`timescale 1ns/1ps
module tb_top_axis_review;
reg clk=0,rst=0; always #10 clk=~clk;
top dut(.clk(clk),.rst_n(rst),.uart_rx(1'b1),.timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),.enc_a_i(1'b1),.enc_b_i(1'b1),.enc_sw_i(1'b1));
reg [7:0] frames[0:55]; integer n=0,i; reg [3:0] ax=5; reg [1:0] kind=0;reg [31:0] inc=38702840;reg valid=0;
always @(negedge clk) if(dut.up_push_w && n<56) begin frames[n]=dut.up_byte_w;n=n+1;end
task evt; input[3:0] a; input[1:0] k; input[31:0] p; begin @(negedge clk);ax=a;kind=k;inc=p;valid=1;@(negedge clk);valid=0;repeat(30) @(negedge clk);end endtask
initial begin
force dut.g_sound.mg_evt_valid=valid; force dut.g_sound.mg_evt_axis=ax;
force dut.g_sound.mg_evt_kind=kind;force dut.g_sound.mg_evt_inc=inc;
force dut.g_sound.mg_evt_vel=8'd100;force dut.g_sound.mg_evt_src=3'd0;
force dut.g_sound.mg_evt_timbre_valid=1'b1;force dut.g_sound.mg_evt_timbre=2'd0;
force dut.up_enable_r=1'b1;
repeat(10) @(negedge clk);rst=1;repeat(40) @(negedge clk);
evt(5,0,38702840); evt(6,0,48702840);repeat(100) @(negedge clk);
evt(5,1,38702840); evt(6,1,48702840);
wait(n==56);@(negedge clk);
$writememh("review/standards/top-axis-frames.hex",frames);
for(i=0;i<4;i=i+1) begin
$write("frame%0d=",i);for(integer j=0;j<14;j=j+1) $write("%02x",frames[i*14+j]);$display("");
end
$display("input_axes=5,6,5,6 wire_axes=%0d,%0d,%0d,%0d",frames[7][3:0],frames[21][3:0],frames[35][3:0],frames[49][3:0]);
if(frames[7][3:0]!==5 || frames[21][3:0]!==6) $fatal(1,"MELODIC_AXIS_LOSS expected5,6 actual%0d,%0d",frames[7][3:0],frames[21][3:0]);
$finish;end
initial begin #30000000;$fatal(1,"timeout n=%0d",n);end
endmodule
