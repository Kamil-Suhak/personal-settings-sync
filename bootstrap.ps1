<#
.SYNOPSIS
    Remote one-line machine bootstrapper for personal-settings-sync.

.DESCRIPTION
    Designed to run directly from Windows PowerShell on a brand-new machine:
      irm https://raw.githubusercontent.com/<YourUsername>/personal-settings-sync/main/bootstrap.ps1 | iex

    Performs the full machine bootstrap:
      1. Downloads latest repository archive from GitHub (no git or login required)
      2. Extracts project to $HOME\Coding\Projects\personal-settings-sync
      3. Applies Windows developer tweaks & installs JetBrains Mono font
      4. Installs configured applications via Winget
      5. Deploys personal configuration files
#>

[CmdletBinding()]
param(
    [string]$RepoOwner = "kamilsuhak",
    [string]$RepoName = "personal-settings-sync",
    [string]$Branch = "main",
    [string]$TargetDir = "$HOME\Coding\Projects\personal-settings-sync",
    [switch]$SkipApps,
    [switch]$SkipSetup
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Title)
    Write-Host "`n>>> $Title" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host "   Personal Settings Sync - Automated Machine Setup       " -ForegroundColor Magenta
Write-Host "==========================================================" -ForegroundColor Magenta

# 1. Download and Extract Repository
Write-Step "Downloading repository archive ($RepoOwner/$RepoName@$Branch)..."

$tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "settings-sync-$([guid]::NewGuid().ToString('N')).zip"
$tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "settings-sync-extract-$([guid]::NewGuid().ToString('N'))"
$archiveUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"

try {
    Invoke-WebRequest -Uri $archiveUrl -OutFile $tempZip -UseBasicParsing
    Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

    $unzippedFolder = Join-Path $tempExtract "$RepoName-$Branch"
    if (-not (Test-Path -LiteralPath $unzippedFolder)) {
        $unzippedFolder = (Get-ChildItem -LiteralPath $tempExtract -Directory | Select-Object -First 1).FullName
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    Copy-Item -Path "$unzippedFolder\*" -Destination $TargetDir -Recurse -Force
    Write-Success "Repository deployed to: $TargetDir"
} finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
}

# 2. Apply Windows Developer Tweaks, Font, Git Identity, & Project Roots
$syncScript = Join-Path $TargetDir "sync.ps1"
if (-not (Test-Path -LiteralPath $syncScript)) {
    Write-Error "Could not locate sync.ps1 in $TargetDir"
    exit 1
}

if (-not $SkipSetup) {
    Write-Step "Configuring Windows developer preferences, font & local identity..."
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript setup
    } catch {
        Write-Warn "Setup script encountered an issue: $($_.Exception.Message)"
    }
}

# 3. Install Configured Applications via Winget
if (-not $SkipApps) {
    Write-Step "Installing applications via Winget..."
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript apps -Install
    } catch {
        Write-Warn "Winget application installation encountered an issue: $($_.Exception.Message)"
    }
}

# 4. Deploy Settings
Write-Step "Deploying configuration files to machine..."
try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript apply
} catch {
    Write-Warn "Settings application encountered an issue: $($_.Exception.Message)"
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   Bootstrap Complete! Restart terminal to activate prompt. " -ForegroundColor Green
Write-Host "==========================================================`n" -ForegroundColor Green

