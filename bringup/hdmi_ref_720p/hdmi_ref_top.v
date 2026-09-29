// H1 minimal HDMI/DVI reference for Tang Console 60K.
//
// This is intentionally isolated from rtl/top.v.  It proves the board pins,
// the official checked-in PLL/DVI TX IP path without pulling camera or DDR
// logic into the synthesizer.  The actual PLL RTL frequencies are documented
// in README.md; they differ from the upstream SDC/IPC nominal values.

module hdmi_ref_top (
    input  wire       clk,
    input  wire       rst_n,
    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0,
    output wire       hpd_en
);

    wire serial_clk;
    wire pixel_clk;
    wire pll_lock;
    wire video_rst_n;

    wire       video_de;
    wire       video_hs;
    wire       video_vs;
    wire [7:0] video_r;
    wire [7:0] video_g;
    wire [7:0] video_b;

    // Console HDMI HPD control.  The official cam_dvi reference drives it high.
    assign hpd_en = 1'b1;
    assign video_rst_n = rst_n & pll_lock;

    // Official Sipeed/Gowin PLL RTL.  Its checked-in integer parameters build
    // as 366.667 MHz serializer and 73.333 MHz pixel clocks in Gowin 1.9.12.03.
    TMDS_PLL u_tmds_pll (
        .lock    (pll_lock),
        .clkout0 (serial_clk),
        .clkout1 (pixel_clk),
        .clkin   (clk)
    );

    // 1280x720p60 CTA timing, with the official eight-colour test pattern.
    testpattern u_testpattern (
        .I_pxl_clk  (pixel_clk),
        .I_rst_n    (video_rst_n),
        .I_mode     (3'b000),
        .I_single_r (8'hff),
        .I_single_g (8'hff),
        .I_single_b (8'hff),
        .I_h_total  (12'd1650),
        .I_h_sync   (12'd40),
        .I_h_bporch (12'd220),
        .I_h_res    (12'd1280),
        .I_v_total  (12'd750),
        .I_v_sync   (12'd5),
        .I_v_bporch (12'd20),
        .I_v_res    (12'd720),
        .I_hs_pol   (1'b1),
        .I_vs_pol   (1'b1),
        .O_de       (video_de),
        .O_hs       (video_hs),
        .O_vs       (video_vs),
        .O_data_r   (video_r),
        .O_data_g   (video_g),
        .O_data_b   (video_b)
    );

    DVI_TX_Top u_dvi_tx (
        .I_rst_n       (video_rst_n),
        .I_serial_clk  (serial_clk),
        .I_rgb_clk     (pixel_clk),
        .I_rgb_vs      (video_vs),
        .I_rgb_hs      (video_hs),
        .I_rgb_de      (video_de),
        .I_rgb_r       (video_r),
        .I_rgb_g       (video_g),
        .I_rgb_b       (video_b),
        .O_tmds_clk_p  (tmds_clk_p_0),
        .O_tmds_clk_n  (tmds_clk_n_0),
        .O_tmds_data_p (tmds_d_p_0),
        .O_tmds_data_n (tmds_d_n_0)
    );

endmodule
