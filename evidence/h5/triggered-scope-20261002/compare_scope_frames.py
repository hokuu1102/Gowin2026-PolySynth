# compare_scope_frames.py - quantify how well two dumped frames agree.
# ASCII-only on purpose.
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 640, 480


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    return data.split(b'\n', 3)[3]


def trace(body):
    tr = [None] * W
    for x in range(W):
        for y in range(H):
            i = (y * W + x) * 3
            r, g, b = body[i], body[i + 1], body[i + 2]
            if g > 128 and r < 64 and b < 64:
                if tr[x] is None:
                    tr[x] = [y, y]
                else:
                    tr[x][1] = y
    return [((a + b) / 2.0 if a is not None else None) for a, b in
            [(t[0], t[1]) if t else (None, None) for t in tr]]


def main():
    a = trace(read_ppm(os.path.join(HERE, 'frameA.ppm')))
    b = trace(read_ppm(os.path.join(HERE, 'frameB.ppm')))

    diffs = [(x, abs(a[x] - b[x])) for x in range(W)
             if a[x] is not None and b[x] is not None]
    n = len(diffs)
    print('columns compared:', n)
    for th in (1, 2, 3, 5, 10, 20):
        ok = sum(1 for _, d in diffs if d <= th)
        print('  |dy| <= %2d px : %3d / %d columns (%.1f%%)' % (th, ok, n, 100.0 * ok / n))
    mx = max(diffs, key=lambda t: t[1])
    print('  max |dy| = %.1f px at column %d' % (mx[1], mx[0]))
    avg = sum(d for _, d in diffs) / n
    print('  mean |dy| = %.2f px' % avg)

    # where do the large differences live?
    big = [x for x, d in diffs if d > 10]
    print('  columns with |dy| > 10 px:', len(big), big[:20])


if __name__ == '__main__':
    main()
