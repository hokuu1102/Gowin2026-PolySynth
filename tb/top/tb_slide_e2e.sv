`timescale 1ns/1ps
// Compatibility entry point for the real UART/SPI/comparator/I2S regression.
// Historical forced-am_mode/autonomous-ramp fixture is archived in evidence.
`include "tb/top/tb_slide_position_e2e.sv"
module tb_slide_e2e;
    tb_slide_position_e2e acceptance();
endmodule
