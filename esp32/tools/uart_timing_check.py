#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_timing_check.py —— 抓 UART1 字节流【带时间戳】，验证帧间时序

═══ 验什么 ═══
⭐ **帧内 / 帧间的字节间隔**，判据是 FPGA 的空闲归位门限：

    FPGA `evt_uart_rx.v:86`  GAP_BYTES = 16
    ⇒ 空闲 ≥ 16 个字节时间 ⇒ 判为"帧边界"，状态机归位

    | 波特率 | 1 字节 | GAP_BYTES=16 ⇒ 门限 |
    |---|---|---|
    | 1 Mbps | 10.0 µs | ⭐ 160 µs |
    | 500 k  | 20.0 µs | ⭐ 320 µs |

🔴 **为什么这是关键判据**：
    9N 铁律要求「**一帧 9 字节一次写入**」——
    ⚠️ 如果一帧内部出现 ≥ 门限的空隙，FPGA 会**误判为帧边界** ⇒
    🔴 **半帧被当成一整帧** ⇒ 后续全错位（⭐ 静默少音 / 弹错音）。

⚠️ 本脚本【不能】验"放水节奏" —— 那是 `pool_pump()` 的 tick 限流，
   ⚠️ 而现在 `pool_start()` 零调用 ⇒ 根本没有放水（见矛盾裁定单）。
   ⭐ 本脚本验的是**物理层帧间时序**。

═══ 用法 ═══
    python uart_timing_check.py --port COM31 --baud 1000000 --seconds 20
    python uart_timing_check.py --port COM31 --baud 500000  --seconds 20
