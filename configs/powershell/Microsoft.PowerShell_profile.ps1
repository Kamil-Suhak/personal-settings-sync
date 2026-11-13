#region 1. Core Environment & Encodings
# Bail out immediately if session is non-interactive or streams are redirected (e.g. AGY, automated agent runners, CI/CD)
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }

# Force UTF-8 console encoding for Powerline glyphs and emojis
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Prevent Python virtualenv from injecting an unstyled line above our prompt
$env:VIRTUAL_ENV_DISABLE_PROMPT = 1

# Cache elevated admin state once at startup to avoid expensive reflection on every prompt render
$global:__is_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Last command duration is always stored in $cmdtime; set $__show_prompt_timer = $true to show it on the prompt bar
$global:__show_prompt_timer = $false
$global:cmdtime = $null

# Cache ANSI palette once at startup (guards against PowerShell < 7.2 where $PSStyle is $null)
$global:__ansi = if ($PSStyle) {
    @{
        Cyan   = $PSStyle.Foreground.Cyan
        Yellow = $PSStyle.Foreground.Yellow
        Green  = $PSStyle.Foreground.Green
        Gray   = $PSStyle.Foreground.BrightBlack
        Red    = $PSStyle.Foreground.Red
        Reset  = $PSStyle.Reset
    }
}
else {
    @{ Cyan = ""; Yellow = ""; Green = ""; Gray = ""; Red = ""; Reset = "" }
}

# Resolve repository root dynamically from this shared profile's location
$global:__pss_root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $global:__pss_root 'scripts\local-state.ps1')
$global:__pss_state = Get-PssLocalStatePaths -Checkout $global:__pss_root
$profileDir = if ($PROFILE) { Split-Path -Parent $PROFILE } else { $null }
Invoke-PssLocalStateMigration -Paths $global:__pss_state -Checkout $global:__pss_root -HomePath $HOME -ProfileDirectory $profileDir

function Get-PssActiveWorkspace {
    $wsFile = $global:__pss_state.Workspace
    if (Test-Path -LiteralPath $wsFile) {
        $rawWs = Get-Content -LiteralPath $wsFile -Raw -ErrorAction SilentlyContinue
        if ($rawWs) {
            $ws = $rawWs.Trim()
            if ($ws) { return $ws }
        }
    }
    return "personal"
}
#endregion

. (Join-Path $global:__pss_root 'scripts\profile-groups.ps1')
$activeWorkspace = Get-PssActiveWorkspace
$profileGroups = @(Get-PssProfileGroups -Root $global:__pss_root -Workspace $activeWorkspace)
foreach ($group in $profileGroups | Where-Object { $_.Scope -eq 'shared' -and $_.Name -ne 'shared' }) {
    . $group.Path
}

#region 4. Development & System Helpers

