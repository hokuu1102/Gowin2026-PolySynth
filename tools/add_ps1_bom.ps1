# add_ps1_bom.ps1 -- add a UTF-8 BOM to every BOM-less .ps1 in the repo
#
# WHY
#   Project decision (2026-09-24): ALL .ps1 files are UTF-8 WITH BOM.
#   Rationale and failure modes are in tools\check_ps1_encoding.ps1
#   (syntax error U46/K-55; SILENT array-element loss C72).
#
# WHAT IT DOES
#   Prepends EF BB BF to any .ps1 that lacks it.  Byte-level, so line endings
#   and all existing content are preserved exactly.  Idempotent: running it
#   twice changes nothing the second time.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\add_ps1_bom.ps1          # dry run
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\add_ps1_bom.ps1 -Apply   # do it
#
# NOTE: keep this file pure ASCII as well (see the header of the checker).

param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$skipDirs = @('\.git\', '\build\', '\_wt_oldcheck\', '\impl\')

$changed = 0
$scanned = 0

Get-ChildItem $root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
    $path = $_.FullName
    $rel = $path.Substring($root.Length).TrimStart('\')

    $skip = $false
    foreach ($d in $skipDirs) { if ($path -like "*$d*") { $skip = $true } }
    if ($skip) { return }

    $scanned++
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { return }

    $nonAscii = 0
    foreach ($x in $bytes) { if ($x -gt 127) { $nonAscii++ } }

    $changed++
    $why = if ($nonAscii -gt 0) { "non-ASCII=$nonAscii  <-- would FAIL today" } else { "pure ASCII (safe either way)" }

    if ($Apply) {
        $new = New-Object byte[] ($bytes.Length + 3)
        $new[0] = 0xEF; $new[1] = 0xBB; $new[2] = 0xBF
        [Array]::Copy($bytes, 0, $new, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($path, $new)
        Write-Host ("  ADDED   " + $rel + "   " + $why) -ForegroundColor Green
    } else {
        Write-Host ("  would add  " + $rel + "   " + $why) -ForegroundColor Yellow
    }
}

Write-Host ""
if ($Apply) {
    Write-Host ("DONE: {0} file(s) updated, {1} scanned." -f $changed, $scanned) -ForegroundColor Green
} else {
    Write-Host ("DRY RUN: {0} file(s) would be updated, {1} scanned.  Re-run with -Apply." -f $changed, $scanned) -ForegroundColor Cyan
}
exit 0
