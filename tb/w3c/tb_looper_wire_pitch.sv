`timescale 1ns/1ps
`default_nettype none
module tb_looper_wire_pitch;
    reg clk=0, rst_n=0, rec=0, stop=0, live=0, dump=0;
    reg [31:0] inc=0;
    reg [15:0] addr=0;
    wire [63:0] data;
    wire clip;
    wire [15:0] count;
    always #10 clk=~clk;
    looper #(.EVT_MAX(8)) dut (
        .clk_i(clk),.rst_n_i(rst_n),.tick_i(1'b0),.tick_cnt_i(20'd0),
        .bar_start_i(1'b0),.transport_i(1'b1),.live_valid_i(live),
        .live_axis_i(4'd0),.live_inc_i(inc),.live_vel_i(8'd128),
        .live_kind_i(2'd0),.live_timbre_i(2'd1),.live_vel_valid_i(1'b0),
        .live_vel_axis_i(4'd0),.live_vel_value_i(8'd0),.rec_req_i(rec),
        .stop_req_i(stop),.play_en_i(1'b0),.clear_req_i(1'b0),
        .evt_cnt_flat_o(count),.dump_en_i(dump),.dump_addr_i(addr),
        .dump_data_o(data),.dump_clip_o(clip)
    );
    task check_word(input [15:0] a,input [20:0] expected,input expected_loss);
        begin
            @(negedge clk); dump=1;addr=a;
            repeat(3) @(negedge clk);
            if(data[43:23] !== expected || clip !== expected_loss)
                $fatal(1,"FAIL: wire pitch addr=%0d got=%0d loss=%b expected=%0d/%b",a,data[43:23],clip,expected,expected_loss);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;rec=1;
        @(negedge clk);rec=0;
        repeat(3) @(negedge clk);
        inc=32'd2096128;live=1;
        @(negedge clk);live=0;
        @(negedge clk);inc=32'd38702809;live=1;
        @(negedge clk);live=0;
        @(negedge clk);stop=1;
        @(negedge clk);stop=0;
        repeat(25) @(negedge clk);
        // Worked wire-unit literals: exact low tone and A4 rounded down.
        check_word(0,21'd2047,1'b0);
        check_word(1,21'd37795,1'b1);
        $display("PASS: recording exports score-unit pitch and observable quantization");
        $finish;
    end
    initial begin #100000; $fatal(1,"FAIL: watchdog"); end
endmodule
`default_nettype wire
