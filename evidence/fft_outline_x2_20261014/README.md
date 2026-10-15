# Half-band (x2) normal-play spectrum outline

Rollback: codex/fft-outline-20261014 at dd83189 (x4). One production module
changes: fft_spectrum_view.v. Default PLAY_ZOOM=2 expands normal viewport to
0..12207.03125 Hz; PLAY_ZOOM=4 restores 0..6103.515625 Hz. Test Mode remains
0..24414.0625 Hz. Legacy OUTLINE_EN=0 retains its existing filled x4 viewport.

Normal x2 stores independent bins 0..N/4-1, one pixel/bin for N=2048.
Last right neighbor clamps to the last visible bin, preventing wrap/stale reads.
Fs/4 is the right-edge axis limit; the final displayed sample is one FFT bin
below that limit. FFT/audio, height mapping, CDC, blanking publication and
line appearance do not change. No constraints are relaxed.

Public RGB tb_fft_outline_x2 initially failed old x4 at the literal x224
bin-5 landmark. New x2 passed independent peaks, no bottom fill, connected
flank, full-band Test Mode, atomic metadata and locked-snapshot backpressure.
It additionally feeds the bin-3/bin-13 fixture: bin 13, excluded by x4,
is now visible at x480. The x4 regression remains explicitly parameterized
and also passed. Complete candidate-specific regression and PnR are pending.

Previous x4 complete regression: 183 functional PASS, 1 expected negative,
1 separate diagnostic, zero failures. Physical setup -0.965 ns (65 endpoints),
hold 0.046 ns, recovery -0.980 ns: not timing accepted. Do not borrow its
regression or physical verdict for this x2 candidate. No push/main replacement.
