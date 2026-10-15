# FFT outline display trial

Rollback: codex/fft-height-floor-20261014 at 84b254e. Only production module
fft_spectrum_view.v changes. FFT core, audio, clocks, SDC and top ports remain
unchanged. No CPU/HLS/new PLL, no loss of sound/control functionality.

Default OUTLINE_EN=1: no filled columns. A 1..2 pixel vertical tolerance
follows piecewise-linear segments; steep segments use vertical supercover
between the interpolated start/end heights of a pixel column so peaks do not
disconnect. No spatial/time smoothing or automatic gain is added.

Normal N=0 stores independent bins 0..N/8 (257 points at N=2048), 2 horizontal
pixels per bin, 0..6.103515625 kHz. Test Mode retains all full-band paired-bin
maxima and the Nyquist merge, 0..24.4140625 kHz. No FFT calculations changed.
N metadata is latched at first FFT output bin, so the complete histogram uses
one format; the pixel range uses published metadata and changes at vblank.

Snapshot memory is explicitly replicated: each copy has one synchronous read
and one common blanking-time write. Interpolation uses a small signed product.
Resource and physical timing deltas require fresh PnR; do not assume free cost.
RGB/sync latency remains 2 pixel clocks and waveform/XY are unchanged.

OUTLINE_EN=0 preserves the earlier filled histogram and normal zoom mapping.
Four historical RGB fixtures now explicitly select legacy mode; their original
assertions are unchanged. The header test runs the new default.

New public RGB fixture tb_fft_outline failed on the old default filled renderer,
then passed on new RTL. It covers black below the tone, independent bin-4 vs
bin-5 heights, connected thin descending segments, full band, published-frame
metadata, and locked snapshot survival under video backpressure (one intentional
display drop, zero input drop). All 6 directed fixtures passed. Full regression
and 16.4 ns native physical gates are pending; no push, main replacement or flash.
