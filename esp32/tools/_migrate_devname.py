#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_migrate_devname.py —— 把工具里的设备名比较改成【前缀匹配】

═══ 为什么需要 ═══
Windows 按 MAC 地址缓存 GATT 服务列表，不信板子的实际 GATT。
实测症状（2026-10-13）：
  板子固件完全正常（日志里 `attr table created OK`、`0xABF1`~`0xABF4`
  全部注册、`service started`），但 PC 连上后只能发现 4 个标准特征
  => `BleakCharacteristicNotFoundError`（0xABF3 not found）。
  复位、重烧固件都无效（都试过）—— 因为 MAC 地址没变。
换设备名让 Windows 当成新设备，缓存自然失效（见 ble_config.h 的说明）。

═══ 为什么用前缀匹配而不是改字符串 ═══
  22 个文件都写死了 `== "FPGA2026-Synth"`。
  若简单换成 `"FPGA2026-Synth2"`，下次再改名又得改 22 处。
  前缀匹配后 Synth / Synth2 / Synth3… 全都能认，改名零成本。

用法：
  python _migrate_devname.py            # 试运行，只报告
  python _migrate_devname.py --apply    # 真改
"""

import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))

CMP_PAT = re.compile(r'\(d\.name or ""\)\s*==\s*(DEV_NAME|DEV)\b')

DEF_PY = re.compile(
    r'^(?P<ind>[ \t]*)(?P<var>DEV_NAME|DEV)\s*=\s*"FPGA2026-Synth"\s*$', re.M)

DEF_JS = re.compile(
    r'^(?P<ind>[ \t]*)const\s+DEV_NAME\s*=\s*"FPGA2026-Synth"\s*;', re.M)

HELPER = '''

def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")
'''


def main():
    apply = "--apply" in sys.argv
    nfile = 0
    for fn in sorted(os.listdir(HERE)):
        p = os.path.join(HERE, fn)
        if not os.path.isfile(p) or not fn.endswith(".py"):
            continue
        if fn in ("_migrate_devname.py",):
            continue
        src = open(p, encoding="utf-8").read()
        if not CMP_PAT.search(src):
            continue
        orig = src
        # 1) 插入 DEV_PREFIX 常量（紧跟原定义之后）
        if "DEV_PREFIX" not in src:
            src = DEF_PY.sub(
                lambda m: ('%s%s = "FPGA2026-Synth"\n'
                           '%s# 前缀匹配（改名后备选）：见 _name_matches 的说明\n'
                           '%sDEV_PREFIX = "FPGA2026-Synth"'
                           % (m.group("ind"), m.group("var"),
                              m.group("ind"), m.group("ind"))),
                src, count=1)
        # 2) 比较改成 helper
        src = CMP_PAT.sub(lambda m: "_name_matches(d.name, %s)" % m.group(1), src)
        # 3) 插入 helper（放在第一个 import 之后）
        if "_name_matches" in src and "def _name_matches" not in src:
            m = re.search(r'^import .*$|^from .*$', src, re.M | re.S)
            # 插到【最后一个顶层 import 行】之后
            lines = src.split("\n")
            last_imp = 0
            for i, ln in enumerate(lines[:80]):
                if re.match(r'^(import |from )', ln):
                    last_imp = i
            lines.insert(last_imp + 1, HELPER)
            src = "\n".join(lines)

        if src != orig:
            nfile += 1
            print("  %-34s %s" % (fn, "已改" if apply else "(试运行)"))
            if apply:
                open(p, "w", encoding="utf-8", newline="").write(src)
    print()
    print("  共 %d 个文件%s" % (nfile, "已改" if apply else "待改"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
