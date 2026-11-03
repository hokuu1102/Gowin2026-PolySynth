# Guide bitmap output timing candidate

Parent: `7ff935737da8135bb7a09594e6e2a7bfb9770f12` (FIFO block RAM mapping).
This is an isolated candidate, not a qualified hardware release.

Attempt06's routed result reached 47.277 MHz. Its worst setup path traversed
the held-note identity matcher, OFF priority selection, release control and
64-slot lamp reduction before reaching the guide bitmap register.

The candidate derives each bitmap bit directly from the registered
`held_valid` and `held_key` ledger. This moves the reduction after the existing
ledger boundary. It removes the redundant bitmap registers and their
next-state release gates without adding a cycle. Event decode, ledger
allocation/release, 64-slot capacity, 32-bit repeat counters, accepted-ON pulse
notifications, stream timeout and live-key masking are unchanged.

For a valid slot retained across an edge, its key is retained. Allocation
writes its new key and valid bit on that edge; release/reset/timeout clears
the valid bit on that edge. A duplicate ON retains a reference to that key.
Consequently the reduction of the updated ledger equals the former registered
next bitmap. Do not mask this output with `stream_timeout`: that signal can
become true one edge before the ledger clears, which would clear a lamp early.

The production top consumes `guide_vis_o` in `led_data`, which registers the
pattern and its commit before the physical LED driver. No combinational
guide bitmap is connected directly to a board pin. The new output is
combinational after ledger registers; equivalence is claimed at clock
boundaries, not for analog glitches during propagation between edges.

## Validation

- `tb_guide_lamp_output_equiv`: frozen exact parent module versus candidate;
  all six public outputs compared each cycle. Eight configurations combine
  decode pipeline 0/1 with capacities 1/7/8/64 and valid timeout settings
  2/17/32. Approximately 171,392 cycles per configuration exercise full and
  overflowing ledgers, repeated ON/OFF beyond 65,536, mode/transpose/live-mask
  changes, timeout boundaries, reset and reuse.
- A mutation that incorrectly masks the new bitmap with timeout fails at
  cycle 213. This confirms the comparison catches an actual one-cycle output
  regression. Probe evidence is retained in the output directory.
- `tb_guide_bank_fanout_equiv`: all public outputs and internal ledger state,
  capacities 1/3/9/64/65, including count overflow and priority cases.
- `tb_guide_flash`, `tb_top_guide_flash`,
  `tb_top_guide_input_snapshot`, `tb_lamp_stuck_clear`: targeted production
  integration behavior, including the previously fixed missed-flash symptom.
- `tools/check_static.ps1`: 7/7 pass.

Timing, routing completion and hardware acceptance are separate gates. No
50 MHz qualification is claimed until the complete native build and the
existing timing gate pass. Clock/pin constraints and all audio, HDMI/FFT,
Loop, UART and screen features remain in the complete production project.
