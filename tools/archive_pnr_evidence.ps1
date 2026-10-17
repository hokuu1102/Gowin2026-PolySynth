# archive_pnr_evidence.ps1 -- snapshot the FULL timing evidence of one PnR run into
#                             a git-tracked, append-only archive.
#
# WHY THIS EXISTS (2026-10-17, paid for with real evidence loss):
#
#   sim/gowin_build.ps1 WIPES impl/pnr/ at the start of every run (see its
#   line ~210: `Remove-Item $pnrDir -Recurse -Force`), and impl/ is git-ignored.
#   gowin_build.ps1 only persists THREE summary blocks into
#   sim/evidence/gowin_m0_timing.txt (its lines 342-361):
#       STA Tool Run Summary  (only the VIOLATION COUNTS, not the paths)
#       Clock Summary
#       Max Frequency Summary
#
#   Everything else -- the actual Setup/Recovery/Removal/MinPulseWidth PATH
#   TABLES -- exists ONLY inside the wiped HTML.  Measured cost on 2026-10-17:
#
#     * the 4 serial_clk setup violations (TNS -2.621) lost their From/To
#       detail permanently when the 21:38 respin wiped impl/pnr;
#     * the recovery detail was gone too, so the -0.910/-0.652/-0.555/-0.504
#       OSER10/RESET numbers below are from an EARLIER extraction of the same
#       run and survive only because a transcript quoted them.
#
#   A gap that destroys its own evidence means the problem can never be
#   gated.  This script is the fix: call it right after gowin_build.ps1.
#
# USAGE (run from anywhere, AFTER a successful build):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\archive_pnr_evidence.ps1 -Label respin-2128 -Note "same RTL as 20:46"
#
#   exit 0 = archived
#   exit 1 = nothing to archive (impl/pnr/Gowin2026_tr_content.html absent)
#   exit 2 = impl/pnr is present but the HTML is stale (older than -MaxAgeMin)
#
# NOTE: this file is deliberately PURE ASCII (project rule for .ps1: UTF-8 BOM
#       or pure ASCII -- see AGENTS.md "ps1 BOM" section).  No BOM is added.

