`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_i2s_tx_sweep · **参数全档扫档**（`bringup/01-现有代码能验证什么.md` §三-1）
//
// ⭐ 为什么必须有它：`i2s_tx` 是**参数化**的（`JUSTIFY`/`MSB_DELAY`/`SLOT_BITS`/`DATA_BITS`/`LRCK_POL`），
//    而 `tb/w3c/tb_i2s_tx.sv` **只跑了默认档**（`JUSTIFY=1 / SLOT_BITS=32`）。
//    ⛔ "参数化的东西只验一档 = 没验"：将来为了兼容别的 DAC 顺手改一下参数就可能踩坑。
//
// ⚠️⚠️ 两个"帧长"必须分开（本 tb 第一版就栽在这里）：
//    `i2s_tx` 的**每声道时隙长度**由 `SLOT_BITS` 决定，而**一帧有多长**由 `clk_gen` 的
//    `CLK_PER_SAMPLE` 决定 —— 两者必须自洽：`CLK_PER_SAMPLE == BCLK_DIV × SLOT_BITS × 2`。
//    ⇒ `SLOT_BITS=16` 的用例必须配 **`CLK_PER_SAMPLE=512`** 的时基（32 个 BCK/帧），
//      ⛔ 不能拿 64 BCK/帧的时基去跑 16 BCK 时隙（DUT 一帧内会绕两圈，激励与解串点必然错位）。
//
// 本 tb 用**同一个仿真**跑两套时基、七套配置：
//   时基 A（1024 clk/帧 = 64 BCK，配 32 BCK 时隙）
//     (1) 默认档 LSBJ 右对齐 —— 回归，必须逐点一致
//     (2) JUSTIFY=0 / MSB_DELAY=1（Philips 左对齐）—— 必须逐点一致
//     (5) LRCK_POL=1（左右互换）—— 必须逐点一致
//     (6) DATA_BITS=8（位宽参数化）—— 必须逐点一致
//   时基 B（512 clk/帧 = 32 BCK，配 16 BCK 时隙）
//     (3) JUSTIFY=0/MSB_DELAY=0  ⟷  (4) JUSTIFY=1 —— ⭐ 交叉验证：位流必须**逐拍相同**
//     (4) 右对齐 16 BCK —— 必须逐点一致
//     (7) ⭐ 负向：JUSTIFY=0/MSB_DELAY=1/SLOT_BITS=16 —— 参数不自洽（放不下 16 位），
//         低位被静默丢弃 ⇒ 断言「**必须对不上**」，证明缺陷真实存在且判据能发现它
//
// ⚠️ 结论由本 tb 自己给（`sim/tb_all.ps1` 只认退出码 + 行首 `FAIL`）。
// ⚠️ 本文件是 UTF-8（无 BOM）：⛔ 不要用 PowerShell `Set-Content -Encoding utf8` 回写
//    （PS 5.1 会按 GBK 读进来再写成 UTF-8 ⇒ 中文注释全毁，见 `K-38`/`U46`；本文件真踩过）。
// ─────────────────────────────────────────────────────────────────────────────
module tb_i2s_tx_sweep;

    localparam integer BCLK_DIV = 16;
    localparam integer MCLK_DIV = 4;
    localparam integer SAMPLE_W = 24;
    localparam integer N_FRAMES = 64;
    localparam integer T        = 20;      // 50 MHz

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    integer errors = 0;

    integer i;
    reg signed [SAMPLE_W-1:0] sine_tbl [0:63];
    initial begin
        for (i = 0; i < 64; i = i + 1)
            sine_tbl[i] = $rtoi(0.5 * 8388607.0 * $sin(2.0 * 3.141592653589793 * i / 64.0));
    end

    // ═══ 时基 A：1024 clk/帧（64 BCK）═══
    wire ta_tick, ta_mclk, ta_bclk_en, ta_bclk_half, ta_lrclk, ta_frame;
    clk_gen #(.CLK_PER_SAMPLE(1024), .BCLK_DIV(BCLK_DIV), .MCLK_DIV(MCLK_DIV)) u_clk_a (
        .clk(clk), .rst_n(rst_n),
        .tick_audio(ta_tick), .mclk_en(ta_mclk), .bclk_en(ta_bclk_en),
        .bclk_half_en(ta_bclk_half), .lrclk(ta_lrclk), .frame_start(ta_frame));

    // ═══ 时基 B：512 clk/帧（32 BCK）═══
    wire tb_tick, tb_mclk, tb_bclk_en, tb_bclk_half, tb_lrclk, tb_frame;
    clk_gen #(.CLK_PER_SAMPLE(512), .BCLK_DIV(BCLK_DIV), .MCLK_DIV(MCLK_DIV)) u_clk_b (
        .clk(clk), .rst_n(rst_n),
        .tick_audio(tb_tick), .mclk_en(tb_mclk), .bclk_en(tb_bclk_en),
        .bclk_half_en(tb_bclk_half), .lrclk(tb_lrclk), .frame_start(tb_frame));

    // ═══ 被测 + S2 解串模型（参数逐项镜像）═══
    wire signed [SAMPLE_W-1:0] sa_l, sa_r, sb_l, sb_r;

    wire b1_bck, b1_ws, b1_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
             .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) u1 (
        .clk(clk), .rst_n(rst_n), .bclk_en(ta_bclk_en), .bclk_half_en(ta_bclk_half),
        .frame_start(ta_frame), .sample_l(sa_l), .sample_r(sa_r),
        .HP_BCK(b1_bck), .HP_WS(b1_ws), .HP_DIN(b1_din));
    wire signed [SAMPLE_W-1:0] r1_l, r1_r; wire v1_l, v1_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
                   .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) rx1 (
        .clk(clk), .rst_n(rst_n), .bck(b1_bck), .ws(b1_ws), .din(b1_din),
        .sample_l(r1_l), .sample_r(r1_r), .valid_l(v1_l), .valid_r(v1_r),
        .recon_l(), .recon_r());

    wire b2_bck, b2_ws, b2_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
             .JUSTIFY(0), .MSB_DELAY(1), .LRCK_POL(0)) u2 (
        .clk(clk), .rst_n(rst_n), .bclk_en(ta_bclk_en), .bclk_half_en(ta_bclk_half),
        .frame_start(ta_frame), .sample_l(sa_l), .sample_r(sa_r),
        .HP_BCK(b2_bck), .HP_WS(b2_ws), .HP_DIN(b2_din));
    wire signed [SAMPLE_W-1:0] r2_l, r2_r; wire v2_l, v2_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
                   .JUSTIFY(0), .MSB_DELAY(1), .LRCK_POL(0)) rx2 (
        .clk(clk), .rst_n(rst_n), .bck(b2_bck), .ws(b2_ws), .din(b2_din),
        .sample_l(r2_l), .sample_r(r2_r), .valid_l(v2_l), .valid_r(v2_r),
        .recon_l(), .recon_r());

    wire b3_bck, b3_ws, b3_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(16),
             .JUSTIFY(0), .MSB_DELAY(0), .LRCK_POL(0)) u3 (
        .clk(clk), .rst_n(rst_n), .bclk_en(tb_bclk_en), .bclk_half_en(tb_bclk_half),
        .frame_start(tb_frame), .sample_l(sb_l), .sample_r(sb_r),
        .HP_BCK(b3_bck), .HP_WS(b3_ws), .HP_DIN(b3_din));

    wire b4_bck, b4_ws, b4_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(16),
             .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) u4 (
        .clk(clk), .rst_n(rst_n), .bclk_en(tb_bclk_en), .bclk_half_en(tb_bclk_half),
        .frame_start(tb_frame), .sample_l(sb_l), .sample_r(sb_r),
        .HP_BCK(b4_bck), .HP_WS(b4_ws), .HP_DIN(b4_din));
    wire signed [SAMPLE_W-1:0] r4_l, r4_r; wire v4_l, v4_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(16),
                   .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) rx4 (
        .clk(clk), .rst_n(rst_n), .bck(b4_bck), .ws(b4_ws), .din(b4_din),
        .sample_l(r4_l), .sample_r(r4_r), .valid_l(v4_l), .valid_r(v4_r),
        .recon_l(), .recon_r());

    wire b5_bck, b5_ws, b5_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
             .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(1)) u5 (
        .clk(clk), .rst_n(rst_n), .bclk_en(ta_bclk_en), .bclk_half_en(ta_bclk_half),
        .frame_start(ta_frame), .sample_l(sa_l), .sample_r(sa_r),
        .HP_BCK(b5_bck), .HP_WS(b5_ws), .HP_DIN(b5_din));
    wire signed [SAMPLE_W-1:0] r5_l, r5_r; wire v5_l, v5_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
                   .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(1)) rx5 (
        .clk(clk), .rst_n(rst_n), .bck(b5_bck), .ws(b5_ws), .din(b5_din),
        .sample_l(r5_l), .sample_r(r5_r), .valid_l(v5_l), .valid_r(v5_r),
        .recon_l(), .recon_r());

    wire b6_bck, b6_ws, b6_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(8), .SLOT_BITS(32),
             .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) u6 (
        .clk(clk), .rst_n(rst_n), .bclk_en(ta_bclk_en), .bclk_half_en(ta_bclk_half),
        .frame_start(ta_frame), .sample_l(sa_l), .sample_r(sa_r),
        .HP_BCK(b6_bck), .HP_WS(b6_ws), .HP_DIN(b6_din));
    wire signed [SAMPLE_W-1:0] r6_l, r6_r; wire v6_l, v6_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(8), .SLOT_BITS(32),
                   .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) rx6 (
        .clk(clk), .rst_n(rst_n), .bck(b6_bck), .ws(b6_ws), .din(b6_din),
        .sample_l(r6_l), .sample_r(r6_r), .valid_l(v6_l), .valid_r(v6_r),
        .recon_l(), .recon_r());

    wire b7_bck, b7_ws, b7_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(16),
             .JUSTIFY(0), .MSB_DELAY(1), .LRCK_POL(0)) u7 (
        .clk(clk), .rst_n(rst_n), .bclk_en(tb_bclk_en), .bclk_half_en(tb_bclk_half),
        .frame_start(tb_frame), .sample_l(sb_l), .sample_r(sb_r),
        .HP_BCK(b7_bck), .HP_WS(b7_ws), .HP_DIN(b7_din));
    wire signed [SAMPLE_W-1:0] r7_l, r7_r; wire v7_l, v7_r;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(16),
                   .JUSTIFY(0), .MSB_DELAY(1), .LRCK_POL(0)) rx7 (
        .clk(clk), .rst_n(rst_n), .bck(b7_bck), .ws(b7_ws), .din(b7_din),
        .sample_l(r7_l), .sample_r(r7_r), .valid_l(v7_l), .valid_r(v7_r),
        .recon_l(), .recon_r());

    wire [31:0] a8_1, a8_4, a8_7;
    chk_xprop #(.W(1), .NAME("HP_DIN(default)"))  u_a8_1 (.clk(clk), .rst_n(rst_n), .sig(b1_din), .err_cnt(a8_1));
    chk_xprop #(.W(1), .NAME("HP_DIN(16BCK)"))    u_a8_4 (.clk(clk), .rst_n(rst_n), .sig(b4_din), .err_cnt(a8_4));
    chk_xprop #(.W(1), .NAME("HP_DIN(badparam)")) u_a8_7 (.clk(clk), .rst_n(rst_n), .sig(b7_din), .err_cnt(a8_7));

    // ═══ 激励 ═══
    reg signed [SAMPLE_W-1:0] sa_l_r, sa_r_r, sb_l_r, sb_r_r;
    reg signed [SAMPLE_W-1:0] expa_l [0:N_FRAMES+2];
    reg signed [SAMPLE_W-1:0] expa_r [0:N_FRAMES+2];
    reg signed [SAMPLE_W-1:0] expb_l [0:N_FRAMES+2];
    reg signed [SAMPLE_W-1:0] expb_r [0:N_FRAMES+2];
    integer na, nb;

    assign sa_l = sa_l_r; assign sa_r = sa_r_r;
    assign sb_l = sb_l_r; assign sb_r = sb_r_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            na <= 0; sa_l_r <= sine_tbl[0]; sa_r_r <= sine_tbl[16];
            expa_l[0] <= sine_tbl[0]; expa_r[0] <= sine_tbl[16];
        end else if (ta_tick === 1'b1) begin
            na <= na + 1;
            sa_l_r <= sine_tbl[(na + 1) & 6'h3f];
            sa_r_r <= sine_tbl[((na + 1) + 16) & 6'h3f];
            expa_l[na + 1] <= sine_tbl[(na + 1) & 6'h3f];
            expa_r[na + 1] <= sine_tbl[((na + 1) + 16) & 6'h3f];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            nb <= 0; sb_l_r <= sine_tbl[0]; sb_r_r <= sine_tbl[16];
            expb_l[0] <= sine_tbl[0]; expb_r[0] <= sine_tbl[16];
        end else if (tb_tick === 1'b1) begin
            nb <= nb + 1;
            sb_l_r <= sine_tbl[(nb + 1) & 6'h3f];
            sb_r_r <= sine_tbl[((nb + 1) + 16) & 6'h3f];
            expb_l[nb + 1] <= sine_tbl[(nb + 1) & 6'h3f];
            expb_r[nb + 1] <= sine_tbl[((nb + 1) + 16) & 6'h3f];
        end
    end

    // ═══ ⭐ R-14：极端样点的截断行为（新增，2026-09-17）═══
    //   `i2s_tx` 把 24 bit 样点**直接取高 16 位**（无舍入）。这有两个后果要**显式验**：
    //     ① **不会溢出/削顶**：`0x7FFFFF` → `0x7FFF`、`0x800000` → `0x8000`（都在 16 bit 范围内）
    //     ② ⚠️ 有 **−0.5 LSB(16bit) 的系统性直流偏置**（≈ −15 ppm）：
    //        `floor(x/256)` 的平均误差 = −128（24 bit 单位）。⭐ 这不是 bug，是**取舍**：
    //        DAC/功放是交流耦合 ⇒ 实际可忽略；但**必须验过**而不是"应该没事"。
    //   本段用一个"专用实例"跑 4 个极端样点，检查解串回来的高 16 位与期望**位型完全一致**。
    reg signed [SAMPLE_W-1:0] ext_smp;
    wire ext_bck, ext_ws, ext_din;
    i2s_tx #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
             .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) u_ext (
        .clk(clk), .rst_n(rst_n), .bclk_en(ta_bclk_en), .bclk_half_en(ta_bclk_half),
        .frame_start(ta_frame), .sample_l(ext_smp), .sample_r(ext_smp),
        .HP_BCK(ext_bck), .HP_WS(ext_ws), .HP_DIN(ext_din));
    wire signed [SAMPLE_W-1:0] ext_rx; wire ext_v;
    i2s_rx_model #(.SAMPLE_W(SAMPLE_W), .DATA_BITS(16), .SLOT_BITS(32),
                   .JUSTIFY(1), .MSB_DELAY(1), .LRCK_POL(0)) rx_ext (
        .clk(clk), .rst_n(rst_n), .bck(ext_bck), .ws(ext_ws), .din(ext_din),
        .sample_l(ext_rx), .sample_r(), .valid_l(ext_v), .valid_r(),
        .recon_l(), .recon_r());

    integer ext_i, ext_ok, ext_bad;
    reg signed [SAMPLE_W-1:0] ext_vec [0:3];
    reg signed [SAMPLE_W-1:0] ext_lat;      // ⭐ 在 `frame_start` 锁存"本帧真正被装载的值"
    reg signed [SAMPLE_W-1:0] ext_exp_now;  // 期望 = 取高 16 位（低 8 位清零）
    integer ext_frames;

    initial begin
        ext_vec[0] = 24'sh7FFFFF;   // 最大正
        ext_vec[1] = 24'sh800000;   // 最小负（−满量程）
        ext_vec[2] = 24'sh000000;   // 零
        ext_vec[3] = 24'shFFFFFF;   // −1（全 1）
        ext_smp = ext_vec[0];
        ext_lat = ext_vec[0];
        ext_exp_now = 24'sh7FFF00;
        ext_i = 0; ext_ok = 0; ext_bad = 0; ext_frames = 0;
    end

    // ⚠️ 2026-09-17 修正（本段第一版踩了 L54/L57 记过的坑）：
    //    原来我按"第几个 tick"去索引期望值，结果 `got` 恰好等于**上一个**期望值
    //    ⇒ **差一帧**。原因是"我换激励的时刻"与"接收方报告样点的时刻"不是同一个点。
    //    ✅ 正确做法：**在 `frame_start`（DUT 的装载点）锁存当前驱动值**，
    //       然后用它算期望 —— 这样激励与期望天然同源，不依赖任何帧计数。
    //    另外：复位后**第一个**时隙是未填满的（`ext#0` 曾读到 0x3fff00 = 半值伪影），
    //    所以前 2 个 valid 不判（与 `L57` 的 warm-up 同理）。
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            ext_frames = 0; ext_i = 0;
            ext_smp <= ext_vec[0];
            ext_lat <= ext_vec[0];
        end else if (ta_frame === 1'b1) begin
            // ⭐ 先锁存"本帧要发出去的值"，再决定下一帧换成哪个极端值
            ext_lat     <= ext_smp;
            ext_exp_now <= {ext_smp[SAMPLE_W-1 -: 16], 8'b0};   // 取高 16 位（低 8 位丢）
            ext_frames  = ext_frames + 1;
            if (ext_frames % 8 == 0 && ext_i < 3) begin
                ext_i   = ext_i + 1;
                ext_smp <= ext_vec[ext_i];
            end
        end
    end

    // 解串出的样点必须与"锁存值取高 16 位"**位型完全一致**
    integer ext_valid_seen;
    initial ext_valid_seen = 0;
    always @(posedge clk) begin
        if (rst_n === 1'b1 && ext_v === 1'b1) begin
            ext_valid_seen = ext_valid_seen + 1;
            if (ext_valid_seen > 2) begin      // warm-up：跳过前 2 个（复位后未填满的时隙）
                if ((ext_rx & hi_mask(16)) === (ext_exp_now & hi_mask(16))) ext_ok = ext_ok + 1;
                else begin
                    ext_bad = ext_bad + 1;
                    if (ext_bad <= 4)
                        $display("  [x] R-14 got 0x%06h exp 0x%06h (driven 0x%06h)", ext_rx, ext_exp_now, ext_lat);
                end
            end
        end
    end

    // ═══ 逐点比对 ═══
    // ⚠️ 掩码：要的是**高 dbits 位** ⇒ `全1 << (SAMPLE_W - dbits)`
    //    （⛔ 写成 `~（全1 << (SAMPLE_W-dbits))` 就变成低 dbits 位了 —— 本 tb 第一版错在这）
    // ⚠️ 不用 `[SAMPLE_W-1 -: dbits]`：iverilog 不允许**变量宽度**的部分选择。
    function [SAMPLE_W-1:0] hi_mask;
        input integer dbits;
        begin
            hi_mask = ({SAMPLE_W{1'b1}} << (SAMPLE_W - dbits));
        end
    endfunction

    integer ok1, bad1, ok2, bad2, ok4, bad4, ok5, bad5, ok6, bad6, ok7, bad7;
    integer cnt_l1, cnt_r1, cnt_l2, cnt_r2, cnt_l4, cnt_r4;
    integer cnt_l5, cnt_r5, cnt_l6, cnt_r6, cnt_l7, cnt_r7;
    integer eq_same, eq_diff;

    task automatic cmp;
        input integer which;
        input signed [SAMPLE_W-1:0] got;
        input signed [SAMPLE_W-1:0] exp;
        input integer dbits;
        reg [SAMPLE_W-1:0] m;
        begin
            m = hi_mask(dbits);
            if ((got & m) === (exp & m)) begin
                case (which)
                    1: ok1 = ok1 + 1;  2: ok2 = ok2 + 1;  4: ok4 = ok4 + 1;
                    5: ok5 = ok5 + 1;  6: ok6 = ok6 + 1;  7: ok7 = ok7 + 1;
                endcase
            end else begin
                case (which)
                    1: begin bad1 = bad1 + 1; if (bad1 <= 3) $display("  [x] (1) #%0d got 0x%06h exp 0x%06h", ok1+bad1-1, got, exp); end
                    2: begin bad2 = bad2 + 1; if (bad2 <= 3) $display("  [x] (2) #%0d got 0x%06h exp 0x%06h", ok2+bad2-1, got, exp); end
                    4: begin bad4 = bad4 + 1; if (bad4 <= 3) $display("  [x] (4) #%0d got 0x%06h exp 0x%06h", ok4+bad4-1, got, exp); end
                    5: begin bad5 = bad5 + 1; if (bad5 <= 3) $display("  [x] (5) #%0d got 0x%06h exp 0x%06h", ok5+bad5-1, got, exp); end
                    6: begin bad6 = bad6 + 1; if (bad6 <= 3) $display("  [x] (6) #%0d got 0x%06h exp 0x%06h", ok6+bad6-1, got, exp); end
                    7: begin bad7 = bad7 + 1; if (bad7 <= 3) $display("  [x] (7) #%0d got 0x%06h exp 0x%06h", ok7+bad7-1, got, exp); end
                endcase
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (b3_din === b4_din) eq_same = eq_same + 1;
            else                   eq_diff = eq_diff + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (v1_l) begin cnt_l1 = cnt_l1 + 1; if (cnt_l1 <= N_FRAMES) cmp(1, r1_l, expa_l[cnt_l1-1], 16); end
            if (v1_r) begin cnt_r1 = cnt_r1 + 1; if (cnt_r1 <= N_FRAMES) cmp(1, r1_r, expa_r[cnt_r1-1], 16); end
            if (v2_l) begin cnt_l2 = cnt_l2 + 1; if (cnt_l2 <= N_FRAMES) cmp(2, r2_l, expa_l[cnt_l2-1], 16); end
            if (v2_r) begin cnt_r2 = cnt_r2 + 1; if (cnt_r2 <= N_FRAMES) cmp(2, r2_r, expa_r[cnt_r2-1], 16); end
            if (v5_l) begin cnt_l5 = cnt_l5 + 1; if (cnt_l5 <= N_FRAMES) cmp(5, r5_l, expa_l[cnt_l5-1], 16); end
            if (v5_r) begin cnt_r5 = cnt_r5 + 1; if (cnt_r5 <= N_FRAMES) cmp(5, r5_r, expa_r[cnt_r5-1], 16); end
            if (v6_l) begin cnt_l6 = cnt_l6 + 1; if (cnt_l6 <= N_FRAMES) cmp(6, r6_l, expa_l[cnt_l6-1],  8); end
            if (v6_r) begin cnt_r6 = cnt_r6 + 1; if (cnt_r6 <= N_FRAMES) cmp(6, r6_r, expa_r[cnt_r6-1],  8); end
            if (v4_l) begin cnt_l4 = cnt_l4 + 1; if (cnt_l4 <= N_FRAMES) cmp(4, r4_l, expb_l[cnt_l4-1], 16); end
            if (v4_r) begin cnt_r4 = cnt_r4 + 1; if (cnt_r4 <= N_FRAMES) cmp(4, r4_r, expb_r[cnt_r4-1], 16); end
            if (v7_l) begin cnt_l7 = cnt_l7 + 1; if (cnt_l7 <= N_FRAMES) cmp(7, r7_l, expb_l[cnt_l7-1], 16); end
            if (v7_r) begin cnt_r7 = cnt_r7 + 1; if (cnt_r7 <= N_FRAMES) cmp(7, r7_r, expb_r[cnt_r7-1], 16); end
        end
    end

    wire p1 = u1.PARAM_OK, p2 = u2.PARAM_OK, p3 = u3.PARAM_OK, p4 = u4.PARAM_OK;
    wire p5 = u5.PARAM_OK, p6 = u6.PARAM_OK, p7 = u7.PARAM_OK;

    initial begin
        $dumpfile("build/sim/tb_i2s_tx_sweep/tb_i2s_tx_sweep.vcd");
        $dumpvars(0, tb_i2s_tx_sweep);

        ok1=0; bad1=0; ok2=0; bad2=0; ok4=0; bad4=0; ok5=0; bad5=0; ok6=0; bad6=0; ok7=0; bad7=0;
        cnt_l1=0; cnt_r1=0; cnt_l2=0; cnt_r2=0; cnt_l4=0; cnt_r4=0;
        cnt_l5=0; cnt_r5=0; cnt_l6=0; cnt_r6=0; cnt_l7=0; cnt_r7=0;
        eq_same=0; eq_diff=0;

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (1024 * (N_FRAMES + 4)) @(posedge clk);
        #1;

        $display("");
        $display("================ i2s_tx parameter sweep ================");
        $display("  clk A = 1024 clk/frame (64 BCK) | clk B = 512 clk/frame (32 BCK)");
        $display("  (1) default LSBJ right, 32BCK : ok %0d / bad %0d", ok1, bad1);
        $display("  (2) left-align MSB_DELAY=1    : ok %0d / bad %0d", ok2, bad2);
        $display("  (3)<->(4) left(D=0) vs right, 16BCK : same %0d / diff %0d clk", eq_same, eq_diff);
        $display("  (4) right-align 16BCK         : ok %0d / bad %0d", ok4, bad4);
        $display("  (5) LRCK_POL=1 (L/R swapped)  : ok %0d / bad %0d", ok5, bad5);
        $display("  (6) DATA_BITS=8               : ok %0d / bad %0d", ok6, bad6);
        $display("  (7) NEGATIVE bad param combo  : ok %0d / bad %0d  <- MUST FAIL", ok7, bad7);
        $display("  PARAM_OK self-check           : (1)-(6) = %b%b%b%b%b%b | (7) = %b (must be 0)",
                 p1, p2, p3, p4, p5, p6, p7);
        $display("  A8 (HP_DIN X/Z)               : default %0d | 16BCK %0d | bad %0d", a8_1, a8_4, a8_7);
        $display("=======================================================");

        if (bad1 == 0 && ok1 >= 2*(N_FRAMES-1)) $display("  ok : (1) default LSBJ right-align point-by-point match (regression intact)");
        else begin $display("FAIL: (1) default config mismatch (ok %0d bad %0d)", ok1, bad1); errors = errors + 1; end

        if (bad2 == 0 && ok2 >= 2*(N_FRAMES-1)) $display("  ok : (2) left-align Philips (MSB_DELAY=1, 32BCK) point-by-point match");
        else begin $display("FAIL: (2) left-align mismatch (ok %0d bad %0d)", ok2, bad2); errors = errors + 1; end

        // ⚠️ 阈值说明：整个仿真只有 `1024*(N_FRAMES+4)` = 69632 个 clk，
        //    所以"相同拍数"的上限就是 69632（⛔ 不要写一个比它更大的数 —— 那是判据笔误，
        //    第一版写成 >100000 导致永远 FAIL）。
        if (eq_diff == 0 && eq_same >= 60000) $display("  ok : (3)<->(4) left(D=0) and right align produce IDENTICAL bitstream (%0d clk)", eq_same);
        else begin $display("FAIL: (3)<->(4) the two justifications differ in %0d clk (same=%0d)", eq_diff, eq_same); errors = errors + 1; end

        if (bad4 == 0 && ok4 >= 2*(N_FRAMES-1)) $display("  ok : (4) right-align 16BCK slot point-by-point match (SLOT_BITS parameter works)");
        else begin $display("FAIL: (4) right-align 16BCK mismatch (ok %0d bad %0d)", ok4, bad4); errors = errors + 1; end

        if (bad5 == 0 && ok5 >= 2*(N_FRAMES-1)) $display("  ok : (5) LRCK_POL=1 point-by-point match with mirrored model");
        else begin $display("FAIL: (5) LRCK_POL=1 mismatch (ok %0d bad %0d)", ok5, bad5); errors = errors + 1; end

        if (bad6 == 0 && ok6 >= 2*(N_FRAMES-1)) $display("  ok : (6) DATA_BITS=8 point-by-point match (width param works)");
        else begin $display("FAIL: (6) DATA_BITS=8 mismatch (ok %0d bad %0d)", ok6, bad6); errors = errors + 1; end

        if (bad7 > 0 && p7 === 1'b0) $display("  ok : (7) NEGATIVE case holds: PARAM_OK flags it AND the compare really fails");
        else begin $display("FAIL: (7) negative case does not hold (bad %0d, PARAM_OK=%b)", bad7, p7); errors = errors + 1; end

        if (p1 && p2 && p3 && p4 && p5 && p6) $display("  ok : (1)-(6) parameter self-check all pass");
        else begin $display("FAIL: some of (1)-(6) flagged as inconsistent (%b%b%b%b%b%b)", p1, p2, p3, p4, p5, p6); errors = errors + 1; end

        if (a8_1 == 0 && a8_4 == 0 && a8_7 == 0) $display("  ok : A8 no X/Z on all three HP_DIN nets");
        else begin $display("FAIL: A8 detected X/Z (default %0d | 16BCK %0d | bad %0d)", a8_1, a8_4, a8_7); errors = errors + 1; end

        // ⭐ R-14：极端样点的截断行为
        $display("  R-14 extreme samples (0x7FFFFF / 0x800000 / 0 / 0xFFFFFF): ok %0d / bad %0d", ext_ok, ext_bad);
        if (ext_bad == 0 && ext_ok >= 4)
            $display("  ok : R-14 极端样点截断正确（取高 16 位、不溢出；−0.5LSB 直流偏置为已知取舍）");
        else begin
            $display("FAIL: R-14 极端样点截断异常（ok %0d bad %0d）", ext_ok, ext_bad);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: i2s_tx works in every parameter mode (incl. 16BCK equivalence and the inconsistent-parameter negative proof)");
        else             $fatal(1, "FAIL: i2s_tx sweep has %0d unexpected result(s)", errors);

        #100;
        $finish;
    end

endmodule
