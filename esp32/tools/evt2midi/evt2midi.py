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
CLK_HZ = 50_000_000.0         # ⭐ FPGA 系统时钟（⚠️ 不是音频帧率！见下）
TWO32 = 4294967296.0          # ⭐ 2³²
PPQN = 960                    # ⭐ MIDI 每四分音符的 tick 数（⭐ 与项目一致）
DEFAULT_BPM = 120.0

# Upstream events carry the full 32-bit phase increment restored by RTL.
# The oscillator advances once per audio sample (50 MHz / 1024).
# CLK_HZ remains the system tick rate for legacy raw-clock timestamps.
FS_AUDIO_HZ = 50_000_000.0 / 1024.0

# ============================================================================
# ⭐⭐ 帧格式：**全部从 `frame_format.py` 导入**（⭐ 任务 4）
# ============================================================================
# 🔴 为什么抽出去：⚠️ **上行格式尚未冻结** ⇒ 一定会改
#    ⇒ ⭐ 把"会变的帧结构"集中到【一个文件】⇒ ⭐ 改版只动那一处
#    ⇒ ⛔ 本文件不再重复定义任何帧常量（⭐ 否则两处会漂）
#
# ⚠️ 本文件只保留【音频换算】（`inc → Hz → 音符号`）——
#    ⭐ 那属于**物理**，⭐ 与**协议**的变化原因不同 ⇒ ⚠️ 混在一起会互相干扰。
from frame_format import (          # noqa: E402
    FRAME_HDR, FRAME_LEN_DEFAULT, FRAME_LEN_BY_TYPE, FRAME_TYPE_NAMES,
    KNOWN_TYPES, MAX_FRAME_LEN,
    OFF_AXIS, OFF_INC, OFF_SEQ, OFF_TICK, OFF_VEL, LEN_INC, LEN_TICK,
    T_CALIB, T_LOOPER, T_NOTE_OFF, T_NOTE_ON, T_TABLESYNC,
    T_TRANSPORT_START, PPQN_FPGA, PPQN_TYPES,
    TABLESYNC_DATA_OFF, TABLESYNC_ITEM_BYTES, TABLESYNC_ITEMS,
    TABLESYNC_TABLE_FB, TABLESYNC_TABLE_KB, TABLESYNC_TABLE_NAMES,
    build_frame as _mk_frame,        # ⭐ 造帧（⭐ 测试用）
    frame_checksum, frame_len_for, frame_len_known, is_ascii_byte,
    is_known_type, parse_frame,
)

# ⚠️ 兼容旧名：⭐ 本文件与 `_e2e_check.py` 里用的是 `FRAME_LEN`
FRAME_LEN = FRAME_LEN_DEFAULT

# ⭐⭐ 2026-10-01（加固）：端到端的**读回能力**。
# 🔴 为什么必须是【另一个文件里的独立实现】：
#    ⚠️ 若用本文件的写侧代码去读自己写的东西 ⇒
#    🔴 "自己写的 bug"会被"自己写的检查"放过 ⇒ ⭐ 等于**没验证**（`C83` 探针假绿）。
# ⚠️ 用 try 包住：⭐ 即使读侧缺失，**转换功能本身仍要能用**（⭐ 只是自检会判红）。
try:
    from midi_verify import notes_of as _notes_of
    from midi_verify import read_midi as _read_midi
    HAVE_MIDI_READER = True
except Exception as _reader_err:             # noqa: BLE001
    HAVE_MIDI_READER = False
    _READER_ERR = repr(_reader_err)

    def _read_midi(_m):
        raise RuntimeError("midi_verify 读侧不可用：%s" % _READER_ERR)

    def _notes_of(_r):
        return []


# ============================================================================
# ⭐ 相位增量 → 音高
# ============================================================================
def inc_to_hz(inc):
    """⭐ 反算频率。⚠️ 用【系统时钟 50 MHz】，⛔ 不是音频帧率（⭐ 否则错 1024×）。"""
    return inc * FS_AUDIO_HZ / TWO32


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
    __slots__ = ("kind", "tick", "axis", "inc", "vel", "seq", "ascii", "t_raw", "timbre", "drum_type")

    def __init__(self, kind, tick=None, axis=None, inc=None, vel=None,
                 seq=None, ascii_ch=None, t_raw=None, timbre=None, drum_type=None):
        self.kind = kind
        self.tick = tick
        self.axis = axis
        self.inc = inc
        self.vel = vel
        self.seq = seq
        self.ascii = ascii_ch
        self.t_raw = t_raw
        self.timbre = timbre
        self.drum_type = drum_type

    def __repr__(self):
        if self.ascii is not None:
            return "<%s %r>" % (self.kind, self.ascii)
        return "<%s tick=%s axis=%s inc=%s vel=%s>" % (
            self.kind, self.tick, self.axis, self.inc, self.vel)


class ParseStats:
    """
    ⭐⭐ **坏帧记账**（⭐ 加固的核心）。

    🔴 为什么"记账"和"解析"一样重要：
       ⚠️ 一位翻转会把字段变成**看起来正常**的值（⭐ 实测 933）
       ⇒ ⭐ **"没报错"不等于"没坏"** ⇒ 🔴 必须有一个**能被检查的计数**，
          ⭐ 否则坏帧就是**静默**的。

    ⭐ 分组：
      · ⭐ 正常计数   —— `frames_ok` / `ascii_events` / `table_frames`
      · 🔴 **拒收计数** —— `frames_bad_csum` / `bad_type` / `truncated`（⭐ 见 `rejected`）
      · ⭐ 恢复计数   —— `resyncs` / `resync_fail`
      · ⚠️ 可疑计数   —— `unknown_hi` / `seq_gaps`
      （2026-10-17：原 `axis_out_of_range` 已删 —— 它查的"鼓标记"字段在上行帧里不存在，
        见 `parse_stream` 里那段说明 ✅）
      · ⭐ MIDI 侧    —— `inc_zero*` / `orphan_off` / `notes_open_at_end`
    """

    REJECT_LOG_LIMIT = 16

    def __init__(self):
        # ---- ⭐ 正常 ----
        self.frames_ok = 0
        self.ascii_events = 0
        self.table_frames = 0          # ⭐ 表同步帧数
        # v1.1 起播锚点（0x05）。单独计数，因为它不是音符事件 ——
        # 混进 frames_ok 的话，"收到几帧"这个数会看不出锚点到没到。
        self.anchor_frames = 0
        # ppqn = 0 的次数（异常/旧固件）。我们回退到了可用值，
        # 但必须如实计数：回退是兜底，不能把异常掩盖成正常。
        self.anchor_ppqn_zero = 0

        # ---- tick 单位（2026-10-13）----
        # 🔴 这个字段存在的原因：`tick` 的单位【没有权威定义】（两侧文档冲突），
        #    而选错会让整曲时间全错、且是【静默】的（音高还对，只是挤在一起）。
        #    => 必须把"我按哪种口径算的、为什么"【显式报出来】，⛔ 不能默认。
        self.tick_unit = None            # auto 判断出来的结果
        self.tick_unit_reason = ""
        self.tick_unit_used = None       # 实际用于换算的口径
        # tick 非单调的次数（2026-10-13）。
        # 🔴 为什么必须单独计：tick 是 32 位【自由运行】计数器，
        #    正常情况下只会"增长 + 回绕"。若出现"小幅回退"，
        #    那多半是【多轴/多段录制混在一起】=> 时间轴会错乱。
        #    ⚠️ 而这种错乱会表现为"MIDI 写不出来"（delta 超上限），
        #       现象看起来像"工具坏了"，其实是【输入不是单条时间轴】。
        #    => 把它计出来并在报告里说清，免得下次又当成工具 bug 查。
        self.non_monotonic_tick = 0

        # ---- 🔴 拒收（⭐ 加固：⛔ 一律不许静默）----
        self.frames_bad_csum = 0       # ⭐ 校验错（⭐ 最可能的一类）
        self.bad_type = 0              # ⭐ 未知类型（🔴 现在【不计入】frames_ok）
        self.truncated = 0             # ⭐ 半帧 / 长度不足（⭐ 录制被截断）
        self.rejects = []              # ⭐ [(偏移, 原因)]，⛔ 只留前 N 条免得爆内存

        # ---- ⭐ 恢复 ----
        self.resyncs = 0               # ⭐ 靠校验重新对齐成功
        self.resync_fail = 0           # ⚠️ 找不到可信帧 ⇒ 只能保守跳过

        # ---- ⚠️ 可疑 ----
        self.unknown_hi = 0            # ⚠️ ≥0x80 且⛔ 不是 0xA5 ⇒ 失步/噪声
        # 2026-10-17 删除 `axis_out_of_range`：它原来查"鼓标记 > 3"，而那个字段
        # 在上行帧里不存在（`[3:0]` 是轴号，见 parse_stream 那段的说明）✅
        self.seq_gaps = 0
        self.seq_wraps = 0
        self.tick_wraps = 0
        self.big_tick_steps = 0        # ⚠️ 单步 Δ > 2³¹（⭐ 超过半圈 ⇒ 可疑）

        # ---- ⭐ MIDI 侧 ----
        self.notes_on = 0
        self.notes_off = 0
        self.orphan_off = 0            # ⚠️ 没 on 就 off
        self.notes_open_at_end = 0
        self.inc_zero = 0              # ⭐ 收到 inc == 0 的音符事件数
        self.inc_zero_skipped = 0      # ⭐ 其中【跳过】的（⛔ 不猜音高）
        self.inc_zero_from_table = 0   # ⭐ 其中用表兜底的（⚠️ 需显式开启）
        self.skipped_no_pitch = 0      # ⭐ 总共因无音高被跳过的事件

    @property
    def rejected(self):
        """🔴 被拒收的帧总数（⭐ 判据用：⛔ 这个数不为 0 就说明录制不干净）。"""
        return self.frames_bad_csum + self.bad_type + self.truncated

    def note_reject(self, off, reason):
        """⭐ 记一条拒收原因（⚠️ 有上限，⛔ 免得坏流把内存吃光）。"""
        if len(self.rejects) < self.REJECT_LOG_LIMIT:
            self.rejects.append((off, reason))

    def summary(self):
        return ("ok=%d bad_csum=%d bad_type=%d trunc=%d resync=%d/%d "
                "unk_hi=%d" % (self.frames_ok, self.frames_bad_csum,
                               self.bad_type, self.truncated, self.resyncs,
                               self.resync_fail, self.unknown_hi))


