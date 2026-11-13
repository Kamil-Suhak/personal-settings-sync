<#
.SYNOPSIS
    Personal Settings Sync (PSS) - Repo-as-source-of-truth workspace manager.

.DESCRIPTION
    Manages shared and workspace-scoped configurations (PowerShell, Git, AI Agent Rules,
    Skills, and Plugins) using native includes, directory junctions, and one-way synthesis.

.PARAMETER Action
    Primary action:
      status     : Show sync state across all subsystems for the active workspace
      apply      : Link/deploy repo configurations to local machine (alias: link)
      diff       : Show diffs between local files and repo state
      edit       : Open a shared or workspace config file in the repo
      bootstrap  : Interactively harvest functions/sections from existing machine configs
      workspace  : Manage workspaces (list, current, use, new, delete)
      apps       : Manage Winget packages (list, install, update)
      fonts      : Download and install developer fonts (JetBrains Mono)
      setup      : Run one-time Windows developer optimizations
      help       : Show help reference
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

    [switch]$Force,
    [switch]$WhatIf,
    [switch]$NoBackup,
    [switch]$NoApply,
    [switch]$Push,
    [switch]$Pull,
    [switch]$PathOnly,
    [switch]$Help,

    [string]$HomeOverride,
    [string]$DocumentsOverride,
    [string]$LocalAppDataOverride,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir 'sync.config.json'
. (Join-Path $ScriptDir 'scripts\local-state.ps1')
$localAppData = if ($LocalAppDataOverride) { $LocalAppDataOverride } else { $env:LOCALAPPDATA }
$PssLocalState = Get-PssLocalStatePaths -Checkout $ScriptDir -LocalAppData $localAppData
$ValidSubsystems = @('powershell', 'git', 'gemini', 'skills', 'plugins')
$MaxBackups = 10

#region 1. Output & Help
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
    Write-Host "Repo-as-source-of-truth environment manager (PowerShell, Git, AI).`n" -ForegroundColor DarkGray

    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  pss <action> [<args...>] [options]`n" -ForegroundColor White

    Write-Host "Primary Actions:" -ForegroundColor Yellow
    Write-Host "  status                 Show sync state across all subsystems"
    Write-Host "  apply | link           Link/deploy repo configs to this machine"
    Write-Host "  diff                   Show diffs for out-of-sync files"
    Write-Host "  edit <layer> <target>  Open repo file (layer: shared|<workspace>; target: powershell|git|agents|gemini|skills.json)"
    Write-Host "  bootstrap              Interactively migrate existing local profile/gitconfig/AGENTS.md into repo layers"
    Write-Host "  workspace <cmd>        Manage workspaces (list, current, use, new, delete)"
    Write-Host "  apps <cmd>             Manage Winget packages for active workspace (list, install, update)"
    Write-Host "  fonts                  Install JetBrains Mono font"
    Write-Host "  setup                  Run one-time Windows developer tweaks"
    Write-Host "  help                   Show this guide`n"

    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  -Include <list>        Subsystems: $($ValidSubsystems -join ', ')"
    Write-Host "  -Exclude <list>        Exclude specific subsystems"
    Write-Host "  -Pull                  Run 'git pull' before applying"
    Write-Host "  -Push                  Commit and push after workspace/bootstrap mutations"
    Write-Host "  -Force                 Force overwrite or relink even if already in sync"
    Write-Host "  -WhatIf                Dry run; preview changes without writing to disk"
    Write-Host "  -NoBackup              Skip .backups/ creation before overwriting"
    Write-Host "  -NoApply               Skip automatic re-link on 'workspace use'"
    Write-Host "  -PathOnly              Print resolved repo path on 'pss edit'`n"

    Write-Host "Examples:" -ForegroundColor DarkGray
    Write-Host "  pss status"
    Write-Host "  pss apply -Pull"
    Write-Host "  pss workspace use work"
    Write-Host "  pss edit work powershell"
    Write-Host "  pss edit shared agents"
    Write-Host "  pss bootstrap`n"
}
#endregion

#region 2. Argument Normalization
if ($Help -or ($Action -in @('help', '--help', '-h', '/?'))) {
    Show-Help
    return
}

$posixAliases = @{
    '--force'     = { $script:Force = $true }
    '--what-if'   = { $script:WhatIf = $true }
    '--whatif'    = { $script:WhatIf = $true }
    '--no-backup' = { $script:NoBackup = $true }
    '--nobackup'  = { $script:NoBackup = $true }
    '--no-apply'  = { $script:NoApply = $true }
    '--push'      = { $script:Push = $true }
    '--pull'      = { $script:Pull = $true }
    '--path-only' = { $script:PathOnly = $true }
}

$rawPositionals = @($SubAction, $TargetName) + @($ExtraArgs)
$sanitizedArgs = [System.Collections.Generic.List[string]]::new()
foreach ($argItem in $rawPositionals) {
    if ([string]::IsNullOrEmpty($argItem)) { continue }
    if ($posixAliases.ContainsKey($argItem)) {
        & $posixAliases[$argItem]
        Write-Badge "NOTE" DarkYellow "Mapped POSIX flag '$argItem' to PowerShell parameter."
    } elseif ($argItem -like '--*') {
        Write-Badge "ERROR" Red "Unsupported POSIX flag '$argItem'. Use PowerShell switches (e.g. -Include, -Force)."
        exit 1
    } else {
        $sanitizedArgs.Add($argItem)
    }
}

$SubAction = if ($sanitizedArgs.Count -gt 0) { $sanitizedArgs[0] } else { $null }
$TargetName = if ($sanitizedArgs.Count -gt 1) { $sanitizedArgs[1] } else { $null }
$migrationHome = if ($HomeOverride) { $HomeOverride } else { $HOME }
$migrationProfileDir = if ($DocumentsOverride) { Join-Path $DocumentsOverride 'PowerShell' } elseif ($PROFILE) { Split-Path -Parent $PROFILE } else { $null }
Invoke-PssLocalStateMigration -Paths $PssLocalState -Checkout $ScriptDir -HomePath $migrationHome -ProfileDirectory $migrationProfileDir -WhatIf:$WhatIf
$WorkspaceLocalFile = $PssLocalState.Workspace
if ($WhatIf -and -not (Test-Path -LiteralPath $WorkspaceLocalFile) -and (Test-Path -LiteralPath (Join-Path $ScriptDir '.workspace.local'))) {
    $WorkspaceLocalFile = Join-Path $ScriptDir '.workspace.local'
}
#endregion

