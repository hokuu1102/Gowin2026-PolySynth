`timescale 1ns/1ps
// Exercise actual accepted-event mapping plus independent LED pulse timers.
// Reduced timer constants change time scale only; ledger capacity semantics
// and the display/reference priorities are unchanged.
module tb_guide_flash;
reg clk=0,rst=0,v=0,alive=1,fb=0,blink=0,clear=0;
reg sweep=0;integer beat_period=80,phase=0;
// Scaled 6.25ms units: pulse=8 (50ms), beat window=20 (125ms).
// Advance at the opposite edge from the RTL to avoid sampling races.
always @(negedge clk)if(sweep)begin
 blink <= phase<20;
 phase <= phase==beat_period-1 ? 0 : phase+1;
end
reg signed [4:0] tr=0;reg [63:0] data=0;reg [15:0] active=0;
always #10 clk=~clk;
wire [15:0] held,vis,onmask;wire onvalid,idle;wire [3:0] onkey;wire [23:0] pattern;
guide_lamp #(.HELD_SLOTS(4),.TIMEOUT_CLKS(12)) gl(
 .clk_i(clk),.rst_n_i(rst),.note_valid_i(v),.note_data_i(data),.note_off5_i(data[4:0]),.transpose_i(tr),.fb_mode_i(fb),.key_active_i(active),.stream_alive_i(alive),
 .guide_key_o(held),.guide_commit_o(),.guide_vis_o(vis),.guide_on_valid_o(onvalid),.guide_on_key_o(onkey),.stream_idle_o(idle));
assign onmask=onvalid?(16'h1<<onkey):16'd0;
led_data #(.GUIDE_PULSE_CLKS(8)) ld(.clk_i(clk),.rst_n_i(rst),.guide_key_i(vis),.key_active_i(active),.status_i(8'ha5),.blink_i(blink),.guide_on_i(onmask),.guide_clear_i(clear|idle),.pattern_o(pattern),.pattern_commit_o());
task waitn(input integer n);begin repeat(n)@(negedge clk);end endtask
task check(input bit ok,input [511:0] label);begin if(!ok)$fatal(1,"FAIL: %0s held=%h pattern=%h",label,held,pattern);end endtask
task send(input [3:0] axis,input [4:0] pitch,input bit off,input bit accepted,input [3:0] key);begin
 @(negedge clk);data={20'd0,21'd10000,axis,8'd100,1'b0,off,2'b00,1'b0,1'b0,pitch};v=1;
 @(negedge clk);v=0;
 check(onvalid===accepted,"accepted ON indication");
 if(accepted)check(onkey==key,"registered mapped key");
end endtask
task reset_all;begin sweep=0;rst=0;v=0;alive=1;tr=0;fb=0;blink=0;clear=0;active=0;waitn(3);rst=1;waitn(3);end endtask
integer i,b,p;
initial begin
 reset_all();
 send(0,3,0,1,5);waitn(2);check(pattern[5],"dark-window ON visible");
 send(0,3,1,0,0);waitn(2);check(held==0 && pattern[5],"OFF closes ledger but preserves pulse tail");
 waitn(10);check(pattern[15:0]==0,"pulse expires without hanging lamp");
 send(0,3,0,1,5);waitn(5);send(0,3,0,1,5);waitn(5);
 check(pattern[5] && held[5],"same-identity repeat reloads timer while bitmap stays one");
 send(0,3,1,0,0);waitn(2);check(held[5],"first OFF preserves overlapping identity");
 send(0,3,1,0,0);waitn(10);check(held==0 && pattern[15:0]==0,"balanced repeated OFFs close cleanly");
 send(0,3,0,1,5);waitn(10);check(held[5] && !pattern[5],"long note dark after initial pulse");
 send(1,7,0,1,3);waitn(2);check(pattern[3] && !pattern[5],"new key does not flash other held key");
 blink=1;waitn(2);check(pattern[5] && pattern[3],"long-held keys retain beat blinking");
 active=16'h0020;blink=0;waitn(10);check(pattern[5] && !pattern[3],"physical pressed key has steady priority");
 active=0;waitn(2);check(pattern[15:0]==0,"release follows current guide phase");
 check(pattern[23:16]==8'ha5,"status passthrough unchanged");
 reset_all();tr=1;send(0,3,0,1,6);waitn(2);check(pattern[6] && !pattern[5],"transpose maps pulse and ledger together");
 tr=0;send(0,3,1,0,0);waitn(10);check(held==0,"transpose change does not redirect OFF");
 fb=1;send(0,0,0,1,5);send(0,0,1,0,0);waitn(10);
 send(0,4,0,0,0);waitn(2);check(pattern[15:0]==0,"unmapped fretboard note has no phantom pulse");
 reset_all();
 send(0,3,0,1,5);send(1,5,0,1,4);send(2,7,0,1,3);send(3,8,0,1,2);
 waitn(10);send(4,10,0,0,0);waitn(2);check(!pattern[13] && !held[13],"full ledger rejects new identity without flash");
 send(0,3,0,1,5);waitn(2);check(pattern[5],"full ledger still accepts existing identity repeat");
 clear=1;waitn(3);clear=0;check(pattern[15:0]==0,"clear cancels every pending pulse");
 check(held!=0,"display clear does not alter held ledger");
 alive=0;waitn(16);check(idle && held==0 && pattern[15:0]==0,"stream timeout clears ledger and pulses");
 alive=1;send(0,3,0,1,5);waitn(3);check(pattern[5],"first resumed note survives timeout recovery");
 rst=0;waitn(3);check(pattern==0,"reset cancels all state");
 // Sweep all within-beat offsets for scaled 40/120/240 BPM periods.
 // blink's pulse width is fixed while the beat period changes.
 for(b=0;b<3;b=b+1)begin
  if(b==0)p=240;else if(b==1)p=80;else p=40;
  for(i=0;i<p;i=i+1)begin
   reset_all();beat_period=p;phase=i;blink=(i<20);sweep=1;
   send(0,3,0,1,5);send(0,3,1,0,0);waitn(2);
   check(pattern[5],"phase/BPM sweep short note always visible");
   sweep=0;blink=0;waitn(10);check(pattern[15:0]==0,"swept short note expires");
  end
 end
 $display("PASS: guide pulse mapping, OFF tail, repeats, overlapping identities, per-key isolation, priority, transpose, modes, capacity, clear, timeout, replay and 360 beat phases");$finish;
end
initial begin #1000000;$fatal(1,"FAIL: timeout");end
endmodule
