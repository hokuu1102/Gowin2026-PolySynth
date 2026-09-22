#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
evt2wav.py -- the FPGA event stream -> a WAV you can actually listen to.

WHY THIS EXISTS
    The converter's correctness has to be judged BY EAR.  A note count that
    matches means nothing if the rhythm is wrong.  This renders the event list
    with a plain additive synth so the result can be compared against the
    original MIDI on the PC, long before anything reaches the FPGA.

TEMPO
    The tempo map is taken from the SCORE, not guessed.  A fixed 120 BPM was
    wrong: two of the three sampled scores are not in 120, and one changes
    tempo mid-song.  Using one constant made a 5.0-minute piece render as 3.9
    minutes and another render as 7.1 instead of 5.1.

WHAT IT IS NOT
    This is NOT the FPGA's sound.  The FPGA uses wavetables and its own ADSR;
    here we use a simple sine/harmonic stack with a short envelope.  The point
    is to check PITCH and TIMING (did the de-duplication, the pairing and the
    tick conversion come out right), not timbre.

    ⚠️ It also renders NO DRUMS.  mid2evt routes drum tracks into a separate
       group and never writes them into events.hex, so this tool cannot see
       them.  A melody-only audition is expected, NOT a bug -- but do not
       judge the finished sound from it.

TEMPO IS REQUIRED -- IT WILL NOT GUESS
    The event stream does not carry the tempo map (see U-7), so this tool
    cannot infer the score's tempo.  Earlier versions silently assumed 120 BPM,
    which rendered a 168-BPM score with a plausible-looking but WRONG timeline
    -- an audition that proves nothing.  It now REFUSES unless you pass
    --midi / --bpm, or opt in to the guess with --assume-120.

USAGE
    python tools/evt2wav.py build/score/<name>/events.csv out.wav --midi <src.mid>
    python tools/evt2wav.py build/score/<name>/events.hex out.wav --midi <src.mid>

    Both inputs are accepted; the extension picks the reader.  Audition BOTH --
    the CSV alone does not prove the FPGA record stream is correct (see the
    note on read_events).

    ⭐ Pass --midi: it supplies the FULL tempo map, including mid-song tempo
      changes.  Without it the timeline is wrong for any score not in 120.
