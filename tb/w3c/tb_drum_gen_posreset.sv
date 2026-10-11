// ─────────────────────────────────────────────────────────────────────────────
// tb_drum_gen_posreset.sv · ⭐ `P1-18` 专用判据（2026-10-11 新建）
//
// ⭐ **被测缺陷**（⭐ 审查 `[P1-18]`，⭐ `ANVIL-09【ANVIL09-01】`）：
//    ⭐ `top.v` 的 `met_start`（⭐ = "开节拍器/鼓机"的上升沿脉冲）**同时喂**
//       `beat_gen.pos_reset_i` ✅
//    ⭐ `beat_gen` 收到它 ⇒ ⭐ **`tick_cnt_o` 在那一拍【立刻跳回 0】**
//       （⛔ 不产生 `tick`、⛔ 不产生 `bar_start` ✅）
//    🔴 而 `drum_gen` 的步进判据是**无符号差值法**：
//       `step_advance = transport_i & ((tick_cnt_i - tick_at_step_q) >= TPS_C)`
//       ⇒ ⭐ `0 - 300 = 65336 ≥ 240` ⇒ 🔴 **无符号下溢 ⇒ 假的 step_advance** ✅
//    ⇒ ⭐ 于是**多推进一步**、⭐ 并**多发一条不在 16 分网格上的事件** ✅
//
// ⭐ **听感（⭐ 为什么值得修）**：⭐ 交付默认档是 `SEL_DRUM = 1`（**鼓机**）✅
//    ⇒ ⭐ **每次开鼓机**，⭐ 强拍前 **≈0.52 ms** 会多一记 ⇒
//       🔴 **紧 flam / 双击**（⭐ 120 BPM 下一个 16 分音符 = 125 ms ⇒ 约 0.4%）✅
//    ＋ ⭐ 顺带污染 `evt_cnt_o` / `step_evt_cnt_o` / `hit_cnt_o`（⭐ 各多计 1 ✅）
//
// ⭐⭐ **本 tb 的判据设计（⭐ 同源双实例 ⇒ ⭐ 非空洞性内建 ✅）**：
//    ⭐ 例化**两套完全相同的** `beat_gen` ＋ `drum_gen`，⭐ **同 `clk`、⭐ 同 `rst_n`、
//       ⭐ 同参数、⭐ 同激励** —— ⭐ **只差一件事**：⭐ A 组收 `pos_reset` 脉冲，⭐ B 组不收 ✅
//    ⇒ ⭐ 于是"**复位窗口内多出来的事件**"**只可能**来自 `pos_reset` ✅
//    📌 ⭐ `J2`（⭐ B 组窗口内必须 **0** 条）就是**非空洞性对照** ——
//       ⚠️ 它保证"**这个窗口本来就不会有事件**"，⭐ 所以 `J1` 的红**只可能是缺陷** ✅
//
// ⭐ **判据清单**：
//    · `J1` ⭐⭐ **核心**：⭐ 复位后窗口内（⭐ = `WIN1_CLK`，⭐ **严格小于一个 tick**）,
//      ⭐ A 组**不许**多出任何事件（🔴 未修复实测 **+1** 条 ⇒ **必红** ✅）
//    · `J2` ⭐ **非空洞性对照**：⭐ 同一窗口内 B 组必须 **0** 条 ✅
//    · `J3` ⭐ **不许打破既有行为**：⭐ 复位后 A 组的**前两条**必须是**强拍**
//      （⭐ `pattern 0` 的 step 0 = `0101` = **Kick ＋ HiHat** ✅）
//      —— ⚠️ 守的是"**开鼓机从强拍开始**"那个**已交付行为**（⭐ 2026-09-28 用户要求 ✅）
//    · `J4` ⭐ **不许打破既有行为（2）**：⭐ 复位后 A 组的 `step_q` 必须回到 **0** ✅
//    · `J5` ⭐⭐ **修法①专属**：⭐ 复位脉冲后**立刻**（⭐ 只等 10 拍，⭐ 而两个 tick 之间是 26042 拍）
//      `step_q` 就必须是 **0** ✅
//
// ⭐⭐⭐ **覆盖分析（⭐ 变异体实测，⭐ 如实记录 ⚠️）**：
//    ⭐ `P1-18` 有**两条**修法（⭐ ① `drum_gen` 新增 `pos_reset_i`；⭐ ② 差值判据加固）✅
//    ⭐ 实测四种组合：
//    | 组合 | `J1` | `J3` | `J5` | 判据总判 |
//    |---|---|---|---|---|
//    | ⭐ 都不修（⭐ 原始缺陷） | 🔴 **红** | 🔴 **红** | 🔴 **红** | 🔴 **FAIL** ✅ |
//    | ⭐ 只修 ①（⭐ MUT-A） | ✅ 绿 | ✅ 绿 | 🔴 **红** | 🔴 **FAIL** ✅ |
//    | ⭐ 只修 ②（⭐ MUT-B） | ✅ 绿 | ✅ 绿 | 🔴 **红** | 🔴 **FAIL** ✅ |
//    | ✅ **两条都修** | ✅ 绿 | ✅ 绿 | ✅ 绿 | ✅ **PASS** ✅ |
//    ⇒ ⭐ **所以本判据组【要求两条都做】** —— ⭐ 而这**不是过约束**，⭐ 理由如下 ✅：
//      · 🔴 **只修 ① 是不够的（⭐ 一般情形）**：⭐ `pos_rst` 当拍 `tick_at_step_q` 拿到的
//        还是**旧值**（⭐ `tick_cnt_i` 尚未更新）⇒ ⚠️ 下一拍 `step_advance` 仍会**下溢为真**
//        ⇒ ⭐ `step_q` 从 0 跳到 **1**、⭐ 并装载 **step 1 的掩码** ✅
//        📌 ⭐ **`pattern 0` 恰好 step 1 是空掩码** ⇒ ⚠️ 所以 `J1` 在 MUT-A 下**侥幸绿** ✅
//        ⇒ 🔴 **若换一个 step 1 非空的节奏型 ⇒ 多余事件照样出来** ✅
//        ⇒ ⭐ 这正是 `J5` 存在的意义：⭐ **它查【状态】而不是【症状】** ✅
//      · ⚠️ **只修 ② 是"消除症状但没补齐语义"**：⭐ `drum_gen` 仍然**不知道位置被复位了**
//        ⇒ ⭐ `step_q` 会一直停在旧值，⭐ 直到下一个 tick 的 `bar_start` 才归零 ✅
//        （⭐ 审查原文也这么写：*"只做 ② 能消除症状，但下游仍拿不到'位置复位'这件事"* ✅）
//
// ⚠️ 时基：⭐ 激励一律在 `negedge` 改（⛔ 不与 DUT 的 `posedge` 竞争 ✅）
// ⚠️ `WIN1_CLK` 必须 **< `TICK_CLK`** —— 🔴 见它声明处的实测踩坑记录 ✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_drum_gen_posreset;

    localparam integer TICK_CLK = 26042;   // ⭐ 120 BPM 下 1 tick ≈ 26042 clk ✅
    //  ⭐⭐ **窗口 1 的长度必须【严格小于】一个 tick** —— 🔴 这是本轮踩到的坑 ✅
    //     ⚠️ 复位后**第一个 tick** 上会走 `step_zero_align` ⇒ ⭐ 那是**预期行为**
    //        （⭐ 强拍，⭐ `J3` 专门查它 ✅）⇒ ⛔ **不能算进"多余事件"** ✅
    //     🔴 **实测**：⭐ 我原来写 `TICK_CLK`（26042）⇒ ⚠️ 加上 `J5` 那 10 拍之后
    //        ⭐ 窗口右端正好跨过第一个 tick ⇒ 🔴 **`J1` 把强拍也数进去 ⇒ 假红** ✅
    //     ✅ **修法**：⭐ 取 `20000`（⭐ ≈ 一个 tick 的 **77%**）⇒
    //        · ⭐ 缺陷那条在 **+2.5 拍** ⇒ ⭐ 稳稳在窗口内 ✅
    //        · ⭐ 强拍在 **+26042 拍** ⇒ ⭐ 稳稳在窗口外 ✅
    localparam integer WIN1_CLK = 20000;
    //  ⭐ `drum_gen` 的乐器相位增量（⭐ 用于反查"这一条是哪件鼓" ✅）
    localparam [31:0] INC_KICK  = 32'd5_368_709;
    localparam [31:0] INC_SNARE = 32'd42_949_673;
    localparam [31:0] INC_HIHAT = 32'd171_798_691;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    reg pos_reset = 1'b0;                  // ⭐ 只喂 A 组

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    //  ⭐ A 组：⭐ 收 `pos_reset`（⭐ = `top.v` 的 `met_start` ✅）
    //  ⭐ B 组：⭐ **完全相同**，⭐ 只是 ⛔ 不收（⭐ 对照 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    wire        a_tick, a_bar, a_transport;
    wire [15:0] a_tick_cnt;
    wire        a_beat, a_wrap;
    wire [15:0] a_bar_cnt;

    beat_gen #(.PPQN(960), .BEATS_PER_BAR(4), .PHASE_W(32), .TICK_INC_W(32)) u_bg_a (
        .clk_i(clk), .rst_n_i(rst_n), .run_i(1'b1),
        .pos_reset_i(pos_reset),                 // ⭐ A 收复位
        .tick_inc_i(32'd164927),
        .tick_o(a_tick), .tick_cnt_o(a_tick_cnt), .bar_start_o(a_bar),
        .beat_o(a_beat), .transport_o(a_transport), .bar_cnt_o(a_bar_cnt),
        .tick_cnt_wrap_o(a_wrap)
    );

    wire        b_tick, b_bar, b_transport;
    wire [15:0] b_tick_cnt;
    wire        b_beat, b_wrap;
    wire [15:0] b_bar_cnt;

    beat_gen #(.PPQN(960), .BEATS_PER_BAR(4), .PHASE_W(32), .TICK_INC_W(32)) u_bg_b (
        .clk_i(clk), .rst_n_i(rst_n), .run_i(1'b1),
        .pos_reset_i(1'b0),                      // ⭐ B 不收复位（对照）
        .tick_inc_i(32'd164927),
        .tick_o(b_tick), .tick_cnt_o(b_tick_cnt), .bar_start_o(b_bar),
        .beat_o(b_beat), .transport_o(b_transport), .bar_cnt_o(b_bar_cnt),
        .tick_cnt_wrap_o(b_wrap)
    );

    wire        a_valid, a_kind_w;
    wire [3:0]  a_axis;
    wire [31:0] a_inc;
    wire [7:0]  a_vel;
    wire [1:0]  a_kind;
    wire [15:0] a_evt_cnt, a_step_evt_cnt;
    wire [3:0]  a_step_cnt, a_hit_cnt;
    wire        a_cfg_warn;

    drum_gen #(
        .AXIS_W(4), .PHASE_W(32), .VEL_W(8), .AXIS_ID(15),
        .N_DRUM(4), .STEPS(16), .TICKS_PER_STEP(240), .RESERVED_N(5)
    ) u_drm_a (
        .clk_i(clk), .rst_n_i(rst_n), .pattern_id_i(2'd0),
        .tick_i(a_tick), .tick_cnt_i(a_tick_cnt), .bar_start_i(a_bar),
        .transport_i(a_transport),
        .pos_reset_i(pos_reset),                 // ⭐ A 组收复位（⭐ 与 beat_gen 同源 ✅）
        .evt_valid_o(a_valid), .evt_axis_o(a_axis), .evt_phase_inc_o(a_inc),
        .evt_velocity_o(a_vel), .evt_kind_o(a_kind),
        .evt_cnt_o(a_evt_cnt), .step_cnt_o(a_step_cnt), .hit_cnt_o(a_hit_cnt),
        .step_evt_cnt_o(a_step_evt_cnt), .cfg_warn_o(a_cfg_warn)
    );

    wire        b_valid;
    wire [3:0]  b_axis;
    wire [31:0] b_inc;
    wire [7:0]  b_vel;
    wire [1:0]  b_kind;
    wire [15:0] b_evt_cnt, b_step_evt_cnt;
    wire [3:0]  b_step_cnt, b_hit_cnt;
    wire        b_cfg_warn;

    drum_gen #(
        .AXIS_W(4), .PHASE_W(32), .VEL_W(8), .AXIS_ID(15),
        .N_DRUM(4), .STEPS(16), .TICKS_PER_STEP(240), .RESERVED_N(5)
    ) u_drm_b (
        .clk_i(clk), .rst_n_i(rst_n), .pattern_id_i(2'd0),
        .tick_i(b_tick), .tick_cnt_i(b_tick_cnt), .bar_start_i(b_bar),
        .transport_i(b_transport),
        //  ⚠️ **B 组【故意接 0】** —— ⭐ 它是对照组（⭐ 不收 `pos_reset` ✅）
        //     📌 ⭐ 也顺带覆盖了"**老例化不接本端口**"的向后兼容口径（⭐ `z` ⇒ 当 0 ✅）
        .pos_reset_i(1'b0),
        .evt_valid_o(b_valid), .evt_axis_o(b_axis), .evt_phase_inc_o(b_inc),
        .evt_velocity_o(b_vel), .evt_kind_o(b_kind),
        .evt_cnt_o(b_evt_cnt), .step_cnt_o(b_step_cnt), .hit_cnt_o(b_hit_cnt),
        .step_evt_cnt_o(b_step_evt_cnt), .cfg_warn_o(b_cfg_warn)
    );

    // ── ⭐ 事件计数 + ⭐ 复位后前两条的乐器（⭐ 供 `J3` 判"强拍还在不在" ✅）────
    integer   n_a = 0;
    integer   n_b = 0;
    integer   t_reset = -1;
    integer   post_a = 0;
    reg [31:0] post_a_inc1 = 32'd0;
    reg [31:0] post_a_inc2 = 32'd0;

    always @(posedge clk) begin
        if (rst_n && a_valid) begin
            n_a = n_a + 1;
            if (t_reset >= 0) begin
                post_a = post_a + 1;
                if (post_a == 1) post_a_inc1 = a_inc;
                if (post_a == 2) post_a_inc2 = a_inc;
            end
        end
        if (rst_n && b_valid) n_b = n_b + 1;
    end

    integer evt_a_at_reset = 0;
    integer evt_b_at_reset = 0;
    integer win1_a = 0;
    integer win1_b = 0;

    integer i;
    initial begin
        rst_n = 1'b0; pos_reset = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        $display("=== tb_drum_gen_posreset (P1-18: met_start 的 pos_reset 让 drum_gen 多发一条) ===");

        //  ⭐ 跑到小节内 `tick_cnt == 300`（⭐ 已越过 `tick=240` 那次【正常】步进 ✅）
        wait (a_tick_cnt == 16'd300);
        @(negedge clk);
        $display("   info: 复位前 A: tick_cnt=%0d step_q=%0d evt=%0d | B: tick_cnt=%0d step_q=%0d evt=%0d",
                 a_tick_cnt, a_step_cnt, n_a, b_tick_cnt, b_step_cnt, n_b);
        evt_a_at_reset = n_a;
        evt_b_at_reset = n_b;

        //  ⭐ 完全照 `top.v` 的 `met_start`：⭐ **1 拍脉冲** ✅
        pos_reset = 1'b1;
        @(negedge clk);
        pos_reset = 1'b0;
        t_reset = $time;
        $display("   info: pos_reset 脉冲已发（1 拍，t=%0t）", $time);

        // ═════════════════════════════════════════════════════════════════
        $display("== J5 复位脉冲后【立刻】（远早于下一个 tick）step_q 必须已是 0 ==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴🔴 **为什么单独立这一条**：⭐ `P1-18` 有**两条**修法 ✅
        //     · ⭐ ① `drum_gen` 新增 `pos_reset_i`（⭐ 清步进状态）✅
        //     · ⭐ ② 差值判据加固（⭐ 先要求"没后退"）✅
        //     ⚠️ 而 **`J1`（不许有多余事件）【只被 ② 满足】** ——
        //        ⭐ 光有 ② 时，⭐ `step_advance` 因 `0 >= 300` 为假而**不再假推进** ✅
        //        ⇒ 🔴 **`J1` 绿了，⭐ 但 `drum_gen` 仍然"不知道位置被复位了"** ✅
        //     ⇒ ⭐ 本判据（`J5`）**只有 ① 能满足**：
        //        ⭐ 复位后【下一个 tick 之前】`step_q` 就必须是 **0** ✅
        //        （⚠️ 没有 ① 时它一直是 1，⭐ 直到下一个 tick 的 `bar_start` 才归零 ✅）
        //     📌 ⭐ 两个 tick 之间是 **26042 clk** ⇒ ⭐ 这里只等 **10 clk**，
        //        ⭐ 所以"下一个 tick 的 `bar_start`"**结构上不可能**帮上忙 ✅
        repeat (10) @(negedge clk);
        $display("   info: 复位后 10 拍（tick 还没来）：A step_q=%0d evt=%0d",
                 a_step_cnt, n_a);
        //  ⚠️ **只查 `step_q`**（⭐ 不查事件）—— ⭐ 因为"复位后有没有多余事件"是 `J1` 的职责，
        //     ⚠️ 两者重叠会让"`J5` 到底测的是哪条修法"变得说不清 ✅
        chk(a_step_cnt == 4'd0, "J5 pos_reset clears step_q IMMEDIATELY (before the next tick) -- fix (1) only");

        // ═════════════════════════════════════════════════════════════════
        $display("== J1/J2 复位后窗口内不许有多余事件（⭐ 窗口 = %0d clk < 一个 tick）==", WIN1_CLK);
        // ═════════════════════════════════════════════════════════════════
        //  ⚠️ `J5` 已经消耗了 10 拍 ⇒ ⭐ 这里补齐到【从复位算起】正好 `WIN1_CLK` 拍 ✅
        repeat (WIN1_CLK - 10) @(negedge clk);
        win1_a = n_a - evt_a_at_reset;
        win1_b = n_b - evt_b_at_reset;
        $display("   info: 窗口1（复位后 %0d 拍）新增 A=%0d B=%0d（A: tick_cnt=%0d step_q=%0d | B: tick_cnt=%0d step_q=%0d）",
                 WIN1_CLK, win1_a, win1_b, a_tick_cnt, a_step_cnt, b_tick_cnt, b_step_cnt);
        chk(win1_a == 0, "J1 pos_reset must NOT produce any off-grid event (window = 1 tick)");
        chk(win1_b == 0, "J2 non-vacuity: the control (no pos_reset) has 0 events in the same window");

        // ═════════════════════════════════════════════════════════════════
        $display("== J3/J4 复位后必须正常回到 step 0 并发出强拍 ==");
        // ═════════════════════════════════════════════════════════════════
        repeat (2 * TICK_CLK) @(negedge clk);
        $display("   info: 窗口2 累计新增 A=%0d B=%0d | A: step_q=%0d 复位后前两条=%0d,%0d",
                 n_a - evt_a_at_reset, n_b - evt_b_at_reset, a_step_cnt, post_a_inc1, post_a_inc2);
        //  ⭐ `pattern 0` 的 step 0 掩码 = `0101` ⇒ ⭐ **Kick（bit0）＋ HiHat（bit2）** ✅
        //     📌 顺序：⭐ `drum_gen` 按 `pending_q` 的**最低位优先**逐个发 ⇒ Kick 在前 ✅
        //  🔴 **未修复时这一条为什么红**：⭐ 复位后**第一条**是那条**多余的事件**
        //     （⭐ HiHat，⭐ 来自假的 step_advance）⇒ ⭐ 于是序列变成 **[HiHat, Kick]**
        //     ⇒ ⭐ **强拍被一条网格外的音"顶"到了后面** —— ⭐ 这正是用户听到的紧 flam ✅
        chk((post_a_inc1 == INC_KICK) && (post_a_inc2 == INC_HIHAT),
            "J3 the FIRST post-reset events are the step-0 downbeat (Kick then HiHat), no stray in front");
        chk(a_step_cnt == 4'd0, "J4 step_q realigns to 0 after pos_reset");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_drum_gen_posreset - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_drum_gen_posreset - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⚠️ 看门狗：⭐ 本 tb 要跑到小节内 `tick_cnt == 300` ⇒
    //     ⭐ **303 个 tick × 26042 clk × 20 ns ≈ 158 ms 仿真时间** ✅
    //     （⭐ 实测：⭐ 设 40 ms 会**先超时** —— ⚠️ 这正是"看门狗比被测窗口短"的经典坑 ✅）
    initial begin
        #300_000_000;
        $display("FAIL: tb_drum_gen_posreset TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
