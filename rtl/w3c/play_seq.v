`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// play_seq.v · 曲谱播放器（按 tick 吐事件 + 处理换速）—— W3c（`U-18`）
//
// ⭐ 契约见 `files/20-代码/play_seq接口冻结契约.md`（⭐ 本文件必须与它一致）
//
// ── 它解决什么问题 ───────────────────────────────────────────────────────────
//   ⭐ 事件流（`events.hex`）里每条事件带的是 **tick（音乐时间）**，⛔ 不是绝对时间。
//   ⭐ 节拍由【硬件】`beat_gen` 产生 ⇒ ⭐ PC 只负责"把谱子搬进去"，⛔ 不参与计时。
//   ⇒ 本模块 = "**按音乐位置把事件放出来**"。
//
//   ⭐⭐ 为什么节拍必须由硬件产生（⛔ 不能让 PC 按真实时间发）：
//     ⚠️ PC 的抖动会**直接变成音频抖动**，🔴 违反"延迟要确定性上界"。
//
// ── 🔴🔴 本版修的两个【真缺陷】（⚠️ 都是实测发现的，⛔ 不是预防性重构）──────
//
//   **缺陷 1：从来不看事件的 `tick` 字段 ⇒ 和弦变琶音**
//     ⚠️ 旧版：`wire take = run_i & tick_i & evt_valid_i;`
//        —— ⭐ 只问"缓冲区有没有数据"，⛔ **不问"这条是哪一拍"**。
//        ⚠️ 而 `TICK_SH` 在整个文件里**只出现一次**（它自己的声明）⇒ 从未被解码。
//     🔴 后果：**每个 tick 只取一条** ⇒ 一 tick 上的 N 条事件被摊到 N 个 tick。
//        ⭐ 实测三个真实谱子：**一个 tick 上最多 24 条**（和弦）
//        ⇒ @168 BPM 时 **24 条要摊 24 个 tick = 8.56 ms** ⇒ 🔴 **和弦被拉成琶音**。
//        ⚠️ 而一个 tick 有 **18601 clk**，余量 **775 倍** —— ⛔ 不是性能问题，是漏了。
//     ⭐ 修法：维护**本地音乐位置** `cur_tick_r`，⭐ **事件的 tick ≤ 当前位置才发**，
//        ⇒ 同一个 tick 的全部事件在**该 tick 内连续发完**（⛔ 不推迟到下一拍）。
//
//   **缺陷 2：`valid` 与它的数据没有【同拍锁存】**（⭐ 与经验库 `80 号` 同族）
//     ⚠️ 旧版：`note_valid_o` 是**寄存器**（由 `evt_rd_o` 派生），
//        而 `note_data_o = evt_data_i` 是**组合直通**。
//     🔴 后果：`valid` 有效那一拍，数据已经是**调用方推进后的下一条**
//        ⇒ ⚠️ **"计数是对的、输出却是错的"**（⭐ 现象极难查）。
//     ⭐ 修法：把 `evt_data_i` **在发出 `evt_rd_o` 的同一拍锁存**到 `note_data_o`，
//        并使 `note_valid_o` 与之同拍。
//
// ── ⭐ 关键设计点 ───────────────────────────────────────────────────────────
//   ① ⭐⭐ **`tick_inc_o` 必须是寄存器输出**（⛔ 不是组合）
//      —— 它直接进 `beat_gen` 的 32 位相位累加器；组合输出的毛刺会让相位跳变。
//
//   ② ⭐⭐ **解码必须先看 `kind`**
//      —— 同一字段 `inc` 在 `kind=0/1` 时是 **`phase_inc`（音高）**，
//         在 `kind=2` 时是 **`tick_inc`（速度）** ⇒ ⛔ 语义随 kind 改变。
//
//   ③ ⭐ **换速不重算相位**
//      —— 只把 `tick_inc` 写出去，`beat_gen` 内部相位**连续推进** ⇒ 不跳拍/不断音。
//
//   ④ ⭐ **`cur_tick_r` 必须与 `beat_gen` 的音乐位置严格同步**：
//      两者都由**同一个 `tick_i` 推进**、由**同一个 `pos_reset_i` 归零**。
//      ⚠️ 调用方**必须**把本模块的 `pos_reset_i` 与 `beat_gen.pos_reset_i` 接同一个信号，
//         ⛔ 否则两边位置会**静默错位**（事件按错误的时间播放，且没有任何报错）。
//
//   ⑤ ⭐ **`tick_inc = 0` 合法但静止** —— 复位默认值取 **120 BPM**，⛔ 不用 0。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 2001 编译，用了 SV 专有构造
//     ⇒ **整个模块被静默丢弃**，而 iverilog 全绿）
//   · ⭐ **组合逻辑用 `assign`；`always @(*)` 只用在"真的读信号"的块上**（`L67`）
//   · ⛔ **不对 `integer` 参数做位选**（`K-91`）
//   · ⭐ **参与算术的 wire 一律显式写位宽**（⚠️ 不写就是 1 位 ⇒ 截断）
//   · ⭐ **任何"容量有限"的计数器都必须可观测**（`K-106`）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module play_seq #(
    parameter integer EVT_W    = 64,
    // ⭐ 复位后的默认速度 = 120 BPM 的 tick_inc
    //    ⚠️ 为什么不是 0：`tick_inc = 0` ⇒ 相位不涨 ⇒ 🔴 **时钟静止**
    //    ⭐ 164927 已与 `tb_beat_gen` 的既有常量交叉核对（120 BPM @ PPQN 960）
    parameter [31:0]  TICK_INC_DEFAULT = 32'd164927
) (
    input  wire                clk_i,
    input  wire                rst_n_i,          // ⭐ 同步复位、低有效

    // ── ⭐ 与 `beat_gen` 的接口 ─────────────────────────────────────────────
    input  wire                tick_i,           // ⭐ `beat_gen.tick_o`（单周期脉冲）
    input  wire                run_i,            // transport（1 = 走）
    // ⭐⭐ 音乐位置复位 —— **必须与 `beat_gen.pos_reset_i` 接同一个信号**
    //    ⚠️ 否则本模块的 `cur_tick_r` 会与 `beat_gen` 的位置**静默错位**
    input  wire                pos_reset_i,

    // ── ⭐⭐ LED 指引的【提前量】（⭐ 2026-10-14 新增 · ⭐ 指引模式专用）──────────
    //  ⭐ **语义**：⭐ 事件在 `evt_tick - lead_i` 那一刻就发出（⛔ 不是到点才发）✅
    //  ⭐ **用途**：⭐ 指引模式（`'U'`）下让 **LED 提前一拍**亮起
    //     ⇒ ⭐ 给演奏者"**预备—按**"的时间（⭐ 音乐教学的标准做法 ✅）
    //
    //  📌 ⭐⭐ **为什么这样做是安全的（⭐ 关键，⛔ 别改成别处）**：
    //     · ⭐ 指引模式下 `seq_arb.score_valid_i` **已被闸住** ⇒ ⭐ 音符**不出声** ✅
    //     · ⭐ 而**节拍器/鼓机是 `beat_gen` 驱动**的 ——
    //        ⭐ `metronome` 吃 `beat_i`、⭐ `drum_gen` 吃 `tick_i`
    //        ⇒ ⭐ **两者都⛔ 不经过本模块的事件流** ✅
    //     · ⭐ 用户已澄清指引模式的形态：*"指引模式应该只会有一个音轨，
    //        然后背景是和灌谱相同的 BPM 的节拍器/鼓机"* ✅
    //     ⇒ ⭐ 所以提前发**只影响 LED**，⛔ **不会让鼓提前** ✅
    //
    //  ⚠️ **演奏模式必须给 `0`** ⇒ ⭐ 表达式与原来**逐位相同** ⇒ ⭐ **零回归** ✅
    //  📌 ⭐ 1 拍 = `PPQN = 960` tick（⭐ 4/4 小节 = 3840 ✅）
    //     ⭐ 120 BPM 下 960 tick = **500 ms** ⇒ ⭐ 正落在"找键+移手指"的直觉区间
    //        （⭐ 400~800 ms）正中间 ✅
    //  📌 ⭐ **将来可做成随速度自适应**（⭐ ≤90 BPM 用半拍、≥160 BPM 用两拍）
    //     ⇒ ⭐ 只需改 `top.v` 喂进来的值，⛔ 本模块不用动 ✅
    input  wire [19:0]         lead_i,

    // ── ⭐⭐ 2026-10-15：⭐ **【逐事件】提前一拍**（⭐ 上位机保留位 `bit6` ✅）────────
    //  ⭐ **背景**：⭐ `lead_i` 是**全局**的（⭐ 由 `top.v` 的 `guide_only_r` 决定），
    //     ⚠️ 而"**哪些音符只亮灯不出声**"已改成**逐事件**用保留位 `bit6` 指定
    //     （⭐ `files/20-代码/ESP32侧需求-引导模式改成上位机逐事件控制-20261015.md`）
    //     ⇒ ⭐ 于是**提前一拍也必须能逐事件生效** ✅
    //
    //  ⭐ **语义**：⭐ 本拍**队头**事件若被标记，⭐ 就再提前 **`LEAD_ONE_BEAT`（= 1 拍）** ✅
    //     ⭐ 有效条件：⭐ `due_limit = cur_tick_r + lead_i + (lead_sel_i ? LEAD_ONE_BEAT : 0)`
    //        📌 ⭐ **`lead_i` 那条【原样保留】**（⭐ 它是全局的）⇒ ⭐ **两条相加** ✅
    //     ⭐ `lead_sel_i` 由 `top.v` 用**队头的 `bit6`** 驱动
    //        （⭐ `eb_rd_data[6]` ⇒ ⭐ 与 `evt_data_i` **同一条**、⭐ 同拍有效 ✅）
    //
    //  ⚠️⚠️ **必须 Z-safe（`=== 1'b1`）** —— ⭐ 与下面 `bpm_load_i` **同一条纪律** ✅
    //     🔴 **为什么**：⭐ `tb_play_seq` / `tb_play_seq_lead` 等**已存在**的 tb
    //        用**具名端口**例化本模块、⭐ **没接**这个新端口
    //        ⇒ ⭐ 输入是 **`z`** ⇒ ⚠️ 若写成 `if (lead_sel_i)` ⇒ **`x`**
    //        ⇒ 🔴 `due_limit` 整条变 `x` ⇒ ⭐ `evt_due = x` ⇒ **tb 行为不可预测** ✅
    //     ✅ Z-safe ⇒ ⭐ 悬空时**一律当假** ⇒ ⭐ 老 tb **逐位不变**（⭐ 零回归 ✅）
    //
    //  📌 ⭐ **为什么不改 `lead_i` 的语义**：⭐ 那样会**破坏 `tb_play_seq_lead`**
    //     （⭐ 它只驱动 `lead_i` ⇒ ⚠️ 提前量会静默消失 ⇒ 🔴 **判据变空** ✅）
    //     ⇒ ⭐ 两条**相加**：⭐ 老通路原样保留 ＋ ⭐ 新增一条逐事件通路 ✅
    //  📌 ⭐ **代价**：⭐ 一个 20 位 2:1 mux ＋ 一个 21 位加法器（⭐ 与既有那条同量级 ✅）
    input  wire                lead_sel_i,

    // ── ⭐⭐ BPM 手动入口（⭐ 2026-10-11 新增 · ⭐ 串口 `'Q'` ＋ ⭐ 将来 EC11）──────
    //  ⭐ **为什么放在本模块**：⭐ `tick_inc_o` 是**本模块拥有的换速寄存器** ✅
    //     ⇒ ⭐ 手动改速与曲谱 `kind=2` 事件**写同一个寄存器** ⇒ ⭐ **后写者胜** ✅
    //     ⇒ ⛔ 不需要仲裁器，⛔ 不会出现"两个速度源打架" ✅
    //  📌 ⭐ **与信号源无关**（⭐ 这是给 EC11 留的口子 ✅）：
    //     ⭐ 现在：⭐ 串口 `'Q'` ⇒ `bpm_load_i`/`bpm_i` ✅
    //     ⭐ 将来：⭐ EC11 的 A/B 解码 ⇒ `bpm_up_i`/`bpm_dn_i` ✅
    //     ⇒ ⭐ **EC11 只需加解码器 ＋ 一个 OR，⛔ 不用改本模块** ✅
    //  ⚠️ ⭐ 三个都按**单周期脉冲**用（⭐ 与 `tare_req_o` 等同一约定 ✅）
    //     ⭐ 同拍多个有效时的优先级：⭐ `bpm_load_i` > `bpm_up_i` > `bpm_dn_i` ✅
    input  wire                bpm_up_i,         // ⭐ +1 BPM
    input  wire                bpm_dn_i,         // ⭐ −1 BPM
    input  wire                bpm_load_i,       // ⭐ 装载 `bpm_i`（⭐ 绝对设置）
    input  wire [15:0]         bpm_i,            // ⭐ 目标 BPM（⭐ 会被限幅到 40~240 ✅）

    output reg  [31:0]         tick_inc_o,       // ⭐⭐ → `beat_gen.tick_inc_i`（**寄存器输出**）

    // ── 事件缓冲接口（⭐ 由调用方供给）──────────────────────────────────────
    input  wire                evt_valid_i,      // 缓冲区当前有事件可读
    input  wire [EVT_W-1:0]    evt_data_i,       // 事件数据
    // ⭐⭐ `evt_rd_o` 是**组合**的"本拍正在取"选通 —— ⚠️ **不是**寄存器脉冲！
    //   🔴 **踩过的坑（2026-09-22）**：第一版把它做成寄存器输出
    //      ⇒ ⚠️ 调用方（标准同步 FIFO：见 `rd` 下一拍推进 `head`）
    //        **来不及**在 DUT 下一次采样前换数据
    //      ⇒ 🔴 **同一条事件被发两遍**（第一个 `evt_rd` 之后 head 还没动）。
    //   ⭐ 组合输出 ⇒ 调用方**在同一拍**就看到它、下一拍 head 已推进 ⇒ ⛔ 不重复。
    //   ⚠️ 组合毛刺不影响：调用方是在**时钟沿采样**它（⭐ 与 FIFO 的 `rd` 同语义）。
    output wire                evt_rd_o,

    // ── 解码后的音符事件（→ `evt_merge`）──────────────────────────────────
    output reg                 note_valid_o,     // ⭐ 与 `note_data_o` **同拍**
    output reg  [EVT_W-1:0]    note_data_o,      // ⭐ **锁存**输出（⛔ 不是组合直通）

    // ── ⭐ 可观测性（`K-106` 纪律）────────────────────────────────────────
    output reg                 tempo_applied_o,  // ⭐ 换速已生效（单周期）
    output reg                 evt_underrun_o,   // ⭐⚠️ 该出事件却没有 ⇒ **不许静默**
    output reg  [15:0]         evt_cnt_o,        // ⭐ 已吐出的事件数
    output reg  [15:0]         tempo_cnt_o,      // ⭐ 已应用的换速次数
    output reg  [19:0]         cur_tick_o        // ⭐ 当前音乐位置（**可观测**，便于上板核对）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐⭐⭐ 2026-10-11：⭐ **BPM 手动入口的换算**（⭐ 串口 `'Q'` ＋ 将来 EC11 ✅）
    //
    //  ⭐ **公式**（⭐ 从 `beat_gen` 的定义反推 ✅）：
    //     ⭐ `tick_inc = BPM × PPQN × 2^32 / (60 × CLK_HZ)`
    //     ⭐ 代入 `PPQN = 960`、⭐ `CLK_HZ = 50e6` ⇒ ⭐ 斜率 = `960 × 2^32 / 3e9`
    //        = **1374.3895…** ✅
    //     ⭐ 取整数斜率 **1374** ＋ ⭐ 偏置 **47**：
    //        ⭐ `tick_inc = BPM × 1374 + 47` ✅
    //     ✅ **验算**：⭐ `120 × 1374 + 47 = 164927` ✅
    //        ⇒ ⭐ **与现有常量 `TICK_INC_DEFAULT` 逐位相同** ✅
    //        （⭐ 选 47 就是为了让 120 BPM **精确**落在原值上 ✅）
    //     📌 ⭐ 40 BPM ⇒ `55007` · ⭐ 240 BPM ⇒ `329807` ✅
    //
    //  ⭐ **为什么用移位相加而⛔ 不用乘法**：⭐ `1374 = 1024+256+64+16+8+4+2` ✅
    //     ⇒ ⭐ 6 个加法器 ✅（⭐ 而 `x * 1374` 会被综合成 **DSP** 🔴 ——
    //        ⭐ 见 `P1-15`：⭐ `MULT12X12` 就是这么来的 ✅）
    //     📌 ⭐ 且 `BPM` 只有 40~240 ⇒ ⭐ 位宽很小 ✅
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer BPM_MIN     = 40;          // ⭐ 最慢
    localparam integer BPM_MAX     = 240;         // ⭐ 最快
    localparam [31:0]  INC_PER_BPM = 32'd1374;    // ⭐ 每 1 BPM 的 `tick_inc` 增量
    localparam [31:0]  INC_OFFSET  = 32'd47;      // ⭐ 偏置（⭐ 让 120 BPM 精确）
    localparam [31:0]  INC_MIN     = 32'd55007;   // ⭐ = 40 BPM
    localparam [31:0]  INC_MAX     = 32'd329807;  // ⭐ = 240 BPM

    //  ⭐ 限幅后的目标 BPM（⭐ 40~240 ✅）
    wire [15:0] bpm_clamped = (bpm_i < BPM_MIN) ? BPM_MIN[15:0]
                            : ((bpm_i > BPM_MAX) ? BPM_MAX[15:0] : bpm_i);

    //  ⭐ `BPM × 1374`：⭐ **移位相加**（⭐ 1374 = 1024+256+64+16+8+4+2 ✅）
    wire [31:0] bpm_x1374 = ({16'd0, bpm_clamped} << 10)
                          + ({16'd0, bpm_clamped} <<  8)
                          + ({16'd0, bpm_clamped} <<  6)
                          + ({16'd0, bpm_clamped} <<  4)
                          + ({16'd0, bpm_clamped} <<  3)
                          + ({16'd0, bpm_clamped} <<  2)
                          + ({16'd0, bpm_clamped} <<  1);

    //  ⭐ 绝对装载值（⭐ `bpm_load_i` 用 ✅）
    wire [31:0] tick_inc_from_bpm = bpm_x1374 + INC_OFFSET;

    //  ⭐ 相对步进（⭐ `bpm_up_i`/`bpm_dn_i` 用 ✅）—— ⭐ 直接加减，⛔ 不用重算 BPM
    //     📌 ⭐ 这就是"±1 BPM/格"的等价实现（⭐ 每格正好 `INC_PER_BPM` ✅）
    //     ⚠️ 必须**限幅** ⇒ ⭐ 否则连按会把速度推出 40~240 ✅
    wire [31:0] inc_up_raw = tick_inc_o + INC_PER_BPM;
    wire [31:0] inc_dn_raw = tick_inc_o - INC_PER_BPM;
    wire [31:0] inc_up     = (inc_up_raw > INC_MAX) ? INC_MAX : inc_up_raw;
    wire [31:0] inc_dn     = (inc_dn_raw < INC_MIN) ? INC_MIN : inc_dn_raw;

    // ── ⭐ 位域（⚠️ 必须与 `tools/mid2evt.py` 逐位一致 —— 契约 §1.1.3 硬约束 1）──
    localparam integer TICK_SH   = 44;
    localparam integer TICK_W    = 20;
    localparam integer INC_SH    = 23;
    localparam integer INC_W     = 21;
    localparam integer AXIS_SH   = 19;
    localparam integer VEL_SH    = 11;
    localparam integer KIND_SH   = 9;
    localparam integer TIMBRE_SH = 7;

    // ⭐ kind 编码（冻结契约 §1.2）
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_TEMPO = 2'd2;

    // ── 组合解码（⭐ 用 `assign`，⛔ 不用 `always @(*)` —— `L67`）─────────────
    wire [1:0]  evt_kind = evt_data_i[KIND_SH +: 2];
    wire [31:0] evt_inc  = evt_data_i[INC_SH  +: INC_W];   // ⚠️ 21 位，零扩展到 32
    wire [19:0] evt_tick = evt_data_i[TICK_SH +: TICK_W];  // ⭐⭐ 缺陷 1：这一条必须用

    // ⭐⭐ 音符事件 = kind 0/1（⭐ 换速【不是】音符 ⇒ 必须排除）
    //    🔴 漏掉这个判断 ⇒ 每条换速事件都会被当成 `note_on` 送给 note_manager
    //       ⇒ 多出一个"伪音符"（音高 = tick_inc，通常是很低的怪音）。
    wire is_note_event = (evt_kind == KIND_ON) || (evt_kind == KIND_OFF);
    wire is_tempo_evt  = (evt_kind == KIND_TEMPO);

    // ── ⭐⭐ 本地音乐位置（与 `beat_gen` 严格同步推进）──────────────────────
    reg [19:0] cur_tick_r;

    // ── ⭐⭐ 缺陷 1 的修法：**位置到了才发**，且**同 tick 的全部连续发完** ───────
    //   ⭐ `evt_tick <= cur_tick_r` ⇒ 本拍该发（⛔ 不用等下一个 `tick_i`）
    //   ⚠️ 用 `<=`（⛔ 不是 `==`）：⭐ **PC 送晚了的条目【照样发】**（追赶），
    //      ⛔ 而不是永远卡住等一个已经过去的位置（那会死锁）。
    //
    //  ⭐⭐ 2026-10-14：⭐ **加 `lead_i`（指引模式的提前量）** ✅
    //     ⭐ `lead_i = 0` ⇒ `due_limit == {1'b0, cur_tick_r}`
    //        ⇒ ⭐ 比较结果与原来**逐位相同** ⇒ ⭐ **零回归** ✅
    //     ⚠️ **必须用 21 位相加**（⛔ 不是 20 位）：
    //        ⭐ `cur_tick_r` 是 20 位，⭐ 加 `lead` **可能越过 20 位上限**
    //        ⇒ 🔴 若用 20 位会**回绕** ⇒ ⭐ 在曲子末尾会**误发后面的事件** ✅
    //     📌 ⭐ 这里**只放宽"什么时候可以发"**，⛔ **不动** `evt_rd_o`/锁存/换速的时序 ✅
    //
    //  ⭐⭐ 2026-10-15：⭐ **再叠一层【逐事件】提前量**（⭐ 见端口 `lead_sel_i` 的长注释 ✅）
    //     ⭐ `LEAD_ONE_BEAT` = 1 拍（⭐ 与 `top.v` 的 `LEAD_ONE_BEAT` **同值** ✅）
    //     ⭐ `lead_sel_i = 0`（⭐ 含悬空 `z`）⇒ ⭐ 表达式与**原来逐位相同** ⇒ ⭐ 零回归 ✅
    localparam [19:0] LEAD_ONE_BEAT = 20'd960;      // ⭐ = PPQN（1 拍）
    wire [19:0] lead_evt = (lead_sel_i === 1'b1) ? LEAD_ONE_BEAT : 20'd0;
    wire [20:0] due_limit = {1'b0, cur_tick_r} + {1'b0, lead_i} + {1'b0, lead_evt};
    wire        evt_due   = evt_valid_i & ({1'b0, evt_tick} <= due_limit);

    // ⭐ 本拍真的发一条：只有在走、且该发时才发
    wire emit_now = run_i & evt_due;

    // ⭐⭐ `evt_rd_o` = **组合**的"本拍在取"（⛔ 不是寄存器脉冲，见端口说明）
    assign evt_rd_o = emit_now;

    // ⭐⚠️ underrun：**在一个 tick 的边界上，缓冲区却是空的**
    //    ⚠️ 判据用"缓冲区空"（⛔ 不是"数据无效"）—— ⭐ 空=事实；无效=未知（`C35`）
    wire underrun = run_i & tick_i & ~evt_valid_i;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            cur_tick_r      <= 20'd0;
            note_valid_o    <= 1'b0;
            note_data_o     <= {EVT_W{1'b0}};
            tempo_applied_o <= 1'b0;
            evt_underrun_o  <= 1'b0;
            evt_cnt_o       <= 16'd0;
            tempo_cnt_o     <= 16'd0;
            cur_tick_o      <= 20'd0;
            tick_inc_o      <= TICK_INC_DEFAULT;   // ⭐ ⛔ 不是 0（0 ⇒ 时钟静止）
        end else begin
            // ⭐ 默认：脉冲类输出**每拍清零** ⇒ 严格单周期
            note_valid_o    <= 1'b0;
            tempo_applied_o <= 1'b0;
            evt_underrun_o  <= 1'b0;

            // ⭐⭐ 音乐位置推进：⭐ **与 `beat_gen` 同源**（同一个 tick 脉冲）
            //    ⚠️ 复位优先级最高（与 `beat_gen.pos_reset_i` 必须接到同一个信号）
            if (pos_reset_i) begin
                cur_tick_r <= 20'd0;
            end else if (run_i & tick_i) begin
                // ⭐ 到上限就**不回绕**（⭐ 20 位 = 1048575 tick = 273 小节，
                //    ⚠️ 超过就是曲子本身超出契约容量 ⇒ 停在末端，⭐ 由 `cur_tick_o` 可见）
                if (cur_tick_r != {TICK_W{1'b1}})
                    cur_tick_r <= cur_tick_r + 20'd1;
            end

            if (underrun) begin
                evt_underrun_o <= 1'b1;
            end

            if (emit_now) begin
                evt_cnt_o    <= evt_cnt_o + 16'd1;
                // ⭐⭐ 缺陷 2 的修法：**在同一拍把数据锁存**，与 `note_valid_o` 对齐
                note_data_o  <= evt_data_i;
                note_valid_o <= is_note_event;

                if (is_tempo_evt) begin
                    // ⭐⭐ 换速：把 `inc` 字段（此处存的是 `tick_inc`）写出去。
                    //    ⚠️ 本模块【不碰相位】—— 相位在 beat_gen 内部连续推进
                    //       ⇒ ⭐ 不跳拍、不断音（契约 §3.2）。
                    //    ⚠️ `tick_inc = 0` 是"合法但静止"⇒ ⭐ **拒绝应用**（⛔ 不让时钟停死）
                    if (evt_inc != 32'd0) begin
                        tick_inc_o      <= evt_inc;
                        tempo_applied_o <= 1'b1;
                        tempo_cnt_o     <= tempo_cnt_o + 16'd1;
                    end
                    // ⚠️ 若 evt_inc == 0：**不应用、但也不报错** ——
                    //    这是"上电/未选曲"的合法态。⭐ 可观测性由 `tempo_cnt_o` 体现
                    //    （⛔ 不静默：调用方看 `tempo_cnt_o` 没涨就知道没应用）
                end
                // ⚠️ 音符事件（kind 0/1）**不改速度**
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ 2026-10-11：⭐ **BPM 手动入口**（⭐ 串口 `'Q'` ＋ 将来 EC11 ✅）
            //
            //  📌 ⭐ **为什么放在 `emit_now` 之外**：⭐ 手动改速**与事件流无关** ✅
            //     ⭐ 曲谱没在放的时候也要能改速 ✅
            //  📌 ⭐ **同拍冲突的优先级**：⭐ 放在 `emit_now` **之后** ⇒
            //     ⭐ **手动命令胜**（⭐ 用户刚按的应该被尊重 ✅）
            //     ⚠️ 但这只在"曲谱 tempo 事件与手动命令**同拍**"时才有差别
            //        （⭐ 概率极低 ✅）
            //  📌 ⭐ **三者都写 `tick_inc_o`** ⇒ ⭐ 与 tempo 事件**同一个寄存器** ✅
            //     ⇒ ⭐ 后写者胜、⛔ 无仲裁器 ✅
            //  📌 ⭐ 可观测：⭐ 三个分支都拉 `tempo_applied_o` ＋ ⭐ 涨 `tempo_cnt_o` ✅
            //     （⭐ `K-106`：⭐ 改速**必须可见**，⛔ 不许静默 ✅）
            // ═══════════════════════════════════════════════════════════════
            //  ⚠️⚠️ ⭐ **必须用 Z-safe 比较（`=== 1'b1`）** —— 🔴 **实测踩到**：
            //     ⭐ `tb_play_seq` 的例化**没接这四个新端口**（⭐ 它是**已存在**的 tb ✅）
            //     ⇒ ⭐ 输入是 **`z`** ⇒ ⚠️ `if (bpm_load_i)` 里是 **`x`**
            //     ⇒ 🔴 分支**可能成立** ⇒ ⭐ `tick_inc_o <= x` ⇒ 🔴 **音乐时钟崩 ⇒ tb 挂死** ✅
            //     （⭐ 实测：⭐ 全量回归里 `tb_play_seq` **TIMEOUT after 120 s** ✅）
            //  ✅ **Z-safe**：⭐ `=== 1'b1` ⇒ ⭐ `z`/`x` **一律当假** ⇒ ⭐ 悬空输入**无害** ✅
            //     📌 ⭐ 这是**本项目已有的约定**（⭐ 见 `looper` 的 `dump_en_w = (dump_en_i === 1'b1)` ✅）
            //     📌 ⭐ 而且它**保护所有"没接新端口的 tb"** —— ⚠️ 否则每加一个输入都要改一堆 tb ✅
            if (bpm_load_i === 1'b1) begin
                tick_inc_o      <= tick_inc_from_bpm;
                tempo_applied_o <= 1'b1;
                tempo_cnt_o     <= tempo_cnt_o + 16'd1;
            end else if (bpm_up_i === 1'b1) begin
                tick_inc_o      <= inc_up;
                tempo_applied_o <= 1'b1;
                tempo_cnt_o     <= tempo_cnt_o + 16'd1;
            end else if (bpm_dn_i === 1'b1) begin
                tick_inc_o      <= inc_dn;
                tempo_applied_o <= 1'b1;
                tempo_cnt_o     <= tempo_cnt_o + 16'd1;
            end

            cur_tick_o <= cur_tick_r;   // ⭐ 可观测（⚠️ 打一拍，便于上板对照）
        end
    end

endmodule

`default_nettype wire
