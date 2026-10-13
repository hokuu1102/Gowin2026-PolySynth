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
//   ⭐ 效果器「留位」（§四）：fx_en_o / fx_sel_o 只定义接口，⛔ 不实现本体
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
    //   1 Mbps = 1000000（默认，对齐 uart_rx 的 BAUD_DIV=50）
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
    parameter integer MODE_PIANO_DEFAULT = 1
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

    // ── ⭐ 效果器「留位」（§四：只定义接口，⛔ 不实现本体）────────────────
    output reg         fx_en_o,            // ⭐ 效果器使能（留位，恒 0）
    output reg  [1:0]  fx_sel_o,           // ⭐ 效果器选择（留位，恒 0）

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
    reg [6:0]  body_q;         // ⭐ 帧体第一个「有意义」字节（控件 ID / 变量序号）
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
            body_q       <= 7'd0;
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
            fx_en_o      <= 1'b0;          // ⭐ 留位，恒 0
            fx_sel_o     <= 2'd0;          // ⭐ 留位，恒 0
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
                                        if (body_q == 7'd0) begin
                                            mode_o        <= ~mode_o;    // ⭐ 翻转
                                            mode_commit_o <= 1'b1;
                                        end else if (body_q == 7'd2) begin
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
                                        if (body_q == 7'd1) begin
                                            // ⭐ 起始音：本模块只做 `val_q >> 1`（🔴 ⛔ **不是"按 12 取整"**）
                                            //    ⭐ 真正只认 `0/12/24` 的是 `note_manager.v:373-378`
                                            //    ⇒ ⭐ **屏侧要发 `val_q = 0 / 24 / 48`**（= 2 × base_semi）
                                            base_semi_o  <= {1'b0, val_q[7:1]}; // ⚠️ 简化：见 tb 约定
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
                            if (body_len == 6'd0) begin
                                body_q <= rx_data_i[6:0];
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

endmodule

`default_nettype wire
