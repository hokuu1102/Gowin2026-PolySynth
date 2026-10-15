`timescale 1ns/1ps
// ============================================================================
//  led_indicator.v -- 指示层（三层架构的【第 2 层】）：状态码 → 颜色/闪烁
//
//  三层架构（出处：files/20-代码/WS2812指示层规格-20261003.md）
//  ---------------------------------------------------------------
//    第 1 层  各子系统：它们本来就有状态 ⇒ 只引出 2~3 位状态码（~5 LUT/路）
//    第 2 层  **本模块**：状态码 → 24 位 RGB888 颜色 ＋ 闪烁方式（表驱动）
//    第 3 层  ws2812_driver：颜色 → 800 kHz 单线位时序（已有，本模块不碰）
//
//  ⚠️ **本模块不是 WS2812**：它只决定"每颗灯什么颜色、怎么闪"，
//     协议那层是 `ws2812_driver`。两者靠 `top.v` 的 `case` 接起来
//     （驱动是 16 颗的缓冲，LED7..15 恒灭）。
//
//  ⭐ **为什么是"表驱动"**：加第 9 个东西的代价 = ① 子系统引出 2~3 位（~5 LUT）
//     ＋ ② 本文件加一个 `case`（~30 LUT）＋ ③ 灯序里加一颗
//     ⇒ 完全不需要动 PHY，也不需要新增状态机。
//
// ============================================================================
//  八路语义 —— ⭐⭐ 2026-10-15 按【控制板第 3 版】重排（用户裁定）
// ============================================================================
//  出处：`files/20-代码/控制板16键功能映射-20261013.md`（第 3 版）
//  🔴 **与上一版的差别（灯序整个变了，上板前必须知道）**：
//     · 7 颗 → **8 颗**
//     · "节拍器"与"鼓机"**合并**成一颗（#3 节奏）
//     · "指板/键盘"与"键盘打鼓"**合并**成一颗（#1 16 键行为）
//     · 新增 #5 EC11 对象 + 音高状态、#6 HDMI 显示、#7 效果器
//
//   #  | 东西          | 状态码                    | 显示
//   ---|---------------|---------------------------|--------------------------------
//   0  | 音色          | timbre_i[1:0]  (4 种)     | 白 / 青 / 紫 / 橙  常亮
//   1  | 16 键行为     | fb_mode_i ＋ keydrum_i    | 橙=指板 / 绿=键盘；键盘打鼓=蓝+快闪（覆盖）
//   2  | 推子功能      | gear_i[1:0]               | 变调=紫 / 颤音=青 / 摇把=黄 / 无=灭
//   3  | 节奏          | drum_on/pat ＋ metro_on   | 鼓机 4 型色；鼓机关但节拍器开=绿；节拍器开=每拍暗 100 ms
//   4  | looper        | looper_i[1:0]             | 空闲=暗蓝 / 录音=红快闪 / 回放=绿 / 武装中=黄快闪
//   5  | EC11+音高     | transpose/slide/enc_*     | 见下方 ③
//   6  | HDMI 显示     | scope_mode_i              | 波形=蓝 / 李萨如=品红
//   7  | 效果器        | fx_en_i ＋ fx_sel_i[1:0]  | 关=灭；开=按 sel 分色
//
//  ⭐ "灭"的编码 = **颜色 0**（不另设使能位）—— WS2812 没有独立使能脚，
//     `24'h000000` 就是全灭，多一根使能线只是多一根要接错的线。
//
//  ⭐ 闪烁（只有两种计数器，全模块共享，不是 8 个）
//  -----------------------------------------------------------------
//    · `BL_FAST`：内部快闪计数器（`FAST_DIV` 位）翻转 ⇒ 灭/亮各 2^(FAST_DIV-1) 拍
//        `FAST_DIV = 23` @50 MHz ⇒ 半周期 4.19 M 拍 = 83.9 ms（整周期 167.8 ms）
//        ⇒ ≈6 Hz 闪烁（"快闪"就是给人一眼看出"在录"）
//    · `BL_BEAT_ON` / `BL_BEAT_OFF`：拍点脉冲 `beat_i` **触发一次拉伸**（`FLASH_CYC` 拍）
//        `FLASH_CYC = 5_000_000` @50 MHz = 100 ms
//        ⭐ `BL_BEAT_ON` = 亮一小段就灭（旧行为，保留给将来用）
//        ⭐ `BL_BEAT_OFF` = **暗一小段就亮**（第 3 版 #3 节奏要的"每拍短暂熄灭"）
//    两者都只调制"亮/灭"，不改变颜色 ⇒ 表里只写"该状态什么颜色"。
//
//  ⚠️ 为什么闪烁不用"每路一个计数器"：8 个计数器 = 8 份几乎相同的逻辑
//     ＋ 8 个相位（上板看起来会"各闪各的"）⇒ 共享一个 ⇒ 全板同步、省资源。
//
//  ============================================================================
//  ③ 第 5 颗（EC11 对象 + 音高状态）—— 分时显示
//  ============================================================================
//  **静止时显示音高状态**：
//    · 变调 > 0（升）  ⇒ 暖橙 FF8000
//    · 变调 < 0（降）  ⇒ 冷蓝 0080FF
//    · 变调 = 0        ⇒ 灭
//    · 滑音进行中      ⇒ 青 00FFFF（优先级高于变调 —— 正在滑的时候最需要知道）
//  **EC11 被转动或按下时，临时切换成"对象色"，持续 1 秒后回落**：
//    · 对象 = BPM      ⇒ 黄 FFFF00
//    · 对象 = 音高     ⇒ 紫 8000FF
//  理由：旋钮管什么是"你动它的那一刻"才需要知道的信息，静止时常显是浪费一颗灯。
//  实现代价：一个 26 位超时计数器（50 MHz 下 1 秒 = 5e7，需 26 位）。
//
//  可测性（判据必须能红，见 tb/w3a/tb_led_indicator.sv）
//  -------------------------------------------------------------
//    · 颜色：每档状态码都逐位比对 24 位颜色（不是"看起来对"）
//    · 闪烁：`FAST_DIV`/`FLASH_CYC` 都是参数 ⇒ tb 用小值实例化第二个 DUT，
//        在几千拍内就能量出周期与时长
//    · 已实测能红（两次真变异，见 tb 文件头的 MUTATION EVIDENCE）
// ============================================================================
`default_nettype none

module led_indicator #(
    //  指示灯颗数（控制板第 3 版 = 8：一颗对一个东西）
    parameter integer N_CH      = 8,
    //  快闪计数器位宽：半周期 = 2^(FAST_DIV-1) 拍（23 ⇒ 167.8 ms @50 MHz）
    parameter integer FAST_DIV  = 23,
    //  拍点闪的拉伸长度（拍）：5_000_000 ⇒ 100 ms @50 MHz
    parameter integer FLASH_CYC = 5_000_000,
    //  EC11 临时色的保持时间（拍）：50_000_000 ⇒ 1 秒 @50 MHz（26 位）
    parameter integer ENC_HOLD_CYC = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // ── 第 1 层：状态码（全部是各子系统现成的信号）──────────────────────
    input  wire [1:0]  timbre_i,       // 音色 0..3                    → #0
    input  wire        fb_mode_i,      // 0=键盘 · 1=指板               → #1
    input  wire        keydrum_i,      // 键盘打鼓 开/关                → #1（覆盖）
    input  wire [1:0]  gear_i,         // 0=变调 · 1=颤音 · 2=摇把 · 3=无 → #2
    input  wire        metro_on_i,     // 节拍器 开/关                  → #3
    input  wire        beat_i,         // 拍点脉冲（单周期）            → #3
    input  wire        drum_on_i,      // 鼓机是否真的在出声            → #3
    input  wire [1:0]  drum_pat_i,     // 鼓机节奏型 0..3               → #3
    input  wire [1:0]  looper_i,       // 0=空闲 1=录音 2=回放 3=武装中 → #4
    //  ⭐ 2026-10-15 新增（第 5/6/7 颗要的）
    input  wire signed [4:0] transpose_i,  // 变调半音（-12..+12）     → #5
    input  wire        slide_i,        // 滑音开关                      → #5
    input  wire        enc_act_i,      // EC11 刚被动过（脉冲/电平）    → #5 临时色
    input  wire        enc_obj_i,      // EC11 当前对象：0=BPM 1=音高   → #5 临时色
    input  wire        scope_mode_i,   // HDMI 显示：0=波形 1=李萨如    → #6
    input  wire        fx_en_i,        // 效果器使能                    → #7
    input  wire [1:0]  fx_sel_i,       // 效果器选择 0..3               → #7

    // ── 第 3 层接口：N_CH 颗灯的颜色（RGB888 平铺，LED0 在最低 24 位）──────
    output reg  [N_CH*24-1:0] led_col_o
);

    // ── 参数自检（与 looper/clk_gen 的 PARAM_OK 同一套路）────────────────
    //   ⚠️ 为什么必须有：`FLASH_CYC` 放不进 23 位时会静默截断（100 ms 变别的值，
    //      而灯照常闪 ⇒ 看不出来）⇒ 明确报出来。
    initial begin
        if (FLASH_CYC > ((1 << 23) - 1))
            $display("ERROR [led_indicator] FLASH_CYC=%0d does not fit in 23 bits", FLASH_CYC);
        if (FAST_DIV < 1)
            $display("ERROR [led_indicator] FAST_DIV=%0d must be >= 1", FAST_DIV);
        if (N_CH < 8)
            $display("ERROR [led_indicator] N_CH=%0d must be >= 8 (control board v3)", N_CH);
        if (ENC_HOLD_CYC > ((1 << 26) - 1))
            $display("ERROR [led_indicator] ENC_HOLD_CYC=%0d does not fit in 26 bits", ENC_HOLD_CYC);
    end

    // ── 闪烁方式（表里每路只写一个值）────────────────────────────────────
    localparam [1:0] BL_STEADY    = 2'd0;   // 常亮
    localparam [1:0] BL_FAST      = 2'd1;   // 快闪（内部计数器）
    localparam [1:0] BL_BEAT_ON   = 2'd2;   // 拍点闪：亮一小段就灭
    localparam [1:0] BL_BEAT_OFF  = 2'd3;   // 拍点闪：暗一小段就亮（第 3 版 #3 用）

    // ── 颜色表（24'hRRGGBB；到线上的 GRB 重排由 ws2812_driver 做）──────────
    localparam [23:0] C_OFF     = 24'h000000;   // 灭
    localparam [23:0] C_WHITE   = 24'hFFFFFF;   // 白
    localparam [23:0] C_CYAN    = 24'h00FFFF;   // 青
    localparam [23:0] C_VIOLET  = 24'h8000FF;   // 紫（与"洋红"分开：洋红 = FF00FF）
    localparam [23:0] C_ORANGE  = 24'hFF8000;   // 橙（暖橙）
    localparam [23:0] C_GREEN   = 24'h00FF00;   // 绿
    localparam [23:0] C_RED     = 24'hFF0000;   // 红
    localparam [23:0] C_MAGENTA = 24'hFF00FF;   // 洋红
    localparam [23:0] C_YELLOW  = 24'hFFFF00;   // 黄
    localparam [23:0] C_ORRED   = 24'hFF4000;   // 橙红
    localparam [23:0] C_BLUE    = 24'h0000FF;   // 蓝
    localparam [23:0] C_DIMBLUE = 24'h000030;   // 暗蓝（looper 空闲；暗到不刺眼）
    localparam [23:0] C_COOLBLUE= 24'h0080FF;   // 冷蓝（第 5 颗：变调为负）

    // ── ① 共享快闪计数器（全模块一个）──────────────────────────────────
    reg [FAST_DIV-1:0] fast_cnt;
    always @(posedge clk) begin
        if (!rst_n) fast_cnt <= {FAST_DIV{1'b0}};
        else        fast_cnt <= fast_cnt + 1'b1;
    end
    //  最高位 = "灭"的那一半（占空比 50%）
    wire fast_off = fast_cnt[FAST_DIV-1];

    // ── ② 拍点闪拉伸（beat_i 来一下 ⇒ 拉长 FLASH_CYC 拍）──────────────────
    localparam [22:0] FLASH_LOAD = FLASH_CYC;
    reg [22:0] beat_t;
    always @(posedge clk) begin
        if (!rst_n)               beat_t <= 23'd0;
        else if (beat_i)          beat_t <= FLASH_LOAD;         // 重新触发 = 延长
        else if (beat_t != 23'd0) beat_t <= beat_t - 23'd1;
    end
    wire beat_lit = (beat_t != 23'd0);

    // ── ③ EC11 临时色超时（1 秒 ⇒ 回落成音高状态）────────────────────────
    localparam [25:0] ENC_HOLD_LOAD = ENC_HOLD_CYC;
    reg [25:0] enc_t;
    always @(posedge clk) begin
        if (!rst_n)               enc_t <= 26'd0;
        else if (enc_act_i)       enc_t <= ENC_HOLD_LOAD;        // 重新触发 = 延长
        else if (enc_t != 26'd0)  enc_t <= enc_t - 26'd1;
    end
    wire enc_lit = (enc_t != 26'd0);

    // ── ④ 表：状态码 → {颜色, 闪烁}（组合逻辑；加一路 = 加一个 case）────────
    reg [23:0] col_c [0:N_CH-1];
    reg [1:0]  blk_c [0:N_CH-1];
    integer    ci;

    always @* begin
        //   先全灭 ⇒ 不会有"忘了写 default"留下的锁存/残值
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

        // ── #1 16 键行为（第 3 版：模式 + 键盘打鼓 合并）──────────────────
        //   优先级：键盘打鼓 > 模式（因为 keydrum 是覆盖式的：
        //   打开时 16 键直接产出鼓声，模式在下面但不起作用）
        //   ⚠️ 文档写"蓝 + 呼吸"，本模块只有"快闪"这一种可用效果 ⇒ 用 BL_FAST
        //      近似（呼吸要额外做正弦/三角调制，属将来优化）
        if (keydrum_i) begin
            col_c[1] = C_BLUE;
            blk_c[1] = BL_FAST;
        end else begin
            col_c[1] = fb_mode_i ? C_ORANGE : C_GREEN;   // 指板=橙 / 键盘=绿
        end

        // ── #2 推子功能（gear）──────────────────────────────────────────
        //   ⚠️ 今天 `fader_gear` 只在 0/1 之间切 ⇒ 2/3 是预留行（表先写好）
        //   📌 用户 2026-10-14 裁定：档 2 将改成"效果页"（音量颤音等参数）
        //      ⇒ 届时这里的语义从"摇把"改成"效果"，颜色可保持黄
        case (gear_i)
            2'd0: col_c[2] = C_VIOLET;   // 变调
            2'd1: col_c[2] = C_CYAN;     // 颤音（上电默认档）
            2'd2: col_c[2] = C_YELLOW;   // 摇把（预留；将来=效果页）
            2'd3: col_c[2] = C_OFF;      // 无
        endcase

        // ── #3 节奏（第 3 版：节拍器 + 鼓机 合并）────────────────────────
        //   四种组合全部可分辨：
        //     鼓机关 + 节拍器关 ⇒ 灭
        //     鼓机关 + 节拍器开 ⇒ 绿 + 每拍暗 100 ms
        //     鼓机开 + 节拍器关 ⇒ 节奏型色常亮
        //     鼓机开 + 节拍器开 ⇒ 节奏型色 + 每拍暗 100 ms
        if (drum_on_i) begin
            case (drum_pat_i)
                2'd0: col_c[3] = C_RED;
                2'd1: col_c[3] = C_MAGENTA;
                2'd2: col_c[3] = C_YELLOW;
                2'd3: col_c[3] = C_ORRED;
            endcase
        end else if (metro_on_i) begin
            col_c[3] = C_GREEN;
        end
        //  ⭐ 节拍器开着 ⇒ 无论底色是什么，都"每拍暗 100 ms"
        if (metro_on_i) blk_c[3] = BL_BEAT_OFF;

        // ── #4 looper（空闲 / 录音 / 回放 / 武装中）──────────────────────
        case (looper_i)
            2'd1: begin col_c[4] = C_RED;   blk_c[4] = BL_FAST; end   // 录音：红快闪
            2'd2: begin col_c[4] = C_GREEN; blk_c[4] = BL_STEADY; end // 回放：绿常亮
            //  ⭐⭐ 2026-10-14：码 3 = "已武装、等小节线"（黄快闪）
            //     为什么加：按下 R 后要等【下一个小节线】才真起录
            //     ⇒ 这段窗口里弹的音一个都不录 ⇒ 用户以为"第一个音被吞了"
            //     黄快闪 = "在等你，先别弹" ⇒ 等它变红（录音）再弹
            //     依据：looper.rec_pending_o ＋ top.v 的 led_looper_st
            2'd3: begin col_c[4] = C_YELLOW; blk_c[4] = BL_FAST; end  // 武装中：黄快闪
            default: begin
                col_c[4] = C_DIMBLUE;                                     // 空闲：暗蓝常亮
                blk_c[4] = BL_STEADY;
            end
        endcase

        // ── #5 EC11 对象 + 音高状态（分时）──────────────────────────────
        if (enc_lit) begin
            //  临时色：EC11 刚被动过 ⇒ 显示"它现在管什么"
            col_c[5] = enc_obj_i ? C_VIOLET : C_YELLOW;   // 音高=紫 / BPM=黄
        end else if (slide_i) begin
            col_c[5] = C_CYAN;                            // 滑音进行中（优先级最高）
        end else if (transpose_i > 5'sd0) begin
            col_c[5] = C_ORANGE;                          // 变调 > 0（暖橙）
        end else if (transpose_i < 5'sd0) begin
            col_c[5] = C_COOLBLUE;                        // 变调 < 0（冷蓝）
        end else begin
            col_c[5] = C_OFF;                             // 变调 = 0
        end

        // ── #6 HDMI 显示（0=波形 1=李萨如）──────────────────────────────
        col_c[6] = scope_mode_i ? C_MAGENTA : C_BLUE;

        // ── #7 效果器（关=灭；开=按 sel 分色）────────────────────────────
        if (fx_en_i) begin
            case (fx_sel_i)
                2'd0: col_c[7] = C_ORRED;    // 失真
                2'd1: col_c[7] = C_CYAN;     // 合唱
                2'd2: col_c[7] = C_VIOLET;   // 延迟
                2'd3: col_c[7] = C_GREEN;    // 混响（留位）
            endcase
        end
    end

    // ── ⑤ 输出级：只把"亮/灭"按闪烁方式调制（不动颜色）────────────────────
    //   打一拍寄存器 ⇒ 输出无毛刺、时序好；代价 N_CH × 24 = 192 FF（N_CH=8）
    integer oi;
    always @(posedge clk) begin
        if (!rst_n) begin
            led_col_o <= {(N_CH*24){1'b0}};
        end else begin
            for (oi = 0; oi < N_CH; oi = oi + 1) begin
                led_col_o[oi*24 +: 24] <=
                    ((blk_c[oi] == BL_FAST)     &&  fast_off)  ? C_OFF :   // 快闪的"灭"半周
                    ((blk_c[oi] == BL_BEAT_ON)  && !beat_lit)  ? C_OFF :   // 拍点闪：等下一拍
                    ((blk_c[oi] == BL_BEAT_OFF) &&  beat_lit)  ? C_OFF :   // 拍点闪：每拍暗一下
                                                                 col_c[oi];
            end
        end
    end

endmodule

`default_nettype wire
