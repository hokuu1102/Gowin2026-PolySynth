// ─────────────────────────────────────────────────────────────────────────────
// tb_retrig_reset_span.sv · P0-4 判据（⛔ 不改 RTL）
//
// ⭐ 守的是什么（commit `7eacaeb` 修的缺陷）：
//   `note_manager.v` 里 `retrig_reset_r` 的语义是
//   *"置 1 后【保持到下一个 `sample_tick`】，让 ADSR 必然看见"*。
//   🔴 原写法（同块内**后写覆盖先写**）：
//        :463  if (sample_tick_i) retrig_reset_r <= 0;   // 清零写在前
//        :559  retrig_reset_r[i] <= 1'b1;                // (f) 段无条件置 1，写在后
//      ⇒ tick 那一拍又被置起 ⇒ 该位保持到【下一个】tick 才清
//      ⇒ ⭐ 跨【两个】`sample_tick` ⇒ ADSR 连清两帧
//      ⇒ ⭐ 重触发起音多延迟一整帧（20.48 µs）。
//   ✅ 修法：(f) 段改成 `if (!sample_tick_i) retrig_reset_r[i] <= 1'b1;`
//      ⇒ 高电平恰好跨【一个】tick 沿。
//
// ⭐ 判据（⭐ 能失败 —— `K-56` / `C21`）：
//   激励：`note_on(A)` → 等一会儿 → 再 `note_on(A)`（进重触发）
//   探针：⭐ **每个 `sample_tick` 沿采样一次** `retrig_reset_r[该 voice]`，
//         统计读到 1 的次数 = `rst_ticks`
//   ⇒ ⭐ **必须 == 1**（⛔ 不是 "<=1"，也不是 ">=1"）
//
// ⚠️ 为什么"每 tick 采一次"就等于"跨了几个 tick 沿"：
//   `retrig_reset_r` 是 DUT 里的寄存器，探针在**同一个 `posedge clk`** 读它
//   ⇒ 读到的是**沿前的值**（NBA 语义）—— ⭐ 正是 **ADSR 在同一拍看到的值**。
//   ⇒ `rst_ticks == 1` ⇔ ADSR 只在**一个** tick 上看见这个清零请求（幂等，正好一次）。
//
// ⭐ 非空洞性（⭐ 必看）：把 `rtl/w3b/note_manager.v` 复制到 `%TEMP%`，
//   只把 :563 改回修复前的**无条件置 1**（与 `git show 7eacaeb^:rtl/w3b/note_manager.v`
//   对应行逐字相同），用那份 RTL 编译本 tb
//   ⇒ ⭐ 实测 **FAIL**（`rst_ticks = 2`）。
//
// ⚠️ 三个场景都测（⭐ 覆盖重触发的两条入口）：
//   ① 在响时重触发（`gate_r=1`）  ② 紧接着再重触发一次
//   ③ ⭐ **尾巴期内重按**（`gate_r=0` 但 `env_active_i=1` ⇒ 走 `live_mask` 入口）
//
// ⚠️ 判据名一律【纯 ASCII】（⭐ 实测教训）：
//   `chk` 的名字是经 `task` 的**宽向量参数**传给 `$display("%0s", …)` 的，
//   而 ⭐ **iverilog 的 `%s` 会把 ≥0x80 的字节逐个换成 `U+FFFD`**
//   ⇒ 日志里所有中文判据名都变成 `����`（⭐ 现有 `sim/evidence/*.log` 全都如此）。
//   ⇒ 本 tb：**节标题**（直接 `$display` 字面量，⛔ 不走 task 参数）保留中文，
//     **判据名**用 ASCII ⇒ ⭐ 日志可读、`FAIL:`/`PASS:` 干净。
//
// ⚠️ 语法纪律（`K-91`）：Verilog-2001 风格（`-g2012` 编译，⛔ 不用 SV 专有构造）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_retrig_reset_span;

    localparam integer POLY       = 32;
    localparam integer AXIS_W     = 4;
    localparam integer PHASE_W    = 32;
    localparam integer VEL_W      = 8;
    localparam integer TIMBRE_W   = 2;
    localparam integer ENV_W      = 16;
    localparam integer AGE_W      = 16;
    localparam integer IDX_W      = 5;      // $clog2(32)
    localparam integer EVT_LOST_W = 8;

    // ⚠️ `note_manager` 一次分配要扫 `POLY_TARGET+4 = 36` 拍
    //    ⇒ ⭐ 一个 `sample_tick` 必须长于它（否则扫描会被下一个 tick 打断 —— `K-93`）
    localparam integer CLK_PER_SAMPLE = 64;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;

    task chk;
        input [8*128-1:0] name;
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
    // DUT · `note_manager`（⭐ 与 `tb_note_manager.sv` 同一套参数/接法）
    // ═════════════════════════════════════════════════════════════════════════
    reg                    sample_tick;
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;

    wire [POLY-1:0]          voice_gate;
    wire [POLY-1:0]          voice_active;
    wire [POLY-1:0]          voice_releasing;
    wire [POLY*AXIS_W-1:0]   voice_axis;
    wire [POLY*PHASE_W-1:0]  voice_phase_inc;
    wire [POLY*VEL_W-1:0]    voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY*AGE_W-1:0]    voice_age;
    wire [POLY-1:0]          voice_retrig_reset;   // ⭐ 本 tb 的被测对象
    wire                     alloc_valid;
    wire [IDX_W-1:0]         alloc_voice;
    wire                     event_lost;
    wire [EVT_LOST_W-1:0]    event_lost_cnt;

    wire [POLY-1:0]          env_active;
    wire [POLY*ENV_W-1:0]    env_level;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        .FIFO_DEPTH(32), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}),
        .default_timbre_i({TIMBRE_W{1'b0}}), .evt_timbre_valid_i(1'b0),
        .evt_timbre_i({TIMBRE_W{1'b0}}),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_age_o(voice_age),
        .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        .event_lost_o(event_lost), .event_lost_cnt_o(event_lost_cnt),
        .event_lost_clr_i(1'b0)
    );

    // ⭐ 真包络（⭐ 场景③"尾巴期内重按"要靠 `env_active_i` 才有意义）
    //    ⚠️ `RELEASE_STEP` 取小值 ⇒ 尾巴足够长，⛔ 不会在 2 拍内就衰到 0
    //       （否则场景③会退化成"全新分配"，判据失去被测对象）
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(1000), .DECAY_STEP(100), .SUSTAIN_Q8(64), .RELEASE_STEP(100)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ 探针：每个 `sample_tick` 沿采一次 `retrig_reset_r[watch_idx]`
    //   ⭐ 同一个 `posedge clk` 读 ⇒ 读到沿前的值 = **ADSR 在同一拍看到的值**
    // ═════════════════════════════════════════════════════════════════════════
    reg     watch_en  = 1'b0;
    integer watch_idx = 0;
    integer rst_ticks = 0;

    always @(posedge clk) begin
        if (watch_en && sample_tick)
            if (voice_retrig_reset[watch_idx]) rst_ticks = rst_ticks + 1;
    end

    // ── 辅助 ────────────────────────────────────────────────────────────────
    function integer voice_of_axis;
        input [AXIS_W-1:0] ax;
        integer v;
        integer found;
        begin
            found = -1;
            for (v = 0; v < POLY; v = v + 1)
                if (voice_axis[v*AXIS_W +: AXIS_W] == ax) found = v;
            voice_of_axis = found;
        end
    endfunction

    // ⭐ `sample_tick_i` 必须**恰好高 1 拍**（它是时钟使能，⛔ 不是电平 —— `K-93`）
    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); sample_tick = 1'b1;
                @(negedge clk); sample_tick = 1'b0;
                repeat (CLK_PER_SAMPLE - 2) @(negedge clk);
            end
        end
    endtask

    // ⚠️ 本 tb 的 tick **只在 `run_ticks` 里产生** ⇒ 激励与 tick 的相对位置完全可控
    task settle;
        integer t;
        begin
            for (t = 0; t < POLY + 8; t = t + 1) @(negedge clk);
        end
    endtask

    task note_on;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            note_valid     = 1'b1;
            note_axis      = ax;
            note_phase_inc = 32'h0010_0000;
            note_velocity  = 8'd200;
            note_kind      = 2'd0;             // note_on
            @(negedge clk);
            note_valid     = 1'b0;
        end
    endtask

    task note_off;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            note_valid     = 1'b1;
            note_axis      = ax;
            note_phase_inc = 32'h0010_0000;
            note_velocity  = 8'd200;
            note_kind      = 2'd1;             // note_off
            @(negedge clk);
            note_valid     = 1'b0;
        end
    endtask

    integer vA;
    integer rst_a;
    integer rst_b;
    integer rst_c;

    initial begin
        $dumpfile("build/sim/tb_retrig_reset_span/tb_retrig_reset_span.vcd");
        $dumpvars(0, tb_retrig_reset_span);

        sample_tick    = 1'b0;
        note_valid     = 1'b0;
        note_axis      = {AXIS_W{1'b0}};
        note_phase_inc = 32'h0010_0000;
        note_velocity  = {VEL_W{1'b0}};
        note_kind      = 2'd0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 1: 建立基线 —— note_on(轴 3) ==");
        // ═══════════════════════════════════════════════════════════════════
        note_on(4'd3);
        settle;
        run_ticks(5);
        vA = voice_of_axis(4'd3);
        $display("  info: axis 3 -> voice %0d", vA);
        chk("axis 3 got a voice", vA >= 0);
        chk("that voice gate is high (sounding)", voice_gate[vA] === 1'b1);
        chk("after reset retrig_reset is low", voice_retrig_reset[vA] === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 2: ⭐⭐ 在响时重触发（同轴 3 再 note_on）==");
        // ═══════════════════════════════════════════════════════════════════
        watch_idx = vA; rst_ticks = 0; watch_en = 1'b1;
        note_on(4'd3);                 // ⭐ 进重触发（复用同一 voice）
        settle;
        run_ticks(4);
        watch_en = 1'b0;
        rst_a = rst_ticks;
        $display("  info: rst_ticks = %0d", rst_a);
        chk("after retrigger the gate is back high (voice sounding)",
            voice_gate[vA] === 1'b1);
        chk("after retrigger retrig_reset returned low (not stuck)",
            voice_retrig_reset[vA] === 1'b0);
        if (rst_a !== 1)
            $display("  FAIL: retrigger-while-sounding: retrig_reset_r spans %0d sample_tick(s), must be 1",
                     rst_a);
        chk("P0-4: retrigger while sounding => retrig_reset_r spans exactly ONE sample_tick",
            rst_a == 1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 3: ⭐⭐ 紧接着再重触发一次（连续第二次）==");
        // ═══════════════════════════════════════════════════════════════════
        watch_idx = vA; rst_ticks = 0; watch_en = 1'b1;
        note_on(4'd3);
        settle;
        run_ticks(4);
        watch_en = 1'b0;
        rst_b = rst_ticks;
        $display("  info: rst_ticks = %0d", rst_b);
        if (rst_b !== 1)
            $display("  FAIL: second consecutive retrigger: retrig_reset_r spans %0d sample_tick(s), must be 1",
                     rst_b);
        chk("P0-4: second consecutive retrigger => spans exactly ONE sample_tick",
            rst_b == 1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 4: ⭐⭐ 尾巴期内重按（note_off 后 env 还没死就再按）==");
        //   ⭐ 这条走的是 `same_hit` 的 **`env_active_i` 入口**（`gate_r` 已是 0）
        //      ⇒ ⭐ 与场景 2/3 的入口**不同**，必须单独覆盖。
        // ═══════════════════════════════════════════════════════════════════
        note_off(4'd3);
        settle;
        run_ticks(2);                  // ⭐ 只走 2 拍 ⇒ Release 尾巴还在
        chk("gate fell after note_off", voice_gate[vA] === 1'b0);
        chk("release tail is still live (live_mask=1)", voice_active[vA] === 1'b1);

        watch_idx = vA; rst_ticks = 0; watch_en = 1'b1;
        note_on(4'd3);                 // ⭐ 尾巴期内重按 ⇒ 必须复用同一 voice
        settle;
        run_ticks(4);
        watch_en = 1'b0;
        rst_c = rst_ticks;
        $display("  info: rst_ticks = %0d", rst_c);
        chk("gate is back high after re-press inside the tail",
            voice_gate[vA] === 1'b1);
        if (rst_c !== 1)
            $display("  FAIL: re-press inside release tail: retrig_reset_r spans %0d sample_tick(s), must be 1",
                     rst_c);
        chk("P0-4: re-press inside release tail => spans exactly ONE sample_tick",
            rst_c == 1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 汇总 ==");
        // ⭐ 防空跑：三次都必须**真的**观测到一次清零请求（⛔ 否则判据是空的 —— `C36`）
        chk("all three retriggers really produced a reset pulse (1/1/1, not vacuous)",
            (rst_a == 1) && (rst_b == 1) && (rst_c == 1));

        if (errors == 0)
            $display("PASS: retrig_reset single-tick span (P0-4) - all judgements held (rst_ticks = %0d/%0d/%0d)",
                     rst_a, rst_b, rst_c);
        else begin
            $display("FAIL: retrig_reset single-tick span (P0-4): %0d error(s), rst_ticks = %0d/%0d/%0d (must be 1/1/1)",
                     errors, rst_a, rst_b, rst_c);
            $fatal(1, "FAIL: retrig_reset single-tick span (P0-4) has %0d error(s)", errors);
        end
        #200;
        $finish;
    end

endmodule
