`timescale 1ns/1ps
module tb_uart_tx_fifo_clear_drop;
 reg clk=0,rst=0,push=0,clear=0;
 reg [7:0] data=0;
 always #10 clk=~clk;
 wire ready,idle,start,overflow;
 wire [7:0] sent,drops;
 uart_tx_fifo dut(.clk_i(clk),.rst_n_i(rst),.push_i(push),.data_i(data),
  .ready_o(ready),.idle_o(idle),.tx_start_o(start),.tx_data_o(sent),
  .busy_i(1'b1),.ovf_o(overflow),.drop_cnt_o(drops),.ovf_clr_i(clear));
 initial begin
  repeat(4) @(negedge clk);rst=1;
  push=1;repeat(8) @(negedge clk);
  if(ready!==1'b0) $fatal(1,"FAIL: FIFO must be full");
  repeat(2) @(negedge clk);
  if(drops!==8'd2) $fatal(1,"FAIL: precondition two previous drops");
  clear=1;@(negedge clk);clear=0;push=0;
  if(overflow!==1'b1 || drops!==8'd1)
   $fatal(1,"FAIL: clear must retain this cycle's NEW drop, got flag=%b count=%0d",overflow,drops);
  clear=1;@(negedge clk);clear=0;
  if(overflow!==1'b0 || drops!==8'd0) $fatal(1,"FAIL: clear without new drop");
  $display("PASS: concurrent clear/drop preserves new loss, plain clear empties history");$finish;
 end
endmodule
