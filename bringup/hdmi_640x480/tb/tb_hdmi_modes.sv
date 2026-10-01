`timescale 1ns/1ps
// Digital timing test only: PLL and physical serializer are stubbed below.
module tb_hdmi_modes;
`ifdef H4_MODE
    localparam integer H4 = 1;
`else
    localparam integer H4 = 0;
`endif
    localparam HA = H4 ? 1920 : 640, HF = H4 ? 48 : 16;
    localparam HS = H4 ? 32 : 96, HT = H4 ? 2080 : 800;
    localparam VA = H4 ? 1200 : 480, VF = H4 ? 3 : 10;
    localparam VS = H4 ? 6 : 2, VT = H4 ? 1235 : 525;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
`ifdef H4_MODE
    hdmi_h4 dut (.clk(clk), .rst_n(rst_n));
`else
    hdmi_top dut (.clk(clk), .rst_n(rst_n));
`endif
    integer x, y, active_count = 0;
    reg expected_hs, expected_vs;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        wait (dut.video_reset_n === 1'b1);
        @(negedge clk);
        for (y = 0; y < VT; y = y + 1) begin
            for (x = 0; x < HT; x = x + 1) begin
                expected_hs = (x >= HA + HF && x < HA + HF + HS);
                expected_vs = (y >= VA + VF && y < VA + VF + VS);
                if (!H4) begin
                    expected_hs = !expected_hs;
                    expected_vs = !expected_vs;
                end
                if (dut.x !== x || dut.y !== y ||
                    dut.hs !== expected_hs || dut.vs !== expected_vs ||
                    dut.de !== (x < HA && y < VA))
                    $fatal(1, "mode=%0d at x=%0d y=%0d: timing mismatch", H4, x, y);
                if (dut.de) active_count = active_count + 1;
                @(negedge clk);
            end
        end
        if (dut.x !== 0 || dut.y !== 0 || active_count != HA * VA)
            $fatal(1, "frame wrap or active count mismatch");
        $display("PASS H4=%0d active=%0dx%0d total=%0dx%0d pixels=%0d sync_positive=%0d", H4, HA, VA, HT, VT, active_count, H4);
        $finish;
    end
endmodule

module hdmi_clk #(parameter USE_252=0)
    (input clk, rst_n, output pixel_clk, serial_clk, lock);
    assign pixel_clk = clk;
    assign serial_clk = clk;
    assign lock = rst_n;
endmodule

module hdmi_clk_h4
    (input clk, rst_n, output pixel_clk, serial_clk, lock);
    assign pixel_clk = clk;
    assign serial_clk = clk;
    assign lock = rst_n;
endmodule

module tmds_serializer
    (input pixel_clk, serial_clk, rst, input [9:0] blue, green, red,
     output [2:0] tmds_d_p_0, tmds_d_n_0,
     output tmds_clk_p_0, tmds_clk_n_0);
endmodule
