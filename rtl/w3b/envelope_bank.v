// envelope_bank.v
// Per-voice ADSR bank. Every generated instance owns independent state.
// Flat-bus contract: voice i occupies bus[i*W +: W], voice 0 at the LSB.
`timescale 1ns/1ps

module envelope_bank #(
    parameter integer POLY_TARGET = 32,
    parameter integer VEL_W       = 8,
    parameter integer ENV_W       = 16,
    parameter integer ATTACK_STEP = 669,
    parameter integer DECAY_STEP  = 4,
    parameter integer SUSTAIN_Q8  = 64,
    parameter integer RELEASE_STEP = 2
) (
    input  wire                         clk_i,
    input  wire                         rst_n_i,
    input  wire                         sample_tick_i,
    input  wire [POLY_TARGET-1:0]       gate_i,
    input  wire [POLY_TARGET*VEL_W-1:0] velocity_i,
    //  Per-voice retrigger reset: forces that voice's envelope to zero so a
    //  re-press or a steal restarts from silence instead of stacking on the
    //  tail of the previous note (see adsr.v for the full reasoning).
    input  wire [POLY_TARGET-1:0]       retrig_reset_i,
    input  wire [POLY_TARGET*2-1:0]     timbre_i,
    output wire [POLY_TARGET*ENV_W-1:0] env_level_o,
    output wire [POLY_TARGET-1:0]       env_active_o
);

    genvar voice_id;
    generate
        for (voice_id = 0; voice_id < POLY_TARGET; voice_id = voice_id + 1) begin : g_voice_envelope
            adsr #(
                .ENV_W        (ENV_W),
                .VEL_W        (VEL_W),
                .ATTACK_STEP  (ATTACK_STEP),
                .DECAY_STEP   (DECAY_STEP),
                .SUSTAIN_Q8   (SUSTAIN_Q8),
                .RELEASE_STEP (RELEASE_STEP)
            ) u_adsr (
                .clk_i         (clk_i),
                .rst_n_i       (rst_n_i),
                .sample_tick_i (sample_tick_i),
                .gate_i        (gate_i[voice_id]),
                .velocity_i    (velocity_i[voice_id*VEL_W +: VEL_W]),
                .retrig_reset_i(retrig_reset_i[voice_id]),
                .timbre_i      (timbre_i[voice_id*2 +: 2]),
                .env_level_o   (env_level_o[voice_id*ENV_W +: ENV_W]),
                .active_o      (env_active_o[voice_id])
            );
        end
    endgenerate

endmodule
