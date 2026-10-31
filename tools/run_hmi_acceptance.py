"""Run selected HMI integration checks; preserve full test assertions and external logs."""
from pathlib import Path
import subprocess,json,re,time,concurrent.futures
ROOT=Path(__file__).resolve().parents[1]
OUT=Path('D:/ChatGPT/Outputs/FPGA-51-HMI-checks')/time.strftime('%Y%m%d-%H%M%S');OUT.mkdir(parents=True,exist_ok=True)
names=['tb_bpm_o_probe', 'tb_guide_lamp', 'tb_guide_lamp_capacity', 'tb_guide_lamp_cycle_equiv', 'tb_guide_lamp_identity', 'tb_guide_lamp_local_equiv', 'tb_lamp_stuck_clear', 'tb_looper_e2e', 'tb_play_seq', 'tb_right_analog_ctrl', 'tb_score_chain', 'tb_test_mode_top', 'tb_top_ctrl_wire', 'tb_top_diag_upstream_atomic', 'tb_top_dump_atomic', 'tb_top_ec11_param', 'tb_top_fx_audio', 'tb_top_fx_runtime', 'tb_top_fxstat_uart', 'tb_top_guide_axes', 'tb_top_guide_bit6', 'tb_top_hmi_bpm', 'tb_top_hmi_integration', 'tb_top_keydrum_score_isolation', 'tb_top_looper_pedals', 'tb_top_reject_notice_queue', 'tb_top_score_path', 'tb_top_uart_isolation', 'tb_top_upstream_timbre', 'tb_uart_ui']
import sys
if '--help' in sys.argv:
 print('Run 30 selected HMI/51-baseline checks. Usage: python tools/run_hmi_acceptance.py [tb_name ...]. Outputs: '+str(OUT));raise SystemExit(0)
if len(sys.argv)>1:names=sys.argv[1:]
rtl=[str(p) for p in (ROOT/'rtl').rglob('*') if p.suffix in ['.v','.sv']]
models=[str(p) for folder in ['tb/models','tb/checkers'] for p in (ROOT/folder).rglob('*') if p.suffix in ['.v','.sv']]
def run(name):
 start=time.time();tb=list((ROOT/'tb').rglob(name+'.sv'));assert len(tb)==1,name
 binary=OUT/(name+'.vvp')
 with (OUT/(name+'.compile.log')).open('wb') as f:c=subprocess.run(['iverilog','-g2012','-DWAVETABLE_BEHAVIORAL','-s',name,'-o',str(binary),*rtl,*models,str(tb[0])],cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
 ok=False
 if c.returncode==0:
  try:
   with (OUT/(name+'.log')).open('wb') as f:c=subprocess.run(['vvp',str(binary),'-none'],cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,timeout=3600)
   log=(OUT/(name+'.log')).read_text(errors='replace');ok=c.returncode==0 and not re.search(r'^\s*(FAIL|FATAL)',log,re.M) and 'PASS' in log
  except subprocess.TimeoutExpired:pass
 r={'name':name,'pass':bool(ok),'seconds':round(time.time()-start,2)};(OUT/(name+'.result.json')).write_text(json.dumps(r,indent=2));print(json.dumps(r),flush=True);return r
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,names))
 (OUT/'summary.json').write_text(json.dumps(results,indent=2));raise SystemExit(int(any(not r['pass'] for r in results)))
