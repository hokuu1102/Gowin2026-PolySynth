`timescale 1ns/1ps
// Passive audio tap. The source must not exceed one sample / 1024 sys clocks.
// At 50/25 MHz the 640-word blanking copy takes 25.7 us, far below the
// 384-sample (7.86 ms) overwrite margin of the 1024-word history.
module waveform_scope (
    input wire sample_clk, sample_rst_n,
    input wire signed [23:0] sample_i,
    input wire valid_i,
    input wire pixel_clk, pixel_rst_n,
    input wire [9:0] x_i, y_i,
    input wire de_i, hs_i, vs_i,
    output reg [7:0] r_o, g_o, b_o,
    output reg de_o, hs_o, vs_o
);
    reg signed [23:0] history [0:1023];
    reg [9:0] wr_ptr, wr_gray;
    reg history_full;
    wire [9:0] wr_next = wr_ptr + 10'd1;
    // No array reset: infer a true dual-clock block RAM. Unwritten memory is
    // never displayed; history_full is sticky after the first complete wrap.
    always @(posedge sample_clk) begin
        if (!sample_rst_n) begin
            wr_ptr <= 0;
            wr_gray <= 0;
            history_full <= 0;
        end else if (valid_i) begin
            history[wr_ptr] <= sample_i;
            wr_ptr <= wr_next;
            wr_gray <= (wr_next >> 1) ^ wr_next;
            if (wr_ptr == 10'd1023) history_full <= 1;
        end
    end

    // The PLL pixel rising edge coincides with a source rising edge. Launch
    // the CDC bundle on the source falling edge to provide a real 10 ns
    // setup/hold separation instead of relying on a false-path exception.
    // This changes only the passive display pointer, never the audio stream.
    reg [9:0] gray_launch;
    reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end

    // Registered Gray pointer and two receiving stages. Both clocks derive
    // from the same 50 MHz reference; every crossing remains timed by SDC.
    reg [9:0] gray_meta, gray_sync;
    reg full_meta, full_sync;
    reg [9:0] wr_seen;
    integer k;
    always @* begin
        wr_seen[9] = gray_sync[9];
        for (k=8; k>=0; k=k-1) wr_seen[k] = wr_seen[k+1] ^ gray_sync[k];
    end
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            gray_meta <= 0; gray_sync <= 0;
            full_meta <= 0; full_sync <= 0;
        end else begin
            gray_meta <= gray_launch; gray_sync <= gray_meta;
            full_meta <= full_launch; full_sync <= full_meta;
        end
    end

    function [8:0] sample_y;
        input signed [23:0] s;
        reg signed [10:0] y_calc;
        begin
            // Signed slice is exactly s >>> 14, including negative rounding.
            y_calc = 11'sd240 - $signed(s[23:14]);
            if (y_calc < 0) sample_y = 9'd0;
            else if (y_calc > 479) sample_y = 9'd479;
            else sample_y = y_calc[8:0];
        end
    endfunction

    reg [8:0] frame_y [0:1023];
    // -----------------------------------------------------------------------
    // Snapshot with an AUDIO-TRIGGERED window start (2026-10-02, H5 fix).
    //
    // Old behaviour: copy a fixed 640-sample window from wr_seen-640. The frame
    // period (16.683 ms) is longer than the window (13.107 ms), so every frame
    // showed the waveform at a different horizontal phase (~260 px per frame at
    // 523 Hz). The LCD / camera afterglow of the previous frame was therefore
    // visible as a SECOND TRACE. Offline proof (dump of two full frames):
    // one frame holds exactly one trace (640/640 columns with one green run),
    // while consecutive frames differ by a -260 px horizontal shift.
    //
    // New behaviour: scan the ring for the first rising zero crossing and start
    // the displayed window there, so every frame is phase aligned and the
    // afterglow lands on top of the trace (a triggered scope).
    //
    // Budget: <= 320 scan reads + 640 fill reads = 960 pixel clocks = 38 us,
    // started on the first blanking line (y=480). Vblank is 45 lines = 1.43 ms,
    // and the oldest read is 960 samples behind the write pointer, so both the
    // video timing and the ring content stay safe.
    // -----------------------------------------------------------------------
    localparam [9:0] SCAN_BACK = 10'd960;   // oldest window start = wr_seen-960
    localparam [9:0] TRIG_MAX  = 10'd320;   // latest window start = wr_seen-640

    localparam [1:0] CP_IDLE = 2'd0, CP_SCAN = 2'd1, CP_FILL = 2'd2;

    reg [1:0]  cp_state;
    reg [9:0]  scan_base, scan_i, scan_i_q;
    reg [9:0]  fill_base, fill_i, fill_i_q;
    reg        fill_rd_q;
    reg        frame_ready;
    reg signed [23:0] history_q, prev_q;
    // The read pipeline is one cycle deep, so the first two scan steps would
    // compare against a sample left over from the previous window (a stale
    // history_q / the reset prev_q). That produced a false "crossing" at
    // scan_i_q=0 and broke the phase lock. Comparisons are therefore enabled
    // only from the third scan step, when both operands come from this window.
    reg [1:0]  scan_warm;

    wire [9:0] history_addr = (cp_state == CP_SCAN) ? (scan_base + scan_i)
                                                   : (fill_base + fill_i);
    wire       history_re   = (cp_state == CP_SCAN) || (cp_state == CP_FILL);
    // rising zero crossing between the two most recently read samples
    wire       crossing     = (prev_q < 24'sd0) && (history_q >= 24'sd0);

    // Snapshot only in vertical blanking. The image is immutable during all
    // 480 active lines; a ring wrap can never splice two different frames.
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            cp_state  <= CP_IDLE;
            scan_base <= 10'd0; scan_i <= 10'd0; scan_i_q <= 10'd0;
            fill_base <= 10'd0; fill_i <= 10'd0; fill_i_q <= 10'd0;
            fill_rd_q <= 1'b0;  frame_ready <= 1'b0;
            prev_q    <= 24'sd0;
            scan_warm <= 2'b00;
        end else begin
            case (cp_state)
                CP_IDLE: begin
                    fill_rd_q <= 1'b0;
                    if (x_i == 0 && y_i == 480 && full_sync) begin
                        scan_base <= wr_seen - SCAN_BACK;
                        scan_i    <= 10'd0;
                        scan_i_q  <= 10'd0;
                        prev_q    <= 24'sd0;
                        scan_warm <= 2'b00;
                        cp_state  <= CP_SCAN;
                    end
                end

                CP_SCAN: begin
                    scan_i    <= scan_i + 10'd1;
                    scan_i_q  <= scan_i;
                    prev_q    <= history_q;
                    fill_rd_q <= 1'b0;
                    scan_warm <= {scan_warm[0], 1'b1};
                    if (crossing && (scan_warm == 2'b11)) begin
                        // the crossing sample (index scan_i_q) becomes column 0
                        fill_base <= scan_base + scan_i_q;
                        fill_i    <= 10'd0;
                        fill_i_q  <= 10'd0;
                        cp_state  <= CP_FILL;
                    end else if (scan_i >= TRIG_MAX) begin
                        // no crossing (silence / DC): fall back to the latest
                        // legal window start so 640 samples are still filled
                        fill_base <= scan_base + TRIG_MAX;
                        fill_i    <= 10'd0;
                        fill_i_q  <= 10'd0;
                        cp_state  <= CP_FILL;
                    end
                end

                CP_FILL: begin
                    fill_rd_q <= 1'b1;
                    fill_i    <= fill_i + 10'd1;
                    fill_i_q  <= fill_i;
                    if (fill_i == 10'd639) cp_state <= CP_IDLE;
                end

                default: cp_state <= CP_IDLE;
            endcase
            // frame_ready is raised one cycle after the last frame_y write.
            // It lives in this block (with the reset) so the register has a
            // single driver.
            if (fill_rd_q && (fill_i_q == 10'd639)) frame_ready <= 1'b1;
        end
    end

    always @(posedge pixel_clk) begin
        if (history_re) history_q <= history[history_addr];
        if (fill_rd_q)  frame_y[fill_i_q] <= sample_y(history_q);
    end

    reg [8:0] point_q, previous_y;
    reg [9:0] x_q, y_q;
    reg de_q, hs_q, vs_q;
    wire [8:0] segment_previous = (x_q == 0) ? point_q : previous_y;
    wire on_trace = frame_ready &&
        (((y_q >= point_q) && (y_q <= segment_previous)) ||
         ((y_q >= segment_previous) && (y_q <= point_q)));
    // Synchronous RAM read, then registered pixel: RGB and all timing signals
    // have the same two-register latency. Column zero never joins to x=639.
    always @(posedge pixel_clk) begin
        if (de_i) point_q <= frame_y[x_i];
        if (!pixel_rst_n) begin
            x_q <= 0; y_q <= 0; de_q <= 0; hs_q <= 1; vs_q <= 1;
            previous_y <= 240;
            r_o <= 0; g_o <= 0; b_o <= 0;
            de_o <= 0; hs_o <= 1; vs_o <= 1;
        end else begin
            x_q <= x_i; y_q <= y_i;
            de_q <= de_i; hs_q <= hs_i; vs_q <= vs_i;
            de_o <= de_q; hs_o <= hs_q; vs_o <= vs_q;
            if (de_q) previous_y <= point_q;
            r_o <= 0; g_o <= 0; b_o <= 0;
            if (de_q) begin
                if (on_trace) begin
                    r_o <= 8'h00; g_o <= 8'hff; b_o <= 8'h00;
                end else if (y_q == 240) begin
                    r_o <= 8'h28; g_o <= 8'h28; b_o <= 8'h28;
                end
            end
        end
    end
endmodule
