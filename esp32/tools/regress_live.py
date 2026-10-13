#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
regress_live.py —— ⭐ 真机回归（CMD 命令集 + 上行蓄水/放水）

═══ 用途 ═══
⭐ 一条命令跑完**需要板子**的那几项回归：
    ① CMD `0x01` 清池
    ② CMD `0x02` 上报状态 → 读 `0xABF4`
    ③ CMD `0x03` 起播 → 等 `feed done`
    ④ CMD `0x04` 停止
    ⑤ CMD `0xEE` 未知命令 → 必须**计数**（⛔ 不静默吞）
    ⑥ 上行蓄水：未订阅时写 N 字节 ⇒ 只入环不发
    ⑦ 上行放水：订阅后 ⇒ 字节**逐字节一致**地回来

═══ 与 `e2e_accept.py` 的分工 ═══
  · `e2e_accept.py`  = ⭐ **下行**（PC→ESP32→UART）一键验收
  · `regress_live.py`= ⭐ **命令 + 上行**（ESP32→PC）回归
  ⚠️ 两者都要板子，⭐ 但测的是不同通路 ⇒ ⭐ 都要跑。

═══ 用法 ═══
    python regress_live.py --log-port COM29 --uart-port COM31
    python regress_live.py --selftest          # ⛔ 不需要硬件
