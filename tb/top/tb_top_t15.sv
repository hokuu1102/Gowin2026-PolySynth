`timescale 1ns/1ps
// T15 integration: exercise the real top-level mode/edge/pitch-event wiring.
`default_nettype none

module tb_top_t15;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg pluck_up = 1'b0;
    reg pluck_down = 1'b0;
    reg uart_rx = 1'b1;
    reg [5:0] spi_miso = 6'b111111;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN, led_heartbeat;
    wire spi_sclk, spi_mosi, uart_tx;
    wire [5:0] spi_cs_n;
    wire led_sdi, led_clk, led_le;
    wire [4:0] led_oe_n;

    always #10 clk = ~clk;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .DEMO_NOTE_DELAY(1_000_000), // keep the demonstration source inactive
        .DEMO_HOLD_CYC(1_000_000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .pluck_up_i(pluck_up), .pluck_down_i(pluck_down),
        .led_heartbeat(led_heartbeat),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .led_sdi(led_sdi), .led_clk(led_clk), .led_le(led_le), .led_oe_n(led_oe_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    task inject_axis;
        input [3:0] axis;
        input [1:0] kind;
        input [11:0] depth;
        begin
            force dut.g_sound.ee_valid = 1'b1;
            force dut.g_sound.ee_axis = axis;
            force dut.g_sound.ee_kind = kind;
            force dut.g_sound.ee_depth = depth;
            @(posedge clk); #1;
            release dut.g_sound.ee_valid;
            release dut.g_sound.ee_axis;
            release dut.g_sound.ee_kind;
            release dut.g_sound.ee_depth;
        end
    endtask

    task expect_event;
        input [3:0] axis;
        input [1:0] kind;
        begin
            // mode controller register + axis-map input + aligned output
            repeat (2) @(posedge clk);
            #1;
            if (!dut.g_sound.w3a_evt_valid || dut.g_sound.w3a_evt_axis != axis ||
                dut.g_sound.w3a_evt_kind != kind) begin
                $display("FAIL: expected event axis=%0d kind=%0d, got valid=%b axis=%0d kind=%0d",
                         axis, kind, dut.g_sound.w3a_evt_valid,
                         dut.g_sound.w3a_evt_axis, dut.g_sound.w3a_evt_kind);
                $fatal(1);
            end
        end
    endtask

    integer k;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // uart_ui encoding is 1=keyboard.  Axis events must directly play/release.
        force dut.ui_mode_piano = 1'b1;
        inject_axis(4'd2, 2'd0, 12'd500);
        expect_event(4'd2, 2'd0);
        inject_axis(4'd2, 2'd1, 12'd0);
        expect_event(4'd2, 2'd1);
        $display("  ok  : top keyboard mode forwards axis ON/OFF");

        // uart_ui encoding 0=default fretboard.  Selection alone is silent.
        force dut.ui_mode_piano = 1'b0;
        inject_axis(4'd6, 2'd0, 12'd700);
        repeat (3) @(posedge clk);
        if (dut.g_sound.w3a_evt_valid) begin
            $display("FAIL: fretboard selection emitted a musical event");
            $fatal(1);
        end
        $display("  ok  : top fretboard selection is silent");

        // A real top-level comparator edge needs the synchronizer plus pipeline.
        pluck_down = 1'b1;
        for (k = 0; k < 12; k = k + 1) begin
            @(posedge clk); #1;
            if (dut.g_sound.w3a_evt_valid) begin
                if (dut.g_sound.w3a_evt_axis != 4'd6 || dut.g_sound.w3a_evt_kind != 2'd2) begin
                    $display("FAIL: DOWN pluck event carries wrong axis/kind");
                    $fatal(1);
                end
                $display("  ok  : top DOWN comparator edge plucks selected axis");
                pluck_down = 1'b0;
                release dut.ui_mode_piano;
                $display("PASS: T15 top-level keyboard/fretboard integration");
                $finish;
            end
        end
        $display("FAIL: top did not emit a pluck after DOWN comparator edge");
        $fatal(1);
    end
endmodule

`default_nettype wire
