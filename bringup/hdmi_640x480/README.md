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

The pure RTL simulation passes one complete 420000-clock frame and all 256 byte values through encode/decode. The test checks every pixel, all control tokens, sync/DE counts, an internal disparity bound of +/-8, and an **output-observable DC balance** over active pixels (the running sum of `ones - zeros` of every emitted symbol, restarted at each active region, bounded by +/-8; control tokens are excluded because the DVI spec fixes them and does not disparity-balance them).

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

**Clock limitation:** The SPEC labels default A as PLL-free 25/125 MHz, but the only board input is 50 MHz. A divider can make 25 MHz, while 125 MHz cannot be obtained from 50 MHz without a PLL or another high-speed clock source. For an actually serializable output, the default implementation therefore uses one PLL with `MDIV=20`, `ODIV0=8`, and `ODIV1=40`. This is a deliberate deviation from the PLL-free requirement, not a claim that A was met. The proposed B integers (`MDIV=63`, `ODIV0=25`, `ODIV1=125`) and its SDC have **not** been built or validated; PLL operating range and Gowin acceptance remain unknown. The H1 post-synthesis netlist exposes its PLL but keeps `DVI_TX_Top` encrypted, so it does not expose the OSER10 or differential-buffer instances despite the SPEC's expectation. The new primitive wiring was checked by this project's successful Gowin build.

The board has not been tested with a display. The OSER10 bit ordering, clock lane phase, PLL jitter, hot-plug behaviour, and display compatibility remain unverified on hardware. This project does not claim H2 on-board acceptance yet.
