`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_play_seq.sv · `play_seq` 验收（`U-18`）
//
// ⭐ 判据见 `files/20-代码/play_seq接口冻结契约.md` §四
// ⭐ 原则（`K-56`/`C21`）：**每条判据都必须能失败**；⭐ 写成【不变量】（`C44`）
//
//   ⭐⭐ 本版新增三条，针对**实测发现的三个真缺陷**：
//   ⑦ ⭐⭐ **同一个 tick 上的多条必须在【该 tick 内】发完**
//      🔴 旧版每 tick 只取一条 ⇒ 实测一个 tick 最多 24 条（和弦）
//         ⇒ @168 BPM **8.56 ms** ⇒ 🔴 **和弦被拉成琶音**
//   ⑧ ⭐⭐ **`note_valid_o` 与 `note_data_o` 必须【同拍】**（经验 `80 号` 同族）
//      🔴 旧版 valid 是寄存器、data 是组合直通 ⇒ **计数对、数据错**
//   ⑨ ⭐⭐ **`evt_rd_o` 必须能被标准同步 FIFO 正确握手**（⛔ 不发两遍同一条）
//      🔴 旧版 evt_rd 是寄存器 ⇒ 调用方来不及换数据 ⇒ **同一条发两次**
//
//   ① 单速 tick 间隔（⚠️ 小数分频 ⇒ 只许 {floor,ceil}）
//   ② 变速每段间隔  ③ 切换点        ④ tick_inc=0 被拒
//   ⑤ kind 分流      ⑥ underrun 可见
//
// ⚠️ 本 tb 用**真实 FIFO 模型**（`evt_rd` 下一拍推进 head）
//    ⛔ 不是手工反复写同一个值 —— ⭐ 那样测不出缺陷 ⑨，也会误报重复
// ─────────────────────────────────────────────────────────────────────────────

module tb_play_seq;

    localparam integer EVT_W = 64;
    localparam integer TICK_SH = 44, INC_SH = 23, AXIS_SH = 19,
                       VEL_SH = 11, KIND_SH = 9, TIMBRE_SH = 7;
    localparam [1:0] KIND_ON = 2'd0, KIND_OFF = 2'd1, KIND_TEMPO = 2'd2;

    localparam [31:0] INC_120 = 32'd164927;
    localparam [31:0] INC_60  = 32'd82463;
    localparam [31:0] INC_200 = 32'd274878;

    // ⚠️ `$time` 单位是 ns；一个 clk = 20 ns ⇒ 算 clk 数要 /20
    localparam integer NS_PER_CLK = 20;

    integer errors = 0;

    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz
    reg rst_n = 1'b0;

    // ── ⭐ 用【真】beat_gen（⛔ 不用桩）────────────────────────────────────
    reg         run     = 1'b0;
    reg         pos_rst = 1'b0;
    wire        tick, bar_start, beat, transport, wrap;
    wire [15:0] tick_cnt, bar_cnt;

    wire [31:0] ps_tick_inc;
    wire        evt_rd, note_valid, tempo_applied, underrun;
    wire [EVT_W-1:0] note_data;
    wire [15:0] evt_cnt, tempo_cnt;
    wire [19:0] cur_tick;

    beat_gen #(
        .PPQN(960), .BEATS_PER_BAR(4), .PHASE_W(32), .TICK_INC_W(32)
    ) u_beat (
        .clk_i(clk), .rst_n_i(rst_n), .run_i(run), .pos_reset_i(pos_rst),
        .tick_inc_i(ps_tick_inc), .tick_o(tick), .tick_cnt_o(tick_cnt),
        .bar_start_o(bar_start), .beat_o(beat), .transport_o(transport),
        .bar_cnt_o(bar_cnt), .tick_cnt_wrap_o(wrap)
    );

    // ══ ⭐⭐ 真实事件 FIFO 模型（⚠️ 这是缺陷 ⑨ 的探针）══════════════════════
    //   ⭐ 标准同步 FIFO：`rd` 为高的**下一个沿**推进 head
    //   ⚠️ 这正是"调用方"的真实行为 ⇒ `evt_rd` 若不是组合，会发两遍同一条
    localparam integer QDEPTH = 256;
    reg [EVT_W-1:0] q [0:QDEPTH-1];
    integer q_head, q_tail;
    wire q_empty = (q_head == q_tail);

    always @(posedge clk) begin
        if (!rst_n) begin
            q_head <= 0;
        end else if (evt_rd && !q_empty) begin
            q_head <= q_head + 1;          // ⭐ 标准 FIFO 语义
        end
    end

    wire evt_valid_i = ~q_empty;
    wire [EVT_W-1:0] evt_data_i = q[q_head];

    task q_push;
        input [EVT_W-1:0] w;
        begin
            q[q_tail] = w;
            q_tail = q_tail + 1;
        end
    endtask

    play_seq #(
        .EVT_W(EVT_W), .TICK_INC_DEFAULT(INC_120)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick), .run_i(run), .pos_reset_i(pos_rst),
        .tick_inc_o(ps_tick_inc),
        .evt_valid_i(evt_valid_i), .evt_data_i(evt_data_i), .evt_rd_o(evt_rd),
        .note_valid_o(note_valid), .note_data_o(note_data),
        .tempo_applied_o(tempo_applied), .evt_underrun_o(underrun),
        .evt_cnt_o(evt_cnt), .tempo_cnt_o(tempo_cnt), .cur_tick_o(cur_tick)
    );

    // ── A8 ─────────────────────────────────────────────────────────────────
    wire [127:0] a8_bundle = {ps_tick_inc, note_data, evt_cnt, tempo_cnt, cur_tick};
    wire [31:0] a8_err;
    chk_xprop #(.W(128), .NAME("play_seq_bundle")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig(a8_bundle), .err_cnt(a8_err)
    );

    function [63:0] mk_event;
        input [19:0] tk;
        input [20:0] inc;
        input [3:0]  ax;
        input [7:0]  vl;
        input [1:0]  kd;
        input [1:0]  tb;
        begin
            mk_event = {tk, inc, ax, vl, kd, tb, 7'd0};
        end
    endfunction

    // ── tick 间隔测量 ──────────────────────────────────────────────────────
    integer gap_min, gap_max, gap_cnt, last_tick_t;
    reg     measuring = 1'b0;

    always @(posedge clk) begin
        if (measuring && tick) begin
            if (gap_cnt > 0) begin
                if ((($time - last_tick_t) / NS_PER_CLK) < gap_min)
                    gap_min = ($time - last_tick_t) / NS_PER_CLK;
                if ((($time - last_tick_t) / NS_PER_CLK) > gap_max)
                    gap_max = ($time - last_tick_t) / NS_PER_CLK;
            end
            last_tick_t = $time;
            gap_cnt = gap_cnt + 1;
        end
    end

    task start_measure;
        begin
            gap_min = 1000000000; gap_max = 0; gap_cnt = 0;
            last_tick_t = $time; measuring = 1'b1;
        end
    endtask
    task stop_measure;
        begin measuring = 1'b0; end
    endtask

    function integer theory_lo; input [31:0] inc;
        begin theory_lo = 4294967296 / inc; end
    endfunction
    function integer theory_hi; input [31:0] inc;
        begin theory_hi = (4294967296 + inc - 1) / inc; end
    endfunction

    // ── ⚠️ 声明在使用之前（Verilog-2001）──────────────────────────────────
    integer i, k;
    reg [63:0] w;

    // ⭐⭐ 缺陷 ⑧ 的探针：`note_valid_o` 与 `note_data_o` **同拍**
    //   ⚠️ 采样点在**沿之后**（⭐ 观测寄存器输出必须在沿后，经验 `85 号`）
    // Probe tracks NOTE events only.
    // First version used the all-events queue: tempo events never raise
    // note_valid, so the first note was compared against exp_q[0] (a tempo)
    // -> guaranteed mismatch -> a FALSE failure (probe bug, not DUT bug).
    reg [63:0] note_exp [0:QDEPTH-1];
    integer    note_exp_head, note_exp_tail;
    reg [63:0] exp_q [0:QDEPTH-1];
    integer    exp_head;
    integer    nv_checked, nv_ok;
    always @(posedge clk) begin
        #1;
        if (rst_n && note_valid) begin
            nv_checked = nv_checked + 1;
            // ⭐ 本拍报的数据，必须等于"本拍 FIFO 头那条"
            //    ⚠️ 旧版 data 组合直通 ⇒ head 已被推进 ⇒ 报的是**下一条**
            if (note_data === note_exp[note_exp_head]) nv_ok = nv_ok + 1;
            note_exp_head = note_exp_head + 1;
        end
    end

    // ⚠️ Verilog-2001: named begin/end blocks are NOT a declaration scope
    //    (⛔ only SystemVerilog allows that) -> all block vars live at module scope.
    integer th_lo, th_hi, kk, ticks_used, n_before;

    integer total_pushed;

    // Real invariant probe for defect 7.
    // Counting full ticks was too coarse: dropping the tick compare lets the
    // DUT emit every CLOCK (far too early) and the tick count stays 0, so the
    // criterion still passed.  Assert the position relationship instead.
    integer early_cnt;
    always @(posedge clk) begin
        #1;
        // note_valid / note_data / cur_tick_o are all REGISTERED outputs
        // latched on the same edge -> they belong to the same pipeline stage.
        if (rst_n && note_valid) begin
            if (cur_tick < note_data[TICK_SH +: 20]) early_cnt = early_cnt + 1;
        end
    end

    // Push a NOTE event (also records it in the note expectation queue).
    task q_push_note;
        input [EVT_W-1:0] ww;
        begin
            q_push(ww);
            note_exp[note_exp_tail] = ww;
            note_exp_tail = note_exp_tail + 1;
            total_pushed = total_pushed + 1;
        end
    endtask

    initial begin
        $dumpfile("build/sim/play_seq/tb_play_seq.vcd");
        $dumpvars(0, tb_play_seq);

        q_head = 0; q_tail = 0; exp_head = 0;
        note_exp_head = 0; note_exp_tail = 0;
        early_cnt = 0;
        nv_checked = 0; nv_ok = 0; total_pushed = 0;

        rst_n = 1'b0; run = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ══ 判据 ④a：复位默认 tick_inc ≠ 0 ════════════════════════════════
        if (ps_tick_inc !== INC_120) begin
            $display("FAIL: reset default tick_inc = %0d, expected %0d", ps_tick_inc, INC_120);
            errors = errors + 1;
        end else
            $display("  ok  : reset default tick_inc = %0d (120 BPM, not 0)", ps_tick_inc);

        // ══ 判据 ⑥：空缓冲 ⇒ underrun 必须报 ═════════════════════════════
        run = 1'b1;
        for (i = 0; i < 200000 && !underrun; i = i + 1) @(posedge clk);
        if (!underrun) begin
            $display("FAIL: evt_underrun_o never asserted with an empty buffer");
            errors = errors + 1;
        end else
            $display("  ok  : evt_underrun_o asserts when the buffer is empty");

        // ══ 判据 ①②③：变速 120 -> 60 -> 200 ═══════════════════════════════
        pos_rst = 1'b1; @(posedge clk); @(posedge clk); pos_rst = 1'b0;
        repeat (5) @(posedge clk);
        start_measure;
        repeat (300000) @(posedge clk);
        stop_measure;
        begin : seg1
            th_lo = theory_lo(INC_120); th_hi = theory_hi(INC_120);
            if (gap_cnt < 8) begin
                $display("FAIL: only %0d ticks at 120 BPM -- vacuous?", gap_cnt);
                errors = errors + 1;
            end
            if (gap_min < th_lo || gap_max > th_hi) begin
                $display("FAIL: segment1 (120 BPM) gap [%0d,%0d] allowed {%0d,%0d}",
                         gap_min, gap_max, th_lo, th_hi);
                errors = errors + 1;
            end else
                $display("  ok  : segment1 = 120 BPM, gap [%0d,%0d] ok", gap_min, gap_max);
        end

        // ⭐ 换速事件：tick 填 0（⭐ 早就该发 ⇒ 立即生效）
        w = mk_event(20'd0, INC_60[20:0], 4'd0, 8'd0, KIND_TEMPO, 2'd0);
        q_push(w); exp_q[exp_head] = w; exp_head = exp_head + 1; total_pushed = total_pushed + 1;
        wait (tempo_cnt == 16'd1);
        if (ps_tick_inc !== INC_60) begin
            $display("FAIL: tempo change to 60 BPM not applied (tick_inc=%0d)", ps_tick_inc);
            errors = errors + 1;
        end
        repeat (3) @(posedge clk);
        start_measure;
        repeat (600000) @(posedge clk);
        stop_measure;
        begin : seg2
            th_lo = theory_lo(INC_60); th_hi = theory_hi(INC_60);
            if (gap_cnt < 5) begin
                $display("FAIL: only %0d ticks at 60 BPM", gap_cnt);
                errors = errors + 1;
            end
            if (gap_min < th_lo || gap_max > th_hi) begin
                $display("FAIL: segment2 (60 BPM) gap [%0d,%0d] allowed {%0d,%0d}",
                         gap_min, gap_max, th_lo, th_hi);
                errors = errors + 1;
            end else
                $display("  ok  : segment2 = 60 BPM, gap [%0d,%0d] ok", gap_min, gap_max);
        end

        w = mk_event(20'd0, INC_200[20:0], 4'd0, 8'd0, KIND_TEMPO, 2'd0);
        q_push(w); exp_q[exp_head] = w; exp_head = exp_head + 1; total_pushed = total_pushed + 1;
        wait (tempo_cnt == 16'd2);
        if (ps_tick_inc !== INC_200) begin
            $display("FAIL: tempo change to 200 BPM not applied");
            errors = errors + 1;
        end
        repeat (3) @(posedge clk);
        start_measure;
        repeat (400000) @(posedge clk);
        stop_measure;
        begin : seg3
            th_lo = theory_lo(INC_200); th_hi = theory_hi(INC_200);
            if (gap_min < th_lo || gap_max > th_hi) begin
                $display("FAIL: segment3 (200 BPM) gap [%0d,%0d] allowed {%0d,%0d}",
                         gap_min, gap_max, th_lo, th_hi);
                errors = errors + 1;
            end else
                $display("  ok  : segment3 = 200 BPM, gap [%0d,%0d] ok", gap_min, gap_max);
        end

        // ══ 判据 ④b：tick_inc=0 被拒绝 ═══════════════════════════════════
        w = mk_event(20'd0, 21'd0, 4'd0, 8'd0, KIND_TEMPO, 2'd0);
        q_push(w); exp_q[exp_head] = w; exp_head = exp_head + 1; total_pushed = total_pushed + 1;
        repeat (200) @(posedge clk);
        if (ps_tick_inc === 32'd0) begin
            $display("FAIL: tick_inc_o became 0 -- the clock would stand still");
            errors = errors + 1;
        end else
            $display("  ok  : tick_inc=0 REJECTED, tick_inc_o stays %0d", ps_tick_inc);
        if (tempo_cnt !== 16'd2) begin
            $display("FAIL: tempo_cnt_o = %0d, expected 2 (the zero change must NOT count)",
                     tempo_cnt);
            errors = errors + 1;
        end else
            $display("  ok  : tempo_cnt_o = 2 (the rejected zero tempo not counted)");

        // ══ 判据 ⑦：⭐⭐ 同一 tick 的 8 条必须在【该 tick 内】发完 ═════════
        begin : burst
            n_before = evt_cnt;
            // ⭐ 等一个 tick 边界，把 8 条都标成"下一拍就到"
            for (i = 0; i < 400000 && !tick; i = i + 1) @(posedge clk);
            @(negedge clk);
            for (kk = 0; kk < 8; kk = kk + 1) begin
                w = mk_event(cur_tick + 20'd1, (21'd2000 + kk), kk[3:0],
                             8'd100, KIND_ON, 2'd0);
                q_push_note(w);
            end
            // ⭐ 从这里开始数 tick，直到 8 条都发完
            ticks_used = 0;
            while ((evt_cnt - n_before) < 8) begin
                @(posedge clk);
                if (tick) ticks_used = ticks_used + 1;
                if (ticks_used > 20) begin
                    $display("FAIL: burst never completed (only %0d of 8)", evt_cnt - n_before);
                    errors = errors + 1;
                    disable burst;
                end
            end
            // ⭐ 判据：消耗的**整拍数**必须 ≤ 1
            //   ⚠️ 旧版（每 tick 一条）会消耗 8 个 ⇒ 这条当场红
            if (ticks_used > 1) begin
                $display("FAIL: 8 same-tick events consumed %0d full ticks (must be <= 1) -- chord becomes an arpeggio",
                         ticks_used);
                errors = errors + 1;
            end else
                $display("  ok  : 8 same-tick events all emitted within %0d tick (no arpeggio)",
                         ticks_used);
        end

        // NOTE: the criterion above counts TICKS, which is too coarse on its own:
        // removing the tick compare makes the DUT emit every clock (far too early)
        // and ticks_used stays 0, so it still passed.  Assert the invariant too.
        if (early_cnt != 0) begin
            $display("FAIL: %0d event(s) emitted BEFORE their own tick (cur_tick < evt.tick) -- position check missing",
                     early_cnt);
            errors = errors + 1;
        end else
            $display("  ok  : no event emitted before its own tick (position invariant holds)");


        repeat (4000) @(posedge clk);   // ⭐ 让剩下的都流完

        // ══ 判据 ⑧：⭐⭐ valid 与 data 同拍 ═══════════════════════════════
        if (nv_checked < 8) begin
            $display("FAIL: same-beat probe saw only %0d notes -- vacuous?", nv_checked);
            errors = errors + 1;
        end else if (nv_ok != nv_checked) begin
            $display("FAIL: note_valid_o and note_data_o NOT the same beat (%0d/%0d)",
                     nv_ok, nv_checked);
            errors = errors + 1;
        end else
            $display("  ok  : note_valid_o and note_data_o same beat (%0d/%0d)", nv_ok, nv_checked);

        // ══ 判据 ⑨：⭐⭐ evt_rd 能被标准 FIFO 正确握手（⛔ 不发两遍）════════
        //   ⭐ 判据：`evt_cnt` 必须**正好等于** push 过的条数（⛔ 不能多也不能少）
        //   ⚠️ 旧版 evt_rd 是寄存器 ⇒ 同一条发两次 ⇒ evt_cnt 会**多出来**
        if (evt_cnt > total_pushed) begin
            $display("FAIL: evt_cnt_o = %0d > %0d pushed -- an event was read TWICE (handshake broken)",
                     evt_cnt, total_pushed);
            errors = errors + 1;
        end else if (evt_cnt < total_pushed) begin
            $display("FAIL: evt_cnt_o = %0d < %0d pushed -- an event was never emitted",
                     evt_cnt, total_pushed);
            errors = errors + 1;
        end else
            $display("  ok  : evt_cnt_o = %0d = pushed events (no double-read, none lost)",
                     evt_cnt);

        // ══ 判据：run=0 时【即使有人为 tick】也不取事件 ═════════════════════
        //   ⚠️ 必须人为注入 tick（⭐ `run=0` 时 beat_gen 自己也不出 tick，
        //      否则测的是 beat_gen 的门，⛔ 不是 play_seq 的 —— 经验 `C36`）

        // ===== Criterion: a FORWARD-DATED event must NOT be emitted early =====
        // The burst above used tick = cur_tick + 1, which the DUT reaches in the
        // very cycle it advances, so a DUT that ignores the tick field altogether
        // still looked correct there.  Date an event clearly in the FUTURE:
        //   correct DUT -> silent until the position arrives
        //   tick-compare removed -> emitted immediately (early)
        begin : not_early
            integer before_cnt, waited;
            for (i = 0; i < 400000 && !tick; i = i + 1) @(posedge clk);
            @(negedge clk);
            before_cnt = evt_cnt;
            w = mk_event(cur_tick + 20'd10, 21'd4444, 4'd3, 8'd100, KIND_ON, 2'd0);
            q_push_note(w);
            // Wait 5 ticks: nothing must come out yet
            waited = 0;
            while (waited < 5) begin
                @(posedge clk);
                if (tick) waited = waited + 1;
            end
            if (evt_cnt != before_cnt) begin
                $display("FAIL: a forward-dated event (tick=cur+10) was emitted after only %0d ticks -- tick compare ignored",
                         waited);
                errors = errors + 1;
            end else
                $display("  ok  : forward-dated event held back for %0d ticks (not emitted early)", waited);
            // Now let it arrive
            while (evt_cnt == before_cnt) begin
                @(posedge clk);
                if (i > 900000) begin
                    $display("FAIL: forward-dated event never emitted");
                    errors = errors + 1;
                    disable not_early;
                end
                i = i + 1;
            end
            @(negedge clk);
        end


        run = 1'b0;
        repeat (5) @(posedge clk);
        begin : stopped
            n_before = evt_cnt;
            w = mk_event(20'd0, 21'd3333, 4'd2, 8'd120, KIND_ON, 2'd0);
            q_push(w);
            for (i = 0; i < 3; i = i + 1) begin
                force tick = 1'b1;
                @(posedge clk);
                force tick = 1'b0;
                @(posedge clk);
            end
            if (evt_cnt !== n_before) begin
                $display("FAIL: events consumed while run_i=0 even with injected ticks");
                errors = errors + 1;
            end else
                $display("  ok  : no events consumed while run_i=0 (gate really works)");
        end
        release tick;
        run = 1'b1;
        repeat (5) @(posedge clk);

        // ══ A8 ════════════════════════════════════════════════════════════
        repeat (10) @(posedge clk);
        if (a8_err != 0) begin
            $display("FAIL: A8 X/Z propagation (%0d)", a8_err);
            errors = errors + 1;
        end else
            $display("  ok  : A8 no X/Z on play_seq outputs");

        if (errors == 0)
            $display("PASS: play_seq emits every due event (whole chord within one tick), latches data with valid, handshakes a standard FIFO once, applies tempo, rejects tick_inc=0, reports underrun");
        else
            $display("FAIL: play_seq had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`）
    initial begin
        #900_000_000;
        $fatal(1, "FAIL: tb_play_seq timeout");
    end

endmodule
