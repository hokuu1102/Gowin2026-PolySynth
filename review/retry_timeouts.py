"""Re-run two timed-out unchanged simulation images, retaining real native exits."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

root=Path(__file__).resolve().parents[1]
out=root/'review/retries'
out.mkdir(exist_ok=True)
source='cd63b0773480e43b19d47f7b541d202a0a66df4d'
subprocess.run(['git','diff','--quiet',source,'--','.',':(exclude)review/**',':(exclude)sim/evidence/**',':(exclude)evidence/**'],cwd=root,check=True)
tests=['tb_e2e_key_to_sound','tb_sustain_pedal_wire']
def run(name):
    original=root/f'build/sim/{name}/{name}.vvp'
    image=out/f'{name}.vvp'
    shutil.copyfile(original,image)
    record={'source':source,'test':name,'image_sha256':hashlib.sha256(image.read_bytes()).hexdigest(),
            'timeout_seconds':1800,'original_rtl_and_assertions_unchanged':True,'started_utc':datetime.now(timezone.utc).isoformat()}
    cmd=['D:/iverilog/bin/vvp.exe',str(image)]
    record['command']=cmd
    start=time.monotonic()
    timed_out=False
    with (out/f'{name}.log').open('wb') as log:
        proc=subprocess.Popen(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT)
        record['pid']=proc.pid
        (out/f'{name}.running.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
        try:
            proc.wait(timeout=1800)
        except subprocess.TimeoutExpired:
            timed_out=True
            proc.kill()
            proc.wait()
    text=(out/f'{name}.log').read_text(encoding='utf-8-sig',errors='replace')
    record.update({'finished_utc':datetime.now(timezone.utc).isoformat(),'seconds':round(time.monotonic()-start,2),
                   'actual_native_exit':proc.returncode,'timed_out':timed_out})
    passed=not timed_out and proc.returncode==0 and re.search(r'(?m)^.*\bPASS(?:[: ]|$)',text) and not re.search(r'(?m)^[ \t]*[^A-Za-z]*FAIL:|^FATAL:',text)
    record['status']='PASS' if passed else ('INCOMPLETE_TIMEOUT' if timed_out else 'FAIL')
    (out/f'{name}.result.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    print(json.dumps(record),flush=True)
    return record
with ThreadPoolExecutor(max_workers=2) as pool:
    records=list(pool.map(run,tests))
result={'source':source,'results':records,'all_passed':all(x['status']=='PASS' for x in records)}
(root/'review/retries_exit.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
raise SystemExit(not result['all_passed'])