def _valid_frame_at_any(data, p):
    """
    ⭐⭐ 在偏移 `p` 处**是不是一个可信帧**？（⭐ 帧头 + 已知类型 + 校验通过）

    ⚠️ 这是"重同步"的**唯一判据** —— 🔴 光有 `0xA5` **不算**：
       ⭐ 载荷里出现 `0xA5` 是**正常**的（⭐ 实测证明），
       ⇒ ⚠️ 只认帧头就会**同步到载荷中间**。
    """
    n = len(data)
    if p < 0 or p + 2 > n or data[p] != FRAME_HDR:
        return False
    flen = frame_len_known(data[p + 1])       # ⭐ 未知类型 ⇒ None ⇒ 不可信
    if flen is None or p + flen > n:
        return False
    f = data[p:p + flen]
    return frame_checksum(f) == f[flen - 1]


def _try_resync(data, start, limit=None):
    """
    ⭐ 校验失败后**尝试重新对齐**：⭐ 在随后 `limit` 字节里找一个
    **校验能过 + 类型已知**的 `0xA5` 帧头。

    ⚠️ **为什么"找 0xA5"在这里是【对的】**（⭐ 而在别处是错的）：
       · ⭐ **只在【已经确认坏帧】之后才做**（⛔ 不是平时靠它同步）
       · ⭐ **而且必须【校验通过】才算数** ⇒ ⚠️ 载荷里的 `0xA5` 过不了校验
         ⇒ ⭐ 不会被误当成帧头
    ⇒ ⭐ 这是"有校验"带来的**恢复能力** —— 🔴 无校验时只能一路错下去。

    ⭐⭐ 2026-10-01（加固）：两处修好了 ——
      ① 🔴 旧版**只认 14 B 帧**（写死 `FRAME_LEN` 与 `f[13]`）
         ⇒ ⚠️ 一个 68 B 表帧被打坏之后，**重同步永远找不到它**，
         而且更糟：⭐ 窗口 (`14×4=56 B`) **跨不过一个 68 B 表帧**
         ⇒ 🔴 坏表帧后面那一帧会被**整段跳过**（⭐ 静默丢数据）。
      ② 🔴 旧版**不检查类型字节** ⇒ ⚠️ 1/256 的巧合就能把噪声当帧头。
      ⇒ ⭐ 现在：⭐ 逐候选点试**每一种已知帧长**，且**类型必须在白名单里**，
         窗口放宽到**能跨过一整个最长帧**。

    返回：⭐ 下一个可信帧的偏移（⚠️ 找不到则返回 None）。
    """
    if limit is None:
        # ⚠️ 窗口必须 > 最长帧 —— 否则"被打坏的表帧 + 后面那一帧"找不回来
        limit = MAX_FRAME_LEN + FRAME_LEN_DEFAULT
    n = len(data)
    end = min(n, start + limit)
    for p in range(start, end):
        if data[p] != FRAME_HDR:
            continue
        if _valid_frame_at_any(data, p):
            return p
    return None


def parse_stream(data, stats=None, tables=None, anchors=None):
    """
    ⭐ 状态机解析 + ⭐ **校验驱动的重同步** + ⭐ **按类型定帧长**。

    ⚠️ 为什么不能"平时就扫 `0xA5`"：⭐ 见文件头纪律① ——
    ⭐ 实测证明载荷里的 `0xA5` 不会让**定长**解析失步，
    🔴 **真正的问题是【坏帧】伪装成好数据** ⇒ ⭐ 必须靠**校验**识别。

    ⭐ `tables`：⭐ 若给了 dict，⭐ 表同步帧（`0x10`）会**存进去**
    （⭐ 键 = 表号 0=kb / 1=fb，⭐ 值 = 16 个 32 位增量）。

    ⭐ `anchors`（v1.1 新增）：⭐ 若给了 list，⭐ 起播锚点帧（`0x05`）
    会 append 一个 dict `{seq, tick, ppqn, ppqn_raw}`。
    用途：`tick` 是自由运行计数器 ⇒ 有锚点才能把 tick 换算成"第几拍/第几小节"。
    """
    if stats is None:
        stats = ParseStats()
    if tables is None:
        tables = {}
    if anchors is None:
        anchors = []
    evs = []
    i = 0
    n = len(data)
    last_seq = None
    last_tick = None

    while i < n:
        b = data[i]

        # ---- ⭐ 二进制帧 ----
        if b == FRAME_HDR:
            # ⚠️ 先看**类型字节**才能定长度 ⇒ 至少要 2 字节
            if i + 2 > n:
                # ⚠️ 尾部只剩一个帧头 ⇒ ⭐ **半帧截断**（⛔ 不硬猜）
                stats.truncated += 1
                stats.note_reject(i, "trunc:尾部只剩帧头（残 %d B）" % (n - i))
                break
            ftype_peek = data[i + 1]

            # ---- 🔴 未知类型 ⇒ **拒收**（⭐ 加固点 ①）----
            # 🔴 旧版行为：`frame_len_for()` 回退 14 ⇒ ⚠️ 未知类型被**当 14 B 音符帧收下**，
            #    ⭐ 而且 `frames_ok` 还会 +1 ⇒ 🔴 **"收下了不理解的东西"**。
            # ⭐ 现在：⛔ 不进 `frames_ok`、⛔ 不产出事件，⭐ 只计数 + 记原因。
            flen = frame_len_known(ftype_peek)
            if flen is None:
                stats.bad_type += 1
                stats.note_reject(i, "type:未知类型 0x%02X" % ftype_peek)
                nxt = _try_resync(data, i + 1)
                if nxt is not None:
                    stats.resyncs += 1
                    last_seq = None
                    i = nxt
                else:
                    stats.resync_fail += 1
                    # ⚠️ 保守推进 1 字节 —— ⛔ 不按"猜出来的 14"跳
                    #    （🔴 那会**吞掉后面真实的数据**）
                    i += 1
                continue

            # ---- ⚠️ 长度不足 / 半帧截断 ⇒ 拒收（⭐ 加固点 ②）----
            if i + flen > n:
                stats.truncated += 1
                stats.note_reject(i, "trunc:半帧 类型0x%02X 需 %dB 只剩 %dB"
                                  % (ftype_peek, flen, n - i))
                break

            f = data[i:i + flen]

            # ---- 🔴 校验错 ⇒ 拒收 + 记账 + 尝试重同步（⭐ 加固点 ③）----
            if frame_checksum(f) != f[flen - 1]:
                stats.frames_bad_csum += 1
                stats.note_reject(i, "csum:类型0x%02X 帧长%d" % (ftype_peek, flen))
                # ⭐⭐ 重同步**优先试【帧对齐】的下一个位置** ——
                #    ⚠️ 因为"坏了一帧"最可能的情形就是**这一帧坏了、后面还是好的**
                #    🔴 若一上来就全窗口扫描，可能**同步到载荷中间**（⭐ 更糟）
                aligned = i + flen
                nxt = (aligned if _valid_frame_at_any(data, aligned)
                       else _try_resync(data, i + 1))
                if nxt is not None:
                    stats.resyncs += 1
                    i = nxt
                    # ⚠️ 重同步后，序号连续性已断 ⇒ 清掉基准（⛔ 免得误报缺口）
                    last_seq = None
                    continue
                stats.resync_fail += 1
                # ⚠️ 找不到可信帧 ⇒ 整帧跳过（⭐ 保守，⛔ 不逐字节瞎猜）
                i += flen
                continue

            # ⭐⭐ 2026-10-01（任务 4）：字段解码**统一走 `frame_format.parse_frame`**
            #    ⚠️ 原来这里【内联】按固定偏移取字节 ⇒ 🔴 与 `frame_format` **两处会漂**：
            #       ⭐ 格式一改（如加字段/改偏移），⚠️ 改了 `frame_format` 却漏了这里
            #       ⇒ 🔴 **静默读出垃圾**（⭐ 最难查的一类）。
            #    ⭐ 现在只有【一个解码器】⇒ ⭐ 格式冻结时改一处即可。
            fd = parse_frame(f)
            ftype = fd["type"]

            # ---- 表同步帧：布局与音符帧不同，先处理并 continue ----
            if ftype == T_TABLESYNC:
                tables[fd["table"]] = fd["items"]
                stats.table_frames += 1
                evs.append(Event("tablesync", seq=fd["table"], t_raw=fd["items"]))
                stats.frames_ok += 1
                i += flen
                continue

            # ---- v1.1 起播锚点（0x05）：必须【在取 inc 之前】分流 ----
            # 这个分支不能省：0x05 帧的 [8..11] 是 ppqn，
            # parse_frame 返回的键是 `ppqn` 而不是 `inc`
            # => 若走到下面那行 `fd["inc"]` 会直接 KeyError 崩溃。
            # 它的用途是给后续事件一个"第几拍"的基准（tick 是自由运行计数器，
            # 没有锚点就只能算相对间隔，算不出小节位置）。
            if ftype == T_TRANSPORT_START:
                anchors.append({
                    "seq": fd["seq"],
                    "tick": fd["tick"],
                    "ppqn": fd["ppqn"],
                    "ppqn_raw": fd["ppqn_raw"],
                })
                if fd["ppqn_raw"] == 0:
                    # 如实计数：ppqn=0 是异常/旧固件，我们回退了值但不能假装没发生
                    stats.anchor_ppqn_zero += 1
                stats.anchor_frames += 1
                # 用 t_raw 带上 tick 快照（Event 没有 note 字段）——
                # 锚点不是音频事件，所以 kind 单独用 "anchor"，
                # 后面 build_midi 会跳过它，不会污染音符序列。
                evs.append(Event("anchor", seq=fd["seq"], t_raw=fd["tick"],
                                 inc=fd["ppqn"]))
                # 注意：这里【不】++ frames_ok。
                # frames_ok 的语义是"成功解析出的【音频事件】帧数"，
                # 而锚点是元数据（它不带音高、不进 MIDI）。
                # 混进去会让"收到几帧"这个数虚高，且和 table_frames 的
                # 处理方式不一致（表帧也是单独计数的）。
                i += flen
                continue

            seq = fd["seq"]
            tick = fd["tick"]
            axis = fd["axis"]
            inc = fd["inc"]
            vel = fd["vel"]

            # 🔴🔴 2026-10-17：这里原来有一段 `axis_out_of_range` 计数 —— **整段删掉**。
            #   历史：2026-10-16 按《上行帧 byte7 口径补正》把 `[7][3:0]` 当"鼓标记"
            #   （合法 0..3），于是查"鼓标记 > 3"；后经用户实测 + RTL 地面真相
            #   （`rtl/w3c/evt_upstream.v:264` `b_axis = {2'b0, tm, ax}`）确认
            #   **`[3:0]` 是轴号（0..15）**、上行帧里没有鼓标记位。
            #   ⇒ 若继续查 "> 3"，**合法轴号 4..15 全被计成越界**（用户实测会虚高）；
            #     若改回查 "> 15"，掩码之后**结构上不可能**成立 ⇒ 恒 0 的假探针（C83）。
            #   ⇒ 两条都是假的，所以**整段删除**，⛔ 不留"看起来在查什么"的死判据。
            #   真实的不变量由 frame_format 的掩码保证（0xFF ⇒ axis=15，见其自检）。

            # 序号连续性（只用于短窗口丢帧检测）。
            #
            # 口径（FPGA 侧 2026-10-12 建议，本实现已满足）：
            #   `last_seq` 【只】由音符事件 0x01/0x02 更新；
            #   0x03 calib / 0x04 looper / 0x05 transport_start / 0x10 tablesync
            #   【都不】参与。
            # 依据（FPGA 侧原话）：0x05 是"谱面锚点"、0x01/0x02 是"音符事件"
            #   => 它们是【两个不同的序列】。
            #   若锚点也更新 last_seq，锚点与音符帧的序号会串起来
            #   => 制造假 gap（症状：PC 侧报"丢帧"，而其实一帧没丢）。
            #
            # 实现保障：本分支只对音符类帧可达 ——
            #   0x10 表帧和 0x05 锚点都在上面就 `continue` 掉了。
            #   => "非音符类型全部排除"是【结构上成立】的，
            #      而不是靠这里多写几个 if（那种写法将来加类型时会漏）。
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
                evs.append(Event("note_on", tick, axis, inc, vel, seq, timbre=fd.get("timbre"), drum_type=fd.get("drum_type")))
            elif ftype == T_NOTE_OFF:
                stats.notes_off += 1
                evs.append(Event("note_off", tick, axis, inc, vel, seq, timbre=fd.get("timbre"), drum_type=fd.get("drum_type")))
            elif ftype == T_CALIB:
                evs.append(Event("calib", tick, axis, inc, vel, seq, timbre=fd.get("timbre"), drum_type=fd.get("drum_type")))
            elif ftype == T_LOOPER:
                evs.append(Event("looper", tick, axis, inc, vel, seq, timbre=fd.get("timbre"), drum_type=fd.get("drum_type")))
            else:
                # 🔴 理论不可达（⭐ 白名单已经挡过）—— ⚠️ 保留为**兜底**，⛔ 不许静默
                stats.bad_type += 1
                stats.note_reject(i, "type:白名单内未处理的类型 0x%02X" % ftype)
                i += flen
                continue

            stats.frames_ok += 1
            i += flen                       # ⚠️ 用**本帧的实际长度**（⛔ 不是常量）
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


