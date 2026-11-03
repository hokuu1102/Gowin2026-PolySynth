from pathlib import Path
import subprocess, os, json

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
fixture = OUT / 'timeout-fixture'
for directory in ['sim/evidence', 'tb', 'rtl', 'tb/models', 'tb/checkers']:
    (fixture / directory).mkdir(parents=True, exist_ok=True)
(fixture / 'sim/tb_all.ps1').write_bytes((ROOT / 'sim/tb_all.ps1').read_bytes())
(fixture / 'tb/tb_stale_review.sv').write_text(
    'module tb_stale_review; reg clk=0; always #10 clk=~clk; '
    'initial $display("CURRENT RUN STARTED; no verdict"); endmodule\n')
log = fixture / 'sim/evidence/tb_stale_review.log'
results = []
env = dict(os.environ)
env['PATH'] = 'D:/iverilog/bin;' + env['PATH']
for repeat in (1, 2):
    log.write_text('PASS: OLD CHECKOUT EVIDENCE\n')
    os.utime(log, (1000000000, 1000000000))
    command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               str(fixture / 'sim/tb_all.ps1'), '-Filter', 'tb_stale_review', '-TimeoutSec', '1']
    proc = subprocess.run(command, cwd=fixture, env=env, capture_output=True)
    (OUT / f'timeout-run{repeat}.log').write_bytes(proc.stdout + proc.stderr)
    text = log.read_text(encoding='utf-8-sig')
    results.append(dict(repeat=repeat, actual_exit=proc.returncode, expected_exit=1,
                        stale_pass_hint='PASS:' in text, result_log=text))
(OUT / 'timeout-results.json').write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps(results, indent=2, ensure_ascii=True))
