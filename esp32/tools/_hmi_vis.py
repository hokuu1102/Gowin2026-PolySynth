"""⭐⭐ 决定性判据：让 `t3` 【隐藏/显示】，看屏上哪一栏跟着动。

⭐ 为什么这是决定性的：
   🔴 已实测：`t3.txt="ZZZZ"` 发出后，`get t3.txt` 回 `pZZZZ`
      ⇒ ⭐ **屏里 `t3` 的值确实变了**，⚠️ 但屏上那栏**没变**
      ⇒ 🔴 **唯一解释：屏上【看到的那栏】不是 `t3`**（⭐ 名字不同 / 在别的页）
   ⭐ 而 `vis`（可见性）是**最容易看出来**的属性 ——
      哪一栏跟着消失/出现，**那一栏就是 `t3`**。

⚠️ 同时用 `t2` 当【对照组】（⭐ 已知 t2 是能用的）。
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

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == "FPGA2026-Synth", timeout=12)
    if dev is None:
        print("RED: not advertising")
        return 1

    async def raw(c, s):
        await c.write_gatt_char(CMD, bytes([0x21]) + s.encode(), response=False)
        await asyncio.sleep(0.5)

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        print(">>> 第 1 步：把 t3 【隐藏】8 秒")
        await raw(c, "t3.vis=0")
        await asyncio.sleep(8)
        print(">>> 第 2 步：把 t3 【显示】回来")
        await raw(c, "t3.vis=1")
        await asyncio.sleep(2)
        print(">>> 第 3 步：把 t2 【隐藏】8 秒（对照组，t2 是已知能用的）")
        await raw(c, "t2.vis=0")
        await asyncio.sleep(8)
        print(">>> 第 4 步：把 t2 【显示】回来")
        await raw(c, "t2.vis=1")
        await asyncio.sleep(3)
        print(">>> 完成")

    lg.close()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
