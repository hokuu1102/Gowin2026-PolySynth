#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mid2evt.py -- Standard MIDI file -> FPGA event stream.

WHY MIDI AND NOT THE .gp FILE
    An earlier tool parsed Guitar Pro's .gp (GPIF XML) directly.  It works, but
    it is fragile: the GPIF nesting puts <Bars> at two different levels with
    different meanings, a track's bars are the k-th bar of every master bar
    rather than a contiguous run, and beats/voices live in separate global
    blocks.  Two mistakes were made chasing that.  More importantly it is
    RE-DERIVING semantics that Guitar Pro already decided.

    Exporting MIDI from Guitar Pro and parsing THAT gives us the author's own
    semantics, in a decades-stable format:
      * note_on / note_off are already paired  => durations are correct
      * format 1 = one track per instrument    => no voice/bar archaeology
      * pitches are absolute note numbers      => no fret/capo/tuning maths

    Trade-off: one manual export step.  Worth it.

WHAT IT HANDLES
    * format 0 (single track) and format 1 (multi track)
    * running status (a MIDI stream omits a repeated status byte)
    * meta events (tempo, track name, end-of-track)
    * simultaneous same-pitch duplicates -> DE-DUPLICATED (see below)
    * drum tracks -> routed to a separate "drum" group (NOT treated as pitch)

DRUM DETECTION (deliberately NOT hard-coded to one channel)
    The channel a score uses for drums varies between scores, so we accept
    EITHER of two signals and report which one fired:
      1. the track name contains drum/perc          <- primary
      2. the track is on MIDI channel 9             <- GM convention
    A third signal (pitch range inside 35..81) is only reported, never used
    to decide, because a low bass line can sit in that range too.

DE-DUPLICATION
    A score may start the SAME pitch twice at the SAME tick -- two strings
    playing a unison, or two voices doubling.  That is legitimate notation and
    Guitar Pro exports it as two note_ons.  On the FPGA those become two
    voices at the same frequency, whose phases interfere: depending on the
    phase the result may get louder, thin out, or beat at the attack, which
    sounds like the note was struck twice.  Since the pitch is identical no
    musical information is lost by keeping one, and it also saves voices in a
    32-voice pool.  Only EXACT (tick, pitch) repeats are merged; a repeated
    pitch at a different tick is a real repeat and is preserved.

OUTPUT
    events.hex    FPGA record, one 64-bit word per line
    events.csv    the same, human readable
    report.txt    statistics + which drum rule fired + what was de-duplicated
    (no reference MIDI is produced: the input already IS MIDI)

FIELD LAYOUT (64-bit record) -- REVISED 2026-09-22
    bit 63..44   tick    (20 bit)   musical time, PPQN=960
    bit 43..23   inc     (21 bit)   phase_inc  -- or tick_inc when kind==2
    bit 22..19   axis    (4 bit)    axis id 0..15
    bit 18..11   vel     (8 bit)    velocity
    bit 10..9    kind    (2 bit)    0=note_on, 1=note_off, 2=tempo change
    bit  8..7    timbre  (2 bit)    timbre id 0..3  (TIMBRE_N=4)
    bit  6..0            (7 bit)    RESERVED -- must be written as 0

TEMPO EVENTS (kind=2)
    The tempo map used to live only in report.txt, so the FPGA had no way to
    know how fast a score should play -- a score that changes tempo would play
    at one constant BPM.  Each set_tempo now also emits a kind=2 record at its
    tick, with `inc` reinterpreted as tick_inc (the phase increment per PPQN
    tick), matching beat_gen.tick_inc_i exactly.  Kind=2 records also carry
    a timbre field, but it is meaningless there and written as 0.

