`timescale 1ns/1ps
// ============================================================================
//  tb_top_led_strip.sv -- ⭐ **顶层灯带集成验收**：把 `ctrl_ws_o` 的位流解回 7 路颜色
//
//  🔴 为什么必须有它（⭐ 2026-10-04 发现的**口径缺口**）：
//     · `tb_led_indicator`  只测**指示层模块本身**（第 2 层）
//     · `tb_ws2812_driver`  只测**PHY 位时序**（第 3 层）
//     ⇒ ⛔ **没有任何 tb 观察 `ctrl_ws_o`** ⇒ `top.v` 里
//       "7 路颜色 → 写口 `case` → 驱动" 这段接线**当时没有判据**：
//       ⚠️ 切片顺序写错、灯序颠倒、`WS_LED_N` 差一 ⇒ **119 个 tb 全都会绿**。
//     ⇒ ⭐ 本 tb **只看引脚上的波形**（⛔ 不引用任何 DUT 内部信号），
//       把线上 384 个 bit cell 解回 GRB → 24 位颜色，再**逐颗**比对 ✅
//
//  ⭐ 判据（每条都能红）
//    (1) 上电帧：LED0..LED6 == 期望表；⭐ **LED7..LED15 必须全灭**
//    (2) ⭐ **活体**：往 `uart_rx` 发裸 `'I'`（切音色）⇒ ⭐ **下一帧 LED0 变色**，
//        ⭐ 且**只有 LED0 变**（⛔ 不是常量、⛔ 不是串线）
//    (3) ⭐ **跨 generate 分支**：`DEMO_CHORD_ON=0`（`g_silent`）实例 ⇒ ⭐ **LED5 必须灭**
//        （⭐ 那一档 `led_gear_st` 由**另一个** generate 分支显式驱动 = 0）
//    (4) 线上位时序：整帧 = 384 × 62 拍（⭐ 位周期契约）＋ 帧间长低（≥ 10000 拍）
//    (5) `ws_strip_o` 恒 `3'b000`（⭐ 拓展板 3 路**预留**，⛔ 本次没做设计）
//        ＋ `esp_uart_tx_o` 恒高（⭐ UART 空闲态）
//    (6) A8：`ctrl_ws_o` 复位后无 X/Z
//
//  ⭐ 上电期望表（⭐ 全部来自**复位值**，⛔ 不依赖任何激励）
//    LED0 音色      = 白  `FFFFFF`（`timbre_sel_r` 复位 = 0）
//    LED1 节拍器    = 灭  `000000`（`met_on_r` 复位 = 0）
//    LED2 鼓机      = 灭  `000000`（`met_on_r` = 0）
//    LED3 键盘打鼓  = 灭  `000000`（`key_drum_r` 复位 = 0）
//    LED4 looper    = 暗蓝 `000030`（`loop_*_on_r` 复位 = 0）
//    LED5 推子功能  = 青  `00FFFF`（`fader_gear` 复位 = **档 1 = 颤音**）★ g_sound 档
//    LED6 指板/键盘 = 绿  `00FF00`（`uart_ui` 上电 = 钢琴 ⇒ `play_fretboard_mode` = 0）
//
//  ⭐⭐ 为什么这就是"集成判据"：⭐ 上面这张表**同时钉住**了三件事 ——
//     ① ⭐ 写口 `case` 的**切片顺序**（哪一段 24 位对应哪颗灯）
//     ② ⭐ 指示层的**灯序**（音色在第 0 颗、looper 在第 4 颗 …）
//     ③ ⭐ 第 3 层驱动的**接入**（真位流、GRB、800 kHz、帧间复位）
//     ⚠️ 任何一处接错 ⇒ ⭐ 解出来的颜色**立刻不对** ⇒ ✅ 能红
// ============================================================================
`default_nettype none

module tb_top_led_strip;

    localparam integer LED_N   = 16;          // ⭐ `top.v` 的 `WS_LED_N`
    localparam integer NBITS   = LED_N * 24;  // 384
    localparam integer BIT_CYC = 62;          // ⭐ 位周期（PHY 契约）
    localparam integer SMP_AT  = 26;          // ⭐ 采样点：`17 < 26 < 35` ⇒ 落在"0/1 码高电平"之间
    localparam integer LOW_WAIT= 10000;       // ⭐ 帧间"长低"判据（≥ 10000 拍；驱动给 20000）

    // ── 期望颜色（⭐ 字面量；⛔ 不引用 RTL 的 localparam，否则改 RTL 会连带改判据）──
    localparam [23:0] X_OFF     = 24'h000000;
    localparam [23:0] X_WHITE   = 24'hFFFFFF;
    localparam [23:0] X_CYAN    = 24'h00FFFF;
    localparam [23:0] X_GREEN   = 24'h00FF00;
    localparam [23:0] X_DIMBLUE = 24'h000030;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz

    // ── 串口注入（⭐ 500 kbaud ⇒ BAUD_DIV = 100，与 `top.v` 的 `u_uart_rx` 同档）──
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    wire       uart_line;

    uart_tx #(.BAUD_DIV(100)) u_pc (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .tx_start_i(tx_start),
        .tx_data_i (tx_data),
        .tx_o      (uart_line),
        .busy_o    (tx_busy),
        .tx_done_o ()
    );

    // ── 被测顶层 ×2（⭐ 两个 generate 分支各一份）───────────────────────────
    wire ws_snd, ws_sil;
    wire [2:0] strip_snd, strip_sil;
    wire esp_tx_snd, esp_tx_sil;

    // ⭐ 11 个预留输入 + 3 个踏板：⭐ 全部按 `.cst` 的**上拉空闲态**显式给值
    //   （⛔ 不留悬空：`z` 会经 `reserved_in_xor` 传成 `x` ⇒ ⚠️ 污染 A8 判据）
    top #(
        .DEMO_CHORD_ON (1),                   // ⭐ 出声档（`g_sound`）
        .HEARTBEAT_DIV (512),                 // ⭐ 心跳加快，便于观测（本 tb 不查心跳）
        .SAMPLE_W      (24),
        .DATA_BITS     (16)
    ) u_top_snd (
        .clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),   // ⭐ 按键**低有效** ⇒ 1 = 没按
        .HP_BCK (), .HP_WS (), .HP_DIN (), .PA_EN_n (), .led_heartbeat (),
        .I2S2_BCK (), .I2S2_LRCK (), .I2S2_DIN (),
        .pluck_up_i (1'b0), .pluck_down_i (1'b0),
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        .uart_rx (uart_line), .uart_tx (),
        .ctrl_row_o (), .ctrl_col_i (4'b0000),
        .enc_a_i (1'b1), .enc_b_i (1'b1), .enc_sw_i (1'b1),
        .ctrl_ws_o (ws_snd),
        .pedal_sus_i (1'b1), .pedal_loop_rec_i (1'b1), .pedal_loop_play_i (1'b1),
        .esp_uart_tx_o (esp_tx_snd), .esp_uart_rx_i (1'b1),
        .ws_strip_o (strip_snd)
    );

    top #(
        .DEMO_CHORD_ON (0),                   // ⭐ 静音档（`g_silent`）⇒ 三根跨分支状态线由该分支驱动
        .HEARTBEAT_DIV (512)
    ) u_top_sil (
        .clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),
        .HP_BCK (), .HP_WS (), .HP_DIN (), .PA_EN_n (), .led_heartbeat (),
        .I2S2_BCK (), .I2S2_LRCK (), .I2S2_DIN (),
        .pluck_up_i (1'b0), .pluck_down_i (1'b0),
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        .uart_rx (1'b1), .uart_tx (),          // ⭐ 静音档：串口空闲高（⛔ 不喂命令）
        .ctrl_row_o (), .ctrl_col_i (4'b0000),
        .enc_a_i (1'b1), .enc_b_i (1'b1), .enc_sw_i (1'b1),
        .ctrl_ws_o (ws_sil),
        .pedal_sus_i (1'b1), .pedal_loop_rec_i (1'b1), .pedal_loop_play_i (1'b1),
        .esp_uart_tx_o (esp_tx_sil), .esp_uart_rx_i (1'b1),
        .ws_strip_o (strip_sil)
    );

    // ── A8：复位释放后引脚上不许有 X/Z ──────────────────────────────────────
    reg [31:0] a8_err;
    chk_xprop #(.W(2), .NAME("ctrl_ws_o(snd/sil)")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig({ws_snd, ws_sil}), .err_cnt(a8_err)
    );

    // ── 解码缓冲（⭐ `[0:NBITS-1]` 升序 ⇒ `bits[k]` 就是线上第 k 个 bit）─────
    reg [0:NBITS-1] bits_snd;
    reg [0:NBITS-1] bits_sil;

    integer errors = 0;
    integer n;
    reg [23:0] got_rgb;
    reg ok_all;
    time t_frame0, t_frame1;

    task chk(input [8*256-1:0] name, input cond);
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ⭐ 解一帧：⭐ 先等"长时间低"（= 帧间复位）⇒ 之后第一个上升沿就是**帧起点**
    //   📌 采样点取 `SMP_AT=26` 拍 ⇒ `'0'`（高 17）读成 0、`'1'`（高 35）读成 1 ✅
    task decode_frame(input integer which);       // 0 = snd · 1 = sil
        integer k, low;
        begin
            low = 0;
            while (low < LOW_WAIT) begin
                @(posedge clk);
                if ((which ? ws_sil : ws_snd) === 1'b1) low = 0; else low = low + 1;
            end
            if (which) @(posedge ws_sil); else @(posedge ws_snd);   // ⭐ 帧起点
            t_frame0 = $time;
            for (k = 0; k < NBITS; k = k + 1) begin
                repeat (SMP_AT) @(posedge clk);
                if (which) bits_sil[k] = ws_sil; else bits_snd[k] = ws_snd;
                repeat (BIT_CYC - SMP_AT) @(posedge clk);
            end
            t_frame1 = $time;
        end
    endtask

    // ⭐ 线上是 **GRB**（MSB 先出）⇒ 组回 24 位 RGB888
    function [23:0] rgb_of;
        input integer which;
        input integer led;
        integer b;
        reg [7:0] g, r, bl;
        begin
            g = 8'd0; r = 8'd0; bl = 8'd0;
            for (b = 0; b < 8; b = b + 1) begin
                if (which) begin
                    g  = {g[6:0],  bits_sil[led*24 + b]};
                    r  = {r[6:0],  bits_sil[led*24 + 8 + b]};
                    bl = {bl[6:0], bits_sil[led*24 + 16 + b]};
                end else begin
                    g  = {g[6:0],  bits_snd[led*24 + b]};
                    r  = {r[6:0],  bits_snd[led*24 + 8 + b]};
                    bl = {bl[6:0], bits_snd[led*24 + 16 + b]};
                end
            end
            rgb_of = {r, g, bl};
        end
    endfunction

    task exp_led(input [8*256-1:0] name, input integer which, input integer led,
                  input [23:0] want);
        begin
            got_rgb = rgb_of(which, led);
            if (got_rgb === want)
                $display("  ok  : %0s [led%0d] = %06h", name, led, got_rgb);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s [led%0d] = %06h want %06h", name, led, got_rgb, want);
            end
        end
    endtask

    // ⭐ LED7..LED15 必须全灭（⭐ 钉住 `case` 的 `default`）
    task chk_tail_dark(input [8*256-1:0] name, input integer which);
        begin
            ok_all = 1'b1;
            for (n = 7; n < LED_N; n = n + 1)
                if (rgb_of(which, n) !== X_OFF) begin
                    ok_all = 1'b0;
                    $display("       ⚠️ led%0d = %06h（应为 000000）", n, rgb_of(which, n));
                end
            if (ok_all) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task send_byte(input [7:0] b);
        begin
            @(negedge clk);
            tx_data  = b;
            tx_start = 1'b1;
            @(negedge clk);
            tx_start = 1'b0;
            wait (tx_busy === 1'b1);          // ⭐ 10 位 × 100 拍
            wait (tx_busy === 1'b0);
            repeat (3000) @(posedge clk);     // ⭐ 等 `calib_cmd` 消化并置 `timbre_sel_r`
        end
    endtask

    initial begin
        tx_data = 8'h00; tx_start = 1'b0;

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);

        // ════════════════════════════════════════════════════════════════════
        // (1) 出声档（`g_sound`）上电帧
        // ════════════════════════════════════════════════════════════════════
        $display("=== (1) 上电帧 · g_sound（LED0..LED6 + 尾灯全灭）===");
        decode_frame(0);
        $display("  info: 帧长 = %0d 拍（期望 %0d = %0d × %0d）",
                 (t_frame1 - t_frame0) / 20, NBITS*BIT_CYC, NBITS, BIT_CYC);
        chk("(4) 整帧时长 == NBITS × BIT_CYC（⭐ 位周期契约）",
            ((t_frame1 - t_frame0) / 20) == (NBITS*BIT_CYC));

        exp_led("(1a) led0 音色 = 白",       0, 0, X_WHITE);
        exp_led("(1b) led1 节拍器 = 灭",     0, 1, X_OFF);
        exp_led("(1c) led2 鼓机 = 灭",       0, 2, X_OFF);
        exp_led("(1d) led3 键盘打鼓 = 灭",   0, 3, X_OFF);
        exp_led("(1e) led4 looper = 暗蓝",   0, 4, X_DIMBLUE);
        exp_led("(1f) led5 推子(档1 颤音) = 青", 0, 5, X_CYAN);
        exp_led("(1g) led6 键盘模式 = 绿",   0, 6, X_GREEN);
        chk_tail_dark("(1h) led7..led15 全灭（⭐ 写口 default）", 0);

        // ════════════════════════════════════════════════════════════════════
        // (3) 静音档（`g_silent`）⇒ ⭐ LED5 必须灭（另一分支显式驱动 `led_gear_st=0`）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (3) 静音档（g_silent）· 跨 generate 分支 ===");
        decode_frame(1);
        exp_led("(3a) led0 音色 = 白（模块层信号，两档相同）", 1, 0, X_WHITE);
        exp_led("(3b) led4 looper = 暗蓝",                     1, 4, X_DIMBLUE);
        exp_led("(3c) led6 键盘模式 = 绿",                     1, 6, X_GREEN);
        exp_led("(3d) ⭐ led5 推子 = 灭（g_silent 把 led_gear_st 驱动成 0）", 1, 5, X_OFF);
        chk_tail_dark("(3e) led7..led15 全灭", 1);

        // ════════════════════════════════════════════════════════════════════
        // (2) ⭐ 活体：发裸 `'I'`（切音色 0→1）⇒ 下一帧 LED0 必须变青、其余不动
        // ════════════════════════════════════════════════════════════════════
        $display("=== (2) 活体：UART 裸 'I' 切音色 ===");
        send_byte(8'h49);                       // ⭐ 'I'
        decode_frame(0);
        exp_led("(2a) ⭐ led0 音色 0→1 = 青（真的在动）", 0, 0, X_CYAN);
        exp_led("(2b) led1 节拍器 = 灭（⛔ 没被串动）",   0, 1, X_OFF);
        exp_led("(2c) led2 鼓机 = 灭",                   0, 2, X_OFF);
        exp_led("(2d) led3 键盘打鼓 = 灭",               0, 3, X_OFF);
        exp_led("(2e) led4 looper = 暗蓝",               0, 4, X_DIMBLUE);
        exp_led("(2f) led5 推子 = 青（⛔ 没被串动）",     0, 5, X_CYAN);
        exp_led("(2g) led6 键盘模式 = 绿",               0, 6, X_GREEN);
        chk_tail_dark("(2h) led7..led15 全灭", 0);

        // ════════════════════════════════════════════════════════════════════
        // (5) 预留脚：⛔ 本次没做设计 ⇒ 必须仍是常量
        // ════════════════════════════════════════════════════════════════════
        $display("=== (5) 预留脚 / UART 空闲态 ===");
        chk("(5a) ws_strip_o == 3'b000（拓展板 3 路预留，⭐ 本次未做设计）",
            (strip_snd === 3'b000) && (strip_sil === 3'b000));
        chk("(5b) esp_uart_tx_o 恒高（⭐ UART 空闲态）",
            (esp_tx_snd === 1'b1) && (esp_tx_sil === 1'b1));
        chk("(6) ctrl_ws_o 复位后无 X/Z（A8）", a8_err == 32'd0);

        if (errors == 0)
            $display("PASS: top 灯带集成 —— ctrl_ws_o 位流解出的 7 路颜色/灯序/切片/两档分支全部正确");
        else
            $fatal(1, "FAIL: tb_top_led_strip has %0d error(s)", errors);
        $finish;
    end

    // 看门狗：⭐ 本 tb 约 13.4 万拍（≈ 2.7 ms 仿真）⇒ 给 4 ms 上限
    initial begin
        #4_000_000;
        $fatal(1, "FAIL: tb_top_led_strip timeout");
    end

endmodule

`default_nettype wire
