<#
.SYNOPSIS
    Personal Settings Sync (PSS) - Modular context-aware settings & workspace manager.

.DESCRIPTION
    Synchronizes configurations between this repository and local system paths across
    multiple machines using modular workspaces (personal, work, school).
    Supports layered JSON merging, interactive export reconciliation, and Winget app management.

.PARAMETER Action
    The primary action to execute:
      status    : Show sync matrix across all configured subsystems
      apply     : Deploy settings from repository to this machine
      export    : Harvest current settings from machine into repository
      diff      : Show color-coded git diffs for modified settings
      workspace : Manage workspaces (list, use, current, new, delete)
      apps      : Manage applications via Winget (list, install, update)
      fonts     : Download and install developer fonts (JetBrains Mono)
      setup     : Apply Windows developer system optimizations
      help      : Display exhaustive help documentation

.PARAMETER SubAction
    Secondary verb for 'workspace' (list, use, current, new, delete) or 'apps' (list, install, update).

.PARAMETER TargetName
    Target name for 'workspace use <name>', 'workspace new <name>', or 'workspace delete <name>'.

.PARAMETER Include
    Comma-separated list of subsystems to include:
    vscode, powershell, terminal, git, gemini, skills, plugins, apps, fonts

.PARAMETER Exclude
    Comma-separated list of subsystems to exclude from execution.

.PARAMETER Target
    Destination layer for non-interactive export: 'Shared' or 'Workspace'.

.PARAMETER Force
    Overwrite files or reinstall packages even when already in sync.

.PARAMETER WhatIf
    Simulate actions without writing to disk.

.PARAMETER NoBackup
    Skip creating backups in .backups/ before modifying machine files.

.PARAMETER Push
    Commit and push repository changes to GitHub after export or workspace mutation.

.PARAMETER Pull
    Pull latest changes from git remote before applying.

.EXAMPLE
    pss status
    pss apply -Include vscode,powershell
    pss export -Target Workspace
    pss workspace list
    pss workspace use work
    pss diff
    pss apps install
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$SubAction,

    [Parameter(Position = 2)]
    [string]$TargetName,

    [string[]]$Include,
    [string[]]$Exclude,

    [ValidateSet('Shared', 'Workspace', '')]
    [string]$Target = '',

    [switch]$Force,
    [switch]$WhatIf,
    [switch]$NoBackup,
    [switch]$Push,
    [switch]$Pull,
    [switch]$SyncExtensions,
    [switch]$Help
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir 'sync.config.json'
$WorkspaceLocalFile = Join-Path $ScriptDir '.workspace.local'
$ValidSubsystems = @('vscode', 'powershell', 'terminal', 'git', 'gemini', 'skills', 'plugins', 'apps', 'fonts')
$MaxBackups = 10

#region 1. Output & Formatting Utilities
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

function Show-Help {
    Write-Host "`n=== Personal Settings Sync (PSS) ===" -ForegroundColor Cyan
    Write-Host "Modular, context-aware developer environment synchronizer.`n" -ForegroundColor DarkGray

    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  pss <action> [<subaction>] [<target>] [options]`n" -ForegroundColor White

    Write-Host "Primary Actions:" -ForegroundColor Yellow
    Write-Host "  status                Show sync status for all subsystems vs active workspace"
    Write-Host "  apply                 Deploy repository configurations to local machine"
    Write-Host "  export                Harvest local machine changes into repository"
    Write-Host "  diff                  Show differences between local files and synthesized repo state"
    Write-Host "  workspace <command>   Manage workspaces (list, use, current, new, delete)"
    Write-Host "  apps <command>        Manage Winget packages (list, install, update)"
    Write-Host "  fonts                 Download and install JetBrains Mono font"
    Write-Host "  setup                 Run run-once Windows developer optimizations"
    Write-Host "  help                  Display this reference guide`n"

    Write-Host "Workspace Commands:" -ForegroundColor Yellow
    Write-Host "  workspace list        List all configured workspaces (* indicates active)"
    Write-Host "  workspace current     Display current active workspace"
    Write-Host "  workspace use <name>  Switch local machine to specified workspace"
    Write-Host "  workspace new <name>  Create a new workspace context directory structure"
    Write-Host "  workspace delete <n>  Remove a workspace context directory`n"

    Write-Host "Filtering & Layering Options:" -ForegroundColor Yellow
    Write-Host "  -Include <list>       Filter subsystems (comma-separated or array):"
    Write-Host "                        vscode, powershell, terminal, git, gemini, skills, plugins, apps, fonts"
    Write-Host "  -Exclude <list>       Exclude specific subsystems from execution"
    Write-Host "  -Target <layer>       Export destination in non-interactive sessions: 'Shared' or 'Workspace'"
    Write-Host "  -Pull                 Run 'git pull' before applying"
    Write-Host "  -Push                 Commit and push changes to GitHub after export or workspace update"
    Write-Host "  -Force                Bypass hash comparisons and force write/install"
    Write-Host "  -WhatIf               Dry run; preview changes without modifying filesystem"
    Write-Host "  -NoBackup             Skip automated backup creation before overwriting local files`n"

    Write-Host "Examples:" -ForegroundColor DarkGray
    Write-Host "  pss status"
    Write-Host "  pss apply -Include vscode,powershell"
    Write-Host "  pss apply -Pull"
    Write-Host "  pss export"
    Write-Host "  pss export -Target Workspace -Push"
    Write-Host "  pss workspace use work"
    Write-Host "  pss diff -Include vscode"
    Write-Host "  pss apps install`n"
}
#endregion

