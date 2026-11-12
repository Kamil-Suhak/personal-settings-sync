#region 1. Core Environment & Encodings
# Bail out immediately if session is non-interactive or streams are redirected (e.g. AGY, automated agent runners, CI/CD)
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }

# Force UTF-8 console encoding for Powerline glyphs and emojis
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Prevent Python virtualenv from injecting an unstyled line above our prompt
$env:VIRTUAL_ENV_DISABLE_PROMPT = 1

# Cache elevated admin state once at startup to avoid expensive reflection on every prompt render
$global:__is_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Resolve repository root dynamically from this shared profile's location
$global:__pss_root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-PssActiveWorkspace {
    $wsFile = Join-Path $global:__pss_root ".workspace.local"
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

# In-memory branch cache state to eliminate subprocess overhead on prompt
$global:__git_cache_repo = $null
$global:__git_cache_head_path = $null
$global:__git_cache_head_time = [datetime]::MinValue
$global:__git_cache_branch = ''

function Clear-GitBranchCache {
    $global:__git_cache_head_time = [datetime]::MinValue
    $global:__git_cache_branch = ''
}

<#
.SYNOPSIS
Stages all files and creates a commit: git add -A; git commit -m <message>.
#>
function commit {
    if (-not $args) {
        Write-Host "Commit message required: commit <message>" -ForegroundColor Yellow
        return
    }
    git add -A
    git commit -m "$args"
}

<#
.SYNOPSIS
Stages all local changes and amends the latest commit without editing message (or updates message if provided).
#>
function amend {
    $hasCommits = (& git rev-parse --verify HEAD 2>$null)
    if (-not $hasCommits) {
        Write-Host "No commits exist to amend or not in a git repository." -ForegroundColor Yellow
        return
    }

    git add -A
    if ($args) {
        git commit --amend -m "$args"
    } else {
        git commit --amend --no-edit
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Amended latest commit:" -ForegroundColor Green
        git log -1 --oneline
    }
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
    } else {
        git push
    }
}

<#
.SYNOPSIS
Fetches upstream updates from develop (or main) and merges into current branch. Supports -r for rebase and -c for previewing incoming commits.
#>
function catchup {
    param(
        [string]$Base = "develop",
        [Alias("r")][switch]$Rebase,
        [Alias("m")][switch]$Merge,
        [Alias("c")][switch]$Check
    )

    # Support POSIX style flags (--rebase, -r, --merge, -m, --check, -c)
    if ($Base -in @('--rebase', '-rebase', '-r', '/r')) { $Rebase = $true; $Base = "develop" }
    if ($Base -in @('--merge', '-merge', '-m', '/m'))   { $Merge = $true; $Base = "develop" }
    if ($Base -in @('--check', '-check', '-c', '/c'))   { $Check = $true; $Base = "develop" }
    if ($args -contains '--rebase' -or $args -contains '-r') { $Rebase = $true }
    if ($args -contains '--merge' -or $args -contains '-m')   { $Merge = $true }
    if ($args -contains '--check' -or $args -contains '-c')   { $Check = $true }

    Write-Host "Fetching latest origin/$Base..." -ForegroundColor Cyan
    git fetch origin $Base 2>$null
    if ($LASTEXITCODE -ne 0 -and $Base -eq "develop") {
        # Fallback to main if develop doesn't exist
        $Base = "main"
        git fetch origin $Base 2>$null
    }

    $incoming = git log "HEAD..origin/$Base" --oneline -n 10 2>$null
    if (-not $incoming) {
        Write-Host "Already completely up to date with origin/$Base." -ForegroundColor Green
        return
    }

    Write-Host "`nNew commits on origin/${Base}:" -ForegroundColor Yellow
    $incoming | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    if ($Check) { return }

    if ($Rebase) {
        Write-Host "`nRebasing current branch onto origin/$Base (with autostash)..." -ForegroundColor Cyan
        git rebase "origin/$Base" --autostash
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Rebase successful! Note: use 'git push --force-with-lease' if branch was already pushed." -ForegroundColor DarkCyan
        }
    } else {
        Write-Host "`nMerging origin/$Base into current branch..." -ForegroundColor Cyan
        git merge "origin/$Base"
    }

    Clear-GitBranchCache
}

