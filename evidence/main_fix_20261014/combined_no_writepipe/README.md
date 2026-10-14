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

This combination requires its OWN fresh synthesis/PnR. AY and FIFO-pipeline
metrics are historical comparisons, not acceptance of this combination.
Board acceptance is NOT_RUN. Build and regression results will be recorded
separately; do not call this a perfect or fully accepted version prematurely.
