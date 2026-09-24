// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_with_real_adc_farm —— ⭐【真 adc_farm】驱动【真 calib_span】
//
//  🔴 **为什么需要这支 tb（⭐ 本轮最重要的方法教训）**：
//     ⭐ 我前面 5 支 tb **全部用"合成"的 sample_valid 发生器**（⭐ 每 40 拍均匀给一个）。
//     🔴 而真 `adc_farm` 的时序完全不同：
//        · ⭐ 8 个 `sample_valid` **密集出现在一帧的前 9800 拍**（⭐ 8 × 1225 拍 conv）
//        · 🔴 之后 **15200 拍一个都没有**（⭐ `STATE_WAIT_PERIOD` 空等）
//        · ⭐ 通道号是 **driver_done 那拍才算稳定**
//     ⇒ ⚠️ **"均匀合成"掩盖了真实的相位/节拍特性** ⇒ 🔴 **必须联仿才能证伪**。
//
//  ⭐ 本 tb 用 MCP3208 行为模型 + 真 `adc_farm` + 真 `calib_span`，
//     并让轴 0（ch0）保持稳定值，⭐ 看它能否标定成功。
//
//  ⚠️ 为了让仿真不至于跑几十分钟：
//     · ⭐ **保持 `CHANNEL_RATE_HZ` / `TIMEOUT` 的比值合理**（⭐ 用真参数跑，见 K-129）
//     · ⭐ `WAIT_TIMEOUT_CLK` 取真值比例：⭐ 帧 25000 拍 ⇒ 超时 2000 帧 = 50_000_000 拍
//       ⚠️ 但那样 tb 要跑很久 ⇒ ⭐ 只跑**足够标定完 1~2 轴**的时间
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_with_real_adc_farm;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                 // 50 MHz

    // ── adc_farm 的物理接口 ──────────────────────────────────────────────
    wire [N_ADC-1:0] af_cs_n;
    wire             af_sclk_unused;       // farm 输出 [N_ADC-1:0]
    wire [N_ADC-1:0] af_sclk;
    wire [N_ADC-1:0] af_mosi;
    wire [N_ADC-1:0] af_miso;

    wire        s_valid;
    wire [2:0]  s_ch;
    wire [2*12-1:0] s_data;

    // ── MCP3208 模型（本 tb 用 2 片）─────────────────────────────────────
    // ⭐⭐ 复刻上板实测：⭐ **只有 ch7 被按下**（2171 → 2903），⭐ 其余通道保持松手
    //    · ⭐ `ch_mask_i[7] = 1`、`ch_val_i = 2903` ⇒ ⭐ 只有通道 7 返回 2903
    //    · ⚠️ 其余通道走 `IDVAL + ch` ⇒ ⭐ 我用 IDVAL 让它们的值落在实测区间（2139~2196）
    reg        ovr_en  [0:N_ADC-1];
    reg [11:0] ovr_val [0:N_ADC-1];
    reg [7:0]  chmask  [0:N_ADC-1];
    reg [11:0] chval   [0:N_ADC-1];

    genvar gi;
    generate
        for (gi = 0; gi < N_ADC; gi = gi + 1) begin : gen_model
            mcp3208_model #(
                // ⭐ 让"松手"的各通道落在实测值附近（⭐ IDVAL=2139 ⇒ ch0..7 = 2139..2146）
                .IDVAL (12'd2139)
            ) u_model (
                .cs_n      (af_cs_n[gi]),
                .sclk      (af_sclk[gi]),
                .mosi      (af_mosi[gi]),
                .miso      (af_miso[gi]),
                .ovr_en_i  (ovr_en[gi]),
                .ovr_val_i (ovr_val[gi]),
                .ch_mask_i (chmask[gi]),
                .ch_val_i  (chval[gi])
            );
        end
    endgenerate

    adc_farm #(
        .N_ADC           (N_ADC),
        .CLK_HZ          (50_000_000),
        .SCLK_HZ         (1_000_000),
        .CHANNEL_RATE_HZ (2_000)          // ⭐ 真参数：帧 = 25000 拍
    ) u_farm (
        .clk               (clk),
        .rst_n             (rst_n),
        .enable            (1'b1),
        .adc_cs_n          (af_cs_n),
        .adc_sclk          (af_sclk),
        .adc_mosi          (af_mosi),
        .adc_miso          (af_miso),
        .sample_valid      (s_valid),
        .sample_ch         (s_ch),
        .sample_data_packed(s_data),
        .sample_data0      (),
        .sample_data1      (),
        .sample_data2      (),
        .frame_done        (),
        .fault             ()
    );

    // ⭐⭐ 关键：模型按【通道号】返回值
    //    ⚠️ 真 mcp3208_model 的返回值 = IDVAL + 通道号 ⇒ ⚠️ 差太小（1 个码）
    //    ⇒ 🔴 我要模拟"按下/松手"的大差 ⇒ ⭐ 用 ovr 强制按通道给值
    //    📌 做法：⭐ 监听 mosk 的命令字取通道号不好做 ⇒ ⭐ 改为【按 CSCLK 计数】不可靠。
    //    ⇒ ⭐ 最稳的办法：⭐ 让模型每次 done 后我们从它的内部取通道号。
    //    📌 但模型接口不暴露通道号 ⇒ ⭐ 换个更直接的做法：
    //       ⭐ **不用 mcp3208_model，自己写一个"会说人话"的 SPI 从机**，
    //          它按 MOSI 收到的通道号返回对应值。⭐ 见下方 `spi_slave_chan`。

    reg [11:0] raw0_pol;
    // ⭐ 片 0 的极性反相（⭐ 与 top.v 的 axis_polarity 一致：4095 - v）
    always @(*) raw0_pol = 12'hFFF - s_data[11:0];

    // ── calib_span（真参数）────────────────────────────────────────────
    reg  start_i = 0, abort_i = 0;
    reg  cal_busy_i = 0, cal_err_i = 0;
    wire [N_ADC-1:0] sp_span;
    wire [2:0]  sp_ch;
    wire        sp_busy, sp_done, sp_reject, sp_need_press;
    wire [3:0]  sp_cur_axis, sp_done_cnt, sp_rej_cnt;
    wire [2:0]  sp_state;

    integer spans = 0, rejects = 0;
    always @(posedge clk) begin
        if (sp_reject) rejects = rejects + 1;
        if (|sp_span)  spans   = spans + 1;
    end

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        .WAIT_TIMEOUT_CLK(50_000_000),      // ⭐ 真值 = 1 秒 = 2000 帧
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

    // ⭐ 只跑 1.5 秒仿真时间（⚠️ 足够标定几轴；⭐ 全 16 轴要 ~8 帧/轴 × 16 × 500us = 64ms）
    integer state_hist [0:7];
    integer i;
    initial begin
        $display("=== tb_span_with_real_adc_farm（真 adc_farm + 真 calib_span）===");
        $display("⭐ 帧周期 = 25000 拍 = 500 us（⭐ 真参数 CHANNEL_RATE_HZ=2000）");
        $display("⭐ TIMEOUT = 50_000_000 拍 = 1 秒 = 2000 帧（⭐ 真值）");
        $display("");

        for (i = 0; i < N_ADC; i = i + 1) begin
            ovr_en[i]  = 1'b0;
            ovr_val[i] = 12'd0;
            chmask[i]  = 8'h00;
            chval[i]   = 12'd0;
        end

        // ⭐⭐ 复刻上板：⭐ 片 0 的 **通道 7 被按住**（⭐ 2903），⭐ 其余保持松手
        //    📌 为什么用 ch7：⭐ 上板实测就是 ch7 从 2171 跳到 2903
        //    ⚠️ 注意轴的映射：⭐ `calib_span` 的 `cur_axis[2:0]` = 通道号
        //       ⇒ ⭐ 轴 0..7 = 片0 的 ch0..7 ⇒ ⭐ ch7 对应 **轴 7**
        chmask[0] = 8'h80;          // ⭐ 只有 bit7 置位 ⇒ 只有通道 7 覆盖
        chval[0]  = 12'd2903;       // ⭐ 按住特征值（⭐ 与实测一致）
        $display("⭐ 复刻上板：片0 的 ch7 被按住 = 2903，其余走 IDVAL+ch（2139~2146）");
        $display("   ⇒ 跨通道极差 = 2903 - 2139 = 764（⭐ 与实测 762 同量级）");

        rst_n = 0; start_i = 0;
        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (100) @(negedge clk);

        // ⭐ 启动 span 标定
        @(negedge clk); start_i = 1;
        @(negedge clk); start_i = 0;

        // ⭐ 跑 60 ms 仿真时间（⭐ 足够标定 ~7 轴：⭐ 每轴 ~8ms）
        #60_000_000;   // 60 ms

        $display("--------------------------------------------------");
        $display("结果：span=%0d  reject=%0d  state=%0d  axis=%0d done_cnt=%0d rej_cnt=%0d",
                 spans, rejects, sp_state, sp_cur_axis, sp_done_cnt, sp_rej_cnt);
        $display("--------------------------------------------------");

        if (spans > 0 && rejects == 0) begin
            $display("ok  : 真 adc_farm 驱动下，calib_span 能正常标定（span>0, reject=0）");
            $display("      => ✅ 说明【真实采样时序】下状态机工作正常");
            $display("      => 🔴 上板失败的原因在别处（不是采样时序）");
        end else if (spans == 0 && rejects > 0) begin
            $display("FAIL: 🔴 真 adc_farm 驱动下 calib_span 被拒（span=0 reject=%0d）", rejects);
            $display("      => 🔴🔴 **复现了上板现象！** 根因在【真采样时序】与合成的差异");
        end else begin
            $display("NOTE: spans=%0d rejects=%0d state=%0d —— 需要人工判读", spans, rejects, sp_state);
        end

        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
