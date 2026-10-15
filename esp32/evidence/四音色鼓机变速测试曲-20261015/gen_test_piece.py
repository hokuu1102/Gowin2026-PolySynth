#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""四音色 + 鼓机 + 变速 + 复音 的测试小段子（生成 .mid）。

风格：**funk**（单一风格）。编曲思路：**功能演示卡** ——
      ⭐ **一小节只演示一件事**，音符刻意稀疏（用户："不要塞爆，每个都体现一下就可以了"）。
      7 小节，约 16 秒。上一版是"每小节所有乐器一起上"（280 个音），听感是糊的。

═══ 一小节演示什么 ═══
  小节  速度   演示的内容                         同时在响的音
  1     100    BASS（riff）+ 底鼓 / 踩镲            1~2
  2     100    + GUITAR（单音 riff）                2~3
  3     100    + PIANO（三音和弦）                  3~5
  4     100    + PAD  => **四音色同框**（长音为主）   6
  5     126    **鼓机四件** + tom 过门               1~2
  6     126    **复音**：每半拍进一个音 -> 7 声       1→7
  7     92     **收尾 + 鼓探针**                     6

  变速点：小节 1（100）· 小节 5（126）· 小节 7（92）。

═══ ⭐⭐ 两条硬约束（都是踩过坑才加的）═══
  1. 【不许两个音色发同一个音高】
     两个音色同频 => 两个 voice 相位干涉（mid2evt.py 文件头："可能变响、变薄、
     或在起音处打拍子，听起来像被敲了两次"）。
     📌 用户实测："第一次变速之后怪怪的，好像两个音色没对上" =>
        verify_piece.js 判据 ⑨ 量出 44 处，从第 3 小节（第一次变速）开始。
     ⇒ 这里把音高素材【按音色分区】，整曲只用 Am7 的和弦音 A·C·E·G：
         BASS 45/48/52(A2 C3 E3)   PAD 57/60(A3 C4)
         GUITAR 64/67(E4 G4)       PIANO 69/72(A4 C5)
       四组互不重叠 => 同音高在结构上不可能发生。判据 ⑨ 再核一遍（应为 0 处）。
  2. 【鼓的不同件不许在同一 tick 同时敲】
     已知未解决项（same_hit 复用）。⇒ 每档鼓的落点互不相同；
     ⛔ 只有第 7 小节第 4 拍【故意】让 kick+snare+hihat 同 tick 敲一下，作探针。
  3. ⭐⭐ 【鼓的相邻落点间隔必须 >= DRUM_DUR（480 tick）】
     为什么（FPGA 侧 RTL 查证，note_manager.v:1305-1321）：
       `note_off` 清的是【所有】同轴位且 gate 高的 voice（同源才清）——
         if ((gate_r[i]|retrig_low[i]) && (axis_r[i]==cur_axis) && (src_r[i]==cur_src))
     而四个鼓件【共用 axis 15 且同源（SRC_KDRUM）】
       ⇒ ⭐ **任何一个鼓的 note_off 会把该轴上所有还在响的鼓一起释放**
       ⇒ ⭐ **鼓机实际是"单声部"**：后一下会被前一下的 off 掐掉。
     📌 所以 16 分鼓花（240 间隔）在这里是【听得出问题】的写法 ——
        本曲原来第 5 小节的 tom 过门就是 16 分，已改成八分。
     ✅ verify_piece.js 判据 ⑩ 会卡这条。

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

PPQN = 960                 # 与 FPGA 的 beat_gen / 上位机 MIDI_PPQN 一致
BEAT = PPQN
BAR = 4 * BEAT
E8 = 480                   # 八分音符


def bar(n):
    """第 n 小节（1 起）的起始 tick。"""
    return (n - 1) * BAR


# 音高素材（见文件头硬约束 1）：全是 Am7 的和弦音 A / C / E / G，【按音色分区】
# ⚠️ 整曲只用 Am7 一个和弦 —— 这是"功能演示卡"，⛔ 不是歌。
#    换和弦就要换音高素材，很容易又撞上"两个音色同音高"（上一版就是这么翻车的）。
A2, C3, E3 = 45, 48, 52
A3, C4 = 57, 60
E4, G4 = 64, 67
A4, C5 = 69, 72

