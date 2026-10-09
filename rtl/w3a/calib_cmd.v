`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// calib_cmd.v · 标定命令解析（⭐ 单字母 ASCII，⭐ 电脑直连 USB-TTL）
//
// ── ⭐⭐ 协议（⭐ 用户 2026-09-23 拍板 + 深夜确认）────────────────────────────
//   | 字母 | 十六进制 | 动作 | ⭐ 语义 |
//   |---|---|---|---|
//   | `'T'` | `0x54` | ⭐ **逐轴 `tare`**（全部 16 轴） | 重新记零点 = 松手位 |
//   | `'S'` | `0x53` | ⭐ **逐轴 `span`**（全部 16 轴） | 逐个按到底 ⇒ 满行程标定 |
//   | `'X'` | `0x58` | ⭐ **取消** | 中止当前标定（⭐ 任意状态可退） |
//   | `'M'` | `0x4D` | ⭐ **Test Mode 循环** | 关 → 4 → 8 → 16 → 32 → 关 |
//
//   ⭐ **谁定义了这个协议**：⭐ **FPGA 侧** —— ⚠️ ESP32 侧已明确
//      *"标定命令是你们的协议，由你们定义（⛔ 不需要问我们）"*。
//      📌 依据：`<同级>/FPGA2026-esp32/files/20-代码/ESP32侧串口命令格式-给FPGA侧-20260923.md`
//         §1.3/§1.2（⭐ 且对方已**撤回**原 `0x53` 帧头方案）。
//
//   ⚠️ **接线事实**：⭐ 标定阶段是 **PC ──USB-TTL/板载 USB-C──> FPGA**，
//      ⛔ **不经过 ESP32**（⭐ 依据同上 §1.1）。
//      ⇒ ⭐ 本模块接的是**板载 `FPGA_UART`**（`V14`/`U15`，经 `BL616` 桥到 USB-C）。
//
// ── ⭐⭐ 为什么是"单字母"而不是帧 ──────────────────────────────────────────────
//   ⭐ **不占用 `evt_uart_rx` 的帧格式**：⭐ 事件帧是 `0xA5` + 8 字节（9N 对齐），
//      ⚠️ 而单字母命令**不是 `0xA5`** ⇒ ⭐ `evt_uart_rx` 会在"第 0 字节位置"
//      判 `hdr_err` 并**留在 `idx=0` 继续等** ⇒ ⭐ **两者天然共存、⛔ 不误同步**。
//      📌 依据：`evt_uart_rx.v:175-187`（⭐ "只在第 0 字节位置看帧头"）。
//   ⚠️ **代价（⭐ 诚实说明）**：⭐ 命令会让 `evt_uart_rx.hdr_err_cnt_o` **+1**
//      ⇒ ⭐ 上板时**看到该计数上涨是正常的**（⛔ 不是故障）。
//
// ── 🔴🔴 本模块的核心难点：⭐ 命令不能与"正在跑的事件帧"交错 ────────────────────
//   ⚠️ 两个模块接**同一个** `uart_rx` 的 `rx_done_i`/`rx_data_i`
//      ⇒ ⭐ 我们必须**自己判断"这个字节是不是给我的"**。
//   ⭐ 判据：⭐ **只认"自己是一个完整帧的第 0 字节"位置的字母** ——
//      ⚠️ 但 `calib_cmd` **看不到 `evt_uart_rx` 内部的 `idx`**。
//   ⇒ ⭐ **做法**：⭐ 跟踪 `0xA5` 帧的边界（⭐ 本模块自带一个极简的同步计数器）：
//      · 见到 `0xA5` ⇒ ⭐ 进入"帧内"状态、⭐ 数 8 个后续字节
//      · ⭐ **帧内出现的 `'T'`/`'S'`/`'X'` ⇒ ⛔ 一律忽略**（⭐ 它们是**载荷**！）
//      · ⭐ **帧外**（`idx==0` 位置）出现的字母 ⇒ ✅ 才是命令
//   🔴 **为什么必须这样**：⚠️ 事件载荷里**完全可能出现** `0x54`/`0x53`/`0x58`
//      （⭐ 比如 `vel=0x54` 或 `tick` 的某个字节）
//      ⇒ 🔴 **不做边界跟踪 ⇒ 曲谱灌入时会被误当成标定命令**（⭐ 灾难性）。
//      📌 这与 `evt_uart_rx` 的"不做任意位置扫描"是**同一条纪律**。
//
//   ⭐ **空闲归位**（⭐ 自愈，⭐ 与 `evt_uart_rx` 同思路）：
//      ⚠️ 若在"帧内"长时间没有新字节 ⇒ ⭐ 强制回到"帧外"
//      ⇒ ⭐ PC 崩在半帧中间也**不会永久卡死**。
//      ⚠️ `GAP_BYTES` 必须**足够宽**（⭐ 容忍 USB/蓝牙分块投递），
//         且 ⭐ **应与 `evt_uart_rx.GAP_BYTES` 同值**（⭐ 两者对"帧"的理解要一致）。
//
// ── ⭐ 输出：单拍脉冲（⭐ 直接给下游当触发源）─────────────────────────────────
//   ⭐ `tare_req_o` → `calib_autotare.retrig_i`
//   ⭐ `span_req_o` → `calib_span.start_i`
//   ⭐ `abort_req_o` → `calib_span.abort_i`
//   ⚠️ 2026-10-03 更正：本段原来写"**三个**单拍脉冲" —— 🔴 **早就不是三个了**
//      （⭐ `P`/`V`/`N`/`M`/`R`/`L`/`C`/`I`/`B`/`D`/`K` ＋ ⭐ `P2` 的 `F`/`G`/`H`/`J`
//      ⇒ ⭐ 现在共 **18 条命令**，⭐ 其中 `'H'` 还**带一个载荷值**）✅
//      📌 逐条的语义**只写在各自的 `parameter` 声明处**（⛔ 不在此处重复维护）✅
//   ⭐ 纪律：⭐ **新命令一律做成单周期脉冲** ⇒ ⭐ 以后接推子/按键**只需产生同样的脉冲** ✅
//
// ── ⛔ 纪律（本项目血泪）──────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：用 SV 专有构造 ⇒ **整个模块被静默丢弃**）
//   · ⭐ **组合逻辑用 `assign`**（`L67`）
//   · ⭐ **参与算术的 wire 一律显式写位宽**（⚠️ 不写就是 1 位 ⇒ 截断）
//   · ⭐ **声明必须先于使用**（⚠️ 本项目踩过 "Unable to bind wire/reg"）
//   · ⭐ **任何"会失效"的路径都必须可观测**（`K-106`）——
//     本模块把"命令计数 / 帧内忽略 / 空闲归位"**全做成计数器**，⛔ 不静默
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module calib_cmd #(
    parameter integer CLK_HZ    = 50000000,   // ⭐ 50 MHz（冻结表约定 1：单时钟域）
    // ⭐ 必须与 `uart_rx.BAUD_DIV` / `evt_uart_rx.BAUD` 一致。
    //   🔴 **2026-10-01 更正：本默认值（1 Mbps）⛔ 不是实际波特率** ——
    //      ⭐ `top.v` 例化时传的是 **`500_000`**（`rtl/top.v:785` / `:831`）⇒ ⭐ **以 500000 为准**。
    //      ⚠️ 照这个默认值去配串口助手会收到**乱码、而且不报错**（`bringup/16:26`）。
    parameter integer BAUD      = 1000000,
    // ⭐ 空闲归位阈值（单位：字节时间）
    //   ⚠️ **应与 `evt_uart_rx.GAP_BYTES` 同值** —— ⭐ 两者对"帧边界"的判断要一致，
    //      否则会出现"一个认为已归位、另一个还在帧内"的**窗口错配**。
    parameter integer GAP_BYTES = 16,
    parameter [7:0]   HEADER    = 8'hA5,      // ⭐ 与 `evt_uart_rx` 同一魔数

    // ⭐⭐ 四个命令字母（⭐ 提成参数 ⇒ ⭐ tb 可改、⭐ 也便于以后换协议）
    //   🔴 2026-09-24 新增 `CMD_PROBE = 'P'` —— ⭐ **诊断用**：
    //      ⚠️ 起因：⭐ 上板跑 `'S'`（span）时**只回 `s` + `!`，⭐ 轴号只出一次**
    //      ⇒ ⭐ 需要【看到实时 `pos` 读数】才能判断"稳定判定为什么过不去"
    //      📌 设计：⭐ 发 `'P'` ⇒ ⭐ 回当前 `calib_span.cur_axis` 的
    //         **原始码（`af0_pol`，3 位十进制）**
    parameter [7:0]   CMD_TARE  = 8'h54,      // 'T'
    parameter [7:0]   CMD_SPAN  = 8'h53,      // 'S'
    parameter [7:0]   CMD_ABORT = 8'h58,      // 'X'
    parameter [7:0]   CMD_PROBE = 8'h50,      // 'P' ⭐ 诊断：⭐ 回传 pos 读数
    parameter [7:0]   CMD_VSTAT = 8'h56,      // 'V' ⭐ 诊断：⭐ 回传 span 内部状态（⭐ 2026-09-24）
    // ⭐ T43：复用板载 USB-C 串口作为 Test Mode 的实体入口。
    // 只输出一次单拍请求；4/8/16/32/关的状态机属于 top.v，避免解析器
    // 自己保留另一份模式状态而与实际音频链失去一致。
    parameter [7:0]   CMD_TEST_MODE = 8'h4D,  // 'M'
    // ⭐⭐ 2026-09-27 新增 `'N'` —— ⭐ **诊断：回传【标定后的 `pos`】**
    //   🔴 **为什么必须再加一条**（⭐ 上板实测）：
    //      · ⭐ `'P'` 回的是 `af0_pol`（⭐ **极性校正后的【原始码】**）
    //      · 🔴 而 `event_extract` 判键用的是 **`pos`（`calib` 后的行程）**
    //      ⇒ ⚠️ 看原始码**推断不出** `pos`：`pos = (raw − zero) × gain >> 8`
    //         ⭐ 而 `zero` **只在上电 `tare` 时写一次** ⇒ 🔴 基准漂移看不出来
    //   ⭐ 三个待查症状都卡在"看不到 `pos`"上：
    //      ① 挂音 —— 松手后 `pos` 能否降到 `REL_TH`(80) 以下？
    //      ② 周期性音量起伏 —— 按住时 `pos` 是否周期性变化？
    //      ③ `zero` 是否有效 —— 松手时 `pos` 应 ≈ 0（⭐ 而不是 ~2000）
    parameter [7:0]   CMD_POSPROBE = 8'h4E,  // 'N' ⭐ 诊断：回传 calib 后的 pos
    // ⭐⭐ 2026-09-29 新增：⭐ **looper 的三条命令**（⭐ `T37` / `T39`）
    //
    //   ⭐ **为什么用串口而不是按键**：
    //      · ⭐ 串口通路**已经在跑**（⭐ 上位机 / ESP32 线都通了）⇒ ⭐ **零新增硬件**
    //      · ⭐ ⛔ **不改任何已有模块的【行为】** —— ⭐ 只是**加**命令字母 ✅
    //      · ⚠️ `met_btn_i`（`AB13`）**已给节拍器**，⭐ 而 `Y12` **被 ESP32 线预定** ⇒ ⛔ 不动按键
    //      📌 这也是 `looper接口定义-20260924.md` §五 第 3 条**自己的建议** ✅
    //
    //   ⚠️ **已占用的字母**：⭐ `T`(54) `S`(53) `X`(58) `P`(50) `V`(56) `M`(4D) `N`(4E)
    //      ＋ ⭐ 帧头 `0xA5` ⇒ ⭐ 新增的三个与之**互不相同**（⭐ 由下面的查重保证）✅
    parameter [7:0]   CMD_LOOP_REC  = 8'h52,  // 'R' ⭐ looper：⭐ 录 / 停 **切换**
    parameter [7:0]   CMD_LOOP_PLAY = 8'h4C,  // 'L' ⭐ looper：⭐ 播放 **切换**
    parameter [7:0]   CMD_LOOP_CLR  = 8'h43,  // 'C' ⭐ looper：⭐ 清空该层
    //  ⭐⭐ 2026-09-29 新增：⭐ **`'I'` 切换音色**（⭐ 用户需求："之后需要有 4 个音色可以切换" ✅）
    //   ⭐ 语义：⭐ **每按一次循环下一档** `0→1→2→3→0`（⭐ 与 `'R'`/`'L'` 同一"切换"手法 ✅）
    //   ⭐ 音色定义（⭐ `wavetable_bank.v:3` 原文）：
    //      ⭐ `0=BASS triangle` · ⭐ `1=GUITAR saw` · ⭐ `2=PIANO zero-DC 25% pulse` · ⭐ `3=PAD`
    //   📌 ⭐ **为什么用串口而不是物理按键**：⭐ 见本文件顶部"控制面"说明 ——
    //      ⭐ `*_req_o` 都是**单周期脉冲** ⇒ ⭐ 以后接按键**只需产生同样的脉冲** ✅
    //      ⇒ ⭐ **控制面与来源解耦**，⭐ 换来源**不用改 `calib_cmd` 的下游** ✅
    //   ⚠️ 字母占用核对：⭐ 已用 `T S X P V M N R L C` ＋ 帧头 `A5`
    //      ⇒ ⭐ `'I'` = `0x49` **未占用** ✅（⭐ `initial` 里的查重表会机械核对 ✅）
    parameter [7:0]   CMD_TIMBRE   = 8'h49,   // 'I' ⭐ 切音色（⭐ 0→1→2→3→0 循环）
    //  ⭐⭐ 2026-09-29 合并（⭐ 用户裁定 = 方案 B）：⭐ **节拍器改走串口 `'B'`** ✅
    //   ⭐ 因为 `AB13`/S2 让给了**音色切换按键**（⭐ 队友的 `timbre_btn_i` ✅）
    //   ⭐ 语义与原来的物理按键**完全一致**：⭐ 发一次 **开**、再发一次 **关** ✅
    parameter [7:0]   CMD_METRONOME = 8'h42,   // 'B' ⭐ 节拍器 **开/关切换**
    //  ⭐⭐ 2026-09-29 新增：⭐ **`'D'` 切鼓机节奏型**（⭐ 用户需求："鼓机节奏型要能现场切" ✅）
    //   ⭐ 语义：⭐ **每按一次循环下一档** `0→1→2→3→0`（⭐ 与 `'I'`/`'R'`/`'L'` 同一"切换"手法 ✅）
    //   ⭐ 节奏型定义（⭐ `drum_gen.v:step_mask_of` 原文）：
    //      ⭐ `0=Rock 四拍基本型` · ⭐ `1=八分摇滚` · ⭐ `2=十六分放克` · ⭐ `3=圆舞曲(3/4)`
    //   🔴 **为什么必须走串口**：⚠️ 它原来是**编译期参数 `DRUM_PATTERN_ID`**
    //      ⇒ ⭐ 换一个型要**重新 PnR + 烧写**（⭐ ~10 分钟）⇒ 🔴 **4 个型没法 A/B 对比**
    //      📌 而串口通路**已经在跑** ⇒ ⭐ **零新增硬件**（⭐ 与 `'I'`/`'B'` 同一理由 ✅）
    //   ⚠️ 字母占用核对：⭐ 已用 `T S X P V M N R L C I B` ＋ 帧头 `A5`
    //      ⇒ ⭐ `'D'` = `0x44` **未占用** ✅（⭐ `initial` 里的查重表会机械核对 ✅）
    //      📌 ⚠️ **注意**：⭐ `top.v` 的**回包**里 `0x44` 是"span 全部完成"的 `'D'`
    //         —— ⚠️ 那是 **TX 方向**，⭐ 与 **RX 方向**的命令**互不相干**（⛔ 不冲突）✅
    parameter [7:0]   CMD_DRUM_PATTERN = 8'h44,  // 'D' ⭐ 鼓机节奏型 **切下一个**
    // ⭐⭐ 2026-10-01 新增：⭐ **键盘打鼓模式**（⭐ 'K' ⇒ 单周期脉冲，⭐ 与 `'D'` 同构）
    //   ⭐ **语义**：⭐ 打开后**磁轴键盘不再发音高，而是当鼓垫** ——
    //      ⭐ 按键事件按 **`axis[3:2]`**（= `axis / 4`，⛔ **不是取余**）换成 4 件乐器之一：
    //         `axis 0~3` = 嗵鼓 · `4~7` = 底鼓 · `8~11` = 军鼓 · `12~15` = 踩镲
    //      🔴 **2026-10-01 更正**：旧注释写"按 `axis % 4`" ⇒ ⚠️ **错**，
    //         实际代码是 `key_drum_sel = src_a_axis[3:2]`（`rtl/top.v`，⭐ 两位切片、零逻辑）。
    //         两者结果**完全不同**：`axis % 4` 会让"每个轴组内 4 个键各发一件鼓"，
    //         而实际是"**每 4 个相邻轴 = 同一件鼓**"。
    //   ⭐ **与 4 个音色彻底解耦**：⭐ 打鼓用**固定的** `DRUM_TIMBRE`，
    //      ⛔ 不受"当前键盘音色"影响（⭐ 与源 B 同一手法 ✅）
    //   📌 **字母占用核对**：⭐ 已用 `T S X P V M N R L C I B D` ⇒ ⭐ `'K'` = `0x4B` **未占用** ✅
    //      （⭐ `initial` 里的查重表会机械核对 ✅）
    //   ⚠️ **`top.v` 回包侧**：⭐ 本命令的回包用 **`'k'`**（⭐ 小写），
    //      ⛔ 与 RX 方向的 `'K'` **互不相干**（⭐ 与 `'D'`/`0x44` 同一情形 ✅）
    parameter [7:0]   CMD_KEYDRUM    = 8'h4B,   // 'K' ⭐ 键盘打鼓模式 **开/关切换**
    // ⭐⭐ 2026-10-03 新增（⭐ `P2`）：⭐ **T3 变调控制面的四条命令**（⭐ `F`/`G`/`H`/`J`）
    //   📌 **依据**：⭐ `files/20-代码/T3-后续计划-20261003.md` §P2 ＋
    //      ⭐ `files/00-总览/T3变调与推子功能状态机-设计定稿-20261001.md` §四（档位表）✅
    //   ⭐ **为什么走串口**：⭐ 与 `'I'`/`'D'`/`'K'` **同一条理由** ——
    //      ⭐ 串口通路**已经在跑**（⭐ PC / ESP32 两条线都通）⇒ ⭐ **零新增硬件**；
    //      ⭐ 且本模块的输出**全是单周期脉冲** ⇒ ⭐ 以后接推子/按键**只需产生同样的脉冲**
    //      （⭐ 控制面与来源解耦 —— 见本文件顶部 `'I'` 处的同一说明 ✅）
    //   ⚠️ **字母占用核对**：⭐ 已用 `T S X P V M N R L C I B D K` ＋ ⭐ 帧头 `0xA5`
    //      ⇒ ⭐ `'F'`(46) · `'G'`(47) · `'H'`(48) · `'J'`(4A) **均未占用** ✅
    //      🔴 **⛔ 不要用 `'K'`(4B)** —— ⭐ 它**已被键盘打鼓模式占用**；
    //         用户实测：`8'h4B` 在旧代码里**有 1 处命中** ⇒ ⭐ 复用它会**静默遮蔽** ✅
    //      📌 下面的 `cmd_tab` 查重会**机械核对**（⭐ 加新字母**必须**往表里加一项）✅
    //   ⭐ **语义**（⭐ 用户 2026-10-03 裁定，⛔ 不要重新论证）：
    //      · ⭐ `'F'` = **降 1 半音**（⭐ **裸字母**、⭐ **可连发**）
    //      · ⭐ `'G'` = **升 1 半音**（⭐ **裸字母**、⭐ **可连发**）
    //      · ⭐ `'H'` = **带帧绝对量**：⭐ 先发**裸 `'H'`** 把它"臂化" ⇒
    //          ⭐ **下一帧**（⭐ 复用现有 9 字节帧 = `0xA5` + 8 字节）的
    //          **第一个载荷字节**就是半音值（⭐ **编码 `0..24`**，⭐ **`12` = 不调** ✅）
    //          ⚠️ 取走后**立刻清臂** ⇒ ⭐ 一次臂化**只吃一帧**（⛔ 不会污染后面的曲谱帧）
    //      · ⭐ `'J'` = **切档**（⭐ 推子功能档位，⭐ 供 `P3` 用）
    //          ⇒ ⭐ **本模块只出脉冲**，⭐ "当前档位"由 `top.v` 用寄存器记住 ✅
    parameter [7:0]   CMD_TRANS_DOWN = 8'h46,   // 'F' ⭐ 变调：降 1 半音（⭐ 单周期脉冲）
    parameter [7:0]   CMD_TRANS_UP   = 8'h47,   // 'G' ⭐ 变调：升 1 半音（⭐ 单周期脉冲）
    parameter [7:0]   CMD_TRANS_ABS  = 8'h48,   // 'H' ⭐ 变调：带帧绝对量（⭐ 臂化 ⇒ 下一帧载荷[0]）
    parameter [7:0]   CMD_GEAR_NEXT  = 8'h4A    // 'J' ⭐ 推子档位：切下一档（⭐ 供 `P3`）
) (
    input  wire        clk_i,
    input  wire        rst_n_i,        // ⭐ 同步复位、低有效

    // ── ⭐ 来自 `uart_rx.v` 的字节流（⭐ 与 `evt_uart_rx` 同源）─────────────
    input  wire        rx_done_i,      // ⭐ 收到一个字节（单周期脉冲）
    input  wire [7:0]  rx_data_i,      // ⭐ 该字节

    // ── ⭐ 命令脉冲（⭐ 单周期）────────────────────────────────────────────
    output reg         tare_req_o,     // ⭐ 'T' ⇒ 逐轴 tare
    output reg         span_req_o,     // ⭐ 'S' ⇒ 逐轴 span
    output reg         abort_req_o,    // ⭐ 'X' ⇒ 取消
    output reg         probe_req_o,    // ⭐ 'P' ⇒ 诊断：⭐ 回传 pos 读数（⭐ 2026-09-24 新增）
    output reg         vstat_req_o,    // ⭐ 'V' ⇒ 诊断：⭐ 回传 span 状态（⭐ 2026-09-24 新增）
    output reg         posprobe_req_o, // ⭐ 'N' ⇒ 诊断：⭐ 回传 calib 后的 pos（⭐ 2026-09-27 新增）
    output reg         test_mode_req_o,// ⭐ 'M' ⇒ Test Mode 下一档（帧外才有效）
    // ⭐⭐ 2026-09-29 新增：⭐ looper 控制（⭐ 三条命令都是**单周期脉冲**）
    //   ⚠️ 录/播是"**切换**"语义 ⇒ ⭐ `top.v` 用寄存器记住状态（⭐ 与 `met_on_r` 同一手法）
    output reg         loop_rec_req_o, // ⭐ 'R' ⇒ looper 录/停切换
    output reg         loop_play_req_o,// ⭐ 'L' ⇒ looper 播放切换
    output reg         loop_clear_req_o,// ⭐ 'C' ⇒ looper 清空该层
    output reg         timbre_req_o,    // ⭐ 'I' ⇒ 切音色（⭐ 0→1→2→3→0 循环，⭐ 2026-09-29 新增）
    output reg         met_req_o,       // ⭐ 'B' ⇒ 节拍器开/关切换（⭐ 2026-09-29 新增，方案 B）
    // ⭐⭐ 2026-09-29 新增：⭐ 鼓机节奏型切换（⭐ 'D' ⇒ 单周期脉冲）
    //   ⚠️ 与 `timbre_req_o`/`met_req_o` **同构**：⭐ "切换"语义 ⇒ ⭐ `top.v` 用寄存器记状态
    output reg         drum_pattern_req_o, // ⭐ 'D' ⇒ 鼓机节奏型 0→1→2→3→0（⭐ 2026-09-29 新增）
    // ⭐⭐ 2026-10-01 新增：⭐ 键盘打鼓模式开关（⭐ 'K' ⇒ 单周期脉冲）
    //   ⚠️ 与 `drum_pattern_req_o` **同构**：⭐ "切换"语义 ⇒ ⭐ `top.v` 用寄存器记状态 ✅
    output reg         keydrum_req_o,    // ⭐ 'K' ⇒ 键盘打鼓 **开/关切换**（⭐ 2026-10-01 新增）

    // ── ⭐⭐ 2026-10-03（`P2`）：⭐ **T3 变调控制面**（⭐ `F`/`G`/`H`/`J`）──────────
    //   ⚠️ 与 `drum_pattern_req_o`/`keydrum_req_o` **同构**：
    //      ⭐ 本模块**只出脉冲**，⭐ "当前半音值 / 当前档位"由 `top.v` 用寄存器记住 ✅
    //   📌 四个都是**单周期脉冲** ⇒ ⭐ 以后换成推子/按键**只需产生同样的脉冲** ✅
    output reg         trans_down_req_o, // ⭐ 'F' ⇒ 变调：降 1 半音
    output reg         trans_up_req_o,   // ⭐ 'G' ⇒ 变调：升 1 半音
    //   ⭐ 'H'：⭐ **脉冲 ＋ 数据** —— ⚠️ `trans_abs_val_o` 与 `trans_abs_req_o` **同拍有效**
    //      （⭐ 都在"第一个载荷字节"那一拍更新，⭐ 见下方 `idx_q == 4'd1` 段 ✅）
    output reg         trans_abs_req_o,  // ⭐ 'H' ⇒ 带帧绝对量：⭐ 值到达的那一拍
    output reg  [7:0]  trans_abs_val_o,  // ⭐ 'H' ⇒ 该帧**第一个载荷字节**（⭐ 编码 0..24）
    output reg         gear_next_req_o,  // ⭐ 'J' ⇒ 推子档位 **切下一档**（⭐ 供 `P3`）

    // ── ⭐ 可观测性（`K-106`：⛔ 不许静默失效）────────────────────────────
    output reg  [15:0] cmd_cnt_o,      // ⭐ 已接受的命令数（饱和）
    output reg  [15:0] in_frame_cnt_o, // ⭐ "帧内出现的命令字母"被忽略的次数（饱和）
    output reg  [15:0] resync_cnt_o,   // ⭐ 空闲归位次数（饱和）— ⚠️ 上板先看这个
    output wire [3:0]  idx_o,          // ⭐ 当前帧内位置（0 = 帧外/可收命令）
    output reg  [15:0] unknown_cnt_o   // ⚠️ 帧外收到的**非命令**字节数（⭐ 诊断用）
);

    // ── ⭐⭐ 换算成**定宽 localparam** 再参与运算 ─────────────────────────────
    //   🔴 **`K-91`：⛔ 绝不对 `integer` 参数做位选**（`GAP_I[19:0]` 这种）。
    //      ⚠️ 本项目踩过：对 `integer` 位选会让**整块索引比较静默失效**。
    //   ⭐ 正确做法：**先算 integer，再【赋值】给定宽 localparam**（⛔ 不是位选）。
    //  ⭐⭐ 2026-10-09（`P0-05`）：⭐ **`GAP_BYTES` 的单位是【字节】，⛔ 不是【位】** ✅
    //   🔴 **原缺陷**：⭐ `CLK_HZ / BAUD` 是**一个位**的时间（⭐ `BAUD` = bit/s）
    //      ⚠️ 原写 `BYTE_CLK_I = (CLK_HZ + BAUD/2) / BAUD` ⇒ ⭐ 名字叫 BYTE 但**值是 BIT**
    //      ⇒ ⭐ `GAP_CLK = 100 × 16 = 1600` 拍 = **32 µs** ⚠️ 而**一个字节**（8N1 = 10 位）
    //        在 500 kbaud 下是 **20 µs** ⇒ 🔴 **帧内容忍只有 1.6 个字节时间** ✅
    //      ⚠️ 而注释与设计意图都写"容忍 16 个字节时间（320 µs）、容忍 USB/蓝牙分块投递" ⇒ **差 10 倍** ✅
    //   🔴 **后果链（⭐ 为什么是 P0）**：⭐ `idx_q` 一旦被 >32 µs 的**帧内间隔**"空闲归位"清 0
    //      ⇒ ⭐ 剩下的载荷字节落在"帧外" ⇒ ⭐ 被当**命令** ✅
    //      ⭐ 18 个命令字母占 256 个字节值的 **7.0%**，⭐ 其中包含
    //      `'X'`（中止标定）· `'C'`（清 looper 层）· `'R'`（开始录音）· `'S'`（启动 span 标定）· `'M'`（切 Test Mode）
    //      ⇒ 🔴 **一次分块投递就能在演奏中途静默启动一次标定 / 清掉一层 loop** ✅
    //      （⭐ 这正是本模块存在的唯一理由 —— ⭐ 它自己 :39-42 写的"灾难性" ✅）
    //   📌 **触发条件（⭐ 诚实标注）**：⭐ 主机一次连续 `write()` 写完 9 字节 ⇒ ⭐ 桥芯片背靠背发
    //      ⇒ ⚠️ 帧内间隔 ≈ 0 ⇒ **不触发**；⭐ 但主机**分两次写**（`write(header)` + `write(payload)`）、
    //      逐字节写的脚本、⭐ 或 **USB-CDC 的 1 ms 帧边界**插进来 ⇒ ⭐ 间隔 **1 ms ≫ 32 µs** ⇒ 🔴 **必触发** ✅
    //   ✅ **修法**：⭐ 拆成"位时间"与"字节时间"两个量（⭐ 一个字节 = 10 位：1 起始 + 8 数据 + 1 停止）✅
    //      📌 位宽复核：⭐ 320 µs = **16000 拍** < `2^20−1` ⇒ ⭐ `[19:0] GAP_CLK` 够用 ✅
    //      ⚠️ **必须同步 `evt_uart_rx.v` 的同一公式**（⭐ 否则一个认为已归位、另一个还在帧内 ⇒ 窗口错配）✅
    localparam integer BIT_CLK_I  = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 【位】时间（⭐ 四舍五入）
    localparam integer BYTE_CLK_I = BIT_CLK_I * 10;             // ⭐ 【字节】时间 = 10 位（8N1）
    localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;     // ⭐ 16 字节 = 320 µs
    localparam [19:0]  GAP_CLK    = GAP_CLK_I;                  // ⭐ 赋值 ⇒ 自动截断
    localparam [3:0]   IDX_LAST   = 4'd8;                       // ⭐ 8 字节载荷

    // ── 状态 ───────────────────────────────────────────────────────────────
    //   ⭐ `idx_q` 语义与 `evt_uart_rx` **刻意保持一致**：
    //      0 = 帧外（⭐ 命令只能在这里被接受）；1..8 = 帧内第 N 个载荷字节
    reg [3:0]  idx_q;
    reg [19:0] idle_q;

    //   ⭐⭐ 2026-10-03（`P2`）：⭐ **`'H'` 的"臂化"标志**（⭐ 带帧绝对量的核心）
    //      ⭐ 语义：⭐ 帧外收到**裸 `'H'`** ⇒ 置 1 ⇒
    //         ⭐ **下一帧的第一个载荷字节**（`idx_q == 4'd1`）被取走当半音值 ⇒ ⭐ 取走后**立刻清 0**
    //      🔴 **为什么必须"一次性"**：⭐ 若臂一直挂着 ⇒
    //         ⚠️ 后面每一帧的第一个载荷字节都会被当半音值
    //         ⇒ 🔴 **曲谱灌入时变调值被乱改**（⭐ 与"帧内字母不触发"同一类灾难）✅
    //      ⭐ 另外两条清臂路径：⭐ 复位 · ⭐ 空闲归位（⭐ 半帧作废 ⇒ 臂一起作废，⛔ 不留悬空状态）✅
    reg abs_arm_q;

    assign idx_o = idx_q;

    // ⭐ 空闲是否已达阈值
    wire idle_expired = (idle_q >= GAP_CLK);

    // ⭐ 本字节是不是帧头
    wire byte_is_header = (rx_data_i == HEADER);

    // ⭐⭐ 四个命令字母的比对（⭐ 组合）
    wire byte_is_tare  = (rx_data_i == CMD_TARE);
    wire byte_is_span  = (rx_data_i == CMD_SPAN);
    wire byte_is_abort = (rx_data_i == CMD_ABORT);
    wire byte_is_probe = (rx_data_i == CMD_PROBE);   // ⭐ 'P' 诊断（⭐ 2026-09-24）
    wire byte_is_vstat = (rx_data_i == CMD_VSTAT);   // ⭐ 'V' 诊断（⭐ 2026-09-24）
    wire byte_is_posprobe = (rx_data_i == CMD_POSPROBE); // ⭐ 'N' 诊断（⭐ 2026-09-27）
    wire byte_is_test_mode = (rx_data_i == CMD_TEST_MODE); // ⭐ 'M' Test Mode
    // ⭐ 2026-09-29：looper 三条（⭐ 'R' / 'L' / 'C'）
    wire byte_is_loop_rec  = (rx_data_i == CMD_LOOP_REC);
    wire byte_is_loop_play = (rx_data_i == CMD_LOOP_PLAY);
    wire byte_is_loop_clr  = (rx_data_i == CMD_LOOP_CLR);
    // ⭐ 2026-09-29：⭐ 切音色（⭐ 'I'）
    wire byte_is_timbre    = (rx_data_i == CMD_TIMBRE);
    // ⭐⭐ 2026-09-29：⭐ 节拍器开/关（⭐ 'B'）—— 方案 B：⭐ `AB13`/S2 让给音色按键 ✅
    wire byte_is_met       = (rx_data_i == CMD_METRONOME);
    // ⭐⭐ 2026-09-29：⭐ 鼓机节奏型（⭐ 'D'）
    wire byte_is_drum_pat  = (rx_data_i == CMD_DRUM_PATTERN);
    // ⭐⭐ 2026-10-01：⭐ 键盘打鼓模式（⭐ 'K'）
    wire byte_is_keydrum   = (rx_data_i == CMD_KEYDRUM);
    // ⭐⭐ 2026-10-03（`P2`）：⭐ **T3 变调控制面**（⭐ 'F' / 'G' / 'H' / 'J'）
    wire byte_is_trans_down = (rx_data_i == CMD_TRANS_DOWN);
    wire byte_is_trans_up   = (rx_data_i == CMD_TRANS_UP);
    wire byte_is_trans_abs  = (rx_data_i == CMD_TRANS_ABS);
    wire byte_is_gear_next  = (rx_data_i == CMD_GEAR_NEXT);
    // ⭐ 任一命令字母
    wire byte_is_cmd   = byte_is_tare | byte_is_span | byte_is_abort |
                         byte_is_probe | byte_is_vstat | byte_is_posprobe |
                         byte_is_test_mode |
                         byte_is_loop_rec | byte_is_loop_play | byte_is_loop_clr |
                         byte_is_timbre | byte_is_met | byte_is_drum_pat |
                         byte_is_keydrum |
                         // ⭐ 2026-10-03（`P2`）：⭐ 四个新字母**必须**在这里 ⇒
                         //   ⚠️ 否则**帧内出现它们时 `in_frame_cnt_o` 不计数**
                         //      ⇒ 🔴 "边界跟踪在工作"的**证据就没了**（`K-106` 静默失效）
                         byte_is_trans_down | byte_is_trans_up |
                         byte_is_trans_abs | byte_is_gear_next;

    // ⭐ 只有在**帧外**（`idx_q == 0`）才认命令
    //   🔴 这是本模块的**安全核心** —— ⚠️ 帧内的字母是**载荷**，⛔ 绝不能当命令
    //   ⭐ 实现方式：⭐ 靠 `if (idx_q == 4'd0) ... else ...` 的**结构**保证，
    //      ⛔ **不是**靠一个 `cmd_here` 门控（⚠️ 我曾写过那样的 wire 但**没接**，
    //      结果是**死代码** —— ⭐ 变异测试实测：把它改掉**没有任何 tb 变红**）。
    //   📌 教训：⭐ **声明了没用的信号 = 纯噪声**，⚠️ 还会让人误以为它是守卫。

    // ⭐ 饱和自增（⚠️ ⛔ 不许回绕 —— 回绕会让"溢出"看起来像"刚清零"）
    function [15:0] sat_inc16;
        input [15:0] v;
        begin
            sat_inc16 = (v == 16'hFFFF) ? 16'hFFFF : (v + 16'd1);
        end
    endfunction

    // ── ⭐ 空闲计时器（⭐ 收到字节就清零，否则涨到阈值就停）──────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            idle_q <= 20'd0;
        end else if (rx_done_i) begin
            idle_q <= 20'd0;
        end else if (!idle_expired) begin
            idle_q <= idle_q + 20'd1;
        end
    end

    // ── ⭐ 主逻辑 ──────────────────────────────────────────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            idx_q          <= 4'd0;
            tare_req_o     <= 1'b0;
            span_req_o     <= 1'b0;
            abort_req_o    <= 1'b0;
            probe_req_o    <= 1'b0;     // ⭐ 'P' 诊断（⭐ 2026-09-24）
            vstat_req_o    <= 1'b0;     // ⭐ 'V' 诊断（⭐ 2026-09-24）
            posprobe_req_o <= 1'b0;     // ⭐ 'N' 诊断（⭐ 2026-09-27）
            test_mode_req_o<= 1'b0;     // ⭐ 'M' Test Mode
            loop_rec_req_o <= 1'b0;     // ⭐ 'R' looper 录/停（⭐ 2026-09-29）
            loop_play_req_o<= 1'b0;     // ⭐ 'L' looper 播放切换
            loop_clear_req_o<= 1'b0;    // ⭐ 'C' looper 清空
            timbre_req_o   <= 1'b0;     // ⭐ 'I' 切音色（⭐ 2026-09-29）
            met_req_o      <= 1'b0;     // ⭐ 'B' 节拍器开/关（⭐ 2026-09-29）
            drum_pattern_req_o <= 1'b0; // ⭐ 'D' 鼓机节奏型（⭐ 2026-09-29）
            keydrum_req_o  <= 1'b0;     // ⭐ 'K' 键盘打鼓模式（⭐ 2026-10-01）
            trans_down_req_o <= 1'b0;   // ⭐ 'F' 变调降半音（⭐ 2026-10-03 · P2）
            trans_up_req_o   <= 1'b0;   // ⭐ 'G' 变调升半音（⭐ 2026-10-03 · P2）
            trans_abs_req_o  <= 1'b0;   // ⭐ 'H' 带帧绝对量（⭐ 2026-10-03 · P2）
            trans_abs_val_o  <= 8'd0;   // ⭐ 'H' 的载荷值（⭐ 2026-10-03 · P2）
            gear_next_req_o  <= 1'b0;   // ⭐ 'J' 切档（⭐ 2026-10-03 · P2）
            abs_arm_q        <= 1'b0;   // ⭐ 'H' 臂化标志（⭐ 2026-10-03 · P2）
            cmd_cnt_o      <= 16'd0;
            in_frame_cnt_o <= 16'd0;
            resync_cnt_o   <= 16'd0;
            unknown_cnt_o  <= 16'd0;
        end else begin
            // ⭐ 默认：脉冲类输出**每拍清零** ⇒ 严格单周期
            tare_req_o  <= 1'b0;
            span_req_o  <= 1'b0;
            abort_req_o <= 1'b0;
            probe_req_o <= 1'b0;        // ⭐ 'P' 诊断（⭐ 2026-09-24）
            vstat_req_o <= 1'b0;        // ⭐ 'V' 诊断（⭐ 2026-09-24）
            posprobe_req_o <= 1'b0;     // ⭐ 'N' 诊断（⭐ 2026-09-27）
            test_mode_req_o <= 1'b0;    // ⭐ 'M' Test Mode
            loop_rec_req_o  <= 1'b0;    // ⭐ 'R'（⭐ 2026-09-29）
            loop_play_req_o <= 1'b0;    // ⭐ 'L'
            loop_clear_req_o<= 1'b0;    // ⭐ 'C'
            timbre_req_o    <= 1'b0;    // ⭐ 'I'（⭐ 2026-09-29）
            met_req_o       <= 1'b0;    // ⭐ 'B'（⭐ 2026-09-29）
            drum_pattern_req_o <= 1'b0; // ⭐ 'D'（⭐ 2026-09-29）
            keydrum_req_o      <= 1'b0; // ⭐ 'K'（⭐ 2026-10-01）
            trans_down_req_o   <= 1'b0; // ⭐ 'F'（⭐ 2026-10-03 · P2）
            trans_up_req_o     <= 1'b0; // ⭐ 'G'（⭐ 2026-10-03 · P2）
            trans_abs_req_o    <= 1'b0; // ⭐ 'H'（⭐ 2026-10-03 · P2）
            gear_next_req_o    <= 1'b0; // ⭐ 'J'（⭐ 2026-10-03 · P2）
            //   ⚠️ `trans_abs_val_o` **刻意不在这里清零** ——
            //      ⭐ 它是**数据**（⛔ 不是脉冲）：⭐ 清掉会让"值保持到下一帧"这个
            //      ⚠️ 隐含契约失效；⭐ 且清零会产生**无谓的翻转**（⭐ 上板看不出区别，
            //      ⚠️ 但会让 `trans_abs_val_o` 在脉冲之外**忽 0 忽值**）✅

            if (rx_done_i) begin
                // ══ 收到一个字节 ═══════════════════════════════════════════
                if (idx_q == 4'd0) begin
                    // ---- ⭐ 帧外：这里**只可能**是帧头或命令 ---------------
                    if (byte_is_header) begin
                        // ⭐ 事件帧开始 ⇒ ⭐ 进入帧内，⛔ 之后 8 个字节一律不认命令
                        idx_q <= 4'd1;
                    end else if (byte_is_cmd) begin
                        // ⭐⭐ 命令（⭐ 帧外 ⇒ 安全）
                        //   ⚠️ **互斥**：一次只可能命中一个（⭐ 四个字母互不相同）
                        //   ⭐ 四者的下游都有"忙"保护 ⇒ ⛔ 不会互相打架。
                        if (byte_is_tare)  tare_req_o  <= 1'b1;
                        if (byte_is_span)  span_req_o  <= 1'b1;
                        if (byte_is_abort) abort_req_o <= 1'b1;
                        if (byte_is_probe) probe_req_o <= 1'b1;   // ⭐ 'P' 诊断
                        if (byte_is_vstat) vstat_req_o <= 1'b1;   // ⭐ 'V' 诊断
                        if (byte_is_posprobe) posprobe_req_o <= 1'b1; // ⭐ 'N' 诊断
                        if (byte_is_test_mode) test_mode_req_o <= 1'b1;
                        // ⭐ 2026-09-29：looper 三条（⭐ 帧外 ⇒ 安全）
                        if (byte_is_loop_rec)  loop_rec_req_o  <= 1'b1;
                        if (byte_is_loop_play) loop_play_req_o <= 1'b1;
                        if (byte_is_loop_clr)  loop_clear_req_o<= 1'b1;
                        // ⭐ 2026-09-29：⭐ 切音色（⭐ 帧外 ⇒ 安全）
                        if (byte_is_timbre)    timbre_req_o    <= 1'b1;
                        if (byte_is_met)       met_req_o       <= 1'b1;   // ⭐ 'B'（⭐ 2026-09-29）
                        // ⭐ 2026-09-29：⭐ 鼓机节奏型（⭐ 帧外 ⇒ 安全）
                        if (byte_is_drum_pat)  drum_pattern_req_o <= 1'b1;
                        // ⭐⭐ 2026-10-01：⭐ 键盘打鼓模式（⭐ 帧外 ⇒ 安全）
                        //   ⭐ 与 `'D'` 同构：⭐ "切换"语义 ⇒ ⭐ `top.v` 用寄存器记状态 ✅
                        if (byte_is_keydrum)   keydrum_req_o      <= 1'b1;
                        // ⭐⭐ 2026-10-03（`P2`）：⭐ **T3 变调控制面**（⭐ 帧外 ⇒ 安全）
                        //   ⭐ `'F'`/`'G'`/`'J'` = **纯脉冲**（⭐ 与 `'D'`/`'K'` 同构）
                        if (byte_is_trans_down) trans_down_req_o <= 1'b1;
                        if (byte_is_trans_up)   trans_up_req_o   <= 1'b1;
                        if (byte_is_gear_next)  gear_next_req_o  <= 1'b1;
                        //   ⭐ `'H'` = **臂化**（⛔ 本拍**不出脉冲**）——
                        //      ⭐ 值在**下一帧的第一个载荷字节**那一拍才出（⭐ 见下方帧内段）
                        //      📌 所以"发 `'H'` 就立刻变调"是**错的预期**：
                        //         ⭐ 必须 `'H'` ＋ ⭐ 紧跟一帧（`0xA5` + 8 字节）才生效 ✅
                        if (byte_is_trans_abs)  abs_arm_q        <= 1'b1;
                        cmd_cnt_o <= sat_inc16(cmd_cnt_o);
                        idx_q     <= 4'd0;      // ⭐ 命令不推进帧位置
                    end else begin
                        // ⚠️ 帧外的其他字节（⭐ 比如 PC 敲的回车/换行）
                        //   ⭐ **无害**，但⭐ **必须可观测** ⇒ 计数，⛔ 不静默
                        unknown_cnt_o <= sat_inc16(unknown_cnt_o);
                        idx_q         <= 4'd0;
                    end
                end else begin
                    // ---- ⭐ 帧内：⭐ 这些字节是【载荷】，⛔ 绝不当命令 -------
                    if (byte_is_cmd) begin
                        // 🔴 载荷里出现了命令字母 ⇒ ⭐ **忽略它**，但⭐ 记账
                        //    ⚠️ 这段计数是"边界跟踪真的在工作"的**证据**
                        in_frame_cnt_o <= sat_inc16(in_frame_cnt_o);
                    end
                    // ⭐⭐ 2026-10-03（`P2`）：⭐ **`'H'` 的带帧绝对量**（⭐ 复用现有 9 字节帧）
                    //   ⭐ 位置：⭐ `idx_q == 4'd1` = **第一个载荷字节**（⭐ 紧跟 `0xA5` 那一个）✅
                    //   🔴 **必须在"已臂化"（`abs_arm_q`）时才取** ——
                    //      ⚠️ 否则**普通事件帧**（⭐ 曲谱！）的第一个载荷字节会被当成半音值
                    //      ⇒ 🔴 **灌曲谱时变调值被乱改**（⭐ 与"帧内字母不触发"同一类灾难）✅
                    //   ⭐ 取走后**立刻清臂** ⇒ ⭐ 一次臂化只吃一帧 ✅
                    //   📌 帧内出现的 `'H'`（⭐ 载荷字节 == 0x48）⛔ **不会**再臂化 ——
                    //      ⭐ 因为置臂只写在上面"帧外"分支里（⭐ 靠 `if (idx_q == 4'd0)` 的
                    //      **结构**保证，⛔ 不是靠一个可能被漏接的门控 wire —— 见上方注释 ✅）
                    if ((idx_q == 4'd1) && abs_arm_q) begin
                        trans_abs_val_o <= rx_data_i;
                        trans_abs_req_o <= 1'b1;
                        abs_arm_q       <= 1'b0;
                    end
                    if (idx_q == IDX_LAST) begin
                        idx_q <= 4'd0;          // ⭐ 本帧结束，回到帧外
                    end else begin
                        idx_q <= idx_q + 4'd1;
                    end
                end
            end else if (idle_expired && (idx_q != 4'd0)) begin
                // ══ ⭐ 空闲归位（⭐ 自愈）═════════════════════════════════════
                //   ⭐ 长时间没有新字节 ⇒ ⭐ 半帧作废，回到帧外
                //   ⭐ 幂等：一旦 idx==0 就不再满足条件 ⇒ ⭐ 天然只触发一次
                idx_q        <= 4'd0;
                resync_cnt_o <= sat_inc16(resync_cnt_o);
                //   ⭐ 2026-10-03（`P2`）：⭐ 半帧作废 ⇒ ⭐ `'H'` 的臂**一起作废**
                //      ⚠️ 否则一个"发了 `'H'` 但帧没发完"的残局会**永久挂着臂**
                //      ⇒ 🔴 之后第一帧的载荷[0] 被静默吃掉 ✅
                abs_arm_q    <= 1'b0;
            end
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检（⭐ 与既有模块同一套路）
    //   ⚠️ 会**静默失效**的组合：
    //     ① `GAP_BYTES <= 1` ⇒ ⚠️ 帧内字节间隙被误判成"空闲" ⇒
    //        🔴 **半帧提前归位** ⇒ 帧内字母被当成命令（⭐ 正是本模块要防的）
    //     ② 三个命令字母有**重复** ⇒ ⚠️ 后面的 `if` 永远被前面的遮蔽
    //        ⇒ 🔴 **某个命令静默失效**（⚠️ 按了没反应，且无任何提示）
    //     ③ `BAUD`/`CLK_HZ` 导致 `BYTE_CLK_I == 0` ⇒ ⚠️ 计时器失去意义
    //     ④ 命令字母 == `HEADER` ⇒ 🔴 **帧头被当命令** ⇒ 事件帧全废
    // ═══════════════════════════════════════════════════════════════════════
    // Every recognised command must have its own byte.  Keep this complete:
    // a false PARAM_OK is build-visible, rather than merely a diagnostic that
    // can scroll out of a log.
    //  ⭐ 2026-09-29 重构：⭐ 命令字母从 **7 个**涨到 **10 个** ⇒
    //     🔴 手写 C(10,2) = **45 个配对**既啰嗦、⭐ 又**极容易漏一个**
    //     ⇒ ⭐ **改成【循环查重】**（⭐ 以后加第 11 个字母只需往 `cmd_tab` 里加一项）✅
    localparam PARAM_OK = (GAP_BYTES > 1) && (BYTE_CLK_I > 0);

    //  ⭐⭐ **全部命令字母**（⚠️ 加新命令时【必须】往这张表里加一项）
    //   ⭐ 2026-09-29：⭐ **12 ⇒ 13**（⭐ 新增 `'D'` 鼓机节奏型）
    //      📌 ⚠️ **忘了加这里 = 查重漏掉新字母** ⇒ 🔴 将来撞字母时**静默遮蔽**
    //         （⭐ 所以本表是"加新命令时的**必改项**"，⭐ 见上方注释 ✅）
    //   ⭐ 2026-10-03（`P2`）：⭐ **14 ⇒ 18**（⭐ 新增 `'F'`/`'G'`/`'H'`/`'J'` 四条变调命令）
    //      📌 ⚠️ **忘了加这里 = 查重漏掉新字母** ⇒ 🔴 将来撞字母时**静默遮蔽**
    //         （⭐ 所以本表是"加新命令时的**必改项**"，⭐ 见上方注释 ✅）
    localparam integer N_CMD = 18;
    reg [7:0] cmd_tab [0:N_CMD-1];
    integer   ci, cj;
    reg       letters_ok;

    initial begin
        cmd_tab[0]  = CMD_TARE;
        cmd_tab[1]  = CMD_SPAN;
        cmd_tab[2]  = CMD_ABORT;
        cmd_tab[3]  = CMD_PROBE;
        cmd_tab[4]  = CMD_VSTAT;
        cmd_tab[5]  = CMD_TEST_MODE;
        cmd_tab[6]  = CMD_POSPROBE;
        cmd_tab[7]  = CMD_LOOP_REC;
        cmd_tab[8]  = CMD_LOOP_PLAY;
        cmd_tab[9]  = CMD_LOOP_CLR;
        cmd_tab[10] = CMD_TIMBRE;      // ⭐ 2026-09-29：⭐ 'I' 切音色
        cmd_tab[11] = CMD_METRONOME;   // ⭐ 2026-09-29：⭐ 'B' 节拍器开/关（⭐ 方案 B：S2 让给音色）
        cmd_tab[12] = CMD_DRUM_PATTERN; // ⭐ 2026-09-29：⭐ 'D' 鼓机节奏型切下一个
        cmd_tab[13] = CMD_KEYDRUM;     // ⭐ 2026-10-01：⭐ 'K' 键盘打鼓模式开关
        cmd_tab[14] = CMD_TRANS_DOWN;  // ⭐ 2026-10-03：⭐ 'F' 变调：降 1 半音（⭐ P2）
        cmd_tab[15] = CMD_TRANS_UP;    // ⭐ 2026-10-03：⭐ 'G' 变调：升 1 半音（⭐ P2）
        cmd_tab[16] = CMD_TRANS_ABS;   // ⭐ 2026-10-03：⭐ 'H' 变调：带帧绝对量（⭐ P2）
        cmd_tab[17] = CMD_GEAR_NEXT;   // ⭐ 2026-10-03：⭐ 'J' 推子档位切下一档（⭐ P2）

        if (GAP_BYTES <= 1)
            $display("ERROR [calib_cmd] GAP_BYTES = %0d <= 1 => intra-frame byte gaps would be mistaken for idle, so a half frame resyncs early and payload bytes get treated as commands. PARAM_OK=0.", GAP_BYTES);
        if (BYTE_CLK_I <= 0)
            $display("ERROR [calib_cmd] BYTE_CLK_I = %0d <= 0 (CLK_HZ=%0d BAUD=%0d) => the idle timer is meaningless. PARAM_OK=0.", BYTE_CLK_I, CLK_HZ, BAUD);

        letters_ok = 1'b1;
        for (ci = 0; ci < N_CMD; ci = ci + 1) begin
            if (cmd_tab[ci] == HEADER) begin
                letters_ok = 1'b0;
                $display("ERROR [calib_cmd] command letter %02h (index %0d) equals HEADER (%02h) => every event frame would be swallowed as a command. PARAM_OK=0.", cmd_tab[ci], ci, HEADER);
            end
            for (cj = ci + 1; cj < N_CMD; cj = cj + 1) begin
                if (cmd_tab[ci] == cmd_tab[cj]) begin
                    letters_ok = 1'b0;
                    $display("ERROR [calib_cmd] duplicate command letters %02h at index %0d and %0d => one command is silently shadowed and never fires. PARAM_OK=0.", cmd_tab[ci], ci, cj);
                end
            end
        end

        if (PARAM_OK && letters_ok)
            $display("NOTE [calib_cmd] PARAM_OK=1 (CLK_HZ=%0d BAUD=%0d GAP_BYTES=%0d BYTE_CLK=%0d HEADER=%02h N_CMD=%0d T=%02h S=%02h X=%02h M=%02h R=%02h L=%02h C=%02h I=%02h D=%02h F=%02h G=%02h H=%02h J=%02h)",
                     CLK_HZ, BAUD, GAP_BYTES, BYTE_CLK_I, HEADER, N_CMD,
                     CMD_TARE, CMD_SPAN, CMD_ABORT, CMD_TEST_MODE,
                     CMD_LOOP_REC, CMD_LOOP_PLAY, CMD_LOOP_CLR, CMD_TIMBRE,
                     CMD_DRUM_PATTERN,
                     CMD_TRANS_DOWN, CMD_TRANS_UP, CMD_TRANS_ABS, CMD_GEAR_NEXT);
    end

endmodule

`default_nettype wire
