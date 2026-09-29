`timescale 1ns/1ps
`default_nettype none

// Instrument the real oscillator -> ADSR -> render mixer path at performance
// velocities.  This distinguishes RTL clipping/limiter engagement from a
// board-level overload or extra-note trigger.
module tb_velocity_headroom;
    // POLY=4 keeps POLY+2 representable in the mixer's counter width.  The
    // production configuration is 32; tiny POLY=2 is not a supported profile.
    localparam integer POLY = 4;
    localparam integer OSC_PER_VOICE = 2;
    localparam integer LANES = POLY * OSC_PER_VOICE;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [POLY-1:0] active = 4'b0001;
    reg [POLY-1:0] gate = 4'b0001;
    reg [POLY*32-1:0] phase_inc = {96'd0, 32'd23_010_000};
    reg [POLY*2-1:0] timbre = 8'd0;
    reg [POLY*8-1:0] velocity = 32'd0;

    wire [LANES*16-1:0] osc_bus;
    wire osc_valid;
    wire [POLY*16-1:0] env_level;
    wire [POLY-1:0] env_active;
    wire dry_valid;
    wire signed [23:0] dry_sample;
    wire deadline_fault;

    integer errors = 0;
    integer sample_count = 0;
    integer max_abs = 0;
    integer knee_hits = 0;
    integer rail_hits = 0;
    integer abs_sample;
    integer abs_osc;
    integer max_osc = 0;
    integer max_env = 0;

    always #10 clk = ~clk;

    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OSC_PER_VOICE),
        .WT_DEPTH(1024), .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0)
    ) u_osc (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(active), .base_phase_inc_i(phase_inc),
        .voice_timbre_i(timbre), .voice_velocity_i(velocity),
        .vibrato_mod_i(16'sd0), .test_mode_i(1'b0),
        .test_lane_active_i({LANES{1'b0}}),
        .test_phase_inc_i({LANES*32{1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(osc_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o()
    );

    envelope_bank #(.POLY_TARGET(POLY)) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(gate), .velocity_i(velocity), .retrig_reset_i(4'b0000),
        .timbre_i(timbre), .env_level_o(env_level), .env_active_o(env_active)
    );

    tdm_render_mixer #(
        .OUTPUT_HEADROOM_SH(1),
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OSC_PER_VOICE),
        .RESERVED_N(0), .NORM_GAIN_STEP(0)
    ) u_mix (
        // Headroom is an arithmetic property; render the stable oscillator bus
        // at the audio frame boundary, matching the mixer's standalone TB.
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(sample_tick),
        .osc_sample_bus_i(osc_bus), .env_level_i(env_level),
        .voice_active_i(active), .dry_valid_o(dry_valid),
        .dry_sample_o(dry_sample), .deadline_fault_o(deadline_fault),
        .n_active_o()
    );

    always @(posedge clk) begin
        abs_osc = $signed(osc_bus[15:0]);
        if (abs_osc < 0)
            abs_osc = -abs_osc;
        if (abs_osc > max_osc)
            max_osc = abs_osc;
        if (env_level[15:0] > max_env)
            max_env = env_level[15:0];
        if (dry_valid) begin
            sample_count = sample_count + 1;
            abs_sample = dry_sample[23] ? -dry_sample : dry_sample;
            if (abs_sample > max_abs)
                max_abs = abs_sample;
            if (abs_sample >= 24'h700000)
                knee_hits = knee_hits + 1;
            if (abs_sample >= 24'h780000)
                rail_hits = rail_hits + 1;
        end
    end

    task audio_tick;
        begin
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            repeat (48) @(negedge clk);
        end
    endtask

    task run_case;
        input [1:0] t;
        input [7:0] vel;
        integer k;
        begin
            rst_n = 1'b0;
            repeat (5) @(negedge clk);
            timbre = {6'd0, t};
            velocity = {24'd0, vel};
            active = 4'b0001;
            gate = 4'b0001;
            rst_n = 1'b1;
            sample_count = 0;
            max_abs = 0;
            max_osc = 0;
            max_env = 0;
            knee_hits = 0;
            rail_hits = 0;
            for (k = 0; k < 700; k = k + 1)
                audio_tick();
            $display("INFO: timbre=%0d velocity=%0d samples=%0d osc=%0d env=%0d max_abs=%0d (%0d/1000 FS) knee=%0d rail=%0d",
                     t, vel, sample_count, max_osc, max_env, max_abs,
                     max_abs / 8389, knee_hits, rail_hits);
            if (deadline_fault || (sample_count < 690)) begin
                $display("FAIL: render did not complete deterministically");
                errors = errors + 1;
            end
            if ((vel <= 8'd200) && ((knee_hits != 0) || (rail_hits != 0))) begin
                $display("FAIL: legal performance velocity reached limiter/rail");
                errors = errors + 1;
            end
            if ((max_osc == 0) || (max_env == 0) || (max_abs == 0)) begin
                $display("FAIL: headroom probe is vacuous (osc/env/output must all be nonzero)");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        run_case(2'd0, 8'd64);
        run_case(2'd0, 8'd128);
        run_case(2'd0, 8'd160);
        run_case(2'd0, 8'd200);
        run_case(2'd1, 8'd200);
        run_case(2'd2, 8'd200);
        run_case(2'd3, 8'd200);

        if (errors == 0)
            $display("PASS: velocity headroom stays below the digital limiter for all timbres");
        else
            $fatal(1, "FAIL: velocity headroom found %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_velocity_headroom timeout");
    end
endmodule

`default_nettype wire
