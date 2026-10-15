# BJ frozen release evidence

Production source: `2723b8da7ce46a880d5c67d82b36b448ef232fdd`.
Release branch: `codex/release-bj-20261015`; tag: `bj-final-20261015`.

- `regression_summary.json`: full isolated-source suite verdicts; 193 functional PASS, one expected negative, one separate diagnostic, zero failures, 310 verified source blobs.
- `product_inputs.csv`: all 76 frozen physical-build input SHA256 values. `build_verified.tcl` is the archived build driver; compare it to the manifest entry named `tools/build_target_pnr.tcl`.
- `build_exit.json` and `regression_exit.json`: observed process termination records.
- `completion_at_generation.json`: original candidate acceptance record, including firmware SHA256 and the board-not-run state at generation time. Local path fields are historical provenance, not portable build configuration.
- `timing_full.html`, `timing_paths.txt`, `resource_report.txt`, `build.log`: original complete physical reports and build output, copied without regeneration.

Board status subsequently became BASIC_FUNCTIONS_VERIFIED; no itemized formal board acceptance or long-duration record was supplied. See the release notes under files/20-代码 for scope and limitations. Do not relabel the original generated record as a fully instrumented board acceptance.

All three cumulative optimizations preserve public cycles and behavior. Original 16.4 ns constraints, all features and original hardware clock scheme remain unchanged. No post-freeze remote functionality is included. Binary firmware stays outside Git under the repository's generated-artifact policy.
