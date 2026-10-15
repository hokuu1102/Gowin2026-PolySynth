#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frame_format.py —— ⭐ **上行帧格式的【唯一】定义处**（⭐ 任务 4）

═══ 为什么单独成一个文件 ═══
🔴 **上行格式尚未冻结**（⭐ 见 `files/20-代码/ESP32侧再回函-20261001.md` §三）
⇒ ⚠️ 格式一定会改 ⇒ ⭐ **把"会变的东西"集中到一处**，
   ⭐ 冻结/改版时**只动这个文件**，⛔ 不用翻遍解析逻辑。

⭐⭐ **本文件只放【帧结构】，⛔ 不放音频换算**
   · 帧结构 = 帧头 / 类型 / 长度 / 字段偏移 / 校验   ← ⭐ 本文件
   · 音频换算 = `phase_inc → 频率 → 音符号`          ← ⚠️ 那是 `evt2midi.py`
   ⇒ ⭐ 两者变化的**原因不同**（协议 vs 物理）⇒ ⚠️ 混在一起会互相干扰。

═══ 格式状态：v1.1 —— 已由 FPGA 侧【建议冻结】（2026-10-01 14:52）═══

权威依据（最终版，它修订了 00:45 那份同名 v1.1）：
   `files/20-代码/FPGA侧答复-ESP32再回函-20261001.md` 第四节
   标题原文："建议冻结的【上行帧格式 v1.1】（在你第三节基础上改 3 处）"

注意有两份都叫 v1.1，以【14:52 那份】为准：
   · `FPGA侧回应-ESP32再回函-20261001.md`（00:45）—— 早期版：
     `0x05` 叫 `PLAY_START`，`[7..10]` 放 `score_tick0`，不用这个
   · `FPGA侧答复-ESP32再回函-20261001.md`（14:52）—— 最终版：
     `0x05` 叫 `transport_start`，`[8..11]` 放 `ppqn`
   前者被后者显式取代（字段安排不同）=> 只按后者实现。
