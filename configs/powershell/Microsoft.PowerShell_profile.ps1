#region 1. Core Environment & Encodings
if (-not [Environment]::UserInteractive) { return }

# Force UTF-8 console encoding for Powerline glyphs and emojis
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Prevent Python virtualenv from injecting an unstyled line above our prompt
$env:VIRTUAL_ENV_DISABLE_PROMPT = 1
#endregion

#region 2. Git Automation & Workflows

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
Pushes commits to remote. If message is passed, stages and commits first. Automatically sets upstream tracking on new branches.
#>
function push {
    $branch = (& git branch --show-current 2>$null) -join ''
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
Fetches upstream updates from develop (or main) and rebases with autostash. Supports -m for merge and -c for previewing incoming commits.
#>
function catchup {
    param(
        [string]$Base = "develop",
        [Alias("m")][switch]$Merge,
        [Alias("c")][switch]$Check
    )

    # Support POSIX style flags (--merge, -m, --check, -c)
    if ($Base -in @('--merge', '-merge', '-m', '/m')) { $Merge = $true; $Base = "develop" }
    if ($Base -in @('--check', '-check', '-c', '/c')) { $Check = $true; $Base = "develop" }
    if ($args -contains '--merge' -or $args -contains '-m') { $Merge = $true }
    if ($args -contains '--check' -or $args -contains '-c') { $Check = $true }

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

    if ($Merge) {
        Write-Host "`nMerging origin/$Base into current branch..." -ForegroundColor Cyan
        git merge "origin/$Base"
    } else {
        Write-Host "`nRebasing current branch onto origin/$Base (with autostash)..." -ForegroundColor Cyan
        git rebase "origin/$Base" --autostash
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Rebase successful! Note: use 'git push --force-with-lease' if branch was already pushed." -ForegroundColor DarkCyan
        }
    }
}

<#
.SYNOPSIS
Safely syncs current branch with remote: pulls with rebase and autostash, then pushes.
#>
function sync {
    Write-Host "Syncing with remote..." -ForegroundColor Cyan
    git pull --rebase --autostash
    if ($LASTEXITCODE -eq 0) {
        git push
    }
}

<#
.SYNOPSIS
Switches to branch, or lists your 10 most recently active branches if no argument is passed.
#>
function b ($name) {
    if (-not $name) {
        Write-Host "Recent branches:" -ForegroundColor Cyan
        git branch --sort=-committerdate | Select-Object -First 10
        return
    }
    git checkout $name
}

<#
.SYNOPSIS
Creates and switches to a new branch: git checkout -b <branch-name>.
#>
function nb ($name) {
    if (-not $name) {
        Write-Host "Branch name required: nb <branch-name>" -ForegroundColor Yellow
        return
    }
    git checkout -b $name
}

<#
.SYNOPSIS
Jumps directly back to main branch (automatically falls back to master if repo uses master).
#>
function main {
    git checkout main 2>$null
    if ($LASTEXITCODE -ne 0) { git checkout master }
}

