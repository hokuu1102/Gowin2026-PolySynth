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
//   · ⭐ **本模型对齐 `mcp3208_driver` 的采样点**：
//       第 12 个 SCLK 下降沿起逐位回结果（B11 先出），
//       ⇒ ⭐ **第 13 个上升沿采到 B11** ⇒ ⭐ 收满 24 位后 `rx_shift[11:0]` 正是 B11..B0 ✅
//     🔴 **2026-09-23 更正**：本行原写 *"第 5~16 个 SCLK 下降沿"*，
//        与代码里的 `>= 12 && <= 23` **不一致**（⚠️ 旧版遗留，🔴 会误导读者）。
//        ⭐ 已按**代码的真实行为**改写；⭐ 实测 8 个通道逐一正确（见 `tb_mcp3208_model`）。
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
    output reg        miso,

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 可选【逐通道覆盖】接口（2026-09-23 新增，⭐ 用于端到端按键测试）
    //
    //   🔴 **为什么需要**：⭐ 原模型的取值公式是 `IDVAL + ch`
    //      ⇒ ⚠️ **整片只能线性变化**，无法表达"**某一个轴被按下、其它不动**"。
    //      ⚠️ 而"按某个键 ⇒ 出声"的端到端验证**恰恰需要这个能力**。
    //
    //   ⭐ **设计原则：⛔ 不破坏任何现有用法**
    //      · 新端口是 **`input`（可选）** —— ⚠️ 现有 tb（`tb_adc_farm` /
    //        `tb_mcp3208_model`）**不接它** ⇒ ⭐ 悬空 ⇒ 走下面的默认值
    //      · `ovr_en_i` 为 0（或悬空为 0/x）时 ⇒ ⭐ **行为与原来【完全一致】**
    //      ⇒ ⭐ 现有 tb 的结果**不受影响**（⭐ 可回归验证）。
    //
    //   ⭐ **用法**（⭐ 端到端 tb）：
    //      · `ovr_en_i = 1`、`ovr_val_i = 12'h4D9` ⇒ ⭐ 本片所有通道都返回该值
    //        （⚠️ 仍是"整片"，⭐ 因为 `adc_farm` 锁步扫同一通道）
    //      · `ovr_en_i = 0` ⇒ ⭐ 回落到 `IDVAL + ch`（⭐ 原行为）
    //
    //   📌 **为什么不做成【真·逐通道数组】**：⭐ Verilog-2001 不支持数组输入端口
    //      （⚠️ SV 可以，但 `K-91` 要求全项目按 Verilog-2001 编译）⇒
    //      ⭐ 而端到端测试的真实需要就是"**整片切换按下/松开**"
    //      （⭐ 因为两片锁步、且我要验的是【某个轴】）⇒ ⭐ 单值覆盖已够用。
    // ═══════════════════════════════════════════════════════════════════════
    input  wire       ovr_en_i,          // ⭐ 1 = 启用覆盖（⚠️ 悬空 ⇒ 不启用）
    input  wire [11:0] ovr_val_i         // ⭐ 覆盖值（⭐ 所有通道都返回它）
);

    integer sclk_rising_count;
    reg [23:0] captured_mosi;
    reg [2:0]  response_channel;
    reg [11:0] response_value;

    // 每片返回的样本值 = IDVAL 的低 9 位拼接 + 通道号（确定性、可逐位比对）
    // 这样三片用不同 IDVAL，样本值各不相同，能验证"三片 MISO 没串线"。
    //
    //   ⭐ 2026-09-23：增加 `ovr_en_i` 分支（⭐ 见上方端口说明）。
    //      ⚠️ `ovr_en_i` 悬空时为 `z`/`x` ⇒ ⭐ 三元判断为假 ⇒ ⭐ 走原路径 ✅
    function automatic [11:0] value_for_channel(input [2:0] ch);
        begin
            //   ⚠️ 用 `=== 1'b1`（⭐ 全等）⇒ ⭐ 悬空的 `x`/`z` **不会**误判为启用
            if (ovr_en_i === 1'b1)
                value_for_channel = ovr_val_i;
            else
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
