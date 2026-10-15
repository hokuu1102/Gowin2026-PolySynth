# Colored filled spectrum bars, unchanged x2 frequency range

Rollback: codex/fft-outline-x2-20261014 at 203a482. Only production module
fft_spectrum_view.v changes. Default COLOR_BARS_EN=1 makes 128 columns at
N=2048: 3 pixels filled + 1 black gap. Frequency color runs pink -> orange ->
yellow -> green -> cyan, constant within each column, using small shift/add
palette segments (no new multiplier for color).

Keep normal x2 viewport 0..12207.03125 Hz, Test Mode 0..24414.0625 Hz, existing
height floor and sample/FFT/audio/control/CDC/SDC behavior. During blanking,
take each group of 4 stored heights' maximum: normal group represents 4 bins,
Test group represents 8 bins including the original final Nyquist merge.
This reduces display resolution only and retains narrow peaks; audio and FFT
data generation are not reduced. No background waveform/branding is added.

COLOR_BARS_EN=0 restores the earlier renderer (outline or legacy fill).
Five historical fixtures now explicitly disable the new renderer while keeping
all their original assertions. Header/default-top tests run new default.

New public production-size tb_fft_color_bars first failed old default renderer
at x64 expecting pink fill. New renderer passed exact 128 black gaps + 384
colored pixels, five palette anchors, no pre-frame garbage, no fill above peak,
and vblank-atomic normal/test transitions with zero drops/overflow. A centered
impulse exposes all cells through the real periodic-Hann 2048 FFT. Independent
bin-300 tone tests the normal x2 literal x364 and Test Mode literal x212 with
the correct palette and adjacent gaps; off-tone locations remain black.
All 8 directed fixtures passed. Candidate-specific regression/PnR pending.

Prior x2 full suite ended: 184 functional PASS + 1 expected negative + 1 separate
diagnostic, zero failures, 298 source blobs. Its physical timing was not accepted
(sys Fmax 47.922 MHz, setup -4.467 ns, hold 0.042 ns). Do not borrow its pass
results or claim timing closure for this colored candidate.

User requested experimental firmware without waiting for timing closure. Keep
native 16.4 ns constraints and honest STA, archive only as EXPERIMENT_ONLY after
true build exit 0 and input hash verification, and never copy known failing
functional regression. No main replacement, push or board flashing.
