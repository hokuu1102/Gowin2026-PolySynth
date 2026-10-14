"""一次性：PC 用 USB-TTL 伪装 FPGA，接收 ESP32 从 UART1 发出来的帧，逐字节校验。

为什么要做这个（而不是只看 STAT 的 sent=）
----------------------------------------------------------------------------
`sent=11865` 只证明 `uart_write_bytes()` 每次都返回了 9。
它【不证明】线上那 9 个字节是对的 —— 而位域刚修过（2026-10-01），
所以必须看真实线上的字节。
同族教训：L113（判据锚在中间状态 => 下游缺陷在回归里完全不可见）。

它验什么
----------------------------------------------------------------------------
1. ESP32 播放时，UART1(GPIO17) 上真的有没有字节出来；
2. 出来的帧是不是【9 字节、帧头 0xA5】；
3. 载荷是不是与发进去的 events【逐帧逐字节一致】；
4. 有没有多出来的 / 缺掉的 / 错位的帧。

接线前提
----------------------------------------------------------------------------
USB-TTL 的 RX 必须接 ESP32 的 GPIO17（UART1 TX），GND 共地。
USB-TTL 的 DTR/RTS 一律先压住（U86：open() 这个动作本身可能拉 DTR/RTS）。

用法
----------------------------------------------------------------------------
    python _uart1_wire_check.py --port COM31 --events 200 --seconds 25
"""
import argparse
import asyncio
import os
import sys
import time

import serial
from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import score_word as SW          # noqa: E402


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")


UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
# ⚠️ 日志口【不要写死】—— 本机端口会漂（实测 COM29 是上机时的临时值，
#    写死后 --port 传对了也照样去开 COM29，⛔ 必然失败）。
# ⭐ 改运行时解析：优先 --log-port，其次按 VID 找 ESP32，最后才退回 --port 自己。
LOG_PORT = None


def fake_song(n_events):
    """与 send_frames_ble.py 的 fake_song 完全同参（这里独立重算，便于比对）。"""
    NOTE_INC = 164927
    out = []
    for i in range(n_events):
        out.append(SW.pack_word(tick=1000 + i * 37, inc=NOTE_INC,
                                axis=i % 16, vel=60 + (i % 60),
                                kind=i % 2, timbre=i % 2))
    return out


def open_quiet(port, baud):
    """打开串口，且在 open() 之前就把 DTR/RTS 压住（U86）。"""
    s = serial.Serial()
    s.port = port
    s.baudrate = baud
    s.timeout = 0.1
    s.dtr = False
    s.rts = False
    s.open()
    s.setDTR(False)
    s.setRTS(False)
    s.reset_input_buffer()
    return s


# ===========================================================================
# 判据（抽成纯函数 => 可以离线自检，⛔ 不必插硬件）
# ===========================================================================
def split_frames(raw, hdr=0xA5):
    """把裸字节按 9 B 切帧，丢掉帧头不对的。

    返回 (frames, bad_hdr, nbytes)。
    ⚠️ 为什么按【固定 9 B】切而不是找 0xA5：
    载荷里本来就可能是 0xA5（tick/inc 任意值）=> 扫描会误判；
    而线上格式是【定长】的，按 9 B 推进才是正确做法。
    """
    frames = []
    bad_hdr = 0
    for off in range(0, len(raw) - 8, 9):
        fr = bytes(raw[off:off + 9])
        if fr[0] != hdr:
            bad_hdr += 1
            continue
        frames.append(fr)
    return frames, bad_hdr, len(raw)


def compare_frames(frames, expect_words, frame_from_word):
    """逐帧比对【除帧头外的 8 字节载荷】。

    返回 (n_cmp, first_bad_index_or_None)。
    ⚠️ 为什么【跳过字节 0】（帧头）：
    帧头恒为 0xA5，比它没有信息量；⭐ 真正的判据是【载荷是否一致】。
    """
    n_cmp = min(len(frames), len(expect_words))
    for i in range(n_cmp):
        want = frame_from_word(expect_words[i])[1:]
        if frames[i][1:] != want:
            return n_cmp, i
    return n_cmp, None


