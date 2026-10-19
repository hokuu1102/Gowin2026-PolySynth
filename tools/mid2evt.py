#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mid2evt.py -- Standard MIDI file -> FPGA event stream.

WHY MIDI AND NOT THE .gp FILE
    An earlier tool parsed Guitar Pro's .gp (GPIF XML) directly.  It works, but
    it is fragile: the GPIF nesting puts <Bars> at two different levels with
    different meanings, a track's bars are the k-th bar of every master bar
    rather than a contiguous run, and beats/voices live in separate global
    blocks.  Two mistakes were made chasing that.  More importantly it is
    RE-DERIVING semantics that Guitar Pro already decided.

    Exporting MIDI from Guitar Pro and parsing THAT gives us the author's own
    semantics, in a decades-stable format:
      * note_on / note_off are already paired  => durations are correct
      * format 1 = one track per instrument    => no voice/bar archaeology
      * pitches are absolute note numbers      => no fret/capo/tuning maths

    Trade-off: one manual export step.  Worth it.

WHAT IT HANDLES
    * format 0 (single track) and format 1 (multi track)
    * running status (a MIDI stream omits a repeated status byte)
    * meta events (tempo, track name, end-of-track)
    * simultaneous same-pitch duplicates -> DE-DUPLICATED (see below)
    * drum tracks -> 也输出事件，但带 is_drum=1（见下 DRUM SPLIT）

DRUM DETECTION (deliberately NOT hard-coded to one channel)
    The channel a score uses for drums varies between scores, so we accept
    ANY of THREE signals and report which one fired:
      1. the track name contains drum/perc/kit/cymbal/hat   <- primary
      2. the track is on MIDI channel 9                     <- GM convention
      3. the track is named/indexed by --drum-track         <- 用户显式指定
    三者取【或】：命中任意一条即判为鼓轨。第 3 条是新增的（2026-10-16 手册
    §4.1）—— 轨名是作者随便起的、通道也不一定守 GM 约定，只有用户最清楚
    哪条轨是鼓，所以必须留一条"用户说了算"的通路。
    A fourth signal (pitch range inside 35..81) is only reported, never used
    to decide, because a low bass line can sit in that range too.

DRUM SPLIT (2026-10-16, 手册 §4.1 / §4.3)
    改前：鼓轨被【整轨排除】（只统计条数，不写进 events.hex），FPGA 只能靠
          "axis >= 12 就猜成鼓"这种捷径，而 inc 字段（21 位）装不下
          INC_SNARE(26 位) / INC_HIHAT(28 位) => 鼓变成音高纯音（电子音）。
    改后：鼓轨【照常输出事件】，每条：
          bit5   is_drum = 1
          drum_type      = timbre[8:7]（2 位，0=Kick 1=Snare 2=HiHat 3=Tom）
          inc            = 0（FPGA 从 drum_gen 的表按 drum_type 四选一）
          axis           = 12 + drum_type（一件一轴：12/13/14/15，见下 DRUM AXIS）
          ⛔ note_off(kind=1) 也必须带 is_drum=1 和【同一个】drum_type / axis。
             note_manager.v:1413-1416 的 note_off 按 (axis, src) 清 voice，漏了
             就会让鼓的 voice 永久 held => 鼓的保留池耗尽 => 打一会儿鼓就
             再也不响了。最容易漏的正是"只在 ON 上置标志"。
          为什么鼓必须一件一轴：四件鼓的 src 全都是 SRC_KDRUM，两件共用一条轴时
             任何一件的 OFF 都会清掉同轴同源另一件的 voice（鼓被切碎 / 挂音）。
             这就是 2026-10-15「方案 B（分轴）」要解决的事。
    旋律轨 / tempo 事件：is_drum 一律写死 0，轴号只在 0..11（12 条，与改前一致）。

DRUM AXIS（一件一轴：12=Kick 13=Snare 14=HiHat 15=Tom）
    FPGA 线回函 §2.1 写："鼓的身份靠 drum_type 字段，与轴号完全无关"。⛔ 这个推论
    不成立，RTL 原文是
        rtl/w3b/note_manager.v:1413-1416（ST_DECIDE 的 off 分支）
            if ((gate_r[i] | retrig_low[i]) && (axis_r[i] == cur_axis)
                && (src_r[i] == cur_src)) gate_r[i] <= 1'b0;
    而鼓的 src 全是 SRC_KDRUM => 【同一条 axis 上的两件鼓会互相清 voice】。
    ⇒ axis 仍是 voice 的唯一分隔键 => 四件鼓就必须 4 条互不相同的 axis。

    ⭐ 鼓事件的 axis = 12/13/14/15（一件一轴），与旋律的 0..11 完全不重叠。
    2026-10-16 二次修订（FPGA 线回函第三轮）：上一版曾把 drum_type 扩到 3 位、
    第 3 位放在 bit19（= axis 的 LSB），于是 axis 只能写"轴键"
    ((dt&3)<<1)|(dt>>2) = 0,2,4,6,1,3,5,7。⛔ 那一套【已作废】：
    FPGA 线第三轮收回"扩到 8 件"（那 4 个 inc 只是同一个纯音引擎在高频的 4 个
    音高，不是新音色），drum_type 回 2 位、bit19 不再承担任何语义，轴号随之回到
    12..15。⇒ 判据也从"axis == 轴键"变成"axis == 12 + drum_type"。
    ⚠️ 推论：⛔ 不能再靠"axis >= 12"判断是不是鼓，一律读 is_drum(bit5)。

DE-DUPLICATION
    A score may start the SAME pitch twice at the SAME tick -- two strings
    playing a unison, or two voices doubling.  That is legitimate notation and
    Guitar Pro exports it as two note_ons.  On the FPGA those become two
    voices at the same frequency, whose phases interfere: depending on the
    phase the result may get louder, thin out, or beat at the attack, which
    sounds like the note was struck twice.  Since the pitch is identical no
    musical information is lost by keeping one, and it also saves voices in a
    32-voice pool.  Only EXACT (tick, pitch) repeats are merged; a repeated
    pitch at a different tick is a real repeat and is preserved.

OUTPUT
    events.hex    FPGA record, one 64-bit word per line
    events.csv    the same, human readable
    report.txt    statistics + which drum rule fired + what was de-duplicated
    (no reference MIDI is produced: the input already IS MIDI)

FIELD LAYOUT (64-bit record) -- REVISED 2026-10-16（鼓与旋律分离，手册 §二；
    ⚠️ 同日二次修订已由第三轮回退：drum_type 回 2 位 = timbre[8:7]，鼓轴回 12..15）
    bit 63..44   tick    (20 bit)   musical time, PPQN=960
    bit 43..23   inc     (21 bit)   phase_inc -- 或 kind==2 时的 tick_inc
                                    ⚠️ 鼓事件写 0：旋律的唯一音高来源是 inc，
                                       鼓的音高由 FPGA 按 drum_type 查表给
    bit 22..19   axis    (4 bit)    axis id（鼓的判定⛔ 不看它，看 is_drum）
                                      旋律 : 顺序分 0..11（12 条，与改前一致）
                                      鼓   : 12/13/14/15（一件一轴，见 DRUM AXIS）
                                             12=Kick 13=Snare 14=HiHat 15=Tom
                                             ⇒ 与旋律的 0..11 不重叠；而旋律的
                                             轴号未动，仍是 0..11
    bit 18..11   vel     (8 bit)    velocity（⚠️ 2026-10-16 起不再是一律 130）
                                    旋律 : MIDI 真实力度（note_on 的力度原样带下来）
                                    鼓   : 鼓机力度（与网页 DRUM_VEL 同值，见 VELOCITY）
                                    note_off : 一律写 0
    bit 10..9    kind    (2 bit)    0=note_on, 1=note_off, 2=tempo change
    bit  8..7    timbre  (2 bit)    旋律：timbre id 0..3  (TIMBRE_N=4)
                                    鼓  ：drum_type（2 位，0=Kick 1=Snare
                                          2=HiHat 3=Tom）—— ⛔ 不再有第 3 位
    bit  6       guide   (1 bit)    bit6 = 仅指引（本工具不产生它，只写 0）
    bit  5       is_drum (1 bit)    新增：显式鼓标志（旋律/tempo 写死 0）
    bit  4..0    note5   (5 bit)    新增：note_off5 = MIDI音符号 - 45（给 LED 用）
                                           （基准 BASE_NOTE = 45 = A2）
                                           旋律：音高 < 45 或 > 75 => 5'd31（哨兵 =
                                           键盘上没有这个键，不点灯）；否则 0..30
                                           ⛔ 不再钳到 0 —— 0 是 A2，在指板表里是
                                           真实的键 5，会点亮错误的灯（FPGA 线实测）
                                           鼓 / tempo：一律写 0 —— 它们【没有音高】
                                           （鼓的"音高"是 GM 件号、tempo 装的是速度），
                                           哨兵只作用于旋律。与网页通路一致，也是
                                           check_drum_split 判据⑤的硬要求。
    OLD (2026-09-22 .. 2026-10-15)：bit 5..0 是 RESERVED，必须写 0。
    ⚠️ 新字段放在 bits[6:0] 而不是复用 axis 的最高位，正是因为【本工具原来
       就把 bits[6:0] 写死 0】=> 放在这里永远安全。若把 is_drum 塞进 axis 的
       bit22，轨号 8..15 会被读成鼓 => 又变成"旋律变鼓"，而且更隐蔽。

TEMPO EVENTS (kind=2)
    The tempo map used to live only in report.txt, so the FPGA had no way to
    know how fast a score should play -- a score that changes tempo would play
    at one constant BPM.  Each set_tempo now also emits a kind=2 record at its
    tick, with `inc` reinterpreted as tick_inc (the phase increment per PPQN
    tick), matching beat_gen.tick_inc_i exactly.  Kind=2 records also carry
    a timbre field, but it is meaningless there and written as 0.

TIMBRE (why the record carries it)
    Without it the FPGA can only use one global timbre, so every part -- three
    guitars, a bass -- sounds identical.  note_manager already has the per-note
    path (evt_timbre_valid_i / evt_timbre_i, latched at note-on per K-82), so
    carrying timbre in the record needs no change on the receiving side.  It
    costs nothing: 2 bits out of the 9 reserved, record stays 64 bits.
    （2026-10-16 补：那 9 位保留位后来又被用掉 6 位 —— bit5 is_drum 与
      bits[4:0] note_off5，见上面 FIELD LAYOUT。timbre 那 2 位位置没变。）

    The id is GUESSED from the track name (TIMBRE_HINTS).  That is a heuristic
    and it will sometimes be wrong, so the result is printed in report.txt and
    can be overridden with --timbre.

VELOCITY（2026-10-16 起 —— ⚠️ 这是一处【听觉行为变更】，与改前不同）
    改前：一律常量 130（原注释 "keep it simple"）=> 全曲没有强弱。
    改后：与网页通路 esp32/tools/score_studio.html 同一口径（FPGA 线建议、我方采纳）：
          旋律 : MIDI 真实力度（note_on 的力度原样带下来）
          鼓   : 鼓机力度（与网页 DRUM_VEL 同值）
                 Kick 230 · Snare 235 · HiHat 175 · Tom 220
                 —— 网页那两个数的出处是【生效值】= drum_gen.v 的默认 + top.v 的
                    实例化覆盖（KICK 没被覆盖 ⇒ 仍用默认 230），⛔ 不是照抄默认值；
                    ⚠️ 注意件与数的对应关系：230 是 Kick、175 是 HiHat，
                    与"175/220/230/235 顺次对应 Kick/Snare/HiHat/Tom"是【两回事】，
                    这里按网页（可复算的生效值）对齐。
                 新增四件（与网页 DRUM_VEL 的同一组数，⛔ 两边必须一致）：
                 OpenHat 185 · Crash 240 · Ride 195 · Splash 210
          OFF  : 一律写 0
    ⇒ 轻的音会明显变轻（原来一律 130 = 中等偏弱）。听感与旧版本不同是【预期】的，
      ⛔ 不是"变小声了"：它是把 FPGA 包络本来就想要的强弱层次还回去。

