# TORCH-4 · 顶层衔接面深扒（`rtl/top.v` + `constr/top.sdc` + `constr/top.cst`）

> 范围：**只啃顶层衔接面** —— 编译期参数分支覆盖、top 内部胶水（同步/去抖/边沿/串口多路）、
> SDC 覆盖、CST 引脚与 IO 标准、跨模块组合穿透与协议/位宽接缝。
> 每条 = `文件:行号` + 代码 + 机制（带数字）+ 改法 + 收益/代价 + **怎么验证能红**。
> 器件 GW5AT-LV60PG484AC1/I0（`GW5AT-60`，Device Version B）· clk_sys = 50 MHz（20 ns）·
> `set_max_delay 18.181 ns`（≈55 MHz）· 交付门槛 **0 setup / 0 hold 且 Fmax ≥ 51.5 MHz**。

---

## 0. 结论摘要（先看这段）

### 0.1 实测数字（全部可核，出处见 §附录 C）

| 项 | 值 | 出处 |
|---|---|---|
| Fmax（clk_sys） | **55.313 MHz** | `impl/pnr/Gowin2026_tr_content.html` Max Frequency Summary |
| Fmax 约束档 | `set_max_delay … 18.181`（**Actived**） | 同上 · Timing Constraints Report |
| Setup / Hold 违例 | **0 / 0**（TNS 0.000） | 同上 · STA Tool Run Summary |
| 分析路径 / 端点 | 50605 / 52923（其中 **26 个下降沿端点**） | 同上 |
| CLS | **23303/29952 = 78%** | `impl/pnr/Gowin2026.rpt.txt:51` |
| Logic / Register | 34507/59904 = 58%（27135 LUT + 7372 ALU）· 17039/60780 = 29% | `…rpt.txt:43-50` |
| BSRAM / DSP / IO | 33/118 · 22/118 · 66/297 | `…rpt.txt:52-66` |
| 时钟资源 | PRIMARY 2/8 · **LW 8/8 = 100%** · GCLK_PIN 10/40 · PLLA 1/8 | `…rpt.txt:91-99` |
| 时钟 | `clk_sys` 20 ns / `serial_clk` 8 ns(125 MHz) / `pixel_clk` 40 ns(25 MHz) | `…tr_content.html` Clock Summary |
| pixel_clk Fmax | 137.684 MHz | 同上 |
| serial_clk Fmax | **"No timing paths to get frequency of serial_clk!"** | 同上 |

**头号 setup 路径（唯一一条 slack < 0.2 ns）**：

```
From  g_sound.u_note_manager/g_t3.rot_cnt_0_s0
To    g_sound.u_note_manager/g_t3.phase_tr[28]_24_s0
Slack 0.102   Arrival 22.172   Required 22.274   Setup Relationship 18.181   Clock Skew 0.008
Arrival Data Path Delay: cell 4.607 (25.6%) · route 13.092 (72.6%) · tC2Q 0.331 (1.8%)
```
（`impl/pnr/Gowin2026_tr_content.html` Timing Exceptions Report / `impl/pnr/Gowin2026.timing_paths:1-41`）

### 0.2 结构性长路径 vs 布局运气 —— 裁决

**结论：这条路径「结构造出形状、布局决定长度」。59% 是两个单网，但它们之所以能长到 5 ns，
是三个结构选择造成的。**

| 段 | 延迟 | 性质 |
|---|---|---|
| `rot_cnt_0_s0/Q` → `rot_phase_20_s83/I2` | **5.264 ns**（单网，`tNET`） | 🔴 **结构**：`rot_cnt` 扇出 **595**（`…tr_content.html` High Fanout Nets Report），它是 32 项 × 32 位 `phase_r[rot_cnt]` 读地址 |
| `rot_phase_*` 4 级 LUT（32:1 mux 树） | 0.331+0.211+0.177+0.091+0.091+0.091 ≈ 0.99 ns | 结构（浅，不是主因） |
| `rot_base_*`（移位 0..3） | ≈0.9 ns | 结构 |
| `prod_w_0_s`（DSP，`MULT27X36`） | 2.534 ns（`tINS`） | 结构（1 个共享乘法器） |
| `n34284_s0`（1 级 LUT，扇出 **32**） | 0.469 ns | 结构 |
| `n34284_s0/F` → `phase_tr[28]_24_s0/D` | **5.407 ns**（单网，`tNET`） | 🔴 **布局**：驱动在 `R27C96`、终点在 `R60C141`（跨 **45 列 / 45 行**） |
| 合计数据路径 | 18.079 ns ⇒ 55.313 MHz | 逻辑 4.607 / 走线 13.092 |

**⇒ 结构上真正的病根是两条**：
1. `rot_cnt`（5 位自由计数器）直接当 **32 项寄存器堆的读地址** ⇒ 1 位就扇出 595 个 LUT 输入；
2. `prod_w`（**唯一**一个乘法器）的输出经 1 级 LUT 后扇出 **32** 路去写 1024 个 FF 的
   `phase_tr` 影子数组 ⇒ 其中一路必须横穿半个芯片。

**⇒ 布局噪声到底多大（本仓库可对照的全部样本，全部 18.181 档）**：

```
55.054  cls-nm-55p054              55.060  base-T5-55p060        55.143  headroom2-55p143
55.198  testmode1-18p181-55p198    55.294  norm-levelaware2-55p294
55.301  norm-level-aware-55p301    55.406  C-only-55p406         55.406  C-atomic-55p406
55.899  A-55p899                   56.351  merged-56p351         56.399  margin-18p181-56p399
46.613  rightboard-adc1-46p613（颤音流水未修的那一版，见 P1-6）
```
（每行取自 `evidence/h5/<目录>/Gowin2026_tr_content.html` 的 Actual Fmax）

* **同源重跑噪声 ≤ 0.25 MHz**（55.054 / 55.060 只差 **0.006 MHz**；55.05~55.30 共 6 个点落在 0.25 MHz 内）。
* **跨 RTL 变体**才是 55.05 → 56.40（**1.345 MHz**）。
* 唯一的大差 **46.613 → 55+（9.8 MHz）是结构性的**，不是运气 —— 它对应
  `oscillator_bank` 里那条纯组合的 `vibrato_mod × VIB_REF_INC`（`026ed21` 已用 2 级流水修掉，
  见 `rtl/w3b/oscillator_bank.v:314-333`）。

🔴 **对任务书前提的更正**：本仓库证据**不支持**"同源重跑差 2~3 MHz"。请把口径改成
「**同源重跑 ≤0.25 MHz；档位/结构改动 1~10 MHz**」。这条很重要 —— 因为它意味着
**当前 55.313 不是运气，是被 `g_t3` 那条结构路径钉住的**；也意味着
**门槛 51.5 MHz（19.417 ns）对当前 18.079 ns 的数据路径有 6.9% 的结构性余量，重跑不会掉下去**。

### 0.3 我已核过、确认**无缺陷**的项（写出来是为了让你别重复挖）

| 项 | 结论 | 证据 |
|---|---|---|
| `pos_to_vel` 的位宽 | ✅ 正确。`p22={10'd0,p}`（22 位）⇒ `4095×256=1048320 < 2^21`，`p22<<8` 在 22 位上下文里**不溢出**；`prod[21:10]` 最大 1051，`13'd64+1051=1115` 装得下 13 位 ⇒ 4095 档也能正确饱和到 255 | `rtl/top.v:1181-1207` |
| `am_inc_out` 与 `axis_map` 的拍对齐 | ✅ 正确。`axis_map.phase_inc_o` 是 `assign`（**0 拍组合**，`rtl/w3a/axis_map.v:547-549`）⇒ `top` 再打一拍后 `am_inc_out`/`am_vld_out`/`am_axis_out` 严格同拍 | `rtl/top.v:3244-3269` |
| `cal_ch` 仲裁的组合环 | ✅ 已被 `sp_busy_r` 切断（用寄存器而非组合输出做选择） | `rtl/top.v:2373` |
| `spi_cs_n[5:ADC_N]` 常量补位 | ✅ `ADC_N=2` ⇒ `[5:2]=4'b1111`；`ADC_N=3` ⇒ `[5:3]=3'b111` | `rtl/top.v:1727-1728` |
| `spi_miso` 采样 | ✅ 每片独立 + **2 级同步**（`gen_miso_sync[*].u_sync`），且在 SCLK 上升沿采 ⇒ 建立余量 = 半 SCLK 周期 = **500 ns**（远超 20 ns 采样周期）⇒ 见 P1-1 的"缺 input_delay 但不构成风险" | `rtl/drivers/adc_farm.sv:85-95,161-163`；`sim/evidence/final-batch-20261008/rsc.xml` |
| `pluck_up/down` | ✅ 2 级同步 + 30 ms 不应期，UP 同拍优先 | `rtl/w3a/async_pluck_capture.v:17-50` |
| `uart_ui.tx_busy_i` 硬接 `1'b1` | ⚠️ 无害：该端口在模块内**只出现在声明行**（`rtl/w3c/uart_ui.v:76-77`），从未被读 ⇒ 硬接不影响行为（但仍见 P2-4） | grep 全文件仅 2 处命中 |
| `calib_span` 的 `start_i` | ✅ **只在 `S_IDLE` 采样**（`rtl/w3a/calib_span.v:336-345`）⇒ 重发 `'S'` 不会打断进行中的 span（但**回执会说谎**，见 P1-3） | 同上 |
| 跨模块组合穿透（任务书第五条） | ✅ **没有发现"A 输出不经寄存器就进 B 的组合逻辑"式的长链**：最差 13 条 setup 路径**全部**落在 `u_note_manager/g_t3`（13 条）与 `u_tdm_render_mixer`（其余），**没有一条**是 `as_pos → event_extract → …` 这类穿透 | `impl/pnr/Gowin2026.timing_paths:1-1187` |

### 0.4 优先级索引

| 编号 | 优先级 | 一句话 |
|---|---|---|
| P0-1 | P0 | `TEST_MODE_EN=0`（交付默认）⇒ `'M'` 回 `'4'` 但整条 Test Mode 通路不在网表里（**控制面说谎**） |
| P0-2 | P0 | 综合期 **6 个 `NL0002 is swept`**，其中 5 个与 `top.v` 注释相反；综合门只数 ERROR ⇒ **模块静默消失能过门** |
| P0-3 | P0 | 头号路径 `g_t3.rot_cnt_0_s0 → phase_tr[28]_24_s0`（18.079 ns / 55.313 MHz，59% 是两个单网） |
| P0-4 | P0 | `ee_ovf`/`ee_lost`/`mg_*`/`sa_*`/`txf_ovf`/`txf_drop`/`looper_*` 全是死线 ⇒ **有界的丢事件路径零可观测** |
| P1-1 | P1 | SDC：**0 条 `set_input_delay`**、`set_output_delay` 只覆盖 3 根 `HP_*`、无 `-min` ⇒ 33 根脚零约束 |
| P1-2 | P1 | `serial_clk`（125 MHz）**零路径被 STA 分析**（"No timing paths…"） |
| P1-3 | P1 | span 进行中再发 `'S'`：回 `'s'`（受理）但状态机不理会 ⇒ **回执说谎** |
| P1-4 | P1 | `RIGHT_ADC_ENABLE=1` 档：`af_data` **36 位 → 24 位静默截断**；`N_ADC=2` 三处硬编码 ⇒ 片 2 永不 tare/span |
| P1-5 | P1 | `RESERVED_N=5` **五处独立字面量**；且 `met_cfg_warn`/`drm_cfg_warn`（配错自检）是死线 |
| P1-6 | P1 | `LW` 时钟资源 **8/8 饱和** + `PR1014 clk_d` + `clk_d` 扇出 16957（插入 4.142 ns，走线 2.854 ns） |
| P1-7 | P1 | `tb_p5_osc_equiv` 的参数（`DRUM_TOM_MAX=15M` / `SWEEP_SH=2`）≠ 生产档（`20M` / `3`）⇒ **嗵鼓扫频分支根本没被覆盖** |
| P1-8 | P1 | `DEMO_CHORD_ON=0`（M0 安全档）：`spi_sclk`/`spi_mosi`/`spi_cs_n[5:0]`/`fault_any_w` **共 9 个网无驱动**，且该档**从未过综合门** |
| P2-1 | P2 | 60+ 条"可观测性"线全是死线总表（注释声称"会保留、上板可读"不成立） |
| P2-2 | P2 | `rep_byte` 优先级链：同拍时受理回执（`'s'`/`'t'`/`'x'`/`'k'`）被高优先级事件吃掉 |
| P2-3 | P2 | `uart_ui` 的发送通路整条不存在（`tx_busy_i`/`tx_done_i` 死输入 + `ui_tx_*` 死线） |
| P2-4 | P2 | 注释 ↔ 代码不一致 5 处（含 `key_drum_inc` 表整张过期、`OUTPUT_HEADROOM_SH` 根本不是参数） |
| P2-5 | P2 | `reserved_in_xor`：7 根异步输入异或进 1 个 FF，无同步器（虽无消费者） |
| P2-6 | P2 | `u_led_data` 三个输入全是常量 + 被 swept ⇒ **演奏指引灯功能实际不存在** |
| P2-7 | P2 | `top.cst` 只有一组 `GROUP/GRP_LOC`（h5_ret），头号路径却跨 45 列 ⇒ 应给 `g_t3` 加区域约束 |
| P2-8 | P2 | `at_en_ready` 门控 ⇒ 发 `'T'` 重标期间键盘**最长 ~16 s 无响应** |
| P3-1 | P3 | `top.cst` 四条 TMDS 缺 `IO_TYPE`（实测 LVDS25 与 `TLVDS_OBUF` 一致 ⇒ 不是错，但依赖工具默认） |
| P3-2 | P3 | `DRUM_PATTERN_ID` 无范围自检（填 4 会被 `localparam [1:0]` 静默截成 0） |
| P3-3 | P3 | `=1 档 ≈57.0 MHz / CLS 81%` 只存在于 commit message，**没有机器可读证据文件** |
| P3-4 | P3 | `sim/tb_all.ps1` 实际发现 **131** 个 tb（任务书写 130）；`tb_export_*` 默认跳过 ⇒ "共 N" 的口径要写清 |
| P3-5 | P3 | `i2s_tx` 的 `JUSTIFY(0)` 命名陷阱（0 = Philips 标准 I2S，不是"左对齐"）已写进注释但仍在两处误用风险 |

---

## P0-1 · `TEST_MODE_EN=0` 交付档下，`'M'` 命令回 `'4'` 但 Test Mode 通路不在网表里（控制面说谎）

**位置**：`rtl/top.v:72`（参数值）· `rtl/top.v:67`（注释）· `rtl/top.v:1340-1342`（注释）·
`rtl/top.v:1354-1407`（两个 generate 分支）· `rtl/top.v:2391-2395`（回包字节）· `rtl/top.v:2445`（仲裁）

**代码**：

