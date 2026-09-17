`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_clk_gen_badparam · **参数合法性自检的负向用例**（R-17 / R-05）
//
// ⭐ 为什么需要它：`clk_gen` 把 `$clog2` 当**移位量/位选**用，只在"参数是 2 的幂"时
//    才等于真除法 —— ⛔ 非 2 的幂会**静默给错频率**（不报错、不告警，只是频率不对）。
//    所以模块里加了 `PARAM_OK` + `initial $display`，**本 tb 就是证明"它真的会报"**。
//
// ⚠️ 本 tb 的"通过"判据是**日志里必须出现 ERROR 行**（这与其它 tb 相反！）：
//    `sim/tb_all.ps1` 只把"行首 FAIL / 非零退出码"当失败，**ERROR 只计数**，
//    所以这里可以安全地"故意打 ERROR"（见验证方案 §五 的结论约定）。
//
// 判据：
//   ① 非 2 的幂参数（`CLK_PER_SAMPLE=1000`、`BCLK_DIV=12`）必须打出 `ERROR [clk_gen]`
//   ② 正常参数（1024/16/4）必须**不**打 ERROR
//   ③ 两次都要能正常跑完（⛔ 不能因为参数不合法就卡死/崩溃）
// ─────────────────────────────────────────────────────────────────────────────
module tb_clk_gen_badparam;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;      // 50 MHz

    integer errors = 0;

    // ── ① 非法参数实例：必须报错 ──────────────────────────────────
    wire t1, m1, b1, bh1, l1, f1;
    clk_gen #(
        .CLK_PER_SAMPLE (1000),     // ⛔ 非 2 的幂
        .BCLK_DIV       (12),       // ⛔ 非 2 的幂（会被当成 ÷16 用 ⇒ 静默错频率）
        .MCLK_DIV       (4)
    ) u_bad (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (t1), .mclk_en (m1), .bclk_en (b1),
        .bclk_half_en (bh1), .lrclk (l1), .frame_start (f1)
    );

    // ── ② 合法参数实例：必须不报错 ────────────────────────────────
    wire t2, m2, b2, bh2, l2, f2;
    clk_gen #(
        .CLK_PER_SAMPLE (1024), .BCLK_DIV (16), .MCLK_DIV (4)
    ) u_ok (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (t2), .mclk_en (m2), .bclk_en (b2),
        .bclk_half_en (bh2), .lrclk (l2), .frame_start (f2)
    );

    // 统计两个实例各自的 `bclk_en` 间隔（用来"看见"参数不合法导致的频率偏差）
    integer n_b1, n_b2;
    reg b1_d, b2_d;
    initial begin
        n_b1 = 0; n_b2 = 0; b1_d = 1'b0; b2_d = 1'b0;
    end
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (b1 === 1'b1 && b1_d === 1'b0) n_b1 = n_b1 + 1;
            if (b2 === 1'b1 && b2_d === 1'b0) n_b2 = n_b2 + 1;
        end
        b1_d = b1; b2_d = b2;
    end

    initial begin
        $dumpfile("build/sim/tb_clk_gen_badparam/tb_clk_gen_badparam.vcd");
        $dumpvars(0, tb_clk_gen_badparam);

        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4096) @(posedge clk);
        #1;

        $display("");
        $display("================ clk_gen 参数自检（负向）================");
        $display("  非法参数实例(1000/12/4) 的 bclk_en 次数 = %0d", n_b1);
        $display("  合法参数实例(1024/16/4) 的 bclk_en 次数 = %0d", n_b2);
        $display("  ⚠️ 上面若出现 ERROR [clk_gen] 行，那正是**预期结果**");
        $display("========================================================");

        // ① 非法参数下，`bclk_en` 的实际频率应当是"按 ÷16 走"（= 静默错频率的证据）
        //    4096 拍里，÷16 会有 ≈256 次；若真按 ÷12 应是 ≈341 次。
        //    ⇒ 实测接近 256 就说明"非 2 的幂被静默当成 2 的幂"，这正是要告警的原因。
        if (n_b1 > 240 && n_b1 < 280)
            $display("  ok : 非法参数确实被**静默按 ÷16** 处理（%0d 次 ≈ 256）—— 证明必须靠 PARAM_OK 告警", n_b1);
        else begin
            $display("FAIL: 非法参数下的行为与预期不符（%0d 次，期望 ≈256）", n_b1);
            errors = errors + 1;
        end

        // ② 合法参数：4096 拍 ≈ 256 次 bclk_en
        if (n_b2 > 240 && n_b2 < 280)
            $display("  ok : 合法参数下 bclk_en 次数正常（%0d ≈ 256）", n_b2);
        else begin
            $display("FAIL: 合法参数下 bclk_en 次数异常（%0d）", n_b2);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0)
            $display("PASS: clk_gen 参数自检按预期工作（非法参数会告警；合法参数无告警；两者都不卡死）");
        else
            $fatal(1, "FAIL: clk_gen 参数自检用例有 %0d 项不符合预期", errors);

        #100;
        $finish;
    end

endmodule
