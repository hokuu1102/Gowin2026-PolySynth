// H4 clock: 50*(15+3/8)=768.75 MHz serial and 153.75 MHz pixel.
module hdmi_clk_h4 (
    input wire clk,
    input wire rst_n,
    output wire pixel_clk,
    output wire serial_clk,
    output wire lock
);
    wire pll_lock;
    wire [6:2] unused_clk;
    wire unused_clk6, unused_fb;
    wire [7:0] unused_dr;
    PLLA u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
        .RESET_I(1'b0), .RESET_O(1'b0),
        .PSSEL(3'b0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0), .MDCLK(1'b0), .MDOPC(2'b0),
        .MDAINC(1'b0), .MDWDI(8'b0),
        .LOCK(pll_lock), .CLKOUT0(serial_clk), .CLKOUT1(pixel_clk),
        .CLKOUT2(unused_clk[2]), .CLKOUT3(unused_clk[3]),
        .CLKOUT4(unused_clk[4]), .CLKOUT5(unused_clk[5]),
        .CLKOUT6(unused_clk6), .CLKFBOUT(unused_fb), .MDRDO(unused_dr)
    );
    defparam u_pll.FCLKIN = "50";
    defparam u_pll.IDIV_SEL = 1;
    defparam u_pll.FBDIV_SEL = 1;
    defparam u_pll.MDIV_SEL = 15;
    defparam u_pll.MDIV_FRAC_SEL = 3;
    defparam u_pll.ODIV0_SEL = 1;
    defparam u_pll.ODIV1_SEL = 5;
    defparam u_pll.CLKOUT0_EN = "TRUE";
    defparam u_pll.CLKOUT1_EN = "TRUE";
    defparam u_pll.CLKOUT2_EN = "FALSE";
    defparam u_pll.CLKOUT3_EN = "FALSE";
    defparam u_pll.CLKOUT4_EN = "FALSE";
    defparam u_pll.CLKOUT5_EN = "FALSE";
    defparam u_pll.CLKOUT6_EN = "FALSE";
    defparam u_pll.CLKFB_SEL = "INTERNAL";
    assign lock = pll_lock;
endmodule
