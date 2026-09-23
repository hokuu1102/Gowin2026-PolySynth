`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// event_extract.v · W3a 语义层：触发 / 拨弦 / 不应期（⭐ 先触发后修正）
//
// ⭐ 冻结定义（`files/20-代码/代码总览图.md:196`）：
//    *"触发 / 拨弦 / 不应期（⭐ **先触发后修正**）"*
// ⭐ 产品决议 `A2c`（`产品形态决议清单.md`）：*"不应期是【事后封锁】，⛔ 不是【事前等待】"*
//    ⇒ ⭐ **首次越阈【立即】产生事件**（⛔ 不等稳定）
//
// ── 🔴 本模块的阶段划分（⭐ 2026-09-23 用户拍板："先做 MVP，但预留好接口"）──────
//
//   ⭐ **阶段 1（MVP，本版实现）= 单轴越阈 ⇒ `note_on` / 回落 ⇒ `note_off`**
//      ⇒ ⭐ 目的：⭐ **"按琴键出声"（本周硬指标）**
//
//   ⭐ **阶段 2（接口已预留，逻辑待填）= 滑音 / 双音**
//      · ⭐ **滑音**：`dA < −TH` **且** `dB > +TH`（一减一增 = 反向）
//        ⇒ ⭐ 发一个音，`pitch_upd` 连续改音高，⭐ 最终落到 `B`
//      · ⭐ **双音**：`dA ≥ 0` **且** `dB ≥ 0`（都不减）且都越阈
//        ⇒ ⭐ **同时发两个音**
//      🔴 **预留的接口**（⭐ 见下方 `slide_*` / `two_note_*` 输出）
//         ⇒ ⚠️ **本版恒为 0**，⭐ 阶段 2 填逻辑时**⛔ 不用改端口**
//
// ── ⭐ 输入（← `axis_snapshot`，⭐ 同帧、原子）────────────────────────────────
//   `snap_valid_i`  ⭐ 一帧一次的原子快照脉冲
//   `pos_i`         ⭐ 16 轴行程（轴 i = `[i*POS_W +: POS_W]`）
//   `delta_i`       ⭐ 16 轴**带符号**增量（⭐ 滑音/双音的原料）
//
// ── ⭐ 输出（→ `evt_merge` → `note_manager`）─────────────────────────────────
//   ⭐ **事件通路**（阶段 1 就用）：
//      `evt_valid_o` 单周期脉冲 · `evt_axis_o` · `evt_kind_o`(0=on/1=off/2=pluck)
//      `evt_depth_o`（触发时的行程 ⇒ ⭐ 供 `param_extract` 算力度）
//   ⭐ **滑音/双音预留接口**（阶段 2 填，⛔ 本版恒 0）：
//      `slide_valid_o` · `slide_axis_o` · `slide_dir_o`（+1 = 向右滑、−1 = 向左）
//      `two_note_valid_o` · `two_note_axis_a_o` · `two_note_axis_b_o`
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001**（`K-91`：⛔ 不用 SV 专有构造，否则整模块被静默丢弃）
//   · ⭐ **同步复位、低有效**、⭐ **单时钟域 50 MHz**
//   · ⭐ **`valid` 与数据必须同拍**（`K-109`：⚠️ 本项目已犯过的真缺陷）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module event_extract #(
    // ⭐ 轴数（⭐ 16 = 2 片 ADC × 8 通道）
    parameter integer AXIS_N = 16,
    // ⭐ 行程位宽（12 = MCP3208 满量程）
    parameter integer POS_W  = 12,
    // ⭐ 增量位宽（⭐ 必须 = `POS_W + 1`，带符号）
    parameter integer DW     = POS_W + 1,
    // ⭐ 轴号位宽（4 ⇒ 最多 16 轴，⭐ 与 `note_manager.AXIS_W` 一致）
    parameter integer AXIS_W = 4,

    // ── ⭐ 阈值参数（⭐ 用户拍板"先按建议写、做成 parameter"）────────────────
    //   ⚠️ **全部上板可调** —— ⛔ 不要写死
    //   ⭐ 触发阈 ≈ 25% 行程（⚠️ 12 位满量程 4095 ⇒ 0x400 = 1024）
    parameter [POS_W-1:0] TRIG_TH   = 12'h400,
    //   ⭐ 释放阈（**迟滞**：⭐ 比触发阈低 ⇒ ⚠️ 防回中弹簧振荡造成多次翻转）
    parameter [POS_W-1:0] REL_TH    = 12'h300,
    //   ⭐ **Δ 阈值**（⭐ 滑音/双音判据用）
    //      ⚠️ 依据：滑动时每帧行程变约 `4096/500 ≈ 8` 个码
    //      ⇒ ⭐ 取 8：**大于手抖/噪声**、**小于真实滑动速度**
    parameter signed [DW-1:0] DELTA_TH = 13'sd8,
    //   ⭐ **不应期**（单位：快照帧数）
    //      ⚠️ 一帧 ≈ 196 µs（`adc_farm` 实测）⇒ **150 帧 ≈ 30 ms**
    parameter integer REFRACT_N = 150
) (
    input  wire                    clk,
    input  wire                    rst_n,        // ⭐ 同步复位、低有效

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 判键使能（⭐ 2026-09-23 新增，🔴 修一个**上板必然遇到**的真缺陷）
    //
    //   🔴 **为什么需要**（⭐ 实测发现）：
    //      ⚠️ 上电后 `calib_autotare` 要等 `DELAY_CLK`（默认 200 ms）才做 `tare`，
    //         ⭐ 而**在那之前 `pos` 是【未标定的脏值】**：
    //         · 未 `tare` ⇒ `zero = 0` ⇒ `pos = 4095 − raw = 4095 − 1985 = 2110`
    //         · ⭐ 而阈值是**按标定后的空间**设的（`TRIG_TH = 149`）
    //         ⇒ 🔴 **2110 ≫ 149 ⇒ 16 个轴【全被判成"按下"】**
    //      ⇒ 🔴 **开机瞬间起一堆音符**，⚠️ 而它们**本来就没被按过**
    //         ⇒ ⭐ 松手也关不掉（⭐ 因为对应的"按下"根本没发生过）
    //      ⭐ 实测证据：e2e tb 里 `n_on=8`（⭐ 我一次都没按）、
    //         `nm_gate = 0x08000000`（⭐ 一个 voice **恒 held**）。
    //
    //   ⭐ **语义上本来就该这样**：⭐ **"标定还没做好 ⇒ 读数不可信 ⇒ 不该判按键"**。
    //      ⚠️ 所以在标定完成前**锁住事件层**是**正确做法**，⛔ 不是绕过问题。
    //
    //   📌 **`enable_i = 0` 时的行为**：
    //      ⭐ **只清"按键状态"**（`key_on` / `refr`），⛔ **不产生任何事件**。
    //      ⚠️ 这样标定完成后**从干净状态开始** ⇒ ⭐ 不会把标定前的误触发延续下来。
    //      🔴 **注意**：⛔ 不是"冻结" —— ⚠️ 冻结会把脏状态**带过去**（⭐ 那就白锁了）。
    // ═══════════════════════════════════════════════════════════════════════
    input  wire                    enable_i,

    // ── 输入：⭐ 来自 `axis_snapshot`（同帧、原子）──────────────────────────
    input  wire                    snap_valid_i,
    input  wire [AXIS_N*POS_W-1:0] pos_i,
    input  wire [AXIS_N*DW-1:0]    delta_i,

    // ── 输出：事件通路（⭐ 阶段 1）──────────────────────────────────────────
    output reg                     evt_valid_o,
    output reg  [AXIS_W-1:0]       evt_axis_o,
    output reg  [1:0]              evt_kind_o,    // ⭐ 0=note_on 1=note_off 2=pluck
    output reg  [POS_W-1:0]        evt_depth_o,

    // ── 输出：滑音 / 双音【预留接口】（⭐ 阶段 2 填，⛔ 本版恒 0）─────────────
    output reg                     slide_valid_o,
    output reg  [AXIS_W-1:0]       slide_axis_o,
    output reg  signed [1:0]       slide_dir_o,   // ⭐ +1 = 向高音轴滑、−1 = 向低音轴滑
    output reg                     two_note_valid_o,
    output reg  [AXIS_W-1:0]       two_note_axis_a_o,
    output reg  [AXIS_W-1:0]       two_note_axis_b_o,

    // ── 输出：⭐ 溢出可见（⭐ `K-106` 纪律：⚠️ 溢出⛔ 不许静默）───────────────
    output wire                    overflow_o,    // ⭐ sticky（置位后保持）
    output wire [7:0]              lost_cnt_o     // ⭐ 累计丢弃数（**饱和**，⛔ 不回绕）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 每轴状态：⭐ **迟滞 + 不应期**
    //
    //   ⭐ `key_on[i]`  = 该轴当前是否"已按下"（⭐ 带迟滞的状态）
    //   ⭐ `refr[i]`    = 剩余不应期计数（⭐ >0 ⇒ 封锁中）
    // ═══════════════════════════════════════════════════════════════════════
    reg              key_on [0:AXIS_N-1];
    reg [15:0]       refr   [0:AXIS_N-1];    // ⭐ 16 位够 65535 帧（≈12.8 s）

    // ⭐ 逐轴扫描状态机（⭐ 一拍一个轴 ⇒ ⛔ 不会覆盖 FIFO 指针）
    //   ⚠️ `SAW` 位宽 = `$clog2(AXIS_N)`（⭐ 16 轴 ⇒ 4 位）
    localparam integer SAW = (AXIS_N <= 1) ? 1 : $clog2(AXIS_N);
    reg [SAW-1:0] scan_axis;
    reg           scanning;

    // ⭐ 逐轴扫描变量（⭐ 用 for 遍历 ⇒ 可综合、参数化）
    integer ai;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 事件缓冲：🔴 **修"同帧多轴丢事件"**（⭐ 本项目已犯过的缺陷类）
    //
    //   🔴 **⚠️ 我第一版的设计缺陷（2026-09-23，写完就发现）**：
    //      ⚠️ 我把 `evt_valid_o`/`evt_axis_o`/… 直接在 `for (ai...)` 循环里赋值
    //      ⇒ 🔴 **同一帧若有 2 个轴越阈**（⭐ 和弦 / 双音 / 快速扫键）
    //      ⇒ ⭐ **只有最后一个轴的事件存活，其余的【静默丢失】**。
    //      ⭐⭐ **这正是 `evt_merge` 要解决的"同拍相撞丢事件"的同族缺陷**
    //         ⇒ ⚠️ 而且更糟：⭐ **事件在进 `evt_merge` 之前就没了**，
    //            ⭐ `evt_merge` 的仲裁**根本救不了它**（⚠️ 它压根没收到）。
    //
    //   ⭐ **修法：在 `event_extract` 内部加一个【小 FIFO】**
    //      ⇒ ⭐ 一帧内检测到 N 个事件就 push N 次，⭐ **逐个吐出**（⛔ 不丢）
    //      ⭐ 与 `evt_merge` 同样的取舍：**同帧多事件时后面的晚几拍**
    //         （⚠️ 但一帧 9800 拍 ⇒ ⭐ **延迟完全在预算内**）。
    //
    //   ⭐ **深度取 4**：⚠️ 依据 —— ⭐ 一帧内最多"16 轴全部同时越阈"，
    //      但 ⚠️ 实际演奏中**同一帧内 2~3 个轴同时过阈**已是极限
    //      （⭐ 人手指不可能 16 个键在 196 µs 内同时按下）
    //      ⇒ ⭐ **4 够用**；⚠️ 溢出时**有 sticky 计数**（⛔ 不静默丢）
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer FIFO_D = 4;
    localparam integer FW     = 2;      // ⭐ 指针位宽（$clog2(4)）

    reg [AXIS_W-1:0] q_axis [0:FIFO_D-1];
    reg [1:0]        q_kind [0:FIFO_D-1];
    reg [POS_W-1:0]  q_depth[0:FIFO_D-1];
    reg [FW:0]       q_cnt;             // ⭐ 水位（多 1 位便于判满）
    reg [FW-1:0]     q_wr, q_rd;

    // ⭐ 溢出可见（⭐ `K-106` 纪律：⭐ **溢出必须有 sticky 指示 + 饱和计数**）
    reg              overflow_o_r;
    reg [7:0]        lost_cnt_r;

    // ⭐ 溢出可见（⭐ `K-106` 纪律：⭐ **溢出必须有 sticky 指示 + 饱和计数**）
    //   ⚠️ 为什么不静默丢：⭐ 丢的是**音符事件** ⇒ ⚠️ 丢 `note_off` ⇒ **挂音**
    //      （⭐ 这正是 `T38` 专门要防的失效模式）⇒ ⭐ **必须可见**。
    assign overflow_o = overflow_o_r;
    assign lost_cnt_o = lost_cnt_r;

    // ⚠️ **`ai` 是 `integer`（32 位）⇒ 用它做切片基址时⛔ 不要参与算术后再拼**
    //    🔴 教训（`83 号`/`L49`，⭐ 本会话已踩过一次）：
    //       ⭐ `12'h400 + c`（`c` 是 integer）会让**整个表达式升到 32 位**
    //       ⇒ ⚠️ 若再拼接就会**静默截断**。
    //    ⭐ 本模块只用 `ai` 做**索引**（⛔ 不做拼接）⇒ ✅ 安全。

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 主逻辑：⭐ **每帧扫描 16 个轴**
    //
    //   ⚠️ **为什么是"每帧"而不是"逐轴流水"**：
    //      ⭐ 输入已经是**同帧快照** ⇒ ⭐ 必须在**一帧内**看完全部轴，
    //      才能判断"相邻两轴"（⭐ 滑音/双音）。
    //   ⚠️ **一帧的时钟预算**：⭐ 一帧 196 µs @50 MHz = **9800 拍**
    //      ⇒ ⭐ 扫 16 个轴用 16 拍 ⇒ ⭐ **余量 600 倍**（⛔ 不是性能问题）。
    // ═══════════════════════════════════════════════════════════════════════

    // ⭐ 事件输出寄存器（⭐ 与 `evt_valid_o` **同拍锁存** —— ⭐ `K-109` 要求）
    //   ⭐ ⚠️ **关键**：`evt_*` 现在由 **FIFO 出队**驱动（⛔ 不是循环直接赋）
    //      ⇒ ⭐ **同拍性由"出队那一拍同时锁存数据"保证**。
    integer pi;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (ai = 0; ai < AXIS_N; ai = ai + 1) begin
                key_on[ai] <= 1'b0;
                refr  [ai] <= 16'd0;
            end
            q_cnt <= 0; q_wr <= 0; q_rd <= 0;
            overflow_o_r <= 1'b0;
            lost_cnt_r   <= 8'd0;
            scan_axis    <= {SAW{1'b0}};
            scanning     <= 1'b0;
            evt_valid_o      <= 1'b0;
            evt_axis_o       <= {AXIS_W{1'b0}};
            evt_kind_o       <= 2'd0;
            evt_depth_o      <= {POS_W{1'b0}};
            slide_valid_o    <= 1'b0;
            slide_axis_o     <= {AXIS_W{1'b0}};
            slide_dir_o      <= 2'sd0;
            two_note_valid_o <= 1'b0;
            two_note_axis_a_o<= {AXIS_W{1'b0}};
            two_note_axis_b_o<= {AXIS_W{1'b0}};
        end else begin
            // ⭐ 事件默认单周期
            evt_valid_o      <= 1'b0;
            slide_valid_o    <= 1'b0;
            two_note_valid_o <= 1'b0;

            // ── ⭐ 不应期递减（⭐ 每帧减 1）─────────────────────────────────
            if (snap_valid_i) begin
                for (ai = 0; ai < AXIS_N; ai = ai + 1)
                    if (refr[ai] != 16'd0) refr[ai] <= refr[ai] - 16'd1;
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ 逐轴扫描：⭐ **多拍状态机**（⭐ 一帧内每拍处理【一个】轴）
            //
            //   ⭐⭐ **`enable_i = 0` 时【清按键状态】**（⭐ 2026-09-23 新增）
            //      🔴 **为什么必须清、⛔ 不能只是"不扫描"**：
            //         ⚠️ 若只停止扫描，⭐ `key_on[]` 会**保留脏值** ——
            //         ⭐ 而脏值正是"标定前误判的按下"（⭐ 16 个轴全是 1）
            //         ⇒ 🔴 标定完成后**它们仍然"按着"** ⇒ ⭐ **一起音就永不释放**
            //         ⇒ ⭐ **等于白锁了**。
            //      ⭐ 所以 `enable_i = 0` 时把它清零 ⇒ ⭐ 标定完成后
            //         **从"全部松开"这个干净状态开始** ✅
            //      📌 这样也**天然正确**：⭐ 标定期间没人按键（⭐ 是上电阶段）。
            //
            //   🔴 **⚠️ 踩过的坑（2026-09-23，本模块第二版）**：
            //      ⚠️ 我原来在 `for (ai...)` 里直接 `q_wr <= q_wr + 1;`
            //      ⇒ 🔴 **`for` 循环里多次非阻塞赋值【读到的都是同一个旧 `q_wr`】**
            //      ⇒ ⭐ **所有 push 写同一个位置 ⇒ 互相覆盖，只剩最后一个**
            //      （⭐ 实测：3 个轴同帧越阈 ⇒ **只吐 1 个事件**）
            //      ⭐ 这**正是"单套 `evt_*` 直接赋值"缺陷的翻版** —— ⚠️ 换汤没换药。
            //
            //   ⭐⭐ **正解 = 【一拍一个轴】的状态机**：
            //      · ⭐ 一帧 9800 拍、16 个轴 ⇒ ⭐ **每轴有 600 拍预算**（⛔ 不是性能问题）
            //      · ⭐ **每拍最多 push 1 条** ⇒ ⭐ `q_wr`/`q_cnt` 每拍只加一次

            // ⭐⭐ **使能判定：⭐ 悬空（`x`/`z`）视为【使能】**
            //   🔴🔴 **⚠️ 为什么不能用 `!enable_i`**（⭐ 2026-09-23 踩到，
            //      🔴 回归里一次挂了 3 个 tb）：
            //      ⚠️ `enable_i` 为 `x` 时，⭐ `if (!enable_i)` 在 Verilog 里
            //         **既不为真也不为假** ⇒ 🔴 **两个分支都不执行**
            //         ⇒ ⭐ **事件层彻底停摆**。
            //      ⚠️ 而**老 tb（`tb_event_extract`）不接这个新端口**
            //         ⇒ ⭐ 悬空 = `x` ⇒ 🔴 **那个 tb 直接挂掉**。
            //   ⇒ ⭐ **正解：显式判 0** —— ⭐ 只有【明确的 0】才代表"未使能"，
            //      ⭐ 而 `x`/`z`（悬空）按【使能】处理
            //      ⇒ ⭐ **不接该端口的老 tb 行为与改动前完全一致** ✅
            //   📌 与 `mcp3208_model` 的 `ovr_en_i` 恰好相反：
            //      ⭐ 那里"悬空 = 不启用"（⛔ 不能误触发**新**功能），
            //      ⭐ 这里"悬空 = 启用"（⛔ 不能让**老**用例失效）。
            //      ⭐ 两者都是**向后兼容优先**。
            if (enable_i === 1'b0) begin
                //   ⭐ 清"按住"状态 + 不应期（⭐ 见上方说明）
                //   ⚠️ 用循环逐个清（⭐ Verilog-2001 里数组不能整体赋 0）
                for (ai = 0; ai < AXIS_N; ai = ai + 1) begin
                    key_on[ai] <= 1'b0;
                    refr  [ai] <= 16'd0;
                end
                scanning <= 1'b0;
            end else begin
            //        ⇒ ⭐ **结构上不可能覆盖** ✅
            //      · ⭐ 且**天然可扩展**：⭐ 阶段 2 的"相邻对"判定只需多存一个轴的值
            // ═══════════════════════════════════════════════════════════════
            if (snap_valid_i) begin
                // ⭐ 快照到达 ⇒ ⭐ 开始本轮扫描（⭐ 从轴 0 起）
                //   ⚠️ **使能判定已在【外层】做过**（⭐ 见上方 `enable_i === 1'b0`）
                //      ⇒ ⭐ 走到这里说明**已使能** ⇒ ⭐ 直接开扫，⛔ 不再重复判
                //      （⭐ 重复判会让"悬空=使能"的口径**不一致** ⇒
                //        ⚠️ 老 tb 仍会挂 —— ⭐ 这是我第一版的错）。
                scan_axis <= 4'd0;
                scanning  <= 1'b1;
            end else if (scanning) begin
                // ⭐ 处理【当前】轴（⭐ 一拍一个）
                //   ⚠️ **`scan_axis` 是寄存器** ⇒ ⭐ 用它索引时先落成局部变量
                if (!key_on[scan_axis]) begin
                    if (pos_i[scan_axis*POS_W +: POS_W] >= TRIG_TH) begin
                        if (refr[scan_axis] == 16'd0) begin
                            key_on[scan_axis] <= 1'b1;
                            refr  [scan_axis] <= REFRACT_N[15:0];
                            // ⭐ push（⭐ 每拍至多一次 ⇒ ⛔ 不会覆盖）
                            if (q_cnt < FIFO_D[FW:0]) begin
                                q_axis [q_wr] <= scan_axis;
                                q_kind [q_wr] <= 2'd0;                              // note_on
                                q_depth[q_wr] <= pos_i[scan_axis*POS_W +: POS_W];
                                q_wr  <= q_wr + 1'b1;
                                q_cnt <= q_cnt + 1'b1;
                            end else begin
                                overflow_o_r <= 1'b1;                                // ⭐ sticky
                                if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
                            end
                        end
                    end
                end else begin
                    if (pos_i[scan_axis*POS_W +: POS_W] < REL_TH) begin
                        key_on[scan_axis] <= 1'b0;
                        if (q_cnt < FIFO_D[FW:0]) begin
                            q_axis [q_wr] <= scan_axis;
                            q_kind [q_wr] <= 2'd1;                                  // note_off
                            q_depth[q_wr] <= pos_i[scan_axis*POS_W +: POS_W];
                            q_wr  <= q_wr + 1'b1;
                            q_cnt <= q_cnt + 1'b1;
                        end else begin
                            overflow_o_r <= 1'b1;
                            if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
                        end
                    end
                end

                // ⭐ 推进扫描指针（⭐ 扫完 16 个轴就停）
                if (scan_axis == (AXIS_N - 1)) begin
                    scanning  <= 1'b0;
                    scan_axis <= 4'd0;
                end else begin
                    scan_axis <= scan_axis + 4'd1;
                end
            end   // ⭐ 关闭 `enable_i` 的 `else`（⭐ 2026-09-23 新增）
            end   // ⭐ 关闭 `if (snap_valid_i) ... else if (scanning)`

            // ── ⭐⭐ 出队：⭐ **每拍吐一个**（⭐ 与数据同拍锁存）───────────────
            //   ⚠️ **必须"出队那一拍同时锁存数据"** —— ⭐ 否则就是
            //      `K-109` 那个"valid 与 data 不同拍"的老缺陷。
            if (q_cnt != 0) begin
                evt_valid_o <= 1'b1;                      // ⭐ 与下面三个字段同一拍
                evt_axis_o  <= q_axis [q_rd];
                evt_kind_o  <= q_kind [q_rd];
                evt_depth_o <= q_depth[q_rd];
                q_rd  <= q_rd + 1'b1;
                q_cnt <= q_cnt - 1'b1;
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ 阶段 2 预留：滑音 / 双音（🔴 **本版恒 0**）
            //
            //   ⭐ 判据（⭐ 用户 2026-09-23 定义）：
            //      · **滑音** = `dA < −DELTA_TH` 且 `dB > +DELTA_TH`
            //        ⇒ ⭐ `slide_valid_o = 1`，⭐ `slide_dir_o` 指向"行程变大"的那个轴
            //      · **双音** = 两个轴都越阈、且 `dA ≥ 0` 且 `dB ≥ 0`
            //        ⇒ ⭐ `two_note_valid_o = 1`，⭐ 两个轴号同时给出
            //   🔴 **本版恒 0** ⇒ ⚠️ 下游（`evt_merge`）接上去也**不会误触发**
            //      ⇒ ⭐ **接口预留但不改变行为**（⭐ 这正是"预留好接口"的落地方式）
            // ═══════════════════════════════════════════════════════════════
            // TODO(阶段 2): 在 snap_valid_i 那一拍扫描 (ai, ai+1) 相邻对，
            //               用 delta 判方向 ⇒ 填 slide_* / two_note_*。
            //   ⚠️ 注意：⭐ "相邻"是【硬件布局】决定的（⛔ 不是轴号相邻）
            //      ⇒ ⭐ 需要一张【邻居表】（⭐ 见 `霍尔键位-CH映射-20260923.md`）
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检（与既有模块同一套路）
    //   ⚠️ 这些组合会**静默失效**，⚠️ 而且**现象极难定位**：
    //     ① `TRIG_TH <= REL_TH` ⇒ 🔴 **没有迟滞** ⇒ ⚠️ 抖动造成**反复触发/释放**
    //        （⭐ 摇杆回中弹簧振荡 ⇒ ⭐ 一次按下产生多个事件）
    //     ② `DELTA_TH <= 0` ⇒ 🔴 **滑音判据恒成立** ⇒ ⚠️ 任何微小噪声都判成滑音
    //     ③ `DW < POS_W+1` ⇒ 🔴 **增量符号错**（⭐ 与 `axis_snapshot` 同一约束）
    //     ④ `REFRACT_N == 0` ⇒ ⚠️ **不应期关闭** ⇒ ⚠️ 抖动重复触发
    // ═══════════════════════════════════════════════════════════════════════
    localparam PARAM_OK = (TRIG_TH > REL_TH) && (DELTA_TH > 0) &&
                          (DW >= (POS_W + 1)) && (REFRACT_N > 0);

    initial begin
        if (TRIG_TH <= REL_TH)
            $display("ERROR [event_extract] TRIG_TH (0x%03h) <= REL_TH (0x%03h) => NO HYSTERESIS: a bouncing contact will emit repeated on/off events. PARAM_OK=0.",
                     TRIG_TH, REL_TH);
        if (DELTA_TH <= 0)
            $display("ERROR [event_extract] DELTA_TH = %0d <= 0 => the slide test is ALWAYS true, so any noise reads as a slide. PARAM_OK=0.",
                     DELTA_TH);
        if (DW < (POS_W + 1))
            $display("ERROR [event_extract] DW = %0d < POS_W+1 = %0d => the signed delta can overflow and the sign goes WRONG. PARAM_OK=0.",
                     DW, POS_W + 1);
        if (REFRACT_N == 0)
            $display("ERROR [event_extract] REFRACT_N = 0 => the refractory window is DISABLED => contact bounce emits repeated events. PARAM_OK=0.");
        if (PARAM_OK)
            $display("NOTE [event_extract] PARAM_OK=1 (AXIS_N=%0d TRIG_TH=0x%03h REL_TH=0x%03h DELTA_TH=%0d REFRACT_N=%0d)",
                     AXIS_N, TRIG_TH, REL_TH, DELTA_TH, REFRACT_N);
    end

endmodule

`default_nettype wire
