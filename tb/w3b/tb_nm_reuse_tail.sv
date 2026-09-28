// ─────────────────────────────────────────────────────────────────────────────
// tb_nm_reuse_tail.sv · B2 回归判据：release 尾巴期再按同一个键，必须【复用同一 voice】
//
// ⭐ 来源：`build/exp/vprobe/vprobe_b2.cpp`（Verilator 定向探针，⚠️ **未入库**）
//    ⭐ 探针只能"一次性证明"，⛔ 不能防回归 ⇒ 本 tb 把它的判据**照搬**成仓库 tb，
//      让 `sim/tb_all.ps1` 每轮都能守住这条线。
//
// 🔴 守的缺陷（`note_manager.v` 的 `same_hit` 用错了 mask，2026-09-28 已修）：
//      `same_hit = gate_mask & (axis_r == cur_axis)`，而 `gate_mask = gate_r & ~retrig_low`
//      ⇒ ⭐ **松手后 `gate_r=0`、但 Release 尾巴还在响（`env_active_i=1`）时 `gate_mask=0`**
//      ⇒ `same_valid=0` ⇒ 走 `ST_SCAN` **另分配一个 voice**（同轴、同音高）
//      ⇒ 🔴 旧尾巴 + 新起音峰叠加 ⇒ 幅度冲到正常音的 ~11 倍（DS0004 实测 10.6~11.1 倍）
//   ✅ 修法：`same_hit` 改用 `live_mask`（= `gate_r | retrig_low | env_active_i`）。
//
// ⭐ 判据（机械可判定，⛔ 不是"看起来对" —— `K-56` / `C21`）：
//      note_on(A) → note_off(A) → 等 k 帧（尾巴未结束）→ note_on(A)
//      ⭐ 数"axis==A 且 live_mask==1"的 voice 个数：
//         1 => ✅ PASS（复用了同一 voice）
//         2 => 🔴 FAIL（分配了第二个同轴 voice）
//   📌 修复前实测：`wait 2 frames -> 2`（DUPLICATE）；修复后：`reuse=6 DUPLICATE=0`。
//
// ⚠️ 时基必须与探针**逐拍一致**：`CLK_PER_SAMPLE=1024`，`sample_tick` 只高 **1 拍**
//    （`K-93`：tb 的时基与被测系统的节拍语义不一致 ⇒ 判据假失败）。
//
// ⚠️⚠️ 为什么"尾巴还在"这件事**必须单独断言**（见下方 `B2 non-vacuity` 那条）：
//    ⭐ 尾巴一旦已经结束，`live_mask=0` ⇒ 该 voice **本来就该被当空闲**
//       ⇒ 此时"重按后落在 voice0"是**新分配**而不是**复用**，判据就变成**空洞**的了。
//    ⚠️ 实测（本 tb 的打印可复核）：`k>=3` 帧时 ADSR 已回 `ST_IDLE`、`env_active=0`
//       ⇒ ⭐ **只有 `k=2` 才是真·尾巴期用例**；但 ⛔ 不能因此只留 k=2
//         （那样就丢掉了"缺陷只在一个窗口内可达"这个事实）。
//    ⇒ ⭐ 做法：**6 个等待长度全部照探针跑**（每个都必须 =1），
//      **外加**显式断言 `k=2` 时轴上确有 `env_active=1` 的 voice ⇒ **非空洞性证明**。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_nm_reuse_tail;

    localparam integer POLY           = 32;
    localparam integer AXIS_W         = 4;
    localparam integer PHASE_W        = 32;
    localparam integer VEL_W          = 8;
    localparam integer TIMBRE_W       = 2;
    localparam integer ENV_W          = 16;
    localparam integer AGE_W          = 16;
    localparam integer IDX_W          = 5;        // $clog2(32)
    // ⭐ 与 Verilator 探针 `vprobe_b2.cpp` 的 `tick_cnt` 周期**完全一致**（⛔ 别改成 64）
    localparam integer CLK_PER_SAMPLE = 1024;
    localparam [AXIS_W-1:0] AXIS_A    = 4'd3;     // ⭐ 探针用的轴位

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors  = 0;
    integer n_reuse = 0;
    integer n_dup   = 0;

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
    // 时基 · `sample_tick` 生成
    //   ⭐ 探针写法：`sample_tick = (tick_cnt==1023) ? 1 : 0;  tick_cnt = ...`
    //   ⇒ 本处用【组合 `sample_tick` + 寄存器 `tick_cnt`】表达同一语义：
    //     `tick_cnt==1023` 的那一拍 `sample_tick` 为 1，随后 `tick_cnt` 归 0。
    //   ⚠️ `sample_tick_i` 是**时钟使能**，⛔ 不是电平（`K-93`：只高 1 拍）
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
    //      （⭐ 尤其包络**用默认参数**：`DECAY_STEP=4`/`RELEASE_STEP=2`
    //        ⇒ release 从 sustain(12800) 归零要 6400 帧 ⇒ "k=2 帧尾巴还在"这个窗口）
    // ═════════════════════════════════════════════════════════════════════════
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;

    wire [POLY-1:0]          voice_gate;
    wire [POLY-1:0]          voice_active;      // ⭐ = live_mask（本判据数的就是它）
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

    // ⭐ 真包络（⛔ 不能用桩：本判据 100% 依赖 `env_active`，而它只由 `adsr` 产生）
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ── 切片 / 计数辅助（⭐ 与探针的 `axis_of` / `live_axis_count` 等价）────────
    function [AXIS_W-1:0] axis_of;
        input integer v;
        begin axis_of = voice_axis[v*AXIS_W +: AXIS_W]; end
    endfunction

    function integer live_axis_count;
        input [AXIS_W-1:0] ax;
        integer i2;
        integer c;
        begin
            c = 0;
            for (i2 = 0; i2 < POLY; i2 = i2 + 1)
                if (voice_active[i2] && (axis_of(i2) == ax)) c = c + 1;
            live_axis_count = c;
        end
    endfunction

    function integer gate_axis_count;
        input [AXIS_W-1:0] ax;
        integer i2;
        integer c;
        begin
            c = 0;
            for (i2 = 0; i2 < POLY; i2 = i2 + 1)
                if (voice_gate[i2] && (axis_of(i2) == ax)) c = c + 1;
            gate_axis_count = c;
        end
    endfunction

    function integer env_axis_count;
        input [AXIS_W-1:0] ax;
        integer i2;
        integer c;
        begin
            c = 0;
            for (i2 = 0; i2 < POLY; i2 = i2 + 1)
                if (env_active[i2] && (axis_of(i2) == ax)) c = c + 1;
            env_axis_count = c;
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

    // ── 单个用例的观测量（⭐ 由 `run_case` 填，由 initial 块判）────────────────
    integer r_gate_before;    // ① 按下后：轴上 gate 数（≠1 ⇒ 用例无效）
    integer r_env_before;     // ③ 重按前：轴上 `env_active=1` 的 voice 数（≥1 ⇒ 尾巴还在）
    integer r_live_before;    // ③ 重按前：轴上 `live_mask=1` 的 voice 数
    integer r_live_after;     // ⑤ 重按后：轴上 `live_mask=1` 的 voice 数（⭐ 判据）

    task run_case;
        input integer k_frames;
        begin
            rst_n      = 1'b0;
            note_valid = 1'b0;
            note_axis  = {AXIS_W{1'b0}};
            note_kind  = 2'd0;
            tick_cnt   = 11'd0;          // ⭐ 与探针一致：每个用例都把相位复位
            clkn(30);
            rst_n = 1'b1;
            clkn(30);

            pulse(AXIS_A, 2'd0);         // ① 按下
            clkn(80);
            r_gate_before = gate_axis_count(AXIS_A);

            pulse(AXIS_A, 2'd1);         // ② 松开（gate 清 0，但包络进入 release 尾巴）
            clkn(80);

            tick_n(k_frames);            // ③ 等 k 帧（尾巴仍在）
            r_env_before  = env_axis_count(AXIS_A);
            r_live_before = live_axis_count(AXIS_A);

            pulse(AXIS_A, 2'd0);         // ④ 再按同一个键
            clkn(80);

            r_live_after = live_axis_count(AXIS_A);   // ⑤ 数同轴 live 的 voice
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // 主流程
    // ═════════════════════════════════════════════════════════════════════════
    integer ci;
    integer frames [0:5];
    integer env_at_k2;

    initial begin
        note_valid     = 1'b0;
        note_axis      = {AXIS_W{1'b0}};
        note_kind      = 2'd0;
        note_phase_inc = 32'h0010_0000;   // ⭐ 与探针的 `note_inc` 一致
        note_velocity  = {VEL_W{1'b0}};   // ⭐ 0 ⇒ 模块内套用 `DEFAULT_VEL(200)`

        // ⭐ 探针的 6 个等待长度（尾巴长度：sustain 131 ms ≈ 6.4 帧）
        frames[0] = 2;  frames[1] = 5;  frames[2] = 10;
        frames[3] = 20; frames[4] = 40; frames[5] = 60;

        @(negedge clk);

        $display("");
        $display("==============================================================");
        $display(" B2: re-pressing during the RELEASE TAIL -- voice reuse?");
        $display("   (expect 1 live voice on the axis; 2 => duplicate => BUG)");
        $display("==============================================================");

        env_at_k2 = -1;
        for (ci = 0; ci < 6; ci = ci + 1) begin
            run_case(frames[ci]);

            $display("  case %0d: wait %3d frames -> env_before=%0d live_before=%0d live_after=%0d %0s",
                     ci, frames[ci], r_env_before, r_live_before, r_live_after,
                     (r_live_after == 1) ? "ok" : "  <-- DUPLICATE! (B2)");

            if (frames[ci] == 2) env_at_k2 = r_env_before;

            // ⭐ 前置条件：起音必须真的成功（⛔ 否则本用例什么都没测）
            if (r_gate_before != 1) begin
                errors = errors + 1;
                $display("  FAIL: B2 wait=%0d frames: the initial note_on left %0d gate(s) on axis %0d (expected 1 => setup broken)",
                         frames[ci], r_gate_before, AXIS_A);
            end

            // ⭐⭐ 判据本体
            if (r_live_after == 1) begin
                n_reuse = n_reuse + 1;
            end else begin
                n_dup = n_dup + 1;
                errors = errors + 1;
                $display("  FAIL: B2 wait=%0d frames: %0d live voices on axis %0d after the re-press (expected 1 => the SAME voice must be reused; 2 => a 2nd same-axis voice was allocated)",
                         frames[ci], r_live_after, AXIS_A);
            end
        end

        $display("");
        $display("  == summary ==");
        $display("   reuse=%0d  DUPLICATE=%0d", n_reuse, n_dup);

        // ⭐⭐ 非空洞性证明：`k=2` 必须真的处在"release 尾巴未结束"的状态。
        //     ⛔ 少了这一条，本 tb 在"尾巴被改短/包络不再 active"时会**静默变成空测试**。
        chk("B2 non-vacuity: at wait=2 frames the tail is still alive (env_active=1 on the axis)",
            env_at_k2 >= 1);
        // ⭐ 判据的汇总口径（⛔ 与逐条 FAIL 互补，防止"只数不判"）
        chk("B2: release-tail re-press never allocates a 2nd same-axis voice",
            n_dup == 0);

        if (errors == 0)
            $display("PASS: B2 release-tail re-press reuses the SAME voice (no duplicate same-axis voice)");
        else
            $fatal(1, "FAIL: B2 release-tail re-press has %0d error(s)", errors);

        $finish;
    end

    // ⭐ 看门狗（`K-94` 同族）：⭐ "没有结论"必须算失败，⛔ 不能算通过
    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_nm_reuse_tail timeout");
    end

endmodule
