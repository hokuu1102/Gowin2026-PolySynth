`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_top_m0 · **M0 顶层验收**（`files/20-代码/仿真与验证方案.md` §三 M0）
//
// M0 是"地基里最后一块"：**上板之前，顶层本身必须是安全的**。
// 判据（本 tb 逐条给结论）：
//   A · 时基在**顶层端口**上正确：`HP_BCK` 周期 = 16 clk（3.125 MHz）、
//       `HP_WS` 周期 = 1024 clk（48.828125 kHz）
//   B · ⭐ **安全态 `PA_EN_n = 1`（功放关断）**：复位期间就是 1、复位释放后**全程为 1**、
//       **翻转次数 = 0**（"无窄脉冲"的最强形式：一次都没动过）
//   C · 反向检：`PA_ON_AFTER_RESET=1` 时，复位释放后等 `PA_ON_DELAY` 拍才拉低，
//       且**整个仿真只翻转 1 次**（⇒ 上电/切换过程无毛刺）
//   D · 心跳 LED 活着且周期精确（板级"活体见证"；系统时钟留在板载域 ⇒ 故障可观测）
//   E · ⭐ 静音就是**真的静音**：`HP_DIN` 全程为 0（T20 测试音源接进来之前，⛔ 不该有噪声）
//   F · A8：`HP_BCK/HP_WS/HP_DIN/PA_EN_n/led_heartbeat` 复位释放后无 X/Z
//
// ⚠️ 为什么专门测 `PA_EN_n`：它是**低有效**的功放使能。
//    同步复位意味着"上电到第一个时钟沿之间寄存器是未定义的"，所以**引脚上拉**
//    （`constr/top.cst` 里 `PULL_MODE=UP`）才是配置期间功放关断的保证。
//    本 tb 验证的是"**从第一个时钟沿起**它就已经是 1"，上拉那半由 .cst 负责、上板验证。
// ─────────────────────────────────────────────────────────────────────────────
module tb_top_m0;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer N_FRAMES       = 64;      // 65536 clk ≈ 1.31 ms 仿真时间
    localparam integer HB_DIV         = 512;     // 心跳半周期（顶层的 0.5 s 在这里缩到 10.24 µs 以便快速验证）
    localparam integer PA_DELAY_TB    = 100;     // 反向检用的短延时

    localparam integer T = 20;                   // 50 MHz ⇒ 20 ns

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ═══════════════════════════════════════════════════════════════
    // A · 被测顶层（**M0 安全态**：PA_ON_AFTER_RESET = 0）
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_a, HP_WS_a, HP_DIN_a, PA_EN_n_a, hb_a;
    top #(
        .PA_ON_AFTER_RESET (0),
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_safe (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK_a), .HP_WS (HP_WS_a), .HP_DIN (HP_DIN_a),
        .PA_EN_n (PA_EN_n_a), .led_heartbeat (hb_a)
    );

    // ═══════════════════════════════════════════════════════════════
    // C · 反向检：PA_ON_AFTER_RESET = 1（延时开功放）
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_b, HP_WS_b, HP_DIN_b, PA_EN_n_b, hb_b;
    top #(
        .PA_ON_AFTER_RESET (1),
        .PA_ON_DELAY       (PA_DELAY_TB),
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_on (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK_b), .HP_WS (HP_WS_b), .HP_DIN (HP_DIN_b),
        .PA_EN_n (PA_EN_n_b), .led_heartbeat (hb_b)
    );

    // ── F · A8：X/Z 传播（声明必须放在例化之前）──────────────────────
    wire [31:0] a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b;
    chk_xprop #(.W(1), .NAME("HP_BCK"))        u_a8_bck  (.clk(clk), .rst_n(rst_n), .sig(HP_BCK_a),      .err_cnt(a8_bck));
    chk_xprop #(.W(1), .NAME("HP_WS"))         u_a8_ws   (.clk(clk), .rst_n(rst_n), .sig(HP_WS_a),       .err_cnt(a8_ws));
    chk_xprop #(.W(1), .NAME("HP_DIN"))        u_a8_din  (.clk(clk), .rst_n(rst_n), .sig(HP_DIN_a),      .err_cnt(a8_din));
    chk_xprop #(.W(1), .NAME("PA_EN_n"))       u_a8_pa_a (.clk(clk), .rst_n(rst_n), .sig(PA_EN_n_a),     .err_cnt(a8_pa_a));
    chk_xprop #(.W(1), .NAME("led_heartbeat")) u_a8_hb   (.clk(clk), .rst_n(rst_n), .sig(hb_a),          .err_cnt(a8_hb));
    chk_xprop #(.W(1), .NAME("PA_EN_n(延时)")) u_a8_pa_b (.clk(clk), .rst_n(rst_n), .sig(PA_EN_n_b),     .err_cnt(a8_pa_b));

    // ── 度量 ───────────────────────────────────────────────────────
    integer errors = 0;

    integer t_win;                       // 复位释放后的 clk 计数（时间基准）
    integer last_bck, gap_bck_min, gap_bck_max, n_bck_edge;
    integer last_ws,  ws_period_min, ws_period_max, n_ws_edge;
    reg     bck_d, ws_d;

    integer pa_a_low, pa_a_trans, pa_a_rst_bad, rst_clk_cnt;
    reg     pa_a_d;

    integer pa_b_trans, pa_b_release_at, pa_b_high_after;
    reg     pa_b_d;

    integer din_nonzero;
    integer hb_a_trans, last_hb_a, hb_a_gap_min, hb_a_gap_max;
    reg     hb_a_d;

    integer fd_pa;

    initial begin
        $dumpfile("build/sim/tb_top_m0/tb_top_m0.vcd");
        $dumpvars(0, tb_top_m0);

        t_win = 0; last_bck = -1; gap_bck_min = 1 << 30; gap_bck_max = 0; n_bck_edge = 0;
        last_ws = -1; ws_period_min = 1 << 30; ws_period_max = 0; n_ws_edge = 0;
        bck_d = 1'b0; ws_d = 1'b0;

        pa_a_low = 0; pa_a_trans = 0; pa_a_rst_bad = 0; rst_clk_cnt = 0; pa_a_d = 1'b1;
        pa_b_trans = 0; pa_b_release_at = -1; pa_b_high_after = 0; pa_b_d = 1'b1;
        din_nonzero = 0;
        hb_a_trans = 0; last_hb_a = -1; hb_a_gap_min = 1 << 30; hb_a_gap_max = 0; hb_a_d = 1'b0;

        // ⭐ 证据：PA_EN_n 的**翻转轨迹**（安全态下应为空文件，只有表头 ⇒ "一次都没动过"）
        fd_pa = $fopen("sim/evidence/top_m0_pa_trace.csv", "w");
        $fdisplay(fd_pa, "# PA_EN_n 翻转轨迹（clk_sys=50MHz）；安全态 A 期望 0 行 = 无翻转 = 无窄脉冲");
        $fdisplay(fd_pa, "# 实例,时刻ns,新值");

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (CLK_PER_SAMPLE * N_FRAMES) @(posedge clk);
        #1;

        $fclose(fd_pa);

        $display("");
        $display("==================== top / M0 顶层验收 ====================");
        $display("  A 时基    : HP_BCK 周期 min=%0d max=%0d clk（期望 %0d）· 上升沿 %0d 个",
                 gap_bck_min, gap_bck_max, BCLK_DIV, n_bck_edge);
        $display("              HP_WS  周期 min=%0d max=%0d clk（期望 %0d）· 上升沿 %0d 个",
                 ws_period_min, ws_period_max, CLK_PER_SAMPLE, n_ws_edge);
        $display("  B 安全态  : PA_EN_n 为低 %0d 拍 · 翻转 %0d 次 · 复位期间非 1 的拍数 %0d",
                 pa_a_low, pa_a_trans, pa_a_rst_bad);
        $display("  C 延时开  : 复位释放后第 %0d 拍拉低（期望 %0d）· 总翻转 %0d 次 · 拉低后又变高 %0d 拍",
                 pa_b_release_at, PA_DELAY_TB, pa_b_trans, pa_b_high_after);
        $display("  D 心跳    : 翻转 %0d 次 · 间隔 min=%0d max=%0d clk（期望 %0d）",
                 hb_a_trans, hb_a_gap_min, hb_a_gap_max, HB_DIV);
        $display("  E 静音    : HP_DIN 为 1 的拍数 %0d（期望 0）", din_nonzero);
        $display("  F A8      : bck=%0d ws=%0d din=%0d pa=%0d hb=%0d pa(延时)=%0d",
                 a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b);
        $display("  证据      : sim/evidence/top_m0_pa_trace.csv（应只有表头）+ 波形 build/sim/tb_top_m0/");
        $display("==========================================================");

        if (gap_bck_min == BCLK_DIV && gap_bck_max == BCLK_DIV && n_bck_edge > 100)
            $display("  ok : A · HP_BCK 周期恰好 %0d clk（3.125 MHz）", BCLK_DIV);
        else begin
            $display("FAIL: A · HP_BCK 周期不是恰好 %0d（min=%0d max=%0d）", BCLK_DIV, gap_bck_min, gap_bck_max);
            errors = errors + 1;
        end

        if (ws_period_min == CLK_PER_SAMPLE && ws_period_max == CLK_PER_SAMPLE && n_ws_edge >= N_FRAMES)
            $display("  ok : A · HP_WS 周期恰好 %0d clk（48.828125 kHz）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: A · HP_WS 周期不是恰好 %0d（min=%0d max=%0d）", CLK_PER_SAMPLE, ws_period_min, ws_period_max);
            errors = errors + 1;
        end

        if (pa_a_low == 0 && pa_a_trans == 0 && pa_a_rst_bad == 0)
            $display("  ok : B ⭐ 安全态 —— PA_EN_n 全程为 1、0 次翻转、复位期间就已为 1");
        else begin
            $display("FAIL: B ⭐ 安全态被破坏（低 %0d 拍 / 翻转 %0d 次 / 复位期间非 1 %0d 拍）",
                     pa_a_low, pa_a_trans, pa_a_rst_bad);
            errors = errors + 1;
        end

        // ⭐ 恰好 PA_DELAY_TB + 2 拍：+1 是"计数器到输出寄存器"那一级，+1 是 tb 在时钟沿采到的是
        //    **本拍更新前**的值（寄存输出晚一拍可见）。⛔ 不是"大概" —— 这两个延迟是确定的。
        if (pa_b_release_at == PA_DELAY_TB + 2 && pa_b_trans == 1 && pa_b_high_after == 0)
            $display("  ok : C · 延时开功放：第 %0d 拍拉低（= %0d + 2）且**只翻转 1 次**（无毛刺）",
                     pa_b_release_at, PA_DELAY_TB);
        else begin
            $display("FAIL: C · 延时开功放不对（第 %0d 拍拉低，期望恰好 %0d；总翻转 %0d 次，期望 1；回高 %0d 拍）",
                     pa_b_release_at, PA_DELAY_TB + 2, pa_b_trans, pa_b_high_after);
            errors = errors + 1;
        end

        if (hb_a_trans >= 8 && hb_a_gap_min == HB_DIV && hb_a_gap_max == HB_DIV)
            $display("  ok : D · 心跳 LED 活着且半周期恰好 %0d clk（%0d 次翻转）", HB_DIV, hb_a_trans);
        else begin
            $display("FAIL: D · 心跳不对（翻转 %0d 次 · 间隔 %0d~%0d，期望恰好 %0d）",
                     hb_a_trans, hb_a_gap_min, hb_a_gap_max, HB_DIV);
            errors = errors + 1;
        end

        if (din_nonzero == 0)
            $display("  ok : E · 静音是真静音 —— HP_DIN 全程为 0");
        else begin
            $display("FAIL: E · 静音期 HP_DIN 出现 %0d 拍非 0（接了音源之前不该有数据）", din_nonzero);
            errors = errors + 1;
        end

        if (a8_bck == 0 && a8_ws == 0 && a8_din == 0 && a8_pa_a == 0 && a8_hb == 0 && a8_pa_b == 0)
            $display("  ok : F · A8 无 X/Z 传播（5 个顶层输出 + 延时实例）");
        else begin
            $display("FAIL: F · A8 检测到 X/Z（bck=%0d ws=%0d din=%0d pa=%0d hb=%0d pa_b=%0d）",
                     a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: M0 顶层验收通过（时基正确 + 安全态无窄脉冲 + 静音无噪声 + 心跳活着 + 无 X）");
        else             $fatal(1, "FAIL: M0 顶层有 %0d 项不符合预期", errors);

        #100;
        $finish;
    end

    // ── 采样（全在 clk 域，避免竞争）────────────────────────────────
    always @(posedge clk) begin
        // 复位期间：从第 2 个时钟沿起 PA_EN_n 就必须已经是 1（同步复位已生效）
        if (rst_n === 1'b0) begin
            rst_clk_cnt = rst_clk_cnt + 1;
            if (rst_clk_cnt >= 2 && PA_EN_n_a !== 1'b1) pa_a_rst_bad = pa_a_rst_bad + 1;
        end else begin
            t_win = t_win + 1;

            // A · HP_BCK 上升沿间隔
            if (HP_BCK_a === 1'b1 && bck_d === 1'b0) begin
                n_bck_edge = n_bck_edge + 1;
                if (last_bck >= 0) begin
                    if (t_win - last_bck < gap_bck_min) gap_bck_min = t_win - last_bck;
                    if (t_win - last_bck > gap_bck_max) gap_bck_max = t_win - last_bck;
                end
                last_bck = t_win;
            end
            bck_d = HP_BCK_a;

            // A · HP_WS 上升沿间隔
            if (HP_WS_a === 1'b1 && ws_d === 1'b0) begin
                n_ws_edge = n_ws_edge + 1;
                if (last_ws >= 0) begin
                    if (t_win - last_ws < ws_period_min) ws_period_min = t_win - last_ws;
                    if (t_win - last_ws > ws_period_max) ws_period_max = t_win - last_ws;
                end
                last_ws = t_win;
            end
            ws_d = HP_WS_a;

            // B · 安全态：全程为 1 且一次都不翻转
            if (PA_EN_n_a !== 1'b1) pa_a_low = pa_a_low + 1;
            if (PA_EN_n_a !== pa_a_d) begin
                pa_a_trans = pa_a_trans + 1;
                $fdisplay(fd_pa, "A,%0t,%b", $time, PA_EN_n_a);
            end
            pa_a_d = PA_EN_n_a;

            // C · 延时开功放：记录首次拉低的拍数 + 总翻转次数 + 拉低后是否又变高
            if (PA_EN_n_b !== pa_b_d) begin
                pa_b_trans = pa_b_trans + 1;
                $fdisplay(fd_pa, "B,%0t,%b", $time, PA_EN_n_b);
                if (PA_EN_n_b === 1'b0 && pa_b_release_at < 0) pa_b_release_at = t_win;
            end
            if (pa_b_release_at >= 0 && PA_EN_n_b === 1'b1) pa_b_high_after = pa_b_high_after + 1;
            pa_b_d = PA_EN_n_b;

            // D · 心跳
            if (hb_a !== hb_a_d) begin
                hb_a_trans = hb_a_trans + 1;
                if (last_hb_a >= 0) begin
                    if (t_win - last_hb_a < hb_a_gap_min) hb_a_gap_min = t_win - last_hb_a;
                    if (t_win - last_hb_a > hb_a_gap_max) hb_a_gap_max = t_win - last_hb_a;
                end
                last_hb_a = t_win;
            end
            hb_a_d = hb_a;

            // E · 静音
            if (HP_DIN_a === 1'b1) din_nonzero = din_nonzero + 1;
        end
    end

endmodule
