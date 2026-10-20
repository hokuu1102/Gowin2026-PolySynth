`timescale 1ns/1ps
module tb_master_review;
reg clk=0; always #10 clk=~clk;
reg rst=0,tick=0,adc_valid=0; reg [11:0] adc=64;
wire [15:0] gain; wire signed [23:0] sample;
right_analog_ctrl adcctrl(.clk_i(clk),.rst_n_i(rst),.enable_i(1'b1),.sample_valid_i(adc_valid),.sample_ch_i(3'd1),.sample_data_i(adc),.master_gain_o(gain),.vibrato_depth_o(),.vibrato_rate_o(),.param_valid_o());
master_mix dut(.clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick),.valid_i(1'b1),.sample_i(24'sd1000000),.gain_i(gain),.valid_o(),.sample_o(sample),.ramp_busy_o());
initial begin
repeat(2) @(negedge clk); rst=1; adc_valid=1;
@(negedge clk); adc_valid=0;
@(negedge clk); tick=1;
@(negedge clk); tick=0;
if(gain!==16'd37 || dut.gain_r!==16'd37) $fatal(1,"setup failed target=%d actual=%d",gain,dut.gain_r);
$display("Before mute gain=%0d sample=%0d",dut.gain_r,sample);
adc=0; adc_valid=1;
@(negedge clk); adc_valid=0;
@(negedge clk); tick=1;
@(negedge clk); tick=0;
$display("After mute target=%0d gain=%0d sample=%0d",gain,dut.gain_r,sample);
if(dut.gain_r!==16'd0 || sample!==24'd0) $fatal(1,"MUTE_RAMP_UNDERFLOW expected gain=0 sample=0 actual gain=%0d sample=%0d",dut.gain_r,sample);
$finish;
end
endmodule
