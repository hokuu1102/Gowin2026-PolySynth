`timescale 1ns/1ps
// right_analog_ctrl.v · P4 右手板 ADC 控制量采样
// CH2=颤音深度，CH3=颤音速率。CH3 抵达后的下一拍才提交，保证 valid 与
// 已锁存的两项数据同拍，避免“控制脉冲带着上一轮速率”的错拍问题。
`default_nettype none

module right_analog_ctrl (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        enable_i,
    input  wire        sample_valid_i,
    input  wire [2:0]  sample_ch_i,
    input  wire [11:0] sample_data_i,
    output reg  [11:0] vibrato_depth_o,
    output reg  [11:0] vibrato_rate_o,
    output reg         param_valid_o
);
    reg pending_q;

    always @(posedge clk_i) begin
        if (!rst_n_i || !enable_i) begin
            vibrato_depth_o <= 12'd0;
            vibrato_rate_o  <= 12'd0;
            param_valid_o   <= 1'b0;
            pending_q       <= 1'b0;
        end else begin
            param_valid_o <= pending_q;
            pending_q     <= 1'b0;
            if (sample_valid_i) begin
                if (sample_ch_i == 3'd2)
                    vibrato_depth_o <= sample_data_i;
                if (sample_ch_i == 3'd3) begin
                    vibrato_rate_o <= sample_data_i;
                    pending_q      <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
