"""Summarize only test names selected by this run and logs newer than its start."""
import collections
from datetime import datetime
import json
from pathlib import Path
import re
import shutil

root = Path(__file__).resolve().parents[1]
meta_file=root/'review/regression_exit.json'
if not meta_file.is_file():
    raise SystemExit('Regression has not reached a terminal state; do not summarize as complete.')
meta=json.loads(meta_file.read_text(encoding='utf-8-sig'))
started=datetime.fromisoformat(meta['started_utc'].replace('Z','+00:00')).timestamp()
def read(path):
    raw=path.read_bytes()
    return raw.decode('utf-16' if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')
full=read(root/'review/regression.log')
names=re.findall(r'=== 编译 (\S+) ===',full)
skips={'tb_export_wav','tb_export_key_wav','tb_at_merge_known_bugs'}
cases=[]
archive=root/'review/regression_evidence'
archive.mkdir(exist_ok=True)
for name in names:
    compiled=root/f'sim/evidence/{name}.compile.log'
    run=root/f'sim/evidence/{name}.log'
    item={'test':name,'per_test_native_exit':'not retained by the unmodified production runner'}
    if name in skips:
        status='SKIPPED_BY_DEFAULT'
    elif not compiled.is_file() or compiled.stat().st_mtime<started:
        status='MISSING_FRESH_COMPILE_LOG'
    elif not run.is_file() or run.stat().st_mtime<started:
        status='NO_FRESH_RUN_LOG'
    else:
        text=read(run)
        if 'FAIL: TIMEOUT' in text:
            status='TIMEOUT_INCOMPLETE'
        elif name=='tb_opt04_nm_age_negative' and len(re.findall(r'(?m)^FATAL:.*split age mismatch width=(?:1|7|16|17)\b',text))==4:
            status='EXPECTED_NEGATIVE_DETECTED'
        elif re.search(r'(?m)^[ \t]*[^A-Za-z]*FAIL:|^FATAL:',text):
            status='ASSERTION_OR_RUNTIME_FAILURE'
        elif re.search(r'(?m)^.*\bPASS(?:[: ]|$)',text):
            status='DIAGNOSTIC_COMPLETED' if name=='tb_demo_stall_diag' else 'OBSERVED_PASS'
        else:
            status='NO_EXPLICIT_PASS'
        item['log']=str(run.relative_to(root))
        item['tail']=text.splitlines()[-8:]
    item['status']=status
    for evidence in (compiled,run):
        if evidence.is_file() and evidence.stat().st_mtime>=started:
            shutil.copy2(evidence,archive/evidence.name)
    item['archived_fresh_evidence_directory']='review/regression_evidence'
    cases.append(item)
summary=re.search(r'================ 汇总 ================(.*)',full,re.S)
result={'metadata':meta,'selected_testbenches':len(names),'observed_status_counts':dict(collections.Counter(c['status'] for c in cases)),
        'production_runner_summary':summary.group(1).strip() if summary else None,'cases':cases}
(root/'review/regression_summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='cases'},ensure_ascii=True,indent=2))
