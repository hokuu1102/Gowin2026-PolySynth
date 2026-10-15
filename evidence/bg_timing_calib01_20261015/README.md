# BG timing closure: next calibration-only experiment

- Board-verified BG production base: fa0dec8d255dee7ca99a0490de9f0f19ef6846cc.
- Retained envelope candidate: 7e5a4e112bea1a761eaf98261213d0824889192f (192 functional PASS; timing not qualified).
- Parent mixer experiment: d16ac80bc0539927b426b911ee029d6468219735. Its PnR completed exit 0, setup -0.876 ns /17 violations, hold 0.191 ns /zero violations, recovery -0.914 ns. CLS25999, BSRAM83, DSP23. It is NOT timing-qualified.
- Parent rollback: codex/backup-bg-mix01-20261015 (7590df6, identical parent production code plus documentation).
- Current branch: codex/bg-timing-calib01-20261015. Relative to the parent mixer, only rtl/drivers/calib.sv changes. This stacks envelope + mixer + calibration, not three independent experiments.

## Diagnosis and scope

The parent's worst setup paths start at ADC sample_channel and end at the calib1 multiply input. Existing selected zero/span/gain muxes feed subtraction and clamping before that multiply. The recovery failure is separate: preserved serial-clock lane_reset registers -> OSER10 RESET, checked on the half cycle. It is not an audio-sample calculation error. Do NOT hide those recovery/removal checks, delete reset logic, change HDMI clocks, or relax SDC/CST.

## Calibration candidate

For each channel, compute the qualified zero + min(nonzero calibrated span, MAX_TRAVEL) threshold in parallel, then select that threshold by ch. Compare raw directly with the widened upper threshold, in parallel with the original zero-clamped subtraction. The clamp is identical to min(max(raw-zero,0),limit), without a selected-subtraction -> clamp-comparison dependency.

No extra state, sample delay, valid latency, gain quantization, filtering change, span/tare priority change, ADC rate change or feature removal. Each new read of zero/span is gated by the existing validity bitmap. The sum uses DW+2 bits so zero+limit cannot wrap.

## Observed direct checks

- Old and candidate tb_calib_equivalence PASS: 73141 every-clock public-output comparisons for four profiles; all 4096 ADC codes on eight channels, both median settings, varying travel limits, back-to-back valid, tare/span while busy, invalid slots and reset.
- Candidate tb_calib PASS: all14 checks including default clamp, tare, gain span, error rejection, underflow, median spike rejection, real motion, X/Z and valid=0 output hold.

## Staging gates

The parent full regression was still running when this candidate was prepared. No incomplete parent is claimed as accepted. wait_parent.ps1 MUST obtain its clean final summary before the new physical build and full suite start. A failed/missing/incorrect parent summary blocks the next stage. The new suite must independently verify its source (310 blobs) and run all195 selected tests:193 functional PASS +1 expected negative +1 separate diagnostic.

Freeze76 production inputs; only calib differs from the parent. Original16.4ns and CST stay byte-identical. Require zero setup/hold violations, hold>=0.05ns, nonnegative recovery/removal plus full functional acceptance before any qualified firmware archive. Existing BG and prior experiment files/branches stay intact. No push, primary-project replacement or flashing.
