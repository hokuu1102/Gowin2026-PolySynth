$root = $PSScriptRoot
$trPath = Join-Path $root 'impl/pnr/report.html'
$p030Tr = $trPath                                    # absolute, set at line ~338
$p030Tp = Join-Path $root "impl\pnr\Gowin2026.timing_paths"

function Get-P030TnsSetupRows([string]$Raw) {
  # Parse the "Total Negative Slack Summary" table: one row per
  # (clock, analysis type) with columns TNS and endpoint count.
  # Returns only the Setup rows.
  $i = $Raw.IndexOf('Total Negative Slack Summary')
  if ($i -lt 0) { return @() }
  $j = $Raw.IndexOf('Path Slacks Table', $i)
  if ($j -lt 0) { $j = $Raw.IndexOf('Timing Details', $i) }
  if ($j -lt 0) { return @() }
  $seg = $Raw.Substring($i, $j - $i)
  # Two Gowin layouts exist: <td> per line, and <td> sharing a line.  Collapse
  # both to ';' per row and '|' per cell so one parser handles both.
  $t = ($seg -replace '(?i)</t[dh]>', '|' -replace '(?i)</tr>', ';' -replace '<[^>]+>', '' -replace '[ \t\r\n]+', '').Trim()
  $res = @()
  foreach ($rec in ($t -split ';')) {
    $c = @($rec -split '\|' | Where-Object { $_ -ne '' })
    for ($k = 0; $k -lt $c.Count; $k++) {
      if ($c[$k] -like '*TotalNegativeSlackSummary*' -or $c[$k] -eq 'ClockName') { continue }
      if (($k + 3) -lt $c.Count -and $c[$k+1] -eq 'Setup' -and $c[$k] -ne 'Setup') {
        $o = New-Object PSObject -Property @{ Clock = $c[$k]; Tns = 0.0; Ep = 0 }
        $dv = 0.0; if ([double]::TryParse($c[$k+2], [ref]$dv)) { $o.Tns = $dv }
        $ev = 0;   if ([int]::TryParse($c[$k+3],    [ref]$ev)) { $o.Ep  = $ev }
        $res += $o
        $k += 3
      }
    }
  }
  return $res
}

function Get-P030WorstSetupSlack([string]$Path) {
  # timing_paths is a flat stream: a line reading exactly SETUP, then the
  # path slack on the next line.  Take the minimum.
  $lines = @(Get-Content $Path)
  $best = $null
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq 'SETUP' -and ($i + 1) -lt $lines.Count) {
      $d = 0.0
      if ([double]::TryParse($lines[$i+1].Trim(), [ref]$d)) {
        if (($null -eq $best) -or ($d -lt $best)) { $best = $d }
      }
    }
  }
  return $best
}

# ---- fail closed: no report ----
if (-not (Test-Path $p030Tr)) {
  Write-Host "ERROR: P0-30 -- no timing report at $p030Tr" -ForegroundColor Red
  Write-Host "       Setup timing CANNOT be verified => FAIL CLOSED." -ForegroundColor Red
  Write-Host "       'Cannot verify' is not 'clean' (K-45 / L31)." -ForegroundColor Red
  exit 12
}

# ---- fail closed: unparseable report ----
$p030Rows = @(Get-P030TnsSetupRows (Get-Content $p030Tr -Raw))
if ($p030Rows.Count -eq 0) {
  Write-Host "ERROR: P0-30 -- could not parse 'Total Negative Slack Summary' from $p030Tr" -ForegroundColor Red
  Write-Host "       A report we cannot read is NOT a clean report => FAIL CLOSED." -ForegroundColor Red
  Write-Host "       (A gate that passes on unparseable input is worse than no gate.)" -ForegroundColor Red
  exit 12
}

$p030EpTotal  = @($p030Rows | Measure-Object -Property Ep  -Sum).Sum
$p030TnsTotal = [math]::Round(@($p030Rows | Measure-Object -Property Tns -Sum).Sum, 3)
if ($null -eq $p030EpTotal)  { $p030EpTotal  = 0 }
if ($null -eq $p030TnsTotal) { $p030TnsTotal = 0 }
$p030Worst = if (Test-Path $p030Tp) { Get-P030WorstSetupSlack $p030Tp } else { $null }
$p030WorstTxt = if ($null -eq $p030Worst) { "n/a (timing_paths absent)" } else { "$p030Worst ns" }

