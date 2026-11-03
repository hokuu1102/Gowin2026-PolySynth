`timescale 1ns/1ps
// Check outputs and all valid identity/count payloads over arbitrary one-step
// ledger transitions. Invalid payloads are outside the contract: allocation
// must initialize identity and count before they become observable.
// Unlike long event traces, this exercises distinct wide counts in every bank
// and duplicate identities that must keep the original lowest-slot priority.
module guide_state_case #(parameter N=64)(output reg done=0);
  reg clk=0; always #10 clk=~clk;
  reg rst=0,valid=0,alive=1,fb=0;
  reg [63:0] data=0;
  reg signed [4:0] trans=0;
  reg [15:0] active=0;
  wire [15:0] a,b,av,bv;
  wire ac,bc;
  guide_lamp #(.HELD_SLOTS(N),.TIMEOUT_CLKS(8)) dut(
    .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),
    .note_off5_i(data[4:0]),.transpose_i(trans),.fb_mode_i(fb),
    .key_active_i(active),.stream_alive_i(alive),
    .guide_key_o(a),.guide_vis_o(av),.guide_commit_o(ac));
  guide_lamp_rc1 #(.HELD_SLOTS(N),.TIMEOUT_CLKS(8)) ref_dut(
    .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),
    .note_off5_i(data[4:0]),.transpose_i(trans),.fb_mode_i(fb),
    .key_active_i(active),.stream_alive_i(alive),
    .guide_key_o(b),.guide_vis_o(bv),.guide_commit_o(bc));
  reg [31:0] random=32'h5e361f93+N;
  integer i,j,k;
  reg checking=0;
  task advance_random;
    begin random={random[30:0],random[31]^random[21]^random[1]^random[0]};end
  endtask
  always @(posedge clk) begin
    #1;
    if(checking) begin
      if({a,av,ac,dut.held_valid,dut.stream_idle_cnt}
          !== {b,bv,bc,ref_dut.held_valid,ref_dut.stream_idle_cnt})
        $fatal(1,"state/output mismatch N=%0d step=%0d",N,i);
      for(k=0;k<N;k=k+1)
        if(dut.held_valid[k] && ({dut.held_axis[k],dut.held_note[k],dut.held_key[k]}
            !== {ref_dut.held_axis[k],ref_dut.held_note[k],ref_dut.held_key[k]}
            || dut.held_count[k] !== ref_dut.held_count[k]))
          $fatal(1,"full ledger mismatch N=%0d slot=%0d step=%0d",N,k,i);
    end
  end
  initial begin
    repeat(2)@(negedge clk);rst=1;
    for(i=0;i<1024;i=i+1)begin
      for(j=0;j<N;j=j+1)begin
        advance_random;
        dut.held_axis[j]=j%16;ref_dut.held_axis[j]=j%16;
        dut.held_note[j]=3;ref_dut.held_note[j]=3;
        dut.held_key[j]=random[3] ? 5 : 4;
        ref_dut.held_key[j]=dut.held_key[j];
        // Include zero, last-reference, carry and underflow boundaries.
        case((i+j)%8)
          0:dut.held_count[j]=0;
          1:dut.held_count[j]=1;
          2:dut.held_count[j]=32'hffffffff;
          3:dut.held_count[j]=32'hfffffffe;
          default:dut.held_count[j]=random;
        endcase
        ref_dut.held_count[j]=dut.held_count[j];
        // Single occupied slot walks every bank; mixed/duplicate states
        // exercise priority and allocation independently of the count data.
        dut.held_valid[j]=(i%4==0) ? j==i%N : ((i%4==3) ? 1'b1 : random[7]);
        ref_dut.held_valid[j]=dut.held_valid[j];
      end
      advance_random;
      dut.stream_idle_cnt=i%8;ref_dut.stream_idle_cnt=i%8;
      valid=i%13!=0;rst=i%101!=0;alive=i%5!=0;
      data=0;data[4:0]=3;
      data[22:19]=(i%4==0) ? (i%N)%16 : random[3:0];
      data[10:9]=i%3==0 ? 0 : (i%3==1 ? 1 : 2);
      trans=random[9] ? 0 : 2;fb=i%11==0;active=random[31:16];
      checking=1;
      @(negedge clk);
    end
    checking=0;valid=0;rst=0;
    $display("PASS: 1024 arbitrary-state transitions N=%0d",N);done=1;
  end
endmodule
module tb_guide_lamp_state_equiv;
  wire a,b,c,d;
  guide_state_case #(.N(3)) p3(a);
  guide_state_case #(.N(9)) p9(b);
  guide_state_case #(.N(64)) p64(c);
  guide_state_case #(.N(65)) p65(d);
  initial begin wait(a&&b&&c&&d);$display("PASS: all arbitrary-state transitions");$finish;end
  initial begin #1000000;$fatal(1,"state equivalence timeout");end
endmodule
