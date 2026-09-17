#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""谱峰计数：数出频谱里有几根独立谱峰，并与期望的 N 比对（M4 的自动判定）。

为什么需要它：
    M4（32 voice / Test Mode）的验收判据是
    **"N = 4/8/16/32 时谱峰数正好为 N"**，而评分规则原文要求
    「测试模式下输出多路不同频率音频，**频谱可观测对应数量独立谱峰**」——
    这句话的判定动作就是"**数谱峰**"。人工数会错（相邻频率近时尤其），所以必须自动化。

用法
    # ① 先出频谱，再数峰（两步走，频谱可留档）
    python tools/csv_fft.py tone.csv --fs 48828.125 -o spec.csv
    python tools/peak_count.py spec.csv --expect 4

    # ② 一步到位：直接从样点算（内部调用 csv_fft.analyze）
    python tools/peak_count.py tone.csv --from-samples --fs 48828.125 --expect 32

    # 自检（4 音 / 32 音 / 以及"故意写错期望值必须判失败"）
    python tools/peak_count.py --selftest

判据
    · 谱峰 = **局部极大值**且幅度 ≥ (最高峰 − --min-db dB)
    · 相邻峰间距 < --min-sep-hz 时**合并**（取高的那个）—— 避免把一根峰的裙边数成两根
    · 计数结果与 --expect N 比对；并报告相邻峰的最小间距（= 可分性证据）

退出码：0 = 符合；1 = 不符合或输入有问题；2 = 缺 numpy
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _samples as S  # noqa: E402


def find_peaks(freqs, db, min_db: float = -40.0, min_sep_hz: float = 0.0,
               max_peaks: int = 0):
    """在 (freqs, db) 上找谱峰。

    freqs / db : 等长的序列（list 或 np.ndarray）
    返回 [(freq, db_rel_max), ...]，按频率升序。
    """
    n = len(db)
    if n < 3:
        return []
    top = max(db)
    thr = top + min_db                       # min_db 是负值（相对最高峰的 dB）
    raw = []
    for i in range(1, n - 1):
        if db[i] < thr:
            continue
        if db[i] >= db[i - 1] and db[i] > db[i + 1]:
            raw.append((float(freqs[i]), float(db[i] - top)))
    if not raw:
        return []

    # 按幅度降序合并靠近的峰（近的那根丢掉 —— 它多半是同一根峰的裙边）
    raw.sort(key=lambda t: -t[1])
    kept: list[tuple[float, float]] = []
    for f, d in raw:
        if min_sep_hz > 0 and any(abs(f - kf) < min_sep_hz for kf, _ in kept):
            continue
        kept.append((f, d))
        if max_peaks and len(kept) >= max_peaks:
            break
    kept.sort(key=lambda t: t[0])
    return kept


def load_spectrum(path: str, col_db: str | None, col_freq: str | None):
    """读 csv_fft 产出的频谱表：freq_hz,amplitude,amplitude_db。"""
    header, rows = S.read_columns(path)
    if not rows:
        raise SystemExit(f"❌ {path}：没有数据行")
    if col_freq:
        fi = S.pick_index(header, col_freq)
    else:
        fi = header.index("freq_hz") if "freq_hz" in header else 0
    if col_db:
        di = S.pick_index(header, col_db)
    elif "amplitude_db" in header:
        di = header.index("amplitude_db")
    elif "amplitude" in header:
        di = header.index("amplitude")
    else:
        di = len(header) - 1
    return [r[fi] for r in rows], [r[di] for r in rows], header


# ─────────────────────────── 自检 ───────────────────────────
def _spectrum_from_tones(fs: float, tone_fs: list[float], n: int, amp_ratio: float, np):
    """生成已知多音信号 → 内部调用 csv_fft.analyze 得到频谱。"""
    import csv_fft as F
    t = np.arange(n) / fs
    x = np.zeros(n)
    full = float(1 << 15)
    for i, f in enumerate(tone_fs):
        x += amp_ratio * full * np.sin(2 * np.pi * f * t + 0.3 * i)
    x = np.round(x)
    r = F.analyze(x, fs, "hann", np=np, spur_n=1)
    import math
    db = [20 * math.log10(max(a, 1e-30) / full) for a in r["amp"]]
    return r, list(r["freqs"]), db


