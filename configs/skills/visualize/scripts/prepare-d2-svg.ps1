<#
.SYNOPSIS
Compiles a .d2 diagram to a clean, font-stripped .svg ready for viewer-template.html injection.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourcePath,

    [Parameter(Position = 1)]
    [string]$OutPath,

    [ValidateSet('dagre', 'elk')]
    [string]$Layout,

    [int]$Pad = 24
)

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    Write-Host "✖ prepare-d2-svg: Source file not found: $SourcePath" -ForegroundColor Red
    exit 1
}

$d2Cmd = Get-Command d2 -ErrorAction SilentlyContinue
$d2Exe = if ($d2Cmd) {
    $d2Cmd.Source
} elseif (Test-Path -LiteralPath 'C:\Program Files\D2\d2.exe' -PathType Leaf) {
    'C:\Program Files\D2\d2.exe'
} else {
    $null
}

if (-not $d2Exe) {
    Write-Host "✖ prepare-d2-svg: 'd2' binary not found on PATH or at 'C:\Program Files\D2\d2.exe'." -ForegroundColor Red
    exit 2
}

if (-not $OutPath) {
    $OutPath = [System.IO.Path]::ChangeExtension($SourcePath, '.svg')
}

$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($outDir)
}

$d2Args = @('--pad', "$Pad")
if ($Layout) {
    $d2Args += @('--layout', $Layout)
}
$d2Args += @($SourcePath, $OutPath)

& $d2Exe @d2Args
if ($LASTEXITCODE -ne 0) {
    Write-Host "✖ prepare-d2-svg: d2 failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}

$raw = [System.IO.File]::ReadAllText($OutPath, [System.Text.Encoding]::UTF8)

# Strip XML declaration and D2's embedded WOFF @font-face blobs (viewer-template.html uses system sans-serif)
$clean = [regex]::Replace($raw, '^\s*<\?xml[^?]*\?>\s*', '')
$clean = [regex]::Replace($clean, '@font-face\s*\{[^}]*\}', '')
$clean = [regex]::Replace($clean, '\.d2-\d+\s+\.text(?:-(?:bold|italic))?\s*\{\s*font-family:\s*"d2-[^"]+";\s*\}', '')
$clean = [regex]::Replace($clean, '<style type="text/css"><!\[CDATA\[\s*\]\]></style>', '')

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($OutPath, $clean, $utf8NoBom)

$dims = if ($clean -match 'viewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"') {
    $w = [double]$matches[1]
    $h = [double]$matches[2]
    $ratio = if ($h -gt 0) { [math]::Round($w / $h, 2) } else { 0 }
    "${w}x${h}, ratio ${ratio}:1"
} else {
    'unknown dimensions'
}
$kb = [math]::Round(([System.Text.Encoding]::UTF8.GetByteCount($clean)) / 1024.0, 1)
Write-Host "OK: $OutPath ($dims, $kb KB)"
