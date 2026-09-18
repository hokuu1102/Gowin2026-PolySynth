// oscillator_bank.v
// W1-1 interface skeleton only. DDS, ROM and per-lane state arrive later.
// All logic stays in the 50 MHz clk_i domain; sample_tick_i is a clock-enable.
// Flat-bus contract: item i occupies bus[i*W +: W]. Lane index is
// voice_id*OSC_PER_VOICE + osc_id, so lane 0 is the least-significant slice.
`timescale 1ns/1ps

module oscillator_bank #(
    parameter integer POLY_TARGET       = 32,
    parameter integer OSC_PER_VOICE     = 2,
    parameter integer PHASE_W           = 32,
    parameter integer OSC_SAMPLE_W      = 16,
    parameter integer TIMBRE_N          = 2,
    parameter integer TIMBRE_W          = 1,
    parameter integer WT_DEPTH          = 512,
    parameter integer WT_W              = 16,
    parameter integer ENABLE_FM         = 0
) (
    input  wire                                             clk_i,
    input  wire                                             rst_n_i,
    input  wire                                             sample_tick_i,
    input  wire [POLY_TARGET-1:0]                           voice_active_i,
    input  wire [POLY_TARGET*PHASE_W-1:0]                   base_phase_inc_i,
    input  wire [TIMBRE_W-1:0]                              timbre_id_i,
    input  wire signed [15:0]                               vibrato_mod_i,
    input  wire                                             test_mode_i,
    input  wire [POLY_TARGET*OSC_PER_VOICE-1:0]             test_lane_active_i,
    input  wire [POLY_TARGET*OSC_PER_VOICE*PHASE_W-1:0]     test_phase_inc_i,
    input  wire                                             fm_cfg_valid_i,
    input  wire [15:0]                                      fm_ratio_i,
    input  wire [15:0]                                      fm_index_i,
    output wire [POLY_TARGET*OSC_PER_VOICE*OSC_SAMPLE_W-1:0] osc_sample_bus_o,
    output wire                                             osc_valid_o,
    output wire [PHASE_W-1:0]                               phase_acc_dbg_o
);

    // Safe W1-1 placeholder values. Functional logic must replace these ties.
    assign osc_sample_bus_o = {(POLY_TARGET*OSC_PER_VOICE*OSC_SAMPLE_W){1'b0}};
    assign osc_valid_o      = 1'b0;
    assign phase_acc_dbg_o  = {PHASE_W{1'b0}};

endmodule
