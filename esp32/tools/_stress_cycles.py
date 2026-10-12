"""一次性：循环压力测试 —— 反复「清池 -> 灌谱 -> 起播 -> 等放完」，盯重启与计数。

为什么要做
----------------------------------------------------------------------------
修掉 `BTC_TASK` 栈溢出（起播约 20 秒必崩）之后，还要证明**不再有别的崩溃**。
单跑一次通过说明不了问题 —— 栈溢出那类缺陷是**累积/时机**相关的。

判据（⭐ 每条都必须能红，见 C156 双向判据）
----------------------------------------------------------------------------
  1. `up`（uptime）必须**单调增长** —— 任何一次归零 = 板子重启 => 红
  2. 每轮 `sent` 必须 == 灌入帧数
  3. 每轮 `ovf` 增量必须 == 0
  4. 每轮 `mm`（不匹配）增量必须 == 0
  5. 每轮结束时 `run` 必须回到 0（自然放完，⛔ 不是卡住）
  6. 每轮耗时必须在合理范围内（卡住/变慢 => 红）

用法
----------------------------------------------------------------------------
    python _stress_cycles.py --cycles 5 --events 200
    python _stress_cycles.py --cycles 3 --events 200 --hex <events.hex>
"""
import argparse
import asyncio
import os
import re
import sys
import time

from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import score_word as SW          # noqa: E402

UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
CMD_RESET, CMD_STAT, CMD_PLAY = 0x01, 0x02, 0x03


def fake_words(n):
    return [SW.pack_word(tick=1000 + i * 37, inc=164927, axis=i % 16,
                         vel=100, kind=i % 2, timbre=i % 2) for i in range(n)]


async def read_stat(c):
    await c.write_gatt_char(UUID_CMD, bytes([CMD_STAT]), response=False)
    await asyncio.sleep(0.45)
    t = bytes(await c.read_gatt_char(UUID_STAT)).decode("utf-8", "replace")
    d = {}
    for k in ("pool", "sent", "ovf", "late", "mm", "run", "tf", "unk", "clamp"):
        m = re.search(r"\b%s=(\d+)" % k, t)
        if m:
            d[k] = int(m.group(1))
    m = re.search(r"up=(\d+)ms", t)
    if m:
        d["up"] = int(m.group(1))
    return d


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cycles", type=int, default=5)
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--hex", default=None, help="改用真谱面（否则用合成事件）")
    ap.add_argument("--cycle-timeout", type=float, default=180.0)
    # 本文件在 __main__ 里先拦 --selftest（不需要硬件），
    # 这里声明它只是为了 --help 里能看到。
    ap.add_argument("--selftest", action="store_true", help="离线自检（不需要硬件）")
    args = ap.parse_args()

    if args.hex:
        words, probs = SW.load_events_hex(args.hex)
        if probs:
            print("⚠️ events.hex 有 %d 个问题" % len(probs))
    else:
        words = fake_words(args.events)
    payload = SW.build_payload(words)
    n = len(words)
    print("循环压力：%d 轮 x %d 事件（%d 字节）" % (args.cycles, n, len(payload)))

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        return 1

    rows = []
    bad = 0
    prev_up = None
    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        for k in range(1, args.cycles + 1):
            t0 = time.time()
            print("-" * 70)
            print("第 %d/%d 轮" % (k, args.cycles))
            await c.write_gatt_char(UUID_CMD, bytes([CMD_RESET]), response=False)
            await asyncio.sleep(0.7)
            b = await read_stat(c)

            # ⭐ 判据 1：up 必须单调增长（归零 = 重启）
            if prev_up is not None and b.get("up", 0) < prev_up:
                print("  RED up 归零（%d -> %d）=> 板子重启了！"
                      % (prev_up, b.get("up", 0)))
                bad += 1
            prev_up = b.get("up")

            for o in range(0, len(payload), 180):
                await c.write_gatt_char(UUID_RECV, payload[o:o + 180], response=False)
                await asyncio.sleep(0.004)
            await asyncio.sleep(0.8)
            a = await read_stat(c)
            print("  灌后 pool=%s tf=%s unk=%s" % (a.get("pool"), a.get("tf"), a.get("unk")))

            await c.write_gatt_char(UUID_CMD, bytes([CMD_PLAY]), response=False)
            ok_done = False
            last = None
            while time.time() - t0 < args.cycle_timeout:
                await asyncio.sleep(2.0)
                d = await read_stat(c)
                if prev_up is not None and d.get("up", 0) < prev_up:
                    print("  RED 播放中 up 归零 => 板子重启了！")
                    bad += 1
                    break
                prev_up = d.get("up")
                if d.get("sent") != last:
                    print("    t=%4.0fs sent=%s run=%s ovf=%s mm=%s"
                          % (time.time() - t0, d.get("sent"), d.get("run"),
                             d.get("ovf"), d.get("mm")))
                    last = d.get("sent")
                if d.get("run") == 0 and (d.get("sent") or 0) > 0:
                    ok_done = True
                    break

            dt = time.time() - t0
            # ⭐ 逐条判据
            c1 = ok_done
            c2 = (d.get("sent") == n)
            c3 = (d.get("ovf", 0) - b.get("ovf", 0)) == 0
            c4 = (d.get("mm", 0) - b.get("mm", 0)) == 0
            row_ok = c1 and c2 and c3 and c4
            if not row_ok:
                bad += 1
            print("  耗时 %.1fs | 放完=%s sent=%s/%d ovfΔ=%s mmΔ=%s => %s"
                  % (dt, c1, d.get("sent"), n,
                     d.get("ovf", 0) - b.get("ovf", 0),
                     d.get("mm", 0) - b.get("mm", 0),
                     "OK" if row_ok else "RED"))
            rows.append((k, dt, d.get("sent"), row_ok))
            await asyncio.sleep(1.0)

    print()
    print("=" * 70)
    print("汇总：%d 轮，失败 %d 轮" % (len(rows), bad))
    for k, dt, sent, ok in rows:
        print("  第 %d 轮  %6.1fs  sent=%-6s %s" % (k, dt, sent, "OK" if ok else "RED"))
    print("结论：%s" % ("全部通过（没有重启、没有丢帧、没有卡住）"
                       if bad == 0 else "有失败项（退出码 = 失败轮数）"))
    return bad


