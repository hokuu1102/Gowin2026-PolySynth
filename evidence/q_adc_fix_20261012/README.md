# Q / ADC fix evidence, 2026-10-12

Baseline source: `0906941edf688a0085f2aedbe5f6ee5dbff9495b` on converge-merge.
This directory records targeted RTL tests, not hardware acceptance or a full-suite pass.

## Red evidence

- `red_top_scope_live.log`: replace only top with baseline using `sim/check_nonempty.ps1`; real UART Q causes zero HDMI input commits in 8192 clocks.
- `red_scope_mode_switch.log`: replace only waveform_scope with baseline; four external pixel checks fail, including a request issued during XY plotting.
- `red_adc_protocol.log`: baseline ADC driver and real SPI slave models return 121 correct channel samples (zero mismatches), but legal CH0=0 still triggers fault=001 at 7.5248 ms. The small probe is retained as `evidence/q_adc_fix_20261012/diagnostic_adc_protocol.sv`; its false-dead case is diagnostic evidence for the old RTL, not a green acceptance test.
- The extended ADC regression has a new startup parameter, so swapping the old ADC into that test cannot elaborate. This infrastructure failure is NOT counted as red evidence; the compatible protocol probe above supplies that evidence instead.

## Green evidence

Run `tools/run_q_adc_regression.ps1` with Icarus Verilog. Optional `-Tests` selects individual test names. Adjacent compile/runtime logs correspond to the named test. All 10 tests passed: tb_adc_fault_window, tb_scope_mode_switch, tb_top_scope_live, tb_adc_farm, tb_waveform_scope, tb_xy_scope, tb_top_m0, tb_right_adc, tb_top_sound, tb_tdm_render_mixer. The three new regressions were rerun after strengthening their assertions; the original seven regressions passed on the same functional RTL. The saved top_sound_samples.csv contains 2048 simulated audio samples, not prerecorded material in the synthesis engine.

## Final Gowin build

Command: gw_sh build_cli.tcl; tool V1.9.12.03; device GW5AT-LV60PG484AC1/I0. Frozen RTL/SDC rerun finished at 21:25:24 local time.

| Metric | Result |
|---|---:|
| Setup violated endpoints | 0 |
| Hold violated endpoints | 0 |
| clk_sys Fmax | 57.163 MHz |
| pixel_clk Fmax | 33.325 MHz |
| serial_clk Fmax | 1312.981 MHz |
| Worst setup / hold | +0.306 / +0.115 ns |
| Worst recovery / removal | +0.086 / +0.494 ns |
| Logic / register | 36756 / 17492 |
| BSRAM / DSP | 65 / 25 |
| CLS | 24415 / 29952 (82%) |

Physical clocks remain 50 / 25 / 125 MHz. The 10 ns falling-edge launch constraint is active and includes mode_launch_s0 in the exception detail. No false-path was added. See `evidence/q_adc_fix_20261012/after_timing.html`, `evidence/q_adc_fix_20261012/after_pnr.txt`, `evidence/q_adc_fix_20261012/after_pins.html`, and `evidence/q_adc_fix_20261012/after_build.log`.

Gowin still warns about existing region/BSRAM placement and ordinary clk_d routing. HDMI recovery margin is thin despite being positive: repeated physical reset/power-on verification remains necessary. Serial-clock Fmax is not a TMDS eye-diagram measurement.

Local ignored bitstreams (not committed):

- before_W: SHA256 `7238C950EFADAA69DE3D5DC3EA989FA755076BFBBE57F1A6C54A2A0B69A9C46D`.
- Q_adc_display_fix_20261012: SHA256 `33543A641A335B1A5C06D4BF010133061AF72781E0DC1B0B1B88C2F79C1997C1`, size 19912207 bytes.

## Repository checks / limits

- PowerShell encoding audit passed (44 scripts); new runner is ASCII.
- Source/test/document whitespace check with CR-at-EOL accepted passed; existing top source mixes CRLF/LF. Raw vendor reports keep their original trailing whitespace / final blank lines and are excluded from this source-format verdict.
- Document reference audit failed with 159 existing hard errors; neither this record nor the new fix document introduced a reported reference error. See `evidence/q_adc_fix_20261012/doc_refs.log`.
- Name audit skipped: names.local.txt was absent; this is not a pass.
- No physical board test, no GitHub push. Shared UART ownership, score-frame receive gating, live XY snapshot consistency, and other feature gaps remain as listed in `files/20-代码/Q切换与ADC误报修复-20261012.md`.
