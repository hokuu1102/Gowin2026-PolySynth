// ─────────────────────────────────────────────────────────────────────────────
// tb_am_pipe.sv · P0-2 判据（⛔ 不改 RTL）
//
// ⭐ 守的是什么（commit `bfec7e9` 修的缺陷）：
//   `top.v` 的音高映射流水里，`am_vld_out` / `am_axis_out` / `am_kind_out`
//   是【寄存一拍】的输出；而 `am_inc`（= `axis_map.phase_inc_o`）是
//   【组合输出】（0 拍）。
//   ⇒ 若 `w3a_evt_inc` 直接接 `am_inc`，它会比 `w3a_evt_valid`(= `am_vld_out`)
//     **早一拍**。
//   ⇒ ⭐ 同帧【背靠背】≥2 个事件时，前一条 `note_on` 拿到**后一条事件**的音高
//      ⇒ 和弦全塌到最后一个事件的音高（⭐ 与用户"音高都一样"吻合）。
//
// ⭐ 判据（⭐ 每一条都能失败 —— `K-56` / `C21`）：
//   对**每一个**输出事件（`am_vld_out` 为高的那一拍）：
//     `w3a_evt_inc` 必须 == 【该事件 `am_axis_out` 对应的表值】
//     （⭐ 直接从被例化的 `u_axis_map` 内部读表：键盘 `kb_inc` / 指板 `fb_inc`）
//   ⇒ mismatch 数必须 == 0；且输出事件数必须 == 期望值（⛔ 防空跑）。
//
// ⭐ 非空洞性（⭐ 必看）：本 tb 的流水段是 `rtl/top.v:1890-1945` 的**逐行复刻**
//   （⛔ 只复刻这一段，**不例化整个 `top`**）。
//   加 `-DAM_PIPE_PREFIX_BUG` 编译 ⇒ 流水段被切成**修复前**的接法
//   （`w3a_evt_inc = am_inc`，且不例化 `am_inc_out`）
//   ⇒ ⭐ 实测 **FAIL**（mismatches = 8 / events = 17）。
//   📌 该分支与 `git show bfec7e9^:rtl/top.v` 的对应行**逐字相同**。
//
// ⚠️ 为什么"背靠背"才出错：
//   事件之间**有空隙**时，`am_axis_in` 会一直保持前一个事件的轴号
//   ⇒ `am_inc` 恰好也等于"前一个事件的表值" ⇒ 错拍**看不出来**。
//   ⇒ ⭐ 所以判据必须打**背靠背**（本节 B 段是**对照**：有空隙 ⇒ 修复前也过）。
//
// ⚠️ 判据名一律【纯 ASCII】（⭐ 实测教训）：
//   `chk` 的名字是经 `task` 的**宽向量参数**传给 `$display("%0s", …)` 的，
//   而 ⭐ **iverilog 的 `%s` 会把 ≥0x80 的字节逐个换成 `U+FFFD`**
//   ⇒ 日志里所有中文判据名都变成 `����`（⭐ 现有 `sim/evidence/*.log` 全都如此）。
//   ⇒ 本 tb：**节标题**（直接 `$display` 字面量，⛔ 不走 task 参数）保留中文，
//     **判据名**用 ASCII ⇒ ⭐ 日志可读、`FAIL:`/`PASS:` 干净。
//
// ⚠️ 语法纪律（`K-91`）：Verilog-2001 风格（`-g2012` 编译，⛔ 不用 SV 专有构造）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_am_pipe;

    localparam integer AXIS_W  = 4;
    localparam integer POS_W   = 12;
    localparam integer PHASE_W = 32;
    localparam integer N_KEY   = 16;
    localparam integer N_AXIS  = 16;

    // ⭐ 期望的输出事件总数（⛔ 防空跑：若事件没注入，判据会静默变空 —— `C36`）
    localparam integer EXP_EVT = 17;

    reg clk        = 1'b0;
    reg rst_n_sync = 1'b0;
    always #10 clk = ~clk;

    integer errors     = 0;
    integer n_evt      = 0;      // 输出事件总数（`am_vld_out` 为高的拍数）
    integer n_mismatch = 0;      // 音高错拍数
    integer n_b2b      = 0;      // 背靠背段注入的事件数（对照用）

    task chk;
        input [8*128-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // 激励（⭐ 与 `top.v` 同名同构：`pm_*` 来自 `play_mode_ctrl`，
    //       `as_pos` 来自 `axis_snapshot`）
    // ═════════════════════════════════════════════════════════════════════════
    reg [N_AXIS*POS_W-1:0] as_pos;     // 16 轴行程快照
    reg                    pm_valid;
    reg [3:0]              pm_axis;
    reg [1:0]              pm_kind;
    reg                    play_fretboard_mode;

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ 复刻 `rtl/top.v:1890-1945`（音高映射流水 + `axis_map` 例化）
    //      ⛔ 只复刻这一段 —— 不例化整个 `top`
    // ═════════════════════════════════════════════════════════════════════════
        wire [31:0] am_inc;
        wire        am_valid;
        wire [3:0]  am_axis;

        // 音高映射流水寄存器。valid、axis、kind 与 phase_inc 必须同拍。
        reg [11:0] am_pos_in;
        reg [3:0]  am_axis_in;
        reg [1:0]  am_kind_in;
        reg        am_vld_in;
        reg        am_mode;            // 0 = 键盘模式 · 1 = 指板模式
        reg        am_vld_out;
        reg [3:0]  am_axis_out;
        reg [1:0]  am_kind_out;
`ifndef AM_PIPE_PREFIX_BUG
        //  ⭐⭐ 2026-09-28 新增：m_inc 是 axis_map 对【当前 am_axis_in】的组合输出（0 拍），
        //  而 am_vld_out/am_axis_out 再延一拍 ⇒ 错一拍 ⇒ 同帧多键时前一条事件拿到后一条的音高。
        reg [31:0] am_inc_out;
`endif

        always @(posedge clk) begin
            if (!rst_n_sync) begin
                am_pos_in   <= 12'd0;
                am_axis_in  <= 4'd0;
                am_kind_in  <= 2'd0;
                am_vld_in   <= 1'b0;
                am_mode     <= 1'b1;
                am_vld_out  <= 1'b0;
                am_axis_out <= 4'd0;
                am_kind_out <= 2'd0;
`ifndef AM_PIPE_PREFIX_BUG
                am_inc_out  <= 32'd0;
`endif
            end else begin
                am_vld_in <= 1'b0;
                if (pm_valid) begin
                    am_pos_in  <= as_pos[pm_axis*12 +: 12];
                    am_axis_in <= pm_axis;
                    am_kind_in <= pm_kind;
                    am_mode    <= play_fretboard_mode;
                    am_vld_in  <= 1'b1;
                end
                am_vld_out  <= am_vld_in;
                am_axis_out <= am_axis_in;
                am_kind_out <= am_kind_in;
`ifndef AM_PIPE_PREFIX_BUG
                am_inc_out  <= am_inc;   // ⭐ 打一拍，与 am_vld_out/am_axis_out 严格同拍
`endif
            end
        end

        axis_map #(
            .AXIS_W  (4),
            .POS_W   (12),
            .PHASE_W (32),
            .N_KEY   (16)
        ) u_axis_map (
            .clk          (clk),
            .rst_n        (rst_n_sync),
            .pos_valid_i  (am_vld_in),
            .axis_id_i    (am_axis_in),
            .pos_i        (am_pos_in),
            .mode_i       (am_mode),
            .phase_inc_o  (am_inc),
            .phase_valid_o(am_valid),
            .axis_id_o    (am_axis)
        );

    // ── 下游取用（`top.v:2020-2027`）────────────────────────────────────────
    wire        w3a_evt_valid = am_vld_out;
    wire [3:0]  w3a_evt_axis  = am_axis_out;
    wire [1:0]  w3a_evt_kind  = am_kind_out;
