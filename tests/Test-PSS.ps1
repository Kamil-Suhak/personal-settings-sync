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

    $blockingHooksDir = Join-Path $testHome '.git-hooks'
    [System.IO.Directory]::CreateDirectory($blockingHooksDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $blockingHooksDir 'stale-hook'), "old`n", [System.Text.UTF8Encoding]::new($false))

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
    $prevHome = $env:HOME
    $prevUserProfile = $env:USERPROFILE
    try {
        $env:HOME = $testHome
        $env:USERPROFILE = $testHome
        $gitHooksPath = (& git config --file (Join-Path $testHome '.gitconfig') --includes --path core.hooksPath 2>$null)
    } finally {
        $env:HOME = $prevHome
        $env:USERPROFILE = $prevUserProfile
    }
    Assert-Equal ($gitHooksPath -replace '\\', '/') (($testHome -replace '\\', '/') + '/.git-hooks') "git --includes resolves shared core.hooksPath"
    $gitHooksLink = Get-Item (Join-Path $testHome '.git-hooks') -Force
    Assert-True ([bool]($gitHooksLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) ".git-hooks is a junction (replaced blocking directory)"
    Assert-True ((Test-Path (Join-Path $gitHooksLink.FullName 'commit-msg')) -and (Test-Path (Join-Path $gitHooksLink.FullName 'validate_commit_msg.py'))) ".git-hooks junction resolves commit-msg hook files"
    Assert-True ((Get-ChildItem (Join-Path $testRepo '.backups') -Recurse -File -Filter 'stale-hook').Count -eq 1) "apply backs up existing .git-hooks before linking"

    # Verify AI rules & skills.json template
    $agentsText = Get-Content (Join-Path $testHome '.gemini\AGENTS.md') -Raw
    Assert-True ($agentsText -match 'Global Agent Guidelines' -and $agentsText -match 'Personal Workspace Context') "AGENTS.md combines shared + personal"
    $skillsJson = Get-Content (Join-Path $testHome '.gemini\config\skills.json') -Raw
    $expectedHomeFwd = ($testHome -replace '\\', '/')
    $expectedRepoFwd = ($testRepo -replace '\\', '/')
    Assert-True ($skillsJson -match [regex]::Escape("$expectedHomeFwd/.agents/skills")) "skills.json expands ~ to forward-slash HOME"
    Assert-True ($skillsJson -match [regex]::Escape("$expectedRepoFwd/configs/skills")) "skills.json expands {REPO} to repo configs/skills"
    Assert-True ($skillsJson -match [regex]::Escape("$expectedRepoFwd/workspaces/personal/skills")) "skills.json includes workspace skills directory when present"

    # Verify junctions (including replacing blocking dir & broken junction) & workspace skill + third-party preservation
    $askSkillLink = Get-Item (Join-Path $testHome '.agents\skills\ask') -Force
    Assert-True ([bool]($askSkillLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) "skill 'ask' is a junction (replaced blocking directory)"
    Assert-True (Test-Path (Join-Path $askSkillLink.FullName 'SKILL.md')) "skill 'ask' junction resolves after replacing directory"
    Assert-True (Test-Path (Join-Path $testHome '.agents\skills\visualize\resources\viewer-template.html')) "skill 'visualize' and viewer template linked"
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
            workset delete 'alternate-name' | Out-Null
            Assert-True (-not (Test-Path (Get-WorksetDirectory 'alternate-name'))) 'workset delete removes list immediately without prompt'
            & git -C $repoOne symbolic-ref HEAD refs/heads/different
            $global:__git_cache_repo = $null
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset on another branch'
            & git -C $repoOne symbolic-ref HEAD refs/heads/123/dashboard
            $global:__git_cache_repo = $null
            prompt 6>$null | Out-Null
            Assert-Equal $global:cw '123-dashboard' 'prompt restores current workset when returning to its branch'
            $emptyWsDir = Join-Path $testState.Root 'worksets\work\active\orphan-dir'
            [void][System.IO.Directory]::CreateDirectory($emptyWsDir)
            $global:__cw_cache_key = $null
            $promptWarn = (prompt 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-True ($promptWarn.Count -eq 0 -and $global:cw -eq '123-dashboard') 'prompt ignores workset folder without metadata.json and caches $cw'
            Remove-Item -LiteralPath $emptyWsDir -Force
            [System.IO.File]::WriteAllText($testState.Workspace, 'personal')
            prompt 6>$null | Out-Null
            Assert-True ($null -eq $global:cw) 'prompt clears current workset outside the work workspace'
            [System.IO.File]::WriteAllText($testState.Workspace, 'work')
            workset add $fileOne
            $extraFileOne = Join-Path $repoOne 'extra-one.cs'
            $extraFileTwo = Join-Path $repoOne 'extra-two.cs'
            [System.IO.File]::WriteAllText($extraFileOne, 'extra1')
            [System.IO.File]::WriteAllText($extraFileTwo, 'extra2')
            workset add -Files $extraFileOne $extraFileTwo
            $shownFiles = (workset show 6>&1) -join "`n"
            Assert-True ($shownFiles -match 'extra-one\.cs' -and $shownFiles -match 'extra-two\.cs') 'workset add -Files adds multiple files without mistaking first file for name'
            workset open
            Assert-True ($global:testCodeArguments -contains $fileOne) 'single-repository workset without a solution selects VS Code'
            $noSolution = $false
            try { workset open -Vs } catch { $noSolution = $true }
            Assert-True $noSolution 'explicit VS reports a missing solution'
            [System.IO.File]::WriteAllText((Join-Path $repoOne 'app.sln'), '')
            workset open
            Assert-True ($global:testVsPath -eq $repoOne -and $global:testVsFiles -contains $fileOne) 'single-repository workset selects VS'
            workset add '123-dashboard' -Files $fileTwo
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
            workset delete | Out-Null
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

    # Verify workspace new & delete (and -WhatIf does not mutate; -y skips confirmation while still printing preview)
    & $testPss workspace new school -WhatIf -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-True (-not (Test-Path (Join-Path $testRepo 'workspaces\school'))) "workspace new -WhatIf does not create folder"
    & $testPss workspace new school -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-True (Test-Path (Join-Path $testRepo 'workspaces\school\powershell\profile.ps1')) "workspace new scaffolds directory"
    $wsDelOut = (& $testPss workspace delete school -y -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ((-not (Test-Path (Join-Path $testRepo 'workspaces\school'))) -and $wsDelOut -match 'Command preview: Remove-Item') "workspace delete -y prints command preview and removes inactive workspace"

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

    # Verify function layout across shared & workspace profiles
    $personalAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'workspaces\personal\powershell\profile.ps1'), [ref]$null, [ref]$null)
    $workAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'workspaces\work\powershell\profile.ps1'), [ref]$null, [ref]$null)
    $sharedNames = @($profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name)
    $personalNames = @($personalAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name)
    $workNames = @($workAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name)
    Assert-True ($sharedNames -contains 'brave' -and $personalNames -notcontains 'brave') "brave moved to shared profile"
    Assert-True ($personalNames -notcontains 'passbolt' -and $personalNames -notcontains 'passbolt-stop' -and $personalNames -notcontains 'Invoke-PassboltCompose') "passbolt removed from personal profile"
    Assert-True ($workNames -notcontains 'slnclean') "slnclean removed from work profile"
    Assert-True ($sharedNames -contains 'commit' -and $sharedNames -notcontains 'amend' -and $sharedNames -notcontains 'undo') "amend and undo merged into commit"
    Assert-True ($sharedNames -contains 'st' -and $sharedNames -contains 'diff' -and $sharedNames -notcontains 'repo' -and $sharedNames -notcontains 'catchup' -and $sharedNames -notcontains 'gsync') "repo/catchup/sync replaced with st and diff"
    Assert-True ($sharedNames -contains 'out' -and $sharedNames -contains 'rerun') "out and rerun defined in shared ai group"

    $profileRaw = $sharedProfileText
    Assert-True ($profileRaw -match 'Remove-Alias\s+-Name\s+diff\s+-Force' -and $profileRaw -match 'Compare-Object' -and $profileRaw -match 'Copy-Item') "profile explicitly documents built-in diff and copy alias overrides"

    # Test commit / commit amend / commit undo / push confirmation rules in isolated git repo
    foreach ($fnName in @('Clear-GitBranchCache', 'Invoke-GitConfirmation', 'commit', 'push')) {
        $fnDef = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
        . ([scriptblock]::Create($fnDef.Extent.Text))
    }
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
        $script:PromptCount = 0
        $script:PromptReply = 'n'
        function Read-Host { param($Prompt) $script:PromptCount++; return $script:PromptReply }
        try {
            [System.IO.File]::WriteAllText((Join-Path $commitRepo 'b.txt'), "two`n")
            commit "feat: second commit" *>&1 | Out-Null
            Assert-Equal $script:PromptCount 0 "plain commit creates commit without confirmation"
            Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'feat: second commit' "commit <message> creates commit"

            [System.IO.File]::WriteAllText((Join-Path $commitRepo 'b.txt'), "two amended`n")
            $script:PromptReply = 'n'
            commit amend *>&1 | Out-Null
            Assert-Equal $script:PromptCount 1 "commit amend prompts [y/N] before running"
            Assert-True ((& git diff --cached --name-only).Count -eq 0 -and ((Get-Content (Join-Path $commitRepo 'b.txt') -Raw) -eq "two amended`n")) "commit amend aborted on 'n' does not amend HEAD"

            $script:PromptReply = 'y'
            $amendWithYesCount = $script:PromptCount
            $amendYesOut = (commit amend -y 6>&1 | Out-String)
            Assert-True ($script:PromptCount -eq $amendWithYesCount -and $amendYesOut -match 'Command preview:\s*git add -A; git commit --amend --no-edit') "commit amend -y prints command preview and bypasses confirmation"
            Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'feat: second commit' "commit amend preserves message without extra args"
            Assert-True ((Get-Content (Join-Path $commitRepo 'b.txt') -Raw) -match 'two amended') "commit amend updates commit contents"

            commit amend "fix: updated msg" -y *>&1 | Out-Null
            Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'fix: updated msg' "commit amend <message> -y updates commit message"

            $script:PromptReply = 'n'
            commit undo *>&1 | Out-Null
            Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'fix: updated msg' "commit undo aborted on 'n' leaves HEAD intact"

            $undoWithYesCount = $script:PromptCount
            $undoYesOut = (commit undo -y 6>&1 | Out-String)
            Assert-True ($script:PromptCount -eq $undoWithYesCount -and $undoYesOut -match 'Command preview:\s*git reset --soft HEAD~1') "commit undo -y prints command preview and bypasses confirmation"
            Assert-Equal ((& git log -1 --pretty=%s).Trim()) 'chore: init' "commit undo resets HEAD~1 when confirmed"
            $staged = (& git diff --cached --name-only) -join ','
            Assert-True ($staged -match 'b\.txt') "commit undo keeps changes staged"

            $prevPrompts = $script:PromptCount
            $script:PromptReply = 'n'
            push *>&1 | Out-Null
            Assert-True ($script:PromptCount -gt $prevPrompts) "push prompts [y/N] before pushing"

            $pushBareRemote = Join-Path $sandbox 'push-remote.git'
            & git init --bare $pushBareRemote 2>&1 | Out-Null
            & git remote add origin $pushBareRemote 2>&1 | Out-Null
            $pushYesPromptStart = $script:PromptCount
            $pushYesOut = (push -y *>&1 | Out-String)
            Assert-True ($script:PromptCount -eq $pushYesPromptStart -and $pushYesOut -match 'Command preview:\s*git push') "push -y prints command preview and pushes without confirmation"
        } finally {
            Remove-Item function:\Read-Host -ErrorAction SilentlyContinue
        }

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
    $vsTooShallow = (vs $nestedDir -MaxDepth 1 -WhatIf *>&1 | Out-String)
    Assert-True ($vsTooShallow -match 'No \.sln or \.slnx file found') "vs respects MaxDepth limit"

    # Test st, diff pr, and 24h fetch cache / explicit multi-branch comparison in isolated bare-remote + two-clone git setup
    foreach ($fnName in @('Invoke-GitFetchWithCooldown', 'Resolve-GitTargetRef', 'Show-GitCommitComparison', 'st', 'diff', 'b', 'nb')) {
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
        & git checkout develop 2>&1 | Out-Null
        nb fixes/issue-dev *>&1 | Out-Null

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

        # Force fetch to get peer updates, then verify default st does not guess base branch
        $stForced = (st -f *>&1 | Out-String)
        Assert-True ($stForced -match 'fetched origin just now') "st -f fetches origin updates"
        Assert-True ($stForced -match 'Not compared against any base branch') "st without branch args explicitly states no base branch was compared"
        Assert-True ($stForced -match 'Not pushed yet.*:\s*1' -and $stForced -match 'fix: local unpushed commit') "st shows unpushed local commits"
        Assert-True ($stForced -match 'Not pulled yet.*:\s*1' -and $stForced -match 'chore: peer commit on branch') "st shows unpulled remote commits"
        Assert-True ($stForced -match 'Staged: 1 file' -and $stForced -match 'Unstaged: 1 file' -and $stForced -match 'Untracked: 1 file') "st groups staged, unstaged, and untracked cleanly"

        $stCached = (st *>&1 | Out-String)
        Assert-True ($stCached -match 'refs fetched .* ago') "st skips network fetch while refs are fresh (<24h)"

        $stNoFetch = (st -n *>&1 | Out-String)
        Assert-True ($stNoFetch -match 'fetch skipped') "st -n skips fetch explicitly"

        $stMulti = (st develop main -Files *>&1 | Out-String)
        Assert-True ($stMulti -match 'vs origin/develop' -and $stMulti -match 'vs origin/main') "st compares against every explicitly specified branch"
        Assert-True ($stMulti -match 'Only on your branch \(not in origin/develop\):\s*2' -and $stMulti -match 'New on origin/develop since branch-off:\s*1') "st develop reports commits ahead and behind"
        Assert-True ($stMulti -match 'Changed files since merge-base \(origin/develop\.\.\.HEAD\)' -and $stMulti -match 'feature\.txt') "st develop -Files lists modified files since merge-base"

        $stFull = (st develop -Full *>&1 | Out-String)
        Assert-True ($stFull -match 'GitHub PR preview -> origin/develop' -and $stFull -match 'fix: local unpushed commit') "st -Full delegates to diff pr under the hood"

        $diffUnstaged = (diff *>&1 | Out-String)
        Assert-True ($diffUnstaged -match 'Unstaged changes' -and $diffUnstaged -match '\+unstaged edit' -and $diffUnstaged -match '1 staged') "diff shows unstaged changes and reminds about staged/untracked"

        $diffStaged = (diff staged *>&1 | Out-String)
        Assert-True ($diffStaged -match 'Staged changes' -and $diffStaged -match '\+staged content' -and $diffStaged -match '1 unstaged') "diff staged shows staged changes cleanly"

        $diffPrNoBranch = (diff pr *>&1 | Out-String)
        Assert-True ($diffPrNoBranch -match 'Target branch required') "diff pr requires an explicit target branch"

        $diffPr = (diff pr develop -Files *>&1 | Out-String)
        Assert-True ($diffPr -match 'GitHub PR preview -> origin/develop' -and $diffPr -match 'Commits included \(2\):' -and $diffPr -match 'feature\.txt') "diff pr <branch> -Files shows included commits and changed files since merge-base"

        $diffLast = (diff last -Stat *>&1 | Out-String)
        Assert-True ($diffLast -match 'Last 1 commit\(s\)' -and $diffLast -match 'feature\.txt') "diff last -Stat summarizes latest commit"

        # Test AI/terminal buffer helpers, out/rerun slicing (~3..2 and ~3..~2), and Invoke-AskCliProcess streaming + stderr separation
        foreach ($fnName in @('ConvertTo-TerminalCommandBlocks', 'Resolve-TerminalBlockIndices', 'Get-TerminalCommandBlocks', 'Resolve-AskRequest', 'Invoke-AskCliProcess', 'out', 'rerun')) {
            $fnDef = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
            . ([scriptblock]::Create($fnDef.Extent.Text))
        }
        $fakeBuffer = @(
            "~/repo $([char]0xE0B0) main $([char]0xE0B0) $([char]0x276F) cmd-one",
            "out-one",
            "~/repo $([char]0xE0B0) main $([char]0xE0B0) $([char]0x276F) cmd-two",
            "out-two-a",
            "out-two-b",
            "~/repo $([char]0xE0B0) main $([char]0xE0B0) $([char]0x276F) cmd-three",
            "out-three",
            "~/repo $([char]0xE0B0) main $([char]0xE0B0) $([char]0x276F) out ~3..2"
        )
        $parsedBlocks = @(ConvertTo-TerminalCommandBlocks -Lines $fakeBuffer)
        Assert-Equal $parsedBlocks.Count 3 "ConvertTo-TerminalCommandBlocks splits completed prompts and excludes active prompt"
        Assert-Equal $parsedBlocks[1].Command 'cmd-two' "ConvertTo-TerminalCommandBlocks captures command text after chevron"
        Assert-Equal ($parsedBlocks[1].Output -join ',') 'out-two-a,out-two-b' "ConvertTo-TerminalCommandBlocks preserves multi-line command output"

        $spacePromptBuffer = @(
            " Projects/repo  main  $([char]0x276F) first-cmd",
            "first-out",
            " Projects/repo  main  $([char]0x276F) lastout | copy"
        )
        $spaceBlocks = @(ConvertTo-TerminalCommandBlocks -Lines $spacePromptBuffer)
        Assert-Equal $spaceBlocks.Count 1 "ConvertTo-TerminalCommandBlocks matches space-separated prompt without E0B0 glyph"
        Assert-Equal ($spaceBlocks[0].Output -join ',') 'first-out' "ConvertTo-TerminalCommandBlocks preserves output for space-separated prompts"

        $scrolledOffBuffer = @(
            "scrolled-line-1",
            "",
            "scrolled-line-2",
            " Projects/repo  main  $([char]0x276F) lastout | copy"
        )
        $fallbackBlocks = @(ConvertTo-TerminalCommandBlocks -Lines $scrolledOffBuffer -FallbackCommand 'ask previous')
        Assert-Equal $fallbackBlocks.Count 1 "ConvertTo-TerminalCommandBlocks recovers leading output via FallbackCommand when prior prompt scrolled off ConPTY buffer"
        Assert-Equal $fallbackBlocks[0].Command 'ask previous' "ConvertTo-TerminalCommandBlocks assigns FallbackCommand to recovered block"
        Assert-Equal ($fallbackBlocks[0].Output -join '|') 'scrolled-line-1||scrolled-line-2' "ConvertTo-TerminalCommandBlocks trims leading/trailing blanks on FallbackCommand recovery"

        Assert-Equal ((Resolve-TerminalBlockIndices -Spec '~3..2' -Count 3) -join ',') '0,1' "Resolve-TerminalBlockIndices supports optional tilde in ~3..2"
        Assert-Equal ((Resolve-TerminalBlockIndices -Spec '~3..~2' -Count 3) -join ',') '0,1' "Resolve-TerminalBlockIndices supports ~3..~2"
        Assert-Equal ((Resolve-TerminalBlockIndices -Spec '~2' -Count 3) -join ',') '1' "Resolve-TerminalBlockIndices resolves ~2 to second-last command"
        Assert-Equal ((Resolve-TerminalBlockIndices -Spec '2' -Count 3) -join ',') '1,2' "Resolve-TerminalBlockIndices resolves 2 to last 2 commands"

        $cleanPrompt = Resolve-AskRequest -QuestionArgs @('simple question') -Piped '' -PromptPreamble 'preamble'
        Assert-True ($cleanPrompt -notmatch '\[Context:' -and $cleanPrompt -match 'simple question') "ask is clean by default without -Ctx"

        function Get-TerminalCommandBlocks { return $parsedBlocks }
        try {
            $ctxPrompt = Resolve-AskRequest -QuestionArgs @('~3..2', 'explain failure') -Piped '' -IncludeCtx -PromptPreamble 'preamble'
            Assert-True ($ctxPrompt -match 'out-one' -and $ctxPrompt -match 'out-two-a' -and $ctxPrompt -notmatch 'out-three' -and $ctxPrompt -match 'explain failure') "ask -Ctx ~3..2 injects sliced command blocks into prompt"

            $outText = (out '~2') -join "`n"
            Assert-Equal $outText "out-two-a`nout-two-b" "out ~2 returns clean second-last command output"

            $global:testRerunRan = $false
            function Get-History { @([pscustomobject]@{ CommandLine = '$global:testRerunRan = $true' }) }
            try {
                $rerunOut = (rerun -y 6>&1 | Out-String)
                Assert-True ($global:testRerunRan -and $rerunOut -match 'Commands to execute:' -and $rerunOut -match 'testRerunRan') "rerun -y prints command preview and executes without prompt"
            } finally {
                Remove-Item function:\Get-History -ErrorAction SilentlyContinue
                Remove-Variable -Name testRerunRan -Scope Global -ErrorAction SilentlyContinue
            }

            $global:testRerunLog = [System.Collections.Generic.List[string]]::new()
            function Get-History {
                @(
                    [pscustomobject]@{ CommandLine = '$null = $global:testRerunLog.Add("first")' },
                    [pscustomobject]@{ CommandLine = 'rerun' },
                    [pscustomobject]@{ CommandLine = '$null = $global:testRerunLog.Add("mention rerun arg")' },
                    [pscustomobject]@{ CommandLine = 'rerun -y ~2' },
                    [pscustomobject]@{ CommandLine = 'echo ok; rerun ~1' }
                )
            }
            try {
                $skipRerunOut = (rerun -y 6>&1 | Out-String)
                Assert-True ($global:testRerunLog.Count -eq 1 -and $global:testRerunLog[0] -eq 'mention rerun arg' -and $skipRerunOut -notmatch '> rerun') "rerun skips previous rerun invocations while keeping commands mentioning rerun as an argument"

                $global:testRerunLog.Clear()
                $pairOut = (rerun 2 -y 6>&1 | Out-String)
                Assert-Equal ($global:testRerunLog -join '|') 'first|mention rerun arg' "rerun 2 skips previous rerun entries and runs last 2 non-rerun commands in order"
            } finally {
                Remove-Item function:\Get-History -ErrorAction SilentlyContinue
                Remove-Variable -Name testRerunLog -Scope Global -ErrorAction SilentlyContinue
            }

            function Get-History { @([pscustomobject]@{ CommandLine = 'rerun' }, [pscustomobject]@{ CommandLine = 'rerun -y' }) }
            function Get-TerminalCommandBlocks { @([pscustomobject]@{ Command = 'rerun -y'; Output = @() }) }
            try {
                $onlyRerunOut = (rerun -y 6>&1 | Out-String)
                Assert-True ($onlyRerunOut -match 'No prior commands found to re-run') "rerun reports no prior commands when history and buffer contain only rerun invocations"
            } finally {
                Remove-Item function:\Get-History -ErrorAction SilentlyContinue
                function Get-TerminalCommandBlocks { return $parsedBlocks }
            }

            function Get-History { @([pscustomobject]@{ CommandLine = '$r = "rerun"; & $r -y' }) }
            try {
                $nestedOut = (rerun -y 6>&1 | Out-String)
                Assert-True ($nestedOut -match 'recursive invocation blocked') "rerun blocks nested recursive invocation at runtime"
            } finally {
                Remove-Item function:\Get-History -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item function:\Get-TerminalCommandBlocks -ErrorAction SilentlyContinue
        }

        # Verify Invoke-AskCliProcess streams stream-json deltas cleanly and excludes exit-0 usage stderr from stdout pipeline
        $pwshExe = (Get-Process -Id $PID).Path
        $streamJsonScript = Join-Path $sandbox 'mock-stream.ps1'
        [System.IO.File]::WriteAllText($streamJsonScript, @'
Write-Output '{"event":"init","conversation_id":"conv-test-123"}'
Write-Output '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hel"}}'
Write-Output '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"lo\n\nWor"}}'
Write-Output '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"ld"}}'
Write-Output '{"event":"result","result":{"conversation_id":"conv-test-123","status":"SUCCESS","response":"Hello\n\nWorld"}}'
[Console]::Error.WriteLine("Total usage: 10 tokens")
'@, [System.Text.UTF8Encoding]::new($false))
        $pipedCombined = @(Invoke-AskCliProcess -ExecutablePath $pwshExe -Arguments @('-NoProfile', '-File', $streamJsonScript) -Label 'test-agy' -StreamJson 6>&1)
        $pipedHostMsgs = @($pipedCombined | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message })
        $pipedAnswer = @($pipedCombined | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $headerHitsPiped = @($pipedHostMsgs | Where-Object { $_ -match 'test-agy' }).Count
        Assert-Equal $headerHitsPiped 1 "Invoke-AskCliProcess prints ask header exactly once across multi-paragraph piped stream"
        Assert-Equal ($pipedAnswer -join '|') 'Hello||World' "Invoke-AskCliProcess streams NDJSON text_delta chunks cleanly and excludes exit-0 stderr from stdout pipeline"
        Assert-Equal $script:__ask_last_conv_id 'conv-test-123' "Invoke-AskCliProcess captures conversation_id from stream-json"

        $interactiveCombined = @(Invoke-AskCliProcess -ExecutablePath $pwshExe -Arguments @('-NoProfile', '-File', $streamJsonScript) -Label 'test-agy' -StreamJson -InteractiveStream 6>&1)
        $interactiveStdout = @($interactiveCombined | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $interactiveHostMsgs = @($interactiveCombined | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message })
        $headerHitsInteractive = @($interactiveHostMsgs | Where-Object { $_ -match 'test-agy' }).Count
        Assert-Equal $headerHitsInteractive 1 "Invoke-AskCliProcess InteractiveStream prints ask header exactly once"
        Assert-Equal $interactiveStdout.Count 0 "Invoke-AskCliProcess InteractiveStream writes directly to host without duplicating stdout objects"
        Assert-Equal (($interactiveHostMsgs | Where-Object { $_ -in @('Hel', "lo`n`nWor", 'ld') }) -join '|') "Hel|lo`n`nWor|ld" "Invoke-AskCliProcess InteractiveStream flushes each text_delta immediately without line buffering"

        $streamErrScript = Join-Path $sandbox 'mock-stream-error.ps1'
        [System.IO.File]::WriteAllText($streamErrScript, @'
Write-Output '{"event":"init","conversation_id":"conv-err-1"}'
Write-Output '{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"partial text"}}'
Write-Output '{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"error_message"}}'
Write-Output '{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"retry text"}}'
Write-Output '{"event":"result","result":{"conversation_id":"conv-err-1","status":"ERROR","error":"blocked by content safety filters\nRetries remaining: 3"}}'
'@, [System.Text.UTF8Encoding]::new($false))
        $errHostOut = (Invoke-AskCliProcess -ExecutablePath $pwshExe -Arguments @('-NoProfile', '-File', $streamErrScript) -Label 'test-agy' -StreamJson -InteractiveStream 6>&1 | Out-String)
        Assert-True ($errHostOut -match 'agy step interrupted' -and $errHostOut -match 'ERROR — blocked by content safety filters' -and $errHostOut -notmatch 'Retries remaining') "Invoke-AskCliProcess surfaces retry notices and detailed result.error messages cleanly"

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
    foreach ($j in @((Join-Path $testHome '.gemini\skills'), (Join-Path $testHome '.agents\skills\ask'), (Join-Path $testHome '.agents\skills\ux'), (Join-Path $testHome '.agents\skills\readme'), (Join-Path $testHome '.agents\skills\repo-intro'), (Join-Path $testHome '.agents\skills\developer-profile'), (Join-Path $testHome '.agents\skills\visualize'), (Join-Path $testHome '.agents\skills\ws-skill'), (Join-Path $testHome '.gemini\config\plugins\egm'))) {
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
