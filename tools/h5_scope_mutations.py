"""Run the unchanged pixel oracle against good RTL and isolated faulty copies."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "evidence/h5/mutations"
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / "rtl/hdmi/waveform_scope.v").read_text(encoding="utf-8")
cases = {
    "good": source,
    "invert_sample": source.replace("history[wr_ptr] <= sample_i;", "history[wr_ptr] <= -sample_i;"),
    "wrong_y_origin": source.replace("11'sd240 -", "11'sd239 -"),
    "disconnect_segments": source.replace("(x_q == 0) ? point_q : previous_y", "point_q"),
}
lines = []
for name, rtl in cases.items():
    if name != "good":
        assert rtl != source, f"Missing mutation anchor: {name}"
    path = OUT / f"{name}.v"
    path.write_text(rtl, encoding="utf-8")
    exe = OUT / f"{name}.vvp"
    compiled = subprocess.run(["iverilog", "-g2012", "-s", "tb_waveform_scope", "-o", str(exe),
                               str(path), str(ROOT / "tb/hdmi/tb_waveform_scope.sv")],
                              capture_output=True, text=True, cwd=ROOT)
    (OUT / f"{name}.compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run(["vvp", str(exe)], capture_output=True, text=True, cwd=ROOT, timeout=180)
    (OUT / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if name == "good":
        assert result.returncode == 0 and "PASS: waveform_scope" in result.stdout, result.stdout
    else:
        assert result.returncode != 0 and "FAIL: pixel" in result.stdout, result.stdout
    verdict = f"{name}: exit={result.returncode} {'PASS original' if name == 'good' else 'KILLED'}"
    lines.append(verdict)
    print(verdict, flush=True)
(OUT / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
