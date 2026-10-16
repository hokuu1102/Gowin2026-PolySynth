#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_drum_split.py —— 鼓与旋律分离：产物 events.hex 的验收判据检查器（ESP32 侧）

判据来源（逐条对应手册，一条都不软化）：
  files/20-代码/ESP32侧修改手册-鼓与旋律分离-最终版-20261016.md
  files/20-代码/FPGA线回函-第三轮-收回8件鼓-20261016.md
  files/20-代码/ESP32侧回函-第三轮-axis确认与回退-20261016.md
    §六 验收判据 / ESP32 侧（第 2、3 条）
    §7.3 上板前的机械检查（第 1、2、3 条）
    §4.1 鼓的 note_off 按 (axis, src) 配对 => 四件鼓必须一件一轴（否则同轴互掐）
    §4.3 GM 音符号 -> drum_type 映射表（表外打击乐归 Tom，并在报告里列出）

2026-10-16 第三轮口径：FPGA 线【收回】上一轮的"扩到 8 件"（他们只有 4 件鼓音色，
那 4 个新 inc 是同一个纯音引擎的高频音高，不是新音色）=> 判据回到 4 件。
（判据只增不减：口径可以改，条数不删。）

  ① drum_type 回到 2 位：drum_type = timbre[8:7]（⛔ 不读 bit19）
       0 Kick    35, 36
       1 Snare   38, 40
       2 HiHat   42, 44 + 【镲族全部】46, 49, 51, 52, 53, 55, 57, 59
       3 Tom     41, 43, 45, 47, 48, 50（+ 表外音高兜底）
  ② 鼓的 axis 回到 12..15（一件一轴，方案 B）：
       kick 12 · snare 13 · hihat 14 · tom 15
       => 硬判据：axis - 12 == drum_type（判据⑦，有鉴别力，配反例）
     ⛔ 上一轮的"dt 键" axis = ((dt & 3) << 1) | (dt >> 2)（0/2/4/6/1/3/5/7）整条作废；
     ⛔ 上一轮的"便宜判据" axis & 1 == drum_type >> 2 也作废（2 位没有高位可对）。
  ③ 镲族必须归 HiHat：46/49/51/52/53/55/57/59 => drum_type = 2
       理由（FPGA 线回函 §1.2）：镲与踩镲都是金属高频，"镲 -> 踩镲"远比"镲 -> 嗵鼓"合理，
       而且 FPGA 侧只有 4 件鼓音色（不造音色凑数）。
       判法：有 events.csv 时【逐条】核（含"这 8 个音高一条都不许落到 Tom"）；
             并静态自检"这 8 个音高在映射表里是【显式列出】的"（⛔ 不靠表外兜底）。
  ④ note_off5 语义（不变）：合法 0..30（对应 MIDI 45..75）；31 = 哨兵（键盘上没有这个键 => 不点灯）
       越界音高（<45 或 >75）【必须】写 31，⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点错灯）
     ⚠️ 口径边界（本文件写死并打印）：哨兵只作用于【旋律】事件（is_drum=0）。
        鼓的 note_off5 仍恒为 0（鼓没有音高；这是判据⑯ 的既有口径，本轮不回退）。
  ⑤ 鼓力度（本轮新增判据⑧）：Kick 230 · Snare 235 · HiHat 175 · Tom 220；鼓的 OFF 写 0。
     （上一轮给"扩到 8 件"新增的四件力度随扩位一起作废。）

位域：本文件独立写死自己的位域表，不 import 任何项目内的常量表，
      也不读别的文件的位域定义 —— 避免"拿别人的表验别人的表"。

用法：
  python esp32/tools/check_drum_split.py --hex <events.hex> [--csv <events.csv>]
  python esp32/tools/check_drum_split.py --mid <x.mid> [--keep-temp]

  逐行一个 64 位十六进制字，兼容 0x 前缀 / 大小写 / 行尾注释。
  --mid 会调 tools/mid2evt.py 先生成临时 hex 再读（本文件不复刻转换逻辑）。

退出码：0 = 八条判据全过；1 = 有 [RED]（含"判据恒真"）
"""

import argparse
import io
import math
import os
import shutil
import subprocess
import sys
import tempfile

# --------------------------------------------------------------------------- #
# 位域（本文件独立写死；来源 = 手册 §二 最终位域）
# --------------------------------------------------------------------------- #
SH_TICK, MASK_TICK = 44, (1 << 20) - 1      # bit 63..44  tick(20)
SH_INC, MASK_INC = 23, (1 << 21) - 1        # bit 43..23  inc(21) 旋律唯一音高来源；鼓写 0
SH_AXIS, MASK_AXIS = 19, 0xF                # bit 22..19  axis(4)
SH_VEL, MASK_VEL = 11, 0xFF                 # bit 18..11  vel(8)
SH_KIND, MASK_KIND = 9, 0x3                 # bit 10..9   kind(2) 0=on 1=off 2=tempo
SH_TIMBRE, MASK_TIMBRE = 7, 0x3             # bit 8..7    timbre(2) 鼓事件：这就是 drum_type
SH_GUIDE, MASK_GUIDE = 6, 0x1               # bit 6       guide_only
SH_IS_DRUM, MASK_IS_DRUM = 5, 0x1           # bit 5       is_drum 显式鼓标志
SH_NO5, MASK_NO5 = 0, 0x1F                  # bit 4..0    note_off5(5)
# ⚠️ 第三轮：bit19 【不再是】"共享位" —— 它只是 axis 字段的 bit0，与 drum_type 无关
#   （上一轮的 3 位读法 {bit19, timbre[8:7]} 已随"扩到 8 件"一起作废）。
#   ⇒ 本文件不再定义 SH_DT_MSB / MASK_DT_MSB；鼓件只从 timbre[8:7] 读。

KIND_ON, KIND_OFF, KIND_TEMPO = 0, 1, 2
BASE_NOTE = 45                              # note_off5 = MIDI - 45（可弹区间 45..75 => 0..30）
MIDI_MIN_PLAY, MIDI_MAX_PLAY = 45, 75       # 键盘上真实存在的键 A2..D#4（+ 上下各留 0.5 死区）
NO5_SENTINEL = 31                           # 哨兵：不可弹（不点灯）；⛔ 不是"钳到边界"
NO5_MAX_PLAY = MIDI_MAX_PLAY - BASE_NOTE    # = 30
INC_SR = 50000000.0                         # inc <-> Hz：hz = inc * 50e6 / 2^32
INC_ONE = float(1 << 32)

DRUM_NAMES = {0: "Kick", 1: "Snare", 2: "HiHat", 3: "Tom"}
DRUM_TYPE_N = 4                             # 件数 = 2 位（timbre[8:7]）
BASE_DRUM_TYPES = (0, 1, 2, 3)
FALLBACK_DRUM_TYPE = 3                      # 表外打击乐 -> Tom（在报告里逐个列出）
DRUM_AXIS_BASE = 12                         # 鼓的 axis = 12 + drum_type（一件一轴）
DRUM_AXIS = dict((dt, DRUM_AXIS_BASE + dt) for dt in range(DRUM_TYPE_N))
DRUM_AXIS_SET = sorted(DRUM_AXIS.values())  # 12..15
AXIS_TXT = " ".join("%d->%d" % (dt, DRUM_AXIS[dt]) for dt in range(DRUM_TYPE_N))
CYMBAL_DRUM_TYPE = 2                        # 镲族一律归 HiHat
# 鼓的力度（生效值 = drum_gen 模块默认 + top.v 的实例化覆盖）：
#   kick 230（未被 top.v 覆盖）· snare 235 · hihat 175 · tom 220
#   ⛔ 上一轮给"扩到 8 件"新增的四件力度（openhat/crash/ride/splash）已随扩位一起删掉。
DRUM_VEL = {0: 230, 1: 235, 2: 175, 3: 220}

GM_TO_DRUM = {                              # 手册 §4.3 / 第三轮回函 §一 的映射（本文件独立抄写）
    35: 0, 36: 0,                           # Kick
    38: 1, 40: 1,                           # Snare
    42: 2, 44: 2,                           # HiHat
    # 镲族：本轮重点 —— 必须【显式列出】指向 HiHat(2)，⛔ 不靠"表外兜底 -> Tom"
    46: 2, 49: 2, 51: 2, 52: 2, 53: 2, 55: 2, 57: 2, 59: 2,
    41: 3, 43: 3, 45: 3, 47: 3, 48: 3, 50: 3,   # Tom
}
CYMBAL_GMS = (46, 49, 51, 52, 53, 55, 57, 59)   # 镲族音高：必须归 HiHat，一个都不许落到 Tom


def drum_type2(word):
    """
    drum_type = timbre[8:7]（2 位：0=Kick 1=Snare 2=HiHat 3=Tom）—— 直接按位取。
    本函数是本文件"读件号"的唯一实现：改位域只会改这里。
    ⛔ 本轮不读 bit19（上一轮的 3 位读法已作废）。
    """
    return (word >> SH_TIMBRE) & MASK_TIMBRE


def midi_of_inc(inc):
    """inc -> MIDI 音高（浮点）。与上位机 check_roll.js 的 midiOfInc 同一口径。"""
    hz = inc * INC_SR / INC_ONE
    if hz <= 0:
        return None
    return 69.0 + 12.0 * math.log(hz / 440.0, 2.0)


def inc_of_midi(m):
    """MIDI 音高 -> inc（取整）。只用于自造基线/坏用例，⛔ 不参与对产物的判定。"""
    hz = 440.0 * (2.0 ** ((m - 69) / 12.0))
    return int(round(hz * INC_ONE / INC_SR))


MAX_EXAMPLES = 5                            # 每类问题最多列几条样例


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def note5_want(midi):
    """midi 在 45..75 => MIDI-45；否则 => 哨兵 31。⛔ 不再钳到 0。"""
    return NO5_SENTINEL if (midi < MIDI_MIN_PLAY or midi > MIDI_MAX_PLAY) else int(round(midi)) - BASE_NOTE


def note5_class(midi):
    """把反推出来的音高分类：play（必须 0..30）/ unplay（必须 31）/ edge（死区，不判）。"""
    if midi < MIDI_MIN_PLAY - 0.5 or midi > MIDI_MAX_PLAY + 0.5:
        return "unplay"
    if MIDI_MIN_PLAY <= midi <= MIDI_MAX_PLAY:
        return "play"
    return "edge"


def unlisted_cymbals(table):
    """镲族里【没有显式列在表里】的音高 —— 它们会走"表外兜底"，正是本轮要禁的事。"""
    return [g for g in CYMBAL_GMS if g not in table]


def wrong_cymbals(table):
    """镲族里列了、但没指向 HiHat 的音高。"""
    return [g for g in CYMBAL_GMS if (g in table) and table[g] != CYMBAL_DRUM_TYPE]


def force_utf8_stdout():
    """
    Windows 上把中文写到管道/文件时，Python 默认用本地代码页(cp936)编码
    => 上层按 UTF-8 读会变乱码。这里显式钉死 UTF-8（控制台本来就是 UTF-8，无副作用）。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


