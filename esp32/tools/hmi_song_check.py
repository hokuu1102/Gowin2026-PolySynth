#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hmi_song_check.py —— ⭐ 验证 CMD `0x22`（设置曲谱名）与 `hmi_set_song()` 的净化

═══ 背景 ═══
🔴 实测发现 `hmi_set_song()` **全工程零调用**
⇒ ⭐ `s_c.song` 永远是初值 `----` ⇒ 🔴 **屏上曲名 `g0` 永远显示 `----`**。
⚠️ 而 9 字节事件帧里没有曲名字段 ⇒ ⭐ 曲名**只能由 PC 另外下发**
⇒ ⭐ 新增 CMD `0x22`（⭐ 用户 2026-10-01 裁定）。

═══ 验什么 ═══
  ① ⭐ 正常名字能显示（⭐ 屏回 `p<名字>`）
  ② ⭐ **空 payload** ⇒ 回落成 `----`（⛔ 不是空字符串）
  ③ ⭐⭐ **含双引号的名字** ⇒ 🔴 **必须被净化掉** ——
     ⚠️ 否则 `g0.txt="a"b"` 会被 TJC 当成**两条命令**（⭐ 后一条是垃圾）
  ④ ⭐ 含控制字符（⭐ 尤其 `0x0D`/`0x0A`）⇒ 同样净化

═══ 用法 ═══
    python hmi_song_check.py --selftest     # ⛔ 不需要硬件
    python hmi_song_check.py                # 真机（⚠️ 需要屏接好 + 板子在广播）
