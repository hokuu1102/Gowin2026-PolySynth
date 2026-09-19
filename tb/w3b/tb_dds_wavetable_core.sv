`timescale 1ns/1ps

// Public-seam test for the reusable DDS -> wavetable core.
// The expected literals come from the independently generated sine table.
module tb_dds_wavetable_core;
    reg                clk_i = 1'b0;
    reg                rst_n_i = 1'b0;
    reg                sample_tick_i = 1'b0;
    reg  [31:0]        phase_inc_i = 32'd0;
    wire signed [15:0] sample_o;
    wire               valid_o;

    integer errors = 0;

    always #10 clk_i = ~clk_i;  // 50 MHz

    dds_wavetable_core dut (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .sample_tick_i (sample_tick_i),
        .phase_inc_i   (phase_inc_i),
        .sample_o      (sample_o),
        .valid_o       (valid_o)
    );

    task request_and_check;
        input integer expected_address;
        input integer expected_sample;
        begin
            @(negedge clk_i);
            sample_tick_i = 1'b1;
            @(negedge clk_i);

            if (valid_o !== 1'b1) begin
                $display("FAIL: no valid sample for expected address %0d", expected_address);
                errors = errors + 1;
            end
            if (sample_o !== expected_sample) begin
                $display(
                    "FAIL: address %0d expected %0d, got %0d",
                    expected_address, expected_sample, sample_o
                );
                errors = errors + 1;
            end
            if ((^sample_o) === 1'bx || valid_o === 1'bx) begin
                $display("FAIL: X/Z observed at expected address %0d", expected_address);
                errors = errors + 1;
            end

            sample_tick_i = 1'b0;
            @(negedge clk_i);
            if (valid_o !== 1'b0) begin
                $display("FAIL: valid_o did not return low between requests");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/dds_wavetable_core/tb_dds_wavetable_core.vcd");
        $dumpvars(0, tb_dds_wavetable_core);

        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0)
            $fatal(1, "FAIL: reset outputs must be sample=0 and valid=0");

        rst_n_i = 1'b1;

        // One table address per sample: 2^23 is one step for a 9-bit address.
        phase_inc_i = 32'd8_388_608;
        request_and_check(0, 0);
        request_and_check(1, 402);
        request_and_check(2, 804);

        // Change pitch without resetting phase. The current address must remain
        // 3, then continue 3 -> 5 -> 7 with the new two-address increment.
        phase_inc_i = 32'd16_777_216;
        request_and_check(3, 1206);
        request_and_check(5, 2009);
        request_and_check(7, 2811);

        if (errors == 0)
            $display("PASS: DDS wavetable core preserves phase across phase_inc changes");
        else
            $fatal(1, "FAIL: DDS wavetable core found %0d error(s)", errors);

        #20;
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_dds_wavetable_core timeout");
    end
endmodule
