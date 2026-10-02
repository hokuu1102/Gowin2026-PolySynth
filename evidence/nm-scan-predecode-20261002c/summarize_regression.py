from pathlib import Path
import json, re, shutil

E = Path(__file__).resolve().parent
R = E.parents[1]
raw = (E/'regression.log').read_bytes()
text = raw.decode('utf-16') if raw.startswith(b'\xff\xfe') else raw.decode('utf-8-sig')
summary = re.findall(r'通过 (\d+) / 共 (\d+)', text)
assert len(summary) == 1, 'Regression has no final summary'
passed, total = map(int, summary[0])
exit_code = int((E/'regression-exit.txt').read_text(encoding='utf-8-sig').strip())
names = re.findall(r'^=== 运行 (\S+) ===', text, re.M)
skips = re.findall(r'\[skip\] (\S+)', text)
executed = [n for n in names if n not in skips]
assert len(executed) == total, (len(executed), total)
start = json.loads((E/'build-1/started.json').read_text())['unix_time']
dest = E/'regression-logs'
dest.mkdir(exist_ok=True)
results = []
for n in executed:
    p = R/'sim/evidence'/f'{n}.log'
    assert p.stat().st_mtime >= start, f'Stale log: {p}'
    s = p.read_text(encoding='utf-8-sig')
    results.append({'test':n, 'has_PASS_colon': bool(re.search(r'(?m)^\s*PASS:',s)),
                    'has_PASS_token': bool(re.search(r'\bPASS\b',s)),
                    'has_FAIL_colon': bool(re.search(r'(?m)^[ \t]*[^A-Za-z]*FAIL:',s))})
    for suffix in ['.log','.compile.log']:
        source = R/'sim/evidence'/(n+suffix)
        if source.exists(): shutil.copy2(source,dest/source.name)
out = {'script_passed':passed, 'script_total':total, 'exit_code':exit_code,
       'logs_with_PASS_colon':sum(r['has_PASS_colon'] for r in results),
       'logs_with_PASS_token':sum(r['has_PASS_token'] for r in results),
       'skipped_tools_excluded':skips, 'tests':results}
(E/'regression-summary.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in out.items() if k!='tests'},indent=2))
assert exit_code==0 and passed==total
assert not any(r['has_FAIL_colon'] for r in results)
