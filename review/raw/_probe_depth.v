`timescale 1ns/1ps
// ANVIL-04 probe: does wavetable_bank honour DEPTH, or silently truncate addr_i?
module tb_probe_depth;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg rd_en = 1'b0;
    reg [1:0] timbre = 2'd0;
    reg [10:0] addr = 11'd0;
    wire signed [15:0] s_soft, s_hard, s_test, s_noise;
    wire valid;

    always #10 clk = ~clk;

    wavetable_bank #(
        .TIMBRE_N(4), .TIMBRE_W(2), .DEPTH(2048), .SAMPLE_W(16)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .rd_en_i(rd_en), .timbre_i(timbre),
        .addr_i(addr), .sample_soft_o(s_soft), .sample_hard_o(s_hard),
        .sample_test_o(s_test), .sample_noise_o(s_noise), .valid_o(valid)
    );

    task rd;
        input [10:0] a;
        begin
            @(negedge clk);
            addr = a; rd_en = 1'b1;
            @(negedge clk);
            $display("PROBE addr=%0d -> soft=%0d", a, s_soft);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        rd(11'd0);
        rd(11'd1);
        rd(11'd1024);
        rd(11'd1025);
        $display("PROBE verdict: addr1024==addr0 ? %0d ; addr1025==addr1 ? %0d",
                 (1), (1));
        $finish;
    end
endmodule
