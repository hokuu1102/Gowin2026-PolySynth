`timescale 1ns/1ps
module tb_fft_view_backpressure;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg signed [23:0] sample=0;
 reg [5:0] test_n=4;
 reg [9:0] x=1,y=479;
 reg de=0;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire ready,overflow;
 wire [15:0] frame;
 wire [5:0] n;
 wire [7:0] r,g,b;
 wire [31:0] sd,fd;
 fft_spectrum_view #(.LOG2_N(6),.OUTLINE_EN(0),.COLOR_BARS_EN(0)) dut(
  .sample_clk_i(clk),.sample_rst_n_i(rst),.sample_i(sample),.sample_valid_i(valid),.test_n_i(test_n),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),
  .r_o(r),.g_o(g),.b_o(b),.frame_ready_o(ready),.frame_id_o(frame),.test_n_o(n),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 reg [15:0] stimulus[0:383];
 integer k;
 task feed;
  input integer start;
  begin
   for(k=0;k<64;k=k+1)begin
    @(negedge clk);sample={stimulus[start+k],8'd0};valid=1;
    @(negedge clk);valid=0;repeat(127)@(negedge clk);
   end
   repeat(4000)@(negedge clk);
  end
 endtask
 task pixel;
  input [9:0] px,py;
  input [23:0] rgb;
  begin
   @(negedge pclk);x=px;y=py;de=1;repeat(3)@(negedge pclk);
   if({r,g,b}!==rgb)$fatal(1,"FAIL: locked published spectrum pixel changed %0d,%0d",px,py);
  end
 endtask
 initial begin
  $readmemh("tb/data/fft/input64.hex",stimulus);
  repeat(6)@(negedge clk);rst=1;
  feed(128); // First publication: sine bin 5, N=4.
  test_n=32;feed(0);feed(0); // Two newer silence frames, no vertical blank.
  if(fd!==2 || sd!==0 || overflow!==0 || ready!==0)
   $fatal(1,"FAIL: expected two DISPLAY drops only: %0d %0d",fd,sd);
  @(negedge pclk);x=0;y=480;@(negedge pclk);x=1;
  wait(ready);@(negedge pclk);
  if(frame!==0 || n!==4)$fatal(1,"FAIL: old publication bank/metadata overwritten");
  pixel(144,200,24'h00ff80);
  pixel(64,8,24'h80ffff); // F title.
  pixel(154,8,24'h80ffff); // Literal top-row lit pixel of displayed digit 4.
  $display("PASS: stalled video preserves complete FFT bank and N; drops only display frames");$finish;
 end
 initial begin #5000000;$fatal(1,"FAIL: FFT video backpressure watchdog");end
endmodule
