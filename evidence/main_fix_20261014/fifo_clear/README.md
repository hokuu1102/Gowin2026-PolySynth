# UART FIFO concurrent clear/drop repair

Public module seam: push/data, ready/idle, tx_start/data, overflow/count.
With the downstream held busy, eight pushes fill the FIFO. After two rejected
pushes, a simultaneous clear and rejected push must clear historical losses but
retain the new loss (overflow=1, count=1). A plain clear gives 0/0.

Baseline c47edc7: `red/run.log` records FAIL (actual 0/0).
Minimal repair: the final clear assignment now includes the current rejected
push. `green/tb_uart_tx_fifo_clear_drop.log` and the original FIFO regression
both record explicit PASS. No capacity, UART timing or protocol changes.

This repair is separate from subsequent storage-write timing experiments.