#region 2. POSIX Flag Normalization & Help Interception
# Normalize common POSIX arguments or show help
if ($Help -or ($Action -in @('help', '--help', '-h', '/?'))) {
    Show-Help
    return
}

# Normalize positional or POSIX aliases
$posixAliases = @{
    '--force'     = { $script:Force = $true }
    '--what-if'   = { $script:WhatIf = $true }
    '--whatif'    = { $script:WhatIf = $true }
    '--no-backup' = { $script:NoBackup = $true }
    '--nobackup'  = { $script:NoBackup = $true }
    '--push'      = { $script:Push = $true }
    '--pull'      = { $script:Pull = $true }
}

$unboundArgs = @($args)
$sanitizedArgs = @()
foreach ($argItem in $unboundArgs) {
    if (-not $argItem) { continue }
    if ($posixAliases.ContainsKey($argItem)) {
        & $posixAliases[$argItem]
        Write-Badge "NOTE" DarkYellow "Mapped POSIX flag '$argItem' to PowerShell parameter equivalent."
    } elseif ($argItem -like '--*') {
        Write-Badge "ERROR" Red "Unsupported POSIX flag '$argItem'. Use standard PowerShell parameter syntax (e.g., -Include, -Force)."
        Show-Help
        exit 1
    } else {
        $sanitizedArgs += $argItem
    }
}

if ($sanitizedArgs.Count -gt 0 -and -not $SubAction) {
    $SubAction = $sanitizedArgs[0]
    if ($sanitizedArgs.Count -gt 1 -and -not $TargetName) {
        $TargetName = $sanitizedArgs[1]
    }
}
#endregion

#region 3. Core Path & Environment Helpers
function Test-PathSafe {
    param([string]$Path, [string]$PathType = 'Leaf')
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
    $resolved = [Environment]::ExpandEnvironmentVariables($resolved)
    try {
        $resolved = [System.IO.Path]::GetFullPath($resolved)
    } catch {}
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
    } catch {}
    return $null
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-PathSafe $dir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $normalized = $Content.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}
#endregion

