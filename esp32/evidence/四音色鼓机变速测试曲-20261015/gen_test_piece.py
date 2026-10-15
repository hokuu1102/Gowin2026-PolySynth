#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""四音色 + 鼓机 + 变速 + 复音 的测试小段子（生成 .mid）。

风格：**funk**（单一风格，⛔ 不混 house —— 用户要求三选一）。
      16 分交错切分的贝斯 / 单音 chank 吉他 / 反拍 clav 和弦 / 弦乐铺底。
长度：8 小节，约 18 秒 —— 尽量短，但每一小节都在测东西。

═══ 一次测五件事 ═══
  1. 四个音色同时出声 —— BASS / GUITAR / PIANO / PAD
  2. 鼓机四件都响     —— Kick / Snare / HiHat / Tom
  3. 变速             —— 104 -> 116 -> 92 BPM，三个 tempo 点
  4. 和弦             —— 同一时刻多个音，逼上位机把音摊到多条轴
  5. 复音             —— 第 7 小节【每半拍加一个音】，最后 10 个音同时响
                         （音高互不重复 => 能一个一个数出来）

═══ ⭐⭐ 硬约束：四个音色各占一个【互不重叠】的音区 ═══
  BASS 38~52 · PAD 52~60 · GUITAR 61~71 · PIANO 72~83

  为什么：两个音色发【同一个频率】时，两个 voice 的相位互相干涉 ——
  mid2evt.py 的文件头写过"可能变响、变薄、或在起音处打拍子，听起来像被敲了两次"。
  📌 用户实测反馈："第一次变速之后怪怪的，好像两个音色没对上"
     => 用 verify_piece.js 判据 ⑨ 量出来：**44 处**跨音色同音高重叠，
        且从第 3 小节（第一次变速、钢琴进来的那一小节）开始，每小节 8~9 处。
        例：PAD+PIANO 音高 64（E4）tick 11520~12240。
  ⇒ ⭐ 所以这里【按音区把音高隔开】，而不是"事后检查"：
     隔开之后"同音高"在结构上就不可能发生（同族 C91：要让它变成不变量）。
     verify_piece.js 判据 ⑨ 会再核一遍（应为 0 处）。

编曲（一小节一个和弦：Dm7 G7 Cmaj7 A7 Dm7 G7 Cmaj7 Dm7）

    小节  速度    Bass  Guitar  Piano  Pad   鼓
    1     104     ✓     -       -      -     kick + hat          <- 起速
    2     104     ✓     ✓       -      -     kick + hat
    3     116     ✓     ✓       ✓      ✓     全鼓（提速 drop）
    4     116     ✓     ✓       ✓      ✓     全鼓
    5     116     ✓     ✓       ✓      ✓     全鼓
    6     116     ✓     ✓       ✓      ✓     全鼓 + tom 过门
    7     92      └──── 复音阶梯：每半拍进一个音，最后 10 个音同时响 ────┘  kick+hat
    8     92      ✓     ✓       ✓      ✓     收尾 + 鼓探针

为什么给 .mid 而不是 events.hex
    上位机从 2026-10-14 起能【直接在浏览器里读 .mid】，
    所以给 .mid 最省事；同目录的 verify_piece.js / check_roll.js 会用
    【网页自己的解析器与绘制层】把它核一遍。

有意避开 / 有意保留（鼓）
    避开：鼓的【不同件】在【同一 tick】同时敲 —— 已知未解决项
          （same_hit 复用，见 ESP32侧追问-同时敲多个鼓与same_hit-20261014.md）
          => 主 groove 里 kick / snare / hat 的落点【互不相同】。
    保留：第 8 小节第 4 拍【故意】让 kick + snare + hihat 同 tick 敲一下，作探针。

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
S16 = 240                  # 十六分音符


def bar(n):
    """第 n 小节（1 起）的起始 tick。"""
    return (n - 1) * BAR


# --------------------------------------------------------------------------- #
# 谱面数据（改曲子只动这一块）
# --------------------------------------------------------------------------- #
# ⭐ 每个和弦在【四个音区】里各取几个音 —— 音区互不重叠，见文件头的硬约束。
#    bass = 根音（低音区）· pad/gtr/pno = 该和弦在那个音区里的音（已排好序）
CH = {
    "Dm7":   {"bass": 50, "fifth": 45, "pad": (53, 57, 60),
              "gtr": (62, 65, 69), "pno": (74, 77, 81)},
    "G7":    {"bass": 43, "fifth": 50, "pad": (55, 59),
              "gtr": (62, 65, 67, 71), "pno": (74, 77, 79, 83)},
    "Cmaj7": {"bass": 48, "fifth": 43, "pad": (52, 55, 60),
              "gtr": (64, 67, 71), "pno": (72, 76, 79)},
    "A7":    {"bass": 45, "fifth": 40, "pad": (55, 57),
              "gtr": (61, 64, 67, 69), "pno": (73, 76, 79, 81)},
}
PROG = ["Dm7", "G7", "Cmaj7", "A7", "Dm7", "G7", "Cmaj7", "Dm7"]

TEMPO_PLAN = ((1, 104), (3, 116), (7, 92))      # 小节 -> BPM

# funk 贝斯：16 分交错（根音 / 五度交替）—— "R"=根音 "F"=五度
BASS_PAT = ((0, "R", 200), (240, "R", 160), (720, "F", 200), (960, "R", 200),
            (1440, "F", 160), (1680, "R", 200), (1920, "R", 200), (2400, "F", 200),
            (2640, "R", 160), (3120, "F", 200))
# funk 吉他：单音 chank（短促），序号 = 该和弦音区里的第几个音
GUITAR_PAT = ((120, 0, 140), (360, 1, 140), (600, 2, 140), (1080, 1, 140),
              (1320, 0, 140), (2040, 1, 140), (2280, 2, 140),
              (2760, 0, 140), (3000, 1, 140))
