`timescale 1ns/1ps
// ============================================================================
//  tb_ws2812_driver.sv -- acceptance test for the single-channel WS2812 driver.
//
//  The DUT is treated as a black box: everything is measured from dout_o and
//  busy_o, never from internal state, so the test would still catch a driver
//  that is internally "different but right".
//
//  CHECKS (each one is written so that it CAN go red)
//  --------------------------------------------------
//   (1) bit period = 62..63 cycles for EVERY bit of a frame (measured per bit)
//   (2) '0' code high = 17 +- 2 cycles, '1' code high = 35 +- 2 cycles,
//       measured on the all-0x000000 frame and the all-0xFFFFFF frame
//   (3) wire order is GRB with MSB first: a known colour is decoded bit by bit
//   (4) inter-frame reset is >= 300 us (15000 cycles) of LOW
//   (5) busy_o: low -> high on start -> low when frame + reset are done
//   (6) the line is LOW during reset and while idle
//   (7) no X/Z on the outputs after reset (chk_xprop, assertion A8)
//   (8) per-LED addressing: two neighbouring LEDs carry DIFFERENT data
//
//  MUTATION EVIDENCE -- both were actually run, both went RED:
//   * T1H_CYC 35 -> 17 in rtl/w3a/ws2812_driver.v           => (2) fails
//   * rd_grb {G,R,B} -> {R,G,B} in rtl/w3a/ws2812_driver.v  => (3) fails
//
//  At 50 MHz the clock period is 20 ns, so "cycles" below = $time / 20.
// ============================================================================
`default_nettype none

