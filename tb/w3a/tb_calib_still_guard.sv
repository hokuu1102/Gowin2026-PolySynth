`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib_still_guard.sv · 「修 A」新行为的 5 条同类路径判据
//
// ⭐ 被测：`rtl/w3a/calib_autotare.v`（静止守卫 + clk 超时 + 'T' 同守卫）
//         `rtl/drivers/calib.sv`  （标定值水位闸 zero_vld/gain_vld/span_vld）
//
// ⭐⭐ 为什么需要它：⭐ 修 A 改了这两块，但**新行为【没有判据】**
//    —— 只有"既有 tb 没回归"＋"综合 0 ERROR" ⇒ ⭐ 按 `0.12`：
//    **判据数量必须 == 同类路径数量** ⇒ ⭐ 缺这 5 条。
//
// ⭐ 5 条判据（⭐ 每条都配了能先红的变异锚点）
//    1  静止守卫：⭐ 帧间 `raw` 在【变化】时不得捕获该轴
//    1b `'T'` 重标走【同一守卫】（⭐ 必须先重新确认静止）
//    1c 超时用【clk】计数（⭐ ADC 停流也能到期，⛔ 不是帧计数）
//    2  逻辑复位后的可观测输出 == 冷启动后（⭐ 三个位图复位）
//    2b 数组直读被水位闸挡住（⭐ 位图 = 0 时必须用默认值，⛔ 不看数组内容）
//
// ⚠️⚠️ **诚实标注（⭐ 很重要，别误读判据 1）**：
//    静止守卫的实际契约是「⭐ **帧间读数在变化时不捕获**」，
//    ⛔ **它【不能】区分"按住的键"与"松开的键"** ——
//    ⭐ 若某个键被【完全静止地按住】，守卫会判定"静止"并照样捕获 ⚠️。
//    ⇒ ⭐ 判据 1 只能按【变化】来打（⭐ 这也是唯一能被变异 M1 打红的形态）。
//    📌 "按住键时不该记零点"这条**不在本守卫的能力范围内** ——
//       ⭐ 现场对它的手段是「先插板再上电」/「发 `'T'` 时手离开键盘」。
//
// ⛔ 本文件**未运行**过（⭐ 由上级 agent 跑）· ⛔ 未改 `rtl/`/`constr/`
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_calib_still_guard;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 时钟 / 记账
    // ═══════════════════════════════════════════════════════════════════════
    reg clk = 1'b0;
    always #5 clk = ~clk;                    // ⭐ 10 ns 周期

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check;
        input integer      cond;
        input [1023:0]     msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("ok  : %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // DUT A · `calib_autotare`（⭐ 判据 1 / 1b）
    //   ⭐ `DELAY_CLK=8` 让上电等待只 8 拍；⭐ `WAIT_MS=100000` + `CLK_HZ=1000`
    //      ⇒ ⭐ `WAIT_KHZ = (1000+999)/1000 = 1` ⇒ `WAIT_CLK = 100000` 拍
    //      ⇒ ⭐ **超时足够远**（⛔ 不会在判据 1 的时间尺度内触发）
    //   ⚠️ 为什么不用 `CLK_HZ=50_000_000`：⭐ 那会让 `WAIT_CLK = 5e7` 拍
    //      ⇒ ⭐ 仿真跑不完（⭐ 而 `WAIT_MS` 调小又会让超时提前触发）
    // ═══════════════════════════════════════════════════════════════════════
    reg         rst_n_a = 1'b0;
    reg         sv_a    = 1'b0;
    reg  [2:0]  sch_a   = 3'd0;
    reg  [11:0] sd_a    = 12'd0;
    reg         rt_a    = 1'b0;
    wire [0:0]  tare_a;
    wire [2:0]  cch_a;
    wire [3:0]  skip_a;
    wire        fail_a;
    wire        busy_a;
    wire        done_a;

    calib_autotare #(
        .NCH(4), .N_ADC(1), .DELAY_CLK(8),
        .STILL_EN(1), .DW(12), .STILL_TOL(8), .STILL_FRAMES(4),
        .WAIT_MS(100000), .CLK_HZ(1000)
    ) u_at_guard (
        .clk(clk), .rst_n(rst_n_a),
        .sample_valid_i(sv_a), .sample_ch_i(sch_a), .sample_data_i(sd_a),
        .retrig_i(rt_a),
        .tare_o(tare_a), .cal_ch_o(cch_a),
        .skip_mask_o(skip_a), .fail_o(fail_a),
        .busy_o(busy_a), .done_o(done_a)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // DUT B · `calib_autotare`（⭐ 判据 1c：超时必须用 clk 计数）
    //   ⭐ `WAIT_MS=5` + `CLK_HZ=1000` ⇒ ⭐ `WAIT_CLK = 5` 拍 ⇒ **5 拍就超时**
    // ═══════════════════════════════════════════════════════════════════════
    reg         rst_n_b = 1'b0;
    reg         sv_b    = 1'b0;
    reg  [2:0]  sch_b   = 3'd0;
    reg  [11:0] sd_b    = 12'd0;
    wire [0:0]  tare_b;
    wire [2:0]  cch_b;
    wire [3:0]  skip_b;
    wire        fail_b;
    wire        busy_b;
    wire        done_b;

    calib_autotare #(
        .NCH(4), .N_ADC(1), .DELAY_CLK(8),
        .STILL_EN(1), .DW(12), .STILL_TOL(8), .STILL_FRAMES(4),
        .WAIT_MS(5), .CLK_HZ(1000)
    ) u_at_to (
        .clk(clk), .rst_n(rst_n_b),
        .sample_valid_i(sv_b), .sample_ch_i(sch_b), .sample_data_i(sd_b),
        .retrig_i(1'b0),
        .tare_o(tare_b), .cal_ch_o(cch_b),
        .skip_mask_o(skip_b), .fail_o(fail_b),
        .busy_o(busy_b), .done_o(done_b)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // DUT C · `calib`（⭐ 判据 2 / 2b：标定值水位闸）
    // ═══════════════════════════════════════════════════════════════════════
    reg         rst_n_c = 1'b0;
    reg         v_c     = 1'b0;
    reg  [2:0]  ch_c    = 3'd0;      // ⭐ NCH=2 ⇒ CW=3
    reg  [11:0] raw_c   = 12'd0;
    reg         tare_c  = 1'b0;
    reg         span_c  = 1'b0;
    reg  [2:0]  calch_c = 3'd0;
    wire        busy_c;
    wire        err_c;
    wire        ov_c;
    wire [2:0]  oc_c;
    wire [11:0] ovv_c;

    calib #(
        .NCH(2), .DW(12), .RAW_MEDIAN_EN(0)
    ) u_cal (
        .clk(clk), .rst_n(rst_n_c),
        .valid(v_c), .ch(ch_c), .raw(raw_c),
        .tare(tare_c), .span(span_c), .cal_ch(calch_c),
        .busy(busy_c), .err(err_c),
        .out_valid(ov_c), .out_ch(oc_c), .out_val(ovv_c)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 激励任务
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 给 DUT A 送【一个采样脉冲】（⭐ 该通道一帧）
    task automatic pulse_a;
        input [2:0]  ch_v;
        input [11:0] raw_v;
        begin
            @(negedge clk);
            sv_a  = 1'b1;  sch_a = ch_v;  sd_a = raw_v;
            @(negedge clk);
            sv_a  = 1'b0;
        end
    endtask

    //   ⭐ 给 DUT B 送【一个采样脉冲】
    task automatic pulse_b;
        input [2:0]  ch_v;
        input [11:0] raw_v;
        begin
            @(negedge clk);
            sv_b  = 1'b1;  sch_b = ch_v;  sd_b = raw_v;
            @(negedge clk);
            sv_b  = 1'b0;
        end
    endtask

    //   ⭐ 给 DUT C 送一个采样（⭐ `calib` 的输出延 1 拍 ⇒ 本任务已含那一拍）
    task automatic feed_c;
        input [2:0]  ch_v;
        input [11:0] raw_v;
        begin
            @(negedge clk);
            v_c = 1'b1;  ch_c = ch_v;  raw_c = raw_v;
            @(negedge clk);
            v_c = 1'b0;
        end
    endtask

    //   ⭐ 记录 DUT A 对【每个轴】是否发过 `tare`
    //   ⚠️ `tare_o`/`cal_ch_o` 是【寄存器输出】⇒ 置位后保持 1 拍
    //      ⇒ ⭐ 在下一个 posedge 采样它，能稳定抓到（⭐ 见下方时序说明）
    reg hit_a0 = 1'b0;
    reg hit_a1 = 1'b0;
    reg hit_a2 = 1'b0;
    reg hit_a3 = 1'b0;
    always @(posedge clk) begin
        if (tare_a != 1'b0) begin
            case (cch_a)
                3'd0: hit_a0 <= 1'b1;
                3'd1: hit_a1 <= 1'b1;
                3'd2: hit_a2 <= 1'b1;
                3'd3: hit_a3 <= 1'b1;
                default: ;
            endcase
        end
    end

    //   ⭐ 记录 DUT B：⭐ 必须先【看到它进过 SWEEP】再看它【离开】——
    //   🔴 否则判据 1c 是**空洞的**：⭐ 复位刚放开时 `busy_b` 本来就是 0
    //      （⭐ 状态机还在 `ST_WAIT`）⇒ ⚠️ "离开 SWEEP"当场成立 ⚠️
    integer tare_b_cnt      = 0;
    reg     b_saw_sweep     = 1'b0;
    reg     b_left_sweep    = 1'b0;
    always @(posedge clk) begin
        if (tare_b != 1'b0) tare_b_cnt <= tare_b_cnt + 1;
        if (busy_b == 1'b1) b_saw_sweep <= 1'b1;
        if (b_saw_sweep == 1'b1 && busy_b == 1'b0) b_left_sweep <= 1'b1;
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════════
    integer i;
    reg [11:0] s_cold;
    reg [11:0] s_rst;

    initial begin
        $display("=== tb_calib_still_guard : the 5 same-class criteria for fix A ===");

        // ── 复位（⭐ 两个 DUT 都是【同步复位】⇒ 必须跨过 posedge）──────────
        rst_n_a = 1'b0;  rst_n_b = 1'b0;  rst_n_c = 1'b0;
        repeat (4) @(posedge clk);
        rst_n_a = 1'b1;  rst_n_b = 1'b1;  rst_n_c = 1'b1;
        repeat (2) @(posedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据 1：帧间 `raw` 在【变化】时不得捕获该轴
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 做法：⭐ 对 ch0 交替送两个相差 100 的码（⭐ ≫ STILL_TOL=8）
        //           ⇒ ⭐ 永远不满足"连续 4 帧静止" ⇒ ⭐ ch0 **不得**被捕获
        //           ⭐ 同时对其余通道送【恒定】码 ⇒ ⭐ 它们【应该】被捕获
        //   ⭐ 为什么必须有"其余通道被捕获"这一半：⭐ 否则判据是**空洞的**
        //      （⭐ 守卫若把【所有】通道都拒绝，ch0 不捕获也照样"通过"）
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 先让状态机走过 `DELAY_CLK=8` ⇒ 进 `ST_SWEEP`
        repeat (12) @(posedge clk);

        //   ⭐ 20 帧：ch0 变化、ch1/2/3 静止
        for (i = 0; i < 20; i = i + 1) begin
            pulse_a(3'd0, (i % 2) ? 12'd1100 : 12'd1000);   // ⭐ 变化 ⇒ 不静止
            pulse_a(3'd1, 12'd800);                          // ⭐ 恒定 ⇒ 静止
            pulse_a(3'd2, 12'd800);
            pulse_a(3'd3, 12'd800);
        end
        repeat (4) @(posedge clk);

        check(hit_a0 == 1'b0,
              "C1 the axis whose raw CHANGES every frame is NEVER captured (still-guard works)");
        //   ⭐⭐ 2026-09-30 修（⭐ tb 自身的场景错，⛔ 不是 RTL）：
        //      🔴 原来这里断言 `hit_a1 & hit_a2 & hit_a3 == 1` —— **那个场景达不到** ⚠️
        //      ⭐ 因为 `calib_autotare` 的 `cur_ch` **从 0 开始**，⭐ 且**只在"捕获成功"或"超时"时推进**
        //         （⭐ 见 `calib_autotare.v:229-263` 的 `ST_SWEEP`：⭐ 两条出边都带 `cur_ch <= cur_ch + 1` ✅）
        //      ⇒ ⭐ ch0 一直变化 ⇒ **永远不捕获 ch0** ⇒ ⭐ `cur_ch` 永远停在 0
        //      ⇒ ⭐ **状态机永远到不了 ch1/2/3** ⇒ ⭐ `hit_a1/2/3` **恒为 0** ✅
        //      ⇒ ⭐ 所以本阶段【正确】的断言是：⭐ **它被卡在"变化的那根轴"上** ✅
        //      ⭐ 而"静止的轴确实被捕获"（⭐ 非空洞性）在【下一阶段】证明 —— ⭐ 见下面 `C1n` ✅
        check(hit_a1 == 1'b0 && hit_a2 == 1'b0 && hit_a3 == 1'b0,
              "C1 the FSM is BLOCKED on the changing axis, so the later axes are not reached either (cur_ch only advances on capture or timeout)");
        check(skip_a == 4'b0000,
              "C1 no axis was timed out (WAIT_CLK is far away => the guard, not the timeout, did the work)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据 1b：`'T'` 重标走【同一守卫】
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 做法：① 先把这一轮跑完（⭐ 所有通道静止 ⇒ 全部捕获 ⇒ 进 DONE）
        //           ② 再让 ch0 的 `raw` **变化** ⇒ 发 `retrig_i`
        //           ③ ⭐ 断言：重标后 ch0 **仍不得**被捕获
        //   🔴 若 `ST_DONE` 忘了清 `still_cnt` ⇒ ⭐ 它已饱和 ⇒ 重标**当场捕获**
        // ═══════════════════════════════════════════════════════════════════
        //   ① 让全部通道静止 ⇒ 走完 ⇒ DONE（⭐ 每通道需 5 个连续静止样本）
        hit_a0 = 1'b0;                       // ⭐ 清掉判据 1 的记录，单独看 1b
        for (i = 0; i < 40 && done_a == 1'b0; i = i + 1) begin
            pulse_a(3'd0, 12'd500);  pulse_a(3'd1, 12'd800);
            pulse_a(3'd2, 12'd800);  pulse_a(3'd3, 12'd800);
        end
        check(done_a == 1'b1, "C1b round 1 finished => done_o asserted (all axes captured)");
        //   ⭐⭐ 2026-09-30 新增（⭐ 从判据 1 移过来）：⭐ **非空洞性** ——
        //      ⭐ 守卫若"把所有轴都拒绝"，⭐ `done_a` 也可能因为【超时】而为 1 ⚠️
        //      ⇒ ⭐ 必须显式断言：⭐ **静止的那三根轴【确实被捕获了】** ✅
        //      ⭐ 本阶段所有通道都是恒定码 ⇒ ⭐ `cur_ch` 能一路推进到 3 ✅
        check(hit_a1 == 1'b1 && hit_a2 == 1'b1 && hit_a3 == 1'b1,
              "C1n NON-VACUOUS: with ALL axes steady, the steady axes really WERE captured (the guard is not rejecting everything)");

        //   ② ch0 改成【变化】⇒ 重标
        hit_a0 = 1'b0;
        @(negedge clk);  rt_a = 1'b1;
        @(negedge clk);  rt_a = 1'b0;
        for (i = 0; i < 20; i = i + 1) begin
            pulse_a(3'd0, (i % 2) ? 12'd1100 : 12'd1000);   // ⭐ 变化
            pulse_a(3'd1, 12'd800);  pulse_a(3'd2, 12'd800);  pulse_a(3'd3, 12'd800);
        end
        repeat (4) @(posedge clk);

        check(hit_a0 == 1'b0,
              "C1b after 'T' the CHANGING axis is still NOT captured (retrig re-runs the same guard)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据 1c：超时用【clk】计数 ⇒ ADC 停流也能到期
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 做法：⭐ 进 `ST_SWEEP` 后【完全停掉 `sample_valid_i`】
        //           ⇒ ⭐ 帧计数永不递增；⭐ clk 计数照样走
        //           ⇒ ⭐ `WAIT_CLK=5` 拍后必须离开 `ST_SWEEP`
        //   🔴 若超时改成帧计数 ⇒ ⭐ **永不到期** ⇒ 永远停在 `ST_SWEEP`
        // ═══════════════════════════════════════════════════════════════════
        //   🔴 **必须先把它重新复位** —— ⚠️ 因为在判据 1/1b 那几十拍里，
        //      `u_at_to`（⭐ `WAIT_MS=5`）**早就自己跑完一轮并超时了** ⚠️
        //      ⇒ ⭐ 若不清零重来，`b_saw_sweep`/`b_left_sweep` 早已是 1
        //      ⇒ 🔴 **判据 1c 会变成空洞的**（⭐ 这正是我自查时抓到的第二个 bug）
        rst_n_b = 1'b0;
        repeat (4) @(posedge clk);
        b_saw_sweep  = 1'b0;
        b_left_sweep = 1'b0;
        tare_b_cnt   = 0;
        rst_n_b = 1'b1;
        //   ⭐ 关键：⭐ 从此【一个 sample_valid_i 都不发】（⭐ 模拟 ADC 停流）
        //      ⇒ ⭐ 帧计数永不递增；⭐ clk 计数照样走
        repeat (40) @(posedge clk);          // ⭐ 40 拍 ≫ WAIT_CLK=5
        check(b_saw_sweep == 1'b1,
              "C1c the FSM really entered ST_SWEEP (precondition: the criterion is not vacuous)");
        check(b_left_sweep == 1'b1,
              "C1c with the ADC STOPPED the per-axis timeout still expires (clk-based, not frame-based)");
        check(tare_b_cnt == 0,
              "C1c and it expires WITHOUT emitting any tare (a skipped axis is not silently calibrated)");
        check(fail_b == 1'b1,
              "C1c the skip is made observable (fail_o asserted, not silent)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据 2：逻辑复位后的可观测输出 == 冷启动后
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 冷启动侧（⭐ 本 tb 刚复位过 ⇒ 位图全 0）：
        //        ⭐ `raw=500` ⇒ `zero_eff=0`、`gain_eff=256` ⇒ `out = min(500, MAX_TRAVEL)`
        //   ⭐ 复位侧：⭐ 先做一次 `tare`（⭐ `zero_r[0]=100`、`zero_vld[0]=1`）
        //        ⇒ ⭐ 此时 `raw=500` 应给 `400`（⭐ 证明水位闸**置位后确实生效**）
        //        ⇒ ⭐ **再拉一次逻辑复位** ⇒ ⭐ 位图被清 ⇒ ⭐ 应回到冷启动的值
        // ═══════════════════════════════════════════════════════════════════
        feed_c(3'd0, 12'd500);
        #2;  s_cold = ovv_c;
        check(s_cold == 12'd500,
              "C2 cold start: an UN-calibrated axis uses the default zero (out = raw, no offset)");

        //   ⭐ 做一次 `tare`：⭐ 让 raw=100 出现在输入端
        feed_c(3'd0, 12'd100);
        @(negedge clk);  tare_c = 1'b1;  calch_c = 3'd0;
        @(negedge clk);  tare_c = 1'b0;
        feed_c(3'd0, 12'd500);
        #2;
        check(ovv_c == 12'd400,
              "C2 after tare the offset IS applied (out = raw - zero = 400) -- the water-mark can be raised");

        //   ⭐ 逻辑复位（⭐ 只拉 rst_n，⛔ 不断电）
        rst_n_c = 1'b0;
        repeat (4) @(posedge clk);
        rst_n_c = 1'b1;
        repeat (2) @(posedge clk);
        feed_c(3'd0, 12'd500);
        #2;  s_rst = ovv_c;
        check(s_rst == s_cold,
              "C2 LOGIC RESET == COLD START: the water-mark bitmaps are cleared by reset");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据 2b：数组直读被水位闸挡住
        // ═══════════════════════════════════════════════════════════════════
        //   🔴 **为什么不用 `force`**：⭐ iverilog 明确拒绝
        //      `cannot %force/vec4 to the word of a variable array (zero_r[1])`
        //      ⇒ ⭐ `force` **未打包数组元素**在这套工具链里不可用 ✅
        //
        //   ⭐ 改用【RTL 自己的行为】造出"数组有内容但位图=0"：
        //     ① ⭐ 对 ch1 做一次 `tare`（⭐ 让 `raw=777` 出现在输入端）
        //        ⇒ ⭐ `zero_r[1]=777`、`zero_vld[1]=1`
        //     ② ⭐ 喂 `raw=500` ⇒ ⭐ 期望 `out = 0`
        //        （⭐ `500 < 777` ⇒ ⭐ 下溢守卫给 0）
        //        ⇒ ⭐ **这一步是前置判据**：⭐ 证明 `tare` 真的生效了 ✅
        //     ③ ⭐ 拉一次**逻辑复位**（⭐ 只拉 `rst_n`）
        //        ⇒ ⭐ `zero_vld[1]` 被清成 0 ✅
        //        ⇒ ⭐ 而 `zero_r[1]` **仍然是 777** ✅（⭐ RTL **故意不清数组** ——
        //           ⭐ 这正是水位闸的设计前提 ✅）
        //     ④ ⭐ 喂 `raw=500` ⇒ ⭐ 期望 `out = 500`（⭐ 用**默认零点 0** ✅）
        //
        //   🔴 **若某处把读改回 `zero_r[ch]` 直读** ⇒ ⭐ `out = 0`（⭐ 下溢）⇒ **变红** ✅
        //   ⭐ 这条**同时**证明了两件事：
        //      · ⭐ 复位**不清**数组（⭐ 旧内容真的还在 ✅）
        //      · ⭐ 水位闸**挡住了**旧内容（⭐ 读侧走默认值 ✅）
        // ═══════════════════════════════════════════════════════════════════
        feed_c(3'd1, 12'd777);
        @(negedge clk);  tare_c = 1'b1;  calch_c = 3'd1;
        @(negedge clk);  tare_c = 1'b0;

        // ② ⭐ 前置判据：⭐ tare 生效 ⇒ 500 < 777 ⇒ 下溢 ⇒ out = 0
        feed_c(3'd1, 12'd500);
        #2;
        check(ovv_c == 12'd0,
              "C2b precondition: after tare(zero=777) the offset IS applied (500 < 777 => underflow => 0)");

        // ③ ⭐ 逻辑复位：⭐ 位图被清，⭐ 数组【不清】
        rst_n_c = 1'b0;
        repeat (4) @(posedge clk);
        rst_n_c = 1'b1;
        repeat (2) @(posedge clk);

        // ④ ⭐ 判据：⭐ 旧内容 777 还在数组里，⭐ 但读侧必须走默认零点
        feed_c(3'd1, 12'd500);
        #2;
        check(ovv_c == 12'd500,
              "C2b an UN-calibrated channel IGNORES the stale array content (water-mark gates the read)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 汇总
        // ═══════════════════════════════════════════════════════════════════
        $display("==================================================================");
        $display("tb_calib_still_guard: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt != 0) begin
            $display("FAIL: tb_calib_still_guard has %0d error(s)", fail_cnt);
            $fatal(1);
        end
        $display("PASS: still-guard / clk-timeout / 'T'-guard / water-mark / no-direct-read");
        $finish;
    end

    // ⭐ 兜底超时（⛔ 防仿真挂死）
    initial begin
        #2_000_000;
        $display("FAIL: tb_calib_still_guard TIMEOUT (simulation did not finish)");
        $fatal(1);
    end

endmodule

`default_nettype wire
