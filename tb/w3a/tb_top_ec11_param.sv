// ============================================================================
//  tb_top_ec11_param.sv -- EC11 "参数调节模式"（串口屏联动）判据
//
//  ⭐ 被测功能（2026-10-17 新增，rtl/top.v EC11 段）：
//    ① 'p'(0x70) 命令 ⇒ 进入/退出【参数调节模式】（enc_param_mode 切换）
//    ② 进入时锁存 enc_obj_r ⇒ 退出时还回去（"回到原来的模式"）
//    ③ 参数模式下 EC11 转一格 ⇒ enc_par_up(正) / enc_par_dn(负) 各恰好 1 个
//    ④ 退出后转一格 ⇒ 恢复 BPM/变调语义，⛔ 不再出 par_*
//    ⑤ BPM / 变调在参数模式下必须被门住（两个模式不互踩）
//    ⑥ 回传：一次步进 ⇒ 推 9 字节 ASCII 帧（'E' 'e' <mode> <par> <sign> <n> CR LF）
//    ⑦ ⛔ 不是每拍都发；⛔ 参数模式下按按钮也不发（按钮不改状态）
//
//  ⭐ 观测点：ep_push（有字节要发）/ ep_data（那个字节）—— 中间线，
//    ⛔ 不测 uart_tx 引脚（那是 500kbps 比特流，要比特级模型，容易假绿）
//
//  ⚠️ 本项目血的教训：驱动脉冲若用 @(posedge clk); x=1; @(posedge clk); x=0;
//     会跨【两个】posedge ⇒ DUT 采样两次 ⇒ "恰好一个脉冲"必红。
//     ⇒ ⭐ 本文件统一 #DEB_WAIT 拉高/拉低，只跨一个 posedge 的量级
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top_ec11_param;

    localparam real    CLK_N  = 20.0;
    // ── ⭐ 等Debounce 稳定的时间 ───────────────────────────────────────────
    //  ⚠️ debounce #(DB_MS=5) ⇒ 必须稳定 5 ms 才认一次
    //  5 ms @ 50 MHz = 250,000 个时钟 = 5,000,000 ns
    //  ⇒ ⭐ 每一相保持 ≥ 6 ms（= 300,000 ns），⛔ 不能只给几十 ns
    // ── ⭐⭐⭐ 提速（关键，否则这个 tb 物理上跑不完）────────────────────────
    //  ⚠️ debounce #(DB_MS=5) ⇒ 真板上必须等 5 ms 才认一次稳定；
    //     ⭐ 但 tb 只验【逻辑】，⛔ 不验真实手感 ⇒ 用 defparam 把去抖缩短
    //  📌 这不是"为测试改设计"：defparam 只改【tb 里的这份实例】，
    //     ⭐ rtl/top.v 的 DB_MS=5 一字不动，上板行为完全不变
    //  📌 项目里已有同一手法：tb/top/tb_top_dump_atomic.sv 用
    //     defparam 把 SCAN_DIV 12500→4、DEB_N 8→2（见该文件注释）
    //
    //  🔴🔴 不许压到 0（我踩过）：DB_CYC = (CLK_HZ/1000)*DB_MS = 0
    //     ⇒ 判据 `key_cnt >= DB_CYC-1` = `>= 32'hFFFFFFFF` ⇒ 永远不成立
    //     ⇒ 🔴 输入被永久卡住，所有 EC11 判据全红（看起来像 RTL 错，实为 tb 卡死）
    //  ✅ 折中：DB_MS = 1（1 ms = 50000 拍）⇒ 每相等 1.2 ms，一格 6 ms，全程 ~0.5 s
    defparam dut.u_enc_debounce.DB_MS = 1;

    // ── ⭐ 每相保持时间：1.2 ms > DB_MS(1ms) 的稳定窗口 ─────────────────────
    localparam integer DEB_NS = 1_200; // 60 cycles > scaled 50-cycle debounce window

    reg clk = 1'b0;
    always #(CLK_N/2) clk = ~clk;

    reg rst_n = 1'b0;
    wire rst_n_sync;

    // ── DUT 的 EC11 输入 ────────────────────────────────────────────────────
    reg enc_a  = 1'b1;
    reg enc_b  = 1'b1;
    reg enc_sw = 1'b1;

    // ── 串口命令入口（⭐⭐ 走 top 的真实端口 uart_rx，⛔ 不直接戳内部 wire）──
    //  ⚠️ 本项目教训：calib_cmd 的 rx_data_i/rx_done_i 是【模块】端口，
    //     top 的入口是 uart_rx ⇒ 中间过 u_uart_rx。tb 必须从 uart_rx 进，
    //     ⛔ 不能去驱动 dut.ur_data / dut.ur_done（那是内部线，且有时序）
    //  ⭐ 抄 tb/e2e/tb_looper_e2e.sv:109 的做法（同样在顶层发串口命令）
    reg  uart_rx_tb = 1'b1;

    // ── 其余输入（免悬空）──────────────────────────────────────────────────
    reg  [3:0]  ctrl_col = 4'b1111;
    reg         pedal_sus = 1'b1, pedal_loop_rec = 1'b1, pedal_loop_play = 1'b1;
    reg esp_uart_rx = 1'b1;

    integer errors = 0;

    rst_sync #(.STAGES(2)) u_rst_sync (.clk(clk), .rst_n_async(rst_n), .rst_n_sync(rst_n_sync));

    top dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enc_a_i          (enc_a),
        .enc_b_i          (enc_b),
        .enc_sw_i         (enc_sw),
        .ctrl_col_i       (ctrl_col),
        .pedal_sus_i      (pedal_sus),
        .pedal_loop_rec_i (pedal_loop_rec),
        .pedal_loop_play_i(pedal_loop_play),
        .esp_uart_rx_i    (esp_uart_rx),
        .uart_rx          (uart_rx_tb)
    );

    // ── 探针（⭐ 全挂已存在的层次化信号，⛔ 不为测试改 RTL）──────────────────
    wire        enc_param_mode  = dut.enc_param_mode;
    wire        enc_param_saved = dut.enc_param_saved;
    wire [1:0]  enc_obj_r       = dut.enc_obj_r;
    wire [2:0]  enc_par_sel     = dut.enc_par_sel;
    wire        enc_par_up      = dut.enc_par_up;
    wire        enc_par_dn      = dut.enc_par_dn;
    wire        bpm_up_pulse    = dut.enc_bpm_up_w;
    wire        trans_up_pulse  = dut.enc_trans_up_w;
    wire        ep_push         = dut.ep_push;
    wire [7:0]  ep_data         = dut.ep_data;

    // ── 回传字节收集 ────────────────────────────────────────────────────────
    integer     n_ep_byte = 0;
    reg [7:0]   ep_hist [0:63];

    always @(posedge clk) begin
        if (rst_n_sync && ep_push) begin
            if (n_ep_byte < 64) ep_hist[n_ep_byte] = ep_data;
            n_ep_byte = n_ep_byte + 1;
        end
    end

    // ── 发一个帧外串口命令字节（⭐⭐ 走 uart_rx 真实端口，抄 tb_looper_e2e）──
    //  ⭐ BAUD_CLK=100：50 MHz / 500000 波特 = 100 时钟/位（与 uart_rx.BAUD_DIV(100) 一致）
    localparam integer BAUD_CLK = 100;

    task send_cmd;
        input [7:0] b;
        integer bi;
        begin
            @(negedge clk);
            uart_rx_tb = 1'b0;                      // 起始位
            repeat (BAUD_CLK) @(negedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin // LSB first
                uart_rx_tb = b[bi];
                repeat (BAUD_CLK) @(negedge clk);
            end
            uart_rx_tb = 1'b1;                      // 停止位
            repeat (BAUD_CLK * 2) @(negedge clk);   // 多停一拍，保证帧间空闲
        end
    endtask

    // ── EC11 转"一格" = 4 个格雷步同向 ──────────────────────────────────────
    //  🔴🔴 格雷序必须按 RTL 的 enc_state = {enc_b_lvl, enc_a_lvl} 来写！
    //  （debounce.sv:149  assign enc_state = {enc_b_lvl, enc_a_lvl};）
    //  ⇒ ⭐ 所以下面每一个组合都是 (enc_b, enc_a) 的顺序，⛔ 不是 (a, b)
    //  ⭐ RTL 认的正转（debounce.sv:166-171）：
    //       00→01→11→10→00   （{b,a}）
    //  ⇒ 展开成端口赋值（enc_a, enc_b）：
    //       (a,b) = (0,0) → (1,0) → (1,1) → (0,1)
    task turn_cw;
        begin
            enc_a=0; enc_b=0; #DEB_NS;
            enc_a=1; enc_b=0; #DEB_NS;
            enc_a=1; enc_b=1; #DEB_NS;
            enc_a=0; enc_b=1; #DEB_NS;
            enc_a=0; enc_b=0; #DEB_NS;
        end
    endtask

    //  ⭐ 反转：00→10→11→01→00 ⇒ (a,b) = (0,0)→(0,1)→(1,1)→(1,0)
    task turn_ccw;
        begin
            enc_a=0; enc_b=0; #DEB_NS;
            enc_a=0; enc_b=1; #DEB_NS;
            enc_a=1; enc_b=1; #DEB_NS;
            enc_a=1; enc_b=0; #DEB_NS;
            enc_a=0; enc_b=0; #DEB_NS;
        end
    endtask

    task enc_press;
        begin
            @(negedge clk);
            enc_sw = 1'b0;
            #DEB_NS;
            @(negedge clk);
            enc_sw = 1'b1;
            #DEB_NS;
        end
    endtask

    // ── 计数 par_* 脉冲（⭐⭐ 改成"始终在跑"的边沿计数器）──────────────────
    //  ⚠️ 旧写法在 fork 块里轮询 ncyc 次：
    //     若 turn_cw 的 5×1.2ms = 6 ms 里只跨了 30 万个时钟，
    //     而 ncyc=4000 只覆盖 4000 个时钟 = 80 µs ⇒ 🔴 窗口太窄，脉冲根本不在窗口内
    //  ✅ 新写法：与仿真【全程】并行的一个 always，⛔ 永不漏
    //     （计数器本身在激励前清零，用 rd_ 前缀区分）
    integer rd_n_up = 0, rd_n_dn = 0;
    always @(posedge clk) begin
        if (!rst_n_sync) begin
            rd_n_up <= 0;
            rd_n_dn <= 0;
        end else begin
            if (dut.enc_par_up) rd_n_up <= rd_n_up + 1;
            if (dut.enc_par_dn) rd_n_dn <= rd_n_dn + 1;
        end
    end

    // ── ⑤ 用的"门控计数器"（⭐⭐ 同样改成始终运行，⛔ 不用轮询窗口）────────
    integer rd_n_bpm = 0, rd_n_trans = 0;
    always @(posedge clk) begin
        if (!rst_n_sync) begin
            rd_n_bpm  <= 0;
            rd_n_trans<= 0;
        end else begin
            if (dut.enc_bpm_up_w)   rd_n_bpm  <= rd_n_bpm  + 1;
            if (dut.enc_trans_up_w) rd_n_trans<= rd_n_trans+ 1;
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    integer k, cnt;
    reg [1:0] obj_before;

    initial begin
        $dumpfile("build/sim/tb_top_ec11_param/tb_top_ec11_param.vcd");
        $dumpvars(0, tb_top_ec11_param);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        // ① 复位态
        if (enc_param_mode !== 1'b0) begin
            $display("FAIL: ①-a reset must leave enc_param_mode=0, got %b", enc_param_mode);
            errors = errors + 1;
        end else $display("ok  : ①-a reset => enc_param_mode=0");

        // ① 进 / 出 / 再进
        send_cmd(8'h70);  repeat (8) @(negedge clk);
        if (enc_param_mode !== 1'b1) begin
            $display("FAIL: ①-b one 'p' must ENTER param mode, got %b", enc_param_mode);
            errors = errors + 1;
        end else $display("ok  : ①-b one 'p' => ENTER");

        send_cmd(8'h70);  repeat (8) @(negedge clk);
        if (enc_param_mode !== 1'b0) begin
            $display("FAIL: ①-c second 'p' must EXIT, got %b", enc_param_mode);
            errors = errors + 1;
        end else $display("ok  : ①-c second 'p' => EXIT");

        send_cmd(8'h70);  repeat (8) @(negedge clk);
        if (enc_param_mode !== 1'b1) begin
            $display("FAIL: ①-d third 'p' must ENTER again, got %b", enc_param_mode);
            errors = errors + 1;
        end else $display("ok  : ①-d third 'p' => ENTER again");

        // ② 先退出，用 EC11 按钮把 enc_obj_r 翻成非默认值
        send_cmd(8'h70);  repeat (8) @(negedge clk);
        enc_press;         repeat (8) @(negedge clk);
        obj_before = enc_obj_r;
        if (obj_before !== 2'd1) begin
            $display("FAIL: ②-a precondition: one press must flip enc_obj_r 0=>1, got %0d", enc_obj_r);
            errors = errors + 1;
        end else $display("ok  : ②-a precondition enc_obj_r=%0d", enc_obj_r);

        send_cmd(8'h70);  repeat (8) @(negedge clk);
        if (enc_param_saved !== obj_before) begin
            $display("FAIL: ②-b enter must LATCH enc_obj_r (saved=%b exp %b)",
                     enc_param_saved, obj_before);
            errors = errors + 1;
        end else $display("ok  : ②-b enter latched enc_param_saved=%b", enc_param_saved);

        for (k = 0; k < 5; k = k + 1) enc_press;
        repeat (8) @(negedge clk);
        if (enc_obj_r !== obj_before) begin
            $display("FAIL: ②-c in param mode, button must NOT change enc_obj_r (%b -> %b)",
                     obj_before, enc_obj_r);
            errors = errors + 1;
        end else $display("ok  : ②-c 5 presses left enc_obj_r=%b", enc_obj_r);

        send_cmd(8'h70);  repeat (8) @(negedge clk);
        if (enc_obj_r !== obj_before) begin
            $display("FAIL: ②-d exit must RESTORE enc_obj_r (exp %b got %b)",
                     obj_before, enc_obj_r);
            errors = errors + 1;
        end else $display("ok  : ②-d exit restored enc_obj_r=%b", enc_obj_r);

        // ③ 参数模式内转一格 ⇒ 恰好 1 个 par_up / 1 个 par_dn
        send_cmd(8'h70);  repeat (8) @(negedge clk);

        rd_n_up = 0; rd_n_dn = 0;
        turn_cw;
        repeat (200) @(negedge clk);
        cnt = rd_n_up - rd_n_dn;
        if (cnt !== 1) begin
            $display("FAIL: ③-a one CW detent must give EXACTLY 1 enc_par_up (up=%0d dn=%0d net=%0d)",
                     rd_n_up, rd_n_dn, cnt);
            errors = errors + 1;
        end else $display("ok  : ③-a one CW detent => exactly 1 enc_par_up");

        rd_n_up = 0; rd_n_dn = 0;
        turn_ccw;
        repeat (200) @(negedge clk);
        cnt = rd_n_up - rd_n_dn;
        if (cnt !== -1) begin
            $display("FAIL: ③-b one CCW detent must give EXACTLY 1 enc_par_dn (up=%0d dn=%0d net=%0d)",
                     rd_n_up, rd_n_dn, cnt);
            errors = errors + 1;
        end else $display("ok  : ③-b one CCW detent => exactly 1 enc_par_dn");

        // ④ 退出后转一格 ⇒ 不该再出 par_*
        send_cmd(8'h70);  repeat (8) @(negedge clk);
        rd_n_up = 0; rd_n_dn = 0;
        turn_cw;
        repeat (200) @(negedge clk);
        cnt = rd_n_up - rd_n_dn;
        if (cnt !== 0) begin
            $display("FAIL: ④ after EXIT a detent must NOT produce par_* (up=%0d dn=%0d)", rd_n_up, rd_n_dn);
            errors = errors + 1;
        end else $display("ok  : ④ after exit => no par_* pulse");

        // ⑤ 参数模式内 BPM/变调必须被门住
        send_cmd(8'h70);  repeat (8) @(negedge clk);
        rd_n_bpm = 0; rd_n_trans = 0;
        turn_cw;
        repeat (200) @(negedge clk);
        if (rd_n_bpm !== 0 || rd_n_trans !== 0) begin
            $display("FAIL: ⑤ in param mode bpm/trans must be gated (bpm=%0d trans=%0d)",
                     rd_n_bpm, rd_n_trans);
            errors = errors + 1;
        end else $display("ok  : ⑤ in param mode => bpm=%0d trans=%0d (gated)", rd_n_bpm, rd_n_trans);

        wait(dut.txf_idle && !dut.ep_pending && dut.ep_state == 0);
        repeat(4) @(negedge clk);
        // ⑥ 一次步进 ⇒ 推 8 字节帧
        n_ep_byte = 0;
        for (k = 0; k < 64; k = k + 1) ep_hist[k] = 8'd0;
        repeat (4) @(negedge clk);
        fork
            begin : WAIT6000
                integer j;
                for (j = 0; j < 6000; j = j + 1) @(posedge clk);
            end
            turn_cw;
        join
        repeat (200) @(negedge clk);

        if (n_ep_byte === 0) begin
            $display("FAIL: ⑥ one detent in param mode must push bytes to tx FIFO (got 0)");
            errors = errors + 1;
        end else begin
            $display("ok  : ⑥ one detent => %0d byte(s) pushed, first=0x%02h(%c)",
                     n_ep_byte, ep_hist[0], ep_hist[0]);
            if (ep_hist[0] !== 8'h45) begin
                $display("FAIL: ⑥-b frame must start with 'E'(0x45), got 0x%02h", ep_hist[0]);
                errors = errors + 1;
            end
            if (n_ep_byte !== 8) begin
                $display("FAIL: ⑥-c frame must be exactly 8 bytes (E e m p s n CR LF), got %0d", n_ep_byte);
                errors = errors + 1;
            end else $display("ok  : ⑥-c frame length = 8");
        end

        // ⑦ 安静期间不许发
        n_ep_byte = 0;
        repeat (3000) @(negedge clk);
        if (n_ep_byte !== 0) begin
            $display("FAIL: ⑦ idle must NOT push anything (got %0d)", n_ep_byte);
            errors = errors + 1;
        end else $display("ok  : ⑦ idle => 0 bytes (not per-cycle)");

        // ⑦b 参数模式下按按钮不许发帧
        n_ep_byte = 0;
        enc_press; enc_press;
        repeat (2000) @(negedge clk);
        if (n_ep_byte !== 0) begin
            $display("FAIL: ⑦-b button press in param mode must NOT push a frame (got %0d)", n_ep_byte);
            errors = errors + 1;
        end else $display("ok  : ⑦-b button press => no frame");

        if (errors == 0) $display("PASS: tb_top_ec11_param all checks passed");
        else             $display("FAIL: tb_top_ec11_param had %0d error(s)", errors);
        $finish;
    end

    initial begin
        #100_000_000_000;   // ⭐ 100 s < tb_all.ps1 的 120 s 单 tb 预算（K-94）
        $display("FAIL: TIMEOUT");
        $finish;
    end

defparam dut.MAIN_UART_BAUD = 500000;
// Scale only the debouncer test instance; keep all detent/pulse/frame assertions.
defparam dut.u_enc_debounce.CLK_HZ = 50_000;
endmodule

`default_nettype wire
