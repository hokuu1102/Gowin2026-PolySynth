`timescale 1ns/1ps
`default_nettype none

// Regression for the board failure where a fully pressed key changed every
// timbre into a sustained coarse/saw-like sound.  Performance velocity owns
// loudness in envelope_bank; it must not also rewrite oscillator tone colour.
module tb_velocity_tone_decoupling;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [7:0] velocity = 8'd64;
    wire signed [15:0] sample_bus;
    wire osc_valid;
    integer errors = 0;

    always #10 clk = ~clk;

    oscillator_bank #(
        .POLY_TARGET(1), .OSC_PER_VOICE(1),
        .WT_DEPTH(1024), .DETUNE_ON(0),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(1'b1), .base_phase_inc_i(32'd0),
        .voice_timbre_i(2'd0), .voice_velocity_i(velocity),
        .vibrato_mod_i(16'sd0), .test_mode_i(1'b0),
        .test_lane_active_i(1'b0), .test_phase_inc_i(32'd0),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o()
    );

    task render_and_expect_soft;
        input [7:0] vel;
        begin
            velocity = vel;
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            while (!osc_valid) @(negedge clk);
            #1;
            // BASS address 0, soft table = 373.
            if (sample_bus !== 16'sd373) begin
                $display("FAIL: velocity=%0d changed fixed-soft tone, got %0d expected 373",
                         vel, sample_bus);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        render_and_expect_soft(8'd64);
        render_and_expect_soft(8'd200);

        if (errors == 0)
            $display("PASS: performance velocity changes loudness only, not oscillator tone");
        else
            $fatal(1, "FAIL: velocity/tone decoupling found %0d error(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "FAIL: tb_velocity_tone_decoupling timeout");
    end
endmodule

`default_nettype wire
