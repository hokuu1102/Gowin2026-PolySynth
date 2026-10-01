"""Build the exact main RTL in a fresh directory without deleting PnR state."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--place", type=int, choices=range(5), default=1)
parser.add_argument("--route", type=int, choices=range(3), default=1)
args = parser.parse_args()
name = f"build-p{args.place}-r{args.route}-{time.strftime('%Y%m%d-%H%M%S')}"
dst = ROOT / "evidence/h5" / name
dst.mkdir()
for directory in ["rtl", "ip", "constr"]:
    shutil.copytree(ROOT / directory, dst / directory)
shutil.copyfile(ROOT / "Gowin2026.gprj", dst / "Gowin2026.gprj")
(dst / "build_cli.tcl").write_text(
    f"open_project Gowin2026.gprj\nset_option -top_module top\n"
    f"set_option -place_option {args.place}\nset_option -route_option {args.route}\nrun all\nexit\n",
    encoding="ascii")
manifest = {}
for p in dst.rglob("*"):
    if p.is_file():
        rel = p.relative_to(dst).as_posix()
        manifest[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
        if rel != "build_cli.tcl":
            assert p.read_bytes() == (ROOT / rel).read_bytes(), rel
(dst / "source-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
started = time.time()
(dst / "started.json").write_text(json.dumps({"unix_time": started, "place": args.place, "route": args.route}), encoding="utf-8")
print(f"Fresh main project: {dst}", flush=True)
with open(dst / "build.log", "wb") as out, open(dst / "build.stderr.log", "wb") as err:
    p = subprocess.Popen(["D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe", "build_cli.tcl"],
                         cwd=dst, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
    (dst / "pid.txt").write_text(str(p.pid))
    code = p.wait()
(dst / "exit.json").write_text(json.dumps({"exit": code, "elapsed_seconds": time.time() - started}), encoding="utf-8")
print(f"Gowin exit={code}; reports under {dst / 'impl/pnr'}", flush=True)
raise SystemExit(code)
