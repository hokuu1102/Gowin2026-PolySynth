// ============================================================================
//  span_probe.v —— `'V'` 诊断命令：回传 `calib_span` 的内部状态
//                 （⭐ 2026-09-24 新增）
//
//  ═══════════════════════════════════════════════════════════════════════════
//  🔴 **为什么需要它**（⭐ 上板实测）
//  ═══════════════════════════════════════════════════════════════════════════
//
//  ⭐ 上板发 `'S'`（逐轴 span 标定）⇒ 现象：
//     · 回 `s`（受理）+ 轴号 `0`，🔴 **然后是一长串 `!`（被拒）**
//     · ⭐ 而且**按不按都被拒**
//
//  🔴 **问题**：⭐ `calib_span` 有 **8 个状态**，⚠️ **其中任何一个超时或被拒
//     都会回 `!`** ⇒ ⭐ 从串口**根本看不出卡在哪一步**。
//
//  ⭐ 已经排除的（⭐ 都有实测）：
//     · 回包被丢（`K-126`，✅ 已修，⭐ 轴号能出来了）
//     · ADC 没数据（⭐ `'P'` 读到 2176/2218，⭐ 按下 2902）
//     · 霍尔没信号（⭐ 万用表 1.53V → 0.95V）
//     · 电源（⭐ VDD 3.428V）
//     · MISO 悬空（⭐ 恒定 3.06V **是正常的**——CS 高时三态 + 内部上拉）
//     · 串口丢字节（⭐ 脚本验证：⭐ 包完整、⭐ 8 字节、⭐ CRLF 对）
//     · 抖动（⭐ 连发 20 次：⭐ ch7 的 Δ = 36 < `VOTE_TOL` 96）
//
//  ⇒ ⭐⭐ **本模块就是那只"眼睛"**：⭐ 发 `'V'` ⇒ ⭐ 回当前状态。
//
//  ═══════════════════════════════════════════════════════════════════════════
//  ⭐ 输出格式（⭐ 人类可读，⭐ 串口助手 ASCII 即可）
//  ═══════════════════════════════════════════════════════════════════════════
//
//  ⭐ 每次收到 `probe_req_i` ⇒ 回一行：
//
//      ⭐ `V<state><axis><rej_hi><rej_lo>\r\n`   （⭐ 共 **7** 字节）
//      🔴 2026-10-01 更正：旧注释写"`V<state><axis><rej><rej2>`（共 9 字节）" ⇒ ⚠️ **错**，
//         ⭐ 实际是 **7 字节**（⭐ 与 `N_BYTES = 7` 一致，见下方 `:68-69`；
//         另见 `bringup/18-上板验证卡-功能修复-20260930深夜.md:399-401`）。
//      ⚠️ 另：`rej_why_o`（拒绝原因码）**不经过 `'V'`** —— 它由 `top.v` 单独回传。
//
//  · `V`        —— ⭐ 固定前缀（⭐ 与 `'P'` 的包区分）
//  · `<state>`  —— ⭐ 1 位 hex：⭐ `calib_span` 的状态
//                    `0`=IDLE · `1`=PROMPT · `2`=SETTLE · `3`=VOTE
//                    `4`=FIRE · `5`=WAITBUSY · `6`=NEXT · `7`=DONE
//  · `<axis>`   —— ⭐ 1 位 hex：⭐ `cur_axis`（0~F）
//  · `<rej>`    —— ⭐ 1 位 hex：⭐ `reject_cnt` 高位
//  · `<rej2>`   —— ⭐ 1 位 hex：⭐ `reject_cnt` 低位
//      ⇒ ⭐ 合起来 = `reject_cnt` 的 2 位 hex（⭐ 0~8，⭐ `REJECT_MAX=8`）
//
//  📌 **最有用的一列是 `<state>`**：
//     · ⭐ 一直停在 `2`（SETTLE）⇒ ⭐ 稳定判定过不去
//     · ⭐ 一直停在 `3`（VOTE）  ⇒ ⭐ 收不齐 8 帧
//     · ⭐ 一直在 `1`（PROMPT）  ⇒ ⭐ 在反复重试
//     · ⭐ 停在 `7`（DONE）      ⇒ ⭐ 已放弃（⭐ 那 `reject_cnt` 应该是 8）
//
//  ═══════════════════════════════════════════════════════════════════════════
//  ⭐ 设计要点
//  ═══════════════════════════════════════════════════════════════════════════
//
//  ① ⭐ **和 `pos_probe` 同构**（⭐ 复用它的状态机结构）——
//     ⚠️ 但**独立一个模块**，⛔ 不塞进 `pos_probe`：
//     ⭐ 因为两者的输入/格式不同，⭐ 混在一起会让 `pos_probe` 变复杂。
//
//  ② ⭐ **走同一个 `uart_tx_fifo`**，⭐ 且同样**等 `idle_i` 才开新包**
//     ⇒ ⭐ 避免与 `'P'` 的回包撞车（⭐ `K-126` 的教训）
//
//  ③ ⭐ **读数在触发时【锁存】** ⇒ ⭐ 回传期间状态变了也不影响这一行
//
//  ④ ⭐ **Verilog-2001**（⭐ `K-91`）· ⭐ **声明先于使用**（⭐ `L66`）
//
// ============================================================================

