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
    ap.add_argument("--port", required=True, help="USB-TTL 口，如 COM31")
    ap.add_argument("--baud", type=int, default=500000,
                    help="必须与固件 BLE_BAUD / FPGA 侧一致（默认 500000）")

    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--save", default="", help="原始字节另存")
    args = ap.parse_args()

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
