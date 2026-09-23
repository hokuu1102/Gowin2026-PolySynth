`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_uart_tx.sv · `uart_tx` 自检（8N1 发送器）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **空闲时 `tx` 为高**（⭐ 串口空闲态；⚠️ 复位值必须是 1）
//   ② ⭐⭐ **环回逐字节一致**：⭐ 把 `tx` 接回【真 `uart_rx`】⇒
//      ⭐ 收到的字节必须与发出的**完全相同**（🔴 这是最强的一条判据）
//   ③ ⭐ **位序正确**：⭐ `0x01` 必须原样回来（⚠️ 若 MSB 先发会变成 `0x80`）
//   ④ ⭐⭐ **单周期 `tx_done_o`**（⛔ 不是宽脉冲）
//   ⑤ ⭐ **`busy_o` 覆盖整个发送期**（⭐ 起始位置起、停止位后落）
//   ⑥ ⭐ **发送中改 `tx_data_i` ⛔ 不影响本字节**（⭐ 锁存有效）
//   ⑦ ⭐ **背靠背连发全部正确**（⭐ 最贴近真实用法）
//   ⑧ ⭐ **各种边界字节**（`00`/`FF`/`55`/`AA`/`80`/`7F`）都正确
//
// ── 🔴 tb 纪律（本项目血泪）──────────────────────────────────────────────────
//   · ⛔ **不要用 `wait(信号)`** —— ⚠️ 它不推进仿真时间 ⇒ 永久阻塞
//   · ⭐ **顶层 `initial` 里 ⛔ 不能声明变量**（Verilog-2001 限制）
//   · ⭐ **`uart_tx` 是 Verilog-2001**（`K-91`）
// ─────────────────────────────────────────────────────────────────────────────

module tb_uart_tx;

    localparam integer BAUD_DIV = 50;        // ⭐ 1 Mbps（⭐ 与交付默认一致）

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

    // ── DUT：发送器 ────────────────────────────────────────────────────
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_line;
    wire       tx_busy;
    wire       tx_done;

    uart_tx #(.BAUD_DIV(BAUD_DIV)) dut_tx (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .tx_start_i(tx_start),
        .tx_data_i (tx_data),
        .tx_o      (tx_line),
        .busy_o    (tx_busy),
        .tx_done_o (tx_done)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 真 `uart_rx` 环回（⭐ 判据② 的核心）
    //   ⭐ 用**真接收器** ⇒ ⭐ 同时验证"发送器对、且与接收器兼容"
    //      ⚠️ 而不是 tb 自己写个采样模型（⭐ 那样两只手可能一起错）
    // ═══════════════════════════════════════════════════════════════════
    wire [7:0] rx_data;
    wire       rx_done;

    uart_rx #(.BAUD_DIV(BAUD_DIV)) dut_rx (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .rx_i      (tx_line),        // ⭐ 环回：tx → rx
        .rx_data_o (rx_data),
        .rx_done_o (rx_done)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 监视器
    // ═══════════════════════════════════════════════════════════════════
    //   🔴🔴 **`rx_captured` 是本 tb 的关键**（⭐ 2026-09-23 踩到）：
    //      ⚠️ 我第一版**在 `send_byte()` 之后才去等 `rx_done`** ——
    //      🔴 而 `send_byte` 内部已经等到了 `busy_o` 落下，
    //         ⭐ 那时 **`rx_done` 早就过去了**（⭐ 接收比停止位结束还早几拍）
    //      ⇒ 🔴 我读到的是**上一个字节**的 `rx_data`（⭐ 第一次读到复位值 0xFF）
    //      ⇒ ⭐ 现象极具误导性：**"只有部分字节错、且错的是别的字节的值"**
    //         ⚠️ 看起来像 RTL 的位序/锁存 bug，⭐ 实际是 tb 采样时机错。
    //   ⭐ **正解：⭐ 用 `always` 块在 `rx_done` 那一刻锁存 `rx_data`**，
    //      ⭐ 然后只比较 `rx_captured` —— ⛔ 不在任务里"事后读"。
    //   📌 同族：项目经验 **85 号**（观测寄存器输出，采样点必须在沿之后）/ **L76**。
    reg [7:0] rx_captured;           // ⭐ `rx_done` 那一拍的 `rx_data`（锁存）
    integer   got_cnt;               // ⭐ 收到的字节数
    integer   done_cnt;              // ⭐ `tx_done_o` 脉冲数
    integer   done_width_bad;        // ⭐ 宽度 > 1 拍的次数
    reg       done_prev;
    integer   done_high_cycles;

    integer busy_cycles;             // ⭐ busy 高的总拍数
    integer expect_busy_cycles;      // ⭐ 理论值 = 10 位 × BAUD_DIV

    always @(posedge clk) begin
        if (rst_n) begin
            //   ⭐⭐ 在 `rx_done` **当拍**锁存数据（⭐ 这是唯一正确的采样点）
            if (rx_done) begin
                rx_captured = rx_data;
                got_cnt     = got_cnt + 1;
            end
            //   ⭐ `tx_done_o` 宽度检查
            if (tx_done) begin
                done_cnt = done_cnt + 1;
                if (done_prev === 1'b1) done_width_bad = done_width_bad + 1;
            end
            done_prev = tx_done;
            //   ⭐ busy 占空
            if (tx_busy) busy_cycles = busy_cycles + 1;
        end
    end

    initial begin
        got_cnt = 0; done_cnt = 0; done_width_bad = 0; done_prev = 1'b0;
        done_high_cycles = 0; busy_cycles = 0; expect_busy_cycles = 0;
        rx_captured = 8'h00;
    end

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 驱动任务
    // ═══════════════════════════════════════════════════════════════════

    // ⭐ 发一个字节，⛔ 不等到它发完（⭐ 用于背靠背 / 锁存测试）
    task poke_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            tx_data  = b;
            tx_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tx_start = 1'b0;
        end
    endtask

    // ⭐ 发一个字节并等它**完全发完**（⭐ `busy_o` 落下）
    task send_byte;
        input [7:0] b;
        begin
            poke_byte(b);
            wait_busy_low();
        end
    endtask

    // ⭐ 等 `busy_o` 落下（⭐ 时钟沿轮询，⛔ 不用 `wait`）
    task wait_busy_low;
        integer n;
        begin
            //   ⭐ 上限：⭐ 10 位 × BAUD_DIV + 余量 ⇒ ⛔ 不会死循环
            for (n = 0; n < (10 * BAUD_DIV + 200); n = n + 1) begin
                @(posedge clk);
                if (tx_busy === 1'b0) n = 10 * BAUD_DIV + 200;
            end
        end
    endtask

    // ⭐ 等一个字节被【接收端】收完（⭐ 环回确认）
    task wait_rx_done;
        input integer timeout;
        integer n;
        begin
            for (n = 0; n < timeout; n = n + 1) begin
                @(posedge clk);
                if (rx_done === 1'b1) n = timeout;
            end
        end
    endtask

    task do_reset;
        begin
            rst_n    = 1'b0;
            tx_start = 1'b0;
            tx_data  = 8'h00;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            //   ⭐⭐ **清 tb 自己的监视器**（⭐ 它们不受 `rst_n` 影响）
            //      ⚠️ 不清 ⇒ 后面 `== N` 的判据会带着旧值失败（⭐ 同族坑）
            got_cnt = 0; done_cnt = 0; done_width_bad = 0; done_prev = 1'b0;
            busy_cycles = 0;
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════
    integer i, k;
    reg [7:0] pat [0:9];
    integer bad_cnt;
    integer g0, d0;
    integer busy0;
    reg [7:0] held;

    initial begin
        $display("=== tb_uart_tx (loopback through the real uart_rx) ===");

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据①：空闲时 `tx` 必须为高
        // ───────────────────────────────────────────────────────────────
        do_reset();
        chk("idle tx line is HIGH (UART idle state)", tx_line === 1'b1);
        chk("busy_o is low when idle", tx_busy === 1'b0);
        chk("tx_done_o is low when idle", tx_done === 1'b0);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐ 判据②③⑧：环回逐字节一致（⭐ 含全部边界模式）
        // ───────────────────────────────────────────────────────────────
        pat[0] = 8'h00;  pat[1] = 8'hFF;  pat[2] = 8'h55;  pat[3] = 8'hAA;
        pat[4] = 8'h01;  pat[5] = 8'h80;  pat[6] = 8'h7F;  pat[7] = 8'hFE;
        pat[8] = 8'h5A;  pat[9] = 8'hA5;

        do_reset();
        bad_cnt = 0;
        for (i = 0; i < 10; i = i + 1) begin
            send_byte(pat[i]);
            //   ⭐ 等接收端确认（⭐ 环回）
            wait_rx_done(4 * 10 * BAUD_DIV);
            if (rx_captured !== pat[i]) begin
                $display("    byte[%0d] sent=%02h got=%02h  <-- MISMATCH", i, pat[i], rx_captured);
                bad_cnt = bad_cnt + 1;
            end
        end
        chk("all 10 loopback bytes arrive EXACTLY (incl. 00/FF/55/AA/80/7F)", bad_cnt == 0);
        chk("all 10 bytes were received (rx_done fired 10 times)", got_cnt >= 10);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据③ 专项：位序（⭐ 0x01 回来必须还是 0x01）
        //   ⚠️ 若 MSB 先发，0x01 会变成 0x80 ⇒ ⭐ 这条能单独抓出位序错
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(8'h01);
        wait_rx_done(4 * 10 * BAUD_DIV);
        chk("bit order is LSB-first (0x01 stays 0x01, NOT 0x80)", rx_captured === 8'h01);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据④：`tx_done_o` 必须是【单周期】
        // ───────────────────────────────────────────────────────────────
        do_reset();
        done_cnt = 0; done_width_bad = 0; done_prev = 1'b0;
        send_byte(8'h3C);
        chk("tx_done_o pulses exactly once per byte", done_cnt == 1);
        chk("tx_done_o is exactly ONE cycle wide (never wider)", done_width_bad == 0);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据④b：`tx_done_o` ⛔ **不得在空闲期残留为高**
        //
        //   🔴 **为什么需要这一条**（⭐ 变异测试实测发现）：
        //      ⚠️ 把默认清零那句去掉后，⭐ 上面判据④ **照样全过**
        //      ⇒ 🔴 变异体 **TX-6 存活**。
        //   ⭐ 原因：⭐ `tx_done_o` 只在停止位那一拍置 1，而**那拍之后
        //      `active_q` 立刻回 0** ⇒ ⚠️ 该分支再也不会进
        //      ⇒ ⭐ "不清零"**碰巧也是 1 拍宽** —— ⚠️ 但这是**巧合，⛔ 不是保证**。
        //   ⭐ 判据：⭐ 发完一个字节后**长时间空转** ⇒ `tx_done_o` 必须为 0。
        //      ⚠️ 任何残留都会让调用方**误以为一直在完成**
        //      ⇒ 🔴 可能反复触发同一次上报（⭐ 静默重复）。
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(8'h96);
        repeat (5 * 10 * BAUD_DIV) @(posedge clk);   // ⭐ 空转 5 个字节时间
        chk("tx_done_o stays LOW long after completion (no residual high)",
            tx_done === 1'b0);
        chk("busy_o stays low while idling after a byte", tx_busy === 1'b0);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑤：`busy_o` 覆盖整个发送期
        //   ⭐ 理论值 = 10 位 × BAUD_DIV（⭐ 起始1 + 数据8 + 停止1）
        //   ⚠️ 允许 ±BAUD_DIV 的边界误差（⭐ 起止拍的归属）
        // ───────────────────────────────────────────────────────────────
        do_reset();
        busy_cycles = 0;
        send_byte(8'h5A);
        expect_busy_cycles = 10 * BAUD_DIV;
        $display("  [busy] actual=%0d expected=%0d", busy_cycles, expect_busy_cycles);
        chk("busy_o spans the whole frame (10 bit times, within 1 bit)",
            (busy_cycles >= expect_busy_cycles - BAUD_DIV) &&
            (busy_cycles <= expect_busy_cycles + BAUD_DIV));

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑥：发送中改 `tx_data_i` ⛔ 不影响本字节
        //   ⭐ 做法：⭐ 启动后立刻改 `tx_data`，⭐ 环回应仍收到**原值**
        // ───────────────────────────────────────────────────────────────
        do_reset();
        @(negedge clk);
        tx_data  = 8'hA5;            // ⭐ 真正要发的
        tx_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        tx_start = 1'b0;
        //   ⭐ 发送**中途**把输入改掉
        repeat (3 * BAUD_DIV) @(posedge clk);
        held = tx_data;              // ⭐ 记下来供参考
        tx_data = 8'h5A;             // 🔴 中途篡改
        wait_busy_low();
        wait_rx_done(4 * 10 * BAUD_DIV);
        chk("mid-transmission change of tx_data_i does NOT corrupt the byte",
            rx_captured === 8'hA5);
        tx_data = 8'h00;

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑦：背靠背连发（⭐ 一收完就发下一个）
        //   ⭐ 最贴近真实用法（⭐ 回传进度时就是一个接一个）
        // ───────────────────────────────────────────────────────────────
        do_reset();
        bad_cnt = 0;
        for (i = 0; i < 8; i = i + 1) begin
            //   ⭐ 等上一个发完 ⇒ 立刻发下一个（⭐ 零间隙）
            if (i > 0) wait_busy_low();
            poke_byte(8'h10 + i[7:0]);
            wait_rx_done(4 * 10 * BAUD_DIV);
            if (rx_captured !== (8'h10 + i[7:0])) begin
                $display("    back-to-back[%0d] sent=%02h got=%02h", i, 8'h10 + i[7:0], rx_captured);
                bad_cnt = bad_cnt + 1;
            end
        end
        chk("8 back-to-back bytes all arrive exactly (no gap needed)", bad_cnt == 0);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 附加：`tx_start_i` 在忙时**必须被忽略**（⛔ 不能打断当前字节）
        //   ⚠️ 这是"调用方忘了看 busy"时的安全性
        // ───────────────────────────────────────────────────────────────
        do_reset();
        poke_byte(8'h77);
        //   ⭐ 发送中途再敲一次 start（⭐ 应被忽略）
        repeat (2 * BAUD_DIV) @(posedge clk);
        poke_byte(8'hEE);
        wait_busy_low();
        wait_rx_done(4 * 10 * BAUD_DIV);
        chk("a start pulsed while busy is IGNORED (first byte survives intact)",
            rx_captured === 8'h77);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 附加：复位必须把 `tx` 拉回空闲高
        // ───────────────────────────────────────────────────────────────
        do_reset();
        poke_byte(8'h00);
        repeat (2 * BAUD_DIV) @(posedge clk);
        chk("busy_o really was high before the reset test", tx_busy === 1'b1);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        chk("reset returns tx to the idle HIGH level", tx_line === 1'b1);
        chk("reset clears busy_o", tx_busy === 1'b0);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ⭐ 收尾：确认复位后仍能正常发（⭐ 不是"复位后卡死"）
        send_byte(8'hC3);
        wait_rx_done(4 * 10 * BAUD_DIV);
        chk("after reset the transmitter still works (0xC3 round-trips)",
            rx_captured === 8'hC3);

        $display("");
        if (errors == 0)
            $display("PASS: uart_tx sends 8N1 LSB-first, latches its data, spans busy over the frame, pulses done for one cycle, ignores start-while-busy and survives mid-byte data changes -- all verified by loopback through the real uart_rx");
        else
            $fatal(1, "FAIL: uart_tx had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
