`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_uart_calib_chain.sv · ⭐⭐ 标定链**端到端**（⭐ 2026-09-23 阶段C 新写）
//
// ⭐ **本 tb 补的是【最有价值的一条判据】**：
//    ⚠️ 前面 3 个 tb 都是**模块级**（各自单测），
//    🔴 **而"命令能不能真的驱动起标定"从来没被一起测过** ——
//    ⭐ 因为在此之前它们**根本没接在一起**（阶段C 才接上）。
//
// ── ⭐ 链路（⭐ 完全复刻 `top.v` 的接法）──────────────────────────────────────
//   ```
//   PC 字节流 ──> uart_rx ──┬──> calib_cmd ──'S'──> calib_span.start_i
//                            │              ──'T'──> calib_autotare.retrig_i
//                            │              ──'X'──> calib_span.abort_i
//                            └──> evt_uart_rx（⭐ 曲谱事件，⚠️ 本 tb 不测）
//   ```
//
// ── ⭐ 判据（⚠️ 每条都必须能失败）──────────────────────────────────────────
//   ① ⭐⭐ **`'S'` 经【串口】真的启动 `calib_span`**（⭐ 端到端核心）
//   ② ⭐ 启动后 `busy_o` 拉起、`need_press_o` 拉起（⭐ 状态机真在跑）
//   ③ ⭐⭐ **`'X'` 能取消**（⭐ 从运行态干净回 `S_IDLE`）
//   ④ ⭐⭐ **`'T'` 经串口真的重触发 `calib_autotare`**（⭐ 逐轴 tare）
//   ⑤ ⭐ **串口线上收到命令后 `evt_uart_rx` 不误同步**
//      （⭐ `hdr_err_cnt` 涨 ⚠️ 这是**预期**，⭐ 但 ⛔ 不能产生假事件）
//   ⑥ 🔴 **互锁：`autotare` 忙时 `'S'` 被忽略**（⭐ ⛔ 不允许同拍冲突）
//   ⑦ ⭐ **帧内的 `'S'` ⛔ 不启动标定**（⭐ 载荷 vs 命令的边界，⭐ 端到端复核）
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⛔ **不用 `wait(信号)`**（⭐ 不推进时间 ⇒ 永久阻塞）
//   · ⭐ 顶层 `initial` 里 ⛔ 不能声明变量
//   · ⭐ 全部 Verilog-2001（`K-91`）
// ─────────────────────────────────────────────────────────────────────────────

