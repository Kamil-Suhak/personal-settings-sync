function Get-PssLocalStatePaths {
    param(
        [Parameter(Mandatory)][string]$Checkout,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    if (-not $LocalAppData) { throw 'LOCALAPPDATA is not set.' }
    $root = Join-Path $LocalAppData 'PersonalSettingsSync'
    $canonical = [System.IO.Path]::GetFullPath($Checkout).TrimEnd('\').ToUpperInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $id = [Convert]::ToHexString($hash.ComputeHash($bytes)).ToLowerInvariant() }
    finally { $hash.Dispose() }
    return [PSCustomObject]@{
        Root = $root
        ProjectRoots = Join-Path $root 'project-roots'
        LocalProfile = Join-Path $root 'profile.local.ps1'
        Workspace = Join-Path $root "checkouts\$id\workspace.local"
    }
}

function Invoke-PssLocalStateMigration {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Checkout,
        [Parameter(Mandatory)][string]$HomePath,
        [string]$ProfileDirectory,
        [switch]$WhatIf
    )

    # TODO: Remove this migration after both PCs use the new local-state paths.
    $pairs = @(
        @{ Source = (Join-Path $HomePath '.project-roots'); Destination = $Paths.ProjectRoots }
        @{ Source = (Join-Path $HomePath '.profile.local.ps1'); Destination = $Paths.LocalProfile }
        @{ Source = (Join-Path $Checkout '.workspace.local'); Destination = $Paths.Workspace }
    )
    if ($ProfileDirectory) {
        $profileLegacy = Join-Path $ProfileDirectory '.profile.local.ps1'
        if (-not [string]::Equals($profileLegacy, (Join-Path $HomePath '.profile.local.ps1'), [StringComparison]::OrdinalIgnoreCase)) {
            $pairs += @{ Source = $profileLegacy; Destination = $Paths.LocalProfile }
        }
    }
    $existing = @($pairs | Where-Object { Test-Path -LiteralPath $_.Source -PathType Leaf })
    if (-not $existing.Count) { return }
    if ($WhatIf) {
        foreach ($pair in $existing) { Write-Host "WHAT-IF: Migrate '$($pair.Source)' to '$($pair.Destination)'." }
        return
    }

    $mutex = [System.Threading.Mutex]::new($false, 'Local\PssLocalStateMigration')
    $locked = $false
    try {
        $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $locked) { throw 'Timed out waiting for another PSS local-state migration.' }
        $existing = @($pairs | Where-Object { Test-Path -LiteralPath $_.Source -PathType Leaf })
        $destHashes = @{}
        foreach ($pair in $existing) {
            $sourceHash = (Get-FileHash -LiteralPath $pair.Source -Algorithm SHA256 -ErrorAction Stop).Hash
            $pair.Hash = $sourceHash
            if ($destHashes.ContainsKey($pair.Destination) -and $destHashes[$pair.Destination] -ne $sourceHash) {
                throw "Conflicting legacy files for '$($pair.Destination)'; originals were preserved."
            }
            $destHashes[$pair.Destination] = $sourceHash
            if (Test-Path -LiteralPath $pair.Destination) {
                if (-not (Test-Path -LiteralPath $pair.Destination -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $pair.Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $sourceHash) {
                    throw "Local-state destination conflicts: '$($pair.Destination)'; originals were preserved."
                }
            }
        }
        foreach ($pair in $existing) {
            if (-not (Test-Path -LiteralPath $pair.Destination)) {
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $pair.Destination))
                [System.IO.File]::Copy($pair.Source, $pair.Destination, $false)
            }
            if ((Get-FileHash -LiteralPath $pair.Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $pair.Hash) {
                throw "Verification failed for '$($pair.Destination)'; originals were preserved."
            }
        }
        foreach ($pair in $existing) {
            if ((Get-FileHash -LiteralPath $pair.Source -Algorithm SHA256 -ErrorAction Stop).Hash -ne $pair.Hash) {
                throw "Legacy file changed during migration: '$($pair.Source)'; originals were preserved."
            }
        }
        foreach ($pair in $existing) {
            Remove-Item -LiteralPath $pair.Source -ErrorAction Stop
            Write-Host "Migrated '$($pair.Source)' to '$($pair.Destination)'."
        }
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
