// tb_looper_no_drum.sv — ⭐ "鼓不进 loop"专用判据（2026-10-17）
//
// ⭐ **被测性质**：`looper` 录制时 **⛔ 不录鼓**（`is_drum_i === 1'b1` 的事件一条都不进 `mem`）
//
// 🔴 **缺陷（改前）**：录制写使能只看 `live_valid_i`
//    ⇒ ⚠️ 打鼓模式下的键盘事件（`top.v` 的 `key_drum_r`）被当成**音高事件**记进 loop
//    ⇒ 🔴 回放时按音高发出去 ⇒ 用户实测"**没开鼓机也听到鼓**"（⭐ 幽灵鼓机 ✅）
//    📌 设计依据：`files/20-代码/Looper详细设计.md`
//       *"⭐ 鼓 ⛔ 不占 looper 层 —— 它走**步进音序器**"* ✅
//
// ⭐ **非空洞性（本 tb 的全部意义）**：
//    ① `A1` 录制条数 —— 改前 = **4**（正常 ON/OFF + 鼓 ON/OFF），改后 = **2**
//    ② `A2` 回放里**不许出现**鼓的轴（⭐ 改前必然出现）
//    ③ `N1` **反向证伪**：正常音高的 ON/OFF 必须**还在**（⭐ 否则"全都不录"也能让 A1/A2 通过 ⇒ 探针假绿 ✅）
//    ⇒ ⭐ 实测流程：⭐ 先只加端口不接逻辑 ⇒ A1/A2 红；⭐ 再加 `&& !is_drum` ⇒ 全绿 ✅
//
// 📌 参数与 `top.v` 一致（⭐ `EVT_MAX` 缩小只为仿真快，⭐ 不影响语义）
`timescale 1ns/1ps
`define MAXW 6_000_000

