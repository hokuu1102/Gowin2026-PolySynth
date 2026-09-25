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
// ⭐ 核心设计：**共享一个乘法器**（这是 `K-83`/`FPGA平台与资源评估.md` §3.7 的硬约束）
//   ⚠️ 60K 只有 **118 个 DSP**。若给每个 voice 配一个乘法器 ⇒ 32 个，尚可；
//      但若给每个 **lane** 配（64 个）再加上后续效果器，就会紧张。
//   ⇒ ⭐ 本模块**时分复用同一个乘法器**：一拍算一个 voice，
//      `POLY_TARGET` 拍算完整帧（32 拍），远小于 1024 拍预算。
//
//   每拍（voice `cnt`）：
//     ① `vs = Σ lane_sample`（该 voice 的 OSC_PER_VOICE 个 lane 相加）
//     ② `prod = vs × env_level[cnt]`（Q0.16）—— ⭐ **唯一那个乘法器**
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
    parameter integer RENDER_DEADLINE_CYC = 927
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

    reg signed [SUM_W-1:0] vs_c;
    integer oi;
    always @(*) begin
        vs_c = {SUM_W{1'b0}};
        for (oi = 0; oi < OSC_PER_VOICE; oi = oi + 1)
            vs_c = vs_c + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
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
    //        · `voice.v:101`  `sample_out <= {scaled_16, 8'b0}`  ← ⭐ **×256**
    //        · `i2s_tx`      取 `min(DATA_BITS,SAMPLE_W)` = **高 16 位**
    //        · `voice_i2s_chain.v:84` 把 `voice.sample_out` **直连** `i2s_tx`
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
    //   ⭐ **软限幅（⭐ 阈值 80%，超出 4:1 压缩）**：
    //      ⭐ `|x| <= TH` ⇒ ⭐ 直通（⭐ **日常 1~4 音完全不失真**）
    //      ⭐ `|x| >  TH` ⇒ ⭐ `x = sign(x) × (TH + (|x|-TH)/4)`（⭐ 平滑压缩）
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
    //   级 1：两两配对相加（⭐ 32 → 16 个数，每级路径只有 1 个加法器）
    wire [LW:0] pc_l1 [0:POLY_TARGET/2-1];
    genvar gi;
    generate
        for (gi = 0; gi < POLY_TARGET/2; gi = gi + 1) begin : g_pc1
            assign pc_l1[gi] = {{LW{1'b0}}, voice_active_i[gi*2]}
                            + {{LW{1'b0}}, voice_active_i[gi*2+1]};
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
    always @(posedge clk_i) begin
        if (!rst_n_i) n_active_r <= {(LW+1){1'b0}};
        else          n_active_r <= pc_sum;
    end
    assign n_active_o = n_active_r;
    //   ⚠️ 兼容旧名（⭐ 模块内其它地方可能引用）
    wire [LW:0] n_active = n_active_r;

    // ── ② ⭐ `1/√N` 查表（⭐ Q8.7：128 = 1.0）────────────────────────────
    //   📌 **为什么用表而⛔ 不用开方器**：⭐ `N` 只有 0~32 ⇒ ⭐ 33 项常量表
    //      ⇒ ⭐ 综合成 LUT，⛔ 不占 BRAM、⛔ 不要除法器/开方器。
    //   ⚠️ `N=0`（无活跃 voice）⇒ ⭐ 增益无关紧要（⭐ `acc_r` 本来就是 0）
    //      ⇒ ⭐ 取 128（⭐ 保证 `phase_inc` 式的"永不为 0"纪律，⭐ 避免 X 传播）。
    function [15:0] gain_sqrt_lut;
        input [LW:0] n;
        begin
            case (n)
                6'd0:  gain_sqrt_lut = 16'd70;    // ⭐ 无 voice（增益无意义，取安全值）
                6'd1:  gain_sqrt_lut = 16'd70;    // 70/√1  = 70.0
                6'd2:  gain_sqrt_lut = 16'd49;    // 70/√2  = 49.5
                6'd3:  gain_sqrt_lut = 16'd40;    // 70/√3  = 40.4
                6'd4:  gain_sqrt_lut = 16'd35;    // 70/√4  = 35.0
                6'd5:  gain_sqrt_lut = 16'd31;    // 70/√5  = 31.3
                6'd6:  gain_sqrt_lut = 16'd29;    // 70/√6  = 28.6
                6'd7:  gain_sqrt_lut = 16'd26;    // 70/√7  = 26.5
                6'd8:  gain_sqrt_lut = 16'd25;    // 70/√8  = 24.7
                6'd9:  gain_sqrt_lut = 16'd23;    // 70/√9  = 23.3
                6'd10: gain_sqrt_lut = 16'd22;    // 70/√10 = 22.1
                6'd11: gain_sqrt_lut = 16'd21;    // 70/√11 = 21.1
                6'd12: gain_sqrt_lut = 16'd20;    // 70/√12 = 20.2
                6'd13: gain_sqrt_lut = 16'd19;    // 70/√13 = 19.4
                6'd14: gain_sqrt_lut = 16'd19;    // 70/√14 = 18.7
                6'd15: gain_sqrt_lut = 16'd18;    // 70/√15 = 18.1
                6'd16: gain_sqrt_lut = 16'd18;    // 70/√16 = 17.5
                6'd17: gain_sqrt_lut = 16'd17;    // 70/√17 = 17.0
                6'd18: gain_sqrt_lut = 16'd16;    // 70/√18 = 16.5
                6'd19: gain_sqrt_lut = 16'd16;    // 70/√19 = 16.1
                6'd20: gain_sqrt_lut = 16'd16;    // 70/√20 = 15.7
                6'd21: gain_sqrt_lut = 16'd15;    // 70/√21 = 15.3
                6'd22: gain_sqrt_lut = 16'd15;    // 70/√22 = 14.9
                6'd23: gain_sqrt_lut = 16'd15;    // 70/√23 = 14.6
                6'd24: gain_sqrt_lut = 16'd14;    // 70/√24 = 14.3
                6'd25: gain_sqrt_lut = 16'd14;    // 70/√25 = 14.0
                6'd26: gain_sqrt_lut = 16'd14;    // 70/√26 = 13.7
                6'd27: gain_sqrt_lut = 16'd13;    // 70/√27 = 13.5
                6'd28: gain_sqrt_lut = 16'd13;    // 70/√28 = 13.2
                6'd29: gain_sqrt_lut = 16'd13;    // 70/√29 = 13.0
                6'd30: gain_sqrt_lut = 16'd13;    // 70/√30 = 12.8
                6'd31: gain_sqrt_lut = 16'd13;    // 70/√31 = 12.6
                default: gain_sqrt_lut = 16'd12;// 70/√32 = 12.4
            endcase
        end
    endfunction

    //   ⭐ **寄存器级 B**：查表结果锁存（⭐ 切断"查表 → 乘法"这一段）
    //      📌 查表本身是 LUT（⭐ 浅），⚠️ 但因为它**跟在 popcount 后面**，
    //         🔴 不切的话会和乘法器+R 连成一条长路。
    reg [15:0] norm_gain_r;
    always @(posedge clk_i) begin
        if (!rst_n_i) norm_gain_r <= 16'd128;
        else          norm_gain_r <= gain_sqrt_lut(n_active_r);
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
            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r})) >>> 7;
    end
    wire signed [ACC_W+15:0] sh_norm_w = sh_norm_r;

    // ── ④ ⭐ 软限幅（⭐ 阈值 80% 满幅，⭐ 超出按 4:1 压缩）────────────────
    //   ⚠️ **在【宽】域做限幅**（⭐ 见上方修正说明）——
    //      ⭐ 这样"超出多少"才看得见，⛔ 不会被截断掩盖。
    //   ⭐ 阈值 = 24 位满幅的 80% ⇒ `8388607 × 0.8 ≈ 6710886` = `0x666666`
    localparam signed [ACC_W+15:0] LIM_TH_W = {{(ACC_W-8){1'b0}}, 24'sh599999};
    wire signed [ACC_W+15:0] exc_pos = (sh_norm_w > LIM_TH_W)
                                    ? (sh_norm_w - LIM_TH_W) : {(ACC_W+16){1'b0}};
    wire signed [ACC_W+15:0] exc_neg = (sh_norm_w < -LIM_TH_W)
                                    ? ((-LIM_TH_W) - sh_norm_w) : {(ACC_W+16){1'b0}};
    wire signed [ACC_W+15:0] lim_pos = (sh_norm_w > LIM_TH_W)
                                    ? (LIM_TH_W + (exc_pos >>> 2)) : sh_norm_w;
    wire signed [ACC_W+15:0] lim_neg = (sh_norm_w < -LIM_TH_W)
                                    ? ((-LIM_TH_W) - (exc_neg >>> 2)) : sh_norm_w;
    wire signed [ACC_W+15:0] lim_w   = (sh_norm_w > LIM_TH_W) ? lim_pos : lim_neg;

    // ── ⑤ ⭐ 最终饱和（⭐ 复用原有逐位判溢出手法 —— `K-101`）──────────────
    //   ⚠️ 走到这里时 `lim_w` **最多**只到 `LIM_TH + 溢出/4` ⇒ ⭐ 通常已落在 24 位内；
    //      但 ⚠️ **极端的 `N`/输入组合**下仍可能超 ⇒ ⭐ **这一层是兜底**（⛔ 不删）。
    wire [ACC_W+15:0] sh_final_w = lim_w;
    wire over_pos = ~sh_final_w[ACC_W+15] && (|sh_final_w[ACC_W+14 : SAMPLE_W-1]);
    wire over_neg =  sh_final_w[ACC_W+15] && ~(&sh_final_w[ACC_W+14 : SAMPLE_W-1]);

    reg signed [SAMPLE_W-1:0] samp_r;
    always @(*) begin
        if (over_pos)
            samp_r = {1'b0, {(SAMPLE_W-1){1'b1}}};   // +最大（2^(W-1)-1）
        else if (over_neg)
            samp_r = {1'b1, {(SAMPLE_W-1){1'b0}}};   // −最小（−2^(W-1)）
        else
            samp_r = lim_w[SAMPLE_W-1:0];            // ⭐ 限幅后【才】截到 24 位
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
    reg [2:0] valid_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) valid_d <= 3'b000;
        else          valid_d <= {valid_d[1:0], valid_r};
    end
    //   ⭐ 延时后的 valid = 数据出 `samp_r` 的那一拍
    assign dry_valid_o      = valid_d[2];
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
    end

endmodule

`default_nettype wire