# --------------------------------------------------------------------------- #
# 解析
# --------------------------------------------------------------------------- #
def parse_hex_file(path):
    """读 events.hex，一行一个十六进制字。返回 (words, problems)。"""
    words = []
    problems = []
    with io.open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            s = raw.strip()
            if not s:
                continue
            for mark in ("#", "//", ";"):
                i = s.find(mark)
                if i >= 0:
                    s = s[:i].strip()
            if not s:
                continue
            s = s.replace("_", "").replace(",", "").replace(" ", "").replace("\t", "")
            if s[:2].lower() == "0x":
                s = s[2:]
            if not s or len(s) > 16 or any(c not in "0123456789abcdefABCDEF" for c in s):
                problems.append("第 %d 行不是合法的 64 位十六进制字：%r" % (lineno, raw.strip()))
                continue
            words.append(int(s, 16))
    return words, problems


def decode(word):
    """把一个 64 位字拆成字段。dt = drum_type 两位读取（timbre[8:7]）。"""
    return {
        "raw": word,
        "tick": (word >> SH_TICK) & MASK_TICK,
        "inc": (word >> SH_INC) & MASK_INC,
        "axis": (word >> SH_AXIS) & MASK_AXIS,
        "vel": (word >> SH_VEL) & MASK_VEL,
        "kind": (word >> SH_KIND) & MASK_KIND,
        "timbre": (word >> SH_TIMBRE) & MASK_TIMBRE,
        "dt": drum_type2(word),
        "guide": (word >> SH_GUIDE) & MASK_GUIDE,
        "is_drum": (word >> SH_IS_DRUM) & MASK_IS_DRUM,
        "no5": (word >> SH_NO5) & MASK_NO5,
    }


def decode_all(words):
    evs = []
    for i, w in enumerate(words):
        e = decode(w)
        e["idx"] = i
        e["line"] = i + 1
        evs.append(e)
    return evs


def kind_name(k):
    return {KIND_ON: "on", KIND_OFF: "off", KIND_TEMPO: "tempo"}.get(k, "?%d" % k)


def dt_name(dt):
    return DRUM_NAMES.get(dt, "dt%d" % dt)


def fmt_ev(e):
    return ("第%d行 tick=%d axis=%d kind=%s inc=%d vel=%d is_drum=%d drum_type=%d(%s) note_off5=%d"
            % (e["line"], e["tick"], e["axis"], kind_name(e["kind"]), e["inc"], e["vel"],
               e["is_drum"], e["dt"], dt_name(e["dt"]) if e["is_drum"] else "-", e["no5"]))


def load_csv_midi(csv_path, evs):
    """
    尽力读 events.csv 里的原始音高列（midi），按行序与 hex 对齐。
    对不齐就返回 None —— 宁可不做精确校验，也不拿错位的数据下结论。
    """
    if not csv_path or not os.path.isfile(csv_path):
        return None, "没有 events.csv，无法反查原始音高"
    try:
        with io.open(csv_path, "r", encoding="utf-8-sig", errors="replace") as f:
            lines = [ln.strip() for ln in f if ln.strip()]
    except OSError as exc:
        return None, "events.csv 读不了（%s）" % exc
    if len(lines) < 2:
        return None, "events.csv 是空的"
    header = [h.strip().lower() for h in lines[0].split(",")]
    need = ("tick", "inc", "axis", "midi")
    for col in need:
        if col not in header:
            return None, "events.csv 缺列 %s（表头：%s）" % (col, ",".join(header))
    ci = dict((name, header.index(name)) for name in header)
    vel_col = ci.get("velocity", ci.get("vel"))
    rows = []
    for ln in lines[1:]:
        parts = [p.strip() for p in ln.split(",")]
        if len(parts) < len(header):
            return None, "events.csv 有列数不足的行"
        try:
            rows.append({
                "tick": int(parts[ci["tick"]]),
                "inc": int(parts[ci["inc"]]),
                "axis": int(parts[ci["axis"]]),
                "midi": int(parts[ci["midi"]]),
                "vel": int(parts[vel_col]) if vel_col is not None else None,
            })
        except ValueError:
            return None, "events.csv 有非整数的列"
    if len(rows) != len(evs):
        return None, ("events.csv 有 %d 行、events.hex 有 %d 行，行数不一致 => 不用于精确校验"
                      % (len(rows), len(evs)))
    for r, e in zip(rows, evs):
        if r["tick"] != e["tick"] or r["inc"] != e["inc"] or r["axis"] != e["axis"]:
            return None, "events.csv 与 events.hex 不对齐（tick/inc/axis 三列有差异）=> 不用于精确校验"
        if r["vel"] is not None and r["vel"] != e["vel"]:
            return None, "events.csv 与 events.hex 不对齐（velocity 列有差异）=> 不用于精确校验"
    return dict((e["idx"], r["midi"]) for e, r in zip(evs, rows)), "已用 events.csv 的 midi 列反查原始音高"


# --------------------------------------------------------------------------- #
# 判据容器
# --------------------------------------------------------------------------- #
class Res(object):
    def __init__(self, cid, title):
        self.cid = cid
        self.title = title
        self.reds = []
        self.facts = []
        self.sample_note = ""

    def red(self, msg):
        self.reds.append(msg)

    def fact(self, msg):
        self.facts.append(msg)

    @property
    def ok(self):
        return not self.reds


def examples(evs, n=MAX_EXAMPLES):
    out = "；".join(fmt_ev(e) for e in evs[:n])
    if len(evs) > n:
        out += "；…（共 %d 条）" % len(evs)
    return out


# --------------------------------------------------------------------------- #
# 判据① 鼓与旋律零重叠
# --------------------------------------------------------------------------- #
def crit1(evs, _midi=None):
    r = Res("①", "鼓与旋律零重叠：is_drum=1 的 inc 必须全 0；is_drum=0 且非 tempo 的 inc 必须全非 0")
    drums = [e for e in evs if e["is_drum"] == 1]
    mel = [e for e in evs if e["is_drum"] == 0 and e["kind"] != KIND_TEMPO]
    tempo = [e for e in evs if e["kind"] == KIND_TEMPO]
    r.sample_note = "鼓 %d 条 / 旋律 %d 条 / tempo %d 条（tempo 用 inc 装速度，单独排除）" % (
        len(drums), len(mel), len(tempo))

    if not drums:
        r.red("一条 is_drum=1 都没有 —— 鼓分支空洞，判据①无法成立"
              "（要么产物是旧格式，要么鼓轨被整轨丢掉了）")
    if not mel:
        r.red("一条 is_drum=0 的旋律事件都没有 —— 旋律分支空洞")

    bad = [e for e in drums if e["inc"] != 0]
    if bad:
        r.red("鼓事件 inc 非 0：%d 条 —— 鼓不许带音高，否则 FPGA 会出电子音。%s"
              % (len(bad), examples(bad)))
    bad = [e for e in mel if e["inc"] == 0]
    if bad:
        r.red("旋律事件 inc=0：%d 条 —— 旋律的唯一音高来源就是 inc，写 0 等于没音高。%s"
              % (len(bad), examples(bad)))
    # tempo 必须 is_drum=0，且 timbre[8:7]=0（2 位 drum_type 全 0）
    bad = [e for e in tempo if e["is_drum"] != 0 or e["timbre"] != 0]
    if bad:
        r.red("tempo(kind=2) 事件必须 is_drum=0 且 timbre[8:7]=0（drum_type 区写 0），违规 %d 条。%s"
              % (len(bad), examples(bad)))

    if not r.reds:
        r.fact("鼓 %d 条 inc 全 0；旋律 %d 条 inc 全非 0；tempo %d 条已排除" % (
            len(drums), len(mel), len(tempo)))
    return r


