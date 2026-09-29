`timescale 1ns/1ps
// ═══════════════════════════════════════════════════════════════════════════
//  tb_export_key_wav.sv —— ⭐ 导出【按键出声】的 WAV（⭐ 复用 tb_e2e 的注入法）
//
//  ⭐ 目的：⭐ 用户"不能上板了"，⭐ 但仍要判断"按键音色/音量对不对"。
//     ⇒ ⭐ 本 tb 把**按键按下期间**的 `sample_mono` 导成 WAV
//        ⇒ ⭐ 用户**直接听文件**即可判断（⛔ 无需上板）。
//
//  ⭐ **注入方法逐字复用 `tb_e2e_key_to_sound`**（⭐ 那片 tb 已验证能触发按键）：
//     · ⭐ `mcp3208_model` + `ovr_en_i` / `ovr_val_i = RAW_DOWN`
//     · ⭐ **轮询 `at_done`**（⛔ 不等固定拍数）
//     · ⭐ 等自检和弦走完再注入
//
//  ⭐ 产物：`sim/evidence/wav_export/key_press.wav`
//     ⭐ 含三段：静置 → 按下 → 释放（⭐ 便于对比）
// ═══════════════════════════════════════════════════════════════════════════
module tb_export_key_wav;

    localparam integer CPS = 1024;
    localparam integer FS  = 48828;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;
    wire [5:0] spi_miso, spi_cs_n;
    wire spi_sclk, spi_mosi;
    wire miso_l, miso_r;

    //   ⭐ 与 `tb_e2e` **完全一致**的常量
    localparam [11:0] RAW_REST = 12'h7C1;
    localparam [11:0] RAW_DOWN = 12'h4D9;

    reg ovr_l = 1'b0, ovr_r = 1'b0;

    assign spi_cs_n[5:2] = 4'b1111;
    assign spi_miso[5:2] = 4'b1111;
    assign spi_miso[1:0] = {miso_r, miso_l};

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(ovr_l), .ovr_val_i(RAW_DOWN)
    );
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(ovr_r), .ovr_val_i(RAW_DOWN)
    );

    top #(
        .PA_ON_AFTER_RESET (1),
        .DEMO_CHORD_ON     (1),
        .SOURCE_A_SEL      (0),
        .DEMO_NOTE_DELAY   (2000),
        .DEMO_HOLD_CYC     (200_000),
        .AUTOTARE_DELAY_CLK(100_000),
        .PA_ON_DELAY       (32),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4),
        .HEARTBEAT_DIV     (100)
    ) u_top (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN),
        .PA_EN_n(PA_EN_n), .led_heartbeat(led_hb),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .spi_miso(spi_miso), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi),
        .spi_cs_n(spi_cs_n),
        .uart_rx(1'b1), .uart_tx()
    );

    wire signed [23:0] smp = u_top.sample_mono;

    integer fd, k, ns;
    integer mx, clip, tot;
    integer n_ev = 0;
    reg signed [23:0] prev = 0;
    integer nzc = 0;

    function integer ab;
        input signed [23:0] v;
        begin ab = (v < 0) ? -v : v; end
    endfunction

    always @(posedge clk) if (rst_n && u_top.g_sound.w3a_evt_valid) n_ev = n_ev + 1;

    // ── WAV 写入（⭐ 与 tb_export_wav 同一套路）────────────────────────────
    task wr32; input integer v; begin
        $fwrite(fd, "%c", v[7:0]); $fwrite(fd, "%c", v[15:8]);
        $fwrite(fd, "%c", v[23:16]); $fwrite(fd, "%c", v[31:24]);
    end endtask
    task wr16; input integer v; begin
        $fwrite(fd, "%c", v[7:0]); $fwrite(fd, "%c", v[15:8]);
    end endtask

    task wav_header; input integer nsamp; integer db; begin
        db = nsamp * 2;
        $fwrite(fd, "RIFF"); wr32(36 + db); $fwrite(fd, "WAVE");
        $fwrite(fd, "fmt "); wr32(16); wr16(1); wr16(1);
        wr32(FS); wr32(FS*2); wr16(2); wr16(16);
        $fwrite(fd, "data"); wr32(db);
    end endtask

    //   ⭐ 录 N 个样点
    task record; input integer n;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                repeat (CPS - 1) @(negedge clk);
                begin : wr
                    reg signed [15:0] s16;
                    s16 = smp[23:8];
                    $fwrite(fd, "%c", s16[7:0]);
                    $fwrite(fd, "%c", s16[15:8]);
                    ns = ns + 1;
                    if (ab(smp) > mx) mx = ab(smp);
                    if (ab(smp) >= 8300000) clip = clip + 1;
                    if ((prev < 0 && smp >= 0) || (prev >= 0 && smp < 0)) nzc = nzc + 1;
                    prev = smp;
                end
            end
        end
    endtask

    integer w;
    initial begin
        rst_n = 0;
        repeat (40) @(negedge clk);
        rst_n = 1;

        // ⭐ 轮询 at_done（⭐ tb_e2e 的教训：⛔ 不等固定拍数）
        w = 0;
        while (!u_top.g_sound.at_done && w < 500000) begin @(negedge clk); w = w + 1; end
        $display("=== 按键 WAV 导出 ===");
        $display("  at_done=%b (等了 %0d 拍)", u_top.g_sound.at_done, w);

        // ⭐ 等自检和弦走完
        repeat (600_000) @(negedge clk);
        $display("  自检和弦结束后 n_ev=%0d", n_ev);

        fd = $fopen("sim/evidence/wav_export/key_press.wav", "wb");
        if (fd == 0) begin $display("FAIL: 打不开 WAV"); $finish; end

        ns = 0; mx = 0; clip = 0;
        //   🔴 2026-09-26：⭐ 原来录 **24000 样点 = 24.6M 拍** ⇒ ⚠️ **跑 9 分钟仍未到 `$fopen`**
        //      ⇒ ⭐ 改成 **6000 样点**（⭐ ≈0.12 s 音频，⛔ 但我只要判音高/音量，⭐ 够用）。
        //      📌 **教训**：⭐ 录音类 tb 的**规模要按"仿真时间"算**，⛔ 不是按"听感时长"想。
        wav_header(6000);                     // ⭐ 6000 样点 ≈ 0.12 s

        // ═══ 段1: 静置 1500 样点 ═══
        n_ev = 0;
        record(1500);
        $display("  [段1 静置] n_ev=%0d  峰值=%0d  贴顶=%0d  nzc=%0d", n_ev, mx, clip, nzc);

        // ═══ 段2: 按下 3000 样点 ═══
        mx = 0; clip = 0; nzc = 0; n_ev = 0;
        ovr_l = 1'b1;
        record(3000);
        $display("  [段2 按下] n_ev=%0d  峰值=%0d (%.0f%%) 贴顶=%0d  过零=%0d ==> 主频≈%0d Hz",
                 n_ev, mx, mx*100.0/8388607, clip, nzc, nzc*FS/(2*3000));

        // ═══ 段3: 释放 1500 样点 ═══
        mx = 0; clip = 0; nzc = 0;
        ovr_l = 1'b0;
        record(1500);
        $display("  [段3 释放] 峰值=%0d  贴顶=%0d", mx, clip);

        $fclose(fd);
        $display("  ✅ 已写 sim/evidence/wav_export/key_press.wav (%0d 样点)", ns);
        $display("  参考: A2=110Hz D3=147Hz E3=165Hz F3=175Hz");
        $finish;
    end

    initial begin
        #3000000000;
        $display("FAIL: 超时");
        $finish;
    end
endmodule
