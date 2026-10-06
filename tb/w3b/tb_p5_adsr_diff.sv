`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_p5_adsr_diff.sv  --  P5-1 acceptance gate 1: BIT-EXACT DIFF of the shared
//                         round-robin envelope_bank against the PRE-CHANGE
//                         32x ADSR bank.
//
// WHAT IS COMPARED
//   u_new = rtl/w3b/envelope_bank.v (shared engine, 32-cycle round-robin)
//   u_ref = the PRE-CHANGE rtl/w3b/envelope_bank.v + rtl/w3b/adsr.v, embedded
//           verbatim at the bottom of this file as `ref_envelope_bank` /
//           `ref_adsr` (byte copies with only the module names changed).
//           source : sim/evidence/p5-adsr-20261003/envelope_bank.v.PRE-P5ADSR
//                    sha256 07B1D4EE1E01228090A2D14C8E9A583C8AA4B8610002DAE78BDC0D8329CB1410
//                    sim/evidence/p5-adsr-20261003/adsr.v.PRE-P5ADSR
//                    sha256 9469E3111C662459D41E24B878D208795B16A1698FB0AC7DAAB929E2AE1E2199
//
//   !! NEXT TIME THIS FILE IS TOUCHED, REFRESH THE REFERENCE COPIES !!
//   The embedded reference is a frozen snapshot of the behaviour that was
//   delivered BEFORE the shared engine.  If envelope_bank.v is changed again,
//   the reference must be re-cut from the new pre-change file, otherwise this
//   testbench silently starts comparing two versions of the NEW code.
//
// HOW IT IS COMPARED (per clock, not just per frame)
//   The reference updates all 32 voices in the sample_tick clock.  The shared
//   engine services voice v during the cycle that ends at posedge P(2+v), so
//   voice v carries its new value from cycle (3+v) on.  Therefore, at cycle c
//   of the frame:
//        voice v must equal  new_value[v]   if c >= 3+v
//        voice v must equal  old_value[v]   otherwise
//   Every voice is checked in EVERY cycle (36 cycles x 32 voices per frame),
//   which pins down both the value and the round-robin schedule.
//
//   The stimulus deliberately perturbs gate / velocity / timbre / retrig at
//   pseudo-random cycles INSIDE the frame, i.e. while the round is running.
//   A shared engine that sampled its inputs live during the round (instead of
//   snapshotting them on the tick) would fail this testbench.
// ---------------------------------------------------------------------------
`default_nettype none

