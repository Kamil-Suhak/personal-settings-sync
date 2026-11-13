<#
.SYNOPSIS
Helper function that recursively enumerates files excluding common junk directories and specified extensions.
#>
function Get-SearchableFiles {
    param(
        [string]$Path = ".",
        [string[]]$ExcludeDirs = @('.git', 'node_modules', 'bin', 'obj', 'target', '.vs', 'dist', 'build', '.venv', '__pycache__', '.backups'),
        [string[]]$ExcludeExtensions = @()
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { return @() }

    $rootItem = Get-Item -LiteralPath $resolved.Path -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return @() }
    if (-not $rootItem.PSIsContainer) { return @($rootItem) }

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludeDirs, [System.StringComparer]::OrdinalIgnoreCase)
    $extSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludeExtensions, [System.StringComparer]::OrdinalIgnoreCase)

    $results = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $queue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    $queue.Enqueue($rootItem)

    while ($queue.Count -gt 0) {
        $currentDir = $queue.Dequeue()
        try {
            foreach ($subDir in $currentDir.EnumerateDirectories()) {
                if (-not $excludeSet.Contains($subDir.Name)) {
                    $queue.Enqueue($subDir)
                }
            }
            foreach ($file in $currentDir.EnumerateFiles()) {
                if ($extSet.Count -eq 0 -or -not $extSet.Contains($file.Extension)) {
                    $results.Add($file)
                }
            }
        }
        catch {}
    }
    return $results
}

function Get-ClipboardShortQuery {
    param([int]$MaxLength = 200)

    $raw = Get-Clipboard -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $trimmed = $raw.Trim()
    if ($trimmed.Length -gt $MaxLength -or $trimmed -match '[\r\n]') {
        Write-Host "Clipboard text is multi-line or >$MaxLength chars; skipped auto-query." -ForegroundColor DarkGray
        return $null
    }

    return $trimmed
}

