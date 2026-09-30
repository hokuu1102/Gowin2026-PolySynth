module hdmi_top #(
    parameter integer H_ACTIVE = 640, H_FP = 16, H_SYNC = 96, H_BP = 48,
    parameter integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP,
    parameter integer V_ACTIVE = 480, V_FP = 10, V_SYNC = 2, V_BP = 33,
    parameter integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP,
    parameter USE_252 = 0
) (
    input wire clk, rst_n,
    output wire [2:0] tmds_d_p_0, tmds_d_n_0,
    output wire tmds_clk_p_0, tmds_clk_n_0,
    output wire hpd_en,
    output wire led_hb
);
    localparam integer HB = $clog2(H_TOTAL), VB = $clog2(V_TOTAL);
    wire pixel_clk, serial_clk, lock;
    reg [1:0] reset_pipe;
    wire video_reset_n = reset_pipe[1];
    wire [HB-1:0] x;
    wire [VB-1:0] y;
    wire de, hs, vs;
    wire [7:0] r, g, b;
    wire [9:0] red, green, blue;
    assign hpd_en = 1'b1;
    hdmi_clk #(.USE_252(USE_252)) u_clk (
        .clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[0], lock};
    end
    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP), .H_TOTAL(H_TOTAL),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP), .V_TOTAL(V_TOTAL)
    ) u_timing (.clk(pixel_clk), .rst_n(video_reset_n), .x(x), .y(y),
                .de(de), .hsync(hs), .vsync(vs));
    color_bars #(.H_ACTIVE(H_ACTIVE), .X_BITS(HB)) u_bars (
        .x(x), .de(de), .r(r), .g(g), .b(b));
    tmds_encoder u_blue (.clk(pixel_clk), .rst_n(video_reset_n), .data(b),
        .de(de), .c0(hs), .c1(vs), .symbol(blue));
    tmds_encoder u_green (.clk(pixel_clk), .rst_n(video_reset_n), .data(g),
        .de(de), .c0(1'b0), .c1(1'b0), .symbol(green));
    tmds_encoder u_red (.clk(pixel_clk), .rst_n(video_reset_n), .data(r),
        .de(de), .c0(1'b0), .c1(1'b0), .symbol(red));
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!rst_n), .blue(blue), .green(green), .red(red),
        .tmds_d_p_0(tmds_d_p_0), .tmds_d_n_0(tmds_d_n_0),
        .tmds_clk_p_0(tmds_clk_p_0), .tmds_clk_n_0(tmds_clk_n_0));

    // ── Liveness witness on the Console CFG_LED green channel (V13) ─────────
    // Deliberately free-running in the 50 MHz input domain and NOT gated by
    // rst_n, so it proves "bitstream configured + 50 MHz clock alive" even if
    // the reset key is stuck. The blink rate also reports PLL lock:
    //   ~1 Hz (0.5 s on / 0.5 s off) = running AND PLL locked
    //   ~5 Hz (0.1 s on / 0.1 s off) = running but PLL NOT locked
    //   dark                          = not configured, or no 50 MHz clock
    reg [24:0] hb_cnt;
    reg        hb_slow, hb_fast;
    always @(posedge clk) begin
        hb_cnt <= (hb_cnt == 25'd24_999_999) ? 25'd0 : hb_cnt + 25'd1;
        if (hb_cnt == 25'd24_999_999) hb_slow <= ~hb_slow;
        if (hb_cnt == 25'd4_999_999)  hb_fast <= ~hb_fast;
    end
    assign led_hb = lock ? hb_slow : hb_fast;
endmodule
