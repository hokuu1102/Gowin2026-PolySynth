`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// master_mix.v · 数字主音量 + 静音斜坡（W3c 出声通路的「最后一级」）
//
// ⭐ 位置（见 `files/20-代码/RTL代码结构与接口规划.md` §1 `audio/` 树）：
//     `tdm_render_mixer`（干声 `dry_sample_o`）→ **`master_mix`** → `i2s_tx`
//     职责一句话：**64 点对数增益后的数字主音量与静音斜坡**（规划原文）。
//
// ── 为什么必须存在（⛔ 不是"可有可无的音量"）────────────────────────────
//   · 硬件侧主音量旋钮是 **B10K 线性电位器**（`files/10-硬件/右手板方案.md` 定案），
//     位置→增益**必须套对数映射**（`K-09`），否则"前段爆音、后段无变化"。
//   · 换音量要**平滑过渡（斜率限制）**，否则会有"咔哒"声（规划原文）。
//   · 数字侧音量要**内部位宽留够（≥20 bit 中间位宽）**，否则衰减损失有效位。
//
// ── 设计（遵守本项目三条纪律：单时钟域 / 时钟使能 / Verilog-2001）─────────
//   · ⭐ **对数增益 = 外部职责**：本模块**不做对数映射**，只做「乘以一个已算好的
//     线性增益系数」。理由：① 对数映射是「位置→增益」的查表，属于 `right_analog_ctrl`
//     / `axis_frontend` 的活（它们读 ADC 旋钮位置，输出 Q1.15 增益）；
//     ② 本模块只保证「**系数变了不许有咔哒声**」这个**时序**语义。
//     ⇒ 接口上 `gain_i` 是 **Q1.15 线性增益**（16 bit，[0, 1) 分数），
//        ⭐ 谁给对数系数都行，本模块不关心。
//   · ⭐ **静音斜坡（mute ramp）**：内部 `gain_r` 每 `sample_tick_i` 向 `gain_i`
//     逼近 `RAMP_STEP`（线性斜率限制），⛔ 不一步跳到目标。
//     ⇒ 换音量 / 静音 / 开机渐入，都不会产生可闻"咔哒"。
//   · ⭐ **乘法 + 定标**：`sample × gain`，中间位宽 `SAMPLE_W + GAIN_W`（24+16=40 bit），
//     结果 **右移 15**（Q1.15 定标）还原到样本域。⚠️ 用 `>>>` 保留符号。
//   · ⭐ **饱和**（`K-101` 教训）：⛔ 不用 `signed` 限定符 + 比较（iverilog 会退化成
//     无符号比较）；改成**逐位判断溢出**（符号位之上任何一位与符号位不同 ⇒ 溢出）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`）：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**。
//   · ⭐⭐ **单样本链不反压**：`valid_i` 来了就当拍算完，⛔ 不能插入可变的等待。
//     （`i2s_tx` 要求数据源提前一帧给样点，本模块**零延迟透传 valid**。）
//   · ⭐ **任何"容量有限"的计数器/斜坡步进都必须可观测**（`K-106`）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module master_mix #(
    // 样点位宽（与 `tdm_render_mixer`/`i2s_tx` 一致）
    parameter integer SAMPLE_W  = 24,
    // 增益位宽（Q1.15 线性增益）
    parameter integer GAIN_W    = 16,
    // 斜坡步长：每个 sample_tick 增益逼近目标的步长（Q1.15 增量）
    //   默认 128（≈ 0.0039 / tick）⇒ 从 0 拉到满（32767）约 256 tick ≈ 5.2 ms
    //   ⚠️ 落在"10~50 ms 渐入"（`音频输出方案.md` §4.4）下端，听感平滑、无咔哒。
    parameter integer RAMP_STEP = 128
) (
    input  wire                     clk_i,
    input  wire                     rst_n_i,
    input  wire                     sample_tick_i,   // ⭐ 时钟使能（斜坡节拍，每 1024 clk）

    // ── 单样本流（⭐ 不反压：valid 透传，当拍算完）────────────────────────
    input  wire                     valid_i,
    input  wire signed [SAMPLE_W-1:0] sample_i,

    // ── 主音量（Q1.15 线性增益，[0, 1)）───────────────────────────────────
    input  wire [GAIN_W-1:0]        gain_i,          // ⭐ 最高位须为 0（分数）

    // ── 输出 ────────────────────────────────────────────────────────────────
    output wire                     valid_o,
    output wire signed [SAMPLE_W-1:0] sample_o,
    // ⭐⭐ 可观测性（`K-106` 纪律）：斜坡**是否仍在逼近目标**（诊断"换音量没生效"）
    output wire                     ramp_busy_o
);

    // ── 斜坡状态机：gain_r 每 tick 向 gain_i 逼近 ─────────────────────────
    //   ⭐ 用「饱和逼近」：距离不足一步就一步到位，⛔ 不越过目标（否则会在目标附近
    //      来回抖动 ⇒ 产生低频"嗒嗒"声）。
    reg [GAIN_W-1:0] gain_r;

    wire [GAIN_W-1:0] gain_diff;      // 目标 − 当前（取符号判断方向）
    wire              ramp_up;        // 当前 < 目标 ⇒ 需要上调
    wire              ramp_dn;        // 当前 > 目标 ⇒ 需要下调
    wire              ramp_done;      // 已到目标 ⇒ 停

    // ⭐ 用「差」判方向，⛔ 不做带符号比较（K-101 同族：避免 signed 退化）
    assign gain_diff  = gain_i - gain_r;              // 无符号减法，借位 = 方向
    assign ramp_up    = gain_r < gain_i;
    assign ramp_dn    = gain_r > gain_i;
    assign ramp_done  = (gain_r == gain_i);
    assign ramp_busy_o = ~ramp_done;

    // ⭐ 下一拍增益：若已到目标则保持；否则朝目标走一步（饱和，不越过）
    wire [GAIN_W-1:0] gain_up_v   = (gain_r + RAMP_STEP[GAIN_W-1:0] < gain_i)
                                  ? (gain_r + RAMP_STEP[GAIN_W-1:0]) : gain_i;
    wire [GAIN_W-1:0] gain_dn_v   = (gain_r - RAMP_STEP[GAIN_W-1:0] > gain_i)
                                  ? (gain_r - RAMP_STEP[GAIN_W-1:0]) : gain_i;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            gain_r <= {GAIN_W{1'b0}};                 // 复位静音（安全态）
        end else if (sample_tick_i) begin
            if (ramp_up)
                gain_r <= gain_up_v;
            else if (ramp_dn)
                gain_r <= gain_dn_v;
            // ramp_done ⇒ 保持（⛔ 不是漏写）
        end
    end

    // ── 乘法 + 定标 + 饱和（当拍算完，零延迟）──────────────────────────────
    //   ⭐ 中间位宽 40 bit：signed 24 × unsigned 16，结果 signed
    //   定标：Q1.15 ⇒ 右移 15 位（`>>>` 算术移位，保留符号）
    localparam integer PROD_W = SAMPLE_W + GAIN_W;    // 40

    wire signed [PROD_W-1:0] prod = sample_i * $signed({1'b0, gain_r});
    wire signed [PROD_W-1:0] scaled = prod >>> (GAIN_W - 1);   // >> 15

    // ⭐ 溢出判据（K-101 标准写法：逐位判断，⛔ 无 signed 比较）
    //   正数溢出 = 符号位 0，而高位区有 1
    //   负数溢出 = 符号位 1，而高位区有 0
    wire over_pos = ~scaled[PROD_W-1] && (|scaled[PROD_W-2 : SAMPLE_W-1]);
    wire over_neg =  scaled[PROD_W-1] && ~(&scaled[PROD_W-2 : SAMPLE_W-1]);

    reg signed [SAMPLE_W-1:0] samp_r;
    always @(*) begin
        if (over_pos)
            samp_r = {1'b0, {(SAMPLE_W-1){1'b1}}};   // +最大（2^(W-1)-1）
        else if (over_neg)
            samp_r = {1'b1, {(SAMPLE_W-1){1'b0}}};   // −最小（−2^(W-1)）
        else
            samp_r = scaled[SAMPLE_W-1:0];
    end

    // ⭐ 零延迟透传 valid（单样本链，⛔ 不反压）
    assign valid_o  = valid_i;
    assign sample_o = samp_r;

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 这些组合会**静默失效**，且现象极难定位
    initial begin
        if (GAIN_W < 2)
            $display("ERROR [master_mix] GAIN_W=%0d 必须 >= 2（Q1.15 至少 1 位整数 + 1 位小数）", GAIN_W);
        if (RAMP_STEP < 1)
            $display("ERROR [master_mix] RAMP_STEP=%0d 必须 >= 1（否则斜坡永不逼近目标 ⇒ 音量卡死）", RAMP_STEP);
        if (SAMPLE_W < 8)
            $display("ERROR [master_mix] SAMPLE_W=%0d 必须 >= 8", SAMPLE_W);
    end

endmodule

`default_nettype wire