```verilog
// rtl/top.v:67（注释）
//   ✅ `1`（**默认**，诊断码流）= 行为与改动前**逐字一致**
// rtl/top.v:72（实际值）
parameter integer TEST_MODE_EN       = 0,
// rtl/top.v:1341-1342（注释）
//  📌 诊断码流（`TEST_MODE_EN=1`）**行为与改动前逐字一致**；默认值保持 1，
//     以免影响现有测试台与上板习惯。
// rtl/top.v:1395-1406（=0 分支）
end else begin : g_no_test_mode
    assign tm_enable_r    = 1'b0;
    assign tm_gate        = {POLY_TARGET{1'b0}};
    ...
// rtl/top.v:2391-2395
wire [7:0] tm_reply_byte = !tm_enable_r          ? 8'h34          // '4'
                        : (tm_n_code_r == 2'b00) ? 8'h38 ...
// rtl/top.v:2445
: cmd_test_mode_req? tm_reply_byte    // M: 4/8/A/B/0
```

**机制（带数字）**：交付档 `tm_enable_r ≡ 1'b0`（编译期常量）⇒ `tm_reply_byte ≡ 8'h34 = '4'`。
而 `rtl/top.v:1046` 的回传表把 `'4'` 定义为"**Test Mode 已切至 4**"。
⇒ 操作者每发一次 `'M'` 都收到 `'4'`，**永远不变**（`tm_n_code_q` 那套状态机在 `g_no_test_mode`
分支里**根本不存在**），而 `tm_gate/tm_vel/tm_lane_active/tm_phase_inc` 全是常量 0
⇒ 整条 FFT 验收通路（`test_mode_ctrl` 不进网表）在**交付码流里是死的**。
`test_mode_ctrl` 只在 `g_test_mode` 分支例化（`rtl/top.v:1378-1394`）。
⇒ 后果：**上板做音频验收时，`'M'` 会告诉你"已进入测试模式"，而实际没有测试音** ——
这是"全绿但没声音"家族的又一例（`R-16`/`K-69` 同族）。

**改法（二选一，推荐 ①）**：

1. **让回包说实话**（不改任何功能，1 行）：把 `tm_reply_byte` 改成
   ```verilog
   wire [7:0] tm_reply_byte = (TEST_MODE_EN == 0) ? 8'h2D          // '-' = 本码流无 Test Mode
                            : !tm_enable_r          ? 8'h34
                            : (tm_n_code_r == 2'b00) ? 8'h38
                            : (tm_n_code_r == 2'b01) ? 8'h41
                            : (tm_n_code_r == 2'b10) ? 8'h42 : 8'h30;
   ```
2. 或者把默认值改回 `1`（与注释一致），交付时再显式改 0 —— **但那样注释与代码仍然靠"记得"对齐**。

**收益 / 代价**：收益 = 控制面不再说谎，验收脚本能靠 `'-'` 自动判定"本码流无 Test Mode"；
代价 = 0（1 行、不新增逻辑、不改端口）。**必须同步更正 `rtl/top.v:67` 与 `:1341` 两处注释**
（它们现在直接与 `:72` 矛盾）。

**怎么验证能红**：新增/改造 `tb/w3b/tb_test_mode_top.sv`，加一条**默认档**用例：
例化 `top`（**不传** `TEST_MODE_EN`）→ 发 `'M'` → 断言回包 **≠ `'4'`**。
现在必然红（回的是 `'4'`）；按改法 ① 修完变绿。同时断言
`dut.g_sound.g_test_mode` 不存在（编译期即可证明）或 `tm_gate === 0`。

---

## P0-2 · 综合期 6 个 `NL0002 is swept`：其中 5 个与 `top.v` 注释相反，而综合门只数 ERROR

**位置**：`impl/gwsynthesis/Gowin2026.log`（交付构建自己的综合日志）· 对应 `top.v` 注释
`:4091` · `:4463` · `:4145` · `:1095`

**代码（综合日志原文，逐字）**：

```
WARN  (NL0002) : The module "metronome"          instantiated to "g_sound.u_metronome"       is swept in optimizing(top.v:1565)
WARN  (NL0002) : The module "param_extract"      instantiated to "g_sound.u_param_extract"   is swept in optimizing(top.v:3335)
WARN  (NL0002) : The module "pos_probe"          instantiated to "g_sound.u_pos_probe_dpos"  is swept in optimizing(top.v:3006)
WARN  (NL0002) : The module "right_analog_ctrl"  instantiated to "g_sound.u_right_analog_ctrl" is swept in optimizing(top.v:1754)
WARN  (NL0002) : The module "vibrato_lfo"        instantiated to "g_sound.u_vibrato_lfo"     is swept in optimizing(top.v:4161)
WARN  (NL0002) : The module "led_data"           instantiated to "u_led_data"                is swept in optimizing(top.v:4844)
```

**机制（带数字）**：只有 `u_pos_probe_dpos`（`DPOS_DIAG=0`）是**文档写明**该被扫掉的
（`rtl/top.v:186-196`）。另外 5 个与注释直接冲突：

| 实例 | `top.v` 注释声称 | 综合日志说 | 若"swapped = 删除"成立，则失去的功能 |
|---|---|---|---|
| `u_param_extract` | `:4091` "它的**音高**通路…**仍在用**" | swept | 手弹滑音/音高跟随（`pitch_upd_*` 只剩 looper 那一路） |
| `u_vibrato_lfo` | `:4145` "internal LFO output is Q1.15, matching oscillator_bank" | swept | 颤音（`vibrato_mod` 常 0 ⇒ `vib_off` 常 0） |
| `u_right_analog_ctrl` | `:4463` "输出 0x7FFF，保证旧硬件仍是满音量" | swept | 主音量（折叠成常量；值只能靠音频幅度 tb 间接守） |
| `u_metronome` | `:1565` 节拍器 | swept | 节拍器（`SEL_DRUM=1` 时**本该**扫掉，但 `cfg_warn` 也一起没了） |
| `u_led_data` | `:4838-4840` 三个输入是占位常量 | swept | 演奏指引灯（见 P2-6） |

**为什么这条是 P0**：本项目的第四道门是"**综合 ERROR=0**"。
`NL0002` 是 **WARN** ⇒ **一个模块整块消失也能过门**，而它带走的可能是
文档声称"仍在用"的功能。`sim/evidence/final-batch-20261008/rsc.xml` 的模块清单里
确实**没有** `g_sound.u_metronome` / `u_param_extract` / `u_vibrato_lfo` /
`u_right_analog_ctrl` / `u_led_data`，而 `u_pos_probe` / `u_span_probe` 都在 ⇒ 与日志一致。

**改法（把"看不见"变成"可判定"，3 步）**：

1. 在 `sim/gowin_build.ps1` 里加一条硬门：**日志中出现 `NL0002` 即 FAIL**，
   并配一张**显式白名单**（当前只允许 `g_sound.u_pos_probe_dpos`，附理由字符串 `DPOS_DIAG=0`）。
2. 白名单之外的每个 `NL0002` 必须在 `top.v` 的注释里写出**为什么它该被扫掉**。
3. 对 `u_param_extract` / `u_vibrato_lfo` / `u_right_analog_ctrl` 三个，
   **必须给一个"它活着"的判据**（见下）。

**收益 / 代价**：收益 = 把"注释声称的功能"与"网表里真有的功能"强制对齐；
代价 = 每次构建多一条 grep 判定（<1 s）。**不改 RTL 行为**。

**怎么验证能红**：
* 现在跑 `Select-String NL0002 impl/gwsynthesis/Gowin2026.log` ⇒ **6 条** ⇒ 新门必然红。
* 补完白名单 + 注释后应变绿；若有人手滑把 `RIGHT_ADC_ENABLE` 改回 1，
  `u_right_analog_ctrl` 会从 swept 列表消失 ⇒ 门会提示"白名单过期"，反向也能红。

---

## P0-3 · 头号时序路径：`g_t3.rot_cnt_0_s0 → g_t3.phase_tr[28]_24_s0`（18.079 ns / 55.313 MHz，59% 是两个单网）

**位置**：`rtl/w3b/note_manager.v:1515-1570`（`g_t3` 轮转核心）·
`rtl/w3b/note_manager.v:1532-1544`（`rot_phase` / `rot_base` / `prod_w`）·
证据：`impl/pnr/Gowin2026.timing_paths:1-41` · `impl/pnr/Gowin2026_tr_content.html`

**代码**：

```verilog
// rtl/w3b/note_manager.v:1518,1528-1534,1544
reg  [4:0]         rot_cnt;                                  // 自由运行 0..31
localparam integer ROT_LANES = (POLY_TARGET > 32) ? 32 : POLY_TARGET;
wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];              // ← 32 项 × 32 位寄存器堆读
wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase
                                                    : (rot_phase << base_oct_r);
wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;         // ← 唯一一个共享乘法器
```
```
// impl/pnr/Gowin2026_tr_content.html（Timing Exceptions Report / Constraint[1] Path1）
Slack 0.102 | Data Arrival 22.172 | Data Required 22.274 | Setup Relationship 18.181 | Clock Skew 0.008
Arrival Data Path Delay: cell 4.607 (25.555%) · route 13.092 (72.611%) · tC2Q 0.331 (1.834%)
  4.473  rot_phase_20_s83/I2      ← 前一段 tNET = 5.264 ns（rot_cnt_0_s0 扇出 595）
 16.765  n34284_s0/F              （扇出 32）
 22.172  g_t3.phase_tr[28]_24_s0/D ← 本段 tNET = 5.407 ns（R27C96 → R60C141）
```

**机制（带数字）**：
* `rot_cnt[0]` 扇出 **595**（High Fanout Nets Report：`g_t3.rot_cnt[0] | FANOUT 595 | WORST SLACK 0.102`）
  ⇒ 光把这一位送到 32 项 mux 的每个 LUT 输入就要 **5.264 ns**。
* 影子数组 `phase_tr` 是 **32 voice × 32 位 = 1024 FF**，`phase_tr[28]_24_s0` 被摆在 `R60C141`，
  而驱动它的 LUT 在 `R27C96` ⇒ **一个网跨 45 列 × 45 行 = 5.407 ns**。
* 两者合计 **10.671 ns = 数据路径的 59%**；纯逻辑只有 **4.607 ns**。

**改法（结构 + 布局各一刀，**都便宜**）**：

① **结构刀：给乘法器→影子数组的写口加 1 级流水**（消掉 5.407 ns 那段）
```verilog
// g_t3 内：把 prod_w 的结果先寄存，地址同步延后一拍
reg [PHASE_W+17-1:0] prod_w_r;
reg [4:0]            rot_cnt_w;
always @(posedge clk_i) begin
    if (!rst_n_i) begin prod_w_r <= 0; rot_cnt_w <= 5'd0; end
    else begin prod_w_r <= prod_w; rot_cnt_w <= rot_cnt; end
end
// 写口改用 prod_w_r / rot_cnt_w
```
* 代价：轮转窗口从 32 拍变 **33 拍**。预算：`tick_audio` 周期 = **1024 拍**，
  `tdm_render_mixer` 在 `mx_start_dly[31]`（= `ob_valid` 延 **32** 拍，`rtl/top.v:4390-4395`）
  之后才启动、只需 **34 拍** ⇒ 32+1+34+7 级流水 ≈ **74 拍**，余量 **13.8×** ⇒ **完全放得下**。
* 收益：**−5.4 ns**（数据路径 18.079 → ≈12.7 ns ⇒ Fmax 表观 ≈78 MHz）。

② **布局刀：给 `g_t3` 加一组 `GROUP/GRP_LOC`**（消掉 5.264 ns 那段的分布半径）
```text
// constr/top.cst —— 与已有的 h5_ret 同一手法（:518-523）
GROUP t3_rot = { "g_sound.u_note_manager/g_t3.rot_cnt*"
                 "g_sound.u_note_manager/g_t3.rot_phase_*"
                 "g_sound.u_note_manager/g_t3.rot_base_*"
                 "g_sound.u_note_manager/g_t3.prod_w_*"
                 "g_sound.u_note_manager/g_t3.phase_tr*" };
GRP_LOC t3_rot R[20:40]C[80:120];
```
* ⚠️ **非独占**（`CLS` 已 78%，独占会 PR0004 布不通）—— 与 h5_ret 的注释同一理由。
* 收益：把 `rot_cnt` 的 595 个负载与 1024 个 `phase_tr` FF 收进同一个矩形，
  目标是把两条 `tNET` 从 5.264/5.407 压到 ~2 ns ⇒ **再 −5~7 ns**。

**收益 / 代价**：① 约 +0.3% FF（49 位）、+0 LUT、**零功能变化**；
② 只改 `.cst`、零 RTL 风险，代价是布局自由度下降（可能把别的路径挤坏 ⇒ 必须复算全量 slack）。
**⚠️ 顺序**：先做 ①（确定性），再单独评估 ②（有副作用）。

**怎么验证能红**：
* ① 的**功能性判据**：`tb/w3b/tb_rot32_diff.sv` / `tb_transpose.sv`（都是逐位差分 tb）
  ⇒ 若流水导致差一拍，它们**必然红**（这正是它们存在的意义）。
* ①/② 的**时序判据**：重跑 PnR 后读 `impl/pnr/Gowin2026.timing_paths`，
  断言 `From` **不再是** `g_t3.rot_cnt_0_s0`；并断言 `Actual Fmax > 55.313`。
* **反向证明（防假绿）**：把 `phase_tr` 的写口接回 `prod_w`（去掉流水）⇒ Fmax 必须回落。

---

## P0-4 · 有界的丢事件路径全部"零可观测"（`ee_ovf`/`ee_lost`/`mg_*`/`sa_*`/`txf_ovf`/`txf_drop`/`looper_*`）

**位置**：`rtl/top.v:3177-3178` · `:3755-3761` · `:3981-3984` · `:1133-1134` · `:3653-3657` ·
产生方：`rtl/w3a/event_extract.v:163,307-315,323`

**代码**：

```verilog
// rtl/w3a/event_extract.v:163 —— 有界缓冲
localparam integer FIFO_D = 4;
// rtl/w3a/event_extract.v:314-315
overflow_o_r <= 1'b1;                              // ⭐ sticky
if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
// rtl/w3a/event_extract.v:323（原文注释）
//     若此刻 FIFO 满 ⇒ push 失败 ⇒ 🔴 **这条 `note_off` 永久丢失**
```
```verilog
// rtl/top.v:3177-3178 —— 接到两条【从没人读】的线上
.overflow_o       (ee_ovf),
.lost_cnt_o       (ee_lost)
```
```verilog
// rtl/top.v:1095-1096（对 tx_fifo 的原始要求）
//   🔴 **溢出可观测**（⭐ `K-106`）：⭐ `ovf_o` sticky + `drop_cnt_o` 饱和计数
//      ⛔ **没有这两个输出就【等于没修】** —— ⚠️ 只是换了个地方悄悄丢
// rtl/top.v:1133-1134
.ovf_o     (txf_ovf),
.drop_cnt_o(txf_drop),
```

**机制（带数字）**：`grep -c` 全文件计数 = **2**（= 声明 1 + 例化端口 1），
即以下 20 条线**没有任何消费者**：

