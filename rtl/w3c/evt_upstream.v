`timescale 1ns/1ps
// evt_upstream.v · ⭐⭐ 2026-10-14：⭐ **上行帧 v1.1 的 14 B 实时事件流**（⭐ 用户要求"尽快弄回传" ✅）
//
//   ⭐ **干什么**：⭐ 把 `evt_merge` 合流后的**每一个 note 事件**按 **v1.1 的 14 B 帧**
//      推给 ready/push 下游（⭐ `top.v` 里与 `'Y'` 导出、命令回包**共用同一条 TX** ✅）
//
//   ⭐⭐ **帧格式（⭐ 权威依据：ESP32 侧 `esp32/tools/evt2midi/frame_format.py` ✅
//        —— ⭐ 那是"上行格式的唯一定义处" ✅）**：
// ```
//   [0]     0xA5   帧头（⭐ ⛔ 与 ASCII 流天然不相交 —— ASCII 全 ≤ 0x7F ✅）
//   [1]     类型   0x01=note_on · 0x02=note_off
//   [2]     seq    8 位序号（⭐ 短窗口丢帧检测）
//   [3..6]  tick   32 位自由运行计数器（⭐ 大端；⭐ Δt 取模 2³² ✅）
//   [7]     axis   轴号 0..15
//   [8..11] phase_inc 32 位（⭐ 大端）—— 🔴 **必须是全宽 32 位**
//   [12]    vel    8 位（0..255）
//   [13]    校验   XOR，覆盖 **[0..12]（⭐ 含帧头 0xA5）**
//           ⭐⭐ 2026-10-14 更正：⭐ 原来是 `[1..12]`（⛔ 不含 0xA5），
//           ⚠️ 与 ESP32 侧 `frame_format.py:165`（`for x in b[:-1]`）**不一致**
//           ⇒ ⭐ **已按 ESP32 侧改为【含 0xA5】** ✅
//   帧长 = 14 B
// ```
//
//   🔴🔴 **为什么必须 32 位 `phase_inc`**（⭐ 这是本模块存在的**唯一理由** ✅）：
//      ⭐ 线上**旧格式**（9 B，`rec_dump`/`evt_uart_rx`）只给 `inc` **21 位** ✅
//      ⇒ ⭐ A4 的 `phase_inc` = **38 702 840** ⇒ 🔴 **21 位上限只有 2 097 152**
//      ⇒ ⭐ **真实音高塞不进去** ⇒ ⚠️ 实测导出值 **11236**（⭐ 完全是垃圾 ✅）
//      ⇒ 🔴 所以**导出的录音⛔ 不能转 MIDI**；⭐ 而本模块走**全宽 32 位** ⇒ **音高正确** ✅
//      📌 依据：⭐ `evt_merge` 的 `evt_phase_inc_o` 就是 `PHASE_W`(=32) 全宽 ✅
//
//   ⭐ **与 ESP32 侧的分工**：⭐ 他们的解析器**已经支持** `0x01`/`0x02` 的 14 B 帧
//      （⭐ 白名单里就有 ✅）⇒ ⭐ **本模块落地即可，⛔ 不需要跨侧协调** ✅
//      📌 而 `0x05 transport_start` / `0x10 tablesync` 是**另外两条**（⭐ 本轮不做 ✅）
//
//   🔴 **三条硬约束**：
//      ① ⭐ **事件 FIFO 必须够深**：⭐ 一帧 14 B @ 500 kbps = **280 µs ≈ 14000 拍**，
//         而事件可以**同拍连来**（⭐ 16 轴齐按）⇒ ⚠️ 没有 FIFO 会**丢事件** ✅
//      ② ⭐ **溢出必须可见**：⭐ `drop_cnt_o`（饱和）+ `overflow_o`（sticky）
//         —— ⭐ `K-106`：⛔ 不许静默丢 ✅
//      ③ ⭐ **`busy_o` 覆盖整帧** ⇒ ⭐ 顶层据此把 TX 让给本模块 ✅
//
//   ⚠️ **声明必须先于使用**（⭐ 本项目踩过：⭐ `top.v:2880-2881` 的注释 ✅）——
//      所以下面 `pop_q` 等状态寄存器**声明在 FIFO 之前** ✅
//
//   ⛔ 纪律：Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz
//   ⚠️ 本文件必须【无 BOM】（⭐ 见 `tools/check_no_bom.ps1`）
`default_nettype none

module evt_upstream #(
    parameter integer PHASE_W = 32,
    parameter integer AXIS_W  = 4,
    parameter integer VEL_W   = 8,
    //  ⭐⭐ 2026-10-16：⭐ **音色位宽**（⭐ 与 `note_manager.TIMBRE_W` 同口径 = 2 ✅）
    parameter integer TIMBRE_W = 2,
    parameter integer FIFO_D  = 16,          // ⭐ 事件 FIFO 深度
    parameter [7:0]   HDR     = 8'hA5,
    //  ⭐ 帧长 = 1 帧头 + 1 类型 + 1 seq + 4 tick + 1 axis + 4 inc + 1 vel + 1 校验
    parameter integer FRAME_B = 14,
    //  ⭐ FIFO 深度输出的位宽（⭐ `FIFO_D=16` ⇒ 0..16 ⇒ 5 位 ✅）
    //     ⚠️ ⭐ 必须是**参数**，⛔ 不能用 body 里的 `localparam` ——
    //        🔴 `localparam` **不能出现在端口表里** ✅
    parameter integer LEVEL_W = 5
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── ⭐ 事件抽头（⭐ 与 `note_manager` 看到的是**同一拍** ✅）──────────────
    input  wire                  evt_valid_i,
    input  wire [AXIS_W-1:0]     evt_axis_i,
    input  wire [PHASE_W-1:0]    evt_phase_inc_i,
    input  wire [VEL_W-1:0]      evt_velocity_i,
    input  wire [1:0]            evt_kind_i,      // ⭐ 1 = off；⭐ 其余（on/pluck）都算 note_on
    //  ⭐⭐ 2026-10-15：⭐ **音色**（⭐ 给 ESP32 回传 MIDI 用 ✅）
    //     🔴 **为什么加**：⭐ ESP32 侧要把上行事件转成 MIDI ⇒ ⭐ MIDI 需要
    //        **program change**（音色）⇒ ⚠️ 而帧里原来**没有这个字段**
    //        （⭐ `rec_dump.v` 的原话："Timbre is not carried by this upstream frame."）
    //     ✅ **怎么加（零代价）**：⭐ 帧的 `[7]` 字节是 `axis`（⭐ 只用低 4 位）
    //        ⇒ ⭐ **高 4 位本来就空着** ⇒ ⭐ 拿 2 位放音色
    //        ⇒ **帧长 / 帧类型 / 帧头 / 校验逻辑全不变** ✅
    //     ⚠️ **向后兼容**：⭐ 音色 = 0（BASS）时 `[7]` 与原来**完全相同** ✅
    //     🔴 **协调要求**：⭐ ESP32 侧必须**同时**改成 `axis = f[7] & 0x0F`
    //        （⭐ 见 `esp32/tools/evt2midi/frame_format.py`）
    //        ⇒ ⚠️ **只烧一边会出现"音高全乱"** ✅
    input  wire [1:0]            evt_timbre_i,    // ⭐ 0=BASS 1=GUITAR 2=PIANO 3=PAD
    //  ⭐⭐ 2026-10-17：⭐ **这条事件是不是鼓**（⭐ 拿 `byte[7]` 的 `bit[6]` 回传给 ESP32 ✅）
    //   🔴 **为什么加**：⭐ 协议里 `byte[7] = {1'b0, is_drum, timbre[1:0], axis[3:0]}`
    //      ⇒ ⚠️ 原来 `bit[6]` **硬写 0**（⭐ `b_axis = {2'b0, tm, ax}`）⇒ ESP32 **无法区分**
    //        "低音旋律"与"鼓"（⭐ 两者 `axis` 低 4 位看起来一样 ✅）
    //   ✅ **零帧长代价**：⭐ `bit[6]` 本来就空着 ⇒ 帧长 / 帧类型 / 校验逻辑**全不变** ✅
    //   📌 `top.v` 接的是 **`up_is_drum_w`**（⭐ 三路鼓统一标记，⭐ 已现成 ✅）——
    //      ⛔ 不新造判据
    //   ⚠️ **本端口必须接**（⭐ 悬空 `z` ⇒ `bit[6]` 变 `x` ⇒ 对端解出脏字节）
    //      ⇒ ⭐ 直接驱动的 tb 一律显式接 `1'b0`（⭐ `tb_evt_upstream` / `tb_evt_upstream_queue`）✅
    input  wire                  evt_is_drum_i,    // ⭐ 1 = 本条是鼓

    // ── ⭐ 音乐 tick（⭐ 自由运行 32 位计数器的步进脉冲 = `beat_gen.tick_o`）────
    input  wire                  tick_step_i,

    // ── ⭐ 使能（⭐ 默认关 ⇒ 不灌串口、零回归）──────────────────────────────
    input  wire                  enable_i,

    // ── ⭐ 下游：⭐ 与 `'Y'` 导出共用同一条 TX 通路 ─────────────────────────
    input  wire                  ready_i,         // ⭐ 队列未满（⭐ 上游据此节流 ✅）
    output wire                  push_o,          // ⭐ 当拍接受的字节
    output wire [7:0]            byte_o,

    // ── ⭐ 可观测（⭐ `K-106`）────────────────────────────────────────────
    output reg                   busy_o,          // ⭐ 正在发一帧（⭐ 顶层据此让 TX ✅）
    output reg  [15:0]           frame_cnt_o,     // ⭐ 已发帧数（饱和）
    output reg  [15:0]           drop_cnt_o,      // ⭐ 溢出丢弃条数（饱和）
    output reg                   overflow_o,      // ⭐ sticky：曾溢出
    output wire [7:0]            seq_o,           // ⭐ 当前序号（⭐ 便于上板核对）
    output wire [31:0]           tick_o,          // ⭐ 当前自由运行 tick（⭐ 便于核对）
    output wire [LEVEL_W-1:0]    level_o          // ⭐ FIFO 当前深度（⭐ 便于核对）
);
    //  ⚠️ `AW_W` 要先算出来（⭐ `K-91`：⛔ 不对 `integer` 参数做位选）
    localparam integer AW_W = (FIFO_D <= 1) ? 1 : $clog2(FIFO_D);
    //  ⭐⭐ 2026-10-16：⭐ **音色也随事件进 FIFO** ⇒ `FW` 46 → 48 ✅
    //     🔴 **为什么必须进 FIFO**：⭐ 原来 `b_axis` 是**组帧那一拍**直接读 `evt_timbre_i`
    //        ⇒ ⚠️ 而组帧发生在 `S_LOAD`，⭐ 距事件发生**可能隔了整整一帧**
    //        （⭐ 一帧 14 B @ 500 kbps = 280 µs ≈ 14000 拍 ✅）
    //        ⇒ 🔴 **连来两个事件时，第二条会盖上第一条的音色** ✅
    //     ✅ 现在音色与 `tick`/`axis`/`inc` **一样在写侧锁存** ⇒ ⭐ 与事件严格配对 ✅
    //     📌 ⭐ 插入位置在 `axis` 与 `inc` 之间 ⇒ ⭐ `inc` 仍稳居 `[PHASE_W-1:0]`
    //        ⇒ ⭐ 原来的 `kd`/`vl`/`ax`/`inc` 四条切片**一个字都不用改** ✅
    //  ⭐⭐ 2026-10-17（🔴 修"帧里没有 is_drum"）：⭐ **`is_drum` 也随事件进 FIFO** ⇒ `FW` 48 → 49 ✅
    //     🔴 **为什么⛔ 不能在组帧那一拍读"当前"的 `evt_is_drum_i`**：
    //        ⭐ 与上面音色**完全同一个理由** —— 组帧在 `S_LOAD`，距事件发生可能隔整整一帧
    //        ⇒ 🔴 **连来两条事件时，第一条帧会盖上第二条的 `is_drum`**（⭐ 内容串了 ✅）
    //     📌 插入位置在 `TIMBRE_W` 与 `inc` 之间（⭐ 即 `axis`/音色之后、`inc` 之前）
    //        ⇒ ⭐ `kd`/`vl`/`ax`/`tm`/`inc` 五条切片的**表达式一个字都不用改**
    //        （⭐ 只有新加的那 1 位要单独切 ✅）
    localparam integer FW   = 2 + VEL_W + AXIS_W + TIMBRE_W + 1 + PHASE_W;    // = 49
    //  🔴 `K-91`：⭐ **⛔ 绝不对 `integer` 参数做位选**（`FIFO_D[AW_W:0]` 这种）
    //     ⚠️ 本模块第一版就写了 `FIFO_D[AW_W:0]` ⇒ 🔴 位选对 `integer` **无效**
    //     ⇒ ⭐ 先落到**定宽 localparam** 再参与比较 ✅
    localparam [AW_W:0] FIFO_D_C   = FIFO_D;                   // ⭐ 深度（定宽）
    localparam [3:0]    FRAME_LAST = FRAME_B - 1;              // ⭐ 末字节下标 = 13 ✅

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 自由运行 32 位 tick（⭐ 每个 `beat_gen.tick_o` 加 1）
    //     📌 ⭐ 为什么不用 `beat_gen.tick_cnt_o`：⭐ 那是**小节内计数**（16 位、会回绕）
    //        ⇒ ⚠️ 算不出"跨小节的 Δt" ✅
    //     📌 ⭐ 语义与 v1.1 一致：⭐ **自由运行 + Δt 取模 2³²** ✅
    // ═══════════════════════════════════════════════════════════════════════
    reg [31:0] tick_q;
    always @(posedge clk_i) begin
        if (!rst_n_i) tick_q <= 32'd0;
        else if (tick_step_i) tick_q <= tick_q + 32'd1;
    end
    assign tick_o = tick_q;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 状态寄存器 —— **声明在 FIFO 之前**（⭐ 因为 FIFO 的读侧要用 `pop_q` ✅）
    // ═══════════════════════════════════════════════════════════════════════
    localparam [1:0] S_IDLE = 2'd0,
                     S_LOAD = 2'd1,
                     S_PUSH = 2'd2;

    reg [1:0]  st_q;
    reg [FW-1:0] hold_q;         // ⭐ 从 FIFO 取出的那一条（⭐ `{kind,vel,axis,inc}` ✅）
    reg [31:0] tick_ev_q;        // ⭐ **捕获事件那一刻**的 tick（⭐ 不是组帧那一拍 ✅）
    reg [8*FRAME_B-1:0] sr_q;    // ⭐ 待发字节（⭐ 每拍左移 8 位 ✅）
    reg [3:0]  bi_q;             // ⭐ 已发字节数 0..13
    reg [7:0]  seq_q;
    reg        pop_q;            // ⭐ 本拍从 FIFO 弹出
    wire       pop_w = pop_q;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 事件 FIFO（⭐ 存 `{kind, vel, axis, phase_inc}` = 46 位 ✅）
    //     🔴 **为什么必须有**：⭐ 一帧 14 B @ 500 kbps = **280 µs ≈ 14000 拍**
    //        ⚠️ 而事件可以**同拍连来** ⇒ 没有 FIFO 时后到的事件**全丢** ✅
    // ═══════════════════════════════════════════════════════════════════════
    // Timestamp travels with its event while the UART applies backpressure.
    reg [FW+31:0] mem [0:FIFO_D-1];
    //  ⭐⭐ 2026-10-14：⭐ **复位清数组的循环变量**（⭐ 见下面复位段 ✅）
    integer mi;
    reg [AW_W:0] cnt_q;
    reg [AW_W-1:0] wr_q, rd_q;

    wire          fifo_empty = (cnt_q == {(AW_W+1){1'b0}});
    wire          fifo_full  = (cnt_q == FIFO_D_C);
    assign level_o = cnt_q;

    //  ⭐⭐ 2026-10-14：⭐ **队头读出改用【常量下标 ＋ 比较链】** ✅
    //     🔴 **为什么**：⭐ 原来写的是
    //        `wire [FW-1:0] head = mem[rd_q];`   ← ⭐ 变量下标的**组合读**
    //        ⇒ ⭐ 综合**推断成 BSRAM `SDPB` 且 `WRITE_MODE0 = 2'b10`（write-through）**
    //        ⇒ 🔴 **Gowin 的 SDPB 不支持它** ⇒
    //        `ERROR (PA2122) Not support 'mem_mem_0_0_s'(DPB) WRITE_MODE0 = 2'b10`
    //        ⇒ 🔴 **整个 PnR 失败**（⭐ 2026-10-14 实测 ✅）
    //     📌 ⚠️ ⭐ **复位清数组【没能】阻止推断** —— ⭐ 试过，⭐ 仍报 PA2122 ✅
    //        （⚠️ 所以"清数组 ⇒ 强制分布式"这条**不是万能的**，
    //         ⭐ 它对本模块**无效** —— ⭐ 与 `note_manager` 的差异未查明 ✅）
    //     ✅ **可靠修法**：⭐ 用**常量下标**逐个读、⭐ 再用**比较链**选 ✅
    //        ⇒ ⭐ 综合看到的是 **`FIFO_D` 个寄存器 ＋ 一个 mux**，⛔ **不是 RAM** ✅
    //     📌 ⭐ 本 FIFO 只有 `16 × 46 = 736 bit` ⇒ ⭐ 用寄存器**本来就更划算** ✅
    //     📌 ⭐ 代价：⭐ 组合深度 = 一级比较 + 一级 mux（⭐ 与原变量下标读**同量级** ✅）
    reg  [FW+31:0] head;
    integer       hi;
    always @(*) begin
        head = {(FW+32){1'b0}};
        for (hi = 0; hi < FIFO_D; hi = hi + 1)
            if (rd_q == hi) head = mem[hi];
    end

    // The switch gates every incoming event, including note_off.
    // No release-event exception remains after the first enabled session.
    // Do not reset the FIFO on disable: finish accepted events in order, even
    // under backpressure, rather than parking them until the next enable.
    wire do_wr = enable_i && evt_valid_i;
    wire accept_wr = do_wr && (!fifo_full || pop_w);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            cnt_q <= {(AW_W+1){1'b0}};
            wr_q  <= {AW_W{1'b0}};
            rd_q  <= {AW_W{1'b0}};
            //  ⭐⭐ 2026-10-14：⭐ **复位时清数组 ⇒ ⭐ 强制【分布式 RAM（LUT）】** ✅
            //     🔴 **为什么必须**：⭐ 组合读（⭐ `head = mem[rd_q]`）
            //        ＋ ⭐ 复位**不清数组** ⇒ ⭐ 综合推断成
            //        **BSRAM `SDPB` 且 `WRITE_MODE0 = 2'b10`（write-through）** ✅
            //        ⇒ 🔴 **Gowin 的 SDPB 不支持它** ⇒
            //        `ERROR (PA2122) Not support 'mem_mem_0_0_s'(DPB) WRITE_MODE0 = 2'b10`
            //        ⇒ 🔴 **整个 PnR 失败**（⭐ 2026-10-14 实测 ✅）
            //     📌 ⭐ **一个 BSRAM 无法一拍清空** ⇒ ⭐ 带清空的数组**只能**是分布式 RAM ✅
            //     📌 ⭐ 本 FIFO 只有 `16 × 46 = 736 bit` ⇒ ⭐ 用 LUT **本来就比 BSRAM 划算** ✅
            //     📌 ⭐ **依据**：⭐ `note_manager.v:1029` **同一手法** ✅
            for (mi = 0; mi < FIFO_D; mi = mi + 1) mem[mi] <= {(FW+32){1'b0}};
            //  ⭐⭐ 2026-10-14：⭐ **溢出/丢弃计数的复位放在【本块】** ✅
            //     🔴 **为什么**：⭐ 综合报 `drop_cnt_o[15] constantly driven from
            //        multiple places` —— ⚠️ 因为原来 **FSM 的复位块也写了它们** ✅
            //     📌 ⭐ **一个 reg 只能在一个 always 块里赋值** ——
            //        ⚠️ iverilog **容忍**（后写者胜）⇒ 🔴 仿真全绿、综合报错 ✅
            //     📌 ⭐ 这正是"**仿真过 ≠ 能综合**"（⭐ 本工程 `P1` 的立项理由 ✅）
            drop_cnt_o <= 16'd0;
            overflow_o <= 1'b0;
        end else begin
            //  ⭐ 读：⭐ 由 FSM 在 `S_IDLE` 那一拍抬 `pop_q` ✅
            if (pop_w) begin
                mem[rd_q] <= {(FW+32){1'b0}};
                rd_q      <= rd_q + {{(AW_W-1){1'b0}}, 1'b1};
            end
            //  ⭐ 写
            if (accept_wr) begin
                //  ⭐⭐ 2026-10-16：⭐ **音色在【写侧】锁存**（⭐ 与 `tick_q` 同一手法 ✅）
                //     🔴 原来这里**没有 `evt_timbre_i`** ⇒ ⚠️ 音色根本没跟着事件走 ✅
                mem[wr_q] <= {tick_q, evt_kind_i, evt_velocity_i, evt_axis_i,
                              evt_timbre_i, evt_is_drum_i, evt_phase_inc_i};
                wr_q      <= wr_q + {{(AW_W-1){1'b0}}, 1'b1};
            end
            //  ⭐ 计数（⭐ 同拍读写 ⇒ 不变 ✅）
            if (accept_wr && !pop_w)      cnt_q <= cnt_q + {{AW_W{1'b0}}, 1'b1};
            else if (!accept_wr && pop_w) cnt_q <= cnt_q - {{AW_W{1'b0}}, 1'b1};
            //  ⭐ 溢出：⭐ 丢弃 + **饱和计数 + sticky**（⭐ `K-106` ⛔ 不许静默 ✅）
            if (do_wr && !accept_wr) begin
                overflow_o <= 1'b1;
                if (drop_cnt_o != 16'hFFFF) drop_cnt_o <= drop_cnt_o + 16'd1;
            end
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 帧装配（⭐ 从 `hold_q` 拆字段 ＋ 算 XOR 校验 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    wire [1:0]         kd  = hold_q[FW-1 -: 2];
    wire [VEL_W-1:0]   vl  = hold_q[FW-3 -: VEL_W];
    wire [AXIS_W-1:0]  ax  = hold_q[FW-3-VEL_W -: AXIS_W];
    //  ⭐⭐ 2026-10-16：⭐ **本事件自带的音色**（⭐ 写侧锁存、⭐ 读侧取出 ✅）
    wire [TIMBRE_W-1:0] tm = hold_q[FW-3-VEL_W-AXIS_W -: TIMBRE_W];
    //  ⭐⭐ 2026-10-17：⭐ **本事件自带的 `is_drum`**（⭐ 写侧锁存、⭐ 读侧取出 ✅）
    //     📌 位置就在 `tm` 下面一位（⭐ 即 `{... timbre, is_drum, inc}` 的 `is_drum` 段 ✅）
    wire              dr = hold_q[FW-3-VEL_W-AXIS_W-TIMBRE_W -: 1];
    wire [PHASE_W-1:0] inc = hold_q[PHASE_W-1:0];

    // ⭐ 类型：⭐ 只有 `kind==1` 是 note_off；⭐ on(0)/pluck(2) 都算 note_on ✅
    wire [7:0] b_type = (kd == 2'd1) ? 8'h02 : 8'h01;
    wire [7:0] b_seq  = seq_q;
    //  ⭐⭐ 2026-10-15：⭐ `[7]` 字节 = `{2'b0, timbre[1:0], axis[3:0]}` ✅
    //     ⚠️ **原来是 `{4'd0, ax}`** —— ⭐ 高 4 位硬写 0，白白空着 ✅
    //     📌 布局：bit[7:6]=0（⭐ 再留 2 位）· bit[5:4]=音色 · bit[3:0]=轴号 ✅
    //     ⭐ **`axis` 只有 4 位**（0..15）⇒ ⭐ 低 4 位就是全部信息，⛔ 不损失 ✅
    //     ⚠️ 本字节参与 XOR 校验 ⇒ ⭐ 值变了校验自然跟着变，⛔ 校验逻辑不用动 ✅
    //     ⭐⭐ 2026-10-16：⭐ **音色改用 `tm`（⭐ 随事件锁存的那个）** ——
    //        🔴 原来用**裸的 `evt_timbre_i`** ⇒ ⚠️ 组帧那一拍的值可能已是**下一条事件**的 ✅
    //        📌 ⭐ 本 tb 判据 ⑪ 覆盖"音色真的进 `[5:4]`"（⭐ 非空洞 ✅）
    //  ⭐⭐ 2026-10-17：⭐ `[7]` 字节 = `{1'b0, is_drum, timbre[1:0], axis[3:0]}` ✅
    //     🔴 **改前**（⭐ 本行原来是 `{2'b0, tm, ax}`）：⭐ `bit[6]` 硬写 0
    //        ⇒ ⚠️ ESP32 分不出"低音旋律"和"鼓"（⭐ 两者 axis 低 4 位可能一样 ✅）
    //     ⭐ **`is_drum` 用 `dr`（⭐ 随事件锁存的那个）** —— ⛔ 不用裸的 `evt_is_drum_i`
    //        （⭐ 理由与 `tm` 那一段完全相同：组帧那一拍的"当前值"可能已是下一条事件的 ✅）
    //     ⚠️ 本字节参与 XOR 校验 ⇒ ⭐ 值变了校验自然跟着变，⛔ 校验逻辑不用动 ✅
    wire [7:0] b_axis = {1'b0, dr, tm, ax};
    wire [7:0] b_vel  = vl;

    //  ⭐⭐ 2026-10-14：⭐ **XOR 覆盖范围【改为含帧头 0xA5】**（⭐ 与 ESP32 侧对齐 ✅）
    //     🔴 **原写法 ⛔ 不含 0xA5** ⇒ ⚠️ 而 ESP32 的 `frame_format.py:165`
    //        （`for x in b[:-1]`）**含 0xA5** ⇒ 🔴 **两边永远不等 ⇒ 所有上行帧被判坏** ✅
    //     📌 ⭐ **实测差值**：⭐ 同一帧 代码口径 = `0x13`、文档口径 = `0xB6`
    //        ⇒ ⭐ **`0x13 ^ 0xB6 = 0xA5`** ⇒ 🔴 **纯粹就是"含不含帧头"**（⭐ 逐位吻合 ✅）
    //     ✅ **裁定：以 ESP32 侧为准（含 0xA5）** —— 理由三条：
    //        · ⭐ 他们的**编码器与解析器都按含 0xA5** ⇒ **自洽** ✅
    //        · ⭐ 他们是**接收方**（⭐ 我发、他们解）⇒ ⭐ 我改一处即可 ✅
    //        · ⭐ 他们改会牵动**整个工具链** ✅
    //     📌 ⭐ 依据：⭐ `files/20-代码/FPGA侧答复-鼓谱发声与XOR更正-20261014.md` §三 ✅
    //  🔴🔴 2026-10-17 修（`D8`，只读审计发现）：⭐ 这里原来硬写 `8'hA5`
    //     ⚠️ 而整帧的帧头用的是 `HDR`（⭐ 见下方 `frame_w`）⇒ ⭐ **一旦 `HDR` 被参数覆盖**
    //        （`HDR != 8'hA5`），校验就与帧头**不匹配** ⇒ 🔴 对端把**每一帧**都判成坏帧，
    //        而本模块**没有任何告警** ⇒ ⭐ 静默失效（`K-106` 家族）✅
    //     📌 当前 `HDR` 默认就是 `8'hA5` ⇒ ⭐ 本修法**逐位等价、零回归** ✅
    //     📌 语义：⭐ 校验**包含帧头**（⭐ ESP32 侧裁定，见上方 `:272-276`）
    //        ⇒ ⭐ 那就必须**真的用 `HDR`**，⛔ 不能用它的默认值 ✅
    wire [7:0] b_ck = HDR ^ b_type ^ b_seq
                    ^ tick_ev_q[31:24] ^ tick_ev_q[23:16] ^ tick_ev_q[15:8] ^ tick_ev_q[7:0]
                    ^ b_axis
                    ^ inc[31:24] ^ inc[23:16] ^ inc[15:8] ^ inc[7:0]
                    ^ b_vel;

    // ⭐ 整帧（⭐ 高字节先发 ✅）：`{HDR, type, seq, tick, axis, inc, vel, ck}` = 14 B
    wire [8*FRAME_B-1:0] frame_w =
        { HDR, b_type, b_seq,
          tick_ev_q[31:24], tick_ev_q[23:16], tick_ev_q[15:8], tick_ev_q[7:0],
          b_axis,
          inc[31:24], inc[23:16], inc[15:8], inc[7:0],
          b_vel, b_ck };

    assign push_o = (st_q == S_PUSH) && ready_i;
    assign byte_o = sr_q[8*FRAME_B-1 -: 8];
    assign seq_o  = seq_q;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ FSM（⭐ 与 `rec_dump.v` **同一套 ready/push 握手** ✅）
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            st_q        <= S_IDLE;
            hold_q      <= {FW{1'b0}};
            tick_ev_q   <= 32'd0;
            sr_q        <= {8*FRAME_B{1'b0}};
            bi_q        <= 4'd0;
            seq_q       <= 8'd0;
            pop_q       <= 1'b0;
            busy_o      <= 1'b0;
            frame_cnt_o <= 16'd0;
            //  ⚠️ ⭐ `drop_cnt_o` / `overflow_o` **⛔ 不在这里复位** ——
            //     ⭐ 它们归 **FIFO 那个 always 块**（⭐ 否则**多驱动** ⇒ 综合报错 ✅）
        end else begin
            pop_q <= 1'b0;

            case (st_q)
                // ── ⭐ 空闲：⭐ 有事件就装载一帧 ─────────────────────────
                S_IDLE: begin
                    busy_o <= 1'b0;
                    if (!fifo_empty) begin
                        //  ⭐ 本拍把队头**打进 `hold_q`** 并弹出（⭐ 组合读 ✅）
                        //  ⭐ 同时**锁存 tick** ⇒ ⭐ 时间戳是"事件发生那一刻" ✅
                        hold_q    <= head[FW-1:0];
                        tick_ev_q <= head[FW+31:FW];
                        pop_q     <= 1'b1;
                        st_q      <= S_LOAD;
                        busy_o    <= 1'b1;   // ⭐ 立刻占住 TX（⭐ 顶层据此让路 ✅）
                    end
                end
                // ── ⭐ 装载帧：⭐ `hold_q` 此刻已有效 ⇒ ⭐ 组帧 ＋ seq++ ────
                S_LOAD: begin
                    sr_q  <= frame_w;
                    bi_q  <= 4'd0;
                    seq_q <= seq_q + 8'd1;   // ⭐ 每条事件一个序号 ✅
                    st_q  <= S_PUSH;
                end
                // ── ⭐ 逐字节推（⭐ `ready_i` 节流 ⇒ ⛔ 不丢字节 ✅）────────
                S_PUSH: begin
                    if (ready_i) begin
                        sr_q <= {sr_q[8*FRAME_B-9:0], 8'd0};   // ⭐ 左移一个字节
                        if (bi_q == FRAME_LAST) begin
                            //  ⭐ 14 个字节发完（⭐ `bi_q` = 0..13 ✅）
                            bi_q   <= 4'd0;
                            if (frame_cnt_o != 16'hFFFF)
                                frame_cnt_o <= frame_cnt_o + 16'd1;
                            st_q   <= S_IDLE;
                            busy_o <= 1'b0;
                        end else begin
                            bi_q <= bi_q + 4'd1;
                        end
                    end
                end
                default: st_q <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
