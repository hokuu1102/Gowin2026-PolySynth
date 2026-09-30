`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_looper_bar_align.sv · ⭐ `T41` **对齐小节**的验收 tb（⭐ 2026-09-30 新增）
//
//  🔴 **用户上板原话**：*"回放的节拍会对不上，回放过几次之后会逐渐延后。
//     比如第一次响在第一拍，后面就会延后到第二拍，第三遍开始第一次响"* ✅
//
//  🔴 **根因（⭐ 见 `rtl/w3c/looper.v` 的 §小节对齐）**：
//     ⭐ `loop_len_r <= rec_tick_r`（⭐ 按下停录那一刻的**原始** tick 计数）
//     ⇒ ⭐ 它**不是整数小节** ⇒ **每绕一圈相位偏 `loop_len mod 一小节` 个 tick**
//     ⇒ 🔴 **误差逐圈累加**（⭐ 这正是"逐渐延后"）✅
//
//  ⭐ 本 tb 的判据（⭐ 名字纯 ASCII、≤128 字节）：
//     ① 起录**待命**：⭐ 在小节中间按 `R` ⇒ 那一刻弹的音**不许**进 loop
//     ② 停录**量化（舍）**：⭐ 停在第 2 小节 + 0.31 小节 ⇒ 层里只剩 **2 小节**的内容
//     ③ 舍掉的那半小节里的事件**不许被回放**（⭐ 它们已在 loop 之外）
//     ④ **跨圈不挂音**：⭐ 停录时还按着的音 ⇒ ⭐ **每一圈**都收到补发的 `note_off`
//     ⑤ **downbeat 对格**：⭐ loop 的 `tick 0` 事件**每一圈都落在 `bar_start` 上**
//     ⑥ **周期精确**：⭐ 相邻两圈的同一条事件间隔 **= `loop_len`**（⭐ 一圈不多不少）
//     ⑦ 停录**量化（补）**：⭐ 停在第 2 小节 + 0.75 小节 ⇒ 周期 = **3 小节**
//     ⑧ 补足时**不丢**那半小节里弹的音（⭐ 它必须被回放）
//     ⑨ 非空洞：⭐ 至少观察到 **8 圈**（⭐ 本 tb 跑 10 圈）
//
//  ⚠️ **网格是"压缩"的**（`BAR_TICKS = 192`，⛔ 不是真实的 3840）——
//     ⭐ 理由：⭐ 10 圈 × 2~3 小节 × 3840 tick 会让本 tb 跑几十秒 ⇒ ⭐ 拖慢回归。
//     ⭐ DUT **自己量** `bar_len`（⭐ 见 `looper.v` 的"网格量尺"）⇒
//     ⭐ 量化阈值与对齐逻辑**与小节大小无关** ⇒ ⭐ 压缩网格同样有效 ✅
//     📌 真实值（⭐ `beat_gen.v:61/93`）：⭐ `PPQN = 960`、`BEATS_PER_BAR = 4`
//        ⇒ `TICKS_PER_BAR = 3840` ✅
// ─────────────────────────────────────────────────────────────────────────────
`define MAXW 8_000_000

