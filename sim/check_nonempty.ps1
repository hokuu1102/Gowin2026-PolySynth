# check_nonempty.ps1 -- PROVE that an acceptance criterion CAN FAIL.
#
# WHY (project rule, K-56 / C21 / the 2026-09-28 corrections doc):
#   A green criterion proves NOTHING unless it has first been shown to FAIL on
#   the un-fixed code.  "Green" alone is not evidence.
#
# WHAT:
#   Compile ONE testbench with ONE RTL file replaced by its git HEAD revision,
#   then run it.  The swap happens ONLY inside iverilog's file list -- the file
#   under rtl/ is never modified, so the working tree stays clean and this can
#   run while other long jobs (PnR / regression) are in flight.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\check_nonempty.ps1 `
#       -Tb tb_vel_pos_follow -Swap rtl/w3b/note_manager.v
#
# EXIT CODES:
#   0 = the swapped build FAILED  => criterion is NON-EMPTY (good)
#   1 = the swapped build PASSED  => criterion is VACUOUS    (bad)
#   2 = infrastructure error (compile failed / tb missing / swap not applied)
#
# NOTE: this file is deliberately ASCII-only.  PowerShell 5.1 decodes BOM-less
#       UTF-8 as the local code page (GBK); ASCII sidesteps that entirely.

