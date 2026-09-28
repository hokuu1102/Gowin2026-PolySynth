#!/usr/bin/env python3
"""Generate the embedded T31b four-timbre soft/hard wavetable ROM."""

from pathlib import Path
import re
import sys

DEPTH = 1024
SAMPLE_W = 16
AMPLITUDE = 32767
TIMBRES = ("BASS", "GUITAR", "PIANO", "PAD")
REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_PATH = REPO_ROOT / "rtl" / "w3b" / "wavetable_bank.v"
METADATA_PATH = REPO_ROOT / "evidence" / "w1_2" / "wavetable_t31b_metadata.txt"
AKWF_DIR = REPO_ROOT / "assets" / "third_party" / "akwf"

# Every source is a CC0 AKWF 256-point signed-16 table.  The exact upstream
# paths, conversion policy and licence are recorded beside these assets.
AKWF_SOURCES = (
    "AKWF_dbass_0050_256.h",   # BASS
    "AKWF_eguitar_0015_256.h", # GUITAR
    "AKWF_clavinet_0005_256.h",  # PIANO (clavinet: 与 GUITAR 的拨弦区分开)
    "AKWF_eorgan_0020_256.h",  # PAD
)


def read_akwf_source(filename):
    """Read the 256 signed values from one vendored AKWF C header."""
    text = (AKWF_DIR / filename).read_text(encoding="utf-8")
    try:
        body = text.split("{", 1)[1].split("}", 1)[0]
    except IndexError as error:
        raise ValueError(f"{filename}: missing C array body") from error
    samples = [int(value) for value in re.findall(r"-?\d+", body)]
    if len(samples) != 256:
        raise ValueError(f"{filename}: expected 256 source samples, got {len(samples)}")
    if min(samples) < -32768 or max(samples) > 32767:
        raise ValueError(f"{filename}: source exceeds signed-16")
    return samples


def normalize_zero_dc(samples, amplitude):
    """Remove DC, normalise peak, and correct final rounding DC exactly."""
    mean = sum(samples) / len(samples)
    centered = [value - mean for value in samples]
    peak = max(abs(value) for value in centered)
    if peak == 0:
        raise ValueError("cannot normalise a silent source")
    result = [int(round(amplitude * value / peak)) for value in centered]
    correction = sum(result)
    # Rounding can leave a few LSB of DC.  Correct from the tail so source
    # anchors at the beginning/quarters remain stable and no click is added.
    index = len(result) - 1
    while correction:
        step = -1 if correction > 0 else 1
        result[index] += step
        correction += step
        index = (index - 1) % len(result)
    return result


def smooth_periodic(samples, passes=3, radius=2):
    """Offline cyclic low-pass for the quiet end of the existing blend."""
    result = [float(value) for value in samples]
    width = 2 * radius + 1
    for _ in range(passes):
        result = [sum(result[(index + offset) % len(result)]
                      for offset in range(-radius, radius + 1)) / width
                  for index in range(len(result))]
    return result


def upsample_periodic(samples):
    """Offline 256-to-1024 interpolation; no FPGA phase interpolator is added."""
    source_depth = len(samples)
    if DEPTH % source_depth:
        raise ValueError(f"cannot evenly upsample {source_depth} to {DEPTH}")
    ratio = DEPTH // source_depth
    result = []
    for address in range(DEPTH):
        base = address // ratio
        following = (base + 1) % source_depth
        fraction = (address % ratio) / ratio
        result.append(int(round(samples[base] + (samples[following] - samples[base]) * fraction)))
    return result


def generate_tables():
    tables = []
    for filename in AKWF_SOURCES:
        source = read_akwf_source(filename)
        soft = upsample_periodic(normalize_zero_dc(smooth_periodic(source), AMPLITUDE))
        hard = upsample_periodic(normalize_zero_dc(source, AMPLITUDE))
        # Upsampling has its own rounding, so make each final hardware table
        # exactly zero-DC before it is embedded in the ROM.
        tables.append((normalize_zero_dc(soft, AMPLITUDE),
                       normalize_zero_dc(hard, AMPLITUDE)))
    return tables


def validate_table(name, samples):
    if len(samples) != DEPTH:
        raise ValueError(f"{name}: wrong depth")
    if min(samples) < -32768 or max(samples) > 32767:
        raise ValueError(f"{name}: signed-16 range exceeded")
    if sum(samples) != 0:
        raise ValueError(f"{name}: DC sum must be zero, got {sum(samples)}")


def render_prom_instance(kind, timbre, samples):
    """Render one Gowin 1024x16 pROM with deterministic INIT parameters."""
    stem = f"rom_{kind}_t{timbre}_inst"
    lines = [
        f"    pROM {stem} (",
        f"        .DO({{{stem}_dout_w[15:0], {stem}_do[15:0]}}),",
        "        .CLK(clk_i),",
        "        .OCE(1'b1),",
        "        .CE(rd_en_i),",
        "        .RESET(~rst_n_i),",
        "        .AD({addr_i[9:0], 4'b0000})",
        "    );",
        f"    defparam {stem}.READ_MODE = 1'b0;",
        f"    defparam {stem}.BIT_WIDTH = 16;",
        f'    defparam {stem}.RESET_MODE = "SYNC";',
    ]
    for block in range(64):
        words = samples[block * 16:(block + 1) * 16]
        # Gowin INIT_RAM_x stores the lowest address in the least-significant
        # 16 bits, hence the textual hexadecimal words are emitted reversed.
        packed = "".join(f"{value & 0xFFFF:04X}" for value in reversed(words))
        lines.append(f"    defparam {stem}.INIT_RAM_{block:02X} = 256'h{packed};")
    return "\n".join(lines)


