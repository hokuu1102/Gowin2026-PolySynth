"""从 DS0005 直接找"方波化/硬削顶"的证据 —— 这是"很尖"的最可能机制。

用户描述：
  · 一个键两个音色，有一个【很尖】
  · ~50% 概率
  · 音高与当前键【一致】
  · 每次出现都【失真】

"很尖 + 音高一致" 的物理签名 = 【高频谐波大幅增加，基频不变】。
两种可能：
  A. 硬削顶（幅度超满幅被截）  => 波形出现【平顶】
  B. 波形本身变方（timbre 取到方波表）=> 波形是【方波】，无平顶

判据：
  · A => 幅度直方图两端有【堆积】（平顶）
  · B => 直方图是【双峰】（方波只在两个电平上停留）
  · 正常三角波 => 直方图中间高、两端低（三角形分布）

本脚本：
  1. 找 DS0005 里"最像异常"的段
  2. 对它做直方图 + 电平驻留分析（方波会有明显的"停留电平"）
"""
import math

P = r"C:\Users\hokuu\Downloads\DS0005.CSV"
DT = 0.0002


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


def analyze_segment(seg, tag):
    n = len(seg)
    mn, mx = min(seg), max(seg)
    pp = mx - mn
    print("  [%s] n=%d pp=%.5f min=%.5f max=%.5f" % (tag, n, pp, mn, mx))

    # 直方图（按段内范围归一到 0..1）
    NB = 16
    hist = [0] * NB
    for x in seg:
        b = int((x - mn) / pp * (NB - 1)) if pp > 0 else 0
        hist[min(max(b, 0), NB - 1)] += 1
    tot = sum(hist)
    print("     hist: ", end="")
    for b in range(NB):
        pct = hist[b] * 100.0 / tot
        print("%4.0f%%" % pct, end=" ")
    print()

    # ⭐ 关键：有多少样本"停在两端"（削顶/方波签名）
    end_low = hist[0] + hist[1]
    end_high = hist[NB - 2] + hist[NB - 1]
    mid = sum(hist[NB // 2 - 1:NB // 2 + 1])
    print("     ends(low+high)=%.1f%%  mid=%.1f%%  ratio_ends_mid=%.2f"
          % ((end_low + end_high) * 100.0 / tot, mid * 100.0 / tot,
             ((end_low + end_high) / max(1, mid))))
    # 相邻点"跳变"统计：方波会有很多满幅跳变
    jumps = [abs(seg[i + 1] - seg[i]) for i in range(n - 1)]
    big = sum(1 for j in jumps if j > pp * 0.5)
    print("     big jumps (>50%% of pp): %d / %d = %.1f%%"
          % (big, len(jumps), big * 100.0 / len(jumps)))
    return


def main():
    d = load(P)
    mean = sum(d) / len(d)
    s = [x - mean for x in d]
    n = len(s)
    print("points=%d span=%.2fs" % (n, n * DT))
    print()
    print("=== per 200ms segment ===")
    W = int(0.2 / DT)
    for i in range(0, n - W, W):
        analyze_segment(s[i:i + W], "t=%.1f" % (i * DT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