"""

from __future__ import annotations

import argparse
import csv
import io
import math
import os
import struct
import sys
import wave

FS = 48828.0            # the FPGA's actual frame rate (50 MHz / 1024)
PPQN = 960
CLK = 50_000_000.0
TWO32 = 4294967296.0


def inc_to_hz(inc):
    """Inverse of the converter's phase_inc: f = inc * fs_clock / 2^32.

    ⚠️ The clock is the SYSTEM clock (50 MHz), not the audio frame rate.
       phase_inc was built as round(f * 2^32 / 50e6), so this undoes exactly
       that.  Using FS (48.8 kHz) here would be wrong by ~1024x.
    """
    return inc * CLK / TWO32


def read_events(path):
    """[(tick, kind, midi, inc, vel, axis)] in file order.

    Dispatches on the extension: .csv is the human-readable dump, .hex is the
    actual FPGA record stream.

    ⚠️ WHY .hex MATTERS: this tool used to read ONLY the CSV.  The CSV stores
       the full tick, so auditioning a score proved the CSV was right -- while
       events.hex (the thing the FPGA actually consumes) silently wrapped its
       tick field 12 times on a real score.  Nothing ever read the hex back.
       Reading BOTH is what closes that hole.
    """
    if path.lower().endswith(".hex"):
        return read_events_hex(path)
    out = []
    with io.open(path, encoding="utf-8") as f:
        r = csv.reader(f)
        next(r, None)
        for row in r:
            if len(row) < 7:
                continue
            out.append((int(row[1]), row[2], int(row[3]),
                        int(row[4]), int(row[5]), int(row[6])))
    return out


# ── 64-bit record layout (MUST match tools/mid2evt.py) ──────────────────────
TICK_W, TICK_SH = 20, 44
INC_W,  INC_SH  = 21, 23
AXIS_SH, VEL_SH, KIND_SH = 19, 11, 9
TIMBRE_SH = 7
MIDI_NONE = -1          # the hex record has no midi field; CSV does
KIND_TEMPO = 2


def read_events_hex(path):
    """Decode the 64-bit records into the same tuple shape read_events gives.

    ⚠️ The hex record does NOT carry the MIDI note number -- only phase_inc.
       midi is therefore reported as MIDI_NONE (-1); rendering only needs inc.
    """
    out = []
    with io.open(path, encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                w = int(line, 16)
            except ValueError:
                raise SystemExit("ERROR: %s:%d is not hex: %r"
                                 % (path, lineno, line))
            if w >> 64:
                raise SystemExit("ERROR: %s:%d is wider than 64 bits"
                                 % (path, lineno))
            tick = (w >> TICK_SH) & ((1 << TICK_W) - 1)
            inc = (w >> INC_SH) & ((1 << INC_W) - 1)
            axis = (w >> AXIS_SH) & 0xF
            vel = (w >> VEL_SH) & 0xFF
            kind = (w >> KIND_SH) & 0x3
            out.append((tick, {0: "on", 1: "off", 2: "tempo"}[kind],
                        MIDI_NONE, inc, vel, axis))
    return out


def tempos_from_hex(events):
    """Recover the tempo map from kind=2 records -- (tick, us_per_quarter).

    ⭐ WHY: the hex stream is self-contained now (mid2evt writes kind=2 tempo
       records carrying tick_inc).  So auditioning a .hex no longer requires
       the original .mid -- which is the whole point of U-7.
    """
    out = []
    for tick, kind, _midi, inc, _vel, _ax in events:
        if kind == "tempo" and inc > 0:
            # tick_inc = round((bpm/60 * PPQN) * 2^32 / CLK)
            #   => bpm = tick_inc * CLK / (2^32 * PPQN) * 60
            bpm = inc * CLK / (TWO32 * PPQN) * 60.0
            if bpm > 0:
                out.append((tick, int(round(60_000_000.0 / bpm))))
    return sorted(out)


def build_tick_to_sec(tempos, division):
    """Return a function tick -> seconds, following the score's tempo map.

    tempos = [(tick_in_source_division, us_per_quarter), ...] sorted.
    ⚠️ Tempo is piecewise constant per quarter note, so the elapsed time at a
    tick is the SUM over the preceding segments.  A single BPM constant is
    wrong whenever the score changes tempo or is not in 120.
    """
    pts = sorted(tempos) if tempos else [(0, 500000)]
    if pts[0][0] != 0:
        pts = [(0, 500000)] + pts

    def tick_to_sec(tick):
        sec = 0.0
        for k in range(len(pts)):
            t0, us = pts[k]
            t1 = pts[k + 1][0] if k + 1 < len(pts) else None
            if t1 is None or tick <= t1:
                seg = tick - t0
                if seg < 0:
                    seg = 0
                return sec + seg / float(division) * (us / 1e6)
            sec += (t1 - t0) / float(division) * (us / 1e6)
        return sec

    return tick_to_sec


def render(events, tempos, division, max_seconds=None, gain=0.25,
           tempos_on_ppqn_grid=False):
    # pair on/off per (axis, midi), FIFO
    #
    # ⚠️ TWO THINGS MATTER HERE, both only visible when reading .hex:
    #    1. tempo events (kind == "tempo") are NOT note_offs.  Falling into the
    #       else-branch would close a sounding note at every tempo change.
    #    2. the hex record has no midi field, so every note arrives with
    #       midi == MIDI_NONE.  Keying the FIFO on midi would collapse all
    #       notes of one axis into a single bucket and mis-pair them.  When
    #       midi is unavailable we key on inc instead, which IS in the record
    #       and identifies the pitch just as well (it is derived from it).
    pend = {}
    notes = []
    for tick, kind, midi, inc, vel, axis in events:
        if kind == "tempo":
            continue                      # tempo events carry no note
        k = (axis, midi if midi != MIDI_NONE else inc)
        if kind == "on":
            pend.setdefault(k, []).append((tick, inc, vel))
        else:
            if pend.get(k):
                t0, inc0, vel0 = pend[k].pop(0)
                notes.append((t0, tick, inc0, vel0, axis))

    # ⚠️ events are in the FPGA's PPQN grid; a tempo map parsed from a .mid is
    #    in the SOURCE division, so convert the tick base before consulting it.
    # 🔴 A map recovered from kind=2 records is ALREADY on the PPQN grid --
    #    rescaling it again silently doubles every tempo-change position (this
    #    made a 306.1 s score render as 303.7 s).  Hence the explicit flag
    #    rather than inferring it from `division`.
    if tempos_on_ppqn_grid:
        pts = [(tk, us) for tk, us in tempos]
    else:
        pts = [(tk * PPQN // division, us) for tk, us in tempos]
    to_sec = build_tick_to_sec(pts, PPQN)

    last_tick = max([n[1] for n in notes], default=0)
    n_total = int((to_sec(last_tick + PPQN) + 0.5) * FS)
    if max_seconds:
        n_total = min(n_total, int(max_seconds * FS))
    n_total = max(1, n_total)
    buf = [0.0] * n_total

    for t0, t1, inc, vel, axis in notes:
        s0 = int(round(to_sec(t0) * FS))
        s1 = int(round(to_sec(t1) * FS))
        if s0 >= n_total:
            continue
        s1 = min(s1, n_total)
        dur = max(1, s1 - s0)
        f = inc_to_hz(inc)
        if f <= 0 or f > FS / 2.5:
            continue
        amp = (vel / 255.0) * gain
        # 3 harmonics, short attack, exponential-ish decay
        w = 2.0 * math.pi * f / FS
        atk = max(1, int(0.004 * FS))
        for i in range(dur):
            t = s0 + i
            if t >= n_total:
                break
            x = i / float(dur)
            env = (i / float(atk)) if i < atk else (1.0 - x) ** 1.5
            if env <= 0:
                continue
            ph = w * i
            s = math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.18 * math.sin(3 * ph)
            buf[t] += amp * env * s / 1.53

    # soft clip to avoid wrapping
    peak = max(1e-9, max(abs(v) for v in buf))
    scale = min(1.0, 0.95 / peak)
    pcm = bytearray()
    for v in buf:
        x = int(max(-32768, min(32767, v * scale * 32767)))
        pcm += struct.pack("<h", x)
    return pcm


def tempo_is_known(args, hex_tempos=None):
    """True when the tempo is actually available (from any of the 3 sources).

    ⚠️ WHY THIS EXISTS: falling back to a silent 120 BPM is a K-106-class
       "silent wrong answer".  A score in 168 BPM with tempo changes renders
       with a plausible-looking waveform and a WRONG timeline -- nothing in
       the output says so.  Auditioning it and concluding "the events are
       fine" is then unfounded, because the timeline was never the score's.

    ⭐ Since 2026-09-22 a .hex can carry kind=2 tempo records, so a hex file
       may be self-sufficient -- that counts as "known" too.
    """
    return (args.bpm is not None or args.midi is not None
            or bool(hex_tempos))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("wav")
    ap.add_argument("--midi", default=None,
                    help="the source .mid, to take the tempo map from")
    ap.add_argument("--bpm", type=float, default=None,
                    help="force a constant BPM (overrides --midi)")
    ap.add_argument("--division", type=int, default=480,
                    help="source MIDI division (only matters with --bpm)")
    ap.add_argument("--seconds", type=float, default=None,
                    help="render only the first N seconds")
    ap.add_argument("--assume-120", action="store_true",
                    help="allow the silent 120 BPM fallback (only for quick "
                         "smoke tests; the timeline will be wrong for any "
                         "score that is not in 120)")
    args = ap.parse_args(argv)

    events = read_events(args.csv)
    if not events:
        raise SystemExit("ERROR: no events in %s" % args.csv)

    # ⭐ 看 .hex 里有没有 kind=2 速度记录（U-7 之后 hex 是自包含的）
    hex_tempos = tempos_from_hex(events)

    # ⭐ 速度未知时**拒绝默默按 120 BPM 渲染**（除非显式 --assume-120）。
    #    ⚠️ 这是"静默用错速度"的堵口 —— 见 tempo_is_known() 的说明。
    if not tempo_is_known(args, hex_tempos) and not args.assume_120:
        raise SystemExit(
            "ERROR: tempo unknown -- refusing to guess 120 BPM.\n"
            "  No kind=2 tempo record was found in the input, and no tempo\n"
            "  was given on the command line.  Pass one of:\n"
            "    --midi <source.mid>   (full tempo map, incl. changes)\n"
            "    --bpm <n>             (a single constant tempo)\n"
            "    --assume-120          (smoke test only -- WRONG for most scores)\n"
            "  Rendering at a guessed tempo produces a plausible but wrong\n"
            "  timeline, which makes the audition worthless as evidence.")

    if args.bpm is not None:
        # a single tempo everywhere (deliberate override)
        tempos = [(0, int(round(60_000_000.0 / args.bpm)))]
        division = args.division
        on_ppqn = False
        src = "fixed %.2f BPM" % args.bpm
    elif args.midi:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import mid2evt
        division, _fmt, tempos, _tracks = mid2evt.parse_midi(args.midi)
        on_ppqn = False
        src = "%d tempo point(s) from %s" % (len(tempos),
                                             os.path.basename(args.midi))
    elif hex_tempos:
        # ⭐ 自包含：hex 里有 kind=2 记录 ⇒ 不需要 .mid（U-7 的目的）
        tempos = hex_tempos
        division = args.division
        on_ppqn = True          # 🔴 已在 PPQN 格点上，⛔ 不能再换算
        src = "%d tempo point(s) from the kind=2 records in the .hex" % len(tempos)
    else:
        tempos = [(0, 500000)]
        division = args.division
        on_ppqn = False
        src = "MIDI default 120 BPM (no --midi given && no kind=2 in .hex)"

    print("tempo: %s -> %.2f BPM at the start"
          % (src, 60_000_000.0 / tempos[0][1]))
    pcm = render(events, tempos, division, args.seconds,
                 tempos_on_ppqn_grid=on_ppqn)

    os.makedirs(os.path.dirname(os.path.abspath(args.wav)), exist_ok=True)
    w = wave.open(args.wav, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(int(FS))
    w.writeframes(bytes(pcm))
    w.close()
    print("wrote %s  (%.1f s, %d events)"
          % (args.wav, len(pcm) / 2.0 / FS, len(events)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
