`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// chk_fanout_same · "同源扇出必须逐拍一致" 检查器（A4 的并行采集版，K-79）
//
// 背景（K-79，2026-09-19）：
//   · 三片 MCP3208 必须【并行】采集（串行达不到 2 kHz/通道）。
//   · 并行的正确性前提是【三片锁步】：CS/SCLK/MOSI 三路逐拍完全一致（同源扇出）。
//   · 因此原 A4「三 CS 互斥」不适用于并行 —— 三 CS 同时有效是【设计意图】不是缺陷。
//   · 本检查器是 A4 在并行口径下的替代：判"扇出的 N 路是否逐拍一致"，
//     一旦某一路的 CS/SCLK/MOSI 与主路不同（说明没有锁步/串线），即报违规。
//
// 判据：观察窗口内，N 路信号任何一拍取值不同 ⇒ err_cnt 自增。
//   · 复位期不判（复位时各路可能短暂不同）。
//   · 只报"不一致"这个事实，⛔ 不判"该有效时是否有效"（那是功能真值表的事）。
//
// 用法（N=3，三片 ADC）：
//   chk_fanout_same #(.N(3), .NAME("adc_cs_n")) u_a4p (
//       .clk(clk), .rst_n(rst_n), .v({cs2,cs1,cs0}), .err_cnt(a4_err));
//
// 负向测试：把其中一路异或 1（故意制造不一致）⇒ 必触发。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module chk_fanout_same #(
    parameter integer N          = 3,
    parameter         NAME       = "fanout",
    parameter integer MAX_REPORT = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] v,
    output reg  [31:0]  err_cnt
);
    integer reported;
    integer i;
    integer mismatch;   // 本拍是否有不一致（iverilog 不支持 break，用标志位）

    initial begin
        reported = 0; err_cnt = 32'd0; mismatch = 0;
    end

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            // 复位期不判
        end
        else begin
            mismatch = 0;
            // 以 v[0] 为基准，其余各位必须与之一致
            for (i = 1; i < N; i = i + 1) begin
                if (v[i] !== v[0]) mismatch = 1;
            end
            if (mismatch) begin
                err_cnt = err_cnt + 32'd1;
                if (reported < MAX_REPORT) begin
                    reported = reported + 1;
                    $display("ERROR [A4p] %0s 某一路与第 0 路不一致（%b）—— 同源扇出必须逐拍一致（并行采集锁步）",
                             NAME, v);
                end
            end
        end
    end

endmodule

`default_nettype wire
