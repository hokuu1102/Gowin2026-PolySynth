`timescale 1ns/1ps
`default_nettype none

// tb_osc_ram_equiv -- prove the BSRAM osc-sample read path is cycle-exact and
// bit-exact against the legacy path.
//
//   REF  : oscillator_bank(OSC_RAM_EN=0) + tdm_render_mixer(OSC_SRC_RAM=0)
//          (64x16 FF array sample_bus_r + combinational 64:1 lane mux)
//   DUT  : oscillator_bank(OSC_RAM_EN=1) + tdm_render_mixer(OSC_SRC_RAM=1)
//          (BSRAM with two registered read ports; vs_s taken straight from vs_c)
//
// Both chains are fed identical stimulus and must produce, every single cycle:
//   * the same osc_valid timing
//   * the same dry_valid / dry_sample / deadline_fault / n_active
//
// Non-vacuity guards (a passing probe must be provably doing something):
//   * the DUT bank's osc_sample_bus_o must stay constant 0 -- that is only true
//     when the generate really took the BSRAM branch (not the legacy FF branch)
//   * the DUT must emit at least MIN_SAMPLES nonzero dry samples
//   * the DUT output must stay below the soft-knee limiter, so a real bit
//     difference can never be hidden by saturation
module tb_osc_ram_equiv;

    localparam integer POLY   = 32;              // production profile
    localparam integer OPV    = 2;               // production profile
    localparam integer LANES  = POLY * OPV;
    localparam integer SW     = 16;
    localparam integer RD_AW  = $clog2(LANES);
    localparam integer FRAMES = 100;
    localparam integer FWAIT  = 200;
    localparam integer MIN_SAMPLES = 80;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;

    reg [POLY-1:0]    active;
    reg [POLY*32-1:0] phase_inc;
    reg [POLY*2-1:0]  timbre;
    reg [POLY*8-1:0]  velocity;
    reg [POLY*16-1:0] env_level;
    reg               use_delayed_start;

    // ---- REF chain ------------------------------------------------------
    wire [LANES*SW-1:0] bus_ff;
    wire                valid_ff;
    wire                dry_valid_ff;
    wire signed [23:0]  dry_sample_ff;
    wire                deadline_ff;
    wire [5:0]          n_active_ff;

    // ---- DUT chain ------------------------------------------------------
    wire [LANES*SW-1:0] bus_ram;       // must stay constant 0 (BSRAM branch)
    wire                valid_ram;
    wire [RD_AW-1:0]    ram_rd_addr;   // driven by the DUT mixer
    wire [SW-1:0]       ram_rd_d0;
    wire [SW-1:0]       ram_rd_d1;
    wire                dry_valid_ram;
    wire signed [23:0]  dry_sample_ram;
    wire                deadline_ram;
    wire [5:0]          n_active_ram;

    // production wiring: render_start = ob_valid delayed by 32 cycles
    reg [31:0] start_dly;
    wire       delayed_start = start_dly[31];
    wire       render_start  = use_delayed_start ? delayed_start : sample_tick;

    always #10 clk = ~clk;

    // =====================================================================
    // REF: legacy FF array + combinational lane read
    // =====================================================================
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(32),
        .OSC_SAMPLE_W(SW), .WT_DEPTH(1024),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .OSC_RAM_EN(0)
    ) u_bank_ff (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(active), .voice_phase_rst_i({POLY{1'b0}}),
        .base_phase_inc_i(phase_inc), .voice_timbre_i(timbre),
        .voice_velocity_i(velocity), .voice_drum_i({POLY{1'b0}}),
        .drum_cls_i({POLY*2{1'b0}}), .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0), .test_lane_active_i({LANES{1'b0}}),
        .test_phase_inc_i({LANES*32{1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(bus_ff), .osc_valid_o(valid_ff),
        .phase_acc_dbg_o(),
        .osc_rd_addr0_i({RD_AW{1'b0}}), .osc_rd_addr1_i({RD_AW{1'b0}}),
        .osc_rd_data0_o(), .osc_rd_data1_o()
    );

    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(SW),
        .ENV_W(16), .SAMPLE_W(24), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927), .RESERVED_N(0), .NORM_GAIN_STEP(0),
        .OUTPUT_HEADROOM_SH(1), .OSC_SRC_RAM(0)
    ) u_mix_ff (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i(bus_ff), .env_level_i(env_level),
        .voice_active_i(active),
        .dry_valid_o(dry_valid_ff), .dry_sample_o(dry_sample_ff),
        .deadline_fault_o(deadline_ff), .n_active_o(n_active_ff),
        .osc_rd_addr_o(), .osc_rd_data0_i({SW{1'b0}}),
        .osc_rd_data1_i({SW{1'b0}})
    );

    // =====================================================================
    // DUT: BSRAM with two registered read ports
    // =====================================================================
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(32),
        .OSC_SAMPLE_W(SW), .WT_DEPTH(1024),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .OSC_RAM_EN(1)
    ) u_bank_ram (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(active), .voice_phase_rst_i({POLY{1'b0}}),
        .base_phase_inc_i(phase_inc), .voice_timbre_i(timbre),
        .voice_velocity_i(velocity), .voice_drum_i({POLY{1'b0}}),
        .drum_cls_i({POLY*2{1'b0}}), .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0), .test_lane_active_i({LANES{1'b0}}),
        .test_phase_inc_i({LANES*32{1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(bus_ram), .osc_valid_o(valid_ram),
        .phase_acc_dbg_o(),
        .osc_rd_addr0_i(ram_rd_addr), .osc_rd_addr1_i(ram_rd_addr + 1'b1),
        .osc_rd_data0_o(ram_rd_d0), .osc_rd_data1_o(ram_rd_d1)
    );

    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(SW),
        .ENV_W(16), .SAMPLE_W(24), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927), .RESERVED_N(0), .NORM_GAIN_STEP(0),
        .OUTPUT_HEADROOM_SH(1), .OSC_SRC_RAM(1)
    ) u_mix_ram (
        .clk_i(clk), .rst_n_i(rst_n), .render_start_i(render_start),
        .osc_sample_bus_i({LANES*SW{1'b0}}), .env_level_i(env_level),
        .voice_active_i(active),
        .dry_valid_o(dry_valid_ram), .dry_sample_o(dry_sample_ram),
        .deadline_fault_o(deadline_ram), .n_active_o(n_active_ram),
        .osc_rd_addr_o(ram_rd_addr), .osc_rd_data0_i(ram_rd_d0),
        .osc_rd_data1_i(ram_rd_d1)
    );

    // =====================================================================
    // Stimulus
    // =====================================================================
    integer v;
    integer errors = 0;
    integer compared = 0;
    integer nonzero = 0;
    integer max_abs = 0;
    integer abs_now;
    integer case_id = 0;

    // Every voice gets its own frequency and its own envelope level, so all
    // 64 lanes carry distinct, time-varying data.  An address/lane mix-up in
    // any part of the 0..LANES-1 range therefore changes dry_sample.
    initial begin
        active    = {POLY{1'b1}};
        timbre    = {POLY*2{1'b0}};
        velocity  = {POLY*8{1'd0}};
        phase_inc = {POLY*32{1'b0}};
        for (v = 0; v < POLY; v = v + 1) begin
            phase_inc[v*32 +: 32] = 32'd8_000_000 + v * 32'd1_100_000;
            velocity[v*8 +: 8]    = 8'd200;
            env_level[v*16 +: 16] = 16'h0400 + (v % 4) * 16'h0080;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) start_dly <= 32'd0;
        else        start_dly <= {start_dly[30:0], valid_ff};
    end

    // ---- per-cycle equivalence -----------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            if (valid_ff !== valid_ram) begin
                $display("FAIL: osc_valid differs ff=%b ram=%b", valid_ff, valid_ram);
                errors = errors + 1;
            end
            if (bus_ram !== {LANES*SW{1'b0}}) begin
                $display("FAIL: DUT bank osc_sample_bus_o is not constant 0 -- the BSRAM branch is not in use");
                errors = errors + 1;
            end
            if (dry_valid_ff !== dry_valid_ram) begin
                $display("FAIL: dry_valid differs ff=%b ram=%b", dry_valid_ff, dry_valid_ram);
                errors = errors + 1;
            end
            if (deadline_ff !== deadline_ram) begin
                $display("FAIL: deadline_fault differs ff=%b ram=%b", deadline_ff, deadline_ram);
                errors = errors + 1;
            end
            if (n_active_ff !== n_active_ram) begin
                $display("FAIL: n_active differs ff=%0d ram=%0d", n_active_ff, n_active_ram);
                errors = errors + 1;
            end
            if (dry_valid_ff) begin
                compared = compared + 1;
                if (dry_sample_ff !== dry_sample_ram) begin
                    $display("FAIL: dry_sample differs at cycle %0t ff=%h ram=%h",
                             $time, dry_sample_ff, dry_sample_ram);
                    errors = errors + 1;
                end
                abs_now = dry_sample_ram[23] ? -dry_sample_ram : dry_sample_ram;
                if (abs_now > max_abs) max_abs = abs_now;
                if (abs_now != 0) nonzero = nonzero + 1;
            end
        end
    end

    task audio_frame;
        begin
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            repeat (FWAIT) @(negedge clk);
        end
    endtask

    task run_case;
        input sel;
        integer k;
        begin
            rst_n = 1'b0;
            use_delayed_start = sel;
            repeat (6) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            for (k = 0; k < FRAMES; k = k + 1)
                audio_frame();
            case_id = case_id + 1;
            $display("INFO: case %0d (delayed_start=%0b): compared=%0d samples, nonzero=%0d, max_abs=%0d (0x%06h)",
                     case_id, sel, compared, nonzero, max_abs, max_abs);
        end
    endtask

    initial begin
        // case 1: render starts at the same edge as the TDM sweep restart
        //         (reads race the RAM write port on purpose -- strongest case)
        run_case(1'b0);
        // case 2: production wiring (render_start = ob_valid delayed by 32)
        run_case(1'b1);

        if (compared < MIN_SAMPLES * 2) begin
            $display("FAIL: only %0d samples compared (need %0d) -- probe is vacuous",
                     compared, MIN_SAMPLES * 2);
            errors = errors + 1;
        end
        if (nonzero < MIN_SAMPLES) begin
            $display("FAIL: only %0d nonzero dry samples -- probe is vacuous", nonzero);
            errors = errors + 1;
        end
        if (max_abs >= 24'h700000) begin
            $display("FAIL: max_abs=%0d reaches the soft-knee limiter -- a bit difference could be masked",
                     max_abs);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: osc BSRAM read path is cycle-exact and bit-exact vs the FF path (%0d samples)",
                     compared);
        else
            $fatal(1, "FAIL: osc BSRAM read path differs from the FF path (%0d error(s))", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_osc_ram_equiv timeout");
    end
endmodule

`default_nettype wire
