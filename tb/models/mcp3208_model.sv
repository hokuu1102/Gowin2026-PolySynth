`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// mcp3208_model.sv · MCP3208 从机模型（S1，T2 丙部分，三人共用）
//
// 用途：在没有系统板的情况下，仿真里充当一片 MCP3208 ADC 从机，
//       让采集链（adc_farm / mcp3208_scanner / mcp3208_driver）能"读到真数据"。
//
// 协议（DS21298E，SPI mode 0，CPOL=0/CPHA=0）：
//   · CS 拉低启动转换；SCLK 上升沿从 DIN 采样主机命令；
//   · 主机命令 24 bit：5 个引导零 + START(1) + SGL/DIFF(1) + D2/D1/D0(3) + 14 个填充；
//   · 第 3 个 SCLK 下降沿后（D2..D0 收齐），DOUT 开始回 12 位结果（B11 先出）；
//   · 本模型简化：按第 5~16 个 SCLK 下降沿逐位回结果（与现有 tb 口径一致）。
//
// 参数：
//   · IDVAL：本片返回的基准值（每片不同，用于区分三片是否串线）。
//
// 用法：
//   mcp3208_model #(.IDVAL(12'h100)) u_adc0 (
//       .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso));
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module mcp3208_model #(
    parameter [11:0] IDVAL = 12'h000   // 本片基准值（测试时叠加通道号）
) (
    input  wire       cs_n,
    input  wire       sclk,
    input  wire       mosi,
    output reg        miso
);

    integer sclk_rising_count;
    reg [23:0] captured_mosi;
    reg [2:0]  response_channel;
    reg [11:0] response_value;

    // 每片返回的样本值 = IDVAL 的低 9 位拼接 + 通道号（确定性、可逐位比对）
    // 这样三片用不同 IDVAL，样本值各不相同，能验证"三片 MISO 没串线"。
    function automatic [11:0] value_for_channel(input [2:0] ch);
        begin
            value_for_channel = (IDVAL + {9'd0, ch});
        end
    endfunction

    // 每次 CS 拉低开始新事务
    always @(negedge cs_n) begin
        sclk_rising_count = 0;
        captured_mosi     = 24'd0;
        response_channel  = 3'd0;
        response_value    = 12'd0;
        miso              = 1'b0;
    end

    // SCLK 上升沿：从 DIN 采样主机命令
    always @(posedge sclk) begin
        if (cs_n == 1'b0) begin
            sclk_rising_count = sclk_rising_count + 1;
            captured_mosi = {captured_mosi[22:0], mosi};
        end
    end

    // SCLK 下降沿（或 CS 拉高）：更新 DOUT
    always @(negedge sclk or posedge cs_n) begin
        if (cs_n) begin
            miso = 1'b0;
        end
        else begin
            // 第 10 个上升沿后，D2..D0 已全部收到（5 引导零 + START + SGL/DIFF + D2D1D0）
            if (sclk_rising_count == 10) begin
                response_channel = captured_mosi[2:0];
                response_value   = value_for_channel(captured_mosi[2:0]);
            end

            // 第 12 个下降沿后送 B11，供第 13 个上升沿采样（与现有 tb 口径一致）
            if ((sclk_rising_count >= 12) && (sclk_rising_count <= 23)) begin
                miso = response_value[23 - sclk_rising_count];
            end
            else begin
                miso = 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
