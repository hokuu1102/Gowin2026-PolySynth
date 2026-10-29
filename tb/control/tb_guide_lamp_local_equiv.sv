`timescale 1ns/1ps
// Differential contract test: capacity edges, per-slot state and modulo-2^32
// repeat counts must match the independent pre-optimization implementation.
module guide_local_case #(parameter N=64)(output reg done=0);
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
  integer cycle=0,j,i;
  reg [31:0] random=32'h93c27651+N;
  always @(posedge clk) begin
    #1;
    if ({a,av,ac,dut.held_valid} !== {b,bv,bc,ref_dut.held_valid})
      $fatal(1,"output/valid mismatch N=%0d cycle=%0d",N,cycle);
    for(j=0;j<N;j=j+1) if(dut.held_valid[j]) begin
      if ({dut.held_axis[j],dut.held_note[j],dut.held_key[j],dut.held_count[j]}
          !== {ref_dut.held_axis[j],ref_dut.held_note[j],ref_dut.held_key[j],ref_dut.held_count[j]})
        $fatal(1,"ledger mismatch N=%0d slot=%0d cycle=%0d",N,j,cycle);
    end
    cycle=cycle+1;
  end
  initial begin
    repeat(2) @(negedge clk);rst=1;
    // Allocate slot zero, then jump to the otherwise billion-event boundary.
    data=64'd3;valid=1;
    @(negedge clk);
    dut.held_count[0]=32'hfffffffe;
    ref_dut.held_count[0]=32'hfffffffe;
    repeat(2) @(negedge clk);
    data[10:9]=1;
    repeat(4) @(negedge clk);
    rst=0;@(negedge clk);rst=1;
    // Fill all slots using four mapped pitches and sixteen independent axes.
    for(i=0;i<N+2;i=i+1)begin
      data=0;data[22:19]=i%16;
      case(i/16) 0:data[4:0]=3;1:data[4:0]=5;2:data[4:0]=7;3:data[4:0]=8;default:data[4:0]=10;endcase
      @(negedge clk);
    end
    for(i=0;i<5000;i=i+1)begin
      random={random[30:0],random[31]^random[21]^random[1]^random[0]};
      valid=random[31:29]!=0;data=0;data[22:19]=random[3:0];
      data[4:0]=3+(random[5:4]<<1);data[10:9]=random[7:6];
      trans=$signed(random[12:8]);fb=random[13];active=random[31:16];
      alive=i%80<55;rst=i%151!=0;
      @(negedge clk);
    end
    valid=0;rst=1;alive=0;repeat(12)@(negedge clk);
    $display("PASS: local count/state cycle equivalence N=%0d",N);done=1;
  end
endmodule
module tb_guide_lamp_local_equiv;
  wire a,b,c,d,e,f;
  guide_local_case #(.N(1)) p1(a);
  guide_local_case #(.N(3)) p3(b);
  guide_local_case #(.N(16)) p16(c);
  guide_local_case #(.N(64)) p64(d);
  guide_local_case #(.N(9)) p9(e);
  guide_local_case #(.N(65)) p65(f);
  initial begin wait(a&&b&&c&&d&&e&&f);$display("PASS: all local equivalence cases");$finish;end
  initial begin #2000000;$fatal(1,"equivalence timeout");end
endmodule
