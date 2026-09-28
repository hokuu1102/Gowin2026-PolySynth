"""核对 ADSR 的时间常数，判断"等待时间是否足够"。"""
PEAK = 200 << 8          # DEFAULT_VEL=200 -> peak_level
TICK_US = 20.48          # 1 sample_tick = 1024 clk @50MHz


def ms(ticks):
    return ticks * TICK_US / 1000.0


print("DEFAULT_VEL=200 => peak_level = %d" % PEAK)
print("RELEASE_STEP = 2, DECAY_STEP = 4, ATTACK_STEP = 669")
print()
print("=== release 时间常数 ===")
print("  from peak    (%5d): %6d tick = %8.1f ms" % (PEAK, PEAK // 2, ms(PEAK // 2)))
sus = PEAK * 64 // 256
print("  from sustain (%5d): %6d tick = %8.1f ms" % (sus, sus // 2, ms(sus // 2)))
print()
print("=== decay 时间常数 ===")
print("  peak -> sustain    : %6d tick = %8.1f ms" % ((PEAK - sus) // 4, ms((PEAK - sus) // 4)))
print()
print("=== attack 时间常数 ===")
print("  0 -> peak          : %6d tick = %8.1f ms" % (PEAK // 669, ms(PEAK // 669)))
print()
print("=== 结论 ===")
print("  release 最坏(从 peak 开始) = %.0f ms" % ms(PEAK // 2))
print("  => 只要静默 > %.0f ms, 任何 voice 都必须归零" % ms(PEAK // 2))
print("  => 仿真里等 2000 tick (%.0f ms) 是【足够】的" % ms(2000))
