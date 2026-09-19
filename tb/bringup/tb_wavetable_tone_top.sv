`timescale 1ns/1ps

// External-pin seam test for the dedicated Dock wavetable-tone bring-up top.
module tb_wavetable_tone_top;
    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer N_FRAMES = 620;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;  // 50 MHz

    wire HP_BCK;
    wire HP_WS;
    wire HP_DIN;
    wire PA_EN_n;
    wire led_heartbeat;

    wavetable_tone_top #(
        .PA_ON_DELAY   (32),
        .HEARTBEAT_DIV (64)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_heartbeat)
    );

    wire signed [23:0] rx_l;
    wire signed [23:0] rx_r;
    wire signed [23:0] recon_l;
    wire signed [23:0] recon_r;
    wire               rx_vl;
    wire               rx_vr;

    i2s_rx_model #(
        .SAMPLE_W  (24),
        .DATA_BITS (16),
        .SLOT_BITS (32),
        .JUSTIFY   (1),
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .bck      (HP_BCK),
        .ws       (HP_WS),
        .din      (HP_DIN),
        .sample_l (rx_l),
        .sample_r (rx_r),
        .valid_l  (rx_vl),
        .valid_r  (rx_vr),
        .recon_l  (recon_l),
        .recon_r  (recon_r)
    );

    integer errors = 0;
    integer cycles = 0;
    integer left_count = 0;
    integer nonzero_count = 0;
    integer stereo_mismatch = 0;
    integer x_count = 0;
    integer din_toggle_count = 0;
    integer heartbeat_toggle_count = 0;
    integer pa_fall_count = 0;
    integer last_bck_rise = -1;
    integer bck_gap_min = 1 << 30;
    integer bck_gap_max = 0;
    integer last_ws_rise = -1;
    integer ws_gap_min = 1 << 30;
    integer ws_gap_max = 0;
    integer crossing_count = 0;
    integer last_crossing_sample = -1;
    integer period_sum = 0;
    integer period_min = 1 << 30;
    integer period_max = 0;
    integer average_period;
    integer measured_hz;

    reg bck_d = 1'b0;
    reg ws_d = 1'b0;
    reg din_d = 1'b0;
    reg heartbeat_d = 1'b0;
    reg pa_d = 1'b1;
    reg signed [23:0] previous_left = 24'sd0;
    reg signed [23:0] frame_left = 24'sd0;

    always @(posedge clk) begin
        cycles = cycles + 1;

        if (rst_n) begin
            if ((^{HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_heartbeat}) === 1'bx)
                x_count = x_count + 1;

            if (HP_BCK && !bck_d) begin
                if (last_bck_rise >= 0) begin
                    if ((cycles - last_bck_rise) < bck_gap_min)
                        bck_gap_min = cycles - last_bck_rise;
                    if ((cycles - last_bck_rise) > bck_gap_max)
                        bck_gap_max = cycles - last_bck_rise;
                end
                last_bck_rise = cycles;
            end

            if (HP_WS && !ws_d) begin
                if (last_ws_rise >= 0) begin
                    if ((cycles - last_ws_rise) < ws_gap_min)
                        ws_gap_min = cycles - last_ws_rise;
                    if ((cycles - last_ws_rise) > ws_gap_max)
                        ws_gap_max = cycles - last_ws_rise;
                end
                last_ws_rise = cycles;
            end

            if (HP_DIN != din_d)
                din_toggle_count = din_toggle_count + 1;
            if (led_heartbeat != heartbeat_d)
                heartbeat_toggle_count = heartbeat_toggle_count + 1;
            if (pa_d && !PA_EN_n)
                pa_fall_count = pa_fall_count + 1;

            if (rx_vl) begin
                left_count = left_count + 1;
                frame_left = rx_l;
                if (rx_l != 24'sd0)
                    nonzero_count = nonzero_count + 1;

                // Ignore startup samples, then measure positive zero crossings.
                if (left_count > 16 && previous_left <= 0 && rx_l > 0) begin
                    if (last_crossing_sample >= 0) begin
                        period_sum = period_sum + (left_count - last_crossing_sample);
                        if ((left_count - last_crossing_sample) < period_min)
                            period_min = left_count - last_crossing_sample;
                        if ((left_count - last_crossing_sample) > period_max)
                            period_max = left_count - last_crossing_sample;
                    end
                    last_crossing_sample = left_count;
                    crossing_count = crossing_count + 1;
                end
                previous_left = rx_l;
            end

            if (rx_vr && rx_r !== frame_left)
                stereo_mismatch = stereo_mismatch + 1;
        end

        bck_d = HP_BCK;
        ws_d = HP_WS;
        din_d = HP_DIN;
        heartbeat_d = led_heartbeat;
        pa_d = PA_EN_n;
    end

    initial begin
        $dumpfile("build/sim/wavetable_tone_top/tb_wavetable_tone_top.vcd");
        $dumpvars(0, tb_wavetable_tone_top);

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (CLK_PER_SAMPLE * N_FRAMES) @(posedge clk);
        #1;

        if (crossing_count > 1) begin
            average_period = period_sum / (crossing_count - 1);
            measured_hz = 48_828 / average_period;
        end else begin
            average_period = 0;
            measured_hz = 0;
        end

        $display("WAVETABLE_TONE frames=%0d nonzero=%0d crossings=%0d period=%0d..%0d avg=%0d measured_hz=%0d",
                 left_count, nonzero_count, crossing_count, period_min, period_max,
                 average_period, measured_hz);
        $display("WAVETABLE_TONE bck_gap=%0d..%0d ws_gap=%0d..%0d din_toggles=%0d pa_falls=%0d",
                 bck_gap_min, bck_gap_max, ws_gap_min, ws_gap_max,
                 din_toggle_count, pa_fall_count);

        if (left_count < N_FRAMES - 4) begin
            $display("FAIL: too few decoded left samples: %0d", left_count);
            errors = errors + 1;
        end
        if (nonzero_count < N_FRAMES / 2) begin
            $display("FAIL: decoded audio is mostly zero");
            errors = errors + 1;
        end
        if (crossing_count < 4 || measured_hz < 430 || measured_hz > 450) begin
            $display("FAIL: decoded tone is not approximately 440 Hz");
            errors = errors + 1;
        end
        if (period_min < 109 || period_max > 113) begin
            $display("FAIL: tone period is outside the deterministic 440 Hz bounds");
            errors = errors + 1;
        end
        if (bck_gap_min != 16 || bck_gap_max != 16) begin
            $display("FAIL: HP_BCK period is not exactly 16 system clocks");
            errors = errors + 1;
        end
        if (ws_gap_min != 1024 || ws_gap_max != 1024) begin
            $display("FAIL: HP_WS period is not exactly 1024 system clocks");
            errors = errors + 1;
        end
        if (din_toggle_count < 100) begin
            $display("FAIL: HP_DIN does not show enough activity");
            errors = errors + 1;
        end
        if (stereo_mismatch != 0) begin
            $display("FAIL: left/right mono copies differ %0d time(s)", stereo_mismatch);
            errors = errors + 1;
        end
        if (pa_fall_count != 1 || PA_EN_n !== 1'b0) begin
            $display("FAIL: PA_EN_n must make exactly one falling edge and stay low");
            errors = errors + 1;
        end
        if (heartbeat_toggle_count < 2) begin
            $display("FAIL: heartbeat did not toggle");
            errors = errors + 1;
        end
        if (x_count != 0) begin
            $display("FAIL: external outputs contained X/Z for %0d cycle(s)", x_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: Dock wavetable tone top outputs deterministic 440 Hz mono audio");
        else
            $fatal(1, "FAIL: wavetable tone top found %0d error(s)", errors);

        #20;
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_wavetable_tone_top timeout");
    end
endmodule