"""

import argparse
import asyncio
import struct
import sys
import time


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")


for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

DEV_NAME = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"

FRAME = 9
N_EVENTS = 200
UP_BYTES = 2000


def build_score(n):
    """⭐ 造 n 个事件的曲谱（⭐ 与 `e2e_accept.py` 同口径）。"""
    inc = 164927
    out = bytearray(bytes([0xA5]) * (FRAME * 4))
    out += bytes([0x00]) + struct.pack(">Q", n)
    for i in range(n):
        tick = 1000 + i * 37
        w = ((tick & 0xFFFFF) << 44) | ((inc & 0x3FFFFF) << 22) | \
            (((i % 16) & 0xF) << 18) | (((60 + (i % 60)) & 0x7F) << 11) | \
            (((i % 2) & 0x3) << 9) | (((i % 2) & 0x1) << 8)
        out += bytes([0xA5]) + w.to_bytes(8, "big")
    return bytes(out)


def open_no_reset(port, baud, timeout=0.05):
    """⭐ 打开串口**不拉 DTR/RTS**（⚠️ 否则会复位板子 —— 见经验 U86）。"""
    import serial
    s = serial.Serial()
    s.port = port
    s.baudrate = baud
    s.timeout = timeout
    s.dtr = False
    s.rts = False
    s.open()
    s.setDTR(False)
    s.setRTS(False)
    return s


def _stat_line(txt, prefix):
    for ln in txt.splitlines():
        if ln.startswith(prefix):
            return ln
    return ""


def _stat_tok(line, key):
    """⭐ 从 `k=v` 行里取某个键的值（⚠️ 找不到返回 "?"）。"""
    for tok in line.split():
        if tok.startswith(key):
            return tok.split("=", 1)[1] if "=" in tok else tok[len(key):]
    return "?"


async def read_stat(c):
    """
    ⭐⭐ **读 STAT 前必须【先请求】** —— 🔴 这是我第一版踩的坑。

    🔴 `0xABF4` 不是"实时寄存器"，⭐ 而是**请求时生成的快照**：
       ⚠️ 只有收到 `CMD 0x02` 才会更新内容。
    ⇒ ⚠️ **不请求直接读 = 读到上一次的内容**（⭐ 而且**看不出来是旧的**）。
    📌 症状（⭐ 我实测到的）：⭐ 不请求就读 ⇒ `pool=0 sent=0 in=0`，
       而实际上池里明明有 200 帧、上行明明通了 —— ⚠️ 全是**陈旧快照**。
    ⭐ 同族：`C113`（⭐ 错值伪装成合理值 —— ⚠️ 这里连"值"都是合理的旧值）。
    """
    # ⭐ 重试 3 次：BLE 抖动时读回会失败或读到半截
    #    🔴 实测症状：偶发 `ValueError: invalid literal for int(): '?'`
    #    —— ⚠️ 那是读到**被截断/半更新的内容**（⭐ 不是设备坏）。
    #    ⭐ 判据要结实：⭐ 读不稳就重读，⛔ 不要一次失败就判红。
    last = ""
    for _try in range(3):
        await c.write_gatt_char(UUID_CMD, bytes([0x02]), response=False)
        await asyncio.sleep(0.6)          # ⚠️ 给固件一点时间组装
        try:
            st = await c.read_gatt_char(UUID_STAT)
            last = bytes(st).decode("utf-8", "replace")
            if last.count("=") > 10:      # ⭐ 粗判"像一份完整状态"
                break
        except Exception:                 # noqa: BLE001
            pass
        await asyncio.sleep(0.4)
    return last


async def run(log_port, uart_port, baud):
    from bleak import BleakClient, BleakScanner

    fails = []
    print("=" * 74)
    print("真机回归：CMD 命令集 + 上行蓄水/放水")
    print("=" * 74)
    print("日志口=%s  数据口=%s @ %d" % (log_port, uart_port, baud))
    print()

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV_NAME), timeout=12)
    if dev is None:
        print("🔴 没找到 %s（⚠️ 板子在广播吗？）" % DEV_NAME)
        return 3

    async with BleakClient(dev) as c:
        await asyncio.sleep(0.8)

        # ---- ⑤ 未知命令：⭐ 必须计数（⛔ 不静默吞）----
        # ⚠️ `cmd_ok`/`cmd_unk` 是【自开机累计】量 ⇒ ⭐ 必须比【增量】
        #    （🔴 直接断言绝对值会错 —— ⭐ 见经验 `C112`）
        print("⑤ CMD 0xEE（未知）...")
        txt0 = await read_stat(c)
        unk0 = int(_stat_tok(_stat_line(txt0, "cmd="), "unk") or 0)
        await c.write_gatt_char(UUID_CMD, bytes([0xEE]), response=False)
        await asyncio.sleep(0.5)
        txt1 = await read_stat(c)
        cmd_line = _stat_line(txt1, "cmd=")
        unk1 = int(_stat_tok(cmd_line, "unk") or 0)
        print("   %s（unk 增量 = %d）" % (cmd_line, unk1 - unk0))
        if unk1 - unk0 != 1:
            fails.append("未知命令未被计数（unk 增量=%d，期望 1）" % (unk1 - unk0))
            print("   🔴 未知命令【没有被计数】")
        else:
            print("   ✅ 未知命令已计数（增量 +1）")

        # ---- ① 清池 ----
        print("① CMD 0x01（清池）...")
        await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
        await asyncio.sleep(0.8)
        txt = await read_stat(c)
        pool_now = _stat_tok(_stat_line(txt, "pool="), "pool").split("/")[0]
        print("   pool = %s（期望 0）" % pool_now)
        if pool_now != "0":
            fails.append("清池后 pool=%s" % pool_now)

        # ---- ② 灌曲谱 ----
        print("② BLE 灌 %d 帧 ..." % N_EVENTS)
        payload = build_score(N_EVENTS)
        off = 0
        while off < len(payload):
            n = min(180, len(payload) - off)
            await c.write_gatt_char(UUID_RECV, payload[off:off + n], response=False)
            off += n
            await asyncio.sleep(0.004)
        await asyncio.sleep(1.5)
        txt = await read_stat(c)
        got = _stat_tok(_stat_line(txt, "pool="), "pool").split("/")[0]
        print("   pool = %s（期望 %d）" % (got, N_EVENTS))
        if got != str(N_EVENTS):
            fails.append("灌数据后 pool=%s，期望 %d" % (got, N_EVENTS))

        # ---- ③ 起播 ----
        print("③ CMD 0x03（起播）...")
        await c.write_gatt_char(UUID_CMD, bytes([0x03]), response=False)
        # ⚠️ 200 帧 ≈ 14.3 s 放完（⭐ rate=1919 tick/s，首帧提前 ~10.4 s）
        await asyncio.sleep(20)
        txt = await read_stat(c)
        sent = _stat_tok(_stat_line(txt, "pool="), "sent")
        print("   sent = %s（期望 %d）" % (sent, N_EVENTS))
        if sent != str(N_EVENTS):
            fails.append("起播后 sent=%s，期望 %d" % (sent, N_EVENTS))

        # ---- ④ 停止 ----
        print("④ CMD 0x04（停止）...")
        await c.write_gatt_char(UUID_CMD, bytes([0x04]), response=False)
        await asyncio.sleep(0.6)
        print("   ✅ 已发（⚠️ 停止只改状态位，⭐ 无独立读回判据）")

        # ---- ⑥⑦ 上行蓄水 / 放水 ----
        print()
        # 🔴🔴 `u_in` 是【自开机累计】量 ⇒ ⭐ **必须比【增量】**（⭐ 经验 `C112`）
        #    ⚠️ 我第一版就断言了绝对值 2000 ⇒ 🔴 判红，而实际完全正常：
        #       ⭐ 之前 E2E 写过 `R`/`S` 两个触发字符（+2）
        #       ⭐ 上一轮回归写过 2000 ⇒ 累计 4002
        #    ⇒ ⭐ **同一个坑我记过还又踩了一次** —— ⚠️ 所以判据要写死成"增量"。
        txt = await read_stat(c)
        u_in0 = int(_stat_tok(_stat_line(txt, "ring="), "in") or 0)
        print("⑥ 上行蓄水：往 GPIO18 写 %d 字节 ...（u_in 基线 = %d）"
              % (UP_BYTES, u_in0))
        got_noti = []
        # ⚠️ 未订阅 ⇒ 只入环不发
        try:
            s = open_no_reset(uart_port, baud, timeout=0.2)
            time.sleep(0.3)
            blob = bytes(i & 0xFF for i in range(UP_BYTES))
            for i in range(0, len(blob), 126):
                s.write(blob[i:i + 126])
                s.flush()
                time.sleep(0.05)
            s.close()
        except Exception as e:
            print("   🔴 打不开 %s: %s" % (uart_port, e))
            return 3
        await asyncio.sleep(1.5)
        txt = await read_stat(c)
        ring_line = _stat_line(txt, "ring=")
        print("   %s" % ring_line)
        u_in1 = int(_stat_tok(ring_line, "in") or 0)
        d_in = u_in1 - u_in0
        print("   u_in 增量 = %d（⭐ 必须 = %d —— ⚠️ 少于就是【驱动层丢了】）"
              % (d_in, UP_BYTES))
        if d_in != UP_BYTES:
            fails.append("上行 u_in 增量=%d，期望 %d" % (d_in, UP_BYTES))

        print("⑦ 上行放水：订阅 0xABF2 ...")
        await c.start_notify(UUID_NOTI, lambda _s, d: got_noti.append(bytes(d)))
        await asyncio.sleep(6.0)
        try:
            await c.stop_notify(UUID_NOTI)
        except Exception:
            pass
        total = b"".join(got_noti)
        print("   收到 %d 字节 / %d 包（期望 %d）" % (len(total), len(got_noti), UP_BYTES))
        # ⚠️ 环里可能有**更早**的残留 ⇒ ⭐ 只要求"包含刚写的那一段"
        want = bytes(i & 0xFF for i in range(UP_BYTES))
        if want in total:
            print("   ✅ 刚写的 %d 字节【逐字节一致】地回来了" % UP_BYTES)
        elif len(total) >= UP_BYTES:
            print("   ⚠️ 收到了 %d 字节，但没找到完整匹配段（⚠️ 可能有残留/错位）"
                  % len(total))
            fails.append("上行放水内容不匹配")
        else:
            print("   🔴 只收到 %d 字节 < %d" % (len(total), UP_BYTES))
            fails.append("上行放水字节不足（%d < %d）" % (len(total), UP_BYTES))

    print()
    print("=" * 74)
    if not fails:
        print("结论：真机回归全部通过 ✅")
    else:
        print("结论：%d 项不通过 🔴" % len(fails))
        for f in fails:
            print("   - %s" % f)
    print("=" * 74)
    return 0 if not fails else 1


def selftest():
    """⭐ 离线自检：⭐ 只验**能离线验**的（曲谱构造 + 参数面）。"""
    print("=" * 74)
    print("regress_live.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    p = build_score(200)
    chk("① 曲谱 200 帧 = 1845 字节", len(p) == 36 + 9 + 9 * 200, "  实测 %d" % len(p))
    chk("② 9N 对齐", len(p) % FRAME == 0)
    chk("③ 前 4 帧是复位标记", p[:36] == bytes([0xA5]) * 36)
    chk("④ 第 5 帧是总数帧", p[36] == 0x00 and struct.unpack(">Q", p[37:45])[0] == 200)
    kinds = set()
    for i in range(4 + 1, len(p) // FRAME):
        w = int.from_bytes(p[i * FRAME + 1:i * FRAME + 9], "big")
        kinds.add((w >> 9) & 3)
    chk("⑤ kind 只含 0/1（⛔ 无换速）", kinds <= {0, 1}, "  实际=%s" % sorted(kinds))
    # ⭐⭐ 反例
    chk("⑥ 反例：错期望值会被判红", len(build_score(200)) != 1844)
    chk("⑦ 反例：build_score(1) 长度与 200 不同", len(build_score(1)) != len(p))
    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="真机回归：CMD 命令集 + 上行蓄水/放水")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    ap.add_argument("--log-port", help="ESP32 日志口，如 COM29")
    ap.add_argument("--uart-port", help="USB-TTL 口，如 COM31")
    ap.add_argument("--baud", type=int, default=500000)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.log_port or not args.uart_port:
        print("🔴 需要 --log-port 与 --uart-port（⚠️ 或用 --selftest）")
        return 2
    return asyncio.run(run(args.log_port, args.uart_port, args.baud))


if __name__ == "__main__":
    sys.exit(main())
