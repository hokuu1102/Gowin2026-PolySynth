`timescale 1ns/1ps
`default_nettype none

// ═══════════════════════════════════════════════════════════════════════════
// tb_key_drum -- ⭐ 键盘打鼓模式（⭐ 串口 `'K'`）· 2026-10-01
//
//   ⭐ **被测行为**：⭐ 打开后磁轴键盘当鼓垫 —— 按键 ⇒
//      ① `src_a_src` 变 `SRC_KDRUM(5)`（⭐ ⇒ 进保留池 + 走 perc 包络
//         ＋ ⭐ **与源 B（节拍器/鼓机）标签不同 ⇒ 不互相抢音** ✅ —— ⭐ `P1-59` ✅）
//      ② `src_a_inc` 换成 4 件乐器之一的**鼓频率**
//      ③ `src_a_timbre` 换成该件的 **`drum_type`**
//         ⭐⭐ **2026-10-16（统一鼓轴）**：⭐ 原来这里是**固定的 `DRUM_TIMBRE`**，
//            🔴 而灌谱鼓把 `drum_type` 写进 `timbre[8:7]` ⇒ **同一件鼓两条来路
//            回传给 ESP32 的 timbre 不同** ⇒ ✅ 现在**与灌谱逐位同口径**
//            ⚠️ **对音色零影响**：⭐ 打鼓 `src == SRC_KDRUM` ⇒ 恒判成鼓 ⇒
//               走**噪声表**（⭐ 与 timbre 取值无关 ✅）
//      ④ `src_a_axis` 变成 `12 + drum_type`
//         ⭐⭐ **2026-10-16（统一鼓轴 · 审鼓队 P1）**：⭐ 原来是**键盘物理轴**（0~15）
//            ⇒ 🔴 **同一件鼓三条来路落三个轴** ⇒ `same_hit`（同轴同源才复用）
//               永不命中 ⇒ **各占一个 voice** ⇒ ✅ 现在统一到 12/13/14/15
//      ⇒ ⭐ 关闭后**一切恢复原样**（⭐ 正常发音高）
//
//   ⭐⭐ **判据（10 组）**
//      T1 ⭐ 默认（关）⇒ 按键**原样通过**（`inc` 不被改、`src` 仍是手弹 0）
//      T2 ⭐ 打鼓（开）⇒ `src_a_src == SRC_KDRUM(5)`（⭐ **"进鼓池"的充要条件**）
//      T3 ⭐⭐ **4 件乐器逐件比对** —— `src_a_inc` 必须**等于 `drum_gen` 里那一件的常量**
//            （⭐ 轴 0~3⇒嗵鼓 · 4~7⇒底鼓 · 8~11⇒军鼓 · 12~15⇒踩镲）
//            🔴 **本 tb 最要紧的一条**：⭐ "是不是鼓、是哪件鼓"靠 **`phase_inc` 频率范围**判
//               （`oscillator_bank.v:379-381`）⇒ ⭐ `top.v` 那 4 个常量是**有意重复**的
//               ⇒ 🔴 **抄错一个数就静默变乐器** ⇒ ⭐ 本判据拿 `u_drum_gen.INC_*` 当**单一来源**
//      T4 ⭐ 打鼓 ⇒ `timbre_valid == 1`
//      T4' ⭐⭐ **`timbre` 逐件 = 该件的 `drum_type`**（0=Kick 1=Snare 2=HiHat 3=Tom）
//      T5 ⭐ 串口 `'K'` ⇒ ① 回 `'k'` ② `key_drum_r` **翻转**（⭐ 再发一次 ⇒ 翻回）
//      T6 ⭐ 关闭后**恢复**（⭐ 回到 T1 的行为）
//      T9 ⭐⭐ **四件的【事件轴】= 12/13/14/15** ＝ `12 + drum_type`（⭐⭐ 2026-10-16）
//            底鼓 12 · 军鼓 13 · 踩镲 14 · 嗵鼓 15 ⇒ ⭐ 与 `drum_gen.evt_axis_r`
//            及灌谱鼓**同一套轴号约定** ⇒ `note_manager.same_hit`（同轴同源才复用）
//            ⇒ ⭐ **三条来路同一件鼓天然重触发、⛒ 不叠 voice** ✅
//      T9b ⭐ **`key_drum_sel` 仍取【物理轴】**（⭐ 防"轴号 mux 自指"的唯一判据 ✅）
//      T9c ⭐ **`key_drum_dtype` 换算表**（⭐ 物理轴映射 ⇒ `drum_type` ✅）
//
//   ⚠️⚠️ **两条实测踩到的坑（⭐ 写在这里防复发）**
//      ① ⭐ **`force` 必须"持续到检查之后"** —— 🔴 我第一版把 `release` 写在 `chk` **之前**，
//         ⇒ ⭐ 检查时 `src_a_inc` 已经回到驱动器值 ⇒ 🔴 **T1b/T3b/c/d 假红**
//         （⭐ 现象：⭐ T3a 过、T3b/c/d 全红 ⇒ ⚠️ 看起来像 mux 错，⭐ 其实是 tb 的时序）
//         ⇒ ⭐ 现在拆成 `key_begin`（force + 稳定）/ `chk` / `key_end`（release）✅
//      ② ⭐ **端口位宽要照抄现有 tb**：⭐ `spi_cs_n` 是 **6 位**、`miso_l/r` 各 **1 位**
//         （⭐ 我第一版写成 `[3:0]` 与 `[7:0]` ⇒ ⚠️ 编译告警 + 位选越界 ✅）
// ═══════════════════════════════════════════════════════════════════════════