"""

import argparse
import os
import re
import sys

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

import serial
from bleak import BleakClient, BleakScanner


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")


CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
LOG_PORT = "COM29"
RX_RE = re.compile(r"screen -> ESP32: \d+ B .*?\[([0-9A-Fa-f ]+)\]")


def sanitize(name):
    """
    ⭐ **Python 侧镜像** C 里 `hmi_set_song()` 的净化规则。

    ⚠️ 为什么要在测试里**重写一遍**（⛔ 而不是"相信固件"）：
       ⭐ 测试要能**独立算出期望值** ⇒ ⭐ 才能判定固件对不对。
       ⚠️ 若测试直接抄固件的输出当期望，⭐ 那就是**自证**（⭐ 见 `C83` 探针假绿）。

    ⭐ 规则（⭐ 与 `hmi.c` 必须一致）：
       · 丢掉 `"` · 丢掉 `\\` · 丢掉 `0x7F` · 丢掉所有 `< 0x20` 的控制字符
       · 其余原样保留（⭐ 含 UTF-8 多字节，其字节都 ≥ 0x80）
       · 净化后为空 ⇒ `----`
    """
    if not name:
        return "----"
    out = bytearray()
    for b in name.encode("utf-8"):
        if b in (0x22, 0x5C, 0x7F) or b < 0x20:
            continue
        out.append(b)
    if not out:
        return "----"
    return out.decode("utf-8", "replace")


class LogReader:
    def __init__(self, ser):
        self.ser = ser
        self.buf = bytearray()

    def pump(self):
        try:
            n = self.ser.in_waiting
            if n:
                self.buf.extend(self.ser.read(n))
        except Exception:
            pass

    def replies(self):
        txt = self.buf.decode("utf-8", "replace")
        out = []
        for m in RX_RE.finditer(txt):
            try:
                out.append(bytes(int(x, 16) for x in m.group(1).split()))
            except ValueError:
                pass
        return out


async def get_txt(c, lg, ctrl, wait=2.5):
    """
    ⭐ 发 `get <ctrl>.txt`，从【串口日志】读回（🔴 回包不走 BLE）。

    🔴🔴 **必须【累积】多段回复，⛔ 不能只取最后一段**
    -----------------------------------------------------------------------
    ⚠️ 实测踩过（2026-10-01）：⭐ 曲名用例 ⑦（60 个 A）实测只有 **31** 个 A，
       🔴 我差点判定"固件截断了"。
    ⭐ 真因：⭐ 固件的 RX 读缓冲是 **`uint8_t buf[32]`**（见 `hmi.c` 的
       `hmi_poll_rx`）⇒ ⭐ 一条长回复会被**拆成多行日志**
       ⇒ ⚠️ 只取最后一段 ⇒ 🔴 **测量结果被截断**（⭐ 固件本身没错）。
    ⭐ 判据：⭐ 回复以 **`FF FF FF` 结束** ⇒ ⭐ 就一直拼到看见它为止。
    📌 同族：`C139`（⭐ 显示没变 ≠ 值没设）—— ⭐ 都是**测量层**的误判。
    """
    import asyncio as _a
    lg.pump()
    before = len(lg.replies())
    await c.write_gatt_char(CMD, bytes([0x21]) + ("get %s.txt" % ctrl).encode(),
                            response=False)
    acc = bytearray()
    t0 = _a.get_event_loop().time()
    while _a.get_event_loop().time() - t0 < wait:
        lg.pump()
        r = lg.replies()
        for chunk in r[before:]:
            acc.extend(chunk)
            if acc.endswith(b"\xff\xff\xff"):
                b = bytes(acc[:-3])
                if b[:1] == b"p":
                    b = b[1:]
                return b.decode("utf-8", "replace")
        before = len(r)
        await _a.sleep(0.1)
    if acc:
        b = bytes(acc)
        if b.endswith(b"\xff\xff\xff"):
            b = b[:-3]
        if b[:1] == b"p":
            b = b[1:]
        return b.decode("utf-8", "replace") + "  ⚠️(未见结束符)"
    return None


async def run():
    import asyncio

    ser = serial.Serial()
    ser.port = LOG_PORT
    ser.baudrate = 115200
    ser.timeout = 0.05
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.setDTR(False)
    ser.setRTS(False)
    ser.reset_input_buffer()
    lg = LogReader(ser)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=12)
    if dev is None:
        print("🔴 没找到 %s" % DEV)
        ser.close()
        return 3

    fails = []
    print("=" * 74)
    print("CMD 0x22（设曲名）验证")
    print("=" * 74)

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.2)

        async def case(label, payload, expect=None):
            """⭐ 发一条 `0x22`，读回 `g0.txt`，与【独立算出的期望】比对。"""
            want = sanitize(payload) if expect is None else expect
            await c.write_gatt_char(CMD, bytes([0x22]) + payload.encode("utf-8"),
                                    response=False)
            await asyncio.sleep(0.9)          # ⭐ 等 hmi_task（200 ms 周期）下发
            got = await get_txt(c, lg, "g0")
            ok = (got == want)
            print("  %-34s 期望 %-12s 实测 %-12s %s"
                  % (label, repr(want), repr(got), "OK " if ok else "RED"))
            if not ok:
                fails.append("%s: 期望 %r，实测 %r" % (label, want, got))
            return ok

        # ① ⭐ 正常 ASCII 名字
        await case("① ASCII 名字", "Canon in D")
        # ② ⭐ 中文名字（⭐ 验证 UTF-8 多字节不被误杀）
        await case("② 中文名字", "卡农")
        # ③ ⭐⭐ 含双引号 ⇒ 🔴 必须净化（⭐ 否则 TJC 命令会被截断）
        await case("③ 含双引号（⭐ 关键）", 'a"b')
        # ④ ⭐ 含控制字符 ⇒ 净化
        await case("④ 含控制字符", "x\r\ny")
        # ⑤ ⭐ 空 payload ⇒ 回落 ----
        await case("⑤ 空 payload", "")
        # ⑥ ⭐ 纯非法字符 ⇒ 净化后为空 ⇒ ----
        await case("⑥ 纯非法字符", '"""')
        # ⑦ ⭐ 长名字（⭐ 验证截断到 song[40] 不越界）
        await case("⑦ 长名字（>39 B）", "A" * 60, expect="A" * 39)

        # ⭐ 收尾：设回一个正常名字
        await c.write_gatt_char(CMD, bytes([0x22]) + "ESP32".encode(),
                                response=False)
        await asyncio.sleep(0.6)

    ser.close()
    print()
    print("=" * 74)
    if not fails:
        print("结论：曲名通路全部正确 ✅")
    else:
        print("结论：%d 项不符 🔴" % len(fails))
        for f in fails:
            print("   - %s" % f)
    print("=" * 74)
    return 0 if not fails else 1


