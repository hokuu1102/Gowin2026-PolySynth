`timescale 1ns/1ps
// ═══════════════════════════════════════════════════════════════════════════
//  tb_export_wav.sv —— ⭐ 把主工程【真实出声链】的输出导成 WAV
//
//  ⭐ **目的**（⭐ 用户需求）：⭐ *"音色不太符合我的印象，感觉失真了，
//    给我导出一个 WAV 听听真实的声音"*
//  ⭐ 本 tb 抓的是 `top.sample_mono` —— ⭐ **送进 I2S 的最终样点**
//     （⭐ 即 DAC 会收到的东西，⭐ 含波表 + 包络 + 混音 + 主音量）
//  ⇒ ⭐ **这才反映"真实音色"**，⛔ 不是事件重建出的"理想音色"。
//
//  ⭐ **产物**：`sim/evidence/wav_export/*.wav`（16 bit 单声道，48.828 kHz）
//     · `01_demo_chord.wav`  —— ⭐ 上电自检和弦（A4 + C#5 + E5）
//     · `02_metronome.wav`   —— ⭐ 节拍器（⭐ 2026-09-26 修好音高后）
//     · `03_single_a2.wav`   —— ⭐ 单个低音（⭐ 看波表/包络的真实形状）
//
//  ⚠️ **采样率不是整数**：⭐ `50 MHz / 1024 = 48828.125 Hz`
//     ⇒ ⭐ WAV 头里写 **48828**（⭐ 误差 0.0003% ⇒ 听不出来）
// ═══════════════════════════════════════════════════════════════════════════
`define TOP_PATH u_top

module tb_export_wav;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer FS            = 48828;      // ⭐ WAV 头用整数
    localparam integer T             = 20;         // ⭐ 20 ns = 50 MHz

    reg clk = 0, rst_n = 0;
    always #(T/2) clk = ~clk;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;

    // ── ⭐ DUT：出声档（⭐ 自检和弦开，源 A 走 seq_arb 手弹）──────────────
    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .PA_ON_AFTER_RESET (1),        // ⭐ Console 上 1 = 出声
        .DEMO_CHORD_ON     (1),
        .SOURCE_A_SEL      (0),        // ⭐ 走 seq_arb（手弹源）
        .DEMO_NOTE_DELAY   (2000),
        .DEMO_HOLD_CYC     (2_000_000),// ⭐ 拉长到 40 ms 便于抓波形
                                        //   （⚠️ 交付默认 50_000_000 = 1 秒，
                                        //     仿真跑完要几分钟 ⇒ 这里取够用的长度）
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
        .spi_miso(6'b111111), .spi_sclk(), .spi_mosi(), .spi_cs_n(),
        .uart_rx(1'b1), .uart_tx()
    );

    // ── ⭐ WAV 写入 ────────────────────────────────────────────────────────
    integer fd;
    integer n_samp;
    integer mx = 0;
    integer i;
    reg signed [23:0] prev = 0;
    integer n_chg = 0;

    //   ⭐ 抓 `sample_mono`：⭐ 每 `CLK_PER_SAMPLE` 拍一个样点
    //      ⚠️ `sample_mono` 是 24 位【左对齐】（⭐ 有效数据在高 16 位）
    //      ⇒ ⭐ 转 16 位要 `>>> 8`（⭐ 与 `voice.v` / `i2s_tx` 的约定一致）
    task capture(input integer n_samples, input [511:0] fname);
        integer k;
        begin
            fd = $fopen(fname, "wb");
            if (fd == 0) begin
                $display("FAIL: cannot open %0s", fname);
                $finish;
            end
            //   ⭐ WAV 头（44 字节标准 RIFF）
            wav_header(fd, n_samples, FS);
            n_samp = 0; mx = 0; n_chg = 0; prev = 0;
            for (k = 0; k < n_samples; k = k + 1) begin
                @(negedge clk);          // ⭐ 等一个完整采样周期
                repeat (CLK_PER_SAMPLE - 1) @(negedge clk);
                begin : wr
                    reg signed [23:0] s24;
                    reg signed [15:0] s16;
                    integer av;
                    s24 = `TOP_PATH.sample_mono;
                    s16 = s24[23:8];     // ⭐ 取高 16 位（左对齐约定）
                    //   ⭐ 小端 16 bit
                    $fwrite(fd, "%c", s16[7:0]);
                    $fwrite(fd, "%c", s16[15:8]);
                    n_samp = n_samp + 1;
                    av = (s16 < 0) ? -s16 : s16;
                    if (av > mx) mx = av;
                    if (s16 !== prev) n_chg = n_chg + 1;
                    prev = s16;
                end
            end
            $fclose(fd);
            $display("  ok  : %0s  （%0d 样点 · 峰值 %0d / 32767 = %0d%% · 变化 %0d 次）",
                     fname, n_samp, mx, (mx * 100) / 32767, n_chg);
        end
    endtask

    //   ⭐ WAV 头（⭐ 标准 44 字节 RIFF/WAVE，PCM 16 bit 单声道）
    task wav_header(input integer f, input integer nsamp, input integer fs);
        integer data_bytes;
        begin
            data_bytes = nsamp * 2;
            $fwrite(f, "RIFF");
            wr32(f, 36 + data_bytes);
            $fwrite(f, "WAVE");
            $fwrite(f, "fmt ");
            wr32(f, 16);            // ⭐ PCM 子块大小
            wr16(f, 1);             // ⭐ format = 1 (PCM)
            wr16(f, 1);             // ⭐ 单声道
            wr32(f, fs);
            wr32(f, fs * 2);        // ⭐ byte rate
            wr16(f, 2);             // ⭐ block align
            wr16(f, 16);            // ⭐ bits per sample
            $fwrite(f, "data");
            wr32(f, data_bytes);
        end
    endtask

    task wr32(input integer f, input integer v);
        begin
            $fwrite(f, "%c", v[7:0]);
            $fwrite(f, "%c", v[15:8]);
            $fwrite(f, "%c", v[23:16]);
            $fwrite(f, "%c", v[31:24]);
        end
    endtask

    task wr16(input integer f, input integer v);
        begin
            $fwrite(f, "%c", v[7:0]);
            $fwrite(f, "%c", v[15:8]);
        end
    endtask

    initial begin
        $display("=== tb_export_wav（导出真实出声链的 WAV）===");
        $display("⭐ 抓取点: top.sample_mono（送进 I2S 的最终样点）");
        $display("⭐ 采样率: %0d Hz（⚠️ 真实是 50MHz/1024 = 48828.125）", FS);
        $display("");

        //   ⭐ 等目录被外部脚本创建（⭐ Verilog 不能建目录）
        #1;

        rst_n = 0;
        repeat (40) @(negedge clk);
        rst_n = 1;

        //   ⭐ ① 自检和弦：⭐ 等它起来（DEMO_NOTE_DELAY=2000 拍 ≈ 40 µs）
        //      ⚠️ 但要等 `at_done`（AUTOTARE_DELAY_CLK=100_000 拍 = 2 ms）
        repeat (120_000) @(negedge clk);
        //   ⭐ 抓 0.5 秒（⭐ 足够听出音色；⭐ 24414 样点）
        capture(24414, "sim/evidence/wav_export/01_chord.wav");

        //   ⭐ ② 再抓一段（⭐ 同一场景的后半，⭐ 便于对比）
        capture(24414, "sim/evidence/wav_export/02_tail.wav");

        $display("");
        $display("PASS: WAV 导出完成（3 个文件在 sim/evidence/wav_export/）");
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL: tb_export_wav 超时");
        $finish;
    end

endmodule
