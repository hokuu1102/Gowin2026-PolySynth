`timescale 1ns/1ps
`default_nettype none

// Physical S2 integration: the asynchronous, active-low button is synchronized,
// debounced, and advances the default timbre exactly once per press.
module tb_top_timbre_button;
    localparam integer DB_CYC = 50_000; // 1 ms at the board's 50 MHz clock

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg timbre_btn_i = 1'b1;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN, led_heartbeat;

    always #10 clk = ~clk;

    top #(
        .PA_ON_DELAY(32),
        .DEMO_CHORD_ON(0),
        .AUTOTARE_DELAY_CLK(100_000),
        .SPAN_WAIT_TIMEOUT_CLK(50_000),
        .SPAN_STABLE_NEED(4),
        .SPAN_VOTE_N(4),
        .METRONOME_ON(0),
        .TIMBRE_BTN_DB_MS(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(timbre_btn_i),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN),
        .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .led_heartbeat(led_heartbeat),
        .spi_sclk(), .spi_mosi(), .spi_miso(6'b111111), .spi_cs_n(),
        .led_sdi(), .led_clk(), .led_le(), .led_oe_n(),
        .uart_rx(1'b1), .uart_tx()
    );

    task automatic press_and_expect;
        input [1:0] expected;
        begin
            // A short bounce must not count as a press.
            timbre_btn_i = 1'b0;
            repeat (3) @(posedge clk);
            timbre_btn_i = 1'b1;
            repeat (3) @(posedge clk);
            if (dut.timbre_sel_r !== (expected - 2'd1))
                $fatal(1, "FAIL: S2 bounce changed timbre");

            // One stable press advances exactly once.
            timbre_btn_i = 1'b0;
            repeat (DB_CYC + 12) @(posedge clk);
            #1;
            if (dut.timbre_sel_r !== expected)
                $fatal(1, "FAIL: S2 expected timbre %0d, got %0d",
                       expected, dut.timbre_sel_r);

            // Holding the key may not auto-repeat.
            repeat (200) @(posedge clk);
            #1;
            if (dut.timbre_sel_r !== expected)
                $fatal(1, "FAIL: held S2 auto-repeated");

            // A debounced release arms the next press.
            timbre_btn_i = 1'b1;
            repeat (DB_CYC + 12) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        if (dut.timbre_sel_r !== 2'd0)
            $fatal(1, "FAIL: reset timbre is not BASS");

        press_and_expect(2'd1); // GUITAR
        press_and_expect(2'd2); // PIANO
        press_and_expect(2'd3); // PAD
        press_and_expect(2'd0); // BASS

        $display("PASS: S2 cycles BASS -> GUITAR -> PIANO -> PAD -> BASS once per press");
        $finish;
    end

    initial begin
        #25_000_000;
        $fatal(1, "FAIL: tb_top_timbre_button timeout");
    end
endmodule

`default_nettype wire
