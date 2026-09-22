`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_perc_env_bank.sv · `perc_env_bank` 验收（`T33`）
//
// ⭐ 判据（⚠️ **每一条都必须能失败** —— `K-56`/`C21`；⭐ 尽量写成【不变量】—— `C44`）
//
//   ① ⭐ **反证基线**：不触发时 `level = 0` 且 `active_o = 0`
//      ⚠️ 没有这一步，"active 恒 1" 之类的 bug 会**假通过**
//   ② ⭐ **触发即到峰值**（=`velocity << (ENV_W-VEL_W)`），且 `active_o` 立刻置位
//   ③ ⭐ **单调不增**（不变量）：整个衰减过程 `level[n+1] <= level[n]`
//      ⚠️ 这能抓"下溢回绕"（⚠️ 回绕会让包络**突然变响**，是明显 bug）
//   ④ ⭐⭐ **精确衰减时长** = `ceil(峰值 / DECAY_STEP)` 个 sample_tick
//      ⚠️ 判**精确值**，⛔ 不是 "大约 20 ms"
//   ⑤ ⭐⭐ **衰到 0 后 `active_o` 必须落下** —— ⚠️ 否则永远不释放 voice ⇒ **挂音**（`T38`）
//   ⑥ ⭐ **力度敏感**：peak 随 `velocity` 线性变化（两档对比，⛔ 不是只看一档）
//   ⑦ ⭐ **多乐器独立**：一个在响不影响另一个（同 `envelope_bank` 独立性的要求）
//   ⑧ ⭐ **衰减中重触发** ⇒ 回到峰值重起（打击乐必须能连击），且**计数可观测**
//   ⑨ ⭐ **触发不受 `sample_tick_i` 约束**：两次 sample_tick 之间来的触发**不许丢**
//      ⚠️ 这是我特意设计的语义（触发优先、不依赖 tick）⇒ 必须被守住
// ─────────────────────────────────────────────────────────────────────────────

module tb_perc_env_bank;

    localparam integer N_PERC = 4;
    localparam integer ENV_W  = 16;
    localparam integer VEL_W  = 8;
    localparam integer STEP   = 67;
    localparam integer SHIFT  = ENV_W - VEL_W;      // 8

    reg clk = 1'b0;
    always #10 clk = ~clk;                           // 50 MHz

    reg                    rst_n       = 1'b0;
    reg                    sample_tick = 1'b0;
    reg  [N_PERC-1:0]      trigger     = {N_PERC{1'b0}};
    reg  [N_PERC*VEL_W-1:0] velocity   = {(N_PERC*VEL_W){1'b0}};

    wire [N_PERC*ENV_W-1:0] level;
    wire [N_PERC-1:0]       active;
    wire [N_PERC-1:0]       busy;
    wire [N_PERC*16-1:0]    retrig_cnt;

    wire [ENV_W-1:0] lv0 = level[0*ENV_W +: ENV_W];
    wire [ENV_W-1:0] lv1 = level[1*ENV_W +: ENV_W];
    wire [ENV_W-1:0] lv2 = level[2*ENV_W +: ENV_W];
    wire [ENV_W-1:0] lv3 = level[3*ENV_W +: ENV_W];

    integer errors = 0;

    task chk;
        input [8*100-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    perc_env_bank #(
        .N_PERC     (N_PERC),
        .ENV_W      (ENV_W),
        .VEL_W      (VEL_W),
        .DECAY_STEP (STEP)
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .sample_tick_i(sample_tick),
        .trigger_i    (trigger),
        .velocity_i   (velocity),
        .level_o      (level),
        .active_o     (active),
        .busy_o       (busy),
        .retrig_cnt_o (retrig_cnt)
    );

    // ── 小工具 ──────────────────────────────────────────────────────────────
    // ⭐ 一拍 sample_tick（在 negedge 驱动 ⇒ 避免与 posedge 竞争）
    task tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
        end
    endtask

    // ⭐ 发一个触发的**单周期脉冲**，并**等装载完成**
    //    ⚠️ 实现细节：触发那一拍只把峰值锁进 `peak_r`（`load_r=1`），
    //       **下一拍**才 `level <= peak_r` ⇒ ⭐ 采样点要往后挪一拍，
    //       否则会读到"还没装载"的旧值（⚠️ 这正是 `K-109` 同族的"不同拍"问题）。
    task fire;
        input integer which;
        begin
            @(negedge clk);
            trigger[which] = 1'b1;
            @(negedge clk);
            trigger[which] = 1'b0;
            @(negedge clk);              // ⭐ 装载拍：level <= peak_r
        end
    endtask

    integer i;
    integer elapsed;
    integer prev;
    integer expected_ticks;
    reg [ENV_W-1:0] peak255;
    reg             mono_ok;

    initial begin
        $dumpfile("build/sim/tb_perc_env_bank/tb_perc_env_bank.vcd");
        $dumpvars(0, tb_perc_env_bank);

        peak255 = 16'd65280;            // 255 << 8

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：不触发 ⇒ 全 0、全不活跃
        // ═══════════════════════════════════════════════════════════════════
        repeat (50) @(negedge clk);
        chk("baseline: all levels are 0 with no trigger",
            lv0 === 16'd0 && lv1 === 16'd0 && lv2 === 16'd0 && lv3 === 16'd0);
        chk("baseline: active_o is all 0 with no trigger", active === 4'b0000);
        chk("baseline: busy_o is all 0 with no trigger", busy === 4'b0000);

        // ═══════════════════════════════════════════════════════════════════
        // ② 触发 ⇒ 立刻到峰值（力度 200 ⇒ 200<<8 = 51200）
        // ═══════════════════════════════════════════════════════════════════
        velocity[0*VEL_W +: VEL_W] = 8'd200;
        velocity[1*VEL_W +: VEL_W] = 8'd255;
        velocity[2*VEL_W +: VEL_W] = 8'd128;
        velocity[3*VEL_W +: VEL_W] = 8'd64;

        fire(0);
        @(negedge clk);
        chk("trigger: level jumps straight to the velocity peak (200<<8 = 51200)",
            lv0 === 16'd51200);
        chk("trigger: active_o sets on the trigger", active[0] === 1'b1);
        // ⭐ 其它乐器必须**不受影响**（独立性）
        chk("trigger: other instruments stay silent (independence)",
            lv1 === 16'd0 && lv2 === 16'd0 && lv3 === 16'd0 && active === 4'b0001);

        // ═══════════════════════════════════════════════════════════════════
        // ③ + ④ + ⑤ 单调不增 + 精确时长 + active 准确落下
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ 理论：峰值 51200 / 步长 67 = 764.2 ⇒ **765** 个 sample_tick 到 0
        expected_ticks = (51200 + STEP - 1) / STEP;      // ceil ⇒ 765
        prev = 51200;
        elapsed = 0;
        mono_ok = 1'b1;                                  // ⭐ 显式记录"有没有违反单调性"
        //    ⚠️ 上限给足（预期 765），多跑 20 拍确定它真的**停住**了
        for (i = 0; i < (expected_ticks + 20); i = i + 1) begin
            tick();
            elapsed = elapsed + 1;
            // ⭐ 不变量：单调不增（抓下溢回绕）
            if (lv0 > prev) begin
                $display("  monotonicity broken at tick %0d: level went UP from %0d to %0d (underflow wrap!)",
                         elapsed, prev, lv0);
                mono_ok = 1'b0;
                i = expected_ticks + 20;
            end
            prev = lv0;
            if (active[0] === 1'b0 && elapsed > 1) begin
                // 已经收尾 —— 记下用时并跳出
                i = expected_ticks + 20;
            end
        end
        // ⭐⭐ 单调性是**真判据**（⛔ 不是恒真的摆设）
        chk("decay is monotonic non-increasing (no underflow wrap)", mono_ok === 1'b1);
        // ⭐⭐ 精确时长（⛔ 不是"大约"）
        if (elapsed !== expected_ticks) begin
            $display("  FAIL: decay took %0d sample ticks, expected exactly %0d (peak 51200 / step 67, rounded up)",
                     elapsed, expected_ticks);
            errors = errors + 1;
        end else begin
            $display("  ok  : decay took exactly %0d sample ticks (= %.2f ms at 48828 Hz)",
                     elapsed, elapsed * 1000.0 / 48828.0);
        end
        // ⭐⭐ 关键：必须准确落下（否则挂音）
        chk("decay: level reaches exactly 0", lv0 === 16'd0);
        chk("decay: active_o CLEARS when the envelope finishes (no hung voice)",
            active[0] === 1'b0);
        chk("decay: busy_o clears too", busy[0] === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ 力度敏感（两档对比）
        // ═══════════════════════════════════════════════════════════════════
        fire(1);                                 // vel=255 ⇒ 65280
        @(negedge clk);
        chk("velocity: vel=255 gives peak 65280", lv1 === peak255);
        fire(2);                                 // vel=128 ⇒ 32768
        @(negedge clk);
        chk("velocity: vel=128 gives peak 32768 (half of 255's, within rounding)",
            lv2 === 16'd32768);
        // ⚠️ 这里**不能**断言 `4'b0111` —— 乐器 0 在上面那个 765 拍的循环里**已经衰完**了。
        //    🔴 我第一版就是这么写错的：把"曾经触发过"当成了"现在还在响"。
        //    ⭐ 同 `K-108`：判据里的人工算术必须核对**当前状态**，⛔ 不是历史。
        chk("velocity: instruments 1 and 2 ring independently while 0 is silent",
            active === 4'b0110);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 独立性：让 instrument 1 跑完，2 的电平不受影响
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ 51200/67 = 765 拍足够让 vel=128 (32768) 也跑完（32768/67 = 490）
        //       ⇒ 这里只跑 200 拍，看两者是否**各自**衰减
        begin : indep
            integer l1_before, l2_before;
            l1_before = lv1;
            l2_before = lv2;
            repeat (200) tick();
            chk("independence: instrument 1 decayed", lv1 < l1_before);
            chk("independence: instrument 2 ALSO decayed (neither stalled)",
                lv2 < l2_before);
            // ⭐ 两者步长相同 ⇒ 200 拍内下降量应当**相等**（都是 200×67）
            chk("independence: both decay at the same rate (200 ticks x 67)",
                (l1_before - lv1) === (l2_before - lv2));
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑧ 衰减中重触发 ⇒ 回峰值重起 + 计数可观测
        // ═══════════════════════════════════════════════════════════════════
        begin : retrig
            integer cnt_before;
            // 🔴 我第一版直接在这里检查"乐器 3 还在响" —— **必然失败**：
            //    乐器 3 在很久以前（约 985 拍前）用 vel=64（峰值 16384）触发过，
            //    而 16384/67 = **244 拍**就衰完了 ⇒ ⚠️ 此刻它**早就静音**。
            //    ⭐ 修法：**先当场重新触发**，让它进入衰减中，**再**测重触发。
            //    📌 教训（同 `K-108`）：判据的**前置条件**也要按当前状态算，⛔ 不能凭印象。
            fire(3);                                  // ⭐ 先起音（vel=64 ⇒ 16384）
            repeat (50) tick();                       // 走 50 拍 ⇒ 一定在衰减中
            chk("retrigger: instrument 3 is ringing after a fresh trigger (precondition)",
                active[3] === 1'b1);
            chk("retrigger: it has already decayed below the peak",
                lv3 < 16'd16384);

            cnt_before = retrig_cnt[3*16 +: 16];
            fire(3);                                  // ⭐ 衰减中再次触发
            @(negedge clk);
            chk("retrigger: level jumps back to the peak", lv3 === 16'd16384);
            chk("retrigger: still active", active[3] === 1'b1);
            chk("retrigger: the retrigger COUNT is observable and incremented (K-106 style)",
                retrig_cnt[3*16 +: 16] === (cnt_before + 1));
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑨ 触发**不受 sample_tick 约束**（不许因为"离下一个 tick 还早"而丢）
        // ═══════════════════════════════════════════════════════════════════
        begin : async_fire
            // 先让所有乐器停干净
            repeat (1200) tick();
            chk("async fire: all instruments finished before this test",
                active === 4'b0000);
            // ⭐ 在**两个 sample_tick 正中间**触发（⛔ 不给任何 tick）
            @(negedge clk);
            trigger[0] = 1'b1;
            @(negedge clk);
            trigger[0] = 1'b0;
            @(negedge clk);
            // ⭐ 没有发过 sample_tick ⇒ 若实现把触发塞进 tick 分支，这里会是 0
            chk("async fire: a trigger BETWEEN sample ticks is NOT lost (level = peak)",
                lv0 === 16'd51200);
            chk("async fire: active_o set without any sample_tick", active[0] === 1'b1);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑩ ⭐⭐ 力度**在起音时刻锁存**（⛔ 不是实时跟随）
        //    🔴 这一条是**变异体 `M55` 暴露出来的盲区**：它把 `peak_r` 打成 0，
        //       而我原来的 tb **全过** —— 因为当时 `peak_r` **根本没被读**（死状态）。
        //    ⭐ 现在 `peak_r` 真的参与装载，本节判据**专测这条语义**：
        //       ⭐ 触发后**改变 `velocity`**，那个音的**峰值不许变**
        //          （同冻结表 §二 `K-82`：起音时锁存音色 —— 这里是锁存力度）
        // ═══════════════════════════════════════════════════════════════════
        begin : vel_latch
            // 先让所有乐器停干净
            repeat (1200) tick();
            chk("velocity latch: clean slate before this test", active === 4'b0000);

            velocity[0*VEL_W +: VEL_W] = 8'd200;     // 峰值应为 51200
            fire(0);
            chk("velocity latch: peak loaded from velocity at trigger time",
                lv0 === 16'd51200);

            // ⭐⭐ 关键：**在音还在响的时候把力度改掉**
            repeat (100) tick();
            velocity[0*VEL_W +: VEL_W] = 8'd255;     // 若"实时跟随" ⇒ 会跳到 65280
            repeat (10) tick();
            chk("velocity latch: changing velocity MID-NOTE does NOT change the ringing peak",
                lv0 <= 16'd51200);
            chk("velocity latch: the note keeps decaying from its ORIGINAL peak",
                lv0 < 16'd51200 && lv0 > 16'd0);

            // ⭐ 而且**下一次**触发必须用**新**力度（⇒ 锁存的是"每次触发那一刻"的值）
            repeat (1200) tick();
            chk("velocity latch: previous note finished", active[0] === 1'b0);
            fire(0);
            chk("velocity latch: the NEXT trigger picks up the NEW velocity (255 => 65280)",
                lv0 === 16'd65280);
        end

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: perc_env_bank one-shot decay (peak / monotonic / exact length / active clears / independent / retriggerable)");
        else
            $display("FAIL: perc_env_bank had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`：没有结论必须算失败）
    initial begin
        #200_000_000;
        $fatal(1, "FAIL: tb_perc_env_bank timeout");
    end

endmodule
