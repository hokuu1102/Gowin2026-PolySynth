`timescale 1ns/1ps
// Verification-only wrapper; neither the upstream RTL nor its test is edited.
module tb_bpm_strict_probe;
    parameter INJECT_X = 0;
    tb_bpm_bar_quant upstream();
    initial begin
        if (INJECT_X != 0) begin
            wait (upstream.rst_n === 1'b1);
            force upstream.dut.val_o = 8'hxx;
            $display("PROBE_INJECTION: unknown BPM payload");
        end
    end
    always @(negedge upstream.clk) begin
        if (upstream.rst_n === 1'b1) begin
            if ((^{upstream.load, upstream.pending}) === 1'bx)
                $fatal(1, "STRICT_X_CHECK: unknown control output");
            if ((upstream.load === 1'b1) && ((^upstream.val_o) === 1'bx))
                $fatal(1, "STRICT_X_CHECK: unknown valid BPM payload");
        end
    end
endmodule
