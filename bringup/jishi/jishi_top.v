// ─────────────────────────────────────────────────────────────────────────────
// jishi_top.v · **基石板上板验证顶层**（`bringup/jishi/`）
//
// ⭐ 目的：用**手上已有的基石板**验证当前代码的**最底层三件事**，不必等 Dock/右手板：
//     ① **时钟真的通** ② **复位真的对** ③ **I2S 三线真的在动**（能在示波器/逻辑分析仪上看到）
//     ⛔ 它**不是**交付顶层 —— 交付顶层是 `rtl/top.v`（Dock 用）。
//
// ⭐⭐ **为什么另起一个顶层，而不是直接用 `rtl/top.v`**（这是本文件存在的核心理由）：
//     `rtl/top.v` 的引脚是按 **Dock** 写的（`clk=V22`/`rst_n=AA13`/`HP_*=Y17…`），
//     而基石板的引脚**完全不同**（`clk=F13`/`rst_n=D1`/…）⇒
//     ⛔ **引脚结论不能照搬**（两板同为 PG484 封装，但**布线与引出不同**）。
//     ⇒ 所以做法是：**逻辑一行不改**，只换"顶层外壳 + 引脚约束"。
//       本文件就是那个"外壳"，它把 `clk_gen` + `i2s_tx` 按**基石板的引脚**引出来。
//
// ⚠️⚠️ **不破坏正式代码**（用户的硬要求）：
//     · ⛔ 本文件**不进** `Gowin2026.gprj`、不进 `rtl/`、不改 `constr/top.cst`
//     · ⛔ 不进 `sim/tb_all.ps1` 的回归集（它是上板用，不是仿真判据）
//     · ✅ 它是一个**独立的 Gowin 工程**（`bringup/jishi/jishi.gprj`），
//       用**相对路径**引用 `rtl/` 里的同一份代码 ⇒ ⭐ **改了 `rtl/` 它自动跟着变**，
//       不需要维护两份逻辑（只维护两份"引脚表"）。
//
// ⭐ 与正式顶层的**唯一差别**：引脚名/球位、以及**多了一个蜂鸣器静音脚**（见下）。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module jishi_top #(
    // ⭐ 与 `rtl/top.v` 保持同名的音频参数（口径一致，便于对比）
    parameter integer SAMPLE_W      = 24,
    parameter integer DATA_BITS     = 16,
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer BCLK_DIV      = 16,
    parameter integer MCLK_DIV      = 4,
    // ⭐ 上板验证用：心跳分频（默认 0.5 s @50 MHz）
    parameter integer HEARTBEAT_DIV = 25_000_000,
    // ⭐ 上板验证用：是否输出"测试音"（0 = 静音，只验时序；1 = 输出方波样点，便于示波器看）
    //    ⚠️ 这不是正式功能，只为"板子上能不能看见东西"服务。
    parameter integer TEST_TONE     = 1
) (
    input  wire clk,             // ⭐ 基石板 50 MHz 晶振
    input  wire rst_n,           // ⭐ 基石板复位按键（低有效）

    // ── I2S 三线（给示波器/逻辑分析仪看）────────────────────────────
    output wire HP_BCK,          // 位时钟 3.125 MHz
    output wire HP_WS,           // 帧时钟 48.828125 kHz
    output wire HP_DIN,          // 串行数据（LSBJ 右对齐）

    // ── 板级活体见证 ────────────────────────────────────────────────
    output wire led_heartbeat,   // ⭐ 心跳 LED：不快闪就说明时钟/复位没通
    output wire beep             // ⭐⭐ **蜂鸣器静音脚**（槽点见下）
);

    // ── ⭐⭐ 蜂鸣器：**必须约束并驱动低**，否则它会一直叫 ──────────────────
    //   ⭐ 证据（两条独立来源，与 `ADDA/beep_off/` 的结论一致）：
    //     ① 官方 9 个基石板例程**全部** `IO_LOC "Beep" A13;` 且源码里 `assign Beep = 1'b0;`
    //     ② 扩展板原理图第 7 页：`BEEP` 网络经 NPN（Q16）低边驱动 ⇒ **基极给高才导通** ⇒
    //        **高 = 响、低 = 静音**
    //   ⚠️⚠️ 光"驱动低"**不够**：FPGA 在**上电未配置完成/复位期间引脚是高阻**，
    //     此时蜂鸣器脚悬空 ⇒ NPN 基极可能被漏电/干扰顶起来 ⇒ **上电瞬间叫一声甚至持续叫**。
    //     ⇒ ⭐ 所以 `.cst` 里还要给这个脚 **`PULL_MODE=DOWN`**（把那段窗口也钉在低电平）。
    //       ⚠️ 官方例程用的是 `NONE`（它们不关心上电那一下）；我们**特意加 DOWN**。
    //   ⛔ 不要把这里改成 1'b1 —— 那是"一直响"。
    //   📌 注意：`A18` **不是**蜂鸣器脚（扩展板里的 `A18` 是 PCIe 金手指的连接器脚标号，
    //      而 FPGA 的 `A18` 在官方 OV5640 例程里是 `cam_vsync`）—— 别照字面接。
    assign beep = 1'b0;

    // ── ⭐ R-08：外部复位先同步（与 `rtl/top.v` 完全一致的做法）──────────
    //   `rst_n` 来自按键，是**异步**输入；先过两级 FF ⇒ 释放沿在全设计里严格对齐。
    wire rst_n_sync;
    rst_sync #(.STAGES(2)) u_rst_sync (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst_n_sync  (rst_n_sync)
    );

    // ── 时基（与正式顶层同一套参数）─────────────────────────────────────
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;

    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
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

    // ── ⭐ 测试音发生：给 I2S 送一个"能看见"的方波样点 ──────────────────
    //   为什么需要：⛔ 正式顶层送的是**静音**（全 0）⇒ 上板只能看到 BCK/WS 在动、
    //   `DIN` 是一条直线 ⇒ ⚠️ "DIN 到底通没通"**分不出来**。
    //   ⇒ 这里送一个慢速方波（每 N 帧翻转一次），让 `DIN` **肉眼/示波器可见地在动**。
    //   ⚠️ 它不是正式功能，只是"看得见"的探针；`TEST_TONE=0` 时退回静音。
    //   频率：每 `TONE_HALF` 帧翻转一次 ⇒ 方波频率 = fs / (2 × TONE_HALF)
    //     取 TONE_HALF = 16 ⇒ 48828.125 / 32 ≈ 1526 Hz（可听，且示波器上好触发）
    localparam integer TONE_HALF = 16;
    // ⭐ 幅度取 **1/4 满量程**（不是满量程）：① 示波器好看且不削顶
    //   ② 若将来接 DAC→功放，1/4 幅度不会把喇叭推爆（上板调试要留余量）
    localparam signed [SAMPLE_W-1:0] TONE_HI =  (1 <<< (SAMPLE_W - 2));   // +1/4 满量程
    localparam signed [SAMPLE_W-1:0] TONE_LO = -(1 <<< (SAMPLE_W - 2));   // −1/4 满量程

    reg signed [SAMPLE_W-1:0] sample_mono;
    reg [15:0] tone_cnt;
    reg        tone_hi;           // ⭐ 当前处在方波的高半周还是低半周

    always @(posedge clk) begin
        if (!rst_n_sync) begin
            sample_mono <= {SAMPLE_W{1'b0}};
            tone_cnt    <= 16'd0;
            tone_hi     <= 1'b0;
        end else if (tick_audio) begin
            if (tone_cnt >= TONE_HALF - 1) begin
                tone_cnt    <= 16'd0;
                tone_hi     <= ~tone_hi;                       // ⭐ 每 TONE_HALF 帧翻转
                sample_mono <= tone_hi ? TONE_LO : TONE_HI;    // 用"翻转前"的值 ⇒ 与翻转同拍生效
            end else begin
                tone_cnt    <= tone_cnt + 16'd1;
                sample_mono <= tone_hi ? TONE_HI : TONE_LO;
            end
        end
    end

    // ⚠️ `TEST_TONE=0` 时强制静音（用 generate 保持可综合、且不引入新逻辑）
    wire signed [SAMPLE_W-1:0] sample_to_i2s;
    assign sample_to_i2s = (TEST_TONE != 0) ? sample_mono : {SAMPLE_W{1'b0}};

    // ── I2S 发送（⭐ 参数与正式顶层完全一致：LSBJ 右对齐、PT8211）──────────
    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (32),
        .JUSTIFY   (1),           // LSBJ 右对齐（PT8211；K-39 已结案）
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_i2s_tx (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_to_i2s),
        .sample_r     (sample_to_i2s),
        .HP_BCK       (HP_BCK),
        .HP_WS        (HP_WS),
        .HP_DIN       (HP_DIN)
    );

    // ── 心跳 LED（活体见证）─────────────────────────────────────────────
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
            hb_cnt <= hb_cnt + 32'd1;
        end
    end

    assign led_heartbeat = hb;

endmodule
