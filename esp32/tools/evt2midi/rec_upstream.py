#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rec_upstream.py —— ⭐ 录制 ESP32 回传的上行字节流（FPGA → ESP32 → BLE → PC）

═══ 用途 ═══
⭐ 与 `evt2midi.py` 配对：
    ⭐ 本工具 **录** 出原始字节文件  →  `evt2midi.py` **转** 成 `.mid`

═══ 为什么必须"原样录字节"（⚠️ 这是设计要点）═══
🔴 **不要在这里解析！** ⭐ 只落盘**原始字节**。原因：
  · ⭐ 上行格式**尚未冻结**（⭐ 见 `ESP32侧再回函-20261001.md` §三）
    ⇒ ⚠️ 若录制时解析，格式一改，**已录的文件就废了**
  · ⭐ 存原始字节 ⇒ ⭐ **格式定下来后可以重新解析**（⭐ 数据是资产，解析是可重做的）

═══ 用法 ═══
    python rec_upstream.py --out rec.bin --seconds 30
    python rec_upstream.py --out rec.bin --seconds 30 --hex   # 另存可读 hex

⭐ 接线：⭐ 无需接线 —— ⭐ 走 BLE 订阅 `0xABF2`（⭐ 与 `e2e_accept.py` 同一链路）。
"""

import argparse
import asyncio
import sys
import time

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

DEV_NAME = "FPGA2026-Synth"
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"   # ⭐ 我们订阅这个
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"    # ⭐ 可选：发起播命令


async def run(out_path, seconds, do_start, scan_to, hex_path):
    from bleak import BleakScanner, BleakClient

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV_NAME, timeout=scan_to)
    if dev is None:
        print("RED: 没找到 %s（⚠️ 板子在广播吗？手机是否还连着？）" % DEV_NAME)
        return 2

    chunks = []
    total = [0]

    def on_notify(_sender, data):
        # ⭐ 只收集原始字节 —— ⛔ 不解析（⭐ 见文件头说明）
        b = bytes(data)
        chunks.append(b)
        total[0] += len(b)

    print("已连接；订阅 %s ..." % UUID_NOTI)
    async with BleakClient(dev) as c:
        await c.start_notify(UUID_NOTI, on_notify)
        # ⭐ 等订阅真正生效（⚠️ CCCD 写完才算 —— 见经验 C106）
        await asyncio.sleep(1.0)

        if do_start:
            # ⭐ 可选：发 CMD 0x03 让 ESP32 起播（⭐ 这样才有回传）
            try:
                await c.write_gatt_char(UUID_CMD, bytes([0x03]), response=False)
                print("已发 CMD 0x03（起播）")
            except Exception as e:
                print("⚠️ 起播命令发送失败：%s" % e)

        print("录制 %.0f 秒 ..." % seconds)
        t0 = time.time()
        last = 0
        while time.time() - t0 < seconds:
            await asyncio.sleep(0.5)
            if total[0] != last:
                last = total[0]
                print("  已收 %d 字节" % total[0], flush=True)

        try:
            await c.stop_notify(UUID_NOTI)
        except Exception:
            pass

    blob = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(blob)
    print()
    print("写出 %s：%d 字节（%d 个 notify 包）" % (out_path, len(blob), len(chunks)))

    if hex_path:
        with open(hex_path, "w", encoding="utf-8") as f:
            for i in range(0, len(blob), 16):
                f.write("%06X  %s\n" % (i, blob[i:i + 16].hex(" ")))
        print("另存 %s" % hex_path)

    if len(blob) == 0:
        print("⚠️ 收到 0 字节 —— ⚠️ 检查：① 是否已订阅 ② FPGA 侧是否在发 ③ 是否已起播")
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description="录制 ESP32 上行字节流（原样落盘）")
    ap.add_argument("--out", required=True, help="输出原始字节文件，如 rec.bin")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--start", action="store_true",
                    help="录之前发 CMD 0x03 起播（⚠️ 需要 ESP32 已灌好曲谱）")
    ap.add_argument("--hex", dest="hex_path", default="", help="另存可读 hex 转储")
    ap.add_argument("--scan-timeout", type=float, default=12.0)
    args = ap.parse_args()

    return asyncio.run(run(args.out, args.seconds, args.start,
                           args.scan_timeout, args.hex_path))


if __name__ == "__main__":
    sys.exit(main())