<#
.SYNOPSIS
Safely syncs current git branch with remote: pulls with merge (or -r for rebase), then pushes.
#>
function gsync {
    param([Alias("r")][switch]$Rebase)
    if ($args -contains '--rebase' -or $args -contains '-r') { $Rebase = $true }

    Write-Host "Syncing with remote..." -ForegroundColor Cyan
    if ($Rebase) {
        git pull --rebase --autostash
    } else {
        git pull --no-rebase
    }

    if ($LASTEXITCODE -eq 0) {
        git push
    }

    Clear-GitBranchCache
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

    if ($New) {
        git switch -c $Name
        Clear-GitBranchCache
        return
    }

    $local = (& git branch --list $Name 2>$null) -join ''
    $remote = (& git branch -r --list "*/$Name" 2>$null) -join ''
    $exists = [bool]($local.Trim() -or $remote.Trim())

    if ($exists) {
        git switch $Name
    } else {
        $reply = Read-Host "Branch '$Name' not found. Create it? [Y/n]"
        if ($reply -eq '' -or $reply -match '^[Yy]') {
            git switch -c $Name
        } else {
            Write-Host "Aborted. Branch '$Name' was not created." -ForegroundColor DarkGray
        }
    }

    Clear-GitBranchCache
}

<#
.SYNOPSIS
Creates and switches to a new branch (git switch -c <branch-name>).
#>
function nb ($name) {
    if (-not $name) {
        Write-Host "Branch name required: nb <branch-name>" -ForegroundColor Yellow
        return
    }
    b $name -New
}

<#
.SYNOPSIS
Jumps directly back to main branch (automatically falls back to master if repo uses master).
#>
function main {
    git switch main 2>$null
    if ($LASTEXITCODE -ne 0) { git switch master }
    Clear-GitBranchCache
}

<#
.SYNOPSIS
Safety net: unwinds the last commit while keeping all changes safely staged (git reset --soft HEAD~1).
#>
function undo {
    git reset --soft HEAD~1
    Clear-GitBranchCache
    Write-Host "Undid last commit. Changes remain safely staged." -ForegroundColor Green
}

<#
.SYNOPSIS
Compact, clean 1-line branch and file status (git status -sb).
#>
function st {
    git status -sb
}

<#
.SYNOPSIS
Compact colorized commit graph (git log --graph --oneline). Defaults to 10 commits.
#>
function lg ($count = 10) {
    git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit -n $count
}

