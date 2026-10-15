`timescale 1ns/1ps
module tb_fft_color_bars;
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
 fft_spectrum_view dut(.sample_clk_i(clk),.sample_rst_n_i(rst),.sample_i(sample),
  .sample_valid_i(valid),.test_n_i(configured_n),.pixel_clk_i(pclk),.pixel_rst_n_i(rst),
  .x_i(x),.y_i(y),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),.r_o(r),.g_o(g),.b_o(b),
  .de_o(),.hs_o(),.vs_o(),.frame_ready_o(ready),.frame_id_o(frame),.test_n_o(displayed_n),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 integer k,px,gaps,filled;
 integer tone_input=0;
 task point;
  input integer xx,yy;
  begin @(negedge pclk);x=xx;y=yy;de=1;repeat(3)@(negedge pclk);
   if(^{r,g,b}===1'bx)$fatal(1,"FAIL: unknown color RGB");
  end
 endtask
 task color;
  input integer xx;
  input [23:0] expected;
  begin point(xx,440);if({r,g,b}!==expected)$fatal(1,"FAIL: x=%0d rgb=%h expected=%h",xx,{r,g,b},expected);end
 endtask
 task capture;
  begin
   // Centered impulse survives the periodic Hann window and produces a flat
   // spectrum, exposing every display column through real FFT arithmetic.
   for(k=0;k<2048;k=k+1)begin
    @(negedge clk);valid=1;
    if(tone_input)sample=$rtoi(12000.0*$sin(6.283185307179586*300*k/2048))*256;
    else sample=(k==1024)?24'sh7fff00:24'sd0;
   end
   @(negedge clk);valid=0;repeat(150000)@(negedge clk);
  end
 endtask
 task publish;
  input integer seq,n;
  begin
   @(negedge pclk);de=0;x=0;y=480;@(negedge pclk);x=1;
   wait(ready && frame==seq);@(negedge pclk);
   if(displayed_n!==n)$fatal(1,"FAIL: color frame metadata");
  end
 endtask
 initial begin
  repeat(6)@(negedge clk);rst=1;
  point(64,440);if({r,g,b}!==0)$fatal(1,"FAIL: uninitialized color frame visible");
  capture;publish(0,0);
  color(64,24'hff4080);color(192,24'hff8000);color(320,24'hffff00);
  color(448,24'h00ff00);color(572,24'h00fff8);
  gaps=0;filled=0;
  for(px=64;px<576;px=px+1)begin
   point(px,440);
   if((px-64)%4==3)begin
    if({r,g,b}!==0)$fatal(1,"FAIL: black gap missing x=%0d",px);gaps=gaps+1;
   end else begin
    if({r,g,b}===0)$fatal(1,"FAIL: filled bar missing x=%0d",px);filled=filled+1;
   end
  end
  if(gaps!=128 || filled!=384)$fatal(1,"FAIL: 128x3+1 geometry");
  point(64,50);if({r,g,b}!==0)$fatal(1,"FAIL: filled beyond peak");
  configured_n=32;capture;
  if(frame!==0 || displayed_n!==0)$fatal(1,"FAIL: mode switched before vblank");
  publish(1,32);color(572,24'h00fff8);
  configured_n=0;capture;publish(2,0);color(64,24'hff4080);
  // Bin 300 is above the former x4 normal viewport. At x2 it lands in
  // normal group 75 (x364); full-band Test Mode group 37 (x212).
  tone_input=1;capture;publish(3,0);
  point(364,400);if({r,g,b}!==24'ha7ff00)$fatal(1,"FAIL: normal x2 bin-300 range/group/color");
  point(367,400);if({r,g,b}!==0)$fatal(1,"FAIL: normal tone gap");
  point(212,300);if({r,g,b}!==0)$fatal(1,"FAIL: normal tone mapped as full band");
  configured_n=32;capture;publish(4,32);
  point(212,400);if({r,g,b}!==24'hff9400)$fatal(1,"FAIL: full-band bin-300 range/group/color");
  point(215,400);if({r,g,b}!==0)$fatal(1,"FAIL: full-band tone gap");
  point(364,300);if({r,g,b}!==0)$fatal(1,"FAIL: full tone mapped as normal band");
  if(sd!==0 || fd!==0 || overflow!==0)$fatal(1,"FAIL: color capture drops/overflow");
  $display("PASS: production 2048 FFT, 128 colored filled bars, exact 3+1 gaps, both ranges, atomic frames");$finish;
 end
 initial begin #30000000;$fatal(1,"FAIL: color-bars watchdog");end
endmodule