<#
.SYNOPSIS
Locates commands. Prints path by default; with -h shows description/manual. Supports 'profile' to inspect profile functions.
#>
function which {
    [CmdletBinding(DefaultParameterSetName = "Name")]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Name")]
        [string]$Name,
        [Parameter(Mandatory = $true, ParameterSetName = "Profile")]
        [Alias("p")][switch]$Profile,
        [Alias("h")][switch]$Help
    )

    $cyan = $global:__ansi.Cyan
    $yellow = $global:__ansi.Yellow
    $green = $global:__ansi.Green
    $gray = $global:__ansi.Gray
    $reset = $global:__ansi.Reset

    # Special Profile Inspection Mode: which profile [-h] | which -p [-h]
    $isProfile = $Profile -or ($Name -in @('profile', '$profile'))
    if ($isProfile) {
        $targetProfile = Join-Path $global:__pss_root "configs\powershell\Microsoft.PowerShell_profile.ps1"
        if (-not (Test-Path -LiteralPath $targetProfile)) {
            $targetProfile = if ($PROFILE) { $PROFILE.ToString() } else { "PowerShell Profile" }
        }

        if (-not $Help) {
            return $targetProfile
        }

        $activeWs = Get-PssActiveWorkspace
        $showProfileFuncs = {
            param([string]$FilePath, [string]$Heading)
            if (-not (Test-Path -LiteralPath $FilePath)) { return }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$null)
            $funcAsts = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
            Where-Object { $_.Name -notmatch '^(prompt|Clear-GitBranchCache|(Get|Invoke|Resolve|Show|ConvertTo)-)' }

            if ($funcAsts.Count -eq 0) { return }
            Write-Host "  ${yellow}[$Heading]${reset}"
            $maxLen = ($funcAsts | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
            $pad = [math]::Max($maxLen + 2, 12)
            foreach ($f in $funcAsts) {
                $h = $f.GetHelpContent()
                $syn = if ($h -and $h.Synopsis) {
                    $h.Synopsis.Trim()
                }
                else {
                    $live = Get-Help $f.Name -ErrorAction SilentlyContinue
                    if ($live.Synopsis -and $live.Synopsis.Trim() -ne $f.Name) { $live.Synopsis.Trim() } else { "" }
                }
                Write-Host "    ${green}$($f.Name.PadRight($pad))${reset} $syn"
            }
            Write-Host ""
        }

        Write-Host "`n${cyan}Profile Functions ($activeWs)${reset}  ${gray}$targetProfile${reset}"
        Write-Host "${gray}$('─' * 60)${reset}`n"
        foreach ($group in Get-PssProfileGroups -Root $global:__pss_root -Workspace $activeWs) {
            & $showProfileFuncs $group.Path $group.Name
        }
        return
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "✖ which: Command '$Name' not found." -ForegroundColor Red
        return
    }

    if (-not $Help) {
        switch ($cmd.CommandType) {
            'Application' { return $cmd.Source }
            { $_ -in 'Function', 'Filter' } {
                if ($cmd.ScriptBlock -and $cmd.ScriptBlock.File) { return $cmd.ScriptBlock.File }
                if ($PROFILE) { return $PROFILE.ToString() }
                return 'PowerShell Profile'
            }
            'Alias' { return $cmd.Definition }
            Default {
                if ($cmd.Source) { return $cmd.Source }
                return $cmd.Name
            }
        }
    }

    Write-Host "`n${cyan}[$($cmd.CommandType.ToString().ToUpper())] $($cmd.Name)${reset}"
    Write-Host "${gray}$('─' * 44)${reset}"

    switch ($cmd.CommandType) {
        { $_ -in 'Function', 'Filter' } {
            $funcPath = if ($cmd.ScriptBlock -and $cmd.ScriptBlock.File) {
                $cmd.ScriptBlock.File
            }
            elseif ($PROFILE) {
                $PROFILE.ToString()
            }
            else {
                'PowerShell Profile'
            }
            Write-Host "  ${yellow}Path:${reset}         $funcPath"
            $helpObj = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($helpObj.Synopsis -and $helpObj.Synopsis.Trim() -ne $cmd.Name) {
                Write-Host "`n  ${yellow}Description:${reset}"
                ($helpObj.Synopsis.Trim() -split "`r?`n") | ForEach-Object { Write-Host "    $_" }
            }
        }
        'Alias' {
            Write-Host "  ${yellow}Resolves to:${reset}  ${green}$($cmd.Definition)${reset}"
            which $cmd.Definition -Help:$Help
        }
        'Application' {
            Write-Host "  ${yellow}Path:${reset}         $($cmd.Source)"
            if (Test-Path -LiteralPath $cmd.Source) {
                $ver = (Get-Item -LiteralPath $cmd.Source).VersionInfo
                if ($ver.FileVersion) { Write-Host "  ${yellow}Version:${reset}      ${gray}$($ver.FileVersion)${reset}" }
            }
            Write-Host "`n  ${yellow}Usage / Help:${reset}"
            try {
                $helpOutput = ($null | & $cmd.Source --help 2>&1)
                if ($LASTEXITCODE -ne 0 -or -not $helpOutput) {
                    $helpOutput = ($null | & $cmd.Source /? 2>&1)
                }
                if ($helpOutput) {
                    $lines = @($helpOutput)
                    $lines | ForEach-Object { Write-Host "    $_" }
                }
                else {
                    Write-Host "    ${gray}(No built-in --help or /? documentation returned)${reset}"
                }
            }
            catch {
                Write-Host "    ${gray}Could not execute help: $_${reset}"
            }
        }
        'Cmdlet' {
            Write-Host "  ${yellow}Module:${reset}       ${green}$($cmd.ModuleName)${reset}"
            $helpObj = Get-Help $cmd.Name -ErrorAction SilentlyContinue
            if ($helpObj.Synopsis) {
                Write-Host "`n  ${yellow}Synopsis:${reset}"
                ($helpObj.Synopsis.Trim() -split "`r?`n") | ForEach-Object { Write-Host "    $_" }
            }
            if ($helpObj.Syntax) {
                Write-Host "`n  ${yellow}Syntax:${reset}"
                ($helpObj.Syntax | Out-String).Trim() -split "`r?`n" | ForEach-Object { Write-Host "    ${gray}$_${reset}" }
            }
        }
    }
    Write-Host ""
}

