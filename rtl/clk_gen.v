// ─────────────────────────────────────────────────────────────────────────────
// clk_gen.v · L1 时基（⛔ 不用 PLL、无门控时钟、全设计单时钟域）
//
// 分频链（唯一无歧义写法，见 files/20-代码/W3接口冻结表.md §二）：
//     clk_sys 50 MHz
//       ÷4   → MCLK  12.5 MHz   （= 256 × fs）
//       ÷16  → BCLK   3.125 MHz （= 64 × fs；I2S 位时钟）
//       ÷1024→ LRCLK 48.828125 kHz（= fs；= BCLK ÷ 64）
//
// ⭐ 设计要点
//   1. **只用"节拍使能"（clock-enable），⛔ 不派生新时钟** —— 板级经验：
//      Gowin 上用 PLL/派生时钟做全设计时钟 = 综合通过、板子全死。
//   2. **所有节拍都从同一个帧计数器派生** ⇒ 相位关系天然确定，不需要任何跨域同步。
//   3. `clk_sys` 与 `fs` 是整数关系（50 MHz ÷ 1024 = 48828.125 Hz）⇒ **不需要 PLL**。
//   4. `bclk_en` 是"每 16 个 clk 一个周期"的使能，`i2s_tx` 用它当**移位时钟**。
//
// ⚠️ `LRCK_POL`：本模块输出 **低 = 左声道**（标准 I2S / Philips）。
//    板载 DAC = PT8211-S，官方例程明确"HP_WS 低电平对应左声道"（K-24）。
//
// 参数约束：`CLK_PER_SAMPLE` 与 `BCLK_DIV` 都必须是 **2 的幂**（本设计里是 1024 与 16），
//          这样全部用位选实现，省比较器；换值时必须同时改 `tb/clk_gen/tb_clk_gen.sv` 的期望值。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module clk_gen #(
    parameter integer CLK_PER_SAMPLE = 1024,   // fs 分频：50 MHz / 1024 = 48.828125 kHz
    parameter integer BCLK_DIV       = 16,     // BCLK 分频：50 MHz / 16 = 3.125 MHz
    parameter integer MCLK_DIV       = 4       // MCLK 分频：50 MHz / 4  = 12.5 MHz
) (
    input  wire clk,          // 50 MHz 系统时钟（Dock: V22）
    input  wire rst_n,        // 同步复位、低有效

    output reg  tick_audio,   // 音频帧起点：每 CLK_PER_SAMPLE 个 clk 一个周期（= fs）
    output reg  mclk_en,      // MCLK 使能：每 MCLK_DIV 个 clk 一个周期
    output reg  bclk_en,      // BCLK 使能：每 BCLK_DIV 个 clk 一个周期（= 一个 I2S 数据位）
    output reg  bclk_half_en, // BCLK 半周期使能：每 BCLK_DIV/2 个 clk 一个周期（HP_BCK 翻转用）
    output reg  lrclk,        // 帧时钟电平：低 = 左声道（标准 I2S）
    output reg  frame_start   // 本周期是"帧内第 0 个 BCLK"（给 i2s_tx 对齐用）
);

    // ── 帧内 clk 计数 ────────────────────────────────────────────────
    // ⚠️ **同步复位**（`W3接口冻结表.md` §〇 约定 2：全设计统一同步复位、低有效）
    //    ⇒ ⛔ 不要写成 `always @(posedge clk or negedge rst_n)`（那是异步复位，与约定不符）
    localparam integer CW = $clog2(CLK_PER_SAMPLE);   // 1024 → 10

    // ⭐⭐ 参数合法性（R-17，2026-09-17 加）—— 本模块把 `$clog2` 当**移位量/位选**用，
    //    只在"参数是 2 的幂"时才等于真除法/真取模。⛔ 否则会**静默给错频率**：
    //      · `BCLK_DIV=12` ⇒ 实际仍按 ÷16 走（`cnt[3:0]`），BCLK 比预期低 33%
    //      · `BCLK_DIV=2`  ⇒ `$clog2(BCLK_DIV/2)=0` ⇒ 零宽位选（`cnt[-1:0]`）
    //      · `CLK_PER_SAMPLE` 非 2 的幂 ⇒ `cnt == CLK_PER_SAMPLE-1` 仍对，但 `bpos` 的
    //        右移截断会让 `SLOT_BCK` 与实际时隙对不上
    //    ⇒ 用 `initial` 在**仿真启动时**明确告警（⛔ 综合工具忽略 `initial`，所以这只是仿真侧防线；
    //      上板前必须靠人检查 —— 已写进 `files/20-代码/工具链与Gowin工程.md` 的验收清单）。
    function integer is_pow2;
        input integer v;
        begin
            is_pow2 = (v > 0) && ((v & (v - 1)) == 0);
        end
    endfunction

    localparam PARAM_OK = is_pow2(CLK_PER_SAMPLE) && is_pow2(BCLK_DIV) && is_pow2(MCLK_DIV)
                          && (BCLK_DIV >= 2) && (MCLK_DIV >= 2)
                          && (CLK_PER_SAMPLE >= BCLK_DIV);

    initial begin
        if (!PARAM_OK)
            $display("ERROR [clk_gen] 参数必须全为 2 的幂且 BCLK_DIV/MCLK_DIV >= 2、CLK_PER_SAMPLE >= BCLK_DIV：CLK_PER_SAMPLE=%0d BCLK_DIV=%0d MCLK_DIV=%0d（当前实现把 $clog2 当移位量用 ⇒ 非 2 的幂会**静默给错频率**）",
                     CLK_PER_SAMPLE, BCLK_DIV, MCLK_DIV);
        // ⭐ R-05：跨模块一致性 —— `i2s_tx` 的每声道时隙数必须与这里算出来的一致。
        //    真实约束：`CLK_PER_SAMPLE == BCLK_DIV × SLOT_BITS × 2`
        //    （本模块只能检查"能被 2×BCLK_DIV 整除"，SLOT_BITS 由调用方在 tb/顶层核对）。
        if ((CLK_PER_SAMPLE % (BCLK_DIV * 2)) != 0)
            $display("ERROR [clk_gen] CLK_PER_SAMPLE(%0d) 不能被 2×BCLK_DIV(%0d) 整除 ⇒ 左右时隙不等长",
                     CLK_PER_SAMPLE, BCLK_DIV * 2);
    end

    reg [CW-1:0] cnt;
    always @(posedge clk) begin
        if (!rst_n)                         cnt <= {CW{1'b0}};
        else if (cnt == CLK_PER_SAMPLE - 1) cnt <= {CW{1'b0}};
        else                                cnt <= cnt + 1'b1;
    end

    // ── 帧内 BCLK 序号（0 .. CLK_PER_SAMPLE/BCLK_DIV-1 = 0..63）───────
    localparam integer BW = $clog2(CLK_PER_SAMPLE / BCLK_DIV);  // 64 → 6
    localparam integer SLOT_BCK = (CLK_PER_SAMPLE / BCLK_DIV) / 2;  // 每声道 BCK 数 = 32

    wire [BW-1:0] bpos = cnt[CW-1:0] >> $clog2(BCLK_DIV);  // 当前是帧内第几个 BCLK
    wire          at_bclk_edge = (cnt[$clog2(BCLK_DIV)-1:0] == { $clog2(BCLK_DIV){1'b0} });
    // ⚠️ HP_BCK 是 **3.125 MHz 的方波**（周期 = BCLK_DIV 个 clk）⇒ 它每 **半个** 周期翻转一次，
    //    所以需要一个"半周期"使能（每 BCLK_DIV/2 个 clk）。
    wire          at_bclk_half = (cnt[$clog2(BCLK_DIV/2)-1:0] == { $clog2(BCLK_DIV/2){1'b0} });

    // ── 节拍输出（全部寄存，单时钟域）────────────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            tick_audio   <= 1'b0;
            mclk_en      <= 1'b0;
            bclk_en      <= 1'b0;
            bclk_half_en <= 1'b0;
            lrclk        <= 1'b0;   // 复位后 = 低 = 左声道
            frame_start  <= 1'b0;
        end else begin
            tick_audio   <= (cnt == {CW{1'b0}});                       // 帧起点
            mclk_en      <= (cnt[$clog2(MCLK_DIV)-1:0] == { $clog2(MCLK_DIV){1'b0} });
            bclk_en      <= at_bclk_edge;
            bclk_half_en <= at_bclk_half;
            lrclk        <= (bpos >= SLOT_BCK);       // 前半帧低（左）、后半帧高（右）
            frame_start  <= at_bclk_edge && (bpos == {BW{1'b0}});
        end
    end

endmodule
