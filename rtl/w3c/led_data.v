`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// led_data.v · LED 演奏指引映射层（键灯回显 + 下一个键闪烁 + 状态灯直通）
//              —— W3c（丙 · 输出与效果链）
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/RTL代码结构与接口规划.md` §2.5
//   本模块 = 规划里的 `led_status_map`（16 单色键灯 + 4 双色状态灯的**位映射**），
//   命名沿用待发通知 v4 §2.2 的 `led_data.v`（LED 演奏指引图案）。
//
// ⭐⭐ 职责边界（⛔ 重要：本模块是【薄映射层】，⛔ 不是"指引状态机"）：
//   · ⭐ "哪个键该按"（曲目指引）由上游 `play_seq`（甲）产出 `guide_key_i`；
//   · ⭐ "哪个键在响"（回显）由上游 `note_manager`（乙）的 `voice_active` 映射；
//   · ⭐ 本模块**只负责**：把这两张位图 + 状态灯，合并成 24 bit 图案，
//     ⛔ 不自己推算"下一拍该按什么"（那是 play_seq 的语义，⛔ 别越权重复实现）。
//
// ── 硬件事实（`files/10-硬件/硬件接口总表.md` §J7）─────────────────────────
//   · ⭐ 键帽下 **16 颗单色灯**，`TLC5916ID` ×2（每片 8 路恒流 = 16 路）→ 键灯；
//   · ⭐ 右手板 **4 双色灯**（红/绿）`TLC5916ID` ×1（4 灯 × 2 色 = 8 路）→ 状态灯；
//   ⇒ 总 24 bit = 3 片 TLC5916，`pattern_o[23:0]`：
//      `[15:0]` = 16 键灯（左手板两片）；`[23:16]` = 8 状态灯（右手板一片）。
//
// ⭐⭐ 关于"CH 序 vs OUT 序"（通知 §1.4 的坑）：
//   本模块输出的是【逻辑图案】（bit = 轴号 = CH 序，⛔ 未做物理 OUT 重排）。
//   ⭐ 物理的 **CH→OUT 重映射在【下游 `tlc5916_bank`】做**（用查表，⛔ 不用同索引算术）。
//   ⇒ ⛔ 不要在本模块里"顺手"把 bit 序当 OUT 序用 —— 那正是 §1.4 警告的镜像错位。
//
// ── 指引语义（`files/10-硬件/LED演奏指引方案.md`）──────────────────────────
//   ⭐ 赛题：脱机演奏 LED 曲目指引，辅助规范演奏节奏 ⇒ 核心 =「告诉按哪个键」。
//   ⭐ "当前按下的键" 常亮，"下一个该按（还没按）的键" 用**闪烁**区分（§4.3）。
//
// ── 设计要点 ─────────────────────────────────────────────────────────────────
//   1. ⭐ **键灯合并**：
//        · 当前按下的键（`key_active_i`）⇒ **常亮**（优先级最高）；
//        · 指引要按但还没按的键（`guide_key_i & ~key_active_i`）⇒ **闪烁**
//          （`blink_i` 为 1 的那一拍亮，否则灭 —— blink 是低速节拍，来自 beat_gen）。
//   2. ⭐ **状态灯直通**：`status_i` → `pattern_o` 高 8 bit（⛔ 不加任何变换，
//      因为它已经是"模式/音色/N 分档"的**编码结果**，本模块不该再解码）。
//   3. ⭐ **低速提交**：`pattern_commit_o` 在图案**变化的那一拍**打一个单周期脉冲
//      ⇒ 下游 `tlc5916_bank` 只在"真的变了"才重传（⛔ 不每拍刷，省功耗、省干扰）。
//   4. ⭐ 单时钟域：只用 `clk_i`，⛔ 不派生时钟、不用 PLL（冻结表 §〇 约定 1）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⭐ 组合逻辑用 `assign`；⛔ 不用 `always @(*)` 包"全是常量"的块（`L67`）
//   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module led_data #(
    // 键灯数（左手板，16 = 2 片 TLC5916）
    parameter integer KEY_N    = 16,
    // 状态灯数（右手板，8 = 1 片 TLC5916 × 4 双色灯）
    parameter integer STATUS_N = 8,
    // 50 ms at the unchanged 50 MHz board clock.
    parameter integer GUIDE_PULSE_CLKS = 2_500_000
) (
    input  wire                     clk_i,
    input  wire                     rst_n_i,          // ⭐ 同步复位、低有效（约定 2）

    // ── 输入 · 演奏指引（来自上游，⛔ 本模块不自己推算）─────────────────────
    input  wire [KEY_N-1:0]         guide_key_i,      // 曲目指引：哪些键"该按"
    input  wire [KEY_N-1:0]         key_active_i,     // 回显：哪些键"当前按下/在响"
    input  wire [STATUS_N-1:0]      status_i,         // 状态灯（模式/音色/N，已编码）
    input  wire                     blink_i,          // ⭐ 闪烁节拍（低速，来自 beat_gen 派生）

    // ── 输出 · 24 bit 图案（16 键灯 + 8 状态灯）─────────────────────────────
    output wire [KEY_N+STATUS_N-1:0] pattern_o,
    output wire                      pattern_commit_o, // ⭐ 图案变化那一拍，单周期脉冲
    // Optional for legacy users: unconnected inputs do not create pulses.
    input wire [KEY_N-1:0] guide_on_i,
    input wire             guide_clear_i

);

    // ── ⭐ 逐键显示计时与图案合并────────────────────────────────────
    //   · 常亮 = 当前按下的键（优先级最高，⛔ 不闪烁）
    //   · 闪烁 = 指引要按、但还没按的键（在 blink 高电平那一拍亮）
    wire [KEY_N-1:0] blink_keys = guide_key_i & ~key_active_i;
    wire [KEY_N-1:0] key_pattern;
    localparam integer PULSE_W = (GUIDE_PULSE_CLKS > 1)
        ? $clog2(GUIDE_PULSE_CLKS + 1) : 1;
    // One shared phase counter and independent per-key deadlines replace
    // sixteen wide decrementers. The modulo period is larger than a pulse.
    reg [PULSE_W-1:0] pulse_phase;
    wire [PULSE_W-1:0] pulse_deadline = pulse_phase + GUIDE_PULSE_CLKS;
    always @(posedge clk_i) begin
        if (!rst_n_i) pulse_phase <= {PULSE_W{1'b0}};
        else pulse_phase <= pulse_phase + 1'b1;
    end
    genvar ki, pair;
    generate
        for (ki = 0; ki < KEY_N; ki = ki + 1) begin : gen_key
            // ⭐ 当前按下 ⇒ 常亮；否则若是"要按还没按" ⇒ 跟随 blink 闪烁
            reg [PULSE_W-1:0] deadline;
            reg pulse_active;
            localparam integer EQ_PAIRS = (PULSE_W + 1) / 2;
            // Each preserved two-bit comparison fits one four-input LUT.
            // Avoid inferring sixteen long carry-based equality chains.
            (* syn_keep = 1 *) wire [EQ_PAIRS-1:0] expiry_pair;
            for (pair=0; pair<EQ_PAIRS; pair=pair+1) begin: g_expiry_pair
                if (2*pair+1 < PULSE_W) begin: g_two
                    assign expiry_pair[pair] =
                        ~(pulse_phase[2*pair] ^ deadline[2*pair])
                        & ~(pulse_phase[2*pair+1] ^ deadline[2*pair+1]);
                end else begin: g_one
                    assign expiry_pair[pair] =
                        ~(pulse_phase[2*pair] ^ deadline[2*pair]);
                end
            end
            always @(posedge clk_i) begin
                if (!rst_n_i) begin
                    deadline <= {PULSE_W{1'b0}};
                    pulse_active <= 1'b0;
                end else if (guide_clear_i === 1'b1)
                    pulse_active <= 1'b0;
                else if (guide_on_i[ki] === 1'b1) begin
                    deadline <= pulse_deadline;
                    pulse_active <= 1'b1;
                end else if (&expiry_pair)
                    pulse_active <= 1'b0;
            end
            // A note's own pulse survives an early OFF, but never modifies
            // the held ledger. Repeated ONs reload only this key's timer.
            assign key_pattern[ki] = key_active_i[ki]
                | ((blink_keys[ki] & blink_i)
                   | (pulse_active & ~key_active_i[ki]));
        end
    endgenerate

    // ── ⭐ 24 bit 图案拼装：[15:0] 键灯 + [23:16] 状态灯 ─────────────────────
    wire [KEY_N+STATUS_N-1:0] pattern_next;
    assign pattern_next = {status_i, key_pattern};

    // ── ⭐ 寄存输出（一拍对齐，避免组合毛刺直出到下游 bank）────────────────
    reg [KEY_N+STATUS_N-1:0] pattern_r;
    reg                       commit_r;

    // ⭐ 变化检测：当前寄存值 != 下一拍值 ⇒ 需要提交
    wire pattern_changed = (pattern_r !== pattern_next);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            pattern_r <= {(KEY_N+STATUS_N){1'b0}};
            commit_r  <= 1'b0;
        end else begin
            pattern_r <= pattern_next;
            // ⭐ commit 只在"图案真的变了"那一拍拉高（单周期），⛔ 每拍都刷
            commit_r  <= pattern_changed;
        end
    end

    assign pattern_o        = pattern_r;
    assign pattern_commit_o = commit_r;

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 这些组合会**静默失效**，且现象极难定位
    initial begin
        if (GUIDE_PULSE_CLKS < 1)
            $display("ERROR [led_data] GUIDE_PULSE_CLKS must be >= 1");
        if (KEY_N < 1)
            $display("ERROR [led_data] KEY_N=%0d 必须 >= 1", KEY_N);
        if (STATUS_N < 0)
            $display("ERROR [led_data] STATUS_N=%0d 必须 >= 0", STATUS_N);
    end

endmodule

`default_nettype wire
