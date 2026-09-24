// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_alignment_gap —— 验证「跨通道极差」是否是 `'S'` 被拒的真因
//
//  ⭐⭐ 上板实测数据（2026-09-25，⭐ 用户按住 ch7 时）：
//     · ch7 = 2901..2905（⭐ Δ=4）      ✅ 按下特征明显
//     · 其他 7 通道 = 2141..2196        ✅ 全都没动
//     ⇒ ✅ **`sample_ch` 与 `raw` 的对齐【完全正确】**（⭐ "错位"假设被推翻）
//
//  🔴 但按住时出现了一个【新的量级差】：
//     · ch7(2903) vs ch5(2141)  ==> **跨通道极差 = 762**
//     · 而 `STABLE_TOL = 48`、`VOTE_TOL = 96`
//     ⇒ 🔴 **若相邻两帧拿到不同通道 ⇒ 帧间跳 762 ⇒ 必被拒**
//
//  ⭐ 本 tb 要回答的问题：
//     🔴 **"正确过滤"下，`calib_span` 会不会被跨通道跳变打断？**
//     ⭐ 做法：⭐ 用【按住 ch7】的真实值，⭐ 让 scanner 正常轮转 0..7，
//         ⭐ 看 axis=7 这一轴能否标定成功。
//
//  ⚠️ 参数保持同比例（⭐ `K-129`）：TIMEOUT / 帧周期 = 2000
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_alignment_gap;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    localparam integer FRAME = 40;
    localparam integer TIMEOUT = FRAME * 8 * 2000;

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

    // ⭐⭐ 用【按住 ch7】时的实测静态值
    //    ch0..ch7 = 2166, 2196, 2188, 2182, (缺), 2141, 2180, 2903
    //    ⭐ ch7 被按住 ⇒ 2903；⭐ 其余是松手值
    function [11:0] chval;
        input [2:0] c;
        begin
            case (c)
                3'd0: chval = 12'd2166;
                3'd1: chval = 12'd2196;
                3'd2: chval = 12'd2188;
                3'd3: chval = 12'd2182;
                3'd4: chval = 12'd2144;   // ⚠️ 本次没采到 ch4，用上次的 2144
                3'd5: chval = 12'd2141;
                3'd6: chval = 12'd2180;
                default: chval = 12'd2903; // ⭐ ch7 = 按住
            endcase
        end
    endfunction

    integer tick = 0;
    always @(negedge clk) tick = tick + 1;

    localparam integer FRAME_CYC = FRAME * 8;
    reg [2:0] sweep_ch = 0;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            raw_i = chval(sweep_ch) + ((tick % 5) - 2);   // ±2 噪声
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
        $display("=== tb_span_alignment_gap ===");
        $display("⭐ 复刻【按住 ch7】的实测值：ch7=2903，其余 2141~2196");
        $display("   ⇒ 跨通道极差 = 762（⭐ 远超 STABLE_TOL=48 / VOTE_TOL=96）");
        $display("   STABLE_TOL=%0d VOTE_TOL=%0d TIMEOUT=%0d 拍 = %0d 帧（同比例）",
                 STABLE_TOL, VOTE_TOL, TIMEOUT, TIMEOUT/FRAME_CYC);
        $display("");

        reset_and_start();
        repeat (FRAME_CYC * 4000) @(negedge clk);

        $display("结果：span=%0d  reject=%0d  state=%0d  done_cnt=%0d  rej_cnt=%0d",
                 spans, rejects, state_o, done_cnt_o, rej_cnt_o);
        $display("--------------------------------------------------");

        if (spans == AXIS_TOTAL && rejects == 0) begin
            $display("ok  : 跨通道极差 762 下，16 轴仍全部标定成功");
            $display("      => ✅ 通道过滤【有效】=> 跨通道跳变【不是】根因");
        end else begin
            $display("FAIL: span=%0d (期望 %0d) reject=%0d", spans, AXIS_TOTAL, rejects);
            $display("      => 🔴 跨通道跳变【确实】会打断标定");
            fails = fails + 1;
        end

        $display("==================================================");
        if (fails == 0) $display("PASS: 正确的通道过滤能隔离跨通道跳变");
        else            $display("FAIL: %0d 项不达标", fails);
        $finish;
    end

    initial begin
        #300000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
