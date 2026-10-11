#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
score_word.py -- 曲谱事件字（64 bit）的【唯一定义处】。

为什么单独成一个模块
================================================================================
本项目有两个发送工具，各自拼同一个 64 bit 事件字：
    esp32/tools/send_frames.py       走串口（PC -> USB-TTL -> ESP32）
    esp32/tools/send_frames_ble.py   走 BLE （PC -> BLE -> ESP32）

2026-10-01 实测发现：这两个工具的位域【不一致】，而且 BLE 那个是旧的。

    send_frames.py:108-113        inc<<23 / axis<<19 / vel<<11 8bit / timbre<<7 2bit
    send_frames_ble.py:151-156    inc<<22 / axis<<18 / vel<<11 7bit / timbre<<8 1bit
                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 2026-09-22 修订【之前】的布局

而 FPGA 与固件两侧用的都是【新】布局：
    FPGA2026/rtl/top.v:3594-3616   inc[43:23] axis[22:19] vel[18:11] kind[10:9] timbre[8:7]
    esp32/ble/main/pool.c:60-63    inc[43:23] kind[10:9]

后果（BLE 路径发出去的谱面，FPGA 会这样解）：
    inc    FPGA 读 [43:23]，工具写在 [43:22]   => 得到 inc>>1（低一个八度）
    axis   FPGA 读 [22:19]，工具写在 [21:18]   => 得到 axis>>1（轴号减半）
    vel    FPGA 读 8 bit，工具只写 7 bit       => 丢最高位
    timbre FPGA 读 [8:7]，工具写在 [8]         => 只剩 1 bit，且位置错

为什么一直没被发现
    ESP32 侧固件只读 tick[63:44] 与 kind[10:9]（这两个字段两个布局恰好相同），
    而 e2e_accept.py 的判据是 sent/ovf/late/mm 这类【传输层计数】，
    根本不解码 inc/axis/vel/timbre。
    => 位域错得完全看不出来，直到真的接上 FPGA 听声音才会暴露。

本模块的作用
    把位域收到这一个文件，两个发送工具都 import 它。
    => “再次漂移”在结构上不可能发生（而不是靠“记得两边一起改”）。

位域（硬契约，与 FPGA2026/rtl/top.v:3594-3616 逐位一致）
================================================================================
    bit 63..44   tick    20 bit   音乐时间，PPQN=960
    bit 43..23   inc     21 bit   phase_inc；kind==2 时重解释为 tick_inc
    bit 22..19   axis     4 bit   轴号 0..15
    bit 18..11   vel      8 bit   力度
    bit 10..9    kind     2 bit   0=note_on 1=note_off 2=tempo 3=未使用
    bit  8..7    timbre   2 bit   音色 0..3
    bit  6..0             7 bit   保留，必须写 0
