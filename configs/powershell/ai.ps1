<#
.SYNOPSIS
Runs a polling wait loop with a green ASCII spinner and cancellation cleanup.
#>
function Invoke-WithSpinner {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$IsDone,
        [scriptblock]$OnCancel
    )

    $frames = @('|', '/', '-', '\')
    $green = $global:__ansi.Green
    $reset = $global:__ansi.Reset
    $esc = [char]0x1b
    $animate = -not [Console]::IsOutputRedirected
    $i = 0

    try {
        if ($animate) { Write-Host "${esc}[?25l" -NoNewline }
        while (-not (& $IsDone)) {
            if ($animate) {
                $frame = $frames[$i % $frames.Length]
                Write-Host "`r${green}${frame}${reset} " -NoNewline
                $i++
            }
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        if ($animate) {
            Write-Host "`r${esc}[2K${esc}[?25h" -NoNewline
        }
        if (-not (& $IsDone) -and $OnCancel) {
            & $OnCancel
        }
    }
}

function ConvertTo-TerminalCommandBlocks {
    param(
        [string[]]$Lines,
        [switch]$IncludeActive,
        [string]$FallbackCommand
    )

    if (-not $Lines -or $Lines.Count -eq 0) { return @() }

    # Match both Powerline glyph (' ❯ cmd') and space-separated ('dir  branch  ❯ cmd') prompts
    $promptPattern = '^(?:.*?(?:[\uE0B0]\s*|\s{2,}))?\u276F\s*(.*)$'
    $blocks = [System.Collections.Generic.List[object]]::new()
    $leadingOut = [System.Collections.Generic.List[string]]::new()
    $currentCmd = $null
    $currentOut = [System.Collections.Generic.List[string]]::new()
    $seenPrompt = $false

    $trimBlockLines = {
        param([System.Collections.Generic.List[string]]$SourceLines)
        $start = 0
        $end = $SourceLines.Count - 1
        while ($start -le $end -and [string]::IsNullOrWhiteSpace($SourceLines[$start])) { $start++ }
        while ($end -ge $start -and [string]::IsNullOrWhiteSpace($SourceLines[$end])) { $end-- }
        if ($start -le $end) {
            return @($SourceLines[$start..$end])
        }
        return @()
    }

    $flushBlock = {
        if (-not $seenPrompt) { return }
        [void]$blocks.Add([PSCustomObject]@{
            Command = $currentCmd
            Output  = (& $trimBlockLines $currentOut)
        })
    }

    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        if ($line -match $promptPattern) {
            & $flushBlock
            $seenPrompt = $true
            $currentCmd = $matches[1].Trim()
            $currentOut = [System.Collections.Generic.List[string]]::new()
        }
        elseif ($seenPrompt) {
            [void]$currentOut.Add($line)
        }
        else {
            [void]$leadingOut.Add($line)
        }
    }

    if ($IncludeActive -and $seenPrompt) {
        & $flushBlock
    }

    # In ConPTY hosts where BufferSize.Height equals WindowSize.Height, tall outputs push the opening prompt off-screen
    if ($blocks.Count -eq 0 -and $seenPrompt -and $PSBoundParameters.ContainsKey('FallbackCommand') -and -not [string]::IsNullOrWhiteSpace($FallbackCommand)) {
        $trimmedLeading = @(& $trimBlockLines $leadingOut)
        if ($trimmedLeading.Count -gt 0) {
            [void]$blocks.Add([PSCustomObject]@{
                Command = $FallbackCommand
                Output  = $trimmedLeading
            })
        }
    }

    return @($blocks.ToArray())
}

