`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A1 · 最小脉宽检查器（"⛔ 不许出现窄脉冲"）
//
//   为什么需要它（`files/20-代码/已知问题与风险清单.md` `K-01`）：
//     某类器件的**使能脚**对"一个时钟宽的毛刺"极其敏感 —— 例如恒流 LED 驱动的
//     `/OE` 上出现**单周期脉冲**会把它打进 **Special Mode**，此后输出不再受串行数据控制
//     （现象：明明在移位，灯就是不亮/乱亮）。这类故障**功能仿真往往看不出来**，
//     因为它不破坏数据、只破坏"器件的状态"。
//
//   判据：被监视信号处于**有效电平**的连续时间，不得短于 `MIN_CYCLES` 个 `clk` 周期。
//         `ACTIVE_LOW=1` 表示低有效（如 `/OE`）。
//
//   ⭐ 两种检查（默认只开第 ① 种，避免重复计数）：
//     ① **同步宽度检查**（主判据）：按 `clk` 采样，数连续有效拍数
//        —— 能抓到"1 个 clk 宽的误脉冲"这种真实故障。
//     ② **亚周期毛刺检查**（可选，`MIN_NS > 0` 时生效）：按**真实时间**看电平变化，
//        抓比一个时钟周期还窄的毛刺。⚠️ 只有当被测信号是**组合逻辑直接输出**时才有意义
//        （寄存输出不可能在周期内变化）；默认 `MIN_NS=0`=关闭，以免同一个窄脉冲被两次计数。
//
//   ⚠️ 实现限制（写清楚，别被当成"已经全都证明了"）：
//     ① 同步检查**看不见**比一个 `clk` 周期更窄的毛刺（采样定理）—— 这是 ② 的用途；
//     ② 它判的是"**采样到的**电平宽度"，不判极性是否正确（极性是 `ACTIVE_LOW` 的语义）。
//
//   用法：
//     chk_min_pulse #(.NAME("tlc_oe_n"), .ACTIVE_LOW(1), .MIN_CYCLES(8)) u_a1 (
//         .clk(clk), .rst_n(rst_n), .sig(tlc_oe_n), .err_cnt(a1_err));
//
//   负向测试：把信号拉低**恰好 1 拍**再拉高 ⇒ 必触发（`err_cnt` 恰好 +1）。
// ─────────────────────────────────────────────────────────────
module chk_min_pulse #(
    parameter         NAME       = "sig",
    parameter integer ACTIVE_LOW = 1,     // 1 = 低有效（`/OE` 类）
    parameter integer MIN_CYCLES = 4,     // 允许的最短有效宽度（`clk` 周期数）
    parameter integer MIN_NS     = 0,     // >0 时额外查亚周期毛刺（单位 ns）
    parameter integer MAX_REPORT = 8
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sig,
    output reg [31:0] err_cnt
);
    integer run_len;          // 当前这段有效电平已经持续了多少拍
    integer reported;
    reg     started;          // 复位后已见过至少一拍（避免复位期的伪长度）
    reg     lvl_d, lvl_o;     // 采样到的电平 / 上一次变化前的电平（时间检查用）
    time    t_edge;

    initial begin
        run_len = 0; reported = 0; started = 1'b0; err_cnt = 32'd0;
        lvl_d = 1'b0; lvl_o = 1'b0; t_edge = 0;
    end

    // ── ① 同步宽度检查（主判据）──────────────────────────────
    reg lvl;
    always @(posedge clk) begin
        lvl = (ACTIVE_LOW == 1) ? ~sig : sig;      // 1 = 处于有效电平
        if (rst_n !== 1'b1) begin
            run_len = 0;
            started = 1'b0;
        end else begin
            if (lvl === 1'b1) begin
                run_len = run_len + 1;
            end else begin
                // 一段有效电平刚刚结束：太短就是"窄脉冲"
                if (started && run_len > 0 && run_len < MIN_CYCLES) begin
                    err_cnt = err_cnt + 32'd1;
                    if (reported < MAX_REPORT) begin
                        reported = reported + 1;
                        $display("ERROR [A1] %0s 出现窄脉冲：有效电平只有 %0d 个 clk 周期（要求 ≥ %0d）",
                                 NAME, run_len, MIN_CYCLES);
                    end
                end
                run_len = 0;
            end
            started = 1'b1;
        end
    end

    // ── ② 亚周期毛刺检查（可选）──────────────────────────────
    // ⚠️⚠️ 初始化缺陷修复（2026-09-17，本模块自检抓出来的）：
    //    原来 `lvl_o` 初值是 `1'b0`、`t_edge` 初值是 0。如果被监视信号**上电初值就是有效电平**
    //    （例如 `ACTIVE_LOW=1` 而信号初值为 0），那么**第一次跳变**时判的是
    //    "上一段是无效电平" ⇒ **第一个毛刺永远漏报**（本模块的自检用例正好命中这一点：
    //    信号初值 1、打一个 3 ns 的低脉冲，结果 err=0）。
    //    ⇒ 修法：**在复位释放那一刻，把 `lvl_o`/`t_edge` 对齐到信号的当前电平**
    //      （而不是靠一个猜的初值）。这样"上电就有效的窄脉冲"也能被抓到。
    reg armed;
    initial begin
        armed = 1'b0;
    end

    always @(posedge clk) begin
        if (rst_n !== 1'b1) armed = 1'b0;
        else if (!armed) begin
            // 复位释放后的第一拍：把"上一段"初始化成**当前真实电平**与当前时刻
            armed = 1'b1;
            lvl_o = sig;
            t_edge = $time;
        end
    end

    always @(sig) begin
        if (rst_n === 1'b1 && MIN_NS > 0 && armed) begin
            // 上一段电平（`lvl_o`）是否有效、且持续时间不足 MIN_NS
            if ((ACTIVE_LOW == 1 ? ~lvl_o : lvl_o) === 1'b1 && ($time - t_edge) < MIN_NS) begin
                err_cnt = err_cnt + 32'd1;
                if (reported < MAX_REPORT) begin
                    reported = reported + 1;
                    $display("ERROR [A1] %0s 出现亚周期毛刺：有效电平只有 %0t（要求 ≥ %0d ns）",
                             NAME, $time - t_edge, MIN_NS);
                end
            end
            t_edge = $time;
            lvl_o = sig;
        end else if (rst_n === 1'b1 && MIN_NS > 0 && !armed) begin
            // 还没 armed：只跟踪，不判定（避免用未初始化状态误报）
            t_edge = $time;
            lvl_o = sig;
        end
    end
endmodule
