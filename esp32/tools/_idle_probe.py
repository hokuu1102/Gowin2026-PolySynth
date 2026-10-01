"""⭐ 定位「复位后屏上仍是 `断链`」—— ⭐ 一次分开三种可能。

═══ 三种可能（⭐ 必须用证据区分，⛔ 不许猜）═══
  (a) 🔴 **命令没到处理函数** —— CMD `0x01` 没进 `start_action_reset()`
  (b) 🔴 **值设了但屏没重绘** —— ⭐ 同 `C139`（⭐ 再读一次应该变对）
  (c) 🔴 **有东西把状态又打回 `LINK_LOST`** —— ⭐ 连接/断开的回调顺序问题

═══ 判据 ═══
  | 日志里有 "RESET requested"? | 第 2 次读 | ⇒ 结论 |
  |---|---|---|
  | ⛔ 没有 | 任意 | ⭐ (a) 命令没到 |
  | ✅ 有 | ⭐ 变 `待机` | ⭐ (b) 重绘延迟（⭐ 多读几次就好） |
  | ✅ 有 | ⚠️ 仍 `断链` | ⭐ (c) 被别的路径打回去了 |

⭐ 同时把 ESP32 日志抓下来，⭐ 直接看固件自己怎么说的。
"""

import asyncio
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import serial
from bleak import BleakClient, BleakScanner

CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
LOG_PORT = "COM29"
DEV = "FPGA2026-Synth"
RX_RE = re.compile(r"screen -> ESP32: \d+ B .*?\[([0-9A-Fa-f ]+)\]")


class Log:
    def __init__(self, ser):
        self.ser = ser
        self.buf = bytearray()

    def pump(self):
        try:
            n = self.ser.in_waiting
            if n:
                self.buf.extend(self.ser.read(n))
        except Exception:
            pass

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def replies(self):
        out = []
        for m in RX_RE.finditer(self.text()):
            try:
                out.append(bytes(int(x, 16) for x in m.group(1).split()))
            except ValueError:
                pass
        return out


async def main():
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
    lg = Log(ser)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=12)
    if dev is None:
        print("RED: not advertising")
        return 1

    async def get_t1(c, lg):
        before = len(lg.replies())
        await c.write_gatt_char(CMD, bytes([0x21]) + b"get t1.txt", response=False)
        t0 = asyncio.get_event_loop().time()
        while asyncio.get_event_loop().time() - t0 < 2.0:
            lg.pump()
            r = lg.replies()
            if len(r) > before:
                b = r[-1]
                if b.endswith(b"\xff\xff\xff"):
                    b = b[:-3]
                if b[:1] == b"p":
                    b = b[1:]
                return b.decode("utf-8", "replace")
            await asyncio.sleep(0.1)
        return "(无回包)"

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.2)
        print("① 刚连接时          t1 =", await get_t1(c, lg))

        print("② 发 CMD 0x01（复位）...")
        await c.write_gatt_char(CMD, bytes([0x01]), response=False)
        await asyncio.sleep(1.0)
        print("③ 复位后第 1 次读   t1 =", await get_t1(c, lg))
        await asyncio.sleep(1.5)
        print("④ 复位后第 2 次读   t1 =", await get_t1(c, lg))
        await asyncio.sleep(1.5)
        print("⑤ 复位后第 3 次读   t1 =", await get_t1(c, lg))

        print("⑥ 再发一次 0x01，然后立刻读两次")
        await c.write_gatt_char(CMD, bytes([0x01]), response=False)
        await asyncio.sleep(0.8)
        print("   第 1 次           t1 =", await get_t1(c, lg))
        await asyncio.sleep(1.5)
        print("   第 2 次           t1 =", await get_t1(c, lg))

    lg.pump()
    await asyncio.sleep(0.5)
    lg.pump()
    txt = lg.text()
    ser.close()

    print()
    print("--- 固件【发给屏】的命令里，与 t1(状态字) 有关的行 ---")
    hits = 0
    for ln in txt.splitlines():
        if "screen <- ESP32" in ln and "t1." in ln:
            print("  ", ln.strip()[ln.strip().find("screen"):][:80])
            hits += 1
    print("  （共 %d 条）" % hits)
    if hits == 0:
        print("  🔴 固件【一条都没发】⇒ ⭐ 是 s_c.state 没变成 IDLE（⛔ 不是重绘问题）")
    else:
        print("  ⭐ 固件发了 ⇒ ⭐ 那就是屏没应用/没重绘（⭐ 同 C139）")

    print()
    print("--- 固件日志里与状态/复位有关的行 ---")
    for ln in txt.splitlines():
        u = ln.upper()
        if ("RESET" in u or "REQUESTED" in u or "STATE" in u
                or "START" in u or "STOP" in u or "FINISH" in u
                or "FEED COMPLETE" in u):
            print("  ", ln.strip()[:110])
    print()
    print("--- 屏的回复（解码）---")
    for b in lg.replies():
        print("  ", repr(b))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
