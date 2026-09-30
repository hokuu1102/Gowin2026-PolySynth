`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_looper_tail.sv · ⭐ **PAD 尾音：手弹 vs looper 回放**（⭐ 端到端测量 tb）
//
//  🔴 **它要回答的问题**（⭐ 用户上板报告）：
//     · ⭐ **手弹 PAD** ⇒ 松手后有**几百 ms 的尾音**
//     · 🔴 **looper 回放同一个音** ⇒ *"发出之后就立即释放了"*，⛔ 没有按音色的尾音
//
//  ⭐ **本 tb 的立场**：⛔ **不假设任何一条候选原因**（⭐ 本项目 `C83` / `0.11` 纪律）。
//     ⭐ 它把【手弹链】与【回放链】**并排搭出来**，⭐ 用**同一条 `pos` 行程曲线**跑两遍，
//     然后**打印**两边的：
//        · `note_on` 的力度 / 音色（⭐ 进包络的起点）
//        · **`note_off` 那一刻的包络电平**（⭐ `env_level`）＋ 该 voice 的 `vel_r` / `timbre_r`
//        · 从 `note_off` 到包络归零的**采样拍数**（= release 时长）
//        · ⭐ **looper 录到的"终点力度" `ep_vel`**（⭐ 与手弹的 `vel_r@off` 直接对比）
//     ⇒ ⭐ **第一处分歧**就是根因（⭐ 报告里给行号）。
//
//  ⭐ **`pos` 行程模型（⭐ 逐条照 `top.v` 的真实语义）**：
//     · `as_pos` **每个 ADC 帧（= 500 µs = 25 采样拍）更新一次**（⭐ 与 `axis_snapshot` 同拍）
//     · `vu_valid_r`：⭐ **每采样拍轮转一个轴（⭐ 16 轴，⭐ 2026-09-30 从 8 改）**，
//       ⭐ **只有 `pos > 64` 才发**
//       且 `vu_val = pos_to_vel(pos)`（⭐ `top.v` 的 `vu_*` **逐字同式**）
//     · `note_on`：⭐ 帧上 `pos > 64`（`TRIG_TH`）⇒ 力度 = `pos_to_vel(该帧 pos)`
//     · `note_off`：⭐ 帧上 `pos < 32`（`REL_TH`）⇒ 力度 = `200`（⭐ 与 `top.v:2701` 一致）
//     · `pos_to_vel(p) = 64 + (p*263)>>10`（⭐ `top.v:955-967` **逐字同式**）
//
//  ⚠️ **时基按比例缩小**（⭐ ⛔ 不改任何比值，⭐ 否则包络/斜坡的相对节奏会失真）：
//     · 真实：`sample_tick = 1024 clk`、`PPQN tick = 26000 clk` ⇒ **25.4 采样拍/tick**
//     · 本 tb：`sample_tick =    2 clk`、`PPQN tick =    50 clk` ⇒ **25   采样拍/tick** ✅
//     ⚠️ `CPS` **必须 ≥ 2** —— `note_manager` 的重触发清零写在 `if (!sample_tick_i)` 里
//        （⭐ `note_manager.v:869`）⇒ `CPS = 1` 会让它**永不触发**（⭐ 那是另一个 bug）
//
//  ⭐ **release 时长用【速率外推】**：⭐ `adsr.v` 的 release 是**每采样拍固定步长**
//     ⇒ ⭐ 电平**严格线性** ⇒ ⭐ `rel = env@off × N / (env@off − env@off+N)` 是**精确值** ✅
//
//  ⭐ 判据名**纯 ASCII 且 ≤ 128 字节**（⭐ 与 `tb_looper` 同一条纪律）
// ─────────────────────────────────────────────────────────────────────────────
`define MAXW 6_000_000

