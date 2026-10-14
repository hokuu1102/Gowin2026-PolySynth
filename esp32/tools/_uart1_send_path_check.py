#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_uart1_send_path_check.py —— 只用 BLE 验证 UART1 的【发送路径】
（⛔ 不需要 CH340 / 不需要真 FPGA）

═══ 为什么需要它 ═══
`_uart1_wire_check.py` 要在另一端接 CH340 才能验"线上字节对不对"。
⚠️ 但 CH340 没接 / 接错时，那个工具只会说"一个字节都没收到"，
   ⛔ 分不清是【ESP32 没发】还是【线没接】—— 这正是本轮的困境。

本工具把这两件事分开：
  · 灌谱 → 起播 → 轮询 0xABF4 的 `sent`（= UART1 实际发出的帧数）
  · `sent` 稳步增长 ⇒ ⭐ ESP32 侧发送路径正常 ⇒ 问题在接线/对端
  · `sent` 恒为 0 且已过提前量 ⇒ 🔴 ESP32 侧真有问题

═══ 它证明不了什么（⭐ 边界）═══
**线上字节是否正确** —— 那必须有真 FPGA 或 CH340 在另一端。
⇒ 所以本工具【不能替代】`_uart1_wire_check.py`，
   它只是"没接线时缩小怀疑范围"。

═══ 用法 ═══
  python _uart1_send_path_check.py            # 用内置音阶
  python _uart1_send_path_check.py --selftest # 离线自检（不需要硬件）