# --------------------------------------------------------------------------- #
# 判据② 鼓的 ON/OFF 配对 + 四件一件一轴（轴落 12..15）
# --------------------------------------------------------------------------- #
def crit2(evs, _midi=None):
    r = Res("②", "鼓的 ON/OFF 配对：每个 (axis, drum_type) 的 kind=0 都要有配对 kind=1，"
                 "OFF 也带 is_drum=1 与同一 drum_type；且四件鼓一件一轴、轴必须落在 12..15")
    drums = [e for e in evs if e["is_drum"] == 1]
    r.sample_note = "鼓事件 %d 条（其中 on %d / off %d）；件与轴 %s；合法轴段 %s" % (
        len(drums),
        sum(1 for e in drums if e["kind"] == KIND_ON),
        sum(1 for e in drums if e["kind"] == KIND_OFF),
        AXIS_TXT, DRUM_AXIS_SET)

    if not drums:
        r.red("一条鼓事件都没有 —— 配对判据空洞（漏带 is_drum 的产物会走到这里）")
        return r

    ons, offs = {}, {}
    for e in drums:
        key = (e["axis"], e["dt"])
        if e["kind"] == KIND_ON:
            ons.setdefault(key, []).append(e)
        elif e["kind"] == KIND_OFF:
            offs.setdefault(key, []).append(e)
        else:
            r.red("鼓事件出现 kind=%s（鼓只允许 0=on / 1=off）。%s" % (kind_name(e["kind"]), fmt_ev(e)))

    # 同一 (axis, drum_type) 上按出现顺序 FIFO 配对
    orphans = []
    for key, on_list in sorted(ons.items()):
        n_off = len(offs.get(key, []))
        for e in on_list[n_off:]:
            orphans.append(e)
    if orphans:
        # 顺手给出"漏带 is_drum"的指纹：同轴同 drum_type 的 is_drum=0 的 OFF
        guess = {}
        for e in evs:
            if e["is_drum"] == 0 and e["kind"] == KIND_OFF:
                guess.setdefault((e["axis"], e["dt"]), []).append(e)
        hints = []
        for e in orphans:
            g = guess.get((e["axis"], e["dt"]))
            if g:
                hints.append("（同轴同 drum_type 存在 is_drum=0 的 off：%s => 该 OFF 大概率漏带 is_drum）"
                             % fmt_ev(g[0]))
        r.red("有 %d 条鼓 ON 没有配对的鼓 OFF（挂音风险：鼓 voice 永久 held，保留池会耗尽）。%s%s"
              % (len(orphans), examples(orphans), "".join(hints[:2])))
    dangling = []
    for key, off_list in sorted(offs.items()):
        n_on = len(ons.get(key, []))
        for e in off_list[n_on:]:
            dangling.append(e)
    if dangling:
        r.fact("另有 %d 条鼓 OFF 找不到对应的鼓 ON（不影响发声，但属于可疑残留）：%s"
               % (len(dangling), examples(dangling, 3)))

    # 一件一轴：四件鼓必须落在互不相同的轴上。
    # 依据：手册 §4.1 / 第三轮回函 §1.4 —— note_manager 的 note_off 按 (axis, src) 配对，
    #       而四件鼓的 src 全都是 SRC_KDRUM；多件共用一条轴 => 一件的 OFF 会把同轴同源
    #       其它件的 voice 一起清掉（同时响的鼓互相掐断 + 保留池语义被破坏）。
    ax_of_dt, dt_of_ax = {}, {}
    for e in drums:
        ax_of_dt.setdefault(e["dt"], set()).add(e["axis"])
        dt_of_ax.setdefault(e["axis"], set()).add(e["dt"])
    multi = dict((dt, sorted(ax)) for dt, ax in ax_of_dt.items() if len(ax) > 1)
    share = dict((ax, sorted(dts)) for ax, dts in dt_of_ax.items() if len(dts) > 1)
    if multi:
        r.red("同一件鼓占了多条轴（轴号与鼓件的对应关系丢了）：%s"
              % "；".join("%s->axis%s" % (dt_name(dt), ax) for dt, ax in sorted(multi.items())))
    if share:
        r.red("多件鼓共用同一条轴：%s —— 鼓的 note_off 按 (axis, src) 配对且 src 全是 SRC_KDRUM，"
              "同轴上任意一件的 OFF 会清掉其它件的 voice（鼓被切碎 / 挂音），必须一件一轴"
              % "；".join("axis%d 上是 %s" % (ax, "/".join(dt_name(dt) for dt in dts))
                          for ax, dts in sorted(share.items())))

    # 鼓轴必须落在 12..15（本轮的轴段）；逐件是否等于 12+dt 由判据⑦ 硬判。
    # ⚠️ 必须比【值集合】DRUM_AXIS_SET（12..15），⛔ 不是比 DRUM_AXIS 这个 dict 的键（0..3）。
    stray = sorted(set(e["axis"] for e in drums if e["axis"] not in DRUM_AXIS_SET))
    if stray:
        r.red("鼓的轴落在合法段 12..15 之外：实际出现 %s —— 本轮的鼓轴是 12/13/14/15（一件一轴）"
              "（判据⑦ 会逐条指出 axis-12 与 drum_type 的差）" % stray)

    if not r.reds:
        r.fact("(axis, drum_type) 组合 %d 个，鼓 ON %d 条全部配对到同键的鼓 OFF；"
               "每条 OFF 都带 is_drum=1 与同一 drum_type"
               % (len(ons), sum(len(v) for v in ons.values())))
        r.fact("一件一轴成立：%s"
               % " ".join("%s->axis%d" % (dt_name(dt), sorted(ax)[0])
                          for dt, ax in sorted(ax_of_dt.items())))
        r.fact("出现的鼓件 %d 件（dt %s）占 %d 条互不相同的轴（上限 4 件）"
               % (len(ax_of_dt), ",".join(str(dt) for dt in sorted(ax_of_dt)), len(dt_of_ax)))
    return r


# --------------------------------------------------------------------------- #
# 判据③ 手册 §7.3 第 1 条：is_drum=0 的事件轴号不许落 12..15（口径回到 12..15）
# --------------------------------------------------------------------------- #
def crit3(evs, _midi=None):
    r = Res("③", "手册 §7.3-1：is_drum=0 的事件里，轴号落在 12..15 的必须是 0 条"
                 "（回到四件时代的 12..15 原始口径）")
    mel_side = [e for e in evs if e["is_drum"] == 0]
    n_tempo = sum(1 for e in mel_side if e["kind"] == KIND_TEMPO)
    drums = [e for e in evs if e["is_drum"] == 1]
    dax = sorted(set(e["axis"] for e in drums))
    r.sample_note = ("is_drum=0 的事件 %d 条（含 tempo %d 条，tempo 也不许走 12..15）；"
                     "鼓实际占轴 %s" % (len(mel_side), n_tempo, dax if dax else "-"))
    if not mel_side:
        r.red("一条 is_drum=0 的事件都没有 —— 判据空洞")
        return r
    bad = [e for e in mel_side if e["axis"] >= DRUM_AXIS_BASE]
    if bad:
        by_axis = {}
        for e in bad:
            by_axis[e["axis"]] = by_axis.get(e["axis"], 0) + 1
        detail = " ".join("axis%d=%d 条" % (a, by_axis[a]) for a in sorted(by_axis))
        r.red("命中 %d 条（%s）—— 轴号 12..15 现在【就是】鼓的轴段，出现在 is_drum=0 的事件里"
              "说明还有依赖轴号的老路径（或者鼓 OFF 漏标了 is_drum）。%s"
              % (len(bad), detail, examples(bad)))
    else:
        r.fact("is_drum=0 的事件轴号全部 ≤ 11，没有一条落在 12..15")
    # 读数：12..15 段被谁占着（本轮鼓就该占满这四条，且只有鼓能占）
    if dax:
        occ = sum(1 for e in evs if e["axis"] >= DRUM_AXIS_BASE)
        n_drum_in = sum(1 for e in drums if e["axis"] >= DRUM_AXIS_BASE)
        r.fact("鼓占轴集合 = %s（合法轴段 %s）；12..15 段共 %d 条事件，其中 is_drum=1 的 %d 条"
               % (dax, DRUM_AXIS_SET, occ, n_drum_in))
    return r


