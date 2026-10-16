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

$bootstrapScript = Join-Path $PSScriptRoot "bootstrap.ps1"
if (Test-Path -LiteralPath $bootstrapScript) {
    & $bootstrapScript @PSBoundParameters
    return
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
} finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
}

$syncScript = Join-Path $TargetDir "sync.ps1"
if (-not $SkipSetup) { powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript setup }
if (-not $SkipApps) { powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript apps -Install }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript apply
