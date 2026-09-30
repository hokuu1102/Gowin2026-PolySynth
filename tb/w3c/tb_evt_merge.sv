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
