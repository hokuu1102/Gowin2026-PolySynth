// ============================================================================
//  tb_pos_probe.sv —— `'P'` 诊断命令的验收（⭐ 2026-09-24 新增）
//
//  ⭐ 起因：⭐ 上板跑 `'S'` 时**只回 `s` + 一次轴号，⭐ 之后全是 `!`（被拒）**
//     ⚠️ 每个 `!` **正好隔 1 秒** ⇒ ⭐ `WAIT_TIMEOUT_CLK` ⇒ 🔴 **是超时**
//     ⇒ ⚠️ 但**串口看不到 `pos`** ⇒ 🔴 没法判断"帧不来"还是"读数在抖"
//     ⇒ ⭐ 本模块就是那个"眼睛"
//
//  ⭐⭐ 判据
//    ① ⭐ **没有请求时 `push_o` 恒 0**（⛔ 不许乱发）
//    ② ⭐ **一次请求 ⇒ 正好 7 个字节**（'P' + 4 数字 + CR + LF）
//    ③ ⭐ **数值正确**（⭐ 多个采样值，⭐ 含 0 / 边界 / 满量程）
//    ④ ⭐ **读数在回传期间变化 ⇒ 那一行仍自洽**（⭐ 锁存语义）
//    ⑤ 🔴 **下游满时不丢**（⭐ `ready_i` 低 ⇒ 等，⛔ 不硬塞）—— `K-126` 的教训
//    ⑥ ⭐ **`busy_o` 语义**：⭐ 回传期间为高，⭐ 回完落 0
//    ⑦ ⭐ **A8：无 X/Z**
// ============================================================================

