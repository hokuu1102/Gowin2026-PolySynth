# run_all.ps1 -- run EVERY verification that works WITHOUT a board today,
#               then print one acceptance matrix.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\run_all.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\run_all.ps1 -WithGowin
#
# What it runs:
#   1) sim\tb_all.ps1        -- simulation regression (every tb, judged by exit code + FAIL lines)
#   2) tools\selftest_all.py -- the four tools' self tests
#   3) sim\gowin_build.ps1   -- Gowin full flow (synthesis + P&R + bitstream), only with -WithGowin
#
# NOTE: this file is deliberately ASCII-only. PowerShell 5.1 decodes BOM-less UTF-8
#       as the local code page (GBK) -> Chinese comments become mojibake -> syntax
#       error, and the reported line has nothing to do with the real cause (see K-38).
#
# NOTE: the matrix in bringup\01-*.md is the human-readable version;
#       this script is the executable half of it.

param([switch]$WithGowin)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$rows = @()

function Add-Row($name, $ok, $detail) {
    $script:rows += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
}

# ---------------------------------------------------------------- 1) simulation
Write-Host "`n=== [1/3] simulation regression: sim\tb_all.ps1 ===" -ForegroundColor Cyan
$nTb = @(Get-ChildItem -Path (Join-Path $root "tb") -Recurse -Include tb_*.sv -File).Count
$simOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\tb_all.ps1") 2>&1
$simExit = $LASTEXITCODE
if ($simExit -ne 0) {
    Write-Host "---- last 30 lines ----" -ForegroundColor Yellow
    $simOut | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
    Add-Row "simulation regression" $false ("exit " + $simExit + " (" + $nTb + " benches)")
} else {
    Add-Row "simulation regression" $true ($nTb.ToString() + " benches, all PASS")
}

# ---------------------------------------------------------------- 2) tool selftests
Write-Host "`n=== [2/3] tool selftests: python tools\selftest_all.py ===" -ForegroundColor Cyan
$toolOut = & python (Join-Path $root "tools\selftest_all.py") 2>&1
$toolExit = $LASTEXITCODE
$toolOut | ForEach-Object { Write-Host "    $_" }
if ($toolExit -ne 0) {
    Add-Row "tool selftests (vcd2csv/csv_fft/latency/peak_count)" $false ("exit " + $toolExit)
} else {
    Add-Row "tool selftests (vcd2csv/csv_fft/latency/peak_count)" $true "4/4 PASS"
}

# ---------------------------------------------------------------- 3) Gowin flow
if ($WithGowin) {
    Write-Host "`n=== [3/3] Gowin full flow: sim\gowin_build.ps1 (takes ~2 min) ===" -ForegroundColor Cyan
    $gwOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\gowin_build.ps1") 2>&1
    $gwExit = $LASTEXITCODE
    if ($gwExit -ne 0) {
        $gwOut | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
    }
    $gwDetail = "exit " + $gwExit
    if (Test-Path (Join-Path $root "sim\evidence\gowin_m0_timing.txt")) {
        $gwDetail = $gwDetail + "; see sim\evidence\gowin_m0_timing.txt"
    }
    Add-Row "Gowin synthesis + P&R + bitstream" ($gwExit -eq 0) $gwDetail
} else {
    Write-Host "`n=== [3/3] Gowin full flow: SKIPPED (add -WithGowin) ===" -ForegroundColor DarkGray
    Add-Row "Gowin synthesis + P&R + bitstream" $true "skipped (use -WithGowin)"
}

# ---------------------------------------------------------------- matrix
Write-Host "`n================ acceptance matrix (board-free) ================" -ForegroundColor Yellow
foreach ($r in $rows) {
    $mark = if ($r.Ok) { "PASS" } else { "FAIL" }
    $color = if ($r.Ok) { "Green" } else { "Red" }
    Write-Host ("  [" + $mark + "] " + $r.Name.PadRight(52) + " " + $r.Detail) -ForegroundColor $color
}
Write-Host "  ------------------------------------------------------------"
Write-Host "  full matrix (incl. what still needs a board): bringup\01-*.md"
Write-Host "  board (jishi) plan:                           bringup\02-*.md"
Write-Host ""

$failed = @($rows | Where-Object { -not $_.Ok }).Count
if ($failed -gt 0) {
    Write-Host ("FAIL: " + $failed + " item(s) failed") -ForegroundColor Red
    exit 1
}
Write-Host "PASS: every board-free verification passed" -ForegroundColor Green
exit 0
