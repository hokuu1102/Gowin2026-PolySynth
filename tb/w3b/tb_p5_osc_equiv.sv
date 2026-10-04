`timescale 1ns/1ps
// ============================================================================
//  tb_p5_osc_equiv.sv -- ⭐ P5-② 的**逐位等价**判据（现版 vs 上提版）
//
//  ⭐ 被测性质：⭐ `oscillator_bank` 把"增量 + 扫频"算术**从每 lane 上提到每 voice**
//     （⭐ `OSC_PER_VOICE = 2` ⇒ 同一 voice 的两个 lane 共用同一份算术）
//     ⇒ ⭐ **输出必须逐位不变**（⭐ 这是"纯代数重排"的全部依据）。
//
//  🔴 为什么必须用【差分 tb】而不是"跑一遍看输出对不对"：
//     ⭐ `P5-优化候选` 的 T3 教训 —— ⚠️ **"省了多少 LUT" 必须配"功能是否逐位等价"**；
//     ⭐ 只跑一遍验收 tb 只能证明"没坏到被测判据的程度"，⛔ 证明不了"逐位相同"。
//
//  ⭐⭐ 参考副本 = `tb/models/oscillator_bank_ref.v`（⭐ 改动前的 `oscillator_bank`，
//     ⛔ **只改了模块名**；⭐ 与本项目 `tb/models/evt_merge_ref.v` 同一惯例）
//     🔴 **将来若再改 `oscillator_bank`，必须同步换新参考** ——
//        ⚠️ 否则"两边同源" ⇒ ⭐ 本 tb 会**静默恒真**（⭐ `C83` 探针假绿同族）
//
//  ⭐ 比什么（⭐ 三层，一层比一层强）
//    ① `osc_sample_bus_o`（64 lane × 16 位，整条 TDM 总线）—— ⭐ 与侦察同一口径
//    ② `osc_valid_o`
//    ③ ⭐⭐ **全部 64 个相位累加器 `phase_q`**（⭐ 用层次引用逐 lane 比）
//       📌 为什么必须有 ③：⚠️ 波表只有 1024 项，**不同的相位可能查到同一个样点值**
//          ⇒ ⭐ 只比样点会漏掉"相位偏了但恰好落在同一表项"的情形 ✅
//
//  ⭐ 激励（⭐ 320 帧，⭐ 与侦察一致 —— 覆盖所有被搬动的路径）
//    A 全 voice 在响 + 各不相同的音高（40 帧）
//    B 颤音扫（⭐ 走**有符号加法**那条路）（60 帧）
//    C ⭐ **鼓 voice（底鼓/嗵鼓/军鼓/踩镲）＋ 音高包络**（80 帧）—— ⭐ 扫频是本次搬动的重点
//    D ⭐ **重触发脉冲 + 随机开关/换音高**（120 帧）—— ⭐ 走 `phase_rst` 与上升沿判据
//    E test 档（20 帧）
//
//  ⭐ 能红判据（⭐ 见 `sim/evidence/p5-2-osc-20261004/`：一次真变异实测变红）
// ============================================================================
`default_nettype none

