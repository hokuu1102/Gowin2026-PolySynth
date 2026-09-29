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

            always @(posedge clk or negedge rst_n) begin
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

    // t_cmp = {rem_r, quo_r 最高位}：当前被除数段（含即将移入的下一位）
    always @(*) begin
        t_cmp = {rem_r, quo_r[23]};
    end

    always @(posedge clk or negedge rst_n) begin
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
            if (raw_f <= zero_r[cal_ch]) begin
                err  <= 1'b1;                            // 满量程码不大于零点 -> 拒绝
                gain_r[cal_ch] <= (1 << 8);
            end else begin
                err   <= 1'b0;
                busy  <= 1'b1;
                cnt_r <= {IW{1'b0}};
                rem_r <= 24'd0;
                den_r <= raw_f - zero_r[cal_ch];
                //  ⭐⭐ 2026-09-28：**同时记下该轴的标定行程码**（⭐ 供输出级夹紧用）
                //     📌 与 `den_r` **同拍、同表达式** ⇒ ⭐ 两者必然一致（⭐ 单一来源）
                span_r[cal_ch] <= raw_f - zero_r[cal_ch];
                quo_r <= DIVIDEND;                        // 被除数 = FULL<<8
            end
        end else if (busy) begin
            if (cnt_r == ITER_CNT) begin
                // 写回拍：quo_r 已是 ITER 次迭代后的商
                busy <= 1'b0;
                if (quo_r[GW-1:0] == 0)         gain_r[div_ch] <= 1;
                else if (quo_r[23:GW] != 0)     gain_r[div_ch] <= {GW{1'b1}};  // 饱和
                else                            gain_r[div_ch] <= quo_r[GW-1:0];
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
    //      ⚠️ `span_r[ch] == 0`（⭐ 该轴从未标定过）⇒ ⭐ **不夹**（⭐ 保持旧行为，
    //         ⛔ 否则"未标定"的轴会永远输出 0）
    wire [DW:0] dcode  = (raw_f > zero_r[ch]) ? (raw_f - zero_r[ch]) : {(DW+1){1'b0}};
    //  ⭐⭐ 上界 = `min(MAX_TRAVEL, span_r[ch])`（⭐ `span_r` 未标定 ⇒ 只用 `MAX_TRAVEL`）
    //     ⭐ 这样**两种情形都安全**：⭐ 标定了 ⇒ 用真实行程；⭐ 没标定 ⇒ 用硬上界 ✅
    localparam [DW:0] MAXT = MAX_TRAVEL;
    wire [DW:0] dlim = ((span_r[ch] != {(DW+1){1'b0}}) && (span_r[ch] < MAXT))
                     ? span_r[ch] : MAXT;
    wire [DW:0] dclamp = (dcode > dlim) ? dlim : dcode;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r   <= 1'b0;
            ch_r  <= {CW{1'b0}};
            prod_r <= {PW{1'b0}};
        end else begin
            if (tare) zero_r[cal_ch] <= raw_f;
            v_r   <= valid;
            ch_r  <= ch;
            //  ⭐⭐ 2026-09-28：⭐ 用**夹紧后**的差值 `dclamp`（⛔ 不是裸的 `raw - zero`）
            //      ⇒ ⭐ `pos` 上界 = 该轴标定行程 ✅（⭐ 见 `span_r` 的说明 / `K-153`）
            prod_r <= dclamp * gain_r[ch];
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
    integer gi;
    initial begin
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
