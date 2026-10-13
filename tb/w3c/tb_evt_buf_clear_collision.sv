`timescale 1ns/1ps
module tb_evt_buf_clear_collision;
    reg clk=0,rst_n=0,wr=0,clear=0;
    always #10 clk=~clk;
    wire overflow,high_water;
    wire [15:0] drops,count;
    evt_buf #(.DEPTH(2)) dut(.clk_i(clk),.rst_n_i(rst_n),
        .wr_valid_i(wr),.wr_data_i(64'd1),.rd_ack_i(1'b0),
        .ovf_clr_i(clear),.ovf_o(overflow),.high_water_o(high_water),
        .drop_cnt_o(drops),.cnt_o(count));
    initial begin
        repeat(4) @(negedge clk);rst_n=1;wr=1;
        repeat(2) @(negedge clk);clear=1;
        @(negedge clk);wr=0;clear=0;
        if(count!=2 || !overflow || drops!=1 || !high_water)
            $fatal(1,"FAIL: simultaneous clear erased new overflow/drop");
        clear=1;@(negedge clk);clear=0;
        if(overflow || drops!=0 || high_water) $fatal(1,"FAIL: idle clear failed");
        $display("PASS: clear retains a same-cycle new overflow");$finish;
    end
endmodule
