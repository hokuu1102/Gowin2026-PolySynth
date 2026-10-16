# check_static.ps1 -- pre-push static gates that need NO PnR and NO simulation.
#
# WHY (2026-10-16):
#   gowin_build.ps1 runs the HDL-no-BOM gate at its TAIL (L736-750) -- i.e. a BOM
#   problem is only discovered AFTER a ~10-minute synthesis+place. The .ps1
#   encoding gate is not wired into the build at all (it is a manual discipline).
#   The other static gates (async reset, observability wires, .gprj registration,
#   algorithm options, .gprj XML comment) are all pure file reads but sit deep in
#   the build. This script pulls every static gate together so they run in seconds
#   BEFORE committing or building.
#
# USAGE: powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_static.ps1
#   exit 0 = all static gates pass
#   exit 1 = at least one gate failed (read the output)
#
# NOTE: this file is PURE ASCII on purpose (project rule: a .ps1 must either carry
#   a UTF-8 BOM or be pure ASCII). Keeping it ASCII sidesteps the BOM rule entirely.
#   Gates A3-A7 mirror checks already inside sim/gowin_build.ps1; A1/A2 are the two
#   that are missing or misplaced there.

param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
$fails = 0
$passes = 0

function Pass([string]$msg) {
    $script:passes++
    if (-not $Quiet) { Write-Host ("[PASS] " + $msg) }
}
function Fail([string]$msg) {
    $script:fails++
    Write-Host ("[FAIL] " + $msg) -ForegroundColor Red
}

# ---- A1: HDL sources must NOT carry a UTF-8 BOM -------------------------------
#   Same criterion as gowin_build.ps1 exit 11 / tools/check_no_bom.ps1.
#   A BOM makes iverilog fail to parse that file's module, so every testbench
#   instantiating it reports 'Unable to find the root module <tb>' -- naming the
#   TESTBENCH, not the broken RTL.
$bomGate = Join-Path $PSScriptRoot 'check_no_bom.ps1'
if (Test-Path $bomGate) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $bomGate *> $null
    if ($LASTEXITCODE -eq 0) { Pass "A1  HDL sources have no UTF-8 BOM" }
    else { Fail "A1  HDL source(s) carry a UTF-8 BOM -- run tools\check_no_bom.ps1" }
} else {
    Fail "A1  tools\check_no_bom.ps1 missing"
}

# ---- A2: every .ps1 must be BOM-flagged OR pure ASCII -------------------------
#   Same criterion as tools/check_ps1_encoding.ps1 (gowin_build.ps1 does NOT run this).
#   The edit tool strips UTF-8 BOMs, so any .ps1 edited with it must be re-checked.
$ps1Gate = Join-Path $PSScriptRoot 'check_ps1_encoding.ps1'
if (Test-Path $ps1Gate) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ps1Gate *> $null
    if ($LASTEXITCODE -eq 0) { Pass "A2  .ps1 encoding (BOM or pure ASCII)" }
    else { Fail "A2  .ps1 encoding violation -- run tools\check_ps1_encoding.ps1 (edit strips BOMs)" }
} else {
    Fail "A2  tools\check_ps1_encoding.ps1 missing"
}

# ---- A3: zero async-reset sensitivity lists (P0-23) ---------------------------
#   Mirrors gowin_build.ps1 L573-587 (exit 7). rst_sync releases synchronously;
#   feeding it to an async reset port re-asynchronises the release.
$asyncHits = @()
Get-ChildItem -Path (Join-Path $root 'rtl') -Recurse -Include *.v, *.sv -File -ErrorAction SilentlyContinue | ForEach-Object {
    $h = @(Select-String -Path $_.FullName -Pattern '^\s*always\s*@\s*\(\s*posedge\s+\w+\s+or\s+negedge' -ErrorAction SilentlyContinue)
    if ($h.Count -gt 0) { $asyncHits += $h }
}
if ($asyncHits.Count -eq 0) { Pass "A3  P0-23: 0 async-reset sensitivity lists" }
else {
    Fail ("A3  P0-23: " + $asyncHits.Count + " async-reset list(s):")
    foreach ($h in $asyncHits) { Write-Host ("        " + $h.Path + ":" + $h.LineNumber) }
}

# ---- A4: P0-29 observability wires must have a consumer -----------------------
#   Mirrors gowin_build.ps1 L657-714 (exit 9). A wire that appears only in its
#   declaration + port map is pruned by synthesis, making overflow/drop/param-
#   misconfiguration invisible on the board.
$topText = Get-Content (Join-Path $root 'rtl\top.v') -Raw
$critical = @('ee_ovf','ee_lost','sa_overflow','mg_overflow','looper_overflow','txf_ovf',
              'at_fail','at_skip','met_cfg_warn','drm_cfg_warn','slide_on_r','as_seen',
              'eu_resync_cnt','eu_frame_cnt')
