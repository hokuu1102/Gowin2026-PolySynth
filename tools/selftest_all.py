#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令跑完 `tools/` 四个验收脚本的自检（T4 的验收入口）。

为什么需要它：
    T1 的经验是：**"一条命令"类交付物必须真的被跑过一次**（`sim/tb_all.ps1` 曾经
    从来没有跑通过，却一直被当成已交付）。四个工具脚本也一样 ——
    验收人只该记一条命令，而不是记住四条以及它们的参数。

用法
    python tools/selftest_all.py            # 跑四个自检，汇总
    python tools/selftest_all.py -v         # 连每个自检的完整输出一起打印

退出码：0 = 四个全过；1 = 有失败的
"""

from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _samples as S  # noqa: E402

TOOLS = [
    ("vcd2csv.py", "VCD → CSV（波形抽取）"),
    ("csv_fft.py", "CSV → FFT（主峰/SNR/杂散）"),
    ("latency_stats.py", "延迟日志 → min/max/极差 + M2 判据"),
    ("peak_count.py", "频谱 → 谱峰计数（M4 判定）"),
    ("selftest_evt2uart.py", "evt2uart 帧模型 vs RTL 逐字节对拍"),
]


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    verbose = "-v" in sys.argv or "--verbose" in sys.argv

    print("=" * 68)
    print("tools/ 四个验收脚本的自检")
    print("=" * 68)

    results = []
    for name, desc in TOOLS:
        path = os.path.join(here, name)
        if not os.path.isfile(path):
            results.append((name, desc, None, "脚本不存在"))
            continue
        proc = subprocess.run([sys.executable, path, "--selftest"],
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace")
        out = (proc.stdout or "") + (proc.stderr or "")
        if verbose:
            print()
            print(out.rstrip())
        verdict = [ln.strip() for ln in out.splitlines()
                   if ln.startswith(("PASS:", "FAIL:"))]
        results.append((name, desc, proc.returncode, verdict[-1] if verdict else "(没有结论行)"))

    print()
    print(f"{'脚本':<20}{'结论':<8}说明")
    print("-" * 68)
    bad = 0
    for name, desc, code, verdict in results:
        ok = (code == 0 and verdict.startswith("PASS:"))
        if not ok:
            bad += 1
        print(f"{name:<20}{'PASS' if ok else 'FAIL':<8}{desc}")
        if not ok:
            print(f"{'':<28}{verdict}")
    print("-" * 68)
    if bad:
        print(f"FAIL: {bad}/{len(results)} 个脚本的自检没通过")
        return 1
    print(f"PASS: {len(results)}/{len(results)} 个脚本自检全部通过")
    print("      （证据见 sim/evidence/：自检正弦 CSV / 频谱表 / 频谱图）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
