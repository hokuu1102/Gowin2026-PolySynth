`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// note_manager.v · 32 voice 分配 / 抢占 / 释放 / 参数更新（W3b · `T54`）
//
// ⭐ 为什么需要它（第二周 C 组「接通出声链」的第一块）：
//   `top.v` 第 97 行原本 `sample_mono = 0`（**顶层送静音**），且 `note_manager` **不存在**
//   ⇒ ⛔ **不接通，板子永远不出声**；⚠️ 且**所有自动功能（节拍器/鼓机/Looper）都依赖它**
//   （它们走的是同一条**事件通路**，见 `Looper详细设计.md` §一）。
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/W3接口冻结表.md`
//   · §三 接口 ① 事件通路：`note_evt_t` / `vel_update_t` / `pitch_update_t`
//   · §二 全局参数：`POLY_TARGET=32`、`OSC_PER_VOICE=2`、`PHASE_W=32`、`VEL_W=8`
//   · §四 延迟预算：⭐ **本模块 ≤ 4 拍**
//   · `K-82`：⭐ `timbre` 是**每 voice 属性**（起音时刻锁存），⛔ 不是全局直连
//
// ⭐ 三条设计要点（都来自冻结表，⛔ 不是我自己加的）
//
//   ① ⭐ **按 `axis_id` 寻址，⛔ 不用 `voice_id`**
//      W3a **不知道** `voice_id`（冻结表 §二：`POLY_TARGET` 变了接口不动）。
//      ⇒ 事件带 `axis_id`，本模块负责 `axis_id ⇄ voice` 的映射。
//
//   ② ⭐⭐ **必须支持"更新在响 voice"**（冻结表 §三 接口 ① 的 `vel_update_t` 说明）
//      力度用**双阈值测速法**：越过浅阈 t1 就发声（用 `DEFAULT_VEL`），
//      t2 到了再用 `vel_update_t` **修正那个 voice 的音量**。
//      ⇒ ⛔ 若本模块只会"分配新 voice"，力度修正就落不下去。
//      滑音同理走 `pitch_update_t`（`phase_inc` 连续变化，⛔ 不重发 note_on）。
//
//   ③ ⭐⭐ **抢占顺序固定**（`RTL代码结构与接口规划.md` §2.6 末段）：
//        **空闲 voice → 已 Release 且电平最低 → 年龄最老；并列取最低索引**
//      ⛔ **禁止可变长搜索**；候选比较树**拍数固定**（本模块为**纯组合**，1 拍内出结果）。
//
// ⚠️ 与冻结表的一处**新增端口**（已在 `K-92` 记录）：
//   冻结表 §2.6 的 `voice_manager` 端口表**没有** `env_active_i` / `env_level_i`，
//   但同表 `envelope_bank` 的 `env_active_o` 注明「→ **manager**/status」。
//   ⭐ 本模块**需要**它们来判断"voice 是否还在响"（否则要自己复制一份 ADSR 状态 ⇒ 更糟）。
//   ⇒ 按冻结表原意补上这两个**输入**（⛔ 不改任何既有端口名/宽度）。
//
// ⛔ 纪律（本项目血泪）：
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 把 `.sv` 当 Verilog-2001 编译，
//     用了 SV 专有构造 `N'()`/`logic`/`always_ff` ⇒ **整个模块被丢弃**，而**仿真全绿**）
//     ⇒ ⛔ 本文件里也**不对 `integer` 做位选**（`K-91` 顺带发现）
//   · ⛔ 不用 PLL、不派生时钟；`sample_tick_i` 只是**时钟使能**（冻结表 §〇 约定 1）
//   · ⛔ 不给每个 voice 复制相位累加器/包络 —— 那两件事分别归 `oscillator_bank`/`envelope_bank`
//   · ⭐ **单周期脉冲必须"边沿时刻断言"**（冻结表 §〇 约定 4）—— 本模块的输入事件都是脉冲
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
    //    ⭐ 落地 `T33b` 时再决定是"`POLY_TARGET` 加大"还是"接受 28+4"（见 `K-92`）。
    parameter integer RESERVED_N  = 0,
    // ⭐ 起音用的默认力度（冻结表：越过浅阈 t1 就发声，用 `DEFAULT_VEL` 起音）
    parameter integer DEFAULT_VEL = 200,
    // ⭐ 专用 axis_id 起点（`Looper详细设计.md` §二：建议 `4'hE` 节拍器 / `4'hF` 鼓机）
    parameter integer RESERVED_AXIS_BASE = 14,
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
    localparam [1:0] RT_NONE = 2'd0;   // 空闲
    localparam [1:0] RT_LOW  = 2'd1;   // 已压低，等 sample_tick（让 ADSR 看见 0）
    localparam [1:0] RT_HIGH = 2'd2;   // 已抬高，等 sample_tick（让 ADSR 看见 1 ⇒ 重起 Attack）

    // ── 每 voice 独立状态（⭐ 冻结表禁令 4：⛔ 不共用相位/包络）─────────────
    reg                    gate_r   [0:POLY_TARGET-1];
    reg [AXIS_W-1:0]       axis_r   [0:POLY_TARGET-1];
    reg [PHASE_W-1:0]      phase_r  [0:POLY_TARGET-1];
    reg [VEL_W-1:0]        vel_r    [0:POLY_TARGET-1];
    reg [TIMBRE_W-1:0]     timbre_r [0:POLY_TARGET-1];
    reg [AGE_W-1:0]        age_r    [0:POLY_TARGET-1];

    // ── 事件分类（⛔ 约定 4：脉冲在边沿时刻用，⛔ 不事后查询）─────────────
    wire do_on  = note_valid_i && ((note_kind_i == KIND_ON) || (note_kind_i == KIND_PLUCK));
    wire do_off = note_valid_i && (note_kind_i == KIND_OFF);

    // ── 重触发保持（压低期间该 voice 的 gate 必须表现为 0）──────────────────
    reg                    retrig_hold;
    reg [IDX_W-1:0]        retrig_idx;

    // ── "还在响" = gate 高 **或** 包络仍在活动（Release 尾巴）───────────────
    //    ⭐ 三个 mask 语义不同，⛔ 别合并：
    //      · gate    —— ADSR 的门（note_on 置 1、note_off 清 0）
    //      · active  —— **还能出声**（Release 尾巴也算）⇒ 给振荡器用，尾巴期间不许停相位
    //      · free    —— 完全空闲（可以**直接**拿来做新音，⛔ 不需要抢占）
    //    ⚠️ 重触发压低期间要把 gate **对外**表现成 0，否则会被当成"还在响"而跳过分配。
    //
    //    ⚠️⚠️ 2026-09-21 实测踩坑（`T54`，跑 tb 抓到 **两个真 bug**）：
    //
    //    ① `always @(*)` + `for` 给 `gate_mask` 赋值时，iverilog 对"数组元素是否算
    //       敏感信号"的处理与综合器不同，实测出现 `gate_mask` **不随 `gate_r` 更新**。
    //       ⇒ ⭐ 一律改为**连续赋值**（`assign` + `generate`），语义明确、不依赖工具推断。
    //
    //    ② 🔴 **重触发压低期间，该 voice 会"看起来是空闲的"** ——
    //       因为 `free_mask = ~(gate_mask | env_active)`，而压低时 `gate_mask=0`。
    //       ⇒ ⚠️ 若此时来了**另一个轴位**的 `note_on`，它会**合法地抢走这个 voice**；
    //          紧接着重触发把 gate 抬回 ⇒ ⛔ **把新音符的 voice 又抢回去了**
    //          （表现为"新按的音没声音 / 串音"，而且**只在 2 拍窗口内偶发**，极难复现）。
    //       ⇒ ⭐ 修法：重触发期间该 voice **仍然算"占用"**（`busy`），
    //          只是**对外 gate 表现为 0**（让 ADSR 看到下降沿）。
    wire [POLY_TARGET-1:0] hold_mask;   // 正在重触发压低中的 voice
    wire [POLY_TARGET-1:0] gate_mask;   // 对外门（压低期间为 0）
    wire [POLY_TARGET-1:0] live_mask;   // 还能出声（含 Release 尾巴 + 重触发保持）
    wire [POLY_TARGET-1:0] free_mask;   // 完全空闲（⭐ 重触发保持**不算**空闲）
    genvar mg;
    generate
        for (mg = 0; mg < POLY_TARGET; mg = mg + 1) begin : gen_mask
            assign hold_mask[mg] = retrig_hold & (retrig_idx == mg);
            assign gate_mask[mg] = gate_r[mg] & ~hold_mask[mg];
            // ⭐ live 把 hold 也算进去 ⇒ 振荡器不停相位；⛔ 不会被当成空闲
            assign live_mask[mg] = gate_r[mg] | hold_mask[mg] | env_active_i[mg];
            assign free_mask[mg] = ~live_mask[mg];
        end
    endgenerate

    // ── 专用 voice 池（`T33b`）────────────────────────────────────────────
    //    ⭐ 规则：`axis_id >= RESERVED_AXIS_BASE` 的事件**只**能用专用池（最高 `RESERVED_N` 个）；
    //            普通轴位**只**能用普通池（最低 `NORMAL_N` 个）。
    //    ⇒ ⭐ **32 音全响时，节拍器仍出声**（它的 voice 不参与抢占）。
    //    ⚠️ `RESERVED_N=0` ⇒ 池掩码全 1（所有事件都能用所有 voice，⛔ 无行为变化）。
    //
    //    ⚠️⚠️ 2026-09-21 实测踩坑（`T54`，**第一次跑 tb 就抓到**）：
    //       本段原来写成 `always @(*)` + `for` 循环，而 `RESERVED_N==0` 时
    //       循环体是**常量赋值**（不读任何信号）⇒ ⭐ **该 always 块没有任何敏感信号**
    //       ⇒ iverilog 直接警告 **`@* found no sensitivities so it will never trigger`**
    //       ⇒ ⛔ **块从不执行** ⇒ `pool_mask` 恒为 0 ⇒ `sel_valid` 永假
    //       ⇒ ⭐ **一个 voice 都分配不出去**（按下去完全没声音）。
    //       📌 教训：⭐ **"全是常量的组合块"在仿真里根本不执行** ——
    //          这类"参数化后整块退化成常量"的代码**必须写成连续赋值（`assign`）**，
    //          ⛔ 不要用 `always @(*)`。（Gowin 综合侧则会把常量块正常折叠 ⇒
    //          ⚠️ **两边行为不一致**，这正是它危险的地方。）
    wire [POLY_TARGET-1:0] pool_mask;
    genvar pg;
    generate
        for (pg = 0; pg < POLY_TARGET; pg = pg + 1) begin : gen_pool
            if (RESERVED_N == 0)
                assign pool_mask[pg] = 1'b1;
            else
                assign pool_mask[pg] = (note_axis_i >= RESERVED_AXIS)
                                       ? (pg >= NORMAL_N)
                                       : (pg < NORMAL_N);
        end
    endgenerate

    // ── ⭐⭐ 候选选择（组合、固定深度；⛔ 不用可变长搜索）───────────────────
    //    优先级：① 池内空闲 → ② 池内已 Release 且**电平最低** → ③ 池内**年龄最老**
    //    ⚠️ 两个循环都**从高索引往低索引**扫、且用**严格比较** ⇒
    //       **并列时自然取最低索引**（满足"并列取最低索引"）。
    //    ⚠️ `K-91` 纪律：⛔ 不对 `integer` 做位选 ⇒ 直接整型赋值（隐式截断）
    reg                    sel_valid;
    reg [IDX_W-1:0]        sel_idx;
    reg [ENV_W-1:0]        best_env;
    reg [AGE_W-1:0]        best_age;
    integer si;

    always @(*) begin
        sel_valid = 1'b0;
        sel_idx   = {IDX_W{1'b0}};
        best_env  = {ENV_W{1'b1}};
        best_age  = {AGE_W{1'b0}};

        // ① 池内**完全空闲**的最低索引
        for (si = POLY_TARGET - 1; si >= 0; si = si - 1) begin
            if (pool_mask[si] && free_mask[si]) begin
                sel_valid = 1'b1;
                sel_idx   = si;
            end
        end

        // ② 池内**已 Release（gate=0 但还在响）且包络电平最低**的最低索引
        //    ⚠️ 必须**排除重触发保持中的 voice**（`!hold_mask`）——
        //       否则它 `gate_mask=0 + env_active=1` 会被误判成"已 Release"，
        //       于是**另一个轴位的 note_on 会合法地抢走它**（同上方 ② 号 bug）。
        if (!sel_valid) begin
            for (si = POLY_TARGET - 1; si >= 0; si = si - 1) begin
                if (pool_mask[si] && !gate_mask[si] && !hold_mask[si]
                    && env_active_i[si]
                    && (env_level_i[si*ENV_W +: ENV_W] < best_env)) begin
                    best_env  = env_level_i[si*ENV_W +: ENV_W];
                    sel_valid = 1'b1;
                    sel_idx   = si;
                end
            end
        end

        // ③ 池内**年龄最老**的最低索引（真抢占；会切掉一个还在响的音）
        //    ⚠️⚠️ 这里必须用 `>=` **且** 从 `0` 起比（⛔ 不是 `>`）——
        //       若用严格 `>`，则"所有 voice 年龄都是 0"（例如连续几拍内按满，
        //       一个 `sample_tick` 都还没来过）时会**一个候选都选不出来**
        //       ⇒ `sel_valid=0` ⇒ ⛔ **按下去没声音**（静默丢音）。
        //       `>=` + 从高索引往低索引扫 ⇒ 取到**最大年龄**，且**并列取最低索引**。
        if (!sel_valid) begin
            for (si = POLY_TARGET - 1; si >= 0; si = si - 1) begin
                if (pool_mask[si] && (age_r[si] >= best_age)) begin
                    best_age  = age_r[si];
                    sel_valid = 1'b1;
                    sel_idx   = si;
                end
            end
        end
    end

    // ── ⭐ 同轴位重触发：复用**同一个** voice，⛔ 不新占一个 ─────────────────
    //    为什么：同一根键重复按（或滑音期间又来 note_on）不该吃掉两个 voice。
    //    ⚠️⚠️ 但 ADSR **只在 gate 出现 0→1 沿时才重新 Attack**（见 `adsr.v` 第 52~55 行），
    //       而它**只在 `sample_tick_i` 那一拍采 `gate`** ⇒ ⛔ **压低 1 个 clk 是不够的**
    //       （那 1 拍很可能落在两个 sample_tick 之间 ⇒ **ADSR 根本没看见 gate=0**
    //        ⇒ **包络不会重起**，表现为"重按同一个键没有新起音"—— 一个**静默失效**）。
    //    ⇒ ⭐ 正确做法：**按采样拍走两步** ——
    //         ① 压 gate 低 → ② **等一个 `sample_tick_i`**（ADSR 看到 0）→
    //         ③ 抬 gate 高 → ④ **再等一个 `sample_tick_i`**（ADSR 在 releasing 里看到 1 ⇒ 回 ATTACK）
    //    📌 代价 = 2 个采样拍（≈41 µs）—— 对"重触发"语义完全可接受，
    //       且 ⛔ **不影响**"首次起音"路径（那条路不需要重触发）。
    reg                    same_valid;
    reg [IDX_W-1:0]        same_idx;
    integer qi;
    always @(*) begin
        same_valid = 1'b0;
        same_idx   = {IDX_W{1'b0}};
        for (qi = POLY_TARGET - 1; qi >= 0; qi = qi - 1) begin
            if (gate_mask[qi] && (axis_r[qi] == note_axis_i)) begin
                same_valid = 1'b1;
                same_idx   = qi;
            end
        end
    end

    reg [1:0]              retrig_state;
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
            retrig_state  <= RT_NONE;
            retrig_hold   <= 1'b0;
            retrig_idx    <= {IDX_W{1'b0}};
            alloc_valid_r <= 1'b0;
            alloc_voice_r <= {IDX_W{1'b0}};
        end else begin
            alloc_valid_r <= 1'b0;

            // ── (a) 年龄：每采样拍 +1（饱和），⛔ 不溢出 ──────────────────
            if (sample_tick_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1) begin
                    if (live_mask[i] && (age_r[i] != {AGE_W{1'b1}}))
                        age_r[i] <= age_r[i] + 1'b1;
                end
            end

            // ── (b) ⭐ 重触发两步走（见上方长注释）──────────────────────────
            if (retrig_state == RT_LOW) begin
                gate_r[retrig_idx] <= 1'b0;            // 保持低，等 ADSR 看见
                if (sample_tick_i) begin
                    gate_r[retrig_idx] <= 1'b1;        // 抬回（ADSR 下一拍才会看到）
                    retrig_state       <= RT_HIGH;
                    retrig_hold        <= 1'b0;        // 交给 gate_r 自己维持
                end
            end else if (retrig_state == RT_HIGH) begin
                gate_r[retrig_idx] <= 1'b1;
                if (sample_tick_i)                     // ADSR 已看到 1 ⇒ 回 ATTACK
                    retrig_state <= RT_NONE;
            end

            // ── (c) note_off：清掉**所有**同轴位且 gate 高的 voice ────────
            //    ⚠️ 清"所有"而不是"一个" ⇒ ⭐ **防挂音**（同 Looper 的 `T38` 纪律）：
            //       万一同轴位残留了第二个 voice，也不会永远响下去。
            if (do_off) begin
                for (i = 0; i < POLY_TARGET; i = i + 1) begin
                    if (gate_mask[i] && (axis_r[i] == note_axis_i))
                        gate_r[i] <= 1'b0;
                end
                // ⚠️ 若被关掉的正是重触发中的 voice ⇒ 放弃重触发（否则会把 gate 抬回去）
                if ((retrig_state != RT_NONE) && (axis_r[retrig_idx] == note_axis_i)) begin
                    retrig_state <= RT_NONE;
                    retrig_hold  <= 1'b0;
                end
            end

            // ── (d) note_on / pluck：优先重触发，否则按候选分配 ───────────
            if (do_on) begin
                if (same_valid) begin
                    // ⭐ 复用同一 voice：更新音高/力度/音色，并启动两步重触发
                    gate_r[same_idx]   <= 1'b0;      // 压低（RT_LOW 期间继续压）
                    retrig_state       <= RT_LOW;
                    retrig_hold        <= 1'b1;
                    retrig_idx         <= same_idx;
                    phase_r[same_idx]  <= note_phase_inc_i;
                    vel_r[same_idx]    <= (note_velocity_i != {VEL_W{1'b0}})
                                          ? note_velocity_i : DEFAULT_VEL_V;
                    timbre_r[same_idx] <= evt_timbre_valid_i ? evt_timbre_i : default_timbre_i;
                    age_r[same_idx]    <= {AGE_W{1'b0}};   // 重新变"年轻"
                end else if (sel_valid) begin
                    gate_r[sel_idx]   <= 1'b1;
                    axis_r[sel_idx]   <= note_axis_i;
                    phase_r[sel_idx]  <= note_phase_inc_i;
                    vel_r[sel_idx]    <= (note_velocity_i != {VEL_W{1'b0}})
                                         ? note_velocity_i : DEFAULT_VEL_V;
                    timbre_r[sel_idx] <= evt_timbre_valid_i ? evt_timbre_i : default_timbre_i;
                    age_r[sel_idx]    <= {AGE_W{1'b0}};
                    alloc_valid_r     <= 1'b1;
                    alloc_voice_r     <= sel_idx;
                end
            end

            // ── (e) ⭐ 力度修正：更新**在响**的同轴位 voice（冻结表 §三 要求）──
            //    ⚠️ 只改力度，⛔ 不动 gate / 年龄 / 相位 ⇒ 听感上是"这个音的力度"
            if (vel_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1) begin
                    if (gate_mask[i] && (axis_r[i] == vel_upd_axis_i))
                        vel_r[i] <= vel_upd_value_i;
                end
            end

            // ── (f) ⭐ 音高修正：更新**在响**（含 Release 尾巴）的同轴位 voice ──
            //    ⚠️ 只改 `phase_inc`，⛔ **绝不清相位** ⇒ 滑音不产生"咔"声
            //       （`A7` 检查器守的就是这条：变调时相位必须继续前进）
            if (pitch_upd_valid_i) begin
                for (i = 0; i < POLY_TARGET; i = i + 1) begin
                    if (live_mask[i] && (axis_r[i] == pitch_upd_axis_i))
                        phase_r[i] <= pitch_upd_value_i;
                end
            end
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
    //     ① `RESERVED_N > POLY_TARGET` ⇒ `NORMAL_N` 被夹成 0 ⇒ **普通轴位无 voice 可用**
    //        ⇒ ⛔ 一按就没声音，但代码"看着没错"；
    //     ② `RESERVED_N > 0` 但 `RESERVED_AXIS_BASE` 越界（≥ 2^AXIS_W）
    //        ⇒ 专用池**永远选不到** ⇒ 节拍器没声。
    //   ⇒ 仿真启动时明确打印（综合工具忽略 `initial`，所以只是仿真侧防线）。
    localparam integer AXIS_MAX = (1 << AXIS_W) - 1;
    initial begin
        if (RESERVED_N > POLY_TARGET)
            $display("ERROR [note_manager] RESERVED_N=%0d > POLY_TARGET=%0d => 普通轴位将无 voice 可用（见 K-92）",
                     RESERVED_N, POLY_TARGET);
        if ((RESERVED_N > 0) && (RESERVED_AXIS_BASE > AXIS_MAX))
            $display("ERROR [note_manager] RESERVED_AXIS_BASE=%0d 超出 AXIS_W=%0d 可表示范围 => 专用池永远选不到",
                     RESERVED_AXIS_BASE, AXIS_W);
        if ((RESERVED_N > 0) && (NORMAL_N < 1))
            $display("ERROR [note_manager] RESERVED_N=%0d 吃光了普通池（NORMAL_N=%0d）",
                     RESERVED_N, NORMAL_N);
    end

endmodule

`default_nettype wire
