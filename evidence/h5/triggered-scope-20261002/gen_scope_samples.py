# gen_scope_samples.py - build a sine table for the waveform_scope dump testbench.
# Sample rate = 50 MHz / 1024 = 48828.125 Hz (the design's sample_tick rate).
# ASCII-only on purpose.
import math
import os

FS_HZ = 50_000_000.0 / 1024.0          # 48828.125
FREQ = 523.25                          # C5
AMP = 3_000_000                        # ~36% of 2^23 -> trace spans y 57..423
NSAMP = 1 << 17                        # 131072 samples (~2.68 s), looped

out_dir = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(out_dir, 'scope_samples.hex')

with open(path, 'w', encoding='ascii') as f:
    for n in range(NSAMP):
        v = int(round(AMP * math.sin(2.0 * math.pi * FREQ * n / FS_HZ)))
        # 24-bit two's complement, 6 hex digits
        f.write('%06x\n' % (v & 0xFFFFFF))

print('wrote', path, NSAMP, 'samples')
print('sample rate Hz =', FS_HZ)
print('period in samples =', FS_HZ / FREQ)
print('640-sample window = %.3f ms (%.2f cycles)' % (640 / FS_HZ * 1000, 640 * FREQ / FS_HZ))
print('frame period = 16.683 ms -> window advance per frame = %.3f ms (%.2f cycles)'
      % ((1 / 60.0 - 640 / FS_HZ) * 1000, (1 / 60.0 - 640 / FS_HZ) * FREQ))
