`timescale 1ns/1ps
// T18 acceptance: hysteretic depth, bounded rate slew, and continuous LFO phase.
module tb_vibrato_lfo;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg ctrl_valid;
    reg [11:0] depth_raw, rate_raw;
    wire signed [15:0] mod;
    wire depth_active;
    wire [31:0] rate_inc, phase;

    // Small rates make the slew bound directly observable without a long run.
    vibrato_lfo #(
        .RATE_MIN_INC(32'd100), .RATE_MAX_INC(32'd200),
        .RATE_SLEW_STEP(32'd10), .CTRL_SLEW_DIV(1),
        .DEPTH_OFF(12'd64), .DEPTH_ON(12'd96)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .ctrl_valid_i(ctrl_valid),
        .depth_raw_i(depth_raw), .rate_raw_i(rate_raw), .mod_o(mod),
        .depth_active_o(depth_active), .rate_inc_dbg_o(rate_inc), .phase_dbg_o(phase)
    );

    // A fast fixed-rate instance makes one complete triangle visible in four clocks.
    wire signed [15:0] fast_mod;
    wire fast_active;
    wire [31:0] fast_rate, fast_phase;
    vibrato_lfo #(
        .RATE_MIN_INC(32'h4000_0000), .RATE_MAX_INC(32'h4000_0000),
        .RATE_SLEW_STEP(32'd1), .CTRL_SLEW_DIV(1)
    ) fast_dut (
        .clk_i(clk), .rst_n_i(rst_n), .ctrl_valid_i(ctrl_valid),
        .depth_raw_i(depth_raw), .rate_raw_i(rate_raw), .mod_o(fast_mod),
        .depth_active_o(fast_active), .rate_inc_dbg_o(fast_rate), .phase_dbg_o(fast_phase)
    );

    integer errors = 0;
    reg [31:0] phase_before;
    task chk;
        input [8*96-1:0] name;
        input cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("  FAIL: %0s", name); end
        end
    endtask
    task commit;
        begin
            @(negedge clk); ctrl_valid = 1'b1;
            @(negedge clk); ctrl_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        ctrl_valid = 1'b0;
        depth_raw  = 12'd0;
        rate_raw   = 12'd0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        depth_raw = 12'd80; commit;
        chk("dead-zone below ON threshold keeps vibrato disabled", !depth_active && mod == 0);

        depth_raw = 12'd120; commit;
        chk("depth reaches ON threshold and enables vibrato", depth_active);

        depth_raw = 12'd80; commit;
        chk("hysteresis holds enabled inside OFF..ON band", depth_active);

        depth_raw = 12'd64; commit;
        chk("depth at OFF threshold disables vibrato", !depth_active && mod == 0);

        // Full-scale rate target is 200. Bounded ramp is exactly +10 per commit.
        rate_raw = 12'hFFF;
        depth_raw = 12'd120;
        commit; chk("rate slew first step is bounded", rate_inc == 32'd110);
        commit; chk("rate slew second step is bounded", rate_inc == 32'd120);
        commit; chk("rate slew converges without a jump", rate_inc == 32'd130);

        phase_before = phase;
        commit;
        chk("rate update never clears LFO phase", phase != 32'd0 && phase != phase_before);

        // The fast instance must produce a signed, zero-centred triangle.
        depth_raw = 12'hFFF;
        rate_raw  = 12'd0;
        commit;
        // The preceding checks deliberately ran the LFO for many clocks. Start
        // this waveform assertion at a known phase, not at an assumed one.
        @(negedge clk); fast_dut.phase_q = 32'd0;
        @(negedge clk); chk("triangle positive quarter-cycle", fast_mod > 0);
        @(negedge clk); chk("triangle crosses zero at half-cycle", fast_mod == 0);
        @(negedge clk); chk("triangle negative three-quarter-cycle", fast_mod < 0);
        @(negedge clk); chk("triangle returns to zero continuously", fast_mod == 0);

        if (errors == 0) $display("PASS: vibrato LFO hysteresis, slew and phase continuity");
        else $fatal(1, "FAIL: vibrato LFO has %0d error(s)", errors);
        $finish;
    end
    initial begin #10000; $fatal(1, "FAIL: tb_vibrato_lfo timeout"); end
endmodule
