#!/usr/bin/env python3
"""Generate the embedded T31b four-timbre soft/hard wavetable ROM."""

from pathlib import Path
import math
import sys

DEPTH = 1024
SAMPLE_W = 16
AMPLITUDE = 32767
TIMBRES = ("BASS", "GUITAR", "PIANO", "PAD")
REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_PATH = REPO_ROOT / "rtl" / "w3b" / "wavetable_bank.v"
METADATA_PATH = REPO_ROOT / "evidence" / "w1_2" / "wavetable_t31b_metadata.txt"


def sine_half(amplitude):
    first = [int(round(amplitude * math.sin(2.0 * math.pi * n / DEPTH)))
             for n in range(DEPTH // 2)]
    return first + [-value for value in first]


def triangle():
    first = []
    for n in range(DEPTH // 2):
        if n <= DEPTH // 4:
            value = (AMPLITUDE * n) // (DEPTH // 4)
        else:
            value = (AMPLITUDE * (DEPTH // 2 - n)) // (DEPTH // 4)
        first.append(value)
    return first + [-value for value in first]


def saw():
    first = [-AMPLITUDE + ((2 * AMPLITUDE * n) // (DEPTH // 2))
             for n in range(DEPTH // 2)]
    return first + [-value for value in first]


def pulse_25_percent_zero_dc():
    # 256 * 32766 + 768 * -10922 == 0: 25% duty with no DC component.
    return [32766 if n < DEPTH // 4 else -10922 for n in range(DEPTH)]


def pad():
    raw = []
    for n in range(DEPTH // 2):
        phase = 2.0 * math.pi * n / DEPTH
        raw.append(math.sin(phase) + 0.55 * math.sin(2 * phase)
                   + 0.30 * math.sin(3 * phase) + 0.18 * math.sin(4 * phase)
                   + 0.10 * math.sin(5 * phase))
    peak = max(abs(value) for value in raw)
    first = [int(round(AMPLITUDE * value / peak)) for value in raw]
    return first + [-value for value in first]


def generate_tables():
    soft = sine_half(16384)
    hard = (triangle(), saw(), pulse_25_percent_zero_dc(), pad())
    return [(soft, table) for table in hard]


def validate_table(name, samples):
    if len(samples) != DEPTH:
        raise ValueError(f"{name}: wrong depth")
    if min(samples) < -32768 or max(samples) > 32767:
        raise ValueError(f"{name}: signed-16 range exceeded")
    if sum(samples) != 0:
        raise ValueError(f"{name}: DC sum must be zero, got {sum(samples)}")


def render_assignments(tables):
    lines = []
    for timbre, (soft, hard) in enumerate(tables):
        for addr, value in enumerate(soft):
            literal = f"-16'sd{-value}" if value < 0 else f"16'sd{value}"
            lines.append(f"        rom_soft[{timbre * DEPTH + addr}] = {literal};")
        for addr, value in enumerate(hard):
            literal = f"-16'sd{-value}" if value < 0 else f"16'sd{value}"
            lines.append(f"        rom_hard[{timbre * DEPTH + addr}] = {literal};")
    return "\n".join(lines)


def render_rtl(tables):
    return f'''`timescale 1ns/1ps
// T31b generated ROM: 4 timbres x 1024 points x soft/hard, all embedded.
// IDs: 0=BASS triangle, 1=GUITAR saw, 2=PIANO zero-DC 25% pulse, 3=PAD.
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
    output reg signed [SAMPLE_W-1:0] sample_soft_o,
    output reg signed [SAMPLE_W-1:0] sample_hard_o,
    output reg valid_o
);
    localparam integer ROM_DEPTH = TIMBRE_N * DEPTH;
    reg signed [SAMPLE_W-1:0] rom_soft [0:ROM_DEPTH-1];
    reg signed [SAMPLE_W-1:0] rom_hard [0:ROM_DEPTH-1];
    wire [$clog2(ROM_DEPTH)-1:0] rom_addr = {{timbre_i, addr_i}};

    initial begin
{render_assignments(tables)}
    end

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            sample_soft_o <= {{SAMPLE_W{{1'b0}}}};
            sample_hard_o <= {{SAMPLE_W{{1'b0}}}};
            valid_o       <= 1'b0;
        end else begin
            valid_o <= rd_en_i;
            if (rd_en_i) begin
                sample_soft_o <= rom_soft[rom_addr];
                sample_hard_o <= rom_hard[rom_addr];
            end
        end
    end
endmodule
`default_nettype wire
'''


def render_metadata(tables):
    lines = ["generator=tools/gen_t31b_wavetable.py",
             "format=embedded_verilog_constants",
             f"depth_per_table={DEPTH}",
             "timbre_ids=0:BASS,1:GUITAR,2:PIANO,3:PAD",
             "velocity_mapping=soft_hard_linear_interpolation_in_oscillator_bank"]
    for name, (soft, hard) in zip(TIMBRES, tables):
        lines.extend((f"{name}.soft.sum={sum(soft)}", f"{name}.hard.sum={sum(hard)}",
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
