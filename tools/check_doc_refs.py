#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
校验文档里的交叉引用是否有效。

为什么需要这个：
    本项目文档量大、互相引用多（索引 / 总纲 / 选型表 / 决议清单），
    引用一旦写错就是「点不开」—— 而写文档的人不会每次都去点一遍。

⭐⭐ 核心设计：以【git 跟踪清单】为依据，而不是直接扫文件系统。

    这是踩过一次坑才定下的。原来的写法用路径是否存在来判断，结果：
      · 本地绿 —— `files/历史/WorkBuddy记忆/` 就在硬盘上（它只是被
        gitignore 了），所以"存在"，检查通过；
      · CI 红 —— CI 检出的是【已提交的文件】，被 gitignore 的目录
        根本不在里面，于是同一个引用判为"不存在"。
    同一份代码、同一个仓库，两个环境结论相反 —— 这是最难查的一类故障。

    改用 `git ls-files --cached --others --exclude-standard`
    （= 已跟踪 + 未跟踪但未被忽略 = "提交后仓库里会有的文件"）后：
      · 本地与 CI 语义一致：本地绿 ⇒ CI 绿
      · 顺带抓到「引用了一个忘记 git add 的文件」
      · 大小写天然精确（字符串比对，不再是 Windows 不敏感 / Linux 敏感）
      · .git 目录无需特判

⭐ 第二条设计原则：**宁可漏报，不可误报**。
    一个会误报的检查器比没有检查器更糟 —— 它会训练队友忽略它。
    所以下面这些「看起来可疑但其实合法」的写法一律放过：

    · 引用基准：同时接受【仓库根相对】【所在文件相对】【files/ 相对】
      三种写法（旧文档大量使用 files/ 相对，是合法的）
    · 索引表的裸文件名（`文档地图.md` 的「文件 | 位置」两列结构，
      目录由另一列给出，裸名是正确写法）→ 只提示，不判失败
    · 仓库外的本机路径（Desktop\\... / C:\\...）→ 跳过
    · URL 路径片段（/nuedc/）→ 跳过
    · 含通配符、占位符、或出现在命令示例里的 → 跳过

用法：
    python tools/check_doc_refs.py              # 在仓库根运行
    python tools/check_doc_refs.py --warn-only  # 只报告，始终退出 0

退出码：0 = 通过；1 = 有【硬错误】（引用指向不存在的文件/目录）
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

# ── 输出编码兜底 ───────────────────────────────────────
# Windows 控制台默认 GBK，遇到 emoji / 生僻字会直接 UnicodeEncodeError 崩掉。
# CI（ubuntu）本来就是 UTF-8，这里主要是让本地 `python tools/...` 也能跑。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# ── 视为「文件引用」的扩展名 ────────────────────────────
DOC_EXT = {
    ".md", ".txt", ".pdf", ".png", ".jpg", ".jpeg", ".svg", ".webp",
    ".stl", ".step", ".stp", ".sldprt", ".sldasm", ".dxf",
    ".csv", ".json", ".yml", ".yaml", ".xlsx", ".docx", ".zip",
    ".v", ".sv", ".vhd", ".c", ".h", ".py", ".ps1",
}
# 注：不再按扩展名区分「裸文件名」的处理方式 —— 见文件末尾 check_file 里的说明。
#     （早先只放过 .md/.pdf 等少数扩展名，导致 .v/.py/.cst 的裸名被误判成硬错误）

# ── 不扫描 .md 的目录 ──────────────────────────────────
# files/历史/ 是历史留档，故意保留旧引用（旧文件名/旧结构），
# 检查它只产生噪音，且改它等于篡改历史记录。
SCAN_SKIP_DIRS = {"files/历史", "tools"}

# ── 仓库外的本机路径前缀（跳过，不判失败）───────────────
EXTERNAL_HINTS = ("Desktop", "Users", "Documents", "AppData", "~")

RE_BACKTICK = re.compile(r"`([^`\n]+)`")
RE_MDLINK = re.compile(r"\]\(([^)\s]+)\)")

# ── 内联豁免标记（相当于 # noqa）────────────────────────
# ⭐ 为什么必须有：`files/文档地图.md` 的《路径校正表》**故意**把
#    「错误写法」列在左列 —— 那是它的全部意义。没有豁免机制的话，
#    检查器会去举报这张表存在的目的本身。
#
#    <!-- refcheck:ignore-line -->                      只豁免本行
#    <!-- refcheck:off --> … <!-- refcheck:on -->       豁免一段
MARK_IGNORE_LINE = "refcheck:ignore-line"
MARK_OFF = "refcheck:off"
MARK_ON = "refcheck:on"

