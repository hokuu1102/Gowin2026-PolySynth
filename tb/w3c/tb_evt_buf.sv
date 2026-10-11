// ─────────────────────────────────────────────────────────────────────────────
// tb_evt_buf.sv · `U-19` 事件缓冲区验收（⭐ 2026-10-11 新建）
//
// ⭐ **为什么必须单独建判据**：
//    ⭐ `evt_buf` 是 `play_seq` 与 `evt_uart_rx` 之间**唯一**的一级缓冲
//    ⇒ 🔴 它错 ⇒ ⭐ **曲谱要么丢事件、要么顺序错、要么永远不响** ✅
//    ⚠️ 而"丢事件"在本项目里是**头号静默缺陷族**（⭐ `K-106` / `P0-29`）
//    ⇒ ⭐ 本 tb 的重点就是**把"丢/乱/卡"变成可红的判据** ✅
//
// ⭐ **判据清单（⭐ 每条都必须是"实现错了就红"）**：
//    · ① ⭐ **顺序与条数**：⭐ 灌 N 条 ⇒ 读出 N 条、⭐ **逐条值相同**、⭐ 第 N+1 次读**空** ✅
//    · ② ⭐⭐ **FWFT 无空隙**：⭐ 连续取走时 `rd_valid_o` **恒为 1**（⭐ 不许有 1 拍掉空）✅
//      —— 🔴 这一条**专抓"取走才发起读"那种写法**（⭐ 每取一条就空一拍）✅
//    · ③ ⭐ **满判据**：⭐ 灌 `DEPTH` 条 ⇒ `cnt == DEPTH`、⭐ `ovf_o == 0`（⭐ 恰好满**不算溢出**）✅
//    · ④ ⭐⭐ **溢出必须留痕**：⭐ 再灌 1 条 ⇒ `ovf_o == 1`、⭐ `drop_cnt_o == 1`、
//      ⭐ 且**先灌的 `DEPTH` 条一条不少** ✅（⭐ 这是 `K-106` 的核心）
//    · ⑤ ⭐⭐ **满时同拍"取+推" = 净 0，且推的那条真的进去了** ✅
//      —— 🔴 专抓 `push_ok = wr_valid & ~full` 那种写法（⭐ 会**白丢**腾出来的那个位置）✅
//    · ⑥ ⭐ **`ovf_clr_i` 清零**（⭐ sticky 要能读走）✅
//    · ⑦ ⭐ **复位清空**（⭐ `cnt`/`ovf`/`drop` 全归零、⭐ `rd_valid_o == 0`）✅
//    · ⑧ ⭐ **低水位 `low_o`**：⭐ 边界（`cnt == LOW_WM` **算低**）✅
//    · ⑨ ⭐ **真实深度 1024 能装满读空**（⭐ 交付档尺寸真的能用 ✅）
//    · ⑩ ⭐ **A8 无 X/Z** ✅
//
// ⚠️ 时基纪律：⭐ 激励一律在 `negedge` 改（⭐ ⛔ 不与 DUT 的 `posedge` 竞争 ✅）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_evt_buf;

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

    // ═════════════════════════════════════════════════════════════════════════
    //  ⭐ 小实例（`DEPTH=8`）—— ⭐ 逻辑判据全在这里跑（⭐ 快、且能塞满/塞爆 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    reg         s_wr_v;
    reg  [63:0] s_wr_d;
    wire        s_rd_v;
    wire [63:0] s_rd_d;
    reg         s_rd_a;
    wire        s_ovf;
    wire [15:0] s_drop;
    wire [15:0] s_cnt;
    wire        s_low;
    //  ⭐⭐ 2026-10-11：⭐ **高水位**（⭐ L1 ✅）
    wire        s_hw;
    wire        r_hw;
    reg         s_clr;

    evt_buf #(.DEPTH(8), .EVT_W(64), .LOW_WM(2)) u_small (
        .clk_i(clk), .rst_n_i(rst_n),
        .wr_valid_i(s_wr_v), .wr_data_i(s_wr_d),
        .rd_valid_o(s_rd_v), .rd_data_o(s_rd_d), .rd_ack_i(s_rd_a),
        .ovf_o(s_ovf), .drop_cnt_o(s_drop), .cnt_o(s_cnt), .low_o(s_low),
        .high_water_o(s_hw),          // ⭐ 2026-10-11：⭐ L1 高水位（⭐ 派生 HIGH_WM = 6 ✅）
        .ovf_clr_i(s_clr)
    );

    // ═════════════════════════════════════════════════════════════════════════
    //  ⭐ 真实档实例（`DEPTH=1024` / `LOW_WM=256`）—— ⭐ 交付尺寸 ✅
    // ═════════════════════════════════════════════════════════════════════════
    reg         r_wr_v;
    reg  [63:0] r_wr_d;
    wire        r_rd_v;
    wire [63:0] r_rd_d;
    reg         r_rd_a;
    wire        r_ovf;
    wire [15:0] r_drop;
    wire [15:0] r_cnt;
    wire        r_low;
    reg         r_clr;

    evt_buf #(.DEPTH(1024), .EVT_W(64), .LOW_WM(256)) u_real (
        .clk_i(clk), .rst_n_i(rst_n),
        .wr_valid_i(r_wr_v), .wr_data_i(r_wr_d),
        .rd_valid_o(r_rd_v), .rd_data_o(r_rd_d), .rd_ack_i(r_rd_a),
        .ovf_o(r_ovf), .drop_cnt_o(r_drop), .cnt_o(r_cnt), .low_o(r_low),
        .high_water_o(r_hw),          // ⭐ 2026-10-11：⭐ L1 高水位 ✅
        .ovf_clr_i(r_clr)
    );

    // ── ⭐ 激励任务（⭐ 一律在 `negedge` 改 ✅）────────────────────────────
    task s_push;
        input [63:0] v;
        begin
            @(negedge clk); s_wr_v = 1'b1; s_wr_d = v;
            @(negedge clk); s_wr_v = 1'b0;
        end
    endtask

    task s_pop;
        begin
            @(negedge clk); s_rd_a = 1'b1;
            @(negedge clk); s_rd_a = 1'b0;
        end
    endtask

    integer i;
    reg [63:0] exp_v;
    integer    gap_seen;

    // ═════════════════════════════════════════════════════════════════════════
    initial begin
        s_wr_v = 1'b0; s_wr_d = 64'd0; s_rd_a = 1'b0; s_clr = 1'b0;
        r_wr_v = 1'b0; r_wr_d = 64'd0; r_rd_a = 1'b0; r_clr = 1'b0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        $display("=== tb_evt_buf (U-19 曲谱事件缓冲区) ===");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⓪ 写穿：⭐ 空 ⇒ 非空【那一拍】队头必须立刻是新写的那条 ==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴🔴 **本条判据的由来（⭐ 诚实记录）**：
        //     ⭐ `tb/w3c/tb_score_chain.sv` 首次抓出 —— ⭐ "空 ⇒ 非空"那一拍
        //        `wr_ptr == rd_ptr` ⇒ ⚠️ **同一沿上既写 `mem[0]` 又预取读 `mem[0]`**
        //        ⇒ 🔴 读拿到**写之前**的值 ⇒ `rd_data_o` 是**未初始化值** ✅
        //     🔴 **后果**：⭐ 仿真里 `X` 顺着 `play_seq.evt_data_i` 传出去，
        //        ⭐ 回灌成本模块的 `take_ok` ⇒ **`cnt` 整条变 `X`**；
        //        ⭐ 而**硬件里**（⭐ 无 `X`）会拿残留位型 ⇒ ⚠️ 若残留 `tick` 恰好到期
        //        ⇒ 🔴 **一次伪读 ⇒ 那条真事件被取走却没吐出来 = 静默丢事件** ✅
        //  ✅ **修法**：⭐ 同址**写穿**（⭐ `rd_wr_same ? wr_data_i : mem[rd_addr]` ✅）
        //  ⚠️ **检查时机是关键**：⭐ 必须在**写那一沿的紧后一拍**查 ——
        //     ⭐ 若多等一拍，⭐ 预取已经读到正确的值 ⇒ 🔴 **判据就抓不到了** ✅
        @(negedge clk); s_wr_v = 1'b1; s_wr_d = 64'h0BAD_0000_0000_0001;
        @(negedge clk); s_wr_v = 1'b0;
        chk(s_rd_d === 64'h0BAD_0000_0000_0001,
            "0b the very first entry is live immediately (write-through, no stale/X window)");
        s_pop; @(negedge clk);
        chk(s_cnt === 16'd0, "0c drained after the write-through check");

        // ═════════════════════════════════════════════════════════════════
        $display("== ① 顺序与条数（⭐ 灌 6 条 ⇒ 读出 6 条、逐条相同、第 7 次读【空】）==");
        // ═════════════════════════════════════════════════════════════════
        for (i = 0; i < 6; i = i + 1) s_push(64'hA000_0000_0000_0000 + i);
        @(negedge clk);
        chk(s_cnt === 16'd6, "1a cnt == 6 after 6 pushes");
        chk(s_rd_v === 1'b1, "1b rd_valid == 1 when non-empty");
        for (i = 0; i < 6; i = i + 1) begin
            if (s_rd_d !== (64'hA000_0000_0000_0000 + i)) begin
                $display("      [dbg] i=%0d got=%h exp=%h", i, s_rd_d,
                         64'hA000_0000_0000_0000 + i);
            end
            chk(s_rd_d === (64'hA000_0000_0000_0000 + i), "1c FIFO order preserved (in order)");
            s_pop;
            @(negedge clk);
        end
        chk(s_rd_v === 1'b0, "1d rd_valid == 0 after draining");
        chk(s_cnt === 16'd0, "1e cnt == 0 after draining");

        // ═════════════════════════════════════════════════════════════════
        $display("== ② FWFT：取走后【下一拍】队头必须已经是下一条（⛔ 不许有死拍）==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴🔴 **本节的由来（⭐ 诚实记录）**：
        //     ⭐ 第一版只查了 `rd_valid_o` 在排空期间"不掉"——
        //     ⚠️ 而 `rd_valid_o = ~empty` 是**结构上不可能掉**的
        //     ⇒ 🔴 **那条判据【永远不可能红】= 空洞** ✅
        //     （⭐ 实测：⭐ 把预取地址改成 `rd_ptr`（即"取走才发起读"）⇒
        //       ⭐ 只有 5e/9f/9g 变红，⭐ **2a 照样绿** ⇒ ⭐ 证明它是空的 ✅）
        //  ✅ **修法**：⭐ 直接查**数据** —— ⭐ 取走第 i 条之后**一拍都不等**，
        //     ⭐ 队头必须**已经**是第 i+1 条 ✅（⭐ 这正是 FWFT 的定义 ✅）
        for (i = 0; i < 6; i = i + 1) s_push(64'hB000_0000_0000_0000 + i);
        @(negedge clk);
        gap_seen = 0;
        for (i = 0; i < 6; i = i + 1) begin
            chk(s_rd_d === (64'hB000_0000_0000_0000 + i), "2a head correct before ack");
            @(negedge clk); s_rd_a = 1'b1;
            @(negedge clk); s_rd_a = 1'b0;
            //  ⭐ **就在这里**（⭐ 紧接取走那一拍，⛔ 没有任何额外等待）查新队头 ✅
            if (i < 5) begin
                if (s_rd_d !== (64'hB000_0000_0000_0000 + i + 1)) gap_seen = gap_seen + 1;
            end
        end
        chk(gap_seen == 0, "2b FWFT: next head is live on the very next cycle (no dead cycle)");
        chk(s_rd_v === 1'b0, "2c empty after the FWFT drain");

        // ═════════════════════════════════════════════════════════════════
        $display("== ③/④ 满 / 溢出留痕（⭐ DEPTH=8）==");
        // ═════════════════════════════════════════════════════════════════
        for (i = 0; i < 8; i = i + 1) s_push(64'hC000_0000_0000_0000 + i);
        @(negedge clk);
        chk(s_cnt === 16'd8, "3a cnt == DEPTH(8) when exactly full");
        chk(s_ovf === 1'b0, "3b exactly-full is NOT an overflow");
        chk(s_low === 1'b0, "3c low_o == 0 when full");
        s_push(64'hDEAD_BEEF_0000_0001);
        @(negedge clk);
        chk(s_ovf === 1'b1, "4a overflow sets the sticky ovf_o");
        chk(s_drop === 16'd1, "4b drop_cnt_o == 1 (saturating counter, NOT silent)");
        chk(s_cnt === 16'd8, "4c cnt stays at DEPTH after a dropped write");
        for (i = 0; i < 8; i = i + 1) begin
            chk(s_rd_d === (64'hC000_0000_0000_0000 + i),
                "4d the first DEPTH entries survive the overflow");
            s_pop;
            @(negedge clk);
        end

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑤ 满时同拍【取+推】= 净 0，且推的那条真的进去了 ==");
        // ═════════════════════════════════════════════════════════════════
        for (i = 0; i < 8; i = i + 1) s_push(64'hD000_0000_0000_0000 + i);
        @(negedge clk);
        chk(s_cnt === 16'd8, "5a full again");
        //  ⭐⭐ **先清掉 4a 留下的 sticky** ⇒ ⭐ 否则下面"没新溢出"那条是**空洞**的 ✅
        @(negedge clk); s_clr = 1'b1;
        @(negedge clk); s_clr = 1'b0;
        chk(s_ovf === 1'b0, "5b ovf cleared (so 5d is non-vacuous)");
        //  ⭐ 同一拍：⭐ `wr_valid` 与 `rd_ack` **同时**高 ✅
        @(negedge clk);
        s_wr_v = 1'b1; s_wr_d = 64'hE000_0000_0000_0000; s_rd_a = 1'b1;
        @(negedge clk);
        s_wr_v = 1'b0; s_rd_a = 1'b0;
        chk(s_cnt === 16'd8, "5c cnt net 0 on a same-cycle push+pop");
        chk(s_ovf === 1'b0, "5d the pushed entry was NOT dropped (no NEW overflow)");
        //  ⭐ 读出来：⭐ 前 7 条 = 原来的 1..7（⭐ 第 0 条被取走了），⭐ 第 8 条 = 新推的 ✅
        for (i = 0; i < 7; i = i + 1) begin
            chk(s_rd_d === (64'hD000_0000_0000_0000 + i + 1),
                "5e ring order after the simultaneous op");
            s_pop;
            @(negedge clk);
        end
        chk(s_rd_d === 64'hE000_0000_0000_0000,
            "5f the simultaneously-pushed entry IS in the FIFO (not silently lost)");
        s_pop; @(negedge clk);
        chk(s_cnt === 16'd0, "5g empty after the ring drain");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑥ ovf_clr_i / ⑧ low_o 边界 ==");
        // ═════════════════════════════════════════════════════════════════
        s_push(64'hF000_0000_0000_0001);
        @(negedge clk);
        chk(s_low === 1'b1, "8a low_o == 1 at cnt == 1 (<= LOW_WM=2)");
        s_push(64'hF000_0000_0000_0002);
        @(negedge clk);
        chk(s_low === 1'b1, "8b low_o == 1 at cnt == LOW_WM (boundary counts as low)");
        s_push(64'hF000_0000_0000_0003);
        @(negedge clk);
        chk(s_low === 1'b0, "8c low_o == 0 just above LOW_WM");
        @(negedge clk); s_clr = 1'b1;
        @(negedge clk); s_clr = 1'b0;
        chk(s_ovf === 1'b0, "6a ovf_clr_i clears the sticky ovf_o");
        chk(s_drop === 16'd0, "6b ovf_clr_i clears drop_cnt_o");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑦ 复位清空 ==");
        // ═════════════════════════════════════════════════════════════════
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        chk(s_cnt === 16'd0, "7a reset empties the FIFO");
        chk(s_rd_v === 1'b0, "7b reset drops rd_valid");
        chk(s_ovf === 1'b0, "7c reset clears ovf");
        chk(s_drop === 16'd0, "7d reset clears drop_cnt");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑨ 真实深度 1024：装满 + 读空 + 溢出留痕 ==");
        // ═════════════════════════════════════════════════════════════════
        for (i = 0; i < 1024; i = i + 1) begin
            @(negedge clk); r_wr_v = 1'b1; r_wr_d = {32'h1234_5678, i[31:0]};
            @(negedge clk); r_wr_v = 1'b0;
        end
        @(negedge clk);
        chk(r_cnt === 16'd1024, "9a DEPTH=1024 fills exactly");
        chk(r_ovf === 1'b0, "9b no overflow at exactly 1024");
        chk(r_low === 1'b0, "9c low_o == 0 when full");
        @(negedge clk); r_wr_v = 1'b1; r_wr_d = 64'hFFFF_FFFF_FFFF_FFFF;
        @(negedge clk); r_wr_v = 1'b0;
        chk(r_ovf === 1'b1, "9d the 1025th push sets ovf (8 KB really is the limit)");
        chk(r_drop === 16'd1, "9e drop_cnt == 1 at DEPTH=1024");
        //  ⭐ 读空 1024 条，⭐ 逐条核对（⭐ 顺序 + 值）
        exp_v = 64'd0;
        for (i = 0; i < 1024; i = i + 1) begin
            exp_v = {32'h1234_5678, i[31:0]};
            if (r_rd_d !== exp_v) begin
                $display("      [dbg] i=%0d got=%h exp=%h", i, r_rd_d, exp_v);
                chk(1'b0, "9f 1024 entries come out in order with the right values");
                i = 1024;
            end
            @(negedge clk); r_rd_a = 1'b1;
            @(negedge clk); r_rd_a = 1'b0;
        end
        chk(r_cnt === 16'd0, "9g DEPTH=1024 drains to empty");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑩ A8：无 X/Z ==");
        // ═════════════════════════════════════════════════════════════════
        chk((^{s_rd_v, s_rd_d, s_ovf, s_drop, s_cnt, s_low, s_hw}) !== 1'bx,
            "10a small instance outputs contain no X");
        chk((^{r_rd_v, r_rd_d, r_ovf, r_drop, r_cnt, r_low, r_hw}) !== 1'bx,
            "10b real instance outputs contain no X");

        // ═════════════════════════════════════════════════════════════════
        $display("== ⑪ ⭐⭐ 高水位 `high_water_o`（⭐ ESP32 侧清单 §2.3 的 L1 要求）==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-11 新增：⭐ **"还没丢，但余量告急"必须能提前看见** ✅
        //     📌 ⭐ 清单原文：⭐ *"它**在真正丢失【之前】**就置位 ⇒ ⭐ 调试时能在
        //        '还没丢'的时候就发现余量不够，⛔ 而不是等丢了才知道"* ✅
        //  ⚠️ ⭐ 本段用小实例：⭐ `DEPTH=8` / `LOW_WM=2`
        //     ⇒ ⭐ `HIGH_WM` **派生** = `8 − 2 = 6` ✅
        //     🔴 **注意**：⭐ 若 `HIGH_WM` 写死成交付档的 `768`
        //        ⇒ ⚠️ `cnt_next >= 768` 对 `DEPTH=8` **永远不成立**
        //        ⇒ 🔴 **判据结构上不可能红（空洞）** ⇒ ⭐ 这正是它必须**派生**的原因 ✅
        //  ── 先清干净（⭐ 前一段的残留状态）──
        while (s_cnt !== 16'd0) s_pop;
        s_clr = 1'b1; @(negedge clk); s_clr = 1'b0; @(negedge clk);
        chk(s_hw === 1'b0, "11a after reset/clear: high_water is 0");
        chk(s_ovf === 1'b0, "11b (setup) no overflow yet");

        //  ⭐ 灌到 `HIGH_WM − 1 = 5` ⇒ ⭐ **必须【还没】置位**
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk); s_wr_v = 1'b1; s_wr_d = 64'h1111_0000_0000_0000 + i;
            @(negedge clk); s_wr_v = 1'b0;
        end
        @(negedge clk);
        chk(s_cnt === 16'd5, "11c (setup) level is 5 = HIGH_WM-1");
        chk(s_hw === 1'b0, "11d level HIGH_WM-1 (5) => high_water is STILL 0 (not yet)");

        //  ⭐ 再写一条 ⇒ 水位到 `HIGH_WM = 6` ⇒ ⭐ **必须置位**
        @(negedge clk); s_wr_v = 1'b1; s_wr_d = 64'h2222_0000_0000_0000;
        @(negedge clk); s_wr_v = 1'b0;
        @(negedge clk);
        chk(s_cnt === 16'd6, "11e (setup) level is 6 = HIGH_WM");
        chk(s_hw === 1'b1, "11f level HIGH_WM (6) => high_water SET  <-- the L1 point");
        //  ⭐⭐ **非空洞性的关键**：⭐ 此刻 **`ovf_o` 必须还是 0** ✅
        //     ⇒ ⭐ 证明它**真的**是"**在丢失之前**"报的（⭐ 而不是溢出的马后炮 ✅）
        chk(s_ovf === 1'b0, "11g (NON-VACUOUS) high_water fired BEFORE any overflow -- the whole point");

        //  ⭐ **sticky**：⭐ 排空到 0 ⇒ ⭐ 仍必须是 1 ✅
        while (s_cnt !== 16'd0) s_pop;
        @(negedge clk);
        chk(s_cnt === 16'd0, "11h (setup) drained to empty");
        chk(s_hw === 1'b1, "11i high_water is STICKY (still 1 after draining to 0)");

        //  ⭐ 清 ⇒ 归 0 ✅
        s_clr = 1'b1; @(negedge clk); s_clr = 1'b0; @(negedge clk);
        chk(s_hw === 1'b0, "11j clear resets high_water (shared with ovf_clr_i)");

        //  ⭐ 大实例（交付档）：⭐ `HIGH_WM` 派生 = `1024 − 256 = 768` ✅
        //     📌 ⭐ 只验**参数派生对不对**（⭐ 灌 768 条太慢 ⇒ ⭐ 用层次引用读常量 ✅）
        chk(u_small.HIGH_WM === 6,   "11k small instance HIGH_WM derives to 8-2 = 6");
        chk(u_real.HIGH_WM  === 768, "11l delivery instance HIGH_WM derives to 1024-256 = 768");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_evt_buf - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_evt_buf - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗
    initial begin
        #20_000_000;
        $display("FAIL: tb_evt_buf TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