<#
.SYNOPSIS
Activates a Python virtual environment (default: .venv). Creates it with py or python if it does not exist yet.
#>
function venv {
    param([string]$Name = ".venv")
    if (-not (Test-Path $Name)) {
        Write-Host "Creating virtual environment in '$Name'..." -ForegroundColor Cyan
        $pyCmd = Get-Command py -ErrorAction SilentlyContinue
        if ($pyCmd) {
            & $pyCmd.Source -m venv $Name
            if ($LASTEXITCODE -ne 0) {
                Write-Host "✖ py -m venv failed (exit $LASTEXITCODE)." -ForegroundColor Red
                return
            }
        }
        else {
            $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
            if (-not $pythonCmd) {
                Write-Host "✖ venv: Neither 'py' nor 'python' was found in PATH." -ForegroundColor Red
                return
            }
            & $pythonCmd.Source -m venv $Name
            if ($LASTEXITCODE -ne 0) {
                Write-Host "✖ python -m venv failed (exit $LASTEXITCODE)." -ForegroundColor Red
                return
            }
        }
    }
    $activate = Join-Path $Name "Scripts\Activate.ps1"
    if (Test-Path $activate) {
        & $activate
        Write-Host "Activated $Name (Python $((python --version 2>&1) -replace 'Python\s*'))" -ForegroundColor Green
    }
    else {
        Write-Host "✖ venv: Activation script not found: $activate" -ForegroundColor Red
    }
}

<#
.SYNOPSIS
Windows 11 native elevation. Runs command as Administrator; supports 'sudo !!' to re-run the previous command.
#>
function sudo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Command
    )

    $cmd = if ($Command.Count -eq 0 -or ($Command.Count -eq 1 -and $Command[0] -eq '!!')) {
        (Get-History -Count 1).CommandLine
    }
    else {
        $Command -join ' '
    }

    if (-not $cmd) { return }

    sudo.exe pwsh.exe -NoLogo -NoProfile -Command $cmd
}

<#
.SYNOPSIS
Compares two files, a file against the current clipboard, or two interactive clipboard copies using git diff --no-index:
  cmp                 - Clipboard watcher: waits for 2 Ctrl+C copies and diffs them
  cmp <file>          - Compares <file> against current clipboard text
  cmp <file1> <file2> - Compares two files (SHA-256 + git diff --no-index)
  Flags: -IgnoreWhitespace (-w), -Quiet (-q)
