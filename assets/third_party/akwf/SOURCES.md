# AKWF source manifest

The four files in this directory are vendored, single-cycle source tables for
the T31b wavetable ROM. They are not PCM phrases or instrument recordings.

- Upstream: <https://github.com/KristofferKarlAxelEkstrand/AKWF-FREE>
- Pinned upstream commit: `8de90bf94376670947369e69de0af6b9fbd19286`
- Imported form: upstream `AKWF--Teensy` 256-sample signed `int16_t` headers.
- Licence: CC0 1.0 Universal; the complete upstream text is retained in
  [LICENSE-CC0-1.0.txt](LICENSE-CC0-1.0.txt).

| Synth timbre | Imported file | Upstream path |
|---|---|---|
| BASS | `AKWF_dbass_0050_256.h` | `AKWF--Teensy/AKWF_dbass/AKWF_dbass_0050_256.h` |
| GUITAR | `AKWF_eguitar_0015_256.h` | `AKWF--Teensy/AKWF_eguitar/AKWF_eguitar_0015_256.h` |
| PIANO | `AKWF_clavinet_0005_256.h` | `AKWF--Teensy/AKWF_clavinet/AKWF_clavinet_0005_256.h` |
| PAD | `AKWF_eorgan_0020_256.h` | `AKWF--Teensy/AKWF_eorgan/AKWF_eorgan_0020_256.h` |

`tools/gen_t31b_wavetable.py` removes each source's DC component, creates the
existing quiet endpoint with a cyclic 5-tap low-pass repeated three times,
normalizes it to Q1.15, then performs offline periodic 256-to-1024 linear
resampling. The FPGA still receives exactly one 1024-point soft table and one
1024-point hard table per timbre; no new runtime interpolation, ports, RAM, or
hardware signals are introduced.
