`timescale 1ns/1ps
// ============================================================================
//  ws2812_driver.v -- single-channel WS2812 / WS2812B driver (GRB, 800 kHz).
//
//  WHY SINGLE CHANNEL
//  ------------------
//    The user's answer (2026-10-03) is that all 7 indicator LEDs live on ONE
//    strip on the control board, driven by `ctrl_ws_o` (C22).  The three
//    extension-board lines (`ws_strip_o[2:0]`, W19/W20/F19) are RESERVED and
//    are deliberately left on their old constant drive, so this module drives
//    exactly one wire.  Nothing here is sized for the reserved strips.
//
//  HOW MANY LEDs
//  -------------
//    `LED_N` is the ONLY thing to change when the strip length is known
//    (default 16; it must be >= 7 because there are 7 indicators).  The colour
//    buffer is `LED_N` x 24 registers -- 384 FFs at LED_N = 16, which is cheap
//    -- so no block RAM is needed at this size.  Only if LED_N ever goes past
//    ~32 is a RAM worth revisiting.
//
//  WIRE FORMAT (WS2812B, 800 kHz, GRB, MSB first) @ 50 MHz
//  -------------------------------------------------------
//    bit period   1.25 us -> 62 cycles   (BIT_CYC   = 62)
//    '0' high     0.35 us -> 17 cycles   (T0H_CYC   = 17)
//    '1' high     0.70 us -> 35 cycles   (T1H_CYC   = 35)
//    frame gap   >= 300 us -> RST_CYC    = 20000 cycles (400 us)
//      deliberately WIDE: the spec value is a MINIMUM, and a reset that is
//      merely "just long enough" is the one that fails on a cold board.
//    The line is LOW while idle, including during reset.
//
//  COLOUR ORDER (this is the part that is easy to get wrong)
//  ---------------------------------------------------------
//    `wr_data_i` is the ordinary RGB888 word, 24'hRRGGBB.
//    The driver reorders it to the GRB order the wire needs (see `rd_grb`),
//    so the first byte shifted out is GREEN.  Keeping the reorder here -- one
//    named wire, one place -- makes "GRB or RGB?" a one-line change that
//    tb_ws2812_driver criterion (3) catches.
//
//  TIMING DETAIL WORTH KNOWING
//  ---------------------------
//    Every bit cell is exactly BIT_CYC long, including across an LED boundary:
//    the next LED's colour is prefetched into the shift register during the
//    tail (bit_t = 56..58) of the current LED's last bit cell.  There is
//    therefore no "reload gap" that would stretch one bit.  This requires
//    BIT_CYC >= 61 (the prefetch window lives below BIT_CYC-1).
//
//  USAGE
//  -----
//    Write the whole frame through the write port, then pulse start_i for one
//    cycle.  busy_o stays high until the frame AND its trailing reset have
//    finished, so "wait for !busy_o, then start again" can never violate the
//    >= 300 us inter-frame gap.  A write that lands while the frame in flight
//    is being read simply takes effect on the next frame.
// ============================================================================
`default_nettype none

