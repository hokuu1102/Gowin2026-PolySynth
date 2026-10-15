#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成【鼓机单声部】的最小复现事件流（3 个对照用例）。

用途
    给 FPGA 线一个"跑一遍就能听出来"的最小证据：
    证明下行灌谱的鼓（axis 15 / SRC_KDRUM）**同时只能响一件**。

为什么需要它
    标准 funk/rock 鼓型（踩镲连续八分 + 底鼓军鼓穿插）要求【同时发声】。
    若鼓机实际是单声部，那种鼓型在这块板子上根本打不出来。

三个用例（中间留静音，方便逐段听）
    A  同一 tick 敲两件      tick 0     : kick ON + hihat ON      （480 后都 off）
    B  前一件还没释放        tick 1920  : kick ON（长，3840 才 off）
       后一件进来            tick 2400  : hihat ON               （2880 off）
    C  对照：不重叠          tick 5760  : kick ON                （6240 off）
                             tick 6240  : hihat ON               （6720 off）

判读
    · 若鼓是【多声部】：A 能听到 kick + hihat 两件；B 的 kick 长音不会被 2400 的
      hihat 打断；C 正常。
    · 若鼓是【单声部】（我方读 RTL 的结论）：
        A 只响一件（第二件被 same_hit 顶掉）
        B 的 kick 在 2400 被 hihat 顶掉（长音变短）
        C 正常（两件都响）—— 这条是【对照】，说明不是"鼓根本不响"

事件字布局（64 bit，与 score_word.py / mid2evt.py 一致）
    bit 63..44 tick(20) · 43..23 inc(21) · 22..19 axis(4) · 18..11 vel(8)
    · 10..9 kind(2) · 8..7 timbre(2) · 6..0 保留(0)
    ⚠️ 鼓的 inc = phase_inc >> 10（FPGA 侧口径）：
       kick 5243 · snare 41943 · hihat 167772 · tom 17476
    ⚠️ 鼓的 vel 用鼓机的生效值：kick 230 · snare 235 · hihat 175 · tom 220

用法
    python gen_drum_probe.py            # 写到同目录的 .hex
    python gen_drum_probe.py --out X.hex
"""

import argparse
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# FPGA 侧口径（见 esp32/tools/drum_map.py）
DRUM_INC = {"kick": 5243, "snare": 41943, "hihat": 167772, "tom": 17476}
DRUM_VEL = {"kick": 230, "snare": 235, "hihat": 175, "tom": 220}
DRUM_AXIS = 15
KIND_ON, KIND_OFF = 0, 1


def word(tick, name, kind):
    return ((tick << 44)
            | (DRUM_INC[name] << 23)
            | (DRUM_AXIS << 19)
            | (DRUM_VEL[name] << 11)
            | (kind << 9)
            | (0 << 7))          # 鼓的 timbre 字段无意义，填 0


def build():
    """返回 [(tick, order, name, kind, 说明), ...]；order 保证同 tick 先 off 后 on。"""
    ev = []
    # 用例 A：同一 tick 敲两件
    ev.append((0,    1, "kick",  KIND_ON,  "A 同 tick：kick 起"))
    ev.append((0,    1, "hihat", KIND_ON,  "A 同 tick：hihat 起（同 tick 第二件）"))
    ev.append((480,  0, "kick",  KIND_OFF, "A：kick 收"))
    ev.append((480,  0, "hihat", KIND_OFF, "A：hihat 收"))
    # 用例 B：前一件还没释放，后一件进来
    ev.append((1920, 1, "kick",  KIND_ON,  "B：kick 起（长音，3840 才收）"))
    ev.append((2400, 1, "hihat", KIND_ON,  "B：hihat 在 kick 还响着的时候起"))
    ev.append((2880, 0, "hihat", KIND_OFF, "B：hihat 收"))
    ev.append((3840, 0, "kick",  KIND_OFF, "B：kick 收"))
    # 用例 C：对照，不重叠
    ev.append((5760, 1, "kick",  KIND_ON,  "C 对照：kick 起"))
    ev.append((6240, 0, "kick",  KIND_OFF, "C 对照：kick 收（此时 hihat 才起）"))
    ev.append((6240, 1, "hihat", KIND_ON,  "C 对照：hihat 起"))
    ev.append((6720, 0, "hihat", KIND_OFF, "C 对照：hihat 收"))
    ev.sort(key=lambda e: (e[0], e[1]))
    return ev


def main(argv=None):
    ap = argparse.ArgumentParser(description="生成鼓机单声部最小复现 hex")
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "鼓机单声部-最小复现-20261015.hex")

    ev = build()
    with open(out, "w", encoding="ascii", newline="\n") as f:
        for tick, _o, name, kind, _why in ev:
            f.write("%016x\n" % word(tick, name, kind))

    print("=" * 78)
    print("鼓机单声部 · 最小复现（3 个用例）")
    print("=" * 78)
    for tick, _o, name, kind, why in ev:
        print("  tick %-6d %-6s %-4s   %s"
              % (tick, name, "ON" if kind == KIND_ON else "OFF", why))
    print()
    print("  已写出：%s（%d 个事件字）" % (out, len(ev)))
    print("  灌法：上位机读这个 .hex（或按同样布局自己发包），起播后逐段听 A / B / C。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
