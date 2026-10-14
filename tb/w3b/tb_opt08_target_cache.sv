`timescale 1ns/1ps
`define NM_STIMULUS \
 .clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick), \
 .note_valid_i(nvalid),.note_axis_i(naxis),.note_phase_inc_i(inc), \
 .note_velocity_i(nvel),.note_kind_i(kind),.note_src_i(nsrc), \
 .vel_upd_valid_i(vvalid),.vel_upd_axis_i(vaxis),.vel_upd_value_i(vval),.vel_upd_src_i(vsrc), \
 .pitch_upd_valid_i(pvalid),.pitch_upd_axis_i(vaxis),.pitch_upd_value_i(inc),.pitch_upd_src_i(vsrc), \
 .default_timbre_i(2'd0),.evt_timbre_valid_i(1'b1),.evt_timbre_i(timbre), \
 .env_active_i(active),.env_level_i(level),.base_semi_i(7'd0),.base_commit_i(1'b0), \
 .transpose_semi_i(5'sd0),.sus_pedal_i(pedal),.event_lost_clr_i(lostclr)
`define NM_OUTPUTS(x) {x.voice_gate_o,x.voice_active_o,x.voice_releasing_o,x.voice_axis_o, \
 x.voice_phase_inc_o,x.voice_velocity_o,x.voice_timbre_o,x.voice_drum_o,x.voice_drum_cls_o, \
 x.voice_age_o,x.voice_retrig_reset_o,x.alloc_valid_o,x.alloc_voice_o,x.event_lost_o,x.event_lost_cnt_o}
module cache_profile #(parameter P=4, parameter SEED=32'h246ab731)(output reg done=0);
 reg clk=0; always #10 clk=~clk;
 reg rst=0,tick=0,nvalid=0,vvalid=0,pvalid=0,pedal=0,lostclr=0;
 reg [3:0] naxis=0,vaxis=0;
 reg [7:0] nvel=0,vval=0;
 reg [2:0] nsrc=0,vsrc=0;
 reg [1:0] kind=0,timbre=0;
 reg [31:0] inc=0;
 reg [P-1:0] active=0;
 reg [P*16-1:0] level=0;
 reg [31:0] rnd=SEED;
 integer cycle=0,j,collisions=0,allocations=0,clears=0;
 function [31:0] step(input [31:0] x);
  reg [31:0] t; begin t=x^(x<<13);t=t^(t>>17);step=t^(t<<5);end
 endfunction
 note_manager #(.POLY_TARGET(P),.AXIS_W(4)) dut (`NM_STIMULUS);
 note_manager_ao_reference #(.POLY_TARGET(P),.AXIS_W(4)) gold (`NM_STIMULUS);
 always @(posedge clk) begin
  #1;
  if (`NM_OUTPUTS(dut) !== `NM_OUTPUTS(gold))
   $fatal(1,"AO public output mismatch P=%0d cycle=%0d",P,cycle);
`ifdef OPT08_NEGATIVE
  if (cycle==30) force dut.voice_velocity_o=0;
`endif
`ifdef OPT08_CACHE
  if (rst) for(j=0;j<P;j=j+1) begin
   if (((dut.src_r[j] == 0) && (dut.vtgt_rep[j] !== dut.vtgt_val[dut.axis_r[j]])) ||
       dut.vtgt_live_vld[j] !== dut.vtgt_vld[dut.axis_r[j]])
    $fatal(1,"Cache invariant P=%0d cycle=%0d voice=%0d axis=%0d",P,cycle,j,dut.axis_r[j]);
  end
`endif
 end
 initial begin
  repeat(4) @(negedge clk);
  rst=1;
  for(cycle=0;cycle<100000;cycle=cycle+1) begin
   @(negedge clk);
   rnd=step(rnd); tick=(cycle%7==0)||(rnd[7:0]==0); nvalid=rnd[0]; vvalid=rnd[1];
   pvalid=rnd[2]&&rnd[3]; pedal=rnd[4]; lostclr=(cycle%313==0);
   rnd=step(rnd); naxis=rnd[3:0];vaxis=rnd[7:4];nvel=rnd[15:8];vval=rnd[23:16];
   nsrc=(rnd[26:24]<4)?0:rnd[26:24]-3;
   vsrc=(rnd[29:27]<4)?0:rnd[29:27]-3;
   kind={1'b0,rnd[30]};timbre=rnd[25:24];
   rnd=step(rnd);inc=rnd;active=rnd;
   for(j=0;j<P;j=j+1) begin rnd=step(rnd);level[j*16+:16]=rnd[15:0];end
   // Actual FSM overlaps, without forcing internal state.
   if (gold.state==gold.ST_DECIDE || gold.state==gold.ST_COMMIT2) begin
    tick=1;vvalid=1;vsrc=0;
    vaxis=(gold.state==gold.ST_COMMIT2)?gold.cmt_axis_r:gold.cur_axis;
    vval=cycle[7:0];collisions=collisions+1;
   end
   if(gold.state==gold.ST_COMMIT2 && gold.cmt_en_r) allocations=allocations+1;
   if(gold.state==gold.ST_DECIDE && gold.cur_src==0 &&
      (gold.cur_kind==gold.KIND_OFF || gold.same_valid)) clears=clears+1;
   if(cycle==49999 || cycle==75000) rst=0;
   else rst=1;
  end
  @(negedge clk);nvalid=0;vvalid=0;pvalid=0;tick=0;
  repeat(80) @(negedge clk);
  if(collisions<100 || allocations<50 || clears<50)
   $fatal(1,"Vacuous stress P=%0d overlap=%0d alloc=%0d clear=%0d",P,collisions,allocations,clears);
  $display("PASS cache stress P=%0d cycles=100000 overlap=%0d alloc=%0d clear=%0d",P,collisions,allocations,clears);
  done=1;
 end
endmodule
module tb_opt08_target_cache;
 wire [1:0] done;
 cache_profile #(.P(4)) a(done[0]);
 cache_profile #(.P(32),.SEED(32'h12345abc)) b(done[1]);
 initial begin wait(&done);$display("PASS: AO/cache differential 200000 profile-cycles");$finish;end
 initial begin #2100000;$fatal(1,"Timeout");end
endmodule
`undef NM_STIMULUS
`undef NM_OUTPUTS
