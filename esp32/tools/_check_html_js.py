#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_check_html_js.py —— 从 HTML 里抽出 <script> 做真正的语法检查

为什么需要它：改完网页不能只靠"看起来对"。
  单文件 HTML 里的 JS 语法错误只有打开浏览器才暴露，
  而这里可以离线用 node --check 抓出来。

判据：每个 <script> 块都能通过 node --check。
"""

import os
import re
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["score_studio.html", "upstream_studio.html", "link_test.html"]

# 只取【没有 src 属性】的内联 script（外链的没得查）
SCRIPT_RE = re.compile(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>",
                       re.S | re.I)


def main():
    print("=" * 70)
    print("HTML 内联 JS 语法检查（node --check）")
    print("=" * 70)
    bad = 0
    for fn in FILES:
        p = os.path.join(HERE, fn)
        if not os.path.exists(p):
            print("  %-26s 跳过（文件不存在）" % fn)
            continue
        src = open(p, encoding="utf-8").read()
        blocks = SCRIPT_RE.findall(src)
        if not blocks:
            print("  %-26s 跳过（没有内联 script）" % fn)
            continue
        for i, b in enumerate(blocks):
            # node --check 只接受【模块或脚本】；用 .js 后缀
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                             encoding="utf-8") as f:
                f.write(b)
                tmp = f.name
            try:
                r = subprocess.run(["node", "--check", tmp],
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace")
                if r.returncode == 0:
                    print("  %-26s 块%d  OK   %d 字符" % (fn, i, len(b)))
                else:
                    bad += 1
                    print("  %-26s 块%d  RED" % (fn, i))
                    for ln in (r.stderr or "").splitlines()[:6]:
                        print("        " + ln)
            finally:
                os.unlink(tmp)
    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 个块语法错" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