param(
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Note = "",
    #  A fresh report is NEWER than the build that produced it.  If the HTML is
    #  older than this many minutes, refuse: it belongs to an ALREADY-WIPED
    #  run and archiving it would publish another run's numbers (the exact
    #  class of failure documented at gowin_build.ps1:135-141).
    [int]$MaxAgeMin = 120,
    [string]$DestRoot = "build\pnr_evidence"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$pnr   = Join-Path $root "impl\pnr"
$src   = Join-Path $pnr  "Gowin2026_tr_content.html"
$paths = Join-Path $pnr  "Gowin2026.timing_paths"
$rpt   = Join-Path $pnr  "Gowin2026.rpt.txt"
$fs    = Join-Path $pnr  "Gowin2026.fs"

if (-not (Test-Path $src)) {
    Write-Host "ERROR: no $src -- nothing to archive." -ForegroundColor Red
    Write-Host "       (impl/pnr was wiped by the next gowin_build.ps1 run, or no build has run.)" -ForegroundColor Red
    Pop-Location
    exit 1
}

# ---- freshness guard -------------------------------------------------------
#  The whole point of this tool is to never publish stale evidence.  Compare
#  against the build LOG, which gowin_build.ps1 writes on every run.
$ageOk = $false
$ageMin = -1
try {
    $ageMin = [math]::Round(((Get-Date) - (Get-Item $src).LastWriteTime).TotalMinutes, 1)
    if ($ageMin -le $MaxAgeMin) { $ageOk = $true }
} catch { $ageOk = $false }

if (-not $ageOk) {
    Write-Host "ERROR: impl/pnr/Gowin2026_tr_content.html is $ageMin min old (limit $MaxAgeMin)." -ForegroundColor Red
    Write-Host "       Refusing to archive -- it is probably from an earlier, already-wiped run." -ForegroundColor Red
    Pop-Location
    exit 2
}

# ---- destination ----------------------------------------------------------
$stamp = (Get-Item $src).LastWriteTime.ToString('yyyyMMdd-HHmmss')
$safe  = ($Label -replace '[^A-Za-z0-9_.-]', '_')
$dst   = Join-Path $root "$DestRoot\$stamp-$safe"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# ---- 1. raw artefacts (verbatim, byte-identical) --------------------------
Copy-Item $src   (Join-Path $dst "tr_content.html") -Force
if (Test-Path $paths) { Copy-Item $paths (Join-Path $dst "timing_paths.txt") -Force }
if (Test-Path $rpt)   { Copy-Item $rpt   (Join-Path $dst "rpt.txt")        -Force }

$fsSha = ""
$fsMb  = 0
if (Test-Path $fs) {
    $fsSha = (Get-FileHash $fs -Algorithm SHA256).Hash
    $fsMb  = [math]::Round((Get-Item $fs).Length / 1MB, 2)
}

# ---- 2. flatten the report sections the build script DROPS ----------------
#  gowin_build.ps1 keeps STA/Clock/Fmax only.  The ones whose loss actually
#  cost us information on 2026-10-17 are the PATH TABLES:
#    Recovery Paths        (OSER10/RESET release, serial_clk [R]->[F])
#    Removal Paths         (same family -- top.sdc:119 records +0.217 ns baseline)
#    Minimum Pulse Width   (why the HDMI lanes need 0.312 ns)
#    Setup / Hold path tables (the only record of From/To/slack per path)
#
#  NOTE (2026-10-17) -- why NOT the project's own Get-ReportRows/Get-Block idiom
#      (gowin_build.ps1:322-336) for these five:
#      Get-Block walks the FLATTENED rows for a line containing the section
#      title.  Measured failure on the 21:51 report: all five path tables
#      came back "(section not found)" even though every title is present in
#      the HTML exactly once.  Two reasons, both verified by character offset:
#        (a) after flattening, the table's own HEADER row repeats the words,
#            so "-like" can bind to the wrong row;
#        (b) the real document order is NOT the order the sections are read in:
#              Setup(5131) Hold(12699) Recovery(18658) Removal(22282)
#              MinPulseWidth(25746) ByAnalysisType(27867)
#            so a walk that stops at "the next boundary" slices the wrong span.
#      Slicing the RAW html by character offset is deterministic because each
#      anchor occurs exactly once.  The slice is flattened identically, so the
#      output format is unchanged.
function Get-HtmlBlock([string]$rawHtml, [string]$from, [string]$to, [int]$maxRows = 30) {
    $i = $rawHtml.IndexOf($from)
    if ($i -lt 0) { return @("(anchor not found: $from)") }
    if ([string]::IsNullOrEmpty($to)) { $j = [Math]::Min($rawHtml.Length, $i + 40000) }
    else {
        $j = $rawHtml.IndexOf($to, $i + $from.Length)
        if ($j -lt 0) { $j = [Math]::Min($rawHtml.Length, $i + 40000) }
    }
    $seg = $rawHtml.Substring($i, $j - $i)
    $t = $seg -replace '(?i)</t[dh]>', ' | ' -replace '(?i)</tr>', "`n" -replace '<[^>]+>', '' -replace '[ \t]+', ' '
    @($t -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -First $maxRows)
}
#  Kept for the three summary blocks, which DO parse correctly with the
#  original walk (verified 2026-10-17 on the 21:51 run).
function Get-ReportRows([string]$p) {
    $raw = Get-Content $p -Raw
    $t = $raw -replace '(?i)</t[dh]>', ' | ' -replace '(?i)</tr>', "`n" -replace '<[^>]+>', '' -replace '[ \t]+', ' '
    @($t -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
function Get-Block($rows, [string]$from, [string]$to, [int]$max = 40) {
    $i = -1; $j = -1
    for ($k = 0; $k -lt $rows.Count; $k++) {
        if ($i -lt 0 -and $rows[$k] -like "*$from*") { $i = $k }
        elseif ($i -ge 0 -and $to -ne "" -and $rows[$k] -like "*$to*") { $j = $k; break }
    }
    if ($i -lt 0) { return @("(section not found: $from)") }
    if ($j -lt 0) { $j = [Math]::Min($i + $max, $rows.Count - 1) }
    return $rows[$i..$j]
}

#  NOTE (2026-10-17) measured trap: these anchors must NOT carry a trailing
#      colon.  In tr_content.html the real titles are bounded by
#          "Setup Paths Table Report Command:report_timing -setup ..."
#      i.e. "Table" is followed by the word "Report", not by ':'.  Passing
#      "Setup Paths Table:" therefore never matches, and all five path tables
#      archived as "(anchor not found)" -- a silent evidence hole, which is
#      the exact failure this script exists to prevent.  The colons DO belong
#      to the summary sections (STA Tool Run Summary: etc.), which is why only
#      those five were affected.
$ANCHOR_SETUP    = "Setup Paths Table"
$ANCHOR_HOLD     = "Hold Paths Table"
$ANCHOR_RECOVERY = "Recovery Paths Table"
$ANCHOR_REMOVAL  = "Removal Paths Table"
$ANCHOR_MINPULSE = "Minimum Pulse Width Table"

$rawHtml = Get-Content $src -Raw
$rows   = Get-ReportRows $src

$out = @()
$out += "# PnR timing evidence (archived by tools/archive_pnr_evidence.ps1)"
$out += "# source : impl/pnr/Gowin2026_tr_content.html  (LastWriteTime $stamp)"
$out += "# label  : $safe"
$out += "# note   : $Note"
$out += "#"
$out += "# WHY THIS FILE EXISTS: gowin_build.ps1 only persists"
$out += "#   STA Tool Run Summary / Clock Summary / Max Frequency Summary"
$out += "# into sim/evidence/gowin_m0_timing.txt.  The PATH TABLES below live"
$out += "# only in impl/pnr, which is wiped at the start of EVERY build and is"
$out += "# git-ignored -- so without this archive they are gone for good."
$out += ""
$out += "== STA tool run summary (setup/hold violation counts) =="
$out += Get-Block $rows "STA Tool Run Summary:" "Clock Summary:"
$out += ""
$out += "== total negative slack summary (per clock) =="
$out += Get-Block $rows "Total Negative Slack Summary:" "Timing Details"
$out += ""
$out += "== clock summary =="
$out += Get-Block $rows "Clock Summary:" "Max Frequency Summary:"
$out += ""
$out += "== max frequency summary (Fmax) =="
$out += Get-Block $rows "Max Frequency Summary:" "" 12
$out += ""
$out += "== SETUP PATHS (worst 25 -- the real violations) =="
$out += Get-HtmlBlock $rawHtml $ANCHOR_SETUP $ANCHOR_HOLD 27
$out += ""
$out += "== HOLD PATHS (worst 25) =="
$out += Get-HtmlBlock $rawHtml $ANCHOR_HOLD $ANCHOR_RECOVERY 27
$out += ""
$out += "== RECOVERY PATHS (dropped by gowin_build.ps1 -- 2026-10-17 lesson) =="
$out += Get-HtmlBlock $rawHtml $ANCHOR_RECOVERY $ANCHOR_REMOVAL 26
$out += ""
$out += "== REMOVAL PATHS (dropped by gowin_build.ps1) =="
$out += Get-HtmlBlock $rawHtml $ANCHOR_REMOVAL $ANCHOR_MINPULSE 26
$out += ""
$out += "== MINIMUM PULSE WIDTH (dropped by gowin_build.ps1) =="
$out += Get-HtmlBlock $rawHtml $ANCHOR_MINPULSE "Timing Report By Analysis Type:" 13

#  Written HERE, before section 3 parses it, so the index can never
#  disagree with the file a reviewer is actually looking at.
$out | Out-File -FilePath (Join-Path $dst "summary.txt") -Encoding utf8

# ---- 3. machine-readable headline numbers, for diffing two archives -------
#  NOTE: these parse $out (the freshly built summary), NOT the file on disk,
#  so a write/read round-trip cannot desynchronise them.
#  The flattened cells put the VALUE on the line AFTER the label, which is why
#  "Actual Fmax" alone matches nothing -- match the label then take the next
#  non-empty cell.  2026-10-17 lesson: an earlier version of these regexes
#  silently produced empty strings, and the archive recorded blanks.
function Next-Cell($lines, [string]$label) {
    #  NOTE (2026-10-17) measured trap: after flattening, the label line
    #      a trailing pipe, i.e. the file literally contains
    #          "Numbers of Setup Violated Endpoints |"
    #      so `-eq $label` NEVER matches and the cell comes back empty.  Match
    #      the label as a prefix instead.
    for ($k = 0; $k -lt $lines.Count; $k++) {
        $ln = $lines[$k].Trim()
        if ($ln.StartsWith($label)) {
            $rest = $ln.Substring($label.Length).Trim().TrimStart('|').Trim()
            if ($rest -ne "" -and $rest -ne "|") { return $rest }
            for ($m = $k + 1; $m -lt $lines.Count; $m++) {
                $c = $lines[$m].Trim().TrimEnd('|').Trim()
                if ($c -ne "" -and $c -ne "|") { return $c }
            }
        }
    }
    return ""
}
#  Max Frequency Summary is "NO. | Clock | Constraint | ActualFmax | LogicLevel | Entity"
#  and the clk_sys row is row 1 of the -- RENUMBERED -- table, so read it as:
#  find the constraint value 50.000(MHz) then take the following two cells.
#  NOTE (2026-10-17) measured trap: after flattening, every table CELL sits on
#      its own line, e.g. the clk_sys row of Max Frequency Summary is six
#      consecutive lines "1 |" "clk_sys |" "50.000(MHz) |" "57.866(MHz) |"
#      "15 |" "TOP |".  A regex that expects all five cells on one line
#      therefore never matches.  Walk the cells instead.
function ClkSys-FmaxAndLevel($lines) {
    $want = "50.000(MHz)"      # our clk_sys constraint, from constr/top.sdc:148
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k].Trim() -ne "$want |" -and $lines[$k].Trim() -ne $want) { continue }
        #  next cell = Actual Fmax, the one after = Logic Level
        $f = ""; $ll = ""
        if ($k + 1 -lt $lines.Count) { $f  = $lines[$k+1].Trim().TrimEnd('|').Trim() }
        if ($k + 2 -lt $lines.Count) { $ll = $lines[$k+2].Trim().TrimEnd('|').Trim() }
        if ($f -match '^[0-9.]+\(MHz\)$' -and $ll -match '^\d+$') {
            return ,@($f, $ll)
        }
    }
    return ,@("", "")
}
function Worst-Slack($lines) {
    #  First data row of the Setup Paths table.  After Get-HtmlBlock flattens
    #  it, the row is six cells on six lines ("1 |", "-0.881 |", "<from> |", ...),
    #  so anchor on the "1 |" row-number cell and take the NEXT cell as slack.
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k].Trim() -ne "1 |") { continue }
        if ($k + 1 -ge $lines.Count) { continue }
        $c = $lines[$k+1].Trim().TrimEnd('|').Trim()
        if ($c -match '^-?[0-9]+\.[0-9]+$') { return $c }
    }
    return ""
}

