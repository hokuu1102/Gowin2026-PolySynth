// Gowin primitive boundary: bit zero is transmitted first.
//
// Output buffers are ELVDS_OBUF (emulated 3.3 V differential), which pairs with
// IO_TYPE=LVCMOS33D in the constraint - the combination nand2mario/tangcore
// uses on Tang Console. TLVDS_OBUF would force LVDS25 (1.2 V common mode),
// which does not match a TMDS sink terminated into 50 ohm to 3.3 V.
// OSER10's Q must drive an I/O buffer directly (CK0021: it cannot drive a LUT).
module tmds_serializer (
    input wire pixel_clk,
    input wire serial_clk,
    input wire rst,
    input wire [9:0] blue,
    input wire [9:0] green,
    input wire [9:0] red,
    output wire [2:0] tmds_d_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire tmds_clk_p_0,
    output wire tmds_clk_n_0
);
    wire [3:0] serial;
    wire [9:0] lane [0:3];
    assign lane[0] = blue;
    assign lane[1] = green;
    assign lane[2] = red;
    assign lane[3] = 10'b0000011111;
    genvar j;
    generate for (j=0; j<4; j=j+1) begin : lanes
        OSER10 u_oser (
            .Q(serial[j]), .D0(lane[j][0]), .D1(lane[j][1]),
            .D2(lane[j][2]), .D3(lane[j][3]), .D4(lane[j][4]),
            .D5(lane[j][5]), .D6(lane[j][6]), .D7(lane[j][7]),
            .D8(lane[j][8]), .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst)
        );
        if (j < 3) begin : data_pair
            ELVDS_OBUF u_diff (.I(serial[j]), .O(tmds_d_p_0[j]), .OB(tmds_d_n_0[j]));
        end
    end endgenerate
    ELVDS_OBUF u_clock_pair (.I(serial[3]), .O(tmds_clk_p_0), .OB(tmds_clk_n_0));
endmodule
