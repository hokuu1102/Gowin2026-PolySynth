`timescale 1ns/1ps
`include "tb/hdmi/tb_fft_spectrum_core.sv"
module tb_fft_spectrum_2048;
 tb_fft_spectrum_core #(.LOG2_N(11),.SAMPLE_GAP(1024),
  .INPUT_FILE("tb/data/fft/input2048.hex"),
  .EXPECTED_FILE("tb/data/fft/dft2048.hex")) test();
endmodule