module tb_ws2812_driver;
    // 16 = the RTL default, and >= 7 because there are 7 indicator LEDs.
    localparam integer LED_N = 16;
    localparam integer NBITS = LED_N * 24;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg         start_i;
    wire        busy_o;
    reg         wr_en_i;
    reg  [4:0]  wr_addr_i;
    reg  [23:0] wr_data_i;
    wire        dout_o;

    integer errors = 0;

    ws2812_driver #(.LED_N(LED_N)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_i   (start_i),
        .busy_o    (busy_o),
        .wr_en_i   (wr_en_i),
        .wr_addr_i (wr_addr_i),
        .wr_data_i (wr_data_i),
        .dout_o    (dout_o)
    );

    // ── A8: no X/Z on the outputs once reset is released ────────────────────
    reg [31:0] a8_err;
    chk_xprop #(.W(2), .NAME("ws_dout_o/busy_o")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig({busy_o, dout_o}), .err_cnt(a8_err)
    );

    // ── edge monitor: every bit cell of dout_o is timestamped ───────────────
    integer n_cell = 0;
    time    rise_t [0:2047];
    time    fall_t [0:2047];

    always @(posedge dout_o) begin
        rise_t[n_cell] = $time;
        @(negedge dout_o);
        fall_t[n_cell] = $time;
        n_cell = n_cell + 1;
    end

    // A bit is a '1' code iff its high time is closer to 35 than to 17 cycles.
    //   NOTE: the return type MUST be 1 bit.  Declared `integer`, the
    //   concatenation in pack_byte() would be 39 bits wide and truncating it
    //   back to 8 bits silently keeps only bitval[7:0] -- i.e. it throws away
    //   the bits accumulated so far.  That bug made the decode read
    //   "00 01 00" for a perfectly correct 80 01 AC stream.
    function bitval(input integer idx);
        begin
            bitval = ((fall_t[idx] - rise_t[idx]) > (26 * 20)) ? 1'b1 : 1'b0;
        end
    endfunction

    task chk(input [8*96-1:0] name, input cond);
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    task wr_color(input [4:0] addr, input [23:0] rgb);
        begin
            @(negedge clk);
            wr_en_i   = 1'b1;
            wr_addr_i = addr;
            wr_data_i = rgb;
            @(negedge clk);
            wr_en_i   = 1'b0;
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk); start_i = 1'b1;
            @(negedge clk); start_i = 1'b0;
        end
    endtask

    // High times of bit cells [from .. from+7] packed MSB first into one byte.
    function [7:0] pack_byte(input integer from);
        integer b;
        begin
            pack_byte = 8'd0;
            for (b = 0; b < 8; b = b + 1)
                pack_byte = {pack_byte[6:0], bitval(from + b)};
        end
    endfunction

    integer k, li;
    integer base1, base2, base3;
    integer per_cyc, hi_cyc;
    integer min_per, max_per, min_hi0, max_hi0, min_hi1, max_hi1;
    integer gap_cyc;
    integer ones_led1;
    reg [7:0] grb0, grb1, grb2;

    initial begin
        start_i   = 1'b0;
        wr_en_i   = 1'b0;
        wr_addr_i = 5'd0;
        wr_data_i = 24'd0;

        // ── (6) reset: the line must already be low ─────────────────────────
        repeat (4) @(posedge clk);
        chk("(6) reset: dout_o is low",  dout_o === 1'b0);
        chk("(6) reset: busy_o is low",  busy_o === 1'b0);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        chk("(6) idle: dout_o stays low", dout_o === 1'b0);
        chk("(6) idle: busy_o stays low", busy_o === 1'b0);

        // ═══ frame 1: every colour 0x000000 => every bit is a '0' code ═════
        for (li = 0; li < LED_N; li = li + 1)
            wr_color(li[4:0], 24'h000000);

        base1 = n_cell;
        pulse_start();
        @(negedge clk);
        chk("(5) busy_o asserts after start_i", busy_o === 1'b1);
        wait (n_cell >= base1 + NBITS);

        // ── (1) bit period, measured bit by bit ─────────────────────────────
        min_per = 1_000_000; max_per = 0;
        for (k = 0; k < NBITS - 1; k = k + 1) begin
            per_cyc = (rise_t[base1 + k + 1] - rise_t[base1 + k]) / 20;
            if (per_cyc < min_per) min_per = per_cyc;
            if (per_cyc > max_per) max_per = per_cyc;
        end
        $display("  info: bit period over %0d measured bits = %0d..%0d cycles",
                 NBITS - 1, min_per, max_per);
        chk("(1) bit period is 62..63 cycles for every bit",
            (min_per >= 62) && (max_per <= 63));

        // ── (2a) '0' code high time ─────────────────────────────────────────
        min_hi0 = 1_000_000; max_hi0 = 0;
        for (k = 0; k < NBITS; k = k + 1) begin
            hi_cyc = (fall_t[base1 + k] - rise_t[base1 + k]) / 20;
            if (hi_cyc < min_hi0) min_hi0 = hi_cyc;
            if (hi_cyc > max_hi0) max_hi0 = hi_cyc;
        end
        $display("  info: all-0x000000 frame: '0' high = %0d..%0d cycles (want 17+-2)",
                 min_hi0, max_hi0);
        chk("(2a) '0' code high = 17 +- 2 cycles (all-0x000000 frame)",
            (min_hi0 >= 15) && (max_hi0 <= 19));

        // ── (5) the frame ends and busy_o drops ─────────────────────────────
        wait (busy_o === 1'b0);
        chk("(5) busy_o drops when the frame is over", busy_o === 1'b0);

        // ═══ frame 2: every colour 0xFFFFFF => every bit is a '1' code ═════
        for (li = 0; li < LED_N; li = li + 1)
            wr_color(li[4:0], 24'hFFFFFF);

        base2 = n_cell;
        pulse_start();
        wait (n_cell >= base2 + NBITS);

        // ── (4) inter-frame reset: last fall of frame 1 -> first rise of 2 ──
        gap_cyc = (rise_t[base2] - fall_t[base2 - 1]) / 20;
        $display("  info: inter-frame LOW = %0d cycles = %0d us (want >= 15000 / 300 us)",
                 gap_cyc, gap_cyc * 20 / 1000);
        chk("(4) inter-frame reset is >= 300 us (15000 cycles) of LOW",
            gap_cyc >= 15000);

        // ── (2b) '1' code high time ─────────────────────────────────────────
        min_hi1 = 1_000_000; max_hi1 = 0;
        for (k = 0; k < NBITS; k = k + 1) begin
            hi_cyc = (fall_t[base2 + k] - rise_t[base2 + k]) / 20;
            if (hi_cyc < min_hi1) min_hi1 = hi_cyc;
            if (hi_cyc > max_hi1) max_hi1 = hi_cyc;
        end
        $display("  info: all-0xFFFFFF frame: '1' high = %0d..%0d cycles (want 35+-2)",
                 min_hi1, max_hi1);
        chk("(2b) '1' code high = 35 +- 2 cycles (all-0xFFFFFF frame)",
            (min_hi1 >= 33) && (max_hi1 <= 37));

        wait (busy_o === 1'b0);

        // ═══ frame 3: GRB order + per-LED addressing ═══════════════════════
        //   wr_data_i is RGB888.  LED 0 = R 0x01, G 0x80, B 0xAC, so the wire
        //   must carry 0x80 (G), then 0x01 (R), then 0xAC.  LED 1 is all ones
        //   so the very next 24 cells must be all '1' codes: two neighbouring
        //   LEDs carrying different data is what proves the LED index really
        //   selects a different buffer entry.
        for (li = 0; li < LED_N; li = li + 1)
            wr_color(li[4:0], 24'h000000);
        wr_color(5'd0, 24'h0180AC);
        wr_color(5'd1, 24'hFFFFFF);

        base3 = n_cell;
        pulse_start();
        wait (n_cell >= base3 + NBITS);

        // ── (3) GRB, MSB first ──────────────────────────────────────────────
        grb0 = pack_byte(base3 +  0);       // first byte on the wire
        grb1 = pack_byte(base3 +  8);
        grb2 = pack_byte(base3 + 16);
        $display("  info: decoded wire bytes = %02h %02h %02h (want 80 01 ac = G,R,B)",
                 grb0, grb1, grb2);
        chk("(3) wire order is GRB with MSB first",
            (grb0 == 8'h80) && (grb1 == 8'h01) && (grb2 == 8'hAC));

        // ── (8) LED 1 carries different data than LED 0 ─────────────────────
        ones_led1 = 0;
        for (k = 0; k < 24; k = k + 1)
            if (bitval(base3 + 24 + k) == 1'b1) ones_led1 = ones_led1 + 1;
        $display("  info: LED1 '1'-coded bits = %0d / 24 (want 24)", ones_led1);
        chk("(8) per-LED addressing: LED1 is all-ones while LED0 is not",
            (ones_led1 == 24) &&
            ((grb0 != 8'hFF) || (grb1 != 8'hFF) || (grb2 != 8'hFF)));

        // ── (7) no X/Z anywhere on the outputs ──────────────────────────────
        chk("(7) no X/Z on dout_o/busy_o after reset (A8)", a8_err == 32'd0);

        if (errors == 0)
            $display("PASS: ws2812_driver -- 1 channel, GRB, 800 kHz, reset gap, busy handshake");
        else
            $fatal(1, "FAIL: ws2812_driver has %0d error(s)", errors);
        $finish;
    end

    // Watchdog: 10 ms of simulated time is ~11 frames, far more than needed.
    initial begin
        #10_000_000;
        $fatal(1, "FAIL: tb_ws2812_driver timeout");
    end
endmodule

`default_nettype wire
