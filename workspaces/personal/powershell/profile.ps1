# Personal workspace PowerShell profile additions & overrides

<#
.SYNOPSIS
Asks Gemini via ephemeral streamed agy session (clean by default; pipable to 'copy'):
  ask <question>                  - Clean ephemeral query (also accepts piped input)
  ask -Ctx [<sel>] <question>     - Includes terminal context (~1 default, N last, ~N, or ~3..2 / ~3..~2)
  Flags: -Ctx (include terminal context), -High (gemini-4-hydrogen-high), -KeepHistory (persist agy session)
#>
function ask {
    param(
        [switch]$KeepHistory,
        [switch]$High,
        [switch]$Ctx,
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$QueryArgs
    )

    $piped = @($input) -join "`n"
    $preamble = "You are running in an ephemeral session via agy --print. Keep your response short and do not use markdown formatting. Minimize tool and MCP calls and prioritize fast responses while remaining accurate."
    $fullPrompt = Resolve-AskRequest -QuestionArgs $QueryArgs -Piped $piped -IncludeCtx:$Ctx -PromptPreamble $preamble
    if (-not $fullPrompt) {
        Write-Host "Usage: ask [-Ctx [<n>|~<n>|~<a>..<b>]] [-High] [-KeepHistory] <question>" -ForegroundColor Yellow
        return
    }

    $cliDir = Join-Path $env:USERPROFILE ".gemini\antigravity-cli"
    $convDir = Join-Path $cliDir "conversations"
    $brainDir = Join-Path $cliDir "brain"
    $trackSucceeded = $true
    $beforeConvs = @()
    $beforeBrain = @()
    try {
        if (Test-Path -LiteralPath $convDir) {
            $beforeConvs = @(Get-ChildItem -LiteralPath $convDir -File -Filter "*.db" -ErrorAction Stop | Select-Object -ExpandProperty BaseName)
        }
        if (Test-Path -LiteralPath $brainDir) {
            $beforeBrain = @(Get-ChildItem -LiteralPath $brainDir -Directory -ErrorAction Stop | Select-Object -ExpandProperty Name)
        }
    } catch {
        $trackSucceeded = $false
    }

    $model = if ($High) { "gemini-4-hydrogen-high" } else { "gemini-4-hydrogen-low" }
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $agyCmd) {
        Write-Host "✖ ask: Antigravity CLI ('agy') not found in PATH." -ForegroundColor Red
        return
    }

    $streamInteractive = ($MyInvocation.PipelinePosition -ge $MyInvocation.PipelineLength) -and (-not [Console]::IsOutputRedirected)
    Invoke-AskCliProcess -ExecutablePath $agyCmd.Source -Arguments @("--model", $model, "--output-format", "stream-json", "-p", $fullPrompt) -Label $model -StreamJson -InteractiveStream:$streamInteractive

    if (-not $KeepHistory -and ($trackSucceeded -or $script:__ask_last_conv_id)) {
        Start-Sleep -Milliseconds 200
        $newIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($script:__ask_last_conv_id) { [void]$newIds.Add($script:__ask_last_conv_id) }

        if ($trackSucceeded) {
            if (Test-Path -LiteralPath $convDir) {
                Get-ChildItem -LiteralPath $convDir -File -Filter "*.db" -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -notin $beforeConvs } |
                    ForEach-Object { [void]$newIds.Add($_.BaseName) }
            }
            if (Test-Path -LiteralPath $brainDir) {
                Get-ChildItem -LiteralPath $brainDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin $beforeBrain } |
                    ForEach-Object { [void]$newIds.Add($_.Name) }
            }
        }

        foreach ($id in $newIds) {
            Remove-Item -Path (Join-Path $convDir "$id.db*") -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $brainDir $id) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path $cliDir "annotations\$id.*") -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path $cliDir "implicit\$id.*") -Force -ErrorAction SilentlyContinue
        }

        $summariesDb = Join-Path $cliDir "conversation_summaries.db"
        if ($newIds.Count -gt 0 -and (Test-Path -LiteralPath $summariesDb) -and (Get-Command python -ErrorAction SilentlyContinue)) {
            $pyScript = @'
import sqlite3, sys
db_path = sys.argv[1]
ids = sys.argv[2:]
con = sqlite3.connect(db_path, timeout=2.0)
try:
    for cid in ids:
        for tbl in ("conversation_summaries", "conversations_fts", "conversation_parents"):
            try:
                con.execute(f"DELETE FROM {tbl} WHERE conversation_id = ?", (cid,))
            except sqlite3.Error:
                pass
    con.commit()
finally:
    con.close()
'@
            $pyScript | & python - $summariesDb @($newIds) 2>$null
        }
    }
}