```
ee_ovf ee_lost sa_overflow sa_drop_cnt sa_collision_cnt sa_merged_cnt sa_live_cnt sa_score_cnt sa_demo_cnt
mg_overflow mg_drop_cnt mg_collision_cnt mg_merged_cnt
txf_ovf txf_drop
looper_full looper_drop_cnt looper_overflow looper_evt_cnt
met_cfg_warn drm_cfg_warn
```
无消费者的寄存器**没有理由被保留** ⇒ 计数器逻辑被剪掉 ⇒
**`'P'`/`'V'` 回包之外，上板无法判断"刚才是不是丢了事件"**。
而 `event_extract` 的 FIFO 只有 **4 深**、`seq_arb`/`evt_merge` 只有 **6 深**、
`looper` 有 `EVT_MAX=2048` 上限 ⇒ **丢事件是设计内的可能事件**，
现在它 100% 静默 —— 正是 `K-106` 纪律要禁止的形态。

**改法（选 1 条即可，推荐 ①）**：

1. **把 sticky 位塞进现成的串口诊断面**：`'V'`（`span_probe`，`rtl/top.v:2162`）已经是一个
   7 字节回包。把 `ee_ovf|mg_overflow|sa_overflow|txf_ovf|looper_overflow` 折成 1 个字节，
   在 `'V'` 回包里多带 1 字节（**改 `N_BYTES(7)→8`**），或复用 `'Q'`（`DPOS_DIAG` 门控）那一格。
2. 或者**用现成的心跳灯**：`fault_any_w`（`rtl/top.v:1719`）已经在做 OR 汇合，
   把 `|{ee_ovf, mg_overflow, sa_overflow, txf_ovf}` 也 OR 进去 ⇒ **快闪 = 丢过事件**。
   ⚠️ 但要注意 `fault_sticky` 是"只复位才清"，会掩盖后续正常帧（现有注释已说明这是有意为之）。

**收益 / 代价**：收益 = 把"永久丢一条 `note_off`"变成可判定（这正是挂音类 bug 的取证工具）；
代价 = ① 多 1 字节回包（人眼无感，500 kbps 下 +20 µs）；② 零额外资源（只是把已有 OR 加宽 1 位）。

**怎么验证能红**：写一个 tb，把 `event_extract` 的 FIFO **灌满**（连发 ≥5 个同拍事件），
断言 `dut.g_sound.ee_ovf === 1'b1` **且** 该位能通过 `'V'`/心跳灯观测到。
现在必然红（观测不到）；修完变绿。

---

## P1-1 · SDC 覆盖：0 条 `set_input_delay`、`set_output_delay` 只覆盖 3 根 `HP_*`、无 `-min`

**位置**：`constr/top.sdc:62-71`（output delay + false path）· `:101-102`（max_delay）·
权威对象清单：`impl/pnr/Gowin2026_tr_content.html` **Timing Constraints Report**（共 11 条，全部 `Actived`）

**代码（SDC 全部 11 条约束，逐条对）**：

```
TC_CLOCK            Actived  create_clock -name clk_sys -period 20 …
TC_GENERATED_CLOCK  Actived  create_generated_clock … serial_clk … CLKOUT0
TC_GENERATED_CLOCK  Actived  create_generated_clock … pixel_clk  … CLKOUT1
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
TC_FALSE_PATH       Actived  set_false_path -to   [get_ports {PA_EN_n}]
TC_FALSE_PATH       Actived  set_false_path -to   [get_ports {led_heartbeat}]
TC_FALSE_PATH       Actived  set_false_path -from [get_ports {rst_n}]
TC_MAX_DELAY        Actived  set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
TC_MAX_DELAY        Actived  set_max_delay … -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```

**机制（带数字）**：
* **时钟侧：✅ 无漏项**。`Clock Summary` 恰好 3 个时钟（`clk_sys`/`serial_clk`/`pixel_clk`），
  `create_generated_clock` 的对象路径 `u_hdmi/u_clk/u_pll/CLKOUT0|1` 与 RTL 层次
  （`top.u_hdmi` → `hdmi_clk u_clk` → `PLLA u_pll`）**逐字对得上**
  （`rtl/hdmi/hdmi_scope.v:15` / `rtl/hdmi/hdmi_clk.v:16-22`）⇒ 无未约束时钟。
  第二条 `max_delay` 的 `get_regs` 通配**确实命中**（异常报告里回的是
  `To = u_hdmi/u_scope/gray_launch_3_s0`，`Latch Clk = clk_sys:[F]`，`Required 13.913`）⇒ 不是空对象。
* **引脚侧：🔴 大面积空白**。`set_input_delay` 计数 = **0**；`set_output_delay` 只覆盖
  **3 / 66** 根脚。SDC 自己的文件头（`:24-26`）就写明：
  *"在没有 `set_output_delay`/`set_input_delay` 时**不被分析**"* ⇒
  下列 **33 根脚零时序约束**：
  ```
  输出（30）：I2S2_BCK I2S2_LRCK I2S2_DIN   ← ⚠️ 外置 PCM5102A，是【在用】的输出
              led_sdi led_clk led_le led_oe_n[4:0]   ← led_clk 是移位时钟
              ctrl_row_o[3:0] ctrl_ws_o esp_uart_tx_o ws_strip_o[2:0]
              tmds_d_p_0[2:0] tmds_clk_p_0 hpd_en
  输入（全部）：uart_rx spi_miso[5:0] pluck_up_i pluck_down_i timbre_btn_i
              ctrl_col_i[3:0] enc_a_i enc_b_i enc_sw_i
              pedal_sus_i pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i
  ```
* **无 `-min`**：所有 `set_output_delay` 只有 `-max` ⇒ **输出脚没有 hold 检查**。
* **逐条判定"是真风险还是只是缺文档"**（⛔ 不要一律当风险，也不要一律放过）：
  | 脚 | 实测风险 | 依据 |
  |---|---|---|
  | `spi_miso[*]` | **不构成风险** | SCLK=1 MHz ⇒ 半周期 **500 ns**；且 `adc_farm` 里每片 **2 级同步**（`adc_farm.sv:85-95`） |
  | `pluck_up/down` `timbre_btn` `uart_rx` `pedal_*` `enc_*` `ctrl_col_i` | **不构成风险** | 全部经 `sync_input` 2 级同步（`rtl/top.v:575-584,637-646`；`async_pluck_capture.v:36-39`） |
  | `I2S2_*` | **真空白** | 与 `HP_*` **同构**（同一 `i2s_tx`、同 `bclk_en/frame_start`，`rtl/top.v:4653-4685`）⇒ 今天不会错，但**改 `u_i2s_tx_ext` 的参数（`MSB_DELAY` 0 vs 1）时工具不会报警** |
  | `led_clk`/`led_sdi`/`led_le`/`led_oe_n` | **真空白** | `tlc5916_bank` 的移位时钟，速率需实测；无约束 ⇒ 工具不优化、不检查 |
  | `ctrl_ws_o` | **真空白** | WS2812 位时序 ~1.25 µs/位（800 kHz）⇒ 今天余量大，但无约束 |
  | `tmds_*` | 由 `serial_clk`/`pixel_clk` 覆盖内部路径 | 见 P1-2 |

**改法**：

```tcl
# constr/top.sdc —— 补 ① 外置 DAC 与 HP 同档（对称性）；② 慢速脚显式 false_path；③ 输入脚按"已同步"声明
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_LRCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_DIN}]
set_false_path -to [get_ports {led_sdi led_clk led_le led_oe_n[*] ctrl_row_o[*] ctrl_ws_o ws_strip_o[*] esp_uart_tx_o hpd_en}]
set_false_path -from [get_ports {uart_rx spi_miso[*] pluck_up_i pluck_down_i timbre_btn_i \
                                 ctrl_col_i[*] enc_a_i enc_b_i enc_sw_i \
                                 pedal_sus_i pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i}]
```
⚠️ **纪律**（沿用 `constr/top.sdc:39-40` 的原文）：`set_false_path` 只给**确实不要求时序**的路径，
且必须逐条写理由。上面输入侧的 false_path 的理由是"**全部经 2 级同步器**"——
这比"不写"更诚实（不写 ⇒ 不分析，但**没人知道是有意还是漏了**）。

**收益 / 代价**：收益 = "0 违规"重新变成**有覆盖的 0 违规**（这条是任务书点名的"最阴"）；
代价 = 0 逻辑、0 时序影响；⚠️ 唯一风险是把某条**真需要**约束的路径误 false 掉 ⇒
所以 `led_clk` 建议先**量一次实际翻转率**再决定是 `false_path` 还是 `set_output_delay`。

**怎么验证能红**：改完重跑 PnR，读 Timing Constraints Report，
断言 **`TC_INPUT_DELAY` 或 `TC_FALSE_PATH` 的对象计数 = 33**；
并断言 `Numbers of Setup/Hold Violated Endpoints` 仍为 0/0。
反向：临时把 `I2S2_BCK` 的 `-max` 改成 `19.0` ⇒ 必须出现 setup 违例（证明约束真的生效）。

---

## P1-2 · `serial_clk`（125 MHz）**零路径被 STA 分析**

**位置**：`impl/pnr/Gowin2026_tr_content.html` Max Frequency Summary ·
`rtl/hdmi/tmds_serializer.v:22-33`

**代码 / 报告原文**：

```
Max Frequency Summary:
1  clk_sys     50.000(MHz)  55.313(MHz)  7  TOP
2  pixel_clk   25.000(MHz) 137.684(MHz)  8  TOP
   No timing paths to get frequency of serial_clk!
```
```verilog
// rtl/hdmi/tmds_serializer.v:22-33
OSER10 u_oser (.Q(serial[j]), .D0(lane[j][0]), … .D9(lane[j][9]),
               .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst));
```

**机制（带数字）**：`serial_clk` 是 **125 MHz / 8 ns** 的生成时钟，被 `create_generated_clock`
正确创建（Actived），但**没有任何寄存器到寄存器路径**落在它上面 ⇒ Gowin 明确打印
*"No timing paths to get frequency of serial_clk!"* ⇒ **这个时钟域完全没有 STA 覆盖**。
今天唯一的消费者是 `OSER10` 硬原语的 `FCLK`（其内部时序由原语特性保证）⇒
**当前不是缺陷**；但它是**一个已经建好时钟、却零检查的域**：
只要将来有人往 `serial_clk` 上挂一个寄存器（哪怕只是打拍），**工具不会报任何东西**。

**改法**（低风险，二选一）：

1. **加一条"存在性断言"**（推荐）：在 `sim/gowin_build.ps1` 里断言
   `No timing paths to get frequency of serial_clk` **必须出现**；
   若哪天它消失 ⇒ 说明有人在 125 MHz 域加了逻辑 ⇒ **门主动报警**要求补约束/补分析。
2. 或在 `constr/top.sdc` 里显式写一行注释块，说明"serial_clk 只进 OSER10 的 FCLK，
   不承载寄存器逻辑；若承载则必须补 `set_max_delay`"。

**收益 / 代价**：收益 = 把一个"沉默的域"变成"会叫的域"；代价 = 1 行判定。

**怎么验证能红**：往 `tmds_serializer` 里临时加 `reg dbg; always @(posedge serial_clk) dbg <= blue[0];`
⇒ 重跑 PnR ⇒ 断言那句 `No timing paths…` **消失**（即门报警）。撤掉后恢复。

---

## P1-3 · span 进行中再发 `'S'`：回 `'s'`（受理）但状态机不理会 ⇒ 回执说谎

**位置**：`rtl/top.v:1970-1971`（门控）· `:2433-2444`（回包仲裁）· `:2253`（`start_i` 接线）·
`rtl/w3a/calib_span.v:336-345`（只在 `S_IDLE` 采 `start_i`）

**代码**：

```verilog
// rtl/top.v:1970-1971
wire       sp_start_gated = cmd_span_req & at_done;        // ⚠️ 没有 ~sp_busy
wire       sp_start_rejected = cmd_span_req & ~at_done;
// rtl/top.v:2253
.start_i       (sp_start_gated),
// rtl/top.v:2433-2444（优先级：ev_need > ev_reject > ev_axis_ok > ev_done > sp_start_rejected > … > cmd_span_req）
wire rep_req = … | cmd_span_req | …;
wire [7:0] rep_byte = ev_need ? axis_char : ev_reject ? rej_why_byte : ev_axis_ok ? 8'h2E
                    : ev_done ? 8'h44 : sp_start_rejected ? 8'h21
                    : (at_done & ~at_done_r) ? 8'h54
                    : cmd_tare_req ? 8'h74 : cmd_span_req ? 8'h73   // 's' = 受理 span
                    : …;
```
```verilog
// rtl/w3a/calib_span.v:336-345 —— start_i 只在 S_IDLE 被采样
S_IDLE: begin
    need_press_o <= 1'b0;
    done_o       <= 1'b0;
    if (start_i) begin … state <= S_PROMPT; end
end
```

**机制（带数字）**：span 进行中（`state != S_IDLE && state != S_DONE`，`busy_o=1`）时
`at_done` 仍为 1 ⇒ `sp_start_rejected = 0` ⇒ 仲裁链落到 `cmd_span_req ? 8'h73`
⇒ **回 `'s'`（"已受理"）**；而 `calib_span` 此刻不在 `S_IDLE` ⇒ **`start_i` 被完全忽略**
⇒ 操作者以为"重新开始标定了"，实际**还在标上一轮**（可能已经标到第 9 轴）。
`busy_o` 的定义在 `calib_span.v:247`：`assign busy_o = (state != S_IDLE) && (state != S_DONE);`

**改法**（1 行，把"忽略"变成"明拒"）：

```verilog
wire sp_start_gated    = cmd_span_req & at_done & ~sp_busy;   // 忙 ⇒ 不放行
wire sp_start_rejected = cmd_span_req & (~at_done | sp_busy); // 忙 ⇒ 回 '!'
```
⚠️ 必须用**组合的 `sp_busy`**（不是 `sp_busy_r`）：这里的 `sp_busy` 只用于**生成回包**，
不进 `cal_ch_mux` ⇒ **不会复活 `rtl/top.v:2355-2370` 记录的那个跨模块组合环**。
（`cal_ch_mux` 那一处**必须**继续用 `sp_busy_r`，`rtl/top.v:2373` 不动。）

**收益 / 代价**：收益 = 控制面不再说谎（与 P0-1 同类）；代价 = 1 行、0 资源。

**怎么验证能红**：`tb/w3c/tb_span_axis_over_uart.log` 对应的 tb 里加：
发 `'S'` → 在收到第一个轴号后**立刻再发一个 `'S'`** → 断言第二个回包是 **`'!'`**（而不是 `'s'`）。
现在必然红。

---

## P1-4 · `RIGHT_ADC_ENABLE=1` 档：`af_data` 36 位 → 24 位**静默截断**；`N_ADC=2` 三处硬编码

**位置**：`rtl/top.v:1676`（`ADC_N`）· `:2010`（`sample_data_i`）· `:1975` `:2228` `:2536`（三处 `N_ADC(2)`）·
接收方端口宽度：`rtl/w3a/calib_autotare.v:96`

