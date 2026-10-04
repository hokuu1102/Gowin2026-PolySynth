"""Fresh isolated Gowin synthesis only. Never runs placement or routing."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('name')
p.add_argument('--baseline', action='store_true')
p.add_argument('--rtl-file', help='Explicit archived note_manager candidate, relative to repo root')
p.add_argument('--test-mode', type=int, choices=[0, 1], default=0)
args = p.parse_args()
dst = OUT / args.name
assert dst.resolve().parent == OUT.resolve()
dst.mkdir()  # a reused impl is never accepted
for d in ['rtl', 'ip', 'constr']:
    shutil.copytree(ROOT / d, dst / d)
shutil.copy2(ROOT / 'Gowin2026.gprj', dst / 'Gowin2026.gprj')
if args.baseline:
    shutil.copyfile(OUT / 'note_manager.before.v', dst / 'rtl/w3b/note_manager.v')
if args.rtl_file:
    assert not args.baseline
    shutil.copyfile(ROOT / args.rtl_file, dst / 'rtl/w3b/note_manager.v')
if args.test_mode:
    top = dst / 'rtl/top.v'
    s = top.read_text(encoding='utf-8')
    import re
    s, n = re.subn(r'(parameter\s+integer\s+TEST_MODE_EN\s*=\s*)0', r'\g<1>1', s)
    assert n == 1
    top.write_text(s, encoding='utf-8')
(dst / 'synthesis_only.tcl').write_text('open_project Gowin2026.gprj\nset_option -top_module top\nrun syn\nexit\n', encoding='ascii')
manifest = {f.relative_to(dst).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in dst.rglob('*') if f.is_file()}
(dst / 'source-manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
t = time.time()
with (dst / 'console.log').open('wb') as log:
    result = subprocess.run(['D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe', 'synthesis_only.tcl'],
                            cwd=dst, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
assert not (dst / 'impl/pnr').exists(), 'Unexpected PnR artifacts'
(dst / 'exit.json').write_text(json.dumps({'exit': result.returncode, 'seconds': time.time()-t, 'test_mode': args.test_mode}), encoding='utf-8')
print(args.name, 'synthesis exit', result.returncode, 'seconds', round(time.time()-t, 1), flush=True)
raise SystemExit(result.returncode)
