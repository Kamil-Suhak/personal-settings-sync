<#
.SYNOPSIS
    Personal Settings Sync - Automate applying and backing up developer settings and apps.

.DESCRIPTION
    Synchronizes configurations between this repository and local system paths.
    Supports copy-based synchronization, symbolic links, and Winget app management.

.PARAMETER Action
    The action to execute:
      - status  : Check sync state and display differences table (default)
      - apply   : Deploy settings from repository to this machine (repo -> local)
      - export  : Harvest current settings from machine into repository (local -> repo)
      - diff    : Show detailed diff for modified files
      - link    : Create symbolic links (local -> repo) for live continuous sync
      - apps    : Manage applications via Winget (list, install, update)
      - setup   : Apply run-once Windows developer settings and Explorer tweaks
      - help    : Show help message

.PARAMETER SubAction
    Optional target: App name (e.g. 'vscode') or apps subaction ('install', 'update', 'list').

.PARAMETER Install
    Flag for apps action: install all configured packages via Winget.

.PARAMETER Update
    Flag for apps action: update all installed packages via Winget.

.PARAMETER Pull
    Pull latest changes from git remote before applying.

.PARAMETER Push
    Commit and push changes to git remote after exporting.

.PARAMETER SyncExtensions
    Export or install VS Code extensions list (configs/vscode/extensions.txt).

.PARAMETER Force
    Overwrite files without asking for confirmation.

.PARAMETER WhatIf
    Simulate actions without modifying any files.

.PARAMETER NoBackup
    Skip creating backups of local files before applying repo settings.

.EXAMPLE
    .\sync.ps1 status
    .\sync.ps1 apply
    .\sync.ps1 apply -Pull
    .\sync.ps1 export
    .\sync.ps1 export -Push
    .\sync.ps1 diff
    .\sync.ps1 apps
    .\sync.ps1 apps -Install
    .\sync.ps1 apps -Update
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'export', 'diff', 'link', 'apps', 'setup', 'tweaks', 'help')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$SubAction,

    [string]$App,
    [switch]$Install,
    [switch]$Update,
    [switch]$Pull,
    [switch]$Push,
    [switch]$SyncExtensions,
    [switch]$Force,
    [switch]$WhatIf,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir 'sync.config.json'

function Write-Badge {
    param(
        [string]$Badge,
        [ConsoleColor]$BadgeColor,
        [string]$Message,
        [ConsoleColor]$MessageColor = [ConsoleColor]::White
    )
    Write-Host "[$Badge] " -ForegroundColor $BadgeColor -NoNewline
    Write-Host $Message -ForegroundColor $MessageColor
}

