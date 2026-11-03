"""Regenerate actual operator-tool Q/H bytes for the RTL consumer regression."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("board_acceptance", ROOT / "tools/board_acceptance.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
frames = [tool.bpm_frame(value) for value in (40, 120, 240)]
frames += [tool.transpose_frame(value) for value in (-12, 0, 12)]
assert all(len(frame) == 10 for frame in frames)
target = Path(__file__).with_name("board_acceptance_qh.hex")
target.write_text("".join(f"{byte:02x}\n" for frame in frames for byte in frame), encoding="ascii")
print(f"Generated {sum(map(len, frames))} helper-produced bytes: {target}")
