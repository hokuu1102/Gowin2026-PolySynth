`timescale 1ns/1ps
// right_analog_ctrl.v · P4 右手板 ADC 控制量采样
// CH1=主音量，CH2=颤音深度，CH3=颤音速率。CH1 的线性 B10K 电位器位置
// 经过 64 点对数 LUT，输出给 master_mix 的 Q1.15 线性增益。CH3 抵达后的
// 下一拍才提交颤音参数，保证 valid 与已锁存的数据同拍，避免错拍问题。
`default_nettype none

module right_analog_ctrl (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        enable_i,
    input  wire        sample_valid_i,
    input  wire [2:0]  sample_ch_i,
    input  wire [11:0] sample_data_i,
    output reg  [15:0] master_gain_o,
    output reg  [11:0] vibrato_depth_o,
    output reg  [11:0] vibrato_rate_o,
    output reg         param_valid_o
);
    reg pending_q;

    // 线性旋钮位置 -> 线性幅度。索引 1..63 对应 -60 dB .. 0 dB，
    // 相邻档位恰为 60/63 dB；索引 0 保持硬静音，便于用户获得明确的 OFF。
    // 显式 case 会综合为分布式 ROM，避免运行时除法/幂运算。
    function automatic [15:0] master_gain_lut;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  master_gain_lut = 16'd0;
                6'd1:  master_gain_lut = 16'd37;
                6'd2:  master_gain_lut = 16'd41;
                6'd3:  master_gain_lut = 16'd46;
                6'd4:  master_gain_lut = 16'd51;
                6'd5:  master_gain_lut = 16'd57;
                6'd6:  master_gain_lut = 16'd63;
                6'd7:  master_gain_lut = 16'd71;
                6'd8:  master_gain_lut = 16'd79;
                6'd9:  master_gain_lut = 16'd88;
                6'd10: master_gain_lut = 16'd98;
                6'd11: master_gain_lut = 16'd109;
                6'd12: master_gain_lut = 16'd122;
                6'd13: master_gain_lut = 16'd136;
                6'd14: master_gain_lut = 16'd152;
                6'd15: master_gain_lut = 16'd170;
                6'd16: master_gain_lut = 16'd189;
                6'd17: master_gain_lut = 16'd211;
                6'd18: master_gain_lut = 16'd236;
                6'd19: master_gain_lut = 16'd263;
                6'd20: master_gain_lut = 16'd294;
                6'd21: master_gain_lut = 16'd328;
                6'd22: master_gain_lut = 16'd366;
                6'd23: master_gain_lut = 16'd408;
                6'd24: master_gain_lut = 16'd455;
                6'd25: master_gain_lut = 16'd508;
                6'd26: master_gain_lut = 16'd567;
                6'd27: master_gain_lut = 16'd633;
                6'd28: master_gain_lut = 16'd706;
                6'd29: master_gain_lut = 16'd788;
                6'd30: master_gain_lut = 16'd879;
                6'd31: master_gain_lut = 16'd981;
                6'd32: master_gain_lut = 16'd1095;
                6'd33: master_gain_lut = 16'd1221;
                6'd34: master_gain_lut = 16'd1363;
                6'd35: master_gain_lut = 16'd1521;
                6'd36: master_gain_lut = 16'd1697;
                6'd37: master_gain_lut = 16'd1894;
                6'd38: master_gain_lut = 16'd2113;
                6'd39: master_gain_lut = 16'd2358;
                6'd40: master_gain_lut = 16'd2631;
                6'd41: master_gain_lut = 16'd2936;
                6'd42: master_gain_lut = 16'd3277;
                6'd43: master_gain_lut = 16'd3656;
                6'd44: master_gain_lut = 16'd4080;
                6'd45: master_gain_lut = 16'd4553;
                6'd46: master_gain_lut = 16'd5081;
                6'd47: master_gain_lut = 16'd5669;
                6'd48: master_gain_lut = 16'd6326;
                6'd49: master_gain_lut = 16'd7059;
                6'd50: master_gain_lut = 16'd7878;
                6'd51: master_gain_lut = 16'd8790;
                6'd52: master_gain_lut = 16'd9809;
                6'd53: master_gain_lut = 16'd10946;
                6'd54: master_gain_lut = 16'd12214;
                6'd55: master_gain_lut = 16'd13630;
                6'd56: master_gain_lut = 16'd15209;
                6'd57: master_gain_lut = 16'd16972;
                6'd58: master_gain_lut = 16'd18938;
                6'd59: master_gain_lut = 16'd21133;
                6'd60: master_gain_lut = 16'd23582;
                6'd61: master_gain_lut = 16'd26315;
                6'd62: master_gain_lut = 16'd29364;
                default: master_gain_lut = 16'h7FFF;
            endcase
        end
    endfunction

    always @(posedge clk_i) begin
        if (!rst_n_i || !enable_i) begin
            // 未装/未启用 P4 时维持 unity；否则现有两 ADC 硬件会被静音。
            master_gain_o   <= 16'h7FFF;
            vibrato_depth_o <= 12'd0;
            vibrato_rate_o  <= 12'd0;
            param_valid_o   <= 1'b0;
            pending_q       <= 1'b0;
        end else begin
            param_valid_o <= pending_q;
            pending_q     <= 1'b0;
            if (sample_valid_i) begin
                if (sample_ch_i == 3'd1)
                    master_gain_o <= master_gain_lut(sample_data_i[11:6]);
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
