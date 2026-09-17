`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A3 · "灯的移位 CLK 与 ADC 的 SPI SCK 不是同一根线" 检查器
//
// ⚠️⚠️ 实现限制（必须写清楚，否则会被误当成"已经完全证明"）：
//     Verilog **没有"网线同一性"算子** —— 无法直接问"a 和 b 是不是同一根线"。
//     所以这里判的是**行为等价 ⇒ 疑似同网**：
//       在观察窗口内，两个信号**各自翻转 ≥ MIN_EDGES 次**，却**从未出现过取值不同**
//       ⇒ 判为"疑似同一根网线"，报 `ERROR [A3]`。
//
//     两根真正独立的时钟（哪怕同频、只是相位或占空比不同）必然很快出现取值不同，
//     所以**不会误报**；反过来，真正并成一根线的两个名字一定会被抓到。
//     ⛔ 它不能替代"顶层结构上让两者来自不同的输出端口"这条设计纪律。
//
//   用法：chk_same_net #(.NAME_A("led_clk"), .NAME_B("spi_sck")) u_a3 (
//             .clk(clk_sys), .rst_n(rst_n), .a(led_clk), .b(spi_sck), .err_cnt(a3_err));
//
//   负向测试：assign a = clk; assign b = clk; ⇒ 必触发（err_cnt 恰好 +1，只报一次）。
// ─────────────────────────────────────────────────────────────
module chk_same_net #(
    parameter         NAME_A     = "clk_a",
    parameter         NAME_B     = "clk_b",
    parameter integer MIN_EDGES  = 8,     // 两个信号各翻转这么多次后才下结论
    parameter integer MAX_REPORT = 4
) (
    input  wire       clk,                // 采样时钟（建议 clk_sys，越快越早下结论）
    input  wire       rst_n,
    input  wire       a,
    input  wire       b,
    output reg [31:0] err_cnt
);
    integer edges_a, edges_b, diffs, reported;
    reg     a_d, b_d, flagged;

    initial begin
        edges_a = 0; edges_b = 0; diffs = 0; reported = 0;
        a_d = 1'b0; b_d = 1'b0; flagged = 1'b0; err_cnt = 32'd0;
    end

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            edges_a = 0; edges_b = 0; diffs = 0; flagged = 1'b0;
        end else begin
            if (a !== a_d) edges_a = edges_a + 1;
            if (b !== b_d) edges_b = edges_b + 1;
            if (a !== b)   diffs   = diffs   + 1;
            a_d = a; b_d = b;

            if (!flagged && diffs == 0 && edges_a >= MIN_EDGES && edges_b >= MIN_EDGES) begin
                flagged = 1'b1;              // 只报一次（结论已定，再刷屏无意义）
                err_cnt = err_cnt + 32'd1;
                if (reported < MAX_REPORT) begin
                    reported = reported + 1;
                    $display("ERROR [A3] %0s 与 %0s 各翻转 %0d/%0d 次却全程取值相同 —— 疑似同一根网线（⛔ 灯 CLK 与 SPI SCK 必须各自独立）",
                             NAME_A, NAME_B, edges_a, edges_b);
                end
            end
        end
    end
endmodule
