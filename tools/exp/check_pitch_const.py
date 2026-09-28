"""决定性验证：DS0005 的基频是否恒定 + 两个 lane 的相位关系。

用户关键描述：
  · 约 50% 概率
  · 每次出现都失真
  · 【尖音和当前按下键的音高一致】  <-- 这条最重要

若"相位去相关失效"假设成立（voice 复用时两 lane 相位差随机）：
  · 基频【不变】（仍是那个键的音）           ✅ 与用户描述吻合
  · 但波形 = sin(w t) + sin(w' t + phi)     => 拍频 + 包络起伏
  · crest / pk-pk 周期性起伏                 ✅ 与实测吻合
  · 不失真到削顶（幅度未必超限）              ✅ 与直方图吻合
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


def main():
    d = load(P)
    mean = sum(d) / len(d)
    s = [x - mean for x in d]
    n = len(s)

    # ---- 用零点间隔估【瞬时】频率（滑动 200ms 窗）----
    print("=== instantaneous frequency estimate (200 ms windows) ===")
    print("   t(s) |  zerox |  freq_est(Hz)")
    W = int(0.2 / DT)
    for i in range(0, n - W, W):
        seg = s[i:i + W]
        zc = []
        for k in range(1, len(seg)):
            if (seg[k - 1] < 0) != (seg[k] < 0):
                zc.append(k)
        if len(zc) >= 2:
            # 半周期数 -> 频率
            span = (zc[-1] - zc[0]) * DT
            half = len(zc) - 1
            f = (half / 2.0) / span if span > 0 else 0
        else:
            f = 0
        print("  %5.2f | %6d | %10.2f" % (i * DT, len(zc), f))

    print()
    print("=== 用户说'尖音与按下键音高一致' => 基频应恒定 ===")
    # 去掉首尾不稳段，算整体频率
    seg = s[int(0.1 / DT):int(1.9 / DT)]
    zc = [k for k in range(1, len(seg)) if (seg[k - 1] < 0) != (seg[k] < 0)]
    span = (zc[-1] - zc[0]) * DT
    f_all = ((len(zc) - 1) / 2.0) / span
    print("  overall f = %.2f Hz" % f_all)
    print()
    print("  对比音高表(左板): C3=130.8 E3=164.8 F3=174.6 G3=196.0 A3=220 B3=246.9 C4=261.6")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
