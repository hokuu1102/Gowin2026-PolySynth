`timescale 1ns/1ps
module tb_right_analog_ctrl;
    reg clk = 1'b0, rst_n = 1'b0, enable = 1'b0;
    reg sample_valid = 1'b0;
    reg [2:0] sample_ch = 3'd0;
    reg [11:0] sample_data = 12'd0;
    wire [11:0] depth, rate;
    wire param_valid;
    always #5 clk = ~clk;

    right_analog_ctrl dut (
        .clk_i(clk), .rst_n_i(rst_n), .enable_i(enable),
        .sample_valid_i(sample_valid), .sample_ch_i(sample_ch), .sample_data_i(sample_data),
        .vibrato_depth_o(depth), .vibrato_rate_o(rate), .param_valid_o(param_valid)
    );
    integer errors = 0;
    task chk; input [8*88-1:0] name; input cond; begin
        if (cond) $display("  ok  : %0s", name);
        else begin errors=errors+1; $display("  FAIL: %0s", name); end
    end endtask
    task sample; input [2:0] ch; input [11:0] data; begin
        @(negedge clk); sample_ch=ch; sample_data=data; sample_valid=1'b1;
        @(negedge clk); sample_valid=1'b0;
    end endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1'b1; enable=1'b1;
        sample(3'd2, 12'd321); @(negedge clk);
        chk("CH2 captures vibrato depth", depth == 12'd321 && !param_valid);
        sample(3'd3, 12'd654);
        // The first clock after CH3 is the coherent commit cycle.
        @(negedge clk); chk("CH3 captures rate and commits coherent controls", param_valid && depth == 12'd321 && rate == 12'd654);
        enable=1'b0; @(negedge clk);
        chk("disabled right ADC path forces safe zero controls", depth == 0 && rate == 0 && !param_valid);
        if (errors == 0) $display("PASS: right analog control snapshots CH2/CH3 coherently");
        else $fatal(1, "FAIL: right_analog_ctrl has %0d error(s)", errors);
        $finish;
    end
    initial begin #5000; $fatal(1, "FAIL: tb_right_analog_ctrl timeout"); end
endmodule