# --------------------------------------------------------------------------- #
# 判据④ drum_type 分布（四件）+ GM 音符号 -> dt 的逐条核对 + 镲族必须归 HiHat
# --------------------------------------------------------------------------- #
def crit4(evs, midi_by_idx=None):
    r = Res("④", "drum_type 分布：四件（Kick/Snare/HiHat/Tom）都必须有；核对 GM 音符号 -> dt 映射；"
                 "镲族（46/49/51/52/53/55/57/59）必须归 HiHat(2)、一条都不许落到 Tom；"
                 "列出走了\"归到 Tom\"兜底的 GM 音符号")
    drums = [e for e in evs if e["is_drum"] == 1]
    r.sample_note = "鼓事件 %d 条；映射表 %s（表外 -> Tom）" % (
        len(drums), " ".join("%d=%s" % (dt, dt_name(dt)) for dt in range(DRUM_TYPE_N)))
    if not drums:
        r.red("一条鼓事件都没有 —— 四件分布全是 0，判据空洞")
        return r

    cnt = {}
    for e in drums:
        cnt[e["dt"]] = cnt.get(e["dt"], 0) + 1
    r.fact("四件分布：" + "  ".join("%s(dt=%d)=%d" % (dt_name(dt), dt, cnt.get(dt, 0))
                                   for dt in range(DRUM_TYPE_N)))
    for dt in BASE_DRUM_TYPES:
        if cnt.get(dt, 0) == 0:
            r.red("缺件：%s(drum_type=%d) 计数为 0 —— §7.3-3 要求四件都有"
                  "（⚠️ 若产物还是【上一轮 8 件口径】，件名会整体错位 —— "
                  "先看判据⑦ 的轴段指纹再判是不是真缺件）" % (dt_name(dt), dt))

    # ---- 镲族必须在映射表里【显式列出】（⛔ 不靠表外兜底 -> Tom） ----
    miss = unlisted_cymbals(GM_TO_DRUM)
    if miss:
        r.red("镲族音高 %s 在本文件的映射表里【没有显式列出】—— 它们会走\"表外 -> Tom\"的兜底，"
              "正是本轮要禁的事（第三轮回函：镲必须归 HiHat(2)）"
              % ",".join(str(g) for g in miss))
    else:
        r.fact("镲族 %d 个音高在映射表里【显式列出】= %s（⛔ 不靠表外兜底）"
               % (len(CYMBAL_GMS), ",".join("%d->%s" % (g, dt_name(GM_TO_DRUM[g])) for g in CYMBAL_GMS)))
    wrong_tab = wrong_cymbals(GM_TO_DRUM)
    if wrong_tab:
        r.red("镲族音高 %s 在映射表里没有指向 HiHat(2) —— 表格本身就错了"
              % ",".join(str(g) for g in wrong_tab))

    if midi_by_idx:
        # 逐条核对：产物里的 dt 必须等于 GM 音高查表的结果
        wrong = []
        for e in drums:
            gm = midi_by_idx.get(e["idx"])
            if gm is None:
                continue
            want = GM_TO_DRUM.get(gm, FALLBACK_DRUM_TYPE)
            if e["dt"] != want:
                wrong.append((e, gm, want))
        if wrong:
            r.red("drum_type 与 GM 音符号对不上：%d 条。%s"
                  % (len(wrong),
                     "；".join("GM%d 应为 %s(%d) 实际 %s(%d)" % (gm, dt_name(w), w,
                                                                dt_name(e["dt"]), e["dt"])
                               for e, gm, w in wrong[:MAX_EXAMPLES])))
        else:
            r.fact("drum_type 与 GM 映射逐条一致（表：35/36->Kick 38/40->Snare 42/44->HiHat "
                   "41/43/45/47/48/50->Tom；镲族 46/49/51/52/53/55/57/59->HiHat；其它->Tom；"
                   "口径：按 events.csv 的 midi 列）")

        # ---- 本轮重点：镲族必须归 HiHat，且一条都不许落到 Tom ----
        cym_hit, cym_to_tom = {}, {}
        for e in drums:
            gm = midi_by_idx.get(e["idx"])
            if gm is None or gm not in CYMBAL_GMS:
                continue
            cym_hit[gm] = cym_hit.get(gm, 0) + 1
            if e["dt"] != CYMBAL_DRUM_TYPE:
                cym_to_tom.setdefault(gm, {})
                cym_to_tom[gm][e["dt"]] = cym_to_tom[gm].get(e["dt"], 0) + 1
        if cym_to_tom:
            detail = []
            for gm in sorted(cym_to_tom):
                for dt in sorted(cym_to_tom[gm]):
                    detail.append("GM%d×%d -> %s(%d)，应为 %s(%d)"
                                  % (gm, cym_to_tom[gm][dt], dt_name(dt), dt,
                                     dt_name(CYMBAL_DRUM_TYPE), CYMBAL_DRUM_TYPE))
            tom_part = [d for d in detail if "-> Tom(3)" in d]
            r.red("镲族音高没有归到 HiHat(2)：%d 种。%s%s"
                  % (len(cym_to_tom), "；".join(detail[:MAX_EXAMPLES]),
                     ("（其中 %d 处是\"镲变嗵鼓\"—— 这正是本判据要抓的现象）" % len(tom_part))
                     if tom_part else ""))
        elif cym_hit:
            r.fact("镲族音高逐条核对：%s 全部归 HiHat(2)，一条都没落到 Tom"
                   % " ".join("GM%d×%d" % (g, cym_hit[g]) for g in sorted(cym_hit)))
        else:
            r.fact("这份产物里【一个镲族音高都没有】（%s）—— "
                   "镲族逐条核对本轮为空跑；映射表本身的显式性与指向已由上面两条静态检查守住"
                   % ",".join(str(g) for g in CYMBAL_GMS))

        # 兜底清单：能拿到音高就按音高判
        fb = {}
        for e in drums:
            gm = midi_by_idx.get(e["idx"])
            if gm is None or gm in GM_TO_DRUM:
                continue
            fb[gm] = fb.get(gm, 0) + 1
        if fb:
            r.fact("走了\"归到 Tom\"兜底的 GM 音符号（共 %d 种）：%s"
                   % (len(fb), " ".join("GM%d×%d" % (g, fb[g]) for g in sorted(fb))))
        else:
            r.fact("没有发现走了\"归到 Tom\"兜底的 GM 音符号（口径：按 events.csv 的 midi 列逐条判）")
        return r

    # 拿不到音高：只能从 inc 反推（旋律）—— 但鼓的 inc 恒 0、note_off5 恒 0（判据⑤-鼓），
    # 两条路都断了 => 明确写清"这一项本轮判不了"，⛔ 不是静默放行。
    r.fact("口径：拿不到原始音高（无 events.csv）。本轮鼓的 inc 恒 0、note_off5 恒 0"
           "（哨兵只作用于旋律），⇒ 无法从产物反推 GM 音高，"
           "\"镲族是否归 HiHat\"与\"归到 Tom 的兜底清单\"本轮【判不了】（需要 events.csv）。"
           "⚠️ 这不是放行：判据②/⑦ 仍会逐条核对 dt <-> axis 的对应。")
    return r


