"""Archive fresh H5 Gowin reports and evaluate the requested timing gates."""
from pathlib import Path
import argparse
import hashlib
import html
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "evidence/h5"
parser = argparse.ArgumentParser()
parser.add_argument("--project-dir", type=Path, default=ROOT)
parser.add_argument("--build-log", type=Path, default=OUT / "main-build.log")
parser.add_argument("--started-json", type=Path, default=OUT / "main-build.started.json")
args = parser.parse_args()
project = args.project_dir
report = project / "impl/pnr/Gowin2026_tr_content.html"
log = args.build_log
bitstream = project / "impl/pnr/Gowin2026.fs"
started = json.loads(args.started_json.read_text())["unix_time"]
assert report.stat().st_mtime >= started, "STA report predates this H5 build"
assert bitstream.stat().st_mtime >= started, "Bitstream predates this H5 build"
rows = []
for row in re.findall(r"<tr\b[^>]*>.*?</tr>", report.read_text(errors="replace"), re.I | re.S):
    cells = re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", row, re.I | re.S)
    text = " | ".join(" ".join(html.unescape(re.sub("<[^>]+>", " ", cell)).split()) for cell in cells)
    if text:
        rows.append(text)
summary = rows[:rows.index(next(r for r in rows if r.startswith("Path Number |")))]
for source, target in [
    (report, OUT / "main-timing.html"),
    (project / "impl/pnr/Gowin2026.pin.html", OUT / "main-pins.html"),
    (project / "impl/gwsynthesis/Gowin2026_syn_rsc.xml", OUT / "main-resources.xml"),
    (project / "impl/pnr/Gowin2026.rpt.txt", OUT / "main-pnr-report.txt"),
]:
    shutil.copyfile(source, target)
setup = int(next(r.split(" | ")[1] for r in rows if r.startswith("Numbers of Setup Violated Endpoints |")))
hold = int(next(r.split(" | ")[1] for r in rows if r.startswith("Numbers of Hold Violated Endpoints |")))
pa = len(re.findall(r"\bPA1019\b", log.read_text(errors="replace")))
summary += [f"PA1019 count in fresh full build log: {pa}"]
correct_part = "Part Number | GW5AT-LV60PG484AC1/I0" in rows
passed = setup == 0 and hold == 0 and pa == 0 and correct_part
summary.append(f"{'PASS' if correct_part else 'FAIL'} target part must be GW5AT-LV60PG484AC1/I0")
for clock, nominal in [("clk_sys", 50.0), ("pixel_clk", 25.0)]:
    row = next(r for r in rows if f" | {clock} | " in r and "(MHz)" in r)
    frequency = float(re.findall(r"([\d.]+)\(MHz\)", row)[1])
    margin = (frequency / nominal - 1) * 100
    ok = frequency >= 51.5 and margin >= 3
    summary.append(f"{'PASS' if ok else 'FAIL'} {clock}: Fmax={frequency:.3f} MHz; frequency headroom over {nominal:g} MHz={margin:.3f}%; gate >=51.5 MHz AND >=3%")
    passed &= ok
artifact = OUT / ("Gowin2026_H5.fs" if passed else "Gowin2026_H5_UNQUALIFIED.fs")
shutil.copyfile(bitstream, artifact)
summary += [f"Archived bitstream: {artifact.name}",
            f"Bitstream SHA256: {hashlib.sha256(bitstream.read_bytes()).hexdigest()}",
            "E3 " + ("PASS" if passed else "FAIL")]
(OUT / "main-timing-summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
print("\n".join(summary))
raise SystemExit(0 if passed else 1)
