// ═══════════════════════════════════════════════════════════════════════════
// rec_dump.v · ⭐⭐ 2026-10-11：⭐ **录制回传的导出 FSM**（⭐ 用户需求 ✅）
//
//   ⭐ **干什么**：⭐ 把 `looper` **已录下的事件**按**线上 9 字节帧**吐给
//      `u_tx_fifo` ⇒ ⭐ `u_uart_tx_esp` ⇒ ⭐ ESP32 ⇒ BLE ⇒ PC ✅
//
//   ⭐ **帧格式（⭐ 与 `evt_uart_rx` 收的完全同构 ⇒ ⭐ 可【直接回灌】✅）**：
//      `0xA5` ＋ 8 字节【大端】事件字 ✅
//      `tick[63:44]` · `inc[43:23]` · `axis[22:19]` · `vel[18:11]` ·
//      `kind[10:9]` · `timbre[8:7]` · `[6:0]` 保留 ✅
//
//   ⭐⭐ **为什么"回灌同构"是要紧的**：⭐ 录下来的东西**能原样灌回曲谱口**
//      ⇒ ⭐ "⭐ **录一段 → 回传 PC → 存成谱子 → 再灌回去**" 这条闭环才成立 ✅
//
//   🔴🔴 **与 `looper` 的握手（⭐ 两个硬约束，⭐ 都在 `looper.v` 那边写明）**：
//      ① ⭐ **必须占用读口**（`dump_en_o = 1`）——
//         ⚠️ 因为 BSRAM 只有 **1 读口**（⭐ 加第二个读口 ⇒ 推不出 BSRAM
//            ⇒ 🔴 就是 `135168 > 60780` 的综合失败 ✅）
//         ⇒ ⚠️ **导出期间⛔ 不能放音** ⇒ ⭐ 本模块用 `idle_i` **保证只在层空闲时导** ✅
//      ② ⭐ **读是【同步】的** ⇒ ⭐ 给地址后要**等 2 拍**数据才有效
//         （⭐ 1 拍让地址可见 ＋ 1 拍 BSRAM 出数 ✅）
//         ⇒ ⭐ 所以状态机里有 `S_READ → S_WAIT → S_LATCH` **三个状态** ✅
//         📌 ⚠️ **只等 1 拍是错的**（⭐ 本模块第一版就是这么写的）——
//            因为 `dump_addr_o` 在**给地址的那一拍末尾**才更新，
//            ⭐ `looper` 在**下一拍**才拿它去读 ⇒ ⚠️ 少等一拍会**读到上一条** ✅
//
//   ⭐ **`clip_i`（⭐ 截断标志）**：⭐ `looper` 的导出是 **21 位 `inc`**
//      ⇒ ⚠️ 实时弹的事件（⭐ `axis_map` 给 32 位全用）**会被截断** ✅
//      ⇒ ⭐ 本模块**统计截断条数**（`clip_cnt_o`，⭐ 饱和 ✅）
//      📌 ⭐ 目的：⭐ 让"**不是原样**"这件事**可见**（⭐ `K-106` ⛔ 不许静默失真 ✅）
//
//   ⭐ **`busy_o` / `done_o`**：⭐ 供顶层做可观测（⭐ `K-106` ✅）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps
`default_nettype none

module rec_dump #(
    //  ⭐ 地址/计数位宽（⭐ 与 `looper.CNT_W` 一致 = 16 ✅）
    parameter integer ADDR_W = 16,
    //  ⭐ 帧头（⭐ 与 `evt_uart_rx.HEADER` 一致 ✅）
    parameter [7:0]   HDR    = 8'hA5
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── ⭐ 触发与前提 ─────────────────────────────────────────────────────
    input  wire                  req_i,        // ⭐ 启动导出（⭐ 单周期脉冲 ✅）
    input  wire                  idle_i,       // ⭐ 该层空闲（⭐ 1 = 可导 ✅）
    input  wire [ADDR_W-1:0]     cnt_i,        // ⭐ 已录事件数

    // ── ⭐ 来自 `looper` 的导出读口 ───────────────────────────────────────
    input  wire [63:0]           data_i,       // ⭐ 线上 64 位（⭐ 同步读，⭐ 2 拍后有效 ✅）
    input  wire                  clip_i,       // ⭐ 本条被截断过（⭐ `inc` 超 21 位 ✅）

    // ── ⭐ 推给 `u_tx_fifo` ───────────────────────────────────────────────
    input  wire                  ready_i,      // ⭐ 队列未满（⭐ 上游据此节流 ✅）
    output reg                   push_o,       // ⭐ 推一个字节（⭐ 单周期 ✅）
    output reg  [7:0]            byte_o,

    // ── ⭐ 占用 `looper` 的读口 ───────────────────────────────────────────
    output reg                   dump_en_o,
    output reg  [ADDR_W-1:0]     dump_addr_o,

    // ── ⭐ 可观测（⭐ `K-106`）────────────────────────────────────────────
    output reg                   busy_o,
    output reg                   done_o,       // ⭐ 单周期脉冲 ✅
    output reg  [15:0]           clip_cnt_o,   // ⭐ 被截断的事件数（⭐ 饱和 ✅）
    output reg  [15:0]           frame_cnt_o   // ⭐ 已导出的帧数（⭐ 饱和 ✅）
);

    //  ⭐ 状态：⭐ **`S_WAIT` 那一个是必需的**（⭐ 见文件头 ② 的说明 ✅）
    localparam [2:0] S_IDLE  = 3'd0,
                     S_READ  = 3'd1,   // ⭐ 给地址（⭐ 本拍末尾才可见 ✅）
                     S_WAIT  = 3'd2,   // ⭐ 地址已可见 ⇒ ⭐ BSRAM 本拍出数 ✅
                     S_LATCH = 3'd3,   // ⭐ 数据有效 ⇒ ⭐ 装进移位器 ✅
                     S_PUSH  = 3'd4,   // ⭐ 逐字节推（⭐ 9 个 ✅）
                     S_DONE  = 3'd5;

    reg [2:0]        st;
    reg [ADDR_W-1:0] addr_r;      // ⭐ 当前地址
    reg [ADDR_W-1:0] last_r;      // ⭐ 最后一条的地址（⭐ 启动时锁存 ⇒ ⛔ 不怕 `cnt_i` 中途变 ✅）
    reg [71:0]       sr;          // ⭐ `{HDR, word}` ⇒ ⭐ 左移 9 次发完 ✅
    reg [3:0]        bi;          // ⭐ 0..8（⭐ 9 个字节 ✅）

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            st          <= S_IDLE;
            addr_r      <= {ADDR_W{1'b0}};
            last_r      <= {ADDR_W{1'b0}};
            sr          <= 72'd0;
            bi          <= 4'd0;
            push_o      <= 1'b0;
            byte_o      <= 8'd0;
            dump_en_o   <= 1'b0;
            dump_addr_o <= {ADDR_W{1'b0}};
            busy_o      <= 1'b0;
            done_o      <= 1'b0;
            clip_cnt_o  <= 16'd0;
            frame_cnt_o <= 16'd0;
        end else begin
            //  ⭐ 默认：⭐ 脉冲类信号**每拍回落**（⭐ 下面按状态置位 ✅）
            push_o <= 1'b0;
            done_o <= 1'b0;

            case (st)
                // ── ⭐ 等触发 ─────────────────────────────────────────────
                S_IDLE: begin
                    dump_en_o <= 1'b0;
                    busy_o    <= 1'b0;
                    //  ⭐ **三个前提缺一不可**：⭐ 有请求 ＋ ⭐ 层空闲 ＋ ⭐ 有内容 ✅
                    //     ⚠️ `idle_i` 那一条是**硬约束**（⭐ 导出占用读口 ⇒ 不能放音 ✅）
                    //     ⚠️ `cnt_i != 0` 那一条：⭐ 空层导出**没有意义**
                    //        ⇒ ⭐ 直接不启动（⛔ 也不发任何字节）✅
                    if (req_i && idle_i && (cnt_i != {ADDR_W{1'b0}})) begin
                        st     <= S_READ;
                        addr_r <= {ADDR_W{1'b0}};
                        last_r <= cnt_i - {{(ADDR_W-1){1'b0}}, 1'b1};   // ⭐ = cnt_i - 1 ✅
                        busy_o <= 1'b1;
                    end
                end

                // ── ⭐ 给地址（⭐ 占用读口从本拍开始 ✅）────────────────────
                S_READ: begin
                    dump_en_o   <= 1'b1;
                    dump_addr_o <= addr_r;
                    st          <= S_WAIT;
                end

                // ── ⭐ 等 BSRAM 出数（⭐ 这一拍**不能省** ✅）──────────────
                S_WAIT: begin
                    st <= S_LATCH;
                end

                // ── ⭐ 数据有效 ⇒ ⭐ 装移位器 ─────────────────────────────
                S_LATCH: begin
                    sr <= {HDR, data_i};
                    bi <= 4'd0;
                    st <= S_PUSH;
                    //  ⭐ 截断统计（⭐ 饱和 ✅）
                    if (clip_i && (clip_cnt_o != 16'hFFFF))
                        clip_cnt_o <= clip_cnt_o + 16'd1;
                end

                // ── ⭐ 逐字节推（⭐ `ready_i` 节流 ⇒ ⛔ 不丢字节 ✅）────────
                S_PUSH: begin
                    if (ready_i) begin
                        push_o <= 1'b1;
                        byte_o <= sr[71:64];          // ⭐ 最高字节先发（⭐ 大端 ✅）
                        sr     <= {sr[63:0], 8'd0};   // ⭐ 左移一个字节 ✅
                        if (bi == 4'd8) begin
                            //  ⭐ 9 个字节发完（⭐ `bi` = 0..8 ✅）
                            bi <= 4'd0;
                            if (frame_cnt_o != 16'hFFFF)
                                frame_cnt_o <= frame_cnt_o + 16'd1;
                            if (addr_r == last_r) begin
                                st <= S_DONE;
                            end else begin
                                addr_r <= addr_r + {{(ADDR_W-1){1'b0}}, 1'b1};
                                st     <= S_READ;
                            end
                        end else begin
                            bi <= bi + 4'd1;
                        end
                    end
                end

                // ── ⭐ 收尾（⭐ 释放读口 ＋ ⭐ 一个 `done` 脉冲 ✅）──────────
                S_DONE: begin
                    dump_en_o <= 1'b0;
                    busy_o    <= 1'b0;
                    done_o    <= 1'b1;
                    st        <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ── ⭐ 参数自检（⭐ 与项目其余模块同一套路 ✅）────────────────────────
    initial begin
        if (ADDR_W < 1)
            $display("ERROR [rec_dump] ADDR_W=%0d < 1 => the address counter would be zero-width. PARAM_OK=0.", ADDR_W);
        if (HDR == 8'h00)
            $display("WARNING [rec_dump] HDR=0x00 -- the score receiver expects 0xA5; a 0x00 header will never be recognized on re-feed.");
    end

endmodule

`default_nettype wire
