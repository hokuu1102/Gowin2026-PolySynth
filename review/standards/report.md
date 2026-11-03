# Standards / RTL audit

Fixed source: `cd63b0773480e43b19d47f7b541d202a0a66df4d`. Baseline: `b6f83bbebf0219d49a77e4fe306f9bffddbecc8e` (before HDL). No production source or existing testbench edited.

## Reproduced findings

### P1: Mute ramps wrap to almost twice unity at low volume

Location: `rtl/w3c/master_mix.v:87-88`.

The descending ramp subtracts the 16-bit step before testing whether it overshot the target. When `gain_r < 128`, subtraction wraps. The production `right_analog_ctrl` LUT exposes this with ordinary CH1 ADC values: ADC 64 sets gain 37, then ADC 0 requests mute. On the next audio tick, gain becomes 65445 instead of 0. A constant input of 1000000 jumps from output 1129 to 1997222 (approximately +65 dB) when requesting mute. The amplitude ratio here is approximately +65 dB in the digital samples; no board listening claim is made. Main-reviewer follow-up runs 1025 audio ticks at the actual 1024-system-clock spacing: zero_count=0, tick512 returns to gain37, and tick513 wraps to65445 again. It cycles every512 audio ticks while target remains0. Both runs exit1; see `review/tb_master_zero_hold.sv`, `review/master_zero_hold_run.log`, and `review/master_zero_hold_repeat.log`. Top explicitly selects GAIN_W=16/RAMP_STEP=128 at top.v:7721-7734; top.v:7739-7742 captures mm_sample on mm_valid with only reset gating, assigns sample_mono at 7760 and feeds both I2S transmitters at 7894-7895 and 7946-7947. No separate target-zero mute gate masks the defect. Compare the remaining distance before subtracting, or widen the signed arithmetic.

Probe uses real `right_analog_ctrl.v` and `master_mix.v`, default production parameters; no force or implementation replica. `master-run1.log` and `master-run2.log` each contain the identical failure and vvp exit 1.

### P2: Runtime transpose / mode changes leave guidance lamps stuck

Location: `rtl/w3c/guide_lamp.v:475-478` and `591-594`; top wiring `rtl/top.v:8282-8284`.

