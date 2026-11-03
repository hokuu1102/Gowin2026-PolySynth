`timescale 1ns/1ps
module guide_output_retime_case #(parameter S=64, P=1, T=17)(input clk,rst,valid,alive,fb,
 input [63:0] data, input signed [4:0] trans,input [15:0] active);
 wire [15:0] ak,bk,av,bv;
 wire ac,bc,ao,bo,ai,bi;
 wire [3:0] ap,bp;
 guide_lamp #(.HELD_SLOTS(S),.DECODE_PIPELINE(P),.TIMEOUT_CLKS(T)) a(
 .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),.note_off5_i(data[4:0]),
 .transpose_i(trans),.fb_mode_i(fb),.key_active_i(active),.stream_alive_i(alive),
 .guide_key_o(ak),.guide_vis_o(av),.guide_commit_o(ac),.guide_on_valid_o(ao),.guide_on_key_o(ap),.stream_idle_o(ai));
 guide_lamp_before_output_retime #(.HELD_SLOTS(S),.DECODE_PIPELINE(P),.TIMEOUT_CLKS(T)) b(
 .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),.note_off5_i(data[4:0]),
 .transpose_i(trans),.fb_mode_i(fb),.key_active_i(active),.stream_alive_i(alive),
 .guide_key_o(bk),.guide_vis_o(bv),.guide_commit_o(bc),.guide_on_valid_o(bo),.guide_on_key_o(bp),.stream_idle_o(bi));
 integer cycles=0;
 always @(posedge clk) begin
   #1; cycles=cycles+1;
   if({ak,av,ac,ao,ap,ai} !== {bk,bv,bc,bo,bp,bi})
     $fatal(1,"S=%0d P=%0d T=%0d cycle=%0d key=%h/%h",S,P,T,cycles,ak,bk);
 end
endmodule
module tb_guide_lamp_output_equiv;
 reg clk=0; always #10 clk=~clk;
 reg rst=0,valid=0,alive=1,fb=0;
 reg [63:0] data=0; reg signed [4:0] trans=0;reg [15:0] active=0;
 genvar k;
 generate for(k=0;k<2;k=k+1)begin:g
 guide_output_retime_case #(64,k,17) c64(clk,rst,valid,alive,fb,data,trans,active);
 guide_output_retime_case #(7,k,2) c7(clk,rst,valid,alive,fb,data,trans,active);
 guide_output_retime_case #(8,k,32) c8(clk,rst,valid,alive,fb,data,trans,active);
 guide_output_retime_case #(1,k,2) c1(clk,rst,valid,alive,fb,data,trans,active);
 end endgenerate
 task step(input [1:0] kind,input [3:0] axis,input [4:0] pitch);
 begin @(negedge clk);valid=1;data=0;data[10:9]=kind;data[22:19]=axis;data[4:0]=pitch;end endtask
 integer i,j; reg [31:0] r=32'h79371a95;
 initial begin
 repeat(3)@(negedge clk);rst=1;
 // Fill/overflow, repeated ON with a full ledger, and partial release.
 for(j=0;j<5;j=j+1)for(i=0;i<16;i=i+1) step(0,i,3+j);
 for(j=0;j<3;j=j+1)for(i=0;i<16;i=i+1) step(0,i,3+j);
 for(j=0;j<5;j=j+1)for(i=0;i<16;i=i+1) step(1,i,3+j);
 // Timeout transitions with events, then reuse and reset.
 @(negedge clk);valid=0;alive=0;repeat(40)@(negedge clk);
 for(i=0;i<20;i=i+1) step(i%2,i,3);
 @(negedge clk);alive=1;rst=0;repeat(2)@(negedge clk);rst=1;
 // Cross the old 16-bit repeat limit while preserving all public outputs.
 for(i=0;i<65538;i=i+1) step(0,0,3);
 for(i=0;i<65538;i=i+1) step(1,0,3);
 // Dense mixed events and changes to mode/transpose while notes are held.
 for(i=0;i<40000;i=i+1) begin
   @(negedge clk);r={r[30:0],r[31]^r[21]^r[1]^r[0]};
   data=0;data[10:9]=r[1:0];data[22:19]=r[5:2];data[4:0]=r[10:6];
   valid=r[11];fb=r[12];trans=r[17:13];active=r[31:16];alive=(i%113)<80;
   rst=(i%997)!=0;
 end
 @(negedge clk);rst=1;valid=0;alive=0;repeat(40)@(negedge clk);
 $display("PASS: all public outputs cycle-exact; 8 parameter configurations, capacity/repeats/mode/timeout/reset");$finish;
 end
endmodule
