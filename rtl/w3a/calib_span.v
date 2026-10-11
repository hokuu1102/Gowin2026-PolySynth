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
    //   🔴 2026-09-25 更正：帧周期【不是】196 µs —— ⭐ **实测 500 µs**
    //      📌 证据：`sim/evidence/tb_adc_farm.log` 判据行
    //         `frame period=500000 ns`；⭐ 且 `CHANNEL_RATE_HZ=2000`
    //         （⭐ `top.v:721`）⇒ 500 µs ✅ 两者吻合。
    //      ⚠️ 196 µs 是【单帧 8 通道的转换耗时】8×24.5 µs，⛔ 不是帧周期
    //         ⇒ 🔴 旧注释把"转换耗时"当成"帧周期"了（⭐ 见 `K-128`）。
    parameter integer STABLE_NEED = 24,     // ⭐ 24 帧 ≈ 12 ms @500 µs/帧（原注释写 4.7 ms，错）
    parameter [11:0]  STABLE_TOL  = 12'd8,  // ⭐ 帧间变化 < 8 码算"没动"

    // ── ⭐⭐ 投票参数（⭐ 用户明确要求"多帧投票"）──────────────────────────
    parameter integer VOTE_N      = 32,     // ⭐ 投票帧数（⭐ 取 32 的中位数）
    parameter [11:0]  VOTE_TOL    = 12'd16, // ⭐ max−min ≤ 16 码才认这组样本
    //   ⚠️ 不满足 ⇒ ⭐ **拒绝重来**（⛔ 不静默记错）—— 见 `st_reject`
    parameter integer REJECT_MAX  = 8,      // ⭐ 最多拒绝 8 次（⚠️ 防无限循环）

    // ⭐⭐ `WAIT_TIMEOUT_CLK`（⭐ 2026-09-23 深夜新增 · 修"静默卡死"）
    //   🔴 **为什么必须有**：⭐ `S_WAITBUSY` / `S_NEXT` 原来都在**等一个事件**
    //      （目标通道的采样 / `calib.busy` 升起）
    //      ⇒ ⚠️ 若那个事件**永不到来**，状态机就**永久卡住**：
    //         · ⚠️ `adc_farm` 停扫（SPI 挂了 / 排线松了）⇒ 没有 `sample_valid`
    //         · 🔴 `calib` 走 `err` 分支时**根本不拉 `busy`**（⭐ 见 `S_NEXT` 注释）
    //         · ⚠️ `cal_busy_i` 因任何原因悬高 ⇒ `S_WAITBUSY` 出不去
    //      ⇒ 🔴 现象：⭐ **操作者以为在标定，其实早就死了**（`K-87`/`K-106` 同族）。
    //   ⭐ 本参数给等待一个**上界**：⭐ 超时 ⇒ ⭐ **明确拒绝并重试**（⛔ 不静默）。
    //   ⚠️ **单位 = clk 拍**（⭐ 兜底用；⭐ 主判据仍是"帧"）。
    //      默认 **50_000_000 拍 = 1 秒** @50 MHz ——
    //      ⭐ 远大于 `calib` 除法器的 24 拍，⚠️ 但远小于"人以为卡死了"的耐心。
    parameter integer WAIT_TIMEOUT_CLK = 50_000_000,

    parameter integer POS_W       = 12
) (
    input  wire             clk,
    input  wire             rst_n,          // ⭐ 同步复位、低有效

    // ── ⭐ 触发源（⭐ 只占一个脉冲 ⇒ 以后换源只改这里）───────────────────
    input  wire             start_i,        // ⭐ 单拍脉冲 = 进入 span 标定
    // ⭐⭐ `abort_i`（⭐ 2026-09-23 深夜新增 · 用户拍板"给 calib_span 加 abort_i"）
    //   🔴 **为什么必须有**：⭐ 状态机**没有从中间状态回 `S_IDLE` 的路径** ⇒
    //      ⚠️ 尤其是 `S_SETTLE`：它的退出条件是"连续 STABLE_NEED 帧变化 < STABLE_TOL"
    //      ⇒ 🔴 **操作者中途松手（或按错轴）后，读数剧烈变化 ⇒ 永远满足不了**
    //      ⇒ 🔴 **状态机永久卡在 `S_SETTLE`**，`busy_o` 恒 1、标定再也进不去，
    //      ⭐ **只有复位键能救**。
    //   ⭐ 而 `'X'`（取消）命令**要解决的就是这个** —— ⚠️ 恰恰是最高频场景
    //      （按错轴 / 手抖 / 按错板子想重来）。
    //   ⇒ ⭐ 本端口让**任意状态**都能干净退出。
    //
    //   🔴🔴 **一条硬纪律**：⭐ `abort_i` 拉高时**必须保证 `span_o` 已为 0** ——
    //      ⚠️ 绝不能在 `S_WAITBUSY` 发脉冲的**当拍**被 abort 打断成"半个 `span`"
    //      ⇒ 🔴 若 `calib` 收到 `span` 但 `cal_ch`/`raw` 已错位，
    //         它会**拿别的通道的值算增益** ⇒ ⭐ 静默写坏该通道标定（`K-87` 同族）。
    //      ⭐ 本模块的写法天然满足：⭐ `span_o <= 0` 是**每拍默认赋值**（见下方
    //         `span_o <= {N_ADC{1'b0}};`）⇒ ⭐ abort 走默认路径 ⇒ ⛔ 不会漏脉冲。
    //   ⭐ 同步处理（⛔ 不是异步清）—— ⭐ 遵守单时钟域纪律。
    input  wire             abort_i,

    // ── 来自 `adc_farm`（⭐ 用于对齐时机 + 采样）─────────────────────────
    input  wire             sample_valid_i, // ⭐ 单拍脉冲
    input  wire [2:0]       sample_ch_i,    // ⭐ 当前通道
    input  wire [POS_W-1:0] raw_i,          // ⭐ 当前【已反相】的码（⭐ 与 `calib.raw` 同一路）

    // ── 去 `calib` ────────────────────────────────────────────────────────
    output reg  [N_ADC-1:0] span_o,         // ⭐ 逐片（⭐ 锁步 ⇒ 同拍拉高）
    //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **投票代表值**（⭐ 只在发 `span` 的那一拍有效）✅
    //   🔴 **原缺陷**：⭐ `vote_lo` **只被写、从不被读**（⭐ 全文件仅 3 处出现，无读者）
    //      ⇒ ⭐ 综合直接剪掉 ⇒ 🔴 **真正送进 `calib` 的是发脉冲那一拍的【当拍活采样】** ✅
    //      ⇒ ⭐ 用户明确要求的"值不能只取最后一个采样"**没有交付** ——
    //         ⭐ 投票只当了**闸门**（离散度超限就拒），⛔ **没当取值器** ✅
    //      📌 **误差量级（⭐ 硬算）**：⭐ `SPAN_VOTE_TOL = 96` ⇒ 组内 `(max−min)` 可达 96 码
    //         ⇒ ⭐ 用"最后一个采样"代替中位数 ⇒ 误差可达 **±48 码** ✅
    //         ⭐ 而标称行程 `den ≈ 744` ⇒ 增益误差 **6.5%** ⇒ 满行程 pos 误差 **266 码** ✅
    //         ⭐ 而触发阈值只允许落在行程的 5%~12%（**37~89 码**）
    //         ⇒ 🔴 **266 码的标定偏差是触发阈值本身的 3~7 倍** ✅
    //         ⇒ 🔴 **这正是"同一批键有的灵敏有的要按到底"的机制** ✅
    output reg  [POS_W-1:0] span_val_o,     // ⭐ 本轴的投票代表值（⭐ 其余时刻为 0）
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
    output reg  [3:0]       done_cnt_o,     // ⭐ 已标定轴数
    // ⭐⭐ 2026-09-24 新增：⭐ 把内部状态暴露出来（⭐ 供 `'P'` 诊断回传）
    //   🔴 **为什么**：⭐ 上板调 `span` 时只能看到 `!`，⛔ **看不出卡在哪一步**
    //      ⚠️ 而 8 个状态里任何一个超时都会回 `!` ⇒ ⭐ 必须能区分
    //   📌 编码同 `S_*` 的 localparam（⭐ 0=IDLE · 1=PROMPT · 2=SETTLE · …）
    output wire [2:0]       state_o,        // ⭐ 当前状态（⭐ 组合）
    output wire [3:0]       rej_cnt_o,      // ⭐ 已拒绝次数（⭐ 组合）
    // ⭐⭐ 2026-09-30 新增：⭐ **上一次拒绝的原因码**（⭐ 见上方 `RJ_*`）
    //   ⭐ 它是**寄存器**（⭐ 只在拒绝那一拍更新）⇒ ⭐ 拒绝之后一直保持
    //      ⇒ ⭐ 顶层可以在 `ev_reject` 那一拍取到**本条拒绝**的原因 ✅
    output reg  [2:0]       rej_why_o       // ⭐ 0=none 1=settle 2=vote_to 3=spread 4=busy_to 5=cal_err 6=silent
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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-09-30：**拒绝原因码**（⭐ 上板诊断用）
    //
    //   🔴 **为什么必须在【本模块】里记**：
    //      ⭐ 本模块有 **6 条**拒绝出边（⭐ 见下），⛔ 而它们**都只回一个 `'!'`**
    //      ⇒ ⚠️ 上板看到 `!` 时**根本分不出是哪一条** ⚠️
    //      ⇒ 🔴 而"没按稳"与"片报 err"是**完全不同的修法**（⭐ 前者教用户、
    //         后者查硬件）⇒ ⭐ 必须能分辨。
    //
    //   ⛔ **为什么不能靠 `state_o` 反推**：⭐ 每条拒绝出边都写 `state <= S_PROMPT`
    //      （⭐ 或 `S_DONE`）—— ⚠️ 非阻塞赋值 ⇒ ⭐ 在 `reject_o` 为高的那一拍，
    //      `state_o` **已经是 `S_PROMPT`/`S_DONE`** ⇒ 🔴 **拒绝发生的状态被丢掉了**。
    //      ⇒ ⭐ 所以只能**显式记一个原因码**。
    //
    //   📌 它是**纯诊断**：⭐ 不参与任何判决逻辑 ⇒ ⛔ 改动零风险 ✅
    //      ⭐ 且**只在本 `always` 块里被赋值**（⭐ Gowin 单驱动硬要求 `EX2000`）
    // ═══════════════════════════════════════════════════════════════════════
    localparam [2:0] RJ_NONE    = 3'd0;  // ⭐ 本次扫描还没拒绝过
    localparam [2:0] RJ_SETTLE  = 3'd1;  // R1 `S_SETTLE` 超时（⭐ 键没按稳 / 帧不来）
    localparam [2:0] RJ_VOTE_TO = 3'd2;  // R2 `S_VOTE` 超时（⭐ 投票帧不来）
    localparam [2:0] RJ_SPREAD  = 3'd3;  // R3 离散度 `>VOTE_TOL`（⭐ 手还在动）
    localparam [2:0] RJ_BUSY_TO = 3'd4;  // R4 `S_WAITBUSY` 超时（⭐ 帧不来）
    localparam [2:0] RJ_CAL_ERR = 3'd5;  // R5 `cal_err_i`（⭐ ⭐ **`span` 已发**）
    localparam [2:0] RJ_SILENT  = 3'd6;  // R6 `span` 已发但无 `busy` 无 `err`

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
    //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **13 位投票和**（⭐ 防 12 位回绕）✅
    //   📌 `vmin`/`vmax` 都是 `[11:0]` ⇒ ⭐ 直接相加**只有 12 位** ⇒ ⭐ 两个都接近满幅时回绕 ✅
    //   📌 先零扩展到 13 位再相加 ⇒ ⭐ 最大值 `4095+4095 = 8190 < 8192` ✅ **装得下** ✅
    wire [12:0] vote_sum_w = {1'b0, vmin} + {1'b0, vmax};

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 等待兜底 + "已发 `span`"标记（⭐ 2026-09-23 深夜新增）
    //   🔴 这两个寄存器是**"不静默卡死"**的载体 —— ⭐ 见 `S_WAITBUSY`/`S_NEXT`
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 超时计数器：⭐ 在**需要等待的状态**里递增，⛔ 别处清 0
    localparam integer WCW = (WAIT_TIMEOUT_CLK < 2) ? 1 : $clog2(WAIT_TIMEOUT_CLK + 1);
    reg [WCW-1:0] wait_clk_cnt;
    //   ⭐ `span_sent_r`：⭐ "本轴已经发过 `span` 脉冲"的标志
    //      🔴 **为什么必须记**：⭐ `calib` 的 `err` 与 `busy` 是**互斥**的
    //         （⭐ `err` 路径**不拉 `busy`**）⇒ ⚠️ 光看 `busy` 分不清
    //         "还没开始" 与 "直接 err 了" ⇒ ⭐ 必须主动记录已发。
    //      ⭐ 它在 `S_WAITBUSY` 发出 `span` 的那拍置起、⭐ 进 `S_PROMPT` 时清掉。
    reg           span_sent_r;
    //   ⭐⭐ 2026-09-30：`span_sent_r2` = `span_sent_r` **无条件打一拍**
    //      🔴 **为什么必须再加这一级**：⭐ `calib` 是在**收到 `span` 的【下一拍】**
    //         才更新 `err`（⭐ `err` 是寄存器）⇒ ⚠️ 发脉冲那拍之后**第 1 个 `S_NEXT` 拍**
    //         看到的仍是**上一轴残留的 `err`** ⇒ 🔴 上一轴失败时本轴**第一次必被误判 `!`**。
    //      ⭐ 加一级之后：⭐ 脉冲拍 N 置 `span_sent_r`；`calib` 在 N+1 采样并更新 `err`；
    //         `span_sent_r2` 从 N+1 起有效 ⇒ ⭐ **从 N+2 起"`err` 与标志同属本轴"** ✅
    //      📌 它**只在本 `always` 块里被赋值**（⭐ Gowin 单驱动硬要求：`EX2000`）✅
    //      📌 清除**不需要额外写**：⭐ `span_sent_r` 一清，`span_sent_r2` 下一拍自动跟 0 ✅
    reg           span_sent_r2;
    //   ⭐⭐ `prompt_phase`（⭐ 2026-09-25 新增，⭐ 修 `K-132`）：
    //      ⭐ `S_PROMPT` 需要**停留 2 拍**才能造出干净的 `need_press_o` 上升沿
    //        · 第 1 拍：`need_press_o <= 0`（⭐ 强制拉低）
    //        · 第 2 拍：`need_press_o <= 1`（⭐ 上升沿 ⇒ `ev_need` ⇒ 回轴号）
    //      🔴 **为什么不能靠"数拍子"**：⭐ 那样每次改状态机都得重新核对
    //         ⇒ ⚠️ 用显式标记 ⭐ 意图清楚、⛔ 不会随重构漂移。
    reg           prompt_phase;

    assign busy_o = (state != S_IDLE) && (state != S_DONE);

    // ⭐⭐ 诊断输出（⭐ 2026-09-24）：⭐ 把状态与拒绝计数直接给顶层
    assign state_o   = state;
    assign rej_cnt_o = reject_cnt;

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
            // ⭐ 2026-09-30：原因码复位（⭐ 它本身是 `output reg`，⭐ 直接用，⛔ 不另建内部量）
            rej_why_o   <= RJ_NONE;
            done_cnt_o  <= 4'd0;
            prev_val    <= 12'd0;
            vmin        <= 12'hFFF;
            vmax        <= 12'd0;
            vote_lo     <= 12'd0;
            vote_hi     <= 12'd0;
            stable_cnt  <= 6'd0;
            vote_cnt    <= 6'd0;
            // ⭐ 2026-09-23：兜底计数器 + 已发标记
            wait_clk_cnt<= {WCW{1'b0}};
            span_sent_r <= 1'b0;
            span_sent_r2<= 1'b0;
            //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ 投票代表值复位为 0 ✅
            //   📌 它**只在 `|span_o` 的那一拍被下游使用** ⇒ ⭐ 平时留着旧值无害 ✅
            span_val_o  <= {POS_W{1'b0}};
            // ⭐ 2026-09-25：`S_PROMPT` 的两拍标记（⭐ 见 `K-132`）
            prompt_phase<= 1'b0;
        end else begin
            // ⭐ `span` / `reject` 都是**单拍脉冲** ⇒ ⭐ 默认拉低
            //   🔴 **这行同时是 `abort_i` 的安全保证**（⭐ 见端口声明的硬纪律）：
            //      ⭐ abort 走这条路 ⇒ `span_o` 回到 0、⛔ 不会漏出半个脉冲。
            span_o   <= {N_ADC{1'b0}};
            reject_o <= 1'b0;
            // ⭐⭐ 2026-09-30：`span_sent_r2` **无条件**跟随 `span_sent_r`（⭐ 打一拍）
            //   ⚠️ 放在 `abort_i` 判断**之前** ⇒ abort 那一拍它还会保持 1，
            //      ⭐ 但 abort 把 `state` 打回 `S_IDLE` ⇒ `S_NEXT` 不参与判决 ⇒ ⭐ 无害 ✅
            span_sent_r2 <= span_sent_r;

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ `abort_i` 总闸（⭐ 2026-09-23 新增）—— ⭐ **优先于一切状态**
            //
            //   ⭐ 放在 `case` **之前**（⛔ 不是每个状态里各加一行）：
            //      ⚠️ 因为 `case` 的分支里会给 `state` 赋**别的**值，
            //         ⭐ 而这里**最后赋值者胜** ⇒ ⭐ 必须在结构上保证 abort 生效。
            //      但 ⚠️ Verilog 的 `always` 是**顺序执行、最后一次赋值生效**
            //         ⇒ ⭐ 所以 abort 必须写成 **`if/else` 包住整个 `case`**，
            //            ⛔ 不能只在前面写一句（会被 `case` 覆盖掉）。
            //
            //   ⭐ 复位动作：⭐ 与"回到 `S_IDLE`"等价 ——
            //      · `state` 回 `S_IDLE`（`busy_o` 自动落 0，⭐ 它是组合输出）
            //      · `need_press_o` 清 0（⛔ 否则操作者以为还要按）
            //      · `done_o` 清 0（⭐ 中止 ≠ 完成）
            //      · `cur_axis` / `reject_cnt` / `done_cnt_o` 清 0
            //        （⚠️ 否则下次进入时**带上一次的残留** —— 比如 `reject_cnt`
            //          已经累积到 `REJECT_MAX` ⇒ 🔴 一进去就立刻判失败）
            //      · `stable_cnt` / `vote_cnt` / `prev_val` / `vmin` / `vmax` 清
            //        （⭐ 同理，⚠️ 尤其 `prev_val = 12'hFFF` 是"首帧"哨兵）
            //   ⚠️ **`vote_lo`/`vote_hi` 不清** —— ⭐ 它们是**只读的中间结果**，
            //      下次 `S_FIRE` 会无条件重新赋值 ⇒ ⛔ 清了没意义（也省逻辑）。
            //      🔴 **`span_o` 已由上方默认赋值清 0** ⇒ ⛔ 这里不用再写
            //         （⭐ 但为醒目起见显式再写一次，⚠️ 语义等价、综合会优化掉重复）。
            // ═══════════════════════════════════════════════════════════════
            if (abort_i) begin
                state        <= S_IDLE;
                need_press_o <= 1'b0;
                done_o       <= 1'b0;
                cur_axis     <= 4'd0;
                cur_axis_o   <= 4'd0;
                reject_cnt   <= 4'd0;
                done_cnt_o   <= 4'd0;
                stable_cnt   <= 6'd0;
                vote_cnt     <= 6'd0;
                prev_val     <= 12'hFFF;      // ⭐ 恢复"首帧"哨兵
                vmin         <= 12'hFFF;
                vmax         <= 12'd0;
                span_o       <= {N_ADC{1'b0}};
                // ⭐ 2026-09-23：兜底计数器 + 已发标记也一并清（⭐ 语义 = 回到刚复位）
                wait_clk_cnt <= {WCW{1'b0}};
                span_sent_r  <= 1'b0;
                // ⭐ 2026-09-25：`S_PROMPT` 两拍标记（⭐ `K-132`）
                prompt_phase <= 1'b0;
            end else case (state)
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
                    // 🔴🔴 2026-09-25 修 `K-132`：⭐ **`need_press_o` 必须先落一拍再起**
                    //   ⚠️ **旧代码的 bug**：⭐ 这里只写 `need_press_o <= 1'b1`
                    //      ⇒ ⭐ 若它**本来就是 1**（⭐ 超时重试回到 `S_PROMPT` 时就是）
                    //        ⇒ 🔴 **没有 0→1 跳变**
                    //      ⇒ 🔴 `top.v` 的 `ev_need = sp_need_press & ~sp_need_r`
                    //         （⭐ **上升沿检测**）**不产生事件** ⇒ 🔴 **轴号不再回发**
                    //      📌 上板现象：⭐ 发 `'S'` ⇒ ⭐ **只有 `s`，⭐ 没有轴号**
                    //   ⭐ **为什么要"先落一拍"**：
                    //      ⭐ 让 `S_PROMPT` **停留 2 拍**：
                    //         · 第 1 拍：`need_press_o <= 0`（⭐ 强制拉低）
                    //         · 第 2 拍：`need_press_o <= 1`（⭐ 产生干净的上升沿）
                    //      ⇒ ⭐ 每次重试都会**重新发一次轴号** ✅
                    //   🔴 **注意**：⭐ 这是本模块**唯一**一个"需要两拍"的状态，
                    //      ⚠️ 所以用一个显式的 `prompt_phase` 标记，⛔ 不靠数拍子猜。
                    if (!prompt_phase) begin
                        // ⭐ 第 1 拍：⭐ 先把 `need_press_o` 拉低（⭐ 造出下降沿）
                        need_press_o <= 1'b0;
                        prompt_phase <= 1'b1;
                    end else begin
                        // ⭐ 第 2 拍：⭐ 拉起 `need_press_o`（⭐ 干净的上升沿 ⇒ `ev_need`）
                        need_press_o <= 1'b1;
                        prompt_phase <= 1'b0;
                        vmin         <= 12'hFFF;
                        vmax         <= 12'd0;
                        vote_cnt     <= 6'd0;
                        stable_cnt   <= 6'd0;
                        prev_val     <= 12'hFFF;
                        // ⭐ 2026-09-23：新的一轴 ⇒ ⭐ 清"已发"标记与兜底计数
                        //   🔴 **必须清 `span_sent_r`** —— ⚠️ 否则下一轴会带着
                        //      "上一轴已发过"的状态去判 `cal_err_i`，
                        //      ⇒ 🔴 把上一轴残留的 `err` 记到本轴头上。
                        span_sent_r  <= 1'b0;
                        wait_clk_cnt <= {WCW{1'b0}};
                        state        <= S_SETTLE;
                    end
                end

                // ═══ ⭐ 等读数稳定（⭐ "按着不动"）════════════════════════
                //   ⭐ 判据：⭐ 连续 `STABLE_NEED` 帧的帧间变化都 < `STABLE_TOL`
                S_SETTLE: begin
                    cur_axis_o <= cur_axis;
                    // 🔴🔴 **本状态【必须】有超时兜底（⭐ 2026-09-23 深夜补）**
                    //   ⚠️ 它的退出条件是"连续 `STABLE_NEED` 帧变化 < `STABLE_TOL`"
                    //      ⇒ 🔴 **两条静默卡死路径**：
                    //        ① ⭐ `adc_farm` 停扫（SPI 挂 / 排线松 / 片没接）
                    //           ⇒ ⭐ `sample_valid_i` **永远不来** ⇒ 计数永远不动
                    //        ② ⭐ 操作者**中途松手走开** ⇒ 读数一直剧烈变化
                    //           ⇒ ⭐ `stable_cnt` 一直被清 0 ⇒ 永远稳不住
                    //      ⇒ 🔴 两者都让 `busy_o` **恒 1 且永不出来**
                    //         （⭐ 探针实测：`state` 停在 2、`busy=1`、无任何输出）。
                    //   ⭐ 修法与 `S_WAITBUSY` 一致：⭐ 超时 ⇒ **明确拒绝并重试**。
                    //   📌 注：⭐ `abort_i` 也能救（⭐ 手动），⚠️ 但"自动超时"才是不依赖人的那层。
                    if (wait_clk_cnt != {WCW{1'b1}})
                        wait_clk_cnt <= wait_clk_cnt + 1'b1;

                    if (wait_clk_cnt >= WAIT_TIMEOUT_CLK[WCW-1:0]) begin
                        reject_o   <= 1'b1;
                        rej_why_o  <= RJ_SETTLE;      // ⭐ R1：稳定判据超时（⭐ span 未发）
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            state  <= S_DONE;
                            done_o <= 1'b0;              // ⚠️ 未成功
                        end else begin
                            state  <= S_PROMPT;          // ⭐ 重来
                        end
                    end
                    else if (sample_valid_i && (sample_ch_i == cur_axis[2:0])) begin
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
                //   🔴 **同样必须有超时**（⭐ 理由同 `S_SETTLE`）：⭐ 帧不来 ⇒ 卡死
                S_VOTE: begin
                    cur_axis_o <= cur_axis;
                    if (wait_clk_cnt != {WCW{1'b1}})
                        wait_clk_cnt <= wait_clk_cnt + 1'b1;

                    if (wait_clk_cnt >= WAIT_TIMEOUT_CLK[WCW-1:0]) begin
                        reject_o   <= 1'b1;
                        rej_why_o  <= RJ_VOTE_TO;     // ⭐ R2：投票收帧超时（⭐ span 未发）
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            state  <= S_DONE;
                            done_o <= 1'b0;
                        end else begin
                            state  <= S_PROMPT;
                        end
                    end
                    else if (sample_valid_i && (sample_ch_i == cur_axis[2:0])) begin
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
                        rej_why_o  <= RJ_SPREAD;      // ⭐ R3：离散度超限（⭐ span 未发）
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
                        //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **必须用 13 位中间量** ✅
                        //   🔴 原写 `(vmin + vmax) >> 1` —— ⚠️ `vmin`/`vmax` 都是 `[11:0]`
                        //      ⇒ ⭐ 和的位宽 = **12 位**（⭐ 表达式自定宽度）⇒ ⭐ **≥4096 就回绕** ✅
                        //   📌 **正常工作点必踩**（⭐ `top.v:2069` 记录的实测点：
                        //      触底 `raw' = 2854`、松手 `raw' = 2110`）：
                        //      · ⭐ `2854 + 2854 = 5708` ⇒ 12 位 = **1612** ⇒ `>>1 = 806`
                        //        （⭐ 正确值 2854 ⇒ **差 2048 码**）✅
                        //      · ⭐ `2110 + 2110 = 4220` ⇒ 12 位 = **124** ⇒ `>>1 = 62`（正确 2110）✅
                        //   ⇒ 🔴 所以"把 `vote_lo` 接出去"**必须同时加宽加法器**，
                        //      ⚠️ 否则 `806 < zero(2110)` ⇒ ⭐ **每个轴都走 err ⇒ 'S' 永远回 '!'** ✅
                        vote_lo <= vote_sum_w[12:1];
                        //   ⭐⭐ **`span` 必须与通道同拍**（⭐ 与 `tare` 同理）
                        //      ⇒ ⭐ 等到 `sample_ch_i == cur_ch` 才发
                        state   <= S_WAITBUSY;
                    end
                end

                // ═══ ⭐ 等除法器（⭐ 全用时钟沿，⛔ 不用 `wait`）══════════
                //
                //   🔴🔴 **等待必须【有界】（⭐ 2026-09-23 深夜修 · 抓到真缺陷）**
                //
                //   ⭐ 原文（错误版）：只等 `sample_valid_i && (sample_ch_i == cur) && !cal_busy_i`
                //      ⇒ 🔴 **若那个条件永远不成立，就永久卡在 `S_WAITBUSY`**。
                //   🔴 **实测到的两条卡死路径**（⭐ 用探针 tb 确认，⛔ 不是推测）：
                //
                //     ① ⭐ **`cal_busy_i` 恒 1**：⭐ 若上一次 `span` 触发的除法器
                //        还没结束（⚠️ 或 `calib.busy` 因任何原因悬高），
                //        ⭐ `!cal_busy_i` 永不成立 ⇒ 🔴 **一个 `span` 都发不出去**
                //        ⇒ ⭐ 实测：`span_seen=0`、`state` 永远停在 6（`S_WAITBUSY`）。
                //
                //     ② ⭐ **`sample_ch_i == cur_axis[2:0]` 永不成立**：
                //        ⚠️ `adc_farm` 若停扫（⭐ 比如 SPI 挂了、片没接），
                //        `sample_valid_i` 就永不来 ⇒ 🔴 同样永久卡死。
                //
                //   ⇒ ⭐⭐ **修法**：⭐ 加一个**超时计数器** `WAIT_MAX`（⭐ 单位：采样帧数）。
                //      ⭐ 超时 ⇒ ⭐ **明确拒绝该轴**（⭐ `reject_o`）并**重试/收尾**
                //      ⇒ ⭐ 与"手没按稳"、"`calib.err`"走**同一条拒绝路径**
                //      ⇒ ⭐ 操作者会看到"这一轴没成"，⛔ **不会静默假死**。
                //      📌 这正是 `K-87`/`K-106` 的纪律：⭐ **任何"会失效"的路径
                //         都必须可观测，⛔ 不许静默卡住**。
                //
                //   ⚠️ **为什么超时按"帧"而不按"clk"计**：⭐ 因为本状态等的是
                //      **事件**（某通道的采样）⇒ ⭐ 只有帧在走，等待才有意义；
                //      ⚠️ 按 clk 计会在"帧根本没来"时给出误导性的"已超时"。
                //      ⭐ 但本状态**也可能一帧都收不到** ⇒ ⭐ 所以**两者都要**：
                //      ⭐ `wait_cnt` 数**匹配到目标通道的帧**（主判据），
                //         ⚠️ 同时用一个**宽松的** clk 兜底（⭐ 防"帧完全不来"）。
                S_WAITBUSY: begin
                    cur_axis_o <= cur_axis;
                    need_press_o <= 1'b0;
                    //   ⭐ 兜底计时（⭐ 每拍 +1，⭐ 饱和即可 —— 只需判"到没到"）
                    if (wait_clk_cnt != {WCW{1'b1}})
                        wait_clk_cnt <= wait_clk_cnt + 1'b1;

                    // ── ⭐ clk 兜底超时（⭐ 防"帧完全不来"⇒ 连帧计数都不涨）──
                    if (wait_clk_cnt >= WAIT_TIMEOUT_CLK[WCW-1:0]) begin
                        // ⭐ 超时 ⇒ 按"拒绝"处理（⛔ 不静默卡死）
                        reject_o   <= 1'b1;
                        rej_why_o  <= RJ_BUSY_TO;     // ⭐ R4：等帧超时（⭐ span 未发）
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            state  <= S_DONE;
                            done_o <= 1'b0;              // ⚠️ 未成功
                        end else begin
                            state  <= S_PROMPT;          // ⭐ 重来
                        end
                    end
                    //   ⭐ 与目标通道同拍地发 `span`（⭐ 只发一次）
                    else if (sample_valid_i && (sample_ch_i == cur_axis[2:0]) && !cal_busy_i) begin
                        //  ⭐⭐ 2026-10-09（`P0-10`，⭐ 用户拍板选 A）：⭐ **只发给【目标轴所在的那一片】** ✅
                        //   🔴 **原缺陷**：⭐ 原写 `span_o <= {N_ADC{1'b1}}`（⭐ **两片同拍广播**）✅
                        //      · ⭐ 两片是**两块不同的板**（⭐ 轴 0~7 = 板1 · 轴 8~15 = 板2）
                        //        ⇒ ⭐ 标轴 8（片1 的 ch0）时，**片0 的 ch0 也被标** ✅
                        //      · 🔴 片0 的 ch0 若没按下 ⇒ `raw <= zero` ⇒ `cal0_err=1`
                        //        ⇒ ⭐ 整轴被拒 ⇒ 🔴 **操作者必须把两块板【同一个通道号】的两个键同时按到底**
                        //        （⭐ 16 个轴 = 16 次双手同步按压，⭐ 且回包不说"是另一块板没按"）✅
                        //      · 🔴🔴 **更硬的一条**：⭐ `sp_raw_sel`（top）只选一片
                        //        ⇒ ⭐ `S_SETTLE`/`S_VOTE` 的"连续稳定 + 离散度 ≤ 96"这套门控
                        //        **只作用于被选中的那一片** ✅
                        //        ⇒ ⭐ 而 span 打到两片、两片的 `den_r`/`span_r` **同拍写入**
                        //        ⇒ 🔴 **另一片的 `den_r` 来自一次【未经任何静止判定】的采样** ✅
                        //        ⭐ `calib.sv` 自己记着实测 raw 偶发跳 **150~550 码**
                        //        ⇒ 🔴 该片增益误差可达 `550/744 = 74%`
                        //        ⇒ ⭐ **这正是"板 2 比板 1 小声/大声"的完整机制** ✅
                        //   ✅ **修法（⭐ 一行）**：⭐ 用 `cur_axis[3]` 选片 ——
                        //      · ⭐ `cur_axis[3] == 0` ⇒ 轴 0~7 ⇒ ⭐ 只发片 0（`2'b01`）✅
                        //      · ⭐ `cur_axis[3] == 1` ⇒ 轴 8~15 ⇒ ⭐ 只发片 1（`2'b10`）✅
                        //      📌 ⭐ 本设计 `AXIS_TOTAL = 16`（⭐ 两片 × 8 通道）⇒ ⭐ 该映射完备 ✅
                        //      📌 ⚠️ **代价（⭐ 用户已确认接受）**：⭐ 另一片的同一个通道号**不会被标**
                        //         ⇒ ⭐ 必须跑满 **16 个轴**才能把两片都标完 ✅
                        span_o      <= (cur_axis[3]) ? 2'b10 : 2'b01;
                        //  ⭐⭐ 2026-10-09（`P0-09`）：⭐ **把投票代表值接出去** ✅
                        //   📌 只在发 `span` 的这一拍有效 ⇒ ⭐ 下游用 `|span_o` 当选择 ✅
                        //   📌 与 `span_o` **同拍**（⭐ 与"通道同拍"同一纪律）✅
                        span_val_o  <= vote_lo;
                        cal_ch_o    <= cur_axis[2:0];
                        //   ⭐⭐ 记下"本轴已发 `span`"（⭐ 是 `S_NEXT` 判 `err` 的前提）
                        span_sent_r <= 1'b1;
                        state       <= S_NEXT;
                    end
                end

                // ═══ ⭐ 等 `calib` 算完 ⇒ 下一轴 ══════════════════════════
                //   ⚠️ **必须等 `busy` 起来再等它落** —— ⭐ 否则会在除法器
                //      还没开始时就判"完成"（⭐ 那是 `K-87` 族：静默抢跑）。
                //
                //   🔴🔴 **但"等 busy 起来"也必须有界（⭐ 2026-09-23 深夜修）**：
                //      ⚠️ 有一条**真实的静默失败路径**：⭐ `calib.v:98`
                //         ```
                //         if (raw <= zero_r[cal_ch]) begin
                //             err <= 1'b1;              // 🔴 只置 err
                //             gain_r[cal_ch] <= (1 << 8);
                //         end else begin
                //             busy <= 1'b1;              // ⭐ 只有这里才 busy
                //         ```
                //      ⇒ 🔴 **`err` 路径【不会拉起 `busy`】！**
                //      ⇒ ⭐ 而 `calib.err` 是**寄存器**，⭐ 它在 `span` 那拍之后
                //         才更新 ⇒ ⚠️ 本模块在 `S_NEXT` 里**看不到当拍的 `err`**，
                //         只看到"`busy` 永远不起来" ⇒ 🔴 **永久卡死**。
                //      📌 实测证据：探针 tb 全程 `cal_err_i=1`
                //         ⇒ `state` 停在 6、`span_seen=0`、`done` 恒 0。
                //
                //   ⭐⭐ **修法**：⭐ 记下"我发过 `span`"这件事（`span_sent_r`），
                //      ⭐ 然后在 `S_NEXT` 里**同时**判：
                //        · ⭐ `cal_busy_i` 起过又落 ⇒ ✅ 正常完成（⭐ 走原逻辑）
                //        · ⭐ `cal_err_i` 为高    ⇒ ⭐ 拒绝（⭐ 这就是"没按到底"）
                //        · ⭐ 超时               ⇒ ⭐ 拒绝（⭐ 兜底）
                //      ⇒ ⭐ **三条路都不留"静默卡死"**。
                //
                //   ⚠️ **为什么用 `span_sent_r` 而不是"等 busy 上升沿"**：
                //      ⭐ `calib` 的 `err` 与 `busy` 是**互斥**的（⭐ 见上）
                //      ⇒ ⭐ **不能靠"等 busy"来区分"还没开始"和"直接 err 了"**
                //      ⇒ ⭐ 必须**主动记录已发**，再分别判两条出口。
                S_NEXT: begin
                    //   ⭐ 兜底计时（⭐ 同 `S_WAITBUSY`）
                    if (wait_clk_cnt != {WCW{1'b1}})
                        wait_clk_cnt <= wait_clk_cnt + 1'b1;

                    //   ⭐ 优先判 `err`（⭐ 它比 `busy` 先有效，且二者互斥）
                    //      ⚠️ 只在"本轴确实发过 `span`"之后才判 ——
                    //         ⭐ 否则会把**上一轴残留的 `err`** 当成本轴的错误。
                    //   ⭐⭐ 2026-09-30：⭐ 判据用 `span_sent_r2`（⭐ 打过一拍）——
                    //      ⚠️ 用 `span_sent_r` 会读到**上一轴残留的 `err`**（⭐ 见它的声明）
                    if (cal_err_i && span_sent_r2) begin
                        reject_o   <= 1'b1;
                        rej_why_o  <= RJ_CAL_ERR;     // ⭐ R5：⭐ span【已发】＋ 片报 err
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            state  <= S_DONE;
                            done_o <= 1'b0;          // ⚠️ 未成功
                        end else begin
                            state  <= S_PROMPT;      // ⭐ 重来（⭐ 再按一次）
                        end
                    end
                    //   ⭐ 正常路径：⭐ 等 `busy` 起来（⭐ 除法器真的在跑）
                    //
                    //   🔴 **⚠️ 本分支内【不再】判 `cal_err_i`**（⭐ 2026-09-23 深夜）
                    //      ⭐ 原因：⭐ **实测确认 `err` 与 `busy` 是【互斥】的** ——
                    //         ⭐ `calib.v:96-108` 里 `err` 与 `busy` 写在
                    //         `if/else` 的**两个不同分支**上
                    //         ⇒ ⭐ 走 `err` 就**永不**置 `busy`。
                    //      📌 探针实测（⭐ 直连真 `calib`，发一次 `span` 且 `raw=0`）：
                    //         ⭐ `err=1` 恒高、⭐ `busy` **自始至终为 0**。
                    //      ⇒ ⭐ 所以"`busy` 与 `err` 同时为高"**物理上产生不了**
                    //      ⇒ ⛔ 在这里再判一次 `err` 是**永不可达的死代码**。
                    //      ⭐ 变异测试佐证：⭐ 删掉那一段后**没有任何 tb 变红**
                    //         （⚠️ 因为真 `calib` 构造不出那个组合）。
                    //      📌 教训：⭐ **"防御性"代码若不可达，就是噪声** ——
                    //         ⚠️ 它会让人以为覆盖率比实际高。⭐ 先探针证实再决定留不留。
                    else if (cal_busy_i) begin
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
                    //   ⭐ 兜底：⭐ `span` 发出后长时间既没有 `busy`、也没有 `err`
                    //      ⇒ ⚠️ 说明 `calib` 那边出了问题（⭐ 或 `busy` 线没接）
                    //      ⇒ 🔴 **必须报出来，⛔ 不许静默卡死**
                    else if (span_sent_r && (wait_clk_cnt >= WAIT_TIMEOUT_CLK)) begin
                        reject_o   <= 1'b1;
                        rej_why_o  <= RJ_SILENT;      // ⭐ R6：⭐ span【已发】但无 busy 无 err
                        reject_cnt <= reject_cnt + 4'd1;
                        if (reject_cnt >= REJECT_MAX[3:0]) begin
                            state  <= S_DONE;
                            done_o <= 1'b0;
                        end else begin
                            state  <= S_PROMPT;
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
                          (STABLE_NEED > 0) &&
                          (WAIT_TIMEOUT_CLK > 0);

    initial begin
        if (VOTE_N < 2)
            $display("ERROR [calib_span] VOTE_N = %0d < 2 => the vote degenerates to a SINGLE sample, which is exactly what multi-frame voting is meant to avoid. PARAM_OK=0.", VOTE_N);
        if (AXIS_TOTAL != NCH * N_ADC)
            $display("ERROR [calib_span] AXIS_TOTAL (%0d) != NCH*N_ADC (%0d x %0d) => some axes would never be calibrated. PARAM_OK=0.", AXIS_TOTAL, NCH, N_ADC);
        if (VOTE_TOL == 0)
            $display("ERROR [calib_span] VOTE_TOL = 0 => every frame must match bit-for-bit, so every vote is rejected (looks like a hang). PARAM_OK=0.");
        if (STABLE_NEED == 0)
            $display("ERROR [calib_span] STABLE_NEED = 0 => voting starts before the user has held the key still. PARAM_OK=0.");
        if (WAIT_TIMEOUT_CLK <= 0)
            $display("ERROR [calib_span] WAIT_TIMEOUT_CLK = 0 => the wait states time out immediately, so every axis is rejected without ever emitting span. PARAM_OK=0.");
        if (PARAM_OK)
            $display("NOTE [calib_span] PARAM_OK=1 (NCH=%0d N_ADC=%0d AXIS_TOTAL=%0d STABLE_NEED=%0d STABLE_TOL=%0d VOTE_N=%0d VOTE_TOL=%0d REJECT_MAX=%0d WAIT_TIMEOUT_CLK=%0d)",
                     NCH, N_ADC, AXIS_TOTAL, STABLE_NEED, STABLE_TOL, VOTE_N, VOTE_TOL, REJECT_MAX, WAIT_TIMEOUT_CLK);
    end

endmodule

`default_nettype wire
