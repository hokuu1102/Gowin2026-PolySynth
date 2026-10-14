`timescale 1ns/1ps
module tb_play_mode_fret_release;
    reg clk=0,rst_n=0,valid=0,pluck=0;
    reg [3:0] axis=0;
    reg [1:0] kind=0;
    wire out_valid;
    wire [3:0] out_axis;
    wire [1:0] out_kind;
    wire [11:0] out_depth;
    reg [15:0] off_seen=0;
    always #10 clk=~clk;
    play_mode_ctrl dut(.clk_i(clk),.rst_n_i(rst_n),.fretboard_mode_i(1'b1),
        .axis_valid_i(valid),.axis_i(axis),.axis_kind_i(kind),.axis_depth_i(12'd600),
        .pluck_valid_i(pluck),.pluck_up_i(1'b1),.evt_valid_o(out_valid),
        .evt_axis_o(out_axis),.evt_kind_o(out_kind),.evt_depth_o(out_depth));
    always @(negedge clk)
        if(out_valid===1'b1 && out_kind===2'd1) off_seen[out_axis]=1;
    task select(input [3:0] a);
        begin
            @(negedge clk);axis=a;kind=0;valid=1;
            @(negedge clk);valid=0;pluck=1;
            @(negedge clk);pluck=0;
            repeat(2) @(negedge clk);
        end
    endtask
    task release_axis(input [3:0] a);
        begin
            @(negedge clk);axis=a;kind=1;valid=1;
            @(negedge clk);valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        select(6);select(9);
        release_axis(6);release_axis(9);
        if(off_seen!==16'h0240)
            $fatal(1,"FAIL: both plucked axes must release, observed=%h",off_seen);
        $display("PASS: a new pluck cannot strand the prior axis");
        $finish;
    end
endmodule
