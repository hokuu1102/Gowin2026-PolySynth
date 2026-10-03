// tb_scope_dump.v - dump two consecutive full frames from waveform_scope.
//
// Purpose: decide whether the on-screen "two lines" are produced by the RTL
// (one frame containing two traces) or by the display chain (two frames with
// different horizontal phase, overlaid by the LCD / camera).
//
// Method: feed a known sine (523.25 Hz at the design's 48.828 kHz sample rate),
// let the 1024-deep history wrap, then dump two complete 640x480 RGB frames as
// binary PPM. Analysis of the PPMs is done in Python.
//
// Run from this directory:
//   iverilog -g2005 -o scope_dump.vvp tb_scope_dump.v <repo>/rtl/hdmi/waveform_scope.v
//   vvp scope_dump.vvp

`timescale 1ns/1ps

module tb_scope_dump;
    localparam integer H_VIS   = 640;
    localparam integer H_TOTAL = 800;
    localparam integer V_VIS   = 480;
    localparam integer V_TOTAL = 525;
    localparam integer NPIX    = H_VIS * V_VIS;
    localparam integer NSAMP   = 1 << 17;

    reg sample_clk = 0;
    reg pixel_clk  = 0;
    always #10 sample_clk = ~sample_clk;   // 50 MHz
    always #20 pixel_clk  = ~pixel_clk;    // 25 MHz

    reg sample_rst_n = 0;
    reg pixel_rst_n  = 0;

    // ---------------- sample source: one valid per 1024 sample clocks --------
    reg signed [23:0] rom [0:NSAMP-1];
    reg signed [23:0] sample_i = 24'sd0;
    reg               valid_i  = 1'b0;
    reg [9:0]         div10    = 10'd0;
    reg [16:0]        sidx     = 17'd0;

    always @(posedge sample_clk) begin
        valid_i <= 1'b0;
        if (div10 == 10'd1023) begin
            div10    <= 10'd0;
            valid_i  <= 1'b1;
            sample_i <= rom[sidx];
            sidx     <= sidx + 17'd1;
        end else begin
            div10 <= div10 + 10'd1;
        end
    end

    // ---------------- 640x480@60 video timing --------------------------------
    reg [11:0] hc = 12'd0;
    reg [11:0] vc = 12'd0;
    reg [9:0]  x_i = 10'd0;
    reg [9:0]  y_i = 10'd0;
    reg        de_i = 1'b0;
    reg        hs_i = 1'b1;
    reg        vs_i = 1'b1;

    always @(posedge pixel_clk) begin
        if (hc == H_TOTAL-1) begin
            hc <= 12'd0;
            if (vc == V_TOTAL-1) vc <= 12'd0; else vc <= vc + 12'd1;
        end else begin
            hc <= hc + 12'd1;
        end
        x_i  <= hc[9:0];
        y_i  <= vc[9:0];
        de_i <= (hc < H_VIS) && (vc < V_VIS);
        hs_i <= ~((hc >= H_VIS+16) && (hc < H_VIS+16+96));
        vs_i <= ~((vc >= V_VIS+10) && (vc < V_VIS+10+2));
    end

    // ---------------- DUT ----------------------------------------------------
    wire [7:0] r_o, g_o, b_o;
    wire       de_o, hs_o, vs_o;

    waveform_scope dut (
        .sample_clk   (sample_clk),
        .sample_rst_n (sample_rst_n),
        .sample_i     (sample_i),
        .valid_i      (valid_i),
        .pixel_clk    (pixel_clk),
        .pixel_rst_n  (pixel_rst_n),
        .x_i          (x_i),
        .y_i          (y_i),
        .de_i         (de_i),
        .hs_i         (hs_i),
        .vs_i         (vs_i),
        .r_o          (r_o),
        .g_o          (g_o),
        .b_o          (b_o),
        .de_o         (de_o),
        .hs_o         (hs_o),
        .vs_o         (vs_o)
    );

    // ---------------- copy monitor (debug) -----------------------------------
    integer cp_count = 0;
    always @(posedge pixel_clk) begin
        if (dut.cp_state == 2'd1 && dut.crossing) begin
            if (cp_count < 12)
                $display("  [scan] t=%0t crossing scan_i_q=%0d scan_base=%0d -> fill_base=%0d",
                         $time, dut.scan_i_q, dut.scan_base, dut.scan_base + dut.scan_i_q);
        end
        if (dut.cp_state == 2'd1 && dut.scan_i == 10'd320) begin
            if (cp_count < 12)
                $display("  [FALLBACK] t=%0t scan reached TRIG_MAX without a crossing", $time);
        end
        if (dut.cp_state == 2'd2 && dut.fill_i == 10'd0) begin
            cp_count = cp_count + 1;
            if (cp_count < 12)
                $display("  [copy %0d] t=%0t FILL starts fill_base=%0d", cp_count, $time, dut.fill_base);
        end
        if (dut.fill_rd_q && dut.cp_state == 2'd2 && dut.fill_i_q == 10'd0 && cp_count < 12)
            $display("      window[0]   sample=%0d  y=%0d", dut.history_q, dut.frame_y[0]);
        if (dut.fill_rd_q && dut.fill_i_q == 10'd639 && cp_count < 12)
            $display("      window[639] sample=%0d  y=%0d", dut.history_q, dut.frame_y[639]);
    end

    // ---------------- frame capture ------------------------------------------
    integer fdA = 0, fdB = 0;
    integer framecnt = 0;
    integer pixcnt   = 0;
    reg     armed    = 1'b0;
    reg     vs_o_d   = 1'b1;

    initial begin
        $readmemh("scope_samples.hex", rom);
        sample_rst_n = 1'b0;
        pixel_rst_n  = 1'b0;
        #200;
        sample_rst_n = 1'b1;
        pixel_rst_n  = 1'b1;
        #30_000_000;                       // 30 ms: history wrapped, copies running
        fdA = $fopen("frameA.ppm", "wb");
        fdB = $fopen("frameB.ppm", "wb");
        $fwrite(fdA, "P6\n640 480\n255\n");
        $fwrite(fdB, "P6\n640 480\n255\n");
        armed = 1'b1;
        $display("armed at %0t", $time);
    end

    always @(posedge pixel_clk) begin
        vs_o_d <= vs_o;
        if (armed && !vs_o_d && vs_o) begin          // start of an output frame
            if (framecnt == 1) begin
                $fclose(fdA);
                $display("frameA complete: %0d pixels at %0t", pixcnt, $time);
            end
            if (framecnt == 2) begin
                $fclose(fdB);
                $display("frameB complete: %0d pixels at %0t", pixcnt, $time);
                $finish;
            end
            framecnt <= framecnt + 1;
            pixcnt   <= 0;
        end else if (de_o && framecnt >= 1 && framecnt <= 2) begin
            if (framecnt == 1) $fwrite(fdA, "%c%c%c", r_o, g_o, b_o);
            else               $fwrite(fdB, "%c%c%c", r_o, g_o, b_o);
            pixcnt <= pixcnt + 1;
        end
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
