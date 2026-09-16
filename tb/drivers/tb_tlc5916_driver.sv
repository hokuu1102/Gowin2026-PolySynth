`timescale 1ns/1ps

module tb_tlc5916_driver;

    localparam integer CLK_PERIOD_NS = 20;

    reg       clk;
    reg       rst_n;
    reg       start;
    reg [7:0] led_data;
    reg       outputs_enable;

    wire tlc_clk;
    wire tlc_sdi;
    wire tlc_le;
    wire tlc_oe_n;
    wire busy;
    wire done;

    integer tlc_clk_count;
    integer le_pulse_count;
    integer error_count;
    reg [7:0] captured_data;

    tlc5916_driver dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .led_data       (led_data),
        .outputs_enable (outputs_enable),
        .tlc_clk        (tlc_clk),
        .tlc_sdi        (tlc_sdi),
        .tlc_le         (tlc_le),
        .tlc_oe_n       (tlc_oe_n),
        .busy           (busy),
        .done           (done)
    );

    always #(CLK_PERIOD_NS / 2) begin
        clk = ~clk;
    end

    // TLC5916 samples SDI on each rising edge of its serial clock.
    always @(posedge tlc_clk) begin
        if (rst_n) begin
            captured_data = {captured_data[6:0], tlc_sdi};
            tlc_clk_count = tlc_clk_count + 1;
        end
    end

    always @(posedge tlc_le) begin
        if (rst_n) begin
            le_pulse_count = le_pulse_count + 1;
        end
    end

    task automatic send_and_check(input [7:0] expected_data);
        integer errors_before;

        begin
            errors_before = error_count;
            tlc_clk_count  = 0;
            le_pulse_count = 0;
            captured_data  = 8'h00;

            @(negedge clk);
            led_data = expected_data;
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait (done === 1'b1);
            #1;

            if (tlc_clk_count !== 8) begin
                $display(
                    "ERROR data=%02h: clock count=%0d, expected 8",
                    expected_data, tlc_clk_count
                );
                error_count = error_count + 1;
            end

            if (captured_data !== expected_data) begin
                $display(
                    "ERROR data=%02h: captured=%02h",
                    expected_data, captured_data
                );
                error_count = error_count + 1;
            end

            if (le_pulse_count !== 1) begin
                $display(
                    "ERROR data=%02h: LE count=%0d, expected 1",
                    expected_data, le_pulse_count
                );
                error_count = error_count + 1;
            end

            if (busy !== 1'b0) begin
                $display("ERROR data=%02h: busy should be low", expected_data);
                error_count = error_count + 1;
            end

            if (tlc_le !== 1'b0) begin
                $display("ERROR data=%02h: tlc_le should be low", expected_data);
                error_count = error_count + 1;
            end

            if (tlc_oe_n !== 1'b0) begin
                $display("ERROR data=%02h: tlc_oe_n should be low", expected_data);
                error_count = error_count + 1;
            end

            if (error_count == errors_before) begin
                $display(
                    "PASS: TLC5916 transmitted %02h correctly",
                    expected_data
                );
            end
        end
    endtask

    // The repository contract requires an active-low synchronous reset.
    task automatic check_synchronous_reset;
        begin
            @(negedge clk);
            led_data = 8'hFF;
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait (tlc_clk === 1'b1);
            @(negedge clk);
            rst_n = 1'b0;

            // A synchronous reset must not change registers before clk rises.
            #1;
            if ((tlc_clk !== 1'b1) || (busy !== 1'b1)) begin
                $display("ERROR: reset changed state before a clk rising edge");
                error_count = error_count + 1;
            end

            @(posedge clk);
            #1;
            if ((tlc_clk !== 1'b0) ||
                (tlc_sdi !== 1'b0) ||
                (tlc_le !== 1'b0) ||
                (tlc_oe_n !== 1'b1) ||
                (busy !== 1'b0) ||
                (done !== 1'b0)) begin
                $display("ERROR: synchronous reset did not restore idle outputs");
                error_count = error_count + 1;
            end

            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
            $display("PASS: synchronous reset behavior checked");
        end
    endtask

    initial begin
        $dumpfile("build/sim/tlc5916/tlc5916_tb.vcd");
        $dumpvars(0, tb_tlc5916_driver);

        clk            = 1'b0;
        rst_n          = 1'b0;
        start          = 1'b0;
        led_data       = 8'h00;
        outputs_enable = 1'b0;

        tlc_clk_count  = 0;
        le_pulse_count = 0;
        error_count    = 0;
        captured_data  = 8'h00;

        #100;
        rst_n = 1'b1;
        #100;

        outputs_enable = 1'b1;

        send_and_check(8'h00);
        send_and_check(8'hA5);
        send_and_check(8'hFF);
        send_and_check(8'h3C);
        check_synchronous_reset();
        send_and_check(8'h5A);

        if (error_count == 0) begin
            $display("PASS: all TLC5916 tests completed successfully");
        end
        else begin
            $fatal(
                1,
                "FAIL: TLC5916 tests found %0d error(s)",
                error_count
            );
        end

        #200;
        $finish;
    end

endmodule
