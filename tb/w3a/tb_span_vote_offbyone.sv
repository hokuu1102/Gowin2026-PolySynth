// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_vote_offbyone —— 证明 `S_VOTE`→`S_FIRE` 丢掉【最后一帧】的 min/max
//
//  🔴 假设（K-129）：
//     `calib_span.v` 的 `S_VOTE` 里，当 `vote_cnt >= VOTE_N-1` 时
//     **同拍既更新 `vmin/vmax`、又 `state <= S_FIRE`**。
//     ⚠️ 但进入 `S_FIRE` 后，`vmin/vmax` **不再更新**（`S_FIRE` 没有采样逻辑），
//     ⇒ 🔴 **第 VOTE_N 帧的值只写进了寄存器，却没有参与 (vmax-vmin) 判定**。
//
//  ⭐ 判据设计（⭐ 关键：让"最后一帧"是唯一的离群点）：
//     · 先喂 VOTE_N-1 帧【同一个值】A ⇒ vmin=vmax=A
//     · 再喂 1 帧【离群值】B（|B-A| > VOTE_TOL）⇒ 这一帧【应该】导致拒绝
//       · 若逻辑正确 ⇒ 应报 reject（因为样本里有离群点）
//       · 🔴 若 off-by-one 存在 ⇒ vmin/vmax 仍是 (A,A) ⇒ (vmax-vmin)=0
//          ⇒ ⭐ **不拒绝 ⇒ 把离群值当合法样本用了**
//
//  ⇒ ⭐ 本 tb 断言"**应报 reject**"。若 RTL 有 off-by-one ⇒ 本 tb 会 FAIL。
//
//  用法：iverilog -g2012 -o build/sim/tb_span_vote_offbyone.vvp \
//          rtl/w3a/calib_span.v tb/w3a/tb_span_vote_offbyone.sv
//        vvp build/sim/tb_span_vote_offbyone.vvp
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_vote_offbyone;

    localparam integer NCH        = 8;
    localparam integer N_ADC      = 2;
    localparam integer AXIS_TOTAL = 16;

    // ⭐ 缩小参数 ⇒ 跑得快
    localparam integer STABLE_NEED = 4;
    localparam [11:0]  STABLE_TOL  = 12'd8;
    localparam integer VOTE_N      = 4;      // ⭐ 关键：小 N 好数
    localparam [11:0]  VOTE_TOL    = 12'd16;
    localparam integer REJECT_MAX  = 8;
    localparam integer TIMEOUT     = 1000;   // ⭐ 短超时（避免 tb 跑太久）

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                   // 50 MHz

    reg         start_i = 0, abort_i = 0;
    reg         sample_valid_i = 0;
    reg  [2:0]  sample_ch_i = 0;
    reg  [11:0] raw_i = 0;
    wire [N_ADC-1:0] span_o;
    wire [2:0]  cal_ch_o;
    reg         cal_busy_i = 0, cal_err_i = 0;
    wire        busy_o, done_o, reject_o, need_press_o;
    wire [3:0]  cur_axis_o, done_cnt_o, rej_cnt_o;
    wire [2:0]  state_o;

    // 可观测的内部状态（calib_span 导出了 state/cur_axis/rej）
    integer fails = 0;
    integer rejects = 0;

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

    always @(posedge clk) if (reject_o) rejects = rejects + 1;

    // ⭐ 喂一帧（与目标通道同拍）
    //   🔴 2026-09-25 修（⭐ 本 tb 曾因 `K-132` 改动而误报）：
    //      ⚠️ 原来用 `feed()` + 固定 `repeat(2)` ⇒ **对拍数敏感** ——
    //         ⭐ `S_PROMPT` 从 1 拍改成 2 拍后，相位整体偏移 1 拍
    //         ⇒ 🔴 喂帧的节奏与状态机对不上 ⇒ **误判成 off-by-one**。
    //      ⭐ 修法：⭐ **喂帧前先等状态机真进到目标状态**（⛔ 不数固定拍数）
    //         ⇒ ⭐ 本 tb 从此**不依赖 `S_PROMPT` 的具体拍数**。
    task feed(input [11:0] v);
        begin
            @(negedge clk);
            sample_ch_i    = 3'd0;      // ⭐ 目标轴 = 0
            raw_i          = v;
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
        end
    endtask

    // ⭐ 等状态机进入某个状态（⭐ 带超时兜底，⛔ 不无限等）
    task wait_state(input [2:0] want, input integer max_cyc);
        integer n;
        begin
            n = 0;
            while ((state_o !== want) && (n < max_cyc)) begin
                @(negedge clk);
                n = n + 1;
            end
        end
    endtask

    integer i;
    reg [11:0] A, B;
    reg saw_span;
    reg saw_rej;

    initial begin
        $display("=== tb_span_vote_offbyone 开始（VOTE_N=%0d VOTE_TOL=%0d）===", VOTE_N, VOTE_TOL);

        // ── 复位 ──────────────────────────────────────────────────────
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

        // ── 启动 `'S'` ────────────────────────────────────────────────
        @(negedge clk); start_i = 1;
        @(negedge clk); start_i = 0;

        A = 12'd2000;                       // 稳定值
        B = 12'd2000 + VOTE_TOL + 12'd40;   // 🔴 离群值：明显超 VOTE_TOL

        // ── ① 先让 S_SETTLE 满足（STABLE_NEED 帧同值）──────────────────
        //    ⭐ 用"等状态"而不是"数固定拍数" ⇒ ⭐ 对 S_PROMPT 的拍数变化免疫
        wait_state(3'd2, 50);           // ⭐ 等进 S_SETTLE
        for (i = 0; i < STABLE_NEED + 2; i = i + 1) begin
            feed(A);
            @(negedge clk);
        end
        $display("  · SETTLE 阶段喂了 %0d 帧 A=%0d，当前 state=%0d", STABLE_NEED + 2, A, state_o);

        // ── ② 进入 VOTE：喂 VOTE_N-1 帧 A，最后 1 帧 B ────────────────
        saw_span = 0;
        saw_rej  = 0;
        wait_state(3'd3, 200);          // ⭐ 等进 S_VOTE
        for (i = 0; i < VOTE_N - 1; i = i + 1) begin
            feed(A);
            @(negedge clk);
        end
        $display("  · VOTE 阶段已喂 %0d 帧 A，当前 state=%0d", VOTE_N - 1, state_o);

        // ⭐ 关键：最后这一帧是【唯一的离群点】
        feed(B);
        repeat (6) @(negedge clk);
        $display("  · 已喂最后 1 帧 B=%0d（离群，超 VOTE_TOL %0d）⇒ state=%0d",
                 B, VOTE_TOL, state_o);

        // ⭐ 再等几拍，看它有没有发 span（发 span = 把离群样本当合法用了）
        repeat (40) @(negedge clk);
        if (|span_o) saw_span = 1;
        if (rejects > 0) saw_rej = 1;

        $display("--------------------------------------------------");
        $display("  reject 次数 = %0d", rejects);
        $display("  state       = %0d", state_o);
        $display("  发过 span?  = %0d", saw_span);
        $display("--------------------------------------------------");

        // ── 判定 ──────────────────────────────────────────────────────
        if (rejects > 0) begin
            $display("ok   : RTL 正确 —— 最后一帧的离群值【被看见】并拒绝了该组样本");
        end else begin
            $display("FAIL : 🔴 RTL 有 off-by-one —— 最后一帧的离群值【没参与】判定，");
            $display("       样本被当成合法的了（reject=0）");
            fails = fails + 1;
        end

        if (fails == 0) $display("PASS: 投票窗口覆盖了全部 VOTE_N 帧");
        else            $display("FAIL: 投票窗口丢了最后一帧（K-129 成立）");

        $finish;
    end

    // 超时保险
    initial begin
        #5000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
