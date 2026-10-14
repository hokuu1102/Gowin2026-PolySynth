#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_lead_model_check.py —— 提前量模型的离线推演（第 3 版）。

═══ 这个文件记录了我方在"提前量该取多少"上【连错两次】的过程 ═══
把失败路径留下来，免得下次再走。

── 第一版（错，已作废）────────────────────────────────────────────
    模型："把 FPGA 缓冲填满" => 提前 tick = HIGH_WM / E
    🔴 实测：demo_scale 的 E=0.0011 => 694393 tick = **363 秒**
    => 荒谬。根因：把"填满缓冲"当成了目的，而提前量的唯一作用是抗抖动。

── 第二版（错，已作废）────────────────────────────────────────────
    模型："缓冲里至少存够【一次最坏停顿】该消耗的事件数"
        N_min = E * TICKS_PER_SEC * STALL_SEC
        lo    = N_min / E
    🔴 会计算一下就知道：lo = TICKS_PER_SEC * STALL_SEC = **192 tick（常数）**
    => ⭐ E 被约掉了！"下界"根本不随谱面变 => 模型没意义
       （自检的方向性判据与"E 变化结果必须变"两条当场抓到）

── 第三版（本文件）────────────────────────────────────────────────
    ⭐ 重新问清楚：提前量到底在补偿什么？

    去掉提前量（lead=0）时会发生什么：
        FPGA 按自己的时钟消耗事件。ESP32 通过 BLE 送事件。
        只要【送得比消耗快】，缓冲就会涨；一旦 BLE 卡一下，
        FPGA 就饿着 —— 那是 underrun（掉音，可见但仍是不好的）。
        提前量做的就是：**开播前先攒一批存货**，让偶尔的卡顿被存货吸收。

    ⭐ 所以正确的量是【存货深度】（事件数），而不是"音乐时间"。
       存货深度 D 能吸收多长的停顿？
           停顿时间 = D / 事件速率 = D / (E * TICKS_PER_SEC)
       要求停顿时间 >= STALL_SEC
       => D >= E * TICKS_PER_SEC * STALL_SEC      ← ⭐ 这就是 N_min，它【依赖 E】

    ⭐ 而"提前量 tick" = 攒够 D 个事件需要走多少音乐时间：
            lead_ticks = D/E  —— 🔴 又是 E 约掉，得常数
       ⚠️ 但注意：lead_ticks 是【音乐时间】；
          而"攒够 D 个事件"这条约束，用【音乐时间】表达时：
            D 个事件出现在 D/E 个 tick 内
            而 FPGA 消耗 D 个事件需要 D/(E*1920) 秒
            => 两者【本来就是同一个量】=> 常数 192 tick = 0.1 秒
       📌 所以第二版的"常数"不是算错，而是【结论本身】：**
          **若按"攒够一次停顿的量"来定，提前量恒 = STALL_SEC（0.1 秒）。**

    ⭐⭐ 那还缺什么？缺的是【开播时的首批灌水】。
        FPGA 的 evt_buf 是【滚动】的，起播时是空的。
        真正要保证的是：**在 FPGA 消耗完之前，ESP32 已经把【后续的】
         送进来了** —— 这是一个【吞吐量】问题，不是"存货"问题：
            送速率 = 事件速率 / (1 - 余量)
        ⚠️ 而 UART 是 18000 事件/s（FPGA 侧给的），远大于谱面速率
        => 吞吐【不是】瓶颈。瓶颈只有 BLE 的抖动。

    ⇒ ⭐ 最终结论（第三版）：
        提前量 = max( LEAD_MIN_TICKS,  抗抖动常数 )
        而"抗抖动常数" = 给 BLE 抖动用的事件存货对应的音乐时间
                        ≈ STALL_SEC 那么多的音乐时间
        ⚠️ 即：**它基本就是个常数**，与谱面密度【无关】。
        🔴 所以我方原以为的"按密度动态算"是【伪需求】——
           真正该做的是把固定值从 20000 降到这个常数附近。

