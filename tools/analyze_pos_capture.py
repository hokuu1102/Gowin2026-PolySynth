#!/usr/bin/env python3
"""
analyze_pos_capture.py -- analyse a `board_probe.py --follow P` capture.

WHY:
  We need to decide whether the magnetic-axis (Hall) position reading is
  STABLE during a hard key press.  The FPGA answers `P<dddd>\\r\\n` to every
  `P` command, so polling `P` at ~500 Hz gives a position trace.

USAGE:
  python tools/analyze_pos_capture.py build/probe/hall_cap1.txt

WHAT IT REPORTS (all numbers, no hand-waving):
  1. sample count + measured polling period
  2. idle noise floor  (segments where pos stays low)
  3. the largest single-step jumps |dpos| between consecutive samples
  4. DIRECTION REVERSALS inside one press  <- the "Hall is bouncing" signature
  5. how many times pos RISES through the event-extract trigger threshold (64)
     (each rising crossing can emit a note_on -> retrigger storm)
  6. a compact dump of the busiest press window so the shape can be eyeballed

NOTE: pure ASCII on purpose (no BOM / encoding traps).
"""

import re
import sys

THRESH_TRIG = 64          # top.v EVT_TRIG_TH
REV_MIN     = 20          # |dpos| that counts as a real reversal
IDLE_MAX    = 64          # pos <= this counts as "not pressed"

# One LINE = one WHOLE reply, e.g.
#   [  0.527] << 'N00000..'  4E 30 30 30 30 30 0D 0A
# NOTE: the hex bytes are printed BARE (no "0x" prefix) -- the earlier regex
# expecting "0xNN" matched nothing at all.
LINE_RE = re.compile(r"\[\s*([0-9.]+)\]\s*<<.*?\s((?:[0-9A-Fa-f]{2}\s*)+)\s*$")


def parse(path, want_ch=None):
    """Return [(t, pos), ...] from the probe log.

    REAL FORMAT -- 8 bytes, verified against pos_probe.v's tx_byte_c case:
        <PREFIX 'P'|'N'> <channel-char> <4 decimal digits> CR LF
    e.g. `P72171` = channel '7', pos = 2171.

    !!! The old comment saying "P + 4 digits" was WRONG, and more importantly:
    `'P'` reports the ADC channel that happens to be scanned RIGHT NOW
    (af0_pol / af_sample_ch, rotating every frame) -> its readings jump
    between channels and are USELESS for studying one axis.
    `'N'` reports the CALIBRATED travel of ONE axis and rotates the axis
    on every request -> use --ch to pick one axis out of the stream.
    """
    samples = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LINE_RE.search(line)
            if not m:
                continue
            t = float(m.group(1))
            bs = [int(x, 16) for x in m.group(2).split()]
            # <PREFIX 'P'|'N'> <channel-char> <4 digits> CR LF
            if len(bs) < 7 or bs[0] not in (0x50, 0x4E):
                continue
            ch = bs[1]
            digs = bs[2:6]
            if not all(0x30 <= d <= 0x39 for d in digs):
                continue
            if (want_ch is None) or (chr(ch).upper() == want_ch.upper()):
                samples.append((t, int("".join(chr(d) for d in digs))))
    return samples


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_pos_capture.py <probe-log> [channel-char]")
        print("       channel-char = 0..9 / A..F  (REQUIRED for 'N' captures,")
        print("       because 'N' rotates the axis on every request)")
        return 1
    path = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else None
    if want:
        print("filtering channel '%s' only" % want)
    s = parse(path, want)
    if len(s) < 10:
        print("only %d samples parsed -- is the capture empty / wrong port?" % len(s))
        return 1

    ts = [x[0] for x in s]
    ps = [x[1] for x in s]
    n = len(s)
    span = ts[-1] - ts[0]
    period = span / (n - 1) if n > 1 else 0.0

    print("=" * 72)
    print("samples            : %d" % n)
    print("time span          : %.3f s" % span)
    print("measured period    : %.3f ms  (~%.0f Hz)" % (period * 1000.0, 1.0 / period if period else 0))
    print("pos min / max      : %d / %d" % (min(ps), max(ps)))
    print("distinct pos values: %d" % len(set(ps)))

    # ---- 1. idle noise floor (pos <= IDLE_MAX) ---------------------------
    idle = [i for i in range(n) if ps[i] <= IDLE_MAX]
    if idle:
        segs = []
        run = [idle[0]]
        for i in idle[1:]:
            if i == run[-1] + 1:
                run.append(i)
            else:
                segs.append(run)
                run = [i]
        segs.append(run)
        big = [g for g in segs if len(g) >= 20]
        print("-" * 72)
        print("idle samples (pos<=%d) : %d in %d runs (%d runs >= 20 samples)"
              % (IDLE_MAX, len(idle), len(segs), len(big)))
        if big:
            jit = []
            for g in big:
                vals = [ps[i] for i in g]
                jit.append(max(vals) - min(vals))
            print("idle pos spread per run: min=%d max=%d  <-- noise floor"
                  % (min(jit), max(jit)))

    # ---- 2. largest single steps ----------------------------------------
    d = [ps[i + 1] - ps[i] for i in range(n - 1)]
    order = sorted(range(len(d)), key=lambda i: -abs(d[i]))
    print("-" * 72)
    print("largest |dpos| between consecutive samples:")
    for k in order[:10]:
        print("   t=%8.3f  %4d -> %4d   d=%+5d   (%.1f counts/ms)"
              % (ts[k], ps[k], ps[k + 1], d[k],
                 abs(d[k]) / (period * 1000.0) if period else 0))

    # ---- 3. direction reversals ----------------------------------------
    revs = []
    for i in range(len(d) - 1):
        a, b = d[i], d[i + 1]
        if a == 0 or b == 0:
            continue
        if (a > 0) != (b > 0) and min(abs(a), abs(b)) >= REV_MIN:
            revs.append((i + 1, ps[i + 1], a, b))
    print("-" * 72)
    print("direction reversals with |d|>=%d : %d" % (REV_MIN, len(revs)))
    for (i, p, a, b) in revs[:12]:
        print("   t=%8.3f  pos=%4d   was %+5d now %+5d" % (ts[i], p, a, b))

    # ---- 4. rising crossings of the trigger threshold -------------------
    rise = 0
    rise_t = []
    for i in range(n - 1):
        if ps[i] <= THRESH_TRIG < ps[i + 1]:
            rise += 1
            rise_t.append(ts[i])
    print("-" * 72)
    print("RISING crossings of pos=%d (event_extract trigger) : %d"
          % (THRESH_TRIG, rise))
    for t in rise_t[:20]:
        print("   t=%8.3f" % t)

    # ---- 5. busiest press window dump ----------------------------------
    if max(ps) > IDLE_MAX:
        # find the sample with the max pos, dump +-15 samples around it
        pk = ps.index(max(ps))
        lo = max(0, pk - 15)
        hi = min(n, pk + 16)
        print("-" * 72)
        print("window around the deepest press (t=%.3f, pos=%d):" % (ts[pk], ps[pk]))
        for i in range(lo, hi):
            mark = "  <-- peak" if i == pk else ""
            print("   t=%8.3f  pos=%4d%s" % (ts[i], ps[i], mark))

    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
