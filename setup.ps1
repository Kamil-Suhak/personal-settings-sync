<#
.SYNOPSIS
    Compatibility entrypoint delegating to bootstrap.ps1.
#>

[CmdletBinding()]
param(
    [string]$RepoOwner = "Kamil-Suhak",
    [string]$RepoName = "personal-settings-sync",
    [string]$Branch = "main",
    [string]$TargetDir = "$HOME\Coding\Projects\personal-settings-sync",
    [string]$Workspace = "",
    [switch]$SkipApps,
    [switch]$SkipSetup
)

if ($PSScriptRoot) {
    $bootstrapScript = Join-Path $PSScriptRoot "bootstrap.ps1"
    if (Test-Path -LiteralPath $bootstrapScript) {
        & $bootstrapScript @PSBoundParameters
        return
    }
}

$bootstrapUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/bootstrap.ps1"
$scriptText = Invoke-RestMethod -Uri $bootstrapUrl -UseBasicParsing
& ([scriptblock]::Create($scriptText)) @PSBoundParameters
