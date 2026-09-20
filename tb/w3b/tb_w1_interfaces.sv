// W1-1 contract test: elaborate all four W3b skeletons in the first-week
// 32 voices x 1 oscillator profile and check widths plus safe tie-offs.
`timescale 1ns/1ps

module tb_w1_interfaces;
    localparam integer POLY_TARGET   = 32;
    localparam integer OSC_PER_VOICE = 1;
    localparam integer PHASE_W       = 32;
    localparam integer OSC_SAMPLE_W  = 16;
    localparam integer SAMPLE_W      = 24;
    localparam integer VEL_W         = 8;
    localparam integer ENV_W         = 16;
    localparam integer OSC_N         = POLY_TARGET * OSC_PER_VOICE;

    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg sample_tick_i = 1'b0;
    always #10 clk_i = ~clk_i;

    reg [POLY_TARGET-1:0] voice_active_i = {POLY_TARGET{1'b0}};
    reg [POLY_TARGET*PHASE_W-1:0] base_phase_inc_i = {(POLY_TARGET*PHASE_W){1'b0}};
    reg [POLY_TARGET-1:0] gate_i = {POLY_TARGET{1'b0}};
    reg [POLY_TARGET*VEL_W-1:0] velocity_i = {(POLY_TARGET*VEL_W){1'b0}};
    reg test_mode_i = 1'b0;
    reg [OSC_N-1:0] test_lane_active_i = {OSC_N{1'b0}};
    reg [OSC_N*PHASE_W-1:0] test_phase_inc_i = {(OSC_N*PHASE_W){1'b0}};
    reg enable_i = 1'b0;
    reg [1:0] n_code_i = 2'b00;

    wire [OSC_N*OSC_SAMPLE_W-1:0] osc_sample_bus;
    wire osc_valid;
    wire [PHASE_W-1:0] phase_acc_dbg;
    wire [POLY_TARGET*ENV_W-1:0] env_level;
    wire [POLY_TARGET-1:0] env_active;
    wire dry_valid;
    wire signed [SAMPLE_W-1:0] dry_sample;
    wire deadline_fault;
    wire [POLY_TARGET-1:0] test_voice_gate;
    wire [POLY_TARGET*VEL_W-1:0] test_velocity;
    wire [OSC_N-1:0] test_lane_active;
    wire [OSC_N*PHASE_W-1:0] test_phase_inc;
    wire [5:0] active_n;

    oscillator_bank #(
        .POLY_TARGET(POLY_TARGET), .OSC_PER_VOICE(OSC_PER_VOICE),
        .PHASE_W(PHASE_W), .OSC_SAMPLE_W(OSC_SAMPLE_W)
    ) u_oscillator_bank (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .sample_tick_i(sample_tick_i),
        .voice_active_i(voice_active_i), .base_phase_inc_i(base_phase_inc_i),
        .timbre_id_i(1'b0), .vibrato_mod_i(16'sd0),
        .test_mode_i(test_mode_i), .test_lane_active_i(test_lane_active_i),
        .test_phase_inc_i(test_phase_inc_i), .fm_cfg_valid_i(1'b0),
        .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(osc_sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o(phase_acc_dbg)
    );

    envelope_bank #(
        .POLY_TARGET(POLY_TARGET), .VEL_W(VEL_W), .ENV_W(ENV_W)
    ) u_envelope_bank (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .sample_tick_i(sample_tick_i),
        .gate_i(gate_i), .velocity_i(velocity_i),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    tdm_render_mixer #(
        .POLY_TARGET(POLY_TARGET), .OSC_PER_VOICE(OSC_PER_VOICE),
        .OSC_SAMPLE_W(OSC_SAMPLE_W), .ENV_W(ENV_W), .SAMPLE_W(SAMPLE_W)
    ) u_tdm_render_mixer (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .render_start_i(sample_tick_i),
        .osc_sample_bus_i(osc_sample_bus), .env_level_i(env_level),
        .dry_valid_o(dry_valid), .dry_sample_o(dry_sample),
        .deadline_fault_o(deadline_fault)
    );

    test_mode_ctrl #(
        .POLY_TARGET(POLY_TARGET), .OSC_PER_VOICE(OSC_PER_VOICE),
        .PHASE_W(PHASE_W), .VEL_W(VEL_W)
    ) u_test_mode_ctrl (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .sample_tick_i(sample_tick_i),
        .enable_i(enable_i), .n_code_i(n_code_i),
        .test_voice_gate_o(test_voice_gate), .test_velocity_o(test_velocity),
        .test_lane_active_o(test_lane_active), .test_phase_inc_o(test_phase_inc),
        .active_n_o(active_n)
    );

    integer errors = 0;
    initial begin
        repeat (4) @(negedge clk_i);
        rst_n_i = 1'b1;
        sample_tick_i = 1'b1;
        @(negedge clk_i);
        sample_tick_i = 1'b0;
        enable_i = 1'b1;
        n_code_i = 2'b11;
        repeat (4) @(negedge clk_i);

        if ($bits(osc_sample_bus) != OSC_N*OSC_SAMPLE_W) errors = errors + 1;
        if ($bits(env_level) != POLY_TARGET*ENV_W) errors = errors + 1;
        if ($bits(test_phase_inc) != OSC_N*PHASE_W) errors = errors + 1;
        if ($bits(dry_sample) != SAMPLE_W) errors = errors + 1;

        if (osc_sample_bus !== {OSC_N*OSC_SAMPLE_W{1'b0}}) errors = errors + 1;
        if (env_level !== {POLY_TARGET*ENV_W{1'b0}}) errors = errors + 1;
        if (test_phase_inc !== {OSC_N*PHASE_W{1'b0}}) errors = errors + 1;
        if (osc_valid !== 1'b0 || dry_valid !== 1'b0 || deadline_fault !== 1'b0)
            errors = errors + 1;
        if (active_n !== 6'd0) errors = errors + 1;

        if (errors == 0)
            $display("PASS: W3b interfaces elaborate at 32x1 with safe outputs under idle inputs");
        else
            $fatal(1, "FAIL: W1-1 interface contract has %0d error(s)", errors);

        #20;
        $finish;
    end
endmodule
