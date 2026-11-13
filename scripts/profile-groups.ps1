function Get-PssProfileGroups {
    param([string]$Root, [string]$Workspace)

    [pscustomobject]@{ Name = 'shared'; Path = (Join-Path $Root 'configs\powershell\Microsoft.PowerShell_profile.ps1'); Scope = 'shared'; Required = $true }
    foreach ($name in @('git', 'navigation', 'search', 'visual-studio', 'ai')) {
        [pscustomobject]@{ Name = $name; Path = (Join-Path $Root "configs\powershell\$name.ps1"); Scope = 'shared'; Required = $true }
    }
    if ($Workspace -eq 'work') {
        [pscustomobject]@{ Name = 'worksets'; Path = (Join-Path $Root 'workspaces\work\powershell\worksets.ps1'); Scope = 'workspace'; Required = $true }
    }
    [pscustomobject]@{ Name = $Workspace; Path = (Join-Path $Root "workspaces\$Workspace\powershell\profile.ps1"); Scope = 'workspace'; Required = $false }
}
