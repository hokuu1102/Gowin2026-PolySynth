`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// fx_delay.v · FPGA 内置【数字延时（echo）/ 合唱（chorus）】效果器 —— W3c 出声通路
//
// ⭐ 位置：`tdm_render_mixer`（干声 `dry_sample_o`）→ **`fx_delay`** → `master_mix` → `i2s_tx`
//    ⭐ 即插在【混音器】与【数字主音量】之间 ⇒ 主音量推子/静音斜坡**作用于湿声**
//       （⭐ 与真机一致：音量关到底时回声也一起消失，⛔ 不会"静音了还有回声在响"）
//
// ── 为什么必须有这个模块（⭐ 竞赛硬性要求）────────────────────────────────
//   ⭐ 竞赛明确要求「**在 FPGA 内部实现**的数字音频效果（reverb / delay / chorus）」。
//   🔴 用软核 / MCU 跑算法是**红线** ⇒ ⭐ 本模块**纯 HDL**、⭐ 专用流水线、
//      ⛔ 无 CPU、⛔ 无固件、⛔ 无外部 DSP 芯片。
//   📌 本模块是**第一个**落地的效果器（delay），⭐ 合唱复用**同一条**延迟线
//      （⚠️ 只多一个 LFO + 插值 ⇒ ⛔ 不额外吃一块 BSRAM）。
//
// ── 算法（⭐ 逐样点，⛔ 不做块处理）────────────────────────────────────────
//   ⭐ 延迟线：单时钟 BSRAM（写口 + 寄存读口），环形寻址
//     · 写：`mem[wr] <= x[n] + fb × wet`     （⭐ 反馈 = 回声能"重复"的原因）
//     · 读：`wet = mem[(wr − D) mod DEPTH]`  （⭐ D = 延迟样点数）
//     · 出：`y = x + (wet×mix) >>> MIX_W`（⭐⭐ send/return：干声恒 1.0，
//            `mix` **只调湿声** ⇒ 推 mix 不会让干声掉下去，⛔ 不再"响两下"）
//   ⭐ 合唱：读地址 = `wr − D − mod(LFO)`，⭐ 用**线性插值**取小数延迟
//     （⛔ 不插值就会有"台阶噪声" —— 地址每跳 1 个样点都"咔"一下）
//
// ── ⭐⭐ 存储预算（BSRAM）—— 本模块唯一"贵"的地方 ──────────────────────────
//   ⭐ 本设计：`AW=14` ⇒ 深度 **16384 样点**；`MEM_W=18` ⇒ 每样点存 18 bit。
//     · 时间：16384 ÷ 48828.125 Hz = **335.5 ms**（⭐ ≤ 350 ms，够用且不爆存储）
//     · 块数：16384 × 18 = **294912 bit**；Gowin 每块 BSRAM = **18 Kbit = 18432 bit**
//             ⇒ 294912 ÷ 18432 = **16.0 块**（⭐ 正好 16 块，⛔ 无浪费）
//   ⚠️ 对比：1 秒延迟 = 48829 样点 × 18 bit = 878922 bit ⇒ **48 块**（118 块的 41%）
//      ⇒ ⭐ **不划算** —— 335 ms 已覆盖 slapback / 常规 echo 的全部用法。
//   📌 24 bit 全存则 16384×24 = 393216 bit ⇒ **22 块**（多 6 块只换回 6 个低位）
//      ⇒ ⚠️ 18 bit 的量化底噪 ≈ −108 dBFS，⭐ 远低于 DAC 本身 ⇒ **不值得**。
//   📌 上面的数字在 `initial` 里**由参数自动算出来并打印**（⛔ 不靠人手抄）。
//
// ── ⭐ 流水线（5 级，⛔ 单样本链不反压）─────────────────────────────────────
//   | 拍 | 动作 |
//   |---|---|
//   | N   | `valid_i`：捕获干声/参数，算 tap0 地址送存储器 |
//   | N+1 | 取回 **tap0**；把 **tap1 = tap0+1** 的地址送存储器 |
//   | N+2 | 取回 **tap1** |
//   | N+3 | ⭐ **插值到此为止**（`d_tap → ×frac → >>8 → +tap0_f → 饱和`）⇒ 锁进 `wet_r` |
//   | N+4 | ⭐ **混音 / 反馈两个乘法 + 三处饱和 + 写存储器（`mem[wr_s3]`）+ 写指针 +1**；`valid_o = 1` |
//   ⚠️ ⇒ ⭐ `valid_i` 必须是**脉冲**且**间距 ≥ 4 clk**（⭐ 真实链路每 1024 clk 一个样点）
//      ⭐ 这是本模块**假设的下界**（⛔ 不是"随手取的保守值"）：`S = 4` 时 `stage0`
//         （`wr_s0 <= wr_ptr`）与上一样本的 `stage4`（`wr_ptr <= wr_ptr + 1`）**同沿**
//         ⇒ 非阻塞赋值下 `wr_s0` 拿到**自增前**的旧指针 ⇒ 相邻样点会共用槽位。
//      📌 真实链路 S = 1024 ⇒ 余量 256 倍，⛔ 不会被踩到；
//         ⭐ 要改小这个数，必须先补一条"间距边界"判据（⛔ 本轮没做）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：用 SV 专有构造 ⇒ 整模块被静默丢弃而仿真全绿）
//   · ⭐ **组合逻辑用 `assign`**（`L67`）；⭐ **参与算术的 wire 一律显式写位宽**
//   · ⭐ **饱和 ⛔ 不用 `signed` 比较**（`K-101`：iverilog 会退化成无符号比较）
//   · ⭐ **声明必须先于使用**（⚠️ 本项目踩过 "Unable to bind wire/reg"）
//   · ⭐ **任何"会失效"的路径都必须可观测**（`K-106`）：
//     饱和次数 / 延迟参数被夹次数 / 延迟线是否已填满 / 写指针 ⇒ **全部有输出**
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module fx_delay #(
    // 样点位宽（与 `tdm_render_mixer` / `master_mix` / `i2s_tx` 一致）
    parameter integer SAMPLE_W = 24,
    // ⭐ 延迟线**每样点存多少位**（⭐ 存储预算的分子，见文件头算术）
    parameter integer MEM_W    = 18,
    // ⭐ 延迟线**地址位宽** ⇒ 深度 = 2^AW 个样点（AW=14 ⇒ 16384 样点 ⇒ 335.5 ms）
    parameter integer AW       = 14,
    // 干湿比位宽（Q0.MIX_W；send/return 下 `mix_i = 2^MIX_W` 才是"全湿"，
    //   ⚠️ 8 位最大只能到 255/256 ⇒ ⭐ 实际最湿 = 干声 + 湿声×0.996，⛔ 到不了全湿）
    parameter integer MIX_W    = 8,
    // 反馈量位宽（Q0.FB_W；`fb_i` 最大 255/256 ≈ 0.996 ⇒ ⭐ 仍 < 1，⛔ 不自激）
    parameter integer FB_W     = 8,
    // 合唱 LFO 步长（每样点加多少；16 位三角波 ⇒ 周期 = 2×65536/INC 个样点）
    //   ⭐ 默认 2 ⇒ 周期 65536 样点 = **1.34 s**（⭐ 典型 chorus 速率）
    parameter integer LFO_INC  = 2,
    // 合唱调制深度（±多少个样点；⭐ 默认 128 样点 ≈ ±2.62 ms，典型 chorus 深度）
    parameter integer CHORUS_MOD_SAMPLES = 128
) (
    input  wire                        clk_i,
    input  wire                        rst_n_i,     // ⭐ 同步复位、低有效（约定 2）

    // ── 单样本流（⭐ 与 `master_mix` 同一约定：`valid_i` 是脉冲，⛔ 不反压）──
    input  wire                        valid_i,
    input  wire signed [SAMPLE_W-1:0]  sample_i,

    // ── 控制（⭐ 全部来自 `top.v` 的寄存器；⛔ 本模块不解析串口）──────────
    input  wire                        en_i,        // ⭐ 0 = 硬旁路（输出 == 输入）
    input  wire [1:0]                  sel_i,       // ⭐ 0 = delay · 1 = chorus · 其余按 delay
    input  wire [AW-1:0]               delay_i,     // ⭐ 延迟样点数（⭐ **按模式**被夹：
                                                    //    ⭐ 延迟 = `[DLY_MIN, DEPTH-1]` = `[2, DEPTH-1]`
                                                    //    ⭐ 合唱 = `[DLY_MIN_CH, DEPTH-1]` = `[MOD+1, DEPTH-1]`）
    input  wire [MIX_W-1:0]            mix_i,       // ⭐ 干湿比（send/return：只作用于【湿声】）
                                                    //   0 = 无湿声 ⇒ 逐位等于输入；
                                                    //   255 = 干声 + 湿声×0.996，**不再等于全湿**
    input  wire [FB_W-1:0]             fb_i,        // ⭐ 反馈量（Q0.FB_W）

    // ── 输出 ──────────────────────────────────────────────────────────────
    output reg                         valid_o,
    output reg  signed [SAMPLE_W-1:0]  sample_o,
    // ── ⭐⭐ 可观测性（`K-106`：⛔ 不许静默失效）──────────────────────────
    output wire [AW-1:0]               wr_ptr_o,    // ⭐ 写指针（⭐ 不动 = 延迟线死了）
    output wire                        primed_o,    // ⭐ 延迟线已写满一圈（⛔ 未满时湿声=0）
    output reg  [15:0]                 sat_cnt_o,   // ⭐ 写/混音**饱和**次数（饱和）
    output reg  [15:0]                 clamp_cnt_o  // ⭐ 延迟参数被夹次数（饱和）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ① 常量
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer DEPTH = (1 << AW);                 // ⭐ 延迟线深度（样点）
    localparam integer SH    = SAMPLE_W - MEM_W;          // ⭐ 存的时候右移多少位
    localparam integer SUM_W = SAMPLE_W + MIX_W + 2;      // ⭐ 中间累加位宽（留 2 位余量）
    localparam integer TAP_W = AW + 10;                   // ⭐ 读地址（Q8）位宽：符号+整数+小数+1 余量

    localparam [MIX_W:0] ONE_Q   = (1 << MIX_W);          // ⭐ 1.0 的 Q0.MIX_W 表示
    localparam [AW-1:0]  DLY_MIN = 2;                     // ⭐ 最小延迟（⭐ 理由见 ⑤）
    localparam [15:0]    LFO_INC_C    = LFO_INC;          // ⭐ 赋值给定宽（⛔ 不对 integer 位选）
    localparam [7:0]     CHORUS_MOD_N = CHORUS_MOD_SAMPLES;

    // ⭐⭐ 存储预算（⭐ 自动算，⛔ 不手抄 —— 参数一改数字跟着变）
    localparam integer BSRAM_BITS = DEPTH * MEM_W;
    localparam integer BSRAM_BLK  = (BSRAM_BITS + 18431) / 18432;   // 每块 18 Kbit

    // ⭐ 延迟参数上界 = DEPTH−1（⭐ 因为 `delay_i` 只有 AW 位，天然不会超）
    localparam [AW:0] DEPTH_M1 = DEPTH - 1;

    // ═══════════════════════════════════════════════════════════════════════
    // ② 延迟线存储（⭐ Gowin BSRAM 推断模板：单时钟 + 写使能 + **寄存读数据**）
    //   ⚠️ 模板一旦变形（读数据不寄存 / 异步读）⇒ 综合器会退化成
    //      **分布式 LUT RAM** ⇒ 🔴 294912 bit 的 LUT RAM **装不下**（综合报错）。
    //   ⇒ ⭐ 这里刻意保持最朴素的形态：一个写口 + 一个寄存读口。
    // ═══════════════════════════════════════════════════════════════════════
    reg [MEM_W-1:0] mem [0:DEPTH-1];
    reg [MEM_W-1:0] mem_r;

    // ═══════════════════════════════════════════════════════════════════════
    // ③ 写指针 + 填满标志（⭐ `primed`：延迟线还没写满一圈时**湿声强制 0**）
    //   ⭐ **为什么必须这样**（两条独立的理由）：
    //     ① 🔴 **上电时 BSRAM 内容是垃圾** —— 不做保护就会把垃圾当成回声放出来
    //        （⭐ 上电"放一声怪响"正是本项目最忌讳的失败模式）。
    //     ② ⭐ **仿真可判定** —— 不保护的话读出来是 `x`，判据全部变成"不确定"。
    //   📌 代价：上电后 **16384 个样点 ≈ 336 ms** 内只有干声（⭐ 听感上等于"没开效果"）。
    // ═══════════════════════════════════════════════════════════════════════
    reg [AW-1:0] wr_ptr;
    reg [AW:0]   prime_cnt;
    reg          primed_r;

    // ═══════════════════════════════════════════════════════════════════════
    // ④ 合唱 LFO（⭐ 16 位自由运行三角波，每样点走 `LFO_INC`）
    //   ⭐ **为什么用三角波而不是正弦**：⛔ 不需要 ROM、⛔ 不需要乘法器，
    //      而听感上（对 chorus 的调制）与正弦**没有可辨差别**。
    //   🔴 **⛔ 不能直接把 `lfo_r` 去中心当调制量** —— 那在回绕处是**锯齿**
    //      （+满 突然跳到 −满）⇒ 读地址"啪"地跳一整圈 ⇒ **爆音**。
    //      ⇒ ⭐ 必须先折成三角波（上半程上行、下半程下行）。
    // ═══════════════════════════════════════════════════════════════════════
    reg [15:0] lfo_r;

    // ⭐ 折成三角波：0 → 32767 → 0（⭐ 周期 = 65536/LFO_INC 个样点）
    wire [15:0]       lfo_tri = lfo_r[15] ? ~lfo_r : lfo_r;
    // ⭐ 去中心 ⇒ 归一化有符号调制量（±16384 ≈ ±1.0）
    wire signed [16:0] mod_raw = $signed({1'b0, lfo_tri}) - 17'sd16384;
    // ⭐ 换算成 Q8 的"样点数"：`mod_raw/16384 × CHORUS_MOD_SAMPLES × 256`
    //    = `mod_raw × MOD / 64` ⇒ 右移 6
    wire signed [24:0] mod_mul = mod_raw * $signed({1'b0, CHORUS_MOD_N});
    wire signed [17:0] mod_Q8  = mod_mul >>> 6;             // ±(MOD×256) Q8

    // ═══════════════════════════════════════════════════════════════════════
    // ⑤ 读地址（stage0 组合）：统一按 **Q8 小数地址** 算，两种模式共用
    //   · delay ：`addr = (wr − D) << 8`（⭐ 小数位恒 0 ⇒ 插值结果 == tap0，逐位精确）
    //   · chorus：`addr = (wr − D) << 8 + mod_Q8`（⭐ 带小数 ⇒ 线性插值）
    // ═══════════════════════════════════════════════════════════════════════
    wire          chorus_s0   = (sel_i == 2'd1);
    //  ⭐⭐ 2026-10-15 修（合唱绕回）：⭐ 下界必须【按模式】取，而且合唱下界是 **MOD + 1** ——
    //     🔴 原写法对合唱也用 `DLY_MIN = 2` ⇒ 当 `D < 调制深度(128)` 时，
    //        `m > D` 的那半个 LFO 周期里读地址 `wr−D+m` 落在**写指针前面**
    //        ⇒ 环回读上一圈 ⇒ ⭐ 有效延迟从几十采样【跳到 ≈ 2048−(m−D) ≈ 39 ms】，
    //          每 0.67 s 来回跳一次（⭐ 听感：周期性爆音/音色跳变）。
    //     ⭐⭐ **正确推导**（⛔ 不是经验值，⛔ 也不是早先写过的 133/134）：
    //        · 不变量：读基址 ≡ **本样本自己的写地址**（`wr_s0` 与 `rd0_s0` **同沿同源**）
    //          ⇒ 上一样本的写地址 = **基址 − 1**
    //        · tap0 读（`T_k`）    ：落在 `基址 − D + f`     ⇒ 需 `D ≥ f + 1`
    //        · tap1 读（`T_k + 1`）：落在 `基址 − D + f + 1` ⇒ 需 `D ≥ f + 2`
    //          （⭐ "可见"要求该槽**已经写完**：`mem` 写口在 `T + 4`，而 tap1 在
    //            `T + 2` 读出 ⇒ 落在【基址】就是**本样本正在写的槽**，读到上一圈）
    //        · `f = floor(mod_Q8 / 256)`，`mod_Q8 ∈ [−32768, +32666]` ⇒ `f ∈ [−128, +127]`
    //        ⇒ ⭐⭐ **合唱下界 = MOD + 1 = 129**（⛔ 不是 `MOD = 128`）
    //     🔴 **下界 = 128 的后果**（⭐ 这就是"周期性爆音"没修干净的原因）：
    //        `D = 128, m = +127` 时 tap1 恰好落在【基址】（本样本正在写的槽）
    //        ⇒ 读到【上一圈】（≈ 2048 个样点前）⇒ 插值权重 254/256
    //        ⇒ **湿声几乎全是错值**；⭐ 触发窗口 = 每 LFO 周期（0.67 s）**64 个样点**
    //        ⇒ ⭐ **周期性爆音仍在**（只是窗口从"半个周期"缩到"64 个样点"）。
    //     📌 延迟模式仍是 `DLY_MIN = 2`（⭐ 语义逐位不变 ⇒ 零回归）。
    //     ⭐ 零代价：两份实例的 `sel_i` 都是**编译期常量**（`fx_chain.v:246` 接 `2'd1`、
    //        `:280` 接 `2'd0`）⇒ 这个 mux 会被综合**直接折叠掉**，⛔ 不新增任何逻辑。
    //     ⚠️ `CHORUS_MOD_SAMPLES` 是 `integer` ⇒ ⛔ 不能位选（`K-91`）；
    //        这里用"整数表达式赋给定宽 localparam"的写法（合法且无位选）。
    //     📌 判据：`tb/w3c/tb_fx_delay_chorus_floor.sv`（C14 —— 直连本模块、
    //        `LFO_INC=2048` 让 LFO 走到三角峰 `f = +127` ⇒ 下界差 1 立刻红）。
    localparam [AW-1:0] DLY_MIN_CH =
        ((CHORUS_MOD_SAMPLES + 1) < DEPTH) ? (CHORUS_MOD_SAMPLES + 1) : (DEPTH - 1);
    wire [AW-1:0] dly_lo      = chorus_s0 ? DLY_MIN_CH : DLY_MIN;
    wire          dly_clamped = (delay_i < dly_lo);
    wire [AW-1:0] dly_c       = dly_clamped ? dly_lo : delay_i;

    //   ⭐ 为什么**延迟模式**的 `D ≥ 2`（⭐ 已核实安全，⛔ 数值不改）：
    //      · `f = 0`（延迟模式恒为 0）⇒ tap1 的偏移 = 1 ⇒ 该槽由**上一采样**在
    //        `T_{k−1} + 4 ≤ T_k` 写入 ⇒ ⭐ tap1 读（`T_k + 2`）时**可见** ✓
    //      · 只有 `D = 1` 才坏：tap1 偏移 = 0 ⇒ 落在【基址】= **本样本的写槽**
    //        （⚠️ 写口在 `T + 4`，⛔ 不是"本拍要写"）⇒ 🔴 读到上一圈 ✗
    //      · ⭐ 合唱模式下界不同（= `MOD + 1`）—— 理由见上面 ⑤ 的推导 ✓
    wire signed [TAP_W-1:0] wr_q8   = {{(TAP_W-AW-8){1'b0}}, wr_ptr, 8'b0};
    wire signed [TAP_W-1:0] dly_q8  = {{(TAP_W-AW-8){1'b0}}, dly_c,  8'b0};
    wire signed [TAP_W-1:0] mod_ext = {{(TAP_W-18){mod_Q8[17]}}, mod_Q8};

    wire signed [TAP_W-1:0] tap_q8  = wr_q8 - dly_q8
                                    + (chorus_s0 ? mod_ext : {TAP_W{1'b0}});
    //   ⭐ 整数部分取 `[AW+7:8]`（AW 位），⭐ 小数部分取 `[7:0]`（Q8）
    //      ⇒ ⚠️ 负数时整数部分是"向下取整"，与小数部分配合 ⇒ 插值**无偏**
    wire [AW-1:0] rd0_addr = tap_q8[AW+7:8];
    wire [7:0]    rd_frac  = tap_q8[7:0];

    // ═══════════════════════════════════════════════════════════════════════
    // ⑥ 流水线寄存器（⭐ 声明放在"用它们的组合逻辑"之前 —— 本项目踩过 bind 错误）
    // ═══════════════════════════════════════════════════════════════════════
    reg                       valid_s0, valid_s1, valid_s2, valid_s3;
    reg signed [SAMPLE_W-1:0] dry_s0, dry_s1, dry_s2, dry_s3;
    reg [MIX_W-1:0]           mix_s0, mix_s1, mix_s2, mix_s3;
    reg [FB_W-1:0]            fb_s0,  fb_s1,  fb_s2,  fb_s3;
    reg [AW-1:0]              wr_s0,  wr_s1,  wr_s2,  wr_s3;
    reg [7:0]                 frac_s0, frac_s1, frac_s2;
    reg                       en_s0,  en_s1,  en_s2,  en_s3;
    reg [AW-1:0]              rd0_s0;
    reg [MEM_W-1:0]           tap0_r, tap1_r;
    //  ⭐⭐ 2026-10-15：**第 5 级**（拆锥）——
    //     🔴 原把「插值乘法 → 饱和 → mix/feedback 两个乘法 → 饱和 → RAM 写口」
    //        全塞在一拍 ⇒ 实测 `slack 0.022 / arrival 21.028 / required 21.050`
    //        （⭐ 22 ps 余量，且占全设计最差 setup 路径 6 条；改成运行时参数后
    //         两个乘法不再能常量折叠 ⇒ 恶化到 **TNS −306.8 ns / 133 条违例**）。
    //     ✅ 修法：在 `wet_f` 之后**插一级寄存器 `wet_r`** ⇒ 两个乘法分到两拍，
    //        每拍 ≈10 ns。⭐ 代价：本模块 4→5 拍 ⇒ `fx_chain` **17→19 拍**
    //        （⭐ 链上**两个** `fx_delay` 实例各 +1 ⇒ 合计 +2；实测见
    //         `tb/w3c/tb_fx_chain_latency_contract.sv` = 19 clk = 380 ns），
    //        ⛔ 不花一块 BSRAM。
    reg signed [SAMPLE_W-1:0] wet_r;          // ⭐ stage3 的插值结果（送 stage4 做乘法）
    reg                       sat_w_s3;       // ⭐ stage3 的插值饱和标志（延迟到 stage4 记账）

    // ═══════════════════════════════════════════════════════════════════════
    // ⑦ 存储读地址（⭐ 每拍给一个地址；时序见文件头"5 级流水"）
    //   · cycle N   （`valid_i`）：给 **tap0** 地址 ⇒ posedge N+1 得到 tap0
    //   · cycle N+1（`valid_s0`）：给 **tap1 = tap0+1** ⇒ posedge N+2 得到 tap1
    //   ⚠️ 其余拍给什么地址都无所谓（读出来没人用），但**必须有确定值** ⇒ 给 tap0。
    // ═══════════════════════════════════════════════════════════════════════
    wire [AW-1:0] mem_raddr = valid_s0 ? (rd0_s0 + {{(AW-1){1'b0}}, 1'b1}) : rd0_addr;

    // ═══════════════════════════════════════════════════════════════════════
    // ⑧ 读出重建（⭐ 18 bit ⇒ 24 bit：低位补 0，⭐ 与写入时的截断**完全一致**）
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [SAMPLE_W-1:0] tap0_f = {tap0_r, {SH{1'b0}}};
    wire signed [SAMPLE_W-1:0] tap1_f = {tap1_r, {SH{1'b0}}};

    // ⭐ 线性插值：`wet = tap0 + (tap1 − tap0) × frac / 256`
    //   ⚠️ 延展到 SUM_W 再算，⛔ 不在 24 位里减（否则 tap0−tap1 会溢出）
    wire signed [SUM_W-1:0] d_tap    = tap1_f - tap0_f;
    wire signed [SUM_W-1:0] d_scaled = (d_tap * $signed({1'b0, frac_s2})) >>> 8;
    wire signed [SUM_W-1:0] wet_sum  = tap0_f + d_scaled;

    wire over_pos_w = ~wet_sum[SUM_W-1] && (|wet_sum[SUM_W-2 : SAMPLE_W-1]);
    wire over_neg_w =  wet_sum[SUM_W-1] && ~(&wet_sum[SUM_W-2 : SAMPLE_W-1]);
    wire signed [SAMPLE_W-1:0] wet_lin = over_pos_w ? {1'b0, {(SAMPLE_W-1){1'b1}}}
                                       : over_neg_w ? {1'b1, {(SAMPLE_W-1){1'b0}}}
                                       : wet_sum[SAMPLE_W-1:0];

    // ⭐ 未写满一圈 ⇒ **湿声强制 0**（⭐ 见 ③ 的两条理由）
    wire signed [SAMPLE_W-1:0] wet_f = primed_r ? wet_lin : {SAMPLE_W{1'b0}};

    // ═══════════════════════════════════════════════════════════════════════
    // ⑨ 干湿混合（⭐⭐ send/return）`y = x + (wet×mix) >>> MIX_W`
    //   ⭐ 干声系数恒 `2^MIX_W`（= 1.0）⇒ `mix` **只调湿声**，⛔ 不动干声。
    //   ⭐ `mix = 0` 时 `y = (x×256)>>8 = x` ⇒ **逐位等于输入**（⭐ 判据用它）
    //      ⚠️ 注意这条在 `en = 1` 下也成立（湿声项被 mix=0 归零，干声恒 1.0）
    //   ⭐ 与**纯 send/return 形式**的等价关系（⭐ 逐位证明见下方 `dry_w` 处）：
    //      `(dry×256 + wet×mix) >>> 8 ≡ dry + ((wet×mix) >>> 8)`
    //      ⚠️ 这是「硬件写法 ≡ 数学意图」，⛔ **不是**"和旧 crossfade 版等价"
    // ═══════════════════════════════════════════════════════════════════════
    wire [MIX_W:0] mix_u = {1'b0, mix_s3};             // ⭐ 拆锥后：stage4 用 s3
    //   ⭐⭐ 2026-10-15：**干湿律从 crossfade 改成 send/return** ——
    //      🔴 用户实测原 crossfade 版"延迟突兀地响两下"：`mix` 一动，
    //         **干声跟着变小**（`dry = 1 − mix`）⇒ 推 mix 时先听见干声掉、
    //         再听见湿声进来 ⇒ 听感是"响两下"，⛔ 不是平滑的 send/return。
    //      ✅ send/return：**干声恒 1.0**，`mix` **只调湿声**（= 真机的 FX send 量）。
    //   ⭐ 等价性证明（⛔ 不是"近似"，是**逐位相同**）—— 证明的是
    //      「本模块保留的硬件形式 ≡ **纯 send/return 形式**」：
    //      `(dry×256 + wet×mix) >>> 8  ≡  dry + ((wet×mix) >>> 8)`
    //      ⭐ 因为 `dry×256` 是 256 的**整数倍**，而 `>>>` 对负数就是 `floor(÷256)`
    //         ⇒ `floor((A + B)/256) = A/256 + floor(B/256)`（A 整除 256）✓
    //      ⇒ ⭐ **所以只需改 `dry_w` 这一处**：`×256` 与 `>>>8` 原样保留，
    //         ⛔ 不用动 `p_dry`/`mix_sum`/`mix_sh`，也⛔ 不会引入舍入差异。
    //   ⭐ 附带收益（综合）：`dry_w` 变成**常量** ⇒ `p_dry = dry_s3 << 8`
    //      ⇒ **少一个 24×9 乘法器**（原 `dry_s3 * dry_w` 是变量乘法）。
    wire [MIX_W:0] dry_w = ONE_Q;                      // ⭐ send/return：干声系数恒 1.0

    wire signed [SUM_W-1:0] p_dry   = dry_s3 * $signed({1'b0, dry_w});
    wire signed [SUM_W-1:0] p_wet   = wet_r  * $signed({1'b0, mix_u});
    wire signed [SUM_W-1:0] mix_sum = p_dry + p_wet;
    wire signed [SUM_W-1:0] mix_sh  = mix_sum >>> MIX_W;

    wire over_pos_m = ~mix_sh[SUM_W-1] && (|mix_sh[SUM_W-2 : SAMPLE_W-1]);
    wire over_neg_m =  mix_sh[SUM_W-1] && ~(&mix_sh[SUM_W-2 : SAMPLE_W-1]);
    wire signed [SAMPLE_W-1:0] mix_sat = over_pos_m ? {1'b0, {(SAMPLE_W-1){1'b1}}}
                                       : over_neg_m ? {1'b1, {(SAMPLE_W-1){1'b0}}}
                                       : mix_sh[SAMPLE_W-1:0];

    // ═══════════════════════════════════════════════════════════════════════
    // ⑩ 写回数据 `w = x + fb×wet`（⭐ 反馈在这里闭合 ⇒ 回声"重复"）
    //   ⭐ 旁路时写**纯干声**（⛔ 不写反馈）—— 两条理由：
    //     ① ⭐ 让延迟线始终是"最近 DEPTH 个干声" ⇒ 一开效果**立刻**有回声可放
    //        （⛔ 否则要等 335 ms 才"热"起来）
    //     ② 🔴 旁路时若还累积反馈，⭐ 一个长音就能把线里灌到饱和
    //        ⇒ 开效果的一瞬间**爆音**。
    //   ⭐ 饱和（`K-101` 写法）⇒ 反馈再大也只是**限幅**，⛔ 不会回绕成怪声
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [SUM_W-1:0] p_fb   = wet_r * $signed({1'b0, fb_s3});
    wire signed [SUM_W-1:0] fb_sum = dry_s3 + (p_fb >>> FB_W);

    wire over_pos_f = ~fb_sum[SUM_W-1] && (|fb_sum[SUM_W-2 : SAMPLE_W-1]);
    wire over_neg_f =  fb_sum[SUM_W-1] && ~(&fb_sum[SUM_W-2 : SAMPLE_W-1]);
    wire signed [SAMPLE_W-1:0] fb_sat = over_pos_f ? {1'b0, {(SAMPLE_W-1){1'b1}}}
                                      : over_neg_f ? {1'b1, {(SAMPLE_W-1){1'b0}}}
                                      : fb_sum[SAMPLE_W-1:0];

    wire signed [SAMPLE_W-1:0] wr_full = en_s3 ? fb_sat : dry_s3;
    //   ⭐ 存进 BSRAM 的是**高 MEM_W 位**（⭐ 有符号截断 ⇒ 误差 ≤ 1 LSB@18bit）
    wire [MEM_W-1:0]           wr_mem  = wr_full[SAMPLE_W-1 : SH];

    // ⭐ 三处饱和的合并判据（⭐ 只做"记账"，⛔ 不参与数据通路）
    //   📌 拆锥后：插值饱和（`over_*_w`）在 stage3 产生 ⇒ 用 `sat_w_s3` 延迟到 stage4 记账
    wire sat_any = sat_w_s3 | over_pos_m | over_neg_m | over_pos_f | over_neg_f;

    // ═══════════════════════════════════════════════════════════════════════
    // ⑪ 硬旁路：`en = 0` ⇒ 输出**逐位等于**输入（⭐ 判据 (d)）
    //   ⚠️ 注意：旁路只改**样本值**，⛔ 不改 valid 的时序（⭐ 流水线照走）
    //      ⇒ ⭐ 与 `master_mix` 的"valid 与数据严格配对"约定一致。
    // ═══════════════════════════════════════════════════════════════════════
    wire signed [SAMPLE_W-1:0] fx_out = en_s3 ? mix_sat : dry_s3;

    assign wr_ptr_o = wr_ptr;
    assign primed_o = primed_r;

    // ═══════════════════════════════════════════════════════════════════════
    // ⑫ 饱和自增（⚠️ ⛔ 不许回绕 —— 回绕会让"溢出"看起来像"刚清零"）
    //   ⭐ 函数声明放在**用它之前**（Verilog-2001 的 module item 顺序不保证）
    // ═══════════════════════════════════════════════════════════════════════
    function [15:0] sat_inc16;
        input [15:0] v;
        begin
            sat_inc16 = (v == 16'hFFFF) ? 16'hFFFF : (v + 16'd1);
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⑬ 主时序（5 级流水）
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_s0 <= 1'b0; valid_s1 <= 1'b0; valid_s2 <= 1'b0; valid_s3 <= 1'b0;
            dry_s0 <= {SAMPLE_W{1'b0}}; dry_s1 <= {SAMPLE_W{1'b0}}; dry_s2 <= {SAMPLE_W{1'b0}};
            dry_s3 <= {SAMPLE_W{1'b0}};
            mix_s0 <= {MIX_W{1'b0}}; mix_s1 <= {MIX_W{1'b0}}; mix_s2 <= {MIX_W{1'b0}};
            mix_s3 <= {MIX_W{1'b0}};
            fb_s0  <= {FB_W{1'b0}};  fb_s1  <= {FB_W{1'b0}};  fb_s2  <= {FB_W{1'b0}};
            fb_s3  <= {FB_W{1'b0}};
            wr_s0  <= {AW{1'b0}};    wr_s1  <= {AW{1'b0}};    wr_s2  <= {AW{1'b0}};
            wr_s3  <= {AW{1'b0}};
            frac_s0<= 8'd0;          frac_s1<= 8'd0;          frac_s2<= 8'd0;
            en_s0  <= 1'b0;          en_s1  <= 1'b0;          en_s2  <= 1'b0;  en_s3 <= 1'b0;
            wet_r  <= {SAMPLE_W{1'b0}};   sat_w_s3 <= 1'b0;
            rd0_s0 <= {AW{1'b0}};
            tap0_r <= {MEM_W{1'b0}}; tap1_r <= {MEM_W{1'b0}};
            wr_ptr <= {AW{1'b0}};
            prime_cnt <= {(AW+1){1'b0}};
            primed_r  <= 1'b0;
            lfo_r     <= 16'd0;
            valid_o   <= 1'b0;
            sample_o  <= {SAMPLE_W{1'b0}};
            sat_cnt_o <= 16'd0;
            clamp_cnt_o <= 16'd0;
        end else begin
            // ── stage0：捕获输入 + 算出本样本的读地址 ─────────────────────
            valid_s0 <= valid_i;
            if (valid_i) begin
                dry_s0  <= sample_i;
                mix_s0  <= mix_i;
                fb_s0   <= fb_i;
                wr_s0   <= wr_ptr;
                en_s0   <= en_i;
                rd0_s0  <= rd0_addr;
                frac_s0 <= rd_frac;
                // ⭐ 合唱 LFO 每**样点**走一步（⛔ 不是每 clk）
                lfo_r   <= lfo_r + LFO_INC_C;
                if (dly_clamped)
                    clamp_cnt_o <= sat_inc16(clamp_cnt_o);
            end

            // ── stage1：取 **tap0**；同时把 tap1 的地址送进存储器 ─────────
            valid_s1 <= valid_s0;
            if (valid_s0) begin
                tap0_r  <= mem_r;
                dry_s1  <= dry_s0;
                mix_s1  <= mix_s0;
                fb_s1   <= fb_s0;
                wr_s1   <= wr_s0;
                en_s1   <= en_s0;
                frac_s1 <= frac_s0;
            end

            // ── stage2：取 **tap1** ───────────────────────────────────────
            valid_s2 <= valid_s1;
            if (valid_s1) begin
                tap1_r  <= mem_r;
                dry_s2  <= dry_s1;
                mix_s2  <= mix_s1;
                fb_s2   <= fb_s1;
                wr_s2   <= wr_s1;
                en_s2   <= en_s1;
                frac_s2 <= frac_s1;
            end

            // ── stage3（⭐ 拆锥新增）：**插值到此为止** ⇒ 结果与饱和标志打进 `wet_r` ──
            //   🔴 原实现把插值、两个乘法、三处饱和、RAM 写口全挤在一拍 ⇒ 21.028 ns。
            //   ✅ 现在这一拍只做：`d_tap → ×frac → >>8 → +tap0_f → 饱和 → primed mux`
            //      ⇒ 只剩 **1 个乘法**；`wet_r` 之后那一拍才做 mix/feedback 两个乘法。
            valid_s3 <= valid_s2;
            if (valid_s2) begin
                wet_r    <= wet_f;
                sat_w_s3 <= over_pos_w | over_neg_w;
                dry_s3   <= dry_s2;
                mix_s3   <= mix_s2;
                fb_s3    <= fb_s2;
                wr_s3    <= wr_s2;
                en_s3    <= en_s2;
            end

            // ── stage4（写回 + 出结果）────────────────────────────────────
            //   ⭐ 写指针只在**有样本时**走一步 ⇒ ⛔ 空闲拍不会"吃掉"延迟长度
            //   📌 与 RAM 写口（`mem[wr_s3] <= wr_mem`）**同拍** ⇒ 地址与数据严格配对
            if (valid_s3) begin
                wr_ptr <= wr_ptr + 1'b1;
                if (prime_cnt != DEPTH_M1[AW:0])
                    prime_cnt <= prime_cnt + 1'b1;
                // ⭐ 写满一圈 ⇒ 之后湿声才有效（⭐ 幂等，⛔ 不会自己清零）
                if (prime_cnt == DEPTH_M1[AW:0])
                    primed_r <= 1'b1;
                if (sat_any)
                    sat_cnt_o <= sat_inc16(sat_cnt_o);
            end

            // ── 输出寄存（⭐ 与 `valid_s3` 严格配对 ⇒ ⛔ 不会"valid 与数据错拍"）──
            valid_o  <= valid_s3;
            sample_o <= fx_out;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⑭ 存储器（⭐ 写口 + 寄存读口；⚠️ 地址不冲突由**按模式的下界**保证 ——
    //     延迟 `D ≥ 2` · 合唱 `D ≥ MOD+1`（⭐ 见 ⑤ 的推导；⛔ 写口在 `T+4`，
    //     而 tap1 在 `T+2` 读出 ⇒ "同一沿"⛔ 不是判据，"写没写完"才是））
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (valid_s3)
            mem[wr_s3] <= wr_mem;
        mem_r <= mem[mem_raddr];
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⑮ 参数自检（⭐ 与 `clk_gen`/`master_mix`/`calib_cmd` 同一套路）
    //   ⚠️ 这些组合会**静默失效**，且现象极难定位
    // ═══════════════════════════════════════════════════════════════════════
    initial begin
        if (MEM_W > SAMPLE_W)
            $display("ERROR [fx_delay] MEM_W=%0d > SAMPLE_W=%0d => the delay line would store MORE bits than the sample has; SH is negative and the truncation is undefined. PARAM_OK=0.", MEM_W, SAMPLE_W);
        if (AW < 4)
            $display("ERROR [fx_delay] AW=%0d < 4 => DEPTH=%0d is too small: the [2, DEPTH-1] delay window collapses and DLY_MIN itself is out of range. PARAM_OK=0.", AW, DEPTH);
        if ((MIX_W < 1) || (FB_W < 1))
            $display("ERROR [fx_delay] MIX_W=%0d FB_W=%0d => a zero-width Q-format has no fractional bits, so the mix/feedback terms become 0 or 1 only. PARAM_OK=0.", MIX_W, FB_W);
        if (TAP_W < (AW + 9))
            $display("ERROR [fx_delay] TAP_W=%0d < AW+9=%0d => the Q8 tap address loses its sign headroom and the chorus tap wraps. PARAM_OK=0.", TAP_W, AW + 9);
        if (LFO_INC < 1)
            $display("ERROR [fx_delay] LFO_INC=%0d < 1 => the chorus LFO never moves, so chorus silently degrades to a plain fixed delay. PARAM_OK=0.", LFO_INC);
        if (CHORUS_MOD_SAMPLES < 1)
            $display("ERROR [fx_delay] CHORUS_MOD_SAMPLES=%0d < 1 => zero chorus depth (no modulation at all). PARAM_OK=0.", CHORUS_MOD_SAMPLES);
        //  ⭐ 2026-10-15 新增：合唱下界现在是 `MOD+1` ⇒ 若它顶到 `DEPTH-1`，
        //     那个"下界"就**不再是下界**（tap 会读上一圈）而**没有任何报错** ⇒ 必须自检。
        if ((CHORUS_MOD_SAMPLES + 1) >= DEPTH)
            $display("ERROR [fx_delay] CHORUS_MOD_SAMPLES=%0d + 1 >= DEPTH=%0d => the chorus floor DLY_MIN_CH collapses to DEPTH-1, so the modulated tap reads lap-around data. PARAM_OK=0.", CHORUS_MOD_SAMPLES, DEPTH);

        // ⭐⭐ 存储预算：**由参数自动算**（⭐ 报告里的块数就是这一行）
        $display("NOTE [fx_delay] DEPTH=%0d samples = %0d ms @48828.125Hz | MEM_W=%0d => %0d bit / 18432 bit-per-block = %0d BSRAM block(s) of 118",
                 DEPTH, (DEPTH * 1000) / 48829, MEM_W, BSRAM_BITS, BSRAM_BLK);
    end

endmodule

`default_nettype wire
