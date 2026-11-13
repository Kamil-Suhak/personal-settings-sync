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

function Invoke-GitFetchWithCooldown {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [switch]$Force,
        [switch]$NoFetch
    )

    $remoteUrl = (& git config --get remote.origin.url 2>$null)
    if (-not $remoteUrl) {
        return [pscustomobject]@{ State = 'no-origin'; Text = 'local-only (no origin remote)' }
    }

    if ($NoFetch) {
        return [pscustomobject]@{ State = 'skipped'; Text = 'fetch skipped (-NoFetch)' }
    }

    if (-not $Force -and $global:__git_fetch_cache.ContainsKey($RepoRoot)) {
        $ageSec = ([datetime]::UtcNow - $global:__git_fetch_cache[$RepoRoot]).TotalSeconds
        if ($ageSec -lt 60) {
            $secs = [int][math]::Floor($ageSec)
            return [pscustomobject]@{ State = 'cached'; Text = "fetched ${secs}s ago (cooldown)" }
        }
    }

    $null = & git fetch origin --prune --quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        $global:__git_fetch_cache[$RepoRoot] = [datetime]::UtcNow
        Clear-GitBranchCache
        return [pscustomobject]@{ State = 'fetched'; Text = 'fetched origin --prune just now' }
    }

    return [pscustomobject]@{ State = 'failed'; Text = 'origin fetch failed (offline/unreachable - showing local refs)' }
}

