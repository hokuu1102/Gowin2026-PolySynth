#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pool_pace_check.py —— 抓 UART1 字节流【带逐字节时间戳】，验证水池放水的【放水节奏】

════════════════════════════════════════════════════════════════════════════════
⭐ 验什么：**音乐时间的放水节奏（节奏 / pace）**

  模式 B：ESP32 把整首谱面灌进 PSRAM 水池，然后按【音乐时间】放水：

      固件：due_tick = f(已过微秒)；只放 tick <= due_tick 的帧
      ⇒ 一把 event 帧的 (tick, 到达墙钟时刻) 应当是【线性关系】，斜率 = 音乐时间

  ⇒ ⭐ 本脚本的核心判据就是一个数：

        tick_span   = 末帧 tick - 首帧 tick         （音乐时长，tick）
        墙钟_应有   = tick_span × 60 / (bpm×ppqn)   （秒）
        节奏比 pace = 实测墙钟 / 墙钟_应有

        ✅ pace ≈ 1.0（±10%） ⇒ 固件在【按音乐节奏】放水
        🔴 pace ≪ 1（如 0.01） ⇒ 固件在【能多快就多快】地倒水（限流没生效）

🔴 与 uart_timing_check.py 的分工（⛔ 别搞混）：

    | 脚本 | 验的是 | 物理层 / 音乐层 |
    |---|---|---|
    | uart_timing_check.py | 帧内/帧间的【字节间隔】 vs GAP_BYTES 门限 | ⭐ 物理层 |
    | **本脚本**           | 帧的【musical tick ↔ 墙钟】是否成正比     | ⭐ 音乐层 |

⚠️ 本脚本【不验】字节间隔，那是上面那个脚本的活。

════════════════════════════════════════════════════════════════════════════════
⭐ 帧格式（冻结契约）

    | 帧 = 9 字节 | 头 0xA5 + 8 字节大端 body |

    body 是 64 位大端字，位域（⭐ 冻结，⛔ 不要动）：

        tick   [63:44]  20 bit
        inc    [43:22]  22 bit
        axis   [21:18]   4 bit
        vel    [17:11]   7 bit
        kind   [10:9]    2 bit
        timbre [8]       1 bit
        rsvd   [7:0]     8 bit   ⚠️ 必须为 0

    kind：0=note_on  1=note_off  2=tempo 变化（此时 inc 字段装的是 tick_inc）

⚠️ 复位帧：头 0xA5 且 8 个 body 字节【全是 0xA5】⇒ 单独计数，⛔ 不参与节奏统计。

════════════════════════════════════════════════════════════════════════════════
⭐ 音乐时间

    PPQN = 960 tick / 四分音符；默认 120 BPM；默认 tick_inc = 164927

        一个 tick 的时长 = 60e6 / (bpm × ppqn)
        120 BPM 时      = 60e6 / (120 × 960) = 520.8333… µs

════════════════════════════════════════════════════════════════════════════════
⭐ 用法

    python pool_pace_check.py --port COM31 --seconds 30
    python pool_pace_check.py --port COM31 --seconds 60 --bpm 168
    python pool_pace_check.py --port COM31 --seconds 30 --expect-frames 4096
    python pool_pace_check.py --port COM31 --seconds 30 --save raw.bin --dump 20

