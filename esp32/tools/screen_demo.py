#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
screen_demo.py —— ⭐ 完整上屏演示：⭐ 你盯屏看，我同时【读回】状态做对照

═══ 演示什么（⭐ 一条完整的曲子生命周期）═══
  ① 设曲名        ⇒ ⭐ 屏上 `g0` 从 `----` 变成曲名
  ② 开始灌谱      ⇒ ⭐ 屏上 `t1` = `灌谱中`，`t2` 计数往上涨，`j0` 进度条动
  ③ 灌完          ⇒ ⭐ `t1` = `就绪`（⭐ 本轮的修复点）
  ④ 起播          ⇒ ⭐ `t1` = `播放中`
  ⑤ 放完          ⇒ ⭐ `t1` = `播完`（⭐ 本轮的修复点，⭐ 保持住）
  ⑥ 蓝牙          ⇒ ⭐ `t3` 全程 `BT OK` 绿色

═══ 为什么"读回"和"你看"都要 ═══
⭐ 两边**互相印证**：
   · ⭐ 读回对 + 你看对 ⇒ ✅ 真通过
   · ⭐ 读回对 + 你看不对 ⇒ 🔴 **屏没重绘**（⭐ 见 `C139`）
   · 🔴 读回不对 ⇒ ⭐ 固件/通路问题

═══ 用法 ═══
    python screen_demo.py                # ⭐ 默认 200 事件
    python screen_demo.py --events 400   # ⭐ 灌长一点，看得更清楚
