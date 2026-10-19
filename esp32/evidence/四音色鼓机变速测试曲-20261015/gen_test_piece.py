#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""四音色 + 鼓机 + 变速 + 复音 的测试小段子（生成 .mid）。

曲子：**St. James Infirmary**（传统美国布鲁斯叙事曲，**公有领域**）
      改编成慢速 funk（E 小调，96 -> 108 BPM，10 小节约 24 秒）。

═══ 旋律出处（⛔ 不是凭记忆写的）═══
  ABC 记谱取自 abcnotation.com（John Chambers 收藏，Thornton Rose 2002 记谱）：
    https://abcnotation.com/tunePage?a=trillian.mit.edu/~jc/music/abc/mirror/mindspring.com/~thornton.rose/St_James_Infirmary/0000
  原始 ABC（K:G，L:1/4）：
    B/2>B/2 | B B/2B/2 A/2 A B/2 | G E2 | B | B>B e c | B3 |
    B/2B/2 | B/2B/2B/2B/2 A B | G E2 | (E/2F/2) | G (G/2E/2) (B/2A/2) G | E3 |
  逐音抄进下面的 MEL（音高/音长都按 ABC；K:G ⇒ F 为 F#）。
  ⚠️ 为什么必须抄记谱而不是凭记忆：我不听音频，凭记忆写音高一定会错。

═══ 改编思路 ═══
  · 原曲是慢布鲁斯叙事曲 ⇒ 用【慢速 funk】处理：八分网格、切分贝斯、clav 反拍、
    弦乐铺底、旋律（吉他）当主角。
  · 和声按 ABC 上标的和弦：Em / B7 / Am（每小节前两拍一个、后两拍一个）。
  · 10 小节 = 1 小节起拍 + 8 小节旋律 + 1 小节终和弦（复音 6 声）。

═══ 四条硬约束（都是踩过坑/查过 RTL 才加的）═══
  1. 【不许两个音色发同一个音高】—— 同频 => 两个 voice 相位干涉
     （mid2evt.py 文件头："可能变响、变薄、或在起音处打拍子，听起来像被敲了两次"）。
     ⇒ 音高素材【按音色分区】：
         BASS 40~47 · PAD 52~55 · PIANO(clav) 57~63 · GUITAR(旋律) 64~76
  2. 【鼓的不同件不许在同一 tick 同时敲】—— 已知未解决项（same_hit 复用）。
     ⛔ 只有最后那小节第 4 拍故意让 kick+snare+hihat 同 tick 敲一下，作探针。
  3. ⭐⭐ 【鼓：跨件可以同时响，但**同一件**相邻落点必须 >= DRUM_DUR（480 tick）】
     —— 2026-10-15 已按【方案 B】落地（四件鼓各占一条轴 12/13/14/15）：
       · 跨件：✅ 可以同 tick / 可以重叠（踩镲走满八分 + 底鼓军鼓穿插 = 标准 funk 鼓型）
       · 同一件：⚠️ 仍不行 —— `note_off` 清的是【同轴同源】的所有 voice
         （note_manager.v:1305-1321）⇒ 同一件敲得比鼓长更近，后一下会把前一下掐掉
       · 依据：files/20-代码/FPGA侧答复-鼓机多声部方案B-20261015.md
     ⇒ 所以本曲的鼓是【真 funk 鼓型】，⛔ 不再退化成"每个八分最多一件"。
       ⚠️ 但要在【新位流】上听：旧位流仍是四件共用 axis 15，鼓会被切碎。
  4. 【旋律可用轴只剩 0~11】—— 方案 B 把 12~15 让给鼓 ⇒ 同时发声的旋律音必须 <= 12
     （判据 ④ 会报峰值）。
  4. 【伴奏锁在同一网格，旋律自由】—— 用户："器乐之间各演各的，听感很混乱"。
     贝斯与 clav 都锁在八分网格、互相交错；旋律（吉他）豁免。

用法
    python gen_test_piece.py                 # 生成到本目录
    python gen_test_piece.py --out X.mid     # 换输出路径
