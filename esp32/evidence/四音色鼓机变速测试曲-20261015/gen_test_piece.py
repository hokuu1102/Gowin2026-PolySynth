#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""四音色 + 鼓机 + 变速 的测试小段子（生成 .mid）。

用途
    给「曲谱上位机」（esp32/tools/score_studio.html）做一次灌谱验证。
    一段 12 小节的小曲子，一次把四件事都测到：

      1. 四个音色同时出声 —— BASS / GUITAR / PIANO / PAD
      2. 鼓机四件都响     —— Kick / Snare / HiHat / Tom
      3. 变速             —— 100 -> 140 -> 80 BPM，三个 tempo 点
      4. 和弦             —— 同一时刻多个音，逼上位机把音摊到多条轴

为什么给 .mid 而不是 events.hex
    上位机从 2026-10-14 起能【直接在浏览器里读 .mid】，
    所以给 .mid 最省事；同时同目录的 verify_piece.js 会用
    【网页自己的解析器】把它转成 events.hex，Python 那条路也能用。

有意避开 / 有意保留
    避开：鼓的【不同件】在【同一 tick】同时敲 —— 已知未解决项
          （same_hit 复用，见
           files/20-代码/ESP32侧追问-同时敲多个鼓与same_hit-20261014.md）
          => 主 groove 里 hihat 只打反拍，不与 kick / snare 撞 tick。
    保留：第 12 小节【故意】让 kick + snare + hihat 同 tick 敲一下，
          当作该已知问题的探针。预期见 README。

用法
    python gen_test_piece.py                 # 生成到本目录
    python gen_test_piece.py --out X.mid     # 换输出路径