#region 3. Path, File & Text Helpers
function Test-PathSafe {
    param([string]$Path, [string]$PathType = 'Any')
    try {
        if ($PathType -eq 'Any') { return (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) }
        return (Test-Path -LiteralPath $Path -PathType $PathType -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Get-EffectiveHome {
    if ($HomeOverride) { return [System.IO.Path]::GetFullPath($HomeOverride) }
    return $HOME
}

function Get-EffectiveDocuments {
    if ($DocumentsOverride) { return [System.IO.Path]::GetFullPath($DocumentsOverride) }
    return [Environment]::GetFolderPath('MyDocuments')
}

function Resolve-DynamicPath {
    param([string]$PathPattern)
    $homeDir = Get-EffectiveHome
    $docsDir = Get-EffectiveDocuments
    $resolved = $PathPattern.Replace('$DOCUMENTS', $docsDir).Replace('%USERPROFILE%', $homeDir)
    $resolved = [Environment]::ExpandEnvironmentVariables($resolved)
    try {
        return [System.IO.Path]::GetFullPath($resolved)
    } catch {
        return $resolved
    }
}

function ConvertTo-ForwardPath {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function Normalize-TextLF {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n")
}

function Get-TextHash {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-TextLF $Text))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    if (-not (Test-PathSafe $Path -PathType Leaf)) { return $null }
    return Get-TextHash ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-PathSafe $dir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $normalized = (Normalize-TextLF $Content) + "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function Append-Utf8File {
    param([string]$Path, [string]$Content)
    $existing = if (Test-PathSafe $Path -PathType Leaf) {
        Normalize-TextLF ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
    } else { "" }
    $combined = if ($existing) { "$existing`n`n$(Normalize-TextLF $Content)" } else { Normalize-TextLF $Content }
    Write-Utf8File -Path $Path -Content $combined
}
#endregion

#region 4. Workspace & Config Resolution
if (-not (Test-PathSafe $ConfigFile -PathType Leaf)) {
    Write-Badge "ERROR" Red "Configuration file missing at: $ConfigFile"
    exit 1
}
$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json

function Get-AvailableWorkspaces {
    $wsDir = Join-Path $ScriptDir $Config.workspacesDir
    if (-not (Test-PathSafe $wsDir -PathType Container)) { return @($Config.defaultWorkspace) }
    $dirs = @(Get-ChildItem -LiteralPath $wsDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($dirs.Count -eq 0) { return @($Config.defaultWorkspace) }
    return $dirs
}

function Set-ActiveWorkspace {
    param([string]$Name)
    if (-not $Name) {
        Write-Badge "ERROR" Red "Workspace name required: pss workspace use <name>"
        exit 1
    }
    $Name = $Name.Trim().ToLowerInvariant()
    $wsPath = Join-Path (Join-Path $ScriptDir $Config.workspacesDir) $Name
    if (-not (Test-PathSafe $wsPath -PathType Container)) {
        New-WorkspaceContext -Name $Name
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
    $wsPath = Join-Path (Join-Path $ScriptDir $Config.workspacesDir) $Name
    if (Test-PathSafe $wsPath -PathType Container) {
        Write-Badge "WARN" Yellow "Workspace '$Name' already exists at workspaces/$Name"
        return
    }

    foreach ($sub in @('powershell', 'git', 'gemini')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $wsPath $sub)) | Out-Null
    }
    Write-Utf8File -Path (Join-Path $wsPath 'powershell\profile.ps1') -Content "# PowerShell overrides for workspace: $Name"
    Write-Utf8File -Path (Join-Path $wsPath 'git\.gitconfig') -Content "# Git overrides for workspace: $Name`n[user]`n`t# email = user@$Name.local"
    Write-Utf8File -Path (Join-Path $wsPath 'gemini\AGENTS.md') -Content "## $($Name.Substring(0,1).ToUpperInvariant() + $Name.Substring(1)) Workspace Context"

    Write-Badge "CREATED" Green "Created workspace '$Name' in workspaces/$Name"
}

function Get-ActiveWorkspace {
    if (Test-PathSafe $WorkspaceLocalFile -PathType Leaf) {
        $raw = Get-Content -LiteralPath $WorkspaceLocalFile -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $active = $raw.Trim()
            if ($active) { return $active }
        }
    }

    $available = Get-AvailableWorkspaces
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if (-not $isInteractive) {
        Write-Badge "ERROR" Red "No active workspace configured. Run 'pss workspace use <name>' first."
        exit 1
    }

    Write-Host "`n=== First-Run Workspace Selection ===" -ForegroundColor Cyan
    Write-Host "Available workspaces: $($available -join ', ')" -ForegroundColor White
    $selection = Read-Host "Enter workspace to use (default: '$($available[0])')"
    if (-not $selection) { $selection = $available[0] }
    Set-ActiveWorkspace -Name $selection
    return $selection.Trim().ToLowerInvariant()
}

function Parse-SubsystemList {
    param([string[]]$Items)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        foreach ($sub in ($item -split '[,;]')) {
            $cleaned = $sub.Trim().ToLowerInvariant()
            if (-not $cleaned) { continue }
            if ($cleaned -notin $ValidSubsystems) {
                Write-Badge "ERROR" Red "Invalid subsystem '$cleaned'. Valid: $($ValidSubsystems -join ', ')"
                exit 1
            }
            [void]$set.Add($cleaned)
        }
    }
    return ,$set
}

$script:IncludedSubsystems = Parse-SubsystemList -Items $Include
$script:ExcludedSubsystems = Parse-SubsystemList -Items $Exclude

function Should-ProcessSubsystem {
    param([string]$SubsystemName)
    $name = $SubsystemName.ToLowerInvariant()
    if ($script:ExcludedSubsystems.Contains($name)) { return $false }
    if ($script:IncludedSubsystems.Count -gt 0 -and -not $script:IncludedSubsystems.Contains($name)) { return $false }
    return $true
}
#endregion