"""

import os
import sys

# 控制台 UTF-8：中文 Windows 默认 GBK，打印中文/符号会 UnicodeEncodeError
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ============================================================================
# 位域常量（唯一真源）
# ============================================================================
OFF_TICK   = 44
OFF_INC    = 23
OFF_AXIS   = 19
OFF_VEL    = 11
OFF_KIND   = 9
OFF_TIMBRE = 7

MASK_TICK   = 0xFFFFF
MASK_INC    = 0x1FFFFF
MASK_AXIS   = 0xF
MASK_VEL    = 0xFF
MASK_KIND   = 0x3
MASK_TIMBRE = 0x3
MASK_RESERVED = 0x7F

KIND_ON    = 0
KIND_OFF   = 1
KIND_TEMPO = 2
KIND_NAMES = {KIND_ON: "on", KIND_OFF: "off", KIND_TEMPO: "tempo"}

# 旧位域（2026-09-22 修订之前）。
# 只用于自检里构造反例，禁止出现在任何发送路径上。
OLD_OFF_INC     = 22
OLD_OFF_AXIS    = 18
OLD_OFF_TIMBRE  = 8
OLD_MASK_INC    = 0x3FFFFF
OLD_MASK_VEL    = 0x7F
OLD_MASK_TIMBRE = 0x1

# ============================================================================
# 帧层常量（与固件 / FPGA 一致）
# ============================================================================
FRAME_BYTES  = 9
HDR_EVENT    = 0xA5
HDR_TOTAL    = 0x00
RESET_FRAMES = 4


# ============================================================================
# 打包 / 解包
# ============================================================================
def pack_word(tick, inc, axis, vel, kind, timbre):
    """把六个字段拼成一个 64 bit 事件字。超范围的值按掩码截断。"""
    return (((tick   & MASK_TICK)   << OFF_TICK) |
            ((inc    & MASK_INC)    << OFF_INC) |
            ((axis   & MASK_AXIS)   << OFF_AXIS) |
            ((vel    & MASK_VEL)    << OFF_VEL) |
            ((kind   & MASK_KIND)   << OFF_KIND) |
            ((timbre & MASK_TIMBRE) << OFF_TIMBRE))


def unpack_word(word):
    """按 FPGA 的切片方式解出一个事件字。字段名与 FPGA 侧一致。"""
    return {
        "tick":   (word >> OFF_TICK)   & MASK_TICK,
        "inc":    (word >> OFF_INC)    & MASK_INC,
        "axis":   (word >> OFF_AXIS)   & MASK_AXIS,
        "vel":    (word >> OFF_VEL)    & MASK_VEL,
        "kind":   (word >> OFF_KIND)   & MASK_KIND,
        "timbre": (word >> OFF_TIMBRE) & MASK_TIMBRE,
    }


def reserved_bits(word):
    """返回保留位（bit 6..0）的值。契约要求恒为 0。"""
    return word & MASK_RESERVED


def frame_from_word(word):
    """9 字节事件帧 = 0xA5 + 8 字节大端载荷。"""
    return bytes([HDR_EVENT]) + (word & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")


def reset_sequence(n=RESET_FRAMES):
    """复位序列 = n 个全 0xA5 帧。长度必须是 9 的整数倍。"""
    return bytes([HDR_EVENT]) * (FRAME_BYTES * n)


def frame_total(n_events):
    """总数帧 = 0x00 + 8 字节大端总事件数。

    单独一个帧头，让 ESP32 一眼区分“这是总数不是事件”，不必猜某个位置的语义。
    """
    return bytes([HDR_TOTAL]) + int(n_events).to_bytes(8, "big")


def build_payload(words, with_reset=True, with_total=True):
    """把事件字列表拼成完整下发载荷：复位序列 + 总数帧 + 事件帧。"""
    parts = []
    if with_reset:
        parts.append(reset_sequence())
    if with_total:
        parts.append(frame_total(len(words)))
    for w in words:
        parts.append(frame_from_word(w))
    return b"".join(parts)


# ============================================================================
# 读 mid2evt.py 的产物 events.hex
# ============================================================================
def load_events_hex(path):
    """读 events.hex，返回 (words, problems)。

    格式：每行一个 16 位十六进制数（= 8 字节 / 64 bit 大端），无帧头。
          mid2evt.py 就是这么写的，帧头 0xA5 由发送方补。

    本函数做三项校验（不通过就记进 problems，但该行仍然保留，
    让调用方自己决定是拒发还是照发）：
        1. 行长必须是 16（含空白已 strip）
        2. 保留位 bit[6:0] 必须是 0
        3. kind 不能是 3（未使用）
    """
    words = []
    problems = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            if len(line) != 16:
                problems.append("第 %d 行：长度 %d，应为 16" % (lineno, len(line)))
                continue
            try:
                word = int(line, 16)
            except ValueError:
                problems.append("第 %d 行：不是十六进制「%s」" % (lineno, line))
                continue
            if reserved_bits(word):
                problems.append("第 %d 行：保留位非 0（0x%02X）" % (lineno, reserved_bits(word)))
            if unpack_word(word)["kind"] == 3:
                problems.append("第 %d 行：kind==3 未使用" % lineno)
            words.append(word)
    return words, problems


def summarize(words):
    """统计各 kind 条数 + tick 范围。给 --hex 的打印用。"""
    from collections import Counter
    c = Counter()
    tmin = None
    tmax = None
    for w in words:
        d = unpack_word(w)
        c[d["kind"]] += 1
        t = d["tick"]
        tmin = t if tmin is None else min(tmin, t)
        tmax = t if tmax is None else max(tmax, t)
    return {
        "total": len(words),
        "kinds": {KIND_NAMES.get(k, "kind%d" % k): v for k, v in sorted(c.items())},
        "tick_min": tmin,
        "tick_max": tmax,
    }


# ============================================================================
# 自检（不需要硬件）
# ============================================================================
def selftest():
    """自检。判据必须能失败：下面第 [5] 组专门构造“旧位域”的反例。"""
    print("=" * 74)
    print("score_word.py 离线自检（不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-52s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and bool(cond)

    print("\n[1] 位域与 FPGA 的切片逐位一致")
    # 与 FPGA2026/rtl/top.v:3594-3616 的六个切片逐条对齐
    chk("   inc 在 [43:23]（21 bit）", (OFF_INC, MASK_INC) == (23, 0x1FFFFF))
    chk("   axis 在 [22:19]（4 bit）", (OFF_AXIS, MASK_AXIS) == (19, 0xF))
    chk("   vel 在 [18:11]（8 bit）", (OFF_VEL, MASK_VEL) == (11, 0xFF))
    chk("   kind 在 [10:9]（2 bit）", (OFF_KIND, MASK_KIND) == (9, 0x3))
    chk("   timbre 在 [8:7]（2 bit）", (OFF_TIMBRE, MASK_TIMBRE) == (7, 0x3))
    chk("   tick 在 [63:44]（20 bit）", (OFF_TICK, MASK_TICK) == (44, 0xFFFFF))
    chk("   六个字段无重叠、无空洞",
        OFF_TICK == 44 and
        OFF_TICK + 20 == 64 and
        OFF_INC + 21 == OFF_TICK and
        OFF_AXIS + 4 == OFF_INC and
        OFF_VEL + 8 == OFF_AXIS and
        OFF_KIND + 2 == OFF_VEL and
        OFF_TIMBRE + 2 == OFF_KIND and
        MASK_RESERVED == (1 << OFF_TIMBRE) - 1)

    print("\n[2] 打包 -> 解包 往返（含极值）")
    cases = [
        dict(tick=0, inc=0, axis=0, vel=0, kind=KIND_ON, timbre=0),
        dict(tick=0xFFFFF, inc=0x1FFFFF, axis=0xF, vel=0xFF,
             kind=KIND_TEMPO, timbre=0x3),
        dict(tick=414720, inc=219902, axis=9, vel=130, kind=KIND_OFF, timbre=1),
    ]
    for c in cases:
        w = pack_word(**c)
        d = unpack_word(w)
        same = all(d[k] == c[k] for k in c)
        chk("   往返 tick=%d inc=%d axis=%d vel=%d kind=%d timbre=%d"
            % (c["tick"], c["inc"], c["axis"], c["vel"], c["kind"], c["timbre"]), same,
            "" if same else "  解出=%s" % d)
        chk("   保留位恒为 0（本用例）", reserved_bits(w) == 0,
            "  0x%02X" % reserved_bits(w))

    print("\n[3] 与【真实产物】逐项对齐（events.hex 的首行 / 第 2 行）")
    # 取自 FPGA2026/build/score/regen/09_Conjurer/events.hex，
    # 期望值取自同目录的 events.csv（人可读，用来交叉验证）
    real = [
        ("000001c2f9000400", dict(tick=0, inc=230898, vel=0, axis=0, timbre=0,
                                  kind=KIND_TEMPO)),
        ("0000001d4b841080", dict(tick=0, inc=14999, vel=130, axis=0, timbre=1,
                                  kind=KIND_ON)),
    ]
    for hexstr, want in real:
        d = unpack_word(int(hexstr, 16))
        same = all(d[k] == want[k] for k in want)
        chk("   %s 解出 tick=%d inc=%d vel=%d axis=%d timbre=%d kind=%d"
            % (hexstr, d["tick"], d["inc"], d["vel"], d["axis"], d["timbre"], d["kind"]),
            same, "" if same else "  期望=%s" % want)

    print("\n[4] 帧层")
    w = pack_word(tick=1000, inc=164927, axis=3, vel=100, kind=KIND_ON, timbre=1)
    fr = frame_from_word(w)
    chk("   事件帧 9 字节", len(fr) == FRAME_BYTES)
    chk("   帧头 = 0xA5", fr[0] == HDR_EVENT)
    chk("   载荷大端往返", int.from_bytes(fr[1:], "big") == w)
    chk("   复位序列 36 字节 = 4 帧", len(reset_sequence()) == 36)
    tf = frame_total(11865)
    chk("   总数帧 = 0x00 + 8B 大端", tf[0] == HDR_TOTAL and
        int.from_bytes(tf[1:], "big") == 11865)
    chk("   总数帧帧头与事件帧不同（永不撞车）", HDR_TOTAL != HDR_EVENT)
    payload = build_payload([w, w])
    chk("   载荷 = 36 + 9 + 2*9 = 63 字节", len(payload) == 63)
    chk("   载荷长度是 9 的整数倍", len(payload) % FRAME_BYTES == 0)

    print("\n[5] 反例（非空洞性）：旧位域必须能被抓出来")
    # 这是本模块存在的理由。用 2026-09-22 修订【之前】的布局解同一个字，
    # 结果必须与正确解【不同】；若相同，说明这个判据抓不住那次漂移。
    w2 = pack_word(tick=1000, inc=164927, axis=3, vel=100, kind=KIND_ON, timbre=1)
    old_inc    = (w2 >> OLD_OFF_INC)    & OLD_MASK_INC
    old_axis   = (w2 >> OLD_OFF_AXIS)   & MASK_AXIS
    old_vel    = (w2 >> OFF_VEL)        & OLD_MASK_VEL
    old_timbre = (w2 >> OLD_OFF_TIMBRE) & OLD_MASK_TIMBRE
    chk("   旧布局解出的 inc 与正确值不同（旧 22 位 vs 新 23 位）",
        old_inc != 164927, "  旧解=%d 正解=164927" % old_inc)
    chk("   旧布局解出的 axis 与正确值不同", old_axis != 3,
        "  旧解=%d 正解=3" % old_axis)
    chk("   旧布局解出的 timbre 与正确值不同", old_timbre != 1,
        "  旧解=%d 正解=1" % old_timbre)
    # 方向 1：拿【旧偏移】去解一个【正确打包】的字 => 偏移差 1 位 => 结果翻倍。
    #         这只说明“偏移不同”，不是本次的真实故障方向。
    chk("   旧偏移去解正确字 => inc 翻倍（偏移差 1 位）",
        old_inc == 164927 * 2, "  旧解=%d 正解=164927" % old_inc)
    # 方向 2（本次真实故障方向）：按【旧布局打包】，再让 FPGA 按【新偏移】去读。
    #         FPGA 读到的是 inc>>1 => 音高低一个八度。这条是本模块存在的理由。
    wrong = (((1000 & MASK_TICK) << 44) |
             ((164927 & OLD_MASK_INC) << OLD_OFF_INC) |
             ((3 & MASK_AXIS) << OLD_OFF_AXIS) |
             ((100 & OLD_MASK_VEL) << OFF_VEL) |
             ((KIND_ON & MASK_KIND) << OFF_KIND) |
             ((1 & OLD_MASK_TIMBRE) << OLD_OFF_TIMBRE))
    chk("   按旧布局打包 => FPGA 解出的 inc 不是 164927",
        unpack_word(wrong)["inc"] != 164927,
        "  FPGA 会解出 inc=%d" % unpack_word(wrong)["inc"])
    chk("   按旧布局打包 => FPGA 解出的 inc 恰为正确值的一半（低一个八度）",
        unpack_word(wrong)["inc"] == 164927 // 2,
        "  FPGA 会解出 inc=%d，正解 164927" % unpack_word(wrong)["inc"])
    # 旧布局把 inc 写在 [43:22]，而 FPGA 从 [22:19] 读 axis
    # => 两个字段【重叠】：inc 的最低位渗进 axis。所以 axis 不是简单地减半，
    #    而是被 inc 污染。下面用“翻一下 inc 的最低位”来证明这个重叠。
    chk("   按旧布局打包 => FPGA 解出的 axis 不是 3（已被污染）",
        unpack_word(wrong)["axis"] != 3,
        "  FPGA 会解出 axis=%d，正解 3" % unpack_word(wrong)["axis"])
    wrong_b = (((1000 & MASK_TICK) << 44) |
               (((164927 + 1) & OLD_MASK_INC) << OLD_OFF_INC) |
               ((3 & MASK_AXIS) << OLD_OFF_AXIS) |
               ((100 & OLD_MASK_VEL) << OFF_VEL) |
               ((KIND_ON & MASK_KIND) << OFF_KIND) |
               ((1 & OLD_MASK_TIMBRE) << OLD_OFF_TIMBRE))
    chk("   inc 最低位一变，FPGA 解出的 axis 就跟着变（证明字段重叠）",
        unpack_word(wrong_b)["axis"] != unpack_word(wrong)["axis"],
        "  inc=%d => axis=%d ; inc=%d => axis=%d"
        % (164927, unpack_word(wrong)["axis"],
           164928, unpack_word(wrong_b)["axis"]))

    print("\n[6] 读 events.hex 的校验（含坏输入）")
    import tempfile
    good = "\n".join([
        "000001c2f9000400",
        "0000001d4b841080",
        "",
        "# 注释行应被跳过",
    ]) + "\n"
    bad = "\n".join([
        "0000001d4b841080",
        "0000001d4b8410",            # 长度不足
        "0000001d4b8410ZZ",          # 非十六进制
        "0000001d4b841081",          # 保留位非 0（bit0=1）
        "0000001d4b840600",          # kind==3（bit10:9 = 11）
    ]) + "\n"
    with tempfile.TemporaryDirectory() as td:
        pg = os.path.join(td, "good.hex")
        pb = os.path.join(td, "bad.hex")
        with open(pg, "w", encoding="utf-8") as f:
            f.write(good)
        with open(pb, "w", encoding="utf-8") as f:
            f.write(bad)
        gw, gpr = load_events_hex(pg)
        bw, bpr = load_events_hex(pb)
    chk("   好文件：2 个字、0 个问题", len(gw) == 2 and len(gpr) == 0,
        "  words=%d problems=%s" % (len(gw), gpr))
    chk("   坏文件：至少报出 4 个问题（长度/进制/保留位/kind）",
        len(bpr) >= 4, "  报了 %d 个" % len(bpr))
    chk("   坏文件的问题里点名了保留位", any("保留位" in p for p in bpr))
    chk("   坏文件的问题里点名了 kind==3", any("kind==3" in p for p in bpr))
    sm = summarize(gw)
    chk("   统计：tempo 1 条 + on 1 条",
        sm["kinds"].get("tempo") == 1 and sm["kinds"].get("on") == 1,
        "  %s" % sm["kinds"])

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(selftest())
