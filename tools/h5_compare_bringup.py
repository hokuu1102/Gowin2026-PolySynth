"""Strict byte comparison: allow <=14 differing bytes ONLY in Created Time."""
from pathlib import Path
import argparse
import hashlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("reference", type=Path)
parser.add_argument("--built", type=Path, default=Path("bringup/hdmi_640x480/impl/pnr/hdmi_640x480.fs"))
args = parser.parse_args()
a, b = args.reference.read_bytes(), args.built.read_bytes()
assert len(a) == len(b), f"FAIL: length {len(a)} != {len(b)}"
pattern = rb"(?m)^//Created Time: ([^\r\n]+)"
ma, mb = re.search(pattern, a[:2048]), re.search(pattern, b[:2048])
assert ma and mb and ma.span(1) == mb.span(1), "FAIL: timestamp header shape changed"
diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
outside = [i for i in diff if not ma.start(1) <= i < ma.end(1)]
print(f"Reference: {args.reference}")
print(f"Built: {args.built}")
print(f"Bytes: {len(a)}; differing bytes: {len(diff)}; outside timestamp: {len(outside)}")
print(f"Timestamp region: [{ma.start(1)}, {ma.end(1)}); diff offsets: {diff[:40]}")
print(f"Reference SHA256: {hashlib.sha256(a).hexdigest()}")
print(f"Built SHA256: {hashlib.sha256(b).hexdigest()}")
assert not outside and len(diff) <= 14, "FAIL: more than 14 differences or non-timestamp bytes changed"
print("PASS: every byte outside the permitted header timestamp matches J_TOKENFIX_led.fs")
