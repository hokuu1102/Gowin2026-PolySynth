"""⭐ 给屏的 t3 发一条极其显眼的命令，并回问内部值。

⚠️ 为什么要写成文件：⭐ 用 `python -c` 时 PowerShell 的引号转义会把
   `t3.txt="ZZZZ"` 里的双引号搞坏 ⇒ 🔴 **脚本 SyntaxError，命令根本没发出去**
   ⇒ ⚠️ 而"屏没变"会被**误读成"控件名不对"**（⭐ 同族 C103：抓不到 ≠ 没发）。
"""
import asyncio
import sys

import serial
from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

CMD = "0000abf3-0000-1000-8000-00805f9b34fb"


async def main():
    lg = serial.Serial()
    lg.port = "COM29"
    lg.baudrate = 115200
    lg.timeout = 0.1
    lg.dtr = False
    lg.rts = False
    lg.open()
    lg.setDTR(False)
    lg.setRTS(False)
    lg.reset_input_buffer()
    log = bytearray()

    async def pump():
        while True:
            d = lg.read(8192)
            if d:
                log.extend(d)
            await asyncio.sleep(0.05)

    t = asyncio.create_task(pump())
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == "FPGA2026-Synth", timeout=12)
    if dev is None:
        print("RED: not advertising")
        return 1

    async def raw(c, s):
        await c.write_gatt_char(CMD, bytes([0x21]) + s.encode(), response=False)
        await asyncio.sleep(0.7)

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        print('>>> 发 t3.txt="ZZZZ" 和 t3.pco=31(蓝)')
        await raw(c, 't3.txt="ZZZZ"')
        await raw(c, "t3.pco=31")
        await asyncio.sleep(1.0)
        print(">>> 回问内部值")
        await raw(c, "get t3.txt")
        await raw(c, "get t3.pco")
        await asyncio.sleep(1.0)
        print(">>> 保持 30 秒 —— 请看屏")
        await asyncio.sleep(30)

    t.cancel()
    lg.close()
    txt = log.decode("utf-8", "replace")
    print()
    print("--- 固件发的 ---")
    for ln in txt.splitlines():
        if "screen <- ESP32" in ln:
            print("  ", ln.strip()[ln.strip().find("screen"):][:70])
    print("--- 屏回的（解码）---")
    for ln in txt.splitlines():
        if "[" in ln and "screen -> ESP32" in ln:
            hx = ln[ln.find("[") + 1:ln.rfind("]")].split()
            try:
                print("  ", repr(bytes(int(x, 16) for x in hx)))
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
