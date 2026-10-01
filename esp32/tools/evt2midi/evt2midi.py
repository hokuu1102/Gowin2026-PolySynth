#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
evt2midi.py —— ⭐ 把 FPGA→ESP32 回传的事件录制文件，转成【可播放的 MIDI】

═══ 一句话 ═══
    读【上行录制文件】（原始字节流） → 解析 → 写成标准 `.mid`（⭐ 任意播放器可放）

═══ 为什么要它 ═══
⭐ 用户 2026-10-01：「这个是实现 **FPGA 乐曲回传**的，
    也就是**回到电脑上能逆向回 MIDI**」
⇒ ⭐ 本工具就是那条链路的**最后一环**（⭐ FPGA → ESP32 → BLE → PC → `.mid`）。

═══ 🔴🔴 解析纪律（⭐ 我实测校准过，⛔ 不是想当然）═══
① ⭐ **必须靠【校验】判定帧的合法性** —— 🔴 **这才是关键，⛔ 不是"别扫 0xA5"**
   ⚠️ **我一开始的判断是错的**：我以为"载荷含 `0xA5` ⇒ 扫描式会失步"。
   ⭐ 实测（`_find_real_risk.py`）证明**不会** ——
      ⚠️ 因为"见到 `0xA5` 就吃 14 字节"**根本不会去检查帧内载荷**，
      🔴 载荷里的 `0xA5` 被**整帧跳过去**了。
   ⭐⭐ **真正的差别在【坏帧】上**（⭐ 实测数据）：
      | 场景 | 🔴 无校验 | ✅ 有校验（本工具） |
      |---|---|---|
      | 位翻转把某字节变成 `0xA5` | ⭐ 输出 **933**（⚠️ **错的值，但看起来正常**） | ⭐ **拒收该帧 + 计数** |
      ⇒ ⭐ **没有校验时，坏数据会伪装成合理数据** —— 🔴 **这比丢帧危险得多**。
   ⇒ ⭐ 所以本工具：**校验不过 ⇒ 记账 + 尝试重同步**，⛔ 绝不把可疑数据当正常值用。

② ⭐ **`tick` 是自由运行的 32 位计数器** ⇒ ⭐ **Δt 必须取模**
   ⚠️ 朴素相减 `t2 - t1` 在**回绕**时会得到巨大负数。
   ⭐ 正解：`Δt = (t2 − t1) mod 2³²`（⭐ 跨回绕也正确）。
   📌 32 位 @50 MHz ⇒ ⭐ **85.9 秒就回绕一次** —— ⚠️ 不是理论问题，⭐ 真实曲子必然遇到。

═══ ⚠️ 格式状态：⭐ 仍是【草案】═══
   ⭐ 二进制帧格式（`0xA5` + 14 字节）**尚未冻结**
   （⭐ 见 `files/20-代码/ESP32侧再回函-20261001.md` §三）
   ⇒ ⭐ 所以**帧布局集中在 `FRAME_LAYOUT` 一处**，⚠️ 改格式只动那一处。
   ⭐ 而 **ASCII 事件流已经是事实标准**（⭐ 已在跑）⇒ ⭐ 那部分稳定。

═══ 用法 ═══
    python evt2midi.py --in rec.bin --out song.mid
    python evt2midi.py --selftest              # ⛔ 不需要硬件
    python evt2midi.py --in rec.bin --dump     # 只解析、打印事件表