$setupCnt = Next-Cell $out "Numbers of Setup Violated Endpoints"
$holdCnt  = Next-Cell $out "Numbers of Hold Violated Endpoints"
$pathsCnt = Next-Cell $out "Numbers of Paths Analyzed"
$ll       = ClkSys-FmaxAndLevel $out
$fmax     = $ll[0]
$logLvl   = $ll[1]
$worstSet = Worst-Slack $out
if ($setupCnt -eq "" -or $fmax -eq "" -or $worstSet -eq "") {
    Write-Host "WARN: could not parse headline numbers (setup='$setupCnt' Fmax='$fmax' worst='$worstSet')." -ForegroundColor Yellow
    Write-Host "      The archive is still complete -- only the index row is blank for those columns." -ForegroundColor Yellow
}

# ---- 4. RTL fingerprint of exactly what produced this report --------------
$hashTxt = Get-ChildItem (Join-Path $root "rtl") -Recurse -Include *.v, *.sv -File |
           ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower(),
                                        $_.FullName.Replace("$root\",'').Replace('\','/') }
$hashTxt | Sort-Object | Out-File -FilePath (Join-Path $dst "rtl_fingerprint.txt") -Encoding ascii

# ---- 5. append-only index (build/ is git-ignored, so it lives in evidence) -
$idx = Join-Path $root "sim\evidence\pnr-evidence-index.md"
if (-not (Test-Path $idx)) {
    $hdr = @(
        '# PnR evidence index (append-only, written by tools/archive_pnr_evidence.ps1)',
        '',
        '> WHY: `sim/gowin_build.ps1` wipes `impl/pnr/` every run and `impl/` is',
        '> git-ignored, while `gowin_m0_timing.txt` keeps only three summary',
        '> blocks.  Recovery / Removal / MinPulseWidth / the Setup and Hold path',
        '> tables survive ONLY here.  Call this script right after every build.',
        '',
        '| archived | label | setup | hold | paths | Fmax | LL | worst setup slack | fs sha256 | note |',
        '|---|---|---|---|---|---|---|---|---|---|'
    )
    $hdr | Out-File -FilePath $idx -Encoding utf8
}

$row = "| $stamp | $safe | $setupCnt | $holdCnt | $pathsCnt | $fmax | $logLvl | $worstSet | $(if ($fsSha) { $fsSha.Substring(0,16) } else { 'n/a' }) | $Note |"
Add-Content -Path $idx -Value $row -Encoding utf8

# ---- report ---------------------------------------------------------------
Write-Host ""
Write-Host "OK  archived -> $DestRoot\$stamp-$safe" -ForegroundColor Green
Write-Host "    setup viol = $setupCnt   hold viol = $holdCnt"
Write-Host "    paths = $pathsCnt   Fmax = $fmax   LogicLevel = $logLvl   worst setup slack = $worstSet ns"
if ($fsSha) { Write-Host "    bitstream sha256 = $fsSha  (${fsMb} MB)" }
Write-Host "    files: summary.txt  tr_content.html  timing_paths.txt  rpt.txt  rtl_fingerprint.txt"
Write-Host "    index -> sim\evidence\pnr-evidence-index.md"

Pop-Location
exit 0
