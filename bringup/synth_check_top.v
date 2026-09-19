// ─────────────────────────────────────────────────────────────────────────────
// synth_check_top.v · **合成自检顶层**（`bringup/01-现有代码能验证什么.md` §三-5）
//
// ⭐ 为什么需要它（`K-46` 的教训）：
//    Gowin 对**没有被顶层例化到**的模块**只做语法分析、不做综合**
//    （实测：`tlc5916_driver.sv` 在日志里只有 `Analyzing …`、没有 `Compiling module`）。
//    ⇒ "我把文件加进工程了、构建也过了"**不能**当"它能综合"的证据。
//    本顶层把**所有要检查的模块都例化一遍**（并把输入/输出引到端口，避免被优化掉），
//    用 `-top_module synth_check_top` 跑一次综合，才算真的证明"每个模块都能过工具链"。
//
// ⚠️ 用途与边界：
//    · ✅ 它证明的是"**可综合性**"（语法/结构/资源推断）与"**每个模块的资源占用**"
//      （综合报告的 `<SubModule>` 会按模块列出 Register/Alu/Lut）。
//    · ⛔ 它**不是**功能验证（不做任何断言），也**不是**交付顶层（⛔ 不上板、不进 `rtl/` 的交付路径）。
//    · ⛔ 它不进 `Gowin2026.gprj`（那份工程只放交付路径的模块）；跑它用 `bringup/jishi/` 下的独立工程，
//      或临时把它加进工程并 `set_option -top_module synth_check_top`。
//
// ⚠️ 端口全部用**最简单的 wire**（不带 IO 约束也能综合）：
//    这个顶层只跑 `run syn`（综合），不需要 PnR，所以**不需要 `.cst`**。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module synth_check_top #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer BCLK_DIV       = 16,
    parameter integer MCLK_DIV       = 4,
    parameter integer SAMPLE_W       = 24,
    parameter integer DATA_BITS      = 16,
    parameter integer SLOT_BITS      = 32,
    parameter integer CLK_HZ         = 50_000_000,
    parameter integer DATA_HZ        = 1_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // 激励输入（用于让各模块的输入端口都"有事可做"，避免整块被优化掉）
    input  wire        start,
    input  wire [7:0]  led_data,
    input  wire        outputs_enable,
    input  wire signed [SAMPLE_W-1:0] sample_in,
    input  wire        wavetable_rd_en,
    input  wire [8:0]  wavetable_addr,

    // 时基输出
    output wire        tick_audio,
    output wire        mclk_en,
    output wire        bclk_en,
    output wire        bclk_half_en,
    output wire        lrclk,
    output wire        frame_start,

    // I2S 输出
    output wire        HP_BCK,
    output wire        HP_WS,
    output wire        HP_DIN,

    // TLC5916 输出
    output wire        tlc_clk,
    output wire        tlc_sdi,
    output wire        tlc_le,
    output wire        tlc_oe_n,
    output wire        tlc_busy,
    output wire        tlc_done,

    // W1-2 wavetable pROM outputs. Keeping these at the top-level prevents
    // synthesis from pruning the ROM and makes its resource use observable.
    output wire signed [15:0] wavetable_sample,
    output wire               wavetable_valid,

    // 观测用（把内部信号引出来，防优化 + 方便看资源）
    output wire [31:0] obs
);

    // ── L0 复位同步（R-08）──────────────────────────────────────
    wire rst_n_sync;
    rst_sync #(.STAGES(2)) u_rst_sync (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst_n_sync  (rst_n_sync)
    );

    // ── ⭐ L0b 外部异步输入同步（K-62）──────────────────────────
    //    SPI 三线 + 按键：逐位同步后再用（防亚稳态）。
    wire [3:0] sync_probe;
    sync_input #(.W(4), .STAGES(2)) u_sync_in (
        .clk       (clk),
        .rst_n     (rst_n_sync),
        .async_in  ({start, outputs_enable, led_data[1], led_data[0]}),
        .sync_out  (sync_probe)
    );

    // ── L1 时基 ──────────────────────────────────────────────────
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

    // ── L2 I2S 发送 ──────────────────────────────────────────────
    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (SLOT_BITS),
        .JUSTIFY   (1),
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_i2s_tx (
        .clk          (clk),
        .rst_n        (rst_n),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_in),
        .sample_r     (sample_in),
        .HP_BCK       (HP_BCK),
        .HP_WS        (HP_WS),
        .HP_DIN       (HP_DIN)
    );

    // ── L9 TLC5916 LED 驱动 ──────────────────────────────────────
    tlc5916_driver #(
        .CLK_HZ    (CLK_HZ),
        .DATA_HZ   (DATA_HZ),
        .OE_STABLE (25)          // K-57: 25 clk @50MHz = 500 ns, meets datasheet tw(OE) >= 500 ns
    ) u_tlc (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .led_data       (led_data),
        .outputs_enable (outputs_enable),
        .tlc_clk        (tlc_clk),
        .tlc_sdi        (tlc_sdi),
        .tlc_le         (tlc_le),
        .tlc_oe_n       (tlc_oe_n),
        .busy           (tlc_busy),
        .done           (tlc_done)
    );

    // -- W1-2 Gowin pROM wavetable -------------------------------------------
    // The default (non-WAVETABLE_BEHAVIORAL) path instantiates the generated
    // wavetable_sine_rom_ip module, so this synthesis-only project verifies the
    // real vendor primitive and its initialization data.
    wavetable_bank u_wavetable_bank (
        .clk_i    (clk),
        .rst_n_i  (rst_n_sync),
        .rd_en_i  (wavetable_rd_en),
        .addr_i   (wavetable_addr),
        .sample_o (wavetable_sample),
        .valid_o  (wavetable_valid)
    );

    // 把若干内部信号汇成一个观测字（防止综合器把"只被观测"的逻辑剪掉）
    assign obs = {16'd0, wavetable_sample}
               ^ {24'd0, led_data}
               ^ {28'd0, tlc_busy, tlc_done, HP_DIN, lrclk}
               ^ {28'd0, sync_probe}
               ^ {31'd0, wavetable_valid};

endmodule
