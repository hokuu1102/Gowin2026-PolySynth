`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_i2s_tx · T7 / **M1 的核心判据**：`i2s_tx` 发出去的样点，被 **S2 模型解串回来逐点比对**
//
// 判据（`files/20-代码/仿真与验证方案.md` §三 M1）：
//   1. ⭐ **解串回的样点与激励逐点一致**（比 DATA_BITS 有效位；24 bit 内部样点取高 16 位）
//   2. `HP_BCK` 周期 = 16 clk（3.125 MHz）、`HP_WS` 周期 = 1024 clk（48.828125 kHz）
//   3. `HP_WS` 低 = 左声道；帧起点处为低（标准极性；`LRCK_POL=0`）
//   4. A8：`HP_BCK/HP_WS/HP_DIN` 全程无 X/Z
//   5. ⭐ 把解串样点写成 CSV（`sim/evidence/`）⇒ 交给 `tools/csv_fft.py` 出**单谱峰**证据
//
// 激励：64 点正弦表，每帧一个点 ⇒ 音高 = fs/64 = **762.939 Hz**（便于 FFT 验证）
//   左声道 = 表[帧号]，右声道 = 表[帧号+16]（相位差 90°，便于区分左右）
//
// ⚠️ 逐点比对只比 **16 bit 有效位**：`i2s_tx` 取的是 24 bit 高 16 位（直接截断、无舍入），
//    所以"24 bit 全等"本来就不成立 —— 这是 16 bit DAC 的既定量化，⛔ 不是 bug。
// ─────────────────────────────────────────────────────────────────────────────
module tb_i2s_tx;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer MCLK_DIV       = 4;
    localparam integer SLOT_BITS      = CLK_PER_SAMPLE / BCLK_DIV / 2;   // 32
    localparam integer DATA_BITS      = 16;
    localparam integer SAMPLE_W       = 24;
    localparam integer JUSTIFY        = 1;    // LSBJ 右对齐（K-39 已结案：PT8211 = 日本格式）
    localparam integer MSB_DELAY      = 1;
    localparam integer LRCK_POL       = 0;
    localparam integer N_FRAMES       = 256;  // 4 个正弦周期

    localparam integer T = 20;                // 50 MHz

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ── 时基 ────────────────────────────────────────────────────────
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;
    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
    ) u_clk (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (tick_audio), .mclk_en (mclk_en),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .lrclk (lrclk), .frame_start (frame_start)
    );

    // ── 激励：64 点正弦表 ───────────────────────────────────────────
    integer i;
    reg signed [SAMPLE_W-1:0] sine_tbl [0:63];
    initial begin
        for (i = 0; i < 64; i = i + 1)
            sine_tbl[i] = $rtoi(0.5 * 8388607.0 * $sin(2.0 * 3.141592653589793 * i / 64.0));
    end

    reg signed [SAMPLE_W-1:0] s_l, s_r;        // 送给 i2s_tx 的样点
    reg signed [SAMPLE_W-1:0] exp_l [0:N_FRAMES+2];
    reg signed [SAMPLE_W-1:0] exp_r [0:N_FRAMES+2];
    integer n_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_frame <= 0;
            s_l <= sine_tbl[0];
            s_r <= sine_tbl[16];
            exp_l[0] <= sine_tbl[0];
            exp_r[0] <= sine_tbl[16];
        end else if (tick_audio === 1'b1) begin
            // ⭐ 提前一帧给数据：i2s_tx 在"右时隙末尾"装载下一帧的样点
            n_frame <= n_frame + 1;
            s_l <= sine_tbl[(n_frame + 1) & 6'h3f];
            s_r <= sine_tbl[((n_frame + 1) + 16) & 6'h3f];
            exp_l[n_frame + 1] <= sine_tbl[(n_frame + 1) & 6'h3f];
            exp_r[n_frame + 1] <= sine_tbl[((n_frame + 1) + 16) & 6'h3f];
        end
    end

    // ── 被测：I2S 发送 ──────────────────────────────────────────────
    wire HP_BCK, HP_WS, HP_DIN;
    i2s_tx #(
        .SAMPLE_W  (SAMPLE_W),
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (SLOT_BITS),
        .JUSTIFY   (JUSTIFY),
        .MSB_DELAY (MSB_DELAY),
        .LRCK_POL  (LRCK_POL)
    ) u_tx (
        .clk (clk), .rst_n (rst_n),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .frame_start (frame_start),
        .sample_l (s_l), .sample_r (s_r),
        .HP_BCK (HP_BCK), .HP_WS (HP_WS), .HP_DIN (HP_DIN)
    );

    // ── S2 模型：解串 ───────────────────────────────────────────────
    wire signed [SAMPLE_W-1:0] rx_l, rx_r, rc_l, rc_r;
    wire rx_vl, rx_vr;
    i2s_rx_model #(
        .SAMPLE_W (SAMPLE_W), .DATA_BITS (DATA_BITS), .SLOT_BITS (SLOT_BITS),
        .JUSTIFY (JUSTIFY), .MSB_DELAY (MSB_DELAY), .LRCK_POL (LRCK_POL),
        .RECON_FILTER (1), .FS_HZ (48828.125), .RECON_FC_HZ (18000.0)
    ) u_rx (
        .clk (clk), .rst_n (rst_n),
        .bck (HP_BCK), .ws (HP_WS), .din (HP_DIN),
        .sample_l (rx_l), .sample_r (rx_r),
        .valid_l (rx_vl), .valid_r (rx_vr),
        .recon_l (rc_l), .recon_r (rc_r)
    );

    // ── A8：X/Z 传播（声明必须在例化之前）────────────────────────────
    wire [31:0] a8_bck, a8_ws, a8_din;
    chk_xprop #(.W(1), .NAME("HP_BCK")) u_a8_bck (.clk(clk), .rst_n(rst_n), .sig(HP_BCK), .err_cnt(a8_bck));
    chk_xprop #(.W(1), .NAME("HP_WS"))  u_a8_ws  (.clk(clk), .rst_n(rst_n), .sig(HP_WS),  .err_cnt(a8_ws));
    chk_xprop #(.W(1), .NAME("HP_DIN")) u_a8_din (.clk(clk), .rst_n(rst_n), .sig(HP_DIN), .err_cnt(a8_din));

    // ── 逐点比对 + 度量 ─────────────────────────────────────────────
    integer errors = 0;
    integer cnt_l, cnt_r, ok_l, ok_r, bad_l, bad_r;
    integer show_n;
    integer t_win, n_bck_edge, n_ws_edge;
    integer last_bck, gap_bck_min, gap_bck_max;
    integer ws_period_min, ws_period_max, last_ws_rise;
    integer ws_low_cycles, ws_high_cycles;
    integer ws_low_at_frame;
    integer ws_chk_wait, n_ws_frame_chk;
    reg     bck_d, ws_d;
    integer fd_l, fd_r;

    initial begin
        $dumpfile("build/sim/tb_i2s_tx/tb_i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        cnt_l = 0; cnt_r = 0; ok_l = 0; ok_r = 0; bad_l = 0; bad_r = 0;
        show_n = 0; t_win = 0; n_bck_edge = 0; n_ws_edge = 0;
        last_bck = -1; gap_bck_min = 1 << 30; gap_bck_max = 0;
        ws_period_min = 1 << 30; ws_period_max = 0; last_ws_rise = -1;
        ws_low_cycles = 0; ws_high_cycles = 0; ws_low_at_frame = 0;
        ws_chk_wait = 0; n_ws_frame_chk = 0;

        fd_l = $fopen("sim/evidence/i2s_tx_l.csv", "w");
        fd_r = $fopen("sim/evidence/i2s_tx_r.csv", "w");
        $fdisplay(fd_l, "# i2s_tx 解串（S2 模型）左声道样点 24bit；fs=48828.125 Hz；音高=fs/64=762.939 Hz");
        $fdisplay(fd_r, "# i2s_tx 解串（S2 模型）右声道样点 24bit；fs=48828.125 Hz");

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (CLK_PER_SAMPLE * (N_FRAMES + 4)) @(posedge clk);
        #1;
        $fclose(fd_l);
        $fclose(fd_r);

        $display("");
        $display("================ i2s_tx / S2 解串实测 ================");
        $display("  帧数        : 收到左 %0d / 右 %0d 个样点（期望 %0d）", cnt_l, cnt_r, N_FRAMES);
        $display("  逐点一致    : 左 %0d 对 / %0d 错 · 右 %0d 对 / %0d 错", ok_l, bad_l, ok_r, bad_r);
        $display("  HP_BCK 周期 : min=%0d max=%0d clk（期望 %0d = 3.125 MHz）",
                 gap_bck_min, gap_bck_max, BCLK_DIV);
        $display("  HP_WS  周期 : min=%0d max=%0d clk（期望 %0d = 48.828125 kHz）",
                 ws_period_min, ws_period_max, CLK_PER_SAMPLE);
        $display("  HP_WS  占空 : 低 %0d / 高 %0d clk", ws_low_cycles, ws_high_cycles);
        $display("  样点 CSV    : sim/evidence/i2s_tx_l.csv / _r.csv（交给 tools/csv_fft.py）");
        $display("=====================================================");

        if (ok_l >= N_FRAMES - 1 && bad_l == 0)
            $display("  ok : 左声道解串样点与激励**逐点一致**（%0d 点）", ok_l);
        else begin
            $display("FAIL: 左声道逐点比对不通过（对 %0d / 错 %0d，期望 ≥ %0d 且 0 错）",
                     ok_l, bad_l, N_FRAMES - 1);
            errors = errors + 1;
        end

        if (ok_r >= N_FRAMES - 1 && bad_r == 0)
            $display("  ok : 右声道解串样点与激励**逐点一致**（%0d 点）", ok_r);
        else begin
            $display("FAIL: 右声道逐点比对不通过（对 %0d / 错 %0d）", ok_r, bad_r);
            errors = errors + 1;
        end

        if (gap_bck_min == BCLK_DIV && gap_bck_max == BCLK_DIV)
            $display("  ok : HP_BCK 周期恰好 %0d clk（3.125 MHz）", BCLK_DIV);
        else begin
            $display("FAIL: HP_BCK 周期不是恰好 %0d（min=%0d max=%0d）",
                     BCLK_DIV, gap_bck_min, gap_bck_max);
            errors = errors + 1;
        end

        if (ws_period_min == CLK_PER_SAMPLE && ws_period_max == CLK_PER_SAMPLE)
            $display("  ok : HP_WS 周期恰好 %0d clk（48.828125 kHz）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: HP_WS 周期不是恰好 %0d（min=%0d max=%0d）",
                     CLK_PER_SAMPLE, ws_period_min, ws_period_max);
            errors = errors + 1;
        end

        if (ws_low_at_frame == 0 && n_ws_frame_chk > 0)
            $display("  ok : HP_WS 低 = 左声道（%0d 个帧起点处均为低）", n_ws_frame_chk);
        else begin
            $display("FAIL: HP_WS 极性/相位不对（帧起点处 %0d 次非低）", ws_low_at_frame);
            errors = errors + 1;
        end

        if (a8_bck == 0 && a8_ws == 0 && a8_din == 0)
            $display("  ok : A8 无 X/Z 传播（HP_BCK/HP_WS/HP_DIN）");
        else begin
            $display("FAIL: A8 检测到 X/Z（bck=%0d ws=%0d din=%0d）", a8_bck, a8_ws, a8_din);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: i2s_tx + S2 解串逐点一致（M1 的核心判据通过）");
        else             $fatal(1, "FAIL: i2s_tx 有 %0d 项不符合预期", errors);

        #100;
        $finish;
    end

    // 帧起点处 HP_WS 必须为低（= 左声道）—— 上面的 `ws_low_at_frame == 0` 就是判据

    // ── 采样 + 比对（全在 clk 域里做，避免竞争）──────────────────────
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            t_win = t_win + 1;

            // HP_BCK 上升沿间隔
            // ⚠️ 必须先比较、再更新 `bck_d` —— 反了的话 `bck_d` 刚被赋成新值，边沿永远检测不到
            if (HP_BCK === 1'b1 && bck_d === 1'b0) begin
                n_bck_edge = n_bck_edge + 1;
                if (last_bck >= 0) begin
                    if (t_win - last_bck < gap_bck_min) gap_bck_min = t_win - last_bck;
                    if (t_win - last_bck > gap_bck_max) gap_bck_max = t_win - last_bck;
                end
                last_bck = t_win;
            end
            bck_d = HP_BCK;

            // HP_WS 上升沿间隔（一个完整帧）
            if (HP_WS === 1'b1 && ws_d === 1'b0) begin
                n_ws_edge = n_ws_edge + 1;
                if (last_ws_rise >= 0) begin
                    if (t_win - last_ws_rise < ws_period_min) ws_period_min = t_win - last_ws_rise;
                    if (t_win - last_ws_rise > ws_period_max) ws_period_max = t_win - last_ws_rise;
                end
                last_ws_rise = t_win;
            end
            ws_d = HP_WS;

            if (HP_WS === 1'b1) ws_high_cycles = ws_high_cycles + 1;
            else                ws_low_cycles  = ws_low_cycles  + 1;

            // ⭐ WS 相位：帧起点后 2 拍再查（`HP_WS` 是寄存输出，边界那一拍才开始更新）
            if (tick_audio === 1'b1) ws_chk_wait = 2;
            if (ws_chk_wait > 0) begin
                ws_chk_wait = ws_chk_wait - 1;
                if (ws_chk_wait == 0) begin
                    if (HP_WS !== 1'b0) ws_low_at_frame = ws_low_at_frame + 1;
                    n_ws_frame_chk = n_ws_frame_chk + 1;
                end
            end

            // ⭐ S2 解串出的样点 vs 激励（**只比 16 bit 有效位**）
            if (rx_vl === 1'b1) begin
                cnt_l = cnt_l + 1;
                $fdisplay(fd_l, "%0d", rx_l);
                if (cnt_l <= N_FRAMES) begin
                    if (rx_l[SAMPLE_W-1 -: DATA_BITS] === exp_l[cnt_l-1][SAMPLE_W-1 -: DATA_BITS]) begin
                        ok_l = ok_l + 1;
                        if (show_n < 4) begin
                            $display("  · 左 #%0d 解串=%0d 期望=%0d（高 %0d 位一致）",
                                     cnt_l - 1, rx_l, exp_l[cnt_l-1], DATA_BITS);
                            show_n = show_n + 1;
                        end
                    end else begin
                        bad_l = bad_l + 1;
                        if (bad_l <= 3)
                            $display("  ⛔ 左 #%0d 解串=%0d(0x%06h) 期望=%0d(0x%06h)",
                                     cnt_l - 1, rx_l, rx_l, exp_l[cnt_l-1], exp_l[cnt_l-1]);
                    end
                end
            end

            if (rx_vr === 1'b1) begin
                cnt_r = cnt_r + 1;
                $fdisplay(fd_r, "%0d", rx_r);
                if (cnt_r <= N_FRAMES) begin
                    if (rx_r[SAMPLE_W-1 -: DATA_BITS] === exp_r[cnt_r-1][SAMPLE_W-1 -: DATA_BITS])
                        ok_r = ok_r + 1;
                    else begin
                        bad_r = bad_r + 1;
                        if (bad_r <= 3)
                            $display("  ⛔ 右 #%0d 解串=%0d 期望=%0d", cnt_r - 1, rx_r, exp_r[cnt_r-1]);
                    end
                end
            end
        end
    end

endmodule
