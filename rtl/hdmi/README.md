# H5 waveform display

`top.u_hdmi` passively taps `g_sound.u_master_mix.valid_o/sample_o`.
No backpressure or control signal returns to the audio chain. The silent
top configuration supplies zero samples at `tick_audio` instead.

`waveform_scope` stores signed 24-bit samples in a 1024-entry dual-clock
history RAM. Its source contract is at most one sample per 1024 50 MHz clocks.
The registered Gray write pointer and sticky initialized flag launch on the
falling source-clock edge, then cross two pixel-clock registers. This gives
10 ns separation from the coincident source/pixel rising edges. All paths remain timed: both clocks derive
from the same input reference. There are no new false-path exceptions.

At `(x,y)=(0,480)`, the reader freezes the observed write pointer and copies
the last 640 samples into a separate 1024x9 frame RAM (640 used). Conversion
is `clamp(240 - floor(sample/16384), 0, 479)`. The roughly 25.7 us copy is much
shorter than the 384-sample overwrite margin (7.86 ms). Display stays on the
center baseline until the history has filled once and a snapshot is ready.
The separate frame RAM prevents tearing while the history wraps during scanout.

Each column draws the inclusive vertical segment between its point and the
preceding point. Column zero draws only its own point, never a connection
to column 639 from the previous scanline. Green is `00ff00`, the baseline is
`282828`, and the background is black. The trace takes priority over baseline.
RGB, DE, HSYNC and VSYNC have matching two-register latency.

The 640-sample window is 13.1072 ms. Verified default timing is 25 MHz pixels,
800x525 total, hence 59.5238 Hz. There is no zero-crossing trigger; successive
frames display the latest window and phase can move. This preserves sample
recency and handles silence/transients without trigger timeouts.

`video_timing.v`, `tmds_encoder.v`, `tmds_serializer.v`, and `hdmi_clk.v` were
moved unchanged from the 640x480 bringup directory. Both projects reference
these files. Do not change the shared defaults without repeating the
bringup byte-level bitstream comparison.

Validation:

```powershell
python tools/h5_scope_mutations.py
powershell -NoProfile -ExecutionPolicy Bypass -File sim/tb_all.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bringup/hdmi_640x480/build_hdmi_640x480.ps1
```

The pixel oracle covers complete frames for silence, positive DC, sine,
square, full scale and signed rounding; live writes wrap history while the
display must retain its snapshot. Mutants invert samples, shift the center,
and disconnect line segments. `tb/models/hdmi_primitives_model.sv` provides
functional fixed-mode primitive boundaries for the existing top simulations;
it is neither synthesized nor evidence of physical PLL/serializer timing.
