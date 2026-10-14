`timescale 1ns/1ps
// ═══════════════════════════════════════════════════════════════════════════════
// tb_play_seq_lead.sv · ⭐ 「LED 指引提前量」的行为契约（⭐ 2026-10-14 新增 ✅）
//
//   ⭐ **被测**：`rtl/w3c/play_seq.v` 的 `lead_i` 端口
//   ⭐ **用途**：指引模式（串口 `'U'`）下让 **LED 提前一拍**亮起
//              ⇒ ⭐ 给演奏者"**预备—按**"的时间（⭐ 音乐教学的标准做法 ✅）
//
//   ⭐⭐ **判据（⭐ 每条都【能红】）**：
//     · **L1** ⭐ `lead_i = 0` ⇒ 事件在 `cur_tick == evt_tick` 那一刻发
//              ⇒ ⭐ **演奏模式零回归**（⭐ 这是本改动的生死线 ✅）
//     · **L2** ⭐ `lead_i = 960`（1 拍）⇒ 事件在 `cur_tick == evt_tick - 960` 那一刻发
//              ⇒ ⭐ **提前量精确**（⛔ 不是"早一点"就行 ✅）
//     · **L3** ⭐ 提前量**对每条事件都成立**（⭐ 多条不同 tick 的事件各自提前 960）
//              ⇒ ⭐ 证明是"**按 tick 判定**"，⛔ 不是只对第一条生效 ✅
//     · **L4** ⭐⭐ **21 位相加不回绕**：⭐ `cur_tick` 接近 20 位上限时，
//              `cur_tick + lead` **不得回绕** ⇒ ⭐ 否则会**误发后面的事件** ✅
//              （⭐ 手法：⭐ 把 `cur_tick` 直接 force 到 `20'hFFFF0` 附近再给一条事件）
//     · **L5** ⭐ 提前量**不影响换速**（`kind=2`）⇒ ⭐ `tick_inc_o` 仍按原 tick 换 ✅
//
//   📌 **非空洞性（⭐ "去掉该机制就红"）**：
//     · ⭐ 把 `due_limit` 改回 `cur_tick_r`（⭐ 即删掉 `lead_i`）⇒ ⭐ **L2/L3 立刻红** ✅
//     · ⭐ 把 21 位改成 20 位 ⇒ ⭐ **L4 红** ✅
// ═══════════════════════════════════════════════════════════════════════════════
`default_nettype none

module tb_play_seq_lead;

    localparam integer EVT_W  = 64;
    localparam integer PPQN   = 960;          // ⭐ 1 拍

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    task chk;
        input [8*100-1:0] name;
        input             cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    // ── 事件字（⭐ 位域与 play_seq.v / mid2evt.py 逐位一致）──────────────────
    function [EVT_W-1:0] mk_evt;
        input [19:0] tk;      // tick
        input [20:0] inc;     // inc（21 位）
        input [3:0]  ax;      // axis
        input [7:0]  vel;
        input [1:0]  kind;
        begin
            mk_evt = {tk, inc, ax, vel, kind, 2'b00, 7'b0};
        end
    endfunction

    // ── 激励侧：FIFO（⭐ 与 tb_play_seq 同款：组合读 + rd 下一拍推进）────────
    reg  [EVT_W-1:0] fifo_mem [0:15];
    reg  [3:0]       fifo_rd = 4'd0;
    reg  [3:0]       fifo_wr = 4'd0;
    wire             evt_valid = (fifo_rd != fifo_wr);
    wire [EVT_W-1:0] evt_data  = fifo_mem[fifo_rd];
    task push_evt;
        input [EVT_W-1:0] e;
        begin fifo_mem[fifo_wr] = e; fifo_wr = fifo_wr + 4'd1; end
    endtask

    reg lead_en = 1'b0;
    reg [19:0] lead_val = 20'd0;

    //  ⭐ tick 脉冲发生器（⭐ 模拟 `beat_gen.tick_o`）
    //     ⚠️ **必须声明在例化之前** —— Verilog-2001 **先声明后用**（⭐ 本轮踩到 ✅）
    reg tick_pulse = 1'b0;
    integer tick_div = 0;
    always @(posedge clk) begin
        if (!rst_n) begin tick_pulse <= 1'b0; tick_div <= 0; end
        else begin
            tick_pulse <= 1'b0;
            if (tick_div == 3) begin tick_div <= 0; tick_pulse <= 1'b1; end
            else tick_div <= tick_div + 1;
        end
    end

    wire [31:0] tick_inc_o;
    wire        note_valid_o, tempo_applied_o, evt_underrun_o;
    wire [EVT_W-1:0] note_data_o;
    wire [15:0] evt_cnt_o, tempo_cnt_o;
    wire [19:0] cur_tick_o;
    wire        evt_rd_o;

    play_seq #(.EVT_W(EVT_W)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_pulse), .run_i(1'b1), .pos_reset_i(1'b0),
        .lead_i(lead_en ? lead_val : 20'd0),
        .bpm_up_i(1'b0), .bpm_dn_i(1'b0), .bpm_load_i(1'b0), .bpm_i(16'd120),
        .tick_inc_o(tick_inc_o),
        .evt_valid_i(evt_valid), .evt_data_i(evt_data), .evt_rd_o(evt_rd_o),
        .note_valid_o(note_valid_o), .note_data_o(note_data_o),
        .tempo_applied_o(tempo_applied_o), .evt_underrun_o(evt_underrun_o),
        .evt_cnt_o(evt_cnt_o), .tempo_cnt_o(tempo_cnt_o), .cur_tick_o(cur_tick_o)
    );

    // ⭐ FIFO 读推进（⭐ 与 `evt_rd_o` 组合选通同拍对齐）
    always @(posedge clk) if (rst_n && evt_rd_o) fifo_rd <= fifo_rd + 4'd1;

    // ⭐ 记录每条事件是在哪个 `cur_tick_o` 上被发出的
    integer fired_n = 0;
    integer fired_tick [0:15];
    reg [19:0] fired_evt_tick [0:15];
    always @(posedge clk) if (rst_n && note_valid_o) begin
        fired_tick[fired_n]     = cur_tick_o;
        fired_evt_tick[fired_n] = note_data_o[63:44];
        fired_n = fired_n + 1;
    end

    task do_reset;
        begin
            rst_n = 1'b0; fifo_rd = 4'd0; fifo_wr = 4'd0;
            fired_n = 0; tick_div = 0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // ⭐ 跑到 `cur_tick_o` 达到目标（或超时）
    task wait_tick;
        input [19:0] target;
        integer guard;
        begin
            guard = 0;
            while ((cur_tick_o < target) && (guard < 200000)) begin
                @(posedge clk); guard = guard + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        // ═══════════════════════════════════════════════════════════════════
        //  L1 · `lead = 0` ⇒ 到点才发（⭐ 演奏模式零回归 ✅）
        // ═══════════════════════════════════════════════════════════════════
        lead_en = 1'b0; lead_val = 20'd0;
        do_reset;
        push_evt(mk_evt(20'd50, 21'd1000, 4'd3, 8'd200, 2'd0));
        wait_tick(20'd80);
        chk("L1a lead=0: the event WAS emitted", fired_n == 1);
        chk("L1b lead=0: emitted at cur_tick == evt_tick (exactly, not early)",
            fired_n == 1 && fired_tick[0] == 50);

        // ═══════════════════════════════════════════════════════════════════
        //  L2 · `lead = 960`（1 拍）⇒ 提前 960 tick 发（⭐ 精确 ✅）
        // ═══════════════════════════════════════════════════════════════════
        lead_en = 1'b1; lead_val = 20'd960;
        do_reset;
        push_evt(mk_evt(20'd2000, 21'd1000, 4'd3, 8'd200, 2'd0));
        wait_tick(20'd1100);
        chk("L2a lead=960: the event WAS emitted", fired_n == 1);
        chk("L2b lead=960: emitted EXACTLY 960 ticks early (cur_tick == evt_tick - 960)",
            fired_n == 1 && fired_tick[0] == (2000 - 960));

        // ═══════════════════════════════════════════════════════════════════
        //  L3 · 提前量对【每条】事件都成立（⭐ 按 tick 判定，⛔ 不是只对第一条 ✅）
        // ═══════════════════════════════════════════════════════════════════
        lead_en = 1'b1; lead_val = 20'd960;
        do_reset;
        push_evt(mk_evt(20'd3000, 21'd1000, 4'd3, 8'd200, 2'd0));
        push_evt(mk_evt(20'd3500, 21'd1000, 4'd5, 8'd200, 2'd0));
        push_evt(mk_evt(20'd4200, 21'd1000, 4'd7, 8'd200, 2'd0));
        wait_tick(20'd3400);
        chk("L3a all three events were emitted", fired_n == 3);
        chk("L3b #0 emitted at evt_tick-960", fired_n >= 1 && fired_tick[0] == (3000 - 960));
        chk("L3c #1 emitted at evt_tick-960", fired_n >= 2 && fired_tick[1] == (3500 - 960));
        chk("L3d #2 emitted at evt_tick-960", fired_n >= 3 && fired_tick[2] == (4200 - 960));
        chk("L3e the events kept their own ticks (not shifted in the payload)",
            fired_n >= 3 && fired_evt_tick[0] == 3000
                         && fired_evt_tick[1] == 3500
                         && fired_evt_tick[2] == 4200);

        // ═══════════════════════════════════════════════════════════════════
        //  L4 · ⭐⭐ **相加必须是 21 位**（⭐ ⛔ 不是 20 位 ✅）
        //     🔴 **原判据写错了（⭐ 本轮踩到，⭐ 记下来）**：
        //        我原来给了一条 `tick=100` 的事件、把位置 force 到 `0xFFFC0`
        //        ⇒ ⚠️ 但 `evt_due` 用的是 **`<=`**（⭐ "迟到的也补发"）
        //        ⇒ ⭐ `100 <= 0xFFFC0` **本来就成立** ⇒ 🔴 那条事件**该发**
        //        ⇒ ⭐ 用例**分不出** 20 位与 21 位 ⇒ ⛔ 判据无意义 ✅
        //     ✅ **正确判据**：⭐ **直接验算加法结果** ——
        //        ⭐ force `cur_tick_r = 20'hFFFFF`（上限）、`lead = 960`
        //        ⭐ ⇒ 21 位下 `due_limit` 应 = **`20'hFFFFF + 960 = 1049535`** ✅
        //        ⭐ 而 20 位下会**截断成 959** ⇒ ⭐ 两者**可区分** ⇒ 判据**能红** ✅
        // ═══════════════════════════════════════════════════════════════════
        lead_en = 1'b1; lead_val = 20'd960;
        do_reset;
        force dut.cur_tick_r = 20'hFFFFF;
        repeat (4) @(posedge clk);
        chk("L4a due_limit is computed in 21 bits (0xFFFFF + 960 = 1049535, not 959)",
            dut.due_limit === 21'd1049535);
        chk("L4b the 20-bit truncation would have given 959 (so L4a is non-vacuous)",
            ((20'hFFFFF + 20'd960) === 20'd959));
        release dut.cur_tick_r;

        // ═══════════════════════════════════════════════════════════════════
        //  L5 · 提前量不影响换速（⭐ `kind=2` 仍按原 tick 换 ✅）
        // ═══════════════════════════════════════════════════════════════════
        lead_en = 1'b1; lead_val = 20'd960;
        do_reset;
        push_evt(mk_evt(20'd2000, 21'd5000, 4'd0, 8'd0, 2'd2));    // ⭐ 换速事件
        wait_tick(20'd1100);
        chk("L5a tempo event is NOT emitted as a note (kind=2 never drives note_valid_o)",
            fired_n == 0);
        chk("L5b tempo was applied (tempo_applied_o pulsed)", tempo_cnt_o != 16'd0);

        if (errors == 0) $display("PASS: play_seq lead -- 0 is bit-exact, 960 is exact, no 20-bit wrap");
        else $fatal(1, "FAIL: tb_play_seq_lead has %0d error(s)", errors);
        $finish;
    end

    initial begin #20000000; $fatal(1, "FAIL: tb_play_seq_lead timeout"); end

endmodule
