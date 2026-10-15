`timescale 1ns/1ps
module tb_play_mode_merge_collision;
 reg clk=0,rst=0,valid=0,pluck=0;
 reg [3:0] axis=0;
 reg [1:0] kind=0;
 wire ov;
 wire [3:0] oa;
 wire [1:0] ok;
 wire [11:0] od;
 integer ons=0,offs=0;
 always #10 clk=~clk;
 play_mode_ctrl dut(.clk_i(clk),.rst_n_i(rst),.fretboard_mode_i(1'b1),
  .axis_valid_i(valid),.axis_i(axis),.axis_kind_i(kind),.axis_depth_i(12'd600),
  .pluck_valid_i(pluck),.pluck_up_i(1'b1),
  .evt_valid_o(ov),.evt_axis_o(oa),.evt_kind_o(ok),.evt_depth_o(od));
 always @(negedge clk) if(ov) begin
  if(ok==2) begin
   ons=ons+1;
   if(oa!=3) $fatal(1,"FAIL: wrong pluck axis");
  end
  if(ok==1) begin offs=offs+1;if(oa!=3) $fatal(1,"FAIL: wrong release axis");end
 end
 initial begin
 repeat(4) @(negedge clk);rst=1;
 // A single captured pluck coincides with a physical press.
 @(negedge clk);axis=3;kind=0;valid=1;pluck=1;
 @(negedge clk);valid=0;pluck=0;
 repeat(5) @(negedge clk);
 if(ons!=1) $fatal(1,"FAIL: simultaneous press swallowed captured pluck");
 @(negedge clk);axis=3;kind=1;valid=1;
 @(negedge clk);valid=0;
 repeat(4) @(negedge clk);
 if(offs!=1 || ons!=1) $fatal(1,"FAIL: collision replay duplicated/stranded voice");
 $display("PASS: simultaneous axis input retains exactly one captured pluck");$finish;
 end
endmodule
