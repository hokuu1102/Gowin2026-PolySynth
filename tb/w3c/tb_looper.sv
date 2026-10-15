`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_looper.sv · `looper.v` 的验收 tb（⭐ T37：单层录制 + 播放）
//
//  ⭐ 判据（⭐ 全部【能失败】）：
//     ① 录→放：⭐ **10 条载荷逐条一致**
//     ② ⭐ **不错拍**：⭐ 重放偏移**精确等于** `2/3/5/5/6/7/9/9/11/11`
//     ③ ⭐ **不错拍（周期）**：⭐ 第 2 圈偏移与第 1 圈**完全相同**
//     ④ ⭐ **防挂音**：⭐ 轴 4（没收到 `note_off`）**必须被补发**
//     ⑤ ⭐ **防挂音【边界】**：⭐ **轴 15** 也必须被补发（⭐ 扫描要到 `4'hF`）
//     ⑥ ⭐ **同拍两条**（⭐ tick 5 的和弦）**一条都不丢**
//     ⑦ ⭐ `clear` 后该层为空，⭐ 且**不再重放**
//     ⑧ ⭐ **录满【可见】**：`full_o` / `overflow_o` / `drop_cnt_o`
//     ⑨ ⭐ A8：⭐ 重放输出**无 X/Z**
//
//  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **回放携带【录制时的音色】**
//     ⑬ ⭐ 每条 `note_on` 回放时带回**它自己录制时的音色**（⭐ 中途切音色也各自正确 ✅）
//     ⑭ ⭐ `play_timbre_valid_o` **与 `play_valid_o` 同拍**（⭐ 每条都置位 ✅）
//     ⭐ **非空洞性**：⭐ 把 `play_timbre_o <= e_tbr` 改成 `<= live_timbre_i` ⇒ ⭐ ⑬ 必红 ✅
//
//  ⚠️ 判据名**纯 ASCII 且 ≤ 128 字节** —— ⭐ 实测 `vvp` 输出非 ASCII 会被
//     破坏性转换（⭐ 会让按判据名匹配的变异脚本失配）；⭐ 而 `chk` 的 `msg`
//     端口只有 `[1023:0]`（128 字节），⭐ Verilog 右对齐零填充 ⇒ 超长会**吃掉开头** ✅
// ─────────────────────────────────────────────────────────────────────────────
`define MAXW 2_000_000

module tb_looper;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer KIND_W  = 2;
    //  ⭐⭐ 2026-09-29 新增：⭐ 音色字段（⭐ 用户需求：回放用【录制时】的音色 ✅）
    localparam integer TIMBRE_W = 2;
    localparam integer TICK_W  = 20;
    localparam integer EVT_MAX = 2048;

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task automatic chk;
        input          cond;
        input [1023:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  ok  : %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    // ── DUT ──────────────────────────────────────────────────────────────────
    reg                  tick_i;
    reg  [TICK_W-1:0]    tick_cnt_i;
    reg                  bar_start_i;
    reg                  transport_i;
    reg                  live_valid_i;
    reg  [AXIS_W-1:0]    live_axis_i;
    reg  [PHASE_W-1:0]   live_inc_i;
    reg  [VEL_W-1:0]     live_vel_i;
    reg  [KIND_W-1:0]    live_kind_i;
    reg  [TIMBRE_W-1:0]  live_timbre_i;    // ⭐ 新增：录制时的"当前手弹音色"
    //  ⭐⭐ 2026-09-29 新增：⭐ **手弹【位置式力度】流**（⭐ 端点来源）
    //     ⭐ 与 `top.v` 的 `vu_valid_r/vu_axis_r/vu_val_r` 同一个源 ✅
    reg                  live_vel_valid_i;
    reg  [AXIS_W-1:0]    live_vel_axis_i;
    reg  [VEL_W-1:0]     live_vel_value_i;
    reg  [0:0]           rec_req_i, stop_req_i, play_en_i, clear_req_i;

    wire                 play_valid_o;
    wire [AXIS_W-1:0]    play_axis_o;
    wire [PHASE_W-1:0]   play_inc_o;
    wire [VEL_W-1:0]     play_vel_o;
    wire [KIND_W-1:0]    play_kind_o;
    wire [TIMBRE_W-1:0]  play_timbre_o;        // ⭐ 新增：回放携带的【录制时音色】
    wire                 play_timbre_valid_o;  // ⭐ 新增：与 play_valid_o 同拍
    //  ⭐⭐ 2026-09-29 新增：⭐ **回放插值更新**（⭐ 端点/插值判据用它）
    wire                 play_upd_valid_o;
    wire [AXIS_W-1:0]    play_upd_axis_o;
    wire [PHASE_W-1:0]   play_upd_inc_o;
    wire [VEL_W-1:0]     play_upd_vel_o;
    wire [0:0]           layer_state_o;
    wire [15:0]          evt_cnt_flat_o;
    wire [0:0]           full_o;
    wire [15:0]          drop_cnt_o;
    wire                 overflow_o;
    //  ⭐⭐ 2026-10-11：⭐ **导出读口**（⭐ 录制回传 ✅）
    reg                  dump_en = 1'b0;
    reg  [15:0]          dump_a  = 16'd0;
    wire [63:0]          dump_d;          // ⭐ **线上 64 位格式**（⭐ 由 looper 重打包 ✅）
    wire                 dump_clip;       // ⭐ 截断标志 ✅
    reg  [63:0]          d0, d1;
    reg                  clip0, clip1;
    //  ⚠️ ⭐ **两套偏移都必须与 `looper.v` 一致**（⭐ 那边是 `localparam` ⇒ 这里照抄 ✅）
    //     · ⭐ `I_*` = **内部 68 位**存储布局（⭐ `looper.v` 的 `O_*` ✅）
    //       `O_VEL=0` · `O_INC=8` · `O_AXIS=40` · `O_KIND=44` · `O_TICK=46` · `O_TBR=66` ✅
    //     · ⭐ `T_*` = **线上 64 位**帧布局（⭐ 与 `evt_uart_rx` 的 9 字节帧逐位一致 ✅）
    //       `tick[63:44]` · `inc[43:23]` · `axis[22:19]` · `vel[18:11]` ·
    //       `kind[10:9]` · `timbre[8:7]` · `[6:0]` 保留 ✅
    localparam integer I_VEL  = 0,  I_INC  = 8,  I_AXIS = 40, I_KIND = 44, I_TICK = 46, I_TBR = 66;
    localparam integer T_TICK = 44, T_INC  = 23, T_AXIS = 19, T_VEL  = 11, T_KIND = 9,  T_TBR = 7;

    //  ⭐⭐ **期望值由本 tb 独立按【线上格式】拼出来** ⇒ ⭐ 它就是**规格** ✅
    function [63:0] repack;
        input [67:0] w;
        begin
            repack = {w[I_TICK +: 20], w[I_INC+10 +: 21], w[I_AXIS +: 4],
                      w[I_VEL  +: 8],  w[I_KIND +: 2], w[I_TBR +: 2], 7'b0};
        end
    endfunction

    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TICK_W(TICK_W), .LAYERS(1), .EVT_MAX(EVT_MAX), .CNT_W(16)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .live_valid_i(live_valid_i), .live_axis_i(live_axis_i),
        .live_inc_i(live_inc_i), .live_vel_i(live_vel_i),
        .live_kind_i(live_kind_i),
        .live_timbre_i(live_timbre_i),
        //  ⭐⭐ 2026-09-29 新增：⭐ 手弹位置式力度流（⭐ 端点来源）
        .live_vel_valid_i(live_vel_valid_i),
        .live_vel_axis_i(live_vel_axis_i),
        .live_vel_value_i(live_vel_value_i),
        .play_valid_o(play_valid_o), .play_axis_o(play_axis_o),
        .play_inc_o(play_inc_o), .play_vel_o(play_vel_o),
        .play_kind_o(play_kind_o),
        .play_timbre_o(play_timbre_o), .play_timbre_valid_o(play_timbre_valid_o),
        //  ⭐⭐ 2026-09-29 新增：⭐ 回放插值更新
        .play_upd_valid_o(play_upd_valid_o), .play_upd_axis_o(play_upd_axis_o),
        .play_upd_inc_o(play_upd_inc_o), .play_upd_vel_o(play_upd_vel_o),
        .rec_req_i(rec_req_i), .stop_req_i(stop_req_i),
        .play_en_i(play_en_i), .clear_req_i(clear_req_i),
        .layer_state_o(layer_state_o), .evt_cnt_flat_o(evt_cnt_flat_o),
        .full_o(full_o), .drop_cnt_o(drop_cnt_o), .overflow_o(overflow_o),
        //  ⭐⭐ 2026-10-11：⭐ **录制回传的导出读口** ✅
        .dump_en_i(dump_en), .dump_addr_i(dump_a), .dump_data_o(dump_d),
        .dump_clip_o(dump_clip)
    );

    //  ⭐ 第二个实例：`EVT_MAX = 4` ⇒ ⭐ 专门验"录满可见"（判据 ⑧）
    reg  [0:0]           rec2, stop2, play2, clr2;
    wire                 pv2;
    wire [AXIS_W-1:0]    pa2;
    wire [PHASE_W-1:0]   pi2;
    wire [VEL_W-1:0]     pvel2;
    wire [KIND_W-1:0]    pk2;
    wire [TIMBRE_W-1:0]  pt2;      // ⭐ 小实例的音色输出（本 tb 不判它）
    wire                 ptv2;
    wire [15:0]          cnt2, drop2;
    wire [0:0]           full2;
    wire                 ovf2;
    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TICK_W(TICK_W), .LAYERS(1), .EVT_MAX(4), .CNT_W(16)
    ) dut_small (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .live_valid_i(live_valid_i), .live_axis_i(live_axis_i),
        .live_inc_i(live_inc_i), .live_vel_i(live_vel_i),
        .live_kind_i(live_kind_i),
        .live_timbre_i(live_timbre_i),
        .play_valid_o(pv2), .play_axis_o(pa2), .play_inc_o(pi2),
        .play_vel_o(pvel2), .play_kind_o(pk2),
        .play_timbre_o(pt2), .play_timbre_valid_o(ptv2),
        .rec_req_i(rec2), .stop_req_i(stop2), .play_en_i(play2),
        .clear_req_i(clr2),
        .layer_state_o(), .evt_cnt_flat_o(cnt2), .full_o(full2),
        .drop_cnt_o(drop2), .overflow_o(ovf2)
    );

    // ── A8 ───────────────────────────────────────────────────────────────────
    wire [31:0] a8_axis, a8_inc, a8_vel, a8_kind, a8_tbr;
    chk_xprop #(.W(AXIS_W),  .NAME("play_axis_o")) u_a8a (.clk(clk), .rst_n(rst_n), .sig(play_axis_o), .err_cnt(a8_axis));
    chk_xprop #(.W(PHASE_W), .NAME("play_inc_o"))  u_a8i (.clk(clk), .rst_n(rst_n), .sig(play_inc_o),  .err_cnt(a8_inc));
    chk_xprop #(.W(VEL_W),   .NAME("play_vel_o"))  u_a8v (.clk(clk), .rst_n(rst_n), .sig(play_vel_o),  .err_cnt(a8_vel));
    chk_xprop #(.W(KIND_W),  .NAME("play_kind_o")) u_a8k (.clk(clk), .rst_n(rst_n), .sig(play_kind_o), .err_cnt(a8_kind));
    chk_xprop #(.W(TIMBRE_W),.NAME("play_timbre_o")) u_a8t (.clk(clk), .rst_n(rst_n), .sig(play_timbre_o), .err_cnt(a8_tbr));

    // ── 录制侧记账（⭐ 期望值）──────────────────────────────────────────────
    integer           exp_n;
    reg [KIND_W-1:0]  exp_kind [0:63];
    reg [AXIS_W-1:0]  exp_ax   [0:63];
    reg [PHASE_W-1:0] exp_inc  [0:63];
    reg [VEL_W-1:0]   exp_vel  [0:63];
    integer           exp_off  [0:63];

    // ── 重放侧捕获（⭐ 实际值）──────────────────────────────────────────────
    integer           got_n;
    reg [KIND_W-1:0]  got_kind [0:255];
    reg [AXIS_W-1:0]  got_ax   [0:255];
    reg [PHASE_W-1:0] got_inc  [0:255];
    reg [VEL_W-1:0]   got_vel  [0:255];
    //  ⭐⭐ 2026-09-29 新增：⭐ 回放携带的【录制时音色】＋ 它的 `valid` 计数 ✅
    reg [TIMBRE_W-1:0] got_tbr [0:255];
    integer           tbrv_cnt;
    integer           got_tick [0:255];

    integer tb_tick;      // ⭐ tb 自己数的 PPQN tick（⭐ 用来算偏移）
    integer loop_base;    // ⭐ 起播时的 `tb_tick`

    always @(negedge clk) begin
        if (rst_n && play_valid_o && (got_n < 256)) begin
            got_kind[got_n] = play_kind_o;
            got_ax  [got_n] = play_axis_o;
            got_inc [got_n] = play_inc_o;
            got_vel [got_n] = play_vel_o;
            got_tbr [got_n] = play_timbre_o;        // ⭐ 新增：录制时音色
            got_tick[got_n] = tb_tick;
            if (play_timbre_valid_o === 1'b1) tbrv_cnt = tbrv_cnt + 1;
            got_n = got_n + 1;
        end
    end

    //  ⭐⭐ 2026-09-29 新增：⭐ 回放**插值更新**的捕获（⭐ 端点/插值判据用）
    //   ⚠️ **必须按 `upd_en` 门控到【第一圈】** —— ⭐ 否则第二圈重头爬的值
    //      （⭐ 又回到起点附近）会**盖住"第一圈末尾到了终点"**这条判据 ✅
    integer          upd_n;
    reg              upd_en;
    reg [VEL_W-1:0]  upd_vel [0:511];
    reg [AXIS_W-1:0] upd_ax  [0:511];
    always @(negedge clk) begin
        if (rst_n && upd_en && play_upd_valid_o && (upd_n < 512)) begin
            upd_vel[upd_n] = play_upd_vel_o;
            upd_ax [upd_n] = play_upd_axis_o;
            upd_n = upd_n + 1;
        end
    end

    // ── 驱动小任务 ───────────────────────────────────────────────────────────
    //  ⭐⭐ 每个 PPQN tick 之间的**时钟数**
    //     🔴 **为什么不能是 2**（⭐ 本 tb 实测踩到）：⭐ DUT 的推进是
    //        "**先把本 tick 的事件排空，再推进 `play_tick_r`**"
    //        ⇒ ⭐ 它需要 **≥3 拍**（tick 拍 + pend 拍 + 吐事件拍）
    //        ⚠️ 若 tb 每 2 拍就发一个 tick ⇒ 🔴 **DUT 被拖后，偏移整体漂移**
    //           （⭐ 实测：偏移 +1，⭐ 且**同拍的和弦被拆到相邻两个 tick**）
    //     📌 真实 PPQN tick @120 BPM = 61440 拍 ⇒ ⭐ 12 拍已经**极其保守** ✅
    localparam integer TICK_GAP = 12;

    task automatic do_tick;
        integer g;
        begin
            @(negedge clk);
            tick_i  = 1'b1;
            tb_tick = tb_tick + 1;
            @(negedge clk);
            tick_i  = 1'b0;
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
            live_valid_i = 1'b1; live_kind_i = kd; live_axis_i = ax;
            live_inc_i = inc;    live_vel_i = vl;
            @(negedge clk);
            live_valid_i = 1'b0;
        end
    endtask

    task automatic exp_add;
        input [KIND_W-1:0]  kd;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        input integer       off;
        begin
            exp_kind[exp_n] = kd;  exp_ax[exp_n] = ax;
            exp_inc [exp_n] = inc; exp_vel[exp_n] = vl;
            exp_off [exp_n] = off;
            exp_n = exp_n + 1;
        end
    endtask

    task automatic pulse_rec;  begin @(negedge clk); rec_req_i  = 1'b1; @(negedge clk); rec_req_i  = 1'b0; end endtask
    task automatic pulse_stop; begin @(negedge clk); stop_req_i = 1'b1; @(negedge clk); stop_req_i = 1'b0; end endtask
    task automatic pulse_clr;  begin @(negedge clk); clear_req_i= 1'b1; @(negedge clk); clear_req_i= 1'b0; end endtask

    //  ⭐⭐ 2026-09-29 新增：⭐ 一条"手弹位置式力度"更新（⭐ 1 拍脉冲）
    task automatic live_vel_upd;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  vl;
        begin
            @(negedge clk);
            live_vel_valid_i = 1'b1; live_vel_axis_i = ax; live_vel_value_i = vl;
            @(negedge clk);
            live_vel_valid_i = 1'b0;
        end
    endtask

    integer i;
    integer j;
    integer off1 [0:63], off2 [0:63];
    integer n1, n2;
    integer cnt_off4, cnt_off15;
    integer payload_ok, off_ok, per_ok, same_ok, tbr_ok;
    //  ⭐⭐ 2026-09-29 新增（⭐ 端点/插值判据用）
    reg  [7:0] gv;                       // ⭐ 手势的当前力度（⭐ 逐段加 20）
    integer    upd_distinct, dup_found, upd_ax_ok, off_vel_ok;

    initial begin
        tick_i = 1'b0; tick_cnt_i = {TICK_W{1'b0}}; bar_start_i = 1'b0;
        transport_i = 1'b0;
        live_valid_i = 1'b0; live_axis_i = {AXIS_W{1'b0}};
        live_inc_i = {PHASE_W{1'b0}}; live_vel_i = {VEL_W{1'b0}};
        live_kind_i = KIND_ON;
        live_timbre_i = {TIMBRE_W{1'b0}};
        //  ⭐⭐ 2026-09-29 新增：⭐ 手弹位置式力度流 / 插值捕获计数
        live_vel_valid_i = 1'b0;
        live_vel_axis_i  = {AXIS_W{1'b0}};
        live_vel_value_i = {VEL_W{1'b0}};
        upd_n = 0;
        upd_en = 1'b0;
        rec_req_i = 1'b0; stop_req_i = 1'b0; play_en_i = 1'b0; clear_req_i = 1'b0;
        rec2 = 1'b0; stop2 = 1'b0; play2 = 1'b0; clr2 = 1'b0;
        tb_tick = 0; loop_base = 0; exp_n = 0; got_n = 0; tbrv_cnt = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════════
        // ⭐ 录制（⭐ 相对 tick）：⭐ 2 ON ax1 · 3 OFF ax1 · 5 ON ax2 · 5 ON ax3
        //                        · 6 OFF ax2 · 7 OFF ax3 · 9 ON ax4 · 9 ON ax15
        //    ⚠️ ax4 与 ax15 **故意不闭合** ⇒ ⭐ 停录时必须各补一条 `note_off`
        //    ⭐ 停录在 tick 12 ⇒ `loop_len = 12`，⭐ 补发落在 tick **11**
        // ══════════════════════════════════════════════════════════════════
        $display("== 1: record ==");
        //  ⭐⭐ 2026-09-29 新增：⭐ **录制时音色 = 1**（⭐ 前 6 条）✅
        live_timbre_i = 2'd1;
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON,  4'd1,  32'h1111_0001, 8'd100); exp_add(KIND_ON,  4'd1,  32'h1111_0001, 8'd100, 2);
        do_tick;
        live_evt(KIND_OFF, 4'd1,  32'h1111_0001, 8'd100); exp_add(KIND_OFF, 4'd1,  32'h1111_0001, 8'd100, 3);
        idle_ticks(1);
        do_tick;
        live_evt(KIND_ON,  4'd2,  32'h2222_0002, 8'd110); exp_add(KIND_ON,  4'd2,  32'h2222_0002, 8'd110, 5);
        live_evt(KIND_ON,  4'd3,  32'h3333_0003, 8'd120); exp_add(KIND_ON,  4'd3,  32'h3333_0003, 8'd120, 5);
        do_tick;
        live_evt(KIND_OFF, 4'd2,  32'h2222_0002, 8'd110); exp_add(KIND_OFF, 4'd2,  32'h2222_0002, 8'd110, 6);
        do_tick;
        live_evt(KIND_OFF, 4'd3,  32'h3333_0003, 8'd120); exp_add(KIND_OFF, 4'd3,  32'h3333_0003, 8'd120, 7);
        idle_ticks(1);
        do_tick;
        //  ⭐⭐ 2026-09-29 新增：⭐ **录制中途切音色 ⇒ 音色 = 2**（⭐ 验"每个音各自记住" ✅）
        live_timbre_i = 2'd2;
        live_evt(KIND_ON,  4'd4,  32'h4444_0004, 8'd130); exp_add(KIND_ON,  4'd4,  32'h4444_0004, 8'd130, 9);
        live_evt(KIND_ON,  4'd15, 32'hFFFF_000F, 8'd140); exp_add(KIND_ON,  4'd15, 32'hFFFF_000F, 8'd140, 9);
        do_tick;
        idle_ticks(2);
        pulse_stop;                       // ⭐ `loop_len = 12`
        repeat (40) @(negedge clk);       // ⭐ 等补发扫完（16 拍 + 余量）

        //  ⭐ 补发的两条（⭐ 落在 tick 11，⭐ 扫描顺序 ⇒ 先 ax4 后 ax15）
        //  ⭐⭐ 2026-09-29 **契约变更**（⭐ 本次"端点 + 插值"设计的一部分）：
        //     🔴 `note_off` 的 `inc`/`vel` **不再是 0**，而是"**该音的终点**"
        //        = ⭐ 录制期间该轴**最后已知的实时值**（⭐ `last_inc_r`/`last_vel_r`）
        //     ⭐ 所以这里从 `32'h0 / 8'd0` 改成 **该 `note_on` 带的值**
        //        （⭐ ax4 起音是 `0x4444_0004 / 130`、⭐ ax15 是 `0xFFFF_000F / 140`）
        //     🔴 **为什么不能继续填 0**：⭐ 跨循环点一直按住的音 ⇒ ⭐ 若终点填 0，
        //        回放会把力度**插值拉到 0** ⇒ 🔴 **尾音反而更短**（⭐ 比不改还差）✅
        //     📌 **判据语义一字未改**：⭐ 仍然只断言"**回放逐字等于录下来的**" ✅
        exp_add(KIND_OFF, 4'd4,  32'h4444_0004, 8'd130, 11);
        exp_add(KIND_OFF, 4'd15, 32'hFFFF_000F, 8'd140, 11);

        chk(evt_cnt_flat_o == 16'd10,
            "record: 8 played + 2 appended note_off = 10 events stored");

        // ══════════════════════════════════════════════════════════════════
        // ⭐ 重放：⭐ 连跑两圈
        // ══════════════════════════════════════════════════════════════════
        $display("== 2: replay two loops ==");
        got_n = 0;
        tbrv_cnt = 0;
        //  ⭐⭐ 2026-09-29 新增：⭐ **回放时把手弹音色切成 3**（⭐ 回放【不许】跟它 ✅）
        //     ⇒ ⭐ 判据 ⑬ 因此**非空洞**：⭐ 若实现成"跟随手弹" ⇒ 🔴 会读到 3 ⇒ 必红 ✅
        live_timbre_i = 2'd3;
        transport_i = 1'b1;
        play_en_i   = 1'b1;
        repeat (2) @(negedge clk);
        loop_base = tb_tick;
        idle_ticks(24);                   // ⭐ 两圈（`loop_len` = 12）
        play_en_i   = 1'b0;
        transport_i = 1'b0;
        repeat (4) @(negedge clk);

        chk(got_n == 20, "replay: exactly 20 events over two loops (10 per loop)");

        //  ⭐ 判据 ①：⭐ 10 条载荷逐条一致
        payload_ok = 1;
        for (i = 0; i < 10; i = i + 1)
            if (!((got_kind[i] === exp_kind[i]) && (got_ax[i] === exp_ax[i]) &&
                  (got_inc[i]  === exp_inc[i])  && (got_vel[i] === exp_vel[i])))
                payload_ok = 0;
        chk(payload_ok, "replay: all 10 event payloads come back EXACTLY as recorded");

        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑬（⭐ 2026-09-29 新功能）：⭐ **回放必须用【录制时】的音色**
        //   🔴 **用户原话**：*"希望录制回放的时候，是输出录制时的音色，
        //      ⭐ 而不是跟随现在手弹的音色播放"* ✅
        //   ⭐ **本判据**：⭐ 录制时音色 = 1（⭐ 前 4 条 `note_on`）· ⭐ 中途切到 2
        //      （⭐ ax4 / ax15 那两条）⇒ ⭐ **回放时手弹音色已切成 3**
        //      ⇒ ⭐ 每条 `note_on` 必须带回**它自己录制时的值** ✅
        //   ⭐ **非空洞性**：⭐ 把 `play_timbre_o <= e_tbr` 改成 `<= live_timbre_i`
        //      ⇒ ⭐ **本判据必红**（⭐ 会读到 3 ✅）
        //   ⚠️ 补发的两条 `note_off`（idx 8/9）音色填 0 ⇒ ⭐ **不参与本判据**
        //      （⭐ `note_manager` 只在 `note_on` 提交时锁存音色 ✅）
        // ══════════════════════════════════════════════════════════════════
        tbr_ok = 1;
        for (i = 0; i < 10; i = i + 1) begin
            if (exp_kind[i] == KIND_ON) begin
                if ((i == 6) || (i == 7)) begin
                    if (got_tbr[i] !== 2'd2) tbr_ok = 0;
                end else begin
                    if (got_tbr[i] !== 2'd1) tbr_ok = 0;
                end
            end
        end
        chk(tbr_ok, "replay: every note_on carries the timbre captured at RECORD time (1,1,1,2,2)");
        chk(live_timbre_i === 2'd3,
            "replay: the live timbre is 3 now -- keeps the timbre check NON-VACUOUS");
        chk(tbrv_cnt == got_n,
            "replay: play_timbre_valid_o is asserted on EVERY replayed event");

        //  ⭐ 判据 ②③：⭐ 偏移（⭐ 拆两圈）
        n1 = 0; n2 = 0;
        for (i = 0; i < got_n; i = i + 1) begin
            if ((got_tick[i] - loop_base) < 12) begin
                off1[n1] = got_tick[i] - loop_base; n1 = n1 + 1;
            end else begin
                off2[n2] = (got_tick[i] - loop_base) - 12; n2 = n2 + 1;
            end
        end
        off_ok = (n1 == 10) && (n2 == 10);
        if (off_ok)
            for (i = 0; i < 10; i = i + 1)
                if (off1[i] != exp_off[i]) off_ok = 0;
        chk(off_ok, "replay: offsets are exactly 2/3/5/5/6/7/9/9/11/11 as recorded");

        per_ok = off_ok;
        if (per_ok)
            for (i = 0; i < 10; i = i + 1)
                if (off2[i] != off1[i]) per_ok = 0;
        chk(per_ok, "replay: loop 2 offsets are IDENTICAL to loop 1 (period is exact)");

        //  ⭐⭐ 探针（⭐ 判据红了先看数据，⛔ 不盲改 —— 本项目 `C83` 纪律）
        $display("     [dbg] got_n=%0d  n1=%0d  n2=%0d  loop_base=%0d", got_n, n1, n2, loop_base);
        for (i = 0; (i < got_n) && (i < 24); i = i + 1)
            $display("     [dbg] ev[%0d] tb_tick=%0d off=%0d kind=%0d ax=%0d",
                     i, got_tick[i], got_tick[i] - loop_base, got_kind[i], got_ax[i]);

        //  ⭐ 判据 ⑥：⭐ 同拍两条都在（⭐ tick 5 的 ax2 / ax3）
        same_ok = (got_ax[2] === 4'd2) && (got_ax[3] === 4'd3) &&
                  (off1[2] == 5) && (off1[3] == 5);
        chk(same_ok, "same-tick: both notes of the tick-5 chord are replayed");

        //  ⭐ 判据 ④⑤：⭐ 防挂音（⭐ 含边界）
        cnt_off4 = 0; cnt_off15 = 0;
        for (i = 0; i < 10; i = i + 1) begin
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd4))  cnt_off4  = cnt_off4 + 1;
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd15)) cnt_off15 = cnt_off15 + 1;
        end
        chk(cnt_off4 == 1, "no-hang: the unclosed note_on on axis 4 got a note_off");
        chk(cnt_off15 == 1, "no-hang BOUNDARY: axis 15 is closed too (scan reaches 4'hF)");

        // ══════════════════════════════════════════════════════════════════
        // ⭐ 判据 ⑦：`clear`
        // ══════════════════════════════════════════════════════════════════
        $display("== 3: clear ==");
        pulse_clr;
        repeat (4) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd0, "clear: the layer reports 0 events");
        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        idle_ticks(16);
        play_en_i = 1'b0; transport_i = 1'b0;
        repeat (4) @(negedge clk);
        chk(got_n == 0, "clear: nothing is replayed after clear");

        // ══════════════════════════════════════════════════════════════════
        // ⭐ 判据 ⑧：⭐ 录满【可见】（⭐ `EVT_MAX = 4`）
        // ══════════════════════════════════════════════════════════════════
        $display("== 4: overflow is visible ==");
        @(negedge clk); rec2 = 1'b1; @(negedge clk); rec2 = 1'b0;
        for (i = 0; i < 6; i = i + 1)
            live_evt(KIND_ON, i[AXIS_W-1:0], 32'h0100_0000 + i, 8'd90);
        @(negedge clk); stop2 = 1'b1; @(negedge clk); stop2 = 1'b0;
        repeat (40) @(negedge clk);
        chk(cnt2 == 16'd4, "overflow: the layer stops storing at EVT_MAX (=4)");
        chk(full2 === 1'b1, "overflow: full_o is raised (not silent)");
        chk(ovf2 === 1'b1, "overflow: overflow_o is raised (sticky)");
        chk(drop2 != 16'd0, "overflow: drop_cnt_o counts the dropped events");

        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑩（⭐ 2026-09-29 修 bug①）：⭐ **回放中 clear ⇒ 必须先补发 `note_off`**
        //   🔴 **上板实测（用户报告）**：⭐ 回放中按 `C` 清空 ⇒ ⭐ **当前正在响的音【永久挂住】** ✅
        //   🔴 **根因**：⭐ 原 `clear` 直接 `state <= ST_IDLE` ⇒ ⭐ 那些音永远收不到 `note_off` ✅
        //   ⭐ **本判据**：⭐ 录一个【很长的音】（⭐ 补发的 `note_off` 落在 loop 末尾）⇒
        //      ⭐ 起播 ⇒ ⭐ **在音还在响的时候（tick 10）发 `clear`**
        //      ⇒ ⭐ **重放输出里必须出现过该轴的 `note_off`** ✅
        //   ⭐ **非空洞性**：⭐ 把 `clear` 改回"直接清"（旧写法）⇒ ⭐ **本判据必红** ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 5: clear during playback must close the sounding note ==");
        pulse_clr;                                  // ⭐ 先清干净
        repeat (4) @(negedge clk);
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd5, 32'h5555_0005, 8'd120);   // ⭐ tick 2 起音
        idle_ticks(28);                                   // ⭐ 一直不松 ⇒ `loop_len` ≈ 30
        pulse_stop;                                       // ⭐ 停录 ⇒ 补发 OFF ax5 到 tick 29
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2,
            "bug1 setup: 1 note_on + 1 appended note_off stored");

        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(10);                             // ⭐ 走到 tick 10 ⇒ ⭐ **ax5 正响着**
        pulse_clr;                                  // ⭐⭐ 清空（⭐ 这就是上板那一下）
        repeat (40) @(negedge clk);
        play_en_i = 1'b0; transport_i = 1'b0;
        repeat (4) @(negedge clk);

        cnt_off4 = 0;
        for (i = 0; i < got_n; i = i + 1)
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd5)) cnt_off4 = cnt_off4 + 1;
        chk(cnt_off4 >= 1,
            "bug1: clear during playback emits a note_off for the sounding axis");
        chk(evt_cnt_flat_o == 16'd0,
            "bug1: the layer is empty after the clear-out finishes");

        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑪（⭐ 2026-09-29【结构性修法】）：⭐ **回放中按 `R` 重录也必须先补发**
        //   🔴 **为什么加**：⭐ `ST_HOLD` 有 **3 条**退出路径（⭐ `clear` / `play_en` 落沿 / `rec_req`）⚠️
        //      ⇒ ⭐ 我第一版**只补了 2 条** ⇒ 🔴 **`rec_req` 那条仍然挂音** ✅
        //      📌 ⭐ 这是用户指出"**禁止修表象**"后才发现的 ✅
        //   ⭐ **本判据**：⭐ 录一个长音 ⇒ 起播 ⇒ ⭐ **在音还在响时（tick 10）发 `rec_req`**
        //      ⇒ ⭐ **重放输出里必须出现过该轴的 `note_off`** ✅
        //   ⭐ **非空洞性**：⭐ 把唯一出口那段的条件去掉（⭐ 恢复"直接进 `ST_REC`"）
        //      ⇒ ⭐ **本判据必红** ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 6: rec_req during playback must close the sounding note ==");
        pulse_clr;
        repeat (4) @(negedge clk);
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd5, 32'h5555_0005, 8'd120);   // ⭐ tick 2 起音
        idle_ticks(28);
        pulse_stop;
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2, "bug1b setup: 1 note_on + 1 appended note_off");

        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(10);                             // ⭐ 走到 tick 10 ⇒ ⭐ ax5 正响着
        pulse_rec;                                  // ⭐⭐ 回放中按 R（⭐ 重录）
        repeat (40) @(negedge clk);
        play_en_i = 1'b0; transport_i = 1'b0;
        repeat (4) @(negedge clk);

        cnt_off4 = 0;
        for (i = 0; i < got_n; i = i + 1)
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd5)) cnt_off4 = cnt_off4 + 1;
        chk(cnt_off4 >= 1,
            "bug1b: rec_req during playback emits a note_off for the sounding axis");

        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑫：⭐ **回放中【停播】（`play_en` 落沿）也必须先补发**
        //   ⭐ 这是 `ST_HOLD` 的**第 2 条**退出路径 ✅ ⇒ ⭐ 三条路径至此**全有判据** ✅
        //   ⭐ **非空洞性**：⭐ 去掉 `play_en` 落沿那段补发 ⇒ ⭐ **本判据必红** ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 7: play_en falling must close the sounding note ==");
        pulse_clr;
        repeat (4) @(negedge clk);
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd5, 32'h5555_0005, 8'd120);
        idle_ticks(28);
        pulse_stop;
        repeat (40) @(negedge clk);

        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(10);                             // ⭐ ax5 正响着
        play_en_i = 1'b0;                           // ⭐⭐ 停播（⭐ 落沿）
        repeat (40) @(negedge clk);
        transport_i = 1'b0;
        repeat (4) @(negedge clk);

        cnt_off4 = 0;
        for (i = 0; i < got_n; i = i + 1)
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd5)) cnt_off4 = cnt_off4 + 1;
        chk(cnt_off4 >= 1,
            "bug1c: play_en falling emits a note_off for the sounding axis");

        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **端点 + 线性插值**
        //
        //  🔴 修的缺陷（⭐ 用户上板报告，⭐ 两条症状同一个根因）：
        //     · *"loop 的声音比键盘小"* —— ⭐ 原来回放**只带 `note_on` 那一个力度**
        //     · *"loop 回放没有 release 尾音"* —— ⭐ `adsr.v` 的 release 是
        //       **每采样拍固定步长** ⇒ ⭐ **尾音长度 ∝ 松手时的包络电平 ∝ 力度**
        //       （⭐ 力度 200 ⇒ 峰 51200 ⇒ sustain 12800 ⇒ PAD 尾音 ≈262 ms；
        //         力度 64 ⇒ 4096 ⇒ ≈84 ms —— ⭐ **3 倍差距**）
        //     ⭐ 而手弹时力度是**位置式连续更新**的 ⇒ 🔴 只录起音那一个值
        //       ⇒ **又小又短** ✅
        //
        //  ⭐ **本段场景**：⭐ 录一个"**轻按 → 按重**"的手势
        //     · ⭐ 起音 `vel = 80`；⭐ 按住期间每 24 tick 抬 20 ⇒ **终值 240**
        //     · ⭐ 按住 ≈190 tick（⭐ 120 BPM 下 ≈100 ms）后松手
        //     ⚠️ **松手那条事件故意带 `vel = 200`**（⭐ 模拟 `top.v` 的真实行为：
        //        `note_off` 自带的力度是"松手那一刻"的 `VEL_DEFAULT`，
        //        ⭐ ⛔ **不是**按住期间的力度）⇒ ⭐ 若 looper 不"跟住实时流"，
        //        🔴 就会把 200 当成终点 ⇒ **本段判据必红** ✅
        //
        //  ⭐ **判据（两条核心 + 两条非空洞性前置）**：
        //     ① ⭐ 插值脉冲**从起点爬到终点**：⭐ 首条在 (80, 240) 之间（⛔ 不是一跳到位），
        //        末条 **== 240**（⭐ = 录到的终点力度 ⇒ ⭐ 尾音与手弹一样长 ✅）
        //     ② ⭐ 回放的 `note_off` 事件字**带 240**（⭐ = 录到的终点，⛔ 不是 200）
        //     ③ ⭐ 真的是插值：⭐ 不同取值 **≥ 8 个**（⭐ 防"两段跳"冒充插值 ✅）
        //     ④ ⭐ 全部脉冲都打在**同一个轴**上（⭐ 防串轴 ✅）
        //   ⭐ **非空洞性**：⭐ 把 `looper.v` 里装载插值那段
        //      （`ramp_mask[e_axis] <= (ep_inc != e_inc) || (ep_vel != e_vel);`）
        //      改成 `1'b0` ⇒ ⭐ **①③必红**（⭐ ②仍绿 —— 它验的是"端点记录"，
        //      ⭐ 与"插值脉冲"是**两条独立通路**，⭐ 正好互相印证 ✅）
        //      📌 RED / GREEN 两份输出见报告（⛔ 不删，⭐ 本项目 `C83` 纪律）
        // ══════════════════════════════════════════════════════════════════
        $display("== 8: light->heavy gesture -- endpoints + interpolation ==");
        pulse_clr;
        repeat (4) @(negedge clk);
        live_timbre_i = 2'd0;
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd6, 32'h6666_0006, 8'd80);       // ⭐ 起音：轻（80）
        gv = 8'd80;
        for (i = 1; i <= 8; i = i + 1) begin
            gv = gv + 8'd20;                                 // ⭐ 按重：100…240
            live_vel_upd(4'd6, gv);
            idle_ticks(23);
        end
        //  ⭐ 松手（⭐ 事件自带 200 —— ⚠️ 它**不是**终点；⭐ 终点是"最后已知值 240"）
        live_evt(KIND_OFF, 4'd6, 32'h6666_0006, 8'd200);
        idle_ticks(4);
        pulse_stop;                                          // ⭐ `loop_len` ≈ 196
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2,
            "gesture setup: exactly 1 note_on + 1 note_off stored (the note was closed live)");

        // ── 回放（⭐ 只统计【第一圈】的插值脉冲）─────────────────────────────
        upd_n = 0;
        upd_en = 1'b1;
        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(188);              // ⭐ 第一圈：`loop_len = 190`，音符跨度 = tick 2..186
        upd_en = 1'b0;
        idle_ticks(20);               // ⭐ 走过回绕点（⭐ 第二圈的值**不参与判据**）
        play_en_i = 1'b0; transport_i = 1'b0;
        repeat (4) @(negedge clk);

        chk(upd_n > 8,
            "gesture setup: replay emitted interpolated update pulses (non-vacuous)");
        chk((upd_n > 8) && (upd_vel[0] < 8'd240) && (upd_vel[0] >= 8'd80),
            "gesture: the FIRST interpolated value sits BETWEEN start(80) and end(240)");
        chk((upd_n > 8) && (upd_vel[upd_n-1] == 8'd240),
            "gesture: the LAST interpolated value REACHES the recorded END velocity (240)");
        //  ⭐ 非空洞性：⭐ 不同取值个数（⭐ "两段跳"只有 2 个 ⇒ 必红 ✅）
        upd_distinct = 0;
        for (i = 0; i < upd_n; i = i + 1) begin
            dup_found = 0;
            for (j = 0; j < i; j = j + 1)
                if (upd_vel[j] == upd_vel[i]) dup_found = 1;
            if (!dup_found) upd_distinct = upd_distinct + 1;
        end
        chk(upd_distinct >= 8,
            "gesture: the ramp is a REAL interpolation (>= 8 distinct velocity values)");
        upd_ax_ok = (upd_n > 0);
        for (i = 0; i < upd_n; i = i + 1)
            if (upd_ax[i] !== 4'd6) upd_ax_ok = 0;
        chk(upd_ax_ok, "gesture: every interpolated pulse targets the SAME axis (6)");

        //  ⭐ ② 回放的 `note_off` 事件字必须带"录到的终点力度 240"（⛔ 不是松手自带的 200）
        off_vel_ok = 0;
        for (i = 0; i < got_n; i = i + 1)
            if ((got_kind[i] === KIND_OFF) && (got_ax[i] === 4'd6)) begin
                off_vel_ok = (got_vel[i] === 8'd240) ? 1 : -1;
            end
        chk(off_vel_ok == 1,
            "gesture: the replayed note_off carries the recorded END velocity (240, not 200)");
        //  ⭐ 探针（⭐ 判据红了先看数据，⛔ 不盲改 —— 本项目 `C83` 纪律）
        $display("     [dbg] upd_n=%0d  first=%0d  last=%0d  distinct=%0d",
                 upd_n, (upd_n > 0) ? upd_vel[0] : 8'd0,
                 (upd_n > 0) ? upd_vel[upd_n-1] : 8'd0, upd_distinct);
        $display("     [dbg] got_n=%0d  off_vel_ok=%0d", got_n, off_vel_ok);
        $display("     [dbg] ep_valid=%b ep_vel=%0d ep_tick=%0d ep_inc=%h",
                 dut.ep_valid, dut.ep_vel, dut.ep_tick, dut.ep_inc);
        $display("     [dbg] ramp_mask=%b ramp_go=%b ramp_sc=%0d ramp_vel6=%0d rend6=%0d",
                 dut.ramp_mask, dut.ramp_go, dut.ramp_sc, dut.ramp_vel[6], dut.rend_tick[6]);
        $display("     [dbg] ep0v=%b ep0vel=%0d ep0tick=%0d on_addr6=%0d on_open=%b",
                 dut.ep_mem[0][dut.O_EPV], dut.ep_mem[0][dut.O_EPVE +: 8],
                 dut.ep_mem[0][dut.O_EPT +: 20], dut.on_addr_r[6], dut.on_open_r[6]);

        // ══════════════════════════════════════════════════════════════════
        // ══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑮（⭐ 2026-09-29）：⭐ **`on_open_r` 泄漏 ⇒ 别音的终点被静默改写**
        //   🔴 **缺陷**：⭐ 录制中按 `clear` 走的是 `br_clear_w` 那条（⭐ `br_leave_w`
        //      要求 `state == ST_HOLD`）⇒ ⭐ 直接回 `ST_IDLE`，⭐ `on_open_r[a]` **不清**
        //      ⇒ ⭐ 下一遍录制里松开那个"老键"时，⭐ 这条**没有前置 `note_on`** 的
        //      `note_off` 会命中 `ep_w_off_w` ⇒ ⭐ 把终点写到**上一遍录音的旧地址** ✅
        //   ⭐ **本判据场景**：
        //     · 第 1 遍：`note_on` ax0（⭐ 事件 0）⇒ ⭐ `on_addr_r[0]=0`、`on_open_r[0]=1`
        //     · ⭐ **录制中直接 `clear`**（⭐ 老键【不松】）
        //     · 第 2 遍：`note_on` ax1（⭐ 又是事件 0）＋ `note_off` ax1（⭐ 事件 1）
        //       ⇒ ⭐ **`ep_mem[0]` = ax1 自己的终点**（⭐ tick 32、力度 160）
        //     · ⭐ 这时才**松开老键 ax0**（⭐ 事件 2）⇒ 🔴 老代码把 ax0 的终点
        //       （⭐ 力度 240）**写进 `ep_mem[0]`** ⇒ ⭐ ax1 的终点被改写 ✅
        //     · 停录 ⇒ 回放：⭐ ax1 的插值**必须爬到 160**（⭐ 老代码爬到 240 ⇒ 必红）✅
        //   ⭐ **非空洞性**：⭐ 把 `looper.v` 里 `ST_REC` 两个入口的
        //      `on_open_r <= 16'd0;` 删掉 ⇒ ⭐ **本判据必红** ✅
        //      📌 RED / GREEN 两份输出见报告（⛔ 不删，⭐ 本项目 `C83` 纪律）
        // ══════════════════════════════════════════════════════════════════
        $display("== 9: stale on_open_r must not corrupt another note's endpoint ==");
        pulse_clr;
        repeat (4) @(negedge clk);
        live_timbre_i = 2'd0;

        // ① 第 1 遍：按住 ax0 不放（⭐ 制造"未闭合的 note_on"）
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd0, 32'hA0A0_0000, 8'd100);      // ⭐ 事件 0
        idle_ticks(2);

        // ② ⭐ **录制中直接 clear**（⭐ 老键不松 ⇒ ⭐ 这里正是泄漏点）
        pulse_clr;
        repeat (4) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd0,
            "stale_on_open setup: clear during record empties the layer");

        // ③ 第 2 遍：⭐ 事件 0/1 = ax1 的起音/终点 ⇒ ⭐ `ep_mem[0]` 属于 ax1
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON,  4'd1, 32'h1111_0001, 8'd100);      // ⭐ 事件 0（⭐ tick 2）
        idle_ticks(30);
        live_vel_upd(4'd1, 8'd160);                           // ⭐ ax1 的终点力度 = 160
        live_evt(KIND_OFF, 4'd1, 32'h1111_0001, 8'd100);      // ⭐ 事件 1（⭐ tick 32）
        idle_ticks(2);

        // ④ ⭐ 现在才松开【老键 ax0】⇒ 🔴 老代码在这里把 ax0 的终点写进 `ep_mem[0]`
        live_vel_upd(4'd0, 8'd240);                           // ⭐ 老键的终点力度 = 240
        live_evt(KIND_OFF, 4'd0, 32'hA0A0_0000, 8'd240);      // ⭐ 事件 2（⭐ tick 34）
        idle_ticks(2);
        pulse_stop;                                           // ⭐ `loop_len = 36`
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd3,
            "stale_on_open setup: the second take stored 3 events");

        // ⑤ 回放第一圈：⭐ ax1 的插值终点必须是【它自己的 160】，⛔ 不是 ax0 的 240
        upd_n = 0;
        upd_en = 1'b1;
        got_n = 0;
        transport_i = 1'b1; play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(34);               // ⭐ 第一圈（`loop_len = 36`）—— ⛔ 不跨回绕点
        upd_en = 1'b0;
        idle_ticks(10);               // ⭐ 走过回绕点（⭐ 第二圈的值不参与判据）
        play_en_i = 1'b0; transport_i = 1'b0;
        repeat (4) @(negedge clk);

        upd_ax_ok = (upd_n > 0);
        for (i = 0; i < upd_n; i = i + 1)
            if (upd_ax[i] !== 4'd1) upd_ax_ok = 0;
        chk(upd_ax_ok,
            "stale_on_open: replay ramps the NEW note's axis (1) and nothing else");
        chk((upd_n > 0) && (upd_vel[upd_n-1] == 8'd160),
            "stale_on_open: the replayed endpoint stays its OWN (160) -- not 240");
        $display("     [dbg] upd_n=%0d last=%0d ep0v=%b ep0vel=%0d ep0tick=%0d on_open0=%b",
                 upd_n, (upd_n > 0) ? upd_vel[upd_n-1] : 8'd0,
                 dut.ep_mem[0][dut.O_EPV], dut.ep_mem[0][dut.O_EPVE +: 8],
                 dut.ep_mem[0][dut.O_EPT +: 20], dut.on_open_r[0]);
        // ⭐ 判据 ⑨：A8
        // ══════════════════════════════════════════════════════════════════
        chk((a8_axis == 0) && (a8_inc == 0) && (a8_vel == 0) && (a8_kind == 0) && (a8_tbr == 0),
            "A8: no X/Z on the replay outputs");

        // ══════════════════════════════════════════════════════════════════
        $display("== ⑩ ⭐ 2026-10-11：录制回传 · 导出读口（dump_en/addr/data）==");
        // ══════════════════════════════════════════════════════════════════
        //  ⭐ 判据：⭐ 导出必须能**按地址读出已录的事件**，⭐ 且⛔ 不干扰放音路径 ✅
        //  ⚠️ **为什么必须复用同一个读口**（⭐ 这是本判据真正守的东西）：
        //     ⭐ `mem` 要推成 **BSRAM**（⭐ 物理结构 = **1 写口 ＋ 1 读口** ✅）
        //     ⇒ ⚠️ 再加一条 `always @(posedge clk) x <= mem[addr2]`
        //        ⇒ 🔴 **推不出 BSRAM** ⇒ 退回 DFF 阵列
        //        ⇒ ⭐ 就是 `looper.v` 记过的那个 **`135168 > 60780` 综合失败** ✅
        //     ⇒ ⭐ 所以导出走的是**同一条**读口（⭐ 地址 mux ✅）
        pulse_clr;
        do_tick; do_tick;
        pulse_rec;
        do_tick;
        live_evt(2'd0, 4'd3, 32'h0012_3456, 8'd77);      // ⭐ 第 0 条（⭐ inc < 2^21 ✅）
        do_tick; do_tick;
        live_evt(2'd1, 4'd9, 32'h0015_6789, 8'd88);      // ⭐ 第 1 条（⭐ 同上 ✅）
        do_tick; do_tick;
        pulse_stop;
        idle_ticks(4);

        dump_en = 1'b1; dump_a = 16'd0;
        @(negedge clk); @(negedge clk);
        d0 = dump_d;
        clip0 = dump_clip;
        dump_a = 16'd1;
        @(negedge clk); @(negedge clk);
        d1 = dump_d;

        chk((^d0) !== 1'bx, "DUMP-a dump_data_o is X-free while dumping");
        //  ⭐⭐ **验【重打包】**（⭐ 比"和 `mem[k]` 比"有意义得多 ✅）：
        //     ⭐ 期望值由**本 tb 独立按【线上格式】拼出来**（⭐ 见 `repack()` ✅）
        //     ⭐ 内部 68 位 ⇒ ⭐ 线上 64 位（⭐ `inc` **只留 21 位** ✅）
        chk(d0 === repack(dut.mem[0]), "DUMP-b addr 0 == the repacked WIRE-FORMAT word of mem[0]");
        chk(d1 === repack(dut.mem[1]), "DUMP-c addr 1 == the repacked wire-format word of mem[1]");
        chk(d0 !== d1,   "DUMP-d (NON-VACUOUS) the two entries differ => the address really selects");
        //  ⭐ 字段位序（⭐ **线上格式** ✅）
        chk(d0[T_AXIS +: 4] === 4'd3,  "DUMP-e axis[22:19] of entry 0 == 3 (as recorded)");
        chk(d1[T_AXIS +: 4] === 4'd9,  "DUMP-f axis[22:19] of entry 1 == 9");
        chk(d0[T_INC  +: 21] === 21'h0048d,
            "DUMP-g 0x123456 sample increment exports as clock-unit 0x48d");
        chk(d0[T_VEL  +: 8] === 8'd77, "DUMP-h vel[18:11] of entry 0 == 77");
        chk(d0[T_KIND +: 2] === 2'd0,  "DUMP-i kind[10:9] of entry 0 == 0");
        //  ⭐⭐ **截断标志**：⭐ 两条录进去的 `inc` 都 < 2^21 ⇒ ⭐ **不许报截断** ✅
        //     🔴 **诚实记录**：⭐ 本判据的**第一版用了 `0x11112222`**（⭐ 286 M ✅）——
        //        ⚠️ 而那个值**本身就远超 21 位** ⇒ 🔴 **判据自己写错了**（⭐ RTL 是对的 ✅）
        //     📌 ⭐ 顺带发现：⭐ **实时弹的 `inc` 常常就超过 21 位**
        //        （⭐ `axis_map.BASE_INC = 0x0010_0000`，⭐ 键 69 ≈ 5.6e7 ✅）
        //        ⇒ ⭐ 所以"导出截断"**⛔ 不是边角情形**，⭐ 而是**常态** ✅
        //        ⇒ ⭐ 这正是 `dump_clip_o` 必须存在的理由 ✅
        chk(clip0 === 1'b1, "DUMP-j nonzero low ten bits report quantization loss");

        //  ⭐⭐⭐ **截断的【非空洞性】对照**：⭐ 录一条 `inc` 超出 21 位的事件 ✅
        //     ⭐ 它模拟的是"**实时弹**的事件"（⭐ `axis_map` 给的是 **32 位全用** ✅）
        //     ⇒ ⭐ 导出**必然截断** ⇒ ⭐ 而这**必须【可见】**（⭐ `K-106` ⛔ 不许静默失真 ✅）
        pulse_clr;
        do_tick; do_tick;
        pulse_rec;
        do_tick;
        live_evt(2'd0, 4'd5, 32'h0080_0000, 8'd99);      // ⭐ bit23 ⇒ **超出 21 位** ✅
        do_tick; do_tick;
        pulse_stop;
        idle_ticks(4);
        dump_en = 1'b1; dump_a = 16'd0;
        @(negedge clk); @(negedge clk);
        clip1 = dump_clip;
        chk(clip1 === 1'b0, "DUMP-k exact multiple of 1024 exports losslessly");
        chk(dump_d[T_INC +: 21] === 21'd8192,
            "DUMP-l sample increment 0x00800000 exports as 8192, not zero");

        //  ⭐⭐ **非干扰性**：⭐ `dump_en = 0` ⇒ 读口必须**回到放音指针** ✅
        dump_en = 1'b0;
        @(negedge clk); @(negedge clk);
        chk(dump_d === repack(dut.mem[dut.rd_ptr_r]),
            "DUMP-m with dump_en=0 the read port is back on the playback pointer (no interference)");

        // ══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ⑫（⭐ 2026-10-16）：⭐ **`clear_req_i` 打一拍后仍"恰好一次"** ✅
        //   🔴 **为什么加**：⭐ 本轮为修 setup 违例（⭐ 起点
        //      `u_ctrl_key_map/loop_clear_req_o_s0/Q` ⇒ ⭐ 终点
        //      `g_sound.u_looper/ep_mem_ep_mem_0_4_s/ADA[8]`、⭐ slack **-1.009 ns** ✅）
        //      在 `looper` **入口**给 `clear_req_i` 加了一拍流水（⭐ 见 `rtl/w3c/looper.v:737` ✅）
        //      ⇒ ⭐ **必须证明**：⭐ ① 单拍脉冲 **⛔ 不许丢** ✅
        //                      ⭐ ② **⛔ 不许变成"清两次"**（⭐ 即⛔ 不许被展宽成电平 ✅）
        //   ⭐ **非空洞性（⭐ 两条都推演过"能红" ✅）**：
        //      · ⭐ 把 `clear_pipe_r` 的赋值改成 `1'b0`（⭐ 丢脉冲 ✅）
        //        ⇒ ⭐ `e`/`f` **必红** ✅
        //      · ⭐ 把它改成直通（⭐ `<= clear_req_i[0]`，⭐ 等于没打拍 ✅）
        //        ⇒ ⭐ `c`/`d` 的"脉冲宽度 1 拍"**必红** ✅
        //   📌 ⭐ **脉冲源那一侧**的判据在 `tb/w3a/tb_ctrl_keypad.sv:366-383`
        //      （⭐ `7a` 短按⛔ 不清 · ⭐ `7b` 长按**恰好一次** · ⭐ `7c` 继续按住⛔ 不再发 ✅）
        //      ⇒ ⭐ 两段合起来 = ⭐ **"长按 key12 仍只清一次、且仍能清"** 的完整证据链 ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 9: CLEARPIPE -- one-cycle clear pulse in => exactly one clear out ==");
        transport_i = 1'b0; play_en_i = 1'b0;
        pulse_clr;
        repeat (8) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd0, "CLEARPIPE-a setup: the layer starts empty");

        //  ⭐ ① 录一条（⭐ 与判据 ⑩ 同一套路：⭐ 停录会补发 `note_off` ⇒ ⭐ 恰好 2 条 ✅）
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd9, 32'h9999_0009, 8'd100);
        idle_ticks(28);
        pulse_stop;
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2, "CLEARPIPE-b setup: 2 events stored => the layer is non-empty");

        //  ⭐ ② **恰好一拍**的清空脉冲 ⇒ ⭐ 先经流水、⭐ 再真的清掉 ✅
        //  ⚠️ ⭐ **采样点**：⭐ `pulse_clr` 返回时正好在"把 `clear_req_i` 拉回 0"的
        //     那个 negedge 上 ⇒ ⭐ 此刻流水寄存器**刚捕获完**（⭐ 还在 1 ✅）；
        //     ⭐ 再等一个 negedge ⇒ ⭐ 中间已经过了一个 posedge ⇒ ⭐ 已清回 0 ✅
        pulse_clr;
        chk(dut.clear_pipe_r === 1'b1,
            "CLEARPIPE-c (PIPE) the pulse sits in the pipeline register for exactly 1 cycle");
        @(negedge clk);
        chk(dut.clear_pipe_r === 1'b0,
            "CLEARPIPE-d (PIPE) and it is gone again => the pulse is NOT stretched into a level");
        repeat (8) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd0,
            "CLEARPIPE-e (NON-VACUOUS) a SINGLE-cycle pulse still clears the layer after the pipeline");

        //  ⭐ ③ **"恰好一次"**：⭐ 再录一遍 ⇒ ⭐ 必须**稳定保持**非空 ✅
        //     🔴 若清空被"补做第二次"（⭐ 脉冲被展宽 / ⭐ FSM 反复回清空态 ✅）
        //        ⇒ ⭐ 这次重录会被再清掉 ⇒ ⭐ 本条**必红** ✅
        pulse_rec;
        idle_ticks(2);
        live_evt(KIND_ON, 4'd9, 32'h9999_0009, 8'd100);
        idle_ticks(28);
        pulse_stop;
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2,
            "CLEARPIPE-f the clear fired EXACTLY ONCE: a later recording is not wiped again");
        repeat (60) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd2,
            "CLEARPIPE-g ... and it is still there 60 cycles later (no lingering second clear)");

        pulse_clr;                                  // ⭐ 收尾：⭐ 把层清干净 ✅
        repeat (8) @(negedge clk);

        if (fail_cnt == 0)
            $display("PASS: looper T37 record/replay, no-hang incl. axis 15, clear, same-tick, overflow, clear-pipeline one-shot");
        else
            $display("FAIL: looper T37 -- %0d check(s) failed", fail_cnt);
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: looper tb timeout");
        $finish;
    end

endmodule
