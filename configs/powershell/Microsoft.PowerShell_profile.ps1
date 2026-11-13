#region 1. Core Environment & Encodings
# Bail out immediately if session is non-interactive or streams are redirected (e.g. AGY, automated agent runners, CI/CD)
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }

# Force UTF-8 console encoding for Powerline glyphs and emojis
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Prevent Python virtualenv from injecting an unstyled line above our prompt
$env:VIRTUAL_ENV_DISABLE_PROMPT = 1

# Cache elevated admin state once at startup to avoid expensive reflection on every prompt render
$global:__is_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Last command duration is always stored in $cmdtime; set $__show_prompt_timer = $true to show it on the prompt bar
$global:__show_prompt_timer = $false
$global:cmdtime = $null

# Cache ANSI palette once at startup (guards against PowerShell < 7.2 where $PSStyle is $null)
$global:__ansi = if ($PSStyle) {
    @{
        Cyan   = $PSStyle.Foreground.Cyan
        Yellow = $PSStyle.Foreground.Yellow
        Green  = $PSStyle.Foreground.Green
        Gray   = $PSStyle.Foreground.BrightBlack
        Red    = $PSStyle.Foreground.Red
        Reset  = $PSStyle.Reset
    }
}
else {
    @{ Cyan = ""; Yellow = ""; Green = ""; Gray = ""; Red = ""; Reset = "" }
}

# Resolve repository root dynamically from this shared profile's location
$global:__pss_root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $global:__pss_root 'scripts\local-state.ps1')
$global:__pss_state = Get-PssLocalStatePaths -Checkout $global:__pss_root
$profileDir = if ($PROFILE) { Split-Path -Parent $PROFILE } else { $null }
Invoke-PssLocalStateMigration -Paths $global:__pss_state -Checkout $global:__pss_root -HomePath $HOME -ProfileDirectory $profileDir

function Get-PssActiveWorkspace {
    $wsFile = $global:__pss_state.Workspace
    if (Test-Path -LiteralPath $wsFile) {
        $rawWs = Get-Content -LiteralPath $wsFile -Raw -ErrorAction SilentlyContinue
        if ($rawWs) {
            $ws = $rawWs.Trim()
            if ($ws) { return $ws }
        }
    }
    return "personal"
}
#endregion

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

#region 3. Navigation & Project Switcher

<#
.SYNOPSIS
Go up 1 directory level (Set-Location ..).
#>
function .. { Set-Location .. }

<#
.SYNOPSIS
Go up 2 directory levels (Set-Location ../..).
#>
function ... { Set-Location ../.. }

<#
.SYNOPSIS
Go up 3 directory levels (Set-Location ../../..).
#>
function .... { Set-Location ../../.. }

