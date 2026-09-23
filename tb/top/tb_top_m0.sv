`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_top_m0 · **M0 顶层验收**（`files/20-代码/仿真与验证方案.md` §三 M0）
//
// M0 是"地基里最后一块"：**上板之前，顶层本身必须是安全的**。
// 判据（本 tb 逐条给结论）：
//   A · 时基在**顶层端口**上正确：`HP_BCK` 周期 = 16 clk（3.125 MHz）、
//       `HP_WS` 周期 = 1024 clk（48.828125 kHz）
//   B * **NEO-Dock fallback档**（`PA_ON_AFTER_RESET=0`）：`PA_EN_n` **恒低**、0 次翻转
//       （⚠️ 旧板上低 = `NS4263` 的 AB 类桥式 = "出声"那一侧）
//   C * ⭐⭐ **Console 交付档**（`PA_ON_AFTER_RESET=1`）：`PA_EN_n` **恒高、全程 0 个边沿**
//       （🔴 `U-25b`：它接 `MAX98357A` 的 `SD_MODE`，⭐ **`< 0.16 V` = `Shutdown` = 没声音** ⇒
//        ⭐ **驱动高才出声**；⚠️ 任何**下降沿**都会把它打进 `Shutdown` ⇒ 判据要求 0 个下降沿）
//   D · 心跳 LED 活着且周期精确（板级"活体见证"；系统时钟留在板载域 ⇒ 故障可观测）
//   E · ⭐ 静音就是**真的静音**：`HP_DIN` 全程为 0（T20 测试音源接进来之前，⛔ 不该有噪声）
//   F · A8：`HP_BCK/HP_WS/HP_DIN/PA_EN_n/led_heartbeat` 复位释放后无 X/Z
//
// ⚠️ 为什么专门测 `PA_EN_n`：⭐ **它在两块板上语义【相反】** ——
//    `NEO Dock` 上是**低有效**功放使能（低 = 出声）；⭐ `Console` 上是 **`SD_MODE` 多电平选择**
//    （🔴 低 = `Shutdown` = 没声音，⭐ **高才出声**）。⚠️ 这正是"换板后板子没声音"的根因（`U-25b`）。
//    同步复位意味着"上电到第一个时钟沿之间寄存器是未定义的"，所以**引脚上拉**
//    （`constr/top.cst` 里 `PULL_MODE=UP`）才是配置期间的保证 —— ⭐ 而**高在 Console 上恰好是"出声"**侧
//    ⇒ ⭐ **上拉档依然安全**。本 tb 验证的是"**从第一个时钟沿起**电平就已经正确"，上拉那半由 `.cst` 负责。
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
        // ⭐⭐ T57（2026-09-21）：本实例验的是 **M0 安全态 + 真静音**
        //   ⇒ ⛔ **必须显式关掉开机自检音**（默认值是 1 = 出声）。
        //   ⚠️ 不传这个参数的话，`top` 会自动起 A4+C#5+E5 和弦 ⇒
        //      ⭐ E 判据（`HP_DIN` 全程为 0）必然失败。
        .DEMO_CHORD_ON     (0),
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_safe (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK_a), .HP_WS (HP_WS_a), .HP_DIN (HP_DIN_a),
        .PA_EN_n (PA_EN_n_a), .led_heartbeat (hb_a),
        // ⭐ 2026-09-23：W3a 采集链新增的输入（⭐ 本 tb 不测采集 ⇒ 常量高 = 串口空闲/无 MISO 驱动）
        //   ⚠️ 2026-09-23 晚：端口已改成【预留 6 片】的向量 ⇒ ⭐ 给 6 位常量高
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n ()
    );

    // ═══════════════════════════════════════════════════════════════
    // ⭐⭐ I · **交付默认值守卫**（`R-16`，2026-09-17 加）
    //    ⚠️ 为什么需要：`top.v` 的 `PA_ON_AFTER_RESET` 默认值决定"**上板默认有没有声音**"。
    //      若默认是 0 ⇒ 板载 `NS4263` 永远关断 ⇒ **喇叭/耳机都没声音**，
    //      而 I2S 波形、DAC 输入、所有仿真结论**全都是对的** ⇒ 这种"没声音"极难定位。
    //    ⇒ 本条断言：**裸例化（不传参）时，默认值必须是"能出声"的那一档**。
    //      ⛔ 如果将来有人把默认值改回 0，这条会立刻 FAIL。
    //    ⭐ 注意区分：实例 A **显式传 0** 是有意的（验安全态），
    //      本条查的是"**不传参时**会怎样"。
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_d, HP_WS_d, HP_DIN_d, PA_EN_n_d, hb_d;
    top #(
        .HEARTBEAT_DIV (HB_DIV),         // ⚠️ 只覆盖心跳周期；`PA_ON_AFTER_RESET` **故意不传**
        // ⚠️ T57：本实例只查 `PA_ON_AFTER_RESET` 的默认值，⛔ 不查音频
        //    ⇒ 关掉自检音既省仿真时间、也避免 3 份合成链同时跑
        .DEMO_CHORD_ON (0)
    ) u_top_default (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK_d), .HP_WS (HP_WS_d), .HP_DIN (HP_DIN_d),
        .PA_EN_n (PA_EN_n_d), .led_heartbeat (hb_d),
        //   ⚠️ 2026-09-23 晚：端口改成【预留 6 片】的向量 ⇒ 给 6 位常量
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n ()
    );

    // ═══════════════════════════════════════════════════════════════
    // C · 反向检：PA_ON_AFTER_RESET = 1（延时开功放）
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_b, HP_WS_b, HP_DIN_b, PA_EN_n_b, hb_b;
    top #(
        .PA_ON_AFTER_RESET (1),
        .PA_ON_DELAY       (PA_DELAY_TB),
        .DEMO_CHORD_ON     (0),          // ⚠️ T57：本实例只查功放时序
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_on (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK_b), .HP_WS (HP_WS_b), .HP_DIN (HP_DIN_b),
        .PA_EN_n (PA_EN_n_b), .led_heartbeat (hb_b),
        //   ⚠️ 2026-09-23 晚：端口改成【预留 6 片】的向量 ⇒ 给 6 位常量
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n ()
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

    integer pa_b_trans, pa_b_release_at, pa_b_high_after, pa_b_rst_bad;
    integer pa_b_high_cyc;      // cycles PA_EN_n_b was high (Console delivery must be all-high)
    reg     pa_b_d;

    // ⭐ K-61：`NS4263` 的 `SD`（`PA_EN_n`）靠**下降沿个数**选模式
    //    （1 个 = AB 类桥式；连续 2 个 = D 类）⇒ 单独统计**下降沿**个数。
    integer pa_a_fall, pa_b_fall;
    reg     pa_a_prev, pa_b_prev;

    // ⭐ I · 交付默认值守卫用的量（裸例化实例）
    integer pa_d_fall, pa_d_release_at;
    reg     pa_d_prev;
    integer t_win_d;

    integer din_nonzero;
    integer hb_a_trans, last_hb_a, hb_a_gap_min, hb_a_gap_max;
    reg     hb_a_d;

    integer fd_pa;

    // ── ⭐ R-08：`rst_sync` 的两级同步延迟（声明必须在 always/initial 使用之前，
    //    否则 Icarus 报 "Unable to bind wire/reg/memory ... Check for declaration after use"，
    //    见经验库 `U47`）────────────────────────────────────────────────
    integer in_rise_cyc, out_rise_cyc;
    integer rst_cyc;
    reg     in_hi_d, out_hi_d;

    initial begin
        $dumpfile("build/sim/tb_top_m0/tb_top_m0.vcd");
        $dumpvars(0, tb_top_m0);

        t_win = 0; last_bck = -1; gap_bck_min = 1 << 30; gap_bck_max = 0; n_bck_edge = 0;
        last_ws = -1; ws_period_min = 1 << 30; ws_period_max = 0; n_ws_edge = 0;
        bck_d = 1'b0; ws_d = 1'b0;

        // * seed the previous-value registers to each instance's EXPECTED resting level,
        //   so the first sampled cycle is not miscounted as an edge.
        //   A = NEO-Dock fallback => rests low;  B = Console delivery => rests high.
        pa_a_low = 0; pa_a_trans = 0; pa_a_rst_bad = 0; rst_clk_cnt = 0; pa_a_d = 1'b0;
        pa_a_fall = 0; pa_a_prev = 1'b0;
        pa_b_trans = 0; pa_b_release_at = -1; pa_b_high_after = 0; pa_b_d = 1'b1;
        pa_b_rst_bad = 0; pa_b_high_cyc = 0;
        pa_b_fall = 0; pa_b_prev = 1'b1;
        pa_d_fall = 0; pa_d_release_at = -1; pa_d_prev = 1'b1;
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
        $display("  B fallback: PA_EN_n NOT-low %0d cyc (expect 0) * trans %0d (expect 0) * rst-bad %0d",
                 pa_a_low, pa_a_trans, pa_a_rst_bad);
        $display("  C Console : PA_EN_n high %0d of %0d cyc (expect all) * trans %0d * falling %0d (both expect 0)",
                 pa_b_high_cyc, t_win, pa_b_trans, pa_b_fall);
        $display("  D 心跳    : 翻转 %0d 次 · 间隔 min=%0d max=%0d clk（期望 %0d）",
                 hb_a_trans, hb_a_gap_min, hb_a_gap_max, HB_DIV);
        $display("  G rst_sync: 输入释放拍 %0d · 同步输出释放拍 %0d · 延迟 %0d 拍（期望恰好 2）",
                 in_rise_cyc, out_rise_cyc, out_rise_cyc - in_rise_cyc);
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
            $display("  ok : B * NEO-Dock fallback (PA_ON_AFTER_RESET=0) -- PA_EN_n low throughout, 0 transitions");
        else begin
            $display("FAIL: B * NEO-Dock fallback broken (not-low %0d cyc / trans %0d / rst-issue %0d)",
                     pa_a_low, pa_a_trans, pa_a_rst_bad);
            errors = errors + 1;
        end

        // * Console delivery档 (PA_ON_AFTER_RESET=1): PA_EN_n must be HIGH forever.
        //   Why: on Console this net drives MAX98357A SD_MODE, and <0.16V = Shutdown
        //   (U-25b).  So the ONLY correct delivery value is high, with ZERO falling
        //   edges -- a falling edge here would silently mute the board.
        if (pa_b_high_cyc == t_win && pa_b_trans == 0 && pa_b_fall == 0 && pa_b_rst_bad == 0)
            $display("  ok : C * Console delivery -- PA_EN_n high for all %0d cycles, 0 edges (SD_MODE=Left => SOUNDS)", t_win);
        else begin
            $display("FAIL: C * Console delivery broken (high %0d of %0d cyc, trans %0d, falling %0d, rst-bad %0d) -- SD_MODE would leave Left => NO SOUND",
                     pa_b_high_cyc, t_win, pa_b_trans, pa_b_fall, pa_b_rst_bad);
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

        // ⭐ R-08：复位同步器延迟必须恰好 2 拍（证明"释放沿对齐"这件事真的做了）
        if (in_rise_cyc > 0 && out_rise_cyc > 0 && (out_rise_cyc - in_rise_cyc) == 2)
            $display("  ok : G · rst_sync 把复位释放延后**恰好 2 拍**（异步输入 → 同步释放）");
        else begin
            $display("FAIL: G · rst_sync 延迟不是 2 拍（in=%0d out=%0d 差=%0d）",
                     in_rise_cyc, out_rise_cyc, out_rise_cyc - in_rise_cyc);
            errors = errors + 1;
        end

        // ** U-25b: PA_EN_n drives MAX98357A SD_MODE on Console, NOT an NS4263 SD pin.
        //    Datasheet: <0.16V = Shutdown (NO SOUND); >1.4V = Left (SOUNDS).
        //    => The delivery requirement INVERTED: the pin must be driven HIGH and must
        //       NEVER fall.  A falling edge now means SILENCE, not "AB-class".
        //    => Judgement: zero falling edges in BOTH instances.
        //       (Instance A is the NEO-Dock fallback, which is legitimately static-low.)
        $display("  H SD_MODE : PA_EN_n falling edges A=%0d (fallback, low) B=%0d (Console, high)",
                 pa_a_fall, pa_b_fall);
        if (pa_a_fall == 0 && pa_b_fall == 0)
            $display("  ok : H * zero falling edges -- Console SD_MODE never leaves Left (would be Shutdown)");
        else begin
            $display("FAIL: H * falling edges present (A=%0d B=%0d) -- on Console that means SD_MODE hits Shutdown = NO SOUND",
                     pa_a_fall, pa_b_fall);
            errors = errors + 1;
        end

        // ** I * delivery-default guard (R-16, semantics updated by U-25b):
        //    A bare instantiation must get PA_ON_AFTER_RESET=1, which on Console means
        //    "SD_MODE driven high => SOUNDS".  If someone flips the default back to 0,
        //    the board goes silent -- this assertion is what catches that.
        $display("  I default : bare instantiation PA_ON_AFTER_RESET = %0d (1 = Console sounds; 0 = Shutdown)",
                 u_top_default.PA_ON_AFTER_RESET);
        if (u_top_default.PA_ON_AFTER_RESET == 1)
            $display("  ok : I * delivery default correct -- bare instantiation drives SD_MODE high => board sounds");
        else begin
            $display("FAIL: I * delivery default would MUTE the board (PA_ON_AFTER_RESET=%0d) -- fix top.v default (R-16 / U-25b)",
                     u_top_default.PA_ON_AFTER_RESET);
            errors = errors + 1;
        end

        // ** and the fallback档 must really be static-low, with no transitions
        if (u_top_safe.PA_ON_AFTER_RESET == 0 && pa_a_fall == 0 && pa_a_trans == 0)
            $display("  ok : I * explicit PA_ON_AFTER_RESET=0 gives a static-low output (NEO-Dock fallback intact)");
        else begin
            $display("FAIL: I * explicit 0 did not stay static-low (param=%0d, falling=%0d, trans=%0d)",
                     u_top_safe.PA_ON_AFTER_RESET, pa_a_fall, pa_a_trans);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: M0 top-level acceptance (timebase + SD_MODE polarity + silence-clean + heartbeat + no X)");
        else             $fatal(1, "FAIL: M0 top-level has %0d unexpected item(s)", errors);

        #100;
        $finish;
    end

    // ── ⭐ R-08：`rst_sync` 的两级同步延迟必须**恰好 2 拍** ──────────────
    //    判据：复位释放后，`u_rst_sync` 的输出比输入晚 2 个 clk 变高。
    //    ⚠️ 这是"复位释放沿在全设计里严格对齐"的**代价与证据**：
    //       延迟是确定的 2 拍（40 ns），不是"随便几拍"。
    initial begin
        in_rise_cyc = -1; out_rise_cyc = -1; rst_cyc = 0;
        in_hi_d = 1'b0; out_hi_d = 1'b0;
    end

    always @(posedge clk) begin
        rst_cyc = rst_cyc + 1;
        if (rst_n === 1'b1 && in_hi_d === 1'b0) begin
            in_hi_d = 1'b1;
            in_rise_cyc = rst_cyc;
        end
        if (u_top_on.rst_n_sync === 1'b1 && out_hi_d === 1'b0) begin
            out_hi_d = 1'b1;
            out_rise_cyc = rst_cyc;
        end
    end

    // ── 采样（全在 clk 域，避免竞争）────────────────────────────────
    always @(posedge clk) begin
        // During reset: from the 2nd clock edge onward the output must already hold its
        // final level (synchronous reset has taken effect).
        //   Instance A = NEO-Dock fallback => expects LOW.
        //   Instance B = Console delivery  => expects HIGH (checked separately below).
        if (rst_n === 1'b0) begin
            rst_clk_cnt = rst_clk_cnt + 1;
            if (rst_clk_cnt >= 2 && PA_EN_n_a !== 1'b0) pa_a_rst_bad = pa_a_rst_bad + 1;
            if (rst_clk_cnt >= 2 && PA_EN_n_b !== 1'b1) pa_b_rst_bad = pa_b_rst_bad + 1;
        end else begin
            t_win = t_win + 1;

            // A · HP_BCK 上升沿间隔
            // ⚠️ **跳过复位后前两个上升沿**：`HP_BCK` 的复位值是 1（R-03 修法：数据改在
            //    BCK 下降沿变化，使 DAC 的上升沿采样有半周期余量）⇒ 复位释放后**第一个**
            //    "上升沿"距复位时刻不足一个完整周期（实测 min=10 而非 16）——
            //    那是 warm-up 伪值，⛔ 不是 RTL 错。稳态周期仍是恰好 16 clk。
            if (HP_BCK_a === 1'b1 && bck_d === 1'b0) begin
                n_bck_edge = n_bck_edge + 1;
                if (n_bck_edge > 2 && last_bck >= 0) begin
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

            // B * NEO-Dock fallback (PA_ON_AFTER_RESET=0): output must be statically LOW.
            //   On the old NS4263 board, LOW = AB-class bridged output (the "sounds" side).
            //   On Console this档 would be WRONG (low = SD_MODE Shutdown), which is exactly
            //   why the delivery default is 1 -- see U-25b.
            if (PA_EN_n_a !== 1'b0) pa_a_low = pa_a_low + 1;   // counts cycles NOT low (should be 0)
            if (PA_EN_n_a !== pa_a_d) begin
                pa_a_trans = pa_a_trans + 1;
                $fdisplay(fd_pa, "A,%0t,%b", $time, PA_EN_n_a);
            end
            // * count falling edges (1->0).  On Console ANY falling edge would drive
            //   SD_MODE into Shutdown, so the delivery instance must show zero.
            if (PA_EN_n_a === 1'b0 && pa_a_prev === 1'b1) pa_a_fall = pa_a_fall + 1;
            pa_a_prev = PA_EN_n_a;
            pa_a_d = PA_EN_n_a;

            // C * Console delivery (PA_ON_AFTER_RESET=1): output must be statically HIGH.
            if (PA_EN_n_b !== pa_b_d) begin
                pa_b_trans = pa_b_trans + 1;
                $fdisplay(fd_pa, "B,%0t,%b", $time, PA_EN_n_b);
                if (PA_EN_n_b === 1'b0 && pa_b_release_at < 0) pa_b_release_at = t_win;
            end
            if (PA_EN_n_b === 1'b1) pa_b_high_cyc = pa_b_high_cyc + 1;   // counts HIGH cycles
            if (PA_EN_n_b === 1'b0 && pa_b_prev === 1'b1) pa_b_fall = pa_b_fall + 1;
            pa_b_prev = PA_EN_n_b;
            pa_b_d = PA_EN_n_b;

            // ⭐ I · 裸例化实例（默认值）：只统计"下降沿个数"与"首次拉低的拍数"
            if (PA_EN_n_d === 1'b0 && pa_d_prev === 1'b1) begin
                pa_d_fall = pa_d_fall + 1;
                if (pa_d_release_at < 0) pa_d_release_at = t_win;
            end
            pa_d_prev = PA_EN_n_d;

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