module ws2812_driver #(
    parameter integer LED_N   = 16,     // LEDs on the strip (>= 7; change ONLY this)
    parameter integer T0H_CYC = 17,     // '0' code high time, cycles @50 MHz
    parameter integer T1H_CYC = 35,     // '1' code high time, cycles @50 MHz
    parameter integer BIT_CYC = 62,     // bit period, cycles @50 MHz (>= 61)
    parameter integer RST_CYC = 20000   // inter-frame low time (400 us, >= 300 us)
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_i,         // one-cycle pulse: transmit one frame
    output reg         busy_o,          // high from start until frame + reset done

    input  wire        wr_en_i,         // colour buffer write port
    input  wire [4:0]  wr_addr_i,       // LED index (0 .. LED_N-1; LED_N <= 32)
    input  wire [23:0] wr_data_i,       // 24'hRRGGBB (RGB888; reordered to GRB)

    output wire        dout_o           // single-wire data, idle LOW
);
    // ── derived size ────────────────────────────────────────────────────────
    //   LW = LED index width; the colour buffer is `mem[0 .. (1<<LW)-1]` and
    //   only the first LED_N entries are ever written or read.
    localparam integer LW = (LED_N <=  2) ? 1 :
                            (LED_N <=  4) ? 2 :
                            (LED_N <=  8) ? 3 :
                            (LED_N <= 16) ? 4 : 5;

    localparam [5:0]  T0H  = T0H_CYC;
    localparam [5:0]  T1H  = T1H_CYC;
    localparam [5:0]  BITN = BIT_CYC;
    localparam [15:0] RSTN = RST_CYC;

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_LOAD = 2'd1;
    localparam [1:0] S_SEND = 2'd2;
    localparam [1:0] S_RST  = 2'd3;

    // ── colour buffer: one 24-bit RGB888 word per LED ───────────────────────
    //   The read is registered (synchronous), which is the shape a RAM wants;
    //   at LED_N = 16 the whole buffer is 384 bits, so whether the tool keeps
    //   it as flip-flops or packs it into a block RAM is reported by synthesis
    //   rather than assumed here.
    reg [23:0] mem [0:(1<<LW)-1];
    reg [23:0] rd_data;
    reg [LW-1:0] rd_addr;

    always @(posedge clk) begin
        if (wr_en_i && (wr_addr_i < LED_N))
            mem[wr_addr_i[LW-1:0]] <= wr_data_i;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    // RGB888 in, GRB on the wire: the first byte shifted out must be GREEN.
    //   (Mutation that must turn tb criterion (3) red: swap to
    //    {rd_data[23:16], rd_data[15:8], rd_data[7:0]} = RGB.)
    wire [23:0] rd_grb = {rd_data[15:8], rd_data[23:16], rd_data[7:0]};

    // ── bit engine ──────────────────────────────────────────────────────────
    reg [23:0] sh;              // shift register, MSB leaves first
    reg        cur_bit;         // bit of the current cell
    reg [1:0]  state;
    reg [1:0]  ld_cnt;          // 3-cycle load pipeline (see S_LOAD)
    reg [4:0]  led_i;           // LED being transmitted
    reg [4:0]  bit_i;           // 23 .. 0, MSB first
    reg [5:0]  bit_t;           // 0 .. BIT_CYC-1 inside one bit cell
    reg [15:0] rst_t;

    wire [4:0] led_nxt = led_i + 5'd1;

    // High for T0H or T1H cycles, then low for the rest of the cell.
    assign dout_o = (state == S_SEND) && (bit_t < (cur_bit ? T1H : T0H));

    always @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            busy_o  <= 1'b0;
            ld_cnt  <= 2'd0;
            led_i   <= 5'd0;
            bit_i   <= 5'd23;
            bit_t   <= 6'd0;
            rst_t   <= 16'd0;
            rd_addr <= {LW{1'b0}};
            cur_bit <= 1'b0;
            sh      <= 24'd0;
        end else begin
            case (state)
                // ── idle: line low, waiting for a start pulse ───────────────
                S_IDLE: begin
                    busy_o <= 1'b0;
                    if (start_i) begin
                        busy_o <= 1'b1;
                        led_i  <= 5'd0;
                        ld_cnt <= 2'd0;
                        state  <= S_LOAD;
                    end
                end

                // ── fetch LED 0's colour (read pipeline is 1 deep, so the
                //    address needs its own cycle before the data is valid) ───
                S_LOAD: begin
                    case (ld_cnt)
                        2'd0: begin rd_addr <= led_i[LW-1:0]; ld_cnt <= 2'd1; end
                        2'd1: begin ld_cnt <= 2'd2; end
                        default: begin
                            sh      <= rd_grb;
                            cur_bit <= rd_grb[23];
                            ld_cnt  <= 2'd0;
                            bit_i   <= 5'd23;
                            bit_t   <= 6'd0;
                            state   <= S_SEND;
                        end
                    endcase
                end

                // ── 24 bit cells; every cell is exactly BIT_CYC long ────────
                S_SEND: begin
                    if (bit_t == 6'd0) begin
                        cur_bit <= sh[23];
                    end
                    if (bit_t == BITN - 6'd1) begin
                        if (bit_i != 5'd0) begin
                            // end of a cell that is not the LED's last one:
                            // shift the next bit into position
                            sh    <= {sh[22:0], 1'b0};
                            bit_i <= bit_i - 5'd1;
                            bit_t <= 6'd0;
                        end else if (led_i == LED_N - 1) begin
                            // last bit of the last LED -> inter-frame reset
                            rst_t <= 16'd0;
                            state <= S_RST;
                        end else begin
                            // last bit of this LED: sh already holds the next
                            // LED (prefetched below), so do NOT shift here
                            led_i <= led_i + 5'd1;
                            bit_i <= 5'd23;
                            bit_t <= 6'd0;
                        end
                    end else begin
                        bit_t <= bit_t + 6'd1;
                        // prefetch the NEXT LED's colour during the tail of
                        // this last bit cell (the output uses cur_bit, so
                        // overwriting sh here is safe)
                        if ((bit_i == 5'd0) && (led_i != LED_N - 1)) begin
                            if      (bit_t == 6'd56) rd_addr <= led_nxt[LW-1:0];
                            else if (bit_t == 6'd58) sh      <= rd_grb;
                        end
                    end
                end

                // ── inter-frame reset: line stays LOW, busy_o stays HIGH so a
                //    caller that waits for !busy_o cannot shorten the gap ────
                S_RST: begin
                    if (rst_t == RSTN - 16'd1) begin
                        busy_o <= 1'b0;
                        state  <= S_IDLE;
                    end else begin
                        rst_t <= rst_t + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
