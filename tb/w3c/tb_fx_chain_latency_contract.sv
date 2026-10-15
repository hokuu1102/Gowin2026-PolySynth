`timescale 1ns/1ps
`default_nettype none
module tb_fx_chain_latency_contract;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, valid_i=0;
    reg signed [23:0] sample_i=0;
    wire [1:0] valid_o;
    wire signed [23:0] dry_o,dist_o;
    wire [15:0] dry_pipe,dist_pipe;
    fx_chain dry(.clk_i(clk),.rst_n_i(rst_n),.valid_i(valid_i),.sample_i(sample_i),
        .en_mask_i(8'd0),.dist_sel_i(2'd0),.dist_gain_i(16'd16384),.dist_trim_i(16'd32768),
        .dly_delay_i(14'd32),.chor_delay_i(11'd32),.dly_mix_i(8'd0),.dly_fb_i(8'd0),
        .trem_depth_i(8'd0),.trem_rate_i(8'd0),.valid_o(valid_o[0]),.sample_o(dry_o),.pipe_o(dry_pipe));
    fx_chain u_dist_chain(.clk_i(clk),.rst_n_i(rst_n),.valid_i(valid_i),.sample_i(sample_i),
        .en_mask_i(8'd1),.dist_sel_i(2'd0),.dist_gain_i(16'd16384),.dist_trim_i(16'd32768),
        .dly_delay_i(14'd32),.chor_delay_i(11'd32),.dly_mix_i(8'd0),.dly_fb_i(8'd0),
        .trem_depth_i(8'd0),.trem_rate_i(8'd0),.valid_o(valid_o[1]),.sample_o(dist_o),.pipe_o(dist_pipe));
    integer cycle=0,wr=0,rd=0;
    integer due[0:255];
    reg signed [23:0] expected_dry[0:255],expected_dist[0:255];
    longint signed clipped;
    always @(posedge clk) begin
        if(!rst_n) begin cycle=0;wr=0;rd=0; end
        else begin
            cycle=cycle+1;
            if(valid_i) begin
                expected_dry[wr]=sample_i;
                clipped=longint'($signed(sample_i))*4;
                if(clipped>8388607) clipped=8388607;
                if(clipped< -8388608) clipped= -8388608;
                expected_dist[wr]=clipped;
                due[wr]=cycle+19; wr=wr+1;
            end
            #1;
            if(rd<wr && cycle==due[rd]) begin
                if(valid_o !== 2'b11 || dry_o !== expected_dry[rd] || dist_o !== expected_dist[rd])
                    $fatal(1,"FAIL chain sample/latency cycle=%0d index=%0d valid=%b dry=%0d/%0d dist=%0d/%0d",cycle,rd,valid_o,dry_o,expected_dry[rd],dist_o,expected_dist[rd]);
                if(rd==0) $display("OBSERVED_CHAIN_LATENCY=19 metadata=%0d",dry_pipe);
                if(dry_pipe !== 16'd19 || dist_pipe !== 16'd19)
                    $fatal(1,"FAIL chain latency metadata expected=19 actual=%0d/%0d",dry_pipe,dist_pipe);
                rd=rd+1;
            end else if(valid_o !== 2'b00) $fatal(1,"FAIL chain unexpected valid cycle=%0d",cycle);
        end
    end
    integer k;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(10) @(negedge clk);
        for(k=0;k<128;k=k+1) begin
            @(negedge clk); valid_i=1;
            sample_i=(k[0] ? -1 : 1)*(k+1)*65535;
            @(negedge clk); valid_i=0; sample_i=24'sh55aa55;
            repeat(6) @(negedge clk);
        end
        repeat(25) @(negedge clk);
        if(rd!=128 || wr!=128) $fatal(1,"FAIL chain incomplete scoreboard");
        $display("PASS: fx_chain public latency contract: 128 samples, dry and clipping path, production RAM parameters, exact 19-cycle valid and metadata");
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL chain latency timeout"); end
endmodule
`default_nettype wire
