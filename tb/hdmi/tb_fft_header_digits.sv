`timescale 1ns/1ps
// Public RGB/metadata seam: all 64 values, both decimal glyphs, no private force.
module tb_fft_header_digits;
 reg clk=0,pclk=0,rst=0,valid=0;
 reg [5:0] configured_n=0;
 reg [9:0] x=1,y=479;
 reg de=0;
 always #10 clk=~clk;
 always #20 pclk=~pclk;
 wire ready,overflow;
 wire [15:0] frame;
 wire [5:0] displayed_n;
 wire [7:0] r,g,b;
 wire [31:0] sd,fd;
 fft_spectrum_view #(.LOG2_N(6)) dut(
  .sample_clk_i(clk),.sample_rst_n_i(rst),.sample_i(24'sd0),.sample_valid_i(valid),.test_n_i(configured_n),
  .pixel_clk_i(pclk),.pixel_rst_n_i(rst),.x_i(x),.y_i(y),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),
  .r_o(r),.g_o(g),.b_o(b),.de_o(),.hs_o(),.vs_o(),
  .frame_ready_o(ready),.frame_id_o(frame),.test_n_o(displayed_n),
  .dropped_samples_o(sd),.dropped_frames_o(fd),.overflow_o(overflow));
 function [34:0] digit;
  input integer v;
  begin case(v)
   0:digit=35'b01110_10001_10011_10101_11001_10001_01110;
   1:digit=35'b00100_01100_00100_00100_00100_00100_01110;
   2:digit=35'b01110_10001_00001_00010_00100_01000_11111;
   3:digit=35'b11110_00001_00001_01110_00001_00001_11110;
   4:digit=35'b00010_00110_01010_10010_11111_00010_00010;
   5:digit=35'b11111_10000_10000_11110_00001_00001_11110;
   6:digit=35'b01110_10000_10000_11110_10001_10001_01110;
   7:digit=35'b11111_00001_00010_00100_01000_01000_01000;
   8:digit=35'b01110_10001_10001_01110_10001_10001_01110;
   9:digit=35'b01110_10001_10001_01111_00001_00001_01110;
   default:digit=0;
  endcase end
 endfunction
 integer n,k,digit_index,row,col,checks=0;
 reg [34:0] expected;
 reg [23:0] expected_rgb;
 initial begin
  repeat(6)@(negedge clk);rst=1;
  for(n=0;n<64;n=n+1)begin
   configured_n=n;
   for(k=0;k<64;k=k+1)begin
    @(negedge clk);valid=1;@(negedge clk);valid=0;repeat(127)@(negedge clk);
   end
   repeat(4000)@(negedge clk);
   @(negedge pclk);de=0;x=0;y=480;@(negedge pclk);x=1;
   wait(ready && frame==n);@(negedge pclk);
   if(displayed_n!==n || sd!==0 || fd!==0 || overflow!==0)
    $fatal(1,"FAIL: header metadata/drop N=%0d",n);
   for(digit_index=0;digit_index<2;digit_index=digit_index+1)begin
    expected=digit(digit_index==0 ? n/10 : n%10);
    for(row=0;row<7;row=row+1)for(col=0;col<6;col=col+1)begin
     @(negedge pclk);x=136+digit_index*12+col*2;y=8+row*2;de=1;
     repeat(3)@(negedge pclk);
     expected_rgb=(col<5 && expected[34-row*5-col])?24'h80ffff:24'h000000;
     if({r,g,b}!==expected_rgb)$fatal(1,"FAIL: N=%0d digit=%0d row=%0d col=%0d rgb=%h expected=%h",n,digit_index,row,col,{r,g,b},expected_rgb);
     checks=checks+1;
    end
   end
  end
  $display("PASS: all 64 FFT N headers, %0d public RGB checks, atomic metadata and zero drops",checks);
  $finish;
 end
 initial begin #30000000;$fatal(1,"FAIL: FFT header watchdog");end
endmodule
