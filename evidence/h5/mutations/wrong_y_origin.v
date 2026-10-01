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
            y_calc = 11'sd239 - $signed(s[23:14]);
            if (y_calc < 0) sample_y = 9'd0;
            else if (y_calc > 479) sample_y = 9'd479;
            else sample_y = y_calc[8:0];
        end
    endfunction

    reg [8:0] frame_y [0:1023];
    reg [9:0] copy_base, copy_index, copy_index_q;
    reg copying, copy_valid_q, frame_ready;
    reg signed [23:0] history_q;
    // Snapshot only in vertical blanking. The image is immutable during all
    // 480 active lines; a ring wrap can never splice two different frames.
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            copy_base <= 0; copy_index <= 0; copy_index_q <= 0;
            copying <= 0; copy_valid_q <= 0; frame_ready <= 0;
        end else begin
            copy_valid_q <= copying;
            if (x_i == 0 && y_i == 480 && full_sync) begin
                copy_base <= wr_seen - 10'd640;
                copy_index <= 0;
                copying <= 1;
            end else if (copying) begin
                copy_index <= copy_index + 1'b1;
                if (copy_index == 639) copying <= 0;
            end
            if (copying) copy_index_q <= copy_index;
            if (copy_valid_q && copy_index_q == 639) frame_ready <= 1;
        end
    end
    wire [9:0] history_addr = copy_base + copy_index;
    always @(posedge pixel_clk) begin
        if (copying) history_q <= history[history_addr];
        if (copy_valid_q) frame_y[copy_index_q] <= sample_y(history_q);
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
