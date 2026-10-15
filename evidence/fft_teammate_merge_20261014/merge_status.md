# FFT color / teammate merge status

- Merge branch: `codex/fft-color-teammate-merge-20261014`.
- Local starting revision: `ef2d24d` (color RTL source `cf2c62c`).
- Remote main merged: `458c6a9` (includes missing upstream implementation).
- Latest feature branch merged: `84cca93`.
- User decision: Y export follows remote 14-byte format, no legacy 9-byte export switch. Downlink remains separately specified.
- Merges committed locally; frozen candidate source is `fa0dec8d255dee7ca99a0490de9f0f19ef6846cc`. Not pushed, not promoted, not flashed.

## Resolved missing-file blocker

`origin/main` lists `rtl/w3c/evt_upstream.v` in Gowin2026.gprj and instantiates `evt_upstream` in top.v, but the file is absent from both origin/main and origin/feat/s3-ble. No version is present in fetched Git history or the workspace tree searched.

This was subsequently resolved by the teammate's commit 458c6a9. No black-box stub or feature removal was used. Whole-design elaboration now succeeds.

## Conflict resolution work in progress

- top.v retains calibrated position-following slide_position_ctrl and adds remote evt_upstream integration; does not revert to autonomous slide_ramp.
- play_mode_ctrl retains round-robin held keys, per-axis release, deferred slide-owner release and tracks depth per held key. One captured pluck colliding with an axis input is deferred to an idle cycle; collision scenarios still require additional acceptance tests.
- New public-I/O test tb_play_mode_merge_release fails against remote play_mode_ctrl: releasing axis 9 incorrectly releases axis 2. The same test passes against the conflict resolution.
- Direct tests PASS: tb_play_mode_ctrl, tb_play_mode_merge_release, tb_play_mode_slide_hold, tb_play_mode_poly_release, tb_play_mode_fret_release.
- A second public test reproduces swallowed pluck/axis collisions against the original remote controller and passes against the merged controller.
- Upstream queue stress test reproduces level=6 for a full depth-4 queue (only one drop reported for two rejected events). Accepted-write gating now protects contents/count and counts rejected writes. Captured tick is stored alongside each event rather than read at dequeue time. Both the original protocol test and new queue test PASS.
- Accelerated notice fixture updated to 14-byte export with ON/OFF, axis/pitch, sequence advancement and XOR checks; original pin trace retained. Full regression will supply its actual verdict.
- Original deliberate negative age-comparator stimulus retained instead of converting the negative control to a functional green result.
- ESP32 offline suite: actual exit 0; 5/5 checks pass; nested 41-tool suite reports 852 OK, zero RED. Initial six missing-dependency failures were resolved in isolated build/merge_esp_venv, not hidden by changing checks.
- New teammate lane/layout test passes using a generated MIDI containing a melody and all four drum types. A melody-only fixture cannot satisfy that test's drum coverage requirement and is not counted as PASS.
- Frozen full FPGA regression: 196 discovered, 193 selected, 306 source blobs verified; expected final breakdown 191 functional PASS + 1 deliberate negative + 1 separate diagnostic. Running; no complete-acceptance claim yet.
- Fresh physical build uses build/fft_teammate_merge_pnr01 and 76 SHA-verified frozen inputs. Running; native constraints unchanged. User permits timing failure for this experiment; failures remain explicitly reported.
- Production FFT view and SDC are byte-identical to the prior colorful revision. Normal x2, test full band, color bars and the E three-mode cycle retained.

## Separate completed color-only regression

The pre-merge color-only source cf2c62c has 185 functional PASS, 1 expected negative and 1 separately recorded diagnostic, zero failures, 299 verified source blobs. These results must not be attributed to the merged candidate.
