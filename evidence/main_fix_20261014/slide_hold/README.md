# Play-mode release fixes (2026-10-14)

Boundary: `play_mode_ctrl` public input/output, 50 MHz, synchronous active-low reset.

Reproduced before each fix:

- Pluck axis 6 then axis 9, release both: old logic emitted OFF mask `0200`, expected `0240`.
- A slide retains axis 6 while moving to axis 7: old logic prematurely emitted axis 6 OFF.
- A deferred axis 6 OFF followed by a keyboard-mode physical OFF emitted two releases. Red log: `mode_duplicate.log` reports 3 total OFFs instead of 2 across the two sessions.

Fix: retain every hand-play gate in a bitmap; defer the slide owner's physical OFF while its position session is active; drain it on the next input-idle cycle after cancellation. A new owner ON or a forwarded owner OFF withdraws that pending release. Concurrent input is not discarded to drain the deferred release.

Green: `tb_play_mode_slide_hold`, `tb_play_mode_fret_release`, `tb_play_mode_poly_release`, and the original `tb_play_mode_ctrl` all compile/run with exit 0 and explicit PASS.

This addresses these reproducible release cases, not every historical hardware stuck-note report. Top-level wiring and full physical timing are separate acceptance stages. No board acceptance is claimed.