"""

import argparse
import os
import struct
import sys

# 控制台按 UTF-8 输出（Windows 默认 GBK，遇到中文里的符号会 UnicodeEncodeError）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PPQN = 960
BEAT = PPQN
BAR = 4 * BEAT
E8 = 480


def bar(n):
    """第 n 小节（1 起）的起始 tick。"""
    return (n - 1) * BAR


# --------------------------------------------------------------------------- #
# 旋律（逐音抄自上面的 ABC）
# --------------------------------------------------------------------------- #
# (小节, 偏移, 音高, 时值)   小节 1 = 起拍小节（弱起在它后半）；小节 2~9 = 旋律 8 小节
MEL = (
    # 弱起 "I went"（原谱 B/2>B/2 —— 这里按两个八分处理，听感差别很小）
    (1, 2880, 71, 480), (1, 3360, 71, 480),
    # T1 "down to the St. James In-firm-'ry"   B B/2B/2 A/2 A B/2 | G E2 B
    (2, 0, 71, 960), (2, 960, 71, 480), (2, 1440, 71, 480),
    (2, 1920, 69, 480), (2, 2400, 69, 960), (2, 3360, 71, 480),
    (3, 0, 67, 960), (3, 960, 64, 1920), (3, 2880, 71, 960),
    # T2 "To see my ba-by there"   B>B e c | B3
    (4, 0, 71, 1440), (4, 1440, 71, 480), (4, 1920, 76, 960), (4, 2880, 72, 960),
    # T3 "She was ly-in' on a long white ta-ble"   B3 B/2B/2 | B/2B/2B/2B/2 A B | G E2
    (5, 0, 71, 2880), (5, 2880, 71, 480), (5, 3360, 71, 480),
    (6, 0, 71, 480), (6, 480, 71, 480), (6, 960, 71, 480), (6, 1440, 71, 480),
    (6, 1920, 69, 960), (6, 2880, 71, 960),
    (7, 0, 67, 960), (7, 960, 64, 1920),
    # T4 "So sweet, so cool, so fair"   (E/2F/2) | G (G/2E/2) (B/2A/2) G | E3
    (7, 2880, 64, 480), (7, 3360, 66, 480),
    (8, 0, 67, 960), (8, 960, 67, 480), (8, 1440, 64, 480),
    (8, 1920, 71, 480), (8, 2400, 69, 480), (8, 2880, 67, 960),
    (9, 0, 64, 2880),
)

# --------------------------------------------------------------------------- #
# 和声（按 ABC 上标的和弦：每小节前两拍一个、后两拍一个）
# --------------------------------------------------------------------------- #
# 每小节 = (前两拍和弦, 后两拍和弦)
PROG = (None,                      # 小节 1 是起拍小节，只有贝斯 + 鼓
        ("Em", "B7"), ("Em", "Em"), ("Am", "Em"), ("Em", "Em"),
        ("B7", "Em"), ("Em", "Em"), ("B7", "Em"), ("Em", "Em"),
        ("Em", "Em"))              # 小节 10 = 终和弦

# 音高素材（按音色分区，见硬约束 1）
CH = {
    "Em": {"bass": 40, "fifth": 47, "pad": (52, 55), "clav": (59, 62)},   # E2 B2 | E3 G3 | B3 D4
    "B7": {"bass": 47, "fifth": 42, "pad": (54,),   "clav": (57, 63)},   # B2 F#2 | F#3 | A3 D#4
    "Am": {"bass": 45, "fifth": 40, "pad": (52,),   "clav": (57, 60)},   # A2 E2 | E3 | A3 C4
}

# 贝斯：八分网格上的切分（根音 / 五度），每小节 6 个音
BASS_PAT = ((0, "R", 500), (720, "R", 180), (1440, "F", 400),
            (1920, "R", 500), (2640, "R", 180), (3360, "F", 400))
# clav：反拍双音 stab —— ⚠️ 落点【与贝斯共用】(1440 / 3360)，这样每小节有 2 个共同落点
#       （判据 ⑪ 要求伴奏声部锁在同一骨架上；同时这也是 funk 里常见的"贝斯+clav 齐击"）
CLAV_PAT = ((1440, 200), (3360, 200))

# 鼓（GM 音高）：36 Kick · 38 Snare · 42 HiHat · 45 Tom
KICK, SNARE, HIHAT, TOM = 36, 38, 42, 45
DRUM_DUR = 480
DRUM_VEL = {KICK: 122, SNARE: 116, HIHAT: 100, TOM: 112}
DRUM_PITCH = (("kick", KICK), ("snare", SNARE), ("hat", HIHAT), ("tom", TOM))

# ⭐ 方案 B 之后的鼓：**真 funk 鼓型**（踩镲走满八分，底鼓军鼓穿插）
#    · 跨件可以同 tick / 重叠 ✅（四件各占一条轴）
#    · ⚠️ 同一件相邻落点仍须 >= 480（`note_off` 只清同轴同源）
DRUM_A = dict(kick=(0, 1440, 1920), snare=(960, 2880),
              hat=(0, 480, 960, 1440, 1920, 2400, 2880, 3360), tom=())
DRUM_FILL = dict(kick=(0, 1440), snare=(960,),
                 hat=(0, 480, 960, 1440),
                 tom=(1920, 2400, 2880, 3360))          # 八分 tom 过门（同一件 >= 480）
DRUM_END = dict(kick=(0, 1440, 1920, 2880), snare=(960, 2880),
                hat=(0, 480, 960, 1440, 1920, 2400, 2880, 3360), tom=(3360,))
# ⭐ 2880 那一下：kick + snare + hat 三件同 tick —— 判据 ⑦ 要的"探针"（方案 B 就是要支持它）

TEMPO_PLAN = ((1, 96), (6, 108))          # 小节 -> BPM（后半段提起来）

# ⭐ 终和弦（小节 10）：经典收尾 = 两下齐击 + 一个 6 声长和弦
#    ⚠️ 第 10 小节【不再走常规伴奏】（原来两者叠加 ⇒ 峰值并发冲到 11、同音高重了一次）
#    (偏移, 轨, 音高, 时值)
FINAL = (
    (0, "bass", 40, 1200), (0, "pad", 52, 1200), (0, "pno", 59, 1200),
    (1440, "bass", 40, 900), (1440, "pad", 52, 900), (1440, "pno", 59, 900),
    (2400, "bass", 40, 1440), (2400, "pad", 52, 1440), (2400, "pad", 55, 1440),
    (2400, "pno", 59, 1440), (2400, "pno", 62, 1440), (2400, "gtr", 64, 1440),
)


# --------------------------------------------------------------------------- #
# 标准 MIDI 文件（SMF format 1）写入 —— 只用标准库
# --------------------------------------------------------------------------- #
class Track:
    def __init__(self, name, channel=None):
        self.name = name
        self.channel = channel
        self.ev = []                     # (tick, order, bytes)

    def note(self, tick, midi, vel, dur):
        st = self.channel & 0x0F
        # order: 0 = off 在前，1 = on 在后（同 tick 关旧音、开新音）
        self.ev.append((tick, 1, bytes([0x90 | st, midi & 0x7F, vel & 0x7F])))
        self.ev.append((tick + dur, 0, bytes([0x80 | st, midi & 0x7F, 0])))

    def chord(self, tick, midis, vel, dur):
        for m in midis:
            self.note(tick, m, vel, dur)


class Conductor(Track):
    """速度轨：只有 set_tempo，没有音符（上位机会把它从选轨列表里丢掉，但 tempo 生效）。"""

    def __init__(self, name="Tempo"):
        Track.__init__(self, name, None)

    def tempo(self, tick, bpm):
        us = int(round(60_000_000.0 / bpm))
        self.ev.append((tick, -1, b"\xff\x51\x03" + struct.pack(">I", us)[1:]))


def vlq(n):
    out = bytearray([n & 0x7F])
    n >>= 7
    while n:
        out.insert(0, (n & 0x7F) | 0x80)
        n >>= 7
    return bytes(out)


def build_track(tk):
    body = bytearray()
    nm = tk.name.encode("utf-8")
    body += vlq(0) + b"\xff\x03" + vlq(len(nm)) + nm
    last = 0
    for tick, _order, data in sorted(tk.ev, key=lambda e: (e[0], e[1])):
        if tick < last:
            raise SystemExit("ERROR: %s 的事件 tick 倒退（%d < %d）"
                             % (tk.name, tick, last))
        body += vlq(tick - last) + data
        last = tick
    body += vlq(0) + b"\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(body)) + bytes(body)


def write_midi(path, tracks):
    head = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), PPQN)
    data = head + b"".join(build_track(t) for t in tracks)
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


# --------------------------------------------------------------------------- #
# 谱子
# --------------------------------------------------------------------------- #
def compose():
    tempo = Conductor()
    bass = Track("Bass", 0)
    gtr = Track("Guitar", 1)
    pno = Track("Piano", 2)
    pad = Track("Pad", 3)
    drum = Track("Drum", 9)

    for b, bpm in TEMPO_PLAN:
        tempo.tempo(bar(b), bpm)

    # ---- 旋律（吉他）：逐音抄自 ABC ----
    for b, o, pitch, dur in MEL:
        gtr.note(bar(b) + o, pitch, 92, dur)

    # ---- 伴奏 ----
    # 小节 1 = 起拍（贝斯走两个空弦 E + 鼓）
    t1 = bar(1)
    bass.note(t1, CH["Em"]["bass"], 96, 1800)
    bass.note(t1 + 1920, CH["Em"]["bass"], 96, 1800)

    # 小节 2~9 = 旋律 8 小节的伴奏（贝斯 / clav / 弦乐）
    for b in range(2, 10):
        t0 = bar(b)
        ca, cb = PROG[b - 1]
        for o, which, dur in BASS_PAT:
            c = CH[ca] if o < 1920 else CH[cb]
            bass.note(t0 + o, c["bass"] if which == "R" else c["fifth"], 98, dur)
        for o, dur in CLAV_PAT:
            c = CH[ca] if o < 1920 else CH[cb]
            pno.chord(t0 + o, c["clav"], 84, dur)
        # 弦乐铺底：前两拍 / 后两拍各一个长音
        pad.chord(t0, CH[ca]["pad"], 58, 1919)
        pad.chord(t0 + 1920, CH[cb]["pad"], 58, 1919)

    # 小节 10 = 终和弦（⛔ 不再走上面的常规伴奏，否则会叠加）
    t10 = bar(10)
    for o, who, pitch, dur in FINAL:
        {"bass": bass, "pad": pad, "pno": pno, "gtr": gtr}[who] \
            .note(t10 + o, pitch, 88, dur)

    # ---- 鼓：全部 10 小节 ----
    for b in range(1, 11):
        t0 = bar(b)
        if b == 9:
            drum_pattern = DRUM_FILL
        elif b == 10:
            drum_pattern = DRUM_END
        else:
            drum_pattern = DRUM_A
        for name, pitch in DRUM_PITCH:
            for o in drum_pattern.get(name, ()):
                drum.note(t0 + o, pitch, DRUM_VEL[pitch], DRUM_DUR)

    return [tempo, bass, gtr, pno, pad, drum]


def summarize(tracks):
    print("=" * 74)
    print("St. James Infirmary · funk 改编（E 小调，10 小节）")
    print("=" * 74)
    print("  旋律：吉他 %d 个音（逐音抄自 ABC 记谱，公有领域）" % len(MEL))
    print("  和声：" + " | ".join(("-" if s is None else s[0] + ("/" + s[1] if s[1] != s[0] else ""))
                                for s in PROG))
    print("  速度：96 BPM（1~5 小节）-> 108 BPM（6~10 小节）")
    print()
    tot = 0
    for tk in tracks:
        n_note = sum(1 for e in tk.ev if e[2][0] & 0xF0 in (0x90, 0x80))
        n_on = sum(1 for e in tk.ev if e[2][0] & 0xF0 == 0x90)
        tot += n_note
        extra = "  tempo 点 = %d" % len(tk.ev) if isinstance(tk, Conductor) else ""
        print("  %-8s ch=%-3s 音符 %3d（on/off 共 %3d）%s"
              % (tk.name, "-" if tk.channel is None else (tk.channel + 1),
                 n_on, n_note, extra))
    print("  MIDI 事件总数（含 off 与 tempo）= %d" % tot)
    print("  长度 = 10 小节 = %d tick" % (10 * BAR))


def main(argv=None):
    ap = argparse.ArgumentParser(description="生成 St. James Infirmary 的 funk 改编")
    ap.add_argument("--out", default=None, help="输出 .mid 路径")
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "StJamesInfirmary-funk-测试曲.mid")

    tracks = compose()
    summarize(tracks)
    n = write_midi(out, tracks)
    print("  已写出：%s（%d 字节）" % (out, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
