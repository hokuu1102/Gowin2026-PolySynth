`timescale 1ns/1ps
// Real UART -> command parser -> display input boundary. Check that Q never
// removes audio sample commits from the HDMI module's public input port.
module tb_top_scope_live;
    reg clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire sclk,mosi;
    wire [5:0] cs,miso;
    integer commits=0,errors=0;
    top dut(.clk(clk),.rst_n(rst_n),.uart_rx(rx),
        .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
        .spi_sclk(sclk),.spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso));
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3]=3'b111;
    always @(posedge clk) if(rst_n && dut.u_hdmi.valid_i) commits=commits+1;
    task send_q;
        integer bit_index;
        reg [7:0] cmd;
        begin
            cmd=8'h51;
            @(negedge clk);rx=0;repeat(100) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                rx=cmd[bit_index];repeat(100) @(negedge clk);
            end
            rx=1;repeat(150) @(negedge clk);
        end
    endtask
    task check_stream;
        begin
            commits=0;repeat(8192) @(negedge clk);
            if(commits<7 || commits>9) begin
                $display("FAIL: live HDMI input must receive one commit/frame after Q, got=%0d",commits);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        repeat(2048) @(negedge clk);check_stream;
        send_q;
        if(dut.u_hdmi.SCOPE_MODE!==1'b0) begin
            $display("FAIL: first real UART Q did not select waveform at HDMI input");
            errors=errors+1;
        end
        check_stream;
        send_q;
        if(dut.u_hdmi.SCOPE_MODE!==1'b1) begin
            $display("FAIL: second real UART Q did not select XY at HDMI input");
            errors=errors+1;
        end
        check_stream;
        if(errors) $fatal(1,"FAIL: Q interrupted live audio display input");
        $display("PASS: real UART Q preserves the HDMI audio sample stream in both modes");
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: top scope stream timeout");end
endmodule