# clav 和弦 stab：反拍四个
PIANO_PAT = ((480, 200), (1440, 200), (2400, 200), (3360, 200))

# 鼓（GM 音高）：36 Kick · 38 Snare · 42 HiHat · 45 Tom
KICK, SNARE, HIHAT, TOM = 36, 38, 42, 45
DRUM_DUR = 480
DRUM_VEL = {KICK: 122, SNARE: 116, HIHAT: 100, TOM: 112}
# ⚠️ 每一档里【同一 tick 只允许出现一件】—— 见文件头的"有意避开"
DRUM_BARS = {
    1: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    2: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    # 3~5：funk 主 groove —— kick 加一个"和"的推音（1440），所以 hat 让开 1440
    3: {"kick": (0, 1440, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 2400, 3360), "tom": ()},
    4: {"kick": (0, 1440, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 2400, 3360), "tom": ()},
    5: {"kick": (0, 1440, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 2400, 3360), "tom": ()},
    # 6：后半 tom 过门（把 snare/hat 让开，⛔ 不与 tom 撞 tick）
    6: {"kick": (0, 1440, 1920), "snare": (960,), "hat": (480,),
        "tom": (2400, 2640, 2880, 3120, 3360)},
    # 7：复音阶梯那一小节，鼓只留 kick + hat
    7: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    # 8：⭐ 第 4 拍（2880）kick+snare+hihat 同 tick —— 已知问题的探针
    8: {"kick": (0, 1440, 1920, 2880), "snare": (960, 2880),
        "hat": (480, 2400, 2880), "tom": (3360,)},
}
# 各轨出现在哪些小节（其余留白 => 听得清每件乐器什么时候进来）
BASS_BARS = (1, 2, 3, 4, 5, 6, 8)
GTR_BARS = (2, 3, 4, 5, 6, 8)
PIANO_BARS = (3, 4, 5, 6, 8)
PAD_BARS = (3, 4, 5, 6, 8)          # 第 7 小节是阶梯，pad 音在 LADDER 里

# ⭐ 复音阶梯（第 7 小节，Dm7）：每半拍（480 tick）进一个音，
#    全部【撑到小节末】=> 最后 10 个音同时响。
#    十个音【音高互不重复】且横跨四个音区（见硬约束），所以既数得清、也不打架。
#    (半拍序号, 轨, 音高)
LADDER = (
    (0, "pad",    (53, 57, 60)),   # F3 A3 C4 —— 铺底三音一起进
    (0, "bass",   38),             # D2 —— 低音撑住
    (1, "guitar", 62),             # D4
    (2, "piano",  74),             # D5
    (3, "guitar", 65),             # F4
    (4, "piano",  77),             # F5
    (5, "guitar", 69),             # A4
    (6, "piano",  81),             # A5  => 此刻 10 个音同时在响
)


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

    # ---- Pad：弦乐铺底（长音，力度压低，别盖住别的音色）----
    for b in PAD_BARS:
        pad.chord(bar(b), CH[PROG[b - 1]]["pad"], 60, BAR - 1)

    # ---- Bass：16 分交错（根音 / 五度）----
    for b in BASS_BARS:
        t = bar(b)
        c = CH[PROG[b - 1]]
        for off, which, dur in BASS_PAT:
            bass.note(t + off, c["bass"] if which == "R" else c["fifth"], 100, dur)

    # ---- Guitar：单音 chank（短促、切分）----
    for b in GTR_BARS:
        t = bar(b)
        tones = CH[PROG[b - 1]]["gtr"]
        for off, idx, dur in GUITAR_PAT:
            gtr.note(t + off, tones[idx % len(tones)], 84, dur)

    # ---- Piano：clav 和弦 stab（反拍）----
    for b in PIANO_BARS:
        t = bar(b)
        tones = CH[PROG[b - 1]]["pno"]
        for off, dur in PIANO_PAT:
            pno.chord(t + off, tones, 86, dur)

    # ---- 第 7 小节：复音阶梯（每半拍进一个音，最后 10 个音同时响）----
    t7 = bar(7)
    for slot, who, pitch in LADDER:
        t0 = t7 + slot * E8
        dur = BAR - slot * E8            # ⭐ 全部撑到小节末 => 一起收，末尾 10 声齐鸣
        if who == "pad":
            pad.chord(t0, pitch, 60, dur)
        elif who == "bass":
            bass.note(t0, pitch, 98, dur)
        elif who == "piano":
            pno.note(t0, pitch, 86, dur)
        else:
            gtr.note(t0, pitch, 82, dur)

    # ---- 鼓机 ----
    for b in range(1, 9):
        t = bar(b)
        spec = DRUM_BARS[b]
        for name, pitch in (("kick", KICK), ("snare", SNARE),
                            ("hat", HIHAT), ("tom", TOM)):
            for off in spec[name]:
                drum.note(t + off, pitch, DRUM_VEL[pitch], DRUM_DUR)

    return [tempo, bass, gtr, pno, pad, drum]


def summarize(tracks):
    print("=" * 74)
    print("四音色 + 鼓机 + 变速 + 复音 · funk 测试小段子（8 小节）")
    print("=" * 74)
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
    print("  长度 = 8 小节 = %d tick" % (8 * BAR))


def main(argv=None):
    ap = argparse.ArgumentParser(description="生成四音色+鼓机+变速+复音的 funk 测试 MIDI")
    ap.add_argument("--out", default=None, help="输出 .mid 路径")
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "四音色鼓机变速-funk-测试曲.mid")

    tracks = compose()
    summarize(tracks)
    n = write_midi(out, tracks)
    print("  已写出：%s（%d 字节）" % (out, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