# ============================================================================
#  OVER-CONSTRAINT vs REAL REQUIREMENT  (user decision, 2026-10-17)
#
#  top.sdc does TWO different things to clk_sys:
#     create_clock -name clk_sys -period 20     <- the REAL clock (50 MHz)
#     set_max_delay ... clk_sys -> clk_sys 16.4 <- a TIGHTER, artificial
#                                                  budget that exists only to
#                                                  make the placer work harder
#  Its own comment says so: "OPT08: placement target only; physical clk_sys
#  remains 50 MHz."
#
#  Therefore a path that misses 16.4 ns but still ARRIVES BEFORE the real
#  20 ns clock edge is NOT a functional violation -- it is the over-constraint
#  doing its job.  The release verdict must be computed against the REAL
#  period.  (Measured 2026-10-17: worst path arrives at 17.707 ns, i.e.
#  +2.976 ns of real margin, while the report says -0.624 ns because it is
#  measured against 16.4.)
#
#  Both numbers are parsed from constr/top.sdc, so if anyone re-tunes the
#  over-constraint knob this gate keeps telling the truth automatically.
#  The violation count is still PRINTED -- it stays visible, it just no
#  longer decides pass/fail on its own.
# ============================================================================
$p030Sdc = Join-Path $root "constr\top.sdc"
$p030Period = $null
$p030Budget = $null
if (Test-Path $p030Sdc) {
  $p030SdcTxt = Get-Content $p030Sdc -Raw
  $p030M1 = [regex]::Match($p030SdcTxt, 'create_clock\s+-name\s+clk_sys\s+-period\s+([0-9.]+)')
  if ($p030M1.Success) { $p030Period = [double]$p030M1.Groups[1].Value }
  $p030M2 = [regex]::Match($p030SdcTxt, 'set_max_delay\s+-from\s+\[get_clocks\s+\{clk_sys\}\]\s+-to\s+\[get_clocks\s+\{clk_sys\}\]\s+([0-9.]+)')
  if ($p030M2.Success) { $p030Budget = [double]$p030M2.Groups[1].Value }
}

$p030RealSlack = $null
$p030RealTxt   = "n/a (need top.sdc create_clock + set_max_delay + timing_paths)"
if (($null -ne $p030Worst) -and ($null -ne $p030Period) -and ($null -ne $p030Budget)) {
  $p030RealSlack = [math]::Round($p030Worst + ($p030Period - $p030Budget), 3)
  $p030RealTxt   = ("{0} ns  (real clock {1} ns, over-constraint {2} ns)" -f $p030RealSlack, $p030Period, $p030Budget)
}

Write-Host ""
Write-Host "== P0-30 setup gate ==" -ForegroundColor Cyan
foreach ($r in $p030Rows) {
  Write-Host ("  {0,-12} setup EP={1,4}   TNS={2}" -f $r.Clock, $r.Ep, $r.Tns)
}
Write-Host ("  TOTAL setup EP = {0}   TNS = {1}   worst path slack = {2}" -f $p030EpTotal, $p030TnsTotal, $p030WorstTxt)
Write-Host ("  REAL slack (vs the actual clock) = {0}" -f $p030RealTxt) -ForegroundColor Cyan
if (($null -ne $p030Budget) -and ($null -ne $p030Period) -and ($p030Budget -lt $p030Period)) {
  Write-Host ("  NOTE: the {0} ns figure is an over-constraint (see top.sdc); the physical clock is {1} ns." -f $p030Budget, $p030Period) -ForegroundColor DarkGray
  Write-Host ("        Violations against {0} ns are printed above for visibility but do NOT fail this gate." -f $p030Budget) -ForegroundColor DarkGray
}

