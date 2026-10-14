# -*- coding: utf-8 -*-
"""全量自查：真机工具是否对【旧的固定 axis 分配】有隐含假设（2026-10-14）。

═══ 为什么必须有 ═══
本轮改了 axis 分配（从"按音色固定轴"改成"按段贪心动态分配"）：
  · 原来 Guitar I/II/III 全在 axis 0
  · 现在会动态用 axis 0~9
⇒ ⚠️ 任何【断言 axis 具体值】的真机判据都可能：
   a) 假红 —— 判据期望 axis 0，实际是 axis 3
   b) 假绿 —— 判据只验 axis 0，别的轴错了看不出来
⇒ 🔴 接硬件前必须全查一遍，否则上机会连撞

⭐ 做法：grep 所有 python/node 工具里的 axis 相关断言/取用，
   逐条判定"是否依赖固定 axis"。
"""
import os, re, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
BAD = 0
bad = 0
rows = []

# 我们自己的页面是"唯一生成 axis 的地方" —— 跳过它（它就是要改的）
SKIP = {"score_studio.html", "upstream_studio.html", "link_test.html",
        "_undef_check.js", "_chord_axis_check.js", "_display_check.js",
        "_drum_track_check.js", "_deadlock_check.js", "_diag_bpm.js",
        "_diag_chord.js", "_diag_chord5.js", "_diag_concurrency.js"}

# 【硬断言】= 会把具体 axis 值当判据（最危险）
HARD = re.compile(r"axis\s*[=!]=\s*\d+|axis\s*[<>]=?\s*\d+|==\s*axis\b.*\d")
# 【取用】= 读了 axis 字段（可能依赖）
SOFT = re.compile(r"\baxis\b")

for root, dirs, files in os.walk(HERE):
    dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git", "node_modules")]
    for fn in files:
        if fn in SKIP:
            continue
        if not fn.endswith((".py", ".js")):
            continue
        p = os.path.join(root, fn)
        try:
            txt = open(p, encoding="utf-8").read()
        except Exception:
            continue
        hard_hits, soft_hits = [], []
        for i, ln in enumerate(txt.split("\n"), 1):
            # 剥注释再判
            code = re.sub(r"#.*$", "", ln)
            code = re.sub(r"//.*$", "", code).strip()
            if not code:
                continue
            if HARD.search(code):
                hard_hits.append((i, code[:110]))
            elif SOFT.search(code):
                soft_hits.append((i, code[:110]))
        if hard_hits or soft_hits:
            rows.append((os.path.relpath(p, HERE), hard_hits, soft_hits))

# ⭐ 白名单（必须放在【打印前、循环外】—— ⛔ 放循环里对最终判据无效，踩过）
#   这两处【安全】，⛔ 不是"固定 axis"假设：
#     · evt2midi/evt2midi.py:450  `if axis > 15:` —— 范围校验（合法域 0..15）
#     · score_word.py:320       `old_axis != 3` —— 自检里【构造的测试数据】
#   ⚠️ 非空洞性：从白名单去掉任一 (文件, 行号) ⇒ 立刻变红
FILTERED_WHITELIST = {("evt2midi\\evt2midi.py", 450), ("score_word.py", 320)}
rows = [(rel, [(i, t) for (i, t) in hard if (rel, i) not in FILTERED_WHITELIST], soft)
        for (rel, hard, soft) in rows]

print("=" * 78)
print("自查：真机/离线工具对 axis 的显式依赖（本轮改成动态分配后必须核）")
print("=" * 78)
print("  跳过本轮自己改过的页面自检：%d 个" % len(SKIP))
print()

if not rows:
    print("  OK 没有任何工具显式读 axis")
    sys.exit(0)

# ⭐ 白名单：这两处是【安全】的，⛔ 不是"固定 axis"假设
#   · evt2midi.py:450  `if axis > 15:` —— 范围校验（0..15 合法域）
#   · score_word.py:320 `old_axis != 3` —— 自检里【构造的测试数据】，不是对生成器的假设
# ⚠️ 若去掉白名单，这两条会报 RED ⇒ 非空洞性成立（不会恒绿）
WHITELIST = {
    ("evt2midi\\evt2midi.py", 450),
    ("score_word.py", 320),
}

for rel, hard, soft in sorted(rows):
    tag = "RED" if hard else "OK "
    print("  %s %-28s 硬断言 %d 处  读 axis %d 处" % (tag, rel, len(hard), len(soft)))
    for i, t in hard:
        print("        L%-5d 硬断言: %s" % (i, t))
    if not hard:
        for i, t in soft[:3]:
            print("        L%-5d 读 axis: %s" % (i, t))
        if len(soft) > 3:
            print("        ...（共 %d 处）" % len(soft))
    print()

if any(h for _, h, _ in rows):
    print("  结论：有硬断言 => 需逐条判是否仍成立")
    sys.exit(1)
else:
    print("  结论：只有软读用，无硬断言 => 不会因动态分配假红")
    sys.exit(0)

# ⭐ 供 run_all_tests.py 汇总用：只打结论行
if "--selftest" in sys.argv:
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    sys.exit(0 if bad == 0 else 1)
