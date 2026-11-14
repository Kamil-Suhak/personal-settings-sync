#region 2. Git Automation & Workflows

# In-memory branch & fetch caches to eliminate redundant subprocess overhead
$global:__git_cache_repo = $null
$global:__git_cache_head_path = $null
$global:__git_cache_head_time = [datetime]::MinValue
$global:__git_cache_branch = ''
$global:__git_fetch_cache = @{}

function Clear-GitBranchCache {
    $global:__git_cache_head_time = [datetime]::MinValue
    $global:__git_cache_branch = ''
}

function Invoke-GitConfirmation {
    param(
        [Parameter(Mandatory = $true)][string]$Preview,
        [string]$Label = 'Command preview',
        [switch]$Yes
    )

    Write-Host "${Label}: " -NoNewline -ForegroundColor Yellow
    Write-Host $Preview -ForegroundColor White
    if ($Yes) { return $true }
    $reply = Read-Host "Proceed? [y/N]"
    if ($reply -match '^[Yy](es)?$') {
        return $true
    }
    Write-Host "Aborted." -ForegroundColor DarkGray
    return $false
}

function Invoke-GitFetchWithCooldown {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string[]]$TargetBranches,
        [string]$CurrentUpstream,
        [switch]$Force,
        [switch]$NoFetch
    )

    $remoteUrl = (& git config --get remote.origin.url 2>$null)
    if (-not $remoteUrl) {
        return [pscustomobject]@{ State = 'no-origin'; Text = 'local-only (no origin remote)' }
    }

    if ($NoFetch) {
        return [pscustomobject]@{ State = 'skipped'; Text = 'fetch skipped (-n)' }
    }

    # Resolve candidate origin branch names we care about
    $remoteRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @(& git for-each-ref --format="%(refname:short)" refs/remotes/origin/ 2>$null)) {
        if ($r) { [void]$remoteRefs.Add($r.Trim()) }
    }

    $desiredRefs = [System.Collections.Generic.List[string]]::new()
    $addTargetRef = {
        param([string]$Candidate)
        if (-not $Candidate) { return }
        $clean = $Candidate.Trim() -replace '^origin/', ''
        if ($clean -and $clean -ne 'HEAD' -and $remoteRefs.Contains("origin/$clean") -and -not $desiredRefs.Contains($clean)) {
            [void]$desiredRefs.Add($clean)
        }
    }
    if ($CurrentUpstream) { & $addTargetRef $CurrentUpstream }
    if ($TargetBranches) {
        foreach ($tb in $TargetBranches) { & $addTargetRef $tb }
    }

    # Check both session per-ref cache and .git/FETCH_HEAD mtime (24h threshold)
    $staleThresholdHours = 24
    $cachedEntry = if ($global:__git_fetch_cache.ContainsKey($RepoRoot)) { $global:__git_fetch_cache[$RepoRoot] } else { $null }
    $cacheFresh = $false
    $lastFetchUtc = $null

    if ($cachedEntry -and $cachedEntry.Time) {
        $age = [datetime]::UtcNow - $cachedEntry.Time
        if ($age.TotalHours -lt $staleThresholdHours) {
            $allCovered = [bool]$cachedEntry.All
            if (-not $allCovered) {
                $allCovered = $true
                foreach ($dr in $desiredRefs) {
                    if (-not $cachedEntry.Refs.Contains($dr)) { $allCovered = $false; break }
                }
            }
            if ($allCovered) {
                $cacheFresh = $true
                $lastFetchUtc = $cachedEntry.Time
            }
        }
    }

    if (-not $cacheFresh -and -not $Force -and (-not $TargetBranches -or $TargetBranches.Count -eq 0)) {
        $gitCommonDir = (& git rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitCommonDir) {
            $gitCommonDir = $gitCommonDir.Trim()
            if (-not [System.IO.Path]::IsPathRooted($gitCommonDir)) {
                $gitCommonDir = Join-Path $RepoRoot $gitCommonDir
            }
            $fetchHeadPath = Join-Path $gitCommonDir 'FETCH_HEAD'
            if (Test-Path -LiteralPath $fetchHeadPath -PathType Leaf) {
                $diskFetchUtc = [System.IO.File]::GetLastWriteTimeUtc($fetchHeadPath)
                if (([datetime]::UtcNow - $diskFetchUtc).TotalHours -lt $staleThresholdHours) {
                    $cacheFresh = $true
                    $lastFetchUtc = $diskFetchUtc
                }
            }
        }
    }

    if (-not $Force -and $cacheFresh -and $lastFetchUtc) {
        $age = [datetime]::UtcNow - $lastFetchUtc
        $ageText = if ($age.TotalMinutes -lt 1) {
            "$([int][math]::Floor($age.TotalSeconds))s ago"
        }
        elseif ($age.TotalHours -lt 1) {
            "$([int][math]::Floor($age.TotalMinutes))m ago"
        }
        else {
            "$([int][math]::Floor($age.TotalHours))h ago"
        }
        return [pscustomobject]@{ State = 'cached'; Text = "refs fetched $ageText (-f to refresh)" }
    }

    # Fetch only uncached refs unless forced or full refresh needed
    $refsToFetch = if (-not $Force -and $cachedEntry -and $cachedEntry.Time -and (([datetime]::UtcNow - $cachedEntry.Time).TotalHours -lt $staleThresholdHours)) {
        @($desiredRefs | Where-Object { -not $cachedEntry.Refs.Contains($_) })
    }
    else {
        @($desiredRefs)
    }

    $fetchedOk = $false
    $didFullFetch = $false
    if ($refsToFetch.Count -gt 0) {
        $null = & git fetch origin @refsToFetch --prune --quiet 2>&1
        $fetchedOk = ($LASTEXITCODE -eq 0)
    }
    if (-not $fetchedOk) {
        $null = & git fetch origin --prune --quiet 2>&1
        $fetchedOk = ($LASTEXITCODE -eq 0)
        $didFullFetch = $fetchedOk
    }

    if ($fetchedOk) {
        if ($cachedEntry -and $cachedEntry.Refs -and -not $Force -and (([datetime]::UtcNow - $cachedEntry.Time).TotalHours -lt $staleThresholdHours)) {
            $refSet = $cachedEntry.Refs
        }
        else {
            $refSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        }
        foreach ($r in $refsToFetch) { [void]$refSet.Add($r) }
        $global:__git_fetch_cache[$RepoRoot] = @{
            Time = [datetime]::UtcNow
            Refs = $refSet
            All  = $didFullFetch
        }
        Clear-GitBranchCache
        return [pscustomobject]@{ State = 'fetched'; Text = 'fetched origin just now' }
    }

    return [pscustomobject]@{ State = 'failed'; Text = 'origin fetch failed (offline/unreachable - showing local refs)' }
}

