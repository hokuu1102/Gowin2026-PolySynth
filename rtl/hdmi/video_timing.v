module video_timing #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FP = 16,
    parameter integer H_SYNC = 96,
    parameter integer H_BP = 48,
    parameter integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FP = 10,
    parameter integer V_SYNC = 2,
    parameter integer V_BP = 33,
    parameter integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP,
    parameter integer H_BITS = $clog2(H_TOTAL),
    parameter integer V_BITS = $clog2(V_TOTAL)
) (
    input wire clk,
    input wire rst_n,
    output reg [H_BITS-1:0] x,
    output reg [V_BITS-1:0] y,
    output wire de,
    output wire hsync,
    output wire vsync
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x <= 0; y <= 0; end
        else if (x == H_TOTAL-1) begin
            x <= 0;
            if (y == V_TOTAL-1) y <= 0;
            else y <= y + 1'b1;
        end else x <= x + 1'b1;
    end
    assign de = (x < H_ACTIVE) && (y < V_ACTIVE);
    assign hsync = !((x >= H_ACTIVE + H_FP) &&
                     (x < H_ACTIVE + H_FP + H_SYNC));
    assign vsync = !((y >= V_ACTIVE + V_FP) &&
                     (y < V_ACTIVE + V_FP + V_SYNC));
endmodule