module tb_p5_osc_equiv;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n       = 1'b0;
    reg sample_tick = 1'b0;

    reg [31:0]        voice_active;
    reg [31:0]        voice_phase_rst;
    reg [31:0]        voice_drum;
    reg [1023:0]      base_inc;
    reg [63:0]        voice_timbre;
    reg [255:0]       voice_velocity;
    reg signed [15:0] vibrato;
    reg               test_mode;
    reg [63:0]        test_lane_active;
    reg [2047:0]      test_phase_inc;

    wire [1023:0] ref_bus, dut_bus;
    wire          ref_v,   dut_v;
    wire [31:0]   ref_dbg, dut_dbg;

    // ── 参考（⭐ 改动前的实现，⛔ 只改了模块名）──────────────────────────────
    oscillator_bank_ref #(
        .POLY_TARGET(32), .OSC_PER_VOICE(2), .PHASE_W(32), .OSC_SAMPLE_W(16),
        .TIMBRE_N(4), .TIMBRE_W(2), .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
        .VIB_REF_INC(38_700_000), .DBG_LANE(0),
        .DETUNE_ON(1), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
        .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
        .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),
        .DRUM_CLICK_EN(0)
    ) u_ref (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .voice_phase_rst_i(voice_phase_rst),
        .base_phase_inc_i(base_inc), .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity), .voice_drum_i(voice_drum),
        .vibrato_mod_i(vibrato), .test_mode_i(test_mode),
        .test_lane_active_i(test_lane_active), .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(ref_bus), .osc_valid_o(ref_v), .phase_acc_dbg_o(ref_dbg)
    );

    // ── 被测（⭐ 生产文件 `rtl/w3b/oscillator_bank.v`）────────────────────────
    oscillator_bank #(
        .POLY_TARGET(32), .OSC_PER_VOICE(2), .PHASE_W(32), .OSC_SAMPLE_W(16),
        .TIMBRE_N(4), .TIMBRE_W(2), .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
        .VIB_REF_INC(38_700_000), .DBG_LANE(0),
        .DETUNE_ON(1), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
        .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
        .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),
        .DRUM_CLICK_EN(0)
    ) u_dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .voice_phase_rst_i(voice_phase_rst),
        .base_phase_inc_i(base_inc), .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity), .voice_drum_i(voice_drum),
        .vibrato_mod_i(vibrato), .test_mode_i(test_mode),
        .test_lane_active_i(test_lane_active), .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(dut_bus), .osc_valid_o(dut_v), .phase_acc_dbg_o(dut_dbg)
    );

    integer errors = 0;
    integer frames = 0;
    integer f, i, L;
    reg [31:0] lfsr = 32'hDEAD_BEEF;
    reg [31:0] rv;

    function [31:0] rnd;
        input dummy;
        begin
            lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            rnd  = lfsr;
        end
    endfunction

    // ⭐⭐ 逐 lane 比**相位累加器**（⭐ 层次引用必须用**常量**下标 ⇒ 用宏展开 64 次）
    `define PHCMP(N) \
        if (u_ref.gen_lane[N].phase_q !== u_dut.gen_lane[N].phase_q) begin \
            errors = errors + 1; \
            $display("FAIL frame %0d: lane %0d PHASE ref=%h dut=%h", frames, N, \
                     u_ref.gen_lane[N].phase_q, u_dut.gen_lane[N].phase_q); \
        end

    task frame;
        begin
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            for (i = 0; i < 80; i = i + 1) @(negedge clk);   // ⭐ TDM 66 拍 + 余量
            frames = frames + 1;

            if (ref_bus !== dut_bus) begin
                errors = errors + 1;
                $display("FAIL frame %0d: osc_sample_bus mismatch", frames);
                for (L = 0; L < 64; L = L + 1)
                    if (ref_bus[L*16 +: 16] !== dut_bus[L*16 +: 16])
                        $display("   lane %0d: ref=%0d dut=%0d", L,
                                 $signed(ref_bus[L*16 +: 16]), $signed(dut_bus[L*16 +: 16]));
            end
            if (ref_v !== dut_v) begin
                errors = errors + 1;
                $display("FAIL frame %0d: osc_valid mismatch", frames);
            end
            if (ref_dbg !== dut_dbg) begin
                errors = errors + 1;
                $display("FAIL frame %0d: phase_acc_dbg ref=%h dut=%h", frames, ref_dbg, dut_dbg);
            end

            `PHCMP( 0) `PHCMP( 1) `PHCMP( 2) `PHCMP( 3) `PHCMP( 4) `PHCMP( 5) `PHCMP( 6) `PHCMP( 7)
            `PHCMP( 8) `PHCMP( 9) `PHCMP(10) `PHCMP(11) `PHCMP(12) `PHCMP(13) `PHCMP(14) `PHCMP(15)
            `PHCMP(16) `PHCMP(17) `PHCMP(18) `PHCMP(19) `PHCMP(20) `PHCMP(21) `PHCMP(22) `PHCMP(23)
            `PHCMP(24) `PHCMP(25) `PHCMP(26) `PHCMP(27) `PHCMP(28) `PHCMP(29) `PHCMP(30) `PHCMP(31)
            `PHCMP(32) `PHCMP(33) `PHCMP(34) `PHCMP(35) `PHCMP(36) `PHCMP(37) `PHCMP(38) `PHCMP(39)
            `PHCMP(40) `PHCMP(41) `PHCMP(42) `PHCMP(43) `PHCMP(44) `PHCMP(45) `PHCMP(46) `PHCMP(47)
            `PHCMP(48) `PHCMP(49) `PHCMP(50) `PHCMP(51) `PHCMP(52) `PHCMP(53) `PHCMP(54) `PHCMP(55)
            `PHCMP(56) `PHCMP(57) `PHCMP(58) `PHCMP(59) `PHCMP(60) `PHCMP(61) `PHCMP(62) `PHCMP(63)

            if (errors > 5) begin
                $display("FAIL: too many mismatches, stopping at frame %0d", frames);
                $fatal(1, "FAIL: tb_p5_osc_equiv diverged");
            end
        end
    endtask

    initial begin
        voice_active = 32'd0; voice_phase_rst = 32'd0; voice_drum = 32'd0;
        base_inc = 1024'd0; voice_timbre = 64'd0; voice_velocity = 256'd0;
        vibrato = 16'sd0; test_mode = 1'b0; test_lane_active = 64'd0; test_phase_inc = 2048'd0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // ── A · 全 voice 在响 + 各不相同的音高（40 帧）──────────────────────
        voice_active = 32'hFFFF_FFFF;
        for (i = 0; i < 32; i = i + 1) begin
            base_inc[i*32 +: 32]  = 32'd5_000_000 + i * 32'd1_100_003;
            voice_timbre[i*2 +: 2] = i[1:0];
            voice_velocity[i*8 +: 8] = 8'd100 + i;
        end
        for (f = 0; f < 40; f = f + 1) frame;

        // ── B · 颤音扫（⭐ 走有符号加法那条路）（60 帧）──────────────────────
        for (f = 0; f < 60; f = f + 1) begin
            vibrato = $signed(f * 500 - 15000);
            frame;
        end
        vibrato = 16'sd0;

        // ── C · ⭐ 鼓 voice + 音高包络（⭐ 扫频是本轮搬动的重点）（80 帧）────
        voice_drum = 32'h0000_000F;
        base_inc[0*32 +: 32] = 32'd5_368_709;     // 底鼓
        base_inc[1*32 +: 32] = 32'd17_895_697;    // 嗵鼓
        base_inc[2*32 +: 32] = 32'd17_179_869;    // 军鼓（⛔ 不扫）
        base_inc[3*32 +: 32] = 32'd171_798_691;   // 踩镲（⛔ 不扫）
        for (f = 0; f < 80; f = f + 1) frame;
        voice_drum = 32'd0;

        // ── D · ⭐ 重触发 + 随机开关/换音高（⭐ 走 `phase_rst` 与上升沿判据）（120 帧）
        for (f = 0; f < 120; f = f + 1) begin
            rv = rnd(1'b0);
            voice_active    = rv;
            rv = rnd(1'b0);
            voice_phase_rst = rv & 32'h0000_FFFF;
            rv = rnd(1'b0);
            for (i = 0; i < 32; i = i + 1)
                base_inc[i*32 +: 32] = 32'd1_000_000 + (rv >> (i % 24)) * 32'd37;
            frame;
        end

        // ── E · test 档（20 帧）────────────────────────────────────────────
        test_mode = 1'b1;
        test_lane_active = 64'hFFFF_FFFF_FFFF_FFFF;
        for (i = 0; i < 64; i = i + 1)
            test_phase_inc[i*32 +: 32] = 32'd2_000_000 + i * 32'd999_983;
        for (f = 0; f < 20; f = f + 1) frame;
        test_mode = 1'b0;

        $display("--------------------------------------------------");
        $display("  osc frames compared = %0d · mismatches = %0d", frames, errors);
        $display("  比了：osc_sample_bus_o(64×16) + osc_valid_o + phase_acc_dbg + 64 个 phase_q");
        if (errors == 0) begin
            $display("PASS: P5-2 per-voice oscillator_bank is BIT-IDENTICAL to the reference");
            $finish;
        end else begin
            $fatal(1, "FAIL: P5-2 oscillator_bank variant diverges (%0d mismatches)", errors);
        end
    end

    // 看门狗：320 帧 × ~85 拍 ≈ 2.8 万拍 ⇒ 给 200 万拍（⭐ 远大于需要，⛔ 只在真挂死时触发）
    initial begin
        #40_000_000;
        $fatal(1, "FAIL: tb_p5_osc_equiv timeout");
    end

endmodule

`default_nettype wire
