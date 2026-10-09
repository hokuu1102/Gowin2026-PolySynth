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
    wire [31:0] rate_span = RATE_MAX_INC - RATE_MIN_INC;
    wire [43:0] rate_product = {32'd0, rate_raw_i} * {12'd0, rate_span};
    wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
                              ? RATE_MAX_INC
                              : RATE_MIN_INC + rate_product[43:12];
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
    localparam [11:0] DEPTH_MAX_RAW = 12'd120;   // ⭐ ±50 cents @ A4
    wire [11:0] depth_eff = (depth_raw_i > DEPTH_MAX_RAW) ? DEPTH_MAX_RAW : depth_raw_i;
    wire [15:0] depth_target_w = {depth_eff, 3'b000}; // 12-bit -> Q1.15（⭐ 已限幅）

    reg              depth_active_r;
    reg [15:0]       depth_q;
    reg [31:0]       rate_inc_q;
    reg [31:0]       rate_target_q;
    reg [31:0]       phase_q;
    integer          slew_count_q;

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
            rate_target_q  <= RATE_MIN_INC;
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

                rate_target_q <= rate_target_w;

                // The control source commits at 2 kHz.  Move rate only every
                // 10 commits (5 ms nominal), with a bounded step each time.
                if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
                    slew_count_q <= 0;
                    if (rate_inc_q < rate_target_w) begin
                        if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
                            rate_inc_q <= rate_inc_q + RATE_SLEW_STEP;
                        else
                            rate_inc_q <= rate_target_w;
                    end else if (rate_inc_q > rate_target_w) begin
                        if ((rate_inc_q - rate_target_w) > RATE_SLEW_STEP)
                            rate_inc_q <= rate_inc_q - RATE_SLEW_STEP;
                        else
                            rate_inc_q <= rate_target_w;
                    end
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
    end
endmodule

`default_nettype wire
