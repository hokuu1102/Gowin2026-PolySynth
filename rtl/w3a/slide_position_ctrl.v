`timescale 1ns/1ps
`default_nettype none
// Calibrated two-axis position follower. All logic runs on clk_i (50 MHz).
// pitch = floor((incA*posA + incB*posB)/(posA+posB)).
// A reverse trigger preserves the original voice owner. Only completed results
// raise valid; no phase accumulator is touched. Disable cancels pending work.
// One shared 32x12 multiplier and a 45-cycle restoring divider; no '/' hardware.
// lookup_inc_i is a combinational map for lookup_axis_o, sampled next clock.
// A new trigger/snapshot supersedes incomplete work with one coherent snapshot.
module slide_position_ctrl (
    input wire clk_i, rst_n_i, enable_i,
    input wire trigger_i, snapshot_i,
    input wire [3:0] axis_a_i, axis_b_i,
    input wire [191:0] positions_i,
    output wire [3:0] lookup_axis_o,
    input wire [31:0] lookup_inc_i,
    output wire pitch_valid_o,
    output wire [3:0] pitch_axis_o,
    output reg [31:0] pitch_inc_o,
    output wire active_o, busy_o
);
    localparam [3:0] IDLE=0, LOOK_A=1, LOOK_B=2, CAP_A=3,
                     WAIT_B=4, ADD=5, INIT_DIV=6, DIVIDE=7;
    reg [3:0] state_r, owner_r, peer_r;
    reg active_r, valid_r;
    reg [11:0] pos_a_r, pos_b_r, mul_pos_r;
    reg [12:0] denominator_r, remainder_r;
    reg [31:0] mul_pitch_r, inc_b_r;
    reg [43:0] product_r, product_a_r;
    reg [44:0] numerator_r, shift_r, quotient_r;
    reg [5:0] bits_r;

    wire same_pair = active_r &&
        (((axis_a_i==owner_r)&&(axis_b_i==peer_r)) ||
         ((axis_a_i==peer_r)&&(axis_b_i==owner_r)));
    wire [3:0] request_owner = (trigger_i && !same_pair) ? axis_a_i : owner_r;
    wire [3:0] request_peer  = (trigger_i && !same_pair) ? axis_b_i : peer_r;
    wire [11:0] request_a = positions_i[request_owner*12 +: 12];
    wire [11:0] request_b = positions_i[request_peer*12 +: 12];
    wire [12:0] request_sum = {1'b0,request_a}+{1'b0,request_b};
    wire [13:0] trial = {remainder_r,shift_r[44]};
    wire take_bit = trial >= {1'b0,denominator_r};
    wire [13:0] remainder_next = take_bit ? trial-{1'b0,denominator_r} : trial;
    wire [44:0] quotient_next = {quotient_r[43:0],take_bit};

    assign lookup_axis_o = (state_r==LOOK_B) ? peer_r : owner_r;
    assign pitch_axis_o = owner_r;
    assign pitch_valid_o = valid_r && enable_i;
    assign active_o = active_r && enable_i;
    assign busy_o = (state_r!=IDLE) && enable_i;

    // Registered operands/output allow mapping into Arora V DSP pipeline.
    always @(posedge clk_i) begin
        if (!rst_n_i) product_r <= 44'd0;
        else product_r <= mul_pitch_r * mul_pos_r;
    end

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_r<=IDLE; owner_r<=0; peer_r<=0;
            active_r<=0; valid_r<=0; pitch_inc_o<=0;
            pos_a_r<=0; pos_b_r<=0; denominator_r<=0;
            mul_pos_r<=0; mul_pitch_r<=0; inc_b_r<=0;
            product_a_r<=0; numerator_r<=0; shift_r<=0;
            remainder_r<=0; quotient_r<=0; bits_r<=0;
        end else begin
            valid_r<=0;
            if (!enable_i) begin
                active_r<=0; state_r<=IDLE;
            end else if (trigger_i || (snapshot_i && active_r)) begin
                owner_r<=request_owner; peer_r<=request_peer;
                pos_a_r<=request_a; pos_b_r<=request_b;
                denominator_r<=request_sum;
                if (request_sum==0) begin
                    active_r<=0; state_r<=IDLE;
                end else begin
                    active_r<=1; state_r<=LOOK_A;
                end
            end else begin
                case(state_r)
                    LOOK_A: begin
                        mul_pitch_r<=lookup_inc_i; mul_pos_r<=pos_a_r;
                        state_r<=LOOK_B;
                    end
                    LOOK_B: begin inc_b_r<=lookup_inc_i; state_r<=CAP_A; end
                    CAP_A: begin
                        product_a_r<=product_r;
                        mul_pitch_r<=inc_b_r; mul_pos_r<=pos_b_r;
                        state_r<=WAIT_B;
                    end
                    WAIT_B: state_r<=ADD;
                    ADD: begin
                        numerator_r<={1'b0,product_a_r}+{1'b0,product_r};
                        state_r<=INIT_DIV;
                    end
                    INIT_DIV: begin
                        shift_r<=numerator_r; quotient_r<=0; remainder_r<=0;
                        bits_r<=6'd45; state_r<=DIVIDE;
                    end
                    DIVIDE: begin
                        remainder_r<=remainder_next[12:0];
                        quotient_r<=quotient_next; shift_r<={shift_r[43:0],1'b0};
                        bits_r<=bits_r-1'b1;
                        if (bits_r==1) begin
                            pitch_inc_o<=quotient_next[31:0]; valid_r<=1;
                            state_r<=IDLE;
                        end
                    end
                    default: state_r<=IDLE;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
