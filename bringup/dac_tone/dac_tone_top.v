`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// dac_tone_top.v · ⭐⭐ 最小外置 DAC 出声测试（2026-09-26）
//
// ── 🔴 它做什么 ──────────────────────────────────────────────────────────────
//   ⭐ 只做一件事：⭐ 在 `I2S2_*` 三根线上输出一个 **440 Hz 正弦的 I2S 流**。
//   🔴 完全绕开：`note_manager` / `oscillator_bank` / `mixer` / `master_mix` /
//      `evt_merge` / `calib` / 采集链 —— ⭐ **一个都不例化**。
//
// ── ⭐⭐ 为什么要它 ───────────────────────────────────────────────────────────
//   🔴 现状：FPGA 侧波形**实测全对**
//      · `F20`(BCK) = 1.707 V ⇒ 3.125 MHz 方波 ✅
//      · `E22`(LRCK)= 1.7 V   ⇒ 48.83 kHz 方波 ✅
//      · `D22`(DIN) = 跳变    ⇒ 数据在动 ✅
//      · `XSMT`     = 3.3 V   ⇒ 已 un-mute ✅
//   ⇒ 🔴 但耳机仍无声 ⇒ ⚠️ 变量太多，**没法定位**。
//   ⭐ 本模块把变量压到最少：⭐ 只有 **相位累加器 + I2S 串行器**。
//      · ✅ 出声 ⇒ 🔴 问题在原合成链
//      · 🔴 还不出声 ⇒ 🔴 问题在模块/接线/I2S 格式（⭐ 改 `FORMAT_SEL` 试）
//
// ── ⭐⭐ 三个可切格式（⭐ 一次试完所有猜测）──────────────────────────────────
//   `FORMAT_SEL`: 0 = 标准 I2S（Philips，⭐ 默认）· 1 = 左对齐 · 2 = 右对齐
//   `FREQ_HZ`   : 输出频率（⭐ 默认 440 Hz）
//   `RAMP_MS`   : 上电渐入（⭐ 默认 200 ms；⭐ 防啪声、⭐ 也防"上电就没声"误判）
//
// ── 📌 它是【独立顶层】⇒ ⭐ 用自己的 `.gprj`，⛔ 不污染主工程 ──────────────────
//
// ── ⛔ 纪律 ──────────────────────────────────────────────────────────────────
//   · ⭐ Verilog-2001（`K-91`）· ⭐ 不用 PLL/CPU/HLS · ⭐ 单时钟域 · ⭐ 声明先于使用
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module dac_tone_top #(
    parameter integer CLK_HZ         = 50_000_000,
    parameter integer CLK_PER_SAMPLE = 1024,   // fs = 50e6/1024 = 48.828125 kHz
    parameter integer BCLK_DIV       = 16,     // BCK = 50e6/16 = 3.125 MHz
    parameter integer SLOT_BITS      = 32,     // 每声道 32 个 BCK
    parameter integer FORMAT_SEL     = 0,      // 0=I2S 1=左对齐 2=右对齐
    parameter integer FREQ_HZ        = 440,
    parameter integer AMP_SHIFT      = 1,      // 右移位数（1 = 半幅）
    parameter integer RAMP_MS        = 200
) (
    input  wire clk,        // V22 · 50 MHz
    input  wire rst_n,      // AA13 · 低有效
    output wire I2S2_BCK,   // F20
    output wire I2S2_LRCK,  // E22
    output wire I2S2_DIN,   // D22
    output wire led_hb      // V13 · 心跳
);

    // ═══ ① 复位同步（两级）═══════════════════════════════════════════════
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n_s = rst_sync[1];

    // ═══ ② 参数量（⭐ 先落定宽 localparam —— 🔴 `K-91` 不对 integer 位选）═══
    localparam integer FS_HZ      = CLK_HZ / CLK_PER_SAMPLE;
    //   🔴🔴 **2026-09-26 修正（⭐ 我第一版搞错了语义）**：
    //      ⭐ `BCLK_DIV` 的含义是 **BCK 的【完整周期】** 拍数（⭐ 与 `clk_gen` 一致）：
    //         `BCK = CLK_HZ / BCLK_DIV` ⇒ ⭐ 16 拍/周期 ⇒ **半周期 = 8 拍**
    //      🔴 而我第一版让计数器数到 `BCLK_DIV-1` 才翻转 ⇒ ⚠️ **周期变成 2×**
    //         ⇒ 🔴 实测 BCK 周期 **32 拍**（= 1.5625 MHz，⛔ 不是 3.125 MHz）
    //      📌 修法：⭐ **半周期 = `BCLK_DIV/2`**
    localparam integer BCLK_HALF = (BCLK_DIV < 2) ? 1 : (BCLK_DIV / 2);
    localparam integer BCLK_DIV_W = (BCLK_HALF <= 1) ? 1 : $clog2(BCLK_HALF);
    localparam [BCLK_DIV_W-1:0] BCLK_HALF_M1 = BCLK_HALF - 1;
    localparam integer HB_DIV     = CLK_HZ / 2;     // 心跳半周期（0.5 s）

    // ⭐ phase_inc = FREQ_HZ × 2^32 / FS_HZ
    //   ⚠️ 用 64 位中间量（⭐ 纯常量运算，⭐ 综合期算完）
    localparam [63:0] PHASE_INC_64 = (FS_HZ > 0)
                                   ? ((FREQ_HZ * 64'd4294967296) / FS_HZ)
                                   : 64'd1;
    localparam [31:0] PHASE_INC    = PHASE_INC_64[31:0];

    // ═══ ③ 分频：BCLK / LRCK / 帧起点 ════════════════════════════════════
    reg  [BCLK_DIV_W-1:0] bclk_cnt;
    reg                   bclk_r;
    reg  [5:0]            bit_cnt;      // 0..63（64 个 BCK = 一帧）

    wire bclk_tick = (bclk_cnt == BCLK_HALF_M1);
    //   🔴🔴 **2026-09-26 第二/第三个修正（⭐ 都是"语义搞错"）**：
    //
    //   ⭐ **修正 ②（LRCK 周期）**：⭐ 项目口径（`clk_gen`/`top.v` 注释）：
    //      · `CLK_PER_SAMPLE = 1024` 拍 = **LRCK 的完整周期**（⭐ = 一个音频帧 = fs）
    //      · `BCLK_DIV = 16` 拍 = BCK 完整周期（3.125 MHz）
    //      ⇒ ⭐ **一帧内 BCK = 1024/16 = 64** ⇒ ⭐ **每声道 = 32 个 BCK**
    //      🔴 我第一版让 LRCK **每 64 个 BCK 翻转** ⇒ 整帧 128 BCK = 2048 拍
    //         ⇒ 🔴 **fs 变成 24.4 kHz（错一半）**
    //
    //   🔴 **修正 ③（frame_start 永不成立）**：⭐ 修 ② 时我把 `bit_cnt` 改成
    //      **每 32 个 BCK 清零**（⭐ 只数"当前声道内"的位）⇒ ⚠️ 而 `frame_start`
    //      还在比 `bit_cnt == 62` ⇒ 🔴 **永远不成立** ⇒ ⚠️ 相位不推进、数据不装载
    //      ⇒ 🔴 实测 `LRCK 翻转 = 0`、样点恒 0。
    //      ⇒ ⭐ 正确：⭐ **`bit_cnt` 数 0..`SLOT_BITS-1`**，⭐
    //         **帧起点 = "LRCK 由 1 翻到 0"的那一刻**（⭐ 左声道开始）。
    //      📌 教训：⭐ **改了一处语义，必须重新核对所有依赖它的判据**
    //         （⭐ 同族：`K-129`/`K-130` —— 改了参数/格式，判据却没跟着改）。
    //
    //   ⭐ **本版结构（⭐ 重写成"无歧义"的计数器驱动式）**：
    //      · `bit_cnt`：⭐ 帧【内】的位序号，**0 .. 2×SLOT_BITS-1**（⭐ 0~63）
    //      · `lrck_r` ：⭐ **直接由 `bit_cnt` 决定**（⛔ 不用单独的翻转子）
    //         ⇒ ⭐ `lrck_r = bit_cnt >= SLOT_BITS` ⇒ ⭐ **半帧边界天然对齐**
    //      · 帧起点 = ⭐ **`bit_cnt` 由 63 回绕到 0** 的那一刻
    //   📌 **为什么改成"计数器驱动 LRCK"**：⭐ 原来用"`slot_end` 翻 `lrck_r`"
    //      的方案，⚠️ 两个条件（`bclk_tick` 与 `bclk_r`）在实现里**互相干扰**
    //      ⇒ 🔴 实测 `LRCK 翻转=0`、`DIN 翻转=0`（⭐ 都不动了）。
    //      ⭐ 改成**纯组合派生** ⇒ ⚠️ **不可能不同步**（⭐ 结构上排除这类 bug）。
    //      📌 教训：⭐ **能用组合派生的量，⛔ 不要用"事件翻转"去维护** ——
    //         后者多一个状态、就多一类不同步的可能。
    localparam integer FRAME_BITS = SLOT_BITS * 2;
    localparam [5:0]   FRAME_M1   = FRAME_BITS - 1;
    localparam integer FB_W       = (FRAME_BITS <= 1) ? 1 : $clog2(FRAME_BITS);
    localparam [FB_W-1:0] SLOT_B = SLOT_BITS[FB_W-1:0];

    //   ⭐ LRCK：⭐ 纯组合派生（⭐ 低 = 左声道，⭐ 标准 I2S）
    wire lrck_w = (bit_cnt >= SLOT_B);

    //   ⭐ 帧起点：⭐ `bit_cnt` 走满一帧（⭐ 63）之后的那一刻
    wire frame_start = bclk_tick & bclk_r & (bit_cnt == FRAME_M1);

    always @(posedge clk) begin
        if (!rst_n_s) begin
            bclk_cnt <= {BCLK_DIV_W{1'b0}};
            bclk_r   <= 1'b0;
            bit_cnt  <= {FB_W{1'b0}};
        end else if (bclk_tick) begin
            bclk_cnt <= {BCLK_DIV_W{1'b0}};
            bclk_r   <= ~bclk_r;
            //   ⭐ 在 **BCK 上升沿**（⭐ 即 `bclk_r` 当前为 0、即将变 1）推进位计数
            //      ⭐ 这正是 DAC 采样数据的那一拍
            if (bclk_r === 1'b0) begin
                bit_cnt <= (bit_cnt == FRAME_M1) ? {FB_W{1'b0}} : (bit_cnt + 1'b1);
            end
        end else begin
            bclk_cnt <= bclk_cnt + {{(BCLK_DIV_W-1){1'b0}}, 1'b1};
        end
    end

    // ═══ ④ 正弦查表（⭐ 64 点 + 四象限对称 ⇒ ⭐ 表小、⛔ 无 `.mem`）═══════
    //   🔴 **为什么不用 `$readmemh`/.mem**：
    //      ⚠️ 外部 `.mem` 在 GW5AT-60 **不加载** ⇒ ⭐ ROM 全 0 ⇒ 🔴 没声但"仿真全对"
    //   ⭐ 做法：⭐ 只存 **0°~90° 的 64 点**，⭐ 其余用对称推出
    //      ⇒ ⭐ 表只有 64 项（⭐ 综合成一个很小的 ROM）
    function signed [15:0] sin_quarter;
        input [5:0] q;              // 0..63 ⇒ 角度 q×90/64 度
        begin
            case (q)
                6'd0:  sin_quarter = 16'sd0;      6'd1:  sin_quarter = 16'sd804;
                6'd2:  sin_quarter = 16'sd1608;   6'd3:  sin_quarter = 16'sd2410;
                6'd4:  sin_quarter = 16'sd3212;   6'd5:  sin_quarter = 16'sd4011;
                6'd6:  sin_quarter = 16'sd4808;   6'd7:  sin_quarter = 16'sd5602;
                6'd8:  sin_quarter = 16'sd6393;   6'd9:  sin_quarter = 16'sd7179;
                6'd10: sin_quarter = 16'sd7962;   6'd11: sin_quarter = 16'sd8739;
                6'd12: sin_quarter = 16'sd9512;   6'd13: sin_quarter = 16'sd10278;
                6'd14: sin_quarter = 16'sd11039;  6'd15: sin_quarter = 16'sd11793;
                6'd16: sin_quarter = 16'sd12539;  6'd17: sin_quarter = 16'sd13279;
                6'd18: sin_quarter = 16'sd14010;  6'd19: sin_quarter = 16'sd14732;
                6'd20: sin_quarter = 16'sd15446;  6'd21: sin_quarter = 16'sd16151;
                6'd22: sin_quarter = 16'sd16846;  6'd23: sin_quarter = 16'sd17530;
                6'd24: sin_quarter = 16'sd18204;  6'd25: sin_quarter = 16'sd18868;
                6'd26: sin_quarter = 16'sd19519;  6'd27: sin_quarter = 16'sd20159;
                6'd28: sin_quarter = 16'sd20787;  6'd29: sin_quarter = 16'sd21403;
                6'd30: sin_quarter = 16'sd22005;  6'd31: sin_quarter = 16'sd22594;
                6'd32: sin_quarter = 16'sd23170;  6'd33: sin_quarter = 16'sd23731;
                6'd34: sin_quarter = 16'sd24279;  6'd35: sin_quarter = 16'sd24811;
                6'd36: sin_quarter = 16'sd25329;  6'd37: sin_quarter = 16'sd25832;
                6'd38: sin_quarter = 16'sd26319;  6'd39: sin_quarter = 16'sd26790;
                6'd40: sin_quarter = 16'sd27245;  6'd41: sin_quarter = 16'sd27683;
                6'd42: sin_quarter = 16'sd28105;  6'd43: sin_quarter = 16'sd28510;
                6'd44: sin_quarter = 16'sd28898;  6'd45: sin_quarter = 16'sd29268;
                6'd46: sin_quarter = 16'sd29621;  6'd47: sin_quarter = 16'sd29956;
                6'd48: sin_quarter = 16'sd30273;  6'd49: sin_quarter = 16'sd30571;
                6'd50: sin_quarter = 16'sd30852;  6'd51: sin_quarter = 16'sd31113;
                6'd52: sin_quarter = 16'sd31356;  6'd53: sin_quarter = 16'sd31580;
                6'd54: sin_quarter = 16'sd31785;  6'd55: sin_quarter = 16'sd31971;
                6'd56: sin_quarter = 16'sd32137;  6'd57: sin_quarter = 16'sd32285;
                6'd58: sin_quarter = 16'sd32412;  6'd59: sin_quarter = 16'sd32521;
                6'd60: sin_quarter = 16'sd32609;  6'd61: sin_quarter = 16'sd32678;
                6'd62: sin_quarter = 16'sd32728;
                default: sin_quarter = 16'sd32767;   // q=63
            endcase
        end
    endfunction

    // ⭐ 相位累加器（⭐ 每帧推进一步）
    reg  [31:0] phase_q;
    // ⭐ 取高 8 位 ⇒ 0..255 的相位索引
    wire [7:0]  ph = phase_q[31:24];
    // ⭐ 四象限：⭐ [7:6] 选象限，⭐ [5:0] 选 0~90° 内位置
    wire [1:0]  quad = ph[7:6];
    wire [5:0]  qidx = ph[5:0];
    wire signed [15:0] qval = sin_quarter(qidx);

    //   ⭐ 象限映射：
    //      · 0 (0~90°)   ⇒ +q(ph)
    //      · 1 (90~180°) ⇒ +q(128-ph)  = q(~ph[5:0])
    //      · 2 (180~270°)⇒ -q(ph)
    //      · 3 (270~360°)⇒ -q(~ph[5:0])
    wire [5:0] qmirror = ~qidx;
    wire signed [15:0] sine_raw =
        (quad == 2'd0) ?  qval
      : (quad == 2'd1) ?  sin_quarter(qmirror)
      : (quad == 2'd2) ? -qval
      :                  -sin_quarter(qmirror);

    // ⭐ 幅度缩放（⭐ 移位 ⇒ ⭐ 零乘法器）
    wire signed [15:0] sine_amp = sine_raw >>> AMP_SHIFT;

    // ═══ ⑤ 上电渐入（⭐ 防啪声 + ⭐ 防"上电就没声"误判）═════════════════
    //   🔴🔴 **2026-09-26 第五个修正（⭐ 渐入乘法破坏符号）**：
    //      ⭐ 独立探针实测（⭐ 决定性证据）：
    //         `sine_raw = 12539`（正），🔴 **但 `sample_now = -85`（负）**！
    //      🔴 真因：`(sine_amp * $signed({1'b0, ramp_k[7:0]})) >>> 8`
    //         · ⚠️ 两个操作数位宽不同（16 与 9）⇒ Verilog 先做**位宽对齐**
    //         · 🔴 而且 `>>>` 作用在一个**混合位宽表达式**上时，
    //           ⚠️ 整体被当成**无符号**参与后续 ⇒ 🔴 **符号被破坏**。
    //      ⇒ ⭐ 修法：⭐ **先落到一个明确的 signed 中间变量**
    //         （⭐ 位宽写死 `signed [31:0]`）⇒ ⭐ 再做算术右移 ⇒ ⭐ 无歧义。
    //      📌 教训（⭐ 本文件累计第 5 次同类）：⭐ **Verilog 的位宽/符号规则
    //         在"混合表达式"里极易出错，⭐ 而且【不报错】** ——
    //         ⭐ **每一处混合运算都要显式落到定宽中间量**。
    reg  [31:0] ramp_q;
    //   ⭐ 渐入总帧数（⭐ `RAMP_MS` 毫秒 × fs）
    localparam integer RAMP_FRAMES = (RAMP_MS * FS_HZ) / 1000;
    wire        ramp_full = (ramp_q >= RAMP_FRAMES[31:0]);
    wire [8:0]  ramp_k    = ramp_full ? 9'd256 : ramp_q[8:0];

    //   ⭐ 显式中间量：⭐ 宽度 32、signed、先乘后移
    wire signed [31:0] sine_ext  = {{16{sine_amp[15]}}, sine_amp};   // ⭐ 符号扩展到 32
    wire signed [31:0] ramp_ext  = {23'd0, ramp_k};                  // ⭐ 零扩展到 32（恒正）
    wire signed [31:0] ramped32  = (sine_ext * ramp_ext) >>> 8;      // ⭐ 32 位算术右移
    //   ⭐ 最终取低 16 位（⭐ 此时符号已正确）
    wire signed [15:0] ramped16  = ramped32[15:0];
    wire signed [15:0] sample_now = ramp_full ? sine_amp : ramped16;

    //   ⭐ 相位/渐入推进（⭐ 每帧一次）
    always @(posedge clk) begin
        if (!rst_n_s) begin
            phase_q <= 32'd0;
            ramp_q  <= 32'd0;
        end else if (frame_start) begin
            phase_q <= phase_q + PHASE_INC;
            if (!ramp_full) ramp_q <= ramp_q + 32'd1;
        end
    end

    // ═══ ⑥ I2S 串行器（⭐ 自己实现 ⇒ ⭐ 便于切格式）═══════════════════════
    //   ⭐ 每帧装载一次 32 位时隙，⭐ 然后逐位右移
    //      · `FORMAT_SEL=0` 标准 I2S：⭐ MSB 相对时隙起点延后 **1 BCK**
    //      · `FORMAT_SEL=1` 左对齐：⭐ 无延后（MSB 就在第 0 位）
    //      · `FORMAT_SEL=2` 右对齐：⭐ 数据靠时隙尾部
    //   🔴🔴 **2026-09-26 第四个修正（⭐ 位布局搞错）**：
    //      ⭐ 标准 I2S 的时隙结构（⭐ 32 个 BCK）应当是：
    //         `bit[31] = 空` · `bit[30:15] = 16 bit 样点` · `bit[14:0] = 补 0`
    //      ⭐ 含义：⭐ **MSB 相对时隙起点【延后 1 个 BCK】**（⭐ Philips 约定）
    //      🔴 我第一版写成 `{{15{0}}, 1'b0, sample_now}` ⇒ ⚠️ 样点落在 `[15:0]`
    //         ⇒ 🔴 **数据没上移** ⇒ ⚠️ DAC 按"MSB 在 bit30"解析 ⇒
    //         🔴 **解出来全是 0**（⭐ 仿真实测：399 个样点全 0）。
    //      📌 教训：⭐ **"延后 1 BCK"= 数据整体上移一位** ——
    //         ⚠️ 用拼接表达式写时极易少补一个 0（⭐ 我就错了，⭐ 而且它**不报错**）。
    wire [SLOT_BITS-1:0] slot_val =
        //   ⭐ 标准 I2S：⭐ `[30:15]` = 样点，⭐ `[31]` 与 `[14:0]` 补 0
        //      ⚠️ 拼接必须【逐段核对位宽】：
        //         `1'b0`(1) + `sample_now`(16) + `{15{1'b0}}`(15) = ⭐ **32** ✅
        (FORMAT_SEL == 0) ? {1'b0, sample_now, {(SLOT_BITS-17){1'b0}}}
        //   ⭐ 左对齐：⭐ 无延后 ⇒ `[31:16]` = 样点
      : (FORMAT_SEL == 1) ? {sample_now, {(SLOT_BITS-16){1'b0}}}
        //   ⭐ 右对齐：⭐ 贴时隙尾部 ⇒ `[15:0]` = 样点
      :                     {{(SLOT_BITS-16){1'b0}}, sample_now};

    //   ⭐ 声道内的位序号（⭐ 0 .. SLOT_BITS-1）
    wire [FB_W-1:0] bit_in_slot = (bit_cnt >= SLOT_B) ? (bit_cnt - SLOT_B) : bit_cnt;

    //   🔴🔴 **2026-09-26 第六个修正 —— ⭐ 撤回上一条"off-by-one"改动**
    //
    //   ⚠️ **我一度以为这里有 off-by-one**，依据是探针打印的
    //      "`rx = slot >> 1`"。🔴 **但那个依据是错的**：
    //      ⭐ `slot_val` 是**组合**信号（⭐ 跟着 `sample_now` 每帧变），
    //      而我打印的 `slot_val` 是**当时那一拍**的值，`rx` 却是**串行收了一整帧**的结果
    //      ⇒ 🔴 **两者根本不在同一时刻** ⇒ ⚠️ **那个"对比"本身不成立**。
    //   ⇒ ⭐ **撤回**：⭐ 回到"下降沿输出当前位"的原始写法。
    //   📌 **教训（⭐ 本轮最重要的一条）**：
    //      🔴 **"探针对比"必须先保证【两个量在同一时刻】才有意义** ——
    //      ⚠️ 否则会**用错误的证据去改正确的代码**（⭐ 我差点就这么干了）。
    //      ⭐ 同族：`K-129`（判据错⇒结论错）/ `C36`（探针要打在真正被证明的信号上）。
    wire [FB_W-1:0] idx_from_msb = SLOT_B[FB_W-1:0] - 1'b1 - bit_in_slot;
    wire            bit_out      = slot_val[idx_from_msb];

    //   ⭐ 在 BCK 下降沿更新 `din_r` ⇒ ⭐ DAC 在随后的上升沿采到稳定值
    reg din_r;
    always @(posedge clk) begin
        if (!rst_n_s)              din_r <= 1'b0;
        else if (bclk_tick & bclk_r) din_r <= bit_out;
    end

    assign I2S2_BCK  = bclk_r;
    assign I2S2_LRCK = lrck_w;
    assign I2S2_DIN  = din_r;

    // ═══ ⑦ 心跳 LED（⭐ 活体见证）═══════════════════════════════════════
    reg [31:0] hb_cnt;
    reg        hb_r;
    always @(posedge clk) begin
        if (!rst_n_s) begin
            hb_cnt <= 32'd0;
            hb_r   <= 1'b0;
        end else if (hb_cnt == HB_DIV[31:0] - 32'd1) begin
            hb_cnt <= 32'd0;
            hb_r   <= ~hb_r;
        end else begin
            hb_cnt <= hb_cnt + 32'd1;
        end
    end
    assign led_hb = hb_r;

    // ═══ ⑧ 参数自检 ══════════════════════════════════════════════════════
    initial begin
        if (FS_HZ <= 0)
            $display("ERROR [dac_tone_top] FS_HZ=%0d invalid", FS_HZ);
        if (FREQ_HZ >= FS_HZ / 2)
            $display("ERROR [dac_tone_top] FREQ_HZ=%0d >= Nyquist(%0d) => aliasing",
                     FREQ_HZ, FS_HZ / 2);
        $display("NOTE [dac_tone_top] FORMAT_SEL=%0d FREQ=%0d Hz fs=%0d Hz phase_inc=%0d",
                 FORMAT_SEL, FREQ_HZ, FS_HZ, PHASE_INC);
    end

endmodule

`default_nettype wire
