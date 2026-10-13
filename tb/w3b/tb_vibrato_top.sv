`timescale 1ns/1ps
// T18 integration: enable the optional P4 ADC and prove CH2/CH3 reach W3b.
// An idle-high MISO models the safe pull-up case; it produces full-scale raw
// control values, making the complete route observable without an analogue TB.
module tb_vibrato_top;
    reg clk = 1'b0, rst_n = 1'b0, uart_rx = 1'b1;
    always #10 clk = ~clk;
    wire [5:0] spi_cs_n;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_heartbeat;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;
    wire [4:0] led_oe_n;
    integer errors = 0, cs2_low_count = 0;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .RIGHT_ADC_ENABLE(1), .PA_ON_AFTER_RESET(0), .DEMO_CHORD_ON(1),
        .DEMO_NOTE_DELAY(1_000_000), .DEMO_HOLD_CYC(1_000_000),
        .AUTOTARE_DELAY_CLK(10), .SPAN_WAIT_TIMEOUT_CLK(1000), .HEARTBEAT_DIV(100)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .led_heartbeat(led_heartbeat), .spi_miso(6'b111111), .spi_sclk(),
        .spi_mosi(), .spi_cs_n(spi_cs_n), .led_sdi(), .led_clk(), .led_le(),
        .led_oe_n(led_oe_n), .uart_rx(uart_rx), .uart_tx()
    );
    // Shipping board configuration: P4 is absent, so T17 must retain unity
    // gain all the way into master_mix rather than inheriting a zero control.
    top #(
        .RIGHT_ADC_ENABLE(0), .PA_ON_AFTER_RESET(0), .DEMO_CHORD_ON(1),
        .DEMO_NOTE_DELAY(1_000_000), .DEMO_HOLD_CYC(1_000_000),
        .AUTOTARE_DELAY_CLK(10), .SPAN_WAIT_TIMEOUT_CLK(1000), .HEARTBEAT_DIV(100)
    ) dut_no_right (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(), .HP_WS(), .HP_DIN(), .PA_EN_n(), .I2S2_BCK(), .I2S2_LRCK(), .I2S2_DIN(),
        .led_heartbeat(), .spi_miso(6'b111111), .spi_sclk(), .spi_mosi(), .spi_cs_n(),
        .led_sdi(), .led_clk(), .led_le(), .led_oe_n(), .uart_rx(uart_rx), .uart_tx()
    );
    always @(posedge clk) if (!spi_cs_n[2]) cs2_low_count = cs2_low_count + 1;
    task chk; input [8*96-1:0] name; input cond; begin
        if (cond) $display("  ok  : %0s", name);
        else begin errors=errors+1; $display("  FAIL: %0s", name); end
    end endtask
    initial begin
        repeat (6) @(negedge clk); rst_n = 1'b1;
        // One full 8-channel ADC scan is 0.5 ms at the configured 2 kHz rate.
        repeat (35_000) @(posedge clk);
        chk("optional right ADC is instantiated as ADC #2", dut.g_sound.ADC_N == 3);
        chk("P4 chip-select is actively scanned", cs2_low_count > 10);
        chk("P4 CH1 reaches master mix as Q1.15 unity", dut.g_sound.master_gain == 16'h7fff && dut.g_sound.u_master_mix.gain_i == dut.g_sound.master_gain);
        chk("P4-disabled configuration retains unity master gain", dut_no_right.g_sound.master_gain == 16'h7fff && dut_no_right.g_sound.u_master_mix.gain_i == 16'h7fff);
        chk("CH2 high control enables the LFO through hysteresis", dut.g_sound.vibrato_active);
        chk("LFO output reaches the real oscillator bank", dut.g_sound.u_oscillator_bank.vibrato_mod_i === dut.g_sound.vibrato_mod);
        if (errors == 0) $display("PASS: T18 P4 ADC -> LFO -> oscillator integration");
        else $fatal(1, "FAIL: T18 top integration has %0d error(s)", errors);
        $finish;
    end
    initial begin #2_000_000; $fatal(1, "FAIL: tb_vibrato_top timeout"); end
endmodule