def selftest() -> int:
    np = S.need_numpy("peak_count")
    S.banner("peak_count 自检（4 音 / 32 音 / 故意写错期望值必须判失败）")
    v = S.Verdict("peak_count 自检")
    fs = 48828.125
    n = 8192

    # ① 4 音（M4 的最小档）
    tones4 = [500.0, 1500.0, 3000.0, 6000.0]
    r4, f4, db4 = _spectrum_from_tones(fs, tones4, n, 0.2, np)
    pk4 = find_peaks(f4, db4, -40.0, 3 * r4["bin_hz"])
    v.info(f"4 音：数到 {len(pk4)} 根 → {[round(f, 1) for f, _ in pk4]}")
    v.check(len(pk4) == 4, "4 音的谱峰数 = 4", f"实际 {len(pk4)} 根：{[round(f,1) for f,_ in pk4]}")
    v.check(all(abs(f - t) < 20 for (f, _), t in zip(pk4, tones4)),
            "4 音的峰位与设定频率一致")

    # ② 32 音（M4 的最高档 = 提高题复音线）
    tones32 = [400.0 + i * 700.0 for i in range(32)]     # 400 .. 22100 Hz
    r32, f32, db32 = _spectrum_from_tones(fs, tones32, n, 0.02, np)
    pk32 = find_peaks(f32, db32, -40.0, 3 * r32["bin_hz"])
    v.info(f"32 音：数到 {len(pk32)} 根（bin {r32['bin_hz']:.2f} Hz）")
    v.check(len(pk32) == 32, "32 音的谱峰数 = 32", f"实际 {len(pk32)} 根")

    # ③ 相邻峰最小间距必须报出来（"可分性"证据，不能只给个数）
    if len(pk32) > 1:
        gaps = [b[0] - a[0] for a, b in zip(pk32, pk32[1:])]
        v.info(f"32 音最小间距 {min(gaps):.1f} Hz = {min(gaps) / r32['bin_hz']:.1f} 个 bin")
        v.check(min(gaps) > 3 * r32["bin_hz"], "32 音相邻峰间距 > 3 个 bin（可分辨）",
                f"最小 {min(gaps):.1f} Hz")

    # ④ 判据必须会失败：把期望值故意写错
    vv = S.Verdict("（反例）期望值故意写错")
    vv.check(len(pk4) == 5, "期望 5 根（实际 4 根）—— 期望这一项判失败")
    v.check(bool(vv.errors), "写错期望值时判据确实失败了（不是永远通过）")

    return v.finish()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="数频谱里的独立谱峰，与期望 N 比对（M4 自动判定）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input", nargs="?", help="频谱 CSV（csv_fft 产出）或样点 CSV（配 --from-samples）")
    ap.add_argument("--from-samples", action="store_true",
                    help="输入是样点 CSV：内部调用 csv_fft.analyze 先算频谱")
    ap.add_argument("--expect", type=int, default=0,
                    help="期望的谱峰数 N（4/8/16/32；0 = 只报告不判定）")
    ap.add_argument("--min-db", type=float, default=-40.0,
                    help="谱峰门限（相对最高峰的 dB，默认 -40）")
    ap.add_argument("--min-sep-hz", type=float, default=0.0,
                    help="小于该间距的峰合并（默认 0 = 用 3 个 bin 宽）")
    ap.add_argument("--max-peaks", type=int, default=0, help="最多保留几根峰（默认不限）")
    ap.add_argument("--top", type=int, default=8, help="报告里打印前几根（默认 8）")
    ap.add_argument("--fs", type=float, default=48828.125, help="采样率（--from-samples 用）")
    ap.add_argument("--col", help="样点取哪一列（--from-samples 用）")
    ap.add_argument("--unsigned", action="store_true", help="无符号样点")
    ap.add_argument("--bits", type=int, default=16, help="位宽（--unsigned 用）")
    ap.add_argument("--window", default="hann", help="窗（--from-samples 用）")
    ap.add_argument("-o", "--out", help="谱峰表 CSV 输出路径")
    ap.add_argument("--selftest", action="store_true", help="跑内置自检")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.input:
        ap.print_help()
        print("\n❌ 需要给输入（或用 --selftest）")
        return 1
    if not os.path.isfile(args.input):
        print(f"❌ 找不到 {args.input}")
        return 1

    if args.from_samples:
        import csv_fft as F
        np = S.need_numpy("peak_count")
        x = np.asarray(S.read_samples(args.input, col=args.col,
                                      unsigned=args.unsigned, bits=args.bits), dtype=float)
        r = F.analyze(x, args.fs, args.window, np=np, spur_n=1)
        import math
        full = float(1 << (args.bits - 1))
        freqs = list(r["freqs"])
        db = [20 * math.log10(max(a, 1e-30) / full) for a in r["amp"]]
        src_desc = f"{os.path.basename(args.input)}（内部 FFT：{r['n']} 点 / bin {r['bin_hz']:.3f} Hz）"
        bin_hz = r["bin_hz"]
    else:
        freqs, db, header = load_spectrum(args.input, None, None)
        src_desc = os.path.basename(args.input)
        bin_hz = (freqs[1] - freqs[0]) if len(freqs) > 1 else 0.0

    sep = args.min_sep_hz or (3 * bin_hz)
    peaks = find_peaks(freqs, db, args.min_db, sep, args.max_peaks)

    print(f"📄 {src_desc}")
    print(f"   门限 {args.min_db} dB（相对最高峰）· 合并间距 {sep:.3f} Hz")
    print(f"   ⭐ 谱峰数 = {len(peaks)}")
    for i, (f, d) in enumerate(peaks[:args.top]):
        print(f"      #{i + 1:<3} {f:>10.2f} Hz   {d:>7.2f} dBc")
    if len(peaks) > args.top:
        print(f"      …… 还有 {len(peaks) - args.top} 根")
    if len(peaks) > 1:
        gaps = [b[0] - a[0] for a, b in zip(peaks, peaks[1:])]
        print(f"   相邻峰最小间距 {min(gaps):.2f} Hz"
              + (f" = {min(gaps) / bin_hz:.2f} 个 bin" if bin_hz else ""))

    if args.out:
        S.write_csv(args.out, [f"# peak_count {os.path.basename(args.input)} "
                               f"min_db={args.min_db} sep_hz={sep:.6f} count={len(peaks)}",
                               "index,freq_hz,db_rel_peak"]
                    + [f"{i + 1},{f:.6f},{d:.4f}" for i, (f, d) in enumerate(peaks)])
        print(f"   ✅ 谱峰表 {args.out}")

    if not args.expect:
        print("\nℹ️  没给 --expect，只报告不判定（M4 验收请给 --expect 4/8/16/32）")
        return 0

    v = S.Verdict(f"谱峰计数（期望 {args.expect}）")
    v.check(len(peaks) == args.expect,
            f"谱峰数正好 = {args.expect}",
            f"实际数到 {len(peaks)} 根：{[round(f, 1) for f, _ in peaks]}")
    return v.finish()


if __name__ == "__main__":
    sys.exit(main())
