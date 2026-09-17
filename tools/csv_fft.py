#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CSV → FFT：对样点流做频谱分析，报**主峰频率 / SNR / 杂散**，并出图出表。

为什么需要它：
    M1（第一次"出声"）、M4（Test Mode 谱峰数）、M5（音色差异）的验收判据都是
    **频谱**——而 `files/20-代码/仿真与验证方案.md` 的铁律是"证据必须可复现"。
    这个脚本把"波形 CSV → 频谱图 + 主峰/SNR/杂散报告"变成一条命令。
    它同时是 M4 的 `peak_count.py` 的前半段（后者复用本文件的 `analyze()`）。

用法
    # 一段已知正弦（T4 的验收：主峰频率必须正确）
    python tools/csv_fft.py sim/evidence/sine_1k.csv --fs 48828.125 --bits 16 -o sim/evidence/fft.csv --plot sim/evidence/fft.png

    # 从 VCD 直接来（配合 vcd2csv）
    python tools/vcd2csv.py x.vcd -s sample --fs 48828.125 | python tools/csv_fft.py -

    # 自检（内置已知正弦，不需要任何输入文件；并写出证据）
    python tools/csv_fft.py --selftest

判据怎么读（三个数）
    · **主峰频率**：用抛物线插值取亚 bin 精度（不是简单取 argmax 的 bin 中心）
    · **SNR**：信号功率 = 主瓣（±2 bin）内功率；噪声 = 其余全部功率（扣掉 DC）
      ⇒ 它衡量"这一个音有多干净"，不是"信号有多强"
    · **杂散**：主瓣之外最大的几个局部极大值，用 dBc（相对主峰）表示
      ⇒ 杂散高 = 有别的频率在响（谐波/混叠/时钟泄漏）

退出码：0 = 正常；1 = 有问题；2 = 缺 numpy
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _samples as S  # noqa: E402

WINDOWS = {
    "none": lambda n, np: np.ones(n),
    "hann": lambda n, np: np.hanning(n),
    "hamming": lambda n, np: np.hamming(n),
    "blackman": lambda n, np: np.blackman(n),
}


def make_window(name: str, n: int, np):
    if name not in WINDOWS:
        raise SystemExit(f"❌ 不认识的窗 {name!r}（可选：{', '.join(WINDOWS)}）")
    return WINDOWS[name](n, np)


