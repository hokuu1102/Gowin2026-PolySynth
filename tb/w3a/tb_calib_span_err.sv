`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib_span_err.sv · 【阶段 3】三条判据
//
//   ⭐ 背景（2026-09-30）：`calib_span` 的 `err` 处理改了两处 ——
//      ① `top.v` 把 `.cal_err_i` / `.cal_busy_i` 从"只接片 0"改成接**两片聚合**
//         （`cal_err_any = cal0_err | cal1_err`、`cal_busy_all = cal0_busy & cal1_busy`）
//         ⇒ ⭐ 板 2 的 span 失败**不再静默** ✅
//      ② `calib_span.v` 新增 `span_sent_r2`（`span_sent_r` 打一拍）⇒
//         ⭐ `S_NEXT` 判 `cal_err_i` 时看到的是**本轴**的 `err`，⛔ 不是上一轴的残留 ✅
//      ③ `calib.sv` 删掉了 err 分支里的 `gain_r <= 1.0`
//         ⇒ ⭐ 失败的重标定**不再清掉上次成功的增益** ✅
//
//   ⭐ 本 tb 用**真 `calib` 实例**产生 `busy`/`err`（⛔ 不编造）——
//      理由见 `tb_calib_span.sv:116-120`：`err` 分支**只置 err、不拉 busy**，
//      编造 `busy` 就永远测不到这条真路径。
//
//   📌 纪律：`calib_span` 是 Verilog-2001 ⇒ ⭐ 例化用 `.port(sig)`；
//            ⭐ 全程**时钟沿轮询**（⛔ 不用 `#delay` 去赌组合路径）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_calib_span_err;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数（⭐ 与 `tb_calib_span.sv` 同口径：⭐ 缩短 NEED 以加速）
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer NCH         = 8;
    localparam integer N_ADC       = 2;
    localparam integer AXIS_TOTAL  = 16;     // ⭐ = NCH × N_ADC（参数自检要求相等）
    localparam integer STABLE_NEED = 4;      // ⭐ 真值 24
    localparam integer VOTE_N      = 4;      // ⭐ 真值 32
    localparam integer REJECT_MAX  = 2;      // ⭐ 真值 8
    localparam [11:0]  STABLE_TOL  = 12'd8;  // ⭐ 与真值一致（语义关键）
    localparam [11:0]  VOTE_TOL    = 12'd16; // ⭐ 与真值一致（语义关键）

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 时钟 / 复位 / 激励
    // ═══════════════════════════════════════════════════════════════════════
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg         rst_n;
    reg         start_i;
    reg         abort_i;
    reg         sample_valid;
    reg  [2:0]  sample_ch;
    reg  [11:0] raw_in;

    wire [N_ADC-1:0] span_o;
    wire [2:0]       cal_ch_o;
    wire             busy_o;
    wire             done_o;
    wire [3:0]       cur_axis_o;
    wire             need_press_o;
    wire             reject_o;
    wire [3:0]       done_cnt_o;
    wire [2:0]       state_o;
    wire [3:0]       rej_cnt_o;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-09-30 修编译错：⭐ 下面这些信号【必须声明在 `u_dut` 例化之前】
    //
    //   🔴 原写法把它们放在 `:98` / `:119-120` / `:130` ⇒ iverilog 报：
    //      error: Unable to bind wire/reg/memory `cal_busy_i' in `tb_calib_span_err'
    //      :130:  : A symbol with that name was declared here. Check for declaration after use.
    //      error: Unable to bind wire/reg/memory `cal_err_i' ... (4 errors during elaboration)
    //
    //   📌 这是本项目踩过的老坑：⭐ **Verilog 里声明必须先于使用**
    //      （⭐ 同族见 `top.v` 里 `af0_pol` 那段注释：例化体必须放在 `af0_pol` 之后）
    //   ⭐ 修法：⭐ 只把【声明】上移；⛔ 逻辑（`always` / `assign`）留在原处不动 ✅
    // ═══════════════════════════════════════════════════════════════════════
    wire        cal_busy_w, cal_err_w;
    reg         force_err_mode;
    reg         cal_busy_sel, cal_err_sel;
    wire        cal_busy_i, cal_err_i;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ DUT：`calib_span`
    // ═══════════════════════════════════════════════════════════════════════
    calib_span #(
        .NCH        (NCH),
        .N_ADC      (N_ADC),
        .AXIS_TOTAL (AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED),
        .STABLE_TOL (STABLE_TOL),
        .VOTE_N     (VOTE_N),
        .VOTE_TOL   (VOTE_TOL),
        .REJECT_MAX (REJECT_MAX)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start_i       (start_i),
        .abort_i       (abort_i),
        .sample_valid_i(sample_valid),
        .sample_ch_i   (sample_ch),
        .raw_i         (raw_in),
        .span_o        (span_o),
        .cal_ch_o      (cal_ch_o),
        .cal_busy_i    (cal_busy_i),
        .cal_err_i     (cal_err_i),
        .busy_o        (busy_o),
        .done_o        (done_o),
        .cur_axis_o    (cur_axis_o),
        .need_press_o  (need_press_o),
        .reject_o      (reject_o),
        .done_cnt_o    (done_cnt_o),
        .state_o       (state_o),
        .rej_cnt_o     (rej_cnt_o)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 真 `calib` 实例（⭐ 挂在链上：⭐ 让 `busy`/`err` 由真模块产生）
    // ═══════════════════════════════════════════════════════════════════════
    reg         tare_chain;          // ⭐ 判据③ 需要预置某轴的零点

    calib #(.NCH(NCH), .DW(12), .RAW_MEDIAN_EN(0)) u_calib (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid    (sample_valid),
        .ch       (sample_ch),
        .raw      (raw_in),
        .tare     (tare_chain),
        .span     (span_o[0]),
        .cal_ch   (cal_ch_o),
        .busy     (cal_busy_w),
        .err      (cal_err_w),
        .out_valid(),
        .out_ch   (),
        .out_val  ()
    );

    //   ⭐ 判据① 要**人工强制** `err=1 && busy=0`（⭐ 模拟"片 1 失败"）
    //      ⇒ ⭐ 做成可切换：⭐ `force_err_mode=1` 时用 tb 的驱动值
    always @(*) begin
        if (force_err_mode) begin
            cal_busy_sel = 1'b0;     // ⭐ 真缺陷场景：busy 永不起
            cal_err_sel  = 1'b1;     // ⭐ 但 err 置起
        end else begin
            cal_busy_sel = cal_busy_w;
            cal_err_sel  = cal_err_w;
        end
    end
    assign cal_busy_i = cal_busy_sel;
    assign cal_err_i  = cal_err_sel;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 判据② 专用：⭐ 一个【独立可控】的 `calib` 实例
    //    ⭐ 用它复现"成功 span → 失败 span → 增益必须不变"
    // ═══════════════════════════════════════════════════════════════════════
    reg         rst_n2;
    reg         valid2;
    reg  [2:0]  ch2;
    reg  [11:0] raw2;
    reg         tare2, span2;
    reg  [2:0]  calch2;
    wire        busy2, err2;
    wire [11:0] outv2;

    calib #(.NCH(2), .DW(12), .RAW_MEDIAN_EN(0)) u_cal2 (
        .clk      (clk),
        .rst_n    (rst_n2),
        .valid    (valid2),
        .ch       (ch2),
        .raw      (raw2),
        .tare     (tare2),
        .span     (span2),
        .cal_ch   (calch2),
        .busy     (busy2),
        .err      (err2),
        .out_valid(),
        .out_ch   (),
        .out_val  (outv2)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 计数与检查
    // ═══════════════════════════════════════════════════════════════════════
    integer span_total, reject_total, errors, checks;

    always @(posedge clk) begin
        if (rst_n) begin
            if (span_o[0]) span_total   = span_total + 1;
            if (reject_o)  reject_total = reject_total + 1;
        end
    end

    task chk;
        input        cond;
        input [255:0] msg;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("  ok  : %0s", msg);
            end else begin
                errors = errors + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    // ⭐ 扫一帧：ch0..ch7，⭐ 每通道给【同一个值】⇒ ⭐ 帧间稳定
    task scan_frame_stable;
        input [11:0] base;
        integer c;
        begin
            for (c = 0; c < NCH; c = c + 1) begin
                @(negedge clk);
                sample_ch    = c[2:0];
                raw_in       = base;
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // ⭐ 复位 + 清状态
    task do_reset;
        begin
            rst_n          = 1'b0;
            start_i        = 1'b0;
            abort_i        = 1'b0;
            sample_valid   = 1'b0;
            sample_ch      = 3'd0;
            raw_in         = 12'h000;
            force_err_mode = 1'b0;
            tare_chain     = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ⭐ 复位（判据② 的独立 DUT）
    task do_reset2;
        begin
            rst_n2 = 1'b0;  valid2 = 1'b0;  ch2 = 3'd0;  raw2 = 12'd0;
            tare2  = 1'b0;  span2  = 1'b0;  calch2 = 3'd0;
            repeat (4) @(posedge clk);
            rst_n2 = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ⭐ 给判据② 的 DUT 喂一个采样（⭐ 等一个完整时钟周期）
    task feed2;
        input [2:0]  ch_v;
        input [11:0] raw_v;
        begin
            @(negedge clk);
            valid2 = 1'b1;  ch2 = ch_v;  raw2 = raw_v;
            @(negedge clk);
            valid2 = 1'b0;
        end
    endtask

    // ⭐ 等 `span_o` 脉冲（⭐ 带上限 ⇒ ⛔ 不挂死）
    task wait_span_pulse;
        input integer limit;
        integer k;
        reg     seen;
        begin
            seen = 1'b0;
            for (k = 0; k < limit; k = k + 1) begin
                @(posedge clk);
                if (span_o[0]) seen = 1'b1;
            end
            if (!seen) begin
                errors = errors + 1;
                $display("  FAIL: wait_span_pulse timed out (no span_o within %0d clk)", limit);
            end
        end
    endtask

    // ⭐ 等 `reject_o` 脉冲（⭐ 带上限）
    task wait_reject_pulse;
        input integer limit;
        integer k;
        reg     seen;
        begin
            seen = 1'b0;
            for (k = 0; k < limit; k = k + 1) begin
                @(posedge clk);
                if (reject_o) seen = 1'b1;
            end
            if (!seen) begin
                errors = errors + 1;
                $display("  FAIL: wait_reject_pulse timed out (no reject_o within %0d clk)", limit);
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════════
    integer r1, r2, r3, s1;

    initial begin
        $display("=== tb_calib_span_err （阶段 3 三条判据） ===");

        span_total = 0; reject_total = 0; errors = 0; checks = 0;
        force_err_mode = 1'b0; tare_chain = 1'b0;
        start_i = 1'b0; abort_i = 1'b0; sample_valid = 1'b0;
        sample_ch = 3'd0; raw_in = 12'h000;
        rst_n = 1'b0; rst_n2 = 1'b0;
        valid2 = 1'b0; ch2 = 3'd0; raw2 = 12'd0;
        tare2 = 1'b0; span2 = 1'b0; calch2 = 3'd0;
        do_reset();
        do_reset2();

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据①：⭐ `cal_err_i` 置起 ⇒ ⭐ 必须回 `'!'`（`reject_o` 脉冲）
        //   ⭐ 语义：⭐ 片 1（板 2）失败时，⭐ 顶层聚合线 `cal_err_any` 会置起
        //           ⇒ ⭐ `calib_span` **必须拒绝本轴**，⛔ 不许当成功 ✅
        //   ⭐ 非空洞前置：⭐ 必须**真的走到过 `S_FIRE`**（`span_o` 脉冲过）
        // ═══════════════════════════════════════════════════════════════════
        $display("--- 判据①：cal_err_i 置起 ⇒ 必须 reject ---");
        span_total = 0; reject_total = 0;
        start_i = 1'b1;  @(posedge clk);  start_i = 1'b0;
        chk(need_press_o === 1'b1, "A0 start_i raises need_press (the FSM really entered the sweep)");

        //   ⭐ 稳定帧：⭐ 轴 0 的通道是 ch0 ⇒ ⭐ 全通道同值即可（⭐ 每帧 ch0 都会被看到）
        //   ⚠️ 轴 0 的零点为 0 ⇒ ⭐ `raw=500 > 0` ⇒ ⭐ 真 `calib` 会**成功** ⇒
        //      所以必须在 `span` 脉冲【之后】再人工把 `err` 拉高（⭐ 模拟片 1 失败）
        for (r1 = 0; r1 < STABLE_NEED + 4; r1 = r1 + 1) scan_frame_stable(12'd500);
        for (r1 = 0; r1 < VOTE_N + 4;     r1 = r1 + 1) scan_frame_stable(12'd500);

        //   ⭐ 等 `span` 真的发出来（⭐ 证明走到了 S_FIRE ✅ 非空洞）
        //   ⚠️ **时序关键**：⭐ `cal_err_i` 必须在 `span` 脉冲那一拍就拉高 ——
        //      `span_o` 在 N 拍拉高 ⇒ `span_sent_r` 在 N 拍置位、`span_sent_r2` 在 N+1 拍置位
        //      ⇒ `S_NEXT` 在 **N+1** 拍判 `cal_err_i && span_sent_r2`
        //      ⇒ ⭐ 所以 N 拍拉高 `err`（组合）⇒ ⭐ N+1 拍它已经是 1 ✅
        //      🔴 若等到脉冲之后再拉，⭐ 状态机可能已经走过 `S_NEXT` ⇒ ⭐ 判据空洞 ⚠️
        s1 = span_total;
        r1 = reject_total;
        begin : poll_fire
            integer kk;
            for (kk = 0; kk < 400; kk = kk + 1) begin
                @(posedge clk);
                if (span_o[0]) begin
                    force_err_mode = 1'b1;   // ⭐ 同拍拉高（⭐ 组合 ⇒ N+1 拍可见）
                    kk = 400;                // ⭐ 跳出
                end
            end
        end
        chk(span_total > s1, "A1 the FSM really reached S_FIRE (span_o pulsed) -- non-vacuous");

        r1 = reject_total;
        wait_reject_pulse(200);
        chk(reject_total > r1, "A2 cal_err_i asserted after the pulse => the axis IS rejected (reject_o pulsed)");
        force_err_mode = 1'b0;

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据③：⭐ `err` 必须属于【本轴】—— ⭐ 失败后**重试同一轴**，
        //           ⭐ 第一次就必须被接受（⛔ 不被上一次的 `err` 连累）
        //   ⭐ 场景：⭐ FSM 失败后**不换轴**，⭐ 而是重试同一轴 ✅
        //      ⇒ ⭐ 陈旧 `err` 的真实暴露点就是"重试的第一次 S_NEXT" ✅
        //   🔴 变异：⭐ `span_sent_r2` → `span_sent_r` ⇒ ⭐ 重试的第一次看到陈旧的
        //            `err=1` ⇒ ⭐ 误拒 ⇒ ⭐ `reject_total` 多 1 ⇒ **变红** ✅
        // ═══════════════════════════════════════════════════════════════════
        $display("--- 判据③：err 必须属于本轴（失败后重试同一轴）---");
        do_reset();
        span_total = 0; reject_total = 0;

        //   ⭐ 预置：⭐ 轴 0 的零点 = 200（⭐ 用 `tare`，⭐ 此时 `raw_in` 必须 = 200）
        //      ⚠️ `tare` 用的是 `cal_ch`（⭐ 不是 `ch`）⇒ ⭐ 这里 `cal_ch_o` 由 DUT 驱动，
        //         但 `start_i` 之前它是复位值 0 ⇒ ⭐ 正好是轴 0 ✅
        raw_in = 12'd200;  @(negedge clk);
        tare_chain = 1'b1;
        @(negedge clk);    tare_chain = 1'b0;

        start_i = 1'b1;  @(posedge clk);  start_i = 1'b0;
        //   ① 轴 0 第一次：⭐ `raw=50 <= zero=200` ⇒ ⭐ 真 `calib` 走 **err 分支**
        //      ⇒ ⭐ `err=1`（⭐ 且 busy 不拉）⇒ ⭐ `calib_span` 必须**拒绝** ✅
        for (r2 = 0; r2 < STABLE_NEED + 4; r2 = r2 + 1) scan_frame_stable(12'd50);
        for (r2 = 0; r2 < VOTE_N + 4;     r2 = r2 + 1) scan_frame_stable(12'd50);
        r1 = reject_total;
        wait_reject_pulse(400);
        chk(reject_total > r1, "C1 axis-0 attempt#1 (raw 50 <= zero 200) IS rejected -- precondition");

        //   ② 轴 0 重试：⭐ `raw=500 > zero=200` ⇒ ⭐ 真 `calib` **成功**
        //      ⇒ ⭐ 重试的【第一次】就必须被接受（⛔ 不许再拒一次）
        r1 = reject_total;  s1 = span_total;
        for (r3 = 0; r3 < STABLE_NEED + 4; r3 = r3 + 1) scan_frame_stable(12'd500);
        for (r3 = 0; r3 < VOTE_N + 4;     r3 = r3 + 1) scan_frame_stable(12'd500);
        repeat (60) @(posedge clk);          // ⭐ 给它足够时间走完 FIRE + WAITBUSY
        chk(span_total > s1, "C2 the retry really emitted a span pulse -- non-vacuous");
        chk(reject_total == r1,
            "C3 the RETRY is accepted on the FIRST try (the stale err from the failed attempt does NOT leak)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据②：⭐ 失败的重标定 ⛔ 不得清掉上次成功的 gain
        //   ⭐ 做法（⭐ 只用可观测输出，⛔ 不层次读未打包数组）：
        //     ① ⭐ `tare`：⭐ `zero=100`
        //     ② ⭐ `span`：⭐ `raw=900` ⇒ ⭐ 成功 ⇒ ⭐ `gain = 4095×256/800 ≈ 1310`
        //        ⇒ ⭐ 喂 `raw=900` ⇒ ⭐ `out ≈ 4095`（⭐ 满量程收敛 ✅）
        //     ③ ⭐ 再来一次**会失败**的 `span`：⭐ `raw=50 <= zero=100` ⇒ ⭐ `err=1`
        //     ④ ⭐ 再喂 `raw=900` ⇒ ⭐ **仍必须 ≈4095**
        //        （🔴 变异：⭐ 恢复 err 分支的 `gain_r <= 1.0` ⇒ ⭐ `out` 掉到 ≈800 ⇒ 变红）
        // ═══════════════════════════════════════════════════════════════════
        $display("--- 判据②：失败的重标定不得清掉上次成功的 gain ---");
        do_reset2();

        //   ① tare：⭐ zero_r[0] = 100
        feed2(3'd0, 12'd100);
        @(negedge clk);  tare2 = 1'b1;  calch2 = 3'd0;
        @(negedge clk);  tare2 = 1'b0;
        feed2(3'd0, 12'd500);
        #2;
        chk(outv2 == 12'd400, "B0 tare took effect (out = 500 - 100 = 400)");

        //   ② 成功 span：⭐ raw=900 ⇒ span_r=800、gain≈1310
        feed2(3'd0, 12'd900);
        @(negedge clk);  span2 = 1'b1;  calch2 = 3'd0;
        @(negedge clk);  span2 = 1'b0;
        repeat (40) @(posedge clk);
        chk(busy2 === 1'b0, "B1 the divider finished (busy == 0)");
        chk(err2 === 1'b0,  "B2 the successful span did NOT raise err");
        feed2(3'd0, 12'd900);
        #2;
        chk(outv2 >= 12'd4093, "B3 a successful span normalises full-scale to ~4095 -- precondition");

        //   ③ 失败 span：⭐ raw=50 <= zero=100 ⇒ err
        feed2(3'd0, 12'd50);
        @(negedge clk);  span2 = 1'b1;  calch2 = 3'd0;
        @(negedge clk);  span2 = 1'b0;
        #5;
        chk(err2 === 1'b1, "B4 a span with raw <= zero IS rejected (err == 1) -- precondition");

        //   ④ ⭐ 判据：⭐ 上次成功的增益必须【原样保留】
        feed2(3'd0, 12'd900);
        #2;
        chk(outv2 >= 12'd4093,
            "B5 the FAILED re-calibration did NOT wipe the previous gain (full-scale still ~4095)");

        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 汇总
        // ═══════════════════════════════════════════════════════════════════
        $display("==================================================================");
        $display("tb_calib_span_err: checks=%0d errors=%0d", checks, errors);
        if (errors != 0) begin
            $display("FAIL: tb_calib_span_err has %0d error(s)", errors);
            $fatal(1);
        end
        $display("PASS: span err handling -- per-axis err, retry is accepted, failed re-cal keeps the old gain");
        $finish;
    end

    // ⭐ 兜底超时（⛔ 防仿真挂死）
    initial begin
        #4_000_000;
        $display("FAIL: tb_calib_span_err TIMEOUT (simulation did not finish)");
        $fatal(1);
    end

endmodule

`default_nettype wire