module tb_uart_calib_chain;

    localparam integer BAUD_DIV = 50;        // ⭐ 1 Mbps

    integer errors = 0;

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

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ ① 串口接收（⭐ 模拟 PC 发字节）
    // ═══════════════════════════════════════════════════════════════════
    reg  [7:0] pc_byte;
    reg        pc_send;
    wire       ser_line;                     // ⭐ "串口线"（PC → FPGA）
    wire [7:0] ur_data;
    wire       ur_done;

    //   ⭐ PC 侧发送器：⭐ 复用 `uart_tx`（⭐ 它就是 8N1）—— 手写位模型容易错
    uart_tx #(.BAUD_DIV(BAUD_DIV)) u_pc_tx (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .tx_start_i(pc_send),
        .tx_data_i (pc_byte),
        .tx_o      (ser_line),
        .busy_o    (),
        .tx_done_o ()
    );

    //   ⭐ FPGA 侧接收器（⭐ 与 `top.v` 同一实例化方式）
    uart_rx #(.BAUD_DIV(BAUD_DIV)) u_uart_rx (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .rx_i      (ser_line),
        .rx_data_o (ur_data),
        .rx_done_o (ur_done)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ ② 命令解析（⭐ 与 `top.v` 同参数）
    // ═══════════════════════════════════════════════════════════════════
    wire       cmd_tare, cmd_span, cmd_abort;
    wire [15:0] cmd_cnt, cmd_ifc, cmd_rsc, cmd_unk;
    wire [3:0]  cmd_idx;

    calib_cmd #(
        .CLK_HZ   (50_000_000),
        .BAUD     (1_000_000),
        .GAP_BYTES(16)
    ) u_calib_cmd (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .rx_done_i      (ur_done),
        .rx_data_i      (ur_data),
        .tare_req_o     (cmd_tare),
        .span_req_o     (cmd_span),
        .abort_req_o    (cmd_abort),
        .cmd_cnt_o      (cmd_cnt),
        .in_frame_cnt_o (cmd_ifc),
        .resync_cnt_o   (cmd_rsc),
        .idx_o          (cmd_idx),
        .unknown_cnt_o  (cmd_unk)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ ③ 事件解析（⭐ 验证命令 ⛔ 不污染它）
    // ═══════════════════════════════════════════════════════════════════
    wire        eu_valid;
    wire [63:0] eu_data;
    wire [15:0] eu_frame, eu_rsc, eu_hdr, eu_drop;
    wire [3:0]  eu_idx;
    wire        eu_synced;

    evt_uart_rx #(
        .CLK_HZ   (50_000_000),
        .BAUD     (1_000_000),
        .GAP_BYTES(16)
    ) u_evt_uart_rx (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .rx_done_i     (ur_done),
        .rx_data_i     (ur_data),
        .evt_valid_o   (eu_valid),
        .evt_data_o    (eu_data),
        .frame_cnt_o   (eu_frame),
        .resync_cnt_o  (eu_rsc),
        .hdr_err_cnt_o (eu_hdr),
        .drop_cnt_o    (eu_drop),
        .idx_o         (eu_idx),
        .synced_o      (eu_synced)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ ④ 被驱动方：`calib_span`（⭐ 与 `top.v` 同参数）
    // ═══════════════════════════════════════════════════════════════════
    reg  [11:0] raw_in;
    reg  [2:0]  samp_ch;
    reg         samp_valid;
    wire        sp_busy, sp_done, sp_need, sp_reject;
    wire [1:0]  sp_span;
    wire [2:0]  sp_ch;
    wire [3:0]  sp_cur, sp_done_cnt;
    wire        cal_busy, cal_err;

    //   ⭐ 与 `top.v` **完全相同的门控**（⭐ 互锁）
    reg         at_busy;                     // ⭐ 由 tb 控制（⭐ 模拟 autotare 忙）
    wire        sp_start_gated = cmd_span & ~at_busy;

    calib_span #(
        .NCH        (8),
        .N_ADC      (2),
        .AXIS_TOTAL (16),
        //   ⚠️ 调小参数 ⇒ ⭐ 仿真快（⭐ 真值 24/32）
        .STABLE_NEED(4),
        .VOTE_N     (4),
        .REJECT_MAX (2),
        .WAIT_TIMEOUT_CLK(200000),
        .POS_W      (12)
    ) u_calib_span (
        .clk           (clk),
        .rst_n         (rst_n),
        .start_i       (sp_start_gated),
        .abort_i       (cmd_abort),
        .sample_valid_i(samp_valid),
        .sample_ch_i   (samp_ch),
        .raw_i         (raw_in),
        .span_o        (sp_span),
        .cal_ch_o      (sp_ch),
        .cal_busy_i    (cal_busy),
        .cal_err_i     (cal_err),
        .busy_o        (sp_busy),
        .done_o        (sp_done),
        .cur_axis_o    (sp_cur),
        .need_press_o  (sp_need),
        .reject_o      (sp_reject),
        .done_cnt_o    (sp_done_cnt)
    );

    assign cal_busy = 1'b0;
    assign cal_err  = 1'b0;

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ ⑤ 被驱动方：`calib_autotare`（⭐ 验 `'T'` 重触发）
    // ═══════════════════════════════════════════════════════════════════
    wire [1:0] at_tare;
    wire [2:0] at_ch;
    wire       at_busy_w, at_done;
    integer    at_tare_cnt;
    integer    sp_start_cnt;             // ⭐ `start_i` 实际拉高次数

    //   ⭐ 互锁：⭐ `span` 忙时忽略 `'T'`（⭐ 与 `top.v` 对称）
    wire at_retrig = cmd_tare & ~sp_busy;

    // ⭐⭐ 2026-09-30：`calib_autotare` 新增三个端口
    //   ⚠️ `STILL_EN(0)` ⇒ ⭐ **关闭"静止才捕获"守卫** ⇒ ⭐ **本 tb 的期望值完全不变**
    wire [7:0] at_skip;
    wire       at_fail;

    calib_autotare #(
        .NCH      (8),
        .N_ADC    (2),
        .DELAY_CLK(200),
        .STILL_EN (0)
    ) u_autotare (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_valid_i(samp_valid),
        .sample_ch_i   (samp_ch),
        .sample_data_i (12'h000),
        .retrig_i      (at_retrig),
        .tare_o        (at_tare),
        .cal_ch_o      (at_ch),
        .skip_mask_o   (at_skip),
        .fail_o        (at_fail),
        .busy_o        (at_busy_w),
        .done_o        (at_done)
    );

    //   ⭐ 统计 `tare` 脉冲（⭐ 证明 `'T'` 真的让 autotare 重标了）
    integer at_tare_runs;
    reg     at_prev;
    initial begin at_tare_runs = 0; at_prev = 1'b0; end
    always @(posedge clk) begin
        if (rst_n) begin
            //   ⭐ 一个 `tare` 脉冲的上升沿 ⇒ 记一次"本通道被标"
            if (at_tare[0] && !at_prev) at_tare_cnt = at_tare_cnt + 1;
            at_prev = at_tare[0];
            if (sp_start_gated) sp_start_cnt = sp_start_cnt + 1;
        end
    end

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 驱动任务
    // ═══════════════════════════════════════════════════════════════════

    // ⭐ PC 发一个字节（⭐ 经真 `uart_tx` ⇒ 被真 `uart_rx` 收）
    task pc_send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            pc_byte = b;
            pc_send = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pc_send = 1'b0;
            //   ⭐ 等这字节发完（⭐ 10 位 × BAUD_DIV）+ 收完
            repeat (10 * BAUD_DIV + 30) @(posedge clk);
        end
    endtask

    // ⭐ 扫一帧稳定采样（⭐ 让 `calib_span` 能推进）
    task scan_frame;
        input [11:0] base;
        integer c;
        begin
            for (c = 0; c < 8; c = c + 1) begin
                @(negedge clk);
                samp_ch    = c[2:0];
                raw_in     = base;
                samp_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                samp_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // ⭐ 空转若干帧（⭐ 不让状态机推进，用于超时/静止检查）
    task idle_frames;
        input integer n;
        integer k;
        begin for (k = 0; k < n; k = k + 1) repeat (40) @(posedge clk); end
    endtask

    task do_reset;
        begin
            rst_n      = 1'b0;
            pc_send    = 1'b0;
            pc_byte    = 8'h00;
            samp_valid = 1'b0;
            samp_ch    = 3'd0;
            raw_in     = 12'h400;
            at_busy    = 1'b0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk);
            at_tare_cnt  = 0;
            at_tare_runs = 0;
            sp_start_cnt = 0;
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════
    integer i, k;
    integer hdr0, frame0;

    initial begin
        at_tare_cnt = 0;
        $display("=== tb_uart_calib_chain (serial -> calib_cmd -> calib_span) ===");

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据①：`'S'` 经【串口】真的启动 `calib_span`
        // ───────────────────────────────────────────────────────────────
        do_reset();
        chk("before any command: calib_span is idle", sp_busy === 1'b0);
        chk("calib_cmd counted no commands yet", cmd_cnt == 16'd0);

        pc_send_byte(8'h53);            // ⭐ 'S'
        repeat (4) @(posedge clk);
        chk("cmd_cnt_o counted the serial 'S' command", cmd_cnt == 16'd1);
        chk("'S' through the SERIAL PORT starts calib_span (busy_o high)",
            sp_busy === 1'b1);
        chk("calib_span raised start_i exactly once", sp_start_cnt == 1);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据②：状态机真的在跑（⭐ `need_press_o` 拉起）
        // ───────────────────────────────────────────────────────────────
        scan_frame(12'h400);
        repeat (4) @(posedge clk);
        chk("after start, need_press_o is high (waiting for the operator)",
            sp_need === 1'b1);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据③：`'X'` 经串口能取消（⭐ 从运行态干净回 idle）
        //   ⚠️ 这一步**必须先做**：⭐ 否则状态机还在跑，会影响后面的用例
        // ───────────────────────────────────────────────────────────────
        pc_send_byte(8'h58);            // ⭐ 'X'
        repeat (6) @(posedge clk);
        chk("cmd_cnt_o counted the 'X' command", cmd_cnt == 16'd2);
        chk("'X' through the SERIAL PORT cancels the calibration (busy_o low)",
            sp_busy === 1'b0);
        chk("after abort, need_press_o is cleared", sp_need === 1'b0);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据⑦：帧内的 `'S'` ⛔ 不启动标定（⭐ 载荷 vs 命令，端到端复核）
        //   ⭐ 构造：⭐ `0xA5` + 8 字节载荷，⭐ 载荷里塞满 `'S'`
        // ───────────────────────────────────────────────────────────────
        do_reset();
        pc_send_byte(8'hA5);            // ⭐ 帧头
        for (i = 0; i < 8; i = i + 1) pc_send_byte(8'h53);   // ⭐ 载荷全是 'S'
        repeat (6) @(posedge clk);
        chk("payload full of 'S' does NOT start calibration", sp_busy === 1'b0);
        chk("payload 'S' bytes were counted as ignored, not as commands",
            cmd_cnt == 16'd0 && cmd_ifc >= 16'd8);
        chk("frame completed and idx_o returned to 0", cmd_idx === 4'd0);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑤：⭐ 命令 ⛔ 不污染 `evt_uart_rx`
        //   ⚠️ `hdr_err_cnt` **应该涨**（⭐ 命令不是 0xA5 ⇒ 它记一次错）
        //      ⭐ **这是预期行为，⛔ 不是故障** —— ⭐ 判据是"不产生假事件"
        // ───────────────────────────────────────────────────────────────
        do_reset();
        hdr0 = eu_hdr; frame0 = eu_frame;
        pc_send_byte(8'h54);            // ⭐ 'T'（⭐ 不是 0xA5）
        pc_send_byte(8'h53);            // ⭐ 'S'
        pc_send_byte(8'h58);            // ⭐ 'X'
        repeat (20) @(posedge clk);
        chk("commands raised NO event in evt_uart_rx (no false frame)",
            eu_frame == frame0 && eu_valid === 1'b0);
        chk("evt_uart_rx header-error counter DID advance (expected, not a fault)",
            eu_hdr > hdr0);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据④：`'T'` 经串口真的重触发 `calib_autotare`
        // ───────────────────────────────────────────────────────────────
        do_reset();
        //   ⭐ 先让 autotare 跑完（⭐ 它上电 200 拍后开跑）
        for (k = 0; k < 30; k = k + 1) scan_frame(12'h400);
        repeat (10) @(posedge clk);
        chk("autotare finished before the 'T' test", at_done === 1'b1);
        at_tare_cnt = 0;                 // ⭐ 清计数 ⇒ 只数【重触发】那批
        pc_send_byte(8'h54);            // ⭐ 'T'
        repeat (4) @(posedge clk);
        chk("cmd_cnt_o counted the 'T' command", cmd_cnt == 16'd1);
        //   ⭐ 扫帧让它真的逐通道标一遍
        for (k = 0; k < 20; k = k + 1) scan_frame(12'h400);
        $display("  [retrig] tare pulses after 'T' = %0d (expect 8)", at_tare_cnt);
        chk("'T' through the SERIAL PORT re-ran autotare over ALL 8 channels",
            at_tare_cnt == 8);

        // ───────────────────────────────────────────────────────────────
        // 🔴 判据⑥：互锁 —— `autotare` 忙时 `'S'` 必须被忽略
        //   ⚠️ 否则 `tare` 与 `span` 同拍 ⇒ `calib` 增益算错（⭐ 静默）
        // ───────────────────────────────────────────────────────────────
        do_reset();
        at_busy = 1'b1;                  // ⭐ 模拟 autotare 正在忙
        repeat (2) @(posedge clk);
        pc_send_byte(8'h53);            // ⭐ 'S'
        repeat (6) @(posedge clk);
        chk("while autotare is BUSY, 'S' is IGNORED (no calibration started)",
            sp_busy === 1'b0);
        chk("the interlock did not swallow the command itself (cmd still counted)",
            cmd_cnt == 16'd1);
        //   ⭐ 放开忙标志 ⇒ ⭐ 再发一次应该能启动（⭐ 证明不是"永久卡死"）
        at_busy = 1'b0;
        repeat (4) @(posedge clk);
        pc_send_byte(8'h53);
        repeat (6) @(posedge clk);
        chk("after autotare goes idle, 'S' DOES start calibration (interlock recovers)",
            sp_busy === 1'b1);
        pc_send_byte(8'h58);            // ⭐ 'X' 收尾
        repeat (4) @(posedge clk);

        $display("");
        if (errors == 0)
            $display("PASS: a serial 'S' really starts calib_span, 'X' really cancels it, 'T' really re-runs autotare, in-frame letters are payload, commands never fake an event, and the busy interlock blocks (then releases) 'S'");
        else
            $fatal(1, "FAIL: tb_uart_calib_chain had %0d error(s)", errors);

        #200;
        $finish;
    end

endmodule