function Resolve-GitTargetRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $rawRefs = @(& git for-each-ref --format="%(refname:short)" refs/heads/ refs/remotes/origin/ 2>$null)
    $refSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rawRefs) {
        if ($r) { [void]$refSet.Add($r.Trim()) }
    }

    $clean = $Name.Trim()
    if ($clean.StartsWith('origin/') -and $refSet.Contains($clean)) {
        return [pscustomobject]@{ Ref = $clean; Branch = $clean.Substring(7) }
    }
    if ($refSet.Contains("origin/$clean")) {
        return [pscustomobject]@{ Ref = "origin/$clean"; Branch = $clean }
    }
    if ($refSet.Contains($clean)) {
        return [pscustomobject]@{ Ref = $clean; Branch = $clean }
    }
    return $null
}

function Show-GitCommitComparison {
    param(
        [string]$Title,
        [string]$OtherRef,
        [string]$LeftLabel,
        [string]$RightLabel,
        [string]$InSyncText,
        [switch]$All
    )

    $leftCommits = @(& git log "$OtherRef..HEAD" --oneline 2>$null | Where-Object { $_ })
    $rightCommits = @(& git log "HEAD..$OtherRef" --oneline 2>$null | Where-Object { $_ })

    Write-Host "`n$Title" -ForegroundColor Cyan
    if ($leftCommits.Count -eq 0 -and $rightCommits.Count -eq 0) {
        Write-Host "  $InSyncText" -ForegroundColor Green
        return
    }

    $printList = {
        param([string]$Label, [string[]]$Items, [string]$Color)
        Write-Host "  ${Label}: " -NoNewline -ForegroundColor $Color
        Write-Host $Items.Count -ForegroundColor White
        $cap = if ($All) { $Items.Count } else { [math]::Min($Items.Count, 10) }
        for ($i = 0; $i -lt $cap; $i++) {
            Write-Host "    $($Items[$i])" -ForegroundColor DarkGray
        }
        if (-not $All -and $Items.Count -gt 10) {
            Write-Host "    ... and $($Items.Count - 10) more (use -a to show all)" -ForegroundColor DarkGray
        }
    }

    & $printList $LeftLabel $leftCommits 'Green'
    & $printList $RightLabel $rightCommits 'Yellow'
}

<#
.SYNOPSIS
Stages all files and commits, amends, or undoes the latest commit:
  commit <message>             - stages all and creates a commit (no prompt)
  commit amend [<msg>] [-y]    - previews and stages/amends latest commit (prompts [y/N]; -y/-Yes skips prompt)
  commit undo [-y]             - previews and soft-resets HEAD~1 keeping changes staged (prompts [y/N]; -y/-Yes skips prompt)
