`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// bounce_src.sv · S4 触点抖动模型（T2 丙负责，供 T14 debounce 单元 tb 复用）
//
// 用途：模拟机械按键/编码器触点的「按下→抖动→稳定」物理过程，给 debounce 注入
//       真实形态的抖动序列，验证「只产生一次事件」。
//
// 行为（每次 trigger 一次「按下」）：
//   1. 空闲：输出空闲电平（IDLE_LVL）
//   2. trigger 脉冲后，先输出若干次随机抖动（在 0/1 间快速翻转，每次宽度随机）
//   3. 抖动结束后稳定到目标电平（ACTIVE_LVL），此后保持
//   ⭐ 抖动次数与宽度由外部参数控制，tb 可反复触发以覆盖多种抖动形态。
//
// 输出：pin —— 直接驱动 debounce 的物理输入（ACTIVE_LOW 语义由 debounce 归一化）。
// ─────────────────────────────────────────────────────────────────────────────
module bounce_src #(
    parameter integer SEED        = 0,      // 抖动随机种子（换种子改变抖动形态）
    parameter integer BOUNCE_MAX  = 8,      // 单次最多抖动次数
    parameter integer BOUNCE_W_NS = 20000,  // 每次抖动最大宽度（ns）
    parameter integer IDLE_LVL    = 1,      // 空闲电平（上拉 = 1）
    parameter integer ACTIVE_LVL  = 0       // 按下电平（接地 = 0）
) (
    input  wire clk,
    input  wire trigger,                     // 1 周期脉冲：发起一次「按下」
    output reg  pin                          // 输出到 debounce 的物理信号
);

    reg        bouncing;
    reg [31:0] remain;                       // 当前抖动段剩余时间（ns）
    reg [31:0] rnd;
    integer    step;

    // 简易 LFSR 伪随机（仅仿真用途，不进综合）
    always @(posedge clk) begin
        rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    end

    initial begin
        pin      = IDLE_LVL;
        bouncing = 1'b0;
        remain   = 32'd0;
        rnd      = (SEED == 0) ? 32'hACE1_0001 : (32'hACE1_0001 ^ SEED);
    end

    always @(posedge clk) begin
        if (trigger) begin
            // 发起一次按下：进入抖动阶段
            bouncing <= 1'b1;
            pin      <= ACTIVE_LVL;
            remain   <= 32'd1;               // 第一段抖动
            step     <= 0;
        end else if (bouncing) begin
            if (remain > 1) begin
                remain <= remain - 1;
            end else begin
                // 本段抖动结束，翻转并随机决定下一段宽度
                if (step < BOUNCE_MAX) begin
                    pin      <= ~pin;
                    remain   <= 1 + (rnd % BOUNCE_W_NS);   // 1..BOUNCE_W_NS ns
                    step     <= step + 1;
                end else begin
                    // 抖动结束，稳定到按下电平
                    pin      <= ACTIVE_LVL;
                    bouncing <= 1'b0;
                end
            end
        end
    end

endmodule
