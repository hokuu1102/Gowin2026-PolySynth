`timescale 1ns/1ps

module tb_tlc5916_driver;

    localparam integer CLK_PERIOD_NS = 20;

    reg       clk;
    reg       rst_n;
    reg       start;
    reg [7:0] led_data;
    reg       outputs_enable;

    wire tlc_clk;
    wire tlc_sdi;
    wire tlc_le;
    wire tlc_oe_n;
    wire busy;
    wire done;

    integer tlc_clk_count;
    integer le_pulse_count;
    integer error_count;
    reg [7:0] captured_data;

    // ── A1 / A2 · 接线（2026-09-17 加：K-01/K-03 之前**零覆盖**）──────────
    //   A1（`chk_min_pulse`）：`OE`/`LE` 上不得出现窄脉冲 —— 对 `tlc_oe_n` 挂一个，
    //      因为 TI 手册明确"**恰好 1 个 CLK 宽**的 OE 低脉冲(101)"会把器件打进 Special Mode。
    //   A2（`chk_le_shift`）：`LE` 在移位时钟活动期间必须为低。
    //   ⚠️ 例化必须放在被连信号声明之后（Icarus 的 "Unable to bind" 就是声明顺序问题）。
    reg  oe_before, oe_during_busy;
    integer oe_wait;
    integer done_wait;         // ⭐ `done` 等待的循环变量（有上限，防挂死）
    integer done_timeout;      // ⭐ 上限拍数
    integer rec_wait;          // ⭐ 等 Normal-Mode 恢复序列结束的循环变量（有上限）

    // ⭐⭐ K-66：Normal-Mode 恢复序列的**度量**（证明它符合手册的 "101" 形态）
    integer rec_oe_low_edges;      // `OE` 低窗口里跨过了几个 CLK 上升沿（须 = 1）
    integer rec_le_high_during_rec;// 恢复期间 `LE` 为高的拍数（须 = 0）
    integer rec_oe_low_ns;         // `OE` 低电平持续 ns（须 ≥ 500）
    integer rec_clk_periods;       // 恢复序列发了几个 CLK 周期（须 ≥ 5）
    integer rec_enter_count;       // 进入恢复序列的次数（须 = 1）
    reg     rec_oe_prev, rec_clk_prev, rec_seen;
    time    rec_oe_fall_t;
    integer bit_walk;          // ⭐ 逐位走查用的循环变量
    wire [31:0] a1_err, a2_err;
    chk_min_pulse #(.NAME("tlc_oe_n"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (
        .clk(clk), .rst_n(rst_n), .sig(tlc_oe_n), .err_cnt(a1_err));
    chk_le_shift #(.NAME_LE("tlc_le"), .NAME_SCK("tlc_clk")) u_a2 (
        .clk(clk), .rst_n(rst_n), .le(tlc_le), .sck(tlc_clk), .err_cnt(a2_err));

    // ── A8 · X/Z 传播监视（T3 · `tb/checkers/chk_xprop.sv`）──────────────
    // ⭐ 每个 tb 都应挂上它：X 传播是"仿真看着对、上板全死"的最常见来源。
    //    err_cnt 不直接判失败，而是在 initial 末尾并进本 tb 的 error_count（结论仍由 tb 给）。
    // ⚠️ 例化必须放在**所有被连信号声明之后**（Icarus 报 "Unable to bind wire/reg/memory
    //    `captured_data`" 就是这个原因，不是信号名写错）。
    wire [31:0] a8_clk, a8_sdi, a8_le, a8_oe, a8_busy, a8_dat;
    chk_xprop #(.W(1), .NAME("tlc_clk"))  u_a8_clk  (.clk(clk), .rst_n(rst_n), .sig(tlc_clk),      .err_cnt(a8_clk));
    chk_xprop #(.W(1), .NAME("tlc_sdi"))  u_a8_sdi  (.clk(clk), .rst_n(rst_n), .sig(tlc_sdi),      .err_cnt(a8_sdi));
    chk_xprop #(.W(1), .NAME("tlc_le"))   u_a8_le   (.clk(clk), .rst_n(rst_n), .sig(tlc_le),       .err_cnt(a8_le));
    chk_xprop #(.W(1), .NAME("tlc_oe_n")) u_a8_oe   (.clk(clk), .rst_n(rst_n), .sig(tlc_oe_n),     .err_cnt(a8_oe));
    chk_xprop #(.W(1), .NAME("busy"))     u_a8_busy (.clk(clk), .rst_n(rst_n), .sig(busy),         .err_cnt(a8_busy));
    chk_xprop #(.W(8), .NAME("captured")) u_a8_dat  (.clk(clk), .rst_n(rst_n), .sig(captured_data),.err_cnt(a8_dat));

    tlc5916_driver dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .led_data       (led_data),
        .outputs_enable (outputs_enable),
        .tlc_clk        (tlc_clk),
        .tlc_sdi        (tlc_sdi),
        .tlc_le         (tlc_le),
        .tlc_oe_n       (tlc_oe_n),
        .busy           (busy),
        .done           (done)
    );

    always #(CLK_PERIOD_NS / 2) begin
        clk = ~clk;
    end

    // TLC5916 samples SDI on each rising edge of its serial clock.
    // ⚠️⚠️ 必须**排除 Normal-Mode 恢复序列**（`K-66`）的时钟：
    //    那段序列会**故意**发 6 个 `tlc_clk` 周期（手册要求），它们**不是数据移位**。
    //    ⛔ 如果不排除，计数器会多算（实测 `clock count=10, expected 8`）⇒ 假失败。
    //    ⭐ 判据：只在 `recovering == 0`（主 FSM 接管后）才计数。
    //      ⚠️ 用**层次化引用** `dut.recovering`（iverilog 与 Gowin 都支持，见 `K-63` 的边界）。
    always @(posedge tlc_clk) begin
        if (rst_n && dut.recovering !== 1'b1) begin
            captured_data = {captured_data[6:0], tlc_sdi};
            tlc_clk_count = tlc_clk_count + 1;
        end
    end

    always @(posedge tlc_le) begin
        if (rst_n) begin
            le_pulse_count = le_pulse_count + 1;
        end
    end

    // ⭐⭐ K-66：恢复序列的度量（只在 `dut.recovering` 有效期间统计）
    always @(posedge clk) begin
        // 进入次数（上升沿计数）
        if (rst_n === 1'b1 && dut.recovering === 1'b1 && rec_seen === 1'b0) begin
            rec_seen = 1'b1;
            rec_enter_count = rec_enter_count + 1;
        end
        if (rst_n !== 1'b1 || dut.recovering !== 1'b1) rec_seen = 1'b0;

        if (rst_n === 1'b1 && dut.recovering === 1'b1) begin
            // ① `LE` 必须全程低
            if (tlc_le === 1'b1) rec_le_high_during_rec = rec_le_high_during_rec + 1;
            // ② CLK 上升沿计数（用于"低窗口跨过几个上升沿"）
            if (tlc_clk === 1'b1 && rec_clk_prev === 1'b0) rec_clk_periods = rec_clk_periods + 1;
            // ③ `OE` 低窗口跨过几个 CLK 上升沿 + 低电平宽度
            if (tlc_clk === 1'b1 && rec_clk_prev === 1'b0 && tlc_oe_n === 1'b0)
                rec_oe_low_edges = rec_oe_low_edges + 1;
            if (tlc_oe_n === 1'b0 && rec_oe_prev === 1'b1) rec_oe_fall_t = $time;
            if (tlc_oe_n === 1'b1 && rec_oe_prev === 1'b0)
                rec_oe_low_ns = ($time - rec_oe_fall_t) / 1;   // timescale 1ns ⇒ 直接是 ns
            rec_oe_prev = tlc_oe_n;
            rec_clk_prev = tlc_clk;
        end
    end

    task automatic send_and_check(input [7:0] expected_data);
        integer errors_before;

        begin
            errors_before = error_count;
            tlc_clk_count  = 0;
            le_pulse_count = 0;
            captured_data  = 8'h00;

            // ⭐ 等 Normal-Mode 恢复序列跑完（`K-66`）：复位/上电后它会占若干 `tlc_clk` 周期。
            //    ⚠️ 不等的话：① 恢复序列的时钟会被误算进"移位位数"；
            //              ② 恢复期间 `OE` 是关断的 ⇒ 会误判"tlc_oe_n should be low"。
            //    ⭐ 这段等待**有上限**（防挂死）。
            for (rec_wait = 0; rec_wait < 400; rec_wait = rec_wait + 1) begin
                @(negedge clk);
                if (dut.recovering !== 1'b1) rec_wait = 400;
            end

            @(negedge clk);
            led_data = expected_data;

            // ⭐ 2026-09-17：`OE` 现在有"稳定窗 + 只在空闲期更新"的防护（修 K-01），
            //    所以**不能**假设"outputs_enable 一变 OE 就跟着变"。这里先等 OE 真的生效。
            //    ⚠️ **必须有上限**：`check_synchronous_reset()` 里会把 `outputs_enable` 置 0
            //       （此时 OE 本来就该是高），无上限 `wait` 会**死等**、把整个回归挂住
            //       （本文件真踩过：`wait (tlc_oe_n === 1'b0)` 直接超时 600 s）。
            if (outputs_enable === 1'b1) begin
                for (oe_wait = 0; oe_wait < 200; oe_wait = oe_wait + 1) begin
                    @(negedge clk);
                    if (tlc_oe_n === 1'b0) oe_wait = 200;
                end
            end

            start = 1'b1;

            @(negedge clk);
            start = 1'b0;

            // ⚠️⚠️ **必须有上限**（2026-09-17 实测被挂死过）：
            //    原来这里是无上限的 `wait (done === 1'b1);`。
            //    一旦 DUT 因为任何原因**不再产生 `done`**（例如我加 Normal-Mode 恢复序列时
            //    主 FSM 被冻结），这条 `wait` 会**永久挂住** ⇒ 整个回归**卡死 600 s 超时**，
            //    ⛔ 而且**报不出是哪个 tb**（看起来像"工具坏了"）。
            //    ⭐ 规矩：**tb 里任何等待都要有上限**，超时就报 `FAIL:` 并继续
            //      ⇒ 把"挂死"变成"一条清楚的失败信息"。
            //    上限取 `done_timeout` 拍（默认 2000，远超一次传输的 ~50 拍）。
            for (done_wait = 0; done_wait < done_timeout; done_wait = done_wait + 1) begin
                @(negedge clk);
                if (done === 1'b1) done_wait = done_timeout;
            end
            if (done !== 1'b1) begin
                $display("FAIL: data=%02h 等 `done` 超时（%0d 拍内没等到）—— DUT 可能卡在某个状态",
                         expected_data, done_timeout);
                error_count = error_count + 1;
            end
            #1;

            if (tlc_clk_count !== 8) begin
                $display(
                    "ERROR data=%02h: clock count=%0d, expected 8",
                    expected_data, tlc_clk_count
                );
                error_count = error_count + 1;
            end

            if (captured_data !== expected_data) begin
                $display(
                    "ERROR data=%02h: captured=%02h",
                    expected_data, captured_data
                );
                error_count = error_count + 1;
            end

            if (le_pulse_count !== 1) begin
                $display(
                    "ERROR data=%02h: LE count=%0d, expected 1",
                    expected_data, le_pulse_count
                );
                error_count = error_count + 1;
            end

            if (busy !== 1'b0) begin
                $display("ERROR data=%02h: busy should be low", expected_data);
                error_count = error_count + 1;
            end

            if (tlc_le !== 1'b0) begin
                $display("ERROR data=%02h: tlc_le should be low", expected_data);
                error_count = error_count + 1;
            end

            if (tlc_oe_n !== 1'b0) begin
                $display("ERROR data=%02h: tlc_oe_n should be low", expected_data);
                error_count = error_count + 1;
            end

            if (error_count == errors_before) begin
                $display(
                    "PASS: TLC5916 transmitted %02h correctly",
                    expected_data
                );
            end
        end
    endtask

    // The repository contract requires an active-low synchronous reset.
    task automatic check_synchronous_reset;
        begin
            @(negedge clk);
            led_data = 8'hFF;
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait (tlc_clk === 1'b1);
            @(negedge clk);
            rst_n = 1'b0;

            // A synchronous reset must not change registers before clk rises.
            #1;
            if ((tlc_clk !== 1'b1) || (busy !== 1'b1)) begin
                $display("ERROR: reset changed state before a clk rising edge");
                error_count = error_count + 1;
            end

            @(posedge clk);
            #1;
            if ((tlc_clk !== 1'b0) ||
                (tlc_sdi !== 1'b0) ||
                (tlc_le !== 1'b0) ||
                (tlc_oe_n !== 1'b1) ||
                (busy !== 1'b0) ||
                (done !== 1'b0)) begin
                $display("ERROR: synchronous reset did not restore idle outputs");
                error_count = error_count + 1;
            end

            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
            $display("PASS: synchronous reset behavior checked");
        end
    endtask

    initial begin
        $dumpfile("build/sim/tlc5916/tlc5916_tb.vcd");
        $dumpvars(0, tb_tlc5916_driver);

        clk            = 1'b0;
        rst_n          = 1'b0;
        start          = 1'b0;
        led_data       = 8'h00;
        outputs_enable = 1'b0;

        tlc_clk_count  = 0;
        le_pulse_count = 0;
        error_count    = 0;
        captured_data  = 8'h00;
        done_timeout   = 2000;      // ⭐ `done` 等待上限（拍）；一次传输只需 ~50 拍
        // ⭐ K-66 度量初始化
        rec_oe_low_edges = 0; rec_le_high_during_rec = 0; rec_oe_low_ns = 0;
        rec_clk_periods = 0; rec_enter_count = 0; rec_seen = 1'b0;
        rec_oe_prev = 1'b1; rec_clk_prev = 1'b0; rec_oe_fall_t = 0;

        #100;
        rst_n = 1'b1;
        // ⭐ 等 Normal-Mode 恢复序列跑完（`K-66`）：它占 `REC_TOTAL_CLKS` 个 clk_sys 拍。
        //    ⚠️ 不等也可以（`start` 会被 `pending` 记住），但等一等能让下面的
        //       "OE 生效" 前置检查更直观。
        repeat (200) @(negedge clk);

        outputs_enable = 1'b1;

        send_and_check(8'h00);
        send_and_check(8'hA5);
        send_and_check(8'hFF);
        send_and_check(8'h3C);
        check_synchronous_reset();
        send_and_check(8'h5A);

        // ⭐ 2026-09-17 补：**逐位走查**（8 个"只有 1 位为 1"的字节）。
        //    原来只测了 5 个字节（00/A5/FF/3C/5A）—— 虽然覆盖了全 0/全 1/交替，
        //    但**"某一位接错/移位方向错"这类缺陷不一定被抓到**（例如只错 OUT3，
        //    而 A5/3C/5A 恰好没让那一位单独出现）。
        //    ⭐ 单 1 走查是数字接口最经典的完备性检查：8 个字节就能证明
        //      "每一位都按预期位置输出、且位序（MSB first）正确"。
        $display("--- bit-walk: 8 single-bit patterns (proves bit position + MSB-first order) ---");
        for (bit_walk = 0; bit_walk < 8; bit_walk = bit_walk + 1) begin
            send_and_check(8'h01 << bit_walk);
        end
        if (error_count == 0)
            $display("  ok : 逐位走查 8/8 通过（每一位的位置与 MSB-first 位序都对）");
        else
            $display("  (逐位走查中有失败，见上面的 ERROR 行)");

        // ═══════════════════════════════════════════════════════════
        // ⭐⭐ K-01 / A1：`OE` 单周期误脉冲（2026-09-17 新增，之前**零覆盖**）
        //     TI 手册：`OE` 上出现"**恰好 1 个 CLK 宽**的低脉冲(101)"会把器件打进 Special Mode。
        //     ⇒ 本用例故意在 `outputs_enable` 上打**1 拍窄脉冲**，要求 `tlc_oe_n` **完全不动**。
        // ═══════════════════════════════════════════════════════════
        $display("--- A1: OE single-cycle glitch must NOT reach the pin ---");
        // 先让 OE 稳定在"使能"（低）：稳定窗需要 OE_STABLE 拍
        outputs_enable = 1'b1;
        repeat (40) @(negedge clk);
        oe_before = tlc_oe_n;
        if (oe_before !== 1'b0) begin
            $display("FAIL: A1 前置条件不成立：OE 稳定后应为低（实测 %b）", oe_before);
            error_count = error_count + 1;
        end else begin
            $display("  ok : A1 前置：outputs_enable=1 稳定后 tlc_oe_n=0（LED 使能）");
        end

        // ① 1 拍窄脉冲（最危险的形态：恰好 1 个 clk 宽）
        outputs_enable = 1'b0;
        @(negedge clk);
        outputs_enable = 1'b1;
        repeat (30) @(negedge clk);
        if (tlc_oe_n === oe_before) begin
            $display("  ok : A1 ⭐ 1 拍窄脉冲被稳定窗完全滤掉（tlc_oe_n 未动）");
        end else begin
            $display("FAIL: A1 ⛔ 1 拍窄脉冲传到了 OE 引脚（%b -> %b）—— 会进 Special Mode", oe_before, tlc_oe_n);
            error_count = error_count + 1;
        end

        // ② 传输期间改变 `outputs_enable`：`OE` 必须**等回到 IDLE 之后**才动（防护 ②）
        $display("--- A1b: OE change during transfer must wait for IDLE ---");
        fork
            begin : drive_start
                @(negedge clk);
                start    = 1'b1;
                led_data = 8'h3C;
                @(negedge clk);
                start    = 1'b0;
            end
            begin : drive_oe
                repeat (5) @(negedge clk);
                outputs_enable = 1'b0;      // 传输中途要求关断
            end
        join

        // 在 busy 期间采样：OE 不应已经翻转
        oe_during_busy = 1'b0;
        while (busy === 1'b1) begin
            @(negedge clk);
            if (tlc_oe_n === 1'b1) oe_during_busy = 1'b1;
        end
        if (oe_during_busy === 1'b0) begin
            $display("  ok : A1b ⭐ 传输期间 OE 保持不变（只在 CLK 静止 + LE 低时才更新）");
        end else begin
            $display("FAIL: A1b ⛔ 传输期间 OE 就翻转了（可能在 LE 高/CLK 活动时变化）");
            error_count = error_count + 1;
        end

        // 回到 IDLE 后，稳定窗应当把 OE 关断
        repeat (40) @(negedge clk);
        if (tlc_oe_n === 1'b1) begin
            $display("  ok : A1b 回到 IDLE 后 OE 正确关断（outputs_enable=0 被接受）");
        end else begin
            $display("FAIL: A1b 回到 IDLE 后 OE 没有关断（实测 %b）", tlc_oe_n);
            error_count = error_count + 1;
        end
        outputs_enable = 1'b1;
        repeat (40) @(negedge clk);

        // ── A2 结论：LE 在移位期间必须为低（检查器一直在跑）──
        if (a2_err == 0) begin
            $display("PASS: A2 LE 在移位期间全程为低（含上面的 OE 用例期间）");
        end else begin
            $display("FAIL: A2 检测到 %0d 次「LE 为高时移位时钟出现边沿」", a2_err);
            error_count = error_count + 1;
        end

        // ── A1 结论：窄脉冲检查器（对 tlc_oe_n 全程监视）──
        if (a1_err == 0) begin
            $display("PASS: A1 全程未出现窄脉冲（OE/LE 都过了最小宽度检查）");
        end else begin
            $display("FAIL: A1 检测到 %0d 次窄脉冲", a1_err);
            error_count = error_count + 1;
        end

        // ⭐⭐ `K-57`：**参数自检必须被断言**（否则手册约束只打印 ERROR、回归抓不到）
        //    手册 `tlc5916.pdf` 时序表：`tw(OE) Pulse duration, OE(ED2) = 500 ns`。
        //    我们的 `OE_STABLE`（拍）× 时钟周期 必须 ≥ 500 ns。
        //    ⚠️ 这条断言是**变异测试 M14 逼出来的**：M14 把 `OE_STABLE` 改回 8 拍（160 ns），
        //       模块只打 `ERROR`（回归**只认 `FAIL:`**）⇒ 变异体**没被抓到**。
        //       ⇒ 现在把 `TLC_PARAM_OK` 提升为**硬断言**。
        $display("--- K-57: OE stable window vs datasheet tw(OE) >= 500 ns ---");
        if (dut.TLC_PARAM_OK === 1'b1) begin
            $display("  ok : K-57 OE 稳定窗 = %0d ns（≥ 手册 500 ns）", dut.OE_NS);
        end else begin
            $display("FAIL: K-57 OE 稳定窗只有 %0d ns，短于手册 tw(OE) 500 ns", dut.OE_NS);
            error_count = error_count + 1;
        end

        // ── A8 结论：并进本 tb 的 error_count（tb 自己给结论，见验收方案 §六）──
        if (a8_clk == 0 && a8_sdi == 0 && a8_le == 0 && a8_oe == 0 && a8_busy == 0 && a8_dat == 0) begin
            $display("PASS: A8 无 X/Z 传播");
        end else begin
            $display("FAIL: A8 检测到 X/Z 传播（clk=%0d sdi=%0d le=%0d oe=%0d busy=%0d dat=%0d）",
                     a8_clk, a8_sdi, a8_le, a8_oe, a8_busy, a8_dat);
            error_count = error_count + 1;
        end

        // ⭐⭐ K-66：**Normal-Mode 恢复序列**必须真的符合手册的 "101" 形态
        //     手册 Figure 16 + NOTE 1："one-clock-wide short pulse (101) of OE(ED2)" ⇒
        //     进入 Mode Switching；第 4 个 CLK 上升沿采到 `LE` 低 ⇒ 切回 **Normal Mode**。
        //     ⇒ 判据（在**复位释放后**那一段窗口里量）：
        //       ① 复位释放后确实出现了一段"CLK 在跑 + LE 全程低"的窗口（= 恢复序列）
        //       ② 该窗口里 `OE` 的低电平**恰好跨过 1 个 CLK 上升沿**（⛔ 不是 0 个、不是 2 个）
        //       ③ `OE` 低电平宽度 ≥ 手册 `tw(OE) = 500 ns`
        //       ④ 窗口结束后 `recovering` 归 0，且**永不再进入**（只跑一次）
        $display("--- K-66: Normal-Mode recovery sequence (datasheet 101 pulse + LE low) ---");
        // ⚠️ 计数是**跨两次恢复窗口累加**的（本 tb 有 2 次复位释放）⇒ 期望 = 2（每次 1 个）。
        //    ⭐ 判据的真正含义是"**每个恢复窗口恰好跨过 1 个 CLK 上升沿**"
        //      ⇒ 累加值应等于恢复次数。⛔ 不要写成 `== 1`（那会把"跑两次、每次都对"误判为错）。
        if (rec_oe_low_edges == rec_enter_count && rec_enter_count > 0)
            $display("  ok : K-66 ⭐ `OE` 低窗口**每个恢复窗口恰好跨过 1 个 CLK 上升沿**（%0d 次窗口 / %0d 个沿）",
                     rec_enter_count, rec_oe_low_edges);
        else begin
            $display("FAIL: K-66 `OE` 低窗口共跨过 %0d 个 CLK 上升沿，而恢复窗口有 %0d 个（应每窗口恰好 1 个）",
                     rec_oe_low_edges, rec_enter_count);
            error_count = error_count + 1;
        end

        if (rec_le_high_during_rec == 0)
            $display("  ok : K-66 ⭐ 恢复期间 `LE` **全程低**（⇒ 第 4 个沿必判 Normal Mode）");
        else begin
            $display("FAIL: K-66 恢复期间 `LE` 出现了 %0d 次高电平（应全程低）", rec_le_high_during_rec);
            error_count = error_count + 1;
        end

        if (rec_oe_low_ns >= 500)
            $display("  ok : K-66 ⭐ `OE` 低电平宽度 %0d ns ≥ 手册 tw(OE) 500 ns", rec_oe_low_ns);
        else begin
            $display("FAIL: K-66 `OE` 低电平只有 %0d ns，短于手册 tw(OE) 500 ns", rec_oe_low_ns);
            error_count = error_count + 1;
        end

        if (rec_clk_periods >= 5)
            $display("  ok : K-66 恢复序列发了 %0d 个 CLK 周期（≥5，第 4 个沿能采到 LE）", rec_clk_periods);
        else begin
            $display("FAIL: K-66 恢复序列只发了 %0d 个 CLK 周期（<5，第 4 个沿采不到 LE）", rec_clk_periods);
            error_count = error_count + 1;
        end

        // ⚠️ 进入次数：本 tb 里有**两次**复位释放（开头一次 + `check_synchronous_reset` 一次）
        //    ⇒ 恢复序列**每次复位后都会跑一次**，所以期望值 = **2**（⛔ 不是 1）。
        //    ⭐ 关键判据不是"只跑一次"，而是"**每次复位后恰好跑一次**、且不重复触发"。
        if (rec_enter_count == 2)
            $display("  ok : K-66 恢复序列**每次复位后恰好跑一次**（本 tb 有 2 次复位释放 ⇒ 2 次）");
        else begin
            $display("FAIL: K-66 恢复序列进入次数 = %0d（本 tb 有 2 次复位释放，应恰好 2 次）", rec_enter_count);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: all TLC5916 tests completed successfully");
        end
        else begin
            $fatal(
                1,
                "FAIL: TLC5916 tests found %0d error(s)",
                error_count
            );
        end

        #200;
        $finish;
    end

endmodule
