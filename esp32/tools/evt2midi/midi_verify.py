#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
midi_verify.py —— ⭐ **按 MIDI 规范把 `.mid` 读回来**，用于端到端核对

═══ 为什么要单独一个工具 ═══
🔴 **只检查 `MThd` 文件头是【假绿】** —— ⚠️ 头对了，内容可以**全错**
   （⭐ 音高错、力度错、时间轴整体偏移 —— ⭐ 头都还是对的）。
⇒ ⭐ 真正的判据是：**把事件按规范读回来，逐项比对音高 / 力度 / 时序**。

⭐⭐ 本文件是**独立实现**（⛔ 不复用 `evt2midi.py` 的写侧代码）：
   ⚠️ 若读写共用一套代码，⭐ "自己写的 bug"会被"自己写的检查"放过
   ⇒ 🔴 那就等于**没验证**（⭐ 与 `C83` 探针假绿同族）。

═══ 覆盖的规范点 ═══
   · `MThd`（长度必须 6）/ `MTrk` / PPQN（⛔ 拒绝 SMPTE 时基）
   · **变长量**（每字节 7 位，最多 4 字节）
   · **running status**（⚠️ 真实文件常用，⭐ 我们的写侧不用 ⇒ 读侧必须能读）
   · 元事件 `FF xx len ...`（⭐ 含 `FF 51` tempo、`FF 2F` 轨结束）
   · `F0`/`F7` 系统独占（⭐ 按长度跳过）
   · note_on **力度 0 = note_off**（⭐ 规范定义，⛔ 不是 on）
   · 🔴 **截断 / 长度越界 / 轨长不符 ⇒ 抛错**（⛔ 不"尽量解"）

═══ 用法 ═══
    python midi_verify.py --selftest
    python midi_verify.py --in song.mid                 # 打印事件表
    python midi_verify.py --in song.mid --expect exp.json   # 逐项核对
