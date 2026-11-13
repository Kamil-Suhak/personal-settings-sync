#region 3. Navigation & Project Switcher

<#
.SYNOPSIS
Go up 1 directory level (Set-Location ..).
#>
function .. { Set-Location .. }

<#
.SYNOPSIS
Go up 2 directory levels (Set-Location ../..).
#>
function ... { Set-Location ../.. }

<#
.SYNOPSIS
Go up 3 directory levels (Set-Location ../../..).
#>
function .... { Set-Location ../../.. }

<#
.SYNOPSIS
Universal Project Jumper: searches roots in %LOCALAPPDATA%\PersonalSettingsSync\project-roots and jumps to a matching project directory. Supports -add, -remove, and -list.
#>
function p {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Target,
        [Alias("a")][switch]$Add,
        [Alias("r", "rm")][switch]$Remove,
        [Alias("l")][switch]$List
    )

    $rootsFile = $global:__pss_state.ProjectRoots

    # Load configured machine-local project roots
    $roots = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $rootsFile) {
        Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and (Test-Path -LiteralPath $line)) {
                $roots.Add($line)
            }
        }
    }

    # 1. List configured roots (p -l or p list)
    if ($List -or $Name -eq 'list') {
        Write-Host "`nConfigured project roots ($rootsFile):" -ForegroundColor Cyan
        if ($roots.Count -eq 0) {
            Write-Host "  No roots found. Use 'p -a <path>' to register one." -ForegroundColor Yellow
        }
        else {
            $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor Green }
        }
        Write-Host ""
        return
    }

    # 2. Add new project root (p -a [<path>] or p add [<path>])
    if ($Add -or $Name -eq 'add') {
        $candidatePath = if ($Name -eq 'add') { $Target } elseif ($Target) { $Target } else { $Name }
        if (-not $candidatePath) {
            $candidatePath = Read-Host "Enter directory path to add to project roots (press Enter for current folder: $pwd)"
            if (-not $candidatePath) { $candidatePath = $pwd.Path }
        }
        $resolved = Resolve-Path -LiteralPath $candidatePath -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Host "Directory not found: $candidatePath" -ForegroundColor Red
            return
        }
        $existing = if (Test-Path -LiteralPath $rootsFile) { @(Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue) } else { @() }
        if ($existing -notcontains $resolved.Path) {
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $rootsFile))
            Add-Content -LiteralPath $rootsFile -Value $resolved.Path
            Write-Host "Added '$($resolved.Path)' to $rootsFile" -ForegroundColor Green
        }
        else {
            Write-Host "'$($resolved.Path)' is already in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 3. Remove project root (p -r [<path>|<index>] or p rm [<path>|<index>])
    if ($Remove -or ($Name -in @('remove', 'rm'))) {
        if (-not (Test-Path -LiteralPath $rootsFile)) {
            Write-Host "`nNo project roots file found ($rootsFile)." -ForegroundColor Yellow
            return
        }

        $lines = @(Get-Content -LiteralPath $rootsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
        if ($lines.Count -eq 0) {
            Write-Host "`nNo project roots configured in $rootsFile." -ForegroundColor Yellow
            return
        }

        $targetToRemove = if ($Name -in @('remove', 'rm')) { $Target } elseif ($Target) { $Target } else { $Name }

        if (-not $targetToRemove) {
            Write-Host "`nConfigured project roots ($rootsFile):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $lines.Count; $i++) {
                Write-Host "  [$($i + 1)] $($lines[$i])" -ForegroundColor Green
            }
            Write-Host ""
            $reply = Read-Host "Enter number or path to remove (press Enter to cancel)"
            if (-not $reply) {
                Write-Host "Canceled." -ForegroundColor DarkGray
                return
            }
            $targetToRemove = $reply.Trim()
        }

        # Check if user entered a number index (1-based)
        $match = $null
        $intIndex = 0
        if ([int]::TryParse($targetToRemove, [ref]$intIndex) -and $intIndex -ge 1 -and $intIndex -le $lines.Count) {
            $match = $lines[$intIndex - 1]
        }
        else {
            # Normalize targetToRemove to check for match
            $resolved = Resolve-Path -LiteralPath $targetToRemove -ErrorAction SilentlyContinue
            $resolvedPath = if ($resolved) { $resolved.Path } else { $targetToRemove }

            $matchedLines = @($lines | Where-Object {
                    $_ -eq $targetToRemove -or
                    $_ -eq $resolvedPath -or
                    (Split-Path $_ -Leaf) -eq $targetToRemove
                })

            if ($matchedLines.Count -eq 1) {
                $match = $matchedLines[0]
            }
            elseif ($matchedLines.Count -gt 1) {
                Write-Host "Multiple roots matched '$targetToRemove':" -ForegroundColor Yellow
                $matchedLines | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
                Write-Host "Please specify the full path." -ForegroundColor Cyan
                return
            }
        }

        if ($match) {
            $remaining = @($lines | Where-Object { $_ -ne $match })
            if ($remaining.Count -gt 0) {
                Set-Content -LiteralPath $rootsFile -Value $remaining
            }
            else {
                Clear-Content -LiteralPath $rootsFile
            }
            Write-Host "Removed '$match' from $rootsFile" -ForegroundColor Green
        }
        else {
            Write-Host "Root '$targetToRemove' not found in $rootsFile" -ForegroundColor Yellow
        }
        return
    }

    # 4. Fail cleanly if no project roots are configured
    if ($roots.Count -eq 0) {
        Write-Error "No project roots configured in $rootsFile. Use 'p -add <path>' first."
        return
    }

    # 5. If invoked without arguments, show roots and usage
    if (-not $Name) {
        Write-Host "`nConfigured project roots:" -ForegroundColor Cyan
        $roots | ForEach-Object { Write-Host "  • $_" -ForegroundColor DarkGray }
        Write-Host "Usage: p <name> | p -add [<path>] | p -remove [<path>] | p -list`n" -ForegroundColor DarkCyan
        return
    }

    # 6. Search directories across all configured roots
    $matchedDir = $roots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$Name*" }
    } | Select-Object -First 1

    if ($matchedDir) {
        Set-Location -LiteralPath $matchedDir.FullName
    }
    else {
        Write-Host "Project matching '$Name' not found in:" -ForegroundColor Yellow
        $roots | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
        Write-Host "Tip: Use 'p -add <path>' to register additional project directories." -ForegroundColor DarkCyan
    }
}

<#
.SYNOPSIS
Opens Windows File Explorer at the specified path (defaults to current folder).
#>
function rev {
    param([string]$Path = ".")
    try {
        explorer.exe (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    catch {
        Write-Error "Path not found: $Path"
    }
}

# Directory history state for 'back' command
$global:__current_location = $pwd.Path
$global:__prev_location = $null

<#
.SYNOPSIS
Jumps back to the previous working directory (toggles between current and previous location).
#>
function back {
    if (-not $global:__prev_location -or -not (Test-Path -LiteralPath $global:__prev_location)) {
        Write-Host "No previous directory recorded." -ForegroundColor Yellow
        return
    }
    $target = $global:__prev_location
    Set-Location -LiteralPath $target
}
#endregion