# --------------------------------------------------------------------------- #
# 判据⑤ note_off5（0..30 合法 / 31 哨兵）+ 同一 inc 同一 note_off5
# --------------------------------------------------------------------------- #
def crit5(evs, midi_by_idx=None):
    r = Res("⑤", "note_off5：合法 0..30（MIDI 45..75）；31 = 哨兵（不可弹，不点灯）；"
                 "越界必须写 31（⛔ 不许钳到 0）；同一 inc 必须对应同一 note_off5")
    r.sample_note = ("事件 %d 条（tempo 不参与 note_off5 判定）；"
                     "哨兵 = %d，可弹区间 MIDI %d..%d => note_off5 0..%d"
                     % (len(evs), NO5_SENTINEL, MIDI_MIN_PLAY, MIDI_MAX_PLAY, NO5_MAX_PLAY))

    mel = [e for e in evs if e["kind"] != KIND_TEMPO and e["is_drum"] == 0]
    drm = [e for e in evs if e["kind"] != KIND_TEMPO and e["is_drum"] == 1]
    n_unplay = sum(1 for e in mel if e["no5"] == NO5_SENTINEL)
    r.fact("判为不可弹（note_off5 = %d 哨兵）的旋律事件 = %d 条 / 旋律 %d 条"
           "（诊断价值：直接反映引导轨超出键盘音域 A2..D#4 的量）"
           % (NO5_SENTINEL, n_unplay, len(mel)))

    # 5a 溢出指纹：note_off5 只有 5 位，"写入 >31"在字内唯一可能的形态就是溢出到 bit5(is_drum)
    over = [e for e in evs
            if e["kind"] != KIND_TEMPO and e["inc"] != 0 and (e["raw"] & 0x3F) > NO5_SENTINEL]
    if over:
        r.red("note_off5 取值为 32（超出 5 位字段 0..31，未钳位）：%d 条 —— "
              "它溢出到了 bit5，把 is_drum 一起置 1。%s" % (len(over), examples(over)))
    else:
        r.fact("没有 note_off5 未钳位溢出的指纹（无\"inc 非 0 却 bit5=1\"的事件）")

    # 5b 同一 inc 必须对应同一 note_off5（inc 是音高的纯函数 => note_off5 也是；
    #    ⚠️ 哨兵情形同样受这条约束：同一 inc = 同一音高 => 同一分类 => 同一个值）
    m = {}
    conflict = []
    for e in evs:
        if e["kind"] == KIND_TEMPO or e["inc"] == 0:
            continue
        seen = m.setdefault(e["inc"], {})
        seen[e["no5"]] = seen.get(e["no5"], 0) + 1
    for inc, seen in sorted(m.items()):
        if len(seen) > 1:
            conflict.append((inc, seen))
    if conflict:
        show = "；".join("inc=%d 对应 note_off5 %s" % (inc, sorted(seen)) for inc, seen in conflict[:3])
        r.red("同一个 inc 出现了不同的 note_off5：%d 组 —— 音高与 note_off5 不自洽。%s"
              % (len(conflict), show))
    else:
        r.fact("同一 inc 全部对应同一个 note_off5（%d 个不同 inc）" % len(m))

    # 5c 鼓：没有音高 => note_off5 必须 0（既有口径，本轮不回退；哨兵只作用于旋律）
    bad = [e for e in drm if e["no5"] != 0]
    if bad:
        r.red("鼓事件的 note_off5 非 0：%d 条 —— 鼓没有音高（口径：哨兵只作用于旋律事件；"
              "鼓写 31 会让判据⑯ 与本节互相矛盾）。%s" % (len(bad), examples(bad)))
    else:
        r.fact("鼓事件 %d 条 note_off5 全为 0（口径：哨兵只作用于旋律；若 FPGA 侧要求"
               "\"鼓的越界音高也写 31\"，必须同时改判据⑯ —— 属口径裁定）" % len(drm))

    # 5d 旋律逐条（优先 events.csv 的精确音高；否则按 inc 反推，量化误差 ±1 半音；边界留死区）
    bad_val, bad_sent, bad_sent2, bad_clamp = [], [], [], []
    checked_csv, checked_inc, edge, unknown = 0, 0, 0, 0
    for e in mel:
        gm, src = None, ""
        if midi_by_idx is not None and e["idx"] in midi_by_idx:
            gm, src = float(midi_by_idx[e["idx"]]), "csv"
        elif e["inc"] != 0:
            gm, src = midi_of_inc(e["inc"]), "inc"
        if gm is None:
            unknown += 1
            continue
        cls = note5_class(gm)
        if src == "csv":
            checked_csv += 1
        else:
            checked_inc += 1
        if cls == "edge":
            edge += 1
            continue
        if cls == "unplay":
            if e["no5"] != NO5_SENTINEL:
                bad_sent.append((e, gm, src))
                if e["no5"] == 0:
                    bad_clamp.append((e, gm, src))
        else:
            want = int(round(gm)) - BASE_NOTE
            if e["no5"] == NO5_SENTINEL:
                bad_sent2.append((e, gm, want, src))
            elif abs(e["no5"] - want) > (0 if src == "csv" else 1):
                bad_val.append((e, gm, want, src))

    if bad_sent:
        r.red("越界音高（< %d 或 > %d）没有写哨兵 %d：%d 条。%s"
              % (MIDI_MIN_PLAY, MIDI_MAX_PLAY, NO5_SENTINEL, len(bad_sent),
                 "；".join("%s 反推音高 %.1f（%s）却写了 %d"
                           % (fmt_ev(e), gm, src, e["no5"]) for e, gm, src in bad_sent[:MAX_EXAMPLES])))
    if bad_clamp:
        r.red("其中 %d 条写的是 0 —— 这是【钳位回潮】的指纹：0 = A2 = 真实的键 5，会点亮错误的灯"
              "（手册/回函原话：越界不许钳到 0）。%s"
              % (len(bad_clamp),
                 "；".join("%s 反推音高 %.1f" % (fmt_ev(e), gm) for e, gm, _s in bad_clamp[:MAX_EXAMPLES])))
    if bad_sent2:
        r.red("可弹音高却写了哨兵 %d：%d 条 —— 哨兵必须只出现在\"原始音高 < %d 或 > %d\"的事件上。%s"
              % (NO5_SENTINEL, len(bad_sent2), MIDI_MIN_PLAY, MIDI_MAX_PLAY,
                 "；".join("%s 反推音高 %.1f（应为 note_off5=%d）"
                           % (fmt_ev(e), gm, want) for e, gm, want, _s in bad_sent2[:MAX_EXAMPLES])))
    if bad_val:
        r.red("note_off5 与音高对不上：%d 条（口径：MIDI-45；inc 反推时允许 ±1 半音量化误差）。%s"
              % (len(bad_val),
                 "；".join("%s 反推音高 %.1f 应收 %d（%s）"
                           % (fmt_ev(e), gm, want, src) for e, gm, want, src in bad_val[:MAX_EXAMPLES])))

    if not (bad_sent or bad_sent2 or bad_val or bad_clamp):
        if midi_by_idx:
            r.fact("能用 events.csv 原始音高反查的 %d 条旋律事件，note_off5 全部符合新口径"
                   "（45..75 => MIDI-45；越界 => 哨兵 %d）" % (checked_csv, NO5_SENTINEL))
        r.fact("按 inc 反推音高核对的旋律事件 %d 条（量化误差 ±1 半音）：全部符合新口径；"
               "边界死区（音高落在 %d±0.5 / %d±0.5）跳过 %d 条；inc=0 无法反推 %d 条"
               % (checked_inc, MIDI_MIN_PLAY, MIDI_MAX_PLAY, edge, unknown))
        r.fact("越界音高写哨兵（不点灯）的条数 = %d；哨兵误用（可弹却写 31）= 0；"
               "钳位回潮（越界写 0）= 0" % len([1 for e in mel if e["no5"] == NO5_SENTINEL]))
    return r


# --------------------------------------------------------------------------- #
# 判据⑦（本轮的核心硬判据）鼓轴 = 12 + drum_type
# --------------------------------------------------------------------------- #
def crit7(evs, _midi=None):
    r = Res("⑦", "鼓轴硬判据：axis - 12 == drum_type（一件一轴：kick 12 · snare 13 · "
                 "hihat 14 · tom 15）；鼓轴必须落 12..15")
    drums = [e for e in evs if e["is_drum"] == 1]
    r.sample_note = "鼓事件 %d 条；件与轴 %s" % (len(drums), AXIS_TXT)
    if not drums:
        r.red("一条鼓事件都没有 —— 判据空洞")
        return r

    bad = [e for e in drums if e["axis"] != DRUM_AXIS[e["dt"]]]
    if bad:
        stray = sorted(set(e["axis"] for e in bad))
        pairs = sorted(set((e["dt"], e["axis"]) for e in bad))
        if all(a < DRUM_AXIS_BASE for a in stray):
            fp = ("=> 指纹：全部 <12 —— 这是【上一轮 8 件口径】的产物"
                  "（鼓轴 = dt 键 0/2/4/6/1/3/5/7），待按 4 件重新产出")
        elif all(8 <= a < DRUM_AXIS_BASE for a in stray):
            fp = "=> 指纹：落在 8..11 —— 更早的\"8..15 一件一轴\"写法"
        else:
            fp = "=> 需要口径裁定（既不是 12+dt，也不是已知的两套旧写法）"
        r.red("鼓的 axis - 12 != drum_type：%d 条。逐件期望 %s；实际出现的 (drum_type, axis) = %s。%s。%s"
              % (len(bad), AXIS_TXT,
                 " ".join("dt%d->axis%d" % (dt, ax) for dt, ax in pairs), fp, examples(bad)))
    else:
        r.fact("每条鼓事件都满足 axis - 12 == drum_type：%s" % AXIS_TXT)
        r.fact("逐件读数：" + " ".join("%s axis%d" % (dt_name(dt), DRUM_AXIS[dt])
                                      for dt in range(DRUM_TYPE_N)))

    # 读数：axis-12 的分布（把"轴段对不对"摆出来，便于与旧口径对比）
    hist = {}
    for e in drums:
        k = e["axis"] - DRUM_AXIS_BASE
        hist[k] = hist.get(k, 0) + 1
    r.fact("axis-12 读数分布：%s（合法时每个键都该 == 该事件的 drum_type）"
           % " ".join("axis-12=%d×%d" % (k, hist[k]) for k in sorted(hist)))
    # ⛔ 上一轮的"便宜判据"axis & 1 == drum_type >> 2 已删除：
    #   2 位的 drum_type 没有高位可对，那条式子在本轮【恒真且无意义】。
    r.fact("⛔ 已删除上一轮的 dt 键（((dt&3)<<1)|(dt>>2)）与\"axis&1 == dt>>2\"："
           "本轮 drum_type 只有 2 位（timbre[8:7]），bit19 只是 axis 的 bit0、与件号无关")
    return r


# --------------------------------------------------------------------------- #
# 判据⑧（本轮新增）鼓力度：件定值 + OFF 写 0
# --------------------------------------------------------------------------- #
def crit8(evs, _midi=None):
    r = Res("⑧", "鼓力度：ON 必须等于该件的定值（%s），鼓的 OFF 写 0"
                 % " ".join("%s %d" % (dt_name(dt), DRUM_VEL[dt]) for dt in range(DRUM_TYPE_N)))
    drums = [e for e in evs if e["is_drum"] == 1]
    r.sample_note = ("鼓事件 %d 条（on %d / off %d）；口径：生效值 = drum_gen 默认 + top.v 覆盖"
                     % (len(drums), sum(1 for e in drums if e["kind"] == KIND_ON),
                        sum(1 for e in drums if e["kind"] == KIND_OFF)))
    if not drums:
        r.red("一条鼓事件都没有 —— 力度判据空洞")
        return r

    bad_on = [e for e in drums if e["kind"] == KIND_ON and e["vel"] != DRUM_VEL[e["dt"]]]
    bad_off = [e for e in drums if e["kind"] == KIND_OFF and e["vel"] != 0]
    if bad_on:
        r.red("鼓 ON 的力度不等于该件的定值：%d 条。%s（口径：%s）"
              % (len(bad_on),
                 "；".join("%s 力度 %d，应为 %d" % (dt_name(e["dt"]), e["vel"], DRUM_VEL[e["dt"]])
                           for e in bad_on[:MAX_EXAMPLES]),
                 " ".join("%s %d" % (dt_name(dt), DRUM_VEL[dt]) for dt in range(DRUM_TYPE_N))))
    if bad_off:
        r.red("鼓 OFF 的力度非 0：%d 条（口径：OFF 写 0）。%s"
              % (len(bad_off), examples(bad_off[:MAX_EXAMPLES])))
    if not (bad_on or bad_off):
        seen = {}
        for e in drums:
            if e["kind"] == KIND_ON:
                seen.setdefault(e["dt"], set()).add(e["vel"])
        r.fact("逐件力度读数：" + " ".join("%s=%s（定值 %d）"
                                          % (dt_name(dt), sorted(seen.get(dt, [])) or "-", DRUM_VEL[dt])
                                          for dt in range(DRUM_TYPE_N)))
        r.fact("鼓 OFF 共 %d 条力度全 0" % sum(1 for e in drums if e["kind"] == KIND_OFF))
    # 旋律力度只作报告（真实力度不可由产物单独判定，需 events.csv）
    mel_ons = [e for e in evs if e["is_drum"] == 0 and e["kind"] == KIND_ON]
    mel_offs = [e for e in evs if e["is_drum"] == 0 and e["kind"] == KIND_OFF]
    if mel_ons:
        vs = sorted(set(e["vel"] for e in mel_ons))
        n_zero_off = sum(1 for e in mel_offs if e["vel"] == 0)
        r.fact("（报告）旋律 ON 力度取值 %s%s；旋律 OFF %d 条中力度为 0 的 %d 条"
               % (vs[:8], "…（共 %d 种）" % len(vs) if len(vs) > 8 else "", len(mel_offs), n_zero_off))
    return r


