`timescale 1ns/1ps
module led_pulse_duration_case #(parameter integer N=1)(output reg done=0);
reg clk=0,rst=0,on=0;wire [0:0] pattern;time started;
always #10 clk=~clk;
led_data #(.KEY_N(1),.STATUS_N(0),.GUIDE_PULSE_CLKS(N)) dut(
 .clk_i(clk),.rst_n_i(rst),.guide_key_i(1'b0),.key_active_i(1'b0),.status_i(2'b00),.blink_i(1'b0),.guide_on_i(on),.guide_clear_i(1'b0),.pattern_o(pattern),.pattern_commit_o());
initial begin
 repeat(3)@(negedge clk);rst=1;
 @(negedge clk);on=1;@(negedge clk);on=0;
 wait(pattern[0]===1'b1);started=$time;
 @(negedge pattern[0]);
 if($time-started!=20*N)$fatal(1,"FAIL: N=%0d pulse duration=%0t expected=%0d ns",N,$time-started,20*N);
 $display("PASS: exact visible pulse length N=%0d, %0d ns",N,$time-started);done=1;
end
endmodule
module tb_led_pulse_duration;
wire a,b,c;
led_pulse_duration_case #(.N(1)) one(a);
led_pulse_duration_case #(.N(8)) eight(b);
led_pulse_duration_case #(.N(2500000)) real50ms(c);
initial begin wait(a&&b&&c);$display("PASS: timer width boundaries and actual 50ms at 50MHz");$finish;end
initial begin #60000000;$fatal(1,"FAIL: duration timeout");end
endmodule