#>
function commit {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$ArgsList,
        [Alias("y")][switch]$Yes
    )

    if (-not $ArgsList -or $ArgsList.Count -eq 0) {
        Write-Host "Usage: commit <message> | commit amend [<message>] [-y] | commit undo [-y]" -ForegroundColor Yellow
        return
    }

    $sub = ([string]$ArgsList[0]).ToLowerInvariant()
    if ($sub -eq 'undo' -and $ArgsList.Count -eq 1) {
        $hasParent = (& git rev-parse --verify HEAD~1 2>$null)
        if (-not $hasParent) {
            $hasHead = (& git rev-parse --verify HEAD 2>$null)
            if (-not $hasHead) {
                Write-Host "No commits exist to undo or not in a git repository." -ForegroundColor Yellow
            }
            else {
                Write-Host "Cannot undo initial commit (HEAD~1 does not exist)." -ForegroundColor Yellow
            }
            return
        }
        if (-not (Invoke-GitConfirmation -Preview 'git reset --soft HEAD~1' -Yes:$Yes)) { return }
        git reset --soft HEAD~1
        Clear-GitBranchCache
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Undid last commit. Changes remain safely staged." -ForegroundColor Green
        }
        else {
            Write-Host "✖ git reset failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
        return
    }

    if ($sub -eq 'amend') {
        $hasCommits = (& git rev-parse --verify HEAD 2>$null)
        if (-not $hasCommits) {
            Write-Host "No commits exist to amend or not in a git repository." -ForegroundColor Yellow
            return
        }
        $rest = @($ArgsList | Select-Object -Skip 1)
        $msg = $rest -join ' '
        $preview = if ($rest.Count -gt 0) {
            "git add -A; git commit --amend -m `"$msg`""
        }
        else {
            'git add -A; git commit --amend --no-edit'
        }
        if (-not (Invoke-GitConfirmation -Preview $preview -Yes:$Yes)) { return }

        git add -A
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ git add failed (exit $LASTEXITCODE)." -ForegroundColor Red
            return
        }
        if ($rest.Count -gt 0) {
            git commit --amend -m $msg
        }
        else {
            git commit --amend --no-edit
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Amended latest commit:" -ForegroundColor Green
            Write-Host "  $((& git log -1 --oneline 2>$null) -join '')" -ForegroundColor White
        }
        else {
            Write-Host "✖ git commit --amend failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
        return
    }

    git add -A
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✖ git add failed (exit $LASTEXITCODE)." -ForegroundColor Red
        return
    }
    git commit -m ($ArgsList -join ' ')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✖ git commit failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Previews the git push command and prompts [y/N] before pushing to origin (-y/-Yes bypasses confirmation while still printing the preview). If a message is passed, stages and commits first.
#>
function push {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$MessageArgs,
        [Alias("y")][switch]$Yes
    )

    $branch = if ($global:__git_cache_branch) { $global:__git_cache_branch } else { (& git branch --show-current 2>$null) -join '' }
    if (-not $branch) { Write-Host "✖ push: Not a git repository." -ForegroundColor Red; return }

    $upstream = (& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $pushCmd = if (-not $upstream) { "git push --set-upstream origin $branch" } else { 'git push' }
    $msg = if ($MessageArgs -and $MessageArgs.Count -gt 0) { $MessageArgs -join ' ' } else { $null }
    $preview = if ($msg) { "git add -A; git commit -m `"$msg`"; $pushCmd" } else { $pushCmd }

    if (-not (Invoke-GitConfirmation -Preview $preview -Yes:$Yes)) { return }

    if ($msg) {
        git add -A
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ git add failed (exit $LASTEXITCODE)." -ForegroundColor Red
            return
        }
        git commit -m $msg
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ git commit failed (exit $LASTEXITCODE)." -ForegroundColor Red
            return
        }
    }

    if (-not $upstream) {
        Write-Host "Setting upstream origin/$branch and pushing..." -ForegroundColor Cyan
        git push --set-upstream origin $branch
    }
    else {
        git push
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✖ git push failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Git branch divergence and working-tree status:
  st [<branch>...] [-f] [-n] [-a] [-i] [-Files] [-Full]
  Without <branch>, inspects working tree and upstream tracking only (does not guess a base branch).
  With <branch>..., compares HEAD against each branch (commits ahead/behind; add -Files for modified files, -Full to run 'diff pr' per branch).
  Auto-fetches stale origin refs (>24h); use -f (-Fetch) to force refresh now or -n (-NoFetch) to skip.
#>
function st {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Branches,
        [Alias("f")][switch]$Fetch,
        [Alias("n")][switch]$NoFetch,
        [Alias("a")][switch]$All,
        [Alias("i")][switch]$Ignored,
        [switch]$Files,
        [switch]$Full
    )

    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
        Write-Host "✖ st: Not inside a git repository." -ForegroundColor Red
        return
    }
    $repoRoot = $repoRoot.Trim()

    $branch = (& git symbolic-ref --short HEAD 2>$null)
    $isDetached = $false
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        $isDetached = $true
        $shortSha = (& git rev-parse --short HEAD 2>$null)
        $branch = if ($shortSha) { "DETACHED @ $($shortSha.Trim())" } else { "HEAD (unborn)" }
    }
    else {
        $branch = $branch.Trim()
    }

    $hasHead = $false
    $null = & git rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $hasHead = $true }

    $upstream = $null
    if ($hasHead -and -not $isDetached) {
        $rawUpstream = (& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $rawUpstream) { $upstream = $rawUpstream.Trim() }
    }

    $fetchInfo = Invoke-GitFetchWithCooldown -RepoRoot $repoRoot -TargetBranches $Branches -CurrentUpstream $upstream -Force:$Fetch -NoFetch:$NoFetch

    Write-Host "`nBranch: " -NoNewline -ForegroundColor Cyan
    Write-Host $branch -NoNewline -ForegroundColor White
    $fetchColor = if ($fetchInfo.State -eq 'failed') { 'Yellow' } else { 'DarkGray' }
    Write-Host "  ($($fetchInfo.Text))" -ForegroundColor $fetchColor
    Write-Host ("─" * 52) -ForegroundColor DarkGray

    # Active in-progress operations banner
    $gitDir = (& git rev-parse --git-dir 2>$null)
    if ($gitDir) {
        $gitDir = $gitDir.Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $repoRoot $gitDir }
        $ops = [System.Collections.Generic.List[string]]::new()
        if ((Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply'))) { [void]$ops.Add('REBASE IN PROGRESS') }
        if (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) { [void]$ops.Add('MERGE IN PROGRESS') }
        if (Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')) { [void]$ops.Add('CHERRY-PICK IN PROGRESS') }
        if (Test-Path -LiteralPath (Join-Path $gitDir 'REVERT_HEAD')) { [void]$ops.Add('REVERT IN PROGRESS') }
        if (Test-Path -LiteralPath (Join-Path $gitDir 'BISECT_LOG')) { [void]$ops.Add('BISECT IN PROGRESS') }
        if ($ops.Count -gt 0) {
            Write-Host "ACTIVE STATE: $($ops -join ' | ')" -ForegroundColor Red
        }
    }

    # Commit comparisons (only when HEAD exists)
    if ($hasHead -and -not $isDetached) {
        if ($upstream) {
            Show-GitCommitComparison `
                -Title "vs $upstream" `
                -OtherRef $upstream `
                -LeftLabel "Not pushed yet (local -> $upstream)" `
                -RightLabel "Not pulled yet ($upstream -> local)" `
                -InSyncText "In sync with $upstream" `
                -All:$All
        }
        elseif ($fetchInfo.State -ne 'no-origin') {
            Write-Host "`nvs origin/$branch" -ForegroundColor Cyan
            Write-Host "  Not pushed to origin yet (run 'push' to publish)" -ForegroundColor Yellow
        }

        if (-not $Branches -or $Branches.Count -eq 0) {
            Write-Host "`nvs other branches" -ForegroundColor Cyan
            Write-Host "  Not compared against any base branch." -ForegroundColor DarkGray
            Write-Host "  Tip: Pass branch names explicitly (e.g. 'st main' or 'st develop beta main')." -ForegroundColor DarkGray
        }
        else {
            foreach ($targetBranch in $Branches) {
                if (-not $targetBranch) { continue }
                $targetInfo = Resolve-GitTargetRef -Name $targetBranch
                if (-not $targetInfo) {
                    Write-Host "`nvs $targetBranch" -ForegroundColor Cyan
                    Write-Host "  Branch '$targetBranch' (or 'origin/$targetBranch') not found." -ForegroundColor Yellow
                    continue
                }

                Show-GitCommitComparison `
                    -Title "vs $($targetInfo.Ref)" `
                    -OtherRef $targetInfo.Ref `
                    -LeftLabel "Only on your branch (not in $($targetInfo.Ref))" `
                    -RightLabel "New on $($targetInfo.Ref) since branch-off" `
                    -InSyncText "In sync with $($targetInfo.Ref)" `
                    -All:$All

                if ($Full) {
                    diff pr $targetBranch -Files:$Files
                }
                elseif ($Files) {
                    $changedFiles = @(& git --no-pager diff --name-status "$($targetInfo.Ref)...HEAD" 2>$null | Where-Object { $_ })
                    if ($changedFiles.Count -gt 0) {
                        Write-Host "  Changed files since merge-base ($($targetInfo.Ref)...HEAD):" -ForegroundColor DarkCyan
                        foreach ($cf in $changedFiles) {
                            Write-Host "    $cf" -ForegroundColor DarkGray
                        }
                    }
                    else {
                        Write-Host "  No file differences since merge-base ($($targetInfo.Ref)...HEAD)." -ForegroundColor DarkGray
                    }
                }
            }
        }
    }

    # Grouped working tree status
    $statusArgs = @('-c', 'core.quotePath=false', 'status', '--porcelain=v1')
    $statusArgs += if ($All) { '-uall' } else { '-unormal' }
    if ($Ignored) { $statusArgs += '--ignored=traditional' }

    $rawStatus = @(& git @statusArgs 2>$null)
    $conflicts = [System.Collections.Generic.List[string]]::new()
    $staged = [System.Collections.Generic.List[string]]::new()
    $unstaged = [System.Collections.Generic.List[string]]::new()
    $untracked = [System.Collections.Generic.List[string]]::new()
    $ignoredFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $rawStatus) {
        if (-not $line -or $line.Length -lt 4) { continue }
        $x = $line[0]
        $y = $line[1]
        $filePath = $line.Substring(3)

        if ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) {
            [void]$conflicts.Add("$x$y $filePath")
            continue
        }
        if ($x -eq '?' -and $y -eq '?') {
            [void]$untracked.Add($filePath)
            continue
        }
        if ($x -eq '!' -and $y -eq '!') {
            [void]$ignoredFiles.Add($filePath)
            continue
        }
        if ($x -ne ' ') {
            [void]$staged.Add("$x  $filePath")
        }
        if ($y -ne ' ') {
            [void]$unstaged.Add(" $y $filePath")
        }
    }

    Write-Host "`nWorking Tree" -ForegroundColor Cyan
    if ($conflicts.Count -eq 0 -and $staged.Count -eq 0 -and $unstaged.Count -eq 0 -and $untracked.Count -eq 0 -and $ignoredFiles.Count -eq 0) {
        Write-Host "  Working tree clean" -ForegroundColor Green
    }
    else {
        $printBucket = {
            param([string]$Label, [System.Collections.Generic.List[string]]$Items, [string]$Color)
            if ($Items.Count -eq 0) { return }
            $noun = if ($Items.Count -eq 1) { 'file' } else { 'files' }
            Write-Host "  ${Label}: $($Items.Count) $noun" -ForegroundColor $Color
            $cap = if ($All) { $Items.Count } else { [math]::Min($Items.Count, 25) }
            for ($i = 0; $i -lt $cap; $i++) {
                Write-Host "    $($Items[$i])" -ForegroundColor DarkGray
            }
            if (-not $All -and $Items.Count -gt 25) {
                Write-Host "    ... and $($Items.Count - 25) more (use -a to show all)" -ForegroundColor DarkGray
            }
        }

        & $printBucket 'Conflicts' $conflicts 'Red'
        & $printBucket 'Staged' $staged 'Green'
        & $printBucket 'Unstaged' $unstaged 'Yellow'
        & $printBucket 'Untracked' $untracked 'DarkYellow'
        & $printBucket 'Ignored' $ignoredFiles 'DarkGray'
    }

    $stashes = @(& git stash list --oneline 2>$null | Where-Object { $_ })
    if ($stashes.Count -gt 0) {
        Write-Host "`nStashes: " -NoNewline -ForegroundColor Cyan
        Write-Host "$($stashes.Count)" -NoNewline -ForegroundColor White
        Write-Host "  (latest: $($stashes[0]))" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# WARNING: Intentionally overrides PowerShell's built-in 'diff' alias (Compare-Object).
# Use 'Compare-Object' explicitly if you need object comparison.
Remove-Alias -Name diff -Force -ErrorAction SilentlyContinue

<#
.SYNOPSIS
Unpaged git diff helper and GitHub PR preview (overrides PowerShell's built-in diff -> Compare-Object):
  diff [<path>...]                 - Unstaged changes (Index -> Working Tree)
  diff staged|s [<path>...]        - Staged changes (HEAD -> Index)
  diff all|a [<path>...]           - All uncommitted changes (HEAD -> Working Tree)
  diff up [<path>...]              - Unpushed commits (@{u}..HEAD)
  diff pr <branch> [-f|-s] [path]  - Preview what a GitHub PR to <branch> shows: included commits (<ref>..HEAD) + merge-base file diff (<ref>...HEAD)
  diff last [<n>] [<path>...]      - Last 1 (or n) commit(s)
  Flags: -Stat (-s) summary stats, -Files (-f) changed file names with A/M/D status (--name-status), -Path <string[]>
#>
function diff {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Target,
        [Parameter(Position = 1)]
        [string]$Arg1,
        [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
        [string[]]$RestArgs,
        [Alias("s")][switch]$Stat,
        [Alias("f")][switch]$Files,
        [string[]]$Path
    )

    $null = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Not inside a git repository. Use 'cmp <file1> <file2>' to diff two files directly." -ForegroundColor Yellow
        return
    }

    $knownModes = @('unstaged', 'u', 'staged', 's', 'all', 'a', 'up', 'pr', 'base', 'last')
    $mode = 'unstaged'
    $filterPaths = [System.Collections.Generic.List[string]]::new()
    if ($Path) {
        foreach ($p in $Path) { if ($p) { [void]$filterPaths.Add($p) } }
    }

    $explicitBase = $null
    $lastCount = 1

    if ($Target -and ($knownModes -contains $Target.ToLowerInvariant())) {
        $mode = $Target.ToLowerInvariant()
        switch ($mode) {
            { $_ -in @('pr', 'base') } {
                if ($Arg1) {
                    $explicitBase = $Arg1
                }
            }
            'last' {
                if ($Arg1) {
                    if ($Arg1 -match '^\d+$') {
                        $lastCount = [math]::Max(1, [int]$Arg1)
                    }
                    else {
                        [void]$filterPaths.Add($Arg1)
                    }
                }
            }
            default {
                if ($Arg1) { [void]$filterPaths.Add($Arg1) }
            }
        }
        if ($RestArgs) {
            foreach ($r in $RestArgs) { if ($r) { [void]$filterPaths.Add($r) } }
        }
    }
    else {
        if ($Target) { [void]$filterPaths.Add($Target) }
        if ($Arg1) { [void]$filterPaths.Add($Arg1) }
        if ($RestArgs) {
            foreach ($r in $RestArgs) { if ($r) { [void]$filterPaths.Add($r) } }
        }
    }

    $gitCmd = 'diff'
    $scopeArgs = [System.Collections.Generic.List[string]]::new()
    $banner = ''
    $prRef = $null

    switch ($mode) {
        { $_ -in @('unstaged', 'u') } {
            $banner = '[diff] Unstaged changes (Index -> Working Tree)'
        }
        { $_ -in @('staged', 's') } {
            [void]$scopeArgs.Add('--staged')
            $banner = '[diff] Staged changes (HEAD -> Index)'
        }
        { $_ -in @('all', 'a') } {
            [void]$scopeArgs.Add('HEAD')
            $banner = '[diff] All uncommitted changes (HEAD -> Working Tree)'
        }
        'up' {
            $upstream = (& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $upstream) {
                Write-Host "No upstream tracking branch configured yet (cannot run 'diff up'). Use 'diff pr <branch>' or 'push' first." -ForegroundColor Yellow
                return
            }
            $upstream = $upstream.Trim()
            [void]$scopeArgs.Add("$upstream..HEAD")
            $banner = "[diff] Unpushed commits ($upstream -> HEAD)"
        }
        { $_ -in @('pr', 'base') } {
            if (-not $explicitBase) {
                Write-Host "Target branch required: diff pr <branch> [-f|-s] (e.g. 'diff pr main')." -ForegroundColor Yellow
                return
            }
            $baseInfo = Resolve-GitTargetRef -Name $explicitBase
            if (-not $baseInfo) {
                Write-Host "Target branch '$explicitBase' (or 'origin/$explicitBase') not found." -ForegroundColor Yellow
                return
            }
            $prRef = $baseInfo.Ref
            [void]$scopeArgs.Add("$prRef...HEAD")
            $banner = "[diff] GitHub PR preview -> $prRef (commits: $prRef..HEAD | diff: $prRef...HEAD)"
        }
        'last' {
            $parentRef = "HEAD~$lastCount"
            $null = & git rev-parse --verify $parentRef 2>$null
            if ($LASTEXITCODE -eq 0) {
                [void]$scopeArgs.Add("$parentRef..HEAD")
                $banner = "[diff] Last $lastCount commit(s) ($parentRef..HEAD)"
            }
            elseif ($lastCount -eq 1) {
                $null = & git rev-parse --verify HEAD 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "No commits exist in this repository yet." -ForegroundColor Yellow
                    return
                }
                $gitCmd = 'show'
                [void]$scopeArgs.Add('HEAD')
                $banner = '[diff] Initial commit (HEAD)'
            }
            else {
                Write-Host "Fewer than $lastCount commits exist in history." -ForegroundColor Yellow
                return
            }
        }
    }

    $pathSuffix = [System.Collections.Generic.List[string]]::new()
    if ($filterPaths.Count -gt 0) {
        [void]$pathSuffix.Add('--')
        foreach ($fp in $filterPaths) { [void]$pathSuffix.Add($fp) }
        $banner += "  [filter: $($filterPaths -join ', ')]"
    }

    Write-Host "`n$banner" -ForegroundColor Cyan
    Write-Host ("─" * 52) -ForegroundColor DarkGray

    if ($prRef) {
        $prCommits = @(& git log "$prRef..HEAD" --oneline 2>$null | Where-Object { $_ })
        if ($prCommits.Count -gt 0) {
            Write-Host "Commits included ($($prCommits.Count)):" -ForegroundColor Green
            foreach ($c in $prCommits) {
                Write-Host "  $c" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "Commits included (0): HEAD has no commits ahead of $prRef." -ForegroundColor DarkGray
        }
    }

    if ($mode -in @('unstaged', 'u', 'staged', 's')) {
        $rawPorcelain = @(& git status --porcelain=v1 2>$null)
        $stagedCount = 0
        $unstagedCount = 0
        $untrackedCount = 0
        foreach ($line in $rawPorcelain) {
            if (-not $line -or $line.Length -lt 4) { continue }
            $x = $line[0]; $y = $line[1]
            if ($x -eq '?' -and $y -eq '?') { $untrackedCount++; continue }
            if ($x -notin @(' ', '!')) { $stagedCount++ }
            if ($y -notin @(' ', '!')) { $unstagedCount++ }
        }
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($mode -in @('unstaged', 'u') -and $stagedCount -gt 0) { [void]$notes.Add("$stagedCount staged ('diff staged')") }
        if ($mode -in @('staged', 's') -and $unstagedCount -gt 0) { [void]$notes.Add("$unstagedCount unstaged ('diff')") }
        if ($untrackedCount -gt 0) { [void]$notes.Add("$untrackedCount untracked ('st')") }
        if ($notes.Count -gt 0) {
            Write-Host "Note: Not shown here — $($notes -join ', ')" -ForegroundColor DarkGray
        }
    }

    if ($gitCmd -eq 'diff') {
        $null = & git diff --quiet @scopeArgs @pathSuffix 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No file differences in this scope." -ForegroundColor DarkGray
            return
        }
    }

    $displayArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $scopeArgs) { [void]$displayArgs.Add($a) }
    if ($Stat) { [void]$displayArgs.Add('--stat') }
    elseif ($Files) { [void]$displayArgs.Add('--name-status') }
    foreach ($p in $pathSuffix) { [void]$displayArgs.Add($p) }

    & git --no-pager $gitCmd @displayArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✖ git $gitCmd failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Switches branch, lists recent branches (no arg), or prompts to create a new branch if not found (-y/-Yes bypasses confirmation while still printing the command preview).
