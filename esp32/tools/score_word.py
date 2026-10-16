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

位域（硬契约）
================================================================================
2026-10-16 起按《ESP32侧修改手册-鼓与旋律分离-最终版-20261016.md》§二 的新表。
2026-10-16 第三轮【回退】（FPGA 线收回"鼓扩到 8 件"，我方照办）：
    出处：《FPGA线回函-第三轮-收回8件鼓-20261016.md》§1.1/§1.3
          《ESP32侧回函-第三轮-axis确认与回退-20261016.md》§二
    · drum_type 回到【2 位 = timbre[8:7]】：0 Kick · 1 Snare · 2 HiHat · 3 Tom
    · 鼓的 axis 回到【一件一轴 12/13/14/15】：Kick 12 · Snare 13 · HiHat 14 · Tom 15
    · 已【删除】且不许再加回来：3 位 drum_type（MSB 落在 bit19）、bit19 双语义、
      dt 键 drum_axis_key = ((dt & 3) << 1) | (dt >> 2)（0,2,4,6,1,3,5,7）。
      理由：FPGA 只有 4 件鼓音色；那 4 个新 inc 只是同一个纯音引擎在高频的
      4 个不同音高，不是 4 件新音色（FPGA 线回函 §1.1）。

    bit 63..44   tick       20 bit   音乐时间，PPQN=960
    bit 43..23   inc        21 bit   phase_inc；kind==2 时重解释为 tick_inc
                                      旋律的【唯一】音高来源；
                                      鼓事件必须写 0（音高由 FPGA 按 drum_type 查表给）
    bit 22..19   axis        4 bit   轴号 0..15，voice 的分隔键（note_off 按
                                      (axis, src) 匹配清 voice）
                                      · is_drum=0：旋律用 0..11（MELODY_AXIS_MAX）
                                      · is_drum=1：鼓用 12..15，一件一轴
                                        Kick 12 · Snare 13 · HiHat 14 · Tom 15
                                        => axis - 12 必须 == drum_type（硬检查）
                                      ⚠️ "axis 落在某个范围里才算鼓"的假设已全部废除，
                                         判鼓一律只看 is_drum(bit5)（轴号只是定位键）。
    bit 18..11   vel         8 bit   力度
    bit 10..9    kind        2 bit   0=note_on 1=note_off 2=tempo 3=未使用
    bit  8..7    timbre      2 bit   旋律：音色 0..3
                                      鼓事件：drum_type（2 位，与 timbre 是【同一个
                                      字段的两种解释】—— 鼓的音色由鼓件决定，timbre
                                      对鼓没有意义，正好拿这 2 位装件号，不占新位）
    bit  6       guide_only  1 bit   仅指引：只亮灯不出声（已用）
    bit  5       is_drum     1 bit   显式鼓标志（判鼓【只看这一位】）
    bit  4..0    note_off5   5 bit   音符号偏移 = MIDI音符号 - 45
                                      0..30 = 键盘上真实存在的键（MIDI 45..75）
                                      31    = 哨兵【键盘上没有这个键 => 不点灯】
                                      ⛔ 超出可弹音域一律写 31，不许钳到 0
                                         （0 = A2 = 指板表里真实的键 5，会点亮错的灯）

    drum_type（2 位 = 0..3 四件）：0 Kick · 1 Snare · 2 HiHat · 3 Tom

为什么鼓轴是 12/13/14/15（一件一轴，⛔ 不是"随便挑四条轴"）
    note_manager.v:1413-1416 的 note_off 按 (axis, src) 清 voice，而所有鼓的 src
    都是 SRC_KDRUM => 同一条轴上的两件鼓会【互相清】（鼓被切碎 / 挂音）。
    => 四件鼓必须落在四条互不相同的轴上；12..15 就是两边约定的那四条
       （FPGA 线回函 §1.3 提出，我方确认见 ESP32侧回函-第三轮 §一），
       而 4 位轴字段（0..15）刚好装得下。
    => axis 与 drum_type 之间【不是随便的关系】：axis - 12 必须 == drum_type。
       这条有鉴别力（16 条轴 × 4 个件号 = 64 种组合里只有 4 种成立，⛔ 不是恒等式），
       入参层与字层都当硬检查（validate_fields / word_problems），自检 [13] 组
       把这 64 种组合逐个数了一遍。

为什么新字段放在 bit5 / bits[4:0]（手册 §2.0）：轴号字段现在装的是【轨序号】，
若拿它的最高位当 is_drum，轨号 8..15 会被读成鼓 => 又变成"旋律变鼓"，而且更隐蔽。
bits[6:0] 本来就写死 0 => 放这里永远安全。

