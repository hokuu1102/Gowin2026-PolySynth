`timescale 1ns/1ps
module tb_evt_upstream_queue;
 reg clk=0,rst=0,valid=0,ready=0,tick_step=0;
 reg [3:0] axis=0;
 wire push,busy,overflow;
 wire [7:0] data,seq;
 wire [15:0] frames,drops;
 wire [31:0] ticks;
 wire [4:0] level;
 reg [7:0] rx[0:99];
 integer n=0,i,j;
 reg [7:0] ck;
 always #10 clk=~clk;
 evt_upstream #(.FIFO_D(4)) dut(.clk_i(clk),.rst_n_i(rst),
  .evt_valid_i(valid),.evt_axis_i(axis),.evt_phase_inc_i(32'd38702840),
  .evt_velocity_i(8'd100),.evt_kind_i(2'd0),.tick_step_i(tick_step),
  .enable_i(1'b1),.ready_i(ready),.push_o(push),.byte_o(data),
  .busy_o(busy),.frame_cnt_o(frames),.drop_cnt_o(drops),
  .overflow_o(overflow),.seq_o(seq),.tick_o(ticks),.level_o(level));
 always @(negedge clk) if(push && ready) begin
  if(n>=100) $fatal(1,"FAIL: queue emitted unexpected extra bytes");
  rx[n]=data;n=n+1;
 end
 task event_in(input [3:0] a);
 begin @(negedge clk);axis=a;valid=1;
 @(negedge clk);valid=0;repeat(4) @(negedge clk);end endtask
 task tick_once;
 begin @(negedge clk);tick_step=1;@(negedge clk);tick_step=0;end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 event_in(1); // in-flight frame is blocked; the FIFO itself is empty
 for(i=2;i<=5;i=i+1) begin tick_once;event_in(i);end
 event_in(6);event_in(7); // full FIFO must reject rather than overwrite
 if(level!==5'd4 || drops!==16'd2 || !overflow)
  $fatal(1,"FAIL: full queue corrupted level/drop count level=%0d drops=%0d",level,drops);
 @(posedge clk);#1;ready=1;repeat(180) @(negedge clk);
 if(n!=70 || frames!=5 || level!=0 || busy)
  $fatal(1,"FAIL: full queue did not drain exactly five frames n=%0d",n);
 for(i=0;i<5;i=i+1) begin
  if(rx[i*14+7]!==i+1 || rx[i*14+2]!==i ||
     {rx[i*14+3],rx[i*14+4],rx[i*14+5],rx[i*14+6]}!==i)
   $fatal(1,"FAIL: queue changed accepted event order or capture timestamp frame=%0d",i);
  ck=0;for(j=0;j<13;j=j+1) ck=ck^rx[i*14+j];
  if(rx[i*14+13]!==ck) $fatal(1,"FAIL: queued frame checksum");
 end
 $display("PASS: upstream full queue preserves accepted events and capture timestamps");$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: upstream queue watchdog");end
endmodule
