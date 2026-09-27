`timescale 1ns/1ps
// T15: LM393 UP/DOWN asynchronous outputs -> one synchronous pluck event.
// The first synchronized edge is accepted immediately; the refractory period
// only rejects later edges.  A simultaneous UP/DOWN edge is deterministically UP.
`default_nettype none

module async_pluck_capture #(
    parameter integer REFRACT_CYC = 2_500_000
) (
    input  wire clk_i,
    input  wire rst_n_i,
    input  wire pluck_up_async_i,
    input  wire pluck_down_async_i,
    output reg  pluck_valid_o,
    output reg  pluck_up_o
);
    reg up_ff1, up_ff2, down_ff1, down_ff2;
    reg up_prev, down_prev;
    reg [31:0] refractory_q;

    wire up_rise   = up_ff2   && !up_prev;
    wire down_rise = down_ff2 && !down_prev;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            up_ff1        <= 1'b0;
            up_ff2        <= 1'b0;
            down_ff1      <= 1'b0;
            down_ff2      <= 1'b0;
            up_prev       <= 1'b0;
            down_prev     <= 1'b0;
            refractory_q  <= 32'd0;
            pluck_valid_o <= 1'b0;
            pluck_up_o    <= 1'b0;
        end else begin
            up_ff1    <= pluck_up_async_i;
            up_ff2    <= up_ff1;
            down_ff1  <= pluck_down_async_i;
            down_ff2  <= down_ff1;
            up_prev   <= up_ff2;
            down_prev <= down_ff2;

            pluck_valid_o <= 1'b0;
            if (refractory_q != 32'd0) begin
                refractory_q <= refractory_q - 32'd1;
            end else if (up_rise || down_rise) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= up_rise; // UP wins if both edges are present.
                refractory_q  <= REFRACT_CYC;
            end
        end
    end
endmodule

`default_nettype wire
