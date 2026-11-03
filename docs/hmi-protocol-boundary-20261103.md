# HMI command boundary repair

Parent release: `daadfbddbeeb6323e0c34f389130239c58c286ea`.

## Reproduced failure

The board was observed through COM14 at 115200/8N1. With the screen
disconnected, the PC sent the real screen's page notification and handshake.
The user then turned EC11 while delay length was selected.

The raw capture contains this single FF-terminated wire packet:

```
Ee16+5\r\nz_ll.val=52 FF FF FF
```

The eight-byte EC11 report has no TJC terminator. The screen therefore sees
its bytes as a prefix of `z_ll.val=52`, rejects that command, then accepts the
separate `t_ll_val.txt="52%"` packet. The captured file
`com14-20261103-141220.bin` contains 291 such prefixed delay-needle commands;
the numeric text packets are separately terminated. This reproduces the
reported changing numbers with a stationary needle.

With the production sound branch enabled, a raw-wire top test also
reproduces unchanged mode, keydrum and slide text: the one-byte legacy
acknowledgements prefix the first following screen command. Serial O has
the same risk for uplink text. The physical idx15 path is tested separately.

Earlier byte-ownership scoreboards verified that UI bytes were transmitted
in full, but discarded other owners' bytes before checking screen packets.
They could not detect a foreign prefix *between* packets. The new consumer
keeps every actual wire byte until FF FF FF, matching the screen's boundary.

## Repair

The board UART tracks whether any non-screen byte has been emitted since
the last clean screen boundary. When a new UI packet requests ownership,
the arbiter first sends exactly three FF bytes under dedicated owner 5 and
waits for the third byte's physical UART completion. Only then does it grant
owner 3 to the UI sender. UI backpressure remains asserted during the guard.

This closes the legacy report as a separate packet; it cannot prefix the
next legal HMI instruction. A screen may discard that separate legacy
report as an unknown instruction. Its next valid UI instruction remains
executable. This does not turn arbitrary diagnostic bytes into valid TJC
commands or suppress their possible screen error replies.

Legacy report payloads remain unchanged. In a pure PC session without
screen output, no separator is emitted; the existing acknowledgement
format is retained. A mixed screen/debug session now includes the required
boundary before the next UI command. The separator is added only at the
board-UART mux and never to the shared FIFO or ESP32 UART. The HMI source,
TFT, BLE protocol, audio, Loop, key mapping, FIFO and guide logic are unchanged.

## Validation

- `tb_top_hmi_protocol_boundary` keeps all physical UART bytes. It covers
  matrix mode/keydrum/slide/uplink switches in both directions, serial O,
  six gauge/number pairs, and real quadrature EC11 forward/reverse steps.
  The production sound branch is enabled so the real Ee report is present.
  It also verifies pure-PC A acknowledgements and no separator launch on
  the ESP UART.
- `tb_top_hmi_long_frames` now explicitly accounts for owner-5 bytes in its
  complete wire scoreboard. Original diagnostic payload counts remain
  unchanged. Separate raw-wire consumer checks establish screen semantics.
- Selected page, key15, Loop, missed-guide-flash and actual-115200 checks
  are retained; detailed results are stored with the build evidence.

This source-stage document does not claim a new timing-qualified FS or a
hardware retest of the repair. A new full production build must pass the
unchanged actual-50MHz gate. Then the new FS must be loaded and checked
with the actual screen. The existing TFT remains compatible. FPGA-only
reset still requires page re-entry/handshake to restore the page session.

The captured prefix fault explains the demonstrated failures. It is not a
claim that every historical R10 symptom or a separate missing-byte fault
has been reproduced and fixed.
