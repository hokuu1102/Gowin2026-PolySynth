`timescale 1ns/1ps
module tb_adc_false_dead;
parameter integer HEALTHY_CASE=0;
localparam [11:0] CHIP0_BASE=HEALTHY_CASE ? 12'h800 : 12'h000;
reg clk=0,rst_n=0;
always #10 clk=~clk;
wire [2:0] cs,sck,mosi,miso;
wire valid,done;
wire [2:0] ch,fault;
wire [35:0] data;
integer count=0,bad=0,zero_ch0=0;
adc_farm #(.N_ADC(3),.CLK_HZ(50000000),.SCLK_HZ(1000000),.CHANNEL_RATE_HZ(2000)) dut(
 .clk(clk),.rst_n(rst_n),.enable(1'b1),.adc_cs_n(cs),.adc_sclk(sck),
 .adc_mosi(mosi),.adc_miso(miso),.sample_valid(valid),.sample_ch(ch),
 .sample_data_packed(data),.frame_done(done),.fault(fault));
mcp3208_model #(.IDVAL(CHIP0_BASE)) adc0(.cs_n(cs[0]),.sclk(sck[0]),.mosi(mosi[0]),.miso(miso[0]));
mcp3208_model #(.IDVAL(12'h400)) adc1(.cs_n(cs[1]),.sclk(sck[1]),.mosi(mosi[1]),.miso(miso[1]));
mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sck[2]),.mosi(mosi[2]),.miso(miso[2]));
always @(posedge clk) if(rst_n && valid) begin
 count=count+1;
 if(data[11:0] !== (CHIP0_BASE+ch) || data[23:12] !== (12'h400+ch) || data[35:24] !== (12'h800+ch)) bad=bad+1;
 if(ch==0 && data[11:0]==0) zero_ch0=zero_ch0+1;
end
initial begin
 repeat(10) @(negedge clk);rst_n=1;
 if(HEALTHY_CASE) repeat(450000) @(negedge clk);
 else wait(fault[0]);
 @(negedge clk);
 $display("ADC_HEALTHY_PROTOCOL samples=%0d mismatches=%0d chip0_ch0_zero_count=%0d faults=%b time_ns=%0t",count,bad,zero_ch0,fault,$time);
 if(HEALTHY_CASE && bad==0 && fault==0)
  $display("PASS_HEALTHY: non-endpoint CH0 has no fault through real 9 ms of SPI sampling");
 else if(!HEALTHY_CASE && bad==0 && fault==3'b001 && zero_ch0==16)
  $display("REPRO_FALSE_DEAD: all 3 SPI models correctly return every channel, but chip0 legitimate CH0=0 is declared dead");
 else $fatal(1,"unexpected result");
 $finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
