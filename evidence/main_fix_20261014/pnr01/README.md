# Fresh physical candidate 01: NOT ACCEPTED

Source `be75440`, all 73 project/file input hashes match the frozen build copy. Empty implementation directory, explicit `run syn` then `run pnr`, process exit 0. Completed 2026-10-14 14:00:42 local time. Generation success is not timing acceptance.

| Metric | Audited main 9d30dd3 | Repair candidate 01 |
| --- | --- | --- |
| Physical sys clock | 50 MHz | 50 MHz |
| Native max delay | 16.4 ns | 16.4 ns |
| Sys Fmax | 61.094 MHz | 55.361 MHz |
| Setup slack | +0.032 ns | -1.663 ns |
| Setup violated endpoints | 0 | 66 |
| Hold slack | +0.047 ns | +0.128 ns |
| Hold violated endpoints | 0 | 0 |
| Recovery/removal | 1.030 / 0.123 ns | 1.177 / 0.051 ns |
| Pixel/serial Fmax | 49.217 / 358.857 MHz | 42.557 / 299.138 MHz |
| CLS | 25271 | 25410 |
| Logic/register | 38181 / 18627 | 38362 / 18881 |
| BRAM/DSP | 69 / 22 | 69 / 24 |

Hold >= 0.05 ns passes; strict setup gate fails. Do not promote this candidate or treat it as qualified hardware delivery. `.fs` archived next to prior bitstreams with `SETUP_GATE_FAIL_UNVERIFIED` in its filename; original files untouched, source/archived SHA equal, see `bitstream.json`. Board NOT_RUN, main NOT_REPLACED, remote NOT_PUSHED.

Worst setup path is NOT the new ratio arithmetic: `g_sound.u_calib_span/done_cnt_o_3_s1/Q` -> `g_sound.rd_notice_r_s1/CE`, data 17.783 ns, slack -1.663 ns. Next paths are `g_sound.u_note_manager/state_2_s0/Q` -> `vtgt_rep...RAMREG.../D`, around -1.45 ns. Timing regression therefore needs a measured, single-slice intervention at the reply/control fanout or note-manager write-enable paths, not a speculative rewrite of the divider.

The CT1094 XY placement and PR1014 `clk_d` warnings also exist in the audited-main log; they are not newly introduced here. They are retained, not hidden or declared harmless without the separate clock-path analysis.
