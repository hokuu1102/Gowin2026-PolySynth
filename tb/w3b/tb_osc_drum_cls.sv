// ═══════════════════════════════════════════════════════════════════════════
// tb_osc_drum_cls.sv — ⭐ `A3` 正确修法的专用判据（2026-10-08）
//
//   ⭐ 被测性质：⭐ `oscillator_bank` 的**鼓音高档判据**来源由 **参数 `DRUM_CLS_EXT`** 决定：
//      · `DRUM_CLS_EXT = 1` ⇒ ⭐ **用 `drum_cls_i`**（⭐ 由 `note_manager` 提交时算好）
//        ⇒ ⭐ **零窗口** ＋ ⭐ 那 64 个常量比较器**不参与综合** ✅
//      · `DRUM_CLS_EXT = 0`（⭐ 默认）⇒ ⭐ **本模块自己比 `bv`**（⭐ 老行为 ⇒ 所有老 tb 不用改）✅
//
//   ⭐ **判据（双实例差分 —— ⭐ 自带对照，⛔ 不是空判据）**：
//      · `A1`（⭐ 参数 1）：`base_phase_inc_i` = **嗵鼓档**、`drum_cls_i` = **底鼓**
//        ⇒ ⭐ `is_kick` **必须为 1**（⭐ 说明它**听外部**、⛔ 不听 `bv`）✅
//      · `A2`（⭐ 参数 1）：⭐ 反过来（`base` = 底鼓、`cls` = 嗵鼓）⇒ `is_tom` **必须为 1** ✅
//      · `B1`（⭐ 参数 0）：⭐ 同样输入（`base` = 嗵鼓）⇒ ⭐ `is_kick=0`/`is_tom=1`
//        （⭐ 说明**参数门控真的生效**：⭐ 它**没听** `drum_cls_i`）✅
//   📌 ⭐ **反向证明**：⭐ 若把参数门控去掉（⭐ 一律听 `drum_cls_i`）⇒ ⭐ `B1` 会红 ✅
//
//   📌 阈值（⭐ 与 `top.v` 的生产值一致）：`DRUM_KICK_MAX = 10_000_000` · `DRUM_TOM_MAX = 20_000_000`
//      ⇒ ⭐ 8M = 底鼓档 · ⭐ 15M = 嗵鼓档（⭐ 10M~20M 之间）✅
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_osc_drum_cls;

    localparam integer POLY = 4;
    localparam integer OPV  = 2;
    localparam integer PHW  = 32;
    localparam [31:0]  KICK_INC = 32'd8_000_000;    // ⭐ 底鼓档（< 10M）
    localparam [31:0]  TOM_INC  = 32'd15_000_000;   // ⭐ 嗵鼓档（10M~20M）

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    // ── 共用激励 ──────────────────────────────────────────────────────────
    reg sample_tick;
    reg [POLY-1:0]          voice_active, voice_drum;
    reg [POLY*PHW-1:0]      base_inc;
    reg [POLY*2-1:0]        drum_cls;
    reg [POLY*2-1:0]        voice_timbre;
    reg [POLY*8-1:0]        voice_velocity;
    reg signed [15:0]       vibrato;
    reg                     test_mode;
    reg [POLY*OPV-1:0]      test_lane_active;
    reg [POLY*OPV*PHW-1:0]  test_phase_inc;
    reg [POLY-1:0]          voice_phase_rst;

    // ── 实例 A：DRUM_CLS_EXT = 1（⭐ 生产档：听外部分类）────────────────────
    wire [POLY*OPV*16-1:0] bus_a;
    wire                   vld_a;
    wire [PHW-1:0]         dbg_a;

    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHW), .OSC_SAMPLE_W(16),
        .TIMBRE_N(4), .TIMBRE_W(2), .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
        .VIB_REF_INC(38_700_000), .DBG_LANE(0),
        .DETUNE_ON(1), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
        .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(3),
        .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(20_000_000),
        .DRUM_CLICK_EN(0),
        .DRUM_CLS_EXT(1)                      // ⭐ 听外部分类
    ) u_a (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .voice_phase_rst_i(voice_phase_rst),
        .base_phase_inc_i(base_inc), .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity), .voice_drum_i(voice_drum),
        .drum_cls_i(drum_cls),
        .vibrato_mod_i(vibrato), .test_mode_i(test_mode),
        .test_lane_active_i(test_lane_active), .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(bus_a), .osc_valid_o(vld_a), .phase_acc_dbg_o(dbg_a)
    );

    // ── 实例 B：DRUM_CLS_EXT = 0（⭐ 默认档：自己比 bv）─────────────────────
    wire [POLY*OPV*16-1:0] bus_b;
    wire                   vld_b;
    wire [PHW-1:0]         dbg_b;

    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHW), .OSC_SAMPLE_W(16),
        .TIMBRE_N(4), .TIMBRE_W(2), .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
        .VIB_REF_INC(38_700_000), .DBG_LANE(0),
        .DETUNE_ON(1), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
        .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(3),
        .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(20_000_000),
        .DRUM_CLICK_EN(0)
        //  ⭐ DRUM_CLS_EXT 用默认 0 ⇒ ⭐ 自己比 `bv`（⭐ 老行为）
    ) u_b (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .voice_phase_rst_i(voice_phase_rst),
        .base_phase_inc_i(base_inc), .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity), .voice_drum_i(voice_drum),
        .drum_cls_i(drum_cls),                 // ⭐ 接了但**不该被听**
        .vibrato_mod_i(vibrato), .test_mode_i(test_mode),
        .test_lane_active_i(test_lane_active), .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(bus_b), .osc_valid_o(vld_b), .phase_acc_dbg_o(dbg_b)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    integer k;
    initial begin
        $display("=== tb_osc_drum_cls (A3 正确修法: 参数门控的鼓分类) ===");

        voice_active     = {POLY{1'b0}};  voice_active[0] = 1'b1;
        voice_drum       = {POLY{1'b0}};  voice_drum[0]   = 1'b1;
        voice_timbre     = {(POLY*2){1'b0}};
        voice_velocity   = {(POLY*8){8'd200}};
        vibrato          = 16'sd0;
        test_mode        = 1'b0;
        test_lane_active = {(POLY*OPV){1'b0}};
        test_phase_inc   = {(POLY*OPV*PHW){1'b0}};
        voice_phase_rst  = {POLY{1'b0}};
        sample_tick      = 1'b0;
        drum_cls         = {(POLY*2){1'b0}};
        base_inc         = {(POLY*PHW){1'b0}};

        //  ⭐ A 组：base = 嗵鼓档 · cls = 底鼓  ⇒ 必须听 cls
        base_inc[0*PHW +: PHW] = TOM_INC;
        drum_cls[0*2 + 1]      = 1'b1;      // ⭐ 底鼓位
        drum_cls[0*2 + 0]      = 1'b0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (20) @(negedge clk);

        $display("      [dbg] A(参数=1): base=tom(15M) cls=kick => is_kick=%b is_tom=%b",
                 u_a.gen_voice[0].is_kick, u_a.gen_voice[0].is_tom);
        chk(u_a.gen_voice[0].is_kick === 1'b1,
            "A1 DRUM_CLS_EXT=1 => is_kick follows drum_cls_i (NOT the transposed bv)");
        chk(u_a.gen_voice[0].is_tom === 1'b0,
            "A2 DRUM_CLS_EXT=1 => is_tom is 0 (it judged the external class)");

        $display("      [dbg] B(参数=0): base=tom(15M) cls=kick => is_kick=%b is_tom=%b",
                 u_b.gen_voice[0].is_kick, u_b.gen_voice[0].is_tom);
        chk(u_b.gen_voice[0].is_kick === 1'b0,
            "B1 DRUM_CLS_EXT=0 => parameter gate works: it did NOT listen to drum_cls_i");
        chk(u_b.gen_voice[0].is_tom === 1'b1,
            "B2 DRUM_CLS_EXT=0 => fell back to the internal comparator (base = tom)");

        //  ⭐ 反向组：把两边对调 ⇒ 两个实例必须**仍然各按各的**
        base_inc[0*PHW +: PHW] = KICK_INC;
        drum_cls[0*2 + 1]      = 1'b0;
        drum_cls[0*2 + 0]      = 1'b1;      // ⭐ 嗵鼓位
        repeat (20) @(negedge clk);

        $display("      [dbg] A': base=kick(8M) cls=tom => is_kick=%b is_tom=%b",
                 u_a.gen_voice[0].is_kick, u_a.gen_voice[0].is_tom);
        $display("      [dbg] B': base=kick(8M) cls=tom => is_kick=%b is_tom=%b",
                 u_b.gen_voice[0].is_kick, u_b.gen_voice[0].is_tom);
        chk(u_a.gen_voice[0].is_tom === 1'b1,
            "A3 swap: DRUM_CLS_EXT=1 still follows the external class (tom)");
        chk(u_b.gen_voice[0].is_kick === 1'b1,
            "B3 swap: DRUM_CLS_EXT=0 still follows bv (kick)");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_osc_drum_cls — %0d/%0d judgements held (A3 参数门控 + 零窗口)",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_osc_drum_cls — %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_osc_drum_cls TIMEOUT");
        $finish;
    end

endmodule