"""

import argparse
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK，会炸）----------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HDR_EVENT = 0xA5
GAP_BYTES = 16          # ⭐ FPGA evt_uart_rx.v:86 / top.v:331,362


def byte_time_us(baud):
    """8N1 = 10 bit/字节。"""
    return 10.0 / float(baud) * 1e6


def stats_us(vals):
    """返回 (min, p50, p90, p99, max)（微秒）。"""
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)

    def pct(p):
        i = int(round((n - 1) * p))
        return s[max(0, min(n - 1, i))]

    return s[0], pct(0.50), pct(0.90), pct(0.99), s[-1]


def selftest() -> int:
    """
    ⭐ 离线自检（⛔ 不需要硬件、不需要串口）。

    ⭐⭐ 为什么需要它（⭐ 2026-10-01 补）：
      🔴 本工具是【验收工具】—— ⚠️ 它算出来的【帧间时序】结论直接进验收报告
      ⇒ ⚠️ 它的字节时间换算 / 分位数统计错了，结论就不可信。

    ⭐ 判据两层：① ⭐ 正例（换算/统计都对）② ⭐⭐ 反例（改坏必须判红）
    """
    print("=" * 74)
    print("uart_timing_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① ⭐ byte_time_us：⭐ 拿【独立已知的物理真值】对，⛔ 不是自我循环 ----
    print("\n[1] ⭐ byte_time_us()：8N1 = 10 bit/字节 ⇒ 1 字节 = 10 / baud 秒")
    # ⭐ 期望值来自【物理事实】（10 bit / baud），⛔ 不是从 byte_time_us 自己抄出来的。
    #    ⚠️ 若哪天有人把 10.0 写成 11.0（加校验位），这一组会立刻红。
    for baud, want_us in ((500000, 20.0), (1000000, 10.0), (115200, 86.80555556)):
        got = byte_time_us(baud)
        chk("   %-8d baud -> %.4f µs（真值 %.4f）" % (baud, got, want_us),
            abs(got - want_us) < 1e-4, "  差 %+.6f" % (got - want_us))
    # ⭐ 与公式对照（⭐ 公式也是"物理真值"的一种写法，两条独立路径互证）
    chk("   与 1e6*10/baud 一致（500k）", byte_time_us(500000) == 1e6 * 10 / 500000)
    chk("   与 1e6*10/baud 一致（1M）", byte_time_us(1000000) == 1e6 * 10 / 1000000)
    # ⭐ 波特率翻倍 ⇒ 字节时间减半（⭐ 能抓住"乘除写反 / 常数写错"）
    chk("   波特率翻倍 ⇒ 字节时间减半",
        abs(byte_time_us(1000000) * 2.0 - byte_time_us(500000)) < 1e-9)

    # ---- ② ⭐ 与项目【真实约束】对齐：FPGA 的 GAP_BYTES = 16 ----
    print("\n[2] ⭐ 项目真实约束：FPGA 空闲归位门限 GAP_BYTES = 16 字节")
    chk("   GAP_BYTES = 16（⭐ evt_uart_rx.v:86 冻结值）", GAP_BYTES == 16,
        "  实测 %d" % GAP_BYTES)
    # ⭐ 320 µs @500k 是本项目【文档里写死的】数字（见文件头表格）⇒ 拿它当外部真值。
    gate_500k = byte_time_us(500000) * GAP_BYTES
    chk("   500 kbaud: 16 字节 = 320.0 µs（容差 1 µs）",
        abs(gate_500k - 320.0) <= 1.0, "  实测 %.4f µs" % gate_500k)
    gate_1m = byte_time_us(1000000) * GAP_BYTES
    chk("   1 Mbaud:   16 字节 = 160.0 µs（容差 1 µs）",
        abs(gate_1m - 160.0) <= 1.0, "  实测 %.4f µs" % gate_1m)

    # ---- ③ stats_us()：⭐ 空表行为按【源码实际行为】核（源码 return None）----
    print("\n[3] stats_us() 分位数（⭐ 口径：nearest-rank，下标 = round((n-1)*p)）")
    chk("   空表 -> None（⭐ 源码就是 return None，⛔ 不是空元组）",
        stats_us([]) is None)
    chk("   单元素 -> 五元组全等", stats_us([7]) == (7, 7, 7, 7, 7))
    vals = list(range(1, 101))                      # ⭐ 1..100 µs
    s = stats_us(vals)
    # ⚠️ 防崩：⭐ 若 stats_us 被改坏成"非空也返回 None"，下面每条 s[i] 的
    #    比较（含 None <= None）都会抛 TypeError ⇒ ⚠️ 那【不是判红，是崩溃】。
    #    ⇒ ⭐ 用 NaN 当"毒值"兜住：NaN 与任何数比较都是 False ⇒
    #      ⭐ 每条判据都会老实报 RED，⛔ 自检不会崩。
    chk("   非空表返回五元组（⭐ 不是 None）",
        isinstance(s, tuple) and len(s) == 5, "  实测 %r" % (s,))
    if not (isinstance(s, tuple) and len(s) == 5):
        s = (float("nan"),) * 5
    chk("   1..100: min = 1", s[0] == 1, "  实测 %s" % (s[0],))
    chk("   1..100: p50 = 51（下标 round(99*0.50)=50）", s[1] == 51,
        "  实测 %s" % s[1])
    chk("   1..100: p90 = 90（下标 round(99*0.90)=89）", s[2] == 90,
        "  实测 %s" % s[2])
    chk("   1..100: p99 = 99（下标 round(99*0.99)=98）", s[3] == 99,
        "  实测 %s" % s[3])
    chk("   1..100: max = 100", s[4] == 100, "  实测 %s" % (s[4],))
    chk("   ⭐ 单调不减 min<=p50<=p90<=p99<=max",
        s[0] <= s[1] <= s[2] <= s[3] <= s[4])

    # ---- ④ ⭐⭐ 反例（非空洞性）：⭐ 改坏必须能被发现 ----
    print("\n[4] ⭐⭐ 反例：改坏必须能被发现（⭐ 判据必须能失败）")
    # ⭐ 4a：⭐ 故意拿【错的期望值】去核 ⇒ ⭐ 必须不等。
    #        ⚠️ 若这一条变成"相等"，说明上面的正例判据是空洞的（⭐ 见经验 C83）。
    chk("   错期望值 999 会被判红（⭐ 非空洞）", s[0] != 999)
    chk("   错期望值 20.5 µs 会被判红（⭐ 非空洞）",
        abs(byte_time_us(500000) - 20.5) > 1e-9)
    # ⭐ 4b：倒序输入必须给出【同样的】分位数 ⇒ ⭐ 证明它内部真的排序了
    #        （⚠️ 谁把 sorted() 删掉，这一条立刻红）
    rev = stats_us(list(range(100, 0, -1)))
    chk("   倒序输入的分位数与正序一致（⭐ 证明它排序）", rev == s,
        "  正序 p50=%s / 倒序 p50=%s" % (s[1], rev[1] if rev else None))
    # ⭐ 4c：换一组数据 ⇒ ⭐ 分位数必须真的跟着变（⭐ 防"返回常量"的假实现）
    chk("   换数据分位数必须变（⭐ 不是常量）",
        stats_us([1, 2, 3, 4, 5]) != stats_us([10, 20, 30, 40, 50]))
    # ⭐ 4d：⭐ 结论判据本身能红 —— 造一个"帧内间隔超门限"的样本，必须被抓住
    fake_over = [5.0, 10.0, gate_500k + 1.0]
    fake_ok = [5.0, 10.0, gate_500k - 1.0]
    chk("   超门限的帧内间隔会被判红（⭐ 结论判据能失败）",
        len([g for g in fake_over if g >= gate_500k]) == 1)
    chk("   未超门限的帧内间隔不会被误判",
        len([g for g in fake_ok if g >= gate_500k]) == 0)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def recv_stamped(port, baud, seconds):
    """
    ⭐ 关键：逐字节 read(1) + 打时间戳。
    ⚠️ pyserial 的 read(n) 在收满 n 字节或超时才返回 ⇒
       n 太大会把不同时刻的字节糊成一个时间戳。
    """
    import serial

    data = bytearray()
    stamps = []
    ser = serial.Serial(port, baud, timeout=0.05)
    try:
        ser.reset_input_buffer()
        t_end = time.perf_counter() + seconds
        while time.perf_counter() < t_end:
            b = ser.read(1)
            if b:
                stamps.append(time.perf_counter())
                data += b
    finally:
        ser.close()          # ⭐ 必须释放
    return bytes(data), stamps


def main() -> int:
    ap = argparse.ArgumentParser(description="抓 UART 字节流并做帧间时序判据")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件/串口）")
    ap.add_argument("--port", help="USB-TTL 口，如 COM31")
    ap.add_argument("--baud", type=int, default=500000,
                    help="必须与固件 BLE_BAUD / FPGA 侧一致（默认 500000）")

    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--save", default="", help="原始字节另存")
    args = ap.parse_args()

    # ⭐ 自检优先 —— ⚠️ 不需要 --port（⭐ 便于批量自检统一调用）
    if args.selftest:
        return selftest()
    if not args.port:
        print("🔴 需要 --port（⚠️ 或用 --selftest）")
        return 2

    try:
        import serial  # noqa: F401
    except ImportError:
        print("🔴 缺 pyserial —— pip install pyserial")
        return 2

    bt = byte_time_us(args.baud)
    gate = GAP_BYTES * bt

    print("=" * 70)
    print("UART 帧间时序验证")
    print("=" * 70)
    print("口 = %s   波特率 = %d" % (args.port, args.baud))
    print("1 字节 = %.2f µs" % bt)
    print("⭐ FPGA 空闲归位门限 = GAP_BYTES(%d) × %.2f = %.1f µs"
          % (GAP_BYTES, bt, gate))
    print()
    print("监听 %.1f 秒 ...（⭐ 现在去复位 ESP32）" % args.seconds)
    print()

    data, stamps = recv_stamped(args.port, args.baud, args.seconds)

    print("-" * 70)
    print("收到 %d 字节" % len(data))
    if not data:
        print()
        print("🔴 0 字节 —— 排查：")
        print("   ① ESP32 在发吗？（看日志有没有 'wrote N bytes'）")
        print("   ② 接线：ESP32 GPIO17 → USB-TTL RXD（⚠️ 交叉）")
        print("   ③ 共地：GND -- GND")
        print("   ④ 波特率两端一致？（ESP32 固件里是多少）")
        return 4

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(args.save, "wb") as f:
            f.write(data)
        print("原始字节已存: %s" % os.path.abspath(args.save))

    # ---- 逐字节间隔 --------------------------------------------------------
    gaps = [(stamps[i + 1] - stamps[i]) * 1e6 for i in range(len(stamps) - 1)]

    # 帧内间隔（同一帧的 8 个间隙）vs 帧间间隔（跨帧那 1 个）
    intra = []
    inter = []
    for i, g in enumerate(gaps):
        if (i % FRAME_BYTES) == (FRAME_BYTES - 1):
            inter.append(g)
        else:
            intra.append(g)

    print()
    print("---- 帧内字节间隔（⭐ 必须都 < 门限）----")
    st = stats_us(intra)
    if st:
        print("  n=%d  min=%.1f  p50=%.1f  p90=%.1f  p99=%.1f  max=%.1f µs"
              % (len(intra), st[0], st[1], st[2], st[3], st[4]))
        over = [g for g in intra if g >= gate]
        if over:
            print("  🔴 有 %d 个帧内间隔 ≥ 门限(%.1f µs) ⇒ ⚠️ FPGA 会误判帧边界！"
                  % (len(over), gate))
            print("     最大几个: %s" % ["%.1f" % x for x in sorted(over)[-5:]])
        else:
            print("  ✅ 全部 < 门限 ⇒ 帧内无伪边界")

    print()
    print("---- 帧间间隔（⭐ 应 ≥ 门限，FPGA 靠它归位）----")
    st2 = stats_us(inter)
    if st2:
        print("  n=%d  min=%.1f  p50=%.1f  p90=%.1f  p99=%.1f  max=%.1f µs"
              % (len(inter), st2[0], st2[1], st2[2], st2[3], st2[4]))
        below = [g for g in inter if g < gate]
        if below:
            print("  ⚠️ 有 %d 个帧间间隔 < 门限(%.1f µs)" % (len(below), gate))
            print("     ⚠️ 这【不一定是错】—— 若发送端把多帧合成一次 write，")
            print("        帧间就没有空隙（⭐ 这是允许的：FPGA 靠【帧头 0xA5】区分）")
            print("     最小几个: %s" % ["%.1f" % x for x in sorted(below)[:5]])
        else:
            print("  ✅ 全部 ≥ 门限")

    # ---- 9N / 帧头 ---------------------------------------------------------
    print()
    print("---- 9N 对齐 + 帧头 ----")
    rem = len(data) % FRAME_BYTES
    nf = len(data) // FRAME_BYTES
    print("  9N 对齐: %s（%d 字节 = %d 帧，余 %d）"
          % ("✅" if rem == 0 else "🔴", len(data), nf, rem))
    bad = [(i, data[i * FRAME_BYTES]) for i in range(nf)
           if data[i * FRAME_BYTES] != HDR_EVENT]
    print("  帧头 0xA5: %d/%d %s" % (nf - len(bad), nf,
                                    "" if not bad else "🔴"))
    if bad:
        for i, h in bad[:8]:
            print("     帧 #%-6d 帧头=0x%02X" % (i, h))

    # ---- 总时长 / 吞吐 -----------------------------------------------------
    if len(stamps) > 1:
        dur = stamps[-1] - stamps[0]
        print()
        print("---- 总时长 ----")
        print("  首字节→末字节 = %.4f s" % dur)
        if dur > 0:
            print("  实测吞吐 = %.1f 帧/s  (%.1f KB/s)"
                  % (nf / dur, len(data) / dur / 1024.0))
            ideal = args.baud / 10.0      # 字节/s
            print("  理论上限 = %.0f 字节/s ⇒ 线利用率 %.1f%%"
                  % (ideal, 100.0 * (len(data) / dur) / ideal))

    print()
    print("=" * 70)
    ok = (rem == 0) and (not bad) and (not [g for g in intra if g >= gate])
    print("结论：%s" % ("✅ 帧间时序合格（帧内无伪边界）" if ok
                        else "🔴 有问题，看上面标红项"))
    print("=" * 70)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
