from pathlib import Path
import re, subprocess, json
E=Path(__file__).resolve().parent
R=E.parents[1]
old=(E/'baseline/rtl/w3b/note_manager.v').read_text(encoding='utf-8')
(E/'note_manager_ref.v').write_text(old.replace('module note_manager #','module note_manager_ref #'),encoding='utf-8')
ports=re.findall(r'^\s*(input|output)\s+wire\s*(\[[^\]]+\])?\s*(\w+)',old,re.M)
s='''`timescale 1ns/1ps
module tb_scan_diff;
localparam POLY_TARGET=32, AXIS_W=4, PHASE_W=32, VEL_W=8, TIMBRE_W=2,
 ENV_W=16, AGE_W=16, IDX_W=5, EVT_LOST_CNT_W=8;
'''
for direction,width,name in ports:
    if direction=='input': s+=f'reg {width} {name}=0;\n'
for mod,inst in [('note_manager','dut'),('note_manager_ref','refdut')]:
    s+=f'{mod} #(.RESERVED_N(5)) {inst} (\n'+',\n'.join(f'.{name}({name})' if d=='input' else f'.{name}()' for d,w,name in ports)+'\n);\n'
s+='''always #10 clk_i=~clk_i;
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
'''
signals=[n for d,w,n in ports if d=='output']+['state','scan_cnt','best_valid','best_idx','best_cls','best_env','best_age','cand_idx','cand_hold','cand_pool','cand_free','cand_rel','cand_foreign','cand_cls','cand_env','cand_age','cand_ok','cand_better','cmt_en_r','cmt_idx_r','fifo_cnt','fifo_rd','fifo_wr','same_en_r','same_idx_r','retrig_low']
for name in signals:
    s+=f'  if(dut.{name} !== refdut.{name}) $fatal(1,"FAIL differential {name} cycle=%0d",cycles);\n'
s+='''end
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
'''
(E/'tb_scan_diff.sv').write_text(s,encoding='utf-8')
def run(label,src):
    cmd=['iverilog','-g2012','-s','tb_scan_diff','-o',str(E/(label+'.vvp')),str(src),str(E/'note_manager_ref.v'),str(E/'tb_scan_diff.sv')]
    c=subprocess.run(cmd,capture_output=True)
    (E/(label+'.compile.log')).write_bytes(c.stdout+c.stderr)
    assert c.returncode==0,c.stderr.decode(errors='replace')
    p=subprocess.run(['vvp',str(E/(label+'.vvp'))],capture_output=True,timeout=45)
    (E/(label+'.log')).write_bytes(p.stdout+p.stderr)
    print(label,p.returncode,p.stdout.decode(errors='replace')[-1200:])
    return p.returncode
src=R/'rtl/w3b/note_manager.v'
assert run('green',src)==0
mutant=src.read_text(encoding='utf-8').replace('scan_sel <= scan_sel << 1;','scan_sel <= scan_sel << 2;')
(E/'mutant_shift2.v').write_text(mutant,encoding='utf-8')
assert run('red_shift2',E/'mutant_shift2.v')!=0
print('PASS red-green: shift-by-two mutant rejected; production RTL unmodified')