#region 5. Backups & Git Remote Safeguards
function New-BackupSnapshot {
    param([string]$BackupRoot, [string]$RelativeName, [string]$LocalPath)
    if ($NoBackup -or $WhatIf) { return }
    if (-not (Test-PathSafe $LocalPath)) { return }

    $dest = Join-Path $BackupRoot $RelativeName
    $parent = Split-Path -Parent $dest
    if (-not (Test-PathSafe $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Copy-Item -LiteralPath $LocalPath -Destination $dest -Recurse -Force
    $relBackup = $dest.Substring($ScriptDir.Length).TrimStart('\', '/')
    Write-Badge "BACKUP" DarkCyan "Backed up -> $relBackup"
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

function Invoke-GitCmd {
    param([string[]]$GitArgs)
    try {
        & git @GitArgs
    } catch [System.ComponentModel.Win32Exception] {
        # Fallback when Carbon Black / AppLocker blocks direct git.exe invocation under -NoProfile
        $escaped = $GitArgs | ForEach-Object {
            if ($_ -match '[\s&|<>^()%"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }
        cmd.exe /d /c "git $($escaped -join ' ')"
    }
}

function Invoke-GitRemotePush {
    param([string]$CommitMessage)
    Write-Host "`n=== Pushing Changes to Remote ===" -ForegroundColor Cyan
    $pushCheck = Invoke-GitCmd @('-C', $ScriptDir, 'push', '--dry-run') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Badge "ERROR" Red "Git remote write check failed:`n$($pushCheck -join "`n")"
        exit 1
    }
    Invoke-GitCmd @('-C', $ScriptDir, 'add', '-A')
    Invoke-GitCmd @('-C', $ScriptDir, 'commit', '-m', $CommitMessage)
    if ($LASTEXITCODE -eq 0) {
        Invoke-GitCmd @('-C', $ScriptDir, 'push')
        if ($LASTEXITCODE -eq 0) {
            Write-Badge "PUSHED" Green "Pushed changes to remote."
        } else {
            Write-Badge "ERROR" Red "git push failed with code $LASTEXITCODE."
            exit 1
        }
    }
}
#endregion

#region 6. Subsystem Engines (PowerShell, Git, AI Rules, Junctions)
function Get-ExpectedProfileLoaderContent {
    $sharedProfile = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $Config.subsystems.powershell.sharedPath))
    return "# Managed by personal-settings-sync (pss). Edit files in the repository, not here.`n. `"$sharedProfile`""
}

function Test-IsManagedProfileLoader {
    param([string]$LocalProfilePath)
    if (-not (Test-PathSafe $LocalProfilePath -PathType Leaf)) { return $false }
    $raw = [System.IO.File]::ReadAllText($LocalProfilePath, [System.Text.Encoding]::UTF8)
    return ($raw -match '(?m)^#\s*Managed by personal-settings-sync \(pss\)')
}

function Get-PowerShellStatus {
    $localPath = Resolve-DynamicPath $Config.subsystems.powershell.localTarget
    $expected = Get-ExpectedProfileLoaderContent
    if (-not (Test-PathSafe $localPath -PathType Leaf)) {
        return [PSCustomObject]@{ Status = "Missing on Machine"; LocalPath = $localPath; Expected = $expected }
    }
    $localText = [System.IO.File]::ReadAllText($localPath, [System.Text.Encoding]::UTF8)
    if ((Get-TextHash $localText) -eq (Get-TextHash $expected)) {
        return [PSCustomObject]@{ Status = "In Sync"; LocalPath = $localPath; Expected = $expected }
    }
    if (Test-IsManagedProfileLoader $localPath) {
        return [PSCustomObject]@{ Status = "Needs Relink"; LocalPath = $localPath; Expected = $expected }
    }
    return [PSCustomObject]@{ Status = "Unmanaged Local File"; LocalPath = $localPath; Expected = $expected }
}

function Get-GitIncludeTargets {
    param([string]$Workspace)
    $sharedAbs = ConvertTo-ForwardPath (Join-Path $ScriptDir $Config.subsystems.git.sharedPath)
    $wsRel = $Config.subsystems.git.workspacePath.Replace('{workspace}', $Workspace)
    $wsAbs = ConvertTo-ForwardPath (Join-Path $ScriptDir $wsRel)
    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.Add($sharedAbs)
    if (Test-PathSafe (Join-Path $ScriptDir $wsRel) -PathType Leaf) {
        $targets.Add($wsAbs)
    }
    return $targets
}

function Unquote-GitIncludeValue {
    param([string]$RawValue)
    $val = $RawValue.Trim()
    # Strip trailing inline comment only when outside quotes
    if ($val -match '^"([^"]+)"(?:\s*[#;].*)?$') {
        $val = $matches[1]
    } elseif ($val -match "^'([^']+)'(?:\s*[#;].*)?$") {
        $val = $matches[1]
    } else {
        $val = ($val -split '\s+[#;]', 2)[0].Trim()
    }
    return (ConvertTo-ForwardPath $val)
}

function Test-IsPssManagedGitInclude {
    param([string]$IncludePath)
    $norm = Unquote-GitIncludeValue $IncludePath
    return (
        $norm -in @('~/.gitconfig.shared', '~/.gitconfig.workspace', '~/.gitconfig.local') -or
        $norm -match '/configs/git/\.gitconfig\.shared$' -or
        $norm -match '/workspaces/[^/]+/git/\.gitconfig$'
    )
}

function Build-UpdatedGitConfigContent {
    param([string]$ExistingContent, [string[]]$DesiredIncludes)

    $lines = if ($ExistingContent) { @(Normalize-TextLF $ExistingContent) -split "`n" } else { @() }
    $keptLines = [System.Collections.Generic.List[string]]::new()

    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -match '^\s*\[include\]\s*(?:[#;].*)?$') {
            $sectionBody = [System.Collections.Generic.List[string]]::new()
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\s*\[') {
                $bodyLine = $lines[$j]
                if ($bodyLine -match '^\s*path\s*=\s*(.+)$') {
                    if (-not (Test-IsPssManagedGitInclude $matches[1])) {
                        $sectionBody.Add($bodyLine)
                    }
                } elseif ($bodyLine.Trim() -ne '') {
                    $sectionBody.Add($bodyLine)
                }
                $j++
            }
            if ($sectionBody.Count -gt 0) {
                $keptLines.Add($line)
                foreach ($b in $sectionBody) { $keptLines.Add($b) }
            }
            $i = $j
            continue
        }
        $keptLines.Add($line)
        $i++
    }

    $headerLines = [System.Collections.Generic.List[string]]::new()
    foreach ($inc in $DesiredIncludes) {
        $formattedInc = if ($inc -match '\s') { "`"$inc`"" } else { $inc }
        $headerLines.Add("[include]")
        $headerLines.Add("`tpath = $formattedInc")
    }

    $trimmedBody = ($keptLines -join "`n").TrimStart("`n")
    if ($trimmedBody) {
        return ($headerLines -join "`n") + "`n" + $trimmedBody
    }
    return ($headerLines -join "`n")
}

function Get-GitConfigStatus {
    param([string]$Workspace)
    $localPath = Resolve-DynamicPath $Config.subsystems.git.localTarget
    $desired = @(Get-GitIncludeTargets -Workspace $Workspace)

    if (-not (Test-PathSafe $localPath -PathType Leaf)) {
        return [PSCustomObject]@{ Status = "Missing on Machine"; LocalPath = $localPath; Desired = $desired }
    }

    $raw = [System.IO.File]::ReadAllText($localPath, [System.Text.Encoding]::UTF8)
    $expected = Build-UpdatedGitConfigContent -ExistingContent $raw -DesiredIncludes $desired
    if ((Get-TextHash $raw) -eq (Get-TextHash $expected)) {
        return [PSCustomObject]@{ Status = "In Sync"; LocalPath = $localPath; Desired = $desired }
    }
    return [PSCustomObject]@{ Status = "Needs Update"; LocalPath = $localPath; Desired = $desired }
}

function Get-ExpectedGeminiFileContent {
    param([PSCustomObject]$FileEntry, [string]$Workspace)
    $repoAbs = Join-Path $ScriptDir $FileEntry.repoPath
    if (-not (Test-PathSafe $repoAbs -PathType Leaf)) { return $null }

    $sharedRaw = Normalize-TextLF ([System.IO.File]::ReadAllText($repoAbs, [System.Text.Encoding]::UTF8))
    if ($FileEntry.mode -eq 'template') {
        $homeForward = ConvertTo-ForwardPath (Get-EffectiveHome)
        return $sharedRaw.Replace('~/', "$homeForward/")
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($FileEntry.name -eq 'AGENTS.md') {
        $parts.Add("<!-- Managed by pss (shared + $Workspace). Edit repo files, not this output. -->")
    }
    $parts.Add($sharedRaw)

    if ($FileEntry.workspacePath) {
        $wsRel = $FileEntry.workspacePath.Replace('{workspace}', $Workspace)
        $wsAbs = Join-Path $ScriptDir $wsRel
        if (Test-PathSafe $wsAbs -PathType Leaf) {
            $wsRaw = (Normalize-TextLF ([System.IO.File]::ReadAllText($wsAbs, [System.Text.Encoding]::UTF8))).Trim()
            if ($wsRaw) { $parts.Add($wsRaw) }
        }
    }
    return ($parts -join "`n`n")
}

function Get-JunctionTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
    if ($item.Target) {
        $t = @($item.Target)[0]
        try { return [System.IO.Path]::GetFullPath($t) } catch { return $t }
    }
    return ""
}

function Get-DesiredSkillLinks {
    param([string]$Workspace)
    $skillsCfg = $Config.subsystems.skills
    $targetBase = Resolve-DynamicPath $skillsCfg.targetDir
    $sharedBase = Join-Path $ScriptDir $skillsCfg.repoDir
    $wsBase = if ($skillsCfg.workspaceDir) { Join-Path $ScriptDir ($skillsCfg.workspaceDir.Replace('{workspace}', $Workspace)) } else { $null }

    $links = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($wsBase -and (Test-PathSafe $wsBase -PathType Container)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $wsBase -Directory -ErrorAction SilentlyContinue)) {
            [void]$seen.Add($d.Name)
            $links.Add([PSCustomObject]@{ Name = $d.Name; Source = $d.FullName; Target = (Join-Path $targetBase $d.Name) })
        }
    }

    foreach ($name in @($skillsCfg.items)) {
        if ($seen.Contains($name)) { continue }
        $src = Join-Path $sharedBase $name
        if (Test-PathSafe $src -PathType Container) {
            [void]$seen.Add($name)
            $links.Add([PSCustomObject]@{ Name = $name; Source = $src; Target = (Join-Path $targetBase $name) })
        }
    }

    foreach ($mirror in @($skillsCfg.mirrorLinks)) {
        if ($mirror) {
            $links.Add([PSCustomObject]@{ Name = "skills-mirror"; Source = $targetBase; Target = (Resolve-DynamicPath $mirror) })
        }
    }

    return $links
}

function Get-DesiredPluginLinks {
    $plugCfg = $Config.subsystems.plugins
    $targetBase = Resolve-DynamicPath $plugCfg.targetDir
    $sharedBase = Join-Path $ScriptDir $plugCfg.repoDir
    $links = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($name in @($plugCfg.items)) {
        $src = Join-Path $sharedBase $name
        if (Test-PathSafe $src -PathType Container) {
            $links.Add([PSCustomObject]@{ Name = $name; Source = $src; Target = (Join-Path $targetBase $name) })
        }
    }
    return $links
}

function Get-JunctionStatus {
    param([string]$Source, [string]$Target)
    $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "Missing on Machine" }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return "Directory (Not Linked)" }
    $currentTarget = Get-JunctionTarget $Target
    if ([string]::IsNullOrEmpty($currentTarget)) { return "Stale Link" }
    $expectedFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    if ($currentTarget.TrimEnd('\', '/') -eq $expectedFull) { return "Linked" }
    return "Stale Link"
}

function Sync-JunctionLink {
    param([string]$Source, [string]$Target, [string]$BackupName, [string]$BackupRoot)
    $state = Get-JunctionStatus -Source $Source -Target $Target
    if ($state -eq 'Linked' -and -not $Force) {
        Write-Badge "OK" DarkGray "Already linked: $Target -> $Source"
        return $false
    }

    if ($WhatIf) {
        Write-Badge "WHAT-IF" Cyan "Would junction $Target -> $Source (current: $state)"
        return $false
    }

    $parent = Split-Path -Parent $Target
    if (-not (Test-PathSafe $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $existingItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($existingItem) {
        if ($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            # Remove reparse point directly without recursing into target contents
            if ($existingItem.PSIsContainer) {
                [System.IO.Directory]::Delete($Target)
            } else {
                [System.IO.File]::Delete($Target)
            }
        } else {
            New-BackupSnapshot -BackupRoot $BackupRoot -RelativeName $BackupName -LocalPath $Target
            Remove-Item -LiteralPath $Target -Recurse -Force
        }
    }

    New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
    Write-Badge "LINKED" Green "$Target -> $Source"
    return $true
}

function Invoke-ApplySubsystems {
    param([string]$Workspace, [string]$BackupDir)

    Write-Host "`n=== Applying Settings (Repo -> Machine: $Workspace) ===" -ForegroundColor Cyan
    $appliedCount = 0

    if (Should-ProcessSubsystem 'powershell') {
        Write-Host "`n[PowerShell Profile]" -ForegroundColor Yellow
        $psState = Get-PowerShellStatus
        if ($psState.Status -eq 'In Sync' -and -not $Force) {
            Write-Badge "OK" DarkGray "Already linked: $($psState.LocalPath)"
        } elseif ($WhatIf) {
            Write-Badge "WHAT-IF" Cyan "Would write profile loader -> $($psState.LocalPath)"
        } else {
            if ((Test-PathSafe $psState.LocalPath -PathType Leaf) -and -not (Test-IsManagedProfileLoader $psState.LocalPath)) {
                New-BackupSnapshot -BackupRoot $BackupDir -RelativeName 'powershell\Microsoft.PowerShell_profile.ps1' -LocalPath $psState.LocalPath
            }
            Write-Utf8File -Path $psState.LocalPath -Content $psState.Expected
            Write-Badge "LINKED" Green "Profile loader -> $($psState.LocalPath)"
            $appliedCount++
        }
    }

    if (Should-ProcessSubsystem 'git') {
        Write-Host "`n[Git Config]" -ForegroundColor Yellow
        $gitState = Get-GitConfigStatus -Workspace $Workspace
        if ($gitState.Status -eq 'In Sync' -and -not $Force) {
            Write-Badge "OK" DarkGray "Includes up to date in $($gitState.LocalPath)"
        } else {
            $existing = if (Test-PathSafe $gitState.LocalPath -PathType Leaf) {
                [System.IO.File]::ReadAllText($gitState.LocalPath, [System.Text.Encoding]::UTF8)
            } else { "" }
            $updated = Build-UpdatedGitConfigContent -ExistingContent $existing -DesiredIncludes $gitState.Desired
            if ($WhatIf) {
                Write-Badge "WHAT-IF" Cyan "Would update [include] blocks in $($gitState.LocalPath)"
            } else {
                if ($existing) {
                    New-BackupSnapshot -BackupRoot $BackupDir -RelativeName 'git\.gitconfig' -LocalPath $gitState.LocalPath
                }
                Write-Utf8File -Path $gitState.LocalPath -Content $updated
                Write-Badge "APPLIED" Green "Updated [include] layers (shared + $Workspace) -> $($gitState.LocalPath)"
                $appliedCount++
            }
        }
    }

    if (Should-ProcessSubsystem 'gemini') {
        Write-Host "`n[AI Agent Rules]" -ForegroundColor Yellow
        foreach ($f in $Config.subsystems.gemini.files) {
            $localPath = Resolve-DynamicPath $f.localPath
            $expected = Get-ExpectedGeminiFileContent -FileEntry $f -Workspace $Workspace
            if ($null -eq $expected) { continue }

            $localHash = Get-FileHashSafe $localPath
            $expHash = Get-TextHash $expected
            if (-not $Force -and $localHash -and ($localHash -eq $expHash)) {
                Write-Badge "OK" DarkGray "Already in sync: $localPath"
                continue
            }
            if ($WhatIf) {
                Write-Badge "WHAT-IF" Cyan "Would build $($f.name) -> $localPath"
                continue
            }
            if (Test-PathSafe $localPath -PathType Leaf) {
                New-BackupSnapshot -BackupRoot $BackupDir -RelativeName "gemini\$($f.name)" -LocalPath $localPath
            }
            Write-Utf8File -Path $localPath -Content $expected
            Write-Badge "APPLIED" Green "Built $($f.name) ($Workspace) -> $localPath"
            $appliedCount++
        }
    }

    if (Should-ProcessSubsystem 'skills') {
        Write-Host "`n[AI Skills]" -ForegroundColor Yellow
        $skillsDir = Resolve-DynamicPath $Config.subsystems.skills.targetDir
        if (-not $WhatIf -and -not (Test-PathSafe $skillsDir -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($skillsDir) | Out-Null
        }
        $desiredLinks = Get-DesiredSkillLinks -Workspace $Workspace
        $desiredTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($l in $desiredLinks) { [void]$desiredTargets.Add([System.IO.Path]::GetFullPath($l.Target)) }

        # Remove stale junctions in skillsDir pointing to other workspaces in this repo
        $wsRootPrefix = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $Config.workspacesDir)).TrimEnd('\', '/') + '\'
        if (Test-PathSafe $skillsDir -PathType Container) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $skillsDir -Force -ErrorAction SilentlyContinue)) {
                if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                $jt = Get-JunctionTarget $entry.FullName
                if ($jt -and $jt.StartsWith($wsRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and -not $desiredTargets.Contains([System.IO.Path]::GetFullPath($entry.FullName))) {
                    if ($WhatIf) {
                        Write-Badge "WHAT-IF" Cyan "Would unlink stale workspace skill: $($entry.FullName)"
                    } else {
                        [System.IO.Directory]::Delete($entry.FullName)
                        Write-Badge "UNLINKED" DarkYellow "Removed stale workspace skill link: $($entry.FullName)"
                        $appliedCount++
                    }
                }
            }
        }

        foreach ($link in $desiredLinks) {
            if (Sync-JunctionLink -Source $link.Source -Target $link.Target -BackupName "skills\$($link.Name)" -BackupRoot $BackupDir) {
                $appliedCount++
            }
        }
    }

    if (Should-ProcessSubsystem 'plugins') {
        Write-Host "`n[AI Plugins]" -ForegroundColor Yellow
        foreach ($link in (Get-DesiredPluginLinks)) {
            if (Sync-JunctionLink -Source $link.Source -Target $link.Target -BackupName "plugins\$($link.Name)" -BackupRoot $BackupDir) {
                $appliedCount++
            }
        }
    }

    if (-not $WhatIf) {
        Write-Host "`nDone. Updated $appliedCount item(s)." -ForegroundColor Green
        if ($appliedCount -gt 0) { Prune-Backups }
    }
}
#endregion

#region 7. Bootstrap Interactive Migration Engine
function Get-GitSections {
    param([string]$Text)
    $sections = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $Text) { return $sections }

    $currentHeader = $null
    $currentLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((Normalize-TextLF $Text) -split "`n")) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[#;].*)?$') {
            if ($currentHeader) {
                $sections.Add([PSCustomObject]@{ Header = $currentHeader; Text = ($currentLines -join "`n").TrimEnd() })
            }
            $currentHeader = $matches[1].Trim()
            $currentLines = [System.Collections.Generic.List[string]]::new()
            $currentLines.Add($line)
        } elseif ($currentHeader) {
            $currentLines.Add($line)
        }
    }
    if ($currentHeader) {
        $sections.Add([PSCustomObject]@{ Header = $currentHeader; Text = ($currentLines -join "`n").TrimEnd() })
    }
    return $sections
}

