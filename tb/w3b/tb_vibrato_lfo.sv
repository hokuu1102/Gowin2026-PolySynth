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

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-09（`P0-30`）：⭐ **速率目标值的【精确值】判据** ✅
        //   🔴 **为什么必须补**：⭐ 上面三条（78/79/80）只约束了**步长**（+10 一拍），
        //      ⛔ **没有约束目标值的数值** ✅
        //   📌 **实测证据**：⭐ 把 `rate_product[21:12]` 改成 `[20:11]`（⭐ 差 1 位）
        //      ⇒ ⭐ **上面三条照样 PASS** ⇒ 🔴 **判据是空的** ✅
        //   ⭐ **本判据**：⭐ `rate_raw_i = 2048` ⇒ 目标 = `100 + (2048 × 100) >> 12`
        //      = `100 + 204800/4096` = `100 + 50` = ⭐ **150** ✅
        //      · ⭐ 正确（`[21:12]`）⇒ 收敛到 **150** ✅
        //      · 🔴 变异（`[20:11]`）⇒ `100 + 204800/2048 = 200` ⇒ ⭐ **判据必红** ✅
        //   📌 **参数**：⭐ 本 tb 的 `RATE_MIN_INC=100` · `RATE_MAX_INC=200` ⇒ ⭐ `span = 100` ✅
        //   📌 ⭐ `rate_raw_i == 12'hFFF` 是**特例**（⭐ 直接给 `RATE_MAX_INC`）⇒ ⭐ 这里刻意用 2048 ✅
        rate_raw = 12'd2048;
        commit; commit; commit; commit; commit; commit;   // ⭐ 6 拍 ⇒ 步长 +10 ⇒ 够收敛到 150 ✅
        chk("P0-30 rate target exact value: rate_raw=2048 => 100 + (2048*100)>>12 == 150",
            rate_inc == 32'd150);

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

        //  ⭐⭐ 2026-10-09（`P0-19`）：⭐ **幅度上限判据（⭐ 能红）** ✅
        //   🔴 **缺陷**：⭐ 档 1（上电默认）把 `ch2_i` 原样透传 ⇒ ⭐ 推子**全量程可达**
        //      ⇒ ⭐ 满深度（`depth_raw = 4095`）时 `vib_off_peak = 9448 × 4095 ≈ 38.7 M`
        //      ⇒ ⚠️ 而 A4 的 `bv` = 38.70 M ⇒ ⭐ **摆幅 = ±100% 频率**
        //      ⇒ 🔴 低音（⭐ E1 41.2 Hz 在 9.4% 行程就够）在 LFO 负半周**相位增量翻负**
        //      ⇒ ⭐ 相位累加器倒着走 ⇒ 🔴 **音高跳 +3.27 个八度**（⭐ 明确错音，⛔ 不是噪声）✅
        //   ✅ **判据**：⭐ 满推子（`depth_raw = 4095`）下 ⭐ `|mod|` **必须 ≤ 960**
        //      （⭐ = ±50 cents @ A4 的限幅值 ⇒ `depth_q ≤ 960` ⇒ `vib_off ≤ 1.134 M`
        //       ⇒ ⭐ 最低可听音 20 Hz 的 `bv` = 1 759 220 仍 > 它 ⇒ **永不翻负**）✅
        //   📌 🔴 **未修复时**：⭐ 峰值 ≈ **32759** ⇒ ⭐ 本断言必红 ✅
        depth_raw = 12'hFFF;
        commit;
        begin : depth_limit
            integer k3;
            integer peak;
            peak = 0;
            for (k3 = 0; k3 < 64; k3 = k3 + 1) begin
                @(negedge clk);
                if (fast_mod > peak) peak = fast_mod;
                if (-fast_mod > peak) peak = -fast_mod;
            end
            $display("      [dbg] P0-19 depth_raw=4095 => |mod| peak = %0d（上限 960）", peak);
            chk("P0-19 depth clamp: |mod| <= 960 with the fader at full travel", peak <= 960);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-13：⭐ **全行程可用判据** ✅
        //     （⭐ 修上板实测的"颤音推子没感觉"：⭐ *"只要不是在最底下，
        //       感觉都没什么太大的差别"* ✅）
        //
        //  🔴 **改前为什么必红**：⭐ `P0-19` 的止血版是【限幅】——
        //        `depth_eff = (depth_raw_i > 120) ? 120 : depth_raw_i`
        //     ⇒ ⭐ `depth_raw = 2048` 会被**限成 120**（⭐ 与 4095 同值 ✅）
        //     ⇒ 🔴 本判据的"中点必须明显小于满行程"**必然失败** ✅
        //  ✅ **改后**：⭐ `2048 × 120 / 4096 = 60` ⇒ ⭐ 峰值 ≈ **480**（⭐ 满行程 ≈ 952 ✅）
        //     ⇒ ⭐ **推子全行程可用**，⛔ 不再是一个开关 ✅
        // ═══════════════════════════════════════════════════════════════════
        begin : depth_travel
            integer k4;
            integer peak_mid;
            depth_raw = 12'd2048;          // ⭐ 行程中点
            commit;
            repeat (20) @(negedge clk);    // ⭐ 等滞回与 slew 稳定
            peak_mid = 0;
            for (k4 = 0; k4 < 64; k4 = k4 + 1) begin
                @(negedge clk);
                if (fast_mod > peak_mid) peak_mid = fast_mod;
                if (-fast_mod > peak_mid) peak_mid = -fast_mod;
            end
            $display("      [dbg] full-travel: depth_raw=2048 => |mod| peak = %0d（满行程 ~952）", peak_mid);
            chk("full-travel usable: mid-fader depth is clearly BELOW full-travel depth",
                peak_mid < 700);
            chk("full-travel usable: mid-fader depth is clearly NON-ZERO (fader really does something)",
                peak_mid > 300);
        end

        if (errors == 0) $display("PASS: vibrato LFO hysteresis, slew and phase continuity");
        else $fatal(1, "FAIL: vibrato LFO has %0d error(s)", errors);
        $finish;
    end
    initial begin #10000; $fatal(1, "FAIL: tb_vibrato_lfo timeout"); end
endmodule