TIMBRE (why the record carries it)
    Without it the FPGA can only use one global timbre, so every part -- three
    guitars, a bass -- sounds identical.  note_manager already has the per-note
    path (evt_timbre_valid_i / evt_timbre_i, latched at note-on per K-82), so
    carrying timbre in the record needs no change on the receiving side.  It
    costs nothing: 2 bits out of the 9 reserved, record stays 64 bits.

    The id is GUESSED from the track name (TIMBRE_HINTS).  That is a heuristic
    and it will sometimes be wrong, so the result is printed in report.txt and
    can be overridden with --timbre.

TICK OVERFLOW (why the layout changed)
    The old layout gave tick only 16 bits and masked it with & 0xFFFF.  Real
    scores run far past that: one sampled score reaches tick 814080, i.e. it
    wrapped TWELVE times and the note timeline was silently compressed.  The
    bug survived because nothing consumed events.hex (the audition tool reads
    the CSV, where the tick is complete) and because the truncation was
    SILENT -- no warning, no error.

    The fix does not widen the record.  Measured over a real score, phase_inc
    never exceeds 1077509 (that is MIDI 127, the highest note), which needs 21
    bits -- but the old layout reserved 32.  Re-allocating those idle bits
    buys tick 20 bits, i.e. 1048575 ticks = 273 bars at 4/4 PPQN 960.  The
    record stays 64 bits, so the byte count, the UART frame and the FPGA
    buffer are all unaffected.

    Both fields are now RANGE-CHECKED.  Exceeding either is a hard error, not
    a silent wrap: a silent wrap is what made this bug expensive.

USAGE
    python tools/mid2evt.py <file.mid> [--outdir DIR] [--transpose N]
                            [--timbre AXIS=NAME,...]
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import struct
import sys

PPQN = 960                     # must match beat_gen
FS = 50_000_000.0
TWO32 = 4294967296.0

KIND_ON, KIND_OFF = 0, 1
KIND_TEMPO = 2                 # ⭐ 换速：inc 字段改存 tick_inc（不是 phase_inc）

# --------------------------------------------------------------------------- #
# 64-bit record layout (see the module docstring for why tick is 20 bits)
# --------------------------------------------------------------------------- #
TICK_W, TICK_SH = 20, 44
INC_W,  INC_SH  = 21, 23
AXIS_W, AXIS_SH = 4, 19
VEL_W,  VEL_SH  = 8, 11
KIND_W, KIND_SH = 2, 9
TIMBRE_W, TIMBRE_SH = 2, 7        # ⭐ 音色号 0..3（TIMBRE_N=4）
# bits 6..0 reserved

TICK_MAX = (1 << TICK_W) - 1    # 1048575 ticks = 273 bars @ 4/4 PPQN 960
INC_MAX = (1 << INC_W) - 1      # 2097151 > MIDI 127 (1077509), with headroom

# ⭐ 音色号（必须与 RTL 的 TIMBRE_N=4 及 wavetable_bank 的表序一致）
TIMBRE_BASS, TIMBRE_GUITAR, TIMBRE_PIANO, TIMBRE_PAD = 0, 1, 2, 3
TIMBRE_NAMES = {TIMBRE_BASS: "BASS", TIMBRE_GUITAR: "GUITAR",
                TIMBRE_PIANO: "PIANO", TIMBRE_PAD: "PAD"}
TIMBRE_BY_NAME = {v: k for k, v in TIMBRE_NAMES.items()}

# ⭐ 轨名 -> 音色 的关键词表（⛔ 先匹配到的先用；顺序有意义）
#   ⚠️ 这是【启发式】—— 轨名是作者随便起的，猜错很正常。
#   ⇒ ⭐ 所以必须：① 结果写进 report.txt ② 支持 --timbre 手工覆盖
TIMBRE_HINTS = (
    ("bass",  TIMBRE_BASS),
    ("solo",  TIMBRE_PIANO),      # ⭐ 主音：用脉冲波（亮）—— 见 曲谱音色分配与相位干涉分析.md
    ("lead",  TIMBRE_PIANO),
    ("pad",   TIMBRE_PAD),
    ("piano", TIMBRE_PIANO),
    ("keys",  TIMBRE_PIANO),
    ("synth", TIMBRE_PAD),
    ("gt",    TIMBRE_GUITAR),
    ("gtr",   TIMBRE_GUITAR),
    ("guitar", TIMBRE_GUITAR),
)