module tb_p5_adsr_diff;

    localparam integer POLY   = 32;
    localparam integer VEL_W  = 8;
    localparam integer ENV_W  = 16;
    localparam integer FRAMES = 3000;      // ~108k clocks, a few seconds of CPU
    localparam integer CYCLES = 36;        // 33-cycle round + margin

    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst_n = 1'b0;

    reg                      sample_tick = 1'b0;
    reg  [POLY-1:0]          gate        = {POLY{1'b0}};
    reg  [POLY*VEL_W-1:0]    velocity    = {(POLY*VEL_W){1'b0}};
    reg  [POLY-1:0]          retrig      = {POLY{1'b0}};
    reg  [POLY*2-1:0]        timbre      = {(POLY*2){1'b0}};

    wire [POLY*ENV_W-1:0] new_lvl, ref_lvl;
    wire [POLY-1:0]       new_act, ref_act;

    envelope_bank #(.POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W)) u_new (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (gate),
        .velocity_i    (velocity),
        .retrig_reset_i(retrig),
        .timbre_i      (timbre),
        .env_level_o   (new_lvl),
        .env_active_o  (new_act)
    );

    ref_envelope_bank #(.POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W)) u_ref (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (gate),
        .velocity_i    (velocity),
        .retrig_reset_i(retrig),
        .timbre_i      (timbre),
        .env_level_o   (ref_lvl),
        .env_active_o  (ref_act)
    );

    integer errors      = 0;
    integer frames      = 0;
    integer cycle_cmps  = 0;
    integer frame_cmps  = 0;

    reg [POLY*ENV_W-1:0] snap_old, snap_new;
    reg [POLY-1:0]       snap_old_act, snap_new_act;
    reg [POLY*ENV_W-1:0] expect_lvl;
    reg [POLY-1:0]       expect_act;

    integer f, c, v, bad;
    reg [31:0] lfsr = 32'hC0FF_EE01;
    reg [31:0] rv;

    task rnd;
        begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            rv   = lfsr;
        end
    endtask

    //  Scratch values used while perturbing the inputs mid-round.
    reg [POLY-1:0]       g_tmp;
    reg [POLY*VEL_W-1:0] vel_tmp;
    reg [POLY*2-1:0]     tim_tmp;
    reg [POLY-1:0]       rr_tmp;

    task perturb;
        integer q;
        begin
            rnd; g_tmp = rv[POLY-1:0];
            for (q = 0; q < POLY; q = q + 1) begin
                rnd;
                vel_tmp[q*VEL_W +: VEL_W] = rv[VEL_W-1:0];
                tim_tmp[q*2 +: 2]         = rv[7:6];
            end
            rnd; rr_tmp = rv[POLY-1:0] & rv[15:0];
            gate     = g_tmp;
            velocity = vel_tmp;
            timbre   = tim_tmp;
            retrig   = rr_tmp;
        end
    endtask

    //  One frame: assert sample_tick for exactly one clock, then walk the whole
    //  round cycle by cycle and compare every voice against the reference.
    task run_frame;
        begin
            @(negedge clk);
            snap_old     = ref_lvl;            // reference value before the tick
            snap_old_act = ref_act;
            sample_tick  = 1'b1;
            @(negedge clk);                    // one posedge (the tick) has passed
            sample_tick  = 1'b0;
            snap_new     = ref_lvl;            // reference value after the tick
            snap_new_act = ref_act;

            for (c = 1; c <= CYCLES; c = c + 1) begin
                expect_lvl = {POLY*ENV_W{1'b0}};
                expect_act = {POLY{1'b0}};
                for (v = 0; v < POLY; v = v + 1) begin
                    if (c >= 3 + v) begin
                        expect_lvl[v*ENV_W +: ENV_W] = snap_new[v*ENV_W +: ENV_W];
                        expect_act[v]                = snap_new_act[v];
                    end else begin
                        expect_lvl[v*ENV_W +: ENV_W] = snap_old[v*ENV_W +: ENV_W];
                        expect_act[v]                = snap_old_act[v];
                    end
                end
                cycle_cmps = cycle_cmps + 1;
                if (new_lvl !== expect_lvl || new_act !== expect_act) begin
                    errors = errors + 1;
                    if (errors <= 8) begin
                        $display("FAIL frame %0d cycle %0d: bus mismatch", frames, c);
                        for (v = 0; v < POLY; v = v + 1)
                            if ((new_lvl[v*ENV_W +: ENV_W] !== expect_lvl[v*ENV_W +: ENV_W]) ||
                                (new_act[v] !== expect_act[v]))
                                $display("   voice %0d: got %0d/%b expected %0d/%b",
                                         v, new_lvl[v*ENV_W +: ENV_W], new_act[v],
                                         expect_lvl[v*ENV_W +: ENV_W], expect_act[v]);
                    end
                end
                @(negedge clk);
            end

            //  End of the round: the whole bus must equal the reference exactly.
            frame_cmps = frame_cmps + 1;
            if (new_lvl !== snap_new || new_act !== snap_new_act) begin
                errors = errors + 1;
                if (errors <= 8) begin
                    bad = 0;
                    for (v = 0; v < POLY; v = v + 1)
                        if ((new_lvl[v*ENV_W +: ENV_W] !== snap_new[v*ENV_W +: ENV_W]) ||
                            (new_act[v] !== snap_new_act[v])) bad = bad + 1;
                    $display("FAIL frame %0d: end-of-round bus mismatch on %0d voice(s)",
                             frames, bad);
                end
            end

            //  Mid-round perturbation for the churn phases.
            if (frames >= 250) begin
                rnd;
                if (rv[2:0] == 3'd0) perturb;
            end
            frames = frames + 1;
        end
    endtask

    integer q;
    initial begin
        sample_tick = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // ---- phase A: idle, all gates low --------------------------------
        gate = {POLY{1'b0}};
        for (f = 0; f < 50; f = f + 1) run_frame;

        // ---- phase B: every voice gated on, distinct velocities ----------
        gate = {POLY{1'b1}};
        for (q = 0; q < POLY; q = q + 1) begin
            velocity[q*VEL_W +: VEL_W] = 8'd16 + q * 7;
            timbre[q*2 +: 2]           = q[1:0];
        end
        for (f = 0; f < 200; f = f + 1) run_frame;

        // ---- phase C: deterministic churn --------------------------------
        for (f = 0; f < 750; f = f + 1) begin
            rnd; gate = rv[POLY-1:0];
            for (q = 0; q < POLY; q = q + 1) begin
                rnd;
                velocity[q*VEL_W +: VEL_W] = rv[VEL_W-1:0];
                timbre[q*2 +: 2]           = rv[7:6];
            end
            rnd; retrig = (f % 17 == 0) ? rv[POLY-1:0] : {POLY{1'b0}};
            run_frame;
        end

        // ---- phase D: churn + mid-round perturbations --------------------
        for (f = 0; f < (FRAMES - 1000); f = f + 1) begin
            rnd; gate = rv[POLY-1:0];
            for (q = 0; q < POLY; q = q + 1) begin
                rnd;
                velocity[q*VEL_W +: VEL_W] = rv[VEL_W-1:0];
                timbre[q*2 +: 2]           = rv[7:6];
            end
            rnd; retrig = (f % 13 == 0) ? rv[POLY-1:0] : {POLY{1'b0}};
            run_frame;
        end

        $display("--------------------------------------------------------------");
        $display("frames compared      = %0d", frame_cmps);
        $display("per-cycle bus checks = %0d  (each check covers 32 voices x 16 level bits + 32 active bits)",
                 cycle_cmps);
        $display("voice-observations   = %0d", cycle_cmps * POLY);
        $display("mismatches           = %0d", errors);
        if (errors == 0)
            $display("PASS: shared round-robin envelope_bank is bit-exact vs the 32x ADSR bank");
        else
            $display("FAIL: shared envelope_bank diverges in %0d place(s)", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_p5_adsr_diff timeout");
    end

endmodule

`default_nettype wire

// envelope_bank.v
// Per-voice ADSR bank. Every generated instance owns independent state.
// Flat-bus contract: voice i occupies bus[i*W +: W], voice 0 at the LSB.
`timescale 1ns/1ps

module ref_envelope_bank #(
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
            ref_adsr #(
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
`timescale 1ns/1ps

// One voice's independent envelope state.
// All state changes occur on sample_tick_i in the 50 MHz clock domain.
// velocity_i maps linearly to the attack peak; SUSTAIN_Q8 is a Q0.8 ratio.
module ref_adsr #(
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
    //  ⭐⭐ 2026-09-30：⭐ **"力度 × 音色持续比"这一级的乘法【打一拍】**（⭐ 收敛时序）
    //
    //  🔴 **问题（⭐ PnR 实测原文，⛔ 不是推测）** ——
    //     `impl/pnr/Gowin2026_tr_content.html` 的最差 25 条 setup 路径里
    //     **24 条**都是 `…/u_adsr/sustain_product_0_s → …/env_level_o_*_s0/D`：
    //        · 最差那条 `From g_sound.tm_n_code_r_0_s1/Q
    //                     To   …/g_voice_envelope[6].u_adsr/env_level_o_0_s0/D`
    //          `Path Slack = 0.131`、`Data Delay = 19.823`（⭐ 周期 20 ns）
    //        · `Actual Fmax = 50.329 MHz`、`Logic Level = 15`
    //     ⚠️ 这一级是 **7863b40** 与 looper 插值**同一批**引进来的
    //        （⭐ `timbre_i` + `sustain_for_timbre`）⇒ ⭐ **是本次时序回归的第二个来源** ✅
    //
    //  ⭐ **拆解**（⭐ `impl/pnr/Gowin2026.timing_paths` 的节点到达时间）：
    //     · ⭐ 源 → DSP 输出 `sustain_product`：`3.571 → 13.802` = **10.23 ns**
    //       （⭐ 其中 `timbre_i` 从 `top.v` 送到 **32 个 ADSR** 的布线占大头）
    //     · ⭐ DSP 输出 → `env_level_o`：`13.802 → 23.394` = **9.59 ns**
    //     ⇒ ⭐ **两段各自都 < 20 ns**，⭐ 是**串在一拍里**才超的 ✅
    //
    //  ⭐ **语义为什么不变**：⭐ `sustain_level` 只在 `sample_tick_i`
    //     （⭐ 每 `CLK_PER_SAMPLE` = 1024 拍一次）被读；⭐ 而 `velocity_i` / `timbre_i`
    //     由 `note_manager` **按 voice 锁存**、⭐ 在整条音符期间不变
    //     ⇒ ⭐ 打一拍**不影响任何可观测结果**（⭐ 起音/衰减走到持续音要几十个 tick）✅
    //  📌 写成"**寄存的乘法**"⇒ ⭐ 综合器会用 **DSP 自带的输出寄存器**，
    //     ⭐ 不额外吃 CLS（⭐ 本工程 CLS 已 83%，⭐ 这一步很关键）✅
    reg [ENV_W+7:0] sustain_product_r;
    always @(posedge clk_i) sustain_product_r <= peak_level * sustain_q8_u;
    wire [ENV_W-1:0] sustain_level = sustain_product_r[ENV_W+7:8];

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
