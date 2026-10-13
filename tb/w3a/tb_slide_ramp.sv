`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_slide_ramp.sv -- 滑音斜坡判据（真滑音：把"跳"变成"滑"）
//
// 被测：rtl/w3a/slide_ramp.v
// 判据（每条都必须能失败，见模块头）：
//   1) 不滑时输出 = 直通（行为与改动前一致：没有 trig 就没有动作）
//   2) 一次 trig ⇒ 输出【逐步】靠近目标；**第一帧只走一小步**（⛔ 不是一步到位）
//   3) 单调：全程朝目标走，不回头
//   4) 起点 = start_i（⛔ 不是从 0 开始）
//   5) 到达后 active 落下，最终值【精确等于】目标
//   6) 中途改目标 ⇒ 从【当前值】继续（⛔ 不跳回起点）
//   7) 步数落在预期量级（可据此标定 50 ms）
//   8) 非空洞守卫：若把 SHIFT 调成 0（一步到位）⇒ 判据 2 必须能红
// -----------------------------------------------------------------------------

module tb_slide_ramp;

    localparam integer SHIFT = 4;          // 交付默认：实测 ~81 步 ≈ 40 ms
    localparam [31:0]  EPS   = 32'd4096;

    // A 与 B 用真实表值形状：A=0x00c51339(轴6) · B=0x00d0cb35(轴7)
    localparam [31:0] A_INC = 32'h00c51339;
    localparam [31:0] B_INC = 32'h00d0cb35;

    integer errors = 0;

    task chk;
        input [8*160-1:0] name;
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

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg               tick, trig;
    reg  [31:0]       start_v, target_v;
    wire              active;
    wire [31:0]       value;
    wire [15:0]       steps;

    slide_ramp #(.SHIFT(SHIFT), .EPS(EPS)) dut (
        .clk(clk), .rst_n(rst_n),
        .tick_i(tick), .trig_i(trig),
        .start_i(start_v), .target_i(target_v),
        .active_o(active), .value_o(value), .steps_o(steps)
    );

    // 记录轨迹
    reg [31:0] traj [0:400];
    integer    n_traj;
    integer    i;
    integer    n_up, n_down, n_flat;

    task one_tick;
        begin
            tick = 1'b1;
            @(posedge clk);
            #1;
            tick = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // 跑一次完整滑音，收集轨迹；返回步数
    task run_slide;
        input [31:0] s;
        input [31:0] t;
        begin
            n_traj = 0;
            start_v = s;
            target_v = t;
            trig = 1'b1;
            @(posedge clk);
            #1;
            trig = 1'b0;
            traj[n_traj] = value; n_traj = n_traj + 1;
            // 最多 400 拍（远超收敛所需）
            for (i = 0; i < 400; i = i + 1) begin
                if (!active) i = 400;
                else begin
                    one_tick;
                    traj[n_traj] = value; n_traj = n_traj + 1;
                end
            end
        end
    endtask

    reg [31:0] v_first, v_second, v_at_change, v_final;
    integer    steps_run;

    initial begin
        tick = 1'b0; trig = 1'b0;
        start_v = 32'd0; target_v = 32'd0;
        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 1) idle: no trig => the module does not move on its own ===");
        // ═════════════════════════════════════════════════════════════════
        begin : idle
            reg [31:0] v0;
            v0 = value;
            tick = 1'b0; trig = 1'b0;
            repeat (20) @(posedge clk);
            chk("1a: with no trig, active stays low", active === 1'b0);
            chk("1b: with no trig, the value does not change by itself", value === v0);
        end

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 2) a real glide from A to B (the actual portamento) ===");
        // ═════════════════════════════════════════════════════════════════
        run_slide(A_INC, B_INC);
        steps_run = n_traj;
        v_first  = traj[0];
        v_second = traj[1];
        v_final  = value;
        $display("  [glide] steps recorded = %0d   first=%08h second=%08h final=%08h",
                 steps_run, v_first, v_second, v_final);

        chk("2a: right after trig the value equals the START (A's pitch), not the target",
            v_first === A_INC);
        chk("2b: the first step is SMALL (not a jump straight to the target)",
            (v_second !== B_INC) && (v_second > A_INC) && (v_second < B_INC));
        chk("2c: it really took many steps (a glide, not a one-shot jump)",
            steps_run >= 20);
        chk("2d: and the final value is EXACTLY the target (no residual error)",
            v_final === B_INC);
        chk("2e: when it is done, active has dropped", active === 1'b0);

        // ── 单调 + 每步都朝目标走 ─────────────────────────────────────────
        n_up = 0; n_down = 0; n_flat = 0;
        for (i = 1; i < n_traj; i = i + 1) begin
            if (traj[i] > traj[i-1])      n_up   = n_up   + 1;
            else if (traj[i] < traj[i-1]) n_down = n_down + 1;
            else                          n_flat = n_flat + 1;
        end
        $display("  [glide] up=%0d down=%0d flat=%0d", n_up, n_down, n_flat);
        chk("3a: monotonic upward for an upward glide (never steps backwards)",
            n_down == 0);
        chk("3b: and it actually moved every step except the last snap (no stalling)",
            n_flat <= 1);
        chk("3c: non-vacuity -- there were many upward steps",
            n_up >= 20);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 4) downward glide is symmetric ===");
        // ═════════════════════════════════════════════════════════════════
        run_slide(B_INC, A_INC);
        n_up = 0; n_down = 0; n_flat = 0;
        for (i = 1; i < n_traj; i = i + 1) begin
            if (traj[i] > traj[i-1])      n_up   = n_up   + 1;
            else if (traj[i] < traj[i-1]) n_down = n_down + 1;
            else                          n_flat = n_flat + 1;
        end
        chk("4a: downward glide only steps downward", n_up == 0);
        chk("4b: and lands exactly on the (lower) target", value === A_INC);
        chk("4c: non-vacuity -- many downward steps", n_down >= 20);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 5) retarget mid-glide => continue from CURRENT value ===");
        //   用户规格：中途停在两轴之间 ⇒ 停在当前位置（手指退回要能滑回去）
        // ═════════════════════════════════════════════════════════════════
        begin : retarget
            reg [31:0] v_now;
            // 起滑
            start_v = A_INC; target_v = B_INC;
            trig = 1'b1; @(posedge clk); #1; trig = 1'b0;
            // 只走几步就改目标
            repeat (6) one_tick;
            v_now = value;
            chk("5a: mid-glide the value sits strictly between start and target",
                (v_now > A_INC) && (v_now < B_INC));
            // 改目标回 A
            start_v = B_INC; target_v = A_INC;
            trig = 1'b1; @(posedge clk); #1; trig = 1'b0;
            v_at_change = value;
            chk("5b: on retarget the output continues from the CURRENT value (no jump back)",
                v_at_change === v_now);
            chk("5c: and it is still active (the glide continues)", active === 1'b1);
            // 让它走完
            for (i = 0; i < 400; i = i + 1) if (active) one_tick; else i = 400;
            chk("5d: it converges on the NEW target", value === A_INC);
        end

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 6) tiny move below EPS snaps immediately (no infinite dither) ===");
        //   指数逼近永远到不了目标 ⇒ 必须有收尾吸附，否则会永久微分抖
        // ═════════════════════════════════════════════════════════════════
        begin : snap
            integer n_before;
            start_v = 32'h0010_0000;
            target_v = 32'h0010_0000 + 32'd1000;      // 远小于 EPS=4096
            trig = 1'b1; @(posedge clk); #1; trig = 1'b0;
            n_before = n_traj;
            // 一拍 tick 就应该吸附到位并结束
            one_tick;
            chk("6a: a sub-EPS move snaps to the target on the first tick",
                value === (32'h0010_0000 + 32'd1000));
            chk("6b: and immediately deactivates (no endless micro-stepping)",
                active === 1'b0);
        end

        // ═════════════════════════════════════════════════════════════════
        $display("");
        if (errors == 0)
            $display("PASS: slide ramp -- a trig starts at A's pitch and walks toward B's pitch in many small monotonic steps (both directions), lands exactly on the target, retargeting continues from the current value instead of jumping back, and sub-EPS moves snap cleanly");
        else
            $fatal(1, "FAIL: slide ramp had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