def analyze(x, fs: float, window: str = "hann", nfft: int = 0,
            keep_dc: bool = False, spur_n: int = 3, np=None):
    """核心分析：返回一个 dict（供 csv_fft 与 peak_count 共用）。

    x : 一维样点（np.ndarray, float）
    """
    if np is None:
        np = S.need_numpy("csv_fft")
    x = np.asarray(x, dtype=float)
    n = x.size
    if n < 8:
        raise SystemExit(f"❌ 样点太少（{n} 个）—— FFT 没有意义")

    if not keep_dc:
        x = x - x.mean()                      # 去直流：否则 DC 峰会淹没主峰

    w = make_window(window, n, np)
    wsum = float(w.sum())
    xw = x * w

    nfft_used = int(nfft) if nfft and nfft >= n else n
    spec = np.fft.rfft(xw, n=nfft_used)
    mag = np.abs(spec)
    power = mag ** 2
    freqs = np.fft.rfftfreq(nfft_used, d=1.0 / fs)

    # 幅度校正：正弦幅度 = 2|X|/sum(w)（窗的相干增益）
    # ⚠️ DC 与 Nyquist 这两根 bin 没有"正负频率各一半"的问题，**不能翻倍**
    amp = 2.0 * mag / wsum
    amp[0] = mag[0] / wsum
    if nfft_used % 2 == 0 and amp.size > 1:
        amp[-1] = mag[-1] / wsum

    # ── 主峰：argmax + 抛物线插值（用对数幅度，亚 bin 精度）──
    k0 = int(np.argmax(power[1:]) + 1) if power.size > 1 else 0
    if 0 < k0 < mag.size - 1:
        a, b, c = np.log(mag[k0 - 1] + 1e-30), np.log(mag[k0] + 1e-30), np.log(mag[k0 + 1] + 1e-30)
        denom = (a - 2 * b + c)
        delta = 0.5 * (a - c) / denom if abs(denom) > 1e-20 else 0.0
        delta = float(np.clip(delta, -0.5, 0.5))
    else:
        delta = 0.0
    f_peak = float((k0 + delta) * fs / nfft_used)

    # ── SNR：主瓣 ±2 bin 内算信号，其余算噪声 ──
    lobe = np.zeros_like(power, dtype=bool)
    lo = max(1, k0 - 2)
    hi = min(power.size, k0 + 3)
    lobe[lo:hi] = True
    p_sig = float(power[lobe].sum())
    outside = ~lobe
    outside[:3] = False                       # DC 及其泄漏不参与
    nb = int(outside.sum())
    # ⚠️⚠️ 噪声功率**不能**用"主瓣以外全部相加"：
    #     那会被**窗的旁瓣裙边**主导 —— Hann 的裙边按 18 dB/oct 衰减，
    #     几千根 bin 一累加（+33 dB）就能把"16 bit 量化正弦"的 SNR 从 ~88 dB
    #     压成 44 dB 的**假读数**（本脚本自检时实测踩到）。
    #     正确做法：用主瓣外谱线的**中位数**估噪声密度（稳健统计量，落在平坦噪声底上），
    #     再乘 bin 数还原总噪声功率。杂散是稀疏的，因此不会被中位数吃掉 ——
    #     它们由下面的"杂散报告"单独给出（这正是"SNR 达标"与"无杂散"要分两条判据的原因）。
    per_bin = float(np.median(power[outside])) if nb else 0.0
    p_noise = per_bin * nb
    snr_db = 10.0 * np.log10(p_sig / p_noise) if p_noise > 0 else float("inf")
    noise_floor_dbc = (10.0 * np.log10(per_bin / p_sig)
                       if (p_sig > 0 and per_bin > 0) else -999.0)

    # ── 杂散：主瓣之外的最大局部极大值（按 dBc 排序）──
    spurs = []
    for k in range(3, power.size - 1):        # k<3 是 DC 泄漏区，不算杂散
        if lobe[k] or power[k] <= 0:
            continue
        if power[k] > power[k - 1] and power[k] >= power[k + 1]:
            spurs.append((float(freqs[k]), float(10.0 * np.log10(power[k] / p_sig)) if p_sig > 0 else -999.0))
    spurs.sort(key=lambda t: -t[1])

    return {
        "n": n, "fs": fs, "window": window, "nfft": nfft_used,
        "freqs": freqs, "amp": amp, "mag": mag, "power": power,
        "f_peak": f_peak, "k_peak": k0, "delta": delta,
        "a_peak": float(amp[k0]), "snr_db": float(snr_db),
        "noise_floor_dbc": float(noise_floor_dbc), "noise_per_bin": per_bin,
        "spurs": spurs[:spur_n], "p_sig": p_sig, "p_noise": p_noise,
        "bin_hz": fs / nfft_used,
    }


def report(r: dict, full_scale: float | None, spur_n: int = 3) -> None:
    print(f"   样点 {r['n']} 个 · fs {r['fs']:g} Hz · 窗 {r['window']} · "
          f"nfft {r['nfft']} · bin {r['bin_hz']:.4g} Hz")
    peak_db = (20 * math.log10(max(r["a_peak"], 1e-30) / full_scale)
               if full_scale else None)
    print(f"   ⭐ 主峰 {r['f_peak']:.4f} Hz  (bin {r['k_peak']} + {r['delta']:+.3f})"
          + (f" · 幅度 {peak_db:.2f} dBFS" if peak_db is not None else
             f" · 幅度 {r['a_peak']:.4g}"))
    print(f"   SNR {r['snr_db']:.2f} dB（噪声密度中位数法；单 bin 噪声底 {r['noise_floor_dbc']:.1f} dBc）")
    if r["spurs"]:
        s = " · ".join(f"{f:.1f} Hz {db:.1f} dBc" for f, db in r["spurs"])
        print(f"   杂散（前 {min(spur_n, len(r['spurs']))}）{s}")
    else:
        print("   杂散 无（主瓣之外没有局部极大值）")