function Invoke-BootstrapWizard {
    param([string]$Workspace)
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    Write-Host "`n=== PSS Machine Bootstrapper (Workspace: $Workspace) ===" -ForegroundColor Cyan

    # 1. PowerShell Profile AST inspection
    if (Should-ProcessSubsystem 'powershell') {
        $localPs = Resolve-DynamicPath $Config.subsystems.powershell.localTarget
        $sharedPs = Join-Path $ScriptDir $Config.subsystems.powershell.sharedPath
        $wsPs = Join-Path $ScriptDir ($Config.subsystems.powershell.workspacePath.Replace('{workspace}', $Workspace))

        if (-not (Test-PathSafe $localPs -PathType Leaf)) {
            Write-Badge "INFO" DarkGray "No local PowerShell profile found at $localPs."
        } elseif (Test-IsManagedProfileLoader $localPs) {
            Write-Badge "OK" Green "PowerShell profile is already managed by pss loader."
        } else {
            $parseFuncs = {
                param([string]$Path)
                $map = [ordered]@{}
                if (-not (Test-PathSafe $Path -PathType Leaf)) { return $map }
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
                foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                    $map[$fn.Name] = $fn.Extent.Text
                }
                return $map
            }

            $localFuncs = & $parseFuncs $localPs
            $sharedFuncs = & $parseFuncs $sharedPs
            $wsFuncs = & $parseFuncs $wsPs
            $wsFunctionPaths = @{}
            if ($Workspace -eq 'work') {
                $worksetPath = Join-Path $ScriptDir 'workspaces\work\powershell\worksets.ps1'
                $worksetFuncs = & $parseFuncs $worksetPath
                foreach ($name in $worksetFuncs.Keys) {
                    if ($wsFuncs.Contains($name)) { throw "Duplicate workspace function '$name' in '$wsPs' and '$worksetPath'." }
                    $wsFuncs[$name] = $worksetFuncs[$name]
                    $wsFunctionPaths[$name] = $worksetPath
                }
            }

            $pending = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($name in $localFuncs.Keys) {
                $localHash = Get-TextHash $localFuncs[$name]
                $sharedHash = if ($sharedFuncs.Contains($name)) { Get-TextHash $sharedFuncs[$name] } else { $null }
                $wsHash = if ($wsFuncs.Contains($name)) { Get-TextHash $wsFuncs[$name] } else { $null }
                if ($localHash -eq $sharedHash -or $localHash -eq $wsHash) { continue }

                $kind = if ($sharedFuncs.Contains($name) -or $wsFuncs.Contains($name)) { "Modified" } else { "New" }
                $pending.Add([PSCustomObject]@{ Name = $name; Kind = $kind; Code = $localFuncs[$name] })
            }

            if ($pending.Count -eq 0) {
                Write-Badge "OK" Green "All functions in local PowerShell profile already match repo."
            } else {
                Write-Host "`nFound $($pending.Count) new/modified PowerShell function(s) in ${localPs}:" -ForegroundColor Yellow
                foreach ($item in $pending) {
                    Write-Host "  - [$($item.Kind)] function $($item.Name)" -ForegroundColor Cyan
                    if ($WhatIf) { continue }
                    if (-not $isInteractive) {
                        Write-Badge "ERROR" Red "Interactive session required to route '$($item.Name)'."
                        exit 1
                    }

                    $choice = (Read-Host "    Route 'function $($item.Name)' to: [S]hared, [W]orkspace ($Workspace), [L]ocal ($($PssLocalState.LocalProfile)), [I]gnore, [Q]uit").Trim().ToUpperInvariant()
                    switch ($choice) {
                        'Q' { Write-Host "Bootstrap aborted."; return }
                        'S' {
                            $targetText = if (Test-PathSafe $sharedPs -PathType Leaf) { Normalize-TextLF ([System.IO.File]::ReadAllText($sharedPs, [System.Text.Encoding]::UTF8)) } else { "" }
                            if ($item.Kind -eq 'Modified' -and $sharedFuncs.Contains($item.Name)) {
                                $sharedAst = [System.Management.Automation.Language.Parser]::ParseFile($sharedPs, [ref]$null, [ref]$null)
                                $oldAst = $sharedAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $item.Name }, $false) | Select-Object -First 1
                                if ($oldAst) {
                                    $updated = $sharedAst.Extent.Text.Substring(0, $oldAst.Extent.StartOffset) + $item.Code + $sharedAst.Extent.Text.Substring($oldAst.Extent.EndOffset)
                                    Write-Utf8File -Path $sharedPs -Content $updated
                                }
                            } elseif ($targetText -match '(?m)^#region 7\.') {
                                $m = [regex]::Match($targetText, '(?m)^#region 7\.')
                                $updated = $targetText.Substring(0, $m.Index) + $item.Code + "`n`n" + $targetText.Substring($m.Index)
                                Write-Utf8File -Path $sharedPs -Content $updated
                            } else {
                                Append-Utf8File -Path $sharedPs -Content $item.Code
                            }
                            Write-Badge "ROUTED" Green "Saved '$($item.Name)' -> $($Config.subsystems.powershell.sharedPath)"
                        }
                        'W' {
                            if ($item.Kind -eq 'Modified' -and $wsFuncs.Contains($item.Name)) {
                                $targetWsPs = if ($wsFunctionPaths.ContainsKey($item.Name)) { $wsFunctionPaths[$item.Name] } else { $wsPs }
                                $wsAst = [System.Management.Automation.Language.Parser]::ParseFile($targetWsPs, [ref]$null, [ref]$null)
                                $oldAst = $wsAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $item.Name }, $false) | Select-Object -First 1
                                if ($oldAst) {
                                    $updated = $wsAst.Extent.Text.Substring(0, $oldAst.Extent.StartOffset) + $item.Code + $wsAst.Extent.Text.Substring($oldAst.Extent.EndOffset)
                                    Write-Utf8File -Path $targetWsPs -Content $updated
                                }
                            } else {
                                Append-Utf8File -Path $wsPs -Content $item.Code
                            }
                            Write-Badge "ROUTED" Green "Saved '$($item.Name)' to the $Workspace workspace profile."
                        }
                        'L' {
                            $localOverride = $PssLocalState.LocalProfile
                            Append-Utf8File -Path $localOverride -Content $item.Code
                            Write-Badge "ROUTED" Green "Added '$($item.Name)' -> $localOverride"
                        }
                        default {
                            Write-Badge "SKIP" DarkGray "Ignored function '$($item.Name)'."
                        }
                    }
                }
            }
        }
    }

    # 2. Git Config section inspection
    if (Should-ProcessSubsystem 'git') {
        $localGit = Resolve-DynamicPath $Config.subsystems.git.localTarget
        $sharedGit = Join-Path $ScriptDir $Config.subsystems.git.sharedPath
        $wsGit = Join-Path $ScriptDir ($Config.subsystems.git.workspacePath.Replace('{workspace}', $Workspace))

        if (Test-PathSafe $localGit -PathType Leaf) {
            $localSections = Get-GitSections ([System.IO.File]::ReadAllText($localGit, [System.Text.Encoding]::UTF8))
            $sharedText = if (Test-PathSafe $sharedGit -PathType Leaf) { [System.IO.File]::ReadAllText($sharedGit, [System.Text.Encoding]::UTF8) } else { "" }
            $wsText = if (Test-PathSafe $wsGit -PathType Leaf) { [System.IO.File]::ReadAllText($wsGit, [System.Text.Encoding]::UTF8) } else { "" }

            $sharedHashes = @((Get-GitSections $sharedText) | ForEach-Object { Get-TextHash $_.Text })
            $wsHashes = @((Get-GitSections $wsText) | ForEach-Object { Get-TextHash $_.Text })

            $candidates = @($localSections | Where-Object {
                $_.Header -notmatch '^include(?:\b|$)|^includeIf\b|^credential' -and
                (Get-TextHash $_.Text) -notin $sharedHashes -and
                (Get-TextHash $_.Text) -notin $wsHashes
            })

            if ($candidates.Count -eq 0) {
                Write-Badge "OK" Green "All local .gitconfig sections are accounted for."
            } else {
                Write-Host "`nFound $($candidates.Count) non-managed section(s) in ${localGit}:" -ForegroundColor Yellow
                foreach ($sec in $candidates) {
                    Write-Host "  - [$($sec.Header)]" -ForegroundColor Cyan
                    if ($WhatIf) { continue }
                    if (-not $isInteractive) {
                        Write-Badge "ERROR" Red "Interactive session required to route git section [$($sec.Header)]."
                        exit 1
                    }

                    $choice = (Read-Host "    Route [$($sec.Header)] to: [S]hared, [W]orkspace ($Workspace), [L]ocal (keep in ~/.gitconfig), [Q]uit").Trim().ToUpperInvariant()
                    switch ($choice) {
                        'Q' { Write-Host "Bootstrap aborted."; return }
                        'S' {
                            Append-Utf8File -Path $sharedGit -Content $sec.Text
                            Write-Badge "ROUTED" Green "Added [$($sec.Header)] -> $($Config.subsystems.git.sharedPath)"
                        }
                        'W' {
                            Append-Utf8File -Path $wsGit -Content $sec.Text
                            Write-Badge "ROUTED" Green "Added [$($sec.Header)] -> workspaces/$Workspace/git/.gitconfig"
                        }
                        default {
                            Write-Badge "KEEP" DarkGray "Kept [$($sec.Header)] local in ~/.gitconfig"
                        }
                    }
                }
            }
        }
    }

    # 3. AI AGENTS.md inspection
    if (Should-ProcessSubsystem 'gemini') {
        $agentsEntry = $Config.subsystems.gemini.files | Where-Object { $_.name -eq 'AGENTS.md' } | Select-Object -First 1
        if ($agentsEntry) {
            $localAgents = Resolve-DynamicPath $agentsEntry.localPath
            $expected = Get-ExpectedGeminiFileContent -FileEntry $agentsEntry -Workspace $Workspace
            if ((Test-PathSafe $localAgents -PathType Leaf) -and $expected) {
                $localHash = Get-FileHashSafe $localAgents
                if ($localHash -ne (Get-TextHash $expected)) {
                    Write-Host "`nLocal AGENTS.md differs from synthesized ($Workspace) output:" -ForegroundColor Yellow
                    $tempExpected = Join-Path ([System.IO.Path]::GetTempPath()) "pss-agents-$([guid]::NewGuid().ToString('N')).md"
                    try {
                        Write-Utf8File -Path $tempExpected -Content $expected
                        Invoke-GitCmd @('diff', '--no-index', '--color', $tempExpected, $localAgents) | Out-Host
                    } finally {
                        Remove-Item -LiteralPath $tempExpected -Force -ErrorAction SilentlyContinue
                    }
                    if (-not $WhatIf -and $isInteractive) {
                        Write-Host "Use 'pss edit shared agents' or 'pss edit $Workspace agents' to port any rules you want to keep, then run 'pss apply -Include gemini'." -ForegroundColor DarkGray
                    }
                } else {
                    Write-Badge "OK" Green "AGENTS.md matches synthesized repo state."
                }
            }
        }
    }

    if ($Push -and -not $WhatIf) {
        Invoke-GitRemotePush -CommitMessage "chore: bootstrap $Workspace configs from $env:COMPUTERNAME"
    }
}
#endregion

