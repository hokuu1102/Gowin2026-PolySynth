`timescale 1ns/1ps
module tb_fx_clip_valid;
  reg clk=0; always #10 clk=~clk;
  reg rst=0;
  wire [15:0] clips;
  fx_dist dut(.clk_i(clk),.rst_n_i(rst),.valid_i(1'b0),.sample_i(24'sd4000000),
    .en_i(1'b1),.sel_i(2'd0),.gain_i(16'd16384),.trim_i(16'd32768),.clip_cnt_o(clips));
  initial begin
    repeat(5) @(negedge clk); rst=1;
    repeat(100) @(negedge clk);
    $display("accepted_samples=0 clip_count=%0d",clips);
    if(clips !== 16'd0) $fatal(1,"FAIL clip counter advances without any valid sample");
    $display("PASS clip counter valid qualification"); $finish;
  end
endmodule
