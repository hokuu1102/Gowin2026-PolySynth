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
    parameter integer DEMO_NOTE_DELAY   = 2_000_000,
    // ⭐⭐ 开机自检音的**保持时长**（clk 数；默认 **50_000_000 = 1 秒** @50 MHz）
    //   ⭐ 用户 2026-09-23 拍板：⭐ **"让每个和弦响 1s，只起到自检作用"**。
    //   🔴 **为什么必须让它停**（⭐ 实测发现）：
    //      ⚠️ 原来自检和弦 **"一响就不停"**（⛔ 不发 `note_off`）
    //      ⇒ 🔴 **它的 voice 一直占着、声音一直在** ⇒
    //         ⚠️ 手弹时听到的是 **"自检和弦 + 我弹的音" 混在一起**
    //         （⭐ `SOURCE_A_SEL=0` 只切了"新音符从哪来"，⚠️ 切不掉已经起音的和弦）。
    //      ⭐ 实测证据：e2e tb 里 `nm_gate = 0x08000000`（⭐ 一个 voice 恒 held）
    //         ⇒ ⭐ 等它"自己安静"**永远等不到**。
    //   ⭐ 改后：⭐ 响 1 秒 ⇒ ⭐ **逐个发 `note_off`**（⭐ 轴 0/1/2）⇒
    //      ⭐ 之后 `demo_fired` 自锁 ⇒ ⛔ 不再发任何音 ✅
    //   📌 它仍然完成"自检"使命：⭐ 上电听得到 ⇒ ⭐ **证明出声链通了**。
    parameter integer DEMO_HOLD_CYC     = 50_000_000,

    // ⭐⭐ evt_merge 源 A 的来源选择（2026-09-23 新增，见下方 §源 A 仲裁）
    //   · 0 => W3a 手弹采集链（交付/上板用这一档）
    //   · 1 => 演示和弦（T57 验收 tb_top_sound 用这一档）
    //   ⚠️ 源 A 只有一个人口，而手弹与 T57 的演示和弦都要走它 => 必须仲裁。
    //   📌 不直接删演示和弦：R-16/K-69 的教训，不能为了接新功能而废掉验收手段。
    parameter integer SOURCE_A_SEL      = 0,
    // ⭐⭐ 上电自动零点标定的**等待时间**（clk 数；默认 10M ≈ **200 ms** @50 MHz）
    //   ⭐ `calib_autotare` 用它决定"等多久才开始标定"。
    //   ⚠️ **太短 ⇒ 霍尔供电/LDO 还没稳 ⇒ 🔴 零点记错**（⚠️ 而且**不可察觉**：
    //      表现为"松手位置不对"，⭐ 会被误当成阈值设错）。
    //   📌 **提成参数**是为了**让 tb 能改小** —— ⚠️ 否则仿真要跑 10M 拍。
    parameter integer AUTOTARE_DELAY_CLK = 10_000_000
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
    output wire led_heartbeat,   // V13 · CFG_LED 绿路（SYS_ACT）

    // ── ⭐⭐ W3a 采集链 · 左手区 ADC（MCP3208 ×2）────────────────────────
    //   ⭐ **2026-09-23 新增** —— ⭐ **"按琴键出声"的物理入口**。
    //   ⚠️ 走 **`J9` 排针**（⛔ 不是 PMOD —— 那 16 根已分完），
    //      ⭐ 6 根**连续相邻**（`SDRAM0_D2..D7`）。
    //   🔴 **`MISO` 两根独立**（`K-06`）—— ⚠️ 因为 `adc_farm` 是**并行锁步**，
    //      ⛔ "共享 MISO 靠未选中片高阻"在同时选中时不成立（会推挽对打）。
    //   ⚠️ **⛔ 用这些脚就不能插 `SDRAM` 模块**（`0Ω` 二选一）
    // ⭐⭐ SPI 组（⭐ 2026-09-23 晚重排成【预留 6 片】的向量）
    //   ⭐ **为什么改成向量**（⭐ 用户要求"CS 共 6 根、MISO 也预留"）：
    //      ⭐ 现在硬件只有 **2 片**（左手板 L/R = 16 轴），⚠️ 但**扩展板计划加左手板**
    //      ⇒ ⭐ **端口先留 6 位** ⇒ ⚠️ 以后加片**只改 `.cst` + `N_ADC`**，
    //         ⛔ **不用再动端口**（⭐ 也就不用再改 tb）。
    //   📌 **`N_ADC` 仍为 2**（⭐ 实例化的片数）⇒ ⭐ 高 4 位【暂不接】，
    //      ⚠️ 它们有内部上拉 ⇒ ⭐ 不会悬空乱跳 ✅
    //   🔴 **`MISO` 必须每片独立**（⭐ `K-06`）：⭐ `adc_farm` 是【锁步并行】
    //      ⇒ ⚠️ 多片同时选中 ⇒ ⭐ 共享一根会**推挽对打**。
    //   ⭐ **引脚按"每片 `MISO`+`CS` 同排左右"排**（⭐ 扩展板好走线）：
    //      片0=`N3/N4` · 片1=`N5/N6` · 片2=`N7/N8` · 片3=`N9/N10`
    //      ⚠️ `N11/N12`=`+5V/GND` · 片4=`N13/N14` · 片5=`N15/N16`
    //   ⚠️ **⛔ 用这些脚就不能插 `SDRAM` 模块**（`0Ω` 二选一）
    output wire spi_sclk,         // E14 · J9 N1 · SDRAM0_D0
    output wire spi_mosi,         // E13 · J9 N2 · SDRAM0_D1
    input  wire [5:0] spi_miso,   // N3/N5/N7/N9/N13/N15（⭐ 每片一根，内部上拉）
    output wire [5:0] spi_cs_n,   // N4/N6/N8/N10/N14/N16（⭐ 每片一根）

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ TLC5916（LED 演奏指引）—— ⭐ 2026-09-23 分配引脚
    //
    //   ⭐ **现状**：⭐ `rtl/drivers/tlc5916_driver.sv` **已存在**（⭐ 队友丙的 `T5`），
    //      ⚠️ 但 **⛔ 还没例化进本文件** ⇒ ⭐ **本版只把【引脚 + 顶层端口】加上**，
    //      ⭐ 驱动例化留给丙（⭐ 遵"一人一文件"，⚠️ 避免两边冲突）。
    //
    //   ⭐ **信号数与共享性**（⭐ 依据 `引脚预算核算.md`）：
    //      · ⭐ `SDI` / `CLK` / `LE` —— ⭐ **三根【共享】**（⭐ 所有片同一总线）
    //      · 🔴 `OE` —— ⭐ **每板独立**（⚠️ 用于"只点亮正在操作的那块板"）
    //
    //   ⭐ **为什么预留 5 根 `OE`**（⭐ 用户 2026-09-23 拍板）：
    //      ⭐ "板 B 还没画，但**预留 3 根甚至 5 根**，后续可能会加左手板"
    //      ⇒ ⭐ 现在只画/接实际用到的，⭐ 但**顶层端口先留够**
    //         —— ⚠️ 这样以后加板**只改 `.cst` 接线**，⛔ 不用改 RTL 端口。
    //
    //   📌 **`OE` 低有效**（⭐ `tlc5916` 的 `OE` = Output Enable，**低有效**）
    //      ⇒ ⭐ 端口名带 `_n`，⚠️ 与 `PA_EN_n` 同一命名习惯。
    //   🔴 **引脚来源**：⭐ 从 `J9` 取（⭐ 与 ADC 的 `D2..D7` 同组 ⇒ 走线近）
    //      ⚠️ `PMOD` 的 16 根**已全部分配完**（⭐ 见 `引脚预算核算.md` §3.1）。
    // ═══════════════════════════════════════════════════════════════════════
    output wire led_sdi,         // B21 · J9 N18 · SDRAM0_D8（⭐ 共享数据，可级联）
    output wire led_clk,         // B18 · J9 N19 · SDRAM0_A12（⭐ 共享时钟）
    output wire led_le,          // A21 · J9 N17 · SDRAM0_D9（⭐ 共享锁存）
    //   ⭐ `OE` ×5：⭐ 预留（⭐ 当前实际用 0~2 根，⚠️ 其余留空）
    //      ⭐ 低有效 ⇒ ⭐ 上电应为**高**（⭐ 不使能，灯全灭）
    output wire [4:0] led_oe_n   // B17/C17/D17/A19/A18 · J9 N20..N24
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

        // ⚠️ 计数器位宽必须够装下【两个延时里的大者】（⛔ 不要写死 24 位）
        //   🔴 **⚠️ 2026-09-23 踩到**：⭐ 原来只按 `DEMO_NOTE_DELAY`（默认 2M
        //      ⇒ 21 位）算，🔴 而 `DEMO_HOLD_CYC` 默认 **50M ⇒ 需要 26 位**
        //      ⇒ ⚠️ 若沿用 21 位 ⇒ 🔴 **计数器会【静默回绕】** ⇒
        //         ⭐ 保持时长变成错的（⚠️ 不报错、不警告）。
        //      📌 `K-107`/`K-34` 同族：⭐ **宽度不够 ⇒ 静默算错**。
        localparam integer DEMO_MAX = (DEMO_NOTE_DELAY > DEMO_HOLD_CYC) ? DEMO_NOTE_DELAY : DEMO_HOLD_CYC;
        localparam integer DEMO_CW = (DEMO_MAX < 2) ? 1 : $clog2(DEMO_MAX + 1);
        localparam [DEMO_CW-1:0] DEMO_DELAY_V = DEMO_NOTE_DELAY[DEMO_CW-1:0];
        localparam [DEMO_CW-1:0] DEMO_HOLD_V  = DEMO_HOLD_CYC[DEMO_CW-1:0];

        reg [DEMO_CW-1:0] demo_cnt;
        reg        demo_fired;
        reg [2:0]  demo_step;   // 3 bits: 0..7 (was 2 bits, max 3)
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

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ W3a 采集链（⭐⭐ 2026-09-23 新增 —— "按琴键出声"的最后一环）
        //
        //   链路：`adc_farm` → 语义层（`axis_snapshot` → `axis_map`
        //          → `event_extract` / `param_extract`）→ `evt_merge` 源 A
        //
        //   ⭐ **为什么需要 `axis_snapshot`**：
        //      ⚠️ `adc_farm` 一次只给【一个通道】的样本
        //      ⇒ 🔴 **滑音/双音判据需要同时看相邻两轴** ⇒ ⭐ 必须先做**原子快照**。
        //
        //   ⚠️ **本版范围（⭐ MVP）**：
        //      ⭐ **单轴越阈 → `note_on`/`note_off`** ⇒ ⭐ **按琴键出声**
        //      ⚠️ **滑音/双音**：⭐ 接口已预留（`slide_*`/`two_note_*`），⛔ 本版恒 0。
        // ═══════════════════════════════════════════════════════════════════

        // ── ⭐ ① `adc_farm`：2 片 MCP3208 并行采集 ────────────────────────
        wire        af_sample_valid;
        wire [2:0]  af_sample_ch;
        wire        af_frame_done;
        wire [1:0]  af_fault;
        wire [2*12-1:0] af_data;          // ⭐ packed：片 i = [i*12 +: 12]
        wire [1:0] af_cs_n, af_sclk, af_mosi;
        // ⭐ **本版只接前 2 片**（⭐ `N_ADC = 2`）⇒ ⭐ `af_miso` 取端口低 2 位。
        //   ⚠️ **端口留 6 位**（⭐ 为将来加左手板）⇒ ⭐ 高 4 位【暂不接】，
        //      它们有内部上拉 ⇒ ⭐ 不会悬空乱跳 ✅
        //   📌 以后扩到 N 片时：⭐ 把这里的 `[1:0]` 改成 `[N-1:0]`、
        //      `N_ADC` 改成 N 即可 —— ⛔ **不用动端口**（⭐ 这正是留 6 位的目的）。
        wire [1:0] af_miso = spi_miso[1:0];   // ⭐ 每片独立 MISO（⭐ K-06）

        adc_farm #(
            .N_ADC            (2),        // ⭐ 本版 2 片（左手板 L/R）
            .CLK_HZ           (50_000_000),
            .SCLK_HZ          (1_000_000),
            .CHANNEL_RATE_HZ  (2_000)
        ) u_adc_farm (
            .clk              (clk),
            .rst_n            (rst_n_sync),
            .enable           (1'b1),     // ⭐ 常开（上电即采）
            .adc_cs_n         (af_cs_n),
            .adc_sclk         (af_sclk),
            .adc_mosi         (af_mosi),
            .adc_miso         (af_miso),
            .sample_valid     (af_sample_valid),
            .sample_ch        (af_sample_ch),
            .sample_data_packed(af_data),
            .sample_data0     (),
            .sample_data1     (),
            .sample_data2     (),
            .frame_done       (af_frame_done),
            .fault            (af_fault)
        );

        // ⭐ 同源扇出 ⇒ 只用片 0 的 SCLK/MOSI 引到引脚
        //   ⚠️ `adc_farm` 内部已把片 1 扇出成与片 0 相同 ⇒ 这里取 `[0]` 即可
        assign spi_sclk = af_sclk[0];
        assign spi_mosi = af_mosi[0];
        //   ⭐ 片选：⭐ 本版 2 片 ⇒ ⭐ 只驱动低 2 位
        //   ⚠️ 高 4 位【恒定拉到"不选中"（1）】⇒ ⭐ 即使将来接线了也不会误选中
        //      （⭐ `CS` 低有效 ⇒ 1 = 不选中）
        assign spi_cs_n[1:0] = af_cs_n;       // ⭐ 片 0/1 = 左手板 L/R
        assign spi_cs_n[5:2] = 2'b11;         // ⭐ 未用的片：⭐ 保持不选中 ✅

        // ── ⭐ ② `calib` ×2：逐通道零点/灵敏度标定 ───────────────────────
        //   ⚠️ `calib` 是**单片 8 通道**的 ⇒ ⭐ **每片一份**（⭐ 设计草案 `D1`）
        //   ⚠️ **本版先【旁路】标定**（⭐ `tare`/`span` 未接 ⇒ 输出 = 输入）
        //      ⇒ ⭐ 因为上电自校需要**实物配合**（⚠️ 硬件未到手）
        //      🔴 **TODO（上板后）**：接上电自校序列（`tare`/`span` 打拍）
        wire [11:0] cal0_val, cal1_val;
        wire [2:0]  cal0_ch,  cal1_ch;
        wire        cal0_vld, cal1_vld;

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 上电自动零点标定（⭐ `calib_autotare`，2026-09-23 接入）
        //
        //   🔴 **为什么必须做**：⚠️ `calib` 未标定时 `zero = 0`
        //      ⇒ ⭐ **松手时读到的不是 0**（⭐ 实测松手 1.60 V ≈ **1985 码**）
        //      ⇒ 🔴 `event_extract` 的触发阈**按错的基准判**
        //         ⚠️ 松手就被判成"按下"（挂音）、⚠️ 或要按很深才触发。
        //
        //   ⭐ **它做什么**：⭐ 上电等 ~200 ms（让霍尔供电稳定），
        //      ⭐ 然后**逐个通道发一次 `tare`** ⇒ ⭐ 把每个轴的"松手位"记为零点。
        //
        //   🔴🔴 **关键难点**：⭐ `calib.v` 的 `if (tare) zero_r[cal_ch] <= raw;`
        //      ⇒ ⚠️ **`raw` 是【当拍输入】**（⭐ 芯片当前送来的那个通道的值）
        //      ⇒ 🔴 **`tare` 必须与 `sample_ch` 对得上**，否则会把**别的通道**的值
        //         记成这个通道的零点 —— ⭐ **而且没有任何报错**（`K-87` 同族）。
        //      ⭐ `calib_autotare` 用"**等 `sample_ch == cur_ch`**"来对齐
        //         ⇒ ⚠️ 该判据已用**反向变异**验证：⭐ 错一拍 ⇒ tb 立刻红。
        //
        //   ⛔ **不做 `span`** —— ⚠️ 它需要人把每个轴按到底 ⇒ ⭐ 留给"校准模式"。
        //   📌 依据：`files/20-代码/上电自动tare-设计方案-20260923.md`
        // ═══════════════════════════════════════════════════════════════════
        wire [1:0] at_tare;
        wire [2:0] at_ch;
        wire       at_busy, at_done;

        calib_autotare #(
            .NCH      (8),
            .N_ADC    (2),
            //   ⚠️ 可调：`AUTOTARE_DELAY_CLK` ⭐ 默认 10M 拍 ≈ 200 ms @50 MHz
            //     ⚠️ 提成参数是为了**让 tb 能改小**（⭐ 否则仿真要跑 10M 拍）
            .DELAY_CLK(AUTOTARE_DELAY_CLK)
        ) u_autotare (
            .clk           (clk),
            .rst_n         (rst_n_sync),
            .sample_valid_i(af_sample_valid),
            .sample_ch_i   (af_sample_ch),
            .tare_o        (at_tare),
            .cal_ch_o      (at_ch),
            .busy_o        (at_busy),
            .done_o        (at_done)
        );

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 霍尔极性反相 —— ⭐ **位置在 `calib` 【之前】**（2026-09-23 第 2 版）
        //
        //   🔴🔴 **为什么必须放在 `calib` 之前（⭐ 实测踩过）**：
        //      ⭐ `calib.v:148` 的公式是
        //         `prod_r <= (raw > zero_r[ch]) ? ((raw - zero_r[ch]) * gain) : 0`
        //      ⇒ ⚠️ **它【内建假设】"按下 ⇒ raw 变大"**。
        //      ⚠️ 而实测是 **"按下 ⇒ raw 变小"**（松手 1985 → 触底 1241）。
        //
        //      ⇒ 🔴 **若把反相放在 `calib`【之后】**（⭐ 我第一版就是这么写的）：
        //         · `tare` 记下松手位 `zero = 1985`
        //         · 松手 ⇒ `1985 > 1985` 假 ⇒ out = **0**
        //         · 触底 ⇒ `1241 > 1985` 假 ⇒ out = **0**（⭐ 负差被钳到 0）
        //         ⇒ 🔴 **整段行程都是 0** ⇒ ⭐ 反相后 `pos ≡ 4095`
        //         ⇒ 🔴 **永远触发、分不出按下与松手** ⇒ ⛔ **完全无法演奏**。
        //      ⭐ 实测证据：`[rest] pos=4095` 与 `[press] pos=4095` **完全相同**。
        //
        //   ⭐⭐⭐ **两个改动【单独都对、合起来错】**（⭐ 这是本条的教训）：
        //      · `INVERT_AXIS` 单独看 ✅（把下降变上升）
        //      · `autotare`     单独看 ✅（清零点偏置）
        //      · 🔴 **合起来** ⇒ 全 0 —— ⚠️ 因为 `calib` 的**减法方向**是错的。
        //      ⚠️ 更隐蔽的是：**没 `tare` 时反而"正常"**（`zero=0` ⇒ `raw-0=1985`）
        //         ⇒ 🔴 **加了 `autotare` 反而破坏原本能工作的链路**。
        //
        //   ⭐ **正解：反相放到 `calib` 之前** ⇒ ⭐ 让送进 `calib` 的 `raw'`
        //      满足它的方向假设（"按下 ⇒ `raw'` 变大"）：
        //         · 松手 `1985` ⇒ `raw' = 2110` ⇒ `tare` 记 `zero = 2110`
        //         · 触底 `1241` ⇒ `raw' = 2854` ⇒ out = `2854-2110 = 744` ✅
        //         · 松手 ⇒ out = **0** ✅
        //      ⇒ ⭐ **得到干净的 `0..744` 行程、方向向上** ✅
        //      ⭐ 而阈值 `TRIG_TH = 2259` 正是按这套码值算的 ⇒ ✅ 落在行程内。
        //
        //   📌 **`INVERT_AXIS = 0`（磁铁装反）时**：⭐ 直通 ⇒ `calib` 的假设天然成立。
        // ═══════════════════════════════════════════════════════════════════
        localparam integer INVERT_AXIS = 1;
        localparam [11:0]  ADC_FULL    = 12'hFFF;      // ⭐ 12 位满量程

        function [11:0] axis_polarity;
            input [11:0] v;
            begin
                // ⚠️ 三元表达式 ⇒ ⭐ 综合成"取反 + 常数"，⛔ 无乘法、零延迟
                axis_polarity = INVERT_AXIS ? (ADC_FULL - v) : v;
            end
        endfunction

        // ⭐ 两片的原始码，各做一次极性校正（⭐ 在 `calib` 之前）
        wire [11:0] af0_pol = axis_polarity(af_data[0*12 +: 12]);
        wire [11:0] af1_pol = axis_polarity(af_data[1*12 +: 12]);

        calib #(.NCH(8), .DW(12)) u_calib0 (
            .clk       (clk),
            .rst_n     (rst_n_sync),
            .valid     (af_sample_valid),
            .ch        (af_sample_ch),
            // ⭐ 送【极性校正后】的码 —— ⭐ 满足 `calib` 的"按下 ⇒ raw 变大"假设
            .raw       (af0_pol),
            // ⭐ 2026-09-23：由"硬接 0"改为接 `calib_autotare`（⭐ 上电自动零点）
            .tare      (at_tare[0]),
            .span      (1'b0),            // 🔴 TODO：`span` 需人工配合 ⇒ 留给校准模式
            .cal_ch    (at_ch),
            .busy      (),
            .err       (),
            .out_valid (cal0_vld),
            .out_ch    (cal0_ch),
            .out_val   (cal0_val)
        );

        calib #(.NCH(8), .DW(12)) u_calib1 (
            .clk       (clk),
            .rst_n     (rst_n_sync),
            .valid     (af_sample_valid),
            .ch        (af_sample_ch),
            .raw       (af1_pol),
            // ⭐ 2026-09-23：同 `u_calib0`，接 `calib_autotare`（⭐ 两片锁步、同时标）
            .tare      (at_tare[1]),
            .span      (1'b0),            // 🔴 TODO：`span` 需人工配合 ⇒ 留给校准模式
            .cal_ch    (at_ch),
            .busy      (),
            .err       (),
            .out_valid (cal1_vld),
            .out_ch    (cal1_ch),
            .out_val   (cal1_val)
        );

        // ── ⭐ ③ `axis_snapshot`：16 轴原子快照 + 带符号 Δ ────────────────
        //   🔴 **⚠️ 位宽教训**：⭐ `pos` 是 **16 轴 × 12 位 = 192 位**，
        //      `delta` 是 **16 × 13 = 208 位** —— ⚠️ **⛔ 不是"16 位"**
        //      （⭐ 我第一版写窄了 ⇒ iverilog 报 "expects 192 bit(s), given 16"，
        //        ⚠️ 而它会**静默补高位 0** ⇒ 🔴 若没看 warning 就会**整条链全是 0**）
        wire [16*12-1:0] as_pos;
        wire [16*13-1:0] as_delta;
        wire        as_valid;
        wire [15:0] as_seen;

        // ═══════════════════════════════════════════════════════════════════
        // ⚠️ 两片 `calib` 的输出**同拍有效**（⭐ 都源自同一个 `sample_valid`）
        //   ⇒ ⭐ 拼成 `adc_farm` 的 packed 格式喂给快照
        //   ⭐ **注意**：极性校正已经【在 `calib` 之前】做过了（见 `afN_pol`）
        //      ⇒ ⭐ 这里【⛔ 不再反相】—— ⚠️ 否则会把行程再翻一次
        wire [2*12-1:0] cal_packed = {cal1_val, cal0_val};

        axis_snapshot #(
            .AXIS_N (16),
            .N_ADC  (2),
            .POS_W  (12),
            .DW     (13)
        ) u_axis_snapshot (
            .clk           (clk),
            .rst_n         (rst_n_sync),
            .sample_valid_i(cal0_vld),      // ⭐ 两片同拍 ⇒ 用一个即可
            .sample_ch_i   (cal0_ch),
            .sample_data_i (cal_packed),
            .frame_done_i  (af_frame_done),
            .snap_valid_o  (as_valid),
            .pos_o         (as_pos),
            .delta_o       (as_delta),
            .axis_seen_o   (as_seen)
        );

        // ── ⭐ ④ `axis_map`：轴位 → `phase_inc` ──────────────────────────
        //   ⚠️ **本版用法**：⭐ 用**触发到的那个轴**查表
        //      ⇒ ⭐ 因此 `axis_map` 的输入**逐轴驱动**（⭐ 见下方 `ee` 的配合）
        //   🔴 **TODO（阶段 2）**：⭐ 配合滑音 ⇒ 需要**同时算相邻两轴**的 `phase_inc`
        wire [31:0] am_inc;
        wire        am_valid;
        wire [3:0]  am_axis;

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ `axis_map` 的驱动：⭐ **把触发轴的位置送进去查表**
        //
        //   🔴 **⚠️ 本版的设计取舍（⭐ 说清楚，⛔ 不是最终形态）**：
        //      ⚠️ `event_extract` 一帧可能报多个事件，而 `axis_map` 只有一个入口
        //      ⇒ ⭐ 本版**用"事件携带的轴号"去 `as_pos` 里取那个轴的行程**
        //      ⇒ ⭐ **单键按下的路径是【完全正确】的**（⭐ 这正是本周硬指标）
        //      ⚠️ 同帧多键时，`note_on` 事件**不会丢**（⭐ `ee_valid` 保证），
        //         但**音高可能取到"最后一个轴"的值** —— ⚠️ 这是已知限制。
        //   🔴 **TODO（阶段 2）**：⭐ `axis_snapshot` 已给【16 轴同帧 pos】，
        //      ⭐ 应改成 **`axis_map` 逐轴查表并锁存 16 个 `phase_inc`**，
        //      再按事件轴号选取 ⇒ ⭐ 那样同帧多键也正确。
        //   📌 **依据**：⭐ `axis_map.fb_inc[0..15]` **已经是 16 轴全表**
        //      ⇒ ⭐ 阶段 2 只需把"选轴"这一步挪进 `axis_map`，⛔ 不用改它的表。

        // ── ⭐ ⑤ `event_extract`：触发 / 迟滞 / 不应期 ───────────────────
        wire        ee_valid;
        wire [3:0]  ee_axis;
        wire [1:0]  ee_kind;
        wire [11:0] ee_depth;
        wire        ee_slide_v, ee_two_v, ee_ovf;
        wire [7:0]  ee_lost;
        wire [3:0]  ee_slide_ax, ee_2a, ee_2b;
        wire signed [1:0] ee_slide_dir;

        event_extract #(
            .AXIS_N (16),
            .POS_W  (12),
            .DW     (13),
            .AXIS_W (4),
            // ── ⭐⭐ 阈值（⭐ 2026-09-23 第 2 次重设，⚠️ 起因是一个真缺陷）──────
            //
            //   🔴🔴 **为什么必须重设（⭐ 实测踩到）**：
            //      ⚠️ 我第 1 版设成 `TRIG=0x8D3(2259)` —— ⭐ 那是按【没 `tare`】的
            //         码值算的（松手 2110、触底 2854）。
            //      🔴 **但 `tare` 会把零点【减掉】** ⇒ ⭐ 实际码值是：
            //         · 松手 ⇒ **0**
            //         · 触底 ⇒ **744**（= 2854 − 2110）
            //      ⇒ 🔴 `2259` 在这个空间里 **【永远达不到】** ⇒ ⛔ **永远不触发**。
            //      ⭐ 实测证据（`tb_polarity_order`）：`rest pos=0`、`press pos=744`。
            //
            //   ⭐⭐⭐ **本条的教训（⭐ 我连着犯三次，同一个根因）**：
            //      🔴 **我按"静态码值"推算，没有把【链路各级的变换】串起来算**。
            //      ⭐ 正确做法：⭐ **阈值必须按 `pos` 空间设** ——
            //         ```
            //         raw →(反相) →(tare 减零点) →(span 增益) → pos
            //         ```
            //      ⚠️ 前面三次错误都是这一个根因：
            //        ① 反相放错级（`calib` 的减法方向假设不匹配）
            //        ② 忘了 `tare` 会减零点
            //        ③ 阈值按错的空间算（本条）
            //
            //   ⭐ **本次依据（⭐ 用户 2026-09-23 拍板："不要在中间，最高 20%"）**：
            //      · ⭐ **触发阈 = 行程的 20%** ⇒ `0.20 × 744 ≈ 149` = **`12'h095`**
            //      · ⭐ **释放阈 = 行程的 12%** ⇒ `0.12 × 744 ≈ 89` = **`12'h059`**
            //        （⭐ 迟滞 8% × 744 ≈ 60 码 ⇒ ⚠️ 防回弹抖动反复触发）
            //      📌 **`tare` 之后松手恒为 0** ⇒ ⭐ 阈值不再依赖"松手码"，⭐ 更稳。
            //
            //   ⚠️ **⚠️ 这些值依赖【行程 744 码】，⚠️ 而行程取决于定位板高度**：
            //      · ⭐ 用户正在调定位板 ⇒ ⭐ **行程一定变** ⇒ 🔴 **这两个必须跟着重算**
            //      · 📌 **重算法**：⭐ 先量 `pos@松手`（应 ≈0）与 `pos@触底` ⇒
            //        `TRIG = 0.20 × 行程`、`REL = 0.12 × 行程`
            //      · ⭐ 或更省事：⭐ **启用 `span` 增益标定**，⭐ 把行程归一到满量程 ⇒
            //        ⭐ 阈值就**不用再跟着行程变**（⭐ 见给队友的通知）。
            .TRIG_TH   (12'h095),
            .REL_TH    (12'h059),
            // ⚠️ Δ 阈值（滑音/双音用）：⭐ 目前保持默认 8
            //   （⭐ 依据：滑动时每帧行程变约 8 码 ⇒ 见设计草案 §2.2b）
            .REFRACT_N (150)          // ⭐ ≈30 ms @196 µs/帧
        ) u_event_extract (
            .clk              (clk),
            .rst_n            (rst_n_sync),
            // ⭐⭐ **标定完成前不判按键**（⭐ 2026-09-23 新增，🔴 修"开机误触发"）
            //
            //   🔴 **为什么**：⭐ `calib_autotare` 完成前 `pos` 是**未标定的脏值** ——
            //      ⚠️ 未 `tare` ⇒ `zero = 0` ⇒ `pos = 4095 − 1985 = 2110`
            //      ⭐ 而阈值是按**标定后空间**设的（`TRIG_TH = 149`）
            //      ⇒ 🔴 **2110 ≫ 149 ⇒ 16 个轴【全被判"按下"】**
            //      ⇒ 🔴 **开机瞬间起一堆音符，而它们根本没被按过**
            //         ⇒ ⭐ 松手也关不掉（⭐ 对应的"按下"从未发生）。
            //   ⭐ 实测证据（e2e tb）：⭐ `n_on = 8`（我一次都没按）、
            //      `nm_gate = 0x08000000`（⭐ **一个 voice 恒 held**）。
            //
            //   ⭐ **语义上本来就该这样**：⭐ "标定没做好 ⇒ 读数不可信 ⇒ 不判按键"。
            //   📌 `at_done` 来自 `calib_autotare` ⇒ ⭐ 标定完成后才放行 ✅
            //   ⚠️ `enable_i = 0` 时 `event_extract` **还会清掉 `key_on`/`refr`**
            //      ⇒ ⭐ 标定完成后**从"全松开"的干净状态开始**（⭐ 见该模块注释）。
            .enable_i         (at_done),
            .snap_valid_i     (as_valid),
            .pos_i            (as_pos),
            .delta_i          (as_delta),
            .evt_valid_o      (ee_valid),
            .evt_axis_o       (ee_axis),
            .evt_kind_o       (ee_kind),
            .evt_depth_o      (ee_depth),
            // ⚠️ 滑音/双音：⭐ 接口已接，⛔ 本版恒 0（⭐ 阶段 2 填）
            .slide_valid_o    (ee_slide_v),
            .slide_axis_o     (ee_slide_ax),
            .slide_dir_o      (ee_slide_dir),
            .two_note_valid_o (ee_two_v),
            .two_note_axis_a_o(ee_2a),
            .two_note_axis_b_o(ee_2b),
            .overflow_o       (ee_ovf),
            .lost_cnt_o       (ee_lost)
        );


        // ═══════════════════════════════════════════════════════════════════
        //   ⚠️ **声明与 always 放在 `event_extract` 之后** ——
        //      🔴 因为本块**引用了 `ee_valid`/`ee_kind`/`ee_axis`**
        //      ⇒ ⚠️ **Verilog 要求"先声明后使用"**（⭐ 否则 elaboration 报
        //         `Unable to bind wire/reg` —— ⭐ 这是我第一版犯的错）。
        reg [11:0] am_pos_in;
        reg [3:0]  am_axis_in;
        reg        am_vld_in;
        reg        am_mode;            // ⭐ 0 = 键盘模式 · 1 = 指板模式

        always @(posedge clk) begin
            if (!rst_n_sync) begin
                am_pos_in  <= 12'd0;
                am_axis_in <= 4'd0;
                am_vld_in  <= 1'b0;
                am_mode    <= 1'b1;    // ⭐ **默认指板模式** —— ⚠️ 因为 `fb_inc` 已填**真实音高**，
                                       //    而 `kb_inc` 还是**半音阶梯占位**（⭐ 见 `axis_map.v` TODO）
            end else begin
                am_vld_in <= 1'b0;     // ⭐ 默认单周期
                if (ee_valid && (ee_kind != 2'd1)) begin
                    // ⭐ 收到 `note_on`/`pluck` ⇒ ⭐ **用该轴的位置查表**
                    //   ⚠️ 用【索引】取 `as_pos`（⭐ 不做算术后拼接 —— `83 号` 教训）
                    am_pos_in  <= as_pos[ee_axis*12 +: 12];
                    am_axis_in <= ee_axis;
                    am_mode    <= 1'b1;              // ⭐ 指板模式（真实音高）
                    am_vld_in  <= 1'b1;
                end
            end
        end

        axis_map #(
            .AXIS_W  (4),
            .POS_W   (12),
            .PHASE_W (32),
            .N_KEY   (16)
        ) u_axis_map (
            .clk          (clk),
            .rst_n        (rst_n_sync),
            .pos_valid_i  (am_vld_in),
            .axis_id_i    (am_axis_in),
            .pos_i        (am_pos_in),
            .mode_i       (am_mode),
            .phase_inc_o  (am_inc),
            .phase_valid_o(am_valid),
            .axis_id_o    (am_axis)
        );
        // ── ⭐ ⑥ `param_extract`：力度（⛔ 结构上不产生音符）───────────────
        wire       pe_vel_v, pe_pitch_v;
        wire [3:0] pe_vel_ax, pe_pitch_ax;
        wire [7:0] pe_vel;
        wire [31:0] pe_pitch;

        param_extract #(
            .AXIS_N (16),
            .POS_W  (12),
            .AXIS_W (4),
            .VEL_W  (8),
            .PHASE_W(32)
        ) u_param_extract (
            .clk          (clk),
            .rst_n        (rst_n_sync),
            .snap_valid_i (as_valid),
            .pos_i        (as_pos),
            .evt_valid_i  (ee_valid),
            .evt_axis_i   (ee_axis),
            .evt_kind_i   (ee_kind),
            .vel_valid_o  (pe_vel_v),
            .vel_axis_o   (pe_vel_ax),
            .vel_value_o  (pe_vel),
            .pitch_valid_o(pe_pitch_v),
            .pitch_axis_o (pe_pitch_ax),
            .pitch_value_o(pe_pitch)
        );

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ `axis_map` 的驱动：⭐ **按 `event_extract` 报的轴号取该轴的行程**
        //
        //   🔴 **⚠️ 这是本版的一个【简化】**（⭐ 必须说清，⛔ 不是最终形态）：
        //      ⚠️ `event_extract` 一帧可能报多个事件，⭐ 而 `axis_map` 只有一个入口
        //      ⇒ ⭐ 本版**只把"当前事件"的轴喂给 `axis_map`**
        //      ⇒ ⚠️ **同帧多事件时，音高会取错**（⭐ 但事件本身不会丢 —— 那由 `ee_valid` 保证）
        //   🔴 **TODO（阶段 2）**：⭐ 改成 **`axis_map` 内部按 16 轴全表查**
        //      （⭐ 它的 `fb_inc[0..15]` **已经是 16 轴全表了** ⇒ ⭐ 只需把 `pos` 改成按轴选）
        //   📌 **本版的验收目标**：⭐ **"按琴键出声"** —— 单键按下的路径是**完全正确**的。
        // ═══════════════════════════════════════════════════════════════════
        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 源 A 的仲裁：**`evt_merge` 源 A 只有【一个】入口**
        //
        //   🔴 **⚠️ 这是 2026-09-23 接线时暴露出的真冲突**：
        //      · ⭐ `T57` 的验收（`tb_top_sound`）**靠"演示和弦"走源 A 出声**
        //        ⇒ ⭐ 那是**交付路径的证据**（"顶层真的出声"）
        //      · ⭐ 而 ESP32 清单 §四 说"**唯一对接点 = `evt_merge` 源 A**"
        //      · ⭐ 现在 **W3a 手弹**也要进源 A
        //      ⇒ ⚠️ **三者抢同一个入口**。
        //
        //   ⭐ **本版做法：用一个参数仲裁**（⭐ 而不是删掉演示和弦 ——
        //      ⚠️ 那样会让 `T57` 的判据**失去被测对象**，⭐ 等于自己废掉一张验收单）。
        //      · `SOURCE_A_SEL = 0` ⇒ ⭐ **W3a 手弹**（⭐ 上板/交付用的档）
        //      · `SOURCE_A_SEL = 1` ⇒ ⭐ **演示和弦**（⭐ `T57` 验收用的档）
        //   🔴 **TODO（曲谱接入时）**：⭐ 那时源 A 要有 **3 个来源**（手弹/曲谱/演示）
        //      ⇒ ⭐ 应改成 **`evt_merge` 前再加一级仲裁**（⭐ 或把源 A 也做成多路合流）。
        //   📌 **为什么不直接删演示和弦**：⭐ `R-16`/`K-69` 的教训 ——
        //      ⚠️ **"测试配置"和"交付默认值"要分开**，⛔ 不能为了接新功能而废掉验收手段。
        // ═══════════════════════════════════════════════════════════════════
        wire        w3a_evt_valid = ee_valid;
        wire [3:0]  w3a_evt_axis  = ee_axis;
        wire [1:0]  w3a_evt_kind  = ee_kind;
        //   ⭐ 力度：⭐ 起音**先用默认 200**（⭐ 这就是"先触发后修正"）——
        //     ⚠️ `param_extract` 要**等越过深阈**才算得出力度
        //     ⇒ ⭐ 力度修正走 `note_manager.vel_upd_*`（⭐ 那是独立的通路）
        wire [7:0]  w3a_evt_vel   = 8'd200;
        wire [31:0] w3a_evt_inc   = am_inc;

        // ⭐ 源 A 仲裁（⭐ 见上方说明）
        wire        src_a_valid = (SOURCE_A_SEL == 1) ? demo_note_valid : w3a_evt_valid;
        wire [3:0]  src_a_axis  = (SOURCE_A_SEL == 1) ? demo_note_axis  : w3a_evt_axis;
        wire [31:0] src_a_inc   = (SOURCE_A_SEL == 1) ? demo_note_inc   : w3a_evt_inc;
        wire [7:0]  src_a_vel   = (SOURCE_A_SEL == 1) ? demo_note_vel   : w3a_evt_vel;
        wire [1:0]  src_a_kind  = (SOURCE_A_SEL == 1) ? demo_note_kind  : w3a_evt_kind;

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
            // ── ⭐⭐ 源 A：**仲裁后的来源**（⭐ 默认 W3a 手弹；⚠️ `T57` 档 = 演示和弦）──
            //   📌 依据：⭐ ESP32 清单 §四"唯一对接点 = `evt_merge` 源 A"
            //   ⚠️ 见上方 §源 A 仲裁（`SOURCE_A_SEL`）
            .a_valid_i        (src_a_valid),
            .a_axis_i         (src_a_axis),
            .a_phase_inc_i    (src_a_inc),
            .a_velocity_i     (src_a_vel),
            .a_kind_i         (src_a_kind),
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
            // ⭐⭐ 力度/音高修正通路（⭐ **2026-09-23 接入 W3a `param_extract`**）
            //   🔴 原来硬接 0（注释写着"要等 W3a 采集链落地"）⇒ ⭐ **现已落地**
            //   ⭐ 力度：⭐ `param_extract` 在**越过深阈后**才发 ⇒ ⭐ **后到、只改已在响的 voice**
            //      （⭐ 这就是"先触发后修正"：⭐ 起音不等力度 ⇒ 延迟与力度无关）
            //   ⚠️ 音高：⭐ `param_extract` 本版**恒 0**（⭐ 属滑音，阶段 2）
            .vel_upd_valid_i   (pe_vel_v),
            .vel_upd_axis_i    (pe_vel_ax),
            .vel_upd_value_i   (pe_vel),
            .pitch_upd_valid_i (pe_pitch_v),
            .pitch_upd_axis_i  (pe_pitch_ax),
            .pitch_upd_value_i (pe_pitch),
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

        // ⭐⭐ 主混音 + 数字主音量 + 静音斜坡（master_mix，W3c 出声通路最后一级）
        //    ⚠️ 位置：`tdm_render_mixer` → `master_mix` → `i2s_tx`
        //    ⭐ 增益 `gain_i` 现在是**固定满增益 0x7FFF**（≈ unity）：
        //       ① 音量旋钮（`right_analog_ctrl` 的对数映射）还没落地，留接口；
        //       ② 先打通「合成 → 主音量 → I2S」这条地基通路，验证链不因缺音量而断。
        //    ⭐ 静音斜坡仍在：开机从 0 渐入，避免上电"啪"声（`音频输出方案.md` §4.4）。
        wire signed [SAMPLE_W-1:0] mm_sample;
        wire                      mm_valid;
        master_mix #(
            .SAMPLE_W  (SAMPLE_W),
            .GAIN_W    (16),
            .RAMP_STEP (128)
        ) u_master_mix (
            .clk_i        (clk),
            .rst_n_i      (rst_n_sync),
            .sample_tick_i(tick_audio),
            .valid_i      (mx_valid),
            .sample_i     (mx_sample),
            .gain_i       (16'h7FFF),     // ⭐ 固定满增益，音量旋钮落地后替换
            .valid_o      (mm_valid),
            .sample_o     (mm_sample),
            .ramp_busy_o  ()
        );

        // ⭐ 输出寄存：`i2s_tx` 要求数据源**提前一帧**给出本帧样点
        //    ⚠️ 用 `mx_valid` 打一拍 ⇒ 整帧稳定，⛔ 不会在帧中途变化
        reg signed [SAMPLE_W-1:0] sample_r;
        always @(posedge clk) begin
            if (!rst_n_sync) sample_r <= {SAMPLE_W{1'b0}};
            else if (mm_valid) sample_r <= mm_sample;
        end

        assign sample_mono = sample_r;

        // ── ⭐ 开机自检音：复位后延时起一个 A4+C#5+E5 和弦 ────────────────
        //    ⚠️ 等 `DEMO_NOTE_DELAY` 再起音（避开上电"啪"声）
        always @(posedge clk) begin
            if (!rst_n_sync) begin
                demo_cnt        <= 24'd0;
                demo_fired      <= 1'b0;
                demo_step       <= 3'd0;
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
                                demo_step       <= 3'd1;
                            end
                            2'd1: begin
                                demo_note_axis  <= 4'd1;
                                demo_note_inc   <= INC_CS5;
                                demo_note_vel   <= 8'd200;
                                demo_note_kind  <= 2'd0;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 3'd2;
                            end
                            2'd2: begin
                                demo_note_axis  <= 4'd2;
                                demo_note_inc   <= INC_E5;
                                demo_note_vel   <= 8'd200;
                                demo_note_kind  <= 2'd0;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 3'd3;
                            end
                            default: begin
                                // ⭐⭐ **响 `DEMO_HOLD_CYC` 后【自己停】**（⭐ 2026-09-23 改）
                                //
                                //   🔴 **为什么必须停**（⭐ 用户拍板 + 实测发现）：
                                //      ⚠️ 原来这里是 **"一直响着"**（⛔ 不发 `note_off`），
                                //         注释理由是"便于示波器/耳朵确认"。
                                //      🔴 **但那带来一个真问题**：
                                //         · `SOURCE_A_SEL=0`（手弹档）只切了
                                //           **"新音符从哪来"**，⚠️ 而自检和弦在切换
                                //           **之前**就已经起音了
                                //         ⇒ 🔴 **它的 voice 一直占着、声音一直在**
                                //         ⇒ ⚠️ 手弹时会听到 **"自检和弦 + 我弹的音" 混在一起**
                                //      ⭐ 实测证据（e2e tb）：
                                //         `nm_gate = 0x08000000`（⭐ 有一个 voice 恒 held）
                                //         ⇒ ⭐ 等它"自己安静"是**永远等不到**的。
                                //
                                //   ⭐ **用户决定**：⭐ **响 1 秒就停** ——
                                //      ⭐ 它只需要起到【自检】作用（⭐ 上电听得到 ⇒
                                //      证明出声链通），⛔ 不需要一直响。
                                //
                                //   📌 **实现**：⭐ 分两段 ——
                                //      ① `demo_step==3` ⇒ 开始计时（⭐ 和弦正在响）
                                //      ② 计时到 `DEMO_HOLD_CYC` ⇒ ⭐ **逐个发 `note_off`**
                                //         （⭐ 用 `demo_step` 4/5/6 走三个轴 0/1/2）
                                if (demo_cnt < DEMO_HOLD_V) begin
                                    demo_cnt  <= demo_cnt + 1'b1;
                                    demo_step <= 3'd3;          // ⭐ 继续响
                                end else begin
                                    demo_step <= 3'd4;          // ⭐ 计时到 ⇒ 转去发 off
                                    demo_cnt  <= {DEMO_CW{1'b0}};
                                end
                            end
                            // ── ⭐ 逐个发 `note_off`（⭐ 轴 0/1/2，与起音时一致）──
                            3'd4: begin
                                demo_note_axis  <= 4'd0;
                                demo_note_inc   <= INC_A4;
                                demo_note_vel   <= 8'd0;
                                demo_note_kind  <= 2'd1;        // ⭐ 1 = note_off
                                demo_note_valid <= 1'b1;
                                demo_step       <= 3'd5;
                            end
                            3'd5: begin
                                demo_note_axis  <= 4'd1;
                                demo_note_inc   <= INC_CS5;
                                demo_note_vel   <= 8'd0;
                                demo_note_kind  <= 2'd1;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 3'd6;
                            end
                            3'd6: begin
                                demo_note_axis  <= 4'd2;
                                demo_note_inc   <= INC_E5;
                                demo_note_vel   <= 8'd0;
                                demo_note_kind  <= 2'd1;
                                demo_note_valid <= 1'b1;
                                demo_step       <= 3'd7;
                            end
                            // ── ⭐ 收尾：⭐ `demo_fired` 自锁，⛔ 不再发任何音 ──
                            3'd7: begin
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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ TLC5916 输出的【安全默认值】（⭐ 2026-09-23）
    //
    //   🔴 **为什么需要**：⭐ `tlc5916_driver` **还没例化**（⭐ 属丙线）
    //      ⇒ ⚠️ 若把这四个端口悬空，⭐ **综合会给出不确定的输出** ——
    //      ⚠️ 而 `OE` 是**低有效**的 ⇒ 🔴 **万一综合成 0 ⇒ 灯全亮**（⭐ 白耗电、
    //         且上电瞬间"闪一片"）。
    //   ⭐ **本版给安全态**：
    //      · ⭐ `led_oe_n = 5'b11111` ⇒ ⭐ **全部不使能** ⇒ ⭐ 灯全灭 ✅
    //      · ⭐ `led_sdi/clk/le = 0` ⇒ ⭐ 无数据、无时钟、不锁存 ✅
    //   📌 **丙接驱动时**：⭐ 只要把这三根改成接 `tlc5916_driver` 的输出、
    //      并把 `led_oe_n` 接到它的 `tlc_oe_n`（⭐ 若需要分板 OE 则再拆）即可 ——
    //      ⚠️ **引脚分配不用改**（⭐ 已按 5 根预留）。
    //   ⚠️ **注意**：⭐ 这两组 `assign` 在驱动接进来时**必须删掉**，
    //      否则会与驱动的输出**冲突**（⭐ 多驱动同一 net ⇒ 综合报错或静默取或）。
    // ═══════════════════════════════════════════════════════════════════════
    assign led_sdi   = 1'b0;
    assign led_clk   = 1'b0;
    assign led_le    = 1'b0;
    assign led_oe_n  = 5'b11111;      // ⭐ 低有效 ⇒ 全 1 = 全部关闭（安全态）

endmodule