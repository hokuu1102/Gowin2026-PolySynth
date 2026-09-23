#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""evt2uart.py -- 把 events.hex 封成串口帧，按谱子时间限速发给 FPGA。

═══════════════════════════════════════════════════════════════════════════════
⭐ 它解决什么问题
═══════════════════════════════════════════════════════════════════════════════
  `mid2evt.py` 产出的是 **events.hex**（一条行一个 64 bit 事件）。
  ⚠️ 但 FPGA 那边的 `evt_uart_rx.v` 要的是**串口字节流**，
  而且 ⭐ **必须按谱子的真实时间节流** ——
  ⛔ 不能一次全灌进去（FPGA 缓冲区只有 2 KB）。

  ⇒ 本工具 = **打包 + 限速**。

═══════════════════════════════════════════════════════════════════════════════
⭐⭐ 帧格式（与 `rtl/w3c/evt_uart_rx.v` 严格对应）
═══════════════════════════════════════════════════════════════════════════════
    每帧 9 字节：
      byte 0     : 0xA5          帧头
      byte 1..8  : 64 bit 事件   **大端**（与 events.hex 一致）

⭐⭐ 同步方案：**⛔ 不做任意位置扫描**
  ⭐ FPGA 侧**只在"第 0 字节位置"看帧头** ⇒ ⭐ **误同步原理上不可能**。
  ⚠️ 代价：**失步后必须由 PC 重发复位序列**，⛔ FPGA 不会自己猜。

  ⇒ ⭐ 本工具的三条硬约束（⚠️ 违反任何一条都会静默出错）：

  **① 复位序列长度必须是【9 的整数倍】**
     ⭐ FPGA 把"9 个字节全是 0xA5"的帧当成复位标记**整帧抑制**。
     · 发 `9N` 个 ⇒ ⭐ 整帧整帧被抑制，位置干净 ✅
     · 发 `9N+3` 个 ⇒ 🔴 残留 3 字节把位置推到 3
       ⇒ ⚠️ 之后真正的帧会被当成帧内数据吞掉
     ⇒ ⭐ `RESET_FRAMES * 9`，代码里写死。

  **② 一帧的 9 字节必须【连续发】（⛔ 中间不能长时间停顿）**
     ⭐ FPGA 有"空闲归位"：静默超过 `GAP_BYTES` 个字节时间就强制回到位置 0。
     ⭐ 单次 `write()` 保证连续。
     ⚠️ 若整条流被 PC 拆散（例如每字节 sleep），会**触发归位 ⇒ 帧被截断**。

  **③ ⛔ 绝不生成"全 0xA5 的事件"**
     ⚠️ 那会被 FPGA 当成复位帧**抑制掉**（⭐ 事件静默消失）。
     ⭐ 本工具发送前**断言拦截**。

═══════════════════════════════════════════════════════════════════════════════
⭐ 限速策略（⚠️ 没有反向通道，只能"盲发 + 保守提前量"）
═══════════════════════════════════════════════════════════════════════════════
  🔴 **FPGA 不会告诉 PC 它的缓冲区水位**（本版不做反向流控）。
  ⇒ ⭐ PC 只能**按自己的时钟估算 FPGA 的播放位置**，并保持一个**提前量**：
       发送时刻 = 事件应在的墙钟时刻 − 提前量
  ⭐ 提前量默认 **8 拍**（对应设计文档的"滚动预灌"）。
  ⚠️ **PC 守时不好就会饿死 FPGA** —— 那时 FPGA 的 `evt_underrun_o` 会亮
     （⭐ 这是本版唯一的反馈手段）。

═══════════════════════════════════════════════════════════════════════════════
⚠️ 实测带宽（说明"事件很少"这个直觉是错的）
═══════════════════════════════════════════════════════════════════════════════
  ⭐ 三个真实谱子：平均 **13~25 条事件/拍**，最坏 8 拍窗口 **283~504 条**
  ⇒ ⭐ 平均负载 **750 B/s ≈ 115200 的 6.5%**
  ⇒ ⭐ **帧开销（12.5%）完全不是瓶颈**；🔴 真正的瓶颈是**FPGA 侧缓冲深度**。

用法：
    # ⭐ 不接硬件也能跑：解包自检 + 统计（默认行为）
    python tools/evt2uart.py build/score/regen/09_Conjurer/events.hex --dry-run

    # 真发（需要 pyserial）
    python tools/evt2uart.py <events.hex> --port COM7 --bpm 120
