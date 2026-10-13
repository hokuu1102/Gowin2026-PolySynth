`timescale 1ns/1ps
module tb_top_fault_diag;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    wire tx,sclk,mosi,valid;
    wire [5:0] cs,miso;
    wire [7:0] data;
    top #(.FAULT_DIAG_EN(1)) dut(.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(tx),
        .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
        .spi_sclk(sclk),.spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso));
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3]=3'b111;
    uart_rx #(.BAUD_DIV(100)) monitor(.clk_i(clk),.rst_n_i(rst_n),.rx_i(tx),.rx_data_o(data),.rx_done_o(valid));
    integer n=0;
    reg [7:0] bytes[0:59];
    always @(negedge clk) if(rst_n && valid) begin
        bytes[n]=data;
        if(n==59) begin
            if({bytes[0],bytes[1],bytes[2]}!="!F2" || bytes[59]!=10 ||
               {bytes[4],bytes[5],bytes[6]}!="000" ||
               {bytes[8],bytes[9],bytes[10]}!="000" ||
               {bytes[12],bytes[13],bytes[14]}!="000")
                $fatal(1,"FAIL: top diagnostic UART startup packet");
            $display("PASS: real top diagnostic image emits a decoded startup report without forced internal signals");
            $finish;
        end else n=n+1;
    end
    initial begin repeat(12) @(negedge clk);rst_n=1;end
    initial begin #2000000;$fatal(1,"FAIL: top diagnostic UART timeout");end
endmodule
