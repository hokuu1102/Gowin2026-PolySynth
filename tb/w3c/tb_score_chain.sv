// ─────────────────────────────────────────────────────────────────────────────
// tb_score_chain.sv · ⭐ **曲谱链路的集成判据**（`U-19` 缓冲 ＋ `play_seq`）
//
// ⭐ **为什么必须单独建它**（⭐ 这是 2026-10-11 那次改动的**核心风险点**）：
//    ⭐ 改动把曲谱源从"**裸 UART 直连 `seq_arb`**"换成了
//       `evt_uart_rx ⇒ u_evt_buf ⇒ u_play_seq ⇒ seq_arb.score` ✅
//    🔴 **而全项目【没有任何 tb】端到端跑过这条链**（⭐ 实测：
//       ⭐ 用 `0xA5` 的 tb 全是**模块级**的 —— `tb_evt_uart_rx` / `tb_uart_calib_chain` /
//       `tb_evt_uart_rx_gate` / `tb_calib_cmd` / `tb_test_mode_top` ✅）
//    ⇒ 🔴 **接线错了（⭐ 握手反向 / 差一拍 / 丢一条）⇒ 没有任何判据会红** ✅
//    📌 ⭐ 而"丢事件"正是本项目**头号静默缺陷族**（⭐ `K-106` / `P0-29`）✅
//
// ⭐ **本 tb 打的就是那条【握手线】**：
//    ⭐ `evt_buf.rd_valid_o → play_seq.evt_valid_i`
//    ⭐ `play_seq.evt_rd_o  → evt_buf.rd_ack_i`
//    ⭐ `play_seq.tick_inc_o → (beat_gen.tick_inc_i)`
//    ⇒ ⭐ 用**真的两个模块**、⛔ 不用 FIFO 桩（⭐ `tb_play_seq` 用的是桩 ✅）
//
// ⭐ **判据清单**：
//    · ① ⭐⭐ **未来事件【不许提前发】**：⭐ tick=5/5/9 的三条，
//      在 tick 0..4 期间**一条都不许出来** ✅（⭐ 这是"缓冲真的在起作用"的判据 ✅）
//    · ② ⭐⭐ **同一 tick 的多条【必须都发完】**：⭐ tick=5 上的**两条**都在该 tick 内出来 ✅
//    · ③ ⭐ **逐条落在正确的 tick 上**：⭐ tick=5 出 2 条、⭐ tick=9 出 1 条 ✅
//    · ④ ⭐ **总数守恒**：⭐ `play_seq.evt_cnt_o == 3`（⭐ 一条不多、一条不少 ✅）
//    · ⑤ ⭐⭐ **`kind=2` 换速**：⭐ `tick_inc_o` 变成事件里的值，
//      ⭐ **且不产生任何音符**（⭐ `note_valid_o` 不许拉高 ✅）
//    · ⑥ ⭐ **缓冲溢出在这条链上也可观测**（⭐ 灌 10 条进 DEPTH=8 ⇒ `ovf` 置位 ✅）
//
// ⚠️ 时基：⭐ 激励一律在 `negedge` 改（⛔ 不与 DUT 的 `posedge` 竞争 ✅）
// ⚠️ `tick_i` 是**时钟使能式的单拍脉冲**（⭐ 与 `beat_gen.tick_o` 同口径 ✅）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_score_chain;

    localparam integer DEPTH = 8;
    //  ⭐ 位域（⭐ 与 `play_seq` / `guide_lamp` / `mid2evt.py` 逐位一致 ✅）
    localparam integer TICK_SH   = 44;
    localparam integer INC_SH    = 23;
    localparam integer AXIS_SH   = 19;
    localparam integer VEL_SH    = 11;
    localparam integer KIND_SH   = 9;
    localparam integer TIMBRE_SH = 7;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ── ⭐ 被测链（⭐ 真的两个模块 + 真的握手 ✅）──────────────────────────
    reg         wr_v;
    reg  [63:0] wr_d;
    wire        eb_rd_v;
    wire [63:0] eb_rd_d;
    wire        ps_rd;
    wire        ovf;
    wire [15:0] drop;
    wire [15:0] cnt;
    wire        low;

    evt_buf #(.DEPTH(DEPTH), .EVT_W(64), .LOW_WM(2)) u_buf (
        .clk_i(clk), .rst_n_i(rst_n),
        .wr_valid_i(wr_v), .wr_data_i(wr_d),
        .rd_valid_o(eb_rd_v), .rd_data_o(eb_rd_d), .rd_ack_i(ps_rd),
        .ovf_o(ovf), .drop_cnt_o(drop), .cnt_o(cnt), .low_o(low),
        .ovf_clr_i(1'b0)
    );

    reg         tick;
    reg         run;
    reg         pos_rst;
    wire [31:0] tick_inc;
    wire        note_v;
    wire [63:0] note_d;
    wire        tempo_ap;
    wire        underrun;
    wire [15:0] evt_cnt;
    wire [15:0] tempo_cnt;
    wire [19:0] cur_tick;

    play_seq #(.EVT_W(64)) u_seq (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick), .run_i(run), .pos_reset_i(pos_rst),
        .tick_inc_o(tick_inc),
        .evt_valid_i(eb_rd_v), .evt_data_i(eb_rd_d), .evt_rd_o(ps_rd),
        .note_valid_o(note_v), .note_data_o(note_d),
        .tempo_applied_o(tempo_ap), .evt_underrun_o(underrun),
        .evt_cnt_o(evt_cnt), .tempo_cnt_o(tempo_cnt), .cur_tick_o(cur_tick),
        //  ⭐ 2026-10-14：⭐ 新增 `lead_i` ⇒ **必须显式接 0**（⭐ 悬空 = Z ⇒ X 传播 ✅）
        .lead_i(20'd0)
    );

    // ── ⭐ 打点：⭐ 记录"第几个 tick 上出了哪条事件" ✅ ────────────────────
    localparam integer MAXF = 32;
    integer   fired_n;
    integer   fired_at [0:MAXF-1];      // ⭐ 出事件时的 `cur_tick_o`
    integer   fired_ax [0:MAXF-1];      // ⭐ 该事件的 axis
    integer   cur_tick_n;               // ⭐ 我们自己数的 tick 序号（⭐ 从 0 开始）

    always @(posedge clk) begin
        if (rst_n && note_v) begin
            if (fired_n < MAXF) begin
                fired_at[fired_n] = cur_tick;
                fired_ax[fired_n] = note_d[AXIS_SH +: 4];
                fired_n = fired_n + 1;
            end
        end
    end

    // ── ⭐ 事件打包（⭐ 与 `mid2evt.py` 的位域逐位一致 ✅）──────────────────
    function [63:0] pack;
        input [19:0] tk;
        input [20:0] inc;
        input [3:0]  ax;
        input [7:0]  vel;
        input [1:0]  knd;
        begin
            pack = {tk, inc, ax, vel, knd, 2'b00, 7'b0};
        end
    endfunction

    integer i;
    integer n_at5, n_at9, n_before5;
    integer tempo_seen;

    // ── ⭐ 走一个 tick（⭐ 单拍脉冲 + 给 `play_seq` 足够时间吐完本 tick 的事件）──
    task one_tick;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
            repeat (12) @(negedge clk);      // ⭐ 本 tick 内的事件**连续吐完** ✅
            cur_tick_n = cur_tick_n + 1;
        end
    endtask

    task push;
        input [63:0] v;
        begin
            @(negedge clk); wr_v = 1'b1; wr_d = v;
            @(negedge clk); wr_v = 1'b0;
        end
    endtask

    initial begin
        wr_v = 1'b0; wr_d = 64'd0; tick = 1'b0; run = 1'b1; pos_rst = 1'b0;
        fired_n = 0; cur_tick_n = 0; tempo_seen = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        $display("=== tb_score_chain (U-19 缓冲 + play_seq 的【握手链】) ===");
        $display("   play_seq 复位默认 tick_inc = %0d（⭐ 应为 120 BPM 的 164927）", tick_inc);
        chk(tick_inc === 32'd164927, "0a reset default tick_inc == 164927 (120 BPM)");

        // ═════════════════════════════════════════════════════════════════
        $display("== ①②③④ 未来事件不许提前发 / 同 tick 全发完 / 逐条落对 tick ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 三条事件：⭐ tick 5 上**两条**（⭐ 和弦）+ ⭐ tick 9 上一条 ✅
        push(pack(20'd5, 21'd1000000, 4'd1, 8'd200, 2'd0));
        push(pack(20'd5, 21'd1000001, 4'd2, 8'd200, 2'd0));
        push(pack(20'd9, 21'd1000002, 4'd3, 8'd200, 2'd0));
        @(negedge clk);
        chk(cnt === 16'd3, "1a all three events are buffered (cnt == 3)");
        chk(ovf === 1'b0, "1b no overflow for three events");

        //  ⚠️ **差一注意**：⭐ `cur_tick_r` 复位是 **0**，⭐ 而**第一个 `tick` 把它推到 1**
        //     ⇒ ⭐ 想停在 `cur_tick == 4` ⇒ ⭐ 必须只走 **4** 个 tick ✅
        //     （⭐ 实测：⭐ 走 5 个 ⇒ `cur_tick` 已经到 5 ⇒ 🔴 **tick=5 的事件已经发了** ✅）
        //  ⭐ tick 1..4：⭐ **一条都不许出来** ✅
        for (i = 0; i < 4; i = i + 1) one_tick;
        n_before5 = fired_n;
        chk(n_before5 == 0, "1c NO event fires before its tick (buffer really holds them)");

        //  ⭐ tick 5：⭐ 两条都出来 ✅
        one_tick;
        n_at5 = fired_n;
        chk(n_at5 == 2, "2a BOTH same-tick events fire within that one tick");
        chk((fired_ax[0] == 1) && (fired_ax[1] == 2), "2b the two same-tick axes are 1 and 2");
        chk((fired_at[0] == 5) && (fired_at[1] == 5), "2c both carry cur_tick == 5");

        //  ⭐ tick 6..8：⭐ 还不许出 ✅
        for (i = 0; i < 3; i = i + 1) one_tick;
        chk(fired_n == 2, "3a still nothing new before tick 9");

        //  ⭐ tick 9：⭐ 第 3 条 ✅
        one_tick;
        n_at9 = fired_n;
        chk(n_at9 == 3, "3b the tick-9 event fired");
        chk(fired_ax[2] == 3, "3c it is axis 3");
        chk(fired_at[2] == 9, "3d it carries cur_tick == 9");

        chk(evt_cnt === 16'd3, "4a evt_cnt == 3 (nothing lost, nothing duplicated)");
        chk(cnt === 16'd0, "4b the buffer drained to empty");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑤ kind=2 换速：⭐ 改速度 + ⭐ 不产生音符 ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 60 BPM 的 `tick_inc` = 82463（⭐ 契约 §1.3 的速查表 ✅）
        push(pack(20'd12, 21'd82463, 4'd0, 8'd0, 2'd2));
        @(negedge clk);
        for (i = 0; i < 4; i = i + 1) one_tick;     // ⭐ 走到 tick 12
        chk(tempo_ap === 1'b0, "5a tempo_applied_o is a 1-cycle pulse (already low here)");
        chk(tick_inc === 32'd82463, "5b tick_inc_o became the value from the kind=2 event");
        chk(tempo_cnt === 16'd1, "5c tempo_cnt_o == 1 (the change was really applied)");
        chk(fired_n == 3, "5d a kind=2 event produces NO note (note count still 3)");
        chk(evt_cnt === 16'd4, "5e evt_cnt counts it (4 events consumed)");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑥ 溢出在这条链上也可观测 ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ `DEPTH=8` ⇒ ⭐ 灌 9 条 ⇒ ⭐ 第 9 条必须被**留痕**丢弃 ✅
        for (i = 0; i < 9; i = i + 1)
            push(pack(20'd100, 21'd1000000 + i, 4'd0, 8'd100, 2'd0));
        @(negedge clk);
        chk(ovf === 1'b1, "6a overflow is sticky-visible on the chain");
        chk(drop === 16'd1, "6b drop_cnt == 1 (the 9th event was dropped, NOT silently)");
        chk(cnt === 16'd8, "6c buffer holds exactly DEPTH");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_score_chain - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_score_chain - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_score_chain TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
