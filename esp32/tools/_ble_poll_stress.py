"""一次性：A/B 对照 —— 播放中【并发 GATT 轮询】是不是 ESP32 重启的触发条件。

背景（真机观察，两次）
----------------------------------------------------------------------------
用网页上位机：连接 -> 清池 -> 上传 -> 起播 -> 约 20 秒后 BLE 掉线，
且串口日志时间戳【倒退】+ pool 归零 => 板子重启了。
而此前用 Python 工具跑同样的"上传 + 起播"多次，从未重启。

已知差异：网页每 1.2 秒发 CMD 0x02 并 read 0xABF4（STAT 轮询），
而 Python 探针轮询间隔大得多 / 根本不轮询。

假设
----------------------------------------------------------------------------
H1: 只起播、不轮询        => 不重启
H2: 起播 + 1.2 秒轮询 STAT => 重启

用法
----------------------------------------------------------------------------
    python _ble_poll_stress.py --mode quiet  --seconds 90
    python _ble_poll_stress.py --mode poll   --seconds 90
"""
import argparse
import asyncio
import re
import sys
import time

from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
CMD_RESET, CMD_STAT, CMD_PLAY = 0x01, 0x02, 0x03
FRAME_BYTES = 9
HDR_EVENT, HDR_TOTAL = 0xA5, 0x00
RESET_FRAMES = 4


def build_payload(n):
    def word(tick, inc, axis, vel, kind, timbre):
        return (((tick & 0xFFFFF) << 44) | ((inc & 0x1FFFFF) << 23) |
                ((axis & 0xF) << 19) | ((vel & 0xFF) << 11) |
                ((kind & 0x3) << 9) | ((timbre & 0x3) << 7))
    out = bytearray()
    out += bytes([HDR_EVENT]) * (FRAME_BYTES * RESET_FRAMES)
    tf = bytearray(9); tf[0] = HDR_TOTAL
    v = n
    for i in range(8, 0, -1):
        tf[i] = v & 0xFF; v >>= 8
    out += tf
    for i in range(n):
        out += bytes([HDR_EVENT]) + word(1000 + i * 37, 164927, i % 16, 100, i % 2, i % 2).to_bytes(8, "big")
    return bytes(out)


async def stat(c):
    await c.write_gatt_char(UUID_CMD, bytes([CMD_STAT]), response=False)
    await asyncio.sleep(0.35)
    t = bytes(await c.read_gatt_char(UUID_STAT)).decode("utf-8", "replace")
    d = {}
    for k in ("pool", "sent", "ovf", "late", "mm", "run", "tf", "unk"):
        m = re.search(r"\b%s=(\d+)" % k, t)
        if m:
            d[k] = int(m.group(1))
    return d


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["quiet", "poll"], default="quiet")
    ap.add_argument("--seconds", type=float, default=90.0)
    ap.add_argument("--n", type=int, default=111)
    args = ap.parse_args()

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=15)
    if dev is None:
        print("RED: 没找到 %s（板子在广播吗）" % DEV)
        return 1
    print("模式 = %s（%s轮询 STAT）  观察 %.0f 秒"
          % (args.mode, "" if args.mode == "poll" else "不", args.seconds))

    disconnected = {"at": None}
    c = BleakClient(dev)
    c._backend  # noqa
    await c.connect()
    c._disconnected_event = None

    def on_disc(_c):
        disconnected["at"] = time.time()
    try:
        c.set_disconnected_callback(on_disc)
    except Exception:
        pass

    await asyncio.sleep(1.0)
    await c.write_gatt_char(UUID_CMD, bytes([CMD_RESET]), response=False)
    await asyncio.sleep(0.8)
    pl = build_payload(args.n)
    for o in range(0, len(pl), 180):
        await c.write_gatt_char(UUID_RECV, pl[o:o + 180], response=False)
        await asyncio.sleep(0.004)
    await asyncio.sleep(0.8)
    d0 = await stat(c)
    print("  灌后 pool=%s tf=%s" % (d0.get("pool"), d0.get("tf")))

    await c.write_gatt_char(UUID_CMD, bytes([CMD_PLAY]), response=False)
    t0 = time.time()
    print("  已起播，开始观察…")
    polls = 0
    last = None
    while time.time() - t0 < args.seconds:
        await asyncio.sleep(1.2 if args.mode == "poll" else 5.0)
        if disconnected["at"]:
            print("  RED 在第 %.0f 秒检测到【连接断开】" % (disconnected["at"] - t0))
            break
        try:
            d = await stat(c)
            polls += 1
            if d.get("sent") != last:
                print("  t=%4.0fs sent=%s run=%s ovf=%s late=%s"
                      % (time.time() - t0, d.get("sent"), d.get("run"),
                         d.get("ovf"), d.get("late")))
                last = d.get("sent")
        except Exception as e:
            # ⚠️ 轮询抛异常本身就是【断连】的证据 —— 必须把它记进同一个标志，
            # ⛔ 不能只 break。🔴 实测踩过：bleak 的 disconnected 回调【没触发】，
            #    于是断连了却打印"没断"（判据漏了这条路径，C157 同族）。
            disconnected["at"] = disconnected["at"] or time.time()
            print("  RED 第 %.0f 秒轮询出错（= 断连）：%s"
                  % (time.time() - t0, str(e)[:90]))
            break

    print()
    if disconnected["at"]:
        print("结论：%s 模式下【断了】=> 与假设一致"
              % ("poll" if args.mode == "poll" else "quiet"))
        rc = 2
    else:
        print("结论：%s 模式下 %.0f 秒内【没断】（轮询 %d 次）"
              % (args.mode, args.seconds, polls))
        rc = 0
    try:
        if c.is_connected:
            await c.disconnect()
    except Exception:
        pass
    return rc


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