# --------------------------------------------------------------------------- #
# 判据⑥ 非空洞 + 反向证伪（自造坏 hex，证明①~⑤⑦⑧ 都能变红）
# --------------------------------------------------------------------------- #
def mk(tick, inc, axis, vel, kind, dt=0, guide=0, is_drum=0, no5=0):
    """装字。dt 写进 timbre[8:7]（2 位）；bit19 属于 axis，与件号无关。"""
    return (((tick & MASK_TICK) << SH_TICK)
            | ((inc & MASK_INC) << SH_INC)
            | ((axis & MASK_AXIS) << SH_AXIS)
            | ((vel & MASK_VEL) << SH_VEL)
            | ((kind & MASK_KIND) << SH_KIND)
            | ((dt & MASK_TIMBRE) << SH_TIMBRE)
            | ((guide & MASK_GUIDE) << SH_GUIDE)
            | ((is_drum & MASK_IS_DRUM) << SH_IS_DRUM)
            | (no5 & MASK_NO5))


def baseline_words():
    """
    自造一份【合法的】小谱：四件鼓各一对 ON/OFF（一件一轴 = 12/13/14/15，力度 = 件定值，
    OFF 力度 0），旋律两条（音高 60 / 67，落在可弹区间 => note_off5 = 15 / 22），tempo 一条。
    ⚠️ 旋律的 inc 必须用 inc_of_midi() 真算出来 —— 乱填会与判据⑤ 的音高反推对不上。
    """
    w = []
    for dt in BASE_DRUM_TYPES:
        ax = DRUM_AXIS[dt]
        w.append(mk(0, 0, ax, DRUM_VEL[dt], KIND_ON, dt, is_drum=1, no5=0))
        w.append(mk(240, 0, ax, 0, KIND_OFF, dt, is_drum=1, no5=0))
    for midi in (60, 67):
        inc = inc_of_midi(midi)
        no5 = midi - BASE_NOTE
        w.append(mk(0, inc, 0, 96, KIND_ON, 0, is_drum=0, no5=no5))
        w.append(mk(480, inc, 0, 0, KIND_OFF, 0, is_drum=0, no5=no5))
    w.append(mk(0, 54321, 0, 0, KIND_TEMPO, 0, is_drum=0, no5=0))
    return w


def _replace(words, idx, new_word):
    out = list(words)
    out[idx] = new_word
    return out


def cymbal_words():
    """
    自造一份【含镲族音高】的合法小谱 + 对应的 midi 反查表（判据④ 的镲族逐条核对要用）。
    返 回 (words, midi_by_idx)：8 个镲族音高各一对 ON/OFF，件号 = HiHat(2)、轴 = 14。
    ⚠️ 这是"产物侧"的构造：midi_by_idx 模拟 events.csv 的 midi 列，让判据④ 能按音高判。
    """
    words = list(baseline_words())
    midi = {}
    for i, gm in enumerate(CYMBAL_GMS):
        base = len(words)
        midi[base] = gm
        midi[base + 1] = gm
        words.append(mk(960 + i * 480, 0, DRUM_AXIS[CYMBAL_DRUM_TYPE], DRUM_VEL[CYMBAL_DRUM_TYPE],
                        KIND_ON, CYMBAL_DRUM_TYPE, is_drum=1, no5=0))
        words.append(mk(960 + i * 480 + 240, 0, DRUM_AXIS[CYMBAL_DRUM_TYPE], 0,
                        KIND_OFF, CYMBAL_DRUM_TYPE, is_drum=1, no5=0))
    return words, midi


def bad_cases():
    """返回 [(用例名, 期望变红的判据号, 生成坏 hex 的函数), ...]"""
    base = baseline_words()
    # 下标：0..7 是鼓（Kick on/off, Snare on/off, HiHat on/off, Tom on/off），8..11 旋律，12 tempo
    # 旋律两条的音高 = 60（下标 8/9）、67（下标 10/11）
    # 鼓轴（新口径）：kick 12 · snare 13 · hihat 14 · tom 15

    def b1():   # 鼓 OFF 漏带 is_drum（连带 drum_type 一起丢）
        e = decode(base[1])
        return _replace(base, 1, mk(e["tick"], e["inc"], e["axis"], e["vel"],
                                    KIND_OFF, 0, is_drum=0, no5=e["no5"]))

    def b2():   # 旋律 inc = 0
        e = decode(base[8])
        return _replace(base, 8, mk(e["tick"], 0, e["axis"], e["vel"],
                                    KIND_ON, 0, is_drum=0, no5=e["no5"]))

    def b3():   # 鼓 inc 非 0
        e = decode(base[0])
        return _replace(base, 0, mk(e["tick"], 100000, e["axis"], e["vel"],
                                    KIND_ON, e["dt"], is_drum=1, no5=e["no5"]))

    def b4():   # 旋律轴号落 12..15（鼓的轴段）
        e = decode(base[8])
        return _replace(base, 8, mk(e["tick"], e["inc"], 12, e["vel"],
                                    KIND_ON, 0, is_drum=0, no5=e["no5"]))

    def b5():   # note_off5 = 32（未钳位，溢出到 bit5）
        raw = (base[8] & ~0x3F) | 32
        return _replace(base, 8, raw)

    def b6():   # 缺 HiHat（dt=2 计数 0）
        return base[:4] + base[6:]

    def b7():   # 同一 inc 出现两个不同 note_off5
        e = decode(base[9])
        return _replace(base, 9, mk(e["tick"], e["inc"], e["axis"], e["vel"],
                                    KIND_OFF, 0, is_drum=0, no5=7))

    def b8():   # 四件鼓共用同一条轴（件与轴的对应关系丢失）
        out = list(base)
        for i in range(0, 8):
            e = decode(base[i])
            out[i] = mk(e["tick"], e["inc"], 12, e["vel"], e["kind"], e["dt"],
                        is_drum=1, no5=e["no5"])
        return out

    def b9():   # 鼓轴写成上一轮的 dt 键（kick dt=0 落在 axis=0）
        out = list(base)
        for i in (0, 1):
            e = decode(base[i])
            out[i] = mk(e["tick"], e["inc"], 0, e["vel"], e["kind"], e["dt"],
                        is_drum=1, no5=e["no5"])
        return out

    def b10():  # 越界音高（MIDI 40）却把 note_off5 钳到 0（钳位回潮）
        e = decode(base[9])
        return _replace(base, 9, mk(e["tick"], inc_of_midi(40), e["axis"], e["vel"],
                                    KIND_OFF, 0, is_drum=0, no5=0))

    def b11():  # 可弹音高（MIDI 60）却写了哨兵 31
        e = decode(base[9])
        return _replace(base, 9, mk(e["tick"], e["inc"], e["axis"], e["vel"],
                                    KIND_OFF, 0, is_drum=0, no5=NO5_SENTINEL))

    def b12():  # 鼓轴写成"8+dt"（更早的 8..15 写法：kick dt=0 落在 axis=8）
        out = list(base)
        for i in (0, 1):
            e = decode(base[i])
            out[i] = mk(e["tick"], e["inc"], 8, e["vel"], e["kind"], e["dt"],
                        is_drum=1, no5=e["no5"])
        return out

    def b13():  # 两件鼓的轴互换（snare 落 15、tom 落 13）：轴互不相同，但都不等于 12+dt
        out = list(base)
        for i, ax in ((2, 15), (3, 15), (6, 13), (7, 13)):
            e = decode(base[i])
            out[i] = mk(e["tick"], e["inc"], ax, e["vel"], e["kind"], e["dt"],
                        is_drum=1, no5=e["no5"])
        return out

    def b14():  # 鼓 ON 力度写错（Kick 230 -> 200）
        e = decode(base[0])
        return _replace(base, 0, mk(e["tick"], e["inc"], e["axis"], 200,
                                    KIND_ON, e["dt"], is_drum=1, no5=e["no5"]))

    def b15():  # 鼓 OFF 力度非 0
        e = decode(base[1])
        return _replace(base, 1, mk(e["tick"], e["inc"], e["axis"], 230,
                                    KIND_OFF, e["dt"], is_drum=1, no5=e["no5"]))

    def b16():  # HiHat 用了 Kick 的力度（230，应为 175）—— 跨件串味
        e = decode(base[4])
        return _replace(base, 4, mk(e["tick"], e["inc"], e["axis"], DRUM_VEL[0],
                                    KIND_ON, e["dt"], is_drum=1, no5=e["no5"]))

    return [
        ("B1 鼓 OFF 漏带 is_drum", "②", b1),
        ("B2 旋律 inc=0", "①", b2),
        ("B3 鼓 inc 非 0", "①", b3),
        ("B4 旋律轴号落 12..15", "③", b4),
        ("B5 note_off5=32 未钳位", "⑤", b5),
        ("B6 缺 HiHat（drum_type=2 计数 0）", "④", b6),
        ("B7 同一 inc 两个 note_off5", "⑤", b7),
        ("B8 四件鼓共用一条轴（都落 12）", "②", b8),
        ("B9 鼓轴写成上一轮的 dt 键（kick 落 0）", "⑦", b9),
        ("B10 越界音高钳到 0（钳位回潮）", "⑤", b10),
        ("B11 可弹音高误写哨兵 31", "⑤", b11),
        ("B12 鼓轴写成 8+dt（kick 落 8）", "⑦", b12),
        ("B13 两件鼓的轴互换（snare 落 15 / tom 落 13）", "⑦", b13),
        ("B14 鼓 ON 力度写错（kick 230 -> 200）", "⑧", b14),
        ("B15 鼓 OFF 力度非 0", "⑧", b15),
        ("B16 HiHat 用了 Kick 的力度 230（应为 175）", "⑧", b16),
    ]


