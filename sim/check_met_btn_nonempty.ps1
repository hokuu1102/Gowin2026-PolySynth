# check_met_btn_nonempty.ps1 -- non-emptiness proof for the 2026-09-28 metronome work
#
#   covers:  tb/w3c/tb_met_btn_top.sv   (S2/AB13 metronome switch)
#            tb/w3c/tb_perc_env_top.sv  (reserved pool = one-shot percussive, K-144 fix)
#            tb/w3c/tb_met_start_top.sv (downbeat on enable)
#            tb/drivers/tb_calib.sv     (K-153 pos travel clamp)
#            tb/w3b/tb_note_manager.sv  (K-154 velocity slew)
#            tb/w3b/tb_tdm_render_mixer.sv
#                (2026-09-29 limiter pipeline: valid_d widening, K-155 latency
#                 EQUALITY + the depth-independent in-phase criterion)
#
#   MUTATIONS SPAN MULTIPLE FILES: each entry may set `file` (default rtl/top.v).
#   Anchors must be ASCII-only and unique in the target file -- a Chinese
#   anchor silently never matches (see the M85 lesson / AGENTS.md).
#
# WHY (C21 / C83 / L88):
#   A criterion that has NEVER been observed to FAIL may be vacuous.
#   This script compiles the SAME tb against MUTATED copies of rtl/top.v and
#   requires that a SPECIFIC named criterion turns red for each mutation.
#
# SAFETY:
#   rtl/ is NEVER touched.  Each mutation is written to a COPY under
#   build/_mut_metbtn/<id>/ and substituted into the iverilog file list.
#   Each run gets its own working directory so the tb's hard-coded
#   build/sim/<tb>/*.vcd path does not collide between runs.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\check_met_btn_nonempty.ps1
# EXIT:
#   0 = every mutation produced its expected FAIL line (criteria are non-vacuous)
#   1 = at least one mutation did NOT fail as expected (a criterion is vacuous)
#
# NOTE: pure ASCII on purpose (project rule for .ps1 files).
# NOTE: ErrorActionPreference is Continue on purpose -- iverilog prints harmless
#       "timescale inherited" warnings on stderr, and under 'Stop' PowerShell
#       turns native stderr into a terminating ErrorRecord (AGENTS 0.10 pitfall 2/3).

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$topRel = "rtl\top.v"
$base   = "build\_mut_metbtn"

if (-not (Test-Path $base)) { New-Item -ItemType Directory -Force -Path $base | Out-Null }

