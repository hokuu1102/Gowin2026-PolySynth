# FFT height floor trial

One production module change: fft_spectrum_view.v height mapping only.
Keep normal-play quarter-band zoom, full-band Test Mode, FFT, audio, CDC,
histogram ownership, vblank publication, RGB timing and threshold <=8.
No bar gaps or smoothing in this trial. Older zoom branch is retained.

Old magnitude 9 produced height 75; new produces height 4. Each amplitude
octave adds 32 pixels above magnitude 8, with piecewise-linear fractional
steps. Height saturates at 400. This is approximate display logarithm,
not calibrated dB and not deletion of FFT bins or audio content.

Public RGB test tb_fft_height_floor: constant weak amplitude 8, strong
amplitude 1000 and silence through the real periodic-Hann FFT. Old module
failed weak-spectrum black-at-y400 criterion; new module passed with a
visible near-baseline weak bar, visible strong bar and black silence.
Zoom mode, existing tone pixels, backpressure and header tests are retained.
Full regression and PnR must use this candidate's own frozen source.
Native 16.4 ns and hold>=0.05 ns gates remain unchanged. No push/flash/main
replacement or timing acceptance is implied by these directed tests.
