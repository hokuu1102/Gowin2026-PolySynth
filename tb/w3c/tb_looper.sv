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
    reg  [0:0]           rec_req_i, stop_req_i, play_en_i, clear_req_i;

    wire                 play_valid_o;
    wire [AXIS_W-1:0]    play_axis_o;
    wire [PHASE_W-1:0]   play_inc_o;
    wire [VEL_W-1:0]     play_vel_o;
    wire [KIND_W-1:0]    play_kind_o;
    wire [0:0]           layer_state_o;
    wire [15:0]          evt_cnt_flat_o;
    wire [0:0]           full_o;
    wire [15:0]          drop_cnt_o;
    wire                 overflow_o;

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
        .play_valid_o(play_valid_o), .play_axis_o(play_axis_o),
        .play_inc_o(play_inc_o), .play_vel_o(play_vel_o),
        .play_kind_o(play_kind_o),
        .rec_req_i(rec_req_i), .stop_req_i(stop_req_i),
        .play_en_i(play_en_i), .clear_req_i(clear_req_i),
        .layer_state_o(layer_state_o), .evt_cnt_flat_o(evt_cnt_flat_o),
        .full_o(full_o), .drop_cnt_o(drop_cnt_o), .overflow_o(overflow_o)
    );

    //  ⭐ 第二个实例：`EVT_MAX = 4` ⇒ ⭐ 专门验"录满可见"（判据 ⑧）
    reg  [0:0]           rec2, stop2, play2, clr2;
    wire                 pv2;
    wire [AXIS_W-1:0]    pa2;
    wire [PHASE_W-1:0]   pi2;
    wire [VEL_W-1:0]     pvel2;
    wire [KIND_W-1:0]    pk2;
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
        .play_valid_o(pv2), .play_axis_o(pa2), .play_inc_o(pi2),
        .play_vel_o(pvel2), .play_kind_o(pk2),
        .rec_req_i(rec2), .stop_req_i(stop2), .play_en_i(play2),
        .clear_req_i(clr2),
        .layer_state_o(), .evt_cnt_flat_o(cnt2), .full_o(full2),
        .drop_cnt_o(drop2), .overflow_o(ovf2)
    );

    // ── A8 ───────────────────────────────────────────────────────────────────
    wire [31:0] a8_axis, a8_inc, a8_vel, a8_kind;
    chk_xprop #(.W(AXIS_W),  .NAME("play_axis_o")) u_a8a (.clk(clk), .rst_n(rst_n), .sig(play_axis_o), .err_cnt(a8_axis));
    chk_xprop #(.W(PHASE_W), .NAME("play_inc_o"))  u_a8i (.clk(clk), .rst_n(rst_n), .sig(play_inc_o),  .err_cnt(a8_inc));
    chk_xprop #(.W(VEL_W),   .NAME("play_vel_o"))  u_a8v (.clk(clk), .rst_n(rst_n), .sig(play_vel_o),  .err_cnt(a8_vel));
    chk_xprop #(.W(KIND_W),  .NAME("play_kind_o")) u_a8k (.clk(clk), .rst_n(rst_n), .sig(play_kind_o), .err_cnt(a8_kind));

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
    integer           got_tick [0:255];

    integer tb_tick;      // ⭐ tb 自己数的 PPQN tick（⭐ 用来算偏移）
    integer loop_base;    // ⭐ 起播时的 `tb_tick`

    always @(negedge clk) begin
        if (rst_n && play_valid_o && (got_n < 256)) begin
            got_kind[got_n] = play_kind_o;
            got_ax  [got_n] = play_axis_o;
            got_inc [got_n] = play_inc_o;
            got_vel [got_n] = play_vel_o;
            got_tick[got_n] = tb_tick;
            got_n = got_n + 1;
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

    integer i;
    integer off1 [0:63], off2 [0:63];
    integer n1, n2;
    integer cnt_off4, cnt_off15;
    integer payload_ok, off_ok, per_ok, same_ok;

    initial begin
        tick_i = 1'b0; tick_cnt_i = {TICK_W{1'b0}}; bar_start_i = 1'b0;
        transport_i = 1'b0;
        live_valid_i = 1'b0; live_axis_i = {AXIS_W{1'b0}};
        live_inc_i = {PHASE_W{1'b0}}; live_vel_i = {VEL_W{1'b0}};
        live_kind_i = KIND_ON;
        rec_req_i = 1'b0; stop_req_i = 1'b0; play_en_i = 1'b0; clear_req_i = 1'b0;
        rec2 = 1'b0; stop2 = 1'b0; play2 = 1'b0; clr2 = 1'b0;
        tb_tick = 0; loop_base = 0; exp_n = 0; got_n = 0;

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
        live_evt(KIND_ON,  4'd4,  32'h4444_0004, 8'd130); exp_add(KIND_ON,  4'd4,  32'h4444_0004, 8'd130, 9);
        live_evt(KIND_ON,  4'd15, 32'hFFFF_000F, 8'd140); exp_add(KIND_ON,  4'd15, 32'hFFFF_000F, 8'd140, 9);
        do_tick;
        idle_ticks(2);
        pulse_stop;                       // ⭐ `loop_len = 12`
        repeat (40) @(negedge clk);       // ⭐ 等补发扫完（16 拍 + 余量）

        //  ⭐ 补发的两条（⭐ 落在 tick 11，⭐ 扫描顺序 ⇒ 先 ax4 后 ax15）
        exp_add(KIND_OFF, 4'd4,  32'h0, 8'd0, 11);
        exp_add(KIND_OFF, 4'd15, 32'h0, 8'd0, 11);

        chk(evt_cnt_flat_o == 16'd10,
            "record: 8 played + 2 appended note_off = 10 events stored");

        // ══════════════════════════════════════════════════════════════════
        // ⭐ 重放：⭐ 连跑两圈
        // ══════════════════════════════════════════════════════════════════
        $display("== 2: replay two loops ==");
        got_n = 0;
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
        // ⭐ 判据 ⑨：A8
        // ══════════════════════════════════════════════════════════════════
        chk((a8_axis == 0) && (a8_inc == 0) && (a8_vel == 0) && (a8_kind == 0),
            "A8: no X/Z on the replay outputs");

        if (fail_cnt == 0)
            $display("PASS: looper T37 record/replay, no-hang incl. axis 15, clear, same-tick, overflow");
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