**代码**：

```verilog
// rtl/top.v:1676
localparam integer ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2;
// rtl/top.v:1678
wire [ADC_N*12-1:0] af_data;      // ADC_N=3 时是 36 位
// rtl/top.v:2010 —— 接到只有 24 位的端口
.sample_data_i (af_data[ADC_N*12-1:0]),
// rtl/w3a/calib_autotare.v:96
input  wire [N_ADC*DW-1:0] sample_data_i,      // N_ADC=2, DW=12 ⇒ 24 位
// rtl/top.v:1975 / 2228 / 2536 —— 三处都把片数写死 2
calib_autotare #( … .N_ADC    (2), … )
calib_span     #( … .N_ADC      (2), .AXIS_TOTAL (16), … )
axis_snapshot  #( … .N_ADC  (2), … )
```

**机制（带数字）**：
* `ADC_N=3` 时 `af_data` 是 **36 位**，而 `sample_data_i` 只有 **24 位** ⇒
  **高 12 位（片 2）被静默丢弃**。Verilog 的端口连接是**按表达式宽度截断**，
  工具顶多给一条宽度警告（**不是 ERROR**）⇒ 正是 `K-91` 家族"宽度不够 ⇒ 静默算错"。
  实际后果：片 2 的"静止守卫"数据恒为 0 ⇒ `calib_autotare` 的 `still_r` 判据看不到片 2
  （`calib_autotare.v:195-205` 逐片比较）⇒ 与 `rtl/top.v:2003-2009` 注释声称的
  "必须给【全部片】"**正好相反**。
* `N_ADC` 三处硬编码 **2** ⇒ **片 2（右手板 A）永远不会被 `tare` / `span` / 快照**。
  `at_tare` 只有 2 位（`rtl/top.v:1870`），`sp_span` 只有 2 位（`:1946`）。
  ⇒ `RIGHT_ADC_ENABLE=1` 档下，右手板的模拟量走的是**未标定的裸码**
  （`right_analog_ctrl` 自己做 64 点对数 LUT，所以"能用"，但**没有零点/满量程归一**）。

**改法**：

```verilog
// ① 宽度：显式截到接收方宽度（把"静默"变成"显式"，并让注释与代码一致）
.sample_data_i (af_data[N_ADC_DATA*12-1:0]),   // 其中 localparam N_ADC_DATA = 2; 并加注释说明片 2 不走标定
// ② 片数：把三处 2 换成同一个 localparam，并加编译期自检
localparam integer N_ADC_CAL = 2;              // ⭐ 参与标定的片数（≠ ADC_N）
calib_autotare #( … .N_ADC(N_ADC_CAL), … )
calib_span     #( … .N_ADC(N_ADC_CAL), … )
axis_snapshot  #( … .N_ADC(N_ADC_CAL), … )
initial if (N_ADC_CAL > ADC_N)
    $fatal(1, "N_ADC_CAL(%0d) > ADC_N(%0d) => 标定片数超过实际片数", N_ADC_CAL, ADC_N);
```
⚠️ **不要**直接把 `N_ADC` 全改成 `ADC_N`：那会把 `calib_span` 的 `AXIS_TOTAL`
（= `NCH × N_ADC`，`:2229` 传 16）与 `axis_snapshot` 的 16 轴口径一起改坏。
**先把"参与标定的片数"与"实际片数"拆成两个参数**，再决定片 2 要不要进标定。

**收益 / 代价**：收益 = 消掉一处静默截断 + 把"片 2 不标定"从**隐含**变成**显式**；
代价 = 0 逻辑（都是 localparam/注释）。

**怎么验证能红**：新增 tb 例化 `top #(.RIGHT_ADC_ENABLE(1))`，
断言 `$bits(dut.g_sound.af_data) == 36` **且** `dut.g_sound.u_autotare.sample_data_i` 的
最高 12 位**能反映片 2 的输入**（喂一个片 2 特有的码，看守卫是否看见）。
现在必然红（高 12 位恒 0）。

---

## P1-5 · `RESERVED_N=5` 五处独立字面量；配错自检 `met_cfg_warn`/`drm_cfg_warn` 是死线

**位置**：`rtl/top.v:1537` · `:1613` · `:4013` · `:4308` · `:4409` · 自检输出 `:1523` `:1564` `:1601` `:1654`

**代码**：

```verilog
// 五处【独立字面量】5 —— 只有 PERC_N 有名字
// :1537  metronome       .RESERVED_N (5),
// :1613  drum_gen        .RESERVED_N (5),
// :4013  note_manager    .RESERVED_N  (5),
// :4308  localparam integer PERC_N   = 5;
// :4409  tdm_render_mixer .RESERVED_N          (5),
// 自检输出（都只被例化端口引用一次）
// :1523 wire        met_cfg_warn;   :1564 .cfg_warn_o     (met_cfg_warn)
// :1601 wire        drm_cfg_warn;   :1654 .cfg_warn_o     (drm_cfg_warn)
// rtl/top.v:4306-4307（原文注释）
//  ⚠️ 下面这个 5 **必须**与 `u_note_manager` / `u_tdm_render_mixer` 的
//     `.RESERVED_N(5)` 一致（⭐ 三处同源…）
```

**机制（带数字）**：`RESERVED_N` 决定**最高 5 路 voice** 是保留池
（`note_manager` 的 `pool_mask`、`PERC_N` 的打击包络替换、`tdm_render_mixer` 的归一化
`NORMAL_N = POLY_TARGET - RESERVED_N` 三处**必须**同值）。
现在它被写成 **5 个互不相关的字面量**；注释说"三处同源"，**实际是五处**。
更糟：`metronome`/`drum_gen` 各自带一个 `cfg_warn_o`（专门检查 `AXIS_ID` 与 `RESERVED_N`
是否配套），**而这两根线在 `top.v` 里没有任何消费者**（`grep -c` = 2）
⇒ **"专门为防静默失效而加的自检，本身是静默的"**。

**改法**：

```verilog
// 模块级，参数表之后
localparam integer RESERVED_N = 5;   // ⭐ 单一来源
localparam integer PERC_N     = RESERVED_N;   // :4308 改为派生
// 五处例化统一写 .RESERVED_N (RESERVED_N)
// 自检消费（二选一）：
//  ① 折进心跳灯故障位（与 P0-4 的改法 ② 合并）
wire cfg_warn_any = met_cfg_warn | drm_cfg_warn;
assign fault_any_w = (|af_fault) | mx_fault | cfg_warn_any;
```

**收益 / 代价**：收益 = 改一处即全动，且配错会在**上板可见**（快闪）；
代价 = 0（一个 localparam + 一个 OR）。

**怎么验证能红**：临时把 `note_manager` 的 `.RESERVED_N` 改成 4（其余不动），
断言 (a) `met_cfg_warn`/`drm_cfg_warn` 至少一个为 1，(b) 心跳灯进入快闪档。
现在 (b) 必然不成立（线没人读）；改完成立。

---

## P1-6 · `LW` 时钟资源 **8/8 饱和** + `PR1014 clk_d` + `clk_d` 扇出 16957（插入 4.142 ns）

**位置**：`impl/pnr/Gowin2026.rpt.txt:91-99`（Clock Resource Usage）· `:103-119`（Global Clock Signals）·
`impl/pnr/Gowin2026.log`（PR1014 原文）· `impl/pnr/Gowin2026_tr_content.html`（High Fanout Nets）

**证据原文**：

```
5. Clock Resource Usage Summary
  PRIMARY       | 2/8           | 25%
  LW            | 8/8           | 100%     ← 🔴 饱和
  GCLK_PIN      | 10/40         | 25%
  PLLA          | 1/8           | 13%
6. Global Clock Signals
  clk_d               | PRIMARY | TR BR BL
  u_hdmi/pixel_clk    | PRIMARY | TR BR
  rst_n_sync          | LW      | -
  tick_audio          | LW      | -
  u_hdmi/reset_pipe[1]| LW      | -
  g_sound.u_calib_span/n1750_4 | LW | -
  g_sound.u_looper/n102894_4   | LW | -
  g_sound.u_looper/n104690_3   | LW | -
  g_sound.u_looper/pb_ax_3_8   | LW | -
  g_sound.u_evt_merge/pop_now  | LW | -
  u_hdmi/serial_clk   | HCLK    | BANK3_BANK4_BANK5_HCLK0
```
```
WARN  (PR1014) : Generic routing resource will be used to clock signal 'clk_d' by the specified
                 constraint. And then it may lead to the excessive delay or skew
```
```
High Fanout Nets Report:  clk_d | FANOUT 16957 | WORST SLACK 0.102 | MAX DELAY 3.316
                          rst_n_sync | FANOUT 13958 | WORST SLACK 5.596 | MAX DELAY 3.020
                          tick_audio | FANOUT  1415 | WORST SLACK 9.254 | MAX DELAY 2.953
Arrival Clock Path Delay: cell 1.288 (31.105%) · route 2.854 (68.895%)
```

**机制（带数字）**：
* `clk_sys` 有 **16957** 个 FF 负载，分布在 **TR/BR/BL 三个象限**；主全局时钟网喂不满
  ⇒ Gowin 用**通用布线补**（PR1014）⇒ **时钟插入延迟 4.142 ns，其中 2.854 ns 是走线**。
* 实测各分支插入差：头号路径的捕获 FF 是 **4.142 ns**，而 hold 报告里
  `u_looper/mem_*_s/CLKB` 是 **2.367 ns**（`tr_content.html` Data Required Path）
  ⇒ **跨分支时钟偏斜 ≈ 1.8 ns = 预算的 10%**（**每条路径的 slack 已含它**，
  但 **Fmax 那个数不含**）。
* `LW`（长线）资源 **8/8 = 100%** 被 `rst_n_sync`（13958 扇出）与 `tick_audio`（1415）
  这类**本不该占时钟资源**的信号吃掉 ⇒ **再加一个高扇出信号，工具就必须把某个现有信号
  踢到通用布线** ⇒ 时序会**不可预测地跳**。这就是"布局噪声"的真正注入点。

**改法（按性价比排序）**：

1. **降 `rst_n_sync` 的扇出**（13958 ⇒ 分域/分级缓冲）：它是同步复位，
   13958 个负载放在一根 LW 线上**既占资源又造成 3.020 ns 的到达延迟**。
   最省事的做法：在 `top.v` 里把 `rst_n_sync` 打一拍生成**区域副本**没有意义（同网），
   真正有效的是**把部分模块的复位改成"门控时钟使能"或用局部同步复位**——
   ⚠️ 这是大改，**本轮不做**，只登记。
2. **把 `tick_audio` 从 LW 上摘下来**：它是**时钟使能**，不是时钟。
   现在它被工具提升成时钟网（1415 扇出）。可试的做法是在 `.cst`/综合属性上
   禁止提升（Gowin 支持 `(* syn_keep *)`/`CLK` 属性），或把它改成
   **局部再生的使能**（每个消费模块自己用 10 位计数器产生），从根上消掉高扇出。
3. **登记为"容量红线"**：把 `LW 8/8` 与 `PRIMARY 2/8` 写进 `sim/gowin_build.ps1` 的
   判据里（**利用率 ≥ 100% 即 WARN，且任何新增时钟类信号必须重跑并对比 Fmax**）。

**收益 / 代价**：收益 = 把"改一处 → Fmax 乱跳"变成"可解释、可预警"；
代价 = 3 是 0 成本；1/2 是中改（有回归风险，建议单独一轮）。

**怎么验证能红**：在 `top.v` 里临时加一个 `reg [9:0] dummy; always @(posedge clk) dummy <= dummy+1;`
并把 `dummy[0]` 引到一个新的 `(* syn_keep *)` 高扇出网（模拟"再加一个时钟类信号"）⇒
重跑 PnR ⇒ 断言 `LW` 利用率与 `clk_d` 的 `MAX DELAY` **必须变化**（说明红线是真的）。

---

## P1-7 · `tb_p5_osc_equiv` 的参数 ≠ 生产档 ⇒ **嗵鼓扫频分支根本没被覆盖**；ref 也没有 `DRUM_CLS_EXT`

**位置**：`tb/w3b/tb_p5_osc_equiv.sv:65-68`（ref 参数）· `:81-90`（dut 参数）· `:190-193`（激励 C）·
`tb/models/oscillator_bank_ref.v:192`（参数表末尾）· `rtl/top.v:4205-4206`（生产档覆盖）·
`rtl/w3b/oscillator_bank.v:183-184,204`

**代码**：

```verilog
// tb/w3b/tb_p5_osc_equiv.sv:65-68（ref）与 :81-90（dut）—— 两侧【同参数】
.DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
.DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),
.DRUM_CLICK_EN(0)                       // ⚠️ ref 的参数表就到此为止（无 DRUM_CLS_EXT）
// tb/w3b/tb_p5_osc_equiv.sv:190-193（激励 C，注释写着"扫频是本次搬动的重点"）
base_inc[0] = 32'd5_368_709;     // 底鼓
base_inc[1] = 32'd17_895_697;    // 嗵鼓   ← ⚠️ 17.9M ≥ 15M ⇒ 既不是 kick 也不是 tom！
base_inc[2] = 32'd17_179_869;    // 军鼓
base_inc[3] = 32'd171_798_691;   // 踩镲
// rtl/top.v:4205-4206（生产档覆盖）
.DRUM_TOM_MAX     (20_000_000),
.DRUM_TOM_SWEEP_SH(3),
// rtl/w3b/oscillator_bank.v:183-184（模块默认）
parameter integer DRUM_KICK_MAX     = 10_000_000,
parameter integer DRUM_TOM_MAX      = 15_000_000,
```

**机制（带数字）**：
* 分类判据（`rtl/w3b/oscillator_bank.v:400-405`）：
  `is_kick = bv < 10M`、`is_tom = 10M ≤ bv < 15M`（tb 档）。
  激励 C 的 **嗵鼓 17_895_697 = 17.9M ≥ 15M** ⇒ `is_kick=0 && is_tom=0`
  ⇒ `sweep_load = 0`（`:417`）⇒ **这一 lane 根本不扫频**。
  4 条 lane 里只有 **lane 0（底鼓 5.37M）** 真的走扫频 ⇒
  **`DRUM_TOM_SWEEP_SH` 这条算术分支在逐位等价 tb 里一次都没执行过**。
* 生产档用的是 `DRUM_TOM_MAX=20M` / `DRUM_TOM_SWEEP_SH=3`
  ⇒ **交付档的嗵鼓扫频（17.9M 落进 [10M,20M) ⇒ 会扫，深度 `>>11`）从来没有与 ref 比对过**。
* `tb/models/oscillator_bank_ref.v` **确实同步了颤音流水**（`026ed21`，`:281-300`，与
  `rtl/w3b/oscillator_bank.v:314-333` 逐字对应）⇒ **这一处已经对了**；
  但 ref **没有 `DRUM_CLS_EXT` / `drum_cls_i`**（参数表末尾是 `DRUM_CLICK_EN`，
  `oscillator_bank_ref.v:192`）⇒ 生产档 `.DRUM_CLS_EXT(1)` 的路径**只能靠
  `tb_osc_drum_cls.sv` 的功能判据**，**没有逐位等价判据**。

