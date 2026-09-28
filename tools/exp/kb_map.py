#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kb_map.py -- 从"钢琴音高图 + 轴号映射"算出 kb_inc 表

来源：
  ① 钢琴音高图 files/10-硬件/钢琴音高映射图.drawio.svg
     · 左边 = 左手板的【左边板】（片0）
     · 右边 = 左手板的【右边板】（片1）
     · 每板 8 键：上排 = 黑键(升号)，下排 = 白键
     · 排列顺序 = 从左到右 4 列
  ② 轴号映射 files/10-硬件/霍尔键位映射图.drawio.png
     · 每板内 上排 CH = 6 7 0 1   （物理列 1~4）
     · 每板内 下排 CH = 5 4 3 2   （物理列 1~4）
     · 轴号 = 片号 * 8 + CH
"""

FS = 48828.125

# ── 音高图（排列 1..4 从左到右）──────────────────────────────
#   左板（片0）
LEFT_UP   = ['C3#', 'D3#', 'E3',  'F3#']   # 上排 = 黑键
LEFT_DOWN = ['C3',  'D3',  'E3',  'F3']    # 下排 = 白键
#   右板（片1）
RIGHT_UP   = ['G3#', 'A3#', 'B3',  'C4#']
RIGHT_DOWN = ['G3',  'A3',  'B3',  'C4']

# ── 每板内 CH 分配（物理列序 1..4）────────────────────────────
UP_CH   = [6, 7, 0, 1]     # 上排列1..4
DOWN_CH = [5, 4, 3, 2]     # 下排列1..4

# ── 音名 -> 半音数（相对 C）──────────────────────────────────
NOTE_SEMI = {'C':0,'C#':1,'D':2,'D#':3,'E':4,'F':5,'F#':6,
             'G':7,'G#':8,'A':9,'A#':10,'B':11}

def parse(name):
    """'C3#' -> ('C#', 3) ; 'E3' -> ('E', 3)"""
    name = name.strip()
    if name.endswith('#'):
        return name[:-1], 3
    return name, 3

def midi(name):
    """音名 -> MIDI 号。C4 = 60.  接受 'C3' 'C3#' 'A#3' """
    name = name.strip()
    sharp = name.endswith('#')
    if sharp:
        name = name[:-1]                 # 'C3#'
    base = name[:-1]                     # 'C'
    octv = int(name[-1])                 # 3
    semi = NOTE_SEMI[base + ('#' if sharp else '')]
    return (octv + 1) * 12 + semi

def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)

def inc(m):
    return int(round(hz(m) * (2**32) / FS))

# ── 组表 ─────────────────────────────────────────────────────
tbl = {}   # axis -> (音名, MIDI, Hz, inc)
for col in range(4):
    # 片0（左板）
    ch = UP_CH[col]
    axis = 0 * 8 + ch
    tbl[axis] = LEFT_UP[col]
    ch = DOWN_CH[col]
    axis = 0 * 8 + ch
    tbl[axis] = LEFT_DOWN[col]
    # 片1（右板）
    ch = UP_CH[col]
    axis = 1 * 8 + ch
    tbl[axis] = RIGHT_UP[col]
    ch = DOWN_CH[col]
    axis = 1 * 8 + ch
    tbl[axis] = RIGHT_DOWN[col]

print("=" * 78)
print(" 钢琴模式音高表（kb_inc）—— 按轴号排序")
print("=" * 78)
print()
print("  轴  片  CH  行     音名    MIDI   频率(Hz)     phase_inc")
print("  --- --  --  -----  ------  ----  ----------   ----------")
for axis in range(16):
    name = tbl[axis]
    m = midi(name)
    h = hz(m)
    i = inc(m)
    board = axis // 8
    ch = axis % 8
    row = '下(白)' if ch in DOWN_CH else '上(黑)'
    print("  %2d   %d  %2d  %s  %-6s  %4d  %9.2f   0x%08X"
          % (axis, board, ch, row, name, m, h, i))
print()

# ── 校验：是否构成连续半音阶 ─────────────────────────────────
ms = sorted(midi(tbl[a]) for a in range(16))
print("  音域: %s ~ %s  (MIDI %d ~ %d)" %
      (tbl[min(tbl, key=lambda a: midi(tbl[a]))],
       tbl[max(tbl, key=lambda a: midi(tbl[a]))], ms[0], ms[-1]))
print("  不同音高数 = %d / 16" % len(set(ms)))
dups = [m for m in set(ms) if ms.count(m) > 1]
print("  重复音     = %s" % (["%s(出现%d次)" % (m, ms.count(m)) for m in sorted(dups)] if dups else "无"))
print()
print("  半音覆盖（C3..C4 应为 0..12 共 13 个）：")
have = set(m - 48 for m in ms)      # C3 的 MIDI = 48
miss = [n for n in range(13) if n not in have]
print("    已有 %d 个: %s" % (len(have), sorted(have)))
print("    ⚠️ 缺 %s" % miss if miss else "    ✅ 完整覆盖 C3..C4")
print()
print("=" * 78)
print(" Verilog 表（可直接粘进 axis_map.v）")
print("=" * 78)
print()
LN = {'C':"C",'C#':"Cs",'D':"D",'D#':"Ds",'E':"E",'F':"F",'F#':"Fs",
      'G':"G",'G#':"Gs",'A':"A",'A#':"As",'B':"B"}

def label(name):
    """'C3' -> 'C3' ; 'C3#' -> 'Cs3'"""
    sharp = name.endswith('#')
    n = name[:-1] if sharp else name
    return LN[n[:-1] + ('#' if sharp else '')] + n[-1]

for axis in range(16):
    name = tbl[axis]
    m = midi(name)
    ch = axis % 8
    cmt = "左板" if axis < 8 else "右板"
    cmt += " 上排" if ch in UP_CH else " 下排"
    print("        kb_inc[%2d] = KB_%-4s  // %-5s (%6.2f Hz)  %s"
          % (axis, label(name) + ";", name, hz(m), cmt))