def write_spectrum_csv(path: str, r: dict, db_ref: float | None) -> None:
    lines = [f"# csv_fft spectrum: fs={r['fs']:g} window={r['window']} nfft={r['nfft']} "
             f"peak_hz={r['f_peak']:.6f} snr_db={r['snr_db']:.3f}",
             "freq_hz,amplitude,amplitude_db"]
    for f, a in zip(r["freqs"], r["amp"]):
        db = 20 * math.log10(a / db_ref) if (db_ref and a > 0) else 0.0
        lines.append(f"{f:.6f},{a:.8g},{db:.4f}")
    S.write_csv(path, lines)
    print(f"   ✅ 频谱表 {path}（{len(r['freqs'])} 行）")


def plot_spectrum(path: str, r: dict, db_ref: float | None, title: str) -> bool:
    """出图。⚠️ 图内文字**一律 ASCII** —— 中文字体在多数环境是方块（见经验集 U31）。"""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("   ℹ️ 没装 matplotlib，跳过出图（--plot 需要它：python -m pip install matplotlib）")
        return False
    mag_db = [20 * math.log10(max(a, 1e-30) / db_ref) if db_ref else 20 * math.log10(max(a, 1e-30))
              for a in r["amp"]]
    fig, ax = plt.subplots(figsize=(10, 4.5), dpi=110)
    ax.plot(r["freqs"], mag_db, linewidth=0.9)
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Amplitude (dBFS)" if db_ref else "Amplitude (dB)")
    ax.set_title(title)
    ax.grid(True, alpha=0.3)
    ax.axvline(r["f_peak"], color="tab:red", linestyle="--", linewidth=1.0)
    ax.annotate(f"peak {r['f_peak']:.2f} Hz\nSNR {r['snr_db']:.1f} dB",
                xy=(r["f_peak"], max(mag_db)), xytext=(6, -34),
                textcoords="offset points", fontsize=9, color="tab:red")
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    print(f"   ✅ 频谱图 {path}")
    return True


# ─────────────────────────── 自检 ───────────────────────────
def synth_sine(fs: float, freqs: list[float], n: int, amp: float, np, phase0: float = 0.0):
    t = np.arange(n) / fs
    x = np.zeros(n)
    for i, f in enumerate(freqs):
        x += amp * np.sin(2 * np.pi * f * t + phase0 + i)
    return x


def write_samples_csv(path: str, fs: float, x, source: str) -> None:
    lines = [f"# {source}: fs={fs:g} n={len(x)}"]
    lines += [f"{i},{int(round(v))}" for i, v in enumerate(x)]
    S.write_csv(path, lines)


