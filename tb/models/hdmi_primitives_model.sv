`timescale 1ns/1ps
// Functional boundaries for the fixed H5 50 -> 25/125 MHz PLL and DDR serializer.
// Not an analog PLL/jitter model. Physical timing is checked by Gowin STA.
module PLLA #(
    parameter FCLKIN="50", IDIV_SEL=1, FBDIV_SEL=1, MDIV_SEL=20,
    ODIV0_SEL=8, ODIV1_SEL=40,
    CLKOUT0_EN="TRUE", CLKOUT1_EN="TRUE", CLKOUT2_EN="FALSE",
    CLKOUT3_EN="FALSE", CLKOUT4_EN="FALSE", CLKOUT5_EN="FALSE",
    CLKOUT6_EN="FALSE", CLKFB_SEL="INTERNAL"
) (
    input CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input [2:0] PSSEL, input PSDIR, PSPULSE, SSCPOL, SSCON,
    input [6:0] SSCMDSEL, input [2:0] SSCMDSEL_FRAC,
    input MDCLK, input [1:0] MDOPC, input MDAINC, input [7:0] MDWDI,
    output reg LOCK, output reg CLKOUT0, CLKOUT1,
    output CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT,
    output [7:0] MDRDO
);
    initial begin LOCK=0; CLKOUT0=0; CLKOUT1=0; end
    initial if (MDIV_SEL!=20 || ODIV0_SEL!=8 || ODIV1_SEL!=40)
        $fatal(1,"HDMI PLL model supports only the verified 25/125 MHz mode");
    always #4 CLKOUT0 = (RESET || PLLPWD) ? 0 : ~CLKOUT0;
    always @(posedge CLKIN or posedge RESET) begin
        if (RESET) begin CLKOUT1<=0; LOCK<=0; end
        else begin CLKOUT1<=~CLKOUT1; LOCK<=!PLLPWD; end
    end
    assign {CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5,CLKOUT6,CLKFBOUT,MDRDO}=14'b0;
endmodule

module OSER10(input D0,D1,D2,D3,D4,D5,D6,D7,D8,D9,PCLK,FCLK,RESET,
              output reg Q);
    initial Q=0;
    reg [9:0] word_q=0;
    integer bit_index=0;
    always @(posedge PCLK) word_q <= {D9,D8,D7,D6,D5,D4,D3,D2,D1,D0};
    always @(posedge FCLK or negedge FCLK or posedge RESET) begin
        if (RESET) begin Q<=0; bit_index<=0; end
        else begin Q<=word_q[bit_index]; bit_index<=(bit_index==9)?0:bit_index+1; end
    end
endmodule

module TLVDS_OBUF(input I, output O, OB);
    assign O=I;
    assign OB=~I;
endmodule
