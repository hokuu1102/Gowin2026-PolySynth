`timescale 1ns/1ps

// T19 acceptance at the public voice_i2s_chain seam.
// One held note changes pitch without another note_on; phase, envelope and
// externally decoded I2S must remain consistent with a continuous-phase golden.
module tb_pitch_shift_accept;
    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer SAMPLE_W = 24;
    // Deliberately not a multiple of either waveform period: a reset-to-zero
    // mutant must not be able to masquerade as a natural phase wrap.
    localparam integer RUN_A = 301;
    localparam integer RUN_B = 320;
    localparam [31:0] INC_A = 32'd67_108_864;   // fs / 64
    localparam [31:0] INC_B = 32'd134_217_728;  // fs / 32
    localparam integer SUSTAIN_LEVEL = 65_025;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;
    reg note_on = 1'b0;
    reg note_off = 1'b0;
    reg [31:0] note_inc = INC_A;

    wire hp_bck, hp_ws, hp_din, tick_audio, voice_done;
    wire signed [23:0] sample_dbg;
    wire [31:0] phase_acc, phase_inc;

    voice_i2s_chain #(
        .CLK_PER_SAMPLE(CLK_PER_SAMPLE),
        .ATTACK_STEP(65_535), .DECAY_STEP(65_535),
        .SUSTAIN_Q8(255), .RELEASE_STEP(65_535)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .note_on_i(note_on), .note_off_i(note_off), .note_inc_i(note_inc),
        .HP_BCK(hp_bck), .HP_WS(hp_ws), .HP_DIN(hp_din),
        .tick_audio_o(tick_audio), .sample_dbg_o(sample_dbg),
        .voice_done_o(voice_done), .phase_acc_dbg_o(phase_acc),
        .phase_inc_dbg_o(phase_inc)
    );

    wire signed [23:0] rx_l, rx_r, recon_l, recon_r;
    wire rx_valid_l, rx_valid_r;
    i2s_rx_model #(
        .SAMPLE_W(24), .DATA_BITS(16), .SLOT_BITS(32),
        .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0), .RECON_FILTER(0)
    ) u_rx (
        .clk(clk), .rst_n(rst_n), .bck(hp_bck), .ws(hp_ws), .din(hp_din),
        .sample_l(rx_l), .sample_r(rx_r), .valid_l(rx_valid_l),
        .valid_r(rx_valid_r), .recon_l(recon_l), .recon_r(recon_r)
    );

    wire [31:0] a7_errors;
    chk_phase_advance #(.W(32), .NAME("T19.voice.phase_acc")) u_a7 (
        .clk(clk), .rst_n(rst_n), .tick(tick_audio),
        .acc(phase_acc), .inc(phase_inc),
        .jump_ok(note_on | note_off), .err_cnt(a7_errors)
    );

    reg signed [15:0] wavetable [0:511];
    reg signed [23:0] expected_frame [0:RUN_A+RUN_B+64];
    reg signed [15:0] decoded_l [0:RUN_A+RUN_B+64];
    reg [8:0] golden_addr_q [0:RUN_A+RUN_B+64];
    integer expected_count = 0;
    integer golden_tick_count = 0;
    integer golden_done_count = 0;
    integer rx_l_count = 0;
    integer rx_r_count = 0;
    integer point_errors = 0;
    integer golden_errors = 0;
    integer golden_checks = 0;
    integer xz_errors = 0;
    integer note_on_count = 0;
    integer transition_rx = 0;
    integer fd_before, fd_after;
    integer addr;
    integer fd_count = 0;
    integer fd_csv_a, fd_csv_b;
    integer csv_i;
    reg [31:0] phase_before;
    reg signed [32:0] product_raw;
    reg signed [32:0] product_zero;
    reg signed [16:0] scaled;

    task automatic wait_frames(input integer count);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(posedge clk);
                while (!tick_audio) @(posedge clk);
            end
        end
    endtask

    initial begin
        $readmemh("rtl/w3b/rom/sine_512x16.hex", wavetable);
        fd_csv_a = $fopen("sim/evidence/pitch_before.csv", "w");
        fd_csv_b = $fopen("sim/evidence/pitch_after.csv", "w");
        $fdisplay(fd_csv_a, "# T19 before pitch update; fs=48828.125; expected=762.939453125");
        $fdisplay(fd_csv_b, "# T19 after pitch update; fs=48828.125; expected=1525.87890625");
        $dumpfile("build/sim/tb_pitch_shift_accept/tb_pitch_shift_accept.vcd");
        $dumpvars(0, tb_pitch_shift_accept);

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);
        note_on = 1'b1;
        note_on_count = note_on_count + 1;
        @(negedge clk);
        note_on = 1'b0;

        wait_frames(RUN_A);
        @(negedge clk);
        phase_before = phase_acc;
        fd_before = fd_count;
        transition_rx = rx_l_count;
        note_inc = INC_B; // No second note_on and no legal phase restart.
        wait_frames(RUN_B);
        fd_after = fd_count;

        repeat (8) @(posedge clk);
        for (csv_i = 32; csv_i < transition_rx-16; csv_i = csv_i + 1)
            $fdisplay(fd_csv_a, "%0d", $signed(decoded_l[csv_i]));
        for (csv_i = transition_rx+16; csv_i < rx_l_count-16; csv_i = csv_i + 1)
            $fdisplay(fd_csv_b, "%0d", $signed(decoded_l[csv_i]));
        $fclose(fd_csv_a);
        $fclose(fd_csv_b);

        if (note_on_count != 1) begin
            $display("FAIL: T19 retriggered note_on (%0d events)", note_on_count);
            point_errors = point_errors + 1;
        end
        if (phase_before == 0) begin
            $display("FAIL: pitch update was applied at zero phase; test cannot prove continuity");
            point_errors = point_errors + 1;
        end
        if (fd_before < RUN_A-4 || (fd_after-fd_before) < RUN_B-4) begin
            $display("FAIL: frame_done stopped across pitch update before=%0d after_delta=%0d", fd_before, fd_after-fd_before);
            point_errors = point_errors + 1;
        end
        if (a7_errors != 0)
            $display("FAIL: A7 found %0d phase discontinuities during held-note pitch update", a7_errors);
        if (golden_errors != 0 || golden_checks < RUN_A+RUN_B-16)
            $display("FAIL: continuous-phase golden checks=%0d errors=%0d", golden_checks, golden_errors);
        if (point_errors != 0)
            $display("FAIL: external I2S point mismatches=%0d", point_errors);
        if (xz_errors != 0)
            $display("FAIL: external I2S/debug X/Z observations=%0d", xz_errors);

        $display("T19_ACCEPT note_on=%0d phase_before=%0d A7=%0d golden=%0d/%0d i2s_errors=%0d xz=%0d",
                 note_on_count, phase_before, a7_errors, golden_checks-golden_errors,
                 golden_checks, point_errors, xz_errors);
        if (a7_errors == 0 && golden_errors == 0 &&
            golden_checks >= RUN_A+RUN_B-16 && point_errors == 0 && xz_errors == 0)
            $display("PASS: held-note pitch update preserves phase/envelope and external I2S continuity");
        else
            $fatal(1, "FAIL: T19 phase-continuous pitch acceptance failed");
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && note_on)
            if (note_on_count > 1) point_errors = point_errors + 1;

        if (rst_n && tick_audio && expected_count < RUN_A+RUN_B+64) begin
            expected_frame[expected_count] = sample_dbg;
            expected_count = expected_count + 1;
            golden_addr_q[golden_tick_count] = phase_acc[31:23];
            golden_tick_count = golden_tick_count + 1;
        end

        if (rst_n && voice_done) begin
            fd_count = fd_count + 1;
            addr = golden_addr_q[golden_done_count];
            golden_done_count = golden_done_count + 1;
            if (fd_count > 6) begin
                product_raw = $signed(wavetable[addr]) * SUSTAIN_LEVEL;
                product_zero = product_raw[32] ? product_raw + 33'sd65535 : product_raw;
                scaled = product_zero >>> 16;
                golden_checks = golden_checks + 1;
                if (sample_dbg[23:8] !== scaled[15:0]) begin
                    golden_errors = golden_errors + 1;
                    if (golden_errors <= 4)
                        $display("GOLDEN_MISMATCH frame=%0d phase=%0d inc=%0d addr=%0d got=%0d expected=%0d",
                                 fd_count, phase_acc, phase_inc, addr,
                                 $signed(sample_dbg[23:8]), $signed(scaled[15:0]));
                end
            end
        end

        if (rst_n && rx_valid_l) begin
            if ($isunknown(rx_l)) xz_errors = xz_errors + 1;
            if (rx_l !== expected_frame[rx_l_count]) point_errors = point_errors + 1;
            decoded_l[rx_l_count] = rx_l[23:8];
            rx_l_count = rx_l_count + 1;
        end
        if (rst_n && rx_valid_r) begin
            if ($isunknown(rx_r)) xz_errors = xz_errors + 1;
            if (rx_r !== expected_frame[rx_r_count]) point_errors = point_errors + 1;
            rx_r_count = rx_r_count + 1;
        end
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_pitch_shift_accept timeout");
    end
endmodule