#>
function b {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Alias("n")][switch]$New,
        [Alias("y")][switch]$Yes
    )

    if (-not $Name) {
        Write-Host "`nRecent branches" -ForegroundColor Cyan
        $recentBranches = @(& git branch --sort=-committerdate 2>$null | Select-Object -First 10)
        if ($recentBranches.Count -eq 0) {
            Write-Host "  (no local branches found)" -ForegroundColor DarkGray
        }
        else {
            foreach ($rb in $recentBranches) {
                $trimmed = $rb.TrimStart()
                if ($trimmed.StartsWith('* ')) {
                    Write-Host "  * $($trimmed.Substring(2))" -ForegroundColor Green
                }
                else {
                    Write-Host "    $trimmed" -ForegroundColor White
                }
            }
        }
        Write-Host ""
        return
    }

    $prevBranch = (& git symbolic-ref --short HEAD 2>$null)
    if ($prevBranch) { $prevBranch = $prevBranch.Trim() }

    if ($New) {
        git switch -c $Name
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ git switch failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
        elseif ($prevBranch -and $prevBranch -ne $Name) {
            git config --local "branch.$Name.base" $prevBranch 2>$null
        }
        Clear-GitBranchCache
        return
    }

    $local = (& git branch --list $Name 2>$null) -join ''
    $remote = (& git branch -r --list "*/$Name" 2>$null) -join ''
    $exists = [bool]($local.Trim() -or $remote.Trim())

    if ($exists) {
        git switch $Name
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ git switch failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
    }
    else {
        Write-Host "Command preview: " -NoNewline -ForegroundColor Yellow
        Write-Host "git switch -c $Name" -ForegroundColor White
        $proceed = if ($Yes) {
            $true
        }
        else {
            $reply = Read-Host "Branch '$Name' not found. Create it? [Y/n]"
            ($reply -eq '' -or $reply -match '^[Yy]')
        }
        if ($proceed) {
            git switch -c $Name
            if ($LASTEXITCODE -ne 0) {
                Write-Host "✖ git switch failed (exit $LASTEXITCODE)." -ForegroundColor Red
            }
            elseif ($prevBranch -and $prevBranch -ne $Name) {
                git config --local "branch.$Name.base" $prevBranch 2>$null
            }
        }
        else {
            Write-Host "Aborted. Branch '$Name' was not created." -ForegroundColor DarkGray
        }
    }

    Clear-GitBranchCache
}

