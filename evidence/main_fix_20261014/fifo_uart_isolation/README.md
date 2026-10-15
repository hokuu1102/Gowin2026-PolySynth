# FIFO candidate acceptance closure

This round changes tests/runner only, not hardware RTL or timing constraints.

## Four previously inconclusive entries

| Entry | Finding and acceptance |
|---|---|
| tb_span_need_press_width | Previously printed ok but no PASS. Require a real public prompt rising edge, nonzero width, no unknown status; watchdog is fatal. Explicit PASS at 9f0c8da. Suppressing start deliberately FAILs. |
| tb_span_released_stable | Previously observation-only. Require real ADC samples, stable input range, positive calibration progress and zero rejects; unknown public status/watchdog fail. Explicit PASS at 9f0c8da. This proves the 60 ms progress scenario, not full 16-axis completion or physical calibration accuracy. |
| tb_span_with_real_adc_farm | Require positive progress and zero rejects using original real SPI models and rates. Unknown public status/watchdog fail. Explicit PASS at 9f0c8da. No simulation timing acceleration or RTL change. |
| tb_evt_uart_rx_screen | Intentionally feeds screen bytes to the BARE score parser; eight spurious events are reproduced. Exact diagnostic marker checked separately; **zero functional PASS credited**. Current top routes score from independent ESP UART, not the historical copied gate fixture. |

## Real top isolation seam

Physical board and ESP UART pins driven at 500 kbaud, no producer forcing,
no replicated gating. Observe actual evt_uart_rx and uart_ui public outputs.
Ten board screen frames containing A5: zero score events. While two board frames
are arriving, one ESP 9-byte frame must produce one exact big-endian word
070010002000c800, without losing the board frames. Final fixture PASS.

Fixture development failures retained, not passed off as RTL faults:
1. Static send task arguments were shared by concurrent physical senders:
   first attempt received no ESP event. Make tasks automatic (per-invocation
   arguments and bit counters), no RTL change.
2. Test expected little-endian; public evt_uart_rx contract is big-endian.
   `automatic_task.log` records actual correct 070010002000c800; fixing only
   the independent literal yields `bigendian_task.log` PASS.
3. `crosswire_negative.log`: deliberately connect ESP receiver to board pin in
   a temporary top copy. FAIL at first isolation check, seven spurious events.
   This proves the new fixture detects incorrect physical-port wiring.
4. `prompt_no_start_negative.log`: suppress prompt start in a temporary TB copy.
   FAIL at rising-edge assertion; not a functional DUT failure.

## Physical result (candidate 4f522c4)

Fresh syn + PnR exit 0, completed 2026-10-14 15:24:22 Asia/Shanghai.
Setup 0.062 ns, hold 0.084 ns, recovery 0.956 ns, removal 0.055 ns.
Zero setup/hold violations; hold >=0.05 ns, unchanged native 16.4 ns budget.
System Fmax 61.207 MHz, CLS 25383, BRAM 69, DSP 24.
Versus AY: setup +0.058 ns, hold -0.127 ns, CLS +287.
This is a timing/resource tradeoff, not a universal improvement. Retain as an
experimental candidate, do not replace main or claim board acceptance.

Original candidate non-long suite: 165 functional PASS, one expected negative,
four inconclusive. Strengthened test results and bare-parser diagnostic are
recorded separately; original summary is not rewritten to look green.
Candidate 4f522c4's four long tests are independently running in fifo_long:
replay tail and transpose PASS; key-to-sound and top_sound pending at this report.
AY's four passing long cases are NOT substituted for candidate results.

Final closure snapshot e101f63: fifo_closure_final/summary.json reports four
functional PASS (the three strengthened calibration scenarios and real dual
UART isolation), one separately confirmed bare-parser diagnostic, zero unresolved
results. All 280 RTL/TB/IP blobs were verified. Current 73 hardware product inputs
still match the exact PnR source hashes; no second PnR is inferred or claimed.
Candidate long suite remains independent and pending its own final summary.
