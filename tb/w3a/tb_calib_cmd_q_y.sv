`timescale 1ns/1ps
`default_nettype none
module tb_calib_cmd_q_y;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg rx_done = 0;
    reg [7:0] rx_data = 0;
    // Historical test filename retained; scope command is now E, not Q.
    wire scope_req, dump_req, met_req, bpm_req, slide_req;
    wire [7:0] bpm_val;
    integer e_count = 0, y_count = 0, b_count = 0, bpm_count = 0, w_count = 0;
    calib_cmd dut (
        .clk_i(clk), .rst_n_i(rst_n), .rx_done_i(rx_done), .rx_data_i(rx_data),
        .scope_mode_req_o(scope_req), .recdump_req_o(dump_req), .met_req_o(met_req),
        .bpm_set_req_o(bpm_req), .bpm_val_o(bpm_val), .slide_req_o(slide_req)
    );
    // Deliberately duplicate E and Y: the command table must detect both.
    calib_cmd #(.CMD_RECDUMP(8'h45)) duplicate (
        .clk_i(clk), .rst_n_i(rst_n), .rx_done_i(1'b0), .rx_data_i(8'd0)
    );
    always @(posedge clk) begin
        if (rst_n) begin
            if (scope_req) e_count = e_count + 1;
            if (dump_req) y_count = y_count + 1;
            if (met_req) b_count = b_count + 1;
            if (bpm_req) bpm_count = bpm_count + 1;
            if (slide_req) w_count = w_count + 1;
            if (scope_req && dump_req) $fatal(1, "FAIL: E and Y fired together");
        end
    end
    task send_byte(input [7:0] value);
        begin
            @(negedge clk); rx_done = 1; rx_data = value;
            @(negedge clk); rx_done = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    integer i;
    initial begin
        repeat (4) @(negedge clk);
        if (dut.letters_ok !== 1'b1 || duplicate.letters_ok !== 1'b0)
            $fatal(1, "FAIL: command uniqueness table omitted E or Y");
        rst_n = 1;
        send_byte(8'h45);
        send_byte(8'h59);
        if (e_count != 1 || y_count != 1) $fatal(1, "FAIL: command pulse counts");
        send_byte(8'h42);
        if (b_count != 1 || e_count != 1 || y_count != 1)
            $fatal(1, "FAIL: B metronome command changed or collided with E");
        send_byte(8'h51);
        if (b_count != 1 || e_count != 1 || y_count != 1 || bpm_count != 0)
            $fatal(1, "FAIL: Q collided with E/B/Y or emitted BPM before payload");
        send_byte(8'hA5);
        send_byte(8'd140);
        for (i = 0; i < 7; i = i + 1) send_byte(8'd0);
        if (bpm_count != 1 || bpm_val != 8'd140 || e_count != 1)
            $fatal(1, "FAIL: Q framed BPM missing or switched scope");
        send_byte(8'h57);
        if (w_count != 1 || b_count != 1 || e_count != 1 || y_count != 1)
            $fatal(1, "FAIL: W slide collided with E/B/Y");
        send_byte(8'hA5);
        for (i = 0; i < 8; i = i + 1) send_byte(i[0] ? 8'h45 : 8'h59);
        if (e_count != 1 || y_count != 1 || b_count != 1 || bpm_count != 1 || w_count != 1)
            $fatal(1, "FAIL: payload triggered commands");
        send_byte(8'h59);
        send_byte(8'h45);
        if (e_count != 2 || y_count != 2) $fatal(1, "FAIL: post-frame commands lost");
        $display("PASS: E/Y/B/Q/W independent, framed BPM=140, payload isolation and duplicate detection");
        $finish;
    end
    initial begin #100000; $fatal(1, "FAIL: timeout"); end
endmodule
`default_nettype wire
