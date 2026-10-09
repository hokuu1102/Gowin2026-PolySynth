`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_evt_merge.sv · `evt_merge` 验收（`T36` / `U-6`）
//
// ⭐ 核心判据（⭐ 这条就是它存在的全部理由）：
//   ① ⭐⭐ **两路同拍相撞 ⇒ 两个都进 note_manager**（⛔ 一个都不许丢）
//      —— 这是"真缺陷"的判据。⚠️ `top.v` 原来的 `a | b` 写法会丢一个。
//   ② ⭐ **轮转**：连续相撞时两个源轮流先出（⛔ 不饿死任一方）
//   ③ ⭐ **单周期脉冲**（⛔ 拉宽会让 note_manager 重复触发）
//   ④ ⭐ **空队列不吐**（⛔ 不许产生"垃圾事件"）
//   ⑤ ⭐ **溢出必须可见**（`overflow_o` + `drop_cnt_o`；⛔ 不静默，`K-106`）
//   ⑥ ⭐ **A8**：无 X/Z 传播
//   ⑦ ⭐⭐ **三路同拍相撞 ⇒ 三条都到，且各带自己的源标签**
//      （⭐ 2026-09-30 新增：⭐ `evt_merge` 多了**第三个输入**（looper 回放），
//        ⭐ 判据 ⑦ 专门守"**C 不被悄悄吞掉 / 不串源**"）✅
//
// ⭐ 原则（`K-56`/`C21`）：**每条判据都必须能失败**；⭐ 写成【不变量】（`C44`）
//
// 🔴 **本文件记三个踩过的坑**（⚠️ 都很隐蔽，值得记住）：
//   (a) ⭐ **观测寄存器输出，采样点必须在时钟沿【之后】**
//       —— `evt_valid_o` 在沿上被赋 1，值要到沿后才可见；
//          在沿上直接读会读到**上一拍的 0** ⇒ 🔴 "一条都记不下来"，
//          ⚠️ 而现象看起来像 **DUT 没输出**（⭐ 实测 DUT 内部 `cnt=1`、数据正确）。
//       ⇒ ⭐ 采集器用 `@(posedge clk); #1;` 再读。
//   (b) ⭐ **驱动激励要在沿【之前】设好，采完再撤**
//       —— `@(posedge clk)` **之后立刻**清零会与 DUT 的采样瞬间**竞争**
//          ⇒ DUT 永远看不到 valid ⇒ 🔴 同样是"一条都没进来"的假象。
//       ⇒ ⭐ 用 `@(negedge clk)` 设值 / 撤值，把沿留干净。
//   (c) ⚠️ **Verilog 的 `integer` 初值是 `x`，⛔ 不是 0**
//       —— 计数器不显式初始化 ⇒ `if (n < MAX)` 恒假 ⇒ 一条都记不下来。
// ─────────────────────────────────────────────────────────────────────────────

