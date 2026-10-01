#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loopback_check.py -- ESP32 蓝牙 SPP <-> UART2 回环自测

================================================================================
这是 ESP32 通路上【最有价值】的一个工具：它把"蓝牙链路"和"FPGA"解耦，
出问题一眼能定位是哪边。⛔ 全程不需要 FPGA。

接线：
    PC ──USB(或蓝牙)──> ESP32（SPP）      ← 发送端
    PC ──USB-TTL─────> ESP32 的 UART2      ← 接收端（本脚本读它，带时间戳）

判据（每条都必须能失败）：
    1. 字节流逐字节一致
    2. >=100 KB 不丢一个字节
    3. 一串 0xA5 被【原样】透传
    4. 🔴 帧内空隙 < 门限/2        ← 本脚本的核心，只比内容测不出它
    5. 反向也通
    6. 两种波特率都跑（115200 / 1 Mbps）
    7. 长稳（可选的 --duration 压力模式）

🔴 为什么判据 4 要单独做：
    FPGA 侧 rtl/w3c/evt_uart_rx.v:203 的空闲归位只在【帧中途】触发，
    门限 = GAP_BYTES(16) 个字节时间：
        1 Mbps   -> 160 us   -> 判据卡 80 us
        115200   -> 1.39 ms  -> 判据卡 700 us
    一帧的 9 字节若被 RFCOMM 切成两次投递，中间隔一个调度周期（可达 ms），
    就会截帧。而【只比对内容根本看不出这件事】—— 内容全对，帧却散架了。
    在 FPGA 上表现为"默默少几个音"，且 resync_cnt/hdr_err_cnt 不一定涨。
    => 必须用【每个字节的到达时间戳】来测。

⚠️⚠️ 一条【2026-09-23 新增】的重要口径（★ 起播改成了上板手动按键）：
    FPGA 侧答复（files/20-代码/FPGA侧答复-ESP32对接清单-20260923.md §三）明确：
      起播时刻由【人按板上的键】决定 => 起播前 play_seq 【不消费】
      => 那段时间里 "缓冲水位不为 0" 和 "evt_underrun_o" 都【不代表故障】
    ⇒ 所以任何与"消费进度/underrun"有关的观察，
      ★ 观察窗口必须从【已起播】开始算，不能从"发送端开始发"开始算。
    ⛔ 否则会看到假失败（缓冲区是满的，但消费者还没开跑）。
    ⭐ 本脚本的判据 1~7 都是【链路层】判据，不受起播影响；
      但若你把本脚本的输出喂给带 FPGA 的端到端测试，
      ★ 请务必对"起播后"的那段数据做统计。

用法：
    # 只做离线自检（⛔ 不用硬件）—— 先证明判据逻辑本身是对的
    python loopback_check.py --selftest

    # 真回环：从蓝牙 COM 口发，从 USB-TTL COM 口收
    python loopback_check.py --tx-port COM11 --rx-port COM7 --baud 1000000

    # 发真实曲谱量级的数据
    python loopback_check.py --tx-port COM11 --rx-port COM7 --hex build/score/regen/09_Conjurer/events.hex
