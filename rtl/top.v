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
    //   🔴 **2026-09-26 更新**：⭐ 源 A 现在是 **`seq_arb` 三级仲裁**（手弹/曲谱/演示）
    //      ⇒ ⭐ 本参数**只在"强制档"时才管用**（⭐ 见下方 §源 A 仲裁）：
    //        · 0 => ⭐ **走 `seq_arb` 自动仲裁**（⭐ **默认** —— 手弹 + 曲谱可叠加）
    //        · 1 => ⚠️ **强制演示和弦**（⭐ 保留给 `T57` 的 `tb_top_sound` 验收）
    //   📌 **为什么保留它**：⭐ `tb_top_sound`（`T57` 验收）依赖"演示和弦独占源 A"
    //      ⇒ ⚠️ 删了它**等于自己废掉一张验收单**（⭐ `R-16`/`K-69` 的教训）。
    parameter integer SOURCE_A_SEL      = 0,

    // ⭐⭐ 源 B：节拍器 / 鼓机【二选一】（⭐ 2026-09-26 新增 · `T34`/`U-8`）
    //   · 0 => ⭐ **节拍器**（⭐ **默认** —— ⭐ 上板听的就是这个拍子声）
    //   · 1 => ⭐ **鼓机**（Kick/Snare/HiHat/Clap + 16 步音序器）
    //   ⭐ 用户 2026-09-24 拍板："鼓机和节拍器是**二选一**的
    //      —— 使用节拍器时不会用鼓机，用鼓机不用节拍器"
    //   ⚠️ **为什么是编译期参数而⛔ 不是运行时切换**：
    //      ⚠️ 那需要改 `calib_cmd`（⭐ **上板要测的模块**）⇒ ⭐ 本轮⛔ 一行不碰它。
    //      📌 将来要"现场切" ⇒ ⭐ 只需把 `sel_drum` 换成寄存器即可（⭐ 结构已就绪）。
    parameter integer SEL_DRUM          = 0,
    // ⭐⭐ 鼓机的内置节奏型（⭐ 0~3，⭐ 见 `drum_gen.step_mask_of`）
    //   · 0 = 四拍基本型（Rock）· 1 = 八分摇滚 · 2 = 十六分放克 · 3 = 圆舞曲(3/4)
    parameter integer DRUM_PATTERN_ID   = 0,
    // ⭐⭐ 上电自动零点标定的**等待时间**（clk 数；默认 10M ≈ **200 ms** @50 MHz）
    //   ⭐ `calib_autotare` 用它决定"等多久才开始标定"。
    //   ⚠️ **太短 ⇒ 霍尔供电/LDO 还没稳 ⇒ 🔴 零点记错**（⚠️ 而且**不可察觉**：
    //      表现为"松手位置不对"，⭐ 会被误当成阈值设错）。
    //   📌 **提成参数**是为了**让 tb 能改小** —— ⚠️ 否则仿真要跑 10M 拍。
    parameter integer AUTOTARE_DELAY_CLK = 10_000_000,

    // ⭐⭐ `calib_span` 的**三个可调参数**（⭐ 2026-09-24 新增）
    //   🔴 **为什么必须提出来**：⚠️ 原来 `calib_span` 直接用模块默认值
    //      ⇒ `WAIT_TIMEOUT_CLK = 50_000_000`（= **1 秒**仿真时间 @50 MHz）
    //      🔴 而 tb **改不了** ⇒ ⚠️ 每次跑到"等按键"的超时兜底就要烧 1 秒
    //      📌 **实测**：`tb_top_sound` 因此跑了 **108 秒**（其余 tb 都是几秒）
    //   📌 **手法照抄上面的 `AUTOTARE_DELAY_CLK`**（⭐ 先例就在旁边）
    //   ⚠️ **上板默认值 = 真值**（⛔ 不要改这几个默认值）
    //
    //   🔴🔴 **2026-09-24 上板实测后调整（⭐ 重要）**：
    //      ⭐ 现象：⭐ 发 `'S'` 后**每次都回 `!`（被拒）**，⭐ 每个隔 1 秒（= 超时）。
    //      ⭐ 诊断：⭐ 用新增的 `'P'` 命令读 `af0_pol` ⇒ **实测读数**：
    //         · 松手：⭐ 2746 ~ 2904（⭐ Δ ≈ **158**）
    //         · 按住不动：⭐ 2880 ~ 2903（⭐ Δ ≈ **23**）
    //      🔴 而原来的 `STABLE_TOL = 8` ⇒ ⚠️ **按住时也超**（⭐ 23 > 8）
    //         ⇒ ⭐ `stable_cnt` 每帧被清零 ⇒ 🔴 **永远攒不到 24 帧 ⇒ 必超时**
    //      📌 对照仿真：⭐ `tb_e2e` 里 `af0_pol = 2854` ⇒ ⭐ **与实测同一量级** ✅
    //      ⇒ ✅ **修法：⭐ 放宽容限**（⭐ 不是改逻辑）：
    //         · `SPAN_STABLE_TOL`：8 → **48**（⭐ 覆盖实测 23，⭐ 留 2 倍余量）
    //         · `SPAN_STABLE_NEED`：24 → **8**（⭐ 8×500µs = 4 ms，⭐ 够快又够稳）
    //         · `SPAN_VOTE_N`：32 → **8**
    //         · `SPAN_VOTE_TOL`：16 → **96**（⭐ 覆盖按住时的抖动）
    parameter integer SPAN_WAIT_TIMEOUT_CLK = 50_000_000,
    parameter integer SPAN_STABLE_NEED      = 8,
    parameter integer SPAN_VOTE_N           = 8,
    parameter [11:0]  SPAN_STABLE_TOL       = 12'd48,
    parameter [11:0]  SPAN_VOTE_TOL         = 12'd96
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

    // ── ⭐⭐ 音频（外置 DAC = `PCM5102A` 模块，⭐ 2026-09-25 新增）──────────
    //   🔴 **为什么加**（⭐ `U-26`）：⭐ 用户**没有喇叭** ⇒ ⭐ 必须走外置 DAC 接有源音箱。
    //
    //   ⭐⭐ **路线 A：两路并存**（⭐ 用户拍板）
    //      · ⭐ **板载 `MAX98357A` 通路【完全不动】** ⇒ ⭐ 两路同时可用
    //      · ✅ 现有 I2S 回归判据（`tb_i2s_tx*` / `tb_top_m0` / `tb_e2e`）**全部不受影响**
    //      · ⚠️ 代价：⭐ 多占 3 个引脚
    //
    //   ⭐ **引脚**（⭐ `PMOD1`，⭐ 已两处核对：引脚预算表 + Console 原理图 行 466/471/473）：
    //      · `F20` = `PMOD1_IO3` · `E22` = `PMOD1_IO4` · `D22` = `PMOD1_IO5`
    //      📌 `PMOD1_IO0/1/2`（`W19`/`W20`/`F19`）**已被 SPI 占用** ⇒ ⚠️ `IO3/4/5` 是空着的 ✅
    //
    //   ⚠️ **数据源与板载完全同源**（`sample_mono` + 同一组 `bclk_en`/`frame_start`）
    //      ⇒ ⭐ 两路**天然同步**，⛔ 不需要额外的相位对齐。
    //   ⚠️ **`PCM5102A` 可以不接 `MCLK`**（⭐ 内部 PLL 从 BCK 恢复）
    //      ⇒ 🔴 **前提：⭐ 模块必须带板载晶振**（`U-26`）⇒ ⛔ 否则会没声/爆音。
    output wire I2S2_BCK,        // F20 · PMOD1_IO3 · 外置 DAC 位时钟
    output wire I2S2_LRCK,       // E22 · PMOD1_IO4 · 外置 DAC 帧时钟
    output wire I2S2_DIN,        // D22 · PMOD1_IO5 · 外置 DAC 串行数据

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
    output wire [4:0] led_oe_n,  // B17/C17/D17/A19/A18 · J9 N20..N24

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 串口（⭐ 2026-09-23 阶段C 新增）—— ⭐ 标定命令 + 曲谱事件的入口
    //
    //   🔴 **为什么现在才加**：⭐ `top.v` 此前**完全没有 UART 端口** ——
    //      ⚠️ 所以 `evt_uart_rx` / `calib_cmd` / `uart_rx` **全都接不进来**。
    //
    //   ⭐⭐ **走【板载 USB-C】**（⭐ ⛔ 不用外接 USB-TTL）：
    //      ```
    //      PC ──USB-C──> BL616（桥接芯片）──> FPGA_UART.RX/TX
    //      ```
    //      ⇒ ⭐ **一根 USB-C 线插上就是串口** ✅
    //
    //   📌 **引脚出处**（⭐ 已逐条查实，⛔ 不是猜的）：
    //      `files/10-硬件/板卡替换评估/Console引脚查证-20260922.md` §3.1
    //      ⭐ 官方 `console60k.cst` 原话：
    //         ```
    //         IO_LOC "UART_RXD" V14;  IO_PORT "UART_RXD" IO_TYPE=LVCMOS33;
    //         IO_LOC "UART_TXD" U15;  IO_PORT "UART_TXD" IO_TYPE=LVCMOS33;
    //         ```
    //
    //   ⚠️⚠️ **电平：⭐ `V14`/`U15` 是 `LVCMOS33`，⛔ 不是 1.5 V**
    //      🔴 **别与 `AA13`(`rst_n`) / `Y14`(`PA_EN_n`) 混为一谈** ——
    //         那两个属 **`BANK9` = 1.5 V 域** ⇒ ⚠️ 那边必须 `LVCMOS15`。
    //      📌 出处：`V14` 属 **`BANK8`**、`U15` 属 **`BANK6`**（⭐ 都不是 `BANK9`）
    //         ⇒ ✅ **可以（也必须）用 3.3 V**。
    //
    //   ⭐ `uart_rx`（⭐ 输入）：⭐ 串口**空闲是高电平**
    //      ⇒ ⚠️ 若 PC 没插，悬空会读到随机跳变 ⇒ 🔴 可能被当成假起始位持续误触发
    //      ⇒ ⭐ **`.cst` 里给它 `PULL_MODE=UP`**（⭐ 默认拉到空闲态）。
    //
    //   ⚠️ `uart_tx`（⭐ 输出）：⭐ **本版先只把引脚与端口加上，⛔ 不接任何逻辑**
    //      ⇒ 🔴 因为 `uart_tx.v` **不存在**（⭐ 要新写）
    //      ⇒ ⭐ **恒驱动 0**（⚠️ 串口线会一直处于"break"状态，⛔ 但无害 ——
    //         ⭐ 因为现在**没有任何东西在听它**；⭐ 且它不会被优化掉，
    //         ⚠️ 留给下一步直接接上）。
    //      📌 下一步：写 `uart_tx.v` ⇒ 把 `calib_span` 的进度回传出去
    //         （⚠️ 否则 16 轴 `span` 标定**没有进度提示、几乎没法操作**）。
    // ═══════════════════════════════════════════════════════════════════════
    input  wire uart_rx,         // V14 · 板载 BL616 → FPGA（⭐ 标定命令 / 曲谱事件）
    output wire uart_tx          // U15 · FPGA → 板载 BL616（✅ 已接逻辑，见 `u_uart_tx`）
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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 串口前端（⭐ 2026-09-23 阶段C）
    //
    //   🔴 **三个消费者共用【同一个** `uart_rx` **】**（⭐ 这是本段最关键的设计）：
    //      ```
    //      uart_rx.rx_done_o ─┬─> evt_uart_rx  （⭐ 认 0xA5 帧 = 曲谱事件）
    //                         └─> calib_cmd    （⭐ 认帧外的 T/S/X = 标定命令）
    //      ```
    //   ⭐ **两者天然共存**，因为**各自维护独立的帧边界概念**：
    //      · `evt_uart_rx`：⭐ 只在 **`idx==0`** 位置看 `0xA5`（⭐ 不做扫描）
    //      · `calib_cmd`  ：⭐ **同样跟踪 `0xA5` 边界**，⭐ 帧内字母一律当载荷
    //      ⇒ ⭐ `'T'`(0x54) **不是** `0xA5` ⇒ ⭐ 两边**都不会误同步** ✅
    //
    //   ⚠️ **代价（⭐ 上板时要心里有数）**：
    //      🔴 **每发一条标定命令，`evt_uart_rx.hdr_err_cnt_o` 会 +1** ——
    //      ⭐ **这是正常的，⛔ 不是故障**。
    //
    //   ⚠️⚠️ **波特率必须四处一致**（⭐ 不一致会**静默收乱码**、⛔ 不报错）：
    //      ```
    //      uart_rx     #(.BAUD_DIV(100))      // 🔴 2026-09-24：from 1 Mbps → 500 kbps
    //      evt_uart_rx #(.BAUD(500_000))
    //      calib_cmd   #(.BAUD(500_000))
    //      uart_tx     #(.BAUD_DIV(100))      // ⭐ 回传方向也要同档
    //      ```
    //      ⭐ 切档时**四处一起改**（⭐ 依据 `uart_rx.v` / `evt_uart_rx.v` 顶部注释）。
    //
    //   🔴🔴 **2026-09-24 实测：1 Mbps 在这块板上【有误码】**
    //      · 现象：发 `'T'`(0x54) ⇒ 收到 **`FA 54`**（⭐ 预期是回 `74` = `'t'` 受理）
    //        ⇒ ⚠️ **`0x74` 被误拆成两个字节**（⭐ 而且"秒回"⇒ 不是完成回包）
    //      · 判据：⭐ **逻辑本身是对的**（`rep_byte` 的所有合法值里**没有 0xFA**）
    //        ⇒ ⭐ 所以是**线路/时序**问题，⛔ 不是 RTL bug
    //      · ⭐ **用户经验**：⭐ 招新题那块板 **1 Mbps 同样有问题，500 kbps 正常**
    //      ⇒ ⭐ **结论：本板 500 kbps 起步**；⚠️ 若要更高，必须**实测误码率**再说
    //      📌 **500 kbps 的 `BAUD_DIV = 100`**（⭐ 50 MHz ÷ 500 kbps = 100 **整除 ⇒ 误差 0**）
    //
    //   📌 **为什么放在 `generate` 之外**：⭐ 第 ①②③ 块是**顶层基础设施**
    //      （⭐ 命令还要喂进 `g_sound` 里的 `calib_span`）
    //      ⇒ ⚠️ 放外面才能被 `g_sound` 引用（⭐ 且 `g_silent` 档也能保留串口）。
    // ═══════════════════════════════════════════════════════════════════════

    // ── ⭐ ① 字节接收器（8N1 @ 500 kbps）───────────────────────────────────
    wire [7:0] ur_data;
    wire       ur_done;

    uart_rx #(
        // ⭐ `BAUD_DIV = 50 MHz / 500 kbps = 100`（⭐ 整除 ⇒ 无误差）
        //   🔴 2026-09-24 从 1 Mbps 降到 500 kbps —— ⚠️ 实测 1 Mbps 下串口有误码
        //      （⭐ 收到 `54 FA 54` 而预期是 `74`）⇒ ⭐ 与招新题那块板同样的现象
        //   ⚠️ 必须与下面两个 `BAUD(500_000)` 一致（⭐ 否则静默乱码）
        .BAUD_DIV(100)
    ) u_uart_rx (
        .clk_i     (clk),
        .rst_n_i   (rst_n_sync),
        //   ⭐ 引脚 `V14`（⭐ `.cst` 里已给 `PULL_MODE=UP` ⇒ 空闲态稳定）
        .rx_i      (uart_rx),
        .rx_data_o (ur_data),
        .rx_done_o (ur_done)
    );

    // ── ⭐ ② 标定命令解析（`'T'` / `'S'` / `'X'`）─────────────────────────
    //   🔴 **它自带 `0xA5` 帧边界跟踪** ⇒ ⭐ 帧内的 `T/S/X` 是**载荷**，⛔ 不当命令
    //      （⚠️ 否则**曲谱灌入会被误当标定命令** —— 灾难性）
    wire cmd_tare_req, cmd_span_req, cmd_abort_req, cmd_probe_req, cmd_vstat_req;
    wire [15:0] cmd_cnt, cmd_in_frame_cnt, cmd_resync_cnt, cmd_unknown_cnt;
    wire [3:0]  cmd_idx;

    calib_cmd #(
        .CLK_HZ   (50_000_000),
        .BAUD     (500_000),        // ⚠️ 与 `uart_rx.BAUD_DIV=100` 同一档
        .GAP_BYTES(16)              // ⚠️ 与 `evt_uart_rx` 同值（⭐ 帧边界判断要一致）
    ) u_calib_cmd (
        .clk_i          (clk),
        .rst_n_i        (rst_n_sync),
        .rx_done_i      (ur_done),
        .rx_data_i      (ur_data),
        .tare_req_o     (cmd_tare_req),
        .span_req_o     (cmd_span_req),
        .abort_req_o    (cmd_abort_req),
        .probe_req_o    (cmd_probe_req),
        .vstat_req_o    (cmd_vstat_req),
        .cmd_cnt_o      (cmd_cnt),
        .in_frame_cnt_o (cmd_in_frame_cnt),
        .resync_cnt_o   (cmd_resync_cnt),
        .idx_o          (cmd_idx),
        .unknown_cnt_o  (cmd_unknown_cnt)
    );

    // ── ⭐ ③ 曲谱事件帧解析（`0xA5` + 8 字节大端 = 64 bit 事件）──────────
    //   ⚠️ **本版只接"解析出来"，⛔ 还没接进 `evt_merge`** ——
    //      ⭐ 因为那要动事件合流与 `note_manager`（⚠️ 属另一批改动，
    //      且 `SOURCE_A_SEL` 的仲裁要一起考虑）
    //   ⇒ ⭐ **本轮先让通路"能收、可观测"，⛔ 不急着灌进合成链**
    //      （⭐ 一次只改一个变量 —— 上板在即）
    wire        eu_evt_valid;
    wire [63:0] eu_evt_data;
    wire [15:0] eu_frame_cnt, eu_resync_cnt, eu_hdr_err_cnt, eu_drop_cnt;
    wire [3:0]  eu_idx;
    wire        eu_synced;

    evt_uart_rx #(
        .CLK_HZ   (50_000_000),
        .BAUD     (500_000),        // ⚠️ 与 `uart_rx.BAUD_DIV=100` 同一档
        .GAP_BYTES(16)
    ) u_evt_uart_rx (
        .clk_i         (clk),
        .rst_n_i       (rst_n_sync),
        .rx_done_i     (ur_done),
        .rx_data_i     (ur_data),
        .evt_valid_o   (eu_evt_valid),
        .evt_data_o    (eu_evt_data),
        .frame_cnt_o   (eu_frame_cnt),
        .resync_cnt_o  (eu_resync_cnt),
        .hdr_err_cnt_o (eu_hdr_err_cnt),
        .drop_cnt_o    (eu_drop_cnt),
        .idx_o         (eu_idx),
        .synced_o      (eu_synced)
    );

    // ── ⭐ ④ 串口发送器（⭐ 回传标定进度）─────────────────────────────────
    //   ⭐⭐ **为什么必须有**（⭐ 2026-09-23 阶段C 新增）：
    //      🔴 没有它，`span` 标定**没有任何进度回传** ——
    //         · 操作者不知道**现在标到第几个轴**
    //         · 不知道刚才是**通过**还是**被拒绝**
    //         ⇒ 🔴 **16 轴逐个按到底的流程几乎没法可靠完成**
    //   ⭐ 实现：⭐ 一个极简的发送调度器 ——
    //      ⭐ 波特率 500 kbps ⇒ ⭐ 一个字节 ≈ 20 µs
    //      ⇒ ⚠️ 人类根本感知不到延迟 ⇒ ⭐ **不需要 FIFO，直接串行发即可**。
    //
    //   ⭐ **本版回传的字符**（⭐ 单字节 ASCII，⭐ PC 串口助手直接能看）：
    //      | 时机 | 字符 | 含义 |
    //      |---|---|---|
    //      | ⭐ 收到 `'T'` | **`'t'`** | ⭐ 已受理 tare 请求 |
    //      | ⭐ 收到 `'S'` | **`'s'`** | ⭐ 已受理 span 请求 |
    //      | ⭐ 收到 `'X'` | **`'x'`** | ⭐ 已受理取消 |
    //      | ⭐ `span` 需要按键 | **`'0'~'9'`/`'A'~'F'`** | ⭐ **当前要求按哪个轴**（⭐ 十六进制一位） |
    //      | ⭐ 该轴通过 | **`'.'`** | ⭐ 这一轴标成功 |
    //      | 🔴 该轴被拒 | **`'!'`** | ⭐ 这一轴被拒（⭐ 手没按稳 / 没按到底） |
    //      | ⭐ 全部完成 | **`'D'`** | ⭐ 16 轴全标完 |
    //      | 🔴 放弃 | **`'E'`** | ⭐ 反复失败 ⇒ 放弃（⭐ `REJECT_MAX` 到顶） |
    //      ⚠️ **这套字符是【本项目自定义】的**（⭐ ESP32 侧已明确"标定命令由 FPGA 定"）
    //         📌 出处：`FPGA2026-esp32/.../ESP32侧串口命令格式-给FPGA侧-20260923.md` §1.3
    //      ⚠️ **⛔ 它不上 `0xA5` 帧** —— ⭐ 是**裸 ASCII**
    //         ⇒ ⚠️ 回传方向**只有 PC 在听**，⛔ 不影响下行帧解析。
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ **回传请求信号（⭐ 跨 `generate` 边界）**
    //      ⭐ 事件在 `g_sound` **内部**产生（⭐ `calib_span` 在里面），
    //      ⚠️ 而 `u_uart_tx` 在**外面** ⇒ ⭐ 信号必须引出。
    //      ⭐ **两个 `generate` 分支各自驱动它们**（⭐ 互斥 ⇒ ⛔ 不会冲突）：
    //        · `g_sound`  ⇒ ⭐ 驱动真事件
    //        · `g_silent` ⇒ ⭐ 驱动 0（⛔ 否则悬空成 `x`，⭐ 会误发垃圾字节）
    wire       tx_req;
    wire [7:0] tx_byte;

    // ═══════════════════════════════════════════════════════════════════════
    //   🔴🔴 **`uart_tx_fifo`：回传的发送队列**（⭐ 2026-09-24 新增，修 `K-126`）
    //
    //   ⭐ **为什么必须加**（⭐ 上板实测）：
    //      ⚠️ 原来 `tx_req` **直连** `uart_tx.tx_start_i` ⇒ 🔴 **忙时直接丢**
    //      · 发 `'S'` ⇒ `top.v` **同一时刻**产生两个回包：
    //          ① `'s'`（受理，⭐ 20 µs 才发完）
    //          ② 轴号提示（⭐ `calib_span` 的 `need_press`，⭐ **只高 1 拍 = 20 ns**）
    //      ⇒ 🔴 **20 ns 落在 20 µs 的发送窗口里 ⇒ 必然丢，⛔ 永不重发**
    //      ⇒ ⭐ 现象：⭐ **只收到 `s`，⭐ 之后没有任何轴号** ⇒ ⚠️ 不知道该按哪一轴
    //
    //   ⭐ **本模块把"忙就丢"改成"排队"** ⇒ ⭐ 上游随时可推，⭐ 它负责逐个喂
    //   ⭐ 深度 8（⭐ 最坏"一次 `'S'` 变 3 个回包"，⭐ 8 足够）
    //   🔴 **溢出可观测**（⭐ `K-106`）：⭐ `ovf_o` sticky + `drop_cnt_o` 饱和计数
    //      ⛔ **没有这两个输出就【等于没修】** —— ⚠️ 只是换了个地方悄悄丢
    //
    //   📌 **代价**：⭐ 回包**晚一个字节**（⭐ 20 µs）—— ⚠️ 人眼无感，✅ 可接受
    // ═══════════════════════════════════════════════════════════════════════
    wire       txf_start;        // ⭐ FIFO → uart_tx
    wire [7:0] txf_data;
    wire       txf_ovf;
    // 🔴 **`txf_ready` 必须在这里（`generate` 之外）声明** ——
    //    ⚠️ 它由 `u_tx_fifo`（⭐ 外面）驱动，⭐ 而 `u_pos_probe`（⭐ 在 `g_sound` 里）读它
    //    🔴 **第一版我把它放在 `g_sound` 里** ⇒ Gowin 综合报
    //       `Undeclared symbol 'txf_ready', assumed default net type 'wire'`
    //    ⚠️ **恰好它真的是 1 位 ⇒ 看起来能跑** ——
    //       但这正是 `L66` 警告过的那类"隐式建 wire"的隐患，⛔ 不能放过。
    wire       txf_ready;
    wire       txf_idle;         // ⭐ 队列空且发送器停（⭐ 2026-09-24）
    wire [7:0] txf_drop;
    wire       txf_busy;         // ⭐ 来自 uart_tx

    uart_tx_fifo #(.DEPTH(8)) u_tx_fifo (
        .clk_i     (clk),
        .rst_n_i   (rst_n_sync),
        .push_i    (tx_req),        // ⭐ 上游：⭐ 单拍也可（⭐ 当拍即入队）
        .data_i    (tx_byte),
        .ready_o   (txf_ready),     // ⭐ `'P'` 诊断要用（⭐ 见 `u_pos_probe`）
        .idle_o    (txf_idle),      // ⭐ 队列真空了（⭐ 包边界用）
        .tx_start_o(txf_start),
        .tx_data_o (txf_data),
        .busy_i    (txf_busy),
        .ovf_o     (txf_ovf),
        .drop_cnt_o(txf_drop),
        .ovf_clr_i (1'b0)           // ⚠️ 本版不清（⭐ 置位后保持 ⇒ 上板可观测）
    );

    uart_tx #(
        // ⚠️ 必须与 `uart_rx.BAUD_DIV` **同一档**（⭐ 否则对端收乱码）
        .BAUD_DIV(100)
    ) u_uart_tx (
        .clk_i     (clk),
        .rst_n_i   (rst_n_sync),
        .tx_start_i(txf_start),      // ⭐ 来自 `u_tx_fifo`（⛔ 不再是 `tx_req`）
        .tx_data_i (txf_data),       // ⭐ 同上
        .tx_o      (uart_tx),        // ⭐ 引脚 `D15`（⭐ J9·N25）
        .busy_o    (txf_busy),       // ⭐ 回给 `u_tx_fifo`
        .tx_done_o ()
    );

    generate
    if (DEMO_CHORD_ON == 0) begin : g_silent
        // ⭐ `'P'` 诊断：⭐ 静音档没有 `af0_pol` ⇒ ⭐ 恒无回传
        //   ⚠️ **必须声明成 `wire` 再 `assign`** ——
        //      🔴 两个 `generate` 分支各自声明同名信号（⭐ 互斥 ⇒ ⛔ 不冲突）
        wire       pp_push;
        wire [7:0] pp_data;
        assign pp_push = 1'b0;
        assign pp_data = 8'h00;
        // ── M0 安全态/静音档：⛔ 不例化合成链，直接送 0 ──────────────────
        //    ⭐ 为什么**整条链都不例化**而不是"接了但喂 0"：
        //       ① 省资源；② ⭐ **静音就是结构上的静音**，⛔ 不给"某个内部节点
        //       意外产生数据"留任何可能（`tb_top_m0` 的 E 判据要 `HP_DIN` 恒 0）。
        assign sample_mono = {SAMPLE_W{1'b0}};
        //   ⭐ 静音档：⭐ 没有 `calib_span` ⇒ ⭐ 回传恒"无请求"
        //      ⚠️ **必须显式驱动** —— 否则 `tx_req` 悬空成 `x`
        //         ⇒ 🔴 `uart_tx` 可能把 `x` 当启动脉冲，⭐ 发出垃圾字节
        //   📌 两个 `generate` 分支**互斥**（⭐ 只例化一个）
        //      ⇒ ⭐ 各自驱动同名信号 **⛔ 不会冲突** ✅
        assign tx_req  = 1'b0;
        assign tx_byte = 8'h00;
    end else begin : g_sound
        // ═══════════════════════════════════════════════════════════════════════
        //   ⭐⭐ `'P'` 诊断：⭐ 回传 `pos` 读数（⭐ 2026-09-24 新增）
        //
        //   🔴 **为什么加**（⭐ 上板实测）：
        //      ⭐ 跑 `'S'`（span）时只回 `s` + 一次轴号，🔴 之后全是 `!`（被拒）
        //      ⭐ 每个 `!` **正好隔 1 秒** ⇒ ⭐ `WAIT_TIMEOUT_CLK` ⇒ 🔴 **是超时**
        //      ⇒ ⚠️ 超时意味着"`calib_span` 在 `S_SETTLE` 等不到稳定读数"
        //      ⇒ 🔴 **而串口完全看不到 `pos`** ⇒ ⚠️ 没法判断"帧不来"还是"读数在抖"
        //
        //   ⭐ 本模块：⭐ 发 `'P'` ⇒ ⭐ 回一行 `P<4位十进制>\r\n`（⭐ 7 个字节）
        //      ⇒ ⭐ 连发几次 ⇒ ⭐ **看这个数抖不抖** ⇒ ✅ 一眼定位
        //
        //   📌 **回的是 `af0_pol`** —— ⭐ 与 `calib_span.raw_i` **同一路**
        //      ⇒ ⭐ **看到的就是它判稳定的那个数** ✅
        //   ⚠️ **它走 `u_tx_fifo`**（⛔ 不直连 `uart_tx`）
        //      📌 这正是 `K-126` 的教训：⭐ **别假设"下游有空"**


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
        //   ⭐ 2026-09-26 新增：⭐ 复音归一化的可观测输出（⭐ 当前活跃 voice 数）
        //      ⚠️ 未引到引脚 ⇒ ⭐ 综合时**不要**被优化掉：⭐ 它驱动的是寄存器树
        //         （⭐ 与 `mg_*` 那组同一手法）⇒ ⭐ 会保留，⭐ 上板可用调试核读。
        wire [$clog2(POLY_TARGET):0]   mx_n_active;

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
        //   ⭐⭐ 鼓机（`drum_gen`，⭐ 2026-09-26 新增 · `T34`/`U-8`）
        //
        //   ⭐ **它做什么**：⭐ 纯合成鼓机（Kick/Snare/HiHat/Clap）+ **16 步音序器**
        //      ⇒ ⭐ **只吐事件**（⛔ 不碰音频通路）⇒ ⭐ 零新增合规风险。
        //   ⭐ **16 步音序器【合并】在本模块内**（⭐ 用户 2026-09-26 拍板）
        //      ⇒ ⛔ **不另做 `seq_16step.v`**（⭐ 少一个模块、少一层接口）。
        //
        //   🔴 **与节拍器【二选一】**（⭐ 用户 2026-09-24 拍板）：
        //      · `SEL_DRUM = 0` ⇒ ⭐ **节拍器**（⭐ **默认** —— 上板听的拍子声）
        //      · `SEL_DRUM = 1` ⇒ ⭐ **鼓机**
        //      ⇒ ⭐ **两者都例化**，⭐ 用 `sel_drum` 选谁接到 `evt_merge` 源 B。
        //      📌 **为什么不做成"运行时切换"**（⭐ 原设计）：
        //         ⚠️ 那需要改 `calib_cmd`（⭐ **明天上板要测的模块**）
        //         ⇒ ⭐ **本轮先做编译期参数**（⛔ 一行不碰 `calib_cmd`）；
        //            ⭐ 将来要现场切，⭐ 再加串口命令即可（⭐ 接口已就绪）。
        //
        //   ⭐ **`AXIS_ID = 15`**（⭐ 与节拍器的 14 分开）：
        //      ⚠️ `AXIS_W = 4` ⇒ ⭐ **≥ `RESERVED_AXIS_BASE`(14) 只有 14/15**
        //      ⇒ ⭐ 4 个乐器**共用 15**、⭐ 靠 `PHASE_INC` 区分音色
        //      （🔴 ⛔ 不改 `AXIS_W` —— 那会动**冻结的 64 bit 事件格式**）。
        //
        //   ⚠️ **`RESERVED_N` 的账**：⭐ 节拍器 1 + 鼓机 1（⭐ 共用轴号）⇒ **需要 2**
        //      ⇒ ✅ **当前 `RESERVED_N = 5` 够用**（⛔ 不用改 `note_manager` 例化）。
        // ═══════════════════════════════════════════════════════════════════
        wire        drm_evt_valid;
        wire [3:0]  drm_evt_axis;
        wire [31:0] drm_evt_inc;
        wire [7:0]  drm_evt_vel;
        wire [1:0]  drm_evt_kind;
        wire [15:0] drm_evt_cnt;
        wire [3:0]  drm_step_cnt;
        wire [3:0]  drm_hit_cnt;
        wire [15:0] drm_step_evt_cnt;
        wire        drm_cfg_warn;

        drum_gen #(
            .AXIS_W         (4),
            .PHASE_W        (32),
            .VEL_W          (8),
            // ⭐ 15 = 4'hF（⭐ 与节拍器的 14 分开 ⇒ 将来"同时用"不用返工）
            .AXIS_ID        (15),
            .N_DRUM         (4),
            .STEPS          (16),
            .PATTERN_ID     (DRUM_PATTERN_ID),
            // ⭐ 16 分音符 = PPQN(960) / 4 = 240 tick
            .TICKS_PER_STEP (240),
            .RESERVED_N     (5)
        ) u_drum_gen (
            .clk_i          (clk),
            .rst_n_i        (rst_n_sync),
            //   ⭐ 与节拍器**同一个 `beat_gen`** ⇒ ⭐ 天然同拍（⛔ 不自己再分频）
            .tick_i         (bg_tick),
            .tick_cnt_i     (bg_tick_cnt),
            .bar_start_i    (bg_bar_start),
            .transport_i    (bg_transport),
            .evt_valid_o    (drm_evt_valid),
            .evt_axis_o     (drm_evt_axis),
            .evt_phase_inc_o(drm_evt_inc),
            .evt_velocity_o (drm_evt_vel),
            .evt_kind_o     (drm_evt_kind),
            .evt_cnt_o      (drm_evt_cnt),
            .step_cnt_o     (drm_step_cnt),
            .hit_cnt_o      (drm_hit_cnt),
            .step_evt_cnt_o (drm_step_evt_cnt),
            .cfg_warn_o     (drm_cfg_warn)
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
        //   ⭐⭐ 2026-09-23 阶段B：`busy`/`err` 从【空连接】改为**接出**
        //      🔴 接入前它们悬空 ⇒ ⭐ `calib_span` **看不到标定是否失败**
        //      ⇒ ⚠️ 那正是"静默卡死"缺陷 ③ 的现场（⭐ 见总账 §十）。
        //      ⚠️ 两片**只取片 0** —— ⭐ 因为两片锁步 ⇒ 行为一致
        //         （⭐ 与 `tb_calib_autotare` 里"一片就够"的理由相同）。
        wire        cal0_busy, cal0_err;
        wire        cal1_busy, cal1_err;

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

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ `calib_span` 的端口信号 —— 🔴 **必须在 `u_autotare` 【之前】声明**
        //
        //   🔴🔴 **这是一个真实的踩坑记录（⭐ 2026-09-23，与 `af0_pol` 同族）**：
        //      ⚠️ 我原先把这些 `wire` 声明写在 `u_calib_span` **例化之前**，
        //         ⭐ 但 `u_autotare.retrig_i` 用到了 `sp_busy`（⭐ 互锁门控），
        //         ⚠️ 而 `u_autotare` **在 `u_calib_span` 之前** ⇒ 🔴 **先用后声明**
        //      ⇒ 🔴 iverilog 只报 **`warning: implicit definition of wire 'sp_busy'`**
        //         ⚠️ **不是 error！** ⇒ ⭐ 它会把 `sp_busy` **隐式建成 1 位 wire**
        //         🔴 而真正的 `sp_busy` 也是 1 位 ⇒ ⚠️ **这个例子里恰好无害**，
        //            ⭐ 但**换成一个多位信号就会被静默截断**（⭐ `83 号` 那个坑：
        //            `wire` 不写位宽就是 1 位）⇒ 🔴 **完全可能悄悄坏掉**
        //      📌 **纪律**：⭐ **`implicit definition` 的 warning 必须当 error 对待** ——
        //         ⚠️ 它意味着"声明顺序错了"，⛔ 不要因为"看起来能跑"就放过。
        //   ⭐ 修法：⭐ 把所有 `sp_*` 声明**统一提到 `u_autotare` 之前**
        //      （⭐ 即"谁先用到，谁之前就得声明"）。
        // ═══════════════════════════════════════════════════════════════════
        wire [1:0] sp_span;          // ⭐ 逐片（⭐ 锁步 ⇒ 同拍）
        wire [2:0] sp_ch;
        wire       sp_busy, sp_done, sp_need_press, sp_reject;
        wire [3:0] sp_cur_axis, sp_done_cnt;
    // ⭐⭐ 2026-09-24 新增：⭐ span 的内部状态（⭐ 供 `'P'` 诊断回传）
    wire [2:0] sp_state;
    wire [3:0] sp_rej_cnt;
        //   ⭐ `'S'` 的门控（⭐ 与 `at_busy` 做互锁）—— ⚠️ 同样必须先声明
        wire       sp_start_gated = cmd_span_req & ~at_busy;
        wire       sp_start_rejected = cmd_span_req & at_busy;

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
            // ⭐⭐ `retrig_i`：⭐ 接 `'T'` 命令（⭐ 2026-09-23 阶段C 接通）
            //   🔴 **互锁（⭐ 与 `'S'` 对称）**：⭐ `span` 忙时**忽略 `'T'`**
            //      ⚠️ 否则 `tare` 与本轴的 `span` 同拍 ⇒ 🔴 **增益算错**（⭐ 见 `cal_ch_mux`）
            //   ⚠️ 被拒时不额外回传（⭐ `'T'` 本来就有 `'t'` 回执，⭐ 够用）
            .retrig_i      (cmd_tare_req & ~sp_busy),
            .tare_o        (at_tare),
            .cal_ch_o      (at_ch),
            .busy_o        (at_busy),
            .done_o        (at_done)
        );

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 满行程（`span`）标定 —— ⚠️ **例化体在下方**（⭐ 见 `af0_pol` 之后）
        //
        //   🔴 **为什么不能写在这里**（⭐ 2026-09-23 踩到）：
        //      ⚠️ `calib_span.raw_i` 必须接 **`af0_pol`**（⭐ 反相后、`calib` 前那一路）
        //      🔴 而 `af0_pol` 由 `axis_polarity()` 函数算出，
        //         ⭐ 那个函数**定义在 `calib` 之前**（⭐ 见下方）
        //      ⇒ 🔴 **Verilog 里"声明必须先于使用"** ⇒ ⚠️ 写在这里会报
        //         `Unable to bind wire/reg/memory 'af0_pol'`
        //      📌 这正是本项目的老坑（⭐ 交接文档也记了"声明必须先于使用"）。
        //   ⇒ ⭐ 完整说明与例化体见 `af0_pol` 声明【之后】那一段。
        // ═══════════════════════════════════════════════════════════════════

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 霍尔极性反相 —— ⭐ **位置在 `calib` 【之前】**（2026-09-23 第 2 版）

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

        // ═══════════════════════════════════════════════════════════════════════
        wire       pp_push;
        wire [7:0] pp_data;
        wire       pp_busy;
        // ⚠️ `txf_ready` **已在 `generate` 之外声明**（⭐ 见 `u_tx_fifo` 那段）——
        //    🔴 这里⛔ **不能重复声明**（⭐ 否则又变成"局部隐式 wire"）

        pos_probe #(.N_BYTES(8)) u_pos_probe (
            .clk_i      (clk),
            .rst_n_i    (rst_n_sync),
            .probe_req_i(cmd_probe_req),
            .pos_i      (af0_pol),      // ⭐ 与 `calib_span.raw_i` 同一路
            .ch_i       (af_sample_ch), // ⭐ 2026-09-24 扩展：⭐ 同时回通道号
            .push_o     (pp_push),
            .data_o     (pp_data),
            .ready_i    (txf_ready),
            .idle_i     (txf_idle),     // ⭐ 等真空了才开新包（⭐ 修包错位）
            .busy_o     (pp_busy)
        );

        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ `'V'` 诊断：⭐ 回传 `calib_span` 的【内部状态】（⭐ 2026-09-24 新增）
        //
        //   🔴 **为什么加**：⭐ 上板发 `'S'` 后是一长串 `!`，
        //      ⚠️ 而 `calib_span` 有 8 个状态，⭐ **任何一个卡住都会回 `!`**
        //      ⇒ ⭐ 从串口**看不出卡在哪一步**。
        //   ⭐ 发 `'V'` ⇒ ⭐ 回 `V<state><axis><rej>CRLF`（⭐ 7 字节）
        //      · `<state>` ⭐ 最有用：
        //         `2`=SETTLE（⭐ 稳定判定过不去）· `3`=VOTE（⭐ 收不齐帧）
        //         `1`=PROMPT（⭐ 反复重试）· `7`=DONE（⭐ 已放弃）
        //   ⚠️ **走同一个 `u_tx_fifo`**，⭐ 且等 `idle_i` 才开新包
        //      ⇒ ⭐ 不会与 `'P'`/`'T'`/`'S'` 的回包撞车（⭐ `K-126` 的教训）
        // ═══════════════════════════════════════════════════════════════════
        wire       vp_push;
        wire [7:0] vp_data;
        wire       vp_busy;

        span_probe #(.N_BYTES(7)) u_span_probe (
            .clk_i      (clk),
            .rst_n_i    (rst_n_sync),
            .req_i      (cmd_vstat_req),   // ⭐ `'V'` 命令
            .state_i    (sp_state),        // ⭐ calib_span.state_o
            .axis_i     (sp_cur_axis),     // ⭐ 当前轴
            .rej_i      (sp_rej_cnt),      // ⭐ 拒绝计数
            .push_o     (vp_push),
            .data_o     (vp_data),
            .ready_i    (txf_ready),
            .idle_i     (txf_idle),
            .busy_o     (vp_busy)
        );

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 满行程（`span`）标定（⭐ `calib_span`，2026-09-23 阶段B 接入）
        //
        //   ⭐ **它做什么**：⭐ 把某个轴"按到底"的位置记为满行程点
        //      ⇒ ⭐ `calib` 算出增益 `gain = (4095<<8)/(raw_底 − zero)`
        //      ⇒ ⭐ **把 744 码的行程拉伸到 4095（满量程）** ⇒ ⭐ 分辨率 ×5.5。
        //
        //   ⭐⭐ **为什么值得做**（⭐ 实测的账）：
        //      | | 只有 `tare` | `span` 之后 |
        //      | `pos` 行程 | **744** 码 | ⭐ **4095** |
        //      | 阈值 | `149`（⚠️ **依赖行程**） | ⭐ **`819`（固定 20%）** |
        //      🔴 **关键收益：阈值不再依赖定位板高度** ——
        //         ⚠️ 现在 `TRIG_TH=0x095` 是按"行程 744"算的，而**用户正在调定位板
        //         ⇒ 行程一定会变 ⇒ 那两个阈值必须重算**（⭐ 见 `event_extract` 的注释）。
        //         ⭐ 做完 `span` 就不用再重算了。
        //
        //   🔴🔴 **本版接线的两个关键点（⭐ 都踩过坑）**：
        //
        //   **① `raw_i` 必须用【反相后、`calib` 前】那一路**（`af0_pol`）
        //      ⚠️ 与 `u_calib0.raw` **同一路** ⇒ ⭐ 否则记的"满行程码"与
        //      `calib` 内部减零点的那个码**不在同一空间** ⇒ 🔴 增益算错（⭐ 静默）。
        //      🔴 **⚠️ 这里有一个真实的顺序陷阱**（⭐ 2026-09-23 踩到）：
        //         ⭐ `af0_pol` 由 `axis_polarity()` 函数算出来，
        //         ⚠️ 而那个函数**定义在 `calib` 实例【之前】**（⭐ 见上方）
        //         ⇒ 🔴 **本模块的例化必须放在 `af0_pol` 声明【之后】**
        //         ⇒ ⚠️ 否则 iverilog 报 `Unable to bind wire/reg/memory 'af0_pol'`
        //            （⭐ 本项目的老坑：**Verilog 里声明必须先于使用**）。
        //      📌 所以本段**物理位置在 `af0_pol` 之后**，⛔ 不是紧跟 `u_autotare`。
        //
        //   **② `cal_ch` 必须【同拍仲裁】**（🔴 本模块与 `calib_autotare` 都要驱动它）
        //      ⭐ `calib.v:106/145` 的 `raw` 是**当拍输入**
        //      ⇒ 🔴 `cal_ch` 与 `tare`/`span` 错一拍 ⇒ **把别的通道的值记成本通道的**
        //         （⭐ `K-87` 同族：**静默**，没有任何报错）。
        //      ⭐ **仲裁规则**：⭐ **谁在忙用谁的**（⭐ 见 `cal_ch_mux`）。
        //      ⚠️ **两者天然互斥**：⭐ `at_busy` 期间 `calib_span` 不会启动
        //         （⭐ 本版 `start_i` 接常量 0 ⇒ 根本不会启动）；
        //         阶段 C 接上 `'S'` 后，⭐ 必须在 `calib_cmd` 层加互锁。
        //
        //   ⚠️ **本版 `start_i` / `abort_i` 接常量 0** ——
        //      🔴 因为触发源（`uart_rx` + `calib_cmd`）属**阶段 C**。
        //      ⇒ ⭐ **行为与接入前完全一致**（⛔ 一个 `span` 都不发）。
        //
        //   ⭐ **超时兜底**（⭐ 2026-09-23 修 3 个"静默卡死"缺陷时加的）：
        //      ⚠️ 若 `adc_farm` 停扫（SPI 挂/排线松）⇒ 采样永不来
        //      ⭐ 状态机会**超时 ⇒ 拒绝 ⇒ 重试**（⛔ 不静默卡死）。
        //
        //   📌 依据：`files/20-代码/标定链接入top实施方案-20260923.md`
        //           + `files/00-总览/未完成工作总账.md` §十（三个真缺陷）
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ 端口信号 `sp_*` **已在 `u_autotare` 之前声明**（⭐ 见那里的说明）
        calib_span #(
            .NCH        (8),
            .N_ADC      (2),
            .AXIS_TOTAL (16),            // ⭐ = NCH × N_ADC（⚠️ 参数自检要求相等）
            //   ⭐ 稳定性 / 投票参数
            //      ⚠️ 2026-09-24：⭐ 原来这里写"用模块默认" ⇒ 🔴 **tb 改不了**
            //         ⇒ ⚠️ `WAIT_TIMEOUT_CLK` 的 50M 拍（1 秒仿真时间）无法缩短
            //         ⇒ 🔴 实测让 `tb_top_sound` 跑了 108 秒
            //      ✅ 现在从顶层参数传下去 ⇒ ⭐ **tb 能改小**（⭐ 见 `top` 的参数表）
            .STABLE_NEED      (SPAN_STABLE_NEED),
            .VOTE_N           (SPAN_VOTE_N),
            .WAIT_TIMEOUT_CLK (SPAN_WAIT_TIMEOUT_CLK),
            //   🔴 2026-09-24 实测后新增：⭐ 容限必须能从顶层调 ——
            //      ⚠️ 原来没传 ⇒ 用模块默认（8 / 16）⇒ 🔴 按住时也超（实测 Δ≈23）
            .STABLE_TOL       (SPAN_STABLE_TOL),
            .VOTE_TOL         (SPAN_VOTE_TOL),
            .POS_W      (12)
        ) u_calib_span (
            .clk           (clk),
            .rst_n         (rst_n_sync),
            // ⭐⭐ 2026-09-23 阶段C：接上**真正的触发源**（⭐ 原来接常量 0）
            //   ⭐ `start_i` = `'S'` 命令（⭐ 逐轴 span）
            //   ⭐ `abort_i` = `'X'` 命令（⭐ 取消）
            //   🔴 **互锁**：⭐ `'S'` 到达时若 `autotare` 还在忙 ⇒ ⭐ **必须忽略**
            //      （⚠️ 否则 `span` 与 `tare` 同拍 ⇒ `calib` 先记零点又拿它算增益
            //        ⇒ 🔴 **增益算错** —— 见 `cal_ch_mux` 的注释）
            //      📌 实现见下方 `sp_start_gated`
            .start_i       (sp_start_gated),
            .abort_i       (cmd_abort_req),
            //   ⭐ 与 `u_autotare` **同一路**（⭐ 都用 `adc_farm` 的采样握手）
            .sample_valid_i(af_sample_valid),
            .sample_ch_i   (af_sample_ch),
            //   ⭐⭐ **必须用 `af0_pol`**（⭐ 反相后、`calib` 前）—— 见上方关键点 ①
            .raw_i         (af0_pol),
            .span_o        (sp_span),
            .cal_ch_o      (sp_ch),
            //   ⭐ `calib` 的反馈（⭐ 修"静默卡死"缺陷时新增的连接）
            //      ⚠️ 接入前这两个是【空连接】⇒ 标定失败**无法感知**
            .cal_busy_i    (cal0_busy),
            .cal_err_i     (cal0_err),
            .busy_o        (sp_busy),
            .done_o        (sp_done),
            .cur_axis_o    (sp_cur_axis),
            .need_press_o  (sp_need_press),
            .reject_o      (sp_reject),
            .done_cnt_o    (sp_done_cnt),
            //   ⭐ 2026-09-24 诊断输出（⭐ 让 `'P'` 能回传"卡在哪一步"）
            .state_o       (sp_state),
            .rej_cnt_o     (sp_rej_cnt)
        );

        //   ⭐⭐ **`cal_ch` 仲裁** —— 🔴 **2026-09-24 移到下方**（⭐ 见 `sp_busy_r` 附近）
        //      🔴 **为什么移**：⭐ 原来用 `sp_busy`（⭐ 组合输出）⇒ ⭐ 与 `calib`/`calib_span`
        //         形成**跨模块组合环** ⇒ 🔴 **仿真在时间 0 挂死**（⭐ 见
        //         `files/20-代码/待查异常-tb挂死-20260924.md`）
        //      ✅ **修法**：⭐ 改用**打过一拍的** `sp_busy_r` ⇒ ⭐ **打断环**
        //         📌 且 `sp_busy_r` **已经存在**（⭐ 原本用于边沿检测，⭐ 白捡一个）

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ `'S'` 命令的【互锁】（⭐ 2026-09-23 阶段C）
        //
        //   🔴 **为什么必须有**：⭐ `calib` 是**一个共享资源**（两片锁步），
        //      而 `tare` 与 `span` **都要驱动它**：
        //        · `calib.v:145`  `if (tare) zero_r[cal_ch] <= raw;`
        //        · `calib.v:106`  `den_r <= raw - zero_r[cal_ch];`
        //      ⚠️ 若两者**同拍拉高** ⇒ 🔴 **先记零点、又立刻拿这个零点算满量程**
        //         ⇒ ⭐ `den_r` 变成"满量程码 − 刚记的零点" ⇒ 🔴 **增益完全错**
        //         （⭐ 而且是**静默**的：不报错、`calib.err` 也未必触发）
        //
        //   ⭐ **互锁规则**：⭐ **`autotare` 忙（`at_busy`）时，忽略 `'S'`**。
        //      ⚠️ 代价：⭐ 操作者在上电 200 ms 内敲 `'S'` 会**没反应**
        //      ⇒ ⭐ 所以下面**回传一个 `'!'`** 让操作者知道被拒了（⛔ 不静默）。
        //   ⚠️ 反向（`span` 忙时收到 `'T'`）**同理要拦** —— ⭐ 见 `tr_retrig` 的门控。
        //   📌 依据：`files/20-代码/标定链接入top实施方案-20260923.md` §2.1
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ `'S'` 的门控**已在 `u_autotare` 之前声明**（⭐ 见那里的说明）
        //       · `sp_start_gated`   = ⭐ 放行（⭐ `at_busy` 时不放）
        //       · `sp_start_rejected` = 🔴 被拒（⭐ 用于回传 `'!'`，⛔ 不静默吞）

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 回传调度器（⭐ 2026-09-23 阶段C）
        //
        //   ⭐ 波特率 500 kbps ⇒ ⭐ 一个字节 ≈ 20 µs ⇒ ⚠️ 人类感知不到
        //      ⇒ ⭐ **不需要 FIFO**：⭐ 事件来了就发，⭐ 发之前等上一个发完即可。
        //   ⚠️ **代价（⭐ 诚实说明）**：⭐ 若两个事件**挨得极近**（<10 µs），
        //      ⚠️ 第二个会被**丢弃**（⭐ 因为 `tx_busy` 还没落）。
        //      ⭐ 本场景下事件间隔是"人按键的速度"（⭐ 毫秒级）⇒ ✅ 完全够用。
        //      📌 若将来要发连续数据（⭐ 如波形），⭐ 那时再加 FIFO。
        //
        //   ⭐ 优先级（⭐ 高 → 低）：⭐ 这保证"最要紧的信息先出去"
        //      ① ⭐ 轴号提示（⭐ `need_press`）—— 操作者**最需要知道**
        //      ② 🔴 拒绝 / 通过（⭐ `reject` / 轴完成）
        //      ③ ⭐ 完成 / 放弃
        //      ④ ⭐ 命令受理回执（`'t'`/`'s'`/`'x'`）
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 把"哪一轴"编码成**一位十六进制 ASCII**（⭐ 0..9 → '0'..'9'，10..15 → 'A'..'F'）
        //      ⚠️ 16 轴 ⇒ ⭐ 一个字符就够（⭐ 简单、PC 串口助手直接可读）
        wire [7:0] axis_char = (sp_cur_axis < 4'd10)
                             ? (8'h30 + {4'd0, sp_cur_axis})          // '0'..'9'
                             : (8'h41 + ({4'd0, sp_cur_axis} - 8'd10)); // 'A'..'F'

        //   ⭐ 边沿检测：⭐ 把"单拍事件"变成"一个待发请求"
        //      ⚠️ 用 `*_r` 打一拍，⭐ 只在**上升沿**产生事件（⛔ 不重复发）
        reg sp_reject_r, sp_done_r, at_done_r, sp_busy_r;
        reg sp_need_r;
        always @(posedge clk) begin
            if (!rst_n_sync) begin
                sp_reject_r <= 1'b0;
                sp_done_r   <= 1'b0;
                at_done_r   <= 1'b0;
                sp_busy_r   <= 1'b0;
                sp_need_r   <= 1'b0;
            end else begin
                sp_reject_r <= sp_reject;
                sp_done_r   <= sp_done;
                at_done_r   <= at_done;
                sp_busy_r   <= sp_busy;
                sp_need_r   <= sp_need_press;
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ **`cal_ch` 仲裁**（⭐ 2026-09-24 从上方移到这里）
        //
        //   ⭐ **语义不变**：⭐ `span` 忙 ⇒ 用它的通道；⭐ 否则用 `autotare` 的。
        //
        //   🔴🔴 **为什么必须用 `sp_busy_r`（⭐ 打过一拍）而不是 `sp_busy`**：
        //      ⚠️ `sp_busy` 是 `calib_span.busy_o`（⭐ **组合输出**）
        //      ⇒ ⭐ `cal_ch_mux` 随它**立即变化** ⇒ ⭐ 而 `cal_ch_mux` 又喂给 `calib`
        //      ⇒ 🔴 **`cal_ch_mux` → `calib` → 采集通路 → `calib_span` → `sp_busy`
        //         → `cal_ch_mux` 形成【跨模块组合环】**
        //      ⇒ 🔴 **`iverilog` 在时间 0 反复求值 ⇒ 不收敛 ⇒ 仿真挂死**
        //         （⭐ 实测：`tb_top_sound` / `tb_e2e_key_to_sound` **零输出超时**）
        //
        //   ✅ **修法**：⭐ 用 `sp_busy_r`（⭐ 寄存器）做选择 ⇒ ⭐ **环被切断**
        //      ⚠️ **代价**：⭐ 仲裁**晚一拍** —— ⭐ **可接受**（⭐ 因为 `tare`/`span`
        //         本来就是"谁先在忙"的语义，⭐ 相差一个 50 MHz 周期）
        //      📌 **`sp_busy_r` 原本就有**（⭐ 上面用于边沿检测）⇒ ⭐ 白捡
        //
        //   📌 **本缺陷的教训**（⭐ `L66`/`L67` 的新形态）：
        //      ⚠️ **"模块的 tb 全过" ⛔ 不等于 "接进顶层没问题"** ——
        //      🔴 **组合环只在【跨模块回路】里才成立**，⭐ 单模块测不出来。
        //      📄 完整定位过程：`files/20-代码/待查异常-tb挂死-20260924.md`
        // ═══════════════════════════════════════════════════════════════════
        wire [2:0] cal_ch_mux = sp_busy_r ? sp_ch : at_ch;

        wire ev_reject   = sp_reject & ~sp_reject_r;        // 🔴 本轴被拒
        wire ev_done     = sp_done   & ~sp_done_r;          // ⭐ 全部完成
        wire ev_need     = sp_need_press & ~sp_need_r;      // ⭐ 开始要求按某轴
        //   ⭐ 轴完成（⭐ `done_cnt_o` 加一）—— ⚠️ `done_cnt_o` 是 4 位计数器
        //      ⭐ 用"值变化"当事件（⭐ 它只会加、不回绕，⚠️ 16 轴到顶后自锁）
        reg [3:0] sp_done_cnt_r;
        always @(posedge clk) begin
            if (!rst_n_sync) sp_done_cnt_r <= 4'd0;
            else             sp_done_cnt_r <= sp_done_cnt;
        end
        wire ev_axis_ok = (sp_done_cnt != sp_done_cnt_r) & ~ev_done;

        //   ⭐⭐ 报告请求（⭐ 优先级编码）
        wire       rep_req  = ev_need   | ev_reject | ev_axis_ok | ev_done
                            | cmd_tare_req | cmd_span_req | cmd_abort_req
                            | sp_start_rejected | (at_done & ~at_done_r);
        wire [7:0] rep_byte = ev_need          ? axis_char        // ⭐ ① 轴号（⭐ 最要紧）
                            : ev_reject        ? 8'h21            // '!' 🔴 被拒
                            : ev_axis_ok       ? 8'h2E            // '.' ⭐ 本轴通过
                            : ev_done          ? 8'h44            // 'D' ⭐ 全部完成
                            : sp_start_rejected? 8'h21            // '!' 🔴 'S' 被拒（正忙）
                            : (at_done & ~at_done_r) ? 8'h54      // 'T' ⭐ autotare 完成
                            : cmd_tare_req     ? 8'h74            // 't' ⭐ 受理 tare
                            : cmd_span_req     ? 8'h73            // 's' ⭐ 受理 span
                            :                    8'h78;           // 'x' ⭐ 受理取消

        //   ⭐ 单拍请求 ⇒ 交给 `uart_tx`（⭐ 它忙时自动忽略 ⇒ ⚠️ 见上方"代价"）
        //   ⭐ `'P'` 诊断（⭐ 2026-09-24）：⭐ 与 `T/S/X` 的回包**共用** `u_tx_fifo`
        //      ⇒ ⭐ 上游二选一（⭐ 用 `pp_push` 优先 —— ⚠️ 它只在回传那几拍高）
        //      📌 **为什么要 or 而不是 mux**：⭐ 两者【不会同拍】（⭐ `'P'` 是独立命令，
        //         ⚠️ 而 `rep_req` 由 `calib_span` 事件驱动）⇒ ⭐ 直接 or 更简单
        //      🔴 **但字节要 mux**（⭐ 否则两个来源的数据会撞在一起）
        assign tx_req  = rep_req | pp_push | vp_push;
        assign tx_byte = vp_push ? vp_data : (pp_push ? pp_data : rep_byte);


        calib #(.NCH(8), .DW(12)) u_calib0 (
            .clk       (clk),
            .rst_n     (rst_n_sync),
            .valid     (af_sample_valid),
            .ch        (af_sample_ch),
            // ⭐ 送【极性校正后】的码 —— ⭐ 满足 `calib` 的"按下 ⇒ raw 变大"假设
            .raw       (af0_pol),
            // ⭐ 2026-09-23：由"硬接 0"改为接 `calib_autotare`（⭐ 上电自动零点）
            .tare      (at_tare[0]),
            // ⭐⭐ 2026-09-23 阶段B：接 `calib_span.（⭐ 原来硬接 0）
            //   ⚠️ `span` 与 `cal_ch` 是**配套**的（⭐ 见 `cal_ch_mux` 的仲裁）
            .span      (sp_span[0]),
            .cal_ch    (cal_ch_mux),      // ⭐ 仲裁后的通道（⭐ 与 tare/span 同拍）
            .busy      (cal0_busy),       // ⭐ 阶段B：从空连接改为接出
            .err       (cal0_err),        // ⭐ 同上（⭐ `calib_span` 的失败感知）
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
            // ⭐⭐ 2026-09-23 阶段B：同 `u_calib0`（⭐ 两片锁步 ⇒ 同时标）
            .span      (sp_span[1]),
            .cal_ch    (cal_ch_mux),      // ⭐ 同一个仲裁源（⭐ 两片锁步）
            .busy      (cal1_busy),       // ⭐ 阶段B：从空连接改为接出
            .err       (cal1_err),        // ⭐ 同上
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
            //        `TRIG = 0.26 × 行程`、`REL = 0.11 × 行程`
            //      · ⭐ 或更省事：⭐ **启用 `span` 增益标定**，⭐ 把行程归一到满量程 ⇒
            //        ⭐ 阈值就**不用再跟着行程变**（⭐ 见给队友的通知）。
            //
            //   🔴🔴 **2026-09-26 上板实测调整：⭐ 加厚迟滞（⭐ 修"触发反复"）**
            //      ⭐ **上板症状**（⭐ 用户实测）：
            //         *"先是按下后一点就触发；然后变成按下时不触发，
            //           回升到阈值时才触发。**在这两个情况反复循环**"*
            //      🔴 **根因：⭐ 迟滞太薄 + 触发点太浅**
            //         · ⭐ 原值 `TRIG=0x095(149)` / `REL=0x059(89)` ⇒ **迟滞仅 60**
            //         · ⭐ 行程实测 **744**（⭐ 静止 1985 → 按下 2729）
            //           ⇒ 迟滞只占 **8%** ⇒ 🔴 **读数在阈值附近抖动就会反复 on/off**
            //         · ⭐ 而 `TRIG=149` 只占行程 **20%** ⇒ ⚠️ "按一点就触发"
            //      🔴 **关键佐证**：⭐ 本项目实测过**单通道帧间噪声可达 Δ>48**
            //         （⭐ 见 `待查异常-span拒绝循环-定案-20260925.md`：
            //            正常通道 Δ≤6，⭐ 而 **ch2 的帧间跳变 >48**）
            //         ⇒ ⚠️ **60 的迟滞挡不住 48 的噪声** ⇒ ⭐ **必然反复**。
            //      ✅ **改法**（⭐ 保持"行程百分比"这个可重算的口径）：
            //         · `TRIG = 0.26 × 744 ≈ 192`（`0x0C0`）⇒ 按深一点才触发
            //         · `REL  = 0.11 × 744 ≈  80`（`0x050`）⇒ **迟滞 112**
            //         ⇒ ⭐ **112 ≫ 48** ⇒ ✅ **即使 ch2 那种噪声也跨不过去**
            //         ⇒ ⭐ 且 `192 < 744` ⇒ ✅ **够得着**（⭐ 不会按不出声）
            //      ⚠️ **若启用 `span`**（⭐ 行程归一化到 4095）⇒ ⭐ 这两个要**重算**：
            //         `TRIG = 0.26×4095 ≈ 1065`、`REL = 0.11×4095 ≈ 450`。
            .TRIG_TH   (12'h0C0),
            .REL_TH    (12'h050),
            // ⚠️ Δ 阈值（滑音/双音用）：⭐ 目前保持默认 8
            //   （⭐ 依据：滑动时每帧行程变约 8 码 ⇒ 见设计草案 §2.2b）
            //   🔴 2026-09-25 更正 + **改值**（⭐ `K-128`）：
            //      ⚠️ 原来写 150，注释声称"≈30 ms @196 µs/帧" ⇒ 🔴 **两个数都不对**：
            //         · ⭐ 帧周期实测 **500 µs**（⛔ 不是 196）—— 见 `sim/evidence/tb_adc_farm.log`
            //         · ⇒ 150 帧 实际 = **75 ms**（🔴 是期望的 2.55 倍）
            //      ⇒ 🔴 **触发不应期过长 ⇒ 快速连击会被吞**
            //      ✅ 改法：⭐ **保持"约 30 ms"这个设计意图**，⭐ 按真实帧周期反算帧数：
            //         30 ms / 500 µs = **60 帧** ⇒ ⭐ 取 60
            //      📌 为什么改帧数而不改 `CHANNEL_RATE_HZ`：
            //         ⚠️ 改采样率会连带影响 `VOTE_N`/`STABLE_NEED`/`debounce` 等
            //            全部时序常量 ⇒ 🔴 需重跑全量回归 + 变异测试 ⇒ ⛔ 不划算。
            .REFRACT_N (60)           // ⭐ ≈30 ms @500 µs/帧（原 150 实为 75 ms）
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

        // ═══════════════════════════════════════════════════════════════════
        // 🔴🔴 **2026-09-26 上板实测修复：⭐ `valid` 必须与【它携带的数据】同拍**
        //
        //   ⭐ **上板症状**（⭐ 用户实测，⭐ 三个症状同一根因）：
        //      · ⭐ *"按下第二个键后，会**先触发一次第一个键的声音**，
        //           再按一次第二个键，才会发出这个键的声音"*
        //      · ⭐ *"多个键同时按的时候，**听不出来**，感觉有问题"*
        //      · 🔴 *"同时按下很多键之后会**卡住**，声音一直响，
        //           按哪个键哪个键就一直放对应的音高，**松手也不会静音**"*
        //
        //   🔴 **根因：⭐ `valid` 与 `phase_inc` 差了【一拍】**
        //      ⭐ 原来的接法（⚠️ 错的）：
        //      ```
        //        w3a_evt_valid = ee_valid        // ⭐ 来自 event_extract，【当拍】
        //        w3a_evt_inc   = am_inc          // ⭐ 来自 axis_map
        //        am_vld_in     <= 1'b1           // ⚠️ 在 T0 打一拍
        //        am_pos_in     <= as_pos[...]     // ⚠️ 也在 T0 打一拍
        //      ```
        //      ⭐ **时序推演**：
        //      ```
        //        T0: ee_valid=1 (axis=2)
        //            ⇒ w3a_evt_valid=1 且 w3a_evt_axis=2  【当拍就进了 seq_arb】
        //            🔴 但 am_inc 此刻还是【上一个键(axis=1)】的音高！
        //               ⚠️ 因为 am_pos_in 在 T0 这一拍【才被赋上 axis=2 的位置】
        //        T1: am_inc 才变成 axis=2 的音
        //            ⚠️ 而 ee_valid 已经=0 ⇒ 事件早用【旧音高】发出去了
        //      ```
        //      ⇒ 🔴 **事件带着【上一个键的音高】发出** ⇒ ⭐ 症状 ①
        //      ⇒ 🔴 **`axis` 与 `phase_inc` 不匹配** ⇒ ⭐ `note_manager` 把同一个
        //         axis 映射到了错误的 voice ⇒ ⚠️ `note_off` 找不到那个 voice
        //         ⇒ 🔴 **松手不静音** ⇒ ⭐ 症状 ②③
        //
        //   ⭐⭐ **修法：⭐ 把 `valid` 也延一拍，与 `am_inc` 对齐**
        //      ⭐ 做法：⭐ 用 `am_vld_in`（⭐ 它本来就是"数据已就绪"的标志）⭐ 作为**事件 valid**。
        //      📌 **这正是本项目的老纪律**（⭐ `metronome` 当年踩过同一个坑）：
        //         ⭐ **"脉冲"与"它携带的数据"必须【同拍锁存】**（`80 号` / `TROUBLESHOOTING 77 号`）。
        //      ⚠️ **代价**：⭐ 整条链**晚 1 拍 = 20 ns** ⇒ ⭐ 远小于一个音频帧 20.48 µs
        //         ⇒ ⭐ **听感不可分辨**。
        //
        //   ⚠️ **`am_axis_in` 也要一起延** —— ⭐ 否则 axis 与 inc 又错开
        //      （⭐ 下面用 `am_axis_out` 把 axis 跟随 `am_vld_in` 一起送出）。
        // ═══════════════════════════════════════════════════════════════════════
        reg        am_vld_out;         // ⭐ 与 am_inc/am_axis_out **同拍**的事件 valid
        reg [3:0]  am_axis_out;        // ⭐ 与 am_inc 同拍的轴号

        always @(posedge clk) begin
            if (!rst_n_sync) begin
                am_pos_in   <= 12'd0;
                am_axis_in  <= 4'd0;
                am_vld_in   <= 1'b0;
                am_mode     <= 1'b1;    // ⭐ **默认指板模式** —— ⚠️ 因为 `fb_inc` 已填**真实音高**，
                                        //    而 `kb_inc` 还是**半音阶梯占位**（⭐ 见 `axis_map.v` TODO）
                am_vld_out  <= 1'b0;
                am_axis_out <= 4'd0;
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
                //   ⭐⭐ `am_vld_out`/`am_axis_out` 跟随 `am_vld_in` 再延一拍
                //      ⇒ ⭐ **与 `am_inc`（axis_map 的组合输出）严格同拍**
                //      📌 `am_inc` 依赖 `am_pos_in`/`am_mode`/`am_axis_in`（⭐ 都在上拍锁存）
                //         ⇒ ⭐ `am_axis_out` 必须用**同一个 `am_axis_in`**，
                //            这样"valid / axis / inc"三者同源同拍。
                am_vld_out  <= am_vld_in;
                am_axis_out <= am_axis_in;
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
            .PHASE_W(32),
            // ⭐⭐ 2026-09-24 新增：⭐ **`pos` 的满量程**（⭐ 修 `K-124`）
            //   🔴 **为什么必须传**：⚠️ 不传就用模块默认，⭐ 而模块**看不到行程**
            //      ⇒ 🔴 原来的 `VEL_T2 = 1536` **超过实际行程 744** 却【无人发现】
            //      ⇒ ⚠️ 上板表现：⭐ **深阈永远越不过 ⇒ 力度恒定**
            //         （⚠️ 而波形全对 ⇒ 🔴 极易被误判成"手感问题"）
            //   ⭐ **现在的语义**：⭐ 阈值 = `POS_FULL` 的百分比（⭐ `VEL_T1_PCT`/`VEL_T2_PCT`）
            //      ⇒ ⭐ **换档只改 `POS_FULL` 一个数**
            //   📌 **两档取值**（⭐ 与 `TRIG_TH`/`REL_TH` 的算法一致）：
            //      · ⭐ **只 `tare`（上电默认）** ⇒ `744`（⭐ **本行就是这一档**）
            //      · ⭐ **做过 `span`（归一化）** ⇒ `4095`
            //   ⚠️ **改成 `4095` 时**：⭐ 用户必须**先做 `span`**（⭐ 发串口 `'S'`）
            //      ⇒ ⚠️ 否则 `pos` 空间还是 744 ⇒ 🔴 阈值全落空
            //   📌 **自检会守**：⭐ 若 `VEL_T2_EFF > POS_FULL` ⇒ ⭐ **PARAM_OK=0 + 报错**
            .POS_FULL(12'd744)
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
        //   🔴🔴 **2026-09-26 修正：⭐ 三者必须【同拍】**
        //      ⚠️ 原来 `valid`/`axis` 直接来自 `event_extract`（⭐ 当拍），
        //         🔴 而 `inc` 来自 `axis_map`（⭐ 晚一拍）⇒ ⭐ **音高错一轮**（⭐ 详见上方长注释）。
        //      ⭐ 现在：⭐ **`valid`/`axis` 都用【延一拍】的版本与 `am_inc` 对齐**。
        //      📌 **注意 `axis` 也要用 `am_axis_out`** —— ⚠️ 因为 `am_inc` 是由
        //         `am_axis_in`（⭐ 上一拍锁存）算出来的 ⇒ ⭐ 三者同源同拍。
        //      ⚠️ `kind` 仍用 `ee_kind`：⭐ 它是**当拍的单周期脉冲**，
        //         与 `am_vld_out`（⭐ 同样延一拍）⭐ **相位一致**。
        //      🔴 **`kind != note_off` 的过滤已在上方 `am_vld_in` 的产生处做过**
        //         ⇒ ⭐ `am_vld_out=1` **本身就意味着"这是 note_on/pluck"**，
        //         ⛔ 不需要再重复判一次（⚠️ 重复判反而会用到**错的** `ee_kind`）。
        wire        w3a_evt_valid = am_vld_out;
        wire [3:0]  w3a_evt_axis  = am_axis_out;
        wire [1:0]  w3a_evt_kind  = 2'd0;      // ⭐ note_on（⭐ 见上行说明）
        //   ⭐ 力度：⭐ 起音**先用默认 200**（⭐ 这就是"先触发后修正"）——
        //     ⚠️ `param_extract` 要**等越过深阈**才算得出力度
        //     ⇒ ⭐ 力度修正走 `note_manager.vel_upd_*`（⭐ 那是独立的通路）
        wire [7:0]  w3a_evt_vel   = 8'd200;
        wire [31:0] w3a_evt_inc   = am_inc;

        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ 源 A 三级仲裁（`seq_arb`，⭐ 2026-09-26 新增）
        //
        //   🔴 **它补的是 `top.v` 自己的 TODO**（⭐ 原文保留在下方，⛔ 不删）：
        //      *"那时源 A 要有 3 个来源（手弹/曲谱/演示）
        //        ⇒ 应改成 `evt_merge` 前再加一级仲裁"*
        //
        //   ⭐ **三个来源**：
        //      ① ⭐ **手弹**（W3a 采集链）—— 最高优先（⭐ 人优先于机器）
        //      ② ⭐ **曲谱**（`evt_uart_rx` 经串口灌入）
        //      ③ ⭐ **演示**（`DEMO_CHORD_ON` 自检和弦）—— ⚠️ **自动让位**
        //
        //   ⚠️ **与旧 `SOURCE_A_SEL` 的关系**：
        //      · `SOURCE_A_SEL = 0`（⭐ 默认）⇒ ⭐ **走 `seq_arb`**（手弹+曲谱可叠加）
        //      · `SOURCE_A_SEL = 1` ⇒ ⚠️ **强制演示独占**（⭐ 保 `T57` 的 `tb_top_sound`）
        //      📌 旧 tb 依赖"演示和弦独占源 A"⇒ ⭐ **强制档不能删**。
        //
        //   🔴 **曲谱那一路的接法（⭐ 重要）**：
        //      ⚠️ `evt_uart_rx` 现在**只"解析出来"，⛔ 还没接进 `evt_merge`**
        //         ⇒ ⭐ 本块**把 `eu_evt_valid`/`eu_evt_data` 接到 `seq_arb` 的源 2**
        //         ⇒ ⭐⭐ **灌曲谱从此会响**（⭐ 这是本模块最直接的收益）。
        //
        //   🔴🔴 **64 bit 字段位域 —— ⭐ 已从【权威来源】核实（⛔ 不是凭印象）**：
        //      📌 权威 = `tools/mid2evt.py:124-128` 的**打包**常量（⭐ 发送端）
        //         ⇒ ⭐ 与 `tools/evt2uart.py:161` 的解包**互相印证**。
        //      ```
        //        tick  : bit[63:44]  20 bit   ← ⚠️ 由 play_seq 用，⛔ 不是本处
        //        inc   : bit[43:23]  21 bit   ← ⭐ phase_inc（⭐ 注意是 21 位！）
        //        axis  : bit[22:19]   4 bit
        //        vel   : bit[18:11]   8 bit
        //        kind  : bit[10:9]    2 bit
        //        timbre: bit[8:7]     2 bit   ← ⭐ B 方案（`U-27`）
        //      ```
        //      🔴 **我第一版写错了**（⚠️ 凭印象写成 `[63:60]`=axis / `[59:28]`=inc …）
        //         ⇒ ⭐ **实测 `mid2evt.py` 才发现** ⇒ ⚠️ 若照错的那样接，
        //            🔴 **曲谱会全部响成乱七八糟的音高/轴号**（⭐ 而且**不报错** ——
        //            ⚠️ `K-87` 同族：路径能错却不可见）。
        //      📌 **教训**：⭐ **跨模块的位域必须回到"打包那一侧"核实**，
        //         ⛔ 不能凭接口表的字段【顺序】去推位【位置】。
        //      ⚠️ `inc` 是 **21 位**（⛔ 不是 32）⇒ ⭐ 高位补 0 到 32 位给 `seq_arb`。

        // ⭐ 曲谱源：⭐ 从 `evt_uart_rx` 的 64 bit 打包里拆字段（⭐ 位域见上方）
        wire [3:0]  score_evt_axis = eu_evt_data[22:19];
        wire [31:0] score_evt_inc  = {11'd0, eu_evt_data[43:23]};
        wire [7:0]  score_evt_vel  = eu_evt_data[18:11];
        wire [1:0]  score_evt_kind = eu_evt_data[10:9];
        // ═══════════════════════════════════════════════════════════════════
        //   ⚠️ **旧的二选一写法（⭐ 保留痕迹，⭐ 已被 `seq_arb` 取代）**：
        //      wire src_a_valid = (SOURCE_A_SEL == 1) ? demo_note_valid : w3a_evt_valid;
        //      ...
        //   📌 **为什么保留注释**：⭐ 它是"源 A 只有一个人口"这个约束的**历史证据**
        //      ⇒ ⚠️ 删了就没人知道**为什么当初要仲裁**（⭐ `K-106` 纪律：保留痕迹）。

        wire        sa_valid;
        wire [3:0]  sa_axis;
        wire [31:0] sa_inc;
        wire [7:0]  sa_vel;
        wire [1:0]  sa_kind;
        wire [15:0] sa_collision_cnt;
        wire [15:0] sa_merged_cnt;
        wire [15:0] sa_drop_cnt;
        wire        sa_overflow;
        wire [15:0] sa_live_cnt;
        wire [15:0] sa_score_cnt;
        wire [15:0] sa_demo_cnt;

        seq_arb #(
            .AXIS_W  (4),
            .PHASE_W (32),
            .VEL_W   (8),
            .KIND_W  (2),
            .DEPTH   (6)          // ⭐ 深度 6：3 源各 ≤1 条/拍，留足余量
        ) u_seq_arb (
            .clk_i            (clk),
            .rst_n_i          (rst_n_sync),
            // ── 源 1：手弹（⭐ W3a 采集链）—— ⭐ 最高优先 ──────────────────
            .live_valid_i     (w3a_evt_valid),
            .live_axis_i      (w3a_evt_axis),
            .live_phase_inc_i (w3a_evt_inc),
            .live_velocity_i  (w3a_evt_vel),
            .live_kind_i      (w3a_evt_kind),
            // ── 源 2：曲谱（⭐ `evt_uart_rx` —— 🔴 本次【首次】接通）────────
            .score_valid_i    (eu_evt_valid),
            .score_axis_i     (score_evt_axis),
            .score_phase_inc_i(score_evt_inc),
            .score_velocity_i (score_evt_vel),
            .score_kind_i     (score_evt_kind),
            // ── 源 3：演示（⭐ 自检和弦）—— ⚠️ 自动让位 ───────────────────
            .demo_valid_i     (demo_note_valid),
            .demo_axis_i      (demo_note_axis),
            .demo_phase_inc_i (demo_note_inc),
            .demo_velocity_i  (demo_note_vel),
            .demo_kind_i      (demo_note_kind),
            // ── 仲裁出口 → `evt_merge` 源 A ────────────────────────────────
            .evt_valid_o      (sa_valid),
            .evt_axis_o       (sa_axis),
            .evt_phase_inc_o  (sa_inc),
            .evt_velocity_o   (sa_vel),
            .evt_kind_o       (sa_kind),
            // ── ⭐ 可观测性（`K-106`：⛔ 不许静默失效）──────────────────────
            .collision_cnt_o  (sa_collision_cnt),
            .merged_cnt_o     (sa_merged_cnt),
            .drop_cnt_o       (sa_drop_cnt),
            .overflow_o       (sa_overflow),
            .live_cnt_o       (sa_live_cnt),
            .score_cnt_o      (sa_score_cnt),
            .demo_cnt_o       (sa_demo_cnt)
        );

        // ⭐⭐ 旧 `SOURCE_A_SEL = 1` 的**强制档**（⭐ 保 `T57` 的 `tb_top_sound`）
        //   ⚠️ 它**绕过** `seq_arb`（⭐ 直接拿演示和弦）⇒ ⭐ 行为与改动前【完全一致】。
        wire        src_a_valid = (SOURCE_A_SEL == 1) ? demo_note_valid : sa_valid;
        wire [3:0]  src_a_axis  = (SOURCE_A_SEL == 1) ? demo_note_axis  : sa_axis;
        wire [31:0] src_a_inc   = (SOURCE_A_SEL == 1) ? demo_note_inc   : sa_inc;
        wire [7:0]  src_a_vel   = (SOURCE_A_SEL == 1) ? demo_note_vel   : sa_vel;
        wire [1:0]  src_a_kind  = (SOURCE_A_SEL == 1) ? demo_note_kind  : sa_kind;

        // ⭐⭐ 源 B 二选一（⭐ 节拍器 / 鼓机，⭐ `SEL_DRUM`，⭐ 默认节拍器）
        //   📌 用 `generate`+`localparam` 做**编译期选择** ⇒ ⚠️ 综合会把没选中的那路
        //      **优化掉**（⭐ 省资源）；⭐ 但两路都**例化** ⇒ ⭐ 将来改运行时只需换选择信号。
        wire        sel_drum = (SEL_DRUM == 1);
        wire        src_b_valid = sel_drum ? drm_evt_valid : met_evt_valid;
        wire [3:0]  src_b_axis  = sel_drum ? drm_evt_axis  : met_evt_axis;
        wire [31:0] src_b_inc   = sel_drum ? drm_evt_inc   : met_evt_inc;
        wire [7:0]  src_b_vel   = sel_drum ? drm_evt_vel   : met_evt_vel;
        wire [1:0]  src_b_kind  = sel_drum ? drm_evt_kind  : met_evt_kind;

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
            // ── ⭐⭐ 源 B：**节拍器 / 鼓机 二选一**（⭐ `SEL_DRUM`，⭐ 默认节拍器）──
            //   📌 两路都例化，⭐ 这里选谁进 `evt_merge`（⭐ 见上方 §源 B 二选一）
            .b_valid_i        (src_b_valid),
            .b_axis_i         (src_b_axis),
            .b_phase_inc_i    (src_b_inc),
            .b_velocity_i     (src_b_vel),
            .b_kind_i         (src_b_kind),
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
            //   ⭐⭐ **2026-09-26 新增：⭐ 复音归一化的输入**
            //      ⭐ 直接复用 `note_manager.voice_active_o`（⭐ 已存在）
            //      ⇒ ⭐ **⛔ 不用新造信号、⛔ 不用改 `note_manager`**
            //      📌 语义：⭐ "当前分配了哪几个 voice" ⇒ ⭐ popcount 得 `N`
            //         ⇒ ⭐ 查 `1/√N` 表 ⇒ ⭐ 归一化（⭐ 详见 mixer 内的长注释）
            .voice_active_i   (nm_active),
            .dry_valid_o      (mx_valid),
            .dry_sample_o     (mx_sample),
            .deadline_fault_o (mx_fault),
            .n_active_o       (mx_n_active)
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

    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 外置 DAC 通路（`PCM5102A` 模块，⭐ 2026-09-25 新增 · 路线 A）
    //
    //   ⭐ **与 `u_i2s_tx`【同参数、同数据源、同节拍】** ⇒ ⭐ 两路天然同步。
    //   🔴 **为什么单独一个实例而不是"一个 i2s_tx 驱动两组引脚"**：
    //      ⭐ `i2s_tx` 的输出是 `output reg`（⭐ 无法一驱二）
    //      ⚠️ 且两者**将来可能需要不同参数**（⭐ 例如外置模块要 `JUSTIFY=1`）
    //      ⇒ ⭐ **两个实例最灵活**，⭐ 代价仅 3 个引脚 + 少量逻辑。
    //
    //   ⚠️ **为什么不加 `AUDIO_OUT_SEL` 参数**（⭐ 路线 C）：
    //      ⭐ 两路**同时输出**没有副作用（⭐ 外置 DAC 不接就没影响）
    //      ⇒ ⭐ **不需要开关** ⇒ ⚠️ 少一个参数、少一个变异点。
    //
    //   📌 **`PCM5102A` 的 `JUSTIFY` 也是 0**（⭐ 它按标准 Philips I2S 解析）
    //      ⇒ ⭐ 与 `MAX98357A` **同一档** ⇒ ⭐ 这里直接沿用上面那组参数。
    //      ⚠️ 但**若上板听到"移位/噪声"** ⇒ ⭐ 优先调【这一路】的 `JUSTIFY`/`MSB_DELAY`
    //         （⭐ 板载那路已经验证过是对的）—— ⭐ 见 `C-6`。
    // ═══════════════════════════════════════════════════════════════════════
    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (32),
        //   🔴🔴 **2026-09-26 上板实测更正**：⭐ 外置 `PCM5102A` 要的是
        //      ⭐ **MSB 无延后的左对齐**（⭐ 即 `MSB_DELAY = 0`），⛔ **不是标准 I2S**！
        //
        //   ⭐ **实测经过**（⭐ 决定性）：
        //      · 用 `bringup/dac_tone/dac_tone_top.v` 出的【三档】bitstream 逐个烧：
        //         `FORMAT_SEL=0`（标准 I2S，MSB 延后 1）⇒ 🔴 **没声**
        //         `FORMAT_SEL=1`（左对齐，MSB 无延后）⇒ ⭐ **出声了** ✅
        //      · 且模块的 `FMT` 脚接 **3V3**（⭐ = 手册的 "High = Left-justified"）
        //   📌 **术语陷阱**：⭐ `i2s_tx` 这个模块里的 `JUSTIFY=0` 指的是
        //      **"Philips 标准 I2S"**（⭐ 数据在 WS 翻转后【延迟】`MSB_DELAY` 位），
        //      ⚠️ ⛔ **不是**字面意义的"左对齐" —— ⚠️ 别被名字误导。
        //      ⭐ 真正要"左对齐" ⇒ ⭐ **`JUSTIFY=0` + `MSB_DELAY=0`**。
        //   ⚠️ **与板载那一路的区别**：⭐ 板载 `MAX98357A` 用 `MSB_DELAY=1`（标准 I2S）
        //      ⇒ ⭐ **两路参数不同，这是故意的**（⭐ 实测各自都对）。
        .JUSTIFY   (0),
        .MSB_DELAY (0),           // ⭐ 外置 PCM5102A：左对齐（⭐ 实测出声）
        .LRCK_POL  (0)            // ⭐ 与板载同极性（低 = 左声道）
    ) u_i2s_tx_ext (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_mono),
        .sample_r     (sample_mono),   // ⭐ 单声道 ⇒ 左右同源（⭐ 与板载一致）
        .HP_BCK       (I2S2_BCK),
        .HP_WS        (I2S2_LRCK),
        .HP_DIN       (I2S2_DIN)
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
    // ⭐⭐ LED 演奏指引链（⭐ 丙 · 2026-09-24 接入）
    //
    //   链：`led_data`（逻辑图案，CH 序）→ `tlc5916_bank`（CH→OUT 重映射
    //       + 共享总线三片逐写 + 分板 OE）→ 顶层 `led_*` 端口。
    //
    //   ⚠️ **输入源（key_active/guide_key）当前用占位**：
    //      · `key_active`（哪些键在响）→ 正确来源应是 `event_extract` 的 16 位
    //        `key_on`，但该信号**尚未引出成 16 bit 端口**（甲的 `event_extract.v`）。
    //      · `guide_key`（哪些键该按）→ 正确来源是 `play_seq`，但**尚未例化**（甲）。
    //      ⇒ 本版先接 `1'b0`，接口已留好，等甲补输入源时**只改这两根**，⛔ 不用动
    //        `led_data` / `tlc5916_bank` 本体。
    //   ⚠️ **blink 用 `bg_beat`**（四分音符拍点，低速单周期脉冲），
    //      "下一个键"跟随拍点闪烁。
    // ═══════════════════════════════════════════════════════════════════════
    wire [23:0] led_pattern;
    wire        led_pattern_commit;
    wire        led_busy;

    // 逻辑图案层：键灯（16，CH 序）+ 状态灯（8）→ 24 bit
    led_data #(
        .KEY_N    (16),
        .STATUS_N (8)
    ) u_led_data (
        .clk_i           (clk),
        .rst_n_i         (rst_n_sync),
        .guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
        .key_active_i    (16'd0),            // ⭐ 占位：待 event_extract.key_on（甲）
        .status_i        (8'd0),             // ⭐ 占位：待 UI 状态总线
        .blink_i         (bg_beat),          // ⭐ 四分音符拍点 = 闪烁节拍
        .pattern_o       (led_pattern),
        .pattern_commit_o(led_pattern_commit)
    );

    // 物理驱动层：CH→OUT 重映射 + 共享总线三片逐写 + 分板 OE
    tlc5916_bank #(
        .KEY_CHIPS    (2),
        .STATUS_CHIPS (1),
        .OE_N         (5)
    ) u_led_bank (
        .clk_i           (clk),
        .rst_n_i         (rst_n_sync),
        .pattern_i       (led_pattern),
        .pattern_commit_i(led_pattern_commit),
        .global_blank_i  (1'b0),
        .led_sdi_o       (led_sdi),
        .led_clk_o       (led_clk),
        .led_le_o        (led_le),
        .led_oe_n_o      (led_oe_n),
        .busy_o          (led_busy)
    );

endmodule