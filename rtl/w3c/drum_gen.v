`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// drum_gen.v · 纯合成鼓机（Kick / Snare / Hi-hat / Tom）
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
// ── ⭐⭐ 2026-09-29：⭐ 第 4 件乐器从 **Clap（拍手）** 改成 **Tom（嗵鼓）** ─────────
//   ⭐ **为什么改**（⭐ 用户裁定）：⭐ 鼓机分类定为 **大鼓(Kick) · 小鼓(Snare) ·
//      嗵鼓(Tom) · 镲(Cymbal)** —— ⚠️ **Clap 属 GM 的"音效类"**，⭐ 曲谱里基本不出现
//      ⇒ ⭐ 留着它**占一个乐器位却没人用** ✅
//   📌 **位宽⛔ 不变**：⭐ 仍是 4 bit 掩码，⭐ **只改第 3 位（`bit3`）的语义**
//      ⇒ ⭐ `step_mask_of` 的返回格式、`pop4`、`pending_q` **一行都不用改** ✅
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
//      （⭐ 进不进保留池由**来源**决定，⛔ 不按轴号 —— 见 `note_manager.v` 的 `assign pool_mask[pg]`）
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
    parameter integer N_DRUM      = 4,      // ⭐ Kick / Snare / HiHat / Tom
    parameter integer STEPS       = 16,     // ⭐ 16 分音符为一步
    // ⭐⭐ 2026-09-29：⭐ **节奏型从【编译期参数】改成【运行时输入端口】** ✅
    //   🔴 **为什么必须改**（⭐ 用户上板要求）：⭐ "鼓机节奏型要能**现场切**" ——
    //      ⚠️ 编译期参数意味着"换一个节奏型 = 重新 PnR + 烧写"（⭐ 一次 ~10 分钟）
    //      ⇒ ⭐ 上板试听 4 个型**根本没法比**。
    //   ⭐ 现在由 `top.v` 的寄存器 `drum_pattern_r` 驱动（⭐ 串口 `'D'` 循环 `0→1→2→3→0`）。
    //   ⚠️ **原来是 `parameter integer PATTERN_ID = 0`**（⭐ 已删除）——
    //      📌 **⛔ 不保留"同名参数"**：⭐ 那会变成"设了没反应"的**静默失效**
    //         （⭐ `K-106` 纪律：会失效的东西⛔ 不许静默）。
    //   📌 **代价（⭐ 已评估，可忽略）**：⭐ 查表从"常量折叠"变成**真 mux** ——
    //      ⚠️ 但 `step_mask_of` 只有 **6 个输入位**（`pid[1:0]` + `st[3:0]`）
    //      ⇒ ⭐ 综合出来是**几个 LUT**（⛔ 不是 64 项大表）✅
    // ⭐⭐ 16 分音符 = PPQN/4 = 240 tick（⭐ `beat_gen` 的 PPQN = 960）
    parameter integer TICKS_PER_STEP = 240,
    // ⭐ 专用 voice 数（⭐ 只为 `cfg_warn` 自检 —— ⚠️ 真正生效的是 `note_manager` 那个）
    parameter integer RESERVED_N  = 5,
    //  ⭐⭐ 2026-10-01：⭐ **每件乐器的力度提到【形参表】**（⭐ 原来在体内是 `localparam`）
    //   🔴 **为什么必须提到形参表**：⚠️ 体内 `parameter` 的"按名覆盖"**在部分综合器上会被忽略**
    //      ⇒ 🔴 那就是 `K-106` 家族：⭐ **"设了没反应"的静默失效** ✅
    //      ⇒ ⭐ 提到形参表 ⇒ ⭐ 覆盖**一定生效**（⭐ 且由 `tb_met_start_top` 的判据守着 ✅）
    //   ⭐ **默认值【保持原样】**（⭐ 230/200/140/190）⇒ ⭐ 直连 `drum_gen` 的 tb **不受影响** ✅
    //   📌 音量 ∝ 力度（⭐ `perc_env_bank.v` 的 `SHIFT = ENV_W - VEL_W`：`峰值 = velocity << 8`）⇒ ⭐ 线性 ✅
    parameter [7:0]   VEL_KICK    = 8'd230,   // ⭐ 底鼓（⭐ 已接近上限，⚠️ 不建议再抬）
    parameter [7:0]   VEL_SNARE   = 8'd200,   // ⭐ 军鼓
    parameter [7:0]   VEL_HIHAT   = 8'd140,   // ⭐ 踩镲（⭐ 原偏轻）
    parameter [7:0]   VEL_TOM     = 8'd190,   // ⭐ 嗵鼓（⭐ 加花用）
    parameter [1:0]   EVT_KIND    = 2'd0
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ⭐⭐ 节奏型选择（⭐ 2026-09-29：⭐ 运行时，⭐ 由 `top.v` 的 `drum_pattern_r` 驱动）
    //   ⭐ 语义：⭐ 0~3 四选一（⭐ 见 `step_mask_of`）—— ⚠️ 只有低 2 位有意义
    //   ⭐ **随时可切**：⭐ 切换**立刻**生效（⭐ 下一步装载新表）⇒ ⭐ 不用等小节边界
    //      （⭐ 上板"边听边切"就是靠这个 ✅）
    input  wire [1:0]            pattern_id_i,

    // ── 来自 `beat_gen`（⭐ 实测它有这些输出，⛔ 一个都不用新增）─────────────
    input  wire                  tick_i,        // ⭐ PPQN tick 脉冲
    input  wire [15:0]           tick_cnt_i,    // ⭐ 小节内 tick 计数（⭐ 定位用）
    input  wire                  bar_start_i,   // ⭐ 小节起点
    input  wire                  transport_i,   // ⭐ run 状态（0 ⇒ ⛔ 不发事件）

    //  ⭐⭐⭐⭐ 2026-10-11（`P1-18`）：⭐ **音乐位置复位**（⭐ 必须与 `beat_gen.pos_reset_i` 同源）✅
    //
    //  🔴🔴 **为什么必须新增这个端口**（⭐ 审查 `[P1-18]`，⭐ 实测复现）：
    //     ⭐ `top.v` 的 `met_start`（⭐ = "开节拍器/鼓机"的上升沿脉冲）**同时喂**
    //        `beat_gen.pos_reset_i` ✅
    //     ⭐ `beat_gen` 收到它 ⇒ ⭐ **`tick_cnt_o` 在那一拍【立刻跳回 0】**
    //        （⛔ 不产生 `tick`、⛔ 不产生 `bar_start` ✅）
    //     🔴 而本模块的步进判据是**无符号差值法**（⭐ 见下方 `step_advance`）
    //        ⇒ ⭐ `0 - 300 = 65336 ≥ 240` ⇒ 🔴 **无符号下溢 ⇒ 假的 `step_advance`** ✅
    //     ⇒ ⭐ **多推进一步 ＋ 多发一条不在 16 分网格上的事件** ✅
    //     📌 ⭐ 听感（⭐ 交付默认档 `SEL_DRUM=1` = 鼓机 ⇒ ⭐ **用户能听到**）：
    //        ⭐ 每次开鼓机，⭐ 强拍前 **≈0.52 ms** 多一记 ⇒ 🔴 **紧 flam / 双击** ✅
    //
    //  ⚠️ **老例化不接本端口 ⇒ `z`** ⇒ ⭐ 由下方 `=== 1'b1` 解码为 **0**
    //     ⇒ ⭐ **行为与加本端口之前完全一致** ✅
    //     （⭐ 与 `oscillator_bank.voice_phase_rst_i` / `note_manager.vel_upd_src_i`
    //       是**同一套向后兼容口径** ✅）
    input  wire                  pos_reset_i,   // ⭐ 高有效电平/脉冲：⭐ 位置归零（⭐ 与 beat_gen 同源）

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
    //   📌 🔴 **换算式（⭐ 2026-10-01 更正）**：⭐ `phase_inc = f_out × 2^32 / `**`48000`**
    //      ⚠️ 原文写的是 `/ 50e6` —— 🔴 **那是错的**（⭐ 相位累加器是**每采样拍**走一次，
    //      ⭐ 采样率是 **48 kHz**，⛔ 不是 50 MHz 主时钟）✅
    //      ⇒ ⭐ `inc = f × 89478.4853`（⭐ 反算：⭐ `5_368_709 ⇒ 70.0 Hz` ✅）
    //
    //   ⭐⭐ 2026-10-01：⭐ **四件乐器的音高【拉开】**（⭐ 用户上板："4 个鼓听不太出来区分度"）
    //   🔴 **根因**（⭐ 已核实到 `oscillator_bank.v` 的 `rom_dout` 三选一）：
    //      ⭐ 凡被判成"鼓"的 voice，⭐ 波形**一律取噪声表 `rom_noise`**
    //      ⇒ ⭐ **音色与 4 件乐器无关** ⚠️ ⇒ ⭐ 4 件的区别**只剩【噪声播放速率】＋【扫频】** ✅
    //      ⇒ 🔴 而原来 **军鼓 192 Hz 与嗵鼓 144 Hz 只差 4.2 个半音** ⇒ ⭐ **几乎分不出来** ✅
    //   ⚠️⚠️ **分档边界【必须守住】**（⭐ `oscillator_bank.v` 用 `base_inc` 就地分档）：
    //      · `< 10_000_000`（**111.8 Hz**）⇒ ⭐ **底鼓**（⭐ 带**全深度**扫频 `>>0`）
    //      · `10_000_000 ~ 15_000_000`（**111.8~167.6 Hz**）⇒ ⭐ **嗵鼓**（⭐ 带 1/4 扫频 `>>2`）
    //      · `≥ 15_000_000` ⇒ ⭐ **军鼓 / 踩镲**（⭐ 无扫频）
    //      ⇒ 🔴 **底鼓/嗵鼓填错档 ⇒ 扫频深度跟着错** ⇒ ⭐ 听感直接变另一样 ⚠️
    //   ⭐⭐ **2026-10-01 二次拉开**（⭐ 用户："通鼓和底鼓感觉还差一点点区分度"）：
    //      ⭐ 底鼓 70 ⇒ **60 Hz**（⭐ 更深）· ⭐ 嗵鼓 160 ⇒ **200 Hz**（⭐ 更高）
    //      ⇒ ⭐ 音高比 **3.33×**（⭐ 原 2.29×）⇒ ⭐ **20.8 个半音** ✅
    //      ⚠️ **嗵鼓能上到 200 Hz 的前提**：⭐ `top.v` 把 `oscillator_bank.DRUM_TOM_MAX`
    //         从 **15M 抬到 20M**（⭐ 否则 200 Hz = 17.9M 会被判成"军鼓/踩镲"档 ⚠️）✅
    //      ⚠️ **并同时把嗵鼓的扫频调浅**（⭐ `DRUM_TOM_SWEEP_SH` 2 → **3**）
    //         ⇒ ⭐ 嗵鼓"音高下滑"更少 ⇒ ⭐ 与底鼓（⭐ **全深度** `>>0`）的包络差更远 ✅
    localparam [31:0] INC_KICK  = 32'd5_368_709;    // ⭐ ≈ 60 Hz（⭐ 原 70 ⇒ 更深）
    localparam [31:0] INC_SNARE = 32'd42_949_673;   // ⭐ ≈ 480 Hz
    localparam [31:0] INC_HIHAT = 32'd171_798_691;  // ⭐ ≈ 1920 Hz
    // ⭐⭐ 2026-09-29：⭐ `INC_CLAP`（≈1000 Hz）⇒ **`INC_TOM`** ✅
    //   ⭐ **为什么是"有音高的鼓"**：⭐ 嗵鼓的听感特征就是**有明确音高**
    //      —— ⚠️ 1000 Hz 那一档（⭐ 原 Clap）在鼓组里听着像"敲铁皮" ✅
    localparam [31:0] INC_TOM   = 32'd17_895_697;   // ⭐ ≈ 200 Hz（⭐ 原 160 ⇒ 更高）

    // ⭐ 每件乐器的力度：⭐ **已提到上面的 `#(...)` 形参表**（⭐ 2026-10-01）
    //   🔴 **为什么不在体内写 `localparam` 了**：⚠️ 体内 `parameter` 的按名覆盖
    //      在部分综合器上会被**静默忽略** ⇒ 🔴 `K-106`（⭐ "设了没反应"）✅
    //   ⭐ 定义处：⭐ 见模块头 `VEL_KICK` / `VEL_SNARE` / `VEL_HIHAT` / `VEL_TOM` ✅
    //   📌 音量的语义（⭐ 供改值时参考）：⭐ 嗵鼓是**加花乐器** ——
    //      ⚠️ 太轻（≈踩镲 140）就"听不见加花"；⚠️ 太重（≥ 底鼓 230）又会**盖住正拍重音**
    //      ⇒ ⭐ 保持 **比军鼓略轻、比镲明显重** ✅

    function [PHASE_W-1:0] inc_of;
        input [2:0] d;
        begin
            case (d)
                3'd0: inc_of = INC_KICK;
                3'd1: inc_of = INC_SNARE;
                3'd2: inc_of = INC_HIHAT;
                default: inc_of = INC_TOM;
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
                default: vel_of = VEL_TOM;
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
    //   ⭐ 位序：⭐ `step_masks[step]` 的 bit0=Kick · bit1=Snare · bit2=HiHat · bit3=Tom
    //      ⚠️ **bit3 原来是 Clap**（⭐ 2026-09-29 改成语义 = **Tom**，⭐ 见文件头）
    //      ⇒ ⭐ **掩码值一个都不用改**（⭐ 只是"第 4 件乐器"换了身份）✅
    function [15:0] step_mask_of;
        input [2:0]  pid;
        input [3:0]  st;
        reg   [15:0] m;
        begin
            case (pid)
                // ⭐⭐ **2026-09-30：⭐ 4 个节奏型【全部】换成用户给的表**（⭐ 逐格照抄）✅
                //   ⭐ 命名：⭐ `DRUM_0 = BASIC` · `DRUM_1 = HOUSE` · `DRUM_2 = ROCK`
                //            · `DRUM_3 = DANCE_FILL`
                //   ⭐ 背景：⭐ 用户上板反馈"原来的**塞得太满**、4 个型里**只有第一个能听**"
                //      ⇒ ⭐ 现在以"**能听出来是什么节奏、换 BPM 也不散**"为第一目标。
                //   ⚠️ 用户特别强调：⭐ **嗵鼓⛔ 不能落在每一拍上**
                //      （⭐ 否则嗵鼓会被听成"**第二个军鼓**"）——
                //      ⭐ 本表里嗵鼓只出现在 **step 8 / 14 / 15 / 16**（⭐ 1 基）✅
                //   📌 **锁死判据**：⭐ `tb/w3c/tb_drum_gen.sv` 的 ⑯
                //      （⭐ 4 个型 × 16 步 **位精确**比对用户表）✅
                // ⭐ 型 0：**BASIC**（⭐ 默认型）—— ⭐ 用户表：
                //    Kick 在 1/5/9/13 · Snare 在 5/13 · 镲在每个奇数步（1/3/…/15）
                //    ⛔ 本型**没有嗵鼓**（⭐ 用户表就是空的）
                //    ⚠️ step 5 / 13（1 基）上是 **Kick + Snare + 镲【三件同拍】**
                //       ⇒ ⭐ 用户表照抄；⚠️ 三件**共用 `AXIS_ID=15`** 的"抢 voice"
                //          问题（⭐ 见文件头）**本轮⛔ 未改**，⭐ 如实记录
                3'd0: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat
                        4'd1:  m = 4'b0000;
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0000;
                        4'd4:  m = 4'b0111;   // Kick + Snare + HiHat
                        4'd5:  m = 4'b0000;
                        4'd6:  m = 4'b0100;   // HiHat
                        4'd7:  m = 4'b0000;
                        4'd8:  m = 4'b0101;   // Kick + HiHat
                        4'd9:  m = 4'b0000;
                        4'd10: m = 4'b0100;   // HiHat
                        4'd11: m = 4'b0000;
                        4'd12: m = 4'b0111;   // Kick + Snare + HiHat
                        4'd13: m = 4'b0000;
                        4'd14: m = 4'b0100;   // HiHat
                        4'd15: m = 4'b0000;
                        default: m = 4'b0000;
                    endcase
                end
                // ⭐ 型 1：**HOUSE** —— ⭐ 用户表：
                //    Kick 在 1/5/9/13 · Snare 在 5/13 · 嗵鼓在 **8/16** · 镲在 **3/7/11/15**
                //    ⭐ 镲落在**后半拍**（⭐ 与型 0 的"每个奇数步"不同）⇒ ⭐ 律动更"推"
                //    ⭐ 嗵鼓 2 下（⭐ step 8/16）⇒ ⭐ ⛔ 不落在每一拍上 ✅
                3'd1: begin
                    case (st)
                        4'd0:  m = 4'b0001;   // Kick
                        4'd1:  m = 4'b0000;
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0000;
                        4'd4:  m = 4'b0011;   // Kick + Snare
                        4'd5:  m = 4'b0000;
                        4'd6:  m = 4'b0100;   // HiHat
                        4'd7:  m = 4'b1000;   // Tom
                        4'd8:  m = 4'b0001;   // Kick
                        4'd9:  m = 4'b0000;
                        4'd10: m = 4'b0100;   // HiHat
                        4'd11: m = 4'b0000;
                        4'd12: m = 4'b0011;   // Kick + Snare
                        4'd13: m = 4'b0000;
                        4'd14: m = 4'b0100;   // HiHat
                        4'd15: m = 4'b1000;   // Tom
                        default: m = 4'b0000;
                    endcase
                end
                // ⚠️ 型 2：**ROCK** —— ⭐ 用户表：
                //    Kick 在 **1/7/9/15** · Snare 在 5/13 · 镲在每个奇数步
                //    ⭐ 嗵鼓只有 **step 14**（1 基）一下 ⇒ ⭐ 它是"进副歌前的一击"
                3'd2: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat
                        4'd1:  m = 4'b0000;
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0000;
                        4'd4:  m = 4'b0110;   // Snare + HiHat
                        4'd5:  m = 4'b0000;
                        4'd6:  m = 4'b0101;   // Kick + HiHat
                        4'd7:  m = 4'b0000;
                        4'd8:  m = 4'b0101;   // Kick + HiHat
                        4'd9:  m = 4'b0000;
                        4'd10: m = 4'b0100;   // HiHat
                        4'd11: m = 4'b0000;
                        4'd12: m = 4'b0110;   // Snare + HiHat
                        4'd13: m = 4'b1000;   // Tom
                        4'd14: m = 4'b0101;   // Kick + HiHat
                        4'd15: m = 4'b0000;
                        default: m = 4'b0000;
                    endcase
                end
                // ⚠️ 型 3：**DANCE_FILL** —— ⭐ 用户表：
                //    Kick 在 **1/5/8/9/13** · Snare 在 5/13
                //    · 镲在每个奇数步 **+ step 16** · 嗵鼓 **5 下**（8/11/14/15/16）
                //    ⇒ ⭐ 本型是**加花型**，⚠️ 但嗵鼓仍⛔ **不落在每一拍上**
                //       （⭐ 用户特别强调：⭐ 否则会被听成"第二个军鼓"）✅
                3'd3: begin
                    case (st)
                        4'd0:  m = 4'b0101;   // Kick + HiHat
                        4'd1:  m = 4'b0000;
                        4'd2:  m = 4'b0100;   // HiHat
                        4'd3:  m = 4'b0000;
                        4'd4:  m = 4'b0111;   // Kick + Snare + HiHat
                        4'd5:  m = 4'b0000;
                        4'd6:  m = 4'b0100;   // HiHat
                        4'd7:  m = 4'b1001;   // Kick + Tom
                        4'd8:  m = 4'b0101;   // Kick + HiHat
                        4'd9:  m = 4'b0000;
                        4'd10: m = 4'b1100;   // Tom + HiHat
                        4'd11: m = 4'b0000;
                        4'd12: m = 4'b0111;   // Kick + Snare + HiHat
                        4'd13: m = 4'b1000;   // Tom
                        4'd14: m = 4'b1100;   // Tom + HiHat
                        4'd15: m = 4'b1100;   // Tom + HiHat（⭐ step 16）
                        default: m = 4'b0000;
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
    //      （⭐ 因为小节归零由 `bar_start_i` 那条 `step_zero_align` **优先**处理 ✅）
    //
    //   🔴🔴 2026-10-11（`P1-18`）：⭐ **原来的判据在 `tick_cnt_i` 【向后跳变】时会假推进** ✅
    //      ⭐ 原文只有 `((tick_cnt_i - tick_at_step_q) >= TPS_C)` —— ⭐ 两者都是 `[15:0]`、
    //         ⭐ **无符号** ⇒ ⚠️ `0 - 300` 得 `65336`（⭐ **下溢**）⇒ 🔴 **假 `step_advance`** ✅
    //      ⭐ 而模块头 `:33-35` 恰好把这条差值法论证成"**天然容忍跨小节跳变**" ——
    //         ⚠️ 它容忍的是**向前回绕**，⛔ **不是向后跳变** ✅
    //      ⭐ 触发条件（⭐ 实测）：⭐ `top.v` 的 `met_start` ⇒ `beat_gen` 立刻清 `tick_cnt_o` ✅
    //      ✅ **加固**：⭐ **先要求"没有后退"**（`tick_cnt_i >= tick_at_step_q`），
    //         ⭐ 再判差值 ✅ ⇒ ⭐ **一行改动、把下溢整类排除掉** ✅
    //      📌 ⭐ 为什么不影响正常路径：⭐ `bar_start_i` 那条分支**优先级更高** ⇒
    //         ⭐ 小节回绕（`959 → 0`）永远走 `step_zero_align`，⛔ 走不到这里 ✅
    reg  [15:0] tick_at_step_q;
    reg  [3:0]  step_q;
    //   ⭐ 步进脉冲（⭐ 只在 transport 有效时推进；⭐ 且 **不许后退**）
    wire        step_advance = transport_i
                             & (tick_cnt_i >= tick_at_step_q)
                             & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
    //   ⭐ 小节起点强制对齐到 step 0（⭐ 保证与鼓机/节拍器【不错拍】）
    wire        step_zero_align = transport_i & bar_start_i;
    //   ⭐⭐ 2026-10-11（`P1-18`）：⭐ **位置复位**（⭐ Z-safe 解码 ✅）
    //     ⚠️ **必须用 `=== 1'b1`**（⛔ 不是 `if (pos_reset_i)`）——
    //        ⭐ 老例化**不接**本端口 ⇒ 该位是 `z` ⇒ ⚠️ 用普通 `if` 会得到 `x`
    //        ⇒ 🔴 判据真假不定 ✅（⭐ 与 `oscillator_bank.voice_phase_rst_i` 同一个坑 ✅）
    wire        pos_rst = (pos_reset_i === 1'b1);

    // ── ⭐⭐ 待发列表（⭐ 关键点：一步可能多件乐器，必须逐个发）────────────────
    reg  [3:0]  pending_q;                  // ⭐ one-hot：本步还要发哪几件
    //   ⭐⭐ 节奏型选择：⭐ **运行时输入**（⭐ 2026-09-29 起，⭐ 原来是编译期参数）
    //      ⚠️ `step_mask_of` 的 `pid` 是 **3 位**（⭐ 表里有 4 个型 + default）
    //      ⇒ ⭐ 必须**显式补 0 扩展到 3 位**（⛔ 不能把 2 位直接接上去 ——
    //         ⚠️ 那样高位是 `x`/未定义 ⇒ 🔴 `case` 落进 `default` ⇒ **整曲静音**）
    wire [2:0]  pat_sel     = {1'b0, pattern_id_i};
    wire [3:0]  this_mask   = step_mask_of(pat_sel, step_q);
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
    wire [3:0]  mask_step0 = step_mask_of(pat_sel, 4'd0);
    wire [3:0]  mask_next  = step_mask_of(pat_sel,
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
            //  ⭐⭐ 2026-10-11（`P1-18`）：⭐ **位置复位【优先级最高】** ✅
            //     🔴 **为什么必须有它**：⭐ `beat_gen` 收到 `pos_reset` 会把 `tick_cnt_o`
            //        立刻清 0 ⇒ ⚠️ 本模块的差值法会**下溢**（⭐ 见 `step_advance` 的长注释 ✅）
            //     ✅ **做法**：⭐ 清空**步进状态** ⇒ ⭐ 等下一个 tick 的 `bar_start` 重新对齐 ✅
            //        · ⭐ `step_q <= 0`、⭐ `pending_q <= 0` ⇒ ⭐ **本拍不发任何残余事件** ✅
            //        · ⭐ `tick_at_step_q <= tick_cnt_i`（⭐ = **当拍**的位置）
            //           ⇒ ⭐ **紧接着的下一拍不会立刻假推进** ✅
            //     📌 ⭐ **既有行为【不变】**：⭐ 下一个 tick 上 `bar_start_i` 会走
            //        `step_zero_align` ⇒ ⭐ `step_q <= 0` ＋ ⭐ `pending_q <= mask_step0`
            //        ⇒ ⭐ **"开鼓机从强拍开始"照旧**（⭐ 2026-09-28 用户要求 ✅）
            //        📌 判据：⭐ `tb/w3c/tb_drum_gen_posreset.sv` 的 `J3`/`J4` ✅
            if (pos_rst) begin
                step_q         <= 4'd0;
                tick_at_step_q <= tick_cnt_i;
                pending_q      <= 4'd0;
                hit_cnt_o      <= 4'd0;
                step_evt_cnt_o <= 16'd0;
            end else if (step_zero_align) begin
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
        // ⚠️ 此告警基于**已过时的轴号判据**；⭐ 池实际按**来源** `SRC_AUX` 选
        //    （⭐ 见 `note_manager.v` 的 `assign pool_mask[pg]`）⇒ ⭐ 鼓机源恒为 `SRC_AUX`
        //    ⇒ ⚠️ 无论 `AXIS_ID` 多少，鼓事件都进**保留池**（⛔ 不会被普通音偷走）。
        if (AXIS_ID < 14)
            $display("WARNING [drum_gen] AXIS_ID=%0d < RESERVED_AXIS_BASE(14): 此告警基于已过时的轴号判据；池实际按来源 SRC_AUX 选，见 note_manager 的 pool_mask assign.", AXIS_ID);
        if (TICKS_PER_STEP < 1)
            $display("WARNING [drum_gen] TICKS_PER_STEP=%0d invalid => every tick advances a step.", TICKS_PER_STEP);
    end

endmodule

`default_nettype wire
