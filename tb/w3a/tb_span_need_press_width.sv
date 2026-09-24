// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_need_press_width —— 测 `need_press_o` 的【实际宽度】
//
//  🔴 上板现象（2026-09-25，⭐ 用户实测）：
//     发 `'S'` ⇒ ⭐ **只回一个 `s`，⭐ 没有轴号，⭐ 也没有 `!`**
//     ⚠️ 而 `'P'`（读 ADC）和 `'V'`（读状态）都正常
//
//  ⭐⭐ 怀疑（⭐ 读代码得出）：
//     `calib_span.v:292-307` 的 `S_PROMPT`：
//        ```
//        S_PROMPT: begin
//            need_press_o <= 1'b1;      // ⭐ 置位
//            ...
//            state        <= S_SETTLE;  // 🔴 **同拍就离开！**
//        end
//        ```
//     ⇒ ⭐ `need_press_o` 只在 `S_PROMPT` 停留 **1 拍**
//     ⇒ `top.v` 的 `ev_need = sp_need_press & ~sp_need_r`（⭐ 上升沿检测）
//        ⚠️ **若 `need_press_o` 恰好高 1 拍 ⇒ 上升沿也只有 1 拍 ⇒ 能检测到**（✅ 应该能）
//     🔴 **但**若它高 **2 拍或更多** ⇒ ⭐ 上升沿仍只 1 拍 ⇒ ⭐ 也能检测到
//     ⇒ ⚠️ **所以"宽度"本身可能不是根因** —— ⭐ **必须实测才能定**
//
//  ⭐ 本 tb 测的是【可观测事实】：⭐ `need_press_o` 到底高了几拍、
//     以及 `S_PROMPT` 停留几拍。⭐ 然后据此判断 `ev_need` 能否可靠产生。
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_need_press_width;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    // ⚠️ 用【短超时】只为快速观察 need_press 的宽度（⭐ 本 tb 不判"会不会超时"）
    localparam integer TIMEOUT = 200;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg start_i = 0, abort_i = 0;
    reg sample_valid_i = 0;
    reg [2:0] sample_ch_i = 0;
    reg [11:0] raw_i = 0;
    wire [N_ADC-1:0] span_o;
    wire [2:0] cal_ch_o;
    reg cal_busy_i = 0, cal_err_i = 0;
    wire busy_o, done_o, reject_o, need_press_o;
    wire [3:0] cur_axis_o, done_cnt_o, rej_cnt_o;
    wire [2:0] state_o;

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        .WAIT_TIMEOUT_CLK(TIMEOUT),
        .STABLE_TOL(STABLE_TOL), .VOTE_TOL(VOTE_TOL),
        .REJECT_MAX(REJECT_MAX), .POS_W(12)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .abort_i(abort_i),
        .sample_valid_i(sample_valid_i), .sample_ch_i(sample_ch_i), .raw_i(raw_i),
        .span_o(span_o), .cal_ch_o(cal_ch_o),
        .cal_busy_i(cal_busy_i), .cal_err_i(cal_err_i),
        .busy_o(busy_o), .done_o(done_o),
        .reject_o(reject_o), .need_press_o(need_press_o),
        .cur_axis_o(cur_axis_o), .done_cnt_o(done_cnt_o), .rej_cnt_o(rej_cnt_o),
        .state_o(state_o)
    );

    // ⭐⭐ 逐拍记录 need_press_o 与 state，⭐ 找出"高几拍"
    integer np_width   = 0;      // ⭐ 本次 need_press 高了几拍
    integer np_max     = 0;      // ⭐ 历史最宽
    integer np_rises   = 0;      // ⭐ 上升沿次数（= ev_need 会产生的次数）
    reg     np_prev    = 0;
    integer prompt_cyc = 0;      // ⭐ S_PROMPT 停留拍数

    always @(posedge clk) begin
        if (rst_n) begin
            // ⭐ 统计 need_press 的连续高度
            if (need_press_o) begin
                np_width = np_width + 1;
                if (!np_prev) np_rises = np_rises + 1;   // ⭐ 上升沿
            end else begin
                if (np_width > np_max) np_max = np_width;
                np_width = 0;
            end
            np_prev = need_press_o;

            // ⭐ 统计 S_PROMPT 停留
            if (state_o == 3'd1) prompt_cyc = prompt_cyc + 1;
        end
    end

    localparam integer FRAME = 20;
    reg [2:0] sweep_ch = 0;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            raw_i = (sweep_ch == 3'd0) ? 12'd2000 : 12'd300;
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
            sweep_ch = sweep_ch + 3'd1;
        end
    end

    integer i;
    initial begin
        $display("=== tb_span_need_press_width ===");
        $display("⭐ 目的：测 need_press_o 实际高几拍（⭐ 决定 ev_need 能否可靠触发）");
        $display("");

        rst_n = 0; start_i = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

        $display("启动前: need_press_o=%b state=%0d", need_press_o, state_o);

        @(negedge clk); start_i = 1;
        @(negedge clk); start_i = 0;

        // ⭐ 只观察 300 拍（⭐ 足够看到 S_PROMPT 与 need_press 的行为）
        repeat (300) @(negedge clk);

        if (np_width > np_max) np_max = np_width;

        $display("--------------------------------------------------");
        $display("  S_PROMPT 停留拍数      = %0d", prompt_cyc);
        $display("  need_press 最宽        = %0d 拍", np_max);
        $display("  need_press 上升沿次数  = %0d  (= top.v 的 ev_need 次数)", np_rises);
        $display("  当前 state             = %0d", state_o);
        $display("--------------------------------------------------");

        if (np_rises >= 1)
            $display("ok  : need_press_o 确实产生了上升沿 ⇒ top.v 的 ev_need 会被触发");
        else
            $display("FAIL: need_press_o 从未上升 ⇒ 🔴 轴号【发不出来】");

        if (np_max == 1)
            $display("NOTE: need_press 只高 1 拍 —— ⚠️ 上升沿检测仍可捕获（⭐ 但很脆）");
        else
            $display("NOTE: need_press 高 %0d 拍", np_max);

        $display("==================================================");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
