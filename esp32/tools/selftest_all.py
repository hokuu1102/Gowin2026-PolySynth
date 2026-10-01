#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest_all.py —— ⭐ **一条命令跑完全部工具的自检**（⛔ 不需要硬件）

═══ 用途 ═══
⭐ 把"逐个跑 `--selftest`"这件事收成一个命令 + **一个退出码**。

═══ 为什么需要它 ═══
⚠️ 本工程的工具带 `--selftest`，⭐ 分散在两个目录：
    · `esp32/tools/`              （验收 + 回归）
    · `esp32/tools/evt2midi/`     （录制 + 转 MIDI）
🔴 手工逐个跑**容易漏**（⭐ 我前几轮就漏过 —— ⚠️ 补完 6 个才发现还有 1 个没自检）。
⇒ ⭐ **用脚本枚举**，⛔ 不靠人记清单。

⚠️ **刻意不在这里写"共几个工具"** ——
   ⭐ 那种写死的数字**必然过期**（⭐ 实测：原写"10 个"，实际早已 15 个，
      后来加到 17 个 ⇒ 🔴 文档说 10、实际 17，⚠️ 而没人会去改它）。
   ⭐ 真实数量由 `--list` 现场枚举给出，⛔ 不靠文档里的常数。
   📌 同族：`C116`（⭐ 文档里写死的引用会静默失效）。

═══ 用法 ═══
    python selftest_all.py            # 跑全部，打印汇总表
    python selftest_all.py --list     # 只列出会跑哪些
    python selftest_all.py -v         # 顺带打印每个工具的完整输出

⚠️ 退出码：⭐ **0 = 全过**；⭐ **非 0 = 有工具判红**（⭐ 便于 CI/脚本判）
"""

import argparse
import os
import re
import subprocess
import sys

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

HERE = os.path.dirname(os.path.abspath(__file__))

# ⭐ 要跑的目录（⭐ 相对本脚本）
SCAN_DIRS = (".", os.path.join("evt2midi"))

# ⚠️ 排除：⭐ 这些不是"带 --selftest 的工具"
#    · `_` 开头 = ⭐ 证据/辅助脚本（⭐ 它们**直接跑**，⛔ 没有 --selftest）
#    · `selftest_all.py` 自身（⭐ 会递归）
EXCLUDE = {"selftest_all.py"}


def has_selftest(path):
    """
    ⭐ 判断该脚本是否支持 `--selftest`。

    ⚠️ 用【源码里有没有 `--selftest` 这个字面串】判断 ——
    ⭐ 因为要跑的可能是 argparse 参数，⚠️ 也可能像 `frame_format.py`
       那样"直接跑就是自检"（⭐ 它没有参数）。
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return "--selftest" in f.read()
    except OSError:
        return False


def discover():
    """⭐ 返回 [(相对路径, 是否要加 --selftest)]。"""
    found = []
    for d in SCAN_DIRS:
        full = os.path.join(HERE, d)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            if not name.endswith(".py"):
                continue
            if name in EXCLUDE or name.startswith("_"):
                continue
            p = os.path.join(full, name)
            if not os.path.isfile(p):
                continue
            rel = os.path.relpath(p, HERE)
            # ⭐ 有 --selftest 的加参数；⚠️ 没有的（如 frame_format.py）直接跑
            found.append((rel, has_selftest(p)))
    return found


def run_one(rel, use_flag):
    """⭐ 跑一个工具，返回 (rc, ok 数, red 数, 输出)。"""
    cmd = [sys.executable, rel] + (["--selftest"] if use_flag else [])
    try:
        r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=300)
        out = (r.stdout or "") + (r.stderr or "")
        rc = r.returncode
    except subprocess.TimeoutExpired:
        return 124, 0, 0, "(超时 300 s)"
    except Exception as e:                       # noqa: BLE001
        return 99, 0, 0, "(启动失败：%s)" % e
    return (rc,
            len(re.findall(r"\bOK\b", out)),
            len(re.findall(r"\bRED\b", out)),
            out)


def main():
    ap = argparse.ArgumentParser(description="跑完全部工具的离线自检")
    ap.add_argument("--list", action="store_true", help="只列出会跑哪些")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印完整输出")
    args = ap.parse_args()

    tools = discover()
    if args.list:
        print("会跑 %d 个：" % len(tools))
        for rel, flag in tools:
            print("  %s %s" % (rel, "--selftest" if flag else "(直接跑)"))
        return 0

    print("=" * 74)
    print("全工具离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    print("发现 %d 个脚本（⭐ 排除 `_` 开头的辅助脚本）" % len(tools))
    print()

    total_ok = 0
    total_red = 0
    failed = []
    for rel, flag in tools:
        rc, nok, nred, out = run_one(rel, flag)
        total_ok += nok
        total_red += nred
        mark = "OK " if rc == 0 else "RED"
        print("  %s  rc=%-3d OK=%-4d RED=%-3d  %s" % (mark, rc, nok, nred, rel))
        if rc != 0:
            failed.append((rel, rc, out))
        if args.verbose:
            print("      " + "\n      ".join(out.splitlines()[-8:]))

    print()
    print("=" * 74)
    print("合计：%d 个工具，%d 项 OK，%d 项 RED" % (len(tools), total_ok, total_red))
    if not failed:
        print("结论：全部通过 ✅")
    else:
        print("结论：%d 个工具不通过 🔴" % len(failed))
        for rel, rc, out in failed:
            print()
            print("---- %s (rc=%d) ----" % (rel, rc))
            # ⚠️ 只打含 RED 的行 + 最后 3 行（⭐ 免得刷屏）
            lines = out.splitlines()
            for ln in lines:
                if "RED" in ln:
                    print("   " + ln.strip())
            for ln in lines[-3:]:
                print("   " + ln.strip())
    print("=" * 74)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
