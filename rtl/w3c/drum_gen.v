`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// drum_gen.v · 纯合成鼓机（Kick / Snare / Hi-hat / Clap）
//   —— W3c（⭐ `T34` / `U-8`，⭐ 2026-09-26 实现）
//
// ── ⭐⭐ 一句话 ───────────────────────────────────────────────────────────────
//   ⭐ **它只吐事件，⛔ 不碰音频通路** —— ⭐ 鼓的"声音"由 `note_manager` 的
//      振荡器 + 包络合成出来（⭐ 事件域架构）。
//   ⇒ ⭐ **零新增音频通路、零新增合规风险**。
//
// ── 🔴 三条合规红线（⛔ 违反了整个模块不能用）────────────────────────────────
//   ① 🔴 **严禁预录 PCM** —— ⛔ 不许有"鼓采样表"、⛔ 不许 `.mem`、
//      ⛔ 不许大 `case` 常量波形表。⭐ **每个音都是"当场算出来的"**
//      （⭐ 本模块其实**不生成波形**，⭐ 它只发"敲哪个鼓、什么音高、多响"）
//   ② 🔴 **⛔ 不能用软核/MCU** —— ⭐ 纯 RTL 状态机
//   ③ ⭐ **节奏型是"结构"不是"采样"** —— ⭐ `case` 常量表里存的是
//      **{on, velocity}**（⭐ 16 步 × 4 乐器 × 5 bit ≈ 0.32 kbit ⇒ 可忽略）
//      ⚠️ **它不含任何波形样本** ⇒ ⭐ **不构成 PCM**
//
// ── ⭐ 对标模板：`metronome.v`（⭐ 接口几乎照抄）──────────────────────────────
//   ⭐ 两者架构完全同类：⭐ 收 `beat_gen` 的节拍 ⇒ ⭐ 吐事件 ⇒ ⭐ 进专用池。
//   ⇒ ⭐ `drum_gen` = **`metronome` 的"多乐器 + 节奏型"版本**。
//
// ── ⭐⭐ 16 分音符步进：⭐ 用 `tick_cnt_i` 的【差值法】 ────────────────────────
//   ⭐ PPQN = 960 ⇒ ⭐ 一个 16 分音符 = **240 tick**。
//   🔴 **为什么用"差值 ≥240"而⛔ 不用"取模 ==0"**：
//      ⚠️ `bar_start` 那一刻 `tick_cnt_i` 会**归零** ⇒ ⭐ 取模会被"跨小节跳变"搞乱
//      ⇒ 🔴 **可能丢一步或多发一步**。⭐ **差值法天然容忍跳变**。
//
// ── 🔴🔴 最容易写错的地方：⭐ 一"步"可能同时触发【多个】乐器 ──────────────────
//   ⭐ **必须"逐个发"，⛔ 不能"每步只发一个"**。
//   📌 **同族教训 `U-18b`**：⭐ `play_seq` 当年"16 项判据全过、变异体 4/4 全抓"，
//      🔴 **但 `tick` 字段从没被解码** ⇒ ⭐ 一 tick 上的 N 条被摊到 N 个 tick
//      ⇒ 🔴 **和弦被拉成琶音**（⭐ 实测一 tick 最多 **24 条**）。
//   ⇒ ⭐ 本模块用 `pending_q`（one-hot 待发列表）：⭐ **发出一个、清一个**，
//      ⭐ `evt_valid_o` 在"还有待发"时**连续拉高** ⇒ ⭐ 逐个发完为止。
//   ⭐ 判据：⭐ `hit_cnt_o` 必须等于本步 on 的乐器数。
//
// ── ⚠️ `AXIS_ID` 为什么要与节拍器分开 ────────────────────────────────────────
//   🔴 `AXIS_W = 4` ⇒ ⭐ 轴号只有 0~15 ⇒ ⭐ **≥ `RESERVED_AXIS_BASE`(=14) 只有 14/15**
//   ⭐ 节拍器占 **14**、⭐ 鼓机占 **15** ⇒ ⭐ **分开用，将来"同时用"不用返工**
//      （⚠️ 改 `AXIS_W` 会动**冻结的 64 bit 事件格式** ⇒ ⛔ 绝不改）
//   ⚠️ **4 个乐器【共用】** `AXIS_ID` ⇒ ⭐ 靠 `PHASE_INC`（音高）区分音色。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：用 SV 专有构造 ⇒ **整模块被静默丢弃**）
//   · ⭐ **不对 `integer` 参数做位选**（`K-91`）⇒ ⭐ 先落到定宽 `localparam`
//   · 🔴 **"脉冲"与"它携带的数据"必须【同拍锁存】**
//     （⚠️ `metronome` 踩过：`valid` 做成寄存器、数据是组合的 ⇒
//      🔴 **强拍永远发不出去**，⚠️ 而**计数却是对的** ⇒ 极难查）
//   · ⭐ **组合逻辑用 `assign`**（`L67`）· ⭐ 单时钟域、⛔ 不用 PLL/CPU/HLS
//   · ⭐ **声明必须先于使用**（`L66`）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module drum_gen #(
    parameter integer AXIS_W      = 4,
    parameter integer PHASE_W     = 32,
    parameter integer VEL_W       = 8,
    parameter integer AXIS_ID     = 15,     // ⭐ 4'hF（⭐ 与节拍器的 14 分开）
    parameter integer N_DRUM      = 4,      // ⭐ Kick / Snare / HiHat / Clap
    parameter integer STEPS       = 16,     // ⭐ 16 分音符为一步
    parameter integer PATTERN_ID  = 0,      // ⭐ 默认节奏型（0~3）
    // ⭐⭐ 16 分音符 = PPQN/4 = 240 tick（⭐ `beat_gen` 的 PPQN = 960）
    parameter integer TICKS_PER_STEP = 240,
    // ⭐ 专用 voice 数（⭐ 只为 `cfg_warn` 自检 —— ⚠️ 真正生效的是 `note_manager` 那个）
    parameter integer RESERVED_N  = 5,
    parameter [1:0]   EVT_KIND    = 2'd0
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ── 来自 `beat_gen`（⭐ 实测它有这些输出，⛔ 一个都不用新增）─────────────
    input  wire                  tick_i,        // ⭐ PPQN tick 脉冲
    input  wire [15:0]           tick_cnt_i,    // ⭐ 小节内 tick 计数（⭐ 定位用）
    input  wire                  bar_start_i,   // ⭐ 小节起点
    input  wire                  transport_i,   // ⭐ run 状态（0 ⇒ ⛔ 不发事件）

    // ── 事件输出（⭐ 与 `metronome` 完全同构）──────────────────────────────
    output reg                   evt_valid_o,   // ⭐ 单周期脉冲（⭐ 连续多拍=一步多鼓）
    output wire [AXIS_W-1:0]     evt_axis_o,
    output wire [PHASE_W-1:0]    evt_phase_inc_o,
    output wire [VEL_W-1:0]      evt_velocity_o,
    output wire [1:0]            evt_kind_o,

    // ── ⭐ 可观测性（`K-106`：⛔ 不许静默失效）──────────────────────────────
    output reg  [15:0]           evt_cnt_o,     // ⭐ 已发事件总数（饱和）
    output wire [3:0]            step_cnt_o,    // ⭐ 当前第几步（⭐ 上板调试用）
    output reg  [3:0]            hit_cnt_o,     // ⭐ 上一步触发了几件乐器
    output reg  [15:0]           step_evt_cnt_o,// ⭐ 上一步实际发了几个事件
    output wire                  cfg_warn_o     // ⭐ 参数不一致时报警
);

    // ⭐⭐ 整数参数先落定宽 localparam（🔴 `K-91`：⛔ 不对 integer 做位选）
    localparam [15:0] TPS_C = TICKS_PER_STEP;
    localparam [3:0]  STEPS_C = STEPS[3:0];

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 每个乐器的"音高"（= `PHASE_INC`）—— ⭐ 决定听感上是哪种鼓
    // ══════════════════════════════════════════════════════════════════════
    //   ⭐ 与 `metronome` 的 `INC_ACCENT`/`INC_NORMAL` 同一套路：
    //      ⭐ **不同的 `phase_inc` ⇒ 不同的振荡器频率**（⭐ 相位步进量）。
    //   ⚠️ 具体数值**等上板听过再调**（⭐ 现在是"低频 kick / 中频 snare /
    //      高频 hihat / 中高频 clap"的合理起点）。
    //   📌 32 位相位累加器 @50 MHz：⭐ `phase_inc = f_out × 2^32 / 50e6`
    localparam [31:0] INC_KICK  = 32'd6_442_451;    // ⭐ ≈ 75 Hz（低频"咚"）
    localparam [31:0] INC_SNARE = 32'd17_179_869;   // ⭐ ≈ 200 Hz（中频"啪"）
    localparam [31:0] INC_HIHAT = 32'd171_798_691;  // ⭐ ≈ 2000 Hz（高频"嘶"）
    localparam [31:0] INC_CLAP  = 32'd85_899_345;   // ⭐ ≈ 1000 Hz（中高频"哒"）

    // ⭐ 每件乐器的默认力度（⭐ 让鼓组听起来平衡）
    localparam [7:0] VEL_KICK  = 8'd230;
    localparam [7:0] VEL_SNARE = 8'd200;
    localparam [7:0] VEL_HIHAT = 8'd140;
    localparam [7:0] VEL_CLAP  = 8'd180;

    function [PHASE_W-1:0] inc_of;
        input [2:0] d;
        begin
            case (d)
                3'd0: inc_of = INC_KICK;
                3'd1: inc_of = INC_SNARE;
                3'd2: inc_of = INC_HIHAT;
                default: inc_of = INC_CLAP;
            endcase
        end
    endfunction

    function [VEL_W-1:0] vel_of;
        input [2:0] d;
        begin
            case (d)
                3'd0: vel_of = VEL_KICK;
                3'd1: vel_of = VEL_SNARE;
                3'd2: vel_of = VEL_HIHAT;
                default: vel_of = VEL_CLAP;
            endcase
        end
    endfunction

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 内置节奏型（⭐ `case` 常量表，⛔ 不用 `.mem`）
    // ══════════════════════════════════════════════════════════════════════
    //   🔴 **为什么不用 `.mem`**：⭐ `$readmemh` 外部 `.mem` 在 GW5AT-60
    //      **【不加载】** ⇒ ⭐ ROM 全 0 ⇒ 🔴 **没声音，但仿真全对**
    //      （⭐ 这正是 `T31` 波表验证要排在最前面的原因）。
    //
    //   ⭐ 存储格式：⭐ 返回 **16 个 4 位掩码**（⭐ 每一步一个，bit i = 第 i 件乐器）
    //      📌 用掩码而⛔ 不是"每件乐器一个 16 位向量" ⇒ ⭐ **查表一次就拿到"这一步敲哪几个"**
    //         ⇒ ⭐ 天然支持"一步多乐器"（⭐ 见文件头的关键点）。
    //
    //   ⭐ 位序：⭐ `step_masks[step]` 的 bit0=Kick · bit1=Snare · bit2=HiHat · bit3=Clap
    function [15:0] step_mask_of;
        input [2:0]  pid;
        input [3:0]  st;
        reg   [15:0] m;
        begin
            case (pid)
                // ⭐ 型 0：**四拍基本型（Rock）**
                //    Kick 在 1、3 拍（step 0/8）· Snare 在 2、4 拍（step 4/12）
                //    HiHat 每 8 分（偶数 step）
                3'd0: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat
                        4'd1:  m = 4'b0000;
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0000;
                        4'd4:  m = 4'b0010;   // Snare
                        4'd5:  m = 4'b0000;
                        4'd6:  m = 4'b0100;   // HiHat
                        4'd7:  m = 4'b0000;
                        4'd8:  m = 4'b0101;   // Kick + HiHat
                        4'd9:  m = 4'b0000;
                        4'd10: m = 4'b0100;   // HiHat
                        4'd11: m = 4'b0000;
                        4'd12: m = 4'b0010;   // Snare
                        4'd13: m = 4'b0000;
                        4'd14: m = 4'b0100;   // HiHat
                        default: m = 4'b0000;
                    endcase
                end
                // ⭐ 型 1：**八分摇滚**（HiHat 更密 + Kick 加花）
                3'd1: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0001;   // Kick（切分）
                        4'd4:  m = 4'b0110;   // Snare + HiHat  <== ⭐ 一步两件
                        4'd6:  m = 4'b0100;   // HiHat
                        4'd8:  m = 4'b0101;   // Kick + HiHat
                        4'd10: m = 4'b0100;   // HiHat
                        4'd11: m = 4'b1001;   // Kick + Clap
                        4'd12: m = 4'b0110;   // Snare + HiHat  <== ⭐ 一步两件
                        4'd14: m = 4'b0100;   // HiHat
                        default: m = 4'b0000;
                    endcase
                end
                // ⚠️ 型 2：**十六分放克**（HiHat 每 16 分 + Kick 切分）
                3'd2: begin
                    if (st[0] == 1'b0) begin
                        // ⭐ 偶数步：HiHat 恒有；特殊步再加 Kick/Snare
                        case (st)
                            4'd0:  m = 4'b0101;   // Kick + HiHat
                            4'd4:  m = 4'b0110;   // Snare + HiHat
                            4'd6:  m = 4'b0101;   // Kick + HiHat
                            4'd10: m = 4'b1001;   // Kick + Clap
                            4'd12: m = 4'b0110;   // Snare + HiHat
                            default: m = 4'b0100; // 仅 HiHat
                        endcase
                    end else begin
                        m = 4'b0100;          // ⭐ 奇数步：仅 HiHat（16 分密度）
                    end
                end
                // ⚠️ 型 3：**圆舞曲（3/4）** —— ⭐ 只有 12 步有效，其余留空
                3'd3: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat（第 1 拍）
                        4'd4:  m = 4'b0110;   // Snare + HiHat（第 2 拍）
                        4'd8:  m = 4'b0110;   // Snare + HiHat（第 3 拍）
                        default: m = 4'b0000; // ⭐ 12~15 留空（3/4 拍）
                    endcase
                end
                default: m = 4'b0000;         // ⛔ 全 0 = 静音（安全态）
            endcase
            step_mask_of = m;
        end
    endfunction

    // ⭐⭐ 掩码的"位数"（= 这一步敲几件乐器）
    //   🔴 **2026-09-26 踩坑**：⭐ 我第一版直接写 `step_mask_of(...)[3]`
    //      ⇒ 🔴 **语法错** —— ⭐ **Verilog-2001 里不能对函数返回值做位选**
    //      （⚠️ 必须先赋给 `wire`/`reg` 再选）。
    //   ⇒ ⭐ 修法：⭐ **加一个算位数的函数**（⭐ 同时比 4 个位选更清楚）
    function [3:0] pop4;
        input [3:0] m;
        begin
            pop4 = {3'b0, m[0]} + {3'b0, m[1]} + {3'b0, m[2]} + {3'b0, m[3]};
        end
    endfunction

    // ── ⭐⭐ 16 分音符步进（⭐ 差值法，⛔ 不用取模）────────────────────────────
    //   ⭐ 内部维护"上一次推进时的 tick 位置"，⭐ 与当前值求差
    //      ⇒ ⭐ 差值 ≥ 240 就推进一步 ⇒ ⚠️ **跨小节归零时天然正确**
    reg  [15:0] tick_at_step_q;
    reg  [3:0]  step_q;
    //   ⭐ 步进脉冲（⭐ 只在 transport 有效时推进）
    wire        step_advance = transport_i
                             & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
    //   ⭐ 小节起点强制对齐到 step 0（⭐ 保证与鼓机/节拍器【不错拍】）
    wire        step_zero_align = transport_i & bar_start_i;

    // ── ⭐⭐ 待发列表（⭐ 关键点：一步可能多件乐器，必须逐个发）────────────────
    reg  [3:0]  pending_q;                  // ⭐ one-hot：本步还要发哪几件
    wire [3:0]  this_mask   = step_mask_of(PATTERN_ID[2:0], step_q);
    wire        has_pending = (pending_q != 4'd0);
    //   ⭐ 本拍要发哪一件（⭐ 最低位的那个 ⇒ 逐个发，⭐ 天然公平）
    wire [1:0]  drum_idx    = pending_q[0] ? 2'd0
                            : pending_q[1] ? 2'd1
                            : pending_q[2] ? 2'd2 : 2'd3;
    wire [3:0]  drum_sel    = pending_q[0] ? 4'b0001
                            : pending_q[1] ? 4'b0010
                            : pending_q[2] ? 4'b0100 : 4'b1000;
    //   ⭐ 本拍真的发（⭐ transport 掉了 ⇒ 立刻停发，⛔ 不吐残余）
    wire        fire        = has_pending & transport_i;

    // ⭐⭐ 本步的掩码（⭐ 先落 `wire` 再选位 —— 🔴 ⛔ 不能对函数返回值直接位选）
    //   `mask_next` = 下一拍的掩码（⭐ 用于"推进时装载新的一步"）
    wire [3:0]  mask_step0 = step_mask_of(PATTERN_ID[2:0], 4'd0);
    wire [3:0]  mask_next  = step_mask_of(PATTERN_ID[2:0],
                                          (step_q == STEPS_C - 4'd1)
                                            ? 4'd0 : (step_q + 4'd1));

    // ── ⭐⭐ 事件字段（🔴 必须与 `evt_valid_o` 【同拍锁存】）──────────────────
    //   🔴 `metronome` 踩过的真 bug（2026-09-22）：
    //      ⚠️ 第一版把 `valid` 做成寄存器，而字段是**组合**的（直接跟输入走）
    //      ⇒ 🔴 **`valid` 比数据晚一拍** ⇒ 消费者在 `valid=1` 那拍读到的是
    //        **下一拍的数据** ⇒ 🔴 **强拍永远发不出去**（永远响弱拍音）
    //      ⚠️ 最阴的是：⭐ **计数却是对的** ⇒ 现象是
    //         "计数说发了强拍、声音却是弱拍" ⇒ ⭐ 极难查
    //   ⭐ 修法：⭐ **把字段在同一拍锁存**（与 `valid` 同源、同拍）
    reg [PHASE_W-1:0] evt_inc_r;
    reg [VEL_W-1:0]   evt_vel_r;

    assign evt_axis_o      = AXIS_ID[AXIS_W-1:0];   // ⭐ 常量 ⇒ 无需寄存
    assign evt_kind_o      = EVT_KIND;              // ⭐ 常量 ⇒ 无需寄存
    assign evt_phase_inc_o = evt_inc_r;             // ⭐ 寄存后（与 valid 严格同拍）
    assign evt_velocity_o  = evt_vel_r;             // ⭐ 寄存后（与 valid 严格同拍）

    assign step_cnt_o      = step_q;
    // ⭐ 参数自检（⭐ 与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）
    assign cfg_warn_o      = (RESERVED_N < 1) | (STEPS != 16) | (TICKS_PER_STEP < 1);

    // ── ⭐ 主时序 ─────────────────────────────────────────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            evt_valid_o    <= 1'b0;
            evt_inc_r      <= {PHASE_W{1'b0}};
            evt_vel_r      <= {VEL_W{1'b0}};
            evt_cnt_o      <= 16'd0;
            hit_cnt_o      <= 4'd0;
            step_evt_cnt_o <= 16'd0;
            step_q         <= 4'd0;
            tick_at_step_q <= 16'd0;
            pending_q      <= 4'd0;
        end else begin
            // ⭐ 默认：单周期脉冲"本拍来、下拍走"
            evt_valid_o <= 1'b0;

            // ══ ① 步进（⭐ 小节起点强制归零 ⇒ 与节拍器不错拍）════════════
            if (step_zero_align) begin
                // ⭐ 小节对齐：⭐ 回到 step 0，⭐ 并【重新装载】本步的鼓
                //   ⚠️ 必须**丢弃上一小节残留的 pending**（⭐ 否则会"补发"上一小节的音）
                step_q         <= 4'd0;
                tick_at_step_q <= tick_cnt_i;
                pending_q      <= mask_step0;          // ⭐ 显式取 step 0
                hit_cnt_o      <= pop4(mask_step0);
                step_evt_cnt_o <= 16'd0;
            end else if (step_advance) begin
                // ⭐ 正常推进：⭐ step+1（⭐ mod 16 ⇒ 4 位自然回绕）
                step_q         <= (step_q == STEPS_C - 4'd1) ? 4'd0
                                                             : (step_q + 4'd1);
                tick_at_step_q <= tick_cnt_i;
                pending_q      <= mask_next;
                hit_cnt_o      <= pop4(mask_next);
                step_evt_cnt_o <= 16'd0;   // ⭐ 新的一步 ⇒ 清本步事件计数
            end

            // ══ ② ⭐⭐ 发事件（⭐ 逐拍发一件 ⇒ 一步多件也能全部发完）═══════
            //   ⭐ 字段与 `valid` **同拍锁存**（🔴 见上方的 `metronome` 教训）
            if (fire) begin
                evt_valid_o    <= 1'b1;
                evt_inc_r      <= inc_of({1'b0, drum_idx});
                evt_vel_r      <= vel_of({1'b0, drum_idx});
                pending_q      <= pending_q & ~drum_sel;   // ⭐ 发一件、清一件
                evt_cnt_o      <= (evt_cnt_o == 16'hFFFF) ? evt_cnt_o
                                                          : (evt_cnt_o + 16'd1);
                step_evt_cnt_o <= (step_evt_cnt_o == 16'hFFFF) ? step_evt_cnt_o
                                                               : (step_evt_cnt_o + 16'd1);
            end

            // ⚠️ **transport 掉了 ⇒ 清空待发**（⛔ 不吐残余事件）
            //   ⭐ 与 `metronome` 的 `transport_i` 门控语义一致：⭐ "停就真停"
            if (!transport_i) begin
                pending_q      <= 4'd0;
                step_evt_cnt_o <= 16'd0;
            end
        end
    end

    // ── ⭐ 参数自检（⭐ 与项目惯例同一套路）──────────────────────────────────
    initial begin
        if (RESERVED_N < 1)
            $display("WARNING [drum_gen] RESERVED_N=%0d < 1 => note_manager has no reserved voice; drum events would be stolen by ordinary notes.", RESERVED_N);
        if (STEPS != 16)
            $display("WARNING [drum_gen] STEPS=%0d != 16 => the built-in patterns are 16-step; a different STEPS silently truncates them.", STEPS);
        if (AXIS_ID < 14)
            $display("WARNING [drum_gen] AXIS_ID=%0d < RESERVED_AXIS_BASE(14) => drum events land in the ORDINARY pool and can steal the player's voices.", AXIS_ID);
        if (TICKS_PER_STEP < 1)
            $display("WARNING [drum_gen] TICKS_PER_STEP=%0d invalid => every tick advances a step.", TICKS_PER_STEP);
    end

endmodule

`default_nettype wire
