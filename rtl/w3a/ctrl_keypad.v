`timescale 1ns/1ps
// ============================================================================
//  ctrl_keypad.v -- 控制板 4x4 矩阵键盘：逐行扫描 + 扫描式去抖 + 边沿脉冲
//
//  为什么自己写去抖（而不是直接用 rtl/drivers/debounce.sv）：
//    debounce.sv 每键一个 **32 位** 计数器，NKEY=16 就是 512 个 FF；
//    而本设计 DB 只需要 ~18 位。当前 CLS 已到 86%，LUT/FF 都紧张，
//    所以这里用【扫描式去抖】：扫描本身就在重复采样，只需"连续 N 次相同"
//    ⇒ 每键 3 位计数器 ⇒ 16 键合计 ~48 FF。
//    （debounce.sv 仍用于直连按键 timbre_btn / pedal_sus / EC11，那里键数少。）
//
//  硬件方向（constraint 与 PCB 双向核对过，固定不可改）：
//    ctrl_row_o[3:0] = 出（FPGA 驱动行）  D16 / E16 / E17 / F16
//    ctrl_col_i[3:0] = 入（上拉，只读列） F15 / C20 / D20 / D19
//  => 只能"逐行拉低、读列"。一次只有一行低，所以同一列两个键
//     也不会互相推挽（这正是 top.v 里那句警告担心的情形）。
//
//  时序：每行停留 SCAN_DIV 拍（等列上拉电平稳定）后采样；
//        4 行走完 = 一次扫描 ⇒ 拉高 scan_done 一拍。
//        连续 DEB_N 次扫描一致 ⇒ 该键电平更新（去抖 = DEB_N x 扫描周期）。
//
//  判据（见 tb/w3a/tb_ctrl_keypad.sv）：每条都必须能失败
//    1) 逐行扫描：4 行轮流拉低，且**任一时刻只有一行低**
//    2) 单键：定位到正确的 (行,列)，键号 = row*4+col
//    3) 同列双键：两个键都能被认出来（不会被推挽吃掉）
//    4) 去抖：抖动输入**不改变** key_level
//    5) 稳定输入 DEB_N 次后 key_level 改变，且只出一个 key_down 脉冲
//    6) 松开 ⇒ 一个 key_up 脉冲
//    7) 悬空/未接板（列全高）⇒ key_level 全 0，且**不产生任何脉冲**
// ============================================================================
`default_nettype none

module ctrl_keypad #(
    // 每行停留多少拍（等列上拉稳定）。50 MHz 下 12500 拍 = 250 us，4 行 = 1 ms/扫描
    parameter integer SCAN_DIV = 12500,
    // 连续多少次扫描一致才算稳定（去抖时间 = DEB_N x 扫描周期）
    parameter integer DEB_N    = 8,
    parameter integer CLK_HZ   = 50_000_000
) (
    input  wire       clk,
    input  wire       rst_n,

    // 矩阵
    output wire [3:0] row_o,
    input  wire [3:0] col_i,

    // 结果
    output reg  [15:0] key_level,   // 去抖后的电平（1 = 按下）
    output reg  [15:0] key_down,    // 按下那一拍的单周期脉冲
    output reg  [15:0] key_up       // 松开那一拍的单周期脉冲
);

    localparam integer DIV_W = (SCAN_DIV <= 2) ? 1 : $clog2(SCAN_DIV);
    localparam integer CNT_W = (DEB_N <= 2) ? 1 : $clog2(DEB_N);

    // 参数自检（与项目其它模块同一套路）
    initial begin
        if (SCAN_DIV < 2)
            $display("ERROR [ctrl_keypad] SCAN_DIV=%0d must be >= 2", SCAN_DIV);
        if (DEB_N < 2)
            $display("ERROR [ctrl_keypad] DEB_N=%0d must be >= 2", DEB_N);
        if (SCAN_DIV > (1 << DIV_W))
            $display("ERROR [ctrl_keypad] SCAN_DIV=%0d does not fit DIV_W=%0d", SCAN_DIV, DIV_W);
        else
            $display("NOTE [ctrl_keypad] PARAM_OK=1 (SCAN_DIV=%0d DEB_N=%0d CLK_HZ=%0d scan_us=%0d db_ms=%0d)",
                     SCAN_DIV, DEB_N, CLK_HZ,
                     (SCAN_DIV * 4 * 1000000) / CLK_HZ / 1000,
                     (SCAN_DIV * 4 * DEB_N * 1000) / CLK_HZ);
    end

    // ── 逐行扫描 ────────────────────────────────────────────────────────────
    reg [DIV_W-1:0] div_cnt;
    reg [1:0]       row_cnt;
    reg [15:0]      raw_r;        // 本次扫描采到的原始位图（1 = 按下）
    reg             scan_done;    // 一拍脉冲
    reg             scan_done_d;  // 延一拍：此时 raw_r 已完整

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt     <= {DIV_W{1'b0}};
            row_cnt     <= 2'd0;
            raw_r       <= 16'd0;
            scan_done   <= 1'b0;
            scan_done_d <= 1'b0;
        end else begin
            scan_done   <= 1'b0;
            scan_done_d <= scan_done;

            if (div_cnt == SCAN_DIV[DIV_W-1:0] - 1'b1) begin
                div_cnt <= {DIV_W{1'b0}};
                // 行末采样：col_i 已经稳定了 SCAN_DIV 拍
                // 列是低有效（上拉，按下接地）⇒ 取反归一成「1 = 按下」
                raw_r[row_cnt*4 +: 4] <= ~col_i;
                if (row_cnt == 2'd3) begin
                    row_cnt   <= 2'd0;
                    scan_done <= 1'b1;
                end else begin
                    row_cnt <= row_cnt + 2'd1;
                end
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    // 一次只有一行拉低
    assign row_o = ~(4'b0001 << row_cnt);

    // ── 扫描式去抖：连续 DEB_N 次一致才认 ──────────────────────────────────
    reg [CNT_W-1:0] deb_cnt [0:15];
    integer         ki;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (ki = 0; ki < 16; ki = ki + 1) begin
                key_level[ki] <= 1'b0;
                deb_cnt[ki]   <= {CNT_W{1'b0}};
            end
            key_down <= 16'd0;
            key_up   <= 16'd0;
        end else begin
            key_down <= 16'd0;
            key_up   <= 16'd0;
            if (scan_done_d) begin
                for (ki = 0; ki < 16; ki = ki + 1) begin
                    if (raw_r[ki] == key_level[ki]) begin
                        deb_cnt[ki] <= {CNT_W{1'b0}};
                    end else if (deb_cnt[ki] >= DEB_N[CNT_W-1:0] - 1'b1) begin
                        key_level[ki] <= raw_r[ki];
                        deb_cnt[ki]   <= {CNT_W{1'b0}};
                        if (raw_r[ki]) key_down[ki] <= 1'b1;
                        else           key_up[ki]   <= 1'b1;
                    end else begin
                        deb_cnt[ki] <= deb_cnt[ki] + 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
