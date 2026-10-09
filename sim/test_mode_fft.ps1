param([string]$Python = "")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Python)) {
  $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
  if ($pythonCmd) {
    $Python = $pythonCmd.Source
  } else {
    Write-Host "FAIL: Python was not found. Pass -Python <path-to-python.exe>." -ForegroundColor Red
    exit 2
  }
}

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "tb_all.ps1") -Filter test_mode_fft
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$modes = @(4, 8, 16, 32)
foreach ($n in $modes) {
  $samples = Join-Path $root ("sim\evidence\test_mode_n" + $n + ".csv")
  $spectrum = Join-Path $root ("sim\evidence\test_mode_n" + $n + "_spectrum.csv")
  $peaks = Join-Path $root ("sim\evidence\test_mode_n" + $n + "_peaks.csv")
  $plot = Join-Path $root ("sim\evidence\test_mode_n" + $n + "_spectrum.png")

  & $Python (Join-Path $root "tools\csv_fft.py") $samples --fs 48828.125 --col sample --bits 16 -o $spectrum --plot $plot --title ("Test Mode N=" + $n)
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  & $Python (Join-Path $root "tools\peak_count.py") $spectrum --expect $n --min-db -40 -o $peaks
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "PASS: Test Mode FFT peak counts are exactly 4/8/16/32." -ForegroundColor Green
