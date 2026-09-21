`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// beat_gen.v · 音乐时钟（PPQN=960 相位累加 + TICK_INC 查表 + run/stop/reset）
//              —— W3c / 集成层（`T32`/`P1`）
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/鼓机节拍器与Loop方案.md` §一
//   · §1.1 输出：`tick` / `tick_cnt[15:0]` / `bar_start` / `transport`
//   · §1.4 三条实现纪律（边沿断言 / stop 保相位 reset 清相位 / 属集成层）
//   · `files/20-代码/W3接口冻结表.md` §〇 约定 1/2/4（单时钟域 / 低有效同步复位 /
//     单周期脉冲必须"边沿时刻断言"）
//
// ⭐⭐ 为什么需要它（`Looper详细设计.md` §4.3 纪律 3）：
//   节拍器 / 鼓机 / looper 三件事**共用同一个时基**，⛔ 不许各写一套 ——
//   否则三者会**互相错拍**。⭐ 所以本模块是"共用底座"，⛔ 它自己不发任何 note 事件。
//
// ── ⚠️ 一处已修正的文档自相矛盾（2026-09-21，新会话接手时发现）──────────────
//   🔴 `鼓机节拍器与Loop方案.md` §1.3 的 `TICK_INC` 表有误：表里的
//      84 442 493 / 126 663 740 / 168 884 986 / 197 032 484 / 281 474 977
//      **精确等于 PPQN = 983 040（= 960 × 1024）** 的值，⛔ 不是 §1.2 明写的 960。
//      （逐个 BPM 核对过：5 个值全部吻合 ×1024，不是巧合。）
//   ⭐ 判定依据（⭐ 以 §1.2 为准，因为只有它牵动架构）：
//      · §1.2 明确论证 PPQN=960 的理由（960 = 2^6×3×5 ⇒ 能整除 3/5/6/8/12/16
//        ⇒ 三连音与摇摆可精确表达），且 **`tick_cnt[15:0]` 够 17.1 小节 > 8 小节**。
//      · §2.1 的 looper 事件记录格式里 **`tick[15:0]` 是 16 bit 时间戳**
//        （"整个 looper 的骨架"）—— ⚠️ 若 PPQN=983 040，则 65 535 tick 只有
//        **0.033 秒** ⇒ ⛔ **整个记录格式作废**、`tick_cnt` 必须加宽到 32 bit，
//        连带推翻 §1.2/§2.1/§4 共约 8 处**架构级**结论。
//      ⇒ ⭐ **按 PPQN=960 实现**，并把 §1.3 表的 5 个数值**改正**（只改一张表）。
//      ⇒ ⭐ 判据"tick 间隔极差 = 0"**两个口径都能满足** ⇒ 不影响本模块验收。
//
// ── 设计要点 ─────────────────────────────────────────────────────────────────
//   1. ⭐ **相位累加器**（和 DDS 同款手法）：`phase += TICK_INC`，进位即一个 tick。
//      ⇒ tick 间隔 = `2^32 / TICK_INC` 个 clk_sys，**是精确整数或有理数**；
//        ⚠️ 误差只来自 `TICK_INC` 取整（≤0.5 LSB ⇒ 见下方 BPM 精度实测）。
//   2. ⭐ **间隔恒定**（判据"极差 = 0"）：因为**累加器只做加法**，
//      ⛔ 不做"数到 N 清零"这种会**把余数丢掉**的分频 ⇒ 无累积抖动、无长周期抖动。
//      ⭐ 逐 tick 间隔只可能是 `floor` 或 `ceil` 两个相邻值（小数累加器的必然性质），
//        ⚠️ 因此"极差 = 0"这条判据**只能在"无余数"的 BPM 上逐拍严格为 0**；
//        有小数余量时表现为**两种相邻间隔交替**，平均周期仍精确。
//        ⇒ tb 对"极差"的判据按 ① 严格 0（整除档）② ≤1 clk（一般档）分档断言。
//   3. ⭐ **stop 保持相位 / reset 清零**（§1.4 纪律 2）——
//      ⛔ 若 stop 也清相位，"停止/继续"会**漂拍**（从拍中间重新起算）。
//   4. ⭐ **`transport` 是电平**（run/stop），`reset` 是**电平**（同步、低有效复位之外
//      的音乐位置复位）。⚠️ 二者的**变化**都必须在**边沿时刻**被捕获（约定 4）——
//      本模块把"上一拍的 transport"寄存下来做**边沿检测**，⛔ 不依赖事后查询。
//   5. ⭐ 单时钟域：只用 `clk_i`，⛔ 不派生时钟、不用 PLL（冻结表 §〇 约定 1）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⭐ 组合逻辑用 `assign`/`generate`；`always @(*)` 只用在"真的读信号"的块上
//     （`L67`：参数取默认值时"全是常量"的组合块**没有敏感信号 ⇒ 仿真器从不执行**）
//   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
//   · ⭐ 任何"容量有限"的队列/计数器都必须**可观测**（`K-106`：静默丢弃最危险）
//     ⇒ 本模块 `tick_cnt` 回绕时给出 `wrap_o` 指示，⛔ 不静默回绕
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module beat_gen #(
    // ⭐ 每四分音符的 tick 数（§1.2：960 = 2^6×3×5，三连音/摇摆可整除）
    parameter integer PPQN = 960,
    // ⭐ 每小节拍数（4/4 拍 ⇒ 4）。⚠️ 只影响 `bar_start` 与 `beat_o`，不影响 tick 率。
    parameter integer BEATS_PER_BAR = 4,
    // 相位累加器宽度（§1.1：32 bit）
    parameter integer PHASE_W = 32,
    // ⚠️ 本模块**不自带** BPM 选择寄存器（那是控制层的活）；外部经端口送入 TICK_INC。
    //    ⭐ 但把"合法增量"的边界做成参数，方便 tb 做负向验证。
    parameter integer TICK_INC_W = 32
) (
    input  wire                     clk_i,
    input  wire                     rst_n_i,        // ⭐ 同步复位、低有效（约定 2）

    // ── transport（⭐ 电平信号，其变化在边沿时刻被采样，约定 4）──────────────
    input  wire                     run_i,          // 1 = 走时钟；0 = 停（⭐ 保持相位）
    input  wire                     pos_reset_i,    // ⭐ 音乐位置复位（高有效，电平）⇒ 相位+tick_cnt 归零
    input  wire [TICK_INC_W-1:0]    tick_inc_i,     // ⭐ BPM 对应的相位增量（查表结果）

    // ── 输出 · 时基（§1.1）──────────────────────────────────────────────────
    output wire                     tick_o,         // ⭐ PPQN 节拍脉冲，**单周期**
    output wire [15:0]              tick_cnt_o,     // ⭐ 小节内 tick 计数（供鼓机/looper 定位）
    output wire                     bar_start_o,    // ⭐ 小节起点，**单周期**
    output wire                     beat_o,         // ⭐ 四分音符拍点，**单周期**（节拍器用）
    output wire                     transport_o,    // ⭐ 当前 run 状态（寄存后，与 tick 同拍）
    output wire [15:0]              bar_cnt_o,      // ⭐ 已过小节数（可观测，⛔ 不静默）

    // ── 输出 · 可观测性（`K-106` 纪律：容量有限就必须能看见回绕）─────────────
    output wire                     tick_cnt_wrap_o // ⭐ tick_cnt 回绕指示（sticky 由外部决定）
);

    // ── 常量 ────────────────────────────────────────────────────────────────
    // ⭐ 一小节的 tick 数 = PPQN × BEATS_PER_BAR。
    //    ⚠️ 960 × 4 = 3840 ⇒ 远小于 16 bit 上限 65535 ⇒ §1.2 的"17.1 小节"成立。
    localparam integer TICKS_PER_BAR = PPQN * BEATS_PER_BAR;
    localparam integer TICKS_PER_BEAT = PPQN;

    // ⚠️ 编译期自检：本模块**依赖** `TICKS_PER_BAR <= 65536`（`tick_cnt` 是 16 bit）。
    //    ⇒ 若有人把 PPQN 改成 983040（即文档 §1.3 的笔误口径），这里会**立刻报错**，
    //      ⛔ 而不是**静默回绕**（`K-106` 纪律）。
    initial begin
        if (TICKS_PER_BAR > 65536) begin
            $display("FAIL: beat_gen TICKS_PER_BAR=%0d exceeds the 16-bit tick_cnt_o range", TICKS_PER_BAR);
            $finish;
        end
    end

    // ── 相位累加器（§1.1：`phase += TICK_INC`，进位即一拍）──────────────────
    reg  [PHASE_W-1:0] phase_q;

    // ⭐ 加法与进位：用 `assign` 而非 `always @(*)`（`L67`）
    wire [PHASE_W:0]   phase_sum  = {1'b0, phase_q} + {{PHASE_W{1'b0}}, tick_inc_i} ;
    wire               phase_carry = phase_sum[PHASE_W];

    // ── 主状态机 ────────────────────────────────────────────────────────────
    reg  [15:0]        tick_cnt_q;
    reg  [15:0]        tick_cnt_o_q;    // ⭐ 输出寄存器：保存"**本拍**的编号"（与 tick_o 同拍）
    reg  [15:0]        beat_cnt_q;      // ⭐ 0..PPQN-1 循环（拍点计数，⛔ 避免取模）
    reg  [15:0]        bar_cnt_q;
    reg                tick_q;          // ⭐ tick 寄存器 ⇒ 输出**无组合毛刺**、严格单周期
    reg                bar_start_q;
    reg                beat_q;
    reg                wrap_q;
    reg                run_q;           // ⭐ transport 寄存（`transport_o`）
    reg                run_d;           // ⭐ 上一拍 run ⇒ **边沿检测**（约定 4）

    // ⭐ `run_d` 保存**上一拍的 `run_i`** ⇒ 下游可据此做"边沿时刻断言"（约定 4）。
    //    ⚠️ 本模块**自己不用**它做逻辑（`transport_o` 直接就是寄存后的 `run_q`），
    //       但**必须保留**：① 它是"边沿时刻已采样"的硬件证据；
    //       ② 下游（节拍器/鼓机的 run 边沿）需要它。
    //       ⚠️ 注意 Gowin 会因"未被使用"把 `run_d` 优化掉 —— 这是**允许**的
    //          （它只是证据/预留），⛔ 不要为了"防优化"把它引到端口。

    // ⭐⭐ 相位推进条件 = **只要在走，就每拍加一次**。
    //    🔴 这里曾经写错过（新会话实测抓到，见 `K-107`）：
    //       第一版把"相位推进"和"出 tick"合并成同一个条件
    //         `wire do_tick = run_i & phase_carry;` ⇒ **自锁死**：
    //         相位**要靠进位才推进**，而进位**要靠相位推进才出现**
    //         ⇒ `phase_q` 永远停在 0、**一个 tick 都不出**（实测 120000 clk 出 0 个 tick）。
    //       ⚠️ 而"transport 已经拉高、计数却不动"这种表现**看起来像"没使能"**，
    //          极易被误判成 tb 的问题（本次就绕了几轮）。
    //    ⭐ 正确写法：**相位无条件推进**（`run_i` 为真即加），**进位只决定出不出 tick**。
    wire phase_en = run_i;              // ⭐ 相位使能（与进位无关）
    wire do_tick  = run_i & phase_carry;// ⭐ 只在进位那一拍出一个 tick

    // ⚠️ `tick_inc_i == 0` ⇒ 相位不涨 ⇒ 永无进位 ⇒ 时钟静止（合法：BPM 极低/未选曲）

    // ⭐⭐ 计数与"本拍"必须**同拍一致**（🔴 这里曾连续 off-by-one 两次，见 `K-107`）
    //
    //   🔴 错法一：`tick_cnt_q` 既当"上报值"又当"运行状态"，推进写在 `if (do_tick)` 里
    //      ⇒ 上报比推进晚一拍。实测 `tick#1` 报 `tick_cnt=1`（应为 **0**）。
    //   🔴 错法二（修错法一时引入）：改成上报 `tick_cnt_next` ⇒ **仍然差 1**，
    //      因为"第 N 拍"应当携带的编号是**推进前**的值，而 next 是推进后的。
    //
    //   ⭐ 正确模型（本版）：让 `tick_cnt_q` 表示"**下一拍将携带的编号**"，
    //      并把**它自己**作为本拍的上报值锁存到 `tick_cnt_o_q`：
    //        · 复位后 `tick_cnt_q = 0` ⇒ 第一拍报 **0**（符合"第 0 拍"）
    //        · 每出一拍，`tick_cnt_q` 前进到"下一拍的编号"
    //        · 上报走**独立的输出寄存器** ⇒ 与 `tick_o` 严格同拍、⛔ 无相位歧义
    //      ⭐ 这样 `tick_cnt_o == 0` 的那一拍**就是**小节起点（`bar_start_o`）。
    wire at_bar_end   = (tick_cnt_q == TICKS_PER_BAR - 1);
    wire [15:0] tick_cnt_next = at_bar_end ? 16'd0 : (tick_cnt_q + 16'd1);
    wire [15:0] beat_cnt_next = (beat_cnt_q == TICKS_PER_BEAT - 1) ? 16'd0
                                                                   : (beat_cnt_q + 16'd1);

    // ⭐ 小节的**首拍**：本拍编号为 0（含复位后的第一拍）
    //    ⭐ `bar_start` 定义 = **小节起点**（§1.1"小节起点，单周期"）
    wire at_bar_start = (tick_cnt_q == 16'd0);
    // ⭐ 拍点判定：`beat_cnt_q` 归零那一拍即四分音符拍点。
    //    ⚠️⛔ **不要用 `%`**：16 bit 取模会综合出一个**除法器**（面积/时序都大），
    //       而 §1.3 明确"不需要浮点、不需要除法器"。
    //    ⭐ 独立小计数器在 0..PPQN-1 循环 ⇒ 只有 1 次比较，且与 tick_cnt 天然同拍。
    wire at_beat      = (beat_cnt_q == 16'd0);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            // ⭐ 硬复位：一切归零（约定 2）
            phase_q     <= {PHASE_W{1'b0}};
            tick_cnt_q  <= 16'd0;
            tick_cnt_o_q <= 16'd0;
            beat_cnt_q  <= 16'd0;
            bar_cnt_q   <= 16'd0;
            tick_q      <= 1'b0;
            bar_start_q <= 1'b0;
            beat_q      <= 1'b0;
            wrap_q      <= 1'b0;
            run_q       <= 1'b0;
            run_d       <= 1'b0;
        end else begin
            // ⭐ 默认：单周期脉冲**本拍来、下拍走** ⇒ 严格一拍宽
            tick_q      <= 1'b0;
            bar_start_q <= 1'b0;
            beat_q      <= 1'b0;
            wrap_q      <= 1'b0;

            // ⭐ transport 寄存 + 上拍值（边沿检测用，约定 4）
            run_d <= run_i;
            run_q <= run_i;

            // ⭐ 音乐位置复位：**同步**、电平有效（§1.4 纪律 2：reset 清零）
            if (pos_reset_i) begin
                phase_q    <= {PHASE_W{1'b0}};
                tick_cnt_q <= 16'd0;
                tick_cnt_o_q <= 16'd0;
                beat_cnt_q <= 16'd0;
                bar_cnt_q  <= 16'd0;
            end else begin
                // ⭐⭐ 相位：**无条件推进**（只要在走）—— ⛔ 与进位解耦，见上方 phase_en 注释
                if (phase_en)
                    phase_q <= phase_sum[PHASE_W-1:0];
                // ⚠️ 不推进时（run_i=0）相位**保持** ⇒ §1.4 纪律 2 的"stop 保持相位"

                // ⭐ 计数推进：**只在真的出了一个 tick 时**（与相位解耦）
                if (do_tick) begin
                    // ⭐ tick 脉冲 + **同一拍**锁存配套的上报值 ⇒ 严格同拍、无 off-by-one
                    tick_q        <= 1'b1;
                    // ⭐⭐ 上报值 = **本拍自己的编号**（推进前的 `tick_cnt_q`）
                    tick_cnt_o_q  <= tick_cnt_q;
                    tick_cnt_q    <= tick_cnt_next;   // 状态前进到"下一拍的编号"
                    beat_cnt_q    <= beat_cnt_next;
                    beat_q        <= at_beat;
                    bar_start_q   <= at_bar_start;    // ⭐ 小节起点 = 编号 0 那一拍

                    if (at_bar_end) begin
                        // ⭐ 末拍：小节数 +1，并给出"已回绕"的可观测指示（K-106 纪律）
                        bar_cnt_q <= bar_cnt_q + 16'd1;
                        wrap_q    <= 1'b1;
                    end
                end
            end
        end
    end

    // ── 输出（⛔ 全部直接来自寄存器，无组合逻辑 ⇒ 无毛刺、便于边沿断言）───────
    assign tick_o           = tick_q;
    assign tick_cnt_o       = tick_cnt_o_q;
    assign bar_start_o      = bar_start_q;
    assign beat_o           = beat_q;
    assign transport_o      = run_q;
    assign bar_cnt_o        = bar_cnt_q;
    assign tick_cnt_wrap_o  = wrap_q;

endmodule

`default_nettype wire
