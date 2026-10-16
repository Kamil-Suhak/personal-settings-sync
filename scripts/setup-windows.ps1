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
      - Optionally enables Developer Mode & Win32 Long Paths (requires admin)
      - Refreshes Windows Explorer to apply changes immediately

.PARAMETER WhatIf
    Simulate registry and setting changes without applying them.

.PARAMETER RestartExplorer
    Restart explorer.exe to apply file explorer tweaks immediately.
#>

[CmdletBinding()]
param(
    [switch]$WhatIf,
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
    } catch {
        Write-Badge "WARN" Yellow "Could not set $Path\$Name (Requires elevation?): $($_.Exception.Message)"
    }
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
} else {
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Badge "APPLIED" Green "PowerShell ExecutionPolicy set to RemoteSigned (CurrentUser)"
    } catch {
        Write-Badge "WARN" Yellow "Could not set ExecutionPolicy: $($_.Exception.Message)"
    }
}

# 3. System-Wide Developer Tweaks (Machine Scope - Graceful if not Admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Enable Win32 Long Paths (> 260 chars)
    $fileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    Set-RegistryValueSafe -Path $fileSystemKey -Name 'LongPathsEnabled' -Value 1 -Description "Enable Win32 Long Paths"

    # Enable Developer Mode (Allows symbolic links without admin)
    $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    Set-RegistryValueSafe -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Description "Enable Windows Developer Mode"
} else {
    Write-Badge "INFO" DarkGray "Skipping LongPaths and Developer Mode tweaks (requires running as Administrator)"
}

# 4. Restart Explorer to apply UI tweaks immediately
if ($RestartExplorer -and -not $WhatIf) {
    Write-Host "`nRestarting Windows Explorer to apply visual settings..." -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Badge "OK" Green "Windows Explorer restarted successfully."
}

Write-Host "`nSetup tweaks complete!`n" -ForegroundColor Green
