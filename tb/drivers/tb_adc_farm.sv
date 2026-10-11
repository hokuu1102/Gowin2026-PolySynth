`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_adc_farm · 三片 MCP3208 并行采集总控的单元 tb（丙线 L8，K-79 落地）
//
// 验证目标：
//   1. 三片【并行】采集，一轮 CH0..CH7 内每片各采 8 个通道（共 24 样本）；
//   2. 三片 MISO【独立】—— 用不同 IDVAL 让三片返回不同样本，验证没串线；
//   3. CS/SCLK/MOSI 三路【同源扇出】—— 逐拍一致（K-79：锁步、0 不一致）；
//   4. 帧周期 = 0.5 ms（CHANNEL_RATE_HZ=2k ⇒ FRAME_PERIOD=25_000 周期）；
//   5. 样本汇总：sample_valid / sample_ch / sample_data0/1/2 同拍、值正确。
//
// 判定约定（仓库纪律）：结论用 FAIL:（带冒号），说明性文字用 MUST FAIL。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_adc_farm;

    localparam integer CLK_PERIOD_NS = 20;          // 50 MHz
    localparam integer FRAME_PERIOD_NS = 500_000;   // 0.5 ms（2 kHz）

    reg clk;
    reg rst_n;
    reg enable;

    wire [2:0] adc_cs_n;
    wire [2:0] adc_sclk;
    wire [2:0] adc_mosi;
    wire [2:0] adc_miso;   // 由三片从机模型的 .miso 输出驱动

    wire        sample_valid;
    wire [2:0]  sample_ch;
    wire [11:0] sample_data0;
    wire [11:0] sample_data1;
    wire [11:0] sample_data2;
    wire        frame_done;
    wire [2:0]  fault;

    adc_farm #(
        .N_ADC(3),
        .CLK_HZ(50_000_000),
        .SCLK_HZ(1_000_000),
        .CHANNEL_RATE_HZ(2_000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .adc_cs_n(adc_cs_n), .adc_sclk(adc_sclk), .adc_mosi(adc_mosi), .adc_miso(adc_miso),
        .sample_valid(sample_valid), .sample_ch(sample_ch),
        .sample_data0(sample_data0), .sample_data1(sample_data1), .sample_data2(sample_data2),
        .frame_done(frame_done), .fault(fault)
    );

    // ── 三片 MCP3208 从机模型（不同 IDVAL，验证 MISO 独立）───────────────────
    mcp3208_model #(.IDVAL(12'h000)) u_adc0 (
        .cs_n(adc_cs_n[0]), .sclk(adc_sclk[0]), .mosi(adc_mosi[0]), .miso(adc_miso[0]));
    mcp3208_model #(.IDVAL(12'h400)) u_adc1 (
        .cs_n(adc_cs_n[1]), .sclk(adc_sclk[1]), .mosi(adc_mosi[1]), .miso(adc_miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) u_adc2 (
        .cs_n(adc_cs_n[2]), .sclk(adc_sclk[2]), .mosi(adc_mosi[2]), .miso(adc_miso[2]));

    // ── 时钟 ────────────────────────────────────────────────────────────────
    always #(CLK_PERIOD_NS / 2) clk = ~clk;

    // ── 检查器：CS/SCLK/MOSI 三路同源扇出（逐拍一致，K-79 锁步）─────────────
    // A4 的并行口径替代（chk_fanout_same）：三片必须锁步、扇出逐拍一致。
    wire [31:0] a4p_cs_err, a4p_sclk_err, a4p_mosi_err;
    chk_fanout_same #(.N(3), .NAME("adc_cs_n")) u_a4p_cs (
        .clk(clk), .rst_n(rst_n), .v(adc_cs_n), .err_cnt(a4p_cs_err));
    chk_fanout_same #(.N(3), .NAME("adc_sclk")) u_a4p_sclk (
        .clk(clk), .rst_n(rst_n), .v(adc_sclk), .err_cnt(a4p_sclk_err));
    chk_fanout_same #(.N(3), .NAME("adc_mosi")) u_a4p_mosi (
        .clk(clk), .rst_n(rst_n), .v(adc_mosi), .err_cnt(a4p_mosi_err));

    // ── 样本收集与验证 ──────────────────────────────────────────────────────
    integer sample_count;
    integer frame_count;
    time    first_frame_time;
    time    second_frame_time;
    reg [2:0] expected_ch;
    integer    err_count;

    function automatic [11:0] expect_data(input integer adc_idx, input [2:0] ch);
        begin
            case (adc_idx)
                0: expect_data = 12'h000 + ch;
                1: expect_data = 12'h400 + ch;
                2: expect_data = 12'h800 + ch;
                default: expect_data = 12'h000;
            endcase
        end
    endfunction

    //  ⭐⭐ 2026-10-09（`P1-28`）：⭐ **死片测试开关** ✅
    //   📌 ⭐ 为什么需要：⭐ 下面的逐样本检查器**一直在跑**（⭐ 每拍 `sample_valid` 都查 ✅）
    //     ⚠️ 而死片测试要**故意把某片 MISO 拉死** ⇒ ⭐ 检查器会开始报
    //       `adc0 ch1 data=000 expected=001` ✅（⭐ 那是**预期的**，⛔ 不是真失败 ✅）
    //     ⇒ ⭐ 用一个开关在死片测试期间**关掉它** ✅
    reg dead_test_on = 1'b0;

    always @(posedge clk) begin
        if (rst_n) begin
            #1;
            if (sample_valid) begin
                //  ⭐⭐ 2026-10-09（`P1-28`）：⭐ **只关【检查】、⛔ 不关【计数】** ✅
                //   🔴 **踩过的坑**：⭐ 我第一版把整个 `if (sample_valid)` 块都关掉了
                //      ⇒ ⭐ `sample_count`/`frame_count` **一起停** ✅
                //      ⇒ ⭐ 下面的 `wait (frame_count >= 19)` **永远等不到** ⇒ 🔴 超时 ✅
                //   ✅ 正确做法：⭐ 检查部分用 `!dead_test_on` 挡住 ✅，
                //      ⭐ 而**计数与 `expected_ch` 推进【永远跑】** ✅
                if (!dead_test_on) begin
                    // 通道号应逐拍 0→7 循环（三片锁步，channel 一致）
                    if (sample_ch !== expected_ch) begin
                        $fatal(1, "FAIL: sample order ch=%0d expected=%0d",
                               sample_ch, expected_ch);
                    end
                    // 三片样本各自正确（不同 IDVAL）
                    if (sample_data0 !== expect_data(0, expected_ch)) begin
                        $fatal(1, "FAIL: adc0 ch%0d data=%03h expected=%03h",
                               expected_ch, sample_data0, expect_data(0, expected_ch));
                    end
                    if (sample_data1 !== expect_data(1, expected_ch)) begin
                        $fatal(1, "FAIL: adc1 ch%0d data=%03h expected=%03h",
                               expected_ch, sample_data1, expect_data(1, expected_ch));
                    end
                    if (sample_data2 !== expect_data(2, expected_ch)) begin
                        $fatal(1, "FAIL: adc2 ch%0d data=%03h expected=%03h",
                               expected_ch, sample_data2, expect_data(2, expected_ch));
                    end
                end

                //  ⭐ 计数【永远跑】✅
                sample_count = sample_count + 1;
                expected_ch = (expected_ch == 3'd7) ? 3'd0 : expected_ch + 1'b1;
            end

            if (frame_done) begin
                frame_count = frame_count + 1;
                if (frame_count == 1) first_frame_time = $time;
                else if (frame_count == 2) second_frame_time = $time;
            end
        end
    end

    // ── 主激励 ──────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("build/sim/adc_farm/tb_adc_farm.vcd");
        $dumpvars(0, tb_adc_farm);

        clk = 1'b0;
        rst_n = 1'b0;
        enable = 1'b0;
        sample_count = 0;
        frame_count = 0;
        first_frame_time = 0;
        second_frame_time = 0;
        expected_ch = 3'd0;
        err_count = 0;

        #100;
        @(negedge clk);
        rst_n = 1'b1;
        enable = 1'b1;

        // 等 2 帧完成（每帧 8 通道 × 3 片 = 24 样本）
        wait (frame_count == 2);
        #10;

        // ── 判据 1：样本数 = 2 帧 × 8 通道 = 16 个 sample_valid ──
        if (sample_count !== 16) begin
            $fatal(1, "FAIL: sample_valid count=%0d expected=16", sample_count);
        end

        // ── 判据 2：帧周期 = 0.5 ms ──
        if ((second_frame_time - first_frame_time) !== FRAME_PERIOD_NS) begin
            $fatal(1, "FAIL: frame period=%0d ns expected=%0d ns",
                   second_frame_time - first_frame_time, FRAME_PERIOD_NS);
        end

        // ── 判据 3：同源扇出无不一致（A4 并行口径）──
        if ((a4p_cs_err !== 0) || (a4p_sclk_err !== 0) || (a4p_mosi_err !== 0)) begin
            $fatal(1, "FAIL: 同源扇出不一致 cs=%0d sclk=%0d mosi=%0d",
                   a4p_cs_err, a4p_sclk_err, a4p_mosi_err);
        end

        // ── 判据 4：fault 全程为 0 ──
        if (fault !== 3'b000) begin
            $fatal(1, "FAIL: fault=%b expected=000", fault);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-09（`P1-28`）：⭐ **死片检测判据** ✅
        //   🔴 **未修复代码上必红**（⭐ `fault` 恒 0 ✅）
        //   ⭐ 造现场：⭐ 把片 0 的 `MISO` **拉死为 0**（⭐ 等价于断线/无供电 ✅）
        //      ⇒ ⭐ 片 0 的 raw 恒 `0x000` ⇒ ⭐ 连续 `DEAD_FRAMES` 帧后应判死片 ✅
        //   ⭐ 断言：⭐ `fault[0] === 1'b1`（⭐ 片 0 被抓到 ✅）
        //      ＋ ⭐ `fault[2:1] === 2'b00`（⭐ **其它片不受影响** ✅）
        //   📌 ⭐ 为什么用 `force`：⭐ `adc_miso` 由三个 MCP3208 从机模型驱动 ✅
        //      ⇒ ⭐ 只能 `force` 才能盖住模型 ✅
        // ═══════════════════════════════════════════════════════════════════
        $display("  -- P1-28: force chip-0 MISO stuck at 0, wait %0d frames --", 17);
        dead_test_on = 1'b1;                    // ⭐ 关掉逐样本检查器（⭐ 它会被故意拉死的数据打红 ✅）
        force adc_miso[0] = 1'b0;
        wait (frame_count >= 2 + 17);
        #10;
        if (fault[0] !== 1'b1) begin
            $fatal(1, "FAIL: P1-28 dead-chip NOT detected: fault=%b (chip 0 stuck for 17 frames)", fault);
        end
        if (fault[2:1] !== 2'b00) begin
            $fatal(1, "FAIL: P1-28 false alarm on live chips: fault=%b expected 3'b001", fault);
        end
        $display("  ok  : P1-28 dead chip 0 detected (fault=%b), live chips untouched", fault);
        release adc_miso[0];

        $display("PASS: 2 frames + P1-28 dead-chip window (19 frames total), 16 sample_valid, frame period=%0d ns, fanout clean",
                 second_frame_time - first_frame_time);

        #100;
        $finish;
    end

    // 防挂死
    //  ⭐⭐ 2026-10-09（`P1-28`）：⭐ 看门狗从 **2 ms 抬到 12 ms** ✅
    //   📌 **为什么**：⭐ 死片判据要跑 **19 帧 × 0.5 ms = 9.5 ms** ✅
    //     ⚠️ 原来的 `#2_000_000`（⭐ 2 ms ✅）会**先超时** ⇒ ⭐ 判据永远跑不到 ✅
    //   📌 ⭐ 实测：⭐ 2 ms 的仿真耗时 **4 秒**（墙钟 ✅）
    //     ⇒ ⭐ 12 ms 约 **24 秒** ⇒ ⭐ 远在 tb 预算（120 s）之内 ✅
    initial begin
        #12_000_000;
        $display("  [diag] timeout: frame_count=%0d sample_count=%0d fault=%b t=%0t", frame_count, sample_count, fault, $time);
        $fatal(1, "FAIL: adc_farm simulation timeout");
    end

endmodule

`default_nettype wire
