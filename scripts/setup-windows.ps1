<#
.SYNOPSIS
    Run-once Windows developer environment setup and registry tweaks.

.DESCRIPTION
    Applies recommended Windows developer preferences:
      - Show file extensions in Explorer
      - Show hidden files in Explorer
      - Enable "End Task" on taskbar right-click (Windows 11)
      - Show full directory paths in Explorer title bar
      - Set PowerShell execution policy for CurrentUser
      - Download and install JetBrains Mono font (CurrentUser scope)
      - Optionally enables Developer Mode & Win32 Long Paths (requires admin)
      - Refreshes Windows Explorer to apply changes immediately

.PARAMETER WhatIf
    Simulate registry, font, and setting changes without applying them.

.PARAMETER Force
    Reinstall fonts even if already detected on the machine.

.PARAMETER FontsOnly
    Only download and install the JetBrains Mono font without applying registry tweaks.

.PARAMETER RestartExplorer
    Restart explorer.exe to apply file explorer tweaks immediately.
#>

[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Force,
    [switch]$FontsOnly,
    [switch]$RestartExplorer = $true
)

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

function Set-RegistryValueSafe {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$PropertyType = "DWord",
        [string]$Description
    )

    if ($WhatIf) {
        Write-Badge "WHAT-IF" Cyan "Would set $Path\$Name = $Value ($Description)"
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $PropertyType -Force | Out-Null
        Write-Badge "APPLIED" Green "$Description ($Name = $Value)"
    }
    catch {
        Write-Badge "WARN" Yellow "Could not set $Path\$Name (Requires elevation?): $($_.Exception.Message)"
    }
}

