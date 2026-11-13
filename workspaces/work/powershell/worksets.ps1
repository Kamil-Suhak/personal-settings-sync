function Get-WorksetContext {
    param([string]$Directory = (Get-Location).Path)
    $root = @(& git -C $Directory rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) { return $null }
    $branch = @(& git -C $Directory symbolic-ref --quiet --short HEAD 2>$null)
    return [PSCustomObject]@{
        Root = [System.IO.Path]::GetFullPath($root[0])
        Branch = if ($LASTEXITCODE -eq 0 -and $branch) { $branch[0] } else { $null }
    }
}

function ConvertTo-WorksetName {
    param([Parameter(Mandatory)][string]$Name)
    $normalized = ($Name.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-' -replace '-+', '-').Trim(' ', '.', '-')
    if (-not $normalized -or $normalized.Length -gt 100 -or
        $normalized -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)') {
        throw "Invalid workset name '$Name'; choose a name of at most 100 characters."
    }
    return $normalized
}

function Get-WorksetDirectory {
    param([string]$Name, [switch]$Archived)
    $location = if ($Archived) { 'archived' } else { 'active' }
    return Join-Path $global:__pss_state.Root "worksets\work\$location\$(ConvertTo-WorksetName $Name)"
}

function Resolve-WorksetDirectory {
    param([string]$Name, [switch]$Archived)
    if ($Name) {
        $directory = Get-WorksetDirectory -Name $Name -Archived:$Archived
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Workset '$Name' not found." }
        return $directory
    }
    $context = Get-WorksetContext
    if (-not $context -or -not $context.Branch) { throw 'Specify a workset name outside a repository or on detached HEAD.' }
    $location = if ($Archived) { 'archived' } else { 'active' }
    $parent = Join-Path $global:__pss_state.Root "worksets\work\$location"
    $matches = @()
    if (Test-Path -LiteralPath $parent) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $parent -Directory)) {
            $metadataPath = Join-Path $directory.FullName 'metadata.json'
            if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "Missing metadata: $metadataPath" }
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($metadata.originRoot -eq $context.Root -and $metadata.branch -ceq $context.Branch) { $matches += $directory.FullName }
        }
    }
    if ($matches.Count -ne 1) { throw "Expected one workset for '$($context.Root)' on '$($context.Branch)'; found $($matches.Count). Specify a name." }
    return $matches[0]
}

function Get-WorksetFiles {
    param([Parameter(Mandatory)][string]$Directory)
    $file = Join-Path $Directory 'files.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Workset file list is missing: $file" }
    $files = @()
    foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction Stop)) {
        $path = $line.Trim()
        if (-not $path -or $path.StartsWith('#')) { continue }
        if (-not [System.IO.Path]::IsPathFullyQualified($path)) { throw "Workset paths must be absolute: $path" }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workset file not found: $path" }
        $resolved = (Get-Item -LiteralPath $path -ErrorAction Stop).FullName
        if ($files -notcontains $resolved) { $files += $resolved }
    }
    return $files
}

