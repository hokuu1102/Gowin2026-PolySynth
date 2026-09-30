`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_score_looper_coexist.sv · 「曲谱 UART 与 looper **同时可用**」的验收 tb
//   —— 2026-09-30 新增（⭐ 用户需求：⭐ 两个都要）
//
// ── 🔴 它验的是【新接线】，⛔ 不是新模块 ──────────────────────────────────────
//   ⭐ 改动：⭐ looper 的重放**不再与曲谱 UART 抢 `seq_arb` 的 `score` 口**，
//      改走 `evt_merge` 的**第三个输入（源 C）**，⭐ 带**自己的来源标签 `3'd4`** ✅
//   ⇒ ⭐ 本 tb 例化**真实的三级链**：⭐ `seq_arb → evt_merge → note_manager`
//      ＋ ⭐ **真实的 `looper`**（⭐ 真录、真放）⇒ ⭐ **端到端** ✅
//   📌 **为什么不直接把 `c_*` 打拍子**：⭐ 那样只验 `evt_merge` 的接口，
//      ⚠️ 验不到"**looper 的产出真的接到了那条通路上**"（⭐ 那正是本次改动的本体）✅
//
// ── ⭐ 判据（⭐ 全部【能失败】；⭐ 名字纯 ASCII 且 ≤ 128 字节）──────────────────
//   ① `score_and_loop_same_axis_coexist`
//        ⭐ 同一条轴上：⭐ 曲谱一个音 ＋ looper 回放一个音 **同时存在**
//        （⚠️ 不是"先后响"——⭐ 必须是**两个不同的 voice 同时在 gate=1**）
//   ② `score_note_off_keeps_loop_voice`
//        ⭐ 曲谱的 `note_off` **⛔ 不许**清掉同轴 looper 的 voice
//   ③ `loop_note_off_keeps_score_voice`
//        ⭐ looper 的 `note_off` **⛔ 不许**清掉同轴曲谱的 voice
//   ④ `score_path_unchanged_when_looper_empty`
//        ⭐ looper 空（`cnt_r = 0`）时，⭐ 曲谱通路**行为不变**
//        （⭐ 起音占 **1** 个 voice、⭐ 收音**放掉** ⇒ ⭐ 无回归）
//   ⑤ `loop_interp_update_reaches_loop_voice`
//        ⭐ looper 的**插值更新**（⭐ 参数通路，⭐ 源标签也是 `3'd4`）
//          ⭐ 必须打到 **looper 自己的 voice**（⭐ 力度从起音值往上爬）
//          ⭐ 且⛔ **不许**改同轴**曲谱** voice 的力度
//        🔴 **这一条守的是"事件源标签与更新源标签必须成对"** ——
//           ⚠️ 只改事件标签（源 C）而漏改 `vel_upd_src_i` ⇒
//           🔴 回放的插值会去改**曲谱**的 voice，⭐ 而**自己的一个都收不到**
//           （⭐ 症状 = 用户报过的"loop 的声音比键盘小 / 没有 release 尾音"）✅
//
// ── ⭐⭐ 非空洞性（RED / GREEN 双跑，⭐ 两次输出都留档）────────────────────────
//   ⭐ 编译期宏 `TB_FORCE_SHARED_SRC`：
//      · ⭐ **不加**（默认）⇒ 源 C 的标签 = `3'd4`（**真**隔离）
//        ⇒ ⭐ 判据 ①②③⑤ **GREEN** ✅
//      · ⭐ **加 `-DTB_FORCE_SHARED_SRC`** ⇒ 源 C 的标签 = `3'd1`（**故意**与曲谱同源）
//        ⇒ ⭐ 判据 ①②③ **RED**（⭐ 判据 ④ 不受影响 —— ⭐ 它本来就是"无回归"基线）✅
//   📌 命令见文件尾注释；⭐ 判据 ④ 在两次跑里都应 **GREEN**（⭐ 它是"没被改坏"的证据）✅
//
// ── ⛔ 纪律 ──────────────────────────────────────────────────────────────────
//   · ⭐ **观测寄存器输出，采样点必须在时钟沿【之后】**（⭐ `tb_evt_merge` 坑 (a)）
//   · ⭐ **驱动激励在沿【之前】设好**（⭐ 坑 (b)）；⭐ `integer` 初值是 `x`（⭐ 坑 (c)）
//   · ⭐ **每个 PPQN tick 之间 ≥3 拍**（⭐ `tb_looper` 实测：⭐ 2 拍会让 DUT 被拖后）
// ─────────────────────────────────────────────────────────────────────────────