`ifdef AM_PIPE_PREFIX_BUG
    //  🔴 修复【前】的接法：`am_inc` 是组合输出（0 拍）⇒ 比 valid 早一拍
    wire [31:0] w3a_evt_inc   = am_inc;
`else
    //  ✅ 修复【后】的接法：与 `w3a_evt_valid`(= am_vld_out) 严格同拍
    wire [31:0] w3a_evt_inc   = am_inc_out;
`endif

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ 判据（不变量）：每一个输出事件都必须带上【它自己的】音高
    //
    //   ⭐ 期望值 = 【该输出事件的 axis】对应的表值，⭐ 直接读被例化 DUT 的表
    //      （⛔ 不复刻公式 ⇒ 判据与被测对象解耦；`axis_map` 内部就是 `kb_inc`/`fb_inc`）
    //   ⭐ 写成**每个事件都查**的不变量，⛔ 不是"抓某一个波形"（`L55` 同族写法）
    // ═════════════════════════════════════════════════════════════════════════
    reg [PHASE_W-1:0] exp_now;

    always @(posedge clk) begin
        if (w3a_evt_valid === 1'b1) begin
            n_evt = n_evt + 1;
            exp_now = am_mode ? u_axis_map.fb_inc[am_axis_out]
                              : u_axis_map.kb_inc[am_axis_out];
            if (w3a_evt_inc !== exp_now) begin
                n_mismatch = n_mismatch + 1;
                $display("  FAIL: EVT axis=%0d mode=%0d kind=%0d inc=%08h expected inc=%08h  *** PITCH MISMATCH (inc tap is one cycle early) ***",
                         am_axis_out, am_mode, am_kind_out, w3a_evt_inc, exp_now);
            end else begin
                $display("  ok  : EVT axis=%0d mode=%0d kind=%0d inc=%08h == table[%0d]",
                         am_axis_out, am_mode, am_kind_out, w3a_evt_inc, am_axis_out);
            end
        end
    end

    // ── 激励任务 ────────────────────────────────────────────────────────────
    integer bi;
    integer ai;

    // 单个事件（`pm_valid` 恰好高 1 拍）
    task send1;
        input [3:0] ax;
        begin
            @(negedge clk);
            pm_valid = 1'b1; pm_axis = ax; pm_kind = 2'd0;
            @(negedge clk);
            pm_valid = 1'b0;
        end
    endtask

    // ⭐ n 个事件【背靠背】（每拍一个 ⇒ `am_axis_in` 每拍都换）
    task burst;
        input integer n;
        input integer ax0;
        begin
            @(negedge clk);
            pm_valid = 1'b1;
            for (bi = 0; bi < n; bi = bi + 1) begin
                pm_axis = (ax0 + bi);
                pm_kind = 2'd0;
                @(negedge clk);
            end
            pm_valid = 1'b0;
            n_b2b = n_b2b + n;
        end
    endtask

    // 空 n 拍（把事件隔开 —— 对照用）
    task idle_n;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_am_pipe/tb_am_pipe.vcd");
        $dumpvars(0, tb_am_pipe);

        pm_valid           = 1'b0;
        pm_axis            = 4'd0;
        pm_kind            = 2'd0;
        play_fretboard_mode= 1'b0;
        // 每轴一个不同的行程（⭐ 让"位置"也有区分度 —— 防止判据依赖"所有轴一样"）
        for (ai = 0; ai < N_AXIS; ai = ai + 1)
            as_pos[ai*POS_W +: POS_W] = ai * 137;

        repeat (4) @(negedge clk);
        rst_n_sync = 1'b1;
        repeat (4) @(negedge clk);

        $display("== A: 基线 —— 单事件（键盘模式，轴 5）==");
        send1(4'd5);
        idle_n(6);
        chk("A: output event count == 1", n_evt == 1);
        chk("A: single event => no pitch mismatch", n_mismatch == 0);

        $display("== B: ⭐ 对照 —— 两个事件【有空隙】（轴 5 / 轴 9）==");
        send1(4'd5);
        idle_n(5);
        send1(4'd9);
        idle_n(6);
        chk("B: output event count == 3 (incl. A)", n_evt == 3);
        chk("B: with a GAP between events there is NO mismatch (so the criterion is not a blanket failure)",
            n_mismatch == 0);

        $display("== C: ⭐⭐ 背靠背 2 个事件（轴 0 / 轴 1）—— P0-2 正题 ==");
        burst(2, 0);
        idle_n(6);
        chk("C: output event count == 5", n_evt == 5);
        chk("C: back-to-back 2 events => mismatch count == 0", n_mismatch == 0);

        $display("== D: ⭐⭐ 背靠背 3 个事件（轴 2 / 3 / 4）==");
        burst(3, 2);
        idle_n(6);
        chk("D: output event count == 8", n_evt == 8);
        chk("D: back-to-back 3 events => mismatch count == 0", n_mismatch == 0);

        $display("== E: ⭐⭐ 三串背靠背各 2 个 = 6 个事件（复现复审实测 events=6）==");
        burst(2, 8);  idle_n(5);
        burst(2, 10); idle_n(5);
        burst(2, 12); idle_n(6);
        chk("E: output event count == 14", n_evt == 14);
        chk("E: 6 back-to-back events => mismatch count == 0 (pre-fix measured 3)", n_mismatch == 0);

        $display("== F: ⭐⭐ 指板模式（mode=1）背靠背 3 个事件（轴 8 / 9 / 10）==");
        play_fretboard_mode = 1'b1;
        idle_n(4);
        burst(3, 8);
        idle_n(6);
        play_fretboard_mode = 1'b0;
        idle_n(4);
        chk("F: output event count == 17", n_evt == 17);
        chk("F: fretboard mode back-to-back => mismatch count == 0", n_mismatch == 0);

        // ── 汇总（⛔ 防空跑：事件数与注入数都必须对得上）────────────────────
        $display("== 汇总 ==");
        chk("event total == expected (criterion is not vacuous)", n_evt == EXP_EVT);
        chk("back-to-back injected event count == 14", n_b2b == 14);
        if (n_mismatch !== 0)
            $display("  FAIL: P0-2 pitch mismatch count = %0d (must be 0)", n_mismatch);
        chk("P0-2: w3a_evt_inc is in the SAME cycle as w3a_evt_valid (mismatch == 0)",
            n_mismatch == 0);

        if (errors == 0)
            $display("PASS: am_pipe pitch-tap alignment (P0-2) - all judgements held (events=%0d mismatches=%0d)",
                     n_evt, n_mismatch);
        else begin
            $display("FAIL: am_pipe pitch-tap alignment (P0-2): %0d error(s), events=%0d mismatches=%0d",
                     errors, n_evt, n_mismatch);
            $fatal(1, "FAIL: am_pipe pitch-tap alignment (P0-2) has %0d error(s)", errors);
        end
        #200;
        $finish;
    end

endmodule