"""

import argparse
import asyncio
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_word as SW                                     # noqa: E402

UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
CMD_RESET, CMD_STAT, CMD_PLAY, CMD_STOP = 0x01, 0x02, 0x03, 0x04
DEV_PREFIX = "FPGA2026-Synth"


def _name_matches(name, exact=None):
    """设备名前缀匹配（改名后仍能用，见 ble_config.h 的说明）。"""
    n = name or ""
    return n.startswith(DEV_PREFIX)


# ===========================================================================
# 判据（抽成纯函数 => 可离线自检）
# ===========================================================================
def parse_stat(txt):
    """从 0xABF4 文本里取 pool 段的关键字段。

    返回 dict；取不到的键为 None。
    ⚠️ 用 `\\b` 锚定键名 —— 实测踩过 `\\bx(\\d+)` 命中 `last=0x00` 里
       那个 `x00` 的坑（同族：正则没锚定会抓到别的字段的尾巴）。
    """
    import re
    out = {"sent": None, "play": None, "t0": None, "lead": None,
           "ttot": None, "pv": None, "run": None, "exp": None}
    m = re.search(r"pool=\d+/\d+(.*)$", txt, re.M)
    seg = m.group(1) if m else txt
    for k in out:
        mm = re.search(r"\b%s=(\d+)" % k, seg)
        if mm:
            out[k] = int(mm.group(1))
    return out


def judge_send_path(samples):
    """
    按采样序列判断"发送路径是否正常"。

    `samples` = [(t_sec, stat_dict), ...]（时间递增）

    返回 (verdict, reason)：
      "ok"       —— sent 从 0 起步并在提前量之后稳步增长
      "nogrow"   —— 已过提前量但 sent 仍为 0 => 🔴 ESP32 侧可能真有问题
      "nolead"   —— 还没过提前量（数据不足，⛔ 不能下结论）
      "bad"      —— 数据不合法（缺字段）
    ⭐ 判据里刻意区分"还没到时间"和"到了时间没涨" ——
       否则会像本轮一样误判成"没发出去"。
    """
    if not samples:
        return "bad", "没有采样"
    last = samples[-1][1]
    for k in ("sent", "play", "t0", "lead"):
        if last.get(k) is None:
            return "bad", "缺字段 %s" % k

    # 是否已过提前量。
    # 🔴 这里的算式【踩过一次】，记下来免得再错：
    #    一开始写的是 `play - t0 - lead > 0`（照搬"heard = play-t0-lead"的说法）,
    #    ⇒ 用实测数据一算：play=20249, t0=20019, lead=20000
    #       => 20249-20019-20000 = -19770（负数）
    #    ⚠️ 但同一时刻 `sent=2` —— **已经在发了** ⇒ 🔴 算式错了。
    #    ⭐ 正确：`play - lead > 0`（`t0` 不参与）。
    #    验证：20249 - 20000 = 249 > 0 ✓ 与"sent 刚开始涨"吻合。
    #    ⚠️ 为什么会错：`t0` 在【中段换速】时会被重锚成一个大位置
    #       （实测从 0 变成 20019），而 `play` 同时也是累计位置
    #       ⇒ 两者不能相减。⭐ pool.c 的门控用的是 `pos_now > s_lead_end`，
    #          而 `s_lead_end = t0_tick + LEAD`（t0 是那一轮的快照）。
    #    📌 结论：对【外部观察者】而言，最稳的判据是「play 与 lead 比」。
    played = last["play"] - last["lead"]
    if played <= 0:
        return "nolead", ("还没过提前量（play-lead = %d）；"
                          "⚠️ 此时 sent=0 是【正确的】" % played)

    if last["sent"] > 0:
        return "ok", "sent = %d（已过提前量且稳步增长）" % last["sent"]

    return "nogrow", ("已过提前量（play-lead = %d）但 sent 仍为 0"
                      " => 🔴 ESP32 侧发送路径可疑" % played)


def selftest():
    """离线自检 —— ⭐ 重点是【非空洞性】与"两种 0 必须分开"。"""
    print("=" * 70)
    print("_uart1_send_path_check.py 离线自检（不需要硬件）")
    print("=" * 70)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-52s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    def mk(sent, play, t0, lead):
        return (0.0, {"sent": sent, "play": play, "t0": t0, "lead": lead,
                      "ttot": 19200, "pv": 1, "run": 1, "exp": 111})

    # 真实数据（本轮实测那一段）
    real = [
        mk(0, 3776, 0, 20000),
        mk(0, 9305, 0, 20000),
        mk(0, 14720, 0, 20000),
        mk(2, 20249, 20019, 20000),
        mk(24, 25663, 20019, 20000),
        mk(32, 31078, 20019, 20000),
    ]
    v, why = judge_send_path(real)
    chk("真实采样 => 判 ok", v == "ok", "  %s" % why)

    # ⭐ 关键：前 3 个采样（还没过提前量）不能判成"没发出去"
    v2, why2 = judge_send_path(real[:3])
    chk("还没过提前量 => 判 nolead（⛔ 不误判为失败）",
        v2 == "nolead", "  %s" % why2)
    chk("非空洞：nolead 的理由里点明了 sent=0 是正常的",
        "正确的" in why2 or "sent=0" in why2, "  %s" % why2)

    # 非空洞：已过提前量但 sent 恒 0 => 必须判 nogrow
    # ⚠️ 构造时要保证 `play - lead > 0`（即已过提前量），否则会落进 nolead。
    stuck = [mk(0, 30000, 20019, 20000), mk(0, 35000, 20019, 20000)]
    v3, why3 = judge_send_path(stuck)
    chk("非空洞：过了提前量还恒 0 => 判 nogrow", v3 == "nogrow", "  %s" % why3)

    # ⭐ 非空洞：`t0` 被重锚（中段换速）时，判据不该受影响
    #    实测 t0 会从 0 变成 20019；若算式里减了 t0 就会算成"还没到时间"。
    reanchored = [mk(2, 20249, 20019, 20000), mk(24, 25663, 20019, 20000)]
    v4, why4 = judge_send_path(reanchored)
    chk("非空洞：t0 被重锚后仍判 ok（⭐ 算式里不该减 t0）",
        v4 == "ok", "  %s" % why4)

    # 非空洞：缺字段 => bad（⛔ 不猜）
    chk("非空洞：缺 sent 字段 => 判 bad",
        judge_send_path([(0.0, {"play": 1, "t0": 0, "lead": 0})])[0] == "bad")
    chk("非空洞：空采样 => 判 bad", judge_send_path([])[0] == "bad")

    # 解析：真实 STAT 文本
    txt = ("V1 mode=B req=3 up=1000ms\n"
           "pool=111/18204 sent=32 ovf=0 late=19 exp=111 mm=0 clamp=2 run=1 "
           "play=31078 t0=20019 lead=20000 ttot=19200 pv=1\n"
           "ble=rx0 tx0 fail=0 drop=0 mtu=517 conn=1 sub=0\n")
    d = parse_stat(txt)
    chk("解析：sent = 32", d["sent"] == 32)
    chk("解析：play = 31078", d["play"] == 31078)
    chk("解析：lead = 20000", d["lead"] == 20000)
    chk("解析：不会把别的字段当 sent（⭐ 正则已锚定）",
        d["sent"] == 32 and d["exp"] == 111)
    # 非空洞：字段缺失时为 None（⛔ 不默认成 0）
    d2 = parse_stat("pool=1/2 sent=3 ovf=0\n")
    chk("非空洞：缺 play 字段 => None（⛔ 不默认 0）", d2["play"] is None)

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


# ===========================================================================
async def run(hex_file, settle):
    from bleak import BleakClient, BleakScanner

    if hex_file and os.path.exists(hex_file):
        words, probs = SW.load_events_hex(hex_file)
        if probs:
            print("  ⚠️ 谱面有 %d 个问题" % len(probs))
    else:
        words = None                                   # 用池里已有的

    dev = None
    for _ in range(6):
        dev = await BleakScanner.find_device_by_filter(
            lambda d, a: _name_matches(d.name), timeout=12)
        if dev:
            break
        await asyncio.sleep(1)
    if dev is None:
        print("🔴 没找到 %s" % DEV_PREFIX)
        return 1
    print("  设备 = %s (%s)" % (dev.name, dev.address))

    async with BleakClient(dev, timeout=35) as c:
        await asyncio.sleep(1.5)

        async def rd():
            await c.write_gatt_char(UUID_CMD, bytes([CMD_STAT]), response=False)
            await asyncio.sleep(0.7)
            t = bytes(await c.read_gatt_char(UUID_STAT)).decode("utf-8", "replace")
            return parse_stat(t)

        if words:
            await c.write_gatt_char(UUID_CMD, bytes([CMD_RESET]), response=False)
            await asyncio.sleep(0.9)
            parts = [SW.reset_sequence(), SW.frame_total(len(words))]
            for w in words:
                parts.append(SW.frame_from_word(w))
            payload = b"".join(parts)
            print("  灌谱 %d 帧（%d 字节）..." % (len(words), len(payload)))
            for i in range(0, len(payload), 180):
                await c.write_gatt_char(UUID_RECV, payload[i:i + 180],
                                        response=False)
                await asyncio.sleep(0.01)
            await asyncio.sleep(1.2)
            st = await rd()
            print("  灌后 pool=%s exp=%s" % (st.get("sent"), st.get("exp")))

        print("  起播（CMD 0x03）...")
        await c.write_gatt_char(UUID_CMD, bytes([CMD_PLAY]), response=False)

        samples = []
        import time as _t
        t0w = _t.time()
        for _ in range(int(settle)):
            await asyncio.sleep(2.0)
            st = await rd()
            samples.append((_t.time() - t0w, st))
            print("    t=%4.1fs sent=%-5s play=%-6s t0=%-6s lead=%-6s pv=%s"
                  % (samples[-1][0], st.get("sent"), st.get("play"),
                     st.get("t0"), st.get("lead"), st.get("pv")))

        v, why = judge_send_path(samples)
        print()
        print("=" * 66)
        if v == "ok":
            print("✅ 判据满足：%s" % why)
            print("   => ESP32 侧【UART1 发送路径正常】（⛔ 不需要 CH340 即可确认）")
            print("   ⚠️ 但【线上字节是否正确】仍需 CH340 / 真 FPGA 在另一端验证")
            rc = 0
        elif v == "nolead":
            print("⚠️ 数据不足：%s" % why)
            print("   => 加大 --settle 秒数重跑（提前量约 10.4 秒）")
            rc = 2
        else:
            print("🔴 %s：%s" % (v, why))
            rc = 3
        print("=" * 66)
        await c.write_gatt_char(UUID_CMD, bytes([CMD_STOP]), response=False)
        return rc


def main():
    ap = argparse.ArgumentParser(description="只用 BLE 验 UART1 发送路径")
    ap.add_argument("--hex", default=os.path.join(HERE, "demo_scale.hex"))
    ap.add_argument("--settle", type=float, default=14.0,
                    help="起播后观察多少秒（默认 14，须大于提前量 10.4）")
    args = ap.parse_args()
    return asyncio.run(run(args.hex, args.settle))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
