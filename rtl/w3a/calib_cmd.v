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
// ── ⭐ 输出：三个单拍脉冲（⭐ 直接给下游当触发源）─────────────────────────────
//   ⭐ `tare_req_o` → `calib_autotare.retrig_i`
//   ⭐ `span_req_o` → `calib_span.start_i`
//   ⭐ `abort_req_o` → `calib_span.abort_i`
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
    // ⭐ 必须与 `uart_rx.BAUD_DIV` / `evt_uart_rx.BAUD` 一致（⭐ 1 Mbps 默认）
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
    parameter [7:0]   CMD_TEST_MODE = 8'h4D   // 'M'
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
    output reg         test_mode_req_o,// ⭐ 'M' ⇒ Test Mode 下一档（帧外才有效）

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
    localparam integer BYTE_CLK_I = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 四舍五入
    localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;
    localparam [19:0]  GAP_CLK    = GAP_CLK_I;                  // ⭐ 赋值 ⇒ 自动截断
    localparam [3:0]   IDX_LAST   = 4'd8;                       // ⭐ 8 字节载荷

    // ── 状态 ───────────────────────────────────────────────────────────────
    //   ⭐ `idx_q` 语义与 `evt_uart_rx` **刻意保持一致**：
    //      0 = 帧外（⭐ 命令只能在这里被接受）；1..8 = 帧内第 N 个载荷字节
    reg [3:0]  idx_q;
    reg [19:0] idle_q;

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
    wire byte_is_test_mode = (rx_data_i == CMD_TEST_MODE); // ⭐ 'M' Test Mode
    // ⭐ 任一命令字母
    wire byte_is_cmd   = byte_is_tare | byte_is_span | byte_is_abort |
                         byte_is_probe | byte_is_vstat | byte_is_test_mode;

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
            test_mode_req_o<= 1'b0;     // ⭐ 'M' Test Mode
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
            test_mode_req_o <= 1'b0;    // ⭐ 'M' Test Mode

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
                        if (byte_is_test_mode) test_mode_req_o <= 1'b1;
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
    localparam PARAM_OK = (GAP_BYTES > 1) && (BYTE_CLK_I > 0) &&
                          (CMD_TARE  != CMD_SPAN)  && (CMD_TARE  != CMD_ABORT) &&
                          (CMD_TARE  != CMD_PROBE) && (CMD_TARE  != CMD_VSTAT) &&
                          (CMD_TARE  != CMD_TEST_MODE) &&
                          (CMD_SPAN  != CMD_ABORT) && (CMD_SPAN  != CMD_PROBE) &&
                          (CMD_SPAN  != CMD_VSTAT) && (CMD_SPAN  != CMD_TEST_MODE) &&
                          (CMD_ABORT != CMD_PROBE) && (CMD_ABORT != CMD_VSTAT) &&
                          (CMD_ABORT != CMD_TEST_MODE) &&
                          (CMD_PROBE != CMD_VSTAT) && (CMD_PROBE != CMD_TEST_MODE) &&
                          (CMD_VSTAT != CMD_TEST_MODE) &&
                          (CMD_TARE  != HEADER) && (CMD_SPAN  != HEADER) &&
                          (CMD_ABORT != HEADER) && (CMD_PROBE != HEADER) &&
                          (CMD_VSTAT != HEADER) && (CMD_TEST_MODE != HEADER);

    initial begin
        if (GAP_BYTES <= 1)
            $display("ERROR [calib_cmd] GAP_BYTES = %0d <= 1 => intra-frame byte gaps would be mistaken for idle, so a half frame resyncs early and payload bytes get treated as commands. PARAM_OK=0.", GAP_BYTES);
        if (BYTE_CLK_I <= 0)
            $display("ERROR [calib_cmd] BYTE_CLK_I = %0d <= 0 (CLK_HZ=%0d BAUD=%0d) => the idle timer is meaningless. PARAM_OK=0.", BYTE_CLK_I, CLK_HZ, BAUD);
        if ((CMD_TARE == CMD_SPAN) || (CMD_TARE == CMD_ABORT) || (CMD_SPAN == CMD_ABORT))
            $display("ERROR [calib_cmd] duplicate command letters (T=%02h S=%02h X=%02h) => one command is silently shadowed and never fires. PARAM_OK=0.", CMD_TARE, CMD_SPAN, CMD_ABORT);
        if ((CMD_TARE == HEADER) || (CMD_SPAN == HEADER) || (CMD_ABORT == HEADER))
            $display("ERROR [calib_cmd] a command letter equals HEADER (%02h) => every event frame would be swallowed as a command. PARAM_OK=0.", HEADER);
        if ((CMD_TEST_MODE == CMD_TARE) || (CMD_TEST_MODE == CMD_SPAN) ||
            (CMD_TEST_MODE == CMD_ABORT) || (CMD_TEST_MODE == CMD_PROBE) ||
            (CMD_TEST_MODE == CMD_VSTAT) || (CMD_TEST_MODE == HEADER))
            $display("ERROR [calib_cmd] CMD_TEST_MODE=%02h conflicts with an existing command or HEADER => Test Mode command would be ambiguous. PARAM_OK=0.", CMD_TEST_MODE);
        if (PARAM_OK)
            $display("NOTE [calib_cmd] PARAM_OK=1 (CLK_HZ=%0d BAUD=%0d GAP_BYTES=%0d BYTE_CLK=%0d HEADER=%02h T=%02h S=%02h X=%02h M=%02h)",
                     CLK_HZ, BAUD, GAP_BYTES, BYTE_CLK_I, HEADER, CMD_TARE, CMD_SPAN, CMD_ABORT, CMD_TEST_MODE);
    end

endmodule

`default_nettype wire