def cymbal_cases():
    """
    镲族专项反证（本轮重点）：喂【带 events.csv 音高】的产物，判据④ 必须变红。
    返回 [(用例名, 期望判据号, words, midi_by_idx, 说明), ...]
    """
    good, midi = cymbal_words()
    out = []

    # 正控：8 个镲族全部归 HiHat(2) —— 必须全绿（证明这条判据不会误伤正确产物）
    out.append(("C0 正控：8 个镲族音高全部归 HiHat(2)", None, good, midi,
                "正控（要求全绿）"))

    # 反控 A：一个镲族音高（51 Ride）落到 Tom(3) —— "镲变嗵鼓"
    a = list(good)
    midi_a = dict(midi)
    for i, w in enumerate(a):
        if midi_a.get(i) == 51:
            e = decode(w)
            a[i] = mk(e["tick"], e["inc"], DRUM_AXIS[3], e["vel"], e["kind"], 3,
                      is_drum=1, no5=e["no5"])
    out.append(("C1 镲族 GM51 落到 Tom(3)（镲变嗵鼓）", "④", a, midi_a, ""))

    # 反控 B：一个镲族音高（46 OpenHat）落到 Snare(1)
    b = list(good)
    midi_b = dict(midi)
    for i, w in enumerate(b):
        if midi_b.get(i) == 46:
            e = decode(w)
            b[i] = mk(e["tick"], e["inc"], DRUM_AXIS[1], e["vel"], e["kind"], 1,
                      is_drum=1, no5=e["no5"])
    out.append(("C2 镲族 GM46 落到 Snare(1)", "④", b, midi_b, ""))

    # 反控 C：件号对（HiHat）但轴写成 15 —— 判据⑦ 必须红
    c = list(good)
    midi_c = dict(midi)
    for i, w in enumerate(c):
        if midi_c.get(i) == 55:
            e = decode(w)
            c[i] = mk(e["tick"], e["inc"], 15, e["vel"], e["kind"], CYMBAL_DRUM_TYPE,
                      is_drum=1, no5=e["no5"])
    out.append(("C3 镲族归了 HiHat 但轴写成 15（axis-12 != dt）", "⑦", c, midi_c, ""))
    return out


CRIT_FUNCS = (
    ("①", crit1),
    ("②", crit2),
    ("③", crit3),
    ("④", crit4),
    ("⑤", crit5),
    ("⑦", crit7),
    ("⑧", crit8),
)
ALL_CRIT_IDS = ("①", "②", "③", "④", "⑤", "⑦", "⑧")


def crit6(evs, selftest, midi_by_idx=None):
    r = Res("⑥", "非空洞 + 反向证伪：自造坏 hex，①~⑤⑦⑧ 每条都必须因对应的坏输入变红"
                 "（含本轮新增的镲族归 HiHat 与 axis-12==dt）")
    drums = [e for e in evs if e["is_drum"] == 1]
    mel = [e for e in evs if e["is_drum"] == 0 and e["kind"] != KIND_TEMPO]
    r.sample_note = ("被测产物：事件 %d 条 / 鼓 %d 条 / 旋律 %d 条；"
                     "坏用例 %d 份（含镲族专项 %d 份）"
                     % (len(evs), len(drums), len(mel), len(selftest["cases"]),
                        selftest.get("n_cymbal", 0)))

    if not evs:
        r.red("被测产物一条事件都没有 —— 判据空洞")
    if not drums:
        r.red("被测产物一条 is_drum=1 都没有 —— 鼓侧判据全部空洞")
    if not mel:
        r.red("被测产物一条 is_drum=0 的旋律事件都没有 —— 旋律侧判据全部空洞")
    if not midi_by_idx:
        r.fact("⚠️ 本次没有 events.csv：判据④ 的\"镲族是否归 HiHat\"在【被测产物】上判不了"
               "（但下面的镲族专项反证用的是自造产物 + 自造音高表，判据本身的鉴别力照样被证明）")

    for name, want, got in selftest["cases"]:
        if want is None:                       # 正控：要求全绿
            if got:
                r.red("正控「%s」竟然变红（%s）—— 这条判据会误伤正确产物" % (name, "/".join(got)))
            else:
                r.fact("正控「%s」-> 全绿（符合预期）" % name)
            continue
        if want not in got:
            r.red("坏用例「%s」没有让判据%s 变红（实际变红：%s）—— 证伪失败"
                  % (name, want, "/".join(got) if got else "无"))
        else:
            r.fact("坏用例「%s」-> 判据%s 变红%s"
                   % (name, want, ("（同时 %s 也变红）" % "/".join(x for x in got if x != want))
                      if len(got) > 1 else ""))
    for f in selftest.get("extra_facts", []):
        r.fact(f)
    for m in selftest.get("extra_reds", []):
        r.red(m)
    never = [cid for cid in ALL_CRIT_IDS if selftest["red_count"].get(cid, 0) == 0]
    if never:
        r.red("判据恒真：%s 在任何坏输入下都不变红 —— 这条判据没有鉴别力，必须重写"
              % "/".join(never))
    else:
        r.fact("%s 每一条都至少被一份坏输入证伪过（无恒真判据）" % "/".join(ALL_CRIT_IDS))
    return r


def _run_crit_set(words, midi_map=None):
    """对一份字表跑一遍全部判据，返回变红的判据号列表（正控与反控走【同一份代码】）。"""
    evs = decode_all(words)
    reds = []
    for cid, fn in CRIT_FUNCS:
        res = fn(evs, midi_map)
        if not res.ok:
            reds.append(cid)
    return reds


def run_selftest():
    """对自造坏 hex 跑一遍全部判据，统计谁能变红。"""
    cases = []
    red_count = {}
    for name, want, builder in bad_cases():
        reds = _run_crit_set(builder())
        for cid in reds:
            red_count[cid] = red_count.get(cid, 0) + 1
        cases.append((name, want, reds))
    # 镲族专项（带自造音高表）：正控 + 三条反控
    cym = cymbal_cases()
    for name, want, words, midi_map, _note in cym:
        reds = _run_crit_set(words, midi_map)
        for cid in reds:
            red_count[cid] = red_count.get(cid, 0) + 1
        cases.append((name, want, reds))
    # 基线自检：合法小谱必须全绿，否则是判据本身写错（或基线写错）
    baseline = baseline_words()
    base_reds = []
    for cid, fn in CRIT_FUNCS:
        res = fn(decode_all(baseline), None)
        if not res.ok:
            base_reds.append("%s:%s" % (cid, res.reds[0]))
    # 映射表静态自检（"镲族必须显式列出"这条判据的机械证伪：
    #   喂一张"只有基础四件、镲族靠兜底"的表，检查器必须认出来）
    extra_facts, extra_reds = [], []
    fake_table = dict((gm, dt) for gm, dt in GM_TO_DRUM.items()
                      if gm not in CYMBAL_GMS)
    miss = unlisted_cymbals(fake_table)
    if len(miss) != len(CYMBAL_GMS):
        extra_reds.append("映射表自检失效：把镲族从表里拿掉后，unlisted_cymbals() 只认出 %d/%d 个"
                          % (len(miss), len(CYMBAL_GMS)))
    else:
        extra_facts.append("映射表自检：把镲族从表里拿掉（模拟\"靠表外兜底\"）"
                           "-> unlisted_cymbals() 认出全部 %d 个（符合预期）" % len(miss))
    fake_wrong = dict(GM_TO_DRUM)
    fake_wrong[51] = FALLBACK_DRUM_TYPE
    w = wrong_cymbals(fake_wrong)
    if w != [51]:
        extra_reds.append("映射表自检失效：把 GM51 改成 Tom 后 wrong_cymbals() 报 %s（应只报 [51]）" % w)
    else:
        extra_facts.append("映射表自检：把 GM51 改成 Tom -> wrong_cymbals() 报出 [51]（符合预期）")
    return {"cases": cases, "red_count": red_count, "baseline_reds": base_reds,
            "extra_facts": extra_facts, "extra_reds": extra_reds, "n_cymbal": len(cym)}