function Install-JetBrainsMonoFont {
    $userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $sysFontDir = Join-Path $env:WINDIR 'Fonts'
    $fontRegKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $checkFile = 'JetBrainsMono-Regular.ttf'

    $alreadyInstalled = (Test-Path -LiteralPath (Join-Path $userFontDir $checkFile)) -or
    (Test-Path -LiteralPath (Join-Path $sysFontDir $checkFile))

    if ($alreadyInstalled -and -not $Force) {
        Write-Badge "OK" DarkGray "JetBrains Mono font is already installed."
        return
    }

    if ($WhatIf) {
        Write-Badge "WHAT-IF" Cyan "Would download and install JetBrains Mono (.ttf) to $userFontDir"
        return
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "jetbrains-mono-$([guid]::NewGuid().ToString('N'))"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $downloadUrl = 'https://download.jetbrains.com/fonts/JetBrainsMono-2.304.zip'
        try {
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/JetBrains/JetBrainsMono/releases/latest' -Headers @{ 'User-Agent' = 'personal-settings-sync' } -TimeoutSec 10 -ErrorAction Stop
            $asset = $release.assets | Where-Object { $_.name -match '^JetBrainsMono-[\d.]+\.zip$' } | Select-Object -First 1
            if ($asset -and $asset.browser_download_url) {
                $downloadUrl = $asset.browser_download_url
            }
        }
        catch {}

        $zipPath = Join-Path $tempDir 'JetBrainsMono.zip'
        $extractDir = Join-Path $tempDir 'extracted'

        Write-Badge "DOWNLOAD" Cyan "Downloading JetBrains Mono from $downloadUrl..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $ttfSearchDir = Join-Path $extractDir 'fonts\ttf'
        if (-not (Test-Path -LiteralPath $ttfSearchDir)) {
            $ttfSearchDir = $extractDir
        }

        $ttfFiles = Get-ChildItem -Path $ttfSearchDir -Filter '*.ttf' -Recurse -File | Where-Object { $_.Name -notmatch '\[' }
        if (-not $ttfFiles) {
            Write-Badge "WARN" Yellow "No .ttf files found in downloaded JetBrains Mono archive."
            return
        }

        if (-not (Test-Path -LiteralPath $userFontDir)) {
            New-Item -ItemType Directory -Path $userFontDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $fontRegKey)) {
            New-Item -Path $fontRegKey -Force | Out-Null
        }

        $installedCount = 0
        foreach ($ttf in $ttfFiles) {
            $destPath = Join-Path $userFontDir $ttf.Name
            Copy-Item -LiteralPath $ttf.FullName -Destination $destPath -Force

            $friendlyName = $ttf.BaseName -replace '^JetBrainsMonoNL-', 'JetBrains Mono NL ' -replace '^JetBrainsMono-', 'JetBrains Mono '
            $friendlyName = $friendlyName -replace '([a-z])Italic$', '$1 Italic'
            $regValueName = "$friendlyName (TrueType)"

            Set-ItemProperty -Path $fontRegKey -Name $regValueName -Value $destPath -Type String -Force | Out-Null
            $installedCount++
        }

        Write-Badge "APPLIED" Green "Installed $installedCount JetBrains Mono font files to $userFontDir"
    }
    catch {
        Write-Badge "WARN" Yellow "Failed to install JetBrains Mono font: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Configure-GitUserSafe {
    $localGitConfig = Join-Path $HOME ".gitconfig.local"
    $hasLocalConfig = Test-Path -LiteralPath $localGitConfig
    $currentEmail = if ($hasLocalConfig) {
        (& git config --file $localGitConfig user.email 2>$null)
    } else {
        (& git config --global user.email 2>$null)
    }

    if (-not $currentEmail -or $Force) {
        if ($WhatIf) {
            Write-Badge "WHAT-IF" Cyan "Would prompt for Git user.name and user.email to store in ~/.gitconfig.local"
            return
        }

        if ([Environment]::UserInteractive) {
            Write-Host "`n=== Git Identity Setup (Local Only) ===" -ForegroundColor Cyan
            Write-Host "Your identity is stored in ~/.gitconfig.local and never committed to git." -ForegroundColor DarkGray
            $namePrompt = Read-Host "Enter Git user name (e.g. Your Name)"
            $emailPrompt = Read-Host "Enter Git user email address"

            if ($namePrompt) {
                & git config --file $localGitConfig user.name $namePrompt
            }
            if ($emailPrompt) {
                & git config --file $localGitConfig user.email $emailPrompt
            }

            if ($namePrompt -or $emailPrompt) {
                Write-Badge "APPLIED" Green "Saved Git identity to: $localGitConfig"
            }
        }
    } else {
        Write-Badge "OK" DarkGray "Git user identity already configured in ~/.gitconfig.local."
    }
}

function Configure-ProjectRootsSafe {
    $rootsFile = Join-Path $HOME ".project-roots"
    $hasRoots = Test-Path -LiteralPath $rootsFile

    if (-not $hasRoots -or $Force) {
        if ($WhatIf) {
            Write-Badge "WHAT-IF" Cyan "Would prompt for project root directories to store in ~/.project-roots"
            return
        }

        if ([Environment]::UserInteractive) {
            Write-Host "`n=== Project Directories Setup (for 'p' jumper) ===" -ForegroundColor Cyan
            Write-Host "Directories are stored locally in ~/.project-roots and never committed to git." -ForegroundColor DarkGray
            $defaultHint = "$HOME\Coding\Projects, $HOME\Dev"
            $inputPaths = Read-Host "Enter project directories (comma-separated, press Enter for defaults: $defaultHint)"

            $rootsToSave = [System.Collections.Generic.List[string]]::new()
            if ($inputPaths) {
                foreach ($raw in ($inputPaths -split ',')) {
                    $trimmed = $raw.Trim()
                    if ($trimmed) {
                        $resolved = Resolve-Path -LiteralPath $trimmed -ErrorAction SilentlyContinue
                        $finalPath = if ($resolved) { $resolved.Path } else { [Environment]::ExpandEnvironmentVariables($trimmed) }
                        if (-not (Test-Path -LiteralPath $finalPath)) {
                            New-Item -ItemType Directory -Path $finalPath -Force | Out-Null
                        }
                        $rootsToSave.Add($finalPath)
                    }
                }
            } else {
                @("$HOME\Coding\Projects", "$HOME\Dev") | ForEach-Object {
                    $expanded = [Environment]::ExpandEnvironmentVariables($_)
                    if (-not (Test-Path -LiteralPath $expanded)) {
                        New-Item -ItemType Directory -Path $expanded -Force | Out-Null
                    }
                    $rootsToSave.Add($expanded)
                }
            }

            if ($rootsToSave.Count -gt 0) {
                $rootsToSave | Out-File -FilePath $rootsFile -Encoding utf8
                Write-Badge "APPLIED" Green "Configured $($rootsToSave.Count) project root(s) in: $rootsFile"
            }
        }
    } else {
        Write-Badge "OK" DarkGray "Project roots already configured in ~/.project-roots."
    }
}

