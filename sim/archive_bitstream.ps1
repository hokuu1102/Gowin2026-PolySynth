# archive_bitstream.ps1 -- archive ONE PnR result into build/bitstreams/<name>.*
#
# WHY THIS EXISTS
#   The build/bitstreams/ archive used to be copied BY HAND, and that went wrong:
#   F (DPOS_DIAG=0) and G (DPOS_DIAG=1) ended up with IDENTICAL .rsc.xml resource
#   numbers, which is impossible if the diagnostic really adds 16 comparators.
#   A hand copy can silently keep a STALE file.  This script:
#     1. refuses to run when the timing evidence is OLDER than the bitstream
#     2. copies all three artifacts in one go
#     3. PRINTS the resource numbers so two builds can be compared mechanically
#
# USAGE (from the repository root)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\archive_bitstream.ps1 -Name N_diag_dpos
#
# NOTE: pure ASCII on purpose -- no BOM needed, no GBK decoding trap (see C72/U46).

param(
  [Parameter(Mandatory=$true)][string]$Name,
  #  Optional: another already-archived entry name.  When given, this script
  #  ASSERTS that the evidence fingerprints DIFFER.  Two builds that differ in
  #  one parameter MUST produce different timing/resource evidence; identical
  #  fingerprints mean the copy is STALE (see K-164).
  [string]$CompareTo = '',
  #  Overwrite an existing archive.  WITHOUT this the script REFUSES to run when
  #  any of the three target files already exists -- added 2026-09-29 after I
  #  destroyed the G_diag_dpos archive by testing the script with its real name.
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$fs     = Join-Path $root 'impl\pnr\Gowin2026.fs'
$timing = Join-Path $root 'sim\evidence\gowin_m0_timing.txt'
$rsc    = Join-Path $root 'sim\evidence\gowin_m0_rsc.xml'
$outDir = Join-Path $root 'build\bitstreams'

foreach ($p in @($fs, $timing, $rsc)) {
  if (-not (Test-Path $p)) {
    Write-Host "ERROR: missing $p" -ForegroundColor Red
    exit 1
  }
}

#  Freshness check: the timing evidence must not be OLDER than the bitstream.
$tFs = (Get-Item $fs).LastWriteTime
$tTi = (Get-Item $timing).LastWriteTime
$tRs = (Get-Item $rsc).LastWriteTime
Write-Host ("bitstream : {0}   {1} bytes" -f $tFs, (Get-Item $fs).Length)
Write-Host ("timing    : {0}" -f $tTi)
Write-Host ("resource  : {0}" -f $tRs)
if ($tTi -lt $tFs.AddMinutes(-5)) {
  Write-Host "ERROR: timing evidence is OLDER than the bitstream -- refusing to archive a mismatched pair." -ForegroundColor Red
  Write-Host "       re-run sim\gowin_build.ps1 first" -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

#  REFUSE TO OVERWRITE.  An archive is EVIDENCE; silently replacing it destroys
#  the very thing you wanted to compare against.  (Added after I did exactly
#  that on 2026-09-29 -- see K-164.)
$existing = @()
foreach ($ext in @('fs', 'timing.txt', 'rsc.xml')) {
  $t = Join-Path $outDir ("{0}.{1}" -f $Name, $ext)
  if (Test-Path $t) { $existing += $t }
}
if (($existing.Count -gt 0) -and (-not $Force)) {
  Write-Host "ERROR: these archive files already exist:" -ForegroundColor Red
  $existing | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
  Write-Host "       Refusing to overwrite EVIDENCE.  Use -Force if you really mean it," -ForegroundColor Red
  Write-Host "       or pick a new -Name." -ForegroundColor Red
  exit 1
}

Copy-Item $fs     (Join-Path $outDir "$Name.fs")         -Force
Copy-Item $timing (Join-Path $outDir "$Name.timing.txt") -Force
Copy-Item $rsc    (Join-Path $outDir "$Name.rsc.xml")    -Force

#  Print the numbers so two builds can be compared without opening the XML by hand.
$line = (Select-String -Path $rsc -Pattern '<Module name="top"' | Select-Object -First 1).Line
$reg  = [regex]::Match($line, 'T_Register="(\d+)').Groups[1].Value
$lut  = [regex]::Match($line, 'T_Lut="(\d+)').Groups[1].Value
$bsr  = [regex]::Match($line, 'T_Bsram="(\d+)').Groups[1].Value

#  The timing file lists, on separate lines: the constraint, then the ACTUAL Fmax,
#  both ending in "(MHz)".  Collect every such line and report them in order, so a
#  wrong guess cannot silently report the constraint as the result.
$freq = @(Select-String -Path $timing -Pattern '^[0-9.]+\(MHz\)' | ForEach-Object { $_.Line.Trim() })
$fmax = if ($freq.Count -ge 2) { "$($freq[1])  (constraint $($freq[0]))" }
        elseif ($freq.Count -eq 1) { "$($freq[0])  (only one found -- CHECK)" }
        else { '(not found)' }

$shaFs  = (Get-FileHash (Join-Path $outDir "$Name.fs")         -Algorithm SHA256).Hash
$shaTi  = (Get-FileHash (Join-Path $outDir "$Name.timing.txt") -Algorithm SHA256).Hash
$shaRsc = (Get-FileHash (Join-Path $outDir "$Name.rsc.xml")    -Algorithm SHA256).Hash

Write-Host ""
Write-Host "OK  archived as $Name" -ForegroundColor Green
Write-Host ("    Register = {0}" -f $reg)
Write-Host ("    Lut      = {0}" -f $lut)
Write-Host ("    Bsram    = {0}" -f $bsr)
Write-Host ("    Fmax     = {0}" -f $fmax)
Write-Host ("    sha .fs        = {0}" -f $shaFs)
Write-Host ("    sha timing.txt = {0}" -f $shaTi)
Write-Host ("    sha rsc.xml    = {0}" -f $shaRsc)

#  K-164: the .fs being different is NOT enough -- the EVIDENCE files must differ
#  too.  A stale copy keeps the .fs right while the timing/resource files stay
#  from the previous build, which silently invalidates any conclusion drawn from
#  them.
if ($CompareTo -ne '') {
  Write-Host ""
  Write-Host "COMPARE against $CompareTo" -ForegroundColor Cyan
  $bad = 0
  foreach ($pair in @(
      @{ f = 'fs';         sha = $shaFs },
      @{ f = 'timing.txt'; sha = $shaTi },
      @{ f = 'rsc.xml';    sha = $shaRsc })) {
    $other = Join-Path $outDir ("{0}.{1}" -f $CompareTo, $pair.f)
    if (-not (Test-Path $other)) {
      Write-Host ("  SKIP  {0} -- {1} not found" -f $pair.f, $other) -ForegroundColor DarkYellow
      continue
    }
    $osha = (Get-FileHash $other -Algorithm SHA256).Hash
    if ($osha -eq $pair.sha) {
      Write-Host ("  STALE {0} -- fingerprint IDENTICAL to {1}" -f $pair.f, $CompareTo) -ForegroundColor Red
      $bad = $bad + 1
    } else {
      Write-Host ("  ok    {0} differs" -f $pair.f) -ForegroundColor Green
    }
  }
  if ($bad -gt 0) {
    Write-Host ""
    Write-Host "ERROR: $bad evidence file(s) are IDENTICAL to $CompareTo." -ForegroundColor Red
    Write-Host "       The two builds differ in one parameter, so identical evidence means" -ForegroundColor Red
    Write-Host "       the copy is STALE.  Do NOT draw conclusions from these files." -ForegroundColor Red
    exit 1
  }
  Write-Host "OK  all three artifacts differ from $CompareTo" -ForegroundColor Green
}

Write-Host ""
Write-Host "REMINDER: to prove the archive is not stale, the resource numbers of two"
Write-Host "          builds that differ in ONE parameter MUST differ.  If they are"
Write-Host "          identical, suspect the copy, not the tool."
