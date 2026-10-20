`timescale 1ns/1ps
module tb_guide_review;
reg clk=0; always #10 clk=~clk;
reg rst=0, valid=0; reg [63:0] data=0; reg [4:0] off=3; reg signed [4:0] tr=0; reg fb=0;
wire [15:0] keys;
guide_lamp dut(.clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),.note_off5_i(off),.transpose_i(tr),.fb_mode_i(fb),.key_active_i(16'd0),.stream_alive_i(1'b1),.guide_key_o(keys),.guide_commit_o(),.guide_vis_o());
task reset; begin @(negedge clk); rst=0; valid=0; tr=0; fb=0; repeat(2) @(negedge clk); rst=1; end endtask
task evt; input [1:0] kind; input [3:0] axis; begin @(negedge clk); data=0; data[10:9]=kind; data[22:19]=axis; valid=1; @(negedge clk); valid=0; end endtask
integer i,scenario;
initial begin
if(!$value$plusargs("CASE=%d",scenario)) scenario=1;
reset;
if(scenario==1) begin
 evt(0,0); if(keys!==16'h0020) $fatal(1,"setup ON mapping failed");
 @(negedge clk); tr=2; evt(1,0); repeat(10) @(negedge clk);
 if(keys!==0) $fatal(1,"TRANSPOSE_AFTER_LAST_OFF expected=0000 actual=%h",keys);
end
if(scenario==2) begin
 for(i=0;i<8;i=i+1) evt(0,i);
 for(i=0;i<7;i=i+1) evt(1,i);
 if(keys!==16'h0020) $fatal(1,"EIGHT_OVERLAPS_AFTER_SEVEN_OFF expected=0020 actual=%h",keys);
end
if(scenario==3) begin
 evt(0,0); @(negedge clk); fb=1; evt(1,0); repeat(10) @(negedge clk);
 if(keys!==0) $fatal(1,"MODE_CHANGE_AFTER_LAST_OFF expected=0000 actual=%h",keys);
end
$finish;
end
endmodule
