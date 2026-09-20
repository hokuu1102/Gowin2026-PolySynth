`timescale 1ns/1ps

// T10 single-voice integration: independent frequency/phase state, real
// wavetable pROM, independent ADSR state, and deterministic amplitude scaling.
// All logic runs in the 50 MHz domain; tick_audio is a clock enable.
module voice #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer W_PHASE        = 32,
    parameter integer SAMPLE_W       = 24,
    parameter integer NOTE_VELOCITY  = 255,
    parameter integer ATTACK_STEP    = 669,
    parameter integer DECAY_STEP     = 4,
    parameter integer SUSTAIN_Q8     = 64,
    parameter integer RELEASE_STEP   = 2
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      tick_audio,
    input  wire                      note_on,
    input  wire                      note_off,
    input  wire [W_PHASE-1:0]        note_inc,
    output reg signed [SAMPLE_W-1:0] sample_out,
    output reg                       frame_done,
    output wire [W_PHASE-1:0]        phase_acc,
    output wire [W_PHASE-1:0]        phase_inc
);

    reg                  gate;
    reg [W_PHASE-1:0]    phase_inc_r;
    wire [15:0]          env_level;
    wire                 env_active;
    wire signed [15:0]   wavetable_sample;
    wire                 wavetable_valid;
    wire [31:0]          phase_acc_32;

    assign phase_inc = phase_inc_r;
    assign phase_acc = phase_acc_32;

    // Frequency is private voice state. Runtime pitch changes update only this
    // register; the accumulator below is never cleared by a pitch change.
    always @(posedge clk) begin
        if (!rst_n) begin
            gate        <= 1'b0;
            phase_inc_r <= {W_PHASE{1'b0}};
        end else begin
            if (note_on)
                gate <= 1'b1;
            else if (note_off)
                gate <= 1'b0;

            if (note_on || gate || env_active)
                phase_inc_r <= note_inc;
        end
    end

    dds_wavetable_core u_dds (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (tick_audio),
        .phase_inc_i   (phase_inc_r),
        .sample_o      (wavetable_sample),
        .valid_o       (wavetable_valid),
        .phase_acc_o   (phase_acc_32)
    );

    adsr #(
        .ENV_W        (16),
        .VEL_W        (8),
        .ATTACK_STEP  (ATTACK_STEP),
        .DECAY_STEP   (DECAY_STEP),
        .SUSTAIN_Q8   (SUSTAIN_Q8),
        .RELEASE_STEP (RELEASE_STEP)
    ) u_adsr (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (tick_audio),
        .gate_i        (gate),
        .velocity_i    (NOTE_VELOCITY[7:0]),
        .env_level_o   (env_level),
        .active_o      (env_active)
    );

    // Signed sample times unsigned Q0.16 envelope. Adding 2^16-1 only for a
    // negative product makes the arithmetic shift round toward zero, avoiding
    // the coherent negative DC bias of a bare signed >>> operation.
    wire signed [16:0] env_factor = $signed({1'b0, env_level});
    wire signed [32:0] product_raw = wavetable_sample * env_factor;
    wire signed [32:0] product_zero = product_raw[32]
                                      ? product_raw + 33'sd65535
                                      : product_raw;
    wire signed [16:0] scaled_wide = product_zero >>> 16;
    wire signed [15:0] scaled_16 = scaled_wide[15:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            sample_out <= {SAMPLE_W{1'b0}};
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (wavetable_valid) begin
                sample_out <= {scaled_16, {(SAMPLE_W-16){1'b0}}};
                frame_done <= 1'b1;
            end
        end
    end

endmodule
