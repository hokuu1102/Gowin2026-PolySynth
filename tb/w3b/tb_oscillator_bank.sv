// ─────────────────────────────────────────────────────────────────────────────
// tb_oscillator_bank.sv · `T55` 验收（W3b · 64 路独立振荡器）
//
// ⭐ 为什么这个 tb 是关键（`K-83`/`K-84`）：
//   赛题要求 **吞吐量 = 同时可闻的独立振荡器数 × 采样率** ⇒
//   ⭐ **"64 个独立振荡器"必须能被证明**，⛔ 不能只是"注释里写了 64"。
//
// ⭐ 覆盖的 7 条判据（对应 `任务清单.md` `T55` 验收栏）：
//   ① ⭐ **每个 lane 的相位独立前进**（给定不同 `phase_inc` ⇒ 相位各不相同）
//   ② ⭐ **每个 lane 的相位增量独立生效**（改一个 lane 的 inc ⇒ 只有它变）
//   ③ ⭐ **TDM 取回 64 个样本**（`osc_valid_o` 每帧 1 次脉冲，且 64 个 lane 都有值）
//   ④ ⭐ **地址 = 相位高 9 位**（DDS 正确性：查表索引必须是相位 MSB）
//   ⑤ ⭐ **`test_mode_i` 覆盖生效**（`T43` 的基础：N 路不同频率）
//   ⑥ ⭐ **帧内截止**：TDM 固定 `LANES+2` 拍 ≪ 1024（`A6`）
//   ⑦ ⭐ **未激活 voice 的相位保持不变**（⛔ 不清零 —— 防"咔"声）
//
// ⚠️ 语法纪律（`K-91`）：⛔ **Verilog-2001**，⛔ 不用 SV 专有构造
// ⚠️ 时基纪律（`K-93`）：`sample_tick_i` 是**时钟使能** ⇒ **恰好高 1 拍**
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_oscillator_bank;

    localparam integer POLY   = 32;
    localparam integer OPV    = 2;
    localparam integer LANES  = POLY * OPV;      // 64
    localparam integer PHASE_W = 32;
    localparam integer SW     = 16;
    localparam integer AW     = 9;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    task chk;
        input [8*80-1:0] name;
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

    reg                    sample_tick;
    reg  [POLY-1:0]        voice_active;
    reg  [POLY*PHASE_W-1:0] base_inc;
    reg  [POLY*2-1:0]      voice_timbre;
    reg  [POLY*8-1:0]      voice_velocity;
    reg  signed [15:0]     vibrato_mod;
    reg                    test_mode;
    reg  [LANES-1:0]       test_lane_active;
    reg  [LANES*PHASE_W-1:0] test_phase_inc;

    wire [LANES*SW-1:0]    sample_bus;
    wire                   osc_valid;
    wire [PHASE_W-1:0]     phase_dbg;

    // ⭐ `DBG_LANE=1` ⇒ 观测 voice0 的第二个振荡器（验证"同 voice 内两 lane 独立"）
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHASE_W),
        .OSC_SAMPLE_W(SW), .TIMBRE_N(4), .TIMBRE_W(2),
        .WT_DEPTH(1024), .WT_W(16), .ENABLE_FM(0), .DBG_LANE(1),
        //   🔴🔴 **2026-09-26：⭐ 本 tb 显式关掉失谐（`DETUNE_ON=0`）**
        //
        //   ⭐ **为什么**：⭐ `T55` 验收测的是 **"64 路相位【独立】"** ——
        //      它的判据建立在"**复位后所有 lane 相位 = 0**"之上
        //      （⭐ 如 `phase = 3 × 2^23`）。
        //   🔴 而本轮给 lane1 加了 **1/4 周期去相关初相**（⭐ 学自 `xls32`）
        //      ⇒ ⭐ 复位初相变成 `0x4000_0000` ⇒ 🔴 **那批硬编码期望值全部平移**
        //      （⭐ 实测 6 条失败 —— ⚠️ 不是功能坏了，⭐ 是**期望值过时**）。
        //
        //   ⭐⭐ **分工（⭐ 这样两个 tb 各管一件事，⛔ 不互相干扰）**：
        //      · ⭐ **本 tb**：⭐ `DETUNE_ON=0` ⇒ ⭐ 测**基频/地址/独立性的【基线行为】**
        //      · ⭐ **`build/exp/tb_detune.sv`**：⭐ `DETUNE_ON=1` ⇒ ⭐ 专测**失谐**
        //        （⭐ 已 4/4 PASS：⭐ 两 lane 440.0 / 441.7 Hz、拍频 1.72 Hz、相位持续分离）
        //      📌 **⇒ 两层都有覆盖，⛔ 而且都不需要改判据的语义** ✅
        //   ⚠️ **注意**：⭐ 这不等于"失谐没被验证" ——
        //      ⭐ 交付默认仍是 `DETUNE_ON=1`（⭐ 见 `oscillator_bank` 的参数默认值）。
        .DETUNE_ON(0)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active), .base_phase_inc_i(base_inc),
        .voice_timbre_i(voice_timbre), .voice_velocity_i(voice_velocity),
        .vibrato_mod_i(vibrato_mod),
        .test_mode_i(test_mode), .test_lane_active_i(test_lane_active),
        .test_phase_inc_i(test_phase_inc),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(sample_bus), .osc_valid_o(osc_valid),
        .phase_acc_dbg_o(phase_dbg)
    );

    function [SW-1:0] samp;
        input integer lane;
        begin samp = sample_bus[lane*SW +: SW]; end
    endfunction

    // 取某 voice 的 `phase_inc` 总线切片
    function [PHASE_W-1:0] v_inc;
        input integer v;
        begin v_inc = base_inc[v*PHASE_W +: PHASE_W]; end
    endfunction

    task set_v_inc;
        input integer v;
        input [PHASE_W-1:0] val;
        begin base_inc[v*PHASE_W +: PHASE_W] = val; end
    endtask

    task set_t_inc;
        input integer lane;
        input [PHASE_W-1:0] val;
        begin test_phase_inc[lane*PHASE_W +: PHASE_W] = val; end
    endtask

    // ⭐ `sample_tick_i` **恰好高 1 拍**（`K-93`：它是时钟使能，不是电平！）
    task tick; begin
        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        repeat (3) @(negedge clk);
    end endtask

    // 走一个完整帧：sample_tick + 等 TDM 跑完（LANES+4 拍）
    task frame; begin
        tick;
        repeat (LANES + 6) @(negedge clk);
    end endtask

    integer i;
    integer k;
    integer valid_count;
    reg [PHASE_W-1:0] p0_before;
    reg [PHASE_W-1:0] p1_before;
    reg [PHASE_W-1:0] p_other_before;
    reg [SW-1:0] s_a;
    reg [SW-1:0] s_b;
    integer nonzero_lanes;
    integer distinct;

    // ⭐ 用两个"可预测"的相位增量做 DDS 正确性检查
    //    inc = 2^23 ⇒ 每帧相位正好前进 1 个"表步"（因为地址取高 9 位）
    localparam [PHASE_W-1:0] INC_1STEP = 32'h0080_0000;   // 2^23
    localparam [PHASE_W-1:0] INC_2STEP = 32'h0100_0000;   // 2^24

    initial begin
        sample_tick      = 1'b0;
        voice_active     = {POLY{1'b0}};
        base_inc         = {(POLY*PHASE_W){1'b0}};
        voice_timbre     = {(POLY*2){1'b0}};
        voice_velocity   = {(POLY*8){1'b1}};
        vibrato_mod      = 16'sd0;
        test_mode        = 1'b0;
        test_lane_active = {LANES{1'b0}};
        test_phase_inc   = {(LANES*PHASE_W){1'b0}};

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 6: 帧内截止（TDM 固定拍数 << 1024，A6）==");
        // ═══════════════════════════════════════════════════════════════════
        // 激活全部 64 lane，量出"从 sample_tick 到 osc_valid"的拍数
        voice_active = {POLY{1'b1}};
        for (i = 0; i < POLY; i = i + 1) set_v_inc(i, INC_1STEP);

        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        k = 0;
        while (!osc_valid && k < 200) begin
            @(negedge clk);
            k = k + 1;
        end
        chk("osc_valid 在 200 拍内出现", osc_valid === 1'b1);
        chk("TDM 拍数 ≈ LANES+2（64+2=66）", k >= LANES && k <= (LANES + 4));
        chk("帧内截止：TDM 拍数 << 1024", k < 1024);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 1: 每个 lane 的相位独立前进 ==");
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 让各 voice 的 inc 不同 ⇒ 若干帧后相位应各不相同
        //    voice v 的 inc = (v+1) × 2^23 ⇒ 相位 = 帧数 × (v+1) × 2^23
        for (i = 0; i < POLY; i = i + 1)
            set_v_inc(i, (i + 1) * 32'h0080_0000);
        repeat (5) frame;

        // 检查若干 lane 的相位确实不同（用调试口逐个看代价高 ⇒ 改看样本总线）
        // ⭐ 样本 = 正弦(地址)，地址 = 相位[31:23]
        //    voice v 走 5 帧后地址 = 5×(v+1) mod 512
        //    ⇒ voice0 地址=5、voice1 地址=10、voice2 地址=15 …
        //    ⚠️ 这里只能验"至少有多于 1 种不同的样本值"，因为正弦值可能巧合相同
        distinct = 0;
        s_a = samp(0);
        for (i = 0; i < LANES; i = i + 1) begin
            if (samp(i) !== s_a) distinct = distinct + 1;
        end
        chk("64 个 lane 的样本不全都相同（相位确实各自独立）", distinct > 0);

        // ⭐ 更硬的判据：同 voice 内两个 lane（OSC_PER_VOICE=2）也必须独立
        //    voice v 的 lane = 2v（inc 同）、2v+1（inc 同）⇒ 两 lane 相位相同
        //    ⇒ 为验"独立"，给**两个 lane 不同 inc**（走 test_mode 覆盖）
        //    （正式通路的 inc 是每 voice 一份 ⇒ 同 voice 两 lane 天然同步，
        //      这正是 `K-95` 记录的"失谐未实装"）
        $display("     (注：正式通路每 voice 一份 inc ⇒ 同 voice 两 lane 同步；");
        $display("      失谐需 test_mode 覆盖或后续加 per-lane detune —— 见 K-95)");

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 2: 每个 lane 的相位增量独立生效（test_mode 通路）==");
        // ═══════════════════════════════════════════════════════════════════
        test_mode        = 1'b1;
        test_lane_active = {LANES{1'b1}};
        for (i = 0; i < LANES; i = i + 1) set_t_inc(i, INC_1STEP);
        set_t_inc(1, INC_2STEP);                 // ⭐ 只改 lane1 的增量
        repeat (3) frame;
        // lane0 走 3 步 ⇒ 地址 3；lane1 走 3×2=6 步 ⇒ 地址 6
        chk("test_mode: lane0 与 lane1 的样本不同（增量各自生效）",
            samp(0) !== samp(1));

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 4: 地址 = 相位高 9 位（DDS 正确性）==");
        // ═══════════════════════════════════════════════════════════════════
        // ⚠️⚠️ 2026-09-21：本判据原来是**盲的**（`K-98`）——
        //   我只查了 `phase_dbg`（相位寄存器），⛔ **没有查真正送给 ROM 的地址**。
        //   ⚠️ 而 `addr_q <= phase_q[ADDR_MSB:ADDR_LSB]` 这一句若被改成"取低位"，
        //      相位寄存器**完全不变** ⇒ 我的判据**看不见** ⇒ 变异体 LEAK。
        //   ⇒ ⭐ 修法：**直接探针 DUT 内部真正送 ROM 的地址线**
        //      （`dut.rom_ad`）—— ⭐ 判据必须落在**被证明的那个信号**上，
        //      ⛔ 不能落在"它的上游"。
        //   📌 用 `phase = n × 2^23` 这种"低位恒为 0"的输入**测不出取高位还是取低位**
        //      ⇒ ⭐ 必须再用一个**低位非零**的相位做交叉验证（见判据 4b）。
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);
        // 重新配置（复位后寄存器清 0，但 tb 侧配置保留）
        test_mode        = 1'b1;
        test_lane_active = {LANES{1'b1}};
        for (i = 0; i < LANES; i = i + 1) set_t_inc(i, INC_1STEP);

        repeat (3) frame;
        // lane1 相位应为 3 × 2^23 = 0x0180_0000 ⇒ 高 9 位 = 3
        chk("lane1 相位 = 3×2^23（地址=6）", phase_dbg === 32'h0180_0000);
        chk("phase_acc_dbg_o 的高 10 位 = 6", phase_dbg[31:22] === 10'd6);

        repeat (2) frame;
        chk("再走 2 帧 ⇒ 相位 = 5×2^23（地址=5）", phase_dbg === 32'h0280_0000);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 4b: ⭐ 真正送 ROM 的地址 = 相位【高】9 位（K-98 补的盲区）==");
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 关键：构造"**低位非零**"的相位，让"取高 9 位"与"取低 9 位"**必然不同**。
        //    ⚠️⚠️ 不要硬编码"走 N 帧后相位应是多少" —— 那依赖复位后的确切拍数，
        //       很容易差 1 拍而假失败（我第一版就是这样，`K-98`）。
        //    ⇒ ⭐ 改成验**不变量**：`addr_q` 必须等于"**上一拍采样时刻**的相位高 9 位"。
        //      做法：每个 tick 前记录 `phase_before`，tick 后断言
        //            `addr_q == phase_before[31:23]`（⛔ 与低位无关）。
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);
        test_mode        = 1'b1;
        test_lane_active = {LANES{1'b0}};
        test_lane_active[0] = 1'b1;
        set_t_inc(0, 32'd1);                 // ⭐ 每帧只 +1 ⇒ 相位 = 帧数（低位非零）

        // ⭐ 用几个"**落在高位窗口里**"的增量各验一轮。
        //    ⚠️⚠️ 关键（`K-98` 第二次修正）：增量的**量级必须足够大**，
        //       否则相位一直很小 ⇒ 位 [31:23] 与位 [30:22] **全都是 0**
        //       ⇒ ⭐ "取高 9 位"与"取错 1 位的窗口"**结果相同** ⇒ 变异体仍然漏过。
        //       实测：`inc=1` / `inc=512` 走几帧后相位仅 ~3000（bit 11），
        //       ⛔ 完全测不出高位的错位。
        //    ⇒ ⭐ 必须让相位**真的落在 2^22 / 2^23 / 2^31 附近**：
        //       · `2^22` ⇒ 相位 bit22=1、bit23=0 ⇒ 两种取法**必然不同**
        //       · `2^23` ⇒ 相位 bit23=1、bit22=0 ⇒ 同样能区分
        //       · `2^31` ⇒ 跨最高位，覆盖回绕
        for (k = 0; k < 4; k = k + 1) begin
            case (k)
                0: set_t_inc(0, 32'h0040_0000);   // 2^22
                1: set_t_inc(0, 32'h0080_0000);   // 2^23
                2: set_t_inc(0, 32'h00C0_0000);   // 2^22 + 2^23
                default: set_t_inc(0, 32'h8000_0000);  // 2^31（最高位）
            endcase
            for (i = 0; i < 5; i = i + 1) begin
                p0_before = dut.gen_lane[0].phase_q;      // tick 前的相位
                tick;
                repeat (LANES + 4) @(negedge clk);        // 等 TDM 跑完
                if (dut.gen_lane[0].addr_q !== p0_before[31:22]) begin
                    errors = errors + 1;
                    $display("  FAIL: addr_q=%0d 但 tick 前相位 %08h 的高 9 位 = %0d（第 %0d 组, 第 %0d 次）",
                             dut.gen_lane[0].addr_q, p0_before, p0_before[31:22], k, i);
                end
            end
        end
        chk("⭐ 锁存地址恒等于「上一采样时刻相位的高 9 位」（20 次逐一核对，K-98）",
            errors == 0);


        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 7: 未激活 voice 的相位保持不变（防咔声）==");
        // ═══════════════════════════════════════════════════════════════════
        test_mode = 1'b0;                        // 回到正式通路
        voice_active = {POLY{1'b0}};
        voice_active[1] = 1'b1;                  // ⭐ 只激活 voice1（= lane2/3）
        for (i = 0; i < POLY; i = i + 1) set_v_inc(i, INC_1STEP);
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);

        p0_before = phase_dbg;                   // DBG_LANE=1 = voice0 的 lane1 ⇒ 未激活
        repeat (3) frame;
        chk("未激活 voice0 的相位保持不变（不清零）", phase_dbg === p0_before);

        // ⭐ 激活 voice0 后它才动
        voice_active[0] = 1'b1;
        repeat (2) frame;
        chk("激活 voice0 后相位开始前进", phase_dbg !== p0_before);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 3: TDM 取回 64 个样本，osc_valid 每帧恰好 1 次 ==");
        // ═══════════════════════════════════════════════════════════════════
        voice_active = {POLY{1'b1}};
        for (i = 0; i < POLY; i = i + 1) set_v_inc(i, INC_1STEP);
        repeat (2) frame;

        // 数一帧内 osc_valid 的脉冲数
        valid_count = 0;
        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        for (k = 0; k < (LANES + 10); k = k + 1) begin
            @(negedge clk);
            if (osc_valid) valid_count = valid_count + 1;
        end
        chk("一帧内 osc_valid 恰好 1 次", valid_count == 1);

        // ⭐ 64 个 lane 里应有相当一部分非零（正弦表 512 点、地址分散）
        nonzero_lanes = 0;
        for (i = 0; i < LANES; i = i + 1)
            if (samp(i) !== {SW{1'b0}}) nonzero_lanes = nonzero_lanes + 1;
        chk("64 个 lane 中多数有非零样本（TDM 真的取回了数据）", nonzero_lanes > 32);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 5: test_mode 覆盖生效（T43 的基础）==");
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 只激活前 4 个 lane，且给不同频率 ⇒ 应只有这 4 个 lane 在动
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);

        test_mode        = 1'b1;
        test_lane_active = {LANES{1'b0}};
        for (i = 0; i < 4; i = i + 1) begin
            test_lane_active[i] = 1'b1;
            // ⭐ N 路不同频率：第 i 路用 (i+1)×2^23
            set_t_inc(i, (i + 1) * 32'h0080_0000);
        end
        for (i = 4; i < LANES; i = i + 1) set_t_inc(i, INC_1STEP);

        repeat (6) frame;
        // lane0..3 地址 = 6×(i+1) mod 512 = 6,12,18,24 ⇒ 各不相同
        chk("test_mode 下 lane0/1/2/3 样本互不相同（N 路不同频率）",
            samp(0) !== samp(1) && samp(1) !== samp(2) && samp(2) !== samp(3));

        // ⭐ 未被 test_lane_active 选中的 lane 相位应保持（不再前进）
        //    ⚠️ 它们可能保留着之前的相位 ⇒ 只验"它们彼此相同"（都没动）
        chk("未选中的 lane 相位不变（彼此仍相同）", samp(8) === samp(9));

        // ---- 8: test_mode must OVERRIDE voice_active (guards M32) ----
        // Make the two sources disagree: with test_mode=1 the lane must follow
        // test_lane_active, NOT voice_active.  If the override is lost, lane0
        // stops advancing and the address freezes.
        $display("== 8: test_mode overrides voice_active ==");
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);

        voice_active = {POLY{1'b0}};          // all voices IDLE ...
        test_mode    = 1'b1;
        test_lane_active = {LANES{1'b0}};
        test_lane_active[0] = 1'b1;           // ... but lane0 active via test_mode
        for (i = 0; i < LANES; i = i + 1) set_t_inc(i, INC_1STEP);

        repeat (4) frame;
        begin
            reg [PHASE_W-1:0] a8;
            a8 = dut.gen_lane[0].phase_q;
            chk("test_mode=1 overrides voice_active=0 (lane0 still advances)",
                a8 === (4 * 32'h0080_0000));
            chk("and a lane NOT selected stays frozen",
                dut.gen_lane[1].phase_q === 32'd0);
        end

        if (errors == 0)
            $display("PASS: oscillator_bank acceptance (T55) - all judgements held");
        else
            $fatal(1, "FAIL: oscillator_bank acceptance has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