module tb_looper_bar_align;

    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer KIND_W   = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer TICK_W   = 20;
    localparam integer EVT_MAX  = 2048;

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;

    //  ⭐ 压缩网格：⭐ 一小节 192 tick（⭐ 真实 3840，⭐ 理由见文件头）✅
    localparam integer BAR_TICKS  = 192;
    localparam integer BEAT_TICKS = 48;      // ⭐ 4/4 ⇒ 每拍 48 tick
    localparam integer HALF_BAR   = 96;      // ⭐ 量化的"取整分界"（⭐ 舍 / 补）
    //  ⭐ 每个 tick 之间的时钟数 —— ⚠️ ⛔ 不能太小：
    //     ⭐ DUT 的推进是"**先把本 tick 的事件排空、再推进 `play_tick_r`**"
    //        （⭐ 同步读 ⇒ 每吐一条事件要 2 拍）⇒ ⭐ 太密会把 DUT **拖后**，
    //        偏移整体漂移（⭐ `tb_looper` 的注释里记着这次实测）✅
    localparam integer TICK_GAP   = 16;
    localparam integer WRAPS      = 10;      // ⭐ 判据要求 ≥8 ⇒ 跑 10 圈 ✅

    reg clk   = 1'b0;
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
    reg                tick_i;
    reg  [TICK_W-1:0]  tick_cnt_i;
    reg                bar_start_i;
    reg                transport_i;
    reg                live_valid_i;
    reg  [AXIS_W-1:0]  live_axis_i;
    reg  [PHASE_W-1:0] live_inc_i;
    reg  [VEL_W-1:0]   live_vel_i;
    reg  [KIND_W-1:0]  live_kind_i;
    reg  [TIMBRE_W-1:0]live_timbre_i;
    reg                live_vel_valid_i;
    reg  [AXIS_W-1:0]  live_vel_axis_i;
    reg  [VEL_W-1:0]   live_vel_value_i;
    reg  [0:0]         rec_req_i, stop_req_i, play_en_i, clear_req_i;

    wire               play_valid_o;
    wire [AXIS_W-1:0]  play_axis_o;
    wire [PHASE_W-1:0] play_inc_o;
    wire [VEL_W-1:0]   play_vel_o;
    wire [KIND_W-1:0]  play_kind_o;
    wire [TIMBRE_W-1:0]play_timbre_o;
    wire               play_timbre_valid_o;
    wire               play_upd_valid_o;
    wire [AXIS_W-1:0]  play_upd_axis_o;
    wire [PHASE_W-1:0] play_upd_inc_o;
    wire [VEL_W-1:0]   play_upd_vel_o;
    wire [0:0]         layer_state_o;
    wire [15:0]        evt_cnt_flat_o;
    wire [0:0]         full_o;
    wire [15:0]        drop_cnt_o;
    wire               overflow_o;

    looper #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .TICK_W(TICK_W), .LAYERS(1), .EVT_MAX(EVT_MAX), .CNT_W(16)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .live_valid_i(live_valid_i), .live_axis_i(live_axis_i),
        .live_inc_i(live_inc_i), .live_vel_i(live_vel_i),
        .live_kind_i(live_kind_i), .live_timbre_i(live_timbre_i),
        .live_vel_valid_i(live_vel_valid_i),
        .live_vel_axis_i(live_vel_axis_i), .live_vel_value_i(live_vel_value_i),
        .play_valid_o(play_valid_o), .play_axis_o(play_axis_o),
        .play_inc_o(play_inc_o), .play_vel_o(play_vel_o), .play_kind_o(play_kind_o),
        .play_timbre_o(play_timbre_o), .play_timbre_valid_o(play_timbre_valid_o),
        .play_upd_valid_o(play_upd_valid_o), .play_upd_axis_o(play_upd_axis_o),
        .play_upd_inc_o(play_upd_inc_o), .play_upd_vel_o(play_upd_vel_o),
        .rec_req_i(rec_req_i), .stop_req_i(stop_req_i),
        .play_en_i(play_en_i), .clear_req_i(clear_req_i),
        .layer_state_o(layer_state_o), .evt_cnt_flat_o(evt_cnt_flat_o),
        .full_o(full_o), .drop_cnt_o(drop_cnt_o), .overflow_o(overflow_o)
    );

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐ 网格发生器 —— ⭐ **严格照 `beat_gen` 的契约**（⭐ ⛔ 不是"随便发个脉冲"）：
    //     · ⭐ `bar_start_i` 与 `tick_i` **同拍**（⭐ `beat_gen.v:212-220`）
    //     · ⭐ `tick_cnt_i` = **小节内 tick 编号**，⭐ 小节起点那一拍 = **0**
    //        （⭐ `beat_gen.v:166`：`at_bar_start = (tick_cnt_q == 16'd0)`）✅
    //     📌 本 tb 因此可以**替代 `beat_gen`** —— ⭐ 而 `beat_gen` 自己的契约
    //        由 `tb_beat_gen.sv` 负责验收 ✅
    // ══════════════════════════════════════════════════════════════════════
    integer grid_cnt = 0;      // ⭐ 小节内 tick 编号（0..BAR_TICKS-1）
    integer tb_tick  = 0;      // ⭐ 全局 tick 计数（⭐ 量"圈与圈的间隔"用）

    task automatic do_tick;
        integer g;
        begin
            @(negedge clk);
            grid_cnt = (grid_cnt + 1 >= BAR_TICKS) ? 0 : (grid_cnt + 1);
            tick_i     = 1'b1;
            tick_cnt_i = grid_cnt[TICK_W-1:0];
            bar_start_i= (grid_cnt == 0);
            tb_tick    = tb_tick + 1;
            @(negedge clk);
            tick_i     = 1'b0;
            bar_start_i= 1'b0;
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

    //  ⭐ 走到"小节内编号 = g"为止（⭐ 含 `g = 0` 那个小节起点）✅
    task automatic tick_until;
        input integer g;
        integer guard;
        begin
            guard = 0;
            while ((grid_cnt != g) && (guard < (4 * BAR_TICKS))) begin
                do_tick;
                guard = guard + 1;
            end
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
            live_inc_i = inc;    live_vel_i = vl;  live_timbre_i = 2'd1;
            @(negedge clk);
            live_valid_i = 1'b0;
        end
    endtask

    task automatic pulse_rec;  begin @(negedge clk); rec_req_i  = 1'b1; @(negedge clk); rec_req_i  = 1'b0; end endtask
    task automatic pulse_stop; begin @(negedge clk); stop_req_i = 1'b1; @(negedge clk); stop_req_i = 1'b0; end endtask
    task automatic pulse_clr;  begin @(negedge clk); clear_req_i= 1'b1; @(negedge clk); clear_req_i= 1'b0; end endtask

    // ── 回放观测 ────────────────────────────────────────────────────────────
    //  ⭐ 标记事件 = **轴 1 的 `note_on`**（⭐ 它录在 loop 的 `tick 0` ⇒ 就是"downbeat"）✅
    integer           mk_n;
    integer           mk_grid [0:63];    // ⭐ 吐出来那一刻的**小节内编号**（⭐ 对格判据）
    integer           mk_tick [0:63];    // ⭐ 吐出来那一刻的**全局 tick**（⭐ 周期判据）
    integer           ax1_off_n;         // ⭐ 轴 1 的 `note_off` 条数
    integer           ax4_on_n;          // ⭐ 轴 4 的 `note_on` 条数（⭐ take B 的"补足区"音）
    integer           ax5_off_n;         // ⭐ 轴 5 的 `note_off` 条数（⭐ 跨圈防挂音）
    integer           ax6_n;             // ⭐ 轴 6 的任何事件（⭐ take A 的"被舍去区"）
    integer           ax7_n;             // ⭐ 轴 7 的任何事件（⭐ 起录前弹的"待命期"音）

    always @(negedge clk) begin
        if (rst_n && play_valid_o) begin
            if ((play_kind_o === KIND_ON) && (play_axis_o === 4'd1)) begin
                if (mk_n < 64) begin
                    mk_grid[mk_n] = grid_cnt;
                    mk_tick[mk_n] = tb_tick;
                end
                mk_n = mk_n + 1;
            end
            if ((play_kind_o === KIND_OFF) && (play_axis_o === 4'd1)) ax1_off_n = ax1_off_n + 1;
            if ((play_kind_o === KIND_ON)  && (play_axis_o === 4'd4)) ax4_on_n  = ax4_on_n  + 1;
            if ((play_kind_o === KIND_OFF) && (play_axis_o === 4'd5)) ax5_off_n = ax5_off_n + 1;
            if (play_axis_o === 4'd6) ax6_n = ax6_n + 1;
            if (play_axis_o === 4'd7) ax7_n = ax7_n + 1;
        end
    end

    integer i;
    integer mk_bad_grid, mk_bad_period, wraps_seen, period_ok;

    initial begin
        // ── 初始化 ──────────────────────────────────────────────────────────
        tick_i = 1'b0; tick_cnt_i = {TICK_W{1'b0}}; bar_start_i = 1'b0;
        transport_i = 1'b0;
        live_valid_i = 1'b0; live_axis_i = {AXIS_W{1'b0}};
        live_inc_i = {PHASE_W{1'b0}}; live_vel_i = {VEL_W{1'b0}};
        live_kind_i = KIND_ON; live_timbre_i = {TIMBRE_W{1'b0}};
        live_vel_valid_i = 1'b0; live_vel_axis_i = {AXIS_W{1'b0}};
        live_vel_value_i = {VEL_W{1'b0}};
        rec_req_i = 1'b0; stop_req_i = 1'b0; play_en_i = 1'b0; clear_req_i = 1'b0;
        grid_cnt = 0; tb_tick = 0;
        mk_n = 0; ax1_off_n = 0; ax4_on_n = 0; ax5_off_n = 0; ax6_n = 0; ax7_n = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════════
        // ① ⭐ 先把网格"量出来"：⭐ DUT 要看到 **2 个 `bar_start`** 才敢用 `bar_len`
        //    （⭐ 第 1 个量到的是"从复位到这一刻"，⛔ 不可信 —— 见 `looper.v`）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 1: let the DUT measure the bar grid (2 bars) ==");
        transport_i = 1'b1;
        idle_ticks(2 * BAR_TICKS + 3);

        // ══════════════════════════════════════════════════════════════════
        // ①b ⭐ **"待起录"可以被下一次 `R` 取消**（⭐ `top.v` 那一下发的是 `stop_req`）
        //     🔴 依据：⭐ `top.v:2959` `stop_req_i = cmd & loop_rec_on_r`
        //        ⇒ ⚠️ 若不支持取消 ⇒ `loop_rec_on_r` 与 looper 状态**反相**
        //        ⇒ 🔴 之后每次 `R` 都发错命令（⭐ 上板表现 = "按 R 没反应"）✅
        //     ⭐ 本判据：⭐ 取消之后**走过一个小节线也不许偷偷起录**（⭐ `layer_state_o` 恒 0）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 1b: an ARMED record can be cancelled by the next R press ==");
        tick_until(100);
        pulse_rec;
        repeat (4) @(negedge clk);
        chk(layer_state_o === 1'b1,
            "bar-align: an armed (pending) record is observable via layer_state_o");
        pulse_stop;                                         // ⭐ 再按一次 R ⇒ 取消
        repeat (4) @(negedge clk);
        chk(layer_state_o === 1'b0,
            "bar-align: the armed record is CANCELLED by the next R press");
        idle_ticks(BAR_TICKS + 3);                          // ⭐ 走过一个小节线
        chk(layer_state_o === 1'b0,
            "bar-align: after the cancel the bar line does NOT silently start recording");

        // ══════════════════════════════════════════════════════════════════
        // ② take A：⭐ **在小节中间**按 `R`（⭐ 编号 137 —— ⛔ 不是小节线）
        //    ⭐ 内容（⭐ 相对 loop 起点 = 小节线）：
        //       tick 0   ON  ax1   ← ⭐ downbeat 标记（⭐ 对格判据就用它）
        //       tick 48  OFF ax1
        //       tick 96  ON  ax2
        //       tick 144 OFF ax2
        //       tick 192 ON  ax3        （第 2 小节）
        //       tick 240 OFF ax3
        //       tick 288 ON  ax5        ← ⭐ **一直按住**（⭐ 停录时补发 ⇒ 防挂音判据）
        //       tick 384 ON  ax6 / tick 432 OFF ax6   ← 🔴 **落在"被舍去的半小节"里**
        //    ⭐ 停在编号 **60**（< 半小节 96）⇒ ⭐ 量化到 **2 小节**（舍）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 2: take A -- arm record in the MIDDLE of a bar ==");
        tick_until(137);
        //  ⭐ 待命期弹一个音（⭐ 轴 7）：🔴 改动前它会被立刻录进去（⭐ 判据 ①）
        pulse_rec;
        repeat (4) @(negedge clk);
        live_evt(KIND_ON, 4'd7, 32'h7777_0007, 8'd100);
        //  ⭐ 等小节起点 ⇒ 真起录（⭐ 起录对齐）
        tick_until(0);
        repeat (4) @(negedge clk);
        live_evt(KIND_ON,  4'd1, 32'h1111_0001, 8'd200);   // ⭐ loop tick 0
        tick_until(BEAT_TICKS);
        live_evt(KIND_OFF, 4'd1, 32'h1111_0001, 8'd200);
        tick_until(2 * BEAT_TICKS);
        live_evt(KIND_ON,  4'd2, 32'h2222_0002, 8'd180);
        tick_until(3 * BEAT_TICKS);
        live_evt(KIND_OFF, 4'd2, 32'h2222_0002, 8'd180);
        tick_until(0);                                     // ⭐ 第 2 小节小节线（tick 192）
        live_evt(KIND_ON,  4'd3, 32'h3333_0003, 8'd160);
        tick_until(BEAT_TICKS);
        live_evt(KIND_OFF, 4'd3, 32'h3333_0003, 8'd160);
        tick_until(2 * BEAT_TICKS);                        // ⭐ tick 288
        live_evt(KIND_ON,  4'd5, 32'h5555_0005, 8'd220);   // ⭐ **不松手**
        tick_until(0);                                     // ⭐ 第 3 小节（tick 384）⇒ 舍去区
        live_evt(KIND_ON,  4'd6, 32'h6666_0006, 8'd140);
        tick_until(BEAT_TICKS);                            // ⭐ tick 432 ⇒ 舍去区
        live_evt(KIND_OFF, 4'd6, 32'h6666_0006, 8'd140);
        tick_until(60);                                    // ⭐ 停录点（< 半小节 ⇒ 舍）
        pulse_stop;
        repeat (60) @(negedge clk);                        // ⭐ 等补发扫完（16 拍 + 余量）

        //  ⭐ 判据 ②③：⭐ 层里应当是 **7 条录制 + 1 条补发 = 8**
        //     （⭐ 轴 6 那两条落在被舍去的半小节里 ⇒ ⭐ 必须**整条消失**）✅
        chk(evt_cnt_flat_o == 16'd8,
            "bar-align A: stop at 2.31 bars quantizes DOWN to 2 bars (8 events, not 10)");

        // ══════════════════════════════════════════════════════════════════
        // ③ take A 回放：⭐ **在小节中间**起播（⭐ 编号 91）⇒ ⭐ 必须等小节线才走 tick
        //    ⭐ 判据：⭐ **每一圈**的 downbeat 都要落在 `bar_start` 上（⭐ 编号 0）
        //             且**圈间隔**必须精确 = `loop_len` = 2 小节 = 384 tick ✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 3: take A replay -- 10 wraps, downbeat must sit ON bar_start ==");
        mk_n = 0; ax1_off_n = 0; ax5_off_n = 0; ax6_n = 0; ax7_n = 0;
        tick_until(91);
        play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(WRAPS * 2 * BAR_TICKS + BAR_TICKS);      // ⭐ 10 圈（每圈 2 小节）
        play_en_i = 1'b0;
        repeat (60) @(negedge clk);                        // ⭐ 等停播补发扫完

        mk_bad_grid = 0;
        for (i = 0; i < mk_n; i = i + 1)
            if (mk_grid[i] != 0) mk_bad_grid = mk_bad_grid + 1;
        wraps_seen = (mk_n >= 1) ? (mk_n - 1) : 0;
        chk(mk_n >= (WRAPS - 1),
            "bar-align A: at least 8 wraps of the downbeat were replayed (non-vacuous)");
        chk(mk_bad_grid == 0,
            "bar-align A: the downbeat note_on lands EXACTLY on bar_start on EVERY wrap");
        period_ok = 1;
        for (i = 1; i < mk_n; i = i + 1)
            if ((mk_tick[i] - mk_tick[i-1]) != (2 * BAR_TICKS)) period_ok = 0;
        chk(period_ok && (wraps_seen >= 8),
            "bar-align A: the loop period is EXACTLY 2 bars on every wrap (no tick lost)");
        chk(ax6_n == 0,
            "bar-align A: the events of the TRIMMED half bar are never replayed");
        chk(ax7_n == 0,
            "bar-align A: a note played BEFORE the bar line is not recorded (record is ARMED)");
        chk(ax5_off_n >= WRAPS - 1,
            "bar-align A: the held note gets its appended note_off on EVERY wrap (no hang)");
        chk(ax1_off_n >= WRAPS - 1,
            "bar-align A: every wrap also replays the recorded note_off of the marker");

        //  ⭐ 探针（⭐ 判据红了先看数据 —— ⭐ 本项目 `C83` 纪律）✅
        $display("     [dbg] A: mk_n=%0d bad_grid=%0d ax5_off=%0d ax6=%0d ax7=%0d",
                 mk_n, mk_bad_grid, ax5_off_n, ax6_n, ax7_n);
        for (i = 0; (i < mk_n) && (i < 12); i = i + 1)
            $display("     [dbg] A: wrap[%0d] grid=%0d tick=%0d", i, mk_grid[i], mk_tick[i]);

        // ══════════════════════════════════════════════════════════════════
        // ④ take B：⭐ **回放中**按 `R` 重录（⭐ `ST_REC` 的第二个入口）⇒ ⭐ 也要对齐
        //    ⭐ 停在编号 **144**（> 半小节 96）⇒ ⭐ 量化到 **3 小节**（补）
        //    ⭐ 补足区里那两条（⭐ 轴 4，tick 384/432）**必须留下**（⭐ 判据 ⑧）✅
        // ══════════════════════════════════════════════════════════════════
        $display("== 4: take B -- re-record while playing, stop in the SECOND half bar ==");
        //  ⭐⭐ **走 `ST_REC` 的第二个入口**（⭐ 回放中按 `R` ⇒ `br_leave_w` ⇒
        //     `ST_LCLOSE` ⇒ `LEAVE_REC`）—— 🔴 这条**也**必须对齐小节，
        //     否则"回放中重录"仍然会越跑越偏（⭐ 只改一个入口是**假修**）✅
        tick_until(91);
        play_en_i = 1'b1;
        tick_until(0);                                      // ⭐ 起播对齐 ⇒ 等小节线
        idle_ticks(100);                                    // ⭐ 第 1 圈 tick 100 ⇒ ax2 正响着
        pulse_rec;                                          // ⭐ 回放中按 R ⇒ 重录
        repeat (60) @(negedge clk);                         // ⭐ 等"离开回放"的补发扫完
        play_en_i = 1'b0;                                   // ⭐ 起播时刻由本 tb 控制
        tick_until(0);
        repeat (4) @(negedge clk);
        live_evt(KIND_ON,  4'd1, 32'h1111_0001, 8'd200);    // ⭐ loop tick 0（downbeat 标记）
        tick_until(BEAT_TICKS);
        live_evt(KIND_OFF, 4'd1, 32'h1111_0001, 8'd200);
        tick_until(2 * BEAT_TICKS);
        live_evt(KIND_ON,  4'd2, 32'h2222_0002, 8'd180);
        tick_until(3 * BEAT_TICKS);
        live_evt(KIND_OFF, 4'd2, 32'h2222_0002, 8'd180);
        tick_until(0);                                      // ⭐ tick 192
        live_evt(KIND_ON,  4'd3, 32'h3333_0003, 8'd160);
        tick_until(BEAT_TICKS);
        live_evt(KIND_OFF, 4'd3, 32'h3333_0003, 8'd160);
        tick_until(0);                                      // ⭐ tick 384 ⇒ **补足区**（要留下）
        live_evt(KIND_ON,  4'd4, 32'h4444_0004, 8'd150);
        tick_until(BEAT_TICKS);
        live_evt(KIND_OFF, 4'd4, 32'h4444_0004, 8'd150);
        tick_until(144);                                    // ⭐ 停录点（> 半小节 ⇒ 补）
        pulse_stop;
        repeat (60) @(negedge clk);

        chk(evt_cnt_flat_o == 16'd8,
            "bar-align B: stop at 2.75 bars quantizes UP to 3 bars (8 events, nothing dropped)");

        $display("== 5: take B replay -- 10 wraps of a 3-bar loop ==");
        mk_n = 0; ax1_off_n = 0; ax4_on_n = 0; ax5_off_n = 0; ax6_n = 0; ax7_n = 0;
        tick_until(91);
        play_en_i = 1'b1;
        repeat (2) @(negedge clk);
        idle_ticks(WRAPS * 3 * BAR_TICKS + BAR_TICKS);      // ⭐ 10 圈（每圈 3 小节）
        play_en_i = 1'b0;
        repeat (60) @(negedge clk);

        mk_bad_grid = 0;
        for (i = 0; i < mk_n; i = i + 1)
            if (mk_grid[i] != 0) mk_bad_grid = mk_bad_grid + 1;
        period_ok = 1;
        for (i = 1; i < mk_n; i = i + 1)
            if ((mk_tick[i] - mk_tick[i-1]) != (3 * BAR_TICKS)) period_ok = 0;
        chk(mk_bad_grid == 0,
            "bar-align B: the downbeat lands EXACTLY on bar_start on EVERY wrap (3-bar loop)");
        chk(period_ok && (mk_n >= 9),
            "bar-align B: the loop period is EXACTLY 3 bars on every wrap (padded bar)");
        chk(ax4_on_n >= 9,
            "bar-align B: the note played in the PADDED half bar is kept and replayed");

        $display("     [dbg] B: mk_n=%0d bad_grid=%0d ax4_on=%0d", mk_n, mk_bad_grid, ax4_on_n);
        for (i = 0; (i < mk_n) && (i < 12); i = i + 1)
            $display("     [dbg] B: wrap[%0d] grid=%0d tick=%0d", i, mk_grid[i], mk_tick[i]);

        if (fail_cnt == 0)
            $display("PASS: looper T41 bar alignment -- arm/quantize/align across 10 wraps");
        else
            $display("FAIL: looper T41 bar alignment -- %0d check(s) failed", fail_cnt);
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: looper bar-align tb timeout");
        $finish;
    end

endmodule