if ($FontsOnly) {
    Write-Host "`n=== Installing Developer Fonts ===" -ForegroundColor Cyan
    Install-JetBrainsMonoFont
    return
}

Write-Host "`n=== Applying Run-Once Windows Developer Tweaks ===" -ForegroundColor Cyan

# 1. File Explorer Preferences (User Scope - No Admin Required)
$advancedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

# Show file extensions (0 = show, 1 = hide)
Set-RegistryValueSafe -Path $advancedKey -Name 'HideFileExt' -Value 0 -Description "Show file extensions"

# Show hidden files (1 = show, 2 = hide)
Set-RegistryValueSafe -Path $advancedKey -Name 'Hidden' -Value 1 -Description "Show hidden files"

# Show full path in Explorer title bar (1 = show)
$cabinetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'
Set-RegistryValueSafe -Path $cabinetKey -Name 'FullPath' -Value 1 -Description "Show full path in Explorer title"

# Enable "End Task" on taskbar right-click (Windows 11 23H2+)
$taskbarDevKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
Set-RegistryValueSafe -Path $taskbarDevKey -Name 'TaskbarEndTask' -Value 1 -Description "Enable 'End Task' on taskbar"

# 2. PowerShell Execution Policy (User Scope)
if ($WhatIf) {
    Write-Badge "WHAT-IF" Cyan "Would set ExecutionPolicy to RemoteSigned for CurrentUser"
}
else {
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Badge "APPLIED" Green "PowerShell ExecutionPolicy set to RemoteSigned (CurrentUser)"
    }
    catch {
        Write-Badge "WARN" Yellow "Could not set ExecutionPolicy: $($_.Exception.Message)"
    }
}

# 3. Developer Fonts (User Scope - No Admin Required)
Install-JetBrainsMonoFont

# 4. Git Identity Configuration (Local uncommitted file)
Configure-GitUserSafe

# 5. Project Roots Setup (Local uncommitted file)
Configure-ProjectRootsSafe

# 6. System-Wide Developer Tweaks (Machine Scope - Graceful if not Admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Enable Win32 Long Paths (> 260 chars)
    $fileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    Set-RegistryValueSafe -Path $fileSystemKey -Name 'LongPathsEnabled' -Value 1 -Description "Enable Win32 Long Paths"

    # Enable Developer Mode (Allows symbolic links without admin)
    $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    Set-RegistryValueSafe -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Description "Enable Windows Developer Mode"
}
else {
    Write-Badge "INFO" DarkGray "Skipping LongPaths and Developer Mode tweaks (requires running as Administrator)"
}

# 7. Restart Explorer to apply UI tweaks immediately
if ($RestartExplorer -and -not $WhatIf) {
    Write-Host "`nRestarting Windows Explorer to apply visual settings..." -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Badge "OK" Green "Windows Explorer restarted successfully."
}

Write-Host "`nSetup tweaks complete!`n" -ForegroundColor Green
