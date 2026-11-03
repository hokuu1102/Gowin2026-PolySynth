"""Run the production reference resolver on only the fixed tracked Markdown set."""
import importlib.util
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('production_refcheck', root / 'tools/check_doc_refs.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tracked = set(filter(None, subprocess.check_output(['git','ls-files','-z'], cwd=root).decode('utf-8').split('\0')))
hard,soft = [],[]
docs = sorted(p for p in tracked if p.endswith('.md') and not any(p == d or p.startswith(d+'/') for d in mod.SCAN_SKIP_DIRS))
for p in docs:
    mod.check_file(p,root,tracked,hard,soft)
result = {'markdown_files':len(docs), 'hard_count':len(hard), 'soft_count':len(soft), 'hard':hard}
(root/'review/tracked_doc_refs.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='hard'},ensure_ascii=False))
raise SystemExit(bool(hard))
