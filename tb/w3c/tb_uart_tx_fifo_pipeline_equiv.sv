`timescale 1ns/1ps
module tb_uart_tx_fifo_pipeline_equiv;
 reg clk=0,rst=0,push=0,clear=0,busy=0;
 reg [7:0] data=0;
 always #10 clk=~clk;
 wire r0,i0,s0,o0,r1,i1,s1,o1;
 wire [7:0] d0,c0,d1,c1;
 uart_tx_fifo dut(.clk_i(clk),.rst_n_i(rst),.push_i(push),.data_i(data),
  .ready_o(r0),.idle_o(i0),.tx_start_o(s0),.tx_data_o(d0),.busy_i(busy),
  .ovf_o(o0),.drop_cnt_o(c0),.ovf_clr_i(clear));
 uart_tx_fifo_reference ref_fifo(.clk_i(clk),.rst_n_i(rst),.push_i(push),.data_i(data),
  .ready_o(r1),.idle_o(i1),.tx_start_o(s1),.tx_data_o(d1),.busy_i(busy),
  .ovf_o(o1),.drop_cnt_o(c1),.ovf_clr_i(clear));
 integer cycles=0,launches=0,j;
 reg [31:0] rng=32'h7ac419e3;
 always @(posedge clk) begin
  #1;
  cycles=cycles+1;
  if ({r0,i0,s0,d0,o0,c0} !== {r1,i1,s1,d1,o1,c1})
   $fatal(1,"FAIL: FIFO public outputs differ at cycle %0d",cycles);
  if(s0) launches=launches+1;
 end
 task tick;
  input p,b,c;
  input [7:0] value;
  begin
   @(negedge clk);push=p;busy=b;clear=c;data=value;
  end
 endtask
 initial begin
  repeat(4) @(negedge clk);rst=1;
  // Literal first byte must launch one cycle after acceptance, no extra delay.
  tick(1,0,0,8'hA5);tick(0,0,0,0);@(negedge clk);
  if(s0!==1'b1 || d0!==8'hA5) $fatal(1,"FAIL: immediate launch timing/data");
  tick(0,1,0,0);tick(0,0,0,0);tick(0,0,0,0);
  // Backpressure, saturation, clear+drop and pointer wrap.
  for(j=0;j<300;j=j+1) tick(1,1,(j==299),j);
  if(c0!==8'd1 || o0!==1'b1) begin
   @(negedge clk);
   if(c0!==8'd1 || o0!==1'b1) $fatal(1,"FAIL: new loss after clear");
  end
  for(j=0;j<50000;j=j+1) begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   tick(rng[0]|rng[3],rng[4],rng[9]&rng[10],rng[23:16]);
   // Reset during both accepted writes and blocked transfers.
   if(j%997==0) rst=0;else rst=1;
  end
  tick(0,0,1,0);rst=1;
  for(j=0;j<100;j=j+1) tick(0,(j%4==1),0,0);
  if(launches<1000) $fatal(1,"FAIL: insufficient launch coverage %0d",launches);
  $display("PASS: FIFO cycle equivalence %0d cycles, %0d launches",cycles,launches);
  $finish;
 end
endmodule
