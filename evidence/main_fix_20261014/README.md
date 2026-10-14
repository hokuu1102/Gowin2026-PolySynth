# Main bug repair status — 2026-10-14

Branch: `codex/fix-main-bugs-20261014`. Original audited main: `9d30dd3`. No remote push, merge into main or board flashing in this repair run. FFT is paused. All prior bitstreams and rollback commits are retained.

## Saved fixes

| Commit | Slice | Evidence |
| --- | --- | --- |
| `79bb70d` | BPM test rejects unknowns and includes A8 in verdict | `bpm/` |
| `af58c2d` | Exact calibrated position-following slide controller | `slide/red/`, `slide/green/` |
| `a30ff6f` | Every keyboard voice releases across mode changes | `play_mode/` |
| `4fb1ea4` | Successive fretboard plucks release; slide owner sustains; pending OFF cancels exactly once | `fret_release/`, `slide_hold/` |
| `be75440` | Real top slide integration; stable ratio, owned voice and actual UI gate | `slide/top_red/`, `slide/top_green/` |
| `e678e3b` | Icarus-compatible keypad test, no assertion removed | `keypad/` |
| `ca5cea4` | Reject no-verdict false acceptance, distinguish exact injected negative detection | `runner/` |

## Acceptance, not blanket completion

- Module boundary: ratio arithmetic/ownership/cancellation/known bits and play-mode release cases pass.
- Real top boundary: UART A/W + three SPI ADC models + comparator pluck -> original voice and independently decoded I2S, 14 checks pass; original main fails stationary-position criterion under the same fixture.
- All 174 test entry points elaborate. Directed execution: 18 functional PASS plus 1 exact expected-negative detection. Full-suite execution has NOT been accepted; four long regressions and historical no-verdict diagnostics remain to be resolved/reclassified with actual evidence.
- Fresh physical candidate at `build/fix_pnr01`: source `be75440`, empty implementation directory, explicit synthesis then PnR, input byte hashes 73/73 match. Still running; no final timing claim or new board-qualified bitstream yet. Required gate remains hold >= 0.05 ns. Original main is 0.047 ns and fails that gate despite native 0 setup/hold violations.
- Hardware acceptance: NOT_RUN.

## Pending protocol choice

Actual `rec_dump.v` emits legacy 9-byte A5+64-bit data frames. ESP32 documentation requests typed/checksummed 11-byte bulk frames and a separate 14-byte live uplink. The latter is not implemented in this version. Changing bulk framing affects PC replay tools; user has been asked whether to include coordinated protocol/tool changes now or retain legacy export during this core/timing repair batch. No silent protocol change has been made.
