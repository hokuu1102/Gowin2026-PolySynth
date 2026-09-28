#!/usr/bin/env python3
"""Render the selected T31b AKWF tables as a short WAV audition.

This is an offline listening aid: it uses the same table-generation path as
the ROM source, with a conservative ADSR and no DAC or amplifier modelling.
"""
from __future__ import annotations

import struct
import wave
from pathlib import Path

from gen_t31b_wavetable import DEPTH, generate_tables

FS = 48_828
FREQUENCY_HZ = 220.0
NOTE_SECONDS = 1.25
GAP_SECONDS = 0.15
NAMES = ("bass", "guitar", "clavinet", "pad")
OUT_DIR = Path(__file__).resolve().parents[1] / "sim" / "evidence" / "wav_export"


def envelope(index: int, total: int) -> float:
    attack = int(FS * 0.020)
    decay = int(FS * 0.120)
    release = int(FS * 0.260)
    sustain = 0.68
    if index < attack:
        return index / max(attack, 1)
    if index < attack + decay:
        return 1.0 - (1.0 - sustain) * (index - attack) / max(decay, 1)
    if index >= total - release:
        return sustain * max(total - index, 0) / max(release, 1)
    return sustain


def render(table: list[int], samples: int) -> list[int]:
    phase = 0.0
    increment = FREQUENCY_HZ * DEPTH / FS
    output: list[int] = []
    for index in range(samples):
        base = int(phase) % DEPTH
        frac = phase - int(phase)
        value = table[base] + (table[(base + 1) % DEPTH] - table[base]) * frac
        output.append(round(value * envelope(index, samples) * 0.42))
        phase = (phase + increment) % DEPTH
    return output


def write_wav(path: Path, samples: list[int]) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(FS)
        output.writeframes(struct.pack("<" + "h" * len(samples), *samples))


def main() -> None:
    tables = generate_tables()
    note_samples = round(FS * NOTE_SECONDS)
    gap = [0] * round(FS * GAP_SECONDS)
    playlist: list[int] = []
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, (_soft, hard) in zip(NAMES, tables):
        samples = render(hard, note_samples)
        write_wav(OUT_DIR / f"t31b_{name}_220hz.wav", samples)
        playlist.extend(samples)
        playlist.extend(gap)
    write_wav(OUT_DIR / "t31b_four_timbres_220hz.wav", playlist)
    print(f"wrote {OUT_DIR / 't31b_four_timbres_220hz.wav'}")


if __name__ == "__main__":
    main()
