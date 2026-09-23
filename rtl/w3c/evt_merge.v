`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// evt_merge.v · 事件合流（手弹/曲谱 + 节拍器/鼓机 → note_manager 的唯一事件口）
//   —— W3c（`T36` / `U-6`）
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
//      · 每拍**最多推入 2 条**（A、B 各一条）、**弹出 1 条**
//      · ⭐ **弹出优先于推入**（先腾位置），`cnt_next = cnt + push - pop`
//      · ⚠️ 队列空时**不弹**（避免吐出垃圾）⇒ 代价是**首次入队晚 1 拍**（20 ns）
//
// ── ⭐⭐ 关于"能不能保证【永不】丢"（⚠️ 诚实的边界）──────────────────────────
//   ⚠️ **2 个源各以 1 条/拍持续输入 = 2 条/拍，而出口只有 1 条/拍** ⇒
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

module evt_merge #(
    parameter integer AXIS_W  = 4,
    parameter integer PHASE_W = 32,
    parameter integer VEL_W   = 8,
    parameter integer KIND_W  = 2,
    // ⭐ FIFO 深度。⚠️ 必须 ≥ 2（⚠️ 否则"待发 1 条 + 同拍来 2 条"就装不下 —— 那正是第一版的 bug）
    parameter integer DEPTH   = 4
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── 源 A：手弹 / 曲谱（`play_seq` 的输出，或 live 事件）────────────────
    input  wire                  a_valid_i,
    input  wire [AXIS_W-1:0]     a_axis_i,
    input  wire [PHASE_W-1:0]    a_phase_inc_i,
    input  wire [VEL_W-1:0]      a_velocity_i,
    input  wire [KIND_W-1:0]     a_kind_i,

    // ── 源 B：节拍器 / 鼓机 ────────────────────────────────────────────────
    input  wire                  b_valid_i,
    input  wire [AXIS_W-1:0]     b_axis_i,
    input  wire [PHASE_W-1:0]    b_phase_inc_i,
    input  wire [VEL_W-1:0]      b_velocity_i,
    input  wire [KIND_W-1:0]     b_kind_i,

    // ── 合流后的唯一事件口（→ `note_manager`）─────────────────────────────
    output reg                   evt_valid_o,
    output reg  [AXIS_W-1:0]     evt_axis_o,
    output reg  [PHASE_W-1:0]    evt_phase_inc_o,
    output reg  [VEL_W-1:0]      evt_velocity_o,
    output reg  [KIND_W-1:0]     evt_kind_o,

    // ── ⭐ 可观测性（`K-106` 纪律：容量有限/会失效的东西必须能看见）──────────
    output reg  [15:0]           collision_cnt_o,  // ⭐ 同拍相撞次数（饱和）
    output reg  [15:0]           merged_cnt_o,     // ⭐ 已合流发出的事件数（饱和）
    output reg  [15:0]           drop_cnt_o,       // ⭐ 因溢出丢弃的条数（饱和）
    output reg                   overflow_o        // ⭐⚠️ **溢出**（sticky，复位清）
);

    // ── ⭐ 打包成一条记录（⚠️ 用一个向量，FIFO 索引就简单了）──────────────────
    localparam integer ENT_W = AXIS_W + PHASE_W + VEL_W + KIND_W;
    localparam integer AX_O  = PHASE_W + VEL_W + KIND_W;
    localparam integer IN_O  = VEL_W + KIND_W;
    localparam integer VE_O  = KIND_W;

    // ⭐⭐ 把整数参数先落到**定宽 localparam** 再参与运算
    //   🔴 **`K-91`：⛔ 绝不对 `integer` 参数做位选**（`DEPTH[15:0]` 这种）。
    //      ⚠️ 本模块第一版就写了 `DEPTH[15:0]` ⇒ 🔴 **索引比较全部失效**
    //      ⇒ 现象：`collision_cnt_o` **正常计数**（那条路径不碰 DEPTH），
    //        但 **数据推不进队列、`cnt_q` 不动** ⇒ ⚠️ 看起来像"事件根本没进来"。
    //      ⭐ 教训：**这条规则不是形式主义** —— 它会让一整块逻辑静默失效。
    localparam [15:0] DEPTH_C  = DEPTH;
    localparam [15:0] DEPTH_M1 = DEPTH_C - 16'd1;

    function [ENT_W-1:0] pack_evt;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        input [KIND_W-1:0]  kd;
        begin
            pack_evt = {ax, inc, vl, kd};
        end
    endfunction

    // ── ⭐ FIFO 存储与指针 ─────────────────────────────────────────────────
    //   ⚠️ 用**环形缓冲**（⛔ 不是移位寄存器）：推入/弹出各只动一个指针，
    //      ⛔ 不搬数据 ⇒ 面积小、时序好（⚠️ 本项目 Fmax 余量薄）。
    reg [ENT_W-1:0] mem [0:DEPTH-1];
    reg [15:0]      cnt_q;
    reg [15:0]      head_q;      // ⭐ 弹出位置
    reg [15:0]      tail_q;      // ⭐ 推入位置

    // ⭐ 轮转标志：0 ⇒ A 先；1 ⇒ B 先
    reg prio_b_r;

    // ── ⭐ 组合：本拍能不能弹 ───────────────────────────────────────────────
    wire          pop_now = (cnt_q != 16'd0);        // ⭐ 空队列不弹（⛔ 不吐垃圾）
    wire [ENT_W-1:0] pop_data = mem[head_q];

    // ── ⭐ 组合：本拍推几条（⭐ 冲突时按 prio_b_r 定【谁先】）────────────────
    //   ⚠️ 两条都要推时，**顺序**要定下来（FIFO 是保序的，先推的先出）
    wire push_a_first = ~prio_b_r;
    wire push_a = a_valid_i;
    wire push_b = b_valid_i;
    // 🔴🔴 **必须显式写位宽** —— 这是本模块最隐蔽的一个 bug（2026-09-22 实测踩到）：
    //    `wire push_n = ...` **不写位宽 ⇒ 隐含 1 bit**！
    //    ⭐ 于是 `1 + 1 = 2` 被**截断成 `1'b0`** ⇒ 🔴 **"两路同拍相撞"这一种情况
    //       恰好把计数算成 0** ⇒ ⛔ 什么都不推进队 ⇒ ⚠️ 而**单路来时 `1` 是对的**。
    //    ⇒ ⭐ 现象极具欺骗性：**单源正常、一相撞就"什么都没发生"**
    //       （⚠️ `collision_cnt_o` 还照常计数，因为那条路径不经过 `push_n`）
    //       ⇒ 看起来像"相撞被吞了"，⛔ 其实是**位宽截断**。
    //    📌 **教训**：⛔ 别依赖隐式位宽 —— ⭐ `wire` 不写宽度就是 1 位。
    wire [15:0] push_n = (push_a ? 16'd1 : 16'd0) + (push_b ? 16'd1 : 16'd0);

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
                evt_kind_o      <= pop_data[0 +: KIND_W];
                head_q          <= (head_q + 16'd1 == DEPTH_C) ? 16'd0
                                                                   : head_q + 16'd1;
                merged_cnt_o    <= (merged_cnt_o == 16'hFFFF) ? merged_cnt_o
                                                             : merged_cnt_o + 16'd1;
            end

            // ══ ② 推入（⚠️ 只有装得下才推；⛔ 装不下要【看得见】）════════════
            //   ⚠️ 索引用"本拍 tail + 偏移"，⭐ 两条同时推时偏移 0/1
            if (push_n != 16'd0) begin
                if (!will_overflow) begin
                    // ⭐ 顺序由 prio_b_r 决定：先推的那条先出（FIFO 保序）
                    if (push_a && push_b) begin
                        if (push_a_first) begin
                            mem[tail_q] <= pack_evt(a_axis_i, a_phase_inc_i,
                                                    a_velocity_i, a_kind_i);
                            mem[(tail_q + 16'd1 == DEPTH_C) ? 16'd0
                                                                : tail_q + 16'd1]
                                <= pack_evt(b_axis_i, b_phase_inc_i,
                                            b_velocity_i, b_kind_i);
                        end else begin
                            mem[tail_q] <= pack_evt(b_axis_i, b_phase_inc_i,
                                                    b_velocity_i, b_kind_i);
                            mem[(tail_q + 16'd1 == DEPTH_C) ? 16'd0
                                                                : tail_q + 16'd1]
                                <= pack_evt(a_axis_i, a_phase_inc_i,
                                            a_velocity_i, a_kind_i);
                        end
                    end else if (push_a) begin
                        mem[tail_q] <= pack_evt(a_axis_i, a_phase_inc_i,
                                                a_velocity_i, a_kind_i);
                    end else begin
                        mem[tail_q] <= pack_evt(b_axis_i, b_phase_inc_i,
                                                b_velocity_i, b_kind_i);
                    end

                    // ⭐ 推进 tail（按实际推入条数）
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
            if (a_valid_i && b_valid_i) begin
                collision_cnt_o <= (collision_cnt_o == 16'hFFFF) ? collision_cnt_o
                                                                 : collision_cnt_o + 16'd1;
            end
            // ⭐ 只有**真的在两条之间做过取舍**才翻面（⚠️ 单条来时翻面没有意义）
            if (a_valid_i && b_valid_i) begin
                prio_b_r <= ~prio_b_r;
            end
        end
    end

endmodule

`default_nettype wire