#region 4. Workspace Management Engine
function Get-AvailableWorkspaces {
    $wsDir = Join-Path $ScriptDir 'workspaces'
    if (-not (Test-PathSafe $wsDir -PathType Container)) {
        return @('personal')
    }
    $dirs = @(Get-ChildItem -LiteralPath $wsDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($dirs.Count -eq 0) { return @('personal') }
    return $dirs
}

function Get-ActiveWorkspace {
    if (Test-PathSafe $WorkspaceLocalFile -PathType Leaf) {
        $active = (Get-Content -LiteralPath $WorkspaceLocalFile -Raw).Trim()
        if ($active) { return $active }
    }

    # First run or uninitialized
    $available = Get-AvailableWorkspaces
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

    if (-not $isInteractive) {
        Write-Badge "ERROR" Red "No active workspace configured in .workspace.local. Run 'pss workspace use <name>' first."
        exit 1
    }

    Write-Host "`n=== First-Run Workspace Selection ===" -ForegroundColor Cyan
    Write-Host "This machine does not have an active workspace configured." -ForegroundColor Yellow
    Write-Host "Available workspaces: $($available -join ', ')" -ForegroundColor White

    $selection = Read-Host "Enter workspace to use (default: '$($available[0])')"
    if (-not $selection) { $selection = $available[0] }

    Set-ActiveWorkspace -Name $selection
    return $selection
}

function Set-ActiveWorkspace {
    param([string]$Name)
    if (-not $Name) {
        Write-Badge "ERROR" Red "Workspace name required: pss workspace use <name>"
        exit 1
    }
    $Name = $Name.Trim().ToLowerInvariant()
    $wsPath = Join-Path $ScriptDir "workspaces\$Name"
    if (-not (Test-PathSafe $wsPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($wsPath) | Out-Null
        Write-Badge "CREATED" Green "Created workspace directory: workspaces/$Name"
    }
    Write-Utf8File -Path $WorkspaceLocalFile -Content $Name
    Write-Badge "ACTIVE" Green "Active workspace set to: $Name"
}

function New-WorkspaceContext {
    param([string]$Name)
    if (-not $Name) {
        Write-Badge "ERROR" Red "Workspace name required: pss workspace new <name>"
        exit 1
    }
    $Name = $Name.Trim().ToLowerInvariant()
    $wsPath = Join-Path $ScriptDir "workspaces\$Name"
    if (Test-PathSafe $wsPath -PathType Container) {
        Write-Badge "WARN" Yellow "Workspace '$Name' already exists at workspaces/$Name"
        return
    }

    $dirs = @(
        (Join-Path $wsPath 'vscode'),
        (Join-Path $wsPath 'powershell'),
        (Join-Path $wsPath 'git')
    )
    foreach ($d in $dirs) {
        [System.IO.Directory]::CreateDirectory($d) | Out-Null
    }

    Write-Utf8File -Path (Join-Path $wsPath 'vscode\settings.json') -Content "{}`n"
    Write-Utf8File -Path (Join-Path $wsPath 'powershell\profile.ps1') -Content "# PowerShell additions for workspace: $Name`n"
    Write-Utf8File -Path (Join-Path $wsPath 'git\.gitconfig') -Content "# Git user overrides for workspace: $Name`n[user]`n`t# email = user@$Name.local`n"

    Write-Badge "CREATED" Green "Created new workspace '$Name' with templates in workspaces/$Name"
}
#endregion

#region 5. Layered JSON Recursive Merge & Diff Engine
function Merge-HashtableRecursive {
    param(
        [System.Collections.IDictionary]$Base,
        [System.Collections.IDictionary]$Override
    )
    if (-not $Base) {
        return if ($Override) { [ordered]@{} + $Override } else { [ordered]@{} }
    }
    if (-not $Override) {
        return [ordered]@{} + $Base
    }

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) {
        $result[$key] = $Base[$key]
    }

    foreach ($key in $Override.Keys) {
        if ($result.Contains($key) -and ($result[$key] -is [System.Collections.IDictionary]) -and ($Override[$key] -is [System.Collections.IDictionary])) {
            $result[$key] = Merge-HashtableRecursive -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Read-JsonAsHashtable {
    param([string]$Path)
    if (-not (Test-PathSafe $Path -PathType Leaf)) {
        return [ordered]@{}
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        # Strip single-line comments for resilience
        $clean = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
        if (-not $clean.Trim()) { return [ordered]@{} }
        $obj = ConvertFrom-Json -InputObject $clean -AsHashtable
        if ($obj -is [System.Collections.IDictionary]) { return $obj }
        return [ordered]@{}
    } catch {
        Write-Badge "WARN" Yellow "Could not parse JSON in $Path : $_"
        return [ordered]@{}
    }
}

function Get-SynthesizedJsonContent {
    param(
        [string]$SharedRepoPath,
        [string]$WorkspaceRepoPath
    )
    $sharedFull = if ($SharedRepoPath) { Join-Path $ScriptDir $SharedRepoPath } else { $null }
    $wsFull     = if ($WorkspaceRepoPath) { Join-Path $ScriptDir $WorkspaceRepoPath } else { $null }

    $baseMap = Read-JsonAsHashtable -Path $sharedFull
    $wsMap   = Read-JsonAsHashtable -Path $wsFull

    $merged = Merge-HashtableRecursive -Base $baseMap -Override $wsMap
    if ($merged.Count -eq 0 -and -not (Test-PathSafe $sharedFull -PathType Leaf)) {
        return $null
    }
    return ($merged | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
}

function Compare-JsonProperties {
    param(
        [System.Collections.IDictionary]$LocalMap,
        [System.Collections.IDictionary]$EffectiveMap,
        [string]$Prefix = ""
    )
    $diffs = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Check for Modified and Deleted keys
    foreach ($k in $EffectiveMap.Keys) {
        $propName = if ($Prefix) { "$Prefix.$k" } else { "$k" }
        $expected = $EffectiveMap[$k]

        if (-not $LocalMap.Contains($k)) {
            $diffs.Add([PSCustomObject]@{
                Property = $propName
                Type     = 'DELETED'
                RepoVal  = $expected
                LocalVal = $null
            })
        } elseif (($expected -is [System.Collections.IDictionary]) -and ($LocalMap[$k] -is [System.Collections.IDictionary])) {
            $childDiffs = Compare-JsonProperties -LocalMap $LocalMap[$k] -EffectiveMap $expected -Prefix $propName
            foreach ($cd in $childDiffs) {
                $diffs.Add($cd)
            }
        } else {
            $localVal = $LocalMap[$k]
            $expJson = ($expected | ConvertTo-Json -Compress -Depth 50)
            $locJson = ($localVal | ConvertTo-Json -Compress -Depth 50)
            if ($expJson -ne $locJson) {
                $diffs.Add([PSCustomObject]@{
                    Property = $propName
                    Type     = 'MODIFIED'
                    RepoVal  = $expected
                    LocalVal = $localVal
                })
            }
        }
    }

    # Check for New keys
    foreach ($k in $LocalMap.Keys) {
        $propName = if ($Prefix) { "$Prefix.$k" } else { "$k" }
        if (-not $EffectiveMap.Contains($k)) {
            $diffs.Add([PSCustomObject]@{
                Property = $propName
                Type     = 'NEW'
                RepoVal  = $null
                LocalVal = $LocalMap[$k]
            })
        }
    }

    return $diffs
}
#endregion

#region 6. Subsystem Filtering & Config Resolution
if (-not (Test-PathSafe $ConfigFile -PathType Leaf)) {
    Write-Badge "ERROR" Red "Configuration file missing at: $ConfigFile"
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
$ActiveWorkspace = Get-ActiveWorkspace

# Parse -Include and -Exclude arrays (supporting comma-separated items)
function Parse-SubsystemList {
    param([string[]]$Items)
    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Items) {
        foreach ($item in $Items) {
            foreach ($sub in ($item -split '[,;]')) {
                $cleaned = $sub.Trim().ToLowerInvariant()
                if ($cleaned) {
                    if ($cleaned -notin $ValidSubsystems) {
                        Write-Badge "ERROR" Red "Invalid subsystem '$cleaned'. Valid: $($ValidSubsystems -join ', ')"
                        exit 1
                    }
                    $result.Add($cleaned) | Out-Null
                }
            }
        }
    }
    return $result
}

$script:IncludedSubsystems = Parse-SubsystemList -Items $Include
$script:ExcludedSubsystems = Parse-SubsystemList -Items $Exclude

function Should-ProcessSubsystem {
    param([string]$SubsystemName)
    if (-not $SubsystemName) { return $true }
    $name = $SubsystemName.ToLowerInvariant()
    if ($script:ExcludedSubsystems -and $script:ExcludedSubsystems.Contains($name)) { return $false }
    if ($script:IncludedSubsystems -and ($script:IncludedSubsystems.Count -gt 0) -and -not $script:IncludedSubsystems.Contains($name)) { return $false }
    return $true
}

function Resolve-WorkspaceFilePaths {
    param([PSCustomObject]$FileEntry, [string]$Workspace)
    $repoRel = $FileEntry.repoPath
    $wsRel   = if ($FileEntry.workspacePath) {
        $FileEntry.workspacePath.Replace('{workspace}', $Workspace)
    } else { $null }

    return [PSCustomObject]@{
        RepoPath      = $repoRel
        WorkspacePath = $wsRel
        LocalPath     = Resolve-DynamicPath $FileEntry.localPath
        Layered       = [bool]$FileEntry.layered
        Required      = [bool]$FileEntry.required
    }
}
#endregion

#region 7. Backup Management
function New-BackupSnapshot {
    param(
        [string]$BackupRoot,
        [string]$RelativePath,
        [string]$LocalFullPath
    )
    if (-not (Test-PathSafe $LocalFullPath -PathType Leaf)) { return }
    $dest = Join-Path $BackupRoot $RelativePath
    $parent = Split-Path -Parent $dest
    if (-not (Test-PathSafe $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Copy-Item -LiteralPath $LocalFullPath -Destination $dest -Force
    $relBackup = $dest.Substring($ScriptDir.Length).TrimStart('\', '/')
    Write-Badge "BACKUP" DarkCyan "Backed up: $relBackup"
}

function Prune-Backups {
    $backupsRoot = Join-Path $ScriptDir '.backups'
    if (-not (Test-PathSafe $backupsRoot -PathType Container)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -gt $MaxBackups) {
        $toRemove = $dirs | Select-Object -Skip $MaxBackups
        foreach ($old in $toRemove) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Badge "CLEANUP" DarkGray "Pruned $($toRemove.Count) old backup folder(s)."
    }
}
#endregion

#region 8. Git Push/Pull Safeguards
function Test-GitRemoteWritable {
    $pushCheck = & git push --dry-run 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Badge "ERROR" Red "Git remote write access check failed:`n$($pushCheck -join "`n")"
        return $false
    }
    return $true
}

function Invoke-GitRemotePush {
    param([string]$CommitMessage)
    Write-Host "`n=== Pushing Changes to Remote ===" -ForegroundColor Cyan
    if (-not (Test-GitRemoteWritable)) {
        Write-Badge "ERROR" Red "Cannot push changes: Remote check failed."
        exit 1
    }
    git add -A
    git commit -m $CommitMessage
    if ($LASTEXITCODE -eq 0) {
        git push
        if ($LASTEXITCODE -eq 0) {
            Write-Badge "PUSHED" Green "Pushed changes to GitHub."
        } else {
            Write-Badge "ERROR" Red "git push failed with code $LASTEXITCODE."
            exit 1
        }
    }
}
#endregion

#region 9. Execution Dispatcher
Write-Host "`n[PSS] Active Workspace: " -ForegroundColor Cyan -NoNewline
Write-Host "$ActiveWorkspace" -ForegroundColor Green

if ($Pull) {
    Write-Host "`n=== Pulling Latest Changes From Git ===" -ForegroundColor Cyan
    git pull
    if ($LASTEXITCODE -ne 0) {
        Write-Badge "WARN" Yellow "git pull completed with code $LASTEXITCODE"
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $ScriptDir ".backups\$timestamp"

switch ($Action.ToLowerInvariant()) {
    'workspace' {
        $sub = if ($SubAction) { $SubAction.ToLowerInvariant() } else { 'list' }
        switch ($sub) {
            'list' {
                Write-Host "`n=== Available Workspaces ===" -ForegroundColor Cyan
                $all = Get-AvailableWorkspaces
                foreach ($w in $all) {
                    if ($w -eq $ActiveWorkspace) {
                        Write-Host " * $w (active)" -ForegroundColor Green
                    } else {
                        Write-Host "   $w" -ForegroundColor White
                    }
                }
                Write-Host "`nSwitch workspace: pss workspace use <name>" -ForegroundColor DarkGray
            }
            'current' {
                Write-Host "`nActive workspace: $ActiveWorkspace" -ForegroundColor Green
                Write-Host "Path: $(Join-Path $ScriptDir "workspaces\$ActiveWorkspace")" -ForegroundColor DarkGray
            }
            'use' {
                Set-ActiveWorkspace -Name $TargetName
            }
            'new' {
                New-WorkspaceContext -Name $TargetName
                if ($Push) {
                    Invoke-GitRemotePush -CommitMessage "chore: add workspace context $TargetName"
                }
            }
            'delete' {
                if (-not $TargetName) {
                    Write-Badge "ERROR" Red "Workspace name required: pss workspace delete <name>"
                    exit 1
                }
                if ($TargetName -eq $ActiveWorkspace) {
                    Write-Badge "ERROR" Red "Cannot delete active workspace '$TargetName'. Switch to another workspace first."
                    exit 1
                }
                $targetDir = Join-Path $ScriptDir "workspaces\$TargetName"
                if (Test-PathSafe $targetDir -PathType Container) {
                    Remove-Item -LiteralPath $targetDir -Recurse -Force
                    Write-Badge "DELETED" Green "Deleted workspace '$TargetName'"
                    if ($Push) {
                        Invoke-GitRemotePush -CommitMessage "chore: remove workspace context $TargetName"
                    }
                } else {
                    Write-Badge "WARN" Yellow "Workspace '$TargetName' not found."
                }
            }
            default {
                Write-Badge "ERROR" Red "Unknown workspace command: $sub. Available: list, current, use, new, delete"
                exit 1
            }
        }
    }

    'status' {
        Write-Host "`n=== Personal Settings Sync Status ===" -ForegroundColor Cyan
        $results = @()

        foreach ($app in $Config.apps) {
            if (-not (Should-ProcessSubsystem $app.name)) { continue }

            foreach ($fileConfig in $app.files) {
                $paths = Resolve-WorkspaceFilePaths -FileEntry $fileConfig -Workspace $ActiveWorkspace
                $localExists = Test-PathSafe $paths.LocalPath -PathType Leaf

                $statusText = "Unknown"
                if ($paths.Layered) {
                    $synth = Get-SynthesizedJsonContent -SharedRepoPath $paths.RepoPath -WorkspaceRepoPath $paths.WorkspacePath
                    if (-not $synth -and -not $localExists) {
                        $statusText = "Missing Both"
                    } elseif (-not $synth) {
                        $statusText = "Missing in Repo"
                    } elseif (-not $localExists) {
                        $statusText = "Missing on Machine"
                    } else {
                        $localText = [System.IO.File]::ReadAllText($paths.LocalPath, [System.Text.Encoding]::UTF8)
                        $cleanLocal = [regex]::Replace($localText, '(?m)^\s*//.*$', '')
                        try {
                            $localMap = ConvertFrom-Json -InputObject $cleanLocal -AsHashtable
                            $synthMap = ConvertFrom-Json -InputObject $synth -AsHashtable
                            $diffs = Compare-JsonProperties -LocalMap $localMap -EffectiveMap $synthMap
                            if ($diffs.Count -eq 0) {
                                $statusText = "In Sync"
                            } else {
                                $statusText = "Modified ($($diffs.Count) keys)"
                            }
                        } catch {
                            $statusText = "Format Error"
                        }
                    }
                } else {
                    $repoFull = if ($paths.RepoPath) { Join-Path $ScriptDir $paths.RepoPath } else { Join-Path $ScriptDir $paths.WorkspacePath }
                    $repoExists = Test-PathSafe $repoFull -PathType Leaf

                    if (-not $repoExists -and -not $localExists) {
                        $statusText = "Missing Both"
                    } elseif (-not $repoExists) {
                        $statusText = "Missing in Repo"
                    } elseif (-not $localExists) {
                        $statusText = "Missing on Machine"
                    } else {
                        $repoHash = Get-FileHashSafe $repoFull
                        $localHash = Get-FileHashSafe $paths.LocalPath
                        if ($repoHash -and ($repoHash -eq $localHash)) {
                            $statusText = "In Sync"
                        } else {
                            $statusText = "Modified"
                        }
                    }
                }

                $results += [PSCustomObject]@{
                    Subsystem = $app.displayName
                    File      = Split-Path -Leaf $paths.LocalPath
                    Status    = $statusText
                    LocalPath = $paths.LocalPath
                }
            }
        }

        # Skills & Plugins
        if ((Should-ProcessSubsystem 'skills') -and $Config.skills) {
            $skillsBase = Resolve-DynamicPath "%USERPROFILE%\.agents\skills"
            foreach ($s in $Config.skills) {
                $localSkill = Join-Path $skillsBase $s
                $statusText = if (Test-PathSafe $localSkill -PathType Container) { "In Sync" } else { "Missing on Machine" }
                $results += [PSCustomObject]@{
                    Subsystem = "Skill"
                    File      = $s
                    Status    = $statusText
                    LocalPath = $localSkill
                }
            }
        }

        if ((Should-ProcessSubsystem 'plugins') -and $Config.plugins) {
            $pluginsBase = Resolve-DynamicPath "%USERPROFILE%\.gemini\config\plugins"
            foreach ($p in $Config.plugins) {
                $localPlugin = Join-Path $pluginsBase $p
                $statusText = if (Test-PathSafe $localPlugin -PathType Container) { "In Sync" } else { "Missing on Machine" }
                $results += [PSCustomObject]@{
                    Subsystem = "Plugin"
                    File      = $p
                    Status    = $statusText
                    LocalPath = $localPlugin
                }
            }
        }

        $results | Format-Table -Property Subsystem, File, Status, LocalPath -AutoSize
    }

    'apply' {
        Write-Host "`n=== Applying Settings (Repo -> Machine) ===" -ForegroundColor Cyan
        $appliedCount = 0

        foreach ($app in $Config.apps) {
            if (-not (Should-ProcessSubsystem $app.name)) { continue }
            Write-Host "`n[$($app.displayName)]" -ForegroundColor Yellow

            foreach ($fileConfig in $app.files) {
                $paths = Resolve-WorkspaceFilePaths -FileEntry $fileConfig -Workspace $ActiveWorkspace
                $localExists = Test-PathSafe $paths.LocalPath -PathType Leaf

                if ($paths.Layered) {
                    $synth = Get-SynthesizedJsonContent -SharedRepoPath $paths.RepoPath -WorkspaceRepoPath $paths.WorkspacePath
                    if (-not $synth) {
                        if ($paths.Required) { Write-Badge "WARN" Yellow "No layered configuration found for $($paths.RepoPath)" }
                        continue
                    }

                    # Check if already in sync
                    if (-not $Force -and $localExists) {
                        try {
                            $localText = [System.IO.File]::ReadAllText($paths.LocalPath, [System.Text.Encoding]::UTF8)
                            $localMap = ConvertFrom-Json -InputObject ($localText -replace '(?m)^\s*//.*$', '') -AsHashtable
                            $synthMap = ConvertFrom-Json -InputObject $synth -AsHashtable
                            $diffs = Compare-JsonProperties -LocalMap $localMap -EffectiveMap $synthMap
                            if ($diffs.Count -eq 0) {
                                Write-Badge "OK" DarkGray "Already in sync: $($paths.LocalPath)"
                                continue
                            }
                        } catch {}
                    }

                    if ($WhatIf) {
                        Write-Badge "WHAT-IF" Cyan "Would write synthesized JSON -> $($paths.LocalPath)"
                        continue
                    }

                    if ($localExists -and -not $NoBackup) {
                        New-BackupSnapshot -BackupRoot $backupDir -RelativePath $paths.RepoPath -LocalFullPath $paths.LocalPath
                    }

                    Write-Utf8File -Path $paths.LocalPath -Content $synth
                    Write-Badge "APPLIED" Green "Synthesized (shared + $ActiveWorkspace) -> $($paths.LocalPath)"
                    $appliedCount++
                } else {
                    $repoFull = if ($paths.RepoPath) { Join-Path $ScriptDir $paths.RepoPath } else { Join-Path $ScriptDir $paths.WorkspacePath }
                    if (-not (Test-PathSafe $repoFull -PathType Leaf)) {
                        if ($paths.Required) { Write-Badge "WARN" Yellow "Repo file missing: $repoFull" }
                        continue
                    }

                    $repoHash = Get-FileHashSafe $repoFull
                    $localHash = if ($localExists) { Get-FileHashSafe $paths.LocalPath } else { $null }

                    if (-not $Force -and $localExists -and ($repoHash -eq $localHash)) {
                        Write-Badge "OK" DarkGray "Already in sync: $($paths.LocalPath)"
                        continue
                    }

                    if ($WhatIf) {
                        Write-Badge "WHAT-IF" Cyan "Would deploy $repoFull -> $($paths.LocalPath)"
                        continue
                    }

                    if ($localExists -and -not $NoBackup) {
                        New-BackupSnapshot -BackupRoot $backupDir -RelativePath $paths.RepoPath -LocalFullPath $paths.LocalPath
                    }

                    $parentDir = Split-Path -Parent $paths.LocalPath
                    if (-not (Test-PathSafe $parentDir -PathType Container)) {
                        [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
                    }
                    Copy-Item -LiteralPath $repoFull -Destination $paths.LocalPath -Force
                    Write-Badge "APPLIED" Green "$repoFull -> $($paths.LocalPath)"
                    $appliedCount++
                }
            }
        }

        # Deploy workspace profile additions to ~/.profile.local.ps1 if present
        $wsProfile = Join-Path $ScriptDir "workspaces\$ActiveWorkspace\powershell\profile.ps1"
        if ((Should-ProcessSubsystem 'powershell') -and (Test-PathSafe $wsProfile -PathType Leaf)) {
            $localProfileTarget = Resolve-DynamicPath "%USERPROFILE%\.profile.local.ps1"
            if (-not $WhatIf) {
                Copy-Item -LiteralPath $wsProfile -Destination $localProfileTarget -Force
                Write-Badge "APPLIED" Green "workspaces/$ActiveWorkspace/powershell/profile.ps1 -> $localProfileTarget"
                $appliedCount++
            } else {
                Write-Badge "WHAT-IF" Cyan "Would deploy workspace profile additions -> $localProfileTarget"
            }
        }

        if (-not $WhatIf) {
            Write-Host "`nDone. Successfully applied $appliedCount file(s)." -ForegroundColor Green
            if ($appliedCount -gt 0 -and -not $NoBackup) {
                Prune-Backups
            }
        }
    }

    'export' {
        Write-Host "`n=== Exporting Settings (Machine -> Repo) ===" -ForegroundColor Cyan
        $exportedCount = 0
        $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

        foreach ($app in $Config.apps) {
            if (-not (Should-ProcessSubsystem $app.name)) { continue }
            Write-Host "`n[$($app.displayName)]" -ForegroundColor Yellow

            foreach ($fileConfig in $app.files) {
                $paths = Resolve-WorkspaceFilePaths -FileEntry $fileConfig -Workspace $ActiveWorkspace
                if (-not (Test-PathSafe $paths.LocalPath -PathType Leaf)) { continue }

                if ($paths.Layered) {
                    $sharedFull = Join-Path $ScriptDir $paths.RepoPath
                    $wsFull     = Join-Path $ScriptDir $paths.WorkspacePath

                    $sharedMap = Read-JsonAsHashtable -Path $sharedFull
                    $wsMap     = Read-JsonAsHashtable -Path $wsFull
                    $effective = Merge-HashtableRecursive -Base $sharedMap -Override $wsMap

                    $localText = [System.IO.File]::ReadAllText($paths.LocalPath, [System.Text.Encoding]::UTF8)
                    $cleanLocal = [regex]::Replace($localText, '(?m)^\s*//.*$', '')
                    $localMap = ConvertFrom-Json -InputObject $cleanLocal -AsHashtable

                    $diffs = Compare-JsonProperties -LocalMap $localMap -EffectiveMap $effective
                    if ($diffs.Count -eq 0) {
                        Write-Badge "OK" DarkGray "Already in sync: $($paths.LocalPath)"
                        continue
                    }

                    Write-Host "Found $($diffs.Count) modified/new key(s) in $($paths.LocalPath)." -ForegroundColor Cyan

                    # Group diffs by root namespace (e.g. editor, workbench, git)
                    $groups = $diffs | Group-Object { ($_.Property -split '\.')[0] }

                    foreach ($g in $groups) {
                        $targetLayer = $Target
                        if (-not $targetLayer) {
                            if (-not $isInteractive) {
                                Write-Badge "ERROR" Red "Non-interactive export requires -Target Shared or -Target Workspace."
                                exit 1
                            }

                            Write-Host "`n--- Namespace: $($g.Name) ($($g.Count) change(s)) ---" -ForegroundColor Yellow
                            foreach ($d in $g.Group) {
                                if ($d.Type -eq 'DELETED') {
                                    Write-Host "  [DEL] $($d.Property) (present in repo, removed locally)" -ForegroundColor Red
                                } elseif ($d.Type -eq 'NEW') {
                                    Write-Host "  [NEW] $($d.Property) = $(ConvertTo-Json $d.LocalVal -Compress)" -ForegroundColor Green
                                } else {
                                    Write-Host "  [MOD] $($d.Property) : $(ConvertTo-Json $d.RepoVal -Compress) -> $(ConvertTo-Json $d.LocalVal -Compress)" -ForegroundColor Cyan
                                }
                            }

                            Write-Host "Route changes for '$($g.Name)': [S]hared (all machines), [W]orkspace ('$ActiveWorkspace' only), [K]eep repo values, [Q]uit?" -ForegroundColor White
                            $choice = (Read-Host "Choice [S/W/K/Q]").Trim().ToUpperInvariant()

                            switch ($choice) {
                                'S' { $targetLayer = 'Shared' }
                                'W' { $targetLayer = 'Workspace' }
                                'Q' { Write-Host "Export aborted."; return }
                                default { $targetLayer = 'Keep' }
                            }
                        }

                        if ($targetLayer -eq 'Shared') {
                            foreach ($d in $g.Group) {
                                if ($d.Type -eq 'DELETED') {
                                    $sharedMap.Remove($d.Property)
                                } else {
                                    $sharedMap[$d.Property] = $d.LocalVal
                                }
                            }
                        } elseif ($targetLayer -eq 'Workspace') {
                            foreach ($d in $g.Group) {
                                if ($d.Type -eq 'DELETED') {
                                    $wsMap.Remove($d.Property)
                                } else {
                                    $wsMap[$d.Property] = $d.LocalVal
                                }
                            }
                        }
                    }

                    if (-not $WhatIf) {
                        Write-Utf8File -Path $sharedFull -Content (($sharedMap | ConvertTo-Json -Depth 100))
                        Write-Utf8File -Path $wsFull     -Content (($wsMap | ConvertTo-Json -Depth 100))
                        Write-Badge "EXPORTED" Green "Reconciled $($paths.LocalPath) into repo layers"
                        $exportedCount++
                    } else {
                        Write-Badge "WHAT-IF" Cyan "Would export $($paths.LocalPath) into repo layers"
                    }
                } else {
                    $repoFull = if ($paths.RepoPath) { Join-Path $ScriptDir $paths.RepoPath } else { Join-Path $ScriptDir $paths.WorkspacePath }
                    $repoHash = Get-FileHashSafe $repoFull
                    $localHash = Get-FileHashSafe $paths.LocalPath

                    if ($repoHash -and ($repoHash -eq $localHash)) {
                        Write-Badge "OK" DarkGray "Already in sync: $($paths.LocalPath)"
                        continue
                    }

                    if ($WhatIf) {
                        Write-Badge "WHAT-IF" Cyan "Would export $($paths.LocalPath) -> $repoFull"
                        continue
                    }

                    Copy-Item -LiteralPath $paths.LocalPath -Destination $repoFull -Force
                    Write-Badge "EXPORTED" Green "$($paths.LocalPath) -> $repoFull"
                    $exportedCount++
                }
            }
        }

        if (-not $WhatIf) {
            Write-Host "`nDone. Successfully exported $exportedCount file(s)." -ForegroundColor Green
            if ($Push) {
                Invoke-GitRemotePush -CommitMessage "sync: update settings from $env:COMPUTERNAME ($ActiveWorkspace)"
            }
        }
    }

    'diff' {
        Write-Host "`n=== Comparing Local Machine vs Synthesized State ===" -ForegroundColor Cyan
        $diffCount = 0

        foreach ($app in $Config.apps) {
            if (-not (Should-ProcessSubsystem $app.name)) { continue }

            foreach ($fileConfig in $app.files) {
                $paths = Resolve-WorkspaceFilePaths -FileEntry $fileConfig -Workspace $ActiveWorkspace
                if (-not (Test-PathSafe $paths.LocalPath -PathType Leaf)) { continue }

                if ($paths.Layered) {
                    $synth = Get-SynthesizedJsonContent -SharedRepoPath $paths.RepoPath -WorkspaceRepoPath $paths.WorkspacePath
                    if (-not $synth) { continue }

                    $localText = [System.IO.File]::ReadAllText($paths.LocalPath, [System.Text.Encoding]::UTF8)
                    $localMap = ConvertFrom-Json -InputObject ($localText -replace '(?m)^\s*//.*$', '') -AsHashtable
                    $synthMap = ConvertFrom-Json -InputObject $synth -AsHashtable
                    $diffs = Compare-JsonProperties -LocalMap $localMap -EffectiveMap $synthMap

                    if ($diffs.Count -gt 0) {
                        $diffCount++
                        Write-Host "`n--- Property Diff for $($app.displayName): $($paths.LocalPath) vs Synthesized ($ActiveWorkspace) ---" -ForegroundColor Magenta
                        foreach ($d in $diffs) {
                            if ($d.Type -eq 'DELETED') {
                                Write-Host " - $($d.Property) (Deleted locally)" -ForegroundColor Red
                            } elseif ($d.Type -eq 'NEW') {
                                Write-Host " + $($d.Property) = $(ConvertTo-Json $d.LocalVal -Compress)" -ForegroundColor Green
                            } else {
                                Write-Host " ~ $($d.Property) : $(ConvertTo-Json $d.RepoVal -Compress) -> $(ConvertTo-Json $d.LocalVal -Compress)" -ForegroundColor Cyan
                            }
                        }
                    }
                } else {
                    $repoFull = if ($paths.RepoPath) { Join-Path $ScriptDir $paths.RepoPath } else { Join-Path $ScriptDir $paths.WorkspacePath }
                    $repoHash = Get-FileHashSafe $repoFull
                    $localHash = Get-FileHashSafe $paths.LocalPath
                    if ($repoHash -ne $localHash) {
                        $diffCount++
                        Write-Host "`n--- File Diff for $($app.displayName): $($paths.LocalPath) vs $repoFull ---" -ForegroundColor Magenta
                        git diff --no-index --color $paths.LocalPath $repoFull
                    }
                }
            }
        }

        if ($diffCount -eq 0) {
            Write-Badge "OK" Green "All configurations are in sync with active workspace '$ActiveWorkspace'."
        }
    }

    'apps' {
        $sub = if ($SubAction) { $SubAction.ToLowerInvariant() } else { 'list' }
        $wingetCmd = (Get-Command winget.exe -ErrorAction SilentlyContinue)
        if (-not $wingetCmd) {
            $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-PathSafe $candidate -PathType Leaf) { $wingetCmd = $candidate }
        }

        switch ($sub) {
            'install' {
                Write-Host "`n=== Installing Configured Applications (Winget) ===" -ForegroundColor Cyan
                foreach ($pkg in $Config.packages) {
                    Write-Host "--> Installing $($pkg.name) ($($pkg.id))..." -ForegroundColor Cyan
                    if (-not $WhatIf) {
                        & $wingetCmd install --id $pkg.id -e --accept-package-agreements --accept-source-agreements
                    }
                }
            }
            'update' {
                Write-Host "`n=== Upgrading Applications (Winget) ===" -ForegroundColor Cyan
                if (-not $WhatIf) {
                    & $wingetCmd upgrade --all --accept-package-agreements --accept-source-agreements
                }
            }
            default {
                Write-Host "`n=== Configured Applications ===" -ForegroundColor Cyan
                $Config.packages | Format-Table -Property Name, Id, Category -AutoSize
            }
        }
    }

    'fonts' {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) {
            & $setupScript -FontsOnly
        }
    }

    'setup' {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) {
            & $setupScript
        }
    }

    default {
        Write-Badge "ERROR" Red "Unknown action: '$Action'. Run 'pss help' for usage."
        exit 1
    }
}