返回码：0 = 节奏合格；1 = 节奏有问题；2 = 缺 pyserial；3 = 串口打不开；4 = 没数据
════════════════════════════════════════════════════════════════════════════════
"""

import argparse
import math
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK / 代码页 936，会炸）---------------
# ⭐ 本脚本要打印 emoji 和中文 ⇒ 这一步是【必须】的，⛔ 不是可选项。
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HDR_EVENT = 0xA5

# ---- 冻结契约的位域（⚠️ 改了这里就等于改了协议）------------------------------
B_TICK_MSB = 64
B_TICK_LSB = 44
B_INC_MSB = 43
B_INC_LSB = 22
B_AXIS_MSB = 21
B_AXIS_LSB = 18
B_VEL_MSB = 17
B_VEL_LSB = 11
B_KIND_MSB = 10
B_KIND_LSB = 9
B_TIMBRE_BIT = 8
B_RSVD_MSB = 7
B_RSVD_LSB = 0

KIND_NOTE_ON = 0
KIND_NOTE_OFF = 1
KIND_TEMPO = 2

KIND_NAME = {0: "note_on", 1: "note_off", 2: "tempo", 3: "kind3"}

# ---- 判据门限 ----------------------------------------------------------------
PACE_LO = 0.90          # ⭐ pace 允许带：±10%
PACE_HI = 1.10
BURST_GAP_MS = 2.0      # 墙钟间隔 < 2 ms ⇒ 认为"挨在一起"
BURST_TICK_MIN = 960    # 同时 tick 跨度 >= 1 个四分音符 ⇒ 认定是"倒水"


# ══════════════════════════════════════════════════════════════════════════════
# 小工具
# ══════════════════════════════════════════════════════════════════════════════
def stats(vals):
    """返回 (min, p50, p90, p99, max)，空表返回 None。"""
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)

    def pct(p):
        i = int(round((n - 1) * p))
        return s[max(0, min(n - 1, i))]

    return s[0], pct(0.50), pct(0.90), pct(0.99), s[-1]


def fmt5(st, unit, nd=2):
    """把 stats() 的 5 元组格式化。"""
    if st is None:
        return "  (无数据)"
    return ("min=%.*f  p50=%.*f  p90=%.*f  p99=%.*f  max=%.*f %s"
            % (nd, st[0], nd, st[1], nd, st[2], nd, st[3], nd, st[4], unit))


def bits(word, msb, lsb):
    """取 [msb:lsb]（闭区间，含两端，和 verilog 的 [msb:lsb] 同义）。"""
    return (word >> lsb) & ((1 << (msb - lsb + 1)) - 1)


# ══════════════════════════════════════════════════════════════════════════════
# ① 逐字节带时间戳的采集
# ══════════════════════════════════════════════════════════════════════════════
def recv_stamped(port, baud, seconds):
    """
    ⭐ 关键：**一次只 read(1)**，每收到 1 个字节立刻打一个 perf_counter 时间戳。

    ⚠️ 为什么不能用 ser.read(n) / ser.read(in_waiting)：
        pyserial 的 read(size) 是"**收满 size 个字节 或 读超时** 才返回"——
        ⚠️ 它返回的是【一整块】，块里那些【本来先后差几百微秒】的字节
        只能共用【一个】时间戳（而且这个戳是"read 返回的时刻"，
        即最后一个字节到达的时刻）。
        ⇒ 🔴 这样拿到的时间戳【不是每字节的到达时刻】，
          用它的差分去算"帧间间隔 / 放水节奏"，测的就是 read() 的调用节奏，
          ⛔ 不是串口线上的真实节奏 —— 本脚本的核心判据会直接被毁掉。

    ⚠️ 代价：Python 里一次 read(1) 的系统调用开销约 10~50 µs，
        分辨率【不足以】判 GAP_BYTES 那种 320 µs 级的字节间隔
        （那个交给 uart_timing_check.py）。
        ⭐ 但本脚本关心的是【毫秒级】的帧间/音乐节奏 ⇒ 完全够用。
    """
    import serial

    data = bytearray()
    stamps = []
    ser = serial.Serial(port, baud, timeout=0.05)
    try:
        ser.reset_input_buffer()
        t_end = time.perf_counter() + seconds
        while time.perf_counter() < t_end:
            b = ser.read(1)
            if b:
                stamps.append(time.perf_counter())   # ⭐ 立刻打戳
                data += b
    finally:
        ser.close()          # ⭐ 必须释放，否则下次烧录报 PermissionError(13)
    return bytes(data), stamps


# ══════════════════════════════════════════════════════════════════════════════
# ② 帧解码
# ══════════════════════════════════════════════════════════════════════════════
def decode_frame(buf):
    """9 字节 -> 字段 dict（⛔ 不判合法，判别放在调用方）。"""
    body = int.from_bytes(buf[1:9], "big")
    return {
        "tick": bits(body, B_TICK_MSB, B_TICK_LSB),
        "inc": bits(body, B_INC_MSB, B_INC_LSB),
        "axis": bits(body, B_AXIS_MSB, B_AXIS_LSB),
        "vel": bits(body, B_VEL_MSB, B_VEL_LSB),
        "kind": bits(body, B_KIND_MSB, B_KIND_LSB),
        "timbre": bits(body, B_TIMBRE_BIT, B_TIMBRE_BIT),
        "rsvd": bits(body, B_RSVD_MSB, B_RSVD_LSB),
    }


def selftest() -> int:
    """
    ⭐ 离线自检（⛔ 不需要硬件、不需要串口）。

    ⭐⭐ 为什么需要它（⭐ 2026-10-01 补）：
      🔴 本工具是【验收工具】—— ⚠️ 它算出来的节奏结论**直接进验收报告**
      ⇒ ⚠️ 它的解码/统计错了，**结论就不可信**。

    ⭐ 判据两层：① ⭐ 正例（字段/统计都对）② ⭐⭐ 反例（改坏必须判红）
    """
    print("=" * 74)
    print("pool_pace_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① bits() 本身 ----
    print("\n[1] bits() 取位（⭐ 与 verilog 的 [msb:lsb] 同义，含两端）")
    chk("   bits(0b1011, 3, 0) = 0b1011", bits(0b1011, 3, 0) == 0b1011)
    chk("   bits(0b1011, 2, 1) = 0b01", bits(0b1011, 2, 1) == 0b01)
    chk("   bits(0xFFFFFFFF, 7, 0) = 0xFF", bits(0xFFFFFFFF, 7, 0) == 0xFF)

    # ---- ② ⭐ decode_frame：字段逐个核对 ----
    print("\n[2] ⭐ decode_frame：字段逐个核对")
    tick, inc, axis, vel, kind, timbre, rsvd = (
        0xABCDE, 0x123456, 0xA, 0x55, 2, 1, 0)
    body = ((tick << 44) | (inc << 22) | (axis << 18) | (vel << 11) |
            (kind << 9) | (timbre << 8) | rsvd)
    buf = bytes([HDR_EVENT]) + body.to_bytes(8, "big")
    d = decode_frame(buf)
    for k, want in (("tick", tick), ("inc", inc), ("axis", axis), ("vel", vel),
                    ("kind", kind), ("timbre", timbre), ("rsvd", rsvd)):
        chk("   %-7s = %s（期望 %s）" % (k, d[k], hex(want)), d[k] == want)

    # ---- ③ ⚠️ tick 位宽守卫（⭐ 钉住一个"看起来像 bug 但不是"的地方）----
    print("\n[3] ⚠️ tick 位宽守卫（⭐ 防止有人把常量'修'成错的）")
    full = bytes([HDR_EVENT]) + b"\xff" * 8
    tf = decode_frame(full)["tick"]
    chk("   全 1 时 tick = 0xFFFFF（⭐ 20 位，⛔ 不是 21 位）", tf == 0xFFFFF,
        "  实测 0x%X" % tf)
    # ⚠️ 说明：B_TICK_MSB 写的是 64（⚠️ 对 64 位字来说越界），
    #    ⭐ 但 `body >> 44` 天然只剩 20 位 ⇒ 结果与 [63:44] 一致 ⇒ ✅ 无害。
    #    ⭐ 这一条把它【钉死】：谁改成 63 或别的值，只要结果不对就会红。
    chk("   与 uart_rx_check 的 (w>>44)&0xFFFFF 一致",
        tf == ((int.from_bytes(b"\xff" * 8, "big") >> 44) & 0xFFFFF))

    # ---- ④ stats() ----
    print("\n[4] stats() 分位数")
    chk("   空表 -> None", stats([]) is None)
    chk("   单元素 -> 五元组全等", stats([7]) == (7, 7, 7, 7, 7))
    s = stats(list(range(1, 101)))          # 1..100
    chk("   1..100: min=1 max=100", s[0] == 1 and s[4] == 100)
    chk("   1..100: p50 在 50 附近", 49 <= s[1] <= 51, "  实测 %s" % s[1])
    chk("   1..100: p90 在 90 附近", 89 <= s[2] <= 91, "  实测 %s" % s[2])
    chk("   单调不减", s[0] <= s[1] <= s[2] <= s[3] <= s[4])

    # ---- ⑤ ⭐⭐ 反例（非空洞性）----
    print("\n[5] ⭐⭐ 反例：改坏必须能被发现")
    # ⭐ 5a：把 kind 位置写脏 ⇒ 解码必须跟着变（⭐ 说明它真在读那几位）
    b2 = bytearray(buf)
    w2 = int.from_bytes(bytes(b2[1:9]), "big") ^ (1 << 9)   # 翻 kind 最低位
    b2[1:9] = w2.to_bytes(8, "big")
    chk("   翻 kind 位后 kind 变化", decode_frame(bytes(b2))["kind"] != kind)
    # ⭐ 5b：错期望值必须判红
    chk("   错期望值会被判红（⭐ 非空洞）", d["tick"] != 0x12345)
    # ⭐ 5c：stats 对【倒序】输入必须给出同样的分位数（⭐ 它内部要排序）
    rev = stats(list(range(100, 0, -1)))
    chk("   倒序输入的分位数与正序一致", rev == s)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="抓 UART 字节流（逐字节时间戳）并验证水池放水的【音乐节奏】")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件/串口）")
    ap.add_argument("--port", help="USB-TTL 口，如 COM31")
    ap.add_argument("--baud", type=int, default=500000,
                    help="必须与固件 / FPGA 侧一致（默认 500000）")
    ap.add_argument("--seconds", type=float, default=30.0, help="监听秒数（默认 30）")
    ap.add_argument("--bpm", type=float, default=120.0,
                    help="曲目 BPM（⭐ 判据要用它算 tick 时长，默认 120）")
    ap.add_argument("--ppqn", type=int, default=960, help="每四分音符 tick 数（默认 960）")
    ap.add_argument("--save", default="", help="原始字节另存到该路径")
    ap.add_argument("--dump", type=int, default=12, help="详细打印前 N 帧（默认 12）")
    ap.add_argument("--expect-frames", type=int, default=0,
                    help="预期帧数，用于交叉核对（0 = 不核对）")
    args = ap.parse_args(argv)

    # ⭐ 自检优先 —— ⚠️ 不需要 --port（⭐ 便于批量自检统一调用）
    if args.selftest:
        return selftest()
    if not args.port:
        print("🔴 需要 --port（⚠️ 或用 --selftest）")
        return 2

    # 懒加载 pyserial ------------------------------------------------------
    try:
        import serial  # noqa: F401
    except ImportError:
        print("🔴 缺 pyserial —— 请先安装：")
        print("     pip install pyserial")
        return 2

    # ---- 音乐时间换算 -----------------------------------------------------
    if args.bpm <= 0 or args.ppqn <= 0:
        print("🔴 --bpm / --ppqn 必须为正数")
        return 3
    us_per_tick = 60.0e6 / (args.bpm * args.ppqn)      # 120 BPM => 520.833… µs
    tick_inc_ref = round((1 << 32) * (args.bpm * args.ppqn / 60.0) / 50e6)

    print("=" * 78)
    print("水池放水 · 音乐节奏验证（pool_pace_check）")
    print("=" * 78)
    print("口 = %-10s 波特率 = %d" % (args.port, args.baud))
    print("曲目 = %.4g BPM × PPQN %d" % (args.bpm, args.ppqn))
    print("⭐ 1 tick = %.4f µs   1 四分音符 = %.4f ms"
          % (us_per_tick, us_per_tick * args.ppqn / 1000.0))
    print("   （参考：该 BPM 的 tick_inc 应为 %d）" % tick_inc_ref)
    print()
    print("监听 %.1f 秒 ...（⭐ 现在去复位 ESP32 / 开始放水）" % args.seconds)
    print()

    # ---- 采集 -------------------------------------------------------------
    t0 = time.perf_counter()
    try:
        data, stamps = recv_stamped(args.port, args.baud, args.seconds)
    except Exception as exc:
        print("🔴 串口打不开/读失败：%s" % exc)
        print("   排查：① 口对不对（设备管理器）② 有没有别的程序占着（串口助手/烧录器）")
        print("        ③ 上一次没 close ⇒ 拔插一次 USB-TTL")
        return 3
    wall_total = time.perf_counter() - t0

    print("-" * 78)
    print("实际监听 %.3f s，收到 %d 字节" % (wall_total, len(data)))

    if not data:
        print()
        print("🔴 0 字节 —— 排查：")
        print("   ① 固件真的在放水吗？（pool_start() 有没有被调用 —— 见矛盾裁定单）")
        print("   ② 接线：ESP32 GPIO17(TX) → USB-TTL RXD（⚠️ 交叉）")
        print("   ③ 共地：GND -- GND")
        print("   ④ 波特率两端一致？（--baud 与固件是不是都是 %d）" % args.baud)
        return 4

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(args.save, "wb") as f:
            f.write(data)
        print("原始字节已存: %s" % os.path.abspath(args.save))

    # ---- 9N 对齐 + 帧头 ---------------------------------------------------
    print()
    print("---- 9N 对齐 + 帧头 ----")
    rem = len(data) % FRAME_BYTES
    nf = len(data) // FRAME_BYTES
    aligned = (rem == 0)
    print("  9N 对齐: %s（%d 字节 = %d 帧，余 %d）"
          % ("✅" if aligned else "🔴", len(data), nf, rem))
    if not aligned:
        print("     🔴 余数非 0 ⇒ ①抓包从半帧开始的常见原因：复位时机太晚；")
        print("        ②真丢字节。⚠️ 下面按 9 字节硬切，结果仅供参考。")

    bad_hdr = [(i, data[i * FRAME_BYTES]) for i in range(nf)
               if data[i * FRAME_BYTES] != HDR_EVENT]
    print("  帧头 0xA5: %d/%d %s" % (nf - len(bad_hdr), nf,
                                    "✅" if not bad_hdr else "🔴"))
    for i, h in bad_hdr[:8]:
        print("     帧 #%-6d 帧头=0x%02X" % (i, h))
    if len(bad_hdr) > 8:
        print("     ... 还有 %d 个" % (len(bad_hdr) - 8))

    # ---- 逐帧解码 ---------------------------------------------------------
    # ⚠️ 时间戳数组与字节数组理论上 1:1，但⛔ 不假设它一定对齐：
    #    下标的越界由 _stamp_at() 兜底，避免一个异常把整轮判据全废掉。
    def _stamp_at(k):
        if 0 <= k < len(stamps):
            return stamps[k]
        return stamps[-1] if stamps else 0.0

    events = []          # ⭐ 参与节奏统计的 event 帧
    resets = []          # 复位帧（全 0xA5）
    rsvd_bad = []
    for i in range(nf):
        fr = data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
        if fr[0] != HDR_EVENT:
            continue
        payload = fr[1:9]
        if payload == b"\xA5" * 8:
            resets.append((i, _stamp_at(i * FRAME_BYTES)))
            continue
        d = decode_frame(fr)
        d["idx"] = i
        d["t"] = _stamp_at(i * FRAME_BYTES)
        events.append(d)
        if d["rsvd"] != 0:
            rsvd_bad.append(d)

    print()
    print("---- 帧分类 ----")
    print("  event 帧 = %d" % len(events))
    print("  复位帧(全0xA5) = %d %s" % (len(resets),
                                       "" if not resets else "⚠️（会打断放水节奏）"))
    for idx, t in resets[:6]:
        print("     帧 #%-6d t=%s" % (idx, ("%.6f" % t) if t else "?"))
    kc = {0: 0, 1: 0, 2: 0, 3: 0}
    for e in events:
        kc[e["kind"]] = kc.get(e["kind"], 0) + 1
    print("  kind 分布: note_on=%d  note_off=%d  tempo=%d  其它=%d"
          % (kc.get(0, 0), kc.get(1, 0), kc.get(2, 0), kc.get(3, 0)))
    print("  rsvd 非 0: %d %s" % (len(rsvd_bad), "✅" if not rsvd_bad else "🔴"))
    for e in rsvd_bad[:5]:
        print("     帧 #%-6d rsvd=%d" % (e["idx"], e["rsvd"]))

    if args.expect_frames:
        delta = len(events) - args.expect_frames
        print("  预期帧数 = %d，实测 = %d，差 = %+d %s"
              % (args.expect_frames, len(events), delta,
                 "✅" if delta == 0 else "⚠️"))

    # ---- 详细打印 ---------------------------------------------------------
    if args.dump and events:
        print()
        print("---- 前 %d 帧明细 ----" % min(args.dump, len(events)))
        print("  %-7s %-10s %-10s %-5s %-4s %-6s %-3s %-5s %s"
              % ("#", "tick", "inc", "axis", "vel", "kind", "tr", "rsvd", "t-rel(s)"))
        t_base = events[0]["t"]
        for e in events[:args.dump]:
            print("  %-7d %-10d %-10d %-5d %-4d %-6s %-3d %-5d %.6f"
                  % (e["idx"], e["tick"], e["inc"], e["axis"], e["vel"],
                     KIND_NAME.get(e["kind"], "?"), e["timbre"], e["rsvd"],
                     e["t"] - t_base))

    if len(events) < 2:
        print()
        print("🔴 event 帧不足 2 个，⛔ 没法算节奏。")
        print("=" * 78)
        return 1

    # ══════════════════════════════════════════════════════════════════════
    # ⭐⭐ 核心判据：音乐节奏（pace）
    # ══════════════════════════════════════════════════════════════════════
    first, last = events[0], events[-1]
    tick_span = last["tick"] - first["tick"]
    wall_span = last["t"] - first["t"]
    expect_wall = tick_span * us_per_tick / 1e6          # 应有墙钟秒数

    print()
    print("=" * 78)
    print("⭐⭐ 核心判据 · 放水节奏（pace）")
    print("=" * 78)
    print("  首帧: tick=%d  t=%.6f" % (first["tick"], first["t"]))
    print("  末帧: tick=%d  t=%.6f" % (last["tick"], last["t"]))
    print()
    print("  tick_span（音乐时长）   = %d tick" % tick_span)
    print("                          = %.3f 拍 = %.3f 小节(4/4)"
          % (tick_span / float(args.ppqn), tick_span / float(args.ppqn * 4)))
    print("  wall_span（实测墙钟）   = %.6f s" % wall_span)
    print("  expect_wall（应有墙钟） = tick_span × %.6f µs = %.6f s"
          % (us_per_tick, expect_wall))

    pace = (wall_span / expect_wall) if expect_wall > 0 else float("inf")
    ok_pace = (PACE_LO <= pace <= PACE_HI)

    print()
    print("  ⭐⭐ pace = 实测 / 应有 = %.6f   （判据：%.2f ~ %.2f）"
          % (pace, PACE_LO, PACE_HI))
    if ok_pace:
        print("      ✅ 放水节奏【正确】—— 固件在按音乐时间限流")
    elif pace < PACE_LO:
        print("      🔴 放水【过快】—— 比音乐时间快 %.1f 倍 ⇒ 限流没生效"
              % (1.0 / pace if pace > 0 else float("inf")))
    else:
        print("      🔴 放水【过慢】—— 只有应有速度的 %.1f%% ⇒ 卡住了/被饿死"
              % (pace * 100.0))

    # 等效 BPM（把实测墙钟当成真的，反推固件实际在跑什么速度）
    if wall_span > 0 and tick_span > 0:
        eff_bpm = tick_span / (wall_span * args.ppqn) * 60.0
        print("      ⭐ 若以实测墙钟为准，等效 BPM = %.4f（名义 %.4g）"
              % (eff_bpm, args.bpm))

    # 线性度：tick 对墙钟做最小二乘，看 R²
    ts = [e["t"] - first["t"] for e in events]
    tk = [float(e["tick"] - first["tick"]) for e in events]
    n = float(len(events))
    mt = sum(ts) / n
    mk = sum(tk) / n
    sxx = sum((x - mt) ** 2 for x in ts)
    sxy = sum((ts[i] - mt) * (tk[i] - mk) for i in range(len(ts)))
    syy = sum((y - mk) ** 2 for y in tk)
    slope = (sxy / sxx) if sxx > 0 else 0.0        # tick / s
    # ⚠️ 离散 tick（整数）会让 R² 天然偏低，只能当"趋势"看，⛔ 不当硬判据
    r2 = (sxy * sxy / (sxx * syy)) if (sxx > 0 and syy > 0) else 0.0
    print()
    print("  ---- 线性度（tick 应随墙钟线性增长）----")
    print("     拟合斜率 = %.3f tick/s（⭐ 名义 %.3f tick/s）"
          % (slope, args.bpm * args.ppqn / 60.0))
    print("     R² = %.6f  ⚠️ tick 是整数、有量化台阶 ⇒ R² 只作趋势参考" % r2)
    if slope > 0:
        print("     斜率比 = 拟合/名义 = %.4f" % (slope / (args.bpm * args.ppqn / 60.0)))

    # ══════════════════════════════════════════════════════════════════════
    # 帧间间隔分布
    # ══════════════════════════════════════════════════════════════════════
    wall_gaps = [(events[i + 1]["t"] - events[i]["t"]) * 1e3
                 for i in range(len(events) - 1)]          # ms
    tick_gaps = [events[i + 1]["tick"] - events[i]["tick"]
                 for i in range(len(events) - 1)]

    print()
    print("---- 相邻 event 帧的间隔分布 ----")
    print("  墙钟间隔(ms):  n=%d  %s" % (len(wall_gaps), fmt5(stats(wall_gaps), "ms", 3)))
    print("  tick 间隔    :  n=%d  %s" % (len(tick_gaps), fmt5(stats(tick_gaps), "tick", 1)))

    pos = [g for g in tick_gaps if g > 0]
    if pos:
        print("  tick 间隔>0  :  n=%d  %s" % (len(pos), fmt5(stats(pos), "tick", 1)))
        st_pos = stats(pos)
        print("  ⭐ 由中位间隔反推的【瞬时节奏比】 = %.4f"
              % (st_pos[1] * us_per_tick / 1e3
                 / max(1e-9, stats(wall_gaps)[1])))
        print("     （= 该 tisk 间隔应有的墙钟 / 该间隔实测墙钟；≈1 才对）")

    # ---- 时长一致性：末帧到达时刻 vs 应有 ---------------------------------
    print()
    print("---- 时间线一致性 ----")
    print("  抓包总时长 = %.3f s（--seconds %.1f）" % (wall_total, args.seconds))
    if tick_span > 0 and wall_total > 0:
        print("  期间音乐进度 = %d tick = %.3f 拍"
              % (tick_span, tick_span / float(args.ppqn)))

    # ══════════════════════════════════════════════════════════════════════
    # 突发倒水检测
    # ══════════════════════════════════════════════════════════════════════
    print()
    print("---- 突发倒水检测（⭐ 经典故障：不限速、能多快就多快）----")
    burst_runs = []      # 连续"墙钟几乎不动、tick 却跨度很大"的段
    i = 0
    while i < len(events) - 1:
        j = i
        while (j < len(events) - 1
               and (events[j + 1]["t"] - events[j]["t"]) * 1e3 < BURST_GAP_MS):
            j += 1
        if j > i:
            span_t = events[j]["tick"] - events[i]["tick"]
            span_w = (events[j]["t"] - events[i]["t"]) * 1e3
            if span_t >= BURST_TICK_MIN:
                burst_runs.append((i, j, j - i + 1, span_t, span_w))
        i = j + 1

    n_burst = sum(r[2] for r in burst_runs)
    frac_burst = n_burst / float(len(events))
    print("  判据：连续帧墙钟间隔 < %.1f ms，且这段 tick 跨度 >= %d tick"
          % (BURST_GAP_MS, BURST_TICK_MIN))
    print("  命中 %d 段，涉及 %d 帧（占 %.1f%%）"
          % (len(burst_runs), n_burst, frac_burst * 100.0))
    if burst_runs:
        for a, b, cnt, st_, sw in sorted(burst_runs, key=lambda r: -r[3])[:5]:
            print("     帧 #%-6d..#%-6d 共 %-4d 帧  tick 跨 %-8d (%.2f 拍) 墙钟仅 %.3f ms"
                  % (events[a]["idx"], events[b]["idx"], cnt, st_,
                     st_ / float(args.ppqn), sw))
        print("     ⇒ 🔴 这些帧在音乐上相隔很远，却在墙钟上挤成一团")
    else:
        print("  ✅ 未发现突发倒水段")

    # ---- tempo 变化 -------------------------------------------------------
    tempo_ev = [e for e in events if e["kind"] == KIND_TEMPO]
    print()
    print("---- tempo 变化事件（kind==2）----")
    print("  共 %d 个" % len(tempo_ev))
    if tempo_ev:
        print("  ⚠️ 注意：tempo 事件会【重新锚定时间基准】⇒")
        print("     紧邻它的前后若干帧出现小的节奏台阶是【正常现象】，")
        print("     ⛔ 不要把它当成 pace 故障；但也意味着 span 跨多个 tempo 段时")
        print("     本脚本的单一 pace 值只是【整段平均】（用 --bpm 给的是名义值）。")
        for e in tempo_ev[:12]:
            print("     帧 #%-6d tick=%-10d tick_inc=%-10d t=%.6f"
                  % (e["idx"], e["tick"], e["inc"], e["t"]))
        if len(tempo_ev) > 12:
            print("     ... 还有 %d 个" % (len(tempo_ev) - 12))
    else:
        print("  （无 tempo 事件 ⇒ 全曲单一速度，pace 判据最干净 ✅）")

    # ══════════════════════════════════════════════════════════════════════
    # ⭐ 最终结论
    # ══════════════════════════════════════════════════════════════════════
    print()
    print("=" * 78)
    print("最终结论")
    print("=" * 78)

    reasons = []
    verdict = True

    if aligned:
        reasons.append("✅ 9N 对齐")
    else:
        reasons.append("🔴 9N 不对齐（余 %d 字节）" % rem)
        verdict = False

    if not bad_hdr:
        reasons.append("✅ 全部帧头 0xA5")
    else:
        reasons.append("🔴 %d 个帧头不是 0xA5" % len(bad_hdr))
        verdict = False

    if not rsvd_bad:
        reasons.append("✅ rsvd 全为 0")
    else:
        reasons.append("🔴 %d 帧 rsvd 非 0（位域串了）" % len(rsvd_bad))
        verdict = False

    if ok_pace:
        reasons.append("✅ 放水节奏 pace=%.4f ∈ [%.2f, %.2f]" % (pace, PACE_LO, PACE_HI))
    else:
        reasons.append("🔴 放水节奏 pace=%.4f 超出 [%.2f, %.2f]" % (pace, PACE_LO, PACE_HI))
        verdict = False

    if frac_burst > 0.10:
        reasons.append("🔴 %.1f%% 的帧处在突发倒水段（不限速）" % (frac_burst * 100.0))
        verdict = False
    elif burst_runs:
        reasons.append("⚠️ 有 %.1f%% 的帧在小突发段（未必是错，看 pace）"
                       % (frac_burst * 100.0))
    else:
        reasons.append("✅ 无突发倒水")

    for r in reasons:
        print("  " + r)

    print()
    if verdict:
        print("  ✅ 放水节奏【合格】：固件按音乐时间（%.4g BPM × PPQN %d）放水，"
              % (args.bpm, args.ppqn))
        print("     pace=%.4f ≈ 1.0，节奏比与曲目速度一致。" % pace)
    else:
        print("  🔴 放水节奏【不合格】—— 见上面标红项。")
        if pace < PACE_LO:
            print("     ⭐ 最可能：放水循环【没有按 tick 限流】（能多快就多快）。")
            print("        查 pool_pump() 里的 due_tick 计算 / 有没有真正的 sleep 等待，")
            print("        以及 pool_start() 到底有没有被调用。")
        elif pace > PACE_HI:
            print("     ⭐ 最可能：放水被【饿死/卡住】—— UART 阻塞、或 tick 源太快。")
        if not aligned or bad_hdr:
            print("     ⚠️ 先修对齐/帧头问题，否则节奏结论不可信。")
    print("=" * 78)
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
