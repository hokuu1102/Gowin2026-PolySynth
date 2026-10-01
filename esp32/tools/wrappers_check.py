#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wrappers_check.py —— ⭐ 机械检查：**没有人绕过 `start_action_*` 封装去直接改池状态**

═══ 为什么需要它（⭐ 这是"不变量"，⛔ 不是"补丁"）═══
🔴 实测缺陷（2026-10-01）：
    `case 0x01`（复位）**直接调 `pool_reset()`**，⛔ 没走 `start_action_reset()`
    ⇒ ⭐ `hmi_set_state(HMI_ST_IDLE)` 永不执行
    ⇒ 🔴 **屏上状态字永远进不了 `待机`**（`HMI_ST_IDLE` 成了死代码）。
⚠️ 而 `case 0x03`/`0x04` **都**走了封装 ⇒ ⭐ **只有一条路径漏了**。
📌 这正是 `C91`（⭐ 只补你想到的那条路径 = 修表象）的现场。

⭐⭐ **为什么要写成检查，而不是"记得以后别忘"**：
    ⭐ 判据（0.12 第③步）：⭐ **若"补完之后你还得记住以后别忘" ⇒ 那还是补丁**。
    ⇒ ⭐ 要把它变成**代码里的不变量** ⇒ ⭐ 让"绕过"**在 CI/自检里就红**。

═══ 判据 ═══
  ① `pool_reset()` / `pool_start()` / `pool_stop()` 的**每个**调用点，
     ⭐ 必须满足**其一**：
       · ⭐ 落在某个 `start_action_*()` 的**函数体内**（⭐ 那是唯一的合法封装）
       · ⭐ 该行带 `ALLOW-DIRECT-POOL-CALL` 显式豁免标记（⭐ 例外要看得见）
  ② ⭐ **非空洞性**：⭐ 造一个"绕过"的样本 ⇒ ⭐ 检查**必须报红**
     （⚠️ 否则"全绿"证明不了任何事，见 `C83` 探针假绿）

═══ 用法 ═══
    python wrappers_check.py --selftest     # ⛔ 不需要硬件
    python wrappers_check.py                # 检查真实源码
