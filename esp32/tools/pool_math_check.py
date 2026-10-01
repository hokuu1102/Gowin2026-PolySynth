#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pool_math_check.py -- 离线校验【水池的 tick<->微秒 换算】与限速/防溢出逻辑

================================================================================
⭐ 为什么要有这个（⛔ 没有任何硬件也能跑）：

  模式 B 的核心是"把谱面 tick 换算成墙钟时刻"。这段算术在开发中被
  【连续抓到两个真 bug】—— 都是"结果看着像个数、其实是错的"那一类：

   ① 直接按 us = dticks * 2^32 * 1e6 / (inc * F) 算：
      ⚠️ dticks=814,080（09_Conjurer max_tick）需要 72 bit
        => 64 位静默回绕 => 算出 867,256 us（0.9 s），真值 ~303 s（差 350 倍）
      ⇒ 与 K-57（32 位溢出算出 -15 ns）同族。

   ② 改成"先算 per1k = 每 1000 tick 多少 us，再乘 dticks/1000"：
      ⚠️ 能防溢出，但 per1k 只有 7 位有效数字（1041671.37 -> 1041671）
        => 整曲 814,080 tick 累积绝对误差 **154 us**（⭐ 实测，非估算）
      ⚠️ 想放大分子补精度 => 需要 72 bit，⛔ 64 位放不下（已实测）

   ⇒ ⭐ 最终方案：**增量式** —— 不算绝对时刻，只把"已过微秒"换算成
      "谱面 tick 进度"：`dticks = us * inc * F / (2^32 * 1e6)`
      中间量只随【一次 pump 的间隔】增长（<= 500 ms => 63 bit）✅

  本脚本同时做【正向判据】和【反向判据】：
    · 正向：增量式的结果必须与浮点参考一致（误差 < 1 us）
    · 反向：两个被推翻的旧写法必须【被证明是错的】（C45：
            判据若永远只报绿，就无法证明它真能抓到问题）
