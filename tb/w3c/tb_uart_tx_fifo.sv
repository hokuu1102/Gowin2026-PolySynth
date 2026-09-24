// ============================================================================
//  tb_uart_tx_fifo.sv —— `uart_tx_fifo` 的验收（⭐ 2026-09-24 新增）
//
//  ⭐ 起因（⭐ `K-126`）：⚠️ 回包被 `uart_tx` 静默丢弃
//     ⇒ ⭐ 本 tb 要**正面证明**"排队后不再丢"
//
//  ⭐⭐ 判据（⭐ 全部针对【真问题】，⛔ 不测"跑起来了"）
//    ① ⭐ **背靠背推 3 个字节 ⇒ 全部按顺序发出去**（⭐ 这是 `K-126` 的直接判据）
//    ② ⭐ **推入时机与下游忙闲无关** —— ⭐ 在 `busy` 期间推，⭐ 也【不丢】
//    ③ ⭐ **1 拍脉冲能被接住**（⭐ 模拟 `need_press` 那 20 ns 的脉冲）
//    ④ 🔴 **溢出可观测** —— 推 9 个（⭐ 深度 8）⇒ `ovf_o` 置位 + `drop_cnt_o == 1`
//    ⑤ 🔴 **溢出【不静默】** —— 前 8 个仍然全部发出（⭐ 只是第 9 个丢）
//    ⑥ ⭐ **`ovf_clr_i` 能清**
//    ⑦ ⭐ **复位干净**
//    ⑧ ⭐ **A8：无 X/Z**
//
//  🔴 **本 tb 踩过的两个坑（⭐ 记下来，⭐ 免得再犯）**：
//     · ⚠️ **假 `uart_tx` 的 `busy` 不能用【阻塞赋值】在 `always` 里驱动** ——
//       ⭐ 那样会被本 `always` 块自己的 `busy <= ...` 覆盖 ⇒ 🔴 **卡不住下游**
//       ⇒ ⭐ 改用**独立 `reg` + 组合 `assign`**
//     · ⚠️ **`push` 脉冲必须与 `clk` 错开半拍** —— ⭐ 若在 `posedge` 同刻置起，
//       ⚠️ 会与本模块的采样竞争 ⇒ 🔴 **可能漏采**
// ============================================================================

