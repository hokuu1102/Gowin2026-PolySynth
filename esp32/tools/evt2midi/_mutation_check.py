#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""⭐⭐ 非空洞性证明：⭐ **故意注入变异 ⇒ 自检必须报 RED**。

═══ 为什么必须做这件事 ═══
🔴 **"跑通了"不算证明。** ⚠️ 一个判据可能**永远不会红**（⭐ 恒真 / 自指 / 自算期望值），
   ⇒ 🔴 那样的"全绿"是**假绿** —— ⭐ 它什么都没保护（⭐ 见经验库 `C83`）。
⇒ ⭐ **唯一可信的证明**：⭐ **把代码改坏，输出必须不同**。

═══ 做法（⭐ 安全第一）═══
   ① 备份原文件到**临时目录**（⭐ 仓库外）
   ② **就地**注入变异（⭐ 只改一处、⭐ 改前先断言"这段文本唯一命中"）
   ③ 跑自检，⭐ 抓 RED 原文
   ④ `finally` 里**还原**并**校验 SHA-256 一致**（⚠️ 不一致就大声报错）

用法：
    python _mutation_check.py           # 跑全部变异
    python _mutation_check.py -v        # 顺带打印每个变异的完整输出
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ⭐⭐ 变异表：⭐ 每条只改**一处**，⛔ 不叠加（⭐ 否则分不清是谁的功劳）
MUTATIONS = [
    {
        "name": "① 校验函数恒返回 0（⭐ 校验形同虚设）",
        "file": "frame_format.py",
        "old": "    c = 0\n    for x in b[:-1]:\n        c ^= x\n    return c & 0xFF",
        "new": "    return 0",
        "why": "🔴 校验一失效，坏帧就会被当好帧收下 ⇒ ④b / ⑥ / ⑪ / ⑮ 必须红",
    },
    {
        "name": "② 帧长一律 14（⭐ 表同步 68 B 被切开）",
        "file": "frame_format.py",
        "old": "    return FRAME_LEN_BY_TYPE.get(ftype)",
        "new": "    return FRAME_LEN_DEFAULT",
        "why": "🔴 68 B 表帧会被当 14 B 音符帧 ⇒ ⑧b 必须红",
    },
    {
        "name": "③ 去掉 `parse_frame` 的长度校验（⭐ 半帧/错位照收）",
        "file": "frame_format.py",
        "old": "    if len(f) != want:",
        "new": "    if False:",
        "why": "🔴 长度不符也照解 ⇒ `frame_format` §6 必须红",
    },
    {
        "name": "④ `CLK_HZ` 改成音频帧率（⭐ 那个 1024× 错解）",
        "file": "evt2midi.py",
        "old": "CLK_HZ = 50_000_000.0",
        "new": "CLK_HZ = 48_828.125",
        "why": "🔴 `phase_inc → 音符号` 会差 1024× ⇒ ① 必须红",
    },
    {
        "name": "⑤ Δt 不取模（⭐ 朴素相减）",
        "file": "evt2midi.py",
        "old": "            step = (e.tick - prev_fpga_tick) % (1 << 32)",
        "new": "            step = (e.tick - prev_fpga_tick)",
        "why": "🔴 回绕时 Δ 变负 ⇒ ⑤ 的读回判据必须红",
    },
    {
        "name": "⑥ 解析器完全不校验（⭐ 坏帧照收）",
        "file": "evt2midi.py",
        "old": "            if frame_checksum(f) != f[flen - 1]:",
        "new": "            if False:",
        "why": "🔴 位翻转帧会被当正常值 ⇒ ④b / ⑥ / ⑪ 必须红",
    },
    {
        "name": "⑦ inc=0 不计数（⭐ 直接落进普通分支）",
        "file": "evt2midi.py",
        "old": "            if not e.inc:",
        "new": "            if False:",
        "why": "🔴 `inc = 0` 的记账会丢 ⇒ ⑫ 必须红",
    },
    {
        "name": "⑧ 不写 Tempo 元事件（⭐ 文件不自描述速度）",
        "file": "evt2midi.py",
        "old": ("    out += var_len(0) + bytes([0xFF, 0x51, 0x03]) "
                "+ us_per_qn.to_bytes(3, \"big\")"),
        "new": "    pass",
        "why": "🔴 `--bpm` 只改内部换算、文件里没有速度 ⇒ ⑭ 必须红",
    },
]

TARGETS = [
    ("evt2midi.py --selftest", ["evt2midi.py", "--selftest"]),
    ("frame_format.py", ["frame_format.py"]),
    ("midi_verify.py --selftest", ["midi_verify.py", "--selftest"]),
]


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def run_targets():
    """⭐ 跑全部自检，返回 (合并输出, 每个目标的 rc)。"""
    outs = []
    rcs = []
    for label, argv in TARGETS:
        r = subprocess.run([sys.executable] + argv, cwd=HERE,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=180)
        outs.append("### %s (rc=%d)\n%s" % (label, r.returncode,
                                           (r.stdout or "") + (r.stderr or "")))
        rcs.append((label, r.returncode))
    return "\n".join(outs), rcs


