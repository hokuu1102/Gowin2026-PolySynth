`timescale 1ns/1ps
module vibrato_ce_case #(parameter [31:0] STEP=16, parameter integer DIV=10)(output reg done=0);
reg clk=0,rst=0,valid=0;reg [11:0] depth=0,rate=0;
always #10 clk=~clk;
wire signed [15:0] a,b;wire da,db;wire [31:0] ra,rb,pa,pb;
vibrato_lfo #(.RATE_SLEW_STEP(STEP),.CTRL_SLEW_DIV(DIV)) dut(.clk_i(clk),.rst_n_i(rst),.ctrl_valid_i(valid),.depth_raw_i(depth),.rate_raw_i(rate),.mod_o(a),.depth_active_o(da),.rate_inc_dbg_o(ra),.phase_dbg_o(pa));
vibrato_lfo_before_ce #(.RATE_SLEW_STEP(STEP),.CTRL_SLEW_DIV(DIV)) ref_dut(.clk_i(clk),.rst_n_i(rst),.ctrl_valid_i(valid),.depth_raw_i(depth),.rate_raw_i(rate),.mod_o(b),.depth_active_o(db),.rate_inc_dbg_o(rb),.phase_dbg_o(pb));
reg [31:0] random=32'h9abc1234,initial_rate;integer i;
always @(posedge clk)begin
 #1;if({a,da,ra,pa,dut.depth_q,dut.slew_count_q}!=={b,db,rb,pb,ref_dut.depth_q,ref_dut.slew_count_q})
 $fatal(1,"FAIL: vibrato cycle/state mismatch STEP=%h DIV=%0d cycle=%0d",STEP,DIV,i);
end
initial begin
 repeat(3)@(negedge clk);rst=1;
 for(i=0;i<4096;i=i+1)begin
  @(negedge clk);random={random[30:0],random[31]^random[21]^random[1]^random[0]};
  rate=random[11:0];depth=random[23:12];valid=(i%5!=0);rst=(i%257!=0);
  if(i%31==0)rate=12'bx;
  #1;
  case(i%7)
   0:initial_rate=ref_dut.rate_target_w;
   1:initial_rate=ref_dut.rate_target_w+1;
   2:initial_rate=ref_dut.rate_target_w-1;
   3:initial_rate=ref_dut.rate_target_w+STEP;
   4:initial_rate=ref_dut.rate_target_w-STEP;
   5:initial_rate=ref_dut.rate_target_w+STEP+1;
   default:initial_rate=random;
  endcase
  dut.rate_inc_q=initial_rate;ref_dut.rate_inc_q=initial_rate;
  dut.slew_count_q=DIV-1;ref_dut.slew_count_q=DIV-1;
  if(i%17==0)begin dut.phase_q=random;ref_dut.phase_q=random;end
 end
 @(negedge clk);valid=0;done=1;
 $display("PASS: vibrato 4096 exact cycle/state comparisons STEP=%h DIV=%0d including equality, slew boundaries and X target",STEP,DIV);
end
endmodule
module tb_vibrato_rate_ce_equiv;
wire a,b,c,d;
vibrato_ce_case #(.STEP(16),.DIV(10)) n(a);
vibrato_ce_case #(.STEP(0),.DIV(1)) z(b);
vibrato_ce_case #(.STEP(1),.DIV(3)) o(c);
vibrato_ce_case #(.STEP(32'hffffffff),.DIV(10)) m(d);
initial begin wait(a&&b&&c&&d);$display("PASS: all vibrato enable-equivalence cases");$finish;end
initial begin #1000000;$fatal(1,"FAIL: timeout");end
endmodule
