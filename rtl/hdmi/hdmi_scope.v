`timescale 1ns/1ps
module hdmi_scope (
    input wire clk, rst_n,
    input wire signed [23:0] sample_i,
    input wire valid_i,
    output wire [2:0] tmds_d_p_0, tmds_d_n_0,
    output wire tmds_clk_p_0, tmds_clk_n_0, hpd_en
);
    wire pixel_clk, serial_clk, lock;
    reg [1:0] reset_pipe;
    wire video_reset_n = reset_pipe[1];
    wire [9:0] x, y;
    wire de, hs, vs, scope_de, scope_hs, scope_vs;
    wire [7:0] r, g, b;
    wire [9:0] red, green, blue;
    assign hpd_en = 1'b1;
    hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[0], lock};
    end
    video_timing u_timing (.clk(pixel_clk), .rst_n(video_reset_n),
        .x(x), .y(y), .de(de), .hsync(hs), .vsync(vs));
    waveform_scope u_scope (.sample_clk(clk), .sample_rst_n(rst_n),
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
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!rst_n), .blue(blue), .green(green), .red(red),
        .tmds_d_p_0(tmds_d_p_0), .tmds_d_n_0(tmds_d_n_0),
        .tmds_clk_p_0(tmds_clk_p_0), .tmds_clk_n_0(tmds_clk_n_0));
endmodule