TEMPO_PLAN = ((1, 100), (5, 126), (7, 92))      # 小节 -> BPM

# ⭐ 功能演示卡：一小节一条，每条的音符都是【显式列出】的（偏移 tick 相对小节头）
#    drums 里的每个元组 = 该件的落点（tick 偏移）
DEMO = (
    dict(bar=1, chord="Am7", what="BASS（走 A2-C3）+ 底鼓/踩镲",
         bass=((0, A2, 900), (1440, C3, 400), (1920, A2, 1800)),
         gtr=(), pno=(), pad=(),
         drums=dict(kick=(0, 1920), snare=(), hat=(480, 1440, 2400, 3360), tom=())),

    dict(bar=2, chord="Am7", what="+ GUITAR（单音 riff）",
         bass=((0, A2, 1800), (1920, C3, 1800)),
         gtr=((0, E4, 300), (720, G4, 300), (1920, E4, 300), (2880, G4, 600)),
         pno=(), pad=(),
         drums=dict(kick=(0, 1920), snare=(), hat=(480, 1440, 2400, 3360), tom=())),

    dict(bar=3, chord="Am7", what="+ PIANO（三音和弦）",
         bass=((0, A2, 1800), (1920, A2, 1800)),
         gtr=((2880, E4, 300),),
         # 三音和弦（C4 E4 A4）—— 此刻 pad 不响，所以可以借它的音区
         pno=((0, (C4, E4, A4), 1200), (1920, (C4, E4, A4), 900)),
         pad=(),
         drums=dict(kick=(0, 1920), snare=(), hat=(480, 1440, 2400, 3360), tom=())),

    dict(bar=4, chord="Am7", what="+ PAD => 四音色同框（长音为主）",
         bass=((0, A2, 3600),),
         gtr=((0, E4, 400), (1440, G4, 400)),
         pno=((0, (A4, C5), 1800),),
         pad=((0, (A3, C4), BAR - 1),),
         drums=dict(kick=(0, 1920), snare=(960, 2880),
                    hat=(480, 1440, 2400, 3360), tom=())),

    dict(bar=5, chord="Am7", what="鼓机四件 + tom 过门",
         bass=((0, A2, 1800),),
         gtr=(), pno=(), pad=(),
         # ⚠️⚠️ 鼓的落点间隔必须 >= DRUM_DUR（480）—— 见文件头硬约束 3。
         #    原来这里是 16 分 tom 过门（240 间隔）=> 后一下会被前一下的 note_off 掐掉。
         drums=dict(kick=(0, 1920), snare=(960,), hat=(480, 1440),
                    tom=(2400, 2880, 3360))),

    dict(bar=6, chord="Am7", what="复音：每半拍进一个音 -> 7 声",
         # 全部撑到小节末 => 末尾 7 个音同时响，且音高互不重复（能一个一个数）
         ladder=((0, "bass", A2), (1, "pad", A3), (2, "pad", C4), (3, "gtr", E4),
                 (4, "gtr", G4), (5, "pno", A4), (6, "pno", C5)),
         drums=dict(kick=(0, 1920), snare=(), hat=(480, 1440), tom=())),

    dict(bar=7, chord="Am7", what="收尾 + 鼓探针（第 4 拍三件同敲）",
         bass=((0, A2, 3600),),
         gtr=((0, E4, 400), (960, G4, 400)),
         pno=((0, (A4, C5), 1800),),
         pad=((0, (A3, C4), BAR - 1),),
         drums=dict(kick=(0, 1440, 1920, 2880), snare=(960, 2880),
                    hat=(480, 2400, 2880), tom=(3360,))),
)

# 鼓（GM 音高）：36 Kick · 38 Snare · 42 HiHat · 45 Tom
KICK, SNARE, HIHAT, TOM = 36, 38, 42, 45
DRUM_DUR = 480
DRUM_VEL = {KICK: 122, SNARE: 116, HIHAT: 100, TOM: 112}
DRUM_PITCH = (("kick", KICK), ("snare", SNARE), ("hat", HIHAT), ("tom", TOM))


