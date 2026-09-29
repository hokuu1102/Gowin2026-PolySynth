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
    // Timbre is latched per voice by note_manager.  It selects only the
    // existing ADSR recipe; retrigger reset remains the highest-priority
    // control so a release tail can never stack with a new attack.
    input  wire [1:0]           timbre_i,
    output reg  [ENV_W-1:0]     env_level_o,
    output wire                 active_o
);

    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_ATTACK  = 2'd1;
    localparam [1:0] ST_DECAY   = 2'd2;
    localparam [1:0] ST_SUSTAIN = 2'd3;

    // Four T31b recipes from files/20-代码/音色设计.md.  Unknown/unconnected
    // timbre inputs retain the historical parameterized behavior so existing
    // wrappers and focused legacy tests remain valid.
    function [ENV_W:0] attack_for_timbre;
        input [1:0] timbre;
        begin
            case (timbre)
                2'd0: attack_for_timbre = 17'd448; // BASS:   ~3 ms
                2'd1: attack_for_timbre = 17'd672; // GUITAR: ~2 ms
                2'd2: attack_for_timbre = 17'd672; // PIANO:  ~2 ms
                2'd3: attack_for_timbre = 17'd45;  // PAD:   ~30 ms
                default: attack_for_timbre = ATTACK_STEP;
            endcase
        end
    endfunction

    function [ENV_W:0] decay_for_timbre;
        input [1:0] timbre;
        begin
            case (timbre)
                2'd0: decay_for_timbre = 17'd2;
                2'd1: decay_for_timbre = 17'd2;
                2'd2: decay_for_timbre = 17'd1;
                2'd3: decay_for_timbre = 17'd1;
                default: decay_for_timbre = DECAY_STEP;
            endcase
        end
    endfunction

    function [7:0] sustain_for_timbre;
        input [1:0] timbre;
        begin
            case (timbre)
                2'd0: sustain_for_timbre = 8'd179; // BASS:   0.70
                2'd1: sustain_for_timbre = 8'd77;  // GUITAR: 0.30
                2'd2: sustain_for_timbre = 8'd102; // PIANO:  0.40
                2'd3: sustain_for_timbre = 8'd230; // PAD:    0.90
                default: sustain_for_timbre = SUSTAIN_Q8;
            endcase
        end
    endfunction

    function [ENV_W:0] release_for_timbre;
        input [1:0] timbre;
        begin
            case (timbre)
                2'd0: release_for_timbre = 17'd6;
                2'd1: release_for_timbre = 17'd1;
                2'd2: release_for_timbre = 17'd1;
                2'd3: release_for_timbre = 17'd1;
                default: release_for_timbre = RELEASE_STEP;
            endcase
        end
    endfunction

    wire [ENV_W:0] attack_step_u  = attack_for_timbre(timbre_i);
    wire [ENV_W:0] decay_step_u   = decay_for_timbre(timbre_i);
    wire [7:0]     sustain_q8_u   = sustain_for_timbre(timbre_i);
    wire [ENV_W:0] release_step_u = release_for_timbre(timbre_i);

    // Release is represented by a flag so all four named ADSR phases remain
    // visible while keeping the externally observable interface minimal.
    reg [1:0] state;
    reg       releasing;

    // Default 8-to-16 mapping is velocity << 8: monotonic, multiplier-free,
    // and leaves one byte of headroom at velocity 255.
    wire [ENV_W-1:0] peak_level = {velocity_i, {(ENV_W-VEL_W){1'b0}}};
    wire [ENV_W+7:0] sustain_product = peak_level * sustain_q8_u;
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
                end else if ({1'b0, env_level_o} <= release_step_u) begin
                    env_level_o <= {ENV_W{1'b0}};
                    releasing   <= 1'b0;
                    state       <= ST_IDLE;
                end else begin
                    env_level_o <= env_level_o - release_step_u[ENV_W-1:0];
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
                        end else if ({1'b0, env_level_o} + attack_step_u >= {1'b0, peak_level}) begin
                            env_level_o <= peak_level;
                            state       <= ST_DECAY;
                        end else begin
                            env_level_o <= env_level_o + attack_step_u[ENV_W-1:0];
                        end
                    end

                    ST_DECAY: begin
                        if (env_level_o <= sustain_level) begin
                            env_level_o <= sustain_level;
                            state       <= ST_SUSTAIN;
                        end else if ({1'b0, env_level_o} <= {1'b0, sustain_level} + decay_step_u) begin
                            env_level_o <= sustain_level;
                            state       <= ST_SUSTAIN;
                        end else begin
                            env_level_o <= env_level_o - decay_step_u[ENV_W-1:0];
                        end
                    end

                    ST_SUSTAIN: begin
                        // Smooth a late velocity correction instead of jumping.
                        if (env_level_o < sustain_level) begin
                            if ({1'b0, env_level_o} + attack_step_u >= {1'b0, sustain_level})
                                env_level_o <= sustain_level;
                            else
                                env_level_o <= env_level_o + attack_step_u[ENV_W-1:0];
                        end else if (env_level_o > sustain_level) begin
                            if ({1'b0, env_level_o} <= {1'b0, sustain_level} + decay_step_u)
                                env_level_o <= sustain_level;
                            else
                                env_level_o <= env_level_o - decay_step_u[ENV_W-1:0];
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
