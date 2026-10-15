# BG timing closure: envelope + single mixer candidate

## Lineage and unchanged functionality

- Board-verified BG baseline: fa0dec8d255dee7ca99a0490de9f0f19ef6846cc.
- Accepted-for-retention envelope candidate: 7e5a4e112bea1a761eaf98261213d0824889192f. It is functionally verified, NOT timing-qualified.
- Envelope full suite completed with actual exit 0: 192 functional PASS + 1 deliberate negative + 1 separate diagnostic, zero failures, 308 source blobs verified. Its finalize records timing failure (-0.669 ns, 29 setup violations), not a false PASS.
- Envelope rollback branch: codex/keep-bg-env01-20261015 (fd635c7, same production content plus finalizer).
- Experiment branch: codex/bg-timing-mix01-20261015. Exactly ONE production module changes relative to the retained envelope candidate: rtl/w3b/tdm_render_mixer.v.
- This candidate stacks the retained envelope change and this mixer change. It is not an independent experiment starting from raw BG.
- No feature deletion, altered gain/limiter curve, added latency, changed valid timing, changed oscillator count, changed ADC/SPI/UART/FFT, relaxed constraint, new PLL/CPU/HLS, push, primary-project replacement or flashing.

## Evidence and hypothesis

The previous complete PnR's worst path is mixer square DSP output through knee arithmetic and saturation to samp_r, slack -0.669 ns. Wide excess-to-square logic is a secondary path family. The fixed limiter knee is W=2^20; excess >=W selects the unchanged ceiling. A smaller exact multiplier may shorten the path and reduce route congestion. This is not presumed to pass until fresh complete PnR.

## Algebra and parameter compatibility

For a selected quadratic branch, 0 <= excess <2^20, so the exact square needs at most 40 UNSIGNED bits. A signed original container must exceed 40 bits to retain the nonnegative square. Accordingly:

- When ACC_W+16 >40, compute 20x20->40 unsigned product, then shift by 21. All contributing bits and the existing output registers/valid path are retained.
- When ACC_W+16 <=40, retain the exact original signed multiply/shift, including its historical modular behavior.
- Large excess can produce different unused square intermediates but still takes the original ceiling branch. Public samples/valid/fault/active-count must be bit-identical every clock, including invalid intervals.

## Public-port verification

- New frozen reference is the exact prior mixer code with module renaming and removal of full-line comments only.
- Baseline and candidate both PASS tb_bg_mixer_cycle_equiv: 4096 frames per configuration, every-clock comparisons, production 32-voice configuration, wide 24-bit oscillator input, narrow accumulator and 40-bit signed-product boundary configurations. Intra-render input changes and reset during render are included.
- Non-vacuous production/wide-input tests observe both signs of the quadratic knee and the ceiling. Narrow/edge cases compare public behavior without falsely claiming knee coverage.
- Existing tb_tdm_render_mixer PASS, including fixed POLY_TARGET+7 valid latency, lane weighting, normalization, signed overflow, wide-input saturation and sticky deadline fault. Its deliberate tight-deadline instance prints a parameter ERROR as the intended negative stimulus; this is not a production error.
- Full candidate suite must independently produce 198 discovered /195 selected, 193 functional PASS +1 deliberate negative +1 separate diagnostic, 310 verified source blobs. Do not borrow envelope or BG full-regression results.

## Physical acceptance

Fresh frozen build, 76 input hashes; exactly one input differs from the envelope candidate. Native SDC/CST unchanged. Require original 16.4 ns, zero setup/hold violations, hold >=0.05 ns, nonnegative recovery/removal and complete candidate regression. Failure retains this experiment for analysis but does not replace any baseline or create a timing-qualified firmware archive.