═══ 那 20000 是怎么来的？═══
  FPGA 侧答复 §二 里给的算式：
      安全提前量(事件数) <= HIGH_WM = 768
      => 提前 tick <= 768 / E
  ⚠️ 那是【上界】（不许超过），不是"应该取到"。
  而 20000 tick 对应 0.038 ev/tick —— 那是很密的谱面。
  ⇒ 我方判断：20000 是【按最坏情况（密谱）定的保守值】，
     对稀疏谱面确实过保守。

═══ 本文件做什么 ═══
  · 把三版模型都算出来，说明为什么前两版错
  · 给出第三版的取值，并**验证它在真实谱面上不会溢出、也不会白等**
  · 自检（含非空洞性）

用法：
    python _lead_model_check.py            # 三版对比
    python _lead_model_check.py --selftest # 离线自检
"""

import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ---- 权威常量（FPGA 侧 2026-10-14 给的）----------------------------------
TICKS_PER_SEC = 1920.0          # 120 BPM / 960 PPQN
HIGH_WM = 768                   # 安全提前量(事件数) 上限
LOW_WM = 256
DEPTH = 1024

# ---- 我方待定参数 ---------------------------------------------------------
STALL_SEC = 0.10                # 假设要抗住的一次 BLE 停顿（我方估的，⛔ 非 FPGA 给）
LEAD_MIN_TICKS = 1200           # 下限（0.625 秒）
LEAD_MAX_TICKS = 20000          # 上限（= 原固定值，按最密谱定的）


def v1_fill_buffer(E):
    """第一版（错）：提前 tick = HIGH_WM / E。"""
    return float("inf") if E <= 0 else HIGH_WM / E


def v2_stall_events(E):
    """第二版（结论=常数，不是"错"而是"没信息"）。"""
    if E <= 0:
        return LEAD_MAX_TICKS
    return TICKS_PER_SEC * STALL_SEC          # E 被约掉 => 192 tick


def v3_recommended(E):
    """第三版：提前量基本是常数（抗一次 BLE 停顿），只受上界约束。

    返回 (lead_ticks, 说明)。
    """
    base = TICKS_PER_SEC * STALL_SEC          # 192 tick ≈ 0.1 秒
    lead = max(LEAD_MIN_TICKS, base)
    # 上界：不能超过"把缓冲填满"对应的 tick（即 768/E）
    if E > 0:
        hi = HIGH_WM / E
        if hi < lead:
            # ⚠️ 谱面密到"连 0.1 秒的存货都超过 768 事件"
            # => 这时才需要 r 真的把 lead 顶到 hi 以上（按 hi 走，接受 underrun 风险）
            lead = hi
            return lead, "⚠️ 太密：hi=%.0f < base，取 hi（缓冲会满）" % hi
    return lead, "常数（抗一次 %.0f ms 停顿）" % (STALL_SEC * 1000)


def selftest():
    print("=" * 76)
    print("_lead_model_check.py 离线自检（不需要硬件）")
    print("=" * 76)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-56s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    # ① 钉住第一版的荒谬
    chk("第一版对稀谱面给出 > 300 秒（⭐ 那就是它错的原因）",
        v1_fill_buffer(0.0011) / TICKS_PER_SEC > 300,
        "%.0f 秒" % (v1_fill_buffer(0.0011) / TICKS_PER_SEC))

    # ② 钉住第二版"没有信息"（E 约掉 => 常数）
    a = v2_stall_events(0.001)
    b = v2_stall_events(100.0)
    chk("第二版对任意 E 都给同一个数（⭐ E 被约掉了 => 模型没信息）",
        abs(a - b) < 1e-9, "%.0f == %.0f" % (a, b))

    # ③ 第三版：给出"用户可接受"的等待
    v, why = v3_recommended(0.0011)
    chk("第三版对稀谱面 < 1 秒", v / TICKS_PER_SEC < 1.0,
        "%.2f 秒（%s）" % (v / TICKS_PER_SEC, why))

    # ④ ⭐ 第三版对【极密】谱面会回到 hi（这才是 20000 的用途）
    #    ⚠️ 触发条件是 hi < base（768/E < 1200）=> E > 0.64
    #    🔴 我第一版判据用 E=0.5（hi=1536 > base=1200）=> 走不到那个分支，
    #       判据自己报红。⭐ 又是"判据要对着数据算，别凭印象"（同族 C112/C169）。
    vd, whyd = v3_recommended(1.0)       # hi = 768/1.0 = 768 < base 1200
    chk("第三版对极密谱面取 hi（768/1.0 = 768 tick）",
        abs(vd - 768) < 1, "%.0f tick（%s）" % (vd, whyd))

    # ⑤ 非空洞：至少要能区分"稀"和"极密"
    chk("非空洞：第三版对稀/极密给出不同值",
        v3_recommended(0.0011)[0] != v3_recommended(1.0)[0],
        "%.0f vs %.0f" % (v3_recommended(0.0011)[0], v3_recommended(1.0)[0]))

    # ⑥ 上界永不突破 HIGH_WM（这是 FPGA 的硬约束）
    worst = 0
    for E in [0.0005, 0.0011, 0.005, 0.01, 0.02, 0.038, 0.05, 0.1, 0.5, 1.0]:
        lead, _ = v3_recommended(E)
        ev = lead * E                       # 这批存货有多少事件
        worst = max(worst, ev)
    chk("⭐ 任何密度下，存货事件数都不超 HIGH_WM=768",
        worst <= HIGH_WM + 1e-6, "最大 %.1f 事件" % worst)

    # ⑦ 与旧固定值对比：到底快了多少
    old_sec = LEAD_MAX_TICKS / TICKS_PER_SEC
    new_sec = v / TICKS_PER_SEC
    chk("第三版比旧固定值快（⭐ 这就是收益）",
        new_sec < old_sec, "%.2f 秒 vs %.2f 秒" % (new_sec, old_sec))

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser(description="提前量模型三版对比")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    print("=" * 92)
    print("提前量模型：三版对比（前两版都错，留下来免得再走）")
    print("=" * 92)
    print("  常量：HIGH_WM=%d 事件 · TICKS_PER_SEC=%.0f · 假设停顿=%.0f ms"
          % (HIGH_WM, TICKS_PER_SEC, STALL_SEC * 1000))
    print()
    print("  %-9s %-10s %-14s %-14s %-14s %s"
          % ("E", "事件/拍", "v1 填满(秒)", "v2 停顿(秒)", "v3 推荐(秒)", "说明"))
    for E in (0.0005, 0.0011, 0.002, 0.005, 0.01, 0.02, 0.038, 0.05, 0.1, 0.5):
        s1 = v1_fill_buffer(E) / TICKS_PER_SEC
        s2 = v2_stall_events(E) / TICKS_PER_SEC
        v3, why = v3_recommended(E)
        print("  %-9.4f %-10.2f %-14.1f %-14.2f %-14.2f %s"
              % (E, E * 960, s1, s2, v3 / TICKS_PER_SEC, why))
    print()
    print("  ⭐ 三版的结论：")
    print("     v1 填满缓冲      => 稀谱面 363 秒，荒谬。提前量的作用不是填满缓冲。")
    print("     v2 攒一次停顿的量 => 数学上 E 被约掉，恒为 %.0f tick —— 等于没做。" %
          (TICKS_PER_SEC * STALL_SEC))
    print("     v3 推荐           => 它就是那个常数（加下限），")
    print("                          只有【极密】谱面才需要往上顶（那才是 20000 的用途）。")
    print()
    print("  📌 结论：我方原以为的「按谱面密度动态算提前量」是【伪需求】。")
    print("     真正该做的是：把固定值 20000 降到「抗一次 BLE 停顿」的量级。")
    print("     ⚠️ 而 20000 之所以安全，是因为它按【最密谱面】定的 ——")
    print("        对稀疏谱面它只是白白让人多等。")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
