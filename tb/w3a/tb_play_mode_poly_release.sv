`timescale 1ns/1ps
// Mode changes must not strand previously active keyboard voices.
module tb_play_mode_poly_release;
    reg clk=0,rst_n=0,fretboard=0,valid=0;
    reg [3:0] axis=0;
    reg [1:0] kind=0;
    wire out_valid;
    wire [3:0] out_axis;
    wire [1:0] out_kind;
    wire [11:0] out_depth;
    reg [15:0] off_seen=0;
    always #10 clk=~clk;
    play_mode_ctrl dut(.clk_i(clk),.rst_n_i(rst_n),.fretboard_mode_i(fretboard),
        .axis_valid_i(valid),.axis_i(axis),.axis_kind_i(kind),.axis_depth_i(12'd600),
        .pluck_valid_i(1'b0),.pluck_up_i(1'b0),.evt_valid_o(out_valid),
        .evt_axis_o(out_axis),.evt_kind_o(out_kind),.evt_depth_o(out_depth));
    always @(negedge clk)
        if(out_valid===1'b1 && out_kind===2'd1) off_seen[out_axis]=1;
    task event_in(input [3:0] a,input [1:0] k);
        begin
            @(negedge clk);axis=a;kind=k;valid=1;
            @(negedge clk);valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        event_in(2,0);event_in(5,0);
        fretboard=1;
        event_in(2,1);event_in(5,1);
        if(off_seen!==16'h0024)
            $fatal(1,"FAIL: both keyboard voices must release after mode switch, observed=%h",off_seen);
        $display("PASS: all prior keyboard axes release after switching to fretboard");
        $finish;
    end
endmodule
