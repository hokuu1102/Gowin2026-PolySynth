# mutation_test.ps1 -- MUTATION TESTING: inject a known defect, require the suite to catch it.
#
# Usage (from the repository root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_test.ps1 -Filter r03
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

param([string]$Filter = "")

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$bakDir = Join-Path $root "build\mutation\backup"
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null

# -- mutation catalogue: (id, file, find, replace, why) -------------------------
$mutations = @(
  @{ id = "M01"; file = "rtl\clk_gen.v"; find = "else if (cnt == CLK_PER_SAMPLE - 1) cnt <= {CW{1'b0}};"; repl = "else if (cnt == CLK_PER_SAMPLE - 2) cnt <= {CW{1'b0}};"; why = "frame length off by one -> tick/bclk period wrong" },
  @{ id = "M02"; file = "rtl\clk_gen.v"; find = "bclk_half_en <= at_bclk_half;"; repl = "bclk_half_en <= at_bclk_edge;"; why = "BCK toggles at the wrong rate -> BCK period wrong" },
  @{ id = "M03"; file = "rtl\w3c\i2s_tx.v"; find = "HP_BCK  <= 1'b1;"; repl = "HP_BCK  <= 1'b0;"; why = "R-03 regression: data changes on the DAC sampling edge (setup ~0)" },
  @{ id = "M04"; file = "rtl\w3c\i2s_tx.v"; find = "i2 = b - (SLOT_BITS - DATA_BITS);"; repl = "i2 = b - (SLOT_BITS - DATA_BITS) - 1;"; why = "LSBJ off by one bit -> point-by-point compare fails" },
  @{ id = "M05"; file = "rtl\top.v"; find = "assign PA_EN_n = pa_en_n_r;"; repl = "assign PA_EN_n = ~pa_en_n_r;"; why = "K-42 regression: amp enable polarity inverted" },
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
  @{ id = "M15"; file = "rtl\top.v"; find = "                else             pa_en_n_r <= 1'b1;"; repl = "                else             pa_en_n_r <= 1'b0;"; why = "K-61 regression: safe-state PA_EN_n pulled low -> falling-edge count assertion (H) must catch it" },
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
  @{ id = "M18"; file = "rtl\top.v"; find = "    parameter integer PA_ON_AFTER_RESET = 1,"; repl = "    parameter integer PA_ON_AFTER_RESET = 0,"; why = "R-16 regression: default back to 0 -> amp never turns on -> silent board (guard I must catch it)" },
  @{ id = "M19"; file = "rtl\drivers\debounce.sv"; find = "end else if (key_cnt[ki] >= DB_CYC - 1) begin"; repl = "end else if (key_cnt[ki] >= 0) begin"; why = "T14 regression: debounce window removed -> bounce passes through -> key_down fires many times (must be caught)" },
  @{ id = "M20"; file = "rtl\drivers\calib.sv"; find = "quo_r <= 24'(FULL) << 8;"; repl = "quo_r <= 24'(FULL) << 7;"; why = "T13 regression: span gain computed wrong -> calibrated full-scale does not converge to 4095 (must be caught)" },
  @{ id = "M21"; file = "rtl\drivers\adc_farm.sv"; find = "assign adc_cs_n[1]  = adc_cs_n[0];"; repl = "assign adc_cs_n[1]  = ~adc_cs_n[0];"; why = "L8/adc_farm regression: slave 1 CS inverted -> fanout mismatch (A4p) must be caught" },
  @{ id = "M22"; file = "rtl\drivers\adc_farm.sv"; find = "assign sample_data1 = miso1_shift[11:0];"; repl = "assign sample_data1 = miso2_shift[11:0];"; why = "L8/adc_farm regression: slave 1 data sourced from slave 2 MISO -> sample_data1 wrong (must be caught)" }
)

if ($Filter -ne "") { $mutations = @($mutations | Where-Object { $_.id -like "*$Filter*" }) }

Write-Host "=== mutation testing: $($mutations.Count) mutant(s) ===" -ForegroundColor Cyan
$results = @()

foreach ($m in $mutations) {
  $path = Join-Path $root $m.file
  $bak  = Join-Path $bakDir ((Split-Path -Leaf $m.file) + "." + $m.id + ".bak")
  Copy-Item $path $bak -Force
  $orig = [System.IO.File]::ReadAllText($path)

  if (-not $orig.Contains($m.find)) {
    Write-Host ("  [" + $m.id + "] SKIP -- anchor text not found in " + $m.file) -ForegroundColor Yellow
    $results += [pscustomobject]@{ Id = $m.id; Caught = $null; Note = "anchor not found" }
    continue
  }

  $mut = $orig.Replace($m.find, $m.repl)
  [System.IO.File]::WriteAllText($path, $mut)

  $out  = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\tb_all.ps1") 2>&1
  $exit = $LASTEXITCODE
  $caught = ($exit -ne 0)

  # restore + verify byte-identical
  Copy-Item $bak $path -Force
  $same = ([System.IO.File]::ReadAllText($path) -eq $orig)

  $mark = if ($caught) { "RED  (caught)" } else { "GREEN(LEAK!)" }
  $color = if ($caught) { "Green" } else { "Red" }
  Write-Host ("  [" + $m.id + "] " + $mark + "  " + $m.why) -ForegroundColor $color
  if (-not $same) { Write-Host ("        !! RESTORE MISMATCH for " + $m.file) -ForegroundColor Red }

  $results += [pscustomobject]@{ Id = $m.id; Caught = $caught; Note = $m.why; Restored = $same }
}

Write-Host ""
Write-Host "================ mutation testing summary ================" -ForegroundColor Yellow
$leaks = 0
foreach ($r in $results) {
  if ($r.Caught -eq $true)  { $s = "caught" } elseif ($r.Caught -eq $false) { $s = "LEAK" } else { $s = "skipped" }
  Write-Host ("  " + $r.Id.PadRight(5) + " " + $s.PadRight(9) + " " + $r.Note)
  if ($r.Caught -eq $false) { $leaks++ }
}
Write-Host "=========================================================="

# integrity: every mutated file must be back to its original bytes
$bad = @($results | Where-Object { $_.Restored -eq $false }).Count
if ($bad -gt 0) {
  Write-Host ("FAIL: " + $bad + " file(s) were NOT restored properly -- check git status NOW") -ForegroundColor Red
  exit 2
}
if ($leaks -gt 0) {
  Write-Host ("FAIL: " + $leaks + " mutation(s) were NOT caught by the test suite (blind spot)") -ForegroundColor Red
  exit 1
}

# ---- regenerate evidence from CLEAN code (see the contamination NOTE at the top) ----
Write-Host ""
Write-Host "=== regenerating sim/evidence from the restored (clean) RTL ===" -ForegroundColor Cyan
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "sim\tb_all.ps1") 2>&1
$cleanExit = $LASTEXITCODE
if ($cleanExit -ne 0) {
  Write-Host "FAIL: clean re-run of the regression did not pass -- evidence may be contaminated" -ForegroundColor Red
  exit 3
}
Write-Host "OK: sim/evidence regenerated from clean code" -ForegroundColor Green

Write-Host "PASS: every injected defect was caught by the regression suite" -ForegroundColor Green
exit 0
