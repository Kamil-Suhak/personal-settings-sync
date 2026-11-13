function Get-VsSolutions {
    param([string]$StartDirectory, [int]$MaxDepth = 5)
    $currentDir = $StartDirectory
    for ($depth = 0; $depth -le $MaxDepth -and $currentDir; $depth++) {
        $found = @(Get-ChildItem -LiteralPath $currentDir -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.sln', '.slnx') } |
            Sort-Object Name)
        if ($found.Count -gt 0) { return $found }
        $parent = Split-Path -Parent $currentDir
        if (-not $parent -or $parent -eq $currentDir) { break }
        $currentDir = $parent
    }
}

<#
.SYNOPSIS
Opens Visual Studio for a .sln/.slnx found in the target/current directory or up to MaxDepth parent levels. Supports passing a file path to open alongside the solution.
#>
function vs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [string]$Path = ".",
        [ValidateRange(0, 20)]
        [int]$MaxDepth = 5,
        [string[]]$Files
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Path not found: $Path"
        return
    }

    $item = Get-Item -LiteralPath $Path
    $selectedSolution = $null
    $targetFile = $null
    $searchStartDir = $null
    $targetFiles = @()
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-Error "File not found: $file"
            return
        }
        $targetFiles += (Get-Item -LiteralPath $file).FullName
    }

    if (-not $item.PSIsContainer -and $item.Extension -in @('.sln', '.slnx')) {
        $selectedSolution = $item
    }
    else {
        if ($item.PSIsContainer) {
            $searchStartDir = $item.FullName
        }
        else {
            $searchStartDir = $item.DirectoryName
            $targetFile = $item.FullName
        }

        $solutions = @(Get-VsSolutions -StartDirectory $searchStartDir -MaxDepth $MaxDepth)

        if ($solutions.Count -eq 0) {
            Write-Error "No .sln or .slnx file found in '$searchStartDir' or within $MaxDepth parent level(s)."
            return
        }
        elseif ($solutions.Count -eq 1) {
            $selectedSolution = $solutions[0]
        }
        else {
            Write-Host "`nMultiple solutions found in '$($solutions[0].DirectoryName)':" -ForegroundColor Cyan
            for ($i = 0; $i -lt $solutions.Count; $i++) {
                Write-Host "  [$($i + 1)] $($solutions[$i].Name)" -ForegroundColor Green
            }
            $reply = Read-Host "Select solution [1-$($solutions.Count)] (Enter for 1)"
            if ([string]::IsNullOrWhiteSpace($reply)) {
                $selectedSolution = $solutions[0]
            }
            else {
                $idx = 0
                if ([int]::TryParse($reply.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $solutions.Count) {
                    $selectedSolution = $solutions[$idx - 1]
                }
                else {
                    Write-Host "Canceled." -ForegroundColor DarkGray
                    return
                }
            }
        }
    }

    if ($targetFile) { $targetFiles = @($targetFile) + $targetFiles }
    $targetFiles = @($targetFiles | Select-Object -Unique)
    $devenvPath = if ($global:__devenv_path -and (Test-Path -LiteralPath $global:__devenv_path)) {
        $global:__devenv_path
    }
    else {
        $vswhere = Join-Path "${env:ProgramFiles(x86)}" "Microsoft Visual Studio\Installer\vswhere.exe"
        $vswhereHit = if (Test-Path -LiteralPath $vswhere) {
            (& $vswhere -latest -prerelease -products * -property productPath 2>$null | Select-Object -First 1)
        }
        else { $null }

        $candidates = @(
            (Get-Command devenv.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            $vswhereHit,
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\devenv.exe' -ErrorAction SilentlyContinue).'(default)')
        )
        $hit = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($hit) { $global:__devenv_path = $hit }
        $hit
    }

    $actionDesc = if ($targetFiles.Count) {
        "Open '$($selectedSolution.FullName)' and '$($targetFiles -join "', '")'"
    }
    else {
        "Open '$($selectedSolution.FullName)'"
    }

    Write-Verbose $actionDesc
    if (-not $PSCmdlet.ShouldProcess($selectedSolution.FullName, $actionDesc)) {
        return
    }

    if ($devenvPath) {
        $rawArgs = @($selectedSolution.FullName)
        $rawArgs += $targetFiles
        $quotedArgs = @($rawArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
        Start-Process -FilePath $devenvPath -ArgumentList $quotedArgs
    }
    else {
        if ($Files.Count) {
            Write-Error "devenv.exe not found; cannot open the selected files."
            return
        }
        if ($targetFile) {
            Write-Warning "devenv.exe not found in PATH or Visual Studio Installer; opening solution without '$targetFile'."
        }
        Start-Process -FilePath $selectedSolution.FullName
    }
}
