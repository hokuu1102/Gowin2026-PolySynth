"""Verification-only Icarus runner on an immutable, isolated source snapshot.

Repair snapshot runner: pins --revision and verifies every RTL/TB/IP blob.
Uses the same RTL/models, macros and test-specific timeout policy as tb_all.ps1.
No source or acceptance predicate is rewritten. Run logs are per-test; unknown
or missing verdicts are not counted as passes. Outputs are not board acceptance.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ROOT = REPO / "build/repair_regression_source"
REVISION = None
OUT = HERE / "parallel_full"
IVERILOG = "D:/iverilog/bin/iverilog.exe"
VVP = "D:/iverilog/bin/vvp.exe"
SKIP = {"tb_export_wav", "tb_export_key_wav", "tb_at_merge_known_bugs"}


def sources(folder):
    return sorted(p for p in folder.rglob("*")
                  if p.suffix in {".v", ".sv"} and not p.name.startswith("tb_"))


def verify_snapshot():
    # git archive applies checkout EOL conversion under core.autocrlf on Windows.
    # Accept only exact committed bytes or their CRLF checkout representation.
    raw = subprocess.check_output(
        ["git", "-c", "core.quotePath=false", "ls-tree", "-r", REVISION,
         "rtl", "tb", "ip", "bringup/dac_tone",
         "evidence/h5/cls-next-20261004/note_manager_reference.v"],
        cwd=REPO, text=True, encoding="utf-8")
    count = 0
    for row in raw.splitlines():
        meta, rel = row.split("\t", 1)
        data = (ROOT / rel).read_bytes()
        digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if digest != meta.split()[2]:
            normalized = data.replace(b"\r\n", b"\n")
            digest = hashlib.sha1(b"blob " + str(len(normalized)).encode()
                                  + b"\0" + normalized).hexdigest()
            if digest != meta.split()[2]:
                raise RuntimeError("Snapshot does not match committed blob: " + rel)
        count += 1
    return count


def run_test(tb, rtl, support, policy, heavy, override=None):
    name = tb.stem
    dst = OUT / name
    dst.mkdir(parents=True, exist_ok=True)
    src = tb.read_text(encoding="utf-8-sig")
    # Create output directories, not missing read fixtures. Keep all writes in
    # the isolated snapshot; an absent sim/evidence must not fail RTL at time 0.
    for target in re.findall(r'\$fopen\s*\(\s*"([^"]+)"\s*,\s*"[wa]"', src):
        resolved = (ROOT / target).resolve()
        resolved.relative_to(ROOT.resolve())
        resolved.parent.mkdir(parents=True, exist_ok=True)
    for dump in re.findall(r'\$dumpfile\s*\(\s*"([^"]+)"', src):
        (ROOT / dump).parent.mkdir(parents=True, exist_ok=True)
    image = dst / (name + ".vvp")
    args = [IVERILOG, "-g2012", "-Wall", "-s", name, "-o", str(image)]
    if "_prom" not in name:
        args.append("-DWAVETABLE_BEHAVIORAL")
    args += [str(p) for p in rtl + support] + [str(tb)]
    start = time.monotonic()
    with (dst / "compile.log").open("wb") as log:
        compiled = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=120)
    result = dict(name=name, compile_exit=compiled.returncode,
                  run_exit=None, status="COMPILE_FAIL")
    if compiled.returncode == 0:
        original_budget = policy.get(name, 300 if name in heavy else 120)
        budget = original_budget if override is None else override
        result["original_timeout_sec"] = original_budget
        result["timeout_sec"] = budget
        try:
            with (dst / "run.log").open("wb") as log:
                ran = subprocess.run([VVP, str(image)], cwd=ROOT, stdout=log,
                                     stderr=subprocess.STDOUT, timeout=budget)
            result["run_exit"] = ran.returncode
            text = (dst / "run.log").read_text(encoding="utf-8", errors="replace")
            fail = re.search(r"(?m)^[ \t]*[^A-Za-z]*FAIL:", text)
            verdict = bool(re.search(r"(?m)^.*\bPASS(?:[: ]|$)", text))
            result["explicit_pass_verdict"] = verdict
            result["status"] = "PASS" if ran.returncode == 0 and not fail and verdict else "RUN_FAIL"
            if ran.returncode == 0 and not fail and not verdict:
                result["status"] = "INCONCLUSIVE"
            if name == "tb_opt04_nm_age_negative":
                detected = all(re.search(r"split age mismatch width=" + str(w) + r"\b", text)
                               for w in (1, 7, 16, 17))
                other_failure = re.search(r"timeout|selection mismatch|split compare mismatch", text)
                exact_fatals = (len(re.findall(r"(?m)^FATAL:", text)) == 4 and
                    len(re.findall(r"(?m)^FATAL:.*split age mismatch width=(?:1|7|16|17)\b", text)) == 4)
                result["status"] = ("EXPECTED_NEGATIVE_PASS" if ran.returncode == 1
                                    and detected and exact_fatals and not other_failure
                                    and not verdict else "RUN_FAIL")
        except subprocess.TimeoutExpired:
            result["status"] = "TIMEOUT"
    result["elapsed_sec"] = round(time.monotonic() - start, 3)
    (dst / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def main():
    global OUT, ROOT, REVISION
    ap = argparse.ArgumentParser()
    ap.add_argument("--revision", required=True)
    ap.add_argument("--snapshot-dir", default="repair_regression_source")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--output", default="parallel_full")
    ap.add_argument("--timeout-override", type=int)
    ap.add_argument("--workers", type=int, default=8)
    options = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", options.snapshot_dir):
        raise ValueError("Snapshot must be a local ASCII build directory name")
    ROOT = REPO / "build" / options.snapshot_dir
    REVISION = subprocess.check_output(["git", "rev-parse", "--verify", options.revision + "^{commit}"], cwd=REPO, text=True).strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", options.output):
        raise ValueError("Output must be a local ASCII directory name")
    OUT = HERE / options.output
    OUT.mkdir(parents=True, exist_ok=True)
    script = (REPO / "sim/tb_all.ps1").read_text(encoding="utf-8-sig")
    policy = {name: int(budget) for name, budget in re.findall(
        r"\(\$name -eq '([^']+)'\)\s*\{\s*(\d+)\s*\}", script)}
    heavy_text = re.search(r"\$heavyTb\s*=\s*@\((.*?)\n\s*\)", script, re.S).group(1)
    heavy = set(re.findall(r"'(tb_[^']+)'", heavy_text))
    count = verify_snapshot()
    print("SNAPSHOT_BLOBS_VERIFIED=" + str(count), flush=True)
    rtl = sources(ROOT / "rtl")
    rtl += [p for p in sources(ROOT / "bringup/dac_tone") if "proj_fmt" not in str(p)]
    support = sources(ROOT / "tb/models") + sources(ROOT / "tb/checkers")
    tests = sorted((ROOT / "tb").rglob("tb_*.sv"))
    selected = [p for p in tests if p.stem not in SKIP]
    if options.only is not None:
        selected = [p for p in selected if p.stem in options.only]
        if {p.stem for p in selected} != set(options.only):
            raise ValueError("Requested test name missing from source snapshot")
    print(f"DISCOVERED={len(tests)} SELECTED={len(selected)} SKIPPED={sorted(SKIP)}", flush=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=options.workers) as pool:
        pending = {pool.submit(run_test, tb, rtl, support, policy, heavy,
                               options.timeout_override): tb for tb in selected}
        for future in concurrent.futures.as_completed(pending):
            tb = pending[future]
            try:
                row = future.result()
            except Exception as exc:
                row = dict(name=tb.stem, status="RUNNER_ERROR", error=str(exc))
            results.append(row)
            print(f"{len(results)}/{len(selected)} {row['status']} {row['name']}", flush=True)
    functional = sum(row["status"] == "PASS" for row in results)
    negative = sum(row["status"] == "EXPECTED_NEGATIVE_PASS" for row in results)
    good = functional + negative
    summary = dict(source=REVISION, discovered=len(tests), selected=len(selected),
                   pass_count=functional, expected_negative_count=negative, accepted_count=good, fail_count=len(results)-good, skipped=sorted(SKIP),
                   snapshot_blobs_verified=count, timeout_override_sec=options.timeout_override,
                   results=sorted(results, key=lambda row: row["name"]))
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"SUMMARY: {functional} functional PASS + {negative} expected negative; {good}/{len(selected)} accepted", flush=True)
    return 0 if good == len(selected) else 1


if __name__ == "__main__":
    sys.exit(main())