#>
function cmp {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [string]$file1,
        [Parameter(Position = 1)]
        [string]$file2,
        [Alias("w")]
        [switch]$IgnoreWhitespace,
        [Alias("q")]
        [switch]$Quiet
    )

    $compareTextPair = {
        param([string]$Text1, [string]$Text2, [string]$Label1, [string]$Label2)

        $t1 = if ($null -ne $Text1) { $Text1 } else { '' }
        $t2 = if ($null -ne $Text2) { $Text2 } else { '' }

        $isMatch = if ($IgnoreWhitespace) {
            ($t1 -replace '\s+', ' ').Trim() -ceq ($t2 -replace '\s+', ' ').Trim()
        }
        else {
            $t1 -ceq $t2
        }

        if ($isMatch) {
            Write-Host "Identical ($Label1 == $Label2)." -ForegroundColor Green
            return
        }

        if (($t1 -replace "`r`n", "`n") -ceq ($t2 -replace "`r`n", "`n")) {
            Write-Host "CRLF vs LF mismatch: " -NoNewline -ForegroundColor Yellow
            Write-Host "Identical text ($Label1 == $Label2), only line endings differ." -ForegroundColor White
            return
        }

        if ($Quiet) {
            Write-Host "Contents differ ($Label1 vs $Label2)." -ForegroundColor Red
            return
        }

        Write-Host "`nDifference ($Label1 vs $Label2):" -ForegroundColor Yellow
        $id = [guid]::NewGuid().ToString('N')
        $tmp1 = Join-Path ([System.IO.Path]::GetTempPath()) "pss-cmp-$id-1.txt"
        $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) "pss-cmp-$id-2.txt"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        try {
            [System.IO.File]::WriteAllText($tmp1, $t1, $utf8NoBom)
            [System.IO.File]::WriteAllText($tmp2, $t2, $utf8NoBom)
            $diffArgs = @('--no-pager', 'diff', '--no-index', '--color=auto')
            if ($IgnoreWhitespace) { $diffArgs += '-w' }
            $diffArgs += @('--', $tmp1, $tmp2)
            & git @diffArgs
        }
        finally {
            Remove-Item -LiteralPath $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
        }
    }

    # Mode 1: Interactive 2-copy clipboard watcher (`cmp` with no file arguments)
    if (-not $file1 -and -not $file2) {
        if (-not ([System.Management.Automation.PSTypeName]'Win32.NativeClipboard').Type) {
            Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();' `
                -Name 'NativeClipboard' `
                -Namespace 'Win32'
        }

        $waitForNextCopy = {
            param([uint32]$CurrentSeq, [string]$PromptText)
            Write-Host $PromptText -ForegroundColor Cyan
            while ($true) {
                $newSeq = [Win32.NativeClipboard]::GetClipboardSequenceNumber()
                if ($newSeq -ne $CurrentSeq) {
                    Start-Sleep -Milliseconds 50
                    $raw = Get-Clipboard -Raw -ErrorAction SilentlyContinue
                    $content = if ($null -ne $raw) { $raw } else { '' }
                    return [pscustomobject]@{ Sequence = $newSeq; Content = $content }
                }
                Start-Sleep -Milliseconds 100
            }
        }

        $initialSeq = [Win32.NativeClipboard]::GetClipboardSequenceNumber()
        Write-Host "`nClipboard Watcher" -ForegroundColor Cyan
        Write-Host "  Copy two snippets with Ctrl+C to compare them (Ctrl+C here to abort).`n" -ForegroundColor DarkGray

        $first = & $waitForNextCopy $initialSeq "  [1/2] Waiting for first copy..."
        Write-Host "  ✓ Captured copy 1 ($($first.Content.Length) chars)`n" -ForegroundColor Green

        $second = & $waitForNextCopy $first.Sequence "  [2/2] Waiting for second copy..."
        Write-Host "  ✓ Captured copy 2 ($($second.Content.Length) chars)`n" -ForegroundColor Green

        & $compareTextPair $first.Content $second.Content 'copy 1' 'copy 2'
        return
    }

    if (-not (Test-Path -LiteralPath $file1 -PathType Leaf)) {
        Write-Host "✖ cmp: File not found: $file1" -ForegroundColor Red
        return
    }
    $resolved1 = (Resolve-Path -LiteralPath $file1).Path

    # Mode 2: Single file vs current clipboard (`cmp <file>`)
    if (-not $file2) {
        $text1 = [System.IO.File]::ReadAllText($resolved1)
        $rawClip = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        $text2 = if ($null -ne $rawClip) { $rawClip } else { '' }
        & $compareTextPair $text1 $text2 $file1 'clipboard'
        return
    }

    # Mode 3: Two files (`cmp <file1> <file2>`)
    if (-not (Test-Path -LiteralPath $file2 -PathType Leaf)) {
        Write-Host "✖ cmp: File not found: $file2" -ForegroundColor Red
        return
    }
    $resolved2 = (Resolve-Path -LiteralPath $file2).Path

    if (-not $IgnoreWhitespace -and ((Get-FileHash -LiteralPath $resolved1).Hash -eq (Get-FileHash -LiteralPath $resolved2).Hash)) {
        Write-Host "Files are identical." -ForegroundColor Green
        return
    }

    if ($IgnoreWhitespace) {
        $null = & git diff --no-index --quiet -w -- $resolved1 $resolved2 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Files are identical (ignoring whitespace)." -ForegroundColor Green
            return
        }
        if ($LASTEXITCODE -gt 1) {
            Write-Host "✖ git diff --no-index failed (exit $LASTEXITCODE)." -ForegroundColor Red
            return
        }
    }

    if ($Quiet) {
        Write-Host "Contents differ ($file1 vs $file2). Files differ." -ForegroundColor Red
    }
    else {
        Write-Host "`nFiles differ:" -ForegroundColor Yellow
        $diffArgs = @('--no-pager', 'diff', '--no-index', '--color=auto')
        if ($IgnoreWhitespace) { $diffArgs += '-w' }
        $diffArgs += @('--', $resolved1, $resolved2)
        & git @diffArgs
        if ($LASTEXITCODE -gt 1) {
            Write-Host "✖ git diff --no-index failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
    }
}

