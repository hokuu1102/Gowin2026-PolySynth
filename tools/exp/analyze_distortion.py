"""分析 DS0005（尖音失真）—— 找"两个音色/失真"的波形特征。

用户描述：
  · 约 50% 概率出现
  · 每次出现都【失真】
  · 尖音与当前按下键的【音高一致】

假设（相位去相关失效）：
  一个 voice 有 2 个 lane（OSC_PER_VOICE=2），设计上初相差 1/4 周期。
  若 voice 被复用后相位差变成任意值，则：
    · 接近同相 => 幅度 x2 => 削顶失真（⭐ 但音高不变，仍是同一个音）
    · 接近反相 => 抵消   => 变弱
  => 两种都【不改变基频】=> 与"音高一致"吻合！

判据：
  1. 估基频（过零率），看是否与 DS0004 的正常音相同
  2. 看幅度分布：是否有"平顶"（削顶的指纹）或双峰
  3. 看是否出现"幅度周期性强弱"（拍频/相干叠加的征兆）
"""
import math

P = r"C:\Users\hokuu\Downloads\DS0005.CSV"
DT = 0.0002          # 200 us/点


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


def main():
    d = load(P)
    n = len(d)
    mean = sum(d) / n
    s = [x - mean for x in d]
    print("points = %d   dt = %.0f us   span = %.2f s" % (n, DT * 1e6, n * DT))
    print("DC = %.6f" % mean)
    print("min = %.6f  max = %.6f" % (min(d), max(d)))
    print()

    # ---------- 1. 逐段统计：找"失真段" ----------
    W = int(0.05 / DT)       # 50 ms 窗
    print("=== 50 ms windows: pk-pk, peak, RMS, crest ===")
    print("   t(s) |   pk-pk  |   peak   |   RMS    | crest | zerox")
    segs = []
    for i in range(0, n - W, W):
        seg = s[i:i + W]
        pk = max(abs(x) for x in seg)
        pp = max(seg) - min(seg)
        rms = math.sqrt(sum(x * x for x in seg) / len(seg))
        zc = sum(1 for k in range(1, len(seg))
                 if (seg[k - 1] < 0) != (seg[k] < 0))
        crest = pk / rms if rms > 0 else 0
        segs.append((i * DT, pp, pk, rms, crest, zc))
        if len(segs) <= 40:
            print("  %5.2f | %8.5f | %8.5f | %8.5f | %5.2f | %5d"
                  % (i * DT, pp, pk, rms, crest, zc))

    # ---------- 2. 找"异常"段（pp 明显大）----------
    pps = sorted(x[1] for x in segs)
    med = pps[len(pps) // 2]
    print()
    print("median pk-pk = %.5f" % med)
    print("segments with pk-pk > 2x median:")
    for (t, pp, pk, rms, crest, zc) in segs:
        if pp > 2 * med:
            print("   t=%5.2f  pk-pk=%.5f (%.1fx)  peak=%.5f  crest=%.2f  zc=%d"
                  % (t, pp, pp / med, pk, crest, zc))

    # ---------- 3. 全局幅度直方图（找削顶平顶）----------
    print()
    print("=== amplitude histogram (normalized to peak) ===")
    pk = max(abs(x) for x in s)
    NB = 20
    hist = [0] * NB
    for x in s:
        b = int(abs(x) / pk * (NB - 1))
        hist[b] += 1
    for b in range(NB):
        lo = pk * b / (NB - 1)
        bar = "#" * int(hist[b] / max(1, max(hist)) * 50)
        print("  %7.5f | %6d %s" % (lo, hist[b], bar))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
