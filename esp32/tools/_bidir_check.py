# -*- coding: utf-8 -*-
"""🔴 双向验证：把四组修复【各自改回旧写法】，确认回归判据必须变红（2026-10-14）。

═══ 为什么必须有 ═══
AGENTS 0.11 第 2 步："每条假设都要有红→绿判据：未修复时必须红，修复后必须绿"
0.11 §C83："探针假绿 —— 唯一判据是'跑未修复代码必须输出不同'"

⭐ 本轮修了 4 组问题，各自有自检：
   ① 和弦分轴      _chord_axis_check.js
   ② tempo 全发     _midi_parse_check.js
   ③ tempo 轨丢失   （靠 _diag_bpm + 上面那条）
   ④ 上传死锁       _deadlock_check.js
   ⑤ 未定义引用     _undef_check.js
⇒ 本脚本把【修复代码】临时改回旧写法，跑对应自检，⛔ 必须红。
   全绿 ⇒ 判据恒真 ⇒ 🔴 那组修复等于没保护。

⚠️ 做法：备份 -> 注入旧写法 -> 跑自检 -> 恢复 -> 再跑一次确认恢复成功。
   ⛔ 每一步都校验退出码；⛔ 恢复失败立即报错（⛔ 不许把破坏留在工作区）。
"""
import os, sys, io, subprocess, shutil
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(HERE, "score_studio.html")

def run(args, timeout=120):
    r = subprocess.run([sys.executable] + args if args[0].endswith(".py") else args,
                       capture_output=True, text=True, encoding="utf-8", cwd=HERE,
                       timeout=timeout)
    tail = (r.stdout or "").strip().split("\n")
    return r.returncode, (tail[-1] if tail else ""), r.stdout

results = []

def mutate(label, old, new, checker, expect_red=True):
    """在 HTML 里 old->new，跑 checker，看是否红，然后恢复"""
    bak = open(HTML, encoding="utf-8").read()
    if old not in bak:
        results.append((label, "SKIP", "锚点不在文件里（可能已重构）"))
        return
    open(HTML, "w", encoding="utf-8", newline="\n").write(bak.replace(old, new, 1))
    try:
        is_py = checker.endswith(".py")
        cmd = [sys.executable, "-X", "utf8", checker] if is_py else ["node", checker]
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           cwd=HERE, timeout=180)
        out = (r.stdout or "") + (r.stderr or "")
        went_red = (r.returncode != 0)
        ok = (went_red == expect_red)
        results.append((label, "OK" if ok else "RED",
                        "改回旧写法后 exit=%d（期望 %s）" %
                        (r.returncode, "非0" if expect_red else "0")))
    finally:
        # ⭐ 恢复 + 校验（⛔ 不许留破坏）
        open(HTML, "w", encoding="utf-8", newline="\n").write(bak)
        restored = open(HTML, encoding="utf-8").read() == bak
        if not restored:
            results.append((label + "（恢复）", "RED", "恢复后内容与备份不一致！"))

print("=" * 78)
print("双向验证：四组修复的回归判据【必须能失败】")
print("=" * 78)

# ---- ① 和弦分轴：把"贪心分配"改回"所有音共用第一个轴" ----
mutate("① 和弦分轴（_chord_axis_check）",
       '  for (const sg of segsAll) {\n    let pick = -1;',
       '  for (const sg of segsAll) {\n    let pick = 0; if (false) {',
       "_chord_axis_check.js", expect_red=True)

# ---- ② tempo 全发：把"每个 tempo 都发"改回"只发第一个" ----
mutate("② tempo 全发（_midi_parse_check）",
       '  for (const t of allTempos) {\n    if (firstTempoTick === 0',
       '  for (const t of []) {\n    if (firstTempoTick === 0',
       "_midi_parse_check.js", expect_red=True)

# ---- ④ gattSerial 自嵌套：把 sendCmd 改回"内部又入队" ----
mutate("④ gattSerial 自嵌套（_deadlock_check）",
       '  await chCmd.writeValueWithoutResponse(new Uint8Array([code]));',
       '  await gattSerial(async () => {\n    await chCmd.writeValueWithoutResponse(new Uint8Array([code]));\n  });',
       "_deadlock_check.js", expect_red=True)

# ---- ⑤ 未定义引用：把 axisSwatchColor 改名 ----
mutate("⑤ 未定义引用（_undef_check）",
       'function axisSwatchColor(a) {',
       'function axisSwatchColor_X(a) {',
       "_undef_check.js", expect_red=True)

print()
print("-" * 78)
bad = sum(1 for _, t, _ in results if t != "OK")
for lab, tag, note in results:
    print("  %s %-34s %s" % (tag, lab, note))
print()
print("结论：" + ("全部通过（判据都能失败）" if bad == 0 else "有 %d 项不符" % bad))

# 兜底：确保恢复干净
print()
cur = open(HTML, encoding="utf-8").read()
for k in ["function axisSwatchColor(a)", "await chCmd.writeValueWithoutResponse(new Uint8Array([code]));",
          "for (const t of allTempos) {", "for (const sg of segsAll) {"]:
    tag = "OK " if k in cur else "RED"
    print("  %s 恢复校验: %s" % (tag, k[:44]))

sys.exit(0 if bad == 0 else 1)