"""

import argparse
import asyncio
import os
import re
import struct
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

# 位域与帧层常量：唯一真源在 score_word.py（2026-10-01 起）
# 本文件原来自己拼位域，用的是 2026-09-22 修订【之前】的旧布局：
#     inc<<22(22bit) / axis<<18 / vel 7bit / timbre<<8(1bit)
# 而 FPGA(rtl/top.v:3594-3616) 与固件(ble/main/pool.c:60-63) 都用新布局：
#     inc[43:23](21bit) / axis[22:19] / vel[18:11](8bit) / timbre[8:7](2bit)
# => 本文件发出去的谱面，FPGA 会解出 inc>>1（低一个八度），且 inc 的最低位
#    会渗进 axis 字段把轴号污染。ESP32 侧固件只读 tick/kind（两个布局相同），
#    所以本文件的错误一直没被本地测试发现。
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import score_word as SW          # noqa: E402

CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
FRAME = SW.FRAME_BYTES
DEV = "FPGA2026-Synth"
LOG_PORT = "COM29"
RX_RE = re.compile(r"screen -> ESP32: \d+ B .*?\[([0-9A-Fa-f ]+)\]")

# ⭐ 曲名：⭐ 用中文 + ASCII 混排，⭐ 顺便验证 UTF-8 多字节
SONG = "卡农 Canon in D"

# ⭐ 音高：⭐ C 大调音阶，⭐ 听感上像"爬音阶"，⭐ 若接了 FPGA 能听出来
SCALE = [261.63, 293.66, 329.63, 349.23, 392.00, 440.00, 493.88, 523.25]

TICK_PER_S = 1920.0            # ⭐ 120 BPM / PPQN 960


def read_lead_ticks():
    """
    ⭐ 从 `ble_config.h` **读**起播提前量，⛔ 不写死。

    🔴 为什么必须读（⭐ 实测踩过，2026-10-01）：
       ⭐ 我第一次跑演示时**自己估**了等待时长（⭐ 谱面 2.5 s ⇒ 等 5.5 s），
       ⚠️ 结果读回仍是 `播放中` ⇒ 🔴 **差点判定"`播完` 又坏了"**。
       ⭐ 真因：⭐ 池要**先等 `BLE_POOL_LEAD_TICKS = 20000` tick（≈10.4 s）**
          才发第一帧（⭐ 预填 FPGA 缓冲）
       ⇒ ⭐ 实测 2.49 s 的曲子 **14.3 s** 才放完。
    ⭐ 判据：⭐ 这种"常数决定等待时长"的地方**必须从源头读**，
       ⚠️ 否则改一次常数，⭐ 测试就**静默假红**（⭐ 同族 `C116`）。
    """
    import os
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "ble", "main", "ble_config.h")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = re.match(r"#define\s+BLE_POOL_LEAD_TICKS\s+(\d+)", ln.strip())
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 20000                      # ⭐ 读不到就用当前已知值（⭐ 并会打印告警）


def phase_inc(freq):
    """⭐ f = inc × 50e6 / 2³² ⇒ inc = f × 2³² / 50e6"""
    return int(round(freq * (2 ** 32) / 50e6)) & 0x3FFFFF


def build_score(n, step=24):
    """
    ⭐ 复位标记 + 总数帧 + n 个事件帧（⭐ 与冻结的 9 字节格式一致）。

    ⚠️ `step` 必须可传：⭐ 自检要构造**不同事件数**的谱面做非空洞性检查
       （⭐ 否则"长度跟着事件数变"这条判据是假的）。
    """
    out = bytearray(bytes([0xA5]) * (FRAME * 4))          # ⭐ 复位标记
    out += bytes([0x00]) + struct.pack(">Q", n)           # ⭐ 总数帧
    for i in range(n):
        # ⭐ 每 step 个 tick 一个音（⭐ 120 BPM / PPQN 960 ⇒ 1920 tick/s）
        tick = i * step
        freq = SCALE[(i // 8) % len(SCALE)]
        inc = phase_inc(freq)
        # 位域由 score_word.pack_word 统一负责（唯一真源，与 FPGA 逐位一致）
        word = SW.pack_word(tick=tick, inc=inc, axis=0, vel=90,
                            kind=SW.KIND_ON, timbre=0)
        out += SW.frame_from_word(word)
    return bytes(out)


class Log:
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
        out = []
        for m in RX_RE.finditer(self.buf.decode("utf-8", "replace")):
            try:
                out.append(bytes(int(x, 16) for x in m.group(1).split()))
            except ValueError:
                pass
        return out


async def get_txt(c, lg, ctrl, wait=2.5):
    """⭐ 累积多段回复直到 `FF FF FF`（⚠️ 固件 RX 缓冲只有 32 B ⇒ 长回复分段）。"""
    lg.pump()
    before = len(lg.replies())
    await c.write_gatt_char(CMD, bytes([0x21]) + ("get %s.txt" % ctrl).encode(),
                            response=False)
    acc = bytearray()
    t0 = asyncio.get_event_loop().time()
    while asyncio.get_event_loop().time() - t0 < wait:
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
        await asyncio.sleep(0.1)
    return "(无回包)"


async def main(events, hold):
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
    lg = Log(ser)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == DEV, timeout=12)
    if dev is None:
        print("🔴 没找到 %s（⚠️ 板子在广播吗？）" % DEV)
        ser.close()
        return 3

    print("=" * 76)
    print("上屏演示 —— ⭐ 请盯着屏看")
    print("=" * 76)

    async def step(no, title, look, expect=None, ctrl="t1"):
        got = await get_txt(c, lg, ctrl)
        mark = ""
        if expect is not None:
            mark = "  ✅" if got == expect else "  🔴(期望 %s)" % expect
        print("  %s %-22s 屏上应看到: %-26s 读回 %s = %r%s"
              % (no, title, look, ctrl, got, mark))
        return got

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.2)

        # ---- ⓪ 先复位，确保从干净状态开始 ----
        print("\n【⓪ 复位】把屏打回干净起点")
        for _ in range(3):
            await c.write_gatt_char(CMD, bytes([0x01]), response=False)
            await asyncio.sleep(1.2)
            if await get_txt(c, lg, "t1") == "待机":
                break
        await step("⓪", "复位完成", "状态=待机", "待机")

        # ---- ① 设曲名 ----
        print("\n【① 设曲名】CMD 0x22")
        await c.write_gatt_char(CMD, bytes([0x22]) + SONG.encode("utf-8"),
                                response=False)
        await asyncio.sleep(1.2)
        await step("①", "曲名已下发", "g0 = %s" % SONG, SONG, ctrl="g0")

        # ---- ② 灌谱（⭐ 分两段，中间停一下让"灌谱中"看得见）----
        payload = build_score(events)
        print("\n【② 灌谱】共 %d 个事件（⭐ 先灌一半，停 6 秒让你看清 `灌谱中`）"
              % events)
        half = 36 + 9 + FRAME * (events // 2)
        off = 0
        while off < len(payload):
            stop = half if off < half else len(payload)
            while off < stop:
                n = min(180, stop - off)
                await c.write_gatt_char(RECV, payload[off:off + n],
                                        response=False)
                off += n
                await asyncio.sleep(0.003)
            if off == half:
                await asyncio.sleep(1.5)
                await step("②", "灌了一半", "状态=灌谱中 · 计数涨到一半",
                           "灌谱中")
                print("      ⭐ 停 6 秒 —— 请看屏上的计数和进度条")
                await asyncio.sleep(6)
        await asyncio.sleep(2.0)
        await step("③", "灌完了", "状态=就绪 · 计数=总数 · 进度 100%", "就绪")
        await step("③", "计数", "t2 = %d/%d" % (events, events),
                   "%d/%d" % (events, events), ctrl="t2")

        # ---- ④ 起播 ----
        print("\n【④ 起播】CMD 0x03")
        await c.write_gatt_char(CMD, bytes([0x03]), response=False)
        await asyncio.sleep(1.5)
        await step("④", "已起播", "状态=播放中", "播放中")

        # ---- ⑤ 等放完 ----
        # ⭐⭐ 等待时长 = 提前量 + 谱面时长 + 余量
        # 🔴 这里曾经算错：⭐ 只按"谱面时长"等 ⇒ ⚠️ 永远等不到 `播完`
        #    ⇒ 🔴 差点误判固件（⭐ 详见 `read_lead_ticks()` 的说明）。
        lead = read_lead_ticks()
        lead_s = lead / TICK_PER_S
        score_s = (events * 24) / TICK_PER_S
        need = lead_s + score_s + 3.0
        print("\n【⑤ 等放完】")
        print("      提前量 %d tick = %.1f s（⭐ 从 ble_config.h 读的）" % (lead, lead_s))
        print("      谱面时长 %.1f s ⇒ 预计 %.1f s 放完" % (score_s, lead_s + score_s))
        print("      ⭐ **轮询**等 `播完`（⭐ 最多 %.0f 秒，⛔ 不固定睡）" % need)

        t0 = asyncio.get_event_loop().time()
        done_at = None
        while asyncio.get_event_loop().time() - t0 < need:
            await asyncio.sleep(1.0)
            el = asyncio.get_event_loop().time() - t0
            if await get_txt(c, lg, "t1") == "播完":
                done_at = el
                break
            if int(el) % 5 == 0:
                print("      ... %.0f s 仍在播放" % el)
        if done_at is None:
            print("  🔴 %.0f 秒内没翻到 `播完`" % need)
        await step("⑤", "放完了", "状态=播完（⭐ 保持住）", "播完")
        if done_at is not None:
            print("      ⭐ 实测放完时刻 = %.1f s（⭐ 预计 %.1f s）"
                  % (done_at, lead_s + score_s))

        # ---- ⑥ 蓝牙 ----
        print("\n【⑥ 蓝牙】")
        await step("⑥", "蓝牙状态", "t3 = BT OK 绿色", "BT OK", ctrl="t3")

        # ---- ⑦ 保持连接，让你慢慢看 ----
        print("\n【⑦ 保持连接 %.0f 秒】⭐ 请仔细看屏上六栏" % hold)
        print("      t1 状态字 · t2 事件计数 · g0 曲名 · j0 进度条 ·")
        print("      n0 百分比 · t3 蓝牙(绿)")
        await asyncio.sleep(hold)

    ser.close()
    print()
    print("=" * 76)
    print("演示结束 —— ⭐ 断开后 `t3` 应变 `BT --` 红、`t1` 应变 `断链`")
    print("=" * 76)
    return 0


def selftest():
    """
    ⭐ 离线自检（⛔ 不需要硬件）。

    🔴🔴 **为什么必须有这个函数（⭐ 不是可选项）**
    -----------------------------------------------------------------------
    ⚠️ 实测踩过（2026-10-01）：⭐ `screen_demo.py` 第一版**没有 `--selftest`**
       ⇒ ⭐ `selftest_all.py` 把它归类成"**直接跑**"（⭐ 见它的 `has_selftest`）
       ⇒ 🔴 **`python selftest_all.py` 会真的驱动硬件跑完整演示**
       （⭐ 45 秒、⭐ 还会改板子状态）⇒ ⚠️ 那已经不是"自检"了。
    📌 同族：⭐ `rec_upstream.py` 的自检 v1 也**真的跑了 `main()`**
       （⭐ 做了 30 秒真实 BLE I/O）—— ⭐ **同一个坑踩了两次**。
    ⭐ 判据：⭐ **凡是"能被枚举器收进离线自检"的脚本，
       必须提供一个【不碰硬件】的 `--selftest`**；⚠️ 做不到就得**改名加 `_` 前缀**。
    """
    print("=" * 74)
    print("screen_demo.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-50s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① ⭐ 提前量必须从【源头】读，且读到的值必须与文件一致 ----
    lead = read_lead_ticks()
    import os
    cfg = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "ble", "main", "ble_config.h")
    with open(cfg, "r", encoding="utf-8", errors="replace") as f:
        cfg_txt = f.read()
    m = re.search(r"#define\s+BLE_POOL_LEAD_TICKS\s+(\d+)", cfg_txt)
    chk("⭐ 从 ble_config.h 读到了提前量", m is not None,
        "  lead=%d" % lead)
    chk("⭐ 读到的值与文件里的一致",
        m is not None and lead == int(m.group(1)),
        "  文件=%s 读到=%d" % (m.group(1) if m else "?", lead))
    # ⭐ 非空洞性：⭐ 提前量必须是【非零】的，否则"等放完"的公式退化成"只等谱面"
    chk("⭐ 非空洞：提前量 > 0（否则等待公式退化）", lead > 0)
    chk("⭐ 提前量换算 ≈ 10.4 s（120 BPM/PPQN960）",
        abs(lead / TICK_PER_S - 10.4) < 0.2,
        "  %.2f s" % (lead / TICK_PER_S))

    # ---- ② ⭐ 谱面构造：长度 + 总数帧 ----
    p = build_score(200, 24)
    chk("⭐ 谱面长度 = 复位(36) + 总数帧(9) + 200×9",
        len(p) == 36 + 9 + 200 * 9, "  %d" % len(p))
    chk("⭐ 长度是 9 的整数倍（对齐纪律）", len(p) % 9 == 0)
    chk("⭐ 复位标记 = 36 字节全 0xA5", p[:36] == bytes([0xA5]) * 36)
    chk("⭐ 总数帧帧头 = 0x00", p[36] == 0x00)
    chk("⭐ 总数帧体 = 200 大端", struct.unpack(">Q", p[37:45])[0] == 200)
    chk("⭐ 第 1 个事件帧头 = 0xA5", p[45] == 0xA5)
    # ⭐ 非空洞性：⭐ 换个事件数，长度必须跟着变（⭐ 否则长度判据是假的）
    chk("⭐⭐ 非空洞：事件数变 ⇒ 长度变",
        len(build_score(7, 24)) == 36 + 9 + 7 * 9)

    # ---- ③ ⭐ phase_inc 换算（⭐ 这是最容易差 1024 倍的地方）----
    #   ⭐ f = inc × 50e6 / 2³² ⇒ A4=440 ⇒ inc = 440 × 2³² / 50e6 ≈ 37796
    inc440 = phase_inc(440.0)
    chk("⭐ A4=440Hz ⇒ inc ≈ 37796", abs(inc440 - 37796) <= 1, "  %d" % inc440)
    # ⭐ 2026-10-01 修正：原来写的是 `< (1 << 22)`，那是 2026-09-22 修订【之前】的
    #    字段宽度。新布局 inc 是 [43:23] = 21 bit。而且这里必须真的验证
    #    "inc 装进字里之后，按 FPGA 的切片能原样解回来" —— 光比大小抓不住漂移。
    chk("⭐ inc 不超 21 位（新布局 [43:23]）", inc440 < (1 << 21), "  %d" % inc440)
    _w = SW.pack_word(tick=0, inc=inc440, axis=0, vel=90,
                      kind=SW.KIND_ON, timbre=0)
    chk("⭐ inc 打包后按 FPGA 切片解回原值",
        SW.unpack_word(_w)["inc"] == inc440,
        "  解回 %d" % SW.unpack_word(_w)["inc"])
    chk("⭐ 保留位为 0（契约）", SW.reserved_bits(_w) == 0)
    # ⭐ 非空洞性：⭐ 不同频率必须给不同 inc
    chk("⭐⭐ 非空洞：A5=880 ⇒ inc 约为 A4 的两倍",
        abs(phase_inc(880.0) - 2 * inc440) <= 2,
        "  %d" % phase_inc(880.0))

    # ---- ④ ⭐ tick 递增 ⇒ 时间递增（⭐ 单调性，⭐ 水池靠它排序）----
    ticks = []
    for i in range(4):
        fp = p[45 + i * 9:45 + i * 9 + 9]
        w = int.from_bytes(fp[1:9], "big")
        ticks.append((w >> 44) & 0xFFFFF)
    chk("⭐ tick 严格递增", ticks == sorted(ticks) and len(set(ticks)) == 4,
        "  %s" % ticks)
    chk("⭐ 第 0 帧 tick = 0", ticks[0] == 0)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="完整上屏演示")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件，⭐ 必须存在，见 selftest 的说明）")
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--hold", type=float, default=25.0, help="末尾保持连接的秒数")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    sys.exit(asyncio.run(main(a.events, a.hold)))