**改法**（三处，都便宜）：

```verilog
// ① tb_p5_osc_equiv.sv：把两侧参数改成【生产档】，并把激励 C 的嗵鼓放进 20M 档
.DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(3),
.DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(20_000_000),
// ② 加一条"参数一致性断言"：dut 与 ref 的 4 个鼓参数必须逐字相等（现在靠人眼看）
initial begin
    if (u_dut.DRUM_TOM_MAX !== u_ref.DRUM_TOM_MAX ||
        u_dut.DRUM_TOM_SWEEP_SH !== u_ref.DRUM_TOM_SWEEP_SH)
        $fatal(1, "drum params diverge: ref=(%0d,%0d) dut=(%0d,%0d)",
               u_ref.DRUM_TOM_MAX, u_ref.DRUM_TOM_SWEEP_SH,
               u_dut.DRUM_TOM_MAX, u_dut.DRUM_TOM_SWEEP_SH);
end
// ③ 给 ref 补 DRUM_CLS_EXT/drum_cls_i（与 RTL 同步），并新增一档激励：
//    对 dut 传 .DRUM_CLS_EXT(1) + 手写 drum_cls_i，ref 用参数化等价路径
```
⚠️ **纪律**（写进 tb 头部注释）：**`tb/models/*_ref.v` 是"基线副本"，
凡改动被测模块的**算术或参数语义**，必须同步 ref 并同步 tb 的参数**，
否则逐位等价会变成**假红**（参数不同）或**假绿**（两侧同源、一起错）。

**收益 / 代价**：收益 = 把交付档真正跑的那条扫频算术纳入逐位等价保护；
代价 = tb 跑得稍慢（多一条 lane 参与扫频），**无 RTL 改动**。

**怎么验证能红**：把 `rtl/w3b/oscillator_bank.v:414` 的
`bv >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH)` 改成 `bv >> DRUM_SWEEP_LSB_SH`
（去掉嗵鼓深度）⇒ **现在必须仍然绿**（证明未覆盖），改完 tb 后**必须红**。

---

## P1-8 · `DEMO_CHORD_ON=0`（M0 安全档）：9 个网无驱动，且该档**从未过综合门**

**位置**：`rtl/top.v:1235-1268`（`g_silent` 全部内容）· 对照 `:1723-1728`（`g_sound` 才驱动 SPI）·
`:1719`（`fault_any_w` 只在 `g_sound` 驱动）· `:4789`（读 `fault_any_w`）

**代码**：

```verilog
// rtl/top.v:1235-1268 —— g_silent 里的【全部】assign，逐条列全：
assign pp_push = 1'b0;              assign pp_data = 8'h00;
assign scope_sample = 24'sd0;       assign scope_valid = tick_audio;
assign sample_mono = {SAMPLE_W{1'b0}};
assign tx_req  = 1'b0;              assign tx_byte = 8'h00;
assign led_blink = 1'b0;            assign led_beat = 1'b0;
assign led_gear_st = 2'd3;          assign led_looper_st = 2'd0;
// ⛔ 没有：spi_sclk / spi_mosi / spi_cs_n[*] / fault_any_w
// rtl/top.v:1723-1728（只有 g_sound 里有）
assign spi_sclk = af_sclk[0];   assign spi_mosi = af_mosi[0];
assign spi_cs_n[ADC_N-1:0] = af_cs_n;   assign spi_cs_n[5:ADC_N] = {(6-ADC_N){1'b1}};
// rtl/top.v:1719（只有 g_sound 里有）
assign fault_any_w = (|af_fault) | mx_fault;
// rtl/top.v:4789（两个分支都要读）
else if (fault_any_w)    fault_sticky <= 1'b1;
```

**机制（带数字）**：`DEMO_CHORD_ON=0` ⇒ `g_silent` ⇒
**8 个输出脚无驱动**（`spi_sclk` `spi_mosi` `spi_cs_n[5:0]`，而 `constr/top.cst:208-272`
把这 8 根**全部**做了 `IO_LOC`）+ **1 个内部网无驱动**（`fault_any_w`）。
* 仿真里：`spi_*` 是 `z`（`tb_top_m0` 不看它们，所以**不会红**）；
  `fault_any_w` 是 `z` ⇒ `if (z)` 为假 ⇒ 心跳走慢闪 ⇒ **看起来完全正常**。
* 综合里：无驱动的输出网要么被接 0 要么报 `CV`/`EX` 警告；
  `fault_any_w` 的 `z` 会被当 0 ⇒ `fault_sticky` 在该档**永远为 0** ⇒
  "有故障 ⇒ 快闪"这个语义**在该档结构性失效**。
* 关键：**13 个 tb 覆盖 `DEMO_CHORD_ON`，但 `g_silent` 这一支从来没有被综合过**
  （`sim/gowin_build.ps1` 只跑默认参数）⇒ 综合门**没见过这一档**。

**改法**：

```verilog
// g_silent 里补齐（与 g_sound 同语义的"安全常量"）
assign spi_sclk   = 1'b0;                    // ⭐ SPI 空闲（SCLK 低）
assign spi_mosi   = 1'b0;
assign spi_cs_n   = 6'b111111;               // ⭐ CS 高 = 全部不选中
assign fault_any_w = 1'b0;                   // ⭐ 该档没有 ADC/mixer ⇒ 无故障源
```
**并且**把 `g_silent` 纳入综合门：`sim/gowin_build.ps1` 增加一次
`-DEMO_CHORD_ON 0` 的**综合-only**（不跑 PnR，省 10 分钟）跑，判据 `ERROR=0`。

**收益 / 代价**：收益 = M0 安全档从"只在仿真里成立"变成"综合层也成立"；
代价 = 4 行 assign + 一次综合（~1 分钟）。

**怎么验证能红**：现在对 `g_silent` 跑一次综合 ⇒ **必然出现无驱动/未约束告警**；
补齐后消失。仿真侧可加断言：`tb_top_m0` 里 `$display("%b", dut.spi_cs_n)` 应为 `6'b111111`
（现在是 `zzzzzz`）。

---

## P2-1 · 60+ 条"可观测性"线全是死线（注释声称"会保留、上板可读"不成立）

**位置**：`rtl/top.v` 多处；清单见下

**代码（代表性三条，注释与现实的对照）**：

```verilog
// rtl/top.v:1324-1327（注释）
//      ⚠️ 未引到引脚 ⇒ ⭐ 综合时**不要**被优化掉：⭐ 它驱动的是寄存器树
//         （⭐ 与 `mg_*` 那组同一手法）⇒ ⭐ 会保留，⭐ 上板可用调试核读。
wire [$clog2(POLY_TARGET):0]   mx_n_active;
// rtl/top.v:3585-3586（注释）
//  ⭐ 可观测（`K-106`：⛔ 不许静默失效）—— ⚠️ **暂未接上板观测口**
//     📌 待办：⭐ 接到串口回传 … ⇒ 现在先留线，⛔ 不悬空
wire        looper_full;  wire [15:0] looper_drop_cnt;  wire looper_overflow;
```

**机制（带数字）**：对 `top.v` 逐名 `grep -c`，命中数 = 2（= 声明 + 例化端口）的
**可观测性线共 60+ 条**：

| 组 | 线 |
|---|---|
| `event_extract` | `ee_ovf` `ee_lost` `ee_slide_v` `ee_two_v` `ee_slide_ax` `ee_slide_dir` `ee_2a` `ee_2b` |
| `seq_arb` | `sa_overflow` `sa_drop_cnt` `sa_collision_cnt` `sa_merged_cnt` `sa_live_cnt` `sa_score_cnt` `sa_demo_cnt` |
| `evt_merge` | `mg_overflow` `mg_drop_cnt` `mg_collision_cnt` `mg_merged_cnt` |
| `uart_tx_fifo` | `txf_ovf` `txf_drop` |
| `looper` | `looper_full` `looper_drop_cnt` `looper_overflow` `looper_evt_cnt` `looper_layer_state` |
| `tdm_render_mixer` / `oscillator_bank` | `mx_n_active` `ob_phase_dbg` |
| `vibrato_lfo` | `vibrato_rate_inc` `vibrato_phase` `vibrato_active` |
| `metronome` / `drum_gen` | `met_beat_cnt` `met_accent_cnt` `drm_evt_cnt` `drm_step_cnt` `drm_hit_cnt` `drm_step_evt_cnt` `met_cfg_warn` `drm_cfg_warn` |
| `perc_env_bank` | `perc_retrig_cnt` `perc_busy` `perc_active` |
| `calib*` | `cal1_ch` `cal1_vld` `at_fail` |
| `uart_ui` | `ui_tx_start` `ui_tx_data` `ui_frame_cnt` `ui_resync_cnt` `ui_err_cnt` `ui_hb_ready` `ui_fx_en` `ui_fx_sel` |
| `calib_cmd` / `evt_uart_rx` | `cmd_cnt` `cmd_in_frame_cnt` `cmd_resync_cnt` `cmd_unknown_cnt` `cmd_idx` `eu_frame_cnt` `eu_resync_cnt` `eu_hdr_err_cnt` `eu_drop_cnt` `eu_idx` `eu_synced` |
| probe | `pp_busy` `np_busy` `vp_busy` `dp_busy` |
| LED | `led_busy` |

**结论**：`top.v:1325` 那句"它驱动的是寄存器树 ⇒ 会保留"**不成立** ——
**没有消费者的寄存器没有保留的理由**，工具会剪。所以"先留线"**不等于**"可观测"
（`rtl/top.v:3586` 的注释自己写了"暂未接上板观测口"，但那句"⛔ 不悬空"是**误导**）。

**改法**：与 P0-4 同一处方 —— **至少把"丢事件/溢出"那一类（`ee_*`/`sa_*`/`mg_*`/`txf_*`/`looper_*`）
接进一个可读的口**（`'V'` 回包多 1 字节，或心跳灯故障位）。
其余纯调试计数器**允许**被剪掉，但**必须把注释改成实话**（"未接观测口 ⇒ 会被综合剪掉，
要用时再引"），否则下一个人会以为它在网表里。

**收益 / 代价**：收益 = 注释不再骗人 + 关键计数器真的能读；代价 = 见 P0-4。

**怎么验证能红**：`grep -c` 的判据可以机械化：
在 `sim/gowin_build.ps1` 里对 `top.v` 跑一次
"凡 `wire` 声明且只出现 2 次的名字，必须出现在一张**已知死线白名单**里"，
白名单外的出现即 WARN。这样**新增死线会被立刻发现**。

---

## P2-2 · `rep_byte` 优先级链：同拍时受理回执（`'s'`/`'t'`/`'x'`/`'k'`）被高优先级事件吃掉

**位置**：`rtl/top.v:2433-2447`

**代码**：

```verilog
wire rep_req  = ev_need | ev_reject | ev_axis_ok | ev_done
              | cmd_tare_req | cmd_span_req | cmd_abort_req | cmd_test_mode_req
              | sp_start_rejected | (at_done & ~at_done_r) | cmd_keydrum_req;
wire [7:0] rep_byte = ev_need          ? axis_char        // ①
                    : ev_reject        ? rej_why_byte      // ②
                    : ev_axis_ok       ? 8'h2E             // ③ '.'
                    : ev_done          ? 8'h44             // ④ 'D'
                    : sp_start_rejected? 8'h21             // ⑤ '!'
                    : (at_done & ~at_done_r) ? 8'h54       // ⑥ 'T'
                    : cmd_tare_req     ? 8'h74             // ⑦ 't'
                    : cmd_span_req     ? 8'h73             // ⑧ 's'
                    : cmd_test_mode_req? tm_reply_byte
                    : cmd_keydrum_req  ? 8'h6B
                    :                    8'h78;            // 'x'
```

**机制（带数字）**：仲裁器**每拍只推 1 字节**（`u_tx_fifo` 的 `push_i(tx_req)` 是单拍）。
若 `cmd_span_req` 与 `ev_axis_ok`（轴标定通过）**同拍**（窗口 = 1 clk = **20 ns**），
`rep_byte` 选 ③ `'.'` ⇒ **`'s'` 受理回执永久丢失**（`rep_req` 是 OR，两件事都请求了，
但字节只有一个）。同类可被吃掉的还有 `'t'`（被 ①②③④⑤⑥ 吃）、
`'x'`（被 ①~⑨ 吃）、`'k'`（被 ①~⑩ 吃）。
概率极低（20 ns / 人按键毫秒级），但**后果是"发 `'S'` 没回执 ⇒ 操作者再发一次"**，
而"再发一次"正好撞上 P1-3（忙时回 `'s'` 但被忽略）⇒ **两次都以为成功了**。

**改法**：把 `rep_*` 也做成**小 FIFO**（与 `u_tx_fifo` 同构，深度 4），
即"事件到达即入队，出队再发"。`u_tx_fifo` 已经存在且深度 8
（`rtl/top.v:1123`），**最小改法**是把 `rep_req/rep_byte` 那一段的"每拍选一个"
换成"两个都入队"：

```verilog
// 概念改法：把 ev_* 与 cmd_* 分成两个独立请求源，各自入 tx_fifo（FIFO 已能排队）
assign tx_req  = rep_ev_req | rep_cmd_req | pp_push | vp_push | np_push | …;
assign tx_byte = rep_ev_req ? rep_ev_byte
               : rep_cmd_req ? rep_cmd_byte
               : np_push ? np_data : … ;
```
（`rep_ev_*` = ①②③④⑥；`rep_cmd_*` = ⑤⑦⑧⑨⑩⑪。两组**结构上很少同拍**，
真正同拍时 FIFO 会排队 ⇒ 一个都不丢。）

**收益 / 代价**：收益 = 回执不再丢；代价 = 极端情况下回包顺序变化（`'s'` 可能晚 1 字节 = 20 µs）。

**怎么验证能红**：写一个 tb 用 `force` 让 `cmd_span_req` 与 `sp_done_cnt` 变化**同拍**，
断言串口**同时**收到 `'.'` 与 `'s'`（顺序不限）。现在必然只收到 `'.'`。

---

## P2-3 · `uart_ui` 的发送通路整条不存在

**位置**：`rtl/top.v:918-919`（硬接）· `:920-921`（输出接到死线）· `rtl/w3c/uart_ui.v:76-77`

**代码**：

```verilog
// rtl/top.v:918-921
.tx_busy_i     (1'b1),       // 本版只接收屏的控制帧
.tx_done_i     (1'b0),
.tx_start_o    (ui_tx_start),
.tx_data_o     (ui_tx_data),
// rtl/w3c/uart_ui.v:76-77 —— 这两个端口在模块内【只出现在声明行】
input  wire        tx_busy_i,          // ⭐ tx 忙（⛔ 别喂新字节）
input  wire        tx_done_i,          // ⭐ tx 发送完成（单周期脉冲）
```

