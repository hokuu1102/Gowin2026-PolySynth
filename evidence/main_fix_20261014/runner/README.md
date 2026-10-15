# Regression verdict repair

Public CLI reproduction: run `sim/tb_all.ps1 -Filter tb_opt04_nm_age_negative` in an isolated committed-source checkout. Original runner returned 1 although all four injected age-comparator errors were detected. Green returns 0 only for exit 1 plus exactly four FATAL lines, each the expected age mismatch, covering widths 1/7/16/17, and no PASS/unrelated failure. Summary explicitly separates expected-negative detection from functional PASS.

Second reproduction: `-Filter tb_span_need_press_width`. The diagnostic exits 0 but emits no unified PASS. Original runner counted it as accepted (red exit 0); repaired runner reports INCONCLUSIVE and fails acceptance (green exit 1). This does not invent a functional verdict for the diagnostic or hide its existence. The other no-verdict diagnostics still require explicit acceptance coverage.

Ordinary `tb_bpm_bar_quant` remains accepted with exit 0 and PASS. New real-boundary slide E2E receives the same 900 s budget as the existing slide E2E entry point. No timeout is treated as a PASS.

`../run_snapshot.py` is a stricter, fixed-commit runner with independent per-test native subprocess exit codes and timeouts. It verifies every committed RTL/TB/IP/bring-up blob plus the two write-share tests' included reference file before execution. That reference was initially missing from the isolated snapshot, not from the repository; it has been restored from the same fixed commit.

At source `e678e3b`: all 174 test entry points elaborate. Directed execution: 16 functional PASS + 1 expected-negative detection in `../targeted/`, plus 2 write-share differential PASS in `../reference_pair/`. Real UART/SPI/comparator/I2S slide test passes separately. This is NOT a completed full-suite or board acceptance claim. Four long regressions and no-verdict diagnostics from the main audit remain unresolved.
