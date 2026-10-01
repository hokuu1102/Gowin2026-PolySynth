"""⭐ 端到端验证：造一份"录制文件" → 转 MIDI → **再把 MIDI 解析回来核对**。

⭐ 为什么要"解析回来"：⚠️ 只检查文件头 `MThd` 是**假绿** ——
   🔴 文件可以头对、内容全错。⭐ 必须**按 MIDI 规范读回事件**再比对音高/时序。
"""
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, ".")
from evt2midi import (CLK_HZ, PPQN, T_NOTE_OFF, T_NOTE_ON, TWO32,
                      _mk_frame, build_midi, inc_to_hz, parse_stream)


def inc_for(hz):
    return int(round(hz * TWO32 / CLK_HZ))


def read_var_len(b, i):
    v = 0
    while True:
        c = b[i]
        i += 1
        v = (v << 7) | (c & 0x7F)
        if not (c & 0x80):
            return v, i


def parse_midi(m):
    """⭐ 按 MIDI 规范把文件读回事件（⭐ 这才是真判据）。"""
    assert m[:4] == b"MThd", "bad MThd"
    hlen, fmt, ntrk, div = struct.unpack(">IHHH", m[4:14])
    assert hlen == 6, "bad header len"
    i = 14
    assert m[i:i + 4] == b"MTrk", "bad MTrk"
    tlen = struct.unpack(">I", m[i + 4:i + 8])[0]
    i += 8
    end = i + tlen
    evs = []
    t = 0
    while i < end:
        d, i = read_var_len(m, i)
        t += d
        st = m[i]
        if st == 0xFF:
            meta = m[i + 1]
            ln, j = read_var_len(m, i + 2)
            evs.append(("meta", t, meta))
            i = j + ln
            continue
        if st & 0xF0 in (0x80, 0x90):
            note = m[i + 1]
            vel = m[i + 2]
            evs.append(("on" if (st & 0xF0) == 0x90 and vel > 0 else "off",
                        t, note, vel))
            i += 3
            continue
        raise AssertionError("unexpected status 0x%02X at %d" % (st, i))
    return div, evs


def main():
    print("=" * 74)
    print("端到端：合成录制 -> MIDI -> 读回核对")
    print("=" * 74)
    ok = True

    # ---- 造一段"演奏"：A4 -> C5 -> E5，每个音 0.25 秒 ----
    melody = [(440.0, 200), (523.25, 220), (659.25, 240)]
    rec = bytearray()
    seq = 0
    t = 1000
    step = int(0.25 * CLK_HZ)          # ⭐ 0.25 秒的 FPGA tick 数
    expect = []
    for hz, vel in melody:
        inc = inc_for(hz)
        rec += _mk_frame(T_NOTE_ON, seq, t, 0, inc, vel); seq += 1
        rec += _mk_frame(T_NOTE_OFF, seq, t + step // 2, 0, inc, vel); seq += 1
        expect.append((hz, vel))
        t += step
    # ⭐ 夹几个 ASCII 事件（⭐ 模拟标定回包，⭐ 验证混合流不干扰）
    rec += b"s"
    rec += _mk_frame(T_NOTE_ON, seq, t, 0, inc_for(440.0), 180); seq += 1

    print("录制文件：%d 字节（%d 帧 + 1 个 ASCII）" % (len(rec), seq))

    evs, st = parse_stream(bytes(rec))
    print("解析：帧 ok=%d bad=%d ascii=%d unknown=%d"
          % (st.frames_ok, st.frames_bad_csum, st.ascii_events, st.unknown_hi))
    if st.frames_bad_csum or st.unknown_hi:
        ok = False
        print("  🔴 有坏帧/未知字节")

    midi, skipped, n = build_midi(evs, st)
    print("MIDI：%d 字节" % len(midi))

    div, mevs = parse_midi(midi)
    print("读回：division=%d，事件 %d 条" % (div, len(mevs)))

    # ---- 核对 ----
    print()
    print("核对：")
    if div == PPQN:
        print("  division = %d（期望 %d）OK" % (div, PPQN))
    else:
        print("  🔴 division = %d（期望 %d）" % (div, PPQN)); ok = False

    ons = [e for e in mevs if e[0] == "on"]
    offs = [e for e in mevs if e[0] == "off"]
    metas = [e for e in mevs if e[0] == "meta"]
    print("  note_on  = %d（期望 4）%s" % (len(ons), "OK" if len(ons) == 4 else "RED"))
    print("  note_off = %d（期望 4）%s" % (len(offs), "OK" if len(offs) == 4 else "RED"))
    print("  meta(轨结束) = %d %s" % (len(metas), "OK" if metas else "RED"))
    if len(ons) != 4 or not metas:
        ok = False

    # ⭐ 音高核对：⭐ 用 phase_inc 反算出来的音符号
    got_notes = [e[2] for e in ons]
    want_notes = []
    for hz, _ in melody:
        from evt2midi import hz_to_note
        want_notes.append(hz_to_note(hz))
    from evt2midi import hz_to_note
    want_notes.append(hz_to_note(440.0))
    print("  音符号   = %s（期望 %s）%s"
          % (got_notes, want_notes, "OK" if got_notes == want_notes else "RED"))
    if got_notes != want_notes:
        ok = False

    # ⭐ 力度核对：⭐ vel 200 -> (200+1)//2 = 100
    got_vels = [e[3] for e in ons]
    want_vels = [(v + 1) // 2 for _, v in melody] + [(180 + 1) // 2]
    print("  力度     = %s（期望 %s）%s"
          % (got_vels, want_vels, "OK" if got_vels == want_vels else "RED"))
    if got_vels != want_vels:
        ok = False

    # ⭐ 时序核对：⭐ 0.25 秒 @120BPM/960PPQN = 1920 t/s ⇒ 480 MIDI tick
    if len(ons) >= 2:
        d_on = ons[1][1] - ons[0][1]
        want_d = int(round(0.25 * PPQN * 120.0 / 60.0))
        print("  音间 Δt  = %d（期望 %d）%s"
              % (d_on, want_d, "OK" if abs(d_on - want_d) <= 1 else "RED"))
        if abs(d_on - want_d) > 1:
            ok = False

    print()
    print("结论：%s" % ("端到端通过 ✅" if ok else "有失败项 🔴"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
