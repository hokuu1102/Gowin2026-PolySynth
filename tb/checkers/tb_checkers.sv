`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// T3 · 结构类断言 A1 / A2 / A3 / A4 / A5 / A6 / A7 / A8 的自检 tb（**正向 + 负向**）
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
// 覆盖（每个检查器都**必须**有一正一反两个用例）：
//   A1 最小脉宽      ① 够宽不误报  ② **恰好 1 拍**的窄脉冲必须抓到（`K-01` 的真实故障形态）
//   A2 LE 移位期低   ① `LE` 低时移位不误报  ② `LE` 高时来 `SCK` 边沿必须抓到（`K-03`）
//   A3 同网检测      ① 两根独立时钟不误报  ② 同一根网线必须抓到
//   A4/A5 至多一有效 ① 单路有效不误报  ② 两路同时有效必须抓到（片选互斥 / MISO 单驱动源）
//   A6 帧 deadline   ① 帧内完成不误报  ② 超时必须抓到  ③ 整帧未完成必须抓到
//   A7 相位前进      ① 正常前进/变调都不误报  ② **变调时清零相位**必须抓到（`K-10`）  ③ 合法重启（`jump_ok`）不误报
//   A8 无 X          ① 干净窗口不误报  ② 注入 X 必须抓到
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

    // ═══════════════════════════════════════════════════════════
    // A1 · 最小脉宽（窄脉冲）—— `K-01` 的真实故障形态：`/OE` 上 1 个 clk 宽的误脉冲
    // ═══════════════════════════════════════════════════════════
    reg         oe_n    = 1'b1;
    wire [31:0] a1_err;
    chk_min_pulse #(.NAME("oe_n"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (
        .clk(clk), .rst_n(rst_n), .sig(oe_n), .err_cnt(a1_err));

    // ⭐ A1 的**第二条路径**：`MIN_NS`（真实时间 / 亚周期毛刺）—— 独立实例、独立信号。
    //    ⚠️ 这里 `MIN_NS=200`（远大于时钟周期 20 ns），所以任何短于 200 ns 的低电平都算毛刺；
    //       下面的用例会打一个 **3 ns** 的毛刺（同步检查按 clk 采样**可能采不到**）。
    reg         glitch_sig = 1'b1;
    wire [31:0] a1ns_err;
    integer     ns_before;
    chk_min_pulse #(.NAME("glitch_sig"), .ACTIVE_LOW(1), .MIN_CYCLES(2), .MIN_NS(200)) u_a1ns (
        .clk(clk), .rst_n(rst_n), .sig(glitch_sig), .err_cnt(a1ns_err));

    // 低电平持续 n 个 clk 周期（在 negedge 上动作 ⇒ 被采样的拍数恰好 = n）
    task automatic low_pulse;
        input integer n;
        begin
            @(negedge clk); oe_n = 1'b0;
            repeat (n) @(negedge clk);
            oe_n = 1'b1;
        end
    endtask

    // ═══════════════════════════════════════════════════════════
    // A2 · `LE` 在移位期间必须保持低 —— `K-03`
    // ═══════════════════════════════════════════════════════════
    reg         le = 1'b0, sck = 1'b0;
    wire [31:0] a2_err;
    chk_le_shift #(.NAME_LE("le"), .NAME_SCK("sck")) u_a2 (
        .clk(clk), .rst_n(rst_n), .le(le), .sck(sck), .err_cnt(a2_err));

    // 给移位时钟一个完整周期（两个边沿）
    task automatic sck_cycle;
        begin
            @(negedge clk); sck = ~sck;
            @(negedge clk); sck = ~sck;
        end
    endtask

    // ═══════════════════════════════════════════════════════════
    // A4 / A5 · "至多一个有效"（片选互斥 / MISO 单驱动源）
    // ═══════════════════════════════════════════════════════════
    reg  [2:0]  cs_n   = 3'b111;    // 低有效：0 = 选中
    reg  [2:0]  drv_en = 3'b000;    // 高有效：1 = 该片在驱动 MISO
    wire [31:0] a4_err, a5_err;
    chk_at_most_one #(.N(3), .ACTIVE_LOW(1), .NAME("adc_cs_n")) u_a4 (
        .clk(clk), .rst_n(rst_n), .v(cs_n), .err_cnt(a4_err));
    chk_at_most_one #(.N(3), .ACTIVE_LOW(0), .NAME("miso_drv_en")) u_a5 (
        .clk(clk), .rst_n(rst_n), .v(drv_en), .err_cnt(a5_err));

    // ═══════════════════════════════════════════════════════════
    // A7 · 相位只按 `phase_inc` 前进（⛔ 变调不许清零）—— `K-10`
    // ═══════════════════════════════════════════════════════════
    reg  [31:0] p_acc = 32'd0, p_inc = 32'd1000;
    reg         p_tick = 1'b0, p_jump_ok = 1'b0, p_zero = 1'b0;
    wire [31:0] a7_err;
    chk_phase_advance #(.W(32), .NAME("phase_acc")) u_a7 (
        .clk(clk), .rst_n(rst_n), .tick(p_tick), .acc(p_acc), .inc(p_inc),
        .jump_ok(p_jump_ok), .err_cnt(a7_err));

    // 桩 DDS：tick 那一拍按 `phase_inc` 前进；
    // `p_zero=1` 时**故意清零**（= 模拟 `K-10` 里那个错误做法），用来证明检查器会触发。
    always @(posedge clk) begin
        if (rst_n === 1'b1 && p_tick === 1'b1)
            p_acc <= p_zero ? 32'd0 : (p_acc + p_inc);
    end

    task automatic p_step;          // 走一个音频帧节拍（并给检查器留一拍去看结果）
        begin
            @(negedge clk); p_tick = 1'b1;
            @(negedge clk); p_tick = 1'b0;
            @(negedge clk);
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

        // ═══════════════════════════ A1 ═══════════════════════════
        $display("--- A1 正例：够宽的有效脉冲（8 拍 ≥ 4）---");
        low_pulse(8);
        repeat (2) @(negedge clk);
        if (a1_err == 32'd0) $display("  ok : A1 宽度足够不误报");
        else begin $display("FAIL: A1 把正常宽度的脉冲误判成窄脉冲"); errors = errors + 1; end

        $display("--- A1 反例：恰好 1 拍的窄脉冲（K-01 的真实故障形态）---");
        low_pulse(1);
        repeat (2) @(negedge clk);
        if (a1_err == 32'd1) $display("  ok : A1 单周期窄脉冲被抓到（负向测试）");
        else begin
            $display("FAIL: A1 没抓到单周期窄脉冲（负向测试失效）"); errors = errors + 1;
        end

        // ⭐ 2026-09-17 补：A1 的**第二条检查路径**（`MIN_NS` 亚周期毛刺）——
        //    原来只有 `MIN_CYCLES`（同步宽度）这一条被验过，`MIN_NS>0` 的**真实时间**
        //    检查路径**一次都没跑过**。这里给一个独立实例、故意把阈值设得很宽
        //    （`MIN_NS = 200` > 时钟周期 20 ns），再打一个**比时钟周期还窄**的毛刺。
        //    ⚠️ 用 `#3` 制造 3 ns 的毛刺：同步检查（按 clk 采样）**可能根本采不到它**，
        //       只有真实时间检查能抓 —— 这正是那条路径存在的理由。
        //    ⚠️⚠️ 时序注意：必须在检查器 `armed`（复位释放后第一拍）**之后**再打毛刺，
        //       否则那次跳变被当成"初始化对齐"而不判 —— 本 tb 第一版就栽在这里
        //       （表现为 err 恒 0，看起来像"检查器失效"，其实是**用例太早**）。
        $display("--- A1b 亚周期毛刺（MIN_NS 路径，同步检查看不见的那种）---");
        repeat (8) @(negedge clk);          // ⭐ 确保 armed 已完成（复位释放 + 若干拍）
        ns_before = a1ns_err;
        glitch_sig = 1'b0;
        #3;
        glitch_sig = 1'b1;                  // 3 ns 的低脉冲（< 一个 clk 周期 20 ns）
        #100;
        if (a1ns_err > ns_before)
            $display("  ok : A1b ⭐ 亚周期毛刺被真实时间检查抓到（%0d 次）—— 同步检查看不见它", a1ns_err);
        else begin
            $display("FAIL: A1b 亚周期毛刺没被抓到（MIN_NS 路径失效，err=%0d）", a1ns_err);
            errors = errors + 1;
        end

        // 正例：给一个**足够宽**的低电平（> MIN_NS），不应被真实时间检查误报
        ns_before = a1ns_err;
        glitch_sig = 1'b0;
        #500;                   // 500 ns >> MIN_NS=200
        glitch_sig = 1'b1;
        #100;
        if (a1ns_err == ns_before)
            $display("  ok : A1b 足够宽的脉冲未被真实时间检查误报");
        else begin
            $display("FAIL: A1b 把足够宽的脉冲误报成毛刺（%0d -> %0d）", ns_before, a1ns_err);
            errors = errors + 1;
        end

        // ═══════════════════════════ A2 ═══════════════════════════
        $display("--- A2 正例：LE 保持低时的移位 ---");
        sck_cycle(); sck_cycle(); sck_cycle(); sck_cycle();
        repeat (2) @(negedge clk);
        if (a2_err == 32'd0) $display("  ok : A2 移位期间 LE 为低，不误报");
        else begin $display("FAIL: A2 把合法移位误判成违规"); errors = errors + 1; end

        $display("--- A2 反例：LE 为高时 SCK 出现边沿（K-03）---");
        le = 1'b1;
        repeat (2) @(negedge clk);
        sck_cycle();
        repeat (2) @(negedge clk);
        le = 1'b0;
        if (a2_err >= 32'd1) $display("  ok : A2 LE 高电平期间移位的边沿被抓到（负向测试）");
        else begin $display("FAIL: A2 没抓到「LE 高时移位」（负向测试失效）"); errors = errors + 1; end

        // ═════════════════════════ A4 / A5 ════════════════════════
        $display("--- A4/A5 正例：单路有效、以及全无效（总线空闲）---");
        @(negedge clk); cs_n = 3'b110; drv_en = 3'b001;
        @(negedge clk); cs_n = 3'b111; drv_en = 3'b000;
        @(negedge clk);
        if (a4_err == 32'd0 && a5_err == 32'd0) $display("  ok : A4/A5 单路有效与全无效都不误报");
        else begin $display("FAIL: A4/A5 对合法情形误报"); errors = errors + 1; end

        $display("--- A4 反例：两路片选同时有效 ---");
        @(negedge clk); cs_n = 3'b100;          // bit0/bit1 同时选中
        @(negedge clk); cs_n = 3'b111;
        repeat (2) @(negedge clk);
        if (a4_err == 32'd1) $display("  ok : A4 片选同时有效被抓到（负向测试）");
        else begin $display("FAIL: A4 没抓到片选同时有效（负向测试失效）"); errors = errors + 1; end

        $display("--- A5 反例：MISO 两个驱动源同时使能 ---");
        @(negedge clk); drv_en = 3'b011;
        @(negedge clk); drv_en = 3'b000;
        repeat (2) @(negedge clk);
        if (a5_err == 32'd1) $display("  ok : A5 多驱动源被抓到（负向测试）");
        else begin $display("FAIL: A5 没抓到多驱动源（负向测试失效）"); errors = errors + 1; end

        // ⭐ 2026-09-17 补：**三路同时有效**（检查器的计数逻辑是 `> 1`，要验它不只看两路）
        $display("--- A4b 边界：三路片选同时有效（不是只看两路）---");
        @(negedge clk); cs_n = 3'b000;      // 三路全选
        @(negedge clk); cs_n = 3'b111;
        repeat (2) @(negedge clk);
        if (a4_err == 32'd2) $display("  ok : A4b 三路同时有效也被抓到（err 2 次，计数逻辑正确）");
        else begin $display("FAIL: A4b 三路同时有效的判定不对（err=%0d，期望 2）", a4_err); errors = errors + 1; end

        // ═══════════════════════════ A7 ═══════════════════════════
        $display("--- A7 正例：按 phase_inc 前进 ---");
        repeat (5) p_step();
        if (a7_err == 32'd0) $display("  ok : A7 正常前进不误报");
        else begin $display("FAIL: A7 正常运行被误判"); errors = errors + 1; end

        $display("--- A7 正例：变调（只改 phase_inc）不误报 —— K-10 的正确做法 ---");
        p_inc = 32'd5000;
        repeat (5) p_step();
        if (a7_err == 32'd0) $display("  ok : A7 变调只改 phase_inc（相位连续）不误报");
        else begin $display("FAIL: A7 把合法的变调误判成相位跳变"); errors = errors + 1; end

        $display("--- A7 反例：变调时清零相位（K-10 的错误做法）---");
        p_zero = 1'b1;
        p_step();
        p_zero = 1'b0;
        if (a7_err == 32'd1) $display("  ok : A7 相位清零被抓到（负向测试）");
        else begin
            $display("FAIL: A7 没抓到相位清零（负向测试失效，实际 err_cnt=%0d）", a7_err);
            errors = errors + 1;
        end

        $display("--- A7 正例：合法相位重启（jump_ok=1）不报 ---");
        p_jump_ok = 1'b1; p_zero = 1'b1;
        p_step();
        p_zero = 1'b0; p_jump_ok = 1'b0;
        if (a7_err == 32'd1) $display("  ok : A7 合法的相位重启（jump_ok）未被误报");
        else begin $display("FAIL: A7 把合法相位重启也报了（jump_ok 没起作用）"); errors = errors + 1; end

        $display("");
        if (errors == 0) begin
            $display("PASS: A1/A2/A3/A4/A5/A6/A7/A8 结构类断言全部按预期工作（含负向测试）");
        end else begin
            $fatal(1, "FAIL: 结构类断言自检有 %0d 项不符合预期", errors);
        end
        #200;
        $finish;
    end

endmodule
