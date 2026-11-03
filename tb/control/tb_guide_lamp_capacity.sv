`timescale 1ns/1ps
module tb_guide_lamp_capacity;
  reg clk=0; always #10 clk=~clk;
  reg rst=0,valid=0,alive=1;
  reg [63:0] data=0;
  wire [15:0] keys;
  guide_lamp #(.TIMEOUT_CLKS(40)) dut(
    .clk_i(clk),.rst_n_i(rst),.note_valid_i(valid),.note_data_i(data),
    .note_off5_i(data[4:0]),.transpose_i(5'sd0),.fb_mode_i(1'b0),
    .key_active_i(16'd0),.stream_alive_i(alive),.guide_key_o(keys),
    .guide_commit_o(),.guide_vis_o());
  task evt(input [1:0] kind,input [3:0] axis,input [4:0] note);
    begin
      @(negedge clk);data=0;data[10:9]=kind;data[22:19]=axis;data[4:0]=note;valid=1;
      @(negedge clk);valid=0;
    end
  endtask
  integer i,g;
  reg [4:0] pitch;
  initial begin
    repeat(2) @(negedge clk);rst=1;
    for(i=0;i<16;i=i+1) evt(0,i,3);
    for(i=0;i<16;i=i+1) evt(0,i,5);
    for(i=0;i<16;i=i+1) evt(1,i,3);
    if(keys!==16'h0010)$fatal(1,"32 distinct identities: second 16 notes were lost");
    for(i=0;i<16;i=i+1) evt(1,i,5);
    if(keys!==0)$fatal(1,"32 identity release failed");
    for(g=0;g<4;g=g+1) begin
      case(g) 0:pitch=3;1:pitch=5;2:pitch=7;default:pitch=8;endcase
      for(i=0;i<16;i=i+1) evt(0,i,pitch);
    end
    if(keys!==16'h003c)$fatal(1,"64 identity capacity failed");
    for(g=0;g<3;g=g+1) begin
      case(g) 0:pitch=3;1:pitch=5;default:pitch=7;endcase
      for(i=0;i<16;i=i+1) evt(1,i,pitch);
    end
    if(keys!==16'h0004)$fatal(1,"64 identity references released too early");
    alive=0;repeat(44) @(negedge clk);
    if(keys!==0)$fatal(1,"timeout did not clear the complete ledger");
    alive=1;evt(0,0,3);evt(1,0,3);
    if(keys!==0)$fatal(1,"reallocated slot retained an old count");
    evt(0,0,3);rst=0;repeat(2) @(negedge clk);rst=1;
    evt(0,0,3);evt(1,0,3);
    if(keys!==0)$fatal(1,"reset did not invalidate old references");
    $display("PASS: 32/64 mapped identities, release, timeout and reset/reuse");
    $finish;
  end
endmodule
