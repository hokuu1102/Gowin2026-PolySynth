`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// vibrato_lfo.v · T18 颤音控制（W3b）
//
// CH2（深度）和 CH3（速率）是低速控制量；它们绝不能直接改变振荡器相位。
// 本模块只连续改变 phase increment，故 LFO 相位在所有控制变化中保持连续，
// 不会产生由相位复位导致的音高跳变/咔声。
//
// 深度：双阈值死区（OFF <= DEPTH_OFF；ON >= DEPTH_ON）。控制值在两个阈值
// 之间来回抖动时保持原状态，防止颤音在端点断续。
// 速率：raw 0..4095 映射到 1..12 Hz，且每 CTRL_SLEW_DIV 次控制提交最多
// 改 RATE_SLEW_STEP 个 phase-inc LSB；50 MHz 默认约每 5 ms 一步。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module vibrato_lfo #(
    parameter [11:0] DEPTH_OFF     = 12'd64,
    parameter [11:0] DEPTH_ON      = 12'd96,
    // 1 Hz / 12 Hz at 50 MHz: round(Hz * 2^32 / 50e6)
    parameter [31:0] RATE_MIN_INC  = 32'd86,
    parameter [31:0] RATE_MAX_INC  = 32'd1031,
    parameter [31:0] RATE_SLEW_STEP = 32'd16,
    parameter integer CTRL_SLEW_DIV = 10
) (
    input  wire               clk_i,
    input  wire               rst_n_i,
    // one pulse after a coherent CH2/CH3 control snapshot
    input  wire               ctrl_valid_i,
    input  wire [11:0]        depth_raw_i,
    input  wire [11:0]        rate_raw_i,
    output wire signed [15:0] mod_o,             // Q1.15, for oscillator_bank
    output wire               depth_active_o,
    output wire [31:0]        rate_inc_dbg_o,
    output wire [31:0]        phase_dbg_o
);

    // Explicitly widen before multiplication: 12 bits x 32 bits needs 44 bits.
    wire [31:0] rate_span = RATE_MAX_INC - RATE_MIN_INC;
    wire [43:0] rate_product = {32'd0, rate_raw_i} * {12'd0, rate_span};
    wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
                              ? RATE_MAX_INC
                              : RATE_MIN_INC + rate_product[43:12];
    wire [15:0] depth_target_w = {depth_raw_i, 3'b000}; // 12-bit -> Q1.15

    reg              depth_active_r;
    reg [15:0]       depth_q;
    reg [31:0]       rate_inc_q;
    reg [31:0]       rate_target_q;
    reg [31:0]       phase_q;
    integer          slew_count_q;

    // Triangle LFO: 0 -> +1 -> 0 -> -1 -> 0 over one 32-bit phase turn.
    wire [14:0] tri_mag = phase_q[30] ? ~phase_q[29:15] : phase_q[29:15];
    // Build two's-complement negation at exactly 16 bits. Gowin widens both
    // unary '-' and '+' by one bit, so use a ripple carry here instead.
    function [15:0] twos_complement16;
        input [15:0] value;
        integer bit_i;
        reg carry;
        begin
            carry = 1'b1;
            for (bit_i = 0; bit_i < 16; bit_i = bit_i + 1) begin
                twos_complement16[bit_i] = (~value[bit_i]) ^ carry;
                carry = (~value[bit_i]) & carry;
            end
        end
    endfunction
    wire [15:0] triangle_bits = phase_q[31]
                               ? twos_complement16({1'b0, tri_mag})
                               :  {1'b0, tri_mag};
    wire signed [15:0] triangle_q = triangle_bits;
    wire signed [31:0] mod_product = triangle_q * $signed(depth_q);
    // Q1.15 product -> Q1.15.  The explicit slice is the low 16 bits of the
    // arithmetic result and avoids Gowin's implicit 17-bit shift truncation.
    wire [15:0] mod_bits = mod_product[30:15];
    wire signed [15:0] mod_w = mod_bits;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            depth_active_r <= 1'b0;
            depth_q        <= 16'd0;
            rate_inc_q     <= RATE_MIN_INC;
            rate_target_q  <= RATE_MIN_INC;
            phase_q        <= 32'd0;
            slew_count_q   <= 0;
        end else begin
            // Never reset phase for a control update: this is the anti-click rule.
            phase_q <= phase_q + rate_inc_q;

            if (ctrl_valid_i) begin
                // Depth dead-zone + hysteresis.
                if (depth_active_r) begin
                    if (depth_raw_i <= DEPTH_OFF) begin
                        depth_active_r <= 1'b0;
                        depth_q        <= 16'd0;
                    end else begin
                        depth_q <= depth_target_w;
                    end
                end else if (depth_raw_i >= DEPTH_ON) begin
                    depth_active_r <= 1'b1;
                    depth_q        <= depth_target_w;
                end

                rate_target_q <= rate_target_w;

                // The control source commits at 2 kHz.  Move rate only every
                // 10 commits (5 ms nominal), with a bounded step each time.
                if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
                    slew_count_q <= 0;
                    if (rate_inc_q < rate_target_w) begin
                        if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
                            rate_inc_q <= rate_inc_q + RATE_SLEW_STEP;
                        else
                            rate_inc_q <= rate_target_w;
                    end else if (rate_inc_q > rate_target_w) begin
                        if ((rate_inc_q - rate_target_w) > RATE_SLEW_STEP)
                            rate_inc_q <= rate_inc_q - RATE_SLEW_STEP;
                        else
                            rate_inc_q <= rate_target_w;
                    end
                end else begin
                    slew_count_q <= slew_count_q + 1;
                end
            end
        end
    end

    assign mod_o            = depth_active_r ? mod_w : 16'sd0;
    assign depth_active_o   = depth_active_r;
    assign rate_inc_dbg_o   = rate_inc_q;
    assign phase_dbg_o      = phase_q;

    initial begin
        if (DEPTH_ON <= DEPTH_OFF)
            $display("ERROR [vibrato_lfo] DEPTH_ON must be greater than DEPTH_OFF");
        if (RATE_MAX_INC < RATE_MIN_INC)
            $display("ERROR [vibrato_lfo] RATE_MAX_INC must be >= RATE_MIN_INC");
        if (CTRL_SLEW_DIV < 1)
            $display("ERROR [vibrato_lfo] CTRL_SLEW_DIV must be >= 1");
    end
endmodule

`default_nettype wire
