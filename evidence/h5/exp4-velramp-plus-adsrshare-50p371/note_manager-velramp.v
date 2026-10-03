`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// note_manager.v · 32 voice 分配 / 抢占 / 释放 / 参数更新（W3b · `T54`）
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/W3接口冻结表.md`
//   · §三 接口 ① 事件通路：`note_evt_t` / `vel_update_t` / `pitch_update_t`
//   · §二 全局参数：`POLY_TARGET=32`、`OSC_PER_VOICE=2`、`PHASE_W=32`、`VEL_W=8`
//   · `K-82`：⭐ `timbre` 是**每 voice 属性**（起音时刻锁存）
//
// ⭐⭐ 2026-09-21 重大重构（`T66` / `K-103`）：**候选选择由"单拍组合"改为"多拍流水"**
//
//   🔴 问题：第一版把三级抢占（① 空闲 → ② Release 且电平最低 → ③ 年龄最老）
//      写成**一整条组合优先级链**（每级扫 32 个 voice，且②③的条件依赖上一轮结果
//      ⇒ 综合器**无法并行化**）⇒ 实测 **96 级逻辑、data delay 118.5 ns**
//      ⇒ ⛔ 交付顶层 `Actual Fmax` 从 **55.96 MHz 掉到 8.424 MHz**、
//         **1408 个 setup 违规**、TNS **−135600 ns**（`K-103`）。
//      ⚠️ 而 `synth_check` **只跑 `run syn`、不跑 PnR** ⇒ **完全看不见**（`K-104`）。
//
//   ⭐ 修法：**每拍只考察一个 voice**（1 次比较 + 1 次选择 ≈ 2~3 级逻辑），
//      扫完 32 拍后提交。⚠️ 代价 = 分配延迟从 1 拍变成 **≤34 拍（0.68 µs）**。
//
//   ⭐⭐ 为什么这个代价是**免费**的（关键论证）：
//      `adsr.v` 里 **`gate` 只在 `sample_tick_i` 那一拍被采样**（每 1024 拍一次）
//      ⇒ ⭐ 只要分配在**一帧之内**完成，**`gate` 的生效时刻一个采样拍都没变**
//      ⇒ **听感延迟完全不变**（仍 ≤1.233 帧，`K-44` 实测）。
//      ⭐ 预算核算：`K-44` 留给合成链 **785 clk = 15.7 µs**；
//         本模块用 **34 clk = 0.68 µs** ⇒ **只占 4.3%**，余量仍有 95.7%。
//      ⭐ 且**复音数无损**（仍是 32 voice / 64 振荡器）—— ⛔ 没有降 `POLY_TARGET`。
//
//   ⚠️ **契约变更（须通知全员，冻结表 §〇 约定 5）**：
//      `W3接口冻结表.md` §四 原写 `note_manager ≤ 4 拍` ⇒ 改为 **≤ 34 拍**。
//      ⛔ 但**端口列表一字未改** ⇒ 队友的 tb **不需要改接口**（只需改等待拍数）。
//
// ⭐⭐ 2026-09-21 · `K-106` 修复：**事件队列溢出可观测化**
//   🔴 问题：`fifo_push = note_valid_i && !fifo_full` ⇒ **溢出时静默丢弃**（无任何指示）。
//      ⚠️ 而**丢的若是 `note_off` ⇒ 那个音永远关不掉（挂音）** —— 正是 `T38` 要防的失效模式。
//      ⚠️ 最坏突发 = **16 键 + 节拍器 1 + 鼓机 1 = 18 > 原深度 16** ⇒ 丢 2 个。
//   ⭐ 修法（三件一起，缺一不可）：
//      ① `FIFO_DEPTH: 16 → 32`（覆盖 18，余量 14）—— ⭐ **减少丢音【概率】**
//      ② ⭐⭐ **新增 `event_lost_o`（sticky）+ `event_lost_cnt_o`（饱和计数）+ `event_lost_clr_i`**
//         —— ⭐ **让丢音【可被发现】**
//      ③ tb 补 FIFO 溢出用例（⛔ 之前 `tb_note_manager.sv` 里**没有任何 `fifo` 字样**
//         ⇒ 这条路径**从未被验证**）
//   ⭐⭐ 为什么①和②**必须都有**：两者**正交** ——
//      ① 只是"把墙往后挪"（超过 32 照样丢），② **不能阻止**丢。
//      ⇒ 合起来才是可接受的工程语义：**"要么不丢，要么丢了立刻知道"**。
//      ⛔ **不存在"永不丢音"**（队列有限 + 上游无限 ⇒ 数学上必然溢出）。
//   ⚠️ **本修复【改了端口】**（+3）⇒ 属接口变更，按冻结表 §〇 约定 5 **须通知全员**。
//      已有例化**不接新输入**也合法（`event_lost_clr_i` 悬空=恒 0 ⇒ 只置位不清）。
//
// ⛔ 纪律（本项目血泪）：
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⭐⭐ **组合逻辑用 `assign`/`generate`；`always @(*)` 只用在"真的读信号"的块上**
//     （`L67`：参数取默认值时"全是常量"的组合块**没有敏感信号 ⇒ 仿真器从不执行**）
//   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
//   · ⛔ 不用 PLL、不派生时钟；`sample_tick_i` 只是**时钟使能**（冻结表 §〇 约定 1）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module note_manager #(
    parameter integer POLY_TARGET = 32,
    parameter integer AXIS_W      = 4,
    parameter integer PHASE_W     = 32,
    // ⭐⭐ 2026-10-03（`P1`）：⭐ **T3 实时变调总开关** —— ⭐ 默认 **0 = 关** ✅
    //   📌 **为什么要有它**（⭐ 详见 `files/20-代码/T3-后续计划-20261003.md` §三 `P1`）：
    //      ⭐ T3 变调**功能正确、但装不下** —— ⭐ 32 lane 输出旁路 mux = **1025 LUT**
    //      ⇒ 🔴 布线失败 `PR0004 659 unrouted`；⚠️ 三条减重路（读侧 mux 1025 /
    //      写侧 mux ~1400 / 每 lane 乘法器 DSP 98%）**全部实测不通**。
    //      ⇒ ⭐ 用户 2026-10-03 拍板"**暂不做大改**" ⇒ ⭐ **把 T3 关起来，让主线恢复可交付** ✅
    //   ⭐ **语义**：
    //      · `T3_EN = 0` ⇒ ⭐ **整个变调核心【不参与综合】**（`generate` 门控，见文件末段）：
    //         ⭐ `semi_ratio_of()` 比例表 · ⭐ 共享乘法器 `prod_w` · ⭐ `rot_cnt` 轮转 ·
    //         ⭐ `semi_cur`/`semi_tgt` 滑音 · ⭐ `phase_tr[]` 数组 —— ⭐ **全部不展开** ✅
    //         ⇒ ⭐ `voice_phase_inc_o` **回到 T2 原式**（`phase_r[g] << base_oct_r`）✅
    //         ⇒ ⭐ **与 `d36cb64^`（T2 基线）逐位相同** —— ⭐ 这正是 `tb_transpose` 的
    //            `T1` 判据（⭐ 与 `note_manager_ref` 逐拍差分）所钉住的契约 ✅
    //      · `T3_EN = 1` ⇒ ⭐ **逐字保持 2026-10-03 的现有语义**（⛔ 只"包起来"，⛔ 不改行为）✅
    //   ⚠️ **端口 `transpose_semi_i` 保留**：⭐ `T3_EN=0` 时它无人引用 ⇒ 可能触发
    //      unused 警告 —— ⭐ **可接受**；⛔ **不删端口**（否则 `top.v` / 所有 tb 都要改）✅
    parameter integer T3_EN       = 0,
    parameter integer VEL_W       = 8,
    parameter integer TIMBRE_W    = 2,
    parameter integer ENV_W       = 16,
    parameter integer AGE_W       = 16,
    // ⭐ 专用 voice 数（节拍器/鼓机，`T33b`）—— 从**最高索引**往下留 `RESERVED_N` 个。
    //    ⚠️ 默认 0 ⇒ **32 个 voice 全部给演奏**（保住"复音 ≥32"这条线，⛔ 不缩水）。
    parameter integer RESERVED_N  = 0,
    // ⭐ 起音用的默认力度（冻结表：越过浅阈 t1 就发声，用 `DEFAULT_VEL` 起音）
    parameter integer DEFAULT_VEL = 200,
    // ⭐ 专用 axis_id 起点（`Looper详细设计.md` §二：建议 `4'hE` 节拍器 / `4'hF` 鼓机）
    parameter integer RESERVED_AXIS_BASE = 14,
    // ⭐⭐ 事件队列深度（`T66`）—— 扫描期间到达的事件先排队，⛔ 不丢
    //    ⚠️ 原深度 16 的依据：`AXIS_N=16` ⇒ 一个采集帧内**每个轴位最多一个事件**。
    //    🔴 **`K-106`（2026-09-21）**：该依据**漏算了自动功能** ——
    //       最坏突发 = **16 键 + 节拍器 1 + 鼓机 1 = 18 个** > 16 ⇒ **丢 2 个**。
    //    ⭐ 修法：`16 → 32`（32 ≥ 18，余量 14）。
    //    ⚠️ 代价极小：每条事件 64 bit ⇒ 多 16×64 = **1024 bit**（60K 总 BSRAM 2124 kb 的 **0.05%**）。
    //    ⚠️ 副作用（**必须知道**）：排空时间 16×35=560 拍 → 32×35=**1120 拍 = 22.4 µs**
    //       ⭐ 但**听感延迟不受影响** —— `adsr` 的 `gate` 只在 `sample_tick_i`（每 1024 拍）采样，
    //          22.4 µs 仍在一帧内（见文件头 `K-103` 的同一论证）。
    parameter integer FIFO_DEPTH  = 32,
    // ⭐ 丢弃事件计数位宽（8 bit ⇒ 饱和于 255；⚠️ 饱和而**不回绕**，见下方注释）
    parameter integer EVT_LOST_CNT_W = 8,
    // voice 索引位宽（`alloc_voice_o` 用）
    parameter integer IDX_W = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET)
) (
    input  wire                              clk_i,
    input  wire                              rst_n_i,
    input  wire                              sample_tick_i,

    // ── 接口 ① · 事件通路（W3a → 本模块）──────────────────────────────────
    input  wire                              note_valid_i,       // 单周期脉冲
    input  wire [AXIS_W-1:0]                 note_axis_i,
    input  wire [PHASE_W-1:0]                note_phase_inc_i,
    input  wire [VEL_W-1:0]                  note_velocity_i,    // 0 ⇒ 用 DEFAULT_VEL
    input  wire [1:0]                        note_kind_i,        // 0=note_on 1=note_off 2=pluck
    //  ⭐⭐ 2026-09-29（A1）：⭐ **事件来源标记**（⭐ `evt_merge.evt_src_o` 驱动）
    //     ⭐ 编码：0=live 手弹 / 1=score 曲谱 / 2=demo 演示 / 3=源 B 节拍器·鼓机
    //     ⭐ 用途：⭐ `note_off` **只清"同源"的 voice**（⭐ 见 `ST_DECIDE` 的 off 分支）
    //     🔴 修的缺陷（上板实测）：⭐ looper 回放时按**同一个轴**的手弹键
    //        ⇒ 回放的 `note_off` 把**手弹**的 voice 也清了 ⇒ ⭐ **手弹的音死掉且不再回来**。
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3**（⭐ 新增第 5 个源 `3'd4` = looper 回放）
    //     🔴 **为什么必须加宽**：⭐ 2 位的 4 个值**已经用满**（0/1/2/3），
    //        而用户要求"曲谱 UART 与 looper **同时可用**"⇒ ⭐ looper 必须**独立成源**
    //        （🔴 复用一个已有编码 ⇒ 曲谱的 `note_off` 会清掉**同轴 looper 的 voice**）✅
    //     ⭐ **新的编码表（3 位，用 5 个值）**：
    //        · `3'd0` = live   手弹        · `3'd1` = score  曲谱（串口）
    //        · `3'd2` = demo   自检和弦     · `3'd3` = 源 B   节拍器 / 鼓机
    //        · `3'd4` = looper 回放（⭐ 新增）  · `3'd5..7` **未使用**
    //     ⚠️ 位宽写死 3（⭐ 与 `seq_arb`/`evt_merge` 的编码一致；⛔ 不加参数位选 —— `K-91`）
    //     📌 **本模块的隔离逻辑一个字都没改** —— ⭐ 仍然只是 `src_r[i] == cur_src` 的比较，
    //        ⭐ 加宽对"按源隔离"这条语义是**透明的**（⭐ 比较器宽 1 位）✅
    input  wire [2:0]                        note_src_i,

    input  wire                              vel_upd_valid_i,    // ⭐ 力度修正（后到）
    input  wire [AXIS_W-1:0]                 vel_upd_axis_i,
    input  wire [VEL_W-1:0]                  vel_upd_value_i,

    input  wire                              pitch_upd_valid_i,  // ⭐ 音高修正（滑音持续移动）
    input  wire [AXIS_W-1:0]                 pitch_upd_axis_i,
    input  wire [PHASE_W-1:0]                pitch_upd_value_i,

    //  ⭐⭐ 2026-09-29 新增：⭐ **参数更新通路的【来源标记】**
    //     ⭐ 编码与 `note_src_i` **完全一致**：0=live 手弹 / 1=score 曲谱 / … / 4=looper
    //  🔴 **为什么必须有**（⭐ 与 A1 的 `note_src_i` 是**同一缺陷类**）：
    //     ⭐ (d) 力度跟随 与 (e) 音高修正 原来**只按 `axis` 匹配** ⇒
    //     🔴 一旦 looper 回放也驱动这两条通路 ⇒ ⭐ 回放的更新会
    //        **把同一轴上手弹的 voice 一起拖走**（⭐ 音量被别人的手势带着跑）✅
    //  ⭐ 修法：⭐ **更新也带源** ⇒ 两个处理段都要求 `src_r[i] == 更新源` ✅
    //  ⚠️ **老例化不接本端口 ⇒ `z`** ⇒ ⭐ 由下方 `vu_src_w`/`pu_src_w` 按
    //     "**悬空 = 手弹(0)**"解码 ⇒ ⭐ **行为与加此端口前完全一致** ✅
    //     （📌 与 `event_extract.enable_i` 的"悬空 = 使能"是**同一套向后兼容口径** ✅）
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3**（⭐ 与 `note_src_i` 同步加宽，⭐ 见上方编码表）
    input  wire [2:0]                        vel_upd_src_i,
    input  wire [2:0]                        pitch_upd_src_i,

    // ── 接口 ② · 参数通路（新起音的默认音色，`K-82`）──────────────────────
    input  wire [TIMBRE_W-1:0]               default_timbre_i,
    input  wire                              evt_timbre_valid_i, // ⭐ Looper 每层覆盖
    input  wire [TIMBRE_W-1:0]               evt_timbre_i,

    // ── 包络状态回读（判断 voice 是否还在响）──────────────────────────────
    input  wire [POLY_TARGET-1:0]            env_active_i,
    input  wire [POLY_TARGET*ENV_W-1:0]      env_level_i,

    // ── ⭐⭐ 2026-10-01：⭐ **T2 起始音（base note）** ────────────────────────
    //   📌 **背景**：⭐ `uart_ui.base_semi_o` / `base_commit_o` **早就存在、`top.v` 也接了线**，
    //      🔴 但**全 `rtl/` 里没有任何地方读它** ⇒ ⭐ 一根**悬空线** ⚠️ ⇒ ⭐ **T2 = 把它接上** ✅
    //   ⭐ **语义**（⭐ `uart_ui.v` 的 `RET_NUM` 分支原文）：⭐ "起始音：限定八度级（每 12 半音取整）"
    //      ⇒ ⭐ **`base_semi` = 八度数 × 12**（⭐ `0` = C4 · `12` = C5 · `24` = C6 ✅）
    input  wire [6:0]                        base_semi_i,        // ⭐ 起始音（⭐ 八度×12）
    input  wire                              base_commit_i,      // ⭐ 提交（⭐ 单周期脉冲）

    // ── ⭐⭐ 2026-10-03：⭐ **T3 实时变调（Transpose）** ──────────────────────
    //   📌 **来源**：⭐ `files/00-总览/T3变调与推子功能状态机-设计定稿-20261001.md`
    //      §三（共享乘法器 ＋ 轮转）· §五（比例表 · 旁路 mux · 短滑音）✅
    //   ⭐ **语义**：⭐ **总半音偏移**（⭐ 推子量化 ＋ ⭐ 摇把连续 ⇒ 由上层相加后送来 ✅）
    //      ⇒ ⭐ `0` = 不变调 · ⭐ `−12..+12` = 降/升调 ✅
    //   ⭐⭐ **本步（步骤①）⛔ 不接线**：⭐ `top.v` 的接线是**步骤②** ⇒
    //      ⚠️ 本端口现在**悬空**（⭐ 老例化一个都不接）⇒ ⭐ 悬空是 `5'bzzzzz`
    //      ⇒ 🔴 **必须 Z-safe 解码**（⭐ 见下方 `semi_tgt_w`）⭐ 否则
    //         `semi_cur` 会变 `x` ⇒ ⭐ `voice_phase_inc_o` 全 `x` ⇒ **老 tb 全假红** ✅
    //   📌 **本步的核心安全保证**：⭐ **悬空 ⇒ 0 档 ⇒ 逐位恒等**（⭐ `T1` 判据 ✅）
    //   ⚠️ 位宽写死 **5 位有符号**（⭐ −12..+12 的补码范围 ✅；⛔ 不用 `integer` 参数 —— `K-91`）
    input  wire signed [4:0]                 transpose_semi_i,   // ⭐ 总半音偏移（⭐ −12..+12）

    // ── 输出 → `oscillator_bank` / `envelope_bank` ─────────────────────────
    output wire [POLY_TARGET-1:0]            voice_gate_o,       // → envelope_bank.gate_i
    output wire [POLY_TARGET-1:0]            voice_active_o,     // → oscillator_bank.voice_active_i
    output wire [POLY_TARGET-1:0]            voice_releasing_o,  // 诊断：gate=0 但还在响
    output wire [POLY_TARGET*AXIS_W-1:0]     voice_axis_o,       // 诊断 / 抢占
    output wire [POLY_TARGET*PHASE_W-1:0]    voice_phase_inc_o,  // → oscillator_bank
    output wire [POLY_TARGET*VEL_W-1:0]      voice_velocity_o,   // → envelope_bank
    output wire [POLY_TARGET*TIMBRE_W-1:0]   voice_timbre_o,     // → wavetable（`K-82`）
    //  ⭐⭐ 2026-09-29 新增（⭐ 鼓机噪声波表 · 阶段 2a）：⭐ **每 voice 的"是鼓吗"**
    //     ⭐ 语义：⭐ `src_r[i] == SRC_AUX`（⭐ 源 B = 节拍器/鼓机）⇒ ⭐ **进保留池 / 是打击乐**
    //     ⛔ **不再按轴号判断**（⭐ 轴号 14/15 只是节拍器/鼓机的【事件 ID】；
    //        ⭐ 音色由事件自带的 `timbre` 决定，⛔ 不按轴号 —— 见本文件的 `assign voice_drum_o[g]`）
    //     ⭐ 去向：⭐ `oscillator_bank.voice_drum_i` ⇒ ⭐ 这些 voice 改读**噪声表**
    //     🔴 **为什么"按来源"判而⛔ 不是"按轴号"判**（⭐ 2026-10-01 修B 更正）：
    //        ⭐ 旧规则 `axis_r[i] >= RESERVED_AXIS` 已被推翻 —— 🔴 它把**物理键 14/15**
    //           也标成"鼓 voice" ⇒ 音色被换成噪声表 ⇒ ⭐ 就算出声也是错的音 ✅
    //        ⭐ 保留池的本意是"**给节拍器/鼓机专用**"（⭐ `T33b`），那是【来源】属性
    //        ⇒ ⭐ 与 `pool_mask`（⭐ 本文件的 `assign pool_mask[pg]`）**由同一个信号导出** ⇒ ⭐ 结构上不可能再不一致 ✅
    //     ⭐ 纯组合、⛔ 不加任何寄存器、⛔ 不改任何已有输出 ⇒ **完全 additive** ✅
    output wire [POLY_TARGET-1:0]            voice_drum_o,
    output wire [POLY_TARGET*AGE_W-1:0]      voice_age_o,        // 抢占年龄（诊断）
    //  ⭐ 重触发/抢占时命令该 voice 的包络【先归零】—— → envelope_bank.retrig_reset_i
    //     ⚠️ 为什么必须归零（2026-09-27 上板实测）：
    //        🔴 旧行为只把 `gate` 压低 **1 个 sample_tick（20.5 µs）** 就抬高，
    //           而 ADSR 归零需要 `65535/RELEASE_STEP` 个采样拍 ⇒ **包络几乎没掉**。
    //           `gate` 一回来 ADSR 直接回 `ST_ATTACK` 并从**残余电平**往 peak 爬
    //           ⇒ ⭐ **旧音的尾巴 + 新的 Attack 叠加** ⇒ 🔴 **幅度冲到正常音的 ~11 倍**
    //             （示波器实测 0.0138 V vs 正常 0.00125 V），听感 = **偶发刺耳尖音**。
    //        ⭐ 归零后重触发 = **干净重启**，且**不再依赖 release 时间常数**
    //           （⭐ 这正是"等待时间 < 时间常数"那条老坑在 RTL 侧的翻版）。
    output wire [POLY_TARGET-1:0]            voice_retrig_reset_o,
    //  ⭐⭐ K-169（2026-09-30）：⭐ **本信号同时是【每 voice 的 `note_on` 事件边沿】** ✅
    //     ⭐ 第二个消费者 = `oscillator_bank.voice_phase_rst_i`（⭐ 起音相位复位 ✅）
    //     📌 **为什么"一个信号两处用"是【对的】而⛔ 不是耦合**：
    //        ⭐ "包络归零"与"相位回到设计初相"**本来就是同一件事的两个侧面** ——
    //        两者都表示"⭐ 这个 voice 现在开始一个**全新的音**" ✅
    //        ⇒ ⭐ 由**同一个事件**驱动 ⇒ ⛔ 不会再出现"一个复位了、另一个没复位"
    //          这种**不同步**的缺口（⭐ `K-169` 正是这种缺口 ✅）
    //     🔴 **为什么起音相位复位必须用它、而⛔ 不能用 `voice_active_o` 的上升沿**：
    //        ⭐ `voice_active_o = live_mask = gate_r | retrig_low | env_active_r`
    //           （⭐ `env_active_r` = 模块入口打了一拍的 `env_active_i`，⭐ 见上）
    //           ⇒ ⭐ 它是**电平派生**的：⭐ 上一个音**还在 Release 尾巴里**
    //              （⭐ `env_active_i=1` ✅）时再按**同一个轴**
    //           ⇒ ⭐ `live_mask` **恒为 1** ⇒ 🔴 **上升沿根本不存在**
    //           ⇒ 🔴 相位复位被跳过 ⇒ ⭐ 新音从残留相位起振 ⇒ 🔴 起音幅度随机 ✅
    //        ⭐ 而本信号在**两条起音路径**上都会置位：
    //           · ⭐ `ST_COMMIT2`（⭐ 提交/抢占 ⇒ "新占 voice" ✅）
    //           · ⭐ `(f)` 段（⭐ 同轴重触发**复用**同一 voice ✅）
    //        ⇒ ⭐ **它才是真正的"起音事件"** ⇒ ⭐ 用它复位相位**必然覆盖两条路** ✅
    //     ⚠️ **"保持到 `sample_tick_i`"的电平语义 ⛔ 一个字都不改**：
    //        ⭐ 两个消费者都只在 `sample_tick_i` 采样 ⇒ ⭐ 电平才保证被看见 ✅
    //        （📌 见下方 `if (sample_tick_i) retrig_reset_r <= 0;` 的说明 ✅）
    output wire                              alloc_valid_o,     // 分配发生（脉冲）
    output wire [IDX_W-1:0]                  alloc_voice_o,

    // ── ⭐⭐ 事件队列【溢出可观测性】（`K-106`，2026-09-21）──────────────────
    //    🔴 起因：`fifo_push = note_valid_i && !fifo_full` ⇒ **溢出时静默丢弃**，
    //       ⛔ 无任何指示。⚠️ 而**丢的若是 `note_off` ⇒ 那个音永远关不掉（挂音）**，
    //       正是 `T38` 专门要防的失效模式。
    //    ⭐ 纪律（`K-106` 原话）：**任何"容量有限"的队列，都必须有【可观测的溢出指示】**。
    //    ⭐⭐ 注意：加指示**不能**"不丢音" —— 它解决的是【可知性】而不是【概率】：
    //       · 加深度（16→32）⇒ 把溢出阈值抬高 ⇒ **减少**丢音**概率**，但仍会丢
    //       · 加指示          ⇒ 丢了**能立刻知道**，⛔ 但**不能阻止**丢
    //       ⇒ ⭐ 两者**正交**，要一起做：**"要么不丢，要么丢了能立刻发现"**。
    output wire                              event_lost_o,      // ⭐ sticky：曾发生溢出（⭐ 置位后保持）
    output wire [EVT_LOST_CNT_W-1:0]         event_lost_cnt_o,  // ⭐ 累计丢弃事件数（**饱和**，⛔ 不回绕）
    input  wire                              event_lost_clr_i   // ⭐ 读走后清零（1 拍脉冲或电平皆可）
);

    // ── 常量（⛔ 不对 integer 参数做位选 —— `K-91` 的教训）────────────────
    localparam [1:0]        KIND_ON     = 2'd0;
    localparam [1:0]        KIND_OFF    = 2'd1;
    localparam [1:0]        KIND_PLUCK  = 2'd2;

    localparam [AXIS_W-1:0] RESERVED_AXIS = RESERVED_AXIS_BASE;
    //  ⭐⭐ 2026-10-01 修B：⭐ **"辅助源"＝源 B（节拍器 / 鼓机）** —— ⭐ 池与鼓标志都按它判 ✅
    //   ⭐ 编码与 `top.v` 一致：⭐ `0`=live · `1/2`=score/demo · ⭐ **`3`=源 B（本常量）** · `4`=looper
    //      （⭐ 见 `top.v`：`.b_src_i(3'd3)` · `.c_src_i(3'd4)` ✅）
    //   ⚠️ **为什么⛔ 不写 `src != 0`**：⭐ 那样会把 **looper（4）** 也判成鼓
    //      ⇒ 🔴 **回放会全走噪声表**（⭐ 实测源 C = `3'd4` ⚠️）✅
    localparam [2:0] SRC_AUX = 3'd3;
    localparam [VEL_W-1:0]  DEFAULT_VEL_V = DEFAULT_VEL;
    localparam integer      NORMAL_N      = (RESERVED_N > POLY_TARGET)
                                            ? POLY_TARGET
                                            : POLY_TARGET - RESERVED_N;

    //  ⭐⭐ 2026-09-29 新增：⭐ **更新源的"悬空 ⇒ 手弹(0)"解码**（⭐ 向后兼容的关键一步）
    //   🔴 **为什么必须显式解码**：⭐ 老 tb（`tb_vel_pos_follow` / `tb_note_manager` …）
    //      **不接**这两个新端口 ⇒ ⚠️ 悬空是 `z` ⇒ 🔴 直接拿去和 `src_r[i]` 比较会得到 `x`
    //      ⇒ ⭐ **那些 tb 的"力度跟随"判据会假红** ✅
    //   ⭐ 口径（⭐ 与 `event_extract.v` 的 `enable_i === 1'b0` **完全同构**）：
    //      ⭐ **只有明确的 1/2/3/4 才当"非手弹"**，⭐ 其余（含 `x`/`z`）一律当**手弹(0)**
    //      ⇒ ⭐ **新功能⛔ 不许让老用例失效** ✅
    //   ⭐⭐ 2026-09-30：⭐ **解码表扩到 `3'd4`（looper）** —— ⚠️ 这一条**不能漏**：
    //      🔴 漏了 ⇒ looper 的插值更新会被解码成**手弹(0)** ⇒ ⭐ 它会去改**手弹**的每轴目标
    //         ⇒ 🔴 **回放的力度把同轴手弹的音拖走**（⭐ 正是本端口要防的那个缺陷）✅
    //   ⚠️ `3'd5..7` 是**未使用**的编码 ⇒ ⭐ 落到 `else` ⇒ 当手弹(0)（⭐ 与"悬空"同一处置）
    wire [2:0] vu_src_w = (vel_upd_src_i   === 3'd1) ? 3'd1 :
                          (vel_upd_src_i   === 3'd2) ? 3'd2 :
                          (vel_upd_src_i   === 3'd3) ? 3'd3 :
                          (vel_upd_src_i   === 3'd4) ? 3'd4 : 3'd0;
    wire [2:0] pu_src_w = (pitch_upd_src_i === 3'd1) ? 3'd1 :
                          (pitch_upd_src_i === 3'd2) ? 3'd2 :
                          (pitch_upd_src_i === 3'd3) ? 3'd3 :
                          (pitch_upd_src_i === 3'd4) ? 3'd4 : 3'd0;

    //  ⭐⭐ 2026-10-01 修B（⭐ 章程 `§26.3-c`）：⭐ **`note_src_i` 也必须 Z-safe 解码** ⚠️
    //   🔴 **为什么必须**：⭐ 它进 `fifo_src` 排队 ⇒ ⭐ 若【悬空】（`z`）⇒ ⭐ `fifo_src` = `zzz`
    //      ⇒ ⭐ `cur_src` = `zzz` ⇒ ⭐ **`pool_mask` 变成 32 位全 `x`**
    //      ⇒ 🔴 **静默丢掉每一个事件** ✅（⭐ 章程实测旧回退版：⭐ **6/6 全丢** ⚠️）
    //   ⭐ **手法与上面 `vu_src_w`/`pu_src_w` 完全一致**：⭐ 未用编码 / 悬空 ⇒ ⭐ 当**手弹(0)** ✅
    //   📌 **收益**：⭐ 新 tb `tb_pool_by_src` 的 c1/c3/c4 三条由**红转绿** ✅
    //   📌 **真实设计里 `note_src_i` 是接上的**（⭐ `top.v` 的 `mg_evt_src`）⇒ ⭐ 本条是**防御层** ✅
    wire [2:0] ns_src_w = (note_src_i === 3'd1) ? 3'd1 :
                          (note_src_i === 3'd2) ? 3'd2 :
                          (note_src_i === 3'd3) ? 3'd3 :
                          (note_src_i === 3'd4) ? 3'd4 : 3'd0;

    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-30（时序，待上板验证）：⭐ **`env_level_i` / `env_active_i` 在模块入口打一拍**
    //
    //  🔴 **问题（⭐ PnR 报告原文，⛔ 不是推测）** ——
    //     `impl/pnr/Gowin2026_tr_content.html` 的最差 **25** 条 setup 路径**全部**是
    //     ```
    //     From g_sound.u_envelope_bank/g_voice_envelope[23].u_adsr/env_level_o_10_s0/Q
    //     To   g_sound.u_note_manager/{timbre_r|phase_r|vel_r|vtgt_rep}…/CE
    //     Path Slack = −3.756 ns    Data Delay = 23.539 ns    （⭐ 周期 20 ns）
    //     ```
    //     ⇒ ⭐ `Numbers of Setup Violated Endpoints = 4517` 与 `TNS = −10037.7`
    //       **全部出自这一条链**（⭐ 目标 `…/CE` 的端点总数
    //       = 32 voice × 全部数组寄存器 ≈ 4500 ✅）
    //
    //  📌 **延迟拆解（⭐ `impl/pnr/Gowin2026.timing_paths` 的节点到达时间）**：
    //     · ⭐ **逻辑（LUT）合计 ≈ 2.8 ns**
    //     · 🔴 **布线合计 ≈ 20.7 ns**（⭐ 四段长布线 **2.28 / 4.80 / 5.26 / 4.03 ns**）
    //     ⇒ ⭐ **纯布线/拥塞主导** —— ⭐ 而链的**结构**又是
    //       "**跨模块长线 ＋ 32 路选择 ＋ 32 路写译码**"
    //     ⇒ ⭐ 两者都要治：⭐ 本条治"跨模块长线"，⭐ 下方 `ST_RETRIG` 治"32 路选择+译码" ✅
    //
    //  ⭐ **本条做了什么**：⭐ 把 `env_level_i`（32×16 = **512 位**）与 `env_active_i`（32 位）
    //     在**进入本模块的第一拍**锁存 ⇒
    //     · ⭐ `adsr.v` 的 `assign active_o` 里 **16 位 `env_level_o != 0` OR 树**（⭐ 约 3 级 LUT）
    //       **离开了关键路径**（⭐ 它现在只喂"ADSR → 本寄存器"这条**短**路径）✅
    //     · ⭐ 跨模块那 512＋32 根长线变成 **FF → FF** 路径（⭐ 无逻辑、无宽扇出树）
    //       ⇒ ⭐ 布局器可以自由复制/缓冲 ✅
    //
    //  ⭐ **为什么⛔ 不改变可观测行为**（⭐ 两条，缺一不可）：
    //     ① `env_level_o` **只在 `sample_tick_i` 变**（⭐ 每 `CLK_PER_SAMPLE` = 1024 拍
    //        = 20.48 µs）⇒ ⭐ 晚 **1 拍（20 ns）** 读到的是"**同一个 tick 的值**"
    //        ⇒ ⭐ `cand_env`（"选电平最低的已 Release voice"）的**排序结果完全不变** ✅
    //     ② `env_active_o` 本来就**滞后 `sample_tick` 最多 1024 拍**（⭐ `adsr.v` 只在
    //        tick 更新 `state`/`releasing`）⇒ ⭐ 再晚 1 拍在它的时间尺度上可忽略 ✅
    //        📌 而且"变 0"（⭐ Release 结束）晚 1 拍 ⇒ ⭐ voice **更晚**被当成空闲
    //           ⇒ ⭐ 方向是**更保守**（⛔ 不会提前抢走还在响的 voice）✅
    //     ⚠️ **代价**：⭐ 512 ＋ 32 = **544 FF**（⭐ Register 25% → 25.2%，⭐ CLS +≈0.2%）
    //        ⇒ ⭐ 相对于"4517 个违例端点"完全可以接受 ✅
    //  ═══════════════════════════════════════════════════════════════════════
    reg [POLY_TARGET*ENV_W-1:0] env_level_r;
    reg [POLY_TARGET-1:0]       env_active_r;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            env_level_r  <= {(POLY_TARGET*ENV_W){1'b0}};
            env_active_r <= {POLY_TARGET{1'b0}};
        end else begin
            env_level_r  <= env_level_i;
            env_active_r <= env_active_i;
        end
    end

    // 重触发状态机编码
    localparam [1:0] RT_NONE = 2'd0;
    localparam [1:0] RT_LOW  = 2'd1;   // 已压低，等 sample_tick（让 ADSR 看见 0）
    localparam [1:0] RT_HIGH = 2'd2;   // 已抬高，等 sample_tick（让 ADSR 看见 1）

    // 扫描 FSM 编码（`T66`）
    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_DECIDE = 3'd1;   // 已取出事件，判"同轴位重触发"还是"扫描分配"
    localparam [2:0] ST_SCAN   = 3'd2;   // 每拍考察一个 voice
    localparam [2:0] ST_COMMIT = 3'd3;   // 提交选中结果
    //  ⭐⭐ 2026-09-29 `N-1`（Fmax 修复）：⭐ **提交流水级**
    //     🔴 **为什么加**：⭐ `ST_COMMIT` 原来**一个周期内**同时驱动 **7 个 32 路写译码**，
    //        而 `best_idx` 来自 **32 路扫描比较树**（⭐ 组合）
    //        ⇒ ⭐ **这就是 `note_manager` 那条关键路径**（⭐ 路径表里出现 **274** 次）✅
    //     ✅ **修法**：⭐ `ST_COMMIT` 只**锁存**参数 ⇒ `ST_COMMIT2` 用**寄存器输出**去写 ✅
    //     ⚠️ **代价**：⭐ 分配延迟 **+1 拍**（20 ns，⭐ 听感不可闻）· ⭐ **功能等价** ✅
    localparam [2:0] ST_COMMIT2 = 3'd4;  // ⭐ 用寄存后的 `cmt_idx_r` 写译码器
    //  ⭐⭐ 2026-09-30（时序，待上板验证）：⭐ **同轴重触发的写译码流水级**
    //     ⭐ 与 `ST_COMMIT2` **完全同构**（⭐ 同一个"选谁(组合) / 写谁(寄存)"分离模式）——
    //     理由见下方 `ST_RETRIG` 段与模块入口寄存器的注释 ✅
    localparam [2:0] ST_RETRIG = 3'd5;   // ⭐ 用寄存后的 `same_idx_r` 写译码器

    localparam integer SCAN_LAST = POLY_TARGET - 1;
    localparam integer SW = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET);   // 扫描计数位宽
    localparam integer FW = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);

    // ── 每 voice 独立状态（⭐ 冻结表禁令 4：⛔ 不共用相位/包络）─────────────
    reg                    gate_r   [0:POLY_TARGET-1];
    reg [AXIS_W-1:0]       axis_r   [0:POLY_TARGET-1];
    //  ⭐⭐ 2026-09-29（A1）：⭐ **每 voice 的来源标记**（⭐ 与 `axis_r` 同生共死）
    //     ⭐ 语义：⭐ "这个 voice 是**谁**起音的" ⇒ `note_off` 只清**同源**的
    //     ⚠️ 它**必须与 `axis_r` 在同一条写路径上更新**（⛔ 否则会留下"源不明"的 voice
    //        ⇒ `note_off` 永远匹配不上 ⇒ 🔴 挂音，正是 `T38` 要防的失效模式）
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3**（⭐ 编码表见 `note_src_i`）
    reg [2:0]              src_r    [0:POLY_TARGET-1];
    reg [PHASE_W-1:0]      phase_r  [0:POLY_TARGET-1];

    // ⭐⭐ 2026-10-01：⭐ **T2 起始音 —— 八度锁存**（⭐ 见端口处 `base_semi_i` 的说明）
    //   ⚠️ **安全重做（⭐ 按 `交接文档-20260930-补遗.md:54`）**：
    //      ① ⭐ **显式 `case` 常量** —— ⛔ 不做运行期 `/12`（⭐ 那会引一个除法器 ⚠️）
    //         📌 与 `axis_map`"查表不做运行期指数"是**同一条纪律** ✅
    //      ③ ⭐ **先校验再提交** —— ⭐ 只认 `0/12/24`，⭐ 其余**一律回 `0`**（⭐ ⛔ 不写非法值 ✅）
    //   📌 **范围收窄 0..2**（⭐ C4 / C5 / C6 三档）—— ⭐ §54 明确要求 ✅
    //   ⚠️ **自带复位**（⭐ 独立 `always`）⇒ ⛔ 不必改动主复位块 ✅
    reg [1:0] base_oct_r;
    always @(posedge clk_i) begin
        if (!rst_n_i) base_oct_r <= 2'd0;
        else if (base_commit_i) begin
            case (base_semi_i)
                7'd0 :   base_oct_r <= 2'd0;   // ⭐ C4（⭐ 默认）
                7'd12:   base_oct_r <= 2'd1;   // ⭐ C5
                7'd24:   base_oct_r <= 2'd2;   // ⭐ C6
                default: base_oct_r <= 2'd0;   // 🔴 非法值 ⇒ ⭐ 回到 0
            endcase
        end
    end
    reg [VEL_W-1:0]        vel_r    [0:POLY_TARGET-1];
    //  ⭐⭐ 2026-09-28：**力度更新的挂起寄存器**（⭐ 修"又响又尖"，⭐ 见 `K-154`）
    //   ⚠️ **必须在【模块级】** —— 🔴 Verilog-2001 要求"声明先于语句"，
    //      ⛔ 不能写在 `always` 块中间（⭐ 第一版踩过：40+ 连锁语法错）
    //  ⭐⭐ 2026-09-29 重构：⭐ **每个轴各记一个"目标力度"**（⭐ 取代原来的单寄存器 ✅）
    //   🔴 **原缺陷（⭐ 上板实测"同深度不同时间音量不同"）**：
    //      ⭐ 原来只有**一个** `vu_ax_pend_r`/`vu_val_pend_r` ✅ ⇒ ⚠️ 若 `top.v` 的扫描器
    //      **先于** `event_extract` 看到 `pos` 跳变 ⇒ ⭐ 那次 `vel_upd` 到达时
    //      **还没有 voice**（⭐ `gate_mask[i]=0` ✅）⇒ 🔴 **被丢掉** ✅
    //      而 `top.v` 的死区参考**已经更新** ⇒ 🔴 **永不再发** ⇒ `vel` 卡在起音值 ✅
    //   ✅ **本修法**：⭐ **目标按轴保存**（⛔ 不依赖"那一次有没有 voice" ✅）
    //      ⇒ ⭐ 丢一次也无所谓 —— ⭐ 目标还在，⭐ 下一个 `sample_tick` 接着爬 ✅
    //      ⇒ ⭐ **自愈** ✅ ⇒ ⭐ `top.v` **一个字都不用改** ✅
    //   📌 **为什么在接收端修**（⭐ 而不是去 `top.v` 清死区参考 ✅）：
    //      ⚠️ 上板 `Q_velrace` 完全没声音 —— ⭐ 那一版正是在 `top.v` 里写
    //      `vu_last[<变量索引>]`（⭐ 且对 `integer` 型 `localparam` 位选 ⇒ 违反 `K-91` ✅）
    //      ⇒ ⭐ **教训**：⭐ **"发端去重"和"收端记住目标"，⭐ 该修收端** ✅
    //   ⚠️ **代价**：⭐ 16 轴 × (8 位目标 + 1 位有效) = **144 FF** ✅（⭐ 实测 +5 Reg ⇒ 综合器折掉大半 ✅）
    reg [VEL_W-1:0]        vtgt_val [0:(1<<AXIS_W)-1];   // ⭐ 每轴的目标力度
    reg                    vtgt_vld [0:(1<<AXIS_W)-1];   // ⭐ 该轴是否收到过目标（⛔ 永不清）
    //  ⭐⭐ 2026-09-29 新增：⭐ **非手弹源（回放）的"每 voice 目标"**（⭐ 见 `(d)` 段）
    //   🔴 **为什么不复用上面那套"每轴目标"**：
    //      ⚠️ "每轴目标"**每轴只有一份** ⇒ ⭐ 回放与手弹在同一轴时会**互相覆盖**
    //      ⇒ 🔴 两边的 voice **都被对方的手势拖走** ✅
    //   ⭐ 而**回放的目标可以按 voice 存**（⭐ 手弹不行）：
    //      · ⭐ 手弹的更新**可能早于 voice 出现**（⭐ `K-154`：`top.v` 的扫描器先看到
    //        `pos` 跳变 ⇒ 那次更新到达时还没有 voice）⇒ ⭐ **必须按轴记住**才能自愈 ✅
    //      · ⭐ 回放的更新由 `looper` **每个 tick 发一条**（⭐ 0.52 ms @120 BPM），
    //        而 voice 在 `note_on` 重放后 **≤34 拍（0.68 µs）**就分配好了
    //        ⇒ ⭐ **结构上不可能"更新早于 voice"** ⇒ ⭐ 按 voice 存**不会丢** ✅
    //   📌 代价：⭐ 每 voice 8 位（32×8 = **256 FF**），⭐ ⛔ **不引入任何 mux**
    //      （⚠️ 若改成"按 (源,轴) 索引"的 64 项目标表 ⇒ 🔴 每 voice 一个 64:1 mux
    //        ⇒ ⭐ 约 **+6000 LUT**，⭐ 那才是真正贵的地方）✅
    //   ⚠️ **必须在分配/重触发那一刻用"本次事件的力度"初始化** ——
    //      ⭐ 否则会残留**上一个音**的目标 ⇒ 🔴 新音一响就被拉走 ✅
    reg [VEL_W-1:0]        vtgt_rep [0:POLY_TARGET-1];
    //  ⭐ 2026-10-04（codex 候选三第 2 项）：力度斜坡的**临时**目标
    //     —— 见下方"先选目标，再走一套 ±8 斜坡"（原来是手弹/回放各一套逐字相同的斜坡）。
    //     ⚠️ 它们是**过程内临时量**（阻塞赋值），不是状态。
    reg [VEL_W-1:0]        vel_tgt;
    reg                    vel_tgt_vld;
    reg [TIMBRE_W-1:0]     timbre_r [0:POLY_TARGET-1];
    reg [AGE_W-1:0]        age_r    [0:POLY_TARGET-1];

    // ── 重触发保持（压低期间该 voice 的 gate 必须表现为 0）──────────────────
    //  ⭐⭐ **2026-09-28 根因修复（B3 挂音）：重触发压低改成【每 voice 一位的位图】**
    //
    //  🔴 **原缺陷**：用 `retrig_hold` + `retrig_idx` + `retrig_state` **单套全局寄存器**
    //     描述一个**本质上是每 voice 一个**的操作 ⇒ 三条后果：
    //
    //   ① 🔴 **`note_off` 清不掉正在重触发的 voice**
    //      `gate_mask[i] = gate_r[i] & ~hold_mask[i]`，而压低期间 `hold_mask[i]=1`
    //      ⇒ `gate_mask[i]=0` ⇒ `ST_DECIDE` 的 off 分支**跳过该 voice**；
    //      同时 (f) 段每拍把它抬回 1 ⇒ ⭐ **清了又被拉回** ⇒ **永久挂音**。
    //      ⭐ 与用户实测吻合：「挂音的音高是我按过的键」「按同键/所有键都清不掉」
    //         「⭐ 按了几次以后才会触发」（同轴快速连按才进 RT_LOW）
    //
    //   ② 🔴 **`retrig_idx` 被抢占 ⇒ 孤儿 voice**
    //      两个轴在同一窗口内先后重触发时，后者覆盖 `retrig_idx`
    //      ⇒ 前一个 voice 的 `retrig_hold` **永远没人清**
    //      ⇒ 它的 `gate_mask` 永久为 0 ⇒ **既不能发声、也不能被分配**。
    //
    //   ③ 🔴 **`note_off` 与 (f) 撞在 `sample_tick` 那一拍**
    //      off 分支把 `retrig_state` 推回 `RT_NONE`（于是 (f) 不再管它），
    //      但**同一拍 (f) 刚把 `gate_r[retrig_idx] <= 1`** ⇒ `gate_r` **永久卡在 1**。
    //
    //  ✅ **修法（最稳健）**：⭐ **位图** —— 每个 voice 一位，
    //     · ⛔ 不存在"被抢占"（① 的 ② 消失）
    //     · ⭐ `note_off` 判据改用 `gate_r | retrig_low`，**并同时清位图**
    //       ⇒ `(g)` 段在 `(f)` 之后 ⇒ ⭐ **`note_off` 无条件优先**（① 的 ①③ 消失）
    //     · ⭐ 顺带去掉 32 个 5 位比较器 ⇒ **改善 Fmax**
    //  📌 语义等价：原 `RT_LOW + RT_HIGH` 两步 = "压低到 `sample_tick` 后抬高"，
    //     位图版本完全一致（`retrig_low[i]` 在 tick 时清 0 并同时 `gate_r[i] <= 1`）。
    reg [POLY_TARGET-1:0]  retrig_low;

    // ── ⭐ 三个 mask（`assign` + `generate`，⛔ 不用 `always @(*)` —— `L67`）──
    //    ⭐ 语义：
    //      · gate_mask —— 对外门（重触发压低期间为 0，让 ADSR 看到下降沿）
    //      · live_mask —— **还能出声**（含 Release 尾巴 + 重触发保持）⇒ 给振荡器用
    //      · free_mask —— 完全空闲（⭐ 重触发保持**不算**空闲，否则会被别的轴抢走）
    wire [POLY_TARGET-1:0] hold_mask;
    wire [POLY_TARGET-1:0] gate_mask;
    wire [POLY_TARGET-1:0] live_mask;
    wire [POLY_TARGET-1:0] free_mask;
    genvar mg;
    generate
        for (mg = 0; mg < POLY_TARGET; mg = mg + 1) begin : gen_mask
            assign hold_mask[mg] = retrig_low[mg];
            assign gate_mask[mg] = gate_r[mg] & ~hold_mask[mg];
            assign live_mask[mg] = gate_r[mg] | hold_mask[mg] | env_active_r[mg];
            assign free_mask[mg] = ~live_mask[mg];
        end
    endgenerate

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 事件队列（`T66`）—— 扫描要 34 拍，期间到达的事件⛔ 不能丢
    //    ⚠️ 为什么必须有：第一版是**单拍组合**，每个事件各占一拍 ⇒ 天然能背靠背；
    //       改成流水后，**同一拍只能处理一个事件** ⇒ 必须排队。
    //    ⚠️ 深度 16 的依据：`AXIS_N=16` ⇒ 一个采集帧内每轴最多一个事件。
    // ═══════════════════════════════════════════════════════════════════════
    reg                    fifo_v   [0:FIFO_DEPTH-1];
    reg [AXIS_W-1:0]       fifo_ax  [0:FIFO_DEPTH-1];
    reg [PHASE_W-1:0]      fifo_inc [0:FIFO_DEPTH-1];
    reg [VEL_W-1:0]        fifo_vel [0:FIFO_DEPTH-1];
    reg [1:0]              fifo_knd [0:FIFO_DEPTH-1];
    reg                    fifo_timbre_valid [0:FIFO_DEPTH-1];
    reg [TIMBRE_W-1:0]     fifo_timbre [0:FIFO_DEPTH-1];
    //  ⭐ A1：⭐ 来源标记**随事件一起排队**（⭐ 与 `fifo_timbre` 完全同样的手法）
    //     ⚠️ 必须排队而⛔ 不能"取队列头时直接看活的 `note_src_i`" ——
    //        ⭐ 队列里的每条事件是**不同拍**到达的，源也就可能不同。
    reg [2:0]              fifo_src [0:FIFO_DEPTH-1];
    reg [FW-1:0]           fifo_wr;
    reg [FW-1:0]           fifo_rd;
    reg [FW:0]             fifo_cnt;

    wire fifo_full  = (fifo_cnt == FIFO_DEPTH[FW:0]);
    wire fifo_empty = (fifo_cnt == {(FW+1){1'b0}});

    // ⭐⭐ 所有事件**都进队列**（含 `note_off`）—— ⚠️ 这是**顺序正确性**的要求：
    //    ⛔ 若 `note_off` 走"立即执行"的旁路，而它对应的 `note_on` 还在队列里没处理，
    //       则 `note_off` 会**清了个空**，随后队列里的 `note_on` 才分配 voice
    //       ⇒ ⭐ **那个音永远关不掉（挂音）** —— 正是 Looper 的 `T38` 要防的失效模式。
    //    ⇒ ⭐ 统一排队 ⇒ **事件顺序严格保持**。
    //    ⭐ 代价：`note_off` 多 1~2 拍延迟（0.04 µs），可忽略。
    //    ⚠️ `state` 必须**先声明**（`fifo_pop` 要用它）
    reg [2:0] state;

    wire fifo_push = note_valid_i && !fifo_full;
    wire fifo_pop  = (state == ST_IDLE) && !fifo_empty;

    // ⭐⭐ 溢出丢弃检测（`K-106`）—— 🔴 **这一条就是"静默丢弃"的修复**
    //    ⚠️ `note_valid_i && fifo_full` 正是"来了事件但队列满 ⇒ 丢掉"的那一拍。
    //    ⭐ 与 `fifo_push` **互补且互斥**（push 要求 !full）⇒ 同拍只会有一个为真。
    wire fifo_drop = note_valid_i && fifo_full;

    // ⭐ 丢弃计数（**饱和**，⛔ 不回绕 —— ⚠️ 回绕会把"丢了 256 个"显示成"丢了 0 个"，
    //    那又是**另一种静默**，与 `K-106` 的纪律直接冲突）
    reg  [EVT_LOST_CNT_W-1:0] lost_cnt_r;
    reg                       lost_sticky_r;
    wire lost_cnt_sat = (lost_cnt_r == {EVT_LOST_CNT_W{1'b1}});   // 已达上限则不再加

    // 指向队列头（用于 `ST_DECIDE` 取出）
    wire [AXIS_W-1:0]  head_axis = fifo_ax [fifo_rd];
    wire [PHASE_W-1:0] head_inc  = fifo_inc[fifo_rd];
    wire [VEL_W-1:0]   head_vel  = fifo_vel[fifo_rd];
    wire [1:0]         head_kind = fifo_knd[fifo_rd];
    wire               head_timbre_valid = fifo_timbre_valid[fifo_rd];
    wire [TIMBRE_W-1:0] head_timbre = fifo_timbre[fifo_rd];
    wire [2:0]         head_src    = fifo_src[fifo_rd];   // ⭐ A1：本条事件的来源

    // ── 当前正在处理的事件（从队列头锁存）────────────────────────────────
    reg [AXIS_W-1:0]  cur_axis;
    reg [PHASE_W-1:0] cur_inc;
    reg [VEL_W-1:0]   cur_vel;
    reg [1:0]         cur_kind;
    reg               cur_timbre_valid;
    reg [TIMBRE_W-1:0] cur_timbre;
    reg [2:0]         cur_src;         // ⭐ A1：本条事件的来源（⭐ 与 `cur_kind` 同拍锁存）

    // ── ⭐ 池掩码：由**锁存后的** `cur_axis` 决定（⛔ 不是活的 `note_axis_i`）──
    //    ⚠️ 必须用 `assign` + `generate`（`L67`：常量块在 `always @(*)` 里不执行）
    wire [POLY_TARGET-1:0] pool_mask;
    genvar pg;
    generate
        for (pg = 0; pg < POLY_TARGET; pg = pg + 1) begin : gen_pool
            if (RESERVED_N == 0)
                assign pool_mask[pg] = 1'b1;
            else
                // ⭐⭐ 2026-10-01 修B：⭐ **进不进保留池由【来源】定，⛔ 不再由轴号定** ✅
                //   🔴 **原缺陷**：⭐ 按 `cur_axis >= 14` 选池 ⇒ ⭐ **物理键 14/15（G#3/A#3）
                //      被送进只有 `RESERVED_N=5` 个 voice 的保留池** ⇒ 🔴 **那两个键不响** ✅
                //   ⭐ **为什么按来源才对**：⭐ 保留池的本意是"**给节拍器/鼓机专用**"（⭐ `T33b`），
                //      那是【来源】属性（⭐ `SRC_AUX`），⛔ **不是【轴号】属性** ✅
                //      ⇒ ⭐ 现场手弹（`src == 0`）**无论按哪个键**都该进普通池 ✅
                //   ⚠️ 用 `cur_src`（⭐ 锁存后的）⛔ 不用活的 `note_src_i`（⭐ 与 `cur_axis` 同纪律）
                assign pool_mask[pg] = (cur_src == SRC_AUX)
                                       ? (pg >= NORMAL_N)
                                       : (pg < NORMAL_N);
        end
    endgenerate

    // ── ⭐ 同轴位重触发检测（**组合 OR 树**，⛔ 无链式依赖 ⇒ 深度 ~5 级，可接受）──
    wire [POLY_TARGET-1:0] same_hit;
    genvar sg;
    generate
        for (sg = 0; sg < POLY_TARGET; sg = sg + 1) begin : gen_same
            //  ⭐⭐ **2026-09-28 根因修复（B2「偶发尖音」）**：
            //     `same_hit` 判"同键还在响"必须用 **`live_mask`**（含 Release 尾巴），
            //     ⛔ 不能用 `gate_mask`（那只是"对外门"）。
            //
            //  🔴 **原缺陷**：`same_hit = gate_mask & (axis_r==cur_axis)`，而
            //     `gate_mask = gate_r & ~retrig_low` ⇒ ⭐ **松手后（`gate_r=0`）
            //     尾巴还在响（`env_active_i=1`）时为 0** ⇒ `same_valid=0`
            //     ⇒ ⭐ 走 `ST_SCAN` **另分配一个 voice**（同 `axis_r`、同 `phase_inc`）。
            //
            //  🔴 **后果（⭐ 与 DS0004 实测吻合，已量化）**：
            //     · 旧尾巴（≤51200）+ 新起音峰（`velocity<<8 = 51200`）
            //       = 102400 = ⭐ **8 × sustain(12800)**
            //     · 再乘 `tdm_render_mixer` **无斜坡**的 `1/√N` 增益台阶
            //       （n=2→62 而正常段 n=4→44 ⇒ ×1.41；n=8→31 ⇒ ×2.0）
            //       ⇒ ⭐ **8 × 1.41 ≈ 11.3 倍** ⇒ 落进 DS0004 的 **10.6~11.1 倍**
            //     · 两个 voice **同音高** ⇒ 基频一致 ✅
            //     · 绝对值仅约满幅 1.4% ⇒ 限幅器不介入 ⇒ **无平顶** ✅
            //     · 重按间隔落在 Release 窗口内的比例 ≈ 一半
            //       （`REFRACT_N=60`=30 ms 又挡掉了更快的重按）⇒ ⭐ **~50%** ✅
            //
            //  📌 **为什么 B2-a（`retrig_reset` 电平化）没消除它**：
            //     那条修的是【复用同一 voice】的重触发路径；⭐ 而走"**新分配**"这条路时
            //     旧 voice 的尾巴**不会被清零**（`ST_COMMIT` 只对 `best_idx` 发 reset）
            //     ⇒ 尖音从这条缝里活下来。
            //
            //  ✅ **修法**：改用 `live_mask` ⇒ "尾巴未结束的再按"也算同键还在响
            //     ⇒ 走 `same_valid` ⇒ 拿到 `retrig_low` + `retrig_reset` ⇒ ⭐ **干净重启**。
            //  📌 判据（Verilator 定向探针，红→绿）：
            //     `note_on(A) → note_off(A) → 等 2 帧 → note_on(A)`
            //     数"axis==A 且 live_mask==1"的 voice 个数
            //     ⭐ 原始：**2**（DUPLICATE）⇒ 修复后：**1**（复用）
            //
            //  ⭐⭐ **2026-09-29（A3'）⭐ voice 复用也必须【按来源】判定** ✅
            //
            //  🔴 **原缺陷（⭐ 用户上板实测，⭐ 与 A1 是同一个缺陷的【另一半】）**：
            //     本行只比 `axis_r`、⛔ **不比 `src_r`** ⇒ ⭐ "**先按住**轴 X 的手弹键、
            //     **再**开始 looper 回放"时，回放（`score`）在同轴的 `note_on`
            //     **命中的正是手弹那个 voice** ⇒ 走下面 `ST_DECIDE` 的"同轴重触发"路径：
            //        · 🔴 `retrig_reset` ⇒ **手弹的包络被清零**（⭐ 音被重启）
            //        · 🔴 `src_r[same_idx] <= cur_src` ⇒ **该 voice 被改判成回放的**
            //      ⇒ ⭐ 回放的 `note_off` 一到就把它清掉，而**手弹不会再发 `note_on`**
            //        （⭐ 键一直按着）⇒ 🔴 **键还按着却永久静音** ✅
            //      📌 **用户原话**：⭐ *"从回放一开始就没声了"*，⭐ 且**只在"先按住键、
            //         再开始回放"时出现** —— ⭐ 与"先回放、后按键"的对比完全吻合：
            //         后者 `same_hit` 命中的是**回放自己的** voice ⇒ 行为本来就对 ✅
            //
            //  ⚠️ **为什么 A1 单独不够**（⭐ 这一条是本行的存在理由）：
            //     A1 只改了 `note_off`（⭐ "**清谁**"）⭐ 这一半；⚠️ 而 `src_r` 会被
            //     重触发路径**就地改写** ⇒ ⭐ 手弹 voice 一被接管，A1 的隔离**同时失效**
            //     （⭐ 它已经"不是手弹的"了）⇒ 🔴 必须把"**占谁**"这一半也按来源判定 ✅
            //
            //  ✅ **修法**：⭐ 加 `src_r[sg] == cur_src` ⇒ ⭐ 回放的 `note_on`
            //     **绝不接管手弹的 voice**（⭐ 反向亦然）⇒ ⭐ **同轴两个 voice 并存** ✅
            //  📌 **⛔ 不削弱任何纪律**：
            //     · ⭐ 下面 `ST_DECIDE` 的 `note_off` 仍是"**清所有 `axis` 与 `src`
            //       都匹配的 voice**"（⭐ `T38` 防挂音纪律，⛔ 一个字都不改）✅
            //     · ⭐ `src_r` 与 `axis_r` 永远在**同一条写路径上同拍更新**
            //       （`ST_COMMIT2` / 重触发各一处）⇒ ⭐ **不留"源不明"的 voice**
            //       ⇒ ⭐ 任何 voice 都**清得掉** ⇒ ⛔ **不引入新的挂音** ✅
            assign same_hit[sg] = (gate_r[sg] | retrig_low[sg] | env_active_r[sg])
                                && (axis_r[sg] == cur_axis)
                                && (src_r[sg]  == cur_src);
        end
    endgenerate
    wire same_valid = |same_hit;

    // 最低索引优先编码（升序扫 + 只在未命中时赋值）
    reg [IDX_W-1:0] same_idx;
    integer qi;
    always @(*) begin
        same_idx = {IDX_W{1'b0}};
        for (qi = POLY_TARGET - 1; qi >= 0; qi = qi - 1)
            if (same_hit[qi]) same_idx = qi;
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 扫描用的**单 voice 候选**（每拍只算一个 ⇒ 深度 32:1 mux + 比较）
    //    类别：0 = 空闲（最优）＞ 1 = 已 Release 且电平最低 ＞ 2 = 年龄最老（真抢占）
    //    ⚠️ 重触发保持中的 voice **完全排除**（⛔ 不能被抢）
    //    ⚠️ 2026-09-29（A3' 续）：**同轴但异源且仍按住**的 voice **也完全排除**
    //       （⭐ 理由见下方 `cand_foreign`；⭐ 否则池满时回放会抢走手弹的音）✅
    // ═══════════════════════════════════════════════════════════════════════
    reg [SW-1:0]     scan_cnt;
    // Registered predecode: same edge as scan_cnt, no extra scan/commit cycle.
    // Keep the one-hot state and eight-voice group boundaries in the netlist.
    (* syn_preserve = 1 *) reg [POLY_TARGET-1:0] scan_sel;
    localparam integer SCAN_GROUPS = (POLY_TARGET + 7) / 8;
    localparam integer SCAN_ATTR_W = 5 + AXIS_W + 3 + ENV_W + AGE_W;
    (* syn_keep = 1 *) wire [SCAN_ATTR_W-1:0] scan_group [0:SCAN_GROUPS-1];
    wire [SCAN_ATTR_W-1:0] scan_merge [0:SCAN_GROUPS];
    assign scan_merge[0] = {SCAN_ATTR_W{1'b0}};
    genvar scan_g, scan_l;
    generate
        for (scan_g = 0; scan_g < SCAN_GROUPS; scan_g = scan_g + 1) begin : g_scan_group
            wire [SCAN_ATTR_W-1:0] leaf [0:7];
            for (scan_l = 0; scan_l < 8; scan_l = scan_l + 1) begin : g_scan_voice
                if (scan_g*8+scan_l < POLY_TARGET) begin : g_present
                    assign leaf[scan_l] = {SCAN_ATTR_W{scan_sel[scan_g*8+scan_l]}} &
                        {hold_mask[scan_g*8+scan_l], pool_mask[scan_g*8+scan_l],
                         free_mask[scan_g*8+scan_l], gate_mask[scan_g*8+scan_l],
                         env_active_r[scan_g*8+scan_l], axis_r[scan_g*8+scan_l],
                         src_r[scan_g*8+scan_l],
                         env_level_r[(scan_g*8+scan_l)*ENV_W +: ENV_W], age_r[scan_g*8+scan_l]};
                end else begin : g_padding
                    assign leaf[scan_l] = {SCAN_ATTR_W{1'b0}};
                end
            end
            assign scan_group[scan_g] = leaf[0] | leaf[1] | leaf[2] | leaf[3]
                                 | leaf[4] | leaf[5] | leaf[6] | leaf[7];
            assign scan_merge[scan_g+1] = scan_merge[scan_g] | scan_group[scan_g];
        end
    endgenerate
    reg              best_valid;
    reg [IDX_W-1:0]  best_idx;
    reg [1:0]        best_cls;
    reg [ENV_W-1:0]  best_env;
    reg [AGE_W-1:0]  best_age;

    // 当前扫描位的候选属性（组合，深度浅）
    wire [IDX_W-1:0]   cand_idx   = scan_cnt[IDX_W-1:0];
    wire cand_hold, cand_pool, cand_free, cand_gate, cand_active;
    wire [AXIS_W-1:0] cand_axis;
    wire [2:0] cand_src;
    wire [ENV_W-1:0] cand_env;
    wire [AGE_W-1:0] cand_age;
    assign {cand_hold, cand_pool, cand_free, cand_gate, cand_active,
            cand_axis, cand_src, cand_env, cand_age} = scan_merge[SCAN_GROUPS];
    wire cand_rel = (~cand_gate) & cand_active;
    //  ⭐⭐ **2026-09-29（A3' 续）⭐ 抢占候选也必须【按来源】排除** ✅
    //
    //  🔴 **为什么 `same_hit` 加来源判据还不够**（⭐ 这两条守的是**同一缺陷的两条路**）：
    //     · ⭐ `same_hit` 管的是"**复用**"—— ⭐ "同轴已有 voice ⇒ 就用它" ✅
    //     · ⭐ 而**池满**时新音走的是**抢占**这条路 ⇒ ⚠️ 原来的候选比较
    //       （`cand_ok`/`cand_better`）**只看 空闲/已 Release/年龄，⛔ 完全不看来源**
    //     ⇒ 🔴 池满时回放（`score`）会去抢**手弹那个"最老的" voice**，并在
    //        `ST_COMMIT2` 里把它**改判**成自己的（`axis_r`/`src_r`/`vel_r` 全被覆盖）
    //     ⇒ 🔴 **症状与 A3' 修的那个一模一样**：⭐ 键还按着，手弹的音却没了 ✅
    //     📌 只是窗口从"**必然发生**"收窄到"**池真的满了**"—— ⚠️ 但**症状仍在**，
    //        所以必须一起收掉（⭐ 这是 `K-56` 的纪律：⭐ **修一半等于没修**）✅
    //
    //  ✅ **修法**：⭐ 把"`axis_r == cur_axis` 且 `src_r != cur_src` 且**仍按住**
    //     （`gate_mask`=1）"的 voice **从候选里排除** ⇒ ⭐ 池满时回放只能去抢
    //     **别的** voice（⭐ 即"抢最老"的原有纪律照旧生效，只是**换了对象**）✅
    //     ⚠️ 只排除 **`gate_mask`=1** 的（⭐ "仍按住"）：⭐ 已松手只剩 Release 尾巴的
    //        异源同轴 voice **照样可以抢** —— ⭐ 它本来就是**最优牺牲品**（class 1）✅
    //
    //  📌 **为什么⛔ 不会退化成"丢音"**（⭐ 已算，⭐ 见报告）：
    //     ⭐ 每个 `(axis, src)` 同时**最多只有 1 个在响**的 voice（⭐ 因为同源
    //        `note_on` 一定被 `same_hit` 命中 ⇒ 走复用、⛔ 不会占第二个）✅
    //     ⇒ ⭐ 同轴上"异源且按住"的 voice **最多 4 个**（⭐ 源共 5 种：0/1/2/3/4）
    //        ⚠️ **2026-09-30 更新**：⭐ 原来是 4 种（0/1/2/3）⇒ 最多排除 3 个；
    //           ⭐ 加了 `3'd4`（looper）⇒ **最多排除 4 个**（⭐ 结论不变：仍排不空）✅
    //     ⇒ ⭐ **普通池 27 个候选里最多排除 4 个** ⇒ `best_valid` 必然仍为 1 ✅
    //     （⭐ 若真排空 ⇒ `best_valid`=0 ⇒ 事件被丢 —— ⭐ 那是 `P2-1` 的守卫，
    //       ⚠️ 不是本行引入的；本行在**普通池**上结构性地排不空 ✅）
    //  ⚠️ **已知边界（⭐ 未修，⭐ 实际不可达）**：⭐ **保留池只有 5 个**（`RESERVED_N=5`，
    //     轴 14/15）⇒ ⚠️ 理论上"4 个异源按住 ＋ 1 个正在 `retrig_low`"会把候选排空
    //     ⇒ 丢一个事件。⭐ 但轴 14/15 是节拍器/鼓机专用（源 3），⭐ 现实中不会同时
    //     有 4 个异源在响 ⇒ ⭐ 判定为**不可达**，⛔ 不为它加复杂度（`K-91` 同族：
    //     ⭐ 别为不可达的分支把主路径搞复杂）✅
    wire               cand_foreign = (cand_axis == cur_axis)
                                   && (cand_src  != cur_src)
                                   && cand_gate;
    wire [1:0]         cand_cls   = cand_free ? 2'd0 : (cand_rel ? 2'd1 : 2'd2);

    // ⭐ "更优"判据（⛔ 只用一级比较；升序扫描 + 严格优于 ⇒ 并列取最低索引）
    wire cand_ok = cand_pool & ~cand_hold & ~cand_foreign;
    wire cand_better =
            (~best_valid)
         || (cand_cls < best_cls)
         || ((cand_cls == best_cls) &&
             ( ((cand_cls == 2'd1) && (cand_env < best_env))
            || ((cand_cls == 2'd2) && (cand_age > best_age)) ));

    // ── 提交时用的字段（组合取自 best_idx）────────────────────────────────
    wire [VEL_W-1:0]    new_vel    = (cur_vel != {VEL_W{1'b0}}) ? cur_vel : DEFAULT_VEL_V;
    // Timbre is stored with the event.  Allocation may start dozens of clocks
    // after note_valid_i, so sampling the live sideband here would assign a
    // later event's timbre to the wrong voice.
    wire [TIMBRE_W-1:0] new_timbre = cur_timbre_valid ? cur_timbre : default_timbre_i;

    reg                    alloc_valid_r;
    reg [IDX_W-1:0]        alloc_voice_r;
    //  ⭐⭐ 2026-09-29 `N-1`：⭐ **提交流水级的锁存寄存器**（⭐ 见 `ST_COMMIT2`）
    //     📌 **为什么必须锁存**：⚠️ `best_idx` / `cur_*` / `new_*` 到 `ST_COMMIT2` 那一拍
    //        **已经可能变了**（⭐ `ST_SCAN` 会改写 `best_*`）⇒ ⭐ 直接引用会**写错 voice** ✅
    reg                    cmt_en_r;
    reg [IDX_W-1:0]        cmt_idx_r;
    reg [AXIS_W-1:0]       cmt_axis_r;
    reg [PHASE_W-1:0]      cmt_inc_r;
    reg [VEL_W-1:0]        cmt_vel_r;
    reg [TIMBRE_W-1:0]     cmt_timbre_r;
    reg [2:0]              cmt_src_r;   // ⭐ A1：来源标记也走提交流水级（⭐ 与 `axis_r` 同拍写）
    //  ⭐⭐ 2026-09-30（时序，待上板验证）：⭐ **同轴重触发的流水级锁存**（⭐ 见 `ST_RETRIG`）
    //     ⭐ `same_en_r` = "本拍要写"（⭐ 由 `same_valid` 锁存）· ⭐ `same_idx_r` = "写哪个 voice"
    //     📌 为什么要寄存：⭐ `same_idx` 来自 **32 路优先编码器**，而写译码又是 **32 路比较**
    //        ⇒ ⭐ 组合地串成一拍 = **4517 个违例端点**（⭐ 理由详见 `ST_DECIDE`/`ST_RETRIG`）✅
    reg                    same_en_r;
    reg [IDX_W-1:0]        same_idx_r;
    //  ⭐ 重触发清零脉冲：**单周期**（每 clk 先清、由 (f)/(g) 两处按需置位）
    reg  [POLY_TARGET-1:0] retrig_reset_r;
    integer i;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (i = 0; i < POLY_TARGET; i = i + 1) begin
                gate_r[i]   <= 1'b0;
                axis_r[i]   <= {AXIS_W{1'b0}};
                src_r[i]    <= 3'd0;          // ⭐ A1：来源标记（⭐ 默认 0 = live）
                phase_r[i]  <= {PHASE_W{1'b0}};
                vel_r[i]    <= {VEL_W{1'b0}};
                timbre_r[i] <= {TIMBRE_W{1'b0}};
                age_r[i]    <= {AGE_W{1'b0}};
                //  ⭐⭐ 2026-09-29：⭐ 非手弹源（回放）的每 voice 目标也要复位 ✅
                vtgt_rep[i] <= {VEL_W{1'b0}};
            end
            //  ⭐ 2026-09-29：每轴目标力度也要复位（⭐ 否则上电 `X` ⇒ 可能发假更新 ✅）
            //   📌 按**轴数**循环（⭐ ⛔ 不放在上面 `POLY_TARGET` 的循环里 ——
            //      那两个数组的长度是**轴数**，⛔ 不是 voice 数 ✅）
            for (i = 0; i < (1<<AXIS_W); i = i + 1) begin
                vtgt_val[i] <= {VEL_W{1'b0}};
                vtgt_vld[i] <= 1'b0;
            end
            for (i = 0; i < FIFO_DEPTH; i = i + 1) fifo_v[i] <= 1'b0;
            fifo_wr       <= {FW{1'b0}};
            fifo_rd       <= {FW{1'b0}};
            fifo_cnt      <= {(FW+1){1'b0}};
            retrig_low    <= {POLY_TARGET{1'b0}};
            state         <= ST_IDLE;
            scan_cnt      <= {SW{1'b0}};
            scan_sel      <= {{(POLY_TARGET-1){1'b0}}, 1'b1};
            best_valid    <= 1'b0;
            best_idx      <= {IDX_W{1'b0}};
            best_cls      <= 2'd0;
            best_env      <= {ENV_W{1'b0}};
            best_age      <= {AGE_W{1'b0}};
            cur_axis      <= {AXIS_W{1'b0}};
            cur_inc       <= {PHASE_W{1'b0}};
            cur_vel       <= {VEL_W{1'b0}};
            cur_kind      <= 2'd0;
            cur_timbre_valid <= 1'b0;
            cur_timbre    <= {TIMBRE_W{1'b0}};
            cur_src       <= 3'd0;            // ⭐ A1：来源标记也复位（⛔ 不留 X）
            alloc_valid_r <= 1'b0;
            alloc_voice_r <= {IDX_W{1'b0}};
            // ⭐ 2026-09-29 `N-1`：提交流水级的锁存寄存器（⭐ 见 `ST_COMMIT2`）
            cmt_en_r      <= 1'b0;
            cmt_idx_r     <= {IDX_W{1'b0}};
            cmt_axis_r    <= {AXIS_W{1'b0}};
            cmt_inc_r     <= {PHASE_W{1'b0}};
            cmt_vel_r     <= {VEL_W{1'b0}};
            cmt_timbre_r  <= {TIMBRE_W{1'b0}};
            cmt_src_r     <= 3'd0;            // ⭐ A1：来源标记（提交流水级）
            //  ⭐ 2026-09-30：同轴重触发流水级的锁存寄存器（⭐ 见 `ST_RETRIG`）
            same_en_r     <= 1'b0;
            same_idx_r    <= {IDX_W{1'b0}};
            retrig_reset_r <= {POLY_TARGET{1'b0}};
            // ⭐⭐ 溢出指示：硬复位清（⚠️ 上电后是干净的；上板运行中要靠 clr 输入清）
            lost_cnt_r    <= {EVT_LOST_CNT_W{1'b0}};
            lost_sticky_r <= 1'b0;
        end else begin
            alloc_valid_r <= 1'b0;
            //  ⭐⭐ **2026-09-28 修（B2「偶发尖音」的直接原因）**：
            //     `retrig_reset` 从【单拍脉冲】改成【保持到 `sample_tick` 才清】。
            //
            //  🔴 **原缺陷**（⭐ 与本文件 :481 的电平写法**自相矛盾**）：
            //     · ADSR 只在 `sample_tick_i` 那一拍采样 `retrig_reset_i`（`adsr.v` 的 `retrig_reset_i` 采样分支）
            //     · 而 `ST_COMMIT` 只把 `retrig_reset_r[best_idx]` 拉高 **1 个 clk**
            //     ⇒ ⭐ **命中率 = 1/1024 ≈ 0.1%** ⇒ 抢占路径的"包络清零"**几乎从不生效**
            //     ⇒ 🔴 被抢占的 voice（正在 release、`env` 有残值）会从**残余电平**
            //        重新 attack ⇒ 旧尾巴 + 新 attack 叠加
            //        ⇒ ⭐ **~11 倍尖音**（⭐ 与用户 DS0004 实测的 10.6~11.1 倍吻合）
            //     ⚠️ 同族窗口：`RT_LOW` 的**第一拍**若撞上 `sample_tick` 也会漏采。
            //
            //  ✅ **修法**：⭐ **只在 `sample_tick_i` 那一拍清** ⇒ 任何位置置的 1
            //     都会**至少保持到下一个 tick** ⇒ ADSR **必然看见**。
            //  📌 代价：最多保持 1 帧（20.48 µs）；⚠️ 但 ADSR 在第一个 tick 就消费并
            //     由本行清零 ⇒ **不会重复触发**（ADSR 里 reset 是"立即归零 + 进 ATTACK"，
            //     幂等）。
            //  ⚠️ 本行必须写在 (f)/(g) 两处**置位之前** —— ⭐ Verilog 同块内**后写覆盖先写**，
            //     置位才能赢。
            if (sample_tick_i) retrig_reset_r <= {POLY_TARGET{1'b0}};

            // ── (a) 年龄：每采样拍 +1（饱和），⛔ 不溢出 ──────────────────
            if (sample_tick_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (live_mask[i] && (age_r[i] != {AGE_W{1'b1}}))
                        age_r[i] <= age_r[i] + 1'b1;
            end

            // ── (b) 事件入队 / 出队（⭐ 扫描期间也不丢；顺序严格保持）──────
            //    ⭐ 单一计数器 `fifo_cnt`，push/pop 同拍正确处理（⛔ 不会漏加/漏减）
            if (fifo_push) begin
                fifo_v  [fifo_wr] <= 1'b1;
                fifo_ax [fifo_wr] <= note_axis_i;
                fifo_inc[fifo_wr] <= note_phase_inc_i;
                fifo_vel[fifo_wr] <= note_velocity_i;
                fifo_knd[fifo_wr] <= note_kind_i;
                fifo_timbre_valid[fifo_wr] <= evt_timbre_valid_i;
                fifo_timbre[fifo_wr] <= evt_timbre_i;
                fifo_src [fifo_wr] <= ns_src_w;      // ⭐ A1：来源随事件排队
                                                     //   ⭐ 2026-10-01：⭐ 改走 `ns_src_w`（⭐ Z-safe ✅）
                                                     //   🔴 原来直接写 `note_src_i` ⇒ ⚠️ 悬空时会全丢事件 ✅
                fifo_wr           <= fifo_wr + 1'b1;
            end
            if (fifo_pop) fifo_rd <= fifo_rd + 1'b1;

            if (fifo_push && !fifo_pop)      fifo_cnt <= fifo_cnt + 1'b1;
            else if (!fifo_push && fifo_pop) fifo_cnt <= fifo_cnt - 1'b1;
            // 同拍 push+pop ⇒ 计数不变（⛔ 不加 else 分支）

            // ⭐⭐ (b2) 溢出丢弃计数 + sticky 指示（`K-106`）──────────────────
            //    ⭐ 优先级：**先判 clr**（读走清零）⇒ 同拍"清 + 又丢一个"时，
            //       结果是"计 1 + sticky 置位"（⭐ 新丢的那个**不会被清掉**，语义正确）。
            if (event_lost_clr_i) begin
                lost_cnt_r    <= fifo_drop ? {{(EVT_LOST_CNT_W-1){1'b0}}, 1'b1}
                                           : {EVT_LOST_CNT_W{1'b0}};
                lost_sticky_r <= fifo_drop;      // ⭐ 同拍又丢 ⇒ sticky 重新置位
            end else begin
                if (fifo_drop && !lost_cnt_sat) lost_cnt_r <= lost_cnt_r + 1'b1;
                if (fifo_drop)                  lost_sticky_r <= 1'b1;   // ⭐ sticky：只置位，⛔ 不自动清
            end

            // ── (c) ⭐ `note_off` 现在走队列（见 (g) 的 `ST_DECIDE`）──────
            //    ⚠️ 原来这里是"立即清所有同轴位"的旁路 ⇒ ⛔ **会挂音**：
            //       若 `note_off` 对应的 `note_on` 还在队列里没处理，
            //       旁路会**清个空**，随后队列里的 `note_on` 才分配 voice
            //       ⇒ 那个音永远关不掉（同 `T38` 要防的失效模式）。
            //    ⇒ 已改为统一排队（顺序严格保持）。

            // ── (d) ⭐ 力度修正：更新**在响**的同轴位 voice（冻结表 §三）──
            //
            //   🔴🔴 **2026-09-26 上板实测修复：⭐ 修正【只允许调大】，⛔ 不再无条件覆盖**
            //
            //   ⭐ **上板症状**（⭐ 用户实测）：⭐ *"能听见音高了，但比起节拍器要小很多"*
            //
            //   ⭐ **根因（⭐ 有代码依据的算术）**：
            //      · ⭐ `adsr.v`：`peak_level = velocity << 8` ⇒ ⭐ **力度【线性】决定音量**
            //      · ⭐ 起音 `w3a_evt_vel = 200` ⇒ ⭐ 相对峰高 **0.784**
            //      · 🔴 而 `param_extract` 的算法是"**按得越快越响**"
            //        ⇒ ⚠️ **正常速度按键**（⭐ 不是"敲"）算出 `velocity = VEL_MIN = 64`
            //        ⇒ 🔴 **本段无条件覆盖** ⇒ ⭐ 力度被压到 **0.251**
            //      🔴 **⇒ 按键只有节拍器弱拍（140 ⇒ 0.549）的 46%**（⭐ **-6.8 dB**）
            //      📌 再叠加"`n_active` 含节拍器"（⭐ 另一处已修）⇒ ⭐ **总共约 1/3**（⭐ -10 dB）
            //      ✅ **与用户"小很多"完全吻合**。
            //
            //  ⭐⭐ **2026-09-28 上板实测调整：改成【位置式力度】⇒ 去掉"只允许调大"**
            //
            //  🔴 **原设计**：只允许调大（`if (vel_upd_value_i > vel_r[i])`）
            //     ⭐ 当时的力度来自 `param_extract`（**敲击速度**式）⇒ "只调大"合理：
            //     ⛔ 避免"按得慢"把起音 200 压到 64。
            //
            //  ⭐⭐ **用户新需求（原话）**：
            //     「力度反馈也应该加回来……还是**只用位置式**吧，
            //       **音量实时跟随位置变化**，但是**只在按键按下的时候改变**，
            //       **抬起的时候不再改变力度**，松手就自然衰减」
            //
            //  ⇒ 🔴 **"只调大"与"实时跟随"直接冲突** —— ⭐ 按浅了必须能变**小**。
            //  ✅ **改为**：直接赋值（⭐ 可增可减）。
            //
            //  📌 **"只在按下时"这条【已经】由下面的 `gate_mask` 保证**（⛔ 不用另加逻辑）：
            //     · `gate_mask = gate_r & ~retrig_low`
            //     · ⭐ 松手 ⇒ `note_off` 清 `gate_r` ⇒ `gate_mask=0` ⇒ ⭐ **力度冻结** ✅
            //     · ⭐ 之后走 `RELEASE_STEP` ⇒ **自然衰减** ✅
            //  ⚠️ **已知小瑕疵**：重触发压低窗口（≤1 tick）内 `gate_mask=0`
            //     ⇒ 那一拍的位置更新被跳过。⭐ 影响可忽略（下一拍补上）。
            //  📌 **上层保障**：`top.v` 只在 `pos > TRIG_TH` 时才发 `vel_upd`
            //     ⇒ ⭐ 双重保证"抬起后不再改变"。
            //  📌 **硬件友好性**：⭐ `adsr.v` 的 `ST_SUSTAIN` 本来就会【持续朝 `sustain_level`
            //     收敛】，而 `sustain_level` 是 `velocity_i` 的组合输出
            //     ⇒ ⭐ **改 `vel_r` ⇒ 音量【立刻跟随】**，⛔ 不需要改 `adsr.v`。
            //  ⭐⭐ 2026-09-28：**力度变化率限幅**（⭐ 修"又响又尖"，⭐ 见 `K-154`）
            //   🔴 原来：`vel_r[i] <= vel_upd_value_i;` ⇒ ⭐ 每 clk 可整值跳
            //      ⇒ ⭐ 用力敲打时 `pos` 猛跳 ⇒ `vel_r` 一拍从 64 跳到 255
            //      ⇒ ⭐ 包络电平瞬间跳满 ⇒ 🔴 瞬时超限幅器 ⇒ 削波 ⇒ 又响又尖
            //   ✅ 修法：⭐ 挂在 `sample_tick_i`，⭐ 每音频采样拍最多变 **±8**
            //      ⇒ ⭐ 满量程 255/8 = **32 拍 = 0.65 ms** 平滑滑行
            //      📌 ⭐ **用户 2026-09-28 拍板选 ±8**（⭐ 折中：⭐ 既削掉突变，
            //         又让力度跟随的延迟**几乎无感**）✅
            //   ⚠️ **为什么要挂起**：⭐ `vel_upd_valid_i` 是 1 拍脉冲 ⇒ ⚠️ 直接
            //      `& sample_tick_i` 会**丢掉绝大多数更新**（⭐ 两者不同拍）
            //   ⭐ **目标锁存后【永不清零】** —— 到达目标时下面的 `else` 赋同值
            //      ⇒ ⭐ **自然静止**（⭐ 无需任何"到达"判断）✅
            //   ⭐⭐ 2026-09-29：⭐ **改成【每轴一个目标】**（⭐ 见上方 `vtgt_*` 的说明 ✅）
            //      ⭐ 好处：⭐ 即使某次 `vel_upd` 到达时**还没有 voice**（⭐ 被丢掉 ✅），
            //      ⭐ **目标依然留在 `vtgt_val[axis]`** ⇒ ⭐ 该轴下一个 voice 一发声
            //      ⭐ 就会朝它爬 ✅ ⇒ ⭐ **自愈** ✅
            //  ⭐⭐ 2026-09-29：⭐ **改成【按源分开的两套目标】** ✅
            //     · ⭐ **源 0（手弹）** ⇒ 走下面那套"**每轴**目标"（⭐ 语义与改动前**完全一致**）
            //     · ⭐ **源 ≠ 0（回放等）** ⇒ 走"**每 voice**目标"（⭐ 见 `vtgt_rep` 的说明）
            //   🔴 **为什么必须分开**：⭐ 混用一套 ⇒ ⚠️ 同轴时两路互相覆盖
            //      ⇒ 🔴 **回放的插值会把在响的手弹 voice 拖走**（⭐ 用户会听到"音量乱跑"）✅
            if (vel_upd_valid_i && (vu_src_w == 3'd0)) begin
                vtgt_val[vel_upd_axis_i] <= vel_upd_value_i;   // ⭐ 该轴的目标力度
                vtgt_vld[vel_upd_axis_i] <= 1'b1;              // ⭐ 有效（⛔ 永不清）
            end

            //  ⭐⭐ 非手弹源：⭐ **直接写同源 voice 的每 voice 目标**（⭐ 只动同源 ✅）
            //   ⚠️ 仍然**每采样拍最多 ±8** 地爬（⭐ 见下方统一斜坡段）⇒
            //      ⭐ `K-154`（⛔ 不许 `vel_r` 一拍整值跳）**照旧成立** ✅
            if (vel_upd_valid_i && (vu_src_w != 3'd0)) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (gate_mask[i] && (axis_r[i] == vel_upd_axis_i)
                                     && (src_r[i]  == vu_src_w))
                        vtgt_rep[i] <= vel_upd_value_i;
            end

            //  ⭐ 每个 `sample_tick`：⭐ 所有"在响且该轴有目标"的 voice 各爬 ±8 ✅
            //   📌 ⛔ **不再需要"本拍扫的是哪个轴"** —— ⭐ 每个 voice 查【自己那个轴】的目标 ✅
            //      ⇒ ⭐ 跟随**不依赖 `vel_upd` 的到达节奏** ✅（⭐ 原来单寄存器时是依赖的 ✅）
            //   ⭐⭐ 2026-09-29：⭐ **按源选目标**（⭐ 源 0 查每轴表、⭐ 其它源查每 voice 表）✅
            if (sample_tick_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (gate_mask[i]) begin
                        //  ⭐⭐ 2026-10-04（codex 只读诊断「候选三第 2 项 / 路线三」）：
                        //     **先选目标，再走一套 ±8 斜坡**
                        //
                        //  🔴 原来：手弹与回放**各写一套逐字相同**的 ±8 斜坡
                        //     （只有"目标来自哪里"不同）⇒ 综合器**不保证**跨 if/else 共享
                        //     比较器与加减（本设计 CLS 已 90%，这点很关键）。
                        //  ✅ 改法：先把 target / target_valid 选出来，再执行**一套**斜坡。
                        //  ✅ 语义逐位不变：
                        //     · 手弹（src==0）：目标 = `vtgt_val[axis_r[i]]`，
                        //       且**仅当** `vtgt_vld[axis_r[i]]` 才爬（原来就是这个门）
                        //     · 回放（src!=0）：目标 = `vtgt_rep[i]`，**无** valid 门（原来也没有）
                        //  📌 等价性由"穷举 65536 对 (current,target)"的差分验证（见 tb）。
                        vel_tgt     = (src_r[i] == 3'd0) ? vtgt_val[axis_r[i]] : vtgt_rep[i];
                        vel_tgt_vld = (src_r[i] == 3'd0) ? vtgt_vld[axis_r[i]] : 1'b1;
                        if (vel_tgt_vld) begin
                            if      (vel_tgt > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;
                            else if (vel_tgt + 8'd8 < vel_r[i]) vel_r[i] <= vel_r[i] - 8'd8;
                            else                                vel_r[i] <= vel_tgt;
                        end
                    end
            end

            // ── (e) ⭐ 音高修正：更新**在响**（含 Release 尾巴）的同轴位 voice ──
            //    ⚠️ 只改 `phase_inc`，⛔ **绝不清相位** ⇒ 滑音不产生"咔"声
            //    ⭐⭐ 2026-09-29：⭐ **再加一条"同源"判据**（⭐ 与 (d) 段同一纪律）✅
            //      🔴 原来只按轴匹配 ⇒ ⭐ 回放的插值音高会把**手弹**同轴 voice 的音高
            //         一起拖走（⭐ 听感：手弹的音自己滑走了）✅
            if (pitch_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (live_mask[i] && (axis_r[i] == pitch_upd_axis_i)
                                     && (src_r[i]  == pu_src_w))
                        phase_r[i] <= pitch_upd_value_i;
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ (f) 重触发两步走（与状态无关，优先于扫描）
            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ (f) 重触发压低（⭐ 2026-09-28 改成【每 voice 位图】）
            //   ⭐ 对**每一个**处于压低态的 voice 独立处理 ⇒ ⛔ 不存在"被抢占"
            //   ⭐ `retrig_reset` 用【电平】保持到 `sample_tick` ⇒ ADSR 必然看见
            //     （⛔ 若只发一拍脉冲，而 tick 恰好错开 ⇒ 清零丢失
            //      ⇒ 又回到"从残余电平重新 Attack"的尖音 bug）
            //   ⚠️ 本段在 `case` **之前**；`(g)` 的 `note_off` 在之后 ⇒
            //      ⭐ **`note_off` 无条件优先**（这是防挂音的关键）
            for (i = 0; i < POLY_TARGET; i = i + 1) begin
                if (retrig_low[i]) begin
                    gate_r[i]          <= 1'b0;
                    //  ⭐⭐ 2026-09-28 修（复审实测 rst_ticks=2）：sample_tick 那一拍必须让 :463 的【清零】赢。
                    //  🔴 原写法无条件置 1 ⇒ 后写覆盖先写 ⇒ 该位跨【两个】sample_tick
                    //     ⇒ ADSR 连清两帧 ⇒ ⭐ 重触发起音多延迟一整帧（20.48 µs）。
                    //  ✅ 加 !sample_tick_i ⇒ 高电平恰好跨【一个】tick 沿（语义与注释一致）。
                    if (!sample_tick_i) retrig_reset_r[i] <= 1'b1;
                    if (sample_tick_i) begin
                        gate_r[i]     <= 1'b1;
                        retrig_low[i] <= 1'b0;
                    end
                end
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ (g) 分配扫描 FSM（`T66`：每拍一个 voice）
            // ═══════════════════════════════════════════════════════════════
            case (state)
                ST_IDLE: begin
                    if (!fifo_empty) begin
                        // 取出队列头（⭐ 含 `note_off` —— 顺序严格保持）
                        cur_axis <= head_axis;
                        cur_inc  <= head_inc;
                        cur_vel  <= head_vel;
                        cur_kind <= head_kind;
                        cur_timbre_valid <= head_timbre_valid;
                        cur_timbre <= head_timbre;
                        cur_src  <= head_src;      // ⭐ A1：来源与其它 `head_*` 同拍锁存
                        state    <= ST_DECIDE;
                    end
                end

                ST_DECIDE: begin
                    if (cur_kind == KIND_OFF) begin
                        // ⭐ `note_off`：清掉**所有**同轴位且 gate 高的 voice
                        //    ⚠️ 清"所有"而不是"一个" ⇒ ⭐ **防挂音**（`T38` 纪律）：
                        //       万一同轴位残留了第二个 voice，也不会永远响下去。
                        //  ⭐⭐ 2026-09-29（A1）：⭐ **再加一条"同源"判据** ✅
                        //    🔴 原判据只有 `axis_r[i] == cur_axis` ⇒ ⭐ looper 回放（`score`）
                        //       的 `note_off` 会把**手弹**（`live`）在同一轴上的 voice 也清掉
                        //       ⇒ ⭐ 上板现象（用户实测）：⭐ **回放时按同一个键
                        //          ⇒ 手弹的音被回放的 `note_off` 杀掉，且它自己不再回来** ✅
                        //    ✅ 现在：⭐ 只有 `src_r[i] == cur_src` 的 voice 才清 ⇒ **按源隔离** ✅
                        //    📌 **仍然是"清所有匹配的 voice"**（⛔ 不是只清一个）——
                        //       ⭐ 这是 `T38` 的**防挂音纪律**，⛔ 一个字都不改 ✅
                        for (i = 0; i < POLY_TARGET; i = i + 1)
                            if ((gate_r[i] | retrig_low[i])
                                && (axis_r[i] == cur_axis)
                                && (src_r[i]  == cur_src)) begin
                                gate_r[i]     <= 1'b0;
                                //  ⭐⭐ **`note_off` 无条件优先**（2026-09-28 根因修复）：
                                //     同时清掉"重触发压低"位 ⇒ (f) 段此后再不会把它抬回 1
                                //     ⇒ ⛔ 彻底杜绝"清了又被拉回"的永久挂音。
                                //  📌 原判据用 `gate_mask[i]`（= `gate_r & ~hold_mask`），
                                //     压低期间恒为 0 ⇒ **跳过该 voice** ⇒ 挂音。
                                retrig_low[i] <= 1'b0;
                            end
                        //  ⭐⭐ 2026-09-29：⭐ **松手 ⇒ 清掉该轴的力度目标** ✅
                        //   ⭐ 语义：⭐ 目标只在"按住期间"有效 ⇒ ⭐ 松手即冻结 ✅
                        //   🔴 **为什么必须有**：⭐ 若目标永不清（⭐ 我第一版就是 ✅），
                        //      ⚠️ **上一次按键留下的旧目标会覆盖下一次起音** ✅
                        //      📌 实证：`tb_note_manager.sv:457` 发 axis5=240 ⇒
                        //      ⭐ 之后 `press_a(axis5, vel=100)` ⭐ 本应停在 `env=6400`
                        //      （⭐ =100×64 ✅），⭐ 却被拉向 240×64=15360 ⇒ 🔴 FAIL ✅
                        //   ⭐ 放在循环**外面**（⭐ 与"有没有 voice"无关 ⇒ 语义更干净 ✅）
                        //  ⭐⭐ 2026-09-29：⭐ **只有【手弹】的 `note_off` 才清手弹的每轴目标** ✅
                        //    ⚠️ 否则回放的 `note_off` 会把**手弹**同轴的目标一起清掉
                        //       ⇒ 🔴 手弹的音**力度被冻结**（⭐ 与 A1 修的 `note_off` 同一缺陷类）✅
                        if (cur_src == 3'd0)
                            vtgt_vld[cur_axis] <= 1'b0;
                        state <= ST_IDLE;
                    end else if (same_valid) begin
                        //  ⭐⭐ 2026-09-30（时序，待上板验证）：⭐ **本状态只【锁存】"选谁"**
                        //
                        //  🔴 **问题（⭐ PnR 报告原文）**：`same_idx` 来自 **32 路优先编码器**（组合），
                        //     而重触发的 8 条写入各自是一套 **32 路写译码**（`same_idx == i`）
                        //     ⇒ ⭐ 整条 "`env_level` → `same_hit` → 32 路选择 → 32 路译码 → `CE`"
                        //        在**一个周期内**完成，⭐ 且**同时驱动 32 个 voice 的全部数组寄存器**
                        //     ⇒ ⭐ 这就是 `tr_content.html` 里那 **4517 个 setup 违例端点**
                        //        （⭐ 最差 slack **−3.756 ns**，⭐ data 23.539 ns / 周期 20 ns）✅
                        //
                        //  ✅ **修法**：⭐ **与 `N-1` 的 `ST_COMMIT2` 完全同构** ——
                        //     ⭐ 本状态只锁存 `same_idx`，⭐ 真正的写放在下一状态 `ST_RETRIG`
                        //        （⭐ 用**寄存器输出**驱动 32 路译码器 ⇒ ⭐ 长链一分为二 ✅）
                        //     📌 `N-1` 已用同一手法切掉"`best_idx` → 写译码器"那条链，
                        //        ⭐ 本次切的是**同轴重触发**那条（⭐ 两条链的终点是**同一批 `CE`**）✅
                        //
                        //  ⚠️ **代价**：⭐ 同轴重触发**晚 1 拍**（20 ns，⭐ 听感不可闻）· ⭐ 功能等价
                        //     （⭐ `cur_axis`/`cur_src`/`cur_inc`/`cur_vel`/`cur_timbre*`
                        //       **只在 `ST_IDLE` 更新** ⇒ ⭐ 锁存期间**不会变** ✅）
                        //
                        //  📌 `vtgt_vld[cur_axis] <= 1'b0`（⭐ 重触发清该轴目标）**留在本状态**：
                        //     ⭐ 它只依赖 `cur_axis`/`cur_src`（⭐ 都是寄存器），与 `same_idx` 无关
                        //     ⇒ ⭐ 没有理由推迟（⭐ 语义与原代码**完全一致**）✅
                        same_en_r  <= 1'b1;
                        same_idx_r <= same_idx;
                        if (cur_src == 3'd0)
                            vtgt_vld[cur_axis] <= 1'b0;
                        state      <= ST_RETRIG;
                    end else begin
                        // ⭐ 启动扫描（⛔ 不能保证一定有空闲 voice，故要扫全部）
                        scan_cnt   <= {SW{1'b0}};
                        scan_sel   <= {{(POLY_TARGET-1){1'b0}}, 1'b1};
                        best_valid <= 1'b0;
                        same_en_r  <= 1'b0;      // ⭐ 本拍⛔ 不走重触发分支（⭐ 见 `ST_RETRIG`）
                        state      <= ST_SCAN;
                    end
                end

                //  ══════════════════════════════════════════════════════════════
                //  ⭐⭐ 2026-09-30（时序，待上板验证）：⭐ **同轴重触发的写译码流水级**
                //     📌 与 `ST_COMMIT2`（⭐ `N-1`，2026-09-29）是**同一个模式**：
                //        "**选谁**"（组合）与"**写谁**"（寄存后）分开 ⇒ ⭐ 长链切断 ✅
                //     ⚠️ 本段写入内容与原 `ST_DECIDE` 的 `same_valid` 分支**逐字相同**，
                //        只是把索引从**组合的** `same_idx` 换成**寄存的** `same_idx_r` ✅
                //     📌 `new_vel` / `new_timbre` 只由 `cur_vel` / `cur_timbre*` 组合而来，
                //        而 `cur_*` 只在 `ST_IDLE` 更新 ⇒ ⭐ 本拍取值与原拍**完全相同** ✅
                //  ══════════════════════════════════════════════════════════════
                ST_RETRIG: begin
                    if (same_en_r) begin
                        // ⭐ 同轴位重触发优先（复用同一 voice，⛔ 不新占）
                        gate_r[same_idx_r]     <= 1'b0;   // 压低（由 (f) 段保持到 sample_tick）
                        retrig_low[same_idx_r] <= 1'b1;   // ⭐ 每 voice 一位（⛔ 不再用全局 retrig_idx）
                        //  ⭐⭐ 2026-09-29（A1）：⭐ **同轴重触发 ⇒ 这个 voice 换主人** ✅
                        //   ⭐ 语义：⭐ 谁**最后**起音，voice 就归谁 ⇒ ⭐ 只有它的 `note_off` 清得掉 ✅
                        //   🔴 **为什么这一条是必需的**（⛔ 不是可选优化）：
                        //      若不更新 —— 回放（`score`）先在轴 X 起音、手弹（`live`）再按 X
                        //      ⇒ ⭐ 复用同一个 voice（`src_r` 仍是 `score`）
                        //      ⇒ 🔴 手弹**松手**那条 `note_off(live)` **匹配不上** ⇒
                        //         ⭐ 手弹的音要一直响到回放自己发 `note_off` 为止 ⇒ **挂音** ✅
                        //   📌 与 `note_off` 的 `T38` 纪律一致：⭐ **任何时刻都不留"清不掉"的 voice** ✅
                        //  ⭐⭐ 2026-09-29（A3'）：⭐ **本行现在恒为"写回同一个值"** ✅
                        //     ⚠️ 因为 `same_hit` 已经要求 `src_r[sg] == cur_src`（⭐ 见上）
                        //     ⇒ ⭐ 走到这里时 `src_r[same_idx_r]` **必然已经等于** `cur_src` ✅
                        //     ⇒ ⭐ 保留它（⛔ 不删）的理由有两条：
                        //        · ⭐ **可读性**：⭐ "谁最后起音，voice 就归谁"这条语义
                        //          在这里**显式成立**，⛔ 不依赖读者去反推 `same_hit` 的判据 ✅
                        //        · ⭐ **抗漂移**：⚠️ 万一将来有人放宽 `same_hit`（⭐ 例如为了
                        //          允许跨源复用），⭐ 本行会**立刻**恢复成真正的"改判"，
                        //          而⛔ 不会静默留下"清不掉"的 voice ✅
                        src_r[same_idx_r]      <= cur_src;
                        phase_r[same_idx_r]    <= cur_inc;
                        vel_r[same_idx_r]      <= new_vel;
                        timbre_r[same_idx_r]   <= new_timbre;
                        age_r[same_idx_r]      <= {AGE_W{1'b0}};
                        //  ⭐⭐ 2026-09-29：⭐ **重触发 ⇒ 每 voice 目标重置为【本次事件的力度】** ✅
                        //    ⭐ 语义：⭐ 起音力度由**这次事件**决定 ⇒ ⛔ 不许残留上一个音的目标 ✅
                        //    📌 与 `ST_COMMIT2`（⭐ 新占 voice ✅）保持**同一条规则** ✅
                        //    📌 该轴的"每轴目标"清位（`vtgt_vld[cur_axis]`）已在 `ST_DECIDE` 做 ✅
                        vtgt_rep[same_idx_r]   <= new_vel;
                    end
                    state <= ST_IDLE;
                end

                ST_SCAN: begin
                    // One candidate per edge; advance both indices only before the last item.
                    if (cand_ok && cand_better) begin
                        best_valid <= 1'b1;
                        best_idx   <= cand_idx;
                        best_cls   <= cand_cls;
                        best_env   <= cand_env;
                        best_age   <= cand_age;
                    end
                    if (scan_cnt == SCAN_LAST[SW-1:0]) begin
                        state <= ST_COMMIT;
                    end else begin
                        scan_cnt <= scan_cnt + 1'b1;
                        scan_sel <= scan_sel << 1;
                    end
                end

                ST_COMMIT: begin
                    //  ⭐⭐ **2026-09-28 修（P2-1）：`best_valid==0` 时⛔ 不提交**
                    //
                    //  🔴 **原写法**：无条件用 `best_idx` 提交。
                    //     ⚠️ 若本轮扫描**一个候选都没有**（`best_valid` 始终 0 ——
                    //     例如全部 voice 都在 `retrig_low`、或全在保留池之外），
                    //     `best_idx` 就是**上一轮的残留值**
                    //     ⇒ 🔴 会把音提交到一个**从未通过 `pool_mask` / `~cand_hold` 校验**
                    //        的 voice —— 可能是节拍器的保留 voice，
                    //        或**正在压低态**的 voice（`gate_r=1` 与 `retrig_low=1` 同时成立）
                    //     ⇒ 破坏"压低中的 voice 不可被抢占"这条不变量。
                    //  📌 **可达性**：`POLY_TARGET=32 / RESERVED_N=5` 下需要 **27 个 voice
                    //     同时处于 `retrig_low`**（≤1 帧窗口内 27 次同轴重触发）⇒ 极低；
                    //     ⚠️ 但在**小实例**（例如 tb 里 `POLY_TARGET=4, RESERVED_N=0`）
                    //     只需 4 个 ⇒ ⭐ 结构上是破口。
                    //  ✅ **修法**：加 `if (best_valid)` 守卫 ⇒ ⭐ 无候选时**什么都不做**
                    //     （该事件被丢弃，但⛔ 不会污染无关 voice）。
                    if (best_valid) begin
                        // ⭐ 提交（此时 `best_*` 已稳定）
                        //  ⭐⭐ 2026-09-29 `N-1`：⭐ **这里【只锁存】，⛔ 不再直接写译码器**
                        //     （⭐ 真正的写在 `ST_COMMIT2`，⭐ 用**寄存后**的 `cmt_idx_r`）
                        cmt_en_r     <= 1'b1;
                        cmt_idx_r    <= best_idx;
                        cmt_axis_r   <= cur_axis;
                        cmt_inc_r    <= cur_inc;
                        cmt_vel_r    <= new_vel;
                        cmt_timbre_r <= new_timbre;
                        cmt_src_r    <= cur_src;      // ⭐ A1：来源与 `cmt_axis_r` 同一拍锁存
                        //  ⭐ 抢占也要清零包络 —— ⚠️ `best_idx` 可能是**正在 release、
                        //     包络仍有残值**的 voice（`cand_rel` 类别就是它）⇒
                        //     🔴 不清零就会把"别人的尾巴"和新音叠加 = 同一个尖音 bug。
                        //  📌 与 `gate` 同拍：ADSR 里 `retrig_reset_i` 优先级**高于**
                        //     `gate` 判定 ⇒ ⭐ 同拍不会既清零又按残余电平起振。
                        //  ⭐ 2026-09-29 `N-1`：⭐ `retrig_reset_r` / `alloc_*` 的写入
                        //     也一并搬到 `ST_COMMIT2`（⭐ 与 `gate` **同拍** ⇒
                        //     ⚠️ 必须一起搬，⛔ 否则会破坏"同拍清零 + 起振"的约定）
                    end else begin
                        //  ⚠️ ⭐ 无候选 ⇒ **不提交** —— ⭐ 保住 `P2-1` 的守卫（⛔ 不污染无关 voice）
                        cmt_en_r <= 1'b0;
                    end
                    state              <= ST_COMMIT2;
                end

                //  ══════════════════════════════════════════════════════════════
                //  ⭐⭐ 2026-09-29 `N-1`（Fmax 修复）：⭐ **提交流水级**
                //
                //  🔴 **原缺陷（⭐ 实测 `impl/pnr/Gowin2026.timing_paths`）**：
                //     ⭐ `ST_COMMIT` 在**一个周期内**同时驱动 **7 个 32 路写译码**：
                //        `gate_r[best_idx]` · `axis_r[best_idx]` · `phase_r[best_idx]`
                //        · `vel_r[best_idx]` · `timbre_r[best_idx]` · `age_r[best_idx]`
                //        · `retrig_reset_r[best_idx]`
                //     ⚠️ 而 `best_idx` 来自 **32 路扫描比较树**（⭐ `ST_SCAN` 的组合输出）
                //     ⇒ ⭐ **这就是那条关键路径**（⭐ `note_manager` 在路径表里出现 **274** 次，
                //        是**唯一**的关键路径来源）✅
                //
                //  ✅ **修法**：⭐ **在"选完"与"写"之间插一级寄存器** ⇒
                //     ⭐ 写译码器的输入变成**寄存器输出** ⇒ ⭐ **长路径被切断** ✅
                //
                //  ⚠️ **代价**：⭐ 分配延迟 **+1 拍**（⭐ 20 ns ⇒ 听感不可闻）
                //  📌 ⭐ **功能等价**：⭐ 只是把**同一组写入**晚一拍做 ✅
                //     ⭐ 且 `retrig_reset_r` 与 `gate_r` **仍在同一拍** ⇒ ⭐ 原约定不变 ✅
                //  ⚠️ **`best_valid == 0` 的守卫仍然有效**（⭐ 通过 `cmt_en_r` 传递）✅
                //  ══════════════════════════════════════════════════════════════
                ST_COMMIT2: begin
                    if (cmt_en_r) begin
                        gate_r[cmt_idx_r]   <= 1'b1;
                        axis_r[cmt_idx_r]   <= cmt_axis_r;
                        // ⭐ A1：来源标记与 `axis_r` **同一拍写同一个 voice**（⭐ 不可分离）
                        src_r[cmt_idx_r]    <= cmt_src_r;
                        phase_r[cmt_idx_r]  <= cmt_inc_r;
                        vel_r[cmt_idx_r]    <= cmt_vel_r;
                        timbre_r[cmt_idx_r] <= cmt_timbre_r;
                        age_r[cmt_idx_r]    <= {AGE_W{1'b0}};
                        retrig_reset_r[cmt_idx_r] <= 1'b1;
                        //  ⭐⭐ 2026-09-29：⭐ **新占 voice ⇒ 清掉该轴的旧目标** ✅
                        //   ⭐ 语义：⭐ 起音力度 = **这次事件携带的值**（⭐ `cmt_vel_r` ✅）
                        //      ⇒ ⛔ 旧目标不得把它拉走 ✅
                        //   ⭐⭐ **与"每轴目标"配套的三条规则（缺一不可）**：
                        //      · ⭐ `ST_COMMIT2`（⭐ 新占 ✅）⇒ 清 ✅
                        //      · ⭐ 重触发（⭐ 同轴复用 ✅）⇒ 清 ✅
                        //      · ⭐ `note_off`（⭐ 松手 ✅）⇒ 清 ✅
                        //   📌 **为什么不能只靠"发端补发"**：⭐ 发端的 `vu_last` 是**去重参考** ✅
                        //      ⇒ ⚠️ 若某次 `vel_upd` 在 voice 出现【之前】到达并被丢掉 ✅，
                        //      ⭐ 收端**必须**能自愈 —— ⭐ 而"清旧目标 + 目标持续刷新"正是自愈 ✅
                        //  ⭐⭐ 2026-09-29：⭐ **非手弹事件⛔ 不清手弹的每轴目标**（⭐ 同上）✅
                        if (cmt_src_r == 3'd0)
                            vtgt_vld[cmt_axis_r] <= 1'b0;
                        //  ⭐⭐ 2026-09-29：⭐ **新占 voice ⇒ 每 voice 目标 = 本次事件的起音力度** ✅
                        //    ⭐ 语义：⭐ 新音的第一个"目标"就是它的**起点** ⇒
                        //       ⭐ 回放的插值从起点开始爬（⛔ 不会先被上一个音的残值拉走）✅
                        vtgt_rep[cmt_idx_r] <= cmt_vel_r;
                        alloc_valid_r      <= 1'b1;
                        alloc_voice_r      <= cmt_idx_r;
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-03：⭐ **T3 实时变调核心**（⭐ 步骤① · ⭐ `note_manager` 内 ✅）
    //
    //   📌 **来源**：⭐ `files/00-总览/T3变调与推子功能状态机-设计定稿-20261001.md`
    //      · §三 ⭐ **乘法器必须时分复用**（⭐ 共享 1 个 ＋ 轮转 ✅）
    //      · §五 ⭐ **比例表 · 旁路 mux · 短滑音** ✅
    //
    //   ⭐ **四条，⭐ 缺一不可**：
    //     ① ⭐ **比例表**（⭐ 25 项 Q1.15，⭐ **显式 `case`** ⇒ ⛔ 无运行期幂运算 ✅）
    //     ② ⭐ **共享 1 个乘法器**（⭐ 32×17）＋ ⭐ **5 位轮转**（⭐ 每拍算 **1** 个 lane，
    //        32 拍转完一圈 = **0.64 µs** ≪ 短滑音 1 ms ✅）
    //     ③ ⭐ **旁路 mux**（⭐ `semi_cur == 0` ⇒ ⭐ **逐位恒等**，⭐ 乘法器不在通路上 ✅）
    //     ④ ⭐ **源门控**（⭐ 只有 `live/score/demo` 跟随变调；
    //        ⭐ `SRC_AUX`（节拍器/鼓机）与 `looper` **逐位不变** ✅）
    //
    //   🔴 **为什么⛔ 不能"每 lane 一个乘法器"**（⭐ §三 原文）：
    //      ⭐ 朴素做法 = **32 个 32×17 乘法器** ⇒ ⭐ LUT/DSP **爆炸** ⚠️
    //      📌 **本项目的实测先例**：⭐ T2 的"**每 lane 一个变量移位器**"就吃了 **+2202 LUT**
    //         ⇒ ⭐ 乘法器**绝不能每 lane 一份** ✅
    //      ⭐ 而"**共享 ＋ 轮转**"在本项目**已有先例**（⭐ `tdm_render_mixer` 共享 1 个 DSP ✅）
    //
    //   ⚠️⚠️ **端口悬空的向后兼容**（⭐ 与 `vu_src_w`/`pu_src_w`/`ns_src_w` **同一套口径**）：
    //      ⭐ 本步 `top.v` **不接** `transpose_semi_i` ⇒ ⭐ 悬空 = `5'bzzzzz`
    //      ⇒ 🔴 若**直接**拿它当目标：⭐ `semi_cur` 会变 `x` ⇒ ⭐ `(semi_cur == 0)` 变 `x`
    //      ⇒ 🔴 **`voice_phase_inc_o` 全部变 `x`** ⇒ ⭐ 老 tb（`tb_note_manager` /
    //         `tb_pool_by_src` / `tb_top_m0` / `tb_top_sound` …）**全部假红** ✅
    //      ⭐ **修法**：⭐ **Z-safe 解码** —— ⭐ 只有"**所有位都已知**（⛔ 无 x/z）
    //         **且**落在 `−12..+12`"才当**有效目标**，⭐ 其余**一律当 0** ✅
    //      ⇒ ⭐ **不接 = 0 档 = 逐位恒等** ✅（⭐ **这就是本步的核心安全保证** ✅）
    // ═══════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-03（`P1`）：⭐ **`T3_EN` 参数门控 —— 变调核心整段条件综合** ✅
    //
    //   ⭐ **门控方式**：⭐ `generate if (T3_EN)`（⭐ `T3_EN` 是 `parameter` ⇒ **常量表达式** ✅）
    //      · `T3_EN = 1` ⇒ ⭐ `g_t3` 分支：⭐ **逐字保持原语义**（⛔ 不改行为，只"包起来"）✅
    //      · `T3_EN = 0` ⇒ ⭐ `g_t2` 分支：⭐ 本段**整段不展开** ＋ ⭐ 输出**回到 T2 原式** ✅
    //
    //   ⚠️ **为什么用 `generate` 而⛔ 不是"常量折叠 ＋ 等综合器删"**：
    //      ⭐ 本任务的验收判据是 `T_Lut ≈ 37026`（无 T3 基线）——
    //      ⭐ `generate` 是**结构性保证**（⭐ 那些 `always`/`wire` **根本没被展开**）；
    //      ⚠️ 而"未驱动的寄存器 ＋ 无负载的乘法器会被优化掉"是**概率性保证**
    //      （⭐ 本项目已被"工具行为与预期不符"坑过多次 ⇒ ⭐ 宁可结构上不可能 ✅）
    //
    //   ⚠️ **作用域**：⭐ `semi_cur` / `phase_tr` 等**只存在于 `g_t3` 内** ⇒
    //      ⭐ `voice_phase_inc_o` 的旁路 mux **必须**写在同一个 `generate` 里
    //      （⭐ 见本段末尾）—— ⭐ 否则 `T3_EN=0` 时**引用不到**，⭐ 编译不过 ✅
    //      📌 对 `tb/w3b/tb_transpose.sv` 的后果：⭐ 探针路径变成
    //         `u_t3on.g_t3.semi_cur` / `u_t3on.g_t3.phase_tr`（⭐ 该 tb 已同步改 ✅）
    //
    //   📌 **本段内容一字未改**（⭐ 只加门控外壳）—— ⚠️ 为把 `git diff` 控制在
    //      **可逐行复核**的规模，⭐ 块内**沿用原有缩进**（⭐ Verilog 不依赖缩进）✅
    // ═══════════════════════════════════════════════════════════════════════
    genvar gp;      // ⭐ `g_t3` 分支：⭐ 变调输出的逐 lane 打包（⭐ 模块级 —— Verilog-2001 要求）
    genvar gp2;     // ⭐ `g_t2` 分支：⭐ T2 原式的逐 lane 打包
    generate
    if (T3_EN) begin : g_t3

    // ── ① 比例表：⭐ Q1.15 **无符号**定点（⭐ 1.0 = 32768）；⭐ 17 位（⭐ 因 +12 半音 = 2.0 = 65536 ✅）
    //    ⭐ `idx` 0..24 ⇒ ⭐ 半音 **−12..+12**（⭐ `idx = 半音 + 12` ✅）
    //    ⚠️ **显式 `case`**（⭐ 与 `axis_map` 查表**同一纪律**：⛔ 不做运行期指数运算 ✅）
    //    ⭐ `default` = **32768**（⭐ 兜底 = **不变调** ⇒ ⭐ 任何非法下标都⛔ 不会放大/静音 ✅）
    //    📌 **数值来源**：⭐ §五 的比例表（⭐ 2026-10-01 设计定稿 ✅）—— ⛔ 一个字都不改 ✅
    function [16:0] semi_ratio_of;
        input [4:0] idx;
        case (idx)
            5'd0 : semi_ratio_of = 17'd16384;   // ⭐ −12 半音 ⇒ 0.5
            5'd1 : semi_ratio_of = 17'd17358;   // ⭐ −11
            5'd2 : semi_ratio_of = 17'd18390;   // ⭐ −10
            5'd3 : semi_ratio_of = 17'd19484;   // ⭐  −9
            5'd4 : semi_ratio_of = 17'd20643;   // ⭐  −8
            5'd5 : semi_ratio_of = 17'd21870;   // ⭐  −7
            5'd6 : semi_ratio_of = 17'd23170;   // ⭐  −6
            5'd7 : semi_ratio_of = 17'd24548;   // ⭐  −5
            5'd8 : semi_ratio_of = 17'd26008;   // ⭐  −4
            5'd9 : semi_ratio_of = 17'd27554;   // ⭐  −3
            5'd10: semi_ratio_of = 17'd29193;   // ⭐  −2
            5'd11: semi_ratio_of = 17'd30929;   // ⭐  −1
            5'd12: semi_ratio_of = 17'd32768;   // ⭐   0 ⇒ 1.0
            5'd13: semi_ratio_of = 17'd34716;   // ⭐  +1
            5'd14: semi_ratio_of = 17'd36781;   // ⭐  +2
            5'd15: semi_ratio_of = 17'd38968;   // ⭐  +3
            5'd16: semi_ratio_of = 17'd41285;   // ⭐  +4
            5'd17: semi_ratio_of = 17'd43740;   // ⭐  +5
            5'd18: semi_ratio_of = 17'd46341;   // ⭐  +6
            5'd19: semi_ratio_of = 17'd49097;   // ⭐  +7
            5'd20: semi_ratio_of = 17'd52016;   // ⭐  +8
            5'd21: semi_ratio_of = 17'd55109;   // ⭐  +9
            5'd22: semi_ratio_of = 17'd58386;   // ⭐ +10
            5'd23: semi_ratio_of = 17'd61858;   // ⭐ +11
            5'd24: semi_ratio_of = 17'd65536;   // ⭐ +12 半音 ⇒ 2.0
            default: semi_ratio_of = 17'd32768; // ⭐ 兜底 = 不变调 ✅
        endcase
    endfunction

    // ── ② Z-safe 目标解码（⭐ 见上方"端口悬空"说明 ✅）
    //    ⭐ `^transpose_semi_i` = **归约异或**：⭐ 只要**有一位**是 `x`/`z` ⇒ 结果为 `x`
    //       （⭐ 全已知时结果必是 `0`/`1`）⇒ ⭐ `x !== 1'bx` = `0` ⇒ ⭐ 落到"当 0"分支 ✅
    //    ⭐ 范围判据 `−12..+12`（⭐ 有符号比较：⭐ 两侧都是 signed ⇒ ⭐ 按补码比较 ✅）
    //    📌 `&&` 的语义：⭐ 左操作数为 `0` 时结果为 `0`（⭐ 短路，⛔ 不看右操作数 ✅）
    wire               trans_known = (^transpose_semi_i !== 1'bx);
    wire signed [4:0]  semi_tgt_w  = (trans_known
                                      && (transpose_semi_i >= -5'sd12)
                                      && (transpose_semi_i <=  5'sd12))
                                     ? transpose_semi_i : 5'sd0;

    // ── ③ 短滑音（⭐ 用户裁定：⭐ 量化到半音 ＋ **短滑音过渡** ✅）
    //    ⭐ `semi_cur` 向 `semi_tgt` **每 1 ms 走 ±1**（⭐ 50 MHz ⇒ 数到 **49999** = 1 ms ✅）
    //    ⇒ ⭐ **单调逼近 · ⛔ 不跳变**（⭐ 避免"咔"的一声 ✅）
    //    ⇒ ⭐ **顺带掩盖乘法器的轮转延迟**（⭐ 32 拍 = 0.64 µs ≪ 1 ms ✅ —— 这正是 §三 的判据 ✅）
    //    ⚠️ 计数器挂 **`clk_i`**（⛔ 不挂 `sample_tick_i`）——
    //       ⭐ 因为 1 ms 是**绝对时间**（⭐ 50 MHz ⇒ 50000 拍），⭐ 与音频采样率无关 ✅
    reg  signed [4:0]  semi_cur;      // ⭐ 当前生效的半音（⭐ 逐步逼近 ✅）
    reg  signed [4:0]  semi_tgt;      // ⭐ 目标半音（⭐ = 解码后的 `transpose_semi_i` ✅）
    reg  [15:0]        port_cnt;      // ⭐ 1 ms 计数器（⭐ 0..49999 ✅）
    localparam [15:0]  PORT_1MS = 16'd49999;

    // ── ④ 轮转 ＋ 共享乘法器（⭐ 32 拍一圈 ✅）
    //    ⭐ `rot_cnt` **自由运行** 0..31（⭐ 5 位自然回绕，⛔ 不需要"到 31 清零"的逻辑 ✅）
    //    ⚠️ `phase_tr` 是**新增的 32×32 寄存器组**（⭐ 1024 FF）——
    //       ⭐ 这是"共享乘法器"的**代价项**（⭐ 换来的是 ⛔ 不用 32 个乘法器 ✅）
    reg  [4:0]         rot_cnt;
    reg  [PHASE_W-1:0] phase_tr [0:POLY_TARGET-1];

    //    ⚠️ **小实例的越界保护**（⭐ 本文件是**参数化**的，⭐ tb 里有 `POLY_TARGET=4` 的实例 ✅）：
    //       ⭐ `rot_cnt` 按规格是 **5 位自由运行 0..31**，⚠️ 而数组长度是 `POLY_TARGET`
    //       ⇒ ⭐ `POLY_TARGET < 32` 时 `rot_cnt ≥ POLY_TARGET` **越界**
    //       ⇒ ⭐ 用 `rot_ok` **门控写**（⭐ 越界那几拍**什么都不写** ✅）
    //       📌 对交付值 `POLY_TARGET=32`：⭐ `rot_ok` **恒为真** ⇒ ⭐ 与规格**逐字一致** ✅
    //       ⚠️ 读侧：⭐ 越界读在仿真里给 `x`，⭐ 但它**只喂给被门控掉的写** ⇒ ⭐ 不会传播 ✅
    //    ⛔ 比较对象用 `localparam integer`（⭐ **不对 `integer` 参数做位选** —— `K-91` ✅）
    localparam integer ROT_LANES = (POLY_TARGET > 32) ? 32 : POLY_TARGET;
    wire rot_ok = (rot_cnt < ROT_LANES);

    //    ⭐ **`phase_base` 与下面的输出表达式【逐字相同】**（⭐ 同一约定：⭐ 八度移位 ＋ 32 位截断 ✅）
    wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];
    wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase
                                                        : (rot_phase << base_oct_r);

    //    ⭐ `semi_cur + 12` ⇒ ⭐ **5 位回绕算术**（⭐ 正是"下标 = 半音 + 12" ✅）：
    //       · ⭐ `semi_cur = −12` ⇒ `5'b10100 + 5'b01100` = `5'b00000` = **0** ✅
    //       · ⭐ `semi_cur =   0` ⇒ **12** ✅   · ⭐ `semi_cur = +12` ⇒ **24** ✅
    //       ⚠️ 结果宽度 = `max(5,5)` = **5 位**（⭐ 进位自然丢弃 ⇒ ⭐ 正是我们要的回绕 ✅）
    wire [4:0]         ratio_idx  = semi_cur + 5'd12;
    wire [16:0]        semi_ratio = semi_ratio_of(ratio_idx);

    //    ⭐⭐ **共享乘法器**（⭐ 全模块**只有这一个** ✅）：⭐ 32 × 17 ⇒ **49 位** ✅
    wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;

    // ── 变调核心的时序（⭐ 独立 `always` ⇒ ⛔ 不动主状态机，⭐ 与 `base_oct_r` 同一手法 ✅）
    //    ⚠️ 循环变量**另起一个**（`ti`）—— ⛔ **不能复用主块里的 `i`**
    //       （⭐ 两个 `always` 同拍写同一个 `integer` = **仿真竞态** ✅）
    integer ti;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            semi_cur <= 5'sd0;          // ⭐ 复位 = 0 档 ⇒ ⭐ 旁路 ⇒ 逐位恒等 ✅
            semi_tgt <= 5'sd0;
            port_cnt <= 16'd0;
            rot_cnt  <= 5'd0;
            for (ti = 0; ti < POLY_TARGET; ti = ti + 1)
                phase_tr[ti] <= {PHASE_W{1'b0}};
        end else begin
            semi_tgt <= semi_tgt_w;
            rot_cnt  <= rot_cnt + 5'd1;                 // ⭐ 自由运行（⭐ 5 位回绕 ✅）
            //  ⭐ **每拍算一个 lane**：⭐ 32 位截断（⭐ 与 T2 的 `<< base_oct_r` **同一约定**，
            //     ⛔ **不加饱和** —— ⭐ 交付行为由 tb 的"逐项等于 `×比例 >>> 15`"钉住 ✅）
            //  📌 `prod_w` 是**无符号** ⇒ `>>>` 与 `>>` **完全等价**（⭐ 用 `>>>` 只为与定稿一致 ✅）
            if (rot_ok)
                phase_tr[rot_cnt] <= (prod_w >>> 15);
            //  ⭐ 1 ms 一步：⭐ 到点才动，⭐ 每次只走 **±1**（⭐ 单调、⛔ 不跳变 ✅）
            if (port_cnt == PORT_1MS) begin
                port_cnt <= 16'd0;
                if      (semi_cur < semi_tgt) semi_cur <= semi_cur + 5'sd1;
                else if (semi_cur > semi_tgt) semi_cur <= semi_cur - 5'sd1;
                //  ⭐ 相等 ⇒ 保持（⭐ 不写 ⇒ 自然静止 ✅）
            end else begin
                port_cnt <= port_cnt + 16'd1;
            end
        end
    end

    // ── ⑤ 变调输出打包（⭐ 与上面**同作用域** ⇒ ⭐ 能直接读 `semi_cur` / `phase_tr` ✅）──
    //  ⭐⭐ 2026-10-01：⭐ **T2 起始音 —— 显式旁路 mux**（⭐ §54 ②）
    //     ⭐ `base_oct_r == 0` ⇒ ⭐ **逐位恒等【由构造保证】**（⛔ 不走移位器 ✅）
    //  ⚠️ **为什么移位放在【输出】而⛔ 不是【输入】**：⭐ `phase_r` 有**三条写入路径**
    //     （⭐ 起音 · ⭐ 提交 · ⭐ **滑音 `pitch_upd`**）
    //     ⇒ ⭐ 放输入只覆盖前两条 ⇒ 🔴 **滑音会绕过移位**（⭐ 不一致 ⚠️）
    //     ⇒ ⭐ 放输出 ⇒ ⭐ **三条路径全覆盖** ✅（⭐ 符合 `0.12`"枚举同类路径" ✅）
    //  ⭐⭐ 2026-10-03：⭐ **T3 变调 —— 旁路 mux ＋ 源门控**（⭐ 定稿 §五 ✅）
    //     ⭐ `semi_cur == 0` ⇒ ⭐ **逐位恒等【由构造保证】**（⭐ `base_g` 就是 T2 的原式，
    //        ⛔ **乘法器不在通路上** ⇒ ⭐ `T1` 判据"0 档逐位相同"**结构上成立** ✅）
    //     ⭐ `src_r[g] ∈ {3,4}`（⭐ 节拍器/鼓机 · looper 回放）⇒ ⭐ **逐位不变** ✅
    //        📌 **为什么这两类不跟随变调**：⭐ 节拍器/鼓机是**参考拍**（⭐ 变调会让
    //           "拍子"跟着曲子跑 ⚠️ ⇒ ⭐ 用户失去基准 ✅）；⭐ looper 是**已录素材**
    //           （⭐ 用户要的是"我弹的音变调"，⛔ 不是"把录音也变速" ✅）
    //     ⚠️ **`base_g` 必须与 T2 的原式【逐字相同】** —— ⭐ 这是"0 档恒等"的**唯一依据** ✅
    for (gp = 0; gp < POLY_TARGET; gp = gp + 1) begin : g_ph_t3
        wire [PHASE_W-1:0] base_g = (base_oct_r == 2'd0) ? phase_r[gp]
                                                         : (phase_r[gp] << base_oct_r);
        assign voice_phase_inc_o[gp*PHASE_W +: PHASE_W] =
               (semi_cur == 5'sd0) ? base_g                              // ⭐ 0 档 ⇒ 逐位恒等
             : ((src_r[gp] == 3'd3 || src_r[gp] == 3'd4) ? base_g          // ⭐ 源门控
                                                         : phase_tr[gp]);  // ⭐ 变调（轮转结果）
    end

    end else begin : g_t2
    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ `T3_EN = 0` ⇒ ⭐ **变调核心整段不存在** ⇒ ⭐ 输出回到 **T2 原式** ✅
    //   ⭐ 下面这一行与 `d36cb64^`（T2 基线）的 `gen_pack` 里那一行 **逐字相同** ✅
    //   ⭐ 判据：⭐ 综合后 `T_Lut` 必须回到 **37026 ± 100**（⭐ 无 T3 基线）✅
    //   ⚠️ 本分支**不引用** `semi_cur` / `phase_tr` / `src_r` ⇒ ⭐ 那 1025 LUT 的
    //      旁路 mux **在结构上不可能被综合出来** ✅（⛔ 不是"综合完再优化掉"）
    // ═══════════════════════════════════════════════════════════════════════
    for (gp2 = 0; gp2 < POLY_TARGET; gp2 = gp2 + 1) begin : g_ph_t2
        assign voice_phase_inc_o[gp2*PHASE_W +: PHASE_W] =
               (base_oct_r == 2'd0) ? phase_r[gp2]
                                    : (phase_r[gp2] << base_oct_r);
    end
    end
    endgenerate

    // ── 输出打包（扁平总线契约：voice i = bus[i*W +: W]，voice 0 在最低位）──
    genvar g;
    generate
        for (g = 0; g < POLY_TARGET; g = g + 1) begin : gen_pack
            assign voice_axis_o[g*AXIS_W +: AXIS_W]        = axis_r[g];
            //  ⭐⭐ 2026-10-03（`P1`）：⭐ **`voice_phase_inc_o` 已挪进 `T3_EN` 门控的
            //     `generate`（见上方 `g_t3` / `g_t2` 两个分支）** —— ⭐ 原因：
            //     `T3_EN=0` 时 `semi_cur` / `phase_tr` **根本不存在**（⭐ 在 `g_t3` 作用域内）
            //     ⇒ ⭐ 那个旁路 mux **必须与它们同生共死** ⇒ ⭐ 否则 `T3_EN=0` 时
            //     **引用不到**（⭐ 编译不过）＋ ⚠️ 更糟：⭐ 若把 mux 留在外面，
            //     那 **1025 LUT 会在 `T3_EN=0` 时依然被综合出来** ⇒ ⭐ 判据达不到 37026 ✅
            //     📌 其余 6 组输出（axis/velocity/timbre/drum/age）**与 T3 无关** ⇒ ⭐ 原地不动 ✅
            assign voice_velocity_o[g*VEL_W +: VEL_W]      = vel_r[g];
            assign voice_timbre_o[g*TIMBRE_W +: TIMBRE_W]  = timbre_r[g];
            //  ⭐⭐ 2026-09-29 新增：⭐ **保留轴位 ⇒ 打击乐 voice ⇒ 走噪声表** ✅
            //   ⭐ 为什么不新建一套"是不是打击乐"的状态：⭐ `axis_r` **已经是**那个状态
            //      （⭐ 它在分配/重触发时与 `gate_r`/`phase_r`/`vel_r` **同拍写入** ✅）
            //      ⇒ ⭐ 再存一份 = **两处真相** ⇒ 🔴 迟早不一致（⭐ `K-106` 家族教训）
            //   📌 代价：⭐ 每 voice 1 个比较器（⭐ `AXIS_W=4` ⇒ 4 位比较，⭐ 综合器折叠成
            //      极小的 LUT）＋ ⭐ **零寄存器** ✅
            //  ⭐⭐ 2026-10-01 修B：⭐ **打击乐标志改按【来源】**（⭐ 与 `pool_mask` 同一判据）✅
            //   ⚠️ **上面那段"保留轴位 ⇒ 打击乐"的说明已被本行取代** —— ⭐ 它描述的是【旧规则】：
            //      🔴 `axis_r[g] >= 14` ⇒ ⭐ **物理键 14/15 被标成"鼓 voice"** ⇒ 音色被换成噪声表
            //      ⇒ ⭐ 就算出声也是错的音 ✅
            //   ⭐ **§26.3-e「同源派生」**：⭐ `pool_mask` 与 `voice_drum_o` **必须由同一个信号导出**
            //      ⇒ ⭐ 两者都用 `src == SRC_AUX` ⇒ ⭐ **结构上不可能再不一致** ✅
            assign voice_drum_o[g] = (src_r[g] == SRC_AUX);
            assign voice_age_o[g*AGE_W +: AGE_W]           = age_r[g];
        end
    endgenerate

    assign voice_gate_o      = gate_mask;
    assign voice_active_o    = live_mask;
    assign voice_releasing_o = live_mask & ~gate_mask;
    assign voice_retrig_reset_o = retrig_reset_r;
    assign alloc_valid_o     = alloc_valid_r;
    assign alloc_voice_o     = alloc_voice_r;

    // ⭐⭐ 溢出可观测性输出（`K-106`）
    assign event_lost_o     = lost_sticky_r;
    assign event_lost_cnt_o = lost_cnt_r;

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 为什么要有：这几个组合会**静默失效**，且现象极难定位 ——
    //     ① `RESERVED_N > POLY_TARGET` ⇒ 普通轴位无 voice 可用（⛔ 按下去没声音）
    //     ② `RESERVED_N > 0` 但 `RESERVED_AXIS_BASE` 越界 ⇒ 专用池永远选不到
    //     ③ ⭐ `FIFO_DEPTH` 太小 ⇒ 一帧内的事件**溢出丢弃**（⛔ 丢音）
    //        ⭐⭐ `K-106` 修正：门槛**不是 16** —— 最坏突发 = `AXIS_N(16) + 节拍器 1 + 鼓机 1`
    //           ⇒ **18**。⚠️ 且 `AXIS_W` 可能不是 4（`AXIS_N` 随位宽变）⇒ 按 `2^AXIS_W + 2` 算。
    //     ④ ⭐ 扫描拍数必须 << 一帧（`CLK_PER_SAMPLE`），否则**扫不完就被下一个 tick 打断**
    localparam integer AXIS_MAX = (1 << AXIS_W) - 1;
    // ⭐ 最坏突发下界：每轴位最多 1 个事件 + 节拍器 1 + 鼓机 1（`K-106` 的口径）
    localparam integer FIFO_MIN  = AXIS_MAX + 1 + 2;
    initial begin
        if (RESERVED_N > POLY_TARGET)
            $display("ERROR [note_manager] RESERVED_N=%0d > POLY_TARGET=%0d => 普通轴位将无 voice 可用",
                     RESERVED_N, POLY_TARGET);
        if ((RESERVED_N > 0) && (RESERVED_AXIS_BASE > AXIS_MAX))
            $display("ERROR [note_manager] RESERVED_AXIS_BASE=%0d 超出 AXIS_W=%0d 范围 => 专用池永远选不到",
                     RESERVED_AXIS_BASE, AXIS_W);
        // ⭐ `K-106`：门槛按最坏突发算（16 轴 + 1 节拍器 + 1 鼓机 = 18），⛔ 不是写死 16
        if (FIFO_DEPTH < FIFO_MIN)
            $display("WARNING [note_manager] FIFO_DEPTH=%0d < 最坏突发 %0d (=%0d 轴 +1 节拍器 +1 鼓机) => 事件会溢出丢弃（⭐ 已由 event_lost_o 指示，但会丢音）",
                     FIFO_DEPTH, FIFO_MIN, AXIS_MAX + 1);
        if ((POLY_TARGET + 4) > 1024)
            $display("ERROR [note_manager] POLY_TARGET+4=%0d > 1024（每帧可用 clk）=> 扫描跑不完一帧",
                     POLY_TARGET + 4);
    end

endmodule

`default_nettype wire