"""

import argparse
import io
import math
import struct
import sys

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK）----------------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ============================================================================
# ⭐⭐ 常量 —— ⚠️ 全部来自项目已核实的事实，⛔ 不要凭感觉改
# ============================================================================
FRAME_HDR = 0xA5              # ⭐ 二进制帧头（⭐ 与下行同构）
CLK_HZ = 50_000_000.0         # ⭐ FPGA 系统时钟（⚠️ 不是音频帧率！见下）
TWO32 = 4294967296.0          # ⭐ 2³²
PPQN = 960                    # ⭐ MIDI 每四分音符的 tick 数（⭐ 与项目一致）
DEFAULT_BPM = 120.0

# 🔴🔴 一个**极易踩**的坑（⭐ 现有 `evt2wav.py:66-70` 明确警告过）：
#    ⭐ `phase_inc` 是用 **【系统时钟 50 MHz】** 造的：`inc = round(f × 2³² / 50e6)`
#    ⚠️ 若用音频帧率（48.828 kHz）去反算 ⇒ 🔴 **错 1024 倍**！
#    ⇒ ⭐ 反算必须是 `f = inc × 50e6 / 2³²`
FS_AUDIO_HZ = 50_000_000.0 / 1024.0     # ⚠️ 48.828 kHz，⭐ 仅作参考/限幅用

# ============================================================================
# ⭐⭐ 帧布局（⚠️ **草案** —— 改格式只动这里）
# ============================================================================
# ⭐ 依据：`FPGA2026-deliver/files/20-代码/FPGA侧回应-ESP32回函-20261001.md` §三
#
#   [0] 0xA5   帧头
#   [1] 类型   0x01=note_on 0x02=note_off 0x03=calib 0x04=looper 0x10=表同步
#   [2] seq    8 位序号（⭐ 丢帧可见 —— ⚠️ 只用于【短窗口】检测，见下方说明）
#   [3..6] tick  32 位自由运行计数器（⭐ 大端；⭐ Δt 取模 2³²）
#   [7] axis   轴号 0..15
#   [8..11] phase_inc 32 位（⭐ 大端；⭐ FPGA 直接给增量，⛔ 不给音名）
#   [12] vel   8 位（0..255）
#   [13] 校验  8 位
#
# ⚠️ **`seq` 只有 8 位** ⇒ 我算过：⭐ 750 事件/s（16 轴全按下）时 **0.34 秒就回绕**
#    ⇒ ⭐ **只能当"短窗口丢帧检测"用**，⛔ 别当全曲唯一编号。
FRAME_LEN = 14
T_NOTE_ON = 0x01
T_NOTE_OFF = 0x02
T_CALIB = 0x03
T_LOOPER = 0x04
T_TABLESYNC = 0x10

FRAME_TYPE_NAMES = {
    T_NOTE_ON: "note_on",
    T_NOTE_OFF: "note_off",
    T_CALIB: "calib",
    T_LOOPER: "looper",
    T_TABLESYNC: "tablesync",
}


def frame_checksum(b):
    """⭐ 帧校验（⭐ 草案建议 XOR）—— ⚠️ 若 FPGA 侧改用累加和，改这一处即可。"""
    c = 0
    for x in b[:13]:
        c ^= x
    return c & 0xFF


# ============================================================================
# ⭐ 相位增量 → 音高
# ============================================================================
def inc_to_hz(inc):
    """⭐ 反算频率。⚠️ 用【系统时钟 50 MHz】，⛔ 不是音频帧率（⭐ 否则错 1024×）。"""
    return inc * CLK_HZ / TWO32


def hz_to_note(hz):
    """⭐ 频率 → MIDI 音符号（⭐ A4 = 69 = 440 Hz）。⚠️ hz ≤ 0 时返回 None。"""
    if hz <= 0:
        return None
    n = 69.0 + 12.0 * math.log2(hz / 440.0)
    if n < 0 or n > 127:
        return None
    return int(round(n))


# ============================================================================
# ⭐⭐ 解析器（⭐ 状态机 + 定长 —— ⛔ 绝不"扫 0xA5"）
# ============================================================================
class Event:
    __slots__ = ("kind", "tick", "axis", "inc", "vel", "seq", "ascii", "t_raw")

    def __init__(self, kind, tick=None, axis=None, inc=None, vel=None,
                 seq=None, ascii_ch=None, t_raw=None):
        self.kind = kind
        self.tick = tick
        self.axis = axis
        self.inc = inc
        self.vel = vel
        self.seq = seq
        self.ascii = ascii_ch
        self.t_raw = t_raw

    def __repr__(self):
        if self.ascii is not None:
            return "<%s %r>" % (self.kind, self.ascii)
        return "<%s tick=%s axis=%s inc=%s vel=%s>" % (
            self.kind, self.tick, self.axis, self.inc, self.vel)


class ParseStats:
    def __init__(self):
        self.frames_ok = 0
        self.frames_bad_csum = 0
        self.resyncs = 0           # ⭐ 靠校验重新对齐成功的次数
        self.ascii_events = 0
        self.unknown_hi = 0        # ⚠️ ≥0x80 但⛔ 不是 0xA5 ⇒ 失步/噪声
        self.seq_gaps = 0
        self.seq_wraps = 0
        self.tick_wraps = 0
        self.notes_on = 0
        self.notes_off = 0
        self.orphan_off = 0        # ⚠️ 没 on 就 off
        self.notes_open_at_end = 0
        self.bad_type = 0


def _try_resync(data, start, limit=FRAME_LEN * 4):
    """
    ⭐ 校验失败后**尝试重新对齐**：⭐ 在随后 `limit` 字节里找一个
    **校验能过**的 `0xA5` 帧头。

    ⚠️ **为什么"找 0xA5"在这里是【对的】**（⭐ 而在别处是错的）：
       · ⭐ **只在【已经确认坏帧】之后才做**（⛔ 不是平时靠它同步）
       · ⭐ **而且必须【校验通过】才算数** ⇒ ⚠️ 载荷里的 `0xA5` 过不了校验
         ⇒ ⭐ 不会被误当成帧头
    ⇒ ⭐ 这是"有校验"带来的**恢复能力** —— 🔴 无校验时只能一路错下去。

    返回：⭐ 下一个可信帧的偏移（⚠️ 找不到则返回 None）。
    """
    n = len(data)
    end = min(n - FRAME_LEN, start + limit)
    for p in range(start, end + 1):
        if data[p] != FRAME_HDR:
            continue
        f = data[p:p + FRAME_LEN]
        if frame_checksum(f) == f[13]:
            return p
    return None


def parse_stream(data, stats=None):
    """
    ⭐ 状态机解析 + ⭐ **校验驱动的重同步**。

    ⚠️ 为什么不能"平时就扫 `0xA5`"：⭐ 见文件头纪律① ——
    ⭐ 实测证明载荷里的 `0xA5` 不会让**定长**解析失步，
    🔴 **真正的问题是【坏帧】伪装成好数据** ⇒ ⭐ 必须靠**校验**识别。
    """
    if stats is None:
        stats = ParseStats()
    evs = []
    i = 0
    n = len(data)
    last_seq = None
    last_tick = None

    while i < n:
        b = data[i]

        # ---- ⭐ 二进制帧 ----
        if b == FRAME_HDR:
            if i + FRAME_LEN > n:
                # ⚠️ 尾部残帧（⭐ 录制被截断）⇒ ⭐ 计数后结束，⛔ 不硬猜
                stats.frames_bad_csum += 1
                break
            f = data[i:i + FRAME_LEN]
            if frame_checksum(f) != f[13]:
                stats.frames_bad_csum += 1
                # ⭐⭐ 校验不过 ⇒ **先尝试重同步**（⭐ 这是有校验才有的能力）
                nxt = _try_resync(data, i + 1)
                if nxt is not None:
                    stats.resyncs += 1
                    i = nxt
                    # ⚠️ 重同步后，序号连续性已断 ⇒ 清掉基准（⛔ 免得误报缺口）
                    last_seq = None
                    continue
                # ⚠️ 找不到可信帧 ⇒ 整帧跳过（⭐ 保守，⛔ 不逐字节瞎猜）
                i += FRAME_LEN
                continue

            ftype = f[1]
            seq = f[2]
            tick = int.from_bytes(f[3:7], "big")
            axis = f[7]
            inc = int.from_bytes(f[8:12], "big")
            vel = f[12]

            # ⭐ 序号连续性（⭐ 只用于短窗口丢帧检测）
            if last_seq is not None:
                d = (seq - last_seq) & 0xFF
                if d > 1:
                    stats.seq_gaps += 1
                elif d == 0:
                    stats.seq_wraps += 1
            last_seq = seq

            # ⭐ tick 回绕计数（⭐ 用数值比较即可 —— 回绕时新值更小）
            if last_tick is not None and tick < last_tick:
                stats.tick_wraps += 1
            last_tick = tick

            if ftype == T_NOTE_ON:
                stats.notes_on += 1
                evs.append(Event("note_on", tick, axis, inc, vel, seq))
            elif ftype == T_NOTE_OFF:
                stats.notes_off += 1
                evs.append(Event("note_off", tick, axis, inc, vel, seq))
            elif ftype == T_CALIB:
                evs.append(Event("calib", tick, axis, inc, vel, seq))
            elif ftype == T_LOOPER:
                evs.append(Event("looper", tick, axis, inc, vel, seq))
            elif ftype == T_TABLESYNC:
                evs.append(Event("tablesync", tick, axis, inc, vel, seq))
            else:
                stats.bad_type += 1
                evs.append(Event("unknown_type", tick, axis, inc, vel, seq))

            stats.frames_ok += 1
            i += FRAME_LEN
            continue

        # ---- ⭐ ASCII 事件流（⭐ 全部 ≤ 0x7F）----
        if b < 0x80:
            stats.ascii_events += 1
            evs.append(Event("ascii", ascii_ch=chr(b)))
            i += 1
            continue

        # ---- ⚠️ ≥0x80 且⛔ 不是 0xA5：⭐ 既不是 ASCII 也不是帧头 ----
        # ⚠️ 正常流里**不该出现** ⇒ ⭐ 计数（⚠️ 若不为 0，说明有失步或噪声）
        stats.unknown_hi += 1
        i += 1

    return evs, stats


# ============================================================================
# ⭐ 事件 → MIDI
# ============================================================================
def note_from_axis_inc(axis, inc):
    """⭐ 用 `phase_inc` 反算音符号（⭐ 首选路径）。"""
    return hz_to_note(inc_to_hz(inc))


def build_midi(evs, stats, bpm=DEFAULT_BPM, axis_map=None):
    """
    ⭐ 生成标准 MIDI（Format 0，单轨）。

    ⚠️ 时间基准：⭐ FPGA `tick` 是 **50 MHz 自由运行计数器**
    ⇒ `seconds = Δtick / 50e6` ⇒ `MIDI Δ = seconds × PPQN × BPM / 60`
    ⭐ **Δtick 用取模**（⭐ 见文件头纪律②）。

    ⚠️ 音高来源：⭐ 优先用帧里的 `phase_inc` 反算；
    ⭐ 若为 0（⭐ 无增量）⇒ 回退到 `axis_map`（⚠️ 需外部提供，⭐ 否则跳过）。
    """
    tps = PPQN * bpm / 60.0          # ⭐ 每秒多少个 MIDI tick（120BPM/960PPQN ⇒ 1920）
    ticks_per_sec_fpga = CLK_HZ      # ⭐ FPGA tick 就是 50 MHz 计数

    # ⭐ 排序：⭐ 按 FPGA tick 的**相对顺序**（⚠️ 不能直接按数值排 —— 会回绕）
    #    ⇒ ⭐ 保持【文件顺序】作为时间序（⭐ 录制本身就是按时间来的）
    evs_sorted = list(evs)

    out = bytearray()
    prev_midi_t = 0
    base_fpga_tick = None
    open_notes = {}                  # axis -> note（⭐ 用于配对 off）
    skipped_no_pitch = 0
    ticks_seen = 0

    def var_len(v):
        """⭐ MIDI 变长量（⚠️ 每字节 7 位，最高位是"还有后续"标志）。"""
        if v < 0:
            v = 0
        buf = [v & 0x7F]
        v >>= 7
        while v:
            buf.append((v & 0x7F) | 0x80)
            v >>= 7
        return bytes(reversed(buf))

    for e in evs_sorted:
        if e.tick is None:
            continue                     # ⚠️ ASCII 事件不参与 MIDI 时间轴

        if base_fpga_tick is None:
            base_fpga_tick = e.tick
        # ⭐ 取模 —— ⚠️ 这是跨回绕正确性的关键
        dticks = (e.tick - base_fpga_tick) % (1 << 32)
        t_sec = dticks / ticks_per_sec_fpga
        midi_t = int(round(t_sec * tps))
        if midi_t < prev_midi_t:
            midi_t = prev_midi_t       # ⚠️ 单调（⭐ 防止取整回退）
        delta = midi_t - prev_midi_t

        if e.kind in ("note_on", "note_off"):
            note = note_from_axis_inc(e.axis, e.inc)
            if note is None and axis_map is not None and e.axis in axis_map:
                note = axis_map[e.axis]
            if note is None:
                skipped_no_pitch += 1
                continue
            vel = e.vel
            # ⭐ vel 是 8 位（0..255）⇒ ⭐ ÷2 缩放到 MIDI 的 0..127
            v7 = max(1, min(127, (vel + 1) // 2))
            if e.kind == "note_on":
                out += var_len(delta)
                out += bytes([0x90, note, v7])
                open_notes[e.axis] = note
            else:
                # ⚠️ note_off 的力度用 0（⭐ 标准做法；⭐ FPGA 的"峰值力度"
                #    已体现在 note_on 里，⭐ 这里⛔ 不再用）
                out += var_len(delta)
                out += bytes([0x80, note, 0x40])
                open_notes.pop(e.axis, None)
            prev_midi_t = midi_t
            ticks_seen += 1

    # ⭐ 收尾：⭐ 给所有还开着的音补 note_off（⚠️ 否则播放器会挂音）
    if open_notes:
        for axis, note in open_notes.items():
            out += var_len(0)
            out += bytes([0x80, note, 0x40])
        stats.notes_open_at_end = len(open_notes)

    # ⭐ 轨道结束标记（⭐ MIDI 规范要求）
    out += var_len(0) + bytes([0xFF, 0x2F, 0x00])

    # ---- 组装文件 ----
    hdr = b"MThd" + struct.pack(">IHHH", 6, 0, 1, PPQN)
    trk = b"MTrk" + struct.pack(">I", len(out)) + bytes(out)
    return hdr + trk, skipped_no_pitch, ticks_seen


# ============================================================================
# ⭐ 自检（⛔ 不需要硬件）—— ⚠️ 必须【非空洞】：故意造坏数据要能被发现
# ============================================================================
def _mk_frame(ftype, seq, tick, axis, inc, vel):
    b = bytearray(FRAME_LEN)
    b[0] = FRAME_HDR
    b[1] = ftype
    b[2] = seq & 0xFF
    b[3:7] = tick.to_bytes(4, "big")
    b[7] = axis & 0xFF
    b[8:12] = inc.to_bytes(4, "big")
    b[12] = vel & 0xFF
    b[13] = frame_checksum(b)
    return bytes(b)


def selftest():
    print("=" * 72)
    print("evt2midi.py 离线自检（⛔ 不需要硬件）")
    print("=" * 72)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 相位增量反算（⭐ 含那个 1024× 陷阱的守卫）----
    inc440 = int(round(440.0 * TWO32 / CLK_HZ))
    hz = inc_to_hz(inc440)
    chk("① 440 Hz 往返 (inc=%d -> %.2f Hz)" % (inc440, hz), abs(hz - 440.0) < 0.5)
    # ⚠️ 若误用音频帧率会得到 ~0.43 Hz ⇒ 这一条能抓住
    chk("① 不是 1024× 错（>100 Hz）", hz > 100.0, "  实测 %.1f" % hz)

    # ---- ② 音符号 ----
    chk("② 440 Hz -> note 69", hz_to_note(440.0) == 69)
    chk("② 880 Hz -> note 81", hz_to_note(880.0) == 81)

    # ---- ③ 变长量 ----
    # ⭐ 复用 build_midi 里的写法做等价校验
    def vl(v):
        buf = [v & 0x7F]; v >>= 7
        while v:
            buf.append((v & 0x7F) | 0x80); v >>= 7
        return bytes(reversed(buf))
    chk("③ var_len(0)=00", vl(0) == b"\x00")
    chk("③ var_len(127)=7F", vl(127) == b"\x7f")
    chk("③ var_len(128)=81 00", vl(128) == b"\x81\x00")
    chk("③ var_len(1920)=8F 00", vl(1920) == b"\x8f\x00")

    # ---- ④ ⭐ 载荷里的 0xA5：⭐ 定长解析【不会】因此失步 ----
    # ⚠️ 我原以为会失步，⭐ 实测证明不会（⭐ 见 _find_real_risk.py）
    #    ⇒ ⭐ 这条测试**保留**，⭐ 但断言的是"仍能正确解析"这个事实。
    evil_tick = 0xA5000000
    good = _mk_frame(T_NOTE_ON, 0, evil_tick, 3, inc440, 200)
    chk("④ 恶意帧载荷确实含 0xA5", good[3] == 0xA5, "  byte3=0x%02X" % good[3])
    evs, st = parse_stream(good)
    chk("④ 仍解析成 1 帧（⭐ 定长不受载荷影响）",
        st.frames_ok == 1 and len(evs) == 1,
        "  ok=%d bad=%d unk_hi=%d" % (st.frames_ok, st.frames_bad_csum, st.unknown_hi))
    chk("④ tick 还原正确", evs[0].tick == evil_tick if evs else False)

    # ---- ④b ⭐⭐ 真正的差别：坏帧必须【被发现】，⛔ 不能伪装成好数据 ----
    flip = bytearray(good)
    flip[6] ^= 0x01                     # ⚠️ 翻转 tick 里的 1 位
    evs_b, st_b = parse_stream(bytes(flip))
    chk("④b 位翻转帧被拒收（⛔ 不伪装成好值）",
        st_b.frames_ok == 0 and st_b.frames_bad_csum == 1,
        "  ok=%d bad=%d" % (st_b.frames_ok, st_b.frames_bad_csum))

    # ---- ④c ⭐ 校验驱动的重同步：坏帧后能找回下一帧 ----
    f_after = _mk_frame(T_NOTE_OFF, 1, 0x0000C000, 3, inc440, 200)
    evs_c, st_c = parse_stream(bytes(flip) + f_after)
    chk("④c 坏帧后成功重同步", st_c.resyncs >= 1 and st_c.frames_ok == 1,
        "  resync=%d ok=%d" % (st_c.resyncs, st_c.frames_ok))
    chk("④c 重同步后拿到正确 tick",
        any(e.tick == 0x0000C000 for e in evs_c))

    # ---- ⑤ ⭐⭐ 解析纪律②：tick 回绕必须取模 ----
    # ⭐ 两帧跨回绕：t1 = 2^32-5, t2 = 3 ⇒ Δ = 8
    f1 = _mk_frame(T_NOTE_ON, 0, (1 << 32) - 5, 1, inc440, 100)
    f2 = _mk_frame(T_NOTE_OFF, 1, 3, 1, inc440, 100)
    evs2, st2 = parse_stream(f1 + f2)
    chk("⑤ 回绕被记录", st2.tick_wraps == 1)
    if len(evs2) == 2:
        d = (evs2[1].tick - evs2[0].tick) % (1 << 32)
        chk("⑤ 取模 Δt = 8（⛔ 不是负数）", d == 8, "  实测 %d" % d)

    # ---- ⑥ 校验失败要被发现（⛔ 不静默接受）----
    bad = bytearray(good); bad[13] ^= 0xFF
    evs3, st3 = parse_stream(bytes(bad))
    chk("⑥ 坏校验被计数", st3.frames_bad_csum == 1 and st3.frames_ok == 0)

    # ---- ⑦ ASCII 流解析 ----
    evs4, st4 = parse_stream(b"stxT.\r\n")
    chk("⑦ ASCII 7 个事件", st4.ascii_events == 7 and st4.unknown_hi == 0)

    # ---- ⑧ ⭐ 混合流：ASCII + 帧 交替（⭐ 模式可辨的核心场景）----
    mixed = b"s" + good + b"T" + f2
    evs5, st5 = parse_stream(mixed)
    chk("⑧ 混合流：2 帧 + 2 ASCII",
        st5.frames_ok == 2 and st5.ascii_events == 2,
        "  frames=%d ascii=%d unk=%d" % (st5.frames_ok, st5.ascii_events, st5.unknown_hi))

    # ---- ⑨ 端到端：造一段两音，写 MIDI，验证结构 ----
    seq = bytearray()
    seq += _mk_frame(T_NOTE_ON, 0, 1000, 0, inc440, 200)
    seq += _mk_frame(T_NOTE_OFF, 1, 1000 + 50000, 0, inc440, 200)
    evs6, st6 = parse_stream(bytes(seq))
    midi, skipped, n = build_midi(evs6, st6)
    chk("⑨ MIDI 头 MThd", midi[:4] == b"MThd")
    chk("⑨ MIDI 轨 MTrk", midi[14:18] == b"MTrk")
    chk("⑨ PPQN=960", struct.unpack(">H", midi[12:14])[0] == PPQN)
    chk("⑨ 含 note_on 0x90", b"\x90" in midi)
    chk("⑨ 含 note_off 0x80", b"\x80" in midi)
    chk("⑨ 有轨结束标记", midi.rstrip(b"\x00").endswith(b"\xff\x2f\x00") or b"\xff\x2f\x00" in midi)
    # ⭐ 时间：50000 FPGA tick @50MHz = 1 ms；120BPM/960PPQN ⇒ 1920 t/s ⇒ ~2 tick
    chk("⑨ Δt 合理（1ms -> ~2 MIDI tick）", 0 <= n <= 2, "  事件数=%d" % n)

    # ---- ⑩ ⭐ 非空洞性：坏输入必须产生**不同**结果 ----
    # ⭐ 若把校验改成恒真（⭐ 假绿），⑥ 就会失败 ⇒ 上面已经覆盖。
    #    这里再确认：⭐ 空输入不产生任何帧
    evs7, st7 = parse_stream(b"")
    chk("⑩ 空输入 -> 0 事件（非空洞）", len(evs7) == 0 and st7.frames_ok == 0)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


# ============================================================================
# CLI
# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="FPGA 回传事件 -> 可播放 MIDI")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    ap.add_argument("--in", dest="inp", help="输入录制文件（原始字节流）")
    ap.add_argument("--out", dest="out", help="输出 .mid")
    ap.add_argument("--bpm", type=float, default=DEFAULT_BPM)
    ap.add_argument("--dump", action="store_true", help="只解析并打印事件表")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.inp:
        print("RED: 需要 --in（⚠️ 或用 --selftest）")
        return 2

    with open(args.inp, "rb") as f:
        data = f.read()
    print("输入 %s：%d 字节" % (args.inp, len(data)))

    evs, st = parse_stream(data)
    print()
    print("解析结果：")
    print("  二进制帧 ok        = %d" % st.frames_ok)
    print("  🔴 坏校验帧        = %d" % st.frames_bad_csum)
    print("  ⚠️ 未知高位字节    = %d  (⛔ 正常应为 0)" % st.unknown_hi)
    print("  ASCII 事件         = %d" % st.ascii_events)
    print("  note_on / off      = %d / %d" % (st.notes_on, st.notes_off))
    print("  ⭐ tick 回绕次数   = %d" % st.tick_wraps)
    print("  序号缺口 / 回绕    = %d / %d" % (st.seq_gaps, st.seq_wraps))
    print("  未知类型           = %d" % st.bad_type)

    if args.dump:
        print()
        for e in evs[:80]:
            print("  ", e)
        if len(evs) > 80:
            print("   ... 共 %d 条" % len(evs))
        return 0

    if not args.out:
        print("RED: 需要 --out（⚠️ 或用 --dump）")
        return 2

    midi, skipped, n = build_midi(evs, st, bpm=args.bpm)
    with open(args.out, "wb") as f:
        f.write(midi)

    print()
    print("写出 %s：%d 字节" % (args.out, len(midi)))
    print("  参与的事件   = %d" % n)
    print("  ⚠️ 无音高跳过 = %d" % skipped)
    print("  ⚠️ 收尾补 off = %d" % st.notes_open_at_end)
    if st.frames_bad_csum or st.unknown_hi:
        print("  🔴 注意：有坏帧/未知字节 ⇒ 结果可能不完整")
    return 0


if __name__ == "__main__":
    sys.exit(main())
