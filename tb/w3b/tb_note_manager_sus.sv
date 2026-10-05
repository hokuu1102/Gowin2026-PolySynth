// ═══════════════════════════════════════════════════════════════════════════
// tb_note_manager_sus.sv — T5 延音踏板语义（模块级判据）
//
//   目标（第三周计划 T5）：踩住延音踏板时，`note_off` **只关 gate、不启动包络释放**
//   ⇒ 音保持在 sustain；松开踏板 ⇒ 所有被留住的音同时释放。
//
//   判据（6 条，每条都写了"能红的方式"）：
//     S1 不踩踏板：press → release ⇒ gate 落 0（回归判据：与现在逐位相同）
//     S2 踩住踏板：press → release ⇒ gate **仍为 1**，且 env_active **仍为 1**（音不消失）
//     S3 松踏板     ⇒ 被留住的 voice gate 落 0、env_active 落 0
//     S4 踩住踏板 + 同轴再按 ⇒ **正常重触发**（该轴只有 1 个 voice，不叠音）
//     S5 踩住踏板时，**非手弹源**（src != 0）的 release 照常释放（不被留）
//     S6 松键之后才踩踏板 ⇒ **不复活**（gate 保持 0）
//
//   ⚠️ 本 tb 用真 `envelope_bank` 观察"音有没有消失"（⛔ 不是只看 gate 线）——
//      这是 C83（探针假绿）的反面用法：判据盯真正失效的那个寄存器。
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_note_manager_sus;

    localparam integer POLY     = 8;
    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer TIMBRE_W = 2;
    localparam integer ENV_W    = 16;
    localparam integer TICK_CYC = 64;      // ⭐ tb 用短 tick（生产是 1024）⇒ 跑得快，语义不变
    localparam integer IDX_W    = 3;       // clog2(POLY=8)

    // ── 时钟 / 复位 ────────────────────────────────────────────────────────
    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst_n = 1'b0;

    // ── DUT 输入 ──────────────────────────────────────────────────────────
    reg                  sample_tick;
    reg                  note_valid;
    reg  [AXIS_W-1:0]    note_axis;
    reg  [PHASE_W-1:0]   note_phase_inc;
    reg  [VEL_W-1:0]     note_velocity;
    reg  [1:0]           note_kind;
    reg  [2:0]           note_src;
    reg                  vel_upd_valid;
    reg  [AXIS_W-1:0]    vel_upd_axis;
    reg  [VEL_W-1:0]     vel_upd_value;
    reg  [2:0]           vel_upd_src;
    reg                  pitch_upd_valid;
    reg  [AXIS_W-1:0]    pitch_upd_axis;
    reg  [PHASE_W-1:0]   pitch_upd_value;
    reg  [2:0]           pitch_upd_src;
    reg  [TIMBRE_W-1:0]  default_timbre;
    reg                  evt_timbre_valid;
    reg  [TIMBRE_W-1:0]  evt_timbre;
    reg  [6:0]           base_semi;
    reg                  base_commit;
    reg  signed [4:0]    transpose_semi;
    reg                  event_lost_clr;
    reg                  sus_pedal;        // ⭐ 新端口：1 = 踩住延音踏板

    // ── DUT 输出 ──────────────────────────────────────────────────────────
    wire [POLY-1:0]          voice_gate;
    wire [POLY-1:0]          voice_active;
    wire [POLY-1:0]          voice_releasing;
    wire [POLY*AXIS_W-1:0]   voice_axis;
    wire [POLY*PHASE_W-1:0]  voice_phase_inc;
    wire [POLY*VEL_W-1:0]    voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY-1:0]          voice_drum;
    wire [POLY*16-1:0]       voice_age;
    wire [POLY-1:0]          voice_retrig_reset;
    wire                     alloc_valid;
    wire [IDX_W-1:0]         alloc_voice;
    wire                     event_lost;
    wire [7:0]               event_lost_cnt;

    // ── 真包络（判"音有没有消失"）────────────────────────────────────────
    wire [POLY-1:0]          env_active;
    wire [POLY*ENV_W-1:0]    env_level;

    note_manager #(
        .POLY_TARGET  (POLY),
        .AXIS_W       (AXIS_W),
        .PHASE_W      (PHASE_W),
        .T3_EN        (0),                 // ⛔ 本 tb 不验变调 ⇒ 关掉（省展开）
        .VEL_W        (VEL_W),
        .TIMBRE_W     (TIMBRE_W),
        .ENV_W        (ENV_W),
        .AGE_W        (16),
        .RESERVED_N   (0),
        .DEFAULT_VEL  (200),
        .FIFO_DEPTH   (8),
        .EVT_LOST_CNT_W (8)
    ) dut (
        .clk_i              (clk),
        .rst_n_i            (rst_n),
        .sample_tick_i      (sample_tick),
        .note_valid_i       (note_valid),
        .note_axis_i        (note_axis),
        .note_phase_inc_i   (note_phase_inc),
        .note_velocity_i    (note_velocity),
        .note_kind_i        (note_kind),
        .note_src_i         (note_src),
        .vel_upd_valid_i    (vel_upd_valid),
        .vel_upd_axis_i     (vel_upd_axis),
        .vel_upd_value_i    (vel_upd_value),
        .vel_upd_src_i      (vel_upd_src),
        .pitch_upd_valid_i  (pitch_upd_valid),
        .pitch_upd_axis_i   (pitch_upd_axis),
        .pitch_upd_value_i  (pitch_upd_value),
        .pitch_upd_src_i    (pitch_upd_src),
        .default_timbre_i   (default_timbre),
        .evt_timbre_valid_i (evt_timbre_valid),
        .evt_timbre_i       (evt_timbre),
        .env_active_i       (env_active),
        .env_level_i        (env_level),
        .base_semi_i        (base_semi),
        .base_commit_i      (base_commit),
        .transpose_semi_i   (transpose_semi),
        .sus_pedal_i        (sus_pedal),      // ⭐ T5 新增
        .event_lost_clr_i   (event_lost_clr),
        .voice_gate_o       (voice_gate),
        .voice_active_o     (voice_active),
        .voice_releasing_o  (voice_releasing),
        .voice_axis_o       (voice_axis),
        .voice_phase_inc_o  (voice_phase_inc),
        .voice_velocity_o   (voice_velocity),
        .voice_timbre_o     (voice_timbre),
        .voice_drum_o       (voice_drum),
        .voice_age_o        (voice_age),
        .voice_retrig_reset_o (voice_retrig_reset),
        .alloc_valid_o      (alloc_valid),
        .alloc_voice_o      (alloc_voice),
        .event_lost_o       (event_lost),
        .event_lost_cnt_o   (event_lost_cnt)
    );

    //   ⭐ 参数选得让判据"尖锐"：attack ≈ 39 拍、decay 6 拍、release 2 拍
    //      （⭐ 与 `tb_note_manager.sv` 同一套 —— 否则 200 拍后包络还在 decay 里，
    //       "重触发/释放"的观测会被淹没）
    envelope_bank #(
        .POLY_TARGET  (POLY),
        .VEL_W        (VEL_W),
        .ENV_W        (ENV_W),
        .ATTACK_STEP  (669),
        .DECAY_STEP   (3200),
        .SUSTAIN_Q8   (64),
        .RELEASE_STEP (3200)
    ) u_env (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (voice_gate),
        .velocity_i    (voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .timbre_i      (voice_timbre),
        .env_level_o   (env_level),
        .env_active_o  (env_active)
    );

    // ── 判据计数器 ────────────────────────────────────────────────────────
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk;
        input        cond;
        input [1023:0] name;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  ok  : %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    // ── 激励原语 ──────────────────────────────────────────────────────────
    task tick_once;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    task wait_ticks;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) tick_once();
        end
    endtask

    task send_note;
        input [1:0]        kind;
        input [AXIS_W-1:0] ax;
        input [2:0]        src;
        input [VEL_W-1:0]  vel;
        begin
            @(negedge clk);
            note_valid    = 1'b1;
            note_kind     = kind;
            note_axis     = ax;
            note_src      = src;
            note_velocity = vel;
            note_phase_inc = 32'h0010_0000;
            @(negedge clk);
            note_valid    = 1'b0;
        end
    endtask

    task press;
        input [AXIS_W-1:0] ax;
        input [2:0]        src;
        begin send_note(2'd0, ax, src, 8'd200); end
    endtask

    task rel_note;                        // ⚠️ 不能叫 release —— 那是 Verilog 关键字
        input [AXIS_W-1:0] ax;
        input [2:0]        src;
        begin send_note(2'd1, ax, src, 8'd0); end
    endtask

    // ── 观测辅助 ──────────────────────────────────────────────────────────
    function integer find_voice;
        input [AXIS_W-1:0] ax;
        integer i;
        begin
            find_voice = -1;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax) find_voice = i;
        end
    endfunction

    function integer count_axis;
        input [AXIS_W-1:0] ax;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax) c = c + 1;
            count_axis = c;
        end
    endfunction

    function integer count_axis_gate;
        input [AXIS_W-1:0] ax;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax && voice_gate[i]) c = c + 1;
            count_axis_gate = c;
        end
    endfunction

    function integer count_axis_envact;
        input [AXIS_W-1:0] ax;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax && env_active[i]) c = c + 1;
            count_axis_envact = c;
        end
    endfunction

    task dump_axis;
        input [AXIS_W-1:0] ax;
        integer i;
        begin
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax)
                    $display("      [dbg] axis=%0d voice=%0d gate=%b envact=%b level=%0d",
                             ax, i, voice_gate[i], env_active[i],
                             env_level[i*ENV_W +: ENV_W]);
        end
    endtask

    integer lv_cap;
    integer lv_a, lv_b, lv_c;
    task cap_level;
        input [AXIS_W-1:0] ax;
        integer i;
        begin
            lv_cap = -1;
            for (i = 0; i < POLY; i = i + 1)
                if (voice_axis[i*AXIS_W +: AXIS_W] === ax)
                    lv_cap = env_level[i*ENV_W +: ENV_W];
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    integer v;
    initial begin
        $display("=== tb_note_manager_sus (T5 延音踏板语义) ===");

        // 初值
        sample_tick = 0; note_valid = 0; note_axis = 0; note_phase_inc = 0;
        note_velocity = 0; note_kind = 0; note_src = 0;
        vel_upd_valid = 0; vel_upd_axis = 0; vel_upd_value = 0; vel_upd_src = 0;
        pitch_upd_valid = 0; pitch_upd_axis = 0; pitch_upd_value = 0; pitch_upd_src = 0;
        default_timbre = 2'd0; evt_timbre_valid = 0; evt_timbre = 2'd0;
        base_semi = 7'd0; base_commit = 0; transpose_semi = 5'sd0;
        event_lost_clr = 0;
        sus_pedal = 1'b0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        wait_ticks(3);

        // ── S1：不踩踏板（回归判据 + 反向对照）─────────────────────────
        //   ⭐ 实测（traj）：不踩踏板 ⇒ 松键后 ~50 拍内电平归 0（release 很快）
        press(4'd1, 3'd0);
        wait_ticks(40);
        chk(count_axis_gate(4'd1) == 1, "S1a no-pedal: gate=1 while held");
        rel_note(4'd1, 3'd0);
        wait_ticks(100);
        chk(count_axis_gate(4'd1) == 0, "S1b no-pedal release => gate=0 (zero-regression)");
        cap_level(4'd1);
        chk(lv_cap == 0, "S1c no-pedal release => level back to 0 (note gone)");
        chk(count_axis_envact(4'd1) == 0, "S1d no-pedal release => env inactive");

        // ── S2：踩住踏板 ⇒ 松键后音【不消失】（电平仍在高位）──────────
        //   ⭐ 实测（traj）：踩住 ⇒ 松键后 50 拍仍有 10752、400 拍仍有 51032
        sus_pedal = 1'b1;
        wait_ticks(2);
        press(4'd2, 3'd0);
        wait_ticks(40);
        chk(count_axis_gate(4'd2) == 1, "S2a pedal+press => gate=1");
        rel_note(4'd2, 3'd0);
        wait_ticks(100);
        chk(count_axis_gate(4'd2) == 1, "S2b pedal held: release => gate STILL 1");
        cap_level(4'd2);
        chk(lv_cap > 5000, "S2c pedal held: level still HIGH (note not gone)");
        chk(count_axis_envact(4'd2) == 1, "S2d pedal held: env STILL active");

        // ── S3：松踏板 ⇒ 被留住的音【开始释放】、最终归 0 ───────────────
        //   ⚠️ 两个观测口径必须分开（⭐ 实测踩过坑）：
        //      · "释放开始" ⇒ 200 拍内电平下降（⭐ 与"踩住时的慢衰减"区分靠幅度）
        //      · "最终归 0" ⇒ ⭐ timbre0 的 release 步长只有 6，从峰值 51000 掉到 0
        //        要 ~8500 拍 ⇒ ⭐ 给 12000 拍（⛔ 200 拍会假红）
        sus_pedal = 1'b0;
        wait_ticks(6);
        chk(count_axis_gate(4'd2) == 0, "S3a pedal released => gate falls to 0");
        cap_level(4'd2); lv_a = lv_cap;
        wait_ticks(200);
        cap_level(4'd2); lv_b = lv_cap;
        chk(lv_b < lv_a, "S3b pedal released => level starts FALLING (release begins)");
        wait_ticks(12000);
        cap_level(4'd2); lv_c = lv_cap;
        chk(lv_c == 0, "S3c pedal released => eventually level=0 (note really ends)");
        chk(count_axis_envact(4'd2) == 0, "S3d pedal released => env inactive");

        // ── S4：踩住踏板 + 同轴再按 ⇒ 正常重触发（不叠音）──────────────
        sus_pedal = 1'b1;
        wait_ticks(2);
        press(4'd3, 3'd0);
        wait_ticks(4);
        rel_note(4'd3, 3'd0);
        wait_ticks(4);
        chk(count_axis_gate(4'd3) == 1, "S4a pedal: axis3 held after release");
        press(4'd3, 3'd0);                    // 同轴再按
        wait_ticks(4);
        chk(count_axis(4'd3) == 1, "S4b re-press same axis => exactly ONE voice (no stacking)");
        chk(count_axis_gate(4'd3) == 1, "S4c re-press => gate=1 (retrigger)");
        rel_note(4'd3, 3'd0);
        wait_ticks(3);
        chk(count_axis_gate(4'd3) == 1, "S4d pedal still held => gate stays 1");

        // ── S5：踩住踏板时，非手弹源（src=1）照常释放 ──────────────────
        press(4'd4, 3'd1);
        wait_ticks(4);
        rel_note(4'd4, 3'd1);
        wait_ticks(4);
        chk(count_axis_gate(4'd4) == 0, "S5 pedal held but src!=0 => gate=0 (not sustained)");

        sus_pedal = 1'b0;
        wait_ticks(4);

        // ── S6：松键之后才踩踏板 ⇒ 不复活 ──────────────────────────────
        press(4'd5, 3'd0);
        wait_ticks(4);
        rel_note(4'd5, 3'd0);
        wait_ticks(4);
        chk(count_axis_gate(4'd5) == 0, "S6a released before pedal => gate=0");
        sus_pedal = 1'b1;                     // 事后才踩
        wait_ticks(4);
        chk(count_axis_gate(4'd5) == 0, "S6b pedal pressed AFTER release => NO resurrection");
        sus_pedal = 1'b0;
        wait_ticks(3);

        // ── 汇总 ────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_note_manager_sus — %0d/%0d judgements held (T5 延音踏板语义)",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_note_manager_sus — %0d pass / %0d fail",
                     pass_cnt, fail_cnt);
        $finish;
    end

    // 超时保护（本 tb 应 < 1 s）
    initial begin
        #50_000_000;
        $display("FAIL: tb_note_manager_sus TIMEOUT");
        $finish;
    end

endmodule