module tb_score_looper_coexist;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer KIND_W  = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer TICK_W  = 20;
    localparam integer POLY    = 8;
    localparam integer IDX_W   = 3;

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;

    //  ⭐⭐ 源标签（⭐ 必须与 `rtl/w3c/seq_arb.v` 的编码表一致）
    localparam [2:0] SRC_LIVE   = 3'd0;
    localparam [2:0] SRC_SCORE  = 3'd1;
    localparam [2:0] SRC_DRUM   = 3'd3;
    localparam [2:0] SRC_LOOPER = 3'd4;

    //  ⭐⭐ **非空洞性开关**（⭐ 见文件头）—— ⭐ 用宏而⛔ 不用 `-P`：
    //     ⚠️ 宏的生效**一眼可查**（⭐ 判据红了就是生效了），⭐ 而 `-P` 拼错时
    //        会**静默不生效** ⇒ 🔴 得到一份"看起来是 RED 其实是 GREEN"的假证据 ✅
`ifdef TB_FORCE_SHARED_SRC
    localparam [2:0] C_SRC = SRC_SCORE;    // 🔴 故意破坏隔离（⭐ 非空洞性）
`else
    localparam [2:0] C_SRC = SRC_LOOPER;   // ⭐ 正确：⭐ looper 有自己的标签
