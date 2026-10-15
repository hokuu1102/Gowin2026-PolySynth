# Position-following slide repair

## Agreed behavior

For calibrated positions A/B, pitch is `floor((incA*posA + incB*posB)/(posA+posB))`. A stationary finger keeps the same pitch. Reverse direction preserves the original voice owner. Both released, W off, or keyboard mode cancel. Only phase increment changes, never oscillator phase state.

## Public-interface tests

- `tb_slide_position_ctrl`: 12 directed checks, including 60:40 literal 1400, reverse ownership, exact endpoints, zero denominator cancellation, disable during calculation, and full unsigned 32-bit pitch values. A8 rejects unknowns.
- `tb_slide_top_pitch`: real axis_map -> real position controller, 12 physical neighbour pairs, literal midpoint pitches and disable. Old copied-mux/source-anchor fixture archived in `historical/`, not accepted as real top validation. Event adjacency remains separately covered by `tb_ee_adj`.
- `tb_slide_position_e2e`: real UART A/W, three external MCP3208 SPI models and comparator pluck, real top and public voice outputs, independently decoded I2S. No force of mode/state/map/pitch. ADC scan timing alone is accelerated for simulation.

The exact same E2E stimulus on immutable main `9d30dd3` fails stationary-position acceptance (`top_red/`, exit 1). Repair passes 14 checks (`top_green/`, exit 0), including holding midpoint, original voice after A releases, exact B endpoint, final OFF, W cancellation and keyboard gating. Historical `tb_slide_e2e` entry point now invokes this real-boundary test rather than forcing private mode state.

## Implementation and timing boundary

`slide_position_ctrl` uses one shared 32x12 registered multiplier and a 45-cycle restoring divider, all at 50 MHz. No combinational division, new clock, PLL, CPU or HLS. About 52 cycles per completed snapshot, much less than the hardware scan interval. Actual UI fretboard mode gates the module, not stale last-event `am_mode`. Play-mode release handshake protects the original voice while sliding and releases it after the session ends.

These are simulation results. Full fresh synthesis/place-and-route and hold >= 0.05 ns remain separate gates, and hardware acceptance is pending. Existing main peripherals, synthesis features and clocks are not removed.
