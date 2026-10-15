`timescale 1ns/1ps
module tb_fft_outline #(parameter integer PLAY_ZOOM=4);
 // Worked bin-5 landmarks: x224 for half-band, x384 for quarter-band.
 localparam integer TONE_X=(PLAY_ZOOM==2)?224:384;
 localparam integer NEIGHBOR_X=(PLAY_ZOOM==2)?192:320;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg signed [23:0] sample=0;
 reg [5:0] configured_n=0;
 reg [9:0] x=1,y=479;
 reg de=0;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire [7:0] r,g,b;
 wire ready,overflow;
 wire [15:0] frame;
 wire [5:0] displayed_n;
 wire [31:0] sd,fd;
 fft_spectrum_view #(.LOG2_N(6),.PLAY_ZOOM(PLAY_ZOOM),.COLOR_BARS_EN(0)) dut(.sample_clk_i(clk),.sample_rst_n_i(rst),
  .sample_i(sample),.sample_valid_i(valid),.test_n_i(configured_n),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),
  .hs_i(1'b1),.vs_i(1'b1),.r_o(r),.g_o(g),.b_o(b),.de_o(),.hs_o(),.vs_o(),
  .frame_ready_o(ready),.frame_id_o(frame),.test_n_o(displayed_n),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 reg [15:0] stimulus[0:383];
 integer stimulus_offset=128;
 integer k,px,py,hits,peak_y,bottom_y,previous_peak,previous_bottom,tone_peak;
 task feed;
  input integer seq;
  input integer publish_new;
  begin
   for(k=0;k<64;k=k+1)begin
    @(negedge clk);sample={stimulus[stimulus_offset+k],8'd0};valid=1;
    @(negedge clk);valid=0;repeat(127)@(negedge clk);
   end
   repeat(4000)@(negedge clk);
   if(publish_new)begin
    @(negedge pclk);x=0;y=480;de=0;@(negedge pclk);x=1;
    wait(ready && frame==seq);@(negedge pclk);
   end
  end
 endtask
 task point;
  input integer xx,yy;
  begin @(negedge pclk);x=xx;y=yy;de=1;repeat(3)@(negedge pclk);
   if(^{r,g,b}===1'bx)$fatal(1,"FAIL: unknown outline RGB");
  end
 endtask
 task scan;
  input integer xx;
  begin
   hits=0;peak_y=448;bottom_y=-1;
   for(py=47;py<=447;py=py+1)begin
    point(xx,py);
    if({r,g,b}==24'h00ff80)begin hits=hits+1;if(py<peak_y)peak_y=py;bottom_y=py;end
   end
  end
 endtask
 initial begin
  $readmemh("tb/data/fft/input64.hex",stimulus);
  repeat(6)@(negedge clk);rst=1;
  feed(0,1);
  point(TONE_X,446);
  if({r,g,b}!==24'h000000)$fatal(1,"FAIL: outline still fills tone down to baseline");
  scan(TONE_X);if(hits<1 || peak_y>220 || bottom_y>350)$fatal(1,"FAIL: independent bin-5 peak missing");
  tone_peak=peak_y;
  scan(NEIGHBOR_X);if(peak_y<tone_peak+20)$fatal(1,"FAIL: bin-4 and bin-5 merged into a flat grouped peak");
  scan(TONE_X);previous_peak=peak_y;previous_bottom=bottom_y;
  // Sample consecutive columns on the bin-5 to bin-6 descending flank.
  for(px=TONE_X+1;px<=TONE_X+16;px=px+1)begin
   scan(px);
   if(hits<1 || hits>8)$fatal(1,"FAIL: sparse/disconnected or excessively filled flank x=%0d hits=%0d",px,hits);
   if(peak_y>previous_bottom+1 || previous_peak>bottom_y+1)
    $fatal(1,"FAIL: broken segment connection x=%0d",px);
   previous_peak=peak_y;previous_bottom=bottom_y;
  end
  configured_n=32;feed(1,1);
  if(displayed_n!==32)$fatal(1,"FAIL: full-band metadata");
  scan(128);if(hits<1 || peak_y>220)$fatal(1,"FAIL: full-band tone disappeared");
  point(128,446);if({r,g,b}!==24'h000000)$fatal(1,"FAIL: full-band outline filled");
  if(sd!==0 || fd!==0 || overflow!==0)$fatal(1,"FAIL: spectrum drops/overflow");
  configured_n=0;feed(2,0);
  if(frame!==1 || displayed_n!==32)$fatal(1,"FAIL: range switched before blanking");
  configured_n=32;feed(3,0); // Locked published normal frame must survive.
  if(frame!==1 || displayed_n!==32 || fd!==1)$fatal(1,"FAIL: outline backpressure ownership");
  @(negedge pclk);x=0;y=480;de=0;@(negedge pclk);x=1;
  wait(frame==2);@(negedge pclk);
  if(displayed_n!==0)$fatal(1,"FAIL: published normal frame metadata overwritten");
  scan(TONE_X);if(hits<1 || peak_y>220)$fatal(1,"FAIL: locked outline snapshot overwritten");
  if(sd!==0 || overflow!==0)$fatal(1,"FAIL: audio capture drops in display backpressure");
  if(PLAY_ZOOM==2)begin
   // Fixture 3 contains bins 3 and 13. Bin 13 is above the old quarter band;
   // it must now be visible at the worked half-band landmark x480.
   stimulus_offset=192;configured_n=0;feed(4,1);
   scan(480);if(hits<1 || peak_y>250)$fatal(1,"FAIL: newly included upper half-band tone missing");
   point(480,446);if({r,g,b}!==24'h000000)$fatal(1,"FAIL: upper-band outline filled");
   if(sd!==0 || fd!==1 || overflow!==0)$fatal(1,"FAIL: upper-band capture drop");
  end
  $display("PASS: independent-bin sharp outline, no fill, connected flank, full-band and atomic backpressure");$finish;
 end
 initial begin #10000000;$fatal(1,"FAIL: outline timeout");end
endmodule