<#
.SYNOPSIS
Creates and switches to a new branch (git switch -c [<from-branch>]).
#>
function nb {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$From
    )

    if (-not $Name) {
        Write-Host "Usage: nb <branch-name> [<from-branch>]" -ForegroundColor Yellow
        return
    }

    if ($From) {
        git switch -c $Name $From
        if ($LASTEXITCODE -eq 0) {
            Clear-GitBranchCache
        }
        else {
            Write-Host "✖ git switch failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
        return
    }

    b $Name -New
}

<#
.SYNOPSIS
Compact colorized commit graph (git log --graph). Defaults to 10 commits.
#>
function lg ($count = 10) {
    git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit -n $count
}

<#
.SYNOPSIS
Work In Progress: Stashes staged changes by default, or use -All (-a) to stage and stash all changes including untracked.
#>
function wip {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Message,
        [Alias("a")][switch]$All
    )

    $msgText = if ($Message) { ($Message -join ' ').Trim() } else { $null }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $wipMsg = if ($msgText) { "WIP: $msgText" } else { "WIP: $timestamp" }

    if ($All) {
        Write-Host "Staging all changes (including untracked)..." -ForegroundColor Cyan
        git add -A
        git stash push -u -m "$wipMsg"
    }
    else {
        # Verify staged changes exist
        $null = git diff --staged --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No staged changes to stash." -ForegroundColor Yellow
            Write-Host "Tip: Stage files first (git add) or use 'wip -a' to auto-stage and stash all changes." -ForegroundColor DarkGray
            return
        }
        Write-Host "Stashing staged changes..." -ForegroundColor Cyan
        git stash push --staged -m "$wipMsg"
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Stashed: $wipMsg" -ForegroundColor Green
        Clear-GitBranchCache
    }
    else {
        Write-Host "✖ git stash push failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Restores the latest stash by popping it back into the working tree (git stash pop).
#>
function unwip {
    $hasStash = (& git stash list -n 1 2>$null)
    if (-not $hasStash) {
        Write-Host "No stashes found to pop." -ForegroundColor Yellow
        return
    }

    Write-Host "Popping latest stash..." -ForegroundColor Cyan
    git stash pop
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Restored stash to working tree." -ForegroundColor Green
        Clear-GitBranchCache
    }
    else {
        Write-Host "✖ git stash pop failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Displays formatted, colorized list of all git stashes.
#>
function stashes {
    $rawStashes = git stash list --pretty=format:'%gd%x09%cr%x09%s' 2>$null
    if (-not $rawStashes) {
        Write-Host "No stashes found." -ForegroundColor DarkGray
        return
    }

    Write-Host "`nGit Stashes" -ForegroundColor Cyan
    foreach ($entry in $rawStashes) {
        $parts = $entry -split "`t"
        if ($parts.Count -ge 3) {
            Write-Host "  $($parts[0].PadRight(12))" -NoNewline -ForegroundColor Green
            Write-Host " ($($parts[1]))" -NoNewline -ForegroundColor DarkGray
            Write-Host "  $($parts[2])" -ForegroundColor White
        }
        else {
            Write-Host "  $entry" -ForegroundColor White
        }
    }
    Write-Host ""
}

function Get-GitRepositories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [int]$MaxDepth = 4
    )

    $skipDirs = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            '.git', 'node_modules', 'bin', 'obj', 'target', 'dist',
            '.vs', '.vscode', '.idea', '.venv', 'venv', '__pycache__',
            'packages', '$RECYCLE.BIN', 'System Volume Information'
        ),
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $repos = [System.Collections.Generic.List[string]]::new()

    foreach ($rootPath in $Paths) {
        if (-not $rootPath -or -not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        $resolvedRoot = (Resolve-Path -LiteralPath $rootPath -ErrorAction SilentlyContinue).ProviderPath
        if (-not $resolvedRoot) { continue }

        $foundUnderRoot = $false
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@{ Path = $resolvedRoot; Depth = 0 })

        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $dir = $item.Path
            $depth = $item.Depth

            $dotGit = Join-Path $dir '.git'
            if ([System.IO.Directory]::Exists($dotGit) -or [System.IO.File]::Exists($dotGit)) {
                $canonical = $dir.TrimEnd('\', '/')
                if ($canonical.Length -eq 2 -and $canonical[1] -eq ':') { $canonical += '\' }
                if ($seen.Add($canonical)) {
                    $repos.Add($canonical)
                }
                $foundUnderRoot = $true
                continue
            }

            if ($depth -ge $MaxDepth) { continue }

            try {
                $children = @([System.IO.Directory]::EnumerateDirectories($dir))
                [array]::Sort($children, [System.StringComparer]::OrdinalIgnoreCase)
                for ($i = $children.Count - 1; $i -ge 0; $i--) {
                    $child = $children[$i]
                    $leaf = [System.IO.Path]::GetFileName($child)
                    if ($skipDirs.Contains($leaf)) { continue }
                    try {
                        $attrs = [System.IO.File]::GetAttributes($child)
                        if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    }
                    catch { continue }
                    $stack.Push(@{ Path = $child; Depth = $depth + 1 })
                }
            }
            catch { }
        }

        # Fallback if user passed a subdirectory inside an already-initialized repo
        if (-not $foundUnderRoot) {
            $topLevel = (& git -C $resolvedRoot rev-parse --show-toplevel 2>$null)
            if ($LASTEXITCODE -eq 0 -and $topLevel) {
                $nativeTop = $topLevel.Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                if ([System.IO.Directory]::Exists($nativeTop) -and $seen.Add($nativeTop)) {
                    $repos.Add($nativeTop)
                }
            }
        }
    }

    return @($repos.ToArray())
}