TICK OVERFLOW (why the layout changed)
    The old layout gave tick only 16 bits and masked it with & 0xFFFF.  Real
    scores run far past that: one sampled score reaches tick 814080, i.e. it
    wrapped TWELVE times and the note timeline was silently compressed.  The
    bug survived because nothing consumed events.hex (the audition tool reads
    the CSV, where the tick is complete) and because the truncation was
    SILENT -- no warning, no error.

    The fix does not widen the record.  Measured over a real score, phase_inc
    never exceeds 1077509 (that is MIDI 127, the highest note), which needs 21
    bits -- but the old layout reserved 32.  Re-allocating those idle bits
    buys tick 20 bits, i.e. 1048575 ticks = 273 bars at 4/4 PPQN 960.  The
    record stays 64 bits, so the byte count, the UART frame and the FPGA
    buffer are all unaffected.

    Both fields are now RANGE-CHECKED.  Exceeding either is a hard error, not
    a silent wrap: a silent wrap is what made this bug expensive.

USAGE
    python tools/mid2evt.py <file.mid> [--outdir DIR] [--transpose N]
                            [--timbre AXIS=NAME,...] [--drum-track SPEC,...]

    --drum-track 显式指定鼓轨（手册 §4.1 第三条识别规则）。SPEC 每项可以是：
                    · 纯数字  = 轨序号（0 起，按 MIDI 里的轨顺序）
                    · 其它串  = 轨名的子串（不分大小写）
                  例：--drum-track 4        （第 5 条轨是鼓）
                      --drum-track Drums    （轨名含 Drums 的是鼓）
                      --drum-track 4,Drums,Perc
                  默认 None = 不额外指定（行为与改前完全一致）
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import io
import os
import struct
import sys

PPQN = 960                     # must match beat_gen
FS = 50_000_000.0
TWO32 = 4294967296.0

KIND_ON, KIND_OFF = 0, 1
KIND_TEMPO = 2                 # ⭐ 换速：inc 字段改存 tick_inc（不是 phase_inc）

# --------------------------------------------------------------------------- #
# 64-bit record layout (see the module docstring for why tick is 20 bits)
# --------------------------------------------------------------------------- #
TICK_W, TICK_SH = 20, 44
INC_W,  INC_SH  = 21, 23
AXIS_W, AXIS_SH = 4, 19
VEL_W,  VEL_SH  = 8, 11
KIND_W, KIND_SH = 2, 9
TIMBRE_W, TIMBRE_SH = 2, 7        # ⭐ 音色号 0..3（TIMBRE_N=4）
GUIDE_W, GUIDE_SH = 1, 6          # bit6 仅指引（本工具不产生，只写 0）
IS_DRUM_W, IS_DRUM_SH = 1, 5      # 新增 bit5：显式鼓标志（手册 §4.1）
NOTE5_W, NOTE5_SH = 5, 0          # 新增 bits[4:0]：note_off5（给 LED 用）

TICK_MAX = (1 << TICK_W) - 1    # 1048575 ticks = 273 bars @ 4/4 PPQN 960
INC_MAX = (1 << INC_W) - 1      # 2097151 > MIDI 127 (1077509), with headroom

# note_off5 = MIDI音符号 - BASE_NOTE（音高 45..75 => 0..30）
#   基准 45 = A2 = 指板表最低音；5 位覆盖 MIDI 45..76（A2..E5），16 键足够。
#   ⚠️ 键位【不由本工具算】—— FPGA 有运行期变调，且键位表是非线性的物理布局，
#      所以这里只传音符号偏移，变调后由 FPGA 查表。
BASE_NOTE = 45
NOTE5_MIN, NOTE5_MAX = 0, (1 << NOTE5_W) - 1
# 音高 < 45 或 > 75 => 写 31（哨兵）。31 在两份 FPGA 表里都是 N（不点灯）。
# ⛔ 不许再钳到 0：0 = A2，在指板表里是【真实的键 5】=> 会点亮错误的灯
#    （FPGA 线实测确认，我方回函 §二-④）。
# 🔴🔴 硬约定（FPGA 线 2026-10-17 回函确认，双方共同遵守）：
#    bit[4:0] = 31 【永久】保留为"本事件不参与 LED 指引"
#    => 灯位表里永远不许放 offset 31（= MIDI 76）
#    ⚠️ offset 19..30（MIDI 64..75）现在也是 KEY_NONE，将来扩表补进去是【允许】的
#       （那是真实音域），但 offset 31 必须永远留空 ——
#       否则所有越界音会一起指到 76 那盏灯。
#    ⛔ 也别改成 `(midi - 45) & 0x1F`：那是【回绕】不是钳位，
#       MIDI 30 -> 17 -> 会点亮 MIDI 62 的灯（FPGA 线已认下这处错，见其 2026-10-17 回函 §〇）。
NOTE5_SENTINEL = NOTE5_MAX
NOTE5_PITCH_MIN, NOTE5_PITCH_MAX = BASE_NOTE, BASE_NOTE + NOTE5_MAX - 1   # 45 .. 75

# drum_type（手册 §4.3；2026-10-16 二次修订：⛔ 收回 3 位，保持 2 位）
#   = timbre[8:7]（两位），共 4 件：0=Kick 1=Snare 2=HiHat 3=Tom。
#   ⛔ 不取 bit19 —— FPGA 线第三轮收回"扩到 8 件"（只有 4 件鼓音色），
#      那个"bit19 是 drum_type 的 MSB"的说法与校验【一并作废】。
DRUM_TYPE_W = 2
DRUM_TYPE_MASK = (1 << DRUM_TYPE_W) - 1
DRUM_KICK, DRUM_SNARE, DRUM_HIHAT, DRUM_TOM = 0, 1, 2, 3
DRUM_TYPE_N = 4
DRUM_TYPE_NAMES = {DRUM_KICK: "Kick", DRUM_SNARE: "Snare",
                   DRUM_HIHAT: "HiHat", DRUM_TOM: "Tom"}

# GM 打击乐音符号 -> drum_type。表外的打击乐音符号【仍先归 Tom】，但必须在
# report.txt 里【逐个列出来】（既有纪律：兜底不许静默）。
#   定稿依据（GM 打击乐标准音高，FPGA 线回函第三轮 §一）：
#   ⭐ 镲族 8 个音高【显式列出】指向 HiHat(2) —— 镲与踩镲都是金属高频，
#      "镲 -> 踩镲"远比"镲 -> 嗵鼓"合理，而且不需要造音色。⛔ 不靠"表外兜底"：
#      显式列出才能让 report 把"有意归类成 HiHat"与"没认出来、先归 Tom"分开。
#   46=OpenHat · 49=Crash1 · 51=Ride1 · 52=Chinese Cymbal · 53=Ride Bell ·
#   55=Splash · 57=Crash2 · 59=Ride2
#   ⚠️ 55 是 Splash（FPGA 线上一版 §2.3 的表把 55 抄重了）—— 本轮结果不受影响，
#      因为 Splash 与 Crash 同归 HiHat。
GM_DRUM_TYPE = {
    35: DRUM_KICK,  36: DRUM_KICK,
    38: DRUM_SNARE, 40: DRUM_SNARE,
    42: DRUM_HIHAT, 44: DRUM_HIHAT,
    41: DRUM_TOM,   43: DRUM_TOM,  45: DRUM_TOM,
    47: DRUM_TOM,   48: DRUM_TOM,  50: DRUM_TOM,
    # ---- 镲族：8 个音高显式归 HiHat（FPGA 线回函第三轮 §一，⭐ 本轮重点）----
    46: DRUM_HIHAT,
    49: DRUM_HIHAT,
    51: DRUM_HIHAT,
    52: DRUM_HIHAT,
    53: DRUM_HIHAT,
    55: DRUM_HIHAT,
    57: DRUM_HIHAT,
    59: DRUM_HIHAT,
}

# ⭐ 镲族音高（GM 打击乐）。存在的唯一目的是让 report 能把【有意归成 HiHat】与
#    【没认出来、兜底归 Tom】分开：这两类在事件里都长一样，只有报告能区分它。
#   ⛔ 它不参与映射决策 —— 映射决策只看上面的 GM_DRUM_TYPE 显式条目。
CYMBAL_NOTES = (46, 49, 51, 52, 53, 55, 57, 59)

# 鼓件 -> axis 字段的值（一件一轴：12=Kick 13=Snare 14=HiHat 15=Tom）。
# 与网页上位机 score_studio.html 的鼓轴表同一张表、同一口径，⛔ 不许另定。
# 为什么必须【一件一轴】—— note_manager.v:1413-1416 的 note_off 按 (axis, src) 清
#   voice，而四件鼓的 src 全都是 SRC_KDRUM。两件鼓共用一条轴时，任何一件的 OFF
#   都会把同轴同源的另一个 voice 一起清掉（鼓被切碎 / 挂音）。
# ⚠️ 上一版曾把 drum_type 扩到 3 位、轴写"轴键"((dt&3)<<1)|(dt>>2) = 0,2,4,6,1,3,5,7
#   —— ⛔ 已作废：FPGA 线第三轮收回 8 件，drum_type 回 2 位、bit19 不再承载语义。
DRUM_AXIS_BASE = 12
DRUM_AXIS_OF = {DRUM_KICK: 12, DRUM_SNARE: 13, DRUM_HIHAT: 14, DRUM_TOM: 15}


def drum_axis_of(dt):
    """drum_type -> axis 字段的值 = 12 + dt（一件一轴：12/13/14/15）。"""
    return DRUM_AXIS_BASE + (dt & DRUM_TYPE_MASK)


# 反查：轴号 -> 鼓件（仅对鼓事件有意义，报告里用）
DRUM_TYPE_OF_AXIS = dict((ax, dt) for dt, ax in DRUM_AXIS_OF.items())

# ⭐ 鼓机力度（与网页 DRUM_VEL 同值）。出处 = 【生效值】：
#   rtl/w3c/drum_gen.v 默认 KICK 230 · SNARE 200 · HIHAT 140 · TOM 190
#   rtl/top.v 实例化覆盖  SNARE 235 · HIHAT 175 · TOM 220（KICK 未被覆盖 => 230）
#   ⚠️ 件的对应关系：Kick 230 / Snare 235 / HiHat 175 / Tom 220 —— ⛔ 不是把
#      175/220/230/235 顺次贴给 Kick/Snare/HiHat/Tom。网页侧有同样的注释，改一处
#      必须改两处（两处常量漂移正是这一轮要消灭的）。
#   ⚠️ 第三轮已收回"新增四件（OpenHat 185 / Crash 240 / Ride 195 / Splash 210）"：
#      镲族统一走 HiHat ⇒ 用 HiHat 的 175，⛔ 这四件不再有自己的力度。
DRUM_VEL = {
    DRUM_KICK: 230, DRUM_SNARE: 235, DRUM_HIHAT: 175, DRUM_TOM: 220,
}

# 旋律轴号：0..11（12 条）—— 与改前完全一致（鼓用 12..15，两段不重叠）。
MELODY_AXIS_N = 12
MELODY_AXIS_MAX = MELODY_AXIS_N - 1