<#
.SYNOPSIS
Universal Project Jumper: searches configured project roots in ~/.project-roots and jumps to matching project directory. Supports -add, -remove, and -list.
#>
function p {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Target,
        [Alias("a")][switch]$Add,
        [Alias("r", "rm")][switch]$Remove,
        [Alias("l")][switch]$List
    )

    $rootsFile = $global:__pss_state.ProjectRoots

    # Load configured roots from local uncommitted file (~/.project-roots)
    $roots = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $rootsFile) {
        Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and (Test-Path -LiteralPath $line)) {
                $roots.Add($line)
            }
        }
    }

    # 1. List configured roots (p -l or p list)
    if ($List -or $Name -eq 'list') {
        Write-Host "`nConfigured project roots ($rootsFile):" -ForegroundColor Cyan
        if ($roots.Count -eq 0) {
            Write-Host "  No roots found. Use 'p -a <path>' to register one." -ForegroundColor Yellow
        }
        else {
            $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor Green }
        }
        Write-Host ""
        return
    }

    # 2. Add new project root (p -a [<path>] or p add [<path>])
    if ($Add -or $Name -eq 'add') {
        $candidatePath = if ($Name -eq 'add') { $Target } elseif ($Target) { $Target } else { $Name }
        if (-not $candidatePath) {
            $candidatePath = Read-Host "Enter directory path to add to project roots (press Enter for current folder: $pwd)"
            if (-not $candidatePath) { $candidatePath = $pwd.Path }
        }
        $resolved = Resolve-Path -LiteralPath $candidatePath -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Host "Directory not found: $candidatePath" -ForegroundColor Red
            return
        }
        $existing = if (Test-Path -LiteralPath $rootsFile) { @(Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue) } else { @() }
        if ($existing -notcontains $resolved.Path) {
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $rootsFile))
            Add-Content -LiteralPath $rootsFile -Value $resolved.Path
            Write-Host "Added '$($resolved.Path)' to $rootsFile" -ForegroundColor Green
        }
        else {
            Write-Host "'$($resolved.Path)' is already in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 3. Remove project root (p -r [<path>|<index>] or p rm [<path>|<index>])
    if ($Remove -or ($Name -in @('remove', 'rm'))) {
        if (-not (Test-Path -LiteralPath $rootsFile)) {
            Write-Host "`nNo project roots file found ($rootsFile)." -ForegroundColor Yellow
            return
        }

        $lines = @(Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
        if ($lines.Count -eq 0) {
            Write-Host "`nNo project roots configured in $rootsFile." -ForegroundColor Yellow
            return
        }

        $targetToRemove = if ($Name -in @('remove', 'rm')) { $Target } elseif ($Target) { $Target } else { $Name }

        if (-not $targetToRemove) {
            Write-Host "`nConfigured project roots ($rootsFile):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $lines.Count; $i++) {
                Write-Host "  [$($i + 1)] $($lines[$i])" -ForegroundColor Green
            }
            Write-Host ""
            $reply = Read-Host "Enter number or path to remove (press Enter to cancel)"
            if (-not $reply) {
                Write-Host "Canceled." -ForegroundColor DarkGray
                return
            }
            $targetToRemove = $reply.Trim()
        }

        # Check if user entered a number index (1-based)
        $match = $null
        $intIndex = 0
        if ([int]::TryParse($targetToRemove, [ref]$intIndex) -and $intIndex -ge 1 -and $intIndex -le $lines.Count) {
            $match = $lines[$intIndex - 1]
        }
        else {
            # Normalize targetToRemove to check for match
            $resolved = Resolve-Path -LiteralPath $targetToRemove -ErrorAction SilentlyContinue
            $resolvedPath = if ($resolved) { $resolved.Path } else { $targetToRemove }

            $matchedLines = @($lines | Where-Object {
                    $_ -eq $targetToRemove -or
                    $_ -eq $resolvedPath -or
                    (Split-Path $_ -Leaf) -eq $targetToRemove
                })

            if ($matchedLines.Count -eq 1) {
                $match = $matchedLines[0]
            }
            elseif ($matchedLines.Count -gt 1) {
                Write-Host "Multiple roots matched '$targetToRemove':" -ForegroundColor Yellow
                $matchedLines | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
                Write-Host "Please specify the full path." -ForegroundColor Cyan
                return
            }
        }

        if ($match) {
            $remaining = @($lines | Where-Object { $_ -ne $match })
            if ($remaining.Count -gt 0) {
                Set-Content -LiteralPath $rootsFile -Value $remaining
            }
            else {
                Clear-Content -LiteralPath $rootsFile
            }
            Write-Host "Removed '$match' from $rootsFile" -ForegroundColor Green
        }
        else {
            Write-Host "Root '$targetToRemove' not found in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 4. Fail cleanly if no project roots are configured
    if ($roots.Count -eq 0) {
        Write-Error "No project roots configured in $rootsFile. Use 'p -add <path>' first."
        return
    }

    # 5. If invoked without arguments, show roots and usage
    if (-not $Name) {
        Write-Host "`nConfigured project roots:" -ForegroundColor Cyan
        $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
        Write-Host "Usage: p <name> | p -add [<path>] | p -remove [<path>] | p -list`n" -ForegroundColor DarkCyan
        return
    }

    # 6. Search directories across all configured roots
    $matchedDir = $roots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$Name*" }
    } | Select-Object -First 1

    if ($matchedDir) {
        Set-Location -LiteralPath $matchedDir.FullName
    }
    else {
        Write-Host "Project matching '$Name' not found in:" -ForegroundColor Yellow
        $roots | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
        Write-Host "Tip: Use 'p -add <path>' to register additional project directories." -ForegroundColor DarkCyan
    }
}

<#
.SYNOPSIS
Opens Windows File Explorer at the specified path (defaults to current folder).
#>
function rev {
    param([string]$Path = ".")
    try {
        explorer.exe (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    catch {
        Write-Error "Path not found: $Path"
    }
}

# Directory history state for 'back' command
$global:__current_location = $pwd.Path
$global:__prev_location = $null

<#
.SYNOPSIS
Jumps back to the previous working directory (toggles between current and previous location).
#>
function back {
    if (-not $global:__prev_location -or -not (Test-Path -LiteralPath $global:__prev_location)) {
        Write-Host "No previous directory recorded." -ForegroundColor Yellow
        return
    }
    $target = $global:__prev_location
    Set-Location -LiteralPath $target
}
#endregion

#region 4. Development & System Helpers

<#
.SYNOPSIS
Locates commands. Prints path by default; with -h shows description/manual. Supports 'profile' to inspect profile functions.
#>
function which {
    [CmdletBinding(DefaultParameterSetName = "Name")]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Name")]
        [string]$Name,
        [Parameter(Mandatory = $true, ParameterSetName = "Profile")]
        [Alias("p")][switch]$Profile,
        [Alias("h")][switch]$Help
    )

    $cyan = $global:__ansi.Cyan
    $yellow = $global:__ansi.Yellow
    $green = $global:__ansi.Green
    $gray = $global:__ansi.Gray
    $reset = $global:__ansi.Reset

    # Special Profile Inspection Mode: which profile [-h] | which -p [-h]
    $isProfile = $Profile -or ($Name -in @('profile', '$profile'))
    if ($isProfile) {
        $targetProfile = Join-Path $global:__pss_root "configs\powershell\Microsoft.PowerShell_profile.ps1"
        if (-not (Test-Path -LiteralPath $targetProfile)) {
            $targetProfile = if ($PROFILE) { $PROFILE.ToString() } else { "PowerShell Profile" }
        }

        if (-not $Help) {
            return $targetProfile
        }

        $activeWs = Get-PssActiveWorkspace
        $wsProfile = Join-Path $global:__pss_root "workspaces\$activeWs\powershell\profile.ps1"

        $showProfileFuncs = {
            param([string]$FilePath, [string]$Heading)
            if (-not (Test-Path -LiteralPath $FilePath)) { return }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$null)
            $funcAsts = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
            Where-Object { $_.Name -notmatch '^(prompt|Clear-GitBranchCache|(Get|Invoke|Resolve|Show)-)' }

            if ($funcAsts.Count -eq 0) { return }
            Write-Host "${yellow}${Heading} ($($funcAsts.Count)):${reset}`n"
            $maxLen = ($funcAsts | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
            $pad = [math]::Max($maxLen + 2, 12)
            foreach ($f in $funcAsts) {
                $h = $f.GetHelpContent()
                $syn = if ($h -and $h.Synopsis) {
                    $h.Synopsis.Trim()
                }
                else {
                    $live = Get-Help $f.Name -ErrorAction SilentlyContinue
                    if ($live.Synopsis -and $live.Synopsis.Trim() -ne $f.Name) { $live.Synopsis.Trim() } else { "" }
                }
                Write-Host "  ${green}$($f.Name.PadRight($pad))${reset} $syn"
            }
            Write-Host ""
        }

        Write-Host "`n${cyan}=== [PROFILE] $targetProfile (workspace: $activeWs) ===${reset}"
        & $showProfileFuncs $targetProfile "Shared Functions"
        & $showProfileFuncs $wsProfile "Workspace '$activeWs' Functions"
        if ($activeWs -eq 'work') {
            & $showProfileFuncs (Join-Path $global:__pss_root 'workspaces\work\powershell\worksets.ps1') 'Workset Functions'
        }
        return
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Error "Command '$Name' not found."
        return
    }

    if (-not $Help) {
        switch ($cmd.CommandType) {
            'Application' { return $cmd.Source }
            { $_ -in 'Function', 'Filter' } {
                if ($cmd.ScriptBlock -and $cmd.ScriptBlock.File) { return $cmd.ScriptBlock.File }
                if ($PROFILE) { return $PROFILE.ToString() }
                return 'PowerShell Profile'
            }
            'Alias' { return $cmd.Definition }
            Default {
                if ($cmd.Source) { return $cmd.Source }
                return $cmd.Name
            }
        }
    }

    Write-Host "`n${cyan}=== [$($cmd.CommandType.ToString().ToUpper())] $($cmd.Name) ===${reset}"

    switch ($cmd.CommandType) {
        { $_ -in 'Function', 'Filter' } {
            $funcPath = if ($cmd.ScriptBlock -and $cmd.ScriptBlock.File) {
                $cmd.ScriptBlock.File
            }
            elseif ($PROFILE) {
                $PROFILE.ToString()
            }
            else {
                'PowerShell Profile'
            }
            Write-Host "${yellow}Path:${reset}        ${green}$funcPath${reset}"
            $helpObj = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($helpObj.Synopsis -and $helpObj.Synopsis.Trim() -ne $cmd.Name) {
                Write-Host "`n${yellow}Description:${reset}`n  $($helpObj.Synopsis.Trim())"
            }
        }
        'Alias' {
            Write-Host "${yellow}Alias Target:${reset} ${green}$($cmd.Definition)${reset}`n"
            which $cmd.Definition -Help:$Help
        }
        'Application' {
            Write-Host "${yellow}Path:${reset}        ${green}$($cmd.Source)${reset}"
            if (Test-Path -LiteralPath $cmd.Source) {
                $ver = (Get-Item -LiteralPath $cmd.Source).VersionInfo
                if ($ver.FileVersion) { Write-Host "${yellow}Version:${reset}     ${gray}$($ver.FileVersion)${reset}" }
            }
            Write-Host "`n${yellow}Manual / Usage Help:${reset}"
            try {
                $helpOutput = ($null | & $cmd.Source --help 2>&1)
                if ($LASTEXITCODE -ne 0 -or -not $helpOutput) {
                    $helpOutput = ($null | & $cmd.Source /? 2>&1)
                }
                if ($helpOutput) {
                    $lines = @($helpOutput)
                    $lines | ForEach-Object { Write-Host "  $_" }
                }
                else {
                    Write-Host "  ${gray}(No built-in --help or /? documentation returned)${reset}"
                }
            }
            catch {
                Write-Host "  ${gray}Could not execute help: $_${reset}"
            }
        }
        'Cmdlet' {
            Write-Host "${yellow}Module:${reset}      ${green}$($cmd.ModuleName)${reset}"
            $helpObj = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($helpObj.Synopsis) { Write-Host "`n${yellow}Synopsis:${reset}`n  $($helpObj.Synopsis.Trim())" }
            if ($helpObj.Syntax) {
                Write-Host "`n${yellow}Syntax:${reset}"
                ($helpObj.Syntax | Out-String).Trim() | ForEach-Object { Write-Host "  ${gray}$_${reset}" }
            }
        }
    }
    Write-Host ""
}

<#
.SYNOPSIS
Activates Python virtual environment (default: .venv). Automatically creates it via py -m venv if it does not exist yet.
#>
function venv {
    param([string]$Name = ".venv")
    if (-not (Test-Path $Name)) {
        Write-Host "Creating virtual environment in '$Name'..." -ForegroundColor Cyan
        py -m venv $Name 2>$null
        if ($LASTEXITCODE -ne 0) {
            python -m venv $Name
        }
    }
    $activate = Join-Path $Name "Scripts\Activate.ps1"
    if (Test-Path $activate) {
        & $activate
        Write-Host "Activated $Name (Python $((python --version 2>&1) -replace 'Python\s*'))" -ForegroundColor Green
    }
    else {
        Write-Host "Activation script not found: $activate" -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Windows 11 native elevation. Runs command as Administrator; supports 'sudo !!' to re-run the previous command.
#>
function sudo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Command
    )

    $cmd = if ($Command.Count -eq 0 -or ($Command.Count -eq 1 -and $Command[0] -eq '!!')) {
        (Get-History -Count 1).CommandLine
    }
    else {
        $Command -join ' '
    }

    if (-not $cmd) { return }

    sudo.exe pwsh.exe -NoLogo -NoProfile -Command $cmd
}

<#
.SYNOPSIS
Helper function that recursively enumerates files excluding common junk directories and specified extensions.
#>
function Get-SearchableFiles {
    param(
        [string]$Path = ".",
        [string[]]$ExcludeDirs = @('.git', 'node_modules', 'bin', 'obj', 'target', '.vs', 'dist', 'build', '.venv', '__pycache__', '.backups'),
        [string[]]$ExcludeExtensions = @()
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { return @() }

    $rootItem = Get-Item -LiteralPath $resolved.Path -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return @() }
    if (-not $rootItem.PSIsContainer) { return @($rootItem) }

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludeDirs, [System.StringComparer]::OrdinalIgnoreCase)
    $extSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludeExtensions, [System.StringComparer]::OrdinalIgnoreCase)

    $results = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $queue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    $queue.Enqueue($rootItem)

    while ($queue.Count -gt 0) {
        $currentDir = $queue.Dequeue()
        try {
            foreach ($subDir in $currentDir.EnumerateDirectories()) {
                if (-not $excludeSet.Contains($subDir.Name)) {
                    $queue.Enqueue($subDir)
                }
            }
            foreach ($file in $currentDir.EnumerateFiles()) {
                if ($extSet.Count -eq 0 -or -not $extSet.Contains($file.Extension)) {
                    $results.Add($file)
                }
            }
        }
        catch {}
    }
    return $results
}