<#
.SYNOPSIS
Deletes all local branches that have already been merged into main.
#>
function gbc {
    $merged = git branch --merged main 2>$null | Where-Object { $_ -notmatch 'main|master|\*' }
    if ($merged) {
        $merged | ForEach-Object { git branch -d $_.Trim() }
        Write-Host "Cleaned up merged branches." -ForegroundColor Green
    } else {
        Write-Host "No stale merged branches found." -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
Work In Progress: Stashes staged changes by default, or use -All (-a) to stage and stash all changes including untracked.
#>
function wip {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Message,
        [Alias("a")][switch]$All,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    # Support POSIX style -a / --all
    if ($ExtraArgs -contains '-a' -or $ExtraArgs -contains '--all' -or $Message -in @('-a', '--all')) {
        $All = $true
        $remaining = @($ExtraArgs | Where-Object { $_ -notin @('-a', '--all') })
        if ($Message -in @('-a', '--all')) {
            $Message = if ($remaining.Count -gt 0) { $remaining -join ' ' } else { $null }
        } elseif ($remaining.Count -gt 0) {
            $Message = "$Message $($remaining -join ' ')"
        }
    } elseif ($ExtraArgs.Count -gt 0) {
        $Message = (@($Message) + @($ExtraArgs) | Where-Object { $_ }) -join ' '
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $wipMsg = if ($Message) { "WIP: $Message" } else { "WIP: $timestamp" }

    if ($All) {
        Write-Host "Staging all changes (including untracked)..." -ForegroundColor Cyan
        git add -A
        git stash push -u -m "$wipMsg"
    } else {
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
        } else {
            Write-Host "  $entry"
        }
    }
    Write-Host ""
}

<#
.SYNOPSIS
Jumps to the root directory of the current git repository.
#>
function groot {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($root) {
        Set-Location -LiteralPath $root
    } else {
        Write-Host "Not inside a git repository." -ForegroundColor Yellow
    }
}
#endregion

#region 3. Navigation & Project Switcher

<#
.SYNOPSIS
Go up 1 directory level (Set-Location ..).
#>
function ..   { Set-Location .. }

<#
.SYNOPSIS
Go up 2 directory levels (Set-Location ../..).
#>
function ...  { Set-Location ../.. }

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
        [Alias("a")][switch]$Add,
        [Alias("r", "rm")][switch]$Remove,
        [Alias("l")][switch]$List,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    $rootsFile = Join-Path $HOME ".project-roots"

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

    # Sensible fallbacks if no custom roots configured yet
    if ($roots.Count -eq 0) {
        @("$HOME\Coding\Projects", "$HOME\Coding", "$HOME\Dev", "$HOME\Projects", "$HOME\Documents\Projects") |
            Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object { $roots.Add($_) }
    }

    # 1. List configured roots (p -list or p -l)
    if ($List -or ($Name -in @('-l', '--list', 'list'))) {
        Write-Host "`nConfigured project roots ($rootsFile):" -ForegroundColor Cyan
        if ($roots.Count -eq 0) {
            Write-Host "  No roots found. Use 'p -add <path>' to register one." -ForegroundColor Yellow
        } else {
            $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor Green }
        }
        Write-Host ""
        return
    }

    # 2. Add new project root (p -add [<path>])
    if ($Add -or ($Name -in @('-a', '--add', 'add'))) {
        $candidatePath = if ($ExtraArgs.Count -gt 0) { $ExtraArgs[0] } elseif ($Name -and $Name -notin @('-a', '--add', 'add')) { $Name } else { $null }
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
            Add-Content -LiteralPath $rootsFile -Value $resolved.Path
            Write-Host "Added '$($resolved.Path)' to $rootsFile" -ForegroundColor Green
        } else {
            Write-Host "'$($resolved.Path)' is already in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 3. Remove project root (p -remove [<path>|<index>])
    if ($Remove -or ($Name -in @('-r', '--remove', '-remove', 'remove', '-rm', '--rm', 'rm'))) {
        if (-not (Test-Path -LiteralPath $rootsFile)) {
            Write-Host "`nNo project roots file found ($rootsFile)." -ForegroundColor Yellow
            return
        }

        $lines = @(Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
        if ($lines.Count -eq 0) {
            Write-Host "`nNo project roots configured in $rootsFile." -ForegroundColor Yellow
            return
        }

        $targetToRemove = if ($ExtraArgs.Count -gt 0) { $ExtraArgs[0] } elseif ($Name -and $Name -notin @('-r', '--remove', '-remove', 'remove', '-rm', '--rm', 'rm')) { $Name } else { $null }

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
        } else {
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
            } elseif ($matchedLines.Count -gt 1) {
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
            } else {
                Clear-Content -LiteralPath $rootsFile
            }
            Write-Host "Removed '$match' from $rootsFile" -ForegroundColor Green
        } else {
            Write-Host "Root '$targetToRemove' not found in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 4. If no roots exist at all on machine, prompt interactively
    if ($roots.Count -eq 0) {
        Write-Host "`nNo project directories configured yet." -ForegroundColor Yellow
        $promptPath = Read-Host "Enter your primary projects directory (e.g. ~/Coding/Projects)"
        if ($promptPath) {
            $resolved = Resolve-Path -LiteralPath $promptPath -ErrorAction SilentlyContinue
            if ($resolved) {
                Add-Content -LiteralPath $rootsFile -Value $resolved.Path
                $roots.Add($resolved.Path)
                Write-Host "Saved project root to $rootsFile" -ForegroundColor Green
            }
        }
        if ($roots.Count -eq 0) { return }
    }

    # 5. If invoked without arguments, show roots and usage
    if (-not $Name) {
        Write-Host "`nConfigured project roots:" -ForegroundColor Cyan
        $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
        Write-Host "Usage: p <name> | p -add [<path>] | p -remove [<path>] | p -list`n" -ForegroundColor DarkCyan
        return
    }

    # 6. Search directories across all configured roots
    $target = $roots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$Name*" }
    } | Select-Object -First 1

    if ($target) {
        Set-Location -LiteralPath $target.FullName
    } else {
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
    } catch {
        Write-Error "Path not found: $Path"
    }
}

# Directory history state for 'back' command
$global:__current_location = $pwd.Path
$global:__prev_location = $null

<#
.SYNOPSIS
Creates directory (including nested parents) and navigates into it in one step.
#>
function mkcd {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )
    $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
    Set-Location -LiteralPath $Path
}

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
        [Alias("h")][switch]$Help,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    if ($ExtraArgs -contains '--help' -or $ExtraArgs -contains '-help') {
        $Help = $true
    }

    $cyan = if ($PSStyle) { $PSStyle.Foreground.Cyan } else { "" }
    $yellow = if ($PSStyle) { $PSStyle.Foreground.Yellow } else { "" }
    $green = if ($PSStyle) { $PSStyle.Foreground.Green } else { "" }
    $gray = if ($PSStyle) { $PSStyle.Foreground.BrightBlack } else { "" }
    $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }

    # Special Profile Inspection Mode: which profile [-h] | which -profile [-h]
    $isProfile = $Profile -or ($Name -in @('profile', '$profile', '-profile', '--profile'))
    if ($isProfile) {
        $targetProfile = Join-Path $PSScriptRoot "Microsoft.PowerShell_profile.ps1"
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
                Where-Object { $_.Name -notmatch '^(prompt|Clear-GitBranchCache|Get-PssActiveWorkspace|Get-TerminalAskContext|Invoke-)' }

            if ($funcAsts.Count -eq 0) { return }
            Write-Host "${yellow}${Heading} ($($funcAsts.Count)):${reset}`n"
            $maxLen = ($funcAsts | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
            $pad = [math]::Max($maxLen + 2, 12)
            foreach ($f in $funcAsts) {
                $h = $f.GetHelpContent()
                $syn = if ($h -and $h.Synopsis) {
                    $h.Synopsis.Trim()
                } else {
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
            'Alias'       { return $cmd.Definition }
            Default       {
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
            } elseif ($PROFILE) {
                $PROFILE.ToString()
            } else {
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
                } else {
                    Write-Host "  ${gray}(No built-in --help or /? documentation returned)${reset}"
                }
            } catch {
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
    } else {
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
    } else {
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
        } catch {}
    }
    return $results
}

<#
.SYNOPSIS
Interactive fuzzy file finder. Uses git index acceleration inside git repositories, falls back to .NET file walker, copies selected path to clipboard, and optionally opens in VS Code with -o/--open.
#>
function find {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Alias("o")]
        [switch]$Open,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    # Support POSIX style flags (--open, -o)
    if ($Path -in @('--open', '-open', '-o')) { $Open = $true; $Path = "." }
    if ($ExtraArgs -contains '--open' -or $ExtraArgs -contains '-open' -or $ExtraArgs -contains '-o') { $Open = $true }

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
    } else {
        Write-Host "Action cancelled. Nothing copied." -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
Compares SHA-256 hashes of two files to verify whether their contents are identical.
#>
function cmp {
    param (
        [string]$file1,
        [string]$file2
    )
    if (-not (Test-Path $file1)) {
        Write-Host "File not found: $file1" -ForegroundColor Red
        return
    }
    if (-not (Test-Path $file2)) {
        Write-Host "File not found: $file2" -ForegroundColor Red
        return
    }
    if ((Get-FileHash $file1).Hash -eq (Get-FileHash $file2).Hash) {
        Write-Host "Files are identical." -ForegroundColor Green
    } else {
        Write-Host "Files differ." -ForegroundColor Red
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
        [switch]$FilesOnly,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    begin {
        if (-not $Pattern) {
            Write-Host "Usage: findstr <pattern> [<path>] [-v|--invert] [-c|--case] [-l|--files-only]" -ForegroundColor Yellow
            return
        }

        # Support POSIX-style flags
        if ($Path -in @('--invert', '-invert', '-v')) { $Invert = $true; $Path = "." }
        elseif ($Path -in @('--case', '-case', '-c')) { $CaseSensitive = $true; $Path = "." }
        elseif ($Path -in @('--files-only', '-files-only', '-l')) { $FilesOnly = $true; $Path = "." }

        if ($ExtraArgs -contains '--invert' -or $ExtraArgs -contains '-invert' -or $ExtraArgs -contains '-v') { $Invert = $true }
        if ($ExtraArgs -contains '--case' -or $ExtraArgs -contains '-case' -or $ExtraArgs -contains '-c') { $CaseSensitive = $true }
        if ($ExtraArgs -contains '--files-only' -or $ExtraArgs -contains '-files-only' -or $ExtraArgs -contains '-l') { $FilesOnly = $true }

        $regexOptions = if ($CaseSensitive) {
            [System.Text.RegularExpressions.RegexOptions]::None
        } else {
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        }

        try {
            $regex = [regex]::new($Pattern, $regexOptions)
        } catch {
            $regex = [regex]::new([regex]::Escape($Pattern), $regexOptions)
        }

        $isPiped = $PSCmdlet.MyInvocation.ExpectingInput
    }

    process {
        if ($isPiped -and $null -ne $InputObject) {
            $line = $InputObject.ToString()
            $matched = $regex.IsMatch($line)
            if (($matched -and -not $Invert) -or (-not $matched -and $Invert)) {
                $line
            }
        }
    }

    end {
        if ($isPiped -or -not $Pattern) { return }

        $cyan = if ($PSStyle) { $PSStyle.Foreground.Cyan } else { "" }
        $yellow = if ($PSStyle) { $PSStyle.Foreground.Yellow } else { "" }
        $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }

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
                } else {
                    foreach ($line in $results) {
                        if ($line -match '^([^:]+):(\d+):(.*)$') {
                            "${cyan}$($matches[1])${reset}:${yellow}$($matches[2])${reset}: $($matches[3])"
                        } else {
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
            } catch { continue }

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
                    } else {
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

# Clipboard shortcuts
Set-Alias -Name copy -Value Set-Clipboard -Option AllScope -Force
Set-Alias -Name paste -Value Get-Clipboard -Option AllScope -Force

<#
.SYNOPSIS
Decodes a JWT header and payload offline without making any network calls. Supports arguments or pipeline input.
#>
function jwt {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string]$Token
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Token)) { return }
        $raw = $Token.Trim() -replace '^Bearer\s+', ''
        $parts = $raw -split '\.'
        if ($parts.Count -lt 2) {
            Write-Error "Invalid JWT format (expected header.payload[.signature])."
            return
        }

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
        } catch {
            Write-Error "Failed to decode JWT: $($_.Exception.Message)"
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
    $green = if ($PSStyle) { $PSStyle.Foreground.Green } else { "" }
    $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }
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
    } finally {
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
    } else { "" }

    $promptQuestion = if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $Question
    } else {
        "Analyze or answer based on the piped input above."
    }

    if ($Clean) {
        $historyCmds = "<empty>"
        $recentOutput = "<empty>"
    } else {
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
        } catch {
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
    } finally {
        if ($proc) {
            if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
            $proc.Dispose()
        }
    }

    $cyan = if ($PSStyle) { $PSStyle.Foreground.Cyan } else { "" }
    $gray = if ($PSStyle) { $PSStyle.Foreground.BrightBlack } else { "" }
    $red = if ($PSStyle) { $PSStyle.Foreground.Red } else { "" }
    $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }

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
        } else {
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
        } finally {
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
            "no"  { "Red" }
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
Set-Alias -Name decision -Value decide -Option AllScope -Force

<#
.SYNOPSIS
Personal Settings Sync CLI runner (pss.ps1).
#>
function pss {
    $pssScript = Join-Path $global:__pss_root "pss.ps1"
    if (Test-Path -LiteralPath $pssScript) {
        & $pssScript @args
    } else {
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
        Set-PSReadLineKeyHandler -Key "RightArrow" -Function AcceptNextSuggestionWord -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "F2" -Function SwitchPredictionView -ErrorAction SilentlyContinue
    } catch {
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

    # 1. Timer Logic (renders only if execution > 500ms)
    $durationText = ""
    $lastCommand = Get-History -Count 1 -ErrorAction SilentlyContinue
    if ($lastCommand) {
        $duration = $lastCommand.EndExecutionTime - $lastCommand.StartExecutionTime
        if ($duration.TotalMilliseconds -gt 500) {
            if ($duration.TotalMinutes -ge 1) {
                $durationText = " ⏱ {0:N0}m {1:N0}s " -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
            } else {
                $durationText = " ⏱ {0:N1}s " -f $duration.TotalSeconds
            }
        }
    }

    # 2. Directory Logic (2-tier path to eliminate folder ambiguity)
    $normalizedPath = $pwd.Path -replace ('^' + [regex]::Escape($HOME)), '~'
    if ($normalizedPath -eq '~') {
        $currentDir = '~'
    } else {
        $segments = $normalizedPath.TrimEnd('\', '/') -split '[\\/]'
        if ($segments.Count -ge 2) {
            $currentDir = "$($segments[-2])/$($segments[-1])"
        } else {
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
        } else {
            if (Test-Path -PathType Container -LiteralPath $gitItem) {
                $headPath = Join-Path $gitItem 'HEAD'
            } elseif (Test-Path -PathType Leaf -LiteralPath $gitItem) {
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
            } else {
                try {
                    $headContent = [System.IO.File]::ReadAllText($headPath).Trim()
                    if ($headContent -match '^ref: refs/heads/(.+)$') {
                        $gitBranch = $matches[1]
                    } elseif ($headContent) {
                        $gitBranch = if ($headContent.Length -ge 7) { ":" + $headContent.Substring(0, 7) } else { $headContent }
                    } else {
                        $gitBranch = (& git branch --show-current 2>$null) -join ''
                    }
                } catch {
                    $gitBranch = (& git branch --show-current 2>$null) -join ''
                }

                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $headPath
                $global:__git_cache_head_time = $headTime
                $global:__git_cache_branch = $gitBranch
            }
        } else {
            if ($global:__git_cache_repo -ne $searchDir) {
                $global:__git_cache_branch = (& git branch --show-current 2>$null) -join ''
                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $null
                $global:__git_cache_head_time = [datetime]::MinValue
            }
            $gitBranch = $global:__git_cache_branch
        }
    } else {
        $global:__git_cache_repo = $null
        $global:__git_cache_head_path = $null
        $global:__git_cache_head_time = [datetime]::MinValue
        $global:__git_cache_branch = ''
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
        } else {
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

# Load optional machine-local overrides (git-ignored, never synced)
$localCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[void]$localCandidates.Add((Join-Path $HOME ".profile.local.ps1"))
if ($PROFILE) {
    [void]$localCandidates.Add((Join-Path (Split-Path -Parent $PROFILE) ".profile.local.ps1"))
}
foreach ($localFile in $localCandidates) {
    if (Test-Path -LiteralPath $localFile) {
        . $localFile
    }
}
#endregion

