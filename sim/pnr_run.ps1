# ============================================================================
# pnr_run.ps1 -- a robust Gowin PnR driver.
#
# WHY THIS EXISTS
#   Gowin's `run all` is INCREMENTAL: it reuses whatever is left in impl/pnr.
#   After a failed routing attempt that state is poisoned, and every following
#   run re-enters the same dead end.  Observed on 2026-09-30:
#
#     tree / impl state            result
#     ---------------------------  ---------------------------
#     stepB   (fresh worktree)      OK   ~12 min
#     stepC   (fresh worktree)      OK   ~12 min
#     deliver (first ever run)      OK   ~12 min      <-- produced the .fs
#     deliver (has previous .p)     STUCK 28 min
#     deliver (has previous .p)     STUCK 30 min
#     deliver (has previous .p)     STUCK 17+ min
#
#   Correlation was 6/6.  The fix is therefore: DELETE impl/pnr BEFORE EVERY
#   ATTEMPT.  It is regenerated anyway; the reports that matter are copied to
#   sim/evidence/ by gowin_build.ps1.
#
# WHAT IT DOES
#   1. preflight   -- gw_sh exists, project exists, and no other gw_sh that is
#                     REALLY building THIS project is running.  T4 (2026-10-03):
#                     probes and zombie processes do NOT count as occupancy --
#                     see the long note at the preflight below.
#   2. per attempt -- clean impl/pnr AND impl/gwsynthesis, run gowin_build.ps1,
#                     watch CPU, check.  T2 (2026-10-03): synthesis is
#                     incremental, so a clean PnR attempt must wipe
#                     impl/gwsynthesis too or its T_Lut is not comparable.
#   3. retry       -- up to -MaxAttempts times (a fresh attempt is cheap)
#   4. verdict     -- 0 setup / 0 hold, Actual Fmax >= -MinFmax, .fs is NEW
#
# USAGE (from the repository root)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -MinFmax 51.5
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -MaxAttempts 1 -NoClean
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -KeepSyn
#       (-KeepSyn = keep impl/gwsynthesis, i.e. INCREMENTAL synthesis.  Only for
#        deliberately measuring the incremental path; the T_Lut it reports is
#        NOT comparable with any other run.  It is shouted about when used.)
#
# NOTE: pure ASCII on purpose (a .ps1 with non-ASCII bytes needs a UTF-8 BOM;
#       keeping it ASCII sidesteps that whole class of bug -- see C72/C73).
# ============================================================================

param(
    [string]$ProjectDir   = (Get-Location).Path,
    [int]   $TimeoutSec   = 1800,     # per attempt; clean runs take ~12 min
    [int]   $MaxAttempts  = 3,
    [double]$MinFmax      = 51.5,     # MHz; margin gate = 3% (LOWERED from 5% on 2026-10-01 by user ruling:
                                      #   the 5% figure's evidence basis was retracted -- the board anomaly
                                      #   that motivated it turned out to be a CODE bug, not a timing issue.
                                      #   At 3% a build needs Fmax >= 51.5 MHz; 2% (51.0) was judged too tight
                                      #   to absorb temperature/voltage drift.)
    [switch]$NoClean,                 # skip the impl/pnr wipe (for comparison)
    [switch]$KeepSyn,                 # T2: keep impl/gwsynthesis (incremental synthesis --
                                      #     the T_Lut is then NOT comparable; see the note
                                      #     in the clean step below)
    [switch]$SkipRegression           # do not run the full regression afterwards
)

$ErrorActionPreference = 'Continue'
$gwSh = 'C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe'
$stamp = Get-Date -Format 'HH:mm:ss'

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor $color
}
function Rule([string]$title) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  " + $title) -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------- preflight
Rule "PnR driver -- preflight"
Say ("project dir : " + $ProjectDir)
Say ("gw_sh       : " + $gwSh)
Say ("timeout     : " + $TimeoutSec + " s per attempt")
Say ("attempts    : " + $MaxAttempts)
Say ("min Fmax    : " + $MinFmax + " MHz")
Say ("clean impl  : " + (-not $NoClean) + "  (impl\pnr" + $(if ($KeepSyn) { " only; impl\gwsynthesis KEPT => INCREMENTAL" } else { " + impl\gwsynthesis" }) + ")")

