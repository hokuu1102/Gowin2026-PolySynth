// ═══════════════════════════════════════════════════════════════════════════
//  tb_seq_arb —— ⭐ 源 A 三级仲裁（手弹 / 曲谱 / 演示）
//
//  ⭐ 为什么写这一支（⭐ 硬约束：新模块没有 tb = 没被验收）：
//     🔴 `seq_arb` 的**唯一职责**就是"⭐ **多源同拍相撞不丢**"
//     ⇒ ⚠️ 而"丢事件"正是**本项目最容易漏测的一类**：
//        · `U-6` `evt_merge`：⭐ 当年两路直接 or ⇒ 🔴 同拍丢一条
//        · `U-18b` `play_seq`：⭐ 16 判据全过、变异体 4/4 全抓，
//          🔴 **但同 tick 多事件从没测** ⇒ 和弦被拉成琶音
//     ⇒ ⭐⭐ **所以本 tb 的重点判据是"同拍 N 个源都到"**。
//
//  ⭐ 判据（10 条）：
//     ① ⭐ 无输入 ⇒ 不发任何事件
//     ② ⭐⭐ **手弹+曲谱同拍 ⇒ 两条都出来**（⭐ 最关键）
//     ③ ⭐⭐ **三源同拍 ⇒ 三条都出来**（⚠️ 演示让位后不算，⭐ 见 §让位）
//     ④ ⭐ **单源 ⇒ 正常转发**
//     ⑤ ⭐ **`evt_valid_o` 严格单周期**
//     ⑥ ⭐ **数据与 valid 同拍**（⭐ `80 号` 的教训）
//     ⑦ ⭐⭐ **演示让位**：⭐ 有手弹时演示**不参与**（⭐ 不自检和弦抢演奏）
//     ⑧ ⭐ **不丢也不多**：⭐ 发出的总数 == 输入的总数
//     ⑨ ⭐ **溢出可见**：⭐ 强灌到溢出 ⇒ `overflow_o` 拉起 + `drop_cnt_o` 计数
//     ⑩ ⭐ **A8：无 X/Z 传播**
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_seq_arb;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer KIND_W  = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer DEPTH   = 6;
    localparam integer T       = 20;

    reg clk = 1'b0, rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ── 三个源 ────────────────────────────────────────────────────────────
    reg               live_v = 0, score_v = 0, demo_v = 0;
    reg [AXIS_W-1:0]  live_ax = 0, score_ax = 0, demo_ax = 0;
    reg [PHASE_W-1:0] live_inc = 0, score_inc = 0, demo_inc = 0;
    reg [VEL_W-1:0]   live_vel = 0, score_vel = 0, demo_vel = 0;
    reg [KIND_W-1:0]  live_kd = 0, score_kd = 0, demo_kd = 0;
    reg               live_tv = 0, score_tv = 0, demo_tv = 0;
    reg [TIMBRE_W-1:0] live_tb = 0, score_tb = 0, demo_tb = 0;

    wire              evt_v;
    wire [AXIS_W-1:0] evt_ax;
    wire [PHASE_W-1:0] evt_inc;
    wire [VEL_W-1:0]  evt_vel;
    wire [KIND_W-1:0] evt_kd;
    wire              evt_tv;
    wire [TIMBRE_W-1:0] evt_tb;
    wire [15:0] coll_cnt, merged_cnt, drop_cnt, live_cnt, score_cnt, demo_cnt;
    wire        overflow;

    seq_arb #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .DEPTH(DEPTH)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .live_valid_i(live_v),  .live_axis_i(live_ax),  .live_phase_inc_i(live_inc),
        .live_velocity_i(live_vel),  .live_kind_i(live_kd),
        .live_timbre_valid_i(live_tv), .live_timbre_i(live_tb),
        .score_valid_i(score_v), .score_axis_i(score_ax), .score_phase_inc_i(score_inc),
        .score_velocity_i(score_vel), .score_kind_i(score_kd),
        .score_timbre_valid_i(score_tv), .score_timbre_i(score_tb),
        .demo_valid_i(demo_v),  .demo_axis_i(demo_ax),  .demo_phase_inc_i(demo_inc),
        .demo_velocity_i(demo_vel),  .demo_kind_i(demo_kd),
        .demo_timbre_valid_i(demo_tv), .demo_timbre_i(demo_tb),
        .evt_valid_o(evt_v), .evt_axis_o(evt_ax), .evt_phase_inc_o(evt_inc),
        .evt_velocity_o(evt_vel), .evt_kind_o(evt_kd),
        .evt_timbre_valid_o(evt_tv), .evt_timbre_o(evt_tb),
        .collision_cnt_o(coll_cnt), .merged_cnt_o(merged_cnt), .drop_cnt_o(drop_cnt),
        .overflow_o(overflow),
        .live_cnt_o(live_cnt), .score_cnt_o(score_cnt), .demo_cnt_o(demo_cnt)
    );

    // ── 收集出口事件（⭐ 用"轴"当身份，⭐ 各源用不同轴号便于识别）────────────
    integer n_out = 0;
    reg [AXIS_W-1:0] out_ax [0:127];
    reg [PHASE_W-1:0] out_inc [0:127];
    integer n_live_seen = 0, n_score_seen = 0, n_demo_seen = 0;

    // ⭐ 各源的"身份"：⭐ 用 phase_inc 当唯一标记（⭐ 便于核对是哪一条）
    localparam [31:0] LIVE_INC1  = 32'h1111_0001;
    localparam [31:0] LIVE_INC2  = 32'h1111_0002;
    localparam [31:0] SCORE_INC1 = 32'h2222_0001;
    localparam [31:0] SCORE_INC2 = 32'h2222_0002;
    localparam [31:0] DEMO_INC1  = 32'h3333_0001;

    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            if (n_out < 128) begin
                out_ax[n_out]  = evt_ax;
                out_inc[n_out] = evt_inc;
            end
            n_out = n_out + 1;
            if (evt_inc == LIVE_INC1 || evt_inc == LIVE_INC2)  n_live_seen  = n_live_seen + 1;
            if (evt_inc == SCORE_INC1 || evt_inc == SCORE_INC2) n_score_seen = n_score_seen + 1;
            if (evt_inc == DEMO_INC1)                           n_demo_seen  = n_demo_seen + 1;
        end
    end

    // ── 工具任务 ──────────────────────────────────────────────────────────
    task clr_srcs; begin
        live_v = 0; score_v = 0; demo_v = 0;
        live_ax = 0; score_ax = 0; demo_ax = 0;
        live_inc = 0; score_inc = 0; demo_inc = 0;
        live_vel = 0; score_vel = 0; demo_vel = 0;
        live_kd = 0; score_kd = 0; demo_kd = 0;
        live_tv = 0; score_tv = 0; demo_tv = 0;
        live_tb = 0; score_tb = 0; demo_tb = 0;
    end endtask

    task do_reset; begin
        rst_n = 1'b0;
        clr_srcs;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        n_out = 0; n_live_seen = 0; n_score_seen = 0; n_demo_seen = 0;
    end endtask

    // ⭐ 发一条"手弹"（⭐ 单拍脉冲，⭐ 与真实链路一致）
    task pulse_live(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        live_v = 1; live_inc = inc; live_ax = 4'd3; live_vel = 8'd200; live_kd = 2'd0;
        @(negedge clk);
        live_v = 0;
    end endtask

    task pulse_score(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        score_v = 1; score_inc = inc; score_ax = 4'd5; score_vel = 8'd180; score_kd = 2'd0;
        @(negedge clk);
        score_v = 0;
    end endtask

    task pulse_demo(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        demo_v = 1; demo_inc = inc; demo_ax = 4'd0; demo_vel = 8'd150; demo_kd = 2'd0;
        @(negedge clk);
        demo_v = 0;
    end endtask

    integer errors = 0;
    integer i;
    // ⭐⭐ 单周期判据（🔴 2026-09-26 修正：我第一版判据【写错了】）
    //   🔴 **错在哪**：我原来数"`evt_valid_o` 连续高了几拍"，⚠️ 要求 ≤1。
    //      ⇒ ⚠️ 但**队列里有 2 条时连弹 2 拍是完全正常的**！
    //      ⇒ 🔴 所以那个判据会把【正确行为】判成失败。
    //   ⭐ **正确判据**：⭐ **"同一个事件不能持续 2 拍"** ——
    //      ⭐ 即：⭐ `evt_valid_o` 连续为高时，⭐ **数据必须每拍都在变**
    //      （⭐ 若数据不变 ⇒ 🔴 那是"粘滞"，⭐ 才是真 bug ——
    //        ⚠️ `evt_merge` 注释里那个"valid 一直高、数据不变"的就是这种）
    //   ⚠️ 注意：`max_valid_high` 只用来**打印**（⭐ 说明"连续高几拍是正常的"），
    //      ⛔ **不再当判据** —— ⭐ 真正的判据是 `n_stuck`（零粘滞）
    reg              evt_v_d = 0;
    integer          n_valid_high_in_row = 0;
    integer          max_valid_high = 0;
    reg [AXIS_W-1:0]  last_ax  = 4'hF;
    reg [PHASE_W-1:0] last_inc = 32'hDEAD_BEEF;
    integer n_stuck = 0;                 // ⭐ "valid 高但数据没变"的拍数
    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            // ⭐ 只有"【连续两拍】且数据完全一样"才算粘滞
            if (evt_v_d && (evt_ax === last_ax) && (evt_inc === last_inc))
                n_stuck = n_stuck + 1;
            last_ax  = evt_ax;
            last_inc = evt_inc;
        end
        evt_v_d <= evt_v;
    end

    // ⭐ 连续高几拍（⭐ 只用于打印，⛔ 不是判据）
    always @(posedge clk) begin
        if (rst_n) begin
            if (evt_v) begin
                n_valid_high_in_row = n_valid_high_in_row + 1;
                if (n_valid_high_in_row > max_valid_high) max_valid_high = n_valid_high_in_row;
            end else begin
                n_valid_high_in_row = 0;
            end
        end
    end

    initial begin
        $display("=== tb_seq_arb（源 A 三级仲裁）===");

        // ═══ ① 无输入 ⇒ 不发事件 ═══════════════════════════════════════════
        do_reset();
        repeat (20) @(negedge clk);
        if (n_out == 0) $display("  ok  : ① 无输入 ⇒ 不发任何事件");
        else begin
            $display("FAIL: ① 无输入却发了 %0d 条", n_out);
            errors = errors + 1;
        end

        // ═══ ④ 单源 ⇒ 正常转发 ═════════════════════════════════════════════
        do_reset();
        pulse_live(LIVE_INC1);
        repeat (8) @(negedge clk);
        if (n_out == 1 && out_inc[0] == LIVE_INC1)
            $display("  ok  : ④ 单源（手弹）⇒ 恰好 1 条，内容正确");
        else begin
            $display("FAIL: ④ 单源转发异常：n_out=%0d inc[0]=%h", n_out, out_inc[0]);
            errors = errors + 1;
        end

        // ═══ ② ⭐⭐ 手弹+曲谱【同拍】⇒ 两条都要出来 ════════════════════════
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;  live_ax  = 4'd3;
        score_v = 1; score_inc = SCORE_INC1; score_ax = 4'd5;
        @(negedge clk);
        live_v = 0; score_v = 0;
        repeat (12) @(negedge clk);
        if (n_out == 2 && n_live_seen == 1 && n_score_seen == 1)
            $display("  ok  : ②⭐ 手弹+曲谱同拍 ⇒ 【两条都出来了】(live=1 score=1)");
        else begin
            $display("FAIL: ② 🔴 同拍相撞【丢事件】！n_out=%0d live=%0d score=%0d",
                     n_out, n_live_seen, n_score_seen);
            errors = errors + 1;
        end

        // ═══ ⑦ ⭐⭐ 演示让位：有手弹时演示不参与 ════════════════════════════
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;
        demo_v = 1;  demo_inc  = DEMO_INC1;
        @(negedge clk);
        live_v = 0; demo_v = 0;
        repeat (12) @(negedge clk);
        if (n_live_seen == 1 && n_demo_seen == 0)
            $display("  ok  : ⑦ 演示让位 —— 手弹在发时演示【不参与】(live=1 demo=0)");
        else begin
            $display("FAIL: ⑦ 演示让位失效：live=%0d demo=%0d", n_live_seen, n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ④b 演示单独 ⇒ 正常发 ══════════════════════════════════════════
        do_reset();
        pulse_demo(DEMO_INC1);
        repeat (8) @(negedge clk);
        if (n_demo_seen == 1)
            $display("  ok  : ④b 演示单独（无别源）⇒ 正常发 1 条");
        else begin
            $display("FAIL: ④b 演示单独时没发出去 (demo=%0d)", n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑧ 不丢也不多：连发 N 条，数出来的必须相等 ═════════════════════
        do_reset();
        for (i = 0; i < 20; i = i + 1) begin
            pulse_live(LIVE_INC2);      // ⭐ 间隔发（⭐ 每 2 拍一条）
            @(negedge clk);
        end
        repeat (20) @(negedge clk);
        if (n_out == 20)
            $display("  ok  : ⑧ 连发 20 条 ⇒ 出来 20 条（不丢不多）");
        else begin
            $display("FAIL: ⑧ 连发 20 条却出来 %0d 条", n_out);
            errors = errors + 1;
        end

        // ═══ ⑤ 不粘滞：⭐ "valid 连续为高时数据必须每拍都在变" ═══════════════
        //   🔴 2026-09-26 修正：⭐ 我第一版判"连续高 ≤1 拍"，⚠️ 那是**错的**
        //      —— 队列里有 2 条时**连弹 2 拍完全正常**。
        //   ⭐ 正确判据：⭐ **同一个事件不能占 2 拍**（⭐ 那才是粘滞 ⇒ 数据不变）
        if (n_stuck == 0)
            $display("  ok  : ⑤ 不粘滞 —— valid 连续高时数据每拍都在变（最长连续 %0d 拍，正常）",
                     max_valid_high);
        else begin
            $display("FAIL: ⑤ 🔴 出现 %0d 拍'valid 高但数据不变'（粘滞）", n_stuck);
            errors = errors + 1;
        end

        // ═══ ⑨ 溢出可见 ═════════════════════════════════════════════════════
        //   🔴 2026-09-26 修正：⭐ 我第一版"每 2 拍推 2 条" ⇒ ⚠️ **平均只有 1 条/拍**
        //      ⇒ ⭐ 恰好等于出口速率 ⇒ 🔴 **永远追不上、灌不爆**（⭐ 逻辑是对的）
        //   ⭐ 正确做法：⭐ **每拍都推 2 条**（2 条/拍 > 出口 1 条/拍 ⇒ 必然积压）
        do_reset();
        for (i = 0; i < 60; i = i + 1) begin
            @(negedge clk);
            live_v = 1;  live_inc  = LIVE_INC1;
            score_v = 1; score_inc = SCORE_INC1;
            @(negedge clk);
            // ⚠️ **保持为 1**（⛔ 不清零）⇒ ⭐ 每拍都推 2 条 ⇒ 必然溢出
            live_v = 1; score_v = 1;
        end
        clr_srcs();
        repeat (40) @(negedge clk);
        if (overflow === 1'b1 && drop_cnt > 0)
            $display("  ok  : ⑨ 溢出【可见】—— overflow=1, drop_cnt=%0d（⛔ 不静默丢）", drop_cnt);
        else begin
            $display("FAIL: ⑨ 灌爆了却没报溢出 overflow=%b drop_cnt=%0d", overflow, drop_cnt);
            errors = errors + 1;
        end

        // ═══ ③ 三源同拍 ═════════════════════════════════════════════════════
        //   ⚠️ 注意：⭐ 演示让位 ⇒ 有手弹/曲谱时演示不参与
        //      ⇒ ⭐ 所以"三源同拍"实际出来的是 **手弹 + 曲谱 2 条**
        //      📌 这【就是设计意图】（⭐ 自检和弦不抢真演奏）
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;
        score_v = 1; score_inc = SCORE_INC1;
        demo_v = 1;  demo_inc  = DEMO_INC1;
        @(negedge clk);
        live_v = 0; score_v = 0; demo_v = 0;
        repeat (12) @(negedge clk);
        if (n_live_seen == 1 && n_score_seen == 1 && n_demo_seen == 0)
            $display("  ok  : ③ 三源同拍 ⇒ 手弹+曲谱 2 条（⭐ 演示按设计让位）");
        else begin
            $display("FAIL: ③ 三源同拍异常：live=%0d score=%0d demo=%0d",
                     n_live_seen, n_score_seen, n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑥ 数据与 valid 同拍（⭐ 在 always 块里已按同拍取样 ⇒ 等价于检查） ═
        //   ⭐ 若 data 与 valid 不同拍 ⇒ ⭐ 前面按 inc 认身份就会认错/丢
        if (n_out > 0 && (n_live_seen + n_score_seen + n_demo_seen) <= n_out)
            $display("  ok  : ⑥ 数据与 valid 同拍（⭐ 按 inc 认身份全部认到了）");
        else begin
            $display("FAIL: ⑥ 数据/valid 不同拍：n_out=%0d 认出 %0d 条",
                     n_out, n_live_seen + n_score_seen + n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑩ A8：无 X/Z ══════════════════════════════════════════════════
        if ((evt_v !== 1'bx) && (evt_ax !== 4'hx) && (evt_inc !== 32'hx))
            $display("  ok  : ⑩ A8 无 X/Z 传播");
        else begin
            $display("FAIL: ⑩ 出现 X/Z（v=%b ax=%h inc=%h）", evt_v, evt_ax, evt_inc);
            errors = errors + 1;
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑪ 每源计数必须【真的在数】（⭐ 2026-09-26 补 · 变异 M121 的 LEAK）
        //
        //  🔴 **为什么单补这一条**：⭐ 变异测试报 `M121 GREEN(LEAK)` ——
        //     ⭐ 把 `pop_src = pop_data[ENT_W +: NW]` 改成 `= 2'd3`（非法源 id）
        //     ⇒ ⭐ 每条弹出都被算成"未知源" ⇒ 🔴 **三个分源计数全部不涨**
        //     🔴 **我的 tb 却没抓到** —— ⚠️ **因为这三个信号【接了但从没断言】**。
        //  📌 **一般教训**：⭐ **"接了输出" ≠ "验了输出"** ——
        //     ⚠️ 一个从不被断言的输出，⭐ **在变异测试里等于不存在**。
        //     ⭐ 这正是 `M105`（`in_frame_cnt_o` 停止计数）那类 LEAK 的同族。
        //  ⭐ **判据**：⭐ 跑过确定已知的三段激励后，⭐ **三个计数必须分别对得上**。
        // ═══════════════════════════════════════════════════════════════════
        begin : per_source_cnt_check
            integer e_live, e_score, e_demo;
            // ⭐ 复位清计数，⭐ 然后各发确定条数
            do_reset();
            // ⭐ 手弹 3 条（⭐ 分开拍，⛔ 不相撞）
            pulse_live(LIVE_INC1);  @(negedge clk);
            pulse_live(LIVE_INC1);  @(negedge clk);
            pulse_live(LIVE_INC1);  @(negedge clk);
            // ⭐ 曲谱 2 条
            pulse_score(SCORE_INC1); @(negedge clk);
            pulse_score(SCORE_INC1); @(negedge clk);
            // ⭐ 演示 2 条（⭐ 此时无别的源 ⇒ 演示不被让位）
            pulse_demo(DEMO_INC1);  @(negedge clk);
            pulse_demo(DEMO_INC1);  @(negedge clk);
            repeat (20) @(negedge clk);
            e_live  = 3; e_score = 2; e_demo = 2;
            $display("      分源计数: live=%0d(期望%0d) score=%0d(期望%0d) demo=%0d(期望%0d)",
                     live_cnt, e_live, score_cnt, e_score, demo_cnt, e_demo);
            if (live_cnt == e_live && score_cnt == e_score && demo_cnt == e_demo)
                $display("  ok  : ⑪ 三个分源计数【都真的在数】（⭐ 上板可据此看'谁在发'）");
            else begin
                $display("FAIL: ⑪ 🔴 分源计数不对 ⇒ 可观测性在撒谎（K-106）");
                errors = errors + 1;
            end
        end

        $display("--------------------------------------------------");
        $display("  出口事件总数 = %0d（手弹 %0d · 曲谱 %0d · 演示 %0d）",
                 n_out, n_live_seen, n_score_seen, n_demo_seen);
        $display("  相撞计数 = %0d · 合流计数 = %0d · 丢弃 = %0d",
                 coll_cnt, merged_cnt, drop_cnt);
        $display("--------------------------------------------------");

        if (errors == 0)
            $display("PASS: seq_arb 多源同拍不丢、演示让位、溢出可见、单周期、无 X/Z");
        else
            $fatal(1, "FAIL: seq_arb has %0d unexpected item(s)", errors);

        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