module tb_evt_merge;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer KIND_W  = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer DEPTH   = 4;
    localparam integer MAXEV   = 64;

    integer errors = 0;

    // ⭐⭐ 2026-10-02（阶段 1 减宽）：独立的【非默认 DEPTH】用例（照 A1 的 `seq_arb_depth9_case` 模板）
    //   ① 位宽契约（旧 RTL 必红）② 软件参考队列逐拍比全部输出 + 内部状态 ③ 覆盖率计数器非零
    wire        depth9_done;
    wire [31:0] depth9_errors;
    evt_merge_depth9_case u_depth9 (.done(depth9_done), .errors(depth9_errors));

    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst_n = 1'b0;

    // ── 源 A ──────────────────────────────────────────────────────────────
    reg                a_valid = 1'b0;
    reg  [AXIS_W-1:0]  a_axis  = 4'd0;
    reg  [PHASE_W-1:0] a_inc   = 32'd0;
    reg  [VEL_W-1:0]   a_vel   = 8'd0;
    reg  [KIND_W-1:0]  a_kind  = 2'd0;
    reg                a_tv    = 1'b0;
    reg  [TIMBRE_W-1:0] a_tb   = 2'd0;

    // ── 源 B ──────────────────────────────────────────────────────────────
    reg                b_valid = 1'b0;
    reg  [AXIS_W-1:0]  b_axis  = 4'd0;
    reg  [PHASE_W-1:0] b_inc   = 32'd0;
    reg  [VEL_W-1:0]   b_vel   = 8'd0;
    reg  [KIND_W-1:0]  b_kind  = 2'd0;
    reg                b_tv    = 1'b0;
    reg  [TIMBRE_W-1:0] b_tb   = 2'd0;

    // ── ⭐⭐ 源 C（looper 回放）—— ⭐ 2026-09-30 新增 ──────────────────────
    //   ⭐ 本 tb 原来只有 A/B 两路 ⇒ ⭐ 现在补上第三路，
    //      判据 ⑦ 专门验"**三路同拍相撞⛔ 一条都不许丢**"（⭐ 新增口的核心风险）✅
    reg                c_valid = 1'b0;
    reg  [AXIS_W-1:0]  c_axis  = 4'd0;
    reg  [PHASE_W-1:0] c_inc   = 32'd0;
    reg  [VEL_W-1:0]   c_vel   = 8'd0;
    reg  [KIND_W-1:0]  c_kind  = 2'd0;
    reg                c_tv    = 1'b0;
    reg  [TIMBRE_W-1:0] c_tb   = 2'd0;

    // ── 合流输出 ──────────────────────────────────────────────────────────
    wire               m_valid;
    wire [AXIS_W-1:0]  m_axis;
    wire [PHASE_W-1:0] m_inc;
    wire [VEL_W-1:0]   m_vel;
    wire [KIND_W-1:0]  m_kind;
    wire               m_tv;
    wire [TIMBRE_W-1:0] m_tb;
    // ⭐⭐ 2026-09-30：⭐ 合流后的来源标记（⭐ 判据 ⑦ 用）
    wire [2:0]         m_src;
    wire [15:0]        collision_cnt, merged_cnt, drop_cnt;
    wire               overflow;

    evt_merge #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(DEPTH)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(a_valid), .a_axis_i(a_axis), .a_phase_inc_i(a_inc),
        .a_velocity_i(a_vel), .a_kind_i(a_kind),
        .a_timbre_valid_i(a_tv), .a_timbre_i(a_tb),
        // ⭐ A1：来源标记（⭐ 本 tb 不验它 —— 它由 `tb_note_manager` 的判据覆盖）
        //    ⚠️ 必须给**确定值**：留空 ⇒ `z` ⇒ 存进 FIFO 的是 `z`（⛔ 不是 0）
        // ⭐⭐ 2026-09-30：⭐ 位宽 2 → 3（⭐ 编码见 `seq_arb.evt_src_o`）
        .a_src_i(3'd0),
        .b_valid_i(b_valid), .b_axis_i(b_axis), .b_phase_inc_i(b_inc),
        .b_velocity_i(b_vel), .b_kind_i(b_kind),
        .b_timbre_valid_i(b_tv), .b_timbre_i(b_tb),
        .b_src_i(3'd3),
        // ⭐⭐ 源 C（looper 回放）—— ⭐ 2026-09-30 新增 ✅
        .c_valid_i(c_valid), .c_axis_i(c_axis), .c_phase_inc_i(c_inc),
        .c_velocity_i(c_vel), .c_kind_i(c_kind),
        .c_timbre_valid_i(c_tv), .c_timbre_i(c_tb),
        .c_src_i(3'd4),        // ⭐ looper 的专用标签
        .evt_valid_o(m_valid), .evt_axis_o(m_axis), .evt_phase_inc_o(m_inc),
        .evt_velocity_o(m_vel), .evt_kind_o(m_kind),
        .evt_timbre_valid_o(m_tv), .evt_timbre_o(m_tb),
        // ⭐⭐ 2026-09-30：⭐ **来源标记也要观测** —— 判据 ⑦ 要验
        //    "**三路各自带的是不是自己的标签**"（⭐ 串源 = 下游会误清 voice）✅
        .evt_src_o(m_src),
        .collision_cnt_o(collision_cnt), .merged_cnt_o(merged_cnt),
        .drop_cnt_o(drop_cnt), .overflow_o(overflow)
    );

    // ── A8：X/Z 监视 ───────────────────────────────────────────────────────
    wire [63:0] a8_bundle = {m_axis, m_inc, m_vel, m_kind, merged_cnt, drop_cnt};
    wire [31:0] a8_err;
    chk_xprop #(.W(64), .NAME("evt_merge_bundle")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig(a8_bundle), .err_cnt(a8_err)
    );

    // ── ⭐ 采集器（⚠️ 沿之后才采，见文件头坑 (a)）────────────────────────────
    reg [AXIS_W-1:0]  got_axis [0:MAXEV-1];
    reg [PHASE_W-1:0] got_inc  [0:MAXEV-1];
    // ⭐⭐ 2026-09-30：⭐ **同时记下来源标记**（⭐ 判据 ⑦：⭐ 三路各自的标签不许串）
    reg [2:0]         got_src  [0:MAXEV-1];
    // ⚠️ 必须显式初始化（见坑 (c)）
    integer n_got = 0;

    // SAMPLE ON NEGEDGE, not "posedge + #1".
    //   A second always-block that also drives stimulus on posedge would
    //   race with this one (one resumes immediately, one 1ns later), so the
    //   value can already be gone -> the collector silently records nothing
    //   and it LOOKS like the DUT never emitted.
    //   At negedge the registered output from the previous posedge is stable
    //   and nothing else is driving.
    always @(negedge clk) begin
        if (rst_n && m_valid) begin
            if (n_got < MAXEV) begin
                got_axis[n_got] = m_axis;
                got_inc [n_got] = m_inc;
                got_src [n_got] = m_src;
                n_got = n_got + 1;
            end
        end
    end

    // ── ⭐ 单周期监视：连续两拍都有效 = 违约 ───────────────────────────────
    reg m_valid_d = 1'b0;
    always @(posedge clk) m_valid_d <= (rst_n ? m_valid : 1'b0);

    // ── 临时量（⚠️ Verilog-2001：具名 begin/end 块**不是**声明作用域）────────
    integer n_seen, n_before, n_expect, k, first_a, first_b, viol, j, n_src_ok;

    task idle_cycles;
        input integer n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/sim/evt_merge/tb_evt_merge.vcd");
        $dumpvars(0, tb_evt_merge);

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ══ 判据 ④：空队列不吐垃圾（⭐ 反证基线）══════════════════════════
        n_seen = 0;
        idle_cycles(20);
        if (n_got != 0) n_seen = 1;
        if (n_seen) begin
            $display("FAIL: emitted %0d event(s) with an EMPTY queue (garbage)", n_got);
            errors = errors + 1;
        end else
            $display("  ok  : empty queue emits nothing (no garbage)");

        // ══ 判据 ①：⭐⭐ 两路同拍相撞 ⇒ 两个都到（⛔ 不丢）══════════════════
        // ⚠️ 本条判据曾因**DUT 的一个位宽 bug** 一直失败：
        //    `wire push_n = ...` 没写位宽 ⇒ 隐含 1 bit ⇒ `1+1=2` 截断成 0
        //    ⇒ ⭐ **只有"两路同拍"这一种情况**被吞，单路完全正常。
        //    ⇒ ⭐ 所以这条判据【必须真的存在】—— 别的判据都抓不到它。
        n_before = n_got;
        @(negedge clk);
        a_axis = 4'd1; a_inc = 32'd1111; a_vel = 8'd100; a_kind = 2'd0; a_valid = 1'b1;
        b_axis = 4'd2; b_inc = 32'd2222; b_vel = 8'd200; b_kind = 2'd0; b_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        a_valid = 1'b0; b_valid = 1'b0;
        idle_cycles(10);

        n_expect = n_before + 2;
        if (n_got != n_expect) begin
            $display("FAIL: collision LOST an event -- got %0d, expected %0d (THIS IS THE WHOLE POINT)",
                     n_got, n_expect);
            errors = errors + 1;
        end else
            $display("  ok  : BOTH events survived a same-cycle collision (%0d -> %0d)",
                     n_before, n_got);

        if (n_got >= 2) begin
            if (got_axis[n_got-2] !== 4'd1 || got_axis[n_got-1] !== 4'd2) begin
                $display("FAIL: collision payload wrong -- got axis %0d,%0d expected 1,2",
                         got_axis[n_got-2], got_axis[n_got-1]);
                errors = errors + 1;
            end else
                $display("  ok  : collision payloads intact (axis 1 then 2)");
        end

        if (collision_cnt === 16'd0) begin
            $display("FAIL: collision_cnt_o did not count the collision");
            errors = errors + 1;
        end else
            $display("  ok  : collision_cnt_o = %0d (observed)", collision_cnt);

        // ══ 判据 ②：轮转 —— 连续相撞应轮流先出 ═════════════════════════════
        first_a = 0; first_b = 0;
        for (k = 0; k < 4; k = k + 1) begin
            n_got = 0;
            @(negedge clk);
            a_axis = 4'd3; a_inc = 32'd3333; a_valid = 1'b1;
            b_axis = 4'd4; b_inc = 32'd4444; b_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            a_valid = 1'b0; b_valid = 1'b0;
            idle_cycles(10);
            if (n_got >= 2) begin
                if (got_axis[0] == 4'd3) first_a = first_a + 1;
                if (got_axis[0] == 4'd4) first_b = first_b + 1;
            end
        end
        n_got = 0;
        if (first_a == 0 || first_b == 0) begin
            $display("FAIL: no rotation -- first-served always the same source (a=%0d b=%0d)",
                     first_a, first_b);
            errors = errors + 1;
        end else
            $display("  ok  : round-robin rotates (A first %0d, B first %0d)", first_a, first_b);

        // ══ 判据 ③：单周期脉冲（⛔ 连续两拍有效 = 违约）════════════════════
        viol = 0;
        for (j = 0; j < 20; j = j + 1) begin
            @(negedge clk);
            a_axis = 4'd5; a_inc = j; a_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            a_valid = 1'b0;
            if (m_valid && m_valid_d) viol = viol + 1;
            @(posedge clk);
            if (m_valid && m_valid_d) viol = viol + 1;
        end
        if (viol != 0) begin
            $display("FAIL: evt_valid_o stayed high across %0d cycle boundary(ies)", viol);
            errors = errors + 1;
        end else
            $display("  ok  : evt_valid_o is strictly single-cycle");

        // ══ 判据 ⑤：溢出必须可见（⭐ 2 条/拍持续灌，出口只有 1 条/拍）══════
        idle_cycles(20);                      // ⭐ 先排空
        for (k = 0; k < 30; k = k + 1) begin
            @(negedge clk);
            a_axis = 4'd6; a_inc = k; a_valid = 1'b1;
            b_axis = 4'd7; b_inc = k; b_valid = 1'b1;
            @(posedge clk);
        end
        @(negedge clk);
        a_valid = 1'b0; b_valid = 1'b0;
        idle_cycles(5);

        if (!overflow) begin
            $display("FAIL: forced 2-per-cycle overload did NOT raise overflow_o (silent loss)");
            errors = errors + 1;
        end else
            $display("  ok  : overflow_o raised under sustained overload (drop_cnt=%0d)", drop_cnt);
        if (overflow && drop_cnt === 16'd0) begin
            $display("FAIL: overflow_o set but drop_cnt_o is 0 -- inconsistent");
            errors = errors + 1;
        end

        // ══ 判据 ⑦：⭐⭐ 三路同拍相撞 ⇒ 三条都到（⭐ 2026-09-30 新增源 C）══════
        //   🔴 **为什么这条判据必须存在**：⭐ 加了第三个输入之后，
        //      ⚠️ 最危险的退化是"**只处理 A/B，C 被悄悄吞掉**" ——
        //      🔴 而它**不会报错**：⭐ 现象只是"looper 回放偶尔少一个音"
        //         （⭐ `K-87` 家族：⭐ 路径能错却不可见）✅
        //   ⭐ 判据分两半（⭐ 缺任一半都不够）：
        //      ① ⭐ **条数**：⭐ 三条都要出来（⛔ 一条都不许丢）
        //      ② ⭐ **标签**：⭐ 每条带的是**自己的**源
        //         （🔴 串源 ⇒ 下游 `note_manager` 的 `note_off` 会**误清别人的 voice**）✅
        idle_cycles(20);                       // ⭐ 先排空（判据 ⑤ 灌了一堆）
        n_before = n_got;
        @(negedge clk);
        a_axis = 4'd8;  a_inc = 32'd800;  a_valid = 1'b1;
        b_axis = 4'd9;  b_inc = 32'd900;  b_valid = 1'b1;
        c_axis = 4'd10; c_inc = 32'd1000; c_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        a_valid = 1'b0; b_valid = 1'b0; c_valid = 1'b0;
        idle_cycles(10);

        n_expect = n_before + 3;
        if (n_got != n_expect) begin
            $display("FAIL: 3-way collision LOST event(s) -- got %0d, expected %0d (source C must not be dropped)",
                     n_got, n_expect);
            errors = errors + 1;
        end else
            $display("  ok  : all THREE sources survived a same-cycle collision (%0d -> %0d)",
                     n_before, n_got);

        n_src_ok = 0;
        for (k = n_before; k < n_got; k = k + 1) begin
            if (got_axis[k] === 4'd8  && got_src[k] === 3'd0) n_src_ok = n_src_ok + 1;
            if (got_axis[k] === 4'd9  && got_src[k] === 3'd3) n_src_ok = n_src_ok + 1;
            if (got_axis[k] === 4'd10 && got_src[k] === 3'd4) n_src_ok = n_src_ok + 1;
        end
        if (n_src_ok != 3) begin
            $display("FAIL: 3-way collision payload/source-tag mismatch (matched %0d of 3)",
                     n_src_ok);
            errors = errors + 1;
        end else
            $display("  ok  : each of the three keeps its OWN source tag (A=0 B=3 C=4)");

        // ══ A8 ════════════════════════════════════════════════════════════
        if (a8_err != 0) begin
            $display("FAIL: A8 X/Z propagation (%0d)", a8_err);
            errors = errors + 1;
        end else
            $display("  ok  : A8 no X/Z on evt_merge outputs");

        // ⭐⭐ 2026-10-02（阶段 1 减宽）：等独立的【非默认 DEPTH】用例跑完再下结论
        wait (depth9_done);
        if (depth9_errors != 0) begin
            $display("FAIL: DEPTH9 位宽契约/软件参考模型比出 %0d 处错误", depth9_errors);
            errors = errors + depth9_errors;
        end

        if (errors == 0)
            $display("PASS: evt_merge never drops a same-cycle collision, is single-cycle, rotates, and reports overflow");
        else
            $display("FAIL: evt_merge had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`）
    initial begin
        #200_000_000;
        $fatal(1, "FAIL: tb_evt_merge timeout");
    end

endmodule

// ═════════════════════════════════════════════════════════════════════════════
// ⭐⭐ 2026-10-02（阶段 1 减宽）：非默认 DEPTH 的独立用例
//   —— ⭐ 照 A1 的 `seq_arb_depth9_case` 模板（用户裁定：以后每一次都照这个来）
//   ① ⭐ **位宽契约**：旧 RTL（16 位寄存器）**必红**
//   ② ⭐ **软件参考队列**：每拍按 RTL 的优先级/回绕/溢出语义独立重算，比**全部输出 + 内部状态**
//   ③ ⭐ **覆盖率计数器**：`full/reject/triple/wraps` 末尾必须非零（⛔ 防"跑了但没覆盖"的假绿）
// ═════════════════════════════════════════════════════════════════════════════
module evt_merge_depth9_case(output reg done = 1'b0, output reg [31:0] errors = 32'd0);
    localparam integer D        = 9;      // ⭐ 非默认（模块默认 4、`top.v` 交付 6）
    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer KIND_W   = 2;
    localparam integer TIMBRE_W = 2;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg av = 0, bv = 0, cv = 0;
    reg [AXIS_W-1:0]   aax = 0, bax = 0, cax = 0;
    reg [PHASE_W-1:0]  ain = 0, bin = 0, cin = 0;
    reg [VEL_W-1:0]    ave = 0, bve = 0, cve = 0;
    reg [KIND_W-1:0]   akd = 0, bkd = 0, ckd = 0;
    reg atv = 0, btv = 0, ctv = 0;
    reg [TIMBRE_W-1:0] atb = 0, btb = 0, ctb = 0;

    wire               valid, ovf, tv;
    wire [AXIS_W-1:0]  ax;
    wire [PHASE_W-1:0] inc;
    wire [VEL_W-1:0]   vel;
    wire [KIND_W-1:0]  kd;
    wire [TIMBRE_W-1:0] tb;
    wire [2:0]         src;
    wire [15:0]        coll, merged, dropped;

    evt_merge #(.AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
                .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(D)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(av), .a_axis_i(aax), .a_phase_inc_i(ain), .a_velocity_i(ave),
        .a_kind_i(akd), .a_timbre_valid_i(atv), .a_timbre_i(atb), .a_src_i(3'd0),
        .b_valid_i(bv), .b_axis_i(bax), .b_phase_inc_i(bin), .b_velocity_i(bve),
        .b_kind_i(bkd), .b_timbre_valid_i(btv), .b_timbre_i(btb), .b_src_i(3'd3),
        .c_valid_i(cv), .c_axis_i(cax), .c_phase_inc_i(cin), .c_velocity_i(cve),
        .c_kind_i(ckd), .c_timbre_valid_i(ctv), .c_timbre_i(ctb), .c_src_i(3'd4),
        .evt_valid_o(valid), .evt_axis_o(ax), .evt_phase_inc_o(inc), .evt_velocity_o(vel),
        .evt_kind_o(kd), .evt_timbre_valid_o(tv), .evt_timbre_o(tb), .evt_src_o(src),
        .collision_cnt_o(coll), .merged_cnt_o(merged), .drop_cnt_o(dropped), .overflow_o(ovf)
    );

    // ── 软件参考模型（数据用【平移队列】= FIFO 顺序；head/tail 另按环形推进）──
    reg [51:0] q [0:D-1];                 // {src[2:0], axis[3:0], inc[31:0], vel[7:0], kind[1:0], tv, tb[1:0]}
    reg [51:0] popped = 52'd0;
    integer count = 0, head = 0, tail = 0, i, k, w;
    reg prio_b = 0, sticky = 0, exp_valid = 0;
    integer rc = 0, rm = 0, rd = 0;
    integer full_hits = 0, reject_hits = 0, triple_hits = 0, wraps = 0, checks = 0;
    integer n_push, off_a, off_b, off_c, cnt_after_pop;
    reg a_first;

    function [51:0] pack_evt(input [2:0] s, input [3:0] a, input [31:0] p,
                             input [7:0] v, input [1:0] kk, input t, input [1:0] tm);
        begin pack_evt = {s, a, p, v, kk, t, tm}; end
    endfunction

    always @(posedge clk) begin
        a_first = ~prio_b;                // ⭐ RTL：`push_a_first = ~prio_b_r`
        if (!rst_n) begin
            count = 0; head = 0; tail = 0; prio_b = 0; sticky = 0;
            rc = 0; rm = 0; rd = 0; popped = 52'd0; exp_valid = 0;
        end else begin
            // ① 弹出优先（先腾位置）
            if (count == D) full_hits = full_hits + 1;
            exp_valid = (count != 0);
            if (exp_valid) begin
                popped = q[0];
                for (k = 0; k < count-1; k = k + 1) q[k] = q[k+1];
                count = count - 1;
                head = (head + 1) % D;
                rm = rm + 1;
            end
            // ② 推入（⛔ 装不下就【全部】不推，但要记账）
            n_push = (av ? 1 : 0) + (bv ? 1 : 0) + (cv ? 1 : 0);
            if (n_push == 3) triple_hits = triple_hits + 1;
            if ((av && bv) || (av && cv) || (bv && cv)) rc = rc + 1;
            cnt_after_pop = count;
            if (n_push != 0) begin
                if (count + n_push > D) begin
                    //  ⭐⭐ 2026-10-09（`P0-16`）：⭐ **模型也必须饱和**（⭐ 与 RTL 同步）✅
                    //   🔴 原来 `rd = rd + n_push` **无饱和** ⇒ ⚠️ 灌到 65535 之后
                    //      ⭐ 模型继续数（`65537`）、而修好的 RTL 停在 `0xFFFF`
                    //      ⇒ 🔴 **判据会假红** ⇒ ⭐ 必须同步（⭐ 同 `oscillator_bank_ref` 纪律）✅
                    if (rd != 65535)
                        rd = (rd + n_push > 65535) ? 65535 : (rd + n_push);
                    sticky = 1; reject_hits = reject_hits + 1;
                    count = cnt_after_pop;              // ⭐ 弹出照样记账
                end else begin
                    off_a = bv ? (a_first ? 0 : 1) : 0;
                    off_b = av ? (a_first ? 1 : 0) : 0;
                    off_c = (av ? 1 : 0) + (bv ? 1 : 0);
                    // ⭐ 按【槽位顺序】入队（= FIFO 顺序）：A/B 先后由轮转定，C 固定最后
                    w = count;
                    if (av && bv) begin
                        if (a_first) begin q[w] = pack_evt(3'd0, aax, ain, ave, akd, atv, atb);
                                             q[w+1] = pack_evt(3'd3, bax, bin, bve, bkd, btv, btb); end
                        else         begin q[w] = pack_evt(3'd3, bax, bin, bve, bkd, btv, btb);
                                             q[w+1] = pack_evt(3'd0, aax, ain, ave, akd, atv, atb); end
                        w = w + 2;
                    end else if (av) begin
                        q[w] = pack_evt(3'd0, aax, ain, ave, akd, atv, atb); w = w + 1;
                    end else if (bv) begin
                        q[w] = pack_evt(3'd3, bax, bin, bve, bkd, btv, btb); w = w + 1;
                    end
                    if (cv) begin
                        q[w] = pack_evt(3'd4, cax, cin, cve, ckd, ctv, ctb); w = w + 1;
                    end
                    if (tail + n_push >= D) wraps = wraps + 1;
                    tail = (tail + n_push) % D;
                    count = count + n_push;
                end
            end
            if (av && bv) prio_b = ~prio_b;      // ⭐ 只有 A、B 都到才翻面
        end
        #1;                                      // 等 NBA 落定
        checks = checks + 1;
        if ({valid, src, ax, inc, vel, kd, tv, tb} !== {exp_valid, popped}) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("  FAIL DEPTH9 输出: got v=%b src=%0d ax=%0d inc=%0d vel=%0d kd=%0d tv=%b tb=%0d | exp v=%b",
                         valid, src, ax, inc, vel, kd, tv, tb, exp_valid);
        end
        if (coll !== rc || merged !== rm || dropped !== rd || ovf !== sticky) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("  FAIL DEPTH9 诊断: coll=%0d/%0d mer=%0d/%0d drop=%0d/%0d ovf=%b/%b",
                         coll, rc, merged, rm, dropped, rd, ovf, sticky);
        end
        if (dut.cnt_q !== count || dut.head_q !== head || dut.tail_q !== tail ||
            dut.prio_b_r !== prio_b) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("  FAIL DEPTH9 状态: cnt=%0d/%0d head=%0d/%0d tail=%0d/%0d prio=%b/%b",
                         dut.cnt_q, count, dut.head_q, head, dut.tail_q, tail, dut.prio_b_r, prio_b);
        end
    end

    initial begin
        #2;
        // ⭐ 位宽契约：⭐ **旧 RTL（16 位）在这一行必红** —— 这就是"判据能红"的证据
        if ($bits(dut.cnt_q) != $clog2(D+1) || $bits(dut.head_q) != $clog2(D) ||
            $bits(dut.tail_q) != $clog2(D) || $bits(dut.cnt_next) != $clog2(D+3) ||
            $bits(dut.push_n) != 2)
            $fatal(1, "FAIL: DEPTH9 位宽契约: cnt=%0d head=%0d tail=%0d cnt_next=%0d push_n=%0d（旧 RTL 必红）",
                   $bits(dut.cnt_q), $bits(dut.head_q), $bits(dut.tail_q),
                   $bits(dut.cnt_next), $bits(dut.push_n));
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (i = 0; i < 640; i = i + 1) begin
            @(negedge clk);
            // ⭐ 前 24 拍三源全来 ⇒ 灌满 + 溢出；之后伪随机，覆盖各种 1/2/3 路组合
            if (i < 24) begin av = 1; bv = 1; cv = 1; end
            else begin av = i[0]; bv = i[1]; cv = i[2]; end
            aax = i[3:0]; bax = 4'd9; cax = 4'd10;
            ain = i * 4; bin = i * 4 + 1; cin = i * 4 + 2;
            ave = i[7:0]; bve = 8'd200; cve = 8'd100;
            akd = i[1:0]; bkd = 2'd1; ckd = 2'd2;
            atv = i[0]; btv = 1'b0; ctv = 1'b1;
            atb = 2'd1; btb = 2'd2; ctb = 2'd3;
            if (i == 319) rst_n = 0;             // ⭐ 队列忙时复位
            if (i == 321) rst_n = 1;
        end
        @(negedge clk); av = 0; bv = 0; cv = 0;
        repeat (D+3) @(negedge clk);
        if (full_hits == 0 || reject_hits == 0 || triple_hits == 0 || wraps < 2 || count != 0)
            $fatal(1, "FAIL: DEPTH9 覆盖不足: full=%0d reject=%0d triple=%0d wraps=%0d count=%0d",
                   full_hits, reject_hits, triple_hits, wraps, count);
        if (errors != 0)
            $fatal(1, "FAIL: DEPTH9 软件参考模型比出 %0d 处不一致", errors);
        $display("  ok  : DEPTH9 位宽契约 + 软件参考模型逐拍一致（checks=%0d full=%0d reject=%0d triple=%0d wraps=%0d）",
                 checks, full_hits, reject_hits, triple_hits, wraps);
        //  ⭐⭐ 2026-10-09（`P0-16`）：⭐ **饱和判据** —— ⭐ 灌到【超过 16 位】为止 ✅
        //   🔴 **原缺陷**：⭐ `drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? ...`
        //      ⚠️ `drop_cnt_o`(16) `+` `push_n`(2) ⇒ ⭐ **和自定宽度 = 16 位**
        //      （IEEE 1364-2001 §5.1.1）⇒ 🔴 `x > 16'hFFFF` **恒为假** ⇒ ⭐ 饱和分支是死代码
        //      ⇒ 🔴 计数器**裸回绕**（⭐ 实测 `0xFFFF + 3 ⇒ 0x0002`）⇒ ⚠️ 上板诊断撒谎 ✅
        //   ⭐ **判据**：⭐ 三源齐发灌满队列 ⇒ 实测 `push_n` **均值 2/拍**（⭐ 有一路不是每拍都被收）
        //      ⇒ ⭐ 灌 **40000 拍 ≈ 80000 > 65535** 足够饱和
        //      ⇒ ⭐ `drop_cnt_o` **必须停在 `0xFFFF`**（🔴 未修复会回绕成小值）✅
        begin : sat_test
            integer k2;
            for (k2 = 0; k2 < 40000; k2 = k2 + 1) begin
                @(negedge clk);
                av = 1; bv = 1; cv = 1;
                aax = 4'd1; bax = 4'd9; cax = 4'd10;
                ain = 32'd1; bin = 32'd2; cin = 32'd3;
                ave = 8'd200; bve = 8'd200; cve = 8'd100;
                akd = 2'd0; bkd = 2'd1; ckd = 2'd2;
                atv = 1'b0; btv = 1'b0; ctv = 1'b0;
                atb = 2'd1; btb = 2'd2; ctb = 2'd3;
            end
            @(negedge clk); av = 0; bv = 0; cv = 0;
            repeat (4) @(negedge clk);
            if (dut.drop_cnt_o !== 16'hFFFF)
                $fatal(1, "FAIL: P0-16 饱和判据: drop_cnt_o=0x%04X（应为 0xFFFF）=> 计数器回绕了",
                       dut.drop_cnt_o);
            $display("  ok  : P0-16 饱和判据 drop_cnt_o=0x%04X（灌 40000 拍 x push_n 均值 2 > 65535）",
                     dut.drop_cnt_o);
        end
        done = 1;
    end
endmodule
