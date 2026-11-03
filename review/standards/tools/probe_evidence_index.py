from pathlib import Path
import subprocess, sys, json

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
fixture = OUT / 'evidence-index-fixture'
fixture.mkdir(exist_ok=True)

def run(args):
    return subprocess.run(args, cwd=fixture, capture_output=True, text=True,
                          encoding='utf-8', errors='replace')

assert run(['git', 'init', '--quiet']).returncode == 0
log = fixture / 'sim/evidence/probe.log'
log.parent.mkdir(parents=True, exist_ok=True)
results = []
for repeat in (1, 2):
    for label, indexed, working, expected in [
        ('indexed_fail', 'FAIL: staged contamination\n', 'PASS: working clean\n', 1),
        ('indexed_empty', '', 'PASS: working clean\n', 1),
        ('clean_control', 'PASS: indexed clean\n', 'PASS: working clean\n', 0),
    ]:
        log.write_text(indexed, encoding='utf-8')
        assert run(['git', 'add', 'sim/evidence/probe.log']).returncode == 0
        log.write_text(working, encoding='utf-8')
        result = run([sys.executable, str(ROOT / 'tools/check_evidence.py')])
        results.append(dict(case=label, repeat=repeat, expected_exit=expected,
                            actual_exit=result.returncode,
                            actual_index=run(['git', 'show', ':sim/evidence/probe.log']).stdout,
                            working=working, stdout=result.stdout, stderr=result.stderr))
(OUT / 'evidence-index-results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
print(json.dumps(results, indent=2))
