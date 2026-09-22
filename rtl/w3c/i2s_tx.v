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
//    · `JUSTIFY=0` 左对齐（Philips 标准 I2S）—— ⭐ **当前默认**（Tang Console / `MAX98357A`）
//    · `JUSTIFY=1` 右对齐（LSBJ / 日本格式）—— ⚠️ 旧板 NEO Dock / `PT8211` 用这个
//    📌 `SLOT_BITS == DATA_BITS` 且 `MSB_DELAY == 0` 时两者**完全等价**。
//       ⚠️ 但 `SLOT_BITS == DATA_BITS` 而 `MSB_DELAY == 1`（Philips 的常规取值）时
//       左对齐**放不下** `DATA_BITS` 位 ⇒ **最低 1 位被静默丢弃**（见下方 `PARAM_OK` 自检）。
//       ⇒ ⛔ "16 BCK 时隙 + 16 bit 数据 + MSB 延迟 1" 这个组合**本身不自洽**，别用。
//
// 🔴 **换板警示（2026-09-22）**：⭐ 上面 §⭐⭐ 那段是**为 NEO Dock 的 `PT8211` 定的**。
//    ⚠️ 板卡现已改为 **Tang Console 60K** ⇒ ⭐ **默认值已翻成 `JUSTIFY=0`**。
//    ⚠️ **两个器件格式不同，但都能"出声"** ⇒ 语速/音量不对**很难一眼看出是格式问题** ⇒
//    ⭐ **上板必须用示波器对比 `WS` 与 `DIN` 的相位**再确认（⭐ 见 `C-6`）。
//
// ⭐⭐ 时序约定（踩过两次才定下来，⛔ 别改回去）
//   1. **一帧只在 `frame_start` 装载一次左右样点**。
//      先前写法是"每个时隙末尾装载下一个声道的样点"，结果：左声道对、**右声道差一帧**
//      （左右两次装载相隔半个帧，而数据源每帧只更新一次）。
//   2. 装载用**阻塞赋值**、且与"算出第 0 位"在**同一个 always 块**里 ⇒ 边界那一拍就能用上新数据。
//      ⛔ 用非阻塞赋值的话，第 0 位会拿到上一帧的旧值。
//   3. `HP_WS` **由本模块自己的计数器决定**（帧边界强制为左、进入右时隙置右），
//      ⛔ 不要直通 `clk_gen` 的 `lrclk` 寄存器 —— 它比位边界晚一拍，会让 WS 与数据错开半个 BCK。
//   4. ⭐⭐ **数据必须在 `HP_BCK` 的"另一个边沿"上变化**（2026-09-17 修，见下）。
//
// ⭐⭐⭐ 为什么 `HP_BCK` 复位值是 **1**（不是 0）—— 2026-09-17 根据 **PT8211 手册原文**修
//   手册（Princeton PT8211 V1.5 §FUNCTION DESCRIPTION）逐字写着：
//     · "Each valid DIN data will be shifted to the input register in the
//        **rising edge of the BCK**"            ⇒ **DAC 在 BCK 上升沿采 DIN**
//     · "…the serial bus input data format … is **Japanese or LSBJ**" ⇒ 右对齐（本模块 `JUSTIFY=1`）
//     · "When the Word Select (WS) clock in the **Low** level, the DIN data will be shifted
//        to the **right** input register … High level → **left**"  ⇒ ⚠️ **WS 低 = 右声道**
//        （⛔ 与标准 Philips I2S 相反！本项目音频是**单声道**（左右同一路）⇒ 无听感影响，
//          真要分左右时用 `LRCK_POL` 参数切；⛔ 别再照抄"WS 低 = 左"这个 I2S 说法）
//   ⇒ 既然 DAC 在**上升沿**采样，数据就**必须**在**下降沿**变化，否则两者同拍、
//     建立时间 ≈ 0（实测：修之前 `HP_BCK` 与 `HP_DIN` 在**同一个 clk 沿**更新）。
//   ⚠️ **这个缺陷仿真抓不到**：`tb/models/i2s_rx_model.sv` 是"检测到 BCK 上升沿后**再打一拍**"才取
//     DIN（等价于在上升沿后 20 ns 采样），因此它对"数据在哪个边沿变化"完全不敏感 ——
//     ⛔ 这也是"仿真全过、上板错位"的典型来源。真正的判据见 `tb/w3c/tb_i2s_tx_timing.sv`
//     （逐位量"数据变化沿 → 最近的 BCK 上升沿"的间隔，要求 ≥ 半个位周期）。
//   ✅ 改法：`HP_BCK` 复位值取 **1** ⇒ 它在 `cnt==1`（= 数据/WS 更新那一拍）**下降**、
//     在 `cnt==9` **上升**（`bclk_half_en` 每 8 拍一次、`bclk_en` 每 16 拍一次）
//      ⇒ ⭐ **采样沿正好落在数据窗正中**：数据在下降沿变 → **建立 8 clk = 160 ns**；
//        上升沿采样后再过 **保持 8 clk = 160 ns** 才轮到下一次数据变化。
//        （一个位周期 16 clk = 320 ns，DAC 采样点距两侧各 160 ns —— 理想值。）
//      ⛔ 不要"为了好看"把它改回 0 —— 那会把这个余量重新变成 0（数据与采样同拍）。
//      ⚠️ 判据见 `tb/w3c/tb_i2s_tx_timing.sv`（逐位量"数据变化沿 → 最近 BCK 上升沿"的间隔，
//        并把 PT8211 手册的 tH ≥ 25 ns / Fbck ≤ 18.4 MHz / Fws ≤ 384 kHz 一起断言）。
//
// ⛔ 不用 PLL、不用门控时钟：所有输出都是"由 clk 寄存出来"的引脚信号。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module i2s_tx #(
    parameter integer SAMPLE_W  = 24,   // 内部样点位宽（audio_t）
    parameter integer DATA_BITS = 16,   // 送给 DAC 的有效位（PT8211 = 16）
    parameter integer SLOT_BITS = 32,   // 每个声道时隙的 BCK 数（= CLK_PER_SAMPLE/BCLK_DIV/2）
    // ⭐ 2026-09-22 换板：`JUSTIFY` 默认 **1 → 0**
    //   🔴 板卡已定为 **Tang Console 60K**，其音频器件是 **`MAX98357A`**
    //      （I2S 输入 + 内置 DAC + D 类功放），⭐ **按【标准 I2S / 左对齐】解析**，
    //      ⛔ **不是** NEO Dock 上 `PT8211` 的 **LSBJ / 右对齐**。
    //   ⚠️ 两种格式**都能出声**，只是**数据整体移位**（听起来像音量/音质不对）
    //      ⇒ ⭐ 上板后应以示波器对比 `WS` 与 `DIN` 的相位确认（见 `C-6`）。
    //   ✅ `MSB_DELAY=1` / `LRCK_POL=0` 的默认值**本来就是标准 I2S 的取值**，⛔ 不用改。
    parameter integer JUSTIFY   = 0,    // 0 = 左对齐（标准 I2S，MAX98357A）；1 = 右对齐（LSBJ/日本格式，PT8211 用）
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

    // ── ⚠️ 参数合法性（2026-09-17 加：扫档验证时发现的**静默截断**缺陷）──────────
    // ① 左对齐（标准 I2S）要求时隙里**放得下** `MSB_DELAY + DATA_BITS` 位。
    //   ⛔ 反例：`SLOT_BITS=16 / DATA_BITS=16 / MSB_DELAY=1`
    //      ⇒ MSB 落在 bit1、LSB 应落在 **bit16**，而位序号只到 **bit15**
    //      ⇒ **LSB 永远发不出去**，实际只发了 15 位（**静默截断，仿真/上板都不会报错**）。
    //   ⭐ 这不是"实现 bug"，而是**Philips I2S 用 16 个 BCK 装 16 bit 数据本身不自洽**：
    //      要么 `MSB_DELAY=0`（此时左对齐与右对齐**完全等价**），要么时隙 ≥ `DATA_BITS + MSB_DELAY`。
    // ② ⭐ 右对齐（`JUSTIFY=1`）要求时隙 ≥ `DATA_BITS`，否则 `i2 = b-(SLOT_BITS-DATA_BITS)` 为正
    //      ⇒ 取到的是**低位**（丢掉 MSB ⇒ 等于噪声）。同样静默。
    //   ⇒ 本参数供 tb 直接引用（单一事实来源），并在仿真启动时告警（⛔ 综合工具忽略 `initial`）。
    localparam PARAM_OK =
        ((JUSTIFY == 0) ? (SLOT_BITS >= (DATA_BITS + MSB_DELAY)) : (SLOT_BITS >= DATA_BITS))
        && (SLOT_BITS >= 2) && (DATA_BITS >= 1);

    // ⭐ 取高 `min(DATA_BITS, SAMPLE_W)` 位（R-07）—— 用下面 `top_bits()` 函数做，见 L116 起。
    //    ⛔ 原来直接写 `sh_l[SAMPLE_W-1 -: DATA_BITS]`：当 `DATA_BITS > SAMPLE_W` 时
    //       低位越界 —— 仿真给 x、多数综合器零扩展 ⇒ **两边不一致**（"仿真过、上板错"那一类）。

    initial begin
        if (!PARAM_OK)
            $display("ERROR [i2s_tx] 参数不自洽：JUSTIFY=%0d SLOT_BITS=%0d DATA_BITS=%0d MSB_DELAY=%0d ⇒ 会有数据位被**静默丢弃**",
                     JUSTIFY, SLOT_BITS, DATA_BITS, MSB_DELAY);
        if (DATA_BITS > SAMPLE_W)
            $display("ERROR [i2s_tx] DATA_BITS(%0d) > SAMPLE_W(%0d)：高 %0d 位将被零扩展（确认这是你要的）",
                     DATA_BITS, SAMPLE_W, DATA_BITS - SAMPLE_W);
    end

    reg [BW-1:0]              bit_cnt;   // 当前时隙内位序号 0..SLOT_BITS-1
    reg                       ch;        // 0 = 左、1 = 右
    reg signed [SAMPLE_W-1:0] sh_l, sh_r;

    // ⭐ 取高 `min(DATA_BITS, SAMPLE_W)` 位（R-07，2026-09-17 修）
    //    ⛔ 原来直接写 `sh_l[SAMPLE_W-1 -: DATA_BITS]`：当 `DATA_BITS > SAMPLE_W` 时
    //       低位越界 —— 仿真给 x、多数综合器零扩展 ⇒ **两边不一致**（"仿真过、上板错"那一类）。
    //    ⇒ 用函数按位取：`k < SAMPLE_W` 才取，其余补 0（常量循环，可综合）。
    function [DATA_BITS-1:0] top_bits;
        input [SAMPLE_W-1:0] s;
        integer k;
        begin
            top_bits = {DATA_BITS{1'b0}};
            for (k = 0; k < DATA_BITS; k = k + 1)
                if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[SAMPLE_W-1-k];
        end
    endfunction

    wire [DATA_BITS-1:0] d16_l = top_bits(sh_l);
    wire [DATA_BITS-1:0] d16_r = top_bits(sh_r);
    // ⚠️ 原来这里还有一个 `wire d16 = (ch==0)?d16_l:d16_r;`，**从未被引用**（死逻辑，U-9）⇒ 已删。

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
            HP_BCK  <= 1'b1;                    // ⭐ 复位值 = 1（见文件头 R-03：数据在 BCK 下降沿变化）
            HP_WS   <= 1'b0 ^ LRCK_POL[0];      // 复位后 = 左声道（⚠️ PT8211 手册是"WS 低=右"，见文件头）
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
                // ⭐⭐ 这里必须**直接用 `sample_l`**，⛔ 不能用 `d16_l`（2026-09-17 修，R-04）
                //    `d16_l` 是由 `sh_l` **连续赋值**派生出来的网线：仿真里
                //    `sh_l = sample_l;`（阻塞）之后，连续赋值要等到**下一个 delta** 才更新，
                //    所以本拍读 `d16_l` 拿到的是**上一帧**的数据；而综合器按"新值"处理
                //    ⇒ **仿真与综合不一致**（正是"仿真过、上板错"那一类）。
                //    默认档（`SLOT_BITS=32`）看不出来：第 0 位落在时隙前部、`calc_bit` 恒为 0；
                //    ⚠️ 一旦 `SLOT_BITS == DATA_BITS`（16 BCK 时隙），**第 0 位就是 MSB** ⇒ 立刻错。
                HP_DIN  <= calc_bit({BW{1'b0}}, top_bits(sample_l));
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