function Get-ClipboardShortQuery {
    param([int]$MaxLength = 200)

    $raw = Get-Clipboard -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $trimmed = $raw.Trim()
    if ($trimmed.Length -gt $MaxLength -or $trimmed -match '[\r\n]') {
        Write-Host "Clipboard text is multi-line or >$MaxLength chars; skipped auto-query." -ForegroundColor DarkGray
        return $null
    }

    return $trimmed
}

<#
.SYNOPSIS
Interactive fuzzy file finder. Accepts argument, piped query, or short single-line clipboard text; copies selected path to clipboard and optionally opens in VS Code (-o).
#>
function find {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject,
        [Alias("o")]
        [switch]$Open
    )

    begin {
        $pipedParts = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $s = $InputObject.ToString().Trim()
            if ($s) { [void]$pipedParts.Add($s) }
        }
    }

    end {
        if (-not $Name) {
            if ($pipedParts.Count -gt 0) {
                $Name = $pipedParts[0]
            }
            else {
                $Name = Get-ClipboardShortQuery
                if ($Name) {
                    Write-Host "Searching clipboard filename query: '$Name'" -ForegroundColor DarkGray
                }
            }
        }

        if (-not $Name) {
            Write-Host "Usage: find <name> [<path>] [-o]  (or copy a short filename to clipboard)" -ForegroundColor Yellow
            return
        }

        $cleanedTokens = $Name -split '[\s-_.]+' | Where-Object { $_ }
        $regexPattern = ($cleanedTokens | ForEach-Object { [regex]::Escape($_) }) -join '.?'
        $nameRegex = [regex]::new($regexPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $isGitRepo = (& git rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        $foundFiles = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($isGitRepo) {
            $gitRoot = (& git rev-parse --show-toplevel 2>$null)
            $gitArgs = @('ls-files', '--cached', '--others', '--exclude-standard')
            if ($Path -and $Path -ne '.') { $gitArgs += $Path }
            $trackedFiles = & git @gitArgs 2>$null

            if ($trackedFiles) {
                foreach ($relFile in $trackedFiles) {
                    $fileName = Split-Path $relFile -Leaf
                    if ($nameRegex.IsMatch($fileName)) {
                        $fullPath = if ($gitRoot) { Join-Path $gitRoot $relFile } else { (Resolve-Path $relFile -ErrorAction SilentlyContinue).Path }
                        $dirName = Split-Path $fullPath -Parent
                        $foundFiles.Add([PSCustomObject]@{
                                FullName      = $fullPath
                                Name          = $fileName
                                DirectoryName = $dirName
                            })
                    }
                }
            }
        }

        if (-not $isGitRepo -or $foundFiles.Count -eq 0) {
            if (-not $isGitRepo) {
                Get-SearchableFiles -Path $Path |
                Where-Object { $nameRegex.IsMatch($_.Name) } |
                ForEach-Object {
                    $foundFiles.Add([PSCustomObject]@{
                            FullName      = $_.FullName
                            Name          = $_.Name
                            DirectoryName = $_.DirectoryName
                        })
                }
            }
        }

        if ($foundFiles.Count -eq 0) {
            Write-Host "No files found matching '$Name'." -ForegroundColor Yellow
            return
        }

        Write-Host "`nFound $($foundFiles.Count) match$(if ($foundFiles.Count -ne 1) {'es'} else {''}):" -ForegroundColor Cyan
        Write-Host ("-" * 60) -ForegroundColor DarkGray
        $padLen = $foundFiles.Count.ToString().Length

        for ($i = 0; $i -lt $foundFiles.Count; $i++) {
            $numStr = ($i + 1).ToString().PadLeft($padLen)
            $file = $foundFiles[$i]
            Write-Host " [$numStr] " -NoNewline -ForegroundColor DarkCyan
            Write-Host $file.Name.PadRight(35) -NoNewline -ForegroundColor White
            Write-Host " $($file.DirectoryName)" -ForegroundColor DarkGray
        }
        Write-Host ("-" * 60) -ForegroundColor DarkGray

        if ($foundFiles.Count -eq 1) {
            Set-Clipboard -Value $foundFiles[0].FullName
            Write-Host "Copied to clipboard: $($foundFiles[0].FullName)" -ForegroundColor Green
            if ($Open) {
                code $foundFiles[0].FullName
                Write-Host "Opened in VS Code." -ForegroundColor Cyan
            }
            return
        }

        Write-Host (" " * ($padLen + 2) + "[0] Cancel / None") -ForegroundColor DarkYellow
        $actionVerb = if ($Open) { "open in VS Code" } else { "copy" }
        $choice = Read-Host "`nEnter selection to $actionVerb (1-$($foundFiles.Count), or Enter to cancel)"

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $foundFiles.Count) {
            $selectedPath = $foundFiles[[int]$choice - 1].FullName
            Set-Clipboard -Value $selectedPath
            Write-Host "Copied to clipboard: $selectedPath" -ForegroundColor Green
            if ($Open) {
                code $selectedPath
                Write-Host "Opened in VS Code." -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "Action cancelled. Nothing copied." -ForegroundColor DarkGray
        }
    }
}

<#
.SYNOPSIS
Compares two files, a file against the current clipboard, or two interactive clipboard copies using git diff --no-index:
  cmp                 - Clipboard watcher: waits for 2 Ctrl+C copies and diffs them
  cmp <file>          - Compares <file> against current clipboard text
  cmp <file1> <file2> - Compares two files (SHA-256 + git diff --no-index)
  Flags: -IgnoreWhitespace (-w), -Quiet (-q)
#>
function cmp {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [string]$file1,
        [Parameter(Position = 1)]
        [string]$file2,
        [Alias("w")]
        [switch]$IgnoreWhitespace,
        [Alias("q")]
        [switch]$Quiet
    )

    $compareTextPair = {
        param([string]$Text1, [string]$Text2, [string]$Label1, [string]$Label2)

        $t1 = if ($null -ne $Text1) { $Text1 } else { '' }
        $t2 = if ($null -ne $Text2) { $Text2 } else { '' }

        $isMatch = if ($IgnoreWhitespace) {
            ($t1 -replace '\s+', ' ').Trim() -ceq ($t2 -replace '\s+', ' ').Trim()
        }
        else {
            $t1 -ceq $t2
        }

        if ($isMatch) {
            Write-Host "Identical ($Label1 == $Label2)." -ForegroundColor Green
            return
        }

        if (($t1 -replace "`r`n", "`n") -ceq ($t2 -replace "`r`n", "`n")) {
            Write-Warning "Text content matches visually ($Label1 vs $Label2), but line endings differ (CRLF vs LF mismatch)."
            return
        }

        if ($Quiet) {
            Write-Host "Contents differ ($Label1 vs $Label2)." -ForegroundColor Red
            return
        }

        Write-Host "Difference ($Label1 vs $Label2):" -ForegroundColor Yellow
        $id = [guid]::NewGuid().ToString('N')
        $tmp1 = Join-Path ([System.IO.Path]::GetTempPath()) "pss-cmp-$id-1.txt"
        $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) "pss-cmp-$id-2.txt"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        try {
            [System.IO.File]::WriteAllText($tmp1, $t1, $utf8NoBom)
            [System.IO.File]::WriteAllText($tmp2, $t2, $utf8NoBom)
            $diffArgs = @('--no-pager', 'diff', '--no-index', '--color=auto')
            if ($IgnoreWhitespace) { $diffArgs += '-w' }
            $diffArgs += @('--', $tmp1, $tmp2)
            & git @diffArgs
        }
        finally {
            Remove-Item -LiteralPath $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
        }
    }

    # Mode 1: Interactive 2-copy clipboard watcher (`cmp` with no file arguments)
    if (-not $file1 -and -not $file2) {
        if (-not ([System.Management.Automation.PSTypeName]'Win32.NativeClipboard').Type) {
            Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();' `
                -Name 'NativeClipboard' `
                -Namespace 'Win32'
        }

        $waitForNextCopy = {
            param([uint32]$CurrentSeq, [string]$PromptText)
            Write-Host $PromptText -ForegroundColor Cyan
            while ($true) {
                $newSeq = [Win32.NativeClipboard]::GetClipboardSequenceNumber()
                if ($newSeq -ne $CurrentSeq) {
                    Start-Sleep -Milliseconds 50
                    $raw = Get-Clipboard -Raw -ErrorAction SilentlyContinue
                    $content = if ($null -ne $raw) { $raw } else { '' }
                    return [pscustomobject]@{ Sequence = $newSeq; Content = $content }
                }
                Start-Sleep -Milliseconds 100
            }
        }

        $initialSeq = [Win32.NativeClipboard]::GetClipboardSequenceNumber()
        Write-Host "Clipboard Watcher active. (Press Ctrl+C in terminal to abort)`n" -ForegroundColor DarkGray

        $first = & $waitForNextCopy $initialSeq ">>> Copy ITEM 1 (Ctrl+C in source)..."
        Write-Host "Item 1 captured ($($first.Content.Length) characters).`n" -ForegroundColor DarkGreen

        $second = & $waitForNextCopy $first.Sequence ">>> Copy ITEM 2 (Ctrl+C in source)..."
        Write-Host "Item 2 captured ($($second.Content.Length) characters).`n" -ForegroundColor DarkGreen

        & $compareTextPair $first.Content $second.Content 'copy 1' 'copy 2'
        return
    }

    if (-not (Test-Path -LiteralPath $file1 -PathType Leaf)) {
        Write-Host "File not found: $file1" -ForegroundColor Red
        return
    }
    $resolved1 = (Resolve-Path -LiteralPath $file1).Path

    # Mode 2: Single file vs current clipboard (`cmp <file>`)
    if (-not $file2) {
        $text1 = [System.IO.File]::ReadAllText($resolved1)
        $rawClip = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        $text2 = if ($null -ne $rawClip) { $rawClip } else { '' }
        & $compareTextPair $text1 $text2 $file1 'clipboard'
        return
    }

    # Mode 3: Two files (`cmp <file1> <file2>`)
    if (-not (Test-Path -LiteralPath $file2 -PathType Leaf)) {
        Write-Host "File not found: $file2" -ForegroundColor Red
        return
    }
    $resolved2 = (Resolve-Path -LiteralPath $file2).Path

    if (-not $IgnoreWhitespace -and ((Get-FileHash -LiteralPath $resolved1).Hash -eq (Get-FileHash -LiteralPath $resolved2).Hash)) {
        Write-Host "Files are identical." -ForegroundColor Green
        return
    }

    if ($IgnoreWhitespace) {
        $null = & git diff --no-index --quiet -w -- $resolved1 $resolved2 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Files are identical (ignoring whitespace)." -ForegroundColor Green
            return
        }
    }

    if ($Quiet) {
        Write-Host "Files differ." -ForegroundColor Red
    }
    else {
        Write-Host "Files differ:" -ForegroundColor Yellow
        $diffArgs = @('--no-pager', 'diff', '--no-index', '--color=auto')
        if ($IgnoreWhitespace) { $diffArgs += '-w' }
        $diffArgs += @('--', $resolved1, $resolved2)
        & git @diffArgs
    }
}

