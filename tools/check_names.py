#!/usr/bin/env python3
"""人名泄漏检查器（推送前自查 ①）

为什么要脚本化（而不是手写 `git grep`）：
    ① **扫描基准要和 `tools/check_doc_refs.py` 一致** —— 都用 `git ls-files`
       这份"真正会入库"的清单，避免两套口径
    ② **手写排除规则容易和 `.gitignore` 失同步** —— 一旦某个目录被取消忽略，
       手写命令里的 `:(exclude)xxx` 还在，检查就会**静默漏掉**它
    ③ 一条命令、有退出码，CI 里可以直接跑

⚠️ 扫的是 **git 跟踪清单**，不是整个工作区。
   `files/历史/WorkBuddy记忆/` 这类**故意 gitignore 掉**的目录不在扫描范围内 ——
   这是对的：它们不入库，就不算泄漏（本项目对此有明确约定，见 CONTRIBUTING §五）。

设计原则（与 tools/check_doc_refs.py 一致）：
    · 依据 **git 跟踪清单**（`git ls-files`）—— 只查真正会入库的东西
    · **宁可漏报不可误报** —— 只做"子串命中"，不做姓名识别猜测
    · `names.local.txt` 本身不进仓库（已 gitignore），所以
      「要查什么名字」这件事也不会泄漏

用法：
    python tools/check_names.py                 # 用 names.local.txt
    python tools/check_names.py --init          # 生成模板
    python tools/check_names.py 张三 李四       # 直接用命令行给的姓名

退出码：0 = 干净；1 = 发现泄漏（CI 可据此失败）
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

# ── 输出编码兜底（与 tools/check_doc_refs.py 同一段）─────────
# ⚠️ Windows 控制台默认 GBK，遇到 emoji 会直接 UnicodeEncodeError 崩掉 ——
#    本机实测（2026-09-17）：不加重定向时 `python tools/check_names.py`
#    扫描本身是好的，却在**打印汇总行**时崩溃、退出码非 0，
#    读起来像"查出了人名"，实际是假警报。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAMES_FILE = os.path.join(REPO, 'names.local.txt')

# 只扫这些文本后缀，避免去解二进制
TEXT_EXT = {'.md', '.txt', '.py', '.yml', '.yaml', '.json', '.csv',
            '.cst', '.v', '.sv', '.vh', '.tcl', '.gprj', '.cfg', '.c', '.h'}


def git_tracked() -> list[str]:
    """git 跟踪清单（含已暂存/未跟踪但未被 ignore 的？—— 只要跟踪的）"""
    out = subprocess.run(['git', 'ls-files'], cwd=REPO,
                         capture_output=True, check=True).stdout
    return [p for p in out.decode('utf-8', 'replace').split('\n') if p.strip()]


def load_names(argv: list[str]) -> list[str]:
    if argv:
        return [n.strip() for n in argv if n.strip()]
    if not os.path.exists(NAMES_FILE):
        print('⚠️  没有 names.local.txt')
        print('   做法：把队友姓名每行一个写进该文件（已 gitignore，不会入库）')
        print('   这样「要查什么名字」这件事本身也不会进仓库。')
        print('   生成模板：python tools/check_names.py --init')
        return []
    names = []
    with open(NAMES_FILE, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                names.append(line)
    return names


def main() -> int:
    ap = argparse.ArgumentParser(description='人名泄漏检查（推送前自查 ①）')
    ap.add_argument('names', nargs='*', help='直接给出的姓名（覆盖 names.local.txt）')
    ap.add_argument('--init', action='store_true', help='生成 names.local.txt 模板')
    args = ap.parse_args()

    if args.init:
        if os.path.exists(NAMES_FILE):
            print(f'⚠️  {NAMES_FILE} 已存在，未覆盖')
            return 0
        with open(NAMES_FILE, 'w', encoding='utf-8') as f:
            f.write('# 队友姓名，每行一个（本文件已 gitignore，不会入库）\n'
                    '# 例：\n# 张三\n# 李四\n')
        print(f'✅ 已生成 {NAMES_FILE} —— 请把姓名填进去')
        return 0

    names = load_names(args.names)
    if not names:
        print('结论：⚠️ 未提供姓名，跳过（不算通过）')
        return 0

    files = git_tracked()
    hits: list[tuple[str, int, str, str]] = []
    scanned = 0
    for rel in files:
        if os.path.basename(rel) == 'names.local.txt':
            continue
        _, ext = os.path.splitext(rel)
        if ext.lower() not in TEXT_EXT:
            continue
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding='utf-8') as f:
                text = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        if not any(n in text for n in names):
            continue
        for lineno, line in enumerate(text.split('\n'), 1):
            for n in names:
                if n in line:
                    hits.append((rel, lineno, n, line.strip()[:120]))

    print(f'📄 扫了 {scanned} 个文本文件（依据 git 跟踪清单，共 {len(files)} 个文件）')
    print(f'   待查姓名 {len(names)} 个')
    if hits:
        print(f'\n❌ 发现 {len(hits)} 处人名泄漏：\n')
        for rel, lineno, n, line in hits:
            print(f'  {rel}:{lineno}  [{n}]')
            print(f'      {line}')
        print('\n修法：把姓名改成**角色**（"硬件负责人""FPGA 侧""队友"…）。')
        print('      ⛔ 不要用排除目录的办法"让它通过" —— 见本脚本 docstring。')
        return 1

    print('\n✅ 未发现人名 —— 自查 ① 通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
