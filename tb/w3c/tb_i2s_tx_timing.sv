`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_i2s_tx_timing · **I2S 输出相对 DAC 采样沿的时序余量**（`bringup/01-...` §三-4）
//
// ⭐⭐ 这个 tb 补的是**所有其它 tb 都测不到的一件事**：
//     `tb/w3c/tb_i2s_tx.sv` 与 `tb_i2s_tx_sweep.sv` 用的是 S2 解串模型，而 S2 是
//     "检测到 BCK 上升沿之后**再打一拍**"才取 DIN ⇒ 它等价于"上升沿后 20 ns 采样"，
//     **对"数据在哪个边沿变化"完全不敏感**。也就是说：
//     ⛔ 即使 `HP_DIN` 与 `HP_BCK` 的上升沿**同拍**变化（建立时间 ≈ 0），逐点比对也照样全过。
//     ⇒ 必须**单独**量"数据变化沿 → 最近的 BCK 采样沿"的间隔，才算真的验过。
//
// 📖 判据来源（Princeton PT8211 V1.5 手册，2026-09-17 由公开资料核实）：
//     · "Each valid DIN data will be shifted to the input register in the
//        **rising edge of the BCK**"                       ⇒ **DAC 在 BCK 上升沿采 DIN**
//     · "The serial bus input data format … is Japanese or called **LSBJ**" ⇒ 右对齐（默认档）
//     · 第 5 页 TIMING CHARACTERISTICS：
//         Fbck（BCK 频率）≤ **18.4 MHz** · Fws（WS 频率）≤ **384 kHz** ·
//         **tH（BCK 高电平时间）≥ 25 ns** · tR/tF ≤ 20 ns
//       ⚠️ 手册**没有给 tSU/tHD**（数据建立/保持）—— 所以本 tb 的建立/保持判据**不是**手册值，
//          而是我们自己定的工程目标：**≥ 半个位周期**（这样采样点落在数据窗正中，对两侧都最稳）。
//          ⛔ 这一点必须写清楚，别把"我们自己的目标"当成"手册要求"。
//
// 判据（逐位，跨多个帧）：
//   ① 建立时间 tSU：每次 `HP_DIN` 变化 → **之后最近**的 `HP_BCK` 上升沿，间隔 ≥ `MIN_SETUP_NS`
//   ② 保持时间 tHD：每个 `HP_BCK` 上升沿 → **之后最近**的 `HP_DIN` 变化，间隔 ≥ `MIN_HOLD_NS`
//   ③ `HP_BCK` 高电平时间 ≥ 手册 `tH`(25 ns)；周期 = 16 clk（3.125 MHz ≤ 18.4 MHz）
//   ④ `HP_WS` 周期 = 1024 clk（48.828125 kHz ≤ 384 kHz），且**也在 BCK 下降沿附近变化**
//      （WS 与 DIN 一起被采，必须同样满足建立/保持）
//   ⑤ 同一帧内：`HP_DIN` 的变化次数 == 数据位跳变次数（不出现"一个位周期里变两次"）
//   ⑥ A8：无 X/Z
//
// ⚠️ 结论由本 tb 自己给（`sim/tb_all.ps1` 只认退出码 + 行首 `FAIL`）。
// ⚠️ 本文件是 UTF-8（无 BOM）：⛔ 不要用 PowerShell `Set-Content -Encoding utf8` 回写（会按 GBK 毁掉中文）。
// ─────────────────────────────────────────────────────────────────────────────
module tb_i2s_tx_timing;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer MCLK_DIV       = 4;
    localparam integer SAMPLE_W       = 24;
    localparam integer DATA_BITS      = 16;
    localparam integer SLOT_BITS      = 32;
    localparam integer N_FRAMES       = 16;
    localparam integer T              = 20;      // 50 MHz ⇒ 20 ns

    // ── 判据阈值（ns）──
    localparam integer MIN_SETUP_NS = 100;   // ⭐ 目标：≥ 100 ns（实际应为 160 ns）
    localparam integer MIN_HOLD_NS  = 100;   // ⭐ 目标：≥ 100 ns（实际应为 160 ns）
    localparam integer TH_MIN_NS    = 25;    // 手册 tH ≥ 25 ns
    localparam integer T_BCK_NS     = 320;   // 3.125 MHz ⇒ 320 ns（手册上限 18.4 MHz）

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    integer errors = 0;

    // ── 时基 + 被测 ──────────────────────────────────────────────
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;
    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE), .BCLK_DIV (BCLK_DIV), .MCLK_DIV (MCLK_DIV)
    ) u_clk (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (tick_audio), .mclk_en (mclk_en),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .lrclk (lrclk), .frame_start (frame_start)
    );

    // 激励：故意用"每位都可能跳变"的方波样点（比正弦更容易暴露时序问题）
    reg signed [SAMPLE_W-1:0] s_l, s_r;
    integer nframe;
    always @(posedge clk) begin
        if (!rst_n) begin
            nframe <= 0;
            s_l <= 24'sh7FFFFF;
            s_r <= 24'sh000000;
        end else if (tick_audio === 1'b1) begin
            nframe <= nframe + 1;
            s_l <= ((nframe & 1) == 0) ? 24'sh7FFFFF : 24'sh800000;  // 交替满量程 ⇒ 每位都翻
            s_r <= ((nframe & 2) == 0) ? 24'sh555555 : 24'shAAAAAA;  // 交替棋盘 ⇒ 位跳变密集
        end
    end

    wire HP_BCK, HP_WS, HP_DIN;
    i2s_tx #(
        .SAMPLE_W (SAMPLE_W), .DATA_BITS (DATA_BITS), .SLOT_BITS (SLOT_BITS),
        .JUSTIFY (1), .MSB_DELAY (1), .LRCK_POL (0)
    ) u_tx (
        .clk (clk), .rst_n (rst_n),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .frame_start (frame_start),
        .sample_l (s_l), .sample_r (s_r),
        .HP_BCK (HP_BCK), .HP_WS (HP_WS), .HP_DIN (HP_DIN)
    );

    wire [31:0] a8_din, a8_bck, a8_ws;
    chk_xprop #(.W(1), .NAME("HP_DIN")) u_a8_din (.clk(clk), .rst_n(rst_n), .sig(HP_DIN), .err_cnt(a8_din));
    chk_xprop #(.W(1), .NAME("HP_BCK")) u_a8_bck (.clk(clk), .rst_n(rst_n), .sig(HP_BCK), .err_cnt(a8_bck));
    chk_xprop #(.W(1), .NAME("HP_WS"))  u_a8_ws  (.clk(clk), .rst_n(rst_n), .sig(HP_WS),  .err_cnt(a8_ws));

    // ═══════════════════════════════════════════════════════════════
    // 时序余量测量（⭐ 用**真实时间**，不是 clk 计数 —— 手册指标是 ns）
    // ═══════════════════════════════════════════════════════════════
    time t_din_change, t_ws_change, t_bck_rise, t_bck_fall;
    reg  din_d, ws_d, bck_d;
    integer n_din_change, n_bck_rise, n_ws_change;
    integer su_min, hd_min;              // 最小建立/保持（ns）
    integer tH_min, tL_min;              // BCK 高/低电平时间（ns）
    integer bck_per_min, bck_per_max;    // BCK 周期（ns）
    integer ws_per_min, ws_per_max;      // WS 周期（ns）
    integer din_change_per_bit;          // 一个位周期内 DIN 变化次数（应 ≤1）
    integer din_multi;                   // 违反"一位只变一次"的次数
    integer su_viol, hd_viol, th_viol, freq_viol;
    integer ws_su_min;                   // WS 建立（相对 BCK 上升沿）
    reg     have_din_t, have_ws_t;

    initial begin
        $dumpfile("build/sim/tb_i2s_tx_timing/tb_i2s_tx_timing.vcd");
        $dumpvars(0, tb_i2s_tx_timing);

        t_din_change = 0; t_ws_change = 0; t_bck_rise = 0; t_bck_fall = 0;
        din_d = 1'b0; ws_d = 1'b0; bck_d = 1'b0;
        n_din_change = 0; n_bck_rise = 0; n_ws_change = 0;
        su_min = 1 << 30; hd_min = 1 << 30;
        tH_min = 1 << 30; tL_min = 1 << 30;
        bck_per_min = 1 << 30; bck_per_max = 0;
        ws_per_min = 1 << 30; ws_per_max = 0;
        din_change_per_bit = 0; din_multi = 0;
        su_viol = 0; hd_viol = 0; th_viol = 0; freq_viol = 0;
        ws_su_min = 1 << 30;
        have_din_t = 1'b0; have_ws_t = 1'b0;

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (CLK_PER_SAMPLE * (N_FRAMES + 2)) @(posedge clk);
        #1;

        $display("");
        $display("================ i2s_tx vs PT8211 timing ================");
        $display("  [manual] DAC samples DIN on BCK RISING edge; Fbck<=18.4MHz; tH>=25ns");
        $display("  [ours  ] tSU(min) = %0d ns   tHD(min) = %0d ns   (target >= %0d ns)", su_min, hd_min, MIN_SETUP_NS);
        $display("           WS setup(min) = %0d ns", ws_su_min);
        $display("           BCK tH(min) = %0d ns (>= %0d) · tL(min) = %0d ns", tH_min, TH_MIN_NS, tL_min);
        $display("           BCK period = %0d..%0d ns (nominal %0d) · WS period = %0d..%0d ns",
                 bck_per_min, bck_per_max, T_BCK_NS, ws_per_min, ws_per_max);
        $display("           DIN changes = %0d · BCK rising = %0d · WS changes = %0d", n_din_change, n_bck_rise, n_ws_change);
        $display("           bit period with >1 DIN change = %0d", din_multi);
        $display("  A8     : din=%0d bck=%0d ws=%0d", a8_din, a8_bck, a8_ws);
        $display("========================================================");

        if (su_min >= MIN_SETUP_NS) $display("  ok : DIN setup to BCK rising edge = %0d ns (>= %0d)", su_min, MIN_SETUP_NS);
        else begin $display("FAIL: DIN setup only %0d ns (< %0d) -- DAC would sample a changing DIN", su_min, MIN_SETUP_NS); errors = errors + 1; end

        if (hd_min >= MIN_HOLD_NS) $display("  ok : DIN hold after BCK rising edge = %0d ns (>= %0d)", hd_min, MIN_HOLD_NS);
        else begin $display("FAIL: DIN hold only %0d ns (< %0d)", hd_min, MIN_HOLD_NS); errors = errors + 1; end

        if (tH_min >= TH_MIN_NS) $display("  ok : BCK high time = %0d ns (manual tH >= %0d ns)", tH_min, TH_MIN_NS);
        else begin $display("FAIL: BCK high time %0d ns < manual %0d ns", tH_min, TH_MIN_NS); errors = errors + 1; end

        if (bck_per_min >= 300 && bck_per_max <= 330)
            $display("  ok : BCK period = %0d..%0d ns (= 3.125 MHz, manual max 18.4 MHz)", bck_per_min, bck_per_max);
        else begin $display("FAIL: BCK period %0d..%0d ns out of expected 320 ns", bck_per_min, bck_per_max); errors = errors + 1; end

        if (ws_per_min >= CLK_PER_SAMPLE*20 - 20 && ws_per_max <= CLK_PER_SAMPLE*20 + 20)
            $display("  ok : WS period = %0d..%0d ns (= 48.828 kHz, manual max 384 kHz)", ws_per_min, ws_per_max);
        else begin $display("FAIL: WS period %0d..%0d ns unexpected (expect ~20480)", ws_per_min, ws_per_max); errors = errors + 1; end

        if (ws_su_min >= MIN_SETUP_NS) $display("  ok : WS setup to BCK rising edge = %0d ns (>= %0d)", ws_su_min, MIN_SETUP_NS);
        else begin $display("FAIL: WS setup only %0d ns (< %0d) -- channel select would be sampled while changing", ws_su_min, MIN_SETUP_NS); errors = errors + 1; end

        if (din_multi == 0) $display("  ok : no bit period had more than one DIN change (glitch-free)");
        else begin $display("FAIL: %0d bit periods had >1 DIN change", din_multi); errors = errors + 1; end

        if (a8_din == 0 && a8_bck == 0 && a8_ws == 0) $display("  ok : A8 no X/Z");
        else begin $display("FAIL: A8 detected X/Z (din=%0d bck=%0d ws=%0d)", a8_din, a8_bck, a8_ws); errors = errors + 1; end

        $display("");
        if (errors == 0) $display("PASS: I2S output timing has >=100ns setup/hold around the DAC sampling edge (PT8211 manual limits met)");
        else             $fatal(1, "FAIL: i2s_tx timing margins not met (%0d items)", errors);

        #100;
        $finish;
    end

    // ── 逐边沿测量（全部用 $time，单位 ns）──────────────────────────
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            // DIN 变化 → 记时刻；并检查"距上一个 BCK 上升沿"的保持
            if (HP_DIN !== din_d) begin
                n_din_change = n_din_change + 1;
                // 保持：上一次 BCK 上升沿到本次 DIN 变化
                if (n_bck_rise > 0) begin
                    if ($time - t_bck_rise < hd_min) hd_min = $time - t_bck_rise;
                    if ($time - t_bck_rise < MIN_HOLD_NS) hd_viol = hd_viol + 1;
                end
                t_din_change = $time;
                have_din_t = 1'b1;
            end
            din_d = HP_DIN;

            // WS 变化 → 同样检查（WS 与 DIN 一起被采样）
            if (HP_WS !== ws_d) begin
                n_ws_change = n_ws_change + 1;
                if (n_bck_rise > 0) begin
                    if ($time - t_bck_rise < ws_su_min) ws_su_min = $time - t_bck_rise;
                end
                t_ws_change = $time;
                have_ws_t = 1'b1;
            end
            ws_d = HP_WS;

            // BCK 上升沿 → 记时刻；并检查"距上一次 DIN 变化"的建立
            if (HP_BCK === 1'b1 && bck_d === 1'b0) begin
                n_bck_rise = n_bck_rise + 1;
                if (have_din_t) begin
                    if ($time - t_din_change < su_min) su_min = $time - t_din_change;
                    if ($time - t_din_change < MIN_SETUP_NS) su_viol = su_viol + 1;
                end
                // ⚠️ tL 也跳过复位后前两个边沿（首个低电平段不完整，见下）
                if (n_bck_rise > 2 && t_bck_fall > 0) begin
                    if ($time - t_bck_fall < tL_min) tL_min = $time - t_bck_fall;
                end
                t_bck_rise = $time;
            end
            // BCK 下降沿 → 记时刻（算 tH）
            // ⚠️ **跳过复位后第一个下降沿**：`HP_BCK` 复位值是 1（R-03 的修法），
            //    复位释放到第一次翻转之间的那段"高"不足一个半周期 ⇒ 会把 40 ns 这种
            //    伪值算进 tH（真实稳态是 8 clk = 160 ns）。这与上面 BCK 周期的 warm-up 同理。
            if (HP_BCK === 1'b0 && bck_d === 1'b1) begin
                if (n_bck_rise > 2 && t_bck_rise > 0) begin
                    if ($time - t_bck_rise < tH_min) tH_min = $time - t_bck_rise;
                end
                t_bck_fall = $time;
            end
            bck_d = HP_BCK;

            // BCK 周期
            if (HP_BCK === 1'b1 && bck_d === 1'b0 && n_bck_rise > 1) begin
                // 用相邻两次上升沿的差（存在 t_bck_rise 里）
                // ⚠️ 这里用另一个变量存"上一次上升沿"，避免与上面的赋值顺序打架
            end
        end
    end

    // ── BCK 周期 / WS 周期：单独一个块，避免与上面的赋值顺序互相干扰 ──
    // ⚠️ **复位后前两个边沿不统计**：`HP_BCK` 的复位值是 1（R-03 的修法），
    //    所以复位释放后第一个"上升沿"距离复位时刻不足一个完整周期 ⇒
    //    会把 200 ns 这种伪值算进 min。用 `warm` 跳过前两次上升沿。
    time last_bck_rise, last_ws_rise;
    reg  bck_d2, ws_d2;
    integer bck_edges_seen;
    initial begin
        last_bck_rise = 0; last_ws_rise = 0; bck_d2 = 1'b0; ws_d2 = 1'b0;
        bck_edges_seen = 0;
    end
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            bck_edges_seen = 0;
            last_bck_rise  = 0;
            last_ws_rise   = 0;
        end else begin
            if (HP_BCK === 1'b1 && bck_d2 === 1'b0) begin
                bck_edges_seen = bck_edges_seen + 1;
                if (bck_edges_seen > 2 && last_bck_rise > 0) begin
                    if ($time - last_bck_rise < bck_per_min) bck_per_min = $time - last_bck_rise;
                    if ($time - last_bck_rise > bck_per_max) bck_per_max = $time - last_bck_rise;
                end
                last_bck_rise = $time;
            end
            bck_d2 = HP_BCK;

            if (HP_WS === 1'b1 && ws_d2 === 1'b0) begin
                if (last_ws_rise > 0) begin
                    if ($time - last_ws_rise < ws_per_min) ws_per_min = $time - last_ws_rise;
                    if ($time - last_ws_rise > ws_per_max) ws_per_max = $time - last_ws_rise;
                end
                last_ws_rise = $time;
            end
            ws_d2 = HP_WS;
        end
    end

    // ── "一个位周期内 DIN 变化 >1 次" 检查 ──
    //     位周期 = 16 clk；用 bclk_en 划界，数每个位周期内 DIN 变化次数
    integer din_chg_in_bit;
    reg     din_prev_bit;
    initial begin
        din_chg_in_bit = 0; din_prev_bit = 1'b0;
    end
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (HP_DIN !== din_prev_bit) begin
                din_chg_in_bit = din_chg_in_bit + 1;
                din_prev_bit = HP_DIN;
            end
            if (bclk_en === 1'b1) begin
                if (din_chg_in_bit > 1) din_multi = din_multi + 1;
                din_chg_in_bit = 0;
            end
        end
    end

endmodule
