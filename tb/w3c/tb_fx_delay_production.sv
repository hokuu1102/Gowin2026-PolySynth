`timescale 1ns/1ps
`default_nettype none
module tb_fx_delay_production;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0,valid_i=0;
    reg signed [23:0] sample_i=0;
    wire valid_o,primed;
    wire signed [23:0] sample_o;
    fx_delay #(.SAMPLE_W(24),.AW(14)) dut(.clk_i(clk),.rst_n_i(rst_n),
        .valid_i(valid_i),.sample_i(sample_i),.en_i(1'b1),.sel_i(2'd0),
        .delay_i(14'd9),.mix_i(8'd128),.fb_i(8'd128),
        .valid_o(valid_o),.sample_o(sample_o),.primed_o(primed));
    integer received=0,echoes=0,offset;
    reg signed [23:0] expected;
    always @(posedge clk) begin
        #1;
        if(rst_n && valid_o) begin
            offset=received-16384;
            expected=0;
            // Aligned impulse survives 18-bit storage exactly. send/return: dry passes at unity,
            // the wet tap is scaled by mix=1/2, fb=1/2. The writeback path has no mix term,
            // so the echo train (offset 9/18/27) is unchanged.
            if(offset==0) expected=1048576;
            if(offset==9) expected=524288;
            if(offset==18) expected=262144;
            if(offset==27) expected=131072;
            if(sample_o !== expected)
                $fatal(1,"FAIL production delay index=%0d expected=%0d actual=%0d",received,expected,sample_o);
            if(offset==9 || offset==18 || offset==27) echoes=echoes+1;
            received=received+1;
        end
    end
    task push;
        input signed [23:0] x;
        begin
            @(negedge clk); valid_i=1; sample_i=x;
            @(negedge clk); valid_i=0; sample_i=24'sh55aa55;
            repeat(6) @(negedge clk);
        end
    endtask
    integer k;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        for(k=0;k<16384;k=k+1) push(0);
        if(primed !== 1'b1) $fatal(1,"FAIL production delay did not prime full 16384 samples");
        push(1048576);
        for(k=1;k<32;k=k+1) push(0);
        repeat(10) @(negedge clk);
        if(received!=16416 || echoes!=3) $fatal(1,"FAIL production delay incomplete/non-vacuous");
        $display("PASS: fx_delay production 16384x18 memory priming, exact nine-sample echo and three feedback decays, %0d outputs",received);
        $finish;
    end
    initial begin #4000000; $fatal(1,"FAIL production delay timeout"); end
endmodule
`default_nettype wire