def red_lines(out):
    return [ln.strip() for ln in out.splitlines() if "RED" in ln]


def ok_count(out):
    """⭐ 与 `selftest_all.py` 同口径：⭐ 数独立的 `OK` 记号。"""
    return len(re.findall(r"\bOK\b", out))


def main():
    ap = argparse.ArgumentParser(description="变异测试：⭐ 改坏 ⇒ 必须报 RED")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印完整输出")
    args = ap.parse_args()

    print("=" * 78)
    print("非空洞性证明：⭐ 注入变异 ⇒ 自检必须报 RED")
    print("=" * 78)

    # ---- ① 基线 ----
    print("\n[基线] 未变异时跑一遍")
    base_out, base_rcs = run_targets()
    base_red = red_lines(base_out)
    base_ok = ok_count(base_out)
    print("  rc: %s" % ", ".join("%s=%d" % (l, rc) for l, rc in base_rcs))
    print("  OK 行 = %d，RED 行 = %d" % (base_ok, len(base_red)))
    if base_red:
        print("  🔴 基线就有 RED ⇒ ⛔ 先修好再谈变异")
        for ln in base_red:
            print("     " + ln)
        return 1

    backup_dir = tempfile.mkdtemp(prefix="evt2midi_mutbak_")
    print("  备份目录：%s" % backup_dir)

    results = []
    for m in MUTATIONS:
        path = os.path.join(HERE, m["file"])
        orig = open(path, "rb").read()
        digest = sha256(orig)
        shutil.copyfile(path, os.path.join(backup_dir, m["file"] + "." + digest[:8]))
        text = orig.decode("utf-8")

        n_hit = text.count(m["old"])
        if n_hit != 1:
            results.append((m, "SKIP", ["⚠️ 变异锚点命中 %d 次（⭐ 应为 1）⇒ ⛔ 无法判定"
                                        % n_hit], ""))
            continue

        mutated = text.replace(m["old"], m["new"], 1)
        try:
            with open(path, "wb") as f:
                f.write(mutated.encode("utf-8"))
            out, rcs = run_targets()
            reds = red_lines(out)
            okc = ok_count(out)
            changed = (out != base_out)
            verdict = "RED" if (reds and changed) else ("NO-RED" if changed else "NO-CHANGE")
            results.append((m, verdict, reds, "  OK 行 %d→%d；rc %s"
                            % (base_ok, okc,
                               ", ".join("%s=%d" % (l, rc) for l, rc in rcs))))
            if args.verbose:
                print("\n---- %s 完整输出 ----" % m["name"])
                print(out)
        finally:
            with open(path, "wb") as f:
                f.write(orig)
            after = sha256(open(path, "rb").read())
            if after != digest:
                print("🔴🔴 还原失败！%s 的 SHA-256 不一致（%s → %s）"
                      % (m["file"], digest[:12], after[:12]))
                print("     备份在 %s" % backup_dir)
                return 2

    # ---- 报告 ----
    print()
    print("=" * 78)
    print("变异结果（⭐ 判据：⭐ **每一条都必须 RED**）")
    print("=" * 78)
    n_bad = 0
    for m, verdict, reds, extra in results:
        mark = "✅ RED" if verdict == "RED" else "🔴 " + verdict
        print()
        print("%s  %s" % (mark, m["name"]))
        print("     文件：%s" % m["file"])
        print("     为什么该红：%s" % m["why"])
        print("     变异：%s" % m["new"].strip().replace("\n", " "))
        if extra:
            print("    %s" % extra)
        for ln in reds[:6]:
            print("     RED> %s" % ln)
        if len(reds) > 6:
            print("     ... 另有 %d 条 RED" % (len(reds) - 6))
        if verdict != "RED":
            n_bad += 1

    print()
    print("=" * 78)
    print("还原校验：全部文件 SHA-256 与变异前一致 ✅")
    print("合计：%d 个变异，%d 个成功报 RED，%d 个未报 RED"
          % (len(results), sum(1 for _m, v, _r, _e in results if v == "RED"), n_bad))
    print("结论：%s" % ("非空洞性成立 ✅（每条变异都能被判据抓住）"
                       if n_bad == 0 else "🔴 有 %d 条变异【没能】被判据抓住 ⇒ 判据是假绿"
                       % n_bad))
    print("=" * 78)
    shutil.rmtree(backup_dir, ignore_errors=True)
    return 0 if n_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
