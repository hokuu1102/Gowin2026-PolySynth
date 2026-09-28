#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kb_inc vs fb_inc：键盘表到底给出什么音高？"""

FS = 48828.125
BASE_INC = 0x00100000
SEMI_Q16 = 69433

def inc_to_hz(inc):
    return inc * FS / (2**32)

def key_inc(k):
    acc = BASE_INC
    for _ in range(k):
        acc = (acc * SEMI_Q16) >> 16
    return acc

print("=" * 72)
print(" 键盘表 kb_inc（key_inc 半音阶梯）实际音高")
print("=" * 72)
print()
print("  BASE_INC = 0x%08X = %d" % (BASE_INC, BASE_INC))
print("  SEMITONE_Q16 = %d (%.4f, 应为 %.4f)" % (SEMI_Q16, SEMI_Q16/65536, 2**(1/12)))
print()
print("  BASE_INC 对应频率 = %.2f Hz" % inc_to_hz(BASE_INC))
print()

NOTE = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
def name_of(hz):
    if hz <= 0: return '?'
    import math
    n = 12 * math.log2(hz / 440.0) + 69
    ni = round(n)
    return "%s%d (%.2f Hz, 偏差 %+.1f 音分)" % (NOTE[ni % 12], ni // 12 - 1, hz, (n - ni) * 100)

print("  轴   inc          频率       音名")
print("  ---  -----------  ---------  ---------------------------")
for k in range(16):
    inc = key_inc(k)
    print("  %2d   0x%08X  %8.2f   %s" % (k, inc, inc_to_hz(inc), name_of(inc_to_hz(inc))))
print()
print("=" * 72)
print(" 结论")
print("=" * 72)
print()
print("  ⭐ kb_inc 是【半音阶梯】：轴 0 = 基准音，逐轴 +1 半音")
print("  ⭐ 频率【是对的】（半音阶数学正确）")
print("  ⚠️ 但【轴号 ↔ 物理键位】的对应关系，是【按轴号升序】的假设")
print("     => 而 fb_inc 才是【按真实物理位置】排的（你 2026-09-23 确认过）")
print()
