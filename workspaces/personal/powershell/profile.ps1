# Personal workspace PowerShell profile additions & overrides

<#
.SYNOPSIS
Launches Brave Browser with optional arguments (URLs, flags, incognito, profiles). Supports piped URLs.
#>
function brave {
    $bravePath = if ($global:__brave_path -and (Test-Path -LiteralPath $global:__brave_path)) {
        $global:__brave_path
    } else {
        $candidates = @(
            (Get-Command brave.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe' -ErrorAction SilentlyContinue).'(default)'),
            ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe' -ErrorAction SilentlyContinue).'(default)'),
            "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
        $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($found) { $global:__brave_path = $found }
        $found
    }

    if (-not $bravePath) {
        Write-Host "Brave Browser executable not found. Install it via 'winget install Brave.Brave' or 'pss apps install'." -ForegroundColor Red
        return
    }

    $passedArgs = [System.Collections.Generic.List[string]]::new()
    if ($args) {
        foreach ($a in $args) { $passedArgs.Add([string]$a) }
    }
    if ($null -ne $input) {
        foreach ($item in $input) {
            if ($null -ne $item -and [string]$item -match '\S') {
                $passedArgs.Add([string]$item)
            }
        }
    }

    if ($passedArgs.Count -gt 0) {
        Start-Process -FilePath $bravePath -ArgumentList $passedArgs
    } else {
        Start-Process -FilePath $bravePath
    }
}

function Invoke-PassboltCompose {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Verb,
        [string[]]$ExtraArgs
    )

    $passboltDir = Join-Path $HOME "passbolt"
    if (-not (Test-Path -LiteralPath $passboltDir)) {
        Write-Host "Passbolt directory not found at: $passboltDir" -ForegroundColor Red
        return
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $dockerBin = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin"
        if (Test-Path -LiteralPath "$dockerBin\docker.exe") {
            $env:Path = "$dockerBin;$env:Path"
        } else {
            Write-Host "Docker command not found in PATH." -ForegroundColor Red
            return
        }
    }

    Push-Location $passboltDir
    try {
        Write-Host "Running Passbolt (docker compose $Verb)..." -ForegroundColor Cyan
        docker compose $Verb @ExtraArgs
    } finally {
        Pop-Location
    }
}

<#
.SYNOPSIS
Starts the Passbolt password manager via Docker Compose (in ~/passbolt).
#>
function passbolt { Invoke-PassboltCompose -Verb "start" -ExtraArgs $args }

<#
.SYNOPSIS
Stops the Passbolt password manager via Docker Compose (in ~/passbolt).
#>
function passbolt-stop { Invoke-PassboltCompose -Verb "stop" -ExtraArgs $args }

<#
.SYNOPSIS
Asks Gemini via ephemeral agy -p session using recent terminal history, screen output, and optional piped input.
#>
function ask {
    param(
        [switch]$KeepHistory,
        [switch]$High,
        [switch]$Clean
    )

    $Question = $args -join ' '
    $piped = @($input) -join "`n"
    if ([string]::IsNullOrWhiteSpace($Question) -and [string]::IsNullOrWhiteSpace($piped)) {
        Write-Warning "Usage: ask [-KeepHistory] [-High] [-Clean] <question>"
        return
    }

    $ctx = Get-TerminalAskContext -Question $Question -Piped $piped -Clean:$Clean
    $fullPrompt = @"
You are running in an ephemeral session via agy --print. Keep your response short and do not use markdown formatting. You are given context from the terminal history, recent output, and piped input. Use this information only if it is directly relevant to the question, ignore otherwise.
[Context: Recent Terminal Commands]
$($ctx.History)

[Context: Recent Terminal Output]
$($ctx.Output)
$($ctx.PipedSection)
[User Question]
$($ctx.Question)
"@

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

    $model = if ($High) { "gemini-3.8-flash-high" } else { "gemini-3.8-flash-medium" }
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $agyCmd) {
        Write-Error "Antigravity CLI ('agy') not found in PATH."
        return
    }

    Invoke-AskCliProcess -ExecutablePath $agyCmd.Source -Arguments @("--model", $model, "-p", $fullPrompt) -Label $model

    if (-not $KeepHistory -and $trackSucceeded) {
        Start-Sleep -Milliseconds 200
        $newIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

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
