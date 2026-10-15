#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""四音色 + 鼓机 + 变速 的测试小段子（生成 .mid）。

风格：house 律动（四踩底鼓 / 反拍踩镲 / 反拍钢琴 stab）+ funk 吉他 riff。
长度：8 小节，约 17 秒 —— 尽量短，但每一小节都在测东西。

用途
    给「曲谱上位机」（esp32/tools/score_studio.html）做一次灌谱验证。
    一次把五件事都测到：

      1. 四个音色同时出声 —— BASS / GUITAR / PIANO / PAD
      2. 鼓机四件都响     —— Kick / Snare / HiHat / Tom
      3. 变速             —— 100 -> 126 -> 108 BPM，三个 tempo 点
      4. 和弦             —— 同一时刻多个音，逼上位机把音摊到多条轴
      5. 复音             —— 第 7 小节【每半拍加一个音】，最后 10 个音同时响
                             （音高互不重复 => 能一个一个数出来；这是本曲最"吵"的地方）

编曲（一小节一个和弦：Am7 Dm7 Fmaj7 E7 Am7 Dm7 Fmaj7 Am7）

    小节  速度    Pad   Bass   Piano  Guitar  鼓
    1     100     ✓     -      -      -       kick+hat          <- 起速
    2     100     ✓     ✓      -      -       kick+hat
    3     126     ✓     ✓      ✓      -       全鼓（提速 drop）
    4     126     ✓     ✓      ✓      ✓       全鼓
    5     126     ✓     ✓      ✓      ✓       全鼓
    6     126     ✓     ✓      ✓      ✓       全鼓 + tom 过门
    7     108     └──── 复音阶梯：每半拍进一个音，最后 10 个音同时响 ────┘  kick+hat
    8     108     ✓     ✓      ✓      ✓       收尾 + 鼓探针

    => 四个音色同框在小节 4/5/6/7/8；鼓机四件在 3~6 与 8；变速在 1/3/7 小节头；
       复音峰值 10 声（第 7 小节末），可用轴 0..14 够用。

为什么给 .mid 而不是 events.hex
    上位机从 2026-10-14 起能【直接在浏览器里读 .mid】，
    所以给 .mid 最省事；同目录的 verify_piece.js 会用
    【网页自己的解析器】把它转成 events.hex，Python 那条路也能用。

有意避开 / 有意保留
    避开：鼓的【不同件】在【同一 tick】同时敲 —— 已知未解决项
          （same_hit 复用，见
           files/20-代码/ESP32侧追问-同时敲多个鼓与same_hit-20261014.md）
          => 主 groove 里 kick / snare / hat 的落点【互不相同】。
          ⚠️ 这也解释了为什么底鼓不是"四踩"：底鼓踩满四拍时，
             snare 落 2/4 拍必然与底鼓同 tick => 会踩到那个已知问题。
    保留：第 8 小节第 4 拍【故意】让 kick + snare + hihat 同 tick 敲一下，
          当作该已知问题的探针。预期见 README。

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
# 和弦表：pad 长音三音 / piano stab 三音 / bass 根音 / guitar riff 六个音
# ⚠️ 音区分工（避免糊在一起）：
#     bass  110~175 Hz · pad 220~392 Hz · piano 262~440 Hz · guitar 330~700 Hz
CH = {
    "Am7":   {"pad": (57, 64, 67), "stab": (60, 64, 67), "root": 45,
              "gtr": (69, 72, 76, 72, 69, 64)},
    "Dm7":   {"pad": (57, 62, 65), "stab": (62, 65, 69), "root": 50,
              "gtr": (69, 74, 77, 74, 69, 65)},
    "Fmaj7": {"pad": (57, 60, 65), "stab": (60, 65, 69), "root": 53,
              "gtr": (69, 72, 77, 72, 69, 65)},
    "E7":    {"pad": (56, 59, 64), "stab": (59, 62, 64), "root": 52,
              "gtr": (68, 71, 76, 71, 68, 64)},
}
PROG = ["Am7", "Dm7", "Fmaj7", "E7", "Am7", "Dm7", "Fmaj7", "Am7"]

TEMPO_PLAN = ((1, 100), (3, 126), (7, 108))     # 小节 -> BPM

# house/funk 贝斯：反拍为主 + 十六分推音（全部根音，不糊）
BASS_HITS = ((480, 280), (720, 180), (1440, 280), (1920, 280),
             (2400, 280), (3120, 180))
# house 钢琴 stab：四个反拍
PIANO_HITS = (480, 1440, 2400, 3360)
# funk 吉他：十六分切分（避开钢琴的落点，两者互相穿插而不是叠在一起）
GTR_POS = (240, 720, 1440, 2160, 2640, 3120)

