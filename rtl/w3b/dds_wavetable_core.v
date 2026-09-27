`timescale 1ns/1ps

// Compatibility DDS: independent 32-bit phase state plus the legacy 512x16
// sine pROM.  The production polyphonic path uses wavetable_bank directly.
// All logic runs in the 50 MHz system clock domain; sample_tick_i is a clock enable.
// Changing phase_inc_i never resets phase_acc, so pitch changes remain continuous.
module dds_wavetable_core (
    input  wire                      clk_i,
    input  wire                      rst_n_i,
    input  wire                      sample_tick_i,
    input  wire [31:0]               phase_inc_i,
    output wire signed [15:0]        sample_o,
    output wire                      valid_o,
    output wire [31:0]               phase_acc_o
);

    reg [31:0] phase_acc;

    assign phase_acc_o = phase_acc;

    reg valid_r;
    wire [15:0] sine_rom_o;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            phase_acc <= 32'd0;
            valid_r   <= 1'b0;
        end else begin
            valid_r <= sample_tick_i;
            if (sample_tick_i)
                phase_acc <= phase_acc + phase_inc_i;
        end
    end

    // Existing generated Gowin pROM; tests substitute the checked timing model.
    wavetable_sine_rom_ip u_legacy_sine_rom (
        .dout  (sine_rom_o),
        .clk   (clk_i),
        .oce   (1'b1),
        .ce    (sample_tick_i),
        .reset (~rst_n_i),
        .ad    (phase_acc[31:23])
    );

    assign sample_o = sine_rom_o;
    assign valid_o  = valid_r;

endmodule
