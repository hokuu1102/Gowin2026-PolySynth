#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_lead_probe.py —— ⭐ 实测「起播提前量」到底多长

═══ 为什么需要 ═══
⚠️ 上屏演示里，本曲谱面只有 **2.5 秒**，⭐ 但我等了 **5.5 秒**读回仍是 `播放中`
⇒ 🔴 **说明起播到"第一帧真的出去"之间有一段提前量**。
⭐ 这段提前量**决定**：⭐ 屏上 `播完` 什么时候出现、⭐ 以及"等多久才判定超时"。

═══ 怎么测 ═══
⭐ 起播后**每秒读一次 `t1`**，⭐ 打出「⭐ 第几秒 → 什么状态」的**时间线**
⇒ ⭐ 从"播放中"翻到"播完"的那一刻，⭐ 就是**实测提前量 + 谱面时长**。

═══ 判据 ═══
  · ⭐ 若 `播完` 出现在 (谱面时长 + 提前量) 附近 ⇒ ⭐ 提前量 = 实测值 − 谱面时长
  · 🔴 若一直不翻 ⇒ ⭐ 那不是提前量问题，⭐ 是"放完事件"没上来（⭐ 另查）
"""

import asyncio
import re
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import serial
from bleak import BleakClient, BleakScanner

CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
FRAME = 9
DEV = "FPGA2026-Synth"
LOG_PORT = "COM29"
RX_RE = re.compile(r"screen -> ESP32: \d+ B .*?\[([0-9A-Fa-f ]+)\]")
TICK_PER_S = 1920.0            # ⭐ 120 BPM / PPQN 960


def build_score(events, step):
    out = bytearray(bytes([0xA5]) * (FRAME * 4))
    out += bytes([0x00]) + struct.pack(">Q", events)
    for i in range(events):
        tick = i * step
        inc = 164927                                   # ⭐ 随便一个固定音高
        word = ((tick & 0xFFFFF) << 44) | ((inc & 0x3FFFFF) << 22) | \
               ((0 & 0xF) << 18) | ((90 & 0x7F) << 11)
        out += bytes([0xA5]) + word.to_bytes(8, "big")
    return bytes(out)


async def main(events, step, poll_s):
    ser = serial.Serial()
    ser.port = LOG_PORT
    ser.baudrate = 115200
    ser.timeout = 0.05
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.setDTR(False)
    ser.setRTS(False)
    ser.reset_input_buffer()
    buf = bytearray()

    def pump():
        try:
            n = ser.in_waiting
            if n:
                buf.extend(ser.read(n))
        except Exception:
            pass

    def replies():
        out = []
        for m in RX_RE.finditer(buf.decode("utf-8", "replace")):
            try:
                out.append(bytes(int(x, 16) for x in m.group(1).split()))
            except ValueError:
                pass
        return out

    async def get_t1(c):
        pump()
        before = len(replies())
        await c.write_gatt_char(CMD, bytes([0x21]) + b"get t1.txt", response=False)
        acc = bytearray()
        t0 = asyncio.get_event_loop().time()
        while asyncio.get_event_loop().time() - t0 < 2.0:
            pump()
            r = replies()
            for ch in r[before:]:
                acc.extend(ch)
                if acc.endswith(b"\xff\xff\xff"):
                    b = bytes(acc[:-3])
                    if b[:1] == b"p":
                        b = b[1:]
                    return b.decode("utf-8", "replace")
            before = len(r)
            await asyncio.sleep(0.1)
        return "(无回包)"

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=12)
    if dev is None:
        print("🔴 没找到设备")
        ser.close()
        return 3

    last_tick = (events - 1) * step
    score_s = last_tick / TICK_PER_S
    print("=" * 74)
    print("起播提前量实测")
    print("  事件数 %d · 每事件 %d tick ⇒ 末帧 tick=%d ⇒ 谱面时长 %.2f s"
          % (events, step, last_tick, score_s))
    print("=" * 74)

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.2)
        # ⭐ 复位 + 灌谱
        for _ in range(3):
            await c.write_gatt_char(CMD, bytes([0x01]), response=False)
            await asyncio.sleep(1.2)
            if await get_t1(c) == "待机":
                break
        payload = build_score(events, step)
        off = 0
        while off < len(payload):
            n = min(180, len(payload) - off)
            await c.write_gatt_char(RECV, payload[off:off + n], response=False)
            off += n
            await asyncio.sleep(0.003)
        await asyncio.sleep(2.0)
        print("  灌完时 t1 = %r" % await get_t1(c))

        # ⭐ 起播并开始秒表
        t0 = asyncio.get_event_loop().time()
        await c.write_gatt_char(CMD, bytes([0x03]), response=False)
        print("  >>> 起播（t=0）")
        print()
        print("  %-8s %-10s %s" % ("时刻(s)", "t1", "备注"))
        print("  " + "-" * 52)

        done_at = None
        for k in range(int(poll_s)):
            await asyncio.sleep(1.0)
            el = asyncio.get_event_loop().time() - t0
            st = await get_t1(c)
            note = ""
            if st == "播完" and done_at is None:
                done_at = el
                note = "⭐ 翻到播完"
            elif st != "播放中" and st != "播完":
                note = "⚠️ 非预期"
            print("  %-8.1f %-10s %s" % (el, st, note))
            if done_at is not None and el > done_at + 2:
                break

        print()
        if done_at is None:
            print("  🔴 %.0f 秒内**始终没**翻到 `播完` ⇒ ⚠️ 不是提前量问题" % poll_s)
        else:
            print("  ⭐ 翻到 `播完` 的实测时刻 = %.1f s" % done_at)
            print("  ⭐ 谱面时长            = %.2f s" % score_s)
            print("  ⇒ ⭐ **实测提前量 ≈ %.1f s**" % max(0.0, done_at - score_s))

    ser.close()
    return 0


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--step", type=int, default=24, help="每事件多少 tick")
    ap.add_argument("--poll", type=float, default=40.0)
    a = ap.parse_args()
    sys.exit(asyncio.run(main(a.events, a.step, a.poll)))
