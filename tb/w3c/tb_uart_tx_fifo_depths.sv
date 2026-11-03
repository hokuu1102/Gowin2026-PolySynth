`timescale 1ns/1ps
module fifo_depth_case #(parameter D=8)(output reg done=0);
 reg clk=0;always #10 clk=~clk;
 reg rst=0,push=0,block_tx=1,clear=0;reg[7:0] din=0;
 wire ready,start,busy,ovf,idle;wire[7:0] dout,drop;
 integer sent=0,k,round_n;reg[7:0] base;
 uart_tx_fifo #(.DEPTH(D)) dut(.clk_i(clk),.rst_n_i(rst),.push_i(push),.data_i(din),
 .ready_o(ready),.idle_o(idle),.tx_start_o(start),.tx_data_o(dout),.busy_i(block_tx|busy),
 .ovf_o(ovf),.drop_cnt_o(drop),.ovf_clr_i(clear));
 reg[3:0] left=0;assign busy=(left!=0);
 always @(posedge clk)begin
   if(!rst)left<=0;
   else if(start)begin
      if(busy||block_tx)$fatal(1,"D=%0d launch while blocked",D);
      if(dout!==(base+sent))$fatal(1,"D=%0d corrupt/wrong order at %0d",D,sent);
      sent=sent+1;left<=3;
   end else if(left!=0)left<=left-1;
 end
 initial begin
   repeat(3)@(negedge clk);rst=1;
   for(round_n=0;round_n<3;round_n=round_n+1)begin
     sent=0;base=round_n*64;block_tx=1;
     for(k=0;k<D;k=k+1)begin
       if(!ready)$fatal(1,"FAIL: D=%0d FIFO reports full before byte %0d",D,k);
       din=base+k;push=1;@(negedge clk);
     end
     push=0;
     if(ready)$fatal(1,"D=%0d did not report full",D);
     din=255;push=1;@(negedge clk);push=0;
     if(!ovf||drop!==1)$fatal(1,"D=%0d overflow not counted",D);
     clear=1;@(negedge clk);clear=0;
     if(ovf||drop!==0)$fatal(1,"D=%0d overflow clear failed",D);
     block_tx=0;
     wait(sent==D);repeat(10)@(negedge clk);
     if(!idle || !ready)$fatal(1,"D=%0d failed to drain",D);
   end
   $display("PASS FIFO depth %0d, full/empty, overflow/clear and pointer wrap",D);done=1;
 end
endmodule
module tb_uart_tx_fifo_depths;
 wire a,b;fifo_depth_case #(.D(8)) x(a);fifo_depth_case #(.D(64)) y(b);
 initial begin wait(a&&b);$display("PASS: FIFO depths 8 and 64");$finish;end
 initial begin #2000000;$fatal(1,"FAIL: FIFO depths watchdog");end
endmodule
