`timescale 1ns/1ps
`default_nettype none
module tb_calib_cmd_q_y;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg rx_done = 0;
    reg [7:0] rx_data = 0;
    wire scope_req, dump_req;
    integer q_count = 0, y_count = 0;
    calib_cmd dut (
        .clk_i(clk), .rst_n_i(rst_n), .rx_done_i(rx_done), .rx_data_i(rx_data),
        .scope_mode_req_o(scope_req), .recdump_req_o(dump_req)
    );
    // Deliberately duplicate Q and Y: the command table must detect both.
    calib_cmd #(.CMD_RECDUMP(8'h51)) duplicate (
        .clk_i(clk), .rst_n_i(rst_n), .rx_done_i(1'b0), .rx_data_i(8'd0)
    );
    always @(posedge clk) begin
        if (rst_n) begin
            if (scope_req) q_count = q_count + 1;
            if (dump_req) y_count = y_count + 1;
            if (scope_req && dump_req) $fatal(1, "FAIL: Q and Y fired together");
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
            $fatal(1, "FAIL: command uniqueness table omitted Q or Y");
        rst_n = 1;
        send_byte(8'h51);
        send_byte(8'h59);
        if (q_count != 1 || y_count != 1) $fatal(1, "FAIL: command pulse counts");
        send_byte(8'hA5);
        for (i = 0; i < 8; i = i + 1) send_byte(i[0] ? 8'h51 : 8'h59);
        if (q_count != 1 || y_count != 1) $fatal(1, "FAIL: payload triggered commands");
        send_byte(8'h59);
        send_byte(8'h51);
        if (q_count != 2 || y_count != 2) $fatal(1, "FAIL: post-frame commands lost");
        $display("PASS: Q/Y pulses, payload isolation and duplicate detection");
        $finish;
    end
    initial begin #100000; $fatal(1, "FAIL: timeout"); end
endmodule
`default_nettype wire