# --------------------------------------------------------------------------- #
# 产物口径识别
# --------------------------------------------------------------------------- #
def detect_format(evs):
    """判产物是哪一代：旧格式（无 is_drum）/ 上一轮 8 件口径（鼓轴 = dt 键 <12）/ 本轮 4 件口径。"""
    n_drum = sum(1 for e in evs if e["is_drum"] == 1)
    n_ax12 = sum(1 for e in evs if e["is_drum"] == 0 and e["axis"] >= DRUM_AXIS_BASE)
    if n_drum == 0 and n_ax12 > 0:
        return "旧格式（bit5 全 0，鼓靠轴号 12..15 判定）", True
    if n_drum == 0:
        return "无鼓事件（bit5 全 0 且没有轴号 12..15）", True
    low = [e for e in evs if e["is_drum"] == 1 and e["axis"] < DRUM_AXIS_BASE]
    if low:
        return ("鼓与旋律已分离，但鼓轴还是【上一轮 8 件口径】的 dt 键"
                "（鼓轴 <12，共 %d 条 => 待按 4 件重新产出）" % len(low)), True
    return "本轮 4 件口径（is_drum + timbre[8:7] 的 drum_type + 轴 12..15）", False


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def run_mid2evt(mid_path, tmpdir):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    tool = os.path.join(repo, "tools", "mid2evt.py")
    if not os.path.isfile(tool):
        return None, "找不到转换工具：%s" % tool
    cmd = [sys.executable, tool, mid_path, "--outdir", tmpdir]
    print("  [mid2evt] %s" % " ".join(cmd))
    try:
        # 注意（2026-10-16 实测崩过）：mid2evt 的 stdout 里混着 GBK 字节
        #   （Windows 控制台默认编码），本进程按 UTF-8 解码 => UnicodeDecodeError
        #   （byte 0xb2 直接抛异常，--mid 整条通路跑不起来）。
        # 两手抓：1) 给子进程 PYTHONIOENCODING=utf-8（治根，让它自己就输出 UTF-8）
        #         2) 解码时显式 encoding + errors=replace（不因子进程输出的编码而崩）
        # ⚠️ 这两手是上一轮实测修好的，本轮【保留】，⛔ 不许回退掉。
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        proc = subprocess.run(cmd, cwd=repo, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True,
                              encoding="utf-8", errors="replace", env=env)
    except OSError as exc:
        return None, "调用 mid2evt.py 失败：%s" % exc
    for ln in (proc.stdout or "").splitlines():
        print("  [mid2evt] %s" % ln)
    hex_path = os.path.join(tmpdir, "events.hex")
    if proc.returncode != 0 or not os.path.isfile(hex_path):
        return None, "mid2evt.py 没有产出 events.hex（退出码 %d）" % proc.returncode
    return hex_path, "由 mid2evt.py 现场转出（临时目录 %s）" % tmpdir


def main(argv=None):
    force_utf8_stdout()
    ap = argparse.ArgumentParser(
        description="鼓/旋律分离判据检查器（手册 §六 / §7.3，位域本文件独立写死）")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--hex", help="events.hex（一行一个 64 位十六进制字）")
    src.add_argument("--mid", help=".mid 文件：先调 tools/mid2evt.py 转临时 hex 再读")
    ap.add_argument("--csv", default=None, help="events.csv（可选，用于反查原始音高做精确校验）")
    ap.add_argument("--keep-temp", action="store_true", help="--mid 模式下保留临时目录")
    args = ap.parse_args(argv)

    print("=" * 78)
    print("check_drum_split.py —— 鼓与旋律分离判据检查（手册 §六 / §7.3；2026-10-16 第三轮：4 件）")
    print("=" * 78)

    tmpdir = None
    if args.mid:
        tmpdir = tempfile.mkdtemp(prefix="check_drum_split_")
        print("输入：%s（--mid）" % args.mid)
        hex_path, note = run_mid2evt(args.mid, tmpdir)
        print("来源：%s" % note)
        if not hex_path:
            print("[RED] 无法取得 events.hex：%s" % note)
            print("结论：输入不可用，无法判定（有 RED）。")
            return 1
    else:
        hex_path = args.hex
        print("输入：%s（--hex）" % hex_path)
        print("来源：直接读取")

    if not os.path.isfile(hex_path):
        print("[RED] 文件不存在：%s" % hex_path)
        print("结论：输入不可用，无法判定（有 RED）。")
        return 1

    words, problems = parse_hex_file(hex_path)
    evs = decode_all(words)

    for p in problems[:MAX_EXAMPLES]:
        print("[RED] 解析：%s" % p)
    if len(problems) > MAX_EXAMPLES:
        print("[RED] 解析：另有 %d 行有问题" % (len(problems) - MAX_EXAMPLES))

    csv_path = args.csv
    if not csv_path and args.mid:
        csv_path = os.path.join(tmpdir, "events.csv")
    if not csv_path and args.hex:
        side = os.path.join(os.path.dirname(os.path.abspath(args.hex)), "events.csv")
        if os.path.isfile(side):
            csv_path = side
    midi_by_idx, csv_note = load_csv_midi(csv_path, evs)

    n_drum = sum(1 for e in evs if e["is_drum"] == 1)
    n_mel = sum(1 for e in evs if e["is_drum"] == 0 and e["kind"] != KIND_TEMPO)
    n_tempo = sum(1 for e in evs if e["kind"] == KIND_TEMPO)
    fmt_verdict, fmt_is_old = detect_format(evs)

    print("产物口径：%s" % fmt_verdict)
    print("事件总数：%d（鼓 %d / 旋律 %d / tempo %d）" % (len(evs), n_drum, n_mel, n_tempo))
    print("音高反查：%s" % csv_note)
    print("-" * 78)
    print("本文件独立写死的位域（不引用任何其他文件的常量表）：")
    print("  bit 63..44 tick(20) | bit 43..23 inc(21) 旋律唯一音高来源，鼓写 0")
    print("  bit 22..19 axis(4)  | bit 18..11 vel(8)  | bit 10..9 kind(2) 0=on 1=off 2=tempo")
    print("  bit 8..7 timbre(2)  | bit 6 guide_only | bit 5 is_drum | bit 4..0 note_off5(5)")
    print("  drum_type = timbre[8:7]（2 位，⛔ 不读 bit19）=> 4 件：%s"
          % " ".join("%d=%s" % (dt, dt_name(dt)) for dt in range(DRUM_TYPE_N)))
    print("  鼓的 axis = 12 + drum_type（一件一轴）：%s（合法轴段 %s）" % (AXIS_TXT, DRUM_AXIS_SET))
    print("  镲族 -> HiHat：%s（显式列出，⛔ 不靠表外兜底）"
          % "/".join(str(g) for g in CYMBAL_GMS))
    print("  note_off5：MIDI %d..%d => 0..%d；越界 => %d（哨兵，不点灯；⛔ 不许钳到 0）"
          % (MIDI_MIN_PLAY, MIDI_MAX_PLAY, NO5_MAX_PLAY, NO5_SENTINEL))
    print("  鼓力度：%s；鼓的 OFF 写 0"
          % " ".join("%s %d" % (dt_name(dt), DRUM_VEL[dt]) for dt in range(DRUM_TYPE_N)))
    print("-" * 78)

    selftest = run_selftest()
    results = [crit1(evs), crit2(evs), crit3(evs), crit4(evs, midi_by_idx),
               crit5(evs, midi_by_idx), crit6(evs, selftest, midi_by_idx),
               crit7(evs), crit8(evs)]
    if selftest["baseline_reds"]:
        print("[RED] 自检基线（自造合法小谱）竟然变红，判据实现有问题：%s"
              % " | ".join(selftest["baseline_reds"]))

    for r in results:
        print("%s 判据%s %s" % ("[OK] " if r.ok else "[RED]", r.cid, r.title))
        if r.sample_note:
            print("      样本：%s" % r.sample_note)
        for f in r.facts:
            print("      · %s" % f)
        for m in r.reds:
            print("      × %s" % m)

    n_red = sum(1 for r in results if not r.ok) + (1 if problems else 0) \
        + (1 if selftest["baseline_reds"] else 0)
    print("-" * 78)
    if n_red == 0:
        print("结论：八条判据全过 —— 产物满足手册 §六（ESP32 侧）与 §7.3 的机械检查，可以进 tb 联调。")
        code = 0
    else:
        red_ids = "/".join(r.cid for r in results if not r.ok) or "解析"
        print("结论：判据 %s 有 RED，产物不合格。" % red_ids)
        if fmt_is_old:
            print("      => 待新产物：%s" % fmt_verdict)
            print("        转换侧（mid2evt.py / score_studio.html）改完并重新产出 events.hex 后，重跑本检查即可。")
            print("        ⛔ 这里的红是【产物还没更新】的必然结果，不是判据写错。")
        code = 1

    if tmpdir and not args.keep_temp:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
