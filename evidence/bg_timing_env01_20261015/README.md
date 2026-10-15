# BG timing closure: first single-module candidate

## Baseline and safety

- Functional baseline: BG source `fa0dec8d255dee7ca99a0490de9f0f19ef6846cc`.
- Rollback branch: `codex/baseline-bg-merged-20261015` (8c53b82, same production source plus documentation).
- Experiment branch: `codex/bg-timing-env01-20261015`.
- No feature deletion, interface change, extra envelope cycle, constraint relaxation, new PLL, push, primary-project replacement or flashing.
- Original BG .fs remains untouched. Evaluate before promoting any candidate.

## Measured baseline, not a guessed bottleneck

`read_timing.ps1 -ProjectDir build/fft_teammate_merge_pnr01 -SourceCommit fa0dec8d255dee7ca99a0490de9f0f19ef6846cc` reproduces a failing physical timing gate.

Original budget 16.4 ns; setup -1.134 ns (20 violated endpoints), hold 0.194 ns, recovery 0.789 ns, removal 0.182 ns. CLS 26012/29952, BSRAM 83/118, DSP 29/118.

All 20 violated endpoints are represented in the complete report's top-25 setup table:

| Production module | Violated endpoints | Worst slack ns | Observed path family |
|---|---:|---:|---|
| envelope_bank | 7 | -1.134 | Sustain DSP output through ADSR next-state/clamp into per-voice output |
| tdm_render_mixer | 6 | -1.129 | Limiter/saturation path and normalization-DSP to square-DSP |
| note_manager | 2 | -0.529 | Scan control to best-index clock enable |
| calib1 | 5 | -0.282 | ADC channel selection through calibration datapath |

FFT and upstream were initial hypotheses but are not the violated setup endpoints in this baseline. Do not rewrite them without evidence. CLS occupancy is high (87%); physical route effects can outweigh algebraic improvements.

## Candidate

Change only `rtl/w3b/envelope_bank.v`. Replace the sustain-plus-decay comparison chain by an independent extended decay subtraction and underflow/clamp comparison. This removes an adder from the path launched by sustain DSP output. A compile-time fallback preserves the old modular-add behavior for unusual negative/large DECAY_STEP parameter configurations.

This is an experiment, not an assumed timing win. Next modules are considered only after this candidate has been evaluated; unsuccessful changes are retained on their experiment branch, not silently stacked onto the baseline.

## Functional checks already observed

- Baseline and candidate both PASS the new public-port, every-clock comparison against an exact renamed copy of the BG envelope source.
- New test: 32 voices, four timbres, 42000 frames, late velocity changes, release, retrigger, intra-frame input changes; also 4-voice unknown-timbre fallback and large-parameter boundary probes. No internal forcing.
- tb_envelope_bank PASS.
- tb_p5_adsr_diff PASS: 3000 frames, 108000 bus comparisons, 3456000 voice observations, zero mismatches.
- tb_timbre_adsr PASS.

Complete candidate regression and PnR remain required. No baseline full-suite result is reused for candidate acceptance. Original 16.4 ns constraints must be byte-identical; acceptance also requires zero setup/hold violations, hold >=0.05 ns and nonnegative recovery/removal.