# ⭐ 音色号（必须与 RTL 的 TIMBRE_N=4 及 wavetable_bank 的表序一致）
TIMBRE_BASS, TIMBRE_GUITAR, TIMBRE_PIANO, TIMBRE_PAD = 0, 1, 2, 3
TIMBRE_NAMES = {TIMBRE_BASS: "BASS", TIMBRE_GUITAR: "GUITAR",
                TIMBRE_PIANO: "PIANO", TIMBRE_PAD: "PAD"}
TIMBRE_BY_NAME = {v: k for k, v in TIMBRE_NAMES.items()}

# ⭐ 轨名 -> 音色 的关键词表（⛔ 先匹配到的先用；顺序有意义）
#   ⚠️ 这是【启发式】—— 轨名是作者随便起的，猜错很正常。
#   ⇒ ⭐ 所以必须：① 结果写进 report.txt ② 支持 --timbre 手工覆盖
TIMBRE_HINTS = (
    ("bass",  TIMBRE_BASS),
    ("solo",  TIMBRE_PIANO),      # ⭐ 主音：用脉冲波（亮）—— 见 曲谱音色分配与相位干涉分析.md
    ("lead",  TIMBRE_PIANO),
    ("pad",   TIMBRE_PAD),
    ("piano", TIMBRE_PIANO),
    ("keys",  TIMBRE_PIANO),
    ("synth", TIMBRE_PAD),
    ("gt",    TIMBRE_GUITAR),
    ("gtr",   TIMBRE_GUITAR),
    ("guitar", TIMBRE_GUITAR),
)

# General-MIDI percussion channel (0-based). Channel 10 in 1-based speech.
GM_DRUM_CHANNEL = 9

# drum name hints, matched case-insensitively against the track name
DRUM_HINTS = ("drum", "perc", "kit", "cymbal", "hat")


