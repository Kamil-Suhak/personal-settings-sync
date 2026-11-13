<#
.SYNOPSIS
    Isolated end-to-end verification suite for personal-settings-sync.
    Never modifies the real $HOME, $PROFILE, or active repo .workspace.local.
#>

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -eq $Expected) {
        $script:Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

Write-Host "`n=== 1. PowerShell AST Parse Validation ===" -ForegroundColor Cyan
$psFiles = @(
    'pss.ps1',
    'bootstrap.ps1',
    'setup.ps1',
    'scripts\setup-windows.ps1',
    'scripts\local-state.ps1',
    'scripts\profile-groups.ps1',
    'configs\powershell\Microsoft.PowerShell_profile.ps1',
    'configs\powershell\git.ps1',
    'configs\powershell\navigation.ps1',
    'configs\powershell\search.ps1',
    'configs\powershell\launchers.ps1',
    'configs\powershell\ai.ps1',
    'workspaces\personal\powershell\profile.ps1',
    'workspaces\work\powershell\profile.ps1',
    'workspaces\work\powershell\worksets.ps1'
)
foreach ($rel in $psFiles) {
    $full = Join-Path $RepoRoot $rel
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Syntax valid: $rel"
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host "    Parse error: $_" -ForegroundColor Red }
    }
}

Write-Host "`n=== 2. Isolated Sandbox End-to-End Tests ===" -ForegroundColor Cyan
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "pss-test-$([guid]::NewGuid().ToString('N'))"
$testRepo = Join-Path $sandbox 'repo'
$testHome = Join-Path $sandbox 'home'
$testDocs = Join-Path $sandbox 'docs'
$testLocalAppData = Join-Path $sandbox 'local-app-data'
$previousLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $testLocalAppData
$sharedProfileText = (@('Microsoft.PowerShell_profile', 'git', 'navigation', 'search', 'launchers', 'ai') |
    ForEach-Object { [System.IO.File]::ReadAllText((Join-Path $RepoRoot "configs\powershell\$_.ps1")) }) -join "`n"
$combinedProfileAst = [System.Management.Automation.Language.Parser]::ParseInput($sharedProfileText, [ref]$null, [ref]$null)

