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
    'configs\powershell\Microsoft.PowerShell_profile.ps1',
    'workspaces\personal\powershell\profile.ps1',
    'workspaces\work\powershell\profile.ps1'
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

    # Test empty 0-byte .workspace.local handling
    [System.IO.File]::WriteAllText((Join-Path $testRepo '.workspace.local'), '', [System.Text.UTF8Encoding]::new($false))
    $curEmptyOut = (& $testPss workspace current -HomeOverride $testHome -DocumentsOverride $testDocs *>&1 | Out-String)
    Assert-True ($curEmptyOut -match 'No active workspace configured') "empty 0-byte .workspace.local handled without crashing"

    # Test POSIX flags (--no-apply / --what-if)
    & $testPss workspace use work --no-apply -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-Equal ((Get-Content (Join-Path $testRepo '.workspace.local') -Raw).Trim()) 'work' "workspace use --no-apply sets .workspace.local"

    # Set active workspace to personal without applying yet
    & $testPss workspace use personal -NoApply -HomeOverride $testHome -DocumentsOverride $testDocs | Out-Null
    Assert-Equal ((Get-Content (Join-Path $testRepo '.workspace.local') -Raw).Trim()) 'personal' "workspace use sets .workspace.local"

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
    $profileAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'configs\powershell\Microsoft.PowerShell_profile.ps1'), [ref]$null, [ref]$null)
    $jwtFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'jwt' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($jwtFn.Extent.Text))
    # Header: {"alg":"HS256","typ":"JWT"}, Payload: {"sub":"123","role":"admin"}
    $sampleJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMiLCJyb2xlIjoiYWRtaW4ifQ.sig"
    $jwtOut = (jwt $sampleJwt 6>&1 | Out-String)
    Assert-True ($jwtOut -match '"role": "admin"' -and $jwtOut -match '"alg": "HS256"') "jwt decodes header and payload offline"

    # Test ExtraArgs binding on findstr, p, find, wip and Get-PssActiveWorkspace empty file guard
    $getWsFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-PssActiveWorkspace' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($getWsFn.Extent.Text))
    [System.IO.File]::WriteAllText((Join-Path $testRepo '.workspace.local'), '', [System.Text.UTF8Encoding]::new($false))
    $global:__pss_root = $testRepo
    Assert-Equal (Get-PssActiveWorkspace) 'personal' "Get-PssActiveWorkspace falls back on empty 0-byte .workspace.local"

    $findstrFn = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'findstr' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($findstrFn.Extent.Text))
    $findstrOut = (@('alpha line', 'beta line') | findstr 'alpha' '.' -v *>&1 | Out-String)
    Assert-True ($findstrOut -match 'beta line' -and $findstrOut -notmatch 'alpha line') "findstr binds ExtraArgs -v on piped input"

    foreach ($fnName in @('wip', 'p', 'find', 'findstr')) {
        $fnAst = $profileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fnName }, $false) | Select-Object -First 1
        Assert-True ($fnAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'ExtraArgs') "function $fnName uses ExtraArgs instead of `$args"
    }

    $workAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'workspaces\work\powershell\profile.ps1'), [ref]$null, [ref]$null)
    $slnCleanFn = $workAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'slnclean' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($slnCleanFn.Extent.Text))
    $slnDir = Join-Path $sandbox 'dotnet-proj'
    [System.IO.Directory]::CreateDirectory((Join-Path $slnDir 'src\Api\bin\Debug')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $slnDir 'src\Api\obj')) | Out-Null
    slnclean -Path $slnDir -WhatIf | Out-Null
    Assert-True (Test-Path (Join-Path $slnDir 'src\Api\bin')) "slnclean -WhatIf preserves bin/"
    slnclean -Path $slnDir | Out-Null
    Assert-True (-not (Test-Path (Join-Path $slnDir 'src\Api\bin')) -and -not (Test-Path (Join-Path $slnDir 'src\Api\obj'))) "slnclean removes bin/ and obj/"
} finally {
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