# --------------------------------------------------------------------------- #
# MIDI reading
# --------------------------------------------------------------------------- #
def _read_vlq(d, i):
    v = 0
    while True:
        b = d[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            return v, i


def parse_midi(path):
    """Return (division, fmt, tempo_map, [track, ...]).

    tempo_map = [(tick, us_per_quarter), ...] sorted -- the set_tempo meta
    events (0x51).  A score can change tempo MID-SONG (one sampled score runs
    168 -> 160 BPM), so one BPM constant cannot place notes in real time.

    Each track is {"name": str, "chan": set,
                   "events": [(tick, is_note_on, note, velocity), ...]}
    """
    d = open(path, "rb").read()
    if d[:4] != b"MThd":
        raise SystemExit("ERROR: %s is not a MIDI file (no MThd)" % path)
    fmt, ntrk, division = struct.unpack(">HHH", d[8:14])
    if division & 0x8000:
        raise SystemExit("ERROR: SMPTE time division is not supported")

    i = 14
    tracks = []
    tempos = []
    while i + 8 <= len(d) and d[i:i+4] == b"MTrk":
        ln = struct.unpack(">I", d[i+4:i+8])[0]
        body = d[i+8:i+8+ln]
        i += 8 + ln

        out = {"name": "", "chan": set(), "events": []}
        t = 0
        j = 0
        run = None
        while j < len(body):
            dt, j = _read_vlq(body, j)
            t += dt
            st = body[j]
            if st < 0x80:
                if run is None:
                    # malformed: no running status yet; skip the byte
                    j += 1
                    continue
                st = run                      # running status
            else:
                j += 1

            if st == 0xFF:                    # meta
                mt = body[j]
                j += 1
                l, j = _read_vlq(body, j)
                data = body[j:j+l]
                j += l
                if mt == 0x03:
                    out["name"] = data.decode("utf-8", "replace").strip()
                elif mt == 0x51 and l == 3:
                    us = (data[0] << 16) | (data[1] << 8) | data[2]
                    if us > 0:
                        tempos.append((t, us))
                continue
            if st in (0xF0, 0xF7):            # sysex
                l, j = _read_vlq(body, j)
                j += l
                continue

            run = st
            hi = st & 0xF0
            ch = st & 0x0F
            if hi == 0x90:
                note, vel = body[j], body[j+1]
                j += 2
                out["chan"].add(ch)
                if vel > 0:
                    out["events"].append((t, True, note, vel))
                else:
                    out["events"].append((t, False, note, 0))
            elif hi == 0x80:
                note, vel = body[j], body[j+1]
                j += 2
                out["chan"].add(ch)
                out["events"].append((t, False, note, vel))
            elif hi in (0xA0, 0xB0, 0xE0):
                j += 2
            elif hi in (0xC0, 0xD0):
                j += 1
            else:
                break
        tracks.append(out)

    tempos.sort()
    if not tempos:
        tempos = [(0, 500000)]            # MIDI default = 120 BPM
    return division, fmt, tempos, tracks


# --------------------------------------------------------------------------- #
# classification
# --------------------------------------------------------------------------- #
def parse_drum_track_spec(s):
    """解析 --drum-track 的 SPEC -> {"indices": set, "names": [str]}；空则 None。

    每项：纯数字 = 轨序号（0 起，按 MIDI 文件里的轨顺序）
          其它   = 轨名的子串（不分大小写）
    这是手册 §4.1 的【第三条】鼓识别规则：用户显式指定即可，不被轨名或通道
    推翻 —— 用户最懂自己的谱子，工具不替他做主。
    """
    if not s:
        return None
    spec = {"indices": set(), "names": []}
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            spec["indices"].add(int(part))
        except ValueError:
            spec["names"].append(part.lower())
    if not spec["indices"] and not spec["names"]:
        return None
    return spec


def classify(track, index=None, forced=None):
    """Return (is_drum, reason).  三条规则【取或】，命中任意一条即为鼓轨。

      1. 显式指定（--drum-track，新增）
      2. 轨名含 drum/perc/kit/cymbal/hat（原有）
      3. GM 通道 9（原有）
    判定顺序只影响 reason 的文字，不影响结论。
    显式指定的名字还允许匹配报告里的显示名（无轨名的轨显示成 "track N"），
    这样用户可以直接照着报告里看到的名字去指定。
    """
    forced = forced or {}
    if index is not None and index in (forced.get("indices") or ()):
        return True, "explicitly forced by --drum-track (track index %d)" % index
    nm = track["name"].lower()
    label = nm
    if index is not None and not nm:
        label = ("track %d" % index).lower()
    for sub in (forced.get("names") or ()):
        if sub and sub in label:
            return True, ("explicitly forced by --drum-track "
                          "(name contains '%s')" % sub)
    for h in DRUM_HINTS:
        if h in nm:
            return True, "track name contains '%s'" % h
    if GM_DRUM_CHANNEL in track["chan"]:
        return True, "MIDI channel %d (GM percussion)" % (GM_DRUM_CHANNEL + 1)
    return False, ""


def drum_type_for_note(midi):
    """GM 打击乐音符号 -> (drum_type, mapped)。mapped=False = 表外，仍先归 Tom。

    映射表见手册 §4.3 / FPGA 线回函第三轮 §一（4 件：0=Kick 1=Snare 2=HiHat
    3=Tom；镲族 46/49/51/52/53/55/57/59 显式归 HiHat）。表外的音符号必须在
    report.txt 里【逐个列出来】—— 兜底不许静默（既有纪律），而且只有这样才能让
    报告区分"有意归成 HiHat"与"没认出来、先归 Tom"。
    """
    t = GM_DRUM_TYPE.get(midi)
    if t is None:
        return DRUM_TOM, False
    return t, True


def is_playable(midi):
    """音高是否落在键盘上真实存在的键域内（A2..D#4，MIDI 45..75 => offset 0..30）。"""
    return NOTE5_PITCH_MIN <= int(midi) <= NOTE5_PITCH_MAX


def note_off5_for(midi):
    """【旋律】note_off5：可弹音域内 = MIDI - BASE_NOTE（0..30），否则 31（哨兵）。

    ⛔ 不再钳到 0 —— 0 是 A2，在指板表里是【真实的键 5】=> 会点亮错误的灯
    （FPGA 线实测确认）。31 在两份表里都是 N => 不点灯。

    ⚠️ 只对【旋律】调用。鼓与 tempo 没有音高（鼓的"音高"是 GM 件号，tempo 的字段
    装的是速度）=> 两者一律写 0，与网页通路 score_studio.html 一致
    （那里的注释原文：鼓与 tempo 必须写 0）。这也是判据⑤要求的：哨兵只作用于
    旋律事件，给鼓写 31 会和它自己后面的判据互相矛盾（实测 RED 250 条）。
    """
    m = int(midi)
    if NOTE5_PITCH_MIN <= m <= NOTE5_PITCH_MAX:
        return m - BASE_NOTE
    return NOTE5_SENTINEL


def rec_drum_type(axis, timbre):
    """从【记录字段】还原 2 位 drum_type（给校验器用）。

    ⚠️ 2 位版就是 timbre[8:7] 本身 —— 与 axis 字段【无关】（axis 只承载"一件一轴"
    的 12..15，⛔ 不再兼职 drum_type 的 MSB）。axis 参数保留只为调用点签名不变。
    """
    return int(timbre) & DRUM_TYPE_MASK


# --------------------------------------------------------------------------- #
# conversion
# --------------------------------------------------------------------------- #
def note_to_phase_inc(midi):
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    return max(0, min(0xFFFFFFFF, int(round(f * TWO32 / FS))))


def timbre_for_track(name, axis, overrides=None):
    """Guess the timbre id from a track name.  Returns (id, reason).

    ⚠️ A HEURISTIC.  Track names are free-form ("Biu GT Solo" could be lead,
       rhythm or something else entirely), so this WILL be wrong sometimes.
       That is why the caller prints the result and --timbre can override it.
       Silence here would be the real bug, not a wrong guess.
    """
    if overrides and axis in overrides:
        return overrides[axis], "axis %d override" % axis
    low = (name or "").lower()
    for kw, tid in TIMBRE_HINTS:
        if kw in low:
            return tid, "name contains '%s'" % kw
    return TIMBRE_GUITAR, "default (no keyword matched)"


def tick_inc_for_bpm(bpm):
    """Phase increment per PPQN tick, in the beat_gen.tick_inc_i scale.

    ⚠️ MUST match beat_gen: phase advances by tick_inc per SYSTEM clock, and a
       tick is emitted when the 32-bit accumulator carries.  So
           tick rate  f_tick = BPM/60 * PPQN      [ticks/s]
           tick_inc   = round(f_tick * 2^32 / 50e6)
       Verified against tb_beat_gen's own constants (60 BPM -> 82463,
       120 BPM -> 164927).
    """
    f_tick = (bpm / 60.0) * PPQN
    return int(round(f_tick * TWO32 / FS))


def build_events(tracks, division, tempos, transpose=0, overrides=None,
                 drum_tracks=None):
    """Return (events, stats).  旋律与鼓【都输出事件】（手册 §4.1）。

    改前：鼓轨被整轨排除，只统计条数（dropped_drum）。
    改后：鼓轨照常输出，每条带 is_drum=1 / drum_type（2 位 = timbre[8:7]）/ inc=0；
          / inc=0；旋律轨与 tempo 事件的 is_drum 写死 0。每条事件都带
          note_off5（可弹音域内 = MIDI - BASE_NOTE，越界写 31 = 哨兵，给 LED 用），
          以及 vel（旋律真实力度 / 鼓机力度 / note_off 写 0）。

    Ticks are converted to the FPGA's PPQN grid.  Each event also carries its
    TIMBRE id, and the score's tempo map is emitted as kind=2 records so the
    stream is self-contained (the FPGA no longer needs the .mid to know how
    fast to play).
    """
    scale = float(PPQN) / float(division)

    stats = {
        "tracks": [], "drum_tracks": [], "empty_tracks": [], "notes": 0,
        "events": 0, "dropped_drum": 0, "dedup": 0, "cross_dedup": 0,
        "max_tick": 0, "min_midi": 999, "max_midi": -999,
        "per_track": [], "axis_overflow": 0, "tempos": tempos,
        "timbre_of_axis": [], "tempo_events": 0, "max_tick_inc": 0,
        # 鼓专项统计。dropped_drum 保留只为旧调用方不炸，改后恒为 0。
        "drum_info": [], "drum_notes": 0, "drum_note_hist": {},
        "drum_type_counts": {}, "drum_unmapped": {},
        "drum_on_events": 0, "drum_off_events": 0,
        "drum_forced_unmatched": [], "drum_axes_used": set(),
        # 判为不可弹（note_off5 写 31）的【旋律】音符数 —— 诊断价值：它说明引导轨
        # 超出了键盘音域（我方回函 §二-④）。⛔ 鼓/tempo 不计：它们没有音高、写 0。
        "unplayable": 0,
    }
    events = []

    # 轴号分派（2026-10-16 起）：
    #   · 旋律轨：顺序分 0..11（12 条，与改前一致；12..15 从未使用）
    #   · 鼓轨  ：不占顺序轴号，逐音按【鼓件】给固定轴号（12..15，见 DRUM_AXIS_OF）
    # 改前鼓轨在这里被 continue 掉（整轨排除）；现在鼓轨也输出事件，但轴号走
    # 上表，不吃顺序号 —— 这样旋律的轴号与改前【完全一致】（0,1,2,...）。
    # 另外：只给【真正带音符】的轨分轴号。Guitar Pro 会导出空占位轨（有时还有
    # 两条同名的），给它们分轴号会白烧一个 id 并在编号里留空洞，对读事件 dump
    # 毫无好处，所以在前面剔掉并在报告里说明。
    axis_of = {}
    note_tracks = []
    nxt = 0
    for ti, tr in enumerate(tracks):
        drum, reason = classify(tr, ti, drum_tracks)
        nm = tr["name"] or ("track %d" % ti)
        if drum:
            stats["drum_tracks"].append("%s (%s)" % (nm, reason))
        if not any(e[1] for e in tr["events"]):     # no note_on at all
            stats["empty_tracks"].append(nm)
            continue
        note_tracks.append(ti)
        if drum:
            continue                    # 鼓用固定轴号，不占顺序轴号
        axis_of[ti] = nxt % MELODY_AXIS_N
        nxt += 1
    if nxt > MELODY_AXIS_N:
        # 旋律轴号只有 0..11 这 12 条（与改前一致，⛔ 这一轮不让轴给鼓）。
        stats["axis_overflow"] = nxt

    # ⚠️ --drum-track 里如果有一项【谁也没匹配上】，必须说出来（⛔ 不静默）：
    #    用户以为指定生效了、实际没生效 —— 这是配置类参数最典型的坑。
    unmatched = []
    fspec = drum_tracks or {}
    for ix in sorted(fspec.get("indices") or ()):
        if not (0 <= ix < len(tracks)):
            unmatched.append("轨序号 %d（本文件共 %d 条轨）" % (ix, len(tracks)))
    for sub in (fspec.get("names") or ()):
        if not any(sub in (tr["name"] or ("track %d" % i)).lower()
                   for i, tr in enumerate(tracks)):
            unmatched.append("轨名子串 '%s'" % sub)
    stats["drum_forced_unmatched"] = unmatched

    for ti in note_tracks:
        tr = tracks[ti]
        nm = tr["name"] or ("track %d" % ti)
        drum, reason = classify(tr, ti, drum_tracks)

        # 旋律轴号（0..11）。鼓轨在下面逐音改用鼓件的固定轴号（12..15）。
        axis = axis_of.get(ti, 0) & 0xF
        if drum:
            # 鼓：timbre[8:7] 这个字段改当 drum_type 的【低 2 位】用（手册 §4.1 /
            # §4.3）。每件的 drum_type 在下面按 GM 音符号逐音算，这里只是占位值。
            timbre, why = DRUM_KICK, "drum track: timbre field = drum_type"
        else:
            # ⭐ 音色：按轨名猜（⭐ 结果要写进 report.txt，⛔ 不静默）
            timbre, why = timbre_for_track(nm, axis, overrides)
            stats["timbre_of_axis"].append((axis, nm, timbre, why))
        # pair note_on with the NEXT note_off of the same pitch (FIFO per pitch)
        # ⚠️ 力度跟着 note_on 一起入队：2026-10-16 起 vel 用【真实力度】，
        #    所以配对时必须把 ON 的力度带到这个音上（原来这里只记 tick）。
        pending = {}
        span = []                        # [(start_tick, end_tick, note, velocity)]
        for tick, is_on, note, vel in tr["events"]:
            if is_on:
                pending.setdefault(note, []).append((tick, vel))
            else:
                if pending.get(note):
                    s, v = pending[note].pop(0)
                    span.append((s, tick, note, v))

        # ---- de-duplicate: same (tick, pitch) started more than once ----
        # ⚠️ 同组里力度取【最大】的（与网页通路一致：两把同音色齐奏时，留一个更
        #    接近原来的响度）。
        seen = {}
        for s, e, note, v in span:
            key = (s, note)
            if key in seen:
                stats["dedup"] += 1
                if v > seen[key][2]:
                    seen[key] = (s, e, v)
                continue
            seen[key] = (s, e, v)
        if drum:
            stats["drum_info"].append((nm, len(seen), reason))
        else:
            stats["per_track"].append((nm, axis, len(seen)))

        for (s, note), (_, e, real_vel) in seen.items():
            # 鼓【不受 --transpose 影响】：GM 打击乐音符号就是"哪件鼓"的身份，
            # 移调会把它变成另一件鼓（甚至落到表外）。只有旋律才移调。
            midi = note if drum else (note + transpose)
            if not (0 <= midi <= 127):
                continue
            vel = real_vel              # ⭐ 真实力度（旋律 = MIDI 原始力度；OFF 见下）
            ax = axis                   # 旋律：本轨的顺序轴号
            dt = None                   # 鼓件号（2 位），只有鼓事件才有
            if drum:
                # 按【原始】GM 音符号映射；表外的仍先归 Tom，并在报告里列出来
                dt, mapped = drum_type_for_note(note)
                # timbre[8:7] 这个字段对鼓事件就是 drum_type 本身（2 位，⛔ 没有
                # 第 3 位，也不再借 axis 的 LSB 承载）。
                timbre = dt & DRUM_TYPE_MASK
                inc = 0                 # 手册硬要求：is_drum=1 时 inc 必须为 0
                # ⚠️ note_off5 写 0（⛔ 不是哨兵 31）：鼓没有音高 —— GM 件号不是
                #    键盘音高。哨兵只作用于旋律（与网页通路一致，判据⑤要求）。
                n5 = 0
                vel = DRUM_VEL[dt]      # ⭐ 鼓机力度（⛔ 不用 MIDI 原始力度）
                # 一件一轴：12=Kick 13=Snare 14=HiHat 15=Tom（见 DRUM_AXIS_OF）
                ax = DRUM_AXIS_OF[dt]
                stats["drum_notes"] += 1
                stats["drum_axes_used"].add(ax)
                h = stats["drum_note_hist"]
                h[note] = h.get(note, 0) + 1
                tc = stats["drum_type_counts"]
                tc[dt] = tc.get(dt, 0) + 1
                if not mapped:
                    um = stats["drum_unmapped"]
                    um[note] = um.get(note, 0) + 1
            else:
                # 旋律轨：is_drum 由下面的 base 写死 0（不依赖任何条件）
                inc = note_to_phase_inc(midi)
                n5 = note_off5_for(midi)
                stats["notes"] += 1
                stats["min_midi"] = min(stats["min_midi"], midi)
                stats["max_midi"] = max(stats["max_midi"], midi)
                # ⭐ 判为不可弹（写 31）的条数 —— 诊断价值：它说明引导轨超出了键盘音域
                if not is_playable(midi):
                    stats["unplayable"] += 1
            dur = max(1, int(round((e - s) * scale)))
            t0 = int(round(s * scale))
            # ⚠️ ON 与 OFF 由【同一份 base】造出来，所以 is_drum / axis / drum_type
            #    （= timbre）在结构上不可能不一致。手册点名：鼓的
            #    note_off 漏了 is_drum / drum_type，note_manager.v:1413-1416 的
            #    (axis,src) 就配不上 => 鼓 voice 永久 held => 保留池耗尽 =>
            #    打一会儿鼓就再也不响了。最容易漏的就是"只在 ON 上置标志"。
            base = {"axis": ax, "midi": midi, "timbre": timbre,
                    "is_drum": 1 if drum else 0, "note5": n5}
            if drum:
                base["drum_type"] = dt
            # ⭐ ON 带力度、OFF 写 0（与网页通路一致：vel 只在 ON 上有意义）
            events.append(dict(base, vel=vel, tick=t0, inc=inc, kind=KIND_ON))
            # a note_off is ALWAYS emitted: without it the note hangs (T38)
            events.append(dict(base, vel=0, tick=t0 + dur, inc=inc, kind=KIND_OFF))
            if drum:
                stats["drum_on_events"] += 1
                stats["drum_off_events"] += 1
            stats["max_tick"] = max(stats["max_tick"], t0 + dur)
        if not drum:
            stats["tracks"].append(nm)

    # ⭐ 速度表 -> kind=2 事件（⭐ 让 hex 自包含；⛔ 见 docstring 的 TEMPO EVENTS）
    # 手册 §4.1：tempo 事件 is_drum 写 0、drum_type 写 0。
    # note_off5 对 tempo 没有意义（它没有音高）=> 写 0（与网页通路一致：哨兵只作用于
    #   旋律事件，tempo 若也写 31 会被判据⑤当成"鼓/非旋律带了哨兵"而互相矛盾）。
    for tk, us in (tempos or []):
        if us <= 0:
            continue
        bpm = 60_000_000.0 / us
        ti_ = tick_inc_for_bpm(bpm)
        t0 = int(round(tk * scale))
        events.append({"tick": t0, "inc": ti_, "vel": 0, "axis": 0,
                       "kind": KIND_TEMPO, "midi": -1, "timbre": 0,
                       "is_drum": 0, "note5": 0})
        stats["tempo_events"] += 1
        stats["max_tick_inc"] = max(stats["max_tick_inc"], ti_)
        stats["max_tick"] = max(stats["max_tick"], t0)

    # note_off must be ordered before note_on at the same tick, so that a
    # re-strike of the same pitch is not immediately cancelled.
    # ⭐ kind=2 (tempo) sorts FIRST at a shared tick, so the new tempo is in
    #    force for the notes that start on that very tick.  A plain sort on
    #    (tick, kind) would put tempo LAST (2 > 1), which is wrong.
    # ⚠️ The ranks must be DISTINCT: mapping tempo to the same rank as note_on
    #    (both 0) would let Python's stable sort keep the notes first, because
    #    tempo records are appended after all notes -- so the tie-break silently
    #    reverses the intent.  tempo=-1 puts it unambiguously ahead.
    # 🔴🔴 2026-10-17 修（FPGA 线《ESP32侧需求-写音高字段bit4-0点亮LED指引》§三-3.3）：
    #    上面注释写着"off 要排在 on 前面"，但代码写的是 `e["kind"]` —— 而 KIND_ON=0 < KIND_OFF=1
    #    ⇒ 实际把【ON 排在 OFF 前面】，与注释**正好相反**（注释与代码互相矛盾，本仓 C116 那一族）。
    #    危害（实测）：
    #      · 发声：同音高、同 (axis,src) 的重击会被自己的 off 立刻掐掉；
    #      · LED：那一拍点亮的灯只亮 1 个周期（20 ns）⇒ 肉眼不可见。
    #    实测"同 tick 同音高、ON 在 OFF 前"的对数：测试曲 15 对 / 09_Conjurer 3428 对 /
    #    6.世界悲 2464 对（约占该曲字数 1/4）。
    #    修法：把 kind 映射成 rank（tempo=-1 · off=0 · on=1）—— 三个 rank 互不相同，
    #    ⛔ 不能直接写 `e["kind"]`。
    events.sort(key=lambda e: (e["tick"],
                               -1 if e["kind"] == KIND_TEMPO else
                               (0 if e["kind"] == KIND_OFF else 1)))
    stats["events"] = len(events)
    return events, stats


# --------------------------------------------------------------------------- #
# writers
# --------------------------------------------------------------------------- #
def pack_event(e):
    """Pack one event into the 64-bit record.

    BOTH range checks are load-bearing.  A silent & mask is exactly what hid
    the tick overflow for so long, so overflowing either field raises instead
    of wrapping.  If this fires on a real score the layout needs revisiting --
    do NOT "fix" it by widening the mask.

    2026-10-16 追加（手册 §4.1）：bit5 is_drum 与 bits[4:0] note_off5 参与打包
    （改前这两位恒 0）。并且 is_drum=1 时【在这里就拒绝】inc != 0 —— inc 是
    旋律的唯一音高来源，鼓的 inc 由 FPGA 按 drum_type 查表给，写非 0 就是把
    鼓当旋律发。⛔ 不要用"加个掩码兜住"绕过任何一条：掩码正是当年把 tick
    回绕藏起来、让 bug 活下来的做法。

    2026-10-16 二次修订（⛔ 收回 3 位 / 8 件，保持 2 位 / 4 件）：鼓事件的
      · drum_type 必须是 0..3（2 位，写在 timbre[8:7]）；
      · timbre[8:7] 必须【正是】drum_type —— 2 位版里这两个是同一个字段，
        ⛔ 不再有"低 2 位 + bit19 的 MSB"那套拆分；
      · axis 必须【正是】该件的轴号（DRUM_AXIS_OF = 12 + drum_type）—— 一件一轴。
        把 axis 与 drum_type 混为一谈（或退回 8+dt / 轴键那一套）是这一轮最容易
        犯的错：轴是 voice 的分隔键，drum_type 是音色号，两者各写各的、必须自洽。
    """
    tick, inc = e["tick"], e["inc"]
    is_drum = e.get("is_drum", 0)       # 缺省 0 = 旋律（旧调用方仍可跑）
    note5 = e.get("note5", 0)
    if tick > TICK_MAX:
        raise SystemExit(
            "ERROR: tick %d exceeds the %d-bit field (max %d = %.1f bars). "
            "The note timeline would silently wrap; the record layout must be "
            "revisited rather than masked."
            % (tick, TICK_W, TICK_MAX, TICK_MAX / float(PPQN * 4)))
    if inc > INC_MAX:
        raise SystemExit(
            "ERROR: inc %d exceeds the %d-bit field (max %d). "
            "This is the phase_inc / tick_inc field; the record layout must be "
            "revisited rather than masked." % (inc, INC_W, INC_MAX))
    if e["axis"] > 0xF:
        raise SystemExit("ERROR: axis %d does not fit 4 bits" % e["axis"])
    if e["vel"] > 0xFF:
        raise SystemExit("ERROR: velocity %d does not fit 8 bits" % e["vel"])
    if e["kind"] > 0x3:
        raise SystemExit("ERROR: kind %d does not fit 2 bits" % e["kind"])
    if e["timbre"] > 0x3:
        raise SystemExit("ERROR: timbre %d does not fit 2 bits" % e["timbre"])
    if is_drum not in (0, 1):
        raise SystemExit("ERROR: is_drum %r is not 0/1" % (is_drum,))
    if not (NOTE5_MIN <= note5 <= NOTE5_MAX):
        raise SystemExit("ERROR: note_off5 %d is outside 0..%d -- "
                         "由 note_off5_for() 判定，到这里必须已经合法"
                         % (note5, NOTE5_MAX))
    if is_drum and inc != 0:
        raise SystemExit(
            "ERROR: is_drum=1 的事件 inc 必须为 0，实测 inc=%d (kind=%d)。"
            "手册 §4.1 硬要求；非 0 会被 FPGA 当成音高纯音（电子音）。"
            % (inc, e["kind"]))
    if is_drum:
        # ---- drum_type（2 位 = timbre[8:7]）与轴号必须自洽 ----
        dt = e.get("drum_type")
        if not isinstance(dt, int) or not (0 <= dt <= DRUM_TYPE_MASK):
            raise SystemExit("ERROR: 鼓事件的 drum_type=%r 不在 0..%d"
                             % (dt, DRUM_TYPE_MASK))
        if e["timbre"] != (dt & DRUM_TYPE_MASK):
            raise SystemExit(
                "ERROR: 鼓件 %s(drum_type=%d) 的 timbre[8:7]=%d，应为 %d —— "
                "2 位版里 timbre[8:7] 就是 drum_type 本身（⛔ 没有第 3 位）"
                % (DRUM_TYPE_NAMES[dt], dt, e["timbre"], dt & DRUM_TYPE_MASK))
        want_axis = DRUM_AXIS_OF[dt]
        if e["axis"] != want_axis:
            raise SystemExit(
                "ERROR: 鼓件 %s(drum_type=%d) 的 axis=%d，应为 %d "
                "（= 12 + drum_type，一件一轴：12=Kick 13=Snare 14=HiHat 15=Tom）。"
                "轴是 voice 的分隔键，drum_type 是音色号，⛔ 两者不能混为一谈"
                % (DRUM_TYPE_NAMES[dt], dt, e["axis"], want_axis))
    elif e.get("drum_type"):
        raise SystemExit(
            "ERROR: is_drum=0 的事件带了 drum_type=%r —— 旋律 / tempo 的 "
            "drum_type 必须写 0（手册 §4.1）" % (e.get("drum_type"),))
    if (is_drum or e["kind"] == KIND_TEMPO) and note5 != 0:
        raise SystemExit(
            "ERROR: is_drum=%d / kind=%d 的事件 note_off5=%d —— 鼓与 tempo 没有音高，"
            "这一字段写 0（哨兵 31 只作用于【旋律】；给鼓写 31 会被判据⑤判 RED）"
            % (is_drum, e["kind"], note5))
    return ((tick            << TICK_SH)
            | (inc           << INC_SH)
            | (e["axis"]     << AXIS_SH)
            | (e["vel"]      << VEL_SH)
            | (e["kind"]     << KIND_SH)
            | (e["timbre"]   << TIMBRE_SH)
            | (is_drum       << IS_DRUM_SH)
            | (note5         << NOTE5_SH))
    # bit 6 (guide_only) stays 0 -- 本工具不产生"只亮灯不出声"


def unpack_event(w):
    """Inverse of pack_event -- used by the hex/CSV round-trip self-check."""
    return {
        "tick":    (w >> TICK_SH)    & TICK_MAX,
        "inc":     (w >> INC_SH)     & INC_MAX,
        "axis":    (w >> AXIS_SH)    & 0xF,
        "vel":     (w >> VEL_SH)     & 0xFF,
        "kind":    (w >> KIND_SH)    & 0x3,
        "timbre":  (w >> TIMBRE_SH)  & 0x3,
        "is_drum": (w >> IS_DRUM_SH) & 0x1,
        "note5":   (w >> NOTE5_SH)   & NOTE5_MAX,
    }


def route_pool(axis, is_drum):
    """这条事件该进哪个池子 —— 只看 is_drum，⛔ 永远不看 axis（手册 §4.1）。

    这个函数存在的唯一目的，是让"旋律绝不变鼓"变成【可机械检验】的属性：
    校验器会把 axis 的 16 个取值全跑一遍，证明路由结论与 axis 无关。
    ⚠️ 改前 FPGA 侧靠"axis >= 12 就猜成鼓"，正是这里要根除的东西。
    """
    return "drum" if is_drum else "melody"


def check_drum_split(decoded, stats=None, csv_rows=None, csv_events=None):
    """手册 §4.1 要求校验器加的两条硬检查（外加鼓 ON/OFF 配对等检查）。

    decoded = 从 events.hex【读回来】的 64 位解码结果 —— ⚠️ 必须查产物本身，
    查内存里的事件字典证明不了"写出去的 hex 是对的"。

    ① 任何 is_drum=0 的事件都不许被路由到鼓池（含轴号 0..15 全跑一遍）
    ② is_drum=1 时 inc 必须为 0
    ③ 鼓的每个 note_on 都要有配对的 note_off，且 is_drum / axis / drum_type
       完全相同（note_manager.v:1413-1416 按 (axis,src) 配对；漏了鼓 voice 永久
       held => 鼓的保留池耗尽 => 打一会儿鼓就再也不响了）
    ④ 旋律事件的 is_drum 全 0（数量对得上 stats 里的旋律音符数）
    ⑤ 鼓必须【一件一轴】：drum_type 写在 timbre[8:7]（2 位、0..3），轴号是该件的
       固定轴 12 + drum_type（12/13/14/15，四件互不相同，否则同一轴上的两件互相
       掐 voice）。⚠️ 判据随之从 3 位版的"axis == 轴键"变成这里这条。
    ⑥ 旋律 / tempo 的轴号不许 > 11（旋律与改前一样只用 0..11）
    ⑦ tempo(kind=2) 必须 is_drum=0 且 timbre[8:7]=0（轴号写 0）

    ⚠️ 2 位版与 3 位版的一个关键差别（⛔ 别把旧结论带过来）：bit19 不再兼职
    drum_type 的 MSB，它就是 axis 字段的 LSB。所以本文件对旋律只查 ⑥（轴号 <= 11），
    ⛔ 不查"旋律 bit19 = 0"（奇数轴号天然把它置 1，那条无法成立也无害）。

    任何一条不满足 => SystemExit。返回统计 dict 供 report / stdout 使用。
    """
    n_drum = n_mel = 0
    drum_on = drum_off = tempo = 0
    type_hist = {}
    openq = {}                      # (axis, drum_type) -> [(tick, idx), ...]
    orphan_off = []
    mel_violation = []

    for i, d in enumerate(decoded):
        # ---- 硬检查 ①：is_drum=0 => 不许进鼓池；且与 axis 无关 ----
        want_route = "drum" if d["is_drum"] else "melody"
        if route_pool(d["axis"], d["is_drum"]) != want_route:
            raise SystemExit(
                "ERROR: 记录 %d 的路由结论与 is_drum 不一致 (axis=%d is_drum=%d)"
                % (i, d["axis"], d["is_drum"]))
        if d["is_drum"] == 0 and route_pool(d["axis"], 0) != "melody":
            mel_violation.append(i)
        # ---- 硬检查 ②：is_drum=1 => inc 必须为 0 ----
        if d["is_drum"] == 1 and d["inc"] != 0:
            raise SystemExit(
                "ERROR: 记录 %d 是鼓 (is_drum=1) 但 inc=%d != 0 —— "
                "手册 §4.1 硬要求 inc 写 0" % (i, d["inc"]))
        # ---- 硬检查 ⑤：一件一轴（轴号 = 12 + drum_type） ----
        if d["is_drum"] == 1:
            dt = rec_drum_type(d["axis"], d["timbre"])
            if d["axis"] != DRUM_AXIS_OF[dt]:
                raise SystemExit(
                    "ERROR: 记录 %d 的鼓件 %s(drum_type=%d) 落在 axis=%d，应为 %d "
                    "（= 12 + drum_type）。四件鼓必须一件一轴，否则同轴两件的 OFF "
                    "会互相清 voice"
                    % (i, DRUM_TYPE_NAMES[dt], dt, d["axis"], DRUM_AXIS_OF[dt]))

        if d["kind"] == KIND_TEMPO:
            # ---- 硬检查 ⑦：tempo 必须 is_drum=0、timbre[8:7]=0 ----
            # ⚠️ tempo 的轴号写 0 ⇒ bit19 也自然是 0（2 位版里 bit19 与 drum_type
            #    无关，这里只是把"鼓字段全 0"一次查清）。
            if d["is_drum"] != 0 or d["timbre"] != 0 or d["axis"] != 0:
                raise SystemExit(
                    "ERROR: 记录 %d 是 tempo(kind=2)，但 is_drum=%d timbre=%d axis=%d "
                    "（要求 is_drum=0 / timbre=0 / axis=0）—— 手册 §4.1 要求鼓字段写 0"
                    % (i, d["is_drum"], d["timbre"], d["axis"]))
            # ---- 硬检查 ⑧：tempo 没有音高 => note_off5 写 0 ----
            if d["note5"] != 0:
                raise SystemExit(
                    "ERROR: 记录 %d 是 tempo(kind=2) 但 note_off5=%d —— tempo 没有"
                    "音高，写 0（哨兵只作用于旋律）" % (i, d["note5"]))
            tempo += 1
            continue
        # ---- 硬检查 ⑥：旋律只用 0..11（12 条，与改前一致） ----
        if d["is_drum"] == 0 and d["axis"] > MELODY_AXIS_MAX:
            raise SystemExit(
                "ERROR: 记录 %d 是旋律 (is_drum=0) 却用了 axis=%d —— 旋律轴号 "
                "只用 0..%d（与改前一致；鼓用 12..15，⛔ 不让轴给鼓）"
                % (i, d["axis"], MELODY_AXIS_MAX))

        if d["is_drum"]:
            # ---- 硬检查 ⑧：鼓没有音高 => note_off5 必须写 0（⛔ 不是哨兵 31） ----
            if d["note5"] != 0:
                raise SystemExit(
                    "ERROR: 记录 %d 是鼓但 note_off5=%d —— 鼓的所谓音高是 GM 件号、"
                    "不是键盘音高，note_off5 写 0（哨兵只作用于旋律）" % (i, d["note5"]))
            n_drum += 1
            key = (d["axis"], d["timbre"])
            if d["kind"] == KIND_ON:
                drum_on += 1
                openq.setdefault(key, []).append((d["tick"], i))
                dt = rec_drum_type(d["axis"], d["timbre"])
                type_hist[dt] = type_hist.get(dt, 0) + 1
            else:
                drum_off += 1
                q = openq.get(key)
                if q:
                    q.pop(0)
                else:
                    orphan_off.append((i, key))
        else:
            n_mel += 1

    # ---- 硬检查 ①（穷举）：axis 0..15 全都不能把旋律送进鼓池 ----
    for ax in range(16):
        if route_pool(ax, 0) != "melody":
            raise SystemExit("ERROR: axis=%d 的旋律被路由到鼓池" % ax)
    if mel_violation:
        raise SystemExit("ERROR: %d 条 is_drum=0 的事件落进了鼓池：%r"
                         % (len(mel_violation), mel_violation[:5]))
    # ---- 硬检查 ③：鼓的 ON/OFF 配对 ----
    leftover = [(k, v) for k, v in openq.items() if v]
    if leftover or orphan_off:
        raise SystemExit(
            "ERROR: 鼓事件配对失败 —— 有 ON 无 OFF: %r ; 有 OFF 无 ON: %r "
            "（漏一个 OFF，note_manager 的 (axis,src) 就配不上，"
            "鼓 voice 会永久 held）" % (leftover[:5], orphan_off[:5]))
    # ---- 硬检查 ④：旋律 is_drum 全 0 ----
    if stats is not None and stats.get("drum_on_events") is not None:
        want_drum = 2 * stats.get("drum_notes", 0)
        if n_drum != want_drum:
            raise SystemExit(
                "ERROR: hex 里 is_drum=1 的记录 %d 条，但鼓音符 %d 个"
                "（应为 %d 条）—— 有鼓事件丢了标志位"
                % (n_drum, stats.get("drum_notes", 0), want_drum))
        want_mel = 2 * stats.get("notes", 0)
        if n_mel != want_mel:
            raise SystemExit(
                "ERROR: hex 里 is_drum=0 的音符记录 %d 条，但旋律音符 %d 个"
                "（应为 %d 条）—— 旋律事件不许带 is_drum=1"
                % (n_mel, stats.get("notes", 0), want_mel))

    return {"records": len(decoded), "drum_records": n_drum,
            "melody_records": n_mel, "drum_on": drum_on,
            "drum_off": drum_off, "tempo_records": tempo,
            "drum_type_hist": type_hist}


def _load_score_word():
    """尽力加载 esp32/tools/score_word.py（只读，⛔ 不改它）。

    为什么跨文件校验：note_off5 只占 5 位，越界值（例如 32）进
    score_word.pack_word 会被【静默掩码截断】—— 字面上完全看不出来，灯却指错
    键。所以"note_off5 越界必须被拒"这条判据只能在【入参层】生效。这里调官方
    那份 validate_fields，而不是在本文件另抄一套规则（两套规则迟早漂移）。

    找不到 / 导入失败 => 返回 (None, 原因)：本工具不因此罢工 —— 它原本就不依赖
    ESP32 侧的文件，交叉校验是加强项，不是前置依赖。
    """
    path = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        os.pardir, "esp32", "tools", "score_word.py"))
    if not os.path.isfile(path):
        return None, "找不到 %s" % path
    try:
        spec = importlib.util.spec_from_file_location("score_word_xcheck", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, path
    except Exception as exc:            # 交叉校验失败不阻断主流程，但要说出原因
        return None, "导入失败：%r" % (exc,)


def cross_check_with_score_word(events):
    """把每条事件按【入参】喂给 score_word.validate_fields（手册 §4.2）。

    返回 (问题列表, 说明)。问题列表非空时由调用方报错 —— 这正是 note_off5=32
    这种"进 pack_word 就被静默截成 0"的越界能被打出来的唯一一层。
    """
    mod, note = _load_score_word()
    if mod is None:
        return [], "score_word.validate_fields 未调用（%s）" % note
    if not hasattr(mod, "validate_fields"):
        return [], ("score_word.py 没有 validate_fields（版本旧？）"
                    "：跳过入参层交叉校验")
    # ⚠️ score_word.py 是【另一个文件、由别人同时改】。它的 drum_type 位宽与本文件
    #    不一致时，把一个超出它位宽的 drum_type 喂进去会被它当成越界 => 本工具会假
    #    报错、连 events.hex 都产不出来。所以【按它自己的 mask 判断口径是否一致】：
    #    不一致 => 只喂它装得下的那几位（其余字段照查），并把"哪一条没查"明说出来。
    #    ⛔ 不静默降级 —— 降级必须打印出来（两侧都在回退期，两边都可能领先）。
    dt_mask = None
    try:
        dt_mask = int(getattr(mod, "MASK_DRUMTYPE"))
    except (AttributeError, TypeError, ValueError):
        dt_mask = None
    degrade = ""
    if dt_mask is not None and dt_mask != DRUM_TYPE_MASK:
        degrade = ("（⚠️ 两文件 drum_type 位宽不一致：score_word.py = %d 位 "
                   "MASK=0x%X，本工具 = %d 位 => 只喂了它装得下的位，"
                   "位宽那一条未在入参层校验）"
                   % (dt_mask.bit_length(), dt_mask, DRUM_TYPE_W))
    ps = []
    tried = 0
    try:
        for i, e in enumerate(events):
            is_drum = e.get("is_drum", 0)
            dt = e.get("drum_type", e["timbre"]) if is_drum else 0
            if dt_mask is not None:
                dt &= dt_mask
            tried += 1
            ps += ["记录 %d: %s" % (i, p) for p in mod.validate_fields(
                e["tick"], e["inc"], e["axis"], e["vel"], e["kind"],
                0 if is_drum else e["timbre"],
                is_drum=is_drum, drum_type=dt,
                note_off5=e.get("note5", 0))]
            if len(ps) > 20:            # 够多了，别把屏幕刷爆
                break
    except Exception as exc:
        # ⚠️ score_word.py 是另一个文件、可能正在被别人改：签名变了（TypeError）
        #    只是其中一种，2026-10-16 实测还遇到它自己的回退半成品 ——
        #    validate_fields 里引用了还没定义的 MASK_DRUMTYPE_LOW => NameError。
        #    交叉校验是【加强项】，⛔ 不是前置依赖：任何异常都降级成"跳过"并明说
        #    原因，⛔ 不让本工具因为另一个文件的状态而罢工（那会让 events.hex
        #    根本产不出来）。⚠️ 但降级必须打印，⛔ 不静默。
        #    ⚠️ 注意这里 catch 的是 BaseException 之外的 Exception：本工具自己的
        #    SystemExit【不被捕获】（SystemExit 继承 BaseException），所以
        #    "入参层校验真的报了问题" 仍然照常硬失败。
        return [], ("score_word.validate_fields 调用失败（%s: %r）"
                    "：跳过入参层交叉校验（已试 %d 条）"
                    % (type(exc).__name__, exc, tried))
    return ps, "%s（入参层校验 %d 条事件）%s" % (note, len(events), degrade)


def verify_hex_roundtrip(events, path):
    """Re-read events.hex and prove it decodes back to what we intended.

    WHY THIS EXISTS: the tick overflow was invisible because nobody ever read
    events.hex back.  The audition tool reads the CSV, so a correct CSV proved
    nothing about the hex.  This closes that hole: it compares the hex against
    both the in-memory events AND the CSV, so the two outputs cannot drift.

    2026-10-16：再加 drumsplit 硬检查（见 check_drum_split），查的是【读回来
    的 hex】而不是内存里的事件。
    """
    with io.open(path, "r", encoding="ascii") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    if len(lines) != len(events):
        raise SystemExit("ERROR: events.hex has %d records, expected %d"
                         % (len(lines), len(events)))
    decoded = [unpack_event(int(ln, 16)) for ln in lines]
    bad = 0
    for i, (d, e) in enumerate(zip(decoded, events)):
        want = {"tick": e["tick"], "inc": e["inc"], "axis": e["axis"],
                "vel": e["vel"], "kind": e["kind"], "timbre": e["timbre"],
                "is_drum": e.get("is_drum", 0), "note5": e.get("note5", 0)}
        if d != want:
            if bad < 3:
                print("ERROR: events.hex record %d decodes to %r, expected %r"
                      % (i, d, want))
            bad += 1
    if bad:
        raise SystemExit("ERROR: events.hex round-trip failed on %d record(s)"
                         % bad)
    # the CSV must agree too, otherwise "the CSV looks right" stays misleading
    csv_path = os.path.join(os.path.dirname(path), "events.csv")
    if os.path.isfile(csv_path):
        with io.open(csv_path, encoding="utf-8") as f:
            rows = list(csv.reader(f))
        body = [r for r in rows[1:] if r]
        if len(body) != len(events):
            raise SystemExit("ERROR: events.csv has %d rows, expected %d"
                             % (len(body), len(events)))
        for i, (r, e) in enumerate(zip(body, events)):
            kind = {"on": KIND_ON, "off": KIND_OFF,
                    "tempo": KIND_TEMPO}[r[2]]
            # ⚠️ 第 9/10 列（is_drum / note_off5）是新增的，加在【末尾】，
            #    所以原来按下标 0..7 读 CSV 的工装（试听、灌谱）不受影响。
            # note_off5 拿 CSV 里的【完整音符号】重算一遍，顺便证明哨兵规则正确。
            # ⚠️ 只有【旋律】参与重算：鼓与 tempo 没有音高，一律写 0。
            want_n5 = (note_off5_for(int(r[3]))
                       if (int(r[8]) == 0 and r[2] != "tempo") else 0)
            if (int(r[1]) != e["tick"] or kind != e["kind"]
                    or int(r[4]) != e["inc"] or int(r[5]) != e["vel"]
                    or int(r[6]) != e["axis"] or int(r[7]) != e["timbre"]
                    or int(r[8]) != e.get("is_drum", 0)
                    or int(r[9]) != want_n5):
                raise SystemExit(
                    "ERROR: events.csv row %d disagrees with events.hex "
                    "(csv=%r)" % (i, r))
    return len(lines)


def write_hex(events, path):
    with io.open(path, "w", encoding="ascii", newline="\n") as f:
        for e in events:
            f.write("%016x\n" % pack_event(e))


def write_csv(events, path):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        # ⚠️ is_drum / note_off5 两列加在【末尾】：原来按下标 0..7 读 CSV 的
        #    工装（试听、灌谱）不受影响。timbre 列对鼓事件含义是 drum_type。
        f.write("idx,tick,kind,midi,inc,velocity,axis,timbre,"
                "is_drum,note_off5\n")
        for i, e in enumerate(events):
            k = {KIND_ON: "on", KIND_OFF: "off", KIND_TEMPO: "tempo"}[e["kind"]]
            f.write("%d,%d,%s,%d,%d,%d,%d,%d,%d,%d\n" % (
                i, e["tick"], k,
                e.get("midi", -1), e["inc"], e["vel"], e["axis"],
                e["timbre"], e.get("is_drum", 0), e.get("note5", 0)))


def write_drum_csv(events, path):
    """⭐ 鼓事件**另存一份**（⭐ 给 `tools/evt2wav.py --drums` 用）—— `U-16b` ✅

    ⚠️ **为什么要另存**：`evt2wav.py` 把 hex 里的旋律铺成键盘音高来渲染；
       鼓**没有键盘音高语义**，混进去会白烧 voice ⇒ ⭐ 单独给一份 `tick,note,vel`。
    ⚠️ **只用三列** —— ⛔ 不带 track 名：⭐ 轨名里可能有**逗号 / 中文**
       ⇒ ⭐ 解析会变脆（⭐ 而这三列已经够渲染了）✅
    📌 **数据源 = `events` 里 `is_drum == 1` 的那些** —— ⚠️ **2026-10-18 合并 ESP32 线后
       数据模型变了**：ESP32 版把鼓**放进主流**并打 `is_drum=1`（⛔ 不再有独立的
       `stats["drum_events"]` 列表）⇒ ⭐ 这里从 `events` 里筛，产物格式**逐字节不变** ✅
    """
    rows = [e for e in events if e.get("is_drum", 0)]
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("tick,note,vel\n")
        for e in sorted(rows, key=lambda x: (x["tick"], x.get("midi", 0))):
            f.write("%d,%d,%d\n" % (e["tick"], e.get("midi", 0), e["vel"]))
    return len(rows)


def write_report(stats, path, args):
    L = []
    L.append("mid2evt report")
    L.append("=" * 52)
    L.append("input        : %s" % args.input)
    L.append("transpose    : %+d semitones" % args.transpose)
    L.append("")
    L.append("pitch tracks : %d" % len(stats["tracks"]))
    for nm, axis, n in stats["per_track"]:
        L.append("    axis %-2d %-16s %5d notes" % (axis, nm, n))
    L.append("")
    # ⭐ 音色分配（⚠️ 是【猜】的 ⇒ 必须打出来给人核对，⛔ 不静默）
    L.append("TIMBRE assignment (GUESSED from track name -- verify this!):")
    for axis, nm, tid, why in stats.get("timbre_of_axis", []):
        L.append("    axis %-2d %-16s -> %-6s  (%s)"
                 % (axis, nm, TIMBRE_NAMES[tid], why))
    L.append("  Override any of them with:  --timbre AXIS=NAME,...")
    L.append("  Names: %s" % ", ".join(TIMBRE_NAMES[k] for k in sorted(TIMBRE_NAMES)))
    L.append("")
    if stats["drum_tracks"]:
        # 改前这里写的是"鼓轨被排除、不写进 events.hex"。2026-10-16 起鼓也输出。
        L.append("DRUM tracks (ALSO emitted into events.hex, with is_drum=1):")
        for s in stats["drum_tracks"]:
            L.append("    %s" % s)
        L.append("  three rules, OR'd: (1) --drum-track 显式指定, "
                 "(2) track name, (3) MIDI channel %d" % (GM_DRUM_CHANNEL + 1))
        for nm, n, reason in stats.get("drum_info", []):
            L.append("    %-16s %5d notes  (%s)" % (nm, n, reason))
        L.append("  drum records: %d note_on + %d note_off = %d"
                 % (stats.get("drum_on_events", 0),
                    stats.get("drum_off_events", 0),
                    stats.get("drum_on_events", 0)
                    + stats.get("drum_off_events", 0)))
        L.append("  every drum record: is_drum=1, inc=0, "
                 "drum_type=timbre[8:7] (2 位, 4 件)")
        L.append("  note_off 与 note_on 带【同一个】drum_type 与同一个 axis"
                 "（否则鼓 voice 永久 held）")
        L.append("  一件一轴（note_manager.v:1413-1416 的 note_off 按 (axis,src) 清"
                 " voice，")
        L.append("  四件鼓的 src 全是 SRC_KDRUM ⇒ 同轴两件会互相清）:")
        L.append("    轴号 = 12 + drum_type（一件一轴：12/13/14/15）")
        for dt in sorted(DRUM_AXIS_OF):
            L.append("    %-6s drum_type=%d -> axis %d"
                     % (DRUM_TYPE_NAMES[dt], dt, DRUM_AXIS_OF[dt]))
        used = sorted(stats.get("drum_axes_used", ()))
        L.append("  本谱实际用到的鼓轴号: %s（旋律轴号一律 <= %d，两段不重叠）"
                 % (used if used else "无", MELODY_AXIS_MAX))
        # drum_type 分布
        tc = stats.get("drum_type_counts", {})
        L.append("  drum_type distribution (counted on note_on):")
        for dt in sorted(DRUM_TYPE_NAMES):
            L.append("    %-6s (%d) : %d"
                     % (DRUM_TYPE_NAMES[dt], dt, tc.get(dt, 0)))
        # GM 音符号 -> drum_type 明细（表外的必须在报告里列出来，手册 §4.3）
        #   ⭐ 这里就是"有意归类"与"没认出来"的分界读数：映射表里显式列出的
        #      （含镲族 8 个音高 -> HiHat）在这里显示为普通的 -> HiHat (2)；
        #      表外的才带 "<== 表外，仍先归 Tom" 标记，并在下面逐个重列一遍。
        hist = stats.get("drum_note_hist", {})
        if hist:
            L.append("  GM percussion notes actually present:")
            for note in sorted(hist):
                dt, mapped = drum_type_for_note(note)
                L.append("    MIDI %-3d x%-4d -> %-6s (%d)%s"
                         % (note, hist[note], DRUM_TYPE_NAMES[dt], dt,
                            "" if mapped else "   <== 表外，仍先归 Tom（兜底）"))
            n_cy = sum(hist[n] for n in hist if n in CYMBAL_NOTES)
            L.append("    其中镲族（映射表里【显式列出】的 8 个音高）事件 %d 个：%s"
                     % (n_cy, "、".join("MIDI %d x%d" % (n, hist[n])
                                        for n in sorted(CYMBAL_NOTES) if n in hist)
                        or "本谱没有"))
            L.append("    ⇒ 镲族是【有意归类】到 HiHat(2)，⛔ 不是表外兜底；"
                     "表外的只有上面带标记的那些")
        um = stats.get("drum_unmapped", {})
        if um:
            L.append("  WARNING: %d 个 GM 音符号不在映射表里（表见手册 §4.3 / "
                     "FPGA 线回函第三轮 §一），" % len(um))
            L.append("    按既有纪律【逐个列出来】并仍先归 Tom：")
            for n in sorted(um):
                L.append("      MIDI %-3d x%d" % (n, um[n]))
            L.append("    ⚠️ 兜底只保节奏、不保音色：若谱里真有这些件，"
                     "请把音高加进映射表。")
        L.append("")
        L.append("  drum note_off5: 一律 0（鼓没有音高 —— GM 件号不是键盘音高；"
                 "哨兵只作用于旋律）")
        L.append("  旋律 note_off5: 音高 %d..%d => MIDI - %d（0..%d）；越界 => %d（哨兵）"
                 % (NOTE5_PITCH_MIN, NOTE5_PITCH_MAX, BASE_NOTE,
                    NOTE5_SENTINEL - 1, NOTE5_SENTINEL))
        L.append("                  ⛔ 不再钳到 0（0 = A2 = 真实的键 5，会点错灯）")
        L.append("  drum velocity: %s"
                 % ", ".join("%s=%d" % (DRUM_TYPE_NAMES[dt], DRUM_VEL[dt])
                             for dt in sorted(DRUM_VEL)))
    else:
        L.append("DRUM tracks : none detected")
    if stats.get("drum_forced_unmatched"):
        L.append("WARNING: --drum-track 有 %d 项没匹配到任何轨：%s"
                 % (len(stats["drum_forced_unmatched"]),
                    ", ".join(stats["drum_forced_unmatched"])))
        L.append("         这一项【没生效】；轨序号是 0 起的 MIDI 轨顺序"
                 "（含第一条常为空的 Tempo/指挥轨）。")
    L.append("")
    if stats["empty_tracks"]:
        L.append("EMPTY tracks (no notes; no axis id assigned): %d"
                 % len(stats["empty_tracks"]))
        for s in stats["empty_tracks"]:
            L.append("    %s" % s)
        L.append("  Guitar Pro exports placeholder/duplicate tracks; giving them")
        L.append("  an axis would leave gaps in the numbering for no benefit.")
        L.append("")
    if stats["axis_overflow"]:
        L.append("WARNING: %d 条旋律轨要分轴号，但旋律轴号只有 0..%d 这 %d 个"
                 "（与改前一致）"
                 % (stats["axis_overflow"], MELODY_AXIS_MAX, MELODY_AXIS_N))
        L.append("         超出的轨会【与前面的轨共用轴号】：同轴同源 "
                 "(SRC_SCORE) 的")
        L.append("         note_off 会互相清 voice。请把轨数压到 %d 以内，"
                 "或向 FPGA 侧申请扩轴号位宽。" % MELODY_AXIS_N)
        L.append("")
    L.append("notes kept   : %d melody + %d drum"
             % (stats["notes"], stats.get("drum_notes", 0)))
    L.append("events       : %d note records (1 note_on + 1 note_off each; "
             "%d melody + %d drum)"
             % (stats["events"] - stats.get("tempo_events", 0),
                2 * stats["notes"], 2 * stats.get("drum_notes", 0)))
    L.append("bit split    : is_drum=1 共 %d 条, is_drum=0 共 %d 条 "
             "(+ %d tempo)"
             % (stats.get("drum_on_events", 0) + stats.get("drum_off_events", 0),
                stats["events"] - stats.get("tempo_events", 0)
                - stats.get("drum_on_events", 0)
                - stats.get("drum_off_events", 0),
                stats.get("tempo_events", 0)))
    L.append("               new fields: bit5 is_drum, "
             "drum_type=timbre[8:7] (2 位), bits[4:0] note_off5")
    L.append("velocity     : 真实力度（⚠️ 听觉行为变更：改前一律常量 130）")
    L.append("               旋律 = MIDI 原始力度；鼓 = 鼓机力度 %s；"
             "note_off 一律 0"
             % "/".join(str(DRUM_VEL[k]) for k in sorted(DRUM_VEL)))
    L.append("               鼓力度逐件：%s"
             % ", ".join("%s=%d" % (DRUM_TYPE_NAMES[dt], DRUM_VEL[dt])
                         for dt in sorted(DRUM_VEL)))
    L.append("unplayable   : 判为不可弹（旋律 note_off5 写 %d）的条数 = %d（旋律音符；"
             % (NOTE5_SENTINEL, stats.get("unplayable", 0)))
    L.append("               on/off 各一条 => %d 条事件，判据⑤ 就按事件数报）"
             % (2 * stats.get("unplayable", 0)))
    L.append("               可弹音域 = MIDI %d..%d（A2..D#4，%d 个键）；"
             "越界写 %d = 不点灯"
             % (NOTE5_PITCH_MIN, NOTE5_PITCH_MAX,
                NOTE5_PITCH_MAX - NOTE5_PITCH_MIN + 1, NOTE5_SENTINEL))
    L.append("               鼓 / tempo 的 note_off5 一律 0（没有音高，不参与哨兵规则）")
    L.append("de-duplicated: %d  (same tick + same pitch collapsed to one;"
             % stats["dedup"])
    L.append("                identical pitch means no musical loss, and it")
    L.append("                avoids two voices beating at the same frequency)")
    L.append("pitch range  : MIDI %d .. %d" % (stats["min_midi"], stats["max_midi"]))
    L.append("length       : %d ticks = %.2f bars (4/4 @ PPQN %d)"
             % (stats["max_tick"], stats["max_tick"] / float(PPQN * 4), PPQN))
    tp = stats.get("tempos") or []
    if tp:
        L.append("")
        L.append("TEMPO map (from the MIDI set_tempo events -- NOT assumed):")
        for tk, us in tp:
            bpm = 60_000_000.0 / us
            L.append("    tick %-8d %6.2f BPM  -> tick_inc %d"
                     % (tk, bpm, tick_inc_for_bpm(bpm)))
        L.append("  ⭐ emitted into events.hex as %d kind=2 record(s)"
                 % stats.get("tempo_events", 0))
        L.append("     => the stream is SELF-CONTAINED: the FPGA no longer needs")
        L.append("        the .mid to know how fast to play.")
        if len(set(u for _, u in tp)) > 1:
            L.append("  NOTE: this score CHANGES tempo.  Any renderer must follow")
            L.append("        this map, not a single constant BPM.")
    if stats.get("max_tick_inc", 0) == 0:
        L.append("")
        L.append("WARNING: no tempo event emitted (max_tick_inc = 0).")
        L.append("         tick_inc = 0 means beat_gen's clock STANDS STILL.")
    io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")


def parse_timbre_overrides(s):
    """Parse "0=GUITAR,4=BASS" -> {0: GUITAR_ID, 4: BASS_ID}.  None if empty."""
    if not s:
        return None
    out = {}
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            raise SystemExit("ERROR: --timbre entry %r is not AXIS=NAME" % part)
        a, name = part.split("=", 1)
        try:
            axis = int(a.strip())
        except ValueError:
            raise SystemExit("ERROR: --timbre axis %r is not an integer" % a)
        key = name.strip().upper()
        if key not in TIMBRE_BY_NAME:
            raise SystemExit("ERROR: --timbre name %r unknown; use one of %s"
                             % (name, "/".join(TIMBRE_BY_NAME)))
        out[axis] = TIMBRE_BY_NAME[key]
    return out


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description="Standard MIDI -> FPGA events")
    ap.add_argument("input", help="a .mid file exported from Guitar Pro")
    ap.add_argument("--outdir", default="build/score")
    ap.add_argument("--transpose", type=int, default=0, help="semitones")
    ap.add_argument("--timbre", default=None,
                    help="override the guessed timbre per axis, e.g. "
                         "0=GUITAR,4=BASS (names: BASS/GUITAR/PIANO/PAD)")
    # 新增（默认 None = 行为与改前一致，老调用方式照跑）
    ap.add_argument("--drum-track", default=None, dest="drum_track",
                    help="explicitly name the drum track(s): a track index "
                         "(0-based) or a track-name substring, comma separated, "
                         "e.g. 4  或  Drums  或  4,Drums,Perc  "
                         "(手册 §4.1 第三条鼓识别规则：与轨名/通道【取或】)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit("ERROR: no such file: %s" % args.input)

    overrides = parse_timbre_overrides(args.timbre)
    drum_tracks = parse_drum_track_spec(args.drum_track)
    division, fmt, tempos, tracks = parse_midi(args.input)
    if not tracks:
        raise SystemExit("ERROR: no tracks found in %s" % args.input)

    events, stats = build_events(tracks, division, tempos, args.transpose,
                                 overrides, drum_tracks)
    if not events:
        raise SystemExit("ERROR: no note events produced (no notes at all?)")

    # 手册 §4.2：note_off5 这类"5 位装不下 32"的越界，只能在【入参层】拦 ——
    # score_word.pack_word 会把它静默截断（字面看不出、灯却指错键）。
    # ⇒ 产出文件【之前】先用官方那份 validate_fields 过一遍，有问题就别落盘。
    xp, xnote = cross_check_with_score_word(events)
    if xp:
        raise SystemExit("ERROR: score_word.validate_fields 报了 %d 个问题：\n  %s"
                         % (len(xp), "\n  ".join(xp[:20])))

    os.makedirs(args.outdir, exist_ok=True)
    hex_path = os.path.join(args.outdir, "events.hex")
    write_hex(events, hex_path)
    write_csv(events, os.path.join(args.outdir, "events.csv"))
    write_report(stats, os.path.join(args.outdir, "report.txt"), args)
    #  ⭐⭐ 2026-10-18（合并 ESP32 线后补回）：⭐ **鼓事件另存一份** ⇒
    #     ⭐ 试听（`evt2wav.py --drums`）时能把鼓混回去 ✅
    #     📌 数据源 = `events` 里 `is_drum==1` 的（⭐ ESP32 版把鼓放进主流了）
    n_drum = write_drum_csv(events,
                            os.path.join(args.outdir, "events_drum.csv"))

    # ⭐ 回读校验：证明写出去的 hex 能与 CSV / 内存事件解码一致。
    #   ⚠️ 不能省 —— tick 回绕正是因为"从来没人读回 hex"才隐藏了很久。
    n = verify_hex_roundtrip(events, hex_path)
    # 手册 §4.1 的校验器硬检查（查的是【读回来的 hex】）：is_drum=0 不许进鼓池、
    # is_drum=1 必须 inc=0、鼓的 ON/OFF 必须成对且 drum_type 相同、旋律全 0。
    dec = None
    with io.open(hex_path, encoding="ascii") as _f:
        dec = check_drum_split(
            [unpack_event(int(ln, 16)) for ln in _f.read().split()], stats)

    print("format=%d division=%d tracks=%d" % (fmt, division, len(tracks)))
    print("wrote %s/events.hex  events.csv  events_drum.csv  report.txt" % args.outdir)
    print("notes=%d melody + %d drum (dropped_drum=%d) events=%d dedup=%d "
          "tempo_records=%d"
          % (stats["notes"], stats["drum_notes"], stats["dropped_drum"],
             stats["events"], stats["dedup"], stats["tempo_events"]))
    print("drum split  : is_drum=1 %d records (%d on / %d off), is_drum=0 %d"
          % (dec["drum_records"], dec["drum_on"], dec["drum_off"],
             dec["melody_records"]))
    print("drum_type   : %s" % ", ".join(
        "%s(%d)=%d" % (DRUM_TYPE_NAMES[t], t, c)
        for t, c in sorted(dec["drum_type_hist"].items())))
    print("drum inc    : all zero = %s"
          % all(e["inc"] == 0 for e in events if e.get("is_drum") == 1))
    print("drum axis   : %s" % ", ".join(
        "%s(dt%d)->%d" % (DRUM_TYPE_NAMES[t], t, DRUM_AXIS_OF[t])
        for t in sorted(DRUM_AXIS_OF)))
    print("drum axis ok: 一件一轴（轴号 = 12 + drum_type）全对 = %s，"
          "四件轴互不相同 = %s"
          % (all(e["axis"] == DRUM_AXIS_OF[e["drum_type"]]
                 for e in events if e.get("is_drum") == 1),
             len(set(DRUM_AXIS_OF.values())) == DRUM_TYPE_N))
    print("drum dt rng : drum_type 全落在 0..%d = %s（⛔ 不取 bit19）"
          % (DRUM_TYPE_MASK,
             all(0 <= e["drum_type"] <= DRUM_TYPE_MASK
                 for e in events if e.get("is_drum") == 1)))
    print("drum vel    : %s" % ", ".join(
        "%s=%d" % (DRUM_TYPE_NAMES[t], DRUM_VEL[t]) for t in sorted(DRUM_VEL)))
    print("melody vel  : 真实 MIDI 力度（min %d / max %d），note_off 一律 0"
          % (min([e["vel"] for e in events
                  if e.get("is_drum") == 0 and e["kind"] == KIND_ON] or [0]),
             max([e["vel"] for e in events
                  if e.get("is_drum") == 0 and e["kind"] == KIND_ON] or [0])))
    print("note_off5   : 判为不可弹（旋律写 %d）的条数 = %d 个旋律音 / %d 条事件；"
          "可弹音域 MIDI %d..%d"
          % (NOTE5_SENTINEL, stats.get("unplayable", 0),
             2 * stats.get("unplayable", 0),
             NOTE5_PITCH_MIN, NOTE5_PITCH_MAX))
    print("             鼓 / tempo 的 note_off5 一律 0 = %s"
          % all(e["note5"] == 0 for e in events
                if e.get("is_drum") == 1 or e["kind"] == KIND_TEMPO))
    print("melody axis : 0..%d（%d 条；≤ %d 全部成立 = %s）"
          % (MELODY_AXIS_MAX, MELODY_AXIS_N, MELODY_AXIS_MAX,
             all(e["axis"] <= MELODY_AXIS_MAX for e in events
                 if e.get("is_drum") == 0)))
    print("score_word  : %s" % xnote)
    print("timbre      : %s" % ", ".join(
        "axis%d=%s" % (a, TIMBRE_NAMES[t])
        for a, _n, t, _w in stats["timbre_of_axis"]))
    print("hex round-trip OK: %d records, max tick %d (%.1f bars), max inc %d"
          % (n, stats["max_tick"],
             stats["max_tick"] / float(PPQN * 4),
             max(e["inc"] for e in events)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
