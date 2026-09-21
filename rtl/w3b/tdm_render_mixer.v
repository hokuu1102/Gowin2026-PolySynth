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
    output wire                                             dry_valid_o,
    output wire signed [SAMPLE_W-1:0]                       dry_sample_o,
    output wire                                             deadline_fault_o
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
    wire over_pos = ~sh[ACC_W-1] && (|sh[ACC_W-2 : SAMPLE_W-1]);
    wire over_neg =  sh[ACC_W-1] && ~(&sh[ACC_W-2 : SAMPLE_W-1]);

    reg signed [SAMPLE_W-1:0] samp_r;
    always @(*) begin
        if (over_pos)
            samp_r = {1'b0, {(SAMPLE_W-1){1'b1}}};   // +最大（2^(W-1)-1）
        else if (over_neg)
            samp_r = {1'b1, {(SAMPLE_W-1){1'b0}}};   // −最小（−2^(W-1)）
        else
            samp_r = sh[SAMPLE_W-1:0];
    end

    assign dry_valid_o      = valid_r;
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
