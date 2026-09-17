`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A8 · 通用 X/Z 传播检查器（每个 tb 都应例化）
//
//   断言：复位释放后，被监视信号**任何一位**为 X 或 Z 即为违规。
//
//   用法：chk_xprop #(.W(8), .NAME("audio_sample")) u_a8 (
//             .clk(clk), .rst_n(rst_n), .sig(sample), .err_cnt(a8_err));
//
//   负向测试：把 sig 故意置成 8'hxx ⇒ 应看到 `ERROR [A8] …` 且 err_cnt 增加。
//
// ⚠️ 为什么必须有它：X 传播是"仿真看着对、上板全死"的最常见来源，
//    而赛题要求「可通过 RTL 代码佐证」纯硬件实时合成通路 ——
//    把"无 X"变成**可失败的自动判据**，比"我看波形是好的"强得多。
//
// ⚠️ 用法约定：err_cnt 是**计数**，不是"失败"本身 ——
//    负向测试的 tb 会故意制造 ERROR 行。tb 的结论必须由 tb 自己给
//    （见 `files/20-代码/仿真与验证方案.md` §五 的结论约定）。
// ─────────────────────────────────────────────────────────────
module chk_xprop #(
    parameter integer W          = 1,
    parameter         NAME       = "sig",
    parameter integer MAX_REPORT = 8      // 同一实例最多打印几条，避免刷屏
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] sig,
    output reg [31:0]   err_cnt
);
    integer reported;

    initial begin
        err_cnt  = 32'd0;
        reported = 0;
    end

    always @(posedge clk) begin
        // 复位期间允许为 X（寄存器尚未初始化），只在复位释放后判定
        if (rst_n === 1'b1) begin
            if (^sig === 1'bx) begin          // 任一位为 X/Z ⇒ 缩位异或为 x
                err_cnt = err_cnt + 32'd1;
                if (reported < MAX_REPORT) begin
                    reported = reported + 1;
                    $display("ERROR [A8] %0s 出现 X/Z：%b (t=%0t)", NAME, sig, $time);
                end
            end
        end
    end
endmodule