# General-MIDI percussion channel (0-based). Channel 10 in 1-based speech.
GM_DRUM_CHANNEL = 9

# drum name hints, matched case-insensitively against the track name
DRUM_HINTS = ("drum", "perc", "kit", "cymbal", "hat")


# --------------------------------------------------------------------------- #
# MIDI reading
# --------------------------------------------------------------------------- #
def _read_vlq(d, i):
    v = 0
    while True:
        b = d[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            return v, i


def parse_midi(path):
    """Return (division, fmt, tempo_map, [track, ...]).

    tempo_map = [(tick, us_per_quarter), ...] sorted -- the set_tempo meta
    events (0x51).  A score can change tempo MID-SONG (one sampled score runs
    168 -> 160 BPM), so one BPM constant cannot place notes in real time.

    Each track is {"name": str, "chan": set,
                   "events": [(tick, is_note_on, note, velocity), ...]}
    """
    d = open(path, "rb").read()
    if d[:4] != b"MThd":
        raise SystemExit("ERROR: %s is not a MIDI file (no MThd)" % path)
    fmt, ntrk, division = struct.unpack(">HHH", d[8:14])
    if division & 0x8000:
        raise SystemExit("ERROR: SMPTE time division is not supported")

    i = 14
    tracks = []
    tempos = []
    while i + 8 <= len(d) and d[i:i+4] == b"MTrk":
        ln = struct.unpack(">I", d[i+4:i+8])[0]
        body = d[i+8:i+8+ln]
        i += 8 + ln

        out = {"name": "", "chan": set(), "events": []}
        t = 0
        j = 0
        run = None
        while j < len(body):
            dt, j = _read_vlq(body, j)
            t += dt
            st = body[j]
            if st < 0x80:
                if run is None:
                    # malformed: no running status yet; skip the byte
                    j += 1
                    continue
                st = run                      # running status
            else:
                j += 1

            if st == 0xFF:                    # meta
                mt = body[j]
                j += 1
                l, j = _read_vlq(body, j)
                data = body[j:j+l]
                j += l
                if mt == 0x03:
                    out["name"] = data.decode("utf-8", "replace").strip()
                elif mt == 0x51 and l == 3:
                    us = (data[0] << 16) | (data[1] << 8) | data[2]
                    if us > 0:
                        tempos.append((t, us))
                continue
            if st in (0xF0, 0xF7):            # sysex
                l, j = _read_vlq(body, j)
                j += l
                continue

            run = st
            hi = st & 0xF0
            ch = st & 0x0F
            if hi == 0x90:
                note, vel = body[j], body[j+1]
                j += 2
                out["chan"].add(ch)
                if vel > 0:
                    out["events"].append((t, True, note, vel))
                else:
                    out["events"].append((t, False, note, 0))
            elif hi == 0x80:
                note, vel = body[j], body[j+1]
                j += 2
                out["chan"].add(ch)
                out["events"].append((t, False, note, vel))
            elif hi in (0xA0, 0xB0, 0xE0):
                j += 2
            elif hi in (0xC0, 0xD0):
                j += 1
            else:
                break
        tracks.append(out)

    tempos.sort()
    if not tempos:
        tempos = [(0, 500000)]            # MIDI default = 120 BPM
    return division, fmt, tempos, tracks


# --------------------------------------------------------------------------- #
# classification
# --------------------------------------------------------------------------- #
def classify(track):
    """Return (is_drum, reason).  Name first, then the GM channel."""
    nm = track["name"].lower()
    for h in DRUM_HINTS:
        if h in nm:
            return True, "track name contains '%s'" % h
    if GM_DRUM_CHANNEL in track["chan"]:
        return True, "MIDI channel %d (GM percussion)" % (GM_DRUM_CHANNEL + 1)
    return False, ""


# --------------------------------------------------------------------------- #
# conversion
# --------------------------------------------------------------------------- #
def note_to_phase_inc(midi):
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    return max(0, min(0xFFFFFFFF, int(round(f * TWO32 / FS))))


def timbre_for_track(name, axis, overrides=None):
    """Guess the timbre id from a track name.  Returns (id, reason).

    ⚠️ A HEURISTIC.  Track names are free-form ("Biu GT Solo" could be lead,
       rhythm or something else entirely), so this WILL be wrong sometimes.
       That is why the caller prints the result and --timbre can override it.
       Silence here would be the real bug, not a wrong guess.
    """
    if overrides and axis in overrides:
        return overrides[axis], "axis %d override" % axis
    low = (name or "").lower()
    for kw, tid in TIMBRE_HINTS:
        if kw in low:
            return tid, "name contains '%s'" % kw
    return TIMBRE_GUITAR, "default (no keyword matched)"


def tick_inc_for_bpm(bpm):
    """Phase increment per PPQN tick, in the beat_gen.tick_inc_i scale.

    ⚠️ MUST match beat_gen: phase advances by tick_inc per SYSTEM clock, and a
       tick is emitted when the 32-bit accumulator carries.  So
           tick rate  f_tick = BPM/60 * PPQN      [ticks/s]
           tick_inc   = round(f_tick * 2^32 / 50e6)
       Verified against tb_beat_gen's own constants (60 BPM -> 82463,
       120 BPM -> 164927).
    """
    f_tick = (bpm / 60.0) * PPQN
    return int(round(f_tick * TWO32 / FS))


def build_events(tracks, division, tempos, transpose=0, overrides=None):
    """Return (events, stats).  Pure notes; drums are grouped separately.

    Ticks are converted to the FPGA's PPQN grid.  Each event also carries its
    TIMBRE id, and the score's tempo map is emitted as kind=2 records so the
    stream is self-contained (the FPGA no longer needs the .mid to know how
    fast to play).
    """
    scale = float(PPQN) / float(division)

    stats = {
        "tracks": [], "drum_tracks": [], "empty_tracks": [], "notes": 0,
        "events": 0, "dropped_drum": 0, "dedup": 0, "cross_dedup": 0,
        "max_tick": 0, "min_midi": 999, "max_midi": -999,
        "per_track": [], "axis_overflow": 0, "tempos": tempos,
        "timbre_of_axis": [], "tempo_events": 0, "max_tick_inc": 0,
    }
    events = []

    # ⭐ Assign an axis only to tracks that actually CARRY NOTES.
    #    Guitar Pro exports empty placeholder tracks (and sometimes two tracks
    #    with the same name).  Handing them an axis burns an id and leaves gaps
    #    in the numbering, which makes the event dump harder to read for no
    #    benefit.  Skip them up front and say so in the report.
    axis_of = {}
    nxt = 0
    for ti, tr in enumerate(tracks):
        drum, reason = classify(tr)
        nm = tr["name"] or ("track %d" % ti)
        if drum:
            stats["drum_tracks"].append("%s (%s)" % (nm, reason))
            continue
        if not any(e[1] for e in tr["events"]):     # no note_on at all
            stats["empty_tracks"].append(nm)
            continue
        axis_of[ti] = nxt
        nxt += 1
    if nxt > 16:
        stats["axis_overflow"] = nxt

    for ti, tr in enumerate(tracks):
        if ti not in axis_of:
            # drum track (count its events as excluded) or an empty placeholder
            drum, _r = classify(tr)
            if drum:
                stats["dropped_drum"] += len(tr["events"])
            continue
        nm = tr["name"] or ("track %d" % ti)

        axis = axis_of[ti] & 0xF
        # ⭐ 音色：按轨名猜（⭐ 结果要写进 report.txt，⛔ 不静默）
        timbre, why = timbre_for_track(nm, axis, overrides)
        stats["timbre_of_axis"].append((axis, nm, timbre, why))
        # pair note_on with the NEXT note_off of the same pitch (FIFO per pitch)
        pending = {}
        starts = {}                      # (tick, midi) -> first velocity
        span = []
        for tick, is_on, note, vel in tr["events"]:
            if is_on:
                pending.setdefault(note, []).append(tick)
            else:
                if pending.get(note):
                    s = pending[note].pop(0)
                    span.append((s, tick, note))

        # ---- de-duplicate: same (tick, pitch) started more than once ----
        seen = {}
        for s, e, note in span:
            key = (s, note)
            if key in seen:
                stats["dedup"] += 1
                continue
            seen[key] = (s, e)
        stats["per_track"].append((nm, axis, len(seen)))

        for (s, note), (_, e) in seen.items():
            midi = note + transpose
            if not (0 <= midi <= 127):
                continue
            inc = note_to_phase_inc(midi)
            vel = 130                   # MIDI files carry velocity; keep it simple
            dur = max(1, int(round((e - s) * scale)))
            t0 = int(round(s * scale))
            events.append({"tick": t0, "inc": inc, "vel": vel,
                           "axis": axis, "kind": KIND_ON, "midi": midi,
                           "timbre": timbre})
            # a note_off is ALWAYS emitted: without it the note hangs (T38)
            events.append({"tick": t0 + dur, "inc": inc, "vel": vel,
                           "axis": axis, "kind": KIND_OFF, "midi": midi,
                           "timbre": timbre})
            stats["notes"] += 1
            stats["min_midi"] = min(stats["min_midi"], midi)
            stats["max_midi"] = max(stats["max_midi"], midi)
            stats["max_tick"] = max(stats["max_tick"], t0 + dur)
        stats["tracks"].append(nm)

    # ⭐ 速度表 -> kind=2 事件（⭐ 让 hex 自包含；⛔ 见 docstring 的 TEMPO EVENTS）
    for tk, us in (tempos or []):
        if us <= 0:
            continue
        bpm = 60_000_000.0 / us
        ti_ = tick_inc_for_bpm(bpm)
        t0 = int(round(tk * scale))
        events.append({"tick": t0, "inc": ti_, "vel": 0, "axis": 0,
                       "kind": KIND_TEMPO, "midi": -1, "timbre": 0})
        stats["tempo_events"] += 1
        stats["max_tick_inc"] = max(stats["max_tick_inc"], ti_)
        stats["max_tick"] = max(stats["max_tick"], t0)

    # note_off must be ordered before note_on at the same tick, so that a
    # re-strike of the same pitch is not immediately cancelled.
    # ⭐ kind=2 (tempo) sorts FIRST at a shared tick, so the new tempo is in
    #    force for the notes that start on that very tick.  A plain sort on
    #    (tick, kind) would put tempo LAST (2 > 1), which is wrong.
    # ⚠️ The ranks must be DISTINCT: mapping tempo to the same rank as note_on
    #    (both 0) would let Python's stable sort keep the notes first, because
    #    tempo records are appended after all notes -- so the tie-break silently
    #    reverses the intent.  tempo=-1 puts it unambiguously ahead.
    events.sort(key=lambda e: (e["tick"],
                               -1 if e["kind"] == KIND_TEMPO else e["kind"]))
    stats["events"] = len(events)
    return events, stats


# --------------------------------------------------------------------------- #
# writers
# --------------------------------------------------------------------------- #
def pack_event(e):
    """Pack one event into the 64-bit record.

    BOTH range checks are load-bearing.  A silent & mask is exactly what hid
    the tick overflow for so long, so overflowing either field raises instead
    of wrapping.  If this fires on a real score the layout needs revisiting --
    do NOT "fix" it by widening the mask.
    """
    tick, inc = e["tick"], e["inc"]
    if tick > TICK_MAX:
        raise SystemExit(
            "ERROR: tick %d exceeds the %d-bit field (max %d = %.1f bars). "
            "The note timeline would silently wrap; the record layout must be "
            "revisited rather than masked."
            % (tick, TICK_W, TICK_MAX, TICK_MAX / float(PPQN * 4)))
    if inc > INC_MAX:
        raise SystemExit(
            "ERROR: inc %d exceeds the %d-bit field (max %d). "
            "This is the phase_inc / tick_inc field; the record layout must be "
            "revisited rather than masked." % (inc, INC_W, INC_MAX))
    if e["axis"] > 0xF:
        raise SystemExit("ERROR: axis %d does not fit 4 bits" % e["axis"])
    if e["vel"] > 0xFF:
        raise SystemExit("ERROR: velocity %d does not fit 8 bits" % e["vel"])
    if e["kind"] > 0x3:
        raise SystemExit("ERROR: kind %d does not fit 2 bits" % e["kind"])
    if e["timbre"] > 0x3:
        raise SystemExit("ERROR: timbre %d does not fit 2 bits" % e["timbre"])
    return ((tick            << TICK_SH)
            | (inc           << INC_SH)
            | (e["axis"]     << AXIS_SH)
            | (e["vel"]      << VEL_SH)
            | (e["kind"]     << KIND_SH)
            | (e["timbre"]   << TIMBRE_SH))
    # bits 6..0 stay 0 (reserved)


def unpack_event(w):
    """Inverse of pack_event -- used by the hex/CSV round-trip self-check."""
    return {
        "tick":   (w >> TICK_SH)   & TICK_MAX,
        "inc":    (w >> INC_SH)    & INC_MAX,
        "axis":   (w >> AXIS_SH)   & 0xF,
        "vel":    (w >> VEL_SH)    & 0xFF,
        "kind":   (w >> KIND_SH)   & 0x3,
        "timbre": (w >> TIMBRE_SH) & 0x3,
    }


def verify_hex_roundtrip(events, path):
    """Re-read events.hex and prove it decodes back to what we intended.

    WHY THIS EXISTS: the tick overflow was invisible because nobody ever read
    events.hex back.  The audition tool reads the CSV, so a correct CSV proved
    nothing about the hex.  This closes that hole: it compares the hex against
    both the in-memory events AND the CSV, so the two outputs cannot drift.
    """
    with io.open(path, "r", encoding="ascii") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    if len(lines) != len(events):
        raise SystemExit("ERROR: events.hex has %d records, expected %d"
                         % (len(lines), len(events)))
    bad = 0
    for i, (ln, e) in enumerate(zip(lines, events)):
        got = unpack_event(int(ln, 16))
        want = {"tick": e["tick"], "inc": e["inc"], "axis": e["axis"],
                "vel": e["vel"], "kind": e["kind"], "timbre": e["timbre"]}
        if got != want:
            if bad < 3:
                print("ERROR: events.hex record %d decodes to %r, expected %r"
                      % (i, got, want))
            bad += 1
    if bad:
        raise SystemExit("ERROR: events.hex round-trip failed on %d record(s)"
                         % bad)
    # the CSV must agree too, otherwise "the CSV looks right" stays misleading
    csv_path = os.path.join(os.path.dirname(path), "events.csv")
    if os.path.isfile(csv_path):
        with io.open(csv_path, encoding="utf-8") as f:
            rows = list(csv.reader(f))
        body = [r for r in rows[1:] if r]
        if len(body) != len(events):
            raise SystemExit("ERROR: events.csv has %d rows, expected %d"
                             % (len(body), len(events)))
        for i, (r, e) in enumerate(zip(body, events)):
            kind = {"on": KIND_ON, "off": KIND_OFF,
                    "tempo": KIND_TEMPO}[r[2]]
            if (int(r[1]) != e["tick"] or kind != e["kind"]
                    or int(r[4]) != e["inc"] or int(r[5]) != e["vel"]
                    or int(r[6]) != e["axis"] or int(r[7]) != e["timbre"]):
                raise SystemExit(
                    "ERROR: events.csv row %d disagrees with events.hex "
                    "(csv=%r)" % (i, r))
    return len(lines)


def write_hex(events, path):
    with io.open(path, "w", encoding="ascii", newline="\n") as f:
        for e in events:
            f.write("%016x\n" % pack_event(e))


def write_csv(events, path):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("idx,tick,kind,midi,inc,velocity,axis,timbre\n")
        for i, e in enumerate(events):
            k = {KIND_ON: "on", KIND_OFF: "off", KIND_TEMPO: "tempo"}[e["kind"]]
            f.write("%d,%d,%s,%d,%d,%d,%d,%d\n" % (
                i, e["tick"], k,
                e.get("midi", -1), e["inc"], e["vel"], e["axis"],
                e["timbre"]))


def write_report(stats, path, args):
    L = []
    L.append("mid2evt report")
    L.append("=" * 52)
    L.append("input        : %s" % args.input)
    L.append("transpose    : %+d semitones" % args.transpose)
    L.append("")
    L.append("pitch tracks : %d" % len(stats["tracks"]))
    for nm, axis, n in stats["per_track"]:
        L.append("    axis %-2d %-16s %5d notes" % (axis, nm, n))
    L.append("")
    # ⭐ 音色分配（⚠️ 是【猜】的 ⇒ 必须打出来给人核对，⛔ 不静默）
    L.append("TIMBRE assignment (GUESSED from track name -- verify this!):")
    for axis, nm, tid, why in stats.get("timbre_of_axis", []):
        L.append("    axis %-2d %-16s -> %-6s  (%s)"
                 % (axis, nm, TIMBRE_NAMES[tid], why))
    L.append("  Override any of them with:  --timbre AXIS=NAME,...")
    L.append("  Names: %s" % ", ".join(TIMBRE_NAMES[k] for k in sorted(TIMBRE_NAMES)))
    L.append("")
    if stats["drum_tracks"]:
        L.append("DRUM tracks (routed to the drum machine, NOT played as pitch):")
        for s in stats["drum_tracks"]:
            L.append("    %s" % s)
        L.append("  rule order: (1) track name, (2) MIDI channel %d"
                 % (GM_DRUM_CHANNEL + 1))
        L.append("  drums seen : %d events (excluded from events.hex)"
                 % stats["dropped_drum"])
    else:
        L.append("DRUM tracks : none detected")
    L.append("")
    if stats["empty_tracks"]:
        L.append("EMPTY tracks (no notes; no axis id assigned): %d"
                 % len(stats["empty_tracks"]))
        for s in stats["empty_tracks"]:
            L.append("    %s" % s)
        L.append("  Guitar Pro exports placeholder/duplicate tracks; giving them")
        L.append("  an axis would leave gaps in the numbering for no benefit.")
        L.append("")
    if stats["axis_overflow"]:
        L.append("WARNING: %d pitch tracks need an axis id but the field is only"
                 % stats["axis_overflow"])
        L.append("         4 bits (16 values) -- some tracks will collide.")
        L.append("")
    L.append("notes kept   : %d" % stats["notes"])
    L.append("events       : %d note records (1 note_on + 1 note_off each)"
             % (stats["events"] - stats.get("tempo_events", 0)))
    L.append("de-duplicated: %d  (same tick + same pitch collapsed to one;"
             % stats["dedup"])
    L.append("                identical pitch means no musical loss, and it")
    L.append("                avoids two voices beating at the same frequency)")
    L.append("pitch range  : MIDI %d .. %d" % (stats["min_midi"], stats["max_midi"]))
    L.append("length       : %d ticks = %.2f bars (4/4 @ PPQN %d)"
             % (stats["max_tick"], stats["max_tick"] / float(PPQN * 4), PPQN))
    tp = stats.get("tempos") or []
    if tp:
        L.append("")
        L.append("TEMPO map (from the MIDI set_tempo events -- NOT assumed):")
        for tk, us in tp:
            bpm = 60_000_000.0 / us
            L.append("    tick %-8d %6.2f BPM  -> tick_inc %d"
                     % (tk, bpm, tick_inc_for_bpm(bpm)))
        L.append("  ⭐ emitted into events.hex as %d kind=2 record(s)"
                 % stats.get("tempo_events", 0))
        L.append("     => the stream is SELF-CONTAINED: the FPGA no longer needs")
        L.append("        the .mid to know how fast to play.")
        if len(set(u for _, u in tp)) > 1:
            L.append("  NOTE: this score CHANGES tempo.  Any renderer must follow")
            L.append("        this map, not a single constant BPM.")
    if stats.get("max_tick_inc", 0) == 0:
        L.append("")
        L.append("WARNING: no tempo event emitted (max_tick_inc = 0).")
        L.append("         tick_inc = 0 means beat_gen's clock STANDS STILL.")
    io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")


def parse_timbre_overrides(s):
    """Parse "0=GUITAR,4=BASS" -> {0: GUITAR_ID, 4: BASS_ID}.  None if empty."""
    if not s:
        return None
    out = {}
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            raise SystemExit("ERROR: --timbre entry %r is not AXIS=NAME" % part)
        a, name = part.split("=", 1)
        try:
            axis = int(a.strip())
        except ValueError:
            raise SystemExit("ERROR: --timbre axis %r is not an integer" % a)
        key = name.strip().upper()
        if key not in TIMBRE_BY_NAME:
            raise SystemExit("ERROR: --timbre name %r unknown; use one of %s"
                             % (name, "/".join(TIMBRE_BY_NAME)))
        out[axis] = TIMBRE_BY_NAME[key]
    return out


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description="Standard MIDI -> FPGA events")
    ap.add_argument("input", help="a .mid file exported from Guitar Pro")
    ap.add_argument("--outdir", default="build/score")
    ap.add_argument("--transpose", type=int, default=0, help="semitones")
    ap.add_argument("--timbre", default=None,
                    help="override the guessed timbre per axis, e.g. "
                         "0=GUITAR,4=BASS (names: BASS/GUITAR/PIANO/PAD)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit("ERROR: no such file: %s" % args.input)

    overrides = parse_timbre_overrides(args.timbre)
    division, fmt, tempos, tracks = parse_midi(args.input)
    if not tracks:
        raise SystemExit("ERROR: no tracks found in %s" % args.input)

    events, stats = build_events(tracks, division, tempos, args.transpose,
                                 overrides)
    if not events:
        raise SystemExit("ERROR: no note events produced (all tracks drums?)")

    os.makedirs(args.outdir, exist_ok=True)
    hex_path = os.path.join(args.outdir, "events.hex")
    write_hex(events, hex_path)
    write_csv(events, os.path.join(args.outdir, "events.csv"))
    write_report(stats, os.path.join(args.outdir, "report.txt"), args)

    # ⭐ 回读校验：证明写出去的 hex 能与 CSV / 内存事件解码一致。
    #   ⚠️ 不能省 —— tick 回绕正是因为"从来没人读回 hex"才隐藏了很久。
    n = verify_hex_roundtrip(events, hex_path)

    print("format=%d division=%d tracks=%d" % (fmt, division, len(tracks)))
    print("wrote %s/events.hex  events.csv  report.txt" % args.outdir)
    print("notes=%d events=%d dedup=%d drums_excluded=%d tempo_records=%d"
          % (stats["notes"], stats["events"], stats["dedup"],
             stats["dropped_drum"], stats["tempo_events"]))
    print("timbre      : %s" % ", ".join(
        "axis%d=%s" % (a, TIMBRE_NAMES[t])
        for a, _n, t, _w in stats["timbre_of_axis"]))
    print("hex round-trip OK: %d records, max tick %d (%.1f bars), max inc %d"
          % (n, stats["max_tick"],
             stats["max_tick"] / float(PPQN * 4),
             max(e["inc"] for e in events)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