module span_probe #(
    // ⭐ 一次回传的字节数：'V' + state + axis + rej_hi + rej_lo + CR + LF = 7
    parameter integer N_BYTES = 7,
    parameter integer QUEUE_WHEN_BLOCKED = 0
) (
    input  wire       clk_i,
    input  wire       rst_n_i,

    // ── ⭐ 触发（⭐ 来自 `calib_cmd.probe2_req_o`，⭐ 单拍脉冲）────────────
    input  wire       req_i,

    // ── ⭐ 要回传的状态（⭐ 来自 `top.v` 的 `calib_span` 输出）──────────────
    input  wire [2:0] state_i,      // ⭐ calib_span.state_o
    input  wire [3:0] axis_i,       // ⭐ calib_span.cur_axis_o
    input  wire [3:0] rej_i,        // ⭐ calib_span.rej_cnt_o

    // ── ⭐ 下游：`uart_tx_fifo` 的推入口 ──────────────────────────────────
    output reg        push_o,
    output reg  [7:0] data_o,
    input  wire       ready_i,
    input  wire       idle_i,       // ⭐ 队列真空了才开新包

    output reg        busy_o,
    output wire       packet_active_o
);

    // ── ⭐ 常量 ───────────────────────────────────────────────────────────
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_SEND = 2'd1;
    // star 2026-09-24: one extra settle cycle so push_o really drops before IDLE
    localparam [1:0] S_DONE = 2'd2;
    localparam [1:0] S_WAIT_IDLE = 2'd3;

    // ── ⭐ 声明（⭐ 全部先于使用 —— `L66`）────────────────────────────────
    reg  [1:0]  state;
    assign packet_active_o = (state == S_SEND) || (state == S_DONE);
    reg  [3:0]  idx;                // ⭐ 0..6
    reg  [2:0]  st_lat;
    reg  [3:0]  ax_lat;
    reg  [3:0]  rj_lat;

    // ⭐ 十六进制字符（⭐ 0~15 ⇒ '0'..'9' / 'A'..'F'）
    function [7:0] hexch;
        input [3:0] v;
        begin
            hexch = (v < 4'd10) ? (8'h30 + {4'd0, v})
                                : (8'h41 + ({4'd0, v} - 8'd10));
        end
    endfunction

    // ⭐ 当前该发哪个字节（⭐ 纯组合查表）
    reg [7:0] tx_byte_c;
    always @(*) begin
        case (idx)
            4'd0:    tx_byte_c = 8'h56;              // 'V'
            4'd1:    tx_byte_c = hexch({1'b0, st_lat});
            4'd2:    tx_byte_c = hexch(ax_lat);
            4'd3:    tx_byte_c = hexch(rj_lat);
            4'd4:    tx_byte_c = 8'h30;              // ⭐ reject 低 4 位恒 0（⭐ 0~8）
            4'd5:    tx_byte_c = 8'h0D;              // CR
            default: tx_byte_c = 8'h0A;              // LF
        endcase
    end

    // ── ⭐ 时序 ───────────────────────────────────────────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state  <= S_IDLE;
            idx    <= 4'd0;
            st_lat <= 3'd0;
            ax_lat <= 4'd0;
            rj_lat <= 4'd0;
            push_o <= 1'b0;
            data_o <= 8'd0;
            busy_o <= 1'b0;
        end else begin
            // ⭐ 默认：`push_o` 单拍
            push_o <= 1'b0;

            case (state)
                // ── ⭐ 等触发（⭐ 且下游真空）────────────────────────────
                S_IDLE: begin
                    busy_o <= 1'b0;
                    if (req_i && (idle_i || QUEUE_WHEN_BLOCKED)) begin
                        st_lat <= state_i;
                        ax_lat <= axis_i;
                        rj_lat <= rej_i;
                        idx    <= 4'd0;
                        state  <= idle_i ? S_SEND : S_WAIT_IDLE;
                        busy_o <= 1'b1;
                    end
                end

                S_WAIT_IDLE: begin
                    busy_o <= 1'b1;
                    if (idle_i) state <= S_SEND;
                end
                // ── ⭐ 逐个推字节 ────────────────────────────────────────
                S_SEND: begin
                    busy_o <= 1'b1;
                    if (ready_i) begin
                        push_o <= 1'b1;
                        data_o <= tx_byte_c;

                        if (idx == (N_BYTES[3:0] - 4'd1)) begin
                            idx    <= 4'd0;
                            state  <= S_DONE;
                            busy_o <= 1'b1;
                        end else begin
                            idx <= idx + 4'd1;
                        end
                    end
                end

                // star 收尾一拍：not pushing, just drop push_o
                S_DONE: begin
                    push_o <= 1'b0;
                    busy_o <= 1'b0;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