#region 8. Execution Dispatcher
$subLower = if ($SubAction) { $SubAction.ToLowerInvariant() } else { '' }
$actionsWithoutActiveWs = ($Action.ToLowerInvariant() -eq 'workspace' -and ($subLower -in @('', 'list', 'current', 'use', 'new')))
$ActiveWorkspace = if ($actionsWithoutActiveWs) {
    if (Test-PathSafe $WorkspaceLocalFile -PathType Leaf) {
        $wsRaw = Get-Content -LiteralPath $WorkspaceLocalFile -Raw -ErrorAction SilentlyContinue
        if ($wsRaw) { $wsRaw.Trim() } else { '' }
    } else { '' }
} else {
    Get-ActiveWorkspace
}

if ($ActiveWorkspace) {
    Write-Host "`n[PSS] Active Workspace: " -ForegroundColor Cyan -NoNewline
    Write-Host "$ActiveWorkspace" -ForegroundColor Green
}

if ($Pull) {
    Write-Host "`n=== Pulling Latest Changes From Git ===" -ForegroundColor Cyan
    Invoke-GitCmd @('-C', $ScriptDir, 'pull')
    if ($LASTEXITCODE -ne 0) {
        Write-Badge "WARN" Yellow "git pull exited with code $LASTEXITCODE"
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
                foreach ($w in (Get-AvailableWorkspaces)) {
                    if ($w -eq $ActiveWorkspace) {
                        Write-Host " * $w (active)" -ForegroundColor Green
                    } else {
                        Write-Host "   $w" -ForegroundColor White
                    }
                }
                Write-Host "`nSwitch workspace: pss workspace use <name>" -ForegroundColor DarkGray
            }
            'current' {
                if ($ActiveWorkspace) {
                    Write-Host "`nActive workspace: $ActiveWorkspace" -ForegroundColor Green
                    Write-Host "Path: $(Join-Path $ScriptDir "workspaces\$ActiveWorkspace")" -ForegroundColor DarkGray
                } else {
                    Write-Host "`nNo active workspace configured. Run 'pss workspace use <name>'." -ForegroundColor Yellow
                }
            }
            'use' {
                if (-not $TargetName) {
                    Write-Badge "ERROR" Red "Workspace name required: pss workspace use <name>"
                    exit 1
                }
                $wsNorm = $TargetName.Trim().ToLowerInvariant()
                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would set active workspace to '$wsNorm'"
                    if (-not $NoApply) {
                        Invoke-ApplySubsystems -Workspace $wsNorm -BackupDir $backupDir
                    }
                    break
                }
                Set-ActiveWorkspace -Name $wsNorm
                $ActiveWorkspace = $wsNorm
                if (-not $NoApply) {
                    Invoke-ApplySubsystems -Workspace $ActiveWorkspace -BackupDir $backupDir
                }
            }
            'new' {
                if ($WhatIf) {
                    Write-Badge "WHAT-IF" Cyan "Would create workspace '$TargetName'"
                    break
                }
                New-WorkspaceContext -Name $TargetName
                if ($Push) { Invoke-GitRemotePush -CommitMessage "chore: add workspace $TargetName" }
            }
            'delete' {
                if (-not $TargetName) {
                    Write-Badge "ERROR" Red "Workspace name required: pss workspace delete <name>"
                    exit 1
                }
                $TargetName = $TargetName.Trim().ToLowerInvariant()
                if ($TargetName -eq $ActiveWorkspace) {
                    Write-Badge "ERROR" Red "Cannot delete active workspace '$TargetName'."
                    exit 1
                }
                $targetDir = Join-Path (Join-Path $ScriptDir $Config.workspacesDir) $TargetName
                if (Test-PathSafe $targetDir -PathType Container) {
                    if ($WhatIf) {
                        Write-Badge "WHAT-IF" Cyan "Would delete workspace '$TargetName'"
                        break
                    }
                    Remove-Item -LiteralPath $targetDir -Recurse -Force
                    Write-Badge "DELETED" Green "Deleted workspace '$TargetName'"
                    if ($Push) { Invoke-GitRemotePush -CommitMessage "chore: remove workspace $TargetName" }
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
        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

        if (Should-ProcessSubsystem 'powershell') {
            $psState = Get-PowerShellStatus
            $rows.Add([PSCustomObject]@{ Subsystem = "PowerShell"; Target = "Profile Loader"; Mode = "Loader"; Status = $psState.Status; Path = $psState.LocalPath })
        }

        if (Should-ProcessSubsystem 'git') {
            $gitState = Get-GitConfigStatus -Workspace $ActiveWorkspace
            $rows.Add([PSCustomObject]@{ Subsystem = "Git"; Target = ".gitconfig"; Mode = "Include"; Status = $gitState.Status; Path = $gitState.LocalPath })
        }

        if (Should-ProcessSubsystem 'gemini') {
            foreach ($f in $Config.subsystems.gemini.files) {
                $localPath = Resolve-DynamicPath $f.localPath
                $expected = Get-ExpectedGeminiFileContent -FileEntry $f -Workspace $ActiveWorkspace
                if ($null -eq $expected) { continue }
                $statusText = if (-not (Test-PathSafe $localPath -PathType Leaf)) {
                    "Missing on Machine"
                } elseif ((Get-FileHashSafe $localPath) -eq (Get-TextHash $expected)) {
                    "In Sync"
                } else {
                    "Modified"
                }
                $rows.Add([PSCustomObject]@{ Subsystem = "AI Rules"; Target = $f.name; Mode = $f.mode; Status = $statusText; Path = $localPath })
            }
        }

        if (Should-ProcessSubsystem 'skills') {
            foreach ($link in (Get-DesiredSkillLinks -Workspace $ActiveWorkspace)) {
                $rows.Add([PSCustomObject]@{
                    Subsystem = "AI Skill"
                    Target    = $link.Name
                    Mode      = "Junction"
                    Status    = (Get-JunctionStatus -Source $link.Source -Target $link.Target)
                    Path      = $link.Target
                })
            }
        }

        if (Should-ProcessSubsystem 'plugins') {
            foreach ($link in (Get-DesiredPluginLinks)) {
                $rows.Add([PSCustomObject]@{
                    Subsystem = "AI Plugin"
                    Target    = $link.Name
                    Mode      = "Junction"
                    Status    = (Get-JunctionStatus -Source $link.Source -Target $link.Target)
                    Path      = $link.Target
                })
            }
        }

        $rows | Format-Table -Property Subsystem, Target, Mode, Status, Path -AutoSize
    }

    { $_ -in @('apply', 'link') } {
        Invoke-ApplySubsystems -Workspace $ActiveWorkspace -BackupDir $backupDir
    }

    'diff' {
        Write-Host "`n=== Comparing Local Machine vs Repo ($ActiveWorkspace) ===" -ForegroundColor Cyan
        $diffCount = 0

        if (Should-ProcessSubsystem 'powershell') {
            $psState = Get-PowerShellStatus
            if ($psState.Status -ne 'In Sync') {
                $diffCount++
                Write-Host "`n--- PowerShell Profile ($($psState.Status)) ---" -ForegroundColor Magenta
                if ($psState.Status -eq 'Unmanaged Local File') {
                    $sharedPs = Join-Path $ScriptDir $Config.subsystems.powershell.sharedPath
                    Invoke-GitCmd @('diff', '--no-index', '--color', $sharedPs, $psState.LocalPath)
                } else {
                    Write-Host "Local: $($psState.LocalPath)" -ForegroundColor DarkGray
                    Write-Host "Expected loader:`n$($psState.Expected)" -ForegroundColor Green
                }
            }
        }

        if (Should-ProcessSubsystem 'git') {
            $gitState = Get-GitConfigStatus -Workspace $ActiveWorkspace
            if ($gitState.Status -ne 'In Sync') {
                $diffCount++
                Write-Host "`n--- Git Config ($($gitState.Status)) ---" -ForegroundColor Magenta
                Write-Host "Expected includes in $($gitState.LocalPath):" -ForegroundColor Cyan
                $gitState.Desired | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }
            }
        }

        if (Should-ProcessSubsystem 'gemini') {
            foreach ($f in $Config.subsystems.gemini.files) {
                $localPath = Resolve-DynamicPath $f.localPath
                $expected = Get-ExpectedGeminiFileContent -FileEntry $f -Workspace $ActiveWorkspace
                if (-not $expected) { continue }
                if (-not (Test-PathSafe $localPath -PathType Leaf)) {
                    $diffCount++
                    Write-Host "`n--- AI Rules: $($f.name) (Missing on Machine) ---" -ForegroundColor Magenta
                    continue
                }
                if ((Get-FileHashSafe $localPath) -ne (Get-TextHash $expected)) {
                    $diffCount++
                    Write-Host "`n--- AI Rules: $($f.name) ---" -ForegroundColor Magenta
                    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "pss-diff-$([guid]::NewGuid().ToString('N')).txt"
                    try {
                        Write-Utf8File -Path $tempFile -Content $expected
                        Invoke-GitCmd @('diff', '--no-index', '--color', $tempFile, $localPath)
                    } finally {
                        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        if ($diffCount -eq 0) {
            Write-Badge "OK" Green "All inspected configurations are in sync with '$ActiveWorkspace'."
        }
    }

    'edit' {
        $knownTargets = @('powershell', 'ps', 'profile', 'git', 'agents', 'gemini', 'skills.json')
        if ($SubAction -and -not $TargetName -and ($SubAction.ToLowerInvariant() -in $knownTargets)) {
            $layer = 'shared'
            $target = $SubAction.ToLowerInvariant()
        } else {
            $layer = if ($SubAction) { $SubAction.ToLowerInvariant() } else { 'shared' }
            $target = if ($TargetName) { $TargetName.ToLowerInvariant() } else { '' }
        }
        if (-not $target) {
            Write-Badge "ERROR" Red "Usage: pss edit [<shared|workspace>] <powershell|git|agents|gemini|skills.json>"
            exit 1
        }

        $relPath = if ($layer -eq 'shared') {
            switch ($target) {
                { $_ -in @('powershell', 'ps', 'profile') } { $Config.subsystems.powershell.sharedPath }
                'git'         { $Config.subsystems.git.sharedPath }
                'agents'      { 'configs/gemini/AGENTS.md' }
                'gemini'      { 'configs/gemini/GEMINI.md' }
                'skills.json' { 'configs/gemini/skills.json' }
                default       { $null }
            }
        } else {
            $wsName = if ($layer -eq 'workspace') { $ActiveWorkspace } else { $layer }
            $wsRoot = Join-Path (Join-Path $ScriptDir $Config.workspacesDir) $wsName
            if (-not (Test-PathSafe $wsRoot -PathType Container)) {
                Write-Badge "ERROR" Red "Workspace '$wsName' does not exist. Create it with 'pss workspace new $wsName'."
                exit 1
            }
            switch ($target) {
                { $_ -in @('powershell', 'ps', 'profile') } { $Config.subsystems.powershell.workspacePath.Replace('{workspace}', $wsName) }
                'git'    { $Config.subsystems.git.workspacePath.Replace('{workspace}', $wsName) }
                'agents' { "workspaces/$wsName/gemini/AGENTS.md" }
                'gemini' { "workspaces/$wsName/gemini/GEMINI.md" }
                default  { $null }
            }
        }

        if (-not $relPath) {
            Write-Badge "ERROR" Red "Unknown edit target '$target' for layer '$layer'."
            exit 1
        }

        $fullPath = Join-Path $ScriptDir $relPath
        if ($PathOnly) {
            Write-Output $fullPath
            break
        }

        if (-not (Test-PathSafe $fullPath -PathType Leaf)) {
            Write-Utf8File -Path $fullPath -Content ""
            Write-Badge "CREATED" Green "Created $relPath"
        }

        if ($env:EDITOR) {
            $editorTokens = [System.Management.Automation.PSParser]::Tokenize($env:EDITOR, [ref]$null) |
                Where-Object { $_.Type -in @('Command', 'CommandArgument', 'String') } |
                ForEach-Object { $_.Content }
            $editorExe = $editorTokens | Select-Object -First 1
            $editorArgs = @($editorTokens | Select-Object -Skip 1) + $fullPath
            & $editorExe @editorArgs
        } elseif (Get-Command code -ErrorAction SilentlyContinue) {
            & code $fullPath
        } else {
            Invoke-Item -LiteralPath $fullPath
        }
    }

    'bootstrap' {
        Invoke-BootstrapWizard -Workspace $ActiveWorkspace
    }

    'apps' {
        $sub = if ($SubAction) { $SubAction.ToLowerInvariant() } else { 'list' }
        $packages = @($Config.packages | Where-Object {
            -not $_.workspaces -or ($ActiveWorkspace -in $_.workspaces)
        })

        if ($sub -in @('install', 'update')) {
            $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
            if (-not $wingetCmd) {
                $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
                if (Test-PathSafe $candidate -PathType Leaf) { $wingetCmd = $candidate }
            }
            if (-not $wingetCmd) {
                Write-Badge "ERROR" Red "winget.exe not found."
                exit 1
            }

            if ($sub -eq 'install') {
                Write-Host "`n=== Installing Applications for '$ActiveWorkspace' (Winget) ===" -ForegroundColor Cyan
                foreach ($pkg in $packages) {
                    Write-Host "--> Installing $($pkg.name) ($($pkg.id))..." -ForegroundColor Cyan
                    if (-not $WhatIf) {
                        & $wingetCmd install --id $pkg.id -e --accept-package-agreements --accept-source-agreements
                    }
                }
            } else {
                Write-Host "`n=== Upgrading Applications (Winget) ===" -ForegroundColor Cyan
                if (-not $WhatIf) {
                    & $wingetCmd upgrade --all --accept-package-agreements --accept-source-agreements
                }
            }
        } else {
            Write-Host "`n=== Configured Applications ($ActiveWorkspace) ===" -ForegroundColor Cyan
            $packages | Format-Table -Property Name, Id, Category -AutoSize
        }
    }

    'fonts' {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) { & $setupScript -FontsOnly -WhatIf:$WhatIf }
    }

    'setup' {
        $setupScript = Join-Path $ScriptDir 'scripts\setup-windows.ps1'
        if (Test-PathSafe $setupScript -PathType Leaf) { & $setupScript -WhatIf:$WhatIf }
    }

    default {
        Write-Badge "ERROR" Red "Unknown action: '$Action'. Run 'pss help' for usage."
        exit 1
    }
}
#endregion
