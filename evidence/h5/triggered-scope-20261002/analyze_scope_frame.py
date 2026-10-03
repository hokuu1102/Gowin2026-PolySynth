# analyze_scope_frame.py - decide whether the RTL draws one or two traces per frame,
# and measure the frame-to-frame horizontal shift.
# ASCII-only on purpose.
import os
import struct
import sys
import zlib

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 640, 480


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    # header: P6\n640 480\n255\n
    parts = data.split(b'\n', 3)
    assert parts[0] == b'P6', parts[0]
    body = parts[3]
    return body


def write_png(path, rgb, w=W, h=H):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgb[y * w * 3:(y + 1) * w * 3]

    def chunk(tag, payload):
        c = struct.pack('>I', len(payload)) + tag + payload
        return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def green_columns(body):
    """Return per-column list of green y values."""
    cols = [[] for _ in range(W)]
    for y in range(H):
        base = y * W * 3
        for x in range(W):
            i = base + x * 3
            r, g, b = body[i], body[i + 1], body[i + 2]
            if g > 128 and r < 64 and b < 64:
                cols[x].append(y)
    return cols


def runs(ys):
    """Count contiguous runs in a sorted y list."""
    if not ys:
        return 0
    n = 1
    for a, b in zip(ys, ys[1:]):
        if b != a + 1:
            n += 1
    return n


def trace_of(cols):
    """Per-column trace y (midpoint of the single run), or None."""
    tr = []
    for ys in cols:
        tr.append((ys[0] + ys[-1]) / 2.0 if ys else None)
    return tr


def report(tag, cols):
    counts = {}
    multi = []
    empty = 0
    widths = []
    for x, ys in enumerate(cols):
        n = runs(ys)
        counts[n] = counts.get(n, 0) + 1
        if n == 0:
            empty += 1
        if n > 1:
            multi.append((x, n))
        if ys:
            widths.append(ys[-1] - ys[0] + 1)
    print('--- %s ---' % tag)
    print('  columns with N green runs:', dict(sorted(counts.items())))
    print('  empty columns:', empty)
    print('  columns with >1 run:', len(multi), multi[:10])
    if widths:
        print('  vertical run width: min %d, max %d, avg %.1f'
              % (min(widths), max(widths), sum(widths) / len(widths)))
    return multi


def main():
    a = read_ppm(os.path.join(HERE, 'frameA.ppm'))
    b = read_ppm(os.path.join(HERE, 'frameB.ppm'))
    print('frame size bytes =', len(a), len(b))

    colsA = green_columns(a)
    colsB = green_columns(b)
    multiA = report('frameA', colsA)
    multiB = report('frameB', colsB)

    # write PNGs so they can be viewed
    write_png(os.path.join(HERE, 'frameA.png'), a)
    write_png(os.path.join(HERE, 'frameB.png'), b)

    trA = trace_of(colsA)
    trB = trace_of(colsB)

    # continuity within each frame: max |y(x+1)-y(x)| over consecutive non-empty columns
    def maxjump(tr):
        m = 0.0
        prev = None
        where = None
        for x, v in enumerate(tr):
            if v is None:
                prev = None
                continue
            if prev is not None and abs(v - prev) > m:
                m = abs(v - prev)
                where = x
            prev = v
        return m, where

    jA = maxjump(trA)
    jB = maxjump(trB)
    print('  max |dy| between adjacent columns: frameA %.1f (x=%s), frameB %.1f (x=%s)'
          % (jA[0], jA[1], jB[0], jB[1]))

    # frame-to-frame horizontal shift: best match of trA against trB
    validA = [x for x, v in enumerate(trA) if v is not None]
    validB = [x for x, v in enumerate(trB) if v is not None]
    print('  non-empty columns: frameA %d, frameB %d' % (len(validA), len(validB)))

    best = None
    for shift in range(-320, 321):
        num = 0
        den = 0
        for x in range(W):
            xa = x
            xb = x + shift
            if 0 <= xb < W and trA[xa] is not None and trB[xb] is not None:
                num += (trA[xa] - trB[xb]) ** 2
                den += 1
        if den > 100:
            score = num / den
            if best is None or score < best[0]:
                best = (score, shift, den)
    if best:
        print('  best frameA->frameB horizontal shift = %d px (rms %.1f over %d cols)'
              % (best[1], best[0] ** 0.5, best[2]))
    else:
        print('  could not estimate a shift')

    # direct per-column difference with no shift
    same = 0
    diff = 0
    for x in range(W):
        if trA[x] is not None and trB[x] is not None:
            if abs(trA[x] - trB[x]) <= 1.0:
                same += 1
            else:
                diff += 1
    print('  no-shift comparison: identical %d cols, different %d cols' % (same, diff))


if __name__ == '__main__':
    main()