$dead = @()
foreach ($w in $critical) {
    $cnt = ([regex]::Matches($topText, [regex]::Escape($w))).Count
    $need = 5; if ($w -ne 'slide_on_r') { $need = 3 }
    if ($cnt -lt $need) { $dead += ("$w ($cnt, need $need)") }
}
if ($dead.Count -eq 0) { Pass ("A4  P0-29: all " + $critical.Count + " observability wires have a consumer") }
else {
    Fail "A4  P0-29: observability wires with no consumer (synthesis will prune them):"
    foreach ($d in $dead) { Write-Host ("        " + $d) }
}

# ---- A5: modules instantiated by top.v must be registered in .gprj ------------
#   Mirrors gowin_build.ps1 L104-129 (exit 3, second gate). An unregistered file
#   is SILENTLY omitted from PnR, so the timing evidence is a byte-copy of the
#   previous build -- worse than no PnR.
$gprjText = Get-Content (Join-Path $root 'Gowin2026.gprj') -Raw
$missing = @()
Get-ChildItem -Path (Join-Path $root 'rtl') -Recurse -Include *.v, *.sv -File | ForEach-Object {
    if ($_.Name -like 'tb_*') { return }
    if ($_.DirectoryName -match '\\bringup$') { return }
    if ($_.Name -eq 'top.v') { return }
    $mod = $_.BaseName
    if ($topText -notmatch ("(?m)^\s*" + [regex]::Escape($mod) + "\s*#?\s*\(")) { return }
    $rel = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
    if ($gprjText -notmatch [regex]::Escape($rel)) { $missing += $rel }
}
if ($missing.Count -eq 0) { Pass "A5  .gprj: every top.v-instantiated module is registered" }
else {
    Fail "A5  .gprj: instantiated but NOT registered (PnR would silently omit them):"
    foreach ($m in $missing) { Write-Host ("        " + $m) }
}

# ---- A6: PnR algorithm options must be 0/0/0 ----------------------------------
#   Mirrors gowin_build.ps1 L74-89 (exit 3, first gate). Map_Option was the one
#   that escaped the original guard on 2026-10-15 and produced 676 unrouted nets.
$pcPath = Join-Path $root 'impl\Gowin2026_process_config.json'
if (Test-Path $pcPath) {
    $pcRaw = [IO.File]::ReadAllText($pcPath)
    $bad = @()
    foreach ($k in 'Map_Option','Place_Option','Route_Option') {
        $v = [regex]::Match($pcRaw, '"' + $k + '"\s*:\s*"([^"]*)"').Groups[1].Value
        if ($v -ne '0') { $bad += ("$k=$v") }
    }
    if ($bad.Count -eq 0) { Pass "A6  PnR options Map/Place/Route all 0" }
    else { Fail ("A6  PnR options non-default: " + ($bad -join ' ')) }
} else {
    Pass "A6  PnR options: process config absent (Gowin uses defaults 0/0/0)"
}

# ---- A7: .gprj XML comments must not contain a bare '--' ----------------------
#   XML forbids '--' inside a comment; Gowin reports 'invalid project file' with
#   NO line number, which reads like a path error but is actually comment content.
$gprjRaw = [IO.File]::ReadAllText((Join-Path $root 'Gowin2026.gprj'))
$bareDash = @()
foreach ($m in [regex]::Matches($gprjRaw, '--')) {
    $i = $m.Index
    if ($gprjRaw.Substring([Math]::Max(0, $i - 2), 2) -eq '<!') { continue }
    if ($gprjRaw.Substring($i + 2, 2).StartsWith('>')) { continue }
    $line = (($gprjRaw.Substring(0, $i) -split "`n").Count)
    $bareDash += $line
}
if ($bareDash.Count -eq 0) { Pass "A7  .gprj XML comments free of bare '--'" }
else {
    Fail ("A7  .gprj: bare '--' in XML comment at line(s) " + ($bareDash -join ', '))
}

Pop-Location

Write-Host ""
if ($fails -gt 0) {
    Write-Host ("STATIC CHECK: " + $passes + " passed / " + ($passes + $fails) + "  ->  " + $fails + " FAILED") -ForegroundColor Red
    Write-Host "These gates are pure file reads -- a failure here would otherwise cost a"
    Write-Host "10-minute synthesis before being noticed (or never be noticed at all)."
    exit 1
}
Write-Host ("STATIC CHECK: " + $passes + " passed / " + $passes + "  ->  all static gates green") -ForegroundColor Green
exit 0
