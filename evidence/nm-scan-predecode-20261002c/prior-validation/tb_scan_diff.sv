`timescale 1ns/1ps
module tb_scan_diff;
localparam POLY_TARGET=32, AXIS_W=4, PHASE_W=32, VEL_W=8, TIMBRE_W=2,
 ENV_W=16, AGE_W=16, IDX_W=5, EVT_LOST_CNT_W=8;
reg  clk_i=0;
reg  rst_n_i=0;
reg  sample_tick_i=0;
reg  note_valid_i=0;
reg [AXIS_W-1:0] note_axis_i=0;
reg [PHASE_W-1:0] note_phase_inc_i=0;
reg [VEL_W-1:0] note_velocity_i=0;
reg [1:0] note_kind_i=0;
reg [2:0] note_src_i=0;
reg  vel_upd_valid_i=0;
reg [AXIS_W-1:0] vel_upd_axis_i=0;
reg [VEL_W-1:0] vel_upd_value_i=0;
reg  pitch_upd_valid_i=0;
reg [AXIS_W-1:0] pitch_upd_axis_i=0;
reg [PHASE_W-1:0] pitch_upd_value_i=0;
reg [2:0] vel_upd_src_i=0;
reg [2:0] pitch_upd_src_i=0;
reg [TIMBRE_W-1:0] default_timbre_i=0;
reg  evt_timbre_valid_i=0;
reg [TIMBRE_W-1:0] evt_timbre_i=0;
reg [POLY_TARGET-1:0] env_active_i=0;
reg [POLY_TARGET*ENV_W-1:0] env_level_i=0;
reg [6:0] base_semi_i=0;
reg  base_commit_i=0;
reg  event_lost_clr_i=0;
note_manager #(.RESERVED_N(5)) dut (
.clk_i(clk_i),
.rst_n_i(rst_n_i),
.sample_tick_i(sample_tick_i),
.note_valid_i(note_valid_i),
.note_axis_i(note_axis_i),
.note_phase_inc_i(note_phase_inc_i),
.note_velocity_i(note_velocity_i),
.note_kind_i(note_kind_i),
.note_src_i(note_src_i),
.vel_upd_valid_i(vel_upd_valid_i),
.vel_upd_axis_i(vel_upd_axis_i),
.vel_upd_value_i(vel_upd_value_i),
.pitch_upd_valid_i(pitch_upd_valid_i),
.pitch_upd_axis_i(pitch_upd_axis_i),
.pitch_upd_value_i(pitch_upd_value_i),
.vel_upd_src_i(vel_upd_src_i),
.pitch_upd_src_i(pitch_upd_src_i),
.default_timbre_i(default_timbre_i),
.evt_timbre_valid_i(evt_timbre_valid_i),
.evt_timbre_i(evt_timbre_i),
.env_active_i(env_active_i),
.env_level_i(env_level_i),
.base_semi_i(base_semi_i),
.base_commit_i(base_commit_i),
.voice_gate_o(),
.voice_active_o(),
.voice_releasing_o(),
.voice_axis_o(),
.voice_phase_inc_o(),
.voice_velocity_o(),
.voice_timbre_o(),
.voice_drum_o(),
.voice_age_o(),
.voice_retrig_reset_o(),
.alloc_valid_o(),
.alloc_voice_o(),
.event_lost_o(),
.event_lost_cnt_o(),
.event_lost_clr_i(event_lost_clr_i)
);
note_manager_ref #(.RESERVED_N(5)) refdut (
.clk_i(clk_i),
.rst_n_i(rst_n_i),
.sample_tick_i(sample_tick_i),
.note_valid_i(note_valid_i),
.note_axis_i(note_axis_i),
.note_phase_inc_i(note_phase_inc_i),
.note_velocity_i(note_velocity_i),
.note_kind_i(note_kind_i),
.note_src_i(note_src_i),
.vel_upd_valid_i(vel_upd_valid_i),
.vel_upd_axis_i(vel_upd_axis_i),
.vel_upd_value_i(vel_upd_value_i),
.pitch_upd_valid_i(pitch_upd_valid_i),
.pitch_upd_axis_i(pitch_upd_axis_i),
.pitch_upd_value_i(pitch_upd_value_i),
.vel_upd_src_i(vel_upd_src_i),
.pitch_upd_src_i(pitch_upd_src_i),
.default_timbre_i(default_timbre_i),
.evt_timbre_valid_i(evt_timbre_valid_i),
.evt_timbre_i(evt_timbre_i),
.env_active_i(env_active_i),
.env_level_i(env_level_i),
.base_semi_i(base_semi_i),
.base_commit_i(base_commit_i),
.voice_gate_o(),
.voice_active_o(),
.voice_releasing_o(),
.voice_axis_o(),
.voice_phase_inc_o(),
.voice_velocity_o(),
.voice_timbre_o(),
.voice_drum_o(),
.voice_age_o(),
.voice_retrig_reset_o(),
.alloc_valid_o(),
.alloc_voice_o(),
.event_lost_o(),
.event_lost_cnt_o(),
.event_lost_clr_i(event_lost_clr_i)
);
always #10 clk_i=~clk_i;
integer cycles=0, scans=0, aborted=0, visits=0, updates=0, max_updates=0;
integer allocations=0, empty_scans=0, phase_hits=0;
reg [31:0] seen=0;
reg [2:0] prev_state=0;
reg [31:0] prev_sel=1;
integer prev_idx=0;
always @(posedge clk_i) begin
  if (!rst_n_i) begin
    if (visits!=0) aborted=aborted+1;
    visits=0; seen=0; updates=0;
  end else if (dut.state==2) begin
    if (dut.scan_cnt!==visits || seen[dut.scan_cnt])
      $fatal(1,"FAIL visit order/duplicate idx=%0d visits=%0d",dut.scan_cnt,visits);
    seen[dut.scan_cnt]=1; visits=visits+1;
    if (dut.cand_ok && dut.cand_better) updates=updates+1;
    if (dut.scan_cnt==31) begin
      if (seen!==32'hffffffff || visits!=32) $fatal(1,"FAIL missing candidate");
      scans=scans+1; visits=0; seen=0;
      if (updates>max_updates) max_updates=updates;
      updates=0;
    end
  end
  prev_state=dut.state; prev_sel=dut.scan_sel; prev_idx=dut.scan_cnt;
  #1;
  cycles=cycles+1;
  if (dut.scan_sel !== (32'b1 << dut.scan_cnt))
    $fatal(1,"FAIL onehot alignment cycle=%0d idx=%0d sel=%h",cycles,dut.scan_cnt,dut.scan_sel);
  if (rst_n_i && prev_state==2 && prev_idx==31 && dut.scan_sel!==prev_sel)
    $fatal(1,"FAIL final item wrapped early");
  if (dut.alloc_valid_o) begin
    allocations=allocations+1;
    if(sample_tick_i) phase_hits=phase_hits+1;
  end
  if(dut.voice_gate_o !== refdut.voice_gate_o) $fatal(1,"FAIL differential voice_gate_o cycle=%0d",cycles);
  if(dut.voice_active_o !== refdut.voice_active_o) $fatal(1,"FAIL differential voice_active_o cycle=%0d",cycles);
  if(dut.voice_releasing_o !== refdut.voice_releasing_o) $fatal(1,"FAIL differential voice_releasing_o cycle=%0d",cycles);
  if(dut.voice_axis_o !== refdut.voice_axis_o) $fatal(1,"FAIL differential voice_axis_o cycle=%0d",cycles);
  if(dut.voice_phase_inc_o !== refdut.voice_phase_inc_o) $fatal(1,"FAIL differential voice_phase_inc_o cycle=%0d",cycles);
  if(dut.voice_velocity_o !== refdut.voice_velocity_o) $fatal(1,"FAIL differential voice_velocity_o cycle=%0d",cycles);
  if(dut.voice_timbre_o !== refdut.voice_timbre_o) $fatal(1,"FAIL differential voice_timbre_o cycle=%0d",cycles);
  if(dut.voice_drum_o !== refdut.voice_drum_o) $fatal(1,"FAIL differential voice_drum_o cycle=%0d",cycles);
  if(dut.voice_age_o !== refdut.voice_age_o) $fatal(1,"FAIL differential voice_age_o cycle=%0d",cycles);
  if(dut.voice_retrig_reset_o !== refdut.voice_retrig_reset_o) $fatal(1,"FAIL differential voice_retrig_reset_o cycle=%0d",cycles);
  if(dut.alloc_valid_o !== refdut.alloc_valid_o) $fatal(1,"FAIL differential alloc_valid_o cycle=%0d",cycles);
  if(dut.alloc_voice_o !== refdut.alloc_voice_o) $fatal(1,"FAIL differential alloc_voice_o cycle=%0d",cycles);
  if(dut.event_lost_o !== refdut.event_lost_o) $fatal(1,"FAIL differential event_lost_o cycle=%0d",cycles);
  if(dut.event_lost_cnt_o !== refdut.event_lost_cnt_o) $fatal(1,"FAIL differential event_lost_cnt_o cycle=%0d",cycles);
  if(dut.state !== refdut.state) $fatal(1,"FAIL differential state cycle=%0d",cycles);
  if(dut.scan_cnt !== refdut.scan_cnt) $fatal(1,"FAIL differential scan_cnt cycle=%0d",cycles);
  if(dut.best_valid !== refdut.best_valid) $fatal(1,"FAIL differential best_valid cycle=%0d",cycles);
  if(dut.best_idx !== refdut.best_idx) $fatal(1,"FAIL differential best_idx cycle=%0d",cycles);
  if(dut.best_cls !== refdut.best_cls) $fatal(1,"FAIL differential best_cls cycle=%0d",cycles);
  if(dut.best_env !== refdut.best_env) $fatal(1,"FAIL differential best_env cycle=%0d",cycles);
  if(dut.best_age !== refdut.best_age) $fatal(1,"FAIL differential best_age cycle=%0d",cycles);
  if(dut.cand_idx !== refdut.cand_idx) $fatal(1,"FAIL differential cand_idx cycle=%0d",cycles);
  if(dut.cand_hold !== refdut.cand_hold) $fatal(1,"FAIL differential cand_hold cycle=%0d",cycles);
  if(dut.cand_pool !== refdut.cand_pool) $fatal(1,"FAIL differential cand_pool cycle=%0d",cycles);
  if(dut.cand_free !== refdut.cand_free) $fatal(1,"FAIL differential cand_free cycle=%0d",cycles);
  if(dut.cand_rel !== refdut.cand_rel) $fatal(1,"FAIL differential cand_rel cycle=%0d",cycles);
  if(dut.cand_foreign !== refdut.cand_foreign) $fatal(1,"FAIL differential cand_foreign cycle=%0d",cycles);
  if(dut.cand_cls !== refdut.cand_cls) $fatal(1,"FAIL differential cand_cls cycle=%0d",cycles);
  if(dut.cand_env !== refdut.cand_env) $fatal(1,"FAIL differential cand_env cycle=%0d",cycles);
  if(dut.cand_age !== refdut.cand_age) $fatal(1,"FAIL differential cand_age cycle=%0d",cycles);
  if(dut.cand_ok !== refdut.cand_ok) $fatal(1,"FAIL differential cand_ok cycle=%0d",cycles);
  if(dut.cand_better !== refdut.cand_better) $fatal(1,"FAIL differential cand_better cycle=%0d",cycles);
  if(dut.cmt_en_r !== refdut.cmt_en_r) $fatal(1,"FAIL differential cmt_en_r cycle=%0d",cycles);
  if(dut.cmt_idx_r !== refdut.cmt_idx_r) $fatal(1,"FAIL differential cmt_idx_r cycle=%0d",cycles);
  if(dut.fifo_cnt !== refdut.fifo_cnt) $fatal(1,"FAIL differential fifo_cnt cycle=%0d",cycles);
  if(dut.fifo_rd !== refdut.fifo_rd) $fatal(1,"FAIL differential fifo_rd cycle=%0d",cycles);
  if(dut.fifo_wr !== refdut.fifo_wr) $fatal(1,"FAIL differential fifo_wr cycle=%0d",cycles);
  if(dut.same_en_r !== refdut.same_en_r) $fatal(1,"FAIL differential same_en_r cycle=%0d",cycles);
  if(dut.same_idx_r !== refdut.same_idx_r) $fatal(1,"FAIL differential same_idx_r cycle=%0d",cycles);
  if(dut.retrig_low !== refdut.retrig_low) $fatal(1,"FAIL differential retrig_low cycle=%0d",cycles);
end
task reset_dut;
begin
 @(negedge clk_i); rst_n_i=0; note_valid_i=0; sample_tick_i=0;
 repeat(2) @(negedge clk_i);
 rst_n_i=1;
end endtask
task send_on;
begin
 note_valid_i=1; note_kind_i=0; note_axis_i=7; note_velocity_i=199;
 note_phase_inc_i=32'h12345678;
 @(negedge clk_i); note_valid_i=0;
end endtask
integer k,m,expected,phase,abort_at,start_alloc,seed=32'h1234;
task wait_commit;
input integer winner;
integer deadline;
begin
 deadline=0;
 while(dut.state!=4) begin
   @(negedge clk_i); deadline=deadline+1;
   if(deadline>40) $fatal(1,"FAIL commit timeout");
 end
 if(winner<0) begin
   if(dut.cmt_en_r!==0) $fatal(1,"FAIL no-legal candidate committed");
   empty_scans=empty_scans+1;
 end else if(dut.cmt_en_r!==1 || dut.cmt_idx_r!==winner)
   $fatal(1,"FAIL priority expected=%0d actual=%0d",winner,dut.cmt_idx_r);
 @(negedge clk_i);
 if(winner>=0 && (!dut.alloc_valid_o || dut.alloc_voice_o!==winner))
   $fatal(1,"FAIL allocation latency/index");
end endtask
initial begin
 // Every index must be independently selectable, including both group boundaries
 // and last voice 31 in the reserved pool.
 for(m=0;m<32;m=m+1) begin
   reset_dut(); note_src_i=(m>=27)?3:0; env_active_i=32'hffffffff;
   for(k=0;k<32;k=k+1) begin
     dut.gate_r[k]=1; refdut.gate_r[k]=1;
     dut.axis_r[k]=2; refdut.axis_r[k]=2;
     dut.age_r[k]=k; refdut.age_r[k]=k;
   end
   dut.gate_r[m]=0; refdut.gate_r[m]=0; env_active_i[m]=0;
   send_on(); wait_commit(m);
 end
 // Priority, ties, continuous improvements, excluded hold/foreign, empty pool.
 for(m=0;m<8;m=m+1) begin
   reset_dut(); note_src_i=0; env_active_i=(m==0)?0:32'hffffffff;
   for(k=0;k<32;k=k+1) begin
     dut.gate_r[k]=(m==3 || m==6 || m==7);
     refdut.gate_r[k]=(m==3 || m==6 || m==7);
     dut.axis_r[k]=2; refdut.axis_r[k]=2;
     dut.src_r[k]=1; refdut.src_r[k]=1;
     dut.age_r[k]=100+k; refdut.age_r[k]=100+k;
     env_level_i[k*16+:16]=(m==4)?100:1000-k;
   end
   expected=(m==0 || m==4)?0:26;
   if(m==5) begin
     dut.retrig_low=32'hffffffff; refdut.retrig_low=32'hffffffff; expected=-1;
   end
   if(m==6) begin
     dut.axis_r[26]=7; refdut.axis_r[26]=7; expected=25;
   end
   if(m==7) begin
     dut.retrig_low[26]=1; refdut.retrig_low[26]=1; expected=25;
   end
   send_on(); wait_commit(expected);
 end
 // Reset flush at every scan position, then fresh allocation.
 for(abort_at=0;abort_at<32;abort_at=abort_at+1) begin
   reset_dut(); env_active_i=0; note_src_i=0; send_on();
   while(!(dut.state==2 && dut.scan_cnt==abort_at)) @(negedge clk_i);
   reset_dut(); send_on(); wait_commit(0);
 end
 // Sweep tick across event capture, first/last scan, commit, and adjacent edges.
 for(phase=0;phase<42;phase=phase+1) begin
   reset_dut(); env_active_i=0; note_src_i=0; start_alloc=allocations;
   note_valid_i=1; note_axis_i=7;
   for(k=0;k<45;k=k+1) begin
     sample_tick_i=(k==phase);
     @(negedge clk_i); note_valid_i=0;
   end
   sample_tick_i=0;
   if(allocations!=start_alloc+1) $fatal(1,"FAIL phase sweep missing allocation");
 end
 // Deterministic changing inputs, FIFO traffic, all sources, tick overlap.
 reset_dut();
 for(m=0;m<20000;m=m+1) begin
   @(negedge clk_i);
   sample_tick_i=(m%17==0);
   note_valid_i=(m%11==0);
   note_axis_i=$random(seed); note_src_i=($unsigned($random(seed))%5);
   note_kind_i=($unsigned($random(seed))%3);
   note_velocity_i=$random(seed); note_phase_inc_i=$random(seed);
   env_active_i=$random(seed);
   for(k=0;k<32;k=k+1) env_level_i[k*16+:16]=$random(seed);
 end
 @(negedge clk_i); note_valid_i=0;
 repeat(1600) @(negedge clk_i);
 if(max_updates<27 || empty_scans<1 || scans<100 || aborted<30 || phase_hits<1)
   $fatal(1,"FAIL coverage scans=%0d max_updates=%0d empty=%0d aborted=%0d phases=%0d",scans,max_updates,empty_scans,aborted,phase_hits);
 $display("PASS cycles=%0d differences=0 scans=%0d max_consecutive_updates=%0d empty=%0d reset_aborts=%0d allocations=%0d tick_on_alloc=%0d all_indices=32 phase_offsets=42",cycles,scans,max_updates,empty_scans,aborted,allocations,phase_hits);
 $finish;
end
initial begin #2000000; $fatal(1,"FAIL global timeout"); end
endmodule
