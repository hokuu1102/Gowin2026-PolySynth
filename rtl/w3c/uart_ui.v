`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// uart_ui.v · 串口屏（淘晶驰 TJC X2）人机交互层 —— W3c（丙线 · L9 人机底层）
//
// ⭐ 契约见 `files/30-方案决策/产品形态决议清单.md` §九-1 / §九-3 / §B 第 7/8 项。
//
// ── 它解决什么问题 ───────────────────────────────────────────────────────────
//   ⭐ 串口屏承担「主控制面」：模式切换（指板↔钢琴）+ 起始音选择 + 状态回显。
//   ⭐ 屏自己搞定字库/画点/触摸扫描（FPGA 不碰），FPGA 侧只需三样：
//     ① 一个 UART 收发（⭐ 复用 `uart_rx.v` / `uart_tx.v`，⛔ 不重复造）
//     ② 一张指令表（⭐ 文本指令，本模块维护）
//     ③ 一个返回解析状态机（⭐ 本模块的核心）
//
// ── ⭐⭐ TJC 返回帧格式（决议清单 §九-3 已核实）──────────────────────────────
//   ⭐ 屏 → FPGA 的返回统一以 **0xFF 0xFF 0xFF** 结尾（3 字节，定界清晰）。
//   ⭐ 帧头是「返回码」，本模块只解析这几种：
//     · 0x65          = 控件点击事件（触摸）→ ⭐ 模式切换 / 起始音的输入来源
//     · 0x70 / 0x71   = 字符串 / 数值变量返回 → ⭐ 参数回传
//     · 0x88          = 系统启动成功 → ⭐ 握手（据此发初始状态）
//   ⭐ 其余返回码（0x66 页面 ID / 0x67 触摸坐标等）→ 忽略（⛔ 不参与状态）
//
// ── ⭐⭐ 帧解析的「不做任意位置扫描」原则（对齐 `evt_uart_rx.v`）──────────────
//   ⭐ 0xFF 是 TJC 帧的**结束符**，也是**合法数据字节**（如数值 255 / 字符串高字节）。
//   ⚠️ 若「扫到 0xFF 就当结束」必然误同步 ⇒ ⭐ 本模块采用：
//     · ⭐ 只在「帧内正确位置」看返回码（⛔ 不在数据中间找）
//     · ⭐ 靠「返回码已知 + 定长/自描述长度」维持同步
//     · ⭐ 失步后靠「空闲间隔归位」自愈（⛔ 不是 FPGA 自己猜）
//
// ── 输出契约（给 top.v / 下游）──────────────────────────────────────────────
//   ⭐ 模式切换（决议清单 §B 第 7 项）：
//     mode_o[0] : 0 = 指板（默认）· 1 = 钢琴
//   ⭐ 起始音选择（§B 第 8 项，⚠️ 限定八度级，每 12 半音）：
//     base_semi_o : 起始音相对 C4 的半音偏移（0 = C4，12 = C5，…，⚠️ 八度级）
//     🔴 **2026-10-01 澄清**：本模块只做 `val_q >> 1`（见下方 `:253`），⛔ **不是"按 12 取整"**；
//        ⭐ **真正只认 `0/12/24` 的是 `note_manager.v:373-378`**（⭐ 其余值一律回 0）
//        ⇒ ⭐ **屏侧要发 `val_q = 0 / 24 / 48`**（⭐ 即 `2 × base_semi`）。
//   ⭐⭐ 2026-10-15：⭐ 效果器**实装**（⛔ 原来只"留位"）——
//      从"`fx_en_o`/`fx_sel_o` 恒 0"改成**9 个运行时参数 + 1 个提交脉冲** ✅
//      📌 详见下方 `fx_mask_o` 那一段的**变量号/换算表** ✅
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ 整个模块被静默丢弃，而仿真全绿）
//   · ⭐ 组合逻辑用 `assign`（`L67`）
//   · ⛔ 不用 PLL 派生时钟（冻结表 §〇 约定 1）
//   · ⭐ 任何「会失效」的路径都必须可观测（`K-106`）—— 本模块把
//     「返回码错 / 归位 / 帧计数 / 丢弃」全做成计数器，⛔ 不静默
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module uart_ui #(
    parameter integer CLK_HZ = 50000000,   // ⭐ 50 MHz（单时钟域）
    // ⭐ 波特率：⚠️ 必须与所接 `uart_rx.BAUD_DIV` 一致（两者不匹配会静默乱码）。
    //  ⚠️ **本参数的"默认值"与"交付取值"不是一回事**（⭐ 2026-10-15 澄清）：
    //     · ⭐ 模块默认 = **1000000**（1 Mbps）—— ⭐ 只有本模块的 **tb** 用它
    //       （⭐ `tb/w3c/tb_uart_ui.sv:22` 传 `BAUD=1000000`，⭐ 且 `CLK_HZ` 也由它给）
    //     · ⭐ **交付实传 = 500000**（500 kbps）—— ⭐ 见 `top.v` 的 `uart_ui` 例化
    //       （⭐ `.BAUD(500_000)`，⭐ 与 `uart_rx.BAUD_DIV=100` 同档 ✅）
    //     🔴 **⛔ 不要照着"默认 1e6"去配 `uart_rx`** —— ⚠️ 上板走的是 `top.v` 传的 500 k
    //        （⭐ 原注释只写"1 Mbps = 1000000（默认）"，⭐ 容易让人以为交付就是 1 Mbps）✅
    parameter integer BAUD = 1000000,
    // ⭐ 空闲归位阈值（单位：字节时间）。> 1，取 16（对齐 evt_uart_rx 的 GAP_BYTES）
    parameter integer GAP_BYTES = 16,
    // ⭐⭐ **2026-09-27 新增：⭐ 上电默认模式**
    //   · 0 => ⭐ **指板模式**（轴事件只"选音"，⭐ 必须拨弦才发声）
    //   · 1 => ⭐ **钢琴模式**（轴事件直接发声，**⛔ 不需要拨弦**）
    //
    //   ⭐ **为什么加这个参数**：⭐ 用户上板发现"按下没声音" ——
    //      🔴 因为原来**硬编码默认指板**，而指板模式要等 **P4 的 LM393 拨弦比较器**
    //         ⇒ ⚠️ **不接那个硬件就完全没声音**（⭐ 上板实测踩到）。
    //   ⭐ **交付/烧录取值：1（钢琴）** —— ⭐ 上电即弹即响，⛔ 不依赖外接拨弦板。
    //   📌 **两种模式都保留** —— 串口屏触摸控件仍可**随时切换**（⭐ `mode_o <= ~mode_o`），
    //      ⚠️ 本参数只决定**上电初值**，⛔ 不锁死。
    parameter integer MODE_PIANO_DEFAULT = 1,
    //  ⭐⭐ 2026-10-15：⭐ **效果器参数的【上电初值】** ✅
    //     🔴 **为什么要做成参数**：⭐ 效果器现在是**运行时寄存器**（⭐ 串口帧可改），
    //        但**上电那一刻**需要一个初值 ⇒ ⭐ 由 `top.v` 传进来 ✅
    //     ⭐ **好处**：⭐ 队友的 `tb_top_fx_audio` 可以像以前一样**编译期覆盖**
    //        （⭐ 例如 `FX_EN_MASK=8'hFF` 做"全开档"验收），⛔ 判据不用重写 ✅
    //     📌 **默认 = 全关** ⇒ ⭐ 上电与"没有效果器"逐样本相同（零回归）✅
    //     ⚠️ 这 9 个值的**语义与换算**见下方 `fx_*_o` 端口的注释表 ✅
    parameter [7:0]  FX_MASK_DEF     = 8'd0,
    parameter [15:0] FX_GAIN_DEF     = 16'd16384,   // Q4.12 = 4.0
    parameter [15:0] FX_TRIM_DEF     = 16'd8192,    // Q1.15 = 0.25
    parameter [7:0]  FX_MIX_DEF      = 8'd128,
    parameter [7:0]  FX_FB_DEF       = 8'd96,
    parameter [7:0]  FX_DEPTH_DEF    = 8'd0,        // 0 = 数值恒等
    parameter [7:0]  FX_RATE_DEF     = 8'd7,
    parameter [13:0] FX_DLYLEN_DEF   = 14'd8192,    // 168 ms
    //  ⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **732 → 736** ✅
    //  🔴 **为什么**：⭐ 串口帧只能写"**字节 × 32**"（⭐ `0x18` ⇒ `val × 32`）
    //     ⇒ ⭐ 而 **732 = 22.875 × 32 不在格点上** ⇒ 🔴 **上电默认值【永远写不回来】**：
    //        ⭐ 用户发一次 `0x18`（哪怕发 `23`）之后，⭐ 就再也回不到上电状态 ✅
    //     （⭐ 口径 bug：⭐ "零回归"要求"全关 + 默认值"可复现 ⇒ ⭐ 默认值必须在格点上）
    //  ⭐ **736 = 23 × 32 正好在格点上**，⭐ 与工具 `fx_ctrl.py` / 交接文档
    //     `bringup/27-...` §3.2 / `fx_chain.v` 的"典型 736"**全部对齐** ✅
    //  ⚠️ **代价**：⭐ 差 **4 个采样 = 82 µs**（⭐ 0.08 ms，⭐ 听不出来）；
    //     ⭐ 且**没有任何 tb 钉 732**（⭐ 只有 `tb_uart_ui.sv` 的复位判据，⭐ 已同步改 736）✅
    parameter [10:0] FX_CHORLEN_DEF  = 11'd736     // 15 ms（⭐ = 23 × 32，⭐ 在串口格点上）
) (
    input  wire        clk_i,
    input  wire        rst_n_i,            // ⭐ 同步复位、低有效（约定 2）

    // ── ⭐⭐ 2026-10-13：外部模式切换（串口命令 / 控制板按键）──────────────
    //   语义与屏触摸控件 0 **完全一致**（翻转 `mode_o` + 发提交脉冲）。
    //   🔴 **为什么必须加**：交付默认 `MODE_PIANO_DEFAULT = 1`（钢琴），
    //      而 `play_fretboard_mode = ~ui_mode_piano` ⇒ `am_mode = 0`
    //      ⇒ `top.v` 的滑音项 `(ee_slide_v & am_mode)` **恒 0**
    //      ⇒ 没有"脱离屏"的切换入口，滑音的音高更新就**形同虚设**。
    //   📌 来源（键/串口）在外面 OR 好，本模块只认这一个脉冲。
    input  wire        mode_sw_req_i,      // ⭐ 模式翻转请求（单周期脉冲）

    // ── ⭐ 来自 `uart_rx.v` 的字节流（屏 → FPGA）──────────────────────────
    input  wire        rx_done_i,          // ⭐ 收到一个字节（单周期脉冲）
    input  wire [7:0]  rx_data_i,          // ⭐ 该字节

    // ── ⭐ 发往 `uart_tx.v` 的字节流（FPGA → 屏）──────────────────────────
    input  wire        tx_busy_i,          // ⭐ tx 忙（⛔ 别喂新字节）
    input  wire        tx_done_i,          // ⭐ tx 发送完成（单周期脉冲）
    output reg         tx_start_o,         // ⭐ 启动发送（单周期脉冲）
    output reg  [7:0]  tx_data_o,          // ⭐ 待发字节

    // ── ⭐ 解析出的控制量（给 top.v / 下游）───────────────────────────────
    output reg         mode_o,             // ⭐ 0=指板(默认) · 1=钢琴
    output reg  [6:0]  base_semi_o,        // ⭐ 起始音半音偏移（⚠️ 八度级，每 12 半音）
    output reg         mode_commit_o,      // ⭐ 模式切换提交（单周期脉冲）
    output reg         base_commit_o,      // ⭐ 起始音提交（单周期脉冲）

    // ── ⭐ A1 Test Mode 的「UI 开关」（⭐ 丙 · 2026-09-27）──────────────
    //   ⭐ 触摸控件 2 = Test Mode 切档：关 → 4 → 8 → 16 → 32 → 关
    //   📌 分档语义与乙的 `test_mode_ctrl.n_code_i` 一致（00=4 / 01=8 / 10=16 / 11=32）。
    //      top.v 里与调试串口的 'M' 命令**并联**（或），两种入口都能切档。
    output reg         test_mode_o,        // ⭐ Test Mode 使能（1 = 进入）
    output reg  [1:0]  test_mode_n_o,      // ⭐ 分档（00/01/10/11 = 4/8/16/32）
    output reg         test_mode_commit_o, // ⭐ 切档提交（单周期脉冲）

    // ── ⭐⭐ 效果器运行时参数（⭐ 2026-10-15 实装，⛔ 不再是"留位恒 0"）──────────
    //   🔴 **为什么要改**：⭐ 原来 `fx_en_o`/`fx_sel_o` **恒 0**，而 `top.v` 的
    //      效果器参数是 **`parameter`（编译期常量）** ⇒ 🔴 **上板调不了**，
    //      每改一个值都要**重新综合 + 重新 PnR**（几十分钟一轮）✗
    //   ✅ **现在**：⭐ 这些量全部变成**运行时寄存器**，⭐ 由串口帧直接写 ✅
    //      ⇒ ⭐ 串口助手**当场**就能把失真从 1 倍扫到 16 倍，找到"明显失真"的点 ✅
    //
    //   📌 **帧格式**（⭐ 与串口屏同一套协议，⛔ 不需要新字母 ✅）
    //      `<返回码> <变量序号> <值> FF FF FF`
    //      ⭐ 效果器占用变量序号 **0x10 .. 0x18**（⭐ 现有 0/1/2 不冲突）✅
    //
    //   | 序号 | 名字 | 值域 | 换算 | 说明 |
    //   |---|---|---|---|---|
    //   | 0x10 | mask  | 0..254 | 直传 | ⭐ 位掩码：bit0=失真 bit1=合唱 bit2=延迟 · ⚠️ **bit4 空闲**（⛔ 不是颤音）⇒ ⭐ **全开 = 0x07** |
    //   | 0x11 | gain  | 0..254 | ×256 ⇒ Q4.12 | 失真增益，**64 = 4.0 倍**（默认）· 254 ⇒ 15.875 倍（⚠️ 255 发不出，见下）|
    //   | 0x12 | trim  | 0..254 | ×256 ⇒ Q1.15 | 失真补偿，**32 = 0.25**（默认）· 128 = 1.0 |
    //   | 0x13 | mix   | 0..254 | 直传 Q0.8 | 延迟/合唱混合（0=全干 254≈全湿）|
    //   | 0x14 | fb    | 0..254 | 直传 Q0.8 | 延迟反馈 |
    //   | 0x15 | depth | 0..254 | 直传 | 颤音深度（0 = 数值恒等）|
    //   | 0x16 | rate  | 0..254 | 直传 | 颤音速率 |
    //   | 0x17 | dlylen| 0..254 | ×128 采样 | 延迟长度（64 ⇒ 8192 采样 ⇒ 168 ms）|
    //   | 0x18 | chorlen| 0..254 | ×32 采样 | 合唱长度（**23 ⇒ 736 采样 ⇒ 15 ms**，⭐ 与默认值同格点）|
    //   ⚠️ **值域上限为什么是 254 而不是 255**：⭐ `0xFF` 是**帧尾标记**（`FF FF FF`）
    //      ⇒ ⭐ `S_BODY` 里看到 `0xFF` **不计入 `body_len`** ⇒ 🔴 **`val_q` 永远拿不到 255**
    //      ⇒ ⭐ 这是 **TJC 协议的固有约束**（⛔ 不是实现问题）✅
    //
    //   ⚠️ **复位值 = 全关 + 默认音色** ⇒ ⭐ **上电与改动前逐样本相同**（零回归）✅
    //   📌 **可观测**：`fx_commit_o` 单周期脉冲 ⇒ ⭐ 顶层可据此确认"参数真的写进去了" ✅
    output reg  [7:0]  fx_mask_o,          // ⭐ 0x10 效果器开关掩码
    output reg  [15:0] fx_gain_o,          // ⭐ 0x11 失真增益（Q4.12）
    output reg  [15:0] fx_trim_o,          // ⭐ 0x12 失真补偿（Q1.15）
    output reg  [7:0]  fx_mix_o,           // ⭐ 0x13 延迟/合唱混合
    output reg  [7:0]  fx_fb_o,            // ⭐ 0x14 延迟反馈
    output reg  [7:0]  fx_depth_o,         // ⭐ 0x15 颤音深度
    output reg  [7:0]  fx_rate_o,          // ⭐ 0x16 颤音速率
    output reg  [13:0] fx_dlylen_o,        // ⭐ 0x17 延迟长度（采样）
    output reg  [10:0] fx_chorlen_o,       // ⭐ 0x18 合唱长度（采样）
    output reg         fx_commit_o,        // ⭐ 参数已更新（单周期脉冲）

    // ── ⭐⭐ 2026-10-17（`K-106`）：⭐ **效果器状态【回读】入口** ────────────────────
    //   🔴 **为什么必须有**（⭐ 任务原话）：*"让上板能看到效果器到底生没生效"*。
    //      ⚠️ 在加这条之前，`fx_chain` 的 7 个可观测输出在 `top.v` 里**全部空接**
    //         （⭐ `rtl/top.v` 的 `u_fx` 例化：`.en_mask_o()` / `.dly_active_o()` /
    //          `.chor_active_o()` / `.dly_primed_o()` / `.dist_clip_cnt_o()` /
    //          `.trem_lfo_o()` / `.pipe_o()` ✅）
    //      ⇒ 🔴 **发一串串口帧下去，完全不知道链路上发生了什么** ✅
    //      ⇒ ⚠️ 这正是 `K-106` 的经典形态：*"作者想到了可观测性，但顶层没接"* ✅
    //
    //  ⭐ **数据来源（⭐ 单向，⛔ 不写任何东西）**：下面 7 个输入由 `top.v` 从
    //     `u_fx_chain` 的同名输出**直接接过来**（⭐ `fx_chain.v:150-156` ✅）。
    //     ⚠️ 本模块**只读**它们 ⇒ ⛔ 不会与 `uart_ui` 的参数寄存器互相驱动 ✅
    //
    //  ⭐ **触发源**：`fxstat_req_i` ＋ `fxstat_sub_i`（⭐ 来自 `calib_cmd` 的 `'Z' <n>` ✅）
    //     ⚠️ `fxstat_req_i` 是**单周期脉冲**，`fxstat_sub_i` 与它**同拍有效**
    //        （⭐ `calib_cmd` 的 `'Z'` 分支：两拍臂化 + 一拍取值 ✅）
    //
    //  ⭐ **输出**：`fx_tx_start_o` / `fx_tx_data_o` —— ⭐ 与 `tx_start_o`/`tx_data_o`
    //     **同一套握手**（⭐ `top.v` 已把它们 OR 进 `u_tx_fifo.push_i` ✅）
    //     ⚠️ **为什么走 FIFO 而⛔ 不是直连 `uart_tx`**：⭐ 直连会"忙就丢"
    //        （⭐ `uart_tx_fifo.v` 文件头记的 2026-09-24 上板实测 ✅）
    input  wire        fxstat_req_i,      // ⭐ 'Z' <n> 到达（单周期脉冲）
    input  wire [2:0]  fxstat_sub_i,      // ⭐ 子命令号 0..7（与 req 同拍有效）
    input  wire [7:0]  fx_en_mask_i,      // ⭐ fx_chain.en_mask_o
    input  wire        fx_dly_active_i,   // ⭐ fx_chain.dly_active_o
    input  wire        fx_chor_active_i,  // ⭐ fx_chain.chor_active_o
    input  wire        fx_dly_primed_i,   // ⭐ fx_chain.dly_primed_o
    input  wire [15:0] fx_dist_clip_i,    // ⭐ fx_chain.dist_clip_cnt_o
    input  wire [15:0] fx_trem_lfo_i,     // ⭐ fx_chain.trem_lfo_o
    input  wire [15:0] fx_pipe_i,         // ⭐ fx_chain.pipe_o（低 16 位够用：真值 19）
    output wire        fx_tx_pending_o,  // complete frame waiting or being sent
    input  wire        fx_tx_ready_i,    // acceptance from downstream byte arbiter
    output reg         fx_tx_start_o,     // ⭐ 推一个字节给 u_tx_fifo（单周期脉冲）
    output reg  [7:0]  fx_tx_data_o,      // ⭐ 那个字节
    //  ⭐⭐ 可观测性（`K-106`：⛔ 不许静默失效）
    //     ⚠️ 若 `'Z'` 静默失效（⭐ 例如 `calib_cmd` 漏加总闸、⭐ 或 `top.v` 忘接臂），
    //        ⭐ 现象是"发了 `'Z'` 什么都没有" ⇒ 🔴 **无法归因** ✅
    //     ✅ 三个计数器全部接出来（⭐ `top.v` 已把它 OR 进回读帧的观测点 ✅）
    output reg  [15:0] zfs_req_cnt_o,    // ⭐ 已受理的回读请求数（饱和）
    output reg  [15:0] zfs_drop_cnt_o,   // ⭐ 因上一帧未发完而【挂起】的次数（饱和）

    // ── ⭐ 可观测性（`K-106`）────────────────────────────────────────────
    output reg  [15:0] frame_cnt_o,        // ⭐ 成功解析的返回帧数（饱和）
    output reg  [15:0] resync_cnt_o,       // ⭐ 空闲归位次数（饱和）
    output reg  [15:0] err_cnt_o,          // ⭐ 「该是返回码却不是」的次数（饱和）
    output reg         hb_ready_o,         // ⭐ 已收到 0x88 握手（⭐ 屏就绪）
    //  ⭐⭐ 2026-10-09（`P0-02`）：⭐ **"本模块正在收一帧"**（⭐ 给顶层做互斥门控）✅
    //   🔴 **为什么需要它**：⭐ 同一条 `uart_rx` 的 `ur_done`/`ur_data` 被**三个消费者**共用
    //      （`uart_ui` 串口屏 · `calib_cmd` 命令 · `evt_uart_rx` 曲谱事件）
    //      ⇒ ⚠️ 而 `evt_uart_rx` 的帧头是 **`0xA5`**、⛔ 它**看不到**别人的帧边界
    //      ⇒ 🔴 只要屏/命令的**合法载荷**里出现 `0xA5`，⭐ 就会被当成曲谱帧头
    //      ⇒ 🔴 **注入伪事件**（⭐ 实测：8 个屏帧 ⇒ 8 条伪 `note_on`，`axis=15` 保留轴）
    //      ⇒ ⭐ 而 `note_manager` 的 `note_off` 按 `(轴, 源)` 双条件匹配
    //         ⇒ 🔴 **手弹的 `note_off` 永远清不掉 `score` 源的 voice** ⇒ **永久挂音** ✅
    //   ✅ **修法**：⭐ 把"别人在帧内"引出来 ⇒ 顶层给 `evt_uart_rx.rx_done_i` 加门控 ✅
    //   📌 语义：⭐ `state != S_IDLE` ⇒ ⭐ 正在收一帧（⭐ 含帧头/帧体/返回码/结束符）✅
    output wire        in_frame_o          // ⭐ 1 = 本模块正在收一帧
);

    // ═══════════════════════════════════════════════════════════════════════
    // ① 空闲归位换算（对齐 evt_uart_rx：先算 integer，再赋值给定宽 localparam）
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer BYTE_CLK_I = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 四舍五入
    localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;
    localparam [19:0]  GAP_CLK    = GAP_CLK_I;                  // ⭐ 赋值 ⇒ 自动截断

    // ═══════════════════════════════════════════════════════════════════════
    // ② 返回码定义（决议清单 §九-3）
    // ═══════════════════════════════════════════════════════════════════════
    localparam [7:0] RET_TOUCH   = 8'h65;   // ⭐ 控件点击事件
    localparam [7:0] RET_STR     = 8'h70;   // ⭐ 字符串变量返回
    localparam [7:0] RET_NUM     = 8'h71;   // ⭐ 数值变量返回
    localparam [7:0] RET_BOOT    = 8'h88;   // ⭐ 系统启动成功（握手）
    localparam [7:0] FRAME_TAIL  = 8'hFF;   // ⭐ 帧结束符（3 连）

    // ═══════════════════════════════════════════════════════════════════════
    // ③ 帧解析状态
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 状态：IDLE（等返回码）→ BODY（收帧体，直到 FF FF FF）
    localparam [1:0] S_IDLE = 2'd0, S_BODY = 2'd1;

    reg [1:0]  state;
    reg [7:0]  retcode;        // ⭐ 本帧返回码（0x65/0x70/0x71/0x88）
    reg [2:0]  tail_cnt;       // ⭐ 连续 0xFF 计数（到 3 = 帧结束）
    reg [5:0]  body_len;       // ⭐ 帧体已收字节数（不含返回码和结束符）
    //  ⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **7 位 → 8 位**（🔴 修一个真缺陷）✅
    //  ---------------------------------------------------------------------------
    //  🔴 **原写法**：⭐ `reg [6:0] body_q;` ＋ 赋值 `body_q <= rx_data_i[6:0];`
    //     ⇒ ⭐ **最高位被静默丢掉** ⇒ 🔴 **变量序号 / 控件号【别名】**：
    //        · `0x90` ⇒ `0x10` ⇒ ⭐ 被当成 `V_MASK` ⇒ 🔴 **静默写 `fx_mask`**
    //          （⭐ 实测：发 `71 90 05 FF FF FF` ⇒ `fx_mask` 变成 **5**）✅
    //        · `0x91` ⇒ `0x11`（gain）· `0x98` ⇒ `0x18`（chorlen）· …
    //        · `0x80` ⇒ `0` ⇒ ⭐ 被当成**触摸控件 0** ⇒ 🔴 **翻转模式** ✅
    //     ⇒ ⭐ 症状不是"发不进去"，而是 **"发到别的寄存器上去了"**（⭐ 更危险：
    //        用户会看到**参数莫名跳变**、**模式自己切**）✅
    //  ✅ **修法**：⭐ **扩到 8 位**、并去掉 `[6:0]` 切片 ⇒ ⭐ `0x90` 不再匹配 `0x10`，
    //     而是落进"未知变量序号"⇒ ⭐ 与 `0x7F` **同处置**（⭐ 静默丢弃）✅
    //  📌 **为什么不改成"显式拒绝 `rx_data_i[7]`"**：
    //     ⭐ ① 缺陷**就是**那个 `[6:0]` ⇒ ⭐ 删掉它是最小、最直接的修法；
    //     ⭐ ② 显式拒绝若**要可观测**，就得再加一个计数器并牵动 `top.v` 接线
    //        ⇒ ⚠️ 超出本次改动范围（⭐ 且与 `0x7F` 的既有处置不一致）；
    //     ⭐ ③ 扩位**同时**修好数值与触摸**两条**别名通路，⛔ 不用分别打补丁 ✅
    //  ⚠️ **真实 TJC 的 `0x71` 值可能是 4 字节小端**（⭐ 见
    //     `files/20-代码/审计-top集成与时钟复位-20260928.md:239`）——
    //     ⭐ 但这里被别名的是**变量序号那一个字节**，⛔ 与"值"占几个字节无关
    //     ⇒ ⭐ 扩位对 1 字节值和 4 字节值**同样正确** ✅
    //  ⚠️ **下面的比较一律写 `8'dN`**（⭐ 与 8 位 `body_q` **同宽**）——
    //     ⛔ 不要退回 `7'dN`（⭐ 虽然 Verilog 会把字面量零扩展、语义相同，
    //     但同宽比较**一眼就能看出没有截断**）✅
    reg [7:0]  body_q;         // ⭐ 帧体第一个「有意义」字节（控件 ID / 变量序号）
    reg [7:0]  val_q;          // ⭐ 数值返回的「数值」字节（0x71 场景）
    reg [19:0] idle_q;         // ⭐ 距上次收到字节的 clk 数（饱和）

    //  ⭐⭐ 2026-10-09（`P0-02`）：⭐ **帧内标志** —— ⭐ 给顶层做"曲谱接收"的互斥门控 ✅
    //   📌 只在 `S_BODY` 期间为 1 ⇒ ⭐ 恰好盖住"别人的合法载荷"那一段 ✅
    //   ⚠️ **必须在 `state` 声明之后**（⭐ Verilog 要先声明后使用）✅
    assign in_frame_o = (state != S_IDLE);

    wire idle_expired = (idle_q >= GAP_CLK);

    // ═══════════════════════════════════════════════════════════════════════
    // ④ 空闲计时器
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            idle_q <= 20'd0;
        end else if (rx_done_i) begin
            idle_q <= 20'd0;
        end else if (!idle_expired) begin
            idle_q <= idle_q + 20'd1;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⑤ 饱和自增（⛔ 不许回绕）
    // ═══════════════════════════════════════════════════════════════════════
    function [15:0] sat_inc16;
        input [15:0] v;
        begin
            sat_inc16 = (v == 16'hFFFF) ? 16'hFFFF : (v + 16'd1);
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⑥ 主状态机：解析返回帧
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state        <= S_IDLE;
            retcode      <= 8'h00;
            tail_cnt     <= 3'd0;
            body_len     <= 6'd0;
            body_q       <= 8'd0;
            val_q        <= 8'd0;
            //   ⭐⭐ **2026-09-27：⭐ 上电默认模式改为【可配置】**
            //      🔴 原来硬编码 `1'b0`（指板）⇒ ⚠️ 不接拨弦板就没声音
            //      ⭐ 现在由 `MODE_PIANO_DEFAULT` 决定（⭐ 默认 1 = 钢琴）
            //      📌 `mode_o` 语义：⭐ **0 = 指板 · 1 = 钢琴**（⭐ 见端口注释）
            mode_o       <= (MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0;
            base_semi_o  <= 7'd0;          // ⭐ 默认 C4
            mode_commit_o<= 1'b0;
            base_commit_o<= 1'b0;
            test_mode_o  <= 1'b0;          // ⭐ A1：上电默认关（⛔ 不打扰正常演奏）
            test_mode_n_o<= 2'b00;         // ⭐ 关后首档 = 4 voices
            test_mode_commit_o <= 1'b0;
            //  ⭐⭐ 效果器运行时参数（⭐ 复位值 = **参数传入的初值**）
            //     📌 `top.v` 传的是 `FX_*`（⭐ 默认全关）⇒ **零回归** ✅
            //     📌 队友的 `tb_top_fx_audio` 覆盖 `FX_EN_MASK=8'hFF` ⇒ ⭐ 上电即全开 ✅
            fx_mask_o    <= FX_MASK_DEF;
            fx_gain_o    <= FX_GAIN_DEF;
            fx_trim_o    <= FX_TRIM_DEF;
            fx_mix_o     <= FX_MIX_DEF;
            fx_fb_o      <= FX_FB_DEF;
            fx_depth_o   <= FX_DEPTH_DEF;
            fx_rate_o    <= FX_RATE_DEF;
            fx_dlylen_o  <= FX_DLYLEN_DEF;
            fx_chorlen_o <= FX_CHORLEN_DEF;
            fx_commit_o  <= 1'b0;
            frame_cnt_o  <= 16'd0;
            resync_cnt_o <= 16'd0;
            err_cnt_o    <= 16'd0;
            hb_ready_o   <= 1'b0;
            tx_start_o   <= 1'b0;
            tx_data_o    <= 8'd0;
        end else begin
            // ⭐ 默认：脉冲类输出每拍清零 ⇒ 严格单周期
            mode_commit_o <= 1'b0;
            base_commit_o <= 1'b0;
            test_mode_commit_o <= 1'b0;
            //  ⭐ 效果器参数提交脉冲：⭐ 默认每拍清零 ⇒ 严格单周期 ✅
            fx_commit_o   <= 1'b0;
            tx_start_o    <= 1'b0;

            //  ⭐⭐ 2026-10-13：外部模式翻转（串口 'A' 命令 / 控制板模式键）
            //     与屏触摸控件 0 **同一语义**。
            //  ⚠️ 与屏触摸**同拍**时的取舍：本分支在前 ⇒ 同拍以屏为准（可接受）。
            if (mode_sw_req_i) begin
                mode_o        <= ~mode_o;
                mode_commit_o <= 1'b1;
            end

            if (rx_done_i) begin
                case (state)
                    // ── 空闲：等返回码（⛔ 不扫描）──────────────────────
                    S_IDLE: begin
                        if ((rx_data_i == RET_TOUCH) ||
                            (rx_data_i == RET_STR)   ||
                            (rx_data_i == RET_NUM)   ||
                            (rx_data_i == RET_BOOT)) begin
                            // ⭐ 合法返回码 ⇒ 进入帧体
                            retcode  <= rx_data_i;
                            state    <= S_BODY;
                            tail_cnt <= 3'd0;
                            body_len <= 6'd0;
                            // ⭐ 0x88 握手：立即置就绪（无帧体）
                            if (rx_data_i == RET_BOOT) begin
                                hb_ready_o <= 1'b1;
                            end
                        end else begin
                            // 🔴 该是返回码却不是 ⇒ 留在 IDLE 继续等
                            err_cnt_o <= sat_inc16(err_cnt_o);
                        end
                    end

                    // ── 帧体：收数据，直到 FF FF FF ────────────────────
                    S_BODY: begin
                        if (rx_data_i == FRAME_TAIL) begin
                            // ⭐ 连续 0xFF ⇒ 可能到结束符
                            if (tail_cnt == 3'd2) begin
                                // ⭐⭐ 3 连 0xFF ⇒ 帧结束，落地控制量
                                state   <= S_IDLE;
                                frame_cnt_o <= sat_inc16(frame_cnt_o);
                                // ⭐ 按返回码落地
                                case (retcode)
                                    RET_TOUCH: begin
                                        // ⭐ 触摸事件：body_q = 控件 ID
                                        //   ⭐ 约定（见 tb）：控件 0 = 模式切换，控件 1 = 起始音，
                                        //      控件 2 = Test Mode 切档（⭐ A1）
                                        if (body_q == 8'd0) begin
                                            mode_o        <= ~mode_o;    // ⭐ 翻转
                                            mode_commit_o <= 1'b1;
                                        end else if (body_q == 8'd2) begin
                                            // ⭐ A1：关 → 4 → 8 → 16 → 32 → 关
                                            if (!test_mode_o) begin
                                                test_mode_o  <= 1'b1;
                                                test_mode_n_o<= 2'b00;  // 4 voices
                                            end else if (test_mode_n_o == 2'b11) begin
                                                test_mode_o  <= 1'b0;   // 32 → 关
                                                test_mode_n_o<= 2'b00;
                                            end else begin
                                                test_mode_n_o <= test_mode_n_o + 2'b01;
                                            end
                                            test_mode_commit_o <= 1'b1;
                                        end
                                    end
                                    RET_NUM: begin
                                        // ⭐ 数值返回：val_q = 数值，body_q = 变量序号
                                        //
                                        //  ⭐⭐ 2026-10-15：⭐ **加一道"帧体必须够长"的闸门** ✅
                                        //  ------------------------------------------------------------------
                                        //  🔴 **为什么要加**：⭐ 我写效果器判据时实测踩到 ——
                                        //     发 `71 10 FF FF FF`（想把掩码设成 0xFF）时：
                                        //       · ⭐ `0xFF` 是**帧尾标记** ⇒ ⛔ **不计入 `body_len`**
                                        //       · ⇒ ⭐ `body_len` 只到 **1**（只有 `0x10` 那一个字节）
                                        //       · 🔴 **而帧尾一到就【照样落地】** ⇒
                                        //         ⭐ 把**上一帧遗留的陈旧 `val_q`** 写进了寄存器 ✗
                                        //     ⇒ 🔴 **不只是"设不进去"，而是"写入了垃圾值"** ✅
                                        //         ⚠️ 这比"不生效"危险得多 —— 用户会看到**参数莫名跳变** ✅
                                        //
                                        //  ✅ **修法**：⭐ `0x71` 是"变量号 + 值"两字节帧
                                        //     ⇒ ⭐ **`body_len < 2` 时一律不落地** ✅
                                        //     📌 **零回归**：⭐ 既有的合法用法（⭐ `71 01 18`）
                                        //        `body_len` 恰好 = 2 ⇒ ⛔ 不受影响 ✅
                                        //     📌 **只对 `RET_NUM` 生效** —— ⭐ `0x65`（触摸）本来就是
                                        //        1 字节帧（⭐ 控件 ID），⛔ 不能加这个限制 ✅
                                        if (body_len < 6'd2) begin
                                            // ⭐ 帧体不足 ⇒ ⛔ 什么都不做（⭐ 不落地、不发脉冲）
                                            //    📌 `err_cnt_o` 由上层统计"该是返回码却不是"，
                                            //       ⭐ 这里只做**静默丢弃**（⭐ 与"未知变量号"同处置）✅
                                        end else if (body_q == 8'd1) begin
                                            // ⭐ 起始音：本模块只做 `val_q >> 1`（🔴 ⛔ **不是"按 12 取整"**）
                                            //    ⭐ 真正只认 `0/12/24` 的是 `note_manager.v:373-378`
                                            //    ⇒ ⭐ **屏侧要发 `val_q = 0 / 24 / 48`**（= 2 × base_semi）
                                            base_semi_o  <= {1'b0, val_q[7:1]}; // ⚠️ 简化：见 tb 约定
                                            base_commit_o<= 1'b1;
                                        end
                                        //  ⭐⭐ 2026-10-15：⭐ **效果器参数（变量 0x10..0x18）** ✅
                                        //     🔴 **为什么要走屏协议而不是加单字母命令**：
                                        //        · ⭐ 26 个字母已用掉 **25 个**（只剩 'Z'）⇒ 加不了几个 ✗
                                        //        · ⭐ 一个字母只能带**一个字节**，而参数有 **9 个** ✗
                                        //        · ⭐ 屏协议本来就有「变量序号 + 值」的形态 ⇒ **天然够用** ✅
                                        //     📌 **好处**：⭐ 串口屏和串口助手**同一套协议** ⇒
                                        //        ⭐ 屏上勾选和助手发帧**走同一条代码路径**，⛔ 不用二选一 ✅
                                        else if (body_q == 8'd16) begin   // 0x10
                                            fx_mask_o   <= val_q;         // ⭐ 位掩码，直传
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd17) begin // 0x11
                                            // ⭐ 失真增益：⭐ 字节 ×256 ⇒ Q4.12（⭐ 恰好占满 16 位）
                                            //    ⭐ 值 64 ⇒ 16384 = 4.0（默认）· 值 32 ⇒ 8192 = 2.0
                                            //    ⚠️ **"255 ⇒ 15.9375" 是【算术上界】，⭐ 而 UART 发不到** ——
                                            //       🔴 `0xFF` 是帧尾标记（⭐ 见端口注释表下方那条）
                                            //       ⇒ ⭐ **实际可发的最大值 = 254 ⇒ 65024 = 15.875 倍** ✅
                                            //    📌 `GAIN_W=16` ⇒ `{val_q,8'b0}` 恰好 16 位；254 ⇒ `0xFE00`=65024 ≤ 65535
                                            //       ⇒ ⭐ **装得下、无截断**；`SUM1_W=SUM2_W=SAMPLE_W+16=40` ⇒ **无溢出** ✅
                                            fx_gain_o   <= {val_q, 8'b0};
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd18) begin // 0x12
                                            // ⭐ 失真补偿：⭐ 字节 ×256 ⇒ Q1.15（⭐ 恰好占满 16 位）
                                            //    ⭐ 值 32 ⇒ 8192 = 0.25（默认）· 值 128 ⇒ 32768 = 1.0 ✅
                                            //    📌 `TRIM_W=16` ⇒ `{val_q,8'b0}` 恰好 16 位，255 ⇒ `0xFF00` ≤ 65535
                                            //       ⇒ ⭐ **无截断、无溢出** ✅
                                            fx_trim_o   <= {val_q, 8'b0};
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd19) begin // 0x13
                                            fx_mix_o    <= val_q;         // ⭐ Q0.8 直传
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd20) begin // 0x14
                                            fx_fb_o     <= val_q;         // ⭐ Q0.8 直传
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd21) begin // 0x15
                                            fx_depth_o  <= val_q;         // ⭐ 0 = 数值恒等
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd22) begin // 0x16
                                            fx_rate_o   <= val_q;
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd23) begin // 0x17
                                            // ⭐ 延迟长度：⭐ 字节 ×128 采样
                                            //    ⭐ 值 64 ⇒ 8192 采样 ⇒ 168 ms（默认）✅
                                            //    ⚠️ 最大 值 127 ⇒ 16256 采样 ⇒ 333 ms
                                            //       （⭐ 再大就饱和到【可寻址上限 16383 = DEPTH-1】）
                                            //    🔴 2026-10-15 修：原写 `14'd16384` —— ⭐ 2^14 装不进 14 位
                                            //       ⇒ 字面量被**截断成 0**（⭐ 综合器早报了 `WARN (EX3792)`）
                                            //       ⇒ `fx_delay` 把 0 夹到 `DLY_MIN=2` ⇒ 用户要"最大延迟"
                                            //         实得 **41 µs 的梳状滤波** ✗
                                            //    📌 正确上限 = `DEPTH-1` = **16383**（⭐ `fx_delay.v:125` 的 `DEPTH_M1`）
                                            fx_dlylen_o <= (val_q > 8'd127) ? 14'd16383
                                                                            : {val_q[6:0], 7'b0};
                                            fx_commit_o <= 1'b1;
                                        end else if (body_q == 8'd24) begin // 0x18
                                            // ⭐ 合唱长度：⭐ 字节 ×32 采样
                                            //    ⭐ 值 23 ⇒ 736（⭐ **= 上电默认值**，⭐ 15 ms）✅
                                            //       📌 默认值已从 732 改成 736 ⇒ ⭐ **在 ×32 格点上**，
                                            //          ⭐ 发 23 就能**回到上电状态**（⭐ 见 `FX_CHORLEN_DEF` 注释）✅
                                            //    ⚠️ `AW_CH=11` ⇒ 可寻址上限 **2047** 采样（⭐ 值 63 ⇒ 2016）✅
                                            //    🔴 2026-10-15 修：原写 `11'd2048`（= 2^11）⇒ 同样被截断成 **0**
                                            fx_chorlen_o <= (val_q > 8'd63) ? 11'd2047
                                                                           : {val_q[5:0], 5'b0};
                                            fx_commit_o <= 1'b1;
                                        end
                                    end
                                    // ⭐ RET_STR / RET_BOOT：本版只回显，不落地控制量
                                    default: begin end
                                endcase
                            end else begin
                                tail_cnt <= tail_cnt + 3'd1;
                            end
                        end else begin
                            // ⭐ 非 0xFF：数据字节，且打断 0xFF 连续计数
                            tail_cnt <= 3'd0;
                            // ⭐ 记录「第一个有意义字节」到 body_q（控件 ID / 变量序号）
                            //  🔴 **2026-10-15 修**：⭐ 原来是 `rx_data_i[6:0]`
                            //     ⇒ ⭐ 丢最高位 ⇒ 🔴 **`0x90` 别名成 `0x10`**（见声明处长注释）✅
                            if (body_len == 6'd0) begin
                                body_q <= rx_data_i;
                            end
                            // ⭐ 数值返回：记录数值字节到 val_q
                            if (body_len == 6'd1) begin
                                val_q <= rx_data_i;
                            end
                            body_len <= body_len + 6'd1;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end else if (idle_expired && (state != S_IDLE)) begin
                // ══ 空闲间隔归位：半帧作废 ════════════════════════════════
                state        <= S_IDLE;
                tail_cnt     <= 3'd0;
                resync_cnt_o <= sat_inc16(resync_cnt_o);
            end
        end
    end

    // FXSTAT: Zz<sub><four hexadecimal digits>LF, eight bytes total.
    // An accepted byte advances the serializer; pressure never drops a byte.
    // One latest pending request is retained separately from the active frame.
    // Overwriting that pending request increments the saturating drop counter.
    localparam [3:0] ZFS_S_IDLE=4'd0, ZFS_S_HDR1=4'd1,
        ZFS_S_HDR2=4'd2, ZFS_S_N=4'd3, ZFS_S_HI=4'd4,
        ZFS_S_MH=4'd5, ZFS_S_ML=4'd6, ZFS_S_LO=4'd7, ZFS_S_LF=4'd8;
    reg [3:0] zfs_state;
    reg zfs_pend_q;
    reg [2:0] zfs_sub_q, zfs_pending_sub;
    reg [15:0] zfs_val_q, zfs_pending_val;
    // Existing standalone benches omit this new port; Z means no pressure.
    assign fx_tx_pending_o = (zfs_state != ZFS_S_IDLE) || zfs_pend_q;
    wire zfs_ready = (fx_tx_ready_i !== 1'b0);
    reg [15:0] zfs_val_c;
    always @(*) begin
        case (fxstat_sub_i)
            3'd0: zfs_val_c = {8'd0, fx_en_mask_i};                    // ⭐ 8 位 ⇒ 高位补 0
            3'd1: zfs_val_c = fx_dist_clip_i;                          // ⭐ 16 位
            3'd2: zfs_val_c = {15'd0, fx_dly_active_i};                // ⭐ 1 位
            3'd3: zfs_val_c = {14'd0, fx_chor_active_i, fx_dly_primed_i}; // ⭐ 2 位（bit1=chor, bit0=primed）
            3'd4: zfs_val_c = fx_trem_lfo_i;                           // ⭐ 16 位
            3'd5: zfs_val_c = fx_pipe_i;                               // ⭐ 16 位
            default: zfs_val_c = 16'd0;                                // ⭐ 6/7 预留 ⇒ 全 0
        endcase
    end

    function [7:0] hex2asc;
        input [3:0] h;
        begin
            hex2asc = (h < 4'd10) ? ({4'd0, h} + 8'h30)
                                  : ({4'd0, h} + 8'h37);
        end
    endfunction
    always @(*) begin
        fx_tx_start_o = (zfs_state != ZFS_S_IDLE) && zfs_ready;
        case (zfs_state)
            ZFS_S_HDR1: fx_tx_data_o=8'h5a;
            ZFS_S_HDR2: fx_tx_data_o=8'h7a;
            ZFS_S_N: fx_tx_data_o={5'd0,zfs_sub_q}+8'h30;
            ZFS_S_HI: fx_tx_data_o=hex2asc(zfs_val_q[15:12]);
            ZFS_S_MH: fx_tx_data_o=hex2asc(zfs_val_q[11:8]);
            ZFS_S_ML: fx_tx_data_o=hex2asc(zfs_val_q[7:4]);
            ZFS_S_LO: fx_tx_data_o=hex2asc(zfs_val_q[3:0]);
            ZFS_S_LF: fx_tx_data_o=8'h0a;
            default: fx_tx_data_o=8'd0;
        endcase
    end
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            zfs_state<=ZFS_S_IDLE; zfs_pend_q<=1'b0;
            zfs_sub_q<=3'd0; zfs_val_q<=16'd0;
            zfs_pending_sub<=3'd0; zfs_pending_val<=16'd0;
            zfs_req_cnt_o<=16'd0; zfs_drop_cnt_o<=16'd0;
        end else begin
            if (fxstat_req_i) zfs_req_cnt_o<=sat_inc16(zfs_req_cnt_o);
            if (zfs_state==ZFS_S_IDLE) begin
                if (fxstat_req_i || zfs_pend_q) begin
                    zfs_sub_q<=fxstat_req_i ? fxstat_sub_i : zfs_pending_sub;
                    zfs_val_q<=fxstat_req_i ? zfs_val_c : zfs_pending_val;
                    zfs_pend_q<=1'b0;
                    zfs_state<=ZFS_S_HDR1;
                    if (fxstat_req_i && zfs_pend_q)
                        zfs_drop_cnt_o<=sat_inc16(zfs_drop_cnt_o);
                end
            end else begin
                if (fxstat_req_i) begin
                    zfs_pending_sub<=fxstat_sub_i; zfs_pending_val<=zfs_val_c;
                    zfs_pend_q<=1'b1;
                    if (zfs_pend_q) zfs_drop_cnt_o<=sat_inc16(zfs_drop_cnt_o);
                end
                if (zfs_ready)
                    zfs_state <= (zfs_state==ZFS_S_LF) ? ZFS_S_IDLE : zfs_state+4'd1;
            end
        end
    end

endmodule

`default_nettype wire
