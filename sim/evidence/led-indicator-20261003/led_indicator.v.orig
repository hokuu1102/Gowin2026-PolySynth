`timescale 1ns/1ps
// ============================================================================
//  led_indicator.v -- 指示层（⭐ 三层架构的【第 2 层】）：状态码 → 颜色/闪烁
//
//  三层架构（⭐ 出处：files/20-代码/WS2812指示层规格-20261003.md）
//  ---------------------------------------------------------------
//    第 1 层  各子系统：⭐ 它们**本来就有**状态 ⇒ 只引出 2~3 位状态码（~5 LUT/路）
//    第 2 层  **本模块**：状态码 → 24 位 RGB888 颜色 ＋ 闪烁方式（⭐ 表驱动）
//    第 3 层  ws2812_driver：颜色 → 800 kHz 单线位时序（⭐ 已有，⛔ 本模块不碰）
//
//  ⭐ **为什么是"表驱动"**：加第 8 个东西的代价 = ① 子系统引出 2~3 位（~5 LUT）
//     ＋ ② 本文件加一个 `case`（~30 LUT）＋ ③ 灯序里加一颗
//     ⇒ ⭐ **完全不需要动 PHY，也不需要新增状态机** ✅
//
//  七路语义（⭐ 用户 2026-10-03 给定，⛔ 不许自行改语义）
//  ---------------------------------------------------
//    #  | 东西        | 状态码                      | 显示
//    ---|-------------|-----------------------------|--------------------------------
//    0  | 音色        | timbre_i[1:0]  (4 种)       | 白 / 青 / 紫 / 橙  常亮
//    1  | 节拍器      | metro_on_i ＋ beat_i        | 开 = 按 BPM 拍点闪绿；关 = 灭
//    2  | 鼓机        | drum_on_i ＋ drum_pat_i[1:0]| 红 / 洋红 / 黄 / 橙红 常亮；关 = 灭
//    3  | 键盘打鼓    | keydrum_i                   | 蓝 常亮；关 = 灭
//    4  | looper      | looper_i[1:0]               | 空闲=暗蓝常亮 / 录音=红快闪 / 回放=绿常亮
//    5  | 推子功能    | gear_i[1:0]                 | 变调=紫 / 颤音=青 / 摇把=黄 / 无=灭
//    6  | 指板/键盘   | fb_mode_i                   | 指板=橙 / 键盘=绿
//
//  ⭐ "灭"的编码 = **颜色 0**（⭐ 不另设使能位）—— WS2812 没有独立使能脚，
//     `24'h000000` 就是全灭，多一根使能线只是多一根要接错的线 ✅
//
//  闪烁（⭐ 只有两种效果，⭐ 计数器**全模块共享一个**，⛔ 不是 7 个）
//  -----------------------------------------------------------------
//    · `BL_FAST`：内部快闪计数器（`FAST_DIV` 位）翻转 ⇒ 灭/亮各 2^(FAST_DIV-1) 拍
//        `FAST_DIV = 23` @50 MHz ⇒ 半周期 4.19 M 拍 = **83.9 ms**（整周期 167.8 ms）
//        ⇒ ⭐ **≈6 Hz 闪烁**（⭐ "快闪"就是给人一眼看出"在录"）
//    · `BL_BEAT`：拍点脉冲 `beat_i` **触发一次拉伸**（`FLASH_CYC` 拍）⇒ 亮一小段就灭
//        `FLASH_CYC = 5_000_000` @50 MHz = **100 ms**（120 BPM 下 1/5 拍，看得清）
//    ⭐ 两者都**只调制"亮/灭"**，⛔ 不改变颜色 ⇒ 表里只写"该状态什么颜色" ✅
//
//  ⚠️ 为什么闪烁不用"每路一个计数器"：⭐ 7 个计数器 = 7 份几乎相同的逻辑
//     ＋ 7 个相位（上板看起来会"各闪各的"）⇒ ⭐ 共享一个 ⇒ 全板同步、省资源 ✅
//
//  可测性（⭐ 判据必须【能红】，⭐ 见 tb/w3a/tb_led_indicator.sv）
//  -------------------------------------------------------------
//    · 颜色：每档状态码都逐位比对 24 位颜色（⭐ 不是"看起来对"）
//    · 闪烁：`FAST_DIV`/`FLASH_CYC` 都是**参数** ⇒ tb 用小值实例化第二个 DUT，
//        ⭐ 在几千拍内就能量出"快闪周期 = 2·2^FAST_DIV"与"拍点闪时长 = FLASH_CYC"
//    · 已实测能红（⭐ 两次真变异，⭐ 见 tb 文件头的 MUTATION EVIDENCE）
// ============================================================================
`default_nettype none

module led_indicator #(
    //  ⭐ 指示灯颗数（⭐ 本项目 = 7：一颗对一个东西）
    parameter integer N_CH      = 7,
    //  ⭐ 快闪计数器位宽：半周期 = 2^(FAST_DIV-1) 拍（23 ⇒ 167.8 ms @50 MHz）
    parameter integer FAST_DIV  = 23,
    //  ⭐ 拍点闪的拉伸长度（拍）：5_000_000 ⇒ 100 ms @50 MHz
    parameter integer FLASH_CYC = 5_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // ── 第 1 层：状态码（⭐ 全部是各子系统**现成**的信号）────────────────────
    input  wire [1:0]  timbre_i,       // 音色 0..3
    input  wire        metro_on_i,     // 节拍器 开/关
    input  wire        beat_i,         // 拍点脉冲（⭐ 单周期）
    input  wire        drum_on_i,      // 鼓机是否真的在出声
    input  wire [1:0]  drum_pat_i,     // 鼓机节奏型 0..3
    input  wire        keydrum_i,      // 键盘打鼓 开/关
    input  wire [1:0]  looper_i,       // 0=空闲 · 1=录音 · 2=回放
    input  wire [1:0]  gear_i,         // 0=变调 · 1=颤音 · 2=摇把 · 3=无
    input  wire        fb_mode_i,      // 0=键盘 · 1=指板

    // ── 第 3 层接口：N_CH 颗灯的颜色（⭐ RGB888 平铺，LED0 在**最低** 24 位）──
    output reg  [N_CH*24-1:0] led_col_o
);

    // ── 参数自检（⭐ 与 `looper`/`clk_gen` 的 `PARAM_OK` 同一套路）────────────
    //   ⚠️ 为什么必须有：`FLASH_CYC` 放不进 23 位时会**静默截断**（⭐ 100 ms 变别的值，
    //      而灯照常闪 ⇒ ⚠️ 看不出来）⇒ ⭐ 明确报出来。
    initial begin
        if (FLASH_CYC > ((1 << 23) - 1))
            $display("ERROR [led_indicator] FLASH_CYC=%0d does not fit in 23 bits", FLASH_CYC);
        if (FAST_DIV < 1)
            $display("ERROR [led_indicator] FAST_DIV=%0d must be >= 1", FAST_DIV);
        if (N_CH < 1)
            $display("ERROR [led_indicator] N_CH=%0d must be >= 1", N_CH);
    end

    // ── 闪烁方式（⭐ 表里每路只写一个值）────────────────────────────────────
    localparam [1:0] BL_STEADY = 2'd0;   // 常亮
    localparam [1:0] BL_FAST   = 2'd1;   // 快闪（内部计数器）
    localparam [1:0] BL_BEAT   = 2'd2;   // 拍点闪（`beat_i` 触发一次拉伸）

    // ── 颜色表（⭐ 24'hRRGGBB；⭐ 到线上的 GRB 重排由 `ws2812_driver` 做）──────
    localparam [23:0] C_OFF     = 24'h000000;   // 灭
    localparam [23:0] C_WHITE   = 24'hFFFFFF;   // 白
    localparam [23:0] C_CYAN    = 24'h00FFFF;   // 青
    localparam [23:0] C_VIOLET  = 24'h8000FF;   // 紫（⭐ 与"洋红"分开：洋红 = FF00FF）
    localparam [23:0] C_ORANGE  = 24'hFF8000;   // 橙
    localparam [23:0] C_GREEN   = 24'h00FF00;   // 绿
    localparam [23:0] C_RED     = 24'hFF0000;   // 红
    localparam [23:0] C_MAGENTA = 24'hFF00FF;   // 洋红
    localparam [23:0] C_YELLOW  = 24'hFFFF00;   // 黄
    localparam [23:0] C_ORRED   = 24'hFF4000;   // 橙红
    localparam [23:0] C_BLUE    = 24'h0000FF;   // 蓝
    localparam [23:0] C_DIMBLUE = 24'h000030;   // 暗蓝（⭐ looper 空闲；⭐ 暗到不刺眼）

    // ── ① 共享快闪计数器（⭐ 全模块一个）──────────────────────────────────
    reg [FAST_DIV-1:0] fast_cnt;
    always @(posedge clk) begin
        if (!rst_n) fast_cnt <= {FAST_DIV{1'b0}};
        else        fast_cnt <= fast_cnt + 1'b1;
    end
    //  ⭐ 最高位 = "灭"的那一半（⭐ 占空比 50%）
    wire fast_off = fast_cnt[FAST_DIV-1];

    // ── ② 拍点闪拉伸（⭐ `beat_i` 来一下 ⇒ 亮 `FLASH_CYC` 拍）────────────────
    localparam [22:0] FLASH_LOAD = FLASH_CYC;
    reg [22:0] beat_t;
    always @(posedge clk) begin
        if (!rst_n)               beat_t <= 23'd0;
        else if (beat_i)          beat_t <= FLASH_LOAD;         // ⭐ 重新触发 = 延长
        else if (beat_t != 23'd0) beat_t <= beat_t - 23'd1;
    end
    wire beat_lit = (beat_t != 23'd0);

    // ── ③ 表：状态码 → {颜色, 闪烁}（⭐ 组合逻辑；⭐ 加一路 = 加一个 case）────
    reg [23:0] col_c [0:N_CH-1];
    reg [1:0]  blk_c [0:N_CH-1];
    integer    ci;

    always @* begin
        //   ⭐ 先全灭 ⇒ ⛔ 不会有"忘了写 default"留下的锁存/残值 ✅
        for (ci = 0; ci < N_CH; ci = ci + 1) begin
            col_c[ci] = C_OFF;
            blk_c[ci] = BL_STEADY;
        end

        // ── #0 音色（4 种 ⇒ 4 色常亮）────────────────────────────────────
        case (timbre_i)
            2'd0: col_c[0] = C_WHITE;
            2'd1: col_c[0] = C_CYAN;
            2'd2: col_c[0] = C_VIOLET;
            2'd3: col_c[0] = C_ORANGE;
        endcase

        // ── #1 节拍器（开 = 拍点闪绿；关 = 灭）──────────────────────────
        if (metro_on_i) begin
            col_c[1] = C_GREEN;
            blk_c[1] = BL_BEAT;
        end

        // ── #2 鼓机（4 个节奏型 4 色；关 = 灭）──────────────────────────
        //   ⚠️ 用户要 4~5 种 ⇒ ⭐ 现在 `drum_pat_i` 是 2 位（4 个型）
        //      ⇒ 将来节奏型扩到 3 位时，**只在这里加一行** ✅
        if (drum_on_i) begin
            case (drum_pat_i)
                2'd0: col_c[2] = C_RED;
                2'd1: col_c[2] = C_MAGENTA;
                2'd2: col_c[2] = C_YELLOW;
                2'd3: col_c[2] = C_ORRED;
            endcase
        end

        // ── #3 键盘打鼓（开 = 蓝；关 = 灭）──────────────────────────────
        if (keydrum_i) col_c[3] = C_BLUE;

        // ── #4 looper（空闲 / 录音 / 回放）──────────────────────────────
        case (looper_i)
            2'd1: begin col_c[4] = C_RED;   blk_c[4] = BL_FAST; end   // 录音：红快闪
            2'd2: begin col_c[4] = C_GREEN; blk_c[4] = BL_STEADY; end // 回放：绿常亮
            default: begin
                col_c[4] = C_DIMBLUE;                                     // 空闲：暗蓝常亮
                blk_c[4] = BL_STEADY;
            end
        endcase

        // ── #5 推子功能（gear）──────────────────────────────────────────
        //   ⚠️ 今天 `fader_gear` 只在 0/1 之间切 ⇒ ⭐ 2/3 是**预留行**（表先写好）✅
        case (gear_i)
            2'd0: col_c[5] = C_VIOLET;   // 变调
            2'd1: col_c[5] = C_CYAN;     // 颤音（⭐ 上电默认档）
            2'd2: col_c[5] = C_YELLOW;   // 摇把（预留）
            2'd3: col_c[5] = C_OFF;      // 无
        endcase

        // ── #6 指板 / 键盘模式 ──────────────────────────────────────────
        col_c[6] = fb_mode_i ? C_ORANGE : C_GREEN;
    end

    // ── ④ 输出级：⭐ 只把"亮/灭"按闪烁方式调制（⛔ 不动颜色）────────────────
    //   ⭐ 打一拍寄存器 ⇒ 输出无毛刺、时序好；⭐ 代价 N_CH × 24 = 168 FF（LED_N=7）
    integer oi;
    always @(posedge clk) begin
        if (!rst_n) begin
            led_col_o <= {(N_CH*24){1'b0}};
        end else begin
            for (oi = 0; oi < N_CH; oi = oi + 1) begin
                led_col_o[oi*24 +: 24] <=
                    ((blk_c[oi] == BL_FAST) &&  fast_off)  ? C_OFF :   // 快闪的"灭"半周
                    ((blk_c[oi] == BL_BEAT) && !beat_lit)  ? C_OFF :   // 拍点闪的"等下一拍"
                                                             col_c[oi];
            end
        end
    end

endmodule

`default_nettype wire
