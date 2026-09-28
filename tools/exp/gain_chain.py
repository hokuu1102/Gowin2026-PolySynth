#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gain_chain.py -- 量化整条增益链（对照 xls32 源码校验）

目的：算清 ">>>1 与 gain=44 是否重复衰减"，并给出正确基准。

xls32 的对照（core/synth.x）：
    let mix1 = st.mixacc + (((amp as s24 as s32) * compv) >> u32:8);
    let comp = match p.unison { u2:0 => s32:256, u2:1 => s32:181, ... };   // 256/sqrt(N)
    let compv = (comp * (p.vol as s32)) >> u32:7;
    fn scale_mix(acc: s32) -> u16 { let s = acc >> u32:5; ... }

  => xls32 是【固定 comp】（按 unison 数定，运行期不变），
     而我们是【动态 popcount -> 查表】。两者数学上等价（都是 1/sqrt(N) 型）。

我们当前链路（rtl/w3b/tdm_render_mixer.v）：
    vs_c = (lane0 + lane1) >>> NORM_SH          // NORM_SH=1
    prod = vs_c * env                            // env Q0.16
    acc  = sum(prod)                             // 40 bit
    sh   = acc >>> 16
    sh24 = sh <<< 8
    out  = (sh24 * gain[n]) >>> 7                // gain Q8.7
    limiter: |x| > 0x799999 (95%) -> 压缩 4:1
"""

FULL24 = 8388607          # 24-bit signed full scale
LIM95  = int(FULL24 * 0.95)

def single_voice_sh24(env=65535, two_lane=True, norm_shift=1):
    """单 voice 满幅时的 sh24 值（>>>1 之后）"""
    lane = 32767
    vs = lane * 2 if two_lane else lane
    vs = vs >> norm_shift
    prod = vs * env
    sh = prod >> 16
    return sh << 8

def out_level(gain_q87, voice_gain=1.0, n_voice=1, coherent=True):
    """给定 gain（Q8.7）与 voice 数，算输出峰值"""
    import math
    sh24 = single_voice_sh24()
    per_voice = sh24 * voice_gain
    if coherent:
        sum_amp = n_voice * per_voice          # 严格同相（最坏）
    else:
        sum_amp = math.sqrt(n_voice) * per_voice  # 非相干（真实演奏）
    return sum_amp * gain_q87 / 128.0

def pct(x):
    return x * 100.0 / FULL24

print("=" * 72)
print(" 增益链量化（对照 xls32 core/synth.x）")
print("=" * 72)
print()

sh24 = single_voice_sh24()
print(f"单 voice 满幅 sh24（>>>1 之后） = {sh24}")
print(f"  => 占 24 位满幅 = {pct(sh24):.1f}%")
print(f"  => 结论：>>>1 之后单 voice 已【正好满幅】")
print()

print("-" * 72)
print(" 关键问题：>>>1 与 gain/128 是否重复衰减？")
print("-" * 72)
print()
print("  >>>1      : 2x lane -> 1x lane   = -6.0 dB")
print("  gain=44   : 44/128               = -9.3 dB")
print("  ------------------------------------------")
print("  合计                              = -15.3 dB")
print()
print("  => 是【两次独立衰减】，⛔ 不是重复（作用对象不同）")
print("     但【叠加起来】单音只剩 34%，这就是'单音小'")
print()

print("-" * 72)
print(" 若移除 >>>1（回退 lane 平均），各 gain 的单音电平：")
print("-" * 72)
print()
no_norm = single_voice_sh24(norm_shift=0)
print(f"  不 >>>1 时单 voice sh24 = {no_norm} = {pct(no_norm):.1f}% 满幅")
print()
print("  gain  单音输出      占满幅")
for g in [44, 64, 88, 104, 128]:
    o = no_norm * g / 128.0
    flag = "  <-- 削顶" if o > FULL24 else ""
    print(f"  {g:4d}  {o:10.0f}   {pct(o):6.1f}%{flag}")
print()

print("-" * 72)
print(" 保留 >>>1 时各 gain 的单音电平：")
print("-" * 72)
print()
print("  gain  单音输出      占满幅")
for g in [44, 64, 88, 104, 128]:
    o = sh24 * g / 128.0
    flag = "  <-- 削顶" if o > FULL24 else ""
    print(f"  {g:4d}  {o:10.0f}   {pct(o):6.1f}%{flag}")
print()

print("-" * 72)
print(" 多音行为（保留 >>>1，gain 表为 g/sqrt(N)）：")
print("-" * 72)
print()
import math
print("  gain   N=1    N=2    N=4    N=8    N=16   模型")
for g in [44, 88, 104]:
    for coh in (True, False):
        row = f"  {g:4d} "
        for N in [1, 2, 4, 8, 16]:
            gn = round(g / math.sqrt(N))
            o = out_level(gn, n_voice=N, coherent=coh)
            row += f"{pct(o):6.0f} "
        row += " 同相" if coh else " 非相干"
        print(row)
print()
print("  => 非相干模型下，1/sqrt(N) 让峰值【恒定】= g/128 * 单voice")
print("     这正是 xls32 没做动态归一化也能工作的原因（它按 unison 固定 comp）")
print()

print("=" * 72)
print(" 建议")
print("=" * 72)
print()
print("  对照 xls32：它用【固定 comp】而非动态 N，且 scale_mix 只在最后一级。")
print("  我们保留动态 1/sqrt(N) 是正确的（响度与 N 无关，手感更好）。")
print()
print("  '单音小' 的正解：把 gain 基准从 44 提到 ~90-104")
print("     gain=88  => 单音 69% 满幅")
print("     gain=104 => 单音 81% 满幅")
print()
print("  ⚠️ 但注意：上板实测 gain=104 曾'全失真'—— 那是因为当时【无失谐】，")
print("     两 lane 严格相干 => 实际是 2x 而非 1x => N=2 就 115%。")
print("     现在【已有失谐】，模型应改为非相干 => 104 应可用。")
print("     => 建议先上板验证 gain=88（保守），再决定是否提。")
print()