function Get-GitRepoUnpushedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [switch]$Fetch
    )

    if ($Fetch) {
        & git -C $RepoPath fetch --all --prune 2>$null | Out-Null
    }

    $headBranch = (& git -C $RepoPath symbolic-ref --quiet --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $headBranch = $null }

    & git -C $RepoPath rev-parse --verify --quiet HEAD 2>$null | Out-Null
    $hasHead = ($LASTEXITCODE -eq 0)

    if ($headBranch) {
        $displayBranch = $headBranch
    }
    elseif ($hasHead) {
        $shortSha = (& git -C $RepoPath rev-parse --short HEAD 2>$null)
        $displayBranch = "detached@$shortSha"
    }
    else {
        $displayBranch = '(unborn)'
    }

    $remotes = @(& git -C $RepoPath remote 2>$null | Where-Object { $_ })
    $hasRemotes = ($remotes.Count -gt 0)

    # Parse working tree status
    $porcelain = @(& git -C $RepoPath -c core.quotePath=false status --porcelain=v1 2>$null | Where-Object { $_ -and $_.Length -ge 3 })
    $conflicts = 0
    $staged = 0
    $unstaged = 0
    $untracked = 0
    $dirtyFiles = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $porcelain) {
        $x = $line[0]
        $y = $line[1]
        $filePart = $line.Substring(3)

        if ($x -eq '?' -and $y -eq '?') {
            $untracked++
            $category = 'Untracked'
        }
        elseif ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) {
            $conflicts++
            $category = 'Conflict'
        }
        else {
            if ($x -ne ' ') { $staged++ }
            if ($y -ne ' ') { $unstaged++ }
            $category = if ($x -ne ' ' -and $y -eq ' ') { 'Staged' } else { 'Modified' }
        }

        $dirtyFiles.Add([pscustomobject]@{
            Code     = "$x$y"
            Path     = $filePart
            Category = $category
        })
    }

    # Check unpushed commits across all local branches (and detached HEAD)
    $unpushedBranches = [System.Collections.Generic.List[object]]::new()

    if ($hasHead) {
        $refLines = @(& git -C $RepoPath for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track,nobracket)' refs/heads 2>$null | Where-Object { $_ })
        foreach ($refLine in $refLines) {
            $parts = $refLine -split '\|', 3
            $branch = $parts[0]
            $upstream = if ($parts.Count -ge 2) { $parts[1] } else { '' }
            $track = if ($parts.Count -ge 3) { $parts[2] } else { '' }

            $aheadCount = 0
            $rangeSpec = $null
            $note = $null

            if ($upstream -and ($track -ne 'gone')) {
                # Only compute commits if ahead indicator is present or track info is non-standard
                if (-not $track -or ($track -match 'behind \d+' -and $track -notmatch 'ahead')) {
                    $aheadCount = 0
                }
                else {
                    $rawCount = (& git -C $RepoPath rev-list --count "$upstream..$branch" 2>$null)
                    if ($LASTEXITCODE -eq 0 -and $rawCount -match '^\d+$') {
                        $aheadCount = [int]$rawCount
                        $rangeSpec = "$upstream..$branch"
                    }
                }
            }
            else {
                $rawCount = (& git -C $RepoPath rev-list --count $branch --not --remotes 2>$null)
                if ($LASTEXITCODE -eq 0 -and $rawCount -match '^\d+$') {
                    $aheadCount = [int]$rawCount
                }
                if ($upstream -and $track -eq 'gone') {
                    $note = 'upstream gone'
                }
                elseif (-not $hasRemotes) {
                    $note = 'no remote'
                }
                else {
                    $note = 'no upstream'
                }
            }

            if ($aheadCount -gt 0) {
                $commitLines = if ($rangeSpec) {
                    @(& git -C $RepoPath log --oneline $rangeSpec 2>$null | Where-Object { $_ })
                }
                else {
                    @(& git -C $RepoPath log --oneline $branch --not --remotes 2>$null | Where-Object { $_ })
                }

                $unpushedBranches.Add([pscustomobject]@{
                    Branch   = $branch
                    Upstream = if ($upstream -and $track -ne 'gone') { $upstream } else { $null }
                    Note     = $note
                    Ahead    = $aheadCount
                    Commits  = $commitLines
                })
            }
        }

        if (-not $headBranch) {
            $detachedCount = 0
            $rawDetached = (& git -C $RepoPath rev-list --count HEAD --not --remotes 2>$null)
            if ($LASTEXITCODE -eq 0 -and $rawDetached -match '^\d+$') {
                $detachedCount = [int]$rawDetached
            }
            if ($detachedCount -gt 0) {
                $detachedCommits = @(& git -C $RepoPath log --oneline HEAD --not --remotes 2>$null | Where-Object { $_ })
                $unpushedBranches.Add([pscustomobject]@{
                    Branch   = $displayBranch
                    Upstream = $null
                    Note     = 'detached HEAD'
                    Ahead    = $detachedCount
                    Commits  = $detachedCommits
                })
            }
        }
    }

    $hasUnpushed = ($dirtyFiles.Count -gt 0) -or ($unpushedBranches.Count -gt 0)

    return [pscustomobject]@{
        Name             = [System.IO.Path]::GetFileName($RepoPath.TrimEnd('\', '/'))
        Path             = $RepoPath
        CurrentBranch    = $displayBranch
        HasRemotes       = $hasRemotes
        Conflicts        = $conflicts
        Staged           = $staged
        Unstaged         = $unstaged
        Untracked        = $untracked
        DirtyFiles       = @($dirtyFiles.ToArray())
        UnpushedBranches = @($unpushedBranches.ToArray())
        HasUnpushed      = $hasUnpushed
    }
}

<#
.SYNOPSIS
Lists unpushed local changes across multiple git repositories by name or directory.
#>
function unpushed {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Targets,
        [Alias('a')][switch]$All,
        [switch]$Files,
        [Alias('c')][switch]$Commits,
        [Alias('f')][switch]$Fetch,
        [int]$Depth = 4
    )

    $repoSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $repoList = [System.Collections.Generic.List[string]]::new()
    $cachedRootRepos = $null

    $addRepo = {
        param([string]$RepoDir)
        if ($RepoDir -and $repoSet.Add($RepoDir)) {
            $repoList.Add($RepoDir)
        }
    }

    if (-not $Targets -or $Targets.Count -eq 0) {
        $roots = @(Get-PssProjectRoots)
        if ($roots.Count -eq 0) {
            Write-Host "✖ unpushed: No project roots configured. Use 'p -add <path>' or pass directory path(s)." -ForegroundColor Red
            return
        }
        foreach ($repo in (Get-GitRepositories -Paths $roots -MaxDepth $Depth)) {
            & $addRepo $repo
        }
    }
    else {
        foreach ($target in $Targets) {
            if (-not $target) { continue }

            $expandedTarget = if ($target -eq '~' -or $target -match '^~[/\\]') {
                $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($target)
            }
            else {
                $target
            }
            $looksLikePath = ($target -match '[/\\:]') -or ($target -in @('.', '..', '~')) -or ($target.StartsWith('.'))
            if (Test-Path -LiteralPath $expandedTarget -PathType Container) {
                foreach ($repo in (Get-GitRepositories -Paths @($expandedTarget) -MaxDepth $Depth)) {
                    & $addRepo $repo
                }
            }
            elseif ($looksLikePath) {
                Write-Host "⚠ Path not found: $target" -ForegroundColor Yellow
            }
            else {
                if ($null -eq $cachedRootRepos) {
                    $roots = @(Get-PssProjectRoots)
                    if ($roots.Count -eq 0) {
                        Write-Host "✖ unpushed: '$target' is not a directory and no project roots are configured ('p -add <path>')." -ForegroundColor Red
                        return
                    }
                    $cachedRootRepos = @(Get-GitRepositories -Paths $roots -MaxDepth $Depth)
                }

                $pattern = if ($target -match '[\*\?]') { $target } else { "*$target*" }
                $matched = @($cachedRootRepos | Where-Object {
                    [System.IO.Path]::GetFileName($_.TrimEnd('\', '/')) -like $pattern
                })

                if ($matched.Count -eq 0) {
                    Write-Host "⚠ No repository matched '$target'." -ForegroundColor Yellow
                }
                else {
                    foreach ($repo in $matched) { & $addRepo $repo }
                }
            }
        }
    }

    if ($repoList.Count -eq 0) {
        Write-Host "No git repositories found." -ForegroundColor Yellow
        return
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($repoPath in $repoList) {
        $results.Add((Get-GitRepoUnpushedState -RepoPath $repoPath -Fetch:$Fetch))
    }

    $dirtyCount = 0
    $printedAny = $false
    foreach ($res in $results) {
        if ($res.HasUnpushed) { $dirtyCount++ }
        if (-not $res.HasUnpushed -and -not $All) { continue }

        if (-not $printedAny) {
            Write-Host ""
            $printedAny = $true
        }

        if (-not $res.HasUnpushed) {
            Write-Host "✓ $($res.Name) [$($res.CurrentBranch)]  clean  $($res.Path)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "▸ $($res.Name)" -NoNewline -ForegroundColor Yellow
        Write-Host " [$($res.CurrentBranch)]" -NoNewline -ForegroundColor Cyan
        Write-Host "  $($res.Path)" -ForegroundColor DarkGray

        if ($res.DirtyFiles.Count -gt 0) {
            $wtParts = [System.Collections.Generic.List[string]]::new()
            if ($res.Conflicts -gt 0) { $wtParts.Add("$($res.Conflicts) conflict(s)") }
            if ($res.Staged -gt 0) { $wtParts.Add("$($res.Staged) staged") }
            if ($res.Unstaged -gt 0) { $wtParts.Add("$($res.Unstaged) unstaged") }
            if ($res.Untracked -gt 0) { $wtParts.Add("$($res.Untracked) untracked") }
            Write-Host "  Working tree: $($wtParts -join ', ')" -ForegroundColor White

            if ($Files) {
                foreach ($f in $res.DirtyFiles) {
                    $fileColor = switch ($f.Category) {
                        'Conflict'  { 'Red' }
                        'Staged'    { 'Green' }
                        'Modified'  { 'Yellow' }
                        'Untracked' { 'DarkGray' }
                        default     { 'Gray' }
                    }
                    Write-Host "    $($f.Code) $($f.Path)" -ForegroundColor $fileColor
                }
            }
        }

        foreach ($b in $res.UnpushedBranches) {
            $targetText = if ($b.Upstream) { "-> $($b.Upstream)" } elseif ($b.Note) { "($($b.Note))" } else { '' }
            Write-Host "  Branch $($b.Branch)" -NoNewline -ForegroundColor White
            if ($targetText) {
                Write-Host " $targetText" -NoNewline -ForegroundColor DarkGray
            }
            Write-Host ": +$($b.Ahead) unpushed" -ForegroundColor Yellow

            if ($Commits -and $b.Commits.Count -gt 0) {
                foreach ($c in $b.Commits) {
                    Write-Host "    $c" -ForegroundColor Gray
                }
            }
        }
    }

    $cleanCount = $results.Count - $dirtyCount
    if ($dirtyCount -eq 0 -and -not $All) {
        Write-Host "✓ All $($results.Count) repo(s) are clean and pushed." -ForegroundColor Green
    }
    else {
        Write-Host "`nScanned $($results.Count) repo(s): $dirtyCount with unpushed changes, $cleanCount clean." -ForegroundColor Cyan
    }
}
#endregion
