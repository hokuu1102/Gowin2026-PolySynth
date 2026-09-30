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
#   1. preflight   -- gw_sh exists, project exists, no other gw_sh running
#   2. per attempt -- clean impl/pnr, run gowin_build.ps1, watch CPU, check
#   3. retry       -- up to -MaxAttempts times (a fresh attempt is cheap)
#   4. verdict     -- 0 setup / 0 hold, Actual Fmax >= -MinFmax, .fs is NEW
#
# USAGE (from the repository root)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -MinFmax 52.5
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -MaxAttempts 1 -NoClean
#
# NOTE: pure ASCII on purpose (a .ps1 with non-ASCII bytes needs a UTF-8 BOM;
#       keeping it ASCII sidesteps that whole class of bug -- see C72/C73).
# ============================================================================

param(
    [string]$ProjectDir   = (Get-Location).Path,
    [int]   $TimeoutSec   = 1800,     # per attempt; clean runs take ~12 min
    [int]   $MaxAttempts  = 3,
    [double]$MinFmax      = 52.5,     # MHz; below this the margin is <5%
    [switch]$NoClean,                 # skip the impl/pnr wipe (for comparison)
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
Say ("clean impl  : " + (-not $NoClean))

if (-not (Test-Path $gwSh))                      { Say "FATAL: gw_sh not found" Red; exit 2 }
if (-not (Test-Path (Join-Path $ProjectDir 'Gowin2026.gprj'))) { Say "FATAL: Gowin2026.gprj not found in $ProjectDir" Red; exit 2 }
if (-not (Test-Path (Join-Path $ProjectDir 'sim\gowin_build.ps1'))) { Say "FATAL: sim\gowin_build.ps1 not found" Red; exit 2 }

$others = @(Get-Process gw_sh -ErrorAction SilentlyContinue)
if ($others.Count -gt 0) {
    Say ("FATAL: another gw_sh is already running (PID " + ($others.Id -join ',') + ") -- refusing to start a second one" ) Red
    exit 3
}
Say "preflight OK" Green

$buildLog  = Join-Path $ProjectDir 'sim\evidence\gowin_build.log'
$timingTxt = Join-Path $ProjectDir 'sim\evidence\gowin_m0_timing.txt'
$fsPath    = Join-Path $ProjectDir 'impl\pnr\Gowin2026.fs'
$pnrDir    = Join-Path $ProjectDir 'impl\pnr'

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
    } else {
        Say "NoClean: keeping whatever impl\pnr holds" Yellow
    }

    $fsBefore = if (Test-Path $fsPath) { (Get-Item $fsPath).LastWriteTime } else { [datetime]'1970-01-01' }
    $t0 = Get-Date

    # --- 2. run the build -------------------------------------------------
    $log = Join-Path $ProjectDir ("sim\evidence\pnr_run_attempt{0}.log" -f $attempt)
    Say ("launching gowin_build.ps1 (stdout -> " + $log + ")")

    $job = Start-Job -ScriptBlock {
        param($dir, $timeout, $logPath)
        Set-Location $dir
        & powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1 -BuildTimeoutSec $timeout 2>&1 |
            Tee-Object -FilePath $logPath
        "EXITCODE=$LASTEXITCODE"
    } -ArgumentList $ProjectDir, $TimeoutSec, $log

    # --- 3. watch it (CPU is the only reliable liveness signal) ----------
    #     impl/pnr/Gowin2026.log stops at "[60%] Routing Phase 0" and the
    #     routing phase prints NOTHING, so a log timestamp proves nothing.
    $stallSince = $null
    $lastCpu    = -1.0
    while ($job.State -eq 'Running') {
        Start-Sleep -Seconds 15
        $g = Get-Process gw_sh -ErrorAction SilentlyContinue
        if ($g) {
            $cpu = [double]$g.CPU        # SCALAR -- a Process object refreshes
            $ws  = [math]::Round($g.WorkingSet64 / 1MB, 0)
            $el  = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
            if ($lastCpu -ge 0) {
                $d = $cpu - $lastCpu
                if ($d -lt 0.5) {
                    if (-not $stallSince) { $stallSince = Get-Date }
                    $stalled = [math]::Round(((Get-Date) - $stallSince).TotalSeconds, 0)
                    Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  STALL {3}s" -f $el, $cpu, $ws, $stalled) Yellow
                    if ($stalled -ge 120) { Say "  CPU flat for 120 s -- killing gw_sh" Red; Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue; break }
                } else {
                    $stallSince = $null
                    Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  ok (+{3:N0}s)" -f $el, $cpu, $ws, $d)
                }
            } else {
                Say ("  t={0,5}min cpu={1,7:N0}s ws={2,5}MB  (first sample)" -f $el, $cpu, $ws)
            }
            $lastCpu = $cpu
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
        $setup = (($tl | Select-String 'Numbers of Setup Violated Endpoints' -Context 0,1).Context.PostContext -join '').Trim()
        $hold  = (($tl | Select-String 'Numbers of Hold Violated Endpoints'  -Context 0,1).Context.PostContext -join '').Trim()
        $fmax  = (($tl | Select-String 'Actual Fmax' -Context 0,1).Context.PostContext -join '').Trim()
    }
    $fmaxVal = 0.0
    if ($fmax -match '([0-9]+\.[0-9]+)') { $fmaxVal = [double]$Matches[1] }

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
