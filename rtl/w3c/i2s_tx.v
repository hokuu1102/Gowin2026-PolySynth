// ─────────────────────────────────────────────────────────────────────────────
// i2s_tx.v · L2 I2S 发送（→ 板载 DAC）
//
// ⚠️ 目标器件已确认：板载 DAC = **PT8211-S**（16 bit 立体声 DAC，功放 NS4263，`K-24`）。
//    规格书正文写明它的数字输入格式是 **LSBJ（Least Significant Bit Justified，
//    又称 Japanese input format）**，two's complement、MSB first。
//    ⇒ ⛔ **PT8211 不是标准 Philips I2S**（这一条先前被搞错过，见 `K-39`）。
//
// ⭐⭐ 格式已定（`K-39` 结案，2026-09-17）——**LSBJ 右对齐**，依据两条：
//    ① 规格书正文：`digital input timing format is LSBJ (Japanese input format) … MSB first`
//    ② 一份**已验证出声**的 PT8211 驱动（立创逻辑派 `LSBJ_audio_driver.v`：
//       每声道时隙 24 BCK、数据只占**后 16 个 BCK**、MSB 先出，且时隙里**还有 8 个空闲 BCK**
//       ⇒ ①它确实是右对齐 ②**DAC 容许时隙里多出 BCK**）
//    ⇒ 我们沿用冻结的 `BCLK = 3.125 MHz = 64 × fs`（每声道 32 个 BCK），
//      把 16 bit 数据放在**每个 32 BCK 时隙的尾部**（`JUSTIFY=1`）即可，⛔ `M0` 的数字不用改。
//    ⚠️ `LRCK_POL`（WS 极性）两份参考实现互相矛盾（一份高=左、一份低=左）—— 规格书时序图是扫描图、
//       本机读不了；但 **我们音频通路是单声道**（左右送同一路）⇒ 极性只影响"哪声道"，
//       ⛔ 对本项目无影响；万一要改，也只是一个参数。
//
// ⭐ 因此本模块把"格式"全部做成**参数**：
//    · `JUSTIFY=1` 右对齐（LSBJ / 日本格式，**当前默认，PT8211 用这个**）
//    · `JUSTIFY=0` 左对齐（Philips 标准 I2S：MSB 相对时隙起点延迟 `MSB_DELAY` 个 BCK）
//    📌 `SLOT_BITS == DATA_BITS` 时（每声道 16 个 BCK）两者**完全等价**。
//
// ⭐⭐ 时序约定（踩过两次才定下来，⛔ 别改回去）
//   1. **一帧只在 `frame_start` 装载一次左右样点**。
//      先前写法是"每个时隙末尾装载下一个声道的样点"，结果：左声道对、**右声道差一帧**
//      （左右两次装载相隔半个帧，而数据源每帧只更新一次）。
//   2. 装载用**阻塞赋值**、且与"算出第 0 位"在**同一个 always 块**里 ⇒ 边界那一拍就能用上新数据。
//      ⛔ 用非阻塞赋值的话，第 0 位会拿到上一帧的旧值。
//   3. `HP_WS` **由本模块自己的计数器决定**（帧边界强制为左、进入右时隙置右），
//      ⛔ 不要直通 `clk_gen` 的 `lrclk` 寄存器 —— 它比位边界晚一拍，会让 WS 与数据错开半个 BCK。
//   4. `HP_BCK` 由 `bclk_half_en` 翻转（周期 = 16 clk = 3.125 MHz），数据在 `bclk_en` 边界更新
//      ⇒ DAC 在 `HP_BCK` 的另一个边沿采样时，数据已稳定半个周期 ✅
//
// ⛔ 不用 PLL、不用门控时钟：所有输出都是"由 clk 寄存出来"的引脚信号。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module i2s_tx #(
    parameter integer SAMPLE_W  = 24,   // 内部样点位宽（audio_t）
    parameter integer DATA_BITS = 16,   // 送给 DAC 的有效位（PT8211 = 16）
    parameter integer SLOT_BITS = 32,   // 每个声道时隙的 BCK 数（= CLK_PER_SAMPLE/BCLK_DIV/2）
    parameter integer JUSTIFY   = 1,    // 0 = 左对齐（标准 I2S）；1 = 右对齐（LSBJ/日本格式，PT8211 用）
    parameter integer MSB_DELAY = 1,    // 仅 JUSTIFY=0：MSB 相对时隙起点延迟的 BCK 数（标准 I2S = 1）
    parameter integer LRCK_POL  = 0     // 0 = WS 低 = 左声道（标准）；1 = 取反
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       bclk_en,
    input  wire                       bclk_half_en,
    input  wire                       frame_start,   // 来自 clk_gen：帧起点（1 个 clk）
    input  wire signed [SAMPLE_W-1:0] sample_l,      // ⭐ 数据源须**提前一帧**给出本帧的样点
    input  wire signed [SAMPLE_W-1:0] sample_r,

    output reg                        HP_BCK,
    output reg                        HP_WS,
    output reg                        HP_DIN
);

    localparam integer BW = $clog2(SLOT_BITS);

    reg [BW-1:0]              bit_cnt;   // 当前时隙内位序号 0..SLOT_BITS-1
    reg                       ch;        // 0 = 左、1 = 右
    reg signed [SAMPLE_W-1:0] sh_l, sh_r;

    // 取高 DATA_BITS 位（24 bit 内部样点 → 16 bit DAC；⛔ 直接截断、未做舍入/抖动）
    wire [DATA_BITS-1:0] d16_l = sh_l[SAMPLE_W-1 -: DATA_BITS];
    wire [DATA_BITS-1:0] d16_r = sh_r[SAMPLE_W-1 -: DATA_BITS];
    wire [DATA_BITS-1:0] d16   = (ch == 1'b0) ? d16_l : d16_r;

    // 当前位序号应输出的数据位（两种对齐都实现）
    // ⚠️ 必须是**函数**（按传入的 b 计算），⛔ 不能用"组合 always 算好的 bit_out"：
    //    时序块里先阻塞更新了 bit_cnt、再引用 bit_out 时，bit_out 还是**旧值**
    //    ⇒ 输出整整晚一个位周期（现象：解串值恰好约等于期望的一半、过零点却能对上）。本文件实测踩过。
    function [0:0] calc_bit;
        input [BW-1:0]        b;
        input [DATA_BITS-1:0] d;
        integer i2;
        begin
            calc_bit = 1'b0;
            if (JUSTIFY == 0) begin
                i2 = b - MSB_DELAY;                    // 左对齐：数据占 [MSB_DELAY, +DATA_BITS)
                if (i2 >= 0 && i2 < DATA_BITS) calc_bit = d[DATA_BITS-1-i2];
            end else begin
                i2 = b - (SLOT_BITS - DATA_BITS);      // 右对齐（LSBJ）：数据占时隙尾部
                if (i2 >= 0 && i2 < DATA_BITS) calc_bit = d[DATA_BITS-1-i2];
            end
        end
    endfunction

    // ⚠️ 同一个 always 块内对内部状态统一用**阻塞赋值**：装载样点与"算第 0 位"必须在同一拍可见。
    // ⚠️ **同步复位**（`W3接口冻结表.md` §〇 约定 2）—— ⛔ 不写 `or negedge rst_n`
    always @(posedge clk) begin
        if (!rst_n) begin
            bit_cnt <= {BW{1'b0}};
            ch      <= 1'b0;
            sh_l    <= {SAMPLE_W{1'b0}};
            sh_r    <= {SAMPLE_W{1'b0}};
            HP_BCK  <= 1'b0;
            HP_WS   <= 1'b0 ^ LRCK_POL[0];      // 复位后 = 左声道
            HP_DIN  <= 1'b0;
        end else begin
            if (bclk_half_en) HP_BCK <= ~HP_BCK;   // 3.125 MHz 方波（寄存输出，不是门控时钟）

            if (frame_start) begin
                // ── 帧边界：一次性装载左右样点，并从第 0 位开始 ──
                sh_l    = sample_l;
                sh_r    = sample_r;
                bit_cnt = {BW{1'b0}};
                ch      = 1'b0;
                HP_WS   <= 1'b0 ^ LRCK_POL[0];     // 帧起点 = 左声道
                HP_DIN  <= calc_bit({BW{1'b0}}, d16_l);   // 用**刚装载**的数据算第 0 位
            end else if (bclk_en) begin
                if (bit_cnt == SLOT_BITS - 1) begin
                    bit_cnt = {BW{1'b0}};
                    ch      = ~ch;                 // 进入下一个声道时隙
                    HP_WS   <= ch ? (1'b1 ^ LRCK_POL[0]) : (1'b0 ^ LRCK_POL[0]);
                end else begin
                    bit_cnt = bit_cnt + 1'b1;
                end
                // ⭐ 用**更新后**的位序号算这一位
                HP_DIN <= calc_bit(bit_cnt, (ch == 1'b0) ? d16_l : d16_r);
            end
        end
    end

endmodule
