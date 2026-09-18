// envelope_bank.v
// W1-1 interface skeleton only. Per-voice ADSR state arrives later.
// Flat-bus contract: voice i occupies bus[i*W +: W], voice 0 at the LSB.
`timescale 1ns/1ps

module envelope_bank #(
    parameter integer POLY_TARGET = 32,
    parameter integer VEL_W       = 8,
    parameter integer ENV_W       = 16
) (
    input  wire                         clk_i,
    input  wire                         rst_n_i,
    input  wire                         sample_tick_i,
    input  wire [POLY_TARGET-1:0]       gate_i,
    input  wire [POLY_TARGET*VEL_W-1:0] velocity_i,
    output wire [POLY_TARGET*ENV_W-1:0] env_level_o,
    output wire [POLY_TARGET-1:0]       env_active_o
);

    assign env_level_o  = {(POLY_TARGET*ENV_W){1'b0}};
    assign env_active_o = {POLY_TARGET{1'b0}};

endmodule