def selftest() -> int:
    np = S.need_numpy("csv_fft")
    S.banner("csv_fft 自检（内置已知正弦；证据写进 sim/evidence/）")
    v = S.Verdict("csv_fft 自检")
    fs = 48828.125
    n = 4096
    bits = 16
    full = float(1 << (bits - 1))

    # ① 单音 1000 Hz：主峰必须准
    #    ⚠️ 一定要按**量化后**的整数来分析 —— 直接分析浮点正弦会得到 160+ dB 的
    #       "完美 SNR"，那是双精度浮点的底噪，不是真实数据链路的噪声（自检踩过）。
    x = np.round(synth_sine(fs, [1000.0], n, 0.5 * full, np))
    csv = S.evidence_path("selftest_sine_1k.csv")
    write_samples_csv(csv, fs, x, "csv_fft selftest 1000 Hz @ fs=48828.125")
    r = analyze(x, fs, "hann", np=np)
    v.info(f"1000 Hz 单音：主峰 {r['f_peak']:.4f} Hz · SNR {r['snr_db']:.2f} dB")
    v.check(abs(r["f_peak"] - 1000.0) < 0.5,
            "主峰频率正确（1000 Hz，误差 < 0.5 Hz）", f"实测 {r['f_peak']:.4f} Hz")
    v.check(r["snr_db"] > 80.0, "单音 SNR > 80 dB（16 bit 量化正弦，中位数噪声估计）",
            f"实测 {r['snr_db']:.2f} dB")

    # 窗函数的相干增益必须被校正：幅度要接近设定值
    v.check(abs(r["a_peak"] - 0.5 * full) / (0.5 * full) < 0.02,
            "幅度校正正确（≈0.5×满刻度，误差 < 2%）",
            f"实测 {r['a_peak']:.1f} vs 期望 {0.5 * full:.1f}")

    write_spectrum_csv(S.evidence_path("selftest_sine_1k_spectrum.csv"), r, full)
    plot_spectrum(S.evidence_path("selftest_sine_1k_spectrum.png"), r, full,
                  "csv_fft selftest: 1000 Hz sine @ fs=48828.125")

    # ② 双音：第二根音必须出现在杂散报告里（= 频谱里真的有两根）
    x2 = np.round(synth_sine(fs, [1000.0, 3000.0], n, 0.4 * full, np))
    r2 = analyze(x2, fs, "hann", np=np, spur_n=3)
    near = [f for f, _ in r2["spurs"] if abs(f - 3000.0) < 20.0]
    v.info(f"双音：主峰 {r2['f_peak']:.2f} Hz · 杂散 {[(round(f,1), round(d,1)) for f, d in r2['spurs']]}")
    v.check(bool(near), "双音里第二根音（3000 Hz）被识别为谱峰/杂散", f"杂散 {r2['spurs']}")

    # ③ 频率分辨率：440 Hz 也要准（低频时亚 bin 插值更关键）
    for f0 in (440.0, 12345.678):
        rr = analyze(np.round(synth_sine(fs, [f0], n, 0.5 * full, np)), fs, "hann", np=np)
        v.check(abs(rr["f_peak"] - f0) < 0.5, f"主峰频率正确（{f0} Hz）",
                f"实测 {rr['f_peak']:.4f} Hz")

    return v.finish()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="对样点 CSV 做 FFT，报主峰/SNR/杂散，并出频谱表与图",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input", nargs="?", help="样点 CSV（`-` = 从 stdin 读）")
    ap.add_argument("--fs", type=float, default=48828.125,
                    help="采样率 Hz（默认 48828.125 = 50 MHz ÷ 1024）")
    ap.add_argument("--col", help="取哪一列（列号或列名；默认最后一列）")
    ap.add_argument("--bits", type=int, default=16, help="位宽（用于 --unsigned 与 dBFS）")
    ap.add_argument("--unsigned", action="store_true", help="输入是无符号，自动减 2^(bits-1)")
    ap.add_argument("--full-scale", type=float, default=None,
                    help="dBFS 的满刻度（默认 2^(bits-1)）")
    ap.add_argument("--window", default="hann", choices=list(WINDOWS), help="窗（默认 hann）")
    ap.add_argument("--nfft", type=int, default=0, help="FFT 点数（默认 = 样点数，补零会插值谱线）")
    ap.add_argument("--keep-dc", action="store_true", help="保留直流（默认先去均值）")
    ap.add_argument("--spurs", type=int, default=3, help="报告前几个杂散（默认 3）")
    ap.add_argument("-o", "--out", help="频谱 CSV 输出路径")
    ap.add_argument("--plot", help="频谱 PNG 输出路径")
    ap.add_argument("--title", default="Spectrum", help="图标题（⭐ 只用 ASCII）")
    ap.add_argument("--selftest", action="store_true", help="跑内置自检（不需要输入文件）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.input:
        ap.print_help()
        print("\n❌ 需要给输入 CSV（或用 --selftest）")
        return 1

    if args.input == "-":
        tmp = S.evidence_path("_stdin_samples.csv")
        data = sys.stdin.read()
        if not data.strip():
            print("❌ stdin 里没有数据")
            return 1
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(data)
        src = tmp
    else:
        src = args.input
        if not os.path.isfile(src):
            print(f"❌ 找不到 {src}")
            return 1

    x = S.read_samples(src, col=args.col, unsigned=args.unsigned, bits=args.bits)
    np = S.need_numpy("csv_fft")
    x = np.asarray(x, dtype=float)

    r = analyze(x, args.fs, args.window, args.nfft, args.keep_dc, args.spurs, np=np)
    fs_full = args.full_scale if args.full_scale is not None else float(1 << (args.bits - 1))

    print(f"📄 {os.path.basename(src)}")
    report(r, fs_full, args.spurs)

    if args.out:
        write_spectrum_csv(args.out, r, fs_full)
    if args.plot:
        plot_spectrum(args.plot, r, fs_full, args.title)
    return 0


if __name__ == "__main__":
    sys.exit(main())
