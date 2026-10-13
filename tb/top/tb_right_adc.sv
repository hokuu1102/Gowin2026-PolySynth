// ═══════════════════════════════════════════════════════════════════════════
// tb_right_adc.sv — ⭐ **右手板档（`RIGHT_ADC_ENABLE=1`）的功能判据**（2026-10-08）
//
//   🔴 **为什么要有它**：⭐ 现有 tb 例化 `top` 时**全部用默认参数**（`RIGHT_ADC_ENABLE=0`）
//      ⇒ ⭐ **第 3 片 ADC 的整条通路（扫描 / 通道映射 / 标定）在仿真里【从未验过】** ✅
//      ⚠️ 而 `=1` 档在 2026-10-08 之前**连时序都不过** ⇒ ⭐ 它一直只有"布不通"这一个事实
//      ⇒ ⭐ 本 tb 补上"**它至少是活的**"这一层判据 ✅
//
//   ⭐ **判据（双实例差分 —— ⭐ 自带反向对照，⛔ 不是空判据）**：
//      · `u_on`（`RIGHT_ADC_ENABLE=1`）：⭐ **片 2 的 `spi_cs_n[2]` 必须翻**（被扫描）✅
//      · `u_off`（`RIGHT_ADC_ENABLE=0`）：⭐ **片 2 的 `spi_cs_n[2]` 必须【不翻】**（不扫描）✅
//      · 两个实例的**片 0 都必须翻**（左手板照常）✅
//      · `spi_sclk` 在跑 · 复位后 `led_heartbeat` 会翻（板子活着）✅
//   📌 **为什么用"CS 翻不翻"当判据**：⭐ 它是**编译期参数**直接决定的**可观测后果**
//      （`ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2`）⇒ ⭐ 一眼就能红/绿 ✅
//   📌 **为什么不需要"按键→出声"**：⭐ 那是 `tb_e2e_key_to_sound` 的活（它用 2 片夹具）；
//      本 tb 只回答"**第 3 片的通路通不通**"这一个问题 ✅
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_right_adc;

    localparam integer RAW_REST = 12'h7C1;     // ⭐ 静息（松手 1.60 V）
    localparam integer RAW_DOWN = 12'h4D9;     // ⭐ 按下（触底 1.00 V）
    localparam integer WINDOW   = 120_000;     // ⭐ 120k 拍 = 2.4 ms（ADC 帧 500 µs ⇒ ~4 帧）

    reg clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    reg rst_n = 1'b0;

    // ── 实例 ON（RIGHT_ADC_ENABLE = 1）────────────────────────────────────
    wire [5:0] cs_on;
    wire       sclk_on, mosi_on;
    wire       m0_on, m1_on, m2_on;
    wire [5:0] miso_on = {3'b111, m2_on, m1_on, m0_on};
    wire       hb_on;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .RIGHT_ADC_ENABLE  (1),
        .DEMO_CHORD_ON     (1),
        .PA_ON_AFTER_RESET (0),
        .HEARTBEAT_DIV     (100)
    ) u_on (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(), .HP_WS(), .HP_DIN(), .PA_EN_n(), .led_heartbeat(hb_on),
        .I2S2_BCK(), .I2S2_LRCK(), .I2S2_DIN(),
        .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .spi_miso(miso_on), .spi_sclk(sclk_on), .spi_mosi(mosi_on), .spi_cs_n(cs_on),
        .uart_rx(1'b1), .uart_tx(),
        .ctrl_row_o(), .ctrl_col_i(4'b0000),
        .enc_a_i(1'b1), .enc_b_i(1'b1), .enc_sw_i(1'b1),
        .ctrl_ws_o(),
        .pedal_sus_i(1'b1), .pedal_loop_rec_i(1'b1), .pedal_loop_play_i(1'b1),
        .esp_uart_tx_o(), .esp_uart_rx_i(1'b1),
        .ws_strip_o()
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_on0 (
        .cs_n(cs_on[0]), .sclk(sclk_on), .mosi(mosi_on), .miso(m0_on),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_on1 (
        .cs_n(cs_on[1]), .sclk(sclk_on), .mosi(mosi_on), .miso(m1_on),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));
    //  ⭐ 片 2 = 右手板 A（⭐ 只在 `RIGHT_ADC_ENABLE=1` 时才被选中）
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_on2 (
        .cs_n(cs_on[2]), .sclk(sclk_on), .mosi(mosi_on), .miso(m2_on),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));

    // ── 实例 OFF（RIGHT_ADC_ENABLE = 0）—— ⭐ 反向对照 ────────────────────
    wire [5:0] cs_off;
    wire       sclk_off, mosi_off;
    wire       m0_off, m1_off, m2_off;
    wire [5:0] miso_off = {3'b111, m2_off, m1_off, m0_off};
    wire       hb_off;

    top #(
        .RIGHT_ADC_ENABLE  (0),
        .DEMO_CHORD_ON     (1),
        .PA_ON_AFTER_RESET (0),
        .HEARTBEAT_DIV     (100)
    ) u_off (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(), .HP_WS(), .HP_DIN(), .PA_EN_n(), .led_heartbeat(hb_off),
        .I2S2_BCK(), .I2S2_LRCK(), .I2S2_DIN(),
        .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .spi_miso(miso_off), .spi_sclk(sclk_off), .spi_mosi(mosi_off), .spi_cs_n(cs_off),
        .uart_rx(1'b1), .uart_tx(),
        .ctrl_row_o(), .ctrl_col_i(4'b0000),
        .enc_a_i(1'b1), .enc_b_i(1'b1), .enc_sw_i(1'b1),
        .ctrl_ws_o(),
        .pedal_sus_i(1'b1), .pedal_loop_rec_i(1'b1), .pedal_loop_play_i(1'b1),
        .esp_uart_tx_o(), .esp_uart_rx_i(1'b1),
        .ws_strip_o()
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_off0 (
        .cs_n(cs_off[0]), .sclk(sclk_off), .mosi(mosi_off), .miso(m0_off),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_off1 (
        .cs_n(cs_off[1]), .sclk(sclk_off), .mosi(mosi_off), .miso(m1_off),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_off2 (
        .cs_n(cs_off[2]), .sclk(sclk_off), .mosi(mosi_off), .miso(m2_off),
        //  ⭐⭐ 2026-10-11（⭐ `P1-20` 附带）：⭐ **喂 12 位切片** ——
        //     ⚠️ `RAW_DOWN` 是 `localparam integer`（⭐ 32 位 ✅）而端口是 **12 位** ✅
        //     ⇒ 🔴 原来每次编译都报 `Pruning (signed) 20 high bits`（⭐ 实测 6 条 ✅）
        //     📌 ⭐ `RAW_DOWN = 12'h4D9` ⇒ ⭐ **低 12 位就是它的全部值** ⇒ 取切片**值不变** ✅
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN[11:0]), .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN[11:0]));

    // ── 计数：CS 下降沿 / SCLK 边沿 / 心跳 ───────────────────────────────
    integer cs2_on = 0, cs0_on = 0, cs2_off = 0, cs0_off = 0;
    integer sclk_on_e = 0, hb_on_e = 0;
    always @(negedge cs_on[2])  cs2_on  = cs2_on  + 1;
    always @(negedge cs_on[0])  cs0_on  = cs0_on  + 1;
    always @(negedge cs_off[2]) cs2_off = cs2_off + 1;
    always @(negedge cs_off[0]) cs0_off = cs0_off + 1;
    always @(posedge sclk_on)   sclk_on_e = sclk_on_e + 1;
    always @(posedge hb_on)     hb_on_e = hb_on_e + 1;

    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input        cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    integer k;
    initial begin
        $display("=== tb_right_adc (RIGHT_ADC_ENABLE 双实例差分) ===");
        repeat (20) @(negedge clk);
        rst_n = 1'b1;
        for (k = 0; k < WINDOW; k = k + 1) @(negedge clk);

        $display("      [dbg] ON : cs0=%0d cs2=%0d sclk=%0d hb=%0d", cs0_on, cs2_on, sclk_on_e, hb_on_e);
        $display("      [dbg] OFF: cs0=%0d cs2=%0d", cs0_off, cs2_off);

        //  R1 ⭐ 正向：=1 档必须扫描片 2
        chk(cs2_on >= 3, "R1 RIGHT_ADC_ENABLE=1 => chip2 IS scanned (cs_n[2] toggles)");
        //  R2 ⭐ 反向对照：=0 档必须【不】扫描片 2
        chk(cs2_off == 0, "R2 RIGHT_ADC_ENABLE=0 => chip2 NOT scanned (cs_n[2] stays high)");
        //  R3 两档的片 0 都照常扫描（左手板不受影响）
        chk(cs0_on  >= 3, "R3a =1 config: chip0 still scanned");
        chk(cs0_off >= 3, "R3b =0 config: chip0 still scanned");
        //  R4 SPI 时钟在跑
        chk(sclk_on_e >= 100, "R4 SPI sclk is running");
        //  R5 心跳在翻（板子活着）
        chk(hb_on_e >= 1, "R5 heartbeat toggles (design alive)");
        //  R6 两档的片 3~5（未用）恒高（⛔ 不能误选到不存在的片）
        chk((cs_on[5:3] === 3'b111) && (cs_off[5:3] === 3'b111),
            "R6 unused chip selects (cs_n[5:3]) stay HIGH");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_right_adc — %0d/%0d judgements held (=1 档功能通路是活的)", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_right_adc — %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_right_adc TIMEOUT");
        $finish;
    end

endmodule