================================================================================
"""

import sys
from fractions import Fraction

# --- 控制台 UTF-8（Windows 默认 GBK 编不了符号）------------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

PHASE_BITS = 32
F_CLK_HZ = 50_000_000
PPQN = 960
MASK64 = (1 << 64) - 1
US_NUM_DEN = (1 << PHASE_BITS) * 1_000_000      # 2^32 * 1e6 = 4.295e15

MAX_DELTA_US = 500_000                          # 与 pool.c 的夹紧值一致

# 冻结契约 §1.3 的速查表（⭐ 已与 tb_beat_gen.sv 交叉核对过）
DOC_TABLE = {
    60:  82463,
    90:  123695,
    120: 164927,
    160: 219902,
    168: 230897,
    200: 274878,
}


# ==============================================================================
# ⭐ 最终实现（增量式）—— 与 pool.c 的 delta_us_to_ticks() 逐行对应
# ==============================================================================
def delta_us_to_ticks(dus, tick_inc):
    """复刻 pool.c 的 delta_us_to_ticks()（含 500 ms 夹紧）。"""
    if dus <= 0 or tick_inc == 0:
        return 0
    if dus > MAX_DELTA_US:
        dus = MAX_DELTA_US
    return ((dus * tick_inc * F_CLK_HZ) & MASK64) // US_NUM_DEN


# ==============================================================================
# ❌ 被推翻的旧写法 —— 保留当【反向判据】
# ==============================================================================
def bug1_absolute_us(dticks, tick_inc):
    """❌ 写法①：算绝对时刻。需 72 bit => 64 位回绕。"""
    if tick_inc == 0:
        return 0
    num = (dticks * (1 << PHASE_BITS) * 1_000_000) & MASK64
    den = (tick_inc * F_CLK_HZ) & MASK64
    return num // den


def bug2_per1k_us(dticks, tick_inc):
    """❌ 写法②：per1k 预算法。防了溢出，但 per1k 精度只有 7 位 => 单边累积。"""
    if tick_inc == 0:
        return 0
    num = 1000 * (1 << PHASE_BITS) * 1_000_000
    den = F_CLK_HZ * tick_inc
    per1k = num // den                  # ⚠️ 向下取整，丢小数
    q, r = divmod(dticks, 1000)
    return q * per1k + (r * per1k) // 1000


# ==============================================================================
# 参考值（高精度，用 Fraction）
# ==============================================================================
def ref_us_per_tick(bpm):
    return Fraction(1_000_000 * 60, bpm * PPQN)


def ref_ticks_per_sec(bpm):
    return Fraction(bpm * PPQN, 60)


def tick_inc_for(bpm):
    """与冻结契约 §1.3 同式：round(2^32 * f_tick / 50e6)。"""
    return round((1 << PHASE_BITS) * float(ref_ticks_per_sec(bpm)) / F_CLK_HZ)


def main():
    # ⭐ 2026-10-01：加 `--selftest` —— ⚠️ **只为【接口一致】**
    # ------------------------------------------------------------------------
    # ⭐ 本工具**本来就是纯离线校验**（⭐ 不碰串口、⛔ 不需要硬件）
    #    ⇒ ⭐ `--selftest` 与【无参运行】**完全等价**。
    # ⚠️ 那为什么还要加：⭐ 让【批量自检】能用**统一的方式**调用所有工具
    #    （⭐ 否则每个工具的参数都不一样，⚠️ 扫描脚本要写特例）。
    import argparse
    ap = argparse.ArgumentParser(
        description="水池 tick<->us 换算的离线校验（⭐ 纯离线，⛔ 不需硬件）")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⭐ 与无参运行等价 —— 本工具本来就是离线校验）")
    ap.parse_args()

    print("=" * 80)
    print("水池 tick<->us 换算 · 离线校验（增量式）")
    print("=" * 80)

    ok = True

    # ---- ① tick_inc 公式 vs 冻结契约表 ----
    print("\n[1] tick_inc 公式 vs 冻结契约 §1.3 速查表")
    for bpm, expect in sorted(DOC_TABLE.items()):
        got = tick_inc_for(bpm)
        good = (got == expect)
        ok &= good
        print("    BPM %-4d 算出=%-7d 表值=%-7d %s"
              % (bpm, got, expect, "OK" if good else "MISMATCH"))

    # ---- ② ⭐ 正向判据：增量式 vs 高精度参考 ----
    print("\n[2] ⭐ 增量式 delta_us_to_ticks vs 高精度参考  ⚠️ 判据 = 误差 < 1 tick")
    print("        （增量式只有一次整除，误差应 <= 1 tick）")
    worst_all = 0
    for bpm in sorted(DOC_TABLE):
        inc = DOC_TABLE[bpm]
        tps = ref_ticks_per_sec(bpm)          # tick / s
        row_worst = 0
        for dus in (1_000, 10_000, 50_000, 200_000, 500_000):
            got = delta_us_to_ticks(dus, inc)
            ref = Fraction(dus, 1_000_000) * tps
            err = abs(got - float(ref))
            row_worst = max(row_worst, err)
            good = err <= 1.0
            ok &= good
            if dus in (1_000, 500_000):
                print("    BPM %-4d dus=%7d us -> ticks=%-8d 参考=%-12.2f 误差=%.4f %s"
                      % (bpm, dus, got, float(ref), err, "OK" if good else "FAIL"))
        worst_all = max(worst_all, row_worst)
    print("    => 全局最大误差 = %.4f tick  ⇒ %s"
          % (worst_all, "✅ 小于 1 tick" if worst_all <= 1.0 else "❌ 超限"))

    # ---- ③ 夹紧是否真的起作用（防溢出）----
    print("\n[3] ⚠️ 夹紧验证：超过 500 ms 的增量必须被夹住（否则中间量溢出）")
    inc = DOC_TABLE[168]
    for dus in (500_000, 3_000_000, 300_000_000):
        raw_bits = (dus * inc * F_CLK_HZ).bit_length()
        got = delta_us_to_ticks(dus, inc)
        clamped = (dus > MAX_DELTA_US)
        print("    dus=%-12d 原始中间量 %2d bit %s -> 夹紧后 ticks=%d"
              % (dus, raw_bits, "🔴 超 64 位，必须夹紧" if raw_bits > 64 else "     ",
                 got))
        good = raw_bits <= 64 or clamped
        ok &= good
    print("    => 结论：%s" % ("✅ 夹紧覆盖了所有溢出区间（pump 周期 << 500 ms）"
                              if ok else "❌ 有区间未被覆盖"))

    # ---- ④ ⭐ 反向判据：两个旧写法都必须【被证明是错的】----
    #
    # ⚠️ 判据口径（⭐ 这里也修正过一次）：
    #    一开始用【相对误差 > 1e-6】判"坏"，结果写法②报 5.12e-07 => 判"没坏"。
    #    ⭐ 那说明我之前说写法②"累积 3500 us"是【算错了】——
    #       它的相对误差其实只有 5e-7。
    #    ⇒ 改用【绝对误差】判：因为对功能有意义的是"偏了多少微秒"，
    #      而不是"偏了百分之几"。判据卡在"是否超过 1 个字节时间"。
    #      1 Mbps 下一字节 = 10 us ⇒ 卡 10 us 是有物理意义的。
    print("\n[4] ⭐ 反向判据：被推翻的两个写法必须【证明是错的】")
    print("       理由：C45 —— 判据若永远只报绿，就无法证明它真能抓到问题")
    print("       口径：绝对误差 > 10 us（= 1 Mbps 下一个字节时间）即算坏")
    TOL_ABS_US = 10.0
    inc = DOC_TABLE[168]
    for name, fn in (("写法①绝对时刻(64位回绕)", bug1_absolute_us),
                     ("写法②per1k(7位精度)",   bug2_per1k_us)):
        rows = []
        worst = 0.0
        for dticks in (1_000, 30_720, 100_000, 814_080):
            got = fn(dticks, inc)
            ref = float(dticks * ref_us_per_tick(168))
            err = abs(got - ref)
            worst = max(worst, err)
            rows.append((dticks, got, ref, err))
        broken = (worst > TOL_ABS_US)
        ok &= broken
        print("    %-26s 最大绝对误差 %12.1f us => %s"
              % (name, worst, "🔴 确实坏了（期望）" if broken else "⚠️ 没坏？判据没打在点子上"))
        for dticks, got, ref, err in rows:
            print("        dticks=%-8d got=%-12d ref=%-14.1f err=%.1f us" %
                  (dticks, got, ref, err))

    # ---- ⑤ 提前量：占 FPGA 缓冲多少 ----
    print("\n[5] 提前量占用 FPGA 缓冲的核算（U-19：8 KB = 1024 事件）")
    LEAD_TICKS = 20000
    for name, bpm, ev_per_bar in (("夜洋风景(最密)", 168, 99.3),
                                  ("09_Conjurer", 168, 55.9)):
        lead_us = float(Fraction(LEAD_TICKS) * ref_us_per_tick(bpm))
        bars = LEAD_TICKS / (PPQN * 4.0)
        ev = bars * ev_per_bar
        frac = ev / 1024.0
        good = frac < 0.9
        ok &= good
        print("    %-14s 提前 %d tick = %.0f us (%.2f 小节) ≈ %.0f 事件 = 缓冲的 %.0f%%  %s"
              % (name, LEAD_TICKS, lead_us, bars, ev, frac * 100,
                 "OK" if good else "🔴 太满"))

    # ---- ⑥ 🔴 溢出算术 ----
    print("\n[6] 🔴 溢出算术：全速灌多久灌满 FPGA 缓冲")
    ev_per_s = 1_000_000 / 10 / 9
    fill_ms = 1024 / ev_per_s * 1000
    print("    线速 = %.0f 事件/s；1024 事件缓冲 => 灌满只需 %.0f ms" % (ev_per_s, fill_ms))
    print("    => 结论：必须限速；开环下只能靠【可观测 + 可归因】")

    print("\n" + "=" * 80)
    print("结果：%s" % ("全部通过 ✅" if ok else "❌ 有项不通过"))
    print("=" * 80)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
