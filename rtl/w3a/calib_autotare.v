`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// calib_autotare.v · 上电自动零点标定（⭐ W3a 采集链）
//
// ⭐ 设计依据：`files/20-代码/上电自动tare-设计方案-20260923.md`
//
// ── ⭐ 它做什么 ───────────────────────────────────────────────────────────────
//   ⭐ 上电后等一段时间（让霍尔供电稳定），⭐ 然后**逐个通道发一次 `tare`**
//      ⇒ ⭐ 把每个轴【当前】的原始码记为零点（⭐ 即"松手位"）。
//   ⛔ **不做 `span`** —— ⚠️ 它需要人把每个轴按到底 ⇒ ⭐ 留给"校准模式"。
//
// ── ⭐⭐ 为什么需要（⛔ 不做的后果）────────────────────────────────────────────
//   ⚠️ `calib` 未标定时 `zero = 0` ⇒ ⭐ **松手时读到的不是 0**
//      （⭐ 霍尔偏置 + 装配公差 ⇒ 实测松手 1.60 V ≈ 1985 码）
//   🔴 后果：⭐ `event_extract` 的触发阈**按错的基准判**
//      ⇒ ⚠️ 松手就被判成"按下"（挂音）、⚠️ 或要按很深才触发（手感差）。
//
// ── 🔴🔴 本模块唯一的难点：⭐ `tare` 必须与【目标通道的样本】同拍 ──────────────
//   ⭐ 依据 `calib.v:145`：
//        `if (tare) zero_r[cal_ch] <= raw;`
//      ⇒ ⚠️ **`raw` 是【当拍输入】，⛔ 不是寄存器** —— 它是芯片**当前送来的那个通道**的值。
//      ⇒ 🔴 **`tare` 与 `sample_ch` 必须对得上**，否则会把【别的通道】的值
//         记成这个通道的零点 —— ⭐ **而且是静默的**（`cal_ch` 对、`raw` 错）。
//   📌 这正是 `K-87` 那一族：⭐ **时机对不上，但没有任何报错**。
//
//   ⭐ **正解：等 `sample_ch_i == cur_ch` 那一拍再拉高 `tare`**（⭐ 见下方状态机）
//      ⚠️ 因为 `adc_farm` 是**锁步**的（⭐ 每帧固定 ch0→ch7）
//      ⇒ ⭐ 天然对齐，⛔ 不需要额外计数器，⚠️ 也不怕帧间隔变化。
//   🔴 **反面做法（⛔ 不要用）**：⚠️ 数"每 8 个 `sample_valid` 标一个"
//      —— 🔴 一旦 `N_ADC` 或扫描顺序变化就**静默错位**。
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001**（`K-91`：⛔ 不用 SV 专有构造，否则整模块被静默丢弃）
//   · ⭐ **同步复位、低有效**、⭐ **单时钟域 50 MHz**
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module calib_autotare #(
    // ⭐ 每片通道数（⭐ `MCP3208` = 8）
    parameter integer NCH       = 8,
    // ⭐ 片数（⭐ 本版 2 = 左手板 L/R）
    parameter integer N_ADC     = 2,
    // ⭐ 上电等待：⭐ 让霍尔供电 + LDO 稳定（⭐ 默认 200 ms @50 MHz）
    //   ⚠️ 太短 ⇒ 读数还在漂 ⇒ 🔴 **零点记错**（⚠️ 而且不可察觉）
    parameter integer DELAY_CLK = 10_000_000
) (
    input  wire             clk,
    input  wire             rst_n,          // ⭐ 同步复位、低有效

    // ── 来自 `adc_farm`（⭐ 用于对齐时机）──────────────────────────────────
    input  wire             sample_valid_i, // ⭐ 单拍脉冲
    input  wire [2:0]       sample_ch_i,    // ⭐ 当前是哪个通道

    // ⭐⭐ `retrig_i`（⭐ 2026-09-23 深夜新增 · 用户拍板"'T' 复用 calib_autotare"）
    //   🔴 **它解决什么**：⭐ 本模块原本**只在上电跑一次**（`ST_WAIT → ST_SWEEP
    //      → ST_DONE` 后自锁，⛔ 再也回不去）⇒ ⚠️ 无法响应用户的 `'T'`（tare）命令。
    //   ⭐ **做法**：⭐ 从 `ST_DONE` 收到 `retrig_i` ⇒ ⭐ **直接跳 `ST_SWEEP`**
    //      （⛔ **不重新等 `DELAY_CLK`**）——
    //      ⚠️ 因为 `DELAY_CLK` 是给"上电时霍尔供电未稳"用的，
    //         ⭐ 而上电早已完成 ⇒ ⭐ 再等 200 ms 纯属让操作者干等。
    //   ⚠️ **为什么不从 `ST_WAIT` 也能重触发**：⭐ `ST_WAIT` 期间霍尔还没稳
    //      ⇒ 🔴 那时 tare 会把**漂移中的值**记成零点（⭐ 不可察觉的错）。
    //      ⇒ ⭐ **只在 `ST_DONE` 接受重触发**（⭐ 语义：该模块已"就绪"）。
    //   ⭐ 触发后 `cur_ch` 归 0、`ST_SWEEP` 会**逐通道重标一遍** ⇒
    //      ⭐ 与用户要求的"'T' = 全部轴、逐轴"一致。
    //   ⚠️ 与 `calib_span` 的 `start_i` 同族：⭐ **单拍脉冲**、⭐ **同步**。
    input  wire             retrig_i,

    // ── 去 `calib`（⭐ 每片一份）───────────────────────────────────────────
    output reg  [N_ADC-1:0] tare_o,         // ⭐ 逐片独立（⭐ 它们锁步，所以同时拉高）
    output reg  [2:0]       cal_ch_o,

    // ── 状态（⭐ 供观测/调试）─────────────────────────────────────────────
    output wire             busy_o,         // ⭐ 正在标定
    output wire             done_o          // ⭐ 全部标完（⭐ 置起后不再动）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 三段状态机
    //   WAIT  : ⭐ 上电后等 `DELAY_CLK`（⚠️ 让霍尔稳定）
    //   SWEEP : ⭐ 逐通道（0..NCH-1）发 `tare`
    //   DONE  : ⭐ 停住（⛔ 不再产生任何 `tare`）
    // ═══════════════════════════════════════════════════════════════════════
    localparam [1:0] ST_WAIT  = 2'd0;
    localparam [1:0] ST_SWEEP = 2'd1;
    localparam [1:0] ST_DONE  = 2'd2;

    reg [1:0]  state;
    //   ⭐ 延时计数器：⭐ 位宽必须能装下 `DELAY_CLK`（⛔ 不要写死）
    localparam integer DCW = (DELAY_CLK < 2) ? 1 : $clog2(DELAY_CLK + 1);
    reg [DCW-1:0] delay_cnt;
    //   ⭐ 当前要标的通道（⭐ 0 .. NCH-1）
    reg [2:0]  cur_ch;

    assign busy_o = (state == ST_SWEEP);
    assign done_o = (state == ST_DONE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_WAIT;
            delay_cnt <= {DCW{1'b0}};
            cur_ch    <= 3'd0;
            tare_o    <= {N_ADC{1'b0}};
            cal_ch_o  <= 3'd0;
        end else begin
            // ⭐ `tare` 默认低（⭐ 它**只能是单周期脉冲** —— 见下）
            tare_o <= {N_ADC{1'b0}};

            case (state)
                // ── ⭐ WAIT：等霍尔供电稳定 ────────────────────────────────
                ST_WAIT: begin
                    if (delay_cnt == DELAY_CLK[DCW-1:0]) begin
                        state  <= ST_SWEEP;
                        cur_ch <= 3'd0;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ── ⭐⭐ SWEEP：逐通道发 `tare` ─────────────────────────────
                //   🔴 **关键：只在 `sample_ch_i == cur_ch` 那一拍拉高** ——
                //      ⭐ 这样 `calib` 内部的 `raw` 正好是本通道的值 ✅
                //   ⚠️ 且 `cal_ch_o` 与 `tare_o` **同拍锁存**（⭐ 同一个 always、
                //      同一次赋值）⇒ ⭐ 满足 `calib` 的"1 周期脉冲"要求。
                ST_SWEEP: begin
                    if (sample_valid_i && (sample_ch_i == cur_ch)) begin
                        tare_o   <= {N_ADC{1'b1}};   // ⭐ 所有片同拍（⭐ 锁步）
                        cal_ch_o <= cur_ch;
                        //   ⭐ 本通道标完 ⇒ 推进；⭐ 全部标完 ⇒ DONE
                        if (cur_ch == (NCH - 1)) begin
                            state  <= ST_DONE;
                            cur_ch <= 3'd0;
                        end else begin
                            cur_ch <= cur_ch + 3'd1;
                        end
                    end
                end

                // ── ⭐ DONE：⛔ 不再产生任何 `tare` ────────────────────────
                //   ⚠️ **必须有这个自锁** —— 否则会把"按下的位置"记成零点
                //      （⚠️ 那会导致该轴**永远触发不了**）。
                //   ⭐⭐ `retrig_i`（⭐ 2026-09-23 新增）：⭐ 唯一的重入点 ——
                //      ⭐ 跳回 `ST_SWEEP` **重新逐通道标一遍**（⛔ 不等 DELAY_CLK）。
                //
                //   🔴 **⚠️ 这里【不需要】再写 `cur_ch <= 0`**（⭐ 2026-09-23 深夜）
                //      ⭐ 原因：⭐ `ST_SWEEP` 走到最后一个通道时**已经**会
                //         `cur_ch <= 3'd0`（⭐ 见上方 `if (cur_ch == NCH-1)` 分支）
                //      ⇒ ⭐ 所以进入 `ST_DONE` 时 `cur_ch` **恒为 0**
                //      ⇒ ⛔ 在这里再写一次是**永不可达的冗余赋值**。
                //      📌 变异测试佐证：⭐ 把那行改成 `cur_ch <= cur_ch` 后
                //         **没有任何 tb 变红**（⭐ 因为它的值本来就是 0）。
                //      ⚠️ 我第一版出于"稳妥"写了它 —— ⭐ 但**不可达的代码是噪声**，
                //         ⚠️ 它会让人误以为这里做了必要的状态清理。
                ST_DONE: begin
                    tare_o <= {N_ADC{1'b0}};
                    if (retrig_i) begin
                        state  <= ST_SWEEP;      // ⭐ `cur_ch` 已为 0 ⇒ ⭐ 从头标
                    end
                end

                default: state <= ST_WAIT;
            endcase
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检（与既有模块同一套路）
    //   ⚠️ 会**静默失效**的组合：
    //     ① `NCH <= 0` ⇒ ⚠️ 没有通道可标（⭐ 链永远不工作）
    //     ② `N_ADC <= 0` ⇒ ⚠️ `tare_o` 恒 0 ⇒ 🔴 **标定永不发生**（⚠️ 静默）
    //     ③ `DELAY_CLK == 0` ⇒ ⚠️ 上电立刻标定 ⇒ 🔴 **霍尔未稳定 ⇒ 零点记错**
    // ═══════════════════════════════════════════════════════════════════════
    localparam PARAM_OK = (NCH > 0) && (N_ADC > 0) && (DELAY_CLK > 0);

    initial begin
        if (NCH <= 0)
            $display("ERROR [calib_autotare] NCH = %0d <= 0 => no channel to calibrate. PARAM_OK=0.", NCH);
        if (N_ADC <= 0)
            $display("ERROR [calib_autotare] N_ADC = %0d <= 0 => tare_o is always 0, so calibration NEVER happens (silently). PARAM_OK=0.", N_ADC);
        if (DELAY_CLK == 0)
            $display("ERROR [calib_autotare] DELAY_CLK = 0 => calibration starts before the hall supply has settled, so the recorded zero point is WRONG. PARAM_OK=0.");
        if (PARAM_OK)
            $display("NOTE [calib_autotare] PARAM_OK=1 (NCH=%0d N_ADC=%0d DELAY_CLK=%0d)", NCH, N_ADC, DELAY_CLK);
    end

endmodule

`default_nettype wire
