"""DS0004 分析 —— 这是【正确】的尖音波形（用户 2026-09-28 更正）。

用户描述：
  · DS0004 触发了很多次
  · 其中【幅度特别大的】就是那个尖音
  · 尖音与按下键的【音高一致】

已知（我之前算过）：
  500 us/点 × 10000 = 5 秒
  正常段 pp ≈ 0.00125；爆发段 pp ≈ 0.0136~0.0142（约 11 倍）
  爆发出现在 t ≈ 1.88s / 2.0s / 2.25s

本脚本要回答：
  ① 爆发段的【基频】与正常段是否相同？（"音高一致"验证）
  ② 爆发段是否【削顶】（平顶）？
  ③ 正常段为何是【单极性】（min=+0.0004）而爆发段是【双极性】（±0.007）？
"""
import math

P = r"C:\Users\hokuu\Downloads\DS0004.CSV"
DT = 0.0005          # 500 us/点


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    d = []
    for ln in lines[28:]:
        parts = ln.strip().rstrip(",").split(",")
        if len(parts) >= 2:
            try:
                d.append(float(parts[1]))
            except ValueError:
                pass
    return d


def freq_estimate(seg, dt):
    """用零点间隔估基频（半周期法）。"""
    zc = [k for k in range(1, len(seg)) if (seg[k - 1] < 0) != (seg[k] < 0)]
    if len(zc) < 3:
        return 0.0, len(zc)
    span = (zc[-1] - zc[0]) * dt
    if span <= 0:
        return 0.0, len(zc)
    return ((len(zc) - 1) / 2.0) / span, len(zc)


def main():
    d = load(P)
    n = len(d)
    mean = sum(d) / n
    s = [x - mean for x in d]
    print("points=%d dt=%.0fus span=%.2fs  DC=%.6f" % (n, DT * 1e6, n * DT, mean))
    print("raw min=%.6f max=%.6f" % (min(d), max(d)))
    print()

    # ---- 分段（100 ms 窗）找爆发 ----
    W = int(0.1 / DT)
    segs = []
    for i in range(0, n - W, W):
        seg = s[i:i + W]
        pp = max(seg) - min(seg)
        segs.append((i, pp, seg))
    pps = sorted(x[1] for x in segs)
    med = pps[len(pps) // 2]
    print("median pp (100ms) = %.6f" % med)
    print()
    print("=== 爆发段（pp > 3x median）===")
    bursts = [(i, pp, seg) for (i, pp, seg) in segs if pp > 3 * med]
    for (i, pp, seg) in bursts:
        f, zc = freq_estimate(seg, DT)
        mn, mx = min(seg), max(seg)
        # 平顶检测：接近峰值的样本占比
        hi = sum(1 for x in seg if x > mx * 0.95)
        lo = sum(1 for x in seg if x < mn * 0.95)
        print("  t=%5.2fs pp=%.6f (%.1fx)  f_est=%6.1f Hz  zc=%3d  min=%+.5f max=%+.5f"
              % (i * DT, pp, pp / med, f, zc, mn, mx))
        print("         near-max samples: hi=%d lo=%d / %d  (平顶指纹)"
              % (hi, lo, len(seg)))

    print()
    print("=== 正常段（pp 接近 median）抽样 ===")
    normals = [(i, pp, seg) for (i, pp, seg) in segs if abs(pp - med) < 0.3 * med][:6]
    for (i, pp, seg) in normals:
        f, zc = freq_estimate(seg, DT)
        mn, mx = min(seg), max(seg)
        print("  t=%5.2fs pp=%.6f  f_est=%6.1f Hz  zc=%3d  min=%+.5f max=%+.5f"
              % (i * DT, pp, f, zc, mn, mx))

    print()
    print("=== 关键判据 ===")
    if bursts:
        bf = [freq_estimate(seg, DT)[0] for (_, _, seg) in bursts]
        nf = [freq_estimate(seg, DT)[0] for (_, _, seg) in normals]
        bavg = sum(bf) / len(bf)
        navg = sum(nf) / len(nf) if nf else 0
        print("  爆发段平均 f_est = %.1f Hz" % bavg)
        print("  正常段平均 f_est = %.1f Hz" % navg)
        if navg > 0:
            print("  比值 = %.2f" % (bavg / navg))
            print("  => %s" % ("⭐ 频率相近 => 音高一致（符合用户描述）"
                               if 0.7 < bavg / navg < 1.4 else
                               "⚠️ 频率差异大 => 可能是另一个音/高次谐波主导"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