**机制（带数字）**：`grep` 全文，`tx_busy_i`/`tx_done_i` 各只命中 **1 次**（就是声明行）
⇒ 硬接 `1'b1`/`1'b0` **今天不影响行为**（所以不是 P0）；但
`ui_tx_start`/`ui_tx_data` 命中 **2 次**（声明 + 端口）⇒ **没有接到 `u_tx_fifo`**
⇒ **串口屏永远收不到任何回传**。这意味着"屏上显示状态"这条路**完全没接**，
而 `rtl/top.v:885-887` 的注释只说"本版只接收屏的控制帧" ⇒ **没有写"屏收不到任何东西"**。

**改法**：二选一 ——
① 把 `ui_tx_start`/`ui_tx_data` 接进 `u_tx_fifo` 的 `push_i`/`data_i`
（与 `pp_push`/`vp_push` 同构，`rtl/top.v:2470-2476` 的仲裁器加一路）；
② 若确认不要屏回传，**删掉这 4 个端口连接**并把注释改成"屏的发送通路未接，屏上不会有任何回显"。

**收益 / 代价**：① 收益 = 屏可用；代价 = 多一路仲裁（注意 P2-2 的排队问题）。
② 收益 = 注释不再误导；代价 = 0。

**怎么验证能红**：现有 `sim/evidence/tb_uart_ui.log` 对应的 tb 只验了"收"。
加一条：发一个需要回包的屏帧 ⇒ 断言 `dut.uart_tx` 上有波形。现在必然红。

---

## P2-4 · 注释 ↔ 代码不一致 5 处（本项目的高复发缺陷类）

| # | 位置 | 注释说 | 代码是 | 后果 |
|---|---|---|---|---|
| 1 | `rtl/top.v:67` vs `:72` | "`1`（**默认**，诊断码流）" | `TEST_MODE_EN = 0` | 见 **P0-1**（控制面说谎） |
| 2 | `rtl/top.v:1341` vs `:72` | "默认值保持 1" | `= 0` | 同上 |
| 3 | `rtl/top.v:3776-3779` | 表：`2'd0`=嗵鼓 `12_884_902` · `2'd1`=底鼓 `6_442_451` · `2'd2`=军鼓 `17_179_869` · `2'd3`=踩镲 `171_798_691` | `:3798-3801`：`17_895_697` / `5_368_709` / `42_949_673` / `171_798_691` | 🔴 **整张表过期**。✅ 但代码与 `rtl/w3c/drum_gen.v:161-167` 的 `INC_*` **逐字一致**（已逐条核）⇒ 是**注释**错，不是逻辑错 |
| 4 | `rtl/top.v:3808` | "参照鼓机的 `VEL_*`（底鼓 230 / 军鼓 200 / 嗵鼓 190 / 踩镲 140）" | `:3810-3813`：`200/230/210/175`；而 `top` 又把鼓机覆盖成 `SNARE 235 / HIHAT 175 / TOM 220`（`:1627-1629`） | 三套数并存 ⇒ 调音时按注释改会改错对象 |
| 5 | `rtl/top.v:4306-4307` | "**三处**同源" | `RESERVED_N` 实为 **五处** | 见 **P1-5** |
| 6 | `rtl/top.v:4413` | （任务书/交接把它列为"编译期参数 `OUTPUT_HEADROOM_SH`"） | `.OUTPUT_HEADROOM_SH  (1)` 是**字面量**，`top` **没有**这个参数 | 🔴 **A/B 对比必须改源码**，不能靠构建参数 ⇒ 与"编译期可切"的说法不符 |

**改法**：逐条按"代码为准"改注释（本项目已有裁定：**代码就是地面真相**，
见 `AGENTS.md` §五⑤）。第 6 条建议**真的提成参数**：

```verilog
parameter integer OUTPUT_HEADROOM_SH = 1,   // ⭐ −6.02 dB；0 = 不衰减
…
.OUTPUT_HEADROOM_SH  (OUTPUT_HEADROOM_SH)
```

**收益 / 代价**：收益 = 消掉一整类"照注释改错"的事故；代价 = 0（第 6 条多 1 个参数 = 1 个新变异点）。

**怎么验证能红**：把 `tb/w3c/tb_drum_timbre_top.sv` 或 `tb_key_drum.sv` 里
"鼓机 INC 常量"的比对**改成从 `drum_gen` 里读 `INC_*`**（现在 `tb_key_drum` 已经这么做 ✅）
⇒ 然后**断言 `top.v` 注释里的 4 个数与 `u_drum_gen.INC_*` 相等** ⇒ 注释错会红。
（注释级的判据可以用一条 `grep` 做，不必等仿真。）

---

## P2-5 · `reserved_in_xor`：7 根异步输入异或进 1 个 FF，无同步器

**位置**：`rtl/top.v:4898-4906`

**代码**：

```verilog
(* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_i, enc_a_i, enc_b_i, enc_sw_i,
                                            pedal_loop_rec_i,
                                            pedal_loop_play_i, esp_uart_rx_i};
(* syn_keep = 1 *) reg  reserved_in_r;
always @(posedge clk) begin
    if (!rst_n_sync) reserved_in_r <= 1'b0;
    else             reserved_in_r <= reserved_in_xor;
end
```

**机制（带数字）**：这 7 根是**板外异步**输入（`.cst` 全部 `PULL_MODE=UP`），
异或树的输出直接进 1 个 FF ⇒ **该 FF 会亚稳态**（无 2 级同步）。
今天无害：`reserved_in_r` 命中 **2 次**（声明 + 赋值）⇒ **无人读** ⇒ 会被剪。
但它是"为了让脚活着"而故意保留的（`syn_keep`），
⇒ **在时序/CDC 检查里会留一条噪声路径**，且下一个人接入真逻辑时
**会顺手用这根没同步的线**（注释里正好写着"接入功能逻辑时把它从异或归并里摘掉"，
但没人提醒"这根线本身没同步"）。

**改法**：把 `reserved_in_r` 换成"每根输入各过一个 `sync_input` 再异或"
（7 × 2 = 14 个 FF，成本可忽略），或至少在注释里写明
"**本网仅用于让脚进网表，⛔ 不可当数据用（无同步器）**"。

**收益 / 代价**：收益 = 消掉一个未来会踩的坑 + 少一条 CDC 噪声；代价 = 14 FF（本器件 60780 ⇒ 0.02%）。

**怎么验证能红**：把 `reserved_in_xor` 的某一根输入在 tb 里**异步翻转 1000 次**，
断言 `reserved_in_r` 的采样子序列**不出现 `x`**。现在可能出 `x`（亚稳态传播）。

---

## P2-6 · `u_led_data` 三个输入全是常量 + 被 swept ⇒ 演奏指引灯功能实际不存在

**位置**：`rtl/top.v:4832-4844`

**代码**：

```verilog
led_data #(.KEY_N(16), .STATUS_N(8)) u_led_data (
    .guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
    .key_active_i    (16'd0),            // ⭐ 占位：待 event_extract.key_on（甲）
    .status_i        (8'd0),             // ⭐ 占位：待 UI 状态总线
    .blink_i         (led_blink),        // ⭐ 四分音符拍点
    .pattern_o       (led_pattern),
    .pattern_commit_o(led_pattern_commit));
```

**机制（带数字）**：三个数据输入是**编译期常量**，`blink_i` 是唯一的变量；
若 `led_data` 的逻辑在"全 0 输入"下与 `blink` 无关（极可能），
则 `pattern_o` 折叠成常量 ⇒ 综合日志里出现
`WARN (NL0002): The module "led_data" … is swept in optimizing(top.v:4844)`
（见 P0-2）⇒ **16 颗键灯 + 8 颗状态灯全是死的**，
而 `tlc5916_bank` 仍在**每次 `pattern_commit` 时把常量图案移位输出**（白跑 SPI）。
注释自己写了"待甲补输入源" ⇒ 功能缺失是**已知**的；
但**没人知道它在网表里已经被整块扫掉了**（`rsc.xml` 里没有 `u_led_data`）。

**改法**：
① 短期：把注释改成"**当前为占位常量 ⇒ 综合会把 `u_led_data` 整块扫掉（NL0002），
灯带恒灭**"，并把它加进 P0-2 的白名单；
② 中期：把 `event_extract` 的 16 位 `key_on` 引出来（现在 `rtl/top.v:4819-4820`
的注释说"尚未引出成 16 bit 端口"）⇒ 接 `key_active_i`。

**收益 / 代价**：① 0 成本；② 收益 = 演奏指引灯可用（评分项），
代价 = 多 16 位端口 + 一次 PnR（要重核时序）。

**怎么验证能红**：加 tb 断言 `dut.u_led_data` 存在（用层次引用强制不被剪）⇒ 现在会红。

---

## P2-7 · `top.cst` 只有一组 `GROUP/GRP_LOC`（h5_ret），头号路径却跨 45 列

**位置**：`constr/top.cst:512-523`（现有唯一一组）· 头号路径位置见 P0-3

**代码**：

```text
// constr/top.cst:512-523
// H5 (2026-10-02): targeted LOOSE region for the calibration return-path cone.
// Why: with H5 merged, the worst setup path is
//   g_sound.u_calib_span/reject_o -> u_tx_fifo/mem_*[1]/D
// with 20.303 ns of ROUTING (92% of the 22.08 ns path) …
GROUP h5_ret = { "tx_byte_*" "u_tx_fifo/*" "g_sound.u_calib_span/reject_o_*" };
GRP_LOC h5_ret R[45:73]C[1:148];
```

**机制（带数字）**：项目已经证明"**用 `GROUP/GRP_LOC` 把锥体收进一个矩形**"是有效的
（h5_ret 这一组正是为 92% 走线的路径做的）。而**当前**头号路径
（`n34284_s0` @ `R27C96` → `phase_tr[28]_24_s0` @ `R60C141`）**没有任何区域约束**
⇒ 5.407 ns 的单网。**同一手法没有用到最需要它的地方。**

**改法**：见 P0-3 的 ②（`GROUP t3_rot` + 非独占 `GRP_LOC`）。
⚠️ 两条纪律：① `GROUP` 与 `GRP_LOC` **必须成对**（Gowin SUG1018 2.4.1，`top.cst:518` 已写明）；
② `CLS` 已 **78%** ⇒ **必须非独占**，否则会 `PR0004`（本项目已有 `T3 数组+mux` 版
490 根不布通的先例，见 `rtl/top.v:325-327`）。

**收益 / 代价**：收益 = 直接打掉 5.4 ns（见 P0-3）；代价 = 布局自由度下降，**可能挤坏别的路径**
⇒ 必须"改前改后各留一份 `timing_paths` 对比"。

**怎么验证能红**：改完断言 `phase_tr[28]_24_s0` 的 `LOC` 与驱动它的 LUT 的 `LOC`
在**同一 `R[20:40]C[80:120]` 矩形内**，且该网 `tNET < 2.5 ns`。

---

## P2-8 · `at_en_ready` 门控 ⇒ 发 `'T'` 重标期间键盘**最长 ~16 s 无响应**

**位置**：`rtl/top.v:1920-1927`（延迟链）· `:3162`（接 `event_extract.enable_i`）·
`rtl/w3a/calib_autotare.v:67-71,99-111,243-245`

**代码**：

```verilog
// rtl/top.v:1920-1927
localparam integer AT_EN_DELAY = 16;
always @(posedge clk) … at_done_dly <= {at_done_dly[AT_EN_DELAY-2:0], at_done};
wire at_en_ready = at_done_dly[AT_EN_DELAY-1];
// rtl/top.v:3162
.enable_i         (at_en_ready),
// rtl/w3a/calib_autotare.v:101-103（注释）
//   ⭐ 做法：⭐ 从 `ST_DONE` 收到 `retrig_i` ⇒ ⭐ **直接跳 `ST_SWEEP`**（⛔ 不重新等 `DELAY_CLK`）
// rtl/w3a/calib_autotare.v:69-70
parameter integer STILL_FRAMES = 4,
parameter integer WAIT_MS      = 1000,     // ⭐ 单通道最长等待（ms）
```

**机制（带数字）**：`'T'` ⇒ `retrig_i` ⇒ `state` 从 `ST_DONE` 跳到 `ST_SWEEP`
⇒ `at_done` 落 0 ⇒ **`event_extract.enable_i = 0`** ⇒ **不判任何按键**（设计如此，防脏值）。
标定时长 = 逐通道等"连续 4 帧静止"（4 × 500 µs = **2 ms**）**或** `WAIT_MS` 超时（**1000 ms**）
⇒ 8 通道 × 2 片 = **16 个轴** ⇒ 若每个轴都因手在动而超时，**最长 16 × 1 s = 16 s**。
⇒ 上板时"按了 `'T'` 之后琴有十几秒不响"**看起来像死机**。
（对比：`rtl/top.v:1911-1916` 的注释只算了 `AT_EN_DELAY=16` 拍 = **320 ns**，
**没有算标定本身的时长** —— 这就是"时间常数没算就判卡死"的老坑 `C84`。）

**改法（三选一）**：
① **保留 `event_extract` 的使能**，改为在 `tare` 生效的那一帧**只屏蔽被标定的那一个轴**
（`calib_autotare.cal_ch_o` 已知是哪个通道）⇒ 其余 15 个键**照常能弹**；
② 把 `WAIT_MS` 从 1000 降到 200（代价：手在动时更容易跳过该轴）；
③ 至少在 `rtl/top.v` 的注释里把"**最长 16 s 无响应**"写出来，并在上板手册里提醒。

**收益 / 代价**：① 收益最大（重标时琴不死），代价 = 要改 `event_extract` 的屏蔽口径（**有回归风险**）；
② 0 代码、只改一个参数；③ 0 成本。

**怎么验证能红**：`tb/w3c/tb_span_axis_over_uart.log` 同族的 tb 里，
让 `adc_farm` 的 `raw` **持续抖动**（模拟手在动）⇒ 发 `'T'` ⇒
断言"从 `'T'` 到第一个 `note_on` 可被接受"的时间 **< 100 ms**。现在必然红（>1 s）。

---

## P3-1 · `top.cst` 四条 TMDS 缺 `IO_TYPE`（实测一致，但依赖工具默认）

**位置**：`constr/top.cst:495-506` · 实测：`impl/pnr/Gowin2026.rpt.txt:157-164`

**代码 / 实测**：

```text
// constr/top.cst:496-497 —— ⛔ 没有 IO_TYPE
IO_LOC  "tmds_d_p_0[0]" J14,H14;
IO_PORT "tmds_d_p_0[0]" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
```
```
// impl/pnr/Gowin2026.rpt.txt（Pinout by Port Name）
tmds_d_p_0[0] | tmds_d_n_0[0] | J14/4 | Y | out | IOR26[A] | - | LVDS25 | 3.5 | NONE | … | 3.3
```

