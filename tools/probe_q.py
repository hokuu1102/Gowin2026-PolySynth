#!/usr/bin/env python3
"""
probe_q.py -- auto-send 'P' and report the 'Q' diagnostic packets.

WHY:
  The `'Q'` diagnostic (added 2026-09-28) reports, in the FPGA, the peak
  |delta pos| over ALL axes plus the axis where that peak happened.
  `Q` is CLEARED ON READ, so every 'P' gives one independent measurement window.

  This is the tool for the question:
      "when I bang the key hard, does the Hall reading JUMP?"
        Q ~ tens        -> Hall is clean  -> the shrill sound is downstream
        Q ~ 700+        -> Hall IS jumping -> upstream is the culprit

REPLY FORMAT (8 bytes each; a single 'P' returns THREE packets):
    P<ch><pos>    raw code of the ADC channel being scanned right now
    N<ax><pos>    calibrated travel of one axis (rotates on every request)
    Q<ax><dpos>   peak |dpos| since the last 'P'  + the axis of that peak

USAGE:
    python tools/probe_q.py                      # 20 samples, 0.4 s apart
    python tools/probe_q.py COM32 50 0.3         # port, count, gap seconds
    python tools/probe_q.py COM32 200 0.05       # fast burst while you bang

NOTE: pure ASCII on purpose (no encoding traps).  Requires pyserial.
"""

import re
import sys
import time

import serial

HEX = re.compile(r"([PNQ])([0-9A-Fa-f])(\d{4})")


def main():
    #  ⚠️ ROBUST ARG PARSING (2026-09-28):
    #  cmd.exe has NO comment marker, so `python tools\probe_q.py   # 20 次采样`
    #  passes "20", "次采样，间隔", "0.4", "s" as ARGUMENTS.
    #  => never crash on them: just keep the ones that look like numbers.
    args = [a for a in sys.argv[1:] if not a.startswith("#")]
    num = re.compile(r"\d+(\.\d+)?$")
    port = args[0] if args and not num.match(args[0]) else "COM32"
    nums = [a for a in args if num.match(a)]
    count = int(float(nums[0])) if len(nums) > 0 else 20
    gap = float(nums[1]) if len(nums) > 1 else 0.4
    baud = 500000

    print("# port %s @ %d 8N1 | %d samples | gap %.3f s" % (port, baud, count, gap))
    try:
        ser = serial.Serial(port, baud, bytesize=8, parity="N",
                            stopbits=1, timeout=0.3)
    except Exception as exc:
        print("!! cannot open %s : %s" % (port, exc))
        print("!! is a serial terminal / 串口助手 holding it?")
        return 1

    try:
        ser.reset_input_buffer()
    except Exception:
        pass

    print("%6s  %-10s %-6s %-8s   %s" % ("t(s)", "packet", "axis", "dpos", "note"))
    print("-" * 62)
    t0 = time.time()
    peak = -1
    peak_ax = "-"
    got = 0
    #  ⭐⭐ PER-CHANNEL RAW STATS (this is the part that actually decides
    #  "Hall is bouncing" vs "the ADC/SPI read a bad sample"):
    #  ONE 'P' returns only ONE `P` packet (the channel being scanned right now)
    #  and ONE `Q` packet (the axis of the peak) -- they are DIFFERENT axes, so
    #  a per-sample comparison is meaningless.  Instead collect the raw codes
    #  per channel and look at their SPREAD:
    #      ch 5 spread ~ 700  -> the raw reading really swings (Hall / mechanics)
    #      ch 5 spread ~  10  -> the raw reading is clean; the jump is created
    #                            downstream (calib / velocity path)
    pstat = {}
    for i in range(count):
        ser.reset_input_buffer()
        ser.write(b"P")
        time.sleep(gap)
        raw = ser.read(64)
        txt = raw.decode("ascii", errors="replace")
        found = HEX.findall(txt)
        if not found:
            print("%6.2f  (no reply -- %d bytes: %r)" % (time.time() - t0, len(raw), txt[:24]))
            continue
        line = {}
        for (pfx, ax, val) in found:
            line[pfx] = (ax, int(val))
        q = line.get("Q")
        if q:
            got += 1
            ax, val = q
            #  ⭐⭐ ALSO print the RAW ADC code (`P<ch><pos>`).
            #  WHY: `Q` says the CALIBRATED travel jumped.  To tell
            #  "the Hall/mechanics bounced" apart from "the ADC/SPI read a bad
            #  sample", compare the RAW code in the same window:
            #      raw also jumps  -> upstream (Hall / mechanics / SPI read)
            #      raw is smooth   -> the calib chain is producing the jump
            p = line.get("P")
            praw = ("raw P%s=%-5d" % (p[0], p[1])) if p else "raw P=--"
            if p:
                pstat.setdefault(p[0], []).append(p[1])
            mark = ""
            if val > peak:
                peak, peak_ax = val, ax
                mark = "  <== new max"
            if val >= 300:
                mark += "   *** HALL JUMPED ***"
            print("%6.2f  Q%s=%-5d %s   %s"
                  % (time.time() - t0, ax, val, praw, mark))
        else:
            print("%6.2f  (no Q packet; saw %s)" % (time.time() - t0, sorted(line.keys())))
    ser.close()

    print("-" * 62)
    print("Q samples=%d   peak |dpos| = %d on axis %s" % (got, peak, peak_ax))
    print("")
    print("RAW ADC CODE per channel (from the 'P' packets):")
    if not pstat:
        print("  (no P packets seen)")
    for ch in sorted(pstat):
        v = pstat[ch]
        print("  ch %s : n=%3d  min=%4d  max=%4d  SPREAD=%4d"
              % (ch, len(v), min(v), max(v), max(v) - min(v)))
    print("")
    print("HOW TO READ:")
    print("  1) look at the SPREAD of the channel that shows big Q values")
    print("       spread ~ 500+  -> the RAW reading really swings (Hall / mechanics)")
    print("       spread ~  20   -> the RAW reading is CLEAN; the jump is created")
    print("                         downstream (calib gain not set / velocity path)")
    print("  2) peak |dpos| ~ tens .. low hundreds  -> clean")
    print("     peak |dpos| ~ 700+ (near full travel) -> jumping")
    return 0


if __name__ == "__main__":
    sys.exit(main())
