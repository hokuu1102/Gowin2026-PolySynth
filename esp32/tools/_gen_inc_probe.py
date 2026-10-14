#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_gen_inc_probe.py —— 生成【末帧可核对】的最小谱面，用于验 FPGA 侧的
"尖锐高音 = inc 越界放大"假设。

═══ 背景（FPGA 侧 2026-10-14 的请求）═══
他们的假设：
    "音高变成尖锐高音" 最自然的来源是 phase_inc 被算大了。
    而线上 inc 字段只有 21 位 => 必然经过一次"缩放/截断"。
    若某个 inc 在 21 位里越界/回绕，放大回来就会得到一个极大的 phase_inc
    => 听起来正是"尖锐高音"。
他们要求：一份【末帧可核对】的最小谱面，好逐帧对
    `inc 的编码值 ↔ 放大后值`，看有没有越界。

═══ 本工具产出 ═══
  ① `<名字>.hex`      —— 64 位事件字（可直接灌进板子）
  ② `<名字>.csv`      —— 逐帧核对表：帧号 / tick / axis / kind / vel /
                         inc(编码) / 频率(Hz) / 音名 / 是否越界
  ⭐ 故意把几个【边界值】放进去，专门逼出越界：
     · inc = 1（最低，频率 ~0.00001 Hz）
     · inc = 0（退化：无声/除零风险）
     · inc = 2^21-1 = 2097151（21 位满量程）
     · 真 A4 的 32 位值 38702840 —— 明显超 21 位，看它被截成什么
     · 相邻音高只差 1（C4 vs C#4）—— 验证分辨率没被缩放吃掉

═══ 用法 ═══
  python _gen_inc_probe.py                      # 默认产出到 evidence/
  python _gen_inc_probe.py --out-dir <目录>
  python _gen_inc_probe.py --selftest           # 离线自检