<#
.SYNOPSIS
Launches Brave Browser with optional arguments (URLs, flags, incognito, profiles). Supports piped URLs and clipboard URL fallback.
#>
function brave {
    $bravePath = if ($global:__brave_path -and (Test-Path -LiteralPath $global:__brave_path)) {
        $global:__brave_path
    }
    else {
        $candidates = @(
            (Get-Command brave.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe' -ErrorAction SilentlyContinue).'(default)'),
            ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe' -ErrorAction SilentlyContinue).'(default)'),
            "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
        $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($found) { $global:__brave_path = $found }
        $found
    }

    if (-not $bravePath) {
        Write-Host "Brave Browser executable not found. Install it via 'winget install Brave.Brave' or 'pss apps install'." -ForegroundColor Red
        return
    }

    $passedArgs = [System.Collections.Generic.List[string]]::new()
    if ($args) {
        foreach ($a in $args) { $passedArgs.Add([string]$a) }
    }
    if ($null -ne $input) {
        foreach ($item in $input) {
            if ($null -ne $item -and [string]$item -match '\S') {
                $passedArgs.Add([string]$item)
            }
        }
    }

    if ($passedArgs.Count -eq 0) {
        $clipRaw = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if ($clipRaw) {
            $clipUrl = $clipRaw.Trim()
            if ($clipUrl -match '^https?://\S+$') {
                Write-Host "Opening URL from clipboard: $clipUrl" -ForegroundColor DarkGray
                $passedArgs.Add($clipUrl)
            }
        }
    }

    if ($passedArgs.Count -gt 0) {
        Start-Process -FilePath $bravePath -ArgumentList $passedArgs
    }
    else {
        Start-Process -FilePath $bravePath
    }
}

function Get-VsSolutions {
    param([string]$StartDirectory, [int]$MaxDepth = 5)
    $currentDir = $StartDirectory
    for ($depth = 0; $depth -le $MaxDepth -and $currentDir; $depth++) {
        $found = @(Get-ChildItem -LiteralPath $currentDir -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.sln', '.slnx') } |
            Sort-Object Name)
        if ($found.Count -gt 0) { return $found }
        $parent = Split-Path -Parent $currentDir
        if (-not $parent -or $parent -eq $currentDir) { break }
        $currentDir = $parent
    }
}

<#
.SYNOPSIS
Opens Visual Studio for a .sln/.slnx found in the target/current directory or up to MaxDepth parent levels. Supports passing a file path to open alongside the solution.
#>
function vs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [string]$Path = ".",
        [ValidateRange(0, 20)]
        [int]$MaxDepth = 5,
        [string[]]$Files
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Path not found: $Path"
        return
    }

    $item = Get-Item -LiteralPath $Path
    $selectedSolution = $null
    $targetFile = $null
    $searchStartDir = $null
    $targetFiles = @()
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-Error "File not found: $file"
            return
        }
        $targetFiles += (Get-Item -LiteralPath $file).FullName
    }

    if (-not $item.PSIsContainer -and $item.Extension -in @('.sln', '.slnx')) {
        $selectedSolution = $item
    }
    else {
        if ($item.PSIsContainer) {
            $searchStartDir = $item.FullName
        }
        else {
            $searchStartDir = $item.DirectoryName
            $targetFile = $item.FullName
        }

        $solutions = @(Get-VsSolutions -StartDirectory $searchStartDir -MaxDepth $MaxDepth)

        if ($solutions.Count -eq 0) {
            Write-Error "No .sln or .slnx file found in '$searchStartDir' or within $MaxDepth parent level(s)."
            return
        }
        elseif ($solutions.Count -eq 1) {
            $selectedSolution = $solutions[0]
        }
        else {
            Write-Host "`nMultiple solutions found in '$($solutions[0].DirectoryName)':" -ForegroundColor Cyan
            for ($i = 0; $i -lt $solutions.Count; $i++) {
                Write-Host "  [$($i + 1)] $($solutions[$i].Name)" -ForegroundColor Green
            }
            $reply = Read-Host "Select solution [1-$($solutions.Count)] (Enter for 1)"
            if ([string]::IsNullOrWhiteSpace($reply)) {
                $selectedSolution = $solutions[0]
            }
            else {
                $idx = 0
                if ([int]::TryParse($reply.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $solutions.Count) {
                    $selectedSolution = $solutions[$idx - 1]
                }
                else {
                    Write-Host "Canceled." -ForegroundColor DarkGray
                    return
                }
            }
        }
    }

    if ($targetFile) { $targetFiles = @($targetFile) + $targetFiles }
    $targetFiles = @($targetFiles | Select-Object -Unique)
    $devenvPath = if ($global:__devenv_path -and (Test-Path -LiteralPath $global:__devenv_path)) {
        $global:__devenv_path
    }
    else {
        $vswhere = Join-Path "${env:ProgramFiles(x86)}" "Microsoft Visual Studio\Installer\vswhere.exe"
        $vswhereHit = if (Test-Path -LiteralPath $vswhere) {
            (& $vswhere -latest -prerelease -products * -property productPath 2>$null | Select-Object -First 1)
        }
        else { $null }

        $candidates = @(
            (Get-Command devenv.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            $vswhereHit,
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\devenv.exe' -ErrorAction SilentlyContinue).'(default)')
        )
        $hit = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($hit) { $global:__devenv_path = $hit }
        $hit
    }

    $actionDesc = if ($targetFiles.Count) {
        "Open '$($selectedSolution.FullName)' and '$($targetFiles -join "', '")'"
    }
    else {
        "Open '$($selectedSolution.FullName)'"
    }

    Write-Verbose $actionDesc
    if (-not $PSCmdlet.ShouldProcess($selectedSolution.FullName, $actionDesc)) {
        return
    }

    if ($devenvPath) {
        $rawArgs = @($selectedSolution.FullName)
        $rawArgs += $targetFiles
        $quotedArgs = @($rawArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
        Start-Process -FilePath $devenvPath -ArgumentList $quotedArgs
    }
    else {
        if ($Files.Count) {
            Write-Error "devenv.exe not found; cannot open the selected files."
            return
        }
        if ($targetFile) {
            Write-Warning "devenv.exe not found in PATH or Visual Studio Installer; opening solution without '$targetFile'."
        }
        Start-Process -FilePath $selectedSolution.FullName
    }
}

<#
.SYNOPSIS
Dual-mode text finder. Filters piped input or searches codebase files recursively while auto-skipping junk directories and binary files.
#>
function findstr {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Pattern,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject,
        [Alias("v")]
        [switch]$Invert,
        [Alias("c")]
        [switch]$CaseSensitive,
        [Alias("l")]
        [switch]$FilesOnly
    )

    begin {
        if (-not $Pattern) {
            $Pattern = Get-ClipboardShortQuery
            if ($Pattern) {
                Write-Host "Searching clipboard pattern: '$Pattern'" -ForegroundColor DarkGray
            }
        }

        $hasValidPattern = [bool]$Pattern
        $isPiped = $PSCmdlet.MyInvocation.ExpectingInput
        if (-not $hasValidPattern) {
            Write-Host "Usage: findstr <pattern> [<path>] [-v] [-c] [-l]  (or copy a short single-line pattern to clipboard)" -ForegroundColor Yellow
            return
        }

        $regexOptions = if ($CaseSensitive) {
            [System.Text.RegularExpressions.RegexOptions]::None
        }
        else {
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        }

        try {
            $regex = [regex]::new($Pattern, $regexOptions)
        }
        catch {
            $regex = [regex]::new([regex]::Escape($Pattern), $regexOptions)
        }
    }

    process {
        if ($hasValidPattern -and $isPiped -and $null -ne $InputObject) {
            $line = $InputObject.ToString()
            $matched = $regex.IsMatch($line)
            if (($matched -and -not $Invert) -or (-not $matched -and $Invert)) {
                $line
            }
        }
    }

    end {
        if ($isPiped -or -not $hasValidPattern) { return }

        $cyan = $global:__ansi.Cyan
        $yellow = $global:__ansi.Yellow
        $reset = $global:__ansi.Reset

        # 1. Fast Git acceleration inside a Git repository (monolith indexing)
        $isGitRepo = (& git rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        if ($isGitRepo) {
            $grepArgs = @('grep', '-n', '-I', '--color=never')
            if (-not $CaseSensitive) { $grepArgs += '-i' }
            if ($Invert) { $grepArgs += '-v' }
            if ($FilesOnly) { $grepArgs += '-l' }
            $grepArgs += @('-e', $Pattern)
            if ($Path -and $Path -ne '.') { $grepArgs += @('--', $Path) }

            $results = & git @grepArgs 2>$null
            if ($results) {
                if ($FilesOnly) {
                    foreach ($line in $results) {
                        "${cyan}${line}${reset}"
                    }
                }
                else {
                    foreach ($line in $results) {
                        if ($line -match '^([^:]+):(\d+):(.*)$') {
                            "${cyan}$($matches[1])${reset}:${yellow}$($matches[2])${reset}: $($matches[3])"
                        }
                        else {
                            $line
                        }
                    }
                }
            }
            return
        }

        # 2. Pure PowerShell fallback outside Git repositories
        $binaryExts = @('.exe', '.dll', '.pdb', '.zip', '.tar', '.gz', '.7z', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.woff', '.woff2', '.ttf')
        $currentDir = (Get-Location).Path.TrimEnd('\', '/')

        $files = Get-SearchableFiles -Path $Path -ExcludeExtensions $binaryExts
        $matchingFiles = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($file in $files) {
            $relPath = $file.FullName
            if ($relPath.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relPath = $relPath.Substring($currentDir.Length).TrimStart('\', '/')
            }

            try {
                $lines = [System.IO.File]::ReadLines($file.FullName)
            }
            catch { continue }

            $lineNum = 0
            $fileHasMatch = $false

            foreach ($line in $lines) {
                $lineNum++
                $matched = $regex.IsMatch($line)

                if ($matched -and -not $Invert) {
                    $fileHasMatch = $true
                    if ($FilesOnly) {
                        if ($matchingFiles.Add($relPath)) {
                            "${cyan}${relPath}${reset}"
                        }
                        break
                    }
                    else {
                        "${cyan}${relPath}${reset}:${yellow}${lineNum}${reset}: $line"
                    }
                }
            }

            if ($Invert -and -not $fileHasMatch) {
                "${cyan}${relPath}${reset}"
            }
        }
    }
}

# WARNING: Intentionally overrides PowerShell's built-in 'copy' alias (Copy-Item).
# Use 'Copy-Item' (or 'cp') explicitly when copying files.
Set-Alias -Name copy -Value Set-Clipboard -Option AllScope -Force
Set-Alias -Name paste -Value Get-Clipboard -Option AllScope -Force

<#
.SYNOPSIS
Decodes a JWT header and payload offline without making any network calls. Supports arguments, pipeline input, or clipboard fallback.
#>
function jwt {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string]$Token
    )

    begin {
        $handledAny = $false
        $decodePart = {
            param([string]$Segment)
            $b64 = $Segment.Replace('-', '+').Replace('_', '/')
            switch ($b64.Length % 4) {
                2 { $b64 += '==' }
                3 { $b64 += '=' }
            }
            $jsonText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            return ($jsonText | ConvertFrom-Json)
        }

        $decodeJwtString = {
            param([string]$RawInput)
            $raw = $RawInput.Trim() -replace '^Bearer\s+', ''
            $parts = $raw -split '\.'
            if ($parts.Count -lt 2) {
                Write-Error "Invalid JWT format (expected header.payload[.signature])."
                return
            }

            try {
                $header = & $decodePart $parts[0]
                $payload = & $decodePart $parts[1]

                Write-Host "`n--- JWT Header ---" -ForegroundColor Cyan
                $header | ConvertTo-Json -Depth 10 | Write-Host

                Write-Host "`n--- JWT Payload ---" -ForegroundColor Cyan
                $payload | ConvertTo-Json -Depth 10 | Write-Host

                if ($payload.exp) {
                    $expUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.exp).ToLocalTime()
                    $state = if ($expUtc -lt [DateTimeOffset]::Now) { "EXPIRED" } else { "VALID" }
                    $color = if ($state -eq "EXPIRED") { "Red" } else { "Green" }
                    Write-Host "`nExpires: $($expUtc.ToString('yyyy-MM-dd HH:mm:ss zzz')) [$state]" -ForegroundColor $color
                }
                Write-Host ""
            }
            catch {
                Write-Error "Failed to decode JWT: $($_.Exception.Message)"
            }
        }
    }

    process {
        if ([string]::IsNullOrWhiteSpace($Token)) { return }
        $handledAny = $true
        & $decodeJwtString $Token
    }

    end {
        if (-not $handledAny -and -not $PSCmdlet.MyInvocation.ExpectingInput) {
            $clipToken = Get-Clipboard -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($clipToken)) {
                Write-Host "Usage: jwt <token>  (or pipe / copy a JWT to clipboard)" -ForegroundColor Yellow
                return
            }
            Write-Host "Decoding JWT from clipboard..." -ForegroundColor DarkGray
            & $decodeJwtString $clipToken
        }
    }
}

<#
.SYNOPSIS
Runs a polling wait loop with a green ASCII spinner and cancellation cleanup.
#>
function Invoke-WithSpinner {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$IsDone,
        [scriptblock]$OnCancel
    )

    $frames = @('|', '/', '-', '\')
    $green = $global:__ansi.Green
    $reset = $global:__ansi.Reset
    $esc = [char]0x1b
    $animate = -not [Console]::IsOutputRedirected
    $i = 0

    try {
        if ($animate) { Write-Host "${esc}[?25l" -NoNewline }
        while (-not (& $IsDone)) {
            if ($animate) {
                $frame = $frames[$i % $frames.Length]
                Write-Host "`r${green}${frame}${reset} " -NoNewline
                $i++
            }
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        if ($animate) {
            Write-Host "`r${esc}[2K${esc}[?25h" -NoNewline
        }
        if (-not (& $IsDone) -and $OnCancel) {
            & $OnCancel
        }
    }
}

function Get-TerminalAskContext {
    param(
        [string]$Question,
        [string]$Piped,
        [switch]$Clean
    )

    $pipedSection = if (-not [string]::IsNullOrWhiteSpace($Piped)) {
        "`n[Context: Piped Input]`n$Piped`n"
    }
    else { "" }

    $promptQuestion = if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $Question
    }
    else {
        "Analyze or answer based on the piped input above."
    }

    if ($Clean) {
        $historyCmds = "<empty>"
        $recentOutput = "<empty>"
    }
    else {
        $historyCmds = (Get-History -Count 5 | ForEach-Object { "$($_.Id): $($_.CommandLine)" }) -join "`n"
        $recentOutput = ""
        try {
            $rawUi = $Host.UI.RawUI
            $cursorY = $rawUi.CursorPosition.Y
            $startY = [Math]::Max(0, $cursorY - 30)
            $rect = [System.Management.Automation.Host.Rectangle]::new(0, $startY, $rawUi.BufferSize.Width - 1, $cursorY)
            $buffer = $rawUi.GetBufferContents($rect)
            $lines = for ($y = 0; $y -lt $buffer.GetLength(0); $y++) {
                $line = -join $(for ($x = 0; $x -lt $buffer.GetLength(1); $x++) { $buffer[$y, $x].Character })
                $line.TrimEnd()
            }
            $recentOutput = ($lines | Where-Object { $_ -ne "" }) -join "`n"
        }
        catch {
            $recentOutput = "(Screen buffer capture unavailable)"
        }
    }

    return [PSCustomObject]@{
        History      = $historyCmds
        Output       = $recentOutput
        PipedSection = $pipedSection
        Question     = $promptQuestion
    }
}

function Invoke-AskCliProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new($ExecutablePath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.WorkingDirectory = $pwd.Path
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }

    $proc = $null
    $stdout = ""
    $stderr = ""
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        Invoke-WithSpinner -IsDone { $proc.HasExited } -OnCancel { try { $proc.Kill($true) } catch {} }

        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    }
    finally {
        if ($proc) {
            if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
            $proc.Dispose()
        }
    }

    $cyan = $global:__ansi.Cyan
    $gray = $global:__ansi.Gray
    $red = $global:__ansi.Red
    $reset = $global:__ansi.Reset

    if ($stdout) {
        Write-Host "`n${cyan}▸ ask${reset} ${gray}($Label)${reset}"
        $stdout.TrimEnd("`r", "`n") -split "`r?`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
    }
    if ($stderr) {
        Write-Host "`n${red}✖ ask error:${reset}"
        $stderr.TrimEnd("`r", "`n") -split "`r?`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host ""
    }
}