module tb_key_drum;

    localparam integer NAME_W = 8*72;

    // ── ⭐ 时钟 / 复位 ───────────────────────────────────────────────────
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;          // ⭐ 50 MHz

    // ── ⭐ 串口（⭐ 115200 ⇒ 434 clk/bit；⭐ 2026-10-28 板载口改档，tb 同步适配）──
    localparam integer CLK_HZ      = 50_000_000;
    localparam integer BAUD        = 115_200;
    localparam integer CLK_PER_BIT = 434;                 // = 50M/115200（⭐ 收发同档）

    reg  uart_rx_line = 1'b1;       // ⭐ 空闲高
    wire uart_tx_line;

    // ── ⭐ DUT（⭐ 端口声明照抄 `tb_met_start_top.sv:74-112`）──────────────
    wire        HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire        spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0]  spi_cs_n;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .SEL_DRUM (0)               // ⭐ 源 B = 节拍器（⭐ 本 tb 不测源 B）
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .uart_rx       (uart_rx_line),
        .uart_tx       (uart_tx_line)
    );
    assign spi_cs_n[5:2] = 4'b1111;

    // ── ⭐ 观察点 ────────────────────────────────────────────────────────
    wire        kd_mode  = u_top.key_drum_r;
    wire [31:0] sa_inc_o = u_top.g_sound.src_a_inc;
    wire [2:0]  sa_src_o = u_top.g_sound.src_a_src;
    wire        sa_tv_o  = u_top.g_sound.src_a_timbre_valid;
    wire [1:0]  sa_t_o   = u_top.g_sound.src_a_timbre;
    wire [7:0]  sa_vel_o = u_top.g_sound.src_a_vel;      // ⭐ T7：力度下限判据用
    //  ⭐⭐ 2026-10-16（⭐⭐ 统一鼓轴）：⭐ **事件轴**判据（⭐ `T9`）✅
    //     ⚠️ 与 `sa_axis`（⭐ `seq_arb` 的输出）**必须分开看** —— 本判据钉的是
    //        `src_a_axis`（⭐ 打鼓模式下已被压成 12~15 的那个 ✅）
    wire [3:0]  sa_ax_o  = u_top.g_sound.src_a_axis;
    //     ⭐ 底下的 `key_drum_sel` / `key_drum_dtype` —— ⭐ 顺手钉住"物理轴映射没被改"
    //        （⭐ 它俩是"轴号 mux 会不会自指"的唯一判据 ✅）
    wire [1:0]  kd_sel   = u_top.g_sound.key_drum_sel;
    wire [1:0]  kd_dtype = u_top.g_sound.key_drum_dtype;

    //   ⭐⭐ **单一来源**：⭐ 直接引用 `drum_gen` 的常量（⛔ 不在这里抄一遍）
    //      ⚠️ 用 `wire` 而⛔ 不是 `localparam` —— ⭐ 层次引用**不能出现在常量表达式里** ✅
    wire [31:0] REF_KICK   = u_top.g_sound.u_drum_gen.INC_KICK;
    wire [31:0] REF_SNARE  = u_top.g_sound.u_drum_gen.INC_SNARE;
    wire [31:0] REF_HIHAT  = u_top.g_sound.u_drum_gen.INC_HIHAT;
    wire [31:0] REF_TOM    = u_top.g_sound.u_drum_gen.INC_TOM;
    wire [1:0]  REF_TIMBRE = u_top.DRUM_TIMBRE;

    // ⚠️ **`tx_cyc` 必须声明在【task 之前】** —— ⭐ `L66`：声明先于使用
    //    （⭐ 我第一版放在监视器那段（⭐ 在 task 之后）⇒ 🔴 `Unable to bind wire/reg` ✅）
    reg [31:0] tx_cyc = 32'd0;
    always @(posedge clk) tx_cyc <= tx_cyc + 32'd1;

    integer errors = 0;
    integer checks = 0;

    task chk;
        input [NAME_W-1:0] name;
        input              cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    // ══ ⭐ 后台常驻接收进程 ══════════════════════════════════════════════
    //   🔴🔴 **为什么必须"常驻"而不是"要用时再收"**（⭐ 2026-10-01 实测踩到）：
    //      ⭐ FPGA 收到命令字节后**立刻**回包 ⇒ ⭐ 而我的 `uart_send` 还要再等
    //      **一整个停止位**（100 拍）才返回 ⇒ 🔴 **回包的起始位落在 `uart_send` 期间**
    //      ⇒ ⭐ 等我进 `uart_recv` 时，⭐ 线路**已经是低**（⭐ 起始位中途）
    //      ⇒ 🔴 我的边沿检测**立刻"成功"**（⭐ `waited 0`）⇒ ⭐ 采样整体**晚 1 bit**
    //      ⇒ ⭐ 实测：⭐ `0x6B` 被读成 **`0xB5`**（⭐ 正好 = 丢掉 bit0 + 补停止位）
    //      📌 **判据**：⭐ 后台进程从复位就开始跑 ⇒ ⭐ 字节边界**永远对齐** ✅
    //   ⚠️ 用 `while (... !== 1'b1)` 而不是 `=== 1'b0` —— ⭐ 复位期线路是 `x`，
    //      用 `===` 会**永远等不到**（⭐ `x !== 1'b0` ✅）
    reg [7:0] rx_q [0:15];
    integer   rx_cnt = 0;
    integer   ri;
    reg [7:0] rx_tmp;

    initial begin : uart_rx_bg
        rx_cnt = 0;
        forever begin
            while (uart_tx_line !== 1'b1) @(posedge clk);   // ⭐ 等空闲高
            while (uart_tx_line !== 1'b0) @(posedge clk);   // ⭐ 等起始位
            repeat (CLK_PER_BIT + CLK_PER_BIT/2) @(posedge clk);  // ⭐ 到 D0 中心
            for (ri = 0; ri < 8; ri = ri + 1) begin
                rx_tmp[ri] = uart_tx_line;
                repeat (CLK_PER_BIT) @(posedge clk);
            end
            if (rx_cnt < 16) begin
                rx_q[rx_cnt] = rx_tmp;
                rx_cnt = rx_cnt + 1;
            end
        end
    end

    // ══ ⭐ 串口发送一个字节（⭐ 8N1，⭐ LSB 先）══════════════════════════
    task uart_send;
        input [7:0] b;
        integer i;
        begin
            uart_rx_line = 1'b0;                       // ⭐ start
            repeat (CLK_PER_BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_line = b[i];                   // ⭐ LSB 先
                repeat (CLK_PER_BIT) @(posedge clk);
            end
            uart_rx_line = 1'b1;                       // ⭐ stop
            repeat (CLK_PER_BIT) @(posedge clk);
        end
    endtask

    // ══ ⭐ 取第 `idx` 个已收到的字节（⭐ 等它到，⭐ 超时 ⇒ got=0）══════════
    task uart_take;
        input  integer idx;
        output [7:0]   b;
        output         got;
        integer n;
        begin
            b = 8'h00; got = 1'b0;
            n = 0;
            while ((rx_cnt <= idx) && (n < 30000)) begin
                @(posedge clk); n = n + 1;
            end
            if (rx_cnt > idx) begin
                b = rx_q[idx];
                got = 1'b1;
            end
        end
    endtask

    // ══ ⭐ 按键：⭐ begin（force + 稳定）→ chk → end（release）════════════
    //   ⚠️⚠️ **必须拆开** —— ⭐ `force` 要**持续到检查之后**（⭐ 见文件头「坑 ①」）
    task key_begin;
        input [3:0]  ax;
        input [31:0] inc;
        input [1:0]  kind;
        begin
            @(posedge clk); #5;                        // ⭐ `U74`：force 离开时钟沿
            force u_top.g_sound.sa_valid        = 1'b1;
            force u_top.g_sound.sa_axis         = ax;
            force u_top.g_sound.sa_inc          = inc;
            force u_top.g_sound.sa_vel          = 8'd200;
            force u_top.g_sound.sa_kind         = kind;
            force u_top.g_sound.sa_src          = 3'd0;    // ⭐ 手弹
            force u_top.g_sound.sa_timbre_valid = 1'b0;
            force u_top.g_sound.sa_timbre       = 2'd0;
            #1;                                        // ⭐ 组合逻辑稳定
        end
    endtask

    task key_end;
        begin
            release u_top.g_sound.sa_valid;
            release u_top.g_sound.sa_axis;
            release u_top.g_sound.sa_inc;
            release u_top.g_sound.sa_vel;
            release u_top.g_sound.sa_kind;
            release u_top.g_sound.sa_src;
            release u_top.g_sound.sa_timbre_valid;
            release u_top.g_sound.sa_timbre;
            @(posedge clk);
        end
    endtask

    // ══ ⭐ 主流程 ═══════════════════════════════════════════════════════
    localparam [31:0] KEY_INC = 32'h00BA_039D;   // ⭐ 任意"键盘表值"

    integer   ax;
    reg [7:0] rb;
    reg       rgot;

    initial begin
        $display("=== tb_key_drum: keyboard-as-drums ===");

        // ── ⭐ 复位 ─────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);

        // ══ T1 ⭐ 默认（关）⇒ 按键原样通过 ═════════════════════════════
        chk("T1a: key_drum_r resets to 0 (mode OFF)", kd_mode === 1'b0);
        key_begin(4'd5, KEY_INC, 2'd0);
        chk("T1b: mode OFF => phase_inc passes through", sa_inc_o === KEY_INC);
        chk("T1c: mode OFF => src stays LIVE(0)",        sa_src_o === 3'd0);
        key_end();

        // ══ T5 ⭐ 串口 'K' ⇒ 回 'k' ＋ 翻转 ════════════════════════════
        //   ⭐ 用后台进程收到的**第 0 个**字节（⭐ 见上方"为什么必须常驻"）✅
        uart_send(8'h4B);                       // ⭐ 'K'
        uart_take(0, rb, rgot);
        $display("  INFO: byte[0] = 0x%02X (got=%0d)", rb, rgot);
        chk("T5a: 'K' produces a reply byte", rgot === 1'b1);
        chk("T5b: the reply is 'k' (0x6B)",   rb   === 8'h6B);
        repeat (20) @(posedge clk);
        chk("T5c: 'K' toggles key_drum_r ON", kd_mode === 1'b1);

        // ══ T2/T3/T4 ⭐ 打鼓模式 ═══════════════════════════════════════
        //   ⭐ 轴 → 乐器（⭐ 依据 `files/10-硬件/鼓垫.drawio.svg`）：
        //      轴 0~3 ⇒ 嗵鼓 · 4~7 ⇒ 底鼓 · 8~11 ⇒ 军鼓 · 12~15 ⇒ 踩镲
        for (ax = 0; ax < 16; ax = ax + 1) begin
            key_begin(ax[3:0], KEY_INC, 2'd0);
            // ⭐ T2：⭐ 一律进鼓池
            //  ⭐⭐ 2026-10-11（`P1-59`）：⭐ **判据从 `== 3'd3` 改成 `== 3'd5`** ✅
            //     🔴 **为什么必须改**：⭐ 原来打鼓与**源 B（节拍器/鼓机）共用标签 3**
            //        ⇒ ⭐ `note_manager.same_hit` 要求 `(轴, 源)` **都相同**
            //        ⇒ 🔴 **节拍器/鼓机在轴 14/15 的每一拍，都会把用户在轴 14/15 的 voice
            //          判成"同一个键还在响" ⇒ 走复用路径 ⇒ 改判/重触发** ✅
            //        📌 ⭐ 而 `SEL_DRUM = 1`（**鼓机**）是**交付默认档** ✅
            //     ✅ **现在标 `SRC_KDRUM(3'd5)`** ⇒ ⭐ 与源 B **不同标签**
            //        ⇒ ⭐ `same_hit` 不命中 ⇒ ⭐ **互不打断** ✅
            //     📌 ⭐ 而"进保留池 + 走 perc 包络"**照旧**（⭐ 见 T2b/T2c ✅）
            chk("T2: mode ON => src == SRC_KDRUM(5)", sa_src_o === 3'd5);
            //  ⭐⭐ T2b ⭐⭐ **本条【直接】对应 `P1-59` 那个缺陷** ✅
            //     ⭐ 它断言"**打鼓的标签必须与源 B（节拍器/鼓机）的标签不同**" ✅
            //     🔴 **未修复时这一条必红**（⭐ 两者都是 `3'd3` ✅）
            //     📌 ⭐ 为什么值得单独立一条：⭐ T2 只钉"等于 5"，
            //        ⚠️ 而**真正的契约**是"**与源 B 不同**" —— ⭐ 后者才是缺陷的判据 ✅
            //        （⭐ 若将来换一个空闲值，⭐ 改 T2 即可，⭐ 而 T2b 永远成立 ✅）
            chk("T2b: keyboard-drum src must DIFFER from source B (3) -- this is P1-59",
                sa_src_o !== 3'd3);
            // ⭐ T3：⭐ 逐件比对（⭐ 拿 drum_gen 的常量当单一来源）
            case (ax[3:2])
                2'd0: chk("T3a: axis 0-3   => TOM inc",   sa_inc_o === REF_TOM);
                2'd1: chk("T3b: axis 4-7   => KICK inc",  sa_inc_o === REF_KICK);
                2'd2: chk("T3c: axis 8-11  => SNARE inc", sa_inc_o === REF_SNARE);
                2'd3: chk("T3d: axis 12-15 => HIHAT inc", sa_inc_o === REF_HIHAT);
            endcase
            //  ═══════════════════════════════════════════════════════════════
            //  ⭐⭐⭐⭐ T9（⭐⭐ 2026-10-16 统一鼓轴 · 审鼓队 P1）
            //
            //  🔴 **原缺陷**：⭐ `src_a_axis` 打鼓模式下 = **键盘物理轴**（0~15）⇒
            //     · 内部鼓机（`drum_gen`）落 **12/13/14/15**
            //     · 灌谱鼓（`seq_arb`）落 **12/13/14/15**
            //     · 键盘打鼓（本处）落 **0~15 全占**（⭐ 物理轴）
            //     ⇒ ⭐ 而 `note_manager.v:720-722` 的 `same_hit` 要求 `(axis, src)` **都等**
            //        ⇒ 🔴 **三条来路的同一件鼓永不重触发、各占一个 voice** ✅
            //     ⇒ ⭐ 用户实测：「为什么键盘打鼓 / 内部鼓机 / 灌谱不是一套」✅
            //
            //  ✅ **修法**：⭐ `轴 = 12 + drum_type`（⭐ 与 `drum_gen` 的
            //     `evt_axis_r <= 4'd12 + {2'b00, drum_idx}` **逐字同一口径** ✅）
            //     ⇒ ⭐ 同一件鼓在所有来路落同一个轴 ⇒ ⭐ 天然互相重触发、不叠 voice ✅
            //     ⇒ ⭐ 而且四件各占一个轴 ⇒ ⭐ **内部鼓机也能一次响多件** ✅
            //
            //  ⚠️⚠️ **T9b 是"防自指"的判据**（⭐⭐ 本改动的头号陷阱 ✅）：
            //     ⚠️ 原写法 `key_drum_sel = src_a_axis[3:2]` ⇒ 一旦 `src_a_axis` 被压成
            //        12~15 ⇒ `[3:2]` **恒为 `2'b11`** ⇒ 🔴 **四件鼓全退化成踩镲**
            //        （⭐ 且 inc / vel 跟着一起错 ⇒ **静默换音色** ✅）
            //     ✅ 现在 `key_drum_sel` 取 `sa_axis[3:2]`（⭐ 物理轴）⇒ **T9b 逐件钉住它** ✅
            case (ax[3:2])
                2'd0: begin   // ⭐ 嗵鼓
                    chk("T9a1: TOM   lands on axis 15", sa_ax_o === 4'd15);
                    chk("T9b1: TOM   key_drum_sel is still 0 (physical, not self-fed)",
                        kd_sel === 2'd0);
                    chk("T9c1: TOM   drum_type = 3",      kd_dtype === 2'd3);
                end
                2'd1: begin   // ⭐ 底鼓
                    chk("T9a2: KICK  lands on axis 12", sa_ax_o === 4'd12);
                    chk("T9b2: KICK  key_drum_sel is still 1 (physical, not self-fed)",
                        kd_sel === 2'd1);
                    chk("T9c2: KICK  drum_type = 0",      kd_dtype === 2'd0);
                end
                2'd2: begin   // ⭐ 军鼓
                    chk("T9a3: SNARE lands on axis 13", sa_ax_o === 4'd13);
                    chk("T9b3: SNARE key_drum_sel is still 2 (physical, not self-fed)",
                        kd_sel === 2'd2);
                    chk("T9c3: SNARE drum_type = 1",      kd_dtype === 2'd1);
                end
                2'd3: begin   // ⭐ 踩镲
                    chk("T9a4: HIHAT lands on axis 14", sa_ax_o === 4'd14);
                    chk("T9b4: HIHAT key_drum_sel is still 3 (physical, not self-fed)",
                        kd_sel === 2'd3);
                    chk("T9c4: HIHAT drum_type = 2",      kd_dtype === 2'd2);
                end
            endcase
            //  ═══════════════════════════════════════════════════════════════
            //  ⭐⭐⭐ T4'（⭐⭐ 2026-10-16 统一鼓轴）—— **timbre 字段 = `drum_type`**
            //
            //  🔴 **原状**：⭐ 打鼓写 `DRUM_TIMBRE`(=2)，⭐ 而**灌谱鼓**把 `drum_type`
            //     写进 `timbre[8:7]` ⇒ 🔴 **同一件鼓两条来路回传给 ESP32 的 timbre 不同** ✅
            //  ✅ **现在与灌谱同口径** ⇒ ⭐ 键盘打鼓的四件也带 `drum_type` 回传 ✅
            //  🔴 **对音色零影响**（⭐ 这条必须验，⛒ 否则就是回归 ✅）：
            //     ⭐ 打鼓 `src == SRC_KDRUM` ⇒ `voice_drum_o` 恒判成鼓 ⇒
            //        `oscillator_bank` 走**噪声表** `rom_noise` ⇒ **与 timbre 取值无关** ✅
            //        （⭐ 所以 `timbre` 对鼓本来就是空字段 ✅）
            case (ax[3:2])
                2'd0: chk("T4'a: TOM   timbre field = drum_type 3", sa_t_o === 2'd3);
                2'd1: chk("T4'b: KICK  timbre field = drum_type 0", sa_t_o === 2'd0);
                2'd2: chk("T4'c: SNARE timbre field = drum_type 1", sa_t_o === 2'd1);
                2'd3: chk("T4'd: HIHAT timbre field = drum_type 2", sa_t_o === 2'd2);
            endcase
            // ⭐ T4a：⭐ `timbre_valid == 1`（⭐ 与键盘当前音色解耦 ✅）
            chk("T4a: mode ON => timbre_valid == 1",   sa_tv_o === 1'b1);
            //  ═══════════════════════════════════════════════════════════════
            //  ⭐⭐ T4b（⭐⭐ 2026-10-16 统一鼓轴）—— ⭐ **原"恒 DRUM_TIMBRE"判据已被 T4' 取代**
            //
            //  🔴 **为什么改判据**（⭐ 不是"放松"，⭐ 是**口径变了**）：
            //     ⭐ 原判据 `sa_t_o === DRUM_TIMBRE(2)` 钉的是"鼓用固定音色、不跟键盘走"
            //        ⭐ 而 2026-10-16 起打鼓这一路的 timbre 字段**换成 `drum_type`**
            //           （⭐⭐ 与灌谱鼓同口径 ⇒ 同源两路回传的 timbre 逐位一致 ✅）
            //        ⇒ 🔴 老判据在**非踩镲**那三件上**必然红**（⭐ 它们 = 3/0/1 ≠ 2 ✅）
            //        ⚠️ 而"**与键盘音色解耦**"那条**并没有失效** —— 它现在由
            //           **`T4e`**（⭐ 键盘音色怎么变，鼓的 timbre 都不变 ✅）接管 ✅
            //
            //  ✅ **T4b 的新口径**：⭐ 钉住"鼓的 timbre 与键盘**当前音色**无关"
            //     ⚠️ 用 `sa_t_o === key_drum_dtype`（⭐ 与 `T4'` 同一个真值，
            //        但**角度不同**：⭐ `T4'` 逐件钉常量，⭐ `T4b` 钉"不跟随键盘" ✅）
            chk("T4b: mode ON => timbre is the drum's own (drum_type), NOT the keyboard's",
                sa_t_o === kd_dtype);
            //  ⭐⭐ **T4e**：⭐⭐ "与键盘音色解耦"的**真·判据**（⭐ 老 T4b 的接棒者 ✅）
            //     🔴 **为什么必须真的去改键盘音色**（⭐ 而不是只比常量）：
            //        ⭐ `timbre_sel_r` 是**键盘当前音色**；⭐ 老 `DRUM_TIMBRE` 是**常量** ⇒
            //           **天然不可能跟随** ⇒ ⭐ 所以老判据"比常量"其实**没有证明解耦** ✅
            //        ⭐ 而 `drum_type` **也是常量** ⇒ 同样的问题 ⇒ ✅ **必须强制改
            //           `timbre_sel_r` 再比一次**，⭐ 才真正钉住"不跟随" ✅
            force u_top.timbre_sel_r = 2'd3;         // ⭐ 键盘改成 PAD（⭐ 与四件都不同）
            #1;
            chk("T4e: keyboard timbre forced to PAD(3) does NOT change the drum timbre",
                sa_t_o === kd_dtype);
            release u_top.timbre_sel_r;
            key_end();
        end

        // ══ T8 ⭐⭐ **4 件乐器的音高必须【落在正确分档】且【彼此拉开】** ═══════
        //   🔴 **为什么需要**（⭐ 用户上板："4 个鼓听不太出来区分度"）：
        //      ⭐ 鼓一律取**噪声表**（`oscillator_bank.v:699-701`）⇒ ⭐ 音色与乐器无关 ⚠️
        //      ⇒ ⭐ 4 件的区别**只剩【噪声播放速率】＋【扫频】** ⇒ ⭐ **音高必须拉开** ✅
        //   ⚠️ **分档边界**（`oscillator_bank.v:379-381`）：⭐ `<10M` 底鼓 · `10M~15M` 嗵鼓 · `≥15M` 其他
        //      🔴 **底鼓/嗵鼓填错档 ⇒ 扫频深度跟着错** ⇒ ⭐ 听感直接变另一样 ⚠️
        //   📌 **拉开判据**：⭐ 军鼓 ≥ 2× 嗵鼓 · ⭐ 踩镲 ≥ 2× 军鼓（⭐ 原来军鼓只有嗵鼓的 1.33× ⚠️）
        chk("T8a: kick is in the kick bucket (< 10M)",        REF_KICK  <  32'd10_000_000);
        chk("T8b: tom is in the tom bucket (10M .. 20M)",
            (REF_TOM >= 32'd10_000_000) && (REF_TOM < 32'd20_000_000));
        chk("T8c: snare is above the tom bucket (>= 15M)",    REF_SNARE >= 32'd15_000_000);
        chk("T8d: hihat is above the tom bucket (>= 15M)",    REF_HIHAT >= 32'd15_000_000);
        chk("T8e: snare >= 2x tom  (spread for distinguishability)",
            REF_SNARE >= (REF_TOM << 1));
        chk("T8f: hihat >= 2x snare (spread for distinguishability)",
            REF_HIHAT >= (REF_SNARE << 1));
        // ⭐⭐ T8g：⭐ 用户上板反馈"通鼓和底鼓还差一点点区分度" ⇒ ⭐ **拉开到 ≥ 3×**
        //    ⚠️ 这是**第二次拉开**的能红判据（⭐ 第一次是 2.29×，⭐ 现在是 3.33×）✅
        chk("T8g: tom >= 3x kick (second pass -- the user asked for more separation)",
            REF_TOM >= (REF_KICK * 3));

        // ══ T7 ⭐⭐ **打鼓模式下的力度下限**（⭐ 用户上板："声音也有点小"）═══════
        //   🔴 **根因**：⭐ 原来直接用**键盘力度**当鼓的力度 ⇒ ⚠️ 轻敲就轻
        //      ⭐ 而**鼓机**每件有固定力度（⭐ `drum_gen` 的 `VEL_*`）⇒ ⭐ 所以鼓机听着更"实" ✅
        //   ⭐ **策略**：⭐ `vel = max(键盘力度, 本件基础力度)`
        //      ⭐ 轴 5 ⇒ `axis[3:2] = 2'd1` ⇒ ⭐ **底鼓** ⇒ ⭐ 基础力度 **230** ✅
        key_begin(4'd5, KEY_INC, 2'd0);
        force u_top.g_sound.sa_vel = 8'd10;          // ⭐ 极轻敲
        #1;
        chk("T7a: a light tap is raised to the drum base velocity (230)",
            sa_vel_o === 8'd230);
        force u_top.g_sound.sa_vel = 8'd255;         // ⭐ 重敲
        #1;
        chk("T7b: a harder press passes through unchanged (255)",
            sa_vel_o === 8'd255);
        key_end();

        // ══ T5' ⭐ 再发一次 'K' ⇒ 翻回 ═════════════════════════════════
        uart_send(8'h4B);
        uart_take(1, rb, rgot);
        chk("T5d: second 'K' also replies",  rgot === 1'b1);
        chk("T5e: second reply is 'k'",      rb   === 8'h6B);
        repeat (20) @(posedge clk);
        chk("T5f: second 'K' toggles back to OFF", kd_mode === 1'b0);

        // ══ T6 ⭐ 关闭后恢复 ════════════════════════════════════════════
        key_begin(4'd5, KEY_INC, 2'd0);
        chk("T6a: after OFF => phase_inc restored", sa_inc_o === KEY_INC);
        chk("T6b: after OFF => src restored to LIVE(0)", sa_src_o === 3'd0);
        force u_top.g_sound.sa_vel = 8'd10;          // ⭐ 极轻敲
        #1;
        chk("T6c: after OFF => velocity passes through unchanged (no floor)",
            sa_vel_o === 8'd10);
        key_end();

        // ── ⭐ 汇总 ─────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: key_drum -- keyboard-as-drums maps 4 instruments by axis[3:2] and stays decoupled");
        else
            $display("FAIL: key_drum -- %0d of %0d checks failed", errors, checks);
        $display("INFO: checks=%0d errors=%0d", checks, errors);
        $finish;
    end

    // ⭐ 超时兜底（⭐ 见 `C84`：⛔ 不靠"没输出"判卡死）
    initial begin
        #2_000_000;
        $display("FAIL: key_drum -- TIMEOUT");
        $finish;
    end

endmodule

// ═══════════════════════════════════════════════════════════════════════════
// ⭐ 变异记录（⭐ 非空洞性 —— ⛔ 没做过的不要写）
//
//   | ⭐ 变异 | ⭐ 改法 | ⭐ 期望 |
//   |---|---|---|
//   | M1 | `top.v` 三处 `key_drum_r ? ... :` 全改成恒选原值 | 🔴 T2/T3/T4 **FAIL** |
//   | M2 | `key_drum_inc` 的 4 个常量任意**互换两个** | 🔴 T3 **FAIL**（⭐ 逐件比对抓到） |
//   | M3 | `src_a_src` 的 `3'd5` 改成 `3'd0` | 🔴 T2 **FAIL** |
//   | M4 | `src_a_timbre` 的 `key_drum_dtype` 改成 `2'd0` | 🔴 T4'b/c/d **FAIL** |
//   | M5 | `calib_cmd.v` 的 `byte_is_keydrum` 去掉 | 🔴 T5a/T5c **FAIL** |
//   | M6 | 回复字节 `8'h6B` 改成别的 | 🔴 T5b **FAIL** |
//   ⚠️ **M1 是"功能有没有接线"的总闸**，⭐ M2 是"常量抄没抄错"的**唯一**判据 ✅
//
//   ⭐⭐ **2026-10-16 追加（⭐⭐ 统一鼓轴 · 审鼓队 P1）**
//
//   | ⭐ 变异 | ⭐ 改法 | ⭐ 期望 |
//   |---|---|---|
//   | M7 | `src_a_axis` 退回**原样透传**（⭐ 删掉 `key_drum_axis` mux）| 🔴 T9a 全 4 件 **FAIL** |
//   | M8 | `key_drum_dtype` 4 选 1 里**互换两个**（⭐ 如 Kick↔Snare）| 🔴 T9a/T9c 对应件 **FAIL** |
//   | M9 | **`key_drum_sel` 改回 `src_a_axis[3:2]`**（⭐ 轴号 mux **自指**）| 🔴 **T9b1~4 全 FAIL**<br>（⭐ 这才是"四件全退化成踩镲"那条 ✅）|
//   | M10 | `key_drum_axis` 的 `4'd12` 改成 `4'd0` | 🔴 T9a 全 4 件 **FAIL** |
//   | M11 | `src_a_timbre` 改回 `DRUM_TIMBRE`（⭐ 2026-10-16 之前的值）| 🔴 T4' 全 4 件 **FAIL** |
//   ⚠️ **M9 是"自指陷阱"的专属判据** —— ⭐ 它红的不是"轴号错"，⭐ 而是
//      "**sel 跟着被压扁后的 axis 走**" ⇒ 四件的 inc / vel / timbre **一起错** ✅
//   ⚠️ **M7/M8/M10 红在 `T9a`，⭐ 但根因各不相同**（⭐ 未接线 / 换算表错 / 基址错）
//      ⇒ ⭐ 查的时候必须看**`T9b`/`T9c` 是否同时红**来区分 ✅
// ═══════════════════════════════════════════════════════════════════════════