`endif

    //  ⭐ 曲谱与 looper **共用这一条轴**（⭐ 判据要求"同轴"）
    localparam [AXIS_W-1:0]  AX  = 4'd3;
    localparam [PHASE_W-1:0] INC = 32'h0012_0000;

    integer errors = 0;
    integer pass_n = 0;

    task automatic chk;
        input          cond;
        input [1023:0] msg;
        begin
            if (cond) begin
                pass_n = pass_n + 1;
                $display("  ok  : %0s", msg);
            end else begin
                errors = errors + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz
    reg rst_n = 1'b0;

    //  ⭐ `note_manager` 的 (d)/(e) 段要 `sample_tick`（⭐ 每 4 拍一个）
    reg [1:0] stc = 2'd0;
    reg       sample_tick = 1'b0;
    always @(posedge clk) begin
        stc         <= stc + 2'd1;
        sample_tick <= (stc == 2'd3);
    end

    // ══════════════════════════════════════════════════════════════════════
    //  ① 曲谱源（⭐ `seq_arb.score` 口 —— ⭐ 本 tb 只驱动这一路）
    // ══════════════════════════════════════════════════════════════════════
    reg                sc_valid = 1'b0;
    reg  [AXIS_W-1:0]  sc_axis  = 4'd0;
    reg  [PHASE_W-1:0] sc_inc   = 32'd0;
    reg  [VEL_W-1:0]   sc_vel   = 8'd0;
    reg  [KIND_W-1:0]  sc_kind  = 2'd0;
    reg                sc_tv    = 1'b0;
    reg  [TIMBRE_W-1:0] sc_tb   = 2'd0;

    //  ⭐ 手弹源（⭐ 只给 looper 当"录制素材"；⭐ 同时也进 `seq_arb.live` ——
    //     ⭐ 与 `top.v` **一致**：⭐ looper 是**旁路监听**手弹流 ✅）
    reg                lv_valid = 1'b0;
    reg  [AXIS_W-1:0]  lv_axis  = 4'd0;
    reg  [PHASE_W-1:0] lv_inc   = 32'd0;
    reg  [VEL_W-1:0]   lv_vel   = 8'd0;
    reg  [KIND_W-1:0]  lv_kind  = 2'd0;
    reg  [TIMBRE_W-1:0] lv_tbr  = 2'd0;
    reg                lvv_valid = 1'b0;
    reg  [AXIS_W-1:0]  lvv_axis  = 4'd0;
    reg  [VEL_W-1:0]   lvv_val   = 8'd0;

    // ══════════════════════════════════════════════════════════════════════
    //  ② `seq_arb`（源 A 三级仲裁 —— ⭐ 语义**未改**，⭐ 只是标签加宽）
    // ══════════════════════════════════════════════════════════════════════
    wire               sa_valid;
    wire [AXIS_W-1:0]  sa_axis;
    wire [PHASE_W-1:0] sa_inc;
    wire [VEL_W-1:0]   sa_vel;
    wire [KIND_W-1:0]  sa_kind;
    wire               sa_tv;
    wire [TIMBRE_W-1:0] sa_tb;
    wire [2:0]         sa_src;

    seq_arb #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(6)
    ) u_seq_arb (
        .clk_i(clk), .rst_n_i(rst_n),
        .live_valid_i(lv_valid), .live_axis_i(lv_axis),
        .live_phase_inc_i(lv_inc), .live_velocity_i(lv_vel),
        .live_kind_i(lv_kind), .live_timbre_valid_i(1'b0),
        .live_timbre_i({TIMBRE_W{1'b0}}),
        .score_valid_i(sc_valid), .score_axis_i(sc_axis),
        .score_phase_inc_i(sc_inc), .score_velocity_i(sc_vel),
        .score_kind_i(sc_kind), .score_timbre_valid_i(sc_tv),
        .score_timbre_i(sc_tb),
        .demo_valid_i(1'b0), .demo_axis_i({AXIS_W{1'b0}}),
        .demo_phase_inc_i({PHASE_W{1'b0}}), .demo_velocity_i({VEL_W{1'b0}}),
        .demo_kind_i({KIND_W{1'b0}}), .demo_timbre_valid_i(1'b0),
        .demo_timbre_i({TIMBRE_W{1'b0}}),
        .evt_valid_o(sa_valid), .evt_axis_o(sa_axis), .evt_phase_inc_o(sa_inc),
        .evt_velocity_o(sa_vel), .evt_kind_o(sa_kind),
        .evt_timbre_valid_o(sa_tv), .evt_timbre_o(sa_tb),
        .evt_src_o(sa_src),
        .collision_cnt_o(), .merged_cnt_o(), .drop_cnt_o(), .overflow_o(),
        .live_cnt_o(), .score_cnt_o(), .demo_cnt_o()
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ③ `looper`（⭐ 真录真放 —— ⭐ 重放出口接 `evt_merge` 的**源 C**）
    // ══════════════════════════════════════════════════════════════════════
    reg              tick_i     = 1'b0;
    reg [TICK_W-1:0] tick_cnt_i = {TICK_W{1'b0}};
    reg              bar_start_i = 1'b0;
    reg              transport_i = 1'b0;
    reg  [0:0]       rec_req_i = 1'b0;
    reg  [0:0]       stop_req_i = 1'b0;
    reg  [0:0]       play_en_i = 1'b0;
    reg  [0:0]       clear_req_i = 1'b0;

    wire               lp_valid;
    wire [AXIS_W-1:0]  lp_axis;
    wire [PHASE_W-1:0] lp_inc;
    wire [VEL_W-1:0]   lp_vel;
    wire [KIND_W-1:0]  lp_kind;
    wire [TIMBRE_W-1:0] lp_tbr;
    wire               lp_tbr_v;
    wire               lp_upd_valid;
    wire [AXIS_W-1:0]  lp_upd_axis;
    wire [PHASE_W-1:0] lp_upd_inc;
    wire [VEL_W-1:0]   lp_upd_vel;
    wire [0:0]         lp_layer_state;
    wire [15:0]        lp_evt_cnt;
    wire [0:0]         lp_full;
    wire [15:0]        lp_drop_cnt;
    wire               lp_overflow;

    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .TICK_W(TICK_W), .LAYERS(1),
        .EVT_MAX(64), .CNT_W(16)
    ) u_looper (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .live_valid_i(lv_valid), .live_axis_i(lv_axis),
        .live_inc_i(lv_inc), .live_vel_i(lv_vel), .live_kind_i(lv_kind),
        .live_timbre_i(lv_tbr),
        .live_vel_valid_i(lvv_valid), .live_vel_axis_i(lvv_axis),
        .live_vel_value_i(lvv_val),
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
    //  ④ `evt_merge`（⭐ A = `seq_arb` / ⭐ B = 节拍器·鼓机（本 tb 不用）/
    //                  ⭐⭐ C = **looper 回放** ← ⭐ 本次改动的本体）
    // ══════════════════════════════════════════════════════════════════════
    wire               mg_valid;
    wire [AXIS_W-1:0]  mg_axis;
    wire [PHASE_W-1:0] mg_inc;
    wire [VEL_W-1:0]   mg_vel;
    wire [KIND_W-1:0]  mg_kind;
    wire               mg_tv;
    wire [TIMBRE_W-1:0] mg_tb;
    wire [2:0]         mg_src;
    wire [15:0]        mg_coll, mg_merged, mg_drop;
    wire               mg_ovf;

    evt_merge #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .KIND_W(KIND_W), .TIMBRE_W(TIMBRE_W), .DEPTH(6)
    ) u_evt_merge (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(sa_valid), .a_axis_i(sa_axis), .a_phase_inc_i(sa_inc),
        .a_velocity_i(sa_vel), .a_kind_i(sa_kind),
        .a_timbre_valid_i(sa_tv), .a_timbre_i(sa_tb),
        .a_src_i(sa_src),
        //  ⭐ 源 B（节拍器/鼓机）本 tb 不用 ⇒ ⭐ 显式接常量（⛔ 不留 z）
        .b_valid_i(1'b0), .b_axis_i({AXIS_W{1'b0}}),
        .b_phase_inc_i({PHASE_W{1'b0}}), .b_velocity_i({VEL_W{1'b0}}),
        .b_kind_i({KIND_W{1'b0}}), .b_timbre_valid_i(1'b0),
        .b_timbre_i({TIMBRE_W{1'b0}}),
        .b_src_i(SRC_DRUM),
        //  ⭐⭐ 源 C = looper 回放（⭐ `C_SRC` 由非空洞性开关决定）✅
        .c_valid_i(lp_valid), .c_axis_i(lp_axis), .c_phase_inc_i(lp_inc),
        .c_velocity_i(lp_vel), .c_kind_i(lp_kind),
        .c_timbre_valid_i(lp_tbr_v), .c_timbre_i(lp_tbr),
        .c_src_i(C_SRC),
        .evt_valid_o(mg_valid), .evt_axis_o(mg_axis), .evt_phase_inc_o(mg_inc),
        .evt_velocity_o(mg_vel), .evt_kind_o(mg_kind),
        .evt_timbre_valid_o(mg_tv), .evt_timbre_o(mg_tb),
        .evt_src_o(mg_src),
        .collision_cnt_o(mg_coll), .merged_cnt_o(mg_merged),
        .drop_cnt_o(mg_drop), .overflow_o(mg_ovf)
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ⑤ `note_manager`（⭐ 唯一的"事件消费者" ⇒ ⭐ 隔离就在这里生效）
    // ══════════════════════════════════════════════════════════════════════
    wire [POLY-1:0]        gate_bus;
    wire [POLY-1:0]        act_bus;
    wire [POLY*AXIS_W-1:0] axis_bus;
    wire [POLY*VEL_W-1:0]  vel_bus;
    wire                   nm_alloc_valid;
    wire [IDX_W-1:0]       nm_alloc_voice;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(16), .AGE_W(16),
        .RESERVED_N(0), .FIFO_DEPTH(32), .IDX_W(IDX_W)
    ) u_note_manager (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(mg_valid), .note_axis_i(mg_axis),
        .note_phase_inc_i(mg_inc), .note_velocity_i(mg_vel),
        .note_kind_i(mg_kind), .note_src_i(mg_src),
        //  ⭐⭐ 更新通路：⭐ 只有 looper 会发（⭐ 手弹的 `vu_*` 本 tb 不接）
        //     ⇒ ⭐ **源标签恒为 `3'd4`** —— ⭐ 与 `top.v` 里 `vu_valid_r = 0` 那一档等价 ✅
        //     🔴 **判据 ⑤ 就是守这一行**：⭐ 它必须与事件标签（`C_SRC`）**成对** ✅
        .vel_upd_valid_i(lp_upd_valid), .vel_upd_axis_i(lp_upd_axis),
        .vel_upd_value_i(lp_upd_vel), .vel_upd_src_i(SRC_LOOPER),
        .pitch_upd_valid_i(lp_upd_valid), .pitch_upd_axis_i(lp_upd_axis),
        .pitch_upd_value_i(lp_upd_inc), .pitch_upd_src_i(SRC_LOOPER),
        .default_timbre_i({TIMBRE_W{1'b0}}),
        .evt_timbre_valid_i(mg_tv), .evt_timbre_i(mg_tb),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*16){1'b0}}),
        .voice_gate_o(gate_bus), .voice_active_o(act_bus),
        .voice_releasing_o(), .voice_axis_o(axis_bus),
        .voice_phase_inc_o(), .voice_velocity_o(vel_bus),
        .voice_timbre_o(), .voice_drum_o(), .voice_age_o(),
        .voice_retrig_reset_o(),
        .alloc_valid_o(nm_alloc_valid), .alloc_voice_o(nm_alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ── ⭐ 观测助手（⭐ 组合读，⛔ 不加寄存器）──────────────────────────────
    function integer cnt_on_axis;
        input [AXIS_W-1:0] ax;
        integer k;
        begin
            cnt_on_axis = 0;
            for (k = 0; k < POLY; k = k + 1)
                if (gate_bus[k] && (axis_bus[k*AXIS_W +: AXIS_W] == ax))
                    cnt_on_axis = cnt_on_axis + 1;
        end
    endfunction

    function [VEL_W-1:0] vel_of;
        input integer idx;
        begin
            vel_of = vel_bus[idx*VEL_W +: VEL_W];
        end
    endfunction

    // ── ⭐ 分配监视：⭐ 记下**每次分配的 voice 索引** ────────────────────────
    //   🔴 **为什么需要它**：⭐ "曲谱的 voice"与"looper 的 voice"**轴号相同**
    //      ⇒ ⚠️ 只数个数**分不出谁是谁**（⭐ 那样判据 ②③ 就退化成"数了个数"）✅
    //   📌 ⭐ 采样在 `negedge`（⭐ `tb_evt_merge` 坑 (a)：⭐ 沿之后才看得见寄存器输出）✅
    integer         n_alloc = 0;
    reg [IDX_W-1:0] alloc_hist [0:63];
    always @(negedge clk) begin
        if (rst_n && nm_alloc_valid && (n_alloc < 64)) begin
            alloc_hist[n_alloc] = nm_alloc_voice;
            n_alloc = n_alloc + 1;
        end
    end

    // ── ⭐ looper 重放边沿的 sticky 标志（⭐ 判据 ①③ 要"等它来"）──────────
    reg lp_on_seen  = 1'b0;
    reg lp_off_seen = 1'b0;
    always @(negedge clk) begin
        if (rst_n && lp_valid && (lp_kind == KIND_ON))  lp_on_seen  <= 1'b1;
        if (rst_n && lp_valid && (lp_kind == KIND_OFF)) lp_off_seen <= 1'b1;
    end

    // ── ⭐ 驱动小任务 ──────────────────────────────────────────────────────
    //   ⚠️ **每个 PPQN tick 之间 12 拍**（⭐ `tb_looper` 实测：⭐ 2 拍会让 DUT 被拖后 ⇒
    //      ⭐ 偏移漂移、⭐ 同拍和弦被拆开）✅
    localparam integer TICK_GAP = 12;

    task automatic do_tick;
        integer g;
        begin
            @(negedge clk);
            tick_i = 1'b1;
            @(negedge clk);
            tick_i = 1'b0;
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

    task automatic wait_clk;
        input integer n;
        integer w;
        begin
            for (w = 0; w < n; w = w + 1) @(negedge clk);
        end
    endtask

    //  ⭐ 一条**手弹**事件（⭐ 同时喂 `seq_arb.live` 与 `looper.live` —— ⭐ 与 `top.v` 一致）
    task automatic live_evt;
        input [KIND_W-1:0]  kd;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        begin
            @(negedge clk);
            lv_valid = 1'b1; lv_kind = kd; lv_axis = ax;
            lv_inc = inc;    lv_vel = vl;
            @(negedge clk);
            lv_valid = 1'b0;
        end
    endtask

    //  ⭐ 一条**手弹位置式力度**更新（⭐ 只喂 looper 的旁路监听端口 ——
    //     ⚠️ `top.v` 里它同时喂 `note_manager.vel_upd_*`，⭐ 本 tb 不接那一路
    //     （⭐ 那一路已由 `tb_vel_pos_follow` / `tb_note_manager` 覆盖）⇒ ⭐ 观测干净 ✅）
    task automatic live_vel_upd;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  vl;
        begin
            @(negedge clk);
            lvv_valid = 1'b1; lvv_axis = ax; lvv_val = vl;
            @(negedge clk);
            lvv_valid = 1'b0;
        end
    endtask

    //  ⭐ 一条**曲谱**事件（⭐ 走 `seq_arb.score` 口）
    task automatic score_evt;
        input [KIND_W-1:0] kd;
        input [VEL_W-1:0]  vl;
        begin
            @(negedge clk);
            sc_valid = 1'b1; sc_kind = kd; sc_axis = AX;
            sc_inc = INC; sc_vel = vl;
            sc_tv = 1'b0; sc_tb = {TIMBRE_W{1'b0}};
            @(negedge clk);
            sc_valid = 1'b0;
        end
    endtask

    task automatic pulse_rec;
        begin @(negedge clk); rec_req_i  = 1'b1; @(negedge clk); rec_req_i  = 1'b0; end
    endtask
    task automatic pulse_stop;
        begin @(negedge clk); stop_req_i = 1'b1; @(negedge clk); stop_req_i = 1'b0; end
    endtask

    //  ⭐ 等"轴 ax 上在响的 voice 数 == n"（⭐ **有上限** ⇒ ⛔ 不会挂死，⭐ `K-94`）
    //   🔴🔴 **每一轮必须 `do_tick`（⛔ 不是只等时钟）** —— ⭐ 本 tb 第一版**踩过**：
    //      ⭐ 回放的推进**完全靠 PPQN tick**（⭐ `play_tick_r` 只在 tick 上走）
    //      ⇒ ⚠️ 若等待循环只 `@(negedge clk)` ⇒ 🔴 **tick 一个都不发** ⇒
    //         ⭐ `play_tick_r` 卡在 0 ⇒ **回放一条事件都不吐**
    //      ⇒ 🔴 现象：⭐ 判据 ①③⑤ 全红，⭐ 而**看起来像"新接线没生效"**（⭐ 极误导）
    //      📌 **教训**：⭐ 在"等 looper 输出"的循环里，⭐ **必须由循环本身供 tick** ✅
    task automatic wait_cnt;
        input  [AXIS_W-1:0] ax;
        input  integer      n;
        input  integer      maxticks;
        output integer      got;
        integer w;
        reg     done;
        begin
            got = 0; done = 1'b0; w = 0;
            while ((w < maxticks) && !done) begin
                do_tick;
                if (cnt_on_axis(ax) == n) begin got = 1; done = 1'b1; end
                w = w + 1;
            end
        end
    endtask

    //  ⭐ 等 looper 重放的某个边沿（⭐ `which`：1 = `note_on` · 2 = `note_off`）
    //   ⚠️ 同样**每一轮 `do_tick`**（⭐ 理由见 `wait_cnt`）✅
    task automatic wait_lp_edge;
        input  integer which;
        input  integer maxticks;
        output integer got;
        integer w;
        reg     done;
        begin
            got = 0; done = 1'b0; w = 0;
            while ((w < maxticks) && !done) begin
                do_tick;
                if ((which == 1) && lp_on_seen)  begin got = 1; done = 1'b1; end
                if ((which == 2) && lp_off_seen) begin got = 1; done = 1'b1; end
                w = w + 1;
            end
        end
    endtask

    // ── 临时量（⭐ Verilog-2001：⭐ 具名 `begin/end` 块**不是**声明作用域）────
    integer ok, ok1, ok2, ok4a, ok4b, ok5;
    integer v_loop, v_score, v_score2;
    integer w;
    integer max_vel;
    reg [VEL_W-1:0] vtmp;

    initial begin
        $dumpfile("build/sim/tb_score_looper_coexist/tb_score_looper_coexist.vcd");
        $dumpvars(0, tb_score_looper_coexist);

        sc_valid = 1'b0; sc_axis = 4'd0; sc_inc = 32'd0; sc_vel = 8'd0;
        sc_kind = KIND_ON; sc_tv = 1'b0; sc_tb = 2'd0;
        lv_valid = 1'b0; lv_axis = 4'd0; lv_inc = 32'd0; lv_vel = 8'd0;
        lv_kind = KIND_ON; lv_tbr = 2'd0;
        lvv_valid = 1'b0; lvv_axis = 4'd0; lvv_val = 8'd0;
        tick_i = 1'b0; tick_cnt_i = {TICK_W{1'b0}}; bar_start_i = 1'b0;
        transport_i = 1'b1;                 // ⭐ 重放要它（`looper.playing` 的条件之一）
        rec_req_i = 1'b0; stop_req_i = 1'b0; play_en_i = 1'b0; clear_req_i = 1'b0;
        v_loop = -1; v_score = -1; v_score2 = -1;

        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);

        // ══════════════════════════════════════════════════════════════════
        //  判据 ④：⭐ **looper 空**（还没录过）⇒ ⭐ 曲谱通路**行为不变**
        //     ⭐ 这是"无回归"基线 —— ⭐ 两次跑（GREEN / RED）**都必须过** ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== A: score path with an EMPTY looper ==");
        score_evt(KIND_ON, 8'd60);
        wait_cnt(AX, 1, 400, ok4a);
        chk(ok4a && (cnt_on_axis(AX) == 1),
            "score_path_unchanged_when_looper_empty: note_on allocates exactly ONE voice");

        score_evt(KIND_OFF, 8'd60);
        wait_cnt(AX, 0, 400, ok4b);
        chk(ok4b && (cnt_on_axis(AX) == 0),
            "score_path_unchanged_when_looper_empty: note_off releases it again");

        // ══════════════════════════════════════════════════════════════════
        //  ⭐ 录制：⭐ 轴 3 上一个音（⭐ 起音力度 100 ⇒ 端点力度 200）
        //     ⭐ `note_on` 记在 rec_tick 1、⭐ `note_off` 记在 rec_tick 60
        //     ⭐ 停录在 rec_tick ≈ 75 ⇒ `loop_len ≈ 75`
        //     ⇒ ⭐ 回放时：⭐ `note_on` 落在 play_tick 1、⭐ `note_off` 落在 play_tick 60
        //        · ⭐ **1 → 60 有 59 个 tick 的窗口** ⇒ ⭐ 够判据 ①②⑤ 全部做完 ✅
        //        · ⭐ **60 → 下一圈的 1 还有 16 个 tick** ⇒ ⭐ 判据 ③ 的收尾窗口够 ✅
        //     🔴 **为什么窗口要留这么宽**（⭐ 第一版踩过）：⭐ 每个"等待"循环都要
        //        推进 tick ⇒ ⚠️ 判据 ①②③⑤ 加起来会**吃掉 30 个 tick 左右**
        //        ⇒ ⭐ 窗口若只有 29 个 tick ⇒ 🔴 判据 ③ 会在**下一圈**才开始判
        //           （⭐ 甚至判在 `note_off` 之后 ⇒ ⭐ 假红）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== B: record one note on axis 3 (start vel 100 -> end vel 200) ==");
        pulse_rec;
        idle_ticks(1);
        live_evt(KIND_ON, AX, INC, 8'd100);        // ⭐ 记在 rec_tick 1
        idle_ticks(1);
        live_vel_upd(AX, 8'd200);                  // ⭐ 端点力度 = 200
        idle_ticks(58);                            // ⇒ rec_tick 60
        live_evt(KIND_OFF, AX, INC, 8'd200);       // ⭐ 记在 rec_tick 60
        idle_ticks(15);                            // ⇒ rec_tick 75
        pulse_stop;                                // ⇒ `loop_len ≈ 75`
        idle_ticks(2);

        chk(cnt_on_axis(AX) == 0,
            "recording leaves NO held voice behind (live note was closed)");
        chk(lp_evt_cnt >= 16'd2,
            "looper stored the note_on AND the note_off");

        // ══════════════════════════════════════════════════════════════════
        //  ⭐ 起播：⭐ 等 looper 吐出那条 `note_on`
        // ══════════════════════════════════════════════════════════════════
        $display("== C: start playback ==");
        lp_on_seen  = 1'b0;
        lp_off_seen = 1'b0;
        play_en_i = 1'b1;

        wait_lp_edge(1, 200, ok);
        chk(ok, "looper replay emits a note_on (source C is wired)");
        wait_cnt(AX, 1, 50, ok);
        //  ⭐ 多等一拍 ⇒ ⭐ 保证分配监视器已经把这次分配记进 `alloc_hist`（⭐ 见其说明）
        @(negedge clk);
        //  ⚠️ **必须判 `n_alloc > 0`** —— ⭐ 否则 `alloc_hist[-1]` 是**非法索引**
        //     （⭐ 在"没分配成功"的那一档会读到垃圾/报错，⛔ 不是干净的 FAIL）✅
        if (n_alloc > 0) v_loop = alloc_hist[n_alloc-1];
        else             v_loop = 0;
        chk(ok && (cnt_on_axis(AX) == 1),
            "looper replay alone holds exactly ONE voice on axis 3");

        // ══════════════════════════════════════════════════════════════════
        //  判据 ⑤：⭐ looper 的**插值更新**必须打到**它自己的 voice**
        //     ⭐ 观测：⭐ 它的力度从起音值 100 **往上爬**（⭐ 朝端点 200）
        //     🔴 若更新源标签与事件标签**不成对** ⇒ ⭐ 这条更新收不到
        //        ⇒ 🔴 力度**恒为 100** ⇒ ⭐ 判据 RED ✅
        //     ⚠️ **本循环同样要 `do_tick`**（⭐ 插值引擎是**每 tick** 扫一轮的）✅
        // ══════════════════════════════════════════════════════════════════
        max_vel = 0;
        for (w = 0; w < 8; w = w + 1) begin
            do_tick;
            vtmp = vel_of(v_loop);
            if (vtmp > max_vel) max_vel = vtmp;
        end
        chk((max_vel > 100),
            "loop_interp_update_reaches_loop_voice: its velocity climbs above the start value");

        // ══════════════════════════════════════════════════════════════════
        //  判据 ①：⭐ 曲谱 ＋ looper **同轴并存**
        // ══════════════════════════════════════════════════════════════════
        $display("== D: score note ON the SAME axis while the loop is playing ==");
        score_evt(KIND_ON, 8'd60);
        wait_cnt(AX, 2, 30, ok1);
        @(negedge clk);
        if (n_alloc > 0) v_score = alloc_hist[n_alloc-1];
        else             v_score = 0;
        chk(ok1 && (cnt_on_axis(AX) == 2) && (v_score != v_loop),
            "score_and_loop_same_axis_coexist: TWO distinct voices on axis 3");
        chk(ok1 && gate_bus[v_loop] && gate_bus[v_score],
            "score_and_loop_same_axis_coexist: BOTH are gated (audible)");

        // ══════════════════════════════════════════════════════════════════
        //  判据 ②：⭐ 曲谱的 `note_off` **⛔ 不许**清 looper 的 voice
        // ══════════════════════════════════════════════════════════════════
        $display("== E: score note OFF -- the loop's voice must survive ==");
        score_evt(KIND_OFF, 8'd60);
        idle_ticks(7);
        chk(gate_bus[v_loop] === 1'b1,
            "score_note_off_keeps_loop_voice: the loop's voice is STILL gated");
        chk(gate_bus[v_score] === 1'b0,
            "score_note_off_keeps_loop_voice: only the score's own voice was cleared");

        // ══════════════════════════════════════════════════════════════════
        //  判据 ③：⭐ looper 的 `note_off` **⛔ 不许**清曲谱的 voice
        // ══════════════════════════════════════════════════════════════════
        $display("== F: loop note OFF -- the score's voice must survive ==");
        lp_off_seen = 1'b0;                        // ⭐ 清 sticky（⭐ 本圈的 OFF 还没到）
        score_evt(KIND_ON, 8'd60);
        wait_cnt(AX, 2, 30, ok2);
        @(negedge clk);
        if (n_alloc > 0) v_score2 = alloc_hist[n_alloc-1];
        else             v_score2 = 0;
        chk(ok2 && (v_score2 != v_loop),
            "score voice re-allocated next to the loop's voice");

        wait_lp_edge(2, 200, ok);
        chk(ok, "looper replay emits a note_off");
        idle_ticks(7);
        chk(gate_bus[v_score2] === 1'b1,
            "loop_note_off_keeps_score_voice: the score's voice is STILL gated");
        chk(gate_bus[v_loop] === 1'b0,
            "loop_note_off_keeps_score_voice: only the loop's own voice was cleared");

        //  ⭐ 判据 ⑤ 的另一半：⭐ 曲谱 voice 的力度⛔ **不许**被 looper 的更新改
        chk(vel_of(v_score2) === 8'd60,
            "loop_interp_update_reaches_loop_voice: the score voice's velocity is untouched");

        //  ⭐ 收尾：⭐ **先停播**，⭐ 再放掉曲谱那条
        //     🔴 **为什么必须先停播**：⭐ 否则**下一圈**的 looper `note_on`
        //        （⭐ 轴 3）会在我"等 count==0"的窗口里**又占一个 voice**
        //        ⇒ 🔴 那条判据会**假红**（⭐ 与隔离性无关，⭐ 纯属测试自己的时序问题）✅
        //     📌 停播是安全的：⭐ `play_active_r` 此时已是 0（⭐ 那条 `note_off` 已重放过）
        //        ⇒ ⭐ 不会触发 `ST_LCLOSE` 的补发 ✅
        play_en_i = 1'b0;
        wait_clk(24);
        score_evt(KIND_OFF, 8'd60);
        wait_cnt(AX, 0, 30, ok);
        chk(ok, "final score note_off releases the last voice (no stuck voice)");

        // ══════════════════════════════════════════════════════════════════
        //  ⭐ 汇总
        // ══════════════════════════════════════════════════════════════════
        if (errors == 0)
            $display("PASS: score UART and looper coexist; source tags isolate note_off (ok=%0d)", pass_n);
        else
            $display("FAIL: tb_score_looper_coexist had %0d error(s) (ok=%0d)", errors, pass_n);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`：⭐ "没有结论"必须算失败）
    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_score_looper_coexist timeout");
    end

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 怎么跑（⭐ 两条命令，⭐ 输出都留档）：
    //    ① ⭐ **GREEN**（默认）：
    //       powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_score_looper_coexist
    //    ② ⭐ **RED**（非空洞性 —— ⭐ 故意让源 C 冒用曲谱的标签）：
    //       iverilog -g2012 -Wall -DTB_FORCE_SHARED_SRC -s tb_score_looper_coexist -o <...>.vvp <rtl...> <tb...>
    //       ⇒ ⭐ 判据 ①②③⑤ **必须变红**（⭐ 判据 ④ 仍绿）✅
    // ═══════════════════════════════════════════════════════════════════════
endmodule
