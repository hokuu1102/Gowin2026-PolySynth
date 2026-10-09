// ═══════════════════════════════════════════════════════════════════════════
// tb_note_manager_vel_wrap.sv — ⭐ P0-01 力度斜坡 8 位截断回绕（2026-10-09）
//
//   🔴 被审出的缺陷（review/时序与逻辑审查-20261009.md 的 [P0-01]）：
//      note_manager.v:1070-1078 三处比较写成 `vel_r[i] + 8'd8` / `vtgt + 8'd8`，
//      ⚠️ `vel_r` 是 `reg [7:0]`、`8'd8` 是 8 位常量 ⇒ ⭐ **加法表达式自定宽度 = 8 位**
//      （IEEE 1364-2001 §5.1.1：比较不会把操作数加宽到 9 位）⇒ 是 **mod 256**：
//         vel_r=248 ⇒ 248+8 = 0     ⇒ `tgt > 0` 几乎恒真 ⇒ vel_r 被写成 0
//         vel_r=255 ⇒ 255+8 = 7     ⇒ 同理 ⇒ 被写成 7
//      ⇒ 🔴 满力度音**第一个 sample_tick 就掉到 7/255 ≈ −31 dB**，
//         且随后在 0↔248 之间锯齿（32 拍 = 655 µs ≈ 1.53 kHz 颤音）✅
//
//   ⭐ 为什么现有 tb 全绿（假绿）：`tb_note_manager_vel_ramp.sv` 是**纯组合模型互比**
//      （没例化 RTL），它的"黄金模型"(:28/:35) **逐字复刻了同一个表达式** ⇒ 两边一起错 ✅
//
//   ⭐ 本 tb 的判据（⭐ 每条都指名"改前必红"）：
//     W1 手弹 src=0 · vel=255 ⇒ ⭐ 1 个 sample_tick 后 voice_velocity **必须仍是 255**
//        （🔴 改前 = 7）
//     W2 手弹 src=0 · vel=248 ⇒ ⭐ 必须仍是 248（🔴 改前 = 0）
//     W3 回放 src=1 · vel=250 ⇒ ⭐ 必须仍是 250（🔴 改前 = 2）
//     W4 回放 src=1 · vel=255 收到目标 248（Δ=7 ≤ 8）⇒ ⭐ 必须**直接吸附到 248**
//        （🔴 改前：`248+8=0 < 255` 成立 ⇒ 走 −8 斜坡 ⇒ 247，慢一拍）
//     W5 下坡不回归：回放 src=1 · vel=255 收到目标 100 ⇒ 必须 247（−8），⛔ 不许跳到 0
//     W6 边界不溢出：vel=250 收到目标 255（Δ=5 ≤ 8）⇒ ⭐ 直接吸附 255
//        （🔴 改前：`255 > 250+8=2` 成立 ⇒ 走 +8 ⇒ 2，反向掉）
//   📌 语义基准（规格）：`next = (tgt > cur+8) ? cur+8 : ((tgt+8 < cur) ? cur-8 : tgt)`
//      ⭐ 比较用 **9 位**（零扩展），加法不截断 ✅
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_note_manager_vel_wrap;

    localparam integer POLY     = 2;
    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer TIMBRE_W = 2;
    localparam integer ENV_W    = 16;
    localparam integer TICK_CYC = 64;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

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
    reg                  sus_pedal;
    //  ⭐ 包络侧：让 note_manager 认为"音在响"（否则 gate 会被清）
    reg [POLY-1:0]       env_active;
    reg [POLY*ENV_W-1:0] env_level;

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
    wire [3:0]               alloc_voice;
    wire                     event_lost;
    wire [7:0]               event_lost_cnt;

    note_manager #(
        .POLY_TARGET  (POLY),
        .AXIS_W       (AXIS_W),
        .PHASE_W      (PHASE_W),
        .VEL_W        (VEL_W),
        .TIMBRE_W     (TIMBRE_W),
        .ENV_W        (ENV_W),
        .T3_EN        (1),
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
        .sus_pedal_i        (sus_pedal),
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

    //  ⭐ 包络侧（声明已上移到端口区之前）
    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    task tick_once;
        begin
            @(negedge clk); sample_tick = 1'b1;
            @(negedge clk); sample_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    task send_note;
        input [1:0] kind;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  vel;
        input [2:0]        srct;
        begin
            @(negedge clk);
            note_valid    = 1'b1;
            note_kind     = kind;
            note_axis     = ax;
            note_phase_inc= 32'd1_000_000;
            note_velocity = vel;
            note_src      = srct;
            @(negedge clk);
            note_valid    = 1'b0;
            repeat (6) @(negedge clk);      // 让提交/扫描流水走完
        end
    endtask

    task send_vel_upd;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  val;
        input [2:0]        srct;
        begin
            @(negedge clk);
            vel_upd_valid = 1'b1;
            vel_upd_axis  = ax;
            vel_upd_value = val;
            vel_upd_src   = srct;
            @(negedge clk);
            vel_upd_valid = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    function [VEL_W-1:0] vel_of;
        input integer v;
        begin vel_of = voice_velocity[v*VEL_W +: VEL_W]; end
    endfunction

    integer k;
    initial begin
        $display("=== tb_note_manager_vel_wrap (P0-01 力度斜坡 8 位回绕) ===");

        sample_tick      = 1'b0;
        note_valid       = 1'b0;
        note_axis        = 4'd0;
        note_phase_inc   = 32'd0;
        note_velocity    = 8'd0;
        note_kind        = 2'd0;
        note_src         = 3'd0;
        vel_upd_valid    = 1'b0;
        vel_upd_axis     = 4'd0;
        vel_upd_value    = 8'd0;
        vel_upd_src      = 3'd0;
        pitch_upd_valid  = 1'b0;
        pitch_upd_axis   = 4'd0;
        pitch_upd_value  = 32'd0;
        pitch_upd_src    = 3'd0;
        default_timbre   = 2'd0;
        evt_timbre_valid = 1'b0;
        evt_timbre       = 2'd0;
        base_semi        = 7'd0;
        base_commit      = 1'b0;
        transpose_semi   = 5'sd0;
        event_lost_clr   = 1'b0;
        sus_pedal        = 1'b0;
        env_active       = {POLY{1'b1}};     // ⭐ 音"在响"
        env_level        = {POLY{16'd40000}};

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        // ── W1 手弹 vel=255 ⇒ 一个 tick 后必须仍 255 ──────────────────────
        send_note(2'd0, 4'd1, 8'd255, 3'd0);
        tick_once;
        $display("      [dbg] W1 vel=255 src=0 => vel_of(0)=%0d (期望 255)", vel_of(0));
        chk(vel_of(0) === 8'd255, "W1 hand-play vel=255 stays 255 after 1 sample_tick");

        // ── W2 手弹 vel=248 ⇒ 必须仍 248 ─────────────────────────────────
        send_note(2'd1, 4'd1, 8'd0, 3'd0);          // 先松开
        send_note(2'd0, 4'd2, 8'd248, 3'd0);
        tick_once;
        //  ⭐ 分配不保证落在哪个 voice ⇒ 扫全部（⭐ 只要有一个是 248 且没有回绕值即通过）
        $display("      [dbg] W2 vel=248 src=0 => vel_of(0)=%0d vel_of(1)=%0d (期望 至少一个 248)",
                 vel_of(0), vel_of(1));
        chk(((voice_gate[0] === 1'b1) && (vel_of(0) === 8'd248)) ||
            ((voice_gate[1] === 1'b1) && (vel_of(1) === 8'd248)),
            "W2 hand-play vel=248 stays 248 after 1 sample_tick");

        // ── W3 回放 src=1 vel=250 ⇒ 必须仍 250 ───────────────────────────
        send_note(2'd1, 4'd2, 8'd0, 3'd0);
        send_note(2'd0, 4'd3, 8'd250, 3'd1);
        tick_once;
        $display("      [dbg] W3 vel=250 src=1 => vel_of(0)=%0d (期望 250)", vel_of(0));
        chk(vel_of(0) === 8'd250, "W3 playback vel=250 stays 250 after 1 sample_tick");

        // ── W4 Δ=7 ≤ 8 ⇒ 直接吸附（⛔ 不许走 −8 斜坡）─────────────────────
        send_vel_upd(4'd3, 8'd248, 3'd1);
        tick_once;
        $display("      [dbg] W4 tgt=248 from 250 => vel_of(0)=%0d (期望 248)", vel_of(0));
        chk(vel_of(0) === 8'd248, "W4 |tgt-cur|=7 <= 8 => snaps to 248 (no slow ramp)");

        // ── W5 下坡不回归：从 248 给 100 ⇒ 必须 240（−8），⛔ 不许跳 0 ────
        send_vel_upd(4'd3, 8'd100, 3'd1);
        tick_once;
        $display("      [dbg] W5 tgt=100 from 248 => vel_of(0)=%0d (期望 240)", vel_of(0));
        chk(vel_of(0) === 8'd240, "W5 descending ramp steps -8 (248 -> 240), no wrap");

        // ── W6 上坡边界：从 240 给 255（Δ=15 > 8）⇒ 必须 248（+8）─────────
        send_vel_upd(4'd3, 8'd255, 3'd1);
        tick_once;
        $display("      [dbg] W6 tgt=255 from 240 => vel_of(0)=%0d (期望 248)", vel_of(0));
        chk(vel_of(0) === 8'd248, "W6 ascending ramp steps +8 (240 -> 248), no wrap");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_note_manager_vel_wrap — %0d/%0d judgements held (P0-01 无回绕)",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_note_manager_vel_wrap — %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_note_manager_vel_wrap TIMEOUT");
        $finish;
    end

endmodule
