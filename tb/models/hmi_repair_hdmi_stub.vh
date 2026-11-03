`timescale 1ns/1ps
//  ⭐ 2026-10-09：新增显示模式参数（⛔ 端口一个没变 ⇒ 对 top.v 的连线零影响）
//    SCOPE_MODE = 0 → 波形（原行为）· 1 → 李萨如（XY）
module hdmi_scope #(
    parameter integer XY_DELAY    = 64,    // Y 取延迟多少个样本（64 ≈ 1.3 ms）
    parameter integer XY_GAIN     = 8,
    parameter integer FFT_ENABLE = 0
) (
    input wire clk, rst_n,
    input wire SCOPE_MODE,                 // ⭐ 运行时显示模式（串口 'Q' 切换）
    input wire FFT_MODE,
    input wire [5:0] TEST_N,
    input wire signed [23:0] sample_i,
    input wire valid_i,
    output wire [2:0] tmds_d_p_0, tmds_d_n_0,
    output wire tmds_clk_p_0, tmds_clk_n_0, hpd_en
);
assign tmds_d_p_0=0;assign tmds_d_n_0=0;assign tmds_clk_p_0=0;assign tmds_clk_n_0=0;assign hpd_en=1;
endmodule
