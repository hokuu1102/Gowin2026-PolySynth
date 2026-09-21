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
    parameter integer DATA_HZ        = 1_000_000,
    parameter integer POLY_TARGET    = 32
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
    input  wire [POLY_TARGET-1:0] env_gate,
    input  wire [POLY_TARGET*8-1:0] env_velocity,
    input  wire        note_on,
    input  wire        note_off,
    input  wire [31:0] note_inc,

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

    // W1-3 ADSR outputs remain public so all 32 independent state machines
    // survive synthesis and are visible in the hierarchy/resource report.
    output wire [POLY_TARGET*16-1:0] env_level,
    output wire [POLY_TARGET-1:0]    env_active,

    // T10 real single-voice integration path.
    output wire               chain_HP_BCK,
    output wire               chain_HP_WS,
    output wire               chain_HP_DIN,
    output wire               chain_tick_audio,
    output wire signed [23:0] chain_sample,
    output wire               chain_voice_done,
    output wire [31:0]        chain_phase_acc,
    output wire [31:0]        chain_phase_inc,

    // ── ⭐ L8 采集链（T47 / K-90：这三个模块此前不在任何 Gowin 工程里）──────
    //    ⭐ 为什么要在这里例化：Gowin 只综合**被顶层例化到**的模块（K-46）。
    //       只把文件登记进工程 ⇒ 日志里只有 "Analyzing"、没有 "Compiling module"
    //       ⇒ ⛔ **不是可综合性的证据**。本顶层把它们真的接起来才算证明。
    input  wire [2:0]  adc_miso_in,
    input  wire        adc_enable,
    output wire [2:0]  adc_cs_n,
    output wire [2:0]  adc_sclk,
    output wire [2:0]  adc_mosi,
    output wire        adc_sample_valid,
    output wire [2:0]  adc_sample_ch,
    output wire [35:0] adc_sample_data_packed,
    output wire [11:0] adc_sample_data0,
    output wire [11:0] adc_sample_data1,
    output wire [11:0] adc_sample_data2,
    output wire        adc_frame_done,
    output wire [2:0]  adc_fault,

    // calib（单芯片 8 通道口径；本顶层把 adc_farm 的片 0 接到它上面）
    input  wire        cal_tare,
    input  wire        cal_span,
    output wire        cal_busy,
    output wire        cal_err,
    output wire        cal_out_valid,
    output wire [2:0]  cal_out_ch,
    output wire [11:0] cal_out_val,

    // debounce（按键 + EC11；⛔ A/B 不做 ACTIVE_LOW 归一化）
    input  wire [3:0]  key_in,
    input  wire        enc_a,
    input  wire        enc_b,
    input  wire        enc_sw,
    output wire [3:0]  key_level,
    output wire [3:0]  key_down,
    output wire [3:0]  key_up,
    output wire        enc_sw_down,
    output wire        enc_sw_up,
    output wire        enc_cw,
    output wire        enc_ccw,
    output wire        enc_err,

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

    // -- W1-3 independent per-voice ADSR bank -------------------------------
    envelope_bank #(
        .POLY_TARGET (POLY_TARGET)
    ) u_envelope_bank (
        .clk_i         (clk),
        .rst_n_i       (rst_n_sync),
        .sample_tick_i (tick_audio),
        .gate_i        (env_gate),
        .velocity_i    (env_velocity),
        .env_level_o   (env_level),
        .env_active_o  (env_active)
    );

    // -- T10 DDS + pROM + ADSR + amplitude scaling + I2S --------------------
    voice_i2s_chain u_voice_i2s_chain (
        .clk_i           (clk),
        .rst_n_i         (rst_n_sync),
        .note_on_i       (note_on),
        .note_off_i      (note_off),
        .note_inc_i      (note_inc),
        .HP_BCK          (chain_HP_BCK),
        .HP_WS           (chain_HP_WS),
        .HP_DIN          (chain_HP_DIN),
        .tick_audio_o    (chain_tick_audio),
        .sample_dbg_o    (chain_sample),
        .voice_done_o    (chain_voice_done),
        .phase_acc_dbg_o (chain_phase_acc),
        .phase_inc_dbg_o (chain_phase_inc)
    );

    // ── ⭐ L8 采集链（T47 / K-90）─────────────────────────────────────────────
    //    ⚠️ 此前 `adc_farm`/`calib`/`debounce` **不在任何 Gowin 工程里**
    //       ⇒ 它们**只有仿真证据、没有综合证据**。本节就是补这个缺口。

    // ⭐ 多片 MCP3208 并行总控（N_ADC=3：三片各自 CS/MISO，SCLK/MOSI 同源扇出）
    adc_farm #(
        .N_ADC (3)
    ) u_adc_farm (
        .clk                (clk),
        .rst_n              (rst_n_sync),
        .enable             (adc_enable),
        .adc_cs_n           (adc_cs_n),
        .adc_sclk           (adc_sclk),
        .adc_mosi           (adc_mosi),
        .adc_miso           (adc_miso_in),
        .sample_valid       (adc_sample_valid),
        .sample_ch          (adc_sample_ch),
        .sample_data_packed (adc_sample_data_packed),
        .sample_data0       (adc_sample_data0),
        .sample_data1       (adc_sample_data1),
        .sample_data2       (adc_sample_data2),
        .frame_done         (adc_frame_done),
        .fault              (adc_fault)
    );

    // ⭐ 逐通道零点/灵敏度标定（接片 0 的采样流；单芯片 8 通道口径）
    calib #(
        .NCH (8)
    ) u_calib (
        .clk       (clk),
        .rst_n     (rst_n_sync),
        .valid     (adc_sample_valid),
        .ch        (adc_sample_ch),
        .raw       (adc_sample_data0),
        .tare      (cal_tare),
        .span      (cal_span),
        .cal_ch    (adc_sample_ch),
        .busy      (cal_busy),
        .err       (cal_err),
        .out_valid (cal_out_valid),
        .out_ch    (cal_out_ch),
        .out_val   (cal_out_val)
    );

    // ⭐ 按键/编码器：按 K-62 先 2 级同步、再去抖
    //    （`debounce` 的端口层面不例化 sync_input，由顶层负责 —— 这里就是那个顶层）
    wire [6:0] key_enc_sync;
    sync_input #(.W(7), .STAGES(2)) u_sync_key (
        .clk      (clk),
        .rst_n    (rst_n_sync),
        .async_in ({enc_sw, enc_b, enc_a, key_in}),
        .sync_out (key_enc_sync)
    );

    debounce #(
        .NKEY (4)
    ) u_debounce (
        .clk        (clk),
        .rst_n      (rst_n_sync),
        .key_in     (key_enc_sync[3:0]),
        .key_level  (key_level),
        .key_down   (key_down),
        .key_up     (key_up),
        .enc_a      (key_enc_sync[4]),
        .enc_b      (key_enc_sync[5]),
        .enc_sw     (key_enc_sync[6]),
        .enc_a_lvl  (),
        .enc_b_lvl  (),
        .enc_sw_lvl (),
        .enc_sw_down(enc_sw_down),
        .enc_sw_up  (enc_sw_up),
        .enc_cw     (enc_cw),
        .enc_ccw    (enc_ccw),
        .enc_state  (),
        .enc_err    (enc_err)
    );

    // 把若干内部信号汇成一个观测字（防止综合器把"只被观测"的逻辑剪掉）
    assign obs = {16'd0, wavetable_sample}
               ^ {24'd0, led_data}
               ^ {28'd0, tlc_busy, tlc_done, HP_DIN, lrclk}
               ^ {28'd0, sync_probe}
               ^ {31'd0, wavetable_valid}
               ^ {29'd0, adc_sample_data0}
               ^ {29'd0, cal_out_val}
               ^ {28'd0, key_down};

endmodule
