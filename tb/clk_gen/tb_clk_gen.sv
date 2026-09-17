`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_clk_gen · M0 时基证据（`files/00-总览/第一周/README.md` §四 第 2 条）
//
// 判据（全部要**实测数字**，不接受"看着对"）：
//   1. `tick_audio` 间隔 **恰好 1024** 个 clk（⇒ fs = 50 MHz ÷ 1024 = 48.828125 kHz）
//   2. `bclk_en`   间隔 **恰好 16**   个 clk（⇒ BCLK = 3.125 MHz = 64 × fs）
//   3. `mclk_en`   间隔 **恰好 4**    个 clk（⇒ MCLK = 12.5 MHz = 256 × fs）
//   4. 每个音频帧内 **恰好 64 个 BCLK**、**恰好 256 个 MCLK** 使能
//   5. `lrclk` 低/高各占半帧（低 = 左声道），且**帧起点处为低**
//   6. ⭐ **间隔的 min == max**（极差为 0）—— 这就是"确定性、无抖动"的证据
//   7. A8：全程无 X/Z（挂 `tb/checkers/chk_xprop.sv`）
//
// ⚠️ 本 tb 只证明**时基**。M0 的另一半（`PA_EN_n=1`、`OE_n=1` 安全态无窄脉冲）要等 `top.v` 出来。
//
// ⚠️ Icarus 相关注意（都踩过）：任务名不能叫 `expect`；任务端口用非 ANSI 风格；
//    ⛔ 不要用任务端口传字符串（打印会乱码）；被连信号必须声明在例化之前。
// ─────────────────────────────────────────────────────────────────────────────
module tb_clk_gen;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer MCLK_DIV       = 4;
    localparam integer T              = 20;    // 50 MHz → 20 ns
    localparam integer MEASURE_FRAMES = 8;     // 测 8 帧 = 8192 clk

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    wire tick_audio, mclk_en, bclk_en, lrclk, frame_start;

    // ── A8 监视（必须声明在被连信号之后、例化之前）────────────────────
    wire [31:0] a8_lrclk, a8_bclk, a8_tick;
    chk_xprop #(.W(1), .NAME("lrclk"))    u_a8_lrclk (.clk(clk), .rst_n(rst_n), .sig(lrclk),      .err_cnt(a8_lrclk));
    chk_xprop #(.W(1), .NAME("bclk_en"))  u_a8_bclk  (.clk(clk), .rst_n(rst_n), .sig(bclk_en),    .err_cnt(a8_bclk));
    chk_xprop #(.W(1), .NAME("tick_audio")) u_a8_tick (.clk(clk), .rst_n(rst_n), .sig(tick_audio), .err_cnt(a8_tick));

    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .tick_audio  (tick_audio),
        .mclk_en     (mclk_en),
        .bclk_en     (bclk_en),
        .lrclk       (lrclk),
        .frame_start (frame_start)
    );

    integer errors = 0;

    // ── 测量状态 ────────────────────────────────────────────────────
    integer t_win;                       // 窗口内已过的 clk 数
    integer n_tick, n_bclk, n_mclk;
    integer n_lrclk_low, n_lrclk_high;
    integer last_tick, last_bclk, last_mclk;
    integer gap_tick_min, gap_tick_max;
    integer gap_bclk_min, gap_bclk_max;
    integer gap_mclk_min, gap_mclk_max;
    integer lrclk_low_at_tick;           // 帧起点处 lrclk 为低的次数
    integer n_tick_checked;

    initial begin
        $dumpfile("build/sim/tb_clk_gen/tb_clk_gen.vcd");
        $dumpvars(0, tb_clk_gen);

        t_win = 0; n_tick = 0; n_bclk = 0; n_mclk = 0;
        n_lrclk_low = 0; n_lrclk_high = 0;
        last_tick = -1; last_bclk = -1; last_mclk = -1;
        gap_tick_min = 1 << 30; gap_tick_max = 0;
        gap_bclk_min = 1 << 30; gap_bclk_max = 0;
        gap_mclk_min = 1 << 30; gap_mclk_max = 0;
        lrclk_low_at_tick = 0; n_tick_checked = 0;

        // 复位
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // 测 MEASURE_FRAMES 帧
        repeat (CLK_PER_SAMPLE * MEASURE_FRAMES) @(posedge clk);
        #1;

        $display("");
        $display("================ clk_gen 时基实测 ================");
        $display("  窗口        : %0d 个 clk（%0d ns，期望 %0d 帧）", t_win, t_win * T, MEASURE_FRAMES);
        $display("  tick_audio  : %0d 次 · 间隔 min=%0d max=%0d clk", n_tick, gap_tick_min, gap_tick_max);
        $display("  bclk_en     : %0d 次 · 间隔 min=%0d max=%0d clk", n_bclk, gap_bclk_min, gap_bclk_max);
        $display("  mclk_en     : %0d 次 · 间隔 min=%0d max=%0d clk", n_mclk, gap_mclk_min, gap_mclk_max);
        $display("  lrclk       : 低 %0d / 高 %0d 个 clk", n_lrclk_low, n_lrclk_high);
        $display("--------------------------------------------------");
        $display("  ⇒ fs   = 50 MHz / %0d = %.6f kHz", CLK_PER_SAMPLE, 50000.0 / CLK_PER_SAMPLE);
        $display("  ⇒ BCLK = 50 MHz / %0d = %.6f MHz（= %.1f × fs）",
                 BCLK_DIV, 50.0 / BCLK_DIV, real'(CLK_PER_SAMPLE) / real'(BCLK_DIV));
        $display("  ⇒ MCLK = 50 MHz / %0d = %.3f MHz（= %0d × fs）",
                 MCLK_DIV, 50.0 / MCLK_DIV, CLK_PER_SAMPLE / MCLK_DIV);
        $display("==================================================");

        // ── 判据 ────────────────────────────────────────────────────
        if (gap_tick_min == CLK_PER_SAMPLE && gap_tick_max == CLK_PER_SAMPLE)
            $display("  ok : tick_audio 间隔恰好 %0d clk（fs 精确）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: tick_audio 间隔不是恰好 %0d（min=%0d max=%0d）",
                     CLK_PER_SAMPLE, gap_tick_min, gap_tick_max);
            errors = errors + 1;
        end

        if (gap_bclk_min == BCLK_DIV && gap_bclk_max == BCLK_DIV)
            $display("  ok : bclk_en 间隔恰好 %0d clk（BCLK 精确）", BCLK_DIV);
        else begin
            $display("FAIL: bclk_en 间隔不是恰好 %0d（min=%0d max=%0d）",
                     BCLK_DIV, gap_bclk_min, gap_bclk_max);
            errors = errors + 1;
        end

        if (gap_mclk_min == MCLK_DIV && gap_mclk_max == MCLK_DIV)
            $display("  ok : mclk_en 间隔恰好 %0d clk（MCLK 精确）", MCLK_DIV);
        else begin
            $display("FAIL: mclk_en 间隔不是恰好 %0d（min=%0d max=%0d）",
                     MCLK_DIV, gap_mclk_min, gap_mclk_max);
            errors = errors + 1;
        end

        // 每帧 64 个 BCLK、256 个 MCLK（允许窗口边界 ±1）
        if (n_bclk >= n_tick * (CLK_PER_SAMPLE / BCLK_DIV) - 1 &&
            n_bclk <= n_tick * (CLK_PER_SAMPLE / BCLK_DIV) + 1)
            $display("  ok : 每帧 %0d 个 BCLK 使能（%0d 帧 → %0d 次）",
                     CLK_PER_SAMPLE / BCLK_DIV, n_tick, n_bclk);
        else begin
            $display("FAIL: BCLK 数量不对（%0d 帧 → %0d 次，期望 ≈ %0d）",
                     n_tick, n_bclk, n_tick * (CLK_PER_SAMPLE / BCLK_DIV));
            errors = errors + 1;
        end

        if (n_mclk >= n_tick * (CLK_PER_SAMPLE / MCLK_DIV) - 1 &&
            n_mclk <= n_tick * (CLK_PER_SAMPLE / MCLK_DIV) + 1)
            $display("  ok : 每帧 %0d 个 MCLK 使能", CLK_PER_SAMPLE / MCLK_DIV);
        else begin
            $display("FAIL: MCLK 数量不对（%0d 帧 → %0d 次，期望 ≈ %0d）",
                     n_tick, n_mclk, n_tick * (CLK_PER_SAMPLE / MCLK_DIV));
            errors = errors + 1;
        end

        // lrclk 占空比 50%（低 = 左声道）
        if (n_lrclk_low > 0 && n_lrclk_high > 0 &&
            (n_lrclk_low > n_lrclk_high ? n_lrclk_low - n_lrclk_high : n_lrclk_high - n_lrclk_low) <= 2)
            $display("  ok : lrclk 低/高各占半帧（低 %0d / 高 %0d）", n_lrclk_low, n_lrclk_high);
        else begin
            $display("FAIL: lrclk 占空比不是 50%%（低 %0d / 高 %0d）", n_lrclk_low, n_lrclk_high);
            errors = errors + 1;
        end

        // 帧起点处 lrclk 必须是低（= 左声道先发）
        if (n_tick_checked > 0 && lrclk_low_at_tick == n_tick_checked)
            $display("  ok : 帧起点处 lrclk = 低（左声道先发，标准 I2S）");
        else begin
            $display("FAIL: 帧起点处 lrclk 不是低（%0d/%0d 次）",
                     lrclk_low_at_tick, n_tick_checked);
            errors = errors + 1;
        end

        // A8：无 X/Z
        if (a8_lrclk == 0 && a8_bclk == 0 && a8_tick == 0)
            $display("  ok : A8 无 X/Z 传播");
        else begin
            $display("FAIL: A8 检测到 X/Z（lrclk=%0d bclk=%0d tick=%0d）",
                     a8_lrclk, a8_bclk, a8_tick);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: clk_gen 时基全部符合（分频链精确 + 极差为 0 + 无 X）");
        else             $fatal(1, "FAIL: clk_gen 时基有 %0d 项不符合预期", errors);

        #100;
        $finish;
    end

    // ── 测量逻辑（单时钟域，纯计数）─────────────────────────────────
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            t_win = t_win + 1;

            if (tick_audio === 1'b1) begin
                n_tick = n_tick + 1;
                if (last_tick >= 0) begin
                    if (t_win - last_tick < gap_tick_min) gap_tick_min = t_win - last_tick;
                    if (t_win - last_tick > gap_tick_max) gap_tick_max = t_win - last_tick;
                end
                last_tick = t_win;
                // 帧起点处 lrclk 应为低
                n_tick_checked = n_tick_checked + 1;
                if (lrclk === 1'b0) lrclk_low_at_tick = lrclk_low_at_tick + 1;
            end

            if (bclk_en === 1'b1) begin
                n_bclk = n_bclk + 1;
                if (last_bclk >= 0) begin
                    if (t_win - last_bclk < gap_bclk_min) gap_bclk_min = t_win - last_bclk;
                    if (t_win - last_bclk > gap_bclk_max) gap_bclk_max = t_win - last_bclk;
                end
                last_bclk = t_win;
            end

            if (mclk_en === 1'b1) begin
                n_mclk = n_mclk + 1;
                if (last_mclk >= 0) begin
                    if (t_win - last_mclk < gap_mclk_min) gap_mclk_min = t_win - last_mclk;
                    if (t_win - last_mclk > gap_mclk_max) gap_mclk_max = t_win - last_mclk;
                end
                last_mclk = t_win;
            end

            if (lrclk === 1'b1) n_lrclk_high = n_lrclk_high + 1;
            else                n_lrclk_low  = n_lrclk_low  + 1;
        end
    end

endmodule
