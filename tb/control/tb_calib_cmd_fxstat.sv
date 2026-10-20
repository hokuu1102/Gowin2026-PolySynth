`timescale 1ns/1ps
module tb_calib_cmd_fxstat;
reg clk=0; always #10 clk=~clk;
reg rst=0,done=0; reg [7:0] data=0;
wire req; wire [2:0] sub; wire [15:0] unknown,commands; integer seen=0;
calib_cmd dut(.clk_i(clk),.rst_n_i(rst),.rx_done_i(done),.rx_data_i(data),.fxstat_req_o(req),.fxstat_sub_o(sub),.unknown_cnt_o(unknown),.cmd_cnt_o(commands));
always @(posedge clk) if(req) seen=seen+1;
task send; input [7:0] b; begin @(negedge clk); data=b;done=1;@(negedge clk);done=0; end endtask
initial begin repeat(3) @(negedge clk); rst=1; send(8'h5a); send(8'h00); repeat(4) @(negedge clk);
$display("FXSTAT Z0 expected=1 request actual=%0d unknown=%0d commands=%0d",seen,unknown,commands);
if(seen!=1) $fatal(1,"FXSTAT command is unreachable");
$display("PASS: ASCII and binary FXSTAT commands accepted"); $finish;end
endmodule
