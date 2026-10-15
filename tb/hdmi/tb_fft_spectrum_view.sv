`timescale 1ns/1ps
module tb_fft_spectrum_view;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg signed [23:0] sample=0;
 reg [9:0] x=0,y=0;
 reg de=0,hs=1,vs=1;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire [7:0] r,g,b;
 wire od,oh,ov,ready,overflow;
 wire [15:0] frame;
 wire [5:0] n;
 wire [31:0] samples_dropped,frames_dropped;
 fft_spectrum_view #(.LOG2_N(6),.OUTLINE_EN(0),.COLOR_BARS_EN(0)) dut(.sample_clk_i(clk),.sample_rst_n_i(rst),
  .sample_i(sample),.sample_valid_i(valid),.test_n_i(6'd32),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),.hs_i(hs),.vs_i(vs),
  .r_o(r),.g_o(g),.b_o(b),.de_o(od),.hs_o(oh),.vs_o(ov),
  .frame_ready_o(ready),.frame_id_o(frame),.test_n_o(n),
  .dropped_samples_o(samples_dropped),.dropped_frames_o(frames_dropped),.overflow_o(overflow));
 reg [15:0] stimulus[0:383];
 integer k;
 task pixel;
  input [9:0] px,py;
  input [23:0] expected;
  begin
   @(negedge pclk);x=px;y=py;de=1;
   repeat(3)@(negedge pclk);
   if({r,g,b}!==expected || od!==1'b1)$fatal(1,"FAIL: spectrum pixel %0d,%0d got %06h",px,py,{r,g,b});
  end
 endtask
 initial begin
  $readmemh("tb/data/fft/input64.hex",stimulus);
  repeat(6)@(negedge clk);rst=1;
  pixel(144,200,24'h000000); // Before first completed frame: known black.
  de=0;
  for(k=0;k<64;k=k+1)begin
   @(negedge clk);sample={$signed(stimulus[128+k]),8'd0};valid=1;
   @(negedge clk);valid=0;repeat(127)@(negedge clk);
  end
  repeat(4000)@(negedge clk);
  if(ready!==0)$fatal(1,"FAIL: spectrum became visible before vertical blank");
  @(negedge pclk);x=0;y=480;
  @(negedge pclk);x=1;
  wait(ready);@(negedge pclk);
  if(frame!==0 || n!==32)$fatal(1,"FAIL: spectrum metadata is not atomic");
  pixel(144,200,24'h00ff80); // Bin 5 tone, grouped with bin 4.
  pixel(400,200,24'h000000); // No tone at bins 20/21.
  if(samples_dropped!==0 || frames_dropped!==0 || overflow!==0)
   $fatal(1,"FAIL: unexpected spectrum loss/overflow");
  $display("PASS: real FFT to pixel bars, vertical-blank commit and atomic N/frame metadata");$finish;
 end
 initial begin #5000000;$fatal(1,"FAIL: spectrum view watchdog");end
endmodule
