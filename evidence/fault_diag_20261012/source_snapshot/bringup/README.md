# Fault-source diagnostic image

Archived development snapshot, not an active project or a drop-in build. F1
was built and produced the hardware trace; the source snapshot contains the
later F2 eight-channel extension whose build was stopped after the missing
right-hand board was confirmed. See `evidence/fault_diag_20261012/RESULT.md`.

This is an observer build, NOT a fix or production acceptance claim. It retains
the audio engine, Q input, heartbeat alarm, and production TX FIFO timing.
Only the physical UART TX pin is switched to the diagnostic reporter. P/N
normal replies are not sent on that pin in this image; their internal producer,
FIFO and transmitter still run. The last report field samples the normal TX
signal, retaining its real data path and the associated placement constraints.

The archived build entry is `evidence/fault_diag_20261012/source_snapshot/build_fault_diag.tcl`. The script
backs up the normal project before Gowin modifies its file list and restores it
even if the build reports an error. A leftover backup after an interrupted
process must be resolved before retry; do not overwrite it blindly.

UART: 500000 baud, 8N1, no flow control. A report repeats every 100 ms:

```text
!F1 004 004 004 009F1234 1
     C   S   F      T   U
```

- C: current source mask (three hexadecimal digits).
- S: OR of all sources seen since reset.
- F: mask on the first fault clock; multiple simultaneous sources are retained.
- T: first fault clock counter, eight hex digits; divide by 50000 for milliseconds
  at 50 MHz. Counter wraps after approximately 85.9 seconds; first/seen is kept
  separately, so a timestamp of zero alone is not a no-fault assertion.
- U: sampled normal UART TX bit, not a fault bit.

| Mask | Source |
|---|---|
| 001 / 002 / 004 | ADC 0 / 1 / 2 endpoint-suspicion sticky |
| 008 | Mixer frame deadline |
| 010 | Event FIFO overflow |
| 020 | Event lost count is nonzero |
| 040 | Score arbiter overflow |
| 080 | Looper overflow |
| 100 | Event merge overflow |
| 200 | Production TX FIFO overflow |

The masks are additive, not exclusive. The example is illustrative, not a
measured board result. ADC endpoint flags do not prove a chip is dead: genuine
all-grounded channels and stuck-low MISO cannot be distinguished by data alone.

The archived capture entry is `evidence/fault_diag_20261012/source_snapshot/tools/capture_fault_diag.ps1` after closing
any serial-assistant connection. It saves raw UART evidence and prints decoded
masks. Nonzero sticky mask is a FAIL (a hardware reproduction); missing frames
are an infrastructure error, NOT healthy hardware. Preserve the first failed
capture before rerunning with any fix.

Only timing-qualified images may be temporarily downloaded to SRAM for this
workflow; do not erase/program Flash or OTP. Existing flash contents remain
untouched. The shared user bitstream archive is outside the build checkout;
keep all Gowin source/constraint/project paths ASCII, then copy verified outputs
to the archive without overwriting older versions.