"""

import argparse
import os
import struct
import sys

# 控制台按 UTF-8 输出（Windows 默认 GBK，遇到中文注释里的符号会 UnicodeEncodeError）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PPQN = 960                 # 与 FPGA 的 beat_gen / 上位机 MIDI_PPQN 一致
BEAT = PPQN
BAR = 4 * BEAT


def bar(n):
    """第 n 小节（1 起）的起始 tick。"""
    return (n - 1) * BAR


# 音名 -> MIDI 号（只为了让下面的谱子好读）
N = {
    "F2": 41, "G2": 43, "A2": 45,
    "C3": 48, "D3": 50, "E3": 52, "F3": 53, "G3": 55, "A3": 57, "B3": 59,
    "C4": 60, "D4": 62, "E4": 64, "F4": 65, "G4": 67, "A4": 69, "B4": 71,
    "C5": 72,
}

# 和弦进行（A 小调）：Am - F - C - G
PAD_AM = [57, 60, 64, 69]      # A3 C4 E4 A4
PAD_F = [53, 57, 60, 65]       # F3 A3 C4 F4
PAD_C = [55, 60, 64, 67]       # G3 C4 E4 G4
PAD_G = [55, 59, 62, 67]       # G3 B3 D4 G4


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

    # ---------------- 变速表（三个 tempo 点）----------------
    tempo.tempo(bar(1), 100)             # 第 1~4 小节：100 BPM
    tempo.tempo(bar(5), 140)             # 第 5~8 小节：140 BPM
    tempo.tempo(bar(9), 80)              # 第 9~12 小节：80 BPM

    # ---------------- 第 1~4 小节：只有 Pad + Bass，第 3 小节钢琴进 ----------------
    for b, ch in ((1, PAD_AM), (2, PAD_F), (3, PAD_C), (4, PAD_G)):
        pad.chord(bar(b), ch, 70, BAR - 1)          # 整小节长音
    for b, root in ((1, "A2"), (2, "F2"), (3, "C3"), (4, "G2")):
        t = bar(b)
        bass.note(t, N[root], 96, 1800)             # 半音符（留一点缝）
        bass.note(t + 2 * BEAT, N[root], 90, 1800)
    p = bar(3)
    pno.note(p, N["E4"], 88, 900)
    pno.note(p + BEAT, N["G4"], 88, 900)
    pno.note(p + 2 * BEAT, N["A4"], 92, 1800)
    p = bar(4)
    pno.note(p, N["G4"], 88, 900)
    pno.note(p + BEAT, N["D4"], 88, 900)
    pno.note(p + 2 * BEAT, N["B3"], 92, 1800)

    # ---------------- 第 5~8 小节：四音色 + 鼓机全上 ----------------
    # (小节, 吉他琶音四个音, Pad 和弦, 贝斯根音名)
    S2 = (
        (5, [45, 52, 57, 52], PAD_AM, "A2"),
        (6, [41, 48, 53, 48], PAD_F, "F2"),
        (7, [48, 55, 60, 55], PAD_C, "C3"),
        (8, [43, 50, 55, 50], PAD_G, "G2"),
    )
    for b, gch, pch, root in S2:
        t = bar(b)
        pad.chord(t, pch, 66, BAR - 1)
        for k in range(8):
            bass.note(t + k * 480, N[root] + (12 if k % 2 else 0), 94, 400)
            gtr.note(t + k * 480, gch[k % 4], 80, 400)

    p = bar(5)
    pno.note(p, N["A4"], 92, 900)
    pno.note(p + BEAT, N["C5"], 92, 900)
    pno.note(p + 2 * BEAT, N["B4"], 84, 420)
    pno.note(p + 2 * BEAT + 480, N["A4"], 84, 420)
    pno.note(p + 3 * BEAT, N["G4"], 90, 1800)
    p = bar(6)
    pno.note(p, N["F4"], 90, 900)
    pno.note(p + BEAT, N["A4"], 90, 900)
    pno.note(p + 2 * BEAT, N["C5"], 92, 900)
    pno.note(p + 3 * BEAT, N["A4"], 92, 900)
    p = bar(7)
    pno.note(p, N["G4"], 90, 900)
    pno.note(p + BEAT, N["E4"], 90, 900)
    pno.note(p + 2 * BEAT, N["G4"], 90, 900)
    pno.note(p + 3 * BEAT, N["C5"], 94, 900)
    p = bar(8)
    pno.note(p, N["B4"], 92, 900)
    pno.note(p + BEAT, N["A4"], 90, 900)
    pno.note(p + 2 * BEAT, N["G4"], 92, 1800)

    KICK, SNARE, HIHAT, TOM = 36, 38, 42, 45
    DRUM_DUR = 480                       # 鼓给八分音符的长度（别太短，怕被 off 切掉）
    for b in (5, 6, 7):
        t = bar(b)
        drum.note(t, KICK, 120, DRUM_DUR)               # 拍 1
        drum.note(t + 2 * BEAT, KICK, 118, DRUM_DUR)    # 拍 3
        drum.note(t + BEAT, SNARE, 118, DRUM_DUR)       # 拍 2
        drum.note(t + 3 * BEAT, SNARE, 118, DRUM_DUR)   # 拍 4
        for k in (1, 3, 5, 7):                          # HiHat 只打反拍
            drum.note(t + k * 480, HIHAT, 100, DRUM_DUR)
    t = bar(8)                                          # 第 8 小节：加 tom 过门
    drum.note(t, KICK, 120, DRUM_DUR)
    drum.note(t + 2 * BEAT, KICK, 118, DRUM_DUR)
    drum.note(t + BEAT, SNARE, 118, DRUM_DUR)
    drum.note(t + 3 * BEAT, SNARE, 118, DRUM_DUR)
    drum.note(t + 480, HIHAT, 100, DRUM_DUR)
    drum.note(t + 1440, HIHAT, 100, DRUM_DUR)
    drum.note(t + 2400, TOM, 112, DRUM_DUR)             # 拍 3.5
    drum.note(t + 3360, TOM, 112, DRUM_DUR)             # 拍 4.5

    # ---------------- 第 9~12 小节：慢下来，收尾 ----------------
    S3 = (
        (9, PAD_AM, [45, 52, 57, 52], "A2"),
        (10, PAD_F, [41, 48, 53, 48], "F2"),
        (11, PAD_G, [43, 50, 55, 50], "G2"),
        (12, PAD_AM, [45, 52, 57, 52], "A2"),
    )
    for b, pch, gch, root in S3:
        t = bar(b)
        pad.chord(t, pch, 64, BAR - 1)
        for k in range(4):
            bass.note(t + k * BEAT, N[root] + (12 if k % 2 else 0), 92, 800)
            gtr.note(t + k * BEAT, gch[k], 78, 800)

    p = bar(9)
    pno.note(p, N["A4"], 90, 1800)
    pno.note(p + 2 * BEAT, N["C5"], 90, 1800)
    p = bar(10)
    pno.note(p, N["A4"], 90, 1800)
    pno.note(p + 2 * BEAT, N["F4"], 90, 1800)
    p = bar(11)
    pno.note(p, N["G4"], 90, 1800)
    pno.note(p + 2 * BEAT, N["B4"], 90, 900)
    # 下面这个 A4 的【结束 tick 正好落在第 12 小节起点】，
    # 而第 12 小节第一个音也是 A4 => 同一 tick 上 off 必须先于 on
    pno.note(p + 3 * BEAT, N["A4"], 90, 960)
    p = bar(12)
    pno.note(p, N["A4"], 92, 1800)
    pno.note(p + 2 * BEAT, N["E4"], 88, 1800)

    for b in (9, 10, 11):
        t = bar(b)
        drum.note(t, KICK, 118, DRUM_DUR)
        drum.note(t + 2 * BEAT, KICK, 116, DRUM_DUR)
        drum.note(t + BEAT, SNARE, 116, DRUM_DUR)
        drum.note(t + 3 * BEAT, SNARE, 116, DRUM_DUR)
        drum.note(t + 480, HIHAT, 96, DRUM_DUR)
        drum.note(t + 1440, HIHAT, 96, DRUM_DUR)
    # 第 12 小节：故意同 tick 敲三件（已知 same_hit 问题的探针）
    t = bar(12)
    drum.note(t, KICK, 120, DRUM_DUR)
    drum.note(t, SNARE, 118, DRUM_DUR)
    drum.note(t, HIHAT, 100, DRUM_DUR)
    drum.note(t + BEAT, HIHAT, 100, DRUM_DUR)
    drum.note(t + 2 * BEAT, TOM, 112, DRUM_DUR)

    return [tempo, bass, gtr, pno, pad, drum]


def summarize(tracks):
    print("=" * 74)
    print("四音色 + 鼓机 + 变速 测试小段子")
    print("=" * 74)
    tot = 0
    for tk in tracks:
        n_note = sum(1 for e in tk.ev if e[2][0] & 0xF0 in (0x90, 0x80))
        n_on = sum(1 for e in tk.ev if e[2][0] & 0xF0 == 0x90)
        tot += n_note
        extra = ""
        if isinstance(tk, Conductor):
            extra = "  tempo 点 = %d" % len(tk.ev)
        print("  %-8s ch=%-3s 音符 %3d（on/off 共 %3d）%s"
              % (tk.name, "-" if tk.channel is None else (tk.channel + 1),
                 n_on, n_note, extra))
    print("  MIDI 事件总数（含 off 与 tempo）= %d" % tot)
    print("  长度 = 12 小节 = %d tick（%.2f 小节 @ 4/4 PPQN %d）"
          % (12 * BAR, 12 * BAR / float(BAR), PPQN))


def main(argv=None):
    ap = argparse.ArgumentParser(description="生成四音色+鼓机+变速的测试 MIDI")
    ap.add_argument("--out", default=None, help="输出 .mid 路径")
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "四音色鼓机变速-测试曲.mid")

    tracks = compose()
    summarize(tracks)
    n = write_midi(out, tracks)
    print("  已写出：%s（%d 字节）" % (out, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
