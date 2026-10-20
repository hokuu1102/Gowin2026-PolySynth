#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
demo_midi_roundtrip.py —— MIDI 回传**端到端演示**（离线，不需要硬件）

═══ 这个演示证明什么 ═══
它把"FPGA 回传事件 -> PC 存谱 -> 转 MIDI"这条链**完整跑一遍**，
而且每个环节都用**可核查的判据**钉住，不是"看起来跑通了"。

═══ 为什么必须离线也能演 ═══
FPGA 侧 2026-10-13 明确告知：**14 B 实时事件帧尚未实现**
（他们现在只发 9 B 回传帧）。
=> 真机那一半还在等接线 + 等他们实现。
   但**我方这一侧（解析 + 转 MIDI）现在就能完整验证** ——
   只要喂它"和 FPGA 会发的一模一样的字节"。

═══ 关键：用的字节是【真格式】，不是编的 ═══
事件字来自 `demo_scale.hex`（C 大调音阶，111 个事件），
按 **v1.1 帧结构** 打包成 14 B 帧 —— 与 FPGA 侧将要用的是同一套。
"""

import os
import struct
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "evt2midi"))

import score_word as sw                                    # noqa: E402
from frame_format import (                                 # noqa: E402
    build_frame, parse_frame, frame_checksum,
    T_NOTE_ON, T_NOTE_OFF, T_TRANSPORT_START, T_TABLESYNC,
    PPQN_FPGA, TABLESYNC_ITEMS,
)

OUT_BIN = os.path.join(HERE, "_demo_upstream.bin")
OUT_MID = os.path.join(HERE, "_demo_upstream.mid")

KIND_ON, KIND_OFF, KIND_TEMPO = 0, 1, 2


def word_to_frame_fields(w):
    """把 64 位事件字拆成 v1.1 帧需要的字段。"""
    d = sw.unpack_word(w)
    return d


def build_stream():
    """
    造一段"FPGA 会发上来的字节流"，返回 (bytes, 统计)。

    组成（按 v1.1）：
      · 1 个 0x05 起播锚点（带 tick 快照 + ppqn=960）
      · N 个事件帧（0x01 note_on / 0x02 note_off）
      · 1 个 0x10 表同步帧（16 个标称增量）

    ⚠️ 刻意用 14 B 帧 —— 因为 v1.1 传的是 phase_inc，不是 pos。

    🔴🔴 2026-10-13 重要修正：**只取 axis=0 那一条轴**。
    实测发现 `demo_scale.hex` 里其实有【两段】：
      · 事件 1..37   axis=0，tick 0..19200
      · 事件 38..78  axis=1，tick 23520..100320   <- 另一条轴/另一段
      · 事件 79..    axis=0（第二次），tick 又回到 19200
    ⇒ 混在一起时 tick 【不是单调的】⇒ 时间轴无意义。
    ⭐ 这不是文件坏了 —— 它是【多条轴】的合成谱，
      而 MIDI 单轨只能表达【一条时间轴】⇒ 必须先按轴拆开。
    （⭐ 这个坑也验证了 evt2midi 新加的 `non_monotonic_tick` 计数有用：
       它会把这件事直接指出来，⛔ 而不是让人去猜"为什么 MIDI 写不出来"。）
    """
    words, probs = sw.load_events_hex(os.path.join(HERE, "demo_scale.hex"))
    assert not probs, "demo_scale.hex 有问题：%s" % probs

    AXIS = 0                          # 只演示一条轴（见上）

    buf = bytearray()
    n_on = n_off = n_tempo = n_other_axis = 0
    seq = 0
    first_tick = None
    axis0 = []
    for w in words:
        d = sw.unpack_word(w)
        if d["kind"] == KIND_TEMPO:
            n_tempo += 1
            continue
        if d["axis"] != AXIS:
            n_other_axis += 1
            continue
        axis0.append(d)

    # 起播锚点：tick 用本轴第一个事件的 tick（真实场景是"起播那一刻"的快照）
    anchor_tick = axis0[0]["tick"] if axis0 else 0
    buf += build_frame(T_TRANSPORT_START, seq=seq, tick=anchor_tick, ppqn=PPQN_FPGA)
    seq = (seq + 1) & 0xFF

    for d in axis0:
        if d["vel"] == 0:
            k_mapped = T_NOTE_OFF
            n_off += 1
        else:
            k_mapped = T_NOTE_ON
            n_on += 1
        buf += build_frame(k_mapped, seq=seq, tick=d["tick"], axis=d["axis"],
                           inc=d["inc"] << 10, vel=d["vel"])
        seq = (seq + 1) & 0xFF
        if first_tick is None:
            first_tick = d["tick"]

    # 表同步帧：给 16 个轴一个标称增量（inc=0 时 evt2midi 可用它兜底）
    nominal = [(22473 + i * 1000) << 10 for i in range(TABLESYNC_ITEMS)]
    buf += build_frame(T_TABLESYNC, items=nominal)

    return bytes(buf), {
        "words": len(words), "on": n_on, "off": n_off, "tempo": n_tempo,
        "anchor_tick": anchor_tick, "seq_end": seq, "nominal": nominal,
        "axis": AXIS, "other_axis": n_other_axis,
        "last_tick": axis0[-1]["tick"] if axis0 else 0,
        "axis0_events": axis0,
    }


def main():
    print("=" * 74)
    print("MIDI 回传端到端演示（离线；字节流与 FPGA 将发的一致）")
    print("=" * 74)

    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-52s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 造流 ----
    print("\n[1] 按 v1.1 造一段『FPGA 会发上来的字节流』")
    raw, info = build_stream()
    with open(OUT_BIN, "wb") as f:
        f.write(raw)
    print("      事件字 %d 个 => note_on %d / note_off %d / tempo %d（tempo 不进 MIDI）"
          % (info["words"], info["on"], info["off"], info["tempo"]))
    print("      字节流 = %d B，已写 %s" % (len(raw), os.path.basename(OUT_BIN)))
    chk("字节流非空", len(raw) > 0)
    chk("帧数 = 1(锚点) + 事件 + 1(表帧)",
        len(raw) == 14 + (info["on"] + info["off"]) * 14 + 68,
        "  实为 %d B" % len(raw))
    chk("4 字节对齐检查：长度 % 14 的余数 = 表帧贡献", len(raw) % 14 == 68 % 14)

    # ---- ② 逐帧校验：造出来的字节自己得先过校验 ----
    print("\n[2] 逐帧走一遍解析器（证明造出来的字节本身是合法的）")
    pos, nframe, nbad, kinds = 0, 0, 0, {}
    while pos < len(raw):
        ftype = raw[pos + 1]
        flen = 14 if ftype != T_TABLESYNC else 68
        fr = raw[pos:pos + flen]
        try:
            parse_frame(fr)
            if frame_checksum(fr) != fr[-1]:
                nbad += 1
                break
            nframe += 1
            kinds[ftype] = kinds.get(ftype, 0) + 1
        except ValueError as e:
            nbad += 1
            print("      RED 第 %d 字节处解析失败：%s" % (pos, e))
            break
        pos += flen
    chk("每一帧都能被解析且校验通过（%d 帧）" % nframe, nbad == 0)
    chk("锚点帧恰好 1 个", kinds.get(T_TRANSPORT_START, 0) == 1)
    chk("表帧恰好 1 个", kinds.get(T_TABLESYNC, 0) == 1)
    chk("note_on 数对得上", kinds.get(T_NOTE_ON, 0) == info["on"],
        "  %s vs %s" % (kinds.get(T_NOTE_ON, 0), info["on"]))
    chk("note_off 数对得上", kinds.get(T_NOTE_OFF, 0) == info["off"])

    # ---- ③ 转 MIDI ----
    print("\n[3] 转成 MIDI（evt2midi.py，带 --verify 读回核对）")
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    r = subprocess.run(
        [sys.executable, os.path.join(HERE, "evt2midi", "evt2midi.py"),
         "--in", OUT_BIN, "--out", OUT_MID, "--verify",
         "--table-fallback"],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=env)
    for ln in (r.stdout or "").splitlines():
        if ln.strip():
            print("      " + ln.strip())
    if r.stderr:
        for ln in r.stderr.splitlines():
            if ln.strip():
                print("      [stderr] " + ln.strip())
    chk("evt2midi 退出码 = 0", r.returncode == 0, "  rc=%s" % r.returncode)
    chk("MIDI 文件已生成", os.path.exists(OUT_MID))

    # ---- ④ 独立核对 MIDI 字节（自己读，不信工具的自述）----
    print("\n[4] 独立读回 MIDI 核对（自己解析字节，⛔ 不看工具的自述）")
    if os.path.exists(OUT_MID):
        mb = open(OUT_MID, "rb").read()
        chk("文件头 MThd", mb[:4] == b"MThd")
        chk("轨道块 MTrk", mb[14:18] == b"MTrk")
        ppqn_midi = struct.unpack(">H", mb[12:14])[0]
        chk("PPQN = 960（与 FPGA 的 ppqn 一致）", ppqn_midi == 960,
            "  实测 %d" % ppqn_midi)
        n_on = n_off_m = 0
        i = 14
        while i < len(mb) - 1:
            if mb[i] == 0x90 and i + 2 < len(mb) and mb[i + 2] > 0:
                n_on += 1
            elif mb[i] == 0x80 or (mb[i] == 0x90 and i + 2 < len(mb)
                                   and mb[i + 2] == 0):
                n_off_m += 1
            i += 1
        print("      MIDI 里 note_on = %d，note_off = %d" % (n_on, n_off_m))
        chk("MIDI 里的 note_on 数 = 输入的事件数", n_on == info["on"],
            "  %d vs %d" % (n_on, info["on"]))
        chk("MIDI 里 note_off 数 = 输入的 note_off 数", n_off_m == info["off"],
            "  %d vs %d" % (n_off_m, info["off"]))
        chk("文件大小合理（> 100 B）", len(mb) > 100, "  %d B" % len(mb))

        # ---- 音高核对：把 MIDI 音符号和我们算出来的对上 ----
        print("\n[5] 音高核对（⭐ 不只看'有没有音符'，要看【音对不对】）")
        words, _ = sw.load_events_hex(os.path.join(HERE, "demo_scale.hex"))
        expect = []
        for w in words:
            d = sw.unpack_word(w)
            if d["kind"] == KIND_TEMPO or d["axis"] != info["axis"]:
                continue
            if d["vel"] > 0:
                expect.append(d["inc"])
        got_notes = []
        j = 0
        while j < len(mb) - 2:
            if mb[j] == 0x90 and mb[j + 2] > 0:
                got_notes.append(mb[j + 1])
            j += 1
        print("      输入的不同 inc 值 = %d 个，MIDI 音符号 = %s"
              % (len(set(expect)), got_notes))
        chk("MIDI 音符号全部落在 0..127", all(0 <= n <= 127 for n in got_notes))
        chk("音符号不是常数（⭐ 证明真的按 inc 换算，不是写死一个值）",
            len(set(got_notes)) > 1, "  不同音高 %d 种" % len(set(got_notes)))
        # ⚠️ 判据必须跟着【实际输入】走。
        #    本演示只取 axis=0 那一条轴 ⇒ 它的音高集合就是 C 大调上行 8 个音
        #    （axis=1 那段是另一条轴，已按设计排除）。
        #    🔴 我前两版判据都写错了（先写 <=8、后写 ==16）——
        #       ⭐ 两次都是"判据凭空想"，而不是"从数据里量"。
        chk("音高种类 = 8（本轴是 C 大调 8 个音级）",
            len(set(got_notes)) == 8,
            "  实测 %d 种" % len(set(got_notes)))
        # 更强的判据：管【顺序】—— 合错误的链完全可能凑出对的种类数
        chk("音符号序列 = C 大调【上下行】"
            "（60,62,64,65,67,69,71,72,71,69,67,65,64,62,60）",
            got_notes == [60, 62, 64, 65, 67, 69, 71, 72,
                          71, 69, 67, 65, 64, 62, 60],
            "  实测 %s" % got_notes)
        chk("序列确实【先升后降】（折返在第 8 个音）",
            got_notes.index(max(got_notes)) == 7,
            "  最高音在第 %d 位" % (got_notes.index(max(got_notes)) + 1))
        chk("不同 inc 值的个数 = 不同音符号的个数（一一对应，⛔ 无折叠）",
            len(set(expect)) == len(set(got_notes)),
            "  inc %d 种 vs 音高 %d 种" % (len(set(expect)), len(set(got_notes))))
        # ---- 时间核对（⭐ 2026-10-13 新增：这是本轮修的那个 bug 的回归判据）----
        print("\n[6] 时间核对（⭐ 本轮修的 bug 就在这里 —— 音符间距不许全为 0）")
        # ⚠️ 别自己手写变长量解析 —— 我第一版就是那么写的，
        #    结果把【音符字节】也当成了 delta（实测：解出 77/7/2108 这种垃圾）。
        #    ⭐ 用仓库里【已经过自检】的 midi_verify，⛔ 不重复造一个半吊子解析器。
        from midi_verify import read_midi, notes_of
        res_m = read_midi(mb)
        notes_m = notes_of(res_m)
        times = sorted({n["t"] for n in notes_m})
        print("      MIDI 里的音符时刻（绝对 tick）= %s" % times)
        chk("音符时刻【不是全相同】（全相同 = 挤在同一时刻）",
            len(times) > 1, "  不同时刻 %d 个" % len(times))
        if len(times) > 1:
            gaps = [times[i + 1] - times[i] for i in range(len(times) - 1)]
            print("      相邻间距 = %s" % sorted(set(gaps)))
            chk("相邻间距全是 480 的倍数（本谱是 8 分音符网格）",
                all(g % 480 == 0 for g in gaps),
                "  非 480 倍数：%s" % [g for g in gaps if g % 480][:5])
            chk("最后一个音符时刻 = 谱面最后一个 tick",
                times[-1] == info["last_tick"],
                "  MIDI %d vs 谱面 %d" % (times[-1], info["last_tick"]))
        # 每个音符的相对位置必须与谱面 tick 一致（⭐ 最有力的时间判据）
        want_ticks = sorted({d["tick"] for d in info["axis0_events"]})
        chk("音符时刻集合 = 谱面 tick 集合（逐点比对）",
            times == want_ticks,
            "  MIDI %d 个点 vs 谱面 %d 个点" % (len(times), len(want_ticks)))
        sec = info["last_tick"] / 960.0 * 60.0 / 120.0
        print("      => 时长 = %.2f 秒（%d tick @960PPQN/120BPM）"
              % (sec, info["last_tick"]))
        chk("时长合理（1~120 秒）", 1.0 <= sec <= 120.0, "  %.2f 秒" % sec)

    print()
    print("=" * 74)
    print("结论：%s" % ("全部通过 —— 这条链【离线端到端】是通的 ✅"
                       if ok else "有失败项 🔴"))
    print("=" * 74)
    print()
    print("产物：")
    print("  %s   （模拟 FPGA 回传的原始字节）" % OUT_BIN)
    print("  %s   （转出来的 MIDI，可直接播放）" % OUT_MID)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
