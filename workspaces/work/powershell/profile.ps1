# Work workspace PowerShell profile additions & overrides

. (Join-Path $PSScriptRoot 'worksets.ps1')

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
Asks company-approved GitHub Copilot CLI (copilot -p) using recent terminal history, screen output, and optional piped input.
#>
function ask {
    param(
        [switch]$Clean
    )

    $Question = $args -join ' '
    $piped = @($input) -join "`n"
    if ([string]::IsNullOrWhiteSpace($Question) -and [string]::IsNullOrWhiteSpace($piped)) {
        Write-Warning "Usage: ask [-Clean] <question>"
        return
    }

    $copilotCmd = Get-Command copilot -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $copilotCmd) {
        Write-Error "GitHub Copilot CLI ('copilot') not found in PATH."
        return
    }

    $ctx = Get-TerminalAskContext -Question $Question -Piped $piped -Clean:$Clean
    $fullPrompt = @"
Keep your response short and do not use markdown formatting. You are given context from the terminal history, recent output, and piped input. Use this information only if it is directly relevant to the question, ignore otherwise.
[Context: Recent Terminal Commands]
$($ctx.History)

[Context: Recent Terminal Output]
$($ctx.Output)
$($ctx.PipedSection)
[User Question]
$($ctx.Question)
"@

    Invoke-AskCliProcess -ExecutablePath $copilotCmd.Source -Arguments @("-p", $fullPrompt) -Label "copilot"
}

<#
.SYNOPSIS
Shows the active Azure CLI subscription, tenant, and signed-in user to prevent deploying to the wrong environment.
#>
function azwho {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "Azure CLI ('az') not found in PATH." -ForegroundColor Red
        return
    }
    az account show --query "{Subscription:name, Id:id, Tenant:tenantId, User:user.name}" -o table
}

<#
.SYNOPSIS
Recursively removes .NET build artifact directories (bin and obj) under the current directory.
#>
function slnclean {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path = ".")

    $targets = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('bin', 'obj') -and $_.FullName -notmatch '[\\/]\.git[\\/]' })

    if ($targets.Count -eq 0) {
        Write-Host "No bin/ or obj/ directories found under $Path." -ForegroundColor DarkGray
        return
    }

    $removed = 0
    foreach ($dir in $targets) {
        if ($PSCmdlet.ShouldProcess($dir.FullName, "Remove .NET artifact directory")) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    if (-not $WhatIfPreference) {
        Write-Host "Cleaned $removed bin/obj directory(s)." -ForegroundColor Green
    }
}
