#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
read_log.py —— 【限时读串口】抓 ESP32 日志（⛔ 不用 idf.py monitor）

为什么要这个脚本
================
`idf.py monitor` 是【交互式终端】，占住终端不退出（要 Ctrl+]）
=> 脚本/自动化抓不到日志。见 esp32/上机指南.md §八 + 问题分析 §5.1。

本脚本：打开串口 -> 收 N 秒 -> 关闭（⭐ 句柄必定释放）。
可选 --reset 用 DTR/RTS 复位板子，从启动头开始抓。

用法
====
    python read_log.py --port COM29 --seconds 8
    python read_log.py --port COM29 --seconds 8 --reset
    python read_log.py --port COM29 --seconds 20 --save ..\\evidence\\x.log

⚠️ 编码：控制台代码页 936(GBK) 时，本脚本强制 UTF-8 输出，
   否则含 emoji 的打印会 UnicodeEncodeError。
"""

import argparse
import io
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK，会炸）----------------------------
# ⚠️ 与 send_frames.py / send_frames_ble.py 同一处理：启动即重配成 UTF-8。
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description="限时读 ESP32 串口日志（非交互）")
    ap.add_argument("--port", required=True, help="如 COM29")
    ap.add_argument("--baud", type=int, default=115200,
                    help="日志波特率（默认 115200，⭐ 与烧录波特率无关）")
    ap.add_argument("--seconds", type=float, default=8.0, help="读取秒数")
    ap.add_argument("--reset", action="store_true",
                    help="用 DTR/RTS 复位板子，从启动头开始抓")
    ap.add_argument("--save", default="", help="另存到文件（UTF-8）")
    args = ap.parse_args()

    try:
        import serial
    except ImportError:
        print("🔴 缺 pyserial —— pip install pyserial")
        return 2

    buf = bytearray()
    ser = None
    try:
        # 🔴🔴 关键：**打开 COM29 就会复位 ESP32-S3**（⭐ 2026-09-30 实测确认）
        #    · ESP32-S3 的原生 USB-Serial/JTAG 把 DTR/RTS 接到了芯片的
        #      复位/启动电路上 ⇒ **pyserial 在 open() 时会拉这两根线**
        #      ⇒ 🔴 **板子被复位**，⚠️ **池里的数据全部丢失**
        #    · ⭐ 实测：喂完 200 帧后用本脚本读一次日志 ⇒ 板子重启、
        #      `pool=0 total=0` ⇒ 🔴 **把正在做的测试毁掉了**
        #  ⇒ ⭐ 对策：**open() 之前先把 DTR/RTS 置为"不复位"的静息电平**，
        #     并且 ⛔ **绝不在 open 之后再动它们**（除非显式 --reset）。
        #    ⚠️ pyserial 的构造参数里传 dtr/rts 不总是生效
        #      （⭐ 取决于驱动），所以**用 open() 前后的显式设置兜底**。
        ser = serial.Serial()
        ser.port = args.port
        ser.baudrate = args.baud
        ser.timeout = 0.2
        ser.dtr = False          # ⭐ 打开时不要拉 DTR
        ser.rts = False          # ⭐ 打开时不要拉 RTS
        ser.open()
        # ⚠️ 再确认一次（⭐ 部分驱动会在 open 时自作主张拉线）
        if not args.reset:
            ser.setDTR(False)
            ser.setRTS(False)
        if args.reset:
            # ESP32-S3 原生 USB-Serial/JTAG：DTR/RTS 组合复位
            #   ⚠️ 只有显式传 --reset 才这么做（⭐ 会清空池内数据！）
            ser.setDTR(False)
            ser.setRTS(True)
            time.sleep(0.12)
            ser.setRTS(False)
            time.sleep(0.08)
            ser.setDTR(True)
            time.sleep(0.05)
        ser.reset_input_buffer()

        t0 = time.time()
        while time.time() - t0 < args.seconds:
            n = ser.in_waiting
            if n:
                buf += ser.read(n)
            else:
                time.sleep(0.05)
    except Exception as e:
        print("🔴 串口错误: %s" % e)
        return 3
    finally:
        if ser is not None:
            try:
                ser.close()          # ⭐ 必须释放，否则下次烧录 PermissionError(13)
            except Exception:
                pass

    text = buf.decode("utf-8", errors="replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    print("---- 收到 %d 字节 ----" % len(buf))

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with io.open(args.save, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("已存: %s" % os.path.abspath(args.save))
    return 0


if __name__ == "__main__":
    sys.exit(main())
