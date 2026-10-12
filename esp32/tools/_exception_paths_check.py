"""一次性：异常路径自检 —— 池满溢出 / 未知帧头 / 断连重连。

为什么要做
----------------------------------------------------------------------------
这三条此前【从没验过】。判据是"会出错的容量必须看得见"（K-106 纪律）：
  · 池灌满之后多出来的帧，必须【计数】而不是静默丢弃；
  · 未知帧头必须【计数 + 丢弃】，绝不能当事件转发；
  · 断开再连回来，状态必须还能读。

用法
----------------------------------------------------------------------------
    python _exception_paths_check.py
"""
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

HDR_EVENT, HDR_TOTAL = 0xA5, 0x00
FRAME_BYTES = 9
POOL_CAP = 18204          # 从 STAT 的 pool=x/18204 读到


async def stat(c):
    await c.write_gatt_char(UUID_CMD, bytes([0x02]), response=False)
    await asyncio.sleep(0.5)
    t = bytes(await c.read_gatt_char(UUID_STAT)).decode("utf-8", "replace")
    d = {}
    for k in ("pool", "sent", "ovf", "late", "exp", "mm", "clamp", "run",
              "tf", "unk", "rst", "total"):
        m = re.search(r"\b%s=(\d+)" % k, t)
        if m:
            d[k] = int(m.group(1))
    m = re.search(r"pool=(\d+)/(\d+)", t)
    if m:
        d["pool"], d["cap"] = int(m.group(1)), int(m.group(2))
    m = re.search(r"ble=rx(\d+)", t)          # BLE 收到的字节（自开机累计）
    if m:
        d["ble_rx"] = int(m.group(1))
    m = re.search(r"ble=rx\d+ tx\d+ fail=\d+ drop=(\d+)", t)   # ★ 环形缓冲截断丢的字节
    if m:
        d["ble_drop"] = int(m.group(1))
    return d


def ev_frame(tick):
    w = ((tick & 0xFFFFF) << 44) | (164927 << 23) | (0 << 19) | (100 << 11) | (0 << 9) | (0 << 7)
    return bytes([HDR_EVENT]) + w.to_bytes(8, "big")


def reset_seq():
    """⭐ 复位标记：9 个 0xA5（4 帧）。"""
    return bytes([HDR_EVENT]) * (FRAME_BYTES * 4)


def total_frame(n):
    """⭐ 总数帧：0x00 + 8 字节大端事件数。"""
    f = bytearray(9)
    f[0] = HDR_TOTAL
    v = n
    for i in range(8, 0, -1):
        f[i] = v & 0xFF
        v >>= 8
    return bytes(f)


