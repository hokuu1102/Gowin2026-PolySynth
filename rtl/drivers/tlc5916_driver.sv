`timescale 1ns/1ps

// TLC5916 normal-mode serial writer.
// led_data[n] = 1 enables OUTn. Bits are sent OUT7 first, OUT0 last.
//
// ⭐⭐ `OE` 防护（2026-09-17 加，修 K-01 / K-02 / K-03 里最危险的那条）
//   TI 手册（`tlc5916.pdf` 原件）§Operation Mode Switching 原文：
//     · "When a **one-clock-wide pulse** appears on OE(ED2), the device enters the Mode
//        Switching phase. At this time, the voltage level on **LE(ED1)** determines which
//        mode the TLC591x switches to."
//     · "At the **fourth rising edge of CLK**, if LE(ED1) is sampled as voltage high,
//        TLC591x switches to **Special Mode**; otherwise, it switches to **Normal Mode**."
//   ⇒ 触发条件不是"某个 ns 宽度"，而是「**OE 的低电平恰好跨过 1 个 CLK 上升沿**」。
//     进了 Special Mode 之后 SDI/LE 不再控制输出（现象：明明在移位，灯却不亮/乱亮）。
//     ✅ 手册也给了**恢复路径**：只要 LE 在第 3~5 个 CLK 上升沿之间为**低**，就回 Normal Mode。
//
//   ⭐ 本模块用**双重结构性防护**，让"恰好 1 个 CLK 宽"在物理上不可能出现：
//     ① **稳定窗**（`OE_STABLE`）：`outputs_enable` 必须连续稳定 N 个 clk 才被接受
//        ⇒ 上游任何 1~N-1 拍的毛刺/抖动**根本传不到引脚**；
//     ② **只在安全窗口更新**：只有当 `state == IDLE` 且 `tlc_le == 0` 且 `tlc_clk == 0`
//        （即"不在移位、不在锁存、CLK 静止"）时才把新值写进 `tlc_oe_n`
//        ⇒ 即使真出现窄脉冲，它也不可能**跨过 CLK 上升沿**，因此触发条件不成立。
//     ⚠️ 代价：`outputs_enable` 的变化要等当前这次传输结束、回到 IDLE 后才生效
//        （最多约一次传输 ≈ 8.5 µs @DATA_HZ=1 MHz）—— 对"消隐/亮度"这类用途完全够用。
//     ⛔ 不要为了"响应快"把 ② 去掉：那正是 K-01 的成因。
//
//   ⭐⭐ 2026-09-17 第二轮（`K-57`）：查**手册原件**的时序表发现
//     `tw(OE) Pulse duration, OE(ED2) **500 ns**`（另有 `tw(ED2) ≥ 2 µs` 是 Error Detection 模式的要求）。
//     ⚠️ 原来的 `OE_STABLE=8` 拍 @50 MHz 只有 **160 ns**，**短于**手册值。
//     ⚠️ 判读：这条限值约束的是"**有意打的那个进模式的窄脉冲**"，
//        我们**从不有意进 Special Mode**（`OE` 只当"LED 总开关"），所以**不约束正常使用**；
//        但**反面要小心**：若误产生一个"短于 500 ns 的 OE 低脉冲"，
//        它可能落在"**既不被识别为有效脉冲、又恰好跨过某个 CLK 沿**"的模糊区。
//     ⇒ ⭐ 现在把稳定窗默认值提到 **≥ 25 拍（500 ns @50 MHz）**，让它**同时满足 `tw(OE)`**。
//        代价只是"消隐响应最多晚 0.5 µs"（原本就要等一次传输 ≈ 8.5 µs，可忽略）。
//     ⭐ 并且加了**参数自检**（见下），换 `CLK_HZ` 时不会静默失效。
module tlc5916_driver #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer DATA_HZ   = 1_000_000,
    // `OE` 稳定窗（clk 周期数）。默认 25 拍 ⇒ @50 MHz = **500 ns**，满足手册 `tw(OE) ≥ 500 ns`。
    parameter integer OE_STABLE = 25
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] led_data,
    input  wire       outputs_enable,

    output reg        tlc_clk,
    output reg        tlc_sdi,
    output reg        tlc_le,
    output reg        tlc_oe_n,
    output reg        busy,
    output reg        done
);

    localparam integer HALF_DIV_RAW = CLK_HZ / (DATA_HZ * 2);
    localparam integer HALF_DIV =
        (HALF_DIV_RAW < 1) ? 1 : HALF_DIV_RAW;
    localparam integer DIV_WIDTH =
        (HALF_DIV <= 1) ? 1 : $clog2(HALF_DIV);

    localparam integer OE_W = (OE_STABLE <= 1) ? 1 : $clog2(OE_STABLE + 1);

    // ── ⭐ 参数自检（`K-57`，与 `clk_gen` 的 `PARAM_OK` 同一套路）──────────────
    //   ⚠️ 为什么要机器检查而不是只写注释：`OE_STABLE` 是**拍数**，它对应的**时间**随 `CLK_HZ` 变。
    //     手册要求 `tw(OE) ≥ 500 ns` ⇒ 稳定窗换算成 ns 必须 ≥ 500。
    //     ⛔ 换时钟（比如将来上 100 MHz）时，25 拍就变成 250 ns ⇒ **静默失效**。
    //     ⇒ 这里在仿真启动时明确告警（综合工具忽略 `initial`，所以只是仿真侧防线）。
    //
    //   ⚠️⚠️ 2026-09-17 实测踩坑（**两个坑，都值得记**）：
    //     ① 第一版写成 `(OE_STABLE * 1_000_000_000) / CLK_HZ`
    //        ⇒ **32 位有符号 integer 溢出**（25 × 10⁹ ≫ 2³¹），算出 **−15 ns**，自检反而误报。
    //     ② 改用 `localparam longint` + `longint'(...)` 强制转换后，**iverilog 通过**，
    //        但 ⛔ **Gowin 综合器报 `EX3863` 语法错 / `EX3872` 未声明**
    //        —— **`longint` 与 `longint'()` 在 Gowin 里不可用**（SystemVerilog 子集）。
    //     ⭐ 最终写法（**iverilog 与 Gowin 都支持，且不溢出**）：**先除后乘**，
    //        让中间量"每拍多少 ns"先算出来，再乘拍数：
    //          `per_clk_ns = 1_000_000 / (CLK_HZ / 1_000)`   ← 等于 `1e9 / CLK_HZ`
    //          `OE_NS      = OE_STABLE * per_clk_ns`
    //        50 MHz ⇒ `1e6 / 50000 = 20`（每拍 20 ns）⇒ `25 × 20 = 500 ns` ✅
    //        ⚠️ 中间量最大 `1e9/CLK_HZ`，乘 `OE_STABLE` 后仍远小于 2³¹ ⇒ **不会溢出**。
    //        ⚠️⚠️ 我自己在这里**又踩了一次**：第一版把中间量误当成"千分之一 ns"，
    //           多除了一个 1000 ⇒ 算出 **0 ns**、自检误报。
    //           📌 教训：**"单位"要靠"量纲推导"确认，不能靠感觉** ——
    //             `1e6/(CLK/1e3) = 1e9/CLK` 就是"ns/拍"，不是别的。
    localparam integer PER_CLK_NS = 1_000_000 / (CLK_HZ / 1_000);
    localparam integer OE_NS      = OE_STABLE * PER_CLK_NS;
    localparam TLC_PARAM_OK       = (OE_NS >= 500) && (HALF_DIV >= 1) && (OE_STABLE >= 2);

    initial begin
        if (OE_NS < 500)
            $display("ERROR [tlc5916] OE_STABLE=%0d 拍 @CLK_HZ=%0d = %0d ns < 手册 tw(OE) 500 ns ⇒ 提高 OE_STABLE 或核对时钟（见 K-57）",
                     OE_STABLE, CLK_HZ, OE_NS);
        if (HALF_DIV_RAW < 1)
            $display("ERROR [tlc5916] DATA_HZ=%0d 相对 CLK_HZ=%0d 太高 ⇒ 半周期被夹到 1 拍（时钟频率不符预期）",
                     DATA_HZ, CLK_HZ);
    end

    // ⭐⭐ Normal-Mode 恢复序列（`K-66`，2026-09-17 加）
    //
    //   ⭐ 手册原文依据（`tlc5916.pdf` Figure 16 一段 + NOTE）：
    //     · "once a **one-clock-wide short pulse (101)** of OE(ED2) appears, TLC591x enters the
    //        Mode Switching phase. At the **fourth rising edge of CLK**, if LE(ED1) is sampled as
    //        voltage high, TLC591x switches to **Special Mode**; otherwise, it switches to
    //        **Normal Mode**."
    //     · ⭐ **NOTE 1（关键背书）**："The signal sequence for the mode switching **may be used
    //        frequently to ensure that TLC591x is in the proper mode**."
    //     · ⭐ **NOTE 3**："After power on, the default operation mode is **Normal Mode**."
    //   ⇒ 所以"**发一次 1-CLK 宽的 OE 脉冲 + 期间 LE 保持低**"就是**TI 官方认可**的
    //     "**强制回到 Normal Mode**"手段 ⇒ 把"进了 Special Mode 只能断电"降级为"**开机自愈**"。
    //
    //   ⭐ 实现（**波形是照着手册 Figure 16 的 "101" 设计的**）：
    //     复位释放后一次性跑 `REC_PERIODS` 个 `tlc_clk` 周期 ——
    //       · `LE` **全程低**（决定"切到 Normal"的那一位）
    //       · `OE` 拉低 **恰好 1 个 `tlc_clk` 周期**，且该低电平窗口**跨过恰好 1 个 CLK 上升沿**
    //       · 低脉冲的**前后各留半周期**余量 ⇒ 满足 `tsu(ED2)=8.5 ns` / `th(ED2)=10 ns`
    //       · 之后第 4 个 CLK 上升沿采到 `LE = 低` ⇒ **Normal Mode** ✅
    //     ⚠️⚠️ 第一版**写错过**：把 `OE` 的下降沿与 CLK 上升沿**对齐**了 ⇒
    //        既有 setup/hold 歧义，又可能让低窗口跨过 0 或 2 个上升沿。
    //        ⭐ 正确做法：用"CLK 周期内的相位"来定位脉冲，**居中**跨过上升沿。
    //   ⚠️ 这段**故意**违反防护 ②（"OE 只在 CLK 静止时变"）—— 因为**手册要求**这个脉冲
    //     必须与 CLK 同步出现。安全性由三点保证：
    //      ① 只在**复位释放后**跑一次，之后**永不再跑**（`recovering` 只清一次）；
    //      ② 全程 `LE` 低 ⇒ 无论怎么切换，**只会切到 Normal**（⛔ 切不到 Special）；
    //      ③ 脉冲宽度 = **1 个 `tlc_clk` 周期 = 1000 ns** ≥ 手册 `tw(OE) ≥ 500 ns` ✅。
    //   ⚠️ 代价：复位后多花 `REC_PERIODS` 个 `tlc_clk` 周期（≈ 6 µs）才开始接收 `start`
    //      ⇒ ⭐ 期间来的 `start` 用 `pending` 记住（与 `R-09` 同一语义），⛔ 不丢。
    //   ⛔ 不要把它改成"每个 `start` 都跑" —— 手册 NOTE 3 说上电默认就是 Normal，
    //      没必要每次刷新都跑；而且跑多了反而增加误切风险。
    localparam integer REC_CLK_PERIOD = 2 * HALF_DIV;        // 一个 tlc_clk 周期（clk_sys 拍）
    localparam integer REC_SETTLE_CLKS = 8;                  // 开始前先让电平稳定几拍
    localparam integer REC_PERIODS     = 6;                  // 发几个 CLK 周期（≥5：第 4 个沿要采 LE）
    localparam integer REC_TOTAL_CLKS  = REC_SETTLE_CLKS + REC_PERIODS * REC_CLK_PERIOD;
    localparam integer REC_W = (REC_TOTAL_CLKS <= 1) ? 1 : $clog2(REC_TOTAL_CLKS + 1);
    // ⭐ `OE` 低脉冲的起点相位：落在 **CLK 低电平段的中间** ⇒
    //    低窗口 [P_FALL, P_FALL+REC_CLK_PERIOD) 正好**跨过下一个 CLK 上升沿**（且只跨一个）
    localparam integer REC_OE_FALL_PH = HALF_DIV + (HALF_DIV / 2);

    reg                recovering;              // 正在跑恢复序列（此时主 FSM 冻结）
    reg [REC_W-1:0]    rec_cnt;
    // ⚠️ 恢复序列的中间量必须**在模块层声明**（⛔ 不能在 `begin : label` 里声明 ——
    //    iverilog 允许、但 Gowin 对块内声明的支持更窄，见 `K-63` 的教训）
    integer            rec_phase;               // 稳定期之后过了几拍
    integer            rec_in_period;           // 在当前 tlc_clk 周期内的相位

    localparam [1:0] STATE_IDLE       = 2'd0;
    localparam [1:0] STATE_CLK_HIGH   = 2'd1;
    localparam [1:0] STATE_CLK_LOW    = 2'd2;
    localparam [1:0] STATE_LE_WAIT    = 2'd3;   // ⭐ CLK 静止后再抬 LE（A2 保证）
    localparam [2:0] STATE_LATCH_HIGH = 3'd4;   // ⚠️ 状态位宽从 2 位升到 3 位（新增一个状态）

    reg [2:0] state;
    reg [7:0] data_latched;
    reg       pending;      // ⭐ R-09：busy 期间来的 `start` 记在这里，回 IDLE 后补发
    reg [2:0] bit_index;
    reg [DIV_WIDTH-1:0] div_counter;

    // ── `OE` 稳定窗（防护 ①）──────────────────────────────────────
    reg                 oe_hold;      // 已确认稳定的目标值（= outputs_enable 的"去抖版"）
    reg [OE_W-1:0]      oe_cnt;
    wire                oe_quiet = (state == STATE_IDLE) && (tlc_le == 1'b0) && (tlc_clk == 1'b0);

    // rst_n follows the repository-wide active-low synchronous-reset rule.
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= STATE_IDLE;
            data_latched <= 8'h00;
            bit_index    <= 3'd7;
            div_counter  <= {DIV_WIDTH{1'b0}};

            tlc_clk      <= 1'b0;
            tlc_sdi      <= 1'b0;
            tlc_le       <= 1'b0;
            tlc_oe_n     <= 1'b1;      // ⭐ 复位 = 关断（⛔ OE 低有效；上电不该点亮）
            busy         <= 1'b0;
            done         <= 1'b0;

            oe_hold      <= 1'b0;      // ⇒ ~oe_hold = 1 = 关断，与 tlc_oe_n 一致
            oe_cnt       <= {OE_W{1'b0}};
            pending      <= 1'b0;

            // ⭐ 复位后进入恢复序列（`K-66`）
            recovering   <= 1'b1;
            rec_cnt      <= {REC_W{1'b0}};
        end
        else begin
            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ Normal-Mode 恢复序列（`K-66`）：复位释放后**一次性**跑完，
            //     之后 `recovering` 永久为 0，主 FSM 才接管。
            //     目标：发一个"1 个 CLK 宽"的 `OE` 低脉冲，且**全程 `LE` 低**
            //     ⇒ 第 4 个 CLK 上升沿采到 `LE=低` ⇒ 器件进 **Normal Mode**。
            // ═══════════════════════════════════════════════════════════════
            if (recovering) begin
                rec_cnt <= rec_cnt + 1'b1;

                // ⭐ 恢复期间来的 `start` **不能丢**（与 R-09 同一语义）
                if (start) pending <= 1'b1;

                if (rec_cnt >= REC_TOTAL_CLKS[REC_W-1:0]) begin
                    recovering <= 1'b0;          // ⭐ 只跑一次
                    // ⚠️⚠️ 结束时必须把 `OE` 交还给**主 FSM**（而不是写死 1'b1）：
                    //    写死 1'b1 会让"恢复结束时 `OE` 被强制关断"，而如果上层此刻
                    //    要求点亮（`outputs_enable=1`），`tlc_oe_n` 就会**停在错误的高电平**
                    //    —— 实测踩到：`ERROR data=00: tlc_oe_n should be low`。
                    //    ⭐ 正确做法：结束时把 `oe_hold` 与稳定窗**重置**，
                    //      让主 FSM 在下一拍按 `outputs_enable` 正常接管。
                    //      （`oe_hold` 复位为 0 ⇒ 下一拍主 FSM 看到它与 `outputs_enable` 不同
                    //        ⇒ 走稳定窗重新确认，最多再等 `OE_STABLE` 拍，安全。）
                    tlc_clk    <= 1'b0;
                    tlc_le     <= 1'b0;
                    tlc_oe_n   <= 1'b1;          // 本拍先保持关断（安全）……
                    tlc_sdi    <= 1'b0;
                    oe_hold    <= 1'b0;          // ⭐ 重置稳定窗状态 ⇒ 主 FSM 下一拍接管 OE
                    oe_cnt     <= {OE_W{1'b0}};
                end else if (rec_cnt < REC_SETTLE_CLKS[REC_W-1:0]) begin
                    // ① 稳定期：CLK 低、LE 低、OE 高（= 关断，安全）
                    tlc_clk    <= 1'b0;
                    tlc_le     <= 1'b0;
                    tlc_oe_n   <= 1'b1;
                    tlc_sdi    <= 1'b0;
                end else begin
                    // ② 发 `REC_PERIODS` 个 CLK 周期；`LE` 全程低
                    rec_phase     = rec_cnt - REC_SETTLE_CLKS;
                    rec_in_period = rec_phase % REC_CLK_PERIOD;
                    // CLK：周期起点 = 上升沿（前半个周期高）
                    tlc_clk  <= (rec_in_period < HALF_DIV) ? 1'b1 : 1'b0;
                    tlc_le   <= 1'b0;                  // ⭐ 全程低（决定切到 Normal）
                    // ⭐⭐ OE 低窗口用**绝对相位**定位（⛔ 不能用"周期内相位 >= P"）：
                    //     低窗口 = 绝对相位区间 **[REC_OE_FALL_PH, REC_OE_FALL_PH + REC_CLK_PERIOD)**
                    //     ⇒ 长度 = **1 个完整 CLK 周期 = 1000 ns** ≥ 手册 `tw(OE) 500 ns` ✅
                    //     ⇒ 且该窗口**恰好跨过 1 个 CLK 上升沿**（绝对相位 = 周期的整数倍处）
                    //       = 手册要求的 "101" 形态 ✅
                    //   ⚠️⚠️ 第一版写的是"周期内相位 >= REC_OE_FALL_PH"，那样低窗口是
                    //      [37, 50) —— 只有 **13 拍 = 260 ns**，且**跨不过任何上升沿**
                    //      （上升沿在周期内相位 0）⇒ 实测被自检抓到：
                    //      "`OE` 低窗口跨过 0 个 CLK 上升沿" + "只有 260 ns"。
                    //   📌 教训：**跨周期边界的窗口要用绝对相位判断**，
                    //      用"周期内相位"会把窗口截断在周期末尾。
                    tlc_oe_n <= (rec_phase >= REC_OE_FALL_PH &&
                                 rec_phase <  REC_OE_FALL_PH + REC_CLK_PERIOD) ? 1'b0 : 1'b1;
                    tlc_sdi  <= 1'b0;
                end
                // 恢复期间主 FSM 冻结（state 保持 IDLE，busy 保持 0）
                state  <= STATE_IDLE;
                busy   <= 1'b0;
                done   <= 1'b0;
            end
            else begin
            // ══════════════════ 以下为主 FSM（原逻辑，未改动）══════════════════
            // ── 防护 ①：稳定窗。⛔ 不要直接 `tlc_oe_n <= ~outputs_enable`（K-01 的成因）
            if (oe_hold !== outputs_enable) begin
                if (oe_cnt >= OE_STABLE - 1) begin
                    oe_hold <= outputs_enable;     // 连续稳定够久 ⇒ 接受
                    oe_cnt  <= {OE_W{1'b0}};
                end
                else begin
                    oe_cnt <= oe_cnt + 1'b1;       // 还在观察，先不接受
                end
            end
            else begin
                oe_cnt <= {OE_W{1'b0}};
            end

            // ── 防护 ②：只在"CLK 静止 + LE 低 + 不在传输"时才动 OE ──
            //     ⭐ 这条让"OE 低电平跨过 CLK 上升沿"在结构上不可能发生 ⇒ 进不了 Special Mode
            if (oe_quiet) tlc_oe_n <= ~oe_hold;

            done     <= 1'b0;

            // ── ⭐ R-09：`start` 在 busy 期间不再被静默丢弃（2026-09-17 加）──
            //   原来只有 `STATE_IDLE` 分支看 `start` ⇒ 传输中（≈8.5 µs @1 MHz）来的 `start`
            //   **无声无息地消失**，上层会以为"写了但没生效"。这里用一个 `pending` 位记住它，
            //   等回到 IDLE 时**补发一次**（语义 = "至少写一次"，而不是"写一次就丢一次"）。
            //   ⚠️ 代价：只多 1 位寄存器；⛔ 不要为了"简单"去掉它 —— 那会让上层出现
            //      "偶尔丢一帧灯"这种极难定位的现象。
            if (start && busy) pending <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    tlc_clk     <= 1'b0;
                    tlc_sdi     <= 1'b0;
                    tlc_le      <= 1'b0;
                    busy        <= 1'b0;
                    div_counter <= {DIV_WIDTH{1'b0}};

                    // `start` 或"上次被丢弃的请求"都能触发本次传输
                    if (start || pending) begin
                        pending      <= 1'b0;
                        data_latched <= led_data;
                        bit_index    <= 3'd7;
                        tlc_sdi      <= led_data[7];
                        busy         <= 1'b1;
                        state        <= STATE_CLK_HIGH;
                    end
                end

                STATE_CLK_HIGH: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_clk     <= 1'b1;
                        state       <= STATE_CLK_LOW;
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                STATE_CLK_LOW: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_clk     <= 1'b0;      // ⭐ 先把 CLK 拉低……

                        if (bit_index == 3'd0) begin
                            // ⚠️ 原来这里是"同一拍同时 `tlc_clk <= 0` 和 `tlc_le <= 1`" ⇒
                            //    `LE` 高与 CLK 的 1→0 边沿**同拍**，违反 K-03
                            //    （TI 手册：`LE` 是电平锁存，移位期必须保持低；
                            //     而且模式切换阶段还要靠 `LE` 电平决定去留）。
                            //    ⇒ 先只拉低 CLK，下一拍再抬 LE（多用一个状态，代价 1 拍）。
                            state <= STATE_LE_WAIT;
                        end
                        else begin
                            bit_index <= bit_index - 1'b1;
                            tlc_sdi   <= data_latched[bit_index - 1'b1];
                            state     <= STATE_CLK_HIGH;
                        end
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                // ⭐ 新增：CLK 已经静止之后，才允许抬 `LE`（保证 A2 恒成立）
                STATE_LE_WAIT: begin
                    tlc_le <= 1'b1;
                    state  <= STATE_LATCH_HIGH;
                end

                STATE_LATCH_HIGH: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_le      <= 1'b0;
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        state       <= STATE_IDLE;
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                default: begin
                    state       <= STATE_IDLE;
                    tlc_clk     <= 1'b0;
                    tlc_sdi     <= 1'b0;
                    tlc_le      <= 1'b0;
                    busy        <= 1'b0;
                    div_counter <= {DIV_WIDTH{1'b0}};
                end
            endcase
            end   // ⭐ 结束 `else`（非恢复期）—— 对应上面 `if (recovering) … else begin`
        end
    end

endmodule
