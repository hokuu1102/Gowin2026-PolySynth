`timescale 1ns/1ps
module tb_fault_report;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [11:0] sources=0;
    reg adc_valid=0;
    reg [2:0] adc_ch=0;
    wire tx,valid;
    wire [7:0] data;
    fault_report #(.PERIOD_CLKS(4000),.BAUD_DIV(10)) dut(
        .clk_i(clk),.rst_n_i(rst_n),.sources_i(sources),.normal_tx_i(1'b1),
        .adc_valid_i(adc_valid),.adc_ch_i(adc_ch),.adc_raw_i(12'habc),.tx_o(tx));
    uart_rx #(.BAUD_DIV(10)) rx(.clk_i(clk),.rst_n_i(rst_n),
        .rx_i(tx),.rx_data_o(data),.rx_done_o(valid));
    reg [7:0] bytes[0:59];
    integer n=0,frames=0;
    always @(negedge clk) if(rst_n && valid) begin
        bytes[n]=data;
        if(n==59) begin
            if(bytes[0]!="!" || bytes[1]!="F" || bytes[2]!="2" || bytes[59]!=10 || bytes[25]!="1")
                $fatal(1,"FAIL: fault diagnostic framing");
            if(frames==1) begin
                if({bytes[4],bytes[5],bytes[6]}!="002" ||
                   {bytes[8],bytes[9],bytes[10]}!="00A" ||
                   {bytes[12],bytes[13],bytes[14]}!="008")
                    $fatal(1,"FAIL: live/sticky/first source distinction");
                if({bytes[16],bytes[17],bytes[18],bytes[19],bytes[20],bytes[21],bytes[22],bytes[23]}!="00000005")
                    $fatal(1,"FAIL: first fault timestamp");
                if({bytes[27],bytes[28],bytes[29]}!="ABC" ||
                   {bytes[55],bytes[56],bytes[57]}!="ABC")
                    $fatal(1,"FAIL: complete ADC2 scan snapshot");
                $display("PASS: decoded UART distinguishes current, sticky and first fault, with timestamp");
                $finish;
            end
            frames=frames+1;n=0;
        end else n=n+1;
    end
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        repeat(5) @(negedge clk);sources=12'h008;
        repeat(3) @(negedge clk);sources=12'h002;
        adc_valid=1;
        repeat(8) begin @(negedge clk);adc_ch=adc_ch+1'b1;end
        adc_valid=0;
    end
    initial begin #1000000;$fatal(1,"FAIL: fault report watchdog");end
endmodule
