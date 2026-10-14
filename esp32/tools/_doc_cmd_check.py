# -*- coding: utf-8 -*-
"""扫一遍待上机清单：每个 ```powershell 块必须【单行可粘贴】+ 参数真实存在。"""
import io, os, re, sys, subprocess
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.normpath(os.path.join(HERE, "..", "..", "files", "20-代码",
                                    "待上机验证清单-20261014.md"))
s = open(DOC, encoding="utf-8").read()
bad = 0

blocks = re.findall(r"```powershell\n(.*?)```", s, re.S)
print("  共 %d 个 powershell 块" % len(blocks))

for bi, b in enumerate(blocks, 1):
    lines = [x for x in b.strip().split("\n") if x.strip()]
    if not lines:
        continue
    # ⚠️ 纯注释块（每行都以 # 开头）不是命令 ⇒ 跳过
    if all(ln.lstrip().startswith("#") for ln in lines):
        continue
    # ⚠️ 块首的说明性注释允许存在（文档需要它解释"逐行跑/换端口"）——
    #   ⭐ 判据只看【第一条真正的命令】往后是否有续行符。
    cmd_start = 0
    while cmd_start < len(lines) and lines[cmd_start].lstrip().startswith("#"):
        cmd_start += 1
    cmds = lines[cmd_start:]
    if not cmds:
        continue
    # 单行可粘贴：除最后一行外，每行必须以分号或续行符衔接
    # ⚠️ 若块内【自己】说明了"逐行跑"，允许多条独立命令
    #   （🔴 判据必须只看【本块】—— 我第一版搜整个文件，块7 的"逐行跑"
    #      让注入的多行块也逃过检查 ⇒ 非空洞性失败）。
    allow_multi = "逐行跑" in b
    for k, ln in enumerate(cmds[:-1]):
        if allow_multi:
            break
        if not ln.rstrip().endswith((";", "\\", "|", "`")):
            print("  RED 块%d 命令第%d 行后没续行符（不能整块粘贴）：%s" %
                  (bi, k + 1, ln.strip()[:60]))
            bad += 1
            break
    # 引号配平（只看命令行）
    whole = "\n".join(cmds)
    if whole.count('"') % 2 != 0:
        print("  RED 块%d 引号不配平（粘贴必报错）" % bi)
        bad += 1

# 抽出所有 --flag，核对脚本是否支持
flags = set()
for b in blocks:
    for m in re.finditer(r"--([a-z][a-z0-9-]+)", b):
        flags.add(m.group(1))
print()
print("  清单里出现的参数：%s" % ", ".join(sorted(flags)))

# 从块里抽出脚本名，读它的参数
scripts = set()
for b in blocks:
    for m in re.finditer(r"python(?:\.exe)?\s+(?:-X\s+utf8\s+)?([\w.-]+\.py)", b):
        scripts.add(m.group(1))
print("  引用到的脚本：%s" % ", ".join(sorted(scripts)))

for sc in sorted(scripts):
    p = os.path.join(HERE, sc)
    if not os.path.exists(p):
        print("  RED %s 不存在" % sc); bad += 1; continue
    t = open(p, encoding="utf-8").read()
    mine = set(re.findall(r"add_argument\(\s*[\"']--([a-z0-9-]+)", t))
    # ⭐ 必须按【同一行】归属 flag —— ⛔ 不能按整个块（一个块里有多个脚本，
    # 按块归属会把 A 的 flag 判成 B 不支持：实测把 hmi_states 的 --events
    # 误判成 hmi_song_check.py 不支持 ⇒ 误报）。这就是 0.12 说的"同类路径要枚举"。
    for b in blocks:
        for ln in b.split("\n"):
            if sc not in ln:
                continue
            for fl in re.findall(r"--([a-z][a-z0-9-]+)", ln):
                if fl not in mine:
                    print("  RED %s 【不支持】 --%s（清单同一行里却用了）" % (sc, fl))
                    bad += 1

print()
print("结论：" + ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
sys.exit(0 if bad == 0 else 1)
