#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_gen_simul_probe.py —— 生成【真正同时】的多音色谱面，用于验证多音色并发。

═══ 为什么需要它 ═══
用户报告："网页上同一时间有两个音色，但实际听不到同时发出，而是一个音阶播完才响另一个"。

⭐ 查证结果：**`demo_scale.hex` 本身就是顺序播放的** ——
   axis 0 (BASS)   : tick      0 .. 7200
   axis 2 (PIANO)  : tick   3840 .. 19200
   axis 1 (GUITAR) : tick   8160 .. 100320
   三条轨时间几乎不重叠 => "一个播完才响另一个"是【谱面如此】，⛔ 不是通路缺陷。

⚠️ 所以要看多音色并发，必须用一份【三条轨真正重叠】的谱面。
   本工具就生成它。

═══ 谱面设计 ═══
  · 三条轨【完全重叠】：都在 tick 0 起音，各响 4 拍（3840 tick = 2 秒）
  · 三轨用不同音色（BASS / GUITAR / PIANO）—— 对应 timbre 0/1/2
  · 分在三个 axis（0/1/2）—— 但注意：⭐ axis 只决定音高查表，
    音色由 timbre 字段决定（FPGA 侧 2026-10-14 答复 §六 已确认两者正交）
  · 音高故意错开（低/中/高），这样"是否真的同时响"一耳朵能听出来

═══ 判据（怎么算验过）═══
  ① 三个音的 note_on 都在 tick 0
  ② 三个音的 note_off 都在 tick 3840
  ③ 三条轨的 tick 区间完全重叠
  ④ 三个音的 timbre 互不相同
  监听：应能同时听到低/中/高三个音（而不是先后响）

用法：
    python _gen_simul_probe.py
    python _gen_simul_probe.py --selftest
