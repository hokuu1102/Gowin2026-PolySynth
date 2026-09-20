`timescale 1ns/1ps

// One oscillator lane: independent 32-bit phase state plus one 512x16 table read.
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

    always @(posedge clk_i) begin
        if (!rst_n_i)
            phase_acc <= 32'd0;
        else if (sample_tick_i)
            phase_acc <= phase_acc + phase_inc_i;
    end

    wavetable_bank u_wavetable_bank (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .rd_en_i  (sample_tick_i),
        .addr_i   (phase_acc[31:23]),
        .sample_o (sample_o),
        .valid_o  (valid_o)
    );

endmodule
