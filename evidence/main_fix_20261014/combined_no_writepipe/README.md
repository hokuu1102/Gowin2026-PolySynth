# Combined core candidate, no FIFO write pipeline

User decision: retain concurrent-clear/new-drop bug fix and all new acceptance
tests. Keep the FIFO storage-write pipeline as an alternative, not the primary
choice. Therefore this combination is AY core repairs + notice-expression
optimization + FIFO clear/drop repair + strict calibration and real dual-UART
tests. No function is removed, no interface/protocol/clock/constraint changed.
Legacy Y export stays 9 bytes; FFT remains deferred.

Alternative fully preserved on branch codex/backup-fifo-writepipe-20261014,
including its source, all four passing long regressions and PnR reports. Fresh
build products also remain under build/fix_pnr03b_fifo. No destructive Git reset,
no main checkout replacement, no push and no board flash.

In this combination uart_tx_fifo.v is exactly d4f4c66: no write pipeline,
but simultaneous clear/drop retains flag=1 and count=1. All other production
inputs are unchanged from AY. Tests from both alternatives remain available.

This combination has completed its OWN fresh synthesis/PnR and full selected
regression; see Final result below. AY and FIFO-pipeline metrics are historical
comparisons, not substituted acceptance evidence. Board acceptance is NOT_RUN;
do not call this a perfect or board-accepted version.

Chinese release handoff: [RELEASE_NOTES_ZH.md](RELEASE_NOTES_ZH.md).

## Final result

Fresh synthesis/PnR completed 2026-10-14 16:33:18 Asia/Shanghai, observed
session exit code 0. 73 frozen product inputs verified. Native sys 16.4 ns
budget unchanged. Setup 0.004 ns, hold 0.211 ns, recovery 0.866 ns,
removal 0.123 ns; zero setup/hold violations; hold >=0.05 ns gate PASS.
System Fmax 60.989 MHz; CLS 25096, BRAM 69, DSP 24. This matches AY's
reported metrics and uses 287 fewer CLS than the pipelined FIFO alternative;
it is NOT a claim of generous setup margin (only 4 ps remains).

Own complete regression: 178 discovered, 175 selected; 173 functional PASS,
one expected negative and one separately confirmed bare-parser diagnostic,
zero failed/unresolved cases. 280 source blobs verified against a529bbd.
Three historical/manual fixtures remain skipped as explicitly named in the
summary; they are NOT credited as passing. No result is borrowed from AY
or the FIFO-pipeline alternative.

Firmware copied to the user's existing archive, no old file overwritten:
AZ_combined_core_NO_WRITEPIPE_TIMING_PASS_BOARD_UNVERIFIED_20261014.fs.
Size 19913047 bytes, source/destination SHA256 identical:
28C94FE99FF13DBEAED459A1CD2B7F9531B708BA94AF2E768371499F9EC2822B.
See completion.json, metrics.json, build_exit.json and raw reports.
Software/timing accepted; board NOT_RUN; main not replaced; no push/flash.

## Suspected hang diagnosis

Read-only process/thread and artifact inspection showed a running compute
thread, accumulated CPU time increasing, about 1.3 GB private memory and
about 11 GB system free memory near completion. While inspecting, the router
advanced, wrote final reports/firmware and exited normally. This definitively
rules out a persistent hang for this run; CPU growth alone had NOT been treated
as proof of convergence. Full flow took about 36 minutes, comparable to AY's
36.5-minute run (other previous runs: 23.5 and 13.6 minutes).
No process was killed/suspended and no build was restarted.
Inherited placement/clock-route warnings remain recorded in fresh_build.log;
do not dismiss them as proof of safe real-board behavior. Monitoring paused
after successful finalization.
