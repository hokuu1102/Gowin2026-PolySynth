`timescale 1ns/1ps

// W1-2.4 self-checking testbench for the portable 512x16 wavetable ROM.
// $readmemh is intentionally testbench-only; synthesizable RTL embeds constants.
module tb_wavetable_bank;
    localparam integer DEPTH = 512;

    reg                       clk_i = 1'b0;
    reg                       rst_n_i = 1'b0;
    reg                       rd_en_i = 1'b0;
    reg  [8:0]                addr_i = 9'd0;
    wire signed [15:0]        sample_o;
    wire                      valid_o;

    reg [15:0] golden [0:DEPTH-1];
    integer address;
    integer errors = 0;
    reg signed [15:0] held_sample;

    always #10 clk_i = ~clk_i;  // 50 MHz

    wavetable_bank dut (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .rd_en_i  (rd_en_i),
        .addr_i   (addr_i),
        .sample_o (sample_o),
        .valid_o  (valid_o)
    );

    task check_response;
        input integer expected_address;
        begin
            if (valid_o !== 1'b1) begin
                $display("FAIL: valid_o not asserted for address %0d", expected_address);
                errors = errors + 1;
            end
            if ((^sample_o) === 1'bx) begin
                $display("FAIL: sample_o contains X/Z at address %0d", expected_address);
                errors = errors + 1;
            end else if (sample_o !== $signed(golden[expected_address])) begin
                $display(
                    "FAIL: address %0d expected %0d (0x%04h), got %0d (0x%04h)",
                    expected_address, $signed(golden[expected_address]),
                    golden[expected_address], sample_o, sample_o
                );
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable/tb_wavetable_bank.vcd");
        $dumpvars(0, tb_wavetable_bank);
        $readmemh("rtl/w3b/rom/sine_512x16.hex", golden);

        if (golden[0]   !== 16'h0000 || golden[128] !== 16'h7fff ||
            golden[256] !== 16'h0000 || golden[384] !== 16'h8001) begin
            $fatal(1, "FAIL: golden wavetable key values are invalid");
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $fatal(1, "FAIL: reset outputs are not valid_o=0 and sample_o=0");
        end
        if (valid_o === 1'bx || (^sample_o) === 1'bx) begin
            $fatal(1, "FAIL: reset outputs contain X/Z");
        end

        rst_n_i = 1'b1;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        rd_en_i = 1'b1;
        addr_i  = 9'd37;
        #1;
        if (valid_o !== 1'b0) begin
            $fatal(1, "FAIL: valid_o changed before the sampling clock edge");
        end
        @(negedge clk_i);
        check_response(37);

        held_sample = sample_o;
        rd_en_i = 1'b0;
        addr_i  = 9'd100;
        @(negedge clk_i);
        if (valid_o !== 1'b0) begin
            $display("FAIL: valid_o asserted while rd_en_i=0");
            errors = errors + 1;
        end
        if (sample_o !== held_sample) begin
            $display("FAIL: sample_o changed while rd_en_i=0");
            errors = errors + 1;
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd0;
        for (address = 0; address < DEPTH; address = address + 1) begin
            @(negedge clk_i);
            check_response(address);
            if (address < DEPTH-1)
                addr_i = address + 1;
        end

        held_sample = sample_o;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== held_sample) begin
            $display("FAIL: disabled state after burst is incorrect");
            errors = errors + 1;
        end

        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        rst_n_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $display("FAIL: post-traffic reset did not clear outputs");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: wavetable_bank 512/512 samples matched with deterministic one-cycle reads");
        else
            $fatal(1, "FAIL: wavetable_bank test found %0d error(s)", errors);

        #20;
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_wavetable_bank timeout");
    end
endmodule
