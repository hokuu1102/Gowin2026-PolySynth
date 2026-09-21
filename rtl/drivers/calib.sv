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
            if (raw <= zero_r[cal_ch]) begin
                err  <= 1'b1;                            // 满量程码不大于零点 -> 拒绝
                gain_r[cal_ch] <= (1 << 8);
            end else begin
                err   <= 1'b0;
                busy  <= 1'b1;
                cnt_r <= {IW{1'b0}};
                rem_r <= 24'd0;
                den_r <= raw - zero_r[cal_ch];
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r   <= 1'b0;
            ch_r  <= {CW{1'b0}};
            prod_r <= {PW{1'b0}};
        end else begin
            if (tare) zero_r[cal_ch] <= raw;
            v_r   <= valid;
            ch_r  <= ch;
            prod_r <= (raw > zero_r[ch]) ? ((raw - zero_r[ch]) * gain_r[ch]) : {PW{1'b0}};
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
        end
    end

endmodule

`default_nettype wire
