"""Run the full unmodified acceptance budgets in isolated source directories."""
from pathlib import Path
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "evidence/h5"
roots = {"baseline-final": OUT / "baseline-src", "after-final": ROOT}
processes = {}
streams = []
started = time.time()
for name, cwd in roots.items():
    runner = cwd / "sim/tb_all.ps1"
    assert runner.exists()
    stdout = open(OUT / f"regression-{name}.log", "wb")
    stderr = open(OUT / f"regression-{name}.stderr.log", "wb")
    streams += [stdout, stderr]
    command = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); & '" + str(runner).replace("'", "''") + "'; exit $LASTEXITCODE"
    p = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
                         cwd=cwd, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
    processes[name] = p
    print(f"Started {name}: PID {p.pid}; full tb_all.ps1; existing timeout budgets", flush=True)
results = {}
while len(results) < len(processes):
    for name, p in processes.items():
        if name not in results and p.poll() is not None:
            results[name] = {"exit": p.returncode, "elapsed_seconds": round(time.time() - started, 2)}
            (OUT / "regression-final-exits.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
            print(f"Finished {name}: {results[name]}", flush=True)
    if len(results) < len(processes):
        time.sleep(5)
for stream in streams:
    stream.close()
raise SystemExit(0 if all(r["exit"] == 0 for r in results.values()) else 1)
