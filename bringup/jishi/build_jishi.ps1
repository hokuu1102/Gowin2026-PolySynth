# build_jishi.ps1 -- one-shot build for the JISHI board + copy the reports into evidence/
#
# Usage (* works from ANY directory -- the repo root is derived from this script's own path):
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\bringup\jishi\build_jishi.ps1
#   e.g. from the repo root:
#     powershell -NoProfile -ExecutionPolicy Bypass -File bringup\jishi\build_jishi.ps1
#
# It (1) runs the Gowin CLI flow, (2) copies the four reports you MUST read into
# bringup/jishi/evidence/, (3) prints a short verdict.
#
# !! LOCATION INDEPENDENCE (2026-09-17 fix -- this was a real bug):
#   The first version passed the RELATIVE path "bringup/jishi/build_jishi.tcl" to gw_sh,
#   so running it from anywhere but the repo root failed. And the failure looked like a
#   tool problem rather than a path problem.
#   => This script now derives everything from $PSScriptRoot, and it GENERATES the Tcl
#      with the absolute project path baked in (so no absolute path is ever committed).
#
# ASCII-only on purpose (the console is GBK; a BOM-less UTF-8 .ps1 with Chinese
# comments gets mis-decoded -> syntax error, see U46 / K-38).

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root
$here = Join-Path $root "bringup\jishi"
$evid = Join-Path $here "evidence"
$gw   = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$gen  = Join-Path $root "build\jishi_build.tcl"

if (-not (Test-Path $gw)) { Write-Host "FATAL: gw_sh.exe not found at $gw" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force -Path $evid | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $gen) | Out-Null

# Generate the Tcl with ABSOLUTE paths (gw_sh resolves relative paths against ITS cwd,
# which is not necessarily ours). Forward slashes: Tcl/Gowin prefer them.
$proj = ((Join-Path $here "jishi.gprj") -replace '\\','/')
$tclTxt = "open_project $proj`nset_option -top_module jishi_top`nrun all`nexit`n"
[System.IO.File]::WriteAllText($gen, $tclTxt, [System.Text.UTF8Encoding]::new($false))

Write-Host "=== [1/3] Gowin CLI: synthesis + PnR + bitstream ===" -ForegroundColor Cyan
& $gw $gen 2>&1 | Tee-Object -FilePath (Join-Path $evid "jishi_build.log") | Out-Null
$rc = $LASTEXITCODE
Write-Host ("    exit code = " + $rc)
Write-Host ("    project   = " + $proj)

Write-Host "=== [2/3] copy reports into evidence/ ===" -ForegroundColor Cyan
# The FOUR things you must read (see U52):
#   1. build log ................ zero errors
#   2. timing report ............ violated endpoints + Actual Fmax
#   3. pin report ............... every pin really landed (only the tool checks ball numbers)
#   4. resource report .......... FF / LUT / BSRAM
$cand = @(
  @{ src = "impl\pnr\jishi_tr_content.html"; dst = "jishi_timing.html" },
  @{ src = "impl\pnr\jishi.rpt.txt";         dst = "jishi_pinout.rpt.txt" },
  @{ src = "impl\pnr\jishi.pin.html";        dst = "jishi_pin.html" },
  @{ src = "impl\gwsynthesis\jishi_syn_rsc.xml"; dst = "jishi_rsc.xml" },
  @{ src = "impl\pnr\jishi.fs";              dst = "jishi_top.fs" }
)
foreach ($c in $cand) {
  $s = Join-Path $here $c.src
  if (Test-Path $s) {
    Copy-Item $s (Join-Path $evid $c.dst) -Force
    Write-Host ("    ok  " + $c.dst)
  } else {
    Write-Host ("    --  " + $c.dst + "  (not found: " + $c.src + ")") -ForegroundColor DarkGray
  }
}

Write-Host "=== [3/3] verdict ===" -ForegroundColor Cyan
$log = Join-Path $evid "jishi_build.log"
$errCnt = 0
if (Test-Path $log) { $errCnt = ([regex]::Matches((Get-Content $log -Raw), "(?m)^\s*ERROR")).Count }
Write-Host ("    ERROR lines in build log = " + $errCnt)

# Timing: read the two numbers that matter
$tim = Join-Path $evid "jishi_timing.html"
if (Test-Path $tim) {
  $txt = (Get-Content $tim -Raw) -replace '(?i)</t[dh]>',' | ' -replace '(?i)</tr>',"`n" -replace '<[^>]+>',''
  $rows = $txt -split "`n" | Where-Object { $_ -match "\S" }
  for ($i = 0; $i -lt $rows.Count; $i++) {
    if ($rows[$i] -match "Violated Endpoints") { Write-Host ("    " + $rows[$i].Trim() + " " + $rows[$i+1].Trim()) }
  }
  $fmax = ($rows | Where-Object { $_ -match "^\s*\d+ \|?\s*$" } | Select-Object -First 1)
  Write-Host "    (open jishi_timing.html for the Actual Fmax row)"
}

if ($rc -eq 0 -and $errCnt -eq 0) {
  Write-Host ""
  Write-Host "PASS: toolchain flow finished -- now READ the four reports in:" -ForegroundColor Green
  Write-Host ("      " + $evid) -ForegroundColor Green
  Write-Host ("      bitstream: " + (Join-Path $here "impl\pnr\jishi.fs")) -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host ("FAIL: see " + (Join-Path $evid "jishi_build.log")) -ForegroundColor Red
  exit 1
}
