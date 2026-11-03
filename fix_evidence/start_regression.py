from pathlib import Path
import concurrent.futures, subprocess, json, time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'fix_evidence/regression'
OUT.mkdir(exist_ok=True)
skip={'tb_at_merge_known_bugs','tb_export_key_wav','tb_export_wav'}
tests=sorted(p.stem for p in (ROOT/'tb').rglob('tb_*.sv') if p.stem not in skip)
assert len(tests)==len(set(tests))
def run(name):
    started=time.time()
    cmd=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File','sim/tb_all.ps1','-Filter',name,'-ExactFilter','-NoWave','-TimeoutScale','4']
    with (OUT/(name+'.runner.log')).open('wb') as f:
        p=subprocess.run(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
    result={'name':name,'exit':p.returncode,'seconds':round(time.time()-started,2)}
    (OUT/(name+'.json')).write_text(json.dumps(result))
    print(json.dumps(result),flush=True)
    return result
if __name__=='__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(run,tests))
    (OUT/'summary.json').write_text(json.dumps(results,indent=2))
    raise SystemExit(int(any(r['exit'] for r in results)))
