`timescale 1ns/1ps
module tb_master_mix_boundaries;
  reg clk=0; always #10 clk=~clk;
  reg rst=0, tick=0;
  reg [15:0] gain=0;
  wire signed [23:0] sample;
  wire busy;
  master_mix dut(.clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick),
    .valid_i(1'b1),.sample_i(24'sd1000000),.gain_i(gain),
    .valid_o(),.sample_o(sample),.ramp_busy_o(busy));
  integer k;
  reg [15:0] previous;
  task step;
    begin @(negedge clk);tick=1;@(negedge clk);tick=0;end
  endtask
  task settle;
    input [15:0] target;
    integer j;
    begin
      gain=target;
      for(j=0;j<520;j=j+1) begin
        previous=dut.gain_r;
        step;
        if(previous<target && (dut.gain_r<previous || dut.gain_r>target))
          $fatal(1,"upward ramp wrapped or overshot");
        if(previous>target && (dut.gain_r>previous || dut.gain_r<target))
          $fatal(1,"downward ramp wrapped or overshot");
      end
      if(dut.gain_r!==target || busy) $fatal(1,"gain did not settle");
    end
  endtask
  initial begin
    repeat(2) @(negedge clk);rst=1;
    settle(16'd37);settle(16'd0);
    for(k=0;k<1025;k=k+1) begin
      step;
      if(dut.gain_r!==0 || sample!==0) $fatal(1,"mute did not remain silent");
    end
    settle(16'd65530);settle(16'd65535);settle(16'd65498);
    settle(16'd0);
    $display("PASS: gain ramps remain bounded at mute and full scale");
    $finish;
  end
endmodule
