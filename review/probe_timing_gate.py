"""Execute the exact production P0-30 gate on controlled report fixtures."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'review' / 'timing_gate'
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'sim/gowin_build.ps1').read_text(encoding='utf-8-sig')
gate = source[source.index('$p030Tr = $trPath'):]
results = []
cases = [
    ('sys_overconstraint_control', 'clk_sys', '-0.500', 0, '16.4ns sys-to-sys budget may be expanded to 20ns'),
    ('serial_real_violation', 'serial_clk', '-0.500', 12, 'serial_clk has a real 8ns period and no 16.4ns override'),
    ('pixel_real_violation', 'pixel_clk', '-0.500', 12, 'pixel_clk has a real 40ns period and no 16.4ns override'),
    ('sys_actual_failure_control', 'clk_sys', '-4.000', 12, 'even after adding 3.6ns this sys path is late'),
]
for name, clock, slack, expected, reason in cases:
    case = OUT / name
    (case / 'impl/pnr').mkdir(parents=True, exist_ok=True)
    (case / 'constr').mkdir(exist_ok=True)
    (case / 'constr/top.sdc').write_bytes((ROOT / 'constr/top.sdc').read_bytes())
    html = f'<html>Total Negative Slack Summary<table><tr><td>Clock Name</td><td>Analysis Type</td><td>TNS</td><td>Endpoints</td></tr><tr><td>{clock}</td><td>Setup</td><td>{slack}</td><td>1</td></tr></table>Path Slacks Table</html>'
    (case / 'impl/pnr/report.html').write_text(html, encoding='ascii')
    (case / 'impl/pnr/Gowin2026.timing_paths').write_text(f'SETUP\n{slack}\n{clock}\n', encoding='ascii')
    # Fixture injection is limited to the script's pre-existing root/report inputs.
    prefix = f"$root = $PSScriptRoot\n$trPath = Join-Path $root 'impl/pnr/report.html'\n"
    script = case / 'run_exact_gate.ps1'
    script.write_text(prefix + gate, encoding='utf-8-sig')
    cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)]
    proc = subprocess.run(cmd, cwd=case, capture_output=True, timeout=30)
    output = proc.stdout.decode('utf-8', 'replace') + proc.stderr.decode('utf-8', 'replace')
    (case / 'run.log').write_text(output, encoding='utf-8')
    results.append({'case': name, 'clock': clock, 'slack_ns': float(slack), 'expected_exit': expected, 'actual_exit': proc.returncode, 'matches_requirement': proc.returncode == expected, 'reason': reason, 'command': cmd})
report = {'source_file': 'sim/gowin_build.ps1', 'extracted_gate_sha256': hashlib.sha256(gate.encode()).hexdigest(), 'cases': results}
(OUT / 'results.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
raise SystemExit(1 if any(not r['matches_requirement'] for r in results) else 0)
