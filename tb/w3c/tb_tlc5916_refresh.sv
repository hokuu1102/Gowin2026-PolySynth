`timescale 1ns/1ps
module tb_tlc5916_refresh;
    reg clk=0,rst_n=0,commit=0,blank=0;
    reg [23:0] pattern=0;
    always #10 clk=~clk;
    wire sdi,sck,le,busy;
    wire [4:0] oe;
    tlc5916_bank dut(.clk_i(clk),.rst_n_i(rst_n),.pattern_i(pattern),
        .pattern_commit_i(commit),.global_blank_i(blank),
        .led_sdi_o(sdi),.led_clk_o(sck),.led_le_o(le),.led_oe_n_o(oe),.busy_o(busy));
    reg [7:0] shifted=0,latched=0;
    reg last_sck=0,last_le=0;
    integer shown0=0,shown1=0,shown2=0,cycles0=0,cycles1=0,cycles2=0;
    always @(posedge clk) begin
        #1;
        if(sck && !last_sck) begin
            if(oe!==5'b11111) $fatal(1,"FAIL: LEDs enabled during shift");
            shifted={shifted[6:0],sdi};
        end
        if(le && !last_le) latched=shifted;
        if(rst_n && !blank) begin
            case(oe)
                5'b11110: begin if(latched!==8'h04) $fatal(1,"FAIL: chip0 data");cycles0=cycles0+1; end
                5'b11101: begin if(latched!==8'h10) $fatal(1,"FAIL: chip1 data");cycles1=cycles1+1; end
                5'b01111: begin if(latched!==8'h01) $fatal(1,"FAIL: status data");cycles2=cycles2+1; end
                5'b11111: begin
                    if(cycles0>=25000) shown0=shown0+1;
                    if(cycles1>=25000) shown1=shown1+1;
                    if(cycles2>=25000) shown2=shown2+1;
                    cycles0=0;cycles1=0;cycles2=0;
                end
                default: $fatal(1,"FAIL: multiple boards enabled");
            endcase
        end
        last_sck=sck;last_le=le;
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(1000) @(negedge clk);
        pattern=24'h800420;commit=1;
        @(negedge clk);commit=0;
        // One commit must keep refreshing independent boards, not just shift once.
        repeat(160000) @(negedge clk);
        if(shown0<2 || shown1<2 || shown2<2)
            $fatal(1,"FAIL: persistent refresh %0d/%0d/%0d",shown0,shown1,shown2);
        blank=1;repeat(5) @(negedge clk);
        if(oe!==5'b11111) $fatal(1,"FAIL: global blank");
        $display("PASS: shared-bus three-board refresh, mapping, dwell and safe OE");$finish;
    end
endmodule
