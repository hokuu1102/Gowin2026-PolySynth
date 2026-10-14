// ═══════════════════════════════════════════════════════════════════════════
// rec_dump.v · ⭐⭐ 2026-10-11：⭐ **录制回传的导出 FSM**（⭐ 用户需求 ✅）
//
//   ⭐ **干什么**：⭐ 把 `looper` **已录下的事件**按**线上 9 字节帧**吐给
//      ready/push 下游；顶层采用独占双 UART ⇒ ESP32/板载接收端。
//
//   ⭐ **帧格式（⭐ 与 `evt_uart_rx` 收的完全同构 ⇒ ⭐ 可【直接回灌】✅）**：
//      `0xA5` ＋ 8 字节【大端】事件字 ✅
//      `tick[63:44]` · `inc[43:23]` · `axis[22:19]` · `vel[18:11]` ·
//      `kind[10:9]` · `timbre[8:7]` · `[6:0]` 保留 ✅
//
//   同构只指事件帧布局：音符单位转换有量化损失，并非 32 位无损。
//   STATUS_ENABLE=1 时附 ASCII footer，PC 提取二进制帧后再回灌。
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
//   clip_i：Looper 负责量纲转换，标记量化或越界损失。
//   本模块统计损失条数（clip_cnt_o，饱和），不再次变换 phase_inc。
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
    parameter [7:0]   HDR    = 8'hA5,
    parameter integer STATUS_ENABLE = 0
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── ⭐ 触发与前提 ─────────────────────────────────────────────────────
    input  wire                  req_i,        // ⭐ 启动导出（⭐ 单周期脉冲 ✅）
    input  wire                  idle_i,       // ⭐ 该层空闲（⭐ 1 = 可导 ✅）
    input  wire [ADDR_W-1:0]     cnt_i,        // ⭐ 已录事件数

    // ── ⭐ 来自 `looper` 的导出读口 ───────────────────────────────────────
    input  wire [63:0]           data_i,       // ⭐ 线上 64 位（⭐ 同步读，⭐ 2 拍后有效 ✅）
    input  wire                  clip_i,       // 当前事件有量化或越界损失
    input  wire [15:0]           reject_count_i,

    // ── ⭐ 推给 `u_tx_fifo` ───────────────────────────────────────────────
    input  wire                  ready_i,      // ⭐ 队列未满（⭐ 上游据此节流 ✅）
    output wire                  push_o,       // 当拍接受的字节，不预约下一拍
    output wire [7:0]            byte_o,

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
                     S_PUSH  = 3'd4,   // ⭐ 逐字节推（⭐ 14 个 ✅）
                     S_DONE  = 3'd5,
                     S_STATUS_LOAD = 3'd6,
                     S_STATUS_PUSH = 3'd7;

    reg [2:0]        st;
    reg [ADDR_W-1:0] addr_r;      // ⭐ 当前地址
    reg [ADDR_W-1:0] last_r;      // ⭐ 最后一条的地址（⭐ 启动时锁存 ⇒ ⛔ 不怕 `cnt_i` 中途变 ✅）
    //  ⭐⭐ 2026-10-14：⭐ **帧宽 9 B → 14 B**（⭐ 改成 v1.1 上行格式 ✅）
    //     🔴 **为什么**：⭐ 原来发 `HDR + 8 B 事件字`（⭐ **9 B**）
    //        ⇒ ⚠️ **没有类型字节、没有校验字节**
    //        ⇒ 🔴 **ESP32 的 v1.1 解析器读 `[1]` 得到 `0x00`** ⇒ **未知类型** ⇒ **一直重同步** ✅
    //     📌 ⭐ **实测**：⭐ 用户 2026-10-14 的串口 dump 正是这个问题
    //        （⭐ `帧 0 · 未知类型 8 · 重同步 2411` ✅）
    //     📌 ⭐ 而且那 8 字节**本身是对的** —— ⭐ 逐位解码是合法下行事件字
    //        （⭐ `tick=149` 单调递增 · `axis=5` · `vel=255` · `kind=1` note_off ✅）
    //        ⇒ 🔴 **数据对、封装不对** ✅
    //     ✅ **修法**：⭐ 改成与 `evt_upstream` **同构的 14 B v1.1 帧**：
    //        `[0]0xA5 [1]type [2]seq [3..6]tick32 [7]axis [8..11]inc32 [12]vel [13]XOR[0..12]`
    //     📌 ⚠️ **代价（⭐ 如实说）**：⭐ **失去"可直接回灌"**（⭐ 原设计意图）——
    //        ⚠️ 但那个用途本来就该走 **PC 侧重打包**（⭐ 14 B → 9 B 是一次简单转换 ✅），
    //        ⭐ 而 14 B 帧带**全 32 位 `inc`** ⇒ ⭐ 保真度反而**更高** ✅
    //     📌 ⭐ 依据：⭐ `files/20-代码/FPGA侧答复-鼓谱发声与XOR更正-20261014.md` §三 ✅
    reg [111:0]      sr;          // ⭐ **14 字节**（⭐ 左移 14 次发完 ✅）
    reg [3:0]        bi;          // ⭐ 0..13（⭐ 14 个字节 ✅）
    reg [7:0]        seq_r;       // ⭐ 帧序号（⭐ v1.1 的 `[2]` ✅）
    reg [111:0] status_sr;
    function [7:0] hex_ascii;
        input [3:0] n;
        begin hex_ascii = (n < 10) ? (8'h30 + {4'd0,n}) : (8'h37 + {4'd0,n}); end
    endfunction
    //  ⭐⭐ 2026-10-14：⭐ **v1.1 帧【组合】装配**（⭐ 从 `data_i` 的 64 位下行字导出 ✅）
    //     📌 ⭐ 字段映射与 `rtl/top.v:4506` 的位域表、以及 `evt_upstream.v` **逐位一致** ✅
    wire [7:0]  f_type = (data_i[10:9] == 2'd1) ? 8'h02 : 8'h01;   // ⭐ kind==1 ⇒ note_off
    wire [7:0]  f_seq  = seq_r;
    wire [31:0] f_tick = {12'd0, data_i[63:44]};                    // ⭐ tick 20 位 ⇒ 零扩展 32 位
    wire [7:0]  f_axis = {4'd0, data_i[22:19]};
    wire [31:0] f_inc  = {1'b0, data_i[43:23], 10'b0};              // ⭐ 还原**全 32 位** phase_inc ✅
    wire [7:0]  f_vel  = data_i[18:11];
    //  ⭐ 校验 = XOR 覆盖 **[0..12]（⭐ 含帧头 0xA5）** —— ⭐ 与 ESP32 侧同口径 ✅
    wire [7:0]  f_ck   = HDR ^ f_type ^ f_seq
                       ^ f_tick[31:24] ^ f_tick[23:16] ^ f_tick[15:8] ^ f_tick[7:0]
                       ^ f_axis
                       ^ f_inc[31:24] ^ f_inc[23:16] ^ f_inc[15:8] ^ f_inc[7:0]
                       ^ f_vel;
    wire [111:0] f_frame = { HDR, f_type, f_seq,
                             f_tick[31:24], f_tick[23:16], f_tick[15:8], f_tick[7:0],
                             f_axis,
                             f_inc[31:24], f_inc[23:16], f_inc[15:8], f_inc[7:0],
                             f_vel, f_ck };

    assign push_o = ((st == S_PUSH) || (st == S_STATUS_PUSH)) && ready_i;
    assign byte_o = (st == S_STATUS_PUSH) ? status_sr[111:104] : sr[111:104];

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            st          <= S_IDLE;
            addr_r      <= {ADDR_W{1'b0}};
            last_r      <= {ADDR_W{1'b0}};
            sr          <= 112'd0;     // ⭐ 2026-10-14：⭐ 14 字节（⭐ 原来 72 位 = 9 字节 ✅）
            bi          <= 4'd0;
            seq_r       <= 8'd0;       // ⭐ 2026-10-14：⭐ 帧序号复位 ✅
            status_sr   <= 112'd0;
            dump_en_o   <= 1'b0;
            dump_addr_o <= {ADDR_W{1'b0}};
            busy_o      <= 1'b0;
            done_o      <= 1'b0;
            clip_cnt_o  <= 16'd0;
            frame_cnt_o <= 16'd0;
        end else begin
            //  ⭐ 默认：⭐ 脉冲类信号**每拍回落**（⭐ 下面按状态置位 ✅）
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
                //  ⭐⭐ 2026-10-14：⭐ **装【14 B v1.1 帧】**（⭐ 组合装配见上面 `f_frame` ✅）
                S_LATCH: begin
                    sr <= f_frame;
                    bi <= 4'd0;
                    //  ⭐⭐ 2026-10-14：⭐ **帧序号自增**（⭐ v1.1 的 `[2]` ✅）
                    //     🔴 **我第一版【漏了这一行】** ⇒ ⚠️ 每帧 `seq` 都是 0
                    //        ⇒ 🔴 **`tb_rec_dump` 4 条红**（⭐ seq 字节 ＋ 被它带偏的 XOR 字节 ✅）
                    //     📌 ⭐ **教训**：⭐ 新加一个字段时，
                    //        ⛔ **别只写"声明 ＋ 复位"** —— ⭐ **真正让它动起来的是自增/赋值那一行** ✅
                    //        （⭐ 而声明和复位**都在**，所以读代码时很容易以为已经写全了 ✅）
                    seq_r <= seq_r + 8'd1;
                    st <= S_PUSH;
                    //  ⭐ 截断统计（⭐ 饱和 ✅）
                    if (clip_i && (clip_cnt_o != 16'hFFFF))
                        clip_cnt_o <= clip_cnt_o + 16'd1;
                end

                // ── ⭐ 逐字节推（⭐ `ready_i` 节流 ⇒ ⛔ 不丢字节 ✅）────────
                S_PUSH: begin
                    if (ready_i) begin
                        sr     <= {sr[103:0], 8'd0};  // ⭐ 左移一个字节（⭐ 112 位 = 14 字节 ✅）
                        if (bi == 4'd13) begin        // ⭐ 14 个字节发完（⭐ `bi` = 0..13 ✅）
                            bi <= 4'd0;
                            if (frame_cnt_o != 16'hFFFF)
                                frame_cnt_o <= frame_cnt_o + 16'd1;
                            if (addr_r == last_r) begin
                                st <= STATUS_ENABLE ? S_STATUS_LOAD : S_DONE;
                            end else begin
                                addr_r <= addr_r + {{(ADDR_W-1){1'b0}}, 1'b1};
                                st     <= S_READ;
                            end
                        end else begin
                            bi <= bi + 4'd1;
                        end
                    end
                end

                // Footer: y + four hex frames/losses/rejects + LF.
                // Cumulative counters since reset; ASCII cannot contain 0xA5.
                S_STATUS_LOAD: begin
                    status_sr <= {8'h79,
                        hex_ascii(frame_cnt_o[15:12]),hex_ascii(frame_cnt_o[11:8]),hex_ascii(frame_cnt_o[7:4]),hex_ascii(frame_cnt_o[3:0]),
                        hex_ascii(clip_cnt_o[15:12]),hex_ascii(clip_cnt_o[11:8]),hex_ascii(clip_cnt_o[7:4]),hex_ascii(clip_cnt_o[3:0]),
                        hex_ascii(reject_count_i[15:12]),hex_ascii(reject_count_i[11:8]),hex_ascii(reject_count_i[7:4]),hex_ascii(reject_count_i[3:0]),8'h0a};
                    bi <= 0;
                    st <= S_STATUS_PUSH;
                end
                S_STATUS_PUSH: begin
                    if (ready_i) begin
                        status_sr <= {status_sr[103:0],8'd0};
                        if (bi == 13) st <= S_DONE;
                        else bi <= bi + 1'b1;
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