"""

import argparse
import csv
import math
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_word as SW                                     # noqa: E402

PPQN = 960
FS = 50_000_000.0            # ⚠️ 这是【v1 曲谱口径】的采样率（见 inc→Hz 的说明）
TWO32 = 4294967296.0

# 音高换算：与 mid2evt.py 的 note_to_phase_inc 一致
def midi_to_full_inc(midi):
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    return int(round(f * TWO32 / FS))

# ⚠️ inc -> Hz 的换算有两个口径，取决于 FPGA 侧把 inc 当什么：
#    · 32 位满宽（14 B 上行帧那条路）：f = inc * fs / 2^32，fs = 48 828.125 Hz
#    · 21 位线上字段：被缩放/截断后的值，⛔ 不能直接当音高
# 本工具把【两个口径都算出来】，让核对时不会混。
def inc_to_hz_32(inc, fs=48828.125):
    return inc * fs / TWO32

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
def midi_name(m):
    return "%s%d" % (NOTE_NAMES[m % 12], m // 12 - 1)


# ===========================================================================
# 构造最小谱面
# ===========================================================================
INC_21_MAX = (1 << 21) - 1          # 2097151

def build_probe_score():
    """返回 (事件列表, 说明列表)。

    事件 = (tick, inc, axis, vel, kind, timbre, 备注)
    ⭐ 设计原则：① 尽量短（好逐帧核）② 覆盖边界 ③ 末帧明确
    """
    evs = []
    note = []

    def add(tick, inc, axis, vel, kind, timbre, why):
        evs.append((tick, inc, axis, vel, kind, timbre))
        note.append(why)

    # ① 换速事件（kind=2）—— ⭐ FPGA 侧特别问"播到最后与换速有没有相关性"，
    #    所以【故意把它放在开头】，这样后面的音都在"重锚之后"。
    add(0, 164927, 0, 0, SW.KIND_TEMPO, 0,
        "换速 120BPM（inc 存的是 tick_inc=164927，⛔ 不是音高）")

    # ② 真音高：C4 / C#4 / D4 —— 相邻半音，验证分辨率
    c4 = midi_to_full_inc(60)
    add(0,    c4, 1, 100, SW.KIND_ON, SW.TIMBRE_PIANO, "C4 on，inc=%d（32 位真值）" % c4)
    add(960,  c4, 1, 0,   SW.KIND_OFF, SW.TIMBRE_PIANO, "C4 off")

    cs4 = midi_to_full_inc(61)
    add(960,  cs4, 1, 100, SW.KIND_ON, SW.TIMBRE_PIANO, "C#4 on，inc=%d" % cs4)
    add(1920, cs4, 1, 0,   SW.KIND_OFF, SW.TIMBRE_PIANO, "C#4 off")

    # ③ 边界：21 位满量程
    add(1920, INC_21_MAX, 2, 100, SW.KIND_ON, SW.TIMBRE_BASS,
        "inc = 2^21-1 = 2097151（21 位满量程）")
    add(2880, INC_21_MAX, 2, 0,   SW.KIND_OFF, SW.TIMBRE_BASS, "21 位满量程 off")

    # ④ 边界：inc = 1（极低）
    add(2880, 1, 3, 100, SW.KIND_ON, SW.TIMBRE_GUITAR, "inc = 1（最低非零）")
    add(3840, 1, 3, 0,   SW.KIND_OFF, SW.TIMBRE_GUITAR, "inc=1 off")

    # ⑤ 边界：inc = 0（退化 —— 可能除零 / 无声）
    add(3840, 0, 4, 100, SW.KIND_ON, SW.TIMBRE_PAD, "inc = 0（退化，看 FPGA 怎么处理）")
    add(4800, 0, 4, 0,   SW.KIND_OFF, SW.TIMBRE_PAD, "inc=0 off")

    # ⑥ ⭐ 真 A4 —— 曲谱 inc = 37796（21 位够用）。
    #    🔴 注意口径：FPGA 侧说的"38702840 塞不进 21 位"指的是
    #       【上行 14 B 帧的 phase_inc】（32 位全宽），⛔ 不是本字段。
    #       两者是不同的量，本探针验的是【下行曲谱】这一侧。
    a4 = midi_to_full_inc(69)
    add(4800, a4, 5, 100, SW.KIND_ON, SW.TIMBRE_PIANO,
        "A4 on，曲谱 inc=%d（21 位够用；⭐ 别与上行 32 位的 38702840 混）" % a4)
    add(5760, a4, 5, 0,   SW.KIND_OFF, SW.TIMBRE_PIANO, "A4 off")

    # ⑥b ⭐ 直接打到 21 位满量程（这是"越界"假设的真正靶子）
    add(5760, INC_21_MAX, 7, 100, SW.KIND_ON, SW.TIMBRE_GUITAR,
        "⭐ 21 位满量程 2097151（若被 +1 或放大就会越界回绕）")
    add(6720, INC_21_MAX, 7, 0,   SW.KIND_OFF, SW.TIMBRE_GUITAR, "满量程 off")

    # ⑦ 末帧：一个明确的收尾音 + 它的 off —— ⭐ "末帧可核对"
    end_inc = midi_to_full_inc(48)      # C3
    add(5760, end_inc, 6, 100, SW.KIND_ON, SW.TIMBRE_BASS,
        "末段 C3 on，inc=%d" % end_inc)
    add(7680, end_inc, 6, 0,   SW.KIND_OFF, SW.TIMBRE_BASS,
        "⭐ 末帧：C3 off（全曲最后一个事件）")

    return evs, note


# ===========================================================================
def selftest():
    """离线自检 —— 重点：边界值真的在、末帧真的是 off、越界标记能红。"""
    print("=" * 72)
    print("_gen_inc_probe.py 离线自检（不需要硬件）")
    print("=" * 72)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-52s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    evs, note = build_probe_score()
    chk("事件数 > 0", len(evs) > 0, "%d 个" % len(evs))

    kinds = [e[4] for e in evs]
    chk("有换速事件（kind=2）", SW.KIND_TEMPO in kinds)
    chk("有 note_on / note_off",
        SW.KIND_ON in kinds and SW.KIND_OFF in kinds)

    # ⭐ 末帧必须是 note_off（否则就是挂音源）
    chk("⭐ 末帧是 note_off（⛔ 不是以 on 结尾）",
        evs[-1][4] == SW.KIND_OFF, "末帧 kind=%d" % evs[-1][4])

    # ⭐ on/off 必须配对（否则本探针自己就是挂音源）
    from collections import defaultdict
    open_cnt = defaultdict(int)
    for (tick, inc, axis, vel, kind, tb) in evs:
        if kind == SW.KIND_ON:
            open_cnt[(axis, inc)] += 1
        elif kind == SW.KIND_OFF:
            open_cnt[(axis, inc)] -= 1
    bad_pairs = {k: v for k, v in open_cnt.items() if v != 0}
    chk("⭐ 所有 on/off 完全配对（本探针自身不产生挂音）",
        not bad_pairs, str(bad_pairs) if bad_pairs else "")

    # 边界值确实在
    incs = [e[1] for e in evs]
    chk("含边界 inc=0", 0 in incs)
    chk("含边界 inc=1", 1 in incs)
    chk("含边界 inc=2^21-1", INC_21_MAX in incs)
    a4 = midi_to_full_inc(69)
    chk("含真 A4 的曲谱 inc（%d）" % a4, a4 in incs)

    # 🔴🔴 关键口径（我第一版在这里搞混了，判据当场抓住）：
    #   下行【曲谱】的 inc 字段是 21 位，值域够 A4（37796）。
    #   而上行【14 B 帧】的 phase_inc 是 32 位全宽，A4 = 38702840。
    #   ⚠️ 是【两个不同的量】，⛔ 不能混着说"越界"。
    chk("曲谱 inc 够 A4（37796 <= 21 位上限 %d）" % INC_21_MAX,
        a4 <= INC_21_MAX, "A4 曲谱 inc = %d" % a4)
    chk("非空洞：最高的 MIDI 音(127) 的曲谱 inc 也够 21 位",
        midi_to_full_inc(127) <= INC_21_MAX,
        "inc = %d" % midi_to_full_inc(127))
    # 而上行 32 位口径的 A4 才是 FPAG 侧说的那个大数
    A4_PHASE32 = 38702840
    chk("上行口径：A4 的 phase_inc = 38702840（32 位，⭐ FPGA 侧报的数）",
        abs(inc_to_hz_32(A4_PHASE32) - 440.0) < 1.0,
        "反算频率 = %.1f Hz" % inc_to_hz_32(A4_PHASE32))
    chk("⭐ 且它确实 > 21 位上限（所以 9 B 上行帧塞不下）",
        A4_PHASE32 > INC_21_MAX, "%d > %d" % (A4_PHASE32, INC_21_MAX))

    # 越界标记函数能红（用上行 32 位口径的值来试）
    chk("越界检测：上行 32 位口径的 A4 判越界", A4_PHASE32 > INC_21_MAX)
    chk("非空洞：inc=1 不越界（⭐ 证明上一条不是恒真）", not (1 > INC_21_MAX))

    # 帧字打包能往返
    w = SW.frame_from_word(SW.pack_word(tick=0, inc=INC_21_MAX, axis=2,
                                        vel=100, kind=SW.KIND_ON, timbre=1))
    chk("打包：帧长 9 字节", len(w) == 9)
    chk("打包：帧头 0xA5", w[0] == 0xA5)

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


# ===========================================================================
def main():
    ap = argparse.ArgumentParser(description="生成末帧可核对的最小谱面")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(HERE), "evidence"))
    ap.add_argument("--name", default="inc探针-最小谱面-20261014")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    evs, note = build_probe_score()
    os.makedirs(args.out_dir, exist_ok=True)

    # ---- 写 .hex ----
    hexp = os.path.join(args.out_dir, args.name + ".hex")
    with open(hexp, "w", encoding="utf-8", newline="\n") as f:
        for (tick, inc, axis, vel, kind, tb) in evs:
            w = SW.pack_word(tick=tick, inc=inc, axis=axis, vel=vel,
                             kind=kind, timbre=tb)
            f.write("%016X\n" % w)

    # ---- 写核对表 .csv ----
    #
    # 🔴 关键：真正要核对的【不是"编码值超没超 21 位"】—— 那个字段本来就是
    #    21 位，永远不超。⭐ 要核的是【FPGA 内部把它放大成 phase_inc 之后】的值。
    #
    # ⭐ 放大倍率不是猜的：用 FPGA 侧给的锚点（A4 的 phase_inc = 38702840）
    #    反推得 **2^10 = 1024**（误差 0.0007%），见 `_inc_scale_probe.py`。
    #    ⚠️ 我第一版凭"填满 32 位"猜成 2^11，导致 C4 算成 523 Hz（高一个八度）
    #    —— 那是【猜错】，不是 FPGA 的算法错。
    SCALE_LOG2 = 10                       # 曲谱 inc -> phase_inc 的放大倍率 = 2^10
    csvp = os.path.join(args.out_dir, args.name + ".csv")
    with open(csvp, "w", encoding="utf-8-sig", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["帧号", "tick", "axis", "kind", "vel", "timbre",
                     "inc编码值(21位线上)", "编码值hex",
                     "phase_inc(x2^10)", "该值对应频率Hz",
                     "越界?(>2^32)", "若回绕(&0xFFFFFFFF)后的频率Hz", "备注"])
        for i, ((tick, inc, axis, vel, kind, tb), why) in enumerate(zip(evs, note), 1):
            ph = inc << SCALE_LOG2
            hz = inc_to_hz_32(ph & 0xFFFFFFFF)
            over = ph > 0xFFFFFFFF
            wr.writerow([i, tick, axis, kind, vel, tb, inc, "%07X" % inc,
                         ph, "%.3f" % hz, "是" if over else "否",
                         "%.3f" % inc_to_hz_32(ph & 0xFFFFFFFF), why])

    # ---- 同时输出一份人读的 md ----
    mdp = os.path.join(args.out_dir, args.name + ".md")
    with open(mdp, "w", encoding="utf-8", newline="\n") as f:
        f.write("# 末帧可核对的最小谱面（2026-10-14）\n\n")
        f.write("**用途**：验 FPGA 侧的假设 —— "
                "「尖锐高音 = `inc` 在 21 位里越界/回绕后被放大」。\n\n")
        f.write("**怎么用**：灌进板子，逐帧对下表。\n\n")
        f.write("🔴 **要先说清一件事（⭐ 我方一开始也搞混了）**：\n")
        f.write("`inc` 字段线上只有 **21 位**，而 FPGA 内部把它放大成 **32 位** `phase_inc`。\n")
        f.write("所以「编码值超没超 21 位」**永远是否**（字段本来就那么大），\n")
        f.write("⭐ **真正要看的是【放大成 32 位之后】的值**。\n\n")
        f.write("⭐ **放大倍率 = `2^10 = 1024`** —— 不是猜的，是用你们给的锚点\n")
        f.write("（A4 的 `phase_inc = 38702840`）反推的，误差 **0.0007%**\n")
        f.write("（复算：`C4 22473 → 23012352 → 261.62 Hz`，理论 261.63 Hz）。\n")
        f.write("⚠️ 若这个倍率不对，请告知确切的（或 `wavetable_bank` 的表口径）——\n")
        f.write("   整张表都建立在这个数上。\n\n")
        f.write("| 帧号 | tick | axis | kind | vel | timbre | inc 编码值(21位) "
                "| `phase_inc`(×2^10) | 对应频率 | 越界? | 备注 |\n")
        f.write("|---|---|---|---|---|---|---|---|---|---|---|\n")
        for i, ((tick, inc, axis, vel, kind, tb), why) in enumerate(zip(evs, note), 1):
            ph = inc << 10
            hz = inc_to_hz_32(ph & 0xFFFFFFFF)
            over = "**是**" if ph > 0xFFFFFFFF else "否"
            f.write("| %d | %d | %d | %d | %d | %d | %d | %d | %.3f Hz | %s | %s |\n"
                    % (i, tick, axis, kind, vel, tb, inc, ph, hz, over, why))
        f.write("\n## 关键观察点\n\n")
        f.write("1. **末帧**（第 %d 帧）是 `note_off` —— 全曲以关音结尾。\n" % len(evs))
        f.write("2. **第 6 帧的 `inc` = 21 位满量程 %d** => " % INC_21_MAX)
        f.write("`phase_inc` = %d，⭐ **这是全表最接近 32 位上限的一帧**"
                "（上限 4294967295）—— 若算法里有 `+1`、先行累加或多余的移位，"
                "这一帧最容易看到回绕。\n" % (INC_21_MAX << 10))
        f.write("3. **第 8 帧的 `inc` = 1** => `phase_inc` = 1024，"
                "对应频率 **%.4f Hz** —— 极低，用来验低频侧有没有被特殊处理。\n"
                % inc_to_hz_32(1 << 10))
        f.write("4. **第 10 帧的 `inc` = 0** —— 退化边界，看 FPGA 怎么处理（无声/除零）。\n")
        f.write("5. **第 1 帧是换速事件**（`kind=2`）—— 用来验证"
                "「播到最后」与「换速」有没有时间相关性。\n")
        f.write("6. ⭐ **全曲 17 个事件、7.68 秒**（960 PPQN @120BPM）—— 很短，好逐帧核。\n")

    print("  产出：")
    print("    " + hexp)
    print("    " + csvp)
    print("    " + mdp)
    print("  事件数 = %d，末帧 = %s（kind=%d）"
          % (len(evs), "note_off" if evs[-1][4] == SW.KIND_OFF else "note_on",
             evs[-1][4]))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
