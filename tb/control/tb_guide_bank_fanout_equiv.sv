`timescale 1ns/1ps
module guide_bank_fanout_case #(parameter N=64)(input clk,output reg done=0);
reg rst=0,valid=0,alive=1,fb=0;
reg [63:0] data=0;reg signed [4:0] trans=0;reg [15:0] pressed=0;
wire [15:0] keys,vis,ref_keys,ref_vis;
wire commit,on_valid,idle,ref_commit,ref_on_valid,ref_idle;
wire [3:0] on_key,ref_on_key;
guide_lamp #(.HELD_SLOTS(N),.TIMEOUT_CLKS(8),.DECODE_PIPELINE(1)) dut(
 .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),
 .note_off5_i(data[4:0]),.transpose_i(trans),.fb_mode_i(fb),
 .key_active_i(pressed),.stream_alive_i(alive),.guide_key_o(keys),
 .guide_vis_o(vis),.guide_commit_o(commit),.guide_on_valid_o(on_valid),
 .guide_on_key_o(on_key),.stream_idle_o(idle));
guide_lamp_before_bank_fanout #(.HELD_SLOTS(N),.TIMEOUT_CLKS(8),.DECODE_PIPELINE(1)) reference(
 .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),
 .note_off5_i(data[4:0]),.transpose_i(trans),.fb_mode_i(fb),
 .key_active_i(pressed),.stream_alive_i(alive),.guide_key_o(ref_keys),
 .guide_vis_o(ref_vis),.guide_commit_o(ref_commit),.guide_on_valid_o(ref_on_valid),
 .guide_on_key_o(ref_on_key),.stream_idle_o(ref_idle));
integer cycles=0,j,i;reg [31:0] random_q=32'h1eac57b3 ^ N;
reg [31:0] count_value;reg [4:0] key_value;
always @(posedge clk) begin
 #1;
 if(!done)begin
  if({keys,vis,commit,on_valid,on_key,idle} !== {ref_keys,ref_vis,ref_commit,ref_on_valid,ref_on_key,ref_idle})
   $fatal(1,"FAIL: public guide outputs N=%0d cycle=%0d",N,cycles);
  for(integer s=0;s<N;s=s+1)begin
   if({dut.held_valid[s],dut.held_axis[s],dut.held_note[s],dut.held_key[s],dut.held_count[s]} !==
      {reference.held_valid[s],reference.held_axis[s],reference.held_note[s],reference.held_key[s],reference.held_count[s]})
    $fatal(1,"FAIL: ledger state N=%0d slot=%0d cycle=%0d",N,s,cycles);
  end
  cycles=cycles+1;
 end
end
task event_word(input integer index,input bit off);begin
 data=0;data[4:0]=3+(index/16);data[22:19]=index%16;data[10:9]=off?1:0;
end endtask
initial begin
 repeat(3)@(negedge clk);rst=1;
 // Fill/reject across every bank, then close each original identity.
 for(i=0;i<80;i=i+1)begin @(negedge clk);valid=1;event_word(i,0);end
 for(i=79;i>=0;i=i-1)begin @(negedge clk);event_word(i,1);end
 // Repeated identities must retain the full 32-bit reference count.
 for(i=0;i<12;i=i+1)begin @(negedge clk);event_word(0,0);end
 for(i=0;i<12;i=i+1)begin @(negedge clk);event_word(0,1);end
 for(i=0;i<2048;i=i+1)begin
  @(negedge clk);
  random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
  rst=(i!=777 && i!=1023);valid=random_q[0];alive=(i%128)<100;
  fb=random_q[1];trans=random_q[6:2];pressed=random_q[31:16];
  data=0;data[4:0]=random_q[11:7];data[22:19]=random_q[15:12];data[10:9]=random_q[17:16];
  // Inject equal arbitrary ledger states into both implementations. This
  // forces priority conflicts and uint32 boundaries in all physical banks.
  if(i%32==0)begin
   for(j=0;j<N;j=j+1)begin
    case(j%5)
     0:count_value=0;1:count_value=1;2:count_value=2;
     3:count_value=32'hffffffff;default:count_value=random_q ^ (j*32'h13579bdf);
    endcase
    case(j%4)0:key_value=5;1:key_value=6;2:key_value=4;default:key_value=7;endcase
    dut.held_valid[j]=((j+i/32)%3)!=0;reference.held_valid[j]=dut.held_valid[j];
    dut.held_axis[j]=j%16;reference.held_axis[j]=dut.held_axis[j];
    dut.held_note[j]=3+(j%4);reference.held_note[j]=dut.held_note[j];
    dut.held_key[j]=key_value;reference.held_key[j]=key_value;
    dut.held_count[j]=count_value;reference.held_count[j]=count_value;
   end
   data[4:0]=3+((i/32)%4);data[22:19]=(i/32)%16;data[10:9]=(i/32)%2;valid=1;trans=0;fb=0;
  end
 end
 @(negedge clk);rst=1;valid=0;alive=0;pressed=0;
 repeat(20)@(negedge clk);
 if(keys!==0)$fatal(1,"FAIL: idle clear N=%0d",N);
 done=1;$display("PASS: bank fanout equivalence N=%0d checked cycles=%0d",N,cycles);
end
endmodule
module tb_guide_bank_fanout_equiv;
reg clk=0;always #10 clk=~clk;wire [4:0] done;
guide_bank_fanout_case #(1) a(clk,done[0]);
guide_bank_fanout_case #(3) b(clk,done[1]);
guide_bank_fanout_case #(9) c(clk,done[2]);
guide_bank_fanout_case #(64) d(clk,done[3]);
guide_bank_fanout_case #(65) e(clk,done[4]);
initial begin wait(&done);$display("PASS: all five bank fanout equivalence configurations");$finish;end
initial begin #1000000;$fatal(1,"FAIL: bank fanout watchdog");end
endmodule
