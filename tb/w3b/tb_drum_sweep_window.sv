// ─────────────────────────────────────────────────────────────────────────────
// tb_drum_sweep_window.sv · ⭐ `P0-31` 专用判据（鼓扫频深度 · 32 拍轮转窗口）
//
// ⭐ **被测缺陷**（⭐ 审查 `[P0-31]`，⭐ `ANVIL-02【P0-4】`）：
//    ⭐ `oscillator_bank` 的**扫频深度**是 `bv >> (LSB_SH + 本档 SH)`
//       —— ⚠️ 而 `bv` = `base_phase_inc_i[vg]` = `note_manager.phase_tr[vg]`
//    🔴 **`phase_tr[]` 是【轮转刷新】的**：`rot_cnt` 自由运行（5 位）⇒
//       ⭐ **每条 lane 每 32 拍才被重写一次**（⭐ 写口还有 1 拍流水 ⇒ ≤33 拍）
//    ⇒ 🔴 **"提交"（改 `phase_r`）与"起音"（`voice_phase_rst_i`）可能只差 1 拍**
//       ⇒ ⭐ 起音那一拍读到的 `bv` **还是【上一件鼓】的值** ✅
//
//    📌 **为什么分类对、深度错**：⭐ `A3` 的正确修法把**分类**（`is_kick`/`is_tom`）
//       搬到了 `note_manager.ST_COMMIT2`（⭐ 提交当拍锁存 ⇒ ⭐ **零窗口** ✅）
//       —— 🔴 但**深度**仍然乘 `bv`（⭐ 那条**轮转**的路）⇒ ⭐ **深度这一半仍是旧值** ✅
//       ⇒ ⭐ 于是"**用新鼓的档位**去乘**旧鼓的音高**" ⇒ 🔴 深度错得离谱 ✅
//
// ⭐ **实测数字（⭐ 用 `top.v` 的生产参数：`LSB_SH=8` · `KICK_SH=0` · `TOM_SH=3`）**
//    · ⭐ 底鼓(5_368_709)紧跟嗵鼓(17_895_697)：
//        ⭐ 期望 `17_895_697 >> 11` = **8738** ⚠️ 实得 `5_368_709 >> 11` = **2621**
//        ⇒ 🔴 **浅 3.33×** ✅
//    · ⭐ 嗵鼓紧跟底鼓：
//        ⭐ 期望 `5_368_709 >> 8` = **20971** ⚠️ 实得 `17_895_697 >> 8` = **69905**
//        ⇒ ⭐ 超 16 位 ⇒ ⭐ **截断成 4369** ⇒ 🔴 **深 4.8×（且带截断）** ✅
//    📌 ⭐ 本 tb 的期望值**全部由 `localparam` 现算**（⛔ 不写死十进制常量）
//       —— ⭐ 免掉"报告里写 8739、而 `>>` 的真实结果 8738"这类**抄写错误** ✅
//
// ⭐ **判据设计（⭐ 两条独立观测，⭐ 都必须是"未修复能红"）**：
//    ① ⭐ **白盒**：⭐ `u_dut.gen_voice[0].sweep_q` 在窗口内的**最大值**
//       （⭐ = 装载值；⭐ 同 `tb_osc_drum_cls` 的层次引用手法 ✅）
//    ② ⭐ **端到端**：⭐ 每采样拍**相位增量**（`phase_acc_dbg_o` 差分）的最大值
//       = `bv + (sweep_q << LSB_SH)`（⭐ `DETUNE_ON=0` ＋ 颤音 0 ⇒ 无其它项 ✅）
//       ⇒ ⭐ 它证明"装载值**真的走进了相位通路**"（⛔ 不是只改了寄存器）✅
//    ⭐ 判据 ① 绿而 ② 红 ⇒ 说明装载对了但没生效 ⇒ ⭐ 分开报，⛔ 不合并 ✅
//    📌 **为什么取"最大值"**：⭐ 扫频是**指数衰减**的 ⇒ ⭐ 峰值**就是装载值** ✅
//
// ⭐⭐ **非空洞性（⭐ 本 tb 的核心，⛔ 不是可选项）**：
//    ⭐ 场景 `W2` 与 `W1` **只差一件事**：`base_phase_inc_i` 是"**起音当拍就刷新**"
//       还是"**起音之后才刷新**"（⭐ 后者 = 硬件里 `phase_tr` 轮转的真实行为 ✅）
//    ⇒ ⭐ `W2` **必须始终绿**（⭐ 未修复时也绿）——
//       它证明：⭐ **红是"窗口"造成的，⛔ 不是"判据本身不成立"** ✅
//    🔴 **若 `W2` 也红** ⇒ ⭐ 说明本 tb 的激励/测量有 bug ⇒ ⭐ `W1` 的红**不可信** ✅
//
// ⚠️⚠️ **时基纪律（⭐ 本 tb 唯一的坑，⭐ 已实测踩到并修正）**：
//    ⭐ tb 里 `sample_tick` 是**自己用 `<=` 驱动的 reg** ⇒
//    ⚠️ **DUT 在 `posedge clk` 的 active 区读到的仍是【旧值 0】**
//    ⇒ 🔴 **DUT 真正做采样拍工作的时刻 = `@(posedge sample_tick)` 之后【再一个】 `posedge clk`**
//       （⭐ 实测：`@(posedge sample_tick)` 在 630000，而 DUT 的采样拍在 650000 ✅）
//    ⇒ ⭐ 所以本 tb 的"起音"必须落在 **`@(posedge sample_tick)` 后的第 1 个 negedge**
//       （⭐ = DUT 采样拍**前 1 拍**），⭐ 而"刷新 `base_inc`"落在**再下一个** negedge
//       （⭐ = DUT 采样拍**后 1 拍**）✅
//    📌 ⭐ 若忽略这条 ⇒ ⚠️ 起音落在 DUT 采样拍**之后** ⇒ 🔴 **窗口永远踩不到、判据假绿** ✅
// ⚠️ 层次引用（⭐ `u_dut.gen_voice[0].sweep_q`）：⭐ 与 `tb_osc_drum_cls.sv` 同一手法，
//    ⭐ `iverilog -g2012` 已实测支持 ✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_drum_sweep_window;

    localparam integer POLY  = 1;
    localparam integer OPV   = 2;
    localparam integer LANES = POLY * OPV;
    localparam integer PHW   = 32;
    localparam integer SW    = 16;
    //  ⭐ 采样节拍间隔（⭐ 本 tb 只看**采样域** ⇒ ⛔ 不必是设计的 1024 ✅）
    localparam integer FRAME_GAP = 16;

    //  ⭐ 与 `drum_gen` / `top.v` **逐字同口径**的音高（⭐ `inc = f × 2^32 / 48828.125`）
    localparam integer KICK_INC = 5_368_709;     // ⭐ ≈60 Hz（真实底鼓）
    localparam integer TOM_INC  = 17_895_697;    // ⭐ ≈200 Hz（真实嗵鼓）

    //  ⭐ 与 `top.v` 生产例化**同值**的扫频参数
    localparam integer KICK_SH = 0;
    localparam integer TOM_SH  = 3;
    localparam integer LSB_SH  = 8;

    //  ⭐ 期望深度（⭐ 用**新**音高算）
    localparam [15:0] DEPTH_TOM  = TOM_INC  >> (LSB_SH + TOM_SH);    // 8738
    localparam [15:0] DEPTH_KICK = KICK_INC >> (LSB_SH + KICK_SH);   // 20971
    //  🔴 未修复时会拿到的深度（⭐ 用**旧**音高算）
    localparam [15:0] STALE_FOR_TOM  = KICK_INC >> (LSB_SH + TOM_SH);   // 2621
    localparam [15:0] STALE_FOR_KICK = TOM_INC  >> (LSB_SH + KICK_SH);  // 69905 -> 4369

    //  ⭐ 端到端期望：⭐ 装载那一拍**之后**，相位增量 = `新音高 + (深度 << LSB_SH)`
    localparam integer DELTA_TOM  = TOM_INC  + (DEPTH_TOM  * 256);
    localparam integer DELTA_KICK = KICK_INC + (DEPTH_KICK * 256);
    localparam integer BAD_DELTA_TOM  = TOM_INC  + (STALE_FOR_TOM  * 256);
    localparam integer BAD_DELTA_KICK = KICK_INC + (STALE_FOR_KICK * 256);

    //  ⭐ 鼓分类位（⭐ `drum_cls_i[vg*2+1]` = 底鼓 · `[vg*2+0]` = 嗵鼓 ✅）
    localparam [1:0] CLS_KICK = 2'b10;
    localparam [1:0] CLS_TOM  = 2'b01;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;

    reg                     sample_tick;
    reg  [POLY-1:0]         voice_active;
    reg  [POLY-1:0]         voice_phase_rst;
    reg  [POLY-1:0]         voice_drum;
    reg  [POLY*2-1:0]       drum_cls;
    reg  [POLY*PHW-1:0]     base_inc;
    reg  [POLY*2-1:0]       voice_timbre;
    reg  [POLY*8-1:0]       voice_velocity;
    reg  signed [15:0]      vibrato;
    reg                     test_mode;
    reg  [LANES-1:0]        test_lane_active;
    reg  [LANES*PHW-1:0]    test_phase_inc;

    wire [LANES*SW-1:0]     bus_o;
    wire                    vld_o;
    wire [PHW-1:0]          dbg_phase;

    //  ⭐ 生产档参数（⭐ 与 `top.v` 的例化逐项同值 ✅）
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHW), .OSC_SAMPLE_W(SW),
        .TIMBRE_N(4), .TIMBRE_W(2), .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
        .VIB_REF_INC(38_700_000), .DBG_LANE(0),
        //   ⭐ 关失谐：⭐ 让相位增量**只有** `bv + so_v` ⇒ ⭐ 判据 ② 的算式**无第三项** ✅
        .DETUNE_ON(0), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(LSB_SH),
        .DRUM_KICK_SWEEP_SH(KICK_SH), .DRUM_TOM_SWEEP_SH(TOM_SH),
        .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(20_000_000),
        .DRUM_CLICK_EN(0),
        .DRUM_CLS_EXT(1)                      // ⭐ 生产档：分类由 `note_manager` 给（零窗口）
    ) u_dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .voice_phase_rst_i(voice_phase_rst),
        .base_phase_inc_i(base_inc), .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity), .voice_drum_i(voice_drum),
        .drum_cls_i(drum_cls),
        .vibrato_mod_i(vibrato), .test_mode_i(test_mode),
        .test_lane_active_i(test_lane_active), .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(bus_o), .osc_valid_o(vld_o), .phase_acc_dbg_o(dbg_phase)
    );

    // ── 采样节拍（⭐ = 时钟使能，⭐ 恰好高 1 拍 ✅）────────────────────────────
    integer gap = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            gap         <= 0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (gap >= FRAME_GAP - 1) begin
                gap         <= 0;
                sample_tick <= 1'b1;
            end else begin
                gap <= gap + 1;
            end
        end
    end

    // ── 判据记账 ────────────────────────────────────────────────────────────
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ── 观测累加器 ──────────────────────────────────────────────────────────
    integer       max_sweep;      // ⭐ 窗口内 `sweep_q` 的最大值（⭐ = 装载值 ✅）
    integer       sq_at_onset;    // ⭐ DUT 起音拍**之后**立刻读到的 `sweep_q`（⭐ 仅 info）
    reg [PHW-1:0] ph_prev;
    reg [PHW-1:0] ph_cur;
    reg [PHW-1:0] max_delta;      // ⭐ 窗口内"每采样拍相位增量"的最大值 ✅
    reg [15:0]    sq_now;

    //  ⭐ 读**一个 DUT 采样拍之后**的状态（⭐ 见文件头的时基纪律 ✅）
    //     `@(posedge sample_tick)` 落在 DUT 采样拍**前 2 拍**
    //     ⇒ 第 1 个 negedge = 前 1 拍（⛔ 还没更新）
    //     ⇒ 第 2 个 negedge = 后 1 拍（✅ 已更新）
    task tick_and_read;
        begin
            @(posedge sample_tick);
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    task measure_samples;
        input integer n;
        integer       j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                tick_and_read;
                sq_now = u_dut.gen_voice[0].sweep_q;
                if (sq_now > max_sweep[15:0]) max_sweep = sq_now;
                ph_cur   = dbg_phase;
                if ((ph_cur - ph_prev) > max_delta) max_delta = ph_cur - ph_prev;
                ph_prev  = ph_cur;
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐ 场景：⭐ "同一 voice 上先后两件**不同**鼓" —— ⭐ 唯一会踩到窗口的时序 ✅
    //    · `old_inc` / `new_inc`：⭐ 提交前后的音高（⭐ `phase_tr` 轮转 ⇒ **滞后** ✅）
    //    · `new_cls`           ：⭐ 新档分类（⭐ **提交当拍就新鲜** ✅ —— 这是 `A3` 的成果）
    //    · `with_window`       ：⭐ 1 = `base_inc` 在起音**之后**才刷新（⭐ 硬件真实行为）
    //                            ⭐ 0 = 起音**之前**就刷新（⭐ 非空洞性对照 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    task run_scenario;
        input integer       old_inc;
        input [1:0]         new_cls;
        input integer       new_inc;
        input integer       with_window;
        input [15:0]        exp_depth;
        input [15:0]        stale_depth;
        input integer       exp_delta;
        input integer       stale_delta;
        input [1023:0]      label;
        begin
            // ① ⭐ 复位 ⇒ ⭐ `sweep_q` 必为 0（⭐ 起音前的状态**确定** ✅）
            rst_n           = 1'b0;
            voice_active    = {POLY{1'b0}};
            voice_phase_rst = {POLY{1'b0}};
            voice_drum      = {POLY{1'b0}};
            drum_cls        = {(POLY*2){1'b0}};
            base_inc        = {(POLY*PHW){1'b0}};
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);

            // ② ⭐ 静置：⭐ 鼓 voice **不响**、⭐ 但音高已是【旧值】
            //     （⭐ 真实硬件里这就是"上一件鼓刚提交、轮转还没刷到本 lane"的状态 ✅）
            voice_drum[0]          = 1'b1;
            base_inc[0*PHW +: PHW] = old_inc[PHW-1:0];
            repeat (4) @(negedge clk);

            // ③ ⭐ 对齐到"**DUT 采样拍的前 1 拍**"（⭐ 见文件头的时基纪律 ✅）
            @(posedge sample_tick);       // ⭐ DUT 采样拍 − 2 拍
            @(negedge clk);               // ⭐ DUT 采样拍 − 1 拍

            // ④ ⭐ **起音**（⭐ 分类是【新】的 —— `A3` 已保证提交当拍锁存 ✅）
            //     ⚠️ `base_inc` **仍是旧值**（⭐ 窗口档 ⇒ 轮转尚未刷到 ✅）
            voice_active[0]    = 1'b1;
            voice_phase_rst[0] = 1'b1;
            drum_cls[0*2 +: 2] = new_cls;
            if (with_window == 0)
                base_inc[0*PHW +: PHW] = new_inc[PHW-1:0];

            // ⑤ ⭐ DUT 在**下一拍**看到这次起音 ⇒ ⭐ 装载就在这里发生 ✅
            //     📌 相位也在这一拍被复位到 `phase_seed`（⭐ 本档 = 0）
            //        ⇒ ⭐ 它的"增量"是**无意义的大数** ⇒ ⭐ 必须从下一拍才开始量 ✅
            @(negedge clk);               // ⭐ DUT 采样拍 + 1 拍
            ph_prev      = dbg_phase;
            sq_at_onset  = u_dut.gen_voice[0].sweep_q;
            voice_phase_rst[0] = 1'b0;    // ⭐ 释放复位电平（⭐ 保持超过一拍会反复触发 ✅）
            if (with_window != 0)
                base_inc[0*PHW +: PHW] = new_inc[PHW-1:0];   // ⭐ 轮转"到位" ✅

            // ⑥ ⭐ 观察 24 个采样拍（⭐ 装载 + 之后几拍衰减 ✅）
            //     ⚠️ **必须把"起音拍"也算进窗口**：⭐ 扫频**指数衰减** ⇒
            //        ⭐ 峰值**恰好**出现在装载生效的那一拍
            //        —— ⭐ 未修复时那一拍是**起音拍本身**（⭐ 已经在 ⑤ 读进 `sq_at_onset`）
            //        —— ⭐ 修复后那一拍是**起音拍的下一拍**（⭐ 由 `measure_samples` 覆盖）
            //     📌 ⭐ 若从下一拍才开始算 ⇒ 🔴 **W2（非空洞性对照）会假红**
            //        （⭐ 实测：W2 拿到 8729 而不是 8738 ⇒ 判据 ① 误报 ✅）
            max_sweep = sq_at_onset;
            max_delta = {PHW{1'b0}};
            measure_samples(24);

            $display("");
            $display("== %0s ==", label);
            $display("   info: 旧音高=%0d 新音高=%0d · 窗口=%0d", old_inc, new_inc, with_window);
            $display("   info: 期望深度=%0d · 未修复会拿到=%0d", exp_depth, stale_depth);
            $display("   info: 实测 起音拍 sweep_q=%0d · 窗口内 max sweep_q=%0d",
                     sq_at_onset, max_sweep);
            $display("   info: 期望相位增量=%0d · 未修复会是=%0d · 实测 max=%0d",
                     exp_delta, stale_delta, max_delta);

            //  ⭐ 判据 ①（⭐ 白盒）：⭐ `sweep_q` 的**装载值**必须用**新**音高算
            chk((max_sweep[15:0] === exp_depth),
                {label, " : sweep_q loaded from the NEW pitch (not the stale one)"});
            //  ⭐ 判据 ②（⭐ 端到端）：⭐ 装载值**必须走进相位通路**
            chk((max_delta === exp_delta[PHW-1:0]),
                {label, " : per-sample phase step == NEW_INC + depth<<8 (end-to-end)"});
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    //  ⭐ 三个场景（⭐ `W2` 是**非空洞性对照**，⭐ 未修复时**也必须绿** ✅）
    // ═════════════════════════════════════════════════════════════════════════
    initial begin
        sample_tick      = 1'b0;
        voice_active     = {POLY{1'b0}};
        voice_phase_rst  = {POLY{1'b0}};
        voice_drum       = {POLY{1'b0}};
        drum_cls         = {(POLY*2){1'b0}};
        base_inc         = {(POLY*PHW){1'b0}};
        voice_timbre     = {(POLY*2){1'b0}};
        voice_velocity   = {(POLY*8){8'd200}};
        vibrato          = 16'sd0;
        test_mode        = 1'b0;
        test_lane_active = {LANES{1'b0}};
        test_phase_inc   = {(LANES*PHW){1'b0}};

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        $display("=== tb_drum_sweep_window (P0-31: 鼓扫频深度 32 拍轮转窗口) ===");
        $display("   KICK=%0d TOM=%0d · LSB_SH=%0d KICK_SH=%0d TOM_SH=%0d",
                 KICK_INC, TOM_INC, LSB_SH, KICK_SH, TOM_SH);

        //  ⭐ W1：⭐ 底鼓紧跟嗵鼓 ⇒ ⭐ 未修复 **浅 3.33×**（2621 vs 8738）✅
        run_scenario(KICK_INC, CLS_TOM, TOM_INC, 1,
                     DEPTH_TOM, STALE_FOR_TOM, DELTA_TOM, BAD_DELTA_TOM,
                     "W1 kick->tom (WINDOW: base_inc refreshes AFTER the onset tick)");

        //  ⭐ W2：⭐ **非空洞性对照** —— ⭐ 与 W1 **只差**"刷新时机" ✅
        //     ⇒ ⭐ 必须**始终绿**（⭐ 未修复时也绿）⇒ ⭐ 证明 W1 的红来自窗口 ✅
        run_scenario(KICK_INC, CLS_TOM, TOM_INC, 0,
                     DEPTH_TOM, STALE_FOR_TOM, DELTA_TOM, BAD_DELTA_TOM,
                     "W2 kick->tom (NO WINDOW: base_inc refreshes BEFORE the onset tick)");

        //  ⭐ W3：⭐ 嗵鼓紧跟底鼓 ⇒ ⭐ 未修复 **深 4.8× ＋ 16 位截断**（4369 vs 20971）✅
        run_scenario(TOM_INC, CLS_KICK, KICK_INC, 1,
                     DEPTH_KICK, STALE_FOR_KICK, DELTA_KICK, BAD_DELTA_KICK,
                     "W3 tom->kick (WINDOW: base_inc refreshes AFTER the onset tick)");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_drum_sweep_window - %0d/%0d judgements held",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_drum_sweep_window - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗（⭐ 本 tb 只有几百拍 ⇒ 200 万拍远远够，⭐ 只在真挂死时触发 ✅）
    initial begin
        #2_000_000;
        $display("FAIL: tb_drum_sweep_window TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