def selftest():
    """离线自检 —— ⭐ 重点是【非空洞性】：坏输入必须被判出来。"""
    print("=" * 70)
    print("_uart1_wire_check.py 离线自检（不需要硬件）")
    print("=" * 70)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-50s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    words = fake_song(3)
    stream = b"".join(SW.frame_from_word(w) for w in words)

    fr, bh, nb = split_frames(stream)
    chk("好样本：帧数 = 3", len(fr) == 3, "  实测 %d" % len(fr))
    chk("好样本：无坏帧头", bh == 0)
    chk("好样本：字节数 = 27", nb == 27, "  实测 %d" % nb)

    n, fb = compare_frames(fr, words, SW.frame_from_word)
    chk("好样本：逐帧一致", fb is None and n == 3)

    # 非空洞性 A：载荷被改一位 => 必须抓住
    broken = bytearray(stream)
    broken[9 + 5] ^= 0x01          # 第 2 帧的载荷里翻一位
    fr2, _, _ = split_frames(bytes(broken))
    _, fb2 = compare_frames(fr2, words, SW.frame_from_word)
    chk("非空洞：载荷改一位 => 判出不一致", fb2 == 1, "  首个坏帧 = %s" % fb2)

    # 非空洞性 B：帧头坏 => 该帧被丢掉（bad_hdr 涨）
    bh_bad = bytearray(stream)
    bh_bad[0] = 0x00
    fr3, bh3, _ = split_frames(bytes(bh_bad))
    chk("非空洞：帧头坏 => 被丢弃且计数", bh3 == 1 and len(fr3) == 2,
        "  坏头 %d / 有效 %d" % (bh3, len(fr3)))

    # 非空洞性 C：一个字节都没收到 => 帧数为 0（对应"接线没通"那个分支）
    fr4, _, nb4 = split_frames(b"")
    chk("非空洞：空输入 => 0 帧 0 字节", len(fr4) == 0 and nb4 == 0)

    # 非空洞性 D：少一帧 => 比对数变少（⛔ 不该"看起来通过"）
    fr5, _, _ = split_frames(stream[:-9])
    n5, fb5 = compare_frames(fr5, words, SW.frame_from_word)
    chk("非空洞：少一帧 => 只比 2 帧（⭐ 不是假装通过）",
        n5 == 2 and fb5 is None, "  比对 %d 帧" % n5)

    # 定长切分的正确性：载荷里含 0xA5 也不能错位
    w = list(words)
    w[1] = SW.pack_word(tick=0xA5A5, inc=0xA5A5A5, axis=5, vel=0xA5,
                        kind=0, timbre=1)
    s2 = b"".join(SW.frame_from_word(x) for x in w)
    fr6, bh6, _ = split_frames(s2)
    chk("载荷含 0xA5 时，定长切分仍正确（⛔ 不扫描）",
        len(fr6) == 3 and bh6 == 0, "  帧 %d 坏头 %d" % (len(fr6), bh6))
    _, fb6 = compare_frames(fr6, w, SW.frame_from_word)
    chk("载荷含 0xA5 时，逐帧仍一致", fb6 is None)

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM31", help="CH340（上行）的口（默认 COM31）")
    # ⭐ 日志口单独给 —— 它和上行口是【两个不同的口】。
    #   ⚠️ 不写死：实测写死 COM29 后，--port 传对了也照样开 COM29 => 必失败。
    ap.add_argument("--log-port", default=None,
                    help="ESP32 日志口（默认按 VID 303A 自动找；找不到就用 --port 自己）")
    ap.add_argument("--baud", type=int, default=500000)
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--hex", default=None,
                    help="真谱面：读 mid2evt.py 产出的 events.hex（⛔ 与 --events 二选一）")
    ap.add_argument("--seconds", type=float, default=25.0)
    args = ap.parse_args()

    if args.hex:
        expect, problems = SW.load_events_hex(args.hex)
        print("谱面：%s（%d 事件）" % (os.path.basename(args.hex), len(expect)))
        if problems:
            print("!! events.hex 有 %d 个问题" % len(problems))
    else:
        expect = fake_song(args.events)
    print("期望：%d 帧事件（每帧 9 字节，帧头 0xA5）" % len(expect))
    print("      首帧 tick=%d inc=%d kind=%d"
          % (SW.unpack_word(expect[0])["tick"],
             SW.unpack_word(expect[0])["inc"],
             SW.unpack_word(expect[0])["kind"]))
    print("      末帧 tick=%d"
          % SW.unpack_word(expect[-1])["tick"])
    print()

    print(">>> 打开 %s @ %d（DTR/RTS 已压住）" % (args.port, args.baud))
    try:
        cap = open_quiet(args.port, args.baud)
    except Exception as e:
        print("RED: 打不开 %s：%s" % (args.port, e))
        return 2
    print("    已打开")

    # ⭐ 解析日志口：--log-port > 按 VID 找 ESP32 > 退回 --port 自己
    # ⚠️ 它必须在上行口【之后】打开：正常情况两个口都要开，
    #    但只在 CH340 那侧抓数据，日志口只用来确认"固件真的在处理"。
    log_port = args.log_port
    if not log_port:
        try:
            from run_all_tests import find_port, VID_ESP32
            log_port = find_port(VID_ESP32)
        except Exception:
            log_port = None
    if not log_port:
        log_port = args.port
        print("⚠️ 没找到 ESP32 日志口（VID 303A），退回 %s —— "
              "若它不发日志，下面可能抓不到数据" % log_port)
    else:
        print("    日志口：%s" % log_port)

    lg = open_quiet(log_port, 115200)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        return 1

    raw = bytearray()
    rc = 0
    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)

        print(">>> CMD 0x01 清池")
        await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
        await asyncio.sleep(1.0)

        payload = SW.reset_sequence() + SW.frame_total(len(expect)) + b"".join(
            SW.frame_from_word(w) for w in expect)
        print(">>> 灌 %d 字节" % len(payload))
        sent = 0
        t0 = time.time()
        while sent < len(payload):
            n = min(180, len(payload) - sent)
            await c.write_gatt_char(UUID_RECV, payload[sent:sent + n],
                                    response=False)
            sent += n
            await asyncio.sleep(0.005)
        print("    发完 %.1f s" % (time.time() - t0))
        await asyncio.sleep(1.0)

        # 抓包要在起播【之前】就开始
        print(">>> 开始抓 %s，然后 CMD 0x03 起播" % args.port)
        await c.write_gatt_char(UUID_CMD, bytes([0x03]), response=False)

        t1 = time.time()
        while time.time() - t1 < args.seconds:
            n = cap.in_waiting
            if n:
                raw.extend(cap.read(n))
            await asyncio.sleep(0.02)
        print("    抓到 %d 字节，用时 %.1f s" % (len(raw), time.time() - t1))

    cap.close()
    lg.close()

    # ---- 逐帧逐字节比对 ----
    print()
    print("=" * 66)
    print("逐帧比对")
    print("=" * 66)
    bad_hdr = 0
    frames = []
    frames, bad_hdr, _nb = split_frames(bytes(raw))
    print("抓到字节 = %d（%.2f 帧）" % (len(raw), len(raw) / 9.0))
    print("帧头非 0xA5 的位置 = %d" % bad_hdr)
    print("可用事件帧 = %d（期望 %d）" % (len(frames), len(expect)))

    n_cmp, first_bad = compare_frames(frames, expect, SW.frame_from_word)
    if first_bad is None:
        print("前 %d 帧载荷【逐字节一致】" % n_cmp)
    else:
        print("RED: 第 %d 帧不一致" % first_bad)
        print("   期望 %s" % SW.frame_from_word(expect[first_bad]).hex(" ").upper())
        print("   实测 %s" % frames[first_bad].hex(" ").upper())

    # ---- 结论 ----
    print()
    ok = True
    if len(raw) == 0:
        print("RED  => 一个字节都没收到 => USB-TTL 的 RX 没接到 GPIO17，或没共地")
        rc, ok = 3, False
    elif bad_hdr:
        print("RED  => 有 %d 处帧头不是 0xA5 => 流被污染 / 波特率不对" % bad_hdr)
        rc, ok = 4, False
    elif len(frames) != len(expect):
        print("RED  => 帧数 %d != 期望 %d" % (len(frames), len(expect)))
        rc, ok = 5, False
    elif first_bad is not None:
        print("RED  => 载荷不一致（见上）")
        rc, ok = 6, False
    else:
        print("OK   => 线上 %d 帧与灌进去的 events【逐字节一致】" % len(frames))
        print("        => ESP32 的 UART1 出口这一段【已验】，不再是只看 sent 计数")
    return rc


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(asyncio.run(main()))