# ---- decision: judged against the REAL clock ----
$p030Bad = $false
$p030Reason = ""
$p030Contradiction = ($p030EpTotal -eq 0 -and $null -ne $p030Worst -and $p030Worst -lt 0)
if ($p030Contradiction) {
  Write-Host "ERROR: P0-30 -- TNS table says 0 setup endpoints but timing_paths has a" -ForegroundColor Red
  Write-Host "       negative setup slack ($p030Worst ns).  The two reports disagree;" -ForegroundColor Red
  Write-Host "       that is not a pass.  FAIL CLOSED." -ForegroundColor Red
  $p030Bad = $true
  $p030Reason = "the two timing reports disagree (TNS says 0 EP, timing_paths says negative slack)"
} elseif ($null -eq $p030RealSlack) {
  Write-Host "ERROR: P0-30 -- cannot compute the slack against the real clock:" -ForegroundColor Red
  Write-Host "       top.sdc create_clock(clk_sys) / set_max_delay(clk_sys->clk_sys) / timing_paths" -ForegroundColor Red
  Write-Host "       is missing or unparseable.  'Cannot verify' is not 'clean' => FAIL CLOSED." -ForegroundColor Red
  $p030Bad = $true
  $p030Reason = "cannot derive the real-clock slack (missing sdc numbers or timing_paths)"
} elseif ($p030RealSlack -lt 0) {
  $p030Bad = $true
  $p030Reason = ("the design does NOT meet the real {0} ns clock (real slack {1} ns)" -f $p030Period, $p030RealSlack)
}

if ($p030Bad) {
  # ---- what the bitstream is, so the message is actionable ----
  $p030Fs      = Join-Path $root "impl\pnr\Gowin2026.fs"
  $p030FsMbTxt = "n/a (no bitstream on disk)"
  $p030FsSha   = "n/a"
  if (Test-Path $p030Fs) {
    $p030FsMbTxt = ("{0} MB" -f [math]::Round((Get-Item $p030Fs).Length / 1MB, 2))
    $p030FsSha   = (Get-FileHash $p030Fs -Algorithm SHA256).Hash
  }
  Write-Host ""
  Write-Host "########################################################################" -ForegroundColor Red
  Write-Host "##  TIMING FAIL -- NOT A TIMING-CLEAN BUILD" -ForegroundColor Red
  Write-Host "########################################################################" -ForegroundColor Red
  Write-Host ("  reason                   : {0}" -f $p030Reason)
  Write-Host ("  setup-violated endpoints : {0}" -f $p030EpTotal)
  Write-Host ("  total negative slack     : {0} ns" -f $p030TnsTotal)
  Write-Host ("  worst setup path slack   : {0}" -f $p030WorstTxt)
  Write-Host ("  REAL slack (vs clock)    : {0}" -f $p030RealTxt)
  Write-Host ""
  Write-Host "  This build did NOT converge.  Bitstream on disk:" -ForegroundColor Yellow
  Write-Host ("    path   : {0}" -f $p030Fs)
  Write-Host ("    size   : {0}" -f $p030FsMbTxt)
  Write-Host ("    sha256 : {0}" -f $p030FsSha)
  Write-Host ""
  Write-Host "  MAY be burned to the board for bench testing -- the hardware still runs." -ForegroundColor Yellow
  Write-Host "  NOT a timing-clean release: do NOT archive it, do NOT ship it, and do" -ForegroundColor Yellow
  Write-Host "  NOT use it as the baseline for a comparison table." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Where to look: impl/pnr/Gowin2026_tr_content.html -> Setup Paths Table." -ForegroundColor Yellow
  Write-Host "  Evidence that would otherwise be lost: tools/archive_pnr_evidence.ps1." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  P0-30 FAIL (exit 12)." -ForegroundColor Red
  exit 12
}

if ($p030EpTotal -gt 0) {
  Write-Host ("OK  P0-30 gate: the design MEETS the real clock (real slack {0})" -f $p030RealTxt) -ForegroundColor Green
  Write-Host ("     WARN: {0} setup endpoint(s) still miss the over-constraint ({1} ns)." -f $p030EpTotal, $p030Budget) -ForegroundColor Yellow
  Write-Host "     That is the over-constraint doing its job, not a functional failure." -ForegroundColor Yellow
  Write-Host "     Keep the count visible: if it starts growing, the design IS getting slower." -ForegroundColor Yellow
} else {
  Write-Host ("OK  P0-30 gate: 0 setup violations (TNS {0})" -f $p030TnsTotal) -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Gowin build finished, exit code 0 ===" -ForegroundColor Green
Write-Host "bitstream: impl/pnr/Gowin2026.fs  (git-ignored, regenerated by this script)"
exit 0