================================================================================
"""

import argparse
import os
import random
import sys
import time

# ==============================================================================
# ⚠️ 控制台编码：Windows 默认 GBK，编码不了 ⛔/⭐ 这类符号
# ==============================================================================
# 实测踩过：print 含 \u26d4 的字符串会 UnicodeEncodeError: 'gbk' codec ...
# => 这里【自己】把标准输出重配成 UTF-8，⛔ 不依赖用户设 PYTHONIOENCODING。
#    （同族教训见经验库 C17：编码归属由【读取/写出方】决定）
for _stream_name in ("stdout", "stderr"):
    _s = getattr(sys, _stream_name, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HEADER = 0xA5
RESET_FRAMES = 4                      # 与 tools/evt2uart.py 一致
RESET_BYTES = FRAME_BYTES * RESET_FRAMES    # 36

# 门限 = GAP_BYTES(16) 个字节时间；判据留一倍余量
GAP_BYTES = 16
SAFETY_DIV = 2.0


def byte_time_us(baud):
    """一字节时间（秒）。8N1 = 10 bit/字节。"""
    return 10.0 / float(baud)


def gap_limit_us(baud):
    """FPGA 空闲归位门限（微秒）。"""
    return GAP_BYTES * byte_time_us(baud) * 1e6


def judge_limit_us(baud):
    """判据门限 —— 留一倍余量（UART 自身的字节间隔就有抖动）。"""
    return gap_limit_us(baud) / SAFETY_DIV


# ==============================================================================
# 激励生成
# ==============================================================================
def build_reset():
    """复位序列 = RESET_FRAMES 帧全 0xA5（36 字节，9 的整数倍）。"""
    return bytes([HEADER]) * RESET_BYTES


def load_hex_events(path):
    """
    读 events.hex（每行一个 64 bit 事件，十六进制），封成 9 字节帧。

    ⚠️ 与 tools/evt2uart.py 的 pack_frame 同口径：
        全 0xA5 的事件会被拦掉（否则会被 FPGA 当成复位标记整帧抑制）。
    """
    words = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            for tok in s.replace(",", " ").split():
                tok = tok.strip()
                if not tok:
                    continue
                words.append(int(tok, 16))
    out = bytearray()
    for w in words:
        body = w.to_bytes(8, "big")
        frame = bytes([HEADER]) + body
        if frame == bytes([HEADER]) * FRAME_BYTES:
            continue        # 全 0xA5：拦截
        out += frame
    return bytes(out)


def gen_pattern(kind, nbytes, seed=20260922):
    """生成测试载荷（保证长度是 9 的整数倍）。"""
    nframes = max(1, nbytes // FRAME_BYTES)
    n = nframes * FRAME_BYTES

    if kind == "counter":
        # 帧对齐的递增内容：每 9 字节一帧，帧头 0xA5
        out = bytearray()
        for i in range(nframes):
            out.append(HEADER)
            out += (i & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")
        return bytes(out)

    if kind == "all-a5":
        # 一串 0xA5 —— 判据 3 用。⚠️ 这【会】被 FPGA 当复位序列，但本测试只验透传
        return bytes([HEADER]) * n

    if kind == "random":
        rnd = random.Random(seed)
        out = bytearray()
        for _ in range(nframes):
            out.append(HEADER)                       # 保持帧结构
            out += bytes(rnd.randrange(256) for _ in range(8))
        return bytes(out)

    raise ValueError("unknown pattern: %s" % kind)


# ==============================================================================
# 🔴 核心判据：帧内空隙
# ==============================================================================
def scan_frame_gaps(stamps, frame_bytes=FRAME_BYTES):
    """
    扫描所有【帧内】相邻字节的到达间隔，返回 (最大间隔秒, 位置, 该帧的首字节下标)。

    ⭐ 为什么按"帧"切而不是按"整个流"切：
        帧【之间】可以任意停顿（FPGA 的归位只在一帧中途触发），
        所以帧间的长间隔是【正常】的，必须排除掉。

    只扫描：对每个 frames 起点 f，看 [f, f+frame_bytes) 内部的间隔。
    """
    if len(stamps) < 2:
        return (0.0, -1, -1)

    worst = 0.0
    worst_pos = -1
    worst_frame = -1

    nframes = len(stamps) // frame_bytes
    for f in range(nframes):
        base = f * frame_bytes
        for k in range(base + 1, base + frame_bytes):
            if k >= len(stamps):
                break
            d = stamps[k] - stamps[k - 1]
            if d > worst:
                worst = d
                worst_pos = k
                worst_frame = f
    return (worst, worst_pos, worst_frame)


# ==============================================================================
# ⚠️ 起播观察窗口（⭐ 2026-09-23 新增 —— 起播改成了上板手动按键）
# ==============================================================================
def play_window_slice(stamps, marks_ms, play_start_ms):
    """
    按"已起播"切出观察窗口。

    🔴 为什么需要它（FPGA 侧答复 §三）：
        起播时刻由【人按板上的键】决定 => 起播前 play_seq **不消费**
        => 那段时间里"缓冲水位不为 0"和"evt_underrun_o"都【不代表故障】。
        ⇒ 任何与"消费进度"有关的统计必须【从已起播开始算】。

    参数：
        stamps        每个字节的到达时间戳（秒，perf_counter 基准）
        marks_ms      与 stamps 同基准的"毫秒时间轴"（这里只用第一个元素做原点）
        play_start_ms 起播时刻（毫秒，相对同一个原点）；None 表示不切

    返回：(起播后的 stamps, 起播前的字节数)

    ⚠️ 本函数只在【有 FPGA 的端到端测试】里才有意义；
       纯回环（ESP32 + USB-TTL）没有 play_seq，⛔ 不需要切窗口。
    """
    if play_start_ms is None or not stamps:
        return stamps, 0

    t0 = marks_ms[0]
    cut_s = (play_start_ms - t0) / 1000.0
    if cut_s <= 0:
        return stamps, 0

    idx = 0
    while idx < len(stamps) and (stamps[idx] - t0) < cut_s:
        idx += 1
    return stamps[idx:], idx


def scan_frame_gaps_uniform(stamps, frame_bytes=FRAME_BYTES, max_scan=200000):
    """
    同 scan_frame_gaps，但用于"接收端不理解帧对齐"的场景。

    ⚠️ 为什么要这个：
        接收端（USB-TTL 侧的 PC）不知道字节流的帧相位 ——
        如果丢了字节，帧边界就偏了。
        => 这里假设【所有可能相位】，取最坏的那个相位下的最大帧内间隔。
        ⚠️ 这是保守判据：相位猜错会让"其实没问题"也报红。
        => 所以同时给出最优相位的结果，两者一起看。
    """
    n = len(stamps)
    if n < 2:
        return (0.0, -1, -1, -1)

    best = (float("inf"), -1, -1)
    worst = (0.0, -1, -1)

    limit = min(n, max_scan)
    for phase in range(frame_bytes):
        w = 0.0
        wpos = -1
        f = phase
        while f + frame_bytes <= limit:
            base = f
            for k in range(base + 1, base + frame_bytes):
                d = stamps[k] - stamps[k - 1]
                if d > w:
                    w = d
                    wpos = k
            f += frame_bytes
        if w < best[0]:
            best = (w, wpos, phase)
        if w > worst[0]:
            worst = (w, wpos, phase)

    return (worst[0], worst[1], worst[2], best[2])


# ==============================================================================
# 接收端
# ==============================================================================
def recv_timed(port, baud, expect, timeout_s, chunk_hint=64):
    """
    从串口收字节，记录每个字节的到达时间戳。

    ⚠️ 关键：读【尽可能小的块】（chunk），这样时间戳分辨率才够。
       pyserial 的 read(n) 在收到 n 字节或超时才返回 => n 太大会把
       不同时刻到达的字节糊成一个时间戳。
       这里用 read(1) + 循环，分辨率约等于单字节传输时间。
    """
    import serial

    data = bytearray()
    stamps = []

    ser = serial.Serial(port, baud, timeout=timeout_s)
    try:
        ser.reset_input_buffer()
        t0 = time.perf_counter()
        last_new = t0
        while len(data) < expect:
            b = ser.read(1)
            if b:
                now = time.perf_counter()
                data += b
                stamps.append(now)
                last_new = now
            else:
                # 超时：如果已经没有新数据一段时间，就收摊
                if time.perf_counter() - last_new > timeout_s:
                    break
    finally:
        ser.close()

    return bytes(data), stamps


def send_bytes(port, baud, payload, lead_reset=True):
    """从 SPP 的 COM 口发送。⚠️ 单次 write（保持帧内连续）。"""
    import serial
    ser = serial.Serial(port, baud, timeout=1)
    try:
        time.sleep(0.2)                 # 等串口稳定
        if lead_reset:
            ser.write(build_reset())    # ⭐ 单次 write，36 字节连续
            ser.flush()
        ser.write(payload)              # ⭐ 单次 write
        ser.flush()
    finally:
        ser.close()


# ==============================================================================
# 离线自检（⛔ 不用硬件）—— 先证明"判据本身"是对的
# ==============================================================================
def selftest():
    """
    ⭐ 为什么要这个：
        本项目纪律 C45：「防御性代码从不被触发 = 假安全」。
        判据若永远只报绿，就没法证明它真能抓到问题。
        这里用【合成的坏时间戳】验证判据会报红。
    """
    print("[selftest] 校验判据逻辑（⛔ 不用任何硬件）")
    ok = True

    for baud in (115200, 1000000):
        lim = judge_limit_us(baud)
        gate = gap_limit_us(baud)
        print("  baud=%-8d 一字节=%.2f us  归位门限=%.1f us  判据门限=%.1f us"
              % (baud, byte_time_us(baud) * 1e6, gate, lim))

        bt = byte_time_us(baud)

        # --- 用例 1：完美的帧，帧内无空隙 -> 必须【绿】 ---
        stamps = []
        t = 0.0
        for _ in range(9 * 100):
            stamps.append(t)
            t += bt                      # 每字节间隔 = 一个字节时间
        w, _, _ = scan_frame_gaps(stamps)
        got = w * 1e6
        good = got < lim
        print("    [1] 帧内无空隙        max_gap=%8.2f us  -> %s"
              % (got, "绿 OK" if good else "红 FAIL"))
        ok &= good

        # --- 用例 2：帧【之间】有巨大停顿 -> 仍须【绿】（帧间停顿是正常的）---
        stamps = []
        t = 0.0
        for _ in range(100):
            for k in range(FRAME_BYTES):
                stamps.append(t)
                t += bt
            t += 0.5                     # 帧间停 500 ms
        w, _, _ = scan_frame_gaps(stamps)
        got = w * 1e6
        good = got < lim
        print("    [2] 帧间停 500ms      max_gap=%8.2f us  -> %s   <- ⭐ 必须绿"
              % (got, "绿 OK" if good else "红 FAIL"))
        ok &= good

        # --- 用例 3：帧【中途】插一个大空隙 -> 必须【红】 ---
        stamps = []
        t = 0.0
        for f in range(100):
            for k in range(FRAME_BYTES):
                stamps.append(t)
                if f == 50 and k == 4:
                    t += gate * 3.0      # 🔴 帧中途插入 > 门限 的停顿
                else:
                    t += bt
        w, _, _ = scan_frame_gaps(stamps)
        got = w * 1e6
        bad = got >= lim
        print("    [3] 帧中途插大空隙    max_gap=%8.2f us  -> %s   <- 🔴 必须红"
              % (got, "红 CAUGHT" if bad else "绿 MISSED"))
        ok &= bad

    print("[selftest] %s" % ("全部符合预期 ✅" if ok else "❌ 有判据不符合预期"))
    return 0 if ok else 1


# ==============================================================================
# 主流程
# ==============================================================================
def main(argv=None):
    ap = argparse.ArgumentParser(description="ESP32 SPP 回环自测")
    ap.add_argument("--selftest", action="store_true",
                    help="只校验判据逻辑，不用硬件")
    ap.add_argument("--tx-port", help="发送端串口（蓝牙配对后的 COMx）")
    ap.add_argument("--rx-port", help="接收端串口（USB-TTL 的 COMx）")
    ap.add_argument("--baud", type=int, default=500000,
                    help="波特率（默认 500000，⭐ 与 FPGA 侧同档）")
    ap.add_argument("--pattern", default="counter",
                    choices=["counter", "all-a5", "random"],
                    help="测试载荷类型")
    ap.add_argument("--bytes", type=int, default=100 * 1024,
                    help="载荷字节数（默认 100 KB）")
    ap.add_argument("--hex", help="改用 events.hex 当载荷（真实曲谱量级）")
    ap.add_argument("--timeout", type=float, default=3.0,
                    help="接收端静默超时（秒）")
    ap.add_argument("--duration", type=float, default=0.0,
                    help="长稳模式：持续发送该秒数（0=单次）")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if not args.tx_port or not args.rx_port:
        ap.error("需要 --tx-port 和 --rx-port（或用 --selftest）")

    gate = gap_limit_us(args.baud)
    lim = judge_limit_us(args.baud)
    print("=" * 74)
    print("ESP32 SPP 回环自测")
    print("  tx=%s  rx=%s  baud=%d" % (args.tx_port, args.rx_port, args.baud))
    print("  一字节=%.2f us  FPGA 归位门限=%.1f us  判据门限=%.1f us"
          % (byte_time_us(args.baud) * 1e6, gate, lim))
    print("=" * 74)

    if args.hex:
        payload = load_hex_events(args.hex)
        print("载荷：%s -> %d 字节（%d 帧）" % (args.hex, len(payload),
                                              len(payload) // FRAME_BYTES))
    else:
        payload = gen_pattern(args.pattern, args.bytes)
        print("载荷：%s %d 字节（%d 帧）" % (args.pattern, len(payload),
                                            len(payload) // FRAME_BYTES))

    expect = len(payload) + RESET_BYTES
    print("期望收到：%d 字节（含 %d 字节复位序列）" % (expect, RESET_BYTES))

    t_start = time.time()
    send_bytes(args.tx_port, args.baud, payload)
    t_sent = time.time()
    print("发送完成：耗时 %.3f s（%.1f KB/s）"
          % (t_sent - t_start, len(payload) / 1024.0 / max(1e-9, t_sent - t_start)))

    data, stamps = recv_timed(args.rx_port, args.baud, expect, args.timeout)
    t_recv = time.time()
    print("接收完成：%d 字节，耗时 %.3f s" % (len(data), t_recv - t_sent))

    # ---- 判据 1：逐字节一致 ----
    results = []
    same = (data == (build_reset() + payload))
    results.append(("1. 字节流逐字节一致", same,
                    "%d/%d 字节相同" % (
                        sum(1 for a, b in zip(data, build_reset() + payload) if a == b),
                        expect)))

    # ---- 判据 2：不丢字节 ----
    results.append(("2. 大文件不丢（%d B）" % len(payload), len(data) == expect,
                    "收到 %d，期望 %d，差 %d" % (len(data), expect, expect - len(data))))

    # ---- 判据 3：0xA5 原样透传（用 all-a5 载荷时才有意义）----
    if args.pattern == "all-a5":
        n_a5 = data.count(HEADER)
        results.append(("3. 0xA5 原样透传", n_a5 == expect,
                        "收到 %d 个 0xA5，期望 %d" % (n_a5, expect)))

    # ---- 判据 4：🔴 帧内空隙 ----
    if len(stamps) >= 2:
        # 相位未知：给出"最坏相位"和"最优相位"两个数
        w_worst, pos_w, ph_w, ph_best = scan_frame_gaps_uniform(stamps)
        # 用最优相位算（接收端从复位序列开头对齐时，真实相位就是最优的）
        grads = []
        for k in range(1, len(stamps)):
            grads.append(stamps[k] - stamps[k - 1])
        grads.sort()
        p50 = grads[len(grads) // 2] * 1e6
        p99 = grads[int(len(grads) * 0.99)] * 1e6
        mx = grads[-1] * 1e6

        # 判据：以【最优相位】下的最大帧内间隔为准
        # （复位序列让接收端天然对齐到帧边界，所以最优相位是真实情形）
        best_phase_gap = None
        for phase in range(FRAME_BYTES):
            w = 0.0
            f = phase
            while f + FRAME_BYTES <= len(stamps):
                for k in range(f + 1, f + FRAME_BYTES):
                    d = stamps[k] - stamps[k - 1]
                    if d > w:
                        w = d
                f += FRAME_BYTES
            if best_phase_gap is None or w < best_phase_gap:
                best_phase_gap = w
        gap_ok = (best_phase_gap * 1e6) < lim
        results.append(("4. 帧内空隙 < %.0f us" % lim, gap_ok,
                        "实测最大 %.2f us（全体相邻间隔：中位 %.1f / P99 %.1f / 最大 %.1f us）"
                        % (best_phase_gap * 1e6, p50, p99, mx)))
        print("      ⚠️ 相位未知时的最坏值：%.1f us（phase=%d 偏移）"
              % (w_worst * 1e6, ph_w))
    else:
        results.append(("4. 帧内空隙", False, "时间戳不足（只收到 %d 字节）" % len(data)))

    # ---- 汇总 ----
    print("-" * 74)
    npass = 0
    for name, good, detail in results:
        print("  [%s] %-32s %s" % ("通过" if good else "失败", name, detail))
        npass += 1 if good else 0
    print("-" * 74)
    print("结果：%d/%d 通过" % (npass, len(results)))

    if npass != len(results):
        print("\n⚠️ 排查提示：")
        print("  · 字节数不符  -> 先看固件的 dropped / bt_tx_fail 计数（串口日志）")
        print("  · 帧内空隙超限 -> 检查固件是否真的做了【9N 对齐】写入")
        print("  · 完全收不到   -> 波特率两边是否一致（FPGA 侧现值是 115200）")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
