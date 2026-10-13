# check_no_pruning.ps1 -- gate: no SILENT signal-width / declaration defects.
#
# WHY (P1-20, 2026-10-11):
#   top.v wired `.sample_data_i (af_data[ADC_N*12-1:0])` (36 bits, ADC_N=3)
#   into calib_autotare whose port is [N_ADC*DW-1:0] = 24 bits (.N_ADC(2)).
#   iverilog said: "Pruning 12 high bits of the expression."
#   => chip 2 was silently dropped from the "still guard" coverage, and
#      raising .N_ADC would have silently changed the coverage with NO error.
#   That is the K-106 class (silent failure) in its bit-width form.
#
# WHY (implicit wire, 2026-10-11):
#   top.v:4215 had TWO declarations merged onto ONE line:
#     wire looper_dump_clip;   // comment ...        wire looper_full;
#   The second `wire looper_full;` landed AFTER the `//` => it was swallowed
#   into the comment => looper_full was never declared => iverilog made an
#   IMPLICIT 1-BIT wire. With LAYERS=1 that width happened to be right, but
#   raising LAYERS would have silently truncated full_o. Same K-106 class.
#   (Root cause is the "non-ASCII eats the following newline" trap in AGENTS.md.)
#
# CRITERION: across all tb compile logs,
#   - "Pruning" line count must be 0
#   - "implicit definition" line count must be 0
#   Baseline before the fixes: 13 Pruning lines, 139 implicit-definition lines.
#
# USAGE:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_no_pruning.ps1
#   exit 0 = pass, exit 1 = violation(s)
#
# NOTE: this file is PURE ASCII on purpose -- project rule: a .ps1 must either
#   carry a UTF-8 BOM or be pure ASCII.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir  = Join-Path $root 'sim\evidence'

if (-not (Test-Path $dir)) {
    Write-Host "check_no_pruning: no sim/evidence dir yet -- nothing to check (pass)"
    exit 0
}

$logs = Get-ChildItem -Path $dir -Filter '*.compile.log' -File -ErrorAction SilentlyContinue
if (-not $logs -or $logs.Count -eq 0) {
    Write-Host "check_no_pruning: no *.compile.log found -- run sim\tb_all.ps1 first (pass)"
    exit 0
}

$patterns = @('Pruning', 'implicit definition')
$bad = 0
$hits = @()
foreach ($f in $logs) {
    foreach ($p in $patterns) {
        $m = Select-String -Path $f.FullName -Pattern $p -Encoding utf8
        if ($m) {
            $bad = $bad + $m.Count
            $hits = $hits + $m
        }
    }
}

if ($bad -gt 0) {
    Write-Host "FAIL: $bad silent declaration/width defect line(s) found:"
    foreach ($h in $hits) {
        $line = $h.Line.Trim()
        if ($line.Length -gt 110) { $line = $line.Substring(0, 110) }
        Write-Host ("  " + $h.Filename + ":" + $h.LineNumber + ": " + $line)
    }
    Write-Host ""
    Write-Host "FIX: make the port width and the connected expression use the SAME"
    Write-Host "     localparam (see GUARD_ADC_N / LOOPER_LAYERS in rtl/top.v) --"
    Write-Host "     do not rely on a comment. For an implicit wire, the declaration"
    Write-Host "     was probably swallowed into a trailing comment -- give it its own line."
    exit 1
}

Write-Host "OK  check_no_pruning: 0 silent declaration/width defect across $($logs.Count) compile log(s)"
exit 0
