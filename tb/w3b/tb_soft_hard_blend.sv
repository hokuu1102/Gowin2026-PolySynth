`timescale 1ns/1ps
`default_nettype none

// T31b contract test at the public oscillator output: velocity 0 selects the
// soft AKWF table, 255 selects hard, and 128 is the signed linear midpoint.
module tb_soft_hard_blend;
`ifdef GOWIN_PRIM_SIM
    GSR GSR(.GSRI(1'b1));
`endif
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg voice_active = 1'b1;
    reg [31:0] phase_inc = 32'd0;
    reg [1:0] timbre = 2'd0;
    reg [7:0] velocity = 8'd0;
    wire signed [15:0] sample_bus;
    wire osc_valid;
    integer errors = 0;

    always #10 clk = ~clk;

    oscillator_bank #(
        .POLY_TARGET(1), .OSC_PER_VOICE(1),
        .WT_DEPTH(1024), .DETUNE_ON(0),
        .VELOCITY_BLEND_EN(1)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .base_phase_inc_i(phase_inc),
        .voice_timbre_i(timbre), .voice_velocity_i(velocity),
        .vibrato_mod_i(16'sd0), .test_mode_i(1'b0),
        .test_lane_active_i(1'b0), .test_phase_inc_i(32'd0),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o()
    );

    task render_and_expect;
        input [7:0] vel;
        input signed [15:0] expected;
        begin
            velocity = vel;
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            while (!osc_valid) @(negedge clk);
            #1;
            if (sample_bus !== expected) begin
                $display("FAIL: velocity=%0d expected=%0d got=%0d", vel, expected, sample_bus);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // BASS addr 0: soft=373, hard=226.  Signed arithmetic gives
        // 373 + ((226-373)*128 >>> 8) = 299.
        render_and_expect(8'd0,   16'sd373);
        render_and_expect(8'd128, 16'sd299);
        render_and_expect(8'd255, 16'sd226);

        if (errors == 0)
            $display("PASS: oscillator_bank soft/hard interpolation endpoints and midpoint");
        else
            $fatal(1, "FAIL: soft/hard interpolation found %0d error(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "FAIL: tb_soft_hard_blend timeout");
    end
endmodule

`default_nettype wire

