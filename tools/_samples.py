#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/ 内部的共用小工具（下划线前缀 = 私有，不作为命令使用）。

为什么要有它：
    四个验收脚本（`vcd2csv` / `csv_fft` / `latency_stats` / `peak_count`）必须**共用同一套约定**，
    否则"样点 CSV 该长什么样""怎么算通过"就会各写一份 ——
    本仓库的教训是：同一个东西有两份口径，最后一定会打架（见 `files/20-代码/已知问题与风险清单.md`）。

共用三件事：
    1. **输出编码兜底** —— Windows 控制台默认 GBK，打 emoji 会 UnicodeEncodeError 崩掉；
    2. **结论约定** —— 脚本自己给 `PASS:` / `FAIL:`，失败用**非零退出码**
       （⭐ 与 testbench 的"自己给结论"同一条约定，见 `files/20-代码/仿真与验证方案.md` §六）；
    3. **CSV 读法** —— 注释行（`#`/`//`）、空行、表头、`0x`/`0b`、多列取哪一列、无符号转有符号。

样点 / 频谱 CSV 约定（四个脚本统一遵守）
    ・空行、`#` 开头、`//` 开头 → 跳过
    ・第一行若含非数字 token → 视为**表头**（用 `--col 名字` 可以按列名选）
    ・分隔符自动识别：有逗号按逗号切，否则按空白切
    ・数字支持十进制、`0x` 十六进制、`0b` 二进制（便于直接贴仿真打印的十六进制值）
    ・默认取**最后一列**；`--col` 可给列号（0 起）或列名
"""

from __future__ import annotations

import os
import sys

# ── 1. 输出编码兜底 ─────────────────────────────────────────
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


def num(tok: str):
    """把一个 token 解析成 float；支持 0x / 0b / 带符号。失败返回 None。"""
    t = tok.strip().rstrip(",;")
    if not t:
        return None
    try:
        low = t.lower().lstrip("+-")
        if low.startswith("0x"):
            v = int(t, 16)
        elif low.startswith("0b"):
            v = int(t, 2)
        else:
            return float(t)
        return float(v)
    except ValueError:
        return None


def read_columns(path: str, col=None, unsigned: bool = False, bits: int = 16,
                 quiet: bool = False):
    """读一个 CSV/文本表，返回 (header, rows)。

    header : list[str]（没有表头时是空表头占位 ['c0','c1',...]）
    rows   : list[list[float]]（只保留能解析成数字的行）
    """
    header: list[str] = []
    rows: list[list[float]] = []
    bad_lines = 0

    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            toks = [t for t in (line.split(",") if "," in line else line.split()) if t]
            vals = [num(t) for t in toks]
            if all(v is None for v in vals):
                if not header and not rows:
                    header = [t.strip() for t in toks]      # 第一行非数字 → 表头
                    continue
                bad_lines += 1
                continue
            if any(v is None for v in vals):
                bad_lines += 1
                continue
            rows.append(vals)

    if not header and rows:
        header = [f"c{i}" for i in range(len(rows[0]))]
    if bad_lines and not quiet:
        print(f"ℹ️  {os.path.basename(path)}：跳过 {bad_lines} 行（无法解析成数字）")

    if unsigned and rows:
        mid = 1 << (bits - 1)
        rows = [[v - mid for v in r] for r in rows]
    return header, rows


def pick_index(header: list[str], col) -> int:
    """把 --col 解析成列号：None → 最后一列；int → 直接；str → 按表头名匹配。"""
    n = len(header)
    if col is None:
        return n - 1
    if isinstance(col, int):
        if not 0 <= col < n:
            raise SystemExit(f"❌ --col {col} 越界（这张表有 {n} 列）")
        return col
    if col in header:
        return header.index(col)
    raise SystemExit(f"❌ --col {col!r} 在表头里找不到；表头是 {header}")


def read_samples(path: str, col=None, unsigned: bool = False, bits: int = 16,
                 quiet: bool = False) -> list[float]:
    """读一列样点，返回 float 列表。"""
    header, rows = read_columns(path, unsigned=unsigned, bits=bits, quiet=quiet)
    if not rows:
        raise SystemExit(f"❌ {path}：没有解析到任何数据行")
    i = pick_index(header, col)
    return [r[i] for r in rows]


class Verdict:
    """收集检查项，最后统一给结论（⭐ 约定：脚本自己给 PASS/FAIL）。"""

    def __init__(self, title: str):
        self.title = title
        self.errors: list[str] = []
        self.checks = 0

    def check(self, cond: bool, msg: str, detail: str = "") -> bool:
        self.checks += 1
        if cond:
            print(f"  ok : {msg}")
        else:
            print(f"FAIL: {msg}" + (f"  —— {detail}" if detail else ""))
            self.errors.append(msg)
        return bool(cond)

    def info(self, msg: str) -> None:
        print(f"  ·  {msg}")

    def finish(self) -> int:
        print()
        if self.errors:
            print(f"FAIL: {self.title} —— {len(self.errors)}/{self.checks} 项不符合预期")
            return 1
        print(f"PASS: {self.title} —— {self.checks}/{self.checks} 项全部符合预期")
        return 0


def need_numpy(script: str):
    """两个 FFT 脚本需要 numpy；缺了要给一句能照做的提示，而不是 traceback。"""
    try:
        import numpy as np
        return np
    except ImportError:
        print(f"❌ {script} 需要 numpy（本机 python 里没装）。")
        print("   装法：  python -m pip install numpy")
        print("   说明：  只有 csv_fft / peak_count 依赖它；vcd2csv / latency_stats 只用标准库。")
        raise SystemExit(2)


def evidence_path(name: str) -> str:
    """证据统一落 sim/evidence/（相对仓库根；脚本在 tools/ 下）。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    d = os.path.join(root, "sim", "evidence")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, name)


def write_csv(path: str, lines: list[str]) -> None:
    """写 CSV 证据文件 —— ⭐ **UTF-8 with BOM**（`utf-8-sig`）。

    为什么故意带 BOM（与 `.ps1` 那条"必须带 BOM"是同一类问题的另一面）：
        · Windows PowerShell 5.1 的 `Get-Content` 默认按**本地代码页（GBK）**解码，
          读无 BOM 的 UTF-8 会出乱码 —— 更坑的是 GBK 是双字节：字节数为奇数时
          **会把行尾的换行也吃进一个汉字**，于是"下一行"看起来跑到上一行里去了；
        · **Excel 双击打开**无 BOM 的 UTF-8 CSV 也会把中文列名显示成乱码。
        ⇒ 证据文件（CSV/统计表）统一带 BOM，三方（Excel / PowerShell / Python）都能直接看。
    ⚠️ 读取侧要能吃掉 BOM：本文件 `read_columns()` 用的是 `utf-8-sig` ✓。
    """
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as fh:
        fh.write("\n".join(lines) + "\n")


def banner(text: str) -> None:
    print("─" * 68)
    print(text)
    print("─" * 68)
