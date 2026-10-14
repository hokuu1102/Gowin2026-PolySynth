# Single-slice timing experiment: notice next-state expression

User confirmed keeping legacy 9-byte export and PC tools unchanged. Base RTL is `be75440` (also in `04f32ad`); candidate changes only `rtl/top.v` notice next-state expression, see `candidate.patch`. No pipeline cycle, interface, clock or hardware parameter changes.

Known-input next-state equivalence: reject sets the pending bit regardless of the send slot; otherwise an available send slot clears it, otherwise it holds. Explicit data expression removes the pending bit from the enable predicate when clearing an already-empty latch, without changing its value. This statement does not claim equivalence for unspecified X inputs.

Actual synthesis: DFFRE remains; its CE LUT changes from LUT4 INIT `FF40` (normal request, own pending state, send ready, reject) to LUT3 INIT `F4` (normal request, send ready, reject). The tool reduced total LUT by 28 in the synthesis XML, but that is not a physical timing/CLS verdict.

## Observable regression

- Original, unaccelerated `tb_top_dump_atomic` passes before AND after: actual Hall/SPI recording, two legacy 9-byte event frames, footer, three rejection notices, deferred P query, dual UART equality and unchanged second export.
- Accelerated fixture `tb_top_notice_equiv` also passes both versions. Physical outputs UART board/ESP, CS/SCK/MOSI and I2S BCK/WS/DIN captured at every system-clock falling edge, 155459 rows / 2331885 bytes each. SHA256 identical: `E80E96100E5EC6C8058FEC0A60903324028CC6F4126214702A88D78A79A6CD1E`. Full generated traces remain in `build/notice_probe/`; hashes and logs archived here.
- The first accelerated fixture with SCLK=10 MHz failed on the UNCHANGED baseline's diagnostic value (3099 instead of the original valid range 2103..2110). It is NOT a candidate RTL failure or acceptance result. Lowering ONLY simulated SCLK to 5 MHz restores the original checks. Real hardware remains 1 MHz. `adc_farm` includes MISO synchronizers; the driver integer half-divider is only 2 clocks at the attempted 10 MHz setting. No physical ADC electrical behavior at 5 MHz is claimed.
- Re-run actual slide UART/SPI/comparator/I2S fixture at simulated 5 MHz: all 14 checks PASS. This replaces reliance on the earlier over-accelerated 10 MHz fixture, not its assertions or behavioral requirements.

Fresh synthesis/PnR at `build/fix_pnr02_notice`, empty implementation directory, all 73 product inputs equal the frozen candidate. Completed 2026-10-14 14:57:44, process exit 0. Physical gate PASS: setup 0.004 ns, hold 0.211 ns, recovery 0.866 ns, removal 0.123 ns; 0 setup / 0 hold violations. System Fmax 60.989 MHz; pixel 41.468 MHz, serial 451.671 MHz. Native 16.4 ns constraint unchanged. CLS 25096, logic 38331, registers 18881, BRAM 69, DSP 24. Relative to candidate 01, CLS decreases 314 and all 66 setup violations disappear; relative to audited main, CLS decreases 175 while the two extra DSPs implement the ratio-following core repair.

Retain the notice-expression change: simulation equivalence AND physical timing gates passed. Setup margin is only 0.004 ns, not a claim of generous/perfect timing. Full-suite long cases and hardware still NOT_ACCEPTED/NOT_RUN. Firmware is archived as `AY_fix_core_notice_TIMING_PASS_BOARD_UNVERIFIED_20261014.fs`, with matching source/destination SHA256 in `bitstream.json`; prior files and main checkout untouched. No push or board flash.
