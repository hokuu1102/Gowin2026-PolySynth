`timescale 1ns/1ps
// Test-quality diagnostic only. The untouched upstream testbench runs below.
// A correct acceptance test must reject an unknown BPM output, not report PASS.
module tb_bpm_x_verdict_probe;
    tb_bpm_bar_quant upstream();
    initial begin
        wait (upstream.rst_n === 1'b1);
        force upstream.dut.val_o = 8'hxx;
        $display("PROBE_INJECTION: DUT val_o forced to X after reset");
    end
endmodule
