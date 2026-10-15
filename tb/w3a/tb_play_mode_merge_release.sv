`timescale 1ns/1ps
module tb_play_mode_merge_release;
 reg clk=0,rst=0,valid=0,pluck=0;
 reg [3:0] axis=0;
 reg [1:0] kind=0;
 wire ov;
 wire [3:0] oa;
 wire [1:0] ok;
 wire [11:0] od;
 integer count=0;
 reg [3:0] seen [0:7];
 always #10 clk=~clk;
 play_mode_ctrl dut(.clk_i(clk),.rst_n_i(rst),.fretboard_mode_i(1'b1),
  .axis_valid_i(valid),.axis_i(axis),.axis_kind_i(kind),.axis_depth_i(12'd600),
  .pluck_valid_i(pluck),.pluck_up_i(1'b1),
  .evt_valid_o(ov),.evt_axis_o(oa),.evt_kind_o(ok),.evt_depth_o(od));
 always @(negedge clk) if(ov && ok==1) begin seen[count]=oa;count=count+1;end
 task ev(input [3:0] a,input [1:0] k);
 begin @(negedge clk);axis=a;kind=k;valid=1;
 @(negedge clk);valid=0;repeat(2) @(negedge clk);end endtask
 task pick;
 begin @(negedge clk);pluck=1;@(negedge clk);pluck=0;
 repeat(2) @(negedge clk);end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 ev(2,0);ev(9,0);pick;pick;
 ev(9,1);
 if(count!=1 || seen[0]!=9) $fatal(1,"FAIL: releasing axis9 must not release axis2");
 ev(2,1);
 if(count!=2 || seen[1]!=2) $fatal(1,"FAIL: remaining axis2 must release exactly once");
 $display("PASS: round-robin voices release by their own axes");$finish;
 end
endmodule
