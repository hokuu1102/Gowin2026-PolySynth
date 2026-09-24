// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_cross_channel —— 验证「跨通道跳变」能否单独解释 `'S'` 被拒
//
//  ⭐ 上板实测（2026-09-25）给出了两个关键数：
//     ① ⭐ 单通道噪声极小：⭐ ch7 Δ=6（⭐ 远小于 STABLE_TOL=48）⇒ 🔴 **抖动假设排除**
//     ② 🔴 跨通道极差 = 54（ch5 2139.5 → ch1 2193）
//        ⇒ ⚠️ **54 > STABLE_TOL(48)** ⇒ 🔴 若相邻帧拿到不同通道 ⇒ `stable_cnt` 必被清零
//
//  ⭐ 本 tb 的目的：⭐ **把上板那种"各通道静态值略有不同"的场景搬进仿真**，
//     看 `calib_span` 在【正确的通道过滤】下能否标定成功。
//     · ⭐ 若【能】成功 ⇒ ✅ 说明"跨通道值不同"本身不是问题
//        ⇒ 🔴 **那上板失败就只剩"对齐/接线"一种解释**（⭐ 见定案文档 §四对照实验）
//     · 🔴 若【不能】成功 ⇒ 🔴 说明容限/过滤逻辑确实有洞
//
//  ⭐ 参数保持与上板同比例（TIMEOUT/帧周期 = 2000），⛔ 不缩短（见 K-129）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_cross_channel;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    localparam integer FRAME = 40;                                   // 40 拍/通道
    localparam integer TIMEOUT = FRAME * 8 * 2000;                   // ⭐ 同比例 2000 帧

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

    integer spans = 0, rejects = 0;
    always @(posedge clk) begin
        if (reject_o) rejects = rejects + 1;
        if (|span_o)  spans   = spans + 1;
    end

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

    always @(posedge clk) begin
        if (rst_n && (|span_o)) cal_busy_i <= 1'b1;
        else if (cal_busy_i)   cal_busy_i <= 1'b0;
    end

    // ⭐⭐ 用【上板实测的真实静态值】构造 8 个通道
    //    ch0..ch7 = 2164, 2193, 2184, 2180, 2144, 2139, 2180, 2171
    //    ⭐ 极差 = 2193-2139 = 54（⭐ 正是上板实测的跨通道差）
    function [11:0] chval;
        input [2:0] c;
        begin
            case (c)
                3'd0: chval = 12'd2164;
                3'd1: chval = 12'd2193;
                3'd2: chval = 12'd2184;
                3'd3: chval = 12'd2180;
                3'd4: chval = 12'd2144;
                3'd5: chval = 12'd2139;
                3'd6: chval = 12'd2180;
                default: chval = 12'd2171;   // ch7
            endcase
        end
    endfunction

    // ⭐ 小噪声（⭐ 复刻实测：ch7 Δ=6）
    integer tick = 0;
    always @(negedge clk) tick = tick + 1;

    localparam integer FRAME_CYC = FRAME * 8;
    reg [2:0] sweep_ch = 0;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            // ⭐ 该通道的静态值 + 微小噪声（±3，⭐ 复刻实测 Δ≤6）
            raw_i = chval(sweep_ch) + ((tick % 7) - 3);
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
            sweep_ch = sweep_ch + 3'd1;
        end
    end

    task reset_and_start;
        begin
            rst_n = 0; start_i = 0;
            repeat (5) @(negedge clk);
            rst_n = 1;
            repeat (5) @(negedge clk);
            @(negedge clk); start_i = 1;
            @(negedge clk); start_i = 0;
        end
    endtask

    integer fails = 0;
    initial begin
        $display("=== tb_span_cross_channel ===");
        $display("⭐ 用上板实测的 8 通道静态值：2164/2193/2184/2180/2144/2139/2180/2171");
        $display("   ⇒ 极差 = 54；⭐ 单通道噪声 = ±3（复刻实测 Δ<=6）");
        $display("   STABLE_TOL=%0d VOTE_TOL=%0d；TIMEOUT=%0d 拍 = %0d 帧（同比例）",
                 STABLE_TOL, VOTE_TOL, TIMEOUT, TIMEOUT/FRAME_CYC);
        $display("");

        reset_and_start();
        repeat (FRAME_CYC * 4000) @(negedge clk);

        $display("结果：span=%0d  reject=%0d  state=%0d  done_cnt=%0d  rej_cnt=%0d",
                 spans, rejects, state_o, done_cnt_o, rej_cnt_o);
        $display("--------------------------------------------------");

        if (spans == AXIS_TOTAL && rejects == 0) begin
            $display("ok  : 跨通道静态值不同（极差 54）下，16 轴仍然全部标定成功");
            $display("      ⇒ ✅ 说明'各通道静态值不同'本身【不是】问题");
            $display("      ⇒ 🔴 上板失败只剩'采样对齐/接线'一种解释（见定案文档 §四）");
        end else begin
            $display("FAIL: span=%0d (期望 %0d) reject=%0d", spans, AXIS_TOTAL, rejects);
            $display("      ⇒ 🔴 跨通道跳变【确实】会破坏标定");
            fails = fails + 1;
        end

        if (rej_cnt_o <= REJECT_MAX) begin
            $display("ok  : rej_cnt_o=%0d <= REJECT_MAX=%0d（计数语义自洽）", rej_cnt_o, REJECT_MAX);
        end else begin
            $display("NOTE: rej_cnt_o=%0d > REJECT_MAX=%0d  ⇒ ⚠️ 与上板 'V7090'(rej=9) 同类现象",
                     rej_cnt_o, REJECT_MAX);
        end

        $display("==================================================");
        if (fails == 0) $display("PASS: 跨通道静态差异不破坏 span 标定");
        else            $display("FAIL: %0d 项不达标", fails);
        $finish;
    end

    initial begin
        #300000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
