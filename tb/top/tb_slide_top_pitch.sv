`timescale 1ns/1ps
// Real axis_map public lookup -> real position controller public pitch.
// Physical neighbour detection is covered by tb_ee_adj; real top mux is covered
// by tb_slide_position_e2e. No copied mux or source-text anchors.
module tb_slide_top_pitch;
 reg clk=0,rst=0,en=1,trig=0,tick=0;
 always #10 clk=~clk;
 reg [3:0] a=0,b=0;
 reg [191:0] positions=0;
 wire [3:0] lookup_axis,owner;
 wire [31:0] lookup_inc,pitch;
 wire valid,active,busy;
 integer seen=0,checks=0;
 reg [31:0] captured;
 reg [3:0] captured_owner;
 axis_map mapping(.clk(clk),.rst_n(rst),.pos_valid_i(1'b0),
  .axis_id_i(4'd0),.pos_i(12'd0),.mode_i(1'b1),
  .axis_id_b_i(lookup_axis),.phase_inc_b_o(lookup_inc),
  .phase_inc_o(),.phase_valid_o(),.axis_id_o());
 slide_position_ctrl dut(.clk_i(clk),.rst_n_i(rst),.enable_i(en),
  .trigger_i(trig),.snapshot_i(tick),.axis_a_i(a),.axis_b_i(b),
  .positions_i(positions),.lookup_axis_o(lookup_axis),.lookup_inc_i(lookup_inc),
  .pitch_valid_o(valid),.pitch_axis_o(owner),.pitch_inc_o(pitch),
  .active_o(active),.busy_o(busy));
 always @(negedge clk) if(valid===1'b1) begin
  seen=seen+1;captured=pitch;captured_owner=owner;
 end
 task clocks(input integer n);repeat(n) @(negedge clk);endtask
 task pair(input [3:0] aa,input [3:0] bb,input [31:0] expected);
  integer previous;
  begin
   en=0;clocks(2);en=1;
   a=aa;b=bb;positions=0;positions[aa*12+:12]=256;positions[bb*12+:12]=256;
   previous=seen;trig=1;clocks(1);trig=0;clocks(80);
   if(seen!=previous+1 || captured!==expected || captured_owner!==aa)
    $fatal(1,"FAIL pair %0d/%0d got axis=%0d value=%08h expected=%08h",
     aa,bb,captured_owner,captured,expected);
   checks=checks+1;
  end
 endtask
 initial begin
  clocks(4);rst=1;clocks(2);
  // Literal equal-depth means from the agreed fretboard note table.
  pair(4'd6,4'd7,32'h00caef37);
  pair(4'd7,4'd0,32'h00d70065);
  pair(4'd0,4'd1,32'h00e3c944);
  pair(4'd5,4'd4,32'h00980770);
  pair(4'd4,4'd3,32'h00a111b5);
  pair(4'd3,4'd2,32'h00aaa597);
  pair(4'd14,4'd15,32'h0169968b);
  pair(4'd15,4'd8,32'h017f16d6);
  pair(4'd8,4'd9,32'h0195de6e);
  pair(4'd13,4'd12,32'h010ee28e);
  pair(4'd12,4'd11,32'h011efe1d);
  pair(4'd11,4'd10,32'h01300ee0);
  en=0;clocks(2);trig=1;clocks(1);trig=0;clocks(80);
  if(valid!==1'b0 || active!==1'b0 || busy!==1'b0)
   $fatal(1,"FAIL disabled slide must be inactive");
  $display("PASS: real map and position follower, %0d physical pairs",checks);$finish;
 end
endmodule
