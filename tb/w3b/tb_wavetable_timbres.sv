`timescale 1ns/1ps

// T31b acceptance: the fixed two-bit timbre contract selects four distinct
// embedded 1024-point wavetable pairs.  This is a public ROM-interface test;
// it deliberately does not inspect the implementation's storage structure.
module tb_wavetable_timbres;
    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg rd_en_i = 1'b0;
    reg [1:0] timbre_i = 2'd0;
    reg [9:0] addr_i = 10'd0;
    wire signed [15:0] sample_soft_o;
    wire signed [15:0] sample_hard_o;
    wire valid_o;
    integer errors = 0;
    reg signed [15:0] held_soft;
    reg signed [15:0] held_hard;
    reg signed [15:0] pad_soft_a;
    reg signed [15:0] pad_hard_a;
    reg signed [15:0] pad_soft_b;
    reg signed [15:0] pad_hard_b;

    always #10 clk_i = ~clk_i;

    wavetable_bank dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rd_en_i(rd_en_i),
        .timbre_i(timbre_i), .addr_i(addr_i),
        .sample_soft_o(sample_soft_o), .sample_hard_o(sample_hard_o),
        .valid_o(valid_o)
    );

    task expect_sample;
        input [1:0] timbre;
        input [9:0] address;
        input signed [15:0] expected_soft;
        input signed [15:0] expected_hard;
        begin
            timbre_i = timbre;
            addr_i = address;
            rd_en_i = 1'b1;
            @(negedge clk_i);
            if (valid_o !== 1'b1 || sample_soft_o !== expected_soft ||
                sample_hard_o !== expected_hard) begin
                $display("FAIL: timbre=%0d addr=%0d expected soft=%0d hard=%0d, got valid=%b soft=%0d hard=%0d",
                         timbre, address, expected_soft, expected_hard,
                         valid_o, sample_soft_o, sample_hard_o);
                errors = errors + 1;
            end
        end
    endtask

    task read_sample;
        input [1:0] timbre;
        input [9:0] address;
        output signed [15:0] got_soft;
        output signed [15:0] got_hard;
        begin
            timbre_i = timbre;
            addr_i = address;
            rd_en_i = 1'b1;
            @(negedge clk_i);
            got_soft = sample_soft_o;
            got_hard = sample_hard_o;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk_i);
        rst_n_i = 1'b1;

        // Fixed IDs point at the CC0 AKWF sources documented in
        // assets/third_party/akwf/SOURCES.md.  These are public ROM anchors,
        // not an assertion about the generator's implementation.
        expect_sample(2'd0, 10'd0,  16'sd373,  16'sd226);
        expect_sample(2'd1, 10'd0,  16'sd4848, 16'sd5588);
        expect_sample(2'd2, 10'd0,  16'sd1123, 16'sd3176);
        expect_sample(2'd3, 10'd0,  16'sd917,  16'sd906);

        expect_sample(2'd0, 10'd256, 16'sd32490, 16'sd32280);
        expect_sample(2'd1, 10'd512, -16'sd31041, -16'sd30638);
        expect_sample(2'd2, 10'd768, 16'sd3217, 16'sd963);

        // The chosen PAD source is a complete periodic capture, not an
        // antisymmetric mathematical half copied into the other half.
        read_sample(2'd3, 10'd128, pad_soft_a, pad_hard_a);
        read_sample(2'd3, 10'd640, pad_soft_b, pad_hard_b);
        if ((pad_soft_b === -pad_soft_a) || (pad_hard_b === -pad_hard_a)) begin
            $display("FAIL: PAD source unexpectedly has half-wave antisymmetry soft=%0d/%0d hard=%0d/%0d",
                     pad_soft_a, pad_soft_b, pad_hard_a, pad_hard_b);
            errors = errors + 1;
        end

        held_soft = sample_soft_o;
        held_hard = sample_hard_o;
        rd_en_i = 1'b0;
        addr_i = 10'd777;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== held_soft ||
            sample_hard_o !== held_hard) begin
            $display("FAIL: disabled read did not hold both wavetable outputs");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: T31b four timbre wavetable public interface");
        else
            $fatal(1, "FAIL: T31b wavetable interface has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_wavetable_timbres timeout");
    end
endmodule
