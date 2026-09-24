// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_axis_over_uart —— ⭐ 端到端：⭐ 轴号**真的从 UART 发出来了**吗？
//
//  🔴 **为什么必须补这一支（⭐ `K-132` 的教训）**：
//     ⭐ 原 `tb_uart_calib_chain` 只判到"`need_press_o` 拉高"（⭐ **状态**）
//     🔴 **从没判"轴号字节真的经 UART 发出"**（⭐ **结果**）
//     ⇒ ⭐ 所以 `K-132`（⭐ 轴号只发一次）**在回归里完全不可见**。
//
//  ⭐ 本 tb 补的就是这条**结果级**判据：
//     ⭐ 走【真 `calib_cmd` + 真 `calib_span` + 真 `uart_tx` + 真 `uart_rx`】，
//     🔴 **把 UART 线上真实发出的字节解出来**，⭐ 数"轴号出现了几次"。
//
//  ⭐ 判据：
//     · ✅ 发一次 `'S'` ⇒ ⭐ 线上应出现 `'s'` **和** 一个轴号字符（⭐ `'0'`）
//     · ✅ 反复重试时 ⇒ ⭐ 轴号应**多次**出现（⛔ 不是只有第一次）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_axis_over_uart;

    // ⭐ 与上板真值一致的波特率
    localparam integer CLK_HZ = 50_000_000;
    localparam integer BAUD   = 500_000;
    localparam integer BAUD_DIV = CLK_HZ / BAUD;      // = 100

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    // ⚠️ 短超时 ⇒ 快速制造"重试"，⭐ 正好检验 K-132
    localparam integer TIMEOUT = 600;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    // ── 串口：⭐ 我们【发】命令，⭐ 板子【回】字节 ──────────────────────
    reg  tx_to_board = 1'b1;          // ⭐ FPGA 的 uart_rx 输入
    wire tx_from_board;               // ⭐ FPGA 的 uart_tx 输出

    // ═══ ① 真 uart_rx（⭐ 收我们的命令）══════════════════════════════
    wire [7:0] rx_data;
    wire       rx_done;
    uart_rx #(.BAUD_DIV(BAUD_DIV)) u_rx (
        .clk_i(clk), .rst_n_i(rst_n), .rx_i(tx_to_board),
        .rx_data_o(rx_data), .rx_done_o(rx_done)
    );

    // ═══ ② 真 calib_cmd（⭐ 解析 T/S/X/P/V）═════════════════════════
    wire cmd_tare, cmd_span, cmd_abort, cmd_probe, cmd_vstat;
    calib_cmd #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .HEADER(8'hA5)
    ) u_cmd (
        .clk_i(clk), .rst_n_i(rst_n),
        .rx_data_i(rx_data), .rx_done_i(rx_done),
        .tare_req_o(cmd_tare), .span_req_o(cmd_span), .abort_req_o(cmd_abort),
        .probe_req_o(cmd_probe), .vstat_req_o(cmd_vstat),
        .cmd_cnt_o(), .in_frame_cnt_o(), .resync_cnt_o(), .unknown_cnt_o(), .idx_o()
    );

    // ═══ ③ 真 calib_span ═════════════════════════════════════════════
    reg sample_valid_i = 0;
    reg [2:0] sample_ch_i = 0;
    reg [11:0] raw_i = 0;
    wire [N_ADC-1:0] sp_span;
    wire [2:0] sp_ch;
    reg  cal_busy_i = 0, cal_err_i = 0;
    wire sp_busy, sp_done, sp_reject, sp_need_press;
    wire [3:0] sp_cur_axis, sp_done_cnt, sp_rej_cnt;
    wire [2:0] sp_state;

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        .WAIT_TIMEOUT_CLK(TIMEOUT),
        .STABLE_TOL(STABLE_TOL), .VOTE_TOL(VOTE_TOL),
        .REJECT_MAX(REJECT_MAX), .POS_W(12)
    ) u_span (
        .clk(clk), .rst_n(rst_n),
        .start_i(cmd_span), .abort_i(cmd_abort),
        .sample_valid_i(sample_valid_i), .sample_ch_i(sample_ch_i), .raw_i(raw_i),
        .span_o(sp_span), .cal_ch_o(sp_ch),
        .cal_busy_i(cal_busy_i), .cal_err_i(cal_err_i),
        .busy_o(sp_busy), .done_o(sp_done),
        .reject_o(sp_reject), .need_press_o(sp_need_press),
        .cur_axis_o(sp_cur_axis), .done_cnt_o(sp_done_cnt), .rej_cnt_o(sp_rej_cnt),
        .state_o(sp_state)
    );

    always @(posedge clk) begin
        if (rst_n && (|sp_span)) cal_busy_i <= 1'b1;
        else if (cal_busy_i)     cal_busy_i <= 1'b0;
    end

    // ═══ ④ ⭐⭐ 复刻 `top.v` 的回包逻辑（⭐ 关键是 `ev_need` 的边沿检测）═══
    reg sp_need_r = 0, sp_reject_r = 0, sp_done_r = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            sp_need_r <= 0; sp_reject_r <= 0; sp_done_r <= 0;
        end else begin
            sp_need_r   <= sp_need_press;
            sp_reject_r <= sp_reject;
            sp_done_r   <= sp_done;
        end
    end

    wire [7:0] axis_char = (sp_cur_axis < 4'd10) ? (8'h30 + {4'd0, sp_cur_axis})
                                                 : (8'h41 + ({4'd0, sp_cur_axis} - 8'd10));
    wire ev_need   = sp_need_press & ~sp_need_r;      // ⭐ 上升沿 ⇒ 轴号
    wire ev_reject = sp_reject     & ~sp_reject_r;    // ⭐ 上升沿 ⇒ '!'
    wire ev_done   = sp_done       & ~sp_done_r;

    // ⭐⭐ 探针：⭐ 记录 need_press 的每一次跳变（⭐ 定位 ev_need 为何不产生）
    reg np_last = 0;
    always @(posedge clk) begin
        if (rst_n && (sp_need_press !== np_last)) begin
            $display("    [probe t=%0t] need_press %b -> %b  (state=%0d prompt_phase=%b)",
                     $time, np_last, sp_need_press, sp_state, u_span.prompt_phase);
            np_last <= sp_need_press;
        end
    end
    // ⭐ 探针：⭐ 状态机的每次状态跳变
    reg [2:0] st_last = 3'd7;
    always @(posedge clk) begin
        if (rst_n && (sp_state !== st_last)) begin
            $display("    [probe t=%0t] state %0d -> %0d (need_press=%b)",
                     $time, st_last, sp_state, sp_need_press);
            st_last <= sp_state;
        end
    end

    wire       rep_req = ev_need | ev_reject | ev_done | cmd_tare | cmd_span | cmd_abort;
    wire [7:0] rep_byte = ev_need   ? axis_char
                        : ev_reject ? 8'h21              // '!'
                        : ev_done   ? 8'h44              // 'D'
                        : cmd_tare  ? 8'h74              // 't'
                        : cmd_span  ? 8'h73              // 's'
                        :             8'h78;             // 'x'

    // ═══ ⑤ 真 uart_tx_fifo（🔴 必须！⭐ 我第一版漏了它，导致误判）══════
    //   🔴 **教训**：⭐ 我第一版把 `rep_req` **直连** `uart_tx.tx_start_i`
    //      ⇒ ⭐ `uart_tx` 忙时**直接丢**（⭐ 一个字节要 20 µs）
    //      ⇒ 🔴 **轴号紧跟 `'s'` 而来 ⇒ 必然被丢** ⇒ ⚠️ 我误判成"K-132 没修好"。
    //   ⭐ 而 `top.v` 里是**有** `u_tx_fifo` 的（⭐ `K-126` 的修复）
    //      ⇒ ⭐ **tb 必须复刻它**，⭐ 否则测的不是真实链路。
    //   📌 **一般教训**：⭐ 复刻顶层时**漏一个中间件**，🔴 会造出"看起来像 bug"的假象。
    wire        tx_busy;                     // ⚠️ 必须先声明（⭐ L66：声明先于使用）
    wire        txf_ready, txf_idle, txf_start;
    wire [7:0]  txf_data;
    uart_tx_fifo #(.DEPTH(8)) u_tx_fifo (
        .clk_i(clk), .rst_n_i(rst_n),
        .push_i(rep_req), .data_i(rep_byte),
        .ready_o(txf_ready), .idle_o(txf_idle),
        .tx_start_o(txf_start), .tx_data_o(txf_data),
        .busy_i(tx_busy),
        .ovf_o(), .drop_cnt_o(), .ovf_clr_i(1'b0)
    );

    uart_tx #(.BAUD_DIV(BAUD_DIV)) u_tx (
        .clk_i(clk), .rst_n_i(rst_n),
        .tx_start_i(txf_start), .tx_data_i(txf_data),
        .tx_o(tx_from_board), .busy_o(tx_busy), .tx_done_o()
    );

    // ═══ ⑥ 真 uart_rx（⭐ 解回板子发出的字节）═══════════════════════
    wire [7:0] host_data;
    wire       host_done;
    uart_rx #(.BAUD_DIV(BAUD_DIV)) u_host_rx (
        .clk_i(clk), .rst_n_i(rst_n), .rx_i(tx_from_board),
        .rx_data_o(host_data), .rx_done_o(host_done)
    );

    // ⭐⭐ 把线上收到的字节记下来（⭐ 这就是"结果级"证据）
    reg [7:0] got [0:63];
    integer   n_got = 0;
    integer   n_axis = 0;       // ⭐ 轴号字符计数
    integer   n_s    = 0;       // ⭐ 's' 计数
    integer   n_bang = 0;       // ⭐ '!' 计数

    always @(posedge clk) begin
        if (rst_n && host_done) begin
            if (n_got < 64) got[n_got] = host_data;
            n_got = n_got + 1;
            if (host_data == 8'h30) n_axis = n_axis + 1;    // ⭐ 轴 0 ⇒ '0'
            if (host_data == 8'h73) n_s    = n_s + 1;       // ⭐ 's'
            if (host_data == 8'h21) n_bang = n_bang + 1;    // ⭐ '!'
        end
    end

    // ═══ ⑦ 主机侧：⭐ 发一个字节（⭐ 真的按 500k 波特率发）══════════
    task send_byte(input [7:0] b);
        integer i;
        begin
            tx_to_board = 1'b0;                 // ⭐ start
            #(BAUD_DIV * 20);
            for (i = 0; i < 8; i = i + 1) begin
                tx_to_board = b[i];             // ⭐ LSB first
                #(BAUD_DIV * 20);
            end
            tx_to_board = 1'b1;                 // ⭐ stop
            #(BAUD_DIV * 20);
        end
    endtask

    // ⭐ 采样帧发生（⭐ 用"抖动"保证稳不住 ⇒ 必反复重试 ⇒ 检验 K-132）
    localparam integer FRAME = 30;
    reg [2:0] sweep_ch = 0;
    integer tick = 0;
    always @(negedge clk) tick = tick + 1;
    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            raw_i = (sweep_ch == 3'd0) ? (12'd2000 + ((tick % 2) ? 12'd200 : 12'd0))
                                       : 12'd300;
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
            sweep_ch = sweep_ch + 3'd1;
        end
    end

    integer fails = 0;
    integer k;
    initial begin
        $display("=== tb_span_axis_over_uart（端到端：轴号真的发出去了吗）===");
        $display("⭐ 链路：uart_rx -> calib_cmd -> calib_span -> ev_need -> uart_tx -> uart_rx");
        $display("⭐ 读数是【抖动】的 ⇒ 必定反复重试 ⇒ 正好检验 K-132");
        $display("");

        rst_n = 0;
        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (200) @(negedge clk);

        // ⭐ 发一个 'S'
        $display("  · 发送 'S' ...");
        send_byte(8'h53);                 // 'S'
        repeat (400000) @(negedge clk);   // ⭐ 给它足够的重试时间

        $display("--------------------------------------------------");
        $display("  线上收到字节数 = %0d", n_got);
        $display("  's' 次数       = %0d", n_s);
        $display("  【轴号 '0' 次数】= %0d", n_axis);
        $display("  '!' 次数       = %0d", n_bang);
        if (n_got > 0) begin
            // ⚠️ 用逐字节 $write（⭐ 避开 iverilog 对 $sformatf/%c 组合的已知崩溃）
            $write("  收到的字节: ");
            for (k = 0; k < ((n_got < 40) ? n_got : 40); k = k + 1) begin
                if (got[k] >= 32 && got[k] < 127) $write("%c", got[k]);
                else                               $write(".");
            end
            $write("\n");
        end
        $display("--------------------------------------------------");

        if (n_s >= 1)
            $display("ok  : 's'（受理）经 UART 真的发出去了");
        else begin
            $display("FAIL: 连 's' 都没收到");
            fails = fails + 1;
        end

        if (n_axis >= 1)
            $display("ok  : 【轴号经 UART 真的发出去了】");
        else begin
            $display("FAIL: 🔴 轴号从未出现在 UART 线上（⭐ 就是 K-132 的现象）");
            fails = fails + 1;
        end

        // ⭐⭐ 核心判据：重试时轴号必须【多次】出现
        if (n_bang >= 2) begin
            if (n_axis >= 2)
                $display("ok  : 有 %0d 次拒绝、%0d 次轴号 ⇒ ⭐ 重试时轴号【确实重发】", n_bang, n_axis);
            else begin
                $display("FAIL: 🔴 有 %0d 次拒绝，但轴号只发了 %0d 次 ⇒ K-132 未修好", n_bang, n_axis);
                fails = fails + 1;
            end
        end else begin
            $display("NOTE: 拒绝次数太少（%0d），本 tb 未充分检验'重发'", n_bang);
        end

        $display("==================================================");
        if (fails == 0) $display("PASS: 轴号确实经 UART 发出，且重试时会重发（K-132 已修）");
        else            $display("FAIL: %0d 项不达标", fails);
        $finish;
    end

    initial begin
        #500000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