async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        return 1
    ok = True
    rc = 0

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)

        # ---------- ① 未知帧头必须被计数 ----------
        print("① 未知帧头")
        await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
        await asyncio.sleep(0.8)
        # ⭐ 先发复位帧：模拟真实客户端"整包开头"的形状，
        # ⚠️ 否则本步骤会让固件的"已收事件数"停在旧值上（⭐ 见②的说明）。
        await c.write_gatt_char(UUID_RECV, reset_seq(), response=False)
        await asyncio.sleep(0.4)
        before = await stat(c)
        print("   清池后 unk=%s pool=%s" % (before.get("unk"), before.get("pool")))
        bogus = bytes([0x11]) + bytes(8)          # 既不是 0xA5 也不是 0x00
        await c.write_gatt_char(UUID_RECV, bogus * 5, response=False)
        await asyncio.sleep(0.8)
        after = await stat(c)
        du = (after.get("unk", 0) - before.get("unk", 0))
        c1 = (du == 5 and after.get("pool", 0) == before.get("pool", 0))
        print("   发了 5 个未知帧头 => unk 增量 = %d（应为 5）；pool 增量 = %d（应为 0）"
              % (du, after.get("pool", 0) - before.get("pool", 0)))
        print("   %s" % ("OK 未知帧头被计数且未进池" if c1 else "RED 未知帧头没被正确记账"))
        ok &= c1

        # ---------- ② 池满必须记账，不能静默丢 ----------
        print("\n② 池满溢出")
        await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
        await asyncio.sleep(0.8)
        b2 = await stat(c)
        cap = b2.get("cap", POOL_CAP)
        over = cap + 300
        print("   池容量 %d，本次灌 %d 帧（超 %d）" % (cap, over, over - cap))
        chunk = 180
        # ⭐⭐ 2026-10-12：必须带【复位帧 + 总数帧】！
        # 🔴 踩过的坑：原来只发事件帧 ⇒ 固件里"已收事件数"【从不归零】
        #    ⇒ 屏上显示 **`18704/200`**（= 上一次测试的 18504 + 这次 200）。
        #    ⭐ 那是【我的测试】污染了实机状态，⛔ 不是固件的问题。
        # ⭐ 真实客户端（mid2evt -> send_frames_ble）发的是【完整整包】，
        #    所以测试也必须照它的形状发，否则测的就不是真实路径。
        payload = reset_seq() + total_frame(over) + \
                  b"".join(ev_frame(i & 0xFFFFF) for i in range(over))
        sent = 0
        t0 = time.time()
        while sent < len(payload):
            n = min(chunk, len(payload) - sent)
            await c.write_gatt_char(UUID_RECV, payload[sent:sent + n], response=False)
            sent += n
            await asyncio.sleep(0.003)
        await asyncio.sleep(1.2)
        # ⭐⭐ 2026-10-12：必须等【排空任务】追平再读 STAT。
        # 🔴 踩过的坑：原来只等 1.2 s ⇒ 灌完那一刻 `ble_rx` 已记满，
        #    但 `task_drain` 还在分批把字节搬进池 ⇒ ⚠️ `pool+ovf` 还没跟上
        #    ⇒ 恒等式差 4/24/44 帧（**公差 20 = 我每批发的帧数**，⭐ 这个数列
        #      就是"还差几批没处理"的指纹，⛔ 不是丢帧）。
        # ⭐ 判据：等到 `ble_rx` 连续两次不变（说明排空追平了）再读。
        prev_rx = -1
        for _ in range(60):
            await asyncio.sleep(0.5)
            s = await stat(c)
            if s.get("ble_rx") == prev_rx:
                break
            prev_rx = s.get("ble_rx")
        a2 = await stat(c)
        print("   灌完：pool=%s/%s ovf=%s ble_rx=%s（用时 %.1f s）"
              % (a2.get("pool"), a2.get("cap"), a2.get("ovf"),
                 a2.get("ble_rx"), time.time() - t0))
        # 守恒不变量：ESP32【收到】的帧 = 进池的 + 溢出的（逐层记账，看账对不对）。
        # 注意：不能断言 ovf == 超出的帧数 —— BLE 的无响应写【没有投递保证】，
        # 少掉的帧根本没到 ESP32，它当然不会记进 ovf。
        # ⭐⭐ 守恒不变量（⭐ 两边必须用同一个基准）
        # 🔴 踩过的坑：原来拿"我【发出】的帧数"去比"进池+溢出" ——
        #    ⚠️ 那是【两个基准】：BLE 的无响应写【没有投递保证】，
        #    空口丢掉的帧 ESP32 根本没收到、自然不记账
        #    ⇒ 🔴 差额被误判成"固件静默丢帧"（实测差 12~84 帧，正是 0.5% 的空口丢包）。
        # ⭐ 正确基准：【ESP32 收到的】= 进池 + 溢出 + 未知 + 复位 + 截断丢。
        d_sent = len(payload) // FRAME_BYTES
        d_rx = (a2.get("ble_rx", 0) - b2.get("ble_rx", 0)) // FRAME_BYTES
        air_lost = d_sent - d_rx
        d_drop = (a2.get("ble_drop", 0) - b2.get("ble_drop", 0)) // FRAME_BYTES
        d_pool = a2.get("pool", 0) - b2.get("pool", 0)
        d_ovf = a2.get("ovf", 0) - b2.get("ovf", 0)
        d_unk = a2.get("unk", 0) - b2.get("unk", 0)
        d_rst = a2.get("rst", 0) - b2.get("rst", 0)
        # ⭐ 总数帧：`tf` 是【本曲总数】（⛔ 不是累计计数器）⇒ 不能用增量。
        #    ⭐ 本次整包里固定发了 1 个总数帧 ⇒ 记账里写常数 1。
        #    ⚠️ 这正是 C165 说的"差值形状 = 常数 ⇒ 口径问题"：
        #       实测差额恒为 1、四次完全一致 ⇒ 是【口径】没算上它，⛔ 不是丢帧。
        d_tf = 1
        accounted = d_pool + d_ovf + d_unk + d_rst + d_tf + d_drop
        print("   发出 %d 帧，ESP32 收到 %d 帧（空口丢 %d，%.2f%%）"
              % (d_sent, d_rx, air_lost, 100.0 * air_lost / max(1, d_sent)))
        print("   记账：收到 %d 帧 = 进池 %d + 溢出 %d + 未知 %d + 复位 %d + 总数 %d"
              " + 截断丢 %d => 合计 %d%s"
              % (d_rx, d_pool, d_ovf, d_unk, d_rst, d_tf, d_drop, accounted,
                 "" if d_rx == accounted else "   <== 还差 %d 帧！" % (d_rx - accounted)))
        c2a = (a2.get("pool") == cap)
        c2b_ = (d_ovf > 0)
        c2c = (d_rx == accounted)
        c2 = c2a and c2b_ and c2c
        print("   %s" % ("OK 池停在上限、溢出被计数、且逐帧守恒（没有静默丢）"
                         if c2 else
                         "RED 池满行为不符：pool==cap? %s  ovf>0? %s  守恒? %s"
                         % (c2a, c2b_, c2c)))
        ok &= c2

        # ---------- ③ 断连重连 ----------
        print("\n③ 断连重连")
        await c.disconnect()
        await asyncio.sleep(2.0)
        c2b = BleakClient(dev)          # 注意：BleakClient(dev) 本身不是 awaitable
        await c2b.connect()
        await asyncio.sleep(1.2)
        s3 = await stat(c2b)
        c3 = (s3.get("pool") is not None)
        print("   重连后读到 pool=%s tf=%s => %s"
              % (s3.get("pool"), s3.get("tf"), "OK 状态仍可读" if c3 else "RED 读不到"))
        ok &= c3
        await c2b.disconnect()

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
