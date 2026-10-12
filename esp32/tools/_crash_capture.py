"""一次性：把 ESP32 串口日志【实时落盘】，用于抓崩溃瞬间的证据。

为什么要单独写一个（⛔ 不用 read_log.py）
----------------------------------------------------------------------------
`read_log.py` 把输出攒到最后才给。而我们要抓的是**板子重启的那一瞬间**：
  · boot banner 里的复位原因（rst:0x? = 掉电? 看门狗? 软件复位?）
  · panic 回溯（Guru Meditation / backtrace）
  · 掉电检测（Brownout detector was triggered）
⇒ 这些**必须当场落盘**，否则一旦进程被杀或没跑完就全丢了。

用法
----------------------------------------------------------------------------
    python _crash_capture.py --port COM29 --seconds 900 --out crash.log
    python _crash_capture.py --port COM29 --seconds 900 --reset   # 先复位再抓

⚠️ 串口同一时刻只允许一个读者（U85）—— 抓的时候 ⛔ 不要同时开别的读日志程序。
"""
import argparse
import os
import sys
import time

import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 崩溃相关的关键字（命中就高亮，方便我 grep）
CRASH_KEYS = ("rst:0x", "Brownout", "Guru Meditation", "Backtrace", "abort()",
              "assert", "StoreProhibited", "LoadProhibited", "InstrFetchProhibited",
              "IllegalInstruction", "watchdog", "WDT", "Task watchdog",
              "esp_task_wdt", "CPU halted", "panic", "stack overflow",
              "heap", "CORRUPT", "REBOOT", "boot:", "ESP-ROM", "app_main")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM29")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=900.0)
    ap.add_argument("--out", default="crash.log")
    ap.add_argument("--reset", action="store_true", help="先拉 DTR/RTS 复位一次")
    args = ap.parse_args()

    # U86：open() 会拉 DTR/RTS，先压住
    s = serial.Serial()
    s.port = args.port
    s.baudrate = args.baud
    s.timeout = 0.1
    s.dtr = False
    s.rts = False
    s.open()
    s.setDTR(False)
    s.setRTS(False)
    s.reset_input_buffer()

    if args.reset:
        # ESP32 自动下载电路：RTS 拉低进复位
        s.setRTS(True)
        time.sleep(0.1)
        s.setRTS(False)
        time.sleep(0.3)
        print("已发一次复位脉冲", flush=True)

    print("开始抓 %s -> %s，共 %.0f 秒" % (args.port, args.out, args.seconds), flush=True)
    t0 = time.time()
    total = 0
    hits = []
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("# crash capture from %s at %s\n" % (args.port,
                time.strftime("%Y-%m-%d %H:%M:%S")))
        while time.time() - t0 < args.seconds:
            n = s.in_waiting
            if n:
                raw = s.read(n)
                total += len(raw)
                txt = raw.decode("utf-8", "replace")
                f.write(txt)
                f.flush()                       # 关键：立刻落盘
                os.fsync(f.fileno())
                for ln in txt.splitlines():
                    if any(k in ln for k in CRASH_KEYS):
                        hits.append(ln.strip())
                        print("  HIT  " + ln.strip()[:150], flush=True)
            else:
                time.sleep(0.02)
            # 每 15 秒报一次心跳，便于确认它还活着
            if int(time.time() - t0) % 15 == 0 and int(time.time() - t0) > 0:
                pass
    s.close()
    print("抓完：%d 字节，命中 %d 条崩溃相关行" % (total, len(hits)), flush=True)
    for h in hits[-40:]:
        print("  " + h[:160])
    return 0


if __name__ == "__main__":
    sys.exit(main())