<#
.SYNOPSIS
Evaluates a scenario or piped context using the Gemini Decision API and renders a confidence verdict.
#>
function decide {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Question,
        [string[]]$Choices = @("yes", "no"),
        [string]$Instructions = "Evaluate the scenario and pick the best option.",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject
    )

    begin {
        $pipeLines = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $pipeLines.Add([string]$InputObject)
        }
    }

    end {
        if ([string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {
            Write-Error "GEMINI_API_KEY environment variable is not set."
            return
        }

        if ($Choices.Count -lt 2) {
            Write-Error "Choices must contain at least 2 options."
            return
        }

        $piped = $pipeLines -join "`n"
        $qText = if ($Question) { $Question -join ' ' } else { "" }

        if ([string]::IsNullOrWhiteSpace($qText) -and [string]::IsNullOrWhiteSpace($piped)) {
            Write-Warning "Usage: decide [-Choices <a,b>] [-Instructions <text>] <question>"
            return
        }

        if ([string]::IsNullOrWhiteSpace($qText)) {
            $qText = "What is the recommended decision?"
        }

        $target = if (-not [string]::IsNullOrWhiteSpace($piped)) {
            "Context / Input:`n$piped`n`nQuestion: $qText"
        }
        else {
            $qText
        }

        $criteria = [ordered]@{}
        foreach ($c in $Choices) {
            $criteria[$c] = "Option: $c"
        }

        $payload = [ordered]@{
            model     = "gemini-decision-1"
            input     = $target
            questions = [ordered]@{
                verdict = [ordered]@{
                    type         = "choice"
                    instructions = $Instructions
                    criteria     = $criteria
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $cts = [System.Threading.CancellationTokenSource]::new()
        $client = [System.Net.Http.HttpClient]::new()
        $client.DefaultRequestHeaders.Add("x-goog-api-key", $env:GEMINI_API_KEY)
        $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, "application/json")

        $res = $null
        try {
            $httpTask = $client.PostAsync(
                "https://generativelanguage.googleapis.com/v1beta/decisions",
                $content,
                $cts.Token
            )
            Invoke-WithSpinner -IsDone { $httpTask.IsCompleted } -OnCancel { $cts.Cancel() }

            $response = $httpTask.GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                Write-Error "Decisions API error ($([int]$response.StatusCode) $($response.ReasonPhrase)): $body"
                return
            }
            $res = $body | ConvertFrom-Json
        }
        finally {
            $content.Dispose()
            $client.Dispose()
            $cts.Dispose()
        }

        $verdict = $res.answers.verdict
        $choice = [string]$verdict.choice
        $p = [double]$verdict.confidence
        $pct = [int][Math]::Round($p * 100)
        $filled = [Math]::Clamp([int][Math]::Round($p * 10), 0, 10)
        $bar = ("█" * $filled) + ("░" * (10 - $filled))

        $badgeColor = switch ($choice.ToLowerInvariant()) {
            "yes" { "Green" }
            "no" { "Red" }
            default { "Cyan" }
        }
        $barColor = if ($p -ge 0.8) { "Green" } elseif ($p -ge 0.5) { "Yellow" } else { "Red" }

        Write-Host ""
        Write-Host "  [$($choice.ToUpperInvariant())]" -ForegroundColor $badgeColor -NoNewline
        Write-Host ("  {0,3}%  " -f $pct) -ForegroundColor White -NoNewline
        Write-Host $bar -ForegroundColor $barColor -NoNewline
        Write-Host "  $qText" -ForegroundColor DarkGray

        if ($Choices.Count -gt 2 -and $verdict.probabilities) {
            $breakdown = foreach ($prop in $verdict.probabilities.PSObject.Properties) {
                "{0} {1:P0}" -f $prop.Name, [double]$prop.Value
            }
            Write-Host "  $($breakdown -join ' · ')" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

<#
.SYNOPSIS
Personal Settings Sync CLI runner (pss.ps1).
#>
function pss {
    $pssScript = Join-Path $global:__pss_root "pss.ps1"
    if (Test-Path -LiteralPath $pssScript) {
        & $pssScript @args
    }
    else {
        Write-Host "pss.ps1 not found at: $pssScript" -ForegroundColor Red
    }
}
#endregion

#region 5. PSReadLine & Predictive IntelliSense
if ($Host.UI.RawUI -and (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
    try {
        $psReadLineModule = Get-Module PSReadLine
        if (-not $psReadLineModule) {
            $psReadLineModule = Import-Module PSReadLine -PassThru -ErrorAction SilentlyContinue
        }

        if ($psReadLineModule -and $psReadLineModule.Version -ge [Version]'2.2.0') {
            Import-Module CompletionPredictor -ErrorAction SilentlyContinue
            Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
            Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
            Set-PSReadLineOption -Colors @{ InlinePrediction = "$([char]0x1b)[38;5;242m" } -ErrorAction SilentlyContinue
        }

        Set-PSReadLineKeyHandler -Key "Tab" -Function TabCompleteNext -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "Shift+Tab" -Function TabCompletePrevious -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "Ctrl+Spacebar" -Function MenuComplete -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "RightArrow" -BriefDescription "ForwardCharOrAcceptNextSuggestionWord" -ScriptBlock {
            param($key, $arg)
            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ($cursor -lt $line.Length) {
                [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
            }
            else {
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptNextSuggestionWord($key, $arg)
            }
        } -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "F2" -Function SwitchPredictionView -ErrorAction SilentlyContinue
    }
    catch {
        # Fallback gracefully in non-interactive / redirected consoles
    }
}
#endregion

#region 6. Powerline Segmented Prompt
function prompt {
    # Track directory history for 'back' command
    if ($global:__current_location -and $global:__current_location -ne $pwd.Path) {
        $global:__prev_location = $global:__current_location
    }
    $global:__current_location = $pwd.Path

    $lastError = $global:?
    $statusColor = if ($lastError) { "Green" } else { "Red" }
    $arrow = [char]0xE0B0

    # 1. Timer Logic: always record $global:cmdtime; only render on prompt bar if $global:__show_prompt_timer is $true
    $durationText = ""
    $global:cmdtime = $null
    $lastCommand = Get-History -Count 1 -ErrorAction SilentlyContinue
    if ($lastCommand) {
        $duration = $lastCommand.EndExecutionTime - $lastCommand.StartExecutionTime
        $formattedTime = if ($duration.TotalMinutes -ge 1) {
            "{0:N0}m {1:N0}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
        }
        elseif ($duration.TotalSeconds -ge 1) {
            "{0:N2}s" -f $duration.TotalSeconds
        }
        else {
            "{0:N0}ms" -f $duration.TotalMilliseconds
        }
        $global:cmdtime = $formattedTime
        if ($global:__show_prompt_timer -and $duration.TotalMilliseconds -gt 500) {
            $durationText = " ⏱ $formattedTime "
        }
    }

    # 2. Directory Logic (2-tier path to eliminate folder ambiguity)
    $normalizedPath = $pwd.Path -replace ('^' + [regex]::Escape($HOME)), '~'
    if ($normalizedPath -eq '~') {
        $currentDir = '~'
    }
    else {
        $segments = $normalizedPath.TrimEnd('\', '/') -split '[\\/]'
        if ($segments.Count -ge 2) {
            $currentDir = "$($segments[-2])/$($segments[-1])"
        }
        else {
            $currentDir = $segments[-1]
        }
    }

    # 3. Fast Git Logic with In-Memory Caching (no process spawn per prompt)
    $gitBranch = ''
    $searchDir = $pwd.Path
    $inGitRepo = $false
    while ($searchDir) {
        if (Test-Path (Join-Path $searchDir '.git') -ErrorAction SilentlyContinue) {
            $inGitRepo = $true
            break
        }
        $parent = Split-Path $searchDir -Parent
        if ($parent -eq $searchDir) { break }
        $searchDir = $parent
    }

    if ($inGitRepo) {
        $gitItem = Join-Path $searchDir '.git'
        $headPath = $null

        if ($global:__git_cache_repo -eq $searchDir -and $global:__git_cache_head_path) {
            $headPath = $global:__git_cache_head_path
        }
        else {
            if (Test-Path -PathType Container -LiteralPath $gitItem) {
                $headPath = Join-Path $gitItem 'HEAD'
            }
            elseif (Test-Path -PathType Leaf -LiteralPath $gitItem) {
                # Submodule or worktree: .git is a file containing "gitdir: <path>"
                $gitDirLine = (Get-Content -LiteralPath $gitItem -First 1 -ErrorAction SilentlyContinue)
                if ($gitDirLine -match '^gitdir:\s*(.+)$') {
                    $targetDir = $matches[1].Trim()
                    if (-not [System.IO.Path]::IsPathRooted($targetDir)) {
                        $targetDir = [System.IO.Path]::GetFullPath((Join-Path $searchDir $targetDir))
                    }
                    $headPath = Join-Path $targetDir 'HEAD'
                }
            }
        }

        if ($headPath -and (Test-Path -LiteralPath $headPath)) {
            $headTime = [System.IO.File]::GetLastWriteTimeUtc($headPath)
            if ($global:__git_cache_repo -eq $searchDir -and $global:__git_cache_head_time -eq $headTime -and $global:__git_cache_branch) {
                $gitBranch = $global:__git_cache_branch
            }
            else {
                try {
                    $headContent = [System.IO.File]::ReadAllText($headPath).Trim()
                    if ($headContent -match '^ref: refs/heads/(.+)$') {
                        $gitBranch = $matches[1]
                    }
                    elseif ($headContent) {
                        $gitBranch = if ($headContent.Length -ge 7) { ":" + $headContent.Substring(0, 7) } else { $headContent }
                    }
                    else {
                        $gitBranch = (& git branch --show-current 2>$null) -join ''
                    }
                }
                catch {
                    $gitBranch = (& git branch --show-current 2>$null) -join ''
                }

                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $headPath
                $global:__git_cache_head_time = $headTime
                $global:__git_cache_branch = $gitBranch
            }
        }
        else {
            if ($global:__git_cache_repo -ne $searchDir) {
                $global:__git_cache_branch = (& git branch --show-current 2>$null) -join ''
                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $null
                $global:__git_cache_head_time = [datetime]::MinValue
            }
            $gitBranch = $global:__git_cache_branch
        }
    }
    else {
        $global:__git_cache_repo = $null
        $global:__git_cache_head_path = $null
        $global:__git_cache_head_time = [datetime]::MinValue
        $global:__git_cache_branch = ''
    }

    # Expose current git branch ($cb) and repo root ($gr) at zero extra cost
    $global:cb = $gitBranch
    $global:gr = if ($inGitRepo) { $searchDir } else { $null }
    $global:cw = $null
    if ($global:gr -and $gitBranch -and (Get-Command Get-CurrentWorksetName -CommandType Function -ErrorAction SilentlyContinue) -and (Get-PssActiveWorkspace) -eq 'work') {
        try {
            $global:cw = Get-CurrentWorksetName -Root $global:gr -Branch $gitBranch
        }
        catch {
            Write-Warning "Unable to determine current workset: $_"
        }
    }

    # 4. Build Segments
    $segments = [System.Collections.Generic.List[hashtable]]::new()

    # Elevated Admin badge (only if running as Administrator)
    if ($global:__is_admin) {
        $segments.Add(@{ Text = "⚡ ADMIN"; Bg = "DarkRed"; Fg = "Yellow" })
    }

    # Directory segment
    $segments.Add(@{ Text = $currentDir; Bg = "Blue"; Fg = "White" })

    # Python Virtual Environment segment (integrated into the bar)
    if ($env:VIRTUAL_ENV) {
        $venvName = Split-Path $env:VIRTUAL_ENV -Leaf
        $segments.Add(@{ Text = "($venvName)"; Bg = "DarkGreen"; Fg = "White" })
    }

    # Git branch segment (if inside a git repo)
    if ($gitBranch) {
        $segments.Add(@{ Text = $gitBranch; Bg = "DarkMagenta"; Fg = "White" })
    }

    # Command duration timer (if > 500ms)
    if ($durationText) {
        $segments.Add(@{ Text = $durationText; Bg = "DarkYellow"; Fg = "Black" })
    }

    # 5. Render Segments
    Write-Host "`n" -NoNewline
    $currentBg = $null

    foreach ($s in $segments) {
        if (-not $currentBg) {
            Write-Host " $($s.Text) " -BackgroundColor $s.Bg -ForegroundColor $s.Fg -NoNewline
        }
        else {
            Write-Host $arrow -BackgroundColor $s.Bg -ForegroundColor $currentBg -NoNewline
            Write-Host " $($s.Text) " -BackgroundColor $s.Bg -ForegroundColor $s.Fg -NoNewline
        }
        $currentBg = $s.Bg
    }

    Write-Host $arrow -ForegroundColor $currentBg -NoNewline
    Write-Host " ❯" -ForegroundColor $statusColor -NoNewline
    return " "
}
#endregion

#region 7. Workspace & Machine-Local Overrides
$activeWorkspace = Get-PssActiveWorkspace
$workspaceProfile = Join-Path $global:__pss_root "workspaces\$activeWorkspace\powershell\profile.ps1"
if (Test-Path -LiteralPath $workspaceProfile) {
    . $workspaceProfile
}

# Load optional machine-local overrides (never synced)
if (Test-Path -LiteralPath $global:__pss_state.LocalProfile) {
    . $global:__pss_state.LocalProfile
}
#endregion