由此 bits[6:0] 全部有主，本模块【不再有保留位】（MASK_RESERVED == 0）。
"""

import os
import sys
import tempfile

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
OFF_TICK     = 44
OFF_INC      = 23
OFF_AXIS     = 19     # axis 占 [22:19] => axis 的 LSB 就是 bit19（见文件头双语义）
OFF_VEL      = 11
OFF_KIND     = 9
OFF_TIMBRE   = 7
OFF_GUIDE    = 6
OFF_IS_DRUM  = 5      # 2026-10-16 新增：显式鼓标志
OFF_NOTE5    = 0      # 2026-10-16 新增：音符号偏移，占 bits[4:0]
# drum_type = 2 位，就写在 timbre 字段 [8:7] 里（2026-10-16 第三轮回退）。
# 曾经短暂扩到 3 位 = {bit19, timbre[8:7]}，随 FPGA 线收回一并删除。
# 保留 OFF_DRUMTYPE 这个名字（= OFF_TIMBRE），这样"改了 timbre 的位置却忘了
# drum_type"在结构上仍然不可能发生。
OFF_DRUMTYPE     = 7                      # = OFF_TIMBRE：drum_type 的 2 位

MASK_TICK         = 0xFFFFF
MASK_INC          = 0x1FFFFF
MASK_AXIS         = 0xF
MASK_VEL          = 0xFF
MASK_KIND         = 0x3
MASK_TIMBRE       = 0x3
MASK_GUIDE        = 0x1
MASK_IS_DRUM      = 0x1
MASK_NOTE5        = 0x1F
MASK_DRUMTYPE     = 0x3     # 2 位：0..3 四件（第三轮回退；扩位前就是它）
DRUM_TYPE_MAX     = 3       # drum_type 上限（越界判据用它，⛔ 不另写字面量）
DRUM_TYPE_COUNT   = 4

# bits[6:0] 自 2026-10-16 起【全部有主】：
#     bit6 = guide_only、bit5 = is_drum、bits[4:0] = note_off5
# => 保留位一个都不剩，MASK_RESERVED 只能是 0。
# 为什么还留着这个名字：send_frames.py / send_frames_ble.py / screen_demo.py
#   三处都在断言 reserved_bits(w) == 0，删名会连带改三个文件（本轮只许改本文件）。
#   => 保留函数与常量，语义变成"未分配位（现在没有未分配位了）"，恒为 0。
MASK_RESERVED = 0x00

KIND_ON    = 0
KIND_OFF   = 1
KIND_TEMPO = 2
KIND_NAMES = {KIND_ON: "on", KIND_OFF: "off", KIND_TEMPO: "tempo"}

# 鼓件号（2 bit，0..3）—— 2026-10-16 第三轮回退：回到四件。
# 编号出处：《ESP32侧修改手册-鼓与旋律分离-最终版-20261016.md》§二 / §4.3。
# 八件的编号（4 OpenHat · 5 Crash · 6 Ride · 7 Splash）随扩位一起【删除】：
# FPGA 只有 4 件鼓音色（《FPGA线回函-第三轮-收回8件鼓-20261016.md》§1.1）。
# GM 音高 -> drum_type 的映射由 mid2evt.py 负责；本文件定义【编号与映射表本身】
#   （唯一真源）=> 发送工具与判据工具都从这里取，不许各自再抄一份。
DRUM_KICK  = 0
DRUM_SNARE = 1
DRUM_HIHAT = 2
DRUM_TOM   = 3
DRUM_NAMES = {DRUM_KICK: "Kick", DRUM_SNARE: "Snare",
              DRUM_HIHAT: "HiHat", DRUM_TOM: "Tom"}

# ---- 鼓轴：一件一轴 12/13/14/15（2026-10-16 第三轮定稿）---------------------
# 为什么必须一件一轴：note_manager.v:1413-1416 的 note_off 按 (axis, src) 清
#   voice，而所有鼓的 src 都是 SRC_KDRUM => 同轴的两件鼓会互相清（详细理由见
#   文件头）。与 score_studio.html 的 DRUM_AXIS_BASE / DRUM_AXIS_OF 是同一张表。
DRUM_AXIS_BASE  = 12                                   # Kick 的轴；件号 0..3 => 12..15
DRUM_AXIS_MAX   = DRUM_AXIS_BASE + DRUM_TYPE_MAX       # 15（4 位轴字段的上限）
MELODY_AXIS_MAX = DRUM_AXIS_BASE - 1                   # 11：旋律用 0..11


def drum_axis_of(drum_type):
    """drum_type -> 该件鼓的轴号（一件一轴）：Kick 12 · Snare 13 · HiHat 14 · Tom 15。

    与 drum_type 是【严格配对】的：pack / 校验 / 报告都用这一个函数，
    ⛔ 不许任何地方再手写 "12 + dt" 或另一张轴表（两份必然漂）。
    """
    return DRUM_AXIS_BASE + (drum_type & MASK_DRUMTYPE)


# 件号 -> 轴号 的表（报告 / 工具用）。派生自 drum_axis_of()，⛔ 不手抄第二份。
DRUM_AXIS_OF = dict((dt, drum_axis_of(dt)) for dt in range(DRUM_TYPE_COUNT))

# GM 打击乐音符号 -> drum_type（2026-10-16 第三轮定稿，逐条可查）：
#   35,36 Kick | 38,40 Snare | 42,44 HiHat | 41,43,45,47,48,50 Tom
#   46,49,51,52,53,55,57,59 -> HiHat   （第三轮新增：镲族【显式列出】）
#   表外其它 GM 打击乐 -> 仍归 Tom（既有口径，见 DRUM_FALLBACK）
# ⚠️ 镲族为什么归 HiHat：FPGA 只有 4 件鼓音色，扩位已收回 =>
#    "镲 -> 踩镲"（都是金属高频）远比"镲 -> 嗵鼓"合理，而且不需要造音色
#    （FPGA 线回函 §1.2）。
# ⚠️ 为什么【显式列出】而不是靠表外兜底：兜底归 Tom，镲族若落进兜底就会被静默
#    归错件；显式列出后，报告能区分"这是有意归类"与"这个音高没认出来"
#    （ESP32侧回函-第三轮 §三 的实现口径）。
# ⚠️ 55 是 Splash（GM: Splash Cymbal），⛔ 不是 Crash —— 旧草稿把 55 同时抄进了
#    Crash 与 Splash（FPGA 线回函 §2.3 / §三-③ 已更正）。
GM_CYMBAL_NOTES = (46, 49, 51, 52, 53, 55, 57, 59)

GM_DRUM_MAP = {
    35: DRUM_KICK, 36: DRUM_KICK,
    38: DRUM_SNARE, 40: DRUM_SNARE,
    42: DRUM_HIHAT, 44: DRUM_HIHAT,
    41: DRUM_TOM, 43: DRUM_TOM, 45: DRUM_TOM,
    47: DRUM_TOM, 48: DRUM_TOM, 50: DRUM_TOM,
    46: DRUM_HIHAT, 49: DRUM_HIHAT, 51: DRUM_HIHAT, 52: DRUM_HIHAT,
    53: DRUM_HIHAT, 55: DRUM_HIHAT, 57: DRUM_HIHAT, 59: DRUM_HIHAT,
}

# 表外 GM 打击乐归 Tom（手册 §4.3："其它 GM 打击乐音符号：本轮先归到 Tom，并在
# 报告里列出来"）。
# ⚠️ 兜底【不塞进 gm_to_drum_type()】：那个函数返回 None，调用方才能在报告里点名
#    "这个音高没认出来"。但兜底值本身要有唯一定义处，⛔ 别在别处再写一遍。
DRUM_FALLBACK = DRUM_TOM


def gm_to_drum_type(gm_note):
    """GM 打击乐音符号 -> drum_type；表外返回 None（兜底见 DRUM_FALLBACK）。"""
    return GM_DRUM_MAP.get(gm_note)


def gm_to_drum_type_or_fallback(gm_note):
    """GM 打击乐音符号 -> drum_type；表外归 DRUM_FALLBACK（Tom）。

    给"只想要一个件号、不打算在报告里区分表内 / 表外"的调用方用；
    要在报告里点名表外音高（mid2evt.py 就是这么做的）请用 gm_to_drum_type()。
    """
    dt = GM_DRUM_MAP.get(gm_note)
    return DRUM_FALLBACK if dt is None else dt

# 音符号偏移的基准与范围（手册 §2.1 / §八-2；2026-10-16 二次修订：哨兵语义）：
#     note_off5 = MIDI音符号 - BASE_NOTE     （BASE_NOTE = 45 = A2，指板表最低音）
#     0..30 = 键盘上真实存在的键（MIDI 45..75）
#     31    = 哨兵【键盘上没有这个键 => 不点灯】（FPGA 两张表里 31 都是 N）
# ⛔ 这里修掉一个真 bug：旧口径把超出可弹音域的音【钳到 0】。而 0 = A2 = 指板表里
#    真实的键 5 => 贝斯低音区（40..44，键盘上根本没有对应的键）会点亮键 5，指错。
#    FPGA 线实测确认（回函 §3.2），所以改成写哨兵 31，⛔ 不许再钳到 0。
# 为什么键位不由 ESP32 算：FPGA 有运行期变调（-12..+12），且键位表是
#   非线性的物理布局 => 只有"音符号偏移"是发端本来就知道、变调后也仍然对的量。
BASE_NOTE              = 45
NOTE_OFF5_MIN          = 0
NOTE_OFF5_PLAYABLE_MAX = 30     # = MIDI 75，最后一个可弹的音
NOTE_OFF5_SENTINEL     = 31     # 不可弹：键盘上没有这个键 => 不点灯
NOTE_OFF5_MAX          = 31     # 字段上限（校验用；31 合法，语义是哨兵）
NOTE_OFF5_MIDI_MAX     = BASE_NOTE + NOTE_OFF5_PLAYABLE_MAX    # 75


def note_off5_from_midi(midi_note):
    """MIDI 音符号 -> note_off5。超出可弹音域一律返回哨兵 31，⛔ 不钳到 0。"""
    if midi_note < BASE_NOTE or midi_note > NOTE_OFF5_MIDI_MAX:
        return NOTE_OFF5_SENTINEL
    return midi_note - BASE_NOTE


def note_off5_is_sentinel(note_off5):
    """该 note_off5 是不是"不可弹"哨兵（= 31）。"""
    return note_off5 == NOTE_OFF5_SENTINEL


def note_off5_kind(note_off5):
    """note_off5 的分类：'playable'（0..30）/ 'sentinel'（31）。给日志与自检用。"""
    return "sentinel" if note_off5_is_sentinel(note_off5) else "playable"


def note_off5_to_midi(note_off5):
    """note_off5 -> MIDI 音符号；哨兵没有音高可还原 => None。"""
    return None if note_off5_is_sentinel(note_off5) else BASE_NOTE + note_off5

# 音色号（2 bit，0..3）—— 2026-10-14 补。
# 为什么补：原来本文件只定义位域，没有音色常量 => 每个工具各自写数字，
#   ⚠️ 迟早会有人写错顺序，而且看不出来。
# ⭐ 权威出处：mid2evt.py 注明"必须与 RTL 的 TIMBRE_N=4 及
#   wavetable_bank 的表序一致"。
TIMBRE_BASS, TIMBRE_GUITAR, TIMBRE_PIANO, TIMBRE_PAD = 0, 1, 2, 3
TIMBRE_NAMES = {TIMBRE_BASS: "BASS", TIMBRE_GUITAR: "GUITAR",
                TIMBRE_PIANO: "PIANO", TIMBRE_PAD: "PAD"}

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
def pack_word(tick, inc, axis, vel, kind, timbre,
              is_drum=0, drum_type=0, note_off5=0):
    """把九个字段拼成一个 64 bit 事件字。超范围的值按掩码截断。

    is_drum / drum_type / note_off5 是 2026-10-16 新增的三个入参（手册 §4.2），
    不传就是 0 => 旧的六参调用得到的字与修订前【逐位相同】（向后兼容）。

    bits[8:7] 只有【一个字段】，两种解释：
        is_drum=0 => 装 timbre（旋律音色）
        is_drum=1 => 装 drum_type（2 位件号；此时 timbre 入参被忽略）

    ⚠️ 本函数【不】替调用方纠正 axis：鼓的 axis 必须是该件鼓的轴（12 + drum_type），
        写错了照样原样打包，字面上完全看不出来 => 要拦住"件号与轴打架"请先调
        validate_fields，⛔ 别指望本函数报错（也⛔ 不要在这里静默改写 axis）。

    注意（越界只在打包时被截断）：note_off5=32 会被截成 0，字面上完全看不出来，
        灯却指错键 => 要拦住越界请先调 validate_fields，别指望本函数报错。
        note_off5=31 是合法值（哨兵：键盘上没有这个键 => 不点灯），不是越界。
    """
    if is_drum:
        tf = drum_type & MASK_DRUMTYPE               # 鼓：bits[8:7] = drum_type
    else:
        tf = timbre & MASK_TIMBRE                    # 旋律：bits[8:7] = 音色
    return (((tick      & MASK_TICK)    << OFF_TICK) |
            ((inc       & MASK_INC)     << OFF_INC) |
            ((axis      & MASK_AXIS)    << OFF_AXIS) |
            ((vel       & MASK_VEL)     << OFF_VEL) |
            ((kind      & MASK_KIND)    << OFF_KIND) |
            ((tf        & MASK_TIMBRE)  << OFF_TIMBRE) |
            ((is_drum   & MASK_IS_DRUM) << OFF_IS_DRUM) |
            ((note_off5 & MASK_NOTE5)   << OFF_NOTE5))


def unpack_word(word):
    """按 FPGA 的切片方式解出一个事件字。字段名与 FPGA 侧一致。

    drum_type（2 位）与 timbre 是【同一个字段】bits[8:7] 的两种解释：

        "timbre"     恒 = bits[8:7]（0..3）
        "drum_type"  恒 = bits[8:7]（0..3）：
                     is_drum=1 时它就是鼓件号（0 Kick · 1 Snare · 2 HiHat · 3 Tom）；
                     is_drum=0 时这两位是【音色】，读出来的 drum_type 等于音色值，
                     但它【不是鼓件号】—— 判鼓只看 bit5(is_drum)，
                     ⛔ 别拿 "drum_type" 键去判旋律 / tempo 是不是鼓。

    为什么要写清这一条：扩到 3 位那阵子，is_drum=0 必须把 drum_type 清零
    （那时 bit19 既是 axis 的 LSB，又会把轴号的奇偶读成件号的 MSB）。
    第三轮回退到 2 位后，drum_type 与 timbre 完全同源，这里【不做任何 is_drum
    分流的清零】—— 老口径就是"读出来等于 bits[8:7]"，2 位没有第二个来源。
    """
    return {
        "tick":      (word >> OFF_TICK)     & MASK_TICK,
        "inc":       (word >> OFF_INC)      & MASK_INC,
        "axis":      (word >> OFF_AXIS)     & MASK_AXIS,
        "vel":       (word >> OFF_VEL)      & MASK_VEL,
        "kind":      (word >> OFF_KIND)     & MASK_KIND,
        "timbre":    (word >> OFF_TIMBRE)   & MASK_TIMBRE,
        "drum_type": (word >> OFF_DRUMTYPE) & MASK_DRUMTYPE,
        "guide":     (word >> OFF_GUIDE)    & MASK_GUIDE,
        "is_drum":   (word >> OFF_IS_DRUM)  & MASK_IS_DRUM,
        "note_off5": (word >> OFF_NOTE5)    & MASK_NOTE5,
    }


def reserved_bits(word):
    """返回【未分配位】的值。

    2026-10-16 起 bits[6:0] 全部有主（guide_only / is_drum / note_off5）
    => 未分配位一个都不剩，本函数恒返回 0。
    保留它（而不是删掉）是为了不动 send_frames.py / send_frames_ble.py /
    screen_demo.py 里既有的 reserved_bits() == 0 断言 —— 本轮只许改本文件。
    """
    return word & MASK_RESERVED


# ============================================================================
# 判鼓 与 入参校验（2026-10-16 新增）
# ============================================================================
def is_drum_event(word):
    """该事件字是不是鼓。判鼓【只看 bit5(is_drum)】，任何情况下都不看轴号。"""
    return ((word >> OFF_IS_DRUM) & MASK_IS_DRUM) == 1


def goes_to_drum_pool(word):
    """该事件字是否走鼓池。

    这是全模块【唯一】的判鼓入口，等价于 is_drum_event。
    为什么单独立一个名字：旧的"轴号达到某个阈值就当鼓"的捷径就是这么渗进来的，
    只要还有人顺手按轴号判鼓，旋律就会变成鼓（手册 §一）。
    本模块里【没有】任何按轴号判鼓的规则，也不许再加（手册 §4.1 校验器硬检查①）。
    """
    return is_drum_event(word)


def validate_fields(tick, inc, axis, vel, kind, timbre,
                    is_drum=0, drum_type=0, note_off5=0):
    """打包【之前】的入参校验，返回问题列表（空列表 = 全过）。

    为什么要它：note_off5 只占 5 位，32 这种越界值一旦进了 pack_word 就被
    截成 0 —— 字面上完全看不出来，LED 却指错键。越界只能在【入参层】拦。

    四条硬检查（手册 §4.2 + 2026-10-16 第三轮回退）：
        ① is_drum=0 的事件不许带鼓件号 => 旋律绝不被路由到鼓池
        ② is_drum=1 时 inc 必须为 0（鼓的音高由 FPGA 按 drum_type 查表给）
        ③ is_drum=1 时 axis 必须【正好】是该件鼓的轴：
              axis ∈ 12..15（鼓轴区）且 axis - 12 == drum_type
              （Kick 12 · Snare 13 · HiHat 14 · Tom 15）
           理由：note_off 按 (axis, src) 清 voice，同轴的两件鼓会互相清 =>
                 一件一轴是必需的。
           这条【有鉴别力】：16 条轴 × 4 个件号 = 64 种组合里只有 4 种成立，
           ⛔ 不是恒等式（自检 [13] 组把 64 种逐个数了一遍）。
        ④ drum_type 越界：合法 0..3（2 位四件）

    取值范围：note_off5 = 0..31 全部合法。31 不是错误，而是【不可弹哨兵】
        （键盘上没有这个键 => 不点灯）；要区分请用 note_off5_kind()。
    """
    ps = []
    for name, val, hi in (("tick", tick, MASK_TICK), ("inc", inc, MASK_INC),
                          ("axis", axis, MASK_AXIS), ("vel", vel, MASK_VEL),
                          ("kind", kind, KIND_TEMPO),
                          ("timbre", timbre, MASK_TIMBRE),
                          ("is_drum", is_drum, MASK_IS_DRUM),
                          ("drum_type", drum_type, DRUM_TYPE_MAX),
                          ("note_off5", note_off5, NOTE_OFF5_MAX)):
        if not isinstance(val, int) or val < 0 or val > hi:
            ps.append("%s=%s 越界（合法 0..%d）" % (name, val, hi))
    # ② 鼓事件不许带音高
    if is_drum == 1 and inc != 0:
        ps.append("is_drum=1 但 inc=%s：鼓事件不携带音高，inc 必须为 0" % inc)
    # ① is_drum=0 就不许带鼓件号（带了说明有人还在按别的条件判鼓）
    if is_drum == 0 and drum_type != 0:
        ps.append("is_drum=0 但 drum_type=%s：旋律事件不许带鼓件号"
                  "（不许按轴号等其它条件判鼓）" % drum_type)
    # ③ 鼓的 axis 必须是该件鼓的轴（一件一轴，12/13/14/15）。
    #    分成两句报，是为了让"轴根本不在鼓轴区"（典型：还用着已作废的 dt 键）
    #    与"轴在鼓轴区但配错了件"两种错在日志里一眼可分。
    if is_drum == 1 and isinstance(drum_type, int) and isinstance(axis, int) \
            and 0 <= drum_type <= DRUM_TYPE_MAX:
        ax = axis & MASK_AXIS
        if not (DRUM_AXIS_BASE <= ax <= DRUM_AXIS_MAX):
            ps.append("is_drum=1 但 axis=%s 不在鼓轴区 %d..%d：鼓是一件一轴"
                      "（%s），旋律才用 0..%d"
                      % (axis, DRUM_AXIS_BASE, DRUM_AXIS_MAX,
                         " · ".join("%s %d" % (DRUM_NAMES[dt], drum_axis_of(dt))
                                    for dt in range(DRUM_TYPE_COUNT)),
                         MELODY_AXIS_MAX))
        elif ax - DRUM_AXIS_BASE != drum_type:
            ps.append("is_drum=1 但 axis=%s 与 drum_type=%s 不配对：该件鼓的轴是"
                      "%d（即 axis - %d 必须 == drum_type），否则 note_off 的"
                      "(axis, src) 匹配会让同一条轴上的两件鼓互相清 voice"
                      % (axis, drum_type, drum_axis_of(drum_type), DRUM_AXIS_BASE))
    return ps


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
def word_problems(word):
    """单个事件字的问题列表（空 = 通过）。load_events_hex 逐行调它。

    字层的检查（手册 §4.1 / §4.2 + 2026-10-16 第三轮回退）：
        · kind 不能是 3（未使用）
        · kind==2(tempo)：is_drum 必须为 0，且 bits[8:7] 必须为 0
          （tempo 的 timbre 两位没有语义，写非 0 说明有路径在乱填）
        · is_drum=1 时 inc 必须为 0（鼓事件不携带音高）
        · is_drum=1 时 axis 必须等于该件鼓的轴：axis ∈ 12..15 且
          axis - 12 == bits[8:7]（= drum_type）—— 两个【物理上不同】的字段
          交叉验证，拿到成品 hex（只有字、没有入参）也能验
        · is_drum=1 时 drum_type 必须在 0..3（2 位字段的解码器不变量）

    判鼓【只看 bit5(is_drum)】：本函数里没有任何"按轴号判鼓"的规则，
    所以 is_drum=0 的旋律事件即使在轴 12..15 上也不会被判进鼓
    （手册 §4.1 硬检查①、§六 判据 1、§7.3 机械检查 1）。
    ⚠️ 也【不】拿 "drum_type" 键去判旋律：is_drum=0 时它就是 bits[8:7]（音色），
       拿它当鼓件号读会把旋律全判红。
    """
    ps = []
    d = unpack_word(word)
    if d["kind"] == 3:
        ps.append("kind==3 未使用")
    if d["kind"] == KIND_TEMPO:
        # 手册 §4.1：tempo 事件 is_drum 写 0、drum_type 写 0。
        # 字层这里查的是 bits[8:7]（= "timbre" 键；它同时就是 drum_type 的值）。
        if d["is_drum"] == 1:
            ps.append("kind==2(tempo) 但 is_drum=1：tempo 事件不许带 is_drum")
        if d["timbre"] != 0:
            ps.append("kind==2(tempo) 但 bits[8:7]=%d：tempo 的 timbre 两位"
                      "没有语义，必须写 0" % d["timbre"])
    if d["is_drum"] == 1:
        if d["inc"] != 0:
            ps.append("is_drum=1 但 inc=%d：鼓事件不携带音高，inc 必须写 0"
                      % d["inc"])
        # 跨字段一致性：鼓的 axis 必须是该件鼓的轴（一件一轴 12/13/14/15）
        #   轴 12..15 且 axis - 12 == bits[8:7]。两个物理不同的字段互证：
        #   拿成品 hex 也能验，不必回看入参。
        dt = d["timbre"]                 # 鼓事件里 bits[8:7] 就是 drum_type
        if not (DRUM_AXIS_BASE <= d["axis"] <= DRUM_AXIS_MAX):
            ps.append("is_drum=1 但 axis=%d 不在鼓轴区 %d..%d：鼓是一件一轴"
                      "（Kick %d · Snare %d · HiHat %d · Tom %d）"
                      % (d["axis"], DRUM_AXIS_BASE, DRUM_AXIS_MAX,
                         drum_axis_of(DRUM_KICK), drum_axis_of(DRUM_SNARE),
                         drum_axis_of(DRUM_HIHAT), drum_axis_of(DRUM_TOM)))
        elif d["axis"] - DRUM_AXIS_BASE != dt:
            ps.append("is_drum=1 但 axis=%d 与 bits[8:7]=%d（drum_type）不配对："
                      "该件鼓的轴是 %d（即 axis - %d 必须 == drum_type），"
                      "否则同一条轴上的两件鼓会互相清 voice"
                      % (d["axis"], dt, drum_axis_of(dt), DRUM_AXIS_BASE))
        # 解码器不变量：2 位掩码决定了 drum_type 不可能越界，
        #   这条防的是"常量/掩码被改错"（入参层的 0..3 判据在 validate_fields，
        #   那里才是越界能真正发生的地方）。
        if not (0 <= d["drum_type"] <= DRUM_TYPE_MAX):
            ps.append("drum_type=%d 越界（合法 0..%d）"
                      % (d["drum_type"], DRUM_TYPE_MAX))
    return ps


def load_events_hex(path):
    """读 events.hex，返回 (words, problems)。

    格式：每行一个 16 位十六进制数（= 8 字节 / 64 bit 大端），无帧头。
          mid2evt.py 就是这么写的，帧头 0xA5 由发送方补。

    本函数做五项校验（不通过就记进 problems，但该行仍然保留，
    让调用方自己决定是拒发还是照发）：
        1. 行长必须是 16（含空白已 strip）
        2. kind 不能是 3（未使用）
        3. kind==2(tempo) 时 is_drum 与 bits[8:7] 都必须为 0
        4. is_drum=1 时 inc 必须为 0
        5. is_drum=1 时 axis 必须等于该件鼓的轴（axis ∈ 12..15 且
           axis - 12 == drum_type；一件一轴，见文件头）
    另：note_off5=31 是【合法】的不可弹哨兵（键盘上没有这个键 => 不点灯），
        ⛔ 不是错误、更不是"没钳位"。

    2026-10-16 改：原来第 2 条是"保留位 bit[5:0] 必须为 0"。现在 bits[6:0]
    全部有主（guide_only / is_drum / note_off5）=> 没有保留位可查了，改按新
    语义校验：bit6 与 bit5 各 1 位、bits[4:0] 是 0..31 的 note_off5 —— 这三条
    在字层天然成立，真正要查的是上表第 3、4、5 条。
    也正因为判鼓只看 bit5，本函数【不会】用轴号去猜鼓。
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
            for p in word_problems(word):
                problems.append("第 %d 行：%s" % (lineno, p))
            words.append(word)
    return words, problems


