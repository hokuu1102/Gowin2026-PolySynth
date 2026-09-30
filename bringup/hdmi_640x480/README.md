# 640x480 DVI colour bars (H2/H3)

This project generates 640x480 eight-colour bars for the Tang Console 60K HDMI TX connector. It is DVI video only: no HDMI audio, data islands, EDID, or hot-plug negotiation. The source of requirements is `SPEC.md`.

## Structure

- `rtl/video_timing.v`: parameterized horizontal/vertical counters, DE, and negative HSYNC/VSYNC.
- `rtl/color_bars.v`: eight equal vertical bars. At the default width their x ranges are 0-79 white, 80-159 yellow, 160-239 cyan, 240-319 green, 320-399 magenta, 400-479 red, 480-559 blue, and 560-639 black.
- `rtl/tmds_encoder.v`: one pure RTL DVI TMDS lane. `hdmi_top` instantiates three; only blue receives HSYNC/VSYNC control bits. Blanking resets each lane's disparity.
- `rtl/tmds_serializer.v`: four Gowin OSER10 serializers and TLVDS_OBUF pairs (three data plus forwarded clock).
- `rtl/hdmi_clk.v`: replaceable clock-source boundary. The default uses a PLL to make 25/125 MHz. `USE_252=1` selects a proposed 25.2/126 MHz PLL configuration.
- `rtl/hdmi_top.v`: reset, colour, encoder, and output connections. H/V active, porch, sync, and total are parameters. `H_TOTAL` and `V_TOTAL` default to sums of the other parameters; change them together when selecting another mode.
- `tb/`: pure RTL decoder, full-frame and exhaustive-value self-check, and mutation checks. The testbench does not instantiate Gowin primitives.
- `constr/`, `.gprj`, and build script: pin, timing, and Gowin build files.

The default mode is 800 clocks per line, 525 lines per frame, 25.000 MHz pixel clock, and 59.524 Hz refresh. HSYNC is low for 96 clocks and VSYNC for 2 lines. The CST is byte-for-byte copied from `bringup/hdmi_ref_720p/hdmi_ref_720p.cst`.

## Run

From this directory in PowerShell:

```powershell
iverilog -g2012 -s tb_hdmi_640x480 -o tb/sim.vvp rtl/video_timing.v rtl/color_bars.v rtl/tmds_encoder.v tb/tmds_decoder.sv tb/tb_hdmi_640x480.sv
vvp tb/sim.vvp
powershell -NoProfile -ExecutionPolicy Bypass -File .\tb\run_mutations.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\build_hdmi_640x480.ps1
```

Pass `-GwSh <path>` to the last command if Gowin is installed elsewhere. The build script uses a temporary drive alias when the work directory contains non-ASCII characters; Gowin 1.9.12.03 could open the `.gprj` but failed to open the generated `.prj` through the Chinese path. All generated files stay in this work directory. To use `USE_252=1`, also change the two generated-clock ratios in the SDC from 20/8 and 20/40 to 63/25 and 63/125, respectively.

## Verification and limits

The pure RTL simulation passes one complete 420000-clock frame and all 256 byte values through encode/decode. The test checks every pixel, all control tokens, sync/DE counts, an internal disparity bound of +/-8, and an **output-observable DC balance** over active pixels (the running sum of `2*ones10(symbol)-10` for every emitted data symbol, restarted at each active region, bounded by +/-8). Control tokens are checked for their exact values separately; their 10-bit DC biases are 0, -2, 0, and +2 in `(c1,c0)` order 00, 01, 10, 11. The encoder resets its disparity during blanking.

**Six mutations** each produced a `FAIL` line, and the source files were never modified (the script compiles a temporary mutant copy):

| # | Mutation | Red criterion |
|---|---|---|
| 1 | `H_TOTAL = 799` | `TIMING_COUNT` |
| 2 | first two colours swapped | `COLOR_BAR` |
| 3 | HSYNC polarity inverted | `SYNC_POLARITY_DE` |
| 4 | `(c0,c1)=(1,0)` control code replaced | `TMDS_CONTROL_TOKEN` |
| 5 | blanking `(0,0)` code `1101010100` replaced | `TMDS_CONTROL_TOKEN` |
| 6 | disparity update forced to 0 | `TMDS_DC_BALANCE` |

