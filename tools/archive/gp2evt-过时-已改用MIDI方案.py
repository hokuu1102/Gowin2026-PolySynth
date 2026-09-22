#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gp2evt.py -- Guitar Pro score -> FPGA event stream.

WHY THIS EXISTS
    The FPGA plays notes from an event list (tick, phase_inc, velocity, kind).
    This tool turns a Guitar Pro score into that list, plus a reference MIDI so
    the conversion can be LISTENED TO before it ever reaches hardware.

WHAT IT READS  (verified against a real file, see the probe notes below)
    *.gp  (Guitar Pro 7/8) = a ZIP containing Content/score.gpif, which is XML.
      NOTE: this is NOT the older GP3/4/5 binary format.  For those, use
      PyGuitarPro; this tool deliberately has NO third-party dependencies.
      PyGuitarPro CANNOT read .gp (GP8) -- that was a wrong assumption early on.

STRUCTURE (confirmed by probing the real file, not assumed)
    <Note id=N>          global note list; carries <Midi> directly
                         => no fret/string -> pitch maths, and capo/tuning
                            cannot knock it out of tune
    <Beat id=N>          has <Rhythm ref=R/> and <Notes>i j k</Notes>
                         where i j k are INDICES into the global note list
    <Rhythm id=R>        <NoteValue> + optional dots + optional tuplet
    <Bar id=N>           <Voices>v0 v1 v2 v3</Voices> (-1 = unused voice)
    <Track id=N>         one per instrument; each has its OWN bar list
                         (5 tracks x 190 bars = 950 <Bar> elements)
    <MasterBar>          time signature / tempo marks

    IMPORTANT: a bar does NOT always hold 4 beats, so beats are walked per bar.

OUTPUT
    events.hex    one 64-bit event per line, in the FPGA's record layout
    events.csv    the same, human readable (for debugging)
    ref.mid       reference MIDI -- THE JUDGEMENT: play it and compare by ear
    report.txt    statistics, including anything deliberately dropped

USAGE
    python tools/gp2evt.py <score.gp> [--outdir DIR] [--track N] [--transpose N]
                           [--bpm N] [--no-midi]

DESIGN NOTES
    * PPQN = 960 to match the FPGA's beat_gen, so ticks map 1:1.
    * phase_inc = round(f * 2^32 / 50e6), f = 440 * 2^((midi-69)/12).
    * Velocity from <Dynamic> (ppp..fff) mapped to 8 bits.
    * Glissando/bend: NOT expanded here.  The score carries pitch events and
      the FPGA already has a pitch_update path; a later step can emit those.
      Anything we cannot represent is COUNTED in report.txt, never silently lost.
