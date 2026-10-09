// ═══════════════════════════════════════════════════════════════════════════
//  guide_lamp.v —— 音符事件 → 灯位指引映射层（丙线 · P1 · 2026-10-03）
//
//  ⭐ 职责边界（与 `led_data` 分工）：
//    · `play_seq` 吐出的是【音符事件流】（`note_valid` + `note_data[63:0]`），
//      不是 `led_data` 需要的 16 位 one-hot「哪个键该按」位图。
//    · 本模块做这层【事件 → 位图】转换：把事件的 `axis` 字段（bit[22:19]，轴号 0..15）
//      解码成 `guide_key_o[15:0]` 的 one-hot 指引。
//    · `led_data` 负责的是【位图 → 24bit 物理图案】+ CH→OUT 重映射（下游）。
//
//  ⭐ 位域契约（必须与 `play_seq.v` / `tools/mid2evt.py` 逐位一致）：
//    · AXIS_SH = 19（4 bit，轴号 0..15）
//    · KIND_SH =  9（2 bit）：0 = note_on，1 = note_off，2 = tempo（换速，非音符）
//    · note_data 整体 64 bit，axis 位于 [22:19]，kind 位于 [10:9]。
//
//  ⭐ 语义：
//    · note_on（kind=0）→ 点亮 axis 对应灯位（下一键该按）
//    · note_off（kind=1）→ 熄灭 axis 对应灯位
//    · tempo（kind=2）→ 忽略（换速不是音符，⛔ 不得点亮任何灯）
//    · key_active_i 已按下的键 → 消隐（已按就不需要再指引）⭐ P0-28 已实装
//    · 拍点闪烁 ⛔ 本模块【不做】—— 那是 led_data 的职责（它已写 blink_keys & blink_i），
//      这里若再做会二次闪烁 ⇒ 占空比变 25%（P0-28 审查结论，⛔ 别再引 blink_i 进来）
//
//  ⭐ 非空洞性（P1 判据硬要求）：任意轴号 0..15 的 note_on 事件，
//    都能落到一个真实、非空的灯位（one-hot 位 set），满射、无空洞。
//
//  ⚠️ 只动丙线自己的文件：本模块【不实例化、不改】play_seq / note_manager / top.v，
//    仅消费 play_seq 的公开输出接口（note_valid_o / note_data_o），接线留待集成层。
// ═══════════════════════════════════════════════════════════════════════════

module guide_lamp #(
    parameter integer EVT_W = 64,        // 事件数据位宽（与 play_seq 一致）
    parameter integer AXIS_N = 16        // 键位数（轴号 0..15）
) (
    input  wire                clk_i,
    input  wire                rst_n_i,          // ⭐ 同步复位、低有效

    // ── 来自 play_seq 的音符事件流 ───────────────────────────────────────
    input  wire                note_valid_i,      // 与 note_data_i 同拍
    input  wire [EVT_W-1:0]    note_data_i,       // 事件数据（axis 在 [22:19]）

    // ── 来自采集/演奏侧的已按下键（消隐用）──────────────────────────────
    input  wire [AXIS_N-1:0]   key_active_i,      // 1 = 该键正在响/已按 ⇒ 消隐

    // ── 输出：one-hot 指引位图（⭐ 已消隐：key_active 的键不指引）───────
    output wire [AXIS_N-1:0]   guide_key_o,       // 1 = 该键「该按」且「未在响」
    output reg                 guide_commit_o     // 指引更新（单周期脉冲，可观测）
);

    // ── 位域偏移（与 play_seq 冻结契约逐位一致）────────────────────────────
    localparam integer AXIS_SH = 19;
    localparam integer KIND_SH = 9;

    // ⭐ kind 编码（冻结契约 §1.2）
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_TEMPO = 2'd2;

    // ── 组合解码（⭐ 用 assign，⛔ 不用 always @(*)，规避 L67）─────────────
    wire [1:0]  note_kind = note_data_i[KIND_SH +: 2];
    wire [3:0]  note_axis = note_data_i[AXIS_SH +: 4];   // 轴号 0..15

    wire is_note_on  = (note_kind == KIND_ON);
    wire is_note_off = (note_kind == KIND_OFF);

    // ── 指引位图寄存器 ────────────────────────────────────────────────────
    //   ⭐ one-hot 生成：note_on → 置位 axis 位；note_off → 清零 axis 位。
    //   ⚠️ 用索引赋值（`guide_raw_r[note_axis]`），⛔ 不用移位（轴号直接就是索引，
    //      保证「每个轴号 → 一个灯位」的满射、非空洞）。
    reg [AXIS_N-1:0] guide_raw_r;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            guide_raw_r    <= {AXIS_N{1'b0}};
            guide_commit_o <= 1'b0;
        end
        else begin
            // 默认：commit 单周期脉冲每拍清零
            guide_commit_o <= 1'b0;

            if (note_valid_i) begin
                if (is_note_on) begin
                    // ⭐ note_on → 点亮 axis 灯位（one-hot 置位）
                    guide_raw_r[note_axis] <= 1'b1;
                    guide_commit_o          <= 1'b1;
                end
                else if (is_note_off) begin
                    // ⭐ note_off → 熄灭 axis 灯位
                    guide_raw_r[note_axis] <= 1'b0;
                    guide_commit_o          <= 1'b1;
                end
                // ⭐ tempo（kind=2）→ 忽略，不改任何灯位
            end
        end
    end

    // ⭐ P0-28 消隐：已按下的键（key_active_i）不再指引（已按就不需要再提示）。
    //   组合 AND，+16 LUT / 0 FF，无时序代价。
    assign guide_key_o = guide_raw_r & ~key_active_i;

endmodule
