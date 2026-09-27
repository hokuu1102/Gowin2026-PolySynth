`timescale 1ns/1ps

/* T31b replaced this 512-point single-sine interface.  The retained source
 * below documents the retired acceptance scope; the active test follows it. */
/*

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
*/

// T31b public-ROM protocol test: four 1024-point timbres, soft/hard samples,
// synchronous read and disabled-read hold.  No board-level signals are used.
module tb_wavetable_bank;
    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg rd_en_i = 1'b0;
    reg [1:0] timbre_i = 2'd0;
    reg [9:0] addr_i = 10'd0;
    wire signed [15:0] sample_soft_o;
    wire signed [15:0] sample_hard_o;
    wire valid_o;
    integer errors = 0;
    reg signed [15:0] held_soft, held_hard;

    always #10 clk_i = ~clk_i;

    wavetable_bank dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rd_en_i(rd_en_i),
        .timbre_i(timbre_i), .addr_i(addr_i),
        .sample_soft_o(sample_soft_o), .sample_hard_o(sample_hard_o),
        .valid_o(valid_o)
    );

    task read_and_check;
        input [1:0] t;
        input [9:0] a;
        input signed [15:0] want_soft;
        input signed [15:0] want_hard;
        begin
            @(negedge clk_i);
            timbre_i = t; addr_i = a; rd_en_i = 1'b1;
            @(negedge clk_i);
            if (valid_o !== 1'b1 || sample_soft_o !== want_soft || sample_hard_o !== want_hard) begin
                $display("FAIL: t=%0d a=%0d expected soft=%0d hard=%0d got v=%b soft=%0d hard=%0d",
                         t, a, want_soft, want_hard, valid_o, sample_soft_o, sample_hard_o);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable/tb_wavetable_bank.vcd");
        $dumpvars(0, tb_wavetable_bank);
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== 16'sd0 || sample_hard_o !== 16'sd0)
            $fatal(1, "FAIL: reset state is not zero");
        rst_n_i = 1'b1;

        // 0=BASS sine/triangle; 1=GUITAR sine/saw; 2=PIANO sine/pulse; 3=PAD.
        read_and_check(2'd0, 10'd0,   16'sd0,     16'sd0);
        read_and_check(2'd0, 10'd256, 16'sd16384, 16'sd32767);
        read_and_check(2'd1, 10'd0,   16'sd0,    -16'sd32767);
        read_and_check(2'd2, 10'd0,   16'sd0,     16'sd32766);
        read_and_check(2'd3, 10'd0,   16'sd0,     16'sd0);

        held_soft = sample_soft_o; held_hard = sample_hard_o;
        @(negedge clk_i);
        rd_en_i = 1'b0; addr_i = 10'd511; timbre_i = 2'd3;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== held_soft || sample_hard_o !== held_hard) begin
            $display("FAIL: outputs changed while read was disabled");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: wavetable_bank four timbres use deterministic synchronous reads");
        else
            $fatal(1, "FAIL: wavetable_bank found %0d error(s)", errors);
        $finish;
    end
endmodule
