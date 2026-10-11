`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib_span.sv · `calib_span` 自检（⭐ 满行程标定）
//
// ⭐⭐ **本 tb 是【新写】的**（⭐ 2026-09-23 深夜）——
//    ⚠️ 交接文档曾误记"tb 8/8 过"，⭐ 实际 `tb/w3a/` 下**从来没有**这个文件。
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **`start_i` 之前不产生任何 `span`**（⭐ 未触发时静止）
//   ② ⭐⭐⭐ **读数抖动 ⇒ 不进入投票**（⭐ 稳定性判定真的在拦）
//   ③ ⭐⭐⭐ **投票期内离散度超限 ⇒ 拒绝 + 重来**（⭐ 本模块的核心价值）
//   ④ ⭐⭐⭐ **`span` 出现在 `sample_ch == cal_ch` 那一拍**（🔴 最关键）
//   ⑤ ⭐ **`cal_err_i` ⇒ 拒绝该轴、⛔ 不计入 `done_cnt`**（⭐ 防静默失败）
//   ⑥ ⭐⭐ **`abort_i` ⇒ 任意状态回 `S_IDLE`、`busy_o` 落 0**（⭐ 新增端口）
//   ⑦ ⭐ **`abort_i` ⛔ 不会漏出半个 `span` 脉冲**（🔴 防写坏 `calib` 标定）
//   ⑧ ⭐ **走完全部轴 ⇒ `done_o=1`、`done_cnt_o == AXIS_TOTAL`**
//
// ── 🔴 tb 纪律（本项目血泪）──────────────────────────────────────────────────
//   · ⛔ **不要用 `wait(信号)`** —— ⚠️ 它**不推进仿真时间** ⇒ 🔴 **永久阻塞**
//     （⭐ `calib_span.v` 头部就记着这个坑；⭐ 本 tb 全用**时钟沿轮询**）
//   · ⭐ **`sample_valid_i` 必须与 `sample_ch_i` 同拍**（⭐ 模拟 `adc_farm` 锁步）
//   · ⚠️ `calib_span` 是 **Verilog-2001**（`K-91`）⇒ ⭐ 例化用 `.port(sig)`
//   · ⭐ **顶层 `initial` 里 ⛔ 不能声明变量**（⭐ Verilog-2001 限制）
// ─────────────────────────────────────────────────────────────────────────────

module tb_calib_span;

    // ── ⭐ 参数（⭐ 全部调小 ⇒ ⭐ 仿真快，⚠️ 默认值在真板上是 24/32 帧）──────
    localparam integer NCH        = 8;
    localparam integer N_ADC      = 2;
    localparam integer AXIS_TOTAL = 16;      // ⭐ = NCH × N_ADC（⚠️ 参数自检要求相等）
    localparam integer STABLE_NEED= 4;       // ⭐ 真值 24
    localparam integer VOTE_N     = 4;       // ⭐ 真值 32
    localparam integer REJECT_MAX = 2;       // ⭐ 真值 8

    localparam [11:0] STABLE_TOL  = 12'd8;   // ⭐ 与真值一致（语义关键）
    localparam [11:0] VOTE_TOL    = 12'd16;  // ⭐ 与真值一致（语义关键）
    //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **投票代表值**（⭐ 新端口，⭐ 只在 `span_o` 那拍有效）✅
    wire [11:0] span_val_o;
    // ⭐ 兜底超时：⭐ 调成 **200000 拍**（⭐ 真值 1 秒 = 50M 拍）
    //   🔴 **为什么不能太小**（⭐ 关键）：⭐ 判据⑤b 要求**在超时之前**靠 `err` 拒绝
    //      ⇒ ⚠️ 若超时阈值小于那次循环的拍数，拒绝就**可能来自超时**
    //      ⇒ 🔴 那样就分不清"`err` 检测生效"与"只是超时了"（⭐ 变异体会漏检）。
    localparam integer WAIT_TO    = 200000;

    integer errors = 0;
    //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ 锁存 `span` 那拍的投票代表值（⭐ 判据用）✅
    reg [11:0] p009_val = 12'h0;
    //  ⭐⭐ 2026-10-09（`P0-10`）：⭐ "`span_o` 曾是 `2'b11`" 的计数（⭐ 必须为 0）✅
    integer p010_bad = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                   // ⭐ 50 MHz

    task chk;
        input [1023:0] name;
        input          cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ DUT
    // ═══════════════════════════════════════════════════════════════════════
    reg              start_i;
    reg              abort_i;
    reg              sample_valid;
    reg  [2:0]       sample_ch;
    reg  [11:0]      raw_in;
    wire [N_ADC-1:0] span_o;
    wire [2:0]       cal_ch_o;
    //   ⭐⭐ `cal_busy_i`/`cal_err_i` 是 **wire**（⭐ 由下方 `always @(*)` 驱动）
    wire             cal_busy_i;
    wire             cal_err_i;
    wire             busy_o;
    wire             done_o;
    wire [3:0]       cur_axis_o;
    wire             need_press_o;
    wire             reject_o;
    wire [3:0]       done_cnt_o;

    calib_span #(
        .NCH        (NCH),
        .N_ADC      (N_ADC),
        .AXIS_TOTAL (AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED),
        .STABLE_TOL (STABLE_TOL),
        .VOTE_N     (VOTE_N),
        .VOTE_TOL   (VOTE_TOL),
        .REJECT_MAX (REJECT_MAX),
        .WAIT_TIMEOUT_CLK(WAIT_TO),
        .POS_W      (12)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start_i       (start_i),
        .abort_i       (abort_i),
        .sample_valid_i(sample_valid),
        .sample_ch_i   (sample_ch),
        .raw_i         (raw_in),
        .span_o        (span_o),
        //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ 接出新端口（⭐ 判据要用）✅
        .span_val_o    (span_val_o),
        .cal_ch_o      (cal_ch_o),
        .cal_busy_i    (cal_busy_i),
        .cal_err_i     (cal_err_i),
        .busy_o        (busy_o),
        .done_o        (done_o),
        .cur_axis_o    (cur_axis_o),
        .need_press_o  (need_press_o),
        .reject_o      (reject_o),
        .done_cnt_o    (done_cnt_o)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 真 `calib` 实例（⭐ 端到端：⭐ 让 `busy`/`err` 由【真模块】产生）
    //
    //   🔴 **为什么必须是真的**（⭐ 2026-09-23 深夜的教训）：
    //      ⚠️ 若 tb 自己编造 `busy` 脉冲，就**永远测不到**这条真缺陷：
    //      ⭐ `calib.v:98` 的 `err` 分支**只置 `err`、⛔ 不拉 `busy`**
    //      ⇒ 🔴 只等 `busy` 的 `calib_span` 会**永久卡死**。
    //   ⭐ 用真模块 ⇒ ⭐ `err` 那条路径**自动**被覆盖。
    // ═══════════════════════════════════════════════════════════════════════
    wire        cal_vld;
    wire [2:0]  cal_ch_w;
    wire [11:0] cal_val_w;
    wire        cal_busy_w, cal_err_w;

    calib #(.NCH(NCH), .DW(12)) u_calib (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid    (sample_valid),
        .ch       (sample_ch),
        .raw      (raw_in),
        .tare     (1'b0),            // ⭐ 本 tb 只测 span（⭐ tare 由 autotare 测）
        //  ⭐⭐ 2026-10-09（`P0-10`）：⭐ **span 已改成按片单发**（⭐ 用户拍板选 A）✅
        //   ⇒ ⭐ 本模型代表"某一颗 calib" ⇒ ⭐ **两片任一有脉冲都算**
        //     （⭐ 这样轴 0~7（片0）与轴 8~15（片1）都能被本模型看到 ✅）
        //   📌 ⭐ 原写 `span_o[0]` ⇒ ⚠️ 轴 8~15 时 `span_o = 2'b10` ⇒ **本模型收不到** ⇒ 🔴 假红 ✅
        .span     (span_o[0] | span_o[1]),
        .cal_ch   (cal_ch_o),        // ⭐ 与 span **同拍**（⭐ 这正是被测的契约）
        .busy     (cal_busy_w),
        .err      (cal_err_w),
        .out_valid(cal_vld),
        .out_ch   (cal_ch_w),
        .out_val  (cal_val_w)
    );

    //   ⭐⭐ **把 `calib` 的 `busy`/`err` 接回 DUT**
    //      ⚠️ 但**判据⑤ 要人工强制 `err=1 && busy=0`** ⇒ ⭐ 所以做成可切换：
    //      ⭐ `force_err_mode=1` 时用 tb 的驱动值，⭐ 否则用真 `calib` 的输出。
    //   ⚠️ `always @(*)` 的赋值目标必须是 **`reg`** ⇒ ⭐ 用中间变量再 `assign`。
    reg force_err_mode;
    initial force_err_mode = 1'b0;
    reg cal_busy_sel, cal_err_sel;
    always @(*) begin
        if (force_err_mode) begin
            cal_busy_sel = 1'b0;       // 🔴 真缺陷场景：⭐ busy 永不起
            cal_err_sel  = 1'b1;       // 🔴 但 err 置起
        end else begin
            cal_busy_sel = cal_busy_w;
            cal_err_sel  = cal_err_w;
        end
    end
    assign cal_busy_i = cal_busy_sel;
    assign cal_err_i  = cal_err_sel;

    integer span_total;
    integer align_ok, align_bad;
    integer span_before_abort;   // ⭐ 判据⑦ 用
    integer reject_total;
    integer ch;
    integer i, k, n;
    integer jitter_frame_no;     // ⭐ 判据③：⭐ 按【帧序号】翻转（⛔ 不按通道号）
    initial jitter_frame_no = 0;

    initial begin
        span_total = 0; align_ok = 0; align_bad = 0; reject_total = 0;
        span_before_abort = 0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (span_o[0]) begin
                span_total = span_total + 1;
                //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **锁存投票代表值**（⭐ 判据用）✅
                p009_val = span_val_o;
                //  ⭐⭐ 2026-10-09（`P0-10`）：⭐ **按片单发判据**（⭐ 见下方独立检查）✅
                // ⭐⭐ 判据④：⭐ `span` 那一拍 `sample_ch` 必须 == `cal_ch`
                if (sample_ch === cal_ch_o) align_ok  = align_ok + 1;
                else                        align_bad = align_bad + 1;
            end
            //  ⭐⭐ 2026-10-09（`P0-10`）：⭐ **独立不变量** —— ⭐ `span_o` **永不**是 `2'b11` ✅
            //   📌 一次只标**一个轴** ⇒ ⭐ 只该打给**一片** ✅
            //   🔴 原写法 `{N_ADC{1'b1}}` ⇒ ⭐ 恒 `2'b11` ⇒ 本判据必红 ✅
            //   📌 放在 `span_o[0]` 判断【之外】⇒ ⭐ 片 1 的脉冲也数得到 ✅
            if (span_o === 2'b11) p010_bad = p010_bad + 1;
            if (reject_o) reject_total = reject_total + 1;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 帧驱动任务
    // ═══════════════════════════════════════════════════════════════════════

    // ⭐ 扫一帧：ch0..ch7，⭐ 每通道给【不同值】⇒ ⚠️ 时机错一拍就串位
    //   ⭐ `base` 决定这帧的读数（⭐ 用来做"稳定/抖动"两种场景）
    task scan_frame_stable;
        input [11:0] base;
        integer c;
        begin
            for (c = 0; c < NCH; c = c + 1) begin
                @(negedge clk);
                sample_ch    = c[2:0];
                raw_in       = base;             // ⭐ 每通道同值 ⇒ 帧间稳定
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // ⭐ 扫一帧：⭐ 全部通道喂 **`raw = 0`** ⇒ ⭐ 触发 `calib` 的 `err` 分支
    //   📌 依据 `calib.v:98`：`if (raw <= zero_r[cal_ch])` ⇒ ⭐ `err <= 1`
    //      ⚠️ `zero_r` 初始为 0，⭐ 而 `tare` 在本 tb 里恒 0 ⇒ ⭐ `raw=0` 必然 `<= zero`
    task scan_frame_zero;
        integer c;
        begin
            for (c = 0; c < NCH; c = c + 1) begin
                @(negedge clk);
                sample_ch    = c[2:0];
                raw_in       = 12'h000;
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    //   ⚠️ 这是判据② 的驱动 —— ⭐ 用它证明"稳定性判定真的在拦"
    //   🔴 **曾经的 tb 缺陷（⭐ 已修）**：⭐ 原实现用 `(c % 2)` 选加点
    //      ⇒ ⚠️ `ch0`（`c=0`，偶数）**每帧都拿到同一个值** ⇒ ⭐ 它其实**是稳定的**
    //      ⇒ 🔴 状态机**正确地**推进到了投票并发了 `span`
    //      ⇒ ⚠️ 而我却判它"失败" —— ⭐ **是 tb 错了，⛔ 不是 RTL 错了**。
    //   ⭐ 正解：⭐ 用**帧序号 `frame_no`** 决定加点 ⇒ ⭐ 每个通道都跟着帧变。
    integer frame_no;
    initial frame_no = 0;
    task scan_frame_jitter;
        input [11:0] base;
        integer c;
        begin
            frame_no = frame_no + 1;
            for (c = 0; c < NCH; c = c + 1) begin
                @(negedge clk);
                sample_ch    = c[2:0];
                //   ⭐ 交替给 `base` 与 `base+64` ⇒ ⚠️ 帧间变化 64 ≫ STABLE_TOL(8)
                //      ⭐ `frame_no` 逐帧翻转 ⇒ ⭐ **所有通道**都跟着抖
                raw_in       = base + ((frame_no % 2) ? 12'd64 : 12'd0);
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // ⭐ 复位 + 清状态
    //   ⚠️ `cal_busy_i`/`cal_err_i` 是 **wire**（⭐ 由 `always @(*)` 驱动）
    //      ⇒ ⛔ **不能在这里赋值** —— ⭐ 它们由 `force_err_mode` 与真 `calib` 决定。
    task do_reset;
        begin
            rst_n        = 1'b0;
            start_i      = 1'b0;
            abort_i      = 1'b0;
            sample_valid = 1'b0;
            sample_ch    = 3'd0;
            raw_in       = 12'h000;
            force_err_mode = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════════
    initial begin
        $display("=== tb_calib_span ===");

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据①：`start_i` 之前 ⛔ 不产生 `span`
        // ───────────────────────────────────────────────────────────────
        do_reset();
        for (k = 0; k < 4; k = k + 1) scan_frame_stable(12'h400);
        chk("no span before start_i (idle is truly idle)", span_total == 0);
        chk("busy_o is low before start_i", busy_o === 1'b0);
        chk("need_press_o is low before start_i", need_press_o === 1'b0);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据②：抖动读数 ⇒ ⭐ 不进入投票（⭐ 稳定性判定有效）
        //   ⚠️ 驱动：⭐ 一直喂抖动帧 ⇒ ⭐ 应停在 `S_SETTLE`
        //   ⭐ 判据：⭐ 这些帧里**一个 `span` 都不该发**
        // ───────────────────────────────────────────────────────────────
        do_reset();
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;
        repeat (4) @(posedge clk);
        chk("need_press_o rises after start_i (prompting the operator)", need_press_o === 1'b1);
        chk("busy_o is high while calibrating", busy_o === 1'b1);

        // ⭐ 喂 60 帧抖动 —— ⚠️ 远超 STABLE_NEED，⭐ 若判定失效就会误进投票并发 span
        for (k = 0; k < 60; k = k + 1) scan_frame_jitter(12'h400);
        chk("jittery readings NEVER reach the vote stage (no span emitted)",
            span_total == 0);
        chk("still busy after jitter (stuck in settle, pending a stable hold)",
            busy_o === 1'b1);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑥：`abort_i` ⇒ 从 `S_SETTLE` 干净退出
        //   🔴 这正是"'X' 取消"要解决的场景（⭐ 否则永久卡死）
        // ───────────────────────────────────────────────────────────────
        span_before_abort = span_total;
        @(negedge clk); abort_i = 1'b1;
        @(posedge clk); @(negedge clk); abort_i = 1'b0;
        repeat (2) @(posedge clk);
        chk("abort_i returns the FSM to idle (busy_o drops)", busy_o === 1'b0);
        chk("abort_i clears need_press_o", need_press_o === 1'b0);
        chk("abort_i does not assert done_o", done_o === 1'b0);
        chk("abort_i emits no span (no half-pulse escapes)", span_total == span_before_abort);
        chk("abort_i clears done_cnt_o (no stale progress)", done_cnt_o === 4'd0);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据③：投票期内离散度超限 ⇒ ⭐ 拒绝 + 重来
        //   ⭐ 测法：⭐ 先让它稳定到进入投票，⭐ 然后在投票期**制造抖动**
        //   ⚠️ 这需要精确控制帧 —— 所以用"稳定帧 × N，再抖一帧"的方式
        // ───────────────────────────────────────────────────────────────
        do_reset();
        reject_total = 0;
        span_before_abort = span_total;      // ⭐ 重新基线
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;

        // ⭐ 稳定若干帧 ⇒ 应进入投票（S_SETTLE 需 STABLE_NEED 帧）
        //   ⚠️ 首帧是哨兵（prev_val=0xFFF）⇒ 多给几帧
        for (k = 0; k < (STABLE_NEED + 2); k = k + 1) scan_frame_stable(12'h400);

        // ⭐ 投票期：喂一个【跨 VOTE_TOL 的两点】⇒ ⭐ 必然 (max-min) > VOTE_TOL
        //
        //   🔴🔴 **这里踩过两次同一个坑（⭐ 记下来）**：
        //      ⭐ 本状态机**只采样 `sample_ch_i == cur_axis[2:0]` 的帧**
        //      ⇒ ⚠️ 而 `cur_axis` 此时是 **0**（⭐ 第一轴）
        //      ⇒ ⭐ 所以"让所有通道轮流抖"是**无效**的 ——
        //         🔴 目标通道 0 每 8 帧才被采一次，⭐ 而那时 `k%2` 恰好总是同一个值
        //         ⇒ ⚠️ 它**其实一直是稳定的**（⭐ 探针实测 `vcnt=1` 卡住、`rej=0`）
        //      ⇒ ⭐ **是 tb 的驱动错了，⛔ 不是 RTL 错了**。
        //   ⭐ 正解：⭐ **只针对目标通道 `cur_axis_o`** 喂交替值，
        //      且**按帧序号**（⛔ 不是按通道号）翻转 ⇒ ⭐ 保证两点都进投票。
        //   ⚠️ 关键是"同一个通道连续两次采样拿到相差 > VOTE_TOL 的值"。
        for (k = 0; k < (VOTE_N + 4); k = k + 1) begin
            jitter_frame_no = jitter_frame_no + 1;
            @(negedge clk);
            //   ⭐ 直接对准【当前目标轴】的通道 —— ⭐ 这才是它真正会采的那一帧
            sample_ch    = cur_axis_o[2:0];
            raw_in       = (jitter_frame_no % 2) ? (12'h400 + 12'd40)
                                                 : (12'h400 - 12'd40);
            sample_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sample_valid = 1'b0;
            @(posedge clk);
        end
        repeat (4) @(posedge clk);
        chk("spread beyond VOTE_TOL is rejected (reject_o pulsed at least once)",
            reject_total > 0);
        chk("rejection emitted no span for the bad sample set",
            span_total == span_before_abort);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑤：`cal_err_i` ⇒ 拒绝该轴、⛔ 不计入 `done_cnt`
        //
        //   🔴🔴 **本判据测的是【真缺陷场景】**（⭐ 2026-09-23 深夜发现）：
        //      ⭐ `calib.v:98` 的 `err` 分支**只置 `err`、⛔ 不拉 `busy`**：
        //        ```
        //        if (raw <= zero_r[cal_ch]) begin err <= 1'b1; ... end
        //        else begin busy <= 1'b1; ... end
        //        ```
        //      ⇒ 🔴 若 `calib_span` 只等 `busy` 升起 ⇒ **永久卡死在 `S_NEXT`**。
        //   ⭐ 所以本判据**必须模拟"`err` 起、`busy` 始终不起"** ——
        //      ⚠️ 若这里偷懒去模拟 `busy` 脉冲，就**测不到那个缺陷**。
        //   ⭐ 正解：⭐ 用**真 `calib` 实例**（⭐ 端到端），⭐ 且喂"没按到底"的码
        //      （⭐ `raw <= zero`）⇒ ⭐ 它**自己会走 `err` 分支**。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        reject_total = 0;
        span_before_abort = span_total;
        force_err_mode = 1'b1;               // 🔴 强制 `err=1` 且 `busy=0`（⭐ 真缺陷场景）
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;

        //   ⭐ 稳定帧推进到发 span，⭐ 此后 `err` 应导致拒绝
        //   ⚠️ 循环上限给足（⭐ 要允许"拒绝 → 重试 → 再拒绝 ×REJECT_MAX"跑完）
        for (k = 0; k < 600; k = k + 1) begin
            scan_frame_stable(12'h400);
        end
        chk("calib.err (with busy NEVER rising) causes rejection, not a hang",
            reject_total > 0);
        chk("calib.err never counts the axis as done (done_cnt_o stays 0)",
            done_cnt_o === 4'd0);
        chk("calib.err within REJECT_MAX keeps the FSM from claiming done",
            done_o === 1'b0);
        chk("calib.err eventually gives up instead of hanging forever",
            (dut.state === 3'd7) || (reject_total >= REJECT_MAX));

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑤b：⭐ 用**真 `calib`** 触发 `err`（⭐ 端到端，⛔ 不靠 tb 造）
        //
        //   ⭐ 驱动：⭐ 喂 `raw = 0` ⇒ `calib.v:98` 的 `if (raw <= zero)` 成立
        //      ⇒ ⭐ 它**只置 `err`、⛔ 不拉 `busy`**（⭐ 探针实测确认）
        //      ⇒ ⭐ 这就复现了"**等 `busy` 会永久卡死**"的真场景。
        //
        //   🔴 **判据的关键【不是】"最终会不会拒绝"**（⭐ 超时兜底也能做到），
        //      ⭐ 而是"**在超时之前**就靠 `err` 拒绝" ——
        //      ⚠️ 否则就分不清"`err` 检测生效"与"只是超时了"。
        //   ⇒ ⭐ 做法：把 `WAIT_TIMEOUT_CLK` 设得**远大于**本次循环的拍数，
        //      ⭐ 然后要求 `reject_total > 0`。⚠️ 这样只有 `err` 路径能解释它。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        reject_total = 0;
        force_err_mode = 1'b0;               // ⭐ 用真 `calib`（⭐ 端到端）
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;
        //   ⭐ 喂"没按到底"的码（⭐ `raw = 0` ⇒ 必触发 `calib.err`）
        for (k = 0; k < 400; k = k + 1) begin
            scan_frame_zero();
        end
        chk("real calib.err (busy stays 0) is detected BEFORE any timeout",
            reject_total > 0);
        chk("real calib.err never counts the axis as done (done_cnt_o stays 0)",
            done_cnt_o === 4'd0);
        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑨：⭐ 超时兜底（⭐ 补 CS-6 变异体漏检）
        //
        //   🔴 **为什么需要这一条**（⭐ 变异测试实测发现）：
        //      ⭐ 上面所有判据都会**先走到别的出口**（⭐ 发出 `span`、或 `err`），
        //      ⇒ ⚠️ **超时路径一次都没被执行** ⇒ 🔴 "超时计数失效"的变异体存活。
        //   ⭐ 真实场景：⭐ `adc_farm` 停扫（SPI 挂了 / 排线松了 / 片没接）
        //      ⇒ ⭐ **`sample_valid_i` 永远不来** ⇒ ⚠️ 状态机必须**自己超时退出**，
        //        ⛔ 而不是让操作者对着一个死界面干等。
        //   ⭐ 驱动：⭐ **一个采样都不发给它** —— ⭐ 就让它干等。
        //   ⚠️ `WAIT_TIMEOUT_CLK` 必须**远小于**本段的等待拍数，⭐ 否则测不出。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        reject_total = 0;
        force_err_mode = 1'b0;
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;
        //   ⭐⭐ **完全不发采样**（⭐ 也不发 `span` 的机会）
        //      ⭐ 一直等到"超时 → 拒绝 → 重试"走满 `REJECT_MAX` 次
        //   ⚠️ 上限：⭐ (WAIT_TO + 余量) × (REJECT_MAX + 2)
        for (k = 0; k < ((WAIT_TO + 200) * (REJECT_MAX + 2)); k = k + 1) begin
            @(posedge clk);
            if (dut.state === 3'd7) k = (WAIT_TO + 200) * (REJECT_MAX + 2);
        end
        repeat (4) @(posedge clk);
        chk("NO samples at all => the FSM times out instead of hanging forever",
            (dut.state === 3'd7) || (reject_total > 0));
        chk("timeout path reports rejection (observable, not silent)", reject_total > 0);
        chk("timeout path never claims a successful calibration",
            (done_o === 1'b0) && (done_cnt_o === 4'd0));

        // ⭐ 收尾：⭐ 确认 `abort` 之后一切可恢复
        do_reset();
        chk("after the timeout scenario, a fresh reset returns to idle",
            (busy_o === 1'b0) && (done_o === 1'b0));

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑩：⭐ **投票期**的超时兜底（⭐ 补 CS-7 变异体漏检）
        //
        //   🔴 **为什么单独需要**：⭐ 判据⑨ 卡在 `S_SETTLE`（⭐ 一帧都没发）
        //      ⇒ ⚠️ 它**永远到不了 `S_VOTE`** ⇒ 🔴 `S_VOTE` 的超时**从未被执行**。
        //   ⭐ 真实场景：⭐ 已经稳定、**开始投票**了，⭐ 然后**帧突然停了**
        //      （⭐ 排线被碰松 / SPI 中途挂掉）⇒ ⚠️ `vote_cnt` 收不满 `VOTE_N`
        //      ⇒ 🔴 若不超时，就**永久停在投票状态**。
        //   ⭐ 驱动：⭐ 先喂够稳定帧**进入投票**，⭐ 然后**立刻停发采样**。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        reject_total = 0;
        force_err_mode = 1'b0;
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;

        //   ⭐ 喂稳定帧直到**确实进入投票**（⭐ 用状态机状态判定，⛔ 不猜帧数）
        //   ⚠️ 上限给足，⛔ 不会死循环
        for (k = 0; k < 400; k = k + 1) begin
            if (dut.state === 3'd3) k = 400;      // ⭐ S_VOTE = 3'd3 ⇒ 已进入
            else scan_frame_stable(12'h400);
        end
        chk("steady frames drive the FSM into the vote stage",
            dut.state === 3'd3);

        //   ⭐⭐ **此刻起【彻底停发采样】** ⇒ ⭐ 投票收不满 ⇒ ⭐ 必须超时退出
        for (k = 0; k < ((WAIT_TO + 200) * (REJECT_MAX + 2)); k = k + 1) begin
            @(posedge clk);
            if (dut.state === 3'd7) k = (WAIT_TO + 200) * (REJECT_MAX + 2);
        end
        repeat (4) @(posedge clk);
        chk("frame loss DURING the vote stage times out instead of hanging",
            (dut.state === 3'd7) || (reject_total > 0));
        chk("vote-stage timeout reports rejection (observable, not silent)",
            reject_total > 0);
        chk("vote-stage timeout never claims a successful calibration",
            (done_o === 1'b0) && (done_cnt_o === 4'd0));

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据④ + ⑧：正常跑完全部轴
        //   ⭐ `span` 必须与 `sample_ch == cal_ch` 同拍（⭐ 最关键）
        //   🔴 **这里用【真 `calib`】驱动 `cal_busy_i`/`cal_err_i`**
        //      （⭐ 端到端）—— ⚠️ 而不是 tb 自己编造 busy 脉冲：
        //      ⭐ 只有这样才会经过 `calib` 真实的 `busy`/`err` 语义。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        force_err_mode = 1'b0;               // ⭐ 正常模式：⭐ 由真 `calib` 驱动
        align_ok = 0; align_bad = 0;
        span_before_abort = span_total;
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;

        //   ⭐ 一直扫帧，⭐ `cal_busy_i`/`cal_err_i` 由**真 `calib`** 驱动
        //   ⚠️ 上限给足（⭐ 16 轴 × 每轴若干帧），⭐ 避免死循环
        for (k = 0; k < 6000; k = k + 1) begin
            scan_frame_stable(12'h400);
            if (done_o) k = 6000;            // ⭐ 提前收工
        end
        repeat (4) @(posedge clk);

        $display("  [align] ok=%0d  bad=%0d  spans=%0d", align_ok, align_bad, span_total - span_before_abort);
        chk("every span pulse occurred when sample_ch == cal_ch", align_bad == 0);
        chk("span pulses were actually emitted (chain is live)",
            (span_total - span_before_abort) > 0);
        chk("all axes calibrated => done_o asserted", done_o === 1'b1);
        chk("done_cnt_o == AXIS_TOTAL when done", done_cnt_o == AXIS_TOTAL[3:0]);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑦：`abort_i` 在 `S_DONE` 也要安全（⭐ 不产生任何 `span`）
        // ───────────────────────────────────────────────────────────────
        span_before_abort = span_total;
        @(negedge clk); abort_i = 1'b1;
        @(posedge clk); @(negedge clk); abort_i = 1'b0;
        repeat (2) @(posedge clk);
        chk("abort_i from DONE is safe (no span escapes)", span_total == span_before_abort);
        chk("abort_i from DONE returns to idle", busy_o === 1'b0);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **投票代表值必须是【中位数】**，⛔ 不是最后采样 ✅
        //   🔴 **原缺陷（两层）**：
        //      · ⭐ `vote_lo` **只被写、从不被读** ⇒ ⭐ 送进 `calib` 的是**当拍活采样** ✅
        //      · ⭐ 且 `(vmin+vmax)>>1` 是 **12 位加法** ⇒ ⭐ **≥4096 回绕** ✅
        //   📌 **本判据为什么能同时抓两条**：⭐ 用**实测工作点** `2854`（⭐ `top.v:2069`）
        //      · ⭐ 正确中位数 = `(2854+2854)/2 = 2854` ✅
        //      · 🔴 若加法器回绕：`2854+2854 = 5708` ⇒ 12 位 = **1612** ⇒ `>>1 = 806` ⇒ **FAIL** ✅
        //      · 🔴 若只取最后采样 ⇒ 值会随抖动漂（⭐ 本用例是恒值 ⇒ 那条要另测）✅
        //   📌 ⭐ **本判据在未修复代码上【测不到】**（⭐ 端口都不存在 ⇒ 编译就过不去）
        //      ⇒ ⭐ 它的价值是**把 2854 这条真实工作点钉住** ✅
        // ═══════════════════════════════════════════════════════════════════
        do_reset();
        p009_val = 12'h0;
        @(negedge clk); start_i = 1'b1;
        @(posedge clk); @(negedge clk); start_i = 1'b0;
        for (k = 0; k < 600; k = k + 1) begin
            scan_frame_stable(12'hB26);          // ⭐ 2854 = 实测工作点（⭐ top.v:2069）
            if (p009_val != 12'h0) k = 600;      // ⭐ 拿到就停
        end
        $display("      [dbg] P0-09 投票代表值 = 0x%03h（应 0x%03h = 2854；回绕会变 0x326 = 806）",
                 p009_val, 12'hB26);
        chk("P0-09 span_val_o carries the VOTE median (2854), NOT a 12-bit wrapped 806",
            p009_val === 12'hB26);

        //  ⭐⭐ 2026-10-09（`P0-10`）：⭐ **span 必须按片单发**（⭐ `span_o` 永不为 `2'b11`）✅
        $display("      [dbg] P0-10 span_o 曾是 2'b11 的次数 = %0d（应为 0）", p010_bad);
        chk("P0-10 span_o is NEVER 2'b11 (span goes to ONE chip only, per user choice A)",
            p010_bad == 0);

        $display("");
        if (errors == 0)
            $display("PASS: calib_span gates on stability, rejects bad votes, aligns span with its channel, honours calib.err, and aborts cleanly from any state");
        else
            $fatal(1, "FAIL: calib_span had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
