`timescale 1ns/1ps
//  ⭐ 2026-10-09：新增显示模式参数（⛔ 端口一个没变 ⇒ 对 top.v 的连线零影响）
//    SCOPE_MODE = 0 → 波形（原行为）· 1 → 李萨如（XY）
module hdmi_scope #(
    parameter integer XY_DELAY    = 64,    // Y 取延迟多少个样本（64 ≈ 1.3 ms）
    parameter integer XY_GAIN     = 8,
    parameter integer FFT_ENABLE = 0
) (
    input wire clk, rst_n,
    input wire SCOPE_MODE,                 // ⭐ 运行时显示模式（串口 'Q' 切换）
    input wire FFT_MODE,
    input wire [5:0] TEST_N,
    input wire signed [23:0] sample_i,
    input wire valid_i,
    output wire [2:0] tmds_d_p_0, tmds_d_n_0,
    output wire tmds_clk_p_0, tmds_clk_n_0, hpd_en
);
    wire pixel_clk, serial_clk, lock;
    // Synchronize lock/reset into the parallel word clock. OSER reset is
    // released at a word boundary; all FCLK/PCLK recovery/removal checks remain.
    reg [2:0] rstn_pix = 3'b000;
    always @(posedge pixel_clk)
        rstn_pix <= {rstn_pix[1:0], (lock & rst_n)};   // ⭐ `rst_n` 是 clk_sys 域电平，只当【数据】采 ✅
    wire video_reset_n = rstn_pix[2];
    wire serial_reset = ~video_reset_n;
    wire [9:0] x, y;
    wire de, hs, vs, scope_de, scope_hs, scope_vs;
    wire [7:0] r, g, b,wave_r,wave_g,wave_b;
    wire wave_de,wave_hs,wave_vs;
    wire [9:0] red, green, blue;
    assign hpd_en = 1'b1;
    hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    // All pixel logic observes the synchronized word-clock reset.
    video_timing u_timing (.clk(pixel_clk), .rst_n(video_reset_n),
        .x(x), .y(y), .de(de), .hsync(hs), .vsync(vs));
    waveform_scope #(.XY_DELAY(XY_DELAY), .XY_GAIN(XY_GAIN)) u_scope (
        .sample_clk(clk), .sample_rst_n(rst_n),
        .SCOPE_MODE(SCOPE_MODE),           // ⭐ 端口连接（⛔ 不是参数表）
        .sample_i(sample_i), .valid_i(valid_i),
        .pixel_clk(pixel_clk), .pixel_rst_n(video_reset_n),
        .x_i(x), .y_i(y), .de_i(de), .hs_i(hs), .vs_i(vs),
        .r_o(wave_r), .g_o(wave_g), .b_o(wave_b),
        .de_o(wave_de), .hs_o(wave_hs), .vs_o(wave_vs));
    generate if(FFT_ENABLE)begin:g_fft
        wire [7:0] fft_r,fft_g,fft_b;
        wire fft_de,fft_hs,fft_vs;
        (* syn_preserve=1 *) reg select_launch;
        reg select_meta,select_sync,select_pixel;
        always @(negedge clk)begin
            if(!rst_n)select_launch<=0;else select_launch<=FFT_MODE;
        end
        always @(posedge pixel_clk)begin
            if(!video_reset_n)begin select_meta<=0;select_sync<=0;select_pixel<=0;end
            else begin
                select_meta<=select_launch;select_sync<=select_meta;
                if(x==0 && y==480)select_pixel<=select_sync;
            end
        end
        fft_spectrum_view u_fft(.sample_clk_i(clk),.sample_rst_n_i(rst_n),
            .sample_i(sample_i),.sample_valid_i(valid_i),.test_n_i(TEST_N),
            .pixel_clk_i(pixel_clk),.pixel_rst_n_i(video_reset_n),
            .x_i(x),.y_i(y),.de_i(de),.hs_i(hs),.vs_i(vs),
            .r_o(fft_r),.g_o(fft_g),.b_o(fft_b),.de_o(fft_de),.hs_o(fft_hs),.vs_o(fft_vs));
        assign r=select_pixel?fft_r:wave_r;
        assign g=select_pixel?fft_g:wave_g;
        assign b=select_pixel?fft_b:wave_b;
        assign scope_de=select_pixel?fft_de:wave_de;
        assign scope_hs=select_pixel?fft_hs:wave_hs;
        assign scope_vs=select_pixel?fft_vs:wave_vs;
    end else begin:g_no_fft
        assign r=wave_r;assign g=wave_g;assign b=wave_b;
        assign scope_de=wave_de;assign scope_hs=wave_hs;assign scope_vs=wave_vs;
    end endgenerate
    tmds_encoder u_blue (.clk(pixel_clk), .rst_n(video_reset_n), .data(b),
        .de(scope_de), .c0(scope_hs), .c1(scope_vs), .symbol(blue));
    tmds_encoder u_green (.clk(pixel_clk), .rst_n(video_reset_n), .data(g),
        .de(scope_de), .c0(1'b0), .c1(1'b0), .symbol(green));
    tmds_encoder u_red (.clk(pixel_clk), .rst_n(video_reset_n), .data(r),
        .de(scope_de), .c0(1'b0), .c1(1'b0), .symbol(red));
    // The serializer adds a dedicated, physically local PCLK reset register.
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(serial_reset), .blue(blue), .green(green), .red(red),
        .tmds_d_p_0(tmds_d_p_0), .tmds_d_n_0(tmds_d_n_0),
        .tmds_clk_p_0(tmds_clk_p_0), .tmds_clk_n_0(tmds_clk_n_0));
endmodule