function Test-PathSafe {
    param(
        [string]$Path,
        [string]$PathType = 'Leaf'
    )
    try {
        return (Test-Path -LiteralPath $Path -PathType $PathType -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Resolve-DynamicPath {
    param([string]$PathPattern)

    $resolved = $PathPattern
    $docFolder = [Environment]::GetFolderPath('MyDocuments')
    $resolved = $resolved.Replace('$DOCUMENTS', $docFolder)

    # Expand environment variables (%APPDATA%, %USERPROFILE%, %LOCALAPPDATA%, etc.)
    $resolved = [Environment]::ExpandEnvironmentVariables($resolved)

    try {
        $resolved = [System.IO.Path]::GetFullPath($resolved)
    } catch {
        # Fallback if GetFullPath cannot resolve yet
    }
    return $resolved
}

function Get-FileHashSafe {
    param([string]$Path)
    try {
        if (Test-PathSafe $Path -PathType Leaf) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
    } catch {
        return $null
    }
    return $null
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $localWinApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-PathSafe $localWinApps -PathType Leaf) {
        return $localWinApps
    }
    return $null
}

if ($Action -eq 'help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

if (-not (Test-PathSafe $ConfigFile -PathType Leaf)) {
    Write-Badge "ERROR" Red "Configuration file not found at: $ConfigFile"
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json

# Resolve target app if specified via $App or positional $SubAction
$targetApp = if ($App) { $App } elseif ($Action -ne 'apps' -and $SubAction) { $SubAction } else { $null }
$AppsToProcess = $Config.apps
if ($targetApp) {
    $AppsToProcess = $Config.apps | Where-Object { $_.name -ieq $targetApp }
    if (-not $AppsToProcess) {
        Write-Badge "ERROR" Red "App '$targetApp' not found in sync.config.json. Available: $(($Config.apps.name) -join ', ')"
        exit 1
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $ScriptDir ".backups\$timestamp"

# Pull first if requested
if ($Pull) {
    Write-Host "`n=== Pulling Latest Changes From Git ===" -ForegroundColor Cyan
    try {
        git pull
    } catch {
        Write-Badge "WARN" Yellow "git pull encountered a problem: $($_.Exception.Message)"
    }
}

switch ($Action) {
    'status' {
        Write-Host "`n=== Personal Settings Sync Status ===" -ForegroundColor Cyan
        $results = @()

        foreach ($appEntry in $AppsToProcess) {
            foreach ($file in $appEntry.files) {
                $repoFullPath = Join-Path $ScriptDir $file.repoPath
                $localFullPath = Resolve-DynamicPath $file.localPath

                $repoExists = Test-PathSafe $repoFullPath -PathType Leaf
                $localExists = Test-PathSafe $localFullPath -PathType Leaf

                $statusText = "Unknown"
                if (-not $repoExists -and -not $localExists) {
                    $statusText = "Missing Both"
                } elseif (-not $repoExists) {
                    $statusText = "Missing in Repo"
                } elseif (-not $localExists) {
                    $statusText = "Missing on Machine"
                } else {
                    $repoHash = Get-FileHashSafe $repoFullPath
                    $localHash = Get-FileHashSafe $localFullPath

                    if ($repoHash -and ($repoHash -eq $localHash)) {
                        $statusText = "In Sync"
                    } else {
                        try {
                            $repoTime = (Get-Item -LiteralPath $repoFullPath -ErrorAction SilentlyContinue).LastWriteTime
                            $localTime = (Get-Item -LiteralPath $localFullPath -ErrorAction SilentlyContinue).LastWriteTime
                            if ($repoTime -and $localTime -and ($repoTime -gt $localTime)) {
                                $statusText = "Repo Newer"
                            } else {
                                $statusText = "Machine Newer"
                            }
                        } catch {
                            $statusText = "Modified"
                        }
                    }
                }

                $results += [PSCustomObject]@{
                    App       = $appEntry.displayName
                    File      = Split-Path -Leaf $file.repoPath
                    Status    = $statusText
                    RepoPath  = $file.repoPath
                    LocalPath = $localFullPath
                }
            }
        }

        $results | Format-Table -Property App, File, Status, LocalPath -AutoSize

        Write-Host "Workflows:" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 apply [-Pull]   -> Overwrite machine settings with repo settings" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 export [-Push]  -> Copy machine settings into repository" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 diff            -> View differences for modified files" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 apps -Install   -> Install standard apps via Winget" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 apps -Update    -> Upgrade all installed apps via Winget`n" -ForegroundColor DarkGray
    }

    'apply' {
        Write-Host "`n=== Applying Settings (Repo -> Machine) ===" -ForegroundColor Cyan
        $appliedCount = 0

        foreach ($appEntry in $AppsToProcess) {
            Write-Host "`n[$($appEntry.displayName)]" -ForegroundColor Yellow

            foreach ($file in $appEntry.files) {
                $repoFullPath = Join-Path $ScriptDir $file.repoPath
                $localFullPath = Resolve-DynamicPath $file.localPath

                if (-not (Test-PathSafe $repoFullPath -PathType Leaf)) {
                    if ($file.required) {
                        Write-Badge "WARN" Yellow "Repo file missing: $($file.repoPath)"
                    }
                    continue
                }

                $localExists = Test-PathSafe $localFullPath -PathType Leaf
                $repoHash = Get-FileHashSafe $repoFullPath
                $localHash = if ($localExists) { Get-FileHashSafe $localFullPath } else { $null }

                if ($localExists -and $repoHash -and ($repoHash -eq $localHash)) {
                    Write-Badge "OK" DarkGray "Already in sync: $($file.repoPath)"
                    continue
                }

                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would deploy $($file.repoPath) -> $localFullPath"
                    continue
                }

                # Backup existing local file before overwriting
                if ($localExists -and -not $NoBackup) {
                    $fileBackupPath = Join-Path $backupDir $file.repoPath
                    $fileBackupDir = Split-Path -Parent $fileBackupPath
                    if (-not (Test-PathSafe $fileBackupDir -PathType Container)) {
                        [System.IO.Directory]::CreateDirectory($fileBackupDir) | Out-Null
                    }
                    Copy-Item -LiteralPath $localFullPath -Destination $fileBackupPath -Force
                    Write-Badge "BACKUP" DarkCyan "Backed up current local file to: .backups\$timestamp\$($file.repoPath)"
                }

                # Ensure target directory exists
                $targetDir = Split-Path -Parent $localFullPath
                if (-not (Test-PathSafe $targetDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
                }

                Copy-Item -LiteralPath $repoFullPath -Destination $localFullPath -Force
                Write-Badge "APPLIED" Green "$($file.repoPath) -> $localFullPath"
                $appliedCount++
            }
        }

        # Handle VS Code extensions install if requested or file exists
        $extFile = Join-Path $ScriptDir "configs\vscode\extensions.txt"
        if ($SyncExtensions -and (Test-PathSafe $extFile -PathType Leaf)) {
            Write-Host "`n[VS Code Extensions]" -ForegroundColor Yellow
            if (Get-Command code -ErrorAction SilentlyContinue) {
                Get-Content $extFile | Where-Object { $_ -match '\S' } | ForEach-Object {
                    Write-Host "Installing extension: $_" -ForegroundColor Cyan
                    code --install-extension $_ --force
                }
            } else {
                Write-Badge "WARN" Yellow "'code' command not found in PATH; skipping extension install."
            }
        }

        if (-not $WhatIf) {
            Write-Host "`nDone. Successfully applied $appliedCount file(s)." -ForegroundColor Green
            if ($appliedCount -gt 0 -and -not $NoBackup) {
                Write-Host "Backups preserved in: $backupDir" -ForegroundColor DarkGray
            }
        }
    }

    'export' {
        Write-Host "`n=== Exporting Settings (Machine -> Repo) ===" -ForegroundColor Cyan
        $exportedCount = 0

        foreach ($appEntry in $AppsToProcess) {
            Write-Host "`n[$($appEntry.displayName)]" -ForegroundColor Yellow

            foreach ($file in $appEntry.files) {
                $repoFullPath = Join-Path $ScriptDir $file.repoPath
                $localFullPath = Resolve-DynamicPath $file.localPath

                if (-not (Test-PathSafe $localFullPath -PathType Leaf)) {
                    if ($file.required) {
                        Write-Badge "MISSING" DarkYellow "Local file does not exist: $localFullPath"
                    }
                    continue
                }

                $repoExists = Test-PathSafe $repoFullPath -PathType Leaf
                $localHash = Get-FileHashSafe $localFullPath
                $repoHash = if ($repoExists) { Get-FileHashSafe $repoFullPath } else { $null }

                if ($repoExists -and $localHash -and ($repoHash -eq $localHash)) {
                    Write-Badge "OK" DarkGray "Already in sync: $localFullPath"
                    continue
                }

                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would export $localFullPath -> $($file.repoPath)"
                    continue
                }

                $repoFileDir = Split-Path -Parent $repoFullPath
                if (-not (Test-PathSafe $repoFileDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($repoFileDir) | Out-Null
                }

                Copy-Item -LiteralPath $localFullPath -Destination $repoFullPath -Force
                Write-Badge "EXPORTED" Green "$localFullPath -> $($file.repoPath)"
                $exportedCount++
            }
        }

        # Export VS Code extensions if requested
        if ($SyncExtensions) {
            Write-Host "`n[VS Code Extensions]" -ForegroundColor Yellow
            if (Get-Command code -ErrorAction SilentlyContinue) {
                $extFile = Join-Path $ScriptDir "configs\vscode\extensions.txt"
                $extDir = Split-Path -Parent $extFile
                if (-not (Test-PathSafe $extDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($extDir) | Out-Null
                }
                code --list-extensions | Out-File -FilePath $extFile -Encoding utf8
                Write-Badge "EXPORTED" Green "Exported installed extensions -> configs/vscode/extensions.txt"
                $exportedCount++
            } else {
                Write-Badge "WARN" Yellow "'code' command not found in PATH; skipping extension export."
            }
        }

        if (-not $WhatIf) {
            Write-Host "`nDone. Successfully exported $exportedCount file(s) into repository." -ForegroundColor Green
            Write-Host "Review changes with 'git status' and 'git diff'." -ForegroundColor Yellow
        }

        # Push if requested
        if ($Push -and -not $WhatIf) {
            Write-Host "`n=== Pushing Changes to Git Remote ===" -ForegroundColor Cyan
            git add configs sync.config.json winget-packages.json
            $commitMsg = "sync: update settings from $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
            git commit -m $commitMsg
            git push
            Write-Badge "PUSHED" Green "Committed and pushed to GitHub."
        }
    }

    'diff' {
        Write-Host "`n=== Comparing Repository vs Local Files ===" -ForegroundColor Cyan
        $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

        foreach ($appEntry in $AppsToProcess) {
            foreach ($file in $appEntry.files) {
                $repoFullPath = Join-Path $ScriptDir $file.repoPath
                $localFullPath = Resolve-DynamicPath $file.localPath

                $repoExists = Test-PathSafe $repoFullPath -PathType Leaf
                $localExists = Test-PathSafe $localFullPath -PathType Leaf

                if (-not $repoExists -or -not $localExists) {
                    continue
                }

                $repoHash = Get-FileHashSafe $repoFullPath
                $localHash = Get-FileHashSafe $localFullPath

                if ($repoHash -ne $localHash) {
                    Write-Host "`n--- Diff for $($appEntry.displayName) ($($file.repoPath)) ---" -ForegroundColor Magenta
                    if ($hasGit) {
                        git diff --no-index --color $localFullPath $repoFullPath
                    } else {
                        $localLines = Get-Content -LiteralPath $localFullPath
                        $repoLines = Get-Content -LiteralPath $repoFullPath
                        Compare-Object -ReferenceObject $localLines -DifferenceObject $repoLines | Format-Table -AutoSize
                    }
                }
            }
        }
    }

    'apps' {
        $wingetCmd = Get-WingetPath
        $doInstall = $Install -or ($SubAction -ieq 'install')
        $doUpdate  = $Update -or ($SubAction -ieq 'update')

        if (-not $Config.packages) {
            Write-Badge "WARN" Yellow "No packages defined in sync.config.json."
            return
        }

        if ($doInstall) {
            Write-Host "`n=== Installing Configured Applications (Winget) ===" -ForegroundColor Cyan
            if (-not $wingetCmd -and -not $WhatIf) {
                Write-Badge "ERROR" Red "Winget not found. Ensure 'App Installer' is installed from the Microsoft Store."
                exit 1
            }

            foreach ($pkg in $Config.packages) {
                $packageId = $pkg.id
                if ($packageId -in @('Python.Latest', 'Python.Python.Latest', 'Python.Python.3')) {
                    if ($wingetCmd) {
                        try {
                            $found = & $wingetCmd search --id Python.Python.3 --source winget 2>$null | Select-String 'Python\.Python\.(3\.\d+)'
                            if ($found) {
                                $latestVersion = $found | ForEach-Object { [version]($_.Matches.Groups[1].Value) } | Sort-Object -Descending | Select-Object -First 1
                                if ($latestVersion) {
                                    $packageId = "Python.Python.$latestVersion"
                                }
                            }
                        } catch {}
                    }
                    if ($packageId -like '*Latest*') {
                        $packageId = 'Python.Python.3.13'
                    }
                }

                Write-Host "`n--> Installing $($pkg.name) ($packageId)..." -ForegroundColor Cyan
                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would run: winget install --id $packageId -e --accept-package-agreements --accept-source-agreements"
                    continue
                }

                & $wingetCmd install --id $packageId -e --accept-package-agreements --accept-source-agreements
            }
            if (-not $WhatIf) {
                Write-Host "`nPackage installation process complete." -ForegroundColor Green
            }
        } elseif ($doUpdate) {
            Write-Host "`n=== Upgrading All Installed Applications (Winget) ===" -ForegroundColor Cyan
            if (-not $wingetCmd -and -not $WhatIf) {
                Write-Badge "ERROR" Red "Winget not found. Ensure 'App Installer' is installed from the Microsoft Store."
                exit 1
            }

            if ($WhatIf) {
                Write-Badge "WHAT-IF" Cyan "Would run: winget upgrade --all --accept-package-agreements --accept-source-agreements"
            } else {
                & $wingetCmd upgrade --all --accept-package-agreements --accept-source-agreements
                Write-Host "`nPackage upgrade complete." -ForegroundColor Green
            }
        } else {
            Write-Host "`n=== Configured Applications (Winget) ===" -ForegroundColor Cyan
            $Config.packages | Format-Table -Property Name, Id, Category -AutoSize

            Write-Host "Commands:" -ForegroundColor DarkGray
            Write-Host "  .\sync.ps1 apps -Install   -> Install all listed applications" -ForegroundColor DarkGray
            Write-Host "  .\sync.ps1 apps -Update    -> Upgrade all installed apps to latest version" -ForegroundColor DarkGray
            Write-Host "  Native Winget alternative : winget import -i winget-packages.json`n" -ForegroundColor DarkGray
        }
    }

    'link' {
        Write-Host "`n=== Creating Symbolic Links (Machine -> Repo) ===" -ForegroundColor Cyan
        Write-Host "Note: Creating symbolic links requires Windows Developer Mode or Administrator privileges.`n" -ForegroundColor DarkGray

        foreach ($appEntry in $AppsToProcess) {
            Write-Host "`n[$($appEntry.displayName)]" -ForegroundColor Yellow

            foreach ($file in $appEntry.files) {
                $repoFullPath = Join-Path $ScriptDir $file.repoPath
                $localFullPath = Resolve-DynamicPath $file.localPath

                if (-not (Test-PathSafe $repoFullPath -PathType Leaf)) {
                    Write-Badge "WARN" Yellow "Repo file missing: $($file.repoPath)"
                    continue
                }

                $targetDir = Split-Path -Parent $localFullPath
                if (-not (Test-PathSafe $targetDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
                }

                if (Test-PathSafe $localFullPath) {
                    # Check if already a symlink pointing to the repo file
                    $item = Get-Item -LiteralPath $localFullPath -ErrorAction SilentlyContinue
                    if ($item -and $item.LinkType -eq 'SymbolicLink' -and ($item.Target -eq $repoFullPath -or (Resolve-Path $item.Target -ErrorAction SilentlyContinue).Path -eq $repoFullPath)) {
                        Write-Badge "OK" DarkGray "Already linked: $localFullPath -> $($file.repoPath)"
                        continue
                    }

                    if (-not $NoBackup) {
                        $fileBackupPath = Join-Path $backupDir $file.repoPath
                        $fileBackupDir = Split-Path -Parent $fileBackupPath
                        if (-not (Test-PathSafe $fileBackupDir -PathType Container)) {
                            [System.IO.Directory]::CreateDirectory($fileBackupDir) | Out-Null
                        }
                        Copy-Item -LiteralPath $localFullPath -Destination $fileBackupPath -Force
                        Write-Badge "BACKUP" DarkCyan "Backed up prior file to: .backups\$timestamp\$($file.repoPath)"
                    }

                    Remove-Item -LiteralPath $localFullPath -Force
                }

                try {
                    New-Item -ItemType SymbolicLink -Path $localFullPath -Target $repoFullPath -Force | Out-Null
                    Write-Badge "LINKED" Green "$localFullPath ===> $($file.repoPath)"
                } catch {
                    Write-Badge "FAILED" Red "Could not create symbolic link: $($_.Exception.Message)"
                    Write-Host "  Tip: Turn on Windows Developer Mode (Settings -> System -> For developers) or use '.\sync.ps1 apply' instead." -ForegroundColor Yellow
                }
            }
        }
    }

    { $_ -in 'setup', 'tweaks' } {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) {
            $params = @{}
            if ($WhatIf) { $params['WhatIf'] = $true }
            & $setupScript @params
        } else {
            Write-Badge "ERROR" Red "Setup script not found at $setupScript"
        }
    }
}
