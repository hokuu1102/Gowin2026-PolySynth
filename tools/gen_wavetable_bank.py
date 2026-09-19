#!/usr/bin/env python3
"""Generate a deterministic 512 x signed-16 sine wavetable."""

from pathlib import Path
import hashlib
import math
import sys


DEPTH = 512
DATA_WIDTH = 16
AMPLITUDE = 32767

REPO_ROOT = Path(__file__).resolve().parents[1]
ROM_DIR = REPO_ROOT / "rtl" / "w3b" / "rom"
EVIDENCE_DIR = REPO_ROOT / "evidence" / "w1_2"

HEX_PATH = ROM_DIR / "sine_512x16.hex"
CSV_PATH = ROM_DIR / "sine_512x16.csv"
MI_PATH = ROM_DIR / "sine_512x16.mi"
METADATA_PATH = EVIDENCE_DIR / "wavetable_metadata.txt"


def generate_samples():
    """Generate one sine period with exact half-wave symmetry."""

    first_half = [
        int(round(AMPLITUDE * math.sin(2.0 * math.pi * n / DEPTH)))
        for n in range(DEPTH // 2)
    ]

    # Construct the second half by negation. This avoids floating-point
    # asymmetry around pi and guarantees zero DC sum.
    return first_half + [-value for value in first_half]


def validate_samples(samples):
    """Fail immediately if any W1-2 wavetable condition is violated."""

    if len(samples) != DEPTH:
        raise ValueError(f"expected {DEPTH} samples, got {len(samples)}")

    if min(samples) < -AMPLITUDE or max(samples) > AMPLITUDE:
        raise ValueError("sample exceeds signed-16 amplitude limit")

    expected_points = {
        0: 0,
        128: 32767,
        256: 0,
        384: -32767,
    }

    for address, expected in expected_points.items():
        actual = samples[address]
        if actual != expected:
            raise ValueError(
                f"sample[{address}] expected {expected}, got {actual}"
            )

    for n in range(DEPTH // 2):
        if samples[n + DEPTH // 2] != -samples[n]:
            raise ValueError(f"half-wave symmetry failed at address {n}")

    if sum(samples) != 0:
        raise ValueError(f"DC sum expected 0, got {sum(samples)}")


def to_u16(value):
    """Return the 16-bit two's-complement representation."""

    return value & 0xFFFF


def sample_digest(samples):
    """Hash the complete table as big-endian unsigned 16-bit words."""

    payload = b"".join(
        to_u16(value).to_bytes(2, byteorder="big")
        for value in samples
    )
    return hashlib.sha256(payload).hexdigest()


def render_hex(samples):
    return "".join(f"{to_u16(value):04X}\n" for value in samples)


def render_csv(samples):
    rows = ["address,signed,hex\n"]

    for address, value in enumerate(samples):
        rows.append(f"{address},{value},{to_u16(value):04X}\n")

    return "".join(rows)


def render_mi(samples):
    """Render the Gowin pROM memory-initialization format."""

    header = (
        "#File_format=Hex\n"
        f"#Address_depth={DEPTH}\n"
        f"#Data_width={DATA_WIDTH}\n"
    )
    return header + render_hex(samples)


def render_metadata(samples, digest):
    return (
        "generator=tools/gen_wavetable_bank.py\n"
        "waveform=sine\n"
        f"depth={DEPTH}\n"
        f"data_width={DATA_WIDTH}\n"
        f"amplitude={AMPLITUDE}\n"
        f"minimum={min(samples)}\n"
        f"maximum={max(samples)}\n"
        f"sum={sum(samples)}\n"
        f"sample_0={samples[0]}\n"
        f"sample_128={samples[128]}\n"
        f"sample_256={samples[256]}\n"
        f"sample_384={samples[384]}\n"
        "half_wave_symmetry=PASS\n"
        f"sample_sha256_be={digest}\n"
    )


def write_if_changed(path, content):
    """Avoid rewriting identical files and keep generation deterministic."""

    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists() and path.read_text(encoding="ascii") == content:
        return False

    with path.open("w", encoding="ascii", newline="\n") as output_file:
        output_file.write(content)

    return True


def main():
    samples = generate_samples()
    validate_samples(samples)
    digest = sample_digest(samples)

    outputs = {
        HEX_PATH: render_hex(samples),
        CSV_PATH: render_csv(samples),
        MI_PATH: render_mi(samples),
        METADATA_PATH: render_metadata(samples, digest),
    }

    for path, content in outputs.items():
        changed = write_if_changed(path, content)
        state = "written" if changed else "unchanged"
        print(f"{state}: {path.relative_to(REPO_ROOT)}")

    print(f"depth       = {len(samples)}")
    print(f"width       = {DATA_WIDTH}")
    print(f"minimum     = {min(samples)}")
    print(f"maximum     = {max(samples)}")
    print(f"sum         = {sum(samples)}")
    print(f"sample[0]   = {samples[0]}")
    print(f"sample[128] = {samples[128]}")
    print(f"sample[256] = {samples[256]}")
    print(f"sample[384] = {samples[384]}")
    print("symmetry    = PASS")
    print(f"sha256      = {digest}")
    print("PASS: generated deterministic 512x16 sine wavetable")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
