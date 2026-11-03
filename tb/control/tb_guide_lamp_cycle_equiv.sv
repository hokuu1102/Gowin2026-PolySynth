`timescale 1ns/1ps
module tb_guide_lamp_cycle_equiv;
  reg clk=0; always #10 clk=~clk;
  reg rst=0,valid=0,alive=1,fb=0;
  reg [63:0] data=0;
  reg signed [4:0] trans=0;
  reg [15:0] active=0;
  wire [15:0] a,b,av,bv;
  wire ac,bc;
  guide_lamp #(.TIMEOUT_CLKS(32)) dut(.clk_i(clk),.rst_n_i(rst),
    .note_valid_i(valid),.note_data_i(data),.note_off5_i(data[4:0]),
    .transpose_i(trans),.fb_mode_i(fb),.key_active_i(active),.stream_alive_i(alive),
    .guide_key_o(a),.guide_vis_o(av),.guide_commit_o(ac));
  guide_lamp_rc1 #(.TIMEOUT_CLKS(32)) ref_dut(.clk_i(clk),.rst_n_i(rst),
    .note_valid_i(valid),.note_data_i(data),.note_off5_i(data[4:0]),
    .transpose_i(trans),.fb_mode_i(fb),.key_active_i(active),.stream_alive_i(alive),
    .guide_key_o(b),.guide_vis_o(bv),.guide_commit_o(bc));
  reg [31:0] random=32'h637295a1;
  integer i;
  always @(negedge clk) if(rst && {a,av,ac} !== {b,bv,bc})
    $fatal(1,"cycle mismatch at %0d actual=%h/%h/%b ref=%h/%h/%b",i,a,av,ac,b,bv,bc);
  initial begin
    repeat(2)@(negedge clk);rst=1;
    // Continuous events exercise no-bubble RMW and lowest-slot OFF matching.
    for(i=0;i<12000;i=i+1)begin
      @(negedge clk);
      random={random[30:0],random[31]^random[21]^random[1]^random[0]};
      valid=1;data=0;data[4:0]=random[4:0];data[22:19]=random[8:5];
      data[10:9]=random[10:9]==0 ? 0 : 1;
      trans=$signed(random[15:11])%13;fb=random[16];active=random[31:16];
      alive=(i%300)<240; if(i%500==0)rst=0;else rst=1;
    end
    @(negedge clk);valid=0;rst=1;repeat(4)@(negedge clk);
    $display("PASS: 12000 cycle-exact randomized ledger/mapping/masking/timeout/reset events");$finish;
  end
endmodule