$iverilog = (Get-Command iverilog -ErrorAction SilentlyContinue)
$vvpCmd   = (Get-Command vvp -ErrorAction SilentlyContinue)
if (-not $iverilog -or -not $vvpCmd) {
    Write-Host "cannot find iverilog / vvp on PATH" -ForegroundColor Red
    exit 1
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$src = [IO.File]::ReadAllText((Join-Path $root $topRel), $utf8NoBom)

# ---------------------------------------------------------------- mutations --
# anchor strings must be ASCII-only and unique in rtl/top.v
$muts = @(
    @{ id     = "MUT1_drop_met_on_r_gate";
       tb     = "tb\w3c\tb_met_btn_top.sv";
       find   = "                                  & met_on_r;";
       repl   = "                                  ;";
       want   = "M8";
       why    = "removing the runtime gate must make the gate criterion FAIL" },

    @{ id     = "MUT2_met_btn_s_not_zsafe";
       tb     = "tb\w3c\tb_met_btn_top.sv";
       find   = "wire met_btn_s = (met_btn_i === 1'b0) ? 1'b0 : 1'b1;";
       repl   = "wire met_btn_s = met_btn_i;";
       want   = "M2";
       why    = "passing Z through must make the Z-safe criterion FAIL" },

    @{ id     = "MUT3_met_btn_active_high";
       tb     = "tb\w3c\tb_met_btn_top.sv";
       find   = ".ACTIVE_LOW (1)";
       repl   = ".ACTIVE_LOW (0)";
       want   = "M3";
       why    = "wrong polarity inverts the idle level -- the released/Z state is read as pressed, so the OFF criteria M3/M4/M6 go red" },

    @{ id     = "MUT4_toggle_becomes_set";
       tb     = "tb\w3c\tb_met_btn_top.sv";
       find   = "met_on_r <= ~met_on_r;";
       repl   = "met_on_r <= 1'b1;";
       want   = "M7";
       why    = "a set-only register can never be turned OFF again" },

    #  K-144 fix: revert the reserved-pool envelope back to the ADSR
    #  (the metronome then decays to sustain and HOLDS -> the old hang bug)
    @{ id     = "MUT5_perc_env_not_wired";
       tb     = "tb\w3c\tb_perc_env_top.sv";
       find   = ".env_level_i      (env_level_mix),";
       repl   = ".env_level_i      (env_level),";
       want   = "P3";
       why    = "reserved pool back on the ADSR -> never reaches 0 -> the no-hang criterion must FAIL" },

    #  2026-09-28: the metronome must START on the downbeat -> beat_gen pos_reset
    #  (without it the first audible beat is a WEAK beat, which the user reported)
    @{ id     = "MUT6_no_pos_reset_on_enable";
       tb     = "tb\w3c\tb_met_start_top.sv";
       find   = ".pos_reset_i     (met_start),";
       repl   = ".pos_reset_i     (1'b0),";
       want   = "T2";
       why    = "without the phase reset the first beat is a WEAK beat, not the downbeat" },

    #  2026-09-28: K-153 -- calib must CLAMP (raw - zero) to the travel bound.
    #  Without it, an out-of-range raw sample makes `pos` reach 2.9x the travel
    #  (measured on board: |dpos| = 2193 while the full travel is only 744).
    @{ id     = "MUT7_calib_no_travel_clamp";
       tb     = "tb\drivers\tb_calib.sv";
       file   = "rtl\drivers\calib.sv";
       find   = "wire [DW:0] dclamp = (dcode > dlim) ? dlim : dcode;";
       repl   = "wire [DW:0] dclamp = dcode;";
       want   = "default";
       why    = "removing the clamp lets pos exceed the travel bound -> the clamp criterion must FAIL" },

    #  2026-09-28: K-154 -- the velocity update must be RATE LIMITED (a ramp).
    #  Otherwise a hard press makes vel_r jump from 64 to 255 in ONE cycle, the
    #  envelope level jumps, and the instantaneous sum clips -> shrill sound.
    @{ id     = "MUT8_note_manager_vel_slew";
       tb     = "tb\w3b\tb_note_manager.sv";
       file   = "rtl\w3b\note_manager.v";
       # 2026-09-29 FIX: the anchor was STALE -- it still searched for 8'd1
       # while the shipped parameter is +-8 (the user picked 8 on 2026-09-28).
       # A stale anchor makes this whole script exit 1 with SKIP, i.e. it
       # silently stops being any proof at all (same family as L74 / C88:
       # "the evidence file says PASS" != "it proves the latest change").
       find   = "if      (vu_val_pend_r > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;";
       repl   = "if (1'b0) vel_r[i] <= vel_r[i] + 8'd8;";
       want   = "vel_update";
       why    = "without the rate limit vel_r jumps straight to the target -> the ramp criterion must FAIL" },

    #  2026-09-29: FMAX work -- the limiter pipeline in tdm_render_mixer.
    #  Adding one register stage is only correct if `valid_d` is widened AT
    #  THE SAME TIME.  Forgetting the widening leaves valid_d[4] as an
    #  out-of-range bit select (reads as X) -> dry_valid never pulses.
    @{ id     = "MUT9_valid_d_not_widened";
       tb     = "tb\w3b\tb_tdm_render_mixer.sv";
       file   = "rtl\w3b\tdm_render_mixer.v";
       find   = "    reg [4:0] valid_d;";
       repl   = "    reg [3:0] valid_d;";
       want   = "exactly 1 dry_valid pulse per frame";
       why    = "not widening valid_d leaves valid_d[4] out of range -> dry_valid is X -> the one-pulse criterion must FAIL" },

    #  2026-09-29: K-155 -- the latency criterion must be an EQUALITY.
    #  Moving valid one cycle early keeps EVERY value criterion green (the
    #  data actually settles 4 cycles BEFORE valid asserts), so only the
    #  equality latency check can catch it.  This is the exact mutant that
    #  the old range criterion [POLY+3, POLY+8] let through.
    @{ id     = "MUT10_valid_d_off_by_one";
       tb     = "tb\w3b\tb_tdm_render_mixer.sv";
       file   = "rtl\w3b\tdm_render_mixer.v";
       find   = "    assign dry_valid_o      = valid_d[4];";
       repl   = "    assign dry_valid_o      = valid_d[3];";
       want   = "latency == LAT_EXPECT";
       why    = "one cycle early: the old RANGE criterion passed, the new EQUALITY criterion must FAIL" },

    #  2026-09-29: the depth-independent companion criterion -- valid must
    #  never assert BEFORE the data settles.  This mutation MOVES the valid
    #  pulse 6 cycles early (it does not add one), so the frame still emits
    #  exactly one pulse and the in-phase criterion is the only one able to
    #  see the misalignment.  Anchor is ASCII-only and spans the if/else.
    @{ id     = "MUT11_valid_six_cycles_early";
       tb     = "tb\w3b\tb_tdm_render_mixer.sv";
       file   = "rtl\w3b\tdm_render_mixer.v";
       find   = "                    busy    <= 1'b0;`n                    valid_r <= 1'b1;`n                end else begin`n                    cnt <= cnt + 1'b1;`n                end";
       repl   = "                    busy    <= 1'b0;`n                end else begin`n                    cnt <= cnt + 1'b1;`n                    if (cnt == (CNT_TOTAL[LW:0] - 6'd6)) valid_r <= 1'b1;`n                end";
       want   = "valid and data are IN PHASE";
       why    = "valid before the data settles -> the in-phase criterion must FAIL" }
)

#  2026-09-28: this script no longer hard-codes rtl/top.v as the ONLY file.
#     Each entry may set file = "rtl\drivers\calib.sv" to pick the file to
#     mutate (default is still rtl/top.v); the loop then excludes that file
#     from $rtlBase.
#
#  2026-09-29 FIX (C72 / U46): the three comment lines above used to be
#     CHINESE while this file had NO UTF-8 BOM.  PowerShell 5.1 then decodes
#     it as GBK, a multi-byte sequence swallows the trailing newline, the
#     next line ($rtlBase = @(Get-ChildItem ...) ) gets absorbed into the
#     comment, and the parser dies on the orphan ')' of the following line.
#     => the script could not even PARSE, so this non-emptiness proof for
#     K-153/K-154 was silently dead.  Kept pure ASCII on purpose.
$rtlBase = @(Get-ChildItem -Path "rtl" -Recurse -Include *.sv,*.v -File |
         Sort-Object FullName | ForEach-Object { $_.FullName })
$models = @(Get-ChildItem -Path "tb\models"   -Recurse -Include *.sv,*.v -File | ForEach-Object { $_.FullName })
$chk    = @(Get-ChildItem -Path "tb\checkers" -Recurse -Include *.sv,*.v -File | ForEach-Object { $_.FullName })

Write-Host ("rtl files: {0} | models: {1} | checkers: {2}" -f $rtlBase.Count, $models.Count, $chk.Count)

# --------------------------------------------------------- build + launch --
$runs = @()
foreach ($m in $muts) {
    #  which file this mutant edits (default rtl/top.v)
    $mf    = if ($m.ContainsKey("file")) { $m.file } else { $topRel }
    $mfAbs = (Resolve-Path (Join-Path $root $mf)).Path
    $src   = [IO.File]::ReadAllText($mfAbs, $utf8NoBom)
    #  2026-09-29 FIX: $rtlBase holds STRINGS (built with
    #  `ForEach-Object { $_.FullName }`), so `$_.FullName -ne $mfAbs` was
    #  always TRUE ($null on a string) and NOTHING was ever excluded.
    #  The mutated copy therefore went into iverilog ALONGSIDE the original
    #  file -> "error: 'top' has already been declared" -> every run died at
    #  the compile step.  Compare the string itself.
    $rtl   = @($rtlBase | Where-Object { $_ -ne $mfAbs })

    if (-not $src.Contains($m.find)) {
        Write-Host ("SKIP {0}: anchor NOT found in {1} -- anchor is stale, fix it" -f $m.id, $mf) -ForegroundColor Red
        exit 1
    }
    $mutSrc = $src.Replace($m.find, $m.repl)
    if ($mutSrc -eq $src) {
        Write-Host ("SKIP {0}: replacement was a no-op" -f $m.id) -ForegroundColor Red
        exit 1
    }

    $runDir = Join-Path $root ($base + "\" + $m.id)
    $tbName = [IO.Path]::GetFileNameWithoutExtension($m.tb)
    #  2026-09-29 FIX: the tbs do NOT all dump into build/sim/<tbName>.
    #  e.g. tb_calib.sv writes build/sim/calib/... and tb_mcp3208_* write
    #  build/sim/mcp3208/...  If that directory is missing, $dumpfile fails,
    #  vvp dies at time 0, the log holds ONLY the VCD error, and the verdict
    #  reads "criterion did NOT fail" -> a FALSE negative that looks exactly
    #  like a vacuous criterion.  Derive the directory from the tb itself.
    $tbText = [IO.File]::ReadAllText((Join-Path $root $m.tb), $utf8NoBom)
    $dumpDirs = @()
    foreach ($mm in [regex]::Matches($tbText, '\$dumpfile\s*\(\s*"([^"]+)"')) {
        $dp = Split-Path -Parent $mm.Groups[1].Value
        if ($dp) { $dumpDirs += ($dp -replace '/', '\') }
    }
    if ($dumpDirs.Count -eq 0) { $dumpDirs = @("build\sim\" + $tbName) }
    foreach ($dp in ($dumpDirs | Select-Object -Unique)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $runDir $dp) | Out-Null
    }
    #  keep the legacy directory name too (harmless, one mkdir)
    New-Item -ItemType Directory -Force -Path (Join-Path $runDir ("build\sim\" + $tbName)) | Out-Null

    $mutV = Join-Path $runDir "top_mut.v"
    [IO.File]::WriteAllText($mutV, $mutSrc, $utf8NoBom)

    $vvpFile = Join-Path $runDir "tb.out"
    $cargs = @("-g2012", "-Wall", "-DWAVETABLE_BEHAVIORAL", "-s", $tbName, "-o", $vvpFile) +
             $rtl + $models + $chk + @($mutV, (Join-Path $root $m.tb))
    $cout = & $iverilog.Source @cargs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("COMPILE FAILED for {0}" -f $m.id) -ForegroundColor Red
        Write-Host $cout
        exit 1
    }

    $log = Join-Path $runDir "run.log"
    $err = Join-Path $runDir "run.err"
    $p = Start-Process -FilePath $vvpCmd.Source -ArgumentList @($vvpFile) `
                       -WorkingDirectory $runDir -NoNewWindow -PassThru `
                       -RedirectStandardOutput $log -RedirectStandardError $err
    Write-Host ("launched {0} (pid {1}) -- expect criterion {2} to FAIL" -f $m.id, $p.Id, $m.want)
    $runs += ,@($m, $p, $log)
}

foreach ($r in $runs) { $r[1].WaitForExit() }

# ------------------------------------------------------------------ verdict --
$bad = 0
Write-Host ""
foreach ($r in $runs) {
    $m   = $r[0]
    #  2026-09-29: read the log BYTE-PRESERVING (Latin1) and then drop every
    #  non-ASCII char.  vvp mangles non-ASCII $display output on this machine
    #  (measured: UTF-8 bytes come out as EF A3 B5 or FF FF FF, and the
    #  FOLLOWING ASCII character is swallowed as well), so a criterion name
    #  containing Chinese can partly vanish from the log.  Matching on an
    #  ASCII-only substring of the name is the only stable option -- keep the
    #  names ASCII-only in the tb for the same reason.
    $raw = ""
    if (Test-Path $r[2]) { $raw = [IO.File]::ReadAllText($r[2], [Text.Encoding]::GetEncoding(28591)) }
    $txt = [regex]::Replace($raw, '[^\x00-\x7F]', '')
    $sawFail = $txt -match ("FAIL:\s*" + [regex]::Escape($m.want) + "(\s|:)")
    $sawPass = $txt -match "PASS: "
    $anyFail = $txt -match "FAIL:"
    if ($sawFail -and (-not $sawPass)) {
        Write-Host ("OK   {0}: criterion {1} turned RED as expected  ({2})" -f $m.id, $m.want, $m.why) -ForegroundColor Green
    } elseif ($sawPass) {
        Write-Host ("BAD  {0}: the tb PASSED -- criterion {1} is VACUOUS" -f $m.id, $m.want) -ForegroundColor Red
        $bad = $bad + 1
    } elseif ($anyFail) {
        Write-Host ("BAD  {0}: the tb failed but the token '{1}' is NOT in the ASCII log -- the criterion name is not ASCII, so the verdict cannot be attributed (fix the name, do not ignore this)" -f $m.id, $m.want) -ForegroundColor Red
        $bad = $bad + 1
    } else {
        Write-Host ("BAD  {0}: no verdict in the log at all -- the simulation probably died (missing dir / bad params).  Log head: {1}" -f $m.id, $txt.Substring(0, [Math]::Min(160, $txt.Length))) -ForegroundColor Red
        $bad = $bad + 1
    }
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host "PASS: met_btn non-emptiness -- every criterion can fail (rtl/ untouched)" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAIL: {0} mutation(s) did not produce the expected red criterion" -f $bad) -ForegroundColor Red
    exit 1
}
