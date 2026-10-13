`timescale 1ns/1ps
module tb_dump_fifo_backpressure;
 reg clk=0,rst=0,req=0;
 always #10 clk=~clk;
 wire push,ready,done,busy,ovf;
 wire [7:0] byteval,drop;
 wire [15:0] frames;
 rec_dump rd(.clk_i(clk),.rst_n_i(rst),.req_i(req),.idle_i(1'b1),
  .cnt_i(16'd1),.data_i(64'h0123456789abcdef),.clip_i(1'b0),
  .ready_i(ready),.push_o(push),.byte_o(byteval),.busy_o(busy),.done_o(done),
  .frame_cnt_o(frames));
 // busy=1 is a legal downstream condition while a previous UART byte is sent.
 uart_tx_fifo #(.DEPTH(8)) fifo(.clk_i(clk),.rst_n_i(rst),.push_i(push),
  .data_i(byteval),.ready_o(ready),.busy_i(1'b1),.ovf_o(ovf),
  .drop_cnt_o(drop),.ovf_clr_i(1'b0));
 initial begin
  repeat(4) @(negedge clk); rst=1; req=1;
  @(negedge clk); req=0;
  repeat(30) @(negedge clk);
  $display("RESULT reported_frames=%0d fifo_drop=%0d ovf=%b busy=%b",frames,drop,ovf,busy);
  if(ovf || drop!=0) $display("FAIL: real rec_dump/uart_tx_fifo ready handshake loses bytes");
  else $display("PASS");
  $finish;
 end
endmodule
