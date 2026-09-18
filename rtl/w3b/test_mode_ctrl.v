// test_mode_ctrl.v
// W1-1 interface skeleton only. N=4/8/16/32 generation arrives later.
// n_code_i mapping is 00/01/10/11 -> TEST_N0/1/2/3. In Test Mode only
// oscillator 0 of each selected voice is enabled; flat-bus ordering is the
// same voice-major lane order used by oscillator_bank.
`timescale 1ns/1ps

module test_mode_ctrl #(
    parameter integer POLY_TARGET   = 32,
    parameter integer OSC_PER_VOICE = 2,
    parameter integer PHASE_W       = 32,
    parameter integer VEL_W         = 8,
    parameter integer TEST_N0       = 4,
    parameter integer TEST_N1       = 8,
    parameter integer TEST_N2       = 16,
    parameter integer TEST_N3       = 32
) (
    input  wire                                         clk_i,
    input  wire                                         rst_n_i,
    input  wire                                         sample_tick_i,
    input  wire                                         enable_i,
    input  wire [1:0]                                   n_code_i,
    output wire [POLY_TARGET-1:0]                       test_voice_gate_o,
    output wire [POLY_TARGET*VEL_W-1:0]                 test_velocity_o,
    output wire [POLY_TARGET*OSC_PER_VOICE-1:0]         test_lane_active_o,
    output wire [POLY_TARGET*OSC_PER_VOICE*PHASE_W-1:0] test_phase_inc_o,
    output wire [5:0]                                   active_n_o
);

    assign test_voice_gate_o  = {POLY_TARGET{1'b0}};
    assign test_velocity_o    = {(POLY_TARGET*VEL_W){1'b0}};
    assign test_lane_active_o = {(POLY_TARGET*OSC_PER_VOICE){1'b0}};
    assign test_phase_inc_o   = {(POLY_TARGET*OSC_PER_VOICE*PHASE_W){1'b0}};
    assign active_n_o         = 6'd0;

endmodule