if (-not (Test-Path $gwSh))                      { Say "FATAL: gw_sh not found" Red; exit 2 }
if (-not (Test-Path (Join-Path $ProjectDir 'Gowin2026.gprj'))) { Say "FATAL: Gowin2026.gprj not found in $ProjectDir" Red; exit 2 }
if (-not (Test-Path (Join-Path $ProjectDir 'sim\gowin_build.ps1'))) { Say "FATAL: sim\gowin_build.ps1 not found" Red; exit 2 }

# ---------------------------------------------------------------------------
# T4 (2026-10-03): "another gw_sh is already running" must NOT be decided by
# Get-Process alone -- that check was fooled by a ZOMBIE and really did block a
# PnR run (transcript: sim/evidence/p5-adsr-20261003/pnr_run_zombie_blocked.log).
#
#   OBSERVED: PID 37832 (`gw_sh.exe _probe.tcl`) was already DEAD -- `taskkill
#   /F /PID 37832` answered "There is no running instance of the task" -- yet
#   Get-Process AND Get-CimInstance Win32_Process kept listing it, and it could
#   not be killed.  The old `if (@(Get-Process gw_sh).Count -gt 0) { exit 3 }`
#   therefore refused to start a build that was perfectly safe to start.
#
# THE CRITERION -- what counts as OCCUPANCY (do not "simplify" it back):
#   A gw_sh is a REAL conflict only if we can positively tie it to THIS project:
#     (1) its OWN command line mentions `gowin_build` or a `.gprj`, OR
#     (2) its own command line runs the build script we use (`build_cli.tcl` --
#         that is what sim/gowin_build.ps1 passes to gw_sh) AND walking its
#         parent chain (<= 4 hops) reaches a process whose command line mentions
#         `gowin_build` or `.gprj`.
#   Rule (2) exists because OUR build's command line is just "build_cli.tcl",
#   which by itself says nothing about WHICH project it builds -- the parent
#   chain is what ties it to this repository.
#
#   Everything else is NOT occupancy:
#     - probe runs (`_probe.tcl` / `_synprobe.tcl` / `_p5_run.tcl` / anything
#       under %TEMP%) work in their own directory and never touch impl/ here;
#     - a process whose command line we cannot read is reported but does NOT
#       block: it cannot be tied to this project, and blocking on it is exactly
#       the zombie false positive above.
#
#   The protection this replaced is still in force: a genuine second build of
#   the ROOT project is still refused with exit 3.
# ---------------------------------------------------------------------------
function Test-RootProjectCmd([string]$cmd) {
    if (-not $cmd) { return $false }
    return (($cmd -match 'gowin_build') -or ($cmd -match '\.gprj'))
}

# Every gw_sh we can see, with the command line CIM gives us ('' if unreadable).
$gwProcs = @(Get-CimInstance Win32_Process -Filter "Name='gw_sh.exe'" -ErrorAction SilentlyContinue)
$blockers = @()
$ignored  = @()

foreach ($gp in $gwProcs) {
    $gpid = [int]$gp.ProcessId
    $cmd  = [string]$gp.CommandLine
    $hit  = Test-RootProjectCmd $cmd
    if ((-not $hit) -and ($cmd -match 'build_cli\.tcl')) {
        $anc = $gpid
        for ($hop = 0; $hop -lt 4 -and (-not $hit); $hop++) {
            $par = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $anc) -ErrorAction SilentlyContinue
            if (-not $par) { break }
            if (Test-RootProjectCmd ([string]$par.CommandLine)) { $hit = $true; break }
            $anc = [int]$par.ParentProcessId
            if ($anc -le 0) { break }
        }
    }
    $desc = "PID {0} [{1}]" -f $gpid, $(if ($cmd) { $cmd.Trim() } else { '<command line unavailable>' })
    if ($hit) { $blockers += $desc } else { $ignored += $desc }
}

