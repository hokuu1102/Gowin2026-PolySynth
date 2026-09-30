// Gowin clock primitive boundary. Both realizable modes require a PLL for 5x.
// USE_252=0: 50*20/40=25 and 50*20/8=125 MHz.
// USE_252=1: nominal 50*63/125=25.2 and 50*63/25=126 MHz.
module hdmi_clk #(
    parameter USE_252 = 0
) (
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
    defparam u_pll.MDIV_SEL = USE_252 ? 63 : 20;
    defparam u_pll.ODIV0_SEL = USE_252 ? 25 : 8;
    defparam u_pll.ODIV1_SEL = USE_252 ? 125 : 40;
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