"""

import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_word as SW                                     # noqa: E402

PPQN = 960
BEAT = PPQN                    # 1 拍 = 960 tick
FS = 50_000_000.0
TWO32 = 4294967296.0


def midi_inc(midi):
    """我方曲谱口径（与 mid2evt.py 的 note_to_phase_inc 一致）。"""
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    return int(round(f * TWO32 / FS))


def build_score():
    """三条轨完全重叠的谱面。返回 (事件列表, 说明列表)。

    事件 = (tick, inc, axis, vel, kind, timbre, 备注)
    """
    evs, note = [], []

    def add(tick, inc, axis, vel, kind, timbre, why):
        evs.append((tick, inc, axis, vel, kind, timbre))
        note.append(why)

    # ⭐ 换速事件（kind=2）放最前 —— 让 tick_inc 是本首该有的值
    add(0, 164927, 0, 0, SW.KIND_TEMPO, 0,
        "换速 120BPM（inc = tick_inc，⛔ 不是音高）")

    # ⭐ 三个音【同 tick 起、同 tick 止】=> 真正同时
    # 音高：C3(48) / C4(60) / C5(72)，两个八度差，一耳朵能分辨
    trio = [
        (48, 0, SW.TIMBRE_BASS,   "BASS  C3"),
        (60, 1, SW.TIMBRE_GUITAR, "GUITAR C4"),
        (72, 2, SW.TIMBRE_PIANO,  "PIANO  C5"),
    ]
    DUR = 4 * BEAT                       # 响 4 拍 = 2 秒
    for (midi, axis, tb, label) in trio:
        inc = midi_inc(midi)
        add(0,   inc, axis, 100, SW.KIND_ON,  tb,
            "%s on @tick0（音色 %s，inc=%d）" % (label, SW.TIMBRE_NAMES[tb], inc))
    for (midi, axis, tb, label) in trio:
        inc = midi_inc(midi)
        add(DUR, inc, axis, 0, SW.KIND_OFF, tb,
            "%s off @tick%d" % (label, DUR))

    # ⭐ 再来一轮：换个和弦（E3/G3/C4），验证"第二轮也能同时"
    trio2 = [
        (52, 0, SW.TIMBRE_BASS,   "BASS  E3"),
        (55, 1, SW.TIMBRE_GUITAR, "GUITAR G3"),
        (60, 2, SW.TIMBRE_PIANO,  "PIANO  C4"),
    ]
    t2 = DUR + BEAT                      # 空一拍再起
    for (midi, axis, tb, label) in trio2:
        inc = midi_inc(midi)
        add(t2, inc, axis, 100, SW.KIND_ON, tb,
            "第2轮 %s on @tick%d" % (label, t2))
    for (midi, axis, tb, label) in trio2:
        inc = midi_inc(midi)
        add(t2 + DUR, inc, axis, 0, SW.KIND_OFF, tb,
            "第2轮 %s off @tick%d" % (label, t2 + DUR))

    return evs, note


def selftest():
    print("=" * 74)
    print("_gen_simul_probe.py 离线自检（不需要硬件）")
    print("=" * 74)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-54s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    evs, note = build_score()
    chk("事件数 > 0", len(evs) > 0, "%d 个" % len(evs))

    # ⭐ 核心判据：至少有一组"三个 on 在同一 tick"
    from collections import defaultdict
    on_by_tick = defaultdict(list)
    for (tick, inc, axis, vel, kind, tb) in evs:
        if kind == SW.KIND_ON:
            on_by_tick[tick].append((axis, tb))
    multi = {t: v for t, v in on_by_tick.items() if len(v) >= 3}
    chk("⭐ 存在 tick 上【同时】有 3 个 note_on", len(multi) >= 1,
        "有 %d 个这样的 tick" % len(multi))

    # ⭐ 三个音必须是【不同音色】
    if multi:
        t0 = min(multi)
        tbs = set(tb for (ax, tb) in multi[t0])
        chk("⭐ 同时起音的 3 个音符用【3 种不同音色】", len(tbs) == 3,
            "timbre = %s" % sorted(tbs))
        axes = set(ax for (ax, tb) in multi[t0])
        chk("⭐ 同时起音的 3 个音符在【3 个不同 axis】", len(axes) == 3,
            "axis = %s" % sorted(axes))

    # ⭐ 三条轨的 tick 区间必须【重叠】（这是本探针的全部意义）
    per_axis = defaultdict(list)
    for (tick, inc, axis, vel, kind, tb) in evs:
        if kind in (SW.KIND_ON, SW.KIND_OFF):
            per_axis[axis].append(tick)
    ranges = {ax: (min(ts), max(ts)) for ax, ts in per_axis.items() if ts}
    chk("有 3 个 axis 参与", len(ranges) == 3, str(sorted(ranges)))
    if len(ranges) >= 3:
        lo = max(r[0] for r in ranges.values())      # 最晚的开始
        hi = min(r[1] for r in ranges.values())      # 最早的结束
        chk("⭐ 三条轨的 tick 区间【真的重叠】（lo < hi）", lo < hi,
            "重叠区 [%d, %d]" % (lo, hi))

    # on/off 配对（探针自身不能挂音）
    bal = defaultdict(int)
    for (tick, inc, axis, vel, kind, tb) in evs:
        if kind == SW.KIND_ON:
            bal[(axis, inc)] += 1
        elif kind == SW.KIND_OFF:
            bal[(axis, inc)] -= 1
    unclosed = {k: v for k, v in bal.items() if v != 0}
    chk("⭐ 所有 on/off 完全配对（探针自身不挂音）", not unclosed,
        str(unclosed) if unclosed else "")

    # 末帧是 off
    chk("末帧是 note_off", evs[-1][4] == SW.KIND_OFF,
        "末帧 kind=%d" % evs[-1][4])

    # 非空洞：故意去掉一个 off，配对判据必须红
    evs2 = [e for e in evs if not (e[4] == SW.KIND_OFF and e[2] == 2 and e[0] == 4 * 960)]
    bal2 = defaultdict(int)
    for (tick, inc, axis, vel, kind, tb) in evs2:
        if kind == SW.KIND_ON:
            bal2[(axis, inc)] += 1
        elif kind == SW.KIND_OFF:
            bal2[(axis, inc)] -= 1
    chk("非空洞：去掉一个 off => 配对判据必须红",
        any(v != 0 for v in bal2.values()))

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser(description="生成真正同时的多音色谱面")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(HERE), "evidence"))
    ap.add_argument("--name", default="多音色同时探针-20261014")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    evs, note = build_score()
    os.makedirs(args.out_dir, exist_ok=True)

    hexp = os.path.join(args.out_dir, args.name + ".hex")
    with open(hexp, "w", encoding="utf-8", newline="\n") as f:
        for (tick, inc, axis, vel, kind, tb) in evs:
            w = SW.pack_word(tick=tick, inc=inc, axis=axis, vel=vel,
                             kind=kind, timbre=tb)
            f.write("%016X\n" % w)

    mdp = os.path.join(args.out_dir, args.name + ".md")
    with open(mdp, "w", encoding="utf-8", newline="\n") as f:
        f.write("# 多音色【同时】探针（2026-10-14）\n\n")
        f.write("**用途**：验证「多个音色能否真的同时响」。\n\n")
        f.write("⭐ **为什么需要它**：用户报「同一时间有两个音色，但听不到同时」——\n")
        f.write("查证发现是 `demo_scale.hex` **本身**三条轨时间不重叠：\n\n")
        f.write("```\n")
        f.write("axis 0 (BASS)   : tick      0 .. 7200\n")
        f.write("axis 2 (PIANO)  : tick   3840 .. 19200\n")
        f.write("axis 1 (GUITAR) : tick   8160 .. 100320\n")
        f.write("```\n\n")
        f.write("⇒ 「一个播完才响另一个」是**谱面如此**，⛔ 不是通路缺陷。\n\n")
        f.write("**本探针**：三条轨【完全重叠】——都在 tick 0 起音、tick 3840 止。\n\n")
        f.write("| 帧 | tick | axis | 音色 | 音高 | inc |\n")
        f.write("|---|---|---|---|---|---|\n")
        for (tick, inc, axis, vel, kind, tb) in evs:
            pass
        for i, ((tick, inc, axis, vel, kind, tb), why) in enumerate(zip(evs, note), 1):
            f.write("| %d | %d | %d | %s | — | %d | %s |\n"
                    % (i, tick, axis, SW.TIMBRE_NAMES.get(tb, "?"), inc, why))
        f.write("\n**判据**：应能【同时】听到低(C3)/中(C4)/高(C5)三个音，\n")
        f.write("而不是先后响。\n")

    print("  产出：")
    print("    " + hexp)
    print("    " + mdp)
    print("  事件数 = %d" % len(evs))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