if ($gwProcs.Count -eq 0) {
    # CIM is how we read command lines.  If it yields nothing while Get-Process
    # still sees gw_sh, the guard below degrades to "no occupancy" -- say so out
    # loud instead of passing silently (a silently-green guard is the failure
    # class this project keeps hitting; see C83 "probe false green").
    $seen = @(Get-Process gw_sh -ErrorAction SilentlyContinue)
    if ($seen.Count -gt 0) {
        Say ("WARN: Get-Process sees {0} gw_sh but CIM returned no command lines." -f $seen.Count) Yellow
        Say "      Cannot tell whether one of them builds THIS project -- NOT blocking (see T4 note above)." Yellow
    }
}
if ($ignored.Count -gt 0) {
    Say ("NOTE: ignoring {0} gw_sh that is NOT building this project (probe or zombie):" -f $ignored.Count) DarkGray
    foreach ($i in $ignored) { Say ("        " + $i) DarkGray }
    Say "      (a dead-but-still-listed gw_sh cannot be killed; it must not block a build)" DarkGray
}
if ($blockers.Count -gt 0) {
    Say "FATAL: another gw_sh IS building THIS project -- refusing to start a second one:" Red
    foreach ($b in $blockers) { Say ("        " + $b) Red }
    exit 3
}
Say "preflight OK" Green

$buildLog  = Join-Path $ProjectDir 'sim\evidence\gowin_build.log'
$timingTxt = Join-Path $ProjectDir 'sim\evidence\gowin_m0_timing.txt'
$fsPath    = Join-Path $ProjectDir 'impl\pnr\Gowin2026.fs'
$pnrDir    = Join-Path $ProjectDir 'impl\pnr'
$synDir    = Join-Path $ProjectDir 'impl\gwsynthesis'   # T2 -- see the clean step

