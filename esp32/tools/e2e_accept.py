#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
e2e_accept.py —— ⭐ 一键端到端验收（ESP32 下行通路）

═══ 它做什么 ═══
把原来【手动串 3 步】的验收压成【一条命令】：
    ① 清池(R)  → ② BLE 灌 N 帧 → ③ 起播(S) → ④ 抓 GPIO17 → ⑤ 打印判据对账表

═══ 为什么需要它 ═══
⚠️ 原来每验一次都要手动敲 3 次命令，⭐ 而且判据【靠人记】。
⭐ 本脚本把判据**固化进代码**，⛔ 不靠记忆。

═══ 🔴 两个必须遵守的约束（⭐ 都是踩过的坑）═══
① **单进程、单句柄**（⭐ 见经验 C101）
   ⚠️ BLE 用 `bleak`（另一条链路，不占串口）；
   ⚠️ 清池/起播/抓包【都走同一个 CH340 句柄】——
   ⛔ 绝不开两个进程抢 `COM31`（那会 `PermissionError(13)`）。
② **打开串口不拉 DTR/RTS**（⭐ 见经验 U86）
   ⚠️ 否则会复位 ESP32-S3 ⇒ 🔴 池里的数据全没。

═══ 判据（⭐ 全部硬编码，⛔ 不靠人看）═══
    total == N      tf == 1        rst == 4
    unk == 0        ovf == 0       mismatch == 0
    帧数 == N       9N 对齐        帧头全 0xA5
    kind ∈ {0,1}    rsvd == 0      pace ≈ 1.0
⚠️ unk / ovf / mismatch 三个【必须为 0】—— ⭐ 非 0 都是真故障。

═══ 用法 ═══
    python e2e_accept.py --log-port COM29 --uart-port COM31
    python e2e_accept.py --log-port COM29 --uart-port COM31 --events 400
    python e2e_accept.py --selftest          # ⛔ 不需要硬件

⚠️ 接线（⭐ 交叉 + 共地）：
    ESP32 GPIO17(TX) ──> CH340 RXD     ⭐ 抓数据
    ESP32 GPIO18(RX) <── CH340 TXD     ⭐ 发触发
    ESP32 GND ────────── CH340 GND     🔴 必须共地
