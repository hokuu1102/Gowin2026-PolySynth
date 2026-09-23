`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_evt_uart_rx.sv · 串口事件帧解析验收
//
// ⭐ 判据（⭐ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐⭐ **真实 115200 波特率**下端到端解析正确（⚠️ 用**真** `uart_rx`，⛔ 不用桩）
//   ② ⭐⭐ **载荷里的 `0xA5` 不会误同步**（★ 本模块存在的核心理由）
//        —— 🔴 旧思路"扫到 0xA5 就当帧头"必然在这里失败
//   ③ ⭐ **9 个 `0xA5` 的复位帧被抑制**（⛔ 不产生事件，否则弹怪音）
//   ④ ⭐ **空闲间隔归位**：半帧后静默 ⇒ 回到 `idx=0`，下一帧正常
//   ⑤ ⭐ **帧头错 ⇒ 不推进**（⛔ 不把垃圾当数据吞掉）
//   ⑥ ⭐ 大端字节序正确（⭐ 逐位对，⛔ 不只看非零）
//   ⑦ ⭐ `evt_valid_o` 严格单周期
//   ⑧ ⭐ `evt_valid_o` 与 `evt_data_o` **同拍**（经验 `80 号`）
//   ⑨ ⭐ **连续帧不丢**（背靠背 10 帧全到）
//   ⑩ A8 无 X/Z
//   ⑪ ⭐ **计数守恒**：frame + drop + 归位/错头 能对上实际发的字节
// ─────────────────────────────────────────────────────────────────────────────

module tb_evt_uart_rx;

    // ⭐⭐ 2026-09-23：波特率**参数化**，同一套判据跑【两档】——
    //   ① `BAUD_DIV=50`（**1 Mbps**） = ⭐ **交付默认档**（`U-29`；零误差整除）
    //   ② `BAUD_DIV=108`（**460800**）= ⚠️ **退档备选**（⭐ 1 Mbps 若上板误码时退到这一档）
    //   ⚠️ 为什么两档都跑：⭐ **交付默认值必须在仿真里被真测过**，
    //      而退档路径也要可用（⚠️ 否到上板误码时才发现退档没验过）。
    //   📌 判据完全相同 ⇒ 只换这两个数（`BAUD_DIV` 与 `BAUD_HZ`）即可。
    //   🔴 **更正**：本行上一版写"有线档 115200 也要保留"—— ⚠️ **无依据，已作废**
    //      （⭐ 复核 `蓝牙需求分析与实施规划.md` §6之二："115200 是默认值惯性，⛔ 不是最优选"）。
    localparam integer BAUD_DIV = 50;               // ⭐ 1 Mbps @ 50 MHz（整除，零误差）
    localparam integer BAUD_HZ  = 1000000;          // ⭐ 必须与 BAUD_DIV 匹配（切档时一起改）
    localparam real    BIT_NS   = 20.0 * BAUD_DIV;  // ⭐ 一位的 ns 数
    localparam [7:0]   HDR      = 8'hA5;

    integer errors = 0;

    // Expectation queue in ARRIVAL order (one entry per frame that should emit).
    // Declared BEFORE the collector that reads it -- Verilog-2001 requires it.
    localparam integer MAXEXP = 64;
    reg [63:0] exp_q [0:MAXEXP-1];
    integer    exp_head = 0;
    integer    exp_tail = 0;

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz
    reg rst_n = 1'b0;

    // ── 串口线 ─────────────────────────────────────────────────────────────
    reg  rx_line = 1'b1;                            // ⭐ 空闲高

    // ── ⭐ 真 uart_rx（⛔ 不用桩）───────────────────────────────────────────
    wire [7:0] rx_data;
    wire       rx_done;

    // ⚠️ `uart_rx` 的参数名是 `BAUD_DIV`（⛔ 不是 CLK_HZ/BAUD）——
    //    ⭐ 434 = round(50 MHz / 115200)，与 tb 顶部的 `BAUD_DIV` 同值
    uart_rx #(.BAUD_DIV(BAUD_DIV)) u_rx (
        .clk_i(clk), .rst_n_i(rst_n), .rx_i(rx_line),
        .rx_data_o(rx_data), .rx_done_o(rx_done)
    );

    // ── DUT ────────────────────────────────────────────────────────────────
    wire        evt_valid;
    wire [63:0] evt_data;
    wire [15:0] frame_cnt, resync_cnt, hdr_err_cnt, drop_cnt;
    wire [3:0]  idx;
    wire        synced;

    evt_uart_rx #(
        .CLK_HZ(50000000), .BAUD(BAUD_HZ), .GAP_BYTES(16), .HEADER(HDR)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .rx_done_i(rx_done), .rx_data_i(rx_data),
        .evt_valid_o(evt_valid), .evt_data_o(evt_data),
        .frame_cnt_o(frame_cnt), .resync_cnt_o(resync_cnt),
        .hdr_err_cnt_o(hdr_err_cnt), .drop_cnt_o(drop_cnt),
        .idx_o(idx), .synced_o(synced)
    );

    // ── A8 ─────────────────────────────────────────────────────────────────
    wire [127:0] a8_bundle = {evt_data, frame_cnt, resync_cnt, hdr_err_cnt, drop_cnt, idx};
    wire [31:0]  a8_err;
    chk_xprop #(.W(128), .NAME("evt_uart_rx_bundle")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig(a8_bundle), .err_cnt(a8_err)
    );

    // ── ⭐ 发一个字节（真波特率）────────────────────────────────────────────
    // Record that this frame SHOULD produce one event with this payload.
    task expect_frame;
        input [63:0] ww;
        begin
            exp_q[exp_tail] = ww;
            exp_tail = exp_tail + 1;
        end
    endtask

    task send_byte;
        input [7:0] b;
        integer k;
        begin
            rx_line = 1'b0;                         // 起始位
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin     // ⭐ LSB first
                rx_line = b[k];
                #(BIT_NS);
            end
            rx_line = 1'b1;                         // 停止位
            #(BIT_NS);
        end
    endtask

    // ⭐ 发一整帧：帧头 + 8 字节大端
    task send_frame;
        input [63:0] w;
        integer k;
        begin
            send_byte(HDR);
            for (k = 7; k >= 0; k = k - 1) send_byte(w[k*8 +: 8]);   // ⭐ 大端
        end
    endtask

    // ⭐ 静默 N 个字节时间（用于触发空闲归位）
    task idle_bytes;
        input integer n;
        begin
            #(BIT_NS * 10.0 * n);
        end
    endtask

    // ── ⭐ 采集器（⚠️ 沿之后采 —— 观测寄存器输出必须如此，经验 `85 号`）──────
    localparam integer MAXEV = 64;
    reg [63:0] got [0:MAXEV-1];
    integer    n_got = 0;                           // ⚠️ integer 初值是 x，必须显式初始化
    integer    n_same_beat, n_checked;


    always @(posedge clk) begin
        #1;
        if (rst_n && evt_valid) begin
            if (n_got < MAXEV) begin
                got[n_got] = evt_data;
                n_got = n_got + 1;
            end
            // Same-beat probe: compare against an expectation QUEUE, in arrival
            // order.  A single `exp_now` register only holds the most recent
            // frame, so comparing every arrival against it is meaningless.
            if (evt_data === exp_q[exp_head]) n_same_beat = n_same_beat + 1;
            exp_head = exp_head + 1;
            n_checked = n_checked + 1;
        end
    end

    // ── 临时量（⚠️ Verilog-2001：具名 begin/end **不是**声明作用域）──────────
    integer i, k, n_before, n_expect;
    reg [63:0] w;

    // ⭐ 单周期监视
    reg evt_valid_d = 1'b0;
    always @(posedge clk) evt_valid_d <= (rst_n ? evt_valid : 1'b0);
    integer viol;
    always @(posedge clk) begin
        if (rst_n && evt_valid && evt_valid_d) viol = viol + 1;
    end

    initial begin
        $dumpfile("build/sim/evt_uart_rx/tb_evt_uart_rx.vcd");
        $dumpvars(0, tb_evt_uart_rx);

        n_got = 0; n_same_beat = 0; n_checked = 0; viol = 0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ══ 判据 ①+⑥：真实波特率端到端 + 大端字节序 ═══════════════════════
        //   ⚠️ 故意选一个**每个字节都不同**的字，⛔ 避免"碰巧相等"
        w = 64'h0123_4567_89AB_CDEF;
        expect_frame(w);
        send_frame(w);
        repeat (200) @(posedge clk);
        if (n_got != 1) begin
            $display("FAIL: expected exactly 1 event at real 115200 baud, got %0d", n_got);
            errors = errors + 1;
        end else if (got[0] !== w) begin
            $display("FAIL: byte order/payload wrong -- got %016h expected %016h", got[0], w);
            errors = errors + 1;
        end else
            $display("  ok  : real 115200 baud, 64-bit payload exact (big-endian ok)");

        // ══ 判据 ②：⭐⭐ 载荷里含 0xA5 —— ⛔ 不许误同步 ═══════════════════════
        //   ★ 这是本模块存在的核心理由
        //   ⚠️ 构造一条**每个字节都是 0xA5 或接近**的事件（⭐ 最恶劣情况）
        begin : a5_payload
            n_before = n_got;
            // Payload is all 0xA5 EXCEPT the last byte, so the frame is 8/9 A5:
            // it must NOT be suppressed (only an exact 9/9 A5 frame is a reset).
            w = 64'hA5A5_A5A5_A5A5_A5A4;
            expect_frame(w);
            send_frame(w);
            repeat (200) @(posedge clk);
            if (n_got == n_before) begin
                $display("FAIL: an all-0xA5-payload event was SWALLOWED (must only swallow 9/9)");
                errors = errors + 1;
            end else if (got[n_got-1] !== w) begin
                $display("FAIL: A5 payload corrupted -- got %016h expected %016h",
                         got[n_got-1], w);
                errors = errors + 1;
            end else
                $display("  ok  : payload containing 0xA5 bytes parsed correctly (no false sync)");
        end

        // ⭐ 真正的恶劣情况：**载荷中间**出现 0xA5
        begin : a5_middle
            n_before = n_got;
            w = 64'h00A5_00A5_00A5_00A5;      // ⭐ 0xA5 只出现在中间
            expect_frame(w);
            send_frame(w);
            repeat (200) @(posedge clk);
            if (n_got != n_before + 1) begin
                $display("FAIL: 0xA5 in the MIDDLE of the payload broke framing");
                errors = errors + 1;
            end else if (got[n_got-1] !== w) begin
                $display("FAIL: payload with middle 0xA5 corrupted");
                errors = errors + 1;
            end else
                $display("  ok  : 0xA5 in the middle of the payload does NOT resync");
        end

        // ══ 判据 ③：9 个 0xA5 的复位帧必须被【抑制】 ══════════════════════
        begin : reset_seq
            integer drop_before, frame_before;
            n_before    = n_got;
            drop_before = drop_cnt;
            frame_before = frame_cnt;
            // ⭐ 复位序列 = **9 的整数倍**个 0xA5（⚠️ 硬约束，见模块头注释）
            for (k = 0; k < 18; k = k + 1) send_byte(HDR);   // ⭐ 2 帧
            repeat (200) @(posedge clk);
            if (n_got != n_before) begin
                $display("FAIL: the reset sequence produced %0d bogus event(s)",
                         n_got - n_before);
                errors = errors + 1;
            end else if (drop_cnt != drop_before + 2) begin
                $display("FAIL: 18 x 0xA5 should drop exactly 2 frames, drop_cnt=%0d (was %0d)",
                         drop_cnt, drop_before);
                errors = errors + 1;
            end else if (frame_cnt != frame_before) begin
                $display("FAIL: reset sequence incremented frame_cnt");
                errors = errors + 1;
            end else
                $display("  ok  : 18 x 0xA5 reset sequence DROPPED (2 frames), no bogus event");
        end

        // ══ 判据 ④：空闲间隔归位 ═══════════════════════════════════════════
        begin : idle_resync
            integer rs_before;
            rs_before = resync_cnt;
            send_byte(HDR);                 // ⭐ 只发帧头，帧中途断掉
            send_byte(8'h11);
            repeat (50) @(posedge clk);
            if (idx === 4'd0) begin
                $display("FAIL: precondition broken -- idx already 0 (test is vacuous)");
                errors = errors + 1;
            end
            idle_bytes(20);                 // ⭐ 静默 > GAP_BYTES
            repeat (50) @(posedge clk);
            if (resync_cnt == rs_before) begin
                $display("FAIL: idle gap did NOT trigger a resync");
                errors = errors + 1;
            end else if (idx !== 4'd0) begin
                $display("FAIL: after resync idx = %0d, expected 0", idx);
                errors = errors + 1;
            end else
                $display("  ok  : idle gap re-synced to idx=0 (resync_cnt=%0d)", resync_cnt);
            // ⭐ 归位后必须还能正常工作
            n_before = n_got;
            w = 64'hDEAD_BEEF_CAFE_0001;
            expect_frame(w);
            send_frame(w);
            repeat (200) @(posedge clk);
            if (n_got != n_before + 1 || got[n_got-1] !== w) begin
                $display("FAIL: after resync the next frame was not parsed (got %0d)",
                         n_got - n_before);
                errors = errors + 1;
            end else
                $display("  ok  : after resync the next frame parses normally");
        end

        // ══ 判据 ⑤：帧头位置收到非 0xA5 ⇒ 不推进 ═══════════════════════════
        begin : bad_header
            integer he_before, fr_before;
            he_before = hdr_err_cnt;
            fr_before = frame_cnt;
            n_before  = n_got;
            send_byte(8'h5A);               // ⭐ 该是帧头，却是 0x5A
            repeat (50) @(posedge clk);
            if (hdr_err_cnt == he_before) begin
                $display("FAIL: a wrong header byte was not counted");
                errors = errors + 1;
            end else if (frame_cnt != fr_before || n_got != n_before) begin
                $display("FAIL: a wrong header produced an event");
                errors = errors + 1;
            end else if (idx !== 4'd0) begin
                $display("FAIL: a wrong header advanced idx to %0d (must stay 0)", idx);
                errors = errors + 1;
            end else
                $display("  ok  : a wrong header byte is counted and does NOT advance");
        end

        // ══ 判据 ⑨：背靠背 10 帧，⛔ 一帧都不许丢 ══════════════════════════
        begin : back_to_back
            n_before = n_got;
            for (k = 0; k < 10; k = k + 1) begin
                w = 64'h1000_0000_0000_0000 + k;
                expect_frame(w);          // ⭐ 每条都要登记期望（⚠️ 漏了就守恒对不上）
                send_frame(w);
            end
            repeat (400) @(posedge clk);
            n_expect = n_before + 10;
            if (n_got != n_expect) begin
                $display("FAIL: back-to-back lost frames -- got %0d, expected %0d",
                         n_got, n_expect);
                errors = errors + 1;
            end else begin
                // ⭐ 逐条核对内容
                for (k = 0; k < 10; k = k + 1) begin
                    if (got[n_before + k] !== (64'h1000_0000_0000_0000 + k)) begin
                        $display("FAIL: back-to-back frame %0d payload wrong (%016h)",
                                 k, got[n_before + k]);
                        errors = errors + 1;
                    end
                end
                $display("  ok  : 10 back-to-back frames all parsed, payloads exact");
            end
        end

        repeat (200) @(posedge clk);

        // ══ 判据 ⑦：单周期 ════════════════════════════════════════════════
        if (viol != 0) begin
            $display("FAIL: evt_valid_o stayed high across %0d cycle boundary(ies)", viol);
            errors = errors + 1;
        end else
            $display("  ok  : evt_valid_o is strictly single-cycle");

        // ══ 判据 ⑧：valid 与 data 同拍 ═════════════════════════════════════
        if (n_checked < 10) begin
            $display("FAIL: same-beat probe saw only %0d events -- vacuous?", n_checked);
            errors = errors + 1;
        end else if (n_same_beat != n_checked) begin
            $display("FAIL: evt_valid_o and evt_data_o NOT the same beat (%0d/%0d)",
                     n_same_beat, n_checked);
            errors = errors + 1;
        end else
            $display("  ok  : evt_valid_o and evt_data_o are the same beat (%0d/%0d)",
                     n_same_beat, n_checked);

        // ══ 判据 ⑪：守恒（⭐ 精确不变量，⛔ 不用"总数够多"这种空阈值）═══════
        //   ⭐ 真不变量：**每一帧被接受的帧，恰好产生一个事件**；
        //      两个复位帧被计入 drop。⚠️ "总数 ≥ 20" 什么都证明不了。
        if (frame_cnt !== n_got[15:0]) begin
            $display("FAIL: frame_cnt_o (%0d) != events emitted (%0d) -- lost or duplicated",
                     frame_cnt, n_got);
            errors = errors + 1;
        end else if (drop_cnt !== 16'd2) begin
            $display("FAIL: drop_cnt_o = %0d, expected exactly 2 (the two 9xA5 reset frames)",
                     drop_cnt);
            errors = errors + 1;
        end else if (exp_tail !== frame_cnt) begin
            $display("FAIL: expected %0d frames but the parser accepted %0d",
                     exp_tail, frame_cnt);
            errors = errors + 1;
        end else
            $display("  ok  : conservation -- frame_cnt=%0d == events emitted, drop_cnt=2 exactly",
                     frame_cnt);

        // ══ 判据 ⑩：A8 ════════════════════════════════════════════════════
        if (a8_err != 0) begin
            $display("FAIL: A8 X/Z propagation (%0d)", a8_err);
            errors = errors + 1;
        end else
            $display("  ok  : A8 no X/Z on evt_uart_rx outputs");

        if (errors == 0)
            $display("PASS: evt_uart_rx frames 64-bit events at real baud, never false-syncs on a 0xA5 payload, drops the reset sequence, and self-heals on idle gaps");
        else
            $display("FAIL: evt_uart_rx had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`）
    initial begin
        #400_000_000;
        $fatal(1, "FAIL: tb_evt_uart_rx timeout");
    end

endmodule
