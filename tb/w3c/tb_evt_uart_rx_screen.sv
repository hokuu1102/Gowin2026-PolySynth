// ===========================================================================
//  tb_evt_uart_rx_screen.sv -- ⭐⭐ 决定性测试：串口屏数据会不会被当成"曲谱事件"？
//
//  背景（2026-09-28 代码审计发现）：
//    `top.v` 里 **同一个 UART 字节流**（`ur_done`/`ur_data`）被【三路共享】：
//       · `uart_ui`      —— TJC 串口屏协议（帧头 0x65/0x70/0x71，尾 0xFF×3）
//       · `calib_cmd`    —— T/S/X/M/N/P/V 命令
//       · `evt_uart_rx`  —— 64 位曲谱事件包，**HEADER = 0xA5**（9 字节定长）
//
//  🔴 风险：`evt_uart_rx` 只在 `idx == 0` 时看帧头，靠**字节计数**维持同步，
//     靠**空闲间隔**归位。而屏幕的 `0x71`（数值返回）帧形如
//         `0x71 <var> <4 个数据字节> FF FF FF`
//     ⭐ **4 个数据字节可以是任意值，包括 0xA5！**
//     ⇒ 只要某个 `0xA5` 到达时 `idx == 0`，`evt_uart_rx` 就会
//       **把后面 8 个屏幕数据字节当成一条事件包** ⇒ 🔴 **注入伪事件**。
//
//  ⭐ 本 tb 的判据（机械可判定）：
//     喂一串**只可能是屏幕发的**字节（0x71 数值帧，数据里含 0xA5），
//     **完全不喂任何合法事件包** ⇒ `evt_valid_o` 必须【永不脉冲】。
//     ⭐ 若它脉冲了 ⇒ **伪事件确认** ⇒ 这就是"挂音/尖音"的注入源。
//
//  ⚠️ 本 tb 只观测，不改 RTL。
// ===========================================================================
`timescale 1ns/1ps

module tb_evt_uart_rx_screen;

    localparam integer CLK_HZ = 50_000_000;
    localparam integer BAUD   = 500_000;
    localparam integer BYTE_CLK = CLK_HZ / BAUD;      // 100 clk/字节

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;                            // 50 MHz

    reg        rx_done = 0;
    reg  [7:0] rx_data = 0;

    wire        evt_valid;
    wire [63:0] evt_data;
    wire [15:0] frame_cnt, resync_cnt, hdr_err_cnt, drop_cnt;
    wire [3:0]  idx;
    wire        synced;

    evt_uart_rx #(
        .CLK_HZ   (CLK_HZ),
        .BAUD     (BAUD),
        .GAP_BYTES(16)
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .rx_done_i    (rx_done),
        .rx_data_i    (rx_data),
        .evt_valid_o  (evt_valid),
        .evt_data_o   (evt_data),
        .frame_cnt_o  (frame_cnt),
        .resync_cnt_o (resync_cnt),
        .hdr_err_cnt_o(hdr_err_cnt),
        .drop_cnt_o   (drop_cnt),
        .idx_o        (idx),
        .synced_o     (synced)
    );

    // ── ⭐ 伪事件监视：整个仿真里只要 evt_valid 脉冲一次就记下 ──────────
    integer n_evt = 0;
    reg [63:0] last_evt = 64'd0;
    integer n_first_evt_clk = -1;
    integer clk_cnt = 0;
    always @(posedge clk) begin
        clk_cnt = clk_cnt + 1;
        if (rst_n && evt_valid) begin
            n_evt = n_evt + 1;
            last_evt = evt_data;
            if (n_first_evt_clk < 0) n_first_evt_clk = clk_cnt;
        end
    end

    task feed_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(negedge clk);
            rx_done = 1'b0;
            repeat (BYTE_CLK) @(negedge clk);         // 一个字节时间
        end
    endtask

    task idle_gap;
        input integer nbytes;
        begin
            repeat (BYTE_CLK * nbytes) @(negedge clk);
        end
    endtask

    task feed_frame;
        input [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8;
        begin
            feed_byte(b0); feed_byte(b1); feed_byte(b2);
            feed_byte(b3); feed_byte(b4); feed_byte(b5);
            feed_byte(b6); feed_byte(b7); feed_byte(b8);
        end
    endtask

    initial begin
        $display("");
        $display("==============================================================");
        $display(" does a TJC SCREEN frame get mistaken for a SCORE event?");
        $display(" (no legal event packet is ever sent here)");
        $display("==============================================================");

        repeat (10) @(negedge clk);
        rst_n = 1;
        idle_gap(20);

        // ── ① 屏幕数值返回帧，数据里【含 0xA5】 ─────────────────────────
        //     ⚠️ 第一次测试发现：0xA5 后面只有 5 字节 ⇒ 凑不满 8 ⇒ 无事件。
        //     ⭐ 所以关键条件是：**0xA5 之后还要有 ≥8 个字节**。
        //        而屏幕【背靠背连发两帧】时正好满足（中间间隔 < GAP_BYTES）。
        $display("  [1] TWO screen frames BACK-TO-BACK (gap < 16 byte-times):");
        $display("      frame A: 71 01 00 A5 00 FF FF FF FF");
        $display("      frame B: 71 02 00 11 00 FF FF FF FF");
        //  frame A 的 0xA5 在 idx=0 起帧，随后 5 字节来自 A，再取 B 的前 3 字节
        feed_byte(8'h71); feed_byte(8'h01); feed_byte(8'h00); feed_byte(8'hA5);
        feed_byte(8'h00); feed_byte(8'hFF); feed_byte(8'hFF); feed_byte(8'hFF);
        feed_byte(8'hFF);
        feed_byte(8'h71);                       // ⭐ 间隔只有 1 个字节时间
        feed_byte(8'h02); feed_byte(8'h00);     // ⭐ 第 8 个数据字节 ⇒ 帧完成
        feed_byte(8'h11); feed_byte(8'h00);
        feed_byte(8'hFF); feed_byte(8'hFF); feed_byte(8'hFF);
        idle_gap(40);
        $display("      after: n_evt=%0d  frame_cnt=%0d  hdr_err=%0d  resync=%0d",
                 n_evt, frame_cnt, hdr_err_cnt, resync_cnt);

        // ── ② 连续多帧（模拟屏幕快速刷新） ──────────────────────────────
        $display("  [2] a long continuous screen stream (8 frames, no long gap):");
        begin : stream
            integer k;
            for (k = 0; k < 8; k = k + 1) begin
                feed_byte(8'h71);
                feed_byte(k[7:0]);
                feed_byte(8'hA5);               // ⭐ 每帧都含 0xA5
                feed_byte(8'hA5);
                feed_byte(8'h00);
                feed_byte(8'hFF);
                feed_byte(8'hFF);
                feed_byte(8'hFF);
                feed_byte(8'hFF);
            end
        end
        idle_gap(40);
        $display("      after: n_evt=%0d  frame_cnt=%0d  hdr_err=%0d  resync=%0d",
                 n_evt, frame_cnt, hdr_err_cnt, resync_cnt);

        $display("");
        $display("  == summary ==");
        $display("   total evt_valid pulses (spurious events) = %0d", n_evt);
        if (n_evt > 0) begin
            $display("   🔴 CONFIRMED: screen data WAS parsed as a score event!");
            $display("      last evt_data = 0x%016X", last_evt);
            $display("      => decoded axis = %0d  (14/15 = reserved, keyboard can NEVER clear it)",
                     last_evt[22:19]);
            $display("      => decoded inc  = 0x%05X", last_evt[43:23]);
            $display("      => decoded kind = %0d (0=on 1=off)", last_evt[10:9]);
        end else begin
            $display("   ✅ no spurious event: screen data is safely ignored.");
        end
        $display("==============================================================");
        $finish;
    end

endmodule