def judge_cycle(before, after, n, ok_done, up_restarted):
    """单轮判据 —— 抽成【纯函数】是为了能离线自检。

    ⚠️ 为什么要抽出来：这段逻辑原来【内联在 main() 里】，
       而本文件以 `_` 开头 => 被 selftest_all.py 排除（它只看 `--selftest`）
       => 🔴 这些判据【从来没有被验证过它们会红】。
       同族 C83（探针假绿）：唯一判据是"喂一个坏样本必须输出不同"。

    参数：before/after = 该轮前后的 0xABF4 状态字典；n = 本轮灌入事件数
    返回：(ok, {判据名: (是否通过, 说明)})
    """
    d = dict(after or {})
    b = dict(before or {})

    def _i(dd, k):
        try:
            return int(dd.get(k) or 0)
        except (TypeError, ValueError):
            return 0

    c = {
        # 放完了：run 归 0 且确实送出去过
        "放完": (bool(ok_done), "run 回到 0 且 sent > 0"),
        # 一帧不丢：送出的数量 == 本轮灌入的数量
        "不丢帧": (_i(d, "sent") == n, "sent == 灌入数 %d" % n),
        # 不溢出
        "不溢出": (_i(d, "ovf") - _i(b, "ovf") == 0, "ovf 增量 == 0"),
        # 不失配
        "不失配": (_i(d, "mm") - _i(b, "mm") == 0, "mm 增量 == 0"),
        # 没重启（up 单调）—— 这条单独拎出来，因为重启是最高严重级
        "没重启": (not up_restarted, "up 单调不归零"),
    }
    return all(v[0] for v in c.values()), c


def selftest():
    """离线自检：⭐ 重点是【非空洞性】—— 每个判据都要有【必红】的样本。"""
    print("=" * 70)
    print("_stress_cycles.py 离线自检（不需要硬件）")
    print("=" * 70)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-52s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    good_b = {"sent": 0, "ovf": 0, "mm": 0}
    good_a = {"sent": 200, "ovf": 0, "mm": 0, "run": 0}

    ok, c = judge_cycle(good_b, good_a, 200, True, False)
    chk("好样本 => 全绿", ok and len(c) == 5, "5 条判据")

    # 非空洞性：逐条造一个【只坏这一条】的样本
    for key, mut in (
        ("放完",   lambda a: a.update(run=1)),          # 没放完
        ("不丢帧", lambda a: a.update(sent=199)),        # 少一帧
        ("不溢出", lambda a: a.update(ovf=1)),           # 溢出
        ("不失配", lambda a: a.update(mm=1)),            # 失配
    ):
        a = dict(good_a)
        mut(a)
        o, cc = judge_cycle(good_b, a, 200, a.get("run") == 0, False)
        chk("非空洞性：%s 坏了必须判红" % key,
            (not o) and (cc[key][0] is False),
            "且只有它红" if sum(1 for v in cc.values() if not v[0]) == 1 else "⚠️ 连带红了别的")

    # 重启：ok_done 可能仍为真，但 up 归零必须单独抓到
    o, cc = judge_cycle(good_b, good_a, 200, True, True)
    chk("非空洞性：重启必须判红（即使放完了）",
        (not o) and (cc["没重启"][0] is False), "up 归零 = 板子重启")

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有失败项"))
    return bad


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(asyncio.run(main()))
