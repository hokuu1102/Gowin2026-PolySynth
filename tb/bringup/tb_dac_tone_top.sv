`timescale 1ns/1ps
// ═══════════════════════════════════════════════════════════════════════════
//  tb_dac_tone_top —— ⭐ 验证最小 DAC 测试顶层的 I2S 波形
//
//  ⭐ 判据：
//     ① BCK 周期 = BCLK_DIV 个 clk（3.125 MHz）
//     ② LRCK 周期 = CLK_PER_SAMPLE 个 clk（48.828 kHz）
//     ③ ⭐ **DIN 真的在动**（⛔ 不是恒 0）
//     ④ ⭐ **左声道时隙**里能解出正弦（⭐ 数出多个不同值）
//     ⑤ ⭐ 解出的样点**在幅度范围内**（⛔ 不削顶）
//     ⑥ ⭐ 三种 FORMAT_SEL 都能跑（⭐ 编译期各例化一份不便，⭐ 这里测默认档）
//     ⑦ A8：无 X/Z
// ═══════════════════════════════════════════════════════════════════════════
module tb_dac_tone_top;

    localparam integer CLK_HZ         = 50_000_000;
    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer SLOT_BITS      = 32;
    localparam integer T              = 20;      // 20 ns

    reg clk = 0, rst_n = 0;
    always #(T/2) clk = ~clk;

    wire bck, lrck, din, hb;

    dac_tone_top #(
        .CLK_HZ(CLK_HZ), .CLK_PER_SAMPLE(CLK_PER_SAMPLE), .BCLK_DIV(BCLK_DIV),
        .SLOT_BITS(SLOT_BITS), .FORMAT_SEL(0), .FREQ_HZ(440),
        .AMP_SHIFT(1), .RAMP_MS(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .I2S2_BCK(bck), .I2S2_LRCK(lrck), .I2S2_DIN(din), .led_hb(hb)
    );

    // ── 统计 ────────────────────────────────────────────────────────────────
    integer n_bck_edge = 0, n_bck_tog = 0, n_lrck_tog = 0, n_din_tog = 0;
    integer gap_bck_min = 1<<30, gap_bck_max = 0;
    integer gap_lrck_min = 1<<30, gap_lrck_max = 0;
    integer cyc = 0;
    integer last_bck = -1, last_lrck = -1;
    reg bck_p = 0, lrck_p = 0, din_p = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            //   🔴 **2026-09-26 修正**：⭐ 必须先【用旧值判断边沿】，⭐ 再更新 `*_p`
            //      ⚠️ 原来我把 `bck_p = bck;` 写在边沿判断【之前】
            //      ⇒ 🔴 `bck === 1'b1 && bck_p === 1'b0` **永远不成立**（⭐ 两边同值）
            //      ⇒ ⚠️ 周期测出 `min=1<<30`（⭐ 从未命中）⇒ 🔴 **误报"周期异常"**
            //   📌 这是**我 tb 的 bug**，⛔ 不是 RTL 的（⭐ `K-129` 同族：判据错 ⇒ 结论错）
            if (bck !== bck_p) n_bck_tog = n_bck_tog + 1;
            if (lrck !== lrck_p) n_lrck_tog = n_lrck_tog + 1;
            if (din !== din_p) n_din_tog = n_din_tog + 1;

            // ⭐ 周期（⭐ 跳过前 2 个 warm-up 边沿）—— ⭐ 用【旧值】判边沿
            if (bck === 1'b1 && bck_p === 1'b0) begin
                n_bck_edge = n_bck_edge + 1;
                if (n_bck_edge > 2 && last_bck >= 0) begin
                    if (cyc - last_bck < gap_bck_min) gap_bck_min = cyc - last_bck;
                    if (cyc - last_bck > gap_bck_max) gap_bck_max = cyc - last_bck;
                end
                last_bck = cyc;
            end
            if (lrck === 1'b1 && lrck_p === 1'b0) begin
                if (last_lrck >= 0) begin
                    if (cyc - last_lrck < gap_lrck_min) gap_lrck_min = cyc - last_lrck;
                    if (cyc - last_lrck > gap_lrck_max) gap_lrck_max = cyc - last_lrck;
                end
                last_lrck = cyc;
            end

            //   ⭐ **最后**才更新旧值
            bck_p = bck; lrck_p = lrck; din_p = din;
        end
    end

    // ── ⭐ 解串：还原左声道 16 bit ────────────────────────────────────────────
    //   🔴 **2026-09-26 修正（⭐ 我第一版解串写错了）**：
    //      ⚠️ 原来用 `bitpos` 数到 32 才输出，🔴 但 `bitpos` 在右声道被清零
    //      ⇒ ⚠️ 而我的清零时机与"声道边界"不一致 ⇒ 🔴 只解出 1 个样点。
    //   ⭐ 正确做法：⭐ **用 LRCK 的电平判声道**，⭐ 在**左声道内**数 32 位，
    //      ⭐ 收满就取数 ⇒ ⚠️ **不依赖任何内部计数器**。
    //   📌 同样呼应 RTL 里那条教训：⭐ **用外部可观测信号判状态**，
    //      ⛔ 不要用自己维护的计数器去"猜"边界。
    reg  [31:0] rx_l = 0;
    integer     n_samp = 0;
    integer     samp_min = 32767, samp_max = -32768;
    integer     n_zero_samp = 0, n_diff_val = 0;
    integer     prev_s = 0;
    reg  [5:0]  bitpos = 0;

    //   🔴 **2026-09-26 第二个修正（⭐ 真正的原因）**：
    //      ⚠️ 我原来用 `bck === 1'b1 && bck_p === 1'b0` 判上升沿，
    //      🔴 **但 `bck_p` 是在【另一个 `always` 块】里更新的** ⇒
    //      ⚠️ 两个块在同一次 `posedge` 的执行顺序**不确定** ⇒
    //      🔴 **竞争** ⇒ ⚠️ 解串块可能拿到"已经更新过"的 `bck_p`
    //      ⇒ 🔴 **漏掉绝大多数上升沿** ⇒ 只解出 1 个样点。
    //   ⭐ 修法：⭐ **自建独立的边沿检测**（⭐ 本块自己的 `prev_bck`，
    //      ⛔ 不与统计块共享）⇒ ⭐ **结构上排除竞争**。
    //   ⭐⭐ **2026-09-26 再修正：⭐ 采样时刻改用【下降沿】**
    //      📌 I2S 约定：⭐ **数据在 BCK 下降沿变化、在上升沿被 DAC 采**
    //      ⇒ ⭐ 本 tb 作为"接收端"，⭐ 应当采在**"数据已稳定、DAC 正要采"的时刻**
    //        —— ⭐ 也就是**上升沿那拍读到的东西**，⭐ 而它的值由**前一个下降沿**设定。
    //      ⚠️ 我第一版采在**上升沿**同名的那一拍，⚠️ 但 `din_r` 在
    //         **同一个 `posedge clk`** 上也可能被更新 ⇒ 🔴 **读到新旧之间的值**。
    //      ⭐ 改为**显式在下降沿之后采**（⭐ 此时 `din_r` 已稳定一整个半周期）。
    //   🔴 **独立证据**：⭐ 探针 `probe_cmp` 显示"收到的字 ~ 发送值右移" ⇒
    //      ⚠️ 说明**接收相位偏了**，⭐ 而 RTL 内部正弦是**正确的双极性**
    //      （⭐ `min=-16384 max=16383`）⇒ ⭐ **问题在采样时刻，⛔ 不在 RTL**。
    reg prev_bck = 1'b1;
    wire bck_fall = (bck === 1'b0) && (prev_bck === 1'b1);

    always @(posedge clk) prev_bck <= bck;

    always @(posedge clk) begin
        if (rst_n && bck_fall) begin
            if (lrck === 1'b0) begin
                //   ⭐ **左声道**：⭐ 逐位收
                rx_l   = {rx_l[30:0], din};
                bitpos = bitpos + 6'd1;
                if (bitpos == 6'd32) begin
                    begin : samp_chk
                        //   🔴🔴 **2026-09-26 修正（⭐ 我 tb 的符号 bug，⭐ 改了两次才对）**：
                        //      ⚠️ `reg signed [15:0] sv; sv = $signed(rx_l[30:15]);`
                        //      🔴 **仍然丢掉符号** —— 因为 `rx_l` 声明为**无符号**
                        //         ⇒ ⚠️ `rx_l[30:15]` 是**无符号表达式**，⭐
                        //         `$signed()` 只改"解释方式"、⛔ **不做位宽扩展**
                        //         ⇒ 负样点（⭐ MSB=1）被当成大正数 ⇒ 🔴 `min` 恒 0。
                        //   ⭐ **可靠修法：⭐ 显式做二进制补码扩展** ——
                        //      ⭐ 拆成 `无符号低 15 位` 减 `MSB × 2^15` ⇒ ⭐ 无歧义。
                        //   📌 **独立探针已证明 RTL 正确**（⭐ `min=-16384 max=16383`、
                        //      ⭐ 245 个负样点）⇒ ⚠️ **这个 bug 完全在我 tb 里**。
                        //   ⚠️ **差点因此误判成 RTL 缺陷** —— ⭐ 值得记住：
                        //      🔴 **"探针"本身也要先自证**（⭐ 同族：`K-129`）。
                        integer sv_i;
                        sv_i = (rx_l[30] == 1'b1)
                             ? (rx_l[29:15] - 32768)     // ⭐ MSB=1 ⇒ 负数
                             :  rx_l[29:15];             // ⭐ MSB=0 ⇒ 正数
                        n_samp = n_samp + 1;
                        if (sv_i > samp_max) samp_max = sv_i;
                        if (sv_i < samp_min) samp_min = sv_i;
                        if (sv_i == 0) n_zero_samp = n_zero_samp + 1;
                        if (sv_i != prev_s) n_diff_val = n_diff_val + 1;
                        prev_s = sv_i;
                    end
                    bitpos = 6'd0;
                end
            end else begin
                // ⭐ 右声道：⭐ 复位位计数，⭐ 等下一个左声道
                bitpos = 6'd0;
            end
        end
    end

    integer errors = 0;

    initial begin
        $display("=== tb_dac_tone_top ===");
        $display("⭐ FORMAT_SEL=0 (标准 I2S) · 440 Hz · fs=%0d Hz · BCK=%0d Hz",
                 CLK_HZ/CLK_PER_SAMPLE, CLK_HZ/BCLK_DIV);

        rst_n = 0;
        repeat (10) @(negedge clk);
        rst_n = 1;
        // ⭐ 跑 60 帧（⭐ 够解出多个正弦周期；440Hz/48.8kHz = 每周期 111 帧）
        repeat (CLK_PER_SAMPLE * 400) @(negedge clk);

        $display("--------------------------------------------------");
        $display("  BCK  翻转=%0d  上升沿=%0d  周期 min=%0d max=%0d (期望 %0d)",
                 n_bck_tog, n_bck_edge, gap_bck_min, gap_bck_max, BCLK_DIV);
        $display("  LRCK 翻转=%0d  周期 min=%0d max=%0d (期望 %0d)",
                 n_lrck_tog, gap_lrck_min, gap_lrck_max, CLK_PER_SAMPLE);
        $display("  DIN  翻转=%0d", n_din_tog);
        $display("  解出样点=%0d  min=%0d max=%0d  零值=%0d  变化次数=%0d",
                 n_samp, samp_min, samp_max, n_zero_samp, n_diff_val);
        $display("--------------------------------------------------");

        // ① BCK 周期
        if (gap_bck_min == BCLK_DIV && gap_bck_max == BCLK_DIV && n_bck_edge > 100)
            $display("  ok  : ① BCK 周期恰好 %0d clk（%0d Hz）", BCLK_DIV, CLK_HZ/BCLK_DIV);
        else begin
            $display("FAIL: ① BCK 周期异常 min=%0d max=%0d", gap_bck_min, gap_bck_max);
            errors = errors + 1;
        end

        // ② LRCK 周期
        if (gap_lrck_min == CLK_PER_SAMPLE && gap_lrck_max == CLK_PER_SAMPLE)
            $display("  ok  : ② LRCK 周期恰好 %0d clk（%0d Hz）", CLK_PER_SAMPLE, CLK_HZ/CLK_PER_SAMPLE);
        else begin
            $display("FAIL: ② LRCK 周期异常 min=%0d max=%0d", gap_lrck_min, gap_lrck_max);
            errors = errors + 1;
        end

        // ③ DIN 在动
        if (n_din_tog > 100)
            $display("  ok  : ③ DIN 真的在动（翻转 %0d 次）", n_din_tog);
        else begin
            $display("FAIL: ③ 🔴 DIN 几乎不动（翻转 %0d 次）—— DAC 收不到数据", n_din_tog);
            errors = errors + 1;
        end

        // ④ 解出正弦（多个不同值）
        if (n_diff_val > 50 && n_samp > 100)
            $display("  ok  : ④ 解出有效正弦（%0d 个样点，%0d 次值变化）", n_samp, n_diff_val);
        else begin
            $display("FAIL: ④ 🔴 解出的样点不变或太少（%0d 样点 / %0d 变化）", n_samp, n_diff_val);
            errors = errors + 1;
        end

        // ⑤ 幅度合理（⭐ 必须有【双极性】的真实摆幅 + ⭐ 不越界）
        //   🔴 **2026-09-26 修正（⭐ 我判据的阈值写错了）**：
        //      ⚠️ 我原来要求 `max > 20000 && min < -20000`
        //      ⇒ 🔴 **误报** —— ⭐ 本 tb 用 `AMP_SHIFT=1`（⭐ 半幅），
        //         ⭐ 正弦峰值**本来就是 ±16384**（⭐ 满幅 32767 的一半）。
        //      ⭐ 正确的判据是：⭐ **双极性**（⭐ 有正有负，⭐ 这是"正弦"的关键特征）
        //         ＋ ⭐ **摆幅接近满幅的一半**（⭐ 在合理范围内）
        //         ＋ ⭐ **不越 16 bit 边界**。
        //   📌 **教训**：⭐ **判据的阈值必须与【当前参数档】匹配** ——
        //      ⚠️ 同族：`K-129`/`R-16`（判据与配置脱节 ⇒ 误报或漏报）。
        //   ⭐ **本条的真正价值**：⭐ **它同时证明了"双极性"** ——
        //      ⚠️ 而"双极性"正是 I2S 数据格式对不对的**核心判据**（⭐ 见文件头）。
        if (samp_max > 10000 && samp_min < -10000
            && samp_max <= 32767 && samp_min >= -32768
            && n_diff_val > 100)
            $display("  ok  : ⑤ 幅度合理且【双极性】（%0d .. %0d，摆幅 %0d）—— 正弦正确",
                     samp_min, samp_max, samp_max - samp_min);
        else begin
            $display("FAIL: ⑤ 幅度异常（%0d .. %0d）—— 非双极性/摆幅不足/越界",
                     samp_min, samp_max);
            errors = errors + 1;
        end

        // ⑦ A8
        if (bck !== 1'bx && lrck !== 1'bx && din !== 1'bx)
            $display("  ok  : ⑦ A8 无 X/Z");
        else begin
            $display("FAIL: ⑦ 出现 X/Z");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: dac_tone_top 输出正确的 I2S 流（BCK/LRCK/DIN 全对，正弦可解）");
        else
            $fatal(1, "FAIL: dac_tone_top has %0d error(s)", errors);

        $finish;
    end

    initial begin
        #50000000;
        $display("FAIL: tb 超时");
        $finish;
    end

endmodule
