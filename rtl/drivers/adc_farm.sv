`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// adc_farm.v · 三片 MCP3208 并行采集总控（丙线 L8，K-79 裁决后的落地）
//
// 背景（K-79，2026-09-19 实测裁决）：
//   · "三片例化三个 scanner"不够 —— 三片必须【并行】采集，否则帧预算不达标：
//       串行 24 笔 ≈ 589 µs ⇒ 1698 Hz/通道（⛔ < 2 kHz 目标）；
//       并行  8 笔 ≈ 196 µs ⇒ 5094 Hz/通道（✅ 达标）。
//   · 实测三片同 enable 会【自动锁步】（通道号 0 不一致、SCLK/MOSI 完全一致）
//     ⇒ SCLK/MOSI 可【同源扇出】；但 CS/MISO 物理上每板独立四线。
//
// 设计（本模块）：
//   · 内部只跑【一个】scanner 主控（片 0），三片 CS/SCLK/MOSI 由其【同源扇出】；
//   · 片 1/2 用【影子反串行器】在同样的 SCLK 上升沿采各自 MISO，锁步取 12 位；
//   · 三路 MISO 各自经 sync_input 2 级同步（K-62）；
//   · 三片在同一拍 sample_valid ⇒ 一次 commit 原子提交 3×8=24 通道样本；
//   · 帧周期 = CLK_HZ / CHANNEL_RATE_HZ（默认 2 kHz ⇒ 0.5 ms，K-07/K-79 新口径）。
//
// ⛔ 纪律：
//   · 不用 PLL、不引第二时钟域；SCLK 只是外部协议信号，绝不当内部时钟；
//   · 灯的移位 CLK ≠ ADC 的 SPI SCK（K-13）—— 本模块只出 ADC 的 SCK；
//   · MISO 不靠 FPGA 内部上拉拉高（K-62），高电平由从机推挽提供。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module adc_farm #(
    parameter integer N_ADC          = 3,
    parameter integer CLK_HZ         = 50_000_000,
    parameter integer SCLK_HZ        = 1_000_000,
    parameter integer CHANNEL_RATE_HZ = 2_000
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,

    // ---- 三片 MCP3208 物理接口（每板独立四线）------------------------------
    output wire [N_ADC-1:0] adc_cs_n,
    output wire [N_ADC-1:0] adc_sclk,
    output wire [N_ADC-1:0] adc_mosi,
    input  wire [N_ADC-1:0] adc_miso,

    // ---- 采样汇总输出（三片锁步，同一拍有效）-------------------------------
    output wire        sample_valid,
    output wire [2:0]  sample_ch,
    output wire [11:0] sample_data0,
    output wire [11:0] sample_data1,
    output wire [11:0] sample_data2,

    // ---- 帧完成 ------------------------------------------------------------
    output wire        frame_done,
    output wire [N_ADC-1:0] fault
);

    // ── 三路 MISO 同步（K-62：异步输入必须 2 级同步）───────────────────────
    wire [N_ADC-1:0] miso_sync;
    genvar g;
    generate
        for (g = 0; g < N_ADC; g = g + 1) begin : gen_miso_sync
            sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b0)) u_sync (
                .clk(clk), .rst_n(rst_n),
                .async_in(adc_miso[g]), .sync_out(miso_sync[g])
            );
        end
    endgenerate

    // ── 片 0 主控 scanner：唯一驱动 CS/SCLK/MOSI/channel/valid ──────────────
    wire [11:0] s0_data;
    wire [2:0]  s0_ch;
    wire        s0_valid;

    mcp3208_scanner #(
        .CLK_HZ(CLK_HZ), .SCLK_HZ(SCLK_HZ), .CHANNEL_RATE_HZ(CHANNEL_RATE_HZ)
    ) u_scan0 (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .sample_channel(s0_ch), .sample_data(s0_data), .sample_valid(s0_valid),
        .frame_done(frame_done),
        .adc_cs_n(adc_cs_n[0]), .adc_sclk(adc_sclk[0]),
        .adc_mosi(adc_mosi[0]), .adc_miso(miso_sync[0])
    );

    // 同源扇出：片 1/2 的 CS/SCLK/MOSI 直接等于片 0（K-79：三片锁步、0 不一致）
    assign adc_cs_n[1]  = adc_cs_n[0];
    assign adc_cs_n[2]  = adc_cs_n[0];
    assign adc_sclk[1]  = adc_sclk[0];
    assign adc_sclk[2]  = adc_sclk[0];
    assign adc_mosi[1]  = adc_mosi[0];
    assign adc_mosi[2]  = adc_mosi[0];

    // ── 影子反串行器：在 SCLK 上升沿采片 1/2 的 MISO（与 driver mode0 一致）─
    wire cs_active = (adc_cs_n[0] == 1'b0);

    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);

    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);

    reg [23:0] miso1_shift;
    reg [23:0] miso2_shift;

    always @(posedge clk) begin
        if (!rst_n) begin
            miso1_shift <= 24'd0;
            miso2_shift <= 24'd0;
        end else if (cs_fall) begin
            // 新事务开始：清零移位寄存器
            miso1_shift <= 24'd0;
            miso2_shift <= 24'd0;
        end else if (cs_active && sclk_rise) begin
            miso1_shift <= {miso1_shift[22:0], miso_sync[1]};
            miso2_shift <= {miso2_shift[22:0], miso_sync[2]};
        end
    end

    // ── 样本汇总：直接透传片 0 的 valid/ch/data，片 1/2 用影子移位 ──────────
    // ⚠️ 时序：scanner 的 sample_valid/sample_data/sample_ch 在 driver done 后同拍输出，
    //   而影子反串行器在最后一个 SCLK 上升沿就已收满 24 位（早于 done 数个 HALF_DIV 拍），
    //   故三片数据在同一拍自然对齐，无需额外寄存器延迟。
    assign sample_valid = s0_valid;
    assign sample_ch    = s0_ch;
    assign sample_data0 = s0_data;
    assign sample_data1 = miso1_shift[11:0];
    assign sample_data2 = miso2_shift[11:0];

    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;

endmodule

`default_nettype wire
