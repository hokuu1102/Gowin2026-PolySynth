"""一次性：上行闭环自检 —— PC 当 FPGA 灌 UART1，再从 BLE 收回，逐字节比对。

为什么要做
----------------------------------------------------------------------------
上行（FPGA -> ESP32 -> BLE -> PC）此前只验到"桩灌 GPIO18"，而且没有
逐字节比对。这是 ESP32 侧最后一条没验的主通路。

接线
----------------------------------------------------------------------------
USB-TTL(CH340) 的 TX -> ESP32 的 GPIO18（UART1 RX）。
注意：本脚本【只写】USB-TTL，⛔ 不读它（同一串口单读者，见 U85）。
收包走 BLE 的 0xABF2 通知。

注入什么
----------------------------------------------------------------------------
用 evt2midi/frame_format.py 造【真实的上行事件帧】（0xA5 + 14 字节：
type/seq/tick32/axis/inc32/vel/cksum），另加一个 68 字节表同步帧，
混入一个坏校验帧，验证"坏帧能被识别而不是伪装成好数据"。

用法
----------------------------------------------------------------------------
    python _upstream_loop_check.py --port COM31 --n 300 --seconds 20
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
_EM = os.path.join(_HERE, "evt2midi")
if _EM not in sys.path:
    sys.path.insert(0, _EM)
import frame_format as FF        # noqa: E402


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")


UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
def make_stream(n_notes, with_tablesync=True, with_bad_cksum=True):
    """造一段真实的上行帧流。返回 (bytes, 期望的逐帧列表)。"""
    frames = []
    t = 0
    for i in range(n_notes):
        ftype = FF.T_NOTE_ON if i % 2 == 0 else FF.T_NOTE_OFF
        fr = FF.build_frame(ftype, seq=i & 0xFF, tick=t, axis=i % 16,
                            inc=37796 + (i % 12) * 2000, vel=100)
        frames.append(fr)
        t += 960
    if with_tablesync:
        frames.append(FF.build_frame(FF.T_TABLESYNC, table=FF.TABLESYNC_TABLE_KB,
                                     items=[37796 + k for k in range(FF.TABLESYNC_ITEMS)]))
    if with_bad_cksum:
        bad = bytearray(FF.build_frame(FF.T_NOTE_ON, seq=0xEE, tick=t,
                                       axis=1, inc=37796, vel=100))
        bad[-1] ^= 0xFF                      # 故意破坏校验
        frames.append(bytes(bad))
    return b"".join(frames), frames


def open_write_only(port, baud):
    """只写不读：open 前压住 DTR/RTS（U86）。"""
    s = serial.Serial()
    s.port = port
    s.baudrate = baud
    s.timeout = 0.1
    s.dtr = False
    s.rts = False
    s.open()
    s.setDTR(False)
    s.setRTS(False)
    return s


def split_frames(buf):
    """按已知帧长切分上行流，返回 [(帧, 是否校验通过)]。

    帧长按类型取（0x10 表同步 = 68 B，其余 = 14 B）——
    这正是 frame_format.py 存在的理由：一律按 14 B 吃会把表帧切成 4 个假帧。
    """
    out = []
    i = 0
    while i < len(buf):
        if buf[i] != FF.FRAME_HDR:
            out.append((bytes(buf[i:i + 1]), None))
            i += 1
            continue
        if i + 2 > len(buf):
            out.append((bytes(buf[i:]), None))
            break
        flen = FF.frame_len_for(buf[i + 1])
        if i + flen > len(buf):
            out.append((bytes(buf[i:]), None))
            break
        fr = bytes(buf[i:i + flen])
        ok = (FF.frame_checksum(fr) == fr[-1])
        out.append((fr, ok))
        i += flen
    return out


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM31", help="USB-TTL 口（TX 接 GPIO18）")
    ap.add_argument("--baud", type=int, default=500000)
    ap.add_argument("--n", type=int, default=300, help="注入的音符帧数")
    ap.add_argument("--seconds", type=float, default=20.0)
    args = ap.parse_args()

    stream, expect = make_stream(args.n)
    print("将注入 %d 帧 / %d 字节（含 1 个 68B 表同步帧 + 1 个坏校验帧）"
          % (len(expect), len(stream)))

    try:
        w = open_write_only(args.port, args.baud)
    except Exception as e:
        print("RED: 打不开 %s：%s" % (args.port, e))
        return 2
    print("已打开 %s @ %d（只写）" % (args.port, args.baud))

    got = bytearray()

    def on_noti(_s, data):
        got.extend(bytes(data))

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        w.close()
        return 1

    rc = 0
    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        await c.start_notify(UUID_NOTI, on_noti)
        print("已订阅 0xABF2（上行通知）")
        await asyncio.sleep(0.6)

        # 先清上行环，免得旧数据混进来
        try:
            await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
            await asyncio.sleep(0.8)
            got.clear()
        except Exception as e:
            print("  (清池失败，忽略：%s)" % e)

        print("开始写 UART1 ...")
        # 分块写，块大小取 9 的整数倍（本项目纪律；这里其实与帧长无关，但保持一致）
        sent = 0
        t0 = time.time()
        while sent < len(stream):
            n = min(180, len(stream) - sent)
            w.write(stream[sent:sent + n])
            sent += n
            await asyncio.sleep(0.004)
        w.flush()
        print("  写完 %d 字节，%.1f s" % (sent, time.time() - t0))

        t1 = time.time()
        while time.time() - t1 < args.seconds:
            await asyncio.sleep(0.2)
        try:
            await c.stop_notify(UUID_NOTI)
        except Exception:
            pass

    w.close()

    # ---- 比对 ----
    print()
    print("=" * 66)
    print("比对")
    print("=" * 66)
    print("收到 %d 字节（发出 %d）" % (len(got), len(stream)))
    parsed = split_frames(got)
    good = [p for p in parsed if p[1] is True]
    bad = [p for p in parsed if p[1] is False]
    unk = [p for p in parsed if p[1] is None]
    print("切出 %d 帧：校验通过 %d / 校验失败 %d / 无法成帧 %d"
          % (len(parsed), len(good), len(bad), len(unk)))

    # 逐帧比对：期望流里的每一帧都必须在收到流里按序出现
    n_cmp = min(len(good), len(expect))
    first_bad = None
    for i in range(n_cmp):
        if good[i][0] != expect[i]:
            first_bad = i
            break
    if first_bad is None:
        print("前 %d 帧【逐字节一致】" % n_cmp)
    else:
        print("RED: 第 %d 帧不一致" % first_bad)
        print("   期望 %s" % expect[first_bad].hex(" ").upper())
        print("   实测 %s" % good[first_bad][0].hex(" ").upper())

    print()
    if len(got) == 0:
        print("RED  => 一个字节都没收到 => USB-TTL 的 TX 没接到 GPIO18，或没共地")
        rc = 3
    elif len(got) != len(stream):
        print("RED  => 字节数不等（收 %d / 发 %d）" % (len(got), len(stream)))
        rc = 4
    elif first_bad is not None:
        print("RED  => 载荷不一致")
        rc = 5
    else:
        print("OK   => 上行 %d 帧 / %d 字节【逐字节一致】" % (len(good), len(got)))
        print("        且坏校验帧被识别为校验失败（%d 个）=> 坏帧不伪装成好数据"
              % len(bad))
        if len(bad) != 1:
            print("        注意：期望恰好 1 个坏校验帧，实测 %d" % len(bad))
        rc = 0
    return rc


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