def render_rtl(tables):
    wire_lines = []
    instance_blocks = []
    for timbre, (soft, hard) in enumerate(tables):
        for kind, samples in (("soft", soft), ("hard", hard)):
            stem = f"rom_{kind}_t{timbre}_inst"
            wire_lines.extend((f"    wire [15:0] {stem}_do;",
                               f"    wire [15:0] {stem}_dout_w;"))
            instance_blocks.append(render_prom_instance(kind, timbre, samples))

    return f'''`timescale 1ns/1ps
// T31b generated ROM: 4 timbres x 1024 points x soft/hard, all embedded.
// IDs: 0=BASS, 1=GUITAR, 2=PIANO, 3=PAD; CC0 AKWF source tables.
// Eight explicit Gowin pROMs avoid inferred-register expansion and preserve
// the one-clock read contract consumed by oscillator_bank's TDM pipeline.
`default_nettype none
module wavetable_bank #(
    parameter integer TIMBRE_N = 4,
    parameter integer TIMBRE_W = 2,
    parameter integer DEPTH = 1024,
    parameter integer SAMPLE_W = 16
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire rd_en_i,
    input wire [TIMBRE_W-1:0] timbre_i,
    input wire [$clog2(DEPTH)-1:0] addr_i,
    output wire signed [SAMPLE_W-1:0] sample_soft_o,
    output wire signed [SAMPLE_W-1:0] sample_hard_o,
    output reg valid_o
);
{chr(10).join(wire_lines)}

{chr(10).join(instance_blocks)}

    reg [TIMBRE_W-1:0] timbre_q;
    reg [15:0] rom_soft_sel;
    reg [15:0] rom_hard_sel;
    always @(*) begin
        case (timbre_q)
            2'd0: begin rom_soft_sel = rom_soft_t0_inst_do; rom_hard_sel = rom_hard_t0_inst_do; end
            2'd1: begin rom_soft_sel = rom_soft_t1_inst_do; rom_hard_sel = rom_hard_t1_inst_do; end
            2'd2: begin rom_soft_sel = rom_soft_t2_inst_do; rom_hard_sel = rom_hard_t2_inst_do; end
            default: begin rom_soft_sel = rom_soft_t3_inst_do; rom_hard_sel = rom_hard_t3_inst_do; end
        endcase
    end

    // READ_MODE=0 already registers each word.  timbre_q is the matching
    // one-clock response tag; selecting with the live request timbre would
    // pair every ROM response with the following TDM lane.
    assign sample_soft_o = rom_soft_sel;
    assign sample_hard_o = rom_hard_sel;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_o  <= 1'b0;
            timbre_q <= {{TIMBRE_W{{1'b0}}}};
        end else begin
            valid_o <= rd_en_i;
            if (rd_en_i)
                timbre_q <= timbre_i;
        end
    end

    initial begin
        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
            (DEPTH != 1024) || (SAMPLE_W != 16))
            $display("ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
    end
endmodule
`default_nettype wire
'''


def render_metadata(tables):
    lines = ["generator=tools/gen_t31b_wavetable.py",
             "format=gowin_prom_init_parameters",
             f"depth_per_table={DEPTH}",
             "timbre_ids=0:BASS,1:GUITAR,2:PIANO,3:PAD",
             "source=assets/third_party/akwf/SOURCES.md (AKWF-FREE, CC0-1.0)",
             "soft_generation=periodic_5tap_lowpass_3passes_then_normalize",
             "resampling=offline_periodic_linear_256_to_1024",
             "velocity_mapping=soft_hard_linear_interpolation_in_oscillator_bank"]
    for name, filename, (soft, hard) in zip(TIMBRES, AKWF_SOURCES, tables):
        lines.extend((f"{name}.source={filename}",
                      f"{name}.soft.sum={sum(soft)}", f"{name}.hard.sum={sum(hard)}",
                      f"{name}.hard.min={min(hard)}", f"{name}.hard.max={max(hard)}"))
    return "\n".join(lines) + "\n"


def write_if_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    path.write_text(content, encoding="utf-8", newline="\n")
    return True


def main():
    tables = generate_tables()
    for name, (soft, hard) in zip(TIMBRES, tables):
        validate_table(f"{name}.soft", soft)
        validate_table(f"{name}.hard", hard)
    for path, content in ((RTL_PATH, render_rtl(tables)),
                          (METADATA_PATH, render_metadata(tables))):
        state = "written" if write_if_changed(path, content) else "unchanged"
        print(f"{state}: {path.relative_to(REPO_ROOT)}")
    print("PASS: generated T31b embedded four-timbre soft/hard wavetable bank")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