function Resolve-GitBaseBranch {
    [CmdletBinding()]
    param(
        [string]$ExplicitBase,
        [string]$CurrentBranch,
        [switch]$AllowSelf
    )

    $rawRefs = @(& git for-each-ref --format="%(refname:short)" refs/heads/ refs/remotes/origin/ 2>$null)
    $refSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rawRefs) {
        if ($r) { [void]$refSet.Add($r.Trim()) }
    }

    $resolveCandidate = {
        param([string]$Candidate)
        if (-not $Candidate) { return $null }
        $clean = $Candidate.Trim()
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

    if ($ExplicitBase) {
        return (& $resolveCandidate $ExplicitBase)
    }

    if ($CurrentBranch -and $CurrentBranch -ne 'HEAD') {
        $savedBase = (& git config --local --get "branch.$CurrentBranch.base" 2>$null)
        if ($savedBase) {
            $resolvedSaved = & $resolveCandidate $savedBase
            if ($resolvedSaved -and ($AllowSelf -or $resolvedSaved.Branch -ne $CurrentBranch)) {
                return $resolvedSaved
            }
        }

        if (-not $AllowSelf -and $CurrentBranch -in @('develop', 'beta', 'main')) {
            return $null
        }
    }

    foreach ($name in @('develop', 'beta', 'main')) {
        if (-not $AllowSelf -and $CurrentBranch -eq $name) { continue }
        $resolved = & $resolveCandidate $name
        if ($resolved) { return $resolved }
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
  commit <message>         - stages all and creates a commit
  commit amend [<message>] - stages all and amends the latest commit
  commit undo              - soft-resets HEAD~1 keeping changes staged
#>
function commit {
    if (-not $args -or $args.Count -eq 0) {
        Write-Host "Usage: commit <message> | commit amend [<message>] | commit undo" -ForegroundColor Yellow
        return
    }

    $sub = ([string]$args[0]).ToLowerInvariant()
    if ($sub -eq 'undo' -and $args.Count -eq 1) {
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
        git reset --soft HEAD~1
        Clear-GitBranchCache
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Undid last commit. Changes remain safely staged." -ForegroundColor Green
        }
        return
    }

    if ($sub -eq 'amend') {
        $hasCommits = (& git rev-parse --verify HEAD 2>$null)
        if (-not $hasCommits) {
            Write-Host "No commits exist to amend or not in a git repository." -ForegroundColor Yellow
            return
        }
        git add -A
        $rest = @($args | Select-Object -Skip 1)
        if ($rest.Count -gt 0) {
            git commit --amend -m ($rest -join ' ')
        }
        else {
            git commit --amend --no-edit
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Amended latest commit:" -ForegroundColor Green
            git log -1 --oneline
        }
        return
    }

    git add -A
    git commit -m ($args -join ' ')
}

<#
.SYNOPSIS
Pushes commits to remote. If message is passed, stages and commits first. Automatically sets upstream tracking on new branches.
#>
function push {
    $branch = if ($global:__git_cache_branch) { $global:__git_cache_branch } else { (& git branch --show-current 2>$null) -join '' }
    if (-not $branch) { Write-Host "Not a git repository." -ForegroundColor Red; return }

    if ($args) {
        git add -A
        git commit -m "$args"
    }

    # Check if upstream branch is tracked on remote
    $upstream = (& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    if (-not $upstream) {
        Write-Host "Setting upstream origin/$branch and pushing..." -ForegroundColor Cyan
        git push --set-upstream origin $branch
    }
    else {
        git push
    }
}

<#
.SYNOPSIS
Unified repo status, commit divergence view, and sync/catchup hub:
  repo [<base>] [-f|-n] [-a] [-i]   - Fetches origin --prune (1m cooldown), shows commit delta vs remote & base + grouped status
  repo catchup [<base>] [-r|-m|-c]   - Pulls updates from base branch (branch.base or develop->beta->main) via merge or rebase (-r)
  repo sync [-r]                     - Pulls from upstream (merge or -r rebase --autostash), then pushes
#>
function repo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Action,
        [Parameter(Position = 1)]
        [string]$Base,
        [Alias("r")][switch]$Rebase,
        [Alias("m")][switch]$Merge,
        [Alias("c")][switch]$Check,
        [Alias("f")][switch]$Fetch,
        [Alias("n")][switch]$NoFetch,
        [Alias("a")][switch]$All,
        [Alias("i")][switch]$Ignored
    )

    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
        Write-Host "Not inside a git repository." -ForegroundColor Red
        return
    }
    $repoRoot = $repoRoot.Trim()

    $sub = if ($Action) { $Action.ToLowerInvariant() } else { '' }

    if ($sub -eq 'catchup') {
        $curBranch = (& git symbolic-ref --short HEAD 2>$null)
        if ($curBranch) { $curBranch = $curBranch.Trim() }
        $resolvedBase = Resolve-GitBaseBranch -ExplicitBase $Base -CurrentBranch $curBranch
        if (-not $resolvedBase) {
            Write-Host "No base branch found (checked branch config and develop -> beta -> main). Specify one: repo catchup <branch>" -ForegroundColor Yellow
            return
        }

        $targetBranch = $resolvedBase.Branch
        Write-Host "Fetching latest origin/$targetBranch..." -ForegroundColor Cyan
        $null = & git fetch origin $targetBranch --quiet 2>&1
        if ($LASTEXITCODE -eq 0) {
            $global:__git_fetch_cache[$repoRoot] = [datetime]::UtcNow
        }

        $compareRef = if ((& git rev-parse --verify "origin/$targetBranch" 2>$null)) { "origin/$targetBranch" } else { $resolvedBase.Ref }
        $incoming = @(& git log "HEAD..$compareRef" --oneline -n 10 2>$null | Where-Object { $_ })
        if ($incoming.Count -eq 0) {
            Write-Host "Already up to date with $compareRef." -ForegroundColor Green
            return
        }

        Write-Host "`nNew commits on $compareRef since branch-off:" -ForegroundColor Yellow
        $incoming | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

        if ($Check) { return }

        if ($Rebase) {
            Write-Host "`nRebasing current branch onto $compareRef (with autostash)..." -ForegroundColor Cyan
            git rebase $compareRef --autostash
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Rebase successful! Note: use 'git push --force-with-lease' if branch was already pushed." -ForegroundColor DarkCyan
            }
        }
        else {
            Write-Host "`nMerging $compareRef into current branch..." -ForegroundColor Cyan
            git merge $compareRef
        }

        Clear-GitBranchCache
        return
    }

    if ($sub -eq 'sync') {
        Write-Host "Syncing with remote..." -ForegroundColor Cyan
        if ($Rebase) {
            git pull --rebase --autostash
        }
        else {
            git pull --no-rebase
        }

        if ($LASTEXITCODE -eq 0) {
            git push
            if ($LASTEXITCODE -eq 0) {
                $global:__git_fetch_cache[$repoRoot] = [datetime]::UtcNow
            }
        }

        Clear-GitBranchCache
        return
    }

    # Default status & commit divergence mode: `repo` or `repo <base>`
    $targetBase = if ($Base) { $Base } elseif ($Action) { $Action } else { $null }
    $fetchInfo = Invoke-GitFetchWithCooldown -RepoRoot $repoRoot -Force:$Fetch -NoFetch:$NoFetch

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

    Write-Host "`nBranch: " -NoNewline -ForegroundColor Cyan
    Write-Host $branch -NoNewline -ForegroundColor White
    $fetchColor = if ($fetchInfo.State -eq 'failed') { 'Yellow' } else { 'DarkGray' }
    Write-Host "  ($($fetchInfo.Text))" -ForegroundColor $fetchColor

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
        $upstream = (& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $upstream) {
            $upstream = $upstream.Trim()
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

        $baseInfo = Resolve-GitBaseBranch -ExplicitBase $targetBase -CurrentBranch $branch -AllowSelf:([bool]$targetBase)
        if (-not $baseInfo -and $targetBase) {
            Write-Host "`nvs $targetBase" -ForegroundColor Cyan
            Write-Host "  Branch '$targetBase' (or 'origin/$targetBase') not found." -ForegroundColor Yellow
        }
        elseif ($baseInfo -and $baseInfo.Ref -ne $upstream) {
            Show-GitCommitComparison `
                -Title "vs $($baseInfo.Ref)" `
                -OtherRef $baseInfo.Ref `
                -LeftLabel "Only on your branch (not in $($baseInfo.Ref))" `
                -RightLabel "New on $($baseInfo.Ref) since branch-off" `
                -InSyncText "In sync with $($baseInfo.Ref)" `
                -All:$All
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
Unpaged, side-labeled git diff helper:
  diff [<path>...]             - Unstaged changes (Index -> Working Tree)
  diff staged|s [<path>...]    - Staged changes (HEAD -> Index)
  diff all|a [<path>...]       - All uncommitted changes (HEAD -> Working Tree)
  diff up [<path>...]          - Unpushed commits (@{u}..HEAD)
  diff base [<branch>] [path]  - Whole branch changes vs merge-base (origin/<base>...HEAD)
  diff last [<n>] [<path>...]  - Last 1 (or n) commit(s)
  Flags: -Stat (-s), -Files (-f), -Path <string[]>
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

    $knownModes = @('unstaged', 'u', 'staged', 's', 'all', 'a', 'up', 'base', 'last')
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
            'base' {
                if ($Arg1) {
                    $probeBase = Resolve-GitBaseBranch -ExplicitBase $Arg1 -AllowSelf
                    if ($probeBase) {
                        $explicitBase = $Arg1
                    }
                    else {
                        [void]$filterPaths.Add($Arg1)
                    }
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
                Write-Host "No upstream tracking branch configured yet (cannot run 'diff up'). Use 'diff base' or 'push' first." -ForegroundColor Yellow
                return
            }
            $upstream = $upstream.Trim()
            [void]$scopeArgs.Add("$upstream..HEAD")
            $banner = "[diff] Unpushed commits ($upstream -> HEAD)"
        }
        'base' {
            $curBranch = (& git symbolic-ref --short HEAD 2>$null)
            if ($curBranch) { $curBranch = $curBranch.Trim() }
            $baseInfo = Resolve-GitBaseBranch -ExplicitBase $explicitBase -CurrentBranch $curBranch
            if (-not $baseInfo) {
                $msg = if ($explicitBase) { "Base branch '$explicitBase' (or 'origin/$explicitBase') not found." } else { "No base branch found (develop -> beta -> main). Specify one: diff base <branch>" }
                Write-Host $msg -ForegroundColor Yellow
                return
            }
            [void]$scopeArgs.Add("$($baseInfo.Ref)...HEAD")
            $banner = "[diff] Branch changes vs $($baseInfo.Ref) (merge-base $($baseInfo.Ref)...HEAD)"
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

    Write-Host $banner -ForegroundColor Cyan

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
        if ($untrackedCount -gt 0) { [void]$notes.Add("$untrackedCount untracked ('repo')") }
        if ($notes.Count -gt 0) {
            Write-Host "Note: Not shown here — $($notes -join ', ')" -ForegroundColor DarkGray
        }
    }

    if ($gitCmd -eq 'diff') {
        $null = & git diff --quiet @scopeArgs @pathSuffix 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No changes in this scope." -ForegroundColor DarkGray
            return
        }
    }

    $displayArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $scopeArgs) { [void]$displayArgs.Add($a) }
    if ($Stat) { [void]$displayArgs.Add('--stat') }
    elseif ($Files) { [void]$displayArgs.Add('--name-status') }
    foreach ($p in $pathSuffix) { [void]$displayArgs.Add($p) }

    & git --no-pager $gitCmd @displayArgs
}

