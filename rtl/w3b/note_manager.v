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
    //    ⚠️ 深度 16 的依据：`AXIS_N=16` ⇒ 一个采集帧内**每个轴位最多一个事件**
    parameter integer FIFO_DEPTH  = 16,
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
    output wire                              alloc_valid_o,     // 分配发生（脉冲）
    output wire [IDX_W-1:0]                  alloc_voice_o
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
    reg                    retrig_hold;
    reg [IDX_W-1:0]        retrig_idx;
    reg [1:0]              retrig_state;

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
            assign hold_mask[mg] = retrig_hold & (retrig_idx == mg);
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

    // 指向队列头（用于 `ST_DECIDE` 取出）
    wire [AXIS_W-1:0]  head_axis = fifo_ax [fifo_rd];
    wire [PHASE_W-1:0] head_inc  = fifo_inc[fifo_rd];
    wire [VEL_W-1:0]   head_vel  = fifo_vel[fifo_rd];
    wire [1:0]         head_kind = fifo_knd[fifo_rd];

    // ── 当前正在处理的事件（从队列头锁存）────────────────────────────────
    reg [AXIS_W-1:0]  cur_axis;
    reg [PHASE_W-1:0] cur_inc;
    reg [VEL_W-1:0]   cur_vel;
    reg [1:0]         cur_kind;

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
            assign same_hit[sg] = gate_mask[sg] && (axis_r[sg] == cur_axis);
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
    wire [TIMBRE_W-1:0] new_timbre = evt_timbre_valid_i ? evt_timbre_i : default_timbre_i;

    reg                    alloc_valid_r;
    reg [IDX_W-1:0]        alloc_voice_r;
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
            retrig_state  <= RT_NONE;
            retrig_hold   <= 1'b0;
            retrig_idx    <= {IDX_W{1'b0}};
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
            alloc_valid_r <= 1'b0;
            alloc_voice_r <= {IDX_W{1'b0}};
        end else begin
            alloc_valid_r <= 1'b0;

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
                fifo_wr           <= fifo_wr + 1'b1;
            end
            if (fifo_pop) fifo_rd <= fifo_rd + 1'b1;

            if (fifo_push && !fifo_pop)      fifo_cnt <= fifo_cnt + 1'b1;
            else if (!fifo_push && fifo_pop) fifo_cnt <= fifo_cnt - 1'b1;
            // 同拍 push+pop ⇒ 计数不变（⛔ 不加 else 分支）

            // ── (c) ⭐ `note_off` 现在走队列（见 (g) 的 `ST_DECIDE`）──────
            //    ⚠️ 原来这里是"立即清所有同轴位"的旁路 ⇒ ⛔ **会挂音**：
            //       若 `note_off` 对应的 `note_on` 还在队列里没处理，
            //       旁路会**清个空**，随后队列里的 `note_on` 才分配 voice
            //       ⇒ 那个音永远关不掉（同 `T38` 要防的失效模式）。
            //    ⇒ 已改为统一排队（顺序严格保持）。

            // ── (d) ⭐ 力度修正：更新**在响**的同轴位 voice（冻结表 §三）──
            if (vel_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1)
                    if (gate_mask[i] && (axis_r[i] == vel_upd_axis_i))
                        vel_r[i] <= vel_upd_value_i;
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
            if (retrig_state == RT_LOW) begin
                gate_r[retrig_idx] <= 1'b0;
                if (sample_tick_i) begin
                    gate_r[retrig_idx] <= 1'b1;
                    retrig_state       <= RT_HIGH;
                    retrig_hold        <= 1'b0;
                end
            end else if (retrig_state == RT_HIGH) begin
                gate_r[retrig_idx] <= 1'b1;
                if (sample_tick_i) retrig_state <= RT_NONE;
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
                        state    <= ST_DECIDE;
                    end
                end

                ST_DECIDE: begin
                    if (cur_kind == KIND_OFF) begin
                        // ⭐ `note_off`：清掉**所有**同轴位且 gate 高的 voice
                        //    ⚠️ 清"所有"而不是"一个" ⇒ ⭐ **防挂音**（`T38` 纪律）：
                        //       万一同轴位残留了第二个 voice，也不会永远响下去。
                        for (i = 0; i < POLY_TARGET; i = i + 1)
                            if (gate_mask[i] && (axis_r[i] == cur_axis))
                                gate_r[i] <= 1'b0;
                        if ((retrig_state != RT_NONE) && (axis_r[retrig_idx] == cur_axis)) begin
                            retrig_state <= RT_NONE;
                            retrig_hold  <= 1'b0;
                        end
                        state <= ST_IDLE;
                    end else if (same_valid) begin
                        // ⭐ 同轴位重触发优先（复用同一 voice，⛔ 不新占）
                        gate_r[same_idx]   <= 1'b0;      // 压低（RT_LOW 期间继续压）
                        retrig_state       <= RT_LOW;
                        retrig_hold        <= 1'b1;
                        retrig_idx         <= same_idx;
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
                    // ⭐ 提交（此时 `best_*` 已稳定）
                    gate_r[best_idx]   <= 1'b1;
                    axis_r[best_idx]   <= cur_axis;
                    phase_r[best_idx]  <= cur_inc;
                    vel_r[best_idx]    <= new_vel;
                    timbre_r[best_idx] <= new_timbre;
                    age_r[best_idx]    <= {AGE_W{1'b0}};
                    alloc_valid_r      <= 1'b1;
                    alloc_voice_r      <= best_idx;
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
    assign alloc_valid_o     = alloc_valid_r;
    assign alloc_voice_o     = alloc_voice_r;

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 为什么要有：这几个组合会**静默失效**，且现象极难定位 ——
    //     ① `RESERVED_N > POLY_TARGET` ⇒ 普通轴位无 voice 可用（⛔ 按下去没声音）
    //     ② `RESERVED_N > 0` 但 `RESERVED_AXIS_BASE` 越界 ⇒ 专用池永远选不到
    //     ③ ⭐ `FIFO_DEPTH` 太小 ⇒ 一帧内的事件**溢出丢弃**（⛔ 丢音）
    //     ④ ⭐ 扫描拍数必须 << 一帧（`CLK_PER_SAMPLE`），否则**扫不完就被下一个 tick 打断**
    localparam integer AXIS_MAX = (1 << AXIS_W) - 1;
    initial begin
        if (RESERVED_N > POLY_TARGET)
            $display("ERROR [note_manager] RESERVED_N=%0d > POLY_TARGET=%0d => 普通轴位将无 voice 可用",
                     RESERVED_N, POLY_TARGET);
        if ((RESERVED_N > 0) && (RESERVED_AXIS_BASE > AXIS_MAX))
            $display("ERROR [note_manager] RESERVED_AXIS_BASE=%0d 超出 AXIS_W=%0d 范围 => 专用池永远选不到",
                     RESERVED_AXIS_BASE, AXIS_W);
        if (FIFO_DEPTH < 16)
            $display("WARNING [note_manager] FIFO_DEPTH=%0d < 16 => 一个采集帧内的事件可能溢出丢弃",
                     FIFO_DEPTH);
        if ((POLY_TARGET + 4) > 1024)
            $display("ERROR [note_manager] POLY_TARGET+4=%0d > 1024（每帧可用 clk）=> 扫描跑不完一帧",
                     POLY_TARGET + 4);
    end

endmodule

`default_nettype wire
