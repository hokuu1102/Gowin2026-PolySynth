`timescale 1ns/1ps
// Independent age/countdown reference checks the deadline implementation
// through repeated modulo wraps, retriggers and clear/expiry collisions.
module tb_led_pulse_wrap;
reg clk=0,rst=0,clear=0,blink=0;reg [1:0] on=0,guide=0,active=0;
always #10 clk=~clk;
wire [9:0] pattern;
led_data #(.KEY_N(2),.STATUS_N(8),.GUIDE_PULSE_CLKS(8)) dut(
 .clk_i(clk),.rst_n_i(rst),.guide_key_i(guide),.key_active_i(active),.status_i(8'ha5),.blink_i(blink),.guide_on_i(on),.guide_clear_i(clear),.pattern_o(pattern),.pattern_commit_o());
integer age0=0,age1=0,i;reg [9:0] expected;reg [31:0] random=32'hcedc1234;
always @(posedge clk)begin
 if(!rst)begin expected=0;age0=0;age1=0;end
 else begin
  expected={8'ha5,active|((guide & {2{blink}})|{age1>0,age0>0})};
  if(clear)begin age0=0;age1=0;end
  else begin
   if(on[0])age0=8;else if(age0>0)age0=age0-1;
   if(on[1])age1=8;else if(age1>0)age1=age1-1;
  end
 end
 #1;if(pattern!==expected)$fatal(1,"FAIL: wrapped deadline mismatch got=%h expected=%h",pattern,expected);
end
initial begin
 repeat(3)@(negedge clk);rst=1;
 for(i=0;i<4096;i=i+1)begin
  @(negedge clk);random={random[30:0],random[31]^random[21]^random[1]^random[0]};
  on=random[1:0];guide=random[3:2];active=random[5:4];blink=random[6];clear=(i%41==0);rst=(i%251!=0);
 end
 @(negedge clk);on=0;guide=0;active=0;blink=0;clear=0;rst=1;
 repeat(12)@(negedge clk);
 if(pattern[1:0]!=0)$fatal(1,"FAIL: pulse stuck after wraps");
 $display("PASS: 4096 deadline wrap/reference cycles, repeated ONs, clear/reset/expiry collisions and independent keys");$finish;
end
endmodule
