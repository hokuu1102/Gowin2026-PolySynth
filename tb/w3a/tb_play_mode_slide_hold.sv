`timescale 1ns/1ps
module tb_play_mode_slide_hold;
    reg clk=0,rst_n=0,valid=0,pluck=0,slide=0,mode=1;
    reg [3:0] axis=0;
    reg [1:0] kind=0;
    wire out_valid;
    wire [3:0] out_axis;
    wire [1:0] out_kind;
    wire [11:0] out_depth;
    integer offs=0;
    always #10 clk=~clk;
    play_mode_ctrl dut(.clk_i(clk),.rst_n_i(rst_n),.fretboard_mode_i(mode),
        .axis_valid_i(valid),.axis_i(axis),.axis_kind_i(kind),.axis_depth_i(12'd600),
        .pluck_valid_i(pluck),.pluck_up_i(1'b1),
`ifndef LEGACY_SLIDE_PORTS
        .slide_active_i(slide),.slide_axis_i(4'd6),
`endif
        .evt_valid_o(out_valid),.evt_axis_o(out_axis),
        .evt_kind_o(out_kind),.evt_depth_o(out_depth));
    always @(negedge clk) begin
        if(out_valid===1'b1 && out_kind===2'd1) begin
            offs=offs+1;
            if(out_axis!==4'd6) $fatal(1,"FAIL: slide released an unrelated voice");
        end
    end
    task event_in(input [3:0] a,input [1:0] k);
        begin
            @(negedge clk);axis=a;kind=k;valid=1;
            @(negedge clk);valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        event_in(6,0);
        @(negedge clk);pluck=1;
        @(negedge clk);pluck=0;
        slide=1;
        event_in(7,0);event_in(6,1);
        if(offs!=0) $fatal(1,"FAIL: owner must sustain while partner remains pressed");
        event_in(7,1);slide=0;
        repeat(8) @(negedge clk);
        if(offs!=1) $fatal(1,"FAIL: both released must emit exactly one deferred owner OFF");
        // Cancel a pending release by re-pressing its owner, then end the
        // session in keyboard mode. The physical OFF must not be duplicated.
        event_in(6,0);
        @(negedge clk);pluck=1;
        @(negedge clk);pluck=0;slide=1;
        event_in(6,1);event_in(6,0);
        slide=0;repeat(8) @(negedge clk);
        if(offs!=1) $fatal(1,"FAIL: re-pressed owner was released");
        slide=1;event_in(6,1);
        @(negedge clk);mode=0;slide=0;axis=6;kind=1;valid=1;
        @(negedge clk);valid=0;
        repeat(8) @(negedge clk);
        if(offs!=2) $fatal(1,"FAIL: mode change duplicated the deferred OFF: %0d",offs);
        $display("PASS: slide sustains across the original key release and ends exactly once");
        $finish;
    end
endmodule
