`timescale 1ns/1ps
// Public-interface regression: calibrated position follows, never autonomous glide.
module tb_slide_position_ctrl;
    reg clk=0, rst_n=0, enable=1, trigger=0, tick=0;
    always #10 clk=~clk;
    reg [3:0] axis_a=6, axis_b=7;
    reg [191:0] positions=0;
    wire [3:0] lookup_axis, owner;
    reg [31:0] lookup_inc;
    wire valid, active, busy;
    wire [31:0] pitch;
    integer observed=0, errors=0;
    reg [3:0] last_owner;
    reg [31:0] last_pitch;
    always @* begin
        case(lookup_axis)
            6: lookup_inc=1000;
            7: lookup_inc=2000;
            8: lookup_inc=4000;
            9: lookup_inc=8000;
            14: lookup_inc=32'h90000000;
            15: lookup_inc=32'hf0000000;
            default: lookup_inc=500;
        endcase
    end
    slide_position_ctrl dut (
        .clk_i(clk), .rst_n_i(rst_n), .enable_i(enable),
        .trigger_i(trigger), .snapshot_i(tick), .axis_a_i(axis_a),
        .axis_b_i(axis_b), .positions_i(positions),
        .lookup_axis_o(lookup_axis), .lookup_inc_i(lookup_inc),
        .pitch_valid_o(valid), .pitch_axis_o(owner), .pitch_inc_o(pitch),
        .active_o(active), .busy_o(busy));
    wire [31:0] x_errors;
    chk_xprop #(.W(39),.NAME("position_slide_contract")) xcheck (
        .clk(clk), .rst_n(rst_n),
        .sig({valid,owner,active,busy,valid ? pitch : 32'd0}), .err_cnt(x_errors));
    always @(negedge clk) begin
        if(valid===1'b1) begin
            observed=observed+1; last_owner=owner; last_pitch=pitch;
        end
    end
    task clocks(input integer n); repeat(n) @(negedge clk); endtask
    task check(input [8*96-1:0] label_text, input condition);
        if(condition !== 1'b1) begin
            errors=errors+1; $display("FAIL: %0s",label_text);
        end else $display("PASS_CHECK: %0s",label_text);
    endtask
    task launch(input bit is_trigger);
        begin
            @(negedge clk); trigger=is_trigger; tick=!is_trigger;
            @(negedge clk); trigger=0; tick=0;
            clocks(80);
        end
    endtask
    integer before_count;
    initial begin
        clocks(5); rst_n=1; clocks(3);
        positions[6*12+:12]=384; positions[7*12+:12]=256;
        launch(1);
        check("first complete 60:40 snapshot is 1400 on original axis6",
              observed==1 && last_owner===4'd6 && last_pitch===32'd1400);
        clocks(200);
        check("without new snapshot there is no autonomous pitch movement",observed==1);
        launch(0);
        check("stationary next snapshot retains 1400",last_pitch===32'd1400);
        positions[6*12+:12]=768; positions[7*12+:12]=192;
        axis_a=7; axis_b=6; launch(1);
        check("reverse pair preserves original voice owner6 and follows 80:20",
              last_owner===4'd6 && last_pitch===32'd1200);
        positions[6*12+:12]=640; positions[7*12+:12]=0; launch(0);
        check("A-only endpoint is exact",last_pitch===32'd1000);
        positions[6*12+:12]=0; positions[7*12+:12]=640; launch(0);
        check("B-only endpoint is emitted, not lost when calculation ends",last_pitch===32'd2000);
        before_count=observed;
        positions=0; launch(0);
        check("both released cancels session without divide-by-zero",!active && !busy && observed==before_count);
        axis_a=8; axis_b=9;
        positions[8*12+:12]=256; positions[9*12+:12]=256; launch(1);
        check("new independent pair starts a new owner8",last_owner===4'd8 && last_pitch===32'd6000);
        before_count=observed;
        @(negedge clk); trigger=1;
        @(negedge clk); trigger=0; clocks(10); enable=0; clocks(80);
        check("W off aborts an in-flight result and suppresses valid",!active && !busy && observed==before_count);
        enable=1; clocks(80);
        check("re-enable does not revive a cancelled session",observed==before_count);
        axis_a=14; axis_b=15; positions=0;
        positions[14*12+:12]=4095; positions[15*12+:12]=4095; launch(1);
        check("unsigned 32-bit endpoints use a full-width weighted sum",
              last_owner===4'd14 && last_pitch===32'hc0000000);
        check("A8 detects no unknown public output",x_errors===32'd0);
        if(errors) $fatal(1,"FAIL: position slide contract errors=%0d",errors);
        $display("PASS: position slide follows calibrated ratios, owns its voice, and cancels atomically");
        $finish;
    end
    initial begin #200000; $fatal(1,"FAIL: position slide timeout"); end
endmodule
