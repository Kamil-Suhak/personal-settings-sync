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

function Get-TerminalAskContext {
    param(
        [string]$Question,
        [string]$Piped,
        [switch]$Clean
    )

    $pipedSection = if (-not [string]::IsNullOrWhiteSpace($Piped)) {
        "`n[Context: Piped Input]`n$Piped`n"
    }
    else { "" }

    $promptQuestion = if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $Question
    }
    else {
        "Analyze or answer based on the piped input above."
    }

    if ($Clean) {
        $historyCmds = "<empty>"
        $recentOutput = "<empty>"
    }
    else {
        $historyCmds = (Get-History -Count 5 | ForEach-Object { "$($_.Id): $($_.CommandLine)" }) -join "`n"
        $recentOutput = ""
        try {
            $rawUi = $Host.UI.RawUI
            $cursorY = $rawUi.CursorPosition.Y
            $startY = [Math]::Max(0, $cursorY - 30)
            $rect = [System.Management.Automation.Host.Rectangle]::new(0, $startY, $rawUi.BufferSize.Width - 1, $cursorY)
            $buffer = $rawUi.GetBufferContents($rect)
            $lines = for ($y = 0; $y -lt $buffer.GetLength(0); $y++) {
                $line = -join $(for ($x = 0; $x -lt $buffer.GetLength(1); $x++) { $buffer[$y, $x].Character })
                $line.TrimEnd()
            }
            $recentOutput = ($lines | Where-Object { $_ -ne "" }) -join "`n"
        }
        catch {
            $recentOutput = "(Screen buffer capture unavailable)"
        }
    }

    return [PSCustomObject]@{
        History      = $historyCmds
        Output       = $recentOutput
        PipedSection = $pipedSection
        Question     = $promptQuestion
    }
}

function Invoke-AskCliProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label
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

    $proc = $null
    $stdout = ""
    $stderr = ""
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        Invoke-WithSpinner -IsDone { $proc.HasExited } -OnCancel { try { $proc.Kill($true) } catch {} }

        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    }
    finally {
        if ($proc) {
            if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
            $proc.Dispose()
        }
    }

    $cyan = $global:__ansi.Cyan
    $gray = $global:__ansi.Gray
    $red = $global:__ansi.Red
    $reset = $global:__ansi.Reset

    if ($stdout) {
        Write-Host "`n${cyan}▸ ask${reset} ${gray}($Label)${reset}"
        $stdout.TrimEnd("`r", "`n") -split "`r?`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
    }
    if ($stderr) {
        Write-Host "`n${red}✖ ask error:${reset}"
        $stderr.TrimEnd("`r", "`n") -split "`r?`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host ""
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
            Write-Error "GEMINI_API_KEY environment variable is not set."
            return
        }

        if ($Choices.Count -lt 2) {
            Write-Error "Choices must contain at least 2 options."
            return
        }

        $piped = $pipeLines -join "`n"
        $qText = if ($Question) { $Question -join ' ' } else { "" }

        if ([string]::IsNullOrWhiteSpace($qText) -and [string]::IsNullOrWhiteSpace($piped)) {
            Write-Warning "Usage: decide [-Choices <a,b>] [-Instructions <text>] <question>"
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
                Write-Error "Decisions API error ($([int]$response.StatusCode) $($response.ReasonPhrase)): $body"
                return
            }
            $res = $body | ConvertFrom-Json
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