# ---------------------------------------------------------------- attempts
$verdicts = @()

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Rule ("attempt {0} of {1}" -f $attempt, $MaxAttempts)

    # --- 1. clean the incremental state (THE fix) -------------------------
    if (-not $NoClean) {
        if (Test-Path $pnrDir) {
            $n = @(Get-ChildItem $pnrDir -File -ErrorAction SilentlyContinue).Count
            Remove-Item $pnrDir -Recurse -Force -ErrorAction SilentlyContinue
            Say ("cleaned impl\pnr (" + $n + " files removed)  <-- this is the fix") Green
        } else {
            Say "impl\pnr already absent (clean)" Green
        }

        # T2 (2026-10-03): a "clean attempt" must also mean a clean SYNTHESIS.
        # `run all` writes into impl/gwsynthesis and reads back whatever is
        # there, so a resource number produced on top of a previous build's
        # leftovers is not trustworthy for comparison.  This repo's own notes
        # only obtained the clean figure AFTER wiping it (P5-1 ADSR share:
        # T_Lut 37075 -> 31672).
        # MEASURED 2026-10-03 with Gowin V1.9.12.03, same RTL:
        #     clean       T_Lut 31672(889)   164.2 s / 177.1 s
        #     incremental T_Lut 31672(889)   164.8 s / 164.9 s
        #     leftovers from a DIFFERENT rtl revision (the 37075 design) also
        #     gave 31672, and that run's console log was BYTE-IDENTICAL to the
        #     clean run's -- so on this toolchain the wipe costs ~nothing and
        #     gw_sh appears to re-synthesise fully either way.
        # The wipe is therefore cheap insurance rather than a measured fix: it
        # removes the whole class of "did the leftovers change the number?"
        # doubt for the price of a synthesis we pay anyway.  Default: wipe it.
        # -KeepSyn opts out (for deliberately measuring the incremental path).
        if (-not $KeepSyn) {
            if (Test-Path $synDir) {
                $ns = @(Get-ChildItem $synDir -Recurse -File -ErrorAction SilentlyContinue).Count
                Remove-Item $synDir -Recurse -Force -ErrorAction SilentlyContinue
                Say ("cleaned impl\gwsynthesis (" + $ns + " files) -- T_Lut is now comparable") Green
            } else {
                Say "impl\gwsynthesis already absent (clean synthesis)" Green
            }
        } else {
            Say "KeepSyn: impl\gwsynthesis KEPT -- synthesis is incremental this run" Yellow
            Say "         THIS RUN'S T_Lut IS NOT COMPARABLE WITH ANY OTHER RUN" Yellow
        }
    } else {
        Say "NoClean: keeping whatever impl\pnr holds" Yellow
    }

    $fsBefore = if (Test-Path $fsPath) { (Get-Item $fsPath).LastWriteTime } else { [datetime]'1970-01-01' }
    $t0 = Get-Date

    # --- 2. run the build -------------------------------------------------
    $log = Join-Path $ProjectDir ("sim\evidence\pnr_run_attempt{0}.log" -f $attempt)
    Say ("launching gowin_build.ps1 (stdout -> " + $log + ")")

    $job = Start-Job -ScriptBlock {
        param($dir, $timeout, $logPath, $keepSyn)
        Set-Location $dir
        $extra = @()
        if ($keepSyn) { $extra = @('-KeepSyn') }
        & powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1 -BuildTimeoutSec $timeout @extra 2>&1 |
            Tee-Object -FilePath $logPath
        "EXITCODE=$LASTEXITCODE"
    } -ArgumentList $ProjectDir, $TimeoutSec, $log, ([bool]$KeepSyn)
    #     NOTE (2026-10-03): the cast MUST stay parenthesised.  In ARGUMENT mode
    #     PowerShell does not parse `[bool]$x` as a cast -- it passes the STRING
    #     "[bool]False", which is truthy, so -KeepSyn reached gowin_build.ps1 on
    #     every run (observed in the live process tree: the child command line
    #     read "... -File sim\gowin_build.ps1 -BuildTimeoutSec 1800 -KeepSyn"
    #     even though pnr_run.ps1 was invoked without -KeepSyn).

    # --- 3. watch it (CPU is the only reliable liveness signal) ----------
    #     impl/pnr/Gowin2026.log stops at "[60%] Routing Phase 0" and the
    #     routing phase prints NOTHING, so a log timestamp proves nothing.
    #
    #     T4 (2026-10-03): sample only gw_sh processes that are actually
    #     BUILDING.  The old `Get-Process gw_sh` also matched the dead-but-listed
    #     zombie above, which would have (a) mis-reported its frozen CPU as our
    #     build's CPU and (b) let the stall-killer shoot the wrong PID.
    #     Criterion here mirrors the preflight: command line runs
    #     `build_cli.tcl` or names a `.gprj`.
    $stallSince = $null
    $lastCpu    = -1.0
    while ($job.State -eq 'Running') {
        Start-Sleep -Seconds 15
        $ids = @(Get-CimInstance Win32_Process -Filter "Name='gw_sh.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { ([string]$_.CommandLine) -match 'build_cli\.tcl' -or ([string]$_.CommandLine) -match '\.gprj' } |
                 ForEach-Object { [int]$_.ProcessId })
        $g = @()
        if ($ids.Count -gt 0) { $g = @(Get-Process -Id $ids -ErrorAction SilentlyContinue) }
        if ($g.Count -gt 0) {
            # NOTE (2026-10-03): WorkingSet64 routinely exceeds Int32.MaxValue
            # (~2.1 GB) during routing -- accumulate in [long], not [int], or the
            # += throws "Cannot convert value ... to type System.Int32" and the
            # memory column silently reports 0 MB (observed on the first run).
            $cpu = 0.0; $ws = 0L
            foreach ($x in $g) { $cpu += [double]$x.CPU; $ws += [long]$x.WorkingSet64 }
            $ws = [math]::Round($ws / 1MB, 0)
            $el  = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
            if ($lastCpu -ge 0) {
                $d = $cpu - $lastCpu
                if ($d -lt 0.5) {
                    if (-not $stallSince) { $stallSince = Get-Date }
                    $stalled = [math]::Round(((Get-Date) - $stallSince).TotalSeconds, 0)
                    Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  STALL {3}s" -f $el, $cpu, $ws, $stalled) Yellow
                    if ($stalled -ge 120) {
                        Say ("  CPU flat for 120 s -- killing OUR gw_sh (PID " + ($g.Id -join ',') + ")") Red
                        foreach ($x in $g) { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue }
                        break
                    }
                } else {
                    $stallSince = $null
                    Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  ok (+{3:N0}s)" -f $el, $cpu, $ws, $d)
                }
            } else {
                Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  (first sample)" -f $el, $cpu, $ws)
            }
            $lastCpu = $cpu
        } else {
            $el = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
            if ($lastCpu -ge 0) {
                Say ("  t={0,5}min (our build gw_sh has exited -- job is finishing up)" -f $el) DarkGray
            } else {
                Say ("  t={0,5}min (no build gw_sh yet -- powershell job is starting up)" -f $el) DarkGray
            }
        }
    }

    $null = Wait-Job $job -Timeout 30
    $jobOut = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

    # --- 4. judge ---------------------------------------------------------
    $fsNew = (Test-Path $fsPath) -and ((Get-Item $fsPath).LastWriteTime -gt $fsBefore)
    $setup = '?'; $hold = '?'; $fmax = '?'
    if (Test-Path $timingTxt) {
        $tl = Get-Content $timingTxt -Encoding UTF8
        # NOTE 2026-09-30: Gowin prints the table column separator '|' on its own line,
        # so the line AFTER the label is e.g. "0 |".  Trim() alone leaves "0 |", and the
        # ($setup -eq '0') test further down then fails for EVERY build -- a perfect report
        # was being reported as FAILED (observed: 0/0 + Fmax 53.821 MHz => "FAIL").
        # Keep digits only.  If the label/value is missing the result is "" and the verdict
        # still fails -- i.e. the safe direction is preserved.
        # NOTE 2026-10-03 (N7 residual): the setup/hold value used to be read from the line
        # IMMEDIATELY after the label (-Context 0,1).  That is the same positional-assumption
        # bug class already fixed twice in this file (the Fmax fixed 12-line window, and the
        # '|' separator).  Gowin emits the label row, then a line like "0 |" -- but that
        # layout can shift, and a shifted layout silently yields "" (which then FAILS the
        # verdict).  Scan FORWARD from the label for the first line whose non-'|',
        # non-whitespace content is ALL DIGITS, within a bounded window.  Missing value =>
        # "" => the verdict still FAILS, i.e. the safe direction is preserved.
        function Get-StatValue([string[]]$lines, [string]$label) {
            $li = ($lines | Select-String -SimpleMatch $label | Select-Object -First 1).LineNumber
            if (-not $li) { return '' }
            $stop = [Math]::Min($lines.Count - 1, $li + 8)
            for ($k = $li; $k -le $stop; $k++) {
                $core = ($lines[$k] -replace '[|\s]', '')
                if ($core -match '^[0-9]+$') { return $core }
            }
            return ''
        }
        $setup = Get-StatValue $tl 'Numbers of Setup Violated Endpoints'
        $hold  = Get-StatValue $tl 'Numbers of Hold Violated Endpoints'
        # The Gowin timing text puts the LABEL row first and the VALUES several rows
        # later (Actual Fmax | Logic Level | Entity | 50.000(MHz) | 52.575(MHz) | 2 |),
        # so reading the line right after "Actual Fmax" yields "Logic Level", not a number.
        # Take the LAST "NNN.NNN(MHz)" that appears AFTER the "Actual Fmax" label.
        #
        # NOTE 2026-09-30 (second pass): this used to be a FIXED 12-line window
        # ($idx..$idx+12).  That is the same class of bug as the setup/hold one fixed
        # earlier tonight -- a positional assumption about a tool-generated report.
        # Scan from the label to EOF instead: position-independent and it survives the
        # report growing.  The Max Frequency Summary is the LAST section of this file,
        # and within its row the constraint (50.000) comes BEFORE the actual Fmax, so the
        # LAST match in the range is the Actual Fmax.
        $idx = ($tl | Select-String 'Actual Fmax' | Select-Object -First 1).LineNumber
        $tail = if ($idx) { $tl[($idx - 1)..($tl.Count - 1)] } else { @() }
        $m = @($tail | Select-String -Pattern '([0-9]+\.[0-9]+)\(MHz\)' -AllMatches)
        if ($m.Count -gt 0) { $fmax = $m[-1].Matches[0].Groups[1].Value + ' MHz' } else { $fmax = '?' }
    }
    $fmaxVal = 0.0
    if ($fmax -match '([0-9]+\.[0-9]+)') { $fmaxVal = [double]$Matches[1] }

    # NOTE 2026-10-03 (D1): if this attempt did NOT produce a NEW bitstream, the timing
    # text is STALE -- it belongs to an EARLIER build.  Printing those numbers made a
    # timed-out attempt look like "0 setup / 0 hold / Fmax 52.798" (observed 2026-10-03:
    # the number came from a previous run).  $fsNew already fails the verdict below; here
    # we only stop the printed numbers from lying.
    if (-not $fsNew) { $setup = 'n/a'; $hold = 'n/a'; $fmax = 'n/a'; $fmaxVal = 0.0 }

    $ok = $fsNew -and ($setup -eq '0') -and ($hold -eq '0') -and ($fmaxVal -ge $MinFmax)

    $verdicts += [pscustomobject]@{
        Attempt = $attempt; Minutes = $elapsed; FsNew = $fsNew
        Setup = $setup; Hold = $hold; Fmax = $fmaxVal; Pass = $ok
    }

    Say ("attempt {0}: {1} min | .fs new={2} | setup={3} hold={4} | Fmax={5} MHz | {6}" -f `
         $attempt, $elapsed, $fsNew, $setup, $hold, $fmaxVal, $(if ($ok) { 'PASS' } else { 'FAIL' })) `
         $(if ($ok) { 'Green' } else { 'Red' })

    if ($ok) { break }
    if ($attempt -lt $MaxAttempts) { Say "retrying with a clean impl/pnr ..." Yellow }
}

# ---------------------------------------------------------------- verdict
Rule "VERDICT"
$verdicts | Format-Table -AutoSize | Out-String | Write-Host

$best = $verdicts | Where-Object { $_.Pass } | Select-Object -First 1
if ($best) {
    Say ("PnR PASSED on attempt " + $best.Attempt + " in " + $best.Minutes + " min") Green
    Say ("  setup=" + $best.Setup + "  hold=" + $best.Hold + "  Fmax=" + $best.Fmax + " MHz")
    Say ("  bitstream: " + $fsPath)
    Say ("  sha256   : " + (Get-FileHash $fsPath -Algorithm SHA256).Hash)
    if (-not $SkipRegression) {
        Say "NEXT: run the full regression (sim\tb_all.ps1) -- criterion: passed == total" Cyan
    }
    exit 0
} else {
    Say "PnR FAILED on all attempts.  What to try next:" Red
    Say "  1. the design may genuinely be too dense/tight -- check T_Lut and the Fmax margin" Yellow
    Say "  2. try a different placement/route seed (Gowin: set_option -route_option / -place_option)" Yellow
    Say "  3. compare against a known-good worktree (stepB / stepC) with the SAME script" Yellow
    exit 1
}