```
[0] 0xA5   帧头（⭐ ⛔ 与 ASCII 流天然不相交 —— ASCII 全 ≤ 0x7F）
[1] 类型   0x01=note_on 0x02=note_off 0x03=calib 0x04=looper 0x10=表同步
[2] seq    8 位序号（⚠️ 只用于【短窗口】丢帧检测 —— 750 事件/s 时 0.34 秒就回绕）
[3..6] tick   32 位自由运行计数器（⭐ 大端；⭐ Δt 取模 2³²）
[7] axis   轴号 0..15
[8..11] phase_inc 32 位（⭐ 大端）
[12] vel   8 位（0..255）
[13] 校验  8 位
帧长 = 14 B（⭐ 音符类）

表同步（0x10）：
[0] 0xA5 [1] 0x10 [2] 表号(0=kb/1=fb) [3..66] 16×4B [67] 校验 = 68 B
```
"""

import sys

# ⚠️ 控制台 UTF-8 —— 中文 Windows 默认 **GBK**，⛔ 打不出 ⭐🔴⚠️ 这些字符
#    （🔴 实测：不加这段，`print("⛔ ...")` 直接 `UnicodeEncodeError` 崩掉）
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_HDR = 0xA5

# ---- 类型码 ----------------------------------------------------------------
T_NOTE_ON = 0x01
T_NOTE_OFF = 0x02
T_CALIB = 0x03
T_LOOPER = 0x04
# 起播锚点（v1.1 新增，FPGA 侧 2026-10-01 14:52 裁定）。
# 为什么需要它：`tick` 是【自由运行】计数器 => Δt 算得对，
#   但"这一下弹在第几拍"算不出来 => 必须有一次性对齐信息。
# 载荷复用：`[3..6]` = 起播那一刻的 tick 快照；`[8..11]` = ppqn（不是 phase_inc）。
T_TRANSPORT_START = 0x05
T_TABLESYNC = 0x10

FRAME_TYPE_NAMES = {
    T_NOTE_ON: "note_on",
    T_NOTE_OFF: "note_off",
    T_CALIB: "calib",
    T_LOOPER: "looper",
    T_TRANSPORT_START: "transport_start",
    T_TABLESYNC: "tablesync",
}

# FPGA 侧的音乐 tick 分辨率（`beat_gen` 定义）。
# 反证：`rtl/w3b/drum_gen.v:82` 的 TICKS_PER_STEP = 240 = PPQN/4。
# 有了它，PC 侧才能做 bar = tick / (ppqn * 拍号) 的换算；
# 没有它就只能算"相对间隔"，算不出"第几拍/第几个 16 分音符"。
PPQN_FPGA = 960
# 起播锚点帧里若 ppqn 为 0（异常/旧固件），用这个回退值并记一笔。
PPQN_FALLBACK = PPQN_FPGA

# ---- ⭐⭐ 帧长【按类型】取（⭐ 任务 3 的关键）-------------------------------
# 🔴 为什么必须分长度：⚠️ 若一律按 14 B 吃字节，
#    ⭐ 一个 68 B 的表帧会被切成 **4 个假帧 + 4 个残留字节**
#    ⇒ 🔴 **整条流从此错位**（⚠️ 而且校验大多能过 —— 最难查的一类）。
FRAME_LEN_DEFAULT = 14
FRAME_LEN_BY_TYPE = {
    T_NOTE_ON: 14,
    T_NOTE_OFF: 14,
    T_CALIB: 14,
    T_LOOPER: 14,
    T_TRANSPORT_START: 14,      # v1.1：复用同 4 字节放 ppqn，帧长不变
    T_TABLESYNC: 68,
}

# 哪些类型把 `[8..11]` 解释成 ppqn 而不是 phase_inc。
# 单独列出来，避免解析器到处写 `if ftype == T_TRANSPORT_START`。
PPQN_TYPES = frozenset({T_TRANSPORT_START})

# ⭐⭐ 2026-10-01（加固）：**已知类型的白名单** —— ⚠️ 这是"未知类型必须拒收"的依据。
# 🔴 为什么需要它：⚠️ `frame_len_for()` 对未知类型会**回退到 14**
#    ⇒ 🔴 若解析器只靠它定长，一个**未知类型**的帧会被当成 14 B 音符帧**照收**
#    ⇒ ⭐ 那就等于"把不理解的东西当理解了的用"（⭐ 与"坏帧伪装成合理值"同族）。
#    ⇒ ⭐ 所以解析器**必须先查白名单**：⛔ 不在白名单 ⇒ 拒收 + 计数，⛔ 不猜长度。
KNOWN_TYPES = frozenset(FRAME_LEN_BY_TYPE)

# ⭐ 最长帧（⭐ 用于定重同步窗口 —— ⚠️ 窗口必须能跨过一整个被损坏的表帧）
MAX_FRAME_LEN = max(FRAME_LEN_BY_TYPE.values())

# ---- 音符类帧的字段偏移（⭐ 大端）------------------------------------------
OFF_TYPE = 1
OFF_SEQ = 2
OFF_TICK = 3
OFF_AXIS = 7
OFF_INC = 8
OFF_VEL = 12
LEN_TICK = 4
LEN_INC = 4

# ---- 表同步帧的布局 --------------------------------------------------------
TABLESYNC_DATA_OFF = 3
TABLESYNC_ITEMS = 16
TABLESYNC_ITEM_BYTES = 4
TABLESYNC_TABLE_KB = 0
TABLESYNC_TABLE_FB = 1
TABLESYNC_TABLE_NAMES = {TABLESYNC_TABLE_KB: "kb(键盘)",
                         TABLESYNC_TABLE_FB: "fb(指板)"}


def frame_len_for(ftype):
    """⭐ 按类型取帧长；⚠️ 未知类型回退到 14 B（⭐ 调用方会把它计为 bad_type）。"""
    return FRAME_LEN_BY_TYPE.get(ftype, FRAME_LEN_DEFAULT)


def frame_len_known(ftype):
    """
    ⭐⭐ 2026-10-01（加固）：**严格版** —— ⚠️ 未知类型返回 `None`，⛔ 不猜长度。

    🔴 为什么必须有两个版本：
       · `frame_len_for()`  ⚠️ 给"造帧/兼容旧代码"用 —— ⭐ 未知类型回退 14
       · `frame_len_known()` ⭐ 给**解析器**用 —— ⭐ 未知类型必须能被识别出来
    ⚠️ 解析器若用前者，就会**把未知类型当 14 B 音符帧收下** ⇒ 🔴 静默错误。
    """
    return FRAME_LEN_BY_TYPE.get(ftype)


def is_known_type(ftype):
    """⭐ 该类型码在白名单里吗？（⭐ 解析器判"未知类型"就靠它）"""
    return ftype in KNOWN_TYPES


def frame_checksum(b):
    """
    帧校验（v1.1 定为 XOR）—— 若 FPGA 侧改用累加和，只改这一处。

    对任意长度的帧都成立：校验字节是最后一个字节
    （14 B 帧是 `b[13]`，68 B 表帧是 `b[67]`）。
    """
    c = 0
    for x in b[:-1]:
        c ^= x
    return c & 0xFF


def sat_add(cur, inc=1, cap=0xFFFFFFFF):
    """
    饱和加法 —— FPGA 侧 2026-10-01 明确要求的纪律。

    为什么要饱和而不是回绕（FPGA 侧原话）：
      "计数必须饱和（不回绕）—— 因为回绕会让'丢了 256 次'读成'丢了 0 次'
       => 又变成静默失效。"
    这是同族 C113（错得看不出来）在计数上的形态：
    计数器本身出错时，它看起来和一个"一切正常"的计数器一模一样。
    """
    v = cur + inc
    return cap if v > cap else v


class Counters(object):
    """
    解析器的记账本 —— 每个"会出错的状态"都有一个可读的数字。

    依据 FPGA 侧裁定的第 2 条："坏帧必须记账"。
    这里刻意不继承 dict，避免调用方以为它是普通字典而漏掉饱和语义。
    """

    __slots__ = ("good", "bad_checksum", "bad_type", "bad_len",
                 "resync_tries", "resync_ok", "ascii_bytes", "total_bytes")

    def __init__(self):
        self.good = 0
        self.bad_checksum = 0
        self.bad_type = 0
        self.bad_len = 0
        self.resync_tries = 0
        self.resync_ok = 0
        self.ascii_bytes = 0
        self.total_bytes = 0

    def bump(self, name, inc=1):
        setattr(self, name, sat_add(getattr(self, name), inc))
        return self

    def bad_total(self):
        return self.bad_checksum + self.bad_type + self.bad_len

    def __repr__(self):
        return ("Counters(good=%d bad: cksum=%d type=%d len=%d | "
                "resync %d/%d | ascii=%d total=%d)"
                % (self.good, self.bad_checksum, self.bad_type, self.bad_len,
                   self.resync_ok, self.resync_tries,
                   self.ascii_bytes, self.total_bytes))


def find_next_frame(buf, start=0, max_back=None):
    """
    校验驱动的重同步 —— FPGA 侧裁定的第 3 条。

    FPGA 侧原话（这是它给的【区分】）：
      "做，但按你那个区分来做 —— 「坏帧后在随后若干字节里找校验能过的帧头」。
       不把'扫帧头'当平时的同步手段。"

    所以本函数【只】在已经判定坏帧之后调用；平时的同步靠定长状态机推进，
    绝不每帧都扫。两者的区别是性能与误判率的差别：
      · 平时扫 => 载荷里的 0xA5 会把解析器带去错误位置（且校验可能碰巧能过）
      · 只在坏帧后扫 => 扫描范围有界，且必须"帧头 + 类型合法 + 校验过"三条同时满足

    参数：
      buf      待扫描的字节（bytes/bytearray）
      start    从哪个下标开始找（通常 = 坏帧的位置 + 1）
      max_back 最多向后扫多少字节（默认 = 2 倍最长帧）
    返回：
      (pos, ftype, flen) 找到则给出位置/类型/长度；找不到返回 (None, None, None)
    """
    if max_back is None:
        max_back = MAX_FRAME_LEN * 2
    end = min(len(buf), start + max_back)
    i = start
    while i < end:
        # 帧头
        if buf[i] != FRAME_HDR:
            i += 1
            continue
        if i + 1 >= end:
            break
        ftype = buf[i + 1]
        flen = frame_len_known(ftype)
        if flen is None:
            # 类型不在白名单 => 这多半是载荷里的巧合 0xA5，继续找
            i += 1
            continue
        if i + flen > len(buf):
            # 尾巴不够一帧 => 无法判校验，交给调用方继续攒字节
            return None, None, None
        cand = buf[i:i + flen]
        if frame_checksum(cand) == cand[-1]:
            return i, ftype, flen
        i += 1
    return None, None, None


def is_ascii_byte(b):
    """
    ⭐ 该字节属于 **ASCII 事件流**吗？

    ⭐ 依据（⭐ FPGA 侧已确认的"模式可辨"裁定）：
      ⭐ **ASCII 事件流永远 ≤ 0x7F**（`s t x T S !` + 数字 + `.` + `\\r\\n`）
      ⭐ 而二进制帧头 `0xA5` > 0x7F
      ⇒ ⭐ **两条流的字节域【天然不相交】** ⇒ ⭐ 按首字节即可判别，⛔ 不用切换命令。
    """
    return b < 0x80


def parse_frame(f):
    """
    ⭐ 把**一个完整帧**解成 dict。

    ⚠️ 调用方负责：① 长度够 ② 校验已过。⭐ 本函数**不做校验**（⭐ 职责单一）。

    ⭐⭐ 2026-10-01（加固）：**本函数现在会【拒收】明显不合法的输入**（⭐ 抛 `ValueError`）：
      · 长度 < 2                  ⇒ ⚠️ 连"类型字节"都没有
      · `f[0] != FRAME_HDR`       ⇒ ⚠️ 不是帧头
      · 类型**不在白名单**         ⇒ 🔴 未知类型 ⛔ 不猜布局（⭐ 旧版会按 14 B 瞎解）
      · 长度 **≠ 该类型的帧长**    ⇒ 🔴 半帧 / 错位（⭐ 旧版会 `IndexError` 或读出垃圾）

    🔴 为什么必须"抛错"而⛔ 不是"尽量解"：
       ⚠️ 一位翻转会让字段变成**看起来正常**的值（⭐ 实测 933）
       ⇒ ⭐ 只要还有一条路径能把坏数据解成"合理值"，🔴 那个风险就还在。

    返回 dict，⭐ 字段随类型不同：
      · 音符类：`type/seq/tick/axis/inc/vel`
      · 表同步：`type/table/items`（⭐ 16 个 32 位增量）
    """
    if len(f) < 2:
        raise ValueError("帧太短：%d 字节（⛔ 连类型字节都没有）" % len(f))
    if f[0] != FRAME_HDR:
        raise ValueError("帧头错：0x%02X（⭐ 应为 0x%02X）" % (f[0], FRAME_HDR))

    ftype = f[1]
    want = frame_len_known(ftype)
    if want is None:
        raise ValueError("未知类型 0x%02X（⭐ ⛔ 不猜长度，拒收）" % ftype)
    if len(f) != want:
        raise ValueError("长度不符：类型 0x%02X 应为 %d B，实为 %d B（⚠️ 半帧/错位）"
                         % (ftype, want, len(f)))

    if ftype == T_TABLESYNC:
        items = []
        for k in range(TABLESYNC_ITEMS):
            o = TABLESYNC_DATA_OFF + k * TABLESYNC_ITEM_BYTES
            items.append(int.from_bytes(f[o:o + TABLESYNC_ITEM_BYTES], "big"))
        return {"type": ftype, "table": f[2], "items": items}

    raw48 = int.from_bytes(f[OFF_INC:OFF_INC + LEN_INC], "big")
    if ftype in PPQN_TYPES:
        # v1.1：起播锚点帧 —— `[8..11]` 是 ppqn，不是 phase_inc。
        # `[7]` 本类型填 0（不是轴号），`[12]` 是 0（不是力度）。
        # 注意：这里【不】把它当成音符事件；调用方必须按 type 分流。
        return {
            "type": ftype,
            "seq": f[OFF_SEQ],
            "tick": int.from_bytes(f[OFF_TICK:OFF_TICK + LEN_TICK], "big"),
            "ppqn": raw48 if raw48 else PPQN_FALLBACK,
            "ppqn_raw": raw48,
            "axis": f[OFF_AXIS],
            "vel": f[OFF_VEL],
        }
    return {
        "type": ftype,
        "seq": f[OFF_SEQ],
        "tick": int.from_bytes(f[OFF_TICK:OFF_TICK + LEN_TICK], "big"),
        #  ⭐⭐ 2026-10-15：⭐ `[7]` 现在装**两样东西**（⭐ 帧长不变）✅
        #     布局：bit[7:6]=0（留位）· bit[5:4]=**音色** · bit[3:0]=**轴号**
        #     🔴 **为什么加音色**：⭐ 要把上行事件转成 MIDI ⇒ ⭐ MIDI 需要
        #        **program change** ⇒ ⚠️ 而帧里原来没有这个字段
        #     ✅ **向后兼容**：⭐ 音色 = 0（BASS）时 `[7]` 与原来**完全相同** ✅
        #     🔴 **必须与 FPGA 侧同时改**（⭐ `rtl/w3c/evt_upstream.v` 的 `b_axis`）
        #        ⇒ ⚠️ 只烧一边会出现"音高全乱" ✅
        #     📌 音色映射：⭐ 0=BASS · 1=GUITAR · 2=PIANO · 3=PAD ✅
        "axis":   f[OFF_AXIS] & 0x0F,
        "timbre": (f[OFF_AXIS] >> 4) & 0x03,
        "inc": raw48,
        "vel": f[OFF_VEL],
    }


def build_frame(ftype, seq=0, tick=0, axis=0, inc=0, vel=0,
                table=None, items=None, ppqn=None, timbre=0):
    """
    造一个帧（给测试/自检用；也可当"模拟 FPGA"的发包工具）。

    表同步帧（`0x10`）走 `table=`/`items=` 参数，不用 tick/axis 那套。
    v1.1 起播锚点（`0x05`）走 `ppqn=` 参数 —— 它会占用 `[8..11]`，
    所以此时 `inc` 被忽略（两者【共用同一段字节】，这是协议定的，不是巧合）。
    """
    if ftype == T_TABLESYNC:
        f = bytearray(FRAME_LEN_BY_TYPE[T_TABLESYNC])
        f[0] = FRAME_HDR
        f[1] = ftype
        f[2] = (table if table is not None else TABLESYNC_TABLE_KB) & 0xFF
        if items:
            for k, v in enumerate(items[:TABLESYNC_ITEMS]):
                o = TABLESYNC_DATA_OFF + k * TABLESYNC_ITEM_BYTES
                f[o:o + TABLESYNC_ITEM_BYTES] = (v & 0xFFFFFFFF).to_bytes(4, "big")
        f[-1] = frame_checksum(bytes(f))
        return bytes(f)

    if ftype in PPQN_TYPES:
        # 起播锚点：`[8..11]` 放 ppqn。用它自己的参数，避免调用方传错。
        if ppqn is None:
            raise ValueError("0x05 起播锚点帧必须给 ppqn=（它会占用 [8..11]）")
        inc = ppqn
        axis = 0
        vel = 0

    f = bytearray(FRAME_LEN_DEFAULT)
    f[0] = FRAME_HDR
    f[1] = ftype & 0xFF
    f[OFF_SEQ] = seq & 0xFF
    f[OFF_TICK:OFF_TICK + LEN_TICK] = (tick & 0xFFFFFFFF).to_bytes(LEN_TICK, "big")
    f[OFF_AXIS] = ((timbre & 0x03) << 4) | (axis & 0x0F)
    f[OFF_INC:OFF_INC + LEN_INC] = (inc & 0xFFFFFFFF).to_bytes(LEN_INC, "big")
    f[OFF_VEL] = vel & 0xFF
    f[-1] = frame_checksum(bytes(f))
    return bytes(f)


# ============================================================================
# ⭐ 自检（⛔ 不需要硬件）
# ============================================================================
def selftest():
    """
    ⭐⭐ 为什么本文件也要自检：
      🔴 它是**所有解析的根基** —— ⚠️ 这里错一位，**上面全错**，
      而且 ⚠️ 错得"看起来很正常"（⭐ 与 `C113` 同族）。
    """
    print("=" * 74)
    print("frame_format.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    def _raises(fn, *a, **kw):
        """
        ⭐⭐ 加固用的判据：⭐ "**必须抛错**"。
        ⚠️ 为什么需要它：🔴 旧版只能断言"解出来的值不同" ——
           ⚠️ 那只说明"会读错"，⭐ 而**不禁止**读错 ⇒ 🔴 弱断言。
        """
        try:
            fn(*a, **kw)
            return False
        except ValueError:
            return True

    print("\n[1] ⭐ 常量自洽")
    chk("   帧头 = 0xA5", FRAME_HDR == 0xA5)
    chk("   帧头【不是】ASCII（⭐ 模式可辨的前提）", not is_ascii_byte(FRAME_HDR))
    chk("   音符帧 = 14 B", frame_len_for(T_NOTE_ON) == 14)
    chk("   表帧   = 68 B", frame_len_for(T_TABLESYNC) == 68)
    chk("   68 = 1+1+1+16×4+1", 1 + 1 + 1 + TABLESYNC_ITEMS * TABLESYNC_ITEM_BYTES + 1 == 68)
    chk("   未知类型回退 14", frame_len_for(0x7F) == FRAME_LEN_DEFAULT)
    # ⭐⭐ 加固：白名单 / 严格长度
    # v1.1 起播锚点 0x05 加入后，白名单从 5 类变 6 类。
    # 这条判据故意写死数字：加类型时【必须】同时改这里，
    # 否则"偷偷加了个类型"没人发现。
    chk("   白名单恰为 6 类（v1.1：+0x05）", len(KNOWN_TYPES) == 6,
        "  %s" % sorted(KNOWN_TYPES))
    chk("   0x05 在白名单里", is_known_type(T_TRANSPORT_START))
    chk("   0x05 帧长 = 14（复用 [8..11]，帧长不变）",
        frame_len_known(T_TRANSPORT_START) == 14)
    chk("   0x10 在白名单里", is_known_type(T_TABLESYNC))
    chk("   0x7F ⛔ 不在白名单里", not is_known_type(0x7F))
    chk("   frame_len_known(0x10) = 68", frame_len_known(T_TABLESYNC) == 68)
    chk("   frame_len_known(未知) = None（⭐ ⛔ 不猜）", frame_len_known(0x7F) is None)
    chk("   MAX_FRAME_LEN = 68", MAX_FRAME_LEN == 68)
    chk("   ppqn 类型集合 = {0x05}", set(PPQN_TYPES) == {T_TRANSPORT_START})
    chk("   FPGA ppqn = 960（beat_gen 定义）", PPQN_FPGA == 960)
    # ⚠️ 与 0x05 复用相关的一条硬约束：它不能和音符类共用 inc 语义
    chk("   0x05 ⛔ 不属于音符事件（不会当成 note 处理）",
        not (T_TRANSPORT_START in (T_NOTE_ON, T_NOTE_OFF)))

    print("\n[2] ⭐ 构造 → 解析 往返（⭐ 音符帧）")
    fr = build_frame(T_NOTE_ON, seq=5, tick=0x0000B000, axis=9, inc=37796, vel=200)
    chk("   长度 14", len(fr) == 14)
    chk("   帧头对", fr[0] == FRAME_HDR)
    chk("   校验对", frame_checksum(fr) == fr[-1])
    d = parse_frame(fr)
    chk("   type 往返", d["type"] == T_NOTE_ON)
    chk("   seq  往返", d["seq"] == 5)
    chk("   tick 往返", d["tick"] == 0x0000B000)
    chk("   axis 往返", d["axis"] == 9)
    chk("   inc  往返", d["inc"] == 37796)
    chk("   vel  往返", d["vel"] == 200)

    print("\n[3] ⭐⭐ 表帧往返（⭐ 与音符帧【布局不同】，⛔ 不能混用）")
    vals = [1000 + i for i in range(TABLESYNC_ITEMS)]
    tf = build_frame(T_TABLESYNC, table=TABLESYNC_TABLE_FB, items=vals)
    chk("   长度 68", len(tf) == 68)
    chk("   校验对", frame_checksum(tf) == tf[-1])
    dt = parse_frame(tf)
    chk("   table 往返", dt["table"] == TABLESYNC_TABLE_FB)
    chk("   items 逐项往返", dt["items"] == vals)
    chk("   表帧【没有】tick/axis 键（⭐ 布局确实不同）",
        "tick" not in dt and "axis" not in dt)

    print("\n[4] ⭐ 极值 / 边界")
    mx = build_frame(T_NOTE_ON, seq=255, tick=0xFFFFFFFF, axis=15, inc=0xFFFFFFFF, vel=255)
    dm = parse_frame(mx)
    chk("   全 0xFF 往返（tick 32 位）", dm["tick"] == 0xFFFFFFFF)
    chk("   全 0xFF 往返（inc 32 位）", dm["inc"] == 0xFFFFFFFF)
    #  ⭐⭐ 2026-10-15：⭐ `axis` 从 **255 改成 15**（⭐ 因为 `[7]` 现在被拆成两半）✅
    #     🔴 **为什么**：⭐ `[7]` 的布局是 `bit[5:4]=音色 · bit[3:0]=轴号`
    #        ⇒ ⭐ **轴号只装得下 4 位**（0..15）⇒ ⭐ `axis=255` 现在会被掩成 15 ✅
    #     📌 ⚠️ **这不是功能退化**：⭐ FPGA 侧 `axis` 本来就只有 4 位（0..15）
    #        ⇒ ⭐ 原来"能往返 255"只是**测试写宽了**（⭐ 它测的是一个不存在的取值）✅
    chk("   极值往返（seq/axis/vel）",
        dm["seq"] == 255 and dm["axis"] == 15 and dm["vel"] == 255)
    #  ⭐ 非空洞：⭐ 音色也要能往返（⭐ 用最大值 3）
    mt = parse_frame(build_frame(T_NOTE_ON, axis=7, timbre=3))
    chk("   音色往返（timbre 3 + axis 7）", mt["timbre"] == 3 and mt["axis"] == 7)
    m0 = parse_frame(build_frame(T_NOTE_ON, axis=7, timbre=0))
    chk("   音色 0 时与旧格式逐位一致（向后兼容）",
        m0["timbre"] == 0 and m0["axis"] == 7)
    z = parse_frame(build_frame(T_NOTE_ON))
    # ⚠️ 注意：⭐ `type` 字段**不是 0**（⭐ 它就是 T_NOTE_ON）⇒ ⭐ 要排除它再判
    zfields = {k: v for k, v in z.items() if k != "type"}
    chk("   全 0 时【除 type 外】字段全 0", all(v == 0 for v in zfields.values()),
        "  %s" % zfields)
    chk("   type 仍是 T_NOTE_ON", z["type"] == T_NOTE_ON)

    print("\n[5] ⭐⭐ 反例（非空洞性）：改坏必须被发现")
    bad = bytearray(fr); bad[-1] ^= 0xFF
    chk("   坏校验被识别", frame_checksum(bytes(bad)) != bad[-1])
    # ⭐⭐ 2026-10-01（加固）：⭐ 上面那条**抓不住"校验恒为常数"** ——
    #    🔴 若 `frame_checksum` 恒返回 0，`build_frame` 也会写 0 ⇒
    #    ⚠️ "校验对"与"坏校验被识别"**都会绿** ⇒ 🔴 常数校验**伪装成通过**。
    #    ⭐ 修法：⭐ 直接验"**对每一处单比特翻转都敏感**"（⭐ 常数函数必被抓）。
    _insensitive = 0
    for _pos in range(len(fr) - 1):          # ⚠️ 排除校验字节本身
        for _bit in (0x01, 0x40, 0x80):
            _t = bytearray(fr)
            _t[_pos] ^= _bit
            if frame_checksum(bytes(_t)) == frame_checksum(fr):
                _insensitive += 1
    chk("   校验对每一处单比特翻转都敏感（⭐ 常数校验会被抓）",
        _insensitive == 0, "  不敏感 %d 处" % _insensitive)
    chk("   校验不是常数（⭐ 至少两种取值）",
        len({frame_checksum(fr), frame_checksum(tf)}) == 2)
    bad2 = bytearray(fr); bad2[OFF_TICK] ^= 0x01
    chk("   翻 tick 一位 ⇒ 解出的 tick 确实变了",
        parse_frame(bytes(bad2))["tick"] != 0x0000B000,
        "  变后=0x%X" % parse_frame(bytes(bad2))["tick"])
    chk("   错期望值会被判红（⭐ 非空洞）", parse_frame(fr)["tick"] != 0x12345)

    # ⭐⭐ 关键：⭐ 若把表帧当 14 B 音符帧解 ⇒ ⭐ 一定读错
    #    ⭐ 这条把"长度必须按类型取"这个结论【钉死】
    #    ⚠️ 2026-10-01（加固）：⭐ 旧版这里是"解出来结果不同" ——
    #       🔴 那是**弱断言**：它只说明"会读错"，⭐ 而**不禁止**读错。
    #       ⭐ 现在 `parse_frame` 会**直接拒收** ⇒ ⭐ 断言改成"必须抛错"（⭐ 强得多）。
    chk("   表帧按 14 B 解 ⇒ 被【拒收】（⭐ 长度必须分类型）",
        _raises(parse_frame, bytes(tf[:14])))

    print("\n[5b] v1.1 起播锚点 0x05（tick 快照 + ppqn 复用 [8..11]）")
    ts = build_frame(T_TRANSPORT_START, seq=7, tick=0x0000B000, ppqn=960)
    chk("   长度 14（复用不改变帧长）", len(ts) == 14)
    chk("   校验对", frame_checksum(ts) == ts[-1])
    chk("   [1] = 0x05", ts[1] == 0x05)
    chk("   [3..6] 是 tick（大端）",
        int.from_bytes(ts[3:7], "big") == 0x0000B000)
    chk("   [8..11] 放的是 ppqn，值 = 960",
        int.from_bytes(ts[8:12], "big") == 960)
    chk("   [7] axis 与 [12] vel 被强制填 0（本类型不用）",
        ts[7] == 0 and ts[12] == 0)
    dt2 = parse_frame(ts)
    chk("   解析：type = transport_start", dt2["type"] == T_TRANSPORT_START)
    chk("   解析：tick 往返", dt2["tick"] == 0x0000B000)
    chk("   解析：ppqn 往返 = 960", dt2["ppqn"] == 960)
    chk("   解析：给出的是 ppqn，⛔ 不是 inc（键名就不同）",
        "ppqn" in dt2 and "inc" not in dt2)
    # ppqn = 0 是异常/旧固件 => 必须回退到一个可用值，⛔ 不能让调用方除零
    z0 = parse_frame(build_frame(T_TRANSPORT_START, tick=1, ppqn=0))
    chk("   ppqn = 0 ⇒ 回退到 PPQN_FALLBACK（⛔ 不返回 0 让上层除零）",
        z0["ppqn"] == PPQN_FALLBACK and z0["ppqn"] != 0)
    chk("   ppqn_raw 仍如实报 0（⭐ 回退值是兜底，⛔ 不掩盖原始值）",
        z0["ppqn_raw"] == 0)
    # 非空洞：不带 ppqn 造帧必须抛错（否则会静默造出 ppqn=0 的帧）
    chk("   非空洞：0x05 不给 ppqn ⇒ 造帧必须抛错",
        _raises(build_frame, T_TRANSPORT_START, tick=1))
    # ppqn 与 inc 共用同一段字节 —— 这是协议定的，验一下"改一个另一个也跟着变"
    a = build_frame(T_TRANSPORT_START, tick=1, ppqn=480)
    b2 = build_frame(T_TRANSPORT_START, tick=1, ppqn=960)
    chk("   非空洞：不同 ppqn ⇒ [8..11] 确实不同（⛔ 不是常数）",
        a[8:12] != b2[8:12])
    chk("   音符帧仍用 inc，⛔ 不受影响",
        "inc" in parse_frame(build_frame(T_NOTE_ON, inc=123)) and
        parse_frame(build_frame(T_NOTE_ON, inc=123))["inc"] == 123)

    print("\n[5c] 饱和计数（FPGA 侧纪律：计数必须饱和，⛔ 不回绕）")
    chk("   sat_add 普通相加", sat_add(5, 3) == 8)
    chk("   饱和在 cap 处停住（⛔ 不回绕）", sat_add(0xFFFFFFFF, 1) == 0xFFFFFFFF)
    chk("   不会变成 0（⭐ 回绕会让'丢了 256 次'读成'丢了 0 次'）",
        sat_add(0xFFFFFFFF, 1) != 0)
    chk("   cap 可配", sat_add(250, 10, cap=255) == 255)
    c = Counters()
    chk("   初始全 0", c.good == 0 and c.bad_total() == 0)
    c.bump("good"); c.bump("bad_checksum")
    chk("   bump 生效", c.good == 1 and c.bad_checksum == 1)
    chk("   bad_total 是三类坏帧之和",
        Counters().bump("bad_type").bump("bad_len").bad_total() == 2)
    c2 = Counters()
    c2.good = 0xFFFFFFFF
    c2.bump("good")
    chk("   非空洞：计数到顶后【仍是最大值】，⛔ 不回绕成 0",
        c2.good == 0xFFFFFFFF and c2.good != 0)
    # 反证：如果用普通加法会怎样（把"饱和"和"回绕"的差别摆出来）
    chk("   反证：普通加法在此处会回绕成 0（⭐ 所以必须饱和）",
        ((0xFFFFFFFF + 1) & 0xFFFFFFFF) == 0)

    print("\n[5d] 校验驱动的重同步（⭐ 只在坏帧后用，⛔ 不当作平时的同步手段）")
    # 造一段"垃圾 + 一个完好帧 + 垃圾"，看能不能定位到那个帧
    good = build_frame(T_NOTE_ON, seq=9, tick=0x1234, axis=3, inc=777, vel=50)
    blob = bytes([0x11, 0x22, 0xA5, 0x7F, 0x33]) + good + bytes([0x44, 0x55])
    pos, ftype, flen = find_next_frame(blob, start=0)
    chk("   能在垃圾里定位到正确的帧", pos == 5, "  找到 pos=%s" % pos)
    chk("   类型正确", ftype == T_NOTE_ON)
    chk("   长度正确", flen == 14)
    chk("   定位到的内容确实等于原帧", blob[pos:pos + flen] == good)
    # 非空洞：把帧的校验改坏 => 必须找不到它
    broken = bytearray(blob); broken[5 + 13] ^= 0xFF
    chk("   非空洞：校验坏了就【找不回】它（⛔ 不是见到 0xA5 就认）",
        find_next_frame(bytes(broken), start=0)[0] != 5)
    # 非空洞：载荷里的 0xA5 不能被误认（类型不在白名单 => 跳过）
    decoy = bytes([0xA5, 0x7F]) + bytes(20)
    chk("   非空洞：载荷里巧合的 0xA5 + 非法类型 ⇒ ⛔ 不误认",
        find_next_frame(decoy, start=0)[0] is None)
    chk("   找不到时返回 (None, None, None)",
        find_next_frame(bytes(30), start=0) == (None, None, None))
    # 窗口有界：超出 max_back 就不再扫
    far = bytes(10) + good
    chk("   扫描范围有界：max_back 太小时找不到（⭐ 不是无限扫）",
        find_next_frame(far, start=0, max_back=5)[0] is None)
    chk("   放宽 max_back 就能找到（⭐ 证明上一条是范围限制，不是功能坏）",
        find_next_frame(far, start=0, max_back=40)[0] == 10)
    # 尾巴不够一帧 => 必须返回"没找到"而不是乱猜（调用方会继续攒字节）
    chk("   尾巴不够一帧 ⇒ 返回没找到（⛔ 不猜）",
        find_next_frame(FRAME_HDR.to_bytes(1, "big") + good[:6], start=0)[0] is None)
    # 68 B 表帧也能被重同步找到（长度必须按类型取）
    tgood = build_frame(T_TABLESYNC, items=[1] * TABLESYNC_ITEMS)
    tpos, ttype, tlen = find_next_frame(bytes([0x00, 0x01]) + tgood, start=0)
    chk("   表帧（68 B）也能被重同步找到", tpos == 2 and tlen == 68)
    chk("   非空洞：表帧截断 ⇒ ⛔ 不误认成短帧",
        find_next_frame(bytes([0x00]) + tgood[:20], start=0)[0] is None)

    print("\n[6] ⭐⭐ 加固：不合法的输入必须【抛错拒收】（⛔ 不尽量解）")
    chk("   长度 0 ⇒ 拒收", _raises(parse_frame, b""))
    chk("   长度 1 ⇒ 拒收（⛔ 连类型字节都没有）", _raises(parse_frame, b"\xA5"))
    chk("   帧头错（0x00）⇒ 拒收", _raises(parse_frame, b"\x00" + fr[1:]))
    chk("   未知类型 0x7F ⇒ 拒收（⭐ ⛔ 不按 14 B 瞎解）",
        _raises(parse_frame, bytes([FRAME_HDR, 0x7F]) + bytes(12)))
    chk("   14 B 音符帧补成 68 B ⇒ 拒收（⚠️ 长度不符）",
        _raises(parse_frame, bytes(fr) + bytes(54)))
    chk("   68 B 表帧截成 14 B ⇒ 拒收",
        _raises(parse_frame, bytes(tf[:14])))
    chk("   长度 15（多 1 字节）⇒ 拒收", _raises(parse_frame, bytes(fr) + b"\x00"))
    chk("   合法 14 B 帧【不】抛错", not _raises(parse_frame, fr))
    chk("   合法 68 B 表帧【不】抛错", not _raises(parse_frame, tf))
    # ⭐ 非空洞：⭐ 证明 `_raises` 本身有效（⭐ 用一个【确实不抛】的输入反证）
    chk("   非空洞：_raises 对【正常输入】返回 False", _raises(parse_frame, fr) is False)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(selftest())
