# -*- coding: utf-8 -*-
"""增量落盘的串口抓取（2026-10-14）。

⭐ 为什么要另写一个：`read_log.py` 把结果【攒到最后】才写文件
   （`--save` 要等 `--seconds` 跑完）⇒ ⛔ 没法实时看。
   本脚本【边收边落盘】⇒ 随时可以 tail 它。

用法：
    python -X utf8 _serial_tap.py --port COM29 --seconds 180 --out <文件>
"""
import argparse
import os
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM29")
ap.add_argument("--baud", type=int, default=115200)
ap.add_argument("--seconds", type=float, default=180.0)
ap.add_argument("--out", required=True)
a = ap.parse_args()

import serial  # noqa: E402

os.makedirs(os.path.dirname(a.out), exist_ok=True)
# 覆盖式打开（每次抓取一个新文件，⛔ 不追加旧内容）
f = open(a.out, "w", encoding="utf-8", newline="\n", buffering=1)   # 行缓冲

s = serial.Serial(a.port, a.baud, timeout=0.2)
# ⚠️ 压住 DTR/RTS —— 否则打开串口会把板子拉进下载模式/复位
try:
    s.dtr = False
    s.rts = False
except Exception:
    pass

print("  抓取中：%s @ %d -> %s（%.0f 秒）" % (a.port, a.baud, a.out, a.seconds))
t0 = time.time()
n = 0
try:
    while time.time() - t0 < a.seconds:
        chunk = s.read(4096)
        if chunk:
            txt = chunk.decode("utf-8", "replace")
            f.write(txt)
            f.flush()
            n += len(chunk)
        else:
            time.sleep(0.02)
finally:
    f.close()
    s.close()
    print("  完成：收到 %d 字节 -> %s" % (n, a.out))
