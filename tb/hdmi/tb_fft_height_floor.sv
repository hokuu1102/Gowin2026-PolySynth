`timescale 1ns/1ps
module tb_fft_height_floor;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg signed [23:0] sample=0;
 reg [9:0] x=1,y=479;
 reg de=0;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire [7:0] r,g,b;
 wire ready,overflow;
 wire [15:0] frame;
 wire [31:0] sd,fd;
 fft_spectrum_view #(.LOG2_N(6),.OUTLINE_EN(0),.COLOR_BARS_EN(0)) dut(.sample_clk_i(clk),.sample_rst_n_i(rst),
  .sample_i(sample),.sample_valid_i(valid),.test_n_i(6'd32),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),
  .hs_i(1'b1),.vs_i(1'b1),.r_o(r),.g_o(g),.b_o(b),.de_o(),.hs_o(),.vs_o(),
  .frame_ready_o(ready),.frame_id_o(frame),.test_n_o(),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 integer k;
 task feed;
  input integer amplitude,seq;
  begin
   for(k=0;k<64;k=k+1)begin
    @(negedge clk);sample=amplitude*256;valid=1;
    @(negedge clk);valid=0;repeat(127)@(negedge clk);
   end
   repeat(4000)@(negedge clk);
   @(negedge pclk);de=0;x=0;y=480;@(negedge pclk);x=1;
   wait(ready && frame==seq);@(negedge pclk);
  end
 endtask
 task pixel;
  input integer px,py;
  input [23:0] expected;
  begin
   @(negedge pclk);x=px;y=py;de=1;repeat(3)@(negedge pclk);
   if({r,g,b}!==expected)$fatal(1,"FAIL: floor frame=%0d x=%0d y=%0d got=%h expected=%h",frame,px,py,{r,g,b},expected);
  end
 endtask
 initial begin
  repeat(6)@(negedge clk);rst=1;
  feed(8,0);pixel(64,400,24'h000000);pixel(64,446,24'h00ff80);
  feed(1000,1);pixel(64,300,24'h00ff80);pixel(400,300,24'h000000);
  feed(0,2);pixel(64,446,24'h000000);pixel(64,300,24'h000000);
  if(sd!==0 || fd!==0 || overflow!==0)$fatal(1,"FAIL: floor capture drops/overflow");
  $display("PASS: weak spectrum near baseline, strong spectrum visible, silence black, zero drops");$finish;
 end
 initial begin #5000000;$fatal(1,"FAIL: height-floor watchdog");end
endmodule