"""

import argparse
import io
import os
import sys
import time

# ── ⭐ 与 RTL 严格对应的常量 ────────────────────────────────────────────────
HEADER = 0xA5
FRAME_BYTES = 9                 # 1 帧头 + 8 数据
RESET_FRAMES = 4                # ⭐ 复位序列 = 4 帧 = 36 字节（⭐ 9 的整数倍）
PPQN = 960                      # ⭐ 与 beat_gen 一致


# ══════════════════════════════════════════════════════════════════════════════
# 打包 / 解包
# ══════════════════════════════════════════════════════════════════════════════
def pack_frame(word):
    """64 bit 事件 -> 9 字节帧（⭐ 大端）。

    ⚠️ 断言拦截"全 0xA5 帧" —— 那会被 FPGA 当成复位标记抑制掉（⭐ 事件静默消失）。
    """
    if not (0 <= word < (1 << 64)):
        raise ValueError("event out of 64-bit range: %r" % (word,))
    body = word.to_bytes(8, "big")          # ⭐ 大端，与 events.hex 一致
    frame = bytes([HEADER]) + body
    if frame == bytes([HEADER]) * FRAME_BYTES:
        # 🔴 9/9 全 0xA5 = 复位标记 ⇒ 会被抑制
        raise ValueError(
            "event 0x%016X would form an all-0xA5 frame and be SWALLOWED as a "
            "reset marker; the event format reserves that pattern" % word)
    return frame


def unpack_stream(data):
    """⭐ 纯 Python 复刻 `evt_uart_rx.v` 的解析逻辑（用于离线自检）。

    ⚠️ 这是"如果没有硬件也能验证"的关键：
       它按**和 RTL 一样的状态机**走，所以能验证字节流是自洽的。

    返回 (events, stats)
    """
    idx = 0
    shift = 0
    all_a5 = False
    events = []
    stats = {"frames": 0, "dropped": 0, "hdr_err": 0, "resync": 0}
    for b in data:
        if idx == 0:
            # ⭐ 只在第 0 字节位置看帧头（⛔ 不扫描）
            if b == HEADER:
                idx = 1
                all_a5 = True
                shift = 0
            else:
                stats["hdr_err"] += 1
        else:
            shift = ((shift << 8) | b) & 0xFFFFFFFFFFFFFFFF
            all_a5 = all_a5 and (b == HEADER)
            if idx == 8:
                idx = 0
                if all_a5:
                    stats["dropped"] += 1
                else:
                    events.append(shift)
                    stats["frames"] += 1
            else:
                idx += 1
    if idx != 0:
        stats["resync"] += 1          # ⭐ 尾部半帧（相当于空闲归位）
    return events, stats


# ══════════════════════════════════════════════════════════════════════════════
# 读谱子
# ══════════════════════════════════════════════════════════════════════════════
def read_hex(path):
    """读 events.hex（⭐ 每行 16 个 hex 字符 = 64 bit）。"""
    out = []
    with io.open(path, "r", encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if len(s) != 16:
                raise ValueError("%s:%d: expected 16 hex chars, got %d"
                                 % (path, ln, len(s)))
            out.append(int(s, 16))
    return out


def tick_of(word):
    """事件里的 tick 字段（⭐ 位域与 RTL / mid2evt.py 一致）。"""
    return (word >> 44) & 0xFFFFF          # tick[63:44] = 20 bit


def is_tempo(word):
    """kind == 2（换速）。"""
    return ((word >> 9) & 0x3) == 2


# ══════════════════════════════════════════════════════════════════════════════
# 发送
# ══════════════════════════════════════════════════════════════════════════════
def build_reset():
    """⭐ 复位序列：`RESET_FRAMES` 帧全 0xA5。

    ⚠️ **长度必须是 9 的整数倍** —— 见模块头"硬约束 ①"。
    """
    return bytes([HEADER]) * (FRAME_BYTES * RESET_FRAMES)


def send_stream(events, port=None, baud=115200, bpm=120.0, lead_beats=8.0,
                dry_run=True, verbose=True):
    """把事件流打包装帧并按谱子时间限速发送。

    ⭐ 限速：`发送时刻 = 事件应在的墙钟时刻 − 提前量`
    """
    ticks_per_sec = (bpm / 60.0) * PPQN
    lead_s = lead_beats * (60.0 / bpm)          # ⭐ 提前量（秒）

    stats = {"events": 0, "bytes": 0, "waited_s": 0.0,
             "max_late_s": 0.0, "late_events": 0}

    ser = None
    if not dry_run:
        try:
            import serial                       # noqa: F401
        except ImportError:
            raise SystemExit(
                "pyserial not installed. Use --dry-run, or:  pip install pyserial")
        import serial
        ser = serial.Serial(port, baud, timeout=1)
        time.sleep(0.2)                         # ⭐ 等串口稳定

    t0 = time.time()
    try:
        if ser is not None:
            # ⭐ 单次 write ⇒ 保证复位序列连续（⛔ 不拆散）
            ser.write(build_reset())
            ser.flush()
        stats["bytes"] += len(build_reset())

        for i, w in enumerate(events):
            frame = pack_frame(w)               # ⚠️ 会拦截全 0xA5 事件
            # ⭐ 该事件"应该在"的墙钟时刻（相对 t0）
            due_s = tick_of(w) / ticks_per_sec
            target = t0 + due_s - lead_s
            now = time.time()
            if target > now:
                dt = target - now
                stats["waited_s"] += dt
                if verbose and i % 200 == 0:
                    sys.stderr.write(
                        "\r  sent %6d/%d  (%.1fs ahead)      " % (i, len(events), lead_s))
                    sys.stderr.flush()
                time.sleep(dt)
            else:
                # ⚠️ 已经晚了 ⇒ 只能立刻发（⭐ 记下来，用于判断"PC 守时够不够"）
                late = now - target
                stats["max_late_s"] = max(stats["max_late_s"], late)
                if late > 0.05:
                    stats["late_events"] += 1
            if ser is not None:
                ser.write(frame)                # ⭐ 单次 write ⇒ 帧内 9 字节连续
                ser.flush()
            stats["events"] += 1
            stats["bytes"] += len(frame)
    finally:
        if verbose and stats["events"]:
            sys.stderr.write("\r" + " " * 60 + "\r")
        if ser is not None:
            ser.close()
    return stats


# ══════════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════════
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Wrap events.hex into 9-byte UART frames and stream them "
                    "to the FPGA at score time.")
    ap.add_argument("input", help="events.hex produced by mid2evt.py")
    ap.add_argument("--port", default=None,
                    help="serial port, e.g. COM7 (omit for --dry-run)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--bpm", type=float, default=120.0,
                    help="initial tempo, used for the rate estimate")
    ap.add_argument("--lead-beats", type=float, default=8.0,
                    help="how far ahead of the score to stay (default 8 beats)")
    ap.add_argument("--dry-run", action="store_true",
                    help="build the whole stream, self-check it, send nothing")
    ap.add_argument("--limit", type=int, default=0,
                    help="only process the first N events (0 = all)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit("no such file: %s" % args.input)

    events = read_hex(args.input)
    if args.limit:
        events = events[:args.limit]
    if not events:
        raise SystemExit("no events in %s" % args.input)

    # ⭐ 先整条流打包（⛔ 不边算边发）—— 这样任何"全 0xA5 事件"都会在
    #    发出去之前就暴露，⛔ 不会发到一半才炸
    try:
        stream = b"".join(pack_frame(w) for w in events)
    except ValueError as e:
        raise SystemExit("REFUSING to send: %s" % e)

    reset = build_reset()
    assert len(reset) % FRAME_BYTES == 0, "reset sequence must be a multiple of 9"

    # ⭐⭐ 离线自检：用纯 Python 复刻的解析器把字节流解回来
    #    ⚠️ 这在没有硬件时就是"端到端验证"
    back, pstats = unpack_stream(reset + stream)
    ok = (back == events)

    print("=" * 66)
    print("evt2uart")
    print("=" * 66)
    print("  input        : %s" % args.input)
    print("  events       : %d" % len(events))
    print("  reset seq    : %d bytes (%d frames of 0xA5, multiple of 9: %s)"
          % (len(reset), RESET_FRAMES, len(reset) % 9 == 0))
    print("  wire bytes   : %d  (%.1f%% overhead over 8/e event)"
          % (len(stream), 100.0 * (9 - 8) / 8.0))
    print("  tick range   : %d .. %d" % (min(tick_of(w) for w in events),
                                          max(tick_of(w) for w in events)))
    print()
    print("  -- offline round-trip (python model of evt_uart_rx) --")
    print("     parse frames : %d" % pstats["frames"])
    print("     reset dropped: %d" % pstats["dropped"])
    print("     header errors: %d" % pstats["hdr_err"])
    print("     round-trip   : %s" % ("EXACT MATCH" if ok else "MISMATCH!!"))
    if not ok:
        for i, (a, b) in enumerate(zip(events, back)):
            if a != b:
                print("       first diff at %d: %016X != %016X" % (i, a, b))
                break
        print("       (lengths %d vs %d)" % (len(events), len(back)))
        return 2

    # ⭐ 带宽估算（⚠️ 用实测密度说话，⛔ 不靠"事件很少"的直觉）
    span_s = max(tick_of(w) for w in events) / ((args.bpm / 60.0) * PPQN)
    if span_s > 0:
        bps = len(stream) / span_s
        cap = args.baud / 10.0
        print()
        print("  -- bandwidth --")
        print("     score span   : %.1f s @ %g BPM" % (span_s, args.bpm))
        print("     average need : %.0f B/s  = %.1f%% of %d baud"
              % (bps, 100.0 * bps / cap, args.baud))

    if args.dry_run or not args.port:
        print()
        print("  DRY RUN -- nothing was sent.  (pass --port COMx to really send)")
        print("=" * 66)
        return 0

    print()
    print("  sending on %s @ %d baud, lead %.1f beats ..."
          % (args.port, args.baud, args.lead_beats))
    st = send_stream(events, port=args.port, baud=args.baud, bpm=args.bpm,
                     lead_beats=args.lead_beats, dry_run=False)
    print("  sent %d events, %d bytes, waited %.1fs total"
          % (st["events"], st["bytes"], st["waited_s"]))
    if st["late_events"]:
        print("  !! %d event(s) were sent LATE (max %.0f ms) -- "
              "the FPGA may have starved (check evt_underrun_o)"
              % (st["late_events"], st["max_late_s"] * 1000))
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
