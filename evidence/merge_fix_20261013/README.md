# Merge fix verification — 2026-10-13

Status: software acceptance complete: 151/151 testbenches compile, 45/45 runtime regressions pass, FFT counts 4/8/16/32 all pass, setup/hold/recovery/removal pass. No hardware acceptance and no GitHub push.

Baseline: merge `f8fb7b3`, documentation baseline `6efd069`.
Detailed report: `files/20-代码/合并缺陷修复与验收-20261013.md` (repository-root path).

## Evidence boundaries

- `red_pitch`, `red_uart`, `red_led`, `red_clear`: pre-fix reproducible failures.
- `red_deferred_probe`: strengthened public UART test caught missing P reply after the first fix, before adding the bounded pending request.
- `red_atomic.log`: original merged top-level atomic export failed.
- Root test logs: intermediate repair runs, not the final snapshot acceptance set. The root `tb_span_probe.compile.log` is a mistaken invocation of a nonexistent testbench, not a valid product regression.
- `red_probe_queue_v1`: first repair iteration loses pending P/N/V requests (35/59 bytes).
- `red_probe_queue_v2`: test-oracle correction, not an RTL failure. Actual V bytes are `56303030300d0a`; Icarus interprets the string escape used in the initial assertion as `0x72` rather than CR. Corrected assertion uses an explicit hex literal; actual byte log is retained.
- `v1/`: Test Mode enabled but setup and recovery failed. Not release.
- `v2/`: isolated current-source verification, source SHA256 manifest, 42 focused + 2 audio/Test Mode + 1 additional queue-pressure runtime logs (45 total), complete audio and Test Mode samples, independent FFT acceptance and raw timing. Comment cleanup after the build preserves HDL token equivalence (separate log).
- `doc_refs.log`: existing repository-wide reference check has 165 hard errors. Do not report this check as passed. New repair documentation did not raise that count.
- `name_check.log`: skipped because the private names list is absent; not a passed name check.

User-owned `sim/evidence` and pre-existing `evidence/h5` working-tree logs are not staged as this repair's evidence.

## Reproduction tools

- Simulator: `D:/iverilog/bin/iverilog.exe`, `D:/iverilog/bin/vvp.exe`.
- Behavioral wavetable compile define: `WAVETABLE_BEHAVIORAL`.
- Focused runtime runner: `tools/run_q_adc_regression.ps1 -EvidenceDir audit_review -Tests <explicit test names>`.
- Compile-all helper in isolated snapshot: `compile_all.ps1`; compilation does not imply runtime acceptance.
- Gowin: `gw_sh.exe build_cli.tcl`, fresh ASCII snapshot with default Test Mode enabled.
- Spectral check, only after new samples have been generated: `tools/peak_count.py sim/evidence/test_mode_n<N>.csv --from-samples --col sample --fs 48828.125 --expect <N> --min-db -40` for N=4,8,16,32.

`tb_note_manager_write_share` explicitly uses legacy `MATCH_PIPE_EN=0` to compare the frozen reference cycle by cycle. Production uses `MATCH_PIPE_EN=1`; allocation/retrigger/release/polyphony behavior must be checked separately.

Bitstreams are archived outside Git into the user's specified bitstreams folder. Hardware checks remain pending even when simulation and static timing pass.

Candidate: `AC_merge_fix_testmode_20261013.fs`, SHA256 `D316944EDDA18CB5EF001B297658C3CA21500C8430FD626E45B582E6D0E10CA5`.
Failed first-iteration archive: `AB_merge_fix_v1_NOT_RELEASE_20261013.fs`, SHA256 `561F8DB0E3DD7851436FA2B76110E81170C367535C9BAD0C19073C691CD2617E`.
