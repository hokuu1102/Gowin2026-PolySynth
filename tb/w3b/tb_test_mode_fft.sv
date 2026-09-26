`timescale 1ns/1ps

// Integration evidence generator:
// test_mode_ctrl -> oscillator_bank -> real wavetable samples -> CSV.
// sim/test_mode_fft.ps1 independently FFTs these files and requires exactly
// 4/8/16/32 resolvable peaks.
module tb_test_mode_fft;
    localparam integer POLY = 32;
    localparam integer OSC = 2;
    localparam integer LANES = POLY * OSC;
    localparam integer PW = 32;
    localparam integer SW = 16;
    localparam integer VW = 8;
    localparam integer SAMPLE_N = 8192;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg enable = 1'b0;
    reg [1:0] n_code = 2'b00;
    always #10 clk = ~clk;

    wire [POLY-1:0] test_gate;
    wire [POLY*VW-1:0] test_velocity;
    wire [LANES-1:0] test_lane_active;
    wire [LANES*PW-1:0] test_phase_inc;
    wire [5:0] active_n;
    wire [LANES*SW-1:0] osc_sample_bus;
    wire osc_valid;
    wire [PW-1:0] phase_dbg;

    test_mode_ctrl #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OSC),
        .PHASE_W(PW), .VEL_W(VW)
    ) u_ctrl (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .enable_i(enable), .n_code_i(n_code),
        .test_voice_gate_o(test_gate), .test_velocity_o(test_velocity),
        .test_lane_active_o(test_lane_active),
        .test_phase_inc_o(test_phase_inc), .active_n_o(active_n)
    );

    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OSC),
        .PHASE_W(PW), .OSC_SAMPLE_W(SW)
    ) u_osc (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i({POLY{1'b0}}),
        .base_phase_inc_i({POLY*PW{1'b0}}),
        .timbre_id_i(2'b00), .vibrato_mod_i(16'sd0),
        .test_mode_i(enable), .test_lane_active_i(test_lane_active),
        .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(osc_sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o(phase_dbg)
    );

    integer errors = 0;
    integer fd;
    integer s;
    integer lane;
    integer sample_sum;
    reg signed [SW-1:0] lane_sample;

    task render_one_sample;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            while (osc_valid !== 1'b1) @(negedge clk);
        end
    endtask

    task capture_mode;
        input [1:0] code;
        input integer expected_n;
        input [8*96-1:0] filename;
        begin
            enable = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            n_code = code;
            rst_n = 1'b1;
            enable = 1'b1;
            #1;

            if (active_n !== expected_n) begin
                errors = errors + 1;
                $display("FAIL: mode %0d reports active_n=%0d", expected_n, active_n);
            end

            fd = $fopen(filename, "w");
            if (fd == 0) begin
                errors = errors + 1;
                $display("FAIL: cannot open %0s", filename);
            end else begin
                $fwrite(fd, "sample\n");
                for (s = 0; s < SAMPLE_N; s = s + 1) begin
                    render_one_sample();
                    sample_sum = 0;
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        if (test_lane_active[lane]) begin
                            lane_sample = osc_sample_bus[lane*SW +: SW];
                            sample_sum = sample_sum + lane_sample;
                        end
                    end
                    // Normalise by N to retain a signed 16-bit-like CSV while
                    // preserving equal relative peak amplitudes.
                    $fwrite(fd, "%0d\n", sample_sum / expected_n);
                end
                $fclose(fd);
                $display("FFT_EVIDENCE: mode=%0d samples=%0d file=%0s",
                         expected_n, SAMPLE_N, filename);
            end
        end
    endtask

    initial begin
        capture_mode(2'b00, 4,  "sim/evidence/test_mode_n4.csv");
        capture_mode(2'b01, 8,  "sim/evidence/test_mode_n8.csv");
        capture_mode(2'b10, 16, "sim/evidence/test_mode_n16.csv");
        capture_mode(2'b11, 32, "sim/evidence/test_mode_n32.csv");

        enable = 1'b0;
        if (errors == 0)
            $display("PASS: generated real Test Mode wavetable samples for FFT acceptance");
        else
            $fatal(1, "FAIL: Test Mode FFT evidence generation has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "FAIL: tb_test_mode_fft timeout");
    end
endmodule