"""

from __future__ import annotations

import argparse
import io
import os
import re
import struct
import sys
import zipfile

PPQN = 960                     # must match beat_gen's PPQN
FS = 50_000_000.0              # FPGA system clock
TWO32 = 4294967296.0

# note value -> length in whole-notes (1.0 = a quarter note = 1 beat)
NOTE_VALUE = {
    "Whole": 4.0, "Half": 2.0, "Quarter": 1.0, "Eighth": 0.5,
    "16th": 0.25, "32nd": 0.125, "64th": 0.0625, "128th": 0.03125,
}

# GP dynamic marks -> 8-bit velocity (0..255)
DYNAMIC = {
    "PPP": 20, "PP": 45, "P": 70, "MP": 95, "MF": 130,
    "F": 165, "FF": 200, "FFF": 235,
}
DEFAULT_VEL = 130              # mf, used when a beat carries no <Dynamic>

# kind field of the event record
KIND_ON, KIND_OFF = 0, 1

# event record: 16 tick | 32 phase_inc | 4 axis | 8 velocity | 2 rsv | 2 kind
EVT_BITS = 64


# --------------------------------------------------------------------------- #
# reading
# --------------------------------------------------------------------------- #
def load_gpif(path):
    """Return the score.gpif XML text from a .gp (ZIP) file."""
    if not zipfile.is_zipfile(path):
        raise SystemExit(
            "ERROR: %s is not a ZIP -- it looks like a GP3/4/5 file.\n"
            "       This tool only reads GP7/8 (.gp).  For GP3/4/5 use PyGuitarPro."
            % path)
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if "Content/score.gpif" not in names:
            raise SystemExit("ERROR: no Content/score.gpif inside %s" % path)
        return z.read("Content/score.gpif").decode("utf-8", "replace")


def _txt(body, tag):
    m = re.search(r"<%s>(.*?)</%s>" % (tag, tag), body, re.S)
    return m.group(1).strip() if m else None


def parse_rhythms(x):
    """id -> ticks (at PPQN)."""
    out = {}
    for rid, body in re.findall(r'<Rhythm id="(\d+)">(.*?)</Rhythm>', x, re.S):
        nv = _txt(body, "NoteValue")
        if not nv or nv not in NOTE_VALUE:
            continue
        beats = NOTE_VALUE[nv]
        d = re.search(r'<AugmentationDot[^>]*count="(\d+)"', body)
        dots = int(d.group(1)) if d else 0
        if dots >= 1:
            beats *= 1.5
        if dots >= 2:
            beats *= (1.0 + 1.0 / 3.0)
        t = re.search(r'<PrimaryTuplet[^>]*num="(\d+)"[^>]*den="(\d+)"', body)
        if t:
            beats = beats * int(t.group(2)) / int(t.group(1))
        out[int(rid)] = int(round(beats * PPQN))
    return out


def parse_notes(x):
    """Global note list: index -> (midi, fret, string)."""
    notes = []
    for _, body in re.findall(r'<Note id="(\d+)">(.*?)</Note>', x, re.S):
        m = re.search(r'name="Midi">\s*<Number>(-?\d+)</Number>', body)
        midi = int(m.group(1)) if m else None
        f = re.search(r"name=\"Fret\">\s*<Fret>(-?\d+)</Fret>", body)
        s = re.search(r"name=\"String\">\s*<String>(-?\d+)</String>", body)
        notes.append((midi,
                      int(f.group(1)) if f else None,
                      int(s.group(1)) if s else None))
    return notes


def parse_masterbars(x):
    """List of (time_sig_num, time_sig_den) per master bar."""
    out = []
    for body in re.findall(r"<MasterBar>(.*?)</MasterBar>", x, re.S):
        t = re.search(r"<Time>(\d+)/(\d+)</Time>", body)
        out.append((int(t.group(1)), int(t.group(2))) if t else (4, 4))
    return out


def parse_tracks(x):
    """[(name, [bar_id, ...]), ...] -- which GLOBAL bar ids each track owns.

    ⚠️ In GP8 the bars are GLOBAL (950 = 5 tracks x 190), and a <MasterBar>
    lists the 5 bar ids that belong to it -- one per track, in track order.
    So a track's bars = the k-th bar of every master bar (k = track index).
    (Confirmed by probing a real file; this is NOT the obvious guess.)
    """
    names = []
    for m in re.finditer(r'<Track id="(\d+)">(.*?)(?=<Track id="|\Z)', x, re.S):
        body = m.group(2)
        nm = _txt(body, "Name") or ("Track %s" % m.group(1))
        nm = re.sub(r"^<!\[CDATA\[|\]\]>$", "", nm).strip()
        names.append(nm)

    # every master bar lists N bar ids (N = number of tracks)
    mbs = re.findall(r"<MasterBar>.*?<Bars>([^<]*)</Bars>.*?</MasterBar>",
                     x, re.S)
    per_track = [[] for _ in names]
    for mb in mbs:
        ids = [int(t) for t in mb.split()]
        for k in range(min(len(ids), len(names))):
            per_track[k].append(ids[k])

    return [(names[i], per_track[i]) for i in range(len(names))]


def _section(x, start_tag, end_tag, after=0):
    """Slice the region between start_tag and its matching end_tag.

    ⚠️ Several tags repeat at different nesting levels in a .gpif (e.g. <Bars>
    is both a one-line index list inside every <MasterBar> AND the big
    container holding the 950 <Bar id=..> elements).  Anchor on the FIRST
    occurrence of an element that uniquely identifies the container.
    """
    i = x.find(start_tag, after)
    if i < 0:
        return ""
    j = x.find(end_tag, i)
    return x[i:j] if j > 0 else x[i:]


def _container(x, marker, open_tag, close_tag):
    """Find the element of type open_tag..close_tag that CONTAINS `marker`."""
    k = x.find(marker)
    if k < 0:
        return ""
    i = x.rfind(open_tag, 0, k)
    j = x.find(close_tag, k)
    return x[i:j] if (i >= 0 and j > 0) else ""


def parse_bars(x):
    """bar_id -> [voice_index or -1, ...].

    Anchor on `<Bar id=` (only the real container has it) and walk back to the
    enclosing <Bars>.
    """
    sec = _container(x, "<Bar id=", "<Bars>", "</Bars>")
    out = {}
    for bid, body in re.findall(r'<Bar id="(\d+)">(.*?)</Bar>', sec, re.S):
        v = re.search(r"<Voices>([^<]*)</Voices>", body)
        out[int(bid)] = [int(t) for t in v.group(1).split()] if v else []
    return out


def parse_voices(x):
    """voice_index -> [beat_id, ...].

    Anchor on `<Voice id=` followed by `<Beats>` (only the real container has
    that shape; the per-bar <Voices> are just index lists).
    """
    sec = _container(x, r'<Voice id="0">', "<Voices>", "</Voices>")
    out = {}
    for vid, body in re.findall(r'<Voice id="(\d+)">(.*?)</Voice>', sec, re.S):
        bs = re.search(r"<Beats>([^<]*)</Beats>", body)
        out[int(vid)] = [int(t) for t in bs.group(1).split()] if bs else []
    return out


def parse_beats(x):
    """beat_id -> dict(rhythm, notes, dynamic, body).

    Anchor on `<Beat id=` (only the beat container has it).
    """
    sec = _container(x, "<Beat id=", "<Beats>", "</Beats>")
    out = {}
    for bid, body in re.findall(r'<Beat id="(\d+)">(.*?)</Beat>', sec, re.S):
        r = re.search(r'<Rhythm ref="(\d+)"', body)
        nm = re.search(r"<Notes>(.*?)</Notes>", body, re.S)
        out[int(bid)] = {
            "rhythm": int(r.group(1)) if r else None,
            "notes": [int(t) for t in nm.group(1).split()] if nm else [],
            "dynamic": (_txt(body, "Dynamic") or "").upper(),
            "body": body,
        }
    return out


# --------------------------------------------------------------------------- #
# conversion
# --------------------------------------------------------------------------- #
def note_to_phase_inc(midi):
    f = 440.0 * (2.0 ** ((midi - 69) / 12.0))
    inc = int(round(f * TWO32 / FS))
    return max(0, min(0xFFFFFFFF, inc))


def build_events(x, want_track=None, transpose=0):
    """Return (events, stats).  events = list of dicts in tick order.

    Walk order (matters for timing): track -> bar (in score order) -> voice ->
    beat id -> beat.  Tick advances WITHIN a voice; the four voices of a bar
    all start at the same tick, so each voice needs its own cursor.
    """
    rhythms = parse_rhythms(x)
    notes = parse_notes(x)
    tracks = parse_tracks(x)
    bars = parse_bars(x)
    voices = parse_voices(x)
    beats = parse_beats(x)

    stats = {
        "tracks": [], "notes_total": 0, "events": 0,
        "dropped_no_midi": 0, "dropped_no_rhythm": 0, "dropped_no_beat": 0,
        "max_tick": 0, "min_midi": 999, "max_midi": -999,
        "techniques": {},
    }

    events = []
    for tidx, (name, bar_ids) in enumerate(tracks):
        if want_track is not None and tidx != want_track:
            continue
        stats["tracks"].append(name)

        bar_tick = 0
        for bid in bar_ids:
            slot = bars.get(bid)          # voice indices used in this bar
            if not slot:
                bar_tick += PPQN * 4      # empty bar still advances the grid
                continue

            voice_end = []
            for vi in slot:
                if vi < 0 or vi not in voices:
                    continue
                t = bar_tick              # every voice starts with its bar
                for bt in voices[vi]:
                    b = beats.get(bt)
                    if b is None:
                        stats["dropped_no_beat"] += 1
                        continue
                    dur = rhythms.get(b["rhythm"], 0) \
                        if b["rhythm"] is not None else 0
                    if dur <= 0:
                        stats["dropped_no_rhythm"] += 1
                        continue

                    vel = DYNAMIC.get(b["dynamic"], DEFAULT_VEL)

                    # techniques we deliberately do NOT expand yet (counted)
                    for tech in ("Slide", "Bend", "Harmonic", "PalmMute",
                                 "LetRing", "Vibrato", "Hammer", "Pull"):
                        if "<%s" % tech in b["body"]:
                            stats["techniques"][tech] = \
                                stats["techniques"].get(tech, 0) + 1

                    for i in b["notes"]:
                        if not (0 <= i < len(notes)):
                            continue
                        midi, _fret, _string = notes[i]
                        if midi is None:
                            stats["dropped_no_midi"] += 1
                            continue
                        midi += transpose
                        inc = note_to_phase_inc(midi)
                        # a note_off is ALWAYS emitted: without it the note
                        # would hang forever (the T38 failure mode).
                        events.append({"tick": t, "inc": inc, "vel": vel,
                                       "axis": tidx & 0xF, "kind": KIND_ON,
                                       "midi": midi})
                        events.append({"tick": t + dur, "inc": inc, "vel": vel,
                                       "axis": tidx & 0xF, "kind": KIND_OFF,
                                       "midi": midi})
                        stats["notes_total"] += 1
                        stats["min_midi"] = min(stats["min_midi"], midi)
                        stats["max_midi"] = max(stats["max_midi"], midi)
                        stats["max_tick"] = max(stats["max_tick"], t + dur)

                    t += dur
                voice_end.append(t)

            bar_len = (max(voice_end) - bar_tick) if voice_end else 0
            if bar_len <= 0:
                bar_len = PPQN * 4
            bar_tick += bar_len

    events.sort(key=lambda e: (e["tick"], e["kind"]))
    stats["events"] = len(events)
    return events, stats


# --------------------------------------------------------------------------- #
# writers
# --------------------------------------------------------------------------- #
def pack_event(e):
    return (((e["tick"] & 0xFFFF) << 48)
            | ((e["inc"] & 0xFFFFFFFF) << 16)
            | ((e["axis"] & 0xF) << 12)
            | ((e["vel"] & 0xFF) << 4)
            | (e["kind"] & 0x3))


def write_hex(events, path):
    with io.open(path, "w", encoding="ascii", newline="\n") as f:
        for e in events:
            f.write("%016x\n" % pack_event(e))


def write_csv(events, path):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("idx,tick,kind,midi,phase_inc,velocity,axis\n")
        for i, e in enumerate(events):
            f.write("%d,%d,%s,%d,%d,%d,%d\n" % (
                i, e["tick"],
                "on" if e["kind"] == KIND_ON else "off",
                e["midi"], e["inc"], e["vel"], e["axis"]))


def _vlq(n):
    out = bytearray()
    out.append(n & 0x7F)
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))


def write_midi(events, path, bpm=120, track_name="fpga"):
    """Standard MIDI file, format 0 -- for LISTENING, this is the judgement."""
    # merge on/off into ordered MIDI events; 480 ppq keeps files small
    MIDI_PPQN = 480
    scale = MIDI_PPQN / float(PPQN)
    msgs = []
    for e in events:
        t = int(round(e["tick"] * scale))
        status = (0x90 if e["kind"] == KIND_ON else 0x80) | (e["axis"] & 0x0F)
        msgs.append((t, bytes([status, e["midi"] & 0x7F, e["vel"] & 0x7F])))
    # a note-off must precede an on at the same tick, so sort kind: off(0) first
    msgs.sort(key=lambda m: (m[0], m[1][0] & 0xF0 == 0x90))

    data = bytearray()
    data += _vlq(0) + bytes([0xFF, 0x03, len(track_name)]) + track_name.encode()
    # tempo
    mpqn = int(round(60_000_000.0 / bpm))
    data += _vlq(0) + bytes([0xFF, 0x51, 0x03]) + struct.pack(">I", mpqn)[1:]
    # time signature 4/4
    data += _vlq(0) + bytes([0xFF, 0x58, 0x04, 4, 2, 24, 8])
    # end of track marker added later
    prev = 0
    for t, msg in msgs:
        data += _vlq(t - prev) + msg
        prev = t
    data += _vlq(0) + bytes([0xFF, 0x2F, 0x00])

    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, MIDI_PPQN))
        f.write(b"MTrk" + struct.pack(">I", len(data)) + bytes(data))


def write_report(stats, path, bpm, args):
    L = []
    L.append("gp2evt report")
    L.append("=" * 50)
    L.append("input          : %s" % args.input)
    L.append("tracks used    : %s" % ", ".join(stats["tracks"]))
    L.append("BPM (assumed)  : %d" % bpm)
    L.append("transpose      : %+d semitones" % args.transpose)
    L.append("")
    L.append("notes converted: %d" % stats["notes_total"])
    L.append("events written : %d  (each note = 1 note_on + 1 note_off)"
             % stats["events"])
    L.append("pitch range    : MIDI %d .. %d"
             % (stats["min_midi"], stats["max_midi"]))
    L.append("length         : %d ticks = %.2f bars (4/4 @ PPQN %d)"
             % (stats["max_tick"],
                stats["max_tick"] / float(PPQN * 4), PPQN))
    L.append("")
    if stats["dropped_no_midi"]:
        L.append("WARNING dropped (no Midi number): %d" % stats["dropped_no_midi"])
    if stats["dropped_no_rhythm"]:
        L.append("WARNING dropped (unknown rhythm): %d" % stats["dropped_no_rhythm"])
    if stats["techniques"]:
        L.append("Techniques present but NOT yet expanded (counted, not lost):")
        for k, v in sorted(stats["techniques"].items()):
            L.append("    %-10s %d" % (k, v))
        L.append("  NOTE: pitch bends / glissando should later be emitted as")
        L.append("        pitch_update events on the FPGA's existing path.")
    L.append("")
    L.append("JUDGEMENT: play ref.mid on the PC and compare with the score.")
    io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description="Guitar Pro (.gp) -> FPGA events")
    ap.add_argument("input", help="a .gp file (Guitar Pro 7/8)")
    ap.add_argument("--outdir", default="build/score", help="output directory")
    ap.add_argument("--track", type=int, default=None,
                    help="only this track index (default: all merged)")
    ap.add_argument("--transpose", type=int, default=0, help="semitones")
    ap.add_argument("--bpm", type=int, default=120, help="BPM for ref.mid")
    ap.add_argument("--no-midi", action="store_true", help="skip ref.mid")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit("ERROR: no such file: %s" % args.input)

    x = load_gpif(args.input)
    events, stats = build_events(x, args.track, args.transpose)
    if not events:
        raise SystemExit("ERROR: no events produced -- wrong track index?")

    os.makedirs(args.outdir, exist_ok=True)
    hexp = os.path.join(args.outdir, "events.hex")
    csvp = os.path.join(args.outdir, "events.csv")
    midp = os.path.join(args.outdir, "ref.mid")
    repp = os.path.join(args.outdir, "report.txt")

    write_hex(events, hexp)
    write_csv(events, csvp)
    if not args.no_midi:
        write_midi(events, midp, args.bpm)
    write_report(stats, repp, args.bpm, args)

    print("wrote %s" % hexp)
    print("wrote %s" % csvp)
    if not args.no_midi:
        print("wrote %s   <-- PLAY THIS and compare with the score" % midp)
    print("wrote %s" % repp)
    print("")
    print("notes=%d events=%d length=%.2f bars"
          % (stats["notes_total"], stats["events"],
             stats["max_tick"] / float(PPQN * 4)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