module tb_looper_no_drum;

    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer KIND_W   = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer TICK_W   = 20;
    localparam integer CNT_W    = 16;
    localparam integer EVT_MAX  = 256;

    localparam [KIND_W-1:0] KIND_ON  = 2'd0;
    localparam [KIND_W-1:0] KIND_OFF = 2'd1;

    //  ⭐ 本 tb 用的两个音高：
    //     · ⭐ 正常音（轴 5）：`inc` 取一个明显**高于**鼓档的值
    //     · ⭐ 鼓    （轴 12）：`inc` 取**底鼓**档（⭐ 与生产口径一致，⛔ 不靠猜）
    localparam [PHASE_W-1:0] INC_NOTE = 32'h1000_0000;
    localparam [PHASE_W-1:0] INC_DRUM = 32'h0020_0000;
    localparam [AXIS_W-1:0]  AX_NOTE  = 4'd5;
    localparam [AXIS_W-1:0]  AX_DRUM  = 4'd12;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic chk;
        input        cond;
        input [1023:0] msg;
        begin
            if (cond === 1'b1) begin
                pass_cnt = pass_cnt + 1;
                $display("  ok  : %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    // ── DUT 端口 ─────────────────────────────────────────────────────────────
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg                   tick_i;
    reg  [TICK_W-1:0]     tick_cnt_i;
    reg                   bar_start_i;
    reg                   transport_i;

    reg                   live_valid_i;
    reg  [AXIS_W-1:0]     live_axis_i;
    reg  [PHASE_W-1:0]    live_inc_i;
    reg  [VEL_W-1:0]      live_vel_i;
    reg  [KIND_W-1:0]     live_kind_i;
    reg  [TIMBRE_W-1:0]   live_timbre_i;
    reg                   live_vel_valid_i;
    reg  [AXIS_W-1:0]     live_vel_axis_i;
    reg  [VEL_W-1:0]      live_vel_value_i;
    reg                   tb_is_drum;            // ⭐ 驱动 DUT 的 `is_drum_i`

    wire                  play_valid_o;
    wire [AXIS_W-1:0]     play_axis_o;
    wire [PHASE_W-1:0]    play_inc_o;
    wire [VEL_W-1:0]      play_vel_o;
    wire [KIND_W-1:0]     play_kind_o;
    wire [TIMBRE_W-1:0]   play_timbre_o;
    wire                  play_timbre_valid_o;
    wire                  play_upd_valid_o;
    wire [AXIS_W-1:0]     play_upd_axis_o;
    wire [PHASE_W-1:0]    play_upd_inc_o;
    wire [VEL_W-1:0]      play_upd_vel_o;

    reg  [0:0]            rec_req_i;
    reg  [0:0]            stop_req_i;
    reg  [0:0]            play_en_i;
    reg  [0:0]            clear_req_i;

    wire [0:0]            layer_state_o;
    wire                  rec_pending_o;
    wire [15:0]           evt_cnt_flat_o;
    wire [0:0]            full_o;
    wire [15:0]           drop_cnt_o;
    wire                  overflow_o;

    reg                   dump_en_i;
    reg  [CNT_W-1:0]      dump_addr_i;
    wire [63:0]           dump_data_o;
    wire                  dump_clip_o;

    looper #(
        .AXIS_W  (AXIS_W),
        .PHASE_W (PHASE_W),
        .VEL_W   (VEL_W),
        .KIND_W  (KIND_W),
        .TIMBRE_W(TIMBRE_W),
        .TICK_W  (TICK_W),
        .LAYERS  (1),
        .EVT_MAX (EVT_MAX),
        .CNT_W   (CNT_W)
    ) dut (
        .clk_i            (clk),
        .rst_n_i          (rst_n),
        .tick_i           (tick_i),
        .tick_cnt_i       (tick_cnt_i),
        .bar_start_i      (bar_start_i),
        .transport_i      (transport_i),
        .live_valid_i     (live_valid_i),
        .live_axis_i      (live_axis_i),
        .live_inc_i       (live_inc_i),
        .live_vel_i       (live_vel_i),
        .live_kind_i      (live_kind_i),
        .live_timbre_i    (live_timbre_i),
        //  ⭐⭐ 本 tb 的主角（⭐ 改前它被 DUT 完全忽略 ⇒ A1/A2 必红）
        .is_drum_i        (tb_is_drum),
        .live_vel_valid_i (live_vel_valid_i),
        .live_vel_axis_i  (live_vel_axis_i),
        .live_vel_value_i (live_vel_value_i),
        .play_valid_o     (play_valid_o),
        .play_axis_o      (play_axis_o),
        .play_inc_o       (play_inc_o),
        .play_vel_o       (play_vel_o),
        .play_kind_o      (play_kind_o),
        .play_timbre_o    (play_timbre_o),
        .play_timbre_valid_o(play_timbre_valid_o),
        .play_upd_valid_o (play_upd_valid_o),
        .play_upd_axis_o  (play_upd_axis_o),
        .play_upd_inc_o   (play_upd_inc_o),
        .play_upd_vel_o   (play_upd_vel_o),
        .rec_req_i        (rec_req_i),
        .stop_req_i       (stop_req_i),
        .play_en_i        (play_en_i),
        .clear_req_i      (clear_req_i),
        .layer_state_o    (layer_state_o),
        .rec_pending_o    (rec_pending_o),
        .evt_cnt_flat_o   (evt_cnt_flat_o),
        .full_o           (full_o),
        .drop_cnt_o       (drop_cnt_o),
        .overflow_o       (overflow_o),
        .dump_en_i        (dump_en_i),
        .dump_addr_i      (dump_addr_i),
        .dump_data_o      (dump_data_o),
        .dump_clip_o      (dump_clip_o)
    );

    // ── 驱动小任务（⭐ 与 `tb_looper.sv` 同一套 ✅）────────────────────────────
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

    //  ⭐ **带 `is_drum` 的事件注入**（⭐ 单拍脉冲，⭐ 与 `tb_looper.sv` 的 `live_evt` 同形）
    task automatic live_evt;
        input [KIND_W-1:0]  kd;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vl;
        input               drum;        // ⭐ 1 = 本条是鼓
        begin
            @(negedge clk);
            live_valid_i = 1'b1; live_kind_i = kd; live_axis_i = ax;
            live_inc_i = inc;    live_vel_i = vl;
            tb_is_drum = drum;
            @(negedge clk);
            live_valid_i = 1'b0;
            tb_is_drum   = 1'b0;
        end
    endtask

    task automatic pulse_rec;  begin @(negedge clk); rec_req_i  = 1'b1; @(negedge clk); rec_req_i  = 1'b0; end endtask
    task automatic pulse_stop; begin @(negedge clk); stop_req_i = 1'b1; @(negedge clk); stop_req_i = 1'b0; end endtask
    task automatic pulse_clr;  begin @(negedge clk); clear_req_i= 1'b1; @(negedge clk); clear_req_i= 1'b0; end endtask

    // ── 回放采集 ─────────────────────────────────────────────────────────────
    //  ⭐ 只数"**轴 12（鼓）**"与"**正常 ON / 正常 OFF**"三类 —— ⭐ 够判定，⛔ 不堆代码
    integer n_play_ax12;
    integer n_play_on_note;
    integer n_play_off_note;

    always @(posedge clk) begin
        if (rst_n && (play_valid_o === 1'b1)) begin
            if (play_axis_o == AX_DRUM)
                n_play_ax12 = n_play_ax12 + 1;
            else if ((play_axis_o == AX_NOTE) && (play_kind_o == KIND_ON))
                n_play_on_note = n_play_on_note + 1;
            else if ((play_axis_o == AX_NOTE) && (play_kind_o == KIND_OFF))
                n_play_off_note = n_play_off_note + 1;
        end
    end

    integer cnt_after_rec;

    initial begin
        tick_i = 1'b0; tick_cnt_i = {TICK_W{1'b0}};
        bar_start_i = 1'b0; transport_i = 1'b0;
        live_valid_i = 1'b0; live_axis_i = {AXIS_W{1'b0}};
        live_inc_i = {PHASE_W{1'b0}}; live_vel_i = {VEL_W{1'b0}};
        live_kind_i = KIND_ON; live_timbre_i = {TIMBRE_W{1'b0}};
        tb_is_drum = 1'b0;
        live_vel_valid_i = 1'b0;
        live_vel_axis_i  = {AXIS_W{1'b0}};
        live_vel_value_i = {VEL_W{1'b0}};
        rec_req_i = 1'b0; stop_req_i = 1'b0; play_en_i = 1'b0; clear_req_i = 1'b0;
        dump_en_i = 1'b0; dump_addr_i = {CNT_W{1'b0}};
        n_play_ax12 = 0; n_play_on_note = 0; n_play_off_note = 0;

        $display("=== tb_looper_no_drum (鼓不进 loop) ===");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════════
        // 录制：⭐ 交替注入「正常音」与「鼓」
        //    tick 2 : ON  ax 5  （正常，is_drum=0）
        //    tick 3 : ON  ax12  （⭐ 鼓，is_drum=1）
        //    tick 4 : OFF ax12  （⭐ 鼓，is_drum=1）
        //    tick 6 : OFF ax 5  （正常，is_drum=0）
        //    ⭐ 预期（改后）：`mem` 里**只有 2 条**（ax5 的 ON 与 OFF）
        //    🔴 改前：4 条（鼓的两条也进去了）
        // ══════════════════════════════════════════════════════════════════
        $display("== 1: record a normal note AND a drum ==");
        pulse_rec;
        idle_ticks(1);                                   // ← tick 0
        do_tick;                                         // ← tick 1
        live_evt(KIND_ON,  AX_NOTE, INC_NOTE, 8'd100, 1'b0);
        do_tick;                                         // ← tick 2 完成
        live_evt(KIND_ON,  AX_DRUM, INC_DRUM, 8'd200, 1'b1);
        do_tick;                                         // ← tick 3
        live_evt(KIND_OFF, AX_DRUM, INC_DRUM, 8'd200, 1'b1);
        do_tick;                                         // ← tick 4
        do_tick;                                         // ← tick 5
        live_evt(KIND_OFF, AX_NOTE, INC_NOTE, 8'd100, 1'b0);
        idle_ticks(2);
        pulse_stop;
        repeat (40) @(negedge clk);

        cnt_after_rec = evt_cnt_flat_o;
        $display("  info: recorded event count = %0d (expect 2)", cnt_after_rec);

        chk(cnt_after_rec == 16'd2,
            "A1 the drum's note_on AND note_off are NOT recorded (count stays 2, was 4)");

        // ══════════════════════════════════════════════════════════════════
        // 回放：⭐ 让 loop 跑若干圈，收集 `play_*`
        // ══════════════════════════════════════════════════════════════════
        $display("== 2: replay and look for drum events ==");
        transport_i = 1'b1;
        play_en_i   = 1'b1;
        idle_ticks(40);
        play_en_i   = 1'b0;
        repeat (20) @(negedge clk);

        $display("  info: played ax12=%0d  ax5-on=%0d  ax5-off=%0d",
                 n_play_ax12, n_play_on_note, n_play_off_note);

        chk(n_play_ax12 == 0,
            "A2 REPLAY CONTAINS NO DRUM EVENT (axis 12 never comes back) *** the whole point ***");

        //  ⭐⭐ **反向证伪**（⭐ `C83`：⛔ 不许"全都不录"也能过）
        chk(n_play_on_note >= 1,
            "N1 (NON-VACUOUS) the normal note_on IS still recorded and replayed");
        chk(n_play_off_note >= 1,
            "N2 (NON-VACUOUS) the normal note_off IS still recorded and replayed");

        //  ⭐ ③ 再录一遍（⭐ 只有鼓）⇒ 条数必须是 **0**
        //     🔴 改前 = 2；⭐ 这是对 A1 的**第二条独立证据** ✅
        $display("== 3: record a drum ONLY ==");
        pulse_clr;
        repeat (10) @(negedge clk);
        transport_i = 1'b0;
        pulse_rec;
        idle_ticks(1);
        live_evt(KIND_ON,  AX_DRUM, INC_DRUM, 8'd200, 1'b1);
        idle_ticks(2);
        live_evt(KIND_OFF, AX_DRUM, INC_DRUM, 8'd200, 1'b1);
        idle_ticks(2);
        pulse_stop;
        repeat (40) @(negedge clk);
        chk(evt_cnt_flat_o == 16'd0,
            "A3 a recording that contains ONLY drums ends up empty (0 events, was 2)");

        if (fail_cnt == 0)
            $display("PASS: tb_looper_no_drum -- drums never enter the loop, normal notes still do");
        else
            $display("FAIL: tb_looper_no_drum -- %0d check(s) failed", fail_cnt);
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: tb_looper_no_drum timeout");
        $finish;
    end

endmodule
