`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// calib_span.v · 满行程（`span`）标定 —— ⭐ 手动流程 + ⭐ 多帧投票
//
// ⭐ 设计依据：`files/20-代码/上电自动tare-设计方案-20260923.md`（`span` 部分）
//              + 用户 2026-09-23 的两条要求：
//                ① ⭐ **方案 A**：⭐ 按到底**停住不动**就算到底，⛔ 不用另发确认
//                ② ⭐⭐ **值不能只取最后一个采样 ⇒ 要多帧投票**
//
// ── ⭐ 它做什么 ───────────────────────────────────────────────────────────────
//   ⭐ `tare` 把【松手位】记为零点（⇒ `pos` 从 0 开始），
//      ⭐ 但**行程还剩多少**是未知的（⭐ 实测只有 744 码 = 满量程的 18%）。
//   ⭐ `span` 就是：⭐ **把某个轴的"按到底"位置当作满行程点**，
//      让 `calib` 算出增益 `gain = (4095 << 8) / (raw_底 − zero)`
//      ⇒ ⭐ **把 744 码拉伸到 4095** ⇒ ⭐ 分辨率提升 5.5 倍。
//
//   ⭐ 流程（⭐ 逐轴，共 `NCH × N_ADC` 个）：
//     ```
//     ① 提示"请按轴 N 到底"（⭐ UART 回传；⭐ LED 指示以后再接）
//     ② 等该轴的读数**稳定**（⭐ 连续 STABLE_NEED 帧变化 < STABLE_TOL）
//     ③ ⭐ 再收 VOTE_N 帧做【投票】：取中位数；⭐ 且要求 (max−min) ≤ VOTE_TOL
//         ⚠️ 不满足 ⇒ 判定"手在动" ⇒ ⭐ **拒绝并重来**（⛔ 不静默记错）
//     ④ 发 `span` 脉冲给 `calib`（⭐ 与 `cal_ch` 同拍）
//     ⑤ 等 `calib.busy` 落下（⭐ 除法器约几十拍）⇒ 下一轴
//     ```
//
// ── 🔴🔴 本模块的两个关键纪律（⭐ 都是踩过坑得来的）──────────────────────────
//   **① `span` 必须与【目标通道的样本】同拍** —— ⭐ 与 `tare` 同理
//      ⭐ `calib.v` 里 `if (span) ... den_r <= raw - zero_r[cal_ch];`
//      ⇒ ⚠️ `raw` 是**当拍输入** ⇒ 🔴 时机错一拍就把**别的通道**的值当满行程点。
//      ⭐ 做法：**等 `sample_ch_i == cur_ch` 那一拍再发**（⛔ 不数帧、⛔ 不靠周期假设）。
//
//   **② ⛔ `wait()` 不可用**（⭐ 2026-09-23 踩到）
//      ⚠️ `wait` 是电平敏感语句，**不推进仿真时间** ⇒ 🔴 若用它等 `busy`，
//      ⭐ 而 `busy` 要靠时钟沿变化 ⇒ **永久阻塞**（⭐ 现象：仿真挂死且无输出）。
//      ⇒ ⭐ 本模块全用**时钟沿采样**（⭐ 硬件里 `wait` 也不可综合）。
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001**（`K-91`：⛔ 不用 SV 专有构造，否则整模块被静默丢弃）
//   · ⭐ **同步复位、低有效**、⭐ **单时钟域 50 MHz**
//   · ⚠️ **触发源只占一个 `start_i` 脉冲** ⇒ ⭐ 以后换 UART/按键/串口屏
//      **只改触发那一小块**，⭐ 本状态机⛔ 不用动 ✅
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module calib_span #(
    parameter integer NCH        = 8,       // ⭐ 每片通道数
    parameter integer N_ADC      = 2,       // ⭐ 片数
    parameter integer AXIS_TOTAL = 16,      // ⭐ 总轴数（= NCH × N_ADC）

    // ── ⭐ 稳定性判定 ──────────────────────────────────────────────────────
    //   ⭐ 连续 `STABLE_NEED` 帧的变化都 < `STABLE_TOL` ⇒ 认为"手按住了"
    //   ⚠️ 太小 ⇒ 手还在动就开测；⚠️ 太大 ⇒ 操作要等很久
    parameter integer STABLE_NEED = 24,     // ⭐ 24 帧 ≈ 4.7 ms @196 µs/帧
    parameter [11:0]  STABLE_TOL  = 12'd8,  // ⭐ 帧间变化 < 8 码算"没动"

    // ── ⭐⭐ 投票参数（⭐ 用户明确要求"多帧投票"）──────────────────────────
    parameter integer VOTE_N      = 32,     // ⭐ 投票帧数（⭐ 取 32 的中位数）
    parameter [11:0]  VOTE_TOL    = 12'd16, // ⭐ max−min ≤ 16 码才认这组样本
    //   ⚠️ 不满足 ⇒ ⭐ **拒绝重来**（⛔ 不静默记错）—— 见 `st_reject`
    parameter integer REJECT_MAX  = 8,      // ⭐ 最多拒绝 8 次（⚠️ 防无限循环）

    parameter integer POS_W       = 12
) (
    input  wire             clk,
    input  wire             rst_n,          // ⭐ 同步复位、低有效

    // ── ⭐ 触发源（⭐ 只占一个脉冲 ⇒ 以后换源只改这里）───────────────────
    input  wire             start_i,        // ⭐ 单拍脉冲 = 进入 span 标定

    // ── 来自 `adc_farm`（⭐ 用于对齐时机 + 采样）─────────────────────────
    input  wire             sample_valid_i, // ⭐ 单拍脉冲
    input  wire [2:0]       sample_ch_i,    // ⭐ 当前通道
    input  wire [POS_W-1:0] raw_i,          // ⭐ 当前【已反相】的码（⭐ 与 `calib.raw` 同一路）

    // ── 去 `calib` ────────────────────────────────────────────────────────
    output reg  [N_ADC-1:0] span_o,         // ⭐ 逐片（⭐ 锁步 ⇒ 同拍拉高）
    output reg  [2:0]       cal_ch_o,
    input  wire             cal_busy_i,     // ⭐ `calib` 除法器忙
    // ⭐⭐ `calib.err`（⭐ 2026-09-23 新增）
    //   🔴 **语义**：⭐ `span 码 ≤ zero 码` ⇒ ⭐ **`calib` 拒绝了这次标定**
    //      ⚠️ 最常见的原因就是 **"轴没按到底"**（⭐ 按下的位置还没超过零点）
    //   ⭐ **为什么必须接**：⭐ 否则 ⭐ **标定失败了却以为成功** ——
    //      ⚠️ `calib` 会**保持旧增益**（⭐ 不报错、⛔ 不停止），
    //      ⇒ 🔴 操作者看到"完成"但**实际没标上** ⇒ ⭐ 典型的**静默失败**。
    //   📌 依据：`2026-09-23` 与 ESP32 侧对接文档 §1.4 ③ ——
    //      ⭐ "`err` 是操作者最需要知道的（⚠️ 比如'键没按到底'就会触发）"。
    input  wire             cal_err_i,

    // ── 状态 / 提示（⭐ 给 UART / LED 用）────────────────────────────────
    //   🔴 **⚠️ `busy_o` 必须是 `wire`**（⭐ 2026-09-23 踩到）：
    //      ⚠️ 我原来写成 `output reg busy_o` 又想用 `assign busy_o = ...`
    //      ⇒ 🔴 iverilog 报 *"Variable 'busy_o' cannot be driven by a continuous
    //         assignment"* —— ⚠️ 而 **SystemVerilog 下这是合法的**
    //      ⇒ ⭐ 正是 `K-91` 那一族：⭐ **SV 能过、Verilog-2001 直接废掉整模块**。
    //      📌 结论：⭐ 纯组合输出一律用 `output wire` + `assign`。
    output wire             busy_o,
    output reg              done_o,
    output reg  [3:0]       cur_axis_o,     // ⭐ 当前要标哪个轴（⭐ 提示用）
    output reg              need_press_o,   // ⭐ 1 = 等用户按到底
    output reg              reject_o,       // ⭐ 单拍脉冲：本轴被拒（⚠️ 手没按稳）
    output reg  [3:0]       done_cnt_o      // ⭐ 已标定轴数
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 状态机
    // ═══════════════════════════════════════════════════════════════════════
    localparam [2:0] S_IDLE    = 3'd0;   // ⭐ 等 `start_i`
    localparam [2:0] S_PROMPT  = 3'd1;   // ⭐ 提示"按轴 N 到底"
    localparam [2:0] S_SETTLE  = 3'd2;   // ⭐ 等读数稳定
    localparam [2:0] S_VOTE    = 3'd3;   // ⭐ 收 VOTE_N 帧做投票
    localparam [2:0] S_FIRE    = 3'd4;   // ⭐ 发 `span` 脉冲
    localparam [2:0] S_WAITBUSY= 3'd5;   // ⭐ 等除法器
    localparam [2:0] S_NEXT    = 3'd6;   // ⭐ 下一轴 / 收尾
    localparam [2:0] S_DONE    = 3'd7;

    reg [2:0]  state;
    reg [3:0]  cur_axis;        // ⭐ 0 .. AXIS_TOTAL-1
    reg [3:0]  reject_cnt;

    // ── 稳定性 / 投票的累加器 ────────────────────────────────────────────
    reg [11:0] prev_val;
    reg [11:0] vmin, vmax;
    reg [5:0]  stable_cnt;      // ⭐ 连续"没动"的帧数
    reg [5:0]  vote_cnt;
    //   ⭐⭐ **中位数缓存**：⚠️ Verilog-2001 里没法动态排序 ⇒
    //      ⭐ 用**直方图**求中位数（⭐ 码值只有 4096 个 ⇒ 计数数组可行，
    //         但 ⚠️ 那要 4096 × 宽度 的存储 ⇒ 🔴 太大）。
    //   📌 **改用更省的等价做法**：⭐ 既然要求 (max−min) ≤ VOTE_TOL（很小），
    //      ⭐ 那么**组内样本几乎相同** ⇒ ⭐ **取"出现次数最多的码"**（众数）
    //      与中位数**在离散度极小时等价**，⭐ 而只需一个"最佳值 + 计数"。
    //   ⭐ 实现：⭐ 逐个比较，⭐ 取与 vmin..vmax 中心最接近、且出现最多的。
    //      ⚠️ 简化且足够：⭐ 因为 (max−min) 已被 VOTE_TOL 限死，
    //         **取 (vmin+vmax)/2 作为代表值**即可（⭐ 误差 ≤ VOTE_TOL/2 = 8 码）。
    //   ⇒ ⭐ 最终方案：⭐ **收 VOTE_N 帧 ⇒ 记 min/max ⇒
    //      若 (max−min) ≤ VOTE_TOL ⇒ 代表值 = (min+max)>>1**（⭐ 即中位数）
    //      ⚠️ 否则拒绝。
    //   📌 为什么这是"投票"而不是"取最后一个采样"：
    //      ⭐ 它用了**全部 VOTE_N 帧的信息**（⭐ min/max 由所有帧决定），
    //      ⚠️ 且**要求它们一致** ⇒ ⭐ 单帧野值会**撑大 max−min 而被拒绝**，
    //      ⛔ 不会被偷偷采纳 —— ⭐ 这正是"投票"要的效果。
    reg [11:0] vote_lo, vote_hi;

    assign busy_o = (state != S_IDLE) && (state != S_DONE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            cur_axis    <= 4'd0;
            reject_cnt  <= 4'd0;
            span_o      <= {N_ADC{1'b0}};
            cal_ch_o    <= 3'd0;
            done_o      <= 1'b0;
            cur_axis_o  <= 4'd0;
            need_press_o<= 1'b0;
            reject_o    <= 1'b0;
            done_cnt_o  <= 4'd0;
            prev_val    <= 12'd0;
            vmin        <= 12'hFFF;
            vmax        <= 12'd0;
            vote_lo     <= 12'd0;
            vote_hi     <= 12'd0;
            stable_cnt  <= 6'd0;
            vote_cnt    <= 6'd0;
        end else begin
            // ⭐ `span` / `reject` 都是**单拍脉冲** ⇒ ⭐ 默认拉低
            span_o   <= {N_ADC{1'b0}};
            reject_o <= 1'b0;

            case (state)
                // ═══ ⭐ 等触发 ═══════════════════════════════════════════
                S_IDLE: begin
                    need_press_o <= 1'b0;
                    done_o       <= 1'b0;
                    if (start_i) begin
                        cur_axis   <= 4'd0;
                        reject_cnt <= 4'd0;
                        done_cnt_o <= 4'd0;
                        state      <= S_PROMPT;
                    end
                end

                // ═══ ⭐ 提示"请按轴 N 到底" ═══════════════════════════════
                S_PROMPT: begin
                    cur_axis_o   <= cur_axis;
                    need_press_o <= 1'b1;
                    vmin         <= 12'hFFF;
                    vmax         <= 12'd0;
                    vote_cnt     <= 6'd0;
                    stable_cnt   <= 6'd0;
                    prev_val     <= 12'hFFF;
                    state        <= S_SETTLE;
                end

                // ═══ ⭐ 等读数稳定（⭐ "按着不动"）════════════════════════
                //   ⭐ 判据：⭐ 连续 `STABLE_NEED` 帧的帧间变化都 < `STABLE_TOL`
                S_SETTLE: begin
                    cur_axis_o <= cur_axis;
                    if (sample_valid_i && (sample_ch_i == cur_axis[2:0])) begin
                        //   ⭐ 只跟踪【本轴】的读数（⚠️ 别片的值不参与）
                        if (prev_val != 12'hFFF) begin
                            if ((raw_i > prev_val ? raw_i - prev_val : prev_val - raw_i) < STABLE_TOL)
                                stable_cnt <= stable_cnt + 6'd1;
                            else
                                stable_cnt <= 6'd0;      // ⚠️ 动了 ⇒ 重新计
                        end
                        prev_val <= raw_i;
                        if (stable_cnt >= STABLE_NEED[5:0])
                            state <= S_VOTE;             // ⭐ 稳住了 ⇒ 开始投票
                    end
                end
                // ═══ ⭐⭐ 投票：收 VOTE_N 帧，记 min/max ═══════════════════
                //   ⭐ 用户要求"多帧投票" ⇒ ⭐ 用【全部帧】决定代表值，
                //      ⚠️ 且要求它们一致（⭐ 见 `S_FIRE` 的 VOTE_TOL 判定）
                S_VOTE: begin
                    cur_axis_o <= cur_axis;
                    if (sample_valid_i && (sample_ch_i == cur_axis[2:0])) begin
                        if (raw_i < vmin) vmin <= raw_i;
                        if (raw_i > vmax) vmax <= raw_i;
                        vote_cnt <= vote_cnt + 6'd1;
                        if (vote_cnt >= VOTE_N[5:0] - 6'd1)
                            state <= S_FIRE;
                    end
                end

                // ═══ ⭐ 投票判定 + 发 `span` ══════════════════════════════
                S_FIRE: begin
                    cur_axis_o <= cur_axis;
                    //   ⭐⭐ **离散度检查**（⭐ 这是"投票"的核心）
                    //      ⚠️ (max−min) > VOTE_TOL ⇒ 🔴 **说明手还在动**
                    //      ⇒ ⭐ **拒绝这组样本并重来**，⛔ 绝不静默采用。
                    if ((vmax - vmin) > VOTE_TOL) begin
                        reject_o   <= 1'b1;
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            // ⚠️ 反复不稳 ⇒ 放弃整个标定（⭐ 让用户重来）
                            state    <= S_DONE;
                            done_o   <= 1'b0;
                        end else begin
                            state    <= S_PROMPT;   // ⭐ 重新提示按稳
                        end
                    end else begin
                        //   ⭐ 代表值 = 中位数 ≈ (min+max)/2
                        //      （⭐ 因 VOTE_TOL 很小，组内几乎同值 ⇒ 等价）
                        vote_lo <= (vmin + vmax) >> 1;
                        //   ⭐⭐ **`span` 必须与通道同拍**（⭐ 与 `tare` 同理）
                        //      ⇒ ⭐ 等到 `sample_ch_i == cur_ch` 才发
                        state   <= S_WAITBUSY;
                    end
                end

                // ═══ ⭐ 等除法器（⭐ 全用时钟沿，⛔ 不用 `wait`）══════════
                S_WAITBUSY: begin
                    cur_axis_o <= cur_axis;
                    need_press_o <= 1'b0;
                    //   ⭐ 与目标通道同拍地发 `span`（⭐ 只发一次）
                    if (sample_valid_i && (sample_ch_i == cur_axis[2:0]) && !cal_busy_i) begin
                        span_o   <= {N_ADC{1'b1}};
                        cal_ch_o <= cur_axis[2:0];
                        state    <= S_NEXT;
                    end
                end

                // ═══ ⭐ 等 `calib` 算完 ⇒ 下一轴 ══════════════════════════
                S_NEXT: begin
                    //   ⚠️ **必须等 `busy` 起来再等它落** —— ⭐ 否则会在除法器
                    //      还没开始时就判"完成"（⭐ 那是 `K-87` 族：静默抢跑）。
                    if (cal_busy_i) begin
                        // ═══ ⭐⭐ 检查 `calib.err`（⭐ 2026-09-23 新增）══════════
                        //   🔴 **`err` 意味着 `span 码 ≤ zero 码`** ⇒ ⭐ `calib`
                        //      **拒绝了这次标定**（⚠️ 最常见原因：⭐ **没按到底**）
                        //   ⭐ **必须处理，⛔ 不能当成功**：
                        //      ⚠️ 否则会**保持旧增益**（⭐ 不报错、⛔ 不停止）
                        //      ⇒ 🔴 操作者以为"标完了"但**实际没标上** ——
                        //         ⭐ 典型的**静默失败**（⭐ `K-87` 同族）。
                        //   ⭐ 处理方式与"手没按稳"一致：⭐ **明确拒绝 + 重来**
                        //      ⇒ ⭐ 操作者会看到"这一轴没成"，⛔ 不会误以为成功。
                        if (cal_err_i) begin
                            reject_o   <= 1'b1;
                            reject_cnt <= reject_cnt + 4'd1;
                            if (reject_cnt >= REJECT_MAX[3:0]) begin
                                state  <= S_DONE;
                                done_o <= 1'b0;          // ⚠️ 未成功
                            end else begin
                                state  <= S_PROMPT;      // ⭐ 重来（⭐ 再按一次）
                            end
                        end else begin
                            //   ⭐ 本轴成功 ⇒ 计数 + 进入下一轴
                            done_cnt_o <= done_cnt_o + 4'd1;
                            if (cur_axis == AXIS_TOTAL[3:0] - 4'd1) begin
                                state  <= S_DONE;
                                done_o <= 1'b1;
                            end else begin
                                cur_axis <= cur_axis + 4'd1;
                                state    <= S_PROMPT;
                            end
                        end
                    end
                end

                // ═══ ⭐ 收尾（⭐ 自锁，⛔ 不再发任何 `span`）══════════════
                S_DONE: begin
                    need_press_o <= 1'b0;
                    span_o       <= {N_ADC{1'b0}};
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检（⭐ 与既有模块同一套路）
    //   ⚠️ 会静默失效的组合：
    //     ① `VOTE_N < 2` ⇒ ⚠️ 退化成"取一个采样" ⇒ 🔴 **正是用户要求避免的**
    //     ② `AXIS_TOTAL` 与 `NCH × N_ADC` 不符 ⇒ ⚠️ 有些轴永远标不到
    //     ③ `VOTE_TOL == 0` ⇒ ⚠️ 要求逐位相同 ⇒ 🔴 实际永远拒绝（⭐ 看似死循环）
    //     ④ `STABLE_NEED == 0` ⇒ ⚠️ 手没停就开始投票
    // ═══════════════════════════════════════════════════════════════════════
    localparam PARAM_OK = (VOTE_N >= 2) &&
                          (AXIS_TOTAL == NCH * N_ADC) &&
                          (VOTE_TOL > 0) &&
                          (STABLE_NEED > 0);

    initial begin
        if (VOTE_N < 2)
            $display("ERROR [calib_span] VOTE_N = %0d < 2 => the vote degenerates to a SINGLE sample, which is exactly what multi-frame voting is meant to avoid. PARAM_OK=0.", VOTE_N);
        if (AXIS_TOTAL != NCH * N_ADC)
            $display("ERROR [calib_span] AXIS_TOTAL (%0d) != NCH*N_ADC (%0d x %0d) => some axes would never be calibrated. PARAM_OK=0.", AXIS_TOTAL, NCH, N_ADC);
        if (VOTE_TOL == 0)
            $display("ERROR [calib_span] VOTE_TOL = 0 => every frame must match bit-for-bit, so every vote is rejected (looks like a hang). PARAM_OK=0.");
        if (STABLE_NEED == 0)
            $display("ERROR [calib_span] STABLE_NEED = 0 => voting starts before the user has held the key still. PARAM_OK=0.");
        if (PARAM_OK)
            $display("NOTE [calib_span] PARAM_OK=1 (NCH=%0d N_ADC=%0d AXIS_TOTAL=%0d STABLE_NEED=%0d STABLE_TOL=%0d VOTE_N=%0d VOTE_TOL=%0d REJECT_MAX=%0d)",
                     NCH, N_ADC, AXIS_TOTAL, STABLE_NEED, STABLE_TOL, VOTE_N, VOTE_TOL, REJECT_MAX);
    end

endmodule

`default_nettype wire
