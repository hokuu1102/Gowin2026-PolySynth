# FIFO storage-write timing candidate (not yet physically accepted)

Base: d4f4c66, including the independently tested clear/new-drop repair.
Only hardware module changed: uart_tx_fifo. Accepted address/data/valid are
registered before the memory write. Reading the pending address forwards the
accepted data so queue capacity, ready/idle and tx_start/data cycles do not change.
Synchronous reset cancels the pending write. Hardware DEPTH remains 8.

Frozen reference in tb/models/uart_tx_fifo_reference.v is copied from d4f4c66
with only the module name changed. Public-boundary equivalence checks every
output, including held tx_data, for 50,412 cycles with a fixed LFSR sequence,
backpressure, full/saturating drops, clear/drop, reset, wrap and 8,372 launches.
The first A5 launch is separately checked against a literal one-cycle timing.
Baseline and candidate both PASS. Original FIFO functional regression PASS.

PnR and real top integration are required before retaining this optimization.
Rollback must keep the d4f4c66 bug fix; it must not restore the clear/drop bug.
