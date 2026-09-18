// tdm_render_mixer.v
// W1-1 interface skeleton only. The fixed-slot renderer arrives later.
// Flat-bus contract matches oscillator_bank/envelope_bank: item i is the
// bus[i*W +: W] slice; lanes are voice-major, then oscillator-within-voice.
`timescale 1ns/1ps

module tdm_render_mixer #(
    parameter integer POLY_TARGET         = 32,
    parameter integer OSC_PER_VOICE       = 2,
    parameter integer OSC_SAMPLE_W        = 16,
    parameter integer ENV_W               = 16,
    parameter integer SAMPLE_W            = 24,
    parameter integer CLK_PER_SAMPLE      = 1024,
    parameter integer RENDER_DEADLINE_CYC = 927
) (
    input  wire                                             clk_i,
    input  wire                                             rst_n_i,
    input  wire                                             render_start_i,
    input  wire [POLY_TARGET*OSC_PER_VOICE*OSC_SAMPLE_W-1:0] osc_sample_bus_i,
    input  wire [POLY_TARGET*ENV_W-1:0]                     env_level_i,
    output wire                                             dry_valid_o,
    output wire signed [SAMPLE_W-1:0]                       dry_sample_o,
    output wire                                             deadline_fault_o
);

    assign dry_valid_o      = 1'b0;
    assign dry_sample_o     = {SAMPLE_W{1'b0}};
    assign deadline_fault_o = 1'b0;

endmodule
