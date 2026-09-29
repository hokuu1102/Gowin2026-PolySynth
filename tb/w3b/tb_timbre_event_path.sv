`timescale 1ns/1ps
// T31b: score-event timbre must survive seq_arb, evt_merge and note_manager's
// allocation FIFO.  It is a sideband of the existing 64-bit event, not a new
// board or transport interface.
module tb_timbre_event_path;
    localparam integer AXIS_W = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W = 8;
    localparam integer KIND_W = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer POLY = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg score_valid = 1'b0;
    reg [AXIS_W-1:0] score_axis = 4'd0;
    reg [PHASE_W-1:0] score_inc = 32'd0;
    reg [VEL_W-1:0] score_vel = 8'd0;
    reg [KIND_W-1:0] score_kind = 2'd0;
    reg score_timbre_valid = 1'b0;
    reg [TIMBRE_W-1:0] score_timbre = 2'd0;
    reg live_valid = 1'b0;
    reg [AXIS_W-1:0] live_axis = 4'd0;
    reg [PHASE_W-1:0] live_inc = 32'd0;
    reg [VEL_W-1:0] live_vel = 8'd0;
    reg [KIND_W-1:0] live_kind = 2'd0;
    reg [TIMBRE_W-1:0] default_timbre = 2'd0;

    wire sa_valid;
    wire [AXIS_W-1:0] sa_axis;
    wire [PHASE_W-1:0] sa_inc;
    wire [VEL_W-1:0] sa_vel;
    wire [KIND_W-1:0] sa_kind;
    wire sa_timbre_valid;
    wire [TIMBRE_W-1:0] sa_timbre;

    seq_arb #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(6)
    ) u_seq_arb (
        .clk_i(clk), .rst_n_i(rst_n),
        .live_valid_i(live_valid), .live_axis_i(live_axis),
        .live_phase_inc_i(live_inc), .live_velocity_i(live_vel),
        .live_kind_i(live_kind), .live_timbre_valid_i(1'b0),
        .live_timbre_i({TIMBRE_W{1'b0}}),
        .score_valid_i(score_valid), .score_axis_i(score_axis),
        .score_phase_inc_i(score_inc), .score_velocity_i(score_vel),
        .score_kind_i(score_kind), .score_timbre_valid_i(score_timbre_valid),
        .score_timbre_i(score_timbre),
        .demo_valid_i(1'b0), .demo_axis_i({AXIS_W{1'b0}}),
        .demo_phase_inc_i({PHASE_W{1'b0}}), .demo_velocity_i({VEL_W{1'b0}}),
        .demo_kind_i({KIND_W{1'b0}}), .demo_timbre_valid_i(1'b0),
        .demo_timbre_i({TIMBRE_W{1'b0}}),
        .evt_valid_o(sa_valid), .evt_axis_o(sa_axis), .evt_phase_inc_o(sa_inc),
        .evt_velocity_o(sa_vel), .evt_kind_o(sa_kind),
        .evt_timbre_valid_o(sa_timbre_valid), .evt_timbre_o(sa_timbre),
        .collision_cnt_o(), .merged_cnt_o(), .drop_cnt_o(), .overflow_o(),
        .live_cnt_o(), .score_cnt_o(), .demo_cnt_o()
    );

    wire mg_valid;
    wire [AXIS_W-1:0] mg_axis;
    wire [PHASE_W-1:0] mg_inc;
    wire [VEL_W-1:0] mg_vel;
    wire [KIND_W-1:0] mg_kind;
    wire mg_timbre_valid;
    wire [TIMBRE_W-1:0] mg_timbre;

    evt_merge #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(4)
    ) u_evt_merge (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(sa_valid), .a_axis_i(sa_axis), .a_phase_inc_i(sa_inc),
        .a_velocity_i(sa_vel), .a_kind_i(sa_kind),
        .a_timbre_valid_i(sa_timbre_valid), .a_timbre_i(sa_timbre),
        .b_valid_i(1'b0), .b_axis_i({AXIS_W{1'b0}}),
        .b_phase_inc_i({PHASE_W{1'b0}}), .b_velocity_i({VEL_W{1'b0}}),
        .b_kind_i({KIND_W{1'b0}}), .b_timbre_valid_i(1'b0),
        .b_timbre_i({TIMBRE_W{1'b0}}),
        .evt_valid_o(mg_valid), .evt_axis_o(mg_axis), .evt_phase_inc_o(mg_inc),
        .evt_velocity_o(mg_vel), .evt_kind_o(mg_kind),
        .evt_timbre_valid_o(mg_timbre_valid), .evt_timbre_o(mg_timbre),
        .collision_cnt_o(), .merged_cnt_o(), .drop_cnt_o(), .overflow_o()
    );

    wire [POLY-1:0] voice_gate;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(16), .AGE_W(16),
        .FIFO_DEPTH(8), .IDX_W(2)
    ) u_note_manager (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(1'b0),
        .note_valid_i(mg_valid), .note_axis_i(mg_axis),
        .note_phase_inc_i(mg_inc), .note_velocity_i(mg_vel), .note_kind_i(mg_kind),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}), .pitch_upd_valid_i(1'b0),
        .pitch_upd_axis_i({AXIS_W{1'b0}}), .pitch_upd_value_i({PHASE_W{1'b0}}),
        .default_timbre_i(default_timbre), .evt_timbre_valid_i(mg_timbre_valid),
        .evt_timbre_i(mg_timbre), .env_active_i({POLY{1'b0}}),
        .env_level_i({(POLY*16){1'b0}}), .voice_gate_o(voice_gate),
        .voice_active_o(), .voice_releasing_o(), .voice_axis_o(),
        .voice_phase_inc_o(), .voice_velocity_o(), .voice_timbre_o(voice_timbre),
        .voice_age_o(), .alloc_valid_o(), .alloc_voice_o(),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    integer errors = 0;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        score_valid = 1'b1;
        score_axis = 4'd6;
        score_inc = 32'h0010_0000;
        score_vel = 8'd200;
        score_kind = 2'd0;
        score_timbre_valid = 1'b1;
        score_timbre = 2'd2; // PIANO
        @(negedge clk);
        score_valid = 1'b0;
        score_timbre_valid = 1'b0;
        score_timbre = 2'd0;

        repeat (32) @(negedge clk);
        if (voice_gate[0] !== 1'b1 || voice_timbre[1:0] !== 2'd2) begin
            $display("FAIL: score timbre did not reach and lock in voice0 (gate=%b timbre=%d)",
                     voice_gate[0], voice_timbre[1:0]);
            errors = errors + 1;
        end else
            $display("  ok  : score PIANO timbre survives arb/merge/FIFO into voice0");

        // Changing the selector must not rewrite a voice that is already on.
        default_timbre = 2'd1; // GUITAR
        repeat (4) @(negedge clk);
        if (voice_timbre[1:0] !== 2'd2) begin
            $display("FAIL: a held voice followed the new default timbre");
            errors = errors + 1;
        end else
            $display("  ok  : existing voice keeps its original PIANO timbre");

        // A later manual note has no explicit event timbre, so it must snapshot
        // the new default into the newly allocated voice.
        live_valid = 1'b1;
        live_axis = 4'd7;
        live_inc = 32'h0012_0000;
        live_vel = 8'd180;
        live_kind = 2'd0;
        @(negedge clk);
        live_valid = 1'b0;

        repeat (32) @(negedge clk);
        if (voice_gate[0] !== 1'b1 || voice_timbre[1:0] !== 2'd2) begin
            $display("FAIL: first voice changed when a new note was allocated");
            errors = errors + 1;
        end
        if (voice_gate[1] !== 1'b1 || voice_timbre[3:2] !== 2'd1) begin
            $display("FAIL: new voice did not snapshot GUITAR (gate=%b timbre=%d)",
                     voice_gate[1], voice_timbre[3:2]);
            errors = errors + 1;
        end else
            $display("  ok  : new voice snapshots GUITAR while held voice stays PIANO");

        if (errors == 0)
            $display("PASS: T31b timbre event path");
        else
            $fatal(1, "FAIL: T31b timbre event path (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_timbre_event_path timeout");
    end
endmodule
