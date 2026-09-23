// ─────────────────────────────────────────────────────────────────────────────
// top.v · L11 唯一顶层（**M0 范围**：时基 + 安全态）
//
// 本版只做 M0 需要的东西，刻意最小：
//   ① `clk_gen` 产生全部节拍     ② `i2s_tx` 把样点送到板载 DAC
//   ③ ⭐ **安全态**：`PA_EN_n` 驱动**高**（Console 上是 `SD_MODE`，⚠️ 低 = `Shutdown`）、无窄脉冲
//   ④ ⭐ **板级"活体见证"**：一个心跳 LED —— 系统时钟留在板载域，
//      即使别的模块出问题，**心跳仍活着 ⇒ 故障可观测**（上一个项目踩过"全设计换 PLL 时钟后板子全死、
//      连 UART 都没输出"的坑，见 `files/20-代码/已知问题与风险清单.md` `K-41` / 经验库 `L31`）
//
// ⭐ 引脚全部来自**官方 60K 引脚约束**（`files/开发板原理图/tang_mega_60K_pins.cst`，本地、被 gitignore）：
//    `clk=V22`(LVCMOS33) `rst_n=AA13`(LVCMOS15/PULL_UP)
//    `HP_BCK=Y17` `HP_WS=AB17` `HP_DIN=AA16`
//    🔴 **`PA_EN_n=Y14`**（⚠️ **2026-09-22 换板后改**：⛔ **不是 `AB16`** —— 那是 `USB_TERM_RXDN`）
//       ⚠️ `Y14` 属 **`BANK9` = 1.5 V** ⇒ ⛔ **必须 `LVCMOS15`**；⭐ `PULL_MODE=UP`
//       🔴 它接 **`MAX98357A` 的 `SD_MODE`** ⇒ ⭐ **高 = 出声（Left），低 = `Shutdown`**
//          ⇒ ⭐ **"驱动高"是本设计出声的前提**（⚠️ 旧的"低有效"语义已作废）
//    ⭐ `led_heartbeat=V13`（⚠️ **2026-09-22 换板后改**：⛔ **不是 `T18`** —— 那是 `SDRAM1_D6`）
//
// ⚠️ 复位：**同步复位、低有效**（`files/20-代码/W3接口冻结表.md` §〇 约定 2）。
//    ⚠️ 但同步复位意味着**上电到第一个时钟沿之间寄存器是未定义的** —— 对 `PA_EN_n` 这种
//    "必须上电就是正确电平"的脚，靠的是**引脚上拉**：`.cst` 里给 `PA_EN_n` 设 `PULL_MODE=UP`
//    ⇒ FPGA **配置期间**它被上拉为高，而 ⭐ **高在 Console 上恰好是"出声"那一侧** ⇒ ⭐ **依然是安全态**。
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
    // ⭐⭐ 功放使能策略（`R-16` / `K-42` / `K-61`）—— **默认值已按"交付用途"定**：
    //   · `1`（**默认**）= 复位释放并等待 `PA_ON_DELAY` 后**开功放** ⇒ ⭐ **交付/上板必须用这个**，
    //     否则板载 `NS4263` 永远关断 ⇒ **喇叭与耳机都没声音**，而且**这种"没声音"很难查**
    //     （波形全对、I2S 全对、DAC 也有信号，只是功放被关着）。
    //   · `0` = 功放**永远关断**（0 个下降沿）⇒ ⭐ **这是 M0 的"安全态"验证档**，
    //     由 `tb/top/tb_top_m0.sv` 显式传 `0` 来验"上电不该开功放、不该有窄脉冲"。
    //   📌 为什么默认改成 1：`top.v` 是**交付顶层**，默认值必须让板子**能出声**；
    //     "安全态"是**测试配置**，⛔ 不该当成交付默认值（那等于把"没声音"设成默认行为）。
    parameter integer PA_ON_AFTER_RESET = 1,
    // 开功放前的等待周期数（避免上电"啪"一声；默认 ~21 ms @50 MHz）
    // ⚠️ 用【无位宽】字面量：`20'd1_048_576` 会被截成 20 位 ⇒ 变成 0（2^20 需要 21 位）
    parameter integer PA_ON_DELAY       = 1_048_576,
    // ⭐ 心跳 LED 翻转周期（clk 数；默认 0.5 s @50 MHz。tb 会传小值以便快速验证）
    parameter integer HEARTBEAT_DIV     = 25_000_000,
    // 与 `clk_gen` / `i2s_tx` 保持一致的音频参数
    parameter integer SAMPLE_W          = 24,
    parameter integer DATA_BITS         = 16,
    // ⭐⭐ T57（2026-09-21）：**开机自检音**（⛔ 不依赖任何传感器）
    //   · `1`（**默认**）= 复位后自动起一个 **3 音和弦**（A4 / C#5 / E5）⇒
    //     ⭐ **上板就能听到声音**，用于证明"整条出声链在真硅片上通了"。
    //   · `0` = **完全静音** ⇒ ⭐ 这是 **M0 安全态/静音验证档**，
    //     由 `tb/top/tb_top_m0.sv` 显式传 `0` 来验"静音就是真的静音"。
    //   📌 为什么默认是 1：`top.v` 是**交付顶层**，默认值必须让板子**能出声**；
    //     "静音"是**测试配置**，⛔ 不该当交付默认值（同 `PA_ON_AFTER_RESET` 的 `R-16` 教训）。
    parameter integer DEMO_CHORD_ON     = 1,
    // 与 w3b 链路一致的参数（改这里要同时核对 `POLY_TARGET`）
    parameter integer POLY_TARGET       = 32,
    parameter integer OSC_PER_VOICE     = 2,
    // ⭐ 开机自检音的**起音延时**（clk 数；默认 ≈40 ms @50 MHz）
    //    ⚠️ 提成参数是为了**让 tb 能改小** —— 否则 tb 要跑 200 万拍才能听到音，
    //       仿真会慢到超时（实测 120 s 都不够）。
    parameter integer DEMO_NOTE_DELAY   = 2_000_000
) (
    input  wire clk,             // V22 · 50 MHz
    input  wire rst_n,           // AA13 · 低有效（同步复位）

    // ── 音频（板载 DAC = `MAX98357A`，⛔ 不需要 MCLK）──────────────
    //   ⭐ 2026-09-22 换板 Tang Console 60K：`PT8211`+`NS4263` → `MAX98357A`
    //      （I2S 输入 + 内置 DAC + D 类功放，三合一）
    output wire HP_BCK,          // Y17 · 位时钟 3.125 MHz（= 64 × fs）
    output wire HP_WS,           // AB17 · 帧时钟 48.828125 kHz（低 = 左）
    output wire HP_DIN,          // AA16 · 串行数据（⭐ 标准 I2S 左对齐）
    output wire PA_EN_n,         // 🔴 Y14（⛔ 不是 AB16）· 接 MAX98357A 的 SD_MODE ⇒ ⭐ **高 = 出声**，见下方说明

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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ T57（2026-09-21）· **接通出声链** —— 撤掉静音
    //
    // ⚠️ 为什么这一步是本项目最关键的一次改动：
    //   在此之前 `top.v` 送的是**常量 0**（静音）⇒ ⭐ **板子永远不出声**，
    //   而所有仿真结论（时基、I2S 时序、DAC 帧格式）**全都是对的** ⇒
    //   这种"全绿但没声音"极难定位（同 `R-16` 家族的教训）。
    //
    // ⭐ 链路（与 `代码总览图.md` 的最终形态一致，只是还没有 `w3b_top` 包顶层）：
    //     `note_manager` → `oscillator_bank`(64 lane) → `tdm_render_mixer` → `i2s_tx`
    //
    // ⭐ 时钟关系（全部单时钟域，⛔ 无派生时钟）：
    //    · `tick_audio`（每 1024 clk）驱动 `note_manager` / `oscillator_bank`
    //    · `oscillator_bank` 用 **66 拍** TDM 取回 64 个样本，然后 `osc_valid_o` 拉高一拍
    //    · ⭐ 用 `osc_valid_o` 当 `tdm_render_mixer.render_start_i`
    //      ⇒ mixer 再花 **POLY_TARGET+2 = 34 拍** 算完
    //    ⇒ 合计 **66 + 34 ≈ 100 拍**，远小于 1024 拍预算 ✅（`A6`）
    //
    // ⭐ 开机自检音（`DEMO_CHORD_ON=1`）：复位后自动起 **A4 + C#5 + E5** 三音和弦
    //    ⇒ ⭐ **不依赖任何传感器**就能证明"整条链在真硅片上通了"。
    //    ⚠️ 这只是**验证用**的固定音，⛔ 不是"预录 PCM"（是**实时合成**的三个振荡器）。
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [SAMPLE_W-1:0] sample_mono;

    generate
    if (DEMO_CHORD_ON == 0) begin : g_silent
        // ── M0 安全态/静音档：⛔ 不例化合成链，直接送 0 ──────────────────
        //    ⭐ 为什么**整条链都不例化**而不是"接了但喂 0"：
        //       ① 省资源；② ⭐ **静音就是结构上的静音**，⛔ 不给"某个内部节点
        //       意外产生数据"留任何可能（`tb_top_m0` 的 E 判据要 `HP_DIN` 恒 0）。
        assign sample_mono = {SAMPLE_W{1'b0}};
    end else begin : g_sound
        // ── 出声链 ────────────────────────────────────────────────────────
        wire [POLY_TARGET-1:0]         nm_gate;
        wire [POLY_TARGET-1:0]         nm_active;
        wire [POLY_TARGET*4-1:0]       nm_axis;
        wire [POLY_TARGET*32-1:0]      nm_phase;
        wire [POLY_TARGET*8-1:0]       nm_vel;
        wire [POLY_TARGET*2-1:0]       nm_timbre;
        wire [POLY_TARGET*16-1:0]      nm_age;
        wire                           nm_alloc_valid;
        wire [4:0]                     nm_alloc_voice;

        wire [POLY_TARGET*OSC_PER_VOICE*16-1:0] ob_samples;
        wire                           ob_valid;
        wire [31:0]                    ob_phase_dbg;

        wire                           mx_valid;
        wire signed [SAMPLE_W-1:0]     mx_sample;
        wire                           mx_fault;

        // ⭐ 包络：`envelope_bank` 每 voice 一份 ADSR（与 `note_manager` 的 gate 对接）
        wire [POLY_TARGET*16-1:0]      env_level;
        wire [POLY_TARGET-1:0]         env_active;

        // ── ⭐ 开机自检音（A4+C#5+E5）的驱动信号 ──────────────────────────
        //    ⚠️ 必须**先声明后使用**（Verilog 不允许先用后声明）
        //    ⭐ 相位增量由 `f × 2^32 / fs` 精确算出（fs = 48828.125 Hz）：
        //       A4=440Hz    → 0x024E8ED9
        //       C#5=554.365Hz → 0x02E80E5D
        //       E5=659.255Hz  → 0x0374D64B
        //    ⚠️ `DEMO_NOTE_DELAY` 是顶层参数（tb 可改小以便快速仿真）
        localparam [31:0] INC_A4  = 32'h024E_8ED9;
        localparam [31:0] INC_CS5 = 32'h02E8_0E5D;
        localparam [31:0] INC_E5  = 32'h0374_D64B;

        // ⚠️ 计数器位宽必须够装下 `DEMO_NOTE_DELAY`（⛔ 不要写死 24 位）
        localparam integer DEMO_CW = (DEMO_NOTE_DELAY < 2) ? 1 : $clog2(DEMO_NOTE_DELAY + 1);
        localparam [DEMO_CW-1:0] DEMO_DELAY_V = DEMO_NOTE_DELAY;

        reg [DEMO_CW-1:0] demo_cnt;
        reg        demo_fired;
        reg [1:0]  demo_step;
        reg        demo_note_valid;
        reg [3:0]  demo_note_axis;
        reg [31:0] demo_note_inc;
        reg [7:0]  demo_note_vel;
        reg [1:0]  demo_note_kind;

        envelope_bank #(
            .POLY_TARGET (POLY_TARGET),
            .VEL_W       (8),
            .ENV_W       (16)
        ) u_envelope_bank (
            .clk_i         (clk),
            .rst_n_i       (rst_n_sync),
            .sample_tick_i (tick_audio),
            .gate_i        (nm_gate),
            .velocity_i    (nm_vel),
            .env_level_o   (env_level),
            .env_active_o  (env_active)
        );

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ T33b: musical clock + metronome
        //
        // ⭐ The metronome is NOT a second audio path.  It emits ordinary
        //    note_evt_t events on the SAME path as the fingers do, so there is
        //    zero new audio routing and zero new compliance surface.
        //
        // ⚠️  Scope of THIS step: beat_gen + metronome are instantiated and the
        //     metronome's events reach note_manager.  The tempo is a constant
        //     today; U-7 (see the unfinished-work ledger) will drive
        //     tick_inc_i from tempo events in the score instead.
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 120 BPM at PPQN=960 on a 50 MHz clock:
        //     round(2^32 x 120/60 x 960 / 50e6) = 164927  (verified by hand)
        localparam [31:0] TICK_INC_120BPM = 32'd164927;

        wire        bg_tick;
        wire [15:0] bg_tick_cnt;
        wire        bg_bar_start;
        wire        bg_beat;
        wire        bg_transport;
        wire [15:0] bg_bar_cnt;
        wire        bg_wrap;

        beat_gen #(
            .PPQN          (960),
            .BEATS_PER_BAR (4),
            .PHASE_W       (32),
            .TICK_INC_W    (32)
        ) u_beat_gen (
            .clk_i           (clk),
            .rst_n_i         (rst_n_sync),
            .run_i           (1'b1),            // free-running
            .pos_reset_i     (1'b0),            // no transport seek
            .tick_inc_i      (TICK_INC_120BPM),
            .tick_o          (bg_tick),
            .tick_cnt_o      (bg_tick_cnt),
            .bar_start_o     (bg_bar_start),
            .beat_o          (bg_beat),
            .transport_o     (bg_transport),
            .bar_cnt_o       (bg_bar_cnt),
            .tick_cnt_wrap_o (bg_wrap)
        );

        wire        met_evt_valid;
        wire [3:0]  met_evt_axis;
        wire [31:0] met_evt_inc;
        wire [7:0]  met_evt_vel;
        wire [1:0]  met_evt_kind;
        wire [15:0] met_beat_cnt;
        wire [15:0] met_accent_cnt;
        wire        met_cfg_warn;

        metronome #(
            // ⭐ AXIS_ID must stay >= RESERVED_AXIS (14 = 4'hE) so the event
            //    lands in the reserved pool -- PAIRED with
            //    note_manager.RESERVED_N above.  cfg_warn_o asserts if the two
            //    are inconsistent, so a mismatch is observable rather than
            //    silent (K-106 family).
            .AXIS_W     (4),
            .PHASE_W    (32),
            .VEL_W      (8),
            .AXIS_ID    (14),
            .RESERVED_N (5)
        ) u_metronome (
            .clk_i          (clk),
            .rst_n_i        (rst_n_sync),
            .beat_i         (bg_beat),
            .bar_start_i    (bg_bar_start),
            .transport_i    (bg_transport),
            .evt_valid_o    (met_evt_valid),
            .evt_axis_o     (met_evt_axis),
            .evt_phase_inc_o(met_evt_inc),
            .evt_velocity_o (met_evt_vel),
            .evt_kind_o     (met_evt_kind),
            .beat_cnt_o     (met_beat_cnt),
            .accent_cnt_o   (met_accent_cnt),
            .cfg_warn_o     (met_cfg_warn)
        );

        // ⭐⭐ T36 / U-6：事件合流（手弹/曲谱 + 节拍器 → note_manager 的**唯一**事件口）
        //   🔴 **为什么必须加它**：`note_manager` 只有一个事件口，
        //      而原来两路是**直接或在一起**的 ⇒ ⚠️ **同拍相撞会静默丢一条**
        //      （`note_valid_i` 只响一拍）。⭐ 本模块保证**两路同拍不丢**。
        //   ⚠️ **代价（已评估）**：同拍时后发那条**晚 1 拍 = 20 ns**，
        //      ⭐ **远小于一个音频帧 20.48 µs** ⇒ 听感不可分辨。
        //   ⭐ 可观测：`mg_collision_cnt` / `mg_merged_cnt` / `mg_drop_cnt` / `mg_overflow`
        //      （`K-106` 纪律：⛔ 容量有限的路径不许静默失效）
        wire        mg_evt_valid;
        wire [3:0]  mg_evt_axis;
        wire [31:0] mg_evt_inc;
        wire [7:0]  mg_evt_vel;
        wire [1:0]  mg_evt_kind;
        wire [15:0] mg_collision_cnt;
        wire [15:0] mg_merged_cnt;
        wire [15:0] mg_drop_cnt;
        wire        mg_overflow;

        evt_merge #(
            .AXIS_W  (4),
            .PHASE_W (32),
            .VEL_W   (8),
            .KIND_W  (2),
            .DEPTH   (4)              // ⭐ 深度 4：两源各 ≤1 条/拍，足够吸收突发
        ) u_evt_merge (
            .clk_i            (clk),
            .rst_n_i          (rst_n_sync),
            // ── 源 A：演示和弦（⭐ 将来接 `play_seq` 的曲谱事件）────────────
            .a_valid_i        (demo_note_valid),
            .a_axis_i         (demo_note_axis),
            .a_phase_inc_i    (demo_note_inc),
            .a_velocity_i     (demo_note_vel),
            .a_kind_i         (demo_note_kind),
            // ── 源 B：节拍器 ──────────────────────────────────────────────
            .b_valid_i        (met_evt_valid),
            .b_axis_i         (met_evt_axis),
            .b_phase_inc_i    (met_evt_inc),
            .b_velocity_i     (met_evt_vel),
            .b_kind_i         (met_evt_kind),
            // ── 合流输出 → `note_manager` ────────────────────────────────
            .evt_valid_o      (mg_evt_valid),
            .evt_axis_o       (mg_evt_axis),
            .evt_phase_inc_o  (mg_evt_inc),
            .evt_velocity_o   (mg_evt_vel),
            .evt_kind_o       (mg_evt_kind),
            // ── 可观测性（⚠️ 未引到引脚，但综合时**不要**被优化掉：
            //    它们驱动的是寄存器 → 会保留；⭐ 上板可用调试核读）──────────
            .collision_cnt_o  (mg_collision_cnt),
            .merged_cnt_o     (mg_merged_cnt),
            .drop_cnt_o       (mg_drop_cnt),
            .overflow_o       (mg_overflow)
        );

        // ⭐ voice 分配 / 抢占 / 参数更新（T54）
        note_manager #(
            .POLY_TARGET (POLY_TARGET),
            .AXIS_W      (4),
            .PHASE_W     (32),
            .VEL_W       (8),
            .TIMBRE_W    (2),
            .ENV_W       (16),
            .AGE_W       (16),
            // ⭐⭐ T33b: metronome + drum machine need a voice that user
            //      notes cannot steal.  metronome emits axis_id 4'hE, and
            //      note_manager picks the reserved pool by that axis, so this
            //      MUST be >= 1 or the metronome lands in the normal pool and
            //      gets stolen the moment 32 voices sound.  It is deliberately
            //      PAIRED with metronome.AXIS_ID (see u_metronome below)
            //      (K-106 family: an unpaired setting fails silently).
            .RESERVED_N  (5)
        ) u_note_manager (
            .clk_i             (clk),
            .rst_n_i           (rst_n_sync),
            .sample_tick_i     (tick_audio),
            // ⭐⭐ T36 / U-6（2026-09-22）：两个源经 `evt_merge` 合流。
            //   🔴 这里原来是把两路**直接或在一起**：
            //        .note_valid_i (demo_note_valid | met_evt_valid)
            //        .note_axis_i  (demo_note_valid ? demo_note_axis : met_evt_axis)
            //      ⇒ ⚠️ **同拍相撞时 demo 赢、met 的事件【静默消失】**
            //        （`note_valid_i` 只响一拍，那一整条事件就永久没了）。
            //   ⭐ 现在由 `evt_merge` 仲裁：⭐ **两路同拍【不丢】**，
            //      后发的那条**晚 1 拍**（20 ns）—— 远小于一个音频帧 20.48 µs
            //      ⇒ ⭐ 听感不可分辨；而"丢一条"是永久损失。
            .note_valid_i      (mg_evt_valid),
            .note_axis_i       (mg_evt_axis),
            .note_phase_inc_i  (mg_evt_inc),
            .note_velocity_i   (mg_evt_vel),
            .note_kind_i       (mg_evt_kind),
            // ⚠️ 力度/音高修正通路本版**未接**（要等 W3a 采集链落地）⇒ 恒 0
            .vel_upd_valid_i   (1'b0),
            .vel_upd_axis_i    (4'd0),
            .vel_upd_value_i   (8'd0),
            .pitch_upd_valid_i (1'b0),
            .pitch_upd_axis_i  (4'd0),
            .pitch_upd_value_i (32'd0),
            .default_timbre_i  (2'd0),
            .evt_timbre_valid_i(1'b0),
            .evt_timbre_i      (2'd0),
            .env_active_i      (env_active),
            .env_level_i       (env_level),
            .voice_gate_o      (nm_gate),
            .voice_active_o    (nm_active),
            .voice_releasing_o (),
            .voice_axis_o      (nm_axis),
            .voice_phase_inc_o (nm_phase),
            .voice_velocity_o  (nm_vel),
            .voice_timbre_o    (nm_timbre),
            .voice_age_o       (nm_age),
            .alloc_valid_o     (nm_alloc_valid),
            .alloc_voice_o     (nm_alloc_voice)
        );

        // ⭐ 64 路独立振荡器（T55）—— ⭐ 评分主体：评委可数出 64 份相位寄存器
        oscillator_bank #(
            .POLY_TARGET   (POLY_TARGET),
            .OSC_PER_VOICE (OSC_PER_VOICE),
            .PHASE_W       (32),
            .OSC_SAMPLE_W  (16),
            .TIMBRE_N      (4),
            .TIMBRE_W      (2),
            .ENABLE_FM     (0)
        ) u_oscillator_bank (
            .clk_i              (clk),
            .rst_n_i            (rst_n_sync),
            .sample_tick_i      (tick_audio),
            .voice_active_i     (nm_active),
            .base_phase_inc_i   (nm_phase),
            .timbre_id_i        (2'd0),
            .vibrato_mod_i      (16'sd0),
            .test_mode_i        (1'b0),
            .test_lane_active_i ({(POLY_TARGET*OSC_PER_VOICE){1'b0}}),
            .test_phase_inc_i   ({(POLY_TARGET*OSC_PER_VOICE*32){1'b0}}),
            .fm_cfg_valid_i     (1'b0),
            .fm_ratio_i         (16'd0),
            .fm_index_i         (16'd0),
            .osc_sample_bus_o   (ob_samples),
            .osc_valid_o        (ob_valid),
            .phase_acc_dbg_o    (ob_phase_dbg)
        );

        // ⭐ TDM 混音 + 饱和（T56）—— ⭐ 全设计**只有 1 个 DSP**
        //    ⚠️ `render_start_i` 用 `ob_valid`（振荡器样本就绪）⇒ 天然串行、无竞争
        tdm_render_mixer #(
            .POLY_TARGET         (POLY_TARGET),
            .OSC_PER_VOICE       (OSC_PER_VOICE),
            .OSC_SAMPLE_W        (16),
            .ENV_W               (16),
            .SAMPLE_W            (SAMPLE_W),
            .CLK_PER_SAMPLE      (1024),
            .RENDER_DEADLINE_CYC (927)
        ) u_tdm_render_mixer (
            .clk_i            (clk),
            .rst_n_i          (rst_n_sync),
            .render_start_i   (ob_valid),
            .osc_sample_bus_i (ob_samples),
            .env_level_i      (env_level),
            .dry_valid_o      (mx_valid),
            .dry_sample_o     (mx_sample),
            .deadline_fault_o (mx_fault)
        );

        // ⭐ 输出寄存：`i2s_tx` 要求数据源**提前一帧**给出本帧样点
        //    ⚠️ 用 `mx_valid` 打一拍 ⇒ 整帧稳定，⛔ 不会在帧中途变化
        reg signed [SAMPLE_W-1:0] sample_r;
        always @(posedge clk) begin
            if (!rst_n_sync) sample_r <= {SAMPLE_W{1'b0}};
            else if (mx_valid) sample_r <= mx_sample;
        end

        assign sample_mono = sample_r;

        // ── ⭐ 开机自检音：复位后延时起一个 A4+C#5+E5 和弦 ────────────────
        //    ⚠️ 等 `DEMO_NOTE_DELAY` 再起音（避开上电"啪"声）
        always @(posedge clk) begin
            if (!rst_n_sync) begin
                demo_cnt        <= 24'd0;
                demo_fired      <= 1'b0;
                demo_step       <= 2'd0;
                demo_note_valid <= 1'b0;
                demo_note_axis  <= 4'd0;
                demo_note_inc   <= 32'd0;
                demo_note_vel   <= 8'd0;
                demo_note_kind  <= 2'd0;
            end else begin
                demo_note_valid <= 1'b0;      // 单拍脉冲（冻结表 §〇 约定 4）

                if (!demo_fired) begin
                    if (demo_cnt < DEMO_DELAY_V) begin
                        demo_cnt <= demo_cnt + 1'b1;
                    end else begin
                        // ⭐ 逐拍发三个 note_on（axis 0/1/2 ⇒ 占 voice 0/1/2）
                        case (demo_step)
                            2'd0: begin
                                demo_note_axis  <= 4'd0;
                                demo_note_inc   <= INC_A4;
                                demo_note_vel   <= 8'd200;
                                demo_note_kind  <= 2'd0;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 2'd1;
                            end
                            2'd1: begin
                                demo_note_axis  <= 4'd1;
                                demo_note_inc   <= INC_CS5;
                                demo_note_vel   <= 8'd200;
                                demo_note_kind  <= 2'd0;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 2'd2;
                            end
                            2'd2: begin
                                demo_note_axis  <= 4'd2;
                                demo_note_inc   <= INC_E5;
                                demo_note_vel   <= 8'd200;
                                demo_note_kind  <= 2'd0;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 2'd3;
                            end
                            default: begin
                                // ⭐ 三个音都起了 ⇒ **一直响着**（不发 note_off）
                                //    ⇒ 上板就能持续听到和弦，便于示波器/耳朵确认
                                demo_fired <= 1'b1;
                            end
                        endcase
                    end
                end
            end
        end
    end
    endgenerate


    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (32),          // 每声道 32 个 BCK（冻结口径 64 × fs）
        // ⭐ 2026-09-22 换板 Tang Console 60K：音频器件是 `MAX98357A`，
        //    ⭐ 按【标准 I2S / 左对齐】解析 ⇒ `JUSTIFY` 1 → **0**。
        //    ⚠️ 旧板 NEO Dock 的 `PT8211` 是 LSBJ/右对齐（原来这里是 1）。
        //    ⚠️ 两种都能出声、只是整体移位 ⇒ ⭐ 上板须用示波器对 `WS`/`DIN` 相位确认（`C-6`）。
        .JUSTIFY   (0),           // ⭐ 0 = 标准 I2S 左对齐（MAX98357A）
        .MSB_DELAY (1),           // 标准 I2S 的 MSB 延迟 = 1 BCK（⛔ 不用改）
        .LRCK_POL  (0)            // WS 低 = 左声道（⭐ 单声道通路，极性无影响）
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

    // ── ⚠️⚠️ `PA_EN_n`：⭐ 换板后【语义变了】—— 从"低有效功放使能"变成"多电平模式选择" ──
    //
    //   🔴 **2026-09-22 换板 Tang Console 60K 的结论（U-25b）**：
    //      ⭐ **Console 上【不存在】** `PA_EN` 这个功放使能脚。
    //      ⚠️ `PA_EN` **网络** = SOM pin 52 = **`Y14`**，经 `R54 (0R)` 直连
    //         `MAX98357A` 的 **`SD_MODE`**，且该网络**只有 `R89 51K` 下拉**
    //         （⛔ **不是分压** ⇒ **电平完全由本脚决定**；⚠️ 芯片内部还有 `100 kΩ` 下拉
    //          ⇒ ⛔ **悬空也是 Shutdown**）。
    //      🔴 **`SD_MODE` 是多电平输入（手册）**：
    //         | 电平 | 模式 |
    //         | **`< 0.16 V`** | 🔴 **`Shutdown`（没声音）** |
    //         | `0.16~0.77 V` | `(L+R)/2` |
    //         | `0.77~1.4 V` | Right |
    //         | **`> 1.4 V`** | ⭐ **Left（我们要的）** |
    //      ⇒ ⭐⭐ **要出声必须驱动【高】、⛔ 不是低**（⭐ 低 = 静音）。
    //
    //   🔴 **本条就是"换板后板子没声音"的根因**：
    //      ⚠️ 旧代码（为 `NEO Dock` 的 `NS4263` 写的）在 `PA_ON_AFTER_RESET=1` 时
    //      **把 `PA_EN_n` 拉低** ⇒ ⭐ **落进 `Shutdown`** ⇒ 🔴 **板子不出声**。
    //      ⚠️ 而 `.cst` 已改对（`Y14`/`LVCMOS15`）⇒ ⭐ **只改 `.cst` 不改 RTL 依然没声音**。
    //
    //   ⭐ **本模块现在的做法**：
    //      ① ⭐ **`PA_ON_AFTER_RESET=1`（默认）⇒ 恒【高】** ⇒ `SD_MODE` 取 **Left**；
    //         ⭐ 我们 `sample_l`/`sample_r` 送的是**同一路单声道** ⇒ **取左或取右都一样**；
    //      ② ⛔ **不再产生任何"下降沿脉冲"**（⭐ 那套 `NS4263` 一线脉冲语义在 Console 上无意义）；
    //      ③ ⭐ **端口与引脚约束保留** ⇒ ⛔ **不用改冻结的端口列表**（§〇 约定 5 要通知全员）；
    //      ④ ⭐ **`PA_ON_AFTER_RESET=0` 保留为 `NEO Dock` 回退档**：那时它=**低**
    //         （⚠️ 旧板上 **低 = NS4263 的 AB 类桥式输出**，即"出声"那侧）。
    //
    //   ⚠️ **电平注意**：`Y14` 属 **`BANK9` = 1.5 V** ⇒ ⛔ 必须 `LVCMOS15`（`.cst` 已对），
    //      驱动高 ≈ `1.3~1.5 V` ⇒ ⭐ 仍 **> 1.4 V 门槛的临界/达标** ⇒ ⭐ **上板实测确认取 Left**。
    reg pa_en_n_r;

    generate
        if (PA_ON_AFTER_RESET == 0) begin : g_pa_off
            // ⭐ **NEO Dock 回退档**：旧板上"低"= AB 类桥式输出（出声）⇒ 恒低。
            //   ⚠️ 若把本档用到 Console 上 ⇒ 🔴 **`SD_MODE` < 0.16 V = Shutdown = 没声音**。
            always @(posedge clk) begin
                if (!rst_n_sync) pa_en_n_r <= 1'b0;
                else             pa_en_n_r <= 1'b0;
            end
        end else begin : g_pa_on
            // ⭐⭐ **Console 交付档（默认）**：恒【高】⇒ `SD_MODE` = Left ⇒ **出声**。
            //   ⚠️ 为什么【无条件恒高、⛔ 不要延时计数器】：
            //      ⭐ 旧逻辑是"等 `PA_ON_DELAY` 拍后拉低一次"（为 `NS4263` 造**恰好 1 个下降沿**）。
            //      🔴 在 Console 上**那个下降沿本身就是致命动作** —— 它把 `SD_MODE` 从
            //         "Left（出声）"打到 "Shutdown（静音）"。
            //      ⇒ ⭐ **正确做法是【从头到尾保持高】**：⭐ 复位期间就是高
            //        （⚠️ 这同时满足"上电无爆音"——`SD_MODE` 全程不出 Shutdown 跳变）。
            //   📌 `PA_ON_DELAY` 参数**保留**（⛔ 不删）⇒ ⚠️ 供回退档/将来需要时使用，
            //      但本档**不再使用它**（⭐ 若将来要"软启"应先确认不会跌破 `SD_MODE` 门槛）。
            always @(posedge clk) begin
                if (!rst_n_sync) pa_en_n_r <= 1'b1;   // ⭐ 复位期间即为高（配置期靠 .cst 的 PULL_UP=UP）
                else             pa_en_n_r <= 1'b1;   // ⭐ 永远保持高 ⇒ ⛔ 无任何下降沿
            end
        end
    endgenerate

    assign PA_EN_n = pa_en_n_r;

    // ── ⭐⭐ 参数自检（`R-16`，与 `clk_gen`/`tlc5916` 的 `PARAM_OK` 同一套路）──────────
    //   ⚠️ 为什么要有它：这两个档位的**错误选择会静默失效**，而且**现象极难定位**：
    //     ① `PA_ON_AFTER_RESET=0` ⇒ 在 **Console** 上 `SD_MODE` 被拉低 ⇒
    //        落进 **`Shutdown`（< 0.16 V）⇒ 没声音**，但 I2S 波形、DAC 输入、仿真结论
    //        **全都是对的** ⇒ 会让人去查 RTL，白费几小时；
    //     ② ⚠️ 反向：`=1` 若用到 **NEO Dock** 上 ⇒ 旧板 `SD` 高 = **低功耗关断** ⇒ 同样没声音。
    //   ⇒ 仿真启动时**明确打印状态**（⛔ 不是报错，因为两个档位各自对一块板合法）。
    //   ⚠️ 换算成 ms 时**先除后乘**（避免 `PA_ON_DELAY * 1000` 在 20 位/32 位里溢出；
    //      同 `tlc5916` 的 `PER_CLK_NS`，见 `K-63`）。
    localparam integer PA_CLK_HZ       = 50_000_000;                                // V22 = 50 MHz（已查实）
    localparam integer PA_MS_X10       = (PA_ON_DELAY / (PA_CLK_HZ / 10_000)) ;      // 0.1 ms 单位
    initial begin
        if (PA_ON_AFTER_RESET == 0)
            $display("NOTE [top] PA_ON_AFTER_RESET=0 => PA_EN_n held LOW. On NEO Dock that is AB-class (SOUNDS). On Console that is SD_MODE<0.16V = Shutdown = NO SOUND (U-25b). Use 1 for Console.");
        else
            $display("NOTE [top] PA_ON_AFTER_RESET=1 => PA_EN_n held HIGH forever (0 falling edges). On Console SD_MODE=Left => SOUNDS (U-25b). On NEO Dock high = shutdown, so only use 0 there.");
    end

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
