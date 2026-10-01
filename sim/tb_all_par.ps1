# tb_all_par.ps1 -- parallel driver for the full regression
#
# WHY THIS EXISTS
#   tb_all.ps1 runs the ~108 testbenches strictly one at a time. Each one is fully
#   independent: its own iverilog compile, its own vvp process, its own evidence log under
#   sim/evidence/, and its own waveform directory under build/sim/<tb>/. Nothing is shared,
#   so they can run concurrently. On a 4-core box the wall clock drops roughly 2-3x.
#
# HOW IT WORKS
#   This script does NOT reimplement the runner. It discovers the testbench list with the
#   same rule tb_all.ps1 uses, then invokes tb_all.ps1 -Filter <tb> once per testbench,
#   with at most -Jobs of those invocations alive at the same time. So the proven
#   per-testbench logic, timeouts, evidence layout and pass/fail judgement all stay in one
#   place -- only the scheduling is new.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all_par.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all_par.ps1 -Jobs 6
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all_par.ps1 -Jobs 1   # == serial
#
# NOTE ON -Jobs
#   Default is 4. Going higher than the physical core count mostly adds context switching
#   and memory pressure; this machine has been observed to degrade (PnR failures) under
#   heavy load, so do not run this concurrently with a PnR.
#
# OUTPUT
#   Per-testbench output goes to sim/evidence/<tb>.log and <tb>.compile.log exactly as in
#   the serial runner. This script prints only a one-line summary per testbench plus a
#   final tally, so its own output stays readable.

param(
    [int]$Jobs = 4,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'rtl'))) {
    # fall back: if invoked from the repo root, $PSScriptRoot is <root>\sim
    $root = (Get-Location).Path
}
$runner = Join-Path $PSScriptRoot 'tb_all.ps1'
if (-not (Test-Path $runner)) { Write-Host "ERROR: cannot find $runner"; exit 2 }

# ---- discover testbenches, same rule as tb_all.ps1 -------------------------
$tbDir = Join-Path $root 'tb'
if (-not (Test-Path $tbDir)) { Write-Host "ERROR: cannot find $tbDir"; exit 2 }
$tbs = @(
    Get-ChildItem $tbDir -Recurse -Filter 'tb_*.sv' |
        Where-Object { $_.Name -notmatch 'proj_fmt' } |
        # tool testbenches: these emit artifacts (wav exports) rather than a verdict, and
        # tb_all.ps1 skips them at run time so they never enter its tally. Excluding them
        # here keeps this driver's count directly comparable with the serial runner's.
        Where-Object { $_.BaseName -notin @('tb_export_key_wav', 'tb_export_wav') } |
        ForEach-Object { $_.BaseName } |
        Sort-Object -Unique
)
if ($tbs.Count -eq 0) { Write-Host 'ERROR: no testbenches found'; exit 2 }

Write-Host "tb_all_par: $($tbs.Count) testbenches, Jobs=$Jobs"
$t0 = Get-Date

$pass = New-Object System.Collections.ArrayList
$fail = New-Object System.Collections.ArrayList
$running = @{}          # name -> job
$queue = New-Object System.Collections.Queue
foreach ($t in $tbs) { $queue.Enqueue($t) }

function Start-One([string]$name) {
    Start-Job -ScriptBlock {
        param($r, $n)
        # IMPORTANT: do NOT judge by exit code here. Piping a native command's output with
        # 2>&1 makes PowerShell wrap stderr as ErrorRecords and leaves $LASTEXITCODE
        # unreliable -- the documented C30 trap. It produced two FALSE failures on the first
        # parallel run (tb_i2s_tx_timing and tb_looper_bar_align both logged PASS: yet came
        # back non-zero).
        #
        # The project's own criterion is "passed == total", which tb_all.ps1 prints as
        # "通过 N / 共 N". Parse that instead: it is the real contract, and it does not
        # depend on exit-code plumbing.
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $r -Filter $n 2>&1 | Out-String
        $verdict = 'unknown'
        $m = [regex]::Match($out, '\u901a\u8fc7\s+(\d+)\s*/\s*\u5171\s+(\d+)')
        if ($m.Success) {
            $got = [int]$m.Groups[1].Value
            $tot = [int]$m.Groups[2].Value
            if ($tot -gt 0 -and $got -eq $tot) { $verdict = 'pass' }
            elseif ($tot -gt 0) { $verdict = "fail($got/$tot)" }
        }
        # fall back to the testbench's own verdict lines if no tally was printed
        if ($verdict -eq 'unknown') {
            if ($out -match '(?m)^PASS:') { $verdict = 'pass' }
            elseif ($out -match '(?m)^(FAIL|FATAL):') { $verdict = 'fail(verdict-line)' }
        }
        "$n`n__VERDICT__=$verdict`n$out"
    } -ArgumentList $runner, $name
}

# prime the pool
while ($queue.Count -gt 0 -and $running.Count -lt $Jobs) {
    $n = $queue.Dequeue()
    $running[$n] = Start-One $n
    Write-Host "  + $n"
}

# drain, refilling as slots free up
while ($running.Count -gt 0) {
    $done = Wait-Job -Job @($running.Values) -Any -Timeout $TimeoutSec
    if (-not $done) {
        Write-Host "  ! no job finished within ${TimeoutSec}s -- still waiting"
        continue
    }
    foreach ($j in @($done)) {
        $name = $null
        foreach ($k in @($running.Keys)) { if ($running[$k].Id -eq $j.Id) { $name = $k; break } }
        if (-not $name) { continue }
        $out = Receive-Job -Job $j
        Remove-Job -Job $j -Force
        $running.Remove($name)
        $txt = ($out | Out-String)
        $verdict = 'unknown'
        $m = [regex]::Match($txt, '__VERDICT__=(\S+)')
        if ($m.Success) { $verdict = $m.Groups[1].Value }
        if ($verdict -eq 'pass') {
            [void]$pass.Add($name)
            Write-Host "  ok   $name"
        } else {
            [void]$fail.Add("$name  [$verdict]")
            Write-Host "  FAIL $name  ($verdict)"
        }
        if ($queue.Count -gt 0) {
            $n2 = $queue.Dequeue()
            $running[$n2] = Start-One $n2
            Write-Host "  + $n2"
        }
    }
}

$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
Write-Host ''
Write-Host "================ tb_all_par summary ================"
Write-Host ("passed {0} / total {1}   in {2} min   (Jobs={3})" -f $pass.Count, $tbs.Count, $mins, $Jobs)
if ($fail.Count -gt 0) {
    Write-Host 'failed:'
    foreach ($f in $fail) { Write-Host "  $f" }
    Write-Host 'NOTE: re-run a single one with:  powershell -File sim\tb_all.ps1 -Filter <name>'
    exit 1
}
Write-Host 'all passed'
exit 0
