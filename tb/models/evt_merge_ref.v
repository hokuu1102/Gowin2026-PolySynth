`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// evt_merge.v · 事件合流（手弹/曲谱/演示 + 节拍器/鼓机 + looper → note_manager 的唯一事件口）
//   —— W3c（`T36` / `U-6`）
//
// ── ⭐⭐ 2026-09-30：⭐ **第三个输入 C = looper 回放**（⭐ 用户需求）──────────────
//   🔴 **为什么加**：⭐ 原来 `top.v` 让 looper 与曲谱 UART **编译期二选一**
//      （⭐ 共用 `seq_arb` 的 `score` 口）⇒ 🔴 **两者不能同时出声**。
//      用户要求**两个都要** ⇒ ⭐ 必须给 looper 一条**自己的**通路。
//   ⭐ **做法**：⭐ 新增源 C（⭐ 只加输入，⛔ 不动 A/B 的语义）＋
//      ⭐ 来源标记 **2 → 3 位**（⭐ 5 个值：0=live / 1=score / 2=demo /
//        3=节拍器·鼓机 / 4=looper）⇒ ⭐ 下游 `note_manager` **按 (轴, 源) 隔离** ✅
//   📌 **为什么⛔ 不复用源 B 的空闲编码**：⭐ 源 B 是节拍器/鼓机，⭐ 它**一直在发**
//      ⇒ 🔴 复用 ⇒ 节拍器的 `note_off` 清掉**同轴 looper 的 voice**（⭐ 不许静默串源）✅
//
// ── 🔴 它修的是【真缺陷】，⛔ 不是新功能 ─────────────────────────────────────
//   `note_manager` **只有一个事件口**（`note_valid_i` + 4 个字段）。
//   ⚠️ `top.v` 里两个源现在是**直接或在一起**的：
//
//       .note_valid_i (demo_note_valid | met_evt_valid),
//       .note_axis_i  (demo_note_valid ? demo_note_axis : met_evt_axis),   ← 🔴
//
//   ⇒ 🔴 **同拍相撞时 `demo` 赢，`met` 的事件【静默消失】** ——
//      `note_valid_i` 只响一拍，那一整条事件就没了。
//      ⭐ `top.v` 自己的注释也承认了（"the metronome event is LOST"）。
//
//   ⇒ ⭐ 本模块的唯一职责：⭐ **两路同拍相撞【不丢】**（可仲裁/轮转，⛔ 不能丢）。
//
// ── ⭐⭐ 实现：深度 4 的环形 FIFO（⚠️ 为什么不是"一级待发寄存器"）────────────
//   🔴 **踩过的坑（2026-09-22）**：第一版用"1 个待发寄存器"，
//      自以为"同拍最多来 2 条，存 1 条发 1 条就够"。
//      ⚠️ **穷举验证后发现有 2 种组合会丢**：
//          `待发还占着` + `A 和 B 同拍都到` ⇒ 3 条在飞，1 个槽装不下 ⇒ 🔴 丢 1 条。
//      ⇒ ⭐ **教训：缓冲深度要按"最坏在飞条数"算，⛔ 不能靠直觉**
//        （在飞 = 队列里已有的 + 本拍新到的）。
//
//   ⭐ 现在：**环形 FIFO，深度 `DEPTH`（默认 4）**
//      · 每拍**最多推入 3 条**（A、B、C 各一条）、**弹出 1 条**
//        ⚠️ **2026-09-30**：⭐ 原来是 2 条 —— ⭐ 加了源 C（looper）⇒ ⭐ 上限变 3 条
//      · ⭐ **弹出优先于推入**（先腾位置），`cnt_next = cnt + push - pop`
//      · ⚠️ 队列空时**不弹**（避免吐出垃圾）⇒ 代价是**首次入队晚 1 拍**（20 ns）
//   📌 **深度 4 够不够（⭐ 算过）**：⭐ 要求 `DEPTH ≥ 3`（⭐ "队列空 + 同拍来 3 条"）
//      ⇒ ⭐ 4 满足；⚠️ 而**任何有限深度**在"队列已满 + 同拍来 3 条"时都会溢出
//      ⇒ ⭐ 由 `overflow_o` / `drop_cnt_o` **看见**（⭐ 见下方"诚实的边界"）✅
//      📌 而**实际速率**远低于此：⭐ A ≤ 1/tick、B ≤ 1/960 tick、C ≤ 1/tick ✅
//
// ── ⭐⭐ 关于"能不能保证【永不】丢"（⚠️ 诚实的边界）──────────────────────────
//   ⚠️ **3 个源各以 1 条/拍持续输入 = 3 条/拍，而出口只有 1 条/拍** ⇒
//      ⭐ **任何有限深度都会溢出**（这是信息论的，⛔ 不是实现问题）。
//   ⇒ ⭐ 本模块的承诺是**两级的**：
//      ① ⭐ **在实际源速率下【不丢】**：节拍器 **1 条/960 tick**、
//         曲谱 `play_seq` **≤1 条/tick** ⇒ ⚠️ 稳态远低于 1 条/拍，深度 4 足够
//      ② ⭐⭐ **万一溢出【必须看得见】**：`overflow_o`（sticky）+ `drop_cnt_o`
//         ⇒ ⛔ **不静默丢**（`K-106` 纪律）
//   ⇒ ⭐ **"能证明的上界"比"声称不会发生"可靠**。
//
// ── ⭐ 轮转（round-robin）── ⛔ 不饿死任何一方 ───────────────────────────────
//   ⚠️ 若固定"A 永远先推"，则**每拍都相撞**时 B 会被持续推后。
//   ⇒ ⭐ 每次**真的做过 A/B 取舍**就翻面 ⇒ ⭐ 两个源轮流先走。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 2001 编译，用了 SV 专有构造
//     ⇒ **整个模块被静默丢弃**，而 iverilog 全绿）
//   · ⭐ **组合逻辑用 `assign`；`always @(*)` 只用在"真的读信号"的块上**（`L67`）
//   · ⛔ **不对 `integer` 参数做位选**（`K-91`）
//   · ⭐ **不用 PLL / CPU / HLS**；单时钟域
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module evt_merge_ref #(
    parameter integer AXIS_W  = 4,
    parameter integer PHASE_W = 32,
    parameter integer VEL_W   = 8,
    parameter integer KIND_W  = 2,
    parameter integer TIMBRE_W = 2,
    // ⭐ FIFO 深度。⚠️ 必须 ≥ 2（⚠️ 否则"待发 1 条 + 同拍来 2 条"就装不下 —— 那正是第一版的 bug）
    parameter integer DEPTH   = 4
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── 源 A：手弹 / 曲谱 / 演示（`seq_arb` 三级仲裁的输出）────────────────
    input  wire                  a_valid_i,
    input  wire [AXIS_W-1:0]     a_axis_i,
    input  wire [PHASE_W-1:0]    a_phase_inc_i,
    input  wire [VEL_W-1:0]      a_velocity_i,
    input  wire [KIND_W-1:0]     a_kind_i,
    input  wire                  a_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   a_timbre_i,
    //  ⭐⭐ 2026-09-29（A1）：⭐ 源 A 的**来源标记**（⭐ 由 `seq_arb.evt_src_o` 驱动）
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3**（⭐ 编码表见 `seq_arb` 的 `evt_src_o` 注释）
    //     ⭐ 本模块只**透传**它（⭐ 存进 FIFO、随事件弹出）⇒ ⛔ 不解释、⛔ 不比较 ✅
    input  wire [2:0]            a_src_i,

    // ── 源 B：节拍器 / 鼓机 ────────────────────────────────────────────────
    input  wire                  b_valid_i,
    input  wire [AXIS_W-1:0]     b_axis_i,
    input  wire [PHASE_W-1:0]    b_phase_inc_i,
    input  wire [VEL_W-1:0]      b_velocity_i,
    input  wire [KIND_W-1:0]     b_kind_i,
    input  wire                  b_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   b_timbre_i,
    //  ⭐⭐ 2026-09-29（A1）：⭐ 源 B 的**来源标记**（⭐ 由 `top.v` 给**常数** `3'd3`）
    //     ⭐ 3 是 `seq_arb` 编码（0/1/2）之外的**第 4 个值** ⇒ ⭐ 与手弹/曲谱/演示**必然不同源**
    input  wire [2:0]            b_src_i,

    // ── ⭐⭐ 2026-09-30 新增：源 C —— **looper 回放**（⭐ 用户需求：曲谱与 looper 同时可用）──
    //  🔴 **为什么必须有【第三个】输入**（⭐ 这是本任务的核心决定，⭐ 有代码依据）：
    //     ⭐ 原来 `top.v` 让 looper 与曲谱 UART **共用 `seq_arb` 的 `score` 口**
    //        （⭐ 编译期二选一）⇒ 🔴 **两者不可能同时出声** ✅
    //     ⚠️ 而 **A/B 两个口都已经有主**：⭐ A = 手弹/曲谱/演示、⭐ B = 节拍器/鼓机
    //        ⇒ ⭐ **要让 looper 与曲谱并存，只能新开一个口** ✅
    //     📌 **⛔ 不能"复用源 B 的空闲编码"**：⭐ 源 B 是节拍器/鼓机，⭐ 它**一直在发**
    //        （⭐ 节拍器每拍一个 click）⇒ 🔴 复用它 ⇒ 节拍器的 `note_off`
    //        会把**同轴 looper 的 voice** 清掉（⭐ 与 A1 修掉的那个缺陷同类）✅
    //
    //  ⭐ **C 的仲裁语义（⭐ 有意做得最保守）**：
    //     · ⭐ **A/B 之间的轮转【一个字都不改】**（⭐ `prio_b_r` 仍然只由 A、B 驱动）
    //     · ⭐ C **永远排在 A/B 之后**（⭐ 即"占用最后一槽"）
    //     ⚠️ **为什么"最低优先"在这里是安全的**：⭐ C 的来源是 looper 的**回放**
    //        ⇒ ⭐ 它的速率上限是 **1 条/PPQN tick**（⭐ 而 1 tick ≈ 2.6 万拍），
    //        ⭐ 与 A/B 的实际速率**差 4 个数量级** ⇒ ⭐ **结构上不可能被饿死** ✅
    //        （📌 与 `seq_arb` 里"演示让位"那条**不同**：⭐ 那里演示是**自检**、
    //           ⭐ 抢了真演奏就失去意义；⭐ 而 looper 是**用户内容**，
    //           ⭐ 所以这里**不丢弃、只排队** —— 宁可晚 1 拍也⛔ 不丢 ✅）
    //     📌 溢出仍然**必须可见**（⭐ `overflow_o` + `drop_cnt_o`，⭐ `K-106`）✅
    input  wire                  c_valid_i,
    input  wire [AXIS_W-1:0]     c_axis_i,
    input  wire [PHASE_W-1:0]    c_phase_inc_i,
    input  wire [VEL_W-1:0]      c_velocity_i,
    input  wire [KIND_W-1:0]     c_kind_i,
    input  wire                  c_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   c_timbre_i,
    //  ⭐ 源 C 的**来源标记** = `3'd4`（looper 回放，⭐ 由 `top.v` 给常数）
    input  wire [2:0]            c_src_i,

    // ── 合流后的唯一事件口（→ `note_manager`）─────────────────────────────
    output reg                   evt_valid_o,
    output reg  [AXIS_W-1:0]     evt_axis_o,
    output reg  [PHASE_W-1:0]    evt_phase_inc_o,
    output reg  [VEL_W-1:0]      evt_velocity_o,
    output reg  [KIND_W-1:0]     evt_kind_o,
    output reg                   evt_timbre_valid_o,
    output reg  [TIMBRE_W-1:0]   evt_timbre_o,
    //  ⭐⭐ 2026-09-29（A1）：⭐ 合流后事件的**来源标记** —— ⭐ 时序 = `evt_valid_o`
    //     ⭐ 一路穿过本模块的 FIFO（⭐ 与 `timbre` 字段**完全同样的手法**）
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3** —— ⭐ 3 个输入源共 5 个不同标签
    //     （0=live · 1=score · 2=demo · 3=节拍器/鼓机 · 4=looper）
    output reg  [2:0]            evt_src_o,

    // ── ⭐ 可观测性（`K-106` 纪律：容量有限/会失效的东西必须能看见）──────────
    output reg  [15:0]           collision_cnt_o,  // ⭐ 同拍相撞次数（饱和）
    output reg  [15:0]           merged_cnt_o,     // ⭐ 已合流发出的事件数（饱和）
    output reg  [15:0]           drop_cnt_o,       // ⭐ 因溢出丢弃的条数（饱和）
    output reg                   overflow_o        // ⭐⚠️ **溢出**（sticky，复位清）
);

    // ── ⭐ 打包成一条记录（⚠️ 用一个向量，FIFO 索引就简单了）──────────────────
    localparam integer ENT_W = AXIS_W + PHASE_W + VEL_W + KIND_W + 1 + TIMBRE_W;
    //  ⭐⭐ 2026-09-29（A1）：⭐ **来源标记**（⭐ 与 `seq_arb` 同一手法）
    //     ⚠️ 放在记录的**最高位** ⇒ ⭐ 原有字段偏移（`AX_O`/`IN_O`/`VE_O`/`TV_O`）
    //        **一个都不用动** —— ⭐ 这正是"只加不改"的关键（⛔ 不碰已验证的位域）
    //  ⭐⭐ 2026-09-30：⭐ **2 → 3 位**（⭐ 见 `evt_src_o` 的编码表）
    //     ⭐ 加宽是**纯粹的位宽变化**：⭐ 偏移公式（`ENT_W +: SRC_W`）本身不用改 ✅
    localparam integer SRC_W  = 3;
    localparam integer ENT2_W = SRC_W + ENT_W;
    localparam integer AX_O  = PHASE_W + VEL_W + KIND_W + 1 + TIMBRE_W;
    localparam integer IN_O  = VEL_W + KIND_W + 1 + TIMBRE_W;
    localparam integer VE_O  = KIND_W + 1 + TIMBRE_W;
    localparam integer TV_O  = TIMBRE_W;

    // ⭐⭐ 把整数参数先落到**定宽 localparam** 再参与运算
    //   🔴 **`K-91`：⛔ 绝不对 `integer` 参数做位选**（`DEPTH[15:0]` 这种）。
    //      ⚠️ 本模块第一版就写了 `DEPTH[15:0]` ⇒ 🔴 **索引比较全部失效**
    //      ⇒ 现象：`collision_cnt_o` **正常计数**（那条路径不碰 DEPTH），
    //        但 **数据推不进队列、`cnt_q` 不动** ⇒ ⚠️ 看起来像"事件根本没进来"。
    //      ⭐ 教训：**这条规则不是形式主义** —— 它会让一整块逻辑静默失效。
    localparam [15:0] DEPTH_C  = DEPTH;
    localparam [15:0] DEPTH_M1 = DEPTH_C - 16'd1;

    function [ENT2_W-1:0] pack_evt;
        input [SRC_W-1:0]   src;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        input [KIND_W-1:0]  kd;
        input               tv;
        input [TIMBRE_W-1:0] tb;
        begin
            pack_evt = {src, ax, inc, vl, kd, tv, tb};
        end
    endfunction

    // ── ⭐ FIFO 存储与指针 ─────────────────────────────────────────────────
    //   ⚠️ 用**环形缓冲**（⛔ 不是移位寄存器）：推入/弹出各只动一个指针，
    //      ⛔ 不搬数据 ⇒ 面积小、时序好（⚠️ 本项目 Fmax 余量薄）。
    reg [ENT2_W-1:0] mem [0:DEPTH-1];
    reg [15:0]      cnt_q;
    reg [15:0]      head_q;      // ⭐ 弹出位置
    reg [15:0]      tail_q;      // ⭐ 推入位置

    // ⭐ 轮转标志：0 ⇒ A 先；1 ⇒ B 先
    reg prio_b_r;

    // ── ⭐ 组合：本拍能不能弹 ───────────────────────────────────────────────
    wire          pop_now = (cnt_q != 16'd0);        // ⭐ 空队列不弹（⛔ 不吐垃圾）
    wire [ENT2_W-1:0] pop_data = mem[head_q];

    // ── ⭐ 组合：本拍推几条（⭐ 冲突时按 prio_b_r 定【谁先】）────────────────
    //   ⚠️ 两条都要推时，**顺序**要定下来（FIFO 是保序的，先推的先出）
    wire push_a_first = ~prio_b_r;
    wire push_a = a_valid_i;
    wire push_b = b_valid_i;
    //  ⭐⭐ 2026-09-30：⭐ **源 C（looper 回放）的 valid**
    //   ⚠️ **用 `=== 1'b1` 判定**（⛔ 不是直接取用）—— ⭐ 这是**向后兼容**的关键一步：
    //      ⭐ 已有的 tb（`tb_evt_merge` / `tb_timbre_event_path` …）**不认识新端口**
    //      ⇒ ⚠️ 它们不接 `c_valid_i` ⇒ 悬空是 `z` ⇒ 🔴 若直接取用，`push_n` 会变成 `x`
    //         ⇒ ⭐ **那些 tb 会莫名其妙地全红**（⭐ 与 `looper.v` 的 `live_busy`
    //            "悬空 = 没有"是**同一套向后兼容口径** ✅）
    //   📌 语义：⭐ **只有明确的 1 才算"本拍有 C 事件"**，⭐ 其余（含 `x`/`z`）一律当**没有** ✅
    wire push_c = (c_valid_i === 1'b1);
    // 🔴🔴 **必须显式写位宽** —— 这是本模块最隐蔽的一个 bug（2026-09-22 实测踩到）：
    //    `wire push_n = ...` **不写位宽 ⇒ 隐含 1 bit**！
    //    ⭐ 于是 `1 + 1 = 2` 被**截断成 `1'b0`** ⇒ 🔴 **"两路同拍相撞"这一种情况
    //       恰好把计数算成 0** ⇒ ⛔ 什么都不推进队 ⇒ ⚠️ 而**单路来时 `1` 是对的**。
    //    ⇒ ⭐ 现象极具欺骗性：**单源正常、一相撞就"什么都没发生"**
    //       （⚠️ `collision_cnt_o` 还照常计数，因为那条路径不经过 `push_n`）
    //       ⇒ 看起来像"相撞被吞了"，⛔ 其实是**位宽截断**。
    //    📌 **教训**：⛔ 别依赖隐式位宽 —— ⭐ `wire` 不写宽度就是 1 位。
    //  ⭐⭐ 2026-09-30：⭐ 加到**三路**（A/B/C）—— ⚠️ 位宽纪律**照旧**（⭐ 仍是 16 位）✅
    wire [15:0] push_n = (push_a ? 16'd1 : 16'd0)
                       + (push_b ? 16'd1 : 16'd0)
                       + (push_c ? 16'd1 : 16'd0);

    //  ── ⭐⭐ 三个源各自写进哪个槽（⭐ 2026-09-30 新增的"紧凑写入"手法）──────────
    //   ⭐ **语义与改动前【逐位等价】**（⭐ 只推 A/B 时）：
    //      · ⭐ A、B 谁在 0 号槽由 `prio_b_r` 决定 ⇒ ⭐ **轮转一个字都没改** ✅
    //      · ⭐ C **永远排在 A/B 之后** ⇒ ⭐ 它是"最后一槽"（⭐ 理由见端口区注释）✅
    //   📌 **为什么用"偏移"而不是"再加一层 if/else 链"**：
    //      ⚠️ 原写法是"两两组合各写一遍"（⭐ 4 个分支 × 2 次写 = 8 条写语句）
    //      ⇒ 🔴 加到三路就是 **8 个分支 × 3 次写 = 24 条**，⭐ 既难读又容易漏一种组合
    //         （⚠️ `evt_merge` 第一版正是"漏了组合"才丢事件 ✅）
    //      ⇒ ⭐ 改成"**先算槽位、再各写一条**" ⇒ ⭐ 3 条写语句覆盖**全部 8 种组合**，
    //         ⭐ 且**结构上不可能漏**（⭐ 每个源一条独立的 `if`）✅
    wire [15:0] off_a = push_b ? (push_a_first ? 16'd0 : 16'd1) : 16'd0;
    wire [15:0] off_b = push_a ? (push_a_first ? 16'd1 : 16'd0) : 16'd0;
    wire [15:0] off_c = (push_a ? 16'd1 : 16'd0) + (push_b ? 16'd1 : 16'd0);

    //  ⭐ 槽位回绕（⭐ 与 `seq_arb.tail_plus` 同一手法：⛔ 不用取模，⭐ 逐个减）
    //   ⚠️ `n` 最大 **2**（⭐ C 的偏移最大 = A+B 都在 = 2）、⭐ `DEPTH ≥ 3`
    //      ⇒ ⭐ **最多减两次**就够（⭐ 下面写了两次，⭐ 与 `seq_arb` 的写法一致）✅
    function [15:0] tail_off;
        input [15:0] t;
        input [15:0] n;
        reg   [15:0] r;
        begin
            r = t + n;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            tail_off = r;
        end
    endfunction

    // ⭐ 本拍净变化（⚠️ 弹出优先 ⇒ 先腾位再推，能多接一条）
    wire [15:0] cnt_after_pop  = pop_now ? (cnt_q - 16'd1) : cnt_q;
    wire [15:0] cnt_next       = cnt_after_pop + push_n;
    wire        will_overflow  = (cnt_next > DEPTH_C);

    // ── 输出：本拍弹出来那条（⭐ 单周期脉冲，⛔ 不拉宽）──────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            evt_valid_o     <= 1'b0;
            evt_axis_o      <= {AXIS_W{1'b0}};
            evt_phase_inc_o <= {PHASE_W{1'b0}};
            evt_velocity_o  <= {VEL_W{1'b0}};
            evt_kind_o      <= {KIND_W{1'b0}};
            evt_timbre_valid_o <= 1'b0;
            evt_timbre_o    <= {TIMBRE_W{1'b0}};
            evt_src_o       <= {SRC_W{1'b0}};   // ⭐ A1：来源标记也复位（⛔ 不留 X）
            cnt_q           <= 16'd0;
            head_q          <= 16'd0;
            tail_q          <= 16'd0;
            prio_b_r        <= 1'b0;
            collision_cnt_o <= 16'd0;
            merged_cnt_o    <= 16'd0;
            drop_cnt_o      <= 16'd0;
            overflow_o      <= 1'b0;
        end else begin
            // ⭐ 默认：脉冲类输出每拍清零 ⇒ 严格单周期
            evt_valid_o <= 1'b0;

            // ══ ① 弹出并输出（⭐ 弹出优先，先腾位置）════════════════════════
            if (pop_now) begin
                evt_valid_o     <= 1'b1;
                evt_axis_o      <= pop_data[AX_O +: AXIS_W];
                evt_phase_inc_o <= pop_data[IN_O +: PHASE_W];
                evt_velocity_o  <= pop_data[VE_O +: VEL_W];
                evt_kind_o      <= pop_data[TV_O + 1 +: KIND_W];
                evt_timbre_valid_o <= pop_data[TV_O +: 1];
                evt_timbre_o    <= pop_data[0 +: TIMBRE_W];
                // ⭐ A1：⭐ 来源标记与**本拍弹出的这条**同时输出（⭐ 时序 = `evt_valid_o`）
                evt_src_o       <= pop_data[ENT_W +: SRC_W];
                head_q          <= (head_q + 16'd1 == DEPTH_C) ? 16'd0
                                                                   : head_q + 16'd1;
                merged_cnt_o    <= (merged_cnt_o == 16'hFFFF) ? merged_cnt_o
                                                             : merged_cnt_o + 16'd1;
            end

            // ══ ② 推入（⚠️ 只有装得下才推；⛔ 装不下要【看得见】）════════════
            //   ⚠️ 索引用"本拍 tail + 偏移"，⭐ 三条同时推时偏移 0/1/2
            //  ⭐⭐ 2026-09-30：⭐ **改成"紧凑写入"**（⭐ 每个源一条独立 `if`）
            //     · ⭐ 槽位 = `tail_off(tail_q, off_x)`（⭐ 见上方 `off_a/off_b/off_c`）
            //     · ⭐ **A/B 的先后仍由 `prio_b_r` 决定**（⭐ 轮转语义不变 ✅）
            //     · ⭐ C 固定占最后一槽（⭐ 理由见端口区 ✅）
            //   📌 **时序影响**：⭐ 槽位地址多了一级 3 输入加法（⭐ `off_c`），
            //      ⚠️ 但它是**纯组合的浅逻辑**（⭐ 3 位宽，⭐ 而 `mem` 只有 4 深）
            //      ⇒ ⭐ 实测由 PnR 报（⭐ 本任务**不跑 PnR**，⭐ 见报告）✅
            if (push_n != 16'd0) begin
                if (!will_overflow) begin
                    // ⭐ 源 A（⭐ 手弹 / 曲谱 / 演示，⭐ 由 `seq_arb` 打标）
                    if (push_a)
                        mem[tail_off(tail_q, off_a)]
                            <= pack_evt(a_src_i, a_axis_i, a_phase_inc_i,
                                        a_velocity_i, a_kind_i,
                                        a_timbre_valid_i, a_timbre_i);
                    // ⭐ 源 B（⭐ 节拍器 / 鼓机）
                    if (push_b)
                        mem[tail_off(tail_q, off_b)]
                            <= pack_evt(b_src_i, b_axis_i, b_phase_inc_i,
                                        b_velocity_i, b_kind_i,
                                        b_timbre_valid_i, b_timbre_i);
                    // ⭐⭐ 源 C（⭐ looper 回放 —— ⭐ 2026-09-30 新增）
                    if (push_c)
                        mem[tail_off(tail_q, off_c)]
                            <= pack_evt(c_src_i, c_axis_i, c_phase_inc_i,
                                        c_velocity_i, c_kind_i,
                                        c_timbre_valid_i, c_timbre_i);

                    // ⭐ 推进 tail（按实际推入条数）
                    //   ⚠️ `push_n` 最大 **3**、⭐ `DEPTH ≥ 3` ⇒ ⭐ 最多减一次就够
                    //      （⭐ `tail_q + 3 ≤ DEPTH + 2 < 2*DEPTH` ✅）
                    tail_q <= (tail_q + push_n >= DEPTH_C)
                              ? (tail_q + push_n - DEPTH_C) : (tail_q + push_n);
                    cnt_q  <= cnt_next;
                end else begin
                    // 🔴 **溢出**：⭐ 丢弃并**记数 + 置 sticky 标志**（⛔ 不静默）
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : drop_cnt_o + push_n;
                    // ⚠️ 不推入（⛔ 不动 tail），⭐ 但**本拍的弹出必须照样记账** ——
                    //    🔴 这里踩过坑：原来 overflow 分支里**完全没写 `cnt_q`**，
                    //       于是"同一拍既弹出又被拒"时计数不减 ⇒ `cnt_q` **永远 > 0**
                    //       ⇒ `pop_now` 恒真 ⇒ 🔴 `evt_valid_o` **一直挂着**（不再单周期），
                    //       ⚠️ 而且 `head_q` 每拍都在推进 ⇒ 吐的是**队列里的旧数据**，
                    //       现象是"valid 一直高、数据不变"，很容易误判成 DUT 死锁。
                    //    ⇒ ⭐ 正确做法：**弹出优先记账**，推入是否成功只影响加多少。
                    cnt_q <= cnt_after_pop;
                end
            end else if (pop_now) begin
                // ⭐ 只弹不推：更新计数（tail 不动）
                cnt_q <= cnt_after_pop;
            end

            // ══ ③ 统计与优先级翻转 ══════════════════════════════════════════
            //  ⭐⭐ 2026-09-30：⭐ **"相撞"扩到三路**（⭐ 任两路同拍即为相撞）
            //   📌 **判据不变**：⭐ 原来的 A/B 相撞**照样计数** ⇒ ⭐ 老 tb 的判据不受影响 ✅
            //   ⚠️ 注意：⭐ 只统计**真正参与推入**的（⭐ C 用 `push_c`，
            //      而 `push_c` 已经把"悬空"排除掉了 ✅）
            if ((push_a && push_b) || (push_a && push_c) || (push_b && push_c)) begin
                collision_cnt_o <= (collision_cnt_o == 16'hFFFF) ? collision_cnt_o
                                                                 : collision_cnt_o + 16'd1;
            end
            // ⭐ 只有**真的在 A/B 两条之间做过取舍**才翻面（⚠️ 单条来时翻面没有意义）
            //   📌 ⭐ **C 不参与轮转**（⭐ 它固定占最后一槽 ⇒ 翻面与否都改变不了它的位置）
            //      ⇒ ⭐ 保持"只有 A、B 都到才翻面"⇒ ⭐ **与改动前逐位一致** ✅
            if (a_valid_i && b_valid_i) begin
                prio_b_r <= ~prio_b_r;
            end
        end
    end

endmodule

`default_nettype wire
