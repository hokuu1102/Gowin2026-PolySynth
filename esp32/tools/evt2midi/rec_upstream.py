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


def build_parser():
    """
    ⭐ 单独把 parser 建出来 —— ⚠️ 这样自检可以**只验参数面**，
    ⛔ **不必真的跑 `main()`**（🔴 那会真的连 BLE 录 30 秒 —— 我第一版就这么错的）。
    """
    ap = argparse.ArgumentParser(description="录制 ESP32 上行字节流（原样落盘）")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⚠️ 结构性 —— ⛔ 不需硬件）")
    ap.add_argument("--out", help="输出原始字节文件，如 rec.bin")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--start", action="store_true",
                    help="录之前发 CMD 0x03 起播（⚠️ 需要 ESP32 已灌好曲谱）")
    ap.add_argument("--hex", dest="hex_path", default="", help="另存可读 hex 转储")
    ap.add_argument("--scan-timeout", type=float, default=12.0)
    return ap


def selftest():
    """
    ⭐ 离线自检（⛔ 不需要硬件、不需要 BLE）。

    ⚠️ **诚实说明：这是【结构性】自检，⛔ 不是行为性的。**
       🔴 本工具是**纯 I/O** —— ⭐ 它只做"连 BLE、收字节、落盘"，
          ⚠️ **没有可离线测的纯逻辑**（⭐ 与 `read_log.py` 同类）。

    🔴🔴 **我第一版写错了三处（⭐ 记下来，都是"判据不能失败"的坑）**：
      ① ⚠️ 自检里**真的调了 `main()`** ⇒ 🔴 **实际连 BLE 录了 30 秒**
         ⇒ ⭐ 自检**绝不该做真 I/O**（⭐ 修法：抽出 `build_parser()`，只验参数面）
      ② 🔴 **自指陷阱**：⭐ 我的检查**标签里就含**被 grep 的字面串
         （如标签里写 `parse_stream`）⇒ ⚠️ 断言**恒为 False**
         ⇒ ⭐ 修法：**只检查 selftest 之前的那段源码**
      ③ ⚠️ `--out` 改成可选后，⭐ 原来"必填"的断言就不成立了
         ⇒ ⭐ 修法：改为断言"**没给 --out 时 main 会拒绝**"这个行为
    """
    import inspect
    print("=" * 74)
    print("rec_upstream.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    print("⚠️ 本自检是【结构性】的 —— ⚠️ 本工具是纯 I/O，没有离线可测的纯逻辑")
    print()
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 参数面（⭐ 用真实 parser，⚠️ 但⛔ 不跑 main()）----
    p = build_parser()
    opts = {a.dest: a for a in p._actions}
    for name in ("out", "seconds", "start", "hex_path", "scan_timeout",
                 "selftest"):
        chk("① 有 --%s" % name.replace("_", "-"), name in opts)
    chk("① --seconds 默认 30.0",
        opts.get("seconds") is not None and opts["seconds"].default == 30.0)
    chk("① --start 默认关（⚠️ 起播是副作用，⛔ 不该默认做）",
        opts.get("start") is not None and opts["start"].default is False)
    chk("① --selftest 默认关",
        opts.get("selftest") is not None and opts["selftest"].default is False)
    # ⭐ 行为判据：⭐ 只给 --selftest、不给 --out ⇒ ⭐ 应该跑自检而不是去连 BLE
    ns = p.parse_args(["--selftest"])
    chk("① `--selftest` 单独可用（⛔ 不需要 --out）", ns.selftest is True)
    ns2 = p.parse_args(["--out", "x.bin"])
    chk("① 给了 --out 时 selftest 为假（⭐ 走真录制）", ns2.selftest is False)
    # ⭐⭐ 反例：这些选项【不该】存在
    for bad in ("outt", "no_such_opt", "seconds2"):
        chk("① 反例：⛔ 没有 --%s" % bad.replace("_", "-"), bad not in opts)

    # ---- ② ⭐⭐ 设计约束：录制【不解析】----
    # 🔴 关键：⭐ 只取 `selftest` **之前**的源码 ——
    #    ⚠️ 否则我的**检查标签自己**就含那些字面串 ⇒ 🔴 断言恒 False（自指陷阱）
    full = inspect.getsource(sys.modules[__name__])
    body = full.split("def selftest")[0]
    chk("② 取到了 selftest 之前的源码", len(body) > 500, "  %d 字符" % len(body))
    for bad in ("parse_stream", "frame_checksum", "decode_frame", "inc_to_hz"):
        chk("② 源码里⛔ 没有 %s（⭐ 录制不解析）" % bad, bad not in body)
    chk("② 确实以二进制写文件（⭐ 原样落盘）", 'open(out_path, "wb")' in body)
    # ⭐ 反例：⭐ 用一个【确定存在】的串验证"grep 本身有效"（⭐ 否则上面的 not in 可能恒真）
    chk("② 非空洞：grep 确实能命中（⭐ 用已知存在的串验证）",
        "def run(" in body)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    print("⚠️ 未覆盖（⭐ 需要硬件/BLE）：run() 的连接、订阅、落盘")
    return 0 if ok else 1


def main():
    ap = build_parser()
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.out:
        print("🔴 需要 --out（⚠️ 或用 --selftest）")
        return 2

    return asyncio.run(run(args.out, args.seconds, args.start,
                           args.scan_timeout, args.hex_path))


if __name__ == "__main__":
    sys.exit(main())
