`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tdm_render_mixer.v · TDM 渲染混音（W3b · `T56` 去桩实装）
//
// ⭐ 为什么需要它（第二周 C 组「接通出声链」的第三块）：
//   `note_manager`（`T54`）决定**谁在响**，`oscillator_bank`（`T55`）给出
//   **64 路原始波形**，而本模块负责把它们**乘上各自的包络并求和**，
//   输出**一个饱和后的单声道样本** ⇒ 这才是真正能被 `i2s_tx` 送出去的信号。
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/W3接口冻结表.md` §2.6
//   · `render_start_i`   —— 每样本**固定相位**启动（`clk_gen.frame_start` 或 `tick_audio`）
//   · `osc_sample_bus_i` —— 64 lane 原始波形，**稳定至本帧结束**
//   · `env_level_i`      —— 每 voice Q0.16 包络，**稳定至本帧结束**
//   · `dry_valid_o`      —— **固定周期**产生
//   · `dry_sample_o`     —— **饱和后**单声道（signed 24）
//   · `deadline_fault_o` —— **sticky**，未在 `RENDER_DEADLINE_CYC` 前完成
//
// ⭐ 核心设计：**乘法点共 4 处**（⛔ 不是"只有一个乘法器"）：
//   · `prod = vs × env_level[cnt]`（⭐ 见本文件的 `POLY_TARGET` 时分复用说明）—— ⭐ **唯一【时分复用】的那个**
//   · ⭐ 归一化 `sh24 × gain`（⭐ 见本文件的 `sh_norm_r` 与 `>>> (7 + OUTPUT_HEADROOM_SH)`）
//   · ⭐ 两个软膝平方器 `exc_pos*exc_pos` / `exc_neg*exc_neg`（⭐ 见本文件的 `exc_pos_d`/`exc_neg_d`）
//   ⇒ ⭐ **实测综合后 8 个 DSP**（⭐ 这是 `K-83`/`FPGA平台与资源评估.md` §3.7 的硬约束）
//   ⚠️ 60K 只有 **118 个 DSP**。若给每个 voice 配一个乘法器 ⇒ 32 个，尚可；
//      但若给每个 **lane** 配（64 个）再加上后续效果器，就会紧张。
//   ⇒ ⭐ 本模块**时分复用同一个乘法器**：一拍算一个 voice，
//      `POLY_TARGET` 拍算完整帧（32 拍），远小于 1024 拍预算。
//
//   每拍（voice `cnt`）：
//     ① `vs = Σ lane_sample`（该 voice 的 OSC_PER_VOICE 个 lane 相加）
//     ② `prod = vs × env_level[cnt]`（Q0.16）—— ⭐ **4 个乘法点中唯一【时分复用】的那个**
//     ③ 累加进 `acc`
//   ⇒ 流水：`POLY_TARGET + 2` 拍后 `dry_valid_o` 出结果。
//
// ⭐ 确定性（`A6` / `K-44`）：
//   · 拍数**固定**（⛔ 无变长搜索、⛔ 无"等到齐了再说"）
//   · `deadline_fault_o` 是 **sticky**（一旦超时永久置位）⇒ ⛔ 不会被后续正常帧掩盖
//
// ⛔ 纪律（本项目血泪）：
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⭐⭐ **组合逻辑用 `assign`/`generate`；`always @(*)` 只用在"真的读信号"的块上**
//     （`K-93`/经验库 `L67`：参数取默认值时"全是常量"的组合块**没有敏感信号
//      ⇒ 仿真器从不执行它**，而综合器却正常折叠 ⇒ **两个前端行为不一致**）
//   · ⛔ 不用 PLL、不派生时钟（冻结表 §〇 约定 1）
//   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
//   · ⛔ 不在这里做 voice 分配（那是 `note_manager`）/ 不生成波形（那是 `oscillator_bank`）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tdm_render_mixer #(
    parameter integer POLY_TARGET         = 32,
    parameter integer OSC_PER_VOICE       = 2,
    parameter integer OSC_SAMPLE_W        = 16,
    parameter integer ENV_W               = 16,
    parameter integer SAMPLE_W            = 24,
    parameter integer CLK_PER_SAMPLE      = 1024,
    // ⭐ 帧内截止拍数（冻结表 §2.6 / `A6`：必须在第 927 拍前完成）
    parameter integer RENDER_DEADLINE_CYC = 927,
    //   ⭐⭐ **2026-09-26 新增：⭐ 保留池大小**（⭐ 必须与 `note_manager.RESERVED_N` 一致）
    //      ⭐ 用途：⭐ **popcount 时排除保留池** —— ⚠️ 见下方那段长注释
    //         （⭐ 节拍器恒占 1 个保留 voice ⇒ 不排除的话**键盘音量被白降 29%**）
    parameter integer RESERVED_N          = 0,
    // Per-audio-frame de-zipper for the polyphony normalization gain.
    // 1 changes Q8.7 gain by at most 1/128 per sample (~0.4 ms for 1->2
    // voices).  0 keeps the legacy immediate update for arithmetic-only TBs.
    parameter integer NORM_GAIN_STEP      = 1,
    // Extra pre-limiter headroom for full-scale custom wavetables.  This is a
    // linear attenuation only: it preserves the AKWF samples, timbre ratios,
    // velocity response and detune behaviour.  Production uses 1 (-6.02 dB);
    // arithmetic unit tests may retain 0 for their historical exact values.
    parameter integer OUTPUT_HEADROOM_SH  = 0
) (
    input  wire                                             clk_i,
    input  wire                                             rst_n_i,
    input  wire                                             render_start_i,
    input  wire [POLY_TARGET*OSC_PER_VOICE*OSC_SAMPLE_W-1:0] osc_sample_bus_i,
    input  wire [POLY_TARGET*ENV_W-1:0]                     env_level_i,
    //   ⭐⭐ **2026-09-26 新增：⭐ 活跃 voice 掩码**（⭐ 复音归一化的输入）
    //      ⭐ 来源：`note_manager.voice_active_o`（⭐ 已存在，⛔ 不用新造信号）
    //      📌 用法：⭐ `popcount(voice_active_i)` ⇒ ⭐ 查 `1/√N` 表 ⇒ ⭐ 归一化
    input  wire [POLY_TARGET-1:0]                           voice_active_i,
    output wire                                             dry_valid_o,
    output wire signed [SAMPLE_W-1:0]                       dry_sample_o,
    output wire                                             deadline_fault_o,
    //   ⭐ 可观测：⭐ 当前生效的活跃 voice 数（⭐ 上板/调试用）
    //   ⚠️ **宽度用 `$clog2(POLY_TARGET)+1`** —— ⛔ 不能直接引用 `LW`
    //      （⚠️ `LW` 是**模块体里**的 `localparam`，⭐ **端口列表里还没定义** ⇒
    //       🔴 `Unable to bind parameter` —— ⭐ 这是 `L66`「声明先于使用」的同一族）
    output wire [$clog2(POLY_TARGET):0]                     n_active_o
);

    // ── 位宽推导（⛔ 不对 integer 参数做位选 ⇒ 先落成有宽度的 localparam）────
    localparam integer LW  = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET);
    localparam integer OW  = (OSC_PER_VOICE <= 1) ? 1 : $clog2(OSC_PER_VOICE);
    // 单 voice 内 lane 求和：+OW 位防溢出
    localparam integer SUM_W = OSC_SAMPLE_W + OW + 1;
    // lane 和 × 包络：SUM_W + ENV_W 位
    localparam integer PROD_W = SUM_W + ENV_W;
    // 累加 POLY_TARGET 个 ⇒ +LW 位
    localparam integer ACC_W = PROD_W + LW + 1;

    localparam [LW:0] CNT_LAST  = POLY_TARGET[LW:0];
    localparam [LW:0] CNT_TOTAL = (POLY_TARGET + 2);

    // ⚠️⚠️ 2026-09-21 实测踩坑（`K-99`）：⛔ **不能写 `RENDER_DEADLINE_CYC[LW:0]`** ——
    //   那是**对参数做位选**（`K-91` 同族），会把 927 截成 `927 mod 64 = 31`
    //   ⇒ ⭐ `cnt >= 31` 就置 `deadline_fault`，而 `cnt` 每帧都要走到 34
    //   ⇒ 🔴 **正常配置下每帧都误报超时**（`A6` 判据彻底失效）。
    //   ⇒ ⭐ 正确做法：**饱和到 `cnt` 能表示的最大值**（⛔ 不是截断）。
    localparam [LW:0] CNT_MAX_V  = {LW+1{1'b1}};
    localparam [LW:0] DEADLINE_C = (RENDER_DEADLINE_CYC > CNT_MAX_V)
                                   ? CNT_MAX_V
                                   : RENDER_DEADLINE_CYC[LW:0];

    // ═══════════════════════════════════════════════════════════════════════
    // ① TDM 计数器（固定拍数）
    // ═══════════════════════════════════════════════════════════════════════
    reg [LW:0]  cnt;
    reg         busy;
    reg         valid_r;

    // ═══════════════════════════════════════════════════════════════════════
    // ② ⭐ 单 voice 的 lane 求和（**组合**，每拍只算当前 `cnt` 那一个 voice）
    //    ⚠️ 本块**确实读 `osc_sample_bus_i`** ⇒ 敏感表非空（⛔ 不是 `K-93` 那种
    //       "退化成常量"的块）。
    //    ⚠️⚠️ 必须**夹住索引**：`cnt` 会走到 `POLY_TARGET+2`，
    //       而 `cnt*OSC_PER_VOICE` 在 `cnt >= POLY_TARGET` 时**越界读出 X**
    //       （⛔ 实测会污染 `prod_r`）。⇒ ⭐ 用 `cnt_sel` 夹到最后一个 voice。
    // ═══════════════════════════════════════════════════════════════════════
    // ⚠️⚠️ 2026-09-21 实测踩坑（`K-99`，**同族于 `K-91`：对参数做位选**）：
    //   原来写 `(cnt >= CNT_LAST[LW-1:0]) ? CNT_LAST[LW-1:0] : cnt[LW-1:0]`，
    //   而 `CNT_LAST = POLY_TARGET = 32 = 6'b100000` ⇒ ⭐ `CNT_LAST[4:0] = 5'b00000 = 0`
    //   ⇒ **`cnt_sel` 恒为 0** ⇒ 🔴 **每个 TDM 时隙都去读 voice0**
    //   ⇒ 多 voice 叠加、饱和、混音**全部错**（实测判据 2/3/4 一起失败）。
    //   ⇒ ⭐ 正确做法：用**最大索引**（`POLY_TARGET-1`）做夹取，且**用有宽度的 localparam**。
    localparam [LW-1:0] LAST_IDX = POLY_TARGET - 1;
    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴🔴 **2026-09-26 结构修复：⭐ voice 内部的 lane 求和【必须取平均】**
    //
    //   ⭐ **问题（⭐ 由纯 mixer headroom 实验定量证明，⛔ 不是推理）**：
    //      ⭐ `OSC_PER_VOICE=2` 的**两个 lane 完全相同** ——
    //         见 `oscillator_bank.v` 的 `base_phase_inc_i`：两个 lane 拿的是**同一个**
    //         `base_phase_inc_i[VOICE_IDX*PHASE_W +: PHASE_W]`，
    //         ⚠️ **且都没有初相偏移**（⭐ 复位后 `phase_q` 同为 0）
    //      ⇒ 🔴 **两个 lane 永远同频同相** ⇒ ⭐ `lane0 + lane1 = 2 × lane0`
    //      ⇒ 🔴 **一个 voice 就吃掉 2 倍幅度空间**，⭐ 而**没有任何音色收益**
    //         （⚠️ 注释说的"失谐叠加"**根本没实现** —— 那才是它原本的意图）
    //
    //   ⭐⭐ **实测证据**（⭐ `build/exp/exp_mixer_headroom.v` + `exp_mixer_osc2.v`）：
    //      ```
    //      【A】相干 ×2（⭐ = 修复前）: N=4 就溢出 37% · N=32 溢出 82%
    //      【B】`>>>1`（⭐ = 修复后）: N=4 完全不溢出 · N=8 才 96% ⇒ 溢出点右移 4 倍
    //      📌 B 组每个 N 的溢出次数**恰好等于 A 组 N/4 的次数**（3800/6280 精确吻合）
    //      ```
    //      ⇒ ⭐ **等价于白拿 12 dB headroom**（⭐ 幅度减半 × 相干项减半）
    //
    //   ⭐ **为什么在【这里】做而⛔ 不在 `oscillator_bank` 里做**：
    //      ⭐ 本模块是 lane 求和的**唯一**位置（⭐ `vs_c` 就是"一个 voice"）
    //      ⇒ ⭐ 改动**最小、最集中、⛔ 不碰队友文件**
    //         （⚠️ `oscillator_bank.v` 是队友的 ⇒ 见 `已知问题与风险清单.md` 的禁改清单）
    //      📌 且 `oscillator_bank` 输出的是**原始 lane 样本**（⭐ 那里保留原样更干净：
    //         ⚠️ 若将来真要 detune，⭐ 每个 lane 的原始样本都还有用）。
    //
    //   ⚠️ **`>>> 1` 而⛔ 不是 `/2`**：⭐ 算术右移**保留符号** ⇒ ⭐ 负半周正确
    //      （🔴 用 `/` 会向零取整，⭐ 负值时与右移不等价 ⇒ ⚠️ 引入直流偏置）。
    //   📌 **`OSC_PER_VOICE==1` 时**：⭐ 右移 0 位 ⇒ ⚠️ **必须是 0 而⛔ 不是 1**
    //      ⇒ ⭐ 用 `NORM_SH` 参数算出来，⛔ **不写死 1**。
    //      ⭐ 依据：⭐ 与 `SUM_W` 的位宽推导同一纪律（⭐ `K-91`：位宽必须显式落定）
    // ═══════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ **2026-09-28：lane 加权求和**（失谐音量平衡 · `Minimal-A`）
    //
    //   🔴 **要解决的问题**：两个 lane 用**完全相同的波形** ⇒
    //      反相时**相干抵消到 100%**（拍谷 = **−∞ dB**）⇒
    //      ① 长音音量周期性起伏（"一鼓一鼓"）② 起音音量随机。
    //
    //   ✅ **修法**：给两个 lane **不同的权重** ⇒ 反相时**抵消不干净**：
    //      · ⭐ **同相** = `(w0 + w1)/16` = `(9+7)/16` = **1.000** ⇒ ⭐ **响度不变**
    //        （⭐ 这正是 `gain = 88` 标定前提不被破坏的原因）
    //      · ⭐ **反相** = `|w0 − w1|/16` = `2/16` = **0.125** ⇒
    //        ⭐ 拍谷 = `20·log10(1/8)` = **−18.06 dB**（原为 −∞ dB）
    //      · ⭐ **波形本身不变** ⇒ ⛔ **音色不变**
    //
    //   ⭐ **为什么选 `9 : 7`**：⭐ `9 = 8+1`、`7 = 8−1` ⇒ **纯移位 + 加减**
    //      ⇒ ⛔ **无乘法器**（综合会把常数乘法折成移位/加减）。
    //
    //   ⚠️⚠️ **位宽纪律（⭐ 这里有一个真陷阱）**：
    //      `9·L0 + 7·L1` 最大 = `16 × 32767` = **524272** ⇒ 需要 **20 位**，
    //      而 `SUM_W` 只有 18 位 ⇒ 🔴 **中间量必须显式加宽 `LANE_WS` 位**，
    //      ⛔ 否则**静默溢出**（不报错，只是负半周先被削掉）。
    //
    //   ⚠️ **`OSC_PER_VOICE == 1` 必须【不加权】**：单 lane 没有拍，
    //      加权会**白白把电平降到 9/16**（−5 dB）⇒
    //      ⭐ 用 `w0 = 16` 实现**单位增益** ⇒ ⭐ **一条代码路径覆盖两种情况**。
    //
    //   📌 **权重和必须是 2 的幂**（= 16 ⇒ 右移 4 位即可归一，⛔ 不要除法器）。
    //   📌 **配套**：⭐ 必须与 `DETUNE_SH 8→9`（让拍**变慢**）**一起做** ——
    //      见 `files/20-代码/失谐拍频与长音起伏-方案分析-20260928.md` §15.1 的 `Minimal-A`。
    //   📌 **做成 `parameter`**（⭐ 用户要求：便于以后调拍深，⛔ 不用改逻辑）。
    // ═══════════════════════════════════════════════════════════════════════
    parameter integer LANE_WS = 4;                                    // ⭐ 权重和 = 2^4 = 16
    parameter integer LANE_W0 = (OSC_PER_VOICE <= 1) ? 16 : 9;        // ⭐ 1.125 = 9/8（单 lane ⇒ 单位增益） // 注意：仅用于自检，⛔ 不参与运算（实现在 :255 的 shift/add 恒等式里）
    parameter integer LANE_W1 = (OSC_PER_VOICE <= 1) ? 0  : 7;        // ⭐ 0.875 = 7/8 // 注意：仅用于自检，⛔ 不参与运算（实现在 :255 的 shift/add 恒等式里）

    //   ⭐ 加权和的中间位宽：⭐ **必须比 `SUM_W` 宽 `LANE_WS` 位**（见上方位宽纪律）
    localparam integer LSUM_W = SUM_W + LANE_WS;

    reg signed [SUM_W-1:0]  vs_c;
    reg signed [SUM_W-1:0]  vs_sum;    // ⭐ 普通 lane 和（⛔ 不含权重）
    reg signed [SUM_W-1:0]  vs_dif;    // ⭐ lane 差（⭐ 只用前两个 lane）
    reg signed [LSUM_W-1:0] vs_w;      // ⭐ 加权和（⛔ 不要用 `SUM_W`，会溢出）
    integer oi;

    //  ⭐⭐ **2026-09-28 实测修正：⛔ 不要用 `*`（会实例化 DSP！）**
    //     🔴 **实测代价**：第一版写成 `$signed(lane) * ((oi==0) ? 9 : 7)`
    //        ⇒ ⭐ 综合把它映射成 **DSP 乘法器**（`MULTALU27X18` **7 → 9**，**+2 个**）
    //        ⇒ ⚠️ 而本模块的设计原则是「**唯一的乘法器**（TDM 共享 ——
    //           `K-83`：60K 只有 118 个 DSP）」⇒ 🔴 **违背了它**
    //        ⇒ 副作用：`Logic Level` **11 → 26**、`Fmax` **53.443 → 52.213 MHz**
    //
    //     ✅ **修法：用代数恒等式把加权变成【纯移位 + 加减】**：
    //        ```
    //        9·L0 + 7·L1  =  8·(L0 + L1) + (L0 − L1)
    //                        └── 左移 3 ──┘   └─ 一个减法 ─┘
    //        ```
    //        ⇒ ⭐ **零乘法器**（⛔ 不占 DSP，⭐ 也不该影响 Fmax）
    //
    //     ⚠️⚠️ **Verilog 陷阱（必须显式拼接）**：⭐ **`a << 3` 的结果位宽【等于 `a`】**
    //        ⇒ ⛔ 直接写 `vs_sum <<< 3` 会**丢掉高 3 位**（🔴 静默错）
    //        ⇒ ⭐ 必须写成 `{vs_sum, 3'b0}`（⭐ 拼接会加宽到 21 位）
    //        ⇒ ⭐ 再用 `$signed(...)` 包住（⚠️ 拼接本身是**无符号**的，
    //           ⛔ 不包的话负数会算错）
    always @(*) begin
        vs_sum = {SUM_W{1'b0}};
        for (oi = 0; oi < OSC_PER_VOICE; oi = oi + 1)
            vs_sum = vs_sum + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);

        if (OSC_PER_VOICE <= 1) begin
            //   ⭐ 单 lane：⭐ **单位增益**（⛔ 不加权 —— 单 lane 没有拍，
            //      加权会白白把电平降到 9/16 = −5 dB）
            vs_c = vs_sum;
        end else if (OSC_PER_VOICE == 2) begin
            //   ⭐⭐ 双 lane 加权：⭐ **纯移位 + 加减，⛔ 零乘法器**
            vs_dif = $signed(osc_sample_bus_i[cnt_sel*2*OSC_SAMPLE_W +: OSC_SAMPLE_W])
                   - $signed(osc_sample_bus_i[(cnt_sel*2+1)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
            vs_w   = $signed({vs_sum, 3'b0}) + vs_dif;   // ⭐ 8·(L0+L1) + (L0−L1) = 9L0+7L1
            vs_c   = vs_w >>> LANE_WS;                   // ⭐ ÷16（权重和）
        end else begin
            //   ⚠️ **>2 lane：退回"取平均"**（⭐ 当前配置 `OSC_PER_VOICE = 2` ⇒ ⛔ 不会走到）
            //      📌 若将来真要 >2 lane 加权，⭐ 权重和必须重新设计成 2 的幂。
            vs_c = vs_sum >>> 1;
        end
    end

    //  ⭐⭐ **参数自检（⚠️ 这条【必须】有 —— 否则是一个静默陷阱）**
    //     🔴 **为什么必须有**：⭐ 上面的实现用的是 `(9, 7)` 的**代数恒等式**
    //        （`8·(L0+L1) + (L0−L1)`）⇒ ⚠️ `LANE_W0`/`LANE_W1` **本身并不参与运算**。
    //        ⇒ 🔴 若有人**只改这两个参数**（以为能调权重）⇒ **完全没有效果且不报错**
    //           —— ⭐ 这是经验库 `C45`「只写不读的死状态」的**最坏形式**
    //              （⭐ 它不是无害的，而是**让改动静默失效**）。
    //     ⇒ ⭐ 仿真启动时明确报错（⭐ 综合工具忽略 `initial` ⇒ 仿真侧防线，
    //        与 `clk_gen`/`event_extract`/`top` 的 `PARAM_OK` 同一套路）。
    initial begin
        if ((LANE_W0 != 9) || (LANE_W1 != 7))
            $display("ERROR [tdm_render_mixer] LANE_W0/W1 = (%0d,%0d) but the shift/add identity implements (9,7) => THE PARAMETERS HAVE NO EFFECT, update the code (see the LANE_W0 comment)",
                     LANE_W0, LANE_W1);
    end

    // ⭐ 当前 voice 的包络（Q0.16，**无符号**）
    wire [ENV_W-1:0] env_c = env_level_i[cnt_sel*ENV_W +: ENV_W];

    // ═══════════════════════════════════════════════════════════════════════
    // ③ ⭐⭐ 唯一的乘法器（TDM 共享 —— `K-83`：60K 只有 118 个 DSP）
    //    `vs_c` 有符号 × `env_c` 无符号 ⇒ 显式零扩展到有符号再乘
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [SUM_W-1:0]   vs_s   = vs_c;
    wire signed [ENV_W:0]     env_s  = $signed({1'b0, env_c});
    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;

    // ═══════════════════════════════════════════════════════════════════════
    // ④ 流水：prod 打一拍，累加用上一拍的 prod（⇒ 乘法器只实例化 1 个）
    // ═══════════════════════════════════════════════════════════════════════
    reg signed [PROD_W-1:0] prod_r;
    reg signed [ACC_W-1:0]  acc_r;

    // ═══════════════════════════════════════════════════════════════════════
    // ⑤ 超时检测（**sticky**）
    // ═══════════════════════════════════════════════════════════════════════
    reg fault_r;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            cnt      <= {(LW+1){1'b0}};
            busy     <= 1'b0;
            valid_r  <= 1'b0;
            prod_r   <= {PROD_W{1'b0}};
            acc_r    <= {ACC_W{1'b0}};
            fault_r  <= 1'b0;
        end else begin
            valid_r <= 1'b0;

            if (render_start_i) begin
                // ⭐ 新帧：**固定相位**重启（⛔ 不等上一次做完 —— 那会破坏确定性）
                cnt    <= {(LW+1){1'b0}};
                busy   <= 1'b1;
                acc_r  <= {ACC_W{1'b0}};
                prod_r <= {PROD_W{1'b0}};
            end else if (busy) begin
                // ⭐ 累加**上一拍**的乘积（乘法器输出已寄存）
                if (cnt >= 1 && cnt <= CNT_LAST)
                    acc_r <= acc_r + prod_r;

                // ⭐ 乘法器输入用**当前** `cnt`（下一拍 `prod_r` 就是它的结果）
                prod_r <= prod_c;

                if (cnt == CNT_TOTAL[LW:0]) begin
                    // ⭐ 全部完成：本拍 `acc_r` 已含最后一个乘积（上面刚加过）
                    busy    <= 1'b0;
                    valid_r <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end

                // ⭐⭐ 超时判据：若到 `DEADLINE_C` 还没做完 ⇒ **sticky 置位**
                //    ⚠️⚠️ 必须用**夹取后**的 `DEADLINE_C`（`K-99`）——
                //       原来写 `RENDER_DEADLINE_CYC[LW:0]` 会把 927 截成 31
                //       ⇒ 每帧都误报超时（实测判据 1 失败）。
                //    ⚠️ 用 `>=` 且**只置位不清除**（sticky）⇒ ⛔ 不会被后续正常帧掩盖
                if (cnt >= DEADLINE_C)
                    fault_r <= 1'b1;
            end
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⑥ 饱和输出（`acc_r >> 16` 还原 Q0.16，再夹到 signed SAMPLE_W）
    //
    // ⚠️⚠️ 2026-09-21 实测踩坑（`K-101`）：原来写成
    //     `localparam signed [ACC_W-1:0] MAX_V = (1 <<< 23) - 1;` + `if (shifted > MAX_V)`
    //   ⇒ ⛔ **iverilog 不认 `localparam` 上的 `signed`** ⇒ 比较退化成**无符号**
    //   ⇒ 🔴 **正数被误判成"小于 MIN_V"** ⇒ 输出被错夹成负值
    //     （实测：应为 +2097120，实得 **−2097120**）。
    //   ⇒ ⭐ 正确做法：**不依赖 `signed` 限定符**，改成**逐位判断溢出**
    //     （标准做法：若符号位之上的任何一位与符号位不同 ⇒ 溢出）。
    //     ⭐ 这样**完全不用比较**，也就不存在有无符号的问题。
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [ACC_W-1:0] sh = acc_r >>> ENV_W;

    // ⭐ 溢出判据（⛔ 无比较、无 signed 依赖）：
    //    正数溢出 = 符号位是 0，而**高位区**有任何 1
    //    负数溢出 = 符号位是 1，而**高位区**有任何 0
    //
    // ═══════════════════════════════════════════════════════════════════════
    // 🔴🔴 **2026-09-26 上板实测修复：⭐ 输出量纲少了「16 位 → 24 位」的定标**
    //
    //   ⭐ **上板症状**（⭐ 用户实测）：
    //      · ⭐ 主工程**声音极小**（⭐ 而 `dac_tone_fmt1.fs` 直出正弦**超级大**）
    //      · ⭐ 模块 `OUTL` **几乎测不到幅度**
    //      · ⭐ **电流声/底噪很重**（⭐ 信号太小 ⇒ 信噪比崩）
    //
    //   ⭐ **逐级实测**（⭐ 探针 `build/probe_amp.v`，⛔ 不是推理）：
    //      ```
    //      ① 波表输出   32765  (99% 满幅)  ✅ 正常
    //      ② 包络电平   50540  (77%)       ✅ 正常
    //      ③ mixer 输出 109147             🔴 数值合理，但**放错了位置**
    //      ④ master_mix 109147             ⚠️ 直通
    //      ⑤ sample_mono 109147            🔴 i2s_tx 只取高 16 位 ⇒ 426
    //      ```
    //
    //   🔴 **根因：⭐ 量纲/对齐不匹配**
    //      · ⭐ 本模块的输入是 **16 位原始波表**（`OSC_SAMPLE_W=16`）
    //        ＋ Q0.16 包络 ⇒ `(wave × env) >> 16` 的结果**仍是 16 位量级**。
    //      · ⭐ 而**下游约定 24 位是【左对齐】**（⭐ 有效数据在高 16 位）：
    //        · `voice.v` 的 `sample_out` 赋值  `sample_out <= {scaled_16, 8'b0}`  ← ⭐ **×256**
    //        · `i2s_tx`      取 `min(DATA_BITS,SAMPLE_W)` = **高 16 位**
    //        · `voice_i2s_chain.v` 的 `.sample_l` 连接 把 `voice.sample_out` **直连** `i2s_tx`
    //          ⇒ ⭐ **这就是设计契约**（⭐ 有现成先例背书）
    //      🔴 **但本模块用 `sh[SAMPLE_W-1:0]`（右对齐）** ⇒
    //         ⭐ `i2s_tx` 取到的高 16 位 = `109147 >> 8` = **426**
    //         ⇒ 🔴 **只用掉满幅的 1.3%** ⇒ ⭐ **这就是"声音很小"的确切原因**。
    //      📌 同时解释了**电流声**：⭐ 有效位只剩 1.3% ⇒ 🔴 **信噪比塌了**
    //         （⭐ 底噪没变，信号小了 ~38 dB）。
    //
    //   ⭐ **修法**：⭐ **在饱和之前，把结果左移到「高 16 位」**
    //      ⛔ 不能裸左移到底 —— ⚠️ `acc_r` 是 **32 个 voice 的和**，
    //      当前只有 2~3 个在响 ⇒ 裸左移 8 位会**超 24 位 3.3 倍**。
    //      ⇒ ⭐ **左移 8 位 + 复用下面已有的饱和逻辑** ⇒
    //         ⭐ 小信号得到完整幅度（⭐ 修好音量），
    //         ⭐ 满复音时**饱和削顶**（⭐ 这是"音量太大"该有的正确行为）。
    //      📌 **饱和判据要对齐到新的量纲** ⇒ `over_*` 的边界随之改成检查 `sh24`。
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 左移到「高 16 位」（⭐ 与 `voice.v` 的 `{scaled_16, 8'b0}` 同一约定）
    localparam integer SCALE_UP = SAMPLE_W - 16;      // ⭐ 24-16 = 8
    wire signed [ACC_W-1:0] sh24 = sh <<< SCALE_UP;
    //   ⚠️ `over_pos`/`over_neg` 的声明**移到归一化与限幅之后**
    //      （⭐ 因为饱和判据现在要打在【限幅后】的 `sh_final` 上——⭐ 见下方）

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ **2026-09-26 新增：复音归一化（`1/√N`）+ 软限幅**
    //
    //   🔴 **为什么必须加**（⭐ 上板实测）：
    //      ⭐ 复音是**线性叠加**（⭐ 物理：喇叭位移 = 各波之和）
    //      ⇒ ⭐ **3 个音就到 100%** ⇒ 🔴 **实测削顶率 28.7%**
    //        （⭐ 证据：`sim/evidence/wav_export/01_chord.wav` 的幅度分布
    //          在最高区间 `28672~32767` 堆了 **7878** 个样点 = 典型平顶）
    //      ⇒ ⚠️ 听感"嘈杂、破音、失真"
    //
    //   ⭐ **为什么是 `1/√N` 而⛔ 不是 `1/N`**（⭐ 有行业依据）：
    //      ⭐ 不同频率的波【功率相加】而⛔ 不是幅度相加 ⇒
    //      ⭐ **`1/√N` 才能保持【响度】恒定**（⭐ 即"听感正常"）。
    //      📌 出处：音频 DSP 实践者的标准答复 ——
    //         *"Dividing by the number of tones played will prevent clipping,
    //           **BUT to maintain constant signal power when mixing uncorrelated
    //           tones (which is probably what you want), you should divide by the
    //           square root** of the number of tones."*
    //      ⚠️ **但 `1/√N` 会【超】不削顶所需的增益**（⭐ 实测：N=32 时超 5.66 倍）——
    //         因为**峰值按 `N` 增长，⚠️ 但它们【越来越罕见】**（⭐ 中央极限定理）
    //      ⇒ ⭐ **所以必须配【软限幅】兜底**（⭐ 这就是本块下半部分的作用）。
    //
    //   ⭐ **定标（⭐ 关键设计）**：
    //      ⭐ 单 voice 峰值 = `OSC_PER_VOICE × 32767 ≈ 65532`
    //      ⭐ "不削顶"允许的增益 = `2^23 / (65532 × N) = 128 / N`
    //      ⇒ ⭐ 取 **`gain(N) = 128 / √N`**（⭐ Q8.7 定点，⭐ 即"128 为 1.0"）
    //      📌 校验：N=1 ⇒ 128（⭐ = 满幅，✅ 单音饱满）
    //               N=4 ⇒  64（⭐ 峰值 = 4×65532×64/128 = 131064 ⇒ ⚠️ 超 2 倍 ⇒ 靠限幅）
    //               N=32⇒  22（⭐ 单音占 17% ⇒ ✅ 听感正常，⛔ 不像 `1/N` 那样只有 3%）
    //
    //   ⭐ **软限幅（⭐ 阈值 87.5%，超出走二次软膝 + 平台）**：
    //      ⭐ `|x| <= T` ⇒ ⭐ 直通（⭐ **日常 1~4 音完全不失真**）
    //      ⭐ `|x| >  T` ⇒ ⭐ `T + e − e²/(2W)`（`e = |x| − T`）；`e ≥ W` ⇒ ⭐ **平台 93.75%**
    //      📌 **为什么是"压缩"而⛔ 不是"截断"**：⭐ 截断产生**平顶** ⇒ 听感"破"；
    //         ⭐ 压缩保留波形形状 ⇒ ⭐ 听感"厚"（⭐ 只是动态被压了一点）。
    // ═══════════════════════════════════════════════════════════════════════

    // ── ① ⭐ popcount：数当前有几个 voice 活跃 ─────────────────────────────
    //   ⚠️ 用**显式加法树**（⛔ 不用 `$countones` —— 那是 SV 构造，`K-91`）
    //   （⭐ `n_active` 的声明已移到下方流水段 —— ⚠️ 它是**寄存器**）
    // ── ① ⭐ popcount：数当前有几个 voice 活跃（⭐ **两级加法树**）──────────
    //   ⚠️ 用**显式加法树**（⛔ 不用 `$countones` —— 那是 SV 构造，`K-91`）
    //
    //   🔴🔴 **2026-09-26 修正：⭐ 原来是【一条 32 位长的组合链】⇒ 拖垮时序**
    //      ⭐ **实测证据**（⭐ PnR）：
    //         · ⭐ 加归一化前：`Fmax = 55.263 MHz`（⭐ 余量 +10.5%）
    //         · 🔴 加归一化后：`Fmax = **39.488 MHz**`（🔴 **低于 50 MHz 约束**）
    //           ＋ 🔴 **16 个 Setup Violated**
    //      🔴 **根因**：⭐ 我把一整条链**全做成组合**：
    //         `popcount(32位加法树) → 查表 → 32×16 乘法 → 移位 → 限幅比较`
    //         ⇒ ⚠️ **一级都没切** ⇒ 🔴 关键路径暴涨。
    //      ⭐⭐ **修法：⭐ 打拍流水**（⭐ 见下方三级寄存器）
    //      📌 **为什么可以打拍而⛔ 不影响功能**：
    //         ⭐ 这些量**都是"每帧才变一次"的慢变量**（`voice_active_i` 一帧内不变）
    //         ⭐ 而本模块**一帧有 1024 拍、只用了 34 拍** ⇒ ⭐ **有大量空闲拍可插寄存器**
    //         ⚠️ 代价：⭐ `dry_valid_o` 要**跟着延时**（⭐ 见下方 `valid_d` 移位链）
    // ═══════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════
    //   🔴🔴 **2026-09-26 上板实测修复：⭐ popcount 必须【排除保留池】**
    //
    //   ⭐ **上板症状**：⭐ 用户 *"能听见音高了，但比起节拍器要小很多"*。
    //
    //   🔴 **根因**：⭐ `voice_active_i` **包含保留池**（⭐ 最高 `RESERVED_N` 个 voice，
    //      给节拍器/鼓机用）⇒ ⭐ **节拍器是【free-running】的，恒占 1 个 voice**
    //      ⇒ 🔴 **你按 1 个键时 `N = 2`（不是 1！）**
    //      ⇒ ⭐ `gain(2) = 49` 而 `gain(1) = 70` ⇒ 🔴 **白白降了 29%**。
    //
    //   ⭐ **语义上本来就该排除**：⭐ 保留池是**独立声部**（⭐ 节拍器/鼓机），
    //      ⚠️ **它的存在不该压低【演奏】的音量** ——
    //      🔴 否则"节拍器一响，键盘就变轻"，⭐ 那是**耦合错误**。
    //   📌 **且它还会造成"音量随节拍器跳动"** —— ⚠️ 若节拍器 voice 有开有关，
    //      ⭐ `N` 会抖动 ⇒ 🔴 **增益抖动 ⇒ "滋滋声"**（⭐ 与用户报告吻合）。
    //
    //   ⚠️ **代价**：⭐ 节拍器自己的音量**会相对变大**（⭐ 它的 `N` 也变小了）。
    //      ⭐ 这正好配合本轮的"**节拍器调小**"（⭐ 见 `metronome.VEL_*`）。
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 普通池的 voice 数（⭐ 不含保留池）
    //   ⚠️ 必须与 `top.v` 的 `note_manager.RESERVED_N` 一致
    localparam integer NORMAL_N = (RESERVED_N >= POLY_TARGET)
                                  ? 0 : (POLY_TARGET - RESERVED_N);

    //   级 1：两两配对相加（⭐ 32 → 16 个数，每级路径只有 1 个加法器）
    //   ⭐ **只数普通池**（⭐ 索引 < NORMAL_N 的才计入）
    wire [LW:0] pc_l1 [0:POLY_TARGET/2-1];
    genvar gi;
    generate
        for (gi = 0; gi < POLY_TARGET/2; gi = gi + 1) begin : g_pc1
            //   ⭐ 两个 lane 各自判定是否在普通池内（⭐ 超出的按 0 计）
            assign pc_l1[gi] = ((gi*2   < NORMAL_N) ? {{LW{1'b0}}, voice_active_i[gi*2]}   : {(LW+1){1'b0}})
                             + ((gi*2+1 < NORMAL_N) ? {{LW{1'b0}}, voice_active_i[gi*2+1]} : {(LW+1){1'b0}});
        end
    endgenerate

    //   级 2：再求和（⭐ 16 → 1，⭐ 组合，但只剩 16 项 ⇒ 路径短得多）
    //      📌 综合器会把这 16 项**自动做成平衡树**（⛔ 不是串行长链）
    reg [LW:0] pc_sum;
    integer pi;
    always @(*) begin
        pc_sum = {(LW+1){1'b0}};
        for (pi = 0; pi < POLY_TARGET/2; pi = pi + 1)
            pc_sum = pc_sum + pc_l1[pi];
    end

    //   ⭐ **寄存器级 A**：`n_active` 锁存（⭐ 切断"popcount → 查表"这一段）
    reg [LW:0] n_active_r;
    //  ⭐⭐ **2026-09-28 修（上板实测「偶发尖音」的头号候选）**
    //
    //  🔴 **原写法**：`n_active_r <= pc_sum;` —— 【每 clk 都锁存】，自由运行
    //     ⇒ `norm_gain_r <= gain_sqrt_lut(n_active_r)` 也跟着每 clk 更新
    //     ⇒ ⭐【归一化增益可以在【一帧中间】跳变】
    //     ⇒ 它乘的样本在同一帧内【幅度突变】⇒ ⭐ 一个单拍阶跃
    //     ⇒ ⭐⭐ **DAC 保持期内出现单点毛刺**
    //        （📌 实测 DS0006：50 ns/点、单个采样点跳 7~15 个 DAC LSB，
    //         偏差全部量化在 0.00008 V 的整数倍 ⇒ 是真实输出跳变，不是示波器噪声）
    //     ⇒ 幅度跳变最大 = 88/16 = 【5.5 倍】⇒ 听感「尖、比正常大很多」
    //
    //  ✅ **修法**：⭐ 只在 `render_start_i`（帧边界）锁存
    //     ⇒ ⭐ 增益在整个帧内【恒定】⇒ ⛔ 不可能帧内跳变
    //     ⇒ ⭐ 增益与它乘的数据【同源】（都是本帧的快照）
    //
    //  ⭐ 2026-09-29：帧边界锁存只能消除【帧内】跳变，仍会把 1->2 voice
    //     的 gain 从 64 一拍跳到 45，使已在 sustain 的声音瞬降约 30%。
    //     因此下方 `norm_gain_r` 在每个音频帧最多走 `NORM_GAIN_STEP`，
    //     默认 1 时约 0.39 ms 完成 64->45，消除可闻的控制量阶跃。
    //     旧实验所谓“斜坡破坏 tb”只是算术测试未等待 settle；现在该测试用
    //     `NORM_GAIN_STEP=0` 明确选择立即模式，硬件默认仍使用 de-zipper。
    always @(posedge clk_i) begin
        if (!rst_n_i)            n_active_r <= {(LW+1){1'b0}};
        else if (render_start_i) n_active_r <= pc_sum;
    end
    assign n_active_o = n_active_r;
    //   ⚠️ 兼容旧名（⭐ 模块内其它地方可能引用）
    wire [LW:0] n_active = n_active_r;

    // ── ② ⭐ `1/√N` 查表（⭐ Q8.7：**基准 44** = 满增益）──────────────────
    //   📌 **为什么用表而⛔ 不用开方器**：⭐ `N` 只有 0~32 ⇒ ⭐ 33 项常量表
    //      ⇒ ⭐ 综合成 LUT，⛔ 不占 BRAM、⛔ 不要除法器/开方器。
    //   ⚠️ `N=0`（无活跃 voice）⇒ ⭐ 增益无关紧要（⭐ `acc_r` 本来就是 0）
    //      ⇒ ⭐ 取 44（⭐ 避免 X 传播）。
    //
    //   🔴🔴🔴 **2026-09-26 上板实测【第五次】：⭐ 基准【回到 44】**
    //
    //   ⭐⭐ **必须记录的四次失败（⭐ 我反复在同一个坑里打转）**：
    //      ```
    //      轮  基准   我用的"叠加模型"      上板结果
    //      1   128    ——                  失真
    //      2    70    ——                  破音
    //      3    44    ——                  小声 + 噪声
    //      4   104    ⭐ 假设"非相干 √N"    🔴 全失真（⭐ 更糟）
    //      5    44    ⭐ 回到保守值         ⏳ 待验
    //      ```
    //
    //   🔴 **根本教训（⭐ 这才是要点）**：
    //      ⚠️ 我每次都在**猜一个"叠加模型"去【算】gain**
    //         （先假设同相 ⇒ 算 44；再假设非相干 ⇒ 算 104）
    //      ⇒ 🔴 **模型是猜的 ⇒ 算出来的 gain 必然不可信** ⇒ ⭐ **上板就打脸**。
    //      ⭐⭐ **`gain` 是【结果】，⛔ 不是【原因】** ——
    //         ⭐ **真正的原因是"两个 lane 严格同相"**（⭐ `OSC_PER_VOICE=2` 没有失谐）
    //         ⇒ ⭐ **叠加行为不确定 ⇒ gain 没有唯一解**。
    //
    //   ⭐⭐ **正确的顺序（⭐ 本轮已定）**：
    //      ① ⭐ **先做失谐**（⭐ 让两个 lane 不同频率）
    //      ② ⭐ **叠加行为就确定了**（⭐ 拍频 ⇒ 幅度可控）
    //      ③ ⭐ **此时 gain 才有唯一正确答案**
    //      📌 **⇒ 在失谐落地【之前】，基准一律取【保守值 44】**（⭐ ⛔ 不再猜）。
    //
    //   🔴🔴🔴 **2026-09-27 第六次修正：⭐ 基准 44 → 88（⭐ 失谐已生效，模型改了）**
    //
    //   ⭐⭐ **为什么可以提到 88 了（⭐ 关键前提已变）**：
    //      ⭐ **失谐已实装**（⭐ `oscillator_bank.DETUNE_ON`，⭐ 两 lane 440.0/441.7 Hz、
    //         ⭐ 拍频 1.72 Hz）⇒ ⭐ **两个 lane 不再严格相干**。
    //      ⭐ **⇒ 叠加模型从"相干 ×2"变成"非相干 √N"** ⇒ ⭐ **这正是前提变化**。
    //
    //   ⭐⭐ **量化依据（⭐ `build/exp/gain_chain.py`）**：
    //      ```
    //      ⭐ 单 voice 满幅 sh24（>>>1 之后）= 8388096 = **100.0% 满幅**
    //      ⭐ >>>1      = −6.0 dB
    //      ⭐ gain=44   = −9.3 dB
    //      ⭐ 合计       = −15.3 dB ⇒ 🔴 **单音只剩 34%**（⭐ 这就是"单音小"）
    //      ```
    //      ⭐ **非相干模型下 `1/√N` 让峰值【恒定】，⛔ 与 N 无关**：
    //      | ⭐ gain | N=1 | N=2 | N=4 | N=8 | N=16 |
    //      |---|---|---|---|---|---|
    //      | 44 | 34% | 34% | 34% | 35% | 34% |
    //      | **88** | **69%** | **68%** | **69%** | **68%** | **69%** | ✅
    //      ⇒ ⭐ **88 让单音 69% 满幅，且所有 N 恒定、⛔ 不削顶** ✅
    //
    //   ⚠️ **为什么之前 104"全失真"而⛔ 不是 88**：
    //      ⭐ 那次是 **`>>>1` + 104 + ⛔ 无失谐** ⇒ ⭐ 两 lane 严格相干（×2）
    //      ⇒ ⭐ 实际是 `2x` 而非 `1x` ⇒ 🔴 **N=2 就 115%**
    //      📌 **⇒ 那次的问题在"无失谐"，⛔ 不在 104 这个数**。
    //      ⭐ 现在失谐生效 ⇒ ⭐ **88 是安全的**（⭐ 且比 104 更保守）。
    //
    //   ⚠️ **仍留 31% 余量**：⭐ 吸收"偶尔相位对齐"+ 定点舍入 ⇒ ⭐ 由 limiter 兜底。
    function [15:0] gain_sqrt_lut;
        input [LW:0] n;
        begin
            case (n)
                6'd0:  gain_sqrt_lut = 16'd64;    // ⭐ 无 voice（增益无意义，取安全值）
                6'd1:  gain_sqrt_lut = 16'd64;    // 64/√1  = 64.0
                6'd2:  gain_sqrt_lut = 16'd45;    // 64/√2  = 45.3
                6'd3:  gain_sqrt_lut = 16'd37;    // 64/√3  = 37.0
                6'd4:  gain_sqrt_lut = 16'd32;    // 64/√4  = 32.0
                6'd5:  gain_sqrt_lut = 16'd29;    // 64/√5  = 28.6
                6'd6:  gain_sqrt_lut = 16'd26;    // 64/√6  = 26.1
                6'd7:  gain_sqrt_lut = 16'd24;    // 64/√7  = 24.2
                6'd8:  gain_sqrt_lut = 16'd23;    // 64/√8  = 22.6
                6'd9:  gain_sqrt_lut = 16'd21;    // 64/√9  = 21.3
                6'd10: gain_sqrt_lut = 16'd20;    // 64/√10 = 20.2
                6'd11: gain_sqrt_lut = 16'd19;    // 64/√11 = 19.3
                6'd12: gain_sqrt_lut = 16'd18;    // 64/√12 = 18.5
                6'd13: gain_sqrt_lut = 16'd18;    // 64/√13 = 17.8
                6'd14: gain_sqrt_lut = 16'd17;    // 64/√14 = 17.1
                6'd15: gain_sqrt_lut = 16'd17;    // 64/√15 = 16.5
                6'd16: gain_sqrt_lut = 16'd16;    // 64/√16 = 16.0
                6'd17: gain_sqrt_lut = 16'd16;    // 64/√17 = 15.5
                6'd18: gain_sqrt_lut = 16'd15;    // 64/√18 = 15.1
                6'd19: gain_sqrt_lut = 16'd15;    // 64/√19 = 14.7
                6'd20: gain_sqrt_lut = 16'd14;    // 64/√20 = 14.3
                6'd21: gain_sqrt_lut = 16'd14;    // 64/√21 = 14.0
                6'd22: gain_sqrt_lut = 16'd14;    // 64/√22 = 13.6
                6'd23: gain_sqrt_lut = 16'd13;    // 64/√23 = 13.3
                6'd24: gain_sqrt_lut = 16'd13;    // 64/√24 = 13.1
                6'd25: gain_sqrt_lut = 16'd13;    // 64/√25 = 12.8
                6'd26: gain_sqrt_lut = 16'd13;    // 64/√26 = 12.6
                6'd27: gain_sqrt_lut = 16'd12;    // 64/√27 = 12.3
                6'd28: gain_sqrt_lut = 16'd12;    // 64/√28 = 12.1
                6'd29: gain_sqrt_lut = 16'd12;    // 64/√29 = 11.9
                6'd30: gain_sqrt_lut = 16'd12;    // 64/√30 = 11.7
                6'd31: gain_sqrt_lut = 16'd11;    // 64/√31 = 11.5
                default: gain_sqrt_lut = 16'd11;  // 64/√32 = 11.3
            endcase
        end
    endfunction

    //   ⭐ **寄存器级 B**：查表结果锁存（⭐ 切断"查表 → 乘法"这一段）
    //      📌 查表本身是 LUT（⭐ 浅），⚠️ 但因为它**跟在 popcount 后面**，
    //         🔴 不切的话会和乘法器+R 连成一条长路。
    reg [15:0] norm_gain_r;
    wire [15:0] norm_gain_target = gain_sqrt_lut(n_active_r);
    localparam [15:0] NORM_GAIN_STEP_W = NORM_GAIN_STEP;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            // N=0 and N=1 both use 64, so reset cannot create an initial
            // over-gain transient while the pipeline fills.
            norm_gain_r <= 16'd64;
        end else if (NORM_GAIN_STEP == 0) begin
            // Legacy/immediate mode is used by arithmetic unit tests.  Keep
            // updating between frames so n_active_r has time to propagate.
            norm_gain_r <= norm_gain_target;
        end else if (render_start_i) begin
            if (norm_gain_target > norm_gain_r)
                norm_gain_r <= ((norm_gain_target - norm_gain_r) > NORM_GAIN_STEP_W)
                             ? (norm_gain_r + NORM_GAIN_STEP_W) : norm_gain_target;
            else if (norm_gain_target < norm_gain_r)
                norm_gain_r <= ((norm_gain_r - norm_gain_target) > NORM_GAIN_STEP_W)
                             ? (norm_gain_r - NORM_GAIN_STEP_W) : norm_gain_target;
        end
    end
    wire [15:0] norm_gain = norm_gain_r;

    // ── ③ ⭐ 归一化：`sh24 × gain >> 7`（⭐ Q8.7 ⇒ 右移 7 位）────────────
    //   ⚠️ 位宽：`sh24` 是 `ACC_W` 位、`gain` 16 位 ⇒ 结果 `ACC_W+16` 位
    //      ⇒ ⭐ 先算宽结果，⭐ 再右移（⭐ `K-91`：位宽必须显式落定）
    //   🔴🔴 **2026-09-26 修正（⭐ 我第一版写错了，⭐ 而且错得很隐蔽）**：
    //      ⚠️ 原来写 `sh_norm = norm_full[ACC_W+6:7]` —— ⭐ 只取 `ACC_W` 位，
    //      🔴 **把归一化后【超出 24 位】的部分【直接截断】了** ⇒
    //         ⚠️ 限幅器看到的是一个**已经回绕**的值 ⇒ 🔴 **正数变负数**！
    //      ⭐ 实测签名（⭐ tb 报的）：⭐ `max input` 本应饱和到 `+8388607`，
    //         🔴 **实测 `-4198720`**（⭐ 正好是回绕后的值）。
    //      ⇒ ⭐ **修法：⭐ 保留【宽】结果**，⭐ 让限幅器先看到真实的溢出量，
    //         ⭐ 限幅之后再截到 24 位。
    //      📌 **教训**：⭐ **"先截断再限幅"是错的** ——
    //         ⚠️ 截断会丢溢出信息 ⇒ 限幅器失效 ⇒ 🔴 **饱和逻辑形同虚设**。
    //         ⭐ 正确顺序：⭐ **归一化（宽）→ 限幅（宽）→ 截取（窄）**。
    //   ⚠️ `+7` 是 Q8.7 的小数位 ⇒ ⭐ 右移 7 位（`>>>` 保符号）
    //
    //   ⭐ **寄存器级 C**：乘法结果锁存（⭐ 切断"乘法 → 限幅"这一段）
    //      📌 乘法器 + 移位本来就是一个**较长的组合段** ⇒ ⭐ 必须打拍。
    reg signed [ACC_W+15:0] sh_norm_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)
            sh_norm_r <= {(ACC_W+16){1'b0}};
        else
            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r}))
                         >>> (7 + OUTPUT_HEADROOM_SH);
    end
    wire signed [ACC_W+15:0] sh_norm_w = sh_norm_r;

    // ── ④ ⭐ 软限幅（⭐ 阈值 **87.5%** 满幅，⭐ 超出走**二次软膝 + 平台**）────
    //   ⚠️ **在【宽】域做限幅**（⭐ 见上方修正说明）——
    //      ⭐ 这样"超出多少"才看得见，⛔ 不会被截断掩盖。
    //
    //   🔴🔴 **2026-09-26 上板实测【第二次】修正：⭐ 阈值 70% → 95%**
    //
    //   ⭐ **为什么必须提高**：⭐ 阈值 70% 时，⭐ **限幅器在【正常演奏】就全程工作**
    //      ⇒ 🔴 **正弦被 4:1 压缩压扁** ⇒ ⭐ **"破音"**（⭐ 用户实测）。
    //   ⭐ **语义本来就该这样**：⭐ 限幅器是**兜底**（⭐ 防止极端复音溢出），
    //      ⛔ **不是"音量控制"** —— ⚠️ 正常信号**绝不该碰它**。
    //   ⭐ **改法**：⭐ 阈值提到 **95%**（⭐ `8388607 × 0.95 ≈ 7,969,177` = `0x799999`）
    //      ⇒ ⭐ **正常演奏（⭐ 1~2 音）完全在阈值内** ⇒ ✅ **限幅器不介入**
    //      ⇒ ⭐ **只有极端复音叠加时才软压缩**（⭐ 这才是它的用处）。
    //   📌 **配套**：⭐ 基准已从 70 降到 **44**（⭐ 见 `gain_sqrt_lut`）
    //      ⇒ ⭐ **两者合力**：⭐ 44 保证不超满幅 + 95% 保证不误压。
    //
    //  ⭐⭐⭐ **2026-09-28 上板实测【第三次】修正：4:1 硬膝 → C1 连续软膝**
    //
    //  🔴 **现象**（用户实测 + 波形分析）：
    //     · 「尖音是【音色不同的音】」（⭐ 即【谐波失真】—— 只有非线性才产生新谐波）
    //     · 「1s 内【密集触发】尖音，1s 没有，循环往复」
    //     · 波形实测：离群毛刺【100% 出现在高幅度区】，低幅度区【一个都没有】
    //     · 周期精确等于拍频 T = 256/f（C3 1.957s 误差 2.1%；D3 1.744s 误差 0.2%）
    //
    //  🔴 **根因**：⭐ 上方本文件的 `pc_l1`/`pc_sum` 加法树的量化依据假设「两 lane **偶尔**相位对齐」
    //     ⇒ 只留 31% 余量（峰值 69%）。⭐ **但失谐让两 lane【周期性 100% 同相】**
    //     ⇒ 相干叠加 ×2 ⇒ ⭐ 峰值 = 69% × 2 = **138% 满幅**
    //     ⇒ ⭐ 每个拍峰都越过 95% 阈值 ⇒ 限幅器介入
    //     ⇒ 🔴 **4:1 硬膝在阈值处【斜率从 1 突降到 0.25】** = 折点
    //     ⇒ ⭐ **折点产生谐波** ⇒ ⭐⭐ 就是用户听到的「音色不同的音」
    //     ⇒ 每个周期折两次 ⇒ 「密集触发」；拍谷不折 ⇒ 「1s 有 1s 无」✅
    //
    //  ✅ **修法**：把折点消除 —— 换成 **C1 连续软膝**
    //     · `e = |x| − T`（`0 ≤ e ≤ W` 时用软膝）
    //     · `out = T + e − e²/(2W)`（⭐ 分母是 `2W`，⛔ 不是 `2T`）
    //       ⭐ `e=0` 处斜率 = `1 − e/W = 1` ⇒ **与线性段斜率相同** ⇒ ⭐ C1 连续
    //       ⭐ `e=W` 处斜率 = `0` ⇒ ⭐ 平滑封顶（天花板 `T + W/2`）
    //     · `e > W` ⇒ 直接取天花板 `T + W/2`
    //     ⇒ ⭐ **全程 C1 连续 ⇒ ⛔ 不产生新谐波 ⇒ ⛔ 没有「音色不同的音」**
    //
    //  ⚠️⚠️ **【已被取代 · 仅存更正痕迹】** 以下 `50% / 75%` 那组数已被
    //     **09-28 的第四次修正**（⭐ 见下方"以代码为准的现值"条目）取代 ⇒ ⛔ **不要再据此推导**：
    //     · 旧：`T = 2^22`（50% FS）· `2T = 2^23` · "天花板 = `1.5T` = 75% FS" ·
    //       "阈值从 95% 降到 50%" ⇒ 🔴 **这四项都与代码不符**
    //  ✅ **以代码为准的现值**（⭐ 本文件的 `LIM_TH_W` / `KNEE_W`）：
    //     · `LIM_TH_W = 24'sh700000` = `0x700000` ⇒ ⭐ **`T = 7/8 FS = 87.5% FS`**
    //     · 软膝宽度 `W = 2^20`（12.5% FS）⇒ 分母是 ⭐ **`2W = 2^21`**（⛔ **不是 `2T`**）⇒ 纯移位
    //     · 天花板 `T + W/2 = 0x780000` = ⭐ **`15/16 FS = 93.75%`**
    //     ⇒ ⛔ 不需要除法器、⛔ 不占 DSP 之外的资源。
    //  📌 **天花板 `15/16 FS` 仍 < 100%** ⇒ 仍落在 24 位内 ⇒ ⛔ 不会触发后面的硬饱和
    //     （⭐ 硬饱和是**另一种**折点，必须避免它被用到）。
    //  🔴🔴 2026-09-28 上板实测【第四次】修正：阈值 15/16 → 7/8（93.75% → 87.5%）
    //     ⭐ 现象：多音起音瞬态（几个 note_on 叠加 + gain 归一化还延迟 1 帧）
    //       冲到 117%~149% 满幅，而旧阈值 93.75% 的天花板 = 100% ⇒ 压完仍贴满幅
    //       ⇒ 听感"爆"。把 T 降到 7/8 ⇒ 天花板 = T + W/2 = 87.5% + 6.25% = 93.75%
    //       ⇒ 瞬态被压到 93% 附近（C1 连续、无谐波、不爆）。
    //     ⭐ 正常演奏（单音 49.6% / 双键 70% / demo 和弦 67.7%）都 < 87.5% ⇒ 不碰软膝。
    localparam signed [ACC_W+15:0] LIM_TH_W = {{(ACC_W-8){1'b0}}, 24'sh700000};  // T = 7/8 FS
    wire signed [ACC_W+15:0] exc_pos = (sh_norm_w > LIM_TH_W)
                                    ? (sh_norm_w - LIM_TH_W) : {(ACC_W+16){1'b0}};
    wire signed [ACC_W+15:0] exc_neg = (sh_norm_w < -LIM_TH_W)
                                    ? ((-LIM_TH_W) - sh_norm_w) : {(ACC_W+16){1'b0}};
    // Register the expensive square separately from the knee/mux/saturation
    // network.  Without this cut Gowin placed the whole chain in one cycle
    // (26.13 ns in the detune-off diagnostic build, 25 setup violations).
    // Keep the excess and original sample beside the squared terms so every
    // value consumed below belongs to the same audio frame.
    reg signed [ACC_W+15:0] exc_pos_d;
    reg signed [ACC_W+15:0] exc_neg_d;
    reg signed [ACC_W+15:0] sh_norm_d;
    reg signed [ACC_W+15:0] exc_pos_sq_d;
    reg signed [ACC_W+15:0] exc_neg_sq_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            exc_pos_d    <= {(ACC_W+16){1'b0}};
            exc_neg_d    <= {(ACC_W+16){1'b0}};
            sh_norm_d    <= {(ACC_W+16){1'b0}};
            exc_pos_sq_d <= {(ACC_W+16){1'b0}};
            exc_neg_sq_d <= {(ACC_W+16){1'b0}};
        end else begin
            exc_pos_d    <= exc_pos;
            exc_neg_d    <= exc_neg;
            sh_norm_d    <= sh_norm_w;
            exc_pos_sq_d <= (exc_pos * exc_pos) >>> 21;
            exc_neg_sq_d <= (exc_neg * exc_neg) >>> 21;
        end
    end
    //  ⭐ 软膝（C1 连续）：out = T + e − e²/(2W)；`e ≥ W` ⇒ 天花板 T + W/2
    //     ⚠️ `exc * exc` 在 Verilog 里按【全宽】求值（80 位）后再移位 ⇒ 截到 40 位安全
    //  ⭐ 软膝宽度 W = 2^20（12.5% FS）⇒ 2W = 2^21 ⇒ 纯移位
    //  ⭐ 天花板 = T + W/2 = 7/8 + 1/16 = 【15/16 FS = 93.75%】⇒ ⛔ 低于硬饱和点
    localparam signed [ACC_W+15:0] KNEE_W = {{(ACC_W-8){1'b0}}, 24'sh100000};   // W = 2^20
    wire signed [ACC_W+15:0] ceil_w    = LIM_TH_W + (KNEE_W >>> 1);   // T + W/2 = 0x780000 = 15/16 FS
    wire signed [ACC_W+15:0] knee_pos  = (exc_pos_d >= KNEE_W)
                                       ? ceil_w
                                       : (LIM_TH_W + exc_pos_d - exc_pos_sq_d);
    wire signed [ACC_W+15:0] knee_neg  = (exc_neg_d >= KNEE_W)
                                       ? ceil_w
                                       : (LIM_TH_W + exc_neg_d - exc_neg_sq_d);
    wire signed [ACC_W+15:0] lim_pos = (sh_norm_d >  LIM_TH_W) ?  knee_pos : sh_norm_d;
    wire signed [ACC_W+15:0] lim_neg = (sh_norm_d < -LIM_TH_W) ? -knee_neg : sh_norm_d;
    wire signed [ACC_W+15:0] lim_w   = (sh_norm_d > LIM_TH_W) ? lim_pos : lim_neg;

    // ── ⑤ ⭐ 最终饱和（⭐ 复用原有逐位判溢出手法 —— `K-101`）──────────────
    //   ⚠️ 走到这里时 `lim_w` **最多**只到 `LIM_TH + 溢出/4` ⇒ ⭐ 通常已落在 24 位内；
    //      但 ⚠️ **极端的 `N`/输入组合**下仍可能超 ⇒ ⭐ **这一层是兜底**（⛔ 不删）。
    wire [ACC_W+15:0] sh_final_w = lim_w;
    wire over_pos = ~sh_final_w[ACC_W+15] && (|sh_final_w[ACC_W+14 : SAMPLE_W-1]);
    wire over_neg =  sh_final_w[ACC_W+15] && ~(&sh_final_w[ACC_W+14 : SAMPLE_W-1]);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ **2026-09-28 FMAX 修复：`samp_r` 从【组合】改成【真寄存器】**
    //
    //   🔴 **原缺陷（实测 `impl/pnr/Gowin2026.timing_paths`，⛔ 不是推理）**：
    //      `samp_r` 原来写在 `always @(*)` 里 ⇒ ⭐ **它是组合输出** ⇒
    //      `dry_sample_o` 组合穿到顶层 `top.v`，**中间没有任何寄存器**就进了
    //      `master_mix` 的乘法 ⇒ 🔴 **一个 20 ns 周期里串了**：
    //         归一化乘法 → 限幅（软膝）→ 饱和 → **主音量乘法** → `sample_r`
    //      ⇒ 实测 `slack = 【0.002 ns】`（= **2 皮秒**）· **27 级逻辑**
    //      ⇒ ⚠️ 温度/电压稍偏最坏角、或重新布局一次，就可能不满足时序。
    //
    //   ✅ **修法**：把它变成真寄存器 ⇒ ⭐ 切断"限幅/饱和 → 主音量乘法"这一段
    //      · ⭐ **只加这一级** —— ⛔ 不动 `n_active_r` / `norm_gain_r` / `sh_norm_r`
    //      · ⭐ **`valid_d` 必须同步 +1**（见下方）——
    //        ⚠️ 这是流水线改造**最容易漏的一步**：数据多一级而 `valid` 少一级
    //        ⇒ 🔴 下游拿到"上一拍的数据 + 本拍的 valid" ⇒ 相位错位。
    //
    //   ⭐⭐ **为什么改这里，而不是在 `top.v` 再加一个寄存器**：
    //      `samp_r` 本来就**声明成 `reg`**、名字也是 reg、位置就在输出级 ⇒
    //      ⭐ **把它变成真寄存器是它本来就该有的样子**；
    //      在顶层另加一个反而是"绕过验收 tb"的补丁，而且会让本模块
    //      **保持组合输出**（⛔ 不好的实践：模块输出应当寄存）。
    //      📌 两者的**时序收益完全相同** —— 切点都在本模块的输出处。
    //
    //   ⚠️ **代价**：本模块延迟 +1 clk ⇒ 顶层出声链 +1 clk = **20 ns**
    //      （⭐ 一帧 = 1024 clk ⇒ 只占 1/1024 帧 ⇒ 听感不可闻）
    // ═══════════════════════════════════════════════════════════════════════
    reg signed [SAMPLE_W-1:0] samp_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)
            samp_r <= {SAMPLE_W{1'b0}};
        else if (over_pos)
            samp_r <= {1'b0, {(SAMPLE_W-1){1'b1}}};   // +最大（2^(W-1)-1）
        else if (over_neg)
            samp_r <= {1'b1, {(SAMPLE_W-1){1'b0}}};   // −最小（−2^(W-1)）
        else
            samp_r <= lim_w[SAMPLE_W-1:0];            // ⭐ 限幅后【才】截到 24 位
    end

    //   🔴🔴 **2026-09-26：⭐ `dry_valid_o` 必须跟着流水延时（⭐ 否则 valid 与数据错拍）**
    //
    //      ⭐ 我在归一化段插了 **3 级寄存器**（A: popcount / B: 查表 / C: 乘法）：
    //         `n_active_r` → `norm_gain_r` → `sh_norm_r`
    //      ⇒ ⭐ 从 `acc_r` 到 `samp_r` 之间**多了 3 拍** ⇒
    //         🔴 **`valid_r` 也必须延 3 拍**，⭐ 否则会在数据还没出来时就报 valid。
    //
    //      📌 **这是流水线改造的【标准配套动作】—— ⚠️ 最容易漏的一步。**
    //         ⚠️ 漏了的后果：⭐ 下游拿到**上一帧的数据 + 本帧的 valid**
    //         ⇒ 🔴 **一帧相位错位** ⇒ ⚠️ 仿真里可能"看起来还在响"（⭐ 因为每帧都响），
    //            🔴 但**听感是错的**（⭐ 音符起止全部错一帧）。
    //      📌 **纪律**（⭐ `TROUBLESHOOTING.md` 的"脉冲与其携带的数据必须同拍"）：
    //         ⭐ **加了几级数据寄存器，valid 就要跟着延几级**。
    //   ⭐⭐ **2026-09-28 FMAX 修复：深度 3 → 4**（⭐ 因为 `samp_r` 多了一级寄存器）
    //      ⚠️ **纪律**：⭐ **加了几级数据寄存器，`valid` 就要跟着延几级** ——
    //         它和 `samp_r` 是**一对**，改一个必须改另一个。
    //      📌 **配套**：`tb_tdm_render_mixer.sv` 的判据名字 `POLY_TARGET+6` → `+7`
    //         （⭐ 它的**断言是范围** `[POLY+3, POLY+8]` ⇒ ⛔ 判据本身不用改）。
    //   2026-09-29: the registered soft-knee square adds one more data stage.
    reg [4:0] valid_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) valid_d <= 5'b00000;
        else          valid_d <= {valid_d[3:0], valid_r};
    end
    //   ⭐ 延时后的 valid = 数据出 `samp_r` 的那一拍
    assign dry_valid_o      = valid_d[4];
    assign dry_sample_o     = samp_r;
    assign deadline_fault_o = fault_r;

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 为什么要有：这个组合会**静默失效** ——
    //     ① `POLY_TARGET + 2 > RENDER_DEADLINE_CYC` ⇒ **每帧都超时** ⇒
    //        `deadline_fault_o` 恒 1 ⇒ 但 `dry_valid_o` 仍正常 ⇒ 看起来"有声音"，
    //        ⛔ 而 `A6` 判据已经失效；
    //     ② `POLY_TARGET + 2 > CLK_PER_SAMPLE` ⇒ **帧内根本跑不完** ⇒
    //        会被下一次 `render_start_i` 打断 ⇒ 输出**周期性错帧**。
    //   ⇒ 仿真启动时明确打印（综合工具忽略 `initial`，所以只是仿真侧防线）。
    initial begin
        if (CNT_TOTAL > RENDER_DEADLINE_CYC)
            $display("ERROR [tdm_render_mixer] POLY_TARGET+2=%0d > RENDER_DEADLINE_CYC=%0d => 每帧都会超时（A6 失效）",
                     CNT_TOTAL, RENDER_DEADLINE_CYC);
        if (CNT_TOTAL > CLK_PER_SAMPLE)
            $display("ERROR [tdm_render_mixer] POLY_TARGET+2=%0d > CLK_PER_SAMPLE=%0d => 帧内跑不完（会周期性错帧）",
                     CNT_TOTAL, CLK_PER_SAMPLE);
        if ((OUTPUT_HEADROOM_SH < 0) || (OUTPUT_HEADROOM_SH > 3))
            $display("ERROR [tdm_render_mixer] OUTPUT_HEADROOM_SH=%0d outside 0..3",
                     OUTPUT_HEADROOM_SH);
    end

endmodule

`default_nettype wire
