`timescale 1ns/1ps
module tb_guide_lamp_identity;
  reg clk=0; always #10 clk=~clk;
  reg rst=0,valid=0,fb=0,alive=1;
  reg [63:0] data=0;
  reg signed [4:0] transpose=0;
  wire [15:0] keys;
  guide_lamp #(.TIMEOUT_CLKS(20)) dut(.clk_i(clk),.rst_n_i(rst),
    .note_valid_i(valid),.note_data_i(data),.note_off5_i(5'd3),
    .transpose_i(transpose),.fb_mode_i(fb),.key_active_i(16'd0),
    .stream_alive_i(alive),.guide_key_o(keys),.guide_commit_o(),.guide_vis_o());
  task evt;
    input [1:0] kind;input [3:0] axis;
    begin
      @(negedge clk);data=0;data[10:9]=kind;data[22:19]=axis;valid=1;
      @(negedge clk);valid=0;
    end
  endtask
  integer i;
  initial begin
    repeat(2) @(negedge clk);rst=1;
    evt(0,0);if(keys!==16'h0020)$fatal(1,"ON setup");
    transpose=2;evt(1,0);if(keys!==0)$fatal(1,"transpose left original lamp lit");
    transpose=0;evt(0,0);fb=1;evt(1,0);
    if(keys!==0)$fatal(1,"mode change left original lamp lit");
    fb=0;
    for(i=0;i<16;i=i+1)evt(0,i);
    for(i=0;i<15;i=i+1)evt(1,i);
    if(keys!==16'h0020)$fatal(1,"sixteenth overlapping note lost");
    evt(1,15);if(keys!==0)$fatal(1,"last OFF failed");
    // Repeated same-axis ONs must also retain multiplicity.
    for(i=0;i<8;i=i+1)evt(0,0);
    for(i=0;i<7;i=i+1)evt(1,0);
    if(keys!==16'h0020)$fatal(1,"eighth repeated note lost");
    alive=0;repeat(24)@(negedge clk);
    if(keys!==0)$fatal(1,"timeout failed to clear identities");
    alive=1;evt(0,0);evt(1,0);
    if(keys!==0)$fatal(1,"timeout retained stale identity");
    $display("PASS: guide identity, 16 overlaps, repeated ONs and timeout");
    $finish;
  end
endmodule
