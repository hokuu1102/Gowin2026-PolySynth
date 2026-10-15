# FFT normal-play quarter-band display trial

Rollback base: 628b0ab3f9d048dc05ead23e501f8f28d590682b (production inputs
identical to the viewopt candidate 9ad44c1, which was board-observed but not
strict timing accepted: setup -0.470 ns, 42 violations, hold 0.195 ns).

Only production module `rtl/hdmi/fft_spectrum_view.v` changes.
Normal play (published test_n_o=0): 0..6103.515625 Hz, first 128 stored bars
expanded by four pixels/bar across the original 512-pixel plot.
Test Mode (published N nonzero): original 0..24414.0625 Hz, all 512 bars.
FFT size, arithmetic, histogram, CDC, frame ownership, RGB latency,
height mapping and audio/control modules are unchanged. Higher-frequency
normal-play FFT results still exist; they are outside this visual viewport.

Range uses pixel-domain published frame metadata. It never samples live
sys-domain test_n_i and never changes range midway through a visible frame.
No new ports, PLLs, CPU, HLS or relaxed constraints.

New public RGB regression `tb_fft_zoom_modes` first failed on the old module
at normal N=0/x144 (green instead of expected black), then passed after
the mapping change. It tests full -> zoom -> full landmarks, preserves
the previous visible frame before vblank, and requires zero drops/overflow.
Existing FFT view and backpressure tests passed; all 64 N headers passed
5376 public RGB checks. Complete regression and physical timing are pending.

This trial is not a gap/noise-floor redesign and must not be described as
fixing all connected bars. No push, main replacement or board flashing.
