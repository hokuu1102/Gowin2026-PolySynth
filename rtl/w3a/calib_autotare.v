`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// calib_autotare.v · 上电自动零点标定（⭐ W3a 采集链）
//
// ⭐ 设计依据：`files/20-代码/上电自动tare-设计方案-20260923.md`
//
// ── ⭐ 它做什么 ───────────────────────────────────────────────────────────────
//   ⭐ 上电后等一段时间（让霍尔供电稳定），⭐ 然后**逐个通道发一次 `tare`**
//      ⇒ ⭐ 把每个轴【当前】的原始码记为零点（⭐ 即"松手位"）。
//   ⭐⭐ 2026-09-30 新增：**"静止才捕获"守卫** —— ⭐ 只有该通道**连续 `STILL_FRAMES`
//      帧的 `raw` 帧间差 ≤ `STILL_TOL`** 才允许捕获；⭐ 超时（`WAIT_MS`，按 `clk` 计）
//      则**跳过该轴**并置 `skip_mask_o`/`fail_o`（⛔ 不静默）。
//      🔴 **为什么**：⭐ 原实现一看到样本就捕获 ⇒ ⚠️ 把"按下位"记成零点
//      ⇒ ⭐ 该轴**永不触发**或**永久挂音**。
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
    parameter integer DELAY_CLK = 10_000_000,
    // ⭐⭐ 2026-09-30 新增：**"静止才捕获"守卫**（⭐ 修「复位 ≠ 冷启动」的【上游源头】）
    //
    //   🔴 **它解决什么**：⭐ 原实现**一看到该通道的样本就捕获 `zero_r`**
    //      ⇒ ⚠️ 若那一刻该轴**不是松手位**（用户按着 / 板没插好 / 片未接 ⇒
    //        `MISO` 被内部上拉 ⇒ `raw = 4095`）⇒ 🔴 **把"按下位"记成零点**
    //      ⇒ ⭐ `pos` 恒小于阈值（该轴**永不触发**）⚠️ 或恒大于阈值（**永久挂音**）。
    //   ⭐ **做法**：⭐ 只有该通道**连续 `STILL_FRAMES` 帧的 `raw` 帧间差 ≤ `STILL_TOL`**
    //      才允许捕获 ⇒ ⭐ 把"记错零点"变成**结构上不可能**
    //      （⭐ 全局 `AGENTS.md` 0.12：改上游源头，⛔ 不在下游打补丁）。
    //   ⚠️ **判"静止"只能用 `raw` 的帧间差**（⛔ 不能用 `pos`）：
    //      ⭐ `pos` 由 `calib` 产生、而它依赖 `zero_r` —— ⭐ **正是本守卫要写的东西**
    //      ⇒ 🔴 那是**自指**（用待写的零点去判断该不该写这个零点）。
    //   ⚠️ **超时必须用 `clk` 计数**（⛔ 不能用帧计数）：⭐ 帧计数只在 `sample_valid_i`
    //      到达时递增 ⇒ 🔴 **ADC 停流时永不到期 = 又变成"永远等"**。
    //   ⚠️ `STILL_EN = 0` ⇒ ⭐ **关闭守卫**（⭐ 保持旧行为，⭐ 只给既有 tb 用）
    parameter integer STILL_EN     = 1,
    parameter integer DW           = 12,
    parameter integer STILL_TOL    = 8,        // ⭐ 帧间 `raw` 变化上限（码）
    parameter integer STILL_FRAMES = 4,        // ⭐ 连续 N 帧静止才允许捕获（4 帧 ≈ 2 ms）
    parameter integer WAIT_MS      = 1000,     // ⭐ 单通道最长等待（ms）
    parameter integer CLK_HZ       = 50_000_000
) (
    input  wire             clk,
    input  wire             rst_n,          // ⭐ 同步复位、低有效

    // ── 来自 `adc_farm`（⭐ 用于对齐时机）──────────────────────────────────
    input  wire             sample_valid_i, // ⭐ 单拍脉冲
    input  wire [2:0]       sample_ch_i,    // ⭐ 当前是哪个通道
    // ⭐⭐ 2026-09-30 新增：**该通道当前的原始码**（⭐ 用于判"静止"）
    //   ⚠️ 必须与 `sample_valid_i` / `sample_ch_i` **同一路、同一拍**
    //      （⭐ 即"极性校正后、`calib` 前"那一路）
    input  wire [DW-1:0]    sample_data_i,

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
    // ⭐⭐ 2026-09-30 新增：**超时被跳过的通道**（⭐ 1 = 本轴从未成功标定）
    //   ⚠️ **必须有这个可观测指示** —— ⛔ 否则"跳过"是**静默**的
    //      （⭐ 全局 `K-106`：溢出/失败必须有 sticky 指示）
    output reg  [NCH-1:0]   skip_mask_o,
    // ⭐ = `|skip_mask_o`（⭐ 一个标量，方便直接接诊断回传）
    output reg              fail_o,

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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-09-30 新增：「静止才捕获」守卫的内部状态
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ `WAIT_CLK`：⭐ 单通道的**时钟计数**上界（⛔ 不是帧计数 —— 见参数说明）
    //
    //   🔴🔴 **2026-09-30 实测踩坑（⭐ `tb_calib_autotare` 5 条 FAIL +
    //      `tb_uart_calib_chain` 1 条 FAIL 的【同一个】真因）**：
    //      ⚠️ 原写法 `(WAIT_MS * CLK_HZ) / 1000` 在**默认值**下就溢出 32 位：
    //         `1000 * 50_000_000 = 5.0e10` ≫ `2^31 ≈ 2.147e9`
    //      ⇒ 🔴 有符号回绕成**负数**（实测 `-1_539_607`）
    //      ⇒ `WCW = (WAIT_CLK < 2) ? 1 : ...` ⇒ **`WCW = 1`**
    //      ⇒ 🔴 `WAIT_N` 被截成 1 位 = **1** ⇒ ⭐ `wait_cnt` **第 2 拍就 `>= 1`**
    //      ⇒ 🔴 **每个轴 1 拍就"超时"** ⇒ ⭐ **`tare_o` 的置位路径【整体是死的】**
    //         （⭐ 一个 `tare` 都不发，却把通道全扫完 ⇒ `done_o` 照样置起）
    //      📌 这是 `K-91`/`K-34` 那一族（**位宽/溢出必须显式落定**）。
    //   ⭐ **修法：先除后乘** —— `CLK_HZ/1000` 先化成 kHz（默认 50_000）
    //      ⇒ `1000 * 50_000 = 5.0e7` ✅ **装得下 32 位**
    //      ⭐ 量纲：`ms * kHz = ms * (1000 clk/s / 1000) * ...` ⇒ ⭐ `WAIT_MS * WAIT_KHZ`
    //         就是**时钟数**（⭐ 1000 ms × 50_000 kHz = 1 s × 5e7 Hz = 5e7 拍 ✅）。
    //   ⭐ `WAIT_KHZ` 用**向上取整**（`+999`）⇒ ⛔ 不因 `CLK_HZ` 不是 1000 的整数倍而丢精度。
    localparam integer WAIT_KHZ = (CLK_HZ + 999) / 1000;
    localparam integer WAIT_CLK = WAIT_MS * WAIT_KHZ;
    //   ⭐ 位宽：⭐ 先算 `$clog2`，⭐ 再落成**有宽度的向量**
    //      （⭐ `K-91`：Verilog-2001 ⛔ 不能对 `integer` 参数做位选/比较）
    localparam integer SCW = (STILL_FRAMES < 2) ? 1 : $clog2(STILL_FRAMES + 1);
    localparam integer WCW = (WAIT_CLK    < 2) ? 1 : $clog2(WAIT_CLK + 1);
    localparam [SCW-1:0] STILL_N     = STILL_FRAMES;
    localparam [WCW-1:0] WAIT_N      = WAIT_CLK;
    localparam [DW-1:0]  STILL_TOL_V = STILL_TOL;

    reg [DW-1:0]  last_raw  [0:NCH-1];   // ⭐ 该通道上一帧的原始码
    reg [SCW-1:0] still_cnt [0:NCH-1];   // ⭐ 该通道已连续静止的帧数
    reg           seen_r    [0:NCH-1];   // ⭐ 该通道是否已收到过样本
    reg [WCW-1:0] wait_cnt;              // ⭐ 本通道已等待的时钟数（⭐ 每 clk 递增）
    reg [DW-1:0]  dlt_r;                 // ⭐ 本拍算出的帧间差（⭐ 阻塞赋值临时量）
    reg           still_r;               // ⭐ 本拍该通道是否"静止"
    reg           enough_r;              // ⭐ 本拍静止帧数是否已达 `STILL_N`
    integer       k;                     // ⭐ for 循环变量

    assign busy_o = (state == ST_SWEEP);
    assign done_o = (state == ST_DONE);

    always @(posedge clk) begin
        // ⭐⭐ 组合临时量（⭐ 阻塞赋值 ⇒ 本拍立即可用；⛔ 不引入额外流水级）
        dlt_r    = (sample_data_i > last_raw[sample_ch_i])
                 ? (sample_data_i - last_raw[sample_ch_i])
                 : (last_raw[sample_ch_i] - sample_data_i);
        still_r  = seen_r[sample_ch_i] && (dlt_r <= STILL_TOL_V);
        enough_r = still_r && ((still_cnt[sample_ch_i] >= STILL_N)
                            || ((still_cnt[sample_ch_i] + 1'b1) >= STILL_N));

        if (!rst_n) begin
            state       <= ST_WAIT;
            delay_cnt   <= {DCW{1'b0}};
            cur_ch      <= 3'd0;
            tare_o      <= {N_ADC{1'b0}};
            cal_ch_o    <= 3'd0;
            wait_cnt    <= {WCW{1'b0}};
            skip_mask_o <= {NCH{1'b0}};
            fail_o      <= 1'b0;
            for (k = 0; k < NCH; k = k + 1) begin
                last_raw[k]  <= {DW{1'b0}};
                still_cnt[k] <= {SCW{1'b0}};
                seen_r[k]    <= 1'b0;
            end
        end else begin
            // ⭐ `tare` 默认低（⭐ 它**只能是单周期脉冲** —— 见下）
            tare_o <= {N_ADC{1'b0}};

            // ⭐⭐ (a) 逐通道静止计数 —— ⭐ 每帧维护，⭐ 与状态无关
            //   ⚠️ 必须在 `case` **之前**（⭐ 否则 `ST_SWEEP` 里的 `enough_r`
            //      用的是上一拍的 `still_cnt`）
            if (sample_valid_i) begin
                last_raw[sample_ch_i]  <= sample_data_i;
                still_cnt[sample_ch_i] <= still_r
                    ? ((still_cnt[sample_ch_i] >= STILL_N) ? STILL_N
                                                           : (still_cnt[sample_ch_i] + 1'b1))
                    : {SCW{1'b0}};
                seen_r[sample_ch_i]    <= 1'b1;
            end

            case (state)
                // ── ⭐ WAIT：等霍尔供电稳定 ────────────────────────────────
                ST_WAIT: begin
                    if (delay_cnt == DELAY_CLK[DCW-1:0]) begin
                        state    <= ST_SWEEP;
                        cur_ch   <= 3'd0;
                        wait_cnt <= {WCW{1'b0}};   // ⭐ 每轴从 0 开始计时
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
                    // ⭐⭐ (b) ⭐ **真正的上界**：⭐ 每 `clk` 递增，⛔ 不依赖 `sample_valid_i`
                    //   ⚠️ 这就是"帧计数不是上界"的修法 —— 🔴 ADC 停流时帧计数
                    //      **永不到期** ⇒ ⚠️ 又变成"永远等"。
                    if (wait_cnt >= WAIT_N) begin
                        // ⭐ 超时 ⇒ **跳过该轴**（⛔ 不写它的零点）+ ⭐ 明确指示（⛔ 不静默）
                        skip_mask_o[cur_ch] <= 1'b1;
                        fail_o              <= 1'b1;
                        still_cnt[cur_ch]   <= {SCW{1'b0}};
                        wait_cnt            <= {WCW{1'b0}};
                        if (cur_ch == (NCH - 1)) begin
                            state  <= ST_DONE;
                            cur_ch <= 3'd0;
                        end else begin
                            cur_ch <= cur_ch + 3'd1;
                        end
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                        // ⭐⭐ (c) ⭐ **只有【静止确认】才捕获**
                        //   ⭐ `STILL_EN == 0` ⇒ ⭐ 关闭守卫（⭐ 保持旧行为，⭐ 只给既有 tb）
                        if (sample_valid_i && (sample_ch_i == cur_ch)
                            && ((STILL_EN == 0) || enough_r)) begin
                            tare_o   <= {N_ADC{1'b1}};   // ⭐ 所有片同拍（⭐ 锁步）
                            cal_ch_o <= cur_ch;
                            still_cnt[cur_ch] <= {SCW{1'b0}};
                            wait_cnt          <= {WCW{1'b0}};
                            //   ⭐ 本通道标完 ⇒ 推进；⭐ 全部标完 ⇒ DONE
                            if (cur_ch == (NCH - 1)) begin
                                state  <= ST_DONE;
                                cur_ch <= 3'd0;
                            end else begin
                                cur_ch <= cur_ch + 3'd1;
                            end
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
                        // ⭐⭐🔴 **必须清空静止计数** —— ⚠️ 否则 `'T'` 会**零延迟立即捕获**
                        //    （⭐ `still_cnt` 已饱和 ⇒ 判据当场满足）
                        //    ⇒ 🔴 **守卫在重标路径上【静默失效】**（⭐ 最隐蔽的坑）
                        //   ⭐ 同时清掉上一轮的失败指示 ⇒ ⭐ 本轮重新判定 ✅
                        for (k = 0; k < NCH; k = k + 1) still_cnt[k] <= {SCW{1'b0}};
                        wait_cnt    <= {WCW{1'b0}};
                        skip_mask_o <= {NCH{1'b0}};
                        fail_o      <= 1'b0;
                        state       <= ST_SWEEP;   // ⭐ `cur_ch` 已为 0 ⇒ ⭐ 从头标
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
    //   ⚠️⚠️ **除零守卫**：⭐ Verilog 的 `&&`/`||` **不保证短路求值**
    //      ⇒ ⚠️ 若在 `PARAM_OK` 里直接写 `WAIT_CLK / WAIT_MS`，
    //        `WAIT_MS = 0` 时会**在展开期除零**（⭐ 而不是被 `&&` 挡住）。
    //      ⭐ 所以先把除数落成一个**永不为 0** 的常量。
    localparam integer WAIT_DIV = (WAIT_MS > 0) ? WAIT_MS : 1;
    localparam PARAM_OK = (NCH > 0) && (N_ADC > 0) && (DELAY_CLK > 0)
                       && (WAIT_MS > 0) && (DW > 0) && (WAIT_CLK > 0)
                       && (WAIT_KHZ > 0) && (CLK_HZ > 0)
                       && ((WAIT_CLK / WAIT_DIV) == WAIT_KHZ)
                       && ((STILL_EN == 0) || (STILL_FRAMES > 0));

    initial begin
        if (NCH <= 0)
            $display("ERROR [calib_autotare] NCH = %0d <= 0 => no channel to calibrate. PARAM_OK=0.", NCH);
        if (N_ADC <= 0)
            $display("ERROR [calib_autotare] N_ADC = %0d <= 0 => tare_o is always 0, so calibration NEVER happens (silently). PARAM_OK=0.", N_ADC);
        if (DELAY_CLK == 0)
            $display("ERROR [calib_autotare] DELAY_CLK = 0 => calibration starts before the hall supply has settled, so the recorded zero point is WRONG. PARAM_OK=0.");
        // ⭐⭐ 2026-09-30 新增的自检
        if (WAIT_MS == 0)
            $display("ERROR [calib_autotare] WAIT_MS = 0 => the per-axis timeout expires immediately, so EVERY axis is skipped and no zero point is ever recorded (silently). PARAM_OK=0.");
        //   🔴🔴 **溢出探测器**（⭐ 2026-09-30 实测踩过：`WAIT_MS*CLK_HZ` 溢出 32 位
        //      ⇒ `WCW=1` ⇒ `WAIT_N=1` ⇒ ⭐ **每轴 1 拍就"超时"** ⇒ **一个 `tare` 都不发**）
        //      ⭐ 判据：⭐ 乘法结果**必须能反除回去**；⚠️ 回绕了就对不上。
        //      📌 有了它，这个坑**再犯就会被 tb 一眼看到**（⛔ 不再是静默的）。
        if ((CLK_HZ <= 0) || (WAIT_KHZ <= 0))
            $display("ERROR [calib_autotare] CLK_HZ = %0d => WAIT_KHZ = %0d <= 0, so the timeout cannot be computed. PARAM_OK=0.", CLK_HZ, WAIT_KHZ);
        if ((WAIT_MS > 0) && (WAIT_KHZ > 0) && ((WAIT_CLK / WAIT_DIV) != WAIT_KHZ))
            $display("ERROR [calib_autotare] WAIT_CLK = WAIT_MS(%0d) * WAIT_KHZ(%0d) = %0d OVERFLOWED 32 bits (reverse division gives %0d). Reduce WAIT_MS. PARAM_OK=0.",
                     WAIT_MS, WAIT_KHZ, WAIT_CLK, (WAIT_CLK / WAIT_DIV));
        if (WAIT_CLK <= 0)
            $display("ERROR [calib_autotare] WAIT_CLK = %0d <= 0 => the per-axis timeout is degenerate, so every axis is skipped without ever taring. PARAM_OK=0.", WAIT_CLK);
        if (DW <= 0)
            $display("ERROR [calib_autotare] DW = %0d <= 0 => the frame-to-frame delta has no width, so the still-guard can never be satisfied. PARAM_OK=0.", DW);
        if ((STILL_EN != 0) && (STILL_FRAMES <= 0))
            $display("ERROR [calib_autotare] STILL_EN != 0 but STILL_FRAMES = %0d <= 0 => the still-guard degenerates to a single frame. PARAM_OK=0.", STILL_FRAMES);
        if ((STILL_EN != 0) && (STILL_TOL == 0))
            $display("NOTE [calib_autotare] STILL_TOL = 0 => the still-guard requires bit-for-bit identical frames; a noisy axis will time out and be SKIPPED.");
        if (PARAM_OK)
            $display("NOTE [calib_autotare] PARAM_OK=1 (NCH=%0d N_ADC=%0d DELAY_CLK=%0d STILL_EN=%0d STILL_TOL=%0d STILL_FRAMES=%0d WAIT_MS=%0d CLK_HZ=%0d)",
                     NCH, N_ADC, DELAY_CLK, STILL_EN, STILL_TOL, STILL_FRAMES, WAIT_MS, CLK_HZ);
    end

endmodule

`default_nettype wire