"""

import argparse
import os
import re
import sys

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "ble", "main", "ble_main.c")

# ⭐ 被封装保护的池状态改变函数
GUARDED = ("pool_reset", "pool_start", "pool_stop")
# ⭐ 合法封装的函数名前缀
WRAPPER = "start_action_"
# ⭐ 显式豁免标记（⭐ 例外必须写出来，⛔ 不许默默绕过）
ALLOW = "ALLOW-DIRECT-POOL-CALL"


def wrapper_ranges(lines):
    """
    ⭐ 找出每个 `start_action_*` 函数体占据的行号区间（⭐ 1-based，闭区间）。

    ⚠️ 实现说明：⭐ 用**朴素花括号配对** ——
       ⭐ 本文件的这些封装里**没有字符串/注释里的花括号**
       （⭐ 若将来有了，这里会算错 ⇒ ⚠️ 那时要换成"先剥字符串/注释"）。
       📌 之所以敢用朴素法：⭐ 自检里有一条**非空洞性**判据
          （⭐ 真源码里必须找到 ≥3 处封装内调用）
          ⇒ ⚠️ 一旦区间算错，"找不到封装内调用"会**当场报红**，⛔ 不会静默假绿。
    """
    spans = []
    n = len(lines)
    for i in range(n):
        if not re.match(r"^static\s+void\s+%s\w+\s*\(void\)\s*$" % WRAPPER,
                        lines[i].strip()):
            continue
        # ⭐ 从这一行往后找第一个 `{`，然后配对
        depth = 0
        seen_brace = False
        j = i
        while j < n:
            code = lines[j].split("//")[0]
            for ch in code:
                if ch == "{":
                    depth += 1
                    seen_brace = True
                elif ch == "}":
                    depth -= 1
            if seen_brace and depth <= 0:
                break
            j += 1
        spans.append((i + 1, min(j + 1, n)))
    return spans


def strip_block_comments(lines):
    """
    ⭐ 把 `/* ... */` 块注释（⭐ 可跨行）换成等长的空白，⛔ 保留行号。

    ⚠️ 为什么必须剥：⭐ 实测第一次跑时，**6 处"违规"全是注释里的散文**
       （⭐ 例如 "🔴 原来这里直接调 `pool_reset()` ⇒ 绕过了 wrapper"）
       ⇒ 🔴 检查**误报** ⇒ ⚠️ 而误报会让人**关掉检查**，比没有检查更坏。
    ⭐ 只剥块注释；`//` 行注释由调用方按行处理。
    """
    out = []
    in_block = False
    for ln in lines:
        res = []
        i = 0
        while i < len(ln):
            if in_block:
                j = ln.find("*/", i)
                if j < 0:
                    res.append(" " * (len(ln) - i))
                    i = len(ln)
                else:
                    res.append(" " * (j + 2 - i))
                    i = j + 2
                    in_block = False
            else:
                j = ln.find("/*", i)
                k = ln.find("//", i)
                if j < 0 or (k >= 0 and k < j):
                    res.append(ln[i:])
                    i = len(ln)
                else:
                    res.append(ln[i:j])
                    i = j
                    in_block = True
        out.append("".join(res))
    return out


def strip_strings(line):
    """⭐ 把字符串/字符字面量换成空白（⚠️ 避免把字面量里的函数名当调用）。"""
    res = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch in ('"', "'"):
            q = ch
            res.append(" ")
            i += 1
            while i < n:
                if line[i] == "\\":
                    res.append("  ")
                    i += 2
                    continue
                if line[i] == q:
                    res.append(" ")
                    i += 1
                    break
                res.append(" ")
                i += 1
        else:
            res.append(ch)
            i += 1
    return "".join(res)


def scan(lines):
    """⭐ 返回 (违规列表, 豁免列表, 封装内调用数, 封装区间)。"""
    code_lines = strip_block_comments(lines)
    spans = wrapper_ranges(code_lines)
    bad, allowed, inside = [], [], 0
    for idx, raw in enumerate(lines, start=1):
        code = strip_strings(code_lines[idx - 1].split("//")[0])
        for fn in GUARDED:
            # ⭐⭐ 关键：⭐ 必须是【语句位置】的调用 ——
            #    ⭐ 即整行以 `fn(` 开头（⭐ 允许前置的 `if (...)` / `else`）
            #    ⚠️ 这样"注释/字符串里提到函数名"就不会误报。
            if not re.search(r"^\s*(?:if\s*\([^)]*\)\s*|else\s+)?%s\s*\(" % fn,
                             code):
                continue
            if any(a <= idx <= b for a, b in spans):
                inside += 1
            elif ALLOW in raw:
                allowed.append((idx, raw.strip()))
            else:
                bad.append((idx, raw.strip()))
    return bad, allowed, inside, spans


def run_selftest():
    print("=" * 74)
    print("wrappers_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-50s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 合成样本：⭐ 一个合法的封装 + 一个【绕过】----
    good = [
        "static void start_action_reset(void)",
        "{",
        "    pool_reset();",
        "}",
    ]
    bad, allowed, inside, spans = scan(good)
    chk("合成①：封装内调用 ⇒ 合法", not bad and inside == 1,
        "  bad=%d inside=%d spans=%s" % (len(bad), inside, spans))

    leak = [
        "static void start_action_reset(void)",
        "{",
        "    pool_reset();",
        "}",
        "static void other(void)",
        "{",
        "    pool_reset();",        # 🔴 绕过
        "}",
    ]
    bad, allowed, inside, spans = scan(leak)
    chk("⭐⭐ 合成②：绕过 ⇒ 必须报红（非空洞性）",
        len(bad) == 1 and bad[0][0] == 7,
        "  bad=%s" % (bad,))

    marked = leak[:6] + ["    pool_reset();  /* ALLOW-DIRECT-POOL-CALL: 测试 */", "}"]
    bad, allowed, inside, spans = scan(marked)
    chk("合成③：带豁免标记 ⇒ 放行且记录",
        not bad and len(allowed) == 1, "  allowed=%d" % len(allowed))

    # ---- ② 真实源码 ----
    try:
        with open(SRC, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        chk("读到 ble_main.c", False, "  %s" % e)
        print()
        print("结论：有失败项")
        return 1
    chk("读到 ble_main.c", len(lines) > 500, "  %d 行" % len(lines))

    bad, allowed, inside, spans = scan(lines)
    chk("真实源码：无绕过（除豁免）", not bad,
        "  bad=%d allowed=%d inside=%d" % (len(bad), len(allowed), inside))
    for b in bad:
        print("      🔴 L%d: %s" % b)
    for a in allowed:
        print("      ⭐ L%d 豁免: %s" % (a[0], a[1][:60]))

    # ⭐ 非空洞性：⭐ 真源码里**必须确实存在**封装内调用
    #   ⚠️ 否则"没有绕过"是因为"压根没有调用"⇒ 检查是假的
    chk("⭐⭐ 非空洞：真源码里确有封装内调用", inside >= 3,
        "  inside=%d" % inside)
    chk("⭐ 确有 1 处显式豁免（开机初始化）", len(allowed) == 1,
        "  allowed=%d" % len(allowed))

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="检查是否有人绕过 start_action_* 封装")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    args = ap.parse_args()
    if args.selftest:
        return run_selftest()

    with open(SRC, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    bad, allowed, inside, spans = scan(lines)
    print("封装定义（行区间）: %s" % (spans,))
    print("封装内调用 %d 处 · 豁免 %d 处 · 🔴 绕过 %d 处"
          % (inside, len(allowed), len(bad)))
    for a in allowed:
        print("  ⭐ L%d 豁免: %s" % (a[0], a[1][:70]))
    for b in bad:
        print("  🔴 L%d 绕过: %s" % (b[0], b[1][:70]))
    if bad:
        print()
        print("🔴 有调用绕过了 start_action_* 封装 ⇒ "
              "池状态改了但屏上状态字不会更新。")
        return 1
    if inside == 0:
        print()
        print("🔴 一处封装内调用都没有 ⇒ 本检查是【空洞】的，⛔ 不能算通过。")
        return 1
    print()
    print("✅ 所有池状态改变都走封装（或已显式豁免）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