# WARNING: Intentionally overrides PowerShell's built-in 'copy' alias (Copy-Item).
# Use 'Copy-Item' (or 'cp') explicitly when copying files.
Set-Alias -Name copy -Value Set-Clipboard -Option AllScope -Force
Set-Alias -Name paste -Value Get-Clipboard -Option AllScope -Force

<#
.SYNOPSIS
Decodes a JWT header and payload offline without making any network calls. Supports arguments, pipeline input, or clipboard fallback.
#>
function jwt {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string]$Token
    )

    begin {
        $handledAny = $false
        $decodePart = {
            param([string]$Segment)
            $b64 = $Segment.Replace('-', '+').Replace('_', '/')
            switch ($b64.Length % 4) {
                2 { $b64 += '==' }
                3 { $b64 += '=' }
            }
            $jsonText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            return ($jsonText | ConvertFrom-Json)
        }

        $decodeJwtString = {
            param([string]$RawInput)
            $raw = $RawInput.Trim() -replace '^Bearer\s+', ''
            $parts = $raw -split '\.'
            if ($parts.Count -lt 2) {
                Write-Host "✖ jwt: Invalid JWT format (expected header.payload[.signature])." -ForegroundColor Red
                return
            }

            try {
                $header = & $decodePart $parts[0]
                $payload = & $decodePart $parts[1]

                Write-Host "`nHeader" -ForegroundColor Cyan
                ($header | ConvertTo-Json -Depth 10) -split "`r?`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

                Write-Host "`nPayload" -ForegroundColor Cyan
                ($payload | ConvertTo-Json -Depth 10) -split "`r?`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

                if ($payload.exp) {
                    $expUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.exp).ToLocalTime()
                    $state = if ($expUtc -lt [DateTimeOffset]::Now) { "EXPIRED" } else { "VALID" }
                    $color = if ($state -eq "EXPIRED") { "Red" } else { "Green" }
                    Write-Host "`n  Expires: " -NoNewline -ForegroundColor DarkGray
                    Write-Host "$($expUtc.ToString('yyyy-MM-dd HH:mm:ss zzz')) " -NoNewline -ForegroundColor White
                    Write-Host "[$state]" -ForegroundColor $color
                }
                Write-Host ""
            }
            catch {
                Write-Host "✖ jwt: Failed to decode JWT: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    process {
        if ([string]::IsNullOrWhiteSpace($Token)) { return }
        $handledAny = $true
        & $decodeJwtString $Token
    }

    end {
        if (-not $handledAny -and -not $PSCmdlet.MyInvocation.ExpectingInput) {
            $clipToken = Get-Clipboard -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($clipToken)) {
                Write-Host "Usage: jwt <token>  (or pipe / copy a JWT to clipboard)" -ForegroundColor Yellow
                return
            }
            Write-Host "Decoding JWT from clipboard..." -ForegroundColor DarkGray
            & $decodeJwtString $clipToken
        }
    }
}

