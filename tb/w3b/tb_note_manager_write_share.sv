`timescale 1ns/1ps
// Actual RTL versus frozen pre-change RTL, checked after every system edge.
// Reference is archived with the experiment, never regenerated from the DUT.
`include "evidence/h5/cls-next-20261004/note_manager_reference.v"
module tb_note_manager_write_share #(

    parameter integer POLY_TARGET = 32,
    parameter integer AXIS_W      = 4,
    parameter integer PHASE_W     = 32,
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    parameter integer T3_EN       = 0,
    parameter integer VEL_W       = 8,
    parameter integer TIMBRE_W    = 2,
    parameter integer ENV_W       = 16,
    parameter integer AGE_W       = 16,
    
    
    parameter integer RESERVED_N  = 5,
    
    parameter integer DEFAULT_VEL = 200,
    
    parameter integer RESERVED_AXIS_BASE = 14,
    
    
    
    
    
    
    
    
    
    parameter integer FIFO_DEPTH  = 32,
    
    parameter integer EVT_LOST_CNT_W = 8,
    
    parameter integer IDX_W = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET)

);
    reg  clk_i;
    reg  rst_n_i;
    reg  sample_tick_i;
    reg  note_valid_i;
    reg [AXIS_W-1:0] note_axis_i;
    reg [PHASE_W-1:0] note_phase_inc_i;
    reg [VEL_W-1:0] note_velocity_i;
    reg [1:0] note_kind_i;
    reg [2:0] note_src_i;
    reg  vel_upd_valid_i;
    reg [AXIS_W-1:0] vel_upd_axis_i;
    reg [VEL_W-1:0] vel_upd_value_i;
    reg  pitch_upd_valid_i;
    reg [AXIS_W-1:0] pitch_upd_axis_i;
    reg [PHASE_W-1:0] pitch_upd_value_i;
    reg [2:0] vel_upd_src_i;
    reg [2:0] pitch_upd_src_i;
    reg [TIMBRE_W-1:0] default_timbre_i;
    reg  evt_timbre_valid_i;
    reg [TIMBRE_W-1:0] evt_timbre_i;
    reg [POLY_TARGET-1:0] env_active_i;
    reg [POLY_TARGET*ENV_W-1:0] env_level_i;
    reg [6:0] base_semi_i;
    reg  base_commit_i;
    reg signed [4:0] transpose_semi_i;
    wire [POLY_TARGET-1:0] voice_gate_o, ref_voice_gate_o;
    wire [POLY_TARGET-1:0] voice_active_o, ref_voice_active_o;
    wire [POLY_TARGET-1:0] voice_releasing_o, ref_voice_releasing_o;
    wire [POLY_TARGET*AXIS_W-1:0] voice_axis_o, ref_voice_axis_o;
    wire [POLY_TARGET*PHASE_W-1:0] voice_phase_inc_o, ref_voice_phase_inc_o;
    wire [POLY_TARGET*VEL_W-1:0] voice_velocity_o, ref_voice_velocity_o;
    wire [POLY_TARGET*TIMBRE_W-1:0] voice_timbre_o, ref_voice_timbre_o;
    wire [POLY_TARGET-1:0] voice_drum_o, ref_voice_drum_o;
    wire [POLY_TARGET*AGE_W-1:0] voice_age_o, ref_voice_age_o;
    wire [POLY_TARGET-1:0] voice_retrig_reset_o, ref_voice_retrig_reset_o;
    wire  alloc_valid_o, ref_alloc_valid_o;
    wire [IDX_W-1:0] alloc_voice_o, ref_alloc_voice_o;
    wire  event_lost_o, ref_event_lost_o;
    wire [EVT_LOST_CNT_W-1:0] event_lost_cnt_o, ref_event_lost_cnt_o;
    reg  event_lost_clr_i;
    note_manager #(
        // This test compares write sharing to the frozen pre-pipeline model
        // cycle-for-cycle. Production MATCH_PIPE_EN=1 is covered by functional
        // allocation/source/retrigger tests, not this legacy timing oracle.
        .MATCH_PIPE_EN(0),
        .POLY_TARGET(POLY_TARGET), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .T3_EN(T3_EN), .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W), .RESERVED_N(RESERVED_N), .DEFAULT_VEL(DEFAULT_VEL), .RESERVED_AXIS_BASE(RESERVED_AXIS_BASE), .FIFO_DEPTH(FIFO_DEPTH), .EVT_LOST_CNT_W(EVT_LOST_CNT_W), .IDX_W(IDX_W)
    ) dut (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .sample_tick_i(sample_tick_i),
        .note_valid_i(note_valid_i),
        .note_axis_i(note_axis_i),
        .note_phase_inc_i(note_phase_inc_i),
        .note_velocity_i(note_velocity_i),
        .note_kind_i(note_kind_i),
        .note_src_i(note_src_i),
        .vel_upd_valid_i(vel_upd_valid_i),
        .vel_upd_axis_i(vel_upd_axis_i),
        .vel_upd_value_i(vel_upd_value_i),
        .pitch_upd_valid_i(pitch_upd_valid_i),
        .pitch_upd_axis_i(pitch_upd_axis_i),
        .pitch_upd_value_i(pitch_upd_value_i),
        .vel_upd_src_i(vel_upd_src_i),
        .pitch_upd_src_i(pitch_upd_src_i),
        .default_timbre_i(default_timbre_i),
        .evt_timbre_valid_i(evt_timbre_valid_i),
        .evt_timbre_i(evt_timbre_i),
        .env_active_i(env_active_i),
        .env_level_i(env_level_i),
        .base_semi_i(base_semi_i),
        .base_commit_i(base_commit_i),
        .transpose_semi_i(transpose_semi_i),
        .voice_gate_o(voice_gate_o),
        .voice_active_o(voice_active_o),
        .voice_releasing_o(voice_releasing_o),
        .voice_axis_o(voice_axis_o),
        .voice_phase_inc_o(voice_phase_inc_o),
        .voice_velocity_o(voice_velocity_o),
        .voice_timbre_o(voice_timbre_o),
        .voice_drum_o(voice_drum_o),
        .voice_age_o(voice_age_o),
        .voice_retrig_reset_o(voice_retrig_reset_o),
        .alloc_valid_o(alloc_valid_o),
        .alloc_voice_o(alloc_voice_o),
        .event_lost_o(event_lost_o),
        .event_lost_cnt_o(event_lost_cnt_o),
        .event_lost_clr_i(event_lost_clr_i)
    );
    note_manager_reference #(
        .POLY_TARGET(POLY_TARGET), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .T3_EN(T3_EN), .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W), .RESERVED_N(RESERVED_N), .DEFAULT_VEL(DEFAULT_VEL), .RESERVED_AXIS_BASE(RESERVED_AXIS_BASE), .FIFO_DEPTH(FIFO_DEPTH), .EVT_LOST_CNT_W(EVT_LOST_CNT_W), .IDX_W(IDX_W)
    ) ref_dut (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .sample_tick_i(sample_tick_i),
        .note_valid_i(note_valid_i),
        .note_axis_i(note_axis_i),
        .note_phase_inc_i(note_phase_inc_i),
        .note_velocity_i(note_velocity_i),
        .note_kind_i(note_kind_i),
        .note_src_i(note_src_i),
        .vel_upd_valid_i(vel_upd_valid_i),
        .vel_upd_axis_i(vel_upd_axis_i),
        .vel_upd_value_i(vel_upd_value_i),
        .pitch_upd_valid_i(pitch_upd_valid_i),
        .pitch_upd_axis_i(pitch_upd_axis_i),
        .pitch_upd_value_i(pitch_upd_value_i),
        .vel_upd_src_i(vel_upd_src_i),
        .pitch_upd_src_i(pitch_upd_src_i),
        .default_timbre_i(default_timbre_i),
        .evt_timbre_valid_i(evt_timbre_valid_i),
        .evt_timbre_i(evt_timbre_i),
        .env_active_i(env_active_i),
        .env_level_i(env_level_i),
        .base_semi_i(base_semi_i),
        .base_commit_i(base_commit_i),
        .transpose_semi_i(transpose_semi_i),
        .voice_gate_o(ref_voice_gate_o),
        .voice_active_o(ref_voice_active_o),
        .voice_releasing_o(ref_voice_releasing_o),
        .voice_axis_o(ref_voice_axis_o),
        .voice_phase_inc_o(ref_voice_phase_inc_o),
        .voice_velocity_o(ref_voice_velocity_o),
        .voice_timbre_o(ref_voice_timbre_o),
        .voice_drum_o(ref_voice_drum_o),
        .voice_age_o(ref_voice_age_o),
        .voice_retrig_reset_o(ref_voice_retrig_reset_o),
        .alloc_valid_o(ref_alloc_valid_o),
        .alloc_voice_o(ref_alloc_voice_o),
        .event_lost_o(ref_event_lost_o),
        .event_lost_cnt_o(ref_event_lost_cnt_o),
        .event_lost_clr_i(event_lost_clr_i)
    );
    integer cycles=0, j, k, v, n, wait_count, seed=32'h31b2026;
    integer commits=0, retriggers=0, collision_edges=0, drops=0;
    reg [POLY_TARGET-1:0] written=0;
    always #5 clk_i = ~clk_i;
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (dut.state == 4 && dut.cmt_en_r) begin
                commits=commits+1; written[dut.cmt_idx_r]=1;
            end
            if (dut.state == 5 && dut.same_en_r) retriggers=retriggers+1;
            if ((dut.state == 4 || dut.state == 5) && sample_tick_i && pitch_upd_valid_i && vel_upd_valid_i)
                collision_edges=collision_edges+1;
            if (dut.fifo_drop) drops=drops+1;
        end
        #1;
        cycles=cycles+1;
        if (voice_gate_o !== ref_voice_gate_o) $fatal(1, "DIFF voice_gate_o cycle=%0d", cycles);
        if (voice_active_o !== ref_voice_active_o) $fatal(1, "DIFF voice_active_o cycle=%0d", cycles);
        if (voice_releasing_o !== ref_voice_releasing_o) $fatal(1, "DIFF voice_releasing_o cycle=%0d", cycles);
        if (voice_axis_o !== ref_voice_axis_o) $fatal(1, "DIFF voice_axis_o cycle=%0d", cycles);
        if (voice_phase_inc_o !== ref_voice_phase_inc_o) $fatal(1, "DIFF voice_phase_inc_o cycle=%0d", cycles);
        if (voice_velocity_o !== ref_voice_velocity_o) $fatal(1, "DIFF voice_velocity_o cycle=%0d", cycles);
        if (voice_timbre_o !== ref_voice_timbre_o) $fatal(1, "DIFF voice_timbre_o cycle=%0d", cycles);
        if (voice_drum_o !== ref_voice_drum_o) $fatal(1, "DIFF voice_drum_o cycle=%0d", cycles);
        if (voice_age_o !== ref_voice_age_o) $fatal(1, "DIFF voice_age_o cycle=%0d", cycles);
        if (voice_retrig_reset_o !== ref_voice_retrig_reset_o) $fatal(1, "DIFF voice_retrig_reset_o cycle=%0d", cycles);
        if (alloc_valid_o !== ref_alloc_valid_o) $fatal(1, "DIFF alloc_valid_o cycle=%0d", cycles);
        if (alloc_voice_o !== ref_alloc_voice_o) $fatal(1, "DIFF alloc_voice_o cycle=%0d", cycles);
        if (event_lost_o !== ref_event_lost_o) $fatal(1, "DIFF event_lost_o cycle=%0d", cycles);
        if (event_lost_cnt_o !== ref_event_lost_cnt_o) $fatal(1, "DIFF event_lost_cnt_o cycle=%0d", cycles);
        if (dut.state !== ref_dut.state) $fatal(1, "DIFF internal state cycle=%0d", cycles);
        if (dut.scan_cnt !== ref_dut.scan_cnt) $fatal(1, "DIFF internal scan_cnt cycle=%0d", cycles);
        if (dut.scan_sel !== ref_dut.scan_sel) $fatal(1, "DIFF internal scan_sel cycle=%0d", cycles);
        if (dut.best_valid !== ref_dut.best_valid) $fatal(1, "DIFF internal best_valid cycle=%0d", cycles);
        if (dut.best_idx !== ref_dut.best_idx) $fatal(1, "DIFF internal best_idx cycle=%0d", cycles);
        if (dut.best_cls !== ref_dut.best_cls) $fatal(1, "DIFF internal best_cls cycle=%0d", cycles);
        if (dut.best_env !== ref_dut.best_env) $fatal(1, "DIFF internal best_env cycle=%0d", cycles);
        if (dut.best_age !== ref_dut.best_age) $fatal(1, "DIFF internal best_age cycle=%0d", cycles);
        if (dut.fifo_cnt !== ref_dut.fifo_cnt) $fatal(1, "DIFF internal fifo_cnt cycle=%0d", cycles);
        if (dut.fifo_wr !== ref_dut.fifo_wr) $fatal(1, "DIFF internal fifo_wr cycle=%0d", cycles);
        if (dut.fifo_rd !== ref_dut.fifo_rd) $fatal(1, "DIFF internal fifo_rd cycle=%0d", cycles);
        if (dut.retrig_low !== ref_dut.retrig_low) $fatal(1, "DIFF internal retrig_low cycle=%0d", cycles);
        if (dut.env_level_r !== ref_dut.env_level_r) $fatal(1, "DIFF internal env_level_r cycle=%0d", cycles);
        if (dut.env_active_r !== ref_dut.env_active_r) $fatal(1, "DIFF internal env_active_r cycle=%0d", cycles);
        if (dut.cmt_en_r !== ref_dut.cmt_en_r) $fatal(1, "DIFF internal cmt_en_r cycle=%0d", cycles);
        if (dut.same_en_r !== ref_dut.same_en_r) $fatal(1, "DIFF internal same_en_r cycle=%0d", cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.gate_r[j] !== ref_dut.gate_r[j]) $fatal(1, "DIFF gate_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.axis_r[j] !== ref_dut.axis_r[j]) $fatal(1, "DIFF axis_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.src_r[j] !== ref_dut.src_r[j]) $fatal(1, "DIFF src_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.phase_r[j] !== ref_dut.phase_r[j]) $fatal(1, "DIFF phase_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.vel_r[j] !== ref_dut.vel_r[j]) $fatal(1, "DIFF vel_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.timbre_r[j] !== ref_dut.timbre_r[j]) $fatal(1, "DIFF timbre_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.age_r[j] !== ref_dut.age_r[j]) $fatal(1, "DIFF age_r voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<POLY_TARGET; j=j+1) if (dut.vtgt_rep[j] !== ref_dut.vtgt_rep[j]) $fatal(1, "DIFF vtgt_rep voice=%0d cycle=%0d", j, cycles);
        for (j=0; j<(1<<AXIS_W); j=j+1) if (dut.vtgt_val[j] !== ref_dut.vtgt_val[j]) $fatal(1, "DIFF vtgt_val axis=%0d cycle=%0d", j, cycles);
        for (j=0; j<(1<<AXIS_W); j=j+1) if (dut.vtgt_vld[j] !== ref_dut.vtgt_vld[j]) $fatal(1, "DIFF vtgt_vld axis=%0d cycle=%0d", j, cycles);
    end
    task drive;
        input integer mode;
        begin
            @(negedge clk_i);
            sample_tick_i = ($random(seed) & 3) == 0;
            note_valid_i = mode == 2 ? (($random(seed) & 3) != 0) : 0;
            note_axis_i = $random(seed);
            note_src_i = $unsigned($random(seed)) % 5;
            note_kind_i = $unsigned($random(seed)) % 3;
            note_phase_inc_i = $random(seed);
            note_velocity_i = $random(seed);
            evt_timbre_i = $random(seed);
            evt_timbre_valid_i = $random(seed);
            default_timbre_i = $random(seed);
            vel_upd_valid_i = $random(seed);
            vel_upd_axis_i = $random(seed);
            vel_upd_src_i = $unsigned($random(seed)) % 5;
            vel_upd_value_i = $random(seed);
            pitch_upd_valid_i = $random(seed);
            pitch_upd_axis_i = $random(seed);
            pitch_upd_src_i = $unsigned($random(seed)) % 5;
            pitch_upd_value_i = $random(seed);
            event_lost_clr_i = (($random(seed) & 255) == 0);
            base_commit_i = (($random(seed) & 63) == 0);
            case ($random(seed) & 3)
                0: base_semi_i=0; 1: base_semi_i=12; 2: base_semi_i=24; 3: base_semi_i=127;
            endcase
            transpose_semi_i = $random(seed);
            for (v=0; v<POLY_TARGET; v=v+1) begin
                env_level_i[v*ENV_W +: ENV_W] = mode == 0 ? 0 : $random(seed);
                env_active_i[v] = mode == 0 ? 0 : ($random(seed) & 1);
            end
            // Explicit collisions with the actual destination voice. Event
            // writes must win over ramp / pitch / age on exactly this edge.
            if ((dut.state == 4 && dut.cmt_en_r) || (dut.state == 5 && dut.same_en_r)) begin
                n = dut.state == 5 ? dut.same_idx_r : dut.cmt_idx_r;
                sample_tick_i=1; vel_upd_valid_i=1; pitch_upd_valid_i=1;
                pitch_upd_axis_i=dut.axis_r[n]; pitch_upd_src_i=dut.src_r[n];
                vel_upd_axis_i=dut.axis_r[n]; vel_upd_src_i=dut.src_r[n];
            end
        end
    endtask
    initial begin
        clk_i = 0;
        rst_n_i = 0;
        sample_tick_i = 0;
        note_valid_i = 0;
        note_axis_i = 0;
        note_phase_inc_i = 0;
        note_velocity_i = 0;
        note_kind_i = 0;
        note_src_i = 0;
        vel_upd_valid_i = 0;
        vel_upd_axis_i = 0;
        vel_upd_value_i = 0;
        pitch_upd_valid_i = 0;
        pitch_upd_axis_i = 0;
        pitch_upd_value_i = 0;
        vel_upd_src_i = 0;
        pitch_upd_src_i = 0;
        default_timbre_i = 0;
        evt_timbre_valid_i = 0;
        evt_timbre_i = 0;
        env_active_i = 0;
        env_level_i = 0;
        base_semi_i = 0;
        base_commit_i = 0;
        transpose_semi_i = 0;
        event_lost_clr_i = 0;
        repeat (3) @(negedge clk_i);
        rst_n_i=1;
        // Fill ordinary and AUX pools, then same-source/axis reuse and steal.
        for (k=0; k<240; k=k+1) begin
            drive(0);
            note_valid_i=1; note_axis_i=k%16; note_src_i=(k/16)%5;
            note_kind_i=0; note_velocity_i=k; note_phase_inc_i=32'h12340000+k;
            for (wait_count=0; wait_count<POLY_TARGET+10; wait_count=wait_count+1) drive(0);
        end
        // Continuous busy FIFO, drops, all event kinds, release tails and reset.
        for (k=0; k<12000; k=k+1) begin
            drive(2);
            rst_n_i = (k%3000 != 2999);
        end
        rst_n_i=1;
        for (k=0; k<2000; k=k+1) drive(1);
        @(negedge clk_i);
        if (commits < POLY_TARGET || retriggers < 10 || collision_edges < 20 || drops < 10)
            $fatal(1, "FAIL insufficient coverage c=%0d r=%0d collisions=%0d drops=%0d", commits,retriggers,collision_edges,drops);
        if (written !== {POLY_TARGET{1'b1}}) $fatal(1, "FAIL unvisited voice %h", written);
        $display("PASS: tb_note_manager_write_share P=%0d T3=%0d cycles=%0d commits=%0d retriggers=%0d collisions=%0d drops=%0d all_voice_mask=%h", POLY_TARGET,T3_EN,cycles,commits,retriggers,collision_edges,drops,written);
        $finish;
    end
    initial begin #2000000; $fatal(1, "FAIL watchdog"); end
endmodule
