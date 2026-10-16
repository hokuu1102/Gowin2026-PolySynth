`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// calib.v · 逐通道零点/灵敏度标定（T13，丙线 L8，余量项）
//
// 做什么（对齐 K-16 比例式口径）：
//   · tare：把某通道【当前】原始码记为零点（去皮）
//   · span：把某通道【当前】原始码记为满量程，用移位-减法除法器算出 Q8.8 增益
//   · 正常通路：out = saturate((raw - zero) * gain >> 8)，延 1 拍
//
// 冻结事实：K-16  VCC = VREF = 3V3 ⇒ 比例式换算，原始码 0..4095 直接对应 0..VREF，
//          因此标定只在【码域】做，不需要任何电压换算。
// ⛔ 纪律：不上电自动标定（上电时传感器可能不在零位）；标定只由上层显式触发。
//
// 输入接口对齐 mcp3208_scanner 的输出：
//   valid / channel(sample_channel[2:0]) / data(sample_data[11:0])
//   ⚠️ 单芯片 8 通道（CH0..CH7），故 NCH 默认 8（不是三片 24 —— 三片口径见 K-79，另行裁决）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module calib #(
    parameter integer NCH  = 8,           // 通道数（单芯片 8 通道）
    parameter integer DW   = 12,          // ADC 位宽
    parameter integer GW   = 16,          // 增益位宽（Q8.8，1.0 = 16'h0100）
    parameter integer FULL = 4095,        // 满量程码
    // ⭐⭐ 2026-09-28 新增：**单轴行程的硬上界**（⭐ 原始码单位）
    //
    //   🔴 **为什么必须有它**（⭐ 我第一版只夹 `span_r`，⭐ **那是错的**）：
    //      ⭐ `span_r` **只在 span 标定【成功】时才写** ⇒ ⭐ 标定成功 ⟺ `gain` 已标定
    //      ⇒ ⭐ 那时 `pos` 本来就被 `FULL` 夹住 ⇒ 🔴 **那个夹紧是空操作**。
    //      🔴 而**【span 标定失败】时**（⭐ 用户的实际情形：`raw` 在跳 ⇒ 稳定判据永不满足）
    //      ⇒ `span_r = 0` ⇒ ⭐ 夹紧**完全不生效** ⇒ ⚠️ `pos` 照样冲到 `FULL = 4095`。
    //
    //   ⭐ **本参数的语义**：⭐ **"一个磁轴按键，物理上最多能移动多少原始码"**
    //      · ⭐ 用户板实测满行程 ≈ **744** ⇒ 取 **1023**（≈ 25% ADC 量程）留 37% 余量
    //      · ⚠️ 换板/换磁铁后若行程更大 ⇒ ⭐ **只改这一个数**
    //   ⭐ **效果**：⭐ 无论 `gain` 标定与否，⭐ `pos` 都 ≤ `MAX_TRAVEL`
    //      ⇒ ⭐ 力度流/事件流**再也看不到物理上不可能的变化** ✅（⭐ 修 `K-153`）
    parameter integer MAX_TRAVEL = 1023,
    //  ⭐⭐ 2026-09-29 新增：`raw` 的【3 点中值滤波】开关（⭐ `K-153` 的**软件侧兜底**）
    //
    //   🔴 **为什么需要**：⭐ 上板实测 `raw` 偶发跳 **150~550**（⭐ 峰值 `|Δpos|` **2193**）
    //      ⇒ ① ⭐ `calib_span` 的"稳定判据"（`STABLE_TOL=48`）**永不满足** ⇒ **标定必被拒**
    //         ② ⭐ 力度流/事件流看到**物理上不可能**的变化
    //
    //   ⭐ **为什么是 3 点中值**：⭐ 它能滤掉**【孤立】坏样本**，⭐ 而**保留真实运动**
    //      （⭐ 真实手指运动至少影响 **2 个连续**样本 ⇒ 中值取不到它）
    //      ⚠️ 且它是**因果**的（窗口 = 本拍 ＋ 前 2 拍）⇒ ⭐ **不增加流水延迟** ✅
    //
    //   ⭐⭐ **默认 = 0（关）** ⇒ ⭐ **与旧行为【逐位一致】**，⛔ **不影响任何既有判据 / 手感**；
    //      ⭐ 等上板用 `probe_q.py` 量清 `raw` 的**按通道 spread** 之后，
    //      ⭐ 再决定要不要打开（⭐ 根因未定之前，⛔ 不擅自改用户能感觉到的行为）
    parameter integer RAW_MEDIAN_EN = 0,
    parameter integer CW   = (NCH > 1) ? 3 : 1
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---- 采样输入（接 mcp3208_scanner）------------------------------------
    input  wire             valid,
    input  wire [CW-1:0]    ch,
    input  wire [DW-1:0]    raw,

    // ---- 标定命令 ----------------------------------------------------------
    input  wire             tare,      // 1 周期：cal_ch 的当前值记为零点
    input  wire             span,      // 1 周期：cal_ch 的当前值记为满量程
    input  wire [CW-1:0]    cal_ch,
    output reg              busy,      // 除法器忙（span 计算期间）
    output reg              err,       // 标定异常：span 码 <= zero 码

    // ---- 标定后输出（相对 valid 延 1 拍）------------------------------------
    output reg              out_valid,
    output reg  [CW-1:0]    out_ch,
    output reg  [DW-1:0]    out_val
);

    // ── 标定参数存储 ────────────────────────────────────────────────────────
    reg [DW:0]   zero_r [0:NCH-1];      // 零点原始码（多 1 位存减法中间量）
    reg [GW-1:0] gain_r [0:NCH-1];      // Q8.8 增益
    // ⭐⭐ 2026-09-28 新增：**该轴的标定行程码**（= 满行程时的 `raw − zero`）
    //   🔴 **为什么必须存它**：⭐ `out_val` 原来只夹到 `FULL`（= 4095，**输出满量程**）
    //      ⛔ **不是该轴的真实行程** ⇒ ⚠️ 一旦 `gain` 没标定（默认 256 = 1.0），
    //      `pos` 就是**裸的 `raw − zero`** ⇒ 🔴 **能冲到 4095**
    //      ⇒ ⭐ 上板实测 `|Δpos|` 峰值 **2193**（⭐ 而满行程只有 744，⭐ 2.9 倍）
    //      ⇒ ⭐ 力度流/事件流看到**物理上不可能**的变化 ⇒ 见 `K-153`
    //   ✅ 修法：⭐ **在乘法之前把 `raw − zero` 夹到 `span_r[ch]`** ⇒
    //      ⭐ 无论 `gain` 标定与否，`pos` 都**不可能超过该轴的标定行程** ✅
    reg [DW:0]   span_r [0:NCH-1];

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-09-30 新增：**标定值水位闸**（⭐ 修「复位 ≠ 冷启动」）
    //
    //   🔴 **问题**：⭐ 上面三个数组**不在任何复位分支里**（⭐ 见下方 `always` 的复位体）
    //      ⇒ ⚠️ 逻辑复位**清不掉它们** ⇒ 🔴 **复位 ≠ 冷启动**
    //      （⭐ 实测：冷启动 `zero_r = 0` ⇒ `pos = raw ≈ 1985` ≫ `TRIG_TH = 64`
    //        ⇒ 🔴 **该轴被永久判"按下"**）。
    //
    //   ⭐ **做法（⛔ 不是把数组改成寄存器）**：⭐ 给每个数组配一张 `NCH` 位**有效位图**，
    //      读侧改成"**没标定就读默认值**" ⇒ ⭐ 冷启动与逻辑复位后
    //      **每一个可观测输出都逐位相同**（`zero_eff=0` / `gain_eff=256` / `span_eff=0`）✅
    //      ⇒ ⭐ 数组本身**仍留在 LUTRAM**（⭐ 零面积/时序回归：48 FF vs 672 FF）✅
    //   📌 与本项目既有惯用法一致：⭐ `looper` / `note_manager` / `event_extract` /
    //      `evt_merge` / `seq_arb` / `uart_tx_fifo` **全部**用"复位水位 + 读侧判非空"。
    //
    // Read discipline: zero/gain/span reads must pass their validity bitmap.
    // This includes the qualified per-channel upper bounds below.
    //      —— ⚠️ 否则水位闸被绕过 ⇒ 缺陷重现。
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ **2026-09-30 实测踩坑（⭐ `tb_calib` 2 条 FAIL 的真因）**：
    //      ⚠️ 第一版把三张位图写成**未打包数组** `reg zero_vld [0:NCH-1];`，
    //         并把读入口写成 **`function`**、在 `dcode` 里**同一个表达式调用两次**
    //         （`(raw_f > zero_of(ch)) ? (raw_f - zero_of(ch)) : ...`）
    //      ⇒ 🔴 `tb_calib` 的 `tare` / `underflow` 两条 FAIL
    //         （⭐ 而 `span` 两条**过** —— 因为 `gain_of`/`span_of` **各只调用一次**）
    //      ⭐ 修法（两处一起改，⛔ 不赌是哪一处）：
    //        ① ⭐ 三张位图改成**打包向量** ⇒ `zero_vld[ch]` 是**位选**，
    //           ⛔ 不再是"未打包数组 + 变量索引"（⭐ 与旧代码的 `zero_r[ch]` 同族）
    //        ② ⭐ 读入口改成**纯组合 `wire`** ⇒ ⛔ 没有函数调用、没有静态存储、
    //           ⛔ 没有"同一表达式调两次"的求值次序问题
    //      📌 旁证：本仓库 `tb_calib.sv:123` 的同类辅助函数写的是 `function automatic`
    //         ⇒ ⭐ 说明本项目**已经知道**非 automatic 函数的这个坑。
    // ═══════════════════════════════════════════════════════════════════════
    reg [NCH-1:0] zero_vld;      // ⭐ 该通道零点是否已标定（⭐ 打包 ⇒ 位选安全）
    reg [NCH-1:0] gain_vld;      // ⭐ 该通道增益是否已知
    reg [NCH-1:0] span_vld;      // ⭐ 该通道行程码是否已标定

    // Qualified selected-channel read entrances. Uncalibrated entries use defaults.
    //   ⚠️ 用**输入端口 `ch`/`cal_ch`** ⇒ ⭐ 在模块开头就可用，⛔ 不受声明顺序约束 ✅
    wire [DW:0]   zero_rd = zero_vld[ch]     ? zero_r[ch]     : {(DW+1){1'b0}};
    wire [GW-1:0] gain_rd = gain_vld[ch]     ? gain_r[ch]     : (1 << 8);
    wire [DW:0]   span_rd = span_vld[ch]     ? span_r[ch]     : {(DW+1){1'b0}};
    wire [DW:0]   zero_cc = zero_vld[cal_ch] ? zero_r[cal_ch] : {(DW+1){1'b0}};

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-09-29 新增：`raw` 的 3 点中值滤波（⭐ 见 `RAW_MEDIAN_EN` 的说明）
    //
    //   ⭐ **中值恒等式**：`median(a,b,c) = a + b + c − min − max`
    //      ⇒ ⭐ **纯算术，⛔ 不需要排序网络**（⭐ 面积更小、深度更浅）✅
    //   ⚠️ `a+b+c` 必须**先加宽**再减（⭐ 3×4095 = 12285 > 12 位 ⇒ 否则回绕）
    //      📌 同族教训：⭐ `K-91`（位宽必须显式落定）、⭐ `K-34`（防截断）
    //
    //   ⭐ **为什么用 `generate` 而不是运行时常量**：⭐ `RAW_MEDIAN_EN = 0` 时
    //      **整块逻辑（含 3×8×12 位历史寄存器）被【编译期删掉】** ⇒ ⭐ 零面积零时序代价 ✅
    // ═══════════════════════════════════════════════════════════════════════
    function [DW-1:0] med3;
        input [DW-1:0] a;
        input [DW-1:0] b;
        input [DW-1:0] c;
        reg [DW-1:0] lo;
        reg [DW-1:0] hi;
        reg [DW+1:0] sum;
        begin
            lo  = (a < b) ? a : b;   lo = (lo < c) ? lo : c;   // min
            hi  = (a > b) ? a : b;   hi = (hi > c) ? hi : c;   // max
            sum = {2'b0, a} + {2'b0, b} + {2'b0, c};
            med3 = (sum - {2'b0, lo} - {2'b0, hi});
        end
    endfunction

    //  ⭐ 滤波后（或直通）的采样 —— ⭐ 下游**一律**用它，⛔ 不再直接用 `raw`
    wire [DW-1:0] raw_f;

    generate
        if (RAW_MEDIAN_EN != 0) begin : g_raw_median
            reg [DW-1:0] raw_h1 [0:NCH-1];   // 前 1 拍
            reg [DW-1:0] raw_h2 [0:NCH-1];   // 前 2 拍
            reg          seen_r [0:NCH-1];   // ⭐ 该通道是否已收到过样本
            integer      mi;

            wire [DW-1:0] raw_med = med3(raw, raw_h1[ch], raw_h2[ch]);

            //  ⭐ **上电第 1 个样本【直通】** —— ⚠️ 否则历史全 0 ⇒ `median(x,0,0) = 0`
            //     ⇒ ⭐ **每次复位后该通道的第 1 个 `pos` 会假 0**（⭐ 1 个采样拍 = 500 µs）
            assign raw_f = seen_r[ch] ? raw_med : raw;

            always @(posedge clk) begin
                if (!rst_n) begin
                    for (mi = 0; mi < NCH; mi = mi + 1) begin
                        raw_h1[mi] <= {DW{1'b0}};
                        raw_h2[mi] <= {DW{1'b0}};
                        seen_r[mi] <= 1'b0;
                    end
                end else if (valid) begin
                    if (!seen_r[ch]) begin
                        //  ⭐ 第 1 个样本：把 h1/h2 **都**设成它 ⇒ 第 2 个样本起中值就有意义
                        raw_h1[ch] <= raw;
                        raw_h2[ch] <= raw;
                        seen_r[ch] <= 1'b1;
                    end else begin
                        raw_h2[ch] <= raw_h1[ch];
                        raw_h1[ch] <= raw;
                    end
                end
            end
        end else begin : g_raw_plain
            //  ⭐ 默认路径：⭐ **逐位直通** ⇒ ⭐ 与加滤波之前的行为**完全一致** ✅
            assign raw_f = raw;
        end
    endgenerate

    // ── 除法器：gain = (FULL << 8) / (span_code - zero) ─────────────────────
    // 移位-减法：被除数 = FULL<<8（24 bit），除数 = den_r（≤ 4095）。
    // 每次迭代把商的一位移入 quo_r，ITER 次后 quo_r = 完整商。
    localparam integer ITER = 24;
    localparam integer IW   = 5;

    // ⚠️⚠️ 2026-09-21 实测踩坑（K-91，**T47 一跑就抓到**）：
    //   本文件原来写了 3 处 **SystemVerilog 带宽度强制转换** `N'(expr)`：
    //       `24'(FULL) << 8` / `IW'(ITER)` / `PW'(FULL)` / `DW'(FULL)`
    //   ⇒ iverilog 接受（所以**仿真全绿**），但 ⛔ **Gowin 按 Verilog-2001 解析**：
    //       `ERROR (EX3863) : Syntax error near '''` ×4
    //       `ERROR (EX3928) : Module 'calib' is ignored due to previous errors`
    //   ⇒ ⭐ **整个 calib 模块被丢弃、根本没进综合** —— 而仿真侧完全看不出来。
    //   ⭐ 根因：工程把 `.sv` 登记成 `type="file.verilog"`（见 `Gowin2026.gprj` 注释），
    //      即**按 Verilog-2001 子集编译** ⇒ 只能用 Verilog-2001 语法。
    //   ⚠️ 同一个坑 `tlc5916_driver.sv` 里**已经记过一次**（`longint'()` 不可用）。
    //   ⇒ ⭐ **纪律：`.sv` 文件里 ⛔ 不要用任何 SV 专有构造**（强制转换 / longint /
    //      logic / always_ff / typedef …）；判据 = **必须真的跑过一次 Gowin 综合**。
    localparam [23:0] DIVIDEND = FULL << 8;      // 等价于原来的 `24'(FULL) << 8`
    // ⚠️ K-91：⛔ 不能对 integer 参数做位选（`FULL[DW-1:0]` / `ITER[IW-1:0]`
    //   在 Verilog-2001 里同样非法）⇒ 先落成**有宽度的 localparam 向量**再比较/赋值。
    localparam [IW-1:0] ITER_CNT  = ITER;

    reg [23:0]   rem_r;
    reg [23:0]   quo_r;
    reg [DW:0]   den_r;
    reg [IW-1:0] cnt_r;
    reg [CW-1:0] div_ch;
    reg [24:0]   t_cmp;

    // ⭐⭐ 2026-09-30：⭐ 位图的置位条件用【组合 wire】表达（⛔ 不碰寄存器）
    //
    //   🔴🔴 **为什么必须这样**（⭐ Gowin 综合实测报错）：
    //      `ERROR (EX2000) : Net 'gain_vld[7]' is constantly driven from multiple places`
    //      `ERROR (EX1999) : Found another driver here`
    //      `Module 'calib' remains a black box due to errors in its contents`
    //   ⭐ 根因：⭐ **Gowin 要求每个 `reg` 只能被【一个】`always` 块驱动**。
    //      ⚠️ 而原来 `gain_vld`/`span_vld` 在【块 A（除法器）】与【块 C（主流水+复位）】
    //      **两处**被赋值 ⇒ 🔴 **综合直接报错、整个模块变黑盒**。
    //   ⭐⭐ 而 **iverilog 允许多处驱动同一个 `reg`**（按最后赋值解析）
    //      ⇒ 🔴 **全量回归 99/99 全绿，综合却直接死** —— ⚠️ 这是
    //      **"仿真抓不到、只有综合能抓"** 的一类错（⭐ `L66`/`C31`/`T70` 那一族）。
    //   ✅ **修法**：⭐ 三个位图**只在【块 C】被赋值**；本块只提供**组合条件** ✅
    //   ⚠️ 两个块的时钟/复位**完全一致**（都是 `posedge clk or negedge rst_n`）
    //      ⇒ ⭐ 搬到块 C **同拍、同复位 ⇒ 不改变时序** ✅
    //   ⭐⭐ 2026-09-30：⭐ `span_err_w` 已**删除** —— ⭐ 它唯一的用途是给
    //      `gain_vld[cal_ch]` 置位（⭐ 见块 C），⭐ 而那个置位已被移除
    //      （⭐ 失败的重标定**不应**把该轴标成"增益已知"）⇒ ⭐ 它成了死逻辑 ✅
    //      📌 教训：⭐ **防御性代码若不再被用，就是噪声**（⭐ 同 `S_NEXT` 的注释）
    wire span_ok_w  = (!busy && span && (raw_f >  zero_cc));   // ⭐ span 起点·接受分支
    wire div_done_w = ( busy && (cnt_r == ITER_CNT));          // ⭐ 除法器写回拍

    // t_cmp = {rem_r, quo_r 最高位}：当前被除数段（含即将移入的下一位）
    always @(*) begin
        t_cmp = {rem_r, quo_r[23]};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            err  <= 1'b0;
            cnt_r  <= {IW{1'b0}};
            rem_r  <= 24'd0;
            quo_r  <= 24'd0;
            den_r  <= {DW+1{1'b0}};
            div_ch <= {CW{1'b0}};
        end else if (!busy && span) begin
            div_ch <= cal_ch;
            //   ⭐⭐ 2026-09-30：⭐ 读侧一律走 `zero_cc`（⭐ 水位闸纪律）
            //   ⭐⭐ 2026-09-30（紧急修复）：⭐ **`err` 一次赋值 = 本次尝试的结果**
            //     ⚠️ 诚实标注：⭐ 旧写法（失败置 1 / 成功清 0）**语义上已经等价** ——
            //        ⭐ 本次改写**不改变行为**，⭐ 它改的是【把不变量写成代码的形状】：
            //        ⭐ "尝试失败 ⇒ 1；尝试成功 ⇒ 0" **一句话说完** ⇒
            //        ⚠️ 以后加分支时不会漏掉"成功要清 0" ✅
            //     📌 教训：⭐ 语义等价的改写，只要它消除歧义、把不变量写进形状，就值得做 ✅
            err <= (raw_f <= zero_cc);                   // ⭐ 本次尝试：失败 = 1，成功 = 0
            if (raw_f <= zero_cc) begin
                // 失败：⭐ `err` 已置 1（⭐ 见上）⇒ ⛔ 这里不拉 `busy`（⭐ 与它严格互斥）
                //   ⭐⭐ 2026-09-30：⭐ **删掉** `gain_r[cal_ch] <= (1 << 8);`
                //      🔴 **为什么删**：⭐ 水位闸已经保证"未标定 ⇒ `gain_rd` = 256"
                //         （⭐ 见 `gain_rd` 的默认值）⇒ ⭐ 显式写是**冗余**的；
                //         而它**有害** —— ⚠️ 一次失败的重标定会把**上次成功 span 的增益**
                //         清成 1.0，⭐ 而 `span_vld` 仍是 1、`span_r` 仍是旧行程
                //         ⇒ 🔴 **该轴静默失去归一化**（⭐ 正是"板 2 比板 1 小声"的形态）。
                //      ⭐ 现在：⭐ 失败的重标定**不碰** `gain_r`/`span_r`，
                //         且 `gain_vld` 也**不再被置 1**（⭐ 见块 C 的条件）
                //         ⇒ ⭐ **上次成功的标定完整保留** ✅
            end else begin
                busy  <= 1'b1;
                cnt_r <= {IW{1'b0}};
                rem_r <= 24'd0;
                den_r <= raw_f - zero_cc;
                //  ⭐⭐ 2026-09-28：**同时记下该轴的标定行程码**（⭐ 供输出级夹紧用）
                //     📌 与 `den_r` **同拍、同表达式** ⇒ ⭐ 两者必然一致（⭐ 单一来源）
                span_r[cal_ch] <= raw_f - zero_cc;
                //   ⭐⭐ 2026-09-30：⭐ `span_vld`/`gain_vld` 的置位**移到【块 C】**
                //      （⭐ 条件 = `span_ok_w`）—— ⛔ 本块不再碰位图 ✅
                quo_r <= DIVIDEND;                        // 被除数 = FULL<<8
            end
        end else if (busy) begin
            if (cnt_r == ITER_CNT) begin
                // 写回拍：quo_r 已是 ITER 次迭代后的商
                busy <= 1'b0;
                if (quo_r[GW-1:0] == 0)         gain_r[div_ch] <= 1;
                else if (quo_r[23:GW] != 0)     gain_r[div_ch] <= {GW{1'b1}};  // 饱和
                else                            gain_r[div_ch] <= quo_r[GW-1:0];
                //   ⭐⭐ 2026-09-30：⭐ 三条分支都写出了确定值 ⇒ ⭐ 增益现在是"已知"的
                //      ⭐ `gain_vld` 的置位**移到【块 C】**（⭐ 条件 = `div_done_w`）✅
            end else begin
                if (t_cmp >= den_r) begin
                    rem_r <= t_cmp[23:0] - den_r;
                    quo_r <= {quo_r[22:0], 1'b1};
                end else begin
                    rem_r <= t_cmp[23:0];
                    quo_r <= {quo_r[22:0], 1'b0};
                end
                cnt_r <= cnt_r + 1'b1;
            end
        end
    end

    // ── 零点记录 + 正常通路（1 拍流水）──────────────────────────────────────
    localparam integer PW = DW + GW + 1;   // 29：乘法中间量（防截断，K-34 教训）
    // ⚠️ K-91：有宽度的常量向量（Verilog-2001 不能写 `PW'(FULL)` / `DW'(FULL)`）
    localparam [PW-1:0] FULL_EXT  = FULL;
    localparam [DW-1:0] FULL_CODE = FULL;

    reg [PW-1:0]  prod_r;
    reg [CW-1:0]  ch_r;
    reg           v_r;

    //  ⭐⭐ 2026-09-28：**`pos` 的两级保护**（⭐ 见 `span_r` 的说明）
    //   ① ⭐ **下溢守卫**：`raw <= zero` ⇒ 差值为 0（⭐ 原代码已有，⭐ 这里显式化）
    //   ② ⭐⭐ **上溢夹紧**：⭐ 差值夹到**该轴标定行程** `span_r[ch]`
    //      ⇒ ⭐ 无论 `gain` 标定与否，`pos` 都不可能超过该轴的真实行程 ✅
    //      ⚠️ `span_r[ch] == 0`（⭐ 该轴从未标定过）⇒ ⭐ **退回硬上界 `MAX_TRAVEL` 夹紧**
    //         （⭐ 即 `dlim = MAXT` —— ⭐ 与紧邻的 `localparam MAXT` 及 `wire dlim` 定义一致）
    // One widened subtract provides both the difference and its borrow.
    // Known unsigned inputs: borrow => raw_f < zero_rd => saturate to zero.
    // Equality produces zero too. Ports, latency and calibration state stay
    // unchanged; avoid a separate wide raw_f > zero_rd comparator.
    wire [DW+1:0] raw_delta = {2'b0, raw_f} - {1'b0, zero_rd};
    wire [DW:0] dcode = raw_delta[DW+1] ? {(DW+1){1'b0}} : raw_delta[DW:0];
    //  ⭐⭐ 上界 = `min(MAX_TRAVEL, span_r[ch])`（⭐ `span_r` 未标定 ⇒ 只用 `MAX_TRAVEL`）
    //     ⭐ 这样**两种情形都安全**：⭐ 标定了 ⇒ 用真实行程；⭐ 没标定 ⇒ 用硬上界 ✅
    localparam [DW:0] MAXT = MAX_TRAVEL;
    wire [DW:0] dlim = ((span_rd != {(DW+1){1'b0}}) && (span_rd < MAXT))
                     ? span_rd : MAXT;
    // For unsigned ADC codes, clamp(raw-zero,0,limit) is equally:
    // raw<zero ? 0 : raw>zero+limit ? limit : raw-zero.
    // Precompute each channel's widened upper threshold independently of ch,
    // in parallel with the selected subtract, rather than serializing the
    // channel mux -> subtract -> clamp comparison -> multiplier chain.
    // No state, extra sample cycle, or calibration command timing is added.
    wire [DW+1:0] upper_by_channel [0:NCH-1];
    genvar ui;
    generate for (ui=0;ui<NCH;ui=ui+1) begin : g_upper_threshold
        wire [DW:0] z = zero_vld[ui] ? zero_r[ui] : {(DW+1){1'b0}};
        wire [DW:0] s = span_vld[ui] ? span_r[ui] : {(DW+1){1'b0}};
        wire [DW:0] limit_code = ((s != {(DW+1){1'b0}}) && (s < MAXT)) ? s : MAXT;
        assign upper_by_channel[ui] = {1'b0,z} + {1'b0,limit_code};
    end endgenerate

    //  ⭐⭐⭐⭐ 2026-10-17（🔴 **时序修复 · 只读审计的 top-1**）：
    //     ⭐ **把"每通道夹紧上界"从【每样本组合重算】改成【标定寄存器状态】** ✅
    //
    //  🔴 **为什么（实测证据）**：⭐ 综合报告的 **25 条最差路径里 24 条**都是
    //     `u_calib0/u_calib1 span_r[6]_6_s0 → n2109_s`（**Logic Level 20**，`slack −2.9 ns`
    //     按 `constr/top.sdc:148` 的 `set_max_delay 16.4` 口径）
    //     逐级：`span_r[6]` → `limit_code`(4 级) → `upper_by_channel`(13 位加法)
    //           → `upper_rd`(8:1 mux) → ★**10 级 14 位比较**★ → 夹紧 mux → **DSP A 口**
    //     ⚠️ 而 netlist 实证 `MULTALU27X18 n2109_s` 的 `AREG/BREG` **全 BYPASS**
    //        ⇒ ⭐ 夹紧链与乘法器**串成一条组合路**，还要额外吃 **3.459 ns** 的 tSu ✅
    //
    //  🔴 **为什么"每样本重算"是浪费**：⭐ `limit_code`/`upper_by_channel` **只依赖
    //     `zero_r[ui]`/`span_r[ui]`**，而这两个**只在 `tare`/`span` 那一刻变**
    //     （⭐ 正常演奏中**永不变**）⇒ ⭐ 却每个 `valid`（每通道 ~31 µs）都重算一遍 ✅
    //
    //  ✅ **修法**：⭐ 无条件把 `upper_by_channel` **打一拍存进 `upper_q`**
    //     ⇒ ⭐ 那条 `limit_code + 加法` 长链**终点变成寄存器**，⛔ 不再进每样本路径 ✅
    //     ⇒ ⭐ 每样本路径缩短为 `upper_q[ch]`(mux) → 比较 → 夹紧 → DSP
    //        ≈ **省 5~6 级**（4 级 `limit_code` ＋ 13 位加法）✅
    //
    //  📌 **代价（诚实标注）**：⭐ `upper_q` 比 `zero_r`/`span_r` **晚 1 拍**
    //     ⇒ ⚠️ `tare`/`span` 之后**那一拍内的样本会用旧阈值**（20 ns 窗口，每次标定只一次）
    //     📌 判据：⭐ `tb/drivers/tb_calib.sv`（tare→立刻采样）·
    //        `tb/drivers/tb_calib_equivalence.sv`（对参考模型逐位比）**必须实跑**
    //     📌 若那两条判据红了 ⇒ ⭐ 说明"标定当拍就要求新阈值"是契约
    //        ⇒ 那时改用"只在 `tare`/`span_ok_w` 时更新 `upper_q[cal_ch]`"（⭐ 同样省链）✅
    //  📌 **为什么用数组而不是打包向量**：⭐ 与上面 `upper_by_channel` **同一写法**，
    //     ⛔ 不引入新的索引算术（⭐ 打包向量的 `ch*(DW+2)` 反而会加 1~2 级）✅
    //  📌 **第一版踩的坑（记档）**：⭐ 我最初写成"**无条件** `upper_q[vi] <= upper_by_channel[vi]`"
    //     ⇒ 🔴 `tb/drivers/tb_calib_equivalence.sv:31` **立刻红**
    //        （`cycle-exact calib mismatch check=33102 raw=2441 ch=7`）
    //     🔴 原因：⭐ `span_r` 在**另一个 always 块**（`:294`）写、`zero_r` 在本块（`:387`）写
    //        ⇒ ⭐ 无条件打拍必然**晚 1 拍** ⇒ ⚠️ 标定之后**那一拍内的样本用旧阈值** ✗
    //  📌 **第二版踩的坑（记档）**：⭐ 改成"只在 `tare`/`span_ok_w` 时更新"后**仍然红**
    //     🔴 原因：⭐ 我用了 `zero_rd`/`span_rd` —— 那两个是**按 `ch` 索引**的
    //        ⇒ 🔴 却赋给 `upper_q[cal_ch]` ⇒ ⚠️ **`ch != cal_ch` 时算错通道** ✗
    //     ✅ 修法：⭐ 一律按 **`cal_ch`** 索引 ✅
    //  ✅ **最终改法**：⭐ 只在 `tare`/`span_ok_w` 时更新 `upper_q[cal_ch]`，
    //     且⭐ **用【本次即将写入的】新值算** ⇒ ⭐ 与 `zero_r`/`span_r` **同拍生效** ✅
    //     ⇒ ⭐ 那条 `limit_code + 加法` 长链的**终点仍是寄存器**（⛔ 不进每样本路径）✅
    //     ⇒ ⭐ 每样本路径 = `upper_q[ch]`(mux) → 比较 → 夹紧 → DSP ≈ **省 5~6 级** ✅
    //  ⚠️ **复位值必须是 `MAXT`（⛔ 不是 0）**：⭐ `zero_vld=0`/`span_vld=0` 时
    //     `upper_by_channel = 0 + MAXT = MAXT`（⭐ 见 `:359` 的 `limit_code` 兜底）✅
    reg [DW+1:0] upper_q [0:NCH-1];
    integer      vi;

    //  ⭐ 三个组合临时量：⭐ **一律按 `cal_ch` 索引**（⛔ 不用 `zero_rd`/`span_rd`）
    wire [DW:0] upper_zero_n = tare
                             ? raw_f
                             : (zero_vld[cal_ch] ? zero_r[cal_ch] : {(DW+1){1'b0}});
    //  ⭐⭐ 2026-10-17（🔴 **时序实验 · 综合 #1 热点**）：⭐ **减法改成【显式等宽】** ✅
    //     🔴 **实测证据**（只读审计，⭐ 综合报告逐级路径）：
    //        ⭐ 当前 25 条最差 setup 里 **23 条**都是 `u_autotare/cal_ch_o_0_s0
    //        → u_calib{0,1}/upper_q...RAMREG_*`（⭐ 即下面这条写侧链 ✅）
    //        ⭐ 逐级实测：前端 3.93 ns · 🔴 **减法 6.45 ns（占 40%）** ·
    //           比较 1.82 ns · 加法 1.22 ns · 回写 mux 0.75 ns
    //        ⭐ 而**同宽的加法**走的是 ALU 进位链（**0.045 ns/级**）
    //        ⇒ 🔴 **减法被映射成了 LUT 借位链（0.65 ns/级）—— 慢 14 倍** ✅
    //     ⭐ **本改动的假设**：⭐ 那正是因为**两侧位宽不等**
    //        （⭐ `raw_f` 是 `[DW-1:0]` = **12 位**，⭐ `zero_cc` 是 `[DW:0]` = **13 位**）
    //        ⇒ ⚠️ 混宽减法让综合器**没法用统一的进位链** ⇒ 退化成 LUT 借位链 ✅
    //     ✅ **改法**：⭐ 把被减数**显式补零扩到 13 位**（`{1'b0, raw_f}`）
    //        ⇒ ⭐ **语义逐位相同**（⭐ Verilog 本来就会零扩展，⭐ 只是让意图显式 ✅）
    //        ⇒ ⭐ **零功能风险**（⛔ 不改任何数值）✅
    //     📌 **判据**：⭐ `tb_calib` 9/9 ＋ `tb_calib_equivalence`（⭐ **逐位比参考模型** ✅）
    //        ＋ ⭐ 综合后看那条链是否**从 LUT 借位链变成 ALU 进位链** ✅
    //     ⚠️ **诚实标注**：⭐ 这是**假设**，⛔ 我无法只读证明综合器一定照办 ⇒
    //        ⭐ **落地后必须实测**（⭐ 这正是 `P0` 那次"模型算的上界 ≠ 实测"的教训）✅
    wire [DW:0] upper_span_n = span_ok_w
                             ? ({1'b0, raw_f} - zero_cc)          // ⭐ 显式等宽（原为 `raw_f - zero_cc`）
                             : (span_vld[cal_ch] ? span_r[cal_ch] : {(DW+1){1'b0}});
    wire [DW:0] upper_lim_n  = ((upper_span_n != {(DW+1){1'b0}}) && (upper_span_n < MAXT))
                             ? upper_span_n : MAXT;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (vi = 0; vi < NCH; vi = vi + 1)
                upper_q[vi] <= {1'b0, MAXT};       // ⭐ 与 `upper_by_channel` 的冷启动值一致
        end else if (tare || span_ok_w) begin
            upper_q[cal_ch] <= {1'b0, upper_zero_n} + {1'b0, upper_lim_n};
        end
    end

    wire [DW+1:0] upper_rd = upper_q[ch];
    wire [DW:0] dclamp = ({2'b0,raw_f} > upper_rd) ? dlim : dcode;

    always @(posedge clk) begin
        if (!rst_n) begin
            v_r   <= 1'b0;
            ch_r  <= {CW{1'b0}};
            prod_r <= {PW{1'b0}};
            // ⭐⭐ 2026-09-30：⭐ **水位闸必须复位** ⇒ ⭐ 让"复位 == 冷启动"
            //    成为**代码里的不变量**（⭐ 三个数组本身仍在 LUTRAM，⛔ 不清它们）
            //   ⭐ 打包向量 ⇒ ⭐ 一次清空（⛔ 不需要 for 循环、⛔ 不需要 `vi`）
            zero_vld <= {NCH{1'b0}};
            gain_vld <= {NCH{1'b0}};
            span_vld <= {NCH{1'b0}};
        end else begin
            // ⭐⭐ 2026-09-30：⭐ **三个位图【只在本块】被赋值**
            //   🔴 为什么：⭐ Gowin 要求每个 `reg` 只能被**一个** `always` 块驱动
            //      （⭐ 否则 `EX2000 ... driven from multiple places` ⇒ 🔴 模块变黑盒）
            //      ⭐ 而 iverilog **允许多驱动** ⇒ ⚠️ **仿真全绿、综合才炸** ✅
            //   ⭐ 两个块的时钟/复位完全一致 ⇒ ⭐ 搬过来**不改变时序** ✅
            if (tare)                    zero_vld[cal_ch] <= 1'b1;   // ⭐ 零点已标定
            if (span_ok_w)               gain_vld[cal_ch] <= 1'b1;   // ⭐ 增益已确定（⭐ 失败【不】置位）
            if (span_ok_w)               span_vld[cal_ch] <= 1'b1;   // ⭐ 行程码已标定
            if (div_done_w)              gain_vld[div_ch] <= 1'b1;   // ⭐ 除法器算出增益
            if (tare) begin
                zero_r[cal_ch]   <= raw_f;
            end
            v_r   <= valid;
            ch_r  <= ch;
            //  ⭐⭐ 2026-09-28：⭐ 用**夹紧后**的差值 `dclamp`（⛔ 不是裸的 `raw - zero`）
            //      ⇒ ⭐ `pos` 上界 = 该轴标定行程 ✅（⭐ 见 `span_r` 的说明 / `K-153`）
            //
            //  ⭐⭐⭐⭐ 2026-10-11（⭐ **`P2-24` ①**）：⭐ **用 `valid` 门控这个乘法** ✅
            //  🔴 **为什么**：⭐ 原来是**无条件**执行 ⇒ ⚠️ 即使 `valid = 0`，
            //     ⭐ DSP 也**每个 20 ns 周期**都吃进 `dclamp`/`gain_rd` ⇒
            //     🔴 **白烧动态功耗**（⭐ 而且那两个输入来自**长组合路**
            //        ⇒ ⭐ 翻转还会**馈进关键路径** ✅）
            //  ✅ **为什么行为安全（⭐ 逐条查过）**：
            //     · ⭐ `out_valid = v_r`（⭐ 见下方 `:380` ✅）
            //     · ⭐ `v_r <= valid`（⭐ `:369` ✅）
            //     ⇒ ⭐ **`valid = 0` 时 `out_valid = 0`** ⇒ ⭐ 下游**不看** `out_val` ✅
            //     ⇒ ⭐ `prod_r` 保持旧值**无影响** ✅
            //  📌 ⭐ **代价**：⭐ 一个 `valid` 使能（⭐ **0 LUT** ✅）
            //  ⚠️ ⭐ **它【不是】时序收益** —— ⭐ 审查自己也这么说 ✅
            //     （⭐ 真正的时序瓶颈见 `sim/evidence/timing-critical-path-20261011/` ✅）
            if (valid) prod_r <= dclamp * gain_rd;
        end
    end

    wire [PW-1:0] shifted = prod_r >> 8;

    always @(*) begin
        out_valid = v_r;
        out_ch    = ch_r;
        // ⚠️ K-91：原为 `(shifted > PW'(FULL)) ? DW'(FULL) : ...`（SV 强制转换，
        //   Gowin 报 EX3863）。改为 Verilog-2001 的有宽度常量，行为等价。
        out_val   = (shifted > FULL_EXT) ? FULL_CODE : shifted[DW-1:0];
    end

    // 初始增益 = 1.0（Q8.8 = 256），零点 = 0
    //   ⭐⭐ 2026-09-30：⭐ 加水位闸之后，**正确性的承载者已经变成 `*_of()` 的默认值**
    //      （⭐ `zero_vld=0` ⇒ `zero_eff=0`；`gain_vld=0` ⇒ `gain_eff=256`；
    //        `span_vld=0` ⇒ `span_eff=0`）⇒ ⭐ 本 `initial` 块**不再是唯一防线**，
    //      保留它只是为了**仿真上电时的数组内容确定**（⭐ 真硅片靠 DFF 上电为 0）。
    integer gi;
    initial begin
        //  ⭐⭐ 2026-09-30：⭐ 水位闸初始化成"未标定"（⭐ 打包向量 ⇒ 一次清空）
        //     ⇒ ⭐ **时间 0 就不会有 X 传播**，⭐ 且"上电 == 复位"从第 0 拍就成立 ✅
        zero_vld = {NCH{1'b0}};
        gain_vld = {NCH{1'b0}};
        span_vld = {NCH{1'b0}};
        for (gi = 0; gi < NCH; gi = gi + 1) begin
            zero_r[gi] = {DW+1{1'b0}};
            gain_r[gi] = (1 << 8);
            //  ⭐⭐ 2026-09-28：⭐ 行程码初始为 0 ⇒ ⭐ **上电时"不夹"**
            //     （⭐ 保持"未标定 ⇒ 旧行为"的语义，⛔ 不会一上电就把 pos 夹成 0）
            span_r[gi] = {DW+1{1'b0}};
        end
    end

endmodule

`default_nettype wire
