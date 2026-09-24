`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// adc_farm.v · 多片 MCP3208 并行采集总控（丙线 L8，K-79 裁决后的落地）
//
// 背景（K-79，2026-09-19 实测裁决）：
//   · "三片例化三个 scanner"不够 —— 多片必须【并行】采集，否则帧预算不达标：
//       串行 24 笔 ≈ 589 µs ⇒ 1698 Hz/通道（⛔ < 2 kHz 目标）；
//       并行  8 笔 ≈ 196 µs ⇒ 5094 Hz/通道（✅ 达标）。
//   🔴🔴 2026-09-25 更正（K-128）：⭐ 上面那个 "196 µs ⇒ 5094 Hz/通道" **已作废**！
//       · ⚠️ 196 µs 是【单帧 8 通道的转换耗时】= 8 × 24.5 µs，⛔ **不是帧周期**
//       · ⭐ **真正的帧周期 = `CLK_HZ / CHANNEL_RATE_HZ`（见下方设计说明 + 第 25 行）**
//         ⇒ ⭐ 本版 `top.v` 传 `CHANNEL_RATE_HZ = 2000` ⇒ 🔴 **帧周期 = 500 µs**
//       · 📌 实测证据：`sim/evidence/tb_adc_farm.log` 判据行
//          `frame period=500000 ns` ⇒ ✅ 500 µs，⭐ 与参数算法吻合
//       · ⇒ 🔴 每通道速率 = **2000 Hz**（⛔ 不是 5094）：⭐ 转换只是 196 µs，
//         但状态机还要**空等到 500 µs** 才开下一帧（`STATE_WAIT_PERIOD`）
//       ⚠️ **本注释曾被下游 3 个模块照抄** ⇒ 🔴 是那些注释错误的【源头】
//          （`calib_span` / `event_extract` / `top.v`）—— 见 `files/20-代码/待查异常-帧周期口径错误-20260925.md`
//   · 实测三片同 enable 会【自动锁步】（通道号 0 不一致、SCLK/MOSI 完全一致）
//     ⇒ SCLK/MOSI 可【同源扇出】；但 CS/MISO 物理上每板独立四线。
//
// ⭐ 2026-09-20 扩展（K-85）：N_ADC 由"写死 3"改为**参数化可变**（支持 5/6 片）
//   · 起因：后续可能【加板】（每块左手板 1 片 ADC）⇒ 需要 >3 片
//   · ⭐ 关键结论：**并行帧时间与片数无关** —— 所有片同时扫同一通道号，
//     转换耗时恒为 `8 笔 × 24.5 µs ≈ 196 µs`
//     🔴 但【帧周期】由 `CHANNEL_RATE_HZ` 决定，⛔ 与"196 µs"无关（⭐ 见 `K-128`）：
//        🔴 本版 = **500 µs**（2000 Hz）⇒ ⛔ 不是"196 µs ⇒ 5094 Hz/通道"
//     ⇒ ⭐ 加片【不影响】帧周期这件事仍然成立（⭐ 结论方向不变，⛔ 只是数错）
//   · 引脚代价 = 每片 +2（`CS` + `MISO`）⇒ 6 片共 11 脚（Dock 有 80 可用脚）
//   · 端口：新增通用 `sample_data_packed[N_ADC*12-1:0]`；
//     ⚠️ `sample_data0/1/2` **保留为兼容别名**（⛔ 不破坏既有 tb 与集成）
//
// 设计（本模块）：
//   · 内部只跑【一个】scanner 主控（片 0），所有片 CS/SCLK/MOSI 由其【同源扇出】；
//   · 片 1..N-1 用【影子反串行器】在同样的 SCLK 上升沿采各自 MISO，锁步取 12 位；
//   · 每路 MISO 各自经 sync_input 2 级同步（K-62）；
//   · 所有片在同一拍 sample_valid ⇒ 一次 commit 原子提交 N×8 通道样本；
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

    // ---- 多片 MCP3208 物理接口（每板独立四线）------------------------------
    // ⭐ 2026-09-20 扩展：N_ADC 由 3 → 可变（支持 5/6 片，为"后续加板"预留）
    //    · SCLK/MOSI 全部同源扇出（只用片 0 的）；CS/MISO 每片独立
    //   · ⭐ 并行帧时间与片数【无关】：8 笔转换 = 8 × 24.5 µs ≈ 196 µs
//     🔴 2026-09-25 更正（`K-128`）：⭐ 这 196 µs 是【转换耗时】，
//        🔴 **帧周期另算 = `CLK_HZ / CHANNEL_RATE_HZ` = 500 µs（本版 2000 Hz）**
    //    · 引脚代价 = 每片 +2（CS + MISO）⇒ 6 片共 11 脚（Dock 有 80 可用脚）
    output wire [N_ADC-1:0] adc_cs_n,
    output wire [N_ADC-1:0] adc_sclk,
    output wire [N_ADC-1:0] adc_mosi,
    input  wire [N_ADC-1:0] adc_miso,

    // ---- 采样汇总输出（多片锁步，同一拍有效）-------------------------------
    output wire        sample_valid,
    output wire [2:0]  sample_ch,
    // ⭐ 通用接口：所有片的 12 bit 样本打包（片 i = sample_data_packed[i*12 +: 12]）
    output wire [N_ADC*12-1:0] sample_data_packed,
    // ⚠️ 兼容端口（片 0/1/2）：保留是为了 ⛔ 不破坏既有 tb 与集成；
    //    N_ADC > 3 时请改用上面的 packed 端口（这两个只是前 3 片的别名）
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

    // 同源扇出：所有片的 CS/SCLK/MOSI 直接等于片 0（K-79：多片锁步、0 不一致）
    // ⭐ 2026-09-20：由"写死 1/2"改为 generate 循环 ⇒ N_ADC 可变（3/5/6 均可）
    generate
        for (g = 1; g < N_ADC; g = g + 1) begin : gen_fanout
            assign adc_cs_n[g] = adc_cs_n[0];
            assign adc_sclk[g] = adc_sclk[0];
            assign adc_mosi[g] = adc_mosi[0];
        end
    endgenerate

    // ── 影子反串行器：在 SCLK 上升沿采各片 MISO（与 driver mode0 一致）─────
    wire cs_active = (adc_cs_n[0] == 1'b0);

    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);

    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);

    // ⭐ 2026-09-20：影子移位寄存器改为 [N_ADC-1:1] 的二维数组 ⇒ 任意片数
    //    （片 0 的数据由 scanner 自己给出，不需要影子）
    reg [23:0] miso_shift [1:N_ADC-1];

    integer gi;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= 24'd0;
        end else if (cs_fall) begin
            // 新事务开始：清零所有影子移位寄存器
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= 24'd0;
        end else if (cs_active && sclk_rise) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= {miso_shift[gi][22:0], miso_sync[gi]};
        end
    end

    // ── 样本汇总：片 0 透传 scanner，片 1..N-1 用影子移位 ──────────────────
    // ⚠️ 时序：scanner 的 sample_valid/sample_data/sample_ch 在 driver done 后同拍输出，
    //   而影子反串行器在最后一个 SCLK 上升沿就已收满 24 位（早于 done 数个 HALF_DIV 拍），
    //   故所有片数据在同一拍自然对齐，无需额外寄存器延迟。
    assign sample_valid = s0_valid;
    assign sample_ch    = s0_ch;

    // ⭐ 打包输出（通用）：片 0 用 scanner 数据，其余用影子
    assign sample_data_packed[11:0] = s0_data;
    generate
        for (g = 1; g < N_ADC; g = g + 1) begin : gen_pack
            assign sample_data_packed[g*12 +: 12] = miso_shift[g][11:0];
        end
    endgenerate

    // ⚠️ 兼容别名（片 0/1/2）—— 让既有 tb 与集成不改一行
    // ⭐ K-89 修复（2026-09-20）：原来是**无条件** assign：
    //      sample_data0/1/2 = sample_data_packed[11:0]/[23:12]/[35:24]
    //    但 packed 宽度是 N_ADC*12 ⇒ N_ADC<3 时**索引越界读出 X**
    //    （实测 N_ADC=2：sample_data2 = xxx）。
    //    ⇒ 改为 generate 保护：**不存在的片接 12'd0**，⛔ 不越界。
    wire [35:0] sample_data_alias;      // 固定 3 片宽（片 0/1/2）

    generate
        for (g = 0; g < 3; g = g + 1) begin : gen_alias
            if (g < N_ADC)
                assign sample_data_alias[g*12 +: 12] = sample_data_packed[g*12 +: 12];
            else
                assign sample_data_alias[g*12 +: 12] = 12'd0;   // ⛔ 不越界
        end
    endgenerate

    assign sample_data0 = sample_data_alias[11:0];
    assign sample_data1 = sample_data_alias[23:12];
    assign sample_data2 = sample_data_alias[35:24];

    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;

endmodule

`default_nettype wire
