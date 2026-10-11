#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
stat_read.py —— ⭐ 读 ESP32 的 `0xABF4`(STAT) 并**逐字段核对**

═══ 用途 ═══
⭐ 走 BLE 发 `CMD 0x02`（请求上报）→ ⭐ 读 `0xABF4` → ⭐ 解析 `key=value` 多行 → 打印

═══ 为什么需要它 ═══
🔴 `0xABF4` 是**【只读】**属性（`ESP_GATT_RSP_BY_APP`）——
⚠️ 固件**不能 notify**，⭐ 客户端必须**主动读**。
⇒ ⭐ 所以"上报状态"这条命令**只有配上读取才算闭环**。

═══ 用法 ═══
    python stat_read.py                 # 连 BLE → 发 0x02 → 读 → 打印
    python stat_read.py --selftest      # ⛔ 不需要硬件
    python stat_read.py --json          # 输出 JSON（⭐ 便于脚本消费）
"""

import argparse
import asyncio
import json
import re
import sys

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

DEV_NAME = "FPGA2026-Synth"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"

# ⭐ 期望出现的分组（⭐ 与固件 `cmd_report_status()` 的格式串一一对应）
# ⚠️ 注意：⭐ 这里写的是**分组名**（⛔ 不带 `=`）——
#    ⭐ 解析器把 `pool=...` 拆成 `grp="pool"` + 内容 ⇒ ⚠️ 带上 `=` 会永远匹配不上
#    （🔴 我第一版就写错了，⭐ 自检 ① 立刻判红把它抓出来了 —— ⭐ 这正是自检的价值）
EXPECT_GROUPS = ("V1", "pool", "ring", "ble", "uart", "hmi", "frame", "cmd")

# ⭐ 每个分组里期望出现的键（⭐ 用来抓"格式串与参数表数量对不上"那类错）
# ⚠️ 同样**不带 `=`**（⭐ 解析后键名已剥掉 `=`）
EXPECT_KEYS = {
    "pool":  ("sent", "ovf", "late", "exp", "mm", "clamp", "run"),
    "ring":  ("in", "out", "drop", "full", "hwm"),
    "ble":   ("rx", "tx", "fail", "mtu", "conn", "sub"),
    "uart":  ("rx", "trig"),
    # ⭐ 2026-10-01：屏 → ESP32 诊断（⭐ 排查"屏有界面但数字不变"）
    # ⚠️ `tx` = 固件**发给屏**的命令数（⭐ 发送侧证据）
    #    ⇒ ⭐ 判读表：`tx` 涨 + 屏变 = 通；`tx` 涨 + 屏不变 = 屏没应用/没重绘；
    #       ⭐ `tx` 不涨 = 固件没走到（⭐ 见 `C139`）
    "hmi":   ("rx", "touch", "tx", "last"),
    "frame": ("total", "tf", "rst", "unk"),
    "cmd":   ("ok", "unk"),
}


def parse_stat(text):
    """
    ⭐ 把 `key=value` 多行文本解析成 dict。

    ⚠️ 返回值里：
      · `_groups` = ⭐ 出现过的分组名
      · `_raw`    = ⭐ 原文（⭐ 便于排查）
    """
    out = {"_groups": [], "_raw": text}
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith("V1"):
            out["_version"] = ln
            out["_groups"].append("V1")
            continue
        m = re.match(r"^([A-Za-z_]+)=(.*)$", ln)
        if not m:
            continue
        grp, rest = m.group(1), m.group(2)
        out["_groups"].append(grp)
        # ⭐ 分组内的 `k=v` 用空格分隔；⚠️ 有的值本身是 `a/b` 或 `rx123`
        for tok in rest.split():
            if "=" in tok:
                k, _, v = tok.partition("=")
                out["%s.%s" % (grp, k)] = v
            else:
                # ⭐ 形如 `rx123` / `ok2` ⇒ ⭐ 拆成 前缀=数字
                mm = re.match(r"^([A-Za-z_]+)(-?\d+)$", tok)
                if mm:
                    out["%s.%s" % (grp, mm.group(1))] = mm.group(2)
    return out


def check(d):
    """⭐ 返回 (是否通过, 问题列表)。"""
    problems = []
    for g in EXPECT_GROUPS:
        if g not in d["_groups"]:
            problems.append("缺分组：%s" % g)
    for grp, keys in EXPECT_KEYS.items():
        for k in keys:
            if not any(kk.startswith("%s.%s" % (grp, k)) for kk in d):
                problems.append("缺字段：%s.%s" % (grp, k))
    # ⭐⭐ 2026-10-01（C115 第二层）：⭐ `V1` 行必须带**陈旧可判定**的两个字段
    #    ⭐ `req=` = 第几次快照（⭐ 连读两次不变 ⇒ 数据是旧的）
    #    ⭐ `up=`  = 生成快照时的开机毫秒
    #    ⚠️ 没有它们 ⇒ 🔴 客户端**无法区分"此刻"与"上一次"**
    raw = d.get("_version", "") + d.get("_raw", "")
    for k in ("req=", "up="):
        if k not in raw:
            problems.append("V1 行缺 %s（⭐ 陈旧将不可判定）" % k)
    return (len(problems) == 0), problems


async def run(do_json, scan_to):
    from bleak import BleakClient, BleakScanner

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV_NAME, timeout=scan_to)
    if dev is None:
        print("RED: 没找到 %s（⚠️ 板子在广播吗？）" % DEV_NAME)
        return 2

    async with BleakClient(dev) as c:
        await asyncio.sleep(0.8)
        try:
            await c.write_gatt_char(UUID_CMD, bytes([0x02]), response=False)
        except Exception as e:
            print("RED: 发 CMD 0x02 失败：%s" % e)
            return 3
        await asyncio.sleep(1.0)          # ⚠️ 给固件一点时间组装
        try:
            raw = await c.read_gatt_char(UUID_STAT)
        except Exception as e:
            print("RED: 读 0xABF4 失败：%s" % e)
            return 3

    text = bytes(raw).decode("utf-8", "replace")
    if not text.strip():
        print("🔴 读回【空】 —— ⚠️ 检查固件是否把 STAT 改成了 RSP_BY_APP")
        return 1

    d = parse_stat(text)
    ok, problems = check(d)

    if do_json:
        print(json.dumps(d, ensure_ascii=False, indent=2))
    else:
        print("=" * 70)
        print("0xABF4 STAT 读回（%d 字节）" % len(text))
        print("=" * 70)
        print(text.rstrip())
        print("=" * 70)
        print("分组：%s" % ", ".join(d["_groups"]))
        print("字段数：%d" % len([k for k in d if not k.startswith("_")]))
        print()
        if ok:
            print("✅ 结构完整（八组 + 关键字段都在）")
        else:
            print("🔴 结构有问题：")
            for p in problems:
                print("   - %s" % p)

    return 0 if ok else 1


def selftest():
    """⭐ 离线自检：⭐ 解析 + 结构判据（⭐ 含反例）。"""
    print("=" * 70)
    print("stat_read.py 离线自检（⛔ 不需要硬件）")
    print("=" * 70)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    good = ("V1 mode=B req=7 up=12345ms\n"
            "pool=200/18204 sent=200 ovf=0 late=0 exp=200 mm=0 clamp=0 run=1\n"
            "ring=0/163840 in=2000 out=2000 drop=0/0 full=0 hwm=2000 PSRAM\n"
            "ble=rx1845 tx4000 fail=0 mtu=517 conn=1 sub=0\n"
            "uart=rx0 trig=0\n"
            # ⚠️ `hmi=` 行是 2026-10-01 加的（⭐ 排串口屏问题时要看它）
            #    ⇒ 🔴 **改固件的 STAT 格式时，必须同步这份样本**
            #    （⭐ 否则自检会红 —— ⭐ 这正是它该有的行为：⭐ 防止格式悄悄变）
            "hmi=rx629 touch=10 tx=37 last=0x65\n"
            "frame=total=200 tf=1 rst=4 unk=0\n"
            "cmd=ok2 unk1\n")
    d = parse_stat(good)
    chk("① 八组全在", check(d)[0], "  问题=%s" % (check(d)[1] or "无"))
    chk("① pool.sent = 200", d.get("pool.sent") == "200")
    chk("① ble.mtu = 517", d.get("ble.mtu") == "517")
    chk("① ble.rx = 1845（⭐ rx 无 = 号）", d.get("ble.rx") == "1845")
    chk("① cmd.ok = 2（⭐ ok 无 = 号）", d.get("cmd.ok") == "2")
    chk("① cmd.unk = 1", d.get("cmd.unk") == "1")
    chk("① ring 落位 = PSRAM", "PSRAM" in d["_raw"])

    # ⭐⭐ 反例：缺一组必须判红
    bad = good.replace("cmd=ok2 unk1\n", "")
    db = parse_stat(bad)
    chk("② 反例：删掉 cmd 组 ⇒ 判红", check(db)[0] is False)
    chk("② 反例问题里点名 cmd", any("cmd" in p for p in check(db)[1]))

    # ⭐⭐ 反例：空输入
    de = parse_stat("")
    chk("② 反例：空输入 ⇒ 判红", check(de)[0] is False)

    # ⭐⭐ 反例（C115 第二层）：⭐ V1 行去掉 req/up ⇒ **必须判红**
    #    ⚠️ 这条证明"陈旧可判定"这个要求**真的能失败**（⛔ 不是永远绿）
    no_req = good.replace(" req=7 up=12345ms", "")
    chk("② 反例：V1 去掉 req/up ⇒ 判红（⭐ 陈旧不可判定）",
        check(parse_stat(no_req))[0] is False)
    chk("② 反例问题里点名 req",
        any("req=" in p for p in check(parse_stat(no_req))[1]))

    # ⭐ 只留一行（⭐ 模拟"格式串写错、只回了半截"）
    half = "V1 mode=B\npool=1/2 sent=3 ovf=0 late=0 exp=0 mm=0 clamp=0 run=0\n"
    chk("② 反例：半截状态 ⇒ 判红", check(parse_stat(half))[0] is False)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="读 ESP32 0xABF4 STAT 并核对结构")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--scan-timeout", type=float, default=12.0)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return asyncio.run(run(args.json, args.scan_timeout))


if __name__ == "__main__":
    sys.exit(main())
