# mutation_test.ps1 -- MUTATION TESTING: inject a known defect, require the suite to catch it.
#
# Usage (from the repository root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1 -Filter M29
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1 -File w3b
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1 -Changed
#
# ---- WHICH MUTANTS TO RUN (added 2026-09-21, policy reinforced 2026-09-23) -----
#   Each mutant runs the WHOLE regression (all 36 benches under tb/), so it is
#   expensive.  Measured 2026-09-23: a FULL run of 76 mutants took >3.9 h
#   (the old "~109 s each / all 37 take ~67 min" figures are stale -- bench
#   count and mutant count have both grown).
#
#   WHY THIS IS ACCEPTABLE (and what the two modes actually prove):
#     * FRONT END always runs: every mutant executes the FULL 36-bench regression.
#       So "did my change BREAK the functionality?" is ALWAYS covered in full.
#     * WHAT GETS TRIMMED is only the mutation-injection count, i.e.
#       "is the regression still able to CATCH a defect in module X?"
#   => A partial run is SUFFICIENT EVIDENCE for the modules it covers, but it
#      CANNOT prove that other modules' guards still work.  That is exactly why
#      the policy below still demands a FULL run before commit/push.
#
#   -File <substr>    only mutants whose FILE path contains <substr>
#                     e.g. -File w3b   -> the rtl/w3b mutants
#                          -File tlc   -> the tlc5916 mutants
#   -Changed          only mutants whose file differs from HEAD (git diff + index)
#                     -> the natural choice while iterating on one module
#   -Filter <substr>  only mutants whose ID contains <substr>  (single target)
#
#   POLICY (reinforced 2026-09-23; rationale recorded as entry "K-115" in the
#   project's known-issues / risk list under files/20-*):
#     * iterating on one module ....... -Changed   or   -File <that module>
#     * END OF DAY .................... FULL run (kick it off when you stop working;
#                                       ~4 h, and its LAST step re-runs the
#                                       regression from CLEAN RTL, so you start the
#                                       next day with clean evidence)
#     * before commit / push .......... FULL run (no arguments)
#     * touched a SHARED file ......... FULL run, always
#       (sim/tb_all.ps1, tb/models/*, tb/checkers/*, sim/evidence/*)
#     * touched rtl/top.v ............. FULL run (it is the integration point)
#
#   !! BEFORE STARTING A FULL RUN, COMMIT YOUR WORK FIRST.
#      This script edits tracked files in place.  If it dies mid-run (power loss,
#      kill) with no commit to fall back on, you cannot tell "leftover mutation"
#      from "my own edit".
#
# NOTE (concurrency guard, added 2026-09-21): this script MUTATES tracked files in
#   place and restores them.  Two concurrent runs fight over the same file and can
#   leave a mutation behind -- this really happened: a -Filter run overlapped a full
#   run and left M25's mutation in note_manager.v.  A lock file now makes a second
#   run refuse to start.
#
# !! WHILE A RUN IS IN FLIGHT, DO NOT touch rtl/ or tb/, and DO NOT git add.
#    tb_all.ps1 compiles EVERY file under rtl/ and tb/ into EVERY bench, and this
#    script treats "regression exit != 0" as CAUGHT.  So adding or breaking any
#    file mid-run can flip every remaining mutant to a FALSE "caught".
#    (Same-family hazard as K-105: "does not compile" counted as "was caught".)
#
# WHY (this is the strongest evidence that the checks are not decoration):
#   "All tests pass" proves nothing if the tests cannot fail.  Here we take the REAL RTL,
#   make ONE small change that we KNOW is a defect, and require the regression to go red.
#   A mutation that stays GREEN means the suite has a blind spot for that class of bug.
#
# HOW:
#   1. back up the file to build/mutation/backup/
#   2. apply the mutation (literal string replace)
#   3. run `sim\tb_all.ps1` (expects exit != 0)
#   4. restore the file, verify it is byte-identical to the backup
#   5. report GREEN(leak)=BAD / RED(caught)=GOOD
#   6. run the regression ONE more time on the restored (clean) code, so that
#      sim/evidence/*.log is regenerated from CLEAN code (see the NOTE below)
#
# NOTE (evidence contamination -- found 2026-09-18): tb_all.ps1 REWRITES sim/evidence/*.log.
#   So every mutant run overwrites the committed evidence with a log full of FAIL lines.
#   Restoring only the RTL leaves those contaminated logs behind, and they look like real
#   acceptance evidence.  That is why step 6 exists: the last action is always a clean run.
#
# NOTE: ASCII only.  PowerShell 5.1 decodes BOM-less UTF-8 as GBK -> syntax error (K-38).
# NOTE: the file must be restored even if the run throws -- restore happens in a finally-like
#       block after every mutation, and the script refuses to leave a mutation in place.
#
# NOTE (K-87, found 2026-09-20): "anchor text not found" is reported as SKIP and -- since
#   K-87 -- makes the whole run FAIL (exit 4).  Reason: a mutant whose anchor no longer
#   matches guards NOTHING, yet the run used to still print "PASS".  That is how M21/M22
#   silently stopped protecting adc_farm after its N_ADC parameterisation.  When you change
#   the RTL that a mutant targets, you MUST re-point the anchor in the same commit.