**机制**：`.cst` 没写 `IO_TYPE`，工具**自己推断**成 `LVDS25`。
而 RTL 侧用的是 `TLVDS_OBUF`（`rtl/hdmi/tmds_serializer.v:30,35`）
⇒ **实测两者一致**（Gowin 的 TMDS 输出就是 `TLVDS_OBUF` + `LVDS25`）⇒ **今天不是错**。
但它是一个**没写下来的依赖**：换工具版本 / 换 `DRIVE` 值时，
推断结果可能变，而 `.cst` 里没有任何东西能拦住它。
（`constr/top.cst:495` 的注释写"verified **TLVDS** differential pairs"，
而报告里写 `LVDS25` ⇒ **名字层面就已经对不上**。）

**改法**：显式写出来，并把注释改成实测值：

```text
IO_LOC  "tmds_d_p_0[0]" J14,H14;
IO_PORT "tmds_d_p_0[0]" IO_TYPE=LVDS25 PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
// ⭐ 实测（Gowin2026.rpt.txt）：IO Type=LVDS25 · Drive=3.5 · BankVccio=3.3
//    RTL 侧 = TLVDS_OBUF（rtl/hdmi/tmds_serializer.v:30）
```
（4 对共 4 行）

**收益 / 代价**：收益 = 电气标准不再靠推断；代价 = 0（若推断值本就正确，PnR 结果不变）。

**怎么验证能红**：改完重跑 PnR，断言 Pinout 报告里这 4 行的 `IO Type` **仍是 `LVDS25`**；
若写错（例如 `LVCMOS33`）会立刻出现 `CT1108` 类错误或报告变化。

---

## P3-2 · `DRUM_PATTERN_ID` 无范围自检（填 4 会被 `localparam [1:0]` 静默截成 0）

**位置**：`rtl/top.v:232`（参数）· `:699-700`（截断）· `:702-706`（寄存器）

**代码**：

```verilog
parameter integer DRUM_PATTERN_ID   = 0,
localparam [1:0] DRUM_PATTERN_INIT = DRUM_PATTERN_ID;   // ⚠️ integer → 2 位 ⇒ 静默截断
reg [1:0] drum_pattern_r;
always @(posedge clk) … if (!rst_n_sync) drum_pattern_r <= DRUM_PATTERN_INIT;
```

**机制**：`DRUM_PATTERN_ID = 4` ⇒ `4[1:0] = 0` ⇒ 上电节奏型**静默变成 BASIC**，
而注释（`:219-231`）说明合法值是 **0~3**。同类风险：任何 `integer` 参数赋给窄
`localparam`（本项目 `K-91` 家族）。`rtl/w3b/oscillator_bank.v` / `note_manager.v`
都有 `PARAM_OK` 自检（`$display("ERROR …")`），**`top.v` 这一段没有**。

**改法**：

```verilog
initial if (DRUM_PATTERN_ID < 0 || DRUM_PATTERN_ID > 3)
    $fatal(1, "ERROR [top] DRUM_PATTERN_ID=%0d 超出 0..3（会被 2 位 localparam 静默截断）", DRUM_PATTERN_ID);
```

**收益 / 代价**：收益 = 消掉一个静默截断；代价 = 3 行、0 资源。

**怎么验证能红**：`tb_key_drum.sv` 加一条 `top #(.DRUM_PATTERN_ID(4))` 的例化 ⇒
必须 `$fatal` 退出。现在会静默跑完。

---

## P3-3 · `=1 档 ≈57.0 MHz / CLS 81%` 只存在于 commit message，**没有机器可读证据**

**位置**：`git log -1`（`026ed21` 的 message）· `sim/evidence/rightboard-vibrato-fix-20261008/`（只有 `pnr-rpt-*.txt`，**没有 `timing.txt`**）

**机制**：任务书给的"=1 档 ≈57.0 MHz / CLS 81% / 余量 +0.642 ns"这个数，
在本仓库里**只能从 commit message 读到**：
```
deliver(右手板): 联调档时序达标 —— 一个能上板的版本（=1 档 0/0 · ≈57.0 MHz · 余量 +0.642 ns）
```
而 `sim/evidence/rightboard-vibrato-fix-20261008/` 下**没有** `timing.txt`
（对比 `final-batch-20261008/` 与 `a3-proper-20261008/` 都有）。
⇒ `+0.642` 这个数**无法与 `18.181` 反算校核**（若按 55.313 的口径，
`Fmax = 1000/(18.181 − slack)` ⇒ `slack = 0.642` ⇒ `Fmax = 57.06 MHz` ✅ **自洽**），
但**没有原始报告**可复核，也没有 CLS 81% 的出处。

**改法**：把 `=1 档` 那次 PnR 的 `Gowin2026_tr_content.html` / `timing_paths` /
`rpt.txt` 归档到 `sim/evidence/rightboard-vibrato-fix-20261008/`，
并让 `sim/gowin_build.ps1` **每次 PnR 都强制写 `timing.txt`**（现在是可选）。

**收益 / 代价**：收益 = 交付数字可复核（评委/队友都能验）；代价 = 磁盘（~700 KB/次）。

**怎么验证能红**：断言 `sim/evidence/*/timing.txt` 的份数 == PnR 次数。现在不成立。

---

## P3-4 · tb 数已 **131**（任务书写 130）；`tb_export_*` 默认跳过

**位置**：`sim/tb_all.ps1:65-66`（自动发现）· `:223-224`（默认跳过表）

**代码**：

```powershell
$tbs = @(Get-ChildItem -Path $tbDir -Recurse -Include tb_*.sv -File -ErrorAction SilentlyContinue | …
$skipByDefault = @('tb_export_wav', 'tb_export_key_wav')
```

**机制**：实测 `(Get-ChildItem tb -Recurse -Filter 'tb_*.sv').Count` = **131**
（新增的是 `tb/w3b/tb_osc_drum_cls.sv`）。而 `tb_export_wav`/`tb_export_key_wav`
**默认被跳过** ⇒ 回归打印的"共 N"**不含**这两个。
按项目纪律（`AGENTS.md` §四）：**判据是"通过数 == 共数"**，不写死数字 —— 这条要**继续守**。

**改法**：把任务书/交接里的"130 个 tb"改成"**自动发现，共数即真值**"；
并明确写出"默认跳过 2 个工具 tb（`tb_export_wav`/`tb_export_key_wav`）"。

**收益 / 代价**：收益 = 避免"数字过时"的第三次复发（历史已错三次：48→81→87）；代价 = 0。

**怎么验证能红**：`sim/tb_all.ps1` 输出里的"共 N"与
`(Get-ChildItem tb -Recurse -Filter tb_*.sv).Count - 2` **必须相等**。

---

## P3-5 · `i2s_tx` 的 `JUSTIFY(0)` 是命名陷阱（0 = Philips 标准 I2S，**不是**"左对齐"）

**位置**：`rtl/top.v:4619`（板载）· `:4671-4672`（外置）· 注释 `:4665-4668`

**代码**：

```verilog
// rtl/top.v:4611-4621（板载 MAX98357A）
i2s_tx #( … .JUSTIFY   (0), .MSB_DELAY (1), .LRCK_POL  (0) ) u_i2s_tx (…);
// rtl/top.v:4653-4673（外置 PCM5102A）—— ⚠️ 同一个 JUSTIFY=0，但 MSB_DELAY 不同
i2s_tx #( … .JUSTIFY   (0), .MSB_DELAY (0), .LRCK_POL  (0) ) u_i2s_tx_ext (…);
// rtl/top.v:4665-4668（注释已经把陷阱写出来了）
//   📌 **术语陷阱**：⭐ `i2s_tx` 这个模块里的 `JUSTIFY=0` 指的是
//      **"Philips 标准 I2S"**（⭐ 数据在 WS 翻转后【延迟】`MSB_DELAY` 位），
//      ⚠️ ⛔ **不是**字面意义的"左对齐" —— ⚠️ 别被名字误导。
//      ⭐ 真正要"左对齐" ⇒ ⭐ **`JUSTIFY=0` + `MSB_DELAY=0`**。
```

**机制**：两路的"格式"**完全由 `MSB_DELAY` 区分**（1 = 标准 I2S / 0 = 左对齐），
而 `JUSTIFY` 两路都是 0。⇒ 任何人读这两处例化时，**唯一有效的区分位是 `MSB_DELAY`**，
而名字最响的 `JUSTIFY` 是个**看起来像开关、实际两路相同**的参数。
本项目已经因为"名字骗人"栽过（`PA_EN_n` 实际是"高 = 出声"，`rtl/top.v:352`）。
注释虽然写清了，但**读例化的人不一定读注释**。

**改法**（0 风险，纯可读性）：

```verilog
localparam integer I2S_PHILIPS  = 0;   // ⭐ JUSTIFY=0 = Philips 标准 I2S（⛔ 不是"左对齐"）
// 板载：.JUSTIFY(I2S_PHILIPS) .MSB_DELAY(1)   ← 标准 I2S（实测出声）
// 外置：.JUSTIFY(I2S_PHILIPS) .MSB_DELAY(0)   ← 左对齐（实测出声）
```
或至少在两处例化行尾加同一句行内注释：`// ⭐ 格式差异看 MSB_DELAY，不看 JUSTIFY`。

**收益 / 代价**：收益 = 消掉一个"改错参数 ⇒ 没声音/爆音"的入口（`C-6` 家族）；
代价 = 0。

**怎么验证能红**：`tb/w3c/tb_i2s_tx_timing.log` 同族的 tb 里加一条：
断言 `u_i2s_tx.MSB_DELAY == 1` **且** `u_i2s_tx_ext.MSB_DELAY == 0` **且** 两者
`JUSTIFY == 0`。⇒ 若有人"顺手把两路参数对齐"，**必然红**（今天不会红，因为值是对的；
这条是把"隐式约定"变成"显式契约"）。

---

## 附录 A · 编译期参数 × tb 覆盖矩阵（点名从未验过的组合）

方法：对 `tb/**/*.sv` 统计 `.<参数>(` 的出现（= 该参数被 tb **显式覆盖**过）。
`0` = **任何 tb 都没有切过它的另一档** ⇒ 只有默认分支被执行过。

| 参数 | 默认 | 被 tb 覆盖的个数 | 判定 |
|---|---|---|---|
| `PA_ON_AFTER_RESET` | 1 | 8 | ✅ 两档都有 |
| `DEMO_CHORD_ON` | 1 | 13 | ⚠️ 两档**仿真**都有，但 `=0` 档**从未综合**（见 P1-8） |
| `TEST_MODE_EN` | **0** | 1 | ⚠️ `=1` 只有 1 个 tb；且注释说默认是 1（见 P0-1） |
| `SOURCE_A_SEL` | 0 | 5 | ✅ |
| `SEL_DRUM` | **1** | 6 | ✅ 两档都有 |
| `METRONOME_ON` | 1 | 2 | ✅ |
| `DPOS_DIAG` | 0 | 1 | ⚠️ `=1` 只仿真过，**从未 PnR 复算**（注释自称 Fmax 50.578） |
| `DETUNE_ON` / `DETUNE_SH` | 1 / 9 | 9 / 3 | ✅ |
| `DRUM_PATTERN_ID` | 0 | **0** | 🔴 **只有 0 档**（1/2/3 从未作为初值验过） |
| `DRUM_TIMBRE` | 2'd2 | **0** | 🔴 **只有 PIANO 档**（BASS/GUITAR/PAD 从未验过"鼓不跟键盘变"） |
| `FIXED_VELOCITY_DIAG` / `_VALUE` | 0 / 96 | **0** | 🔴 **`=1` 分支从未被执行过**（满行程失真诊断从没跑过） |
| `T3_ENABLE`（**顶层**） | 1 | **0** | 🔴 **`=0`（T2 回退档）从未在顶层构建过**（模块级 `T3_EN` 有 4 个 tb，但顶层闸没有） |
| `SPAN_CHECK_BOTH` | 1 | **0** | 🔴 **单板档 `=0` 从未构建过**（而注释说单板现场必须改它） |
| `SCORE_UART_ENABLE` | 1 | **0** | 🔴 **它是 `localparam`（`rtl/top.v:3495`），不是参数 ⇒ 根本不可能被构建参数切**（注释说"把它置 0 即可" ⇒ 必须改源码） |
| `OUTPUT_HEADROOM_SH`（**顶层**） | — | 1（**模块级**） | 🔴 **顶层是字面量 `1`（`:4413`）⇒ 顶层 `=0` 从未端到端验过** |
| `RIGHT_ADC_ENABLE` | 0 | 2 | ⚠️ `=1` 有 2 个 tb，但与 `N_ADC=2` 三处硬编码冲突（见 P1-4） |
| `RESERVED_N` | — | 18（**模块级**） | ⚠️ 顶层 5 处字面量，**顶层不可切**（见 P1-5） |
| `AUTOTARE_DELAY_CLK` / `SPAN_*` | — | 13 / 13 | ✅ |
| `HEARTBEAT_DIV` | — | 10 | ✅ |
| `POLY_TARGET` / `OSC_PER_VOICE` | 32 / 2 | 35 / 16 | ⚠️ 顶层**不可切**（`top` 有参数但无 tb 覆盖 ⇒ 交付值只有 32/2 一档） |

### A.1 从未验过的**组合**（点名，按风险排序）

| # | 组合 | 为什么危险 | 最小验证 |
|---|---|---|---|
| C1 | `DEMO_CHORD_ON=0` × **综合** | `g_silent` 有 9 个无驱动网（P1-8）；该档从没过综合门 | 加一次综合-only 跑 |
| C2 | `T3_ENABLE=0` × 顶层 | `note_manager` 的 `g_t2` 分支 + `top.v` 的 `voice_phase_inc_o` 旁路 mux **整段换掉** | `tb_transpose.sv` 加顶层档 |
| C3 | `FIXED_VELOCITY_DIAG=1` | `pos_to_vel` 的分支从未执行；它是"满行程失真"的二分工具 | 加 1 条 tb 断言 `vel ≡ 96` |
| C4 | `RIGHT_ADC_ENABLE=1` × `DEMO_CHORD_ON=0` | 该组合下 `ADC_N=3` 但 `g_silent` 完全不提 ADC ⇒ 引脚约束在、逻辑不在 | 综合-only |
| C5 | `RIGHT_ADC_ENABLE=1` × 标定 | `N_ADC=2` 硬编码 ⇒ 片 2 永不 tare/span（P1-4） | 见 P1-4 的判据 |
| C6 | `SPAN_CHECK_BOTH=0` | 单板现场**必须**用的档，从未构建 | 加一次综合-only |
| C7 | `SCORE_UART_ENABLE=0` | 是 `localparam` ⇒ 现场"置 0"要改源码（与注释矛盾） | 提成参数 + 1 条 tb |
| C8 | `OUTPUT_HEADROOM_SH=0` × 顶层 | 顶层是字面量 ⇒ 从未端到端验过；而它是"限幅器前 6 dB"的唯一开关 | 提成参数 + `tb_velocity_headroom` 顶层档 |
| C9 | `DRUM_TIMBRE ∈ {0,1,3}` | "鼓音色与键盘解耦"只验过 PIANO | `tb_drum_timbre_top` 参数化 |
| C10 | `SEL_DRUM=0` × `METRONOME_ON=0` | 两级串联（编译期闸 + 运行时闸）只有部分组合验过 | 4 组合小矩阵 |
| C11 | `DPOS_DIAG=1` × **PnR** | 只仿真过；注释自称 Fmax 掉到 50.578（**低于 51.5 门槛**） | 出一次诊断 bitstream 并归档 timing |
| C12 | `T3_ENABLE=1` × `SOURCE_A_SEL=1` × `DEMO_CHORD_ON=1` | 三个都开着时的交互（演示和弦 + 变调 + 手弹仲裁）无覆盖 | `tb_top_sound` 加一档 |