# --------------------------------------------------------------------------- #
# 标准 MIDI 文件（SMF format 1）写入 —— 只用标准库
# --------------------------------------------------------------------------- #
class Track:
    """一条 MIDI 轨。事件先按【绝对 tick】攒着，写文件时再转成 delta。"""

    def __init__(self, name, channel=None):
        self.name = name
        self.channel = channel
        self.ev = []                     # (tick, order, bytes)

    def note(self, tick, midi, vel, dur):
        st = self.channel & 0x0F
        # order: 0 = off 在前，1 = on 在后。
        # 为什么：同一 tick 上"关旧音、开新音"（同音高重击）是常见写法，
        # 上位机按 (tick, off 先) 配对；若先发 on，新音会把旧音的段吞掉。
        self.ev.append((tick, 1, bytes([0x90 | st, midi & 0x7F, vel & 0x7F])))
        self.ev.append((tick + dur, 0, bytes([0x80 | st, midi & 0x7F, 0])))

    def chord(self, tick, midis, vel, dur):
        for m in midis:
            self.note(tick, m, vel, dur)


class Conductor(Track):
    """速度轨：只有 set_tempo，一个音符都没有。

    ⚠️ 上位机会把【没有音符的轨】从选轨列表里丢掉，
       但它的 tempo 会被收进全局表（parseMidi 的 allTempos）
       => 变速照样生效，且不会在界面上多出一行。
    """

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
    body += vlq(0) + b"\xff\x03" + vlq(len(nm)) + nm      # track name
    last = 0
    for tick, _order, data in sorted(tk.ev, key=lambda e: (e[0], e[1])):
        if tick < last:
            raise SystemExit("ERROR: %s 的事件 tick 倒退（%d < %d）"
                             % (tk.name, tick, last))
        body += vlq(tick - last) + data
        last = tick
    body += vlq(0) + b"\xff\x2f\x00"                       # end of track
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
    drum = Track("Drum", 9)              # 通道 10（1-based）= GM 打击乐

    for b, bpm in TEMPO_PLAN:
        tempo.tempo(bar(b), bpm)

    for spec in DEMO:
        t0 = bar(spec["bar"])

        for off, pitch, dur in spec.get("bass", ()):
            bass.note(t0 + off, pitch, 98, dur)
        for off, pitch, dur in spec.get("gtr", ()):
            gtr.note(t0 + off, pitch, 84, dur)
        for off, pitches, dur in spec.get("pno", ()):
            pno.chord(t0 + off, pitches, 86, dur)
        for off, pitches, dur in spec.get("pad", ()):
            pad.chord(t0 + off, pitches, 60, dur)

        # 复音阶梯：每半拍进一个音，全部撑到小节末
        for slot, who, pitch in spec.get("ladder", ()):
            off = slot * E8
            dur = BAR - off
            {"bass": bass, "gtr": gtr, "pno": pno, "pad": pad}[who] \
                .note(t0 + off, pitch, 90, dur)

        for name, pitch in DRUM_PITCH:
            for off in spec["drums"].get(name, ()):
                drum.note(t0 + off, pitch, DRUM_VEL[pitch], DRUM_DUR)

    return [tempo, bass, gtr, pno, pad, drum]


def summarize(tracks):
    print("=" * 74)
    print("四音色 + 鼓机 + 变速 + 复音 · funk 功能演示卡（7 小节）")
    print("=" * 74)
    for spec in DEMO:
        print("  第 %d 小节  %-6s %s" % (spec["bar"], spec["chord"], spec["what"]))
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
    print("  长度 = 7 小节 = %d tick" % (7 * BAR))


def main(argv=None):
    ap = argparse.ArgumentParser(description="生成四音色+鼓机+变速+复音的 funk 演示卡")
    ap.add_argument("--out", default=None, help="输出 .mid 路径")
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "四音色鼓机变速-funk-演示卡.mid")

    tracks = compose()
    summarize(tracks)
    n = write_midi(out, tracks)
    print("  已写出：%s（%d 字节）" % (out, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