<#
.SYNOPSIS
Interactive fuzzy file finder. Accepts argument, piped query, or short single-line clipboard text; copies selected path to clipboard and optionally opens in VS Code (-o).
#>
function find {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject,
        [Alias("o")]
        [switch]$Open
    )

    begin {
        $pipedParts = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $s = $InputObject.ToString().Trim()
            if ($s) { [void]$pipedParts.Add($s) }
        }
    }

    end {
        if (-not $Name) {
            if ($pipedParts.Count -gt 0) {
                $Name = $pipedParts[0]
            }
            else {
                $Name = Get-ClipboardShortQuery
                if ($Name) {
                    Write-Host "Searching clipboard filename query: '$Name'" -ForegroundColor DarkGray
                }
            }
        }

        if (-not $Name) {
            Write-Host "Usage: find <name> [<path>] [-o]  (or copy a short filename to clipboard)" -ForegroundColor Yellow
            return
        }

        $cleanedTokens = $Name -split '[\s-_.]+' | Where-Object { $_ }
        $regexPattern = ($cleanedTokens | ForEach-Object { [regex]::Escape($_) }) -join '.?'
        $nameRegex = [regex]::new($regexPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $isGitRepo = (& git rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        $foundFiles = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($isGitRepo) {
            $gitRoot = (& git rev-parse --show-toplevel 2>$null)
            $gitArgs = @('ls-files', '--cached', '--others', '--exclude-standard')
            if ($Path -and $Path -ne '.') { $gitArgs += $Path }
            $trackedFiles = & git @gitArgs 2>$null

            if ($trackedFiles) {
                foreach ($relFile in $trackedFiles) {
                    $fileName = Split-Path $relFile -Leaf
                    if ($nameRegex.IsMatch($fileName)) {
                        $fullPath = if ($gitRoot) { Join-Path $gitRoot $relFile } else { (Resolve-Path $relFile -ErrorAction SilentlyContinue).Path }
                        $dirName = Split-Path $fullPath -Parent
                        $foundFiles.Add([PSCustomObject]@{
                                FullName      = $fullPath
                                Name          = $fileName
                                DirectoryName = $dirName
                            })
                    }
                }
            }
        }

        if (-not $isGitRepo -or $foundFiles.Count -eq 0) {
            if (-not $isGitRepo) {
                Get-SearchableFiles -Path $Path |
                Where-Object { $nameRegex.IsMatch($_.Name) } |
                ForEach-Object {
                    $foundFiles.Add([PSCustomObject]@{
                            FullName      = $_.FullName
                            Name          = $_.Name
                            DirectoryName = $_.DirectoryName
                        })
                }
            }
        }

        if ($foundFiles.Count -eq 0) {
            Write-Host "No files found matching '$Name'." -ForegroundColor Yellow
            return
        }

        Write-Host "`nFound $($foundFiles.Count) match$(if ($foundFiles.Count -ne 1) {'es'} else {''}):" -ForegroundColor Cyan
        Write-Host ("-" * 60) -ForegroundColor DarkGray
        $padLen = $foundFiles.Count.ToString().Length

        for ($i = 0; $i -lt $foundFiles.Count; $i++) {
            $numStr = ($i + 1).ToString().PadLeft($padLen)
            $file = $foundFiles[$i]
            Write-Host " [$numStr] " -NoNewline -ForegroundColor DarkCyan
            Write-Host $file.Name.PadRight(35) -NoNewline -ForegroundColor White
            Write-Host " $($file.DirectoryName)" -ForegroundColor DarkGray
        }
        Write-Host ("-" * 60) -ForegroundColor DarkGray

        if ($foundFiles.Count -eq 1) {
            Set-Clipboard -Value $foundFiles[0].FullName
            Write-Host "Copied to clipboard: $($foundFiles[0].FullName)" -ForegroundColor Green
            if ($Open) {
                code $foundFiles[0].FullName
                Write-Host "Opened in VS Code." -ForegroundColor Cyan
            }
            return
        }

        Write-Host (" " * ($padLen + 2) + "[0] Cancel / None") -ForegroundColor DarkYellow
        $actionVerb = if ($Open) { "open in VS Code" } else { "copy" }
        $choice = Read-Host "`nEnter selection to $actionVerb (1-$($foundFiles.Count), or Enter to cancel)"

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $foundFiles.Count) {
            $selectedPath = $foundFiles[[int]$choice - 1].FullName
            Set-Clipboard -Value $selectedPath
            Write-Host "Copied to clipboard: $selectedPath" -ForegroundColor Green
            if ($Open) {
                code $selectedPath
                Write-Host "Opened in VS Code." -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "Action cancelled. Nothing copied." -ForegroundColor DarkGray
        }
    }
}

<#
.SYNOPSIS
Dual-mode text finder. Filters piped input or searches codebase files recursively while auto-skipping junk directories and binary files.
#>
function findstr {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Pattern,
        [Parameter(Position = 1)]
        [string]$Path = ".",
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject,
        [Alias("v")]
        [switch]$Invert,
        [Alias("c")]
        [switch]$CaseSensitive,
        [Alias("l")]
        [switch]$FilesOnly
    )

    begin {
        if (-not $Pattern) {
            $Pattern = Get-ClipboardShortQuery
            if ($Pattern) {
                Write-Host "Searching clipboard pattern: '$Pattern'" -ForegroundColor DarkGray
            }
        }

        $hasValidPattern = [bool]$Pattern
        $isPiped = $PSCmdlet.MyInvocation.ExpectingInput
        if (-not $hasValidPattern) {
            Write-Host "Usage: findstr <pattern> [<path>] [-v] [-c] [-l]  (or copy a short single-line pattern to clipboard)" -ForegroundColor Yellow
            return
        }

        $regexOptions = if ($CaseSensitive) {
            [System.Text.RegularExpressions.RegexOptions]::None
        }
        else {
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        }

        try {
            $regex = [regex]::new($Pattern, $regexOptions)
        }
        catch {
            $regex = [regex]::new([regex]::Escape($Pattern), $regexOptions)
        }
    }

    process {
        if ($hasValidPattern -and $isPiped -and $null -ne $InputObject) {
            $line = $InputObject.ToString()
            $matched = $regex.IsMatch($line)
            if (($matched -and -not $Invert) -or (-not $matched -and $Invert)) {
                $line
            }
        }
    }

    end {
        if ($isPiped -or -not $hasValidPattern) { return }

        $cyan = $global:__ansi.Cyan
        $yellow = $global:__ansi.Yellow
        $reset = $global:__ansi.Reset

        # 1. Fast Git acceleration inside a Git repository (monolith indexing)
        $isGitRepo = (& git rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        if ($isGitRepo) {
            $grepArgs = @('grep', '-n', '-I', '--color=never')
            if (-not $CaseSensitive) { $grepArgs += '-i' }
            if ($Invert) { $grepArgs += '-v' }
            if ($FilesOnly) { $grepArgs += '-l' }
            $grepArgs += @('-e', $Pattern)
            if ($Path -and $Path -ne '.') { $grepArgs += @('--', $Path) }

            $results = & git @grepArgs 2>$null
            if ($results) {
                if ($FilesOnly) {
                    foreach ($line in $results) {
                        "${cyan}${line}${reset}"
                    }
                }
                else {
                    foreach ($line in $results) {
                        if ($line -match '^([^:]+):(\d+):(.*)$') {
                            "${cyan}$($matches[1])${reset}:${yellow}$($matches[2])${reset}: $($matches[3])"
                        }
                        else {
                            $line
                        }
                    }
                }
            }
            return
        }

        # 2. Pure PowerShell fallback outside Git repositories
        $binaryExts = @('.exe', '.dll', '.pdb', '.zip', '.tar', '.gz', '.7z', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.woff', '.woff2', '.ttf')
        $currentDir = (Get-Location).Path.TrimEnd('\', '/')

        $files = Get-SearchableFiles -Path $Path -ExcludeExtensions $binaryExts
        $matchingFiles = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($file in $files) {
            $relPath = $file.FullName
            if ($relPath.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relPath = $relPath.Substring($currentDir.Length).TrimStart('\', '/')
            }

            try {
                $lines = [System.IO.File]::ReadLines($file.FullName)
            }
            catch { continue }

            $lineNum = 0
            $fileHasMatch = $false

            foreach ($line in $lines) {
                $lineNum++
                $matched = $regex.IsMatch($line)

                if ($matched -and -not $Invert) {
                    $fileHasMatch = $true
                    if ($FilesOnly) {
                        if ($matchingFiles.Add($relPath)) {
                            "${cyan}${relPath}${reset}"
                        }
                        break
                    }
                    else {
                        "${cyan}${relPath}${reset}:${yellow}${lineNum}${reset}: $line"
                    }
                }
            }

            if ($Invert -and -not $fileHasMatch) {
                "${cyan}${relPath}${reset}"
            }
        }
    }
}
