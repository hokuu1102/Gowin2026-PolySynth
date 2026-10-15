`timescale 1ns/1ps
module tb_fft_spectrum_overrun;
 reg clk=0,rst=0,en=1,valid=0;
 reg signed [15:0] sample=0;
 always #10 clk=~clk;
 wire bv,done,busy,overflow;
 wire [5:0] bin;
 wire signed [17:0] re,im;
 wire [15:0] frame;
 wire [31:0] drops;
 fft_spectrum_core #(.LOG2_N(6),.WINDOW_EN(0)) dut(
  .clk_i(clk),.rst_n_i(rst),.enable_i(en),.sample_valid_i(valid),.sample_i(sample),
  .bin_valid_o(bv),.bin_index_o(bin),.bin_real_o(re),.bin_imag_o(im),
  .frame_done_o(done),.frame_id_o(frame),.busy_o(busy),.overflow_o(overflow),.dropped_samples_o(drops));
 integer k,complete=0,bin_count=0,target;
 reg restarted=0;
 always @(posedge clk)if(rst && en)begin
  if(bv)begin
   if(restarted)target=-16000;else target=(frame==0)?4000:8000;
   if(bin==0)begin
    if($signed(re)<target-40 || $signed(re)>target+40 || $signed(im)>40 || $signed(im)< -40)
     $fatal(1,"FAIL: capture bank overwritten or stale: %0d %0d",frame,re);
   end else if($signed(re)>40 || $signed(re)< -40 || $signed(im)>40 || $signed(im)< -40)
    $fatal(1,"FAIL: constant-input non-DC spectrum polluted");
   bin_count=bin_count+1;
  end
  if(done)complete=complete+1;
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;valid=1;
  for(k=0;k<160;k=k+1)begin
   sample=(k<64)?1000:(k<128)?2000:3000;@(negedge clk);
  end
  valid=0;
  if(drops!==32)$fatal(1,"FAIL: exact burst drops expected 32, got %0d",drops);
  wait(complete==2);@(negedge clk);
  if(bin_count!=66 || overflow!==0)$fatal(1,"FAIL: queued spectrum count/overflow");
  en=0;@(negedge clk);
  if(busy!==0 || bv!==0 || done!==0)$fatal(1,"FAIL: disabled FFT still publishes");
  en=1;valid=1;repeat(16)@(negedge clk);valid=0;
  rst=0;repeat(3)@(negedge clk);rst=1;restarted=1;
  for(k=0;k<64;k=k+1)begin sample=-4000;valid=1;@(negedge clk);valid=0;repeat(127)@(negedge clk);end
  wait(complete==3);@(negedge clk);
  if(frame!==0 || drops!==0 || bin_count!=99)$fatal(1,"FAIL: reset did not restart complete frame");
  $display("PASS: burst overflow counted without capture overwrite; disable/reset cancel partial frames");$finish;
 end
 initial begin #10000000;$fatal(1,"FAIL: overrun watchdog");end
endmodule