function Resolve-TerminalBlockIndices {
    param(
        [string]$Spec,
        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    if ($Count -le 0) { return @() }
    $s = if ($Spec) { $Spec.Trim() } else { '1' }

    # Single offset: ~N (1 = most recent completed command)
    if ($s -match '^~(\d+)$') {
        $offset = [int]$matches[1]
        if ($offset -lt 1 -or $offset -gt $Count) { return @() }
        return @($Count - $offset)
    }

    # Range offset: ~A..B or ~A..~B (e.g. ~3..2 or ~3..~2 -> chronological order)
    if ($s -match '^~(\d+)\.\.~?(\d+)$') {
        $a = [int]$matches[1]
        $b = [int]$matches[2]
        if ($a -lt 1 -or $b -lt 1) { return @() }
        $startOffset = [Math]::Min($Count, [Math]::Max($a, $b))
        $endOffset = [Math]::Max(1, [Math]::Min($a, $b))
        if ($startOffset -lt $endOffset) { return @() }
        $indices = for ($off = $startOffset; $off -ge $endOffset; $off--) { $Count - $off }
        return @($indices)
    }

    # Count: N (last N completed commands in chronological order)
    if ($s -match '^(\d+)$') {
        $n = [Math]::Min($Count, [Math]::Max(1, [int]$matches[1]))
        $startIdx = $Count - $n
        return @($startIdx..($Count - 1))
    }

    throw "Invalid selector '$Spec'. Use N (last N), ~N (Nth last), or ~A..B / ~A..~B (slice)."
}

function Get-TerminalCommandBlocks {
    param(
        [int]$MaxLines = 500
    )

    try {
        $rawUi = $Host.UI.RawUI
        $endY = [Math]::Min($rawUi.BufferSize.Height - 1, [Math]::Max(0, $rawUi.CursorPosition.Y))
        $startY = [Math]::Max(0, $endY - $MaxLines)
        $rect = [System.Management.Automation.Host.Rectangle]::new(0, $startY, $rawUi.BufferSize.Width - 1, $endY)
        $buffer = $rawUi.GetBufferContents($rect)
        $lines = for ($y = 0; $y -lt $buffer.GetLength(0); $y++) {
            $chars = for ($x = 0; $x -lt $buffer.GetLength(1); $x++) {
                $cell = $buffer[$y, $x]
                if ($cell.BufferCellType -ne [System.Management.Automation.Host.BufferCellType]::Trailing -and $cell.Character -ne [char]0) {
                    $cell.Character
                }
            }
            (-join $chars).TrimEnd()
        }
        $lastHist = Get-History -Count 1 -ErrorAction SilentlyContinue
        if ($lastHist -and -not [string]::IsNullOrWhiteSpace($lastHist.CommandLine)) {
            return @(ConvertTo-TerminalCommandBlocks -Lines $lines -FallbackCommand $lastHist.CommandLine)
        }
        return @(ConvertTo-TerminalCommandBlocks -Lines $lines)
    }
    catch {
        return @()
    }
}

function Resolve-AskRequest {
    param(
        [string[]]$QuestionArgs,
        [string]$Piped,
        [switch]$IncludeCtx,
        [string]$PromptPreamble
    )

    $ctxSpec = '1'
    $qList = if ($QuestionArgs) { @($QuestionArgs) } else { @() }
    if ($IncludeCtx -and $qList.Count -gt 0 -and ([string]$qList[0]) -match '^(?:\d+|~\d+(?:\.\.~?\d+)?)$') {
        $ctxSpec = [string]$qList[0]
        $qList = @($qList | Select-Object -Skip 1)
    }

    $question = ($qList -join ' ').Trim()
    $hasPiped = -not [string]::IsNullOrWhiteSpace($Piped)
    if (-not $question -and -not $hasPiped -and -not $IncludeCtx) {
        return $null
    }

    $promptQuestion = if ($question) {
        $question
    }
    elseif ($hasPiped) {
        "Analyze or answer based on the piped input above."
    }
    else {
        "Explain or address the terminal command and output shown in context above."
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    [void]$parts.Add($PromptPreamble.Trim())

    if ($IncludeCtx) {
        $blocks = @(Get-TerminalCommandBlocks)
        if ($blocks.Count -gt 0) {
            $indices = @(Resolve-TerminalBlockIndices -Spec $ctxSpec -Count $blocks.Count)
            if ($indices.Count -gt 0) {
                $ctxLines = [System.Collections.Generic.List[string]]::new()
                foreach ($idx in $indices) {
                    $b = $blocks[$idx]
                    [void]$ctxLines.Add("$ $($b.Command)")
                    if ($b.Output -and $b.Output.Count -gt 0) {
                        foreach ($ol in $b.Output) { [void]$ctxLines.Add($ol) }
                    }
                    else {
                        [void]$ctxLines.Add("(no output)")
                    }
                    [void]$ctxLines.Add("")
                }
                [void]$parts.Add("[Context: Terminal Commands & Output (`"$ctxSpec`")]`n$($ctxLines -join "`n")")
            }
        }
        else {
            # Fallback when host has no accessible screen buffer
            $hist = @(Get-History -ErrorAction SilentlyContinue)
            if ($hist.Count -gt 0) {
                $indices = @(Resolve-TerminalBlockIndices -Spec $ctxSpec -Count $hist.Count)
                $histText = ($indices | ForEach-Object { "$($hist[$_].Id): $($hist[$_].CommandLine)" }) -join "`n"
                if ($histText) {
                    [void]$parts.Add("[Context: Recent Terminal Commands]`n$histText")
                }
            }
        }
    }

    if ($hasPiped) {
        [void]$parts.Add("[Context: Piped Input]`n$Piped")
    }

    [void]$parts.Add("[User Question]`n$promptQuestion")

    return ($parts -join "`n`n")
}

function Invoke-AskCliProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [switch]$StreamJson,
        [switch]$InteractiveStream
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new($ExecutablePath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.WorkingDirectory = $pwd.Path
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }

    $cyan = $global:__ansi.Cyan
    $yellow = $global:__ansi.Yellow
    $gray = $global:__ansi.Gray
    $green = $global:__ansi.Green
    $red = $global:__ansi.Red
    $reset = $global:__ansi.Reset
    $esc = [char]0x1b
    $frames = @('|', '/', '-', '\')
    $animate = -not [Console]::IsOutputRedirected

    $script:__ask_last_conv_id = $null
    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    $proc = $null
    $stderr = ""
    $exitCode = 0
    $sawDelta = $false
    $streamError = $null
    $lineBuf = [System.Text.StringBuilder]::new()
    # Shared state hashtable ensures & scriptblock invocations update the parent's flags across child scopes
    $state = @{
        HeaderShown      = $false
        CursorHidden     = $false
        EndedWithNewline = $true
        LastResponseStep = $null
    }

    $clearSpinner = {
        if ($animate -and $state.CursorHidden) {
            Write-Host "`r${esc}[2K${esc}[?25h" -NoNewline
            $state.CursorHidden = $false
        }
    }

    $showHeader = {
        if (-not $state.HeaderShown) {
            & $clearSpinner
            Write-Host "`n${cyan}▸ ask${reset} ${gray}($Label)${reset}"
            $state.HeaderShown = $true
        }
    }

    $emitLine = {
        param([string]$Line)
        & $showHeader
        if ($InteractiveStream) {
            Write-Host $Line
            $state.EndedWithNewline = $true
        }
        else {
            Write-Output $Line
        }
    }

    $appendDelta = {
        param([string]$Delta)
        if ([string]::IsNullOrEmpty($Delta)) { return }
        if ($InteractiveStream) {
            & $showHeader
            $normalized = $Delta.Replace("`r`n", "`n")
            Write-Host $normalized -NoNewline
            $state.EndedWithNewline = $normalized.EndsWith("`n")
            return
        }
        [void]$lineBuf.Append($Delta)
        $text = $lineBuf.ToString()
        while ($true) {
            $nlIdx = $text.IndexOf("`n")
            if ($nlIdx -lt 0) { break }
            $completed = $text.Substring(0, $nlIdx).TrimEnd("`r")
            & $emitLine $completed
            $text = $text.Substring($nlIdx + 1)
        }
        [void]$lineBuf.Clear()
        if ($text.Length -gt 0) { [void]$lineBuf.Append($text) }
    }

    try {
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        }
        catch {
            Write-Host "`n${red}✖ ${exeName}: failed to start ($($_.Exception.Message))${reset}`n"
            return
        }
        $stdoutTask = $proc.StandardOutput.ReadLineAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if ($animate) {
            Write-Host "${esc}[?25l" -NoNewline
            $state.CursorHidden = $true
        }

        $frameIdx = 0
        $stdoutDone = $false
        while (-not $stdoutDone) {
            if ($stdoutTask.IsCompleted) {
                $rawLine = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $rawLine) {
                    $stdoutDone = $true
                    if (-not $InteractiveStream -and $lineBuf.Length -gt 0) {
                        & $emitLine ($lineBuf.ToString().TrimEnd("`r"))
                        [void]$lineBuf.Clear()
                    }
                }
                else {
                    $stdoutTask = $proc.StandardOutput.ReadLineAsync()
                    if ($StreamJson) {
                        if (-not [string]::IsNullOrWhiteSpace($rawLine)) {
                            $ev = try { $rawLine | ConvertFrom-Json -ErrorAction Stop } catch { $null }
                            if ($ev) {
                                if ($ev.conversation_id -and -not $script:__ask_last_conv_id) {
                                    $script:__ask_last_conv_id = [string]$ev.conversation_id
                                }
                                if ($ev.event -eq 'step_update' -and $ev.step_update.step_type -eq 'agent_response') {
                                    $stepIdx = $ev.step_update.step_index
                                    if ($null -ne $stepIdx -and $null -ne $state.LastResponseStep -and $stepIdx -ne $state.LastResponseStep) {
                                        if ($InteractiveStream -and $state.HeaderShown -and -not $state.EndedWithNewline) {
                                            Write-Host ""
                                            $state.EndedWithNewline = $true
                                        }
                                        elseif (-not $InteractiveStream -and $lineBuf.Length -gt 0) {
                                            & $emitLine ($lineBuf.ToString().TrimEnd("`r"))
                                            [void]$lineBuf.Clear()
                                        }
                                    }
                                    if ($null -ne $stepIdx) {
                                        $state.LastResponseStep = $stepIdx
                                    }
                                    if ($null -ne $ev.step_update.text_delta) {
                                        $sawDelta = $true
                                        & $appendDelta ([string]$ev.step_update.text_delta)
                                    }
                                }
                                elseif ($ev.event -eq 'step_update' -and $ev.step_update.step_type -eq 'error_message') {
                                    & $showHeader
                                    if ($InteractiveStream -and -not $state.EndedWithNewline) {
                                        Write-Host ""
                                        $state.EndedWithNewline = $true
                                    }
                                    elseif (-not $InteractiveStream -and $lineBuf.Length -gt 0) {
                                        & $emitLine ($lineBuf.ToString().TrimEnd("`r"))
                                        [void]$lineBuf.Clear()
                                    }
                                    Write-Host "${yellow}[agy step interrupted — retrying]${reset}"
                                }
                                elseif ($ev.event -eq 'result' -and $ev.result) {
                                    if ($ev.result.conversation_id -and -not $script:__ask_last_conv_id) {
                                        $script:__ask_last_conv_id = [string]$ev.result.conversation_id
                                    }
                                    if (-not $sawDelta -and $ev.result.response) {
                                        & $appendDelta ([string]$ev.result.response)
                                    }
                                    if ($ev.result.status -and $ev.result.status -ne 'SUCCESS') {
                                        $errDetail = if ($ev.result.error) { [string]$ev.result.error } elseif ($ev.result.message) { [string]$ev.result.message } else { $null }
                                        if ($errDetail) {
                                            $cleanDetail = ($errDetail -replace '\r?\n', ' ' -replace '\s*Retries remaining:\s*\d+\s*$', '').Trim()
                                            $streamError = "$($ev.result.status) — $cleanDetail"
                                        }
                                        else {
                                            $streamError = "Status: $($ev.result.status)"
                                        }
                                    }
                                }
                            }
                        }
                    }
                    else {
                        & $emitLine $rawLine
                    }
                }
            }
            else {
                if ($animate -and -not $state.HeaderShown) {
                    $frame = $frames[$frameIdx % $frames.Length]
                    Write-Host "`r${green}${frame}${reset} " -NoNewline
                    $frameIdx++
                }
                Start-Sleep -Milliseconds 60
            }
        }

        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $stderr = $stderrTask.GetAwaiter().GetResult()
    }
    finally {
        & $clearSpinner
        if ($proc) {
            if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
            $proc.Dispose()
        }
    }

    if ($state.HeaderShown) {
        if ($InteractiveStream -and -not $state.EndedWithNewline) {
            Write-Host ""
        }
        Write-Host ""
    }

    if ($streamError -and -not ($stderr -and $stderr.Trim())) {
        Write-Host "`n${red}✖ $exeName ($Label) error: $streamError${reset}`n"
    }

    if ($stderr -and $stderr.Trim()) {
        $trimmedErr = $stderr.TrimEnd("`r", "`n") -split "`r?`n"
        if ($exitCode -ne 0) {
            Write-Host "`n${red}✖ $exeName failed (exit $exitCode):${reset}"
            $trimmedErr | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            Write-Host ""
        }
        else {
            # Non-fatal stderr on success (e.g. Copilot token/credit usage summary); kept on host stream so piping excludes it
            $trimmedErr | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            Write-Host ""
        }
    }
    elseif ($exitCode -ne 0 -and -not $streamError) {
        Write-Host "`n${red}✖ $exeName failed (exit $exitCode).${reset}`n"
    }
}

<#
.SYNOPSIS
Outputs terminal output from recent completed command(s) captured passively from the screen buffer (pipable to 'copy' or 'ask'):
  out                 - Last completed command's output (alias: 'lastout')
  out <n>             - Output from last <n> completed commands
  out ~<n>            - Output from the <n>th-last completed command (e.g. 'out ~2')
  out ~<a>..<b>       - Output from slice ~<a> through <b> (e.g. 'out ~3..2' or 'out ~3..~2')
  Flags: -IncludeCommand (-c) prepends '$ <command>' headers
#>
function out {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Selector = '1',
        [Alias("c")][switch]$IncludeCommand
    )

    $blocks = @(Get-TerminalCommandBlocks)
    if ($blocks.Count -eq 0) {
        Write-Host "No completed command blocks found in the current terminal buffer." -ForegroundColor Yellow
        return
    }

    $indices = @(Resolve-TerminalBlockIndices -Spec $Selector -Count $blocks.Count)
    if ($indices.Count -eq 0) {
        Write-Host "Selector '$Selector' matched none of the $($blocks.Count) captured command(s)." -ForegroundColor Yellow
        return
    }

    foreach ($idx in $indices) {
        $b = $blocks[$idx]
        if ($IncludeCommand) {
            Write-Output "$ $($b.Command)"
        }
        if ($b.Output) {
            foreach ($line in $b.Output) {
                Write-Output $line
            }
        }
    }
}
Set-Alias -Name lastout -Value out

