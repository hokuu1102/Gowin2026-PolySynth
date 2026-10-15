// envelope_bank.v
// P5-1: ONE shared ADSR engine + a 32-cycle round-robin over the 32 voices.
//
// Contract kept (flat bus, voice i at bus[i*ENV_W +: ENV_W], voice 0 at the LSB)
// and every voice still advances by EXACTLY ONE ADSR step per sample_tick_i,
// so attack / decay / sustain / release evolve bit-identically to the 32
// independent `adsr` instances this module used to generate.
//
// What changed: the 32 voices are serviced one per clock over the 33 clocks
// that follow sample_tick_i instead of all in the tick clock itself.
//   * per-voice state lives in ROTATING shift registers (lvl_sr / st_sr /
//     rel_sr) whose head slice is always the voice being serviced, so the
//     round-robin needs NO 32:1 read mux and NO 32-way write decoder for the
//     state itself;
//   * the per-voice INPUTS are snapshotted on the tick (gate/velocity/timbre/
//     retrig), so a mid-round change of a note_manager output cannot leak into
//     a voice that has not been serviced yet -- exactly what the 32 parallel
//     `adsr` instances did (they all sampled those wires in the tick clock);
//   * the "velocity x timbre sustain ratio" multiply is a SINGLE DSP, fed one
//     clock AHEAD of the service cycle (look-ahead on the next voice) so the
//     multiply never sits inside the service path.  See the long note at
//     `adsr.v:110-136`: without that register this product is the PnR critical
//     path.
//
// CONTRACT CHANGE (visible to testbenches): env_level_o / env_active_o are
// fully updated only 33 clocks after sample_tick_i (voice 0 at +2, voice 31 at
// +33), instead of in the tick clock.  Any testbench that reads the bus
// immediately after a tick must let the round finish.  A testbench must also
// leave at least 34 clocks between two sample_tick_i pulses (the real design
// has CLK_PER_SAMPLE = 1024).
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
    output reg  [POLY_TARGET*ENV_W-1:0] env_level_o,
    output reg  [POLY_TARGET-1:0]       env_active_o
);

    localparam integer AW = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET);
    //  The round visits cnt = 0 .. POLY_TARGET (33 states for 32 voices):
    //  cnt == 0 has nothing to service, it only prefetches voice 0's product.
    localparam [AW:0] CNT_STOP = POLY_TARGET;

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

    // ═══════════════════════════════════════════════════════════════════════
    // ① Per-voice INPUT snapshot, taken in the tick clock.
    //    The 32 `adsr` instances sampled gate_i / velocity_i / timbre_i /
    //    retrig_reset_i on the sample_tick_i edge; the round-robin services
    //    voice v up to 32 clocks later, so the values must be frozen here or a
    //    mid-round note_manager write would be seen by some voices and not
    //    others.  384 FFs, no LUT (enable = sample_tick_i).
    // ═══════════════════════════════════════════════════════════════════════
    reg [POLY_TARGET-1:0]       gate_s_r;
    reg [POLY_TARGET*VEL_W-1:0] vel_s_r;
    reg [POLY_TARGET-1:0]       rr_s_r;
    reg [POLY_TARGET*2-1:0]     tim_s_r;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            gate_s_r <= {POLY_TARGET{1'b0}};
            vel_s_r  <= {(POLY_TARGET*VEL_W){1'b0}};
            rr_s_r   <= {POLY_TARGET{1'b0}};
            tim_s_r  <= {(POLY_TARGET*2){1'b0}};
        end else if (sample_tick_i) begin
            gate_s_r <= gate_i;
            vel_s_r  <= velocity_i;
            rr_s_r   <= retrig_reset_i;
            tim_s_r  <= timbre_i;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ② Rotating per-voice state.  Head slice = voice being serviced.
    // ═══════════════════════════════════════════════════════════════════════
    reg [POLY_TARGET*ENV_W-1:0] lvl_sr;
    reg [POLY_TARGET*2-1:0]     st_sr;
    reg [POLY_TARGET-1:0]       rel_sr;

    reg [AW:0] cnt;          // 0 .. POLY_TARGET
    reg        running;

    wire [ENV_W-1:0] lvl_c = lvl_sr[ENV_W-1:0];
    wire [1:0]       st_c  = st_sr[1:0];
    wire             rel_c = rel_sr[0];

    //  Service pointer = cnt-1 (the head of the shift registers); the prefetch
    //  pointer = cnt (one voice ahead).  At cnt == 0 nothing is serviced, so the
    //  wrapped "31" is never used.
    wire [AW-1:0] svc_i = cnt[AW-1:0] - 1'b1;
    wire [AW-1:0] pre_i = cnt[AW-1:0];

    // ═══════════════════════════════════════════════════════════════════════
    // ③ LOOK-AHEAD STAGE: everything the service cycle needs is read from the
    //    input snapshot with the NEXT index and registered here, one clock
    //    before that voice is serviced.
    //
    //    WHY (this is the PnR fix, not a nicety): with the mux + timbre decode
    //    + ADSR arithmetic all inside the service clock, the critical path was
    //      cnt -> 32:1 mux -> attack/decay/release case -> 16-bit add/compare
    //          -> lvl_n -> lvl_sr
    //    Measured: Actual Fmax 50.055 MHz, SETUP #1 slack 0.022 (a 6% Fmax
    //    regression against the pre-change 53.4 MHz build).  Registering the
    //    look-ahead values leaves only the arithmetic in the service path.
    //
    //    ALIGNMENT: at cnt = k this stage captures voice k; voice k is serviced
    //    at cnt = k+1, where the head of lvl_sr/st_sr/rel_sr is exactly voice k.
    //    Values are unchanged -- only the clock on which they are computed.
    //
    //    The multiply rides along in the same stage (see the width note below).
    // ═══════════════════════════════════════════════════════════════════════
    wire [VEL_W-1:0] vel_p    = vel_s_r[pre_i*VEL_W +: VEL_W];
    wire [1:0]       tim_p    = tim_s_r[pre_i*2 +: 2];
    wire [ENV_W-1:0] peak_p   = {vel_p, {(ENV_W-VEL_W){1'b0}}};
    wire [7:0]       sus_q8_p = sustain_for_timbre(tim_p);
    //  Width discipline: the product is formed through an explicitly WIDER wire.
    //  Writing `reg [23:0] x <= a * b;` silently overflows when the LHS is
    //  narrower than the true product, so the wide wire is mandatory style.
    //  peak <= 8'hFF << 8 = 65280 and sustain_q8 <= 230 => the true product
    //  needs 24 bits; this wire is 32 bits wide.
    wire [ENV_W+15:0] prod_p  = peak_p * sus_q8_p;

    reg              gate_r, rr_r;
    reg [ENV_W-1:0]  peak_r;
    reg [ENV_W:0]    atk_r, dec_r, rel_r;
    reg [ENV_W+7:0]  sustain_product_r;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            gate_r            <= 1'b0;
            rr_r              <= 1'b0;
            peak_r            <= {ENV_W{1'b0}};
            atk_r             <= {(ENV_W+1){1'b0}};
            dec_r             <= {(ENV_W+1){1'b0}};
            rel_r             <= {(ENV_W+1){1'b0}};
            sustain_product_r <= {(ENV_W+8){1'b0}};
        end else if (running) begin
            gate_r            <= gate_s_r[pre_i];
            rr_r              <= rr_s_r[pre_i];
            peak_r            <= peak_p;
            atk_r             <= attack_for_timbre(tim_p);
            dec_r             <= decay_for_timbre(tim_p);
            rel_r             <= release_for_timbre(tim_p);
            sustain_product_r <= prod_p[ENV_W+7:0];
        end
    end

    wire [ENV_W-1:0] sustain_level = sustain_product_r[ENV_W+7:8];

    // BG timing candidate: remove the sustain DSP output -> add -> compare
    // chain. The decay subtraction is independent of sustain_level, so both
    // operands of the final clamp comparison arrive in parallel. No register
    // or service-cycle alignment changes. Retain the original modular-add
    // semantics for unusually large/negative legacy DECAY_STEP parameters.
    wire [ENV_W:0] decay_difference = {1'b0, lvl_c} - dec_r;
    wire decay_hits_sustain =
        ((DECAY_STEP >= 0) && (DECAY_STEP < (64'd1 << ENV_W)))
        ? (decay_difference[ENV_W] ||
           (decay_difference[ENV_W-1:0] <= sustain_level))
        : ({1'b0, lvl_c} <= {1'b0, sustain_level} + dec_r);

    // ═══════════════════════════════════════════════════════════════════════
    // ④ Next state for the voice currently at the head (verbatim from adsr.v,
    //    same priority order: retrig_reset > releasing > gate low > state).
    //    All operands are the registered look-ahead values from ③.
    // ═══════════════════════════════════════════════════════════════════════

    reg [ENV_W-1:0] lvl_n;
    reg [1:0]       st_n;
    reg             rel_n;

    always @(*) begin
        lvl_n = lvl_c;
        st_n  = st_c;
        rel_n = rel_c;
        if (rr_r) begin
            lvl_n = {ENV_W{1'b0}};
            rel_n = 1'b0;
            st_n  = ST_ATTACK;
        end else if (rel_c) begin
            if (gate_r) begin
                rel_n = 1'b0;
                st_n  = ST_ATTACK;
            end else if ({1'b0, lvl_c} <= rel_r) begin
                lvl_n = {ENV_W{1'b0}};
                rel_n = 1'b0;
                st_n  = ST_IDLE;
            end else begin
                lvl_n = lvl_c - rel_r[ENV_W-1:0];
            end
        end else if (!gate_r && st_c != ST_IDLE) begin
            rel_n = 1'b1;
        end else begin
            case (st_c)
                ST_IDLE: begin
                    lvl_n = {ENV_W{1'b0}};
                    if (gate_r)
                        st_n = ST_ATTACK;
                end

                ST_ATTACK: begin
                    if (lvl_c >= peak_r) begin
                        lvl_n = peak_r;
                        st_n  = ST_DECAY;
                    end else if ({1'b0, lvl_c} + atk_r >= {1'b0, peak_r}) begin
                        lvl_n = peak_r;
                        st_n  = ST_DECAY;
                    end else begin
                        lvl_n = lvl_c + atk_r[ENV_W-1:0];
                    end
                end

                ST_DECAY: begin
                    if (lvl_c <= sustain_level) begin
                        lvl_n = sustain_level;
                        st_n  = ST_SUSTAIN;
                    end else if (decay_hits_sustain) begin
                        lvl_n = sustain_level;
                        st_n  = ST_SUSTAIN;
                    end else begin
                        lvl_n = lvl_c - dec_r[ENV_W-1:0];
                    end
                end

                ST_SUSTAIN: begin
                    // Smooth a late velocity correction instead of jumping.
                    if (lvl_c < sustain_level) begin
                        if ({1'b0, lvl_c} + atk_r >= {1'b0, sustain_level})
                            lvl_n = sustain_level;
                        else
                            lvl_n = lvl_c + atk_r[ENV_W-1:0];
                    end else if (lvl_c > sustain_level) begin
                        if (decay_hits_sustain)
                            lvl_n = sustain_level;
                        else
                            lvl_n = lvl_c - dec_r[ENV_W-1:0];
                    end
                end

                default: begin
                    st_n  = ST_IDLE;
                    rel_n = 1'b0;
                    lvl_n = {ENV_W{1'b0}};
                end
            endcase
        end
    end

    //  Same expression as adsr.v's `assign active_o`, but evaluated on the NEXT
    //  state so that env_level_o and env_active_o of a voice become visible in
    //  the same clock -- exactly like the per-voice instance did.
    wire act_n = (st_n != ST_IDLE) || rel_n || (lvl_n != {ENV_W{1'b0}});

    // ═══════════════════════════════════════════════════════════════════════
    // ⑤ Sequencer: exactly ONE update per voice per sample frame.
    //    cnt = 0 : prefetch voice 0 only.
    //    cnt = k : service voice k-1, prefetch voice k.
    //    cnt = POLY_TARGET : service the last voice, stop.
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            lvl_sr       <= {(POLY_TARGET*ENV_W){1'b0}};
            st_sr        <= {(POLY_TARGET*2){1'b0}};
            rel_sr       <= {POLY_TARGET{1'b0}};
            cnt          <= {(AW+1){1'b0}};
            running      <= 1'b0;
            env_level_o  <= {(POLY_TARGET*ENV_W){1'b0}};
            env_active_o <= {POLY_TARGET{1'b0}};
        end else if (sample_tick_i) begin
            cnt     <= {(AW+1){1'b0}};
            running <= 1'b1;
        end else if (running) begin
            if (cnt != {(AW+1){1'b0}}) begin
                lvl_sr <= {lvl_n, lvl_sr[POLY_TARGET*ENV_W-1:ENV_W]};
                st_sr  <= {st_n,  st_sr[POLY_TARGET*2-1:2]};
                rel_sr <= {rel_n, rel_sr[POLY_TARGET-1:1]};
                env_level_o[svc_i*ENV_W +: ENV_W] <= lvl_n;
                env_active_o[svc_i]                <= act_n;
            end
            if (cnt == CNT_STOP)
                running <= 1'b0;
            cnt <= cnt + 1'b1;
        end
    end

endmodule