def selftest():
    print("=" * 74)
    print("hmi_song_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-48s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 净化规则 ----
    chk("普通名字原样", sanitize("Canon in D") == "Canon in D")
    chk("中文原样（UTF-8 不被误杀）", sanitize("卡农") == "卡农")
    chk("⭐ 双引号被丢掉", sanitize('a"b') == "ab")
    chk("⭐ 反斜杠被丢掉", sanitize("a\\b") == "ab")
    chk("⭐ 控制字符被丢掉", sanitize("x\r\ny") == "xy")
    chk("⭐ 0x7F 被丢掉", sanitize("a\x7fb") == "ab")
    chk("空 ⇒ ----", sanitize("") == "----")
    chk("纯非法 ⇒ ----", sanitize('"""') == "----")
    chk("None ⇒ ----", sanitize(None) == "----")

    # ⭐ 长度：⭐ C 侧是 `song[40]` ⇒ 最多 39 字节 + NUL
    long39 = "A" * 39
    chk("39 字节原样保留", sanitize(long39) == long39)

    # ---- ② ⭐⭐ 关键：净化必须【真的能改变结果】（非空洞性）----
    #   ⚠️ 若某条规则写错了但样本里没有该字符 ⇒ 检查永远绿 ⇒ 假绿
    chk("⭐⭐ 非空洞：双引号样本确实会变", sanitize('a"b') != 'a"b')
    chk("⭐⭐ 非空洞：控制字符样本确实会变", sanitize("x\r\ny") != "x\r\ny")
    chk("⭐⭐ 非空洞：纯非法样本确实会变", sanitize('"""') != '"""')

    # ---- ③ 与 C 源码的规则一致性（⭐ 防"两边规则漂了"）----
    here = os.path.dirname(os.path.abspath(__file__))
    src_path = os.path.join(here, "..", "ble", "main", "hmi.c")
    try:
        with open(src_path, "r", encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError as e:
        chk("读到 hmi.c", False, "  %s" % e)
        print()
        print("结论：有失败项")
        return 1
    chk("读到 hmi.c", len(src) > 1000, "  %d 字符" % len(src))
    # ⭐ C 侧净化循环里必须同时出现这四个判据
    for pat, label in ((r'\*q\s*==\s*\'"\''  , '双引号'),
                       (r"\*q\s*==\s*'\\\\'", '反斜杠'),
                       (r"\*q\s*==\s*0x7F"  , '0x7F'),
                       (r"\*q\s*<\s*0x20"   , '控制字符')):
        chk("hmi.c 净化含判据：%s" % label, re.search(pat, src) is not None)
    chk("hmi.c 里有 hmi_set_song 的净化块", "clean[k++]" in src)
    # ⭐ 反例：⭐ 编一个不存在的判据必须找不到
    chk("反例：hmi.c 不含 0x99 判据", "0x99" not in src)

    # ---- ④ ⭐ 曲名命令确实被接线（⭐ 防"命令加了但没人调"）----
    bl = os.path.join(here, "..", "ble", "main", "ble_main.c")
    try:
        with open(bl, "r", encoding="utf-8", errors="replace") as f:
            bsrc = f.read()
    except OSError as e:
        chk("读到 ble_main.c", False, "  %s" % e)
        print()
        print("结论：有失败项")
        return 1
    chk("⭐ ble_main.c 有 case 0x22", re.search(r"case\s+0x22\s*:", bsrc)
        is not None)
    # ⭐⭐ 关键：`case 0x22` 里必须**真的调用** `hmi_set_song`（⭐ 否则又是死代码）
    m = re.search(r"case\s+0x22\s*:(.*?)\n\s*case\s", bsrc, re.S)
    chk("⭐⭐ case 0x22 里确实调用了 hmi_set_song",
        m is not None and "hmi_set_song(" in m.group(1))
    # ⭐ 反例：⭐ 确认 grep 手法本身能失败
    chk("反例：case 0x99 不存在", re.search(r"case\s+0x99\s*:", bsrc) is None)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="验证 CMD 0x22 设曲名 + 净化")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    import asyncio
    return asyncio.run(run())


if __name__ == "__main__":
    sys.exit(main())