Mutations 4-6 and the output-observable DC balance check were added during the 2026-09-30 adversarial review: the first three only exercised timing/colour, and the original disparity bound read the DUT's own register, so forcing the disparity update to 0 made it vacuously true. Mutation 6 proves the replacement catches that class of fault.

The default Gowin build produced a `.fs` and reported **0 setup and 0 hold violated endpoints**. The timing report lists **176.035 MHz** actual Fmax for `pixel_clk`, compared with 25.000 MHz required. P/N outputs are reported as LVDS25 at the H1 pins. The build still reports `PR1014` on `clk_d` using generic clock routing. Source width truncation warnings in the encoder also remain. None of this verifies signal quality or monitor lock.

**Clock limitation:** The only board input is 50 MHz. A divider can make 25 MHz, while 125 MHz requires a PLL or another high-speed clock source. The default A implementation uses one PLL with `MDIV=20`, `ODIV0=8`, and `ODIV1=40`. The B configuration (`MDIV=63`, `ODIV0=25`, `ODIV1=125`) has a saved bitstream and PnR report, but `bitstreams/B_pnr.log` reports `PA1019`: its calculated VCO is 3150 MHz, outside the stated 700-1400 MHz range. Its successful build and timing summary therefore do not establish a usable 25.2/126 MHz clock. The H1 post-synthesis netlist exposes its PLL but keeps `DVI_TX_Top` encrypted, so it does not expose the OSER10 or differential-buffer instances despite the SPEC's expectation. The new primitive wiring was checked by this project's successful Gowin build.

## Changing video mode

Set the ten H/V timing parameters on `hdmi_top`; the derived totals can keep their defaults. `video_timing` and `color_bars` use those parameters, including eight bars scaled by `H_ACTIVE/8`. The full-frame testbench is fixed to 640x480: update its H/V constants, coordinate widths, and `bar()` thresholds when verifying another mode. Choose a pixel/serial clock pair at 1:5, update the PLL settings in `rtl/hdmi_clk.v`, and update both generated-clock ratios in `constr/hdmi_640x480.sdc`. The project name and build artifacts still say 640x480. For 1920x1200 at 154 MHz, the serializer clock must be 770 MHz and each TMDS lane carries 1.54 Gb/s; the existing 25/125 and 25.2/126 MHz modes cannot provide this. Recheck PLL VCO/output limits, IO/OSER10 rate, and post-route timing for that mode. The saved 176.035 MHz pixel-clock Fmax is for the 640x480 implementation only.

The board has not been tested with a display. The OSER10 bit ordering, clock lane phase, PLL jitter, hot-plug behaviour, and display compatibility remain unverified on hardware. This project does not claim H2 on-board acceptance yet.

## Liveness LED

led_hb drives the Console CFG_LED green channel (SYS_ACT, ball V13) - the same ball the main project uses for led_heartbeat. It runs in the 50 MHz input clock domain and is deliberately **not** gated by st_n, so it proves "bitstream configured and input clock alive" even with a stuck reset key. The blink rate also reports PLL lock:

- **~1 Hz** (0.5 s on / 0.5 s off): running, PLL locked
- **~5 Hz** (0.1 s on / 0.1 s off): running, PLL NOT locked
- **dark**: not configured, or no 50 MHz input clock

This exists because the first on-board attempt produced a completely black screen, which cannot distinguish "not programmed", "programmed but PLL unlocked", and "PLL locked but TMDS or display problem".
### Control-token correction (2026-09-30)

The TMDS control codes for `(c0,c1) = (1,0)` and `(0,1)` were **swapped** in `rtl/tmds_encoder.v`, and the same wrong table had been copied into the testbench `token()` reference and into `tb/tmds_decoder.sv`. Encode/decode round-trips therefore passed while the emitted control codes were wrong - which is why the board showed a live ~1 Hz heartbeat and a locked PLL but a completely black screen. All three tables are now corrected against `nand2mario/tangcore` `src/hdmi2/tmds_channel.sv` (hdl-util/HDMI), an implementation that runs on this exact board. Mutation `TOKEN_CTL10` now re-injects that exact historical bug. Electrical configuration was returned to the combination proven on-board by the official-IP control builds (TLVDS_OBUF + pair syntax -> LVDS25); the ELVDS_OBUF + pair-syntax attempt was measured black, matching a third-party report that ELVDS plus the pair syntax on TRUELVDS-capable pins configures true differential, which is invalid at 3.3 V.