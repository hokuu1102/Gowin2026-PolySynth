`timescale 1ns/1ps
// Literal public RGB landmarks for a bin-5 tone in a 64-point fixture.
// Full scale: bin pair 4/5 at x144. Quarter scale: same pair at x384.
module tb_fft_zoom_modes;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg signed [23:0] sample=0;
 reg [5:0] configured_n=32;
 reg [9:0] x=1,y=479;
 reg de=0;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire [7:0] r,g,b;
 wire ready,overflow;
 wire [15:0] frame;
 wire [5:0] displayed_n;
 wire [31:0] sd,fd;
 fft_spectrum_view #(.LOG2_N(6),.OUTLINE_EN(0),.COLOR_BARS_EN(0)) dut(
  .sample_clk_i(clk),.sample_rst_n_i(rst),.sample_i(sample),.sample_valid_i(valid),.test_n_i(configured_n),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),
  .r_o(r),.g_o(g),.b_o(b),.de_o(),.hs_o(),.vs_o(),
  .frame_ready_o(ready),.frame_id_o(frame),.test_n_o(displayed_n),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 reg [15:0] stimulus[0:383];
 integer k;
 task feed;
  begin
   for(k=0;k<64;k=k+1)begin
    @(negedge clk);sample={stimulus[128+k],8'd0};valid=1;
    @(negedge clk);valid=0;repeat(127)@(negedge clk);
   end
   repeat(4000)@(negedge clk);
  end
 endtask
 task publish;
  input [15:0] expected_frame;
  input [5:0] expected_n;
  begin
   @(negedge pclk);de=0;x=0;y=480;@(negedge pclk);x=1;
   wait(ready && frame==expected_frame);@(negedge pclk);
   if(displayed_n!==expected_n)$fatal(1,"FAIL: non-atomic range metadata");
  end
 endtask
 task pixel;
  input integer px;
  input [23:0] expected;
  begin
   @(negedge pclk);x=px;y=200;de=1;repeat(3)@(negedge pclk);
   if({r,g,b}!==expected)$fatal(1,"FAIL: N=%0d x=%0d got=%h expected=%h",displayed_n,px,{r,g,b},expected);
  end
 endtask
 initial begin
  $readmemh("tb/data/fft/input64.hex",stimulus);
  repeat(6)@(negedge clk);rst=1;
  feed;publish(0,32);pixel(144,24'h00ff80);pixel(384,24'h000000);
  configured_n=0;feed;
  // Mode input changes must not relabel the visible older frame.
  if(frame!==0 || displayed_n!==32)$fatal(1,"FAIL: range changed before vertical blank");
  pixel(144,24'h00ff80);pixel(384,24'h000000);
  publish(1,0);pixel(144,24'h000000);pixel(384,24'h00ff80);
  configured_n=32;feed;
  pixel(144,24'h000000);pixel(384,24'h00ff80);
  publish(2,32);pixel(144,24'h00ff80);pixel(384,24'h000000);
  if(sd!==0 || fd!==0 || overflow!==0)$fatal(1,"FAIL: unexpected FFT loss");
  $display("PASS: normal quarter-band zoom, full test band, vblank-atomic range, zero drops");$finish;
 end
 initial begin #5000000;$fatal(1,"FAIL: FFT zoom timeout");end
endmodule
