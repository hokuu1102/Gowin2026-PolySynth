`timescale 1ns/1ps

// T10 integration seam used by simulation and later top-level composition.
// It connects the real timebase, one real voice, and the production I2S TX.
module voice_i2s_chain #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer BCLK_DIV       = 16,
    parameter integer MCLK_DIV       = 4,
    parameter integer ATTACK_STEP    = 669,
    parameter integer DECAY_STEP     = 4,
    parameter integer SUSTAIN_Q8     = 64,
    parameter integer RELEASE_STEP   = 2
) (
    input  wire               clk_i,
    input  wire               rst_n_i,
    input  wire               note_on_i,
    input  wire               note_off_i,
    input  wire [31:0]        note_inc_i,
    output wire               HP_BCK,
    output wire               HP_WS,
    output wire               HP_DIN,
    output wire               tick_audio_o,
    output wire signed [23:0] sample_dbg_o,
    output wire               voice_done_o,
    output wire [31:0]        phase_acc_dbg_o,
    output wire [31:0]        phase_inc_dbg_o
);

    wire mclk_en;
    wire bclk_en;
    wire bclk_half_en;
    wire lrclk;
    wire frame_start;

    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
    ) u_clk_gen (
        .clk          (clk_i),
        .rst_n        (rst_n_i),
        .tick_audio   (tick_audio_o),
        .mclk_en      (mclk_en),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .lrclk        (lrclk),
        .frame_start  (frame_start)
    );

    voice #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .W_PHASE        (32),
        .SAMPLE_W       (24),
        .ATTACK_STEP    (ATTACK_STEP),
        .DECAY_STEP     (DECAY_STEP),
        .SUSTAIN_Q8     (SUSTAIN_Q8),
        .RELEASE_STEP   (RELEASE_STEP)
    ) u_voice (
        .clk        (clk_i),
        .rst_n      (rst_n_i),
        .tick_audio (tick_audio_o),
        .note_on    (note_on_i),
        .note_off   (note_off_i),
        .note_inc   (note_inc_i),
        .sample_out (sample_dbg_o),
        .frame_done (voice_done_o),
        .phase_acc  (phase_acc_dbg_o),
        .phase_inc  (phase_inc_dbg_o)
    );

    i2s_tx #(
        .SAMPLE_W  (24),
        .DATA_BITS (16),
        .SLOT_BITS (32),
        .JUSTIFY   (1),
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_i2s_tx (
        .clk          (clk_i),
        .rst_n        (rst_n_i),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_dbg_o),
        .sample_r     (sample_dbg_o),
        .HP_BCK       (HP_BCK),
        .HP_WS        (HP_WS),
        .HP_DIN       (HP_DIN)
    );

endmodule