param(
  [Parameter(Mandatory=$true)][string]$Tb,
  [Parameter(Mandatory=$true)][string]$Swap,
  [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

# -- locate the tb ------------------------------------------------------------
$tbFile = Get-ChildItem -Path (Join-Path $root "tb") -Recurse -Include tb_*.sv -File |
          Where-Object { $_.BaseName -eq $Tb } | Select-Object -First 1
if (-not $tbFile) { Write-Host "ERROR: tb not found: $Tb" -ForegroundColor Red; exit 2 }

# -- collect sources (mirror sim\tb_all.ps1) ----------------------------------
function Get-HdlSources([string]$Dir) {
  @(Get-ChildItem -Path $Dir -Recurse -Include *.sv, *.v -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "tb_*" } |
    Sort-Object FullName | ForEach-Object { $_.FullName })
}
$rtl    = @(Get-HdlSources (Join-Path $root "rtl"))
$rtlDac = @(Get-HdlSources (Join-Path $root "bringup\dac_tone") |
            Where-Object { $_ -notmatch 'proj_fmt' })
$rtl    = @($rtl) + $rtlDac
$models = @(Get-HdlSources (Join-Path $root "tb\models"))
$chk    = @(Get-HdlSources (Join-Path $root "tb\checkers"))

# -- materialise the HEAD revision of the file to swap ------------------------
$swapFull = Join-Path $root $Swap
if (-not (Test-Path -LiteralPath $swapFull)) {
  Write-Host "ERROR: swap file not found: $Swap" -ForegroundColor Red; exit 2
}

$tmpDir  = Join-Path $env:TEMP ("nonempty_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$tmpFile = Join-Path $tmpDir (Split-Path -Leaf $Swap)

# byte-exact extraction via cmd redirection (cmd does not re-encode)
$cmdLine = 'git -C "{0}" cat-file blob HEAD:{1} > "{2}"' -f $root, $Swap, $tmpFile
cmd /c $cmdLine | Out-Null

$blobSize = [int](git -C $root cat-file -s "HEAD:$Swap")
$tmpSize  = (Get-Item -LiteralPath $tmpFile).Length
if ($tmpSize -ne $blobSize) {
  Write-Host ("WARN: temp copy is {0} bytes, blob is {1} (trailing newline?)" -f $tmpSize, $blobSize) -ForegroundColor Yellow
}

$workHash = (Get-FileHash -LiteralPath $swapFull -Algorithm SHA256).Hash
$tmpHash  = (Get-FileHash -LiteralPath $tmpFile  -Algorithm SHA256).Hash
if ($workHash -eq $tmpHash) {
  Write-Host "ERROR: HEAD revision is IDENTICAL to the working file -- nothing to prove." -ForegroundColor Red
  Write-Host "       (the swap would be a no-op, so a FAIL could not be attributed)" -ForegroundColor Red
  exit 2
}

# -- swap it into the file list -----------------------------------------------
$swapped = @()
$hit = $false
foreach ($f in $rtl) {
  if ($f -ieq $swapFull) { $swapped += $tmpFile; $hit = $true } else { $swapped += $f }
}
if (-not $hit) {
  Write-Host "ERROR: $Swap is not in the rtl source list" -ForegroundColor Red; exit 2
}

Write-Host ("[nonempty] tb   = {0}" -f $Tb)
Write-Host ("[nonempty] swap = {0}  ->  HEAD revision" -f $Swap)
Write-Host ("[nonempty] RTL {0} + models {1} + checkers {2}" -f $swapped.Count, $models.Count, $chk.Count)

# -- make sure the tb's $dumpfile directory exists ----------------------------
$src = Get-Content -LiteralPath $tbFile.FullName -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($src, '\$dumpfile\s*\(\s*"([^"]+)"')) {
  $dumpPath = $m.Groups[1].Value
  if (-not [System.IO.Path]::IsPathRooted($dumpPath)) { $dumpPath = Join-Path $root $dumpPath }
  $dumpDir = Split-Path -Parent $dumpPath
  if ($dumpDir) { New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null }
}

$outDir  = Join-Path $root ("build\sim\" + $Tb + "_nonempty")
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$vvpFile = Join-Path $outDir ($Tb + ".vvp")
$cmpLog  = Join-Path $outDir ($Tb + ".compile.log")
$runLog  = Join-Path $outDir ($Tb + ".log")
$errLog  = Join-Path $outDir ($Tb + ".err.log")
if (Test-Path -LiteralPath $vvpFile) { Remove-Item -LiteralPath $vvpFile -Force }

$iverilog = (Get-Command iverilog -ErrorAction SilentlyContinue).Source
$vvp      = (Get-Command vvp      -ErrorAction SilentlyContinue).Source
if (-not $iverilog -or -not $vvp) {
  Write-Host "ERROR: iverilog / vvp not on PATH" -ForegroundColor Red; exit 2
}

# -- compile ------------------------------------------------------------------
$isProm = $Tb -like "*_prom*"
if ($isProm) {
  $compileArgs = @("-g2012","-Wall","-s",$Tb,"-o",$vvpFile) + $swapped + $models + $chk + @($tbFile.FullName)
} else {
  $compileArgs = @("-g2012","-Wall","-DWAVETABLE_BEHAVIORAL","-s",$Tb,"-o",$vvpFile) + $swapped + $models + $chk + @($tbFile.FullName)
}
$cOut = & $iverilog @compileArgs 2>&1
$cExit = $LASTEXITCODE
$cOut | Out-File -FilePath $cmpLog -Encoding utf8
if ($cExit -ne 0) {
  Write-Host ("ERROR: compile FAILED (exit {0}) -- not a criterion result" -f $cExit) -ForegroundColor Red
  $cOut | Where-Object { "$_" -match "\S" } | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
  exit 2
}

# -- run (with a watchdog: "no verdict" must never be read as "pass") ---------
$p = Start-Process -FilePath $vvp -ArgumentList @($vvpFile) -NoNewWindow -PassThru `
                   -RedirectStandardOutput $runLog -RedirectStandardError $errLog
$finished = $p.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
  try { $p.Kill() } catch {}
  Write-Host ("ERROR: TIMEOUT after {0}s -- no verdict (counts as NOT proven)" -f $TimeoutSec) -ForegroundColor Red
  exit 2
}
$p.WaitForExit()
$rExit = "n/a"
try { $p.Refresh(); $rExit = $p.ExitCode } catch { $rExit = "n/a" }

# -- verdict: decided by the LOG, never by the exit code ----------------------
# WHY: with Start-Process + redirected stdio, PS 5.1 sometimes returns a null
#      ExitCode (observed 2026-09-28).  A null makes "exit -eq 0" false, which
#      would mislabel a VACUOUS criterion as non-empty -- i.e. the checker would
#      lie in exactly the direction that matters.  The tb's own PASS/FAIL lines
#      are the contract (same convention as sim\tb_all.ps1), so decide on those.
$logText   = @(Get-Content -LiteralPath $runLog -Encoding UTF8 -ErrorAction SilentlyContinue)
$failLines = @($logText | Where-Object { $_ -match '^\s*FAIL' })
$passLines = @($logText | Where-Object { $_ -match '^\s*PASS' })

Write-Host ""
$logText | Where-Object { $_ -match '^\s*(ok|FAIL|PASS)' } | ForEach-Object { Write-Host "    $_" }
Write-Host ""
Write-Host ("[nonempty] vvp exit = {0} (informational only) ; FAIL lines = {1} ; PASS lines = {2}" -f `
            $rExit, $failLines.Count, $passLines.Count)

if ($failLines.Count -gt 0) {
  Write-Host "[nonempty] RESULT: the HEAD (un-fixed) build FAILED while the working build passed." -ForegroundColor Green
  Write-Host "[nonempty]         => criterion is NON-EMPTY (this is the wanted outcome)." -ForegroundColor Green
  Write-Host ("[nonempty] log: {0}" -f $runLog)
  exit 0
} elseif ($passLines.Count -gt 0) {
  Write-Host "[nonempty] RESULT: the HEAD (un-fixed) build ALSO PASSED." -ForegroundColor Red
  Write-Host "[nonempty]         => the criterion is VACUOUS. Fix the criterion, not the code." -ForegroundColor Red
  Write-Host ("[nonempty] log: {0}" -f $runLog)
  exit 1
} else {
  Write-Host "[nonempty] RESULT: neither a PASS nor a FAIL line -- NO VERDICT." -ForegroundColor Red
  Write-Host "[nonempty]         => 'no verdict' must never be read as 'proven'." -ForegroundColor Red
  Write-Host ("[nonempty] log: {0}" -f $runLog)
  exit 2
}