<#
.SYNOPSIS
Previews recent command(s) from session history and prompts [y/N] before re-executing them (-y/-Yes bypasses confirmation while still printing the preview):
  rerun [-y]               - Re-runs the most recent command (~1)
  rerun ~<n> [-y]          - Re-runs the <n>th-last command (e.g. 'rerun ~2')
  rerun ~<a>..<b> [-y]     - Re-runs a chronological slice of commands (e.g. 'rerun ~3..2' or 'rerun ~3..~2')
  rerun <n> [-y]           - Re-runs the last <n> commands in chronological order
#>
function rerun {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Selector = '1',
        [Alias("y")][switch]$Yes
    )

    if ($script:__in_rerun) {
        Write-Host "✖ rerun: recursive invocation blocked." -ForegroundColor Red
        return
    }

    $filterRerunCmds = {
        param([string[]]$Candidates)
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($cand in $Candidates) {
            if ([string]::IsNullOrWhiteSpace($cand)) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($cand, [ref]$null, [ref]$null)
            $hasRerun = $null -ne $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'rerun'
            }, $true)
            if (-not $hasRerun) {
                [void]$kept.Add($cand)
            }
        }
        return @($kept.ToArray())
    }

    $cmds = @(& $filterRerunCmds @(Get-History -ErrorAction SilentlyContinue | ForEach-Object { $_.CommandLine }))
    if ($cmds.Count -eq 0) {
        $cmds = @(& $filterRerunCmds @(Get-TerminalCommandBlocks | ForEach-Object { $_.Command }))
    }
    if ($cmds.Count -eq 0) {
        Write-Host "No prior commands found to re-run." -ForegroundColor Yellow
        return
    }

    $indices = @(Resolve-TerminalBlockIndices -Spec $Selector -Count $cmds.Count)
    if ($indices.Count -eq 0) {
        Write-Host "Selector '$Selector' matched none of the $($cmds.Count) recorded command(s)." -ForegroundColor Yellow
        return
    }

    $toRun = @($indices | ForEach-Object { $cmds[$_] })
    Write-Host "`nCommands to execute:" -ForegroundColor Yellow
    foreach ($c in $toRun) {
        Write-Host "  > $c" -ForegroundColor White
    }
    if (-not $Yes) {
        $reply = Read-Host "Proceed? [y/N]"
        if ($reply -notmatch '^[Yy](es)?$') {
            Write-Host "Aborted." -ForegroundColor DarkGray
            return
        }
    }

    $script:__in_rerun = $true
    try {
        foreach ($c in $toRun) {
            try {
                $global:LASTEXITCODE = 0
                Invoke-Expression $c
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "✖ Command exited with code ${LASTEXITCODE}: $c" -ForegroundColor Red
                    break
                }
            }
            catch {
                Write-Host "✖ rerun: Command failed ($c): $($_.Exception.Message)" -ForegroundColor Red
                break
            }
        }
    }
    finally {
        $script:__in_rerun = $false
    }
}

