#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""延迟统计：把延迟测量日志变成 **min/max/均值/极差** 表，并按 M2 的判据自动判定。

为什么需要它：
    M2（低延迟拨弦）的判据不是"平均挺快"，而是
    **"数字端 < 2 个音频帧、且 50 次统计的极差 < 0.1 ms"**
    —— 要的是**稳定上界**（规则原文："≤5 ms 且**确定性无抖动**"）。
    人眼看 50 行日志会漏掉那一个离群值，而这个离群值恰恰就是"有抖动"的证据。

用法
    # testbench 里每条延迟打印一行，例如：  LATENCY 61
    python tools/latency_stats.py sim/evidence/latency.log --unit cycles

    # 整行就是一个数（最省事的日志格式）
    python tools/latency_stats.py lat.log --plain --label "UP 拨弦"

    # 自检（内置正例 + **故意造一个超差的例子**，证明判据真的会失败）
    python tools/latency_stats.py --selftest

⭐ 单位口径（最容易搞错的一处）
    · `cycles` = **系统时钟（clk_sys = 50 MHz）周期数** → 换算时间要除以 `--clk-sys`
    · **1 个音频帧 = `CLK_PER_SAMPLE` = 1024 个 clk_sys 周期 = 20.48 µs**
      （= `1/fs`，fs = 50 MHz ÷ 1024 = 48828.125 Hz）
    ⛔ 别把 "cycles" 除以 fs —— 那是两条不同的尺子（自检里踩过：
      60 拍的延迟会被算成 60 个音频帧，直接把"<2 帧"判成失败）

判据（默认就是 M2 的目标值，可用参数改）
    · 最大值 ≤ --max-frames 个音频帧（默认 2 帧 = 2048 个 clk_sys 周期）
    · 极差 ≤ --max-range-ms ms（默认 0.1 ms）
    · 样本数 == --expect-count（给了才查；M2 要求 50 次）

