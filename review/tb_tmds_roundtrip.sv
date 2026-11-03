`timescale 1ns/1ps
module tb_tmds_roundtrip;
reg clk=0;
always #5 clk=~clk;
reg rst_n=0;
reg [7:0] data=0;
reg de=0,c0=0,c1=0;
wire [9:0] symbol;
tmds_encoder dut(.clk(clk),.rst_n(rst_n),.data(data),.de(de),.c0(c0),.c1(c1),.symbol(symbol));
reg [7:0] qm,decoded;
reg [9:0] control;
integer i,j,ones,running_balance=0,checks=0;
initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    for(i=0;i<4096;i=i+1) begin
        @(negedge clk);
        data=(i*73+(i>>8)) & 255;
        de=((i%257)!=0);
        c0=(i>>8)&1; c1=(i>>9)&1;
        @(posedge clk); #1;
        if(de) begin
            qm=symbol[9] ? ~symbol[7:0] : symbol[7:0];
            decoded[0]=qm[0];
            for(j=1;j<8;j=j+1) decoded[j]=qm[j]^qm[j-1]^~symbol[8];
            if(decoded!==data) $fatal(1,"TMDS round-trip mismatch data=%h symbol=%h decoded=%h",data,symbol,decoded);
            ones=0;
            for(j=0;j<10;j=j+1) ones=ones+symbol[j];
            running_balance=running_balance+2*ones-10;
            if(running_balance>8 || running_balance< -8) $fatal(1,"unbounded running disparity %0d",running_balance);
        end else begin
            case({c1,c0})
                0: control=10'b1101010100;
                1: control=10'b0010101011;
                2: control=10'b0101010100;
                3: control=10'b1010101011;
            endcase
            if(symbol!==control) $fatal(1,"wrong blanking control symbol");
            running_balance=0;
        end
        checks=checks+1;
    end
    $display("PASS: TMDS independent decode/control/disparity checks=%0d",checks);
    $finish;
end
endmodule
