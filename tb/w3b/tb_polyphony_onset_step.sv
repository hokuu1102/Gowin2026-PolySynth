`timescale 1ns/1ps
`default_nettype none

// Regression for the audible click when a second/third note is pressed.
// A newly allocated voice whose envelope is still zero contributes no audio,
// so merely asserting voice_active for it must not step the current mix.
module tb_polyphony_onset_step;
    localparam integer POLY = 32;
    localparam integer OPV  = 2;
    localparam integer OSW  = 16;
    localparam integer ENVW = 16;
    localparam integer SW   = 24;
    localparam integer LANES = POLY * OPV;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg render_start = 1'b0;
    reg [LANES*OSW-1:0] osc_bus = {(LANES*OSW){1'b0}};
    reg [POLY*ENVW-1:0] env_level = {(POLY*ENVW){1'b0}};
    reg [POLY-1:0] voice_active = {POLY{1'b0}};

    wire dry_valid;
    wire signed [SW-1:0] dry_sample;
    wire deadline_fault;
    wire [$clog2(POLY):0] n_active;

    integer errors = 0;
    integer cyc;
    integer k;
    integer delta;
    integer max_step;
    integer observed_max_step;
    reg signed [SW-1:0] sample_q;
    reg signed [SW-1:0] baseline;
    reg signed [SW-1:0] previous;

    always #10 clk = ~clk;

    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV),
        .OSC_SAMPLE_W(OSW), .ENV_W(ENVW), .SAMPLE_W(SW),
        .CLK_PER_SAMPLE(1024), .RENDER_DEADLINE_CYC(927)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i(osc_bus), .env_level_i(env_level),
        .voice_active_i(voice_active),
        .dry_valid_o(dry_valid), .dry_sample_o(dry_sample),
        .deadline_fault_o(deadline_fault), .n_active_o(n_active)
    );

    task set_lane;
        input integer v;
        input integer o;
        input signed [OSW-1:0] val;
        begin
            osc_bus[(v*OPV + o)*OSW +: OSW] = val;
        end
    endtask

    task set_env;
        input integer v;
        input [ENVW-1:0] val;
        begin
            env_level[v*ENVW +: ENVW] = val;
        end
    endtask

    task run_frame;
        begin
            @(negedge clk); render_start = 1'b1;
            @(negedge clk); render_start = 1'b0;
            cyc = 0;
            while (!dry_valid && cyc < 200) begin
                @(negedge clk);
                cyc = cyc + 1;
            end
            if (!dry_valid) begin
                $display("FAIL: mixer produced no dry_valid");
                errors = errors + 1;
            end
            sample_q = dry_sample;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // Voice 0 is already sustaining at a constant non-zero sample.
        set_lane(0, 0, 16'sd3000);
        set_lane(0, 1, 16'sd3000);
        set_env(0, 16'hFFFF);
        voice_active[0] = 1'b1;

        // Drain the normalization/output pipeline, then capture the baseline.
        for (k = 0; k < 6; k = k + 1)
            run_frame;
        baseline = sample_q;
        previous = sample_q;
        max_step = (baseline < 0 ? -baseline : baseline) / 32 + 1;
        observed_max_step = 0;
        if (baseline == 0) begin
            $display("FAIL: invalid zero baseline");
            errors = errors + 1;
        end

        // Allocate voice 1, exactly as note_on does, but keep its attack
        // envelope at zero.  It contributes no sample yet.
        voice_active[1] = 1'b1;
        set_env(1, 16'h0000);
        set_lane(1, 0, -16'sd12000);
        set_lane(1, 1,  16'sd12000);

        // A de-zippered gain may move gradually.  Bound each audio-sample
        // step to 1/32 (3.125%) of the sustaining level; the broken direct
        // 64->45 transition is about 30% and must fail this assertion.
        for (k = 0; k < 24; k = k + 1) begin
            run_frame;
            delta = sample_q - previous;
            if (delta < 0) delta = -delta;
            if (delta > observed_max_step) observed_max_step = delta;
            if (delta > max_step) begin
                $display("FAIL: note_on mix step too large: frame=%0d prev=%0d got=%0d delta=%0d limit=%0d n_active=%0d",
                         k, previous, sample_q, delta, max_step, n_active);
                errors = errors + 1;
            end
            previous = sample_q;
        end

        // Repeat for 2->3 voices; this used to create a second control step.
        voice_active[2] = 1'b1;
        set_env(2, 16'h0000);
        set_lane(2, 0, 16'sd16000);
        set_lane(2, 1, 16'sd16000);
        for (k = 0; k < 12; k = k + 1) begin
            run_frame;
            delta = sample_q - previous;
            if (delta < 0) delta = -delta;
            if (delta > observed_max_step) observed_max_step = delta;
            if (delta > max_step) begin
                $display("FAIL: third-note mix step too large: frame=%0d prev=%0d got=%0d delta=%0d limit=%0d n_active=%0d",
                         k, previous, sample_q, delta, max_step, n_active);
                errors = errors + 1;
            end
            previous = sample_q;
        end

        $display("INFO: max note_on step=%0d, allowed=%0d, baseline=%0d",
                 observed_max_step, max_step, baseline);

        if (deadline_fault !== 1'b0) begin
            $display("FAIL: unexpected deadline fault");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: polyphony normalization is de-zippered at note_on");
        else
            $fatal(1, "FAIL: polyphony onset step reproduced (%0d mismatching frames)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "FAIL: tb_polyphony_onset_step timeout");
    end
endmodule

`default_nettype wire