<#
.SYNOPSIS
Creates and opens named issue file sets across repositories.
#>
function workset {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)][ValidateSet('new', 'add', 'edit', 'show', 'list', 'open', 'archive', 'restore', 'delete')]
        [string]$Action = 'list',
        [Parameter(Position = 1)][string]$Item,
        [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$Paths,
        [switch]$Code,
        [switch]$Vs,
        [switch]$Archived
    )
    if ($Code -and $Vs) { throw 'Choose either -Code or -Vs.' }
    if (($Code -or $Vs) -and $Action -ne 'open') { throw '-Code and -Vs are only valid for open.' }
    if ($Archived -and $Action -notin @('list', 'show', 'delete')) { throw '-Archived is only valid for list, show, or delete.' }
    if ($Action -ne 'add' -and $Paths.Count) { throw "Unexpected arguments: $($Paths -join ', ')" }

    switch ($Action) {
        'new' {
            $context = Get-WorksetContext
            if (-not $Item) {
                if (-not $context -or -not $context.Branch) { throw 'A name is required outside a repository or on detached HEAD.' }
                $Item = $context.Branch
            }
            $name = ConvertTo-WorksetName $Item
            $directory = Get-WorksetDirectory $name
            $archivedDir = Get-WorksetDirectory $name -Archived
            if ((Test-Path -LiteralPath $directory) -or (Test-Path -LiteralPath $archivedDir)) { throw "Workset '$name' already exists, including archived worksets." }
            if ($PSCmdlet.ShouldProcess($name, 'Create workset')) {
                $parent = Split-Path -Parent $directory
                [void][System.IO.Directory]::CreateDirectory($parent)
                $staging = Join-Path $parent ('.new-' + [guid]::NewGuid().ToString('N'))
                try {
                    [void][System.IO.Directory]::CreateDirectory($staging)
                    $metadata = [ordered]@{
                        name = $name
                        originRoot = if ($context) { $context.Root } else { $null }
                        branch = if ($context) { $context.Branch } else { $null }
                        repositories = @()
                    }
                    [System.IO.File]::WriteAllText((Join-Path $staging 'metadata.json'), ($metadata | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
                    [System.IO.File]::WriteAllText((Join-Path $staging 'files.txt'), '', [System.Text.UTF8Encoding]::new($false))
                    [System.IO.Directory]::Move($staging, $directory)
                } finally {
                    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
                }
                Write-Host "Created workset '$name'."
            }
        }
        'list' {
            $location = if ($Archived) { 'archived' } else { 'active' }
            $parent = Join-Path $global:__pss_state.Root "worksets\work\$location"
            if (Test-Path -LiteralPath $parent) { Get-ChildItem -LiteralPath $parent -Directory | Select-Object -ExpandProperty Name }
        }
        'add' {
            if (-not $Item) { throw 'Usage: workset add [name] <file> [file...]' }
            if ($Paths.Count) { $name = $Item; $inputs = $Paths } else { $name = $null; $inputs = @($Item) }
            $directory = Resolve-WorksetDirectory $name
            $listPath = Join-Path $directory 'files.txt'
            $metadataPath = Join-Path $directory 'metadata.json'
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $existing = @(Get-Content -LiteralPath $listPath -ErrorAction Stop)
            $added = @()
            $repositories = @($metadata.repositories)
            foreach ($path in $inputs) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
                $fullPath = (Get-Item -LiteralPath $path -ErrorAction Stop).FullName
                if ($existing -notcontains $fullPath -and $added -notcontains $fullPath) { $added += $fullPath }
                $context = Get-WorksetContext (Split-Path -Parent $fullPath)
                if ($context -and $context.Branch -and @($repositories | Where-Object { $_.root -eq $context.Root }).Count -eq 0) {
                    $repositories += [PSCustomObject]@{ root = $context.Root; branch = $context.Branch }
                }
            }
            if ($added.Count -and $PSCmdlet.ShouldProcess($directory, "Add $($added.Count) file(s)")) {
                $metadata.repositories = $repositories
                $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding utf8 -ErrorAction Stop
                Add-Content -LiteralPath $listPath -Value $added -Encoding utf8 -ErrorAction Stop
                Write-Host "Added $($added.Count) file(s) to '$($metadata.name)'."
            }
        }
        'edit' {
            $directory = Resolve-WorksetDirectory $Item
            if (-not (Get-Command code -ErrorAction SilentlyContinue)) { throw 'VS Code command not found in PATH.' }
            & code --wait (Join-Path $directory 'files.txt')
            if ($LASTEXITCODE -ne 0) { throw "VS Code exited with code $LASTEXITCODE." }
        }
        'show' {
            $directory = Resolve-WorksetDirectory $Item -Archived:$Archived
            Write-Host "Workset: $(Split-Path -Leaf $directory)"
            Get-Content -LiteralPath (Join-Path $directory 'files.txt') -ErrorAction Stop
        }
        'open' {
            $directory = Resolve-WorksetDirectory $Item
            $files = @(Get-WorksetFiles $directory)
            if (-not $files.Count) { throw 'The workset has no files.' }
            $metadata = Get-Content -LiteralPath (Join-Path $directory 'metadata.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $roots = @()
            $allInRepositories = $true
            foreach ($file in $files) {
                $context = Get-WorksetContext (Split-Path -Parent $file)
                $root = if ($context) { $context.Root } else { $allInRepositories = $false; Split-Path -Parent $file }
                if ($roots -notcontains $root) { $roots += $root }
            }
            foreach ($repository in @($metadata.repositories)) {
                if ($roots -notcontains $repository.root) { continue }
                if (-not (Test-Path -LiteralPath $repository.root -PathType Container)) {
                    Write-Warning "Recorded repository is missing: $($repository.root)"
                    continue
                }
                $current = Get-WorksetContext $repository.root
                if (-not $current -or $current.Branch -cne $repository.branch) {
                    Write-Warning "Branch mismatch in '$($repository.root)': expected '$($repository.branch)', current '$($current.Branch)'."
                }
            }
            $singleRepo = $allInRepositories -and $roots.Count -eq 1
            if ($Vs -and -not $singleRepo) { throw 'Visual Studio requires all workset files to belong to one repository; use -Code.' }
            $hasSolution = $singleRepo -and -not $Code -and @(Get-VsSolutions -StartDirectory $roots[0]).Count -gt 0
            if ($Vs -and -not $hasSolution) { throw "No Visual Studio solution found for '$($roots[0])'." }
            if ($Code -or -not $hasSolution) {
                if (-not (Get-Command code -ErrorAction SilentlyContinue)) { throw 'VS Code command not found in PATH.' }
                if ($PSCmdlet.ShouldProcess($directory, 'Open workset in VS Code')) {
                    & code --new-window @roots @files
                    if ($LASTEXITCODE -ne 0) { throw "VS Code exited with code $LASTEXITCODE." }
                }
            } else {
                if ($PSCmdlet.ShouldProcess($directory, 'Open workset in Visual Studio')) { vs $roots[0] -Files $files }
            }
        }
        'archive' {
            $directory = Resolve-WorksetDirectory $Item
            $destination = Get-WorksetDirectory (Split-Path -Leaf $directory) -Archived
            if (Test-Path -LiteralPath $destination) { throw "Archive already exists: $destination" }
            if ($PSCmdlet.ShouldProcess($directory, 'Archive workset')) {
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                Move-Item -LiteralPath $directory -Destination $destination -ErrorAction Stop
            }
        }
        'restore' {
            $directory = Resolve-WorksetDirectory $Item -Archived
            $destination = Get-WorksetDirectory (Split-Path -Leaf $directory)
            if (Test-Path -LiteralPath $destination) { throw "Active workset already exists: $destination" }
            if ($PSCmdlet.ShouldProcess($directory, 'Restore workset')) {
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                Move-Item -LiteralPath $directory -Destination $destination -ErrorAction Stop
            }
        }
        'delete' {
            $directory = Resolve-WorksetDirectory $Item -Archived:$Archived
            if ($PSCmdlet.ShouldProcess($directory, 'Delete workset list')) {
                $answer = Read-Host "Delete workset '$(Split-Path -Leaf $directory)'? [y/N]"
                if ($answer -match '^[Yy]$') { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop }
            }
        }
    }
}
