`timescale 1ns/1ps
`default_nettype none
module tb_fx_dist_stream_contract;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, valid_i=0, en_i=0;
    reg signed [23:0] sample_i=0;
    reg [15:0] gain_i=4096, trim_i=32768;
    reg [1:0] sel_i=0;
    wire valid_o;
    wire signed [23:0] sample_o;
    wire [23:0] peak_o;
    wire [15:0] clips;
    fx_dist dut(.clk_i(clk),.rst_n_i(rst_n),.valid_i(valid_i),.sample_i(sample_i),
        .en_i(en_i),.sel_i(sel_i),.gain_i(gain_i),.trim_i(trim_i),
        .valid_o(valid_o),.sample_o(sample_o),.peak_o(peak_o),.clip_cnt_o(clips));

    // Independent integer specification; no DUT hierarchy, forces or copied bit tests.
    integer cycle=0, wr=0, rd=0, expected_clips=0, checked=0;
    integer due[0:2047];
    reg signed [23:0] expected[0:2047];
    reg [23:0] expected_peak[0:2047];
    reg expected_clip[0:2047];
    longint signed amplified, limited, trimmed, peak;
    reg clipped;
    always @(posedge clk) begin
        if(!rst_n) begin cycle=0; wr=0; rd=0; expected_clips=0; end
        else begin
            cycle=cycle+1;
            if(valid_i) begin
                amplified=($signed(sample_i)*longint'(gain_i)) >>> 12;
                limited=amplified;
                clipped=0;
                if(limited>8388607) begin limited=8388607; clipped=1; end
                if(limited< -8388608) begin limited= -8388608; clipped=1; end
                peak=clipped ? 8388607 : ((amplified<0) ? -amplified : amplified);
                trimmed=(limited*longint'(trim_i)) >>> 15;
                if(trimmed>8388607) begin trimmed=8388607; clipped=1; end
                if(trimmed< -8388608) begin trimmed= -8388608; clipped=1; end
                expected[wr]=en_i ? trimmed : sample_i;
                expected_peak[wr]=peak;
                expected_clip[wr]=en_i && clipped;
                due[wr]=cycle+5; wr=wr+1;
            end
            #1;
            if(rd<wr && due[rd]==cycle) begin
                if(valid_o !== 1'b1 || sample_o !== expected[rd])
                    $fatal(1,"FAIL dist sample/valid cycle=%0d index=%0d expected=%0d actual=%0d valid=%b",cycle,rd,expected[rd],sample_o,valid_o);
                if(peak_o !== expected_peak[rd])
                    $fatal(1,"FAIL dist peak index=%0d expected=%0d actual=%0d",rd,expected_peak[rd],peak_o);
                if(expected_clip[rd] && expected_clips<65535) expected_clips=expected_clips+1;
                checked=checked+1; rd=rd+1;
            end else if(valid_o !== 1'b0) $fatal(1,"FAIL dist unexpected valid cycle=%0d",cycle);
            if(clips !== expected_clips[15:0])
                $fatal(1,"FAIL dist clips cycle=%0d expected=%0d actual=%0d",cycle,expected_clips,clips);
        end
    end

    task push;
        input signed [23:0] x;
        input [15:0] g,t;
        input e;
        input [1:0] mode;
        begin
            @(negedge clk); sample_i=x; gain_i=g; trim_i=t; en_i=e; sel_i=mode; valid_i=1;
            @(negedge clk); valid_i=0;
            // Idle data and all controls are allowed to change during the pipeline.
            sample_i=24'sd8000000; gain_i=16'hffff; trim_i=16'hffff; en_i=~e; sel_i=~mode;
            repeat(5) @(negedge clk);
        end
    endtask
    integer k;
    integer seed=32'h260615;
    reg signed [23:0] random_sample;
    reg [15:0] random_gain,random_trim;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(5) @(negedge clk);
        push(24'sd100000,16'd4096,16'd32768,1,0);
        push(-24'sd100000,16'd4096,16'd32768,1,1);
        push(24'sd4000000,16'd16384,16'd32768,1,2);
        push(-24'sd4000000,16'd16384,16'd32768,1,3);
        push(24'sh7fffff,16'd4096,16'hffff,1,0);
        push(24'sh800000,16'd4096,16'd32768,1,0);
        push(24'sd4000000,16'd65535,16'd65535,0,0);
        push(24'sd123456,16'd0,16'd32768,1,0);
        push(24'sd123456,16'd65535,16'd0,1,0);
        for(k=0;k<256;k=k+1) begin
            random_sample=$random(seed); random_gain=$random(seed); random_trim=$random(seed);
            push(random_sample,random_gain,random_trim,k[0],k[2:1]);
        end
        // Reset must discard an in-flight clipped sample and clear diagnostics.
        @(negedge clk); valid_i=1; sample_i=24'sh7fffff; gain_i=65535; trim_i=65535; en_i=1;
        @(negedge clk); valid_i=0; rst_n=0;
        repeat(3) @(negedge clk); rst_n=1;
        repeat(8) @(negedge clk);
        push(24'sd765432,16'd4096,16'd32768,1,0);
        repeat(10) @(negedge clk);
        if(rd!=wr || checked<266) $fatal(1,"FAIL dist incomplete/non-vacuous scoreboard");
        $display("PASS: fx_dist public stream contract: %0d samples, exact 5-cycle latency, atomic controls, peak/clip alignment and reset",checked);
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL dist stream timeout"); end
endmodule
`default_nettype wire
