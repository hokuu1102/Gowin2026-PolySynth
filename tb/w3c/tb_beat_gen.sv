`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_beat_gen.sv · `beat_gen` 验收 tb（`T32`/`P1`）
//
// ⭐ 判据来源（唯一权威）：`files/20-代码/鼓机节拍器与Loop方案.md` §一 + 任务清单 `T32`
//   ① ⭐ **tick 间隔极差 = 0**（音乐时钟不准 ⇒ 一切免谈）
//   ② ⭐ **BPM 60 / 120 / 200 实测正确**
//   ③ ⭐ **`transport` 边沿断言**（约定 4：边沿时刻断言，⛔ 不事后查询）
//
// ⚠️ 关于判据 ① 的**分档**（本 tb 必须说明，否则会写成假判据）：
//   相位累加器是**小数分频器**：`间隔 = 2^32 / TICK_INC`，一般**不是整数**。
//   ⇒ 逐 tick 间隔只可能是 `floor` 与 `ceil` **两个相邻值**（数学必然），
//     所以"极差 = 0"**只在 `TICK_INC` 能整除 `2^32` 的 BPM 上严格成立**。
//   ⭐ 本 tb 因此**分两档**断言，⛔ 不用"极差 ≤1"去含糊覆盖严格档：
//     · **A 档（严格档）**：选 `TICK_INC` 为 2 的幂 ⇒ 间隔**精确整数** ⇒ 极差 **= 0** 硬断言
//     · **B 档（实用档）**：BPM 60/120/200（查表真值）⇒
//         断言 ① 极差 **≤ 1 clk**（小数累加器的理论上界）
//         断言 ② **平均周期** 与理论值误差 **≤ 1 clk/tick**（用总拍数摊平 ⇒ 无累积漂移）
//
// ⭐ 判据 ③ 的做法：**在 `tick_o` 的边沿那一拍**检查 `transport_o` 与计数是否自洽，
//   ⛔ 不是"过几拍再去读一眼"（`L12`：事后查询必然漏采）。
// ─────────────────────────────────────────────────────────────────────────────

module tb_beat_gen;

    // ── 时钟 / 复位 ─────────────────────────────────────────────────────────
    localparam real CLK_HALF_NS = 10.0;         // 50 MHz ⇒ 周期 20 ns
    reg clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    // ⭐ 2^32（用 real 算参考值，避免 32 bit 截断）
    localparam real TWO_POW_32 = 4294967296.0;
    localparam real FS_HZ      = 50000000.0;

    reg         rst_n     = 1'b0;
    reg         run       = 1'b0;
    reg         pos_reset = 1'b0;
    reg  [31:0] tick_inc  = 32'd0;

    wire        tick;
    wire [15:0] tick_cnt;
    wire        bar_start;
    wire        beat;
    wire        transport;
    wire [15:0] bar_cnt;
    wire        wrap;

    integer errors = 0;

    // ⭐ 全局 clk 计数（posedge 逐拍）与上一个 tick 的 clk 号 —— 供 wait_tick 测周期
    //    ⚠️ 必须**先声明后使用**（Icarus 报 "declaration after use"）
    integer cyc;
    integer last_tick_cyc;

    // ⭐ 实数参考值（模块作用域：Icarus 不接受命名块内声明 real 的写法）
    real avg;
    real exp_cyc;

    initial begin
        cyc           = 0;
        last_tick_cyc = -1;
    end

    beat_gen #(
        .PPQN          (960),
        .BEATS_PER_BAR (4),
        .PHASE_W       (32),
        .TICK_INC_W    (32)
    ) dut (
        .clk_i            (clk),
        .rst_n_i          (rst_n),
        .run_i            (run),
        .pos_reset_i      (pos_reset),
        .tick_inc_i       (tick_inc),
        .tick_o           (tick),
        .tick_cnt_o       (tick_cnt),
        .bar_start_o      (bar_start),
        .beat_o           (beat),
        .transport_o      (transport),
        .bar_cnt_o        (bar_cnt),
        .tick_cnt_wrap_o  (wrap)
    );

    // ── 小工具 ──────────────────────────────────────────────────────────────
    task automatic fail(input [1023:0] msg);
        begin
            $display("FAIL: %0s", msg);
            errors = errors + 1;
        end
    endtask

    // ⭐ 等一个 tick，返回它距上一个 tick 的 clk 数（含本次）
    // ⭐⭐ 测 tick 间隔（**在 posedge 采样**，逐拍计数）
    //
    //   🔴 这里第一版写错过，实测抓到"假失败"（`C36` 教训：探针必须打在
    //      **真正被测的那条线**上，⛔ 否则测的是探针自己）：
    //      原写法 = `while (tick === 1'b1) @(negedge clk);` 先等 tick 落回 0，
    //      再从 0 数到下一个 1。⚠️ 问题：`tick` 只有 **1 clk 宽**，
    //      而 negeine 采样相位与 tick 的相位关系会让"等它落回"这一步
    //      **吃进 0 个或 1 个 clk** ⇒ 间隔读数在 `1022 / 1023 / 1024` 间跳，
    //      表现为 **极差 = 2**，看起来像"RTL 有抖动"，**实际是测量方法引入的**。
    //      ⭐ 反证：用 posedge 逐拍采样（本函数）测同一 RTL ⇒ 极差**精确为 0**。
    //
    //   ⭐ 正确做法：**在 posedge 后采样**、只认 `tick === 1'b1`，相邻两次的
    //      clk 计数差**就是**周期，与 tick 宽度/相位无关。
    //    （`cyc` / `last_tick_cyc` 已在模块顶部声明）

    task automatic wait_tick(output integer gap_out);
        integer guard;
        begin
            guard = 0;
            @(posedge clk);
            cyc = cyc + 1;
            // ⚠️ 必须带护栏：无护栏的 while 一旦没有 tick 就永久挂死
            while (tick !== 1'b1) begin
                @(posedge clk);
                cyc = cyc + 1;
                guard = guard + 1;
                if (guard > 400000) begin
                    fail("wait_tick timeout -- no tick within 400000 clk");
                    gap_out = -1;
                    disable wait_tick;
                end
            end
            if (last_tick_cyc < 0) begin
                gap_out = -1;           // 第一个 tick：还没有前一个可比较
            end else begin
                gap_out = cyc - last_tick_cyc;
            end
            last_tick_cyc = cyc;
        end
    endtask

    // ⭐ 测一个 BPM：返回 (min_gap, max_gap, sum_gap, n_tick)
    integer mn, mx, sum, cnt;
    task automatic measure(
        input  [31:0] inc,
        input  integer n_ticks,
        output integer o_min,
        output integer o_max,
        output integer o_sum,
        output integer o_cnt
    );
        integer g, i;
        begin
            tick_inc = inc;
            // 从干净的相位起点开始
            pos_reset = 1'b1; @(negedge clk); @(negedge clk);
            pos_reset = 1'b0; @(negedge clk);
            mn  = 1000000;
            mx  = -1;
            sum = 0;
            cnt = 0;
            last_tick_cyc = -1;         // ⭐ 清掉上一个测量段的历史 ⇒ 首个 gap 无效、被跳过
            @(negedge clk);
            for (i = 0; i < n_ticks; i = i + 1) begin
                wait_tick(g);
                if (g < 0) begin
                    // ⭐ 第一个 tick 没有前值可比 ⇒ 跳过，⛔ 不算失败
                end else begin
                    if (g < mn) mn = g;
                    if (g > mx) mx = g;
                    sum = sum + g;
                    cnt = cnt + 1;
                end
            end
            o_min = mn; o_max = mx; o_sum = sum; o_cnt = cnt;
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // ① 复位行为 + transport 边沿断言
    // ═══════════════════════════════════════════════════════════════════════
    integer g;
    integer i;

    initial begin
        $dumpfile("build/sim/tb_beat_gen/tb_beat_gen.vcd");
        $dumpvars(0, tb_beat_gen);

        // ── 复位期间：一切必须静默 ──────────────────────────────────────────
        repeat (4) @(negedge clk);
        if (tick !== 1'b0 || bar_start !== 1'b0 || beat !== 1'b0 ||
            tick_cnt !== 16'd0 || bar_cnt !== 16'd0 || transport !== 1'b0) begin
            fail("after reset: outputs not all zero");
        end
        rst_n = 1'b1;
        @(negedge clk);

        // ── run=0 时**不许**出 tick（即使是合法 TICK_INC）────────────────────
        tick_inc = 32'd82463;           // BPM 60（PPQN=960 的正确值）
        run      = 1'b0;
        repeat (2000) @(negedge clk);
        if (tick !== 1'b0) fail("run=0: tick asserted while stopped");
        if (tick_cnt !== 16'd0) fail("run=0: tick_cnt advanced while stopped");

        // ── transport 边沿断言：run 上升沿那一拍之后，tick 才允许出现 ────────
        //    ⭐ 约定 4：在**边沿时刻**断言。做法 = 在 run 变 1 的那一拍起，
        //      逐拍检查"tick 出现时 transport_o 必须已经是 1"。
        run = 1'b1;
        @(negedge clk);
        // run 已被寄存 ⇒ 本拍起 transport 必须为 1
        for (i = 0; i < 300; i = i + 1) begin
            @(negedge clk);
            if (transport !== 1'b1) begin
                fail("transport_o not high after run rising edge");
                i = 300;
            end
            // ⭐ 核心不变量：**tick 有效时，transport 必须同时有效**
            if (tick === 1'b1 && transport !== 1'b1) begin
                fail("tick asserted while transport_o low (edge-time invariant broken)");
                i = 300;
            end
        end

        // ── tick 必须是**严格单周期**（一拍宽）─────────────────────────────
        //    ⭐ 这是"边沿时刻断言"能成立的前提：若 tick 拉宽，下游会重复触发。
        begin : chk_width
            integer width;
            integer guard;
            // ⭐ 等一个 tick（⚠️ **必须带超时护栏**：无护栏的 while 一旦没有 tick
            //    就永久挂死 ⇒ 整个 tb 无输出超时，极易被误判成"逻辑问题"，实测踩过）
            guard = 0;
            while (tick !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 200000) begin
                    fail("chk_width: no tick within 200000 clk (run stuck low?)");
                    disable chk_width;
                end
            end
            // ⭐ 宽度按 **posedge 逐拍**数（⛔ 不用 negedge 半数 —— 会把 1 clk 数成 1 或 2）
            width = 0;
            while (tick === 1'b1) begin
                width = width + 1;
                @(posedge clk);
                if (width > 8) begin
                    fail("tick_o wider than 1 clk -- not a single-cycle pulse");
                    disable chk_width;
                end
            end
            if (width != 1) begin
                $display("FAIL: tick_o width = %0d clk, expected exactly 1", width);
                errors = errors + 1;
            end
        end

        // ── 停止后再启动：**相位必须保持**（§1.4 纪律 2）⇒ 不漂拍 ───────────
        //    ⭐ 判据（不变量）：**停顿时长不改变拍点位置**。
        //       做法：在**拍中间**停下，停 N 拍，再启动；
        //       则"从停下到下一个 tick"的剩余拍数，应当 = (原周期 − 已走拍数)，
        //       ⛔ **与停顿 N 无关**。
        //    ⚠️ 第一版判据写错了（实测发现）：它"停在 tick 刚过之后"再要求剩余拍数小，
        //       但刚过之后本来就是**整拍剩余** ⇒ 正确实现也会得到 ≈26042
        //       ⇒ 那是**假失败**。⭐ 必须停在**拍中间**才能区分"保持相位"与"清相位"。
        begin : chk_hold
            integer elapsed, remain_stop, remain_free, gap_x;

            // ⭐ 本项用 **BPM 120**（`TICK_INC=164927` ⇒ 周期 26041.67 clk）。
            //    ⚠️ 第一版忘了设定 `tick_inc`，还在用上一段的 BPM60 ⇒ 算术全错
            //       （实测得到 39063 clk，是"周期 52083 − 13021"左右）⇒ 假失败。
            tick_inc  = 32'd164927;
            pos_reset = 1'b1; @(posedge clk); @(posedge clk);
            pos_reset = 1'b0; @(posedge clk);
            run = 1'b1;

            // 先同步到一个 tick
            last_tick_cyc = -1;
            wait_tick(gap_x);
            // ⭐ 走过半拍（≈13021 clk @ BPM120）
            repeat (13021) @(posedge clk);
            elapsed = 13021;
            // 记下"如果不停，还差多少拍到下一个 tick"
            run = 1'b0;                         // ⭐ 停下
            repeat (7777) @(posedge clk);       // 停 7777 拍（故意取个非整拍数）
            if (tick !== 1'b0) fail("tick appeared during stop");
            run = 1'b1;                         // ⭐ 再启动

            // ⭐ 从"重新启动的那一刻"数到下一个 tick
            remain_stop = 0;
            while (tick !== 1'b1) begin
                @(posedge clk);
                remain_stop = remain_stop + 1;
                if (remain_stop > 100000) begin
                    fail("no tick after restart");
                    disable chk_hold;
                end
            end
            // ⭐ 理论：周期 26042，已走 13021 ⇒ 剩余应 ≈ 13021
            //    ⚠️ 判据用**区间**而不是等值（避免相位细节过度约束）：
            //       若"保持相位" ⇒ 剩余 ≈ 13021（±50 拍内）
            //       若错误地"清了相位" ⇒ 剩余 ≈ 26042（整拍）
            //    ⇒ 用 20000 一刀切即可**干净地区分两种行为**。
            remain_free = 26042 - elapsed;
            if (remain_stop > 20000) begin
                $display("FAIL: stop did not hold phase -- %0d clk to next tick (a full period ~26042 means phase was cleared)", remain_stop);
                errors = errors + 1;
            end else if (remain_stop < remain_free - 50 || remain_stop > remain_free + 50) begin
                $display("FAIL: stop hold phase is off -- %0d clk to next tick, expected ~%0d", remain_stop, remain_free);
                errors = errors + 1;
            end
        end

        // ── pos_reset：同步、清零相位与计数（§1.4 纪律 2）──────────────────
        begin : chk_pos_reset
            // ⭐ 用 **2^26（64 clk/tick）** ⇒ 3000 clk 内稳稳走过几十拍。
            //    ⛔ 不能用上一段的 BPM120（周期 26042）——那样 3000 clk **一拍都走不到**，
            //    "清零前必须非零"的前置条件不成立 ⇒ 判据变空、且残留旧计数（实测踩过）。
            tick_inc  = 32'd67108864;
            pos_reset = 1'b1; @(negedge clk); @(negedge clk);
            pos_reset = 1'b0; @(negedge clk);
            run = 1'b1;
            repeat (3000) @(posedge clk);
            // ⭐ 先确认确实走了一段（否则下面的判据是空的）
            if (tick_cnt === 16'd0) begin
                fail("pos_reset check: tick_cnt still 0 before reset -- test would be vacuous");
            end
            // ⚠️ 必须在 **negedge** 断言 `pos_reset` 并**保持几拍**再检查：
            //    · 若在 posedge 同时刻阻塞赋值 ⇒ DUT 本拍采旧值 ⇒ 假失败
            //    · 若只保持 1 拍 ⇒ 64 clk/tick 下**下一拍就可能又来一个 tick**，
            //      输出寄存器被重新装载 ⇒ 读数非 0 ⇒ **假失败 "got 45"**（实测踩过）
            @(negedge clk);
            pos_reset = 1'b1;
            repeat (4) @(posedge clk);
            // ⭐ 在 pos_reset 仍为高的**稳定拍**上检查（此时时钟持续被清零）
            if (tick_cnt !== 16'd0) begin
                $display("FAIL: pos_reset did not clear tick_cnt (got %0d)", tick_cnt);
                errors = errors + 1;
            end
            if (bar_cnt !== 16'd0) begin
                $display("FAIL: pos_reset did not clear bar_cnt (got %0d)", bar_cnt);
                errors = errors + 1;
            end
            pos_reset = 1'b0;
            @(posedge clk);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ② A 档（严格档）：TICK_INC 为 2 的幂 ⇒ 间隔精确整数 ⇒ 极差 = 0
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ TICK_INC = 2^22 = 4194304 ⇒ 间隔 = 2^32/2^22 = **1024 clk**（精确）
        //       ⇒ 这一档是"极差 = 0"的**严格**判据，⛔ 不允许任何抖动。
        run = 1'b1;
        measure(32'd4194304, 40, mn, mx, sum, cnt);
        if (mx != mn) begin
            $display("FAIL: strict tier (TICK_INC=2^22): interval range = %0d clk (min %0d max %0d), expected exactly 0", mx - mn, mn, mx);
            errors = errors + 1;
        end else if (mn != 1024) begin
            $display("FAIL: strict tier: interval = %0d clk, expected 1024", mn);
            errors = errors + 1;
        end

        // ⭐ 另一档：TICK_INC = 2^20 ⇒ 间隔 = 4096 clk（再验一次，防巧合）
        measure(32'd1048576, 30, mn, mx, sum, cnt);
        if (mx != mn || mn != 4096) begin
            $display("FAIL: strict tier (TICK_INC=2^20): got min %0d max %0d, expected 4096/4096", mn, mx);
            errors = errors + 1;
        end

        // ═══════════════════════════════════════════════════════════════════
        // ③ B 档（实用档）：判据明确的 BPM 60 / 120 / 200
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ TICK_INC 取 PPQN=960 的**正确值**（文档 §1.3 那组数已按 ×1024 笔误修正）：
        //       60 →   82463 ｜ 120 →  164927 ｜ 200 →  274878
        begin : chk_bpm
            // ⚠️ `real` 变量声明在**模块作用域**（Icarus 不接受命名块内尾部声明 real）

            // ── BPM 60 ⇒ tick 960 Hz ⇒ 周期 52083.33 clk ────────────────────
            measure(32'd82463, 60, mn, mx, sum, cnt);
            if (cnt == 0) begin
                fail("BPM60: no ticks measured");
            end else begin
                if ((mx - mn) > 1) begin
                    $display("FAIL: BPM60 interval range = %0d clk (min %0d max %0d), expected <= 1", mx - mn, mn, mx);
                    errors = errors + 1;
                end
                avg    = sum * 1.0 / cnt;
                exp_cyc = TWO_POW_32 / 82463.0;
                if (avg < exp_cyc - 1.0 || avg > exp_cyc + 1.0) begin
                    $display("FAIL: BPM60 average interval = %0.3f clk, expected %0.3f", avg, exp_cyc);
                    errors = errors + 1;
                end
                // ⭐ 实测 tick 率（Hz）= FS / 平均周期 ⇒ 应为 960 Hz
                if ((FS_HZ / avg) < 959.0 || (FS_HZ / avg) > 961.0) begin
                    $display("FAIL: BPM60 measured tick rate = %0.4f Hz, expected ~960", FS_HZ / avg);
                    errors = errors + 1;
                end
            end

            // ── BPM 120 ⇒ tick 1920 Hz ⇒ 周期 26041.67 clk ──────────────────
            measure(32'd164927, 80, mn, mx, sum, cnt);
            if (cnt == 0) begin
                fail("BPM120: no ticks measured");
            end else begin
                if ((mx - mn) > 1) begin
                    $display("FAIL: BPM120 interval range = %0d clk (min %0d max %0d), expected <= 1", mx - mn, mn, mx);
                    errors = errors + 1;
                end
                avg    = sum * 1.0 / cnt;
                exp_cyc = TWO_POW_32 / 164927.0;
                if (avg < exp_cyc - 1.0 || avg > exp_cyc + 1.0) begin
                    $display("FAIL: BPM120 average interval = %0.3f clk, expected %0.3f", avg, exp_cyc);
                    errors = errors + 1;
                end
                if ((FS_HZ / avg) < 1918.0 || (FS_HZ / avg) > 1922.0) begin
                    $display("FAIL: BPM120 measured tick rate = %0.4f Hz, expected ~1920", FS_HZ / avg);
                    errors = errors + 1;
                end
            end

            // ── BPM 200 ⇒ tick 3200 Hz ⇒ 周期 15625 clk（⭐ 恰好整除）────────
            measure(32'd274878, 60, mn, mx, sum, cnt);
            if (cnt == 0) begin
                fail("BPM200: no ticks measured");
            end else begin
                if ((mx - mn) > 1) begin
                    $display("FAIL: BPM200 interval range = %0d clk (min %0d max %0d), expected <= 1", mx - mn, mn, mx);
                    errors = errors + 1;
                end
                avg    = sum * 1.0 / cnt;
                exp_cyc = TWO_POW_32 / 274878.0;
                if (avg < exp_cyc - 1.0 || avg > exp_cyc + 1.0) begin
                    $display("FAIL: BPM200 average interval = %0.3f clk, expected %0.3f", avg, exp_cyc);
                    errors = errors + 1;
                end
                if ((FS_HZ / avg) < 3198.0 || (FS_HZ / avg) > 3202.0) begin
                    $display("FAIL: BPM200 measured tick rate = %0.4f Hz, expected ~3200", FS_HZ / avg);
                    errors = errors + 1;
                end
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        // ④ bar_start / beat 的相位关系（⭐ 与 tick 同拍，⛔ 不许错拍）
        // ═══════════════════════════════════════════════════════════════════
        begin : chk_align
            integer snap_tick;
            integer guard;
            integer n_bar_seen;
            // ⭐ 要数满**一小节** = PPQN×4 = 3840 tick 才能看到 `bar_start`。
            //    ⚠️ 若用 2^22（1024 clk/tick）⇒ 3840×1024 = **3.93 M clk = 78.6 ms** 仿真，
            //       光这一项就吃掉整个 tb 的绝大部分时间（实测因此撞上看门狗）。
            //    ⭐ 改用 **2^26**（= 64 clk/tick）⇒ 3840×64 = **245 760 clk = 4.9 ms**，
            //       快 16 倍，而**验的是同一套回绕/同拍逻辑**（与 tick 率无关）。
            tick_inc  = 32'd67108864;      // 2^26 ⇒ 间隔 64 clk（精确整数）
            pos_reset = 1'b1; @(negedge clk); @(negedge clk);
            pos_reset = 1'b0; @(negedge clk);
            n_bar_seen = 0;
            // ⭐ 不变量（**在 tick===1 的那一拍直接检查**，⛔ 不事后查询）：
            //   ① `bar_start` 为真时，`tick_cnt` 必须已回绕到 0
            //   ② `bar_start` 必须与 `beat` 同拍（小节首拍即强拍）
            for (snap_tick = 0; snap_tick < 3860; snap_tick = snap_tick + 1) begin
                guard = 0;
                while (tick !== 1'b1) begin
                    @(posedge clk);
                    guard = guard + 1;
                    if (guard > 100000) begin
                        fail("chk_align: no tick within 100000 clk");
                        disable chk_align;
                    end
                end
                if (bar_start === 1'b1) begin
                    n_bar_seen = n_bar_seen + 1;
                    if (tick_cnt !== 16'd0) begin
                        $display("FAIL: bar_start with tick_cnt = %0d (must be 0 -- same-cycle invariant)", tick_cnt);
                        errors = errors + 1;
                    end
                    if (beat !== 1'b1) begin
                        fail("bar_start must coincide with beat (bar starts on a downbeat)");
                    end
                end
                @(posedge clk);
            end
            // ⭐ 必须真的见过 bar_start，否则上面的判据是空的（C36 纪律）
            if (n_bar_seen == 0) begin
                fail("alignment check: no bar_start observed -- criteria were vacuous");
            end
        end

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: beat_gen tick interval range 0 (strict tiers) / <=1 clk (BPM 60/120/200), BPM rates correct, transport edge assertions hold");
        else
            $display("FAIL: beat_gen had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94` 纪律：没有结论必须算失败）
    //    ⚠️ 时限必须**按实际仿真时长留足余量**（实测踩过）：本 tb 需 ~205 ms 仿真时间
    //       （最大头是 `chk_align` 数满一小节 = 3840 tick × 1024 clk = 78.6 ms），
    //       最初写 200 ms ⇒ **恰好在最后一节被看门狗杀掉**，表现为"无任何输出的超时"，
    //       极易被误判成"逻辑挂死"。⇒ 现取 600 ms（≈2.9× 余量）。
    initial begin
        #600_000_000;
        $fatal(1, "FAIL: tb_beat_gen timeout");
    end

endmodule