TICK_UNIT_AUTO = "auto"
TICK_UNIT_MIDI = "midi"
TICK_UNIT_CLOCK = "clock"


def _guess_tick_unit(evs):
    """
    按数据判断 `tick` 是【音乐 tick】还是【50 MHz 计数】。

    ⭐ 判据（机械可判，⛔ 不靠"我觉得"）：
      音乐 tick 的典型间隔是【PPQN 的整数分之一】（960/ppqn ⇒ 480/240/120…），
      而 50 MHz 计数的间隔是【任意大整数】（毫秒级手弹 => 百万量级）。

    具体做法：取音符事件的相邻 tick 差（去掉 0），看中位数落在哪个量级。

      中位数 < 100000  => 音乐 tick（960/拍时，一个 16 分音符 = 240）
      中位数 >= 100000 => 50 MHz 计数（1 个 16 分音符 = 12,000,000）

    ⚠️ 两者相差【4 个数量级】⇒ 这个判据很结实，⛔ 不会骑墙。
    ⚠️ 边界情况（只有 0 或 1 个事件）=> 返回 clock（保持旧行为），
       并在 reason 里说明"数据不足以判断"。
    """
    ticks = [e.tick for e in evs
             if getattr(e, "tick", None) is not None
             and e.kind in ("note_on", "note_off")]
    if len(ticks) < 2:
        return TICK_UNIT_CLOCK, "事件少于 2 个，不足以判断 => 沿用旧口径(clock)"
    diffs = []
    for i in range(1, len(ticks)):
        d = ticks[i] - ticks[i - 1]
        if d > 0:
            diffs.append(d)
    if not diffs:
        return TICK_UNIT_CLOCK, "所有事件 tick 相同 => 无法判断 => 沿用旧口径(clock)"
    diffs.sort()
    med = diffs[len(diffs) // 2]
    if med < 100000:
        return TICK_UNIT_MIDI, ("相邻 tick 中位数 = %d（< 100000）"
                                "=> 判为音乐 tick(PPQN=%d)" % (med, PPQN))
    return TICK_UNIT_CLOCK, ("相邻 tick 中位数 = %d（>= 100000）"
                             "=> 判为 50 MHz 自由运行计数" % med)


def build_midi(evs, stats, bpm=DEFAULT_BPM, axis_map=None, tables=None,
               table_fallback=False, tick_unit=TICK_UNIT_AUTO):
    """
    生成标准 MIDI（Format 1，速度轨 + 按音色/鼓分轨）。

    ---- tick 的单位（2026-10-13 新增，因为发现两侧定义冲突）----
    🔴 **实测发现**：`tick` 的单位在两条通路上【不一样】，而旧代码只会一种：
       · 9 B 回传帧：`tick[63:44]` 是【音乐 tick】（PPQN 960）—— FPGA 侧文档 §一-③
       · 14 B v1.1 帧：文档写"32 位自由运行"，**没说单位**
       · `rtl/top.v:1988`：`.tick_i (bg_tick)` => 来自 `beat_gen` => 【音乐 tick】
    ⚠️ 旧代码一律按 `CLK_HZ = 50 MHz` 换算 =>
       `480 / 5e7 = 9.6 µs` => 🔴 **整曲挤成 0 秒**（实测：播放器报 0 秒）。

    故这里给出可切换的口径：
       · `"midi"` —— tick 是音乐 tick（PPQN = 本文件的 PPQN）
       · `"clock"` —— tick 是 50 MHz 自由运行计数（旧行为）
       · `"auto"`（默认）—— **按数据自己判断**，见 `_guess_tick_unit()`
     📌 等 FPGA 侧在 v1.1 规范里写明单位后，把默认值钉死为那一种。

    ⭐ `Δtick` 用取模（见文件头纪律②）。

    ⭐⭐ 2026-10-01（加固）：⭐ **改为【逐事件累加】取模** ——
       🔴 旧版是 `(e.tick - base_tick) % 2³²`（⭐ **固定基准**）。
       ⚠️ 那个写法**只在"整段录制 < 一圈（85.9 秒）"时才等价**于真值：
         · ⭐ 32 位 @50 MHz ⇒ **85.9 秒**回绕一次
         · 🔴 真实曲子**必然超过 85.9 秒** ⇒ ⭐ 第二次回绕之后，
           固定基准会把"第 87 秒"算成"第 0.1 秒"（⭐ 差 87 秒，🔴 而文件依然"看起来正常"）。
       ⇒ ⭐ 现在：`Δ = (t_n − t_{n−1}) mod 2³²` **逐事件累加**
         ⇒ ⭐ 支持**任意次**回绕，⭐ 且与题面公式 `(t2 − t1) mod 2³²` **完全一致**。

    ⚠️ 音高来源（⭐ 加固后的**明确政策**）：
      ① ⭐ `phase_inc != 0` ⇒ ⭐ **用它反算**（⭐ 这是权威的"实际音高"）
      ② 🔴 `phase_inc == 0` ⇒ ⭐ **跳过该事件 + 计数**（⛔ **不猜音高**）
         · ⚠️ 唯一例外：显式传 `table_fallback=True` ⇒ ⭐ 才用**表同步**里
           该轴的**标称增量**兜底（⚠️ 那是 FPGA 声明的值，⛔ 不是我们猜的），
           ⭐ 而且**单独计数**（`inc_zero_from_table`）⇒ ⭐ 两种来源**分得清**。

    ⭐⭐ 2026-10-01（加固）：**新增 Tempo 元事件**。
       🔴 旧版⛔ 不写 tempo ⇒ ⚠️ `--bpm` 只改了**我们算 delta 用的 tps**，
          而文件里**没有任何东西告诉播放器该用多少 BPM**
          ⇒ 🔴 播放器按默认 120 BPM 放 ⇒ ⚠️ **`--bpm != 120` 时整首速度是错的**。
       ⭐ 现在写 `FF 51 03 <µs/四分音符>` ⇒ ⭐ 文件**自描述**，⛔ 不依赖播放器默认。
    """
    tps = PPQN * bpm / 60.0          # ⭐ 每秒多少个 MIDI tick（120BPM/960PPQN ⇒ 1920）
    # ---- tick 单位（2026-10-13）----
    # ⚠️ 这个值决定"tick -> 秒"。选错 => 整曲时间全错（且是【静默】的：
    #    音高还对，只是全挤在一起）=> 所以既给显式开关，也有自动判断 + 上报。
    unit = tick_unit
    if unit == TICK_UNIT_AUTO:
        unit, why = _guess_tick_unit(evs)
        stats.tick_unit = unit
        stats.tick_unit_reason = why
    stats.tick_unit_used = unit
    if unit == "midi":
        # 音乐 tick：一拍 = PPQN 个 tick => 每秒的 tick 数 = PPQN × BPM / 60
        ticks_per_sec_fpga = tps
    elif unit == "clock":
        ticks_per_sec_fpga = CLK_HZ   # ⭐ 旧行为：50 MHz 自由运行计数
    else:
        raise ValueError("未知 tick_unit：%r" % (unit,))

    # ⭐⭐ 任务 3：把【表同步】收到的表转成 `axis → 音符号` 的回退映射
    # -----------------------------------------------------------------------
    # ⭐ 为什么要它：⭐ 帧里的 `phase_inc` 是**实际频率**（⭐ 权威）；
    #    ⚠️ 但若某帧的 `inc = 0`（⭐ 没有音高信息）⇒ ⭐ 就用表里的**标称值**兜底。
    # ⚠️ 注意：⭐ 表给的是 `phase_inc`（⭐ 不是音符号）⇒ ⭐ 要**再反算一次**。
    #    ⭐ 优先用 `kb`（键盘模式）—— ⚠️ 因为帧里的 `axis` 是物理键号，
    #    ⭐ 与键盘模式表同源。
    tbl_axis_map = None
    if tables:
        src = tables.get(TABLESYNC_TABLE_KB) or tables.get(TABLESYNC_TABLE_FB)
        if src:
            tbl_axis_map = {}
            for ax, inc_v in enumerate(src):
                n = hz_to_note(inc_to_hz(inc_v))
                if n is not None:
                    tbl_axis_map[ax] = n
    # ⚠️ 显式传入的 `axis_map` 优先级**高于**表（⭐ 便于人工覆盖）
    eff_map = axis_map if axis_map is not None else tbl_axis_map

    # ⭐ 排序：⭐ 按 FPGA tick 的**相对顺序**（⚠️ 不能直接按数值排 —— 会回绕）
    #    ⇒ ⭐ 保持【文件顺序】作为时间序（⭐ 录制本身就是按时间来的）
    evs_sorted = list(evs)

    out = bytearray()
    prev_midi_t = 0
    prev_fpga_tick = None
    acc_ticks = 0                    # ⭐ 累加的真实 tick 数（⭐ 支持任意次回绕）
    open_notes = {}                  # (channel, identity) -> pending pitches
    tracks, last_by_channel = {}, {}
    skipped_no_pitch = 0
    ticks_seen = 0

    # MIDI 变长量的硬上限（规范：最多 4 字节，每字节 7 位）。
    # 🔴 2026-10-13 加：原来这里没有上限检查 => 超限时会**一直往后写**，
    #    产出一个【非法 MIDI】，而且**不报错**（⭐ 只有下游播放器/校验器才炸）。
    #    ⚠️ 实测触发条件：tick 序列非单调（例如多轴混合录制）时，
    #       `acc_ticks` 会累出天文数字 => delta 超限。
    #    ⭐ 判据：宁可【报错并说清原因】，也⛔ 不写出坏文件。
    VARLEN_MAX = 0x0FFFFFFF

    def var_len(v):
        """MIDI 变长量（每字节 7 位，最高位是"还有后续"标志）。"""
        if v < 0:
            v = 0
        if v > VARLEN_MAX:
            raise ValueError(
                "delta 超 MIDI 变长量上限：%d > %d（⭐ 通常意味着 tick 序列"
                "非单调，例如多条轴/多段录制混在一起 => 请先按轴或按段拆开）"
                % (v, VARLEN_MAX))
        buf = [v & 0x7F]
        v >>= 7
        while v:
            buf.append((v & 0x7F) | 0x80)
            v >>= 7
        return bytes(reversed(buf))

    # ⭐⭐ 2026-10-01（加固）：Tempo 元事件 —— ⭐ 让文件**自描述速度**
    #    ⚠️ `FF 51 03 tttttt`，⭐ tttttt = 每四分音符的微秒数（24 位大端）
    #    ⭐ 120 BPM ⇒ 500000 µs ⇒ 0x07A120
    us_per_qn = int(round(60_000_000.0 / bpm)) if bpm > 0 else 500000
    us_per_qn = max(1, min(0xFFFFFF, us_per_qn))
    out += var_len(0) + bytes([0xFF, 0x51, 0x03]) + us_per_qn.to_bytes(3, "big")

    def track_for(channel):
        if channel not in tracks:
            name = ("Drums" if channel == 9 else ("BASS", "GUITAR", "PIANO", "PAD")[channel]).encode("ascii")
            track = bytearray(var_len(0) + b"\xff\x03" + var_len(len(name)) + name)
            if channel != 9:
                track += var_len(0) + bytes([0xC0 | channel, (32, 24, 0, 89)[channel]])
            tracks[channel] = track
            last_by_channel[channel] = 0
        return tracks[channel]

    for e in evs_sorted:
        if e.tick is None:
            continue                     # ⚠️ ASCII 事件不参与 MIDI 时间轴

        if prev_fpga_tick is None:
            prev_fpga_tick = e.tick
        else:
            # Δt = (t_n − t_{n−1}) mod 2³² —— 逐事件累加
            #    这是跨回绕正确性的关键；累加 => 支持任意次回绕。
            #
            # 🔴🔴 2026-10-13 修：原来【无条件】取模 ⇒ 把"乱序"当成"回绕"。
            #    ⚠️ 后果：tick 真变小时（例如【多轴/多段混在同一份录制里】），
            #       取模得到 ≈ 2³² 的巨大 step ⇒ acc_ticks 爆掉
            #       ⇒ delta 超 MIDI 变长量上限 ⇒ 🔴 **写出非法 MIDI**。
            #    🔴 而且当时**不报错** —— 只有下游播放器/校验器才炸
            #       （⭐ 实测：midi_verify 报"变长量超过 4 字节"）。
            #
            # ⭐ 判据（怎么区分"回绕"和"乱序"）：
            #    回绕：32 位计数器在 85.9 秒处归零 ⇒ 新值【小】，但
            #          差值应当接近整圈（≈ 2³²）—— 即 step 落在"大半圈"。
            #    乱序：tick 突然回退一点点（例如另一条轴的录制插进来）
            #          ⇒ 取模后会得到"接近整圈但【不是】大半圈"的值，
            #            且随后的值又跳回原轨 ⇒ 会连续出现。
            #    实践上最稳的判据：⭐ 取模后 step 若 > 半圈（2³¹），
            #       它要么是真回绕（后续 tick 继续单调增长），
            #       要么是乱序 —— 而**乱序时后续还会再出现一次同样的跳变**。
            #    => 这里采用【保守且可观测】的做法：
            #       仍然按取模算（保留跨回绕正确性），但
            #       ① 计数（已有的 big_tick_steps）
            #       ② 再单独计一个 non_monotonic（tick 直接变小、且差值不大）
            #       ③ 若累计出现"不可接受的 delta"，var_len 会抛错并说清原因
            if e.tick < prev_fpga_tick:
                back = prev_fpga_tick - e.tick
                if back < (1 << 24):
                    # 回退幅度不大 ⇒ 基本可以断定是【乱序】而不是回绕
                    # （真回绕的回退幅度应当接近 2³²）
                    stats.non_monotonic_tick += 1
            step = (e.tick - prev_fpga_tick) % (1 << 32)
            if step > (1 << 31):
                # 单步跨过半圈（> 43 秒）⇒ 可疑（多半是乱序或坏帧残留）
                stats.big_tick_steps += 1
            acc_ticks += step
            prev_fpga_tick = e.tick
        t_sec = acc_ticks / ticks_per_sec_fpga
        midi_t = int(round(t_sec * tps))
        if midi_t < prev_midi_t:
            midi_t = prev_midi_t       # ⚠️ 单调（⭐ 防止取整回退）
        delta = midi_t - prev_midi_t

        if e.kind in ("note_on", "note_off"):
            # ---- ⭐⭐ inc == 0：⭐ 明确政策（⛔ 不猜音高）----
            channel = 9 if e.drum_type is not None else (e.timbre or 0) & 3
            identity = (channel, e.drum_type if channel == 9 else e.axis)
            if e.drum_type is not None:
                note = (36, 38, 42, 45)[e.drum_type & 3]
            elif e.kind == "note_off" and not e.inc and identity in open_notes:
                note = open_notes[identity][0]
            elif not e.inc:
                stats.inc_zero += 1
                if table_fallback and eff_map is not None and e.axis in eff_map:
                    note = eff_map[e.axis]
                    stats.inc_zero_from_table += 1
                else:
                    # ⭐ 跳过 + 计数（⭐ 这就是"⛔ 不猜音高"的落地）
                    stats.inc_zero_skipped += 1
                    skipped_no_pitch += 1
                    continue
            else:
                note = note_from_axis_inc(e.axis, e.inc)
                if note is None and eff_map is not None and e.axis in eff_map:
                    note = eff_map[e.axis]
                if note is None:
                    # ⚠️ inc ≠ 0 但算出来超出 MIDI 音域（⭐ 0..127）⇒ 也跳过 + 计数
                    skipped_no_pitch += 1
                    continue
            vel = e.vel if e.vel is not None else 0
            # ⭐ vel 是 8 位（0..255）⇒ ⭐ ÷2 缩放到 MIDI 的 0..127
            #    ⚠️ 下限取 1：⭐ MIDI 里 note_on 的 velocity=0 等于 note_off
            v7 = max(1, min(127, (vel + 1) // 2))
            track = track_for(channel)
            track += var_len(midi_t - last_by_channel[channel])
            last_by_channel[channel] = midi_t
            if e.kind == "note_on":
                track += bytes([0x90 | channel, note, v7])
                open_notes.setdefault(identity, []).append(note)
            else:
                # ⚠️ note_off 的力度用 0x40（⭐ 标准做法；⭐ FPGA 的"峰值力度"
                #    已体现在 note_on 里，⭐ 这里⛔ 不再用）
                if identity not in open_notes:
                    # ⚠️ 没 on 就 off ⇒ ⭐ 计数（⭐ 这通常意味着**前面有帧被拒收**）
                    stats.orphan_off += 1
                track += bytes([0x80 | channel, note, 0x40])
                pending = open_notes.get(identity, [])
                if note in pending:
                    pending.remove(note)
                if not pending:
                    open_notes.pop(identity, None)
            prev_midi_t = midi_t
            ticks_seen += 1

    # ⭐ 收尾：⭐ 给所有还开着的音补 note_off（⚠️ 否则播放器会挂音）
    stats.notes_open_at_end = sum(len(pending) for pending in open_notes.values())
    for (channel, identity), pending in open_notes.items():
        track = track_for(channel)
        for note in pending:
            track += var_len(prev_midi_t - last_by_channel[channel])
            last_by_channel[channel] = prev_midi_t
            track += bytes([0x80 | channel, note, 0x40])

    end_marker = var_len(0) + b"\xff\x2f\x00"
    payloads = [out + end_marker] + [track + end_marker for track in tracks.values()]
    hdr = b"MThd" + struct.pack(">IHHH", 6, 1, len(payloads), PPQN)
    chunks = [b"MTrk" + struct.pack(">I", len(track)) + track for track in payloads]
    return hdr + b"".join(chunks), skipped_no_pitch, ticks_seen


# ============================================================================
# ⭐ 自检（⛔ 不需要硬件）—— ⚠️ 必须【非空洞】：故意造坏数据要能被发现
# ============================================================================
# ⭐⭐ 2026-10-01（任务 4）：本地 `_mk_frame` **已删除** ——
#    ⚠️ 它原来与 `frame_format.build_frame` **重复实现**（⭐ 两处会漂）。
#    ⇒ ⭐ 现在统一用 `frame_format.build_frame`（⭐ 上面 import 时已别名成 `_mk_frame`）。
#    📌 这也顺带修了一个隐患：⭐ 本地那份**只支持 14 B 帧**，
#       ⚠️ 造不出 68 B 表帧 ⇒ 表同步那段自检**根本没法写**。


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
    inc440 = 38702840  # Full-width upstream phase accumulator at 50 MHz / 1024.
    hz = inc_to_hz(inc440)
    chk("① 440 Hz 往返 (inc=%d -> %.2f Hz)" % (inc440, hz), abs(hz - 440.0) < 0.5)
    # Pin the RTL's full-width A4 fixture independently of the conversion formula.
    chk("① 上行 A4 字面值 38702840 反算 440 Hz",
        abs(inc_to_hz(38702840) - 440.0) < 0.5)
    wrong_hz = 38702840 * CLK_HZ / TWO32
    chk("① 非空洞：误用 50 MHz 会高 1024 倍",
        wrong_hz > 100000 and abs(wrong_hz / hz - 1024) < 0.001,
        "  正确 %.1f Hz / 错误 %.1f Hz" % (hz, wrong_hz))
    chk("① ⭐ 用错解反算音符号 ⇒ 越界 None（⭐ 两解可区分）",
        hz_to_note(inc_to_hz(38702840)) == 69 and hz_to_note(wrong_hz) is None,
        "  错解音符号 = %s" % hz_to_note(wrong_hz))

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
    # 🔴🔴 2026-10-01（加固）：⭐ 旧版这条是**空洞的** ——
    #    ⚠️ 它自己写 `(t2 - t1) % (1<<32)` 去算，⭐ **根本没经过 `build_midi`**
    #    ⇒ 🔴 就算生产代码用朴素相减，⭐ 这条也照样绿（⭐ 典型的假绿）。
    #    ⭐ 现在：⭐ **走 `build_midi` 产出 MIDI 字节 → 用 `midi_verify` 读回来**，
    #       ⭐ 核对**真实写进文件的时间差**。
    print("\n[5] ⭐⭐ tick 回绕：⭐ 经 `build_midi` → 读回 MIDI 核对（⛔ 不自算）")
    # ⚠️ 必须让"真实 Δ"大到**能在 MIDI tick 上区分** ——
    #    🔴 若只用 8 个 tick（= 0.16 µs），⭐ 正解和错解**都舍入成 0**
    #    ⇒ ⚠️ `midi_t` 的单调钳位会把负值压成同一个 0 ⇒ 🔴 **判据失去区分力**（假绿）。
    wrap_t1 = (1 << 32) - 50_000_000     # ⭐ 回绕前 1 秒
    wrap_t2 = 50_000_000                 # ⭐ 回绕后 1 秒 ⇒ 真实 Δ = 2 秒
    wrap_d = 100_000_000
    f1 = _mk_frame(T_NOTE_ON, 0, wrap_t1, 1, inc440, 100)
    f2 = _mk_frame(T_NOTE_OFF, 1, wrap_t2, 1, inc440, 100)
    evs2, st2 = parse_stream(f1 + f2)
    chk("⑤ 回绕被记录", st2.tick_wraps == 1)
    chk("⑤ 两帧都解出来了", len(evs2) == 2 and st2.frames_ok == 2)
    if len(evs2) == 2:
        # ⚠️ 这一条保留（⭐ 它验的是"取模这个算术本身"），⛔ 但它**不是**主判据
        d = (evs2[1].tick - evs2[0].tick) % (1 << 32)
        chk("⑤ 取模 Δt = %d（⛔ 不是负数）" % wrap_d, d == wrap_d, "  实测 %d" % d)
        # ⭐⭐ 主判据：⭐ 真正写进 MIDI 的时间差
        midi_w, _sw, _nw = build_midi(evs2, ParseStats())
        rw = _read_midi(midi_w)
        ns_w = _notes_of(rw)
        want_w = int(round(wrap_d / CLK_HZ * (PPQN * DEFAULT_BPM / 60.0)))
        got_w = [e["t"] for e in ns_w]
        chk("⑤ ⭐ 读回 MIDI：Δ = %d tick（⛔ 不是 2³² 量级）" % want_w,
            len(ns_w) == 2 and ns_w[1]["t"] - ns_w[0]["t"] == want_w,
            "  实测 t=%s" % got_w)
        # ⭐⭐ 非空洞：⭐ 若用朴素相减 ⇒ Δ 为负 ⇒ 被单调钳位压成 0 ⇒ 与 %d 不同
        naive = wrap_t2 - wrap_t1
        chk("⑤ ⭐ 非空洞：朴素相减确实为负（⭐ 说明这条能区分对错）",
            naive < 0 and want_w > 0, "  朴素 = %d" % naive)

        # ⭐⭐ 2026-10-01（加固）：⭐ **跨【第二次】回绕** ——
        #    ⚠️ 32 位 @50 MHz ⇒ 85.9 秒一圈 ⇒ ⭐ 真实曲子**必然**跨第二圈。
        #    🔴 旧版"固定基准取模"（`(t - base) % 2³²`）只在**一圈内**才等价真值：
        #       ⭐ 第 90 秒会被算成第 4.1 秒（⭐ 差 86 秒，🔴 而文件仍"看起来正常"）。
        #    ⭐ 正确做法：⭐ `Δ = (t_n − t_{n−1}) mod 2³²` **逐事件累加**
        #       （⚠️ 前提：相邻事件间隔 < 一圈 —— ⭐ 真实演奏必然满足）
        mw = bytearray()
        for k in range(19):                    # ⭐ 0 / 5 / 10 / ... / 90 秒
            mw += _mk_frame(T_NOTE_ON, k & 0xFF,
                            (4244967296 + int(k * 5.0 * CLK_HZ)) % (1 << 32),
                            0, inc440, 100)
        e_mw, s_mw = parse_stream(bytes(mw))
        chk("⑤ 长曲：19 帧全收、⛔ 0 拒收",
            s_mw.frames_ok == 19 and s_mw.rejected == 0, "  %s" % s_mw.summary())
        m_mw, _sm, _nm = build_midi(e_mw, ParseStats())
        n_mw = _notes_of(_read_midi(m_mw))
        want_90 = int(round(90.0 * PPQN * DEFAULT_BPM / 60.0))
        chk("⑤ ⭐⭐ 跨第二圈：第 90 秒 ⇒ %d tick（⭐ 累计 90 秒）" % want_90,
            len(n_mw) > 18 and n_mw[18]["t"] == want_90,
            "  实测 t[18]=%s" % (n_mw[18]["t"] if len(n_mw) > 18 else None))
        fixed90 = (int(90.0 * CLK_HZ) % (1 << 32)) / CLK_HZ
        chk("⑤ ⭐ 非空洞：固定基准取模只得到 %.2f 秒（⭐ 差 %.0f 秒）"
            % (fixed90, 90.0 - fixed90), fixed90 < 10.0)

        # ⭐⭐ 加固：⭐ 验 `big_tick_steps` **真的会被填** ——
        #    🔴 否则它就是个**死字段**（⭐ 声明了、打印了、永远是 0 ⇒ 假绿）。
        e_big, s_big = parse_stream(
            _mk_frame(T_NOTE_ON, 0, 1000, 1, inc440, 100)
            + _mk_frame(T_NOTE_OFF, 1, 1000 + int(50.0 * CLK_HZ), 1, inc440, 100))
        build_midi(e_big, s_big)
        chk("⑤ 单步 Δ>43 秒 被记账（⭐ 不是死字段）", s_big.big_tick_steps == 1,
            "  实测 %d" % s_big.big_tick_steps)

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

    # ---- ⑧b ⭐⭐ 任务 3：表同步帧（68 B）必须**按类型定长**解析 ----
    # 🔴 为什么这是关键：⚠️ 若一律按 14 B 吃字节，
    #    ⭐ 一个 68 B 表帧会被切成 4 个假帧 + 4 个残留 ⇒ 🔴 整条流从此错位。
    print("\n[8b] ⭐⭐ 表同步帧（0x10，68 B）")
    tbl_vals = [inc440 + i for i in range(TABLESYNC_ITEMS)]
    tframe = bytearray(68)
    tframe[0] = FRAME_HDR
    tframe[1] = T_TABLESYNC
    tframe[2] = TABLESYNC_TABLE_KB
    for k, v in enumerate(tbl_vals):
        o = TABLESYNC_DATA_OFF + k * TABLESYNC_ITEM_BYTES
        tframe[o:o + 4] = (v & 0xFFFFFFFF).to_bytes(4, "big")
    tframe[67] = frame_checksum(bytes(tframe))
    tables = {}
    # ⭐ 表帧后面接一个**已知 tick** 的帧 ⇒ ⭐ 用它证明"表帧后没错位"
    after = _mk_frame(T_NOTE_ON, 7, 0x0000B000, 5, inc440, 150)
    evs_t, st_t = parse_stream(bytes(tframe) + after, tables=tables)
    chk("⑧b 表帧被识别（⛔ 不是 4 个假帧）", st_t.table_frames == 1,
        "  table_frames=%d ok=%d bad=%d" % (st_t.table_frames, st_t.frames_ok,
                                            st_t.frames_bad_csum))
    chk("⑧b 表内容逐项正确",
        tables.get(TABLESYNC_TABLE_KB) == tbl_vals,
        "  前 3 项=%s" % (tables.get(TABLESYNC_TABLE_KB, [])[:3]))
    chk("⑧b 表帧后【下一帧仍能正确解析】（⭐ 证明没错位）",
        st_t.frames_ok == 2 and any(e.tick == 0x0000B000 for e in evs_t),
        "  ok=%d ticks=%s" % (st_t.frames_ok,
                              [e.tick for e in evs_t if e.tick is not None]))
    # ⭐⭐ 非空洞性（⭐ 加固）：⭐ 旧版这里只断言 `68 != 14*4` ——
    #    🔴 那是一句**恒真的算术**，⭐ 跟被测代码**毫无关系**（⭐ 假绿）。
    #    ⭐ 现在直接拿**真实的表帧字节**去算：
    #       ⭐ 若一律按 14 B 解 ⇒ ⚠️ 那 14 字节的校验**必然不过**
    #       ⇒ ⭐ 表帧会被误判成"坏帧"，⛔ 而不是被识别 ⇒ ⭐ 这一条才真的能红。
    as14 = bytes(tframe)[:14]
    chk("⑧b 非空洞：按 14 B 解表帧 ⇒ 校验不过（⭐ 必被误判为坏帧）",
        frame_checksum(as14) != as14[13],
        "  csum=0x%02X vs 末字节 0x%02X" % (frame_checksum(as14), as14[13]))
    chk("⑧b 非空洞：真实帧长确实是 68（⭐ 不是回退值 14）",
        frame_len_known(T_TABLESYNC) == 68 and len(tframe) == 68)
    chk("⑧b ⛔ 68 ≠ 14×4（⭐ 长度必须按类型取）", 68 != 14 * 4)
    # ⭐⭐ 加固：⭐ 表帧被打坏后，重同步必须还能找回【后面那一帧】
    #    🔴 旧版窗口只有 14×4 = 56 B ⇒ ⚠️ **跨不过 68 B 的表帧** ⇒ 会静默丢数据
    broken_tbl = bytearray(tframe)
    broken_tbl[30] ^= 0x01                     # ⚠️ 表数据中间翻一位 ⇒ 校验不过
    evs_tb, st_tb = parse_stream(bytes(broken_tbl) + after)
    chk("⑧b 坏表帧被拒收", st_tb.frames_bad_csum == 1 and st_tb.table_frames == 0)
    chk("⑧b ⭐ 坏表帧【后面那一帧】仍被找回（⭐ 窗口能跨过 68 B）",
        st_tb.frames_ok == 1 and any(e.tick == 0x0000B000 for e in evs_tb),
        "  ok=%d resync=%d ticks=%s" % (st_tb.frames_ok, st_tb.resyncs,
                                        [e.tick for e in evs_tb if e.tick is not None]))
    chk("⑧b 拒收原因被记账", len(st_tb.rejects) == 1 and "csum" in st_tb.rejects[1 - 1][1],
        "  %s" % st_tb.rejects)

    # ---- v1.1 起播锚点（0x05）：解析器必须能认它，且【不崩】----
    # 为什么专门测"不崩"：0x05 的 [8..11] 是 ppqn，
    # parse_frame 返回的键是 `ppqn` 而不是 `inc`
    # => 若解析器没在取 inc 之前分流，会直接 KeyError 崩掉。
    _anch = []
    seq_anchor = bytearray()
    seq_anchor += _mk_frame(T_TRANSPORT_START, 0, 0x00100000, ppqn=960)
    seq_anchor += _mk_frame(T_NOTE_ON, 1, 0x00100010, 3, inc440, 200)
    seq_anchor += _mk_frame(T_NOTE_OFF, 2, 0x00101000, 3, inc440, 200)
    try:
        evs_an, st_an = parse_stream(bytes(seq_anchor), anchors=_anch)
        _anchor_ok = True
        _anchor_err = ""
    except Exception as e:                        # noqa: BLE001
        _anchor_ok = False
        _anchor_err = "%s: %s" % (type(e).__name__, e)
        evs_an, st_an = [], None
    chk("⑧c 含 0x05 锚点的流【能解析，⛔ 不崩】", _anchor_ok,
        ("  " + _anchor_err) if _anchor_err else "")
    chk("⑧c 锚点帧被计数", st_an is not None and st_an.anchor_frames == 1,
        "  anchor_frames=%s" % (st_an.anchor_frames if st_an else None))
    chk("⑧c 锚点【不】被算成正弦音符帧",
        st_an is not None and st_an.frames_ok == 2,
        "  frames_ok=%s（应 = 2 个音符）" % (st_an.frames_ok if st_an else None))
    chk("⑧c 锚点内容被收集", len(_anch) == 1 and _anch[0]["ppqn"] == 960,
        "  %s" % (_anch[0] if _anch else None))
    chk("⑧c 锚点的 tick 是【起播快照】",
        bool(_anch) and _anch[0]["tick"] == 0x00100000)
    chk("⑧c 锚点之后音符帧仍正常解析（⭐ 证明没错位）",
        any(e.tick == 0x00100010 for e in evs_an),
        "  ticks=%s" % [e.tick for e in evs_an if e.tick is not None])
    # 非空洞：把 0x05 帧的校验打坏 => 必须被拒收，且【不能】被当成音符收下
    bad_anchor = bytearray(seq_anchor)
    bad_anchor[13] ^= 0xFF
    evs_ba, st_ba = parse_stream(bytes(bad_anchor))
    chk("⑧c 非空洞：坏锚点帧被拒收（⛔ 不当音符收）",
        st_ba.frames_bad_csum == 1 and st_ba.anchor_frames == 0,
        "  bad_csum=%d anchor=%d ok=%d"
        % (st_ba.frames_bad_csum, st_ba.anchor_frames, st_ba.frames_ok))
    # 非空洞：ppqn=0 必须被计数（兜底不能掩盖异常）
    _a2 = []
    evs_z, st_z = parse_stream(
        bytes(_mk_frame(T_TRANSPORT_START, 0, 5, ppqn=0)), anchors=_a2)
    chk("⑧c 非空洞：ppqn=0 被如实计数（⭐ 兜底⛔ 不掩盖异常）",
        st_z.anchor_ppqn_zero == 1 and bool(_a2) and _a2[0]["ppqn_raw"] == 0,
        "  zero=%d raw=%s" % (st_z.anchor_ppqn_zero,
                              _a2[0]["ppqn_raw"] if _a2 else None))
    chk("⑧c ppqn=0 时解析出来的仍是【可用值】（⛔ 不是 0）",
        bool(_a2) and _a2[0]["ppqn"] != 0)
    # 锚点⛔ 不能进 MIDI —— 它不是音符，混进去会多出莫名其妙的音符/静音段。
    _midi_an, _sk_an, _n_an = build_midi(evs_an, st_an)
    _midi_no_anchor = bytearray()
    _midi_no_anchor += _mk_frame(T_NOTE_ON, 1, 0x00100010, 3, inc440, 200)
    _midi_no_anchor += _mk_frame(T_NOTE_OFF, 2, 0x00101000, 3, inc440, 200)
    _evs_na, _st_na = parse_stream(bytes(_midi_no_anchor))
    _midi_na, _, _n_na = build_midi(_evs_na, _st_na)
    chk("⑧c 锚点【不影响】MIDI 输出（⭐ 加不加锚点，字节一致）",
        _midi_an == _midi_na,
        "  含锚点 %d B vs 不含 %d B" % (len(_midi_an), len(_midi_na)))
    chk("⑧c 非空洞：锚点帧确实在流里（⭐ 证明上一条不是空流对比）",
        st_an.anchor_frames == 1 and "anchor" in [e.kind for e in evs_an])

    # ---- `last_seq` 的口径：只有音符事件参与 ----
    # FPGA 侧 2026-10-12 确认：0x05 是"谱面锚点"、0x01/0x02 是"音符事件"
    # => 两个不同的序列 => 锚点不得更新 last_seq，否则制造【假 gap】。
    # 这里造一个"锚点戳在两个连续音符中间"的流：
    #   音符 seq=10 -> 锚点 seq=99 -> 音符 seq=11
    #   ✅ 正确行为：seq_gaps == 0（锚点被排除）
    #   🔴 错误行为：seq_gaps >= 1（报"丢帧"，而其实一帧没丢）
    _sg = bytearray()
    _sg += _mk_frame(T_NOTE_ON, 10, 1000, 0, inc440, 200)
    _sg += _mk_frame(T_TRANSPORT_START, 99, 2000, ppqn=960)
    _sg += _mk_frame(T_NOTE_ON, 11, 3000, 0, inc440, 200)
    _evs_sg, _st_sg = parse_stream(bytes(_sg))
    chk("⑧d 锚点【不参与】last_seq（⛔ 不制造假 gap）",
        _st_sg.seq_gaps == 0,
        "  seq_gaps=%d（应为 0）" % _st_sg.seq_gaps)
    chk("⑧d 非空洞：锚点确实夹在两个音符之间（⭐ 证明上一条不是真空）",
        _st_sg.anchor_frames == 1 and _st_sg.frames_ok == 2,
        "  anchor=%d notes=%d" % (_st_sg.anchor_frames, _st_sg.frames_ok))
    # 反证：真的少一帧时，判据必须报出来（否则上面那条是"永远绿"）
    _sg2 = bytearray()
    _sg2 += _mk_frame(T_NOTE_ON, 10, 1000, 0, inc440, 200)
    _sg2 += _mk_frame(T_NOTE_ON, 13, 3000, 0, inc440, 200)   # 跳了 2
    _evs_sg2, _st_sg2 = parse_stream(bytes(_sg2))
    chk("⑧d 非空洞：音符序号真跳了就必须报 gap（⭐ 不是永远绿）",
        _st_sg2.seq_gaps == 1, "  seq_gaps=%d（应为 1）" % _st_sg2.seq_gaps)
    # 表帧同样不参与
    _sg3 = bytearray()
    _sg3 += _mk_frame(T_NOTE_ON, 10, 1000, 0, inc440, 200)
    _sg3 += _mk_frame(T_TABLESYNC, items=[1] * TABLESYNC_ITEMS)
    _sg3 += _mk_frame(T_NOTE_ON, 11, 3000, 0, inc440, 200)
    _evs_sg3, _st_sg3 = parse_stream(bytes(_sg3))
    chk("⑧d 表帧也不参与 last_seq", _st_sg3.seq_gaps == 0,
        "  seq_gaps=%d" % _st_sg3.seq_gaps)

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

    # ========================================================================
    # ⭐⭐ 2026-10-01（加固）新增段 —— ⭐ 全部围绕"坏帧⛔ 不许静默"与"能红"
    # ========================================================================
    print("\n[11] ⭐⭐ 坏帧记账：⛔ 一律不许静默产出错值")
    b1 = bytearray(good); b1[13] ^= 0xFF           # ⚠️ 只坏校验字节
    e_a, s_a = parse_stream(bytes(b1))
    chk("⑪ 校验错：⛔ 0 帧被收、⭐ 计 1 个坏帧",
        s_a.frames_ok == 0 and s_a.frames_bad_csum == 1)
    chk("⑪ 校验错：rejected 合计 = 1", s_a.rejected == 1)
    chk("⑪ 校验错：⛔ 不产出任何音符事件",
        not [e for e in e_a if e.kind in ("note_on", "note_off")])
    chk("⑪ 校验错：拒收原因被记账（含 csum）",
        len(s_a.rejects) == 1 and "csum" in s_a.rejects[0][1], "  %s" % s_a.rejects)
    # ⭐⭐ 非空洞：⭐ 坏帧的载荷本身是"合法"的 ⇒ ⭐ 若没有校验，它会被照收
    chk("⑪ ⭐ 非空洞：坏帧的 tick 解出来仍是【看起来正常】的值（⭐ 所以必须靠校验）",
        int.from_bytes(bytes(b1)[3:7], "big") == evil_tick,
        "  载荷 tick=0x%X（⭐ 未被破坏）" % int.from_bytes(bytes(b1)[3:7], "big"))

    print("\n[12] ⭐⭐ inc = 0：⭐ 跳过并计数（⛔ 不猜音高）")
    z1 = _mk_frame(T_NOTE_ON, 0, 1000, 2, 0, 200)      # ⭐ inc = 0
    z2 = _mk_frame(T_NOTE_OFF, 1, 2000, 2, 0, 200)
    evs_z, st_z = parse_stream(z1 + z2)
    chk("⑫ 帧本身合法（⭐ 2 帧全收、⛔ 0 坏帧）",
        st_z.frames_ok == 2 and st_z.rejected == 0)
    midi_z, sk_z, n_z = build_midi(evs_z, st_z)
    chk("⑫ inc=0 ⇒ ⛔ 不产出音符（⭐ 跳过）", n_z == 0 and sk_z == 2,
        "  参与=%d 跳过=%d" % (n_z, sk_z))
    chk("⑫ inc=0 被单独计数", st_z.inc_zero == 2 and st_z.inc_zero_skipped == 2)
    chk("⑫ 默认⛔ 不用表兜底", st_z.inc_zero_from_table == 0)
    r_z = _read_midi(midi_z)
    chk("⑫ ⭐ 非空洞：默认产出的 MIDI 里【一个音符都没有】",
        len(_notes_of(r_z)) == 0)
    # ⭐ 表兜底是**显式开启**的（⚠️ 用的是 FPGA 声明的标称值，⛔ 不是我们猜的）
    evs_z2, st_z2 = parse_stream(z1 + z2)
    midi_z2, _sk2, n_z2 = build_midi(
        evs_z2, st_z2, tables={TABLESYNC_TABLE_KB: [inc440] * TABLESYNC_ITEMS},
        table_fallback=True)
    chk("⑫ 显式开表兜底 ⇒ 才用表（⭐ 且单独计数）",
        n_z2 == 2 and st_z2.inc_zero_from_table == 1 and st_z2.inc_zero_skipped == 0)
    chk("⑫ 表兜底音高 = 69（⭐ 表里是 440 Hz）",
        [e["note"] for e in _notes_of(_read_midi(midi_z2))] == [69, 69])

    print("\n[13] ⭐⭐ 半帧截断 / 未知类型：⭐ 拒收并计数（⛔ 不静默）")
    half = good[:-3]                                   # ⚠️ 砍掉一帧的尾巴
    evs_h, st_h = parse_stream(half)
    chk("⑬ 半帧 ⇒ 0 帧被收", st_h.frames_ok == 0 and len(evs_h) == 0)
    chk("⑬ 半帧 ⇒ 计入 truncated（⛔ 不是算作校验错）",
        st_h.truncated == 1 and st_h.frames_bad_csum == 0,
        "  trunc=%d csum=%d" % (st_h.truncated, st_h.frames_bad_csum))
    evs_h2, st_h2 = parse_stream(good + b"\xA5")       # ⚠️ 尾部只剩一个帧头
    chk("⑬ 尾部只剩帧头 ⇒ 也算 truncated",
        st_h2.truncated == 1 and st_h2.frames_ok == 1)
    unk = bytearray(bytes([FRAME_HDR, 0x7F]) + bytes(12))
    unk[13] = frame_checksum(bytes(unk))               # ⚠️ 校验【是】对的
    evs_u, st_u = parse_stream(bytes(unk))
    chk("⑬ 未知类型 ⇒ ⛔ 不计入 frames_ok",
        st_u.frames_ok == 0 and st_u.bad_type == 1,
        "  ok=%d bad_type=%d" % (st_u.frames_ok, st_u.bad_type))
    chk("⑬ 未知类型 ⇒ ⛔ 不产出【帧事件】（⭐ 旧版会产出一个 unknown_type 事件）",
        not [e for e in evs_u if e.kind != "ascii"],
        "  ⚠️ 剩余 %d 个字节按 ASCII 落空（⭐ 保守推进 1 字节的代价，⛔ 不产生音符）"
        % len([e for e in evs_u if e.kind == "ascii"]))
    chk("⑬ 未知类型的载荷⛔ 不产生任何音符（⭐ 进不了 MIDI）",
        len(_notes_of(_read_midi(build_midi(evs_u, ParseStats())[0]))) == 0)
    chk("⑬ 未知类型 ⇒ rejected = 1", st_u.rejected == 1)
    chk("⑬ 未知类型 ⇒ 拒收原因含 type",
        len(st_u.rejects) == 1 and "type" in st_u.rejects[0][1], "  %s" % st_u.rejects)
    evs_u2, st_u2 = parse_stream(bytes(unk) + f_after)
    chk("⑬ 未知类型【后面】的真帧仍被找回（⛔ 不被吞掉）",
        st_u2.frames_ok == 1 and any(e.tick == 0x0000C000 for e in evs_u2),
        "  ok=%d resync=%d" % (st_u2.frames_ok, st_u2.resyncs))
    # ⭐⭐ 2026-10-15：`[7]` = `timbre[5:4] | axis[3:0]`，⭐ 掩码在【解析边界】就拆干净
    #   ⇒ ⭐ 掩码本身仍要验（垃圾字节只解出合法字段，⛔ 不是 255）。
    # 🔴🔴 2026-10-17 再改（用户实测 + RTL 地面真相 `evt_upstream.v:264`
    #   `b_axis = {2'b0, tm, ax}`）：`[3:0]` 是【轴号 0..15】，旧版上行帧没有鼓标记位。
    #   ⇒ 上一版按"鼓标记 0..3"写的两条判据（"15 越界必须被计数""0x22 合法不计数"）
    #     **整段删除** —— 它们钉的是一个不存在的字段（化石判据，⛔ 留着会把正确行为判成错）。
    # ⭐⭐ 2026-10-17 再加（FPGA 线新增 `bit[6] = is_drum`）：`[7] = {1'b0,is_drum,timbre[1:0],axis[3:0]}`
    #   ⇒ 🔴 **测试向量必须避开 bit[6]=1**：`0xFF` 的 bit6=1 ⇒ 按新语义是【鼓】
    #      ⇒ `axis` 必须是 0、`timbre` 必须是 None ⇒ 原来那条 "0xFF ⇒ axis=15" 与新时代冲突 ✗
    #      （这不是"实现坏了"，是判据钉了旧口径 —— 任何符合新语义的实现都会红）
    #   ✅ 改用 `0xBF`（1011_1111）：bit7=1 保留位 · **bit6=0 仍是音高字节** · timbre=3 · axis=15
    #      ⇒ 原意图（垃圾字节被掩码拆干净、⛔ 不是 255）一格不丢 ✓
    #   ✅ 另**补一条** `0xFF ⇒ 鼓`：垃圾字节里 bit6=1 也必须被正确识别成鼓（新语义的正向判据）。
    #   ⚠️ 必须绕过造帧侧：`_mk_frame`（= build_frame）写侧也掩码，
    #      直接传 0xFF 只会写出 0x0F ⇒ ⛔ 验不到解析侧的掩码。
    _axg = bytearray(_mk_frame(T_NOTE_ON, 0, 1000, 1, inc440, 100))
    _axg[OFF_AXIS] = 0xBF                      # bit7=1 保留位 · bit6=0（音高）· timbre=3 · axis=15
    _axg[-1] = frame_checksum(bytes(_axg))
    evs_ax, st_ax = parse_stream(bytes(_axg))
    chk("⑬ [7]=0xBF ⇒ 解成 axis=15 / timbre=3（⛔ 不是 255，⭐ 掩码仍在）",
        st_ax.frames_ok == 1 and len(evs_ax) == 1 and evs_ax[0].axis == 15,
        "  axis=%s" % (evs_ax[0].axis if evs_ax else None))
    # ⭐ 新位 `bit[6]=is_drum` 的正向判据：0xFF 的 bit6=1 ⇒ 鼓 ⇒ axis 必须是 0、drum_type=3
    _dgg = bytearray(_mk_frame(T_NOTE_ON, 0, 1000, 1, inc440, 100))
    _dgg[OFF_AXIS] = 0xFF                      # bit7=1 · bit6=1（鼓） · [5:4]=3 · [3:0]=15
    _dgg[-1] = frame_checksum(bytes(_dgg))
    evs_dg, st_dg = parse_stream(bytes(_dgg))
    chk("⑬ [7]=0xFF ⇒ 判为【鼓】(bit6=1) · drum_type=3 · axis=0（新位生效）",
        st_dg.frames_ok == 1 and len(evs_dg) == 1 and evs_dg[0].axis == 0,
        "  axis=%s" % (evs_dg[0].axis if evs_dg else None))
    # ⭐ 非空洞的另一半：合法轴号（含用户实测出现过的大轴号 10/12/13）必须照原样解出。
    _okg = bytearray(_mk_frame(T_NOTE_ON, 0, 1000, 1, inc440, 100))
    _okg[OFF_AXIS] = 0x0D                      # axis=13（用户实测里真实出现过）
    _okg[-1] = frame_checksum(bytes(_okg))
    evs_ok, st_ok = parse_stream(bytes(_okg))
    chk("⑬ [7]=0x0D ⇒ axis=13 照原样解出（大轴号合法，⛔ 不许报错/计数）",
        len(evs_ok) == 1 and evs_ok[0].axis == 13,
        "  axis=%s" % (evs_ok[0].axis if evs_ok else None))

    print("\n[14] ⭐⭐ Tempo 元事件：⭐ 文件必须【自描述】速度")
    chk("⑭ 读侧（midi_verify）可用（⭐ 下面几条的前提）", HAVE_MIDI_READER)
    # ⚠️ 必须【显式钉住 tick 单位】：
    #    这条测的是"BPM 变了，时间线跟着变"，与单位无关 ——
    #    但 `evs6` 的 tick 值（1000 / 51000）是【为 50 MHz 设计】的，
    #    而 2026-10-13 起了 auto 判断 => 51000 < 100000 会被判成音乐 tick
    #    => 两种 BPM 下都算出同一个绝对 tick => 这条判据假红。
    #    ⭐ 教训：判据依赖"数据长什么样"时，要把那个前提【显式写出来】，
    #       ⛔ 不要留给"自动推断"去猜。
    m120, _s1, _n1 = build_midi(evs6, ParseStats(), bpm=120.0,
                                tick_unit=TICK_UNIT_CLOCK)
    m60, _s2, _n2 = build_midi(evs6, ParseStats(), bpm=60.0,
                               tick_unit=TICK_UNIT_CLOCK)
    r120 = _read_midi(m120)
    r60 = _read_midi(m60)
    chk("⑭ 120 BPM ⇒ tempo = 500000 µs", r120["tempo_us"] == 500000,
        "  实测 %s" % r120["tempo_us"])
    chk("⑭ 60 BPM ⇒ tempo = 1000000 µs", r60["tempo_us"] == 1000000,
        "  实测 %s" % r60["tempo_us"])
    chk("⑭ ⭐ 非空洞：两种 BPM 写出的 tempo 【不同】",
        r120["tempo_us"] != r60["tempo_us"])
    t120 = [e["t"] for e in _notes_of(r120)]
    t60 = [e["t"] for e in _notes_of(r60)]
    chk("⑭ ⭐ 60 BPM 的 tick 数是 120 BPM 的一半（⭐ 时间线一致）",
        t60 and t120 and t60[-1] * 2 == t120[-1],
        "  120: %s / 60: %s" % (t120, t60))

    print("\n[15] ⭐⭐ 端到端：⭐ 合成 → `.mid` → **按规范读回**逐项核对")
    melody = [(440.0, 200), (523.25, 220), (659.25, 240)]
    rec = bytearray()
    sq = 0
    t_e = 1000
    step = int(0.25 * CLK_HZ)                     # ⭐ 0.25 秒
    for hz_v, vel_v in melody:
        iv = int(round(hz_v * TWO32 / FS_AUDIO_HZ))
        rec += _mk_frame(T_NOTE_ON, sq, t_e, 0, iv, vel_v); sq += 1
        rec += _mk_frame(T_NOTE_OFF, sq, t_e + step // 2, 0, iv, vel_v); sq += 1
        t_e += step
    rec += b"s"                                   # ⭐ 夹一个 ASCII 事件
    evs_e, st_e = parse_stream(bytes(rec))
    chk("⑮ 解析：6 帧 + 1 ASCII，⛔ 0 坏帧",
        st_e.frames_ok == 6 and st_e.ascii_events == 1 and st_e.rejected == 0,
        "  %s" % st_e.summary())
    midi_e, _sk_e, _n_e = build_midi(evs_e, st_e)
    r_e = _read_midi(midi_e)
    ns_e = _notes_of(r_e)
    ons_e = [e for e in ns_e if e["kind"] == "on"]
    chk("⑮ 读回：6 个音符事件（3 on + 3 off）",
        len(ns_e) == 6 and len(ons_e) == 3, "  实为 %d（on=%d）" % (len(ns_e), len(ons_e)))
    chk("⑮ ⭐ 音高逐项对（期望 %s）" % [hz_to_note(h) for h, _ in melody],
        [e["note"] for e in ons_e] == [hz_to_note(h) for h, _ in melody],
        "  实为 %s" % [e["note"] for e in ons_e])
    chk("⑮ ⭐ 力度逐项对（期望 %s）" % [(v + 1) // 2 for _, v in melody],
        [e["vel"] for e in ons_e] == [(v + 1) // 2 for _, v in melody],
        "  实为 %s" % [e["vel"] for e in ons_e])
    want_dt = int(round(0.25 * PPQN * DEFAULT_BPM / 60.0))
    got_dt = [ons_e[k + 1]["t"] - ons_e[k]["t"] for k in range(len(ons_e) - 1)]
    chk("⑮ ⭐ 音间 Δt = %d（⭐ 0.25 秒 @120BPM/960PPQN）" % want_dt,
        got_dt == [want_dt] * (len(ons_e) - 1), "  实测 %s" % got_dt)
    chk("⑮ ⭐ 文件头对【而且】内容对（⛔ 不是只看 MThd 的假绿）",
        midi_e[:4] == b"MThd" and r_e["division"] == PPQN and len(ns_e) == 6
        and abs((r_e["tempo_us"] or 0) - 500000) == 0)

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
    ap.add_argument("--table-fallback", dest="table_fallback",
                    action="store_true",
                    help="⭐ inc=0 时用【表同步】的标称增量兜底（⚠️ 默认关 ⇒ 跳过并计数）")
    ap.add_argument("--verify", action="store_true",
                    help="⭐ 写完立刻【按 MIDI 规范读回】核对（⛔ 不只看 MThd）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.inp:
        print("RED: 需要 --in（⚠️ 或用 --selftest）")
        return 2

    with open(args.inp, "rb") as f:
        data = f.read()
    print("输入 %s：%d 字节" % (args.inp, len(data)))

    # ⭐ 任务 3：表同步帧解析后存这里（⭐ 键 = 表号）
    tables = {}
    evs, st = parse_stream(data, tables=tables)
    print()
    print("解析结果：")
    print("  二进制帧 ok        = %d" % st.frames_ok)
    print("  🔴 被拒收合计      = %d   (⭐ 判据：⛔ 正常应为 0)" % st.rejected)
    print("     🔴 坏校验帧     = %d" % st.frames_bad_csum)
    print("     🔴 未知类型     = %d  (⛔ 不计入 ok，⛔ 不产出事件)" % st.bad_type)
    print("     🔴 半帧/长度不足 = %d" % st.truncated)
    print("  ⭐ 重同步成功/失败 = %d / %d" % (st.resyncs, st.resync_fail))
    print("  ⚠️ 未知高位字节    = %d  (⛔ 正常应为 0)" % st.unknown_hi)
    print("  ASCII 事件         = %d" % st.ascii_events)
    print("  note_on / off      = %d / %d" % (st.notes_on, st.notes_off))
    print("  ⭐ tick 回绕次数   = %d" % st.tick_wraps)
    # ⚠️ 注意：⭐ `big_tick_steps` / `inc_zero*` / `orphan_off` **是在 `build_midi` 里算的**
    #    ⇒ 🔴 必须放到 `build_midi` **之后**再打印（⭐ 否则永远显示 0 —— 假绿）。
    print("  序号缺口 / 回绕    = %d / %d" % (st.seq_gaps, st.seq_wraps))
    if st.rejects:
        print("  拒收明细（⭐ 前 %d 条）：" % len(st.rejects))
        for off, why in st.rejects:
            print("     @%-8d %s" % (off, why))
    # ⭐ 任务 3：表同步
    print("  ⭐ 表同步帧        = %d" % st.table_frames)
    for tid, vals in sorted(tables.items()):
        name = {TABLESYNC_TABLE_KB: "kb(键盘)", TABLESYNC_TABLE_FB: "fb(指板)"}.get(
            tid, "表%d" % tid)
        print("     %-12s %d 项，首项 inc=%d (%.1f Hz)"
              % (name, len(vals), vals[0] if vals else 0,
                 inc_to_hz(vals[0]) if vals else 0.0))

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

    midi, skipped, n = build_midi(evs, st, bpm=args.bpm, tables=tables,
                                  table_fallback=args.table_fallback)
    with open(args.out, "wb") as f:
        f.write(midi)

    print()
    print("写出 %s：%d 字节" % (args.out, len(midi)))
    print("  参与的事件   = %d" % n)
    print("  ⚠️ 无音高跳过 = %d" % skipped)
    print("     ⭐ 其中 inc=0 = %d（⭐ 跳过 %d / 表兜底 %d）"
          % (st.inc_zero, st.inc_zero_skipped, st.inc_zero_from_table))
    print("  ⚠️ 孤儿 note_off = %d（⭐ 没 on 就 off ⇒ 通常意味着前面有帧被拒收）"
          % st.orphan_off)
    print("  ⚠️ 单步 Δ>43 秒    = %d（⚠️ 可疑，⛔ 不是拒收）" % st.big_tick_steps)
    # tick 非单调：必须显眼。它多半意味着"输入不是单条时间轴"
    # （多轴/多段录制混在一起）—— 症状是 MIDI 写不出来，
    # ⚠️ 看起来像工具 bug，其实是输入的问题。
    if st.non_monotonic_tick:
        print("  🔴 tick 非单调      = %d  <== 🔴 输入可能混了多条时间轴"
              "（多轴/多段），⛔ 不是单条录制" % st.non_monotonic_tick)
    else:
        print("  ⭐ tick 单调        = OK（单条时间轴）")
    if st.tick_unit_used:
        print("  ⭐ tick 单位        = %s（%s）"
              % (st.tick_unit_used, st.tick_unit_reason or "显式指定"))
    print("  ⚠️ 收尾补 off = %d" % st.notes_open_at_end)

    # ⭐⭐ 加固：⭐ 写完**立刻按规范读回**核对（⛔ 只写不读 = 假绿风险）
    if args.verify:
        print()
        if not HAVE_MIDI_READER:
            print("  🔴 读侧（midi_verify）不可用 ⇒ ⛔ 无法读回核对")
            return 1
        res = _read_midi(midi)
        ns = _notes_of(res)
        print("  读回核对：division=%d tempo=%s 音符事件=%d（on=%d off=%d）"
              % (res["division"],
                 "无" if res["tempo_us"] is None else "%d µs" % res["tempo_us"],
                 len(ns), sum(1 for e in ns if e["kind"] == "on"),
                 sum(1 for e in ns if e["kind"] == "off")))
        print("  ⭐ 事件数与写侧一致：%s"
              % ("OK" if len(ns) == n else "RED（写 %d / 读 %d）" % (n, len(ns))))
        if len(ns) != n:
            return 1

    if st.rejected or st.unknown_hi:
        print("  🔴 注意：有 %d 个坏帧 + %d 个未知高位字节 ⇒ 结果可能不完整"
              % (st.rejected, st.unknown_hi))
    return 0


if __name__ == "__main__":
    sys.exit(main())