# 鼓（GM 音高）：36 Kick · 38 Snare · 42 HiHat · 45 Tom
KICK, SNARE, HIHAT, TOM = 36, 38, 42, 45
DRUM_DUR = 480
DRUM_VEL = {KICK: 122, SNARE: 116, HIHAT: 100, TOM: 112}
# ⚠️ 每一档里【同一 tick 只允许出现一件】—— 见文件头的"有意避开"
DRUM_BARS = {
    1: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    2: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    3: {"kick": (0, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 1440, 2400, 3360), "tom": ()},
    4: {"kick": (0, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 1440, 2400, 3360), "tom": ()},
    5: {"kick": (0, 1920, 3120), "snare": (960, 2880),
        "hat": (480, 1440, 2400, 3360), "tom": ()},
    # 第 6 小节后半：tom 过门（把 snare/hat 让开，⛔ 不与 tom 撞 tick）
    6: {"kick": (0, 1920), "snare": (960,), "hat": (480, 1440),
        "tom": (2400, 2640, 2880, 3120, 3360)},
    # 第 7 小节：breakdown，鼓只留 kick + hat
    7: {"kick": (0, 1920), "snare": (), "hat": (480, 1440, 2400, 3360), "tom": ()},
    # 第 8 小节：⭐ 第 4 拍（2880）kick+snare+hihat 同 tick —— 已知问题的探针
    8: {"kick": (0, 1920, 2880), "snare": (960, 2880),
        "hat": (480, 1440, 2400, 2880), "tom": (3360,)},
}
# 音色轨只在这些小节出现（其余留白 => 听得清每件乐器是什么时候进来的）
# ⚠️ 第 7 小节【不走常规织体】—— 它整小节是"复音阶梯"，由 LADDER 单独生成。
BASS_BARS = (2, 3, 4, 5, 6, 8)
PIANO_BARS = (3, 4, 5, 6, 8)
GTR_BARS = (4, 5, 6, 8)

# ⭐ 复音阶梯（第 7 小节，Fmaj7）：每半拍（480 tick）进一个音，
#    全部【撑到小节末】=> 最后 10 个音同时响。
#    为什么这样设计：
#      · 一个一个进 => 耳朵能听出"又加了一个声部"，能【数】
#      · 音高【互不重复】（Fmaj7 的十个不同音）=> 不会因同音高相位干涉而听糊
#      · 10 声 < 可用轴 15 条 => 不会抢轴，也不会顶到 FPGA 的 32 voice 上限
#    (半拍序号, 轨, 音高)；同一序号里的多个音是一起进的
LADDER = (
    (0, "pad",    (57, 60, 65)),   # A3 C4 F4 —— 铺底三音一起进
    (0, "bass",   41),             # F2 —— 低音撑住
    (1, "piano",  64),             # E4
    (2, "piano",  69),             # A4
    (3, "guitar", 72),             # C5
    (4, "guitar", 76),             # E5
    (5, "bass",   53),             # F3
    (6, "piano",  77),             # F5  => 此刻 10 个音同时在响
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

    # ---- Pad：整曲铺底（长音，力度压低，别盖住别的音色）----
    # ⚠️ 第 7 小节的 pad 音在 LADDER 里（作为阶梯的第一级），这里跳过。
    for i, name in enumerate(PROG):
        if i == 6:
            continue
        pad.chord(bar(i + 1), CH[name]["pad"], 62, BAR - 1)

    # ---- Bass：反拍律动 ----
    for b in BASS_BARS:
        t = bar(b)
        root = CH[PROG[b - 1]]["root"]
        for off, dur in BASS_HITS:
            bass.note(t + off, root, 100, dur)

    # ---- Piano：house stab（三音和弦，短促）----
    for b in PIANO_BARS:
        t = bar(b)
        for off in PIANO_HITS:
            pno.chord(t + off, CH[PROG[b - 1]]["stab"], 88, 240)

    # ---- Guitar：funk riff（十六分切分）----
    for b in GTR_BARS:
        t = bar(b)
        for off, midi in zip(GTR_POS, CH[PROG[b - 1]]["gtr"]):
            gtr.note(t + off, midi, 84, 200)

    # ---- 第 7 小节：复音阶梯（每半拍进一个音，最后 10 个音同时响）----
    t7 = bar(7)
    for slot, who, pitch in LADDER:
        t0 = t7 + slot * E8
        dur = BAR - slot * E8            # ⭐ 全部撑到小节末 => 一起收，末尾 10 声齐鸣
        if who == "pad":
            pad.chord(t0, pitch, 62, dur)
        elif who == "bass":
            bass.note(t0, pitch, 96, dur)
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
    print("四音色 + 鼓机 + 变速 · house/funk 测试小段子（8 小节）")
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
    ap = argparse.ArgumentParser(description="生成四音色+鼓机+变速的测试 MIDI")
    ap.add_argument("--out", default=None, help="输出 .mid 路径")
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(here, "四音色鼓机变速-house-funk-测试曲.mid")

    tracks = compose()
    summarize(tracks)
    n = write_midi(out, tracks)
    print("  已写出：%s（%d 字节）" % (out, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
