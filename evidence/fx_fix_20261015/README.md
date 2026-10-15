# FX contract repairs (2026-10-15)

Base: remote main `4a669c7c7dcf767404c1d2d8ee9657d2bdbe839e`, with review-only commit `9ef6781` retained as rollback. Local branch: `codex/fx-contract-fixes-20261015`. BJ is untouched.

Three sequential production-module changes, each preceded by a failing public-interface test:

1. `fx_dist.v`: consume registered multiply results; retain five-cycle input-to-output valid latency; align data, accepted enable/trim, peak and first/second clipping flags. Count clipping once per valid enabled sample, saturating at the original 16-bit ceiling. Hard-clip function, gain/trim Q formats, placeholder selectors and port widths are unchanged.
2. `fx_trem.v`: consume the registered multiply result; retain three-cycle valid latency; accept depth/rate/enable with the current valid sample. Triangle phase and gain equations, rate zero, phase wrap and depth-zero unity remain intact. Controls changing on invalid cycles cannot alter in-flight audio.
3. `fx_chain.v`: the existing audio path is 17 clocks input-to-output, not the previously reported16. Correct only the diagnostic value and stale comments. Keep the default16-bit diagnostic bus, parameter name and all ports compatible. The parameter sizes the diagnostic bus; it never configured audio pipeline registers. No audio or valid register changes in this third slice.

Public regressions under tb/w3c independently assert arithmetic and exact cycle timing:

- `tb_fx_dist_stream_contract`: 266 checked samples, dynamic controls/invalid data, signed endpoints, both clipping stages, bypass, reset cancellation, aligned peaks and clip count.
- `tb_fx_trem_stream_contract`: 773 checked samples, dynamic enable/depth/rate, signed endpoints, depth zero, phase wrap and reset cancellation.
- `tb_fx_chain_latency_contract`: 128 samples, real default RAM depths, dry and active clipping paths, exact17-cycle sample/valid and diagnostic metadata.

Existing distortion, tremolo and chain tests pass. Original public review probes now pass, including zero valid samples with clip_count=0. Only the old chain diagnostic expectation changed from16 to17, supported by an independent measured-latency test; no old arithmetic/effect assertion was removed or relaxed. Initial chain-test compilation used an SV-reserved instance name; corrected before the actual red run, not counted as an RTL failure.

Raw red logs remain red historical evidence, not expected-negative functional acceptance. Green logs are separate. A whole-version independent regression and standalone FX synthesis are required before declaring this candidate validated. Snapshot counts/source and actual process statuses will be recorded after launch/completion; incomplete tests are not PASS.

No top-level FX attachment, UART protocol/parameter-page change, new PLL/CPU/HLS, constraint relaxation, main-project replacement, firmware generation, flashing or remote push is part of this repair. Effects remain intentionally unregistered in the main project until a separate integration step. Whole-design PnR is NOT performed here and BJ's timing is NOT inherited.

For independent synthesis, copy the four fixed FX RTL files and these two synthesis templates into a fresh ASCII-only build directory; run Gowin `gw_sh build_syn.tcl` there. The top is fx_chain itself, so effects cannot disappear simply because top.v has not connected them. This checks synthesis and resource mapping only, not integrated fit/timing.

## Completed verification

Frozen source `92a77bb182077f8ffebac9c4a30512669adaa602`: full regression session83499 actually exited0; 205 discovered, 202 selected, 200 functional PASS plus one expected negative and one separate bare-parser diagnostic, zero failures, 321 source blobs verified. The three omitted fixtures are the historical known-bug diagnostic and two WAV-export helpers, not claimed as passed. See `final_regression_summary.json`, `regression_exit.json` and `completion.json`.

Standalone synthesis session14382 actually exited0. The six frozen synthesis inputs match their manifest. Reported primitives:20 BSRAM,10 MULTALU27X18 and1 MULT12X12;886 registers,423 LUT and227 ALU. These are standalone mapped counts, not an integrated PnR resource/timing result. `finalize.ps1` actually exited0 and recorded RepairVerificationAccepted=true.

The proven defects are repaired with the above regression coverage. This does not certify absence of all possible bugs. Top integration, integrated timing, firmware and board acceptance remain NOT_RUN; BJ is not replaced and nothing has been pushed. Historical review documents and red logs retain their original context; this completed record gives the repaired-source status.
