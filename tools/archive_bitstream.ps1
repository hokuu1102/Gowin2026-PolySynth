# archive_bitstream.ps1 -- copy impl/pnr/Gowin2026.fs OUT of impl/ with a label,
#                         record its sha256, and append a row to a TRACKED index.
#
# WHY (2026-10-16, learned the hard way):
#   sim/gowin_build.ps1 WIPES impl/pnr/ at the start of every run
#   (`Remove-Item impl/pnr -Recurse -Force`, see its L205-219).  So the bitstream
#   from the previous run is DESTROYED the moment you start a new one -- and impl/
#   is git-ignored, so git cannot get it back either.
#   On 2026-10-16 a rebuild wiped the only copy of a bitstream that was still
#   needed for an A/B comparison.  This script is the fix: archive FIRST.
#
# USAGE (run BEFORE starting any new build):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\archive_bitstream.ps1 -Label v3-cstfix -Note "h5_scope restored"
#
#   exit 0 = archived
#   exit 1 = nothing to archive (impl/pnr/Gowin2026.fs absent)
#
# NOTE: this file is PURE ASCII on purpose (project rule: a .ps1 must either
#   carry a UTF-8 BOM or be pure ASCII).

param(
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Note = "",
    [string]$DestDir = "build\bitstreams"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$src = Join-Path $root 'impl\pnr\Gowin2026.fs'
if (-not (Test-Path $src)) {
    Write-Host "ERROR: no bitstream at impl\pnr\Gowin2026.fs -- nothing to archive." -ForegroundColor Red
    Write-Host "       (If a build is running, impl/pnr was wiped at its start.)"
    Pop-Location
    exit 1
}

$dstRoot = Join-Path $root $DestDir
New-Item -ItemType Directory -Force -Path $dstRoot | Out-Null

$stamp = (Get-Item $src).LastWriteTime.ToString('yyyyMMdd-HHmmss')
$safe  = ($Label -replace '[^A-Za-z0-9_.-]', '_')
$name  = "$stamp-$safe.fs"
$dst   = Join-Path $dstRoot $name

Copy-Item $src $dst -Force
$hash  = (Get-FileHash $dst -Algorithm SHA256).Hash
$mb    = [math]::Round((Get-Item $dst).Length / 1MB, 1)

# ---- tracked index (build/ is git-ignored, so the index lives under sim/evidence) ----
$idx = Join-Path $root 'sim\evidence\bitstream-index.md'
if (-not (Test-Path $idx)) {
    $hdr = @(
        '# Bitstream index (append-only, written by tools/archive_bitstream.ps1)',
        '',
        '> WHY: `sim/gowin_build.ps1` WIPES `impl/pnr/` at the start of every run,',
        '> and `impl/` is git-ignored -- so an un-archived bitstream is gone forever.',
        '> Archive BEFORE starting a new build.',
        '',
        '| archived | label | size MB | sha256 | note |',
        '|---|---|---|---|---|'
    )
    $hdr | Out-File -FilePath $idx -Encoding utf8
}

$row = "| $stamp | $safe | $mb | ``$hash`` | $Note |"
Add-Content -Path $idx -Value $row -Encoding utf8

Write-Host "OK  archived -> $DestDir\$name" -ForegroundColor Green
Write-Host "    sha256 = $hash"
Write-Host "    index  -> sim\evidence\bitstream-index.md"

Pop-Location
exit 0