ON and OFF map independently through the current transpose and keyboard/fretboard table. A C3 ON with transpose 0 lights key 5. Changing transpose to +2 before the matching OFF causes the OFF to decrement key 4 instead, leaving key 5 lit. Switching keyboard to fretboard between ON and OFF has the same failure. While subsequent score events keep `stream_alive_i` true (as the top's FIFO/nonempty wiring does), the idle timeout does not repair it. Store the ON mapping or explicitly migrate/clear guidance state when mapping controls change.

Real `guide_lamp.v` default TIMEOUT_CLKS; no force. `guide-case1-run{1,2}.log` and `guide-case3-run{1,2}.log`: expected mask 0000, actual 0020, vvp exit 1 each.

### P2: Saturating seven-reference guidance counter extinguishes active eighth note

Location: `rtl/w3c/guide_lamp.v:527`, `575-576`.

The 16 score axes can carry identical pitch notes. Eight ON events from axes 0..7 saturate the key count to 7. Seven matching OFF events then clear the lamp, although the eighth note remains active. This occurs with the production default AXIS_N=16, without capacity overflow elsewhere. Counter width must cover the valid overlap count (and ideally follow actual note identity).

`guide-case2-run{1,2}.log`: expected mask 0020, actual 0000, vvp exit 1 each. Real RTL, default params.

### P2: Serial Z effect-status command never reaches its handler

Location: `rtl/w3a/calib_cmd.v:436-466`.

`byte_is_fxstat` is defined at line 434 but omitted from `byte_is_cmd`. Consequently ASCII Z (0x5A) takes the unknown-byte path, so `fxstat_arm_q` never sets and the following subcommand cannot produce `fxstat_req_o`. Probe sends Z then binary 0 into the real default module: requests=0 (expected 1), unknown=2, commands=0. Top wires this request to `uart_ui` at top.v:1618,1780, so external Z status readback cannot work. Include the command in the frame-external command classifier.

Probe `tb_fxstat_review.sv`; `fxstat-run1.log` and `fxstat-run2.log`, compile exit 0, both vvp exit 1. Reproduction: compile `rtl/w3a/calib_cmd.v review/standards/tb_fxstat_review.sv` with `-g2012 -s tb_fxstat_review`, then vvp the compiled result.

## Reproduction

Run in repository root, PowerShell:

```powershell
& D:/iverilog/bin/iverilog.exe -g2012 -s tb_master_review -o review/standards/master.vvp rtl/w3a/right_analog_ctrl.v rtl/w3c/master_mix.v review/standards/tb_master_review.sv
& D:/iverilog/bin/vvp.exe review/standards/master.vvp
& D:/iverilog/bin/iverilog.exe -g2012 -s tb_guide_review -o review/standards/guide.vvp rtl/w3c/guide_lamp.v review/standards/tb_guide_review.sv
& D:/iverilog/bin/vvp.exe review/standards/guide.vvp +CASE=1
& D:/iverilog/bin/vvp.exe review/standards/guide.vvp +CASE=2
& D:/iverilog/bin/vvp.exe review/standards/guide.vvp +CASE=3
```

Compiles exit 0. Each failing assertion run exits 1. Each scenario repeated twice.

## Rules and scope

Read `CONTRIBUTING.md`, relevant `play_seq` and `looper` interface freezing documents, `sim/tb_all.ps1` verdict handling. The old documents describe proposed interfaces and contain stale statements that modules do not exist; they cannot be treated as verified current behavior. No style smell reported as a bug.

Detailed source inspection: `rtl/w3c/{evt_buf,seq_arb,evt_merge,looper,play_seq,guide_lamp,uart_tx_fifo,rec_dump,fx_dist,fx_trem,fx_delay,master_mix,evt_upstream,bpm_bar_quant,beat_gen}.v`; `rtl/w3a/{fader_gear,slide_position_ctrl,play_mode_ctrl,async_pluck_capture,right_analog_ctrl,axis_snapshot,axis_map}.v`; `rtl/{sync_input,rst_sync}.v`; targeted integration sections of `rtl/top.v` and pool allocation in `rtl/w3b/note_manager.v`; `constr/top.sdc`. Read existing guidance and master-mix test coverage. Main agent owns full regression.

Additional follow-up reviewed state/assignment logic in all w3b modules, all six drivers, remaining w3a control/calibration/LED modules and w3c serial/LED modules; per-file review method and focused-test status are in `coverage.csv`. Main reviewer owns detailed HDMI/clock/project checks. Limits: source review is targeted rather than a claim that every line is proved; the main reviewer completed one clean native Gowin build, detailed in R8 below. The evidence establishes simulation and native STA results, not silicon metastability rates or board behavior. No claim of complete clean audit or all-project standards compliance. Parameter-only unsupported configurations and unverified suspicions omitted. Looper A鈫払 mixing not filed: no definitive failing replacement-recording reproduction in this pass.

## Timing evidence gate (verified by main reviewer)

Main reviewer exercised the unchanged production P0-30 timing gate with fixtures. A serial_clk / pixel_clk worst setup slack of -0.5 ns is wrongly given +3.6 ns adjustment intended only for clk_sys, and passes; two control fixtures behave correctly. This violates the repository requirement that timing verdicts reflect the actual constrained clock. Evidence: `review/timing_gate/results.json`. This is a gate logic finding established with parser inputs, not a new PnR run.

## Integrated top upstream evidence supplied to Spec review

`tb_top_axis_review.sv` instantiates the production default top, forces only event stimulus at `g_sound.mg_evt_*` (source 0, axes 5/6, distinct phase increments 38702840 and 48702840, ON/ON/OFF/OFF), and enables real upstream. It captures the actual 14-byte upstream packets with the real UART FIFO ready/backpressure path. `top.v:7023` maps every non-drum to nibble 0; line 7042 feeds that nibble as `evt_axis_i`. All four packets have byte 7 = 0, so the original distinct axis identity is irrecoverable. The existing timbre test intentionally expects this nibble-zero behavior, so standalone disagreement with that test is NOT itself a spec violation: the associated bug requires the real web consumer's axis-keyed ON/OFF pairing result, being independently exercised by the Spec reviewer.

Captured packets: `top-axis-frames.hex`; run output `top-axis-run1.log` and `top-axis-run2.log` (compile 0, each vvp 1 on explicit axis-preservation assertion). Source injection uses force, unlike the three module probes; no DUT implementation or packet output is forced. This proves the actual top wiring behavior, not physical serial pin waveforms or board behavior.

## Appendix: build / simulation / tooling / CI source audit

Coverage: `review/standards/tools/coverage.csv` records 79 scripts/configurations under tools/, sim/ (excluding evidence source snapshots), root build_cli*.tcl and .github/. Python AST call/function/I-O review and PowerShell command/exit/path/verdict inspection were batched; acceptance runners, build/archive gates, shared analysis readers, transport, and CI received deeper source reads. This is source inspection, not a claim that every tool was executed. Existing static 7/7, Python syntax, PowerShell parse, and tools selftests were owned by the main reviewer and not rerun here. Historical exp/, archive/, H5/OPT/rollback/migration utilities are marked separately from current manual/acceptance entry points. No hardware, rollback, cleanup, PnR or full-regression command was run in this appendix.

### P2: Staged evidence gate validates working files instead of the commit index

Location: `tools/check_evidence.py:109-119`; empty evidence check at `85-101` has the same index/working-tree mismatch.

The script lists staged paths using git diff --cached, then opens those paths on disk. When a FAIL log is staged and a subsequent run rewrites that working file with PASS, the gate returns 0 although `git show :sim/evidence/probe.log` still contains FAIL. Likewise, a staged empty runtime log passes if the working file later becomes nonempty. This defeats the tool's advertised refusal to commit contaminated/empty evidence, especially relevant because simulations continuously rewrite tracked logs.

Real script fixture: `python review/standards/tools/probe_evidence_index.py`. It initializes a separate miniature repository entirely within the review output folder; uses git add, no commits; leaves the production repository index untouched. Two repeats each: indexed FAIL -> expected exit 1, actual 0; indexed empty -> expected 1, actual 0; clean indexed PASS control -> expected 0, actual 0. Exact staged blobs, working strings and stdout: `evidence-index-results.json`. Read indexed blobs with git show :path, and check indexed emptiness, when deciding what is about to be committed.

### P2 verification debt: Timeout diagnostic reads an old checkout PASS as this run's evidence

Location: `sim/tb_all.ps1:378-387`, with runLog only rewritten at 407.

The vvp job buffers output until it returns; on timeout the runner reads any pre-existing runLog and emits the hint that PASS has already appeared and the timeout budget may merely be too tight. The old tracked log is neither removed before starting nor checked against this run's stamp. A fresh simulation that never prints PASS thus inherits a misleading success hint from an arbitrarily old checkout log. This does not change exit 1 into PASS, but it contaminates the diagnostic explanation and can lead to unjustified budget changes or false claims that a timed-out simulation passed.

Real unchanged runner copy fixture: `python review/standards/tools/probe_timeout_stale.py`. An isolated minimal bench runs forever, prints no verdict, has a one-second budget, and starts with a PASS log timestamped 2001. Both repeats exit 1 correctly but append the false 'log already contains PASS' hint. Evidence `timeout-results.json`, `timeout-run1.log`, `timeout-run2.log`. This establishes a runner diagnostic defect, not a functional RTL failure or successful full regression. Stream the current run to a fresh log and only inspect current-run output on timeout.

### R7 — P2: Valid parent-relative Markdown references fail the production documentation guard

Location: `tools/check_doc_refs.py:189-210`. The resolver joins the document directory and reference without normalizing `..` segments before comparison with tracked paths. The real `bringup/hdmi_640x480/README.md` reference `../../rtl/hdmi/video_timing.v` is rejected despite its tracked target existing. Two runs of `python review/probe_doc_ref_resolution.py` exit 1 on the valid-link assertions; root-relative valid and missing-target negative controls behave correctly. Normalizing only for independent inspection proves 14 of the current 234 hard-error entries point to actual tracked files. Evidence: `review/doc_ref_resolution.json`, `doc_ref_resolution_run1.log`, `doc_ref_resolution_run2.log`. Normalize candidate paths before the tracked-set lookup; do not infer the remaining entries are all real broken links.

### Additional inspected limits

- Parallel runner invokes the serial runner with substring -Filter names, and has its own default skip list; no parallel run or race fixture was executed in this pass, so no new race or false-verdict claim is made.
- Root build CLI and target Tcl scripts are thin Gowin entry points. Restoring PnR options is an explicit separate utility. No settings were restored or changed.
- Several H5/OPT helpers use fixed paths or historical assumptions; these were classified as historical experiment tools rather than current production failure claims.
- CI currently checks documentation links only, as its workflow explicitly advertises. Lack of hardware/HDL CI is coverage scope, not asserted as an RTL bug.

### R8 — P1: The latest physical HDMI reset path still violates falling-edge recovery

The main reviewer completed one clean build of frozen cd63b07 with the original device/CST/SDC completed on 2026-10-20 at 14:59:43; the production wrapper returned 0. Independent analysis of the newly generated vendor report finds four `rstn_ser_2_s0/Q -> lanes[*].u_oser/RESET` recovery violations: -0.675, -0.621, -0.559, -0.411 ns. The actual constrained serial period is 8 ns; launch rising edge to capture falling edge has a 4 ns relation. Neither this clock nor this reset check is subject to the 16.4 ns clk_sys placement budget.

Locations: `rtl/hdmi/hdmi_scope.v:53-56`, `rtl/hdmi/tmds_serializer.v:36-43`. The serializer comment claims removing a register fixed recovery by citing rising-to-rising positive results; those are indeed positive, but the falling-edge checks remain negative. Do not remove the recovery check or apply the sys-clock 3.6 ns credit to make this pass. Correct the reset release/clock distribution implementation and re-run native STA before claiming closure. No board display failure or metastability rate was measured.

Test: `python review/probe_fresh_hdmi_timing.py` returns 1 on the expected all-recovery-nonnegative requirement. Report freshness and unchanged RTL/constraints are asserted; two independent HTML parsers cross-check the paths, while hold +0.183 ns and removal +0.646 ns serve as positive checks. The flat `.timing_paths` file contains no recovery section. Evidence: `review/fresh_hdmi_timing.json`, `fresh_hdmi_timing_probe.log`, `sta_actual.json`, `physical_exit.json`, and original native report under `review/physical_evidence/`. This is one physical build, not a claim of two repeated builds.

Gowin's `serial_clk Setup EP=4,TNS=-2.267` summary matches the four negative recovery paths in count and displayed sum within 1 ps (-2.266). The formally confirmed finding is the per-path recovery failure; this audit does not additionally assert an independent set of four data-setup faults from the summary label alone. The worst listed clk_sys setup -0.479 ns has relation16.4 ns; adjusting only that eligible system path to20 ns gives +3.121 ns. The actual HDMI recovery defect and R5's erroneous verdict are distinct findings.
