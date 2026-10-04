`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_looper_replay_tail.sv · ⭐ C 项验收：⭐ **回放的 PAD 音必须拿到与现场【同一条】release 拖尾**
//                              （2026-09-30 新增）
//
//  🔴 **用户上板原话**：*"正常演奏的时候 pad 音色有一个很长的拖尾，然而在回放中就只有
//     一个音高的声音，发出之后就立即释放了，没有后面那个每个音色都不同的拖尾 release"* ✅
//
//  ⭐⭐ **本 tb 串的是【真链路】**（⛔ 不用桩）：
//     `looper`（回放，源 C，标签 `3'd4`）→ `evt_merge` → `note_manager`
//     → `envelope_bank`（⭐ **真 `adsr`**，⭐ 音色→release 步长就在这里）→ 回灌 `env_active/env_level`
//     ＋ ⭐ **更新通路**：`looper.play_upd_*`（⭐ 标签 `3'd4`）**与**手弹 `vu_*`（⭐ 标签 `3'd0`）
//       按 `top.v:3308-3314` 的**同一套 mux** 接进 `note_manager.vel_upd_*` ✅
//
//  ⭐⭐ **为什么必须带上 `envelope_bank`/`adsr`**（⭐ 这是本 tb 的关键）：
//     🔴 "有没有拖尾"**不是** looper 的属性，而是 **`adsr` 的 release 时长**：
//        ⭐ `adsr.v:158-164`：⭐ release 是**固定步长**（每 `sample_tick` 降 `release_step`）
//        ⇒ ⭐ **拖尾时长 = `松手那一刻的包络电平 / release_step`** ✅
//        ⇒ ⭐ 它同时取决于【**力度**（决定电平）] 与【**音色**（决定步长）] **两件事** ✅
//     ⭐ `adsr.v:84-95` 的**每音色 release 步长**（⭐ 关键数据）：
//        · `timbre 0 = BASS`  ⇒ **6**（⭐ 掉得最快 ⇒ 拖尾最短）
//        · `timbre 1/2/3`     ⇒ **1**（⭐ 最慢 ⇒ **PAD(3) 拖尾最长** ✅）
//     ⇒ 🔴 **只要回放的音被当成 BASS（或力度没爬上去）⇒ 拖尾立刻短 6 倍** ✅
//
//  ⭐ 判据（⭐ 名字纯 ASCII、≤128 字节；⭐ **每条都能红**）：
//     ① 现场（录制时手弹）的 PAD 音：release 斜率 = **1 电平/采样拍**（⭐ 拖尾真的长）
//     ② 回放的音：release 斜率 **与现场逐值相同**（⭐ 音色没被搞错）
//     ③ 回放的音：release **起始电平**与现场一致（±2%）⇒ ⭐ **拖尾时长一致**
//     ④ 回放的 voice 音色 = **录制时的 PAD(3)**，⛔ 不是 `default_timbre_i`(=BASS 0)
//     ⑤ 回放的 `note_off` 带的是**录到的终点力度**（200），⛔ 不是起音力度(40)
//     ⑥ 非空洞性：⭐ 现场的拖尾**确实很长**（256 采样拍后仍 > 90% 起始电平）
//
//  ⚠️⚠️ **时基（⭐ `K-93`：⛔ 不许与系统语义不一致）**：
//     真实系统：⭐ `clk=50 MHz` · `CLK_PER_SAMPLE=1024` · 1 PPQN tick = 26043 clk
//        ⇒ ⭐ **25.4 采样拍 / tick** ✅
//     本 tb：⭐ `CLK_PER_SAMPLE=16` · `TICK_GAP=406` ⇒ ⭐ **25.375 采样拍 / tick** ✅
//        ⇒ ⭐ **比例逐位保持**（⭐ `note_manager` 的"每采样拍 ±8"平滑、
//           `adsr` 的每采样拍步进、`looper` 的每 tick 一条插值 **全都对得上**）✅
//        ⇒ ⭐ 只是把**墙钟时间压缩 64 倍** ⇒ ⛔ 不改任何可观测行为 ✅
// ─────────────────────────────────────────────────────────────────────────────
`define MAXW 40_000_000

module tb_looper_replay_tail;

    localparam integer POLY      = 32;
    localparam integer AXIS_W    = 4;
    localparam integer PHASE_W   = 32;
    localparam integer VEL_W     = 8;
    localparam integer TIMBRE_W  = 2;
    localparam integer KIND_W    = 2;
    localparam integer ENV_W     = 16;
    localparam integer AGE_W     = 16;
    localparam integer IDX_W     = 5;
    localparam integer TICK_W    = 20;
    localparam integer EVT_MAX   = 64;

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;
    localparam [2:0]        SRC_LIVE   = 3'd0;   // ⭐ 手弹
    localparam [2:0]        SRC_LOOPER = 3'd4;   // ⭐ looper 回放（⭐ 与 `top.v` 一致）
    localparam [TIMBRE_W-1:0] TBR_PAD  = 2'd3;   // ⭐ 录制时的手弹音色 = PAD（⭐ release 步长 1）
    localparam [TIMBRE_W-1:0] TBR_BASS = 2'd0;   // ⭐ 录完之后切成的音色 = BASS（⭐ 步长 6，⭐ 诱饵）

    //  ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //     每拍服务一个 voice**（⭐ 见 `rtl/w3b/envelope_bank.v` 的文件头）⇒
    //     **每帧必须留出 ≥34 拍**让 32 路全部更新完（⭐ 本 tb `POLY=32`）。
    //     ⛔ 原来 `CLK_PER_SAMPLE=4` 只够扫 3 路 ⇒ 第 3 路之后**永远不更新**
    //        ⇒ ⭐ 实测 C1/C3/C6/C6b 四条红。
    //     ⭐ **修法**：⭐ `CLK_PER_SAMPLE` 4 → **34**，⭐ `TICK_GAP` 102 → **864**
    //        ⇒ ⭐ **采样拍 : PPQN tick 的比例仍是 25.4**（⭐ 864/34 = 25.41，
    //           ⭐ 与真实 26043/1024 = 25.43 一致）⇒ ⭐ **语义完全不变**，
    //           ⭐ 只是把墙钟时间压缩比从 256× 改成 30× ✅
    //     📌 副作用：⭐ 仿真时间 ×8.5（⭐ 本 tb 本来就短 ⇒ 可接受）
    localparam integer CLK_PER_SAMPLE = 34;      // ⭐ 压缩时基（⭐ 见上）
    localparam integer TICK_GAP       = 864;     // ⭐ 25.41 采样拍 / tick（⭐ 真实 25.43）
    localparam integer LOOP_TICKS     = 250;     // ⭐ 录 250 个 tick
    localparam integer OFF_TICK       = 60;      // ⭐ 第 60 个 tick 松手（⭐ 60×25.5 ≈ 1530 采样拍
                                                 //    ⇒ ⭐ 包络**已经爬满**持续电平 ✅）
    localparam integer V_ON           = 20;      // ⭐ 起音力度（⭐ 通常很小）
    localparam integer V_END          = 120;     // ⭐ 手势抬到的终点力度
    //  ⭐ `note_off` **事件自带**的力度 = `VEL_DEFAULT`（⭐ 与手势无关，⭐ 见下方注释）✅
    localparam integer V_OFF_EVT      = 200;
    localparam integer CAP_N          = 256;     // ⭐ 松手后连续采 256 个采样拍

    localparam [PHASE_W-1:0] INC_A = 32'h1111_0001;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    task chk;
        input [8*110-1:0] name;
        input             cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    // ── 采样拍 ────────────────────────────────────────────────────────────────
    integer smp_cnt = 0;
    reg     sample_tick = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            smp_cnt     <= 0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= (smp_cnt == 0);
            smp_cnt     <= (smp_cnt + 1 >= CLK_PER_SAMPLE) ? 0 : (smp_cnt + 1);
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐ 手弹通路（⭐ 与 `top.v` 一致：⭐ **同一拍同时喂 `evt_merge` 与 `looper`**）✅
    // ══════════════════════════════════════════════════════════════════════
    reg               lv_valid = 1'b0;
    reg  [AXIS_W-1:0] lv_axis  = 4'd0;
    reg  [PHASE_W-1:0]lv_inc   = {PHASE_W{1'b0}};
    reg  [VEL_W-1:0]  lv_vel   = {VEL_W{1'b0}};
    reg  [KIND_W-1:0] lv_kind  = KIND_ON;
    //  ⭐ 手弹"位置式力度"流（⭐ 端点来源；⭐ `top.v` 接 `vu_*`）✅
    reg               vu_valid = 1'b0;
    reg  [AXIS_W-1:0] vu_axis  = 4'd0;
    reg  [VEL_W-1:0]  vu_val   = {VEL_W{1'b0}};
    //  ⭐⭐ **当前键盘音色**（⭐ `top.v` 的 `timbre_sel_r`）—— ⭐ 它**同时**是：
    //     · ⭐ `looper.live_timbre_i`（⭐ 录制时**逐音**记下 ✅）
    //     · ⭐ `note_manager.default_timbre_i`（⭐ 手弹事件**不带** timbre ⇒ 走这个兜底 ✅）
    //   📌 依据（⭐ `top.v`）：⭐ `seq_arb` 的手弹口 `.live_timbre_valid_i(1'b0)`
    //      ⇒ ⭐ **手弹音色走的是 `default_timbre_i`**，⛔ 不是事件 sideband ✅
    reg  [TIMBRE_W-1:0] kb_timbre = TBR_PAD;

    // ══════════════════════════════════════════════════════════════════════
    //  ① `looper`
    // ══════════════════════════════════════════════════════════════════════
    reg               tick_i     = 1'b0;
    reg  [TICK_W-1:0] tick_cnt_i = {TICK_W{1'b0}};
    reg               bar_start_i= 1'b0;
    reg               transport_i= 1'b0;
    reg  [0:0]        rec_req_i  = 1'b0;
    reg  [0:0]        stop_req_i = 1'b0;
    reg  [0:0]        play_en_i  = 1'b0;
    reg  [0:0]        clear_req_i= 1'b0;

    wire               lp_valid, lp_tbr_v, lp_upd_valid;
    wire [AXIS_W-1:0]  lp_axis, lp_upd_axis;
    wire [PHASE_W-1:0] lp_inc, lp_upd_inc;
    wire [VEL_W-1:0]   lp_vel, lp_upd_vel;
    wire [KIND_W-1:0]  lp_kind;
    wire [TIMBRE_W-1:0]lp_tbr;
    wire [0:0]         lp_layer_state;
    wire [15:0]        lp_evt_cnt, lp_drop_cnt;
    wire [0:0]         lp_full;
    wire               lp_overflow;

    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .TICK_W(TICK_W), .LAYERS(1),
        .EVT_MAX(EVT_MAX), .CNT_W(16)
    ) u_looper (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .live_valid_i(lv_valid), .live_axis_i(lv_axis), .live_inc_i(lv_inc),
        .live_vel_i(lv_vel), .live_kind_i(lv_kind),
        .live_timbre_i(kb_timbre),                     // ⭐ 录制时手弹音色（⭐ 逐音记下）✅
        .live_vel_valid_i(vu_valid), .live_vel_axis_i(vu_axis),
        .live_vel_value_i(vu_val),
        .play_valid_o(lp_valid), .play_axis_o(lp_axis), .play_inc_o(lp_inc),
        .play_vel_o(lp_vel), .play_kind_o(lp_kind),
        .play_timbre_o(lp_tbr), .play_timbre_valid_o(lp_tbr_v),
        .play_upd_valid_o(lp_upd_valid), .play_upd_axis_o(lp_upd_axis),
        .play_upd_inc_o(lp_upd_inc), .play_upd_vel_o(lp_upd_vel),
        .rec_req_i(rec_req_i), .stop_req_i(stop_req_i),
        .play_en_i(play_en_i), .clear_req_i(clear_req_i),
        .layer_state_o(lp_layer_state), .evt_cnt_flat_o(lp_evt_cnt),
        .full_o(lp_full), .drop_cnt_o(lp_drop_cnt), .overflow_o(lp_overflow)
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ② `evt_merge`（⭐ A = 手弹 · B = 不用 · C = looper 回放）
    // ══════════════════════════════════════════════════════════════════════
    wire               mg_valid, mg_tv;
    wire [AXIS_W-1:0]  mg_axis;
    wire [PHASE_W-1:0] mg_inc;
    wire [VEL_W-1:0]   mg_vel;
    wire [KIND_W-1:0]  mg_kind;
    wire [TIMBRE_W-1:0]mg_tb;
    wire [2:0]         mg_src;
    wire [15:0]        mg_coll, mg_merged, mg_drop;
    wire               mg_ovf;

    evt_merge #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(6)
    ) u_evt_merge (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(lv_valid), .a_axis_i(lv_axis), .a_phase_inc_i(lv_inc),
        .a_velocity_i(lv_vel), .a_kind_i(lv_kind),
        .a_timbre_valid_i(1'b0), .a_timbre_i({TIMBRE_W{1'b0}}),
        .a_src_i(SRC_LIVE),
        .b_valid_i(1'b0), .b_axis_i({AXIS_W{1'b0}}),
        .b_phase_inc_i({PHASE_W{1'b0}}), .b_velocity_i({VEL_W{1'b0}}),
        .b_kind_i({KIND_W{1'b0}}), .b_timbre_valid_i(1'b0),
        .b_timbre_i({TIMBRE_W{1'b0}}), .b_src_i(3'd3),
        .c_valid_i(lp_valid), .c_axis_i(lp_axis), .c_phase_inc_i(lp_inc),
        .c_velocity_i(lp_vel), .c_kind_i(lp_kind),
        .c_timbre_valid_i(lp_tbr_v), .c_timbre_i(lp_tbr),
        .c_src_i(SRC_LOOPER),
        .evt_valid_o(mg_valid), .evt_axis_o(mg_axis), .evt_phase_inc_o(mg_inc),
        .evt_velocity_o(mg_vel), .evt_kind_o(mg_kind),
        .evt_timbre_valid_o(mg_tv), .evt_timbre_o(mg_tb),
        .evt_src_o(mg_src),
        .collision_cnt_o(mg_coll), .merged_cnt_o(mg_merged),
        .drop_cnt_o(mg_drop), .overflow_o(mg_ovf)
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ③ `note_manager` ＋ ⭐ **更新通路 mux（⭐ 与 `top.v:3308-3314` 同式）**
    //     ⚠️ 手弹那拍给 `0`、⭐ looper 那拍给 `4` ⇒ ⭐ **事件标签与更新标签必须成对** ✅
    // ══════════════════════════════════════════════════════════════════════
    wire               upd_valid = vu_valid | lp_upd_valid;
    wire [AXIS_W-1:0]  upd_axis  = vu_valid ? vu_axis  : lp_upd_axis;
    wire [VEL_W-1:0]   upd_val   = vu_valid ? vu_val   : lp_upd_vel;
    wire [2:0]         upd_src   = vu_valid ? SRC_LIVE : SRC_LOOPER;

    wire [POLY-1:0]        gate_bus, act_bus, rel_bus, rr_bus;
    wire [POLY*AXIS_W-1:0] axis_bus;
    wire [POLY*VEL_W-1:0]  vel_bus;
    wire [POLY*TIMBRE_W-1:0] tbr_bus;
    wire                   nm_alloc_valid;
    wire [IDX_W-1:0]       nm_alloc_voice;
    wire [POLY*ENV_W-1:0]  env_level;
    wire [POLY-1:0]        env_active;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .FIFO_DEPTH(32), .IDX_W(IDX_W)
    ) u_note_manager (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(mg_valid), .note_axis_i(mg_axis),
        .note_phase_inc_i(mg_inc), .note_velocity_i(mg_vel),
        .note_kind_i(mg_kind), .note_src_i(mg_src),
        .vel_upd_valid_i(upd_valid), .vel_upd_axis_i(upd_axis),
        .vel_upd_value_i(upd_val), .vel_upd_src_i(upd_src),
        .pitch_upd_valid_i(lp_upd_valid), .pitch_upd_axis_i(lp_upd_axis),
        .pitch_upd_value_i(lp_upd_inc), .pitch_upd_src_i(SRC_LOOPER),
        .default_timbre_i(kb_timbre),                  // ⭐ 手弹兜底音色 = 当前键盘音色 ✅
        .evt_timbre_valid_i(mg_tv), .evt_timbre_i(mg_tb),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(gate_bus), .voice_active_o(act_bus),
        .voice_releasing_o(rel_bus), .voice_axis_o(axis_bus),
        .voice_phase_inc_o(), .voice_velocity_o(vel_bus),
        .voice_timbre_o(tbr_bus), .voice_drum_o(), .voice_age_o(),
        .voice_retrig_reset_o(rr_bus),
        .alloc_valid_o(nm_alloc_valid), .alloc_voice_o(nm_alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ④ `envelope_bank`（⭐ **真 `adsr`** ⇒ ⭐ 每音色 release 步长就在这里）✅
    // ══════════════════════════════════════════════════════════════════════
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W)
    ) u_envelope_bank (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(gate_bus), .velocity_i(vel_bus),
        .retrig_reset_i(rr_bus), .timbre_i(tbr_bus),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ── ⭐ 观测助手（⭐ 组合函数，⛔ 不加寄存器）──────────────────────────────
    function integer max_level;
        integer k;
        integer v;
        begin
            max_level = 0;
            for (k = 0; k < POLY; k = k + 1) begin
                v = env_level[k*ENV_W +: ENV_W];
                if (v > max_level) max_level = v;
            end
        end
    endfunction

    //  ⭐ "还在响/还在衰减"的 voice 音色（⭐ 松手后 `gate=0` 但 `env_active=1`）✅
    function [TIMBRE_W-1:0] sounding_timbre;
        integer k;
        begin
            sounding_timbre = TBR_BASS;
            for (k = 0; k < POLY; k = k + 1)
                if (gate_bus[k] || env_active[k])
                    sounding_timbre = tbr_bus[k*TIMBRE_W +: TIMBRE_W];
        end
    endfunction

    // ── ⭐ 拖尾捕获（⭐ 0 = 现场 · 1 = 回放）─────────────────────────────────
    reg     cap_en;
    integer cap_sel;
    integer cap_cnt;
    integer cap_lv [0:1][0:CAP_N-1];
    integer cap_tbr[0:1];

    always @(posedge clk) begin
        if (rst_n && sample_tick && cap_en) begin
            cap_lv[cap_sel][cap_cnt] = max_level();
            if (cap_cnt == 0) cap_tbr[cap_sel] = sounding_timbre();
            if (cap_cnt >= CAP_N-1) begin
                cap_en  <= 1'b0;
                cap_cnt <= 0;
            end else begin
                cap_cnt <= cap_cnt + 1;
            end
        end
    end

    // ── ⭐ 事件观测（⭐ 在 `negedge` 采，⭐ `tb_evt_merge` 坑 (a)：⭐ 沿之后才看得见）──
    integer live_off_seen;      // ⭐ 现场 `note_off` 到达 `note_manager`
    integer rep_on_seen, rep_off_seen;
    integer rep_off_vel;        // ⭐ 回放 `note_off` 带的力度
    integer rep_on_vel;         // ⭐ 回放 `note_on` 带的力度
    integer rep_on_tbr, rep_off_tbr;
    integer mg_off_live_seen;

    always @(negedge clk) begin
        if (rst_n && mg_valid) begin
            if (mg_src == SRC_LOOPER) begin
                if (mg_kind == KIND_ON) begin
                    rep_on_seen  = rep_on_seen + 1;
                    rep_on_vel   = mg_vel;
                    rep_on_tbr   = mg_tb;
                end else begin
                    rep_off_seen = rep_off_seen + 1;
                    rep_off_vel  = mg_vel;
                    rep_off_tbr  = mg_tb;
                end
            end else if (mg_kind == KIND_OFF) begin
                mg_off_live_seen = mg_off_live_seen + 1;
            end
        end
    end

    // ── ⭐ 驱动小任务 ────────────────────────────────────────────────────────
    integer g_tick = 0;
    task automatic do_tick;
        integer g;
        begin
            @(negedge clk);
            tick_i     = 1'b1;
            tick_cnt_i = g_tick[TICK_W-1:0];
            g_tick     = g_tick + 1;
            @(negedge clk);
            tick_i     = 1'b0;
            for (g = 1; g < TICK_GAP; g = g + 1) @(negedge clk);
        end
    endtask

    task automatic idle_ticks;
        input integer n;
        integer kk;
        begin
            for (kk = 0; kk < n; kk = kk + 1) do_tick;
        end
    endtask

    task automatic live_evt;
        input [KIND_W-1:0]  kd;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        begin
            @(negedge clk);
            lv_valid = 1'b1; lv_kind = kd; lv_axis = ax; lv_inc = inc; lv_vel = vl;
            @(negedge clk);
            lv_valid = 1'b0;
        end
    endtask

    task automatic live_vel_upd;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  vl;
        begin
            @(negedge clk);
            vu_valid = 1'b1; vu_axis = ax; vu_val = vl;
            @(negedge clk);
            vu_valid = 1'b0;
        end
    endtask

    //  ⚠️ 用 `negedge` 等采样拍（⭐ 那里 `sample_tick` 已是稳定值，⛔ 无 delta 竞争）
    //     —— ⭐ `@(posedge clk iff ...)` iverilog **不支持**（⭐ 实测语法错）✅
    task automatic wait_samples;
        input integer n;
        integer kk;
        begin
            for (kk = 0; kk < n; kk = kk + 1) begin
                @(negedge clk);
                while (!sample_tick) @(negedge clk);
            end
        end
    endtask

    integer i;
    integer slope_live, slope_rep, k16_ok, k64_ok, k128_ok, k255_ok;
    integer lv_max_after;

    initial begin
        cap_en = 1'b0; cap_sel = 0; cap_cnt = 0;
        for (i = 0; i < CAP_N; i = i + 1) begin
            cap_lv[0][i] = 0;
            cap_lv[1][i] = 0;
        end
        cap_tbr[0] = TBR_BASS; cap_tbr[1] = TBR_BASS;
        live_off_seen = 0; rep_on_seen = 0; rep_off_seen = 0;
        rep_off_vel = 0; rep_on_vel = 0; rep_on_tbr = 0; rep_off_tbr = 0;
        mg_off_live_seen = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (20) @(negedge clk);

        // ══════════════════════════════════════════════════════════════════
        //  ① 录制：⭐ 手弹一个 PAD 音 —— 轻起音(40) → 手势抬到 200 → 第 60 tick 松手
        //     ⚠️ **本 tb 不驱动 `bar_start_i`** ⇒ ⭐ `grid_ok_r = 0` ⇒
        //        ⭐ `T41` 的小节对齐**全部旁路** ⇒ ⭐ 本 tb 只测"拖尾"，与 A 项无关 ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 1: record a PAD note (press, gesture up to 200, release at tick %0d) ==", OFF_TICK);
        transport_i = 1'b1;
        @(negedge clk); rec_req_i = 1'b1; @(negedge clk); rec_req_i = 1'b0;
        repeat (4) @(negedge clk);

        do_tick;                                   // ⭐ tick 0
        live_evt(KIND_ON, 4'd1, INC_A, V_ON);      // ⭐ 起音力度 40
        //  ⭐⭐ 手势：⭐ **线性**从 40 抬到 200（⭐ 每 tick 一步，⭐ 共 60 步）
        //   🔴 **为什么故意用线性**：⭐ A2 的设计前提就是"**只录两个端点 + 回放线性插值**"
        //      ⇒ ⭐ 本 tb 要让**现场轨迹 = 回放轨迹** ⇒ ⭐ 剩下的差异才**只能**来自缺陷 ✅
        //      ⚠️ 若现场是"瞬间跳到 200"（⭐ 真实快速按键），⭐ 回放会把它拉成整条线性
        //         ⇒ ⚠️ 松手电平差 ~10%（⭐ 拖尾长度差 ~10%，⭐ 听不出来）——
        //         ⭐ 那是"**只录端点**"的固有代价，⛔ 不是本判据要抓的缺陷 ✅
        for (i = 1; i < OFF_TICK; i = i + 1) begin
            do_tick;
            live_vel_upd(4'd1, V_ON + (V_END - V_ON) * i / (OFF_TICK - 1));
        end
        idle_ticks(1);                             // ⭐ 走到第 60 tick
        //  ⭐⭐ **松手事件自带的力度 = 释放阈值(200)**，⛔ **不是**手势的终点力度(120)！
        //     🔴 依据（⭐ `top.v` 对 `w3a_evt_vel` 的算式，⭐ 已核实）：
        //        `w3a_evt_vel = (am_pos_in < VEL_TRIG_TH) ? VEL_DEFAULT : pos_to_vel(am_pos_in)`
        //        ⇒ ⭐ 松手时行程已落到阈下 ⇒ ⭐ **恒为 `VEL_DEFAULT = 200`**
        //        ⇒ 🔴 所以"终点力度"**只能**靠 `live_vel_valid_i`（`vu_*`）那条流记下来 ✅
        //     📌 这正是 `looper.v` 里 `rec_vel_w`（`note_off` 取 `last_vel_r`）存在的理由
        //        ⇒ ⭐ **判据⑤因此非空洞**：⭐ 若 looper 直接用事件自带的力度 ⇒ 🔴 必红 ✅
        live_evt(KIND_OFF, 4'd1, INC_A, V_OFF_EVT);
        mg_off_live_seen = 0;
        cap_en = 1'b1; cap_sel = 0; cap_cnt = 0;   // ⭐ 开始采【现场】拖尾
        live_off_seen = 1;
        idle_ticks(LOOP_TICKS - OFF_TICK);         // ⭐ 录到第 250 tick
        @(negedge clk); stop_req_i = 1'b1; @(negedge clk); stop_req_i = 1'b0;
        repeat (40) @(negedge clk);

        chk("C0 setup: the layer stored exactly note_on + note_off (2 events)",
            lp_evt_cnt == 16'd2);

        //  ⭐⭐ **录制之后把键盘音色切到 BASS**（⭐ 模拟"录完 PAD 又切了音色"）——
        //     ⇒ ⭐ 回放**必须**用录制时记下的 PAD(3)，⛔ 不许跟当前键盘音色走 ✅
        //     ⇒ ⭐ 判据④因此**非空洞**：⭐ 若回放跟随 `default_timbre_i` ⇒ 🔴 必红 ✅
        kb_timbre = TBR_BASS;

        // ══════════════════════════════════════════════════════════════════
        //  ② 等【现场】的拖尾彻底衰完 ⇒ ⭐ 回放期的电平测量**无残留**
        //     ⭐ 顺带证明"现场的拖尾确实很长"（⭐ 判据⑥的定量口径）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 2: wait for the LIVE tail to decay completely ==");
        wait_samples(25000);
        lv_max_after = max_level();
        chk("C6 non-vacuity: the LIVE PAD tail is really long (start level >= 25000 => ~0.5 s+)",
            cap_lv[0][16] >= 25000);
        chk("C6b the LIVE tail fully decayed before the replay (clean measurement)",
            lv_max_after == 0);

        // ══════════════════════════════════════════════════════════════════
        //  ③ 回放：⭐ 量【回放】的拖尾
        // ══════════════════════════════════════════════════════════════════
        $display("== 3: replay the loop and measure the replayed tail ==");
        rep_on_seen = 0; rep_off_seen = 0;
        play_en_i = 1'b1;
        repeat (4) @(negedge clk);
        idle_ticks(OFF_TICK);                      // ⭐ 走到 loop 的松手 tick
        cap_en = 1'b1; cap_sel = 1; cap_cnt = 0;   // ⭐ 开始采【回放】拖尾
        idle_ticks(100);                           // ⭐ 采满 256 采样拍（⭐ ≈ 10 tick）
        play_en_i = 1'b0;
        repeat (60) @(negedge clk);

        // ── ⭐ 判据 ─────────────────────────────────────────────────────────
        slope_live = cap_lv[0][16] - cap_lv[0][CAP_N-1];
        slope_rep  = cap_lv[1][16] - cap_lv[1][CAP_N-1];

        $display("     [dbg] live: lv[0]=%0d lv[16]=%0d lv[64]=%0d lv[128]=%0d lv[255]=%0d slope=%0d tbr=%0d",
                 cap_lv[0][0], cap_lv[0][16], cap_lv[0][64], cap_lv[0][128], cap_lv[0][CAP_N-1],
                 slope_live, cap_tbr[0]);
        $display("     [dbg] rep : lv[0]=%0d lv[16]=%0d lv[64]=%0d lv[128]=%0d lv[255]=%0d slope=%0d tbr=%0d",
                 cap_lv[1][0], cap_lv[1][16], cap_lv[1][64], cap_lv[1][128], cap_lv[1][CAP_N-1],
                 slope_rep, cap_tbr[1]);
        $display("     [dbg] rep: on_seen=%0d on_vel=%0d on_tbr=%0d off_seen=%0d off_vel=%0d",
                 rep_on_seen, rep_on_vel, rep_on_tbr, rep_off_seen, rep_off_vel);

        //  ① 现场斜率 = 1 电平/采样拍（⭐ PAD 的 `release_for_timbre(3) = 1`）✅
        chk("C1 the LIVE PAD release slope is 1 level/sample tick (the long per-timbre tail)",
            (slope_live >= (CAP_N-1-16-2)) && (slope_live <= (CAP_N-1-16+2)));

        //  ② 回放斜率必须与现场【相同】⇒ ⭐ 音色（release 步长）没被搞错 ✅
        chk("C2 the REPLAYED release slope is IDENTICAL to the live one (same timbre step)",
            (slope_rep >= slope_live - 2) && (slope_rep <= slope_live + 2));

        //  ③ release 起始电平一致（±2%）⇒ ⭐ 拖尾【时长】一致 ✅
        k16_ok   = (cap_lv[1][16]  >= cap_lv[0][16]  - cap_lv[0][16]/50)  &&
                   (cap_lv[1][16]  <= cap_lv[0][16]  + cap_lv[0][16]/50);
        k64_ok   = (cap_lv[1][64]  >= cap_lv[0][64]  - cap_lv[0][64]/50)  &&
                   (cap_lv[1][64]  <= cap_lv[0][64]  + cap_lv[0][64]/50);
        k128_ok  = (cap_lv[1][128] >= cap_lv[0][128] - cap_lv[0][128]/50) &&
                   (cap_lv[1][128] <= cap_lv[0][128] + cap_lv[0][128]/50);
        k255_ok  = (cap_lv[1][CAP_N-1] >= cap_lv[0][CAP_N-1] - cap_lv[0][CAP_N-1]/50) &&
                   (cap_lv[1][CAP_N-1] <= cap_lv[0][CAP_N-1] + cap_lv[0][CAP_N-1]/50);
        chk("C3 the REPLAYED release starts at the SAME level as live (same tail length)",
            k16_ok && k64_ok && k128_ok && k255_ok);

        //  ④ 回放的 voice 音色 = 录制的 PAD(3)，⛔ 不是**当前**键盘音色 BASS(0) ✅
        chk("C4 the REPLAYED voice uses the RECORDED timbre PAD(3), not the current key timbre BASS(0)",
            (cap_tbr[1] === TBR_PAD) && (kb_timbre === TBR_BASS));

        //  ⑤ 回放的 `note_off` 带的是【录到的终点力度】(V_END)，⛔ 不是起音力度(V_ON) ✅
        chk("C5 the replayed note_off carries the recorded END velocity (120), not the onset (20)",
            (rep_off_seen >= 1) && (rep_off_vel == V_END) && (rep_on_vel == V_ON));

        if (errors == 0)
            $display("PASS: looper replay keeps the SAME per-timbre release tail as the live note");
        else
            $display("FAIL: looper replay tail -- %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: looper replay tail tb timeout");
        $finish;
    end

endmodule
