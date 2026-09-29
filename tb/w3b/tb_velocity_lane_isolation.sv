`timescale 1ns/1ps
`default_nettype none

// The shared blend multiplier is TDM, but its velocity coefficient is not
// global state: every response lane must use the matching voice velocity.
module tb_velocity_lane_isolation;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [1:0] voice_active = 2'b11;
    reg [63:0] phase_inc = 64'd0;
    reg [3:0] timbre = 4'd0;
    reg [15:0] velocity = {8'd255, 8'd0};
    wire [31:0] sample_bus;
    wire osc_valid;
    integer errors = 0;

    always #10 clk = ~clk;

    oscillator_bank #(
        .POLY_TARGET(2), .OSC_PER_VOICE(1),
        .WT_DEPTH(1024), .DETUNE_ON(0),
        .VELOCITY_BLEND_EN(1)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .base_phase_inc_i(phase_inc),
        .voice_timbre_i(timbre), .voice_velocity_i(velocity),
        .vibrato_mod_i(16'sd0), .test_mode_i(1'b0),
        .test_lane_active_i(2'b00), .test_phase_inc_i(64'd0),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o()
    );

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        while (!osc_valid) @(negedge clk);
        #1;

        // BASS address 0: soft=373, hard=226.
        if ($signed(sample_bus[15:0]) !== 16'sd373) begin
            $display("FAIL: lane0 velocity=0 expected soft 373, got %0d", $signed(sample_bus[15:0]));
            errors = errors + 1;
        end
        if ($signed(sample_bus[31:16]) !== 16'sd226) begin
            $display("FAIL: lane1 velocity=255 expected hard 226, got %0d", $signed(sample_bus[31:16]));
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: TDM lanes use their own velocity blend coefficient");
        else
            $fatal(1, "FAIL: velocity leaked across TDM lanes (%0d errors)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "FAIL: tb_velocity_lane_isolation timeout");
    end
endmodule

`default_nettype wire
