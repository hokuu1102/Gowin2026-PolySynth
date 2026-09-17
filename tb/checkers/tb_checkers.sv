`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// T3 · 结构类断言 A3 / A6 / A8 的自检 tb（**正向 + 负向**）
//
// ⭐ T3 的验收判据是「故意注入错误能**触发断言**（负向测试）」——
//    所以本 tb 会**故意制造违规**，日志里出现 `ERROR [Ax]` 是**预期结果**。
//
// ⚠️⚠️ 因此本 tb 的结论**不能**由"日志里有没有 ERROR"来判 ——
//     必须由 tb 自己给（见 `files/20-代码/仿真与验证方案.md` §五 结论约定）：
//        全过  → 打印 `PASS: …`，正常结束（exit 0）
//        不过  → 打印 `FAIL: …` 并 `$fatal(1,…)`（非零退出）
//     `sim/tb_all.ps1` 只认这两样（退出码 + 行首 `FAIL`）。
//
// 覆盖：
//   A8 ① 干净窗口不误报  ② 注入 X 必须抓到
//   A3 ① 两根独立时钟不误报  ② 同一根网线必须抓到
//   A6 ① 帧内完成不误报  ② 超时（>1024 拍）必须抓到  ③ 整帧未完成必须抓到
//
// ⚠️ 三条 Icarus 实测踩过的坑（写其它 tb 时会再遇到）：
//   ① 任务名**不能叫 `expect`** —— 它是 SystemVerilog 保留字，报错落在 task 行、
//      后续每个调用都变 "Malformed statement"，极易误判成"端口写法不对"；
//   ② 任务端口用**非 ANSI 风格**（`task t; input …;`）：`task t(input cond);` 过不去；
//   ③ ⛔ **别用 task 端口传字符串**：`input [1023:0] msg` + `%0s` 打印出来是乱码
//      （本文件实测），所以下面的通过/失败消息一律用**调用处的字面量**直接 $display。
// ─────────────────────────────────────────────────────────────
module tb_checkers;

    localparam integer T              = 20;    // clk_sys = 50 MHz
    localparam integer CLK_PER_SAMPLE = 1024;  // = files/20-代码/W3接口冻结表.md 的 CLK_PER_SAMPLE

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // A3 的采样时钟：⛔ 不能用被监视的那根时钟去采样它自己 ——
    // 同一个时钟在它自己的 posedge 上取值恒为 1、边沿数恒为 0，断言会**永远不下结论**。
    // 真实设计里采样时钟是 clk_sys，被监视的是它派生出的慢信号。
    reg clk_smp = 1'b0;
    always #(T/8) clk_smp = ~clk_smp;

    integer errors = 0;

    // ── A8：被监视信号（后段故意注入 X）─────────────────────
    reg  [7:0]  probe;
    wire [31:0] a8_err;
    chk_xprop #(.W(8), .NAME("probe")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig(probe), .err_cnt(a8_err));

    // ── A3：① 两根独立时钟（不该报）② 同一根网线（必须报）──
    reg clk_b = 1'b0;
    always #(T/2 + 3) clk_b = ~clk_b;      // 26 ns 周期，与 clk 不同频

    wire same_a, same_b;
    assign same_a = clk;
    assign same_b = clk;                   // ⛔ 故意接成同一根网线

    wire [31:0] a3_err_ok, a3_err_bad;
    chk_same_net #(.NAME_A("clk"), .NAME_B("clk_b")) u_a3_ok (
        .clk(clk_smp), .rst_n(rst_n), .a(clk),    .b(clk_b),  .err_cnt(a3_err_ok));
    chk_same_net #(.NAME_A("led_clk"), .NAME_B("spi_sck")) u_a3_bad (
        .clk(clk_smp), .rst_n(rst_n), .a(same_a), .b(same_b), .err_cnt(a3_err_bad));

    // ── A6：音频帧节拍与完成信号 ────────────────────────────
    reg         tick_audio    = 1'b0;
    reg         frame_done    = 1'b0;
    wire        deadline_fault;
    wire [31:0] a6_viol;
    chk_deadline #(.CLK_PER_SAMPLE(CLK_PER_SAMPLE), .NAME("tb_top")) u_a6 (
        .clk(clk), .rst_n(rst_n), .tick_audio(tick_audio), .frame_done(frame_done),
        .deadline_fault(deadline_fault), .viol_cnt(a6_viol));

    // 一帧：先在 negedge 打 tick，再走 frame_cycles 拍；
    // done_at >= 0 时在第 done_at 拍给 frame_done，done_at < 0 表示**整帧不给**
    task automatic run_frame;
        input integer done_at;
        input integer frame_cycles;
        integer i;
        begin
            @(negedge clk); tick_audio = 1'b1;
            @(negedge clk); tick_audio = 1'b0;
            frame_done = 1'b0;
            for (i = 0; i < frame_cycles; i = i + 1) begin
                @(negedge clk);
                if (done_at >= 0 && i == done_at) frame_done = 1'b1;
                else                              frame_done = 1'b0;
            end
            @(negedge clk); frame_done = 1'b0;
        end
    endtask

    reg [31:0] a8_err_clean;

    initial begin
        $dumpfile("build/sim/tb_checkers/tb_checkers.vcd");
        $dumpvars(0, tb_checkers);

        probe = 8'h00;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        $display("--- A8 / A3 干净窗口（不应有任何违规）---");
        probe = 8'hA5;
        repeat (60) @(negedge clk);
        a8_err_clean = a8_err;

        if (a8_err_clean == 32'd0) $display("  ok : A8 干净窗口内无 X 传播（不误报）");
        else begin $display("FAIL: A8 干净窗口内出现了 X（不该报）"); errors = errors + 1; end

        if (a3_err_ok == 32'd0) $display("  ok : A3 两根独立时钟未被误判为同一根网线");
        else begin $display("FAIL: A3 把两根独立时钟误判成同一根网线了"); errors = errors + 1; end

        if (a3_err_bad == 32'd1) $display("  ok : A3 同一根网线被抓到（负向测试）");
        else begin $display("FAIL: A3 没抓到「两个名字接同一根网线」（负向测试失效）"); errors = errors + 1; end

        $display("--- A6 正例：帧内完成 ---");
        run_frame(100, 400);
        if (a6_viol == 32'd0) $display("  ok : A6 第 100 拍完成（< 1024）不误报");
        else begin $display("FAIL: A6 帧内完成却被判超时"); errors = errors + 1; end

        if (deadline_fault === 1'b0) $display("  ok : A6 未置 deadline_fault");
        else begin $display("FAIL: A6 不该置 deadline_fault 却置了"); errors = errors + 1; end

        $display("--- A6 反例 1：超时（第 1500 拍才完成 > 1024）---");
        run_frame(1500, 1700);
        if (a6_viol == 32'd1) $display("  ok : A6 超时被抓到（负向测试）");
        else begin $display("FAIL: A6 超时没被抓到（负向测试失效）"); errors = errors + 1; end

        if (deadline_fault === 1'b1) $display("  ok : A6 超时后 deadline_fault = 1");
        else begin $display("FAIL: A6 超时后 deadline_fault 仍为 0"); errors = errors + 1; end

        $display("--- A6 反例 2：整帧不给 frame_done ---");
        run_frame(-1, 1200);
        if (a6_viol == 32'd1) $display("  ok : A6 边界语义：未到下一个 tick 前不报（本帧仍在进行）");
        else begin $display("FAIL: A6 未到下一个 tick 就报了（边界语义不对）"); errors = errors + 1; end

        run_frame(100, 400);
        if (a6_viol == 32'd2) $display("  ok : A6 整帧未完成 → 在下一次 tick 时报出（负向测试）");
        else begin $display("FAIL: A6 整帧未完成没被抓到（负向测试失效）"); errors = errors + 1; end

        $display("--- A8 反例：注入 X ---");
        probe = 8'hxx;
        repeat (4) @(negedge clk);
        probe = 8'h00;
        repeat (2) @(negedge clk);
        if (a8_err > a8_err_clean) $display("  ok : A8 注入 X 被抓到（负向测试）");
        else begin $display("FAIL: A8 注入的 X 没被抓到（负向测试失效）"); errors = errors + 1; end

        $display("");
        if (errors == 0) begin
            $display("PASS: A3/A6/A8 结构类断言全部按预期工作（含负向测试）");
        end else begin
            $fatal(1, "FAIL: A3/A6/A8 自检有 %0d 项不符合预期", errors);
        end
        #200;
        $finish;
    end

endmodule
