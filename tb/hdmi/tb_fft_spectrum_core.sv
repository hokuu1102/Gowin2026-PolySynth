`timescale 1ns/1ps
module tb_fft_spectrum_core #(
 parameter integer LOG2_N=6,
 parameter integer SAMPLE_GAP=128,
 parameter INPUT_FILE="tb/data/fft/input64.hex",
 parameter EXPECTED_FILE="tb/data/fft/dft64.hex"
);
 localparam LG=LOG2_N,N=1<<LG,FRAMES=6,BINS=N/2+1;
 reg clk=0,rst=0,valid=0;
 reg signed [15:0] sample=0;
 always #10 clk=~clk;
 wire bin_valid,done,busy,overflow;
 wire [LG-1:0] bin;
 wire signed [17:0] re,im;
 wire [15:0] frame_id;
 wire [31:0] drops;
 fft_spectrum_core #(.LOG2_N(LG)) dut(.clk_i(clk),.rst_n_i(rst),
  .enable_i(1'b1),.sample_valid_i(valid),.sample_i(sample),
  .bin_valid_o(bin_valid),.bin_index_o(bin),.bin_real_o(re),.bin_imag_o(im),
  .frame_done_o(done),.frame_id_o(frame_id),.busy_o(busy),
  .overflow_o(overflow),.dropped_samples_o(drops));
 reg [15:0] inputs[0:FRAMES*N-1];
 reg [35:0] expected[0:FRAMES*BINS-1];
 integer sent=0,received=0,frames_done=0;
 integer er,ei,dr,di;
 always @(posedge clk) if(rst) begin
  if((^{bin_valid,done,busy,overflow,drops})===1'bx)$fatal(1,"FAIL: unknown FFT status");
  if(bin_valid) begin
   if((^{bin,re,im,frame_id})===1'bx)$fatal(1,"FAIL: unknown FFT bin");
   if(received>=FRAMES*BINS)$fatal(1,"FAIL: extra FFT bins");
   if(bin!==received%BINS || frame_id!==received/BINS)
    $fatal(1,"FAIL: FFT ordering bin=%0d frame=%0d",bin,frame_id);
   er=$signed(expected[received][35:18]);ei=$signed(expected[received][17:0]);
   dr=$signed(re)-er;di=$signed(im)-ei;
   if(dr>40 || dr< -40 || di>40 || di< -40)
    $fatal(1,"FAIL: bin %0d actual (%0d,%0d) DFT (%0d,%0d)",received,re,im,er,ei);
   received=received+1;
  end
  if(done)frames_done=frames_done+1;
 end
 initial begin
  $readmemh(INPUT_FILE,inputs);
  $readmemh(EXPECTED_FILE,expected);
  repeat(5)@(negedge clk);rst=1;
  for(sent=0;sent<FRAMES*N;sent=sent+1) begin
   sample=inputs[sent];valid=1;@(negedge clk);valid=0;
   repeat(SAMPLE_GAP-1)@(negedge clk);
  end
  wait(frames_done==FRAMES);@(negedge clk);
  if(received!=FRAMES*BINS || drops!==0 || overflow!==0)
   $fatal(1,"FAIL: FFT count/drop/overflow %0d %0d %b",received,drops,overflow);
  $display("PASS: six real-input FFT frames match independent direct DFT, exact ordering and no drops");
  $finish;
 end
 initial begin #(FRAMES*N*SAMPLE_GAP*20+10000000);$fatal(1,"FAIL: FFT watchdog");end
endmodule
