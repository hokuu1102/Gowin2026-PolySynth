`timescale 1ns/1ps
`default_nettype none
module tb_fx_trem_stream_contract;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, valid_i=0, en_i=0;
    reg signed [23:0] sample_i=0;
    reg [7:0] depth_i=0, rate_i=0;
    wire valid_o;
    wire signed [23:0] sample_o;
    wire [15:0] phase_o;
    fx_trem #(.DEPTH_DEFAULT(0),.RATE_DEFAULT(0)) dut(
        .clk_i(clk),.rst_n_i(rst_n),.valid_i(valid_i),.sample_i(sample_i),
        .en_i(en_i),.depth_i(depth_i),.rate_i(rate_i),
        .valid_o(valid_o),.sample_o(sample_o),.lfo_o(phase_o));
    integer cycle=0, wr=0, rd=0, checked=0;
    integer phase=0,triangle,gain;
    integer due[0:2047];
    reg signed [23:0] expected[0:2047];
    longint signed scaled;
    always @(posedge clk) begin
        if(!rst_n) begin cycle=0; wr=0; rd=0; phase=0; end
        else begin
            cycle=cycle+1;
            if(valid_i) begin
                // Independent integer triangle and gain specification, before phase advance.
                triangle=((phase<32768) ? phase : (65535-phase))/128;
                gain=256-((depth_i*(255-triangle))/256);
                scaled=($signed(sample_i)*longint'(gain)) >>> 8;
                expected[wr]=en_i ? scaled : sample_i;
                due[wr]=cycle+3; wr=wr+1;
                phase=(phase+rate_i)%65536;
            end
            #1;
            if(phase_o !== phase[15:0]) $fatal(1,"FAIL trem LFO cycle=%0d expected=%0d actual=%0d",cycle,phase,phase_o);
            if(rd<wr && due[rd]==cycle) begin
                if(valid_o !== 1'b1 || sample_o !== expected[rd])
                    $fatal(1,"FAIL trem sample/valid cycle=%0d index=%0d expected=%0d actual=%0d valid=%b",cycle,rd,expected[rd],sample_o,valid_o);
                rd=rd+1; checked=checked+1;
            end else if(valid_o !== 1'b0) $fatal(1,"FAIL trem unexpected valid cycle=%0d",cycle);
        end
    end
    task push;
        input signed [23:0] x;
        input [7:0] d,r;
        input e;
        begin
            @(negedge clk); sample_i=x; depth_i=d; rate_i=r; en_i=e; valid_i=1;
            @(negedge clk); valid_i=0;
            sample_i= -24'sd7000000; depth_i=~d; rate_i=~r; en_i=~e;
            repeat(4) @(negedge clk);
        end
    endtask
    integer k,seed=32'h261015;
    reg signed [23:0] random_sample;
    reg [7:0] random_depth;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(5) @(negedge clk);
        push(24'sd100000,0,0,1);
        push(-24'sd100000,255,0,1);
        push(24'sh7fffff,255,255,1);
        push(24'sh800000,255,255,1);
        for(k=0;k<768;k=k+1) begin
            random_sample=$random(seed); random_depth=$random(seed);
            push(random_sample,(k%4==0)?0:random_depth,(k%7==0)?0:255,k[0]);
        end
        @(negedge clk); valid_i=1; sample_i=24'sh7fffff; depth_i=255; rate_i=255; en_i=1;
        @(negedge clk); valid_i=0; rst_n=0;
        repeat(3) @(negedge clk); rst_n=1;
        repeat(5) @(negedge clk);
        push(24'sd765432,0,0,1);
        repeat(8) @(negedge clk);
        if(rd!=wr || checked<773) $fatal(1,"FAIL trem incomplete/non-vacuous scoreboard");
        $display("PASS: fx_trem public stream contract: %0d samples, exact 3-cycle latency, atomic depth/rate/enable, phase wrap and reset",checked);
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL trem stream timeout"); end
endmodule
`default_nettype wire
