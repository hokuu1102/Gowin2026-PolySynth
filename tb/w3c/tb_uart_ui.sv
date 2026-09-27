`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_uart_ui.sv · 串口屏人机交互层测试
//
// ⭐ 验证 `uart_ui.v` 的返回帧解析状态机：
//   ① 握手帧 0x88 + FF FF FF → hb_ready 置位
//   ② 触摸帧 0x65 + 控件ID + FF FF FF → 模式翻转 + mode_commit
//   ③ 数值帧 0x71 + 变量序 + 数值 + FF FF FF → 起始音落地 + base_commit
//   ④ 结束符严格三连（单个/两个 FF 不结束帧）
//   ⑤ 空闲归位（半帧后静默 → 回 IDLE + resync_cnt 自增）
//   ⑥ 非法返回码 → err_cnt 自增
//
// ⭐ 判据用「可观测现象」而非内部信号：全部走输出端口（K-106）。
// ⭐ 喂入方式：直接驱动 rx_done_i/rx_data_i（uart_ui 消费的是 uart_rx 的字节流，
//   不模拟完整串行波形 —— 串行层已被 tb_uart_rx 覆盖）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_uart_ui;

    localparam integer CLK_HZ = 50000000;
    localparam integer BAUD   = 1000000;
    // ⭐ 一个字节时间 = CLK_HZ/BAUD = 50 个 clk。空闲归位阈值 GAP_BYTES=16 字节。
    //   这里用「远大于 16 字节时间」的静默来触发归位。
    localparam integer BYTE_CLK = CLK_HZ / BAUD;   // = 50

    reg  clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg        rst_n = 1'b0;
    reg        rx_done = 1'b0;
    reg  [7:0] rx_data = 8'h00;

    // tx 侧（本 tb 不真正驱动 uart_tx，只给静态握手信号）
    reg        tx_busy = 1'b0;
    reg        tx_done = 1'b0;

    wire        tx_start;
    wire [7:0]  tx_data;
    wire        mode;
    wire [6:0]  base_semi;
    wire        mode_commit;
    wire        base_commit;
    wire        fx_en;
    wire [1:0]  fx_sel;
    wire        test_mode;
    wire [1:0]  test_mode_n;
    wire        test_mode_commit;
    wire [15:0] frame_cnt;
    wire [15:0] resync_cnt;
    wire [15:0] err_cnt;
    wire        hb_ready;

    integer errors = 0;

    task chk;
        input [8*110-1:0] name;
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

    uart_ui #(
        .CLK_HZ   (CLK_HZ),
        .BAUD     (BAUD),
        .GAP_BYTES(16),
        .MODE_PIANO_DEFAULT(0)   // ⭐ tb 沿用「指板默认」语义（reset 检查 mode==0）
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .rx_done_i    (rx_done),
        .rx_data_i    (rx_data),
        .tx_busy_i    (tx_busy),
        .tx_done_i    (tx_done),
        .tx_start_o   (tx_start),
        .tx_data_o    (tx_data),
        .mode_o       (mode),
        .base_semi_o  (base_semi),
        .mode_commit_o(mode_commit),
        .base_commit_o(base_commit),
        .fx_en_o      (fx_en),
        .fx_sel_o     (fx_sel),
        .test_mode_o  (test_mode),
        .test_mode_n_o(test_mode_n),
        .test_mode_commit_o(test_mode_commit),
        .frame_cnt_o  (frame_cnt),
        .resync_cnt_o (resync_cnt),
        .err_cnt_o    (err_cnt),
        .hb_ready_o   (hb_ready)
    );

    // ── 喂一个字节（单周期 rx_done 脉冲）────────────────────────────────────
    //   ⭐ rx_done 在 negedge 拉高、下一个 negedge 拉低 ⇒ 覆盖一个完整 posedge，
    //      DUT 在该 posedge 采样 rx_done=1 并用非阻塞更新输出。
    task feed;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(negedge clk);
            rx_done = 1'b0;
        end
    endtask

    // ── 喂完一个字节后，在「紧接的 posedge」抓输出 ──────────────────────────
    //   ⭐ commit 脉冲在 rx_done 采样那个 posedge 产生，持续一个周期。
    //     喂字节用的 feed() 停在 negedge，此时 commit 已更新为 1，
    //     用 @(posedge clk) 对齐到「commit 仍为高」的那一拍。
    task feed_capture;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(posedge clk);   // ⭐ DUT 采样 rx_done，本拍输出已更新
            @(negedge clk);
            rx_done = 1'b0;
        end
    endtask

    // ── 喂一帧 = 返回码 + 帧体 + FF FF FF ──────────────────────────────────
    //   ⭐ 最后一个 FF 用 feed_capture（在 posedge 抓输出后停在 negedge），
    //      使调用方在 feed_frame 返回后能立即读到 commit 脉冲（仍为高）。
    task feed_frame;
        input [7:0] retcode;
        input [7:0] body0;   // ⭐ 第一个帧体字节（控件ID/变量序），可为 0 表示"无帧体"
        input [7:0] body1;   // ⭐ 第二个帧体字节（数值），0 表示"无"
        begin
            feed(retcode);
            feed(body0);
            if (body1 != 8'h00) feed(body1);
            feed(8'hFF);
            feed(8'hFF);
            feed_capture(8'hFF);   // ⭐ 第 3 个 FF：帧结束，commit 在此产生
        end
    endtask

    // ── 静默 N 个 clk（用于触发空闲归位）───────────────────────────────────
    task silence;
        input integer nclk;
        integer i;
        begin
            for (i = 0; i < nclk; i = i + 1) @(negedge clk);
        end
    endtask

    integer i;

    initial begin
        $dumpfile("build/sim/tb_uart_ui/tb_uart_ui.vcd");
        $dumpvars(0, tb_uart_ui);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 复位基线
        // ═══════════════════════════════════════════════════════════════════
        chk("reset: mode=0 (指板默认)", mode === 1'b0);
        chk("reset: base_semi=0 (C4)", base_semi === 7'd0);
        chk("reset: hb_ready=0", hb_ready === 1'b0);
        chk("reset: 无 commit 脉冲", mode_commit === 1'b0 && base_commit === 1'b0);
        chk("reset: 效果器留位恒 0", fx_en === 1'b0 && fx_sel === 2'd0);
        chk("reset: test_mode 默认关", test_mode === 1'b0 && test_mode_n === 2'd0);

        // ═══════════════════════════════════════════════════════════════════
        // ② 握手帧：0x88 + FF FF FF → hb_ready 置位
        // ═══════════════════════════════════════════════════════════════════
        feed_frame(8'h88, 8'h00, 8'h00);
        @(negedge clk);
        chk("握手 0x88 -> hb_ready=1", hb_ready === 1'b1);
        chk("握手计入 frame_cnt", frame_cnt === 16'd1);
        chk("握手不改 mode", mode === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ③ 触摸帧：0x65 + 控件ID=0 + FF FF FF → 模式翻转 + mode_commit
        // ═══════════════════════════════════════════════════════════════════
        //   控件 0 = 模式切换（见 uart_ui 注释 + 决议清单 §B 第 7 项）
        feed_frame(8'h65, 8'h00, 8'h00);
        chk("触摸控件0 -> mode 翻转 =1", mode === 1'b1);
        chk("mode_commit 单周期脉冲", mode_commit === 1'b1);
        @(negedge clk);
        chk("mode_commit 仅 1 拍（下一拍回落）", mode_commit === 1'b0);

        //   再点一次 → 翻回 0
        feed_frame(8'h65, 8'h00, 8'h00);
        @(negedge clk);
        chk("再次触摸 -> mode 翻回 =0", mode === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ④ 数值帧：0x71 + 变量序=1 + 数值=0x18 + FF FF FF → 起始音落地
        // ═══════════════════════════════════════════════════════════════════
        //   变量 1 = 起始音（八度级）。数值 0x18=24 半音 → 高 2 个八度。
        feed_frame(8'h71, 8'h01, 8'h18);
        chk("数值帧 -> base_semi 落地 =12", base_semi === 7'd12);
        chk("base_commit 单周期脉冲", base_commit === 1'b1);
        @(negedge clk);
        chk("base_commit 仅 1 拍", base_commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ④b A1 Test Mode 切档：触摸控件 2 → 关→4→8→16→32→关 循环
        // ═══════════════════════════════════════════════════════════════════
        //   控件 2 = Test Mode 切档（A1 UI 开关）
        feed_frame(8'h65, 8'h02, 8'h00);
        chk("控件2 第1次 -> test_mode=1, n=00(4)", test_mode === 1'b1 && test_mode_n === 2'b00);
        chk("test_mode_commit 单周期脉冲", test_mode_commit === 1'b1);
        @(negedge clk);
        chk("test_mode_commit 仅 1 拍", test_mode_commit === 1'b0);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第2次 -> n=01(8)", test_mode === 1'b1 && test_mode_n === 2'b01);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第3次 -> n=10(16)", test_mode === 1'b1 && test_mode_n === 2'b10);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第4次 -> n=11(32)", test_mode === 1'b1 && test_mode_n === 2'b11);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第5次 -> 32 回到关", test_mode === 1'b0 && test_mode_n === 2'b00);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤ 结束符严格三连：两连 FF 不结束帧
        // ═══════════════════════════════════════════════════════════════════
        //   发 0x65 + 控件0 + FF + FF（只有两个 FF）+ 一个非 FF 数据字节
        //   ⇒ 不应触发 mode 翻转（帧未结束）
        feed(8'h65);
        feed(8'h00);
        feed(8'hFF);
        feed(8'hFF);        // ⭐ 只有两个 FF，帧未结束
        feed(8'h00);        // ⭐ 打断 FF 连续（当作数据）
        @(negedge clk);
        chk("两连 FF 不结束帧（mode 未变）", mode === 1'b0);

        //   现在补齐第 3 个 FF 之外的剩余：先归位，避免残留半帧影响后续
        silence(BYTE_CLK * 40);   // ⭐ 远大于 16 字节时间 ⇒ 归位
        @(negedge clk);
        chk("半帧静默 -> 空闲归位(resync_cnt>0)", resync_cnt > 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ 非法返回码 → err_cnt 自增，不影响状态
        // ═══════════════════════════════════════════════════════════════════
        feed(8'h42);   // ⭐ 'B'，非法返回码
        @(negedge clk);
        chk("非法返回码 -> err_cnt 自增", err_cnt > 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 完整回归：再走一遍握手+触摸+数值，确认状态机可复用
        // ═══════════════════════════════════════════════════════════════════
        feed_frame(8'h88, 8'h00, 8'h00);
        feed_frame(8'h65, 8'h00, 8'h00);   // mode 0→1
        @(negedge clk);
        chk("回归: 再握手+触摸 mode=1", mode === 1'b1);
        chk("回归: frame_cnt 累计", frame_cnt >= 16'd4);

        // ═══════════════════════════════════════════════════════════════════
        // 汇总
        // ═══════════════════════════════════════════════════════════════════
        if (errors == 0) begin
            $display("PASS: tb_uart_ui (%0d checks)", 28);
        end else begin
            $display("FAIL: tb_uart_ui errors=%0d", errors);
        end
        $finish;
    end

endmodule

`default_nettype wire