# ── 「举例用」的路径名，不是真的仓库路径 ────────────────
# 两类来源：
#   ① `.gitignore` 文档里引用的【忽略模式】本身
#      例：CONTRIBUTING.md 写 `History/`（Altium 的输出目录），
#          本仓库本就没有这个目录 —— 这是正确写法。
#   ② 文档里点名说明「已被排除」的路径
#      例：`files/历史/WorkBuddy记忆/`，它正是被 gitignore 的目录，
#          仓库里【本来就不该有】—— 引用它是在说明"这里不公开"。
EXAMPLE_PATH_NAMES = {
    "History", "Project Outputs", "__Previews",
    "node_modules", "dist", "build", "out",
    "WorkBuddy记忆",
    # 通用 EDA / 构建产物目录名：文档里提到它们是在描述"会生成这个目录"，
    # 不是在引用仓库里的某个路径（例：gw_sh 会写 impl/ 目录）
    "impl", "pnr", "gwsynthesis", "temp", "logs",
}


def get_tracked_files(repo: Path) -> set[str] | None:
    """
    取【提交后仓库里会有的文件】清单（posix 相对路径）。

    = git ls-files --cached --others --exclude-standard
      （已跟踪 + 未跟踪但未被忽略）

    返回 None 表示 git 不可用 —— 调用方需要退回扫文件系统，
    并应提示「本地结论可能与 CI 不一致」。
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=str(repo),
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return {p for p in out.decode("utf-8", "surrogateescape").split("\0") if p}


def looks_like_ref(s: str) -> bool:
    """粗筛：这段文本是否有可能是路径引用。"""
    s = s.strip()
    if not s or len(s) > 300 or "\n" in s:
        return False
    if s.startswith(("http://", "https://", "#", "mailto:", "/", "~")):
        return False                      # URL / 锚点 / 绝对路径片段
    if "//" in s:
        return False
    if any(ch in s for ch in "*?<>|{}\"' \t"):
        return False                      # 通配符 / 占位符 / 含空格（命令）
    if ":" in s:
        return False                      # 盘符、URL scheme、标题
    if s.startswith(("git", "python", "pnpm", "npm", "pwsh", "$", "-")):
        return False
    seg = re.split(r"[\\/]", s)[0]
    if seg in EXTERNAL_HINTS:
        return False                      # 仓库外的本机路径
    return True


def normalize_ref(ref: str) -> str:
    """统一分隔符、剥掉开头的 ./、去掉结尾的 /。"""
    rel = ref.replace("\\", "/")
    # ⚠️ 只能用 startswith 剥前缀，绝不能用 lstrip("./") ——
    #    lstrip 的参数是【字符集】不是前缀，会把 `.github/x.yml`
    #    剥成 `github/x.yml`，于是所有点开头的路径都变成假警报。
    if rel.startswith("./"):
        rel = rel[2:]
    return rel.rstrip("/")


def resolve(ref: str, md_rel_dir: str, tracked: set[str]) -> bool:
    """
    在【git 跟踪清单】里找这个引用。三种基准都试一遍。

    为什么接受三种：本项目旧文档大量写【files/ 相对】路径
    （例：files/ 下的文档写 `方案抉择/左手区方案.md`），
    这是历史的合法写法；一刀切只认仓库根会产生大量误报。
    新文档建议统一用【仓库根相对】。
    """
    rel = normalize_ref(ref)
    candidates = [rel]
    if md_rel_dir:
        candidates.append(f"{md_rel_dir}/{rel}")
    candidates.append(f"files/{rel}")

    for cand in candidates:
        if cand in tracked:                       # 文件
            return True
        prefix = cand + "/"
        if any(t.startswith(prefix) for t in tracked):   # 目录
            return True
    return False


def check_file(
    rel: str,
    repo: Path,
    tracked: set[str],
    hard: list[tuple[str, int, str]],
    soft: list[tuple[str, int, str]],
) -> None:
    md = repo / rel
    try:
        lines = md.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError) as exc:
        hard.append((rel, 0, f"文件读不了：{exc}"))
        return

    parent = PurePosixPath(rel).parent
    md_rel_dir = "" if str(parent) == "." else str(parent)

    in_off = False
    for lineno, line in enumerate(lines, start=1):
        # 豁免区 / 豁免行
        if MARK_OFF in line:
            in_off = True
            continue
        if MARK_ON in line:
            in_off = False
            continue
        if in_off or MARK_IGNORE_LINE in line:
            continue

        raw_refs = [m.group(1) for m in RE_BACKTICK.finditer(line)]
        raw_refs += [m.group(1) for m in RE_MDLINK.finditer(line)]

        for raw in raw_refs:
            if not looks_like_ref(raw):
                continue
            ref = raw.strip().rstrip(".,;:）)")
            is_dir_ref = ref.endswith("/")

            if is_dir_ref and normalize_ref(ref).split("/")[-1] in EXAMPLE_PATH_NAMES:
                continue                            # 举例用的路径，不是仓库路径

            if is_dir_ref:
                if not resolve(ref, md_rel_dir, tracked):
                    hard.append((rel, lineno, ref))
                continue

            ext = os.path.splitext(ref.lower())[1]
            if ext not in DOC_EXT:
                continue

            is_bare = "/" not in ref and "\\" not in ref

            if resolve(ref, md_rel_dir, tracked):
                if is_bare:
                    soft.append((rel, lineno, ref))
                continue

            if is_bare:
                # ⭐ 裸文件名一律归入【提示】，不判失败 —— 与扩展名无关。
                #    理由：裸名在这类文档里有大量合法用法（索引表的「文件|位置」、
                #    提到外部资产的文件名、说明某个生成物的名字…），
                #    而它是不是"坏引用"取决于上下文，检查器判断不了。
                #    （早先只放过 .md/.pdf 等少数扩展名，结果 .v/.py/.cst
                #     被误判成硬错误 —— 又一个"误报训练人忽略检查器"的例子。）
                soft.append((rel, lineno, ref + "  （仓库里找不到同名文件）"))
            else:
                hard.append((rel, lineno, ref))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warn-only", action="store_true", help="只报告，始终退出 0")
    ap.add_argument("--repo", default=".", help="仓库根（默认当前目录）")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()

    tracked = get_tracked_files(repo)
    if tracked is None:
        print("⚠️  拿不到 git 跟踪清单（git 不可用？）—— 退回扫描文件系统。")
        print("    注意：这个模式下【本地可能绿而 CI 会红】，")
        print("    因为被 gitignore 的文件在本地存在、在 CI 的检出里不存在。")
        print()
        tracked = {
            p.relative_to(repo).as_posix()
            for p in repo.rglob("*")
            if p.is_file() and ".git" not in p.relative_to(repo).parts
        }

    md_files = sorted(
        p for p in tracked
        if p.endswith(".md")
        and not any(p == d or p.startswith(d + "/") for d in SCAN_SKIP_DIRS)
    )

    hard: list[tuple[str, int, str]] = []
    soft: list[tuple[str, int, str]] = []

    for rel in md_files:
        check_file(rel, repo, tracked, hard, soft)

    print(f"📄 检查了 {len(md_files)} 个 Markdown 文件"
          f"（依据 git 跟踪清单，共 {len(tracked)} 个文件）")
    if SCAN_SKIP_DIRS:
        print(f"   已跳过扫描：{', '.join(sorted(SCAN_SKIP_DIRS))}")
    print()

    if hard:
        print(f"❌ 硬错误：{len(hard)} 处 —— 引用指向仓库里不存在的文件/目录")
        for src, lineno, ref in hard:
            print(f"    {src}:{lineno}  →  {ref}")
        print()
        print("   ⚠️ 注意：这里判断的是【已提交的文件】，不是硬盘上有什么。")
        print("      所以「我本地明明有」不是理由 —— 未 git add 的文件")
        print("      在 CI 的检出里不存在，引用它一样是坏的。")
        print()
    else:
        print("✅ 没有硬错误：所有引用都能解析到仓库里的实际文件")

    if soft:
        print()
        print(f"ℹ️  提示：{len(soft)} 处「裸文件名」（缺目录）")
        print("    这不一定是错 —— 索引表的「文件 | 位置」结构里裸名是正确写法。")
        print("    但正文引用建议写全，否则点击时按当前文档目录解析，容易点不开。")
        print("    写法：files/方案抉择/硬件选型表.md")
        for src, lineno, ref in soft[:15]:
            print(f"      {src}:{lineno}  →  {ref}")
        if len(soft) > 15:
            print(f"      …… 还有 {len(soft) - 15} 处（提示项不影响结果）")

    print()
    if hard:
        print(f"结论：❌ 有 {len(hard)} 处硬错误，需要修。")
        print("参考 files/文档地图.md 里的「路径校正表」查正确路径。")
        return 0 if args.warn_only else 1
    print("结论：✅ 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