退出码：0 = 全部符合；1 = 有不符合项
"""

from __future__ import annotations

import argparse
import os
import re
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _samples as S  # noqa: E402

DEFAULT_PATTERN = r"(?:latency|lat|delay|lat_cyc|延迟)\s*[:=]?\s*(\d+)"
TO_SEC = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}


def parse_values(text: str, pattern: str | None, plain: bool) -> list[float]:
    vals: list[float] = []
    if plain:
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith(("#", "//")):
                continue
            try:
                vals.append(float(line))
            except ValueError:
                pass
        return vals
    rx = re.compile(pattern or DEFAULT_PATTERN, re.IGNORECASE)
    for raw in text.splitlines():
        for m in rx.finditer(raw):
            vals.append(float(m.group(1)))
    return vals


def to_seconds(values: list[float], unit: str, clk_sys: float) -> list[float]:
    """统一换算成秒。

    ⚠️ `cycles` 指的是 **clk_sys 周期**（50 MHz），所以除以 `clk_sys` ——
       ⛔ 不是除以音频采样率 fs（那会把 60 拍算成 60 个"音频帧"）。
    """
    if unit == "cycles":
        return [v / clk_sys for v in values]
    return [v * TO_SEC[unit] for v in values]


def summarize(values: list[float], unit: str, fs: float,
              clk_sys: float = 50e6, clk_per_sample: int = 1024) -> dict:
    """统计。`fs` 只用于把时间换算成"音频帧"；cycles→秒用 `clk_sys`。"""
    secs = to_seconds(values, unit, clk_sys)
    ms = [s * 1e3 for s in secs]
    frames = [s * fs for s in secs]
    return {
        "count": len(values),
        "unit": unit,
        "fs": fs,
        "clk_sys": clk_sys,
        "clk_per_sample": clk_per_sample,
        "clk_per_frame": clk_sys / fs,
        "frame_us": 1e6 / fs,
        "min": min(values), "max": max(values),
        "mean": st.fmean(values), "median": st.median(values),
        "std": st.pstdev(values) if len(values) > 1 else 0.0,
        "range": max(values) - min(values),
        "min_ms": min(ms), "max_ms": max(ms), "mean_ms": st.fmean(ms),
        "range_ms": max(ms) - min(ms),
        "max_frames": max(frames), "mean_frames": st.fmean(frames),
        "frame_ms": 1e3 / fs,
        "values": values,
    }


def judge(s: dict, max_frames: float, max_range_ms: float, expect_count: int) -> S.Verdict:
    v = S.Verdict(f"延迟判据（{s['count']} 次）")
    if expect_count:
        v.check(s["count"] == expect_count, f"样本数 = {expect_count}", f"实测 {s['count']}")
    v.check(s["max_frames"] <= max_frames,
            f"最大延迟 ≤ {max_frames:g} 个音频帧（数字端目标）",
            f"实测 {s['max_frames']:.3f} 帧 = {s['max_ms']:.4f} ms")
    v.check(s["range_ms"] <= max_range_ms,
            f"极差 ≤ {max_range_ms:g} ms（确定性无抖动）",
            f"实测 {s['range_ms']:.4f} ms（{s['range']:g} {s['unit']}）")
    return v


def print_table(s: dict) -> None:
    print(f"   1 音频帧 = {s['clk_per_frame']:.0f} 个 clk_sys 周期 = {s['frame_us']:.3f} µs"
          f"（fs={s['fs']:g} Hz，clk_sys={s['clk_sys']:g} Hz）")
    print(f"   {'指标':<10}{'原始单位(' + s['unit'] + ')':>18}{'µs':>14}{'音频帧':>12}")
    rows = [
        ("样本数", f"{s['count']}", "", ""),
        ("最小", f"{s['min']:g}", f"{s['min_ms'] * 1e3:.3f}", f"{s['min_ms'] * s['fs'] / 1e3:.3f}"),
        ("最大", f"{s['max']:g}", f"{s['max_ms'] * 1e3:.3f}", f"{s['max_frames']:.3f}"),
        ("均值", f"{s['mean']:.3f}", f"{s['mean_ms'] * 1e3:.3f}", f"{s['mean_frames']:.3f}"),
        ("中位数", f"{s['median']:g}", "", ""),
        ("标准差", f"{s['std']:.4f}", "", ""),
        ("极差", f"{s['range']:g}", f"{s['range_ms'] * 1e3:.3f}", f"{s['range_ms'] * s['fs'] / 1e3:.3f}"),
    ]
    for name, a, b, c in rows:
        print(f"   {name:<10}{a:>18}{b:>14}{c:>12}")


# ─────────────────────────── 自检 ───────────────────────────
def _mk_log(vals: list[float], style: str) -> str:
    if style == "plain":
        return "\n".join(f"{v:g}" for v in vals) + "\n"
    if style == "latency=":
        return "\n".join(f"t={i} latency={v:g}" for i, v in enumerate(vals)) + "\n"
    return "\n".join(f"LATENCY {v:g}" for v in vals) + "\n"


def selftest() -> int:
    S.banner("latency_stats 自检（正例 + 故意造的超差例；证明判据真的会失败）")
    v = S.Verdict("latency_stats 自检")
    fs = 48828.125

    # ① 正例：50 次，60/61 拍（极差 1 拍 ≈ 0.02 µs）→ 应当通过
    good = [60, 61] * 25
    s = summarize(good, "cycles", fs)
    jg = judge(s, 2.0, 0.1, 50)
    v.info(f"正例：50 次 60~61 拍 → 最大 {s['max_frames']:.4f} 帧（{s['max_ms'] * 1e3:.3f} µs）、"
           f"极差 {s['range_ms'] * 1e3:.4f} µs")
    v.check(not jg.errors, "正例全部通过（不误报）", f"误报项：{jg.errors}")

    # ② 反例（故意注入）：夹一个 20000 拍的离群值 → 必须判失败（两条判据都要踩中）
    bad = good[:-1] + [20000]
    sb = summarize(bad, "cycles", fs)
    jb = judge(sb, 2.0, 0.1, 50)
    v.info(f"反例：一个 20000 拍的离群值 → 最大 {sb['max_frames']:.1f} 帧、极差 {sb['range_ms']:.4f} ms")
    v.check(bool(jb.errors), "反例被判失败（判据不是永远通过）", "判据没抓到离群值")
    v.check(any("最大延迟" in e for e in jb.errors), "失败项确实指向'最大延迟'")
    v.check(any("极差" in e for e in jb.errors), "失败项确实指向'极差'")

    # ③ 三种日志格式都要能解析
    for style in ("plain", "latency=", "LATENCY"):
        txt = _mk_log([60, 61, 62], style)
        got = parse_values(txt, None, plain=(style == "plain"))
        v.check(got == [60, 61, 62], f"能解析 {style} 格式的日志", f"实测 {got}")

    # ④ 单位换算：--unit us 时不做 cycles 换算
    su = summarize([100, 110], "us", fs)
    v.check(abs(su["max_ms"] - 0.11) < 1e-9, "unit=us 的换算正确（110 µs = 0.11 ms）",
            f"实测 {su['max_ms']}")

    return v.finish()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="延迟测量日志 → min/max/均值/极差 + M2 判据",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input", nargs="?", help="日志文件（`-` = 从 stdin 读）")
    ap.add_argument("--pattern", help=f"抽取延迟的正则（默认 {DEFAULT_PATTERN}）")
    ap.add_argument("--plain", action="store_true", help="整行就是一个数（最省事的日志格式）")
    ap.add_argument("--unit", default="cycles", choices=["cycles", "s", "ms", "us", "ns"],
                    help="日志里的单位（默认 cycles，用 --fs 换算）")
    ap.add_argument("--fs", type=float, default=48828.125,
                    help="音频采样率 Hz（把时间换算成'音频帧'用；默认 50 MHz ÷ 1024）")
    ap.add_argument("--clk-sys", type=float, default=50e6,
                    help="系统时钟 Hz（--unit cycles 换算成秒用；默认 50 MHz）")
    ap.add_argument("--max-frames", type=float, default=2.0,
                    help="最大延迟上界（音频帧数，默认 2 = M2 目标）")
    ap.add_argument("--max-range-ms", type=float, default=0.1,
                    help="极差上界 ms（默认 0.1 = M2 目标）")
    ap.add_argument("--expect-count", type=int, default=0,
                    help="期望样本数（默认 0 = 不检查；M2 用 50）")
    ap.add_argument("--label", default="", help="报告标题（例如 'UP 拨弦'）")
    ap.add_argument("-o", "--out", help="统计表 CSV 输出路径")
    ap.add_argument("--selftest", action="store_true", help="跑内置自检")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.input:
        ap.print_help()
        print("\n❌ 需要给日志文件（或用 --selftest）")
        return 1

    if args.input == "-":
        text = sys.stdin.read()
        src = "<stdin>"
    else:
        if not os.path.isfile(args.input):
            print(f"❌ 找不到 {args.input}")
            return 1
        text = open(args.input, "r", encoding="utf-8-sig", errors="replace").read()
        src = args.input

    vals = parse_values(text, args.pattern, args.plain)
    if not vals:
        print(f"❌ 在 {src} 里没有抽到任何延迟值")
        print(f"   默认匹配：{DEFAULT_PATTERN}")
        print("   若日志是「整行一个数」，加 --plain；否则用 --pattern 指定正则。")
        return 1

    s = summarize(vals, args.unit, args.fs)
    print(f"📄 {src}" + (f"   [{args.label}]" if args.label else ""))
    print_table(s)

    v = judge(s, args.max_frames, args.max_range_ms, args.expect_count)
    code = v.finish()

    if args.out:
        S.write_csv(args.out, [
            f"# latency_stats {os.path.basename(src)} unit={s['unit']} fs={s['fs']:g} "
            f"label={args.label or '-'}",
            "metric,value",
            f"count,{s['count']}",
            f"min,{s['min']:g}", f"max,{s['max']:g}", f"mean,{s['mean']:.6f}",
            f"median,{s['median']:g}", f"std,{s['std']:.6f}", f"range,{s['range']:g}",
            f"max_ms,{s['max_ms']:.6f}", f"range_ms,{s['range_ms']:.6f}",
            f"max_frames,{s['max_frames']:.6f}", f"mean_frames,{s['mean_frames']:.6f}",
        ])
        print(f"   ✅ 统计表 {args.out}")
    return code


if __name__ == "__main__":
    sys.exit(main())
