// tb_tdm_render_mixer.sv -- T56 acceptance (W3b TDM render mixer)
// ASCII only, so the console never mangles the verdict text.
`timescale 1ns/1ps

module tb_tdm_render_mixer;

    localparam integer POLY = 32;
    localparam integer OPV  = 2;
    localparam integer OSW  = 16;
    localparam integer ENVW = 16;
    localparam integer SW   = 24;
    localparam integer LANES = POLY * OPV;

    // theoretical max: LANES * 32767 = 2097088 (well below signed24 max 8388607)
    localparam signed [SW-1:0] MAXTHEO = 24'sd2097088;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    task chk;
        input [8*90-1:0] name;
        input            cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    reg                    render_start;
    reg  [LANES*OSW-1:0]   osc_bus;
    reg  [POLY*ENVW-1:0]   env_level;

    wire                   dry_valid;
    wire signed [SW-1:0]   dry_sample;
    wire                   deadline_fault;

    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(OSW),
        .ENV_W(ENVW), .SAMPLE_W(SW), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i(osc_bus), .env_level_i(env_level),
        .dry_valid_o(dry_valid), .dry_sample_o(dry_sample),
        .deadline_fault_o(deadline_fault)
    );

    // tight deadline => must set the sticky fault
    wire                   tight_valid;
    wire signed [SW-1:0]   tight_sample;
    wire                   tight_fault;
    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(OSW),
        .ENV_W(ENVW), .SAMPLE_W(SW), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(4)
    ) dut_tight (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i(osc_bus), .env_level_i(env_level),
        .dry_valid_o(tight_valid), .dry_sample_o(tight_sample),
        .deadline_fault_o(tight_fault)
    );

    task set_lane;
        input integer v;
        input integer o;
        input signed [OSW-1:0] val;
        begin osc_bus[(v*OPV + o)*OSW +: OSW] = val; end
    endtask

    task set_env;
        input integer v;
        input [ENVW-1:0] val;
        begin env_level[v*ENVW +: ENVW] = val; end
    endtask

    task clear_all;
        integer q;
        begin
            for (q = 0; q < LANES; q = q + 1) osc_bus[q*OSW +: OSW] = {OSW{1'b0}};
            for (q = 0; q < POLY; q = q + 1) env_level[q*ENVW +: ENVW] = {ENVW{1'b0}};
        end
    endtask

    task start_frame; begin
        @(negedge clk); render_start = 1'b1;
        @(negedge clk); render_start = 1'b0;
    end endtask

    // Start a frame and LATCH the sample on the dry_valid cycle.
    // K-102: dry_sample is only valid on that cycle; reading it later gets a
    // different frame's value.
    reg signed [SW-1:0] latched;
    task run_frame_get;
        output integer cycles;
        integer c;
        begin
            c = 0;
            start_frame;
            while (!dry_valid && c < 200) begin
                @(negedge clk);
                c = c + 1;
            end
            latched = dry_sample;
            cycles = c;
        end
    endtask

    // ---- saturation-capable instance -------------------------------------
    // 16-bit samples can NEVER reach signed24 saturation (64*32767 = 2_097_088
    // << 8_388_607), so M36/M37 would be uncatchable (C23: a mutant that cannot
    // change behaviour is not a valid mutant).  Use WIDE samples instead:
    // 64 lanes x 2^21 with full env => ~2^27, far above signed24.
    localparam integer WSW = 24;                 // wide sample width
    reg  [LANES*WSW-1:0] wide_bus;
    reg  [POLY*ENVW-1:0] wide_env;
    wire                 wide_valid;
    wire signed [SW-1:0] wide_sample;
    wire                 wide_fault;

    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(WSW),
        .ENV_W(ENVW), .SAMPLE_W(SW), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927)
    ) dut_wide (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i(wide_bus), .env_level_i(wide_env),
        .dry_valid_o(wide_valid), .dry_sample_o(wide_sample),
        .deadline_fault_o(wide_fault)
    );

    task wide_clear;
        integer q;
        begin
            for (q = 0; q < LANES; q = q + 1) wide_bus[q*WSW +: WSW] = {WSW{1'b0}};
            for (q = 0; q < POLY; q = q + 1) wide_env[q*ENVW +: ENVW] = {ENVW{1'b0}};
        end
    endtask

    reg signed [SW-1:0] wlatched;
    task wide_frame_get;
        output integer cycles;
        integer c;
        begin
            c = 0;
            @(negedge clk); render_start = 1'b1;
            @(negedge clk); render_start = 1'b0;
            while (!wide_valid && c < 200) begin
                @(negedge clk);
                c = c + 1;
            end
            wlatched = wide_sample;
            cycles = c;
        end
    endtask

    integer i, k, cyc, valid_count;
    reg signed [SW-1:0] s1, s2, sN, sSat;

    initial begin
        render_start = 1'b0;
        osc_bus      = {(LANES*OSW){1'b0}};
        env_level    = {(POLY*ENVW){1'b0}};

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ---- 1: deadline fault stays 0 (worst case) ----
        $display("== 1: deadline_fault stays 0 (A6) ==");
        clear_all;
        for (i = 0; i < POLY; i = i + 1) begin
            set_lane(i, 0, 16'sd32767);
            set_lane(i, 1, 16'sd32767);
            set_env(i, 16'hFFFF);
        end
        repeat (5) begin
            start_frame;
            repeat (POLY + 8) @(negedge clk);
        end
        chk("worst case 5 frames: deadline_fault stays 0", deadline_fault === 1'b0);

        // ---- 2: exactly one valid pulse per frame, fixed latency ----
        $display("== 2: one dry_valid per frame, fixed latency ==");
        valid_count = 0;
        start_frame;
        for (k = 0; k < (POLY + 20); k = k + 1) begin
            @(negedge clk);
            if (dry_valid) valid_count = valid_count + 1;
        end
        chk("exactly 1 dry_valid pulse per frame", valid_count == 1);

        run_frame_get(cyc); k = cyc;
        run_frame_get(cyc);
        chk("latency identical across two frames (determinism)", cyc == k);
        chk("latency is a fixed POLY_TARGET+3", k >= POLY && k <= (POLY + 5));

        // ---- 3: correct mixing, single voice ----
        $display("== 3: single-voice mixing ==");
        clear_all;
        set_lane(0, 0, 16'sd1000);
        set_lane(0, 1, 16'sd2000);
        set_env(0, 16'h8000);
        run_frame_get(cyc);
        s1 = latched;
        chk("3000 x 0.5 = 1500 (matches hand calc)", s1 === 24'sd1500);

        set_env(0, 16'hFFFF);
        run_frame_get(cyc);
        chk("full env => ~3000", latched >= 24'sd2998 && latched <= 24'sd3000);

        set_env(0, 16'h0000);
        run_frame_get(cyc);
        chk("zero env => 0 (silence)", latched === 24'sd0);

        clear_all;
        set_lane(0, 0, -16'sd1000);
        set_lane(0, 1, -16'sd2000);
        set_env(0, 16'hFFFF);
        run_frame_get(cyc);
        s1 = latched;
        chk("negative input => negative output (signed ok)", s1 < 24'sd0);
        chk("negative magnitude ~ 3000", s1 >= -24'sd3000 && s1 <= -24'sd2998);

        // ---- 4: multi-voice summing ----
        $display("== 4: multi-voice summing ==");
        clear_all;
        set_lane(0, 0, 16'sd1000); set_env(0, 16'hFFFF);
        run_frame_get(cyc); s1 = latched;
        set_lane(1, 0, 16'sd1000); set_env(1, 16'hFFFF);
        run_frame_get(cyc); s2 = latched;
        set_lane(2, 0, 16'sd1000); set_env(2, 16'hFFFF);
        run_frame_get(cyc); sN = latched;
        chk("2 voices => ~2x", s2 >= 24'sd1998 && s2 <= 24'sd2000);
        chk("3 voices => ~3x", sN >= 24'sd2998 && sN <= 24'sd3000);
        chk("summing is linear (monotonic)", s1 < s2 && s2 < sN);

        // ---- 5: no wrap at max input ----
        $display("== 5: max input, no wrap ==");
        clear_all;
        for (i = 0; i < POLY; i = i + 1) begin
            set_lane(i, 0, 16'sd32767);
            set_lane(i, 1, 16'sd32767);
            set_env(i, 16'hFFFF);
        end
        run_frame_get(cyc);
        sSat = latched;
        // 64 x 32767 = 2097088, far below signed24 max => no saturation needed.
        // The real risk is WRAPPING (positive turning negative).
        chk("max input stays POSITIVE (no wrap)", sSat > 24'sd0);
        // env=0xFFFF is 65535/65536 (not exactly 1.0), and >>16 truncates,
        // so the exact expected value is floor(64*32767*65535/65536) = 2097056.
        chk("max input == 2097056 (exact: env 0xFFFF is 65535/65536)",
            sSat === 24'sd2097056);
        $display("     [dbgMax] sSat=%0d MAXTHEO=%0d acc=%0d sh=%0d", sSat, MAXTHEO, dut.acc_r, dut.sh);

        clear_all;
        for (i = 0; i < POLY; i = i + 1) begin
            set_lane(i, 0, -16'sd32768);
            set_lane(i, 1, -16'sd32768);
            set_env(i, 16'hFFFF);
        end
        run_frame_get(cyc);
        sSat = latched;
        chk("min input stays NEGATIVE (no wrap)", sSat < 24'sd0);
        $display("     [dbgMin] sSat=%0d acc=%0d sh=%0d", sSat, dut.acc_r, dut.sh);
        // 64 * (-32768) = -2097152; x 65535/65536 = -2097120 exactly.
        // Note the asymmetry vs +2097056: arithmetic shift rounds toward -inf,
        // while the positive side truncates. Both are correct.
        chk("min input == -2097120 (exact arithmetic-shift result)",
            sSat === -24'sd2097120);

        // ---- 6: sticky fault ----
        $display("== 6: deadline_fault is sticky ==");
        chk("tight-deadline instance: fault set after one frame", tight_fault === 1'b1);
        repeat (3) begin
            start_frame;
            repeat (POLY + 8) @(negedge clk);
        end
        chk("sticky: fault still 1 after several frames", tight_fault === 1'b1);
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);
        chk("fault clears only on reset", tight_fault === 1'b0);

        // ---- 7: REAL saturation (wide samples) ----
        $display("== 7: real saturation via wide samples ==");
        wide_clear;
        for (i = 0; i < POLY; i = i + 1) begin
            wide_bus[(i*OPV + 0)*WSW +: WSW] = 24'sd2097151;   // +2^21-1
            wide_bus[(i*OPV + 1)*WSW +: WSW] = 24'sd2097151;
            wide_env[i*ENVW +: ENVW] = 16'hFFFF;
        end
        wide_frame_get(cyc);
        chk("wide positive overflow clamps to signed24 MAX (no wrap)",
            wlatched === 24'sd8388607);

        wide_clear;
        for (i = 0; i < POLY; i = i + 1) begin
            wide_bus[(i*OPV + 0)*WSW +: WSW] = -24'sd2097152;  // -2^21
            wide_bus[(i*OPV + 1)*WSW +: WSW] = -24'sd2097152;
            wide_env[i*ENVW +: ENVW] = 16'hFFFF;
        end
        wide_frame_get(cyc);
        chk("wide negative overflow clamps to signed24 MIN (no wrap)",
            wlatched === -24'sd8388608);

        if (errors == 0)
            $display("PASS: tdm_render_mixer acceptance (T56) - all judgements held");
        else
            $fatal(1, "FAIL: tdm_render_mixer acceptance has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
