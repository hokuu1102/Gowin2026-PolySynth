// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_released_stable —— ⭐ 决定性问题：⭐【不按键】时标定到底能不能过？
//
//  ⭐⭐ 上板实测形成的**三方矛盾**（2026-09-25）：
//     ⓐ ⭐ 松手时 `'P'` 读数：⭐ ch0=2164，⭐ **Δ ≤ 6**（⭐ 你实测）
//     ⓑ ⭐ 配置：⭐ `STABLE_TOL=48`、⭐ `VOTE_TOL=96`
//     ⓒ 🔴 ⭐ **一直没按键，⭐ `'S'` 仍然被拒 9 次**
//     ⇒ 🔴 **A + B 应该「通过」，⭐ 但 C 说被拒** ⇒ ⚠️ **三者不可能同时成立**
//
//  ⭐ 本 tb 用【真 `adc_farm` + 真模型】跑"松手静止"场景，
//     ⭐ 看它到不到底能不能通过。
//     · ✅ 若**能通过** ⇒ ⭐ 说明上板一定还有别的因素（⭐ 对齐/接线/片选）
//     · 🔴 若**通不过** ⇒ 🔴 **在仿真里就复现了** ⇒ ⭐ 我可以直接开始修
//
//  📌 与 `tb_span_with_real_adc_farm` 的区别：
//     那一支是"**ch7 按住**"（⭐ 值 2903）；
//     ⭐ 本支是"**全部松手**"（⭐ 值都落在 2139~2196）—— ⭐ 这才是你实测的场景。
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_released_stable;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    wire [N_ADC-1:0] af_cs_n;
    wire [N_ADC-1:0] af_sclk, af_mosi, af_miso;
    wire        s_valid;
    wire [2:0]  s_ch;
    wire [2*12-1:0] s_data;

    reg        ovr_en  [0:N_ADC-1];
    reg [11:0] ovr_val [0:N_ADC-1];
    reg [7:0]  chmask  [0:N_ADC-1];
    reg [11:0] chval   [0:N_ADC-1];
    reg [11:0] base    [0:N_ADC-1];   // ⭐ IDVAL（⭐ 松手基准）

    genvar gi;
    generate
        for (gi = 0; gi < N_ADC; gi = gi + 1) begin : gen_model
            // ⭐ IDVAL=2139 ⇒ 8 个通道 = 2139..2146（⭐ 与实测 2139~2196 同量级）
            mcp3208_model #(.IDVAL(12'd2139)) u_model (
                .cs_n(af_cs_n[gi]), .sclk(af_sclk[gi]),
                .mosi(af_mosi[gi]), .miso(af_miso[gi]),
                .ovr_en_i(ovr_en[gi]), .ovr_val_i(ovr_val[gi]),
                .ch_mask_i(chmask[gi]), .ch_val_i(chval[gi])
            );
        end
    endgenerate

    adc_farm #(
        .N_ADC(2), .CLK_HZ(50_000_000), .SCLK_HZ(1_000_000), .CHANNEL_RATE_HZ(2_000)
    ) u_farm (
        .clk(clk), .rst_n(rst_n), .enable(1'b1),
        .adc_cs_n(af_cs_n), .adc_sclk(af_sclk), .adc_mosi(af_mosi), .adc_miso(af_miso),
        .sample_valid(s_valid), .sample_ch(s_ch), .sample_data_packed(s_data),
        .sample_data0(), .sample_data1(), .sample_data2(), .frame_done(), .fault()
    );

    // ⭐ 极性反相（⭐ 与 top.v 一致）
    wire [11:0] raw0_pol = 12'hFFF - s_data[11:0];

    reg  start_i = 0, abort_i = 0;
    reg  cal_busy_i = 0, cal_err_i = 0;
    wire [N_ADC-1:0] sp_span;
    wire [2:0]  sp_ch;
    wire        sp_busy, sp_done, sp_reject, sp_need_press;
    wire [3:0]  sp_cur_axis, sp_done_cnt, sp_rej_cnt;
    wire [2:0]  sp_state;

    integer spans = 0, rejects = 0;
    always @(posedge clk) begin
        if (rst_n && ((^{sp_span, sp_reject, sp_done_cnt, sp_rej_cnt}) === 1'bx))
            $fatal(1, "FAIL: unknown public span status");
        if (sp_reject) rejects = rejects + 1;
        if (|sp_span)  spans   = spans + 1;
    end

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        .WAIT_TIMEOUT_CLK(50_000_000),      // ⭐ 真值 = 1 秒
        .STABLE_TOL(STABLE_TOL), .VOTE_TOL(VOTE_TOL),
        .REJECT_MAX(REJECT_MAX), .POS_W(12)
    ) u_span (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .abort_i(abort_i),
        .sample_valid_i(s_valid), .sample_ch_i(s_ch), .raw_i(raw0_pol),
        .span_o(sp_span), .cal_ch_o(sp_ch),
        .cal_busy_i(cal_busy_i), .cal_err_i(cal_err_i),
        .busy_o(sp_busy), .done_o(sp_done),
        .reject_o(sp_reject), .need_press_o(sp_need_press),
        .cur_axis_o(sp_cur_axis), .done_cnt_o(sp_done_cnt), .rej_cnt_o(sp_rej_cnt),
        .state_o(sp_state)
    );

    always @(posedge clk) begin
        if (rst_n && (|sp_span)) cal_busy_i <= 1'b1;
        else if (cal_busy_i)     cal_busy_i <= 1'b0;
    end

    // ⭐⭐ 记录：⭐ 轴 0 通道被采到的原始值（⭐ 看它到底稳不稳）
    integer n_ch0 = 0;
    reg [11:0] ch0_min = 12'hFFF, ch0_max = 12'd0;

    always @(posedge clk) begin
        if (rst_n && s_valid && (s_ch == 3'd0)) begin
            n_ch0 = n_ch0 + 1;
            if (raw0_pol < ch0_min) ch0_min <= raw0_pol;
            if (raw0_pol > ch0_max) ch0_max <= raw0_pol;
        end
    end

    // ⭐⭐ 状态跳变追踪（⭐ 关键：看它走到哪一步）
    reg [2:0] st_last = 3'd7;
    always @(posedge clk) begin
        if (rst_n && (sp_state !== st_last)) begin
            $display("    [t=%0t] state %0d -> %0d  (axis=%0d rej=%0d)",
                     $time, st_last, sp_state, sp_cur_axis, sp_rej_cnt);
            st_last <= sp_state;
        end
    end

    integer i;
    initial begin
        $display("=== tb_span_released_stable（全部松手，看能不能过）===");
        $display("⭐ 复刻实测：8 通道 = 2139..2146（⭐ 松手值），⭐ 模型固有噪声");
        $display("⭐ STABLE_TOL=%0d VOTE_TOL=%0d", STABLE_TOL, VOTE_TOL);
        $display("");

        for (i = 0; i < N_ADC; i = i + 1) begin
            ovr_en[i]  = 1'b0;
            ovr_val[i] = 12'd0;
            chmask[i]  = 8'h00;      // ⭐ 不覆盖任何通道 ⇒ 全部松手
            chval[i]   = 12'd0;
        end

        rst_n = 0; start_i = 0;
        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (200) @(negedge clk);

        @(negedge clk); start_i = 1;
        @(negedge clk); start_i = 0;

        // ⭐ 跑 60 ms（⭐ 足够 6~7 轴）
        #60_000_000;

        $display("--------------------------------------------------");
        $display("  轴0通道采样次数 = %0d", n_ch0);
        $display("  轴0 raw 范围     = %0d .. %0d  (Δ=%0d)", ch0_min, ch0_max, ch0_max - ch0_min);
        $display("  span=%0d  reject=%0d  state=%0d  done_cnt=%0d",
                 spans, rejects, sp_state, sp_done_cnt);
        $display("--------------------------------------------------");

        if (spans > 0 && rejects == 0) begin
            $display("ok  : 松手静止 ⇒ 标定【能通过】（span=%0d, reject=0）", spans);
            $display("      => 🔴 上板被拒【不是】这个场景本身的问题 ⇒ 另有因素");
        end else if (spans == 0 && rejects > 0) begin
            $display("FAIL: 🔴 松手静止也【被拒】(%0d 次) => ⭐ 复现了上板现象!", rejects);
            $display("      => 🔴 根因就在这条路径上");
        end else begin
            $display("NOTE: span=%0d reject=%0d state=%0d —— 需人工判读", spans, rejects, sp_state);
        end

        if ((ch0_max - ch0_min) < STABLE_TOL)
            $display("ok  : 轴0 帧间变化 Δ=%0d < STABLE_TOL=%0d ⇒ 稳定判定【应能通过】",
                     ch0_max - ch0_min, STABLE_TOL);
        else
            $display("NOTE: 轴0 Δ=%0d >= STABLE_TOL=%0d ⇒ 稳定判定【过不去】",
                     ch0_max - ch0_min, STABLE_TOL);

        $display("==================================================");
        if (spans <= 0 || rejects != 0 || n_ch0 <= 0 ||
            (ch0_max - ch0_min) >= STABLE_TOL)
            $fatal(1, "FAIL: stable released-input calibration or sample coverage");
        $display("PASS: real ADC released-input calibration makes progress without rejection");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb 自身超时");
        $fatal(1, "FAIL: released-input watchdog");
    end

endmodule
