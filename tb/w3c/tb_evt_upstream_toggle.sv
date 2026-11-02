`timescale 1ns/1ps
module tb_evt_upstream_toggle;
 reg clk=0,rst=0,en=0,valid=0,ready=0;
 reg [1:0] kind=0;
 reg [3:0] axis=0;
 wire push,busy,overflow;
 wire [7:0] data,seq;
 wire [15:0] frames,drops;
 wire [31:0] ticks;
 wire [4:0] level;
 reg [7:0] rx[0:255];
 integer n=0,i,j;
 reg [7:0] ck;
 always #10 clk=~clk;
 evt_upstream dut(.clk_i(clk),.rst_n_i(rst),.enable_i(en),
  .evt_valid_i(valid),.evt_axis_i(axis),.evt_phase_inc_i(32'd38702840),
  .evt_velocity_i(8'd100),.evt_kind_i(kind),.evt_timbre_i(2'd2),
  .evt_is_drum_i(1'b0),.tick_step_i(1'b0),.ready_i(ready),
  .push_o(push),.byte_o(data),.busy_o(busy),.frame_cnt_o(frames),
  .drop_cnt_o(drops),.overflow_o(overflow),.seq_o(seq),.tick_o(ticks),.level_o(level));
 always @(posedge clk) if(push) begin
  if(n>=256) $fatal(1,"FAIL: unexpected output flood");
  rx[n]=data; n=n+1;
 end
 task event_in(input [3:0] a,input [1:0] k);
 begin @(negedge clk);axis=a;kind=k;valid=1;
 @(negedge clk);valid=0; repeat(4) @(negedge clk);end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 event_in(1,0);event_in(1,1);ready=1;repeat(40) @(negedge clk);
 if(n!=0 || level!=0) $fatal(1,"FAIL: initial disabled state must be quiet");
 @(negedge clk);en=1;ready=0;
 event_in(1,0);event_in(2,0);event_in(3,2);
 // Disable with an in-flight frame and two queued events, downstream blocked.
 @(negedge clk);en=0;
 event_in(4,0);event_in(5,2); // rejected, not replayed at next enable
 event_in(1,1);event_in(2,1);event_in(3,1); // must now be rejected while disabled
 @(negedge clk);ready=1;
 repeat(180) @(negedge clk);
 if(n!=42 || frames!=3 || level!=0 || busy || drops!=0 || overflow)
  $fatal(1,"FAIL: disabled note_off must not be transmitted n=%0d frames=%0d",n,frames);
 for(i=0;i<3;i=i+1) begin
  if(rx[14*i]!==8'hA5 || rx[14*i+2]!==i ||
     rx[14*i+1]!==8'h01 ||
     rx[14*i+7]!== (8'h20 + (i%3)+1))
   $fatal(1,"FAIL: event identity/type/sequence corrupted frame=%0d",i);
  ck=0;for(j=0;j<13;j=j+1) ck=ck^rx[14*i+j];
  if(rx[14*i+13]!==ck) $fatal(1,"FAIL: incomplete/corrupt frame");
 end
 // Keep playing/releasing after the initial queue is fully empty.
 for(i=0;i<4;i=i+1) begin
  event_in(8+i,0);event_in(8+i,1);event_in(8+i,2);
 end
 repeat(40) @(negedge clk);
 if(n!=42 || level!=0 || busy || drops!=0)
  $fatal(1,"FAIL: disabled playback/release generated new traffic");
 @(negedge clk);en=1;repeat(40) @(negedge clk);
 if(n!=42) $fatal(1,"FAIL: old queue replayed at re-enable");
 event_in(6,0);repeat(40) @(negedge clk);
 if(n!=56 || rx[49]!==8'h26 || rx[44]!==8'd3)
  $fatal(1,"FAIL: new session did not resume correctly");
 // Disable half-way through a frame; backpressure must hold the next byte.
 @(negedge clk);ready=0;
 event_in(7,0);
 @(negedge clk);ready=1;
 wait(n==61); #1;ready=0;en=0;
 repeat(20) @(negedge clk);
 if(n!=61) $fatal(1,"FAIL: backpressure accepted bytes");
 @(posedge clk);#1;ready=1;
 repeat(40) @(negedge clk);
 if(n!=70 || frames!=5) $fatal(1,"FAIL: disable truncated active frame");
 ck=0;for(j=56;j<69;j=j+1) ck=ck^rx[j];
 if(rx[69]!==ck) $fatal(1,"FAIL: active frame checksum after toggle");
 $display("PASS: toggle drains accepted frames, rejects every disabled ON/OFF/pluck, no stale replay or half frames");$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: toggle watchdog");end
endmodule
