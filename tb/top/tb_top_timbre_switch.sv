`timescale 1ns/1ps
`default_nettype none

// Top-level demonstration invariant: a new timbre may not start while any
// envelope from the previous demonstration chord is still active.
module tb_top_timbre_switch;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN, led_heartbeat;

    always #10 clk = ~clk;

    top #(
        .PA_ON_DELAY(32),
        .DEMO_NOTE_DELAY(20),
        .DEMO_HOLD_CYC(5_000),
        .AUTOTARE_DELAY_CLK(100_000),
        .SPAN_WAIT_TIMEOUT_CLK(50_000),
        .SPAN_STABLE_NEED(4),
        .SPAN_VOTE_N(4),
        .METRONOME_ON(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN),
        .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .led_heartbeat(led_heartbeat),
        .spi_sclk(), .spi_mosi(), .spi_miso(6'b111111), .spi_cs_n(),
        .led_sdi(), .led_clk(), .led_le(), .led_oe_n(),
        .uart_rx(1'b1), .uart_tx()
    );

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.g_sound.demo_step == 3'd7);
        #1;
        if (!(|dut.g_sound.env_active))
            $fatal(1, "FAIL: test did not reach switch point with an active release tail");
        if (dut.g_sound.demo_timbre !== 2'd0)
            $fatal(1, "FAIL: first timbre changed before switch invariant was sampled");

        // With a release tail still active, the controller must hold timbre 0.
        @(posedge clk); #1;
        if (dut.g_sound.demo_timbre !== 2'd0)
            $fatal(1, "FAIL: demo switched timbre while previous envelope was active");

        // Once the existing envelope-bank seam reports silence, switching is
        // permitted immediately; no new timer or audio path is required.
        force dut.g_sound.env_active = {32{1'b0}};
        @(posedge clk); #1;
        if (dut.g_sound.demo_timbre !== 2'd1)
            $fatal(1, "FAIL: demo did not advance after all envelopes became inactive");
        release dut.g_sound.env_active;

        $display("PASS: demo timbre switch waits for release tails to finish");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_top_timbre_switch timeout");
    end
endmodule

`default_nettype wire
