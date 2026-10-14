#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_inc_scale_probe.py —— 用【权威锚点】反推曲谱 inc -> FPGA phase_inc 的放大倍率。

═══ 为什么要单独算 ═══
我方做核对表时一开始【猜】倍率是"把 21 位填满 32 位"（<<11，即 x2048），
结果 C4 算出来 523 Hz（应为 261.6）—— 正好高一个八度。
=> 猜错了。

⭐ 正确做法：用 FPGA 侧给的【权威锚点】反推。
   FPGA 侧 2026-10-14 明确给出：A4 的 phase_inc = 38702840。
   而我方发出的 A4 曲谱 inc = 37796。
   => 倍率 = 38702840 / 37796。

用法：
    python _inc_scale_probe.py            # 打印反推结果
    python _inc_scale_probe.py --selftest # 离线自检
"""
import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_word as SW                                     # noqa: E402

# ---- 权威数据 -------------------------------------------------------------
A4_MIDI = 69
# FPGA 侧 rtl/w3c/drum_gen.v 与答复里给的 A4 phase_inc
A4_PHASE_INC_FPGA = 38702840
# FPGA 内部合成时钟（drum_gen 换算常数：fs = 50 MHz / 1024）
FS_FPGA = 48828.125
TWO32 = float(1 << 32)


def curve_inc_for_midi(midi):
    """我方【曲谱】口径的 inc —— 与 mid2evt.py 的 note_to_phase_inc 一致。"""
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    return int(round(f * TWO32 / 50_000_000.0))


def phase_inc_to_hz(inc, fs=FS_FPGA):
    return inc * fs / TWO32


def derive_scale():
    """用 A4 锚点反推倍率。返回 (倍率, 是否接近 2 的幂, 最近的 2 的幂, 相对误差)。"""
    curve = curve_inc_for_midi(A4_MIDI)
    r = A4_PHASE_INC_FPGA / curve
    # 找最近的 2 的幂
    import math
    lg = math.log2(r)
    nearest = round(lg)
    pow2 = 2 ** nearest
    err = abs(r / pow2 - 1.0)
    return r, (err < 0.01), nearest, err


def selftest():
    print("=" * 72)
    print("_inc_scale_probe.py 离线自检（不需要硬件）")
    print("=" * 72)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-54s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    r, is_pow2, lg, err = derive_scale()
    chk("反推倍率 > 1（放大而非缩小）", r > 1, "倍率 = %.4f" % r)
    chk("倍率接近 2 的整数次幂（误差 < 1%）", is_pow2,
        "2^%d = %d，相对误差 %.4f%%" % (lg, 2 ** lg, err * 100))
    chk("该幂次落在合理区间 8..12", 8 <= lg <= 12, "2^%d" % lg)

    # ⭐ 用反推出的倍率验证 A4 频率对得上
    curve_a4 = curve_inc_for_midi(A4_MIDI)
    scaled = curve_a4 * (2 ** lg)
    hz = phase_inc_to_hz(scaled)
    chk("用该倍率放大 A4 => 频率 ≈ 440 Hz",
        abs(hz - 440.0) < 5.0, "%.2f Hz" % hz)

    # ⭐ 用该倍率验证 C4（应 ≈ 261.6 Hz）
    c4 = curve_inc_for_midi(60)
    hz4 = phase_inc_to_hz(c4 * (2 ** lg))
    chk("用该倍率放大 C4 => 频率 ≈ 261.6 Hz",
        abs(hz4 - 261.63) < 3.0, "%.2f Hz" % hz4)

    # 非空洞：错的倍率必须给错的频率
    wrong = phase_inc_to_hz(c4 * (2 ** (lg + 1)))
    chk("非空洞：倍率多一倍 => 频率也高一倍（⭐ 证明上面不是恒真）",
        abs(wrong - 2 * hz4) < 1.0, "%.2f vs %.2f" % (wrong, 2 * hz4))

    # 曲谱 inc 的位宽够不够
    worst = curve_inc_for_midi(127)
    chk("最高的 MIDI 音(127) 的曲谱 inc 仍在 21 位内",
        worst <= SW.MASK_INC, "inc = %d, 上限 %d" % (worst, SW.MASK_INC))

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser(description="反推 inc 放大倍率")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    r, is_pow2, lg, err = derive_scale()
    print("=" * 72)
    print("曲谱 inc -> FPGA phase_inc 的放大倍率（由权威锚点反推）")
    print("=" * 72)
    print("  锚点（FPGA 侧 2026-10-14 给出）：A4 的 phase_inc = %d"
          % A4_PHASE_INC_FPGA)
    print("  我方曲谱口径：A4 的 inc = %d" % curve_inc_for_midi(A4_MIDI))
    print("  倍率 = %.4f" % r)
    print("  最近的 2 的幂 = 2^%d = %d（相对误差 %.4f%%）"
          % (lg, 2 ** lg, err * 100))
    print()
    print("  用该倍率验算几个音：")
    for m in (48, 60, 69, 72):
        c = curve_inc_for_midi(m)
        ph = c * (2 ** lg)
        print("    MIDI %3d  曲谱 inc %8d  ->  phase_inc %10d  ->  %8.2f Hz"
              % (m, c, ph, phase_inc_to_hz(ph)))
    print()
    print("  ⚠️ 注意：倍率是我方【由锚点反推】的，不是 FPGA 侧直接告知的。")
    print("     若 FPGA 侧能给出确切倍率（或 wavetable_bank 的表口径），请告知。")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
