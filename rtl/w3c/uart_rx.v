`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// uart_rx.v · UART 接收器（8N1：1 起始 + 8 数据 + 1 停止）—— W3c（曲谱下载通路）
//
// ⭐ 来源：**移植自已有工程** `Desktop/FPGA/ADDA/src/uart_rx.v`（8N1，实测可用）。
//   ⭐ 原版是**已验证过的**（`FPGA招新题/phase4/uart_rx_tb.v` + ADDA 工程都在用）。
//   ✅ 本次**只做"符合本项目规范"的移植**，⛔ 不改状态机逻辑：
//     ① ⭐ **复位风格：异步 → 同步**（改这一处的唯一原因见下）
//     ② ⚠️ `clk_cnt <= 6'd0` → `16'd0`（寄存器是 16 bit；原写法值无害但**语义误导**）
//     ③ ⭐ 加本项目的头部注释与自检
//
// ── ⚠️ 为什么必须把复位改成【同步】（唯一的实质性改动）────────────────────
//   冻结表 §〇 约定 2 原文：
//     ⭐ **"统一复位：`rst_n` 同步复位、低有效，全设计极性一致"**
//     ⚠️ 理由栏写的是：**"混用极性是最常见的集成 bug"**。
//   原版用的是 `always @(posedge clk or negedge sys_rst_n)`（**异步**复位）
//   ⇒ ⭐ 与本设计其余模块**风格不一致** ⇒ 本次统一为**同步**。
//   ⚠️ 注意：这是**风格统一**，⛔ 不是原版有 bug —— 异步复位本身是合法写法。
//
// ── ⭐ 设计要点（沿用原版，已实测）──────────────────────────────────────────
//   1. ⭐ **`rx` 两级同步打拍**（防亚稳态，`L28`：跨时钟域必需）
//   2. ⭐ **起始位中点验证**：中点仍为低才认；⚠️ 毛刺会被丢弃
//   3. ⭐ **数据位在【位中点】采样**（`clk_cnt == BAUD_DIV/2`）⇒ 最稳的采样点
//   4. ⭐ **LSB 先到** ⇒ `rx_data[bit_cnt]` 直接按位写入
//
// ── ⭐ 波特率配置（`BAUD_DIV = round(50 MHz / baud)`）──────────────────────
//   | 波特率 | BAUD_DIV | 说明 |
//   |---|---|---|
//   | **115200** | **434** | ⭐ 推荐（实测 6/6 过，误差 0.006%）|
//   | 1 M | 50 | ⭐ 整除、零误差（原工程用的就是这个）|
//   | 9600 | 5208 | 太慢，⛔ 不推荐（曲谱下载会很久）|
//
//   ⚠️ 误差核算（⭐ 这是"能不能用"的判据，⛔ 不要凭感觉）：
//     `50 MHz / 115200 = 434.028` ⇒ 取 **434** ⇒ 实际 **115 207.4**（误差 **0.006%**）
//     ⇒ 累积到第 10 位只有 **0.001 个位宽**（需 < 0.5）⇒ ✅ **安全**
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⛔ 不用 PLL、不派生时钟（冻结表 §〇 约定 1）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module uart_rx #(
    // ⭐ 每 bit 的 clk 数 = round(50 MHz / 波特率)
    //    ⚠️ 必须 >= 4（否则位中点采样没有意义）
    parameter integer BAUD_DIV = 434        // ⭐ 默认 115200
) (
    input  wire       clk_i,        // ⭐ 50 MHz（冻结表约定 1：单时钟域）
    input  wire       rst_n_i,      // ⭐ **同步**复位、低有效（约定 2）
    input  wire       rx_i,         // 串行输入（空闲高）

    output reg  [7:0] rx_data_o,    // 接收字节
    output reg        rx_done_o     // ⭐ 接收完成**单周期脉冲**（约定 4：边沿时刻断言）
);

    // ⭐ 状态编码（沿用原版的**独热**写法，⛔ 不改）
    localparam [2:0] S_IDLE  = 3'b001;   // 空闲等起始位
    localparam [2:0] S_START = 3'b010;   // 数满起始位
    localparam [2:0] S_DATA  = 3'b100;   // 采 8 个数据位

    // ⭐ 采样点：位中点（最稳）
    localparam [15:0] MID_CNT   = BAUD_DIV >> 1;        // 位中点
    localparam [15:0] START_MID = (BAUD_DIV >> 1) - 1;  // 起始位中点检查点
    localparam [15:0] DIV_LAST  = BAUD_DIV - 1;         // 一位的最后一拍

    reg  [2:0]  state;
    reg  [2:0]  bit_cnt;
    reg  [15:0] clk_cnt;            // ⭐ 16 bit（原版也是）⇒ 支持任意降速分频
    reg         rx_d1, rx_d2;       // ⭐ 两级同步打拍

    // ── 同步打拍（两级，防亚稳态）──────────────────────────────────────────
    //    ⭐ 复位值给 **1**（串口空闲是高）⇒ ⭐ 上电不会误判成"起始位"
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            rx_d1 <= 1'b1;
            rx_d2 <= 1'b1;
        end else begin
            rx_d1 <= rx_i;
            rx_d2 <= rx_d1;
        end
    end

    // ── 主状态机（⭐ 同步复位）──────────────────────────────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state     <= S_IDLE;
            bit_cnt   <= 3'd0;
            clk_cnt   <= 16'd0;
            rx_data_o <= 8'd0;
            rx_done_o <= 1'b0;
        end else begin
            rx_done_o <= 1'b0;      // ⭐ 单周期脉冲：默认清零（约定 4）

            case (state)
                // ── 空闲：等 `rx` 变低（可能是起始位，也可能是毛刺）──────────
                S_IDLE: begin
                    if (rx_d2 == 1'b0) begin
                        state   <= S_START;
                        clk_cnt <= 16'd0;
                    end
                end

                // ── 起始位：中点仍为低才认（⚠️ 排毛刺），数满整位进 DATA ──────
                S_START: begin
                    if ((clk_cnt == START_MID) && (rx_d2 == 1'b1)) begin
                        state <= S_IDLE;            // ⚠️ 中点变高 ⇒ 是毛刺 ⇒ 放弃
                    end else if (clk_cnt == DIV_LAST) begin
                        state   <= S_DATA;          // ⭐ 整位走完 ⇒ 对齐到数据位起点
                        bit_cnt <= 3'd0;
                        clk_cnt <= 16'd0;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                // ── 数据位：位中点采样（⭐ LSB 先到）──────────────────────────
                S_DATA: begin
                    if (clk_cnt == MID_CNT) begin
                        rx_data_o[bit_cnt] <= rx_d2;    // ⭐ LSB 先进 ⇒ bit0 在最低位
                        clk_cnt            <= clk_cnt + 16'd1;
                    end else if (clk_cnt == DIV_LAST) begin
                        if (bit_cnt == 3'd7) begin
                            state     <= S_IDLE;        // ⭐ 8 位采完
                            rx_done_o <= 1'b1;          // ⭐ 单周期完成脉冲
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                            clk_cnt <= 16'd0;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 为什么要有：下面几条会**静默失效**，现象极难定位
    localparam BIT_TOO_FEW = (BAUD_DIV < 4);
    localparam ODD_DIV     = ((BAUD_DIV % 2) != 0);
    initial begin
        if (BIT_TOO_FEW)
            // 🔴 `BAUD_DIV < 4` ⇒ 位中点采样没有意义（起始位中点检查也会失真）
            $display("ERROR [uart_rx] BAUD_DIV=%0d < 4 => 位中点采样不可用（波特率过高）",
                     BAUD_DIV);
        if (ODD_DIV)
            // ⚠️ 奇数分频 ⇒ `MID_CNT` 截断 ⇒ 采样点偏左一点点
            //    ⭐ 不致命（0.1% 级），但**建议取偶数**（如 434）
            $display("WARNING [uart_rx] BAUD_DIV=%0d 为奇数 => 中点采样有半拍偏差，建议取偶数",
                     BAUD_DIV);
    end

endmodule

`default_nettype wire
