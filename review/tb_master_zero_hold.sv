`timescale 1ns/1ps
module tb_master_zero_hold;
reg clk=0; always #10 clk=~clk;
reg rst=0,tick=0,adc_valid=0;
reg [11:0] adc=64;
wire [15:0] gain;
wire signed [23:0] sample;
integer k,zero_count=0;
reg [15:0] first_wrapped;
right_analog_ctrl adcctrl(.clk_i(clk),.rst_n_i(rst),.enable_i(1'b1),
 .sample_valid_i(adc_valid),.sample_ch_i(3'd1),.sample_data_i(adc),
 .master_gain_o(gain),.vibrato_depth_o(),.vibrato_rate_o(),.param_valid_o());
master_mix dut(.clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick),.valid_i(1'b1),
 .sample_i(24'sd1000000),.gain_i(gain),.valid_o(),.sample_o(sample),.ramp_busy_o());
task audio_tick;
 begin
  @(negedge clk);tick=1;
  @(negedge clk);tick=0;
  repeat(1022) @(negedge clk);
 end
endtask
initial begin
 repeat(3) @(negedge clk);rst=1;adc_valid=1;
 @(negedge clk);adc_valid=0;
 audio_tick;
 if(dut.gain_r!==16'd37) $fatal(1,"invalid setup");
 adc=0;adc_valid=1;
 @(negedge clk);adc_valid=0;
 for(k=1;k<=1025;k=k+1)begin
  audio_tick;
  if(dut.gain_r===0)zero_count=zero_count+1;
  if(k==1)first_wrapped=dut.gain_r;
  if(k==1 || k==512 || k==513 || k==1024 || k==1025)
   $display("tick=%0d target=%0d gain=%0d sample=%0d",k,gain,dut.gain_r,sample);
 end
 $display("zero_count=%0d over1025 audio ticks; first gain=%0d",zero_count,first_wrapped);
 if(dut.gain_r!==0 || zero_count!=1025)
  $fatal(1,"MUTE_NEVER_CONVERGES expected all1025 tick gains=0");
 $display("PASS: mute clamps and remains zero");$finish;
end
endmodule
