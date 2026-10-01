import json
import re
import sys
from collections import Counter
from pathlib import Path

import fitz

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(r"D:\Gowin")
OUT = Path(__file__).with_name("local_scan.json")
PAT = re.compile(r"OSER10|OSER16|serializ(?:er|ation)|SERDES|LVDS|最大频率|数据率|Gbps|Gbit/s|MHz|AC\s*(?:特性|Characteristics)|GW5AT|FCLK", re.I)
files = [p for p in ROOT.rglob("*") if p.is_file()]
result = {"root": str(ROOT), "total_files": len(files), "pdf_files": [], "text_files": [], "binary_or_oversize_files": 0, "errors": [], "pdf_hits": [], "text_hits": []}
for p in files:
    suffix = p.suffix.lower()
    if suffix == ".pdf":
        result["pdf_files"].append(str(p))
        try:
            doc = fitz.open(p)
            for i, page in enumerate(doc):
                lines = page.get_text().splitlines()
                hits = [j for j, line in enumerate(lines) if PAT.search(line)]
                if hits:
                    terms = Counter(m.group(0).lower() for j in hits for m in PAT.finditer(lines[j]))
                    result["pdf_hits"].append({"file": str(p), "page": i + 1, "terms": dict(terms), "lines": [lines[j][:280] for j in hits[:20]]})
        except Exception as exc:
            result["errors"].append({"file": str(p), "error": str(exc)})
    else:
        try:
            if p.stat().st_size > 20_000_000:
                result["binary_or_oversize_files"] += 1
                continue
            with p.open("rb") as stream:
                sample = stream.read(4096)
            if b"\0" in sample or (sample and sum(32 <= b <= 126 or b >= 128 or b in (9, 10, 13) for b in sample) / len(sample) < .85):
                result["binary_or_oversize_files"] += 1
                continue
            data = p.read_bytes()
            content = None
            for encoding in ("utf-8-sig", "gb18030", "cp1252"):
                try:
                    content = data.decode(encoding)
                    break
                except UnicodeError:
                    pass
            if content is None:
                result["binary_or_oversize_files"] += 1
                continue
            result["text_files"].append(str(p))
            lines = content.splitlines()
            hits = [(i + 1, line[:280]) for i, line in enumerate(lines) if PAT.search(line)]
            if hits:
                terms = Counter(m.group(0).lower() for _, line in hits for m in PAT.finditer(line))
                result["text_hits"].append({"file": str(p), "terms": dict(terms), "lines": hits[:20], "total_hit_lines": len(hits)})
        except Exception as exc:
            result["errors"].append({"file": str(p), "error": str(exc)})
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({"total_files": len(files), "pdf_files": len(result["pdf_files"]), "text_files": len(result["text_files"]), "binary_or_oversize_files": result["binary_or_oversize_files"], "pdf_hit_pages": len(result["pdf_hits"]), "text_hit_files": len(result["text_hits"]), "errors": len(result["errors"])}, ensure_ascii=False))