try {
    [System.IO.Directory]::CreateDirectory($testRepo) | Out-Null
    [System.IO.Directory]::CreateDirectory($testHome) | Out-Null
    [System.IO.Directory]::CreateDirectory($testDocs) | Out-Null

    # Copy repo files excluding .git and .backups
    foreach ($item in @('pss.ps1', 'sync.config.json', 'bootstrap.ps1', 'setup.ps1', 'configs', 'workspaces', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $item) -Destination (Join-Path $testRepo $item) -Recurse -Force
    }

    # Pre-seed machine state (existing .gitconfig with credentials, includeIf, quoted legacy include + comment, unmanaged $PROFILE, third-party skill & plugin, real dir blocking 'ask', broken junction for 'egm', and workspace-only personal skill)
    $existingGit = @"
[credential "https://github.com"]
	helper = !gh auth git-credential
[user]
	name = Kamil
[include]
	path = ~/.gitconfig.shared
	path = "~/.gitconfig.workspace" ; legacy workspace include
[includeIf "gitdir:~/work/"]
	path = ~/.gitconfig.work-extra
"@
    [System.IO.File]::WriteAllText((Join-Path $testHome '.gitconfig'), $existingGit, [System.Text.UTF8Encoding]::new($false))

    $psDir = Join-Path $testDocs 'PowerShell'
    [System.IO.Directory]::CreateDirectory($psDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $psDir 'Microsoft.PowerShell_profile.ps1'), "function custom_local_fn { `$args | ForEach-Object { `$_ } }`n", [System.Text.UTF8Encoding]::new($false))

    $thirdPartySkill = Join-Path $testHome '.agents\skills\third-party-skill'
    [System.IO.Directory]::CreateDirectory($thirdPartySkill) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $thirdPartySkill 'SKILL.md'), "# Third Party`n", [System.Text.UTF8Encoding]::new($false))

    # Pre-seed a blocking real directory for 'ask' and a broken junction for 'egm'
    $blockingAskDir = Join-Path $testHome '.agents\skills\ask'
    [System.IO.Directory]::CreateDirectory($blockingAskDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $blockingAskDir 'old.txt'), "stale`n", [System.Text.UTF8Encoding]::new($false))

    $staleTarget = Join-Path $sandbox 'deleted-plugin-target'
    [System.IO.Directory]::CreateDirectory($staleTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $testHome '.gemini\config\plugins')) | Out-Null
    $brokenEgmLink = Join-Path $testHome '.gemini\config\plugins\egm'
    cmd.exe /c mklink /J "`"$brokenEgmLink`"" "`"$staleTarget`"" | Out-Null
    [System.IO.Directory]::Delete($staleTarget)

    # Pre-seed a personal-workspace-only skill inside the test repo
    $wsOnlySkillSrc = Join-Path $testRepo 'workspaces\personal\skills\ws-skill'
    [System.IO.Directory]::CreateDirectory($wsOnlySkillSrc) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $wsOnlySkillSrc 'SKILL.md'), "# Workspace Skill`n", [System.Text.UTF8Encoding]::new($false))

    $thirdPartyPlugin = Join-Path $testHome '.gemini\config\plugins\flutter'
    [System.IO.Directory]::CreateDirectory($thirdPartyPlugin) | Out-Null

    $testPss = Join-Path $testRepo 'pss.ps1'
    . (Join-Path $testRepo 'scripts\local-state.ps1')
    $testState = Get-PssLocalStatePaths -Checkout $testRepo -LocalAppData $testLocalAppData

    $migrationHome = Join-Path $sandbox 'migration-home'
    $migrationCheckout = Join-Path $sandbox 'migration-checkout'
    [void][System.IO.Directory]::CreateDirectory($migrationHome)
    [void][System.IO.Directory]::CreateDirectory($migrationCheckout)
    $migrationState = Get-PssLocalStatePaths -Checkout $migrationCheckout -LocalAppData $testLocalAppData
    $oldRoots = Join-Path $migrationHome '.project-roots'
    $oldProfile = Join-Path $migrationHome '.profile.local.ps1'
    $oldWorkspace = Join-Path $migrationCheckout '.workspace.local'
    [System.IO.File]::WriteAllText($oldRoots, 'roots')
    [System.IO.File]::WriteAllText($oldProfile, 'profile')
    [System.IO.File]::WriteAllText($oldWorkspace, 'work')
    Invoke-PssLocalStateMigration -Paths $migrationState -Checkout $migrationCheckout -HomePath $migrationHome -WhatIf | Out-Null
    Assert-True ((Test-Path $oldRoots) -and -not (Test-Path $migrationState.ProjectRoots)) 'migration what-if leaves all files untouched'
    [void][System.IO.Directory]::CreateDirectory($migrationState.Root)
    [System.IO.File]::WriteAllText($migrationState.LocalProfile, 'conflicting')
    $conflict = $false
    try { Invoke-PssLocalStateMigration -Paths $migrationState -Checkout $migrationCheckout -HomePath $migrationHome }
    catch { $conflict = $true }
    Assert-True ($conflict -and (Test-Path $oldRoots) -and (Test-Path $oldProfile) -and (Test-Path $oldWorkspace)) 'migration conflict preserves every original'
    Remove-Item -LiteralPath $migrationState.LocalProfile
    $alternateProfileDir = Join-Path $sandbox 'alternate-profile'
    [void][System.IO.Directory]::CreateDirectory($alternateProfileDir)
    $alternateProfile = Join-Path $alternateProfileDir '.profile.local.ps1'
    [System.IO.File]::WriteAllText($alternateProfile, 'different profile')
    $profileConflict = $false
    try { Invoke-PssLocalStateMigration -Paths $migrationState -Checkout $migrationCheckout -HomePath $migrationHome -ProfileDirectory $alternateProfileDir }
    catch { $profileConflict = $true }
    Assert-True ($profileConflict -and (Test-Path $oldProfile) -and (Test-Path $alternateProfile) -and (Test-Path $oldWorkspace)) 'migration preserves distinct legacy profile files'
    Remove-Item -LiteralPath $alternateProfile
    $blockedLocal = Join-Path $sandbox 'blocked-local'
    [System.IO.File]::WriteAllText($blockedLocal, 'not a directory')
    $blockedState = Get-PssLocalStatePaths -Checkout $migrationCheckout -LocalAppData $blockedLocal
    $copyFailed = $false
    try { Invoke-PssLocalStateMigration -Paths $blockedState -Checkout $migrationCheckout -HomePath $migrationHome }
    catch { $copyFailed = $true }
    Assert-True ($copyFailed -and (Test-Path $oldRoots) -and (Test-Path $oldProfile) -and (Test-Path $oldWorkspace)) 'migration copy failure preserves every original'
    Invoke-PssLocalStateMigration -Paths $migrationState -Checkout $migrationCheckout -HomePath $migrationHome
    Assert-True ((-not (Test-Path $oldRoots)) -and (-not (Test-Path $oldProfile)) -and (-not (Test-Path $oldWorkspace)) -and
        [System.IO.File]::ReadAllText($migrationState.ProjectRoots) -eq 'roots' -and
        [System.IO.File]::ReadAllText($migrationState.LocalProfile) -eq 'profile' -and
        [System.IO.File]::ReadAllText($migrationState.Workspace) -eq 'work') 'migration verifies copies and removes originals'
    Invoke-PssLocalStateMigration -Paths $migrationState -Checkout $migrationCheckout -HomePath $migrationHome
    $otherState = Get-PssLocalStatePaths -Checkout $testRepo -LocalAppData $testLocalAppData
    Assert-True ($otherState.Workspace -ne $migrationState.Workspace) 'workspace state is isolated per checkout'

    # Test empty 0-byte .workspace.local handling
    [System.IO.File]::WriteAllText((Join-Path $testRepo '.workspace.local'), '', [System.Text.UTF8Encoding]::new($false))
    $curEmptyOut = (& $testPss workspace current -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($curEmptyOut -match 'No active workspace configured') "empty 0-byte .workspace.local handled without crashing"

    # Test POSIX flags (--no-apply / --what-if)
    & $testPss workspace use work --no-apply -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-Equal ((Get-Content $testState.Workspace -Raw).Trim()) 'work' "workspace use --no-apply sets local workspace"

    # Set active workspace to personal without applying yet
    & $testPss workspace use personal -NoApply -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-Equal ((Get-Content $testState.Workspace -Raw).Trim()) 'personal' "workspace use sets local workspace"

    # Test --what-if does not write loader or junctions
    & $testPss apply --what-if -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    $psAfterWhatIf = Get-Content (Join-Path $psDir 'Microsoft.PowerShell_profile.ps1') -Raw
    Assert-True ($psAfterWhatIf -match 'custom_local_fn') "apply --what-if leaves local profile untouched"
    Assert-True (-not (Test-Path (Join-Path $testHome '.gemini\AGENTS.md'))) "apply --what-if does not create AGENTS.md"

    # Test bootstrap -WhatIf detects custom_local_fn & skips includeIf
    $bootOut = (& $testPss bootstrap -WhatIf -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($bootOut -match 'function custom_local_fn') "bootstrap -WhatIf detects custom local function"
    Assert-True ($bootOut -notmatch 'includeIf') "bootstrap -WhatIf skips [includeIf] section"
    Assert-True ($bootOut -match '\[user\]') "bootstrap -WhatIf detects non-managed [user] section"

    # Apply for personal workspace
    & $testPss apply -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null

    # Verify backup was created for unmanaged $PROFILE
    Assert-True ((Get-ChildItem (Join-Path $testRepo '.backups') -Recurse -File -Filter 'Microsoft.PowerShell_profile.ps1').Count -eq 1) "apply backs up unmanaged local profile"

    # Verify PowerShell loader
    $loaderText = Get-Content (Join-Path $psDir 'Microsoft.PowerShell_profile.ps1') -Raw
    $expectedRepoPs = Join-Path $testRepo 'configs\powershell\Microsoft.PowerShell_profile.ps1'
    Assert-True ($loaderText -match [regex]::Escape($expectedRepoPs)) "apply writes profile loader pointing to repo"

    # Verify Git includes + preservation of credentials + includeIf + legacy cleanup + native git config resolution
    $gitText = Get-Content (Join-Path $testHome '.gitconfig') -Raw
    Assert-True ($gitText -match 'configs/git/\.gitconfig\.shared') "apply adds shared git include"
    Assert-True ($gitText -match 'workspaces/personal/git/\.gitconfig') "apply adds personal git include"
    Assert-True ($gitText -notmatch '~/\.gitconfig\.shared' -and $gitText -notmatch '~/\.gitconfig\.workspace') "apply removes legacy ~/.gitconfig.shared and quoted ~/.gitconfig.workspace includes"
    Assert-True ($gitText -match 'includeIf "gitdir:~/work/"') "apply preserves [includeIf] section"
    Assert-True ($gitText -match 'gh auth git-credential') "apply preserves local git credential helper"
    $gitEmail = (& git config --file (Join-Path $testHome '.gitconfig') --includes user.email 2>$null)
    Assert-Equal $gitEmail 'kamilsuhak@gmail.com' "git --includes resolves personal user.email"

    # Verify AI rules & skills.json template
    $agentsText = Get-Content (Join-Path $testHome '.gemini\AGENTS.md') -Raw
    Assert-True ($agentsText -match 'Global Agent Guidelines' -and $agentsText -match 'Personal Workspace Context') "AGENTS.md combines shared + personal"
    $skillsJson = Get-Content (Join-Path $testHome '.gemini\config\skills.json') -Raw
    $expectedHomeFwd = ($testHome -replace '\\', '/')
    Assert-True ($skillsJson -match [regex]::Escape("$expectedHomeFwd/.agents/skills")) "skills.json expands ~ to forward-slash HOME"

    # Verify junctions (including replacing blocking dir & broken junction) & workspace skill + third-party preservation
    $askSkillLink = Get-Item (Join-Path $testHome '.agents\skills\ask') -Force
    Assert-True ([bool]($askSkillLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) "skill 'ask' is a junction (replaced blocking directory)"
    Assert-True (Test-Path (Join-Path $askSkillLink.FullName 'SKILL.md')) "skill 'ask' junction resolves after replacing directory"
    Assert-True (Test-Path (Join-Path $testHome '.agents\skills\ws-skill\SKILL.md')) "personal workspace-only skill linked"
    Assert-True (Test-Path (Join-Path $thirdPartySkill 'SKILL.md')) "third-party skills preserved"
    $mirrorLink = Get-Item (Join-Path $testHome '.gemini\skills') -Force
    Assert-True ([bool]($mirrorLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) ".gemini/skills mirror junction created"
    $egmLink = Get-Item (Join-Path $testHome '.gemini\config\plugins\egm') -Force
    Assert-True ([bool]($egmLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) "plugin 'egm' is a junction (replaced broken junction)"
    Assert-True ((Test-Path (Join-Path $egmLink.FullName 'plugin.json')) -or (Test-Path $egmLink.FullName)) "plugin 'egm' junction target exists"
    Assert-True (Test-Path $thirdPartyPlugin) "third-party plugins preserved"

    # Verify status and diff are clean
    $statusOut = (& $testPss status -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($statusOut -notmatch 'Modified|Missing|Needs|Stale|Unmanaged') "status shows all subsystems In Sync / Linked"
    $diffOut = (& $testPss diff -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($diffOut -match 'in sync') "diff reports clean sync state"

    # Verify diff detects out-of-sync local AGENTS.md
    Add-Content -LiteralPath (Join-Path $testHome '.gemini\AGENTS.md') -Value "`n<!-- drift -->"
    $driftDiffOut = (& $testPss diff -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($driftDiffOut -match 'drift|AGENTS\.md') "diff reports local drift when AGENTS.md is modified"

    # Verify workspace switch to 'work' auto-updates git includes, AGENTS.md, and unlinks personal ws-skill
    & $testPss workspace use work -Force -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    $workGitText = Get-Content (Join-Path $testHome '.gitconfig') -Raw
    Assert-True ($workGitText -match 'workspaces/work/git/\.gitconfig' -and $workGitText -notmatch 'workspaces/personal/git/\.gitconfig') "workspace use work switches git include"
    $workAgentsText = Get-Content (Join-Path $testHome '.gemini\AGENTS.md') -Raw
    Assert-True ($workAgentsText -match 'Work Workspace Context' -and $workAgentsText -notmatch 'Personal Workspace Context') "workspace use work rebuilds AGENTS.md"
    Assert-True (-not (Test-Path (Join-Path $testHome '.agents\skills\ws-skill'))) "switching away from personal unlinks workspace-only skill"

    # Verify pss apply -Pull works when invoked from outside $testRepo
    $bareRemote = Join-Path $sandbox 'remote.git'
    $secondClone = Join-Path $sandbox 'second-clone'
    & git init --bare $bareRemote 2>&1 | Out-Null
    & git -C $testRepo init -b main 2>&1 | Out-Null
    & git -C $testRepo config user.name "Test"
    & git -C $testRepo config user.email "test@example.com"
    & git -C $testRepo remote add origin $bareRemote
    & git -C $testRepo add -A 2>&1 | Out-Null
    & git -C $testRepo commit -m "chore: initial sandbox" 2>&1 | Out-Null
    & git -C $testRepo push -u origin main 2>&1 | Out-Null
    & git clone $bareRemote $secondClone 2>&1 | Out-Null
    & git -C $secondClone config user.name "Test"
    & git -C $secondClone config user.email "test@example.com"
    Add-Content -LiteralPath (Join-Path $secondClone 'workspaces\work\gemini\AGENTS.md') -Value "`nRemote pulled rule"
    & git -C $secondClone add -A 2>&1 | Out-Null
    & git -C $secondClone commit -m "docs: remote update" 2>&1 | Out-Null
    & git -C $secondClone push origin main 2>&1 | Out-Null
    Push-Location $sandbox
    try {
        & $testPss apply -Pull -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
        Write-Host "`n=== 4. Workset Tests ===" -ForegroundColor Cyan
        . (Join-Path $RepoRoot 'workspaces\work\powershell\worksets.ps1')
        $global:__pss_state = $testState
        $repoOne = Join-Path $sandbox 'workset-repo-one'
        $repoTwo = Join-Path $sandbox 'workset-repo-two'
        [void][System.IO.Directory]::CreateDirectory($repoOne)
        [void][System.IO.Directory]::CreateDirectory($repoTwo)
        & git init -b '123/dashboard' $repoOne 2>&1 | Out-Null
        & git init -b 'feature/policy' $repoTwo 2>&1 | Out-Null
        $fileOne = Join-Path $repoOne 'one file.cs'
        $fileTwo = Join-Path $repoTwo 'policy.xml'
        [System.IO.File]::WriteAllText($fileOne, 'one')
        [System.IO.File]::WriteAllText($fileTwo, 'two')
        function code { $global:testCodeArguments = @($args); $global:LASTEXITCODE = 0 }
        function vs { param($Path, $Files) $global:testVsPath = $Path; $global:testVsFiles = $Files }
        $sharedProfileAst = $combinedProfileAst
        . (Join-Path $testRepo 'scripts\profile-groups.ps1')
        $vsSolutionsFn = $sharedProfileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-VsSolutions' }, $false) | Select-Object -First 1
        . ([scriptblock]::Create($vsSolutionsFn.Extent.Text))
        foreach ($name in @('Get-PssActiveWorkspace', 'which')) {
            $fn = $sharedProfileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name }, $false) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        $promptDefinition = $sharedProfileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'prompt' }, $false) | Select-Object -First 1
        . ([scriptblock]::Create($promptDefinition.Extent.Text))
        $global:__pss_root = $testRepo
        $global:__ansi = @{ Cyan = ''; Yellow = ''; Green = ''; Gray = ''; Reset = '' }
        $savedProfile = $PROFILE
        try {
            $PROFILE = Join-Path $testRepo 'configs\powershell\Microsoft.PowerShell_profile.ps1'
            $whichProfile = (which profile -h 6>&1 | Out-String)
            Assert-True ($whichProfile -match 'workset' -and $whichProfile -match 'Manages named issue file sets') 'which profile discovers workset synopsis'
            Assert-True ($whichProfile -match '(?s)\[search\].*?find\s+Interactive fuzzy.*?findstr\s+Filters piped input') 'which profile groups search functions with synopses'
            Assert-True ($whichProfile -match '(?s)\[launchers\].*?brave\s+Launches Brave Browser.*?vs\s+Opens Visual Studio') 'which profile groups program launchers with synopses'
            Assert-True ($whichProfile -match 'p\s+Universal Project Jumper: searches roots in %LOCALAPPDATA%\\PersonalSettingsSync\\project-roots') 'which profile shows the current project roots location'
            Assert-True ($whichProfile -match '\[worksets\]' -and $whichProfile -notmatch 'ConvertTo-WorksetName') 'which profile hides workset helpers'
            [System.IO.File]::WriteAllText($testState.Workspace, 'personal')
            $personalHelp = (which profile -h 6>&1 | Out-String)
            Assert-True ($personalHelp -notmatch '\[worksets\]') 'which profile excludes work-only groups in personal workspace'
            [System.IO.File]::WriteAllText($testState.Workspace, 'work')
        } finally {
            $PROFILE = $savedProfile
        }
        $worksetAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $testRepo 'workspaces\work\powershell\worksets.ps1'), [ref]$null, [ref]$null)
        $worksetFn = $worksetAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'workset' }, $false) | Select-Object -First 1
        $testLocalProfile = Join-Path $psDir 'Microsoft.PowerShell_profile.ps1'
        $savedLoader = [System.IO.File]::ReadAllText($testLocalProfile)
        try {
            [System.IO.File]::WriteAllText($testLocalProfile, $worksetFn.Extent.Text)
            $bootstrapOut = (& $testPss bootstrap -WhatIf -Include powershell -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
            Assert-True ($bootstrapOut -match 'All functions.*already match repo') 'bootstrap recognizes dot-sourced workset functions'
        } finally {
            [System.IO.File]::WriteAllText($testLocalProfile, $savedLoader)
        }
        $testPssText = [System.IO.File]::ReadAllText($testPss)
        $searchPath = Join-Path $testRepo 'configs\powershell\search.ps1'
        $launchersPath = Join-Path $testRepo 'configs\powershell\launchers.ps1'
        $worksetsPath = Join-Path $testRepo 'workspaces\work\powershell\worksets.ps1'
        $originalSearch = [System.IO.File]::ReadAllText($searchPath)
        $originalLaunchers = [System.IO.File]::ReadAllText($launchersPath)
        $originalWorksets = [System.IO.File]::ReadAllText($worksetsPath)
        try {
            $interactivePss = $testPssText.Replace('$isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected', '$isInteractive = $true')
            Assert-True ($interactivePss -ne $testPssText) 'bootstrap test enables interactive routing only in isolated copy'
            [System.IO.File]::WriteAllText($testPss, $interactivePss)
            [System.IO.File]::WriteAllText($testLocalProfile, "function find { 'bootstrap-shared' }`nfunction brave { 'bootstrap-launcher' }`nfunction workset { 'bootstrap-workspace' }`n")
            $routingOutput = & {
                function Read-Host {
                    param($Prompt)
                    if ($Prompt -match 'function find') { return 'S' }
                    if ($Prompt -match 'function brave') { return 'S' }
                    if ($Prompt -match 'function workset') { return 'W' }
                    throw "Unexpected bootstrap prompt: $Prompt"
                }
                & $testPss bootstrap -Include powershell -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String
            }
            $updatedSearch = [System.IO.File]::ReadAllText($searchPath)
            $updatedLaunchers = [System.IO.File]::ReadAllText($launchersPath)
            $updatedWorksets = [System.IO.File]::ReadAllText($worksetsPath)
            Assert-True ($updatedSearch -match "function find \{ 'bootstrap-shared' \}" -and $updatedSearch -match 'function findstr') 'bootstrap updates shared function in its source file'
            Assert-True ($updatedLaunchers -match "function brave \{ 'bootstrap-launcher' \}" -and $updatedLaunchers -match 'function vs') 'bootstrap updates a launcher in its source file'
            Assert-True ($updatedWorksets -match "function workset \{ 'bootstrap-workspace' \}" -and $updatedWorksets -match 'function Get-WorksetContext') 'bootstrap updates workset function in its source file'
            Assert-True ($routingOutput -match [regex]::Escape($searchPath) -and $routingOutput -match [regex]::Escape($worksetsPath)) 'bootstrap reports actual destination paths'
        } finally {
            [System.IO.File]::WriteAllText($testPss, $testPssText)
            [System.IO.File]::WriteAllText($testLocalProfile, $savedLoader)
            [System.IO.File]::WriteAllText($searchPath, $originalSearch)
            [System.IO.File]::WriteAllText($launchersPath, $originalLaunchers)
            [System.IO.File]::WriteAllText($worksetsPath, $originalWorksets)
        }
        $personalPath = Join-Path $testRepo 'workspaces\personal\powershell\profile.ps1'
        $originalPersonal = [System.IO.File]::ReadAllText($personalPath)
        $localOverride = Join-Path $sandbox 'local-override.ps1'
        $loaderTest = Join-Path $sandbox 'profile-loader-test.ps1'
        try {
            [System.IO.File]::WriteAllText($personalPath, '$global:workspaceSawShared = [bool](Get-Command find -CommandType Function -ErrorAction SilentlyContinue); function find { "workspace" }')
            [System.IO.File]::WriteAllText($localOverride, '$global:localSawWorkspace = (find) -eq "workspace"; function find { "local" }')
            $loaderSource = [System.IO.File]::ReadAllText((Join-Path $testRepo 'configs\powershell\Microsoft.PowerShell_profile.ps1'))
            $sharedLoader = $loaderSource.Substring($loaderSource.IndexOf(". (Join-Path `$global:__pss_root 'scripts\profile-groups.ps1')"))
            $sharedLoader = $sharedLoader.Substring(0, $sharedLoader.IndexOf('#region 4.'))
            $workspaceLoader = $loaderSource.Substring($loaderSource.IndexOf('#region 7.'))
            $loaderScript = @"
`$global:__pss_root = '$($testRepo.Replace("'", "''"))'
`$global:__pss_state = @{ LocalProfile = '$($localOverride.Replace("'", "''"))' }
function Get-PssActiveWorkspace { 'personal' }
$sharedLoader
$workspaceLoader
if (-not `$global:workspaceSawShared -or -not `$global:localSawWorkspace -or (find) -ne 'local' -or `$null -eq `$global:__git_fetch_cache) { exit 1 }
"@
            [System.IO.File]::WriteAllText($loaderTest, $loaderScript)
            & pwsh -NoLogo -NoProfile -File $loaderTest
            Assert-Equal $LASTEXITCODE 0 'loader dot-sources initialized shared groups before workspace and local overrides'
        } finally {
            [System.IO.File]::WriteAllText($personalPath, $originalPersonal)
        }
        Push-Location $repoOne
        try {
            workset new
            $worksetDir = Get-WorksetDirectory '123-dashboard'
            Assert-True (Test-Path (Join-Path $worksetDir 'files.txt')) 'workset derives a Windows-safe name from branch'
            prompt 6>$null | Out-Null
            Assert-Equal $global:cw '123-dashboard' 'prompt sets current workset for the active checkout and branch'
            Push-Location $sandbox
            try {
                prompt 6>$null | Out-Null
                Assert-True ($null -eq $global:cw) 'prompt clears current workset outside a repository'
            } finally { Pop-Location }
            workset new 'alternate-name'
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset when multiple worksets match'
            function Read-Host { 'y' }
            workset delete 'alternate-name'
            Remove-Item function:\Read-Host
            & git -C $repoOne symbolic-ref HEAD refs/heads/different
            $global:__git_cache_repo = $null
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset on another branch'
            & git -C $repoOne symbolic-ref HEAD refs/heads/123/dashboard
            $global:__git_cache_repo = $null
            prompt 6>$null | Out-Null
            Assert-Equal $global:cw '123-dashboard' 'prompt restores current workset when returning to its branch'
            [System.IO.File]::WriteAllText($testState.Workspace, 'personal')
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset outside the work workspace'
            [System.IO.File]::WriteAllText($testState.Workspace, 'work')
            workset add $fileOne
            workset open
            Assert-True ($global:testCodeArguments -contains $fileOne) 'single-repository workset without a solution selects VS Code'
            $noSolution = $false
            try { workset open -Vs } catch { $noSolution = $true }
            Assert-True $noSolution 'explicit VS reports a missing solution'
            [System.IO.File]::WriteAllText((Join-Path $repoOne 'app.sln'), '')
            workset open
            Assert-True ($global:testVsPath -eq $repoOne -and $global:testVsFiles -contains $fileOne) 'single-repository workset selects VS'
            workset add '123-dashboard' $fileTwo
            workset open
            Assert-True ($global:testCodeArguments -contains $repoOne -and $global:testCodeArguments -contains $repoTwo -and
                $global:testCodeArguments -contains $fileOne -and $global:testCodeArguments -contains $fileTwo) 'cross-repository workset opens all roots and files in VS Code'
            $rejectedVs = $false
            try { workset open -Vs } catch { $rejectedVs = $true }
            Assert-True $rejectedVs 'cross-repository workset rejects Visual Studio'
            & git -C $repoTwo symbolic-ref HEAD refs/heads/changed
            $branchWarnings = @(workset open 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-True (($branchWarnings | Out-String) -match 'Branch mismatch') 'workset warns when a recorded repository branch changes'
            $docDir = Join-Path $sandbox 'documentation'
            [void][System.IO.Directory]::CreateDirectory($docDir)
            $docFile = Join-Path $docDir 'document.md'
            [System.IO.File]::WriteAllText($docFile, 'docs')
            workset add '123-dashboard' $docFile
            workset open 3>$null
            Assert-True ($global:testCodeArguments -contains $docDir -and $global:testCodeArguments -contains $docFile) 'workset supports files outside repositories'
            $collision = $false
            try { workset new '123-dashboard' } catch { $collision = $true }
            Assert-True $collision 'workset name collisions do not overwrite existing data'
            Remove-Item -LiteralPath $fileTwo
            $missing = $false
            try { workset open } catch { $missing = $true }
            Assert-True $missing 'workset rejects missing files before launching an editor'
            [System.IO.File]::WriteAllText($fileTwo, 'two')
            workset archive
            Assert-True (Test-Path (Get-WorksetDirectory '123-dashboard' -Archived)) 'workset archive preserves the list'
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset after archiving'
            workset restore '123-dashboard'
            Assert-True (Test-Path (Join-Path $worksetDir 'files.txt')) 'workset restore returns the list'
            prompt 6>$null | Out-Null
            Assert-Equal $global:cw '123-dashboard' 'prompt restores current workset after restoring the workset'
            workset delete -WhatIf
            Assert-True ((Test-Path $worksetDir) -and (Test-Path $fileOne)) 'workset delete what-if preserves list and source'
            $synopsis = (Get-Help workset).Synopsis
            Assert-True ($synopsis -match 'issue file sets') 'dot-sourced workset exposes synopsis'
            function Read-Host { 'y' }
            workset delete
            Remove-Item function:\Read-Host
            Assert-True ((-not (Test-Path $worksetDir)) -and (Test-Path $fileOne) -and (Test-Path $fileTwo)) 'workset delete removes only the list'
        } finally {
            Pop-Location
            Remove-Item function:\code, function:\vs -ErrorAction SilentlyContinue
            Remove-Item function:\Read-Host -ErrorAction SilentlyContinue
        }
    } finally {
        Pop-Location
    }
    $pulledAgentsText = Get-Content (Join-Path $testHome '.gemini\AGENTS.md') -Raw
    Assert-True ($pulledAgentsText -match 'Remote pulled rule') "apply -Pull works when invoked outside repo root"

    # Verify apps filtering per workspace
    $workApps = (& $testPss apps -HomeOverride $testHome -DocumentsOverride $testDocs | Out-String)
    Assert-True ($workApps -notmatch 'Spotify' -and $workApps -match 'GitHub CLI') "work apps exclude personal-only Spotify"

    # Verify edit -PathOnly
    $editSharedPs = (& $testPss edit shared powershell -PathOnly -HomeOverride $testHome -DocumentsOverride $testDocs | Select-Object -Last 1).Trim()
    Assert-Equal $editSharedPs (Join-Path $testRepo 'configs\powershell\Microsoft.PowerShell_profile.ps1') "edit shared powershell -PathOnly resolves shared profile"
    $editShortAgents = (& $testPss edit agents -PathOnly -HomeOverride $testHome -DocumentsOverride $testDocs | Select-Object -Last 1).Trim()
    Assert-Equal $editShortAgents (Join-Path $testRepo 'configs\gemini\AGENTS.md') "edit agents shorthand resolves shared AGENTS.md"

    # Verify workspace new & delete (and -WhatIf does not mutate)
    & $testPss workspace new school -WhatIf -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-True (-not (Test-Path (Join-Path $testRepo 'workspaces\school'))) "workspace new -WhatIf does not create folder"
    & $testPss workspace new school -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-True (Test-Path (Join-Path $testRepo 'workspaces\school\powershell\profile.ps1')) "workspace new scaffolds directory"
    & $testPss workspace delete school -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-True (-not (Test-Path (Join-Path $testRepo 'workspaces\school'))) "workspace delete removes inactive workspace"

    # Verify setup-windows.ps1 -WhatIf runs cleanly and reads config
    $setupWinOut = (& (Join-Path $testRepo 'scripts\setup-windows.ps1') -WhatIf *>&1 | Out-String)
    Assert-True ($setupWinOut -match 'WHAT-IF') "scripts/setup-windows.ps1 -WhatIf runs without error"

    # Verify shared profile functions work cleanly
    Write-Host "`n=== 3. Profile Function Smoke Tests ===" -ForegroundColor Cyan
    $profileAst = $combinedProfileAst
    $jwtFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'jwt' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($jwtFn.Extent.Text))
    # Header: {"alg":"HS256","typ":"JWT"}, Payload: {"sub":"123","role":"admin"}
    $sampleJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMiLCJyb2xlIjoiYWRtaW4ifQ.sig"
    $jwtOut = (jwt $sampleJwt 6>&1 | Out-String)
    Assert-True ($jwtOut -match '"role": "admin"' -and $jwtOut -match '"alg": "HS256"') "jwt decodes header and payload offline"

    # Test ExtraArgs binding on findstr, p, find, wip and Get-PssActiveWorkspace empty file guard
    $getWsFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-PssActiveWorkspace' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($getWsFn.Extent.Text))
    [System.IO.File]::WriteAllText($testState.Workspace, '', [System.Text.UTF8Encoding]::new($false))
    $global:__pss_root = $testRepo
    $global:__pss_state = $testState
    Assert-Equal (Get-PssActiveWorkspace) 'personal' "Get-PssActiveWorkspace falls back on empty 0-byte .workspace.local"

    $findstrFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'findstr' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($findstrFn.Extent.Text))
    $findstrOut = (@('alpha line', 'beta line') | findstr 'alpha' -v *>&1 | Out-String)
    Assert-True ($findstrOut -match 'beta line' -and $findstrOut -notmatch 'alpha line') "findstr binds -v alias natively on piped input"

    foreach ($fnName in @('wip', 'p', 'find', 'findstr')) {
        $fnAst = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
        Assert-True ($fnAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains 'ExtraArgs') "function $fnName has no ExtraArgs POSIX glue"
    }

    # Test prompt updates $cb and $gr in git repo without errors
    $promptFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'prompt' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($promptFn.Extent.Text))

    # Verify passbolt removed, brave in shared, amend & undo merged into commit, st/catchup/gsync consolidated into repo + diff
    $personalAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'workspaces\personal\powershell\profile.ps1'), [ref]$null, [ref]$null)
    foreach ($workspaceName in @('personal', 'work')) {
        $workspaceAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot "workspaces\$workspaceName\powershell\profile.ps1"), [ref]$null, [ref]$null)
        $askFn = $workspaceAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'ask' }, $false) | Select-Object -First 1
        $capturedPrompt = & {
            param($Definition, $Workspace, $TestHomeDir)
            function copilot {}
            function agy {}
            function Get-TerminalAskContext {
                param($Question, $Piped, $Clean)
                [pscustomobject]@{ History = 'history'; Output = 'output'; PipedSection = ''; Question = $Question }
            }
            function Invoke-AskCliProcess {
                param($ExecutablePath, $Arguments, $Label)
                $Arguments[-1]
            }
            . ([scriptblock]::Create($Definition))
            $savedUserProfile = $env:USERPROFILE
            try {
                $env:USERPROFILE = $TestHomeDir
                if ($Workspace -eq 'personal') { ask -KeepHistory 'test question' } else { ask 'test question' }
            } finally {
                $env:USERPROFILE = $savedUserProfile
            }
        } $askFn.Extent.Text $workspaceName $testHome
        Assert-True ($capturedPrompt -match 'Minimize tool and MCP calls and prioritize fast responses while remaining accurate' -and $capturedPrompt -match '\[User Question\]\s*test question') "$workspaceName ask sends speed guidance and the question"
    }
    $sharedNames = @($profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name)
    $personalNames = @($personalAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name)
    Assert-True ($sharedNames -contains 'brave' -and $personalNames -notcontains 'brave') "brave moved to shared profile"
    Assert-True ($personalNames -notcontains 'passbolt' -and $personalNames -notcontains 'passbolt-stop' -and $personalNames -notcontains 'Invoke-PassboltCompose') "passbolt removed from personal profile"
    Assert-True ($sharedNames -contains 'commit' -and $sharedNames -notcontains 'amend' -and $sharedNames -notcontains 'undo') "amend and undo merged into commit"
    Assert-True ($sharedNames -contains 'repo' -and $sharedNames -contains 'diff' -and $sharedNames -notcontains 'st' -and $sharedNames -notcontains 'catchup' -and $sharedNames -notcontains 'gsync') "st/catchup/gsync consolidated into repo and diff"

    $profileRaw = $sharedProfileText
    Assert-True ($profileRaw -match 'Remove-Alias\s+-Name\s+diff\s+-Force' -and $profileRaw -match 'Compare-Object' -and $profileRaw -match 'Copy-Item') "profile explicitly documents built-in diff and copy alias overrides"

    # Test commit / commit amend / commit undo in isolated git repo
    $clearCacheFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Clear-GitBranchCache' }, $false) | Select-Object -First 1
    $commitFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'commit' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($clearCacheFn.Extent.Text))
    . ([scriptblock]::Create($commitFn.Extent.Text))
    $commitRepo = Join-Path $sandbox 'commit-repo'
    [System.IO.Directory]::CreateDirectory($commitRepo) | Out-Null
    & git -C $commitRepo init -b main 2>&1 | Out-Null
    & git -C $commitRepo config user.name "Test"
    & git -C $commitRepo config user.email "test@example.com"
    [System.IO.File]::WriteAllText((Join-Path $commitRepo 'a.txt'), "one`n")
    & git -C $commitRepo add -A 2>&1 | Out-Null
    & git -C $commitRepo commit -m "chore: init" 2>&1 | Out-Null
    Push-Location $commitRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $commitRepo 'b.txt'), "two`n")
        commit "feat: second commit" *>&1 | Out-Null
        Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'feat: second commit' "commit <message> creates commit"

        [System.IO.File]::WriteAllText((Join-Path $commitRepo 'b.txt'), "two amended`n")
        commit amend *>&1 | Out-Null
        Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'feat: second commit' "commit amend preserves message without extra args"
        Assert-True ((Get-Content (Join-Path $commitRepo 'b.txt') -Raw) -match 'two amended') "commit amend updates commit contents"

        commit amend "fix: updated msg" *>&1 | Out-Null
        Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'fix: updated msg' "commit amend <message> updates commit message"

        commit undo *>&1 | Out-Null
        Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'chore: init' "commit undo resets HEAD~1"
        $staged = (& git diff --cached --name-only) -join ','
        Assert-True ($staged -match 'b\.txt') "commit undo keeps changes staged"

        $global:__show_prompt_timer = $false
        $promptOut = (prompt 6>&1 | Out-String)
        Assert-Equal $global:cb 'main' "prompt populates `$cb with current git branch"
        Assert-Equal $global:gr $commitRepo "prompt populates `$gr with git repository root"
        Assert-True ($promptOut -notmatch '⏱') "prompt hides command timer segment by default"
    } finally {
        Pop-Location
    }

    # Test p fails cleanly with no fallback directories when USERPROFILE has no .project-roots
    $pNoRootsScript = Join-Path $sandbox 'test-p-noroots.ps1'
    $pFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'p' }, $false) | Select-Object -First 1
    [System.IO.File]::WriteAllText($pNoRootsScript, ("`$global:__pss_state = @{ ProjectRoots = '$($testState.ProjectRoots)' }`n" + $pFn.Extent.Text + "`np anything`n"), [System.Text.UTF8Encoding]::new($false))
    $pNoRootsOut = & {
        $prevProf = $env:USERPROFILE
        $env:USERPROFILE = $testHome
        try {
            pwsh -NoProfile -File $pNoRootsScript 2>&1 | Out-String
        } finally {
            $env:USERPROFILE = $prevProf
        }
    }
    Assert-True ($pNoRootsOut -match 'No project roots configured') "p fails cleanly when no project roots configured"

    # Test p jumps cleanly when matching directory exists (guards against [string]$Target parameter shadowing)
    $pJumpScript = Join-Path $sandbox 'test-p-jump.ps1'
    $pRootDir = Join-Path $sandbox 'projects-root'
    $pWorkDir = Join-Path $pRootDir 'work-helpers'
    [System.IO.Directory]::CreateDirectory($pWorkDir) | Out-Null
    [System.IO.File]::WriteAllText($testState.ProjectRoots, "$pRootDir`n", [System.Text.UTF8Encoding]::new($false))
    $pJumpContent = "`$global:__pss_state = @{ ProjectRoots = '$($testState.ProjectRoots)' }`n" + $pFn.Extent.Text + "`nSet-Location '$sandbox'`np work-h`n(Get-Location).Path`n"
    [System.IO.File]::WriteAllText($pJumpScript, $pJumpContent, [System.Text.UTF8Encoding]::new($false))
    $pJumpOut = & {
        $prevProf = $env:USERPROFILE
        $env:USERPROFILE = $testHome
        try {
            pwsh -NoProfile -File $pJumpScript 2>&1 | Out-String
        } finally {
            $env:USERPROFILE = $prevProf
        }
    }
    Assert-True ($pJumpOut -match [regex]::Escape($pWorkDir)) "p jumps to matching directory without parameter shadowing"

    # Test cmp diff output
    $cmpFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'cmp' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($cmpFn.Extent.Text))
    $cmpA = Join-Path $sandbox 'cmp-a.txt'
    $cmpB = Join-Path $sandbox 'cmp-b.txt'
    [System.IO.File]::WriteAllText($cmpA, "line one`n")
    [System.IO.File]::WriteAllText($cmpB, "line one`n")
    $cmpSame = (cmp $cmpA $cmpB *>&1 | Out-String)
    Assert-True ($cmpSame -match 'Files are identical') "cmp reports identical files"
    [System.IO.File]::WriteAllText($cmpB, "line two`n")
    $cmpDiff = (cmp $cmpA $cmpB *>&1 | Out-String)
    Assert-True ($cmpDiff -match 'Files differ' -and $cmpDiff -match '-line one' -and $cmpDiff -match '\+line two') "cmp shows git diff --no-index when files differ"

    # Test vs solution lookup & parent traversal via -WhatIf
    $vsFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'vs' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($vsFn.Extent.Text))
    $slnDir = Join-Path $sandbox 'dotnet-proj'
    $nestedDir = Join-Path $slnDir 'src\Api\Controllers'
    [System.IO.Directory]::CreateDirectory((Join-Path $slnDir 'src\Api\bin\Debug')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $slnDir 'src\Api\obj')) | Out-Null
    [System.IO.Directory]::CreateDirectory($nestedDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $slnDir 'MyApp.sln'), "Microsoft Visual Studio Solution File`n")
    $nestedFile = Join-Path $nestedDir 'UsersController.cs'
    [System.IO.File]::WriteAllText($nestedFile, "class UsersController {}`n")
    $vsDirOut = (vs $nestedDir -Verbose -WhatIf 4>&1 | Out-String)
    Assert-True ($vsDirOut -match 'MyApp\.sln') "vs traverses parent directories to find .sln"
    $vsFileOut = (vs $nestedFile -Verbose -WhatIf 4>&1 | Out-String)
    Assert-True ($vsFileOut -match 'MyApp\.sln' -and $vsFileOut -match 'UsersController\.cs') "vs accepts a file and opens solution + file"
    $anotherFile = Join-Path $nestedDir 'Other.cs'
    [System.IO.File]::WriteAllText($anotherFile, 'class Other {}')
    $vsFilesOut = (vs $slnDir -Files @($nestedFile, $anotherFile) -Verbose -WhatIf 4>&1 | Out-String)
    Assert-True ($vsFilesOut -match 'MyApp\.sln' -and $vsFilesOut -match 'UsersController\.cs' -and $vsFilesOut -match 'Other\.cs') "vs includes every requested file with the solution"
    $vsTooShallow = (vs $nestedDir -MaxDepth 1 -WhatIf -ErrorAction Continue 2>&1 | Out-String)
    Assert-True ($vsTooShallow -match 'No \.sln or \.slnx file found') "vs respects MaxDepth limit"

    $workAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'workspaces\work\powershell\profile.ps1'), [ref]$null, [ref]$null)
    $slnCleanFn = $workAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'slnclean' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($slnCleanFn.Extent.Text))
    slnclean -Path $slnDir -WhatIf | Out-Null
    Assert-True (Test-Path (Join-Path $slnDir 'src\Api\bin')) "slnclean -WhatIf preserves bin/"
    slnclean -Path $slnDir | Out-Null
    Assert-True (-not (Test-Path (Join-Path $slnDir 'src\Api\bin')) -and -not (Test-Path (Join-Path $slnDir 'src\Api\obj'))) "slnclean removes bin/ and obj/"

    # Test repo, diff, nb, and cooldown / base-branch detection in isolated bare-remote + two-clone git setup
    foreach ($fnName in @('Invoke-GitFetchWithCooldown', 'Resolve-GitBaseBranch', 'Show-GitCommitComparison', 'repo', 'diff', 'b', 'nb')) {
        $fnDef = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
        . ([scriptblock]::Create($fnDef.Extent.Text))
    }
    Remove-Alias -Name diff -Force -ErrorAction SilentlyContinue
    $global:__git_fetch_cache = @{}

    $bareOrigin = Join-Path $sandbox 'origin.git'
    $cloneA = Join-Path $sandbox 'clone-a'
    $cloneB = Join-Path $sandbox 'clone-b'
    & git init --bare -b main $bareOrigin 2>&1 | Out-Null
    & git clone $bareOrigin $cloneA 2>&1 | Out-Null
    & git -C $cloneA config user.name "Test"
    & git -C $cloneA config user.email "test@example.com"
    & git -C $cloneA checkout -b main 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cloneA 'app.txt'), "v1`n")
    & git -C $cloneA add -A 2>&1 | Out-Null
    & git -C $cloneA commit -m "chore: initial main" 2>&1 | Out-Null
    & git -C $cloneA push -u origin main 2>&1 | Out-Null

    # Push a develop branch too so develop -> beta -> main priority can be verified
    & git -C $cloneA checkout -b develop 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cloneA 'dev.txt'), "dev1`n")
    & git -C $cloneA add -A 2>&1 | Out-Null
    & git -C $cloneA commit -m "feat: develop seed" 2>&1 | Out-Null
    & git -C $cloneA push -u origin develop 2>&1 | Out-Null

    & git clone $bareOrigin $cloneB 2>&1 | Out-Null
    & git -C $cloneB config user.name "Peer"
    & git -C $cloneB config user.email "peer@example.com"

    Push-Location $cloneA
    try {
        # Branch from main using nb <new> <from> and verify explicit base config is saved
        nb fixes/issue-main main *>&1 | Out-Null
        Assert-Equal ((& git config --local --get branch.fixes/issue-main.base).Trim()) 'main' "nb <branch> <from> records base branch in git config"

        # Branch from develop using nb <new> (default)
        & git checkout develop 2>&1 | Out-Null
        nb fixes/issue-dev *>&1 | Out-Null
        Assert-Equal ((& git config --local --get branch.fixes/issue-dev.base).Trim()) 'develop' "nb <branch> records active branch as base"

        # Auto-priority without branch.<name>.base should choose develop over main
        & git config --local --unset branch.fixes/issue-dev.base 2>$null
        $autoBase = Resolve-GitBaseBranch -CurrentBranch 'fixes/issue-dev'
        Assert-Equal $autoBase.Branch 'develop' "Resolve-GitBaseBranch prioritizes develop over main"

        # Create remote + local divergence
        [System.IO.File]::WriteAllText((Join-Path $cloneA 'feature.txt'), "line1`n")
        & git add -A 2>&1 | Out-Null
        & git commit -m "fix: shared base commit" 2>&1 | Out-Null
        & git push -u origin fixes/issue-dev 2>&1 | Out-Null

        # Peer pushes incoming commit to both origin/fixes/issue-dev and origin/develop
        & git -C $cloneB fetch origin 2>&1 | Out-Null
        & git -C $cloneB checkout -b fixes/issue-dev origin/fixes/issue-dev 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cloneB 'peer.txt'), "peer`n")
        & git -C $cloneB add -A 2>&1 | Out-Null
        & git -C $cloneB commit -m "chore: peer commit on branch" 2>&1 | Out-Null
        & git -C $cloneB push origin fixes/issue-dev 2>&1 | Out-Null

        & git -C $cloneB checkout -b develop origin/develop 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cloneB 'upstream.txt'), "upstream`n")
        & git -C $cloneB add -A 2>&1 | Out-Null
        & git -C $cloneB commit -m "feat: landed on develop" 2>&1 | Out-Null
        & git -C $cloneB push origin develop 2>&1 | Out-Null

        # Local unpushed commit + staged + unstaged + untracked changes
        [System.IO.File]::WriteAllText((Join-Path $cloneA 'feature.txt'), "line1`nline2`n")
        & git add -A 2>&1 | Out-Null
        & git commit -m "fix: local unpushed commit" 2>&1 | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $cloneA 'staged.txt'), "staged content`n")
        & git add staged.txt 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cloneA 'feature.txt'), "line1`nline2`nunstaged edit`n")
        [System.IO.File]::WriteAllText((Join-Path $cloneA 'scratch.txt'), "untracked`n")

        $repoFirst = (repo *>&1 | Out-String)
        Assert-True ($repoFirst -match 'fetched origin --prune just now') "repo fetches origin --prune on first run"
        Assert-True ($repoFirst -match 'Not pushed yet.*:\s*1' -and $repoFirst -match 'fix: local unpushed commit') "repo shows unpushed local commits"
        Assert-True ($repoFirst -match 'Not pulled yet.*:\s*1' -and $repoFirst -match 'chore: peer commit on branch') "repo shows unpulled remote commits"
        Assert-True ($repoFirst -match 'Only on your branch \(not in origin/develop\):\s*2') "repo shows branch commits not in base"
        Assert-True ($repoFirst -match 'New on origin/develop since branch-off:\s*1' -and $repoFirst -match 'feat: landed on develop') "repo shows base commits since branch-off"
        Assert-True ($repoFirst -match 'Staged: 1 file' -and $repoFirst -match 'Unstaged: 1 file' -and $repoFirst -match 'Untracked: 1 file') "repo groups staged, unstaged, and untracked cleanly"

        $repoSecond = (repo *>&1 | Out-String)
        Assert-True ($repoSecond -match 'cooldown') "repo skips fetch within 60s cooldown"

        $repoNoFetch = (repo -n *>&1 | Out-String)
        Assert-True ($repoNoFetch -match 'fetch skipped') "repo -n skips fetch explicitly"

        $repoForced = (repo -f *>&1 | Out-String)
        Assert-True ($repoForced -match 'fetched origin --prune just now') "repo -f bypasses 60s cooldown"

        $catchupCheck = (repo catchup -c *>&1 | Out-String)
        Assert-True ($catchupCheck -match 'New commits on origin/develop since branch-off' -and $catchupCheck -match 'feat: landed on develop') "repo catchup -c previews incoming base commits"

        $diffUnstaged = (diff *>&1 | Out-String)
        Assert-True ($diffUnstaged -match 'Unstaged changes' -and $diffUnstaged -match '\+unstaged edit' -and $diffUnstaged -match '1 staged') "diff shows unstaged changes and reminds about staged/untracked"

        $diffStaged = (diff staged *>&1 | Out-String)
        Assert-True ($diffStaged -match 'Staged changes' -and $diffStaged -match '\+staged content' -and $diffStaged -match '1 unstaged') "diff staged shows staged changes cleanly"

        $diffBase = (diff base -Files *>&1 | Out-String)
        Assert-True ($diffBase -match 'Branch changes vs origin/develop' -and $diffBase -match 'feature\.txt') "diff base -Files lists branch diff files vs origin/develop"

        $diffLast = (diff last -Stat *>&1 | Out-String)
        Assert-True ($diffLast -match 'Last 1 commit\(s\)' -and $diffLast -match 'feature\.txt') "diff last -Stat summarizes latest commit"

        # Test clipboard fallbacks and piping with isolated mock Get-Clipboard (never mutates user's real clipboard)
        foreach ($fnName in @('Get-ClipboardShortQuery', 'cmp', 'findstr', 'jwt', 'find')) {
            $fnDef = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
            . ([scriptblock]::Create($fnDef.Extent.Text))
        }

        $script:MockClip = $sampleJwt
        function Get-Clipboard { param([switch]$Raw) return $script:MockClip }
        try {
            $jwtClipOut = (jwt 6>&1 | Out-String)
            Assert-True ($jwtClipOut -match '"role": "admin"' -and $jwtClipOut -match 'clipboard') "jwt decodes token from clipboard when omitted"

            $script:MockClip = 'alpha'
            $findstrClipOut = (@('alpha line', 'beta line') | findstr *>&1 | Out-String)
            Assert-True ($findstrClipOut -match 'alpha line' -and $findstrClipOut -notmatch 'beta line') "findstr uses short clipboard pattern when omitted on pipeline"

            $script:MockClip = "line1`nline2"
            $findstrMultiOut = (@('alpha line') | findstr *>&1 | Out-String)
            Assert-True ($findstrMultiOut -match 'skipped auto-query' -and $findstrMultiOut -match 'Usage:') "findstr safely ignores multi-line clipboard blobs"

            $cmpSingleFile = Join-Path $cloneA 'app.txt'
            $script:MockClip = "v1`n"
            $cmpClipSame = (cmp $cmpSingleFile *>&1 | Out-String)
            Assert-True ($cmpClipSame -match 'Identical \(.* == clipboard\)') "cmp <file> detects match against clipboard"

            $script:MockClip = "v1`r`n"
            $cmpClipCrlf = (cmp $cmpSingleFile *>&1 | Out-String)
            Assert-True ($cmpClipCrlf -match 'CRLF vs LF mismatch') "cmp <file> warns on CRLF vs LF mismatch against clipboard"

            $script:MockClip = "  v1  `n"
            $cmpClipWs = (cmp $cmpSingleFile -w *>&1 | Out-String)
            Assert-True ($cmpClipWs -match 'Identical \(.* == clipboard\)') "cmp <file> -w matches ignoring whitespace"

            $script:MockClip = "v2`n"
            $cmpClipDiff = (cmp $cmpSingleFile *>&1 | Out-String)
            Assert-True ($cmpClipDiff -match 'Difference \(.* vs clipboard\)' -and $cmpClipDiff -match '-v1' -and $cmpClipDiff -match '\+v2') "cmp <file> shows git diff --no-index vs clipboard"
        } finally {
            Remove-Item function:\Get-Clipboard -ErrorAction SilentlyContinue
        }

        $findAst = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'find' }, $false) | Select-Object -First 1
        Assert-True ($findAst.Extent.Text -match 'ValueFromPipeline') "find supports pipeline input"
    } finally {
        Pop-Location
    }
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    # Clean up junctions safely before removing sandbox
    foreach ($j in @((Join-Path $testHome '.gemini\skills'), (Join-Path $testHome '.agents\skills\ask'), (Join-Path $testHome '.agents\skills\ux'), (Join-Path $testHome '.agents\skills\readme'), (Join-Path $testHome '.agents\skills\repo-intro'), (Join-Path $testHome '.agents\skills\developer-profile'), (Join-Path $testHome '.agents\skills\ws-skill'), (Join-Path $testHome '.gemini\config\plugins\egm'))) {
        if (Test-Path -LiteralPath $j) {
            try { [System.IO.Directory]::Delete($j) } catch {}
        }
    }
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nResults: $script:Passed passed, $script:Failed failed." -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
