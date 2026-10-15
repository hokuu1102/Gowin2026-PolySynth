# FX top-level integration (2026-10-15)

Final update: full regression and both physical profiles completed with actual exit0; `completion.json` Accepted=true. Full suite:202 functional PASS,1 expected negative,1 separate diagnostic, fail0,323 source blobs. All-effects setup/hold +0.018/+0.056ns; bypass +0.007/+0.124ns; both original16.4ns. The in-flight descriptions below are historical process records, not current pending status. Board acceptance remains NOT_RUN. See `evidence/fx_top_20261015/全开档交付说明.md` for the all-enabled profile and firmware hash.

Scope confirmed: compile-time profiles, power-on/default bypass, no key or UART protocol change. Base is the verified repaired FX branch (source92a77bb; acceptance evidence committed61d59df), not a new pull or a replacement of BJ. Unrelated review-file edits remain untouched.

## Audio routing

`tdm_render_mixer` combines all existing voices, including live/score/looper and reserved percussion. Its output now goes through FX (when selected) or the original direct connection (default), then master_mix, sample_r, both original I2S transmitters. Scope/FFT continues to observe the final master_mix output. The master volume stays after FX and can silence wet tails. No independent audio source, event arbitration or synthesis engine is removed.

- `FX_EN_MASK[0]`: distortion; bit1 chorus; bit2 delay; other bits remain nonimplemented placeholders.
- `FX_DIST_SEL`: current selectors all retain the existing hard-clip behavior.
- `FX_DIST_GAIN` Q4.12 (default16384); `FX_DIST_TRIM` Q1.15 (default8192).
- `FX_DELAY_SAMPLES`:14-bit, default8192; `FX_CHORUS_SAMPLES`:11-bit, default732.
- `FX_MIX`:8-bit dry/wet, default128; `FX_FEEDBACK`:8-bit, default96.
- `FX_TREM_DEPTH`:8-bit, default0; `FX_TREM_RATE`:8-bit phase increment, default7. Tremolo is selected by nonzero depth, independent of mask bits.

Default mask0/depth0 uses the exact old direct sample/valid path. Enabled profiles use the measured17-clock FX chain (340ns at50MHz), still within the audio frame; actual I2S verification, not this budget estimate, establishes output behavior. Ports, clocks, constraints, UART and matrix mappings are unchanged. The original UI FX indicator still reflects uart_ui state, not these temporary compile-time profiles; this step does not claim runtime control/UI completion.

`Gowin2026.gprj` registers all four FX files. Registration alone is not proof of use: the default bypass may remove all FX arithmetic and delay RAM. Only an enabled-profile report can establish enabled resource/timing behavior. Do not use bypass timing to certify all-effects timing.

## Tests before physical builds

- `tb_top_fx_audio`: three real top instances, public board and external I2S pins and UART only; real demo sound, actual UART timbre command. Before wiring: explicit FAIL because enabled-gain profile did not change either output. After wiring:79101 cycles unity-profile bit-identical to dry; driven profile differed on12122 board and12138 external data cycles;17776 live one cycles prevented silence-vacuity.
- `tb_fx_delay_production`: real16384x18 delay storage, full priming and impulse/feedback timing.16416 outputs checked, echoes at9/18/27 samples with known half/quarter/eighth amplitude; PASS. Invalid-cycle data changes are allowed and exercised.
- Existing repaired module tests stay unchanged. Full-suite results must be pinned to the new integration source, not borrowed from the repair-only version. Timeout/exit0 without an explicit PASS is not accepted; expected-negative and bare-parser diagnostic remain separate.

## Reproducible physical configurations

No unsupported Gowin CLI parameter option is assumed. Top-level parameters are the interface; the default working tree remains bypass. Each physical build uses a fresh frozen ASCII-path copy. The all-effects validation copy has exactly two declared default overrides:FX_EN_MASK=7 and FX_TREM_DEPTH=128. All other defaults and all constraints stay byte-identical. Overrides are applied explicitly only in the isolated build copy, then sealed against an independently calculated exact expected hash. Source revision, profile, overrides and every input hash are recorded; do not describe the profile as identical defaults to the source commit.

Separate manifests/results are required for bypass and all-effects. The enabled build must show fx_chain and both memory instances in the hierarchy; any pruning must be reported rather than disguised as successful integration. No timing is claimed before full PnR. Original16.4ns, zero setup/hold violations, hold>=0.05ns and nonnegative recovery/removal remain the acceptance gate, without new PLL/CPU/HLS.

Physical build results, full regression, firmware and board acceptance are pending until actual completion records exist. No push, automatic main-project replacement, firmware copy to the user's archive or flashing is authorized by this step.

## Frozen in-flight verification

Integration source:`0e98a58a8e69b13d779621de4e756b25707ee056` (later evidence/script commits do not change production). Full independent suite:207 discovered/204 selected,323 source blobs verified, requires202 functional PASS plus1 expected negative and1 separate diagnostic, zero failures. Results must come from this new snapshot, not the repaired-only version's202 selected tests.

Additional all-effects public-port fixture `tb_top_fx_all.sv` compiles against that same immutable snapshot, with the physical all-profile's FX settings mask7/depth128. It separately passed80000 cycles:9280 differing cycles on each I2S output,19117 live wet one cycles, unchanged clocks and no public X/Z. It is archived outside automatic TB discovery and does not inflate the full-suite counts. This short top test checks the real route and live output before priming; production-depth echo timing is established by the dedicated delay test, not claimed from this short window.

`all_top_exit.json` records the observed exit0 and fixture hash. `all_source.json` / `bypass_source.json` and their80-input CSVs identify physical configurations independently. Physical jobs run serially, all-effects then bypass, in fresh directories; each actual tool exit is captured separately. The wrapper's final exit0 is NOT evidence that both physical tool runs or STA passed. `finalize.ps1` checks each profile's real exit, complete reports, source/inputs, full suite and all-effects probe; it never copies or burns firmware. All-effects memory retention is additionally checked against the bypass physical report.
