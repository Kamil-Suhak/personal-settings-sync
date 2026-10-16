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
      - fonts   : Download and install developer fonts (JetBrains Mono)
      - setup   : Apply run-once Windows developer settings, fonts, and Explorer tweaks
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
    Overwrite files or reinstall fonts/packages even when already in sync.

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
    .\sync.ps1 fonts
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'export', 'diff', 'link', 'apps', 'fonts', 'setup', 'tweaks', 'help')]
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
$MaxBackups = 10

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
            $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            $normalized = $text.Replace("`r`n", "`n").TrimEnd("`r", "`n")
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
            } finally {
                $sha.Dispose()
            }
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

function Get-BackupDestination {
    param(
        [string]$BackupRoot,
        [string]$RepoRelativePath,
        [string]$LocalFullPath
    )
    $candidate = Join-Path $BackupRoot $RepoRelativePath
    if (Test-PathSafe $candidate -PathType Leaf) {
        $parentName = Split-Path -Leaf (Split-Path -Parent $LocalFullPath)
        $leafName = Split-Path -Leaf $RepoRelativePath
        $relDir = Split-Path -Parent $RepoRelativePath
        $candidate = Join-Path $BackupRoot (Join-Path $relDir "${parentName}_${leafName}")
    }
    $dir = Split-Path -Parent $candidate
    if (-not (Test-PathSafe $dir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    return $candidate
}

function Remove-OldBackups {
    param([int]$Keep = $MaxBackups)
    $backupsRoot = Join-Path $ScriptDir '.backups'
    if (-not (Test-PathSafe $backupsRoot -PathType Container)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -gt $Keep) {
        $toRemove = $dirs | Select-Object -Skip $Keep
        foreach ($oldDir in $toRemove) {
            Remove-Item -LiteralPath $oldDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Badge "CLEANUP" DarkGray "Pruned $($toRemove.Count) old backup folder(s) (retaining latest $Keep)."
    }
}

function Sync-WingetManifest {
    $manifestPath = Join-Path $ScriptDir 'winget-packages.json'
    if (-not $Config.packages) { return $false }

    $existingPythonId = 'Python.Python.3.14'
    if (Test-PathSafe $manifestPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $pyEntry = $existing.Sources[0].Packages | Where-Object { $_.PackageIdentifier -match '^Python\.Python\.3\.\d+$' } | Select-Object -First 1
            if ($pyEntry) { $existingPythonId = $pyEntry.PackageIdentifier }
        } catch {}
    }

    $pkgEntries = foreach ($pkg in $Config.packages) {
        $id = if ($pkg.id -in @('Python.Latest', 'Python.Python.Latest', 'Python.Python.3')) {
            $existingPythonId
        } else {
            $pkg.id
        }
        [ordered]@{ PackageIdentifier = $id }
    }

    $manifestObj = [ordered]@{
        '$schema'      = 'https://aka.ms/winget-packages.schema.2.0.json'
        CreationDate   = '2026-10-08T18:15:00.000'
        Sources        = @(
            [ordered]@{
                Packages      = @($pkgEntries)
                SourceDetails = [ordered]@{
                    Argument   = 'https://cdn.winget.microsoft.com/cache'
                    Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
                    Name       = 'winget'
                    Type       = 'Microsoft.PreIndexed.Package'
                }
            }
        )
    }

    $newJson = ($manifestObj | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    $oldHash = Get-FileHashSafe $manifestPath
    $normalizedNew = $newJson.TrimEnd("`r", "`n")
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedNew)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $newHash = [System.BitConverter]::ToString($sha.ComputeHash($newBytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }

    if ($oldHash -ne $newHash) {
        if ($WhatIf) {
            Write-Badge "WHAT-IF" Cyan "Would update winget-packages.json from sync.config.json"
            return $false
        }
        [System.IO.File]::WriteAllText($manifestPath, $newJson, [System.Text.UTF8Encoding]::new($false))
        Write-Badge "SYNCED" Green "Synchronized winget-packages.json with sync.config.json"
        return $true
    }
    return $false
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
$targetApp = if ($App) { $App } elseif ($Action -notin @('apps', 'fonts', 'setup', 'tweaks') -and $SubAction) { $SubAction } else { $null }
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
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git pull
        if ($LASTEXITCODE -ne 0) {
            Write-Badge "WARN" Yellow "git pull exited with code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $prevEAP
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
        Write-Host "  .\sync.ps1 apps -Install   -> Install standard apps and fonts via Winget" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 apps -Update    -> Upgrade all installed apps via Winget" -ForegroundColor DarkGray
        Write-Host "  .\sync.ps1 fonts           -> Download and install JetBrains Mono font`n" -ForegroundColor DarkGray
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

                if (-not $Force -and $localExists -and $repoHash -and ($repoHash -eq $localHash)) {
                    Write-Badge "OK" DarkGray "Already in sync: $localFullPath"
                    continue
                }

                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would deploy $($file.repoPath) -> $localFullPath"
                    continue
                }

                # Backup existing local file before overwriting
                if ($localExists -and -not $NoBackup) {
                    $fileBackupPath = Get-BackupDestination -BackupRoot $backupDir -RepoRelativePath $file.repoPath -LocalFullPath $localFullPath
                    Copy-Item -LiteralPath $localFullPath -Destination $fileBackupPath -Force
                    $relBackup = $fileBackupPath.Substring($ScriptDir.Length).TrimStart('\', '/')
                    Write-Badge "BACKUP" DarkCyan "Backed up current local file to: $relBackup"
                }

                # If target is currently a symbolic link, remove link before copying file
                if ($localExists) {
                    $localItem = Get-Item -LiteralPath $localFullPath -Force -ErrorAction SilentlyContinue
                    if ($localItem -and $localItem.LinkType -eq 'SymbolicLink') {
                        Remove-Item -LiteralPath $localFullPath -Force
                    }
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

        # Handle VS Code extensions install if requested
        $extFile = Join-Path $ScriptDir "configs\vscode\extensions.txt"
        if ($SyncExtensions -and (Test-PathSafe $extFile -PathType Leaf)) {
            Write-Host "`n[VS Code Extensions]" -ForegroundColor Yellow
            if (Get-Command code -ErrorAction SilentlyContinue) {
                Get-Content $extFile | Where-Object { $_ -match '\S' } | ForEach-Object {
                    Write-Host "Installing extension: $_" -ForegroundColor Cyan
                    if (-not $WhatIf) {
                        code --install-extension $_ --force
                    }
                }
            } else {
                Write-Badge "WARN" Yellow "'code' command not found in PATH; skipping extension install."
            }
        }

        if (-not $WhatIf) {
            Write-Host "`nDone. Successfully applied $appliedCount file(s)." -ForegroundColor Green
            if ($appliedCount -gt 0 -and -not $NoBackup) {
                Write-Host "Backups preserved in: $backupDir" -ForegroundColor DarkGray
                Remove-OldBackups -Keep $MaxBackups
            }
        }
    }

    'export' {
        Write-Host "`n=== Exporting Settings (Machine -> Repo) ===" -ForegroundColor Cyan
        $exportedCount = 0

        foreach ($appEntry in $AppsToProcess) {
            Write-Host "`n[$($appEntry.displayName)]" -ForegroundColor Yellow

            # Group by repoPath in case multiple local paths share a single repo file (e.g. PS 7+ and PS 5.1)
            $groupedFiles = $appEntry.files | Group-Object -Property repoPath

            foreach ($group in $groupedFiles) {
                $repoRelPath = $group.Name
                $repoFullPath = Join-Path $ScriptDir $repoRelPath
                $repoExists = Test-PathSafe $repoFullPath -PathType Leaf
                $repoHash = if ($repoExists) { Get-FileHashSafe $repoFullPath } else { $null }

                # Select candidate local files that exist
                $existingCandidates = @()
                foreach ($file in $group.Group) {
                    $localFullPath = Resolve-DynamicPath $file.localPath
                    if (Test-PathSafe $localFullPath -PathType Leaf) {
                        $item = Get-Item -LiteralPath $localFullPath -Force -ErrorAction SilentlyContinue
                        $existingCandidates += [PSCustomObject]@{
                            FileEntry     = $file
                            LocalFullPath = $localFullPath
                            Hash          = Get-FileHashSafe $localFullPath
                            LastWriteTime = if ($item) { $item.LastWriteTime } else { [datetime]::MinValue }
                        }
                    } elseif ($file.required -and $group.Group.Count -eq 1) {
                        Write-Badge "MISSING" DarkYellow "Local file does not exist: $localFullPath"
                    }
                }

                if ($existingCandidates.Count -eq 0) {
                    if (($group.Group | Where-Object { $_.required }) -and $group.Group.Count -gt 1) {
                        Write-Badge "MISSING" DarkYellow "No local files found for: $repoRelPath"
                    }
                    continue
                }

                # Prefer candidates whose hash differs from the repo, sorted by newest LastWriteTime
                $modifiedCandidates = @($existingCandidates | Where-Object { $_.Hash -ne $repoHash } | Sort-Object LastWriteTime -Descending)
                $chosen = if ($modifiedCandidates.Count -gt 0) {
                    $modifiedCandidates[0]
                } else {
                    ($existingCandidates | Sort-Object LastWriteTime -Descending)[0]
                }

                if (-not $Force -and $repoExists -and $chosen.Hash -and ($chosen.Hash -eq $repoHash)) {
                    Write-Badge "OK" DarkGray "Already in sync: $($chosen.LocalFullPath)"
                    continue
                }

                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would export $($chosen.LocalFullPath) -> $repoRelPath"
                    continue
                }

                $repoFileDir = Split-Path -Parent $repoFullPath
                if (-not (Test-PathSafe $repoFileDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($repoFileDir) | Out-Null
                }

                Copy-Item -LiteralPath $chosen.LocalFullPath -Destination $repoFullPath -Force
                Write-Badge "EXPORTED" Green "$($chosen.LocalFullPath) -> $repoRelPath"
                $exportedCount++
            }
        }

        # Keep winget-packages.json synchronized with sync.config.json
        if (-not $targetApp) {
            if (Sync-WingetManifest) {
                $exportedCount++
            }
        }

        # Export VS Code extensions if requested
        if ($SyncExtensions) {
            Write-Host "`n[VS Code Extensions]" -ForegroundColor Yellow
            if (Get-Command code -ErrorAction SilentlyContinue) {
                $extFile = Join-Path $ScriptDir "configs\vscode\extensions.txt"
                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would export installed extensions -> configs/vscode/extensions.txt"
                } else {
                    $extDir = Split-Path -Parent $extFile
                    if (-not (Test-PathSafe $extDir -PathType Container)) {
                        [System.IO.Directory]::CreateDirectory($extDir) | Out-Null
                    }
                    code --list-extensions | Out-File -FilePath $extFile -Encoding utf8
                    Write-Badge "EXPORTED" Green "Exported installed extensions -> configs/vscode/extensions.txt"
                    $exportedCount++
                }
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
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                git add configs sync.config.json winget-packages.json
                $porcelain = git status --porcelain
                if (-not $porcelain) {
                    Write-Badge "OK" DarkGray "Working tree is clean; nothing to commit or push."
                } else {
                    $commitMsg = "sync: update settings from $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
                    git commit -m $commitMsg
                    if ($LASTEXITCODE -eq 0) {
                        git push
                        if ($LASTEXITCODE -eq 0) {
                            Write-Badge "PUSHED" Green "Committed and pushed to GitHub."
                        } else {
                            Write-Badge "WARN" Yellow "git push exited with code $LASTEXITCODE"
                        }
                    }
                }
            } finally {
                $ErrorActionPreference = $prevEAP
            }
        }
    }

    'diff' {
        Write-Host "`n=== Comparing Repository vs Local Files ===" -ForegroundColor Cyan
        $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
        $diffCount = 0

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
                    $diffCount++
                    Write-Host "`n--- Diff for $($appEntry.displayName): $localFullPath vs $($file.repoPath) ---" -ForegroundColor Magenta
                    if ($hasGit) {
                        $prevEAP = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        try {
                            git diff --no-index --color $localFullPath $repoFullPath
                            $global:LASTEXITCODE = 0
                        } finally {
                            $ErrorActionPreference = $prevEAP
                        }
                    } else {
                        $localLines = Get-Content -LiteralPath $localFullPath
                        $repoLines = Get-Content -LiteralPath $repoFullPath
                        Compare-Object -ReferenceObject $localLines -DifferenceObject $repoLines | Format-Table -AutoSize
                    }
                }
            }
        }

        if ($diffCount -eq 0) {
            Write-Badge "OK" Green "All existing tracked files are identical."
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

            $installedListText = ""
            if ($wingetCmd -and -not $Force) {
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $installedListText = (& $wingetCmd list --accept-source-agreements 2>$null) -join "`n"
                } catch {} finally {
                    $ErrorActionPreference = $prevEAP
                }
            }

            foreach ($pkg in $Config.packages) {
                $packageId = $pkg.id
                $isDynamicPython = $packageId -in @('Python.Latest', 'Python.Python.Latest', 'Python.Python.3')

                if (-not $Force -and $installedListText) {
                    $checkPattern = if ($isDynamicPython) { 'Python\.Python\.3\.\d+' } else { [regex]::Escape($packageId) }
                    if ($installedListText -match $checkPattern) {
                        Write-Badge "OK" DarkGray "Already installed: $($pkg.name) ($packageId)"
                        continue
                    }
                }

                if ($isDynamicPython) {
                    if ($wingetCmd -and -not $WhatIf) {
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
                        $packageId = 'Python.Python.3.14'
                    }
                }

                Write-Host "`n--> Installing $($pkg.name) ($packageId)..." -ForegroundColor Cyan
                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would run: winget install --id $packageId -e --accept-package-agreements --accept-source-agreements"
                    continue
                }

                & $wingetCmd install --id $packageId -e --accept-package-agreements --accept-source-agreements
            }

            # Also ensure JetBrains Mono developer font is installed
            $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
            if (Test-PathSafe $setupScript -PathType Leaf) {
                $fontParams = @{ FontsOnly = $true }
                if ($WhatIf) { $fontParams['WhatIf'] = $true }
                if ($Force)  { $fontParams['Force']  = $true }
                & $setupScript @fontParams
            }

            if (-not $WhatIf) {
                Write-Host "`nPackage and font installation process complete." -ForegroundColor Green
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

            if ($Config.fonts) {
                Write-Host "=== Configured Developer Fonts ===" -ForegroundColor Cyan
                $Config.fonts | Format-Table -Property Name, Repo, CheckFile -AutoSize
            }

            Write-Host "Commands:" -ForegroundColor DarkGray
            Write-Host "  .\sync.ps1 apps -Install   -> Install all listed applications and fonts" -ForegroundColor DarkGray
            Write-Host "  .\sync.ps1 apps -Update    -> Upgrade all installed apps to latest version" -ForegroundColor DarkGray
            Write-Host "  .\sync.ps1 fonts           -> Download and install JetBrains Mono font only" -ForegroundColor DarkGray
            Write-Host "  Native Winget alternative  : winget import -i winget-packages.json`n" -ForegroundColor DarkGray
        }
    }

    'link' {
        Write-Host "`n=== Creating Symbolic Links (Machine -> Repo) ===" -ForegroundColor Cyan
        Write-Host "Note: Creating symbolic links requires Windows Developer Mode or Administrator privileges.`n" -ForegroundColor DarkGray
        $linkedCount = 0

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
                if ($localExists -and -not $Force) {
                    $item = Get-Item -LiteralPath $localFullPath -Force -ErrorAction SilentlyContinue
                    if ($item -and $item.LinkType -eq 'SymbolicLink' -and ($item.Target -eq $repoFullPath -or (Resolve-Path $item.Target -ErrorAction SilentlyContinue).Path -eq $repoFullPath)) {
                        Write-Badge "OK" DarkGray "Already linked: $localFullPath -> $($file.repoPath)"
                        continue
                    }
                }

                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would link $localFullPath ===> $($file.repoPath)"
                    continue
                }

                $targetDir = Split-Path -Parent $localFullPath
                if (-not (Test-PathSafe $targetDir -PathType Container)) {
                    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
                }

                $tempOldFile = $null
                if ($localExists) {
                    if (-not $NoBackup) {
                        $fileBackupPath = Get-BackupDestination -BackupRoot $backupDir -RepoRelativePath $file.repoPath -LocalFullPath $localFullPath
                        Copy-Item -LiteralPath $localFullPath -Destination $fileBackupPath -Force
                        $relBackup = $fileBackupPath.Substring($ScriptDir.Length).TrimStart('\', '/')
                        Write-Badge "BACKUP" DarkCyan "Backed up prior file to: $relBackup"
                    }

                    # Move existing file to temporary path so we can restore it if symlink creation fails
                    $tempOldFile = "$localFullPath.sync-tmp"
                    Move-Item -LiteralPath $localFullPath -Destination $tempOldFile -Force
                }

                try {
                    New-Item -ItemType SymbolicLink -Path $localFullPath -Target $repoFullPath -Force | Out-Null
                    if ($tempOldFile -and (Test-PathSafe $tempOldFile -PathType Leaf)) {
                        Remove-Item -LiteralPath $tempOldFile -Force -ErrorAction SilentlyContinue
                    }
                    Write-Badge "LINKED" Green "$localFullPath ===> $($file.repoPath)"
                    $linkedCount++
                } catch {
                    # Restore original local file if symlink creation failed
                    if ($tempOldFile -and (Test-PathSafe $tempOldFile -PathType Leaf)) {
                        Move-Item -LiteralPath $tempOldFile -Destination $localFullPath -Force -ErrorAction SilentlyContinue
                    }
                    Write-Badge "FAILED" Red "Could not create symbolic link (original file preserved): $($_.Exception.Message)"
                    Write-Host "  Tip: Turn on Windows Developer Mode (Settings -> System -> For developers) or use '.\sync.ps1 apply' instead." -ForegroundColor Yellow
                }
            }
        }

        if (-not $WhatIf -and $linkedCount -gt 0 -and -not $NoBackup) {
            Remove-OldBackups -Keep $MaxBackups
        }
    }

    'fonts' {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) {
            $params = @{ FontsOnly = $true }
            if ($WhatIf) { $params['WhatIf'] = $true }
            if ($Force)  { $params['Force']  = $true }
            & $setupScript @params
        } else {
            Write-Badge "ERROR" Red "Setup script not found at $setupScript"
        }
    }

    { $_ -in 'setup', 'tweaks' } {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) {
            $params = @{}
            if ($WhatIf) { $params['WhatIf'] = $true }
            if ($Force)  { $params['Force']  = $true }
            & $setupScript @params
        } else {
            Write-Badge "ERROR" Red "Setup script not found at $setupScript"
        }
    }
}
