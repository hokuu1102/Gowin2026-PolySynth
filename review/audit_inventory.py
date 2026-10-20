"""Read tracked sources, record syntax checks and source hashes without executing them."""
import collections
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode('utf-8').split('\0')
extensions = {'.v', '.sv', '.vh', '.py', '.ps1', '.tcl', '.c', '.h', '.html', '.js', '.sdc', '.cst', '.gprj', '.yml', '.yaml', '.cmake'}
sources, errors = [], []
for rel in filter(None, paths):
    p = ROOT / rel
    if p.suffix.lower() not in extensions and p.name not in {'CMakeLists.txt', 'sdkconfig', 'Kconfig.projbuild'}:
        continue
    raw = p.read_bytes()
    item = {'path': rel, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'lines': raw.count(b'\n')}
    if p.suffix.lower() == '.py':
        try:
            compile(raw, rel, 'exec')
            item['python_syntax'] = 'PASS'
        except Exception as e:
            item['python_syntax'] = 'FAIL'
            errors.append({'file': rel, 'error': str(e)})
    sources.append(item)
report = {
    'source': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
    'tracked_files': len(list(filter(None, paths))),
    'source_files': len(sources),
    'by_top_directory': dict(collections.Counter(i['path'].split('/')[0] for i in sources)),
    'by_extension': dict(collections.Counter(Path(i['path']).suffix for i in sources)),
    'python_syntax_errors': errors,
    'sources': sources,
}
(ROOT / 'review' / 'inventory.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k != 'sources'}, ensure_ascii=False, indent=2))
