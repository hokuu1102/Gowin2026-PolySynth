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
    //     · ⭐ **交付实传 = 115200** —— ⭐ 见 `top.v` 的 `uart_ui` 例化
    //       （⭐ `.BAUD(115_200)`，⭐ 与 `uart_rx.BAUD_DIV=434` 同档 ✅
    //        🔴 2026-10-28 板载口 500 kbps → 115200 —— ⭐ 串口屏 TJC 不支持 500000 档 ✅）
    //     🔴 **⛔ 不要照着"默认 1e6"去配 `uart_rx`** —— ⚠️ 上板走的是 `top.v` 传的 115200
    //        （⭐ 原注释只写"1 Mbps = 1000000（默认）"，⭐ 容易让人以为交付就是 1 Mbps）✅
    parameter integer BAUD = 1000000,
    // ⭐ 空闲归位阈值（单位：字节时间）。> 1，取 16（对齐 evt_uart_rx 的 GAP_BYTES）
    parameter integer GAP_BYTES = 16,
    //  ⭐⭐ 2026-10-29：⭐ **心跳周期**（单位：ms，⭐ 喂屏侧看门狗 `tm1`）
    //     📌 交付取值 1000ms（⭐ 屏侧 `tm1` 周期 1500ms ⇒ 500ms 余量）；
    //        ⭐ tb 用小值加速（⭐ `tb_uart_ui.sv` 传 1ms）⇒ ⛔ 判据不依赖真实手感 ✅
    parameter integer HB_MS = 1000,
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

    // ── ⭐ 音色循环请求（⭐ 丙 · 2026-10-30）────────────────────────────────
    //   🔴 **为什么要加**：⭐ `t_timbre`（BASS/GUITAR/PIANO/PAD）在屏上是
    //      32px 大字看似主控件，但原来**屏上没有任何按钮能切音色**——
    //      入口只有板载 S2 按键和调试串口 'I' ⇒ 🔴 屏侧闭环缺一环 ✗
    //   ✅ **现在**：⭐ 触摸控件 3 = 音色循环请求（单周期脉冲）
    //      ⭐ 真正的 `timbre_sel_r` 在 `top.v`（2 位自然回绕 0→1→2→3→0），
    //      本模块只发脉冲 ⛔ 不存音色值 —— 📌 与 'I'/S2 **并联**（或）✅
    //   📌 **回显自动闭环**：⭐ 回显 FSM 只盯 `st_timbre_i` 的值变化挂帧
    //      （uart_ui.v 变化检测段），无论变化来自屏触摸 / 'I' / S2 ⇒
    //      ⭐ 本入口加上后 t_timbre 文字切换**零额外回显代码** ✅
    output reg         timbre_req_o,       // ⭐ 音色循环请求（单周期脉冲）

    // ── ⭐⭐ page0 控制面板化：11 个触摸控件脉冲（⭐ 丙 · 2026-10-31）──────────
    //   🔴 **为什么要加**：⭐ page0 上 t_slide/t_drum/t_kd/t_trans/t_loop/
    //      t_gear/t_bpm 原来都只是**文字显示**（回显）⇒ 🔴 屏上**没有入口**
    //      能改它们（只有调试串口 'W'/'D'/'K'/'F'/'G'/'R'/'L'/'C'/'J'/'Q'）✗
    //   ✅ **现在**：⭐ 每个字段右端叠放一个热区按钮，点按发 `65 00 <id>`
    //      帧 ⇒ 本模块发**单周期脉冲**，top.v 里与对应 `cmd_*_req`
    //      **并联**（或），与调试串口命令**完全同一条下游路径** ✅
    //   📌 **回显自动闭环**：⭐ 回显 FSM 只盯 `st_*_i` 值变化挂帧，
    //      无论变化来自屏触摸 / 调试串口 ⇒ ⭐ **零额外回显代码** ✅
    //
    //   📌 **控件 ID 分配**（⭐ 与 tb / 搭建清单 v3 三方对齐）：
    //   | id | 控件 | 按钮 | 对应调试命令 | 下游寄存器 |
    //   |----|------|------|--------------|------------|
    //   | 4  | 滑音开/关   | b_slide  | 'W' | top.v slide_en_r |
    //   | 5  | 鼓机节奏下一 | b_drum   | 'D' | drum_pat_r |
    //   | 6  | 键盘打鼓开关 | b_kd     | 'K' | kd_active_r |
    //   | 7  | 移调 +1 半音 | b_tr_up  | 'F' | trans_semi_r |
    //   | 8  | 移调 -1 半音 | b_tr_dn  | 'G' | trans_semi_r |
    //   | 9  | 循环录音     | b_rec    | 'R' | looper rec |
    //   | 10 | 循环播放     | b_play   | 'L' | looper play |
    //   | 11 | 循环清空     | b_clear  | 'C' | looper clear |
    //   | 12 | 推子档位下一 | b_gear   | 'J' | gear_r（1..5 循环）|
    //   | 13 | BPM +5      | b_bpm_up | 'Q'+val | bpm shadow |
    //   | 14 | BPM -5      | b_bpm_dn | 'Q'+val | bpm shadow |
    output reg         slide_req_o,        // ⭐ 控件 4：滑音开/关（单周期脉冲）
    output reg         drum_req_o,         // ⭐ 控件 5：鼓机节奏型下一（单周期脉冲）
    output reg         kd_req_o,           // ⭐ 控件 6：键盘打鼓开/关（单周期脉冲）
    output reg         trans_up_req_o,     // ⭐ 控件 7：移调 +1 半音（单周期脉冲）
    output reg         trans_dn_req_o,     // ⭐ 控件 8：移调 -1 半音（单周期脉冲）
    output reg         loop_rec_req_o,     // ⭐ 控件 9：循环录音请求（单周期脉冲）
    output reg         loop_play_req_o,    // ⭐ 控件 10：循环播放请求（单周期脉冲）
    output reg         loop_clear_req_o,   // ⭐ 控件 11：循环清空请求（单周期脉冲）
    output reg         gear_req_o,         // ⭐ 控件 12：推子档位下一（单周期脉冲）
    output reg         bpm_up_req_o,       // ⭐ 控件 13：BPM +5（单周期脉冲）
    output reg         bpm_dn_req_o,       // ⭐ 控件 14：BPM -5（单周期脉冲）

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
    output reg         fx_tx_start_o,     // ⭐ 推一个字节给 u_tx_fifo（单周期脉冲）
    output reg  [7:0]  fx_tx_data_o,      // ⭐ 那个字节
    //  ⭐⭐ 可观测性（`K-106`：⛔ 不许静默失效）
    //     ⚠️ 若 `'Z'` 静默失效（⭐ 例如 `calib_cmd` 漏加总闸、⭐ 或 `top.v` 忘接臂），
    //        ⭐ 现象是"发了 `'Z'` 什么都没有" ⇒ 🔴 **无法归因** ✅
    //     ✅ 三个计数器全部接出来（⭐ `top.v` 已把它 OR 进回读帧的观测点 ✅）
    output reg  [15:0] zfs_req_cnt_o,    // ⭐ 已受理的回读请求数（饱和）
    output reg  [15:0] zfs_drop_cnt_o,   // ⭐ 因上一帧未发完而【挂起】的次数（饱和）

    // ── ⭐⭐ 2026-10-29：⭐ Page0 状态回显输入（⭐ 只读，全部来自 top.v 模块层信号）──
    //   ⭐ 控件号/文案严格按《USART-HMI搭建清单-Page0-20261028.md》✅
    //   ⚠️ **全部 Z-safe**：⭐ 老 tb 不接新端口 ⇒ 输入 `z` ⇒ 一律取"默认值"
    //      （⭐ = 信号复位值）⇒ 镜像与输入恒相等 ⇒ ⛔ 不产生伪回显帧 ⇒ **零回归** ✅
    //   📌 单比特沿用项目既有约定 `=== 1'b1`（z/x 当假）；多比特用 `=== N'bz`（悬空=全 z）✅
    input  wire [7:0]  st_bpm_i,     // ⭐ play_seq.bpm_o（t_bpm 巨字，复位 120）
    input  wire [1:0]  st_timbre_i,  // ⭐ timbre_sel_r（t_timbre：0=BASS/1=GUITAR/2=PIANO/3=PAD）
    input  wire [4:0]  st_trans_i,   // ⭐ transpose_semi（t_trans，⚠️ 有符号 −12..+12）
    input  wire        st_slide_i,   // ⭐ slide_on_r（t_slide：开启/关闭）
    input  wire [2:0]  st_drum_i,    // ⭐ {drum_on_r, drum_pattern_r}（t_drum：Pattern I..IV / 关）
    input  wire        st_kd_i,      // ⭐ key_drum_r（t_kd：键盘打鼓开/关）
    input  wire [1:0]  st_loop_i,    // ⭐ led_looper_st（t_loop：0=空闲/1=录音/2=回放/3=武装中）
    input  wire [6:0]  st_vol_i,     // ⭐ 主音量百分比 0..100（t_vol + j_vol.val）
    input  wire        st_pedal_i,   // ⭐ sus_pedal_r（t_pedal：踩下使能/松开）
    input  wire [1:0]  st_gear_i,    // ⭐ led_gear_st（t_gear：0=变调/1=音高颤音/2=音量颤音/3=无）
    input  wire [1:0]  st_scope_i,   // ⭐ scope_mode_r（t_hdmi：0=波形/1=李萨如/2=频谱）
    input  wire [6:0]  st_pvib_i,    // ⭐ 音高颤音深度百分比（t_pd + z_pd.val）
    input  wire [6:0]  st_vvib_i,    // ⭐ 音量颤音深度百分比（t_vd + z_vd.val）
    input  wire [2:0]  st_fxmask_i,  // ⭐ ui_fx_mask[2:0]（t_dist_st/t_chor_st/t_dly_st）
    //  ⭐⭐ 2026-10-31：《控件位置清单》新输入（⭐ 全部 Z-safe，见下方 ③b）
    input  wire [11:0] st_prate_i,   // ⭐ 音高颤音速率原始值 vib_rate_sel（0..4095 → 1..12Hz）
    input  wire [7:0]  st_vrate_i,  // ⭐ 音量颤音速率 trem_rate_eff（f = rate×48828/65536 Hz）
    input  wire        beat_i,      // ⭐ 节拍脉冲（p_bpm 橙点每拍翻转）
    //  ⭐⭐ 2026-11-01 队友新增输入（⭐ 全部 Z-safe）
    input  wire        st_lock_i,   // ⭐ 当前推子档锁定状态（fg_hold[gear]，1=锁定 ⇒ t_lock）
    input  wire [5:0]  st_nactive_i,// ⭐ 当前活跃复音数 mx_n_active（0..32 ⇒ t1 复音数）

    // ── ⭐⭐ 2026-10-31：b_uplink 实时上行开关（⭐ 触摸控件 15 翻转，top 只读消费）──
    output reg         uplink_sw_o, // ⭐ 1 = 开启（复位默认）

    // ── ⭐⭐ 2026-10-29：⭐ EC11 参数旋钮【写回】（缺口4）────────────────────────
    //   🔴 **背景**：⭐ EC11 的 `enc_par_up/dn` 原来只发 `'E'` 反馈帧、⛔ **不写 fx 寄存器**
    //      ⇒ ⭐ 旋了半天屏上/链路上**什么都没变** ⇒ 🔴 典型 K-106 形态 ✗
    //   ⭐ **修法**：⭐ 把 EC11 的"选参 + 步进"直接接进本模块的 fx 寄存器
    //      （⭐ 与串口 `0x11..0x18` 帧**写同一组寄存器** ⇒ 后写者胜，⛔ 无仲裁 ✅）
    //   📌 参数号与 uart_ui 变量号**一一对齐**（0x11..0x18 − 0x11 = 0..7）：
    //      | 0=gain · 1=trim · 2=mix · 3=fb · 4=depth · 5=rate · 6=dlylen · 7=chorlen |
    //   📌 步进粒度 = **串口帧可达的最小格点**（⭐ 保证 EC11 调完还能用串口帧复原 ✅）：
    //      gain/trim ±256（=1 个字节档）· mix/fb/depth/rate ±1 · dlylen ±128 · chorlen ±32
    //   ⚠️ 全部**限幅到串口帧可达范围**（⭐ 0..254 字节域 / 0x17 的 127 档 / 0x18 的 63 档）✅
    input  wire [2:0]  par_sel_i,    // ⭐ EC11 选中的参数号 0..7（电平）
    input  wire        par_up_i,     // ⭐ +1 步进（单周期脉冲）
    input  wire        par_dn_i,     // ⭐ −1 步进（单周期脉冲）

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
    // ③b  ⭐⭐ 2026-10-29：Page0 回显输入 / EC11 写回输入的 **Z-safe 接线** ✅
    //   🔴 **为什么**：⭐ 老 tb 不接这批新端口 ⇒ 输入是 `z` ⇒
    //      ⚠️ 直接 `==` 比较会把 `z` 当 `x` 传播进回显镜像 ⇒ 🔴 伪帧/不定态 ✗
    //   ✅ **修法**：⭐ 单比特 `=== 1'b1`（z/x 当假）；多比特 `=== N'bz` 判悬空 ⇒
    //      ⭐ 悬空一律取「信号复位值」（⭐ 与端口注释的默认值表**逐项对齐**）⇒
    //      ⭐ 镜像初值 = 同一复位值 ⇒ ⛔ 不产生伪回显帧 ⇒ **零回归** ✅
    //   📌 `par_sel_c` 悬空取 0 无害：⭐ up/dn 脉冲悬空恒假 ⇒ 写回分支进不去 ✅
    // ═══════════════════════════════════════════════════════════════════════
    wire [7:0]  st_bpm_c    = (st_bpm_i    === 8'bz) ? 8'd120 : st_bpm_i;   // 复位 120
    wire [1:0]  st_timbre_c = (st_timbre_i === 2'bz) ? 2'd0   : st_timbre_i;
    wire [4:0]  st_trans_c  = (st_trans_i  === 5'bz) ? 5'd0   : st_trans_i;
    wire        st_slide_c  = (st_slide_i  === 1'b1);
    wire [2:0]  st_drum_c   = (st_drum_i   === 3'bz) ? 3'b100 : st_drum_i;   // 复位：开 + Pattern I
    wire        st_kd_c     = (st_kd_i     === 1'b1);
    wire [1:0]  st_loop_c   = (st_loop_i   === 2'bz) ? 2'd0   : st_loop_i;
    wire [6:0]  st_vol_c    = (st_vol_i    === 7'bz) ? 7'd0   : st_vol_i;
    wire        st_pedal_c  = (st_pedal_i  === 1'b1);
    wire [1:0]  st_gear_c   = (st_gear_i   === 2'bz) ? 2'd1   : st_gear_i;   // 复位档 1
    wire [1:0]  st_scope_c  = (st_scope_i  === 2'bz) ? 2'd0   : st_scope_i;
    wire [6:0]  st_pvib_c   = (st_pvib_i   === 7'bz) ? 7'd0   : st_pvib_i;
    wire [6:0]  st_vvib_c   = (st_vvib_i   === 7'bz) ? 7'd0   : st_vvib_i;
    wire [2:0]  st_fxmask_c = (st_fxmask_i === 3'bz) ? 3'd0   : st_fxmask_i;
    wire        par_up_c    = (par_up_i    === 1'b1);
    wire        par_dn_c    = (par_dn_i    === 1'b1);
    wire [2:0]  par_sel_c   = (par_sel_i   === 3'bz) ? 3'd0   : par_sel_i;
    //  ⭐⭐ 2026-10-31 新增端口 Z-safe（⭐ 复位默认 = 信号复位值 ⇒ ⛔ 零伪帧）✅
    wire [11:0] st_prate_c  = (st_prate_i  === 12'bz) ? 12'd0  : st_prate_i;
    wire [7:0]  st_vrate_c  = (st_vrate_i  === 8'bz) ? 8'd7   : st_vrate_i;   // = FX_RATE_DEF
    wire        beat_c      = (beat_i      === 1'b1);
    wire        st_lock_c   = (st_lock_i   === 1'b1);                          // 1=锁定
    wire [5:0]  st_nactive_c= (st_nactive_i=== 6'bz) ? 6'd0   : st_nactive_i; // 复音数 0..32

    // ── ⭐⭐ 2026-10-31：颤音速率 → 十分之一赫兹（dHz）换算 ─────────────────────
    //   音高（vib_rate_sel 0..4095 线性 → 1..12Hz，vibrato_lfo：rate_inc=86+raw×945>>12）：
    //     dHz = 10 + (raw×110+2048)>>12（线性近似，中点误差 < 0.005Hz ✅）
    //   音量（fx_trem 8 位相位增量，f = rate×48828/65536 Hz）：
    //     dHz = (rate×488280+32768)>>16（⭐ 默认 7 → 52 → "5.2Hz" 恰合队友文案 ✅）
    wire [19:0] ech_prate_hz = 20'd10 + ((st_prate_c * 20'd110 + 20'd2048) >> 12);
    wire [26:0] ech_vrate_hz = (st_vrate_c * 27'd488280 + 27'd32768) >> 16;

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
            timbre_req_o <= 1'b0;           // ⭐ 2026-10-30：音色循环脉冲复位清零
            //  ⭐ 2026-10-31：page0 控制面板 11 个脉冲复位清零
            slide_req_o     <= 1'b0;
            drum_req_o      <= 1'b0;
            kd_req_o        <= 1'b0;
            trans_up_req_o  <= 1'b0;
            trans_dn_req_o  <= 1'b0;
            loop_rec_req_o  <= 1'b0;
            loop_play_req_o <= 1'b0;
            loop_clear_req_o<= 1'b0;
            gear_req_o      <= 1'b0;
            bpm_up_req_o    <= 1'b0;
            bpm_dn_req_o    <= 1'b0;
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
            //  ⭐ 2026-10-31：b_uplink 实时上行开关（⭐ 复位默认开启）
            uplink_sw_o  <= 1'b1;
        end else begin
            // ⭐ 默认：脉冲类输出每拍清零 ⇒ 严格单周期
            mode_commit_o <= 1'b0;
            base_commit_o <= 1'b0;
            test_mode_commit_o <= 1'b0;
            //  ⭐ 音色循环脉冲：⭐ 默认每拍清零 ⇒ 严格单周期 ✅
            timbre_req_o <= 1'b0;
            //  ⭐ 2026-10-31：page0 控制面板 11 个脉冲默认每拍清零 ⇒ 严格单周期 ✅
            slide_req_o     <= 1'b0;
            drum_req_o      <= 1'b0;
            kd_req_o        <= 1'b0;
            trans_up_req_o  <= 1'b0;
            trans_dn_req_o  <= 1'b0;
            loop_rec_req_o  <= 1'b0;
            loop_play_req_o <= 1'b0;
            loop_clear_req_o<= 1'b0;
            gear_req_o      <= 1'b0;
            bpm_up_req_o    <= 1'b0;
            bpm_dn_req_o    <= 1'b0;
            //  ⭐ 效果器参数提交脉冲：⭐ 默认每拍清零 ⇒ 严格单周期 ✅
            fx_commit_o   <= 1'b0;

            //  ⭐⭐ 2026-10-13：外部模式翻转（串口 'A' 命令 / 控制板模式键）
            //     与屏触摸控件 0 **同一语义**。
            //  ⚠️ 与屏触摸**同拍**时的取舍：本分支在前 ⇒ 同拍以屏为准（可接受）。
            if (mode_sw_req_i) begin
                mode_o        <= ~mode_o;
                mode_commit_o <= 1'b1;
            end

            //  ⭐⭐ 2026-10-29：EC11 参数旋钮【写回】（缺口4）────────────────
            //   🔴 **背景**：⭐ EC11 的 `enc_par_up/dn` 原来只发 `'E'` 反馈帧、
            //      ⛔ **不写 fx 寄存器** ⇒ ⭐ 旋了半天**链路上什么都没变** ⇒
            //      🔴 典型 K-106「静默失效」形态（⭐ 无法归因）✗
            //   ✅ **修法**：⭐ 把 EC11 的"选参 + 步进"直接落到与串口帧
            //      `0x11..0x18` **同一组** fx 寄存器 ⇒ ⭐ 后写者胜、⛔ 无仲裁 ✅
            //   📌 参数号对齐：`par_sel_c` 0..7 ↔ 串口变量 `0x11..0x18` − 0x11 ✅
            //   📌 步进粒度 = 串口帧最小格点（⭐ 保证串口帧还能把值**写回来**）：
            //      · gain/trim ±256（16 位 = `val×256`）· mix/fb/depth/rate ±1
            //      · dlylen ±128（14 位 = `val×128`）· chorlen ±32（= `val×32`）
            //   ⚠️ 全部**限幅到串口帧可达范围**（65024 / 254 / 16256 / 2016）✅
            //   ⚠️ **摆放位置**：⭐ 本段在 `rx_done_i` 解析【之前】⇒
            //      同拍既有旋钮脉冲又有串口帧 ⇒ 串口帧后执行 ⇒ ⭐ **串口帧胜**
            //      （⭐ 与上方 `mode_sw_req_i` 的取舍**同款**，⭐ 可接受）✅
            //   ⚠️ up/dn **同拍** ⇒ ⛔ 互斥丢弃（⭐ 编码器换向抖动不可能同拍；
            //      `fx_commit_o` 也**不置位** ⇒ ⛔ 不发空提交脉冲）✅
            if (par_up_c && !par_dn_c) begin
                case (par_sel_c)
                    3'd0: fx_gain_o    <= (fx_gain_o    < 16'd64768) ? fx_gain_o + 16'd256 : 16'd65024;
                    3'd1: fx_trim_o    <= (fx_trim_o    < 16'd64768) ? fx_trim_o + 16'd256 : 16'd65024;
                    3'd2: fx_mix_o     <= (fx_mix_o     <  8'd254  ) ? fx_mix_o  +  8'd1   :  8'd254;
                    3'd3: fx_fb_o      <= (fx_fb_o      <  8'd254  ) ? fx_fb_o   +  8'd1   :  8'd254;
                    3'd4: fx_depth_o   <= (fx_depth_o   <  8'd254  ) ? fx_depth_o + 8'd1   :  8'd254;
                    3'd5: fx_rate_o    <= (fx_rate_o    <  8'd254  ) ? fx_rate_o +  8'd1   :  8'd254;
                    3'd6: fx_dlylen_o  <= (fx_dlylen_o  < 14'd16128) ? fx_dlylen_o + 14'd128 : 14'd16256;
                    default: fx_chorlen_o <= (fx_chorlen_o < 11'd1984) ? fx_chorlen_o + 11'd32 : 11'd2016;
                endcase
                fx_commit_o <= 1'b1;    // ⭐ 写回即提交（⭐ 与串口帧同款语义）
            end else if (par_dn_c && !par_up_c) begin
                case (par_sel_c)
                    3'd0: fx_gain_o    <= (fx_gain_o    > 16'd256) ? fx_gain_o - 16'd256 : 16'd0;
                    3'd1: fx_trim_o    <= (fx_trim_o    > 16'd256) ? fx_trim_o - 16'd256 : 16'd0;
                    3'd2: fx_mix_o     <= (fx_mix_o     >  8'd1  ) ? fx_mix_o  -  8'd1   :  8'd0;
                    3'd3: fx_fb_o      <= (fx_fb_o      >  8'd1  ) ? fx_fb_o   -  8'd1   :  8'd0;
                    3'd4: fx_depth_o   <= (fx_depth_o   >  8'd1  ) ? fx_depth_o -  8'd1   :  8'd0;
                    3'd5: fx_rate_o    <= (fx_rate_o    >  8'd1  ) ? fx_rate_o -  8'd1   :  8'd0;
                    3'd6: fx_dlylen_o  <= (fx_dlylen_o  > 14'd128) ? fx_dlylen_o - 14'd128 : 14'd0;
                    default: fx_chorlen_o <= (fx_chorlen_o > 11'd32) ? fx_chorlen_o - 11'd32 : 11'd0;
                endcase
                fx_commit_o <= 1'b1;
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
                                // ⭐⭐ 2026-10-29 三件套-A：⭐ **每次收到 0x88 都请求全量重发** ✅
                                //   📌 首次：与 `!ech_hb_s` 握手沿同拍 ⇒ 二选一触发（reflash_q 次拍自清）
                                //   📌 重复：⭐ 屏切页返回时发 `88` ⇒ ⭐ 靠本标志再拿 22 帧新值
                                reflash_q <= 1'b1;
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
                                        //      控件 2 = Test Mode 切档（⭐ A1），
                                        //      控件 3 = 音色循环（⭐ 2026-10-30，top.v 并入 timbre_sel_r）
                                        //      ⭐ 2026-10-31：控件 4..15 = page0 控制面板组
                                        //      （4=滑音 5=鼓机 6=打鼓 7/8=移调± 9/10/11=循环录播清
                                        //       12=档位 13/14=BPM±5 15=实时上行，见端口区分配表）
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
                                        end else if (body_q == 8'd3) begin
                                            // ⭐ 2026-10-30：音色循环请求（b_timbre 按钮）
                                            //   ⭐ 只发脉冲，音色值由 top.v 的 timbre_sel_r 管理
                                            //    （0=BASS→1=GUITAR→2=PIANO→3=PAD→0 回绕）
                                            timbre_req_o <= 1'b1;
                                        end else if (body_q == 8'd4) begin
                                            // ⭐ 2026-10-31：滑音开/关（b_slide）
                                            slide_req_o <= 1'b1;
                                        end else if (body_q == 8'd5) begin
                                            // ⭐ 2026-10-31：鼓机节奏型下一（b_drum）
                                            drum_req_o <= 1'b1;
                                        end else if (body_q == 8'd6) begin
                                            // ⭐ 2026-10-31：键盘打鼓开/关（b_kd）
                                            kd_req_o <= 1'b1;
                                        end else if (body_q == 8'd7) begin
                                            // ⭐ 2026-10-31：移调 +1 半音（b_tr_up）
                                            trans_up_req_o <= 1'b1;
                                        end else if (body_q == 8'd8) begin
                                            // ⭐ 2026-10-31：移调 -1 半音（b_tr_dn）
                                            trans_dn_req_o <= 1'b1;
                                        end else if (body_q == 8'd9) begin
                                            // ⭐ 2026-10-31：循环录音（b_rec）
                                            loop_rec_req_o <= 1'b1;
                                        end else if (body_q == 8'd10) begin
                                            // ⭐ 2026-10-31：循环播放（b_play）
                                            loop_play_req_o <= 1'b1;
                                        end else if (body_q == 8'd11) begin
                                            // ⭐ 2026-10-31：循环清空（b_clear）
                                            loop_clear_req_o <= 1'b1;
                                        end else if (body_q == 8'd12) begin
                                            // ⭐ 2026-10-31：推子档位下一（b_gear，1..5 循环）
                                            gear_req_o <= 1'b1;
                                        end else if (body_q == 8'd13) begin
                                            // ⭐ 2026-10-31：BPM +5（b_bpm_up，40..240 饱和）
                                            bpm_up_req_o <= 1'b1;
                                        end else if (body_q == 8'd14) begin
                                            // ⭐ 2026-10-31：BPM -5（b_bpm_dn，40..240 饱和）
                                            bpm_dn_req_o <= 1'b1;
                                        end else if (body_q == 8'd15) begin
                                            //  ⭐⭐ 2026-10-31：实时上行开关翻转（b_uplink）
                                            //   📌 只翻转本模块寄存器；⭐ 回显帧由变化检测
                                            //      （uplink_sw_o ≠ 镜像 ech_uplink_s）自动挂起
                                            //      ⇒ ⛔ 不在此写 ech_pend（只归回显 always 块写 ✅）
                                            uplink_sw_o <= ~uplink_sw_o;
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
                                        end                                         else if (body_q == 8'd24) begin // 0x18
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
                                        //  ⭐⭐ 2026-10-29 三件套-B：⭐ **翻转变量 0x19**（效果器开关）✅
                                        //     🔴 **为什么**：⭐ 屏 page1 的效果器开关按钮只知道"翻哪个 bit"，
                                        //        ⛔ **不知道当前值**（⭐ 0x10 是绝对写、屏没法翻转）⇒ 屏侧要
                                        //        状态记账才能发绝对值（⭐ 两套状态源必漂）✗
                                        //     ✅ **修法**：⭐ `fx_mask_o ^= val_q`（⭐ 屏发 `71 19 01/02/04`
                                        //        盲翻转 Bit0/1/2，⭐ 无状态、天然幂等收敛）✅
                                        //     📌 翻转结果由回显 FSM 三状态条帧（t_dist_st 等）反馈给屏 ✅
                                        else if (body_q == 8'd25) begin // 0x19
                                            fx_mask_o   <= fx_mask_o ^ val_q;
                                            fx_commit_o <= 1'b1;
                                        end
                                        //  ⭐⭐ 2026-10-29 三件套-C：⭐ **八度循环变量 0x1B**（起始音）✅
                                        //     🔴 **为什么**：⭐ b_oct 按 0/12/24 循环，屏侧若用 0x01 绝对写
                                        //        得自己记账（⭐ 硬件侧也改过就记偏）✗
                                        //     ✅ **修法**：⭐ FPGA 侧自循环 `0→12→24→0`（⭐ 与 b_oct 语义
                                        //        一对一），⭐ 屏发一句 `71 1B 01` 即可、无需记账 ✅
                                        //     📌 ⚠️ 非格点值（0x01 绝对写过）：一律归到 0 重开循环 ✅
                                        else if (body_q == 8'd27) begin // 0x1B
                                            base_semi_o  <= (base_semi_o == 7'd0)  ? 7'd12
                                                          : (base_semi_o == 7'd12) ? 7'd24
                                                          : 7'd0;
                                            base_commit_o<= 1'b1;
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

    // ═══════════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-17（`K-106`）：⭐ **效果器状态回读**（`'Z' <n>` ⇒ 6 字节 ASCII 帧）
    //
    //  ── ⭐⭐ 回传帧格式（⭐ 本节【唯一】口径，⛔ 不许自创，⛔ 不许改）
    //  ```
    //   'Z' 'z' <n> <hi> <lo> '\n'
    //   ↑   ↑   ↑    ↑     ↑     ↑
    //   │   │   │    │     │     └─ 0x0A（LF，行结束）
    //   │   │   │    │     └─────── 16 位值的低字节（ASCII hex，'0'..'9'/'A'..'F'）
    //   │   │   │    └───────────── 16 位值的高字节（ASCII hex）
    //   │   │   └────────────────── 子命令号 ASCII '0'..'7'
    //   │   └────────────────────── 内容起始标记（小写 'z' = 效果器状态）
    //   └────────────────────────── 帧类型（大写 'Z' = 效果器状态回读，与命令同字母 ✅）
    //  ```
    //  ⭐ **总长 6 字节**（⭐ ASCII 一行 ⇒ ⭐ 串口助手直接可读 ✅）
    //
    //  ⭐⭐ **为什么用 ASCII 而不是二进制**（⭐ 与 `top.v` 的 `ep_*` 同理由 ✅）：
    //     · ⭐ 串口助手直接看得到一个**人类可读的一行**（⭐ 例 `Zz102 3` = "子命令 1、clip=0x0233" ✅）
    //     · ⭐ 与既有回包同风格（⭐ `'P'` 回 `P12345`、⭐ `'V'`/`'N'` 回 ASCII ✅）
    //     · ⭐ **不占用 `0xA5` 帧** ⇒ ⭐ 曲谱链路零影响 ✅
    //
    //  ── ⭐ 子命令表（⭐ `fxstat_sub_i` ⇒ 回读哪一项）
    //  | n | 回读量 | 来源 | 宽度 | 编码 |
    //  |---|---|---|---|---|
    //  | 0 | `en_mask` | `fx_en_mask_i` | 8 bit | 2 位 hex |
    //  | 1 | `dist_clip_cnt` | `fx_dist_clip_i` | 16 bit | 4 位 hex |
    //  | 2 | `dly_active` | `fx_dly_active_i` | 1 bit | `00`/`01` |
    //  | 3 | `chor_active` / `dly_primed` | `{fx_chor_active_i, fx_dly_primed_i}` | 2 bit | `00`..`03` |
    //  | 4 | `trem_lfo` | `fx_trem_lfo_i` | 16 bit | 4 位 hex |
    //  | 5 | `pipe` | `fx_pipe_i` | 16 bit | 4 位 hex |
    //  | 6/7 | 预留 | — | — | ⭐ 恒回 `0000`（⭐ ⛔ 不静默：⭐ 发得出、看得出 ✅）|
    //
    //  ⚠️ **`n=3` 是"两项挤一个子命令号"**（⭐ 任务原文就要求 `'Z' 3` 同时回这两项 ✅）
    //     ⭐ 编码：⭐ bit1 = chorus_active · bit0 = dly_primed（⭐ 高位在前 ✅）
    //
    //  🔴 **为什么必须逐字节排队**（⛔ 不是"一帧一次推完"）：
    //     ⚠️ `u_tx_fifo.push_i` 一次只能推**一个字节**（⭐ 它的契约 ✅）
    //        ⭐ 而 FIFO 深度只有 8 ⇒ 🔴 若一拍推 6 个字节会**溢出丢弃**（⭐`K-106` ✅）
    //     ⚠️ **去抖/合帧**：⭐ 若上一次还没发完又来一次 `'Z'` ⇒ ⭐ **保留最新一次**
    //        （⭐ 因为诊断只关心**当前状态**，历史无意义 ✅）
    //     ⚠️ **每拍最多只推一个字节** ⇒ ⛔ 不会溢出 FIFO ✅
    //
    //  ⭐ **零回归**：⭐ 没有 `'Z'` ⇒ `fx_tx_start_o` 恒 0 ⇒ ⭐ `top.v` 的 `tx_req`
    //     与**改动前逐位相同** ✅
    //
    //  ⚠️ **一个 reg 只能在一个 always 块里赋值**（⭐ `EX2000`/`EX1999` ✅）
    //     ⇒ ⭐ 本节的 `zfs_*` 全部只在下面那**一个** always 里写 ✅
    //  ⚠️ **拼接 `{}` 会把表达式拉成无符号**（⭐ 本项目 10-17 实测把 −2 零扩展成 8190 ✅）
    //     ⇒ ⭐ 本节的取值全是**无符号**位宽（⭐ 掩码/计数/LFO/拍数 ✅）⇒ ⛔ 不参与有符号运算 ✅
    // ═══════════════════════════════════════════════════════════════════════════

    // ── ① 状态编码（⭐ IDLE + 6 数据字节 = 7 个状态）────────────────────────
    localparam [2:0] ZFS_S_IDLE = 3'd0,   // ⭐ 空闲：等 `'Z' <n>`
                     ZFS_S_HDR1 = 3'd1,   // ⭐ 'Z'
                     ZFS_S_HDR2 = 3'd2,   // ⭐ 'z'
                     ZFS_S_N    = 3'd3,   // ⭐ <n>
                     ZFS_S_HI   = 3'd4,   // ⭐ <hi>
                     ZFS_S_LO   = 3'd5,   // ⭐ <lo>
                     ZFS_S_LF   = 3'd6;   // ⭐ LF

    reg [2:0]  zfs_state;
    reg        zfs_req_q;      // ⭐ "有一帧待发/在发"（⭐ 起帧置位、LF 发完清零 ✅）
    reg        zfs_pend_q;     // ⭐ **挂起位**：⭐ 发上一帧期间又来一次 `'Z'` ✅
    reg [2:0]  zfs_sub_q;      // ⭐ 帧里的子命令号（⭐ 锁存 ⇒ **时序解耦** ✅）
    reg [15:0] zfs_val_q;      // ⭐ 帧里的 16 位值（⭐ **事件那一拍**就锁存 ✅）

    // ── ② 取哪一项（⭐ 组合，⭐ 在**脉冲那一拍**求值）
    //   ⚠️ **必须组合、⛔ 不能等下一拍** —— ⭐ `dist_clip_cnt` 这类**会变**
    //      （⭐ 判据②就是"驱动削波样本 ⇒ 回读值必须增加" ⇒ ⚠️ 若延后取样会读到旧值 ✅）
    //   📌 **宽度纪律**：⭐ 每一项都写成**定宽 localparam/pin**（⛔ 不靠隐式截断 ✅）
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

    // ── ③ 字节内容（⭐ 组合，⭐ 与 `zfs_state` 严格同拍 ✅）
    //   ⚠️ **hex nibble → ASCII**：⭐ `4'h0..4'h9` ⇒ `+8'h30`；
    //      ⭐ `4'hA..4'hF` ⇒ `+8'h37`（⭐ 即 `+('A'−10)` ✅）
    //   📌 **为什么不用 `$sformatf`/`%h`**：⭐ 综合器不支持（⭐ 只对仿真有效 ✅）
    //      ⇒ ⭐ 用一条"加 0x30 / 0x37"的算术（⭐ 8 位加，⛔ 无溢出 ✅）
    function [7:0] hex2asc;
        input [3:0] h;
        begin
            hex2asc = (h < 4'd10) ? ({4'd0, h} + 8'h30)
                                  : ({4'd0, h} + 8'h37);
        end
    endfunction

    reg [7:0] zfs_data_c;
    always @(*) begin
        case (zfs_state)
            ZFS_S_HDR1: zfs_data_c = 8'h5A;                        // ⭐ 'Z'
            ZFS_S_HDR2: zfs_data_c = 8'h7A;                        // ⭐ 'z'
            ZFS_S_N:    zfs_data_c = {5'd0, zfs_sub_q} + 8'h30;    // ⭐ '0'..'7'
            ZFS_S_HI:   zfs_data_c = hex2asc(zfs_val_q[15:12]);    // ⭐ 高位 nibble
            ZFS_S_LO:   zfs_data_c = hex2asc(zfs_val_q[7:4]);      // ⭐ 次高 nibble
            ZFS_S_LF:   zfs_data_c = 8'h0A;                        // ⭐ LF
            default:    zfs_data_c = 8'h00;                        // IDLE ⇒ ⛔ 不会推
        endcase
    end

    //  ⚠️ **帧只有 5 个有意义的数据字节 + LF** ⇒ ⭐ `zfs_val_q[3:0]` **被丢弃**
    //     （⭐ 如实标注：⭐ `dist_clip_cnt` 的**低 4 位看不到**）
    //     📌 **为什么不做 8 位 hex**：⭐ 那要 8 个数据字节 ⇒ ⭐ 一次回读 9 字节
    //        ⚠️ 而 `u_tx_fifo` 深度只有 **8** ⇒ 🔴 排队期间再来一条命令就溢出 ✅
    //     ⭐ **取舍**：⭐ 诊断要看的是"**有没有在涨 / 是不是 0**"，
    //        ⚠️ 低 4 位的精度对"生没生效"这个问题**没有信息量**（✅ 理由充分）

    // ── ④ 时序（⭐ 唯一写 `zfs_*` 的 always 块 ✅）
    //   ⚠️ `fx_tx_start_o`/`fx_tx_data_o` 是 **`output reg`**（⭐ 端口声明处定的 ✅）
    //      ⇒ ⭐ 必须在这个 always 里赋值（⛔ 不能再写 `assign` ✅）
    //      📌 **好处**：⭐ 脉冲与数据**天然同拍**（⭐ `u_tx_fifo` 当拍即存 ✅）
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            zfs_state     <= ZFS_S_IDLE;
            zfs_req_q     <= 1'b0;
            zfs_pend_q    <= 1'b0;
            zfs_sub_q     <= 3'd0;
            zfs_val_q     <= 16'd0;
            fx_tx_start_o <= 1'b0;
            fx_tx_data_o  <= 8'd0;
            zfs_req_cnt_o  <= 16'd0;
            zfs_drop_cnt_o <= 16'd0;
        end else begin
            // ⭐ 默认：脉冲输出每拍清零 ⇒ 严格单周期
            fx_tx_start_o <= 1'b0;

            // ══ ⭐ 计数器（`K-106`）══════════════════════════════════════
            //  ⚠️ 计数与状态机**写在同一个 always**（⛔ 不另起一个 —— `EX2000` ✅）
            if (fxstat_req_i) begin
                zfs_req_cnt_o <= sat_inc16(zfs_req_cnt_o);
                // ⭐ 挂起 = "请求来了但上一帧还没发完"（⭐ 会丢一次**即时**性 ✅）
                if (zfs_req_q && (zfs_state != ZFS_S_IDLE))
                    zfs_drop_cnt_o <= sat_inc16(zfs_drop_cnt_o);
            end

            case (zfs_state)
                // ── 空闲：等 `'Z' <n>` ────────────────────────────────────
                ZFS_S_IDLE: begin
                    // ⭐ **只在 `!zfs_req_q` 时起帧**
                    //   ⚠️ 正在发（`zfs_req_q==1`）时来的 `'Z'` 只置 `zfs_pend_q`
                    //      ⇒ ⭐ **⛔ 不打断当前帧**（⭐ 否则帧会被拆花 ✅）
                    if (!zfs_req_q && fxstat_req_i) begin
                        zfs_req_q  <= 1'b1;
                        zfs_pend_q <= 1'b0;
                        // ⭐ **在脉冲那一拍就锁存**（⭐ 组合值只在这一拍有效 ✅）
                        zfs_sub_q  <= fxstat_sub_i;
                        zfs_val_q  <= zfs_val_c;
                        zfs_state  <= ZFS_S_HDR1;
                    end
                end
                ZFS_S_HDR1: begin fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c; zfs_state <= ZFS_S_HDR2; end
                ZFS_S_HDR2: begin fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c; zfs_state <= ZFS_S_N;    end
                ZFS_S_N:    begin fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c; zfs_state <= ZFS_S_HI;   end
                ZFS_S_HI:   begin fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c; zfs_state <= ZFS_S_LO;   end
                ZFS_S_LO:   begin fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c; zfs_state <= ZFS_S_LF;   end
                ZFS_S_LF:   begin
                    fx_tx_start_o <= 1'b1; fx_tx_data_o <= zfs_data_c;
                    // ⭐ LF 是最后一个字节 ⇒ 本拍之后帧就发完了
                    if (zfs_pend_q) begin
                        // ⭐ 发送期间又来了一次 `'Z'` ⇒ **立刻发下一帧**
                        //   ⚠️ **内容用最新的锁存值**（⭐ `zfs_sub_q`/`zfs_val_q` 已被更新 ✅）
                        zfs_pend_q <= 1'b0;
                        zfs_req_q  <= 1'b1;         // ⭐ 保持"在发"
                        zfs_state  <= ZFS_S_HDR1;
                    end else begin
                        zfs_req_q  <= 1'b0;         // ⭐ 本帧发完
                        zfs_state  <= ZFS_S_IDLE;
                    end
                end
                default: zfs_state <= ZFS_S_IDLE;
            endcase

            // ══ ⭐ 挂起位（⭐ 与状态机【分开写】，⛔ 不混在 case 里 ✅）═══
            //   ⚠️ **为什么必须独立**：⭐ `zfs_pend_q` 要在**每一个**非 IDLE 状态
            //      都被置位（⛔ 不能只在某一个状态里置）⇒ ⭐ 写在 case 外面最安全 ✅
            if (fxstat_req_i && (zfs_state != ZFS_S_IDLE)) zfs_pend_q <= 1'b1;
            //   ⚠️ **IDLE 且 `zfs_req_q==0`** 的情况 ⇒ ⭐ 由上面 IDLE 分支直接起帧，
            //      ⭐ **不需要** `zfs_pend_q`（⛔ 否则会多发一帧 ✅）
        end
    end

    // ═══════════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-28：⭐ **状态回显推送 FSM**（规格 `FPGA侧串口屏UI规划` §五-1 / §二 2.2）
    //
    //  ── 它解决什么 ───────────────────────────────────────────────────────────
    //   ⭐ 串口屏是「主控制面」，但**只下行**（屏→FPGA）。屏上 Page 0 的
    //      **22 个状态控件**（`t_mode`/`t_bpm`/…/`z_vd`）需要 FPGA 在**上电握手后**、
    //      以及**每次状态变化后**回写，否则屏上显示与 FPGA 实际状态**脱节**。
    //   ⭐ 本 FSM 复用**早已预留、但一直「死着」**的 `tx_start_o`/`tx_data_o`
    //      （⭐ `top.v` 当前把它们接成 `ui_tx_start`/`ui_tx_data` 但**无消费者** ✅，
    //        ⚠️ 接入 tx 仲裁是**下一步**（规格 §五-1「复用 uart_tx.v」）✅）。
    //
    //  ── 触发时机（⭐ 全部是可观测的**状态变化**）──────────────────────────────
    //   ① 0x88 握手（`hb_ready_o` 0→1）⇒ ⭐ 回写**全部 47 个字段**（屏上电初态）
    //      ⭐ 握手**前**的变化 ⛔ 不发帧（⭐ 由握手沿一次性补发 ⇒ 屏没就绪发了也白发）
    //      ⭐⭐ 2026-10-29 三件套-A：⭐ **每次收到 0x88 都全量重发**（⭐ `reflash_q`）——
    //         屏切页返回时发 `88` ⇒ 再拿 47 帧最新值（⭐ 修"切页陈旧值"）✅
    //   ② 任一字段值变化（⭐ 握手后）⇒ 置对应待发位，IDLE 按**字段号从小到大**发帧
    //   📌 `t1` 是旧控件（Test Mode 档位）⭐ 保留一列，其余 21 个 = Page 0 新控件
    //
    //  ── 回写内容（⭐ UTF-8 字节，严格按《USART-HMI搭建清单-Page0-20261028.md》）──
    //   | # | 控件 | 内容（body） | 帧 |
    //   |---|---|---|---|
    //   | 0 | t_mode   | 指板模式 [FRET] / 钢琴模式 [PIANO] | txt |
    //   | 1 | t1       | 关 / 4 / 8 / 16 / 32（⭐ 旧控件） | txt |
    //   | 2 | t_base   | 基准音: C4 (最低音 C3) | txt |
    //   | 3 | t_timbre | BASS / GUITAR / PIANO / PAD | txt |
    //   | 4 | t_trans  | 0 SEMI (原调) / +N SEMI / −N SEMI | txt |
    //   | 5 | t_slide  | 开启 (GLIDE ON) / 关闭 (GLIDE OFF) | txt |
    //   | 6 | t_bpm    | 120（⭐ 十进制巨字，无前导零） | txt |
    //   | 7 | t_drum   | 开 II [PATTERN II] | txt |
    //   | 8 | t_loop   | 空闲 / ● 循环录音中 REC / ► 循环回放中 PLAY / 武装中 | txt |
    //   | 9 | t_kd     | 键盘打鼓: 关闭 [音符演奏] / 开启 [键位打鼓] | txt |
    //   | 10| t_vol    | 主音量: 85% | txt |
    //   | 11| t_pedal  | [PEDAL 延音踏板: 踩下使能] / …松开] | txt |
    //   | 12| t_gear   | 推子控制: 档 1 [音高颤音] | txt |
    //   | 13| t_hdmi   | HDMI: 实时示波器 (波形显示/李萨如图/频谱) | txt |
    //   | 14| t_pd     | 音高颤音: 25% | txt |
    //   | 15| t_vd     | 音量颤音: 60% | txt |
    //   | 16-18 | t_dist_st / t_chor_st / t_dly_st | 失真 [关] / 合唱 [开] / 延迟 [开] | txt |
    //   | 19| j_vol    | 主音量数值 0..100 | val |
    //   | 20| z_pd     | 音高颤音仪表值 0..100 | val |
    //   | 21| z_vd     | 音量颤音仪表值 0..100 | val |
    //   ⚠️ 每帧以 `FF FF FF` 结尾（⭐ TJC 命令约定，与屏→FPGA 方向对称 ✅）
    //
    //  ── ⭐⭐ 2026-10-29 晚：§八 收口新增 25 字段（23..47）───────────────────
    //   | 23/24 | t_loop（.bco=/.pco=）| 三态配色：空闲 63455/9509 · 录音 52517/65535
    //   |       |                    | 回放 6822/65535 · 武装 55264/65535（RGB565 十进制）|
    //   | 25-27 | led_dist/led_chor/led_dly（.val=0/1）| 效果器状态灯（fx_mask 同源、屏侧双态按钮）|
    //   | 28-35 | z_dg/z_dt/z_cl/z_mx/z_ll/z_lf/z_pr/z_vr（.val=0..99）| page1 仪表
    //   |       | （⭐ 满量程**百分比**统一口径：16bit→v[15:8]、14bit→v[13:6]、
    //   |       |   11bit→v[10:3]、8bit→v，再 ×100>>8；⭐ z_pr/z_vr 同源 fx_rate）|
    //   | 36-45 | t_dg_val..t_vr_val（txt `NN%`）| page1 数值文本（与仪表同源） |
    //   | 46 | cur | `EC11: <参数名> (0x1N)`（N=par_sel 0..7 ↔ 变量 0x11..0x18）| txt |
    //   | 47 | gr  | `档 N [label]`（与 t_gear 同源短版）| txt |
    //   ⚠️ 每帧同样以 `FF FF FF` 结尾；⭐ 全量 47 帧 ≈ 1141 字节 ≈ 99ms@115200（切页可接受）
    //
    //  ── ⭐ 为什么用「镜像寄存器 + 变化检测」而不是「提交脉冲触发」──────────
    //   ⭐ 本模块有 `mode_commit_o`/`test_mode_commit_o`/`base_commit_o` 三个脉冲
    //      本可直接当触发源，⚠️ 但：
    //        · ⭐ 脉冲与 `mode_o` 等**同一拍更新**（非阻塞），⭐ 直接读会拿到旧值；
    //        · ⭐ `mode_sw_req_i`（外部模式翻转）也发 `mode_commit_o`，⭐ 与屏触摸**同源**；
    //        · 🔴 用脉冲**无法区分「哪个寄存器变了」**，还得再比一次。
    //      ⇒ ⭐ 干脆**只盯寄存器值**：⭐ 无论变化来自屏触摸、数值帧还是外部按键，
    //        只要 `mode_o`/`test_mode_o`/`base_semi_o` 的值变了就回显 ✅
    //        （⭐ 这也**天然覆盖**握手后的初始状态 —— 上电时寄存器就是初值 ✅）
    //
    //  ── ⭐ 握手约定（⭐ 流控，⛔ 与 ZFS 回读的"盲推"不同）───────────────────
    //   ⭐ 每拍最多推**一个字节**（`tx_start_o` 单周期脉冲 + `tx_data_o` 同拍数据）。
    //   ⭐ **看 `tx_busy_i`**：⭐ busy（下游队列满 / 串行线在发）时**原地等待**，
    //      ⛔ 不推、不推进 —— 🔴 因为回显帧最长 52 字节（t_hdmi 波形档：
    //      6+6+36+1+3），而 `u_tx_fifo` 深度只有 8，
    //      ⚠️ 若盲推（像 `fx_tx` 那样）会**溢出丢字节**（⭐ `fx_tx` 的 `'Z'` 帧 6 字节 < 8 才敢盲推 ✅）
    //   📌 `top.v` 把 `tx_busy_i` 接 `~txf_ready`（队列满 = 忙）⇒ 自动背压 ✅
    //
    //  ── 零回归 ───────────────────────────────────────────────────────────────
    //   ⭐ 握手前 / 无状态变化时 ⇒ `tx_start_o` 恒 0 ⇒ 与改动前**逐位相同** ✅
    //   ⭐ 复位时把镜像寄存器初始化为**与复位值一致** ⇒ ⛔ 上电不产生伪回显 ✅
    //
    //  ── ⛔ 纪律 ───────────────────────────────────────────────────────────────
    //   ⭐ `tx_start_o`/`tx_data_o` 是 `output reg`，⭐ **只能在一个 always 里赋值**
    //      ⇒ ⭐ 已从上方「主状态机」里**移除**它们的赋值，⭐ 全部改由本节接管 ✅
    // ═══════════════════════════════════════════════════════════════════════════

    // ── ① 状态 / 字段编码 ────────────────────────────────────────────────────
    localparam [1:0] ECH_S_IDLE = 2'd0,
                     ECH_S_EMIT = 2'd1;
    //  ⭐⭐ 2026-10-29：状态字段 **0..21**（⭐ 与 `ech_pend` 一位一字段对齐）
    //     ⭐ 2026-10-29 晚：**再加 22 = 心跳**（⭐ 不是屏状态字段：⭐ 由【计时器】
    //        而非变化检测置位 —— ⭐ 周期发 `tm1.tim=1500` 喂屏侧看门狗、断联闪烁 ✅）
    //     ⭐⭐ 2026-10-29 晚：**再加 23..47 = §八 收口 25 字段**（⭐ 三态配色 2 +
    //        状态灯 3 + page1 动态 20；⭐ 全部排在心跳之后 = 展板类最低优先）✅
    //   📌 编码顺序 = IDLE 发送优先级（⭐ 字段号小的先发 ⇒ 演奏核心类最优先）✅
    localparam [5:0] ECH_F_MODE = 6'd0,   // t_mode（指板模式 [FRET] / 钢琴模式 [PIANO]）
                     ECH_F_TEST = 6'd1,   // t1（Test Mode 档位，⭐ 旧控件保留）
                     ECH_F_BASE = 6'd2,   // t_base（基准音: C4 (最低音 C3)）
                     ECH_F_TIMB = 6'd3,   // t_timbre（BASS/GUITAR/PIANO/PAD）
                     ECH_F_TRAN = 6'd4,   // t_trans（0 SEMI (原调) / ±N SEMI）
                     ECH_F_SLIDE= 6'd5,   // t_slide（开启 (GLIDE ON) / 关闭 (GLIDE OFF)）
                     ECH_F_BPM  = 6'd6,   // t_bpm（十进制巨字，无前导零）
                     ECH_F_DRUM = 6'd7,   // t_drum（Pattern I..IV / 关，⭐ 2026-10-31 新文案）
                     ECH_F_LOOP = 6'd8,   // t_loop（空闲/● 循环录音中 REC/► 循环回放中 PLAY/武装中）
                     ECH_F_KD   = 6'd9,   // t_kd（打鼓: 开/关 [键位打鼓/音符演奏]）
                     ECH_F_VOL  = 6'd10,  // t_vol（主音量: NN%）
                     ECH_F_PEDAL= 6'd11,  // t_pedal（[PEDAL 延音踏板: …]）
                     ECH_F_GEAR = 6'd12,  // t_gear（推子控制: 档 N [label]）
                     ECH_F_HDMI = 6'd13,  // t_hdmi（HDMI: 实时示波器 (…)）
                     ECH_F_PD   = 6'd14,  // t_pd（深度 NN%，⭐ 2026-10-31 双仓新文案）
                     ECH_F_VD   = 6'd15,  // t_vd（深度 NN%）
                     ECH_F_DIST = 6'd16,  // t_dist_st（失真 [开/关]）
                     ECH_F_CHOR = 6'd17,  // t_chor_st（合唱 [开/关]）
                     ECH_F_DLY  = 6'd18,  // t_dly_st（延迟 [开/关]）
                     ECH_F_JVOL = 6'd19,  // j_vol.val（主音量数值）
                     ECH_F_ZPD  = 6'd20,  // z_pd.val（音高颤音仪表值）
                     ECH_F_ZVD  = 6'd21,  // z_vd.val（音量颤音仪表值）
                     ECH_F_HB   = 6'd22,  // tm1.tim=1500（⭐ 心跳帧、喂屏看门狗）
                     // ── ⭐⭐ 2026-10-29 晚：§八 收口 25 字段 ──────────────────
                     ECH_F_LOOPBCO = 6'd23,  // t_loop.bco（三态背景色，⭐ §八-2）
                     ECH_F_LOOPPCO = 6'd24,  // t_loop.pco（三态前景色）
                     ECH_F_LEDD    = 6'd25,  // led_dist.val（失真灯，⭐ §八-4）
                     ECH_F_LEDC    = 6'd26,  // led_chor.val（合唱灯）
                     ECH_F_LEDDLY  = 6'd27,  // led_dly.val（延迟灯）
                     ECH_F_ZDG     = 6'd28,  // z_dg.val（失真增益仪表，⭐ §八-3）
                     ECH_F_ZDT     = 6'd29,  // z_dt.val（失真补偿仪表）
                     ECH_F_ZCL     = 6'd30,  // z_cl.val（合唱长度仪表）
                     ECH_F_ZMX     = 6'd31,  // z_mx.val（干湿比仪表）
                     ECH_F_ZLL     = 6'd32,  // z_ll.val（延迟长度仪表）
                     ECH_F_ZLF     = 6'd33,  // z_lf.val（延迟反馈仪表）
                     ECH_F_ZPR     = 6'd34,  // z_pr.val（音高颤音速率仪表）
                     ECH_F_ZVR     = 6'd35,  // z_vr.val（音量颤音速率仪表）
                     ECH_F_TDG     = 6'd36,  // t_dg_val（"NN%" 数值文本）
                     ECH_F_TDT     = 6'd37,  // t_dt_val
                     ECH_F_TCL     = 6'd38,  // t_cl_val
                     ECH_F_TMX     = 6'd39,  // t_mx_val
                     ECH_F_TLL     = 6'd40,  // t_ll_val
                     ECH_F_TLF     = 6'd41,  // t_lf_val
                     ECH_F_TPDV    = 6'd42,  // t_pd_val（音高颤音深度文本）
                     ECH_F_TVDV    = 6'd43,  // t_vd_val（音量颤音深度文本）
                     ECH_F_TPR     = 6'd44,  // t_pr_val（速率文本）
                     ECH_F_TVR     = 6'd45,  // t_vr_val（速率文本）
                     ECH_F_CUR     = 6'd46,  // cur（EC11 锁定参数文本）
                     ECH_F_GR      = 6'd47,  // gr（推子档短文本）
                     // ── ⭐⭐ 2026-10-31：《控件位置清单》落地：状态灯 2 + 卡片 B 1 + 卡片 D 6 ──
                     ECH_F_PSLIDE  = 6'd48,  // p_slide.val（滑音状态灯：绿点 0/1，⭐ 与 t_slide 同源）
                     ECH_F_PBEAT   = 6'd49,  // p_bpm.val（节拍状态灯：橙点随 beat_i 翻转）
                     ECH_F_UPL     = 6'd50,  // b_uplink.txt（● 实时上行: 开启/关闭）
                     ECH_F_PRATE   = 6'd51,  // t_pr.txt（速率 N.NHz，音高颤音仓）
                     ECH_F_VRATE   = 6'd52,  // t_vr.txt（速率 N.NHz，音量颤音仓）
                     ECH_F_JPR     = 6'd53,  // j_pr.val（音高颤音速率进度条）
                     ECH_F_JVR     = 6'd54,  // j_vr.val（音量颤音速率进度条）
                     ECH_F_JPD     = 6'd55,  // j_pd.val（音高颤音深度进度条）
                     ECH_F_JVD     = 6'd56,  // j_vd.val（音量颤音深度进度条）
                     // ⭐⭐ 2026-11-01 队友新增 3 字段（色帧 + 锁定）
                     ECH_F_DRUMBCO = 6'd57,  // t_drum.bco（鼓机开启=蓝背景）
                     ECH_F_PEDALBCO= 6'd58,  // t_pedal.bco（踩下=红背景）
                     ECH_F_LOCK    = 6'd59;  // t_lock.txt（推子锁定状态）

    reg [1:0]  ech_state;
    reg [5:0]  ech_pos;        // ⭐ 帧内字节位置（最长帧 52B ⇒ 6 位够）
    reg [59:0] ech_pend;       // ⭐ 每字段一位（0..59）待发标志（⭐ IDLE 按低位优先发）
    reg [5:0]  ech_nxt_c;      // ⭐ IDLE 组合选出：`ech_pend` 的最低置位位
    // ── 起帧那拍锁存的「帧快照」（⭐ 发送期间输入再变也 ⛔ 不影响本帧）──────────
    reg [71:0] ech_name_q;     // ⭐ 控件名（≤9B，⭐ **右对齐**：低字节 = 末字符）
    reg [3:0]  ech_nlen_q;     // ⭐ 名字长度（2..9）
    reg [5:0]  ech_blen_q;     // ⭐ body 长度（0..36）
    reg        ech_isval_q;    // ⭐ 1 = `.val=` 帧（数值帧、无收尾引号）
    reg        ech_istim_q;    // ⭐ 1 = `.tim=` 帧（⭐ 心跳专用、无收尾引号）
    //  ⭐⭐ 2026-10-29 晚（§八-2）：`.bco=`/`.pco=` 色帧（⭐ 与 .val= 同为 5B infix）
    reg        ech_isbco_q;    // ⭐ 1 = `.bco=` 帧（背景色，t_loop 三态配色）
    reg        ech_ispco_q;    // ⭐ 1 = `.pco=` 帧（前景色）
    //  ⭐⭐ 2026-10-29：⭐ 心跳节拍（⭐ 握手后才开始计 ⇒ 上电不发）
    localparam integer HB_CLKS_I = (CLK_HZ/1000)*HB_MS;   // ⭐ 周期（clk 数）
    reg  [31:0] hb_tmr_q;      // ⭐ 32 位（⭐ 50MHz×1s=5e7 < 2^31 ✅）
    reg [7:0]  ech_body_q [0:35];  // ⭐ body 字节缓冲（**左对齐数组**：[0]=首字节）
    // ── 镜像寄存器（⭐ 变化检测基准；⭐ 复位值 = 各信号复位值 ⇒ 上电无伪帧）─────
    reg        ech_hb_s;       // ⭐ `hb_ready_o` 的镜像（抓 0→1 上升沿）
    //  ⭐⭐ 2026-10-29 三件套-A：⭐ **重发请求**（0x88 每次收到都全量重发）✅
    //     🔴 **为什么**：⭐ 原 `!ech_hb_s` 只在**首次**握手沿触发 ⇒ 屏切页回来
    //        发 `88` 时 hb_ready 早已为 1、**无沿** ⇒ 🔴 **一个字节都不回** ✗
    //        ⇒ 屏上显示**陈旧值**（⭐ 切页期间 page0 更新帧全被屏丢弃）✗
    //     ✅ **修法**：⭐ 收到 0x88（⭐ 含重复收到）置一拍 `reflash_q` ⇒
    //        回显块看到 `reflash_q` ⇒ **与首次握手同款**：47 字段全置位 + 同步镜像 ✅
    reg        reflash_q;      // ⭐ 0x88 重发请求（单拍标志，回显块自清）
    reg        ech_mode_s;
    reg        ech_test_s;
    reg [1:0]  ech_testn_s;
    reg [6:0]  ech_base_s;
    reg [1:0]  ech_timbre_s;
    reg [4:0]  ech_trans_s;
    reg        ech_slide_s;
    reg [7:0]  ech_bpm_s;
    reg [2:0]  ech_drum_s;     // ⭐ 2026-10-31：{on, pattern} 3 位镜像
    reg [1:0]  ech_loop_s;
    reg        ech_kd_s;
    reg [6:0]  ech_vol_s;
    reg        ech_pedal_s;
    reg [1:0]  ech_gear_s;
    reg [1:0]  ech_scope_s;
    reg [6:0]  ech_pvib_s;
    reg [6:0]  ech_vvib_s;
    reg [2:0]  ech_fxmask_s;
    //  ⭐⭐ 2026-10-29 晚（§八-3）：page1 动态字段镜像（⭐ 同样只盯值、来源无关）
    reg [15:0] ech_fxg_s;      // fx_gain_o 镜像（z_dg / t_dg_val 数据源）
    reg [15:0] ech_fxt_s;      // fx_trim_o 镜像（z_dt / t_dt_val）
    reg [7:0]  ech_mix_s;      // fx_mix_o 镜像（z_mx / t_mx_val）
    reg [7:0]  ech_fb_s;       // fx_fb_o 镜像（z_lf / t_lf_val）
    reg [7:0]  ech_rate_s;     // fx_rate_o 镜像（z_pr/z_vr/t_pr_val/t_vr_val 四同源）
    reg [13:0] ech_dl_s;       // fx_dlylen_o 镜像（z_ll / t_ll_val）
    reg [10:0] ech_cl_s;       // fx_chorlen_o 镜像（z_cl / t_cl_val）
    reg [2:0]  ech_parsel_s;   // par_sel_c 镜像（cur 文本）
    //  ⭐⭐ 2026-10-31：《控件位置清单》新字段镜像
    reg        ech_uplink_s;   // uplink_sw_o 镜像（触摸翻转 → UPL 帧）
    reg        ech_beat_s;     // beat_c 电平镜像（抓上升沿）
    reg        beat_dot_s;     // p_bpm.val 显示值（每拍翻转 0/1）
    reg [11:0] ech_prate_s;    // st_prate_c 镜像（t_pr + j_pr 双挂起）
    reg [7:0]  ech_vrate_s;    // st_vrate_c 镜像（t_vr + j_vr 双挂起）
    reg        ech_lock_s;     // st_lock_c 镜像（t_lock）
    reg [5:0]  ech_nactive_s;  // st_nactive_c 镜像（t1 复音数）

    // ── ①b 待发字段选择（⭐ 组合：`ech_pend` 最低置位位）────────────────────
    //   ⚠️ **必须与 IDLE 的选字段/清位完全一致** ⇒ ⭐ 双方共用 `ech_nxt_c` ✅
    //   📌 `ech_pend` 全 0 时 IDLE 不会起帧 ⇒ `ech_nxt_c` 的值无害 ✅
    always @(*) begin
        if      (ech_pend[ 0]) ech_nxt_c = ECH_F_MODE;
        else if (ech_pend[ 1]) ech_nxt_c = ECH_F_TEST;
        else if (ech_pend[ 2]) ech_nxt_c = ECH_F_BASE;
        else if (ech_pend[ 3]) ech_nxt_c = ECH_F_TIMB;
        else if (ech_pend[ 4]) ech_nxt_c = ECH_F_TRAN;
        else if (ech_pend[ 5]) ech_nxt_c = ECH_F_SLIDE;
        else if (ech_pend[ 6]) ech_nxt_c = ECH_F_BPM;
        else if (ech_pend[ 7]) ech_nxt_c = ECH_F_DRUM;
        else if (ech_pend[ 8]) ech_nxt_c = ECH_F_LOOP;
        else if (ech_pend[ 9]) ech_nxt_c = ECH_F_KD;
        else if (ech_pend[10]) ech_nxt_c = ECH_F_VOL;
        else if (ech_pend[11]) ech_nxt_c = ECH_F_PEDAL;
        else if (ech_pend[12]) ech_nxt_c = ECH_F_GEAR;
        else if (ech_pend[13]) ech_nxt_c = ECH_F_HDMI;
        else if (ech_pend[14]) ech_nxt_c = ECH_F_PD;
        else if (ech_pend[15]) ech_nxt_c = ECH_F_VD;
        else if (ech_pend[16]) ech_nxt_c = ECH_F_DIST;
        else if (ech_pend[17]) ech_nxt_c = ECH_F_CHOR;
        else if (ech_pend[18]) ech_nxt_c = ECH_F_DLY;
        else if (ech_pend[19]) ech_nxt_c = ECH_F_JVOL;
        else if (ech_pend[20]) ech_nxt_c = ECH_F_ZPD;
        else if (ech_pend[21]) ech_nxt_c = ECH_F_ZVD;
        //  ⭐ 心跳排【page0 状态字段之后、page1 展板字段之前】（⭐ 2026-10-29 晚）
        //    ⭐ page0 状态变化永远最优先；⭐ 47 帧全量 < 100ms << 1s 心跳周期 ⇒ 不会饿死；
        //    ⭐ page1 展板类（23..47）最低优先（⭐ 演奏核心类不因展板刷屏而排队）
        else if (ech_pend[22]) ech_nxt_c = ECH_F_HB;
        else if (ech_pend[23]) ech_nxt_c = ECH_F_LOOPBCO;
        else if (ech_pend[24]) ech_nxt_c = ECH_F_LOOPPCO;
        else if (ech_pend[25]) ech_nxt_c = ECH_F_LEDD;
        else if (ech_pend[26]) ech_nxt_c = ECH_F_LEDC;
        else if (ech_pend[27]) ech_nxt_c = ECH_F_LEDDLY;
        else if (ech_pend[28]) ech_nxt_c = ECH_F_ZDG;
        else if (ech_pend[29]) ech_nxt_c = ECH_F_ZDT;
        else if (ech_pend[30]) ech_nxt_c = ECH_F_ZCL;
        else if (ech_pend[31]) ech_nxt_c = ECH_F_ZMX;
        else if (ech_pend[32]) ech_nxt_c = ECH_F_ZLL;
        else if (ech_pend[33]) ech_nxt_c = ECH_F_ZLF;
        else if (ech_pend[34]) ech_nxt_c = ECH_F_ZPR;
        else if (ech_pend[35]) ech_nxt_c = ECH_F_ZVR;
        else if (ech_pend[36]) ech_nxt_c = ECH_F_TDG;
        else if (ech_pend[37]) ech_nxt_c = ECH_F_TDT;
        else if (ech_pend[38]) ech_nxt_c = ECH_F_TCL;
        else if (ech_pend[39]) ech_nxt_c = ECH_F_TMX;
        else if (ech_pend[40]) ech_nxt_c = ECH_F_TLL;
        else if (ech_pend[41]) ech_nxt_c = ECH_F_TLF;
        else if (ech_pend[42]) ech_nxt_c = ECH_F_TPDV;
        else if (ech_pend[43]) ech_nxt_c = ECH_F_TVDV;
        else if (ech_pend[44]) ech_nxt_c = ECH_F_TPR;
        else if (ech_pend[45]) ech_nxt_c = ECH_F_TVR;
        else if (ech_pend[46]) ech_nxt_c = ECH_F_CUR;
        else if (ech_pend[47]) ech_nxt_c = ECH_F_GR;
        // ── ⭐⭐ 2026-10-31：新 9 帧（⭐ 排队尾 = 展板类最低优先）─────────────────
        else if (ech_pend[48]) ech_nxt_c = ECH_F_PSLIDE;
        else if (ech_pend[49]) ech_nxt_c = ECH_F_PBEAT;
        else if (ech_pend[50]) ech_nxt_c = ECH_F_UPL;
        else if (ech_pend[51]) ech_nxt_c = ECH_F_PRATE;
        else if (ech_pend[52]) ech_nxt_c = ECH_F_VRATE;
        else if (ech_pend[53]) ech_nxt_c = ECH_F_JPR;
        else if (ech_pend[54]) ech_nxt_c = ECH_F_JVR;
        else if (ech_pend[55]) ech_nxt_c = ECH_F_JPD;
        else if (ech_pend[56]) ech_nxt_c = ECH_F_JVD;
        else if (ech_pend[57]) ech_nxt_c = ECH_F_DRUMBCO;
        else if (ech_pend[58]) ech_nxt_c = ECH_F_PEDALBCO;
        else if (ech_pend[59]) ech_nxt_c = ECH_F_LOCK;
        else                   ech_nxt_c = ECH_F_MODE;
    end

    // ── ①c 中文词表（UTF-8；⭐ Python 逐字节生成核对过 2026-10-29）─────────────
    //   📌 一律 **120 位右对齐**（低字节 = 末字）⇒ 可直接喂 `ech_push_str` ✅
    localparam [119:0] W_ZHIBAN_MOSHI   = {8'hE6,8'h8C,8'h87,8'hE6,8'h9D,8'hBF,8'hE6,8'hA8,8'hA1,8'hE5,8'hBC,8'h8F},  // 指板模式(12B)
                       W_GANGQIN_MOSHI  = {8'hE9,8'h92,8'hA2,8'hE7,8'h90,8'hB4,8'hE6,8'hA8,8'hA1,8'hE5,8'hBC,8'h8F},  // 钢琴模式(12B)
                       W_JIZHUNYIN      = {8'hE5,8'h9F,8'hBA,8'hE5,8'h87,8'h86,8'hE9,8'h9F,8'hB3},                     // 基准音(9B)
                       W_ZUIDIYIN       = {8'hE6,8'h9C,8'h80,8'hE4,8'hBD,8'h8E,8'hE9,8'h9F,8'hB3},                     // 最低音(9B)
                       W_YUANDIAO       = {8'hE5,8'h8E,8'h9F,8'hE8,8'hB0,8'h83},                                       // 原调(6B)
                       W_KAIQI          = {8'hE5,8'hBC,8'h80,8'hE5,8'h90,8'hAF},                                       // 开启(6B)
                       W_GUANBI         = {8'hE5,8'h85,8'hB3,8'hE9,8'h97,8'hAD},                                       // 关闭(6B)
                       W_KAI            = {8'hE5,8'hBC,8'h80},                                                          // 开(3B)
                       W_GUAN           = {8'hE5,8'h85,8'hB3},                                                          // 关(3B)
                       W_XUNHUAN_LUYIN  = {8'hE5,8'hBE,8'hAA,8'hE7,8'h8E,8'hAF,8'hE5,8'hBD,8'h95,8'hE9,8'h9F,8'hB3,8'hE4,8'hB8,8'hAD}, // 循环录音中(15B)
                       W_XUNHUAN_HUIFANG= {8'hE5,8'hBE,8'hAA,8'hE7,8'h8E,8'hAF,8'hE5,8'h9B,8'h9E,8'hE6,8'h94,8'hBE,8'hE4,8'hB8,8'hAD}, // 循环回放中(15B)
                       W_KONGXIAN       = {8'hE7,8'hA9,8'hBA,8'hE9,8'h97,8'hB2},                                       // 空闲(6B)
                       W_WUZHUANG       = {8'hE6,8'hAD,8'hA6,8'hE8,8'hA3,8'h85,8'hE4,8'hB8,8'hAD},                     // 武装中(9B)
                       W_JIANPAN_DAGU   = {8'hE9,8'h94,8'hAE,8'hE7,8'h9B,8'h98,8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93},    // 键盘打鼓(12B)
                       W_JIANWEI_DAGU   = {8'hE9,8'h94,8'hAE,8'hE4,8'hBD,8'h8D,8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93},    // 键位打鼓(12B)
                       W_YINFU_YANZOU   = {8'hE9,8'h9F,8'hB3,8'hE7,8'hAC,8'hA6,8'hE6,8'hBC,8'h94,8'hE5,8'hA5,8'h8F},    // 音符演奏(12B)
                       W_ZHU_YINLIANG   = {8'hE4,8'hB8,8'hBB,8'hE9,8'h9F,8'hB3,8'hE9,8'h87,8'h8F},                     // 主音量(9B)
                       W_YANYIN_TABAN   = {8'hE5,8'hBB,8'hB6,8'hE9,8'h9F,8'hB3,8'hE8,8'hB8,8'hA9,8'hE6,8'h9D,8'hBF},    // 延音踏板(12B)
                       W_YANYIN         = {8'hE5,8'hBB,8'hB6,8'hE9,8'h9F,8'hB3},                                       // 延音(6B) ⭐ 2026-11-01 队友改（原「[PEDAL 延音踏板: …]」）
                       W_CAIXIA_SHINENG = {8'hE8,8'hB8,8'hA9,8'hE4,8'hB8,8'h8B,8'hE4,8'hBD,8'hBF,8'hE8,8'h83,8'hBD},    // 踩下使能(12B)
                       W_SONGKAI        = {8'hE6,8'h9D,8'hBE,8'hE5,8'hBC,8'h80},                                       // 松开(6B)
                       W_TUIZI_KONGZHI  = {8'hE6,8'h8E,8'hA8,8'hE5,8'hAD,8'h90,8'hE6,8'h8E,8'hA7,8'hE5,8'h88,8'hB6},    // 推子控制(12B)
                       W_DANG           = {8'hE6,8'hA1,8'hA3},                                                          // 档(3B)
                       W_BIANDIAO       = {8'hE5,8'h8F,8'h98,8'hE8,8'hB0,8'h83},                                       // 变调(6B)
                       W_YINGAO_CHANYIN = {8'hE9,8'h9F,8'hB3,8'hE9,8'hAB,8'h98,8'hE9,8'hA2,8'hA4,8'hE9,8'h9F,8'hB3},  // 音高颤音(12B)
                       W_YINLIANG_CHANYIN = {8'hE9,8'h9F,8'hB3,8'hE9,8'h87,8'h8F,8'hE9,8'hA2,8'hA4,8'hE9,8'h9F,8'hB3}, // 音量颤音(12B)
                       W_WU             = {8'hE6,8'h97,8'hA0},                                                          // 无(3B)
                       W_SHISHI_SHIBOQI = {8'hE5,8'hAE,8'h9E,8'hE6,8'h97,8'hB6,8'hE7,8'hA4,8'hBA,8'hE6,8'hB3,8'hA2,8'hE5,8'h99,8'hA8}, // 实时示波器(15B)
                       W_BOXING_XIANSHI = {8'hE6,8'hB3,8'hA2,8'hE5,8'hBD,8'hA1,8'hE6,8'h98,8'hBE,8'hE7,8'hA4,8'hBA},    // 波形显示(12B)
                       W_LISA_RU        = {8'hE6,8'h9D,8'h8E,8'hE8,8'h90,8'hA8,8'hE5,8'hA6,8'h82,8'hE5,8'h9B,8'hBE},    // 李萨如图(12B)
                       W_LISARU         = {8'hE6,8'h9D,8'h8E,8'hE8,8'h90,8'hA8,8'hE5,8'hA6,8'h82},                     // 李萨如(9B) ⭐ 2026-11-01 队友改（去「图」）
                       W_SHIBO          = {8'hE7,8'hA4,8'hBA,8'hE6,8'hB3,8'hA2},                                       // 示波(6B) ⭐ 2026-11-01 队友改（原「波形显示」）
                       W_PINPU          = {8'hE9,8'hA2,8'h91,8'hE8,8'hB0,8'hB1},                                       // 频谱(6B)
                       W_SHIZHEN        = {8'hE5,8'hA4,8'hB1,8'hE7,8'h9C,8'h9F},                                       // 失真(6B)
                       W_HECHANG        = {8'hE5,8'h90,8'h88,8'hE5,8'h94,8'hB1},                                       // 合唱(6B)
                       W_YANCHI         = {8'hE5,8'hBB,8'hB6,8'hE8,8'hBF,8'h9F},                                       // 延迟(6B)
                       W_DOT            = {8'hE2,8'h97,8'h8F},                                                          // ●(3B)
                       W_PLAY           = {8'hE2,8'h96,8'hBA},                                                          // ►(3B) ⭐ 2026-10-30 回放态专用（终稿速查表对齐；⛔ 不用 ▶ U+25B6，字库② §7.2 集里是 ► U+25BA）
                       // ── ⭐⭐ 2026-10-29 晚（§八-3）：page1 参数名词表（UTF-8，Python 逐字节核对 ✅）──
                       W_ZENGYI         = {8'hE5,8'hA2,8'h9E,8'hE7,8'h9B,8'h8A},                                       // 增益(6B)
                       W_BUCHANG        = {8'hE8,8'hA1,8'hA5,8'hE5,8'h81,8'hBF},                                       // 补偿(6B)
                       W_HUNHE          = {8'hE6,8'hB7,8'hB7,8'hE5,8'h90,8'h88},                                       // 混合(6B)
                       W_FANKUI         = {8'hE5,8'h8F,8'h8D,8'hE9,8'hA6,8'h88},                                       // 反馈(6B)
                       W_SHENDU         = {8'hE6,8'hB7,8'hB1,8'hE5,8'hBA,8'hA6},                                       // 深度(6B)
                       W_SULU           = {8'hE9,8'h80,8'h9F,8'hE7,8'h8E,8'h87},                                       // 速率(6B)
                       W_YANCHI_CD      = {8'hE5,8'hBB,8'hB6,8'hE8,8'hBF,8'h9F,8'hE9,8'h95,8'hBF,8'hE5,8'hBA,8'hA6}, // 延迟长度(12B)
                       W_HECHANG_CD     = {8'hE5,8'h90,8'h88,8'hE5,8'h94,8'hB1,8'hE9,8'h95,8'hBF,8'hE5,8'hBA,8'hA6}, // 合唱长度(12B)
                       // ── ⭐⭐ 2026-10-31：卡片 B/D 新词（UTF-8 逐字节核对 ✅）──
                       W_DAGU           = {8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93},                                        // 打鼓(6B)
                       W_SHISHI_SHANGXING = {8'hE5,8'hAE,8'h9E,8'hE6,8'h97,8'hB6,8'hE4,8'hB8,8'h8A,8'hE8,8'hA1,8'h8C}, // 实时上行(12B)
                       // ── ⭐⭐ 2026-11-01 队友改：推子锁定状态词 ──
                       W_SUODING          = {8'hE9,8'h94,8'h81,8'hE5,8'hAE,8'h9A},                                       // 锁定(6B)
                       W_SHISHI_SHENGXIAO = {8'hE5,8'hAE,8'h9E,8'hE6,8'h97,8'hB6,8'hE7,8'h94,8'h9F,8'hE6,8'h95,8'h88}; // 实时生效(12B)
    // ── ⭐⭐ 2026-10-29 晚（§八-2）：t_loop 三态配色（⭐ 标准 RGB565；2026-11-01 修正错误色值）──
    //   🔴 2026-11-01 修正：原清单"RGB565"列是**错误换算**（如 52517 实际显示偏黄，队友反馈「循环录音改回红色」）。
    //      正确值 = 标准 RGB565（R>>3<<11 | G>>2<<5 | B>>3）：
    //      警戒红 #CF222E=51461 · 森林绿 #1A7F37=7142 · 琥珀金 #D97706=56224 · 深炭黑 #24292F=8517
    localparam [15:0] C_LPIDLE_B = 16'd63455,   // 空闲背景（浅灰 #F6F8FA）
                      C_LPIDLE_P = 16'd8517,    // 空闲前景（深炭黑 #24292F，⭐ 原 9509 错）
                      C_LPREC_B  = 16'd51461,   // 录音背景（警戒红 #CF222E，⭐ 原 52517 错→显黄）
                      C_LPREC_P  = 16'd65535,   // 录音前景（反白）
                      C_LPPLAY_B = 16'd7142,    // 回放背景（森林绿 #1A7F37，⭐ 原 6822 错）
                      C_LPPLAY_P = 16'd65535,   // 回放前景（反白）
                      C_LPARM_B  = 16'd56224,   // 武装背景（琥珀金 #D97706，⭐ 原 55264 错）
                      C_LPARM_P  = 16'd65535;   // 武装前景（反白）
    // ── ⭐⭐ 2026-11-01：鼓机蓝 / 踏板红（标准 RGB565）──
    localparam [15:0] C_DRUM_ON_B  = 16'd2907,   // 鼓机开启背景（电光蓝 #0969DA）
                      C_DRUM_OFF_B = 16'd63455,  // 鼓机关闭背景（浅灰 #F6F8FA，⭐ 与空闲同色）
                      C_PEDAL_ON_B = 16'd51461,  // 踏板踩下背景（警戒红 #CF222E）
                      C_PEDAL_OFF_B= 16'd63455,  // 踏板松开背景（浅灰）
                      C_PEDAL_ON_P = 16'd65535,  // 踏板踩下前景（反白）
                      C_PEDAL_OFF_P= 16'd9509;   // 踏板松开前景（深字）

    // ── ② body 打包原语（⭐ 只在下方组合块内调用）────────────────────────────
    //   📌 `ech_bf_c`/`ech_len_c` 是组合 scratch（左对齐数组 + 游标）；
    //      ⭐ 起帧那拍整体锁存进 `ech_body_q`/`ech_blen_q` ⇒ 帧内容冻结 ✅
    reg [7:0] ech_bf_c [0:35];
    reg [5:0] ech_len_c;
    reg       ech_isval_c;
    reg       ech_istim_c;     // ⭐ 1 = `.tim=` 心跳帧
    reg       ech_isbco_c;     // ⭐ 1 = `.bco=` 背景色帧（⭐ §八-2，与 .val= 同 5B infix、无收尾引号）
    reg       ech_ispco_c;     // ⭐ 1 = `.pco=` 前景色帧
    reg [4:0] ech_abs_c;       // ⭐ 变调绝对值（TRAN 字段用）
    integer   ech_bi;

    task ech_push;             // ⭐ 追加 1 字节
        input [7:0] b;
        begin
            ech_bf_c[ech_len_c] = b;
            ech_len_c = ech_len_c + 6'd1;
        end
    endtask

    task ech_push_str;         // ⭐ 追加右对齐串（低 len 字节 = 文本，⭐ 从高位往低位推）
        input [119:0] s;
        input [4:0]   len;
        integer k;
        begin
            for (k = len - 1; k >= 0; k = k - 1)
                ech_push(s[8*k +: 8]);
        end
    endtask

    task ech_push_dec;         // ⭐ 追加十进制数（⛔ 不带前导零：TJC 按数字解析）
        input [7:0] v;
        reg [7:0] h, t, o;
        begin
            h = 8'h30 + (v / 8'd100);
            t = 8'h30 + ((v / 8'd10) % 8'd10);
            o = 8'h30 + (v % 8'd10);
            if (v >= 8'd100) ech_push(h);
            if (v >= 8'd10)  ech_push(t);
            ech_push(o);
        end
    endtask

    task ech_push_dec16;   // ⭐⭐ 2026-10-29 晚：16 位十进制（⭐ 色帧 5 位数、⛔ 无前导零）
        input [15:0] v;
        reg [15:0] rem;
        reg [7:0]  d4, d3, d2, d1, d0;
        begin
            d4  = 8'h30 + (v / 16'd10000);
            rem = v % 16'd10000;
            d3  = 8'h30 + (rem / 16'd1000);
            rem = rem % 16'd1000;
            d2  = 8'h30 + (rem / 16'd100);
            rem = rem % 16'd100;
            d1  = 8'h30 + (rem / 16'd10);
            d0  = 8'h30 + (rem % 16'd10);
            if (v >= 16'd10000) begin
                ech_push(d4); ech_push(d3); ech_push(d2); ech_push(d1); ech_push(d0);
            end else if (v >= 16'd1000) begin
                ech_push(d3); ech_push(d2); ech_push(d1); ech_push(d0);
            end else if (v >= 16'd100) begin
                ech_push(d2); ech_push(d1); ech_push(d0);
            end else if (v >= 16'd10) begin
                ech_push(d1); ech_push(d0);
            end else begin
                ech_push(d0);
            end
        end
    endtask

    task ech_push_dhz;     // ⭐⭐ 2026-10-31：追加 `N.N`（⭐ v = 十分之一赫兹；整数⛔无前导零）
        input [15:0] v;
        begin
            ech_push_dec(v / 16'd10);              // ⭐ 整数位（≤189 ⇒ 8 位够 ✅）
            ech_push(8'h2E);                       // '.'
            ech_push(8'h30 + (v % 16'd10));        // ⭐ 小数位恒 1 位 ⇒ "5.2" 形态
        end
    endtask

    // ── ⭐⭐ 2026-10-29 晚（§八-3）：满量程百分比（⭐ 仪表 .val 与文本 `NN%` 同源同值）──
    //   ⭐ 口径统一：取满量程**高 8 位**再 ×100>>8 ⇒ 0..99（⭐ 与屏侧 j_vol/z_pd 同宽）
    //   ⚠️ Verilog 乘积宽度 = 操作数最大宽度 ⇒ ⛔ 8bit×100 会溢出 256
    //      ⇒ **全部零扩到 16 位再乘**（⭐ 16bit 中间积 25500 < 2^16 ✅）
    function [7:0] ech_pct16h;   // 16bit 满量程（gain Q4.12 / trim Q1.15）
        input [15:0] v;
        begin
            ech_pct16h = (({8'd0, v[15:8]}) * 8'd100) >> 8;
        end
    endfunction
    function [7:0] ech_pct14;    // 14bit 满量程（dlylen 采样）
        input [13:0] v;
        begin
            ech_pct14 = (({8'd0, v[13:6]}) * 8'd100) >> 8;
        end
    endfunction
    function [7:0] ech_pct11;    // 11bit 满量程（chorlen 采样）
        input [10:0] v;
        begin
            ech_pct11 = (({8'd0, v[10:3]}) * 8'd100) >> 8;
        end
    endfunction
    function [7:0] ech_pct12;    // ⭐ 2026-10-31：12bit 满量程（vib_rate_sel 推子原始值）
        input [11:0] v;
        begin
            ech_pct12 = (({8'd0, v[11:4]}) * 8'd100) >> 8;
        end
    endfunction
    function [7:0] ech_pct8;     // 8bit 满量程（mix / fb / rate 字节域）
        input [7:0] v;
        begin
            ech_pct8 = (({8'd0, v}) * 8'd100) >> 8;
        end
    endfunction
    function [7:0] ech_pct_vrate; // ⭐ 2026-11-01：音量颤音速率进度条（满量程 = 31 = 推子档上限 23.1Hz）
        input [7:0] v;
        begin
            //   📌 推子档 trem_rate_eff = 推子[11:7] ⇒ 满量程 31（=23.1Hz），⛔ 不是 255
            //      （ech_pct8 按 256 换算 ⇒ 拉满只显示 12% ⇒ 🔴 进度条不满）
            //   ✅ 除以 31（常数除法综合器转乘加）：31 → 99、7 → 22、0 → 0
            ech_pct_vrate = (v >= 8'd31) ? 8'd99 : (({8'd0, v} * 8'd100) / 8'd31);
        end
    endfunction

    // ── ②b 控件名（⭐ 组合，⭐ 与 `ech_nxt_c` 同拍）───────────────────────────
    //   📌 字符串字面量赋给 72 位 reg ⇒ ⭐ 高位补零 = **右对齐**（低字节 = 末字符）✅
    //   ⭐ 最长名 `t_dist_st`/`t_chor_st` = 9 字符 ⇒ 72 位恰好装下 ✅
    reg [71:0] ech_name_c;
    reg [3:0]  ech_nlen_c;
    always @(*) begin
        case (ech_nxt_c)
            ECH_F_MODE:  begin ech_name_c = "t_mode";    ech_nlen_c = 4'd6; end
            ECH_F_TEST:  begin ech_name_c = "t1";        ech_nlen_c = 4'd2; end
            ECH_F_BASE:  begin ech_name_c = "t_base";    ech_nlen_c = 4'd6; end
            ECH_F_TIMB:  begin ech_name_c = "t_timbre";  ech_nlen_c = 4'd8; end
            ECH_F_TRAN:  begin ech_name_c = "t_trans";   ech_nlen_c = 4'd7; end   // ⭐ 7 字符（⭐ 曾误写 8 ⇒ 帧头多发一个 00 名字字节）
            ECH_F_SLIDE: begin ech_name_c = "t_slide";   ech_nlen_c = 4'd7; end   // ⭐ 7 字符（同上修正）
            ECH_F_BPM:   begin ech_name_c = "t_bpm";     ech_nlen_c = 4'd5; end
            ECH_F_DRUM:  begin ech_name_c = "t_drum";    ech_nlen_c = 4'd6; end
            ECH_F_LOOP:  begin ech_name_c = "t_loop";    ech_nlen_c = 4'd6; end
            ECH_F_KD:    begin ech_name_c = "t_kd";      ech_nlen_c = 4'd4; end
            ECH_F_VOL:   begin ech_name_c = "t_vol";    ech_nlen_c = 4'd5; end
            ECH_F_PEDAL: begin ech_name_c = "t_pedal";   ech_nlen_c = 4'd7; end   // ⭐ 7 字符（同上修正）
            ECH_F_GEAR:  begin ech_name_c = "t_gear";    ech_nlen_c = 4'd6; end
            ECH_F_HDMI:  begin ech_name_c = "t_hdmi";    ech_nlen_c = 4'd6; end
            ECH_F_PD:    begin ech_name_c = "t_pd";      ech_nlen_c = 4'd4; end
            ECH_F_VD:    begin ech_name_c = "t_vd";      ech_nlen_c = 4'd4; end
            ECH_F_DIST:  begin ech_name_c = "t_dist_st"; ech_nlen_c = 4'd9; end
            ECH_F_CHOR:  begin ech_name_c = "t_chor_st"; ech_nlen_c = 4'd9; end
            ECH_F_DLY:   begin ech_name_c = "t_dly_st";  ech_nlen_c = 4'd8; end
            ECH_F_JVOL:  begin ech_name_c = "j_vol";     ech_nlen_c = 4'd5; end
            ECH_F_ZPD:   begin ech_name_c = "z_pd";      ech_nlen_c = 4'd4; end
            ECH_F_HB:    begin ech_name_c = "tm1";      ech_nlen_c = 4'd3; end
            // ── ⭐⭐ 2026-10-29 晚：§八 收口 25 字段 ──────────────────────────
            ECH_F_LOOPBCO: begin ech_name_c = "t_loop";   ech_nlen_c = 4'd6; end
            ECH_F_LOOPPCO: begin ech_name_c = "t_loop";   ech_nlen_c = 4'd6; end
            ECH_F_LEDD:    begin ech_name_c = "led_dist"; ech_nlen_c = 4'd8; end
            ECH_F_LEDC:    begin ech_name_c = "led_chor"; ech_nlen_c = 4'd8; end
            ECH_F_LEDDLY:  begin ech_name_c = "led_dly";  ech_nlen_c = 4'd7; end   // ⭐ 7 字符（同上修正）
            ECH_F_ZDG:     begin ech_name_c = "z_dg";     ech_nlen_c = 4'd4; end
            ECH_F_ZDT:     begin ech_name_c = "z_dt";     ech_nlen_c = 4'd4; end
            ECH_F_ZCL:     begin ech_name_c = "z_cl";     ech_nlen_c = 4'd4; end
            ECH_F_ZMX:     begin ech_name_c = "z_mx";     ech_nlen_c = 4'd4; end
            ECH_F_ZLL:     begin ech_name_c = "z_ll";     ech_nlen_c = 4'd4; end
            ECH_F_ZLF:     begin ech_name_c = "z_lf";     ech_nlen_c = 4'd4; end
            ECH_F_ZPR:     begin ech_name_c = "z_pr";     ech_nlen_c = 4'd4; end
            ECH_F_ZVR:     begin ech_name_c = "z_vr";     ech_nlen_c = 4'd4; end
            ECH_F_TDG:     begin ech_name_c = "t_dg_val"; ech_nlen_c = 4'd8; end
            ECH_F_TDT:     begin ech_name_c = "t_dt_val"; ech_nlen_c = 4'd8; end
            ECH_F_TCL:     begin ech_name_c = "t_cl_val"; ech_nlen_c = 4'd8; end
            ECH_F_TMX:     begin ech_name_c = "t_mx_val"; ech_nlen_c = 4'd8; end
            ECH_F_TLL:     begin ech_name_c = "t_ll_val"; ech_nlen_c = 4'd8; end
            ECH_F_TLF:     begin ech_name_c = "t_lf_val"; ech_nlen_c = 4'd8; end
            ECH_F_TPDV:    begin ech_name_c = "t_pd_val"; ech_nlen_c = 4'd8; end
            ECH_F_TVDV:    begin ech_name_c = "t_vd_val"; ech_nlen_c = 4'd8; end
            ECH_F_TPR:     begin ech_name_c = "t_pr_val"; ech_nlen_c = 4'd8; end
            ECH_F_TVR:     begin ech_name_c = "t_vr_val"; ech_nlen_c = 4'd8; end
            ECH_F_CUR:     begin ech_name_c = "cur";      ech_nlen_c = 4'd3; end
            ECH_F_GR:      begin ech_name_c = "gr";       ech_nlen_c = 4'd2; end
            // ── ⭐⭐ 2026-10-31：《控件位置清单》新 9 帧 ──────────────────────
            ECH_F_PSLIDE:  begin ech_name_c = "p_slide";  ech_nlen_c = 4'd7; end
            ECH_F_PBEAT:   begin ech_name_c = "p_bpm";    ech_nlen_c = 4'd5; end
            ECH_F_UPL:     begin ech_name_c = "b_uplink"; ech_nlen_c = 4'd8; end
            ECH_F_PRATE:   begin ech_name_c = "t_pr";     ech_nlen_c = 4'd4; end
            ECH_F_VRATE:   begin ech_name_c = "t_vr";     ech_nlen_c = 4'd4; end
            ECH_F_JPR:     begin ech_name_c = "j_pr";     ech_nlen_c = 4'd4; end
            ECH_F_JVR:     begin ech_name_c = "j_vr";     ech_nlen_c = 4'd4; end
            ECH_F_JPD:     begin ech_name_c = "j_pd";     ech_nlen_c = 4'd4; end
            ECH_F_JVD:     begin ech_name_c = "j_vd";     ech_nlen_c = 4'd4; end
            ECH_F_DRUMBCO: begin ech_name_c = "t_drum";   ech_nlen_c = 4'd6; end
            ECH_F_PEDALBCO:begin ech_name_c = "t_pedal";  ech_nlen_c = 4'd7; end
            ECH_F_LOCK:    begin ech_name_c = "t_lock";   ech_nlen_c = 4'd6; end
            default:     begin ech_name_c = "z_vd";      ech_nlen_c = 4'd4; end  // ECH_F_ZVD
        endcase
    end

    // ── ②c body 打包（⭐ 组合，⭐ 与 `ech_nxt_c` 同拍；⭐ 起帧那拍整体锁存快照）─
    //   ⚠️ 文案严格按《USART-HMI搭建清单-Page0-20261028.md》，UTF-8 已逐字核对 ✅
    //   ⚠️ **变长 body ⛔ 不能用定宽拼接**（零填充会落进帧里）⇒ 用游标逐字节推 ✅
    always @(*) begin
        for (ech_bi = 0; ech_bi < 36; ech_bi = ech_bi + 1) ech_bf_c[ech_bi] = 8'h00;
        ech_len_c   = 6'd0;
        ech_isval_c = 1'b0;
        ech_istim_c = 1'b0;
        ech_isbco_c = 1'b0;
        ech_ispco_c = 1'b0;
        ech_abs_c   = 5'd0;
        case (ech_nxt_c)
            ECH_F_MODE: begin
                if (mode_o) begin
                    ech_push_str(W_GANGQIN_MOSHI, 4'd12);
                    ech_push_str(" [PIANO]", 4'd8);
                end else begin
                    ech_push_str(W_ZHIBAN_MOSHI, 4'd12);
                    ech_push_str(" [FRET]", 4'd7);
                end
            end
            ECH_F_TEST: begin
                // ⭐⭐ 2026-11-01 队友改：t1 显示「当前复音数」（mx_n_active 0..32），⛔ 不再是档位
                ech_push_dec(st_nactive_c);
            end
            ECH_F_BASE: begin
                // ⭐ 基准音: C4 (最低音 C3) —— C5/C6 时最低音联动 +1 八度
                ech_push_str(W_JIZHUNYIN, 4'd9);
                ech_push_str(": ", 4'd2);
                case (base_semi_o)
                    7'd12:  begin ech_push(8'h43); ech_push(8'h35); end  // C5
                    7'd24:  begin ech_push(8'h43); ech_push(8'h36); end  // C6
                    default: begin ech_push(8'h43); ech_push(8'h34); end // C4（⭐ 兜底）
                endcase
                ech_push_str(" (", 4'd2);
                ech_push_str(W_ZUIDIYIN, 4'd9);
                ech_push(8'h20);
                case (base_semi_o)
                    7'd12:  begin ech_push(8'h43); ech_push(8'h34); end  // C4
                    7'd24:  begin ech_push(8'h43); ech_push(8'h35); end // C5
                    default: begin ech_push(8'h43); ech_push(8'h33); end // C3（⭐ 兜底）
                endcase
                ech_push(8'h29);   // ')'
            end
            ECH_F_TIMB: begin
                case (st_timbre_c)
                    2'd0: ech_push_str("BASS", 4'd4);
                    2'd1: ech_push_str("GUITAR", 4'd6);
                    2'd2: ech_push_str("PIANO", 4'd5);
                    default: ech_push_str("PAD", 4'd3);
                endcase
            end
            ECH_F_TRAN: begin
                // ⭐ 0 = `0 SEMI (原调)`；非 0 = `+N SEMI` / `-N SEMI`
                if (st_trans_c == 5'd0) begin
                    ech_push_str("0 SEMI (", 4'd8);
                    ech_push_str(W_YUANDIAO, 4'd6);
                    ech_push(8'h29);   // ')'
                end else begin
                    if (st_trans_c[4]) begin
                        ech_abs_c = (~st_trans_c) + 5'd1;   // ⭐ 有符号取绝对值
                        ech_push(8'h2D);                     // '-'
                        ech_push_dec({3'd0, ech_abs_c});
                    end else begin
                        ech_push(8'h2B);                     // '+'
                        ech_push_dec({3'd0, st_trans_c});
                    end
                    ech_push_str(" SEMI", 4'd5);
                end
            end
            ECH_F_SLIDE: begin
                if (st_slide_c) begin
                    ech_push_str(W_KAIQI, 4'd6);
                    ech_push_str(" (GLIDE ON)", 4'd11);
                end else begin
                    ech_push_str(W_GUANBI, 4'd6);
                    ech_push_str(" (GLIDE OFF)", 4'd12);
                end
            end
            ECH_F_BPM: ech_push_dec(st_bpm_c);
            ECH_F_DRUM: begin
                //  ⭐⭐ 2026-11-01 队友改：一直显示当前节奏型 `Pattern N`（⛔ 不再显示「关」）
                //   📌 st_drum_c = {on, pattern}；开启/关闭只靠 bco 色帧（ECH_F_DRUMBCO）区分
                ech_push_str("Pattern ", 4'd8);
                case (st_drum_c[1:0])
                    2'd0: ech_push_str("I", 4'd1);
                    2'd1: ech_push_str("II", 4'd2);
                    2'd2: ech_push_str("III", 4'd3);
                    default: ech_push_str("IV", 4'd2);
                endcase
            end
            ECH_F_LOOP: begin
                case (st_loop_c)
                    2'd1: begin  // 录音
                        ech_push_str(W_DOT, 3'd3);
                        ech_push(8'h20);
                        ech_push_str(W_XUNHUAN_LUYIN, 4'd15);
                        ech_push_str(" REC", 4'd4);
                    end
                    2'd2: begin  // 回放
                        // ⭐ 2026-10-30：● → ►（终稿速查表"▶ 回放中"的对齐实现；
                        //    ⛔ ▶ U+25B6 不在字库② §7.2 集（只有 ► U+25BA）⇒ 用 ► ✅
                        ech_push_str(W_PLAY, 3'd3);
                        ech_push(8'h20);
                        ech_push_str(W_XUNHUAN_HUIFANG, 4'd15);
                        ech_push_str(" PLAY", 4'd5);
                    end
                    2'd3: ech_push_str(W_WUZHUANG, 4'd9);   // 武装中
                    default: ech_push_str(W_KONGXIAN, 4'd6); // 空闲
                endcase
            end
            ECH_F_KD: begin
                //  ⭐⭐ 2026-10-31 新文案：`打鼓: 开/关 [键位打鼓/音符演奏]`
                //    （⭐ t_kd 缩窄至 220px ⇒ 前缀 4 字砍成 2 字）
                ech_push_str(W_DAGU, 3'd6);
                ech_push_str(": ", 4'd2);
                if (st_kd_c) begin
                    ech_push_str(W_KAIQI, 4'd6);
                    ech_push_str(" [", 4'd2);
                    ech_push_str(W_JIANWEI_DAGU, 4'd12);
                end else begin
                    ech_push_str(W_GUANBI, 4'd6);
                    ech_push_str(" [", 4'd2);
                    ech_push_str(W_YINFU_YANZOU, 4'd12);
                end
                ech_push(8'h5D);   // ']'
            end
            ECH_F_VOL: begin
                ech_push_str(W_ZHU_YINLIANG, 4'd9);
                ech_push_str(": ", 4'd2);
                ech_push_dec({1'b0, st_vol_c});
                ech_push(8'h25);   // '%'
            end
            ECH_F_PEDAL: begin
                //  ⭐⭐ 2026-11-01 队友改：`延音: 关/开`（踩下=开，⭐ 配合 bco 色帧变红）
                ech_push_str(W_YANYIN, 4'd6);
                ech_push_str(": ", 4'd2);
                ech_push_str(st_pedal_c ? W_KAI : W_GUAN, 3'd3);
            end
            ECH_F_GEAR: begin
                // ⭐ `推子控制: 档 N [label]`（⭐ 屏显档号 1..4 = gear+1）
                ech_push_str(W_TUIZI_KONGZHI, 4'd12);
                ech_push_str(": ", 4'd2);
                ech_push_str(W_DANG, 3'd3);
                ech_push(8'h20);
                ech_push_dec({5'd0, st_gear_c} + 8'd1);
                ech_push_str(" [", 4'd2);
                case (st_gear_c)
                    2'd0: ech_push_str(W_BIANDIAO, 4'd6);
                    2'd1: ech_push_str(W_YINGAO_CHANYIN, 4'd12);
                    2'd2: ech_push_str(W_YINLIANG_CHANYIN, 4'd12);
                    default: ech_push_str(W_WU, 3'd3);
                endcase
                ech_push(8'h5D);   // ']'
            end
            ECH_F_HDMI: begin
                //  ⭐⭐ 2026-11-01 队友改：`HDMI: 频谱/示波/李萨如`（⛔ 去掉「实时示波器」与括号）
                ech_push_str("HDMI: ", 4'd6);
                case (st_scope_c)
                    2'd2: ech_push_str(W_PINPU, 4'd6);        // 频谱
                    2'd1: ech_push_str(W_LISARU, 4'd9);       // 李萨如
                    default: ech_push_str(W_SHIBO, 4'd6);     // 示波（原「波形显示」）
                endcase
            end
            ECH_F_PD: begin
                //  ⭐⭐ 2026-10-31 新文案：`深度 NN%`
                //    （⭐ 双仓重排：仓标题移到静态 l_vp_title/l_vv_title ⇒ 帧内只留量纲词）
                ech_push_str(W_SHENDU, 4'd6);
                ech_push(8'h20);
                ech_push_dec({1'b0, st_pvib_c});
                ech_push(8'h25);   // '%'
            end
            ECH_F_VD: begin
                ech_push_str(W_SHENDU, 4'd6);
                ech_push(8'h20);
                ech_push_dec({1'b0, st_vvib_c});
                ech_push(8'h25);   // '%'
            end
            ECH_F_DIST: begin
                ech_push_str(W_SHIZHEN, 4'd6);
                ech_push_str(" [", 4'd2);
                ech_push_str(st_fxmask_c[0] ? W_KAI : W_GUAN, 3'd3);
                ech_push(8'h5D);   // ']'
            end
            ECH_F_CHOR: begin
                ech_push_str(W_HECHANG, 4'd6);
                ech_push_str(" [", 4'd2);
                ech_push_str(st_fxmask_c[1] ? W_KAI : W_GUAN, 3'd3);
                ech_push(8'h5D);   // ']'
            end
            ECH_F_DLY: begin
                ech_push_str(W_YANCHI, 4'd6);
                ech_push_str(" [", 4'd2);
                ech_push_str(st_fxmask_c[2] ? W_KAI : W_GUAN, 3'd3);
                ech_push(8'h5D);   // ']'
            end
            ECH_F_JVOL: begin
                // ⭐ 数值帧：j_vol.val=<0..100>（⭐ 进度条）
                ech_isval_c = 1'b1;
                ech_push_dec({1'b0, st_vol_c});
            end
            ECH_F_ZPD: begin
                ech_isval_c = 1'b1;
                ech_push_dec({1'b0, st_pvib_c});
            end
            ECH_F_HB: begin
                //  ⭐ 心跳帧：`tm1.tim=1500`（⭐ 重置屏侧看门狗倒计时 ⇒ 断联 1.5s 后闪）
                //     ⚠️ "1500" 与屏侧 tm1 周期【成对配置】（⭐ > HB_MS 留余量）
                ech_istim_c = 1'b1;
                ech_push_str("1500", 4'd4);
            end
            // ══ ⭐⭐ 2026-10-29 晚：§八 收口 25 字段 ═════════════════════════════
            ECH_F_LOOPBCO: begin
                //  ⭐ §八-2：t_loop 背景色（.bco=，⭐ 色值与 body 文案同一个 st_loop case 源）
                ech_isbco_c = 1'b1;
                case (st_loop_c)
                    2'd1:    ech_push_dec16(C_LPREC_B);   // 录音红
                    2'd2:    ech_push_dec16(C_LPPLAY_B);  // 回放绿
                    2'd3:    ech_push_dec16(C_LPARM_B);   // 武装琥珀
                    default: ech_push_dec16(C_LPIDLE_B);  // 空闲浅灰
                endcase
            end
            ECH_F_LOOPPCO: begin
                ech_ispco_c = 1'b1;
                case (st_loop_c)
                    2'd1:    ech_push_dec16(C_LPREC_P);
                    2'd2:    ech_push_dec16(C_LPPLAY_P);
                    2'd3:    ech_push_dec16(C_LPARM_P);
                    default: ech_push_dec16(C_LPIDLE_P);
                endcase
            end
            ECH_F_LEDD: begin
                //  ⭐ §八-4：效果器状态灯（.val=0/1，⭐ 与 t_dist_st 同源 fxmask）
                ech_isval_c = 1'b1;
                ech_push(st_fxmask_c[0] ? 8'h31 : 8'h30);
            end
            ECH_F_LEDC: begin
                ech_isval_c = 1'b1;
                ech_push(st_fxmask_c[1] ? 8'h31 : 8'h30);
            end
            ECH_F_LEDDLY: begin
                ech_isval_c = 1'b1;
                ech_push(st_fxmask_c[2] ? 8'h31 : 8'h30);
            end
            ECH_F_ZDG: begin
                //  ⭐ §八-3：page1 仪表（.val=0..99，⭐ 满量程百分比）
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct16h(fx_gain_o));
            end
            ECH_F_ZDT: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct16h(fx_trim_o));
            end
            ECH_F_ZCL: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct11(fx_chorlen_o));
            end
            ECH_F_ZMX: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct8(fx_mix_o));
            end
            ECH_F_ZLL: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct14(fx_dlylen_o));
            end
            ECH_F_ZLF: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct8(fx_fb_o));
            end
            ECH_F_ZPR: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct8(fx_rate_o));
            end
            ECH_F_ZVR: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct8(fx_rate_o));   // ⭐ 与 z_pr 同源 fx_rate
            end
            ECH_F_TDG: begin
                //  ⭐ page1 数值文本（txt `NN%`，⭐ 与对应仪表**同源同值**）
                ech_push_dec(ech_pct16h(fx_gain_o));
                ech_push(8'h25);   // '%'
            end
            ECH_F_TDT: begin
                ech_push_dec(ech_pct16h(fx_trim_o));
                ech_push(8'h25);
            end
            ECH_F_TCL: begin
                ech_push_dec(ech_pct11(fx_chorlen_o));
                ech_push(8'h25);
            end
            ECH_F_TMX: begin
                ech_push_dec(ech_pct8(fx_mix_o));
                ech_push(8'h25);
            end
            ECH_F_TLL: begin
                ech_push_dec(ech_pct14(fx_dlylen_o));
                ech_push(8'h25);
            end
            ECH_F_TLF: begin
                ech_push_dec(ech_pct8(fx_fb_o));
                ech_push(8'h25);
            end
            ECH_F_TPDV: begin
                //  ⭐ 音高/音量颤音深度文本（⭐ 数据源 = page0 的 st_pvib/st_vvib）
                ech_push_dec({1'b0, st_pvib_c});
                ech_push(8'h25);
            end
            ECH_F_TVDV: begin
                ech_push_dec({1'b0, st_vvib_c});
                ech_push(8'h25);
            end
            ECH_F_TPR: begin
                ech_push_dec(ech_pct8(fx_rate_o));
                ech_push(8'h25);
            end
            ECH_F_TVR: begin
                ech_push_dec(ech_pct8(fx_rate_o));   // ⭐ 与 t_pr_val 同源 fx_rate
                ech_push(8'h25);
            end
            ECH_F_CUR: begin
                //  ⭐ EC11 锁定参数文本 `EC11: <参数名> (0x1N)`（N=par_sel 0..7 ↔ 0x11..0x18）
                ech_push_str("EC11: ", 4'd6);
                case (par_sel_c)
                    3'd1: ech_push_str(W_BUCHANG, 4'd6);       // 补偿
                    3'd2: ech_push_str(W_HUNHE, 4'd6);          // 混合
                    3'd3: ech_push_str(W_FANKUI, 4'd6);         // 反馈
                    3'd4: ech_push_str(W_SHENDU, 4'd6);         // 深度
                    3'd5: ech_push_str(W_SULU, 4'd6);           // 速率
                    3'd6: ech_push_str(W_YANCHI_CD, 4'd12);     // 延迟长度
                    3'd7: ech_push_str(W_HECHANG_CD, 4'd12);    // 合唱长度
                    default: ech_push_str(W_ZENGYI, 4'd6);     // 增益（par_sel=0）
                endcase
                ech_push_str(" (0x1", 4'd5);
                ech_push(8'h31 + {5'd0, par_sel_c});   // '1'..'8'（⭐ = 串口变量号 0x11..0x18）
                ech_push(8'h29);                       // ')'
            end
            ECH_F_GR: begin
                //  ⭐ 推子档短文本 `档 N [label]`（⭐ 与 t_gear 同源 st_gear_c ⇒ 双挂起）
                ech_push_str(W_DANG, 3'd3);
                ech_push(8'h20);
                ech_push_dec({5'd0, st_gear_c} + 8'd1);   // ⭐ 屏显档号 1..4 = gear+1
                ech_push_str(" [", 4'd2);
                case (st_gear_c)
                    2'd0: ech_push_str(W_BIANDIAO, 4'd6);
                    2'd1: ech_push_str(W_YINGAO_CHANYIN, 4'd12);
                    2'd2: ech_push_str(W_YINLIANG_CHANYIN, 4'd12);
                    default: ech_push_str(W_WU, 3'd3);
                endcase
                ech_push(8'h5D);   // ']'
            end
            // ══ ⭐⭐ 2026-10-31：《控件位置清单》新 9 帧体 ═══════════════════════════
            ECH_F_PSLIDE: begin
                // ⭐ 滑音状态灯（绿点：.val=0/1，⭐ 与 t_slide 文本同源 ⇒ 双挂起）
                ech_isval_c = 1'b1;
                ech_push(st_slide_c ? 8'h31 : 8'h30);
            end
            ECH_F_PBEAT: begin
                // ⭐ 节拍状态灯（橙点：.val 随 beat_dot_s 每拍翻转 0/1）
                ech_isval_c = 1'b1;
                ech_push(beat_dot_s ? 8'h31 : 8'h30);
            end
            ECH_F_UPL: begin
                // ⭐ `● 实时上行: 开启/关闭`（⭐ 触摸控件 15 翻转 uplink_sw_o）
                ech_push_str(W_DOT, 3'd3);
                ech_push(8'h20);
                ech_push_str(W_SHISHI_SHANGXING, 4'd12);
                ech_push_str(": ", 4'd2);
                ech_push_str(uplink_sw_o ? W_KAIQI : W_GUANBI, 3'd6);
            end
            ECH_F_PRATE: begin
                // ⭐ `速率 N.NHz`（⭐ 显示实际生效值：音高速率只来自推子档 1，1.0~12.0Hz）
                ech_push_str(W_SULU, 4'd6);
                ech_push(8'h20);
                ech_push_dhz(ech_prate_hz[15:0]);
                ech_push_str("Hz", 4'd2);
            end
            ECH_F_VRATE: begin
                // ⭐ `速率 N.NHz`（音量颤音：trem_rate_eff 8 位相位增量，默认 5.2Hz）
                ech_push_str(W_SULU, 4'd6);
                ech_push(8'h20);
                ech_push_dhz(ech_vrate_hz[15:0]);
                ech_push_str("Hz", 4'd2);
            end
            ECH_F_JPR: begin
                // ⭐ 音高颤音速率进度条（.val=0..99 满量程百分比）
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct12(st_prate_c));
            end
            ECH_F_JVR: begin
                ech_isval_c = 1'b1;
                ech_push_dec(ech_pct_vrate(st_vrate_c));   // ⭐ 满量程 31（推子档上限 23.1Hz）
            end
            ECH_F_JPD: begin
                // ⭐ 音高/音量颤音深度进度条（⭐ 与 t_pd/t_vd 文本同源同值）
                ech_isval_c = 1'b1;
                ech_push_dec({1'b0, st_pvib_c});
            end
            ECH_F_JVD: begin
                ech_isval_c = 1'b1;
                ech_push_dec({1'b0, st_vvib_c});
            end
            // ══ ⭐⭐ 2026-11-01 队友新增 3 帧体（色帧 + 锁定）════════════════
            ECH_F_DRUMBCO: begin
                // 鼓机背景色：开启=蓝、关闭=浅灰（⭐ 与 t_drum 文本同源 st_drum_c ⇒ 双挂起）
                ech_isbco_c = 1'b1;
                ech_push_dec16(st_drum_c[2] ? C_DRUM_ON_B : C_DRUM_OFF_B);
            end
            ECH_F_PEDALBCO: begin
                // 踏板背景色：踩下=红、松开=浅灰（⭐ 与 t_pedal 文本同源 st_pedal_c ⇒ 双挂起）
                ech_isbco_c = 1'b1;
                ech_push_dec16(st_pedal_c ? C_PEDAL_ON_B : C_PEDAL_OFF_B);
            end
            ECH_F_LOCK: begin
                //  ⭐⭐ 2026-11-01 队友改：推子锁定状态（`锁定` / `实时生效`）
                if (st_lock_c) ech_push_str(W_SUODING, 4'd6);
                else           ech_push_str(W_SHISHI_SHENGXIAO, 4'd12);
            end
            default: begin  // ECH_F_ZVD
                ech_isval_c = 1'b1;
                ech_push_dec({1'b0, st_vvib_c});
            end
        endcase
    end

    // ── ③ 帧字节（⭐ 组合，⭐ 与 `ech_pos` 严格同拍；⭐ 只读【锁存快照】）────────
    //   📌 帧结构：`<名字>`(nlen) + `.txt="`(6)/`.val=`(5)/`.tim=`(5)/`.bco=`(5)/`.pco=`(5)
    //            + <body>(blen) + [`"`](仅 txt) + `FF FF FF`(3)
    //   📌 位置映射：pos 0..nlen−1 = 名字 · nlen..pre−1 = infix ·
    //       pre..ebody−1 = body · ebody = 收尾引号(txt) · ff0..ff0+2 = FF FF FF
    //   📌 最长帧 = t_hdmi 波形档：6+6+36+1+3 = 52 字节 ⇒ `ech_pos` 6 位够 ✅
    wire [5:0] ech_ilen_c  = (ech_isval_q | ech_istim_q | ech_isbco_q | ech_ispco_q) ? 6'd5 : 6'd6;
    wire [5:0] ech_pre_c   = {2'd0, ech_nlen_q} + ech_ilen_c;        // 名字+infix 总长
    wire [5:0] ech_ebody_c = ech_pre_c + ech_blen_q;                 // body 结束（不含）
    wire [5:0] ech_ff0_c   = ech_ebody_c + ((ech_isval_q | ech_istim_q | ech_isbco_q | ech_ispco_q) ? 6'd0 : 6'd1); // 首个 FF 位置
    reg  [7:0] ech_data_c;
    reg        ech_last_c;
    always @(*) begin
        ech_data_c = 8'h00;
        ech_last_c = 1'b0;
        if (ech_pos < {2'd0, ech_nlen_q}) begin
            // ══ 名字（⭐ 右对齐 72 位：字节 (nlen−1−pos) 从低位数）══
            ech_data_c = ech_name_q[8*(ech_nlen_q - 6'd1 - ech_pos) +: 8];
        end else if (ech_pos < ech_pre_c) begin
            // ══ infix ══
            if (ech_istim_q) begin
                case (ech_pos - {2'd0, ech_nlen_q})
                    6'd0: ech_data_c = 8'h2E;  // '.'
                    6'd1: ech_data_c = 8'h74;  // 't'
                    6'd2: ech_data_c = 8'h69;  // 'i'
                    6'd3: ech_data_c = 8'h6D;  // 'm'
                    6'd4: ech_data_c = 8'h3D;  // '='
                    default: ech_data_c = 8'h00;
                endcase
            end else if (ech_isval_q) begin
                case (ech_pos - {2'd0, ech_nlen_q})
                    6'd0: ech_data_c = 8'h2E;  // '.'
                    6'd1: ech_data_c = 8'h76;  // 'v'
                    6'd2: ech_data_c = 8'h61;  // 'a'
                    6'd3: ech_data_c = 8'h6C;  // 'l'
                    6'd4: ech_data_c = 8'h3D;  // '='
                    default: ech_data_c = 8'h00;
                endcase
            end else if (ech_isbco_q) begin
                //  ⭐⭐ 2026-10-29 晚（§八-2）：`.bco=` 背景色 infix（5B、无收尾引号）
                case (ech_pos - {2'd0, ech_nlen_q})
                    6'd0: ech_data_c = 8'h2E;  // '.'
                    6'd1: ech_data_c = 8'h62;  // 'b'
                    6'd2: ech_data_c = 8'h63;  // 'c'
                    6'd3: ech_data_c = 8'h6F;  // 'o'
                    6'd4: ech_data_c = 8'h3D;  // '='
                    default: ech_data_c = 8'h00;
                endcase
            end else if (ech_ispco_q) begin
                //  ⭐ `.pco=` 前景色 infix
                case (ech_pos - {2'd0, ech_nlen_q})
                    6'd0: ech_data_c = 8'h2E;  // '.'
                    6'd1: ech_data_c = 8'h70;  // 'p'
                    6'd2: ech_data_c = 8'h63;  // 'c'
                    6'd3: ech_data_c = 8'h6F;  // 'o'
                    6'd4: ech_data_c = 8'h3D;  // '='
                    default: ech_data_c = 8'h00;
                endcase
            end else begin
                case (ech_pos - {2'd0, ech_nlen_q})
                    6'd0: ech_data_c = 8'h2E;  // '.'
                    6'd1: ech_data_c = 8'h74;  // 't'
                    6'd2: ech_data_c = 8'h78;  // 'x'
                    6'd3: ech_data_c = 8'h74;  // 't'
                    6'd4: ech_data_c = 8'h3D;  // '='
                    6'd5: ech_data_c = 8'h22;  // '"'
                    default: ech_data_c = 8'h00;
                endcase
            end
        end else if (ech_pos < ech_ebody_c) begin
            // ══ body（⭐ 左对齐数组：下标 = pos − pre）══
            ech_data_c = ech_body_q[ech_pos - ech_pre_c];
        end else if (!ech_isval_q && !ech_istim_q && !ech_isbco_q && !ech_ispco_q && (ech_pos == ech_ebody_c)) begin
            ech_data_c = 8'h22;   // '"'（txt 帧收尾引号；⭐ val/tim/bco/pco 帧 ⛔ 无引号）
        end else if (ech_pos >= ech_ff0_c) begin
            ech_data_c = 8'hFF;
            if (ech_pos == (ech_ff0_c + 6'd2)) ech_last_c = 1'b1;   // ⭐ 第 3 个 FF = 帧尾
        end
    end

    // ── ④ 时序（⭐ 唯一写 `tx_start_o`/`tx_data_o` 与 `ech_*` 的 always 块）────
    //   ⚠️ **已从主状态机里移除** `tx_start_o`/`tx_data_o` 的赋值，
    //      ⭐ 现在**只有本节**写它们（⛔ 一个 reg 只能一个 always 赋值 ✅）
    //   ⚠️ **本块内顺序**：① 发送 FSM（清 pending 位）→ ② 变化检测（置 pending 位）。
    //      ⭐ 两者写同一位时**后写者胜** ⇒ 同拍「起帧 + 值恰好又变」不会被清掉 ✅
    integer ech_ei;   // ⭐ 起帧锁存 36 字节快照的循环变量
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            ech_state   <= ECH_S_IDLE;
            ech_pos     <= 6'd0;
            ech_pend    <= 60'd0;
            ech_name_q  <= 72'd0;
            ech_nlen_q  <= 4'd0;
            ech_blen_q  <= 6'd0;
            ech_isval_q <= 1'b0;
            ech_istim_q <= 1'b0;
            ech_isbco_q <= 1'b0;
            ech_ispco_q <= 1'b0;
            hb_tmr_q    <= 32'd0;
            for (ech_ei = 0; ech_ei < 36; ech_ei = ech_ei + 1) ech_body_q[ech_ei] <= 8'd0;
            // ⭐ 镜像初始化为**与各信号复位值一致** ⇒ ⛔ 上电不产生伪回显 ✅
            ech_hb_s     <= 1'b0;
            reflash_q    <= 1'b0;   // ⭐ 2026-10-29 三件套-A：重发请求复位
            ech_mode_s   <= (MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0;
            ech_test_s   <= 1'b0;
            ech_testn_s  <= 2'b00;
            ech_base_s   <= 7'd0;
            ech_timbre_s <= 2'd0;
            ech_trans_s  <= 5'd0;
            ech_slide_s  <= 1'b0;
            ech_bpm_s    <= 8'd120;   // ⭐ play_seq.bpm_o 复位 120
            ech_drum_s   <= 3'b100;   // ⭐ 2026-10-31：{on, pattern} 复位 = 开 + Pattern I
            ech_loop_s   <= 2'd0;
            ech_kd_s     <= 1'b0;
            ech_vol_s    <= 7'd0;
            ech_pedal_s  <= 1'b0;
            ech_gear_s   <= 2'd1;    // ⭐ fader_gear 复位档 1
            ech_scope_s  <= 2'd0;
            ech_pvib_s   <= 7'd0;
            ech_vvib_s   <= 7'd0;
            ech_fxmask_s <= 3'd0;
            // ⭐⭐ 2026-10-31：新字段镜像 ← 各信号复位值 ⇒ ⛔ 上电不产生伪回显 ✅
            ech_uplink_s <= 1'b1;     // ⭐ uplink_sw_o 复位开启
            ech_beat_s   <= 1'b0;
            beat_dot_s   <= 1'b0;
            ech_prate_s  <= 12'd0;
            ech_vrate_s  <= 8'd7;     // ⭐ = FX_RATE_DEF（z-safe 默认同值）
            // ⭐⭐ 2026-10-29 晚（§八-3）：page1 镜像 ← FX 复位默认值 ⇒ ⛔ 上电不产生伪回显 ✅
            ech_fxg_s    <= FX_GAIN_DEF;
            ech_fxt_s    <= FX_TRIM_DEF;
            ech_mix_s    <= FX_MIX_DEF;
            ech_fb_s     <= FX_FB_DEF;
            ech_rate_s   <= FX_RATE_DEF;
            ech_dl_s     <= FX_DLYLEN_DEF;
            ech_cl_s     <= FX_CHORLEN_DEF;
            ech_parsel_s <= 3'd0;
            tx_start_o <= 1'b0;
            tx_data_o  <= 8'd0;
        end else begin
            // ⭐ 默认：脉冲输出每拍清零 ⇒ 严格单周期
            tx_start_o <= 1'b0;

            // ══ ⭐ 发送 FSM ═════════════════════════════════════════════════
            case (ech_state)
                ECH_S_IDLE: begin
                    if (|ech_pend) begin
                        // ⭐ 起帧：锁存**帧快照**（⭐ 发送期间输入再变也 ⛔ 不影响本帧）
                        ech_pend[ech_nxt_c] <= 1'b0;   // ⭐ 变索引清位（与 ①b 同一优先级）
                        ech_nlen_q  <= ech_nlen_c;
                        ech_name_q  <= ech_name_c;
                        ech_blen_q  <= ech_len_c;
                        ech_isval_q <= ech_isval_c;
                        ech_istim_q <= ech_istim_c;
                        ech_isbco_q <= ech_isbco_c;
                        ech_ispco_q <= ech_ispco_c;
                        for (ech_ei = 0; ech_ei < 36; ech_ei = ech_ei + 1)
                            ech_body_q[ech_ei] <= ech_bf_c[ech_ei];
                        ech_pos     <= 6'd0;
                        ech_state    <= ECH_S_EMIT;
                    end
                end
                ECH_S_EMIT: begin
                    // ⭐⭐ 流控：⭐ 只在 `tx_busy_i == 0`（下游能接）时推字节 + 推进
                    //   🔴 **为什么必须看 busy**：⭐ 回显帧最长 52 字节，而 `u_tx_fifo`
                    //      深度只有 8 ⇒ ⛔ 若像 `fx_tx` 那样"盲推每拍一个"，队列会溢出丢字节。
                    //      （⭐ `fx_tx` 能盲推只因为 `'Z'` 帧是 6 字节 < 8 ✅）
                    //   ⇒ ⭐ `top.v` 把 `tx_busy_i` 接到 `~txf_ready`（队列满 = 忙），
                    //      本 FSM 在 busy 时**原地等待**（⛔ 不推、不推进 pos）✅
                    //   📌 与 `uart_tx` 直连时同理：busy 就是"串行线还在发上一字节"。
                    if (!tx_busy_i) begin
                        tx_start_o <= 1'b1;
                        tx_data_o  <= ech_data_c;
                        if (ech_last_c) begin
                            // ⭐ 帧尾（第 3 个 FF）已推 ⇒ 回 IDLE
                            ech_pos   <= 6'd0;
                            ech_state <= ECH_S_IDLE;
                        end else begin
                            ech_pos <= ech_pos + 6'd1;
                        end
                    end
                end
                default: ech_state <= ECH_S_IDLE;
            endcase

            // ══ ⭐⭐ 心跳节拍（⭐ 2026-10-29 新增：⭐ 周期置位 pend[22]）══
            //   📌 门控在 `hb_ready_o` 上：⭐ 握手前一个心跳都不发（⭐ 与状态回显同一纪律）
            //   📌 心跳 = `tm1.tim=1500`（⭐ 屏侧看门狗复位倒计时）⇒ 屏断联 1.5s 自动闪
            if (!hb_ready_o) begin
                hb_tmr_q <= 32'd0;
            end else if (hb_tmr_q >= HB_CLKS_I - 1) begin
                hb_tmr_q <= 32'd0;
                ech_pend[ECH_F_HB] <= 1'b1;   // ⭐ 最低优先级 ⇒ 不抢状态帧
            end else begin
                hb_tmr_q <= hb_tmr_q + 32'd1;
            end

            // ══ ⭐ 变化检测 + 置待发位（⭐ **后**执行：同拍「起帧清位」不会吃掉新变化）══
            //   📌 全部门控在 `hb_ready_o` 上：⭐ 握手前的变化由握手沿**一次性补发** ✅
            if (hb_ready_o) begin
                //  ⭐⭐ 2026-10-29 三件套-A：⭐ **首次握手沿 ∨ 0x88 重发请求** ⇒ 全量 ⭐⭐
                //   📌 重复收到 0x88（⭐ 屏切页返回）⇒ ⭐ 靠 `reflash_q` 再拿 47 帧新值 ✅
                if (!ech_hb_s || reflash_q) begin
                    // ⭐ 0x88 握手上升沿 ⇒ 56 个字段**全部**回显（屏上电初态）
                    //   ⭐ 2026-10-29 起重复收到 0x88 同样全量（⭐ 切页返回刷新）
                    //   ⭐ 2026-10-31 起新增 48..56 共 9 帧一并全量
                    ech_pend <= 60'hFFF_FFFF_FFBF_FFFF;  // ⭐ bit22（心跳）⛔ 不随握手置位：⭐ 由计时器首发
                    reflash_q <= 1'b0;        // ⭐ 重发请求自清（⭐ 单拍语义）
                    // ⭐ 同步全部镜像（⭐ 吸收握手前堆积的变化 ⇒ 随后不重复触发）
                    ech_mode_s   <= mode_o;
                    ech_test_s   <= test_mode_o;
                    ech_testn_s  <= test_mode_n_o;
                    ech_base_s   <= base_semi_o;
                    ech_timbre_s <= st_timbre_c;
                    ech_trans_s  <= st_trans_c;
                    ech_slide_s  <= st_slide_c;
                    ech_bpm_s    <= st_bpm_c;
                    ech_drum_s   <= st_drum_c;
                    ech_loop_s   <= st_loop_c;
                    ech_kd_s     <= st_kd_c;
                    ech_vol_s    <= st_vol_c;
                    ech_pedal_s  <= st_pedal_c;
                    ech_gear_s   <= st_gear_c;
                    ech_scope_s  <= st_scope_c;
                    ech_pvib_s   <= st_pvib_c;
                    ech_vvib_s   <= st_vvib_c;
                    ech_fxmask_s <= st_fxmask_c;
                    // ⭐⭐ 2026-10-31：同步新字段镜像（⭐ 吸收握手前堆积的变化）
                    ech_uplink_s <= uplink_sw_o;
                    ech_prate_s  <= st_prate_c;
                    ech_vrate_s  <= st_vrate_c;
                    // ⭐⭐ 2026-11-01：同步队友新增字段镜像
                    ech_lock_s    <= st_lock_c;
                    ech_nactive_s <= st_nactive_c;
                    // ⭐⭐ 2026-10-29 晚（§八-3）：同步 page1 镜像（⭐ 吸收握手前堆积的变化）
                    ech_fxg_s    <= fx_gain_o;
                    ech_fxt_s    <= fx_trim_o;
                    ech_mix_s    <= fx_mix_o;
                    ech_fb_s     <= fx_fb_o;
                    ech_rate_s   <= fx_rate_o;
                    ech_dl_s     <= fx_dlylen_o;
                    ech_cl_s     <= fx_chorlen_o;
                    ech_parsel_s <= par_sel_c;
                end else begin
                    // ⭐ 逐字段变化检测（⭐ 只盯值 ⇒ ⭐ 触摸/串口/按键全走这一条路）
                    if (mode_o != ech_mode_s) begin
                        ech_pend[ECH_F_MODE] <= 1'b1;  ech_mode_s <= mode_o;
                    end
                    if ((test_mode_o != ech_test_s) || (test_mode_n_o != ech_testn_s)) begin
                        ech_pend[ECH_F_TEST] <= 1'b1;
                        ech_test_s  <= test_mode_o;
                        ech_testn_s <= test_mode_n_o;
                    end
                    if (base_semi_o != ech_base_s) begin
                        ech_pend[ECH_F_BASE] <= 1'b1;  ech_base_s <= base_semi_o;
                    end
                    if (st_timbre_c != ech_timbre_s) begin
                        ech_pend[ECH_F_TIMB] <= 1'b1;  ech_timbre_s <= st_timbre_c;
                    end
                    if (st_trans_c != ech_trans_s) begin
                        ech_pend[ECH_F_TRAN] <= 1'b1;  ech_trans_s <= st_trans_c;
                    end
                    if (st_slide_c !== ech_slide_s) begin
                        // ⭐⭐ 2026-10-31：文本 t_slide + 状态灯 p_slide **同源** ⇒ 双挂起
                        ech_pend[ECH_F_SLIDE]  <= 1'b1;
                        ech_pend[ECH_F_PSLIDE] <= 1'b1;
                        ech_slide_s <= st_slide_c;
                    end
                    if (st_bpm_c != ech_bpm_s) begin
                        ech_pend[ECH_F_BPM] <= 1'b1;  ech_bpm_s <= st_bpm_c;
                    end
                    if (st_drum_c != ech_drum_s) begin
                        // ⭐⭐ 2026-11-01：文案 + 背景色 bco **同源** ⇒ 双挂起
                        ech_pend[ECH_F_DRUM]    <= 1'b1;
                        ech_pend[ECH_F_DRUMBCO] <= 1'b1;
                        ech_drum_s <= st_drum_c;
                    end
                    if (st_loop_c != ech_loop_s) begin
                        // ⭐⭐ 2026-10-29 晚（§八-2）：文案 + 三态配色**同源** ⇒ 三挂起
                        ech_pend[ECH_F_LOOP]   <= 1'b1;
                        ech_pend[ECH_F_LOOPBCO] <= 1'b1;
                        ech_pend[ECH_F_LOOPPCO] <= 1'b1;
                        ech_loop_s <= st_loop_c;
                    end
                    if (st_kd_c !== ech_kd_s) begin
                        ech_pend[ECH_F_KD] <= 1'b1;  ech_kd_s <= st_kd_c;
                    end
                    if (st_vol_c != ech_vol_s) begin
                        // ⭐ 主音量：文本 `t_vol` 与进度条 `j_vol.val` **同源** ⇒ 双挂起
                        ech_pend[ECH_F_VOL]  <= 1'b1;
                        ech_pend[ECH_F_JVOL] <= 1'b1;
                        ech_vol_s <= st_vol_c;
                    end
                    if (st_pedal_c !== ech_pedal_s) begin
                        // ⭐⭐ 2026-11-01：文案 + 背景色 bco **同源** ⇒ 双挂起（踩下=红）
                        ech_pend[ECH_F_PEDAL]    <= 1'b1;
                        ech_pend[ECH_F_PEDALBCO] <= 1'b1;
                        ech_pedal_s <= st_pedal_c;
                    end
                    if (st_gear_c != ech_gear_s) begin
                        // ⭐⭐ 2026-10-29 晚（§八-3）：t_gear 与 page1 短文本 gr **同源** ⇒ 双挂起
                        ech_pend[ECH_F_GEAR] <= 1'b1;
                        ech_pend[ECH_F_GR]   <= 1'b1;
                        ech_gear_s <= st_gear_c;
                    end
                    if (st_scope_c != ech_scope_s) begin
                        ech_pend[ECH_F_HDMI] <= 1'b1;  ech_scope_s <= st_scope_c;
                    end
                    if (st_pvib_c != ech_pvib_s) begin
                        // ⭐⭐ 2026-10-31：音高颤音深度四挂起（+j_pd 进度条）
                        ech_pend[ECH_F_PD]   <= 1'b1;
                        ech_pend[ECH_F_ZPD]  <= 1'b1;
                        ech_pend[ECH_F_TPDV] <= 1'b1;
                        ech_pend[ECH_F_JPD]  <= 1'b1;
                        ech_pvib_s <= st_pvib_c;
                    end
                    if (st_vvib_c != ech_vvib_s) begin
                        ech_pend[ECH_F_VD]   <= 1'b1;
                        ech_pend[ECH_F_ZVD]  <= 1'b1;
                        ech_pend[ECH_F_TVDV] <= 1'b1;
                        ech_pend[ECH_F_JVD]  <= 1'b1;
                        ech_vvib_s <= st_vvib_c;
                    end
                    if (st_fxmask_c != ech_fxmask_s) begin
                        // ⭐⭐ 2026-10-29 晚（§八-4）：三个灯文本 + 三个状态灯 .val **同源** ⇒ 六挂起
                        ech_pend[ECH_F_DIST]   <= 1'b1;
                        ech_pend[ECH_F_CHOR]   <= 1'b1;
                        ech_pend[ECH_F_DLY]    <= 1'b1;
                        ech_pend[ECH_F_LEDD]   <= 1'b1;
                        ech_pend[ECH_F_LEDC]   <= 1'b1;
                        ech_pend[ECH_F_LEDDLY] <= 1'b1;
                        ech_fxmask_s <= st_fxmask_c;
                    end
                    // ⭐⭐ 2026-10-29 晚（§八-3）：page1 动态字段
                    //   （⭐ fx 寄存器就是数据源：串口帧 / EC11 写回都会触发这一条路 ✅）
                    if (fx_gain_o != ech_fxg_s) begin
                        // ⭐ 失真增益：仪表 z_dg + 文本 t_dg_val 同源 ⇒ 双挂起
                        ech_pend[ECH_F_ZDG] <= 1'b1;
                        ech_pend[ECH_F_TDG] <= 1'b1;
                        ech_fxg_s <= fx_gain_o;
                    end
                    if (fx_trim_o != ech_fxt_s) begin
                        ech_pend[ECH_F_ZDT] <= 1'b1;
                        ech_pend[ECH_F_TDT] <= 1'b1;
                        ech_fxt_s <= fx_trim_o;
                    end
                    if (fx_mix_o != ech_mix_s) begin
                        ech_pend[ECH_F_ZMX] <= 1'b1;
                        ech_pend[ECH_F_TMX] <= 1'b1;
                        ech_mix_s <= fx_mix_o;
                    end
                    if (fx_fb_o != ech_fb_s) begin
                        ech_pend[ECH_F_ZLF] <= 1'b1;
                        ech_pend[ECH_F_TLF] <= 1'b1;
                        ech_fb_s <= fx_fb_o;
                    end
                    if (fx_rate_o != ech_rate_s) begin
                        // ⭐ 颤音速率：z_pr/z_vr/t_pr_val/t_vr_val **四帧同源** ⇒ 四挂起
                        ech_pend[ECH_F_ZPR] <= 1'b1;
                        ech_pend[ECH_F_ZVR] <= 1'b1;
                        ech_pend[ECH_F_TPR] <= 1'b1;
                        ech_pend[ECH_F_TVR] <= 1'b1;
                        ech_rate_s <= fx_rate_o;
                    end
                    if (fx_dlylen_o != ech_dl_s) begin
                        ech_pend[ECH_F_ZLL] <= 1'b1;
                        ech_pend[ECH_F_TLL] <= 1'b1;
                        ech_dl_s <= fx_dlylen_o;
                    end
                    if (fx_chorlen_o != ech_cl_s) begin
                        ech_pend[ECH_F_ZCL] <= 1'b1;
                        ech_pend[ECH_F_TCL] <= 1'b1;
                        ech_cl_s <= fx_chorlen_o;
                    end
                    if (par_sel_c != ech_parsel_s) begin
                        // ⭐ EC11 选参变化 ⇒ cur 文本（⭐ 参数号与 0x11..0x18 对齐）
                        ech_pend[ECH_F_CUR] <= 1'b1;
                        ech_parsel_s <= par_sel_c;
                    end
                    // ⭐⭐ 2026-10-31：《控件位置清单》新字段变化检测 ──────────────────
                    if (st_prate_c != ech_prate_s) begin
                        // ⭐ 音高颤音速率：文本 `t_pr` + 进度条 `j_pr.val` 同源 ⇒ 双挂起
                        ech_pend[ECH_F_PRATE] <= 1'b1;
                        ech_pend[ECH_F_JPR]   <= 1'b1;
                        ech_prate_s <= st_prate_c;
                    end
                    if (st_vrate_c != ech_vrate_s) begin
                        // ⭐ 音量颤音速率：文本 `t_vr` + 进度条 `j_vr.val` 同源 ⇒ 双挂起
                        ech_pend[ECH_F_VRATE] <= 1'b1;
                        ech_pend[ECH_F_JVR]   <= 1'b1;
                        ech_vrate_s <= st_vrate_c;
                    end
                    if (uplink_sw_o !== ech_uplink_s) begin
                        // ⭐ b_uplink 触摸翻转 ⇒ `● 实时上行: 开启/关闭` 回显
                        ech_pend[ECH_F_UPL] <= 1'b1;
                        ech_uplink_s <= uplink_sw_o;
                    end
                    if (beat_c != ech_beat_s) begin
                        // ⭐ 节拍脉冲上升沿 ⇒ p_bpm 橙点翻转（⭐ 高电平多拍也只翻一次）
                        if (beat_c) begin
                            beat_dot_s <= ~beat_dot_s;
                            ech_pend[ECH_F_PBEAT] <= 1'b1;
                        end
                        ech_beat_s <= beat_c;
                    end
                    // ⭐⭐ 2026-11-01 队友新增字段变化检测 ──────────────────────
                    if (st_lock_c !== ech_lock_s) begin
                        ech_pend[ECH_F_LOCK] <= 1'b1;
                        ech_lock_s <= st_lock_c;
                    end
                    if (st_nactive_c != ech_nactive_s) begin
                        ech_pend[ECH_F_TEST] <= 1'b1;
                        ech_nactive_s <= st_nactive_c;
                    end
                end
            end
            ech_hb_s <= hb_ready_o;
        end
    end

endmodule

`default_nettype wire
