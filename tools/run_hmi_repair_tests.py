from pathlib import Path
import subprocess,sys,time,json,re
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(__import__('os').environ.get('FPGA_TEST_OUT',r'D:/ChatGPT/Outputs/FPGA-screen-integration-repair-20261102'))
OUT.mkdir(parents=True,exist_ok=True)
name=sys.argv[1];label=sys.argv[2] if len(sys.argv)>2 else 'green'
tb=list((ROOT/'tb').rglob(name+'.sv'));assert len(tb)==1
sources=[str(p) for folder in ['rtl','tb/models','tb/checkers'] for p in (ROOT/folder).rglob('*') if p.suffix in ['.v','.sv'] and not p.name.startswith('tb_')]
for path in re.findall(r'\$dumpfile\("([^"]+)"\)',tb[0].read_text(encoding='utf-8')):
 (OUT/path).parent.mkdir(parents=True,exist_ok=True)
if name in ['tb_top_hmi_protocol_boundary','tb_top_hmi_long_frames','tb_top_looper_record_start','tb_top_screen_param_mode','tb_top_drum_four_cycle','tb_top_key15_uplink']:
 sources=[p for p in sources if not p.replace('\\','/').endswith('/hdmi_scope.v')] + [str(ROOT/'tb/models/hmi_repair_hdmi_stub.vh')]
exe=OUT/(name+'.vvp');start=time.time()
p=subprocess.run(['iverilog',*(['-DHMI_FAST_BAUD'] if label=='fast' else []),'-g2012','-DWAVETABLE_BEHAVIORAL','-s',name,'-o',str(exe),*sources,str(tb[0])],cwd=ROOT,capture_output=True,timeout=60)
(OUT/(name+'.'+label+'.compile.log')).write_bytes(p.stdout+p.stderr)
if p.returncode:print((p.stdout+p.stderr).decode(errors='replace')[-1500:]);sys.exit(p.returncode)
try:
 p=subprocess.run(['vvp',str(exe),'-none'],cwd=OUT,capture_output=True,timeout=600)
except subprocess.TimeoutExpired as e:
 (OUT/(name+'.'+label+'.log')).write_bytes((e.stdout or b'')+(e.stderr or b'')+b'\nTIMEOUT after 600 seconds\n')
 (OUT/(name+'.'+label+'.json')).write_text(json.dumps({'name':name,'pass':False,'timeout':True,'seconds':time.time()-start},indent=2),encoding='utf-8')
 print('TIMEOUT after 600 seconds');sys.exit(1)
(OUT/(name+'.'+label+'.log')).write_bytes(p.stdout+p.stderr)
s=(p.stdout+p.stderr).decode('utf-8',errors='replace');ok=p.returncode==0 and 'PASS' in s and not any(l.startswith('FAIL') for l in s.splitlines())
(OUT/(name+'.'+label+'.json')).write_text(json.dumps({'name':name,'pass':ok,'exit':p.returncode,'seconds':time.time()-start},indent=2),encoding='utf-8')
print(s[-1800:]);sys.exit(0 if ok else 1)
