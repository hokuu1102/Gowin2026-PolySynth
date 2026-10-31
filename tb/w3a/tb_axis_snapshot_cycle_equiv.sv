`timescale 1ns/1ps
module snapshot_timing_fixture #(parameter N=16, A=2, P=12, D=13)(input clk, output reg done=0);
 reg rst=0,valid=0,frame=0;reg [2:0] ch=0;reg [A*P-1:0] data=0;
 wire sv,rv;wire [N*P-1:0] pos,rpos;wire [N*D-1:0] delta,rdelta;wire [N-1:0] seen,rseen;
 axis_snapshot #(.AXIS_N(N),.N_ADC(A),.POS_W(P),.DW(D)) dut(clk,rst,valid,ch,data,frame,sv,pos,delta,seen);
 axis_snapshot_timing_ref #(.AXIS_N(N),.N_ADC(A),.POS_W(P),.DW(D)) ref_dut(clk,rst,valid,ch,data,frame,rv,rpos,rdelta,rseen);
 integer i,seed;
 initial begin
  seed=12345+N;repeat(3)@(negedge clk);
  for(i=0;i<12000;i=i+1)begin
   @(negedge clk);rst=(i%521!=0);valid=($random(seed)&3)!=0;ch=i%8;
   data={$random(seed),$random(seed)};
   if(i%31==0)data=0;if(i%31==1)data={A*P{1'b1}};
   frame=(ch==7)||((i%211)==0);
   @(posedge clk);#1;
   if({sv,pos,delta,seen}!=={rv,rpos,rdelta,rseen})
    $fatal(1,"snapshot cycle mismatch N=%0d P=%0d D=%0d cycle=%0d delta=%h ref=%h",N,P,D,i,delta,rdelta);
  end
  $display("PASS: snapshot every-cycle equivalence N=%0d P=%0d D=%0d",N,P,D);done=1;
 end
endmodule
module tb_axis_snapshot_cycle_equiv;
 reg clk=0;always #5 clk=~clk;wire a,b,c;
 snapshot_timing_fixture f0(clk,a);
 snapshot_timing_fixture #(.N(8),.A(1),.P(8),.D(10)) f1(clk,b);
 snapshot_timing_fixture #(.N(3),.A(1),.P(12),.D(13)) f2(clk,c);
 initial begin wait(a&&b&&c);$display("PASS: all snapshot timing fixtures (36000 compared cycles)");$finish;end
 initial begin #300000;$fatal(1,"snapshot equivalence timeout");end
endmodule