"""

import argparse
import json
import sys

# ⚠️ 控制台 UTF-8 —— 中文 Windows 默认 GBK（⭐ 不加会 UnicodeEncodeError）
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


class MidiError(ValueError):
    """⭐ 文件不符合 MIDI 规范（⚠️ 含被截断）—— ⛔ 一律拒收，⛔ 不"尽量解"。"""


def _u16(b, i):
    if i + 2 > len(b):
        raise MidiError("越界读 u16 @%d（长度 %d）" % (i, len(b)))
    return int.from_bytes(b[i:i + 2], "big")


def _u32(b, i):
    if i + 4 > len(b):
        raise MidiError("越界读 u32 @%d（长度 %d）" % (i, len(b)))
    return int.from_bytes(b[i:i + 4], "big")


def read_var_len(b, i, end):
    """
    ⭐ MIDI 变长量：⭐ 每字节低 7 位，⭐ 最高位 = "还有后续"。
    ⚠️ 规范上限 **4 字节** ⇒ 🔴 第 5 字节还在续 ⇒ 拒收（⛔ 防死循环 / 防垃圾）。
    """
    v = 0
    for k in range(4):
        if i >= end:
            raise MidiError("变长量越界 @%d" % i)
        c = b[i]
        i += 1
        v = (v << 7) | (c & 0x7F)
        if not (c & 0x80):
            return v, i
    raise MidiError("变长量超过 4 字节 @%d（⚠️ 规范上限）" % i)


def read_track(b, i, end):
    """
    ⭐ 读一条轨，返回事件表：⭐ 每条 = dict（⭐ `t` 是**绝对** tick）。
    ⚠️ 事件种类：`on` / `off` / `meta` / `sysex` / `cc` / `other`
    """
    evs = []
    t = 0
    running = None
    while i < end:
        d, i = read_var_len(b, i, end)
        t += d
        if i >= end:
            raise MidiError("事件缺状态字节 @%d" % i)
        st = b[i]

        # ---- 元事件 ----
        if st == 0xFF:
            i += 1
            if i >= end:
                raise MidiError("元事件缺类型 @%d" % i)
            meta = b[i]
            i += 1
            ln, i = read_var_len(b, i, end)
            if i + ln > end:
                raise MidiError("元事件越界（meta=0x%02X len=%d）" % (meta, ln))
            payload = bytes(b[i:i + ln])
            i += ln
            evs.append({"kind": "meta", "t": t, "meta": meta, "data": payload})
            running = None
            if meta == 0x2F:                     # ⭐ 轨结束
                if ln != 0:
                    raise MidiError("轨结束元事件长度应为 0，实为 %d" % ln)
                if i != end:
                    raise MidiError("轨结束标记后还有 %d 字节（⚠️ 轨长不符）"
                                    % (end - i))
                return evs
            continue

        # ---- 系统独占 ----
        if st in (0xF0, 0xF7):
            i += 1
            ln, i = read_var_len(b, i, end)
            if i + ln > end:
                raise MidiError("sysex 越界 @%d" % i)
            i += ln
            evs.append({"kind": "sysex", "t": t, "status": st})
            running = None
            continue

        # ---- running status ----
        if st & 0x80:
            status = st
            i += 1
            running = status
        else:
            if running is None:
                raise MidiError("running status 但没有前置状态字节 @%d" % i)
            status = running

        hi = status & 0xF0
        if hi in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
            if i + 2 > end:
                raise MidiError("通道事件越界 @%d（status=0x%02X）" % (i, status))
            a, v = b[i], b[i + 1]
            i += 2
            if hi == 0x90 and v > 0:
                kind = "on"
            elif hi == 0x80 or (hi == 0x90 and v == 0):
                kind = "off"
            elif hi == 0xB0:
                kind = "cc"
            else:
                kind = "other"
            evs.append({"kind": kind, "t": t, "ch": status & 0x0F,
                        "note": a, "vel": v, "status": status})
        elif hi in (0xC0, 0xD0):
            if i + 1 > end:
                raise MidiError("通道事件越界 @%d（status=0x%02X）" % (i, status))
            a = b[i]
            i += 1
            evs.append({"kind": "other", "t": t, "status": status, "a": a})
        else:
            raise MidiError("非法状态字节 0x%02X @%d" % (status, i))
    raise MidiError("轨里没有 `FF 2F` 轨结束标记（⚠️ 被截断？）")


def read_midi(data):
    """
    ⭐ 读一个 `.mid`（bytes）⇒ dict：
      `format` / `ntrks` / `division` / `tempo_us`（⚠️ 可能是 None）/ `events`

    🔴 严格：⚠️ 任何越界 / 长度不符 / 缺轨结束 ⇒ ⭐ 抛 `MidiError`。
    """
    if len(data) < 14:
        raise MidiError("文件太短：%d 字节（⭐ MThd 就要 14）" % len(data))
    if data[:4] != b"MThd":
        raise MidiError("不是 MIDI：头 4 字节 = %r（⭐ 应为 b'MThd'）" % data[:4])
    hlen = _u32(data, 4)
    if hlen != 6:
        raise MidiError("MThd 长度应为 6，实为 %d" % hlen)
    fmt = _u16(data, 8)
    ntrks = _u16(data, 10)
    div = _u16(data, 12)
    if div & 0x8000:
        raise MidiError("SMPTE 时基（division=0x%04X）⚠️ 本工具只支持 PPQN" % div)
    if div == 0:
        raise MidiError("division = 0（⚠️ 非法）")

    i = 8 + hlen
    tracks = []
    for k in range(ntrks):
        if data[i:i + 4] != b"MTrk":
            raise MidiError("第 %d 条轨缺 MTrk（偏移 %d：%r）"
                            % (k, i, data[i:i + 4]))
        tlen = _u32(data, i + 4)
        i += 8
        end = i + tlen
        if end > len(data):
            raise MidiError("第 %d 条轨声明 %d B，实际只剩 %d B（⚠️ 截断）"
                            % (k, tlen, len(data) - i))
        tracks.append(read_track(data, i, end))
        i = end

    evs = [e for tr in tracks for e in tr]
    tempo = None
    for e in evs:
        if e["kind"] == "meta" and e["meta"] == 0x51:
            if len(e["data"]) != 3:
                raise MidiError("tempo 元事件长度应为 3，实为 %d" % len(e["data"]))
            tempo = int.from_bytes(e["data"], "big")
            break
    return {"format": fmt, "ntrks": ntrks, "division": div,
            "tempo_us": tempo, "tracks": tracks, "events": evs}


def read_midi_file(path):
    with open(path, "rb") as f:
        return read_midi(f.read())


def notes_of(res):
    """⭐ 只取 note_on / note_off（⭐ 便于逐项比对）。"""
    return [e for e in res["events"] if e["kind"] in ("on", "off")]


def bpm_of(res):
    """⭐ 由 tempo 元事件反算 BPM（⚠️ 没有 tempo ⇒ None ⇒ 播放器按 120）。"""
    return None if res["tempo_us"] in (None, 0) else 60_000_000.0 / res["tempo_us"]


def compare(res, expect):
    """
    ⭐ 逐项核对（⭐ 返回 `[(名称, 通过?, 说明)]`）。

    `expect` 的键（⭐ 都可选）：
      · `division`  ⭐ 期望 PPQN
      · `bpm`       ⭐ 期望速度（⭐ 由 tempo 元事件反算）
      · `events`    ⭐ `[[kind, t, note, vel], ...]`（⭐ 绝对 tick）
    """
    out = []
    if "division" in expect:
        out.append(("division", res["division"] == expect["division"],
                    "实为 %d，期望 %d" % (res["division"], expect["division"])))
    if "bpm" in expect:
        got = bpm_of(res)
        good = got is not None and abs(got - expect["bpm"]) < 0.01
        out.append(("bpm(tempo)", good,
                    "实为 %s，期望 %.3f" % ("None" if got is None else "%.3f" % got,
                                            expect["bpm"])))
    if "events" in expect:
        got = [[e["kind"], e["t"], e.get("note"), e.get("vel")] for e in notes_of(res)]
        want = [list(x) for x in expect["events"]]
        out.append(("事件序列", got == want, "实为 %s，期望 %s" % (got, want)))
    return out


# ============================================================================
# ⭐ 自检（⛔ 不需要硬件、⛔ 不需要外部文件）
# ============================================================================
def _vl(v):
    buf = [v & 0x7F]
    v >>= 7
    while v:
        buf.append((v & 0x7F) | 0x80)
        v >>= 7
    return bytes(reversed(buf))


def _mk(track_bytes, ntrks=1, div=960, fmt=0):
    return (b"MThd" + (6).to_bytes(4, "big") + fmt.to_bytes(2, "big")
            + ntrks.to_bytes(2, "big") + div.to_bytes(2, "big")
            + b"MTrk" + len(track_bytes).to_bytes(4, "big") + track_bytes)


def selftest():
    print("=" * 74)
    print("midi_verify.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-48s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    def raises(fn, *a, **kw):
        try:
            fn(*a, **kw)
            return False
        except MidiError:
            return True

    print("\n[1] ⭐ 变长量")
    chk("  vl(0) = 00", _vl(0) == b"\x00")
    chk("  vl(127) = 7F", _vl(127) == b"\x7f")
    chk("  vl(128) = 81 00", _vl(128) == b"\x81\x00")
    chk("  vl(0x0FFFFFFF) = FF FF FF 7F",
        _vl(0x0FFFFFFF) == b"\xff\xff\xff\x7f")
    chk("  读回 vl(1920)", read_var_len(_vl(1920), 0, 2) == (1920, 2))
    chk("  🔴 5 字节变长量 ⇒ 拒收", raises(read_var_len, b"\x80" * 5, 0, 5))

    print("\n[2] ⭐ 最小合法文件（⭐ 只有轨结束）")
    m = _mk(_vl(0) + b"\xff\x2f\x00")
    r = read_midi(m)
    chk("  division = 960", r["division"] == 960)
    chk("  ntrks = 1", r["ntrks"] == 1)
    chk("  只有 1 条 meta", len(r["events"]) == 1 and r["events"][0]["kind"] == "meta")
    chk("  它是轨结束 0x2F", r["events"][0]["meta"] == 0x2F)
    chk("  ⛔ 没有 tempo ⇒ bpm_of = None", bpm_of(r) is None)

    print("\n[3] ⭐⭐ 事件解码：⭐ 绝对 tick 累加 + note_on 力度 0 = off")
    tr = bytearray()
    tr += _vl(0) + bytes([0xFF, 0x51, 0x03]) + (500000).to_bytes(3, "big")   # tempo 120
    tr += _vl(0) + bytes([0x90, 69, 100])
    tr += _vl(480) + bytes([0x80, 69, 64])
    tr += _vl(0) + bytes([0x90, 72, 0])          # ⭐ 力度 0 ⇒ 规范上是 off
    tr += _vl(0) + bytes([0xFF, 0x2F, 0x00])
    r = read_midi(_mk(bytes(tr)))
    ns = notes_of(r)
    chk("  tempo 反算 120 BPM", abs(bpm_of(r) - 120.0) < 1e-6)
    chk("  3 个音符事件", len(ns) == 3, "  %s" % [(e["kind"], e["t"]) for e in ns])
    chk("  第 1 个是 on t=0 note=69 vel=100",
        (ns[0]["kind"], ns[0]["t"], ns[0]["note"], ns[0]["vel"]) == ("on", 0, 69, 100))
    chk("  第 2 个是 off t=480（⭐ 绝对 tick 累加对）",
        (ns[1]["kind"], ns[1]["t"]) == ("off", 480))
    chk("  ⭐ 力度 0 的 note_on 被判为 off（⭐ 规范）", ns[2]["kind"] == "off")

    print("\n[4] ⭐⭐ running status（⭐ 真实文件常用，⛔ 我们的写侧不用）")
    tr = bytearray()
    tr += _vl(0) + bytes([0x90, 60, 64])      # 带状态
    tr += _vl(10) + bytes([62, 64])           # ⭐ 省略状态（running）
    tr += _vl(10) + bytes([64, 0])            # ⭐ 省略状态 + 力度 0 = off
    tr += _vl(0) + bytes([0xFF, 0x2F, 0x00])
    r = read_midi(_mk(bytes(tr)))
    ns = notes_of(r)
    chk("  running status 解出 3 条", len(ns) == 3)
    chk("  音高 60/62/64", [e["note"] for e in ns] == [60, 62, 64])
    chk("  第 3 条是 off", ns[2]["kind"] == "off")
    chk("  ⭐ 绝对 tick = 0/10/20", [e["t"] for e in ns] == [0, 10, 20])

    print("\n[5] ⭐ sysex 按长度跳过")
    tr = bytearray()
    tr += _vl(0) + bytes([0xF0, 0x03, 0x7E, 0x7F, 0xF7])
    tr += _vl(0) + bytes([0x90, 60, 64])
    tr += _vl(0) + bytes([0x80, 60, 64])
    tr += _vl(0) + bytes([0xFF, 0x2F, 0x00])
    r = read_midi(_mk(bytes(tr)))
    chk("  sysex 被跳过且不影响后面",
        [e["kind"] for e in notes_of(r)] == ["on", "off"])

    print("\n[6] ⭐⭐ 反例（非空洞性）：坏文件必须【拒收】")
    good = _mk(_vl(0) + bytes([0x90, 60, 64]) + _vl(0) + bytes([0xFF, 0x2F, 0x00]))
    chk("  正常文件不抛错", not raises(read_midi, good))
    chk("  空文件 ⇒ 拒收", raises(read_midi, b""))
    chk("  头不是 MThd ⇒ 拒收", raises(read_midi, b"RIFF" + good[4:]))
    chk("  MThd 长度 ≠ 6 ⇒ 拒收",
        raises(read_midi, good[:4] + (5).to_bytes(4, "big") + good[8:]))
    chk("  ⚠️ 截断（去掉末尾 1 字节）⇒ 拒收", raises(read_midi, good[:-1]))
    chk("  ⚠️ 轨长声明过大 ⇒ 拒收",
        raises(read_midi, good[:14] + b"MTrk" + (9999).to_bytes(4, "big") + good[22:]))
    chk("  ⚠️ 缺轨结束标记 ⇒ 拒收",
        raises(read_midi, _mk(_vl(0) + bytes([0x90, 60, 64]))))
    chk("  ⚠️ 轨结束标记后还有字节 ⇒ 拒收",
        raises(read_midi, _mk(_vl(0) + bytes([0xFF, 0x2F, 0x00]) + b"\x00")))
    chk("  ⚠️ SMPTE 时基 ⇒ 拒收",
        raises(read_midi, _mk(_vl(0) + bytes([0xFF, 0x2F, 0x00]), div=0xE728)))
    chk("  ⚠️ 非法状态字节 ⇒ 拒收",
        raises(read_midi, _mk(_vl(0) + bytes([0x00, 0x00]))))
    chk("  ⚠️ 缺 MTrk ⇒ 拒收", raises(read_midi, good[:14] + b"XXXX" + good[18:]))
    # ⭐⭐ 非空洞：⭐ 证明"改一个字节，结论就变"（⭐ 唯一可信的证明方式）
    flipped = bytearray(good)
    flipped[22 + 1] = 0x91          # ⭐ 把 note_on 状态改成通道 1
    r2 = read_midi(bytes(flipped))
    chk("  ⭐ 非空洞：改 1 字节 ⇒ 通道变了（⭐ 读侧确实在看内容）",
        r2["events"][0]["ch"] == 1)
    flipped2 = bytearray(good)
    flipped2[22 + 2] = 61           # ⭐ 改音高
    chk("  ⭐ 非空洞：改音高字节 ⇒ 音高变了",
        notes_of(read_midi(bytes(flipped2)))[0]["note"] == 61)

    print("\n[7] ⭐⭐ 交叉核对：⭐ 读侧 vs `evt2midi` 的写侧（⭐ 两套独立实现）")
    try:
        import evt2midi as E
        f1 = E._mk_frame(E.T_NOTE_ON, 0, 1000, 0, 38702840, 200)
        f2 = E._mk_frame(E.T_NOTE_OFF, 1, 1000 + 250000, 0, 38702840, 200)
        evs, st = E.parse_stream(f1 + f2)
        midi, _sk, _n = E.build_midi(evs, st)
        rr = read_midi(midi)
        chk("  写侧产出能被读侧解析", rr["division"] == E.PPQN)
        chk("  写侧 tempo = 120 BPM（⭐ 加固新增）", abs(bpm_of(rr) - 120.0) < 1e-6)
        ns = notes_of(rr)
        chk("  读回 2 个音符事件", len(ns) == 2)
        chk("  note_on = 69（440 Hz）", ns[0]["note"] == 69)
        chk("  vel 200 -> 100", ns[0]["vel"] == 100)
        chk("  250000 tick @50MHz = 5 ms -> 9.6 -> 10 MIDI tick",
            ns[1]["t"] == 10, "  实测 %d" % ns[1]["t"])
        # ⭐ 非空洞：⭐ 若读侧不看内容，上面几条不可能同时成立
        chk("  ⭐ 非空洞：改 tempo 后 BPM 反算随之变",
            abs(bpm_of(read_midi(_mk(
                _vl(0) + bytes([0xFF, 0x51, 0x03])
                + (250000).to_bytes(3, "big")
                + _vl(0) + bytes([0xFF, 0x2F, 0x00])))) - 240.0) < 1e-6)
    except ImportError as e:                       # pragma: no cover
        chk("  能 import evt2midi（⭐ 交叉核对的前提）", False, "  %s" % e)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


# ============================================================================
# CLI
# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="按 MIDI 规范读回 .mid 并核对")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需文件）")
    ap.add_argument("--in", dest="inp", help="要读的 .mid")
    ap.add_argument("--expect", help="期望值的 JSON（⭐ 逐项核对）")
    ap.add_argument("--limit", type=int, default=200, help="最多打印多少条事件")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.inp:
        print("RED: 需要 --in（⚠️ 或用 --selftest）")
        return 2

    try:
        res = read_midi_file(args.inp)
    except MidiError as e:
        print("🔴 不是合法的 MIDI：%s" % e)
        return 1

    print("=" * 74)
    print("读回 %s" % args.inp)
    print("=" * 74)
    print("  format   = %d" % res["format"])
    print("  轨数     = %d" % res["ntrks"])
    print("  division = %d (PPQN)" % res["division"])
    bpm = bpm_of(res)
    print("  tempo    = %s" % ("无（⚠️ 播放器按默认 120）" if bpm is None
                               else "%.3f BPM (%d µs/四分音符)" % (bpm, res["tempo_us"])))
    ns = notes_of(res)
    print("  音符事件 = %d（on=%d off=%d）"
          % (len(ns), sum(1 for e in ns if e["kind"] == "on"),
             sum(1 for e in ns if e["kind"] == "off")))
    print()
    for e in res["events"][:args.limit]:
        if e["kind"] == "meta":
            print("  t=%-8d meta 0x%02X len=%d %s"
                  % (e["t"], e["meta"], len(e["data"]), e["data"].hex(" ")))
        elif e["kind"] in ("on", "off"):
            print("  t=%-8d %-3s ch=%d note=%-3d vel=%d"
                  % (e["t"], e["kind"], e["ch"], e["note"], e["vel"]))
        else:
            print("  t=%-8d %s" % (e["t"], e["kind"]))
    if len(res["events"]) > args.limit:
        print("  ... 共 %d 条" % len(res["events"]))

    if not args.expect:
        return 0

    with open(args.expect, "r", encoding="utf-8") as f:
        expect = json.load(f)
    print()
    print("逐项核对：")
    bad = 0
    for name, good, why in compare(res, expect):
        print("  %-14s %s   %s" % (name, "OK" if good else "RED", why))
        if not good:
            bad += 1
    print()
    print("结论：%s" % ("全部核对通过 ✅" if not bad else "%d 项不符 🔴" % bad))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
