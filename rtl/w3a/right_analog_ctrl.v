`timescale 1ns/1ps
// right_analog_ctrl.v · P4 右手板 ADC 控制量采样
// CH1=主音量，CH2=颤音深度，CH3=颤音速率。CH1 的线性 B10K 电位器位置
// 经过 64 点对数 LUT，输出给 master_mix 的 Q1.15 线性增益。CH3 抵达后的
// 下一拍才提交颤音参数，保证 valid 与已锁存的数据同拍，避免错拍问题。
//
// ⭐⭐ 2026-10-29（缺口1 修复）：⭐ CH1 改为【单极性三段式】映射 ──────────
//   🔴 **原缺陷**（⭐ 见缺陷报告《主音量旋钮问题：现象诊断、根因与落地方案》）：
//     · **现象**：⭐ 顺时针旋到 12 点声音就已几乎听不到；⭐ 逆时针拧到底
//        （物理最小端）时声音反而异常突变变大（破音/爆音）/ 数值显示负数
//        （⭐ 那是【历史版本】把单极性电位器当变调摇杆做 `−2048` 偏移的锅）。
//     · **现状残余缺口**：⭐ B10K 逆时针拧死时 ADC 读数在 **10~80 之间波动**
//        （接触电阻+模拟地偏置）⇒ ⚠️ 旧的 `sample_data_i[11:6]` 直接取索引
//        会抖进 `idx=1`（增益 37）⇒ 🔴 **旋钮完全关死仍有轻微漏音** ✗
//   ✅ **修法（⭐ 用户报告给出的规范算法，逐字落实）**：
//     ① 底部 3% 死区（ADC ≤ 128）        ⇒ 硬静音 `16'd0`（彻底消除漏音/底噪）
//     ② 顶部 3% 满幅区（ADC ≥ 3968）     ⇒ 直通 `16'h7FFF`（0 dB 无衰减）
//     ③ 中间有效行程（129~3967）        ⇒ `(raw−128)×62/3840 + 1` 归一化到
//        1..62 档对数 LUT（⭐ 人耳听感音量随旋钮角度线性提升）
//   ⚠️ **极性说明（⭐ 为什么【不】取反索引）**：⭐ 用户报告的硬件事实是
//     "**逆时针拧死（物理最小）时 ADC 读数 10~80**" ⇒ ⭐ 即 ADC 与音量
//     **同向**（顺时针 code 增大 = 音量增大）⇒ ⭐ 直接映射方向本就正确，
//     ⛔ 取反反而会把旋钮做成反的 ✗
//   📌 位宽（🔴 关键）：⭐ `(raw−128)×62` 最大 **238_018**，⛔ 塞不进 12 位
//     ⇒ 必须**显式扩到 18 位**再乘（⭐ Verilog 自定宽表达式会截断成 12 位 ✗）
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

    // ── ⭐ 2026-10-29（缺口1）：⭐ CH1 三段式【死区 + 满幅直通 + 归一化对数】────
    //    ⭐ 死区/满幅区保证「关死彻底漏不掉、开满无损不削波」；
    //    ⭐ 中间行程归一化映射到 1..62 档（⭐ 0 与 63 保留给两个保真区）✅
    wire [11:0] vol_raw  = sample_data_i;
    wire [11:0] vol_span = vol_raw - 12'd128;                  // 1..3839（仅中区使用）
    //  ⚠️ 18 位乘法：3839×62 = 238_018 < 2^18 ✅（⛔ 12 位自定宽会截断 ✗）
    wire [17:0] vol_mid  = ({6'd0, vol_span} * 18'd62) / 18'd3840;  // 0..61
    reg  [5:0]  vol_lut_idx;
    always @(*) begin
        if (vol_raw <= 12'd128)
            vol_lut_idx = 6'd0;                                // 底部死区：硬静音
        else if (vol_raw >= 12'd3968)
            vol_lut_idx = 6'd63;                               // 顶部满幅：0 dB 直通
        else
            vol_lut_idx = 6'd1 + vol_mid[5:0];                 // 中区：1..62 档对数
    end

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
                    master_gain_o <= master_gain_lut(vol_lut_idx); // ⭐ 2026-10-29：三段式索引（见上）
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
