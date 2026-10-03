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

    // 2026-10-02: the OSER10 RESET is sampled by FCLK (serial_clk, 4 ns period).
    // Feeding it straight from another domain produced, in turn:
    //   clk_sys   -> pixel_clk  hold   -0.053  (raw !rst_n from hdmi_scope)
    //   pixel_clk -> serial_clk setup  -0.516  (video_reset_n from hdmi_scope)
    // Both are cross-domain checks on an asynchronous reset.  Synchronizing the
    // reset into serial_clk here (2 FFs, reset released in the serial domain)
    // makes every check serial_clk -> serial_clk while keeping the primitive's
    // asynchronous assertion, which is the intended use of an OSER10 RESET.
    reg [1:0] rst_serial;
    always @(posedge serial_clk or posedge rst) begin
        if (rst) rst_serial <= 2'b11;
        else     rst_serial <= {rst_serial[0], 1'b0};
    end

    genvar j;
    generate for (j=0; j<4; j=j+1) begin : lanes
        OSER10 u_oser (
            .Q(serial[j]), .D0(lane[j][0]), .D1(lane[j][1]),
            .D2(lane[j][2]), .D3(lane[j][3]), .D4(lane[j][4]),
            .D5(lane[j][5]), .D6(lane[j][6]), .D7(lane[j][7]),
            .D8(lane[j][8]), .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst_serial[1])
        );
        if (j < 3) begin : data_pair
            TLVDS_OBUF u_diff (.I(serial[j]), .O(tmds_d_p_0[j]), .OB(tmds_d_n_0[j]));
        end
    end endgenerate
    TLVDS_OBUF u_clock_pair (.I(serial[3]), .O(tmds_clk_p_0), .OB(tmds_clk_n_0));
endmodule
