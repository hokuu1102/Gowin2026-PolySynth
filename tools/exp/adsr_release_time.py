"""核对：为什么观察到的 env 只有 1338，而不是 peak 51200？

已知参数（top.v / adsr.v 默认）：
  ATTACK_STEP  = 669      (每 sample_tick 加)
  DECAY_STEP   = 4
  SUSTAIN_Q8   = 64       (sustain = peak * 64/256 = peak/4)
  RELEASE_STEP = 2
  DEFAULT_VEL  = 200  => peak_level = 200 << 8 = 51200
                          sustain_level = 51200/4 = 12800
  sample_tick  = 1024 clk @50MHz = 20.48 us
"""

ATTACK, DECAY, REL = 669, 4, 2
VEL = 200
PEAK = VEL << 8
SUS = PEAK * 64 // 256
TICK_MS = 20.48 / 1000.0

print(__doc__)
print("peak_level    = %d" % PEAK)
print("sustain_level = %d" % SUS)
print()
print("=== 各阶段耗时 ===")
print("  attack  0 -> peak      : %6d tick = %8.1f ms" % (PEAK // ATTACK, PEAK / ATTACK * TICK_MS))
print("  decay   peak -> sus    : %6d tick = %8.1f ms" % ((PEAK - SUS) // DECAY, (PEAK - SUS) / DECAY * TICK_MS))
print("  release sus  -> 0      : %6d tick = %8.1f ms" % (SUS // REL, SUS / REL * TICK_MS))
print("  release peak -> 0      : %6d tick = %8.1f ms" % (PEAK // REL, PEAK / REL * TICK_MS))
print()
print("=== 观察到的 env=1338 是什么？ ===")
print("  1338 接近 sustain_level(%d) 的 1/10" % SUS)
print("  ⭐ 说明这个 voice 在 release 已经走了一段时间")
print("  ⭐ 而从 1338 归零需要 %d tick = %.1f 秒" % (1338 // 2, 1338 / 2 * TICK_MS))
print()
print("  🔴 而我的静默只有 600 tick = %.1f 秒  => 不够！" % (600 * TICK_MS))
print()
print("=== 结论 ===")
print("  ⭐ release 【正常】，只是【很慢】")
print("  🔴 '松开后声音不停' 的真相 = release 需要 %.0f ms ~ %.1f 秒" % (SUS / REL * TICK_MS, PEAK / REL * TICK_MS))
print("  => ⭐ 这【不是 bug】，而是 RELEASE_STEP=2 太小 + 从高电平起算")
print()
print("  ⚠️ 但要区分两种情况：")
print("     A. 从 sustain(12800) 释放 : %.0f ms  <- 正常听感" % (SUS / REL * TICK_MS))
print("     B. 从 peak(51200)   释放 : %.0f ms  <- 太长了！" % (PEAK / REL * TICK_MS))
print()
print("  ⭐ 用户听到的'回音'很可能是 A/B 之间，取决于松手时机")