<#
.SYNOPSIS
Switches branch, lists recent branches (no arg), or prompts to create a new branch if not found.
#>
function b {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Alias("n")][switch]$New
    )

    if (-not $Name) {
        Write-Host "Recent branches:" -ForegroundColor Cyan
        git branch --sort=-committerdate | Select-Object -First 10
        return
    }

    $prevBranch = (& git symbolic-ref --short HEAD 2>$null)
    if ($prevBranch) { $prevBranch = $prevBranch.Trim() }

    if ($New) {
        git switch -c $Name
        if ($LASTEXITCODE -eq 0 -and $prevBranch -and $prevBranch -ne $Name) {
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
    }
    else {
        $reply = Read-Host "Branch '$Name' not found. Create it? [Y/n]"
        if ($reply -eq '' -or $reply -match '^[Yy]') {
            git switch -c $Name
            if ($LASTEXITCODE -eq 0 -and $prevBranch -and $prevBranch -ne $Name) {
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
Creates and switches to a new branch (recording base branch for 'repo' and 'diff base').
#>
function nb {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$From
    )

    if (-not $Name) {
        Write-Host "Branch name required: nb <branch-name> [<from-branch>]" -ForegroundColor Yellow
        return
    }

    if ($From) {
        git switch -c $Name $From
        if ($LASTEXITCODE -eq 0) {
            $cleanFrom = $From -replace '^origin/', ''
            if ($cleanFrom -and $cleanFrom -ne $Name) {
                git config --local "branch.$Name.base" $cleanFrom 2>$null
            }
            Clear-GitBranchCache
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
        Write-Host "Stashed: $wipMsg" -ForegroundColor Green
        Clear-GitBranchCache
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
        Write-Host "Restored stash to working tree." -ForegroundColor Green
        Clear-GitBranchCache
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

    Write-Host "`nGit Stashes:" -ForegroundColor Cyan
    foreach ($entry in $rawStashes) {
        $parts = $entry -split "`t"
        if ($parts.Count -ge 3) {
            Write-Host "  $($parts[0].PadRight(12))" -NoNewline -ForegroundColor Green
            Write-Host " ($($parts[1]))" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($parts[2])" -ForegroundColor Yellow
        }
        else {
            Write-Host "  $entry"
        }
    }
    Write-Host ""
}
#endregion
