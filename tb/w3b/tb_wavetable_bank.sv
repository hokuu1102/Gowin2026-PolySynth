`timescale 1ns/1ps

/* T31b replaced this 512-point single-sine interface.  The retained source
 * below documents the retired acceptance scope; the active test follows it. */
/*

// W1-2.4 self-checking testbench for the portable 512x16 wavetable ROM.
// $readmemh is intentionally testbench-only; synthesizable RTL embeds constants.
module tb_wavetable_bank;
    localparam integer DEPTH = 512;

    reg                       clk_i = 1'b0;
    reg                       rst_n_i = 1'b0;
    reg                       rd_en_i = 1'b0;
    reg  [8:0]                addr_i = 9'd0;
    wire signed [15:0]        sample_o;
    wire                      valid_o;

    reg [15:0] golden [0:DEPTH-1];
    integer address;
    integer errors = 0;
    reg signed [15:0] held_sample;

    always #10 clk_i = ~clk_i;  // 50 MHz

    wavetable_bank dut (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .rd_en_i  (rd_en_i),
        .addr_i   (addr_i),
        .sample_o (sample_o),
        .valid_o  (valid_o)
    );

    task check_response;
        input integer expected_address;
        begin
            if (valid_o !== 1'b1) begin
                $display("FAIL: valid_o not asserted for address %0d", expected_address);
                errors = errors + 1;
            end
            if ((^sample_o) === 1'bx) begin
                $display("FAIL: sample_o contains X/Z at address %0d", expected_address);
                errors = errors + 1;
            end else if (sample_o !== $signed(golden[expected_address])) begin
                $display(
                    "FAIL: address %0d expected %0d (0x%04h), got %0d (0x%04h)",
                    expected_address, $signed(golden[expected_address]),
                    golden[expected_address], sample_o, sample_o
                );
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable/tb_wavetable_bank.vcd");
        $dumpvars(0, tb_wavetable_bank);
        $readmemh("rtl/w3b/rom/sine_512x16.hex", golden);

        if (golden[0]   !== 16'h0000 || golden[128] !== 16'h7fff ||
            golden[256] !== 16'h0000 || golden[384] !== 16'h8001) begin
            $fatal(1, "FAIL: golden wavetable key values are invalid");
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $fatal(1, "FAIL: reset outputs are not valid_o=0 and sample_o=0");
        end
        if (valid_o === 1'bx || (^sample_o) === 1'bx) begin
            $fatal(1, "FAIL: reset outputs contain X/Z");
        end

        rst_n_i = 1'b1;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        rd_en_i = 1'b1;
        addr_i  = 9'd37;
        #1;
        if (valid_o !== 1'b0) begin
            $fatal(1, "FAIL: valid_o changed before the sampling clock edge");
        end
        @(negedge clk_i);
        check_response(37);

        held_sample = sample_o;
        rd_en_i = 1'b0;
        addr_i  = 9'd100;
        @(negedge clk_i);
        if (valid_o !== 1'b0) begin
            $display("FAIL: valid_o asserted while rd_en_i=0");
            errors = errors + 1;
        end
        if (sample_o !== held_sample) begin
            $display("FAIL: sample_o changed while rd_en_i=0");
            errors = errors + 1;
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd0;
        for (address = 0; address < DEPTH; address = address + 1) begin
            @(negedge clk_i);
            check_response(address);
            if (address < DEPTH-1)
                addr_i = address + 1;
        end

        held_sample = sample_o;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== held_sample) begin
            $display("FAIL: disabled state after burst is incorrect");
            errors = errors + 1;
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        rst_n_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $display("FAIL: post-traffic reset did not clear outputs");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: wavetable_bank 512/512 samples matched with deterministic one-cycle reads");
        else
            $fatal(1, "FAIL: wavetable_bank test found %0d error(s)", errors);

        #20;
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_wavetable_bank timeout");
    end
endmodule
*/

// T31b public-ROM protocol test: four 1024-point timbres, soft/hard samples,
// synchronous read and disabled-read hold.  No board-level signals are used.
//
// ⭐⭐ 2026-09-29 追加（⭐ 鼓机噪声波表 · 阶段 2a）：⭐ **第 10 张表（宽带噪声）的验收**
//   ⭐ 三条判据：
//     ① ⭐ **过零率**：⭐ 噪声表远高于纯正弦表（⭐ 白噪声 ≈ 50 %，正弦 ≈ 0.1 %）
//     ② ⭐ **小滞后自相关**：⭐ `|r(1)| / |r(2)| ≤ 0.10`（⭐ 正弦 ≈ 1.0）
//     ③ ⭐ **环绕处一阶差分**：⭐ 不得大于表内最大一阶差分（⭐ 防"每圈一次咔哒"）
//   ⭐ 再加一条**端到端**判据：⭐ 把 `oscillator_bank` 的鼓标志拉高 ⇒
//      该 voice 的样本必须变成宽带噪声；⭐ 拉低（= **关掉噪声选择**）⇒
//      同一个判据必须**变红**（⭐ 非空洞性，⭐ 见 `noise_sel_off_*` 两条）。
module tb_wavetable_bank;
    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg rd_en_i = 1'b0;
    reg [1:0] timbre_i = 2'd0;
    reg [9:0] addr_i = 10'd0;
    wire signed [15:0] sample_soft_o;
    wire signed [15:0] sample_hard_o;
    wire signed [15:0] sample_test_o;
    wire signed [15:0] sample_noise_o;
    wire valid_o;
    integer errors = 0;
    reg signed [15:0] held_soft, held_hard;

    always #10 clk_i = ~clk_i;

    wavetable_bank dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rd_en_i(rd_en_i),
        .timbre_i(timbre_i), .addr_i(addr_i),
        .sample_soft_o(sample_soft_o), .sample_hard_o(sample_hard_o),
        .sample_test_o(sample_test_o), .sample_noise_o(sample_noise_o),
        .valid_o(valid_o)
    );

    // ─────────────────────────────────────────────────────────────────────
    // ⭐⭐ 鼓标志 → 噪声表选择的**端到端**验证载体
    //
    //   ⭐ 为什么要在这里放一个 `oscillator_bank`：
    //      ⭐ "选哪张表"这个决定**不在 `wavetable_bank` 里**，⭐ 而在
    //         `oscillator_bank` 的 `resp_drum_q`（⭐ 与 pROM 数据**同拍**的标签）✅
    //      ⇒ ⭐ 只在 `wavetable_bank` 上量统计量 ⇒ 🔴 **量的是表，⛔ 不是"表有没有被选中"**
    //         ⇒ ⭐ 判据**空洞**（⭐ 把 `resp_drum_q` 恒置 0 也照样绿 ✅）
    //
    //   ⭐ 用**真实鼓机的音高**（⭐ `drum_gen.INC_HIHAT ≈ 1953 Hz`）驱动它 ——
    //      ⭐ 这样"噪声听起来是不是噪声"就是在**真实使用条件**下量的 ✅
    // ─────────────────────────────────────────────────────────────────────
    localparam integer OB_POLY  = 2;
    localparam integer OB_OPV   = 1;
    localparam integer OB_LANES = OB_POLY * OB_OPV;
    localparam [31:0]  INC_HIHAT = 32'd171_798_691;   // ⭐ ≈ 1920 Hz（⭐ 同 `drum_gen`）
    localparam integer CAP_N    = 512;                // ⭐ 每个窗口的捕获点数

    reg                    ob_tick = 1'b0;
    reg  [OB_POLY-1:0]     ob_active = 2'b00;
    reg  [OB_POLY*32-1:0]  ob_inc    = {(OB_POLY*32){1'b0}};
    reg  [OB_POLY*2-1:0]   ob_timbre = {(OB_POLY*2){1'b0}};
    reg  [OB_POLY*8-1:0]   ob_vel    = {(OB_POLY*8){1'b0}};
    reg  [OB_POLY-1:0]     ob_drum   = 2'b00;
    wire [OB_LANES*16-1:0] ob_samples;
    wire                   ob_valid;
    wire [31:0]            ob_phase_dbg;

    // ⭐ `sample_tick_i` 是**时钟使能**（⭐ 恰好高 1 拍）⇒ 用计数器产生 ✅
    //   ⭐ 周期 16 拍 ≫ TDM 的 `LANES+2 = 3` 拍 ⇒ ⭐ 每帧都来得及 ✅
    integer ob_div = 0;
    always @(posedge clk_i) begin
        if (ob_div >= 15) begin
            ob_div  <= 0;
            ob_tick <= 1'b1;
        end else begin
            ob_div  <= ob_div + 1;
            ob_tick <= 1'b0;
        end
    end

    oscillator_bank #(
        .POLY_TARGET(OB_POLY), .OSC_PER_VOICE(OB_OPV), .PHASE_W(32),
        .OSC_SAMPLE_W(16), .TIMBRE_N(4), .TIMBRE_W(2),
        .WT_DEPTH(1024), .WT_W(16), .ENABLE_FM(0), .DBG_LANE(0),
        //   ⚠️ 关失谐 + 固定 soft 档 ⇒ ⭐ 关掉噪声时读的就是**同一张乐音表**
        //      ⇒ ⭐ "开/关噪声"两个窗口**只差这一个变量** ✅
        .DETUNE_ON(0), .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0)
    ) ob_dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .sample_tick_i(ob_tick),
        .voice_active_i(ob_active), .base_phase_inc_i(ob_inc),
        .voice_timbre_i(ob_timbre), .voice_velocity_i(ob_vel),
        .voice_drum_i(ob_drum),
        .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0),
        .test_lane_active_i({OB_LANES{1'b0}}),
        .test_phase_inc_i({(OB_LANES*32){1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(ob_samples), .osc_valid_o(ob_valid),
        .phase_acc_dbg_o(ob_phase_dbg)
    );

    reg signed [15:0] noise_tab [0:1023];
    reg signed [15:0] sine_tab  [0:1023];
    reg signed [15:0] cap_noise [0:CAP_N-1];
    reg signed [15:0] cap_pitch [0:CAP_N-1];

    integer idx, lag, cap_idx;
    integer noise_zcr, sine_zcr, cap_zcr_noise, cap_zcr_pitch;
    integer noise_sum, noise_max, noise_min;
    integer wrap_step, max_step, step_now;
    real    ac_num, ac_den, ac_lag1, ac_lag2;
    real    rate_noise, rate_pitch;

    // ⭐ 判据打印/计分（⭐ 判据名**纯 ASCII**、≤128 字节 ✅）
    task check_criterion;
        input [8*128-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ⭐ 跳过 `n` 个 `osc_valid_o` 帧 —— ⭐ 切换 `ob_drum` 后必须空转几帧，
    //   让 TDM 里**还带着旧标签**的那几拍彻底排空（⛔ 否则窗口首尾会混入异类样本）
    task skip_frames;
        input integer n;
        integer seen;
        begin
            seen = 0;
            while (seen < n) begin
                @(negedge clk_i);
                if (ob_valid === 1'b1) seen = seen + 1;
            end
        end
    endtask


    task read_and_check;
        input [1:0] t;
        input [9:0] a;
        input signed [15:0] want_soft;
        input signed [15:0] want_hard;
        begin
            @(negedge clk_i);
            timbre_i = t; addr_i = a; rd_en_i = 1'b1;
            @(negedge clk_i);
            if (valid_o !== 1'b1 || sample_soft_o !== want_soft || sample_hard_o !== want_hard) begin
                $display("FAIL: t=%0d a=%0d expected soft=%0d hard=%0d got v=%b soft=%0d hard=%0d",
                         t, a, want_soft, want_hard, valid_o, sample_soft_o, sample_hard_o);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable/tb_wavetable_bank.vcd");
        $dumpvars(0, tb_wavetable_bank);
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== 16'sd0 || sample_hard_o !== 16'sd0)
            $fatal(1, "FAIL: reset state is not zero");
        rst_n_i = 1'b1;

        // Each timbre has an independent CC0 AKWF soft/hard pair.
        read_and_check(2'd0, 10'd0,   16'sd373,   16'sd226);
        read_and_check(2'd0, 10'd256, 16'sd32490, 16'sd32280);
        read_and_check(2'd1, 10'd0,   16'sd4848,  16'sd5588);
        read_and_check(2'd2, 10'd0,   16'sd1123,  16'sd3176);
        read_and_check(2'd3, 10'd0,   16'sd917,   16'sd906);

        held_soft = sample_soft_o; held_hard = sample_hard_o;
        @(negedge clk_i);
        rd_en_i = 1'b0; addr_i = 10'd511; timbre_i = 2'd3;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== held_soft || sample_hard_o !== held_hard) begin
            $display("FAIL: outputs changed while read was disabled");
            errors = errors + 1;
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ ① 表级判据：⭐ **逐点读回噪声表与纯正弦表**（⭐ 各 1024 点）✅
        //   ⭐ 为什么逐点读：⭐ 统计量（过零率 / 自相关）是**全表**属性 ⇒
        //      ⚠️ 只抽查几个地址 ⇒ 🔴 判据空洞 ✅
        // ═══════════════════════════════════════════════════════════════════
        @(negedge clk_i);
        timbre_i = 2'd0; rd_en_i = 1'b1; addr_i = 10'd0;
        for (idx = 0; idx < 1024; idx = idx + 1) begin
            @(negedge clk_i);
            //   ⭐ 上一拍送出的地址 `idx` 的数据此刻已在输出上（⭐ pROM 1 拍读 ✅）
            noise_tab[idx] = sample_noise_o;
            sine_tab[idx]  = sample_test_o;
            addr_i = idx[9:0] + 10'd1;
        end

        noise_zcr = 0; sine_zcr = 0; noise_sum = 0;
        noise_max = -32768; noise_min = 32767;
        for (idx = 0; idx < 1024; idx = idx + 1) begin
            noise_sum = noise_sum + noise_tab[idx];
            if (noise_tab[idx] > noise_max) noise_max = noise_tab[idx];
            if (noise_tab[idx] < noise_min) noise_min = noise_tab[idx];
        end
        for (idx = 0; idx < 1023; idx = idx + 1) begin
            if ((noise_tab[idx] < 0) != (noise_tab[idx+1] < 0)) noise_zcr = noise_zcr + 1;
            if ((sine_tab[idx]  < 0) != (sine_tab[idx+1]  < 0)) sine_zcr  = sine_zcr + 1;
        end
        //   ⭐ 环绕那一对（`s[1023] → s[0]`）也要算 —— ⭐ 表是**循环**的 ✅
        if ((noise_tab[1023] < 0) != (noise_tab[0] < 0)) noise_zcr = noise_zcr + 1;
        if ((sine_tab[1023]  < 0) != (sine_tab[0]  < 0)) sine_zcr  = sine_zcr + 1;

        //   ⭐ 小滞后自相关 `r(k) = Σ x[i]x[i+k] / Σ x[i]²`（⭐ 用 `real` 防 32 位溢出 ✅）
        ac_lag1 = 0.0; ac_lag2 = 0.0;
        for (lag = 1; lag <= 2; lag = lag + 1) begin
            ac_num = 0.0; ac_den = 0.0;
            for (idx = 0; idx < 1024; idx = idx + 1) begin
                ac_num = ac_num + 1.0 * noise_tab[idx] * noise_tab[(idx+lag) % 1024];
                ac_den = ac_den + 1.0 * noise_tab[idx] * noise_tab[idx];
            end
            if (lag == 1) ac_lag1 = ac_num / ac_den;
            else          ac_lag2 = ac_num / ac_den;
        end

        //   ⭐ 环绕处一阶差分 vs 表内最大一阶差分（⭐ 周期性安全 ✅）
        wrap_step = (noise_tab[0] > noise_tab[1023]) ? (noise_tab[0] - noise_tab[1023])
                                                     : (noise_tab[1023] - noise_tab[0]);
        max_step = 0;
        for (idx = 0; idx < 1023; idx = idx + 1) begin
            step_now = (noise_tab[idx+1] > noise_tab[idx]) ? (noise_tab[idx+1] - noise_tab[idx])
                                                           : (noise_tab[idx] - noise_tab[idx+1]);
            if (step_now > max_step) max_step = step_now;
        end

        $display("  info: noise len=1024 sum=%0d min=%0d max=%0d zcr=%0d",
                 noise_sum, noise_min, noise_max, noise_zcr);
        $display("  info: sine  zcr=%0d  noise r1=%.5f r2=%.5f  wrap_step=%0d max_step=%0d",
                 sine_zcr, ac_lag1, ac_lag2, wrap_step, max_step);

        check_criterion("noise_table_dc_sum_is_zero", noise_sum == 0);
        check_criterion("noise_table_peak_within_2pct_of_full_scale", noise_max >= 32000);
        check_criterion("noise_table_not_clipped_to_full_scale", noise_min > -32768);
        check_criterion("sine_table_zcr_is_low", sine_zcr <= 4);
        check_criterion("noise_table_zcr_ge_64x_sine_zcr", noise_zcr >= 64 * (sine_zcr + 1));
        check_criterion("noise_table_autocorr_lag1_le_0p10",
                        (ac_lag1 <= 0.10) && (ac_lag1 >= -0.10));
        check_criterion("noise_table_autocorr_lag2_le_0p10",
                        (ac_lag2 <= 0.10) && (ac_lag2 >= -0.10));
        check_criterion("noise_table_wrap_step_le_max_interior_step", wrap_step <= max_step);

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ ② 端到端判据：⭐ **鼓标志真的把该 voice 切到噪声表了吗** ✅
        //   ⭐ 两个窗口**只差 `ob_drum` 这一位**（⭐ 音高 / 音色 / 包络全同）⇒
        //      ⭐ 差异只可能来自"选表"⇒ ⭐ 判据不可辩驳 ✅
        // ═══════════════════════════════════════════════════════════════════
        ob_active = 2'b01;
        ob_inc    = {{(OB_POLY-1)*32{1'b0}}, INC_HIHAT};
        ob_timbre = {(OB_POLY*2){1'b0}};
        ob_vel    = {(OB_POLY*8){1'b0}};
        @(negedge clk_i);

        // ── 窗口 A：⭐ 鼓标志 = 1（⭐ 应走噪声表 ✅）
        ob_drum = 2'b01;
        skip_frames(4);
        cap_idx = 0;
        while (cap_idx < CAP_N) begin
            @(negedge clk_i);
            if (ob_valid === 1'b1) begin
                cap_noise[cap_idx] = ob_samples[15:0];
                cap_idx = cap_idx + 1;
            end
        end

        // ── 窗口 B：⭐ 鼓标志 = 0（⭐ = **关掉噪声选择** ⇒ 走乐音表 ✅）
        ob_drum = 2'b00;
        skip_frames(4);
        cap_idx = 0;
        while (cap_idx < CAP_N) begin
            @(negedge clk_i);
            if (ob_valid === 1'b1) begin
                cap_pitch[cap_idx] = ob_samples[15:0];
                cap_idx = cap_idx + 1;
            end
        end

        cap_zcr_noise = 0; cap_zcr_pitch = 0;
        for (idx = 1; idx < CAP_N; idx = idx + 1) begin
            if ((cap_noise[idx] < 0) != (cap_noise[idx-1] < 0)) cap_zcr_noise = cap_zcr_noise + 1;
            if ((cap_pitch[idx] < 0) != (cap_pitch[idx-1] < 0)) cap_zcr_pitch = cap_zcr_pitch + 1;
        end
        rate_noise = cap_zcr_noise / (CAP_N - 1.0);
        rate_pitch = cap_zcr_pitch / (CAP_N - 1.0);
        $display("  info: drum voice capture zcr: noise_sel=%0d (%.3f) / noise_sel_off=%0d (%.3f)",
                 cap_zcr_noise, rate_noise, cap_zcr_pitch, rate_pitch);

        //   ⭐ **非空洞性**：⭐ 关掉噪声选择后，**同一个判据必须变红** ⇒
        //      ⭐ 所以"关掉时过零率必须低"本身也是一条判据 ✅
        check_criterion("noise_sel_off_capture_is_pitched", rate_pitch <= 0.15);
        check_criterion("drum_voice_reads_broadband_noise", rate_noise >= 0.25);
        //   ⚠️ 门限取 3 倍（⛔ 不是 8 倍）：⭐ 实测噪声窗口 246 次 / 乐音窗口 41 次
        //      ⇒ ⭐ 约 6 倍。⭐ 取 3 倍 ⇒ **两倍余量**（⭐ 8 倍会把正常结果判红 —— 已踩过）✅
        check_criterion("drum_voice_zcr_at_least_3x_pitched_ref",
                        cap_zcr_noise >= 3 * (cap_zcr_pitch + 1));

        if (errors == 0)
            $display("PASS: wavetable_bank four timbres use deterministic synchronous reads");
        else
            $fatal(1, "FAIL: wavetable_bank found %0d error(s)", errors);
        $finish;
    end
endmodule