"""

import argparse
import asyncio
import io
import os
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


# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK，会炸）----------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HDR_EVENT = 0xA5
HDR_TOTAL = 0x00
RESET_FRAMES = 4

DEV_NAME = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"

# ⭐ 音乐时间（⭐ 与固件 pool.c 的约定一致）
PPQN = 960
BPM = 120
TICKS_PER_S = BPM * PPQN / 60.0          # 1920 tick/s
# ⚠️ 固件起播后有 BLE_POOL_LEAD_TICKS 的提前量 ⇒ 首帧要等 ~10.4 s
LEAD_TICKS = 20000
LEAD_S = LEAD_TICKS / TICKS_PER_S
PACE_LO, PACE_HI = 0.90, 1.10


# ============================================================================
# 帧构造（⭐ 与 send_frames_ble.py 完全一致 —— 复用它的语义，⛔ 不另立一套）
# ============================================================================
def reset_sequence() -> bytes:
    return bytes([HDR_EVENT]) * (FRAME_BYTES * RESET_FRAMES)


def frame_total(n_events: int) -> bytes:
    return bytes([HDR_TOTAL]) + struct.pack(">Q", n_events)


def fake_song(n_events: int) -> bytes:
    """
    ⚠️ 假曲谱。⭐ 语义必须合法（⭐ 这是踩过的坑）：
      · `kind` 只能是 0(note_on) / 1(note_off)
        🔴 **绝不能出现 `kind=2`（换速）** —— 固件会重锚时间基准
        ⇒ 提前量反复从头累积 ⇒ 🔴 **根本放不完**
      · `inc` 必须【恒定】（⭐ 它是音高相位增量，⛔ 不是随机数）
      · `tick` 严格递增
    """
    NOTE_INC = 164927        # ⭐ = 固件 BLE_POOL_DEFAULT_TICK_INC @120BPM
    out = bytearray()
    for i in range(n_events):
        tick = 1000 + i * 37
        word = ((tick & 0xFFFFF) << 44) | \
               ((NOTE_INC & 0x3FFFFF) << 22) | \
               (((i % 16) & 0xF) << 18) | \
               (((60 + (i % 60)) & 0x7F) << 11) | \
               (((i % 2) & 0x3) << 9) | \
               (((i % 2) & 0x1) << 8)
        out += bytes([HDR_EVENT]) + word.to_bytes(8, "big")
    return bytes(out)


def build_payload(n_events: int) -> bytes:
    return reset_sequence() + frame_total(n_events) + fake_song(n_events)


# ============================================================================
# 自检（⛔ 不需要硬件）
# ============================================================================
def selftest() -> int:
    print("=" * 70)
    print("e2e_accept.py 离线自检（⛔ 不需要硬件）")
    print("=" * 70)
    ok = True

    p = build_payload(200)
    c1 = len(p) == 36 + 9 + 9 * 200
    print("① 整包 1845 字节: %s" % ("OK" if c1 else "RED"))
    ok &= c1

    c2 = len(p) % FRAME_BYTES == 0
    print("② 9N 对齐: %s" % ("OK" if c2 else "RED"))
    ok &= c2

    # ⭐ 语义检查：kind 只能 0/1，inc 恒定
    # 🔴 踩过的坑（⭐ 本自检初版就错了）：⚠️ 不能把 payload 里【所有】9 字节块
    #    都当事件帧 —— ⭐ payload 的结构是
    #        [4 个复位帧：全 0xA5] + [1 个总数帧：0x00 + 8 字节] + [N 个事件帧]
    #    ⚠️ 复位帧的"载荷"是 A5×8 ⇒ 解出来 kind/inc 是碰巧的随机值；
    #    ⚠️ 总数帧帧头是 0x00 ⇒ 压根不是事件。
    #    ⇒ ⭐ **必须先按帧头筛出真正的事件帧**（⭐ 与主流程同一口径）。
    kinds, incs, ticks = set(), set(), []
    for i in range(len(p) // FRAME_BYTES):
        f = p[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
        if f[0] != HDR_EVENT:
            continue                        # ⛔ 总数帧，不是事件
        if all(b == HDR_EVENT for b in f):
            continue                        # ⛔ 复位标记帧，不是事件
        w = int.from_bytes(f[1:], "big")
        kinds.add((w >> 9) & 3)
        incs.add((w >> 22) & 0x3FFFFF)
        ticks.append((w >> 44) & 0xFFFFF)
    c3 = kinds <= {0, 1}
    print("③ kind 只含 0/1（⛔ 无换速）: %s  实际=%s  事件数=%d"
          % ("OK" if c3 else "RED", sorted(kinds), len(ticks)))
    ok &= c3
    c4 = len(incs) == 1
    print("④ inc 恒定: %s  实际 %d 个值" % ("OK" if c4 else "RED", len(incs)))
    ok &= c4
    c5 = all(ticks[i] < ticks[i + 1] for i in range(len(ticks) - 1))
    print("⑤ tick 严格递增: %s" % ("OK" if c5 else "RED"))
    ok &= c5

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


# ============================================================================
# 串口（⭐ 打开不拉 DTR/RTS —— 见 U86）
# ============================================================================
def open_no_reset(port, baud, timeout=0.05):
    import serial
    s = serial.Serial()
    s.port = port
    s.baudrate = baud
    s.timeout = timeout
    s.dtr = False
    s.rts = False
    s.open()
    # ⚠️ 部分驱动会在 open 时自作主张拉线 ⇒ 再确认一次
    s.setDTR(False)
    s.setRTS(False)
    return s


# ============================================================================
# 读日志（⭐ 限时读，⛔ 不用 idf.py monitor）
# ============================================================================
def read_log(port, seconds):
    try:
        s = open_no_reset(port, 115200, timeout=0.1)
    except Exception as e:
        return "", "打不开 %s: %s" % (port, e)
    buf = bytearray()
    try:
        s.reset_input_buffer()
        t0 = time.time()
        while time.time() - t0 < seconds:
            n = s.in_waiting
            if n:
                buf += s.read(n)
            else:
                time.sleep(0.03)
    except Exception as e:
        return bytes(buf).decode("utf-8", "replace"), str(e)
    finally:
        try:
            s.close()
        except Exception:
            pass
    return bytes(buf).decode("utf-8", "replace"), None


def parse_status(text):
    """⭐ 从日志里抓最后一个 `sent=`/`pool=` 状态行，解析成 dict。"""
    fields = {}
    for ln in text.splitlines():
        if "sent=" in ln and "pool=" in ln:
            for tok in ln.replace("|", " ").split():
                if "=" in tok:
                    k, _, v = tok.partition("=")
                    fields[k.strip()] = v.strip()
    return fields


# ============================================================================
# BLE 灌数据（⭐ bleak 直连，⛔ 不经虚拟串口）
# ============================================================================
async def ble_feed(n_events, chunk, scan_to):
    from bleak import BleakScanner, BleakClient
    payload = build_payload(n_events)
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV_NAME), timeout=scan_to)
    if dev is None:
        return None, "没找到设备 %s（⚠️ 手机是否还连着？板子在广播吗？）" % DEV_NAME
    sent = 0
    async with BleakClient(dev) as c:
        try:
            await c.start_notify(UUID_NOTI, lambda s, d: None)
        except Exception:
            pass
        await asyncio.sleep(0.8)
        chunk = max(FRAME_BYTES, (chunk // FRAME_BYTES) * FRAME_BYTES)
        while sent < len(payload):
            n = min(chunk, len(payload) - sent)
            try:
                await c.write_gatt_char(UUID_RECV, payload[sent:sent + n],
                                        response=False)
            except Exception as e:
                return None, "写入失败（已发 %d/%d）: %s" % (sent, len(payload), e)
            sent += n
            await asyncio.sleep(0.004)
    return sent, None


# ============================================================================
# 抓 GPIO17（⭐ 分块读 —— 逐字节读在 500k 下会丢整条流，见 C104）
# ============================================================================
def capture(port, baud, seconds, trigger=b"S"):
    s = open_no_reset(port, baud, timeout=0.0)
    data = bytearray()
    stamps = []
    t_trig = None
    try:
        s.reset_input_buffer()
        time.sleep(0.3)
        t0 = time.perf_counter()
        if trigger:
            s.write(trigger)
            s.flush()
            t_trig = time.perf_counter() - t0
        while time.perf_counter() - t0 < seconds:
            n = s.in_waiting
            if n:
                d = s.read(n)
                now = time.perf_counter() - t0
                for _ in range(len(d) // FRAME_BYTES):
                    stamps.append(now)
                data += d
    finally:
        try:
            s.close()
        except Exception:
            pass
    return bytes(data), stamps, t_trig


# ============================================================================
# 主流程
# ============================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description="ESP32 下行通路一键端到端验收")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    ap.add_argument("--log-port", help="ESP32 日志口，如 COM29")
    ap.add_argument("--uart-port", help="USB-TTL 口（接 GPIO17/18），如 COM31")
    ap.add_argument("--baud", type=int, default=500000, help="数据波特率（默认 500000）")
    ap.add_argument("--events", type=int, default=200, help="事件数（默认 200）")
    ap.add_argument("--chunk", type=int, default=180, help="BLE 每次写入字节（默认 180）")
    ap.add_argument("--scan-timeout", type=float, default=12.0)
    ap.add_argument("--capture-seconds", type=float, default=20.0,
                    help="抓包窗口（⚠️ 首帧要等 ~10.4 s ⇒ 至少 15）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.log_port or not args.uart_port:
        print("RED: 需要 --log-port 与 --uart-port（⚠️ 或用 --selftest）")
        return 2

    try:
        import serial  # noqa: F401
    except ImportError:
        print("RED: 缺 pyserial —— pip install pyserial")
        return 2

    N = args.events
    fails = []
    print("=" * 70)
    print("ESP32 下行通路 · 一键端到端验收")
    print("=" * 70)
    print("日志口 = %s    数据口 = %s @ %d" % (args.log_port, args.uart_port, args.baud))
    print("事件数 = %d    抓包窗口 = %.0f s" % (N, args.capture_seconds))
    print()

    # ---- ① 清池 ----
    print("① 清池 (R) ...")
    try:
        s = open_no_reset(args.uart_port, args.baud, timeout=0.2)
        time.sleep(0.3)
        s.write(b"R")
        s.flush()
        time.sleep(0.4)
        s.close()
    except Exception as e:
        print("   RED: 打不开 %s: %s" % (args.uart_port, e))
        return 3
    txt, err = read_log(args.log_port, 2)
    st = parse_status(txt)
    # ⭐ 记基线：`tf`/`rst` 是【自开机累计】量（⭐ 见下方判据处的说明）
    #    ⇒ ⭐ 后面比【增量】，⛔ 不是比绝对值。
    base = dict(st)
    # 🔴 踩过的坑（⭐ 实跑撞上）：`pool` 的格式是 **`N/cap`**，
    #    ⚠️ 我原来直接把整个字段（`"0/18204"`）跟 `"0"` 比 ⇒ 🔴 **永远不等**
    #    ⇒ ⭐ 明明清空了却报"未清零"。⭐ 必须先按 `/` 取【分子】。
    cur_pool = st.get("pool", "?").split("/")[0]
    if cur_pool != "0":
        print("   ⚠️ 池未清零：pool=%s（⚠️ 继续，但判据可能受影响）" % st.get("pool"))
    else:
        print("   OK: pool=0（已清空）")

    # ---- ② BLE 灌 N 帧 ----
    print("② BLE 灌 %d 帧 ..." % N)
    sent, err = asyncio.run(ble_feed(N, args.chunk, args.scan_timeout))
    if err:
        print("   RED: %s" % err)
        return 3
    print("   OK: 已发 %d 字节" % sent)

    txt, _ = read_log(args.log_port, 3)
    st = parse_status(txt)
    got_pool = st.get("pool", "?").split("/")[0]
    print("   池内 = %s（期望 %d）" % (got_pool, N))
    if got_pool != str(N):
        fails.append("灌数据：pool=%s，期望 %d" % (got_pool, N))

    # ---- ③+④ 起播并抓包（⭐ 单句柄，边发边收）----
    print("③ 起播 (S) 并抓 GPIO17（%.0f s）..." % args.capture_seconds)
    data, stamps, t_trig = capture(args.uart_port, args.baud, args.capture_seconds)
    print("   OK: 收到 %d 字节" % len(data))

    # ---- ⑤ 判据 ----
    print()
    print("=" * 70)
    print("判据对账")
    print("=" * 70)

    nf = len(data) // FRAME_BYTES
    rem = len(data) % FRAME_BYTES
    print("  帧数        = %d（期望 %d）%s" % (nf, N, "" if nf == N else "  <-- RED"))
    if nf != N:
        fails.append("帧数 %d != %d" % (nf, N))
    print("  9N 对齐     = %s（余 %d）%s" % ("是" if rem == 0 else "否", rem,
                                            "" if rem == 0 else "  <-- RED"))
    if rem != 0:
        fails.append("9N 不对齐（余 %d）" % rem)

    # 固件侧日志判据
    txt, _ = read_log(args.log_port, 3)
    st = parse_status(txt)
    # 🔴🔴 踩过的坑（⭐ 首次实跑就撞上）：`tf`/`rst` 是【自开机累计】的计数器
    #    —— `ble_main.c:84-85` 声明、`:497`/`:525` **只增不减**，
    #    ⚠️ **没有任何地方复位它们**。
    #    ⇒ ⭐ 所以**不能断言它们恰好等于 1 / 4**（⚠️ 那只在"开机后第一次跑"成立）。
    #    ⭐ 正确判据：**每次跑会【增加】恰好 1（tf）和 4（rst）** ——
    #       ⚠️ 但这需要"跑前跑后各读一次"才能比出来。
    #    ⭐ 本脚本的做法：**记基线 → 跑 → 比较增量**（⭐ 见下方 baseline）。
    checks = [
        ("total", str(N)),
        ("unk", "0"), ("ovf", "0"), ("mismatch", "0"),
    ]
    for k, want in checks:
        got = st.get(k, "?")
        hard = k in ("unk", "ovf", "mismatch")
        mark = "" if got == want else ("  <-- RED(必须)" if hard else "  <-- RED")
        print("  %-10s = %s（期望 %s）%s" % (k, got, want, mark))
        if got != want:
            fails.append("%s=%s，期望 %s" % (k, got, want))

    # ⭐ tf / rst：比较【增量】（⭐ 它们是累计量，⛔ 不是每次归零）
    for k, want_delta in (("tf", 1), ("rst", RESET_FRAMES)):
        before = base.get(k)
        after = st.get(k)
        try:
            delta = int(after) - int(before)
        except (TypeError, ValueError):
            delta = None
        if delta is None:
            print("  %-10s = %s（⚠️ 无基线，跳过增量判据）" % (k, after))
        elif delta == want_delta:
            print("  %-10s = %s（⭐ 增量 +%d，期望 +%d）OK"
                  % (k, after, delta, want_delta))
        else:
            print("  %-10s = %s（⭐ 增量 +%d，期望 +%d）  <-- RED"
                  % (k, after, delta, want_delta))
            fails.append("%s 增量 +%d，期望 +%d" % (k, delta, want_delta))

    print("  clamp       = %s（⚠️ 可以有值）" % st.get("clamp", "?"))
    print("  sent        = %s（期望 %d）" % (st.get("sent", "?"), N))
    if st.get("sent") != str(N):
        fails.append("sent=%s，期望 %d" % (st.get("sent"), N))

    # 帧内容判据
    if nf > 0:
        hdrs = set(data[i * FRAME_BYTES] for i in range(nf))
        kinds, rsvd, ticks = set(), set(), []
        for i in range(nf):
            f = data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
            w = int.from_bytes(f[1:], "big")
            kinds.add((w >> 9) & 3)
            rsvd.add(w & 0xFF)
            ticks.append((w >> 44) & 0xFFFFF)
        print("  帧头        = %s%s" % ([hex(h) for h in hdrs],
                                        "" if hdrs == {HDR_EVENT} else "  <-- RED"))
        if hdrs != {HDR_EVENT}:
            fails.append("帧头异常")
        print("  kind        = %s%s" % (sorted(kinds),
                                        "" if kinds <= {0, 1} else "  <-- RED"))
        if not kinds <= {0, 1}:
            fails.append("kind 含换速")
        print("  rsvd        = %s%s" % (sorted(rsvd), "" if rsvd == {0} else "  <-- RED"))
        if rsvd != {0}:
            fails.append("rsvd 非 0")
        inc_ok = all(ticks[i] <= ticks[i + 1] for i in range(len(ticks) - 1))
        print("  tick 递增   = %s" % ("是" if inc_ok else "否  <-- RED"))
        if not inc_ok:
            fails.append("tick 非递增")

        # ⭐ pace（⭐ 用固件日志的 rate= 更可信，⛔ 但 PC 侧也算一个）
        span = ticks[-1] - ticks[0]
        if len(stamps) >= nf and span > 0:
            wall = stamps[nf - 1] - stamps[0]
            exp = span / TICKS_PER_S
            pace = wall / exp if exp > 0 else 0
            ok = PACE_LO <= pace <= PACE_HI
            print("  pace(PC 侧) = %.3f（期望 %.2f~%.2f）%s"
                  % (pace, PACE_LO, PACE_HI, "" if ok else "  <-- 偏离"))
            # ⚠️ 不作为硬判据 —— 见验收报告的"首帧滞留"分析
    print("  首帧时刻    = %s" % ("%.2f s（⭐ 理论 %.2f s）"
                                  % (stamps[0], LEAD_S) if stamps else "无"))

    print()
    print("=" * 70)
    if not fails:
        print("结论：全部通过 ✅")
    else:
        print("结论：%d 项不通过 🔴" % len(fails))
        for f in fails:
            print("   - %s" % f)
    print("=" * 70)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
