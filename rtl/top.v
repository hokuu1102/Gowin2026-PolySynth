// ─────────────────────────────────────────────────────────────────────────────
// top.v · L11 唯一顶层（**M0 范围**：时基 + 安全态）
//
// 本版只做 M0 需要的东西，刻意最小：
//   ① `clk_gen` 产生全部节拍     ② `i2s_tx` 把样点送到板载 DAC
//   ③ **安全态**：`PA_EN_n = 1`（功放关断）、无窄脉冲
//   ④ ⭐ **板级"活体见证"**：一个心跳 LED —— 系统时钟留在板载域，
//      即使别的模块出问题，**心跳仍活着 ⇒ 故障可观测**（上一个项目踩过"全设计换 PLL 时钟后板子全死、
//      连 UART 都没输出"的坑，见 `files/20-代码/已知问题与风险清单.md` `K-41` / 经验库 `L31`）
//
// ⭐ 引脚全部来自**官方 60K 引脚约束**（`files/开发板原理图/tang_mega_60K_pins.cst`，本地、被 gitignore）：
//    `clk=V22`(LVCMOS33) `rst_n=AA13`(LVCMOS15/PULL_UP)
//    `HP_BCK=Y17` `HP_WS=AB17` `HP_DIN=AA16` `PA_EN_n=AB16`（⛔ 低有效）
//    `led_heartbeat=LEDs[0]=T18`（⚠️ 与 `SDRAM1_D6`/PMOD 复用，本设计不用 SDRAM）
//
// ⚠️ 复位：**同步复位、低有效**（`files/20-代码/W3接口冻结表.md` §〇 约定 2）。
//    ⚠️ 但同步复位意味着**上电到第一个时钟沿之间寄存器是未定义的** —— 对 `PA_EN_n` 这种
//    "必须上电就安全"的脚，靠的是**引脚上拉**：`.cst` 里给 `PA_EN_n` 设 `PULL_MODE=UP`
//    ⇒ FPGA **配置期间**它被上拉为高 = 功放关断（官方例程同样这么做）。
//
// ⛔ 本版**还没有**（按第一周范围，属后续任务）：
//    · ⚠️ **结构上还没按"三个包顶层"接**：`files/20-代码/代码总览图.md` 的最终形态是
//      `top.v` → `w3a_top` / `w3b_top` / `w3c_top`。本版 `w3c_top` 还不存在，
//      所以**直接例化 `i2s_tx`**；等 `w3c_top` 落地后改成例化包顶层即可（M0 判据不受影响）
//    · `test_mode` 测试音源（T20 / 乙）—— 现在 `i2s_tx` 送的是**静音 0**，所以**上板听不到声音**
//    · `note_manager` / `voice` / `mixer`（T8~T10 / 乙）
//    · `adc_spi_master` / `chan_scan`（T11/T12 / 丙）· LED 驱动 `tlc5916`（T5 / 丙）
//      ⇒ M0 判据里的 `OE_n=1 无窄脉冲` 那一条要等 `T5` 落地后再接进顶层（⛔ 不凭空编引脚）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module top #(
    // 0 = 功放保持关断（**M0 安全态**）；1 = 复位释放并等待 `PA_ON_DELAY` 后开功放
    parameter integer PA_ON_AFTER_RESET = 0,
    // 开功放前的等待周期数（避免上电"啪"一声；默认 ~21 ms @50 MHz）
    // ⚠️ 用【无位宽】字面量：`20'd1_048_576` 会被截成 20 位 ⇒ 变成 0（2^20 需要 21 位）
    parameter integer PA_ON_DELAY       = 1_048_576,
    // 心跳 LED 翻转周期（clk 数；默认 0.5 s @50 MHz。tb 会传小值以便快速验证）
    parameter integer HEARTBEAT_DIV     = 25_000_000,
    // 与 `clk_gen` / `i2s_tx` 保持一致的音频参数
    parameter integer SAMPLE_W          = 24,
    parameter integer DATA_BITS         = 16
) (
    input  wire clk,             // V22 · 50 MHz
    input  wire rst_n,           // AA13 · 低有效（同步复位）

    // ── 音频（板载 DAC = PT8211-S，⛔ 不需要 MCLK）──────────────────
    output wire HP_BCK,          // Y17 · 位时钟 3.125 MHz（= 64 × fs）
    output wire HP_WS,           // AB17 · 帧时钟 48.828125 kHz（低 = 左）
    output wire HP_DIN,          // AA16 · 串行数据（LSBJ 右对齐）
    output wire PA_EN_n,         // AB16 · ⭐ 功放使能，**低有效**；安全态 = 1

    // ── 板级活体见证 ────────────────────────────────────────────────
    output wire led_heartbeat    // LEDs[0] = T18
);

    // ── ⭐ R-08：外部复位先同步（异步输入 → 同步释放）──────────────────
    //    `rst_n` 来自板上按键，是**异步**输入；直接当同步复位分发，可能让不同 FF
    //    在释放沿采到不同值（一部分复位、一部分没复位，且各模块互相不一致）。
    //    `rst_sync` 把它过两级 FF ⇒ 释放沿在全设计里**严格同一个时钟沿**。
    //    ⚠️ 代价：复位生效晚 2 拍（40 ns），对本设计无影响。
    //    ⛔ 注意它**不**去抖按键抖动（那是 `debounce`/T14 的事）。
    wire rst_n_sync;
    rst_sync #(.STAGES(2)) u_rst_sync (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst_n_sync  (rst_n_sync)
    );

    // ── 时基 ────────────────────────────────────────────────────────
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;

    clk_gen #(
        .CLK_PER_SAMPLE (1024),   // fs = 50 MHz ÷ 1024 = 48.828125 kHz
        .BCLK_DIV       (16),     // BCLK = 3.125 MHz（= 64 × fs）
        .MCLK_DIV       (4)       // MCLK = 12.5 MHz（板载 DAC 不用，留作观测）
    ) u_clk_gen (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .tick_audio   (tick_audio),
        .mclk_en      (mclk_en),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .lrclk        (lrclk),
        .frame_start  (frame_start)
    );

    // ── 音频源：⛔ 本版是**静音**（T8~T10 接进来之前）────────────────
    //    ⚠️ 送单声道（左右同一路）—— 我们 `audio_t` 就是单声道，W3c 负责复制到两声道
    wire signed [SAMPLE_W-1:0] sample_mono = {SAMPLE_W{1'b0}};

    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (32),          // 每声道 32 个 BCK（冻结口径 64 × fs）
        .JUSTIFY   (1),           // ⭐ LSBJ 右对齐（PT8211；`K-39` 已结案）
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_i2s_tx (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_mono),
        .sample_r     (sample_mono),
        .HP_BCK       (HP_BCK),
        .HP_WS        (HP_WS),
        .HP_DIN       (HP_DIN)
    );

    // ── ⭐⭐ 安全态：功放使能（低有效）—— 但**不是普通使能**！──────────────
    //   🔴 **2026-09-17 查 `NS4263` 手册原件后的重大发现**：
    //     板载功放 `NS4263` 的 `SD` 脚（= 我们的 `PA_EN_n`）是**"一线脉冲控制"**，
    //     ⛔ **不是简单的使能电平** —— 它靠**下降沿的个数**决定工作模式。
    //     手册 §10.1 原文的模式表：
    //       | `SD`                        | `HP-IN` | 工作模式            |
    //       | **初始化低 或 一个下降沿**   | 逻辑低   | **AB 类，桥式输出**  | ← ⭐ 我们要的
    //       | **连续两个下降沿**           | 逻辑低   | **D 类，桥式输出**   | ← ⚠️ 音色/EMI 不同
    //       | 低                          | 逻辑高   | AB 类，单端（耳机）  |
    //       | **高（>100 µs）**            | 低/高    | **低功耗关断**       |
    //     ⚠️⚠️ 而且手册电气特性表给了 `THI SD 高电平时间 1~12 µs` / `TLO SD 低电平时间 1~12 µs`
    //       ⇒ **高/低电平的持续时间也在被计数** —— 与 `TLC5916` 的 Special Mode 是**同类陷阱**。
    //
    //   ⭐ 对本设计的两条要求（**这就是本段代码存在的理由**）：
    //     ① **上电到稳态只允许出现恰好 1 个下降沿**（= 进 AB 类）。
    //        ⛔ 绝不能让"复位/抖动"产生**第 2 个**下降沿（那会切到 **D 类**）。
    //        ⇒ 本模块的做法：`PA_ON_AFTER_RESET=0` 时**永远输出高**（0 个下降沿 = 关断，安全）；
    //          置 1 时**只在复位释放后延时一次**拉低（**恰好 1 个下降沿**）。
    //     ② ⭐ **关断要走"高电平 > 100 µs"这条路**（手册：高 >100 µs = 低功耗关断），
    //        ⛔ 而不是"再给一个下降沿"。
    //     ⚠️ 代价与现状：M0 安全态是"永久关断"，所以**当前不会有任何下降沿**；
    //        等真正开功放（`PA_ON_AFTER_RESET=1`）时才会有那**唯一**一个下降沿。
    //     ⛔ 不要为了"关断功放"把 `pa_en_n_r` 再拉低一次 —— 那会变成 D 类。
    reg pa_en_n_r;

    generate
        if (PA_ON_AFTER_RESET == 0) begin : g_pa_off
            // M0 安全态：**永远关断**（0 个下降沿；无窄脉冲、无上电"啪"声）
            always @(posedge clk) begin
                if (!rst_n_sync) pa_en_n_r <= 1'b1;
                else             pa_en_n_r <= 1'b1;
            end
        end else begin : g_pa_on
            // ⭐ **一次性**延时开功放：复位释放后等 `PA_ON_DELAY` 拍，然后**永久保持低**
            //    ⇒ 全程**恰好 1 个下降沿** ⇒ NS4263 进 **AB 类桥式输出**（我们要的）。
            //    ⚠️ `pa_cnt` 位宽必须**够装下 `PA_ON_DELAY`**（原来 24 位，>16.7M 会永不到 ⇒ R-16）。
            //       这里用 `$clog2` 自动算宽度。
            localparam integer PA_CNT_W = (PA_ON_DELAY < 2) ? 1 : $clog2(PA_ON_DELAY + 1);
            reg [PA_CNT_W-1:0] pa_cnt;
            reg                pa_done;      // ⭐ 已开过 ⇒ 之后**永不再变**（保证只有 1 个下降沿）
            always @(posedge clk) begin
                if (!rst_n_sync) begin
                    pa_cnt    <= {PA_CNT_W{1'b0}};
                    pa_done   <= 1'b0;
                    pa_en_n_r <= 1'b1;              // ⭐ 复位期间关断（高）
                end else if (!pa_done) begin
                    if (pa_cnt < PA_ON_DELAY[PA_CNT_W-1:0]) begin
                        pa_cnt    <= pa_cnt + 1'b1;
                        pa_en_n_r <= 1'b1;          // ⭐ 计时期间保持关断（高）
                    end else begin
                        pa_done   <= 1'b1;          // ⭐ 锁死：这是**唯一**的下降沿
                        pa_en_n_r <= 1'b0;          // 开功放（1→0，恰好 1 个下降沿）
                    end
                end
                // ⚠️ `pa_done` 之后**不再有任何赋值** ⇒ `pa_en_n_r` 永久保持 0
                //    （⛔ 不要加"关断"分支：那会产生第 2 个下降沿 ⇒ D 类）
            end
        end
    endgenerate

    assign PA_EN_n = pa_en_n_r;

    // ── 心跳 LED（活体见证）─────────────────────────────────────────
    reg [31:0] hb_cnt;
    reg        hb;

    always @(posedge clk) begin
        if (!rst_n_sync) begin
            hb_cnt <= 32'd0;
            hb     <= 1'b0;
        end else if (hb_cnt >= HEARTBEAT_DIV - 1) begin
            hb_cnt <= 32'd0;
            hb     <= ~hb;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
        end
    end

    assign led_heartbeat = hb;

endmodule
