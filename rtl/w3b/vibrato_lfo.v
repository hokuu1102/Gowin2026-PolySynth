`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// vibrato_lfo.v · T18 颤音控制（W3b）
//
// CH2（深度）和 CH3（速率）是低速控制量；它们绝不能直接改变振荡器相位。
// 本模块只连续改变 phase increment，故 LFO 相位在所有控制变化中保持连续，
// 不会产生由相位复位导致的音高跳变/咔声。
//
// 深度：双阈值死区（OFF <= DEPTH_OFF；ON >= DEPTH_ON）。控制值在两个阈值
// 之间来回抖动时保持原状态，防止颤音在端点断续。
// 速率：raw 0..4095 映射到 1..12 Hz，且每 CTRL_SLEW_DIV 次控制提交最多
// 改 RATE_SLEW_STEP 个 phase-inc LSB；50 MHz 默认约每 5 ms 一步。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module vibrato_lfo #(
    parameter [11:0] DEPTH_OFF     = 12'd64,
    parameter [11:0] DEPTH_ON      = 12'd96,
    // 1 Hz / 12 Hz at 50 MHz: round(Hz * 2^32 / 50e6)
    parameter [31:0] RATE_MIN_INC  = 32'd86,
    parameter [31:0] RATE_MAX_INC  = 32'd1031,
    parameter [31:0] RATE_SLEW_STEP = 32'd16,
    parameter integer CTRL_SLEW_DIV = 10
) (
    input  wire               clk_i,
    input  wire               rst_n_i,
    // one pulse after a coherent CH2/CH3 control snapshot
    input  wire               ctrl_valid_i,
    input  wire [11:0]        depth_raw_i,
    input  wire [11:0]        rate_raw_i,
    output wire signed [15:0] mod_o,             // Q1.15, for oscillator_bank
    output wire               depth_active_o,
    output wire [31:0]        rate_inc_dbg_o,
    output wire [31:0]        phase_dbg_o
);

    // Explicitly widen before multiplication: 12 bits x 32 bits needs 44 bits.
    //  ⭐⭐ 2026-10-09（`P0-30`）：⭐ **把 44 位乘法云收窄到真实的 22 位** ✅
    //   🔴 **原写法**：`wire [43:0] rate_product = {32'd0, rate_raw_i} * {12'd0, rate_span};`
    //      ⚠️ 而 `rate_raw_i` **只有 12 个有效位**、`rate_span = 945` 只有 **10 位** ✅
    //      ⇒ ⭐ 真实积上限 = `4095 × 945 = 3 869 775` = **22 位**（2^22 = 4 194 304）✅
    //      ⇒ 🔴 声明的 44 位里有 **22 位是纯零填充** ✅
    //      ⚠️ 而 945 = `0b11_1011_0001` ⇒ **6 个非零部分积**
    //      ⇒ ⭐ 每一级加法树的位宽都被撑到 44 位 ✅
    //   ✅ **修法**：⭐ 收窄到 22 位 —— ⭐ **与现写法逐位等价**：
    //      ⭐ 44 位积 = 22 位积的**零扩展** ⇒ ⭐ `rate_product[43:12]` ≡ `rate_product[21:12]`（零扩展）✅
    //   📌 **预期**：⭐ 6 级加法树位宽 44 → 22 ⇒ ⭐ 每级进位链减半
    //      ⇒ ⭐ 估算 **省 66 ALU**（`6 × 44/2 = 132` → `6 × 22/2 = 66`）✅
    //   ⚠️ **诚实边界**：⭐ Gowin 的常量乘法优化**有可能**本来就已经把它收窄了
    //      ⇒ ⭐ **必须用综合报告确认**（⭐ 若 ALU 不变 ⇒ 工具早已收窄，⭐ 收益为零也要如实记）✅
    localparam [21:0] RATE_SPAN22 = RATE_MAX_INC - RATE_MIN_INC;   // ⭐ 真值 945
    wire [31:0] rate_span = RATE_MAX_INC - RATE_MIN_INC;
    wire [21:0] rate_product = rate_raw_i * RATE_SPAN22;   // ⭐ 12×10 ⇒ 22 位，够 ✅
    wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
                              ? RATE_MAX_INC
                              : RATE_MIN_INC + rate_product[21:12];
    //  ⭐⭐ 2026-10-09（`P0-19`）：⭐ **颤音深度上限（⭐ 止血版）** ✅
    //   🔴 **缺陷**：⭐ 档 1（上电默认）把 `ch2_i` **原样透传**到 `vibrato_depth_o`
    //      ⇒ ⭐ 推子行程 = `depth_raw_i` **0..4095 全量程可达** ✅
    //      ⇒ ⭐ 本 LFO 的输出是**绝对偏移**（⛔ 不是按基频比例）：
    //         `vib_off_peak = 9448.2 × depth_raw_i`（⭐ 单位 = 相位增量/拍）
    //         ⚠️ 而 A4 的 `bv` = **38 702 840** ⇒ ⭐ **满深度时摆幅 = ±100% 频率** ✅
    //      ⇒ 🔴 `inc_main = bv + vib_off`（mod 2³²）在 `vib_off < −bv` 时**翻负**
    //         ⇒ ⭐ 相位累加器**倒着走** ⇒ 🔴 **明确的错音**（⛔ 不是噪声）✅
    //   📌 **翻负门限（⭐ 实测换算）**：⭐ 低 B(5弦) 30.87 Hz ⇒ `depth_raw ≥ 287`（**7.0%** 行程）
    //      · E1 41.20 Hz ⇒ **384**（9.4%）· E2 82.41 Hz ⇒ **767**（18.7%）· A2 110 Hz ⇒ **1024**（25%）✅
    //      · ⭐ 例：E1 + `depth_raw=4095` ⇒ `inc = 3 624 000 − 38 689 000 = −35 065 000`
    //        ⇒ ⭐ 等效 **398.7 Hz 倒放** ⇒ ⭐ 41.2 Hz 的音**跳 +3.27 个八度** ✅
    //   ✅ **修法（A）**：⭐ 深度上限 **±50 cents @ A4**（⭐ 50 cents = 2^(50/1200)−1 = 2.93%）
    //      ⇒ `vib_off ≤ 0.0293 × 38.7M = 1.134M` ⇒ `depth_q ≤ 960` ⇒ ⭐ **`depth_raw ≤ 120`** ✅
    //   📌 **上限足够**：⭐ 最低可听音 20 Hz 的 `bv` = 1 759 220 > 1 134 000 ⇒ ⭐ **永不翻负** ✅
    //   📌 **代价**：⭐ 1 个 12 位比较 + 1 个 12 位 2:1 mux ≈ **+16 LUT**，⛔ 零 FF、对 Fmax 可忽略 ✅
    //   ⚠️ **结构修法（B，⭐ 未做）**：⭐ 把"绝对偏移"改成"按基频比例"（⭐ 共享乘法器 + 32 拍轮转）
    //      ⇒ ⭐ 代价 1 个 DSP + 1024 FF + 32 拍状态机 ⇒ ⚠️ 给 CLS 78% 的布线加压 ⇒ ⭐ 记入 P1 ✅
    localparam [11:0] DEPTH_MAX_RAW = 12'd120;   // ⭐ ±50 cents @ A4（⭐ **设计目标**）
    //  ⚠️⚠️ **下面那组移位分解【必须】等于 `DEPTH_MAX_RAW`**（⭐ 120 = 64+32+16+8 ✅）
    //     🔴 **静默陷阱**：⭐ 若只改 `DEPTH_MAX_RAW` 而⛔ 不改移位
    //        ⇒ ⭐ 实际上限**不会跟着变**，⭐ 而且**没有任何判据会发现** ✅
    //     ✅ 所以这里放一个**编译期守卫**（⭐ 与其它模块的 `PARAM_OK` 同一套路 ✅）
    //     📌 若真要改上限：⭐ 先把新值分解成 2 的幂之和（⛔ 别引入乘法器），
    //        ⭐ 再改下面的移位，⭐ 最后改本守卫 ✅
    localparam [11:0] DEPTH_SHIFT_EQ = 12'd64 + 12'd32 + 12'd16 + 12'd8;   // ⭐ = 120
    //  ⭐⭐ 2026-10-13：⭐ **把"限幅"改成"全行程线性映射"**（⭐ 修上板实测的"推子没感觉" ✅）
    //
    //  🔴 **上板症状**（⭐ 用户原话）：
    //     *"颤音的第二个推子没什么用啊，只要不是在最底下，感觉都没什么太大的差别"* ✅
    //
    //  🔴 **根因**：⭐ `P0-19`（2026-10-09）的**止血版**用的是**限幅**：
    //        `depth_eff = (depth_raw_i > 120) ? 120 : depth_raw_i`
    //     ⇒ ⭐ 推子**只有最底下 2.9%（120/4095）有效** ✅
    //        ⭐ **2.9% ~ 100% 全部恒定 = 满深度** ⇒ 🔴 **推子等于一个开关** ✅
    //     📌 它修好了"低音翻负错音"（⭐ 那是对的 ✅），⚠️ 但代价是**浪费 97% 的行程** ✅
    //
    //  ✅ **本修法**：⭐ 把 `0..4095` **线性映射**到 `0..120` ⇒ ⭐ **全行程可用** ✅
    //     `depth_eff = depth_raw_i × 120 / 4096`（⭐ `120 = 64+32+16+8` ⇒ ⛔ **不用乘法器** ✅）
    //     📌 **三条保证全部保持**：
    //        · ⭐ 最大深度**仍是 120**（⭐ = ±50 cents @ A4 ✅）⇒ **永不翻负** ✅
    //        · ⭐ **滞回比较的仍是【原始推子值】**（⭐ 见下方 `depth_raw_i <= DEPTH_OFF` ✅）
    //          ⇒ ⭐ 死区/门限语义**逐位不变** ✅
    //        · ⭐ `depth_raw_i = 4095` 时 `depth_eff = 119`（⭐ ≤ 120 ✅）⇒ 上限判据仍绿 ✅
    //     📌 代价：⭐ 3 个 ~19 位加法器 ≈ **+60 LUT**（⭐ 无 FF、无 DSP ✅）
    wire [18:0] depth_mul = (depth_raw_i << 6) + (depth_raw_i << 5)
                          + (depth_raw_i << 4) + (depth_raw_i << 3);   // ⭐ ×120
    //  ⚠️ **切片必须是 `[18:12]`（= `>>12`）** ✅
    //     🔴 **我第一版写成 `[18:7]`（= `>>7`）⇒ 深度大了 32 倍** ✅
    //        ⇒ ⭐ 实测 `depth_raw=4095` 时峰值 **30712**（⭐ 上限 960 ✅）
    //        ⇒ 🔴 正是判据把它抓住的（⭐ `P0-19 depth clamp` 红 ✅）
    wire [11:0] depth_eff = depth_mul[18:12];   // ⭐ >>12（⭐ 4096），⭐ 结果 ≤ 119 ✅
    wire [15:0] depth_target_w = {depth_eff, 3'b000}; // 12-bit -> Q1.15（⭐ 已在限内）

    reg              depth_active_r;
    reg [15:0]       depth_q;
    reg [31:0]       rate_inc_q;
    //  ⭐⭐ 2026-10-09（`P0-30`）：⭐ **删掉死寄存器 `rate_target_q`**（⭐ 省 32 FF）✅
    //   🔴 它**一个负载都没有**（⭐ 三处引用全是写、无读）⇒ ⭐ 纯浪费 32 FF ✅
    //   📌 作者原意应是"把 `rate_target_w` 打一拍再用于 slew"
    //      ⇒ ⭐ 那一拍正好能把乘法云从 `rate_inc_q` 的反馈环里切出去（⭐ 即审查的"改法二"）
    //      ⚠️ 但那是**行为变更**（⭐ 会打红 tb 的 78/79/80 三条精确值断言）
    //      ⇒ ⭐ **留作独立决策**，⛔ 本次只做零风险的"改法一 + 删死寄存器" ✅
    reg [31:0]       phase_q;
    integer          slew_count_q;

    // Compare against widened thresholds instead of subtracting first and
    // then comparing a second time. The 33rd bit preserves UINT32 edges.
    wire [32:0] rate_plus_step_w = {1'b0, rate_inc_q} + {1'b0, RATE_SLEW_STEP};
    wire [32:0] target_plus_step_w = {1'b0, rate_target_w} + {1'b0, RATE_SLEW_STEP};
    wire rate_slew_up_w = {1'b0, rate_target_w} > rate_plus_step_w;
    wire rate_slew_down_w = {1'b0, rate_inc_q} > target_plus_step_w;


    // Triangle LFO: 0 -> +1 -> 0 -> -1 -> 0 over one 32-bit phase turn.
    wire [14:0] tri_mag = phase_q[30] ? ~phase_q[29:15] : phase_q[29:15];
    //  ⭐⭐ 2026-10-09（`P0-17`）：⭐ **补码取负改用 `(~x) + 16'd1`（一条进位链）** ✅
    //   🔴 **原写法**：⭐ 手写 16 级 ripple-carry 函数（`carry = (~value[bit_i]) & carry;`）——
    //      ⚠️ 那是一条**纯 2 输入 AND 串联链**，`carry` 只能逐级传播 ⇒ **16 级 LUT 级联** ✅
    //   📌 **关键**：⭐ 这**不是加法器** —— ⭐ Gowin 的专用进位链（ALU 资源，每单元 2 bit）
    //      **只在综合器识别出 `+` / `-` 运算符时**才被推断
    //      ⚠️ 手写 `&` 链 ⇒ ⭐ 综合器**没有义务**把它映射成进位链 ⇒ 🔴 大概率是 16 级普通 LUT ✅
    //   🔴 **它曾经就是全设计最差路径的上游**（⭐ 2026-10-08 实测）：
    //      `u_vibrato_lfo/phase_q_17_s0/Q → u_oscillator_bank/gen_lane[*].phase_q_*_s0/D`
    //      = **21.4 ns**（约束 18.181）· slack **−3.272** · **1630 个端点同时违例** · TNS −2718.329 ✅
    //      那一次在 `oscillator_bank` 侧插了两级流水（⭐ 把终点拉回 `vibrato_mod_r`），
    //      ⚠️ **但本链的 16 级一级没减** —— ⭐ 现在只是**被布局掩盖**（`timing_paths` 里 `vibrato_lfo` 出现 0 次）✅
    //   ✅ **修法**：⭐ `(~tri_pos) + 16'd1` **就是 16 位补码取负**，⭐ 与旧函数**逐位等价** ✅
    //      📌 **宽度安全**：⭐ 两个操作数都是 16 位（`tri_pos` 与 `16'd1`）
    //         ⇒ ⭐ 结果宽度 = `max(16,16)` = **16** ⇒ ⛔ **不会触发作者担心的"Gowin 加宽一位"** ✅
    //      📌 **代价**：⭐ `(~tri_pos)` = 16 个 LUT（**并行**、不在关键路径上）；
    //         ⭐ `+ 16'd1` = **一条 16 位进位链 = 8 个 ALU**（每 ALU 2 bit）≈ **0.3~0.5 ns**
    //         ⇒ ⭐ 对比 16 级 LUT 的 **8~11 ns** ⇒ ⭐ **省 8~10 ns** ✅
    //      📌 资源：`LUT −16` · `ALU +8` · ⛔ **零 FF、零行为变更** ✅
    wire [15:0] tri_pos = {1'b0, tri_mag};          // 16 位，MSB 恒 0
    wire [15:0] tri_neg = (~tri_pos) + 16'd1;       // ⭐ 16 位进位链取负（⛔ 不是 16 级 LUT）
    wire [15:0] triangle_bits = phase_q[31] ? tri_neg : tri_pos;
    wire signed [15:0] triangle_q = triangle_bits;
    wire signed [31:0] mod_product = triangle_q * $signed(depth_q);
    // Q1.15 product -> Q1.15.  The explicit slice is the low 16 bits of the
    // arithmetic result and avoids Gowin's implicit 17-bit shift truncation.
    wire [15:0] mod_bits = mod_product[30:15];
    wire signed [15:0] mod_w = mod_bits;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            depth_active_r <= 1'b0;
            depth_q        <= 16'd0;
            rate_inc_q     <= RATE_MIN_INC;
            //  ⭐ P0-30：死寄存器已删（原 `rate_target_q <= RATE_MIN_INC;`）✅
            phase_q        <= 32'd0;
            slew_count_q   <= 0;
        end else begin
            // Never reset phase for a control update: this is the anti-click rule.
            phase_q <= phase_q + rate_inc_q;

            if (ctrl_valid_i) begin
                // Depth dead-zone + hysteresis.
                if (depth_active_r) begin
                    if (depth_raw_i <= DEPTH_OFF) begin
                        depth_active_r <= 1'b0;
                        depth_q        <= 16'd0;
                    end else begin
                        depth_q <= depth_target_w;
                    end
                end else if (depth_raw_i >= DEPTH_ON) begin
                    depth_active_r <= 1'b1;
                    depth_q        <= depth_target_w;
                end

                //  ⭐ P0-30：死寄存器已删（原 `rate_target_q <= rate_target_w;`）✅
                //   ⚠️ 注意：⭐ `rate_target_w` **仍在用**（⭐ 见下面的 slew 判据）
                //      ⇒ ⭐ 删掉的只是那个"没人读的寄存器" ✅

                // The control source commits at 2 kHz.  Move rate only every
                // 10 commits (5 ms nominal), with a bounded step each time.
                if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
                    slew_count_q <= 0;
                    if (rate_slew_up_w)
                        rate_inc_q <= rate_plus_step_w[31:0];
                    else if (rate_slew_down_w)
                        rate_inc_q <= rate_inc_q - RATE_SLEW_STEP;
                    else if (!(rate_slew_up_w | rate_slew_down_w))
                        // Known in-range/equal values snap to target. An
                        // unknown target still holds exactly as before.
                        rate_inc_q <= rate_target_w;
                end else begin
                    slew_count_q <= slew_count_q + 1;
                end
            end
        end
    end

    assign mod_o            = depth_active_r ? mod_w : 16'sd0;
    assign depth_active_o   = depth_active_r;
    assign rate_inc_dbg_o   = rate_inc_q;
    assign phase_dbg_o      = phase_q;

    initial begin
        if (DEPTH_ON <= DEPTH_OFF)
            $display("ERROR [vibrato_lfo] DEPTH_ON must be greater than DEPTH_OFF");
        if (RATE_MAX_INC < RATE_MIN_INC)
            $display("ERROR [vibrato_lfo] RATE_MAX_INC must be >= RATE_MIN_INC");
        if (CTRL_SLEW_DIV < 1)
            $display("ERROR [vibrato_lfo] CTRL_SLEW_DIV must be >= 1");
        //  ⭐⭐ 2026-10-13：⭐ **移位分解与设计上限必须一致**（⭐ 防"改了上限却忘了改移位" ✅）
        //     🔴 这是**静默失效**：⭐ 不一致时上限不会变，⭐ 而且判据也不会红 ✅
        if (DEPTH_SHIFT_EQ != DEPTH_MAX_RAW)
            $display("ERROR [vibrato_lfo] DEPTH_MAX_RAW=%0d but the shift decomposition sums to %0d => the real depth ceiling would silently differ from the design target. PARAM_OK=0.",
                     DEPTH_MAX_RAW, DEPTH_SHIFT_EQ);
        else
            $display("NOTE [vibrato_lfo] PARAM_OK=1 (DEPTH_OFF=%0d DEPTH_ON=%0d DEPTH_MAX_RAW=%0d, shift decomposition matches)",
                     DEPTH_OFF, DEPTH_ON, DEPTH_MAX_RAW);
    end
endmodule

`default_nettype wire
