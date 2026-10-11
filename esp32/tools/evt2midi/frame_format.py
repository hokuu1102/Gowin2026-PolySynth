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

═══ ⚠️ 格式状态：草案 ═══
⭐ 依据 `FPGA侧回应-ESP32回函-20261001.md` §三：
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
T_TABLESYNC = 0x10

FRAME_TYPE_NAMES = {
    T_NOTE_ON: "note_on",
    T_NOTE_OFF: "note_off",
    T_CALIB: "calib",
    T_LOOPER: "looper",
    T_TABLESYNC: "tablesync",
}

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
    T_TABLESYNC: 68,
}

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
    ⭐ 帧校验（⭐ 草案建议 XOR）—— ⚠️ 若 FPGA 侧改用累加和，**只改这一处**。

    ⚠️ 对**任意长度**的帧都成立：⭐ 校验字节是**最后一个字节**
    （⭐ 14 B 帧是 `b[13]`，⭐ 68 B 表帧是 `b[67]`）。
    """
    c = 0
    for x in b[:-1]:
        c ^= x
    return c & 0xFF


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
    return {
        "type": ftype,
        "seq": f[OFF_SEQ],
        "tick": int.from_bytes(f[OFF_TICK:OFF_TICK + LEN_TICK], "big"),
        "axis": f[OFF_AXIS],
        "inc": int.from_bytes(f[OFF_INC:OFF_INC + LEN_INC], "big"),
        "vel": f[OFF_VEL],
    }


def build_frame(ftype, seq=0, tick=0, axis=0, inc=0, vel=0,
                table=None, items=None):
    """
    ⭐ 造一个帧（⭐ 给测试/自检用；⭐ 也可当"模拟 FPGA"的发包工具）。

    ⚠️ 表同步帧（`0x10`）走 `table=`/`items=` 参数，⛔ 不用 tick/axis 那套。
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

    f = bytearray(FRAME_LEN_DEFAULT)
    f[0] = FRAME_HDR
    f[1] = ftype & 0xFF
    f[OFF_SEQ] = seq & 0xFF
    f[OFF_TICK:OFF_TICK + LEN_TICK] = (tick & 0xFFFFFFFF).to_bytes(LEN_TICK, "big")
    f[OFF_AXIS] = axis & 0xFF
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
    # ⭐⭐ 2026-10-01（加固）：⭐ 白名单 / 严格长度
    chk("   白名单恰为 5 类", len(KNOWN_TYPES) == 5, "  %s" % sorted(KNOWN_TYPES))
    chk("   0x10 在白名单里", is_known_type(T_TABLESYNC))
    chk("   0x7F ⛔ 不在白名单里", not is_known_type(0x7F))
    chk("   frame_len_known(0x10) = 68", frame_len_known(T_TABLESYNC) == 68)
    chk("   frame_len_known(未知) = None（⭐ ⛔ 不猜）", frame_len_known(0x7F) is None)
    chk("   MAX_FRAME_LEN = 68", MAX_FRAME_LEN == 68)

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
    mx = build_frame(T_NOTE_ON, seq=255, tick=0xFFFFFFFF, axis=255, inc=0xFFFFFFFF, vel=255)
    dm = parse_frame(mx)
    chk("   全 0xFF 往返（tick 32 位）", dm["tick"] == 0xFFFFFFFF)
    chk("   全 0xFF 往返（inc 32 位）", dm["inc"] == 0xFFFFFFFF)
    chk("   全 0xFF 往返（seq/axis/vel）",
        dm["seq"] == 255 and dm["axis"] == 255 and dm["vel"] == 255)
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