module tb_looper_tail;

    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer KIND_W   = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer TICK_W   = 20;
    localparam integer POLY     = 32;
    localparam integer ENV_W    = 16;

    localparam integer CPS       = 2;    // 每采样拍 clk 数（真实 1024）
    localparam integer TICK_GAP  = 50;   // 每 PPQN tick clk 数（真实 26000）
    localparam integer FRAME_SMP = 25;   // 每 ADC 帧采样拍数（真实 500 µs / 20.48 µs）
    localparam integer REL_WIN   = 2000; // ⭐ release 速率外推窗口（采样拍）

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;

    localparam [TIMBRE_W-1:0] TBR_PAD = 2'd3;   // ⭐ PAD
    localparam [11:0] TRIG_TH = 12'd64;         // ⭐ = `event_extract.TRIG_TH`
    localparam [11:0] REL_TH  = 12'd32;         // ⭐ = `event_extract.REL_TH`
    localparam [7:0]  VEL_DEFAULT = 8'd200;     // ⭐ = `top.v:2700`

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task automatic chk;
        input          cond;
        input [1023:0] msg;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", msg); end
            else      begin fail_cnt = fail_cnt + 1; $display("  FAIL: %0s", msg); end
        end
    endtask

    // ⭐ `top.v:955-967` 的映射函数（⭐ 逐字同式）
    function [7:0] pos_to_vel;
        input [11:0] p;
        reg   [21:0] p22, prod;
        reg   [12:0] v13;
        begin
            p22        = {10'd0, p};
            prod       = (p22 << 8) + (p22 << 3) - p22;   // ×263
            v13        = 13'd64 + prod[21:10];
            pos_to_vel = (v13 > 13'd255) ? 8'd255 : v13[7:0];
        end
    endfunction

    // ── 采样拍 ──────────────────────────────────────────────────────────────
    reg [15:0] sdiv = 16'd0;
    reg        sample_tick = 1'b0;
    always @(posedge clk) begin
        if (sdiv == CPS-1) begin sdiv <= 16'd0;         sample_tick <= 1'b1; end
        else               begin sdiv <= sdiv + 16'd1;  sample_tick <= 1'b0; end
    end

    // ── PPQN tick（⭐ 自由运行）───────────────────────────────────────────────
    integer          tdiv = 0;
    reg              tick_i      = 1'b0;
    reg [TICK_W-1:0] tick_cnt_i  = {TICK_W{1'b0}};
    reg              transport_i = 1'b0;
    always @(posedge clk) begin
        if (tdiv == TICK_GAP-1) begin
            tdiv <= 0; tick_i <= 1'b1; tick_cnt_i <= tick_cnt_i + 1'b1;
        end else begin
            tdiv <= tdiv + 1; tick_i <= 1'b0;
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // ⭐⭐ `pos` 行程模型 + `vu_*` 位置式力度流 + `event_extract` 事件生成
    // ══════════════════════════════════════════════════════════════════════
    //  ⚠️ `as_pos` 用 **12 位向量数组**（⛔ 不是 `integer` 数组）——
    //     🔴 因为要 `pos_to_vel(as_pos[x])`（⭐ 形参是 `[11:0]`）＋ 与 `TRIG_TH` 比较；
    //     ⭐ `integer` 做位选/部分选择是本项目 `K-91` 的雷区 ✅
    reg   [11:0] as_pos [0:15];        // ⭐ = `top.v` 的 `as_pos`（每 ADC 帧更新）
    integer      wf_ax, wf_P, wf_R, wf_H, wf_F;   // ⭐ 本场景的行程曲线参数（initial 驱动）
    reg [AXIS_W-1:0] wf_ax4;           // ⭐ 轴号（⛔ 不对 integer 做位选 —— `K-91`）
    reg          wf_go;                // ⭐ initial 置 1 ⇒ 帧状态机自己起跑
    reg          wf_go_d, wf_on_d;
    integer      wf_fr;                // ⭐ 帧计数（帧状态机驱动）
    reg          wf_on;                // ⭐ 曲线正在跑（帧状态机驱动）
    reg          wf_done;
    reg          pressed;              // ⭐ `event_extract` 的"键按住"状态（事件块驱动）

    reg               live_valid  = 1'b0;
    reg [AXIS_W-1:0]  live_axis   = 4'd0;
    reg [PHASE_W-1:0] live_inc    = 32'h1111_0000;
    reg [VEL_W-1:0]   live_vel    = 8'd0;
    reg [KIND_W-1:0]  live_kind   = KIND_ON;
    reg [TIMBRE_W-1:0]live_timbre = TBR_PAD;

    reg              vu_valid = 1'b0;
    reg [3:0]        vu_ax_r  = 4'd0;      // ⭐ 16 轴轮转（= `VEL_AXIS_N = 16`，⭐ 2026-09-30 从 8 改）
    reg [AXIS_W-1:0] vu_axis  = 4'd0;
    reg [VEL_W-1:0]  vu_val   = 8'd0;

    integer fi;
    integer frc;
    integer fcnt;

    // ⭐ 行程曲线：`pos_of(f)`（⭐ 分段线性）
    function integer pos_of;
        input integer f;
        begin
            if      (f < 0)              pos_of = 0;
            else if (f < wf_R)           pos_of = (wf_P * f) / wf_R;
            else if (f < (wf_R + wf_H))  pos_of = wf_P;
            else if (f < (wf_R+wf_H+wf_F))
                pos_of = (wf_P * (wf_R + wf_H + wf_F - f)) / wf_F;
            else                         pos_of = 0;
        end
    endfunction

    // ⭐ ADC 帧边界：更新 `as_pos`（⭐ 帧状态机**独占**这些状态 ⇒ ⛔ 无多驱动）
    always @(posedge clk) begin
        if (!rst_n) begin
            fcnt = 0; wf_fr = 0; wf_done = 1'b0; wf_on = 1'b0;
            for (fi = 0; fi < 16; fi = fi + 1) as_pos[fi] = 12'd0;
        end else begin
            wf_go_d <= wf_go;
            if (wf_go && !wf_go_d) begin
                // ⭐ 新场景起跑
                fcnt = 0; wf_fr = 0; wf_done = 1'b0; wf_on = 1'b1;
                for (fi = 0; fi < 16; fi = fi + 1) as_pos[fi] = 12'd0;
            end else if (sample_tick) begin
                if (fcnt == FRAME_SMP-1) begin
                    fcnt = 0;
                    if (wf_on) begin
                        as_pos[wf_ax] = pos_of(wf_fr);
                        wf_fr = wf_fr + 1;
                        //  ⚠️ **必须多跑 4 帧** —— 🔴 否则"曲线结束"与"`pos` 落到 0"同拍
                        //     ⇒ ⭐ 事件块看到 `wf_done` 就已经不再判释放
                        //     ⇒ 🔴 **`note_off` 永远不发**（⭐ 实测：tb 挂在 `wait(off_seen)`）
                        if (wf_fr > (wf_R + wf_H + wf_F + 4)) begin
                            wf_on = 1'b0; wf_done = 1'b1;
                        end
                    end
                end else begin
                    fcnt = fcnt + 1;
                end
            end
        end
    end

    // ⭐ 事件生成（⭐ = `event_extract` 的触发/释放判据 + `top.v:2701` 的起音力度）
    always @(posedge clk) begin
        live_valid <= 1'b0;
        wf_on_d    <= wf_on;
        if (!rst_n) begin
            pressed <= 1'b0;
        end else if (wf_on && !wf_on_d) begin
            pressed <= 1'b0;                 // ⭐ 新场景 ⇒ 键状态清零
        end else if (rst_n && wf_on && !wf_done) begin
            if (!pressed && (as_pos[wf_ax] > TRIG_TH)) begin
                pressed    <= 1'b1;
                live_valid <= 1'b1;
                live_kind  <= KIND_ON;
                live_axis  <= wf_ax4;
                live_inc   <= 32'h1111_0000;
                // ⭐ `w3a_evt_vel`（⭐ `top.v:2701`）
                live_vel   <= (as_pos[wf_ax] < TRIG_TH) ? VEL_DEFAULT
                                                        : pos_to_vel(as_pos[wf_ax]);
            end else if (pressed && (as_pos[wf_ax] < REL_TH)) begin
                pressed    <= 1'b0;
                live_valid <= 1'b1;
                live_kind  <= KIND_OFF;
                live_axis  <= wf_ax4;
                live_inc   <= 32'h1111_0000;
                // ⭐ 松手那一刻 `pos < TRIG_TH` ⇒ `w3a_evt_vel` = `VEL_DEFAULT`
                live_vel   <= VEL_DEFAULT;
            end
        end
    end

    // ⭐ `vu_*`：⭐ `top.v` 的 `vu_*` **逐字同式**（每采样拍轮转一个轴，`pos > 64` 才发）
    //     ⚠️ 2026-09-30：⭐ `VEL_AXIS_N` 8 → **16**（⭐ 左手板两块必须配置一致）⇒
    //        ⭐ 本模型同步改成 **16 轴**（⭐ 否则"逐字同式"这句话就是假的 ✅）
    always @(posedge clk) begin
        vu_valid <= 1'b0;
        if (rst_n && sample_tick) begin
            vu_ax_r <= vu_ax_r + 4'd1;
            if (as_pos[vu_ax_r] > 12'd64) begin
                vu_valid <= 1'b1;
                vu_axis  <= vu_ax_r;
                vu_val   <= pos_to_vel(as_pos[vu_ax_r]);
            end
        end
    end

    // ══ DUT ① · looper ══════════════════════════════════════════════════════
    reg  rec_req = 1'b0, stop_req = 1'b0, play_en = 1'b0, clear_req = 1'b0;
    wire        lp_play_valid;
    wire [AXIS_W-1:0]  lp_play_axis;
    wire [PHASE_W-1:0] lp_play_inc;
    wire [VEL_W-1:0]   lp_play_vel;
    wire [KIND_W-1:0]  lp_play_kind;
    wire [TIMBRE_W-1:0]lp_play_tbr;
    wire        lp_play_tbr_v;
    wire        lp_upd_valid;
    wire [AXIS_W-1:0]  lp_upd_axis;
    wire [PHASE_W-1:0] lp_upd_inc;
    wire [VEL_W-1:0]   lp_upd_vel;
    wire [0:0]  lp_state;
    wire [15:0] lp_cnt, lp_drop;
    wire [0:0]  lp_full;
    wire        lp_ovf;

    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .TICK_W(TICK_W), .LAYERS(1), .EVT_MAX(2048), .CNT_W(16)
    ) u_looper (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i), .bar_start_i(1'b0),
        .transport_i(transport_i),
        .live_valid_i(live_valid), .live_axis_i(live_axis), .live_inc_i(live_inc),
        .live_vel_i(live_vel), .live_kind_i(live_kind), .live_timbre_i(live_timbre),
        .live_vel_valid_i(vu_valid), .live_vel_axis_i(vu_axis), .live_vel_value_i(vu_val),
        .play_valid_o(lp_play_valid), .play_axis_o(lp_play_axis),
        .play_inc_o(lp_play_inc), .play_vel_o(lp_play_vel), .play_kind_o(lp_play_kind),
        .play_timbre_o(lp_play_tbr), .play_timbre_valid_o(lp_play_tbr_v),
        .play_upd_valid_o(lp_upd_valid), .play_upd_axis_o(lp_upd_axis),
        .play_upd_inc_o(lp_upd_inc), .play_upd_vel_o(lp_upd_vel),
        .rec_req_i(rec_req), .stop_req_i(stop_req), .play_en_i(play_en),
        .clear_req_i(clear_req),
        .layer_state_o(lp_state), .evt_cnt_flat_o(lp_cnt), .full_o(lp_full),
        .drop_cnt_o(lp_drop), .overflow_o(lp_ovf)
    );

    // ══ DUT ② · evt_merge（⭐ 源 A = 手弹 src 0 · 源 C = looper src 4）══════
    wire        mg_valid;
    wire [AXIS_W-1:0]  mg_axis;
    wire [PHASE_W-1:0] mg_inc;
    wire [VEL_W-1:0]   mg_vel;
    wire [KIND_W-1:0]  mg_kind;
    wire        mg_tbr_v;
    wire [TIMBRE_W-1:0]mg_tbr;
    wire [2:0]  mg_src;
    wire [15:0] mg_coll, mg_merged, mg_drop;
    wire        mg_ovf;

    evt_merge #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .DEPTH(4)
    ) u_merge (
        .clk_i(clk), .rst_n_i(rst_n),
        .a_valid_i(live_valid), .a_axis_i(live_axis), .a_phase_inc_i(live_inc),
        .a_velocity_i(live_vel), .a_kind_i(live_kind),
        .a_timbre_valid_i(1'b0), .a_timbre_i(2'd0), .a_src_i(3'd0),
        .b_valid_i(1'b0), .b_axis_i(4'd0), .b_phase_inc_i(32'd0),
        .b_velocity_i(8'd0), .b_kind_i(2'd0),
        .b_timbre_valid_i(1'b0), .b_timbre_i(2'd0), .b_src_i(3'd3),
        .c_valid_i(lp_play_valid), .c_axis_i(lp_play_axis), .c_phase_inc_i(lp_play_inc),
        .c_velocity_i(lp_play_vel), .c_kind_i(lp_play_kind),
        .c_timbre_valid_i(lp_play_tbr_v), .c_timbre_i(lp_play_tbr), .c_src_i(3'd4),
        .evt_valid_o(mg_valid), .evt_axis_o(mg_axis), .evt_phase_inc_o(mg_inc),
        .evt_velocity_o(mg_vel), .evt_kind_o(mg_kind),
        .evt_timbre_valid_o(mg_tbr_v), .evt_timbre_o(mg_tbr), .evt_src_o(mg_src),
        .collision_cnt_o(mg_coll), .merged_cnt_o(mg_merged),
        .drop_cnt_o(mg_drop), .overflow_o(mg_ovf)
    );

    // ══ DUT ③ · note_manager ═══════════════════════════════════════════════
    wire [POLY-1:0]         nm_gate, nm_active, nm_retrig, nm_drum;
    wire [POLY*AXIS_W-1:0]  nm_axis;
    wire [POLY*PHASE_W-1:0] nm_phase;
    wire [POLY*VEL_W-1:0]   nm_vel;
    wire [POLY*TIMBRE_W-1:0]nm_timbre;
    wire [POLY*16-1:0]      nm_age;
    wire [POLY*ENV_W-1:0]   env_level;
    wire [POLY-1:0]         env_active;
    wire                    nm_alloc_valid;
    wire [4:0]              nm_alloc_voice;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(4), .PHASE_W(32), .VEL_W(8),
        .TIMBRE_W(2), .ENV_W(16), .AGE_W(16), .RESERVED_N(5)
    ) u_nm (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(mg_valid), .note_axis_i(mg_axis),
        .note_phase_inc_i(mg_inc), .note_velocity_i(mg_vel),
        .note_kind_i(mg_kind), .note_src_i(mg_src),
        // ⭐ 与 `top.v:3290-3310` **逐字同式**（含 OR + mux + 源标签）
        .vel_upd_valid_i(vu_valid | lp_upd_valid),
        .vel_upd_axis_i (vu_valid ? vu_axis : lp_upd_axis),
        .vel_upd_value_i(vu_valid ? vu_val  : lp_upd_vel),
        .vel_upd_src_i  (vu_valid ? 3'd0    : 3'd4),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i(4'd0),
        .pitch_upd_value_i(32'd0), .pitch_upd_src_i(3'd0),
        .default_timbre_i(live_timbre),
        .evt_timbre_valid_i(mg_tbr_v), .evt_timbre_i(mg_tbr),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(nm_gate), .voice_active_o(nm_active), .voice_releasing_o(),
        .voice_axis_o(nm_axis), .voice_phase_inc_o(nm_phase),
        .voice_velocity_o(nm_vel), .voice_timbre_o(nm_timbre),
        .voice_drum_o(nm_drum), .voice_age_o(nm_age),
        .voice_retrig_reset_o(nm_retrig),
        .alloc_valid_o(nm_alloc_valid), .alloc_voice_o(nm_alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ══ DUT ④ · envelope_bank（⭐ `timbre_i` 接上 ⇒ 按音色取 A/D/R）══════════
    envelope_bank #(.POLY_TARGET(POLY), .VEL_W(8), .ENV_W(16)) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(nm_gate), .velocity_i(nm_vel), .retrig_reset_i(nm_retrig),
        .timbre_i(nm_timbre),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 测量（⭐ **按 voice 索引** —— ⛔ 不用"全体最大值"，⭐ 免得别的 voice 干扰）
    // ═══════════════════════════════════════════════════════════════════════
    integer gi;
    integer gated_n, gidx, last_gated_idx;
    integer prev_env, prev_vel, prev_tbr;
    reg     armed;
    integer rel_cnt;
    reg     rel_run;
    integer off_idx;
    integer env_at_off, vel_at_off, tbr_at_off, rel_ticks, rel_env_end;
    integer off_seen, on_seen;
    integer on_sample_cnt, off_sample_cnt, s_cnt;

    integer phase;                    // 1 = 手弹段 · 2 = 回放段
    integer live_env_off, live_vel_off, live_tbr_off, live_rel, live_on_s, live_off_s;
    integer rep_env_off,  rep_vel_off,  rep_tbr_off,  rep_rel,  rep_on_s,  rep_off_s;
    integer live_on_vel_evt, live_off_vel_evt;
    integer rep_on_vel_evt,  rep_off_vel_evt, rep_on_tbr_evt;
    integer upd_n, upd_last, upd_first;

    always @(posedge clk) begin
        if (rst_n && sample_tick) begin
            s_cnt = s_cnt + 1;
            gated_n = 0; gidx = -1;
            for (gi = 0; gi < POLY; gi = gi + 1)
                if (nm_gate[gi]) begin gated_n = gated_n + 1; gidx = gi; end
            if ((gated_n > 0) && !on_seen) begin
                on_seen = 1; on_sample_cnt = s_cnt;
            end
            if (gated_n > 0) begin
                prev_env = env_level[gidx*ENV_W +: ENV_W];
                prev_vel = nm_vel[gidx*VEL_W +: VEL_W];
                prev_tbr = nm_timbre[gidx*TIMBRE_W +: TIMBRE_W];
                last_gated_idx = gidx;
            end
            if (armed && (gated_n == 0) && (off_seen == 0)) begin
                env_at_off     = prev_env;
                vel_at_off     = prev_vel;
                tbr_at_off     = prev_tbr;
                off_idx        = last_gated_idx;
                off_sample_cnt = s_cnt;
                off_seen       = 1;
                armed          = 1'b0;
                rel_cnt        = 0;
                rel_run        = 1'b1;
            end
            if (rel_run) begin
                rel_env_end = env_level[off_idx*ENV_W +: ENV_W];
                if (rel_env_end == 0) begin
                    rel_ticks = rel_cnt; rel_run = 1'b0;
                end else if (rel_cnt >= REL_WIN) begin
                    rel_ticks = rel_cnt; rel_run = 1'b0;
                end else begin
                    rel_cnt = rel_cnt + 1;
                end
            end
        end
    end

    // ⭐ 事件字捕获（⭐ 按段分开 ⇒ 手弹段与回放段各自的"进包络的值"）
    always @(posedge clk) begin
        if (rst_n && mg_valid) begin
            if (phase == 1) begin
                if (mg_kind == KIND_ON) live_on_vel_evt  = mg_vel;
                else                    live_off_vel_evt = mg_vel;
            end else if (phase == 2) begin
                if (mg_kind == KIND_ON) begin
                    rep_on_vel_evt = mg_vel; rep_on_tbr_evt = mg_tbr;
                end else begin
                    rep_off_vel_evt = mg_vel;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && lp_upd_valid) begin
            if (upd_n == 0) upd_first = lp_upd_vel;
            upd_last = lp_upd_vel;
            upd_n    = upd_n + 1;
        end
    end

    task automatic pulse_rec;  begin @(negedge clk); rec_req  = 1'b1; @(negedge clk); rec_req  = 1'b0; end endtask
    task automatic pulse_stop; begin @(negedge clk); stop_req = 1'b1; @(negedge clk); stop_req = 1'b0; end endtask
    task automatic pulse_clr;  begin @(negedge clk); clear_req= 1'b1; @(negedge clk); clear_req= 1'b0; end endtask

    // ⭐ release 时长：⭐ 线性 ⇒ 速率外推（⭐ 见文件头）
    function integer rel_len;
        input integer env0;
        input integer envN;
        input integer n;
        begin
            if (env0 <= 0)        rel_len = 0;
            else if (envN == 0)   rel_len = n;
            else                  rel_len = (env0 * n) / (env0 - envN);
        end
    endfunction

    integer ep_vel_rec;      // ⭐ looper 录到的"终点力度"
    integer sc;
    integer ep_pct, min_env_pct, min_rel_pct;

    // ══════════════════════════════════════════════════════════════════════
    // ⭐ 一个场景：⭐ 用同一条 `pos` 曲线跑【手弹】与【回放】两遍，⭐ 打印对照
    // ══════════════════════════════════════════════════════════════════════
    task automatic run_scenario;
        input [AXIS_W-1:0] ax;
        input integer P;
        input integer R;
        input integer H;
        input integer F;
        input [1023:0] name;
        begin
            // ── 准备 ──────────────────────────────────────────────────────
            pulse_clr;
            repeat (20) @(negedge clk);
            wf_go = 1'b0;
            repeat (20) @(negedge clk);
            wf_ax = ax; wf_ax4 = ax;
            wf_P = P; wf_R = R; wf_H = H; wf_F = F;
            live_timbre = TBR_PAD;
            pulse_rec;
            repeat (20) @(negedge clk);

            // ── 段 A：手弹 ────────────────────────────────────────────────
            phase = 1;
            off_seen = 0; on_seen = 0; rel_run = 1'b0; rel_cnt = 0; armed = 1'b0;
            env_at_off = 0; vel_at_off = 0; tbr_at_off = 0; rel_ticks = 0; rel_env_end = 0;
            live_on_vel_evt = 0; live_off_vel_evt = 0;
            wf_go = 1'b1;                    // ⭐ 起跑行程曲线
            $display("     [prog] A start ax=%0d P=%0d R=%0d H=%0d F=%0d s=%0d", ax, P, R, H, F, s_cnt);
            wait (on_seen == 1);
            $display("     [prog] A note_on seen s=%0d pos0=%0d", s_cnt, as_pos[wf_ax]);
            armed = 1'b1;
            wait (off_seen == 1);
            $display("     [prog] A note_off seen s=%0d", s_cnt);
            live_env_off = env_at_off; live_vel_off = vel_at_off; live_tbr_off = tbr_at_off;
            live_on_s = on_sample_cnt; live_off_s = off_sample_cnt;
            wait (rel_run == 0);
            $display("     [prog] A release window done s=%0d", s_cnt);
            live_rel = rel_len(env_at_off, rel_env_end, rel_ticks);
            wait (wf_done == 1'b1);
            $display("     [prog] A waveform done s=%0d", s_cnt);
            wf_go = 1'b0;
            repeat (40) @(negedge clk);
            pulse_stop;
            repeat (400) @(negedge clk);
            // ⭐ 录到的终点力度（⭐ `ep_mem[0]` = 本遍唯一 `note_on` 的地址）
            ep_vel_rec = u_looper.ep_mem[0][u_looper.O_EPVE +: VEL_W];

            // ── 段 B：回放 ────────────────────────────────────────────────
            phase = 2;
            off_seen = 0; on_seen = 0; rel_run = 1'b0; rel_cnt = 0; armed = 1'b0;
            env_at_off = 0; vel_at_off = 0; tbr_at_off = 0; rel_ticks = 0; rel_env_end = 0;
            rep_on_vel_evt = 0; rep_off_vel_evt = 0; rep_on_tbr_evt = 0;
            upd_n = 0; upd_last = 0; upd_first = 0;
            transport_i = 1'b1; play_en = 1'b1;
            $display("     [prog] B start s=%0d cnt=%0d loop_len=%0d ep_vel=%0d", s_cnt, lp_cnt,
                     u_looper.loop_len_r, ep_vel_rec);
            wait (gated_n > 0);
            $display("     [prog] B replay note_on seen s=%0d", s_cnt);
            @(negedge clk);
            armed = 1'b1;
            wait (off_seen == 1);
            $display("     [prog] B replay note_off seen s=%0d", s_cnt);
            rep_env_off = env_at_off; rep_vel_off = vel_at_off; rep_tbr_off = tbr_at_off;
            rep_on_s = on_sample_cnt; rep_off_s = off_sample_cnt;
            play_en = 1'b0; transport_i = 1'b0;
            wait (rel_run == 0);
            rep_rel = rel_len(env_at_off, rel_env_end, rel_ticks);

            // ── 打印对照 ──────────────────────────────────────────────────
            $display("  [%0s] ax=%0d P=%0d R=%0d H=%0d F=%0d | pos@trig->vel_on=%0d off_evt_vel=%0d",
                     name, ax, P, R, H, F, live_on_vel_evt, live_off_vel_evt);
            $display("     LIVE  vel@off=%0d env@off=%0d tbr=%0d rel=%0d smp | dur=%0d smp",
                     live_vel_off, live_env_off, live_tbr_off, live_rel, live_off_s-live_on_s);
            $display("     REC   ep_vel=%0d", ep_vel_rec);
            $display("     REPLAY vel@off=%0d env@off=%0d tbr=%0d rel=%0d smp | dur=%0d smp | upd_n=%0d last=%0d",
                     rep_vel_off, rep_env_off, rep_tbr_off, rep_rel, rep_off_s-rep_on_s,
                     upd_n, upd_last);
            $display("     DELTA vel=%0d env=%0d rel=%0d",
                     rep_vel_off - live_vel_off, rep_env_off - live_env_off, rep_rel - live_rel);

            // ⭐ 记录最差偏差（⭐ 供最后判据用）
            if ((live_vel_off - rep_vel_off) > sc) sc = live_vel_off - rep_vel_off;
            if (live_env_off > 0) begin
                ep_pct = (rep_env_off * 100) / live_env_off;
                if (ep_pct < min_env_pct) min_env_pct = ep_pct;
            end
            if (live_rel > 0) begin
                ep_pct = (rep_rel * 100) / live_rel;
                if (ep_pct < min_rel_pct) min_rel_pct = ep_pct;
            end
        end
    endtask

    initial begin
        gated_n = 0; gidx = -1; last_gated_idx = 0;
        prev_env = 0; prev_vel = 0; prev_tbr = 0;
        armed = 1'b0; rel_cnt = 0; rel_run = 1'b0; off_idx = 0;
        env_at_off = 0; vel_at_off = 0; tbr_at_off = 0; rel_ticks = 0; rel_env_end = 0;
        off_seen = 0; on_seen = 0;
        on_sample_cnt = 0; off_sample_cnt = 0; s_cnt = 0;
        phase = 0; sc = 0; ep_vel_rec = 0;
        ep_pct = 0; min_env_pct = 1000; min_rel_pct = 1000;
        live_env_off = 0; live_vel_off = 0; live_tbr_off = 0; live_rel = 0;
        live_on_s = 0; live_off_s = 0;
        rep_env_off = 0; rep_vel_off = 0; rep_tbr_off = 0; rep_rel = 0;
        rep_on_s = 0; rep_off_s = 0;
        live_on_vel_evt = 0; live_off_vel_evt = 0;
        rep_on_vel_evt = 0; rep_off_vel_evt = 0; rep_on_tbr_evt = 0;
        upd_n = 0; upd_last = 0; upd_first = 0;
        wf_ax = 0; wf_ax4 = 4'd0; wf_P = 0; wf_R = 1; wf_H = 1; wf_F = 1;
        wf_go = 1'b0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        // ⭐⭐ 场景表（⭐ 行程 `pos` ∈ [0,744] ⇒ `pos_to_vel` ∈ [64,255]）
        //    · ⭐ **极轻按**：⭐ 峰值行程只到 70（⭐ 刚过 `TRIG_TH`=64）⇒ 起音/松手力度都 ≈80
        //    · ⭐ **普通按**：⭐ 峰值 300
        //    · ⭐ **重按**：⭐ 峰值 744（满行程）
        //    · ⭐ **重按 + 快松**：⭐ 松手只 2 帧 ⇒ ⭐ 探"手弹 `vel_r` 跟不跟得上"
        $display("== PAD tail: LIVE vs REPLAY over %0d gestures ==", 4);
        run_scenario(0, 70,  2, 100, 2, "LIGHT  P70 ");
        run_scenario(1, 300, 2, 100, 2, "NORMAL P300");
        run_scenario(2, 744, 4, 100, 2, "HARD   P744");
        run_scenario(3, 744, 4, 100, 6, "HARD slow-rel");

        $display("== verdict ==");
        //  ⭐⭐ 判据：⭐ **回放必须与手弹逐值一致**（⭐ 力度 / 包络电平 / 尾音时长）
        //     ⭐ 非空洞性：⭐ 端点取"末值"（⭐ 改动前）⇒ ⭐ `env@off` 只有手弹的 37%~70%
        //        ⇒ ⭐ 下面两条**必红** ✅（⭐ RED/GREEN 两份输出见报告）
        $display("     [dbg] worst env%%=%0d  worst rel%%=%0d", min_env_pct, min_rel_pct);
        chk(sc == 0, "tail: replay vel at note_off equals live vel at note_off (all gestures)");
        chk(min_env_pct >= 90,
            "tail: replayed env level at note_off is within 10 percent of the live one");
        chk(min_rel_pct >= 90,
            "tail: replayed release duration is within 10 percent of the live one");
        chk(fail_cnt == 0, "tail: every gesture matched between live and replay");

        if (fail_cnt == 0)
            $display("PASS: looper tail -- replayed PAD note releases like the live one");
        else
            $display("FAIL: looper tail -- %0d check(s) failed", fail_cnt);
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: looper tail tb timeout");
        $finish;
    end

endmodule
