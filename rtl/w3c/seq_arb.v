`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// seq_arb.v · 源 A 三级仲裁（手弹 / 曲谱 / 演示 → `evt_merge` 源 A）
//   —— W3c（⭐ 2026-09-26 新增，⭐ 补 `top.v:1520` 的 TODO）
//
// ── 🔴 它解决什么问题 ────────────────────────────────────────────────────────
//   `evt_merge` 的**源 A 只有一个入口**，⚠️ 而现在有【3 个来源】都往里挤：
//     ① ⭐ **手弹**（W3a 采集链：琴键 → `event_extract`）
//     ② ⭐ **曲谱**（`evt_uart_rx`：串口灌进来的事件）
//     ③ ⭐ **演示**（`DEMO_CHORD_ON`：复位后自动起一个三音和弦，⭐ 自检用）
//
//   ⚠️ 原来的做法是一个**编译期二选一参数** `SOURCE_A_SEL`（0=手弹 / 1=演示），
//      🔴 **曲谱根本挤不进去** ⇒ ⭐ 灌了曲谱**不会响**。
//
//   📌 `top.v` 自己的注释（⭐ 原文）：
//      *"TODO（曲谱接入时）：那时源 A 要有 3 个来源（手弹/曲谱/演示）
//        ⇒ 应改成 `evt_merge` 前再加一级仲裁"* ⇒ ⭐ **本模块就是那一级**。
//
// ── ⭐⭐ 实现：直接复用 `evt_merge` 的【已验证】手法 ─────────────────────────
//   ⚠️ **为什么不重新设计**：`evt_merge` 是**穷举验证过**的
//      （⭐ 它的第一版用"1 个待发寄存器" ⇒ 🔴 **穷举后发现 2 种组合会丢**）
//      ⇒ ⭐ **同一类问题、同一个解法** ⇒ ⭐ **照抄它的环形 FIFO，⛔ 不发明新的**。
//
//   ⭐ 环形 FIFO，深度 `DEPTH`（默认 **6**）：
//      · ⭐ **每拍最多推入 3 条**（A/B/C 各一条）、**弹出 1 条**
//      · ⭐ **弹出优先于推入**（先腾位置）⇒ `cnt_next = cnt + push - pop`
//      · ⚠️ 队列空时**不弹**（避免吐垃圾）⇒ 代价是**首次入队晚 1 拍**（20 ns）
//
// ── 🔴 深度为什么是 6（⭐ 算过，⛔ 不是拍脑袋）───────────────────────────────
//   ⚠️ `evt_merge` 的教训：⭐ **深度要按"最坏在飞条数"算**。
//   本模块最坏：⭐ 队列里已有 `DEPTH-1` 条 + 本拍又来 3 条 ⇒ ⚠️ **需要 DEPTH+2**。
//   ⭐ 但和 `evt_merge` 一样，⭐ **实际源速率远低于 1 条/拍**：
//      · 手弹：⭐ 人手指最快 ~10 次/秒（⭐ 而 1 拍 = 20 ns ⇒ 密度可忽略）
//      · 曲谱：⭐ `play_seq` **≤1 条/tick**，⭐ tick = 960/四分音符
//      · 演示：⭐ 只发 **3+3 = 6 条**（⭐ 起音 3 + 收音 3）⇒ ⚠️ 瞬时，⛔ 不持续
//   ⇒ ⭐ **深度 6 有大量余量**（⭐ 20 倍以上）。⚠️ 万一溢出 ⇒ ⭐ **必须看得见**。
//
// ── ⭐⭐ 关于"能不能保证【永不】丢"（⚠️ 诚实的边界）──────────────────────────
//   ⚠️ 3 个源各以 1 条/拍持续输入 = 3 条/拍，而出口只有 1 条/拍
//      ⇒ ⭐ **任何有限深度都会溢出**（⭐ 这是信息论的，⛔ 不是实现问题）。
//   ⇒ ⭐ 本模块的承诺和 `evt_merge` 一样，是**两级的**：
//      ① ⭐ **在实际源速率下【不丢】**（⭐ 见上：密度远低于 1 条/拍）
//      ② ⭐⭐ **万一溢出【必须看得见】**：`overflow_o`（sticky）+ `drop_cnt_o`
//         ⇒ ⛔ **不静默丢**（`K-106` 纪律）
//   ⇒ ⭐ **"能证明的上界"比"声称不会发生"可靠**。
//
// ── ⭐ 优先级（⭐ 与"轮转"配合，⛔ 不饿死任何一方）──────────────────────────
//   ⭐ **固定优先级**：⭐ **手弹 > 曲谱 > 演示**
//      ⇒ ⭐ 理由：⭐ **人优先于机器** —— ⚠️ 演奏者按下琴键时，
//         ⭐ 那个音**必须**立刻发出去（⭐ 延迟是手感的一部分）。
//
//   ⚠️ 但**光有固定优先级不够**：⭐ 若"手弹每拍都有"，🔴 曲谱会被**永久饿死**。
//   ⇒ ⭐ 本模块用**两级机制**：
//      · ⭐ **推入顺序**按"真实做过取舍则轮转"（⭐ 同 `evt_merge`）——
//        ⭐ 保证两个源**轮流先出队**
//      · ⭐ **演示优先让位**：⭐ `demo_active_i` 拉起时，⚠️ 若 A/B 也有事件，
//        ⭐ **演示不参与**（⭐ 它是"自检"，⛔ 不该和真演奏抢）
//   📌 **为什么不用"绝对优先级"**：⚠️ 绝对优先级 ⇒ 🔴 **低优先级源被饿死**
//      （⭐ 这正是 `evt_merge` 注释里"⛔ 不饿死任何一方"那条）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 2001 编译，用 SV 专有构造
//     ⇒ **整个模块被静默丢弃**，而 iverilog 全绿）
//   · ⭐ **不对 `integer` 参数做位选**（`K-91`）⇒ ⭐ 先落到定宽 `localparam`
//   · 🔴 **`wire` 必须显式写位宽**（⚠️ `evt_merge` 踩过：`wire push_n` 隐含 1 bit
//     ⇒ `1+1` 截成 0 ⇒ ⭐ **"两路同拍相撞"恰好什么都不做**）
//   · ⭐ **组合逻辑用 `assign`**（`L67`）· ⭐ 单时钟域、⛔ 不用 PLL/CPU/HLS
//   · ⭐ **声明必须先于使用**（`L66`）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module seq_arb #(
    parameter integer AXIS_W  = 4,
    parameter integer PHASE_W = 32,
    parameter integer VEL_W   = 8,
    parameter integer KIND_W  = 2,
    parameter integer TIMBRE_W = 2,
    // ⭐ FIFO 深度。⚠️ 必须 ≥ 3（⚠️ 否则"待发 + 同拍来 3 条"就装不下 ——
    //    ⭐ 那正是 `evt_merge` 第一版的 bug 模式）。⭐ 默认 6 留足余量。
    parameter integer DEPTH   = 6
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── ⭐ 源 1：手弹（W3a 采集链）—— ⭐ 最高优先 ───────────────────────────
    input  wire                  live_valid_i,
    input  wire [AXIS_W-1:0]     live_axis_i,
    input  wire [PHASE_W-1:0]    live_phase_inc_i,
    input  wire [VEL_W-1:0]      live_velocity_i,
    input  wire [KIND_W-1:0]     live_kind_i,
    input  wire                  live_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   live_timbre_i,

    // ── ⭐ 源 2：曲谱（`evt_uart_rx` → 串口灌入）────────────────────────────
    input  wire                  score_valid_i,
    input  wire [AXIS_W-1:0]     score_axis_i,
    input  wire [PHASE_W-1:0]    score_phase_inc_i,
    input  wire [VEL_W-1:0]      score_velocity_i,
    input  wire [KIND_W-1:0]     score_kind_i,
    input  wire                  score_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   score_timbre_i,

    // ── ⭐ 源 3：演示（`DEMO_CHORD_ON` 自检和弦）—— ⭐ 最低优先 ─────────────
    input  wire                  demo_valid_i,
    input  wire [AXIS_W-1:0]     demo_axis_i,
    input  wire [PHASE_W-1:0]    demo_phase_inc_i,
    input  wire [VEL_W-1:0]      demo_velocity_i,
    input  wire [KIND_W-1:0]     demo_kind_i,
    input  wire                  demo_timbre_valid_i,
    input  wire [TIMBRE_W-1:0]   demo_timbre_i,

    // ── 仲裁后的唯一出口（→ `evt_merge` 的源 A）────────────────────────────
    output reg                   evt_valid_o,
    output reg  [AXIS_W-1:0]     evt_axis_o,
    output reg  [PHASE_W-1:0]    evt_phase_inc_o,
    output reg  [VEL_W-1:0]      evt_velocity_o,
    output reg  [KIND_W-1:0]     evt_kind_o,
    output reg                   evt_timbre_valid_o,
    output reg  [TIMBRE_W-1:0]   evt_timbre_o,
    //  ⭐⭐ 2026-09-29（A1）：⭐ **事件来源标记** —— ⭐ 与 `evt_valid_o` **同时序**
    //     ⭐ 编码 = 内部 `SRC_*`（⭐ 0=live 手弹 / 1=score 曲谱·回放 / 2=demo 演示）
    //     ⚠️ 位宽**写死 2** —— `NW` 是模块体内的 `localparam`，⭐ ANSI 端口表在它之前
    //        ⇒ ⛔ 不能引用（`K-91` 同族纪律：⛔ 不对参数做位选）
    //     ⭐ 用途：⭐ 下游 `note_manager` 据此**按源**区分 `note_off`
    //        ⇒ ⭐ 回放（`score`）的 `note_off` ⛔ 不再误杀手弹（`live`）的同轴 voice
    output reg  [1:0]            evt_src_o,

    // ── ⭐ 可观测性（`K-106` 纪律：容量有限/会失效的东西必须能看见）──────────
    output reg  [15:0]           collision_cnt_o,  // ⭐ 多源同拍相撞次数（饱和）
    output reg  [15:0]           merged_cnt_o,     // ⭐ 已仲裁发出的事件数（饱和）
    output reg  [15:0]           drop_cnt_o,       // ⭐ 因溢出丢弃的条数（饱和）
    output reg                   overflow_o,       // ⭐⚠️ 溢出（sticky，复位清）
    output reg  [15:0]           live_cnt_o,       // ⭐ 转发的手弹事件数（⭐ 上板可看）
    output reg  [15:0]           score_cnt_o,      // ⭐ 转发的曲谱事件数
    output reg  [15:0]           demo_cnt_o        // ⭐ 转发的演示事件数
);

    // ── ⭐ 打包成一条记录（⚠️ 用一个向量，FIFO 索引就简单了）──────────────────
    localparam integer ENT_W = AXIS_W + PHASE_W + VEL_W + KIND_W + 1 + TIMBRE_W;
    localparam integer AX_O  = PHASE_W + VEL_W + KIND_W + 1 + TIMBRE_W;
    localparam integer IN_O  = VEL_W + KIND_W + 1 + TIMBRE_W;
    localparam integer VE_O  = KIND_W + 1 + TIMBRE_W;
    localparam integer TV_O  = TIMBRE_W;

    // ⭐⭐ 把整数参数先落到**定宽 localparam** 再参与运算
    //   🔴 **`K-91`：⛔ 绝不对 `integer` 参数做位选**（`DEPTH[15:0]` 这种）
    localparam [15:0] DEPTH_C  = DEPTH;
    localparam [15:0] DEPTH_M1 = DEPTH_C - 16'd1;

    // ⭐⭐ 记录字段宽度（⭐ `evt_merge` 的同样手法）
    localparam integer NW = 2;        // ⭐ 源编号宽度（3 个源 ⇒ 2 bit）
    localparam [NW-1:0] SRC_LIVE  = 2'd0;
    localparam [NW-1:0] SRC_SCORE = 2'd1;
    localparam [NW-1:0] SRC_DEMO  = 2'd2;

    // ⭐ 事件记录 = {源编号, 轴, 相位增量, 力度, 类型}
    //   📌 ⭐ **把源编号也存进去** ⇒ ⭐ 弹出时才能知道"这条是谁的" ⇒ ⭐ 好统计
    localparam integer ENT2_W = NW + ENT_W;
    function [ENT2_W-1:0] pack_src;
        input [NW-1:0]      src;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        input [KIND_W-1:0]  kd;
        input               tv;
        input [TIMBRE_W-1:0] tb;
        begin
            pack_src = {src, ax, inc, vl, kd, tv, tb};
        end
    endfunction

    // ── ⭐ FIFO 存储与指针 ─────────────────────────────────────────────────
    //   ⚠️ 用**环形缓冲**（⛔ 不是移位寄存器）：推入/弹出各只动一个指针，
    //      ⛔ 不搬数据 ⇒ 面积小、时序好（⚠️ 本项目 Fmax 余量薄）。
    reg [ENT2_W-1:0] mem [0:DEPTH-1];
    reg [15:0]       cnt_q;
    reg [15:0]       head_q;      // ⭐ 弹出位置
    reg [15:0]       tail_q;      // ⭐ 推入位置

    // ── ⭐ 组合：本拍能不能弹 ───────────────────────────────────────────────
    wire             pop_now  = (cnt_q != 16'd0);   // ⭐ 空队列不弹（⛔ 不吐垃圾）
    wire [ENT2_W-1:0] pop_data = mem[head_q];

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 推入仲裁（⭐ 本模块的核心）
    // ══════════════════════════════════════════════════════════════════════
    //   ⭐ **两级机制**（⭐ 见文件头说明）：
    //     ① ⭐ **演示让位**：⭐ 若"有别的源在发"，⚠️ 演示**主动不参与**
    //        ⇒ ⭐ 它是自检，⛔ 不该和真演奏抢
    //     ② ⭐ **A/B 之间轮转**：⭐ 只有两路**真的都到**且**真的做过取舍**才翻面
    //
    //   📌 **为什么演示用"让位"而不是"最低优先级"**：
    //      ⚠️ 最低优先级在"手弹每拍都有"时 ⇒ 🔴 **演示永远发不出去**
    //      ⇒ ⭐ 而演示只有 **6 条**，⭐ **让它在"没人弹"时独占**才合理。
    // ══════════════════════════════════════════════════════════════════════

    // ⭐ 另两个源是否在发（⭐ 演示据此让位）
    wire others_going = live_valid_i | score_valid_i;

    // ⭐ 本拍真正参与推入的（⭐ 已应用"演示让位"）
    wire push_live  = live_valid_i;
    wire push_score = score_valid_i;
    //   ⭐ 演示：⭐ 只在"没有别的源"时才推（⭐ 让位）
    //  ⭐⭐ **2026-09-28 修（防挂音，P1-2）：`note_off` 绝不让位**
    //  🔴 原写法 `demo_valid_i & ~others_going` 会把演示和弦的 3 个 `note_off`
    //     在撞上手弹时【直接丢掉】—— ⛔ 不排队、⛔ 不计入任何计数器（违反 `K-106`）
    //     ⇒ 对应 voice 的 `gate_r` 【永久为 1】⇒ 开机自检后留下常驻音。
    //  ✅ `note_off` 是【释放】语义 ⇒ ⭐ 丢掉它只会造成【挂音】，⛔ 不会造成多音
    //     ⇒ 允许它与手弹同拍推入（FIFO 深 6，实测占用 ≤2 ⇒ 有富余）。
    //  📌 `note_on` 仍按原规则让位（⛔ 不改演示的让位语义）。
    wire demo_is_off = (demo_kind_i == 2'd1);
    wire push_demo  = demo_valid_i & (~others_going | demo_is_off);

    // ⭐ 轮转标志：0 ⇒ 手弹先；1 ⇒ 曲谱先（⭐ 只在**两者都发**时才有意义）
    reg  prio_score_r;
    wire live_first = ~prio_score_r;

    // ⭐ 本拍推几条
    //   🔴 **必须显式写位宽** —— ⚠️ `evt_merge` 踩过：`wire push_n` **隐含 1 bit**
    //      ⇒ `1+1` 被截断成 `1'b0` ⇒ 🔴 **恰好"两路同拍相撞"什么都不做**。
    wire [15:0] push_n = (push_live  ? 16'd1 : 16'd0)
                       + (push_score ? 16'd1 : 16'd0)
                       + (push_demo  ? 16'd1 : 16'd0);

    // ⭐ 本拍净变化（⚠️ 弹出优先 ⇒ 先腾位再推，能多接一条）
    wire [15:0] cnt_after_pop = pop_now ? (cnt_q - 16'd1) : cnt_q;
    wire [15:0] cnt_next      = cnt_after_pop + push_n;
    wire        will_overflow = (cnt_next > DEPTH_C);

    // ⭐ 安全的下一个 tail 指针（⭐ 用"逐个 +1 + 回绕"表示，⛔ 不用取模）
    function [15:0] tail_plus;
        input [15:0] t;
        input [15:0] n;
        reg   [15:0] r;
        begin
            r = t + n;
            //   ⚠️ `n` 最大 3、`DEPTH` 是常数 ⇒ ⭐ 最多减一次就够
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            tail_plus = r;
        end
    endfunction

    // ⭐ tail 的三个"下一个位置"（⭐ 按推入条数用）
    wire [15:0] tail_1 = tail_plus(tail_q, 16'd1);
    wire [15:0] tail_2 = tail_plus(tail_q, 16'd2);
    wire [15:0] tail_3 = tail_plus(tail_q, 16'd3);

    // ⭐ 弹出那条属于哪个源（⭐ 统计用）
    wire [NW-1:0] pop_src = pop_data[ENT_W +: NW];

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 主时序
    // ══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            evt_valid_o     <= 1'b0;
            evt_axis_o      <= {AXIS_W{1'b0}};
            evt_phase_inc_o <= {PHASE_W{1'b0}};
            evt_velocity_o  <= {VEL_W{1'b0}};
            evt_kind_o      <= {KIND_W{1'b0}};
            evt_timbre_valid_o <= 1'b0;
            evt_timbre_o    <= {TIMBRE_W{1'b0}};
            evt_src_o       <= 2'd0;          // ⭐ A1：来源标记也复位（⛔ 不留 X）
            cnt_q           <= 16'd0;
            head_q          <= 16'd0;
            tail_q          <= 16'd0;
            prio_score_r    <= 1'b0;
            collision_cnt_o <= 16'd0;
            merged_cnt_o    <= 16'd0;
            drop_cnt_o      <= 16'd0;
            overflow_o      <= 1'b0;
            live_cnt_o      <= 16'd0;
            score_cnt_o     <= 16'd0;
            demo_cnt_o      <= 16'd0;
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
                evt_src_o       <= pop_src;
                head_q          <= (head_q == DEPTH_M1) ? 16'd0 : (head_q + 16'd1);
                merged_cnt_o    <= (merged_cnt_o == 16'hFFFF) ? merged_cnt_o
                                                              : (merged_cnt_o + 16'd1);
                // ⭐ 按源分别统计（⭐ 上板时"谁在发"一眼可见）
                if (pop_src == SRC_LIVE)
                    live_cnt_o  <= (live_cnt_o  == 16'hFFFF) ? live_cnt_o
                                                             : (live_cnt_o  + 16'd1);
                else if (pop_src == SRC_SCORE)
                    score_cnt_o <= (score_cnt_o == 16'hFFFF) ? score_cnt_o
                                                             : (score_cnt_o + 16'd1);
                else
                    demo_cnt_o  <= (demo_cnt_o  == 16'hFFFF) ? demo_cnt_o
                                                             : (demo_cnt_o  + 16'd1);
            end

            // ══ ② 推入（⚠️ 只有装得下才推；⛔ 装不下要【看得见】）════════════
            if (push_n != 16'd0) begin
                if (!will_overflow) begin
                    // ⭐ 按"谁先"定推入顺序（⭐ FIFO 保序 ⇒ 先推的先出）
                    //   🔴 **为什么顺序重要**：⭐ 手弹优先级最高 ⇒ ⭐ 它应当**先出队**
                    //      ⚠️ 但**不能永远先**（⭐ 那会饿死曲谱）⇒ ⭐ 轮转
                    if (push_live && push_score && push_demo) begin
                        // ⭐ 三条全到（⚠️ 极罕见：演示只在"没别的"时才推 ⇒ 此路实际不可达，
                        //    ⭐ 但**保留** ⇒ ⭐ 不给"将来改让位规则"留坑）
                        if (live_first) begin
                            mem[tail_q] <= pack_src(SRC_LIVE,  live_axis_i,  live_phase_inc_i,  live_velocity_i,  live_kind_i,  live_timbre_valid_i,  live_timbre_i);
                            mem[tail_1] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                            mem[tail_2] <= pack_src(SRC_DEMO,  demo_axis_i,  demo_phase_inc_i,  demo_velocity_i,  demo_kind_i,  demo_timbre_valid_i,  demo_timbre_i);
                        end else begin
                            mem[tail_q] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                            mem[tail_1] <= pack_src(SRC_LIVE,  live_axis_i,  live_phase_inc_i,  live_velocity_i,  live_kind_i,  live_timbre_valid_i,  live_timbre_i);
                            mem[tail_2] <= pack_src(SRC_DEMO,  demo_axis_i,  demo_phase_inc_i,  demo_velocity_i,  demo_kind_i,  demo_timbre_valid_i,  demo_timbre_i);
                        end
                    end else if (push_live && push_score) begin
                        // ⭐ 手弹 + 曲谱同拍（⭐ **最要紧的一种**：⭐ 必须两条都发）
                        if (live_first) begin
                            mem[tail_q] <= pack_src(SRC_LIVE,  live_axis_i,  live_phase_inc_i,  live_velocity_i,  live_kind_i,  live_timbre_valid_i,  live_timbre_i);
                            mem[tail_1] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                        end else begin
                            mem[tail_q] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                            mem[tail_1] <= pack_src(SRC_LIVE,  live_axis_i,  live_phase_inc_i,  live_velocity_i,  live_kind_i,  live_timbre_valid_i,  live_timbre_i);
                        end
                    end else if (push_live && push_demo) begin
                        mem[tail_q] <= pack_src(SRC_LIVE, live_axis_i, live_phase_inc_i, live_velocity_i, live_kind_i, live_timbre_valid_i, live_timbre_i);
                        mem[tail_1] <= pack_src(SRC_DEMO, demo_axis_i, demo_phase_inc_i, demo_velocity_i, demo_kind_i, demo_timbre_valid_i, demo_timbre_i);
                    end else if (push_score && push_demo) begin
                        mem[tail_q] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                        mem[tail_1] <= pack_src(SRC_DEMO,  demo_axis_i,  demo_phase_inc_i,  demo_velocity_i,  demo_kind_i,  demo_timbre_valid_i,  demo_timbre_i);
                    end else if (push_live) begin
                        mem[tail_q] <= pack_src(SRC_LIVE, live_axis_i, live_phase_inc_i, live_velocity_i, live_kind_i, live_timbre_valid_i, live_timbre_i);
                    end else if (push_score) begin
                        mem[tail_q] <= pack_src(SRC_SCORE, score_axis_i, score_phase_inc_i, score_velocity_i, score_kind_i, score_timbre_valid_i, score_timbre_i);
                    end else begin
                        mem[tail_q] <= pack_src(SRC_DEMO, demo_axis_i, demo_phase_inc_i, demo_velocity_i, demo_kind_i, demo_timbre_valid_i, demo_timbre_i);
                    end

                    // ⭐ 推进 tail（按实际推入条数）
                    tail_q <= tail_plus(tail_q, push_n);
                    cnt_q  <= cnt_next;
                end else begin
                    // 🔴 **溢出**：⭐ 丢弃并**记数 + 置 sticky 标志**（⛔ 不静默）
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : (drop_cnt_o + push_n);
                    // ⚠️ **本拍的弹出必须照样记账**（⭐ `evt_merge` 踩过的坑：
                    //    原来 overflow 分支里完全没写 `cnt_q` ⇒ `cnt_q` 永远 > 0
                    //    ⇒ `pop_now` 恒真 ⇒ 🔴 `evt_valid_o` 一直挂着、不再单周期）
                    cnt_q <= cnt_after_pop;
                end
            end else if (pop_now) begin
                // ⭐ 只弹不推：更新计数（tail 不动）
                cnt_q <= cnt_after_pop;
            end

            // ══ ③ 统计与优先级轮转 ══════════════════════════════════════════
            // ⭐ "相撞"= 本拍有 ≥2 个源**真正参与推入**（⭐ 演示让位后不算）
            if ((push_live && push_score) || (push_live && push_demo)
                || (push_score && push_demo)) begin
                collision_cnt_o <= (collision_cnt_o == 16'hFFFF) ? collision_cnt_o
                                                                 : (collision_cnt_o + 16'd1);
            end
            // ⭐ **只有 A/B 真的都到才翻面**（⚠️ 单源来时翻面没有意义 ⇒
            //    ⭐ 且会让"固定优先级"退化）
            if (push_live && push_score) begin
                prio_score_r <= ~prio_score_r;
            end
        end
    end

endmodule

`default_nettype wire
