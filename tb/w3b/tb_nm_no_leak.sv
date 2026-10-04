// ===========================================================================
// tb_nm_no_leak.sv -- guard: same-axis repeated press/release must NOT leak a
//                    voice (the "stuck note / pool leak" symptom)
//
// WHY THIS TESTBENCH EXISTS
//   Board symptom, reproducible on two power-ups:
//     1) the power-on self-test chord sounds fine;
//     2) the FIRST key press is fine;
//     3) after a few more presses (especially the SAME key again and again) it
//        goes wrong: a stuck note plus a backlog of events, so each press only
//        releases one queued note and the pitch lags the keys.
//
//   HEAD HYPOTHESIS UNDER TEST (note_manager.v, added by the timing fix)
//     ST_RETRIG writes with the index latched one clock earlier (same_idx_r),
//     while the signal that produced that index can change in between:
//         same_hit[sg] = (gate_r[sg] | retrig_low[sg] | env_active_r[sg])
//                        && (axis_r[sg] == cur_axis) && (src_r[sg] == cur_src);
//     If the write lands on a voice that no longer matches, that voice is left
//     with gate_r=0 but retrig_low=1 => live_mask=1 => never free again => the
//     pool leaks => once the pool is empty the allocator can only steal =>
//     the event backlog.
//
//   COUNTER-EVIDENCE THAT MUST BE DISTINGUISHED
//     Another analysis argues the (index, value) pair is bit-identical to the
//     pre-fix version and that cand_ok does not depend on env, so no event can
//     be lost.  This testbench is built so it CAN fail if the leak is real, and
//     so its criteria can be shown non-vacuous by mutation (see the report).
//
//   CODE FACTS CONFIRMED BY READING rtl/w3b/note_manager.v (needed to aim the
//   sweep -- these are read, not assumed):
//     * (f) clears retrig_low[i] UNCONDITIONALLY on every sample_tick_i
//       (note_manager.v:935-938 sets gate_r[i]<=1 and retrig_low[i]<=0), so a
//       retrigger hold can last at most one sample period.  A *permanent* leak
//       therefore cannot come from retrig_low alone.
//     * axis_r / src_r are written only by reset, ST_RETRIG and ST_COMMIT2, and
//       only one of those states is active per clock -- so between ST_DECIDE
//       (cycle N) and ST_RETRIG (cycle N+1) the axis/src of every voice are
//       frozen.  The stale index therefore still points at a voice whose
//       axis/src MATCH cur_axis/cur_src.
//     * the only input of same_hit that can change in that one clock is
//       env_active_r (a 1-clock copy of env_active_i, note_manager.v:288-296),
//       and env_active_i only moves on a sample_tick.  So the one clock that
//       can expose the stale index is the clock right after the release ends.
//       Section D is aimed exactly at it (kr sweeps across the 16-tick release,
//       off sweeps the clock phase inside the 16-clock frame).
//
// WHAT IS ASSERTED (all criterion names are ASCII: vvp mangles non-ASCII)
//   A  baseline: the pool is completely free after reset.
//   B  ROUNDS x (press -> sustain -> release -> FAST re-press inside the
//      release tail -> release -> drain): the free count must be back to POLY
//      after EVERY round, and retrig_low must be all-zero.
//   C  one fast re-press checked in detail: exactly one gated voice, exactly
//      one live voice on the pressed axis, free == POLY-1, retrig_low == 0,
//      and NO foreign voice was ever retriggered.
//   D  the same criteria swept over the phase of the re-press relative to
//      sample_tick, in two pool layouts:
//        D1  the witness voice is NOT index 0 and voice 0 is held on another
//            axis -- a stale index that falls back to 0 shows up as a FOREIGN
//            retrigger.
//        D2  voice 0 is FREE with a stale axis while the witness voice still
//            has a release tail -- if a stale index falls back to 0, voice 0
//            is brought back up on the OLD axis and no key in use can release
//            it => a permanent stuck note (exactly the board symptom).
//   E  the same module at POLY_TARGET=32 still compiles and behaves.
//   F  the event queue never overflowed during the whole run (no silent drop).
//
// WHAT THIS BENCH DOES *NOT* DO
//   It does not run on hardware and it does not model the top-level scanner.
//   If the criteria stay green here, that only means the leak cannot be
//   produced at UNIT level with these event timings (see the report).
//
// DISCIPLINE
//   - read only: nothing under rtl/ or constr/ is touched.
//   - every wait is bounded (no silent hang; K-106 family).
//   - no $dumpfile: the evidence is the printed per-round free count.
// ===========================================================================
`timescale 1ns/1ps

module tb_nm_no_leak;

    // ------------------------------------------------------------- geometry --
    localparam integer POLY       = 4;    // small pool: easy to exhaust
    localparam integer AXIS_W     = 4;
    localparam integer PHASE_W    = 32;
    localparam integer VEL_W      = 8;
    localparam integer TIMBRE_W   = 2;
    localparam integer ENV_W      = 16;
    localparam integer AGE_W      = 16;
    localparam integer IDX_W      = 2;    // clog2(POLY)
    localparam integer FRAME      = 40;   // clk per sample_tick (DUT A/B share it)
                                          //   ⭐ P5-1（2026-10-03）：⭐ 16 → **40**。
                                          //   ⭐ 为什么：`envelope_bank` 改成**共享引擎 +
                                          //      32 拍轮转**（⭐ 见其文件头）⇒ ⭐ 每帧必须
                                          //      留出 **≥34 拍**让 32 路全部更新完，
                                          //      ⛔ 否则第 15 路之后**永远不更新**
                                          //      ⇒ ⭐ E3「快速重按不泄漏」会红（⭐ 实测确实红）。
                                          //   ⭐ 分配 FSM 只要 POLY+4 = 8 拍 ⇒ 40 拍绰绰有余 ✅
                                          //   📌 副作用：⭐ 本 tb 的仿真时间 ×2.5（⭐ 可接受）
    localparam integer ROUNDS     = 40;   // same-axis press/release rounds
    localparam integer DRAIN_MAX  = 400;  // bounded wait, in sample ticks

    // witness / filler axes.  The witness must NOT be voice index 0 for the
    // stale-index mutations to be observable, so voices 0/1 are occupied first.
    localparam [AXIS_W-1:0]  AXX  = 4'd3;  // axis under test (witness voice)
    localparam [AXIS_W-1:0]  AXH1 = 4'd1;  // filler -> voice 0
    localparam [AXIS_W-1:0]  AXH2 = 4'd2;  // filler -> voice 1
    localparam [VEL_W-1:0]   VEL  = 8'd100;
    localparam [PHASE_W-1:0] INC0 = 32'h0010_0000;
    localparam [PHASE_W-1:0] INC1 = 32'h0033_0000;

    // Envelope recipe (DUT A/B).  These parameters are only effective because
    // envelope_bank.timbre_i is tied to z below: a 2-bit timbre would select
    // the fixed timbre table and ignore them (see adsr.v attack_for_timbre).
    //   peak = 100<<8 = 25600; attack 25600/3200 = 8 ticks; decay to
    //   sustain 6400 takes 6 ticks; release 6400/400 = 16 ticks.
    localparam integer A_STEP = 3200;
    localparam integer D_STEP = 3200;
    localparam integer S_Q8   = 64;
    localparam integer R_STEP = 400;

    // ------------------------------------------------------------- clock/tick
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;

    // Free-running sample tick: one clk high every FRAME clocks.  It MUST be
    // free running (not driven by the stimulus tasks) or the phase of an event
    // relative to sample_tick cannot be swept -- and that phase is the whole
    // point of section D.
    reg sample_tick = 1'b0;
    integer tick_cnt = 0;
    always @(negedge clk) begin
        if (tick_cnt == FRAME-1) begin tick_cnt <= 0; sample_tick <= 1'b1; end
        else                     begin tick_cnt <= tick_cnt + 1; sample_tick <= 1'b0; end
    end

    // ------------------------------------------------------- DUT A (POLY=4) --
    reg                note_valid;
    reg  [AXIS_W-1:0]  note_axis;
    reg  [PHASE_W-1:0] note_phase_inc;
    reg  [VEL_W-1:0]   note_velocity;
    reg  [1:0]         note_kind;
    reg  [2:0]         note_src;

    wire [POLY-1:0]          voice_gate;
    wire [POLY-1:0]          voice_active;
    wire [POLY-1:0]          voice_releasing;
    wire [POLY*AXIS_W-1:0]   voice_axis;
    wire [POLY*PHASE_W-1:0]  voice_phase_inc;
    wire [POLY*VEL_W-1:0]    voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY-1:0]          voice_drum;
    wire [POLY*AGE_W-1:0]    voice_age;
    wire [POLY-1:0]          voice_retrig_reset;
    wire                     alloc_valid;
    wire [IDX_W-1:0]         alloc_voice;
    wire                     event_lost;
    wire [7:0]               event_lost_cnt;

    wire [POLY-1:0]        env_active;
    wire [POLY*ENV_W-1:0]  env_level;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind), .note_src_i(note_src),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}), .vel_upd_src_i(3'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}), .pitch_upd_src_i(3'd0),
        .default_timbre_i({TIMBRE_W{1'b0}}), .evt_timbre_valid_i(1'b0),
        .evt_timbre_i({TIMBRE_W{1'b0}}),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_drum_o(voice_drum),
        .voice_age_o(voice_age), .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        .event_lost_o(event_lost), .event_lost_cnt_o(event_lost_cnt),
        .event_lost_clr_i(1'b0)
    );

    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(A_STEP), .DECAY_STEP(D_STEP),
        .SUSTAIN_Q8(S_Q8), .RELEASE_STEP(R_STEP)
    ) u_env_a (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        // z => the ADSR keeps the parameterized recipe above instead of the
        // fixed per-timbre table (same trick the existing tb gets implicitly).
        .timbre_i({(POLY*2){1'bz}}),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ------------------------------------------------------ DUT B (POLY=32) --
    localparam integer POLY_B = 32;
    localparam integer IDX_B  = 5;

    reg                b_valid;
    reg  [AXIS_W-1:0]  b_axis;
    reg  [1:0]         b_kind;
    wire [POLY_B-1:0]  b_gate;
    wire [POLY_B-1:0]  b_active;
    wire [POLY_B-1:0]  b_retrig_rst;
    wire [POLY_B*AXIS_W-1:0] b_axis_bus;
    wire [POLY_B*VEL_W-1:0] b_vel;
    wire               b_alloc_valid;
    wire [IDX_B-1:0]   b_alloc_voice;
    wire [POLY_B-1:0]  b_env_active;
    wire [POLY_B*ENV_W-1:0] b_env_level;

    note_manager #(
        .POLY_TARGET(POLY_B), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_B)
    ) dut_b (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(b_valid), .note_axis_i(b_axis),
        .note_phase_inc_i(INC0), .note_velocity_i(VEL),
        .note_kind_i(b_kind), .note_src_i(3'd0),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}), .vel_upd_src_i(3'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}), .pitch_upd_src_i(3'd0),
        .default_timbre_i({TIMBRE_W{1'b0}}), .evt_timbre_valid_i(1'b0),
        .evt_timbre_i({TIMBRE_W{1'b0}}),
        .env_active_i(b_env_active), .env_level_i(b_env_level),
        .voice_gate_o(b_gate), .voice_active_o(b_active),
        .voice_releasing_o(), .voice_axis_o(b_axis_bus), .voice_phase_inc_o(),
        .voice_velocity_o(b_vel), .voice_timbre_o(), .voice_drum_o(),
        .voice_age_o(), .voice_retrig_reset_o(b_retrig_rst),
        .alloc_valid_o(b_alloc_valid), .alloc_voice_o(b_alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    envelope_bank #(
        .POLY_TARGET(POLY_B), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(A_STEP), .DECAY_STEP(D_STEP),
        .SUSTAIN_Q8(S_Q8), .RELEASE_STEP(R_STEP)
    ) u_env_b (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(b_gate), .velocity_i(b_vel),
        .retrig_reset_i(b_retrig_rst),
        .timbre_i({(POLY_B*2){1'bz}}),
        .env_level_o(b_env_level), .env_active_o(b_env_active)
    );

    // ------------------------------------------------------------ bookkeeping
    integer errors   = 0;
    integer r, kr, off;
    integer iters_d1, iters_d2;
    integer foreign_d1, leak_d1, axis_d1, live_d1, retrig_d1;
    integer foreign_d2, leak_d2, axis_d2, live_d2, retrig_d2;
    integer leak_rounds;
    integer drain_timeouts = 0;
    integer fr, lv, rg, gc;
    // non-vacuity counters: they prove the criteria really exercised the paths
    // they claim to guard (C83: a probe that never reaches its target is green
    // for the wrong reason).
    integer retrig_seen   = 0;   // re-presses that really entered the retrigger hold
    integer d1_setup_bad  = 0;   // D1 iterations where the witness was voice 0
    integer d2_setup_bad  = 0;   // D2 iterations where voice 0 was not free

    task chk;
        input [8*96-1:0] name;
        input            cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ---- observations ------------------------------------------------------
    // "live" is exactly the RTL definition (note_manager.v:419)
    //     live_mask = gate_r | hold_mask(=retrig_low) | env_active_r
    // and note_manager.v:1219 exports it as voice_active_o, so the PRIMARY
    // reading is the port (no hierarchical access needed).  live_terms_cnt
    // rebuilds the same quantity from the three terms instead -- the same
    // fallback the task allows -- and A3 checks the two agree.  Note that
    //     gate_r | retrig_low  ==  gate_mask | retrig_low
    // because gate_mask = gate_r & ~retrig_low, so the exported gate port can
    // stand in for gate_r here.
    function integer live_cnt;
        integer j;
        begin
            live_cnt = 0;
            for (j = 0; j < POLY; j = j + 1) if (voice_active[j]) live_cnt = live_cnt + 1;
        end
    endfunction

    function integer live_terms_cnt;
        integer j;
        begin
            live_terms_cnt = 0;
            for (j = 0; j < POLY; j = j + 1)
                if (voice_gate[j] || dut.retrig_low[j] || dut.env_active_r[j])
                    live_terms_cnt = live_terms_cnt + 1;
        end
    endfunction

    function integer free_cnt;
        integer j;
        begin
            free_cnt = 0;
            for (j = 0; j < POLY; j = j + 1) if (!voice_active[j]) free_cnt = free_cnt + 1;
        end
    endfunction

    function integer free_mask_cnt;
        integer j;
        begin
            free_mask_cnt = 0;
            for (j = 0; j < POLY; j = j + 1) if (dut.free_mask[j]) free_mask_cnt = free_mask_cnt + 1;
        end
    endfunction

    function integer gate_cnt;
        integer j;
        begin
            gate_cnt = 0;
            for (j = 0; j < POLY; j = j + 1) if (voice_gate[j]) gate_cnt = gate_cnt + 1;
        end
    endfunction

    function integer retrig_cnt;
        integer j;
        begin
            retrig_cnt = 0;
            for (j = 0; j < POLY; j = j + 1) if (dut.retrig_low[j]) retrig_cnt = retrig_cnt + 1;
        end
    endfunction

    // axis ownership is read from the exported bus (voice_axis_o), not from the
    // internal unpacked axis_r array, so this needs no hierarchical access.
    function [AXIS_W-1:0] axis_of;
        input integer v;
        begin axis_of = voice_axis[v*AXIS_W +: AXIS_W]; end
    endfunction

    function integer axis_live_cnt;
        input [AXIS_W-1:0] ax;
        integer j;
        begin
            axis_live_cnt = 0;
            for (j = 0; j < POLY; j = j + 1)
                if (voice_active[j] && (axis_of(j) == ax))
                    axis_live_cnt = axis_live_cnt + 1;
        end
    endfunction

    function [AXIS_W-1:0] b_axis_of;
        input integer v;
        begin b_axis_of = b_axis_bus[v*AXIS_W +: AXIS_W]; end
    endfunction

    function integer b_free;
        integer j;
        begin
            b_free = 0;
            for (j = 0; j < POLY_B; j = j + 1) if (!b_active[j]) b_free = b_free + 1;
        end
    endfunction

    function integer b_retrig;
        integer j;
        begin
            b_retrig = 0;
            for (j = 0; j < POLY_B; j = j + 1) if (dut_b.retrig_low[j]) b_retrig = b_retrig + 1;
        end
    endfunction

    function integer b_axis_live;
        input [AXIS_W-1:0] ax;
        integer j;
        begin
            b_axis_live = 0;
            for (j = 0; j < POLY_B; j = j + 1)
                if (b_active[j] && (b_axis_of(j) == ax))
                    b_axis_live = b_axis_live + 1;
        end
    endfunction

    // ---- foreign-retrigger monitor ----------------------------------------
    // Armed only around a re-press.  It fires if ANY voice whose axis is not
    // the pressed axis is ever pushed into the retrigger hold -- that is the
    // direct signature of the stale-index write (and it needs no leak to
    // happen in order to be visible).
    reg              mon_armed = 1'b0;
    reg              mon_bad   = 1'b0;
    reg              mon_seen  = 1'b0;   // the retrigger hold was observed at all
    reg [AXIS_W-1:0] mon_axis  = {AXIS_W{1'b0}};
    integer          mi;
    always @(negedge clk) begin
        if (mon_armed) begin
            for (mi = 0; mi < POLY; mi = mi + 1) begin
                if (dut.retrig_low[mi]) begin
                    mon_seen <= 1'b1;
                    if (axis_of(mi) !== mon_axis) mon_bad <= 1'b1;
                end
            end
        end
    end

    // ---- stimulus helpers -------------------------------------------------
    task run_clks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin @(negedge clk); #1; end
        end
    endtask

    // Land on a fixed phase: the negedge right after the posedge that consumed
    // a sample_tick.  Repeating it advances exactly one sample frame, so every
    // sequence built out of it is tick-quantized and reproducible.
    task sync_frame;
        begin
            @(negedge clk); #1;
            while (sample_tick !== 1'b1) begin @(negedge clk); #1; end
            @(negedge clk); #1;
        end
    endtask

    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) sync_frame;
        end
    endtask

    // one-clk note event, issued at a fixed phase, then one frame of settling
    // (the allocation FSM needs POLY+4 = 8 clk, well inside FRAME = 16).
    task pulse_note;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vel;
        input [1:0]         kind;
        begin
            sync_frame;
            @(negedge clk);
            note_valid     = 1'b1;
            note_axis      = ax;
            note_phase_inc = inc;
            note_velocity  = vel;
            note_kind      = kind;
            note_src       = 3'd0;
            @(negedge clk);
            note_valid     = 1'b0;
            run_ticks(1);
        end
    endtask

    task press_a;  input [AXIS_W-1:0] ax; begin pulse_note(ax, INC0, VEL, 2'd0); end endtask
    task repress_a;input [AXIS_W-1:0] ax; begin pulse_note(ax, INC1, VEL, 2'd0); end endtask
    task off_a;    input [AXIS_W-1:0] ax; begin pulse_note(ax, {PHASE_W{1'b0}}, {VEL_W{1'b0}}, 2'd1); end endtask

    // note_off on every axis (bounded, tick-quantized)
    task off_all;
        integer d;
        reg [AXIS_W-1:0] ax;
        begin
            for (d = 0; d < 16; d = d + 1) begin
                ax = d;
                off_a(ax);
            end
        end
    endtask

    // bounded wait until no voice is live; a timeout is itself a failure and is
    // reported (a leaked voice never becomes free, so this is where a leak of
    // the "retrig_low never clears" kind shows up).
    task wait_free;
        integer d;
        begin
            d = 0;
            while ((live_cnt() != 0) && (d < DRAIN_MAX)) begin
                run_ticks(1);
                d = d + 1;
            end
            if (live_cnt() != 0) begin
                drain_timeouts = drain_timeouts + 1;
                if (drain_timeouts <= 4)
                    $display("  INFO: wait_free timed out (%0d ticks): live=%0d free=%0d retrig=%0d",
                             d, live_cnt(), free_cnt(), retrig_cnt());
            end
        end
    endtask

    task clean_slate;
        begin
            off_all();
            wait_free();
        end
    endtask

    // ---- DUT B helpers (its FSM needs POLY_B+4 = 36 clk per event) ---------
    task b_event;
        input [AXIS_W-1:0] ax;
        input [1:0]        kind;
        begin
            sync_frame;
            @(negedge clk);
            b_valid = 1'b1; b_axis = ax; b_kind = kind;
            @(negedge clk);
            b_valid = 1'b0;
            run_ticks(4);          // 64 clk > 36 clk scan
        end
    endtask

    task b_wait_free;
        integer d;
        begin
            d = 0;
            while ((b_free() != POLY_B) && (d < DRAIN_MAX)) begin
                run_ticks(1);
                d = d + 1;
            end
        end
    endtask

    // =======================================================================
    initial begin
        note_valid     = 1'b0;
        note_axis      = {AXIS_W{1'b0}};
        note_phase_inc = {PHASE_W{1'b0}};
        note_velocity  = {VEL_W{1'b0}};
        note_kind      = 2'd0;
        note_src       = 3'd0;
        b_valid        = 1'b0;
        b_axis         = {AXIS_W{1'b0}};
        b_kind         = 2'd0;

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);
        sync_frame;

        $display("== tb_nm_no_leak: POLY=%0d AXIS_W=%0d FRAME=%0d ROUNDS=%0d ==",
                 POLY, AXIS_W, FRAME, ROUNDS);

        // ===================================================================
        // A - baseline
        // ===================================================================
        $display("-- A: baseline --");
        chk("A1 reset: no live voice", live_cnt() == 0);
        chk("A2 reset: free count == POLY (pool full)", free_cnt() == POLY);
        chk("A3 reset: live == the gate_r|retrig_low|env_active_r definition",
            live_terms_cnt() == live_cnt());
        chk("A4 reset: free_mask agrees with POLY - live (allocator view)",
            free_mask_cnt() == (POLY - live_cnt()));
        chk("A5 reset: retrig_low is all zero", retrig_cnt() == 0);
        chk("A6 reset: no gated voice", gate_cnt() == 0);

        // ===================================================================
        // B - ROUNDS x same-axis press/release, each with a FAST re-press in
        //     the release tail (that is the path that enters ST_RETRIG).
        //     Criterion: the free count must return to POLY after EVERY round.
        // ===================================================================
        $display("-- B: %0d x same-axis press/release with a fast re-press --", ROUNDS);
        leak_rounds = 0;
        for (r = 0; r < ROUNDS; r = r + 1) begin
            press_a(AXX);
            run_ticks(20);              // attack 8 + decay 6 => sustain (6400)
            off_a(AXX);
            run_ticks(2);               // still inside the release tail
            repress_a(AXX);             // FAST RE-PRESS -> ST_RETRIG path
            run_ticks(4);
            off_a(AXX);
            wait_free();
            fr = free_cnt();
            lv = live_cnt();
            rg = retrig_cnt();
            gc = gate_cnt();
            $display("  round %0d: free=%0d/%0d live=%0d gate=%0d retrig=%0d",
                     r, fr, POLY, lv, gc, rg);
            if (!((fr == POLY) && (lv == 0) && (rg == 0) && (gc == 0)
                  && (free_mask_cnt() == POLY))) begin
                leak_rounds = leak_rounds + 1;
                $display("  INFO: round %0d LEAKED a voice (free=%0d, expected %0d)",
                         r, fr, POLY);
            end
            chk("B: same-axis round ends with the pool back to full (no leaked voice)",
                (fr == POLY) && (lv == 0) && (rg == 0) && (gc == 0));
        end
        chk("B0: all %0d rounds ended with a full pool", leak_rounds == 0);

        // ===================================================================
        // C - one fast re-press, checked in detail
        // ===================================================================
        $display("-- C: fast re-press in the release tail --");
        clean_slate();
        press_a(AXX);
        run_ticks(20);
        off_a(AXX);
        run_ticks(2);
        mon_bad  = 1'b0;
        mon_seen = 1'b0;
        mon_axis = AXX;
        mon_armed = 1'b1;
        repress_a(AXX);
        run_ticks(4);
        mon_armed = 1'b0;
        if (mon_seen) retrig_seen = retrig_seen + 1;
        chk("C1 exactly one voice is gated after the fast re-press", gate_cnt() == 1);
        chk("C2 exactly one live voice on the pressed axis", axis_live_cnt(AXX) == 1);
        chk("C3 exactly one live voice in total (no duplicate on the axis)", live_cnt() == 1);
        chk("C4 free count == POLY-1 (one voice in use)", free_cnt() == (POLY-1));
        chk("C5 retrig_low returned to all-zero after the re-press", retrig_cnt() == 0);
        chk("C6 no foreign voice was retriggered by the same-axis re-press",
            mon_bad === 1'b0);
        clean_slate();
        chk("C7 pool is full again after the release", free_cnt() == POLY);
        chk("C8 the ST_RETRIG hold was really entered (probe reached the path)",
            mon_seen === 1'b1);

        // ===================================================================
        // D - phase sweep of the re-press relative to sample_tick
        //
        //   The stale-index write can only differ from the latched index on the
        //   ONE clock where same_hit drops, i.e. where env_active_r falls at the
        //   end of the release.  Two things must therefore be swept together:
        //     off = 0..15  the clock phase of the re-press inside the frame
        //                  (FRAME = 16, so one full frame covers every phase);
        //     kr  = 0..24  the release age in sample ticks.  The envelope is
        //                  released 16 ticks after the gate falls (6400/400), so
        //                  the "env_active_r falls" clock only exists for
        //                  kr around 15..16; sweeping kr across it is what makes
        //                  the one-clock window reachable at all.
        //   kr*FRAME + off covers 400 consecutive clock positions, so the window
        //   is hit exactly once (and each combination is a distinct position).
        // ===================================================================
        $display("-- D1: phase sweep, witness voice != 0, voice 0 held on axis 1 --");
        foreign_d1 = 0; leak_d1 = 0; axis_d1 = 0; live_d1 = 0; retrig_d1 = 0;
        iters_d1 = 0;
        for (kr = 0; kr <= 24; kr = kr + 1) begin
            for (off = 0; off < 16; off = off + 1) begin
                clean_slate();
                press_a(AXH1);          // voice 0
                press_a(AXH2);          // voice 1
                press_a(AXX);           // voice 2 (witness)
                run_ticks(14);          // witness reaches sustain
                off_a(AXX);             // witness enters its release tail
                run_ticks(kr);
                run_clks(off);          // <- phase offset under test
                // non-vacuity: in D1 the witness must NOT be voice 0, otherwise
                // a stale index falling back to 0 would write the same voice
                // and the whole test would be blind to it.
                if (axis_of(0) == AXX) d1_setup_bad = d1_setup_bad + 1;
                mon_bad   = 1'b0;
                mon_seen  = 1'b0;
                mon_axis  = AXX;
                mon_armed = 1'b1;
                repress_a(AXX);         // fast re-press
                run_ticks(3);
                mon_armed = 1'b0;
                iters_d1 = iters_d1 + 1;
                if (mon_seen)                         retrig_seen = retrig_seen + 1;
                if (mon_bad !== 1'b0)                 foreign_d1 = foreign_d1 + 1;
                if (axis_live_cnt(AXX) != 1)          axis_d1    = axis_d1 + 1;
                if (live_cnt() != 3)                  live_d1    = live_d1 + 1;
                if (retrig_cnt() != 0)                retrig_d1  = retrig_d1 + 1;
                off_a(AXX); off_a(AXH1); off_a(AXH2);
                wait_free();
                if (free_cnt() != POLY)               leak_d1    = leak_d1 + 1;
            end
        end
        $display("  D1: iters=%0d foreign=%0d axis_bad=%0d live_bad=%0d retrig_bad=%0d leak=%0d",
                 iters_d1, foreign_d1, axis_d1, live_d1, retrig_d1, leak_d1);
        chk("D1a no foreign voice was ever retriggered (all phases)",
            foreign_d1 == 0);
        chk("D1b exactly one live voice on the pressed axis (all phases)",
            axis_d1 == 0);
        chk("D1c live count is exactly 3 during the retrigger window (all phases)",
            live_d1 == 0);
        chk("D1d retrig_low is all-zero once the re-press completed (all phases)",
            retrig_d1 == 0);
        chk("D1e the pool is full again after every sweep iteration (all phases)",
            leak_d1 == 0);
        chk("D1f the witness voice was never voice 0 (probe layout stays valid)",
            d1_setup_bad == 0);

        // D2: voice 0 is FREE with a stale axis while the witness still has a
        // release tail.  If a stale index falls back to 0, voice 0 is pushed
        // into the retrigger hold, brought back up on its OLD axis, and no key
        // in use can release it -> permanent stuck note + one leaked voice.
        // NOTE: this variant deliberately does NOT send note_off for AXH1 --
        // sending it would clear the stuck voice (the board symptom "pressing
        // another key makes the stuck note disappear").
        $display("-- D2: phase sweep, voice 0 FREE with a stale axis --");
        foreign_d2 = 0; leak_d2 = 0; axis_d2 = 0; live_d2 = 0; retrig_d2 = 0;
        iters_d2 = 0;
        for (kr = 0; kr <= 24; kr = kr + 1) begin
            for (off = 0; off < 16; off = off + 1) begin
                // clean up front: AXH1 first, in case a previous iteration left
                // voice 0 stuck on that axis.
                off_a(AXH1);
                clean_slate();
                press_a(AXH1);          // voice 0
                press_a(AXH2);          // voice 1
                press_a(AXX);           // voice 2 (witness)
                run_ticks(14);
                off_a(AXH1);            // voice 0 -> release -> becomes FREE
                run_ticks(20);          // release is 16 ticks: voice 0 is free now
                // non-vacuity: voice 0 must really be FREE (with its OLD axis
                // still latched) or the permanent-leak case cannot be built.
                if (voice_active[0]) d2_setup_bad = d2_setup_bad + 1;
                off_a(AXX);             // witness enters its release tail
                run_ticks(kr);
                run_clks(off);          // <- phase offset under test
                mon_bad   = 1'b0;
                mon_seen  = 1'b0;
                mon_axis  = AXX;
                mon_armed = 1'b1;
                repress_a(AXX);
                run_ticks(3);
                mon_armed = 1'b0;
                iters_d2 = iters_d2 + 1;
                if (mon_seen)                         retrig_seen = retrig_seen + 1;
                if (mon_bad !== 1'b0)                 foreign_d2 = foreign_d2 + 1;
                if (axis_live_cnt(AXX) != 1)          axis_d2    = axis_d2 + 1;
                if (live_cnt() != 2)                  live_d2    = live_d2 + 1;
                if (retrig_cnt() != 0)                retrig_d2  = retrig_d2 + 1;
                off_a(AXX); off_a(AXH2);   // NOT AXH1: see the note above
                wait_free();
                if (free_cnt() != POLY)               leak_d2    = leak_d2 + 1;
            end
        end
        $display("  D2: iters=%0d foreign=%0d axis_bad=%0d live_bad=%0d retrig_bad=%0d leak=%0d",
                 iters_d2, foreign_d2, axis_d2, live_d2, retrig_d2, leak_d2);
        chk("D2a no foreign voice was ever retriggered (all phases)",
            foreign_d2 == 0);
        chk("D2b exactly one live voice on the pressed axis (all phases)",
            axis_d2 == 0);
        chk("D2c live count is exactly 2 during the retrigger window (all phases)",
            live_d2 == 0);
        chk("D2d retrig_low is all-zero once the re-press completed (all phases)",
            retrig_d2 == 0);
        chk("D2e no voice was left stuck on a stale axis (permanent leak, all phases)",
            leak_d2 == 0);
        chk("D2f voice 0 was FREE (old axis still latched) before every re-press",
            d2_setup_bad == 0);
        off_a(AXH1);
        clean_slate();

        // ===================================================================
        // E - the same module at POLY_TARGET=32 (parameterization / compile)
        // ===================================================================
        $display("-- E: POLY_TARGET=%0d instance --", POLY_B);
        chk("E1 POLY=32: pool is full after reset", b_free() == POLY_B);
        b_event(4'd5, 2'd0);
        run_ticks(20);
        b_event(4'd5, 2'd1);
        b_wait_free();
        chk("E2 POLY=32: press/release leaves the pool full", b_free() == POLY_B);
        b_event(4'd5, 2'd0);
        run_ticks(20);
        b_event(4'd5, 2'd1);
        run_ticks(2);
        b_event(4'd5, 2'd0);            // fast re-press
        run_ticks(4);
        chk("E3 POLY=32: fast re-press keeps exactly one voice on the axis",
            (b_axis_live(4'd5) == 1) && (b_free() == (POLY_B-1)));
        chk("E4 POLY=32: retrig_low is all-zero after the re-press", b_retrig() == 0);
        b_event(4'd5, 2'd1);
        b_wait_free();
        chk("E5 POLY=32: pool is full again after the release", b_free() == POLY_B);

        // ===================================================================
        // F - the event queue must never have overflowed (no silent drop: a
        //     dropped note_off is itself a way to get a stuck note)
        // ===================================================================
        chk("F1 the event queue never overflowed (no silently dropped event)",
            event_lost === 1'b0);

        // ===================================================================
        // G - non-vacuity: the criteria above only mean something if the
        //     retrigger path was really entered by these re-presses.
        // ===================================================================
        chk("G1 the ST_RETRIG hold was really entered (retrig_low seen non-zero)",
            retrig_seen > 0);

        // ------------------------------------------------------------- verdict
        $display("==================================================================");
        $display("tb_nm_no_leak: errors=%0d drain_timeouts=%0d leak_rounds=%0d retrig_seen=%0d",
                 errors, drain_timeouts, leak_rounds, retrig_seen);
        $display("  D1 iters=%0d leak=%0d foreign=%0d | D2 iters=%0d leak=%0d foreign=%0d",
                 iters_d1, leak_d1, foreign_d1, iters_d2, leak_d2, foreign_d2);
        if (errors == 0)
            $display("PASS: no voice leak on same-axis repeated press/release (all swept phases)");
        else
            $fatal(1, "FAIL: tb_nm_no_leak has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
