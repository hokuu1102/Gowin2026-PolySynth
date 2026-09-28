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

    input  wire                              vel_upd_valid_i,    // ⭐ 力度修正（后到）
    input  wire [AXIS_W-1:0]                 vel_upd_axis_i,
    input  wire [VEL_W-1:0]                  vel_upd_value_i,

    input  wire                              pitch_upd_valid_i,  // ⭐ 音高修正（滑音持续移动）
    input  wire [AXIS_W-1:0]                 pitch_upd_axis_i,
    input  wire [PHASE_W-1:0]                pitch_upd_value_i,

    // ── 接口 ② · 参数通路（新起音的默认音色，`K-82`）──────────────────────
    input  wire [TIMBRE_W-1:0]               default_timbre_i,
    input  wire                              evt_timbre_valid_i, // ⭐ Looper 每层覆盖
    input  wire [TIMBRE_W-1:0]               evt_timbre_i,

    // ── 包络状态回读（判断 voice 是否还在响）──────────────────────────────
    input  wire [POLY_TARGET-1:0]            env_active_i,
    input  wire [POLY_TARGET*ENV_W-1:0]      env_level_i,

    // ── 输出 → `oscillator_bank` / `envelope_bank` ─────────────────────────
    output wire [POLY_TARGET-1:0]            voice_gate_o,       // → envelope_bank.gate_i
    output wire [POLY_TARGET-1:0]            voice_active_o,     // → oscillator_bank.voice_active_i
    output wire [POLY_TARGET-1:0]            voice_releasing_o,  // 诊断：gate=0 但还在响
    output wire [POLY_TARGET*AXIS_W-1:0]     voice_axis_o,       // 诊断 / 抢占
    output wire [POLY_TARGET*PHASE_W-1:0]    voice_phase_inc_o,  // → oscillator_bank
    output wire [POLY_TARGET*VEL_W-1:0]      voice_velocity_o,   // → envelope_bank
    output wire [POLY_TARGET*TIMBRE_W-1:0]   voice_timbre_o,     // → wavetable（`K-82`）
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
    localparam [VEL_W-1:0]  DEFAULT_VEL_V = DEFAULT_VEL;
    localparam integer      NORMAL_N      = (RESERVED_N > POLY_TARGET)
                                            ? POLY_TARGET
                                            : POLY_TARGET - RESERVED_N;

    // 重触发状态机编码
    localparam [1:0] RT_NONE = 2'd0;
    localparam [1:0] RT_LOW  = 2'd1;   // 已压低，等 sample_tick（让 ADSR 看见 0）
    localparam [1:0] RT_HIGH = 2'd2;   // 已抬高，等 sample_tick（让 ADSR 看见 1）

    // 扫描 FSM 编码（`T66`）
    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_DECIDE = 3'd1;   // 已取出事件，判"同轴位重触发"还是"扫描分配"
    localparam [2:0] ST_SCAN   = 3'd2;   // 每拍考察一个 voice
    localparam [2:0] ST_COMMIT = 3'd3;   // 提交选中结果

    localparam integer SCAN_LAST = POLY_TARGET - 1;
    localparam integer SW = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET);   // 扫描计数位宽
    localparam integer FW = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);

    // ── 每 voice 独立状态（⭐ 冻结表禁令 4：⛔ 不共用相位/包络）─────────────
    reg                    gate_r   [0:POLY_TARGET-1];
    reg [AXIS_W-1:0]       axis_r   [0:POLY_TARGET-1];
    reg [PHASE_W-1:0]      phase_r  [0:POLY_TARGET-1];
    reg [VEL_W-1:0]        vel_r    [0:POLY_TARGET-1];
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
            assign live_mask[mg] = gate_r[mg] | hold_mask[mg] | env_active_i[mg];
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

    // ── 当前正在处理的事件（从队列头锁存）────────────────────────────────
    reg [AXIS_W-1:0]  cur_axis;
    reg [PHASE_W-1:0] cur_inc;
    reg [VEL_W-1:0]   cur_vel;
    reg [1:0]         cur_kind;
    reg               cur_timbre_valid;
    reg [TIMBRE_W-1:0] cur_timbre;

    // ── ⭐ 池掩码：由**锁存后的** `cur_axis` 决定（⛔ 不是活的 `note_axis_i`）──
    //    ⚠️ 必须用 `assign` + `generate`（`L67`：常量块在 `always @(*)` 里不执行）
    wire [POLY_TARGET-1:0] pool_mask;
    genvar pg;
    generate
        for (pg = 0; pg < POLY_TARGET; pg = pg + 1) begin : gen_pool
            if (RESERVED_N == 0)
                assign pool_mask[pg] = 1'b1;
            else
                assign pool_mask[pg] = (cur_axis >= RESERVED_AXIS)
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
            assign same_hit[sg] = (gate_r[sg] | retrig_low[sg] | env_active_i[sg])
                                && (axis_r[sg] == cur_axis);
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
    // ═══════════════════════════════════════════════════════════════════════
    reg [SW-1:0]     scan_cnt;
    reg              best_valid;
    reg [IDX_W-1:0]  best_idx;
    reg [1:0]        best_cls;
    reg [ENV_W-1:0]  best_env;
    reg [AGE_W-1:0]  best_age;

    // 当前扫描位的候选属性（组合，深度浅）
    wire [IDX_W-1:0]   cand_idx   = scan_cnt[IDX_W-1:0];
    wire               cand_hold  = hold_mask[cand_idx];
    wire               cand_pool  = pool_mask[cand_idx];
    wire               cand_free  = free_mask[cand_idx];
    wire               cand_rel   = (~gate_mask[cand_idx]) & env_active_i[cand_idx];
    wire [1:0]         cand_cls   = cand_free ? 2'd0 : (cand_rel ? 2'd1 : 2'd2);
    wire [ENV_W-1:0]   cand_env   = env_level_i[cand_idx*ENV_W +: ENV_W];
    wire [AGE_W-1:0]   cand_age   = age_r[cand_idx];

    // ⭐ "更优"判据（⛔ 只用一级比较；升序扫描 + 严格优于 ⇒ 并列取最低索引）
    wire cand_ok = cand_pool & ~cand_hold;
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
    //  ⭐ 重触发清零脉冲：**单周期**（每 clk 先清、由 (f)/(g) 两处按需置位）
    reg  [POLY_TARGET-1:0] retrig_reset_r;
    integer i;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (i = 0; i < POLY_TARGET; i = i + 1) begin
                gate_r[i]   <= 1'b0;
                axis_r[i]   <= {AXIS_W{1'b0}};
                phase_r[i]  <= {PHASE_W{1'b0}};
                vel_r[i]    <= {VEL_W{1'b0}};
                timbre_r[i] <= {TIMBRE_W{1'b0}};
                age_r[i]    <= {AGE_W{1'b0}};
            end
            for (i = 0; i < FIFO_DEPTH; i = i + 1) fifo_v[i] <= 1'b0;
            fifo_wr       <= {FW{1'b0}};
            fifo_rd       <= {FW{1'b0}};
            fifo_cnt      <= {(FW+1){1'b0}};
            retrig_low    <= {POLY_TARGET{1'b0}};
            state         <= ST_IDLE;
            scan_cnt      <= {SW{1'b0}};
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
            alloc_valid_r <= 1'b0;
            alloc_voice_r <= {IDX_W{1'b0}};
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
            //     · ADSR 只在 `sample_tick_i` 那一拍采样 `retrig_reset_i`（`adsr.v:61-69`）
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
            if (vel_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (gate_mask[i] && (axis_r[i] == vel_upd_axis_i))
                        vel_r[i] <= vel_upd_value_i;   // ⭐ 位置式：可增可减
            end

            // ── (e) ⭐ 音高修正：更新**在响**（含 Release 尾巴）的同轴位 voice ──
            //    ⚠️ 只改 `phase_inc`，⛔ **绝不清相位** ⇒ 滑音不产生"咔"声
            if (pitch_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (live_mask[i] && (axis_r[i] == pitch_upd_axis_i))
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
                        state    <= ST_DECIDE;
                    end
                end

                ST_DECIDE: begin
                    if (cur_kind == KIND_OFF) begin
                        // ⭐ `note_off`：清掉**所有**同轴位且 gate 高的 voice
                        //    ⚠️ 清"所有"而不是"一个" ⇒ ⭐ **防挂音**（`T38` 纪律）：
                        //       万一同轴位残留了第二个 voice，也不会永远响下去。
                        for (i = 0; i < POLY_TARGET; i = i + 1)
                            if ((gate_r[i] | retrig_low[i]) && (axis_r[i] == cur_axis)) begin
                                gate_r[i]     <= 1'b0;
                                //  ⭐⭐ **`note_off` 无条件优先**（2026-09-28 根因修复）：
                                //     同时清掉"重触发压低"位 ⇒ (f) 段此后再不会把它抬回 1
                                //     ⇒ ⛔ 彻底杜绝"清了又被拉回"的永久挂音。
                                //  📌 原判据用 `gate_mask[i]`（= `gate_r & ~hold_mask`），
                                //     压低期间恒为 0 ⇒ **跳过该 voice** ⇒ 挂音。
                                retrig_low[i] <= 1'b0;
                            end
                        state <= ST_IDLE;
                    end else if (same_valid) begin
                        // ⭐ 同轴位重触发优先（复用同一 voice，⛔ 不新占）
                        gate_r[same_idx]     <= 1'b0;   // 压低（由 (f) 段保持到 sample_tick）
                        retrig_low[same_idx] <= 1'b1;   // ⭐ 每 voice 一位（⛔ 不再用全局 retrig_idx）
                        phase_r[same_idx]  <= cur_inc;
                        vel_r[same_idx]    <= new_vel;
                        timbre_r[same_idx] <= new_timbre;
                        age_r[same_idx]    <= {AGE_W{1'b0}};
                        state              <= ST_IDLE;
                    end else begin
                        // ⭐ 启动扫描（⛔ 不能保证一定有空闲 voice，故要扫全部）
                        scan_cnt   <= {SW{1'b0}};
                        best_valid <= 1'b0;
                        state      <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    // ⭐ 每拍只考察一个 voice ⇒ 深度 = 32:1 mux + 一级比较
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
                        gate_r[best_idx]   <= 1'b1;
                        axis_r[best_idx]   <= cur_axis;
                        phase_r[best_idx]  <= cur_inc;
                        vel_r[best_idx]    <= new_vel;
                        timbre_r[best_idx] <= new_timbre;
                        age_r[best_idx]    <= {AGE_W{1'b0}};
                        //  ⭐ 抢占也要清零包络 —— ⚠️ `best_idx` 可能是**正在 release、
                        //     包络仍有残值**的 voice（`cand_rel` 类别就是它）⇒
                        //     🔴 不清零就会把"别人的尾巴"和新音叠加 = 同一个尖音 bug。
                        //  📌 与 `gate` 同拍：ADSR 里 `retrig_reset_i` 优先级**高于**
                        //     `gate` 判定 ⇒ ⭐ 同拍不会既清零又按残余电平起振。
                        retrig_reset_r[best_idx] <= 1'b1;
                        alloc_valid_r      <= 1'b1;
                        alloc_voice_r      <= best_idx;
                    end
                    state              <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ── 输出打包（扁平总线契约：voice i = bus[i*W +: W]，voice 0 在最低位）──
    genvar g;
    generate
        for (g = 0; g < POLY_TARGET; g = g + 1) begin : gen_pack
            assign voice_axis_o[g*AXIS_W +: AXIS_W]        = axis_r[g];
            assign voice_phase_inc_o[g*PHASE_W +: PHASE_W] = phase_r[g];
            assign voice_velocity_o[g*VEL_W +: VEL_W]      = vel_r[g];
            assign voice_timbre_o[g*TIMBRE_W +: TIMBRE_W]  = timbre_r[g];
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