param(
  [string]$Filter = "",
  [string]$File   = "",
  [switch]$Changed
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$bakDir = Join-Path $root "build\mutation\backup"
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null

# ---- concurrency guard -------------------------------------------------------
# This script edits tracked source files in place and restores them.  A second
# concurrent instance would corrupt the backup/restore cycle.  Refuse to start.
$lockFile = Join-Path $root "build\mutation\.lock"
if (Test-Path $lockFile) {
  $owner = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue)
  $alive = $false
  if ($owner -match '^(\d+)') {
    $alive = $null -ne (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)
  }
  if ($alive) {
    Write-Host "FAIL: another mutation_test.ps1 is already running (pid $owner)." -ForegroundColor Red
    Write-Host "      Concurrent runs mutate the same files and can leave a mutation behind." -ForegroundColor Red
    Write-Host "      Wait for it to finish, or kill it first." -ForegroundColor Red
    exit 3
  }
  Write-Host "NOTE: reclaiming stale lock (pid $owner is gone)" -ForegroundColor Yellow
  Remove-Item $lockFile -Force -ErrorAction SilentlyContinue

  # ---- CRASH RECOVERY (added 2026-09-21) -------------------------------------
  # If a previous run was KILLED (Ctrl-C, executor timeout, task kill) it never
  # reached its restore step, so the working tree may still hold a mutation.
  # This really happened: the executor's 600 s cap killed a -File w3b run with
  # M33 applied, and the next run then SKIPPED M33 (anchor already mutated) and
  # its clean-up regression ran on MUTATED rtl -- i.e. a corrupted verdict.
  #
  # Any leftover .bak in build/mutation/backup is proof of an unclean exit.
  # NOTE: recovery runs BEFORE the catalogue is declared below, so it must NOT
  # depend on $mutations.  Match the backup leaf name against the files we know
  # about by scanning rtl/ and tb/ instead.
  $stale = @(Get-ChildItem $bakDir -Filter *.bak -File -ErrorAction SilentlyContinue)
  if ($stale.Count -gt 0) {
    Write-Host ("WARNING: " + $stale.Count + " leftover backup(s) -- a previous run was killed mid-mutation.") -ForegroundColor Yellow
    # index every candidate source file by leaf name
    $srcIndex = @{}
    foreach ($d in @("rtl", "tb")) {
      Get-ChildItem (Join-Path $root $d) -Recurse -File -Include *.v, *.sv -ErrorAction SilentlyContinue |
        ForEach-Object { $srcIndex[$_.Name] = $_.FullName }
    }
    foreach ($b in $stale) {
      # backup name is "<leaf>.<Mnn>.bak"
      $leaf = ($b.Name -replace '\.[^.]*\.bak$', '')
      if ($srcIndex.ContainsKey($leaf)) {
        $src = $srcIndex[$leaf]
        # NOTE: read/write BYTES, not text.  ReadAllText+WriteAllText rewrites
        # line endings (LF -> CRLF on this host), which shows up as a 240-line
        # diff even though the content is identical.  Bytes keep the file exact.
        $cur = [System.IO.File]::ReadAllBytes($src)
        $bak = [System.IO.File]::ReadAllBytes($b.FullName)
        $same = ($cur.Length -eq $bak.Length)
        if ($same) {
          for ($i = 0; $i -lt $cur.Length; $i++) {
            if ($cur[$i] -ne $bak[$i]) { $same = $false; break }
          }
        }
        if (-not $same) {
          [System.IO.File]::WriteAllBytes($src, $bak)
          Write-Host ("  restored " + $leaf + " from " + $b.Name) -ForegroundColor Yellow
        } else {
          Write-Host ("  " + $leaf + " already clean") -ForegroundColor DarkGray
        }
      } else {
        Write-Host ("  WARNING: cannot map backup " + $b.Name + " to a source file") -ForegroundColor Red
      }
      Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  recovery done; re-run the mutation test to get a valid verdict." -ForegroundColor Yellow
  }
}
"$PID $(Get-Date -Format o)" | Out-File -FilePath $lockFile -Encoding ascii
$script:exitCode = 0
try {

# -- mutation catalogue: (id, file, find, replace, why) -------------------------
$mutations = @(
  @{ id = "M01"; file = "rtl\clk_gen.v"; find = "else if (cnt == CLK_PER_SAMPLE - 1) cnt <= {CW{1'b0}};"; repl = "else if (cnt == CLK_PER_SAMPLE - 2) cnt <= {CW{1'b0}};"; why = "frame length off by one -> tick/bclk period wrong" },
  @{ id = "M02"; file = "rtl\clk_gen.v"; find = "bclk_half_en <= at_bclk_half;"; repl = "bclk_half_en <= at_bclk_edge;"; why = "BCK toggles at the wrong rate -> BCK period wrong" },
  @{ id = "M03"; file = "rtl\w3c\i2s_tx.v"; find = "HP_BCK  <= 1'b1;"; repl = "HP_BCK  <= 1'b0;"; why = "R-03 regression: data changes on the DAC sampling edge (setup ~0)" },
  @{ id = "M04"; file = "rtl\w3c\i2s_tx.v"; find = "i2 = b - (SLOT_BITS - DATA_BITS);"; repl = "i2 = b - (SLOT_BITS - DATA_BITS) - 1;"; why = "LSBJ off by one bit -> point-by-point compare fails" },
  @{ id = "M05"; file = "rtl\top.v"; find = "assign PA_EN_n = pa_en_n_r;"; repl = "assign PA_EN_n = ~pa_en_n_r;"; why = "U-25b regression: SD_MODE polarity inverted -> driven LOW = Shutdown = SILENT board (must be caught)" },
  @{ id = "M06"; file = "rtl\drivers\tlc5916_driver.sv"; find = "if (oe_quiet) tlc_oe_n <= ~oe_hold;"; repl = "tlc_oe_n <= ~oe_hold;"; why = "K-01 regression: OE guard removed -> narrow pulse reaches the pin" },
  @{ id = "M07"; file = "rtl\drivers\tlc5916_driver.sv"; find = "state <= STATE_LE_WAIT;"; repl = "state <= STATE_LATCH_HIGH;"; why = "K-03 regression: LE raised while CLK is still moving" },
  @{ id = "M08"; file = "rtl\top.v"; find = "rst_sync #(.STAGES(2)) u_rst_sync ("; repl = "rst_sync #(.STAGES(1)) u_rst_sync ("; why = "R-08 regression: reset release no longer 2-stage synchronised" },
  # ---- checkers / models: mutate the JUDGE, not the DUT (the deeper blind spot) ----
  @{ id = "M09"; file = "tb\checkers\chk_min_pulse.sv"; find = "if (started && run_len > 0 && run_len < MIN_CYCLES) begin"; repl = "if (1'b0) begin"; why = "A1 checker disabled -> narrow pulse no longer reported (its self-test must fail)" },
  @{ id = "M10"; file = "tb\checkers\chk_le_shift.sv"; find = "if (le === 1'b1 || le_d === 1'b1) begin"; repl = "if (1'b0) begin"; why = "A2 checker disabled -> LE-while-CLK-moves no longer reported" },
  @{ id = "M11"; file = "tb\checkers\chk_at_most_one.sv"; find = "if (n_active > 1) begin"; repl = "if (n_active > 99) begin"; why = "A4/A5 checker threshold broken -> two-active never reported" },
  @{ id = "M12"; file = "tb\models\i2s_rx_model.sv"; find = "wire [DATA_BITS-1:0] raw = extract(sr_next);"; repl = "wire [DATA_BITS-1:0] raw = extract(sr);"; why = "S2 model reads pre-shift sr -> off-by-one bit (the historic M1 failure mode)" },
  # ---- stimulus-coverage mutations: only a full value-range stimulus can catch these ----
  @{ id = "M13"; file = "rtl\w3c\i2s_tx.v"; find = "if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[SAMPLE_W-1-k];"; repl = "if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[DATA_BITS-1-k];"; why = "truncation takes LOW bits instead of high -> only value-range coverage catches it" },
  # ---- datasheet-derived constraints (K-57): the OE stable window must satisfy tw(OE) >= 500 ns ----
  @{ id = "M14"; file = "rtl\drivers\tlc5916_driver.sv"; find = "parameter integer OE_STABLE = 25"; repl = "parameter integer OE_STABLE = 8"; why = "K-57 regression: OE window back to 160 ns (< datasheet tw(OE) 500 ns) -- PARAM_OK must flag it" },
  # ---- NS4263 amp: SD counts FALLING EDGES (1 = class AB, 2 = class D) ----
  # Mutation: make the "safe state" instance pull PA_EN_n LOW (it must stay HIGH forever).
  # That is a real behaviour change: the amp would be enabled instead of blanked, and the
  # tb's falling-edge assertion (H) must catch it.
  # NOTE: an earlier attempt mutated the `pa_done` latch instead and LEAKED -- it did not
  # actually create a 2nd falling edge, so "LEAK" was a false alarm. A mutant must really
  # change behaviour (see C21 in the experience library).
  @{ id = "M15"; file = "rtl\top.v"; find = "                else             pa_en_n_r <= 1'b1;"; repl = "                else             pa_en_n_r <= 1'b0;"; why = "U-25b regression: delivery branch drives SD_MODE low -> Shutdown => SILENT board (the very bug U-25b fixed; must be caught)" },
  # ---- K-66: the Normal-Mode recovery sequence must keep LE low during the OE pulse ----
  # If LE went high during the pulse, the device would switch to SPECIAL mode instead of back
  # to Normal mode -- exactly the failure the sequence exists to prevent.
  @{ id = "M16"; file = "rtl\drivers\tlc5916_driver.sv"; find = "                    tlc_le   <= 1'b0;                  // "; repl = "                    tlc_le   <= 1'b1;                  // "; why = "K-66 regression: LE high during the recovery pulse -> device would switch to SPECIAL mode" },
  # ---- K-66: the OE low window must be a full clock period (>= tw(OE) 500 ns) ----
  # NOTE: an earlier attempt shrank the window to HALF_DIV (=500 ns) and LEAKED -- that value
  # exactly MEETS the datasheet minimum (tw(OE) >= 500 ns), so the assertion correctly passed.
  # A mutant must actually VIOLATE the spec (see C21): shrink to HALF_DIV/2 = 250 ns.
  @{ id = "M17"; file = "rtl\drivers\tlc5916_driver.sv"; find = "                                 rec_phase <  REC_OE_FALL_PH + REC_CLK_PERIOD) ? 1'b0 : 1'b1;"; repl = "                                 rec_phase <  REC_OE_FALL_PH + (HALF_DIV/2)) ? 1'b0 : 1'b1;"; why = "K-66 regression: OE window shrunk to 250 ns -> violates tw(OE) 500 ns (must be caught)" },
  # ---- R-16: the DELIVERED default must actually turn the amp on (else the board is silent) ----
  @{ id = "M18"; file = "rtl\top.v"; find = "    parameter integer PA_ON_AFTER_RESET = 1,"; repl = "    parameter integer PA_ON_AFTER_RESET = 0,"; why = "R-16/U-25b regression: default back to 0 -> SD_MODE low on Console -> SILENT board (guard I must catch it)" },
  @{ id = "M19"; file = "rtl\drivers\debounce.sv"; find = "end else if (key_cnt[ki] >= DB_CYC - 1) begin"; repl = "end else if (key_cnt[ki] >= 0) begin"; why = "T14 regression: debounce window removed -> bounce passes through -> key_down fires many times (must be caught)" },
  # NOTE (2026-09-21, third re-point): K-91 replaced the SystemVerilog size casts
  # (`24'(FULL) << 8`) with a Verilog-2001 localparam vector, because Gowin rejected the
  # casts with EX3863 and DROPPED the whole module.  Re-point at the current RTL.
  # The mutant must still change the gain by a factor of two (FULL<<7 instead of FULL<<8).
  @{ id = "M20"; file = "rtl\drivers\calib.sv"; find = "quo_r <= DIVIDEND;"; repl = "quo_r <= DIVIDEND >> 1;"; why = "T13 regression: span gain computed wrong -> calibrated full-scale does not converge to 4095 (must be caught)" },
  # NOTE (2026-09-20): M21/M22 anchors were rewritten.  The original anchors pointed at
  # the hard-coded "slave 1/2" assigns, which were replaced by a `generate for` loop when
  # N_ADC was parameterised (to support 5..6 boards).  The anchors had silently become
  # "not found" and the script used to count that as a PASS -- see K-87.
  # Both mutants now target the parameterised code, so they stay valid for any N_ADC >= 3.
  @{ id = "M21"; file = "rtl\drivers\adc_farm.sv"; find = "assign adc_cs_n[g] = adc_cs_n[0];"; repl = "assign adc_cs_n[g] = ~adc_cs_n[0];"; why = "L8/adc_farm regression: fanout slave CS inverted -> fanout mismatch (A4p) must be caught" },
  # NOTE (2026-09-20, second re-point): the aliases moved AGAIN when K-89 was fixed --
  # they now go through sample_data_alias[35:0] with a generate guard.  The alias output
  # still exists, so M22 was re-pointed to the current line.  This second skip is exactly
  # the failure mode K-87 is meant to surface, and the new exit-4 check caught it.
  @{ id = "M22"; file = "rtl\drivers\adc_farm.sv"; find = "assign sample_data1 = sample_data_alias[23:12];"; repl = "assign sample_data1 = sample_data_alias[35:24];"; why = "L8/adc_farm regression: slave 1 alias reads slave 2's slice -> sample_data1 wrong (must be caught)" },

  # ---- T54: note_manager (W3b voice allocation).  Without these the module's
  #      "PASS" would prove nothing -- a module with no mutant is UNVERIFIED (K-56).
  # NOTE: note_manager.v uses bare LF (no CRLF), so anchors must be single-line.
  # NOTE (2026-09-21, T66, FOURTH attempt -- C23 keeps biting):
  #   attempt 1: anchor was a prefix -> syntax error -> mutant never compiled
  #              (and a compile failure used to count as "caught" -- now K-105).
  #   attempt 2: dropping "& ~hold_mask[mg]" is a no-op, because the FSM already
  #              drives gate_r low explicitly -> semantically equivalent.
  #   attempt 3: dropping hold from live_mask is ALSO a no-op here, because
  #              env_active_i stays high through the hold -> voice still busy.
  # The load-bearing line is the FSM statement that actually pulls the gate down;
  # without it the ADSR never sees a falling edge and never restarts Attack.
  @{ id = "M23"; file = "rtl\w3b\note_manager.v"; find = "if (retrig_state == RT_LOW) begin"; repl = "if (1'b0 && retrig_state == RT_LOW) begin"; why = "T54 regression: retrigger never pulls the gate low -> ADSR never restarts Attack (must be caught)" },
  # NOTE (2026-09-21, T66): anchor re-pointed.  The scan was rewritten from a
  # single-cycle priority loop into a pipelined scan, so the old anchor is gone.
  # The mutant keeps the same meaning: make the age comparison strict so that
  # equal ages select NO candidate.
  # NOTE (2026-09-21, T66): anchor re-pointed.  The candidate selection was
  # rewritten from a single-cycle priority loop into a pipelined scan, so the old
  # anchor text no longer exists.  Same meaning: a tie on the oldest age must
  # still select a candidate (make the term never true -> nothing is chosen).
  # NOTE (2026-09-21, T66, third attempt -- C23 again): inverting the age
  # comparison still leaked, because tb_note_manager's small instance has no
  # envelope_bank attached, so the age-based class is rarely reached.  Target the
  # scan's selection condition instead: if "better" is never true, no candidate
  # is ever chosen -> the note is silently dropped (the original M24 intent).
  @{ id = "M24"; file = "rtl\w3b\note_manager.v"; find = "wire cand_ok = cand_pool & ~cand_hold;"; repl = "wire cand_ok = 1'b0;"; why = "T54 regression: no candidate ever selected -> note silently dropped (must be caught)" },
  @{ id = "M25"; file = "rtl\w3b\note_manager.v"; find = "if (live_mask[i] && (axis_r[i] == pitch_upd_axis_i))"; repl = "if (1'b0 && (axis_r[i] == pitch_upd_axis_i))"; why = "T54 regression: pitch_update ignored -> glissando does not track (must be caught)" },
  @{ id = "M26"; file = "rtl\w3b\note_manager.v"; find = "if (gate_mask[i] && (axis_r[i] == vel_upd_axis_i))"; repl = "if (1'b0 && (axis_r[i] == vel_upd_axis_i))"; why = "T54 regression: vel_update ignored -> dual-threshold velocity correction lost (must be caught)" },
  # NOTE (2026-09-21, T66): anchor re-pointed to the pipelined same-axis detect.
  @{ id = "M27"; file = "rtl\w3b\note_manager.v"; find = "assign same_hit[sg] = gate_mask[sg] && (axis_r[sg] == cur_axis);"; repl = "assign same_hit[sg] = 1'b0;"; why = "T54 regression: same-axis retrigger detection removed -> a repeated key eats a second voice (must be caught)" },
  @{ id = "M28"; file = "rtl\w3b\note_manager.v"; find = "assign pool_mask[pg] = 1'b1;"; repl = "assign pool_mask[pg] = 1'b0;"; why = "T54 regression: pool mask stuck at 0 -> no voice can ever be allocated (must be caught)" },

  # ---- K-106 (2026-09-21): event-queue overflow observability.  Before this
  #      fix the queue dropped events SILENTLY, and the dangerous part is not
  #      "one note lost" but a lost note_off -> the note hangs forever (the very
  #      failure mode T38 exists to prevent).  These four guard the reporting
  #      path itself: a silent-drop regression must go red, not unnoticed.
  @{ id = "M45"; file = "rtl\w3b\note_manager.v"; find = "wire fifo_drop = note_valid_i && fifo_full;"; repl = "wire fifo_drop = 1'b0;"; why = "K-106 regression: overflow detection disabled -> drops become SILENT again (must be caught)" },
  @{ id = "M46"; file = "rtl\w3b\note_manager.v"; find = "if (fifo_drop && !lost_cnt_sat) lost_cnt_r <= lost_cnt_r + 1'b1;"; repl = "if (1'b0) lost_cnt_r <= lost_cnt_r + 1'b1;"; why = "K-106 regression: lost-event counter never increments -> count lies that nothing was lost (must be caught)" },
  @{ id = "M47"; file = "rtl\w3b\note_manager.v"; find = "if (fifo_drop)                  lost_sticky_r <= 1'b1;"; repl = "if (fifo_drop)                  lost_sticky_r <= 1'b0;"; why = "K-106 regression: sticky flag never sets -> overflow invisible on the board (must be caught)" },
  @{ id = "M48"; file = "rtl\w3b\note_manager.v"; find = "if (fifo_drop && !lost_cnt_sat) lost_cnt_r <= lost_cnt_r + 1'b1;"; repl = "if (fifo_drop) lost_cnt_r <= lost_cnt_r + 1'b1;"; why = "K-106 regression: saturation removed -> count WRAPS (256 losses would read as 0, another silent failure) (must be caught)" },

  # ---- T33 / P2 (2026-09-22): the metronome and the percussion envelope.
  #      M51 is the interesting one: while building metronome.v I made the valid
  #      flag registered but left the payload combinational, so the consumer read
  #      the NEXT beat's tone -- i.e. the accent never sounded, while the accent
  #      COUNTER still counted it ("the counter says accent, the ear hears weak
  #      beat").  Same family as TROUBLESHOOTING 77: a pulse and the data it
  #      carries must be latched in the SAME cycle.
  @{ id = "M49"; file = "rtl\w3c\metronome.v"; find = "wire fire_accent = beat_i & bar_start_i & transport_i;"; repl = "wire fire_accent = 1'b0;"; why = "T33 regression: accent never fires -> every beat is a weak beat (must be caught)" },
  @{ id = "M50"; file = "rtl\w3c\metronome.v"; find = "wire fire        = fire_accent | fire_normal;"; repl = "wire fire        = beat_i;"; why = "T33 regression: events emitted even when transport is stopped (must be caught)" },
  @{ id = "M51"; file = "rtl\w3c\metronome.v"; find = "evt_inc_r   <= is_accent ? INC_ACCENT : INC_NORMAL;"; repl = "evt_inc_r   <= INC_NORMAL;"; why = "T33 regression (K-109): payload no longer tracks the accent -> counter says accent, ear hears weak beat (must be caught)" },
  @{ id = "M52"; file = "rtl\w3c\metronome.v"; find = "assign evt_axis_o        = AXIS_V;"; repl = "assign evt_axis_o        = 4'd0;"; why = "T33 regression: event loses its dedicated axis id -> lands in the normal pool and gets STOLEN when 32 voices sound (must be caught)" },
  # NOTE (2026-09-22, K-87): M53's anchor was re-pointed after perc_env_bank gained
  # the load_r stage (utilisation of peak_r, see K-111).  The old anchor text no
  # longer existed, and a skipped mutant guards NOTHING.
  @{ id = "M53"; file = "rtl\w3c\perc_env_bank.v"; find = "                                active_r <= 1'b0;      // "; repl = "                                active_r <= 1'b1;      // "; why = "T33 regression: active never clears when the envelope hits 0 -> voice never released -> HUNG NOTE (must be caught)" },
  @{ id = "M54"; file = "rtl\w3c\perc_env_bank.v"; find = "                            level_r <= level_r - DECAY_STEP[ENV_W-1:0];"; repl = "                            level_r <= level_r - 16'd1;"; why = "T33 regression: decay 67x too slow -> click lasts ~1 s instead of 20 ms (must be caught)" },
  @{ id = "M55"; file = "rtl\w3c\perc_env_bank.v"; find = "                        peak_r   <= vel_peak;"; repl = "                        peak_r   <= 16'd0;"; why = "T33 regression: velocity no longer latched at trigger -> accent/velocity response dead (must be caught)" },
  # ---- T33b (2026-09-22): uart_rx -- the score-download front end (8N1).
  #      Ported from an already-working project; these guard the pieces that a
  #      "port" can silently break: bit order, sample point, glitch rejection.
  @{ id = "M56"; file = "rtl\w3c\uart_rx.v"; find = "rx_data_o[bit_cnt] <= rx_d2;"; repl = "rx_data_o[3'd7 - bit_cnt] <= rx_d2;"; why = "T33b regression: bit order reversed (MSB-first) -> every byte is bit-reversed (must be caught)" },
  @{ id = "M57"; file = "rtl\w3c\uart_rx.v"; find = "if (clk_cnt == MID_CNT) begin"; repl = "if (clk_cnt == 16'd0) begin"; why = "T33b regression: samples at the bit EDGE instead of the middle -> marginal/noisy reception (must be caught)" },
  @{ id = "M58"; file = "rtl\w3c\uart_rx.v"; find = "if ((clk_cnt == START_MID) && (rx_d2 == 1'b1)) begin"; repl = "if (1'b0) begin"; why = "T33b regression: start-bit glitch check removed -> short noise pulses are accepted as frames (must be caught)" },
  @{ id = "M59"; file = "rtl\w3c\uart_rx.v"; find = "rx_done_o <= 1'b1;          // "; repl = "rx_done_o <= 1'b0;          // "; why = "T33b regression: completion pulse never asserts -> no byte is ever delivered (must be caught)" },
  # ---- U-18 (2026-09-22): play_seq -- the score player (tick -> events, tempo).
  #      Guards the four things that are easy to get wrong and are SILENT:
  #      filtering kind=2 out of the note stream, refusing tick_inc=0,
  #      the transport gate, and the underrun indicator.
  @{ id = "M60"; file = "rtl\w3c\play_seq.v"; find = "wire is_note_event = (evt_kind == KIND_ON) || (evt_kind == KIND_OFF);"; repl = "wire is_note_event = 1'b1;"; why = "U-18 regression: kind=2 (tempo) events are also emitted as notes -> every tempo change plays a bogus note (must be caught)" },
  @{ id = "M61"; file = "rtl\w3c\play_seq.v"; find = "if (evt_inc != 32'd0) begin"; repl = "if (1'b1) begin"; why = "U-18 regression: tick_inc=0 is applied -> phase stops advancing -> the musical clock FREEZES (contract 3.2 risk 3; must be caught)" },
  # ⚠️ 2026-09-22 夜重指锚点：`play_seq.v` 重写后：
  #    · 变量 `take` 改名成 `emit_now`，且表达式拆成 `evt_due` + 门
  #    · 🔴 **旧锚点文本现在只出现在【注释】里** ⇒ `.Replace()` 只改到注释，
  #      RTL 没变 ⇒ 回归通过 ⇒ 误报 LEAK（变成本次全量跑的 M62）
  #    ⭐ 教训（`K-87`）：**锚点腐烂 = 变异体什么都没守护**，必须重指。
  @{ id = "M62"; file = "rtl\w3c\play_seq.v"; find = "wire emit_now = run_i & evt_due;"; repl = "wire emit_now = evt_due;"; why = "U-18 regression: transport gate dropped -> events are consumed while stopped (must be caught)" },
  @{ id = "M63"; file = "rtl\w3c\play_seq.v"; find = "wire underrun = run_i & tick_i & ~evt_valid_i;"; repl = "wire underrun = 1'b0;"; why = "U-18 regression: underrun indicator disabled -> a starved buffer fails SILENTLY (K-106; must be caught)" },
  # ---- U-6 (2026-09-22): evt_merge -- joins hand-play with metronome/score.
  #      M64 is the one that matters most: it is EXACTLY the real bug found while
  #      bringing this module up (missing width on push_n truncates 1+1 to 0, so
  #      only the same-cycle collision case breaks while single-source still works).
  @{ id = "M64"; file = "rtl\w3c\evt_merge.v"; find = "wire [15:0] push_n = (push_a ? 16'd1 : 16'd0) + (push_b ? 16'd1 : 16'd0);"; repl = "wire push_n = (push_a ? 16'd1 : 16'd0) + (push_b ? 16'd1 : 16'd0);"; why = "U-6 regression: push_n loses its width -> 1+1 truncates to 0 -> a same-cycle collision pushes NOTHING (the exact bug this module exists to fix; must be caught)" },
  @{ id = "M65"; file = "rtl\w3c\evt_merge.v"; find = "wire          pop_now = (cnt_q != 16'd0);"; repl = "wire          pop_now = 1'b1;"; why = "U-6 regression: pop from an EMPTY queue -> emits garbage events that were never pushed (must be caught)" },
  @{ id = "M66"; file = "rtl\w3c\evt_merge.v"; find = "if (!will_overflow) begin"; repl = "if (1'b1) begin"; why = "U-6 regression: overflow ignored -> writes past the ring and the counter runs away (silent corruption; must be caught)" },
  @{ id = "M67"; file = "rtl\w3c\evt_merge.v"; find = "overflow_o <= 1'b1;"; repl = "overflow_o <= 1'b0;"; why = "U-6 regression: overflow flag never latches -> drops happen SILENTLY (K-106; must be caught)" },
  @{ id = "M68"; file = "rtl\w3c\evt_merge.v"; find = "prio_b_r <= ~prio_b_r;"; repl = "prio_b_r <= prio_b_r;"; why = "U-6 regression: round-robin removed -> one source always wins, the other starves under repeated collisions (must be caught)" },
  # ---- U-18 follow-up (2026-09-22): play_seq's three REAL defects, found after
  #      the module was already "green".  M69 in particular needed TWO rounds of
  #      strengthening the tb before it was caught -- counting full ticks was too
  #      coarse, and a tick=cur+1 burst cannot tell the two behaviours apart.
  @{ id = "M69"; file = "rtl\w3c\play_seq.v"; find = "wire evt_due = evt_valid_i & (evt_tick <= cur_tick_r);"; repl = "wire evt_due = evt_valid_i;"; why = "U-18 regression: the tick field is ignored again -> a forward-dated event fires immediately, and a whole chord spills across N ticks (arpeggio) (must be caught)" },
  @{ id = "M70"; file = "rtl\w3c\play_seq.v"; find = "note_data_o  <= evt_data_i;"; repl = "note_data_o  <= evt_data_i ^ 64'd1;"; why = "U-18 regression: payload corrupted while valid stays correct -> 'count right, data wrong' (the 80-hao family; must be caught)" },
  @{ id = "M71"; file = "rtl\w3c\play_seq.v"; find = "assign evt_rd_o = emit_now;"; repl = "assign evt_rd_o = 1'b0;"; why = "U-18 regression: the FIFO pop strobe is dead -> no event is ever handed over (must be caught)" },
  @{ id = "M72"; file = "rtl\w3c\play_seq.v"; find = "note_valid_o <= is_note_event;"; repl = "note_valid_o <= 1'b1;"; why = "U-18 regression: kind=2 (tempo) leaks into the note stream -> every tempo change plays a bogus note (must be caught)" },
  # ---- UART event framing (2026-09-22).  M73 is the one that matters most: it
  #      reintroduces "scan for 0xA5 anywhere", which is exactly the false-sync
  #      hazard this module's whole design avoids.
  @{ id = "M73"; file = "rtl\w3c\evt_uart_rx.v"; find = "if (idx_q == 4'd0) begin"; repl = "if (byte_is_a5 || idx_q == 4'd0) begin"; why = "framing regression: the header is accepted anywhere in the stream -> a 0xA5 payload byte causes a FALSE SYNC (the exact hazard this design avoids) (must be caught)" },
  @{ id = "M74"; file = "rtl\w3c\evt_uart_rx.v"; find = "if (all_a5_now) begin"; repl = "if (1'b0) begin"; why = "framing regression: the 9x0xA5 reset marker is no longer suppressed -> the PC reset sequence emits bogus events (must be caught)" },
  @{ id = "M75"; file = "rtl\w3c\evt_uart_rx.v"; find = "end else if (idle_expired && (idx_q != 4'd0)) begin"; repl = "end else if (1'b0) begin"; why = "framing regression: idle-gap resync disabled -> a half frame wedges the parser forever, and it never self-heals (must be caught)" },
  @{ id = "M76"; file = "rtl\w3c\evt_uart_rx.v"; find = "hdr_err_cnt_o <= sat_inc16(hdr_err_cnt_o);"; repl = "idx_q <= 4'd1;"; why = "framing regression: a wrong header byte advances anyway -> garbage is swallowed as payload instead of being rejected (must be caught)" },
  # ---- T55: oscillator_bank (64 independent oscillators).  NOTE: this file is
  #      LF-only, so every anchor must be a single line.
  # NOTE (2026-09-21, K-98): the first version of M29 was
  #   find: "addr_q <= phase_q[ADDR_MSB:ADDR_LSB];"
  #   repl: "addr_q <= phase_q[ADDR_LSB +: AW];"
  # and it LEAKED -- because ADDR_LSB=23 and AW=9, `phase_q[23 +: 9]` is bits
  # [31:23], i.e. EXACTLY the original expression.  The mutant was semantically
  # identical, so nothing could ever catch it (C23: first ask whether the mutant
  # actually violates the spec).  Replaced with a genuine off-by-one bit window.
  @{ id = "M29"; file = "rtl\w3b\oscillator_bank.v"; find = "addr_q <= phase_q[ADDR_MSB:ADDR_LSB];"; repl = "addr_q <= phase_q[ADDR_MSB-1:ADDR_LSB-1];"; why = "T55 regression: table address takes a shifted phase window -> wrong DDS mapping (must be caught)" },
  @{ id = "M30"; file = "rtl\w3b\oscillator_bank.v"; find = "if (lane_active)"; repl = "if (1'b1)"; why = "T55 regression: phase advances even when the voice is inactive -> idle voices drift (must be caught)" },
  @{ id = "M31"; file = "rtl\w3b\oscillator_bank.v"; find = "sample_bus_r[(cnt-1)*OSC_SAMPLE_W +: OSC_SAMPLE_W] <= rom_dout;"; repl = "sample_bus_r[(cnt-1)*OSC_SAMPLE_W +: OSC_SAMPLE_W] <= {OSC_SAMPLE_W{1'b0}};"; why = "T55 regression: TDM capture disabled -> every lane reads 0 -> silence (must be caught)" },
  # NOTE (2026-09-21): the original anchor was a PREFIX of a multi-line ternary,
  # so the replacement left a dangling "? test_lane_active_i[g] : ...;" -> syntax
  # error.  K-105's new check caught it (reported "MUTANT DOES NOT COMPILE"
  # instead of silently counting it as caught).  Re-pointed to a single-line
  # expression that genuinely disables the test_mode override.
  @{ id = "M32"; file = "rtl\w3b\oscillator_bank.v"; find = "? test_lane_active_i[g]"; repl = "? voice_active_i[VOICE_IDX]"; why = "T55 regression: test_mode override ignored -> T43 N-tone demo breaks (must be caught)" },

  # ---- T56: tdm_render_mixer.  LF-only file => single-line anchors.
  @{ id = "M33"; file = "rtl\w3b\tdm_render_mixer.v"; find = "if (cnt >= DEADLINE_C)"; repl = "if (cnt >= CNT_MAX_V)"; why = "T56 regression: deadline check never fires -> A6 (frame deadline) unguarded (must be caught)" },
  @{ id = "M34"; file = "rtl\w3b\tdm_render_mixer.v"; find = "if (cnt >= 1 && cnt <= CNT_LAST)"; repl = "if (1'b0)"; why = "T56 regression: accumulation disabled -> output always 0 -> silence (must be caught)" },
  @{ id = "M35"; file = "rtl\w3b\tdm_render_mixer.v"; find = "wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];"; repl = "wire [LW-1:0] cnt_sel = {LW{1'b0}};"; why = "T56 regression: every TDM slot reads voice 0 -> no summing (must be caught)" },
  @{ id = "M36"; file = "rtl\w3b\tdm_render_mixer.v"; find = "wire over_pos = ~sh[ACC_W-1] && (|sh[ACC_W-2 : SAMPLE_W-1]);"; repl = "wire over_pos = 1'b0;"; why = "T56 regression: positive saturation removed -> overflow wraps to negative (must be caught)" },
  @{ id = "M37"; file = "rtl\w3b\tdm_render_mixer.v"; find = "wire over_neg =  sh[ACC_W-1] && ~(&sh[ACC_W-2 : SAMPLE_W-1]);"; repl = "wire over_neg = 1'b0;"; why = "T56 regression: negative saturation removed -> overflow wraps positive (must be caught)" },

  # ---- T57: top.v sound chain.  This is the "board actually makes sound" step;
  #      before it, top.v drove sample_mono = 0 (silence) and every simulation
  #      still passed, so these mutants guard the thing that matters most.
  @{ id = "M38"; file = "rtl\top.v"; find = "assign sample_mono = sample_r;"; repl = "assign sample_mono = {SAMPLE_W{1'b0}};"; why = "T57 regression: top drives silence again -> board never makes a sound (must be caught)" },
  @{ id = "M39"; file = "rtl\top.v"; find = "localparam [31:0] INC_E5  = 32'h0374_D64B;"; repl = "localparam [31:0] INC_E5  = 32'h0000_1000;"; why = "T57 regression: wrong E5 phase increment -> third tone missing (must be caught)" },
  # NOTE (2026-09-21): the first version of M40 flipped the DEMO_CHORD_ON *default*
  # and LEAKED -- tb_top_sound passes DEMO_CHORD_ON(1) explicitly, so the default
  # is unobservable there (C23: a mutant that cannot change behaviour is not a
  # valid mutant).  tb_top_m0 covers the silence side explicitly instead, so M40
  # now targets the audible path itself.
  @{ id = "M40"; file = "rtl\top.v"; find = "if (mx_valid) sample_r <= mx_sample;"; repl = "if (mx_valid) sample_r <= {SAMPLE_W{1'b0}};"; why = "T57 regression: output register mutes the mixer -> chain runs but board is silent (must be caught)" },

  # ---- T32 / P1: beat_gen (the musical clock the metronome, drum machine and
  #      looper all share).  These four target the three things that actually
  #      matter: (a) the tick RATE, (b) stop holding phase, (c) the reported
  #      tick number coinciding with the tick pulse.
  #      NOTE (K-107): the phase-advance and the tick emit were originally the
  #      SAME condition, which self-locked (phase can only advance on a carry,
  #      and a carry needs the phase to have advanced) -> ZERO ticks ever.
  #      M41 guards the decoupling itself: re-merging them must go red.
  @{ id = "M41"; file = "rtl\w3c\beat_gen.v"; find = "wire phase_en = run_i;              // "; repl = "wire phase_en = run_i & phase_carry;  // "; why = "T32 regression (K-107): phase advance re-coupled to the carry -> self-lock -> no tick ever fires (must be caught)" },
  @{ id = "M42"; file = "rtl\w3c\beat_gen.v"; find = "wire do_tick  = run_i & phase_carry;"; repl = "wire do_tick  = run_i;"; why = "T32 regression: a tick on EVERY clk instead of on carry -> tick rate 50 MHz (must be caught)" },
  @{ id = "M43"; file = "rtl\w3c\beat_gen.v"; find = "if (phase_en)"; repl = "if (phase_en & ~at_bar_end)"; why = "T32 regression: phase stalls at the bar boundary -> tick interval jumps there (must be caught)" },
  @{ id = "M44"; file = "rtl\w3c\beat_gen.v"; find = "tick_cnt_o_q  <= tick_cnt_q;"; repl = "tick_cnt_o_q  <= tick_cnt_next;"; why = "T32 regression (K-107): reported tick number off by one -> bar_start no longer lands on tick_cnt 0 (must be caught)" },
  # ---- T33 (2026-09-22): perc_env_bank -- percussion amplitude envelope (attack/decay).
  @{ id = "M81"; file = "rtl\w3c\perc_env_bank.v"; find = "if (level_r <= DECAY_STEP[ENV_W-1:0]) begin"; repl = "if (level_r >= DECAY_STEP[ENV_W-1:0]) begin"; why = "T33 regression: decay never terminates -> level stalls just above 0 and active_o never clears -> HUNG NOTE (must be caught)" },
  # ---- master_mix (2026-09-22): master volume / mix stage (Q1.15 gain ramp).
  @{ id = "M82"; file = "rtl\w3c\master_mix.v"; find = "if (ramp_up)"; repl = "if (1'b0)"; why = "master_mix regression: ramp disabled -> gain never tracks the target -> volume/mute dead (must be caught)" },
  @{ id = "M83"; file = "rtl\w3c\master_mix.v"; find = "prod >>> (GAIN_W - 1);"; repl = "prod >>> (GAIN_W - 2);"; why = "master_mix regression: Q1.15 scaling off by one -> output 2x too loud (must be caught)" },
  @{ id = "M84"; file = "rtl\w3c\master_mix.v"; find = "assign valid_o  = valid_i;"; repl = "assign valid_o  = 1'b0;"; why = "master_mix regression: valid dropped -> downstream (i2s_tx) never latches the sample -> silence (must be caught)" },
  @{ id = "M85"; file = "rtl\w3c\master_mix.v"; find = "gain_r <= {GAIN_W{1'b0}};                 // 复位静音（安全态）"; repl = "gain_r <= 16'h7FFF;                 // 复位静音（安全态）"; why = "master_mix regression: reset no longer mutes -> power-on pop (must be caught)" },
  # ---- W3a semantic layer: axis_map / event_extract / param_extract (2026-09-23)
  #      These are the modules that turn ADC samples into note events
  #      (i.e. 'press a key -> sound').  An unguarded W3a chain means the
  #      instrument can silently stop making sound with every test still green.
  @{ id = "M88"; file = "rtl\w3a\axis_map.v"; find = "wire [PHASE_W-1:0] inc_delta = inc_hi - inc_lo;"; repl = "wire [PHASE_W-1:0] inc_delta = {PHASE_W{1'b0}};"; why = "W3a axis_map: the interpolation slope is forced to zero -> dual-press interpolation degrades to 'only the lower key' (glissando silently dies). Must be caught." },
  @{ id = "M89"; file = "rtl\w3a\axis_map.v"; find = "assign phase_valid_o = pos_valid_i;"; repl = "assign phase_valid_o = 1'b0;"; why = "W3a axis_map: the valid strobe is killed -> phase_inc is produced but never handed over. Must be caught." },
  @{ id = "M90"; file = "rtl\w3a\event_extract.v"; find = "if (refr[scan_axis] == 16'd0) begin"; repl = "if (1'b1) begin"; why = "W3a event_extract: the refractory gate is removed -> a bouncing key emits repeated note_on. Must be caught." },
  @{ id = "M91"; file = "rtl\w3a\event_extract.v"; find = "refr  [scan_axis] <= REFRACT_N[15:0];"; repl = "refr  [scan_axis] <= 16'hFFFF;"; why = "W3a event_extract: the refractory counter is set to its MAX -> the key is blocked forever (fires once, never again). Must be caught." },
  @{ id = "M92"; file = "rtl\w3a\event_extract.v"; find = "if (pos_i[scan_axis*POS_W +: POS_W] < REL_TH) begin"; repl = "if (pos_i[scan_axis*POS_W +: POS_W] < TRIG_TH) begin"; why = "W3a event_extract: hysteresis removed (release threshold == trigger threshold) -> a bouncing contact emits repeated on/off. Must be caught." },
  @{ id = "M93"; file = "rtl\w3a\event_extract.v"; find = "evt_axis_o  <= q_axis [q_rd];"; repl = "evt_axis_o  <= q_axis [q_rd] ^ 4'h1;"; why = "W3a event_extract: the axis field of a dequeued event is corrupted -> note_on arrives but plays the WRONG key. Must be caught." },
  @{ id = "M94"; file = "rtl\w3a\param_extract.v"; find = "vel_value_o <= vel_of(dt_hold[emit_axis]);"; repl = "vel_value_o <= 8'd255 - vel_of(dt_hold[emit_axis]);"; why = "W3a param_extract: the velocity polarity is inverted -> a fast press reads as quiet (the feature is silently backwards). Must be caught." },
  @{ id = "M95"; file = "rtl\w3a\param_extract.v"; find = "dt_hold[scan_axis] <= frame_cnt - t1_stamp[scan_axis];"; repl = "dt_hold[scan_axis] <= frame_cnt;"; why = "W3a param_extract: dt drops the t1 timestamp term -> the measured interval no longer reflects how fast the key was pressed (velocity becomes meaningless). Must be caught." },
  @{ id = "M96"; file = "rtl\w3a\param_extract.v"; find = "dt_hold[scan_axis] <= 16'd0;"; repl = "dt_hold[scan_axis] <= 16'hFFFF;"; why = "W3a param_extract: the underflow guard wraps to MAX instead of clamping to 0 -> a t2-before-t1 ordering turns the LOUDEST hit into the QUIETEST. Must be caught." },
  @{ id = "M97"; file = "rtl\w3a\param_extract.v"; find = "if (!was_above_t2[scan_axis] && t1_seen[scan_axis]) begin"; repl = "if (1'b1) begin"; why = "W3a param_extract: the edge/hold gate on the deep threshold is removed -> dt is recomputed every frame (velocity floods and jitters). Must be caught." }
)

# ---- selection ---------------------------------------------------------------
$allCount = $mutations.Count
$selNote  = ""

if ($Filter -ne "") {
  $mutations = @($mutations | Where-Object { $_.id -like "*$Filter*" })
  $selNote = "-Filter $Filter"
}
if ($File -ne "") {
  $mutations = @($mutations | Where-Object { $_.file -like "*$File*" })
  $selNote = ($selNote + " " + "-File $File").Trim()
}
if ($Changed) {
  $changedFiles = @()
  $g1 = & git -C $root diff --name-only HEAD 2>$null
  if ($g1) { $changedFiles += @($g1) }
  $g2 = & git -C $root diff --name-only --cached 2>$null
  if ($g2) { $changedFiles += @($g2) }
  $changedFiles = @($changedFiles | Where-Object { $_ -match '\S' } | Sort-Object -Unique)
  if ($changedFiles.Count -eq 0) {
    Write-Host "NOTE: -Changed found no changed files (working tree == HEAD)." -ForegroundColor Yellow
    $mutations = @()
  } else {
    $norm = @($changedFiles | ForEach-Object { $_.Replace('/', '\') })
    $mutations = @($mutations | Where-Object {
      $mf = $_.file
      @($norm | Where-Object { $mf -like "*$_*" -or $_ -like "*$mf*" }).Count -gt 0
    })
  }
  $selNote = ($selNote + " -Changed").Trim()
}

$hdr = "=== mutation testing: " + $mutations.Count + " mutant(s)"
if ($selNote -ne "") { $hdr = $hdr + "  [selected: $selNote, of $allCount]" } else { $hdr = $hdr + "  [FULL]" }
Write-Host $hdr -ForegroundColor Cyan
if ($mutations.Count -gt 0) {
  $est = [math]::Round($mutations.Count * 109 / 60.0, 1)
  Write-Host ("    estimated: ~" + $est + " min (each mutant runs the full regression)") -ForegroundColor DarkGray
}

# NOTE (2026-09-21): selecting 0 mutants is NOT a pass.  An empty selection means
# the filter matched nothing, so NOTHING was verified -- reporting PASS there would
# be exactly the "no verdict counted as success" mistake (see C29 / K-97).
if ($mutations.Count -eq 0) {
  Write-Host "FAIL: selection matched 0 mutants -- nothing was verified." -ForegroundColor Red
  Write-Host "      Check the -Filter / -File / -Changed arguments." -ForegroundColor Red
  exit 5
}
$results = @()

foreach ($m in $mutations) {
  $path = Join-Path $root $m.file
  $bak  = Join-Path $bakDir ((Split-Path -Leaf $m.file) + "." + $m.id + ".bak")
  Copy-Item $path $bak -Force
  $orig = [System.IO.File]::ReadAllText($path)

  if (-not $orig.Contains($m.find)) {
    Write-Host ("  [" + $m.id + "] SKIP -- anchor text not found in " + $m.file) -ForegroundColor Yellow
    $results += [pscustomobject]@{ Id = $m.id; Caught = $null; Note = "anchor not found" }
    # do not leave the backup behind (it is the crash-recovery sentinel)
    Remove-Item $bak -Force -ErrorAction SilentlyContinue
    continue
  }

  $mut = $orig.Replace($m.find, $m.repl)
  [System.IO.File]::WriteAllText($path, $mut)

  $out  = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\tb_all.ps1") 2>&1
  $exit = $LASTEXITCODE

  # ???? 2026-09-21 (K-105): "exit != 0" ALONE is not proof that the suite CAUGHT
  # the defect.  A mutant that fails to COMPILE also exits non-zero -- and that was
  # being counted as "caught".  A mutant which cannot even build guards NOTHING:
  # it never exercised a single check.  Distinguish the two cases.
  $outTxt   = ($out | Out-String)
  $compFail = ($outTxt -match 'syntax error|error: Invalid|error: Unable to|Unknown module type')
  $hasFail  = ([regex]::IsMatch($outTxt, "(?m)^[ \t]*[^A-Za-z]*FAIL:"))

  if ($compFail -and -not $hasFail) {
    Write-Host ("  [" + $m.id + "] !! MUTANT DOES NOT COMPILE -- invalid mutant, NOT a pass") -ForegroundColor Red
    Copy-Item $bak $path -Force
    Remove-Item $bak -Force -ErrorAction SilentlyContinue
    $results += [pscustomobject]@{ Id = $m.id; Caught = $null; Note = "mutant failed to compile (invalid)"; Restored = $true }
    continue
  }

  $caught = ($exit -ne 0)

  # restore + verify byte-identical
  Copy-Item $bak $path -Force
  $same = ([System.IO.File]::ReadAllText($path) -eq $orig)

  # NOTE (2026-09-21): the .bak is deliberately kept until here, but it MUST be
  # removed on the normal path too.  A leftover .bak is the "previous run was
  # killed" signal used by crash recovery above -- leaving them behind after a
  # clean run would make the next start report a false alarm and "restore" files
  # that were never mutated.
  Remove-Item $bak -Force -ErrorAction SilentlyContinue

  $mark = if ($caught) { "RED  (caught)" } else { "GREEN(LEAK!)" }
  $color = if ($caught) { "Green" } else { "Red" }
  Write-Host ("  [" + $m.id + "] " + $mark + "  " + $m.why) -ForegroundColor $color
  if (-not $same) { Write-Host ("        !! RESTORE MISMATCH for " + $m.file) -ForegroundColor Red }

  $results += [pscustomobject]@{ Id = $m.id; Caught = $caught; Note = $m.why; Restored = $same }
}

Write-Host ""
Write-Host "================ mutation testing summary ================" -ForegroundColor Yellow
$leaks = 0
$skipped = 0
foreach ($r in $results) {
  if ($r.Caught -eq $true)  { $s = "caught" } elseif ($r.Caught -eq $false) { $s = "LEAK" } else { $s = "skipped" }
  Write-Host ("  " + $r.Id.PadRight(5) + " " + $s.PadRight(9) + " " + $r.Note)
  if ($r.Caught -eq $false) { $leaks++ }
  if ($r.Caught -eq $null)  { $skipped++ }
}
Write-Host "=========================================================="

# integrity: every mutated file must be back to its original bytes
$bad = @($results | Where-Object { $_.Restored -eq $false }).Count
if ($bad -gt 0) {
  Write-Host ("FAIL: " + $bad + " file(s) were NOT restored properly -- check git status NOW") -ForegroundColor Red
  exit 2
}

# NOTE (K-87): a SKIPPED mutant is NOT a pass.  "anchor not found" means the mutant no longer
# guards anything -- the RTL moved and nobody re-pointed the mutation.  Counting it as
# success would let a whole module silently lose its regression guard (that is exactly
# what happened to M21/M22 on 2026-09-20).  Treat it as a failure of the SAME severity.
if ($skipped -gt 0) {
  Write-Host ("FAIL: " + $skipped + " mutation(s) were SKIPPED -- anchor text not found.") -ForegroundColor Red
  Write-Host "      A skipped mutant guards NOTHING.  Re-point the anchor at the current RTL (see K-87)." -ForegroundColor Red
  exit 4
}
if ($leaks -gt 0) {
  Write-Host ("FAIL: " + $leaks + " mutation(s) were NOT caught by the test suite (blind spot)") -ForegroundColor Red
  exit 1
}

# ---- regenerate evidence from CLEAN code (see the contamination NOTE at the top) ----
Write-Host ""
Write-Host "=== regenerating sim/evidence from the restored (clean) RTL ===" -ForegroundColor Cyan
# NOTE: assign to a variable so a non-zero child exit does not abort our flow.
$cleanOut  = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\tb_all.ps1") 2>&1
$cleanExit = $LASTEXITCODE
if ($cleanExit -ne 0) {
  Write-Host "FAIL: clean re-run of the regression did not pass -- evidence may be contaminated" -ForegroundColor Red
  exit 3
} else {
  Write-Host "OK: sim/evidence regenerated from clean code" -ForegroundColor Green
  Write-Host "PASS: every injected defect was caught by the regression suite" -ForegroundColor Green
  $script:exitCode = 0
}
}
finally {
  # Always release the lock, whatever path we took (including early `return`s).
  Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
exit $script:exitCode
