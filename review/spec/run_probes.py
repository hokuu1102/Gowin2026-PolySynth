import pathlib,subprocess,sys,json,time
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=pathlib.Path(__file__).resolve().parent
py=str(OUT/'venv/Scripts/python.exe')
jobs=[('web-probe',['node','review/spec/web_probe.js']),('python-probe',[py,'review/spec/python_probe.py']),('host-probe',[py,'review/spec/host_probe.py']),('pool-interleave',[py,'review/spec/pool_interleave_probe.py']),('html-syntax',[py,'esp32/tools/_check_html_js.py']),('selftest-complete',[py,'esp32/tools/selftest_all.py','-v']),('inventory',[py,'review/spec/inventory.py'])]
results=[]
for name,cmd in jobs:
 start=time.monotonic();r=subprocess.run(cmd,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/(name+'.log')).write_bytes(r.stdout)
 rec={'name':name,'command':cmd,'exit':r.returncode,'seconds':round(time.monotonic()-start,2)};results.append(rec);print(json.dumps(rec),flush=True)
(OUT/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
sys.exit(any(r['exit']!=0 for r in results))