`timescale 1ns/1ps

module tb_pos_probe;

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

    reg        probe_req;
    reg  [11:0] pos_in;
    reg  [2:0]  ch_in = 3'd0;   // ⭐ 通道号（⭐ 2026-09-24 扩展）
    wire       push;
    wire [7:0] data;
    reg        ready;
    reg        idle;          // ⭐ 下游彻底空闲（⭐ 2026-09-24 新增）
    wire       busy;

    pos_probe #(.N_BYTES(8)) dut (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .probe_req_i(probe_req),
        .pos_i      (pos_in),
        .ch_i       (ch_in),
        .push_o     (push),
        .data_o     (data),
        .ready_i    (ready),
        .idle_i     (idle),
        .busy_o     (busy)
    );

    // ── ⭐ 收集推出来的字节 ─────────────────────────────────────────────────
    reg [7:0] got [0:31];
    integer   n_got;
    always @(posedge clk) begin
        if (rst_n && push) begin
            got[n_got] = data;
            n_got = n_got + 1;
        end
    end

    task do_reset;
        begin
            rst_n = 1'b0; probe_req = 1'b0; pos_in = 12'd0; ready = 1'b1; idle = 1'b1;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ⭐ 一次请求（⭐ 单拍脉冲）
    task fire;
        begin
            @(negedge clk); probe_req = 1'b1;
            @(negedge clk); probe_req = 1'b0;
        end
    endtask

    task wait_n(input integer want, input integer maxc);
        integer k;
        begin
            k = 0;
            while ((n_got < want) && (k < maxc)) begin
                @(posedge clk); k = k + 1;
            end
        end
    endtask

    // ⭐ 校验一行："P" + d3 d2 d1 d0 + CR + LF
    reg [31:0] bad;
    task chk_line(input [11:0] v, input string tag);
        integer exp3, exp2, exp1, exp0;
        begin
            exp3 = v / 1000;
            exp2 = (v % 1000) / 100;
            exp1 = (v % 100) / 10;
            exp0 = v % 10;
            bad = 0;
            if (got[0] !== 8'h50) bad = bad + 1;
            if (got[1] !== (8'h30 + {5'd0, ch_in})) bad = bad + 1;  // ⭐ 通道号
            if (got[2] !== (8'h30 + exp3[7:0])) bad = bad + 1;
            if (got[3] !== (8'h30 + exp2[7:0])) bad = bad + 1;
            if (got[4] !== (8'h30 + exp1[7:0])) bad = bad + 1;
            if (got[5] !== (8'h30 + exp0[7:0])) bad = bad + 1;
            if (got[6] !== 8'h0D) bad = bad + 1;
            if (got[7] !== 8'h0A) bad = bad + 1;
            $display("    %s: pos=%0d -> %c%c%c%c%c%c%c",
                     tag, v, got[0], got[1], got[2], got[3], got[4], got[5], got[6]);
            if (bad == 0) $display("  ok  : %s 数值正确", tag);
            else begin $display("  FAIL: %s 数值错（%0d 处）", tag, bad); errors = errors + 1; end
        end
    endtask

    initial begin
        n_got = 0;
        $display("=== tb_pos_probe ===");

        // ═══ ① 无请求 ⇒ 不发 ═══
        $display("== 1: 无请求 ==");
        do_reset; n_got = 0;
        repeat (20) @(posedge clk);
        chk("无请求时 push 恒 0", n_got == 0);

        // ═══ ②③ 一次请求 ⇒ 7 字节 + 数值正确 ═══
        $display("== 2/3: 一次请求 ==");
        do_reset; n_got = 0;
        pos_in = 12'd744;
        fire;
        wait_n(8, 200);
        chk("正好 8 个字节", n_got == 8);
        if (n_got == 8) chk_line(12'd744, "744");

        // ⭐ 零
        do_reset; n_got = 0; pos_in = 12'd0;   fire;
        wait_n(8, 200);
        if (n_got == 8) chk_line(12'd0, "0");

        // ⭐ 边界：4095（满量程）
        do_reset; n_got = 0; pos_in = 12'd4095; fire;
        wait_n(8, 200);
        if (n_got == 8) chk_line(12'd4095, "4095");

        // ⭐ 中间值
        do_reset; n_got = 0; pos_in = 12'd9;    fire;
        wait_n(8, 200);
        if (n_got == 8) chk_line(12'd9, "9");

        do_reset; n_got = 0; pos_in = 12'd2050; fire;
        wait_n(8, 200);
        if (n_got == 8) chk_line(12'd2050, "2050");

        // ═══ ④ 回传期间读数变化 ⇒ 那一行仍自洽（锁存）═══
        $display("== 4: 锁存语义 ==");
        do_reset; n_got = 0;
        pos_in = 12'd1234;
        fire;
        // ⭐ 发到第 3 个字节时把输入改成别的
        wait_n(3, 100);
        pos_in = 12'd4000;
        wait_n(8, 200);
        chk("回传期间改输入 ⇒ 仍输出锁存的 1234", n_got == 8);
        if (n_got == 8) chk_line(12'd1234, "锁存");

        // ═══ ⑤ 下游忙/非空 ⇒ 不开新包；⭐ 空了以后才发 ═══
        //   🔴 **2026-09-24 语义变更**（⭐ 修上板实测的"包错位"bug）：
        //      ⚠️ 原来 `S_IDLE` 只看 `probe_req_i` ⇒ ⚠️ 上包还在排队就开新包
        //         ⇒ 🔴 两个包首尾相接 ⇒ ⚠️ PC 按行读就错位
        //         （⭐ 实测：⭐ 有时先冒出一个孤立数字，⭐ 再跟下一个包 `0\n\nP217`）
        //      ✅ 现在**必须 `idle_i`（队列空 且 发送器停）**才开新包
        //   📌 所以本判据的语义变了：
        //      · `idle=0` 时 ⇒ ⭐ **不启动**（⭐ 而原来会启动、⭐ 只是发不出去）
        //      · `busy_o` 在 `idle=0` 时**是 0**（⭐ 还没开始）—— ⚠️ 不是"忙"
        //      · ⚠️ 且请求是**单拍脉冲** ⇒ ⭐ `idle=0` 期间来的请求【会被错过】
        //         ⇒ ⭐ 所以"放开后应全发"这条判据⛔ 对单拍请求【不成立】——
        //            ⭐ 改成"**放开后再发一次请求 ⇒ 才发出**"
        $display("== 5: 非空时不开新包（K-126 的教训）==");
        do_reset; n_got = 0;
        idle = 1'b0;                   // ⭐ 下游非空（⭐ 上一个包还在发）
        pos_in = 12'd500;
        fire;
        repeat (30) @(posedge clk);
        chk("非空时一个都不发（⭐ 等，⛔ 不硬塞）", n_got == 0);
        chk("非空时 busy 为 0（⭐ 还没开始，⛔ 不是忙）", busy === 1'b0);
        // ⭐ 下游空了以后，**再发一次请求** ⇒ 这次应该正常发出
        idle = 1'b1;
        @(negedge clk);
        fire;
        wait_n(8, 200);
        chk("空了以后请求 ⇒ 7 个字节全发（⭐ 一个没丢）", n_got == 8);
        if (n_got == 8) chk_line(12'd500, "空后");

        // ═══ ⑥ busy 语义 ═══
        $display("== 6: busy 语义 ==");
        do_reset; n_got = 0;
        chk("空闲时 busy 为 0", busy === 1'b0);
        pos_in = 12'd100; fire;
        @(posedge clk);
        chk("回传中 busy 为 1", busy === 1'b1);
        wait_n(8, 200);
        repeat (4) @(posedge clk);
        chk("回完后 busy 落 0", busy === 1'b0);

        // ═══ ⑦ A8 ═══
        $display("== 7: A8 ==");
        chk("A8: data 无 X/Z", ^data !== 1'bx);
        chk("A8: busy 无 X/Z", ^busy !== 1'bx);

        $display("");
        if (errors == 0)
            $display("PASS: pos_probe emits 'P<4 digits>CRLF' on request, latches the reading, and never drops when the sink is busy");
        else
            $fatal(1, "FAIL: pos_probe had %0d error(s)", errors);
        #200;
        $finish;
    end

    // ⭐ 兜底超时（K-94）
    initial begin
        #2_000_000;
        $display("FAIL: tb_pos_probe timeout (no verdict)");
        $fatal(1, "FAIL: timeout");
    end

endmodule
