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

    ⚠️ 判据必须锚在【真的注册了这个参数】上，⛔ 不是"源码里出现过这几个字"。
    🔴 实测踩过：新写的 `run_all_tests.py` 在**命令清单字符串**里写了
       `--selftest`，于是被误枚举、被加上 `--selftest` 跑 => argparse 报
       `unrecognized arguments` => 退出码 2 => 全量自检变红。
    ⭐ 同族：`C157`（"提到过" ⛔ 不等于"真的支持"）。
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError:
        return False
    # ⭐ 只看 argparse 注册：add_argument("--selftest" ...) / add_argument('--selftest' ...
    if re.search(r"""add_argument\(\s*["']--selftest""", src):
        return True
    # ⚠️ 兼容"手动看 sys.argv"的写法（当前工程没有，但保留这条以防将来）
    return bool(re.search(r"""["']--selftest["']\s+in\s+sys\.argv""", src))


def discover():
    """⭐ 返回 [(相对路径, 是否要加 --selftest)]。"""
    found = []
    for d in SCAN_DIRS:
        full = os.path.join(HERE, d)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            # 2026-10-14 改：也收录 .js 自检（用 node 跑）。
            #
            # 为什么：网页里的 MIDI 解析器是 JS，它的判据只能用 node 跑。
            #   ⚠️ 原来只扫 .py => 我写的 `_midi_parse_check.js` **永远跑不到**
            #   => 判据等于白写（同族：`_stress_cycles.py` 那个坑）。
            # ⭐ 判据锚在"这文件是不是一个能独立跑的自检"，⛔ 不看扩展名：
            #   文件名以 `_` 开头、且以 `check` 结尾 => 认作自检脚本。
            #   ⚠️ 不扫全部 .js —— 页面的辅助脚本不该被当自检跑。
            if name.endswith(".js"):
                if not name.startswith("_") or "check" not in name:
                    continue
                p = os.path.join(full, name)
                if os.path.isfile(p):
                    found.append((os.path.relpath(p, HERE), "node"))
                continue
            if not name.endswith(".py"):
                continue
            if name in EXCLUDE:
                continue
            p = os.path.join(full, name)
            if not os.path.isfile(p):
                continue
            rel = os.path.relpath(p, HERE)
            has = has_selftest(p)
            # 2026-10-14 改：`_` 开头的脚本【也收录】，但只收【真有 --selftest】的。
            #
            # 为什么改（原来的规则有个真缺口）：
            #   原来 `_` 开头一律跳过 => 我给 `_uart1_wire_check.py` /
            #   `_upstream_loop_check.py` / `_stress_cycles.py` 补的 `--selftest`
            #   **永远跑不到** => 判据等于白写。
            #   🔴 同族：`_stress_cycles.py` 也是"补了自检但没人跑"，
            #      当时的修法是"登记进 run_all_tests"，但那要一个个记得登记。
            #   ⭐ 现在的规则让它【自动被收录】=> 补了自检就自动进网，
            #      ⛔ 不需要额外的"记得登记"。
            # ⚠️ 仍然跳过"没有 --selftest 的 `_` 脚本"（它们是真机/一次性工具，
            #    直接跑需要硬件）—— 判据锚在 `has_selftest`，⛔ 不看名字。
            if name.startswith("_") and not has:
                continue
            # ⭐ 有 --selftest 的加参数；⚠️ 没有的（如 frame_format.py）直接跑
            found.append((rel, has))
    return found


# ⭐ 只认【判据位】的 RED —— ⛔ 不认标签 / 列名 / 测试描述里的 RED。
# 🔴 实测踩过：`run_all_tests.py` 的自检里，测试【标签】本身含 "RED" 二字
#    （如「判据位的 RED 必须判红」）=> 被数成 2 项 RED =>
#    合计说"2 项 RED"而结论说"全部通过" => ⭐ 两行又打架（`C162` / `C161` 同族）。
# ⭐ 同族：`C159`（用字面串做能力探测会误判）。
_RED_VERDICT = (
    re.compile(r"(?m)^\s*RED\b"),            # 行首的 RED（如 "  RED  rc=2  x.py"）
    re.compile(r"RED\s*=\s*[1-9]"),          # RED=3
    re.compile(r"\b([1-9]\d*)\s*项\s*RED"),  # "3 项 RED"
)


def count_red(out):
    """⭐ 数【判据位】的 RED 个数（⛔ 不是"文本里出现过几次"）。"""
    n = 0
    for ln in out.splitlines():
        if _RED_VERDICT[0].match(ln):
            n += 1
            continue
        m = _RED_VERDICT[1].search(ln)
        if m:
            n += 1
            continue
        m = _RED_VERDICT[2].search(ln)
        if m:
            n += int(m.group(1))
    return n


def run_one(rel, use_flag):
    """⭐ 跑一个工具，返回 (rc, ok 数, red 数, 输出)。

    `use_flag` 的三种取值：
      True    —— python 脚本，要加 `--selftest`
      False   —— python 脚本，直接跑（它没有 --selftest 参数）
      "node"  —— JS 自检，用 node 跑（2026-10-14 新增，见 discover()）
    """
    if use_flag == "node":
        cmd = ["node", rel]
    else:
        cmd = [sys.executable, rel] + (["--selftest"] if use_flag else [])
    try:
        r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=300)
        out = (r.stdout or "") + (r.stderr or "")
        rc = r.returncode
    except FileNotFoundError:
        return 98, 0, 0, "(找不到 node —— 本机没装 Node.js，跳过 JS 自检)"
    except subprocess.TimeoutExpired:
        return 124, 0, 0, "(超时 300 s)"
    except Exception as e:                       # noqa: BLE001
        return 99, 0, 0, "(启动失败：%s)" % e
    return rc, len(re.findall(r"\bOK\b", out)), count_red(out), out


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
    # ⚠️ 合计行必须包含【工具不通过数】—— 否则会与下面的结论行自相矛盾。
    # 🔴 实测踩过：合计只数输出里 "RED" 字面出现的次数，
    #    而 argparse 报错（退出码 2）的输出里没有 "RED" ⇒
    #    合计说"0 项 RED"、结论说"1 个工具不通过" ⇒ ⭐ 两行打架（C157 同族）。
    print("合计：%d 个工具（不通过 %d 个），%d 项 OK，%d 项 RED"
          % (len(tools), len(failed), total_ok, total_red))
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
