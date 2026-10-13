// Gowin primitive boundary: bit zero is transmitted first.
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
        // One preserved local release register per hard IO lane. The input
        // already has three serial-domain sync stages; retain STA checks.
        (* syn_preserve = 1 *) reg lane_reset = 1'b1;
        always @(posedge serial_clk) lane_reset <= rst;
        OSER10 u_oser (
            .Q(serial[j]), .D0(lane[j][0]), .D1(lane[j][1]),
            .D2(lane[j][2]), .D3(lane[j][3]), .D4(lane[j][4]),
            .D5(lane[j][5]), .D6(lane[j][6]), .D7(lane[j][7]),
            .D8(lane[j][8]), .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(lane_reset)
        );
        if (j < 3) begin : data_pair
            TLVDS_OBUF u_diff (.I(serial[j]), .O(tmds_d_p_0[j]), .OB(tmds_d_n_0[j]));
        end
    end endgenerate
    TLVDS_OBUF u_clock_pair (.I(serial[3]), .O(tmds_clk_p_0), .OB(tmds_clk_n_0));
endmodule