<#
.SYNOPSIS
Safety net: unwinds the last commit while keeping all changes safely staged (git reset --soft HEAD~1).
#>
function undo {
    git reset --soft HEAD~1
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
Universal Project Jumper: searches configured project roots in ~/.project-roots and jumps to matching project directory. Supports -add and -list.
#>
function p {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Alias("a")][switch]$Add,
        [Alias("l")][switch]$List
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
        $candidatePath = if ($args.Count -gt 0) { $args[0] } elseif ($Name -and $Name -notin @('-a', '--add', 'add')) { $Name } else { $null }
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

    # 3. If no roots exist at all on machine, prompt interactively
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

    # 4. If invoked without arguments, show roots and usage
    if (-not $Name) {
        Write-Host "`nConfigured project roots:" -ForegroundColor Cyan
        $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
        Write-Host "Usage: p <name> | p -add [<path>] | p -list`n" -ForegroundColor DarkCyan
        return
    }

    # 5. Search directories across all configured roots
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
#endregion

#region 4. Development & System Helpers

<#
.SYNOPSIS
Locates commands. By default prints path; with -m shows description/short manual; with -f shows full manual.
#>
function which {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,
        [Alias("m")][switch]$Man,
        [Alias("f")][switch]$Full
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Error "Command '$Name' not found."
        return
    }

    $showMan = $Man -or $Full
    if (-not $showMan) {
        switch ($cmd.CommandType) {
            'Application' { return $cmd.Source }
            'Alias'       { return $cmd.Definition }
            { $_ -in 'Function', 'Filter' } { return $cmd.Definition }
            Default       { return (if ($cmd.Source) { $cmd.Source } else { $cmd.Name }) }
        }
    }

    $cyan = if ($PSStyle) { $PSStyle.Foreground.Cyan } else { "" }
    $yellow = if ($PSStyle) { $PSStyle.Foreground.Yellow } else { "" }
    $green = if ($PSStyle) { $PSStyle.Foreground.Green } else { "" }
    $gray = if ($PSStyle) { $PSStyle.Foreground.BrightBlack } else { "" }
    $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }

    Write-Host "`n${cyan}=== [$($cmd.CommandType.ToString().ToUpper())] $($cmd.Name) ===${reset}"

    switch ($cmd.CommandType) {
        { $_ -in 'Function', 'Filter' } {
            $help = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($help.Synopsis -and $help.Synopsis -ne $cmd.Name) {
                Write-Host "${yellow}Description:${reset}`n  $($help.Synopsis)`n"
            }
            Write-Host "${yellow}Source Definition:${reset}"
            $lines = $cmd.Definition.Trim() -split "`r?`n"
            foreach ($line in $lines) { Write-Host "  ${gray}$line${reset}" }
        }
        'Alias' {
            Write-Host "${yellow}Alias Target:${reset} ${green}$($cmd.Definition)${reset}`n"
            which $cmd.Definition -Man:$Man -Full:$Full
        }
        'Application' {
            Write-Host "${yellow}Path:${reset}    ${green}$($cmd.Source)${reset}"
            if (Test-Path -LiteralPath $cmd.Source) {
                $ver = (Get-Item -LiteralPath $cmd.Source).VersionInfo
                if ($ver.FileVersion) { Write-Host "${yellow}Version:${reset} ${gray}$($ver.FileVersion)${reset}" }
            }
            Write-Host "`n${yellow}Manual / Usage Help (POSIX-style):${reset}"
            try {
                $helpOutput = ($null | & $cmd.Source --help 2>&1)
                if ($LASTEXITCODE -ne 0 -or -not $helpOutput) {
                    $helpOutput = ($null | & $cmd.Source /? 2>&1)
                }
                if ($helpOutput) {
                    $lines = @($helpOutput)
                    $limit = if ($Full) { $lines.Count } else { 25 }
                    $lines | Select-Object -First $limit | ForEach-Object { Write-Host "  $_" }
                    if (-not $Full -and $lines.Count -gt $limit) {
                        Write-Host "`n  ${gray}... [truncated, showing 25 of $($lines.Count) lines. Use 'which $Name -f' for complete manual]${reset}"
                    }
                } else {
                    Write-Host "  ${gray}(No built-in --help or /? documentation returned)${reset}"
                }
            } catch {
                Write-Host "  ${gray}Could not execute help: $_${reset}"
            }
        }
        'Cmdlet' {
            Write-Host "${yellow}Module:${reset}  ${green}$($cmd.ModuleName)${reset}"
            $help = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($help.Synopsis) { Write-Host "`n${yellow}Synopsis:${reset}`n  $($help.Synopsis)" }
            if ($help.Syntax) {
                Write-Host "`n${yellow}Syntax:${reset}"
                ($help.Syntax | Out-String).Trim() | ForEach-Object { Write-Host "  ${gray}$_${reset}" }
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
Finds and kills whatever process is occupying a local TCP port (e.g. killport 5000).
#>
function killport ($port) {
    $connections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($connections) {
        $pids = $connections.OwningProcess | Select-Object -Unique
        Stop-Process -Id $pids -Force
        Write-Host "Terminated process(es) on port ${port}: $($pids -join ', ')" -ForegroundColor Green
        } else {
        Write-Host "No active process listening on port ${port}." -ForegroundColor Yellow
    }
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
Interactive fuzzy file finder. Excludes junk folders, copies selected file path to clipboard, and optionally opens in VS Code with -o/--open.
#>
function find {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Alias("o")]
        [switch]$Open
    )

    # Support POSIX style flags (--open, -o)
    if ($Path -in @('--open', '-open', '-o')) { $Open = $true; $Path = "." }
    if ($args -contains '--open' -or $args -contains '-o') { $Open = $true }

    $cleanedTokens = $Name -split '[\s-_.]+' | Where-Object { $_ }
    $regexPattern = ($cleanedTokens | ForEach-Object { [regex]::Escape($_) }) -join '.?'
    $nameRegex = [regex]::new($regexPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $foundFiles = @(
        Get-SearchableFiles -Path $Path |
        Where-Object { $nameRegex.IsMatch($_.Name) } |
        Select-Object FullName, Name, DirectoryName
    )

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
        [switch]$FilesOnly
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

        if ($args -contains '--invert' -or $args -contains '-v') { $Invert = $true }
        if ($args -contains '--case' -or $args -contains '-c') { $CaseSensitive = $true }
        if ($args -contains '--files-only' -or $args -contains '-l') { $FilesOnly = $true }

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

        $binaryExts = @('.exe', '.dll', '.pdb', '.zip', '.tar', '.gz', '.7z', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.woff', '.woff2', '.ttf')
        $currentDir = (Get-Location).Path.TrimEnd('\', '/')

        $files = Get-SearchableFiles -Path $Path -ExcludeExtensions $binaryExts

        $cyan = if ($PSStyle) { $PSStyle.Foreground.Cyan } else { "" }
        $yellow = if ($PSStyle) { $PSStyle.Foreground.Yellow } else { "" }
        $reset = if ($PSStyle) { $PSStyle.Reset } else { "" }
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
    $normalizedPath = $pwd.Path.Replace($HOME, '~')
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

    # 3. Fast Git Logic (only runs git if .git is detected in folder hierarchy)
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
        $gitBranch = (& git branch --show-current 2>$null) -join ''
    }

    # 4. Build Segments
    $segments = [System.Collections.Generic.List[hashtable]]::new()

    # Elevated Admin badge (only if running as Administrator)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
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

#region 7. Machine-Local Custom Overrides
# Load optional machine-local configuration (git-ignored, never synced)
$localProfile = Join-Path (Split-Path -Parent $PROFILE) ".profile.local.ps1"
if (Test-Path -LiteralPath $localProfile) {
    . $localProfile
}
#endregion

