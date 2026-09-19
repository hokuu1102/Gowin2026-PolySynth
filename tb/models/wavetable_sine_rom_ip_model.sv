`timescale 1ns/1ps

// Simulation-only timing model for the generated Gowin Bypass-mode pROM.
// It exists to verify the synthesis-path wrapper without compiling vendor
// primitives in Icarus. Hardware initialization remains in the generated IP.
module wavetable_sine_rom_ip (
    output reg  [15:0] dout,
    input  wire        clk,
    input  wire        oce,
    input  wire        ce,
    input  wire        reset,
    input  wire [8:0]  ad
);
    reg [15:0] rom [0:511];

    initial begin
        $readmemh("rtl/w3b/rom/sine_512x16.hex", rom);
        dout = 16'd0;
    end

    always @(posedge clk) begin
        if (reset)
            dout <= 16'd0;
        else if (ce && oce)
            dout <= rom[ad];
    end
endmodule
