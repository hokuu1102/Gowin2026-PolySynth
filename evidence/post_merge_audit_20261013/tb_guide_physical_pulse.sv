`timescale 1ns/1ps
module tb_guide_physical_pulse;
 reg clk=0,rst=0,blink=0;
 always #10 clk=~clk;
 wire [23:0] pattern;
 wire commit,sdi,sck,le,busy;
 wire [4:0] oe;
 integer shifts=0,ones=0,latches=0;
 led_data ld(.clk_i(clk),.rst_n_i(rst),.guide_key_i(16'h0020),
  .key_active_i(16'd0),.status_i(8'd0),.blink_i(blink),
  .pattern_o(pattern),.pattern_commit_o(commit));
 tlc5916_bank bank(.clk_i(clk),.rst_n_i(rst),.pattern_i(pattern),
  .pattern_commit_i(commit),.global_blank_i(1'b0),.led_sdi_o(sdi),
  .led_clk_o(sck),.led_le_o(le),.led_oe_n_o(oe),.busy_o(busy));
 always @(posedge sck) begin shifts=shifts+1; if(sdi) ones=ones+1; end
 always @(posedge le) latches=latches+1;
 initial begin
  repeat(4) @(negedge clk); rst=1;
  repeat(4) @(negedge clk);
  blink=1; // exact top wiring: beat_gen.beat_o is one system-clock pulse
  @(negedge clk); blink=0;
  repeat(20000) @(negedge clk);
  $display("RESULT shifts=%0d ones=%0d latches=%0d final_oe=%b guide_axis=5",shifts,ones,latches,oe);
  if(ones==0) $display("FAIL: requested guide key never reaches TLC physical data");
  else $display("PASS");
  $finish;
 end
endmodule
