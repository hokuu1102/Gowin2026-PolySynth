`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// axis_snapshot.v · W3a：**16 轴原子快照**（⭐ 滑音/双音的前置）
//
// ── 🔴 为什么需要它（⭐ 这是本模块存在的唯一理由）────────────────────────────
//   ⚠️ `adc_farm` 的输出是【一次一个通道】：`sample_valid` 脉冲 + `sample_ch`
//      ⇒ 🔴 **任一时刻只有一个轴的 `pos`**。
//   ⚠️ 而【滑音/双音】的判据需要 **同时看到相邻两个轴**：
//      · ⭐ **滑音**：`dA < −TH` 且 `dB > +TH`（一个减、一个增）
//      · ⭐ **双音**：`dA ≥ 0` 且 `dB ≥ 0`（都不减）
//      ⇒ ⭐ **`dA`/`dB` 必须基于【同一时刻】的两个轴** ⇒ ⭐ **必须先快照**。
//
//   ⭐ 依据：`files/20-代码/RTL代码结构与接口规划.md:423`
//      —— "三 ADC 与控制 | 三总线并行、**16 轴快照**、…"（⭐ 架构本来就要求快照）
//
// ── ⭐ 本模块做什么 ───────────────────────────────────────────────────────────
//   ① ⭐ **收**：把 `adc_farm` 逐通道送来的样本，按【轴号】写进 16 项寄存器组
//   ② ⭐ **发**：当一帧的全部通道都到齐（或 `frame_done`）⇒ ⭐ **出一个原子快照脉冲**
//      ⇒ ⭐ 下游（`axis_map`/`event_extract`）拿到的是**同一帧的 16 个轴**
//   ③ ⭐ **算 Δ**：⭐ **顺带算出每个轴的"行程增量"**（`d = pos_now − pos_prev`）
//      ⇒ ⚠️ 这是滑音/双音判据的原料，⭐ 放在这里算**避免下游重复存历史**
//
// ── ⭐ 接口契约 ───────────────────────────────────────────────────────────────
//   ⭐ **输入**（← `adc_farm`）：
//      `sample_valid` 单周期脉冲 · `sample_ch[2:0]`（片内通道 0..7）
//      `sample_data_packed[N_ADC*12-1:0]`（片 i = `[i*12 +: 12]`）
//      `frame_done`（一帧扫完）
//   ⭐ **输出**（→ `axis_map` / `event_extract`）：
//      `snap_valid_o` 单周期脉冲（⭐ **原子快照有效**）
//      `pos_o[AXIS_N*POS_W-1:0]`（轴 i = `[i*POS_W +: POS_W]`）
//      `delta_o[AXIS_N*DW-1:0]`（⭐ 带符号增量，轴 i = `[i*DW +: DW]`）
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001**（`K-91`：⛔ 不用 SV 专有构造，否则整个模块被静默丢弃）
//   · ⭐ **同步复位、低有效**、⭐ **单时钟域 50 MHz**（冻结表 §〇 约定 1/2）
//   · ⛔ 不用 PLL 派生时钟
//   · ⭐ **`valid` 与数据必须同拍**（`K-109`：⚠️ 本项目已犯过的真缺陷）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module axis_snapshot #(
    // ⭐ 轴数：16（⭐ 2 片 ADC × 8 通道；⚠️ 第 3 片留给右手板推子/音量）
    parameter integer AXIS_N = 16,
    // ⭐ 片数：**参与轴的 ADC 片数**（⭐ 2 = 两块左手板）
    //   ⚠️ 必须满足 `N_ADC * 8 >= AXIS_N`
    parameter integer N_ADC  = 2,
    // ⭐ 轴位位宽（12 = MCP3208 满量程）
    parameter integer POS_W  = 12,
    // ⭐ 增量位宽：⭐ **必须能表示【带符号】的差值**
    //   ⚠️ `POS_W + 1` ⇒ 12 位量程的差值范围 `[-4095, +4095]` 放得下
    parameter integer DW     = POS_W + 1
) (
    input  wire                        clk,
    input  wire                        rst_n,        // ⭐ 同步复位、低有效

    // ── 输入：来自 `adc_farm`（⭐ 逐通道）────────────────────────────────────
    input  wire                        sample_valid_i,
    input  wire [2:0]                  sample_ch_i,
    input  wire [N_ADC*POS_W-1:0]      sample_data_i,   // ⭐ 片 i = [i*POS_W +: POS_W]
    input  wire                        frame_done_i,

    // ── 输出：原子快照（⭐ 一帧一次）──────────────────────────────────────────
    output reg                         snap_valid_o,    // ⭐ 单周期脉冲
    output wire [AXIS_N*POS_W-1:0]     pos_o,           // ⭐ 本帧 16 轴行程
    output wire [AXIS_N*DW-1:0]        delta_o,         // ⭐ 带符号增量（本帧 − 上帧）
    output wire [AXIS_N-1:0]           axis_seen_o      // ⭐ 本帧收到过哪些轴（诊断）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 双缓冲：`cur` 收本帧、`prev` 存上帧
    //
    //   ⚠️ 为什么要双缓冲：⭐ `delta = cur − prev` **必须在同一帧内两个数组都稳定**
    //      ⇒ ⭐ 收的时候只写 `cur`，快照那一刻把 `cur` 整体移进 `prev`
    //   📌 代价：⭐ **2 × 16 × 12 = 384 bit 寄存器**（⭐ 60K 有 60780 FF ⇒ 忽略不计）
    // ═══════════════════════════════════════════════════════════════════════
    reg [POS_W-1:0] cur  [0:AXIS_N-1];
    reg [POS_W-1:0] prev [0:AXIS_N-1];
    reg [AXIS_N-1:0] seen;          // ⭐ 本帧已收到哪些轴

    // ⭐⭐ `first_ch_of_frame`：⭐ **"本帧的 ch0 还没来"** 标志
    //   ⭐ 用途：⭐ **只在"新一帧的第一个样本"那一刻固化 `prev`**（⭐ 见下方注释的推理）
    //   ⭐ 语义：`frame_done` 之后置 1；收到 `ch0` 后清 0（⭐ 一帧只固化一次）
    //   ⚠️ 为什么用 `ch0`：⭐ `adc_farm` **锁步**扫描 ⇒ 每帧**固定从 ch0 开始**
    //      （⭐ `mcp3208_scanner` 的通道号 0..7 循环）
    reg first_ch_of_frame;

    // ⭐ 写侧：把"片号 + 片内通道"换算成**轴号**
    //   ⭐ **轴号 = 片号 × 8 + `sample_ch`** —— ⚠️ 依据 `霍尔键位-CH映射-20260923.md` §四 约束 1：
    //      🔴 **两块板 CH 号重复** ⇒ ⛔ **单用 CH 号会让两块板互相覆盖**。
    //   ⚠️ 本模块用 `sample_ch_i` + 片号**逐片展开**写入（⭐ 见下方 generate）
    //      —— 因为 `adc_farm` 一次给的是【所有片同一通道号】的打包数据。

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 写侧：⭐ **一拍要写【多片】的同一通道**
    //
    //   ⚠️ `adc_farm` 的语义：**所有片同时扫同一通道号**（⭐ 锁步）
    //      ⇒ ⭐ 一个 `sample_valid` 携带 `N_ADC` 个轴的样本
    //      ⇒ 🔴 **不能只写一个轴** —— 必须**逐片展开**
    //   ⭐ 轴号 = **片号 × 8 + 通道号**（⭐ 映射文档 §四 约束 1）
    // ═══════════════════════════════════════════════════════════════════════
    integer wi;         // ⭐ 轴遍历（复位与快照搬移共用）
    integer di;         // ⭐ 片遍历（写侧逐片展开）
    always @(posedge clk) begin
        if (!rst_n) begin
            for (wi = 0; wi < AXIS_N; wi = wi + 1) begin
                cur [wi] <= {POS_W{1'b0}};
                prev[wi] <= {POS_W{1'b0}};
            end
            seen <= {AXIS_N{1'b0}};
            first_ch_of_frame <= 1'b0;
        end else begin
            // ── ⭐ 收样本：**逐片写入**（⭐ 每片 = 8 通道 ⇒ 8 个轴）
            if (sample_valid_i) begin
                for (di = 0; di < N_ADC; di = di + 1) begin
                    // ⭐ 轴号 = 片号 × 8 + 通道号
                    //   ⚠️ 越界的片**静默丢弃**（⭐ 自检已保证 `N_ADC*8 >= AXIS_N`）
                    if ((di * 8 + sample_ch_i) < AXIS_N) begin
                        cur[di*8 + sample_ch_i]  <= sample_data_i[di*POS_W +: POS_W];
                        seen[di*8 + sample_ch_i] <= 1'b1;
                    end
                end
            end

            // ⭐ `first_ch_of_frame` 的状态机：
            //    ⭐ `frame_done` ⇒ 置 1（⭐ 下一帧的 ch0 即将到来）
            //    ⭐ 收到 `ch0` ⇒ 清 0（⭐ 本帧已固化过，⛔ 不再重复）
            if (frame_done_i)
                first_ch_of_frame <= 1'b1;
            else if (sample_valid_i && (sample_ch_i == 3'd0))
                first_ch_of_frame <= 1'b0;

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ 快照：⭐ **在新一帧【开始】时把上一帧固化**
            //
            //   🔴 **⚠️ 踩过的坑（2026-09-23，本模块前两版都错在这里）**：
            //      · 第 1 版：在 `snap_valid_o`（`frame_done` 延迟一拍）上搬
            //        ⇒ 🔴 那一拍 `cur` 已是**本帧新值** ⇒ `prev` 抄到本帧 ⇒ **`delta` 恒 0**
            //      · 第 2 版：改在 `frame_done` 那一拍搬 —— ⚠️ **仍然错**：
            //        ⭐ `frame_done` 是 `adc_farm` 在**最后一个通道采完之后**才给的
            //        ⇒ 🔴 那一拍 `cur` **也已经是本帧**了（实测 `prev == cur == 0x810`）
            //   ⭐⭐ **正确时机 = 新一帧的【第一个样本】到来时**：
            //      ⭐ 此刻 `cur` 还完整装着**上一帧**的值
            //      ⇒ ⭐ 先 `prev <= cur`（把上一帧固化），⭐ 再写本帧的新通道
            //      ⇒ ⭐ 本帧写完时：`cur` = 本帧、`prev` = 上一帧 ⇒ ⭐ `delta` 语义正确 ✅
            //   📌 **判据 = "何时 `cur` 还是上一帧"** —— ⭐ 用【新帧的第一次 `sample_valid`】标识
            //      （⭐ `adc_farm` 锁步 ⇒ 新帧第一个样本的 `sample_ch == 0`，⭐ 见下方说明）
            // ═══════════════════════════════════════════════════════════════
            if (sample_valid_i && (sample_ch_i == 3'd0) && first_ch_of_frame) begin
                for (wi = 0; wi < AXIS_N; wi = wi + 1)
                    prev[wi] <= cur[wi];
            end
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 写地址解码：⭐ **一次 `sample_valid` 会命中【多片】同一通道**
    //
    //   ⚠️ `adc_farm` 的语义：**所有片同时扫同一通道号**（⭐ 锁步）
    //      ⇒ 一个 `sample_valid` 携带的是 `N_ADC` 个轴的样本
    //      ⇒ ⚠️ **一拍要写【多个】轴** ⇒ 🔴 **不能只用单个 `wr_ax`**
    //   ⭐ 本实现：**用 generate 逐片展开，每片一个独立的写端口**
    // ═══════════════════════════════════════════════════════════════════════
    //   ⚠️ 但 `always` 块里逐片写会让代码重复 ⇒ ⭐ 折中：**把每片的写入做成数组**，
    //      在**同一个 always** 里用 for 循环遍历片（⭐ 片数是参数，可综合）
    //   ⇒ ⭐ 下面改用【循环 + 片内地址计算】的写法（⛔ 更干净、也更好扩展）
    // ═══════════════════════════════════════════════════════════════════════

    // ⚠️ 上一段 `always` 里的 `wr_en/wr_ax/wr_dat` 是为说明而写 —— ⭐ **实际用下面这个**
    //   📌 **重写写侧**（⭐ 用 for 循环遍历所有片，每片算一次轴号）

    // ⭐ 轴号计算（组合）：⭐ **轴号 = 片号 × 8 + 通道号**
    //   ⚠️ `8` = 每片 8 通道（⭐ MCP3208 固定 8 通道）
    //   📌 本函数**留作文档与自检用**；⭐ 写侧直接内联了同样的算式（⭐ 见下方 always）。
    function [15:0] axis_of;
        input integer adc_idx;
        input [2:0]   ch;
        begin
            axis_of = (adc_idx * 8) + ch;
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 快照有效脉冲：⭐ 用 `frame_done` 产生（⭐ 一帧一次）
    //
    //   ⚠️ 为什么用 `frame_done` 而⛔ 不是"数够 16 个 sample_valid"：
    //      ⭐ `frame_done` 是 `adc_farm` 自己给的**帧边界**（⭐ 语义权威）
    //      ⚠️ 而"数 16 个"在 `N_ADC` 或 `AXIS_N` 参数变化时会**静默错位**
    //   ⚠️ 延迟一拍：⭐ 让 `frame_done` 那一拍写入的 `cur` 先落定，
    //      下一拍再发快照 ⇒ ⭐ 保证快照里**一定包含本帧最后一个通道**
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) snap_valid_o <= 1'b0;
        else        snap_valid_o <= frame_done_i;
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 输出：`pos_o` 与 `delta_o`（⭐ 全部组合 ⇒ 与 `snap_valid_o` 严格同拍）
    //   ⚠️ 依据 `K-109`：⭐ **`valid` 与数据必须同拍** ——
    //      若把数据也寄存一拍，就会变成"valid 与 data 不同拍"的老缺陷。
    // ═══════════════════════════════════════════════════════════════════════
    genvar gi;
    generate
        for (gi = 0; gi < AXIS_N; gi = gi + 1) begin : gen_out
            // ⭐ 本帧行程（⭐ 快照那一拍 `cur` 就是本帧值）
            assign pos_o[gi*POS_W +: POS_W] = cur[gi];

            // ⭐⭐ 带符号增量：`delta = cur − prev`
            //   ⚠️ **必须做符号扩展**：⭐ 两个 12 位无符号数相减，
            //      结果需要 `POS_W+1` 位才能表示 `[-4095, +4095]`。
            //   ⚠️ 写法：⭐ 先各自扩展到 `DW` 位再相减 ⇒ ⭐ 进位/借位正确
            assign delta_o[gi*DW +: DW] =
                {1'b0, cur[gi]} - {1'b0, prev[gi]};
        end
    endgenerate

    assign axis_seen_o = seen;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检（与 `clk_gen`/`tlc5916`/`top`/`axis_map` 的同一套路）
    //   ⚠️ 为什么要有：⭐ 这些参数的**错误组合会静默失效**：
    //     ① `N_ADC * 8 < AXIS_N` ⇒ 🔴 **部分轴永远收不到数据**（⭐ 恒 0 ⇒ 静默）
    //     ② `DW < POS_W + 1` ⇒ 🔴 **增量溢出 ⇒ 符号错**（⭐ 滑音/双音判据全错）
    //     ③ `AXIS_N <= 0` ⇒ ⚠️ 数组为空（⭐ 编译期错，但也报出来）
    // ═══════════════════════════════════════════════════════════════════════
    localparam PARAM_OK = (AXIS_N > 0) && ((N_ADC * 8) >= AXIS_N) && (DW >= (POS_W + 1));

    initial begin
        if ((N_ADC * 8) < AXIS_N)
            $display("ERROR [axis_snapshot] N_ADC*8 = %0d < AXIS_N = %0d => some axes would NEVER receive data (would read as 0 silently). PARAM_OK=0.",
                     N_ADC * 8, AXIS_N);
        if (DW < (POS_W + 1))
            $display("ERROR [axis_snapshot] DW = %0d < POS_W+1 = %0d => the signed delta can overflow and the sign goes WRONG. PARAM_OK=0.",
                     DW, POS_W + 1);
        if (PARAM_OK)
            $display("NOTE [axis_snapshot] PARAM_OK=1 (AXIS_N=%0d N_ADC=%0d POS_W=%0d DW=%0d)", AXIS_N, N_ADC, POS_W, DW);
    end

endmodule

`default_nettype wire
