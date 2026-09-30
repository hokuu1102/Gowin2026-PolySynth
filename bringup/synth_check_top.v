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

    // ── ⭐ T54 · note_manager（W3b voice 分配）──────────────────────────────
    //    ⭐ 为什么要在这里例化：Gowin 只综合**被顶层例化到**的模块（`K-46`），
    //       只把文件登记进工程 ⇒ 日志里只有 "Analyzing"、没有 "Compiling module"
    //       ⇒ ⛔ **不是可综合性的证据**（`K-91` 就是这么抓到 `calib` 被整块丢弃的）。
    input  wire        nm_note_valid,
    input  wire [3:0]  nm_note_axis,
    input  wire [31:0] nm_note_phase_inc,
    input  wire [7:0]  nm_note_velocity,
    input  wire [1:0]  nm_note_kind,
    input  wire        nm_vel_upd_valid,
    input  wire [3:0]  nm_vel_upd_axis,
    input  wire [7:0]  nm_vel_upd_value,
    input  wire        nm_pitch_upd_valid,
    input  wire [3:0]  nm_pitch_upd_axis,
    input  wire [31:0] nm_pitch_upd_value,
    input  wire [1:0]  nm_default_timbre,
    output wire [POLY_TARGET-1:0]           nm_voice_gate,
    output wire [POLY_TARGET-1:0]           nm_voice_active,
    output wire [POLY_TARGET*4-1:0]         nm_voice_axis,
    output wire [POLY_TARGET*32-1:0]        nm_voice_phase_inc,
    output wire [POLY_TARGET*8-1:0]         nm_voice_velocity,
    output wire [POLY_TARGET*2-1:0]         nm_voice_timbre,
    output wire [POLY_TARGET*16-1:0]        nm_voice_age,
    output wire                             nm_alloc_valid,
    output wire [4:0]                       nm_alloc_voice,

    // ⭐⭐ K-106: event-queue overflow observability (sticky + saturating count).
    //    ⚠️ `nm_event_lost_clr` is a top-level INPUT, not a constant -- K-96.
    input  wire                             nm_event_lost_clr,
    output wire                             nm_event_lost,
    output wire [7:0]                       nm_event_lost_cnt,

    // ── ⭐ T55 · oscillator_bank（64 路独立振荡器 —— 评分主体）──────────────
    //    ⭐ 这里例化它的**关键目的之一**是：综合报告里应当能数出
    //       **64 份相位寄存器**（`K-83`/`K-84`：评委要翻代码/报告确认"独立"）。
    //
    //    ⚠️⚠️ 2026-09-21 实测踩坑（`K-96`）：
    //       我第一版把 `voice_active_i` 写死成"只有 voice0 活跃"
    //       （`{{(POLY_TARGET-1){1'b0}}, 1'b1}`）⇒ ⭐ **综合器把 63 个未激活 lane
    //       的相位寄存器整块优化掉了**（因为它们恒等于复位值、永不改变）
    //       ⇒ 报告里只剩 **1069** 个寄存器（64 lane × 32 bit 的相位就要 2048）
    //       ⇒ 🔴 **"64 个独立振荡器"这条评分证据当场消失**。
    //    ⇒ ⭐ 修法：**把 `voice_active_i` 引到顶层输入**（⛔ 不写常量），
    //       让综合器**无法常量折叠** ⇒ 64 份相位寄存器必须全部保留。
    //       📌 教训：**"为了自检方便"写死的常量，会把要被证明的电路优化掉。**
    input  wire        ob_test_mode,
    input  wire [POLY_TARGET-1:0]      ob_voice_active,
    input  wire [POLY_TARGET*32-1:0]   ob_base_phase_inc,
    input  wire [POLY_TARGET*2-1:0]    ob_test_lane_active,
    output wire [POLY_TARGET*2*16-1:0] ob_sample_bus,
    output wire        ob_valid,
    output wire [31:0] ob_phase_dbg,

    // ── ⭐ T56 · tdm_render_mixer（TDM 共享乘法器 + 饱和）──────────────────
    //    ⭐ 关键判据：综合报告里 `MULTALU27X18`（DSP）**只应增加 1 个** ——
    //       这正是"TDM 共享乘法器"的证明（`K-83`：60K 只有 118 个 DSP）。
    input  wire        trm_start,
    input  wire [POLY_TARGET*16-1:0] trm_env_level,
    output wire        trm_valid,
    output wire signed [23:0] trm_sample,
    output wire        trm_fault,

    // ── ⭐ T32 · beat_gen（音乐时钟：节拍器/鼓机/Looper 的共用底座）──────────
    //    ⭐ 为什么要在这里例化：Gowin 只综合**被顶层例化到**的模块（`K-46`）；
    //       只把文件登记进工程 ⇒ 日志里只有 "Analyzing" ⇒ ⛔ 不是可综合性证据
    //       （`K-91` 就是这么抓到 `calib` 被整块丢弃的）。
    //    ⚠️ `run` / `pos_reset` / `tick_inc` **引到顶层输入**，⛔ 不写常量 ——
    //       写常量会被常量折叠（`K-96` 的教训：为了自检方便写死的常量，
    //       会把"要被证明的电路"优化掉）。
    input  wire        bg_run,
    input  wire        bg_pos_reset,
    input  wire [31:0] bg_tick_inc,
    output wire        bg_tick,
    output wire [15:0] bg_tick_cnt,
    output wire        bg_bar_start,
    output wire        bg_beat,
    output wire        bg_transport,
    output wire [15:0] bg_bar_cnt,
    output wire        bg_wrap,
    // T33b: UART receiver (score download path).  rx is a top-level INPUT so
    // synthesis cannot constant-fold the receiver away (K-96).
    input  wire        uart_rx_pin,
    output wire [7:0]  uart_rx_data,
    output wire        uart_rx_done,

    // ── ⭐ T33 · metronome（节拍器：合成 click 走【事件通路】）──────────────
    //    ⚠️ 输入引到顶层（⛔ 不写常量 —— `K-96`：写死的常量会把要证明的电路折叠掉）。
    //    ⭐ 本顶层没有真 `beat_gen` 拍点时用 `met_beat_force` 强制驱动（仅综合取证用）
    input  wire        met_beat_force,
    output wire        met_evt_valid,
    output wire [3:0]  met_evt_axis,
    output wire [31:0] met_evt_phase_inc,
    output wire [7:0]  met_evt_velocity,
    output wire [15:0] met_beat_cnt,
    output wire [15:0] met_accent_cnt,
    output wire        met_cfg_warn,

    // ── ⭐ T33 · perc_env_bank（打击包络：一击到底，⛔ 不改队友的 envelope_bank）──
    input  wire [3:0]  pe_trigger,
    input  wire [31:0] pe_velocity,
    output wire [63:0] pe_level,
    output wire [3:0]  pe_active,
    output wire [63:0] pe_retrig_cnt,

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

    // ── ⭐ T54 · note_manager（W3b · 32 voice 分配/抢占/释放/参数更新）────────
    //    ⚠️ 这是第二周 C 组「接通出声链」的第一块：`top.v` 原本送静音，
    //       且**所有自动功能（节拍器/鼓机/Looper）都依赖它**。
    //    本例化只为**可综合性取证**（⛔ 不做功能验证 —— 功能由 `tb_note_manager.sv` 管）。
    note_manager #(
        .POLY_TARGET (POLY_TARGET),
        .AXIS_W      (4),
        .PHASE_W     (32),
        .VEL_W       (8),
        .TIMBRE_W    (2),
        .ENV_W       (16),
        .AGE_W       (16),
        .RESERVED_N  (0),
        .DEFAULT_VEL (200)
    ) u_note_manager (
        .clk_i             (clk),
        .rst_n_i           (rst_n_sync),
        .sample_tick_i     (tick_audio),
        .note_valid_i      (nm_note_valid),
        .note_axis_i       (nm_note_axis),
        .note_phase_inc_i  (nm_note_phase_inc),
        .note_velocity_i   (nm_note_velocity),
        .note_kind_i       (nm_note_kind),
        // ⭐ A1：来源标记（⭐ 综合只看结构；功能由 tb 覆盖）⇒ 给确定常数（⛔ 不留 z）
        // ⭐⭐ 2026-09-30：⭐ 位宽 2 → 3（⭐ 与 `note_manager.note_src_i` 同步）✅
        .note_src_i        (3'd0),
        .vel_upd_valid_i   (nm_vel_upd_valid),
        .vel_upd_axis_i    (nm_vel_upd_axis),
        .vel_upd_value_i   (nm_vel_upd_value),
        .pitch_upd_valid_i (nm_pitch_upd_valid),
        .pitch_upd_axis_i  (nm_pitch_upd_axis),
        .pitch_upd_value_i (nm_pitch_upd_value),
        .default_timbre_i  (nm_default_timbre),
        .evt_timbre_valid_i(1'b0),
        .evt_timbre_i      (2'd0),
        // ⚠️ 自检顶层没有真包络 ⇒ 用 0 接（综合只看结构；功能由 tb 覆盖）
        .env_active_i      ({POLY_TARGET{1'b0}}),
        .env_level_i       ({(POLY_TARGET*16){1'b0}}),
        .voice_gate_o      (nm_voice_gate),
        .voice_active_o    (nm_voice_active),
        .voice_releasing_o (),
        .voice_axis_o      (nm_voice_axis),
        .voice_phase_inc_o (nm_voice_phase_inc),
        .voice_velocity_o  (nm_voice_velocity),
        .voice_timbre_o    (nm_voice_timbre),
        .voice_age_o       (nm_voice_age),
        .alloc_valid_o     (nm_alloc_valid),
        .alloc_voice_o     (nm_alloc_voice),
        // ⭐⭐ K-106: event-queue overflow observability.  Brought out to
        // top-level pins (NOT constants) so synthesis cannot constant-fold the
        // detector away -- that is exactly the K-96 / C37 trap.
        .event_lost_o      (nm_event_lost),
        .event_lost_cnt_o  (nm_event_lost_cnt),
        .event_lost_clr_i  (nm_event_lost_clr)
    );

    // ── ⭐ T55 · oscillator_bank（64 路独立振荡器）──────────────────────────
    //    ⚠️ 只为**可综合性 + 资源取证**；功能由 `tb_oscillator_bank.sv` 覆盖。
    //    ⭐ 关键判据：综合报告里能数出 **64 份相位寄存器**（评分主体）。
    oscillator_bank #(
        .POLY_TARGET   (POLY_TARGET),
        .OSC_PER_VOICE (2),
        .PHASE_W       (32),
        .OSC_SAMPLE_W  (16),
        .TIMBRE_N      (4),
        .TIMBRE_W      (2),
        .WT_DEPTH      (512),
        .WT_W          (16),
        .ENABLE_FM     (0),
        .DBG_LANE      (0)
    ) u_oscillator_bank (
        .clk_i              (clk),
        .rst_n_i            (rst_n_sync),
        .sample_tick_i      (tick_audio),
        // ⭐ `K-96`：⛔ **不能写死** —— 必须引到顶层输入，否则未激活的 lane
        //    会被综合器整块优化掉，"64 份相位寄存器"这条评分证据就没了。
        .voice_active_i     (ob_voice_active),
        .base_phase_inc_i   (ob_base_phase_inc),
        .timbre_id_i        (2'd0),
        .vibrato_mod_i      (16'sd0),
        .test_mode_i        (ob_test_mode),
        .test_lane_active_i (ob_test_lane_active),
        .test_phase_inc_i   ({(POLY_TARGET*2*32){1'b0}}),        .fm_cfg_valid_i     (1'b0),
        .fm_ratio_i         (16'd0),
        .fm_index_i         (16'd0),
        .osc_sample_bus_o   (ob_sample_bus),
        .osc_valid_o        (ob_valid),
        .phase_acc_dbg_o    (ob_phase_dbg)
    );

    // ── ⭐ T56 · tdm_render_mixer（TDM 共享乘法器）────────────────────────
    //    ⚠️ `osc_sample_bus_i` / `env_level_i` 接到自检顶层的输入，
    //       ⛔ **不写常量** —— 否则会被常量折叠（`K-96` 的教训）。
    //    ⭐ 判据：DSP 只 +1（共享乘法器），⛔ 不是 +32/+64。
    tdm_render_mixer #(
        .POLY_TARGET         (POLY_TARGET),
        .OSC_PER_VOICE       (2),
        .OSC_SAMPLE_W        (16),
        .ENV_W               (16),
        .SAMPLE_W            (24),
        .CLK_PER_SAMPLE      (1024),
        .RENDER_DEADLINE_CYC (927)
    ) u_tdm_render_mixer (
        .clk_i             (clk),
        .rst_n_i           (rst_n_sync),
        .render_start_i    (trm_start),
        .osc_sample_bus_i  (ob_sample_bus),
        .env_level_i       (trm_env_level),
        .dry_valid_o       (trm_valid),
        .dry_sample_o      (trm_sample),
        .deadline_fault_o  (trm_fault)
    );

    // ── ⭐ T32 · beat_gen（音乐时钟 · PPQN=960 相位累加器）──────────────────
    //    ⚠️ 只为**可综合性**取证（⛔ 不做功能验证 —— 功能由 `tb_beat_gen.sv` 管）。
    //    ⭐ 关键判据：综合报告里应能看到它的相位寄存器 `phase_q[31:0]`
    //       （32 bit 相位累加器 = §1.1 的"和 DDS 同款手法"）。
    beat_gen #(
        .PPQN          (960),
        .BEATS_PER_BAR (4),
        .PHASE_W       (32),
        .TICK_INC_W    (32)
    ) u_beat_gen (
        .clk_i            (clk),
        .rst_n_i          (rst_n_sync),
        .run_i            (bg_run),
        .pos_reset_i      (bg_pos_reset),
        .tick_inc_i       (bg_tick_inc),
        .tick_o           (bg_tick),
        .tick_cnt_o       (bg_tick_cnt),
        .bar_start_o      (bg_bar_start),
        .beat_o           (bg_beat),
        .transport_o      (bg_transport),
        .bar_cnt_o        (bg_bar_cnt),
        .tick_cnt_wrap_o  (bg_wrap)
    );

    // ── ⭐ T33 · metronome（节拍器）────────────────────────────────────────
    //    ⚠️ 只为**可综合性 + 资源**取证（⛔ 功能由 `tb_metronome.sv` 管）。
    //    ⭐ 它接 `beat_gen` 的真实输出 ⇒ ⭐ 顺带证明"节拍器与音乐时钟同拍"这条结构。
    metronome #(
        .AXIS_W      (4),
        .PHASE_W     (32),
        .VEL_W       (8),
        .AXIS_ID     (14),
        .RESERVED_N  (5)
    ) u_metronome (
        .clk_i            (clk),
        .rst_n_i          (rst_n_sync),
        .beat_i           (bg_beat | met_beat_force),
        .bar_start_i      (bg_bar_start),
        .transport_i      (bg_transport),
        .evt_valid_o      (met_evt_valid),
        .evt_axis_o       (met_evt_axis),
        .evt_phase_inc_o  (met_evt_phase_inc),
        .evt_velocity_o   (met_evt_velocity),
        .evt_kind_o       (),
        .beat_cnt_o       (met_beat_cnt),
        .accent_cnt_o     (met_accent_cnt),
        .cfg_warn_o       (met_cfg_warn)
    );

    // ── ⭐ T33 · perc_env_bank（打击包络，一击到底）────────────────────────
    //    ⚠️ `trigger` / `velocity` 引到顶层（⛔ 不写常量 —— `K-96`）。
    perc_env_bank #(
        .N_PERC     (4),
        .ENV_W      (16),
        .VEL_W      (8),
        .DECAY_STEP (67)
    ) u_perc_env_bank (
        .clk_i        (clk),
        .rst_n_i      (rst_n_sync),
        .sample_tick_i(tick_audio),
        .trigger_i    (pe_trigger),
        .velocity_i   (pe_velocity),
        .level_o      (pe_level),
        .active_o     (pe_active),
        .busy_o       (),
        .retrig_cnt_o (pe_retrig_cnt)
    );

    // 把若干内部信号汇成一个观测字（防止综合器把"只被观测"的逻辑剪掉）
    // ---- T33b: UART receiver (8N1 @ 115200 => BAUD_DIV=434) ----------------
    uart_rx #(
        .BAUD_DIV (434)
    ) u_uart_rx (
        .clk_i     (clk),
        .rst_n_i   (rst_n_sync),
        .rx_i      (uart_rx_pin),
        .rx_data_o (uart_rx_data),
        .rx_done_o (uart_rx_done)
    );


    assign obs = {16'd0, wavetable_sample}
               ^ {24'd0, led_data}
               ^ {28'd0, tlc_busy, tlc_done, HP_DIN, lrclk}
               ^ {28'd0, sync_probe}
               ^ {31'd0, wavetable_valid}
               ^ {29'd0, adc_sample_data0}
               ^ {29'd0, cal_out_val}
               ^ {28'd0, key_down}
               ^ {27'd0, nm_alloc_voice}
               ^ {31'd0, nm_voice_gate}
               ^ ob_sample_bus[31:0]
               ^ ob_phase_dbg
               ^ trm_sample
               ^ {16'd0, bg_tick_cnt}            // ⭐ T32 beat_gen
               ^ {28'd0, bg_tick, bg_bar_start, bg_beat, bg_wrap}
               ^ {16'd0, bg_bar_cnt}
               ^ {24'd0, uart_rx_data}                  // T33b uart_rx
               ^ {31'd0, uart_rx_done}
               ^ {23'd0, nm_event_lost_cnt}      // ⭐ K-106 overflow observability
               ^ {31'd0, nm_event_lost}
               ^ {29'd0, met_evt_axis, met_evt_valid}   // ⭐ T33 metronome
               ^ met_evt_phase_inc
               ^ {24'd0, met_evt_velocity}
               ^ {16'd0, met_beat_cnt}
               ^ {16'd0, met_accent_cnt}
               ^ {31'd0, met_cfg_warn}
               ^ pe_level[31:0]                          // ⭐ T33 perc_env_bank
               ^ {28'd0, pe_active}
               ^ pe_retrig_cnt[31:0];

endmodule