---

## 附录 B · 跨模块逐跳：位宽 / 时序 / 握手（逐跳核对）

**B.1 采集 → 事件链（每帧 500 µs，16 轴）**

| # | 发送 | 信号（位宽） | 接收 | 谁寄存 | 差几拍 | 握手语义 | 结论 |
|---|---|---|---|---|---|---|---|
| 1 | `adc_farm` | `sample_valid`(1) `sample_ch`(3) `sample_data_packed`(24) | `u_calib0/1`（`.valid/.ch/.raw`） | 发端寄存 | 0 | **无握手**（广播） | ⚠️ `tare`/`span`/`cal_ch` 必须**同拍**（`K-87`）—— 由 `cal_ch_mux` 仲裁保证 |
| 2 | `u_calib0/1` | `out_valid`(1) `out_ch`(3) `out_val`(12) | `axis_snapshot`（`sample_valid_i(cal0_vld)` / `sample_data_i({cal1_val,cal0_val})`=24） | 发端寄存 | 0 | **无握手**；两片**锁步** | ⚠️ 只取 `cal0_vld`（两片同拍，注释已论证） |
| 3 | `axis_snapshot` | `snap_valid`(1) `pos`(**192**) `delta`(**208**) | `event_extract` **与** `param_extract`（同拍广播） | 发端寄存 | 0 | **无握手、无背压** | ⚠️ 位宽必须 192/208（`rtl/top.v:2518-2523` 记过"写窄了会静默补 0"） |
| 4 | `event_extract` | `evt_valid`(1) `evt_axis`(4) `evt_kind`(2) `evt_depth`(12) | `play_mode_ctrl` **与** `param_extract` | 发端**FIFO 出队** | 0 | **内部 FIFO 深度 4**（`event_extract.v:163`） | 🔴 **会丢**（FIFO 满 ⇒ `note_off` 永久丢失，`event_extract.v:323`）⇒ 见 **P0-4** |
| 5 | `play_mode_ctrl` | `evt_valid/axis/kind/depth` | `top` 的 `always`（`pm_valid` 那拍锁 `as_pos[pm_axis*12+:12]`） | 收端寄存 | +1 | — | ✅ 单键路径正确；**同帧多键会取错音高**（`:3019-3029` 已登记为已知限制） |
| 6 | `top` | `am_pos_in`(12) `am_axis_in`(4) `am_mode`(1) | `axis_map`（**组合**，`axis_map.v:547-549`） | — | 0 | — | ✅ 输出 `am_inc`(32) 同拍有效 |
| 7 | `top` | `am_inc`→`am_inc_out`，`am_vld_in`→`am_vld_out` | `w3a_evt_*` | 收端寄存 | +1 | — | ✅ 与 #6 合计 **2 拍**，valid/axis/inc **严格同拍**（`:3264-3267`） |
| 8 | `seq_arb` | `evt_valid/axis/phase_inc/velocity/kind/timbre/src` | `evt_merge.a_*` | 发端 FIFO（`DEPTH 6`） | 0~1 | **真仲裁**（3 源同拍不丢） | ✅ 但 `sa_overflow`/`sa_drop_cnt` 是死线（P0-4） |
| 9 | `evt_merge` | `evt_*`（含 `src`(3)） | `note_manager.note_*` | 发端 FIFO（`DEPTH 6`） | 0~1 | **真仲裁**（A/B/C 三口） | ✅ 但 `mg_overflow`/`mg_drop_cnt` 是死线（P0-4） |
| 10 | `note_manager` | `voice_gate/active/axis/phase/vel/timbre/drum/drum_cls/retrig_reset` | `oscillator_bank` / `envelope_bank` / `tdm_render_mixer` | 发端寄存 | 0 | — | ✅ 位宽已核（`POLY_TARGET*N`） |
| 11 | `oscillator_bank` | `osc_sample_bus`(32×2×16=**1024**) `osc_valid`(1) | `tdm_render_mixer`（经 `mx_start_dly[31]` 延 **32** 拍） | 发端寄存 | **+32** | — | ⚠️ 32 拍偏移是 P5-1 的有意设计（`:4362-4388`） |
| 12 | `tdm_render_mixer` | `dry_valid` `dry_sample`(24) | `master_mix` | 发端寄存 | 0 | — | ✅ |
| 13 | `master_mix` | `valid_o` `sample_o`(24) | `sample_r`（**输出寄存**）→ `i2s_tx.sample_l/r` | 收端寄存 | +1 | — | ✅ `i2s_tx` 只在 `frame_start` 装载 ⇒ 整帧稳定 |
| 14 | `i2s_tx` ×2 | `HP_BCK/WS/DIN` · `I2S2_*` | 引脚 | 发端寄存 | — | — | ⚠️ **只有 `HP_*` 有 `set_output_delay`**（P1-1） |

**B.2 标定链（`'T'`/`'S'`/`'X'`）**

| # | 发送 | 信号 | 接收 | 结论 |
|---|---|---|---|---|
| 1 | `uart_rx` | `rx_data`(8) `rx_done`(1) | `uart_ui` **+** `calib_cmd` **+** `evt_uart_rx`（**三路共用同一字节流**） | 🔴 `0xA5` 帧头冲突是**已证明**的伪事件注入路径（`:3690-3717`）；`SCORE_UART_ENABLE=1` 是当前默认 ⇒ **风险仍在**（见 C7） |
| 2 | `calib_cmd` | `*_req_o`（**全部单周期脉冲**） | `top` 的翻转寄存器 / `calib_span` / `calib_autotare` | ✅ 脉冲语义一致；⚠️ `cmd_gear_next_req` 无人消费（`rtl/top.v:985-986` 已注明会剪掉） |
| 3 | `top` | `sp_start_gated = cmd_span_req & at_done` | `calib_span.start_i` | 🔴 **缺 `~sp_busy`** ⇒ 见 **P1-3** |
| 4 | `top` | `at_tare[1:0]` `at_ch[2:0]` | `u_calib0/1.tare` `.cal_ch` | ✅ 与 `sp_span`/`sp_ch` 经 `cal_ch_mux` 同拍仲裁 |
| 5 | `calib_span` | `raw_i = sp_raw_sel`（`sp_cur_axis[3] ? af1_pol : af0_pol`） | — | ⚠️ 选片靠"轴 ≥ 8 ⇒ 片 1"的隐含约定 ⇒ `N_ADC ≠ 2` 即错（P1-4） |
| 6 | `calib_span` | `cal_busy_i`/`cal_err_i` = `cal_busy_all`/`cal_err_any` | — | ✅ 两片都成功才算成功（`:1846-1847`，注释已论证 `&` 是最保守选择） |
| 7 | `top` | `rep_req`/`rep_byte` → `tx_req`/`tx_byte` | `uart_tx_fifo.push_i` | 🔴 每拍只推 1 字节 + 优先级链 ⇒ 见 **P2-2** |
| 8 | `uart_tx_fifo` | `tx_start`/`tx_data` | `uart_tx` | ✅ 深度 8；⚠️ `ovf_o`/`drop_cnt_o` 是死线 ⇒ 见 **P0-4** |

**B.3 位宽/符号接缝（逐条核过的"宽度错配"清单）**

| 位置 | 表达式 | 位宽 | 判定 |
|---|---|---|---|
| `rtl/top.v:1187,1202` | `p22={10'd0,p}`；`prod=(p22<<8)+(p22<<3)-p22` | 22 位 | ✅ `4095×263=1076985 < 2^21` ⇒ 不溢出（`K-91` 已守） |
| `rtl/top.v:1203` | `v13 = 13'd64 + prod[21:10]` | 13 位 | ✅ 最大 1115 ⇒ 饱和逻辑正确 |
| `rtl/top.v:3438` | `score_evt_inc = {11'd0, eu_evt_data[43:23]}` | 21→32 位 | ✅ 显式补 0（位域已回到 `mid2evt.py:124-128` 核实） |
| `rtl/top.v:2010` | `.sample_data_i(af_data[ADC_N*12-1:0])` | **36→24 位** | 🔴 **静默截断**（P1-4） |
| `rtl/top.v:3609` | `.tick_cnt_i({4'b0, bg_tick_cnt})` | 16→20 位 | ✅ 显式补零 |
| `rtl/top.v:1728` | `spi_cs_n[5:ADC_N] = {(6-ADC_N){1'b1}}` | 常数 | ✅ |
| `rtl/top.v:3320` | `.POS_FULL(TRAVEL_TARE)` | 12 位 | ✅ 单一来源（`TRAVEL_TARE=744`） |
| `rtl/top.v:700` | `DRUM_PATTERN_INIT = DRUM_PATTERN_ID` | int→2 位 | ⚠️ **静默截断**（P3-2） |
| `rtl/w3b/oscillator_bank.v:411-413` | 综合日志 `EX3791`：`24→16` / `21→16` 位截断 | 16 位 | ⚠️ 是有意的（`sweep_off` 高 16 位丢弃，注释已说明深度必须 < 65536） |
| `rtl/hdmi/tmds_encoder.v:45,46,50,53` | 综合日志 `EX3791`：`32→6` | 6 位 | ⚠️ 需人工确认（**不在本次三个文件范围内**，仅登记） |

---

## 附录 C · 证据索引与复现命令

**C.1 本次引用的原始证据（全部在仓库内）**

| 证据 | 路径 |
|---|---|
| 交付构建的时序总表（Fmax/违例/时钟） | `impl/pnr/Gowin2026_tr_content.html` |
| 最差 13 条 setup + 20 条 hold 路径 | `impl/pnr/Gowin2026.timing_paths` |
| 资源/时钟/引脚报告 | `impl/pnr/Gowin2026.rpt.txt` |
| 综合日志（含 PR1014 与 6 条 NL0002） | `impl/gwsynthesis/Gowin2026.log` |
| 综合报告（文件表） | `impl/gwsynthesis/Gowin2026_syn.rpt.html` |
| PnR 日志（PR1014 原文） | `impl/pnr/Gowin2026.log` |
| 模块级资源清单（swept 的交叉验证） | `sim/evidence/final-batch-20261008/rsc.xml` |
| 各档 Fmax 对照（12 个 18.181 档样本） | `evidence/h5/*/Gowin2026_tr_content.html` |
| 逐位等价 tb / 基线副本 | `tb/w3b/tb_p5_osc_equiv.sv` · `tb/models/oscillator_bank_ref.v` |
| 差分/功能 tb | `tb/w3b/tb_osc_drum_cls.sv` · `tb/w3c/tb_key_drum.sv` · `tb/top/tb_top_led_strip.sv` |

**C.2 复现命令（可直接粘贴）**

```powershell
# ① 时序总表 + 违例数
Select-String -Path impl/pnr/Gowin2026.rpt.txt -Pattern 'CLS|Logic |Register |LW |PRIMARY'

# ② 头号路径（From/To/Slack/Arrival/Required）
$t=[System.Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes('impl/pnr/Gowin2026_tr_content.html'))
($t -replace '<[^>]+>',' ') -split "`n" | Select-String 'Slack|Data Arrival|Data Required|g_t3' | Select-Object -First 20

# ③ 综合期"模块消失"清单（P0-2 的门）
Select-String -Path impl/gwsynthesis/Gowin2026.log -Pattern 'NL0002'
# 期望（当前）：6 条 —— metronome / param_extract / pos_probe_dpos / right_analog_ctrl / vibrato_lfo / led_data

# ④ 时钟资源红线（P1-6）
Select-String -Path impl/pnr/Gowin2026.rpt.txt -Pattern 'PR1014' , 'LW '

# ⑤ top.v 死线扫描（P2-1）
$lines = Get-Content rtl/top.v
$names = Select-String -Path rtl/top.v -Pattern '^\s*wire\s+(\[[^]]+\]\s+)?(\w+)\s*;' -AllMatches |
         ForEach-Object { $_.Matches[0].Groups[2].Value } | Sort-Object -Unique
foreach($n in $names){ if((($lines | Select-String -Pattern ([regex]::Escape($n)) -AllMatches).Count) -le 2){ $n } }

# ⑥ 参数覆盖矩阵（附录 A）
$files = Get-ChildItem tb -Recurse -Include *.sv,*.v -File
foreach($p in @('T3_ENABLE','DRUM_TIMBRE','DRUM_PATTERN_ID','FIXED_VELOCITY_DIAG','SPAN_CHECK_BOTH','OUTPUT_HEADROOM_SH')){
  "{0,-22} {1}" -f $p, ($files | Select-String -Pattern ("\.\s*"+[regex]::Escape($p)+"\s*\(") | Measure-Object).Count
}
```

**C.3 四道门（按项目纪律，改 RTL 必须走全）**

```
① 综合 ERROR=0      —— ⚠️ 建议加一条：NL0002 白名单之外出现即 FAIL（P0-2）
② 聚焦 tb           —— 本文件每条 P0/P1 都给了"怎么验证能红"的具体 tb 与断言
③ 干净 PnR 0/0 无 PR0004 —— 当前 0/0 ✅；PR1014 是 WARN（P1-6 登记）
④ 全量回归 通过数 == 共数 —— 当前 tb 数 = 131（默认跳过 2 个工具 tb，P3-4）
```

---

## 附录 D · 本次**未能**核实的项（诚实登记，⛔ 不要当结论用）

| 项 | 为什么没核 | 怎么核 |
|---|---|---|
| `NL0002 "swept"` 到底是"删除"还是"常量折叠" | Gowin 文档没有明确语义；`.vg` 是扁平网表，实例名全无（`grep u_master_mix` = 0）；`rsc.xml` 只证明"模块清单里没有" | ① 按 P0-2 的白名单门先把它变成可判定；② 或对 `u_vibrato_lfo` 单独出一个 bitstream，用调试核读 `vib_off` |
| `=1 档`（`RIGHT_ADC_ENABLE=1`）的 57.0 MHz / CLS 81% | 仓库里没有该档的 `timing.txt` / `tr_content.html` | 见 P3-3 |
| "同源重跑差 2~3 MHz" | 我能找到的同源样本只差 **0.006~0.25 MHz** | 见 §0.2；请提供那两份原始报告 |
| `led_clk` 的实际翻转频率 | 需要读 `tlc5916_bank`/`tlc5916_driver` 的分频（本次三个文件之外） | `grep PER_CLK` 于 `rtl/drivers/tlc5916_driver.sv` |
| `event_extract` 的 FIFO 在真实演奏下会不会真的满 | 需要场景化仿真 | 在 `tb_e2e_key_to_sound` 里加"16 轴同帧全按下"的激励，断言 `ee_ovf == 0` |
