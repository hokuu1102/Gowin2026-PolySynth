#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把仿真导出的样本文件转成 WAV —— 用于「不接任何硬件就听到音色」。

为什么需要它：
    音色设计要几十次来回试。上板一次要 综合→P&R→下载（几分钟），
    拿来调音色是浪费；而仿真导出样本 + 转 WAV 是【秒级】迭代。
    这条路径不需要 DAC、不需要引脚约束、不需要开发板。

用法：
    # 1) testbench 里把每个采样点按行写进文本文件（十进制或 0x 十六进制都可）
    #    $fdisplay(fd, "%d", sample);          有符号
    #    $fdisplay(fd, "%d", sample + 32768);  无符号（差 2^(bits-1)）
    #
    # 2) 转成 WAV
    python tools/wav_from_samples.py sim_out.txt -o tone.wav --fs 48828 --bits 16
    python tools/wav_from_samples.py sim_out.txt -o tone.wav --fs 48828 --unsigned
    python tools/wav_from_samples.py sim_out.txt -o tone.wav --gain 0.5 --bits 24

    # 3) 直接播放
    #    Windows: start tone.wav       （或双击）

设计取舍（刻意为之）：
    · **默认不归一化** —— 保持仿真的真实幅度。这样"有没有削波""包络峰
      值对不对"才是可信的；一归一化就把这些问题掩盖掉了。
      想调音量用 --gain 显式指定。
    · **会报告峰值与削波** —— 数字侧削波在仿真阶段最容易被忽略，
      而在示波器/耳朵上未必听得出来（可能是"变响"而不是"变破"）。
    · 只依赖标准库（wave/struct），不装任何第三方包。

输入格式：每行一个整数。空行与 # 开头的注释行会被跳过。
          支持十进制、负号、以及 0x / 0b 前缀。

退出码：0 = 正常；1 = 输入有问题（无有效样本 / 行数不是声道数整数倍等）
"""

from __future__ import annotations

import argparse
import os
import sys
import wave

# 输出编码兜底（Windows 控制台默认 GBK）
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


def parse_samples(path: str) -> list[int]:
    """读文本样本文件，返回整数列表。"""
    vals: list[int] = []
    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            # 允许一行里有多个样本（空白分隔）
            for tok in line.split():
                tok = tok.rstrip(",;")
                if not tok:
                    continue
                try:
                    if tok.lower().startswith(("0x", "-0x")):
                        vals.append(int(tok, 16))
                    elif tok.lower().startswith(("0b", "-0b")):
                        vals.append(int(tok, 2))
                    else:
                        vals.append(int(tok, 10))
                except ValueError:
                    print(f"⚠️  第 {lineno} 行无法解析为整数，已跳过：{tok!r}")
    return vals


def pack_signed(value: int, bits: int) -> bytes:
    """把一个有符号整数按给定位宽打包成小端字节。"""
    if bits == 8:
        # WAV 的 8-bit 是【无符号】，这里加 128 偏移
        return bytes([max(0, min(255, value + 128))])
    if bits == 16:
        return int(value).to_bytes(2, "little", signed=True)
    if bits == 24:
        return (int(value) & 0xFFFFFF).to_bytes(3, "little")
    if bits == 32:
        return int(value).to_bytes(4, "little", signed=True)
    raise ValueError(f"不支持的位宽：{bits}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把仿真导出的样本文本转成 WAV",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input", help="样本文本文件（每行一个整数）")
    ap.add_argument("-o", "--output", required=True, help="输出的 .wav 路径")
    ap.add_argument("--fs", type=float, default=48828,
                    help="采样率 Hz（默认 48828 = 本项目 50MHz÷1024，见音频方案 §6.3）")
    ap.add_argument("--bits", type=int, default=16, choices=[8, 16, 24, 32],
                    help="位宽（默认 16）")
    ap.add_argument("--channels", type=int, default=1,
                    help="声道数（默认 1；>1 时输入按交错排列）")
    ap.add_argument("--unsigned", action="store_true",
                    help="输入是无符号（0..2^bits-1），会自动减去 2^(bits-1)")
    ap.add_argument("--gain", type=float, default=1.0,
                    help="线性增益（默认 1.0，即不改动幅度）")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        print(f"❌ 找不到输入文件：{args.input}")
        return 1

    samples = parse_samples(args.input)
    if not samples:
        print("❌ 没有解析到任何样本（检查文件是不是空的 / 格式对不对）")
        return 1

    if args.channels < 1:
        print("❌ --channels 必须 ≥ 1")
        return 1
    if len(samples) % args.channels:
        print(f"⚠️  样本数 {len(samples)} 不是声道数 {args.channels} 的整数倍，"
              f"末尾 {len(samples) % args.channels} 个已丢弃")

    # 无符号 → 有符号
    if args.unsigned:
        samples = [v - (1 << (args.bits - 1)) for v in samples]

    # 增益
    if args.gain != 1.0:
        samples = [int(round(v * args.gain)) for v in samples]

    # 位宽范围与削波检测
    lo, hi = -(1 << (args.bits - 1)), (1 << (args.bits - 1)) - 1
    if args.bits == 8:
        lo, hi = -128, 127
    peak = max(abs(v) for v in samples)
    clipped = sum(1 for v in samples if v < lo or v > hi)

    frames = bytearray()
    for v in samples:
        frames += pack_signed(max(lo, min(hi, v)), args.bits)

    with wave.open(args.output, "wb") as w:
        w.setnchannels(args.channels)
        w.setsampwidth(args.bits // 8)
        w.setframerate(int(round(args.fs)))
        w.writeframes(bytes(frames))

    dur = len(samples) / args.channels / args.fs
    print(f"✅ 已写出 {args.output}")
    print(f"   {len(samples)} 个样本 / {args.channels} 声道 / "
          f"{args.bits} bit / {args.fs:.0f} Hz  →  时长 {dur:.3f} s")

    # 峰值报告：用满刻度的百分比表示，便于判断"是不是太小/太大"
    full = float(hi)
    pct = peak / full * 100 if full else 0
    print(f"   峰值 {peak} / 满刻度 {hi}  = {pct:.1f}%  （线性增益 {args.gain}）")
    if clipped:
        print(f"   ⚠️ 削波 {clipped} 个样本 —— 仿真值超出 {args.bits} bit 范围，"
              f"已在写入时截断；请检查内部位宽或增益")
    elif pct < 5:
        print("   ℹ️ 峰值偏低（<5%）。听感会很小，两种可能：")
        print("      · 信号本身就这么小 → 用 --gain 放大")
        print("        （默认刻意不归一化，以免掩盖真实幅度问题）")
        if args.bits > 16:
            print(f"      · 换了位宽但没重新缩放 ⚠️ → 每多 8 bit 要多 ×256："
                  f"16bit 的值放到 {args.bits}bit 需要 --gain "
                  f"{256 ** ((args.bits - 16) // 8)}")
        elif args.bits < 16:
            print(f"      · 换了位宽但没重新缩放 ⚠️ → 位宽变小要相应缩小")

    print()
    print("   播放：  start " + args.output if os.name == "nt"
          else "   播放：  xdg-open " + args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