<#
.SYNOPSIS
Personal Settings Sync CLI runner (pss.ps1).
#>
function pss {
    $pssScript = Join-Path $global:__pss_root "pss.ps1"
    if (Test-Path -LiteralPath $pssScript) {
        & $pssScript @args
    }
    else {
        Write-Host "✖ pss: pss.ps1 not found at: $pssScript" -ForegroundColor Red
    }
}
#endregion

#region 5. PSReadLine & Predictive IntelliSense
if ($Host.UI.RawUI -and (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
    try {
        $psReadLineModule = Get-Module PSReadLine
        if (-not $psReadLineModule) {
            $psReadLineModule = Import-Module PSReadLine -PassThru -ErrorAction SilentlyContinue
        }

        if ($psReadLineModule -and $psReadLineModule.Version -ge [Version]'2.2.0') {
            Import-Module CompletionPredictor -ErrorAction SilentlyContinue
            Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
            Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
            Set-PSReadLineOption -Colors @{ InlinePrediction = "$([char]0x1b)[38;5;242m" } -ErrorAction SilentlyContinue
        }

        Set-PSReadLineKeyHandler -Key "Tab" -Function TabCompleteNext -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "Shift+Tab" -Function TabCompletePrevious -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "Ctrl+Spacebar" -Function MenuComplete -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "RightArrow" -BriefDescription "ForwardCharOrAcceptNextSuggestionWord" -ScriptBlock {
            param($key, $arg)
            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ($cursor -lt $line.Length) {
                [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
            }
            else {
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptNextSuggestionWord($key, $arg)
            }
        } -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key "F2" -Function SwitchPredictionView -ErrorAction SilentlyContinue
    }
    catch {
        # Fallback gracefully in non-interactive / redirected consoles
    }
}
#endregion

#region 6. Powerline Segmented Prompt
function prompt {
    # Track directory history for 'back' command
    if ($global:__current_location -and $global:__current_location -ne $pwd.Path) {
        $global:__prev_location = $global:__current_location
    }
    $global:__current_location = $pwd.Path

    $lastError = $global:?
    $statusColor = if ($lastError) { "Green" } else { "Red" }
    $arrow = [char]0xE0B0

    # 1. Timer Logic: always record $global:cmdtime; only render on prompt bar if $global:__show_prompt_timer is $true
    $durationText = ""
    $global:cmdtime = $null
    $lastCommand = Get-History -Count 1 -ErrorAction SilentlyContinue
    if ($lastCommand) {
        $duration = $lastCommand.EndExecutionTime - $lastCommand.StartExecutionTime
        $formattedTime = if ($duration.TotalMinutes -ge 1) {
            "{0:N0}m {1:N0}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
        }
        elseif ($duration.TotalSeconds -ge 1) {
            "{0:N2}s" -f $duration.TotalSeconds
        }
        else {
            "{0:N0}ms" -f $duration.TotalMilliseconds
        }
        $global:cmdtime = $formattedTime
        if ($global:__show_prompt_timer -and $duration.TotalMilliseconds -gt 500) {
            $durationText = " ⏱ $formattedTime "
        }
    }

    # 2. Directory Logic (2-tier path to eliminate folder ambiguity)
    $normalizedPath = $pwd.Path -replace ('^' + [regex]::Escape($HOME)), '~'
    if ($normalizedPath -eq '~') {
        $currentDir = '~'
    }
    else {
        $segments = $normalizedPath.TrimEnd('\', '/') -split '[\\/]'
        if ($segments.Count -ge 2) {
            $currentDir = "$($segments[-2])/$($segments[-1])"
        }
        else {
            $currentDir = $segments[-1]
        }
    }

    # 3. Fast Git Logic with In-Memory Caching (no process spawn per prompt)
    $gitBranch = ''
    $searchDir = $pwd.Path
    $inGitRepo = $false
    while ($searchDir) {
        if (Test-Path (Join-Path $searchDir '.git') -ErrorAction SilentlyContinue) {
            $inGitRepo = $true
            break
        }
        $parent = Split-Path $searchDir -Parent
        if ($parent -eq $searchDir) { break }
        $searchDir = $parent
    }

    if ($inGitRepo) {
        $gitItem = Join-Path $searchDir '.git'
        $headPath = $null

        if ($global:__git_cache_repo -eq $searchDir -and $global:__git_cache_head_path) {
            $headPath = $global:__git_cache_head_path
        }
        else {
            if (Test-Path -PathType Container -LiteralPath $gitItem) {
                $headPath = Join-Path $gitItem 'HEAD'
            }
            elseif (Test-Path -PathType Leaf -LiteralPath $gitItem) {
                # Submodule or worktree: .git is a file containing "gitdir: <path>"
                $gitDirLine = (Get-Content -LiteralPath $gitItem -First 1 -ErrorAction SilentlyContinue)
                if ($gitDirLine -match '^gitdir:\s*(.+)$') {
                    $targetDir = $matches[1].Trim()
                    if (-not [System.IO.Path]::IsPathRooted($targetDir)) {
                        $targetDir = [System.IO.Path]::GetFullPath((Join-Path $searchDir $targetDir))
                    }
                    $headPath = Join-Path $targetDir 'HEAD'
                }
            }
        }

        if ($headPath -and (Test-Path -LiteralPath $headPath)) {
            $headTime = [System.IO.File]::GetLastWriteTimeUtc($headPath)
            if ($global:__git_cache_repo -eq $searchDir -and $global:__git_cache_head_time -eq $headTime -and $global:__git_cache_branch) {
                $gitBranch = $global:__git_cache_branch
            }
            else {
                try {
                    $headContent = [System.IO.File]::ReadAllText($headPath).Trim()
                    if ($headContent -match '^ref: refs/heads/(.+)$') {
                        $gitBranch = $matches[1]
                    }
                    elseif ($headContent) {
                        $gitBranch = if ($headContent.Length -ge 7) { ":" + $headContent.Substring(0, 7) } else { $headContent }
                    }
                    else {
                        $gitBranch = (& git branch --show-current 2>$null) -join ''
                    }
                }
                catch {
                    $gitBranch = (& git branch --show-current 2>$null) -join ''
                }

                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $headPath
                $global:__git_cache_head_time = $headTime
                $global:__git_cache_branch = $gitBranch
            }
        }
        else {
            if ($global:__git_cache_repo -ne $searchDir) {
                $global:__git_cache_branch = (& git branch --show-current 2>$null) -join ''
                $global:__git_cache_repo = $searchDir
                $global:__git_cache_head_path = $null
                $global:__git_cache_head_time = [datetime]::MinValue
            }
            $gitBranch = $global:__git_cache_branch
        }
    }
    else {
        $global:__git_cache_repo = $null
        $global:__git_cache_head_path = $null
        $global:__git_cache_head_time = [datetime]::MinValue
        $global:__git_cache_branch = ''
    }

    # Expose current git branch ($cb), repo root ($gr), and cached current workset ($cw)
    $global:cb = $gitBranch
    $global:gr = if ($inGitRepo) { $searchDir } else { $null }
    if ($global:gr -and $gitBranch -and (Get-Command Get-CurrentWorksetName -CommandType Function -ErrorAction SilentlyContinue) -and (Get-PssActiveWorkspace) -eq 'work') {
        $activeWorksetDir = Join-Path $global:__pss_state.Root 'worksets\work\active'
        $dirStamp = if (Test-Path -LiteralPath $activeWorksetDir) {
            [System.IO.Directory]::GetLastWriteTimeUtc($activeWorksetDir).Ticks
        }
        else { 0 }
        $cacheKey = "$($global:gr)|$gitBranch|$dirStamp"
        if ($global:__cw_cache_key -eq $cacheKey) {
            $global:cw = $global:__cw_cache_value
        }
        else {
            try {
                $global:cw = Get-CurrentWorksetName -Root $global:gr -Branch $gitBranch
                $global:__cw_cache_key = $cacheKey
                $global:__cw_cache_value = $global:cw
            }
            catch {
                $global:cw = $null
                $global:__cw_cache_key = $null
                Write-Warning "Unable to determine current workset: $_"
            }
        }
    }
    else {
        $global:cw = $null
        $global:__cw_cache_key = $null
    }

    # 4. Build Segments
    $segments = [System.Collections.Generic.List[hashtable]]::new()

    # Elevated Admin badge (only if running as Administrator)
    if ($global:__is_admin) {
        $segments.Add(@{ Text = "⚡ ADMIN"; Bg = "DarkRed"; Fg = "Yellow" })
    }

    # Directory segment
    $segments.Add(@{ Text = $currentDir; Bg = "Blue"; Fg = "White" })

    # Python Virtual Environment segment (integrated into the bar)
    if ($env:VIRTUAL_ENV) {
        $venvName = Split-Path $env:VIRTUAL_ENV -Leaf
        $segments.Add(@{ Text = "($venvName)"; Bg = "DarkGreen"; Fg = "White" })
    }

    # Git branch segment (if inside a git repo)
    if ($gitBranch) {
        $segments.Add(@{ Text = $gitBranch; Bg = "DarkMagenta"; Fg = "White" })
    }

    # Command duration timer (if > 500ms)
    if ($durationText) {
        $segments.Add(@{ Text = $durationText; Bg = "DarkYellow"; Fg = "Black" })
    }

    # 5. Render Segments
    Write-Host "`n" -NoNewline
    $currentBg = $null

    foreach ($s in $segments) {
        if (-not $currentBg) {
            Write-Host " $($s.Text) " -BackgroundColor $s.Bg -ForegroundColor $s.Fg -NoNewline
        }
        else {
            Write-Host $arrow -BackgroundColor $s.Bg -ForegroundColor $currentBg -NoNewline
            Write-Host " $($s.Text) " -BackgroundColor $s.Bg -ForegroundColor $s.Fg -NoNewline
        }
        $currentBg = $s.Bg
    }

    Write-Host $arrow -ForegroundColor $currentBg -NoNewline
    Write-Host " ❯" -ForegroundColor $statusColor -NoNewline
    return " "
}
#endregion

#region 7. Workspace & Machine-Local Overrides
foreach ($group in $profileGroups | Where-Object { $_.Scope -eq 'workspace' }) {
    if ($group.Required -or (Test-Path -LiteralPath $group.Path)) {
        . $group.Path
    }
}

# Load optional machine-local overrides (never synced)
if (Test-Path -LiteralPath $global:__pss_state.LocalProfile) {
    . $global:__pss_state.LocalProfile
}
#endregion

