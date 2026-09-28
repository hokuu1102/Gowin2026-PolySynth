`timescale 1ns/1ps

// One voice's independent envelope state.
// All state changes occur on sample_tick_i in the 50 MHz clock domain.
// velocity_i maps linearly to the attack peak; SUSTAIN_Q8 is a Q0.8 ratio.
module adsr #(
    parameter integer ENV_W        = 16,
    parameter integer VEL_W        = 8,
    parameter integer ATTACK_STEP  = 669,
    parameter integer DECAY_STEP   = 4,
    parameter integer SUSTAIN_Q8   = 64,
    parameter integer RELEASE_STEP = 2
) (
    input  wire                 clk_i,
    input  wire                 rst_n_i,
    input  wire                 sample_tick_i,
    input  wire                 gate_i,
    input  wire [VEL_W-1:0]     velocity_i,
    //  Retrigger reset: a one-sample-tick pulse that forces the envelope back
    //  to zero and re-enters ATTACK from scratch.
    //
    //  Why this exists: `note_manager` reacts to a same-axis re-press by
    //  rewriting `phase_inc` and pulsing `gate` low then high. If the envelope
    //  is still anywhere above zero when `gate` returns, the ADSR resumes from
    //  the residual level, so the old tail and the new attack stack and the
    //  output spikes far above full scale. Zeroing first makes the re-press a
    //  clean restart and removes the dependency on the release time constant.
    input  wire                 retrig_reset_i,
    output reg  [ENV_W-1:0]     env_level_o,
    output wire                 active_o
);

    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_ATTACK  = 2'd1;
    localparam [1:0] ST_DECAY   = 2'd2;
    localparam [1:0] ST_SUSTAIN = 2'd3;

    localparam [ENV_W:0] ATTACK_STEP_U  = ATTACK_STEP;
    localparam [ENV_W:0] DECAY_STEP_U   = DECAY_STEP;
    localparam [ENV_W:0] RELEASE_STEP_U = RELEASE_STEP;
    localparam [7:0]     SUSTAIN_Q8_U   = SUSTAIN_Q8;

    // Release is represented by a flag so all four named ADSR phases remain
    // visible while keeping the externally observable interface minimal.
    reg [1:0] state;
    reg       releasing;

    // Default 8-to-16 mapping is velocity << 8: monotonic, multiplier-free,
    // and leaves one byte of headroom at velocity 255.
    wire [ENV_W-1:0] peak_level = {velocity_i, {(ENV_W-VEL_W){1'b0}}};
    wire [ENV_W+7:0] sustain_product = peak_level * SUSTAIN_Q8_U;
    wire [ENV_W-1:0] sustain_level = sustain_product >> 8;

    assign active_o = (state != ST_IDLE) || releasing || (env_level_o != {ENV_W{1'b0}});

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state       <= ST_IDLE;
            releasing   <= 1'b0;
            env_level_o <= {ENV_W{1'b0}};
        end else if (sample_tick_i) begin
            if (retrig_reset_i) begin
                //  Highest priority: a retrigger discards whatever the envelope
                //  was doing, including a release in flight. The level must go
                //  to zero BEFORE gate returns, otherwise the residual tail and
                //  the new attack add up and the voice overshoots.
                env_level_o <= {ENV_W{1'b0}};
                releasing   <= 1'b0;
                state       <= ST_ATTACK;
            end else if (releasing) begin
                if (gate_i) begin
                    releasing <= 1'b0;
                    state     <= ST_ATTACK;
                end else if ({1'b0, env_level_o} <= RELEASE_STEP_U) begin
                    env_level_o <= {ENV_W{1'b0}};
                    releasing   <= 1'b0;
                    state       <= ST_IDLE;
                end else begin
                    env_level_o <= env_level_o - RELEASE_STEP_U[ENV_W-1:0];
                end
            end else if (!gate_i && state != ST_IDLE) begin
                releasing <= 1'b1;
            end else begin
                case (state)
                    ST_IDLE: begin
                        env_level_o <= {ENV_W{1'b0}};
                        if (gate_i)
                            state <= ST_ATTACK;
                    end

                    ST_ATTACK: begin
                        if (env_level_o >= peak_level) begin
                            env_level_o <= peak_level;
                            state       <= ST_DECAY;
                        end else if ({1'b0, env_level_o} + ATTACK_STEP_U >= {1'b0, peak_level}) begin
                            env_level_o <= peak_level;
                            state       <= ST_DECAY;
                        end else begin
                            env_level_o <= env_level_o + ATTACK_STEP_U[ENV_W-1:0];
                        end
                    end

                    ST_DECAY: begin
                        if (env_level_o <= sustain_level) begin
                            env_level_o <= sustain_level;
                            state       <= ST_SUSTAIN;
                        end else if ({1'b0, env_level_o} <= {1'b0, sustain_level} + DECAY_STEP_U) begin
                            env_level_o <= sustain_level;
                            state       <= ST_SUSTAIN;
                        end else begin
                            env_level_o <= env_level_o - DECAY_STEP_U[ENV_W-1:0];
                        end
                    end

                    ST_SUSTAIN: begin
                        // Smooth a late velocity correction instead of jumping.
                        if (env_level_o < sustain_level) begin
                            if ({1'b0, env_level_o} + ATTACK_STEP_U >= {1'b0, sustain_level})
                                env_level_o <= sustain_level;
                            else
                                env_level_o <= env_level_o + ATTACK_STEP_U[ENV_W-1:0];
                        end else if (env_level_o > sustain_level) begin
                            if ({1'b0, env_level_o} <= {1'b0, sustain_level} + DECAY_STEP_U)
                                env_level_o <= sustain_level;
                            else
                                env_level_o <= env_level_o - DECAY_STEP_U[ENV_W-1:0];
                        end
                    end

                    default: begin
                        state       <= ST_IDLE;
                        releasing   <= 1'b0;
                        env_level_o <= {ENV_W{1'b0}};
                    end
                endcase
            end
        end
    end

endmodule
