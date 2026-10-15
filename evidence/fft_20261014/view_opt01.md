# FFT view one-module candidate

The first complete FFT implementation failed physical timing. PnR exit 0
is not acceptance: setup -1.860 ns (79 endpoints), hold 0.045 ns,
recovery -1.952 ns. Constraints remain 16.4 ns; no exceptions added.

Only production module `rtl/hdmi/fft_spectrum_view.v` changes in this trial:
explicit narrow shift/add height and glyph addressing, and exact 6-bit
decimal digit conversion without general integer division/modulo.
No ports, state, CDC, latency, FFT size, precision or audio/control behavior
change. No improvement is claimed until complete new synthesis/PnR.

Public RGB test `tb_fft_header_digits` covers all N=0..63: 5376 checks,
atomic frame metadata, no sample/display drops. It passed on both original
and trial module. Existing FFT tone pixels and locked-bank backpressure
tests also passed after the trial.

`tb_top_scope_live` failed reproducibly because its second E expected XY,
although the accepted three-mode specification requires waveform there
when reset defaults to XY. The corrected fixture checks all three modes,
continues checking stream commits, and preserves Q/BPM isolation plus W
slide toggles. Its direct run passed. Original frozen full-suite results
remain intact and must not be silently relabelled as passing.

The STA reader also now accepts Gowin's fractional DSP usage (30.5);
it still fails every original timing/hold gate and does not round the count.

No push, main-project replacement, or board flashing has been performed.
