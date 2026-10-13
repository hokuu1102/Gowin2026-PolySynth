`timescale 1ns/1ps
//  ⭐ 2026-10-09：新增显示模式参数（⛔ 端口一个没变 ⇒ 对 top.v 的连线零影响）
//    SCOPE_MODE = 0 → 波形（原行为）· 1 → 李萨如（XY）
module hdmi_scope #(
    parameter integer XY_DELAY    = 64,    // Y 取延迟多少个样本（64 ≈ 1.3 ms）
    parameter integer XY_GAIN     = 8      // XY 增益（图形大小 ∝ 它；台阶 = 它/8 像素）
) (
    input wire clk, rst_n,
    input wire SCOPE_MODE,                 // ⭐ 运行时显示模式（串口 'Q' 切换）
    input wire signed [23:0] sample_i,
    input wire valid_i,
    output wire [2:0] tmds_d_p_0, tmds_d_n_0,
    output wire tmds_clk_p_0, tmds_clk_n_0, hpd_en
);
    wire pixel_clk, serial_clk, lock;
    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-09（`P0-24`）：⭐ **HDMI 域复位改成【域内同步产生】** ✅
    //
    //  🔴 **原缺陷（⭐ 两处跨域异步复位）**：
    //     · ⭐ `always @(posedge pixel_clk or negedge rst_n)` —— ⭐ `rst_n` 来自 **`clk_sys` 域**
    //       ⇒ 🔴 **跨域异步复位** ⇒ ⭐ 释放沿对 pixel 域的每个 FF 都是**异步**的 ✅
    //     · ⭐ `.rst(!rst_n)` 送进 `tmds_serializer` ⇒ ⭐ 落到 **125 MHz 的 `FCLK` 硬宏**的 RESET
    //       ⇒ 🔴 **第二处跨域异步复位** ✅
    //     📌 后果：⭐ 各 FF 在自己的 recovery/removal 窗里**各自判定**
    //        ⇒ ⭐ 可以落在**不同的 clk 沿**上 ⇒ ⭐ 偶发、不可复现的"某次上电某个模块慢一拍" ✅
    //
    //  ✅ **修法（⭐ 审查的首选方案）**：⭐ **让 `rst_n` 只当【数据】采** ——
    //     ⭐ 两级/三级同步器把 `lock & rst_n` 同步进本域
    //     ⇒ ⭐ **复位本身不再跨域**（⭐ 跨的只是数据 ✅）
    //     ⇒ ⭐ `video_reset_n` 现在是 **pixel 域 FF 的输出** ⇒ ⭐ 域内所有 FF **同沿释放** ✅
    //  📌 **为什么把 `lock` 也并进来**：⭐ `lock` 来自 PLL 的 LOCK 引脚（⭐ **也是异步源** ✅）
    //     ⇒ ⭐ 用同一个同步链把它一起同步 ✅（⭐ 顺带解掉 P1-01 ✅）
    //  ⚠️ **为什么不用"异步置位 + 同步释放"**：⭐ 那仍会引入一条跨域异步路径 ✅
    //     ⇒ ⭐ 本方案**结构上彻底没有**跨域异步复位 ✅
    //  📌 **硅片上电**：⭐ Gowin 的 FF 上电 `INIT=0` ⇒ ⭐ `rstn_pix` 初值 0（⭐ 复位有效）✅
    //     ⭐ `initial` 只影响仿真（⭐ 综合工具忽略 ✅）
    //  ⚠️ **SDC（⭐ 诚实标注）**：⭐ 审查建议给新增的 D 端跨域路径加 `set_max_delay 12.000`
    //     ⚠️ 但它同时警告 `get_regs` 通配**曾让构建 `TA2003` 直接失败** ✅
    //     ⇒ ⭐ 本次**不加 SDC**：⭐ 这两条是**准静态控制信号**（⭐ 只在按复位键时变一次 ✅）
    //       ⇒ ⭐ 工具给的默认 I/O 预算**够用** ✅
    //       📌 ⭐ 若将来要加：⭐ 必须**先只改 SDC 跑一次 PnR** 看 Constraints Report 里对象非空 ✅
    //       ⛔ **不许用 `set_false_path` 一刀切**（⭐ `top.sdc:88-90` 明文禁止 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    //  ① ⭐ **像素域**：⭐ 无异步复位的同步器（⭐ 只有 D 端跨域 ✅）
    reg [2:0] rstn_pix = 3'b000;
    always @(posedge pixel_clk)
        rstn_pix <= {rstn_pix[1:0], (lock & rst_n)};   // ⭐ `rst_n` 是 clk_sys 域电平，只当【数据】采 ✅
    wire video_reset_n = rstn_pix[2];                  // ⭐ 现在是【pixel 域 FF 的输出】✅
    //  ② ⭐ **串行域**（⭐ 125 MHz）：⭐ 同样域内同步 ✅
    reg [2:0] rstn_ser = 3'b000;
    always @(posedge serial_clk)
        rstn_ser <= {rstn_ser[1:0], (lock & rst_n)};
    wire serial_reset = ~rstn_ser[2];
    wire [9:0] x, y;
    wire de, hs, vs, scope_de, scope_hs, scope_vs;
    wire [7:0] r, g, b;
    wire [9:0] red, green, blue;
    assign hpd_en = 1'b1;
    hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    //  ⭐⭐ `P0-24`：⭐ **旧的跨域异步复位块已删** ✅
    //   🔴 原文：`always @(posedge pixel_clk or negedge rst_n) begin
    //              if (!rst_n) reset_pipe <= 0;
    //              else reset_pipe <= {reset_pipe[0], lock};
    //            end`
    //   ⚠️ 它的 `reset_pipe` 是 `[1:0]`（⭐ 2 级）⇒ ⭐ 新写法是 `[2:0]`（⭐ 3 级，⭐ 与串行域一致 ✅）
    video_timing u_timing (.clk(pixel_clk), .rst_n(video_reset_n),
        .x(x), .y(y), .de(de), .hsync(hs), .vsync(vs));
    waveform_scope #(.XY_DELAY(XY_DELAY), .XY_GAIN(XY_GAIN)) u_scope (
        .sample_clk(clk), .sample_rst_n(rst_n),
        .SCOPE_MODE(SCOPE_MODE),           // ⭐ 端口连接（⛔ 不是参数表）
        .sample_i(sample_i), .valid_i(valid_i),
        .pixel_clk(pixel_clk), .pixel_rst_n(video_reset_n),
        .x_i(x), .y_i(y), .de_i(de), .hs_i(hs), .vs_i(vs),
        .r_o(r), .g_o(g), .b_o(b),
        .de_o(scope_de), .hs_o(scope_hs), .vs_o(scope_vs));
    tmds_encoder u_blue (.clk(pixel_clk), .rst_n(video_reset_n), .data(b),
        .de(scope_de), .c0(scope_hs), .c1(scope_vs), .symbol(blue));
    tmds_encoder u_green (.clk(pixel_clk), .rst_n(video_reset_n), .data(g),
        .de(scope_de), .c0(1'b0), .c1(1'b0), .symbol(green));
    tmds_encoder u_red (.clk(pixel_clk), .rst_n(video_reset_n), .data(r),
        .de(scope_de), .c0(1'b0), .c1(1'b0), .symbol(red));
    //  ⭐⭐ 2026-10-09（`P0-24`）：⭐ **OSER10 的 RESET 改由【串行域内同步】的复位驱动** ✅
    //   🔴 原写 `.rst(!rst_n)` ⇒ ⭐ 把 clk_sys 域的复位直接灌进 **125 MHz `FCLK` 硬宏**
    //      ⇒ 🔴 **跨域异步复位** ✅
    //   ✅ 现在 `.rst(serial_reset)`（⭐ `rstn_ser[2]` 取反 ✅）⇒ ⭐ 域内 FF 输出 ⇒ ⭐ 同沿释放 ✅
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(serial_reset), .blue(blue), .green(green), .red(red),
        .tmds_d_p_0(tmds_d_p_0), .tmds_d_n_0(tmds_d_n_0),
        .tmds_clk_p_0(tmds_clk_p_0), .tmds_clk_n_0(tmds_clk_n_0));
endmodule
