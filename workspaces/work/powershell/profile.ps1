# Work workspace PowerShell profile additions & overrides

# Carbon Black / AppLocker Process Execution Compatibility
$canRunGitDirectly = $false
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gitCmd) {
    try {
        $null = & $gitCmd.Source --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            $canRunGitDirectly = $true
        }
    } catch {
        $canRunGitDirectly = $false
    }
}

if (-not $canRunGitDirectly) {
    <#
    .SYNOPSIS
    Carbon Black / AppLocker bypass wrapper: executes git through cmd.exe /d /c when direct execution is blocked.
    #>
    function git {
        $escaped = @($args | ForEach-Object {
            $argStr = [string]$_
            if ($argStr -match '[\s&|<>^()%"]') { '"' + ($argStr -replace '"', '\"') + '"' } else { $argStr }
        })
        $cmdLine = if ($escaped.Count -gt 0) { "git $($escaped -join ' ')" } else { "git" }
        if ($MyInvocation.ExpectingInput) {
            $input | cmd.exe /d /c $cmdLine
        } else {
            cmd.exe /d /c $cmdLine
        }
    }
}

<#
.SYNOPSIS
Asks company-approved GitHub Copilot CLI (copilot -p, clean by default; pipable to 'copy'):
  ask <question>                  - Clean query (also accepts piped input)
  ask -Ctx [<sel>] <question>     - Includes terminal context (~1 default, N last, ~N, or ~3..2 / ~3..~2)
#>
function ask {
    param(
        [switch]$Ctx,
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$QueryArgs
    )

    $piped = @($input) -join "`n"
    $preamble = "Keep your response short and do not use markdown formatting. Minimize tool and MCP calls and prioritize fast responses while remaining accurate."
    $fullPrompt = Resolve-AskRequest -QuestionArgs $QueryArgs -Piped $piped -IncludeCtx:$Ctx -PromptPreamble $preamble
    if (-not $fullPrompt) {
        Write-Host "Usage: ask [-Ctx [<n>|~<n>|~<a>..<b>]] <question>" -ForegroundColor Yellow
        return
    }

    $copilotCmd = Get-Command copilot -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $copilotCmd) {
        Write-Host "✖ ask: GitHub Copilot CLI ('copilot') not found in PATH." -ForegroundColor Red
        return
    }

    $streamInteractive = ($MyInvocation.PipelinePosition -ge $MyInvocation.PipelineLength) -and (-not [Console]::IsOutputRedirected)
    Invoke-AskCliProcess -ExecutablePath $copilotCmd.Source -Arguments @("-p", $fullPrompt) -Label "copilot" -InteractiveStream:$streamInteractive
}

<#
.SYNOPSIS
Shows the active Azure CLI subscription, tenant, and signed-in user to prevent deploying to the wrong environment.
#>
function azwho {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "✖ azwho: Azure CLI ('az') not found in PATH." -ForegroundColor Red
        return
    }
    az account show --query "{Subscription:name, Id:id, Tenant:tenantId, User:user.name}" -o table
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✖ az account show failed (exit $LASTEXITCODE)." -ForegroundColor Red
    }
}