def summarize(words):
    """统计各 kind 条数 + tick 范围 + 不可弹（哨兵）条数。给 --hex 的打印用。

    "不可弹"= note_off5 写的是哨兵 31（键盘上没有这个键 => 不点灯）。
    手册 §3.3 把日志口径从"钳位数"改成"判为不可弹的条数"：它直接反映
    引导轨超出了键盘音域，比"钳了边界"更有诊断价值（钳位现在是明令禁止的）。
    """
    from collections import Counter
    c = Counter()
    tmin = None
    tmax = None
    unplayable = 0
    for w in words:
        d = unpack_word(w)
        c[d["kind"]] += 1
        if note_off5_is_sentinel(d["note_off5"]):
            unplayable += 1
        t = d["tick"]
        tmin = t if tmin is None else min(tmin, t)
        tmax = t if tmax is None else max(tmax, t)
    return {
        "total": len(words),
        "kinds": {KIND_NAMES.get(k, "kind%d" % k): v for k, v in sorted(c.items())},
        "tick_min": tmin,
        "tick_max": tmax,
        "unplayable": unplayable,
    }


# ============================================================================
# 自检（不需要硬件）
# ============================================================================
def selftest():
    """自检。判据必须能失败，缺了反向的一半就是假绿：
    第 [5] 组构造“旧位域”的反例；第 [8] 组构造“is_drum=1 却带音高 /
    note_off5 越界 / drum_type=4 / 轴与件不配对 / 轴用回已作废的 dt 键”的反例；
    第 [9] 组构造“按轴号判鼓”的反例；第 [13] 组把鼓轴判据的鉴别力数成
    “64 种组合里只有 4 种成立”，并逐条给出正反例。
    """
    print("=" * 74)
    print("score_word.py 离线自检（不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-52s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and bool(cond)

    print("\n[1] 位域与 FPGA 的切片逐位一致")
    # 与 FPGA 侧（rtl/top.v 切片 + rtl/w3c/seq_arb.v 判鼓）逐条对齐，
    # 依据：手册《ESP32侧修改手册-鼓与旋律分离-最终版-20261016》§二，
    #       以及第三轮回退（《FPGA线回函-第三轮-收回8件鼓-20261016.md》§1.3：
    #       drum_type 回 2 位 = timbre[8:7]，鼓轴回 12/13/14/15）。
    chk("   inc 在 [43:23]（21 bit）", (OFF_INC, MASK_INC) == (23, 0x1FFFFF))
    chk("   axis 在 [22:19]（4 bit）", (OFF_AXIS, MASK_AXIS) == (19, 0xF))
    chk("   vel 在 [18:11]（8 bit）", (OFF_VEL, MASK_VEL) == (11, 0xFF))
    chk("   kind 在 [10:9]（2 bit）", (OFF_KIND, MASK_KIND) == (9, 0x3))
    chk("   timbre 在 [8:7]（2 bit）", (OFF_TIMBRE, MASK_TIMBRE) == (7, 0x3))
    chk("   drum_type 与 timbre 是【同一字段】[8:7]（第三轮回退到 2 位）",
        (OFF_DRUMTYPE, MASK_DRUMTYPE) == (OFF_TIMBRE, MASK_TIMBRE))
    chk("   drum_type 是 2 位（0..3 四件：Kick/Snare/HiHat/Tom）",
        (MASK_DRUMTYPE, DRUM_TYPE_MAX, DRUM_TYPE_COUNT) == (0x3, 3, 4))
    chk("   鼓轴常量：基址 12、上限 15，轴字段 4 位装得下（掩码 0xF 就是 15）",
        (DRUM_AXIS_BASE, DRUM_AXIS_MAX) == (12, 15) and MASK_AXIS == DRUM_AXIS_MAX)
    chk("   旋律轴区 0..11 与鼓轴区 12..15 不重叠（MELODY_AXIS_MAX + 1 == 基址）",
        MELODY_AXIS_MAX == 11 and MELODY_AXIS_MAX + 1 == DRUM_AXIS_BASE)
    chk("   guide_only 在 [6]（1 bit，仅指引）", (OFF_GUIDE, MASK_GUIDE) == (6, 0x1))
    chk("   is_drum 在 [5]（1 bit：判鼓只看这一位）",
        (OFF_IS_DRUM, MASK_IS_DRUM) == (5, 0x1))
    chk("   note_off5 在 [4:0]（0..30 可弹 / 31 哨兵 / 字段上限 31）",
        (OFF_NOTE5, MASK_NOTE5) == (0, 0x1F)
        and (NOTE_OFF5_PLAYABLE_MAX, NOTE_OFF5_SENTINEL, NOTE_OFF5_MAX) == (30, 31, 31))
    chk("   tick 在 [63:44]（20 bit）", (OFF_TICK, MASK_TICK) == (44, 0xFFFFF))
    chk("   全部字段无重叠、无空洞（64 位刚好排满）",
        OFF_TICK == 44 and
        OFF_TICK + 20 == 64 and
        OFF_INC + 21 == OFF_TICK and
        OFF_AXIS + 4 == OFF_INC and
        OFF_VEL + 8 == OFF_AXIS and
        OFF_KIND + 2 == OFF_VEL and
        OFF_TIMBRE + 2 == OFF_KIND and
        OFF_GUIDE + 1 == OFF_TIMBRE and
        OFF_IS_DRUM + 1 == OFF_GUIDE and
        OFF_IS_DRUM == 5 and
        OFF_NOTE5 + 5 == OFF_IS_DRUM and
        MASK_RESERVED == 0)
    # 回退不是"改一半"：3 位那一版的常量 / 函数 / 八件编号必须一个都不剩。
    # 这条防的是"删了用法却留着定义"或"又被人加回来"（那种半成品最容易被误用）。
    chk("   第三轮回退已落实：3 位 drum_type 的残留一个都不剩"
        "（bit19 常量 / dt 键函数 / 八件编号）",
        not any(n in globals() for n in ("OFF_DRUMTYPE_MSB", "MASK_DRUMTYPE_MSB",
                                         "MASK_DRUMTYPE_LOW", "drum_axis_key",
                                         "DRUM_OPENHAT", "DRUM_CRASH",
                                         "DRUM_RIDE", "DRUM_SPLASH"))
        and sorted(DRUM_NAMES) == list(range(DRUM_TYPE_COUNT)),
        "  残留=%s" % [n for n in ("OFF_DRUMTYPE_MSB", "MASK_DRUMTYPE_MSB",
                                   "MASK_DRUMTYPE_LOW", "drum_axis_key",
                                   "DRUM_OPENHAT", "DRUM_CRASH",
                                   "DRUM_RIDE", "DRUM_SPLASH") if n in globals()])

    print("\n[2] 打包 -> 解包 往返（含极值）")
    # ⚠️ 鼓事件的 axis 必须是该件鼓的轴（一件一轴 12/13/14/15）—— 用 drum_axis_of()
    #    取，⛔ 不许手写 "12 + dt"，也⛔ 不许再用已作废的 dt 键（0,2,4,6,...）。
    # ⚠️ 鼓事件的 "timbre" 键解出来就是 bits[8:7] = drum_type（同一个字段）。
    cases = [
        dict(tick=0, inc=0, axis=0, vel=0, kind=KIND_ON, timbre=0),
        dict(tick=0xFFFFF, inc=0x1FFFFF, axis=0xF, vel=0xFF,
             kind=KIND_TEMPO, timbre=0x3),
        dict(tick=414720, inc=219902, axis=9, vel=130, kind=KIND_OFF, timbre=1),
        # 鼓事件的 note_on / note_off 都必须带 is_drum / drum_type（手册 §4.1 硬要求：
        #   鼓的 OFF 漏了标志 => 鼓的 voice 永久 held => 保留池耗尽 =>
        #   打一会儿鼓就再也不响了。这是最容易漏的一条。）
        dict(tick=960, inc=0, axis=drum_axis_of(DRUM_SNARE), vel=110,
             kind=KIND_OFF, timbre=DRUM_SNARE & MASK_DRUMTYPE,
             is_drum=1, drum_type=DRUM_SNARE, note_off5=NOTE_OFF5_SENTINEL),
        # 2 位里最高的一件（dt=3 Tom，轴 15）单独走一遍
        dict(tick=1920, inc=0, axis=drum_axis_of(DRUM_TOM), vel=235,
             kind=KIND_ON, timbre=DRUM_TOM & MASK_DRUMTYPE,
             is_drum=1, drum_type=DRUM_TOM, note_off5=0),
    ]
    for c in cases:
        w = pack_word(**c)
        d = unpack_word(w)
        same = all(d[k] == c[k] for k in c)
        chk("   往返 tick=%d inc=%d axis=%d vel=%d kind=%d timbre=%d"
            % (c["tick"], c["inc"], c["axis"], c["vel"], c["kind"], c["timbre"]), same,
            "" if same else "  解出=%s" % d)
        chk("   未分配位恒为 0（修订后已无保留位，函数兼容保留）",
            reserved_bits(w) == 0, "  0x%02X" % reserved_bits(w))
        chk("   guide_only 恒为 0（pack_word 不产生仅指引位）", d["guide"] == 0,
            "  guide=%d" % d["guide"])
        if "is_drum" not in c:
            # 注意：is_drum=0 时 bits[8:7] 是【音色】；"drum_type" 键读出来等于音色值
            #   （两位同源），但它不是鼓件号 —— 判鼓只看 is_drum。
            #   本判据只看 is_drum 与 note_off5 —— 那才是新增的位。
            chk("   旧六参调用不带新字段（bit5 与 bits[4:0] 恒 0）",
                (d["is_drum"], d["note_off5"]) == (0, 0),
                "  is_drum=%d note_off5=%d" % (d["is_drum"], d["note_off5"]))

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
    # 坏文件的每一行都必须被【拒】，且理由各不相同。
    # 注意第 4 行：就是修订前那句"保留位非 0"的同一串十六进制（原来是 ...81）。
    #   那时它因 bit0 被拒；现在 bit0 属于 note_off5，是合法值 => 不能再用它当反例。
    #   换成 ...a0（bit5 置 1）后，它带着 inc=14999 => 按【新语义】被拒。
    #   理由换了，但"坏行必须被拒"这个判据没丢。
    bad = "\n".join([
        "0000001d4b841080",
        "0000001d4b8410",            # 长度不足
        "0000001d4b8410ZZ",          # 非十六进制
        "0000001d4b8410a0",          # is_drum=1（bit5）却带着 inc=14999
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
    chk("   坏文件：至少报出 4 个问题（长度/进制/is_drum带inc/kind）",
        len(bpr) >= 4, "  报了 %d 个" % len(bpr))
    chk("   坏文件的问题里点名了 inc（is_drum=1 不许带音高）",
        any("inc" in p for p in bpr), "  %s" % bpr)
    chk("   坏文件的问题里点名了 kind==3", any("kind==3" in p for p in bpr))
    sm = summarize(gw)
    chk("   统计：tempo 1 条 + on 1 条",
        sm["kinds"].get("tempo") == 1 and sm["kinds"].get("on") == 1,
        "  %s" % sm["kinds"])

    print("\n[7] bit6=guide_only / bit5=is_drum / bits[4:0]=note_off5：按新语义校验")
    # 2026-10-16 修订：bits[6:0] 不再有"保留位"——
    #   bit6 = guide_only（0/1）、bit5 = is_drum（0/1）、bits[4:0] = note_off5（0..31）
    # 所以"保留位必须写 0"这条断言按新语义【换掉】，不是删掉：
    #   正向：带 guide_only=1 的合法产物必须被【接受】，解出来就是 1；
    #   反向：自相矛盾的字必须被【拒】（下面 x_bad：is_drum=1 却带着音高）。
    g_ok  = "0000001d4b8410c0"   # 与 [6] 的好行同一个字，只把 bit6 置 1
    g_bad = "0000001d4b8410a0"   # bit5 = 1 => is_drum=1，却带着 inc=14999
    w_ok  = int(g_ok, 16)
    w_bad = int(g_bad, 16)
    chk("   bit6=1 => unpack_word 解出 guide=1",
        unpack_word(w_ok)["guide"] == 1, "  guide=%d" % unpack_word(w_ok)["guide"])
    chk("   bit6=1 => 其余字段不受影响（inc=14999 vel=130 timbre=1 kind=0）",
        (unpack_word(w_ok)["inc"], unpack_word(w_ok)["vel"],
         unpack_word(w_ok)["timbre"], unpack_word(w_ok)["kind"]) == (14999, 130, 1, 0),
        "  %s" % {k: unpack_word(w_ok)[k] for k in ("inc", "vel", "timbre", "kind")})
    chk("   bit6=1 => 不是保留位（bits[6:0] 已全部有主，reserved_bits 恒 0）",
        reserved_bits(w_ok) == 0, "  0x%02X" % reserved_bits(w_ok))
    chk("   bit6=0 => guide=0",
        unpack_word(w_ok & ~(1 << OFF_GUIDE))["guide"] == 0)
    chk("   bit5=1 => is_drum=1，且不影响 guide（别把 bit5 当成 guide）",
        is_drum_event(w_bad) and unpack_word(w_bad)["guide"] == 0,
        "  is_drum=%d guide=%d" % (unpack_word(w_bad)["is_drum"],
                                   unpack_word(w_bad)["guide"]))
    with tempfile.TemporaryDirectory() as td:
        p_ok = os.path.join(td, "guide1.hex")
        p_bad = os.path.join(td, "drum_with_inc.hex")
        with open(p_ok, "w", encoding="utf-8") as f:
            f.write(g_ok + "\n")
        with open(p_bad, "w", encoding="utf-8") as f:
            f.write(g_bad + "\n")
        ow, opr = load_events_hex(p_ok)
        xw, xpr = load_events_hex(p_bad)
    chk("   load_events_hex 接受 bit6=1（1 个字、0 个问题）",
        len(ow) == 1 and len(opr) == 0, "  words=%d problems=%s" % (len(ow), opr))
    chk("   load_events_hex 读出的字解出 guide == 1",
        len(ow) == 1 and unpack_word(ow[0])["guide"] == 1)
    chk("   load_events_hex 拒 bit5=1 且 inc 非 0（点名 is_drum 与 inc）",
        len(xw) == 1 and any("is_drum=1" in p and "inc" in p for p in xpr),
        "  words=%d problems=%s" % (len(xw), xpr))

    print("\n[8] 新增字段 is_drum / drum_type / note_off5（双向判据：收 + 拒）")
    # 手册 §二 / §4.2 + 2026-10-16 第三轮回退（drum_type 回 2 位、鼓轴 12/13/14/15）。
    # 判据必须双向，缺一条就是假绿：
    #   正向：is_drum=1 + 合法 drum_type + 该件鼓的轴 + inc=0 必须被【接受】
    #   反向：is_drum=1 但 inc 非 0 / note_off5=32 / drum_type=4 /
    #         轴与件不配对 / 轴用回已作废的 dt 键 必须被【拒】（下面逐条点名）
    ax_hihat = drum_axis_of(DRUM_HIHAT)
    okf = validate_fields(tick=0, inc=0, axis=ax_hihat, vel=130, kind=KIND_ON,
                          timbre=0, is_drum=1, drum_type=DRUM_HIHAT, note_off5=17)
    chk("   收：is_drum=1 + 合法 drum_type + 该件鼓的轴 + inc=0 => 0 个问题",
        okf == [], "  %s" % okf)
    dw = pack_word(tick=960, inc=0, axis=ax_hihat, vel=130, kind=KIND_ON, timbre=0,
                   is_drum=1, drum_type=DRUM_HIHAT, note_off5=17)
    dd = unpack_word(dw)
    chk("   收：往返后 is_drum=1 drum_type=2 axis=14（HiHat 的轴）note_off5=17 inc=0",
        (dd["is_drum"], dd["drum_type"], dd["axis"], dd["note_off5"], dd["inc"])
        == (1, DRUM_HIHAT, ax_hihat, 17, 0),
        "  %s" % {k: dd[k] for k in ("is_drum", "drum_type", "axis",
                                     "note_off5", "inc")})
    chk("   鼓事件的 bits[8:7] 装的是 drum_type（timbre 入参被忽略：传 0 解出 2）",
        dd["timbre"] == DRUM_HIHAT, "  timbre=%d" % dd["timbre"])
    # is_drum=0 时 bits[8:7] 是音色；"drum_type" 键与它同源（2 位没有第二个来源），
    #   但它【不是鼓件号】=> 一律不许拿它去判旋律 / tempo 是不是鼓。
    mel_odd_w = pack_word(tick=0, inc=164927, axis=1, vel=100, kind=KIND_ON, timbre=2)
    mel_odd = unpack_word(mel_odd_w)
    chk("   is_drum=0 时 drum_type 键 == timbre（同一字段），且 is_drum=0",
        mel_odd["drum_type"] == mel_odd["timbre"] == 2 and mel_odd["is_drum"] == 0,
        "  drum_type=%d timbre=%d is_drum=%d"
        % (mel_odd["drum_type"], mel_odd["timbre"], mel_odd["is_drum"]))
    chk("   is_drum=0 的奇轴（axis=1）合法：字层 0 个问题"
        "（⛔ 不许按 drum_type 键判鼓、也不许按轴号判鼓）",
        (mel_odd["timbre"], mel_odd["axis"]) == (2, 1)
        and word_problems(mel_odd_w) == [],
        "  timbre=%d axis=%d problems=%s"
        % (mel_odd["timbre"], mel_odd["axis"], word_problems(mel_odd_w)))
    four = all(validate_fields(tick=0, inc=0, axis=drum_axis_of(dt), vel=100,
                               kind=KIND_ON, timbre=0, is_drum=1, drum_type=dt,
                               note_off5=5) == []
               for dt in range(DRUM_TYPE_COUNT))
    chk("   收：四件鼓 drum_type 0..3 全部被接受（每件都在自己的轴上）", four)
    chk("   收：drum_type=3（Tom，轴 15）合法 —— 2 位的上限就是 3",
        validate_fields(tick=0, inc=0, axis=drum_axis_of(DRUM_TOM), vel=100,
                        kind=KIND_ON, timbre=0, is_drum=1, drum_type=DRUM_TOM,
                        note_off5=0) == [])
    # ---- 以下六条是【必须被拒】的反例（点名到具体字段）----
    r1 = validate_fields(tick=0, inc=999, axis=drum_axis_of(DRUM_KICK), vel=130,
                         kind=KIND_ON, timbre=0, is_drum=1, drum_type=DRUM_KICK,
                         note_off5=17)
    chk("   拒：is_drum=1 但 inc=999（鼓事件 inc 必须为 0）",
        any("is_drum=1" in p and "inc" in p for p in r1), "  %s" % r1)
    r2 = validate_fields(tick=0, inc=0, axis=drum_axis_of(DRUM_KICK), vel=130,
                         kind=KIND_ON, timbre=0, is_drum=1, drum_type=DRUM_KICK,
                         note_off5=32)
    chk("   拒：is_drum=1 且 note_off5=32（越出 5 位上限 31）",
        any("note_off5" in p for p in r2), "  %s" % r2)
    r3 = validate_fields(tick=0, inc=164927, axis=3, vel=130, kind=KIND_ON,
                         timbre=1, is_drum=0, drum_type=DRUM_TOM, note_off5=3)
    chk("   拒：is_drum=0 却带 drum_type=3（旋律不许带鼓件号）",
        any("is_drum=0" in p and "drum_type" in p for p in r3), "  %s" % r3)
    r4 = validate_fields(tick=0, inc=0, axis=drum_axis_of(DRUM_KICK), vel=130,
                         kind=KIND_ON, timbre=0, is_drum=1,
                         drum_type=DRUM_TYPE_MAX + 1, note_off5=0)
    chk("   拒：drum_type=4（2 位只有 0..3 四件；扩位已收回）",
        any("drum_type" in p for p in r4), "  %s" % r4)
    r5 = validate_fields(tick=0, inc=0, axis=drum_axis_of(DRUM_KICK), vel=130,
                         kind=KIND_ON, timbre=0, is_drum=1, drum_type=DRUM_SNARE,
                         note_off5=0)
    chk("   拒：轴与件不配对（Snare(dt=1) 却写在 Kick 的轴 12 上）",
        any("不配对" in p for p in r5), "  %s" % r5)
    r6 = validate_fields(tick=0, inc=0, axis=0, vel=130, kind=KIND_ON, timbre=0,
                         is_drum=1, drum_type=DRUM_KICK, note_off5=0)
    chk("   拒：轴用回已作废的 dt 键（dt=0 写 axis=0，不在鼓轴区 12..15）",
        any("鼓轴区" in p for p in r6), "  %s" % r6)
    # ---- tempo 事件（kind==2）：is_drum 与 bits[8:7] 都必须写 0（手册 §4.1）----
    t_ok = int("000001c2f9000400", 16)      # 真实产物里的 tempo 字（[3] 已逐项对齐）
    chk("   收：正常 tempo（is_drum=0 bits[8:7]=0）0 个问题，且打包与原字逐位相同",
        word_problems(t_ok) == []
        and pack_word(tick=0, inc=230898, axis=0, vel=0, kind=KIND_TEMPO,
                      timbre=0) == t_ok,
        "  %s" % word_problems(t_ok))
    t_bad1 = pack_word(tick=0, inc=230898, axis=0, vel=0, kind=KIND_TEMPO,
                       timbre=0, is_drum=1, note_off5=0)
    chk("   拒：tempo 却带 is_drum=1（点名 tempo 与 is_drum）",
        any("tempo" in p and "is_drum" in p for p in word_problems(t_bad1)),
        "  %s" % word_problems(t_bad1))
    t_bad2 = pack_word(tick=0, inc=230898, axis=0, vel=0, kind=KIND_TEMPO,
                       timbre=3, is_drum=0, note_off5=0)
    chk("   拒：tempo 却带 bits[8:7]=3（tempo 的 timbre 两位必须写 0）",
        any("tempo" in p and "bits[8:7]" in p for p in word_problems(t_bad2)),
        "  %s" % word_problems(t_bad2))
    # note_off5 三条边界：0 / 31 必须【接受】（31 是哨兵，不是错误），32 必须【拒】
    # 注意 32 在【字层】永远查不出来 —— 5 位字段装不下它，pack_word 会把它截成 0
    #   （灯指错键却毫无痕迹）=> 越界只能在入参层用 validate_fields 拦。
    for n5, want in ((NOTE_OFF5_MIN, True), (NOTE_OFF5_PLAYABLE_MAX, True),
                     (NOTE_OFF5_SENTINEL, True), (32, False)):
        f5 = validate_fields(tick=0, inc=164927, axis=0, vel=100, kind=KIND_ON,
                             timbre=1, is_drum=0, drum_type=0, note_off5=n5)
        chk("   note_off5=%d => %s" % (n5, "接受" if want else "拒绝"),
            (f5 == []) == want, "  %s" % (f5 or "无问题"))
    with tempfile.TemporaryDirectory() as td:
        p_a = os.path.join(td, "drum_ok.hex")
        p_b = os.path.join(td, "drum_bad.hex")
        p_c = os.path.join(td, "drum_bad_axis.hex")
        with open(p_a, "w", encoding="utf-8") as f:
            f.write("%016X\n" % dw)
        with open(p_b, "w", encoding="utf-8") as f:
            f.write("%016X\n" % pack_word(tick=960, inc=14999,
                                          axis=drum_axis_of(DRUM_HIHAT), vel=130,
                                          kind=KIND_ON, timbre=0, is_drum=1,
                                          drum_type=DRUM_HIHAT, note_off5=31))
        # 轴与件打架：按 Snare 打成（轴 13、bits[8:7]=1），再把 bits[8:7] 的最低位
        #   翻掉 => 件号变成 Kick(0)，轴却还停在 13 => 两个字段对不上。
        # ⚠️ 这是【物理位】级的反例（只有字、没有入参也能验）；
        #    入参层那条反例是 r5（⛔ 别只留一条：两层的读法不同）。
        with open(p_c, "w", encoding="utf-8") as f:
            f.write("%016X\n" % (pack_word(tick=960, inc=0,
                                           axis=drum_axis_of(DRUM_SNARE), vel=130,
                                           kind=KIND_ON, timbre=0, is_drum=1,
                                           drum_type=DRUM_SNARE, note_off5=0)
                                 ^ (1 << OFF_TIMBRE)))
        aw, apr = load_events_hex(p_a)
        bw2, bpr2 = load_events_hex(p_b)
        cw, cpr = load_events_hex(p_c)
    chk("   字层：真鼓事件被放行（1 个字、0 个问题）",
        len(aw) == 1 and len(apr) == 0, "  words=%d problems=%s" % (len(aw), apr))
    chk("   字层：is_drum=1 且 inc=14999 被拒（点名 inc）",
        len(bw2) == 1 and any("inc" in p for p in bpr2), "  problems=%s" % bpr2)
    chk("   字层：轴与 bits[8:7]（件号）不配对 => 被拒（点名 axis）",
        len(cw) == 1 and any("axis" in p for p in cpr), "  problems=%s" % cpr)

    print("\n[9] 判鼓只看 is_drum：任何轴号都不能把旋律判进鼓")
    # 手册 §六 判据 1（FPGA 侧那条判据的 ESP32 镜像）：
    #   is_drum=0 的事件在【任意轴号】下都不许走鼓池，尤其鼓的轴区 12/13/14/15 ——
    #   那是"轴号 = 鼓"这个旧捷径最容易复发的地方（第三轮回退后鼓轴又回到 12..15）。
    # 这就是"删掉按轴号判鼓"的机械保证 —— 判鼓入口只有 goes_to_drum_pool(=is_drum)，
    #   本模块里没有任何"轴号达到某个阈值就算鼓"的残留规则。
    wrong_ax = []
    for ax in range(16):
        w_ax = pack_word(tick=0, inc=164927, axis=ax, vel=100, kind=KIND_ON,
                         timbre=1, is_drum=0, note_off5=ax)
        if goes_to_drum_pool(w_ax) or is_drum_event(w_ax):
            wrong_ax.append(ax)
    chk("   16 个轴号（0..15）下，旋律事件一律不走鼓池",
        wrong_ax == [], "  被判成鼓的轴号=%s" % wrong_ax)
    edge_ax = [ax for ax in (12, 13, 14, 15)
               if goes_to_drum_pool(pack_word(tick=0, inc=164927, axis=ax, vel=100,
                                              kind=KIND_ON, timbre=1, is_drum=0,
                                              note_off5=1))]
    chk("   鼓的轴区（轴号 12/13/14/15）上尤其不许把旋律判成鼓",
        edge_ax == [], "  被判成鼓的轴号=%s" % edge_ax)
    chk("   正向：is_drum=1 才走鼓池（防「一律不判鼓」的假绿）",
        goes_to_drum_pool(pack_word(tick=0, inc=0, axis=0, vel=100, kind=KIND_ON,
                                    timbre=0, is_drum=1, drum_type=DRUM_KICK,
                                    note_off5=0))
        and not goes_to_drum_pool(pack_word(tick=0, inc=164927, axis=0, vel=100,
                                            kind=KIND_ON, timbre=1, is_drum=0,
                                            note_off5=0)))
    with tempfile.TemporaryDirectory() as td:
        p_m = os.path.join(td, "melody_hi_axis.hex")
        with open(p_m, "w", encoding="utf-8") as f:
            for i in range(4):
                f.write("%016X\n" % pack_word(tick=i * 240, inc=164927, axis=12 + i,
                                              vel=100, kind=KIND_ON, timbre=1,
                                              is_drum=0, note_off5=i))
        mw, mpr = load_events_hex(p_m)
    chk("   校验器不把高轴号的旋律判成鼓（轴号 12/13/14/15 四行，0 个问题）",
        len(mw) == 4 and len(mpr) == 0, "  words=%d problems=%s" % (len(mw), mpr))

    print("\n[10] 旧字段回归：tick/inc/axis/vel/kind/timbre 的解包结果一个都不许变")
    base = int("0000001d4b841080", 16)     # 真实产物里的字（[3] 已逐项对齐）
    repack = pack_word(tick=0, inc=14999, axis=0, vel=130, kind=KIND_ON, timbre=1)
    chk("   六参调用（不传新参）与原字逐位相同 0x0000001D4B841080",
        repack == base, "  重打=0x%016X" % repack)
    w_new = base | (1 << OFF_IS_DRUM) | 17      # 只动本次新增的位
    d_old, d_new = unpack_word(base), unpack_word(w_new)
    chk("   只置 is_drum / note_off5 后，六个旧字段逐一不变",
        all(d_old[k] == d_new[k] for k in ("tick", "inc", "axis", "vel", "kind",
                                           "timbre")),
        "  旧=%s 新=%s" % ({k: d_old[k] for k in ("tick", "inc", "axis", "vel",
                                                  "kind", "timbre")},
                           {k: d_new[k] for k in ("tick", "inc", "axis", "vel",
                                                  "kind", "timbre")}))
    chk("   新增位确实生效：is_drum=1 且 note_off5=17",
        (d_new["is_drum"], d_new["note_off5"]) == (1, 17),
        "  is_drum=%d note_off5=%d" % (d_new["is_drum"], d_new["note_off5"]))
    chk("   MASK_RESERVED == 0（bits[6:0] 已全部有主，没有保留位了）",
        MASK_RESERVED == 0)
    # 说明：w_new 这个字（is_drum=1 却带着 inc=14999）会被字层校验拒 ——
    #   本组只验【解包不受影响】，那条拒绝是 [8] 的判据，两件事不冲突。
    chk("   非空洞：该字确实会被字层校验拒（证明 [8] 的判据在跑）",
        any("inc" in p for p in word_problems(w_new)),
        "  %s" % word_problems(w_new))

    print("\n[11] 四件编号 / GM 映射（含镲族 -> HiHat）/ 鼓轴（第三轮定稿）")
    # 出处：《FPGA线回函-第三轮-收回8件鼓-20261016.md》§1.2/§1.3，
    #       我方照办口径见《ESP32侧回函-第三轮-axis确认与回退-20261016.md》§二/§三。
    want_names = {0: "Kick", 1: "Snare", 2: "HiHat", 3: "Tom"}
    chk("   四件编号 0..3 齐全、无重名（八件的 4..7 已删）",
        DRUM_NAMES == want_names, "  %s" % DRUM_NAMES)
    want_gm = {35: 0, 36: 0, 38: 1, 40: 1, 42: 2, 44: 2,
               41: 3, 43: 3, 45: 3, 47: 3, 48: 3, 50: 3,
               46: 2, 49: 2, 51: 2, 52: 2, 53: 2, 55: 2, 57: 2, 59: 2}
    chk("   GM 映射表与第三轮定稿逐条一致（共 %d 个音高）" % len(want_gm),
        GM_DRUM_MAP == want_gm, "  %s" % sorted(GM_DRUM_MAP.items()))
    # 镲族 8 个音高【逐个】点名（⛔ 不是"随便抽一个看看"）
    cym_bad = [g for g in GM_CYMBAL_NOTES if gm_to_drum_type(g) != DRUM_HIHAT]
    chk("   镲族 8 个音高逐个映射到 HiHat(2)：46/49/51/52/53/55/57/59",
        len(GM_CYMBAL_NOTES) == 8 and cym_bad == [],
        "  未归 HiHat 的=%s" % cym_bad)
    chk("   镲族在表里【显式列出】（⛔ 不靠表外兜底）：8 个音高都在 GM_DRUM_MAP 里",
        all(g in GM_DRUM_MAP for g in GM_CYMBAL_NOTES))
    chk("   45（低嗵）仍映射到 Tom(3) —— 防『一刀切把中高音全算镲』",
        (gm_to_drum_type(45), gm_to_drum_type(43), gm_to_drum_type(47))
        == (DRUM_TOM, DRUM_TOM, DRUM_TOM),
        "  45->%s 43->%s 47->%s" % (gm_to_drum_type(45), gm_to_drum_type(43),
                                    gm_to_drum_type(47)))
    chk("   42/44（踩镲）本来就是 HiHat(2)：镲族归 HiHat 后仍只归这一件",
        gm_to_drum_type(42) == DRUM_HIHAT and gm_to_drum_type(44) == DRUM_HIHAT)
    chk("   55 归 HiHat（第三轮起镲族统一归 HiHat），⛔ 不再有 Splash 这一件",
        gm_to_drum_type(55) == DRUM_HIHAT)
    chk("   表外音高 gm_to_drum_type 返回 None（不许静默归类，报告要点名）",
        gm_to_drum_type(60) is None and gm_to_drum_type(99) is None)
    chk("   表外 GM 打击乐兜底 = Tom(3)（既有口径；37/39/54/56 都归 Tom）",
        DRUM_FALLBACK == DRUM_TOM
        and all(gm_to_drum_type_or_fallback(g) == DRUM_TOM
                for g in (37, 39, 54, 56, 60, 99)),
        "  %s" % [gm_to_drum_type_or_fallback(g) for g in (37, 39, 54, 56, 60, 99)])
    chk("   兜底不许吞掉表内音高：表内 %d 个音高的兜底结果 == 直查结果"
        % len(GM_DRUM_MAP),
        all(gm_to_drum_type_or_fallback(g) == gm_to_drum_type(g) for g in GM_DRUM_MAP))
    ax_list = [drum_axis_of(dt) for dt in range(DRUM_TYPE_COUNT)]
    chk("   鼓轴：Kick 12 · Snare 13 · HiHat 14 · Tom 15（一件一轴）",
        ax_list == [12, 13, 14, 15], "  %s" % ax_list)
    chk("   鼓轴互不相同（一件一轴；同一条轴上的两件鼓会互相清 voice）",
        len(set(ax_list)) == DRUM_TYPE_COUNT)
    chk("   DRUM_AXIS_OF 表（报告/工具用）与 drum_axis_of() 逐项一致",
        DRUM_AXIS_OF == dict((dt, drum_axis_of(dt)) for dt in range(DRUM_TYPE_COUNT)))

    print("\n[12] note_off5 哨兵语义：0..30 可弹 / 31 不可弹（⛔ 不再钳到 0）")
    # 出处：FPGA 线回函 §3.3。旧口径把超音域钳到 0，而 0 = A2 = 指板表里真实的
    #   键 5 => 贝斯低音区会点亮错误的灯（FPGA 线实测确认）。哨兵 31 在 FPGA 的
    #   两张表里都是"不点灯"。
    chk("   0..30 全部是可弹（MIDI 45..75）",
        all(note_off5_kind(v) == "playable"
            for v in range(NOTE_OFF5_PLAYABLE_MAX + 1)))
    chk("   31 是哨兵（kind=sentinel），且它就是字段上限、不是越界",
        note_off5_is_sentinel(NOTE_OFF5_SENTINEL)
        and note_off5_kind(NOTE_OFF5_SENTINEL) == "sentinel"
        and NOTE_OFF5_SENTINEL == NOTE_OFF5_MAX)
    chk("   哨兵 != 0（0 是 A2 = 真实的键 5，钳到 0 会点错灯）",
        NOTE_OFF5_SENTINEL != NOTE_OFF5_MIN)
    chk("   边界：45->0，75->30，44->31，76->31",
        (note_off5_from_midi(45), note_off5_from_midi(75),
         note_off5_from_midi(44), note_off5_from_midi(76)) == (0, 30, 31, 31),
        "  %s" % [note_off5_from_midi(m) for m in (45, 75, 44, 76)])
    chk("   ⛔ 不再钳到 0：midi 40 / 100 都返回哨兵 31（不是 0）",
        note_off5_from_midi(40) == NOTE_OFF5_SENTINEL
        and note_off5_from_midi(100) == NOTE_OFF5_SENTINEL
        and note_off5_from_midi(40) != NOTE_OFF5_MIN,
        "  40 -> %s ; 100 -> %s" % (note_off5_from_midi(40),
                                    note_off5_from_midi(100)))
    chk("   反查：哨兵没有音高可还原（None），0..30 能还原成 MIDI",
        note_off5_to_midi(NOTE_OFF5_SENTINEL) is None
        and note_off5_to_midi(0) == 45 and note_off5_to_midi(30) == 75)
    chk("   入参层：31 被接受（哨兵不是错误）",
        validate_fields(tick=0, inc=164927, axis=0, vel=100, kind=KIND_ON,
                        timbre=1, is_drum=0, drum_type=0,
                        note_off5=NOTE_OFF5_SENTINEL) == [])
    sm2 = summarize([pack_word(tick=0, inc=164927, axis=0, vel=100, kind=KIND_ON,
                               timbre=1, is_drum=0, drum_type=0, note_off5=31),
                     pack_word(tick=1, inc=164927, axis=0, vel=100, kind=KIND_ON,
                               timbre=1, is_drum=0, drum_type=0, note_off5=30)])
    chk("   summarize 报出不可弹条数（口径 = 哨兵条数，不是钳位数）",
        sm2["unplayable"] == 1, "  unplayable=%d" % sm2["unplayable"])

    print("\n[13] 鼓轴硬判据：轴与件必须一一对应（鉴别力 + 反例）")
    # 这条判据【不是恒等式】：16 条轴 × 4 个件号 = 64 种组合里只有 4 种成立。
    # 把"鉴别力"数成一个可判定的数字 —— 若判据写成恒真，这里会数出 64。
    combos = [(dt, ax) for dt in range(DRUM_TYPE_COUNT)
              for ax in range(MASK_AXIS + 1)]
    accept = [(dt, ax) for (dt, ax) in combos
              if validate_fields(tick=0, inc=0, axis=ax, vel=100, kind=KIND_ON,
                                 timbre=0, is_drum=1, drum_type=dt,
                                 note_off5=0) == []]
    chk("   鉴别力：64 种组合（16 条轴 × 4 个件号）里只有 4 种被接受",
        len(combos) == 64
        and accept == [(dt, drum_axis_of(dt)) for dt in range(DRUM_TYPE_COUNT)],
        "  接受 %d 种：%s" % (len(accept), accept))
    wrong_axis = [(dt, ax) for (dt, ax) in combos
                  if ax != drum_axis_of(dt)
                  and validate_fields(tick=0, inc=0, axis=ax, vel=100, kind=KIND_ON,
                                      timbre=0, is_drum=1, drum_type=dt,
                                      note_off5=0) == []]
    chk("   反例：每一件的【其余 15 条轴】全部被拒（4 件 × 15 = 60 种）",
        wrong_axis == [], "  漏过的=%s" % wrong_axis)
    chk("   字层：四件鼓（轴 12..15，bits[8:7] 与件号一致）0 个问题",
        all(word_problems(pack_word(tick=0, inc=0, axis=drum_axis_of(dt), vel=100,
                                    kind=KIND_ON, timbre=0, is_drum=1,
                                    drum_type=dt, note_off5=0)) == []
            for dt in range(DRUM_TYPE_COUNT)))
    # 字层反例 1：轴落在旋律区（4）却标 is_drum=1
    bad_mel_axis = pack_word(tick=0, inc=0, axis=4, vel=100, kind=KIND_ON, timbre=0,
                             is_drum=1, drum_type=DRUM_KICK, note_off5=0)
    chk("   反例（字层）：轴落在旋律区（4）却标 is_drum=1 => 被拒（点名 axis）",
        any("axis" in p for p in word_problems(bad_mel_axis)),
        "  %s" % word_problems(bad_mel_axis))
    # 字层反例 2：轴是 Snare 的（13），bits[8:7] 却被翻成 Kick(0)
    bad_pair = (pack_word(tick=0, inc=0, axis=drum_axis_of(DRUM_SNARE), vel=100,
                          kind=KIND_ON, timbre=0, is_drum=1, drum_type=DRUM_SNARE,
                          note_off5=0) ^ (1 << OFF_TIMBRE))
    chk("   反例（字层）：轴 13（Snare）配 bits[8:7]=0（Kick）=> 被拒（点名 axis）",
        any("axis" in p for p in word_problems(bad_pair)),
        "  %s" % word_problems(bad_pair))
    chk("   非空洞：两条反例改成【配对】的写法，问题必须消失（判据不是恒红）",
        word_problems(pack_word(tick=0, inc=0, axis=4, vel=100, kind=KIND_ON,
                                timbre=0, is_drum=0, drum_type=0, note_off5=0)) == []
        and word_problems(pack_word(tick=0, inc=0, axis=drum_axis_of(DRUM_SNARE),
                                    vel=100, kind=KIND_ON, timbre=0, is_drum=1,
                                    drum_type=DRUM_SNARE, note_off5=0)) == [])
    # 旋律写在鼓的轴上仍然【不是鼓】：判鼓只看 bit5（手册 §4.1 硬检查①）
    mel_on_drum_axis = pack_word(tick=0, inc=164927, axis=drum_axis_of(DRUM_KICK),
                                 vel=100, kind=KIND_ON, timbre=1, is_drum=0,
                                 note_off5=3)
    chk("   旋律写在鼓轴 12 上也不是鼓（判鼓只看 bit5，⛔ 不许按轴号猜）",
        not goes_to_drum_pool(mel_on_drum_axis)
        and word_problems(mel_on_drum_axis) == []
        and unpack_word(mel_on_drum_axis)["axis"] == DRUM_AXIS_BASE,
        "  is_drum=%d problems=%s" % (unpack_word(mel_on_drum_axis)["is_drum"],
                                      word_problems(mel_on_drum_axis)))

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


if __name__ == "__main__":
    # 用法：python -X utf8 score_word.py --selftest
    # 不带参数也跑自检（selftest_all.py 对"文件里没有 --selftest 字样"的脚本
    #   走无参调用分支，两条路都得通）；给了别的参数就报用法退出 ——
    #   免得以为自己跑了自检，其实什么都没跑。
    _argv = sys.argv[1:]
    if _argv and "--selftest" not in _argv:
        print("用法：python -X utf8 score_word.py --selftest")
        sys.exit(2)
    sys.exit(selftest())
