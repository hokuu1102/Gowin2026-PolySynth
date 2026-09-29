// ─────────────────────────────────────────────────────────────────────────────
// tb_nm_off_in_hold.sv · B3 回归判据：**重触发压低期间，note_off 必须能清掉 gate**
//
// ⭐ 来源：`build/exp/vprobe/vprobe_rt2.cpp`（Verilator 定向探针，⚠️ **未入库**）
//    ⭐ 探针只能"一次性证明"，⛔ 不能防回归 ⇒ 本 tb 把它的判据**照搬**成仓库 tb。
//
// 🔴 守的缺陷（`note_manager.v` 的 `note_off` 分支用错了 mask，2026-09-28 已修）：
//      off 分支用 `gate_mask[i] = gate_r[i] & ~hold_mask[i]`，而**压低期间 `hold_mask=1`**
//      ⇒ `gate_mask[i]=0` ⇒ **跳过该 voice**；同时 (f) 段每拍把它抬回 1
//      ⇒ ⭐ **清了又被拉回** ⇒ 🔴 **永久挂音**
//        （用户实测：按同键 / 所有键都清不掉、只能断电、音高=该轴对应的键）
//   ✅ 修法：off 判据改用 `gate_r | retrig_low`，**并同时清掉 `retrig_low` 位**
//      ⇒ (g) 段在 (f) 段之后 ⇒ **`note_off` 无条件优先**。
//
// ⭐ 判据（机械可判定）：
//      按轴 A(note_on) → 立刻再按轴 A(note_on)（进重触发压低窗口）
//      → 对齐相位发 note_off(A) → 静默 2 帧
//      ⇒ ⭐ `voice_gate[该 voice]` 必须为 0
//         0 => ✅ PASS
//         1 => 🔴 FAIL（永久挂音）
//
// ⭐⭐ 关键：**必须精确扫描相位**（`sample_tick` 附近：1016..1023 + 0..7）
//      ⛔ 粗步长会**跳过触发窗口** —— ⭐ 这正是第一次没测出来的原因。
//      📌 修复前实测：`off_phase=1021` ⇒ gate=1（STUCK）；修复后：**32 个相位全 0**。
//
// ⚠️ 时基与探针**逐拍一致**：`CLK_PER_SAMPLE=1024`、`sample_tick` 只高 **1 拍**
//    （`K-93`）。⚠️ `note_off` 的对齐用**相位循环**（`tick_cnt == off_phase`），
//    ⛔ 不是"等固定拍数" —— 两者在相位上并不等价。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_nm_off_in_hold;

    localparam integer POLY           = 32;
    localparam integer AXIS_W         = 4;
    localparam integer PHASE_W        = 32;
    localparam integer VEL_W          = 8;
    localparam integer TIMBRE_W       = 2;
    localparam integer ENV_W          = 16;
    localparam integer AGE_W          = 16;
    localparam integer IDX_W          = 5;        // $clog2(32)
    // ⭐ 与 Verilator 探针 `vprobe_rt2.cpp` 的 `tick_cnt` 周期**完全一致**（⛔ 别改成 64）
    localparam integer CLK_PER_SAMPLE = 1024;
    localparam [AXIS_W-1:0] AXIS_A    = 4'd3;     // ⭐ 探针用的轴位

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors    = 0;
    integer n_cleared = 0;
    integer n_stuck   = 0;
    integer n_invalid = 0;

    task chk;
        input [8*120-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // 时基 · `sample_tick` 生成（⭐ 与探针 `tick_cnt` 逐拍等价，见 tb_nm_reuse_tail）
    // ═════════════════════════════════════════════════════════════════════════
    reg [10:0] tick_cnt = 11'd0;
    always @(posedge clk) begin
        if (tick_cnt == CLK_PER_SAMPLE - 1) tick_cnt <= 11'd0;
        else                                tick_cnt <= tick_cnt + 11'd1;
    end
    wire sample_tick = (tick_cnt == CLK_PER_SAMPLE - 1);

    // ═════════════════════════════════════════════════════════════════════════
    // DUT · `note_manager`（32 voice）+ 真 `envelope_bank`
    //   ⚠️ 参数与探针的包装 `vprobe_nm_leak.v` **逐项一致**
    // ═════════════════════════════════════════════════════════════════════════
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;

    wire [POLY-1:0]          voice_gate;       // ⭐ 判据读的就是它（= `gate_mask`）
    wire [POLY-1:0]          voice_active;
    wire [POLY-1:0]          voice_releasing;
    wire [POLY*AXIS_W-1:0]   voice_axis;
    wire [POLY*PHASE_W-1:0]  voice_phase_inc;
    wire [POLY*VEL_W-1:0]    voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY*AGE_W-1:0]    voice_age;
    wire [POLY-1:0]          voice_retrig_reset;
    wire                     alloc_valid;
    wire [IDX_W-1:0]         alloc_voice;

    wire [POLY-1:0]          env_active;
    wire [POLY*ENV_W-1:0]    env_level;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W), .FIFO_DEPTH(32)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        // ⭐ A1：本 tb 只有**单一来源**（手弹/live = 0）⇒ 恒接 0（⭐ 行为与加此端口前一致）
        .note_src_i(2'd0),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_age_o(voice_age),
        .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ── ⭐ 分配器给的是【最低空闲 voice】⇒ 必须跟踪**实际被 gate 的那一位** ────
    //    （⛔ 不能写死 voice0：抢占/复用逻辑一变，写死的判据就会打在错的 voice 上）
    function integer gated_bit;
        integer i2;
        begin
            gated_bit = -1;
            for (i2 = 0; i2 < POLY; i2 = i2 + 1)
                if ((gated_bit < 0) && voice_gate[i2]) gated_bit = i2;
        end
    endfunction

    // ── 激励任务（⭐ 与探针的 `clkn` / `tick_n` / `pulse` 逐拍等价）────────────
    task clkn;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) @(negedge clk);
        end
    endtask

    task tick_n;
        input integer n;
        begin
            clkn(CLK_PER_SAMPLE * n);
        end
    endtask

    task pulse;
        input [AXIS_W-1:0] ax;
        input [1:0]        kd;
        begin
            note_valid = 1'b1;
            note_axis  = ax;
            note_kind  = kd;
            @(negedge clk);
            note_valid = 1'b0;
            note_kind  = 2'd0;
        end
    endtask

    // ── 单个用例的观测量 ──────────────────────────────────────────────────────
    integer r_gate;      // ⭐ 判据读数：-1 = 用例无效（起音失败）、-2 = 相位对齐失败
    integer r_vi;        // 实际被 gate 的 voice 索引（打印用）

    task run_case;
        input integer off_phase;
        integer vi;
        integer guard;
        begin
            rst_n      = 1'b0;
            note_valid = 1'b0;
            note_axis  = {AXIS_W{1'b0}};
            note_kind  = 2'd0;
            tick_cnt   = 11'd0;          // ⭐ 与探针一致：每个用例都把相位复位
            clkn(30);
            rst_n = 1'b1;
            clkn(30);

            pulse(AXIS_A, 2'd0);         // ① 按轴 A
            clkn(80);
            vi    = gated_bit();
            r_vi  = vi;

            if (vi < 0) begin
                r_gate = -1;             // 起音失败 ⇒ 本用例无效
            end else begin
                pulse(AXIS_A, 2'd0);     // ② 立刻再按轴 A（同轴重触发 ⇒ 进压低窗口）
                clkn(3);

                // ③ ⭐ 对齐相位：等到 `tick_cnt == off_phase` 才发 `note_off`
                //    ⚠️ 带兜底计数（⛔ 不允许死循环 —— `K-94`：挂死不是通过）
                guard = 0;
                while ((tick_cnt != off_phase) && (guard < 4096)) begin
                    @(negedge clk);
                    guard = guard + 1;
                end

                if (guard >= 4096) begin
                    r_gate = -2;         // 相位对齐失败（⛔ 不该发生）
                end else begin
                    pulse(AXIS_A, 2'd1); //    发 note_off
                    tick_n(2);           // ④ 静默 2 帧
                    r_gate = voice_gate[vi];
                end
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // 主流程
    // ═════════════════════════════════════════════════════════════════════════
    integer phases [0:63];
    integer np;
    integer pi;

    initial begin
        note_valid     = 1'b0;
        note_axis      = {AXIS_W{1'b0}};
        note_kind      = 2'd0;
        note_phase_inc = 32'h0010_0000;   // ⭐ 与探针的 `note_inc` 一致
        note_velocity  = {VEL_W{1'b0}};   // ⭐ 0 ⇒ 模块内套用 `DEFAULT_VEL(200)`

        // ⭐⭐ 相位表（⭐ 与探针逐点一致）：
        //    · 粗扫 0..960（步长 64）
        //    · ⭐ 精扫 `sample_tick` 前 8 拍（1016..1023）—— 🔴 缺陷就藏在这里
        //    · ⭐ 精扫 `sample_tick` 之后 8 拍（0..7）
        np = 0;
        for (pi = 0; pi < 1024; pi = pi + 64) begin
            phases[np] = pi;  np = np + 1;
        end
        for (pi = 1016; pi < 1024; pi = pi + 1) begin
            phases[np] = pi;  np = np + 1;
        end
        for (pi = 0; pi < 8; pi = pi + 1) begin
            phases[np] = pi;  np = np + 1;
        end

        @(negedge clk);

        $display("");
        $display("==============================================================");
        $display(" B3 RETRIGGER window: can note_off still clear the gate?");
        $display("   (phase sweep around sample_tick; gate MUST be 0 after note_off)");
        $display("==============================================================");

        for (pi = 0; pi < np; pi = pi + 1) begin
            run_case(phases[pi]);

            if (r_gate < 0) begin
                n_invalid = n_invalid + 1;
                errors    = errors + 1;
                if (r_gate == -1)
                    $display("  FAIL: B3 off_phase=%4d: the initial note_on produced no gate at all (setup broken => case invalid)",
                             phases[pi]);
                else
                    $display("  FAIL: B3 off_phase=%4d: phase alignment never reached the requested tick phase (case invalid)",
                             phases[pi]);
            end else if (r_gate == 0) begin
                n_cleared = n_cleared + 1;
                $display("  off_phase=%4d -> gate=%0d ok", phases[pi], r_gate);
            end else begin
                n_stuck = n_stuck + 1;
                errors  = errors + 1;
                $display("  off_phase=%4d -> gate=%0d  <-- STUCK! note_off could not clear it",
                         phases[pi], r_gate);
                $display("  FAIL: B3 off_phase=%4d: voice %0d gate stayed 1 after note_off inside the retrigger hold window (permanent stuck note)",
                         phases[pi], r_vi);
            end
        end

        $display("");
        $display("  == summary ==");
        $display("   cleared=%0d  STUCK=%0d  (invalid=%0d, phases=%0d)",
                 n_cleared, n_stuck, n_invalid, np);

        // ⭐ 判据的汇总口径（⛔ 与逐条 FAIL 互补，防止"只数不判"）
        chk("B3: every phase around the sample tick clears the gate (no stuck note)",
            n_stuck == 0);
        // ⭐ 非空洞性：所有相位都必须真的跑起来了（⛔ 无效用例不算通过 —— `C29`）
        chk("B3 non-vacuity: all phase cases executed with a valid setup",
            n_invalid == 0);

        if (errors == 0)
            $display("PASS: B3 note_off always clears the gate, even inside the retrigger hold window");
        else
            $fatal(1, "FAIL: B3 note_off-in-hold has %0d error(s)", errors);

        $finish;
    end

    // ⭐ 看门狗（`K-94` 同族）：⭐ "没有结论"必须算失败，⛔ 不能算通过
    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_nm_off_in_hold timeout");
    end

endmodule
