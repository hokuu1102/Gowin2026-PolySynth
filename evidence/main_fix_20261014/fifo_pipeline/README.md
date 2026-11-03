# FIFO storage-write timing candidate (timing gate passed, not promoted)

Base: d4f4c66, including the independently tested clear/new-drop repair.
Only hardware module changed: uart_tx_fifo. Accepted address/data/valid are
registered before the memory write. Reading the pending address forwards the
accepted data so queue capacity, ready/idle and tx_start/data cycles do not change.
Synchronous reset cancels the pending write. Hardware DEPTH remains 8.

Frozen reference in tb/models/uart_tx_fifo_reference.v is copied from d4f4c66
with only the module name changed. Public-boundary equivalence checks every
output, including held tx_data, for 50,412 cycles with a fixed LFSR sequence,
backpressure, full/saturating drops, clear/drop, reset, wrap and 8,372 launches.
The first A5 launch is separately checked against a literal one-cycle timing.
Baseline and candidate both PASS. Original FIFO functional regression PASS.

PnR and real top integration are required before retaining this optimization.
Rollback must keep the d4f4c66 bug fix; it must not restore the clear/drop bug.

Update: PnR completed, timing gate PASS. Setup 0.062 ns / hold 0.084 ns,
CLS 25383 (versus AY 0.004 / 0.211 ns, CLS 25096). This consumes 287 more CLS
and reduces hold margin, so it is not a universal timing/resource improvement.
Raw reports, fresh build log and metrics.json are archived here. The historical
in-progress snapshot below is retained for chronology; current closure details
are in ../fifo_uart_isolation/README.md. Main and board remain untouched.

## Verification snapshot 4f522c4

- `evidence/main_fix_20261014/fifo_targeted/summary.json`: all 12 selected tests explicit PASS, 279 source
  blobs checked against the pinned commit. This is NOT the complete suite.
- Public top pin trace is identical to AY: 155,459 cycles, 2,331,885 bytes,
  SHA256 E80E96100E5EC6C8058FEC0A60903324028CC6F4126214702A88D78A79A6CD1E.
- Real UART/SPI/comparator to I2S slide test: all 14 checks PASS.
- Deliberately removing read forwarding fails cycle equivalence at cycle 7;
  `no_forward_negative.log` is an expected failing mutation, NOT a DUT PASS.
- Fresh `build/fix_pnr03b_fifo`: all 73 product input hashes match. Synthesis
  completed successfully and PnR is running; no timing verdict or new archived
  firmware yet. Constraints and GPRJ unchanged. The earlier `fix_pnr03_fifo`
  attempt failed before synthesis because the file-copy harness rejected the
  project's nonstandard XML version="1"; it is not RTL evidence.
- 170 non-long candidate tests are running. Separately, old AY long tests now
  have explicit PASS for replay tail and transpose; key-to-sound and the repaired
  output-directory top_sound retry are still running. These are not candidate
  long-suite verdicts.

Until physical results are evaluated, this remains an experimental branch commit;
main checkout, remote and board are untouched. No function/protocol reduction,
no changed hardware ADC speed, and no claim of a perfect/fully accepted version.
