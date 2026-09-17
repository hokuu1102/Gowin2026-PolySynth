// ─────────────────────────────────────────────────────────────────────────────
// i2s_rx_model.sv · **S2 模型**（I2S 解串 + DAC 重构）—— 没有系统板时的"耳朵"
//
// 为什么必须有它（`files/20-代码/仿真与验证方案.md` §一 S2、§三 M1）：
//    M1 的判据是「**解串回的样点与 golden 逐点一致** + FFT 单谱峰」。
//    没有板子、没有耳机 ⇒ **"能不能出声"只能靠"把 I2S 解回来再比对"来证明**。
//    这个模型就是那把尺子：它按真实 DAC 的时序采样 `BCK/WS/DIN`，还原出左右声道样点。
//
// 参数必须与 `rtl/w3c/i2s_tx.v` **完全镜像**（否则"逐点一致"根本无从谈起）：
//    DATA_BITS / SLOT_BITS / JUSTIFY / MSB_DELAY / LRCK_POL / SAMPLE_W
//
// 输出
//    · `sample_l/r` + `valid_l/r` —— **解串后的样点**（默认走这条：与 golden 逐点比对）
//    · `recon_l/r`                —— 可选**二阶低通重构**后的"模拟样点"（`RECON_FILTER=1` 时开）
//      ⚠️ 重构只用于"看模拟感/画波形"，⛔ **验收仍以逐点比对为准**（滤波会引入相位与幅度误差）
//
// ⭐ 采样方式刻意与真实 DAC 一致：**用系统时钟去检测 `BCK` 的上升沿**，在上升沿上取 `WS`/`DIN`
//    （⛔ 不是"用 BCK 去采它自己"—— 那条路在经验里明确是错的：边沿计数恒为 0、断言永不下结论）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module i2s_rx_model #(
    parameter integer SAMPLE_W    = 24,
    parameter integer DATA_BITS   = 16,
    parameter integer SLOT_BITS   = 32,
    parameter integer JUSTIFY     = 1,     // 0 = 左对齐（标准 I2S）；1 = 右对齐（LSBJ，PT8211 用）
    parameter integer MSB_DELAY   = 1,
    parameter integer LRCK_POL    = 0,     // 0 = WS 低 = 左声道
    parameter integer RECON_FILTER = 0,    // 1 = 打开二阶低通重构输出
    parameter real    FS_HZ        = 48828.125,
    parameter real    RECON_FC_HZ  = 20000.0
) (
    input  wire clk,        // 系统时钟（必须远快于 BCK；本设计 = 16 × BCK）
    input  wire rst_n,
    input  wire bck,
    input  wire ws,
    input  wire din,

    output reg signed [SAMPLE_W-1:0] sample_l,
    output reg signed [SAMPLE_W-1:0] sample_r,
    output reg                       valid_l,
    output reg                       valid_r,
    output reg signed [SAMPLE_W-1:0] recon_l,
    output reg signed [SAMPLE_W-1:0] recon_r
);

    // ── 检测 BCK 上升沿（用慢时钟采快时钟的边沿 —— 这是"采样"，不是"用被测时钟采自己"）──
    reg bck_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bck_d <= 1'b0;
        else        bck_d <= bck;
    end
    wire bck_rise = (bck === 1'b1) && (bck_d === 1'b0);

    // ── 位计数 + 时隙移位寄存器 ─────────────────────────────────────
    localparam integer BW = $clog2(SLOT_BITS);
    reg [BW-1:0]            bit_cnt;
    reg [SLOT_BITS-1:0]     sr;          // 移位：sr[SLOT_BITS-1] = 本时隙第 1 位，sr[0] = 最后一位
    reg                     ch;          // 0 = 左、1 = 右（由 WS 决定）

    wire ch_now = ws ^ LRCK_POL[0];      // 0 = 左声道

    // 提取本时隙的 DATA_BITS 位（按 JUSTIFY）
    // ⚠️ 必须用**移位之后**的值（`sr_next`）：在"最后一位"那一拍，非阻塞赋值还没更新 `sr`，
    //    用旧 `sr` 提取会整体错一位（本文件实测踩过 —— M1 的"逐点一致"会因此永远差 1 bit）。
    wire [SLOT_BITS-1:0] sr_next  = {sr[SLOT_BITS-2:0], din};

    // ⭐ 与 `rtl/w3c/i2s_tx.v` 的 `calc_bit` **严格镜像**（2026-09-17 重写）：
    //    位序号约定：`s[SLOT_BITS-1]` = 本时隙送出的**第 1 位**，`s[SLOT_BITS-1-b]` = 第 b 位。
    //    · `JUSTIFY=1` 右对齐（LSBJ）：数据占时隙**尾部** `DATA_BITS` 位
    //      ⇒ 第 i 位（i=0 是 MSB）在 `s[DATA_BITS-1-i]`
    //    · `JUSTIFY=0` 左对齐（Philips）：MSB 落在第 `MSB_DELAY` 位
    //      ⇒ 第 i 位在 `s[SLOT_BITS-1-(MSB_DELAY+i)]`
    //    ⚠️ 左对齐若 `SLOT_BITS < DATA_BITS + MSB_DELAY`，**低位会被静默丢弃** ——
    //       模型这里**照样按同一规则丢弃**，这样"模型与发送器一致"仍然成立，
    //       而"低位丢失"这件事由 `tb/w3c/tb_i2s_tx_sweep.sv` 用**已知必错**的配置显式证明。
    function [DATA_BITS-1:0] extract;
        input [SLOT_BITS-1:0] s;
        integer i2;
        begin
            extract = {DATA_BITS{1'b0}};
            for (i2 = 0; i2 < DATA_BITS; i2 = i2 + 1) begin
                if (JUSTIFY == 0) begin
                    if ((MSB_DELAY + i2) < SLOT_BITS)
                        extract[DATA_BITS-1-i2] = s[SLOT_BITS-1-(MSB_DELAY+i2)];
                end else begin
                    if (((SLOT_BITS-DATA_BITS) + i2) < SLOT_BITS)
                        extract[DATA_BITS-1-i2] = s[SLOT_BITS-1-((SLOT_BITS-DATA_BITS)+i2)];
                end
            end
        end
    endfunction

    wire [DATA_BITS-1:0] raw = extract(sr_next);

    // 16 bit → 24 bit：**左移对齐到高位**（与 i2s_tx 的"取高 16 位"互逆）
    wire signed [SAMPLE_W-1:0] raw_ext = $signed(raw) <<< (SAMPLE_W - DATA_BITS);

    // ── 二阶低通重构（real 运算；仅测试台用）────────────────────────
    // ⚠️ 用**字面量**而不是 `$exp(...)`：实测 iverilog 不接受在 localparam/常量表达式里调 `$exp`。
    //    `RECON_ALPHA = 1 - e^(-2π·fc/fs)`；默认 fc=18 kHz、fs=48.828 kHz ⇒ 0.9014。
    parameter real RECON_ALPHA = 0.9014;
    real y1_l, y2_l, y1_r, y2_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt = {BW{1'b0}};
            sr      = {SLOT_BITS{1'b0}};
            ch      = 1'b0;
            sample_l <= {SAMPLE_W{1'b0}};
            sample_r <= {SAMPLE_W{1'b0}};
            valid_l  <= 1'b0;
            valid_r  <= 1'b0;
            recon_l  <= {SAMPLE_W{1'b0}};
            recon_r  <= {SAMPLE_W{1'b0}};
            y1_l = 0.0; y2_l = 0.0; y1_r = 0.0; y2_r = 0.0;
        end else begin
            valid_l <= 1'b0;
            valid_r <= 1'b0;

            if (bck_rise) begin
                // ⭐⭐ **用 WS 划时隙**（2026-09-17 重写）—— 与真实 DAC 的做法一致。
                //    ⛔ 旧写法是"从我看到的第一条 BCK 上升沿开始数位"，隐含假设
                //       "BCK 的第一个上升沿恰好落在帧/时隙边界上"。一旦 `i2s_tx` 的
                //       `HP_BCK` 复位极性变了（数据改在下降沿变化、采样沿移半拍），
                //       这个假设就崩了 ⇒ 模型与 DUT 的位对齐错开一位（现象：几乎全错，
                //       但"看起来格式都对"）。真实器件不会有这个问题，因为它**靠 WS 界定时隙**。
                //    ⇒ 现在：BCK 上升沿移位；**WS 一变就是新时隙的第 0 位**；收满 SLOT_BITS 位出样点。
                sr = {sr[SLOT_BITS-2:0], din};
                if (ch_now !== ch) begin
                    ch      = ch_now;   // ⭐ 时隙边界：本拍就是新时隙的**第 0 位**
                    bit_cnt = 0;
                end

                if (bit_cnt == SLOT_BITS - 1) begin
                    // 一个时隙收满 ⇒ 出样点（`ch` = 本时隙的声道）
                    if (ch == 1'b0) begin
                        sample_l <= raw_ext;
                        valid_l  <= 1'b1;
                        if (RECON_FILTER != 0) begin
                            y1_l = y1_l + RECON_ALPHA * (real'(raw_ext) - y1_l);
                            y2_l = y2_l + RECON_ALPHA * (y1_l - y2_l);
                            recon_l <= $rtoi(y2_l);
                        end
                    end else begin
                        sample_r <= raw_ext;
                        valid_r  <= 1'b1;
                        if (RECON_FILTER != 0) begin
                            y1_r = y1_r + RECON_ALPHA * (real'(raw_ext) - y1_r);
                            y2_r = y2_r + RECON_ALPHA * (y1_r - y2_r);
                            recon_r <= $rtoi(y2_r);
                        end
                    end
                    bit_cnt = 0;
                end else begin
                    bit_cnt = bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule
