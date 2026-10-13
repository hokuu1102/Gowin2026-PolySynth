`timescale 1ns/1ps
module tb_dump_uart_backpressure;
 reg clk=0,rst=0,req=0;
 always #10 clk=~clk;
 wire push,ready,done,dbusy,ovf,start,ubusy,serial,rxdone;
 wire [7:0] byteval,drop,txdata,rxdata;
 wire [15:0] frames;
 integer received=0;
 always @(posedge clk) if(rxdone) received<=received+1;
 rec_dump rd(.clk_i(clk),.rst_n_i(rst),.req_i(req),.idle_i(1'b1),
  .cnt_i(16'd2),.data_i(64'h0123456789abcdef),.clip_i(1'b0),
  .ready_i(ready),.push_o(push),.byte_o(byteval),.busy_o(dbusy),.done_o(done),
  .frame_cnt_o(frames));
 uart_tx_fifo #(.DEPTH(8)) fifo(.clk_i(clk),.rst_n_i(rst),.push_i(push),
  .data_i(byteval),.ready_o(ready),.busy_i(ubusy),.ovf_o(ovf),
  .tx_start_o(start),.tx_data_o(txdata),.drop_cnt_o(drop),.ovf_clr_i(1'b0));
 uart_tx #(.BAUD_DIV(100)) tx(.clk_i(clk),.rst_n_i(rst),.tx_start_i(start),
  .tx_data_i(txdata),.tx_o(serial),.busy_o(ubusy));
 uart_rx #(.BAUD_DIV(100)) rx(.clk_i(clk),.rst_n_i(rst),.rx_i(serial),
  .rx_data_o(rxdata),.rx_done_o(rxdone));
 initial begin
  repeat(4) @(negedge clk); rst=1; req=1;
  @(negedge clk); req=0;
  repeat(30000) @(negedge clk);
  $display("RESULT reported_frames=%0d fifo_drop=%0d ovf=%b received_bytes=%0d expected=18",frames,drop,ovf,received);
  if(ovf || drop!=0 || received!=18) $display("FAIL: real 500kbps dump/FIFO/UART chain loses bytes");
  else $display("PASS");
  $finish;
 end
endmodule
