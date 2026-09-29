`timescale 1ns/1ps

// Public-ROM acceptance for the four CC0 AKWF source waves selected in
// assets/third_party/akwf/SOURCES.md.  The literals are independently frozen
// source anchors after the documented offline DC removal, normalisation,
// smoothing and 256-to-1024 periodic resampling.
module tb_akwf_wavetables;
`ifdef GOWIN_PRIM_SIM
    GSR GSR(.GSRI(1'b1));
`endif
    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg rd_en_i = 1'b0;
    reg [1:0] timbre_i = 2'd0;
    reg [9:0] addr_i = 10'd0;
    wire signed [15:0] sample_soft_o;
    wire signed [15:0] sample_hard_o;
    wire valid_o;
    integer errors = 0;

    always #10 clk_i = ~clk_i;

    wavetable_bank dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rd_en_i(rd_en_i),
        .timbre_i(timbre_i), .addr_i(addr_i),
        .sample_soft_o(sample_soft_o), .sample_hard_o(sample_hard_o),
        .valid_o(valid_o)
    );

    task expect_source_anchor;
        input [1:0] timbre;
        input [9:0] address;
        input signed [15:0] want_soft;
        input signed [15:0] want_hard;
        begin
            @(negedge clk_i);
            timbre_i = timbre;
            addr_i = address;
            rd_en_i = 1'b1;
            @(negedge clk_i);
            if (valid_o !== 1'b1 || sample_soft_o !== want_soft || sample_hard_o !== want_hard) begin
                $display("FAIL: AKWF source anchor timbre=%0d addr=%0d expected=%0d/%0d got=%b %0d/%0d",
                         timbre, address, want_soft, want_hard,
                         valid_o, sample_soft_o, sample_hard_o);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk_i);
        rst_n_i = 1'b1;

        // 0=BASS AKWF_dbass_0050; 1=GUITAR AKWF_eguitar_0015;
        // 2=PIANO AKWF_clavinet_0005; 3=PAD AKWF_eorgan_0020.
        expect_source_anchor(2'd0, 10'd0,   16'sd373,   16'sd226);
        expect_source_anchor(2'd0, 10'd256, 16'sd32490, 16'sd32280);
        expect_source_anchor(2'd1, 10'd0,   16'sd4848,  16'sd5588);
        expect_source_anchor(2'd1, 10'd512, -16'sd31041, -16'sd30638);
        expect_source_anchor(2'd2, 10'd0,   16'sd1123,  16'sd3176);
        expect_source_anchor(2'd2, 10'd768, 16'sd3217,  16'sd963);
        expect_source_anchor(2'd3, 10'd0,   16'sd917,   16'sd906);
        expect_source_anchor(2'd3, 10'd768, -16'sd13002, -16'sd13034);

        if (errors == 0)
            $display("PASS: wavetable_bank emits the selected CC0 AKWF four-timbre set");
        else
            $fatal(1, "FAIL: AKWF wavetable acceptance found %0d error(s)", errors);
        $finish;
    end
endmodule
