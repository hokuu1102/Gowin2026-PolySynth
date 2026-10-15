`timescale 1ns/1ps
// ============================================================================
//  ctrl_key_map.v -- 控制板 16 键 -> 命令脉冲（与串口 calib_cmd 的输出 OR）
//
//  设计原则（见 files/20-代码/控制板16键功能映射-20261013.md）：
//    列 = 功能组，键号 idx = row*4 + col
//
//    idx  行,列   功能                        输出（与 calib_cmd 同名信号 OR）
//    ---  -----   --------------------------  --------------------------------
//     0   0,0     源 B 开关（交付档=鼓机开/关） met_req_o        （'B'）
//     1   0,1     音色循环                     timbre_req_o     （'I'）
//     2   0,2     滑音开关                     slide_req_o      （'W'）
//     3   0,3     显示切换（HDMI 波形/李萨如）  scope_mode_req_o （'E'）
//     4   1,0     键盘打鼓开关                 keydrum_req_o    （'K'）
//     5   1,1     推子档位切下一档             gear_next_req_o  （'J'）
//     6   1,2     变调 升 1 半音               trans_up_req_o   （'G'）
//     7   1,3     模式 指板/钢琴               mode_req_o       （新增，无串口命令）
//     8   2,0     鼓机节奏型 切下一个          drum_pattern_req_o（'D'）
//     9   2,1     效果器（占位）               fx_req_o         （占位，当前无消费者）
//    10   2,2     变调 降 1 半音               trans_down_req_o （'F'）
//    11   2,3     Test Mode 进/出             test_mode_req_o  （'M'）
//    12   3,0     looper 清空（长按）          loop_clear_req_o （'C'）
//    13   3,1     备用                         （无）
//    14   3,2     音高归零（恢复默认音高）      trans_reset_req_o（⭐ 2026-10-15 新增）
//    15   3,3     标定 短按=T / 长按=S         tare_req_o / span_req_o
//
//  ⭐⭐ 2026-10-15 新增 idx 14「音高归零」：
//    ⭐ 用户需求：*"矩阵键盘加一个键：一键恢复默认音高"*，⭐ 位置 = 列 2 / 行 3 ✅
//    ⭐ 语义落位：⭐ 列 2 = 音高组（滑音 / 变调升 / 变调降）⇒ ⭐ 行 3 列 2 原来是「备用 2」
//       ⇒ ⭐ **不占用任何现有功能**、⭐ 也不与 key 9（`fx_req_o` 占位）冲突 ✅
//    ⭐ 实现：⭐ 本模块**只出脉冲**，⛔ 不持有音高状态 ——
//       ⭐ 由 `top.v` 把它 OR 进 `fader_gear.trans_abs_i`、⭐ 并选值 `8'd12`
//          （⭐ `fader_gear` 内部编码 `12` = 不调 ⇒ ⭐ `transpose_semi_o = 0` ✅）
//       📌 为什么复用 `trans_abs_i` 通路：⭐ `fader_gear` **已经**有"带帧绝对量"入口
//          ⇒ ⭐ **一行 RTL 都不用改 `fader_gear.v`** ✅（⭐ 最省、⭐ 零回归风险）
//
//  长按保护（破坏性/低频操作）：
//    · idx 12 looper 清空：必须**长按** LONG_MS 才发脉冲（防误触）
//    · idx 15 标定：**短按** = tare（'T'）、**长按** = span（'S'）
//      两者共用一个键，互斥：长按触发后，松手不再发短按的那一个
//
//  为什么与 calib_cmd 的输出【OR】而不是替换：
//    calib_cmd 的下游全部只认这一组 *_req 脉冲，
//    串口与实体键【来源解耦】⇒ 加按键不用动任何下游模块
//    （依据 files/10-硬件/Console引脚与控制接口总表-20261001.md:129-130）
//
//  判据（见 tb/w3a/tb_ctrl_keypad.sv）：逐键按 ⇒ 对应 req 恰好一次、不串扰
// ============================================================================
`default_nettype none

module ctrl_key_map #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer LONG_MS = 2000          // 长按阈值（ms）
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] key_level,   // 去抖后的电平（1 = 按下）
    input  wire [15:0] key_down,    // 按下脉冲
    input  wire [15:0] key_up,      // 松开脉冲

    output reg         met_req_o,
    output reg         timbre_req_o,
    output reg         slide_req_o,
    output reg         scope_mode_req_o,
    output reg         keydrum_req_o,
    output reg         gear_next_req_o,
    output reg         trans_up_req_o,
    output reg         trans_down_req_o,
    //  ⭐⭐ 2026-10-15：⭐ idx 14（列 2 / 行 3）= 一键恢复默认音高 ✅
    //     🔴 **本 reg 只在【命令脉冲块】（下面的块 2）里赋值** ——
    //        ⚠️ 本模块曾因"同一 reg 在两个 always 块里赋值"在综合报
    //        `ERROR (EX2000) : Net ... is constantly driven from multiple places`
    //        （⭐ 而 iverilog 仿真全绿 ⇒ 🔴 "仿真过 ≠ 能综合"）✅
    //     ⭐ 所以：⭐ 复位清零 / 默认清零 / 置位 **三处都在块 2 内** ✅
    output reg         trans_reset_req_o,
    output reg         drum_pattern_req_o,
    output reg         test_mode_req_o,
    output reg         loop_clear_req_o,
    output reg         mode_req_o,        // 新增：模式切换（top.v 需接一个寄存器）
    output reg         fb_piano_o,        // 模式键「目标档」：1 = 钢琴、0 = 指板
    output reg         tare_req_o,
    output reg         span_req_o,
    output reg         fx_req_o           // 占位
);

    localparam integer LONG_CYC = (CLK_HZ / 1000) * LONG_MS;
    localparam integer HW       = (LONG_CYC <= 2) ? 1 : $clog2(LONG_CYC);

    initial begin
        if (LONG_MS < 1)
            $display("ERROR [ctrl_key_map] LONG_MS=%0d must be >= 1", LONG_MS);
        else
            $display("NOTE [ctrl_key_map] PARAM_OK=1 (CLK_HZ=%0d LONG_MS=%0d LONG_CYC=%0d HW=%0d)",
                     CLK_HZ, LONG_MS, LONG_CYC, HW);
    end

    // ── 长按计数器：只给两个需要长按的键各一个 ─────────────────────────────
    reg [HW-1:0] hold_clr;     // idx 12 looper 清空
    reg [HW-1:0] hold_cal;     // idx 15 标定
    reg          clr_long_fired;
    reg          cal_long_fired;

    wire clr_at_long = (hold_clr >= LONG_CYC[HW-1:0]);
    wire cal_at_long = (hold_cal >= LONG_CYC[HW-1:0]);

    //  🔴🔴 2026-10-14：⭐ **本块【不再碰】`clr_long_fired` / `cal_long_fired`** ✅
    //     ⭐ **原缺陷（⭐ 仿真过、综合报错 ✅）**：
    //        `ERROR (EX2000) : Net 'clr_long_fired' is constantly driven from multiple places`
    //        `ERROR (EX1999) : Found another driver here`
    //     🔴 **根因**：⭐ 两个标志在**本块**（复位 ＋ 松手清零）**和下面的命令脉冲块**
    //        （长按到阈值时置位）里**各写一次** ✅
    //     📌 ⭐ **一个 reg 只能在一个 always 块里赋值** ——
    //        ⚠️ iverilog **容忍**（后写者胜）⇒ 🔴 **仿真全绿、综合报错** ✅
    //     📌 ⭐ 这正是"**仿真过 ≠ 能综合**"（⭐ 本工程 `P1` 的立项理由 ✅）
    //     📌 ⭐ **为什么现在才发现**：⭐ 本模块**此前从未进过网表** ——
    //        ⚠️ `top.v` 一直没例化它 ⇒ 🔴 直到 2026-10-14 接线才暴露 ✅
    //     ✅ **修法**：⭐ 标志**全部归下面的命令脉冲块** ⇒ 本块只管**计数器** ✅
    always @(posedge clk) begin
        if (!rst_n) begin
            hold_clr        <= {HW{1'b0}};
            hold_cal        <= {HW{1'b0}};
        end else begin
            // idx 12：按住就计数，松手清零
            if (key_level[12]) begin
                if (!clr_at_long) hold_clr <= hold_clr + 1'b1;
            end else begin
                hold_clr       <= {HW{1'b0}};
            end

            // idx 15：同上
            if (key_level[15]) begin
                if (!cal_at_long) hold_cal <= hold_cal + 1'b1;
            end else begin
                hold_cal       <= {HW{1'b0}};
            end
        end
    end

    // ── 命令脉冲：全部单周期 ────────────────────────────────────────────────
    //   原则：一个 key_down 只产生【一个】脉冲；长按键改用计数器阈值触发。
    always @(posedge clk) begin
        if (!rst_n) begin
            met_req_o          <= 1'b0;
            timbre_req_o       <= 1'b0;
            slide_req_o        <= 1'b0;
            scope_mode_req_o   <= 1'b0;
            keydrum_req_o      <= 1'b0;
            gear_next_req_o    <= 1'b0;
            trans_up_req_o     <= 1'b0;
            trans_down_req_o   <= 1'b0;
            trans_reset_req_o  <= 1'b0;   // ⭐ idx 14（⭐ 与其余脉冲同一块、同一口径 ✅）
            drum_pattern_req_o <= 1'b0;
            test_mode_req_o    <= 1'b0;
            loop_clear_req_o   <= 1'b0;
            mode_req_o         <= 1'b0;
            fb_piano_o         <= 1'b0;
            tare_req_o         <= 1'b0;
            span_req_o         <= 1'b0;
            fx_req_o           <= 1'b0;
            //  ⭐⭐ 2026-10-14：⭐ **两个长按标志的复位【搬到本块】** ✅
            //     🔴 原缺陷见上面块 1 的注释（⭐ 多驱动 ⇒ 综合报错 ✅）
            clr_long_fired     <= 1'b0;
            cal_long_fired     <= 1'b0;
        end else begin
            // 默认全低：单周期脉冲
            met_req_o          <= 1'b0;
            timbre_req_o       <= 1'b0;
            slide_req_o        <= 1'b0;
            scope_mode_req_o   <= 1'b0;
            keydrum_req_o      <= 1'b0;
            gear_next_req_o    <= 1'b0;
            trans_up_req_o     <= 1'b0;
            trans_down_req_o   <= 1'b0;
            trans_reset_req_o  <= 1'b0;   // ⭐ idx 14（⭐ 单周期脉冲的默认低 ✅）
            drum_pattern_req_o <= 1'b0;
            test_mode_req_o    <= 1'b0;
            loop_clear_req_o   <= 1'b0;
            mode_req_o         <= 1'b0;
            tare_req_o         <= 1'b0;
            span_req_o         <= 1'b0;
            fx_req_o           <= 1'b0;

            // 行 0 · 节奏/循环组（按下沿直接出脉冲）
            if (key_down[ 0]) met_req_o          <= 1'b1;
            // 行 0 · 音色组
            if (key_down[ 1]) timbre_req_o       <= 1'b1;
            // 行 0 · 音高组
            if (key_down[ 2]) slide_req_o        <= 1'b1;
            // 行 0 · 系统组
            if (key_down[ 3]) scope_mode_req_o   <= 1'b1;

            // 行 1
            if (key_down[ 4]) keydrum_req_o      <= 1'b1;
            if (key_down[ 5]) gear_next_req_o    <= 1'b1;
            if (key_down[ 6]) trans_up_req_o     <= 1'b1;
            // 模式键：发脉冲，同时给出「目标档」
            //   按下瞬间翻转：当前是钢琴(1) 就切到指板(0)，反之亦然
            if (key_down[ 7]) begin
                mode_req_o <= 1'b1;
                fb_piano_o <= ~fb_piano_o;
            end

            // 行 2
            if (key_down[ 8]) drum_pattern_req_o <= 1'b1;
            if (key_down[ 9]) fx_req_o           <= 1'b1;   // 占位
            if (key_down[10]) trans_down_req_o   <= 1'b1;
            if (key_down[11]) test_mode_req_o    <= 1'b1;

            // 行 3 · 音高组（⭐ 2026-10-15 新增）：⭐ idx 14 = 列 2 / 行 3 ✅
            //   ⭐ 用户需求：*"矩阵键盘加一个键：一键恢复默认音高"* ✅
            //   ⭐ 语义：⭐ 列 2 是音高组（滑音 / 变调升 / 变调降）⇒ ⭐ 归零键落在这里最自然 ✅
            //   📌 ⭐ 本模块**只出脉冲**（⭐ 与 `trans_up_req_o`/`trans_down_req_o` 完全同构）——
            //      ⭐ 音高状态在 `fader_gear` 里，⛔ 本模块不持有 ⇒ ⛔ 不引入第二个状态源 ✅
            if (key_down[14]) trans_reset_req_o  <= 1'b1;

            //  ⭐⭐ 2026-10-14：⭐ **松手清标志**（⭐ 从块 1 搬过来 ✅）
            //     📌 ⭐ 顺序：⭐ 先"松手清"、⭐ 再"阈值置位" ——
            //        ⚠️ 同一拍两者**不可能同时成立**
            //        （⭐ 一个要求 `key_level=0`、⭐ 一个要求 `=1` ✅）
            if (!key_level[12]) clr_long_fired <= 1'b0;
            if (!key_level[15]) cal_long_fired <= 1'b0;

            // 行 3 · looper 清空：长按阈值到达那一刻发一次（且只发一次）
            if (key_level[12] && clr_at_long && !clr_long_fired) begin
                loop_clear_req_o <= 1'b1;
                clr_long_fired   <= 1'b1;
            end

            // 行 3 · 标定：长按 = span（阈值到达时发）；短按 = tare（松手时发，且没长按过）
            if (key_level[15] && cal_at_long && !cal_long_fired) begin
                span_req_o     <= 1'b1;
                cal_long_fired <= 1'b1;
            end
            if (key_up[15] && !cal_long_fired) tare_req_o <= 1'b1;
        end
    end

endmodule

`default_nettype wire