<#
.SYNOPSIS
Evaluates a scenario or piped context using the Gemini Decision API and renders a confidence verdict.
#>
function decide {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Question,
        [string[]]$Choices = @("yes", "no"),
        [string]$Instructions = "Evaluate the scenario and pick the best option.",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject
    )

    begin {
        $pipeLines = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $pipeLines.Add([string]$InputObject)
        }
    }

    end {
        if ([string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {
            Write-Host "✖ decide: GEMINI_API_KEY environment variable is not set." -ForegroundColor Red
            return
        }

        if ($Choices.Count -lt 2) {
            Write-Host "✖ decide: Choices must contain at least 2 options." -ForegroundColor Red
            return
        }

        $piped = $pipeLines -join "`n"
        $qText = if ($Question) { $Question -join ' ' } else { "" }

        if ([string]::IsNullOrWhiteSpace($qText) -and [string]::IsNullOrWhiteSpace($piped)) {
            Write-Host "Usage: decide [-Choices <a,b>] [-Instructions <text>] <question>" -ForegroundColor Yellow
            return
        }

        if ([string]::IsNullOrWhiteSpace($qText)) {
            $qText = "What is the recommended decision?"
        }

        $target = if (-not [string]::IsNullOrWhiteSpace($piped)) {
            "Context / Input:`n$piped`n`nQuestion: $qText"
        }
        else {
            $qText
        }

        $criteria = [ordered]@{}
        foreach ($c in $Choices) {
            $criteria[$c] = "Option: $c"
        }

        $payload = [ordered]@{
            model     = "gemini-decision-1"
            input     = $target
            questions = [ordered]@{
                verdict = [ordered]@{
                    type         = "choice"
                    instructions = $Instructions
                    criteria     = $criteria
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $cts = [System.Threading.CancellationTokenSource]::new()
        $client = [System.Net.Http.HttpClient]::new()
        $client.DefaultRequestHeaders.Add("x-goog-api-key", $env:GEMINI_API_KEY)
        $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, "application/json")

        $res = $null
        try {
            $httpTask = $client.PostAsync(
                "https://generativelanguage.googleapis.com/v1beta/decisions",
                $content,
                $cts.Token
            )
            Invoke-WithSpinner -IsDone { $httpTask.IsCompleted } -OnCancel { $cts.Cancel() }

            $response = $httpTask.GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                Write-Host "✖ Gemini Decisions API failed ($([int]$response.StatusCode) $($response.ReasonPhrase)): $body" -ForegroundColor Red
                return
            }
            $res = $body | ConvertFrom-Json
        }
        catch {
            Write-Host "✖ Gemini Decisions API request failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
        finally {
            $content.Dispose()
            $client.Dispose()
            $cts.Dispose()
        }

        $verdict = $res.answers.verdict
        $choice = [string]$verdict.choice
        $p = [double]$verdict.confidence
        $pct = [int][Math]::Round($p * 100)
        $filled = [Math]::Clamp([int][Math]::Round($p * 10), 0, 10)
        $bar = ("█" * $filled) + ("░" * (10 - $filled))

        $badgeColor = switch ($choice.ToLowerInvariant()) {
            "yes" { "Green" }
            "no" { "Red" }
            default { "Cyan" }
        }
        $barColor = if ($p -ge 0.8) { "Green" } elseif ($p -ge 0.5) { "Yellow" } else { "Red" }

        Write-Host ""
        Write-Host "  [$($choice.ToUpperInvariant())]" -ForegroundColor $badgeColor -NoNewline
        Write-Host ("  {0,3}%  " -f $pct) -ForegroundColor White -NoNewline
        Write-Host $bar -ForegroundColor $barColor -NoNewline
        Write-Host "  $qText" -ForegroundColor DarkGray

        if ($Choices.Count -gt 2 -and $verdict.probabilities) {
            $breakdown = foreach ($prop in $verdict.probabilities.PSObject.Properties) {
                "{0} {1:P0}" -f $prop.Name, [double]$prop.Value
            }
            Write-Host "  $($breakdown -join ' · ')" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}
