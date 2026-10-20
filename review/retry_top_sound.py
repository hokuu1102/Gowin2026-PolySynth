"""Run unchanged images with isolated file output and an explicit budget."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--test',choices=['tb_top_sound','tb_top_upstream_timbre','tb_top_ec11_param','tb_bg_envelope_cycle_equiv','tb_nm_no_leak'],default='tb_top_sound')
parser.add_argument('--timeout',type=int,default=1800)
parser.add_argument('--no-wave',action='store_true')
args=parser.parse_args()
name=args.test
source='cd63b0773480e43b19d47f7b541d202a0a66df4d'
subprocess.run(['git','diff','--quiet',source,'--','.',':(exclude)review/**',':(exclude)sim/evidence/**',':(exclude)evidence/**'],cwd=root,check=True)
out=root/('review/retries/'+name.removeprefix('tb_')+'_workspace')
(out/'sim/evidence').mkdir(parents=True,exist_ok=True)
(out/'build/sim'/name).mkdir(parents=True,exist_ok=True)
original=root/f'build/sim/{name}/{name}.vvp'
image=out/f'{name}.vvp'
shutil.copyfile(original,image)
record={'source':source,'test':name,'original_rtl_and_assertions_unchanged':True,
        'image_sha256':hashlib.sha256(image.read_bytes()).hexdigest(),
        'working_directory':str(out),'timeout_seconds':args.timeout,'waveform_dump_suppressed':args.no_wave,
        'started_utc':datetime.now(timezone.utc).isoformat()}
cmd=['D:/iverilog/bin/vvp.exe','-i',str(image)]
if args.no_wave:
    cmd.append('-none')
record['command']=cmd
start=time.monotonic()
timed_out=False
with (out/'run.log').open('wb') as log:
    proc=subprocess.Popen(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT)
    record['pid']=proc.pid
    (root/f'review/retries/{name}.running.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    try:
        proc.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out=True
        proc.kill()
        proc.wait()
text=(out/'run.log').read_text(encoding='utf-8-sig',errors='replace')
passed=not timed_out and proc.returncode==0 and re.search(r'(?m)^PASS:',text) and not re.search(r'(?m)^FATAL:|^FAIL:',text)
record.update({'finished_utc':datetime.now(timezone.utc).isoformat(),
               'seconds':round(time.monotonic()-start,2),'actual_native_exit':proc.returncode,
               'timed_out':timed_out,'status':'PASS' if passed else ('INCOMPLETE_TIMEOUT' if timed_out else 'FAIL')})
(root/f'review/retries/{name}.result.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
print(json.dumps(record,indent=2))
raise SystemExit(not passed)
