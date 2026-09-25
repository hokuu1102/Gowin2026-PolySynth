`timescale 1ns/1ps

module tb_test_mode_ctrl;
    localparam integer POLY = 32;
    localparam integer OSC  = 2;
    localparam integer PW   = 32;
    localparam integer VW   = 8;
    localparam integer LANES = POLY * OSC;
    localparam integer OUT_W = POLY + POLY*VW + LANES + LANES*PW + 6;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg enable = 1'b0;
    reg [1:0] n_code = 2'b00;
    always #10 clk = ~clk;

    wire [POLY-1:0] voice_gate;
    wire [POLY*VW-1:0] velocity;
    wire [LANES-1:0] lane_active;
    wire [LANES*PW-1:0] phase_inc;
    wire [5:0] active_n;
    wire [OUT_W-1:0] all_outputs = {
        voice_gate, velocity, lane_active, phase_inc, active_n
    };
    wire [31:0] x_errors;

    test_mode_ctrl #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OSC),
        .PHASE_W(PW), .VEL_W(VW)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .enable_i(enable), .n_code_i(n_code),
        .test_voice_gate_o(voice_gate), .test_velocity_o(velocity),
        .test_lane_active_o(lane_active), .test_phase_inc_o(phase_inc),
        .active_n_o(active_n)
    );

    chk_xprop #(.W(OUT_W), .NAME("test_mode outputs")) u_xprop (
        .clk(clk), .rst_n(rst_n), .sig(all_outputs), .err_cnt(x_errors)
    );

    integer errors = 0;
    integer i;
    integer j;
    integer k;
    integer gate_count;
    integer lane_count;
    reg [PW-1:0] pi;
    reg [PW-1:0] pj;

    task check;
        input [8*96-1:0] label;
        input condition;
        begin
            if (condition) $display("  ok  : %0s", label);
            else begin
                errors = errors + 1;
                $display("  FAIL: %0s", label);
            end
        end
    endtask

    task check_mode;
        input [1:0] code;
        input integer expected_n;
        begin
            n_code = code;
            #1;
            count_active();
            check("active_n matches requested mode", active_n == expected_n);
            check("gate popcount matches active_n", gate_count == expected_n);
            check("lane popcount matches active_n", lane_count == expected_n);

            for (i = 0; i < POLY; i = i + 1) begin
                if (i < expected_n) begin
                    if (voice_gate[i] !== 1'b1 ||
                        velocity[i*VW +: VW] !== {VW{1'b1}} ||
                        lane_active[i*OSC] !== 1'b1 ||
                        lane_active[i*OSC+1] !== 1'b0 ||
                        phase_inc[(i*OSC)*PW +: PW] == 0 ||
                        phase_inc[(i*OSC+1)*PW +: PW] != 0) begin
                        errors = errors + 1;
                        $display("  FAIL: selected voice %0d gate/velocity/lane/config", i);
                    end
                end else begin
                    if (voice_gate[i] !== 1'b0 ||
                        velocity[i*VW +: VW] != 0 ||
                        lane_active[i*OSC +: OSC] != 0 ||
                        phase_inc[(i*OSC)*PW +: OSC*PW] != 0) begin
                        errors = errors + 1;
                        $display("  FAIL: inactive voice %0d is not fully zero", i);
                    end
                end
            end

            // Independent frequency contract: every selected fundamental is
            // unique and none is a low-order (2x..16x) harmonic of another.
            for (i = 0; i < expected_n; i = i + 1) begin
                pi = phase_inc[(i*OSC)*PW +: PW];
                for (j = i + 1; j < expected_n; j = j + 1) begin
                    pj = phase_inc[(j*OSC)*PW +: PW];
                    if (pi == pj) begin
                        errors = errors + 1;
                        $display("  FAIL: voices %0d/%0d share phase_inc %08h", i, j, pi);
                    end
                    for (k = 2; k <= 16; k = k + 1)
                        if (pj == k*pi || pi == k*pj) begin
                            errors = errors + 1;
                            $display("  FAIL: voices %0d/%0d are harmonic ratio %0d", i, j, k);
                        end
                end
            end
        end
    endtask

    task count_active;
        begin
            gate_count = 0;
            lane_count = 0;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_gate[i] === 1'b1) gate_count = gate_count + 1;
            for (i = 0; i < LANES; i = i + 1)
                if (lane_active[i] === 1'b1) lane_count = lane_count + 1;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        check("reset holds every output at zero", all_outputs === {OUT_W{1'b0}});

        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        check("enable=0 bypasses every output", all_outputs === {OUT_W{1'b0}});

        enable = 1'b1;
        sample_tick = 1'b1;
        @(negedge clk);
        sample_tick = 1'b0;
        @(negedge clk);

        check_mode(2'b00, 4);
        check_mode(2'b01, 8);
        check_mode(2'b10, 16);
        check_mode(2'b11, 32);

        check("first FFT-bin-aligned increment is exact",
              phase_inc[0*PW +: PW] == 32'h0280_0000);
        check("second FFT-bin-aligned increment is exact",
              phase_inc[(1*OSC)*PW +: PW] == 32'h0628_0000);
        check("highest frequency remains below Nyquist",
              phase_inc[(31*OSC)*PW +: PW] == 32'h73D8_0000 &&
              !phase_inc[(31*OSC)*PW + PW-1]);

        // Switch straight from the maximum mode to the minimum without a
        // reset or tick: no stale gate/lane/config may survive.
        check_mode(2'b00, 4);
        check("32-to-4 switch leaves no stale fifth voice",
              voice_gate[4] == 0 && lane_active[8 +: 2] == 0 &&
              phase_inc[8*PW +: 2*PW] == 0);

        enable = 1'b0;
        #1;
        check("disable after 32/4 switching clears every output",
              all_outputs === {OUT_W{1'b0}});

        enable = 1'b1;
        n_code = 2'b11;
        rst_n = 1'b0;
        #1;
        check("reset wins even while enable is high", all_outputs === {OUT_W{1'b0}});
        rst_n = 1'b1;
        #1;
        check("no output X/Z after reset", x_errors == 0);

        if (errors == 0)
            $display("PASS: test_mode_ctrl 4/8/16/32 contract");
        else
            $fatal(1, "FAIL: test_mode_ctrl contract has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "FAIL: tb_test_mode_ctrl timeout");
    end
endmodule
