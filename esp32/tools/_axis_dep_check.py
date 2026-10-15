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
        "_diag_chord.js", "_diag_chord5.js", "_diag_concurrency.js",
        # ⭐ 2026-10-15：本文件【自己】也跳过 —— 白名单里就写着 `axis >= 12`（那是
        #   协议边界的正则），⛔ 不该把自己算成"对固定 axis 有假设的工具"。
        "_axis_dep_check.py"}

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

# ⭐⭐ 白名单：这些是【安全】的硬断言，⛔ 不是"固定 axis 分配"假设。
#   ⚠️ 2026-10-15 改成【按内容匹配】，⛔ 不再按行号 ——
#     🔴 实测踩到：行号式白名单在"它上面插了几行"之后就失效：
#        我往 evt2midi.py 里加了注释 ⇒ 白名单指的 450 行不再是那句
#        ⇒ 🔴 误报 RED（判据依赖"第几行"这种会漂的东西，同族 C91）。
#   ⭐ 每条 = (文件后缀, 该行内容的正则)：
#     · `evt2midi/evt2midi.py` 的 `if axis > 15:` —— ⭐ 范围校验（合法域 0..15）
#     · `evt2midi/evt2midi.py` 的 `evs_ax[0].axis == 15` —— ⭐ 掩码上限（4 bit 字段）
#     · `score_word.py` 的 `old_axis != 3` —— ⭐ 自检里【构造的测试数据】
#   ⚠️ 非空洞性：把任一条从 WHITELIST 去掉 ⇒ 立刻变红（已实测）。
WHITELIST = [
    ("evt2midi/evt2midi.py", re.compile(r"if\s+axis\s*>\s*15\s*:")),
    ("evt2midi/evt2midi.py", re.compile(r"evs_ax\[0\]\.axis\s*==\s*15")),
    ("score_word.py",        re.compile(r"old_axis\s*!=\s*3")),
    # ⭐ 2026-10-15 方案 B：`axis >= 12` 是【协议边界】（与 `seq_arb.v:204` 逐字一致：
    #   axis >= 12 ⇒ 鼓），⛔ 不是"旧的固定 axis 分配"假设 —— 这几处正是在【说明/判据】该边界。
    ("_inspect_midi.js",     re.compile(r"axis >= 12")),
    ("_midi_parse_check.js", re.compile(r"axis >= 12")),
    ("drum_map.py",          re.compile(r"axis >= 12")),
]


def _whitelisted(rel, code):
    """⭐ 这一行是否属于【已知安全】的硬断言（按内容判，⛔ 不看行号）"""
    r = rel.replace("\\", "/")
    return any(r.endswith(sfx) and pat.search(code) for sfx, pat in WHITELIST)


rows = [(rel, [(i, t) for (i, t) in hard if not _whitelisted(rel, t)], soft)
        for (rel, hard, soft) in rows]

print("=" * 78)
print("自查：真机/离线工具对 axis 的显式依赖（本轮改成动态分配后必须核）")
print("=" * 78)
print("  跳过本轮自己改过的页面自检：%d 个" % len(SKIP))
print()

if not rows:
    print("  OK 没有任何工具显式读 axis")
    sys.exit(0)

# ⚠️ 白名单已在上面定义并使用（⛔ 这里不再重复一份 —— 两份必然漂，同族 C91）。

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
