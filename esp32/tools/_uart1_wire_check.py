"""一次性：PC 用 USB-TTL 伪装 FPGA，接收 ESP32 从 UART1 发出来的帧，逐字节校验。

为什么要做这个（而不是只看 STAT 的 sent=）
----------------------------------------------------------------------------
`sent=11865` 只证明 `uart_write_bytes()` 每次都返回了 9。
它【不证明】线上那 9 个字节是对的 —— 而位域刚修过（2026-10-01），
所以必须看真实线上的字节。
同族教训：L113（判据锚在中间状态 => 下游缺陷在回归里完全不可见）。

它验什么
----------------------------------------------------------------------------
1. ESP32 播放时，UART1(GPIO17) 上真的有没有字节出来；
2. 出来的帧是不是【9 字节、帧头 0xA5】；
3. 载荷是不是与发进去的 events【逐帧逐字节一致】；
4. 有没有多出来的 / 缺掉的 / 错位的帧。

接线前提
----------------------------------------------------------------------------
USB-TTL 的 RX 必须接 ESP32 的 GPIO17（UART1 TX），GND 共地。
USB-TTL 的 DTR/RTS 一律先压住（U86：open() 这个动作本身可能拉 DTR/RTS）。

用法
----------------------------------------------------------------------------
    python _uart1_wire_check.py --port COM31 --events 200 --seconds 25
"""
import argparse
import asyncio
import os
import sys
import time

import serial
from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import score_word as SW          # noqa: E402

UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
LOG_PORT = "COM29"


def fake_song(n_events):
    """与 send_frames_ble.py 的 fake_song 完全同参（这里独立重算，便于比对）。"""
    NOTE_INC = 164927
    out = []
    for i in range(n_events):
        out.append(SW.pack_word(tick=1000 + i * 37, inc=NOTE_INC,
                                axis=i % 16, vel=60 + (i % 60),
                                kind=i % 2, timbre=i % 2))
    return out


def open_quiet(port, baud):
    """打开串口，且在 open() 之前就把 DTR/RTS 压住（U86）。"""
    s = serial.Serial()
    s.port = port
    s.baudrate = baud
    s.timeout = 0.1
    s.dtr = False
    s.rts = False
    s.open()
    s.setDTR(False)
    s.setRTS(False)
    s.reset_input_buffer()
    return s


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM31", help="USB-TTL 的口（默认 COM31）")
    ap.add_argument("--baud", type=int, default=500000)
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--hex", default=None,
                    help="真谱面：读 mid2evt.py 产出的 events.hex（⛔ 与 --events 二选一）")
    ap.add_argument("--seconds", type=float, default=25.0)
    args = ap.parse_args()

    if args.hex:
        expect, problems = SW.load_events_hex(args.hex)
        print("谱面：%s（%d 事件）" % (os.path.basename(args.hex), len(expect)))
        if problems:
            print("!! events.hex 有 %d 个问题" % len(problems))
    else:
        expect = fake_song(args.events)
    print("期望：%d 帧事件（每帧 9 字节，帧头 0xA5）" % len(expect))
    print("      首帧 tick=%d inc=%d kind=%d"
          % (SW.unpack_word(expect[0])["tick"],
             SW.unpack_word(expect[0])["inc"],
             SW.unpack_word(expect[0])["kind"]))
    print("      末帧 tick=%d"
          % SW.unpack_word(expect[-1])["tick"])
    print()

    print(">>> 打开 %s @ %d（DTR/RTS 已压住）" % (args.port, args.baud))
    try:
        cap = open_quiet(args.port, args.baud)
    except Exception as e:
        print("RED: 打不开 %s：%s" % (args.port, e))
        return 2
    print("    已打开")

    lg = open_quiet(LOG_PORT, 115200)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        return 1

    raw = bytearray()
    rc = 0
    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)

        print(">>> CMD 0x01 清池")
        await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
        await asyncio.sleep(1.0)

        payload = SW.reset_sequence() + SW.frame_total(len(expect)) + b"".join(
            SW.frame_from_word(w) for w in expect)
        print(">>> 灌 %d 字节" % len(payload))
        sent = 0
        t0 = time.time()
        while sent < len(payload):
            n = min(180, len(payload) - sent)
            await c.write_gatt_char(UUID_RECV, payload[sent:sent + n],
                                    response=False)
            sent += n
            await asyncio.sleep(0.005)
        print("    发完 %.1f s" % (time.time() - t0))
        await asyncio.sleep(1.0)

        # 抓包要在起播【之前】就开始
        print(">>> 开始抓 %s，然后 CMD 0x03 起播" % args.port)
        await c.write_gatt_char(UUID_CMD, bytes([0x03]), response=False)

        t1 = time.time()
        while time.time() - t1 < args.seconds:
            n = cap.in_waiting
            if n:
                raw.extend(cap.read(n))
            await asyncio.sleep(0.02)
        print("    抓到 %d 字节，用时 %.1f s" % (len(raw), time.time() - t1))

    cap.close()
    lg.close()

    # ---- 逐帧逐字节比对 ----
    print()
    print("=" * 66)
    print("逐帧比对")
    print("=" * 66)
    bad_hdr = 0
    frames = []
    for off in range(0, len(raw) - 8, 9):
        fr = bytes(raw[off:off + 9])
        if fr[0] != SW.HDR_EVENT:
            bad_hdr += 1
            continue
        frames.append(fr)
    print("抓到字节 = %d（%.2f 帧）" % (len(raw), len(raw) / 9.0))
    print("帧头非 0xA5 的位置 = %d" % bad_hdr)
    print("可用事件帧 = %d（期望 %d）" % (len(frames), len(expect)))

    n_cmp = min(len(frames), len(expect))
    first_bad = None
    for i in range(n_cmp):
        if frames[i][1:] != SW.frame_from_word(expect[i])[1:]:
            first_bad = i
            break
    if first_bad is None:
        print("前 %d 帧载荷【逐字节一致】" % n_cmp)
    else:
        print("RED: 第 %d 帧不一致" % first_bad)
        print("   期望 %s" % SW.frame_from_word(expect[first_bad]).hex(" ").upper())
        print("   实测 %s" % frames[first_bad].hex(" ").upper())

    # ---- 结论 ----
    print()
    ok = True
    if len(raw) == 0:
        print("RED  => 一个字节都没收到 => USB-TTL 的 RX 没接到 GPIO17，或没共地")
        rc, ok = 3, False
    elif bad_hdr:
        print("RED  => 有 %d 处帧头不是 0xA5 => 流被污染 / 波特率不对" % bad_hdr)
        rc, ok = 4, False
    elif len(frames) != len(expect):
        print("RED  => 帧数 %d != 期望 %d" % (len(frames), len(expect)))
        rc, ok = 5, False
    elif first_bad is not None:
        print("RED  => 载荷不一致（见上）")
        rc, ok = 6, False
    else:
        print("OK   => 线上 %d 帧与灌进去的 events【逐字节一致】" % len(frames))
        print("        => ESP32 的 UART1 出口这一段【已验】，不再是只看 sent 计数")
    return rc


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
