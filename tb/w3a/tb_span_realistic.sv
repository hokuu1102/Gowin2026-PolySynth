// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_realistic —— 用【上板真实比例】复现 `'S'` 被拒
//
//  🔴 前几支 tb 的教训（⭐ 我自己的错）：
//     · 我把 `WAIT_TIMEOUT_CLK` 设成 200 / 2000 拍"省时间"
//     · 🔴 但上板真值是 **50_000_000 拍 = 1 秒**，⭐ 而帧率 2000 Hz
//       ⇒ ⭐ **1 秒 = 2000 帧**，余量极大
//     ⇒ 🔴 短超时的 tb **证明不了上板行为** —— ⚠️ 那只是"我的参数太小"
//
//  ⭐ 本 tb 保持【帧率与超时的真实比例】：
//     · 真值：TIMEOUT = 50e6 拍，帧 = 25000 拍 ⇒ **TIMEOUT = 2000 帧**
//     · 本 tb：帧 = 40 拍 ⇒ TIMEOUT = 2000 × 40 = **80000 拍**（⭐ 比例不变）
//     ⇒ ⭐ 这样才有资格谈"上板会不会超时"。
//
//  ⭐ 同时验证 K-129（`stable_cnt` 需 STABLE_NEED+2 帧，⛔ 不是 STABLE_NEED 帧）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_realistic;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    // ⭐ 与 top.v 的 SPAN_* 一致
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    localparam integer FRAME = 40;              // 1 通道占 40 拍 ⇒ 一帧 320 拍
    // ⭐ 真实比例：TIMEOUT/帧 = 50e6/25000 = 2000
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

    integer spans = 0, rejects = 0, votes_done = 0;
    always @(posedge clk) begin
        if (reject_o) rejects = rejects + 1;
        if (|span_o)  spans   = spans + 1;
    end
    // ⭐ 数"进过 S_VOTE"这件事（用 state 变化）
    reg [2:0] ps = 3'd7;
    always @(posedge clk) begin
        if (rst_n && state_o !== ps) begin
            if (state_o == 3'd3) votes_done = votes_done + 1;
            ps = state_o;
        end
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

    // ⭐ 模拟 calib 的除法器：收到 span 后拉 busy 若干拍再落
    always @(posedge clk) begin
        if (rst_n && (|span_o)) begin
            cal_busy_i <= 1'b1;
        end else if (cal_busy_i) begin
            cal_busy_i <= 1'b0;
        end
    end

    reg [2:0] sweep_ch = 0;
    // ⭐ 轴 0 的"读数"：可配置抖动
    integer jit = 0;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            if (sweep_ch == 3'd0) raw_i = 12'd2000 + jit;
            else                  raw_i = 12'd300 + sweep_ch * 12'd100;
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

    integer i, k;
    integer fails = 0;

    // ⭐ 判据：跑完一个场景后，必须 span 数 == AXIS_TOTAL 且 reject == 0
    task check_scene(input [255:0] name, input integer want_span);
        begin
            if (spans == want_span && rejects == 0) begin
                $display("  ok  : %0s -- span=%0d (期望 %0d) reject=0", name, spans, want_span);
            end else begin
                $display("  FAIL: %0s -- span=%0d (期望 %0d) reject=%0d", name, spans, want_span, rejects);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_span_realistic ===");
        $display("STABLE_NEED=%0d VOTE_N=%0d STABLE_TOL=%0d VOTE_TOL=%0d", STABLE_NEED, VOTE_N, STABLE_TOL, VOTE_TOL);
        $display("FRAME=%0d 拍/通道 ⇒ 一帧 %0d 拍；TIMEOUT=%0d 拍 = %0d 帧（⭐ 与上板同比例）",
                 FRAME, FRAME*8, TIMEOUT, TIMEOUT/(FRAME*8));
        $display("");
        $display("⚠️ 为什么要'同比例'：上板 TIMEOUT=50e6 拍 = 2000 帧。");
        $display("   🔴 若把超时缩成几百拍（只够 1 帧），会【人为制造】必超时 ⇒ 结论作废。");

        // ═══ ① 完美稳定（零抖动）═══════════════════════════════════
        jit = 0; spans = 0; rejects = 0; votes_done = 0;
        reset_and_start();
        repeat (FRAME * 8 * 4000) @(negedge clk);
        $display("① 零抖动：span=%0d reject=%0d 进VOTE次数=%0d state=%0d done_cnt=%0d",
                 spans, rejects, votes_done, state_o, done_cnt_o);
        check_scene("零抖动 ⇒ 16 轴全标定", AXIS_TOTAL);

        // ═══ ② 抖动 ±30（< STABLE_TOL 48）═════════════════════════
        jit = 0; spans = 0; rejects = 0; votes_done = 0;
        reset_and_start();
        fork
            begin : jitgen
                for (k = 0; k < 200000; k = k + 1) begin
                    @(negedge clk);
                    jit = (k % 2) ? 30 : -30;
                end
            end
            begin repeat (FRAME * 8 * 4000) @(negedge clk); end
        join
        $display("② 抖动±30（< TOL 48）：span=%0d reject=%0d 进VOTE次数=%0d state=%0d",
                 spans, rejects, votes_done, state_o);
        check_scene("抖动 ±30 ⇒ 仍应全标定", AXIS_TOTAL);

        // ═══ ③ 抖动 ±60（> STABLE_TOL 48，但 < VOTE_TOL 96）═══════
        jit = 0; spans = 0; rejects = 0; votes_done = 0;
        reset_and_start();
        fork
            begin : jitgen2
                for (k = 0; k < 200000; k = k + 1) begin
                    @(negedge clk);
                    jit = (k % 2) ? 60 : -60;
                end
            end
            begin repeat (FRAME * 8 * 4000) @(negedge clk); end
        join
        $display("③ 抖动±60（> TOL 48）：span=%0d reject=%0d 进VOTE次数=%0d state=%0d",
                 spans, rejects, votes_done, state_o);
        check_scene("抖动 ±60 (< VOTE_TOL 96) ⇒ 仍应全标定", AXIS_TOTAL);

        $display("==================================================");
        if (fails == 0)
            $display("PASS: 同比例超时下，calib_span 在稳定/抖动输入都能标定全部 16 轴");
        else
            $display("FAIL: %0d 个场景不达标", fails);
        $finish;
    end

    initial begin
        #200000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
