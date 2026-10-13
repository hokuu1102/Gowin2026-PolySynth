`timescale 1ns/1ps
// External ADC fixtures and public heartbeat: an ordinary first scan must not
// latch the fault heartbeat merely because only some channels arrived so far.
module tb_top_merge_startup;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire sclk, mosi, hb;
    wire [5:0] cs, miso;
    top #(.SCOPE_MODE(0), .RIGHT_ADC_ENABLE(1), .HEARTBEAT_DIV(100)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .esp_uart_rx_i(1'b1),
        .timbre_btn_i(1'b1), .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .pedal_sus_i(1'b1), .pedal_loop_rec_i(1'b1), .pedal_loop_play_i(1'b1),
        .enc_a_i(1'b1), .enc_b_i(1'b1), .enc_sw_i(1'b1), .ctrl_col_i(4'b0000),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_cs_n(cs), .spi_miso(miso),
        .led_heartbeat(hb)
    );
    mcp3208_model #(.IDVAL(12'h800)) a0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) a1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) a2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3]=3'b111;
    integer cycles=0, last_edge=0, edges=0, fast_edges=0;
    reg expect_fault=0;
    reg hb_prev=0;
    always @(negedge clk) begin
        if (rst_n) begin
            cycles=cycles+1;
            if (hb !== hb_prev) begin
                if (edges>0 && cycles-last_edge != 100 && !expect_fault)
                    $fatal(1,"FAIL: healthy startup heartbeat switched to fault cadence interval=%0d",cycles-last_edge);
                if (expect_fault && cycles-last_edge == 12) fast_edges=fast_edges+1;
                edges=edges+1;
                last_edge=cycles;
            end
        end
        hb_prev=hb;
    end
    initial begin
        repeat(12) @(negedge clk);
        rst_n=1;
        repeat(40000) @(posedge clk);
        if(edges<300) $fatal(1,"FAIL: heartbeat coverage vacuous");
        // Deliberate diagnostic-boundary injection, not a physical ADC fault:
        // demonstrate that the new frame gate does not remove missing-axis alarm.
        @(negedge clk); expect_fault=1;
        force dut.g_sound.as_seen=16'hfffe;
        repeat(30000) @(posedge clk);
        if(fast_edges<10) $fatal(1,"FAIL: missing-axis alarm removed or never became visible");
        release dut.g_sound.as_seen;
        $display("PASS: healthy ADC startup normal; injected missing-axis mask still gives fault heartbeat");
        $finish;
    end
    initial begin #2000000; $fatal(1,"FAIL: startup timeout"); end
endmodule