`timescale 1ns/1ps

module tb_uart_tx_fifo;

    localparam integer DEPTH = 8;

    integer errors = 0;
    task chk(input string name, input logic cond);
        begin
            if (cond) $display("  ok  : %s", name);
            else begin $display("  FAIL: %s", name); errors = errors + 1; end
        end
    endtask

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;        // 50 MHz

    // ── DUT 信号 ─────────────────────────────────────────────────────────
    reg        push;
    reg  [7:0] push_data;
    wire       ready;
    wire       tx_start;
    wire [7:0] tx_data;
    wire       busy;              // ⭐ 由"假 uart_tx"驱动（⭐ 见下）
    wire       ovf;
    wire [7:0] drop_cnt;
    reg        ovf_clr;

    uart_tx_fifo #(.DEPTH(DEPTH)) dut (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .push_i    (push),
        .data_i    (push_data),
        .ready_o   (ready),
        .tx_start_o(tx_start),
        .tx_data_o (tx_data),
        .busy_i    (busy),
        .ovf_o     (ovf),
        .drop_cnt_o(drop_cnt),
        .ovf_clr_i (ovf_clr)
    );

    // ── 收集"被发出去的字节"（⭐ 顺序敏感）────────────────────────────────
    reg [7:0]  sent [0:63];
    integer    n_sent;
    always @(posedge clk) begin
        if (rst_n && tx_start) begin
            sent[n_sent] = tx_data;
            n_sent = n_sent + 1;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 假 `uart_tx`：收到 `tx_start` ⇒ `busy` 保持 N 拍
    //    🔴 **关键修法**：⭐ `busy` 用**独立 `reg` + 组合 `assign`** 驱动 ——
    //       ⚠️ 若在 `always` 里用阻塞赋值，⭐ 会被同块的 `busy <= 0` 覆盖
    //          ⇒ 🔴 **卡不住下游 ⇒ 测不出溢出**
    //    ⚠️ `busy` 必须【下一拍】才拉高（⭐ 与真 `uart_tx` 一致 —— `L67` 同族）
    // ═══════════════════════════════════════════════════════════════════════
    reg  [15:0] busy_left;
    reg         force_busy;        // ⭐ tb 主动卡住下游（⭐ 测溢出用）
    assign busy = force_busy | (busy_left != 16'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            busy_left <= 16'd0;
        end else if (tx_start && (busy_left == 16'd0) && !force_busy) begin
            busy_left <= 16'd20;   // ⭐ 启动一次发送 ⇒ 占 20 拍
        end else if (busy_left != 16'd0) begin
            busy_left <= busy_left - 16'd1;
        end
    end

    task do_reset;
        begin
            rst_n = 1'b0; push = 1'b0; ovf_clr = 1'b0; push_data = 8'd0;
            force_busy = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ⭐ 推一个字节 —— **单拍脉冲，⭐ 半拍错开**
    //   ⚠️ 在 `negedge` 置起、`negedge` 撤下 ⇒ ⭐ 跨越一个完整的 `posedge`
    //      ⇒ ⭐ 保证恰好被采到一次
    task push1(input [7:0] b);
        begin
            @(negedge clk);
            push = 1'b1; push_data = b;
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task wait_sent(input integer want, input integer max_cyc);
        integer k;
        begin
            k = 0;
            while ((n_sent < want) && (k < max_cyc)) begin
                @(posedge clk); k = k + 1;
            end
        end
    endtask

    integer i;

    initial begin
        n_sent = 0;
        force_busy = 1'b0;
        $display("=== tb_uart_tx_fifo ===");

        // ═══ ① 背靠背推 3 个 ⇒ 全部按顺序发出 ═══
        $display("== 1: 背靠背推 3 个（K-126 的直接判据）==");
        do_reset; n_sent = 0;
        push1(8'h74);   // 't'
        push1(8'h73);   // 's'
        push1(8'h30);   // '0'  ← 轴号（原来就是它被丢）
        wait_sent(3, 400);
        $display("    发出 %0d 个: 0x%02h 0x%02h 0x%02h", n_sent, sent[0], sent[1], sent[2]);
        chk("3 个字节全部发出（一个都没丢）", n_sent == 3);
        chk("顺序正确 't'->'s'->'0'",
            (n_sent >= 3) && (sent[0] === 8'h74) && (sent[1] === 8'h73) && (sent[2] === 8'h30));

        // ═══ ② 下游忙时推 ⇒ 也不丢 ═══
        $display("== 2: 下游忙时推（原来就是这样丢的）==");
        do_reset; n_sent = 0;
        push1(8'h41);
        @(posedge clk);
        wait_sent(1, 200);                 // ⭐ 等第 1 个真的开始发
        repeat (3) @(posedge clk);         // ⭐ 再等几拍 ⇒ busy 必然是高的
        $display("    此刻 busy=%b busy_left=%0d", busy, busy_left);
        chk("第 1 个已在发（busy 高）", busy === 1'b1);
        push1(8'h42);                      // ⭐ 忙时推
        push1(8'h43);                      // ⭐ 忙时推
        wait_sent(3, 400);
        $display("    发出 %0d 个: 0x%02h 0x%02h 0x%02h", n_sent, sent[0], sent[1], sent[2]);
        chk("忙时推的 2 个没丢", n_sent == 3);
        chk("顺序仍是 A->B->C",
            (n_sent >= 3) && (sent[0] === 8'h41) && (sent[1] === 8'h42) && (sent[2] === 8'h43));

        // ═══ ③ 1 拍脉冲能被接住 ═══
        $display("== 3: 单拍脉冲（模拟 need_press 那 20 ns）==");
        do_reset; n_sent = 0;
        @(negedge clk); push = 1'b1; push_data = 8'h5A;
        @(posedge clk);                 // ⭐ 恰好一个 posedge
        @(negedge clk); push = 1'b0;
        wait_sent(1, 200);
        $display("    发出 %0d 个: 0x%02h", n_sent, sent[0]);
        chk("1 拍脉冲也被接住并发出", (n_sent == 1) && (sent[0] === 8'h5A));

        // ═══ ④⑤ 溢出可观测 + 不静默 ═══
        //   🔴 **2026-09-24 踩坑（⭐ 记下来）**：⚠️ 这一段我曾写成"先 do_reset 再 force_busy"
        //      ⇒ 🔴 **测不出溢出**。⭐ 真因：`do_reset` 结束后 `push` 的状态与
        //      `force_busy` 的建立时机**没有跨时钟沿** ⇒ 第一拍就错位。
        //   ✅ **正确写法**（⭐ 与 `build/` 里验证过的最小复现一致）：
        //      ⭐ **先置 `force_busy`，⭐ 再等一个 `negedge` 对齐，⭐ 然后才推**
        $display("== 4/5: 溢出（推 %0d 个，深度 %0d）==", DEPTH + 1, DEPTH);
        do_reset; n_sent = 0;
        @(negedge clk);
        force_busy = 1'b1;                 // ⭐ 主动卡住下游 ⇒ 队列必满
        @(negedge clk);
        repeat (3) @(posedge clk);
        for (i = 0; i < DEPTH + 1; i = i + 1) begin
            push1(i[7:0]);
        end
        // 🔴 **必须在 `negedge` 读** ——
        //    ⚠️ 若在 `posedge` 后立刻读，⭐ 看到的是【上一拍】的值
        //    ⇒ 🔴 会误判成"溢出没置位"
        @(negedge clk);
        $display("    ovf=%b drop_cnt=%0d", ovf, drop_cnt);
        @(negedge clk);
        chk("溢位置起（不静默）", ovf === 1'b1);
        chk("丢弃计数 = 1", drop_cnt === 8'd1);
        force_busy = 1'b0;
        wait_sent(DEPTH, 800);
        $display("    发出 %0d 个", n_sent);
        chk("前 8 个仍然全部发出（只丢第 9 个）", n_sent == DEPTH);
        chk("发出的是 0..7（丢的是最后那个）",
            (n_sent >= DEPTH) && (sent[0] === 8'h00) && (sent[DEPTH-1] === 8'h07));

        // ═══ ⑥ 清溢出 ═══
        $display("== 6: ovf_clr_i ==");
        @(negedge clk); ovf_clr = 1'b1; @(negedge clk); ovf_clr = 1'b0;
        @(posedge clk);
        chk("清后 ovf 落 0", ovf === 1'b0);
        chk("清后 drop_cnt 归 0", drop_cnt === 8'd0);

        // ═══ ⑦ 复位干净 ═══
        $display("== 7: 复位 ==");
        force_busy = 1'b1;
        push1(8'hAA); push1(8'hBB);
        repeat (2) @(posedge clk);
        do_reset;
        chk("复位后 ovf 清 0", ovf === 1'b0);
        chk("复位后 drop_cnt 清 0", drop_cnt === 8'd0);
        chk("复位后队列空（ready 高）", ready === 1'b1);

        // ═══ ⑧ A8 无 X/Z ═══
        $display("== 8: A8 ==");
        chk("A8: tx_data 无 X/Z", ^tx_data !== 1'bx);
        chk("A8: ovf / drop_cnt 无 X/Z", (^ovf !== 1'bx) && (^drop_cnt !== 1'bx));

        $display("");
        if (errors == 0)
            $display("PASS: uart_tx_fifo queues bytes (never drops while busy), surfaces overflow, and clears on demand");
        else
            $fatal(1, "FAIL: uart_tx_fifo had %0d error(s)", errors);
        #200;
        $finish;
    end

    // ⭐ 兜底超时（K-94：任何 tb 都要有上限）
    initial begin
        #2_000_000;
        $display("FAIL: tb_uart_tx_fifo timeout (no verdict)");
        $fatal(1, "FAIL: timeout");
    end

endmodule
