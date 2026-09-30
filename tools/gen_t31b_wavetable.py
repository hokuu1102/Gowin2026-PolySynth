#!/usr/bin/env python3
"""Generate the embedded T31b four-timbre soft/hard wavetable ROM."""

from pathlib import Path
import math
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


def generate_test_sine():
    """Dedicated PURE-SINE table for Test Mode (M4 FFT peak counting).

    The four AKWF timbres are harmonically rich.  If Test Mode borrowed one of
    them, its harmonics would be counted as extra spectral peaks and the M4
    acceptance (`sim/test_mode_fft.ps1`, expects exactly 4/8/16/32) would go
    red.  Test Mode is a MEASUREMENT mode, so it gets its own clean source.
    """
    samples = [int(round(AMPLITUDE * math.sin(2.0 * math.pi * index / DEPTH)))
               for index in range(DEPTH)]
    return normalize_zero_dc(samples, AMPLITUDE)


#  ⭐⭐ 噪声表的固定种子（⭐ 2026-09-29 新增，⭐ 鼓机专用）
#   ⭐ 为什么必须固定：⭐ 表内容要**可复现** —— ⛔ 否则每次重生成都改 RTL，
#      ⇒ ⭐ `git diff` 全是噪声（字面意义），⭐ 且"仿真表 == 上板表"这条不变式失效。
NOISE_SEED = 0x5EED2026


def _xorshift32(state):
    """Deterministic 32-bit xorshift PRNG (⭐ 固定种子 ⇒ 表内容逐字节可复现)."""
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= state >> 17
    state ^= (state << 5) & 0xFFFFFFFF
    return state & 0xFFFFFFFF


def generate_noise_table():
    """Single-cycle PSEUDO-RANDOM (broadband) table for the drum voices.

    ⭐⭐ 为什么鼓机需要它（⭐ 本表存在的唯一理由）：
       ⭐ 鼓机（`rtl/w3c/drum_gen.v`）的 4 件乐器**共用同一个 `AXIS_ID`**，
          只靠 `PHASE_INC`（音高）区分 ⇒ 🔴 全部走**同一张谐波丰富的乐音表**
          ⇒ ⭐ 听感是"**音高不同的节拍器嘀嗒**"，⛔ 不是鼓。
       ⭐ 真实鼓（hi-hat / snare / clap）的能量主体是**噪声** ⇒
          最省的第一步就是给它们一张**宽带噪声表**（⛔ 不加任何新音频通路）。

    ⭐⭐ 为什么用【频域合成】而⛔ 不是"时域直接填随机数"：
       ⭐ 表是**单周期循环**的（1024 点，环路频率由 `PHASE_INC` 决定）⇒
          ⚠️ 时域直接填随机数 ⇒ 🔴 **环绕处（`s[1023] → s[0]`）大概率是一个大台阶**
          ⇒ 🔴 该台阶的能量**摊到所有谐波**（含低频）⇒ ⭐ 每圈一次的"咔哒"嗡声。
       ⭐ 本表取 **1..512 号整数谐波 × 随机相位 × 等幅** ⇒
          ① ⭐ **天然周期安全**：⭐ 每一项都是**整周期**的 ⇒
             ⭐ 环绕处与表内任意处**同分布**（⭐ 不存在"离群台阶"）
          ② ⭐ **天然零直流**（⭐ 不含 0 号谐波）
          ③ ⭐ **等幅 ⇒ 平坦谱 ⇒ 宽带**（⭐ 时域近似高斯白噪声，
             ⭐ 相邻样本相关系数 ≈ `-2/512 ≈ 0`）
    """
    state = NOISE_SEED
    phases = []
    for _ in range(DEPTH // 2):
        state = _xorshift32(state)
        phases.append(2.0 * math.pi * state / 4294967296.0)
    samples = []
    for index in range(DEPTH):
        total = 0.0
        for harmonic in range(1, DEPTH // 2 + 1):
            total += math.sin(2.0 * math.pi * harmonic * index / DEPTH
                              + phases[harmonic - 1])
        samples.append(int(round(total)))
    return normalize_zero_dc(samples, AMPLITUDE)


def zero_crossings(samples):
    """Sign changes around the cyclic table (⭐ 宽带性的时域判据)."""
    return sum(1 for index in range(len(samples))
               if (samples[index] < 0) != (samples[(index + 1) % len(samples)] < 0))


def validate_noise_periodic(name, samples):
    """⭐ 周期性安全：环绕处的一阶差分⛔ 不得大于表内最大的一阶差分。"""
    steps = [abs(samples[index + 1] - samples[index])
             for index in range(len(samples) - 1)]
    wrap = abs(samples[0] - samples[-1])
    if wrap > max(steps):
        raise ValueError(f"{name}: wrap step {wrap} exceeds the largest interior step {max(steps)}")
    return wrap, max(steps)


def validate_table(name, samples):
    if len(samples) != DEPTH:
        raise ValueError(f"{name}: wrong depth")
    if min(samples) < -32768 or max(samples) > 32767:
        raise ValueError(f"{name}: signed-16 range exceeded")
    if sum(samples) != 0:
        raise ValueError(f"{name}: DC sum must be zero, got {sum(samples)}")


def render_prom_instance(stem, samples):
    """Render one Gowin 1024x16 pROM with deterministic INIT parameters."""
    lines = [
        f"    pROM {stem} (",
        f"        .DO({{{stem}_dout_w[15:0], {stem}_do[15:0]}}),",
        "        .CLK(clk_i),",
        "        .OCE(1'b1),",
        "        .CE(rd_en_i),",
        "        .RESET(~rst_n_i),",
        "        .AD({addr_i[9:0], 4'b0000})",
        "    );",
        #  ⭐⭐ 2026-09-29 合并（⭐ 队友 `t31b-final-6db-s2`）：⭐ **`READ_MODE` 必须是 0** ✅
        #   ⭐ Gowin 官方 gw5a 原语模型：⭐ `0`（bypass）= **BRAM 自带的那级读寄存 = 1 拍** ✅
        #      ⭐ `1`（pipeline）= **再加一级输出寄存 = 2 拍** 🔴
        #   ⇒ ⭐ `oscillator_bank` 的 TDM 响应标签**只延 1 拍** ⇒ ⭐ **必须用 0** ✅
        #   ⚠️ 用 1 会让每条 lane 配到**下一条 lane 的数据** ⇒ 🔴 车道错位/瞬态尖峰 ✅
        #   📌 佐证：⭐ **Gowin 自家 IP 生成器的 ROM 输出就用 `READ_MODE = 1'b0`** ✅
        #      （⭐ `ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:34` ✅）
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


def render_rtl(tables, test_sine, noise):
    wire_lines = []
    instance_blocks = []
    for timbre, (soft, hard) in enumerate(tables):
        for kind, samples in (("soft", soft), ("hard", hard)):
            stem = f"rom_{kind}_t{timbre}_inst"
            wire_lines.extend((f"    wire [15:0] {stem}_do;",
                               f"    wire [15:0] {stem}_dout_w;"))
            instance_blocks.append(render_prom_instance(stem, samples))
    test_stem = "rom_test_sine_inst"
    wire_lines.extend((f"    wire [15:0] {test_stem}_do;",
                       f"    wire [15:0] {test_stem}_dout_w;"))
    instance_blocks.append(render_prom_instance(test_stem, test_sine))
    #  ⭐⭐ 第 10 个 pROM：⭐ **鼓机专用的宽带噪声表**（⭐ 2026-09-29 新增）
    #   ⭐ 与 `rom_test_sine_inst` 同一套路：⭐ **与 4 个乐音音色【解耦】** ——
    #      ⭐ 以后换任何乐音表都**不会**连带改掉鼓的音色 ✅
    noise_stem = "rom_noise_inst"
    wire_lines.extend((f"    wire [15:0] {noise_stem}_do;",
                       f"    wire [15:0] {noise_stem}_dout_w;"))
    instance_blocks.append(render_prom_instance(noise_stem, noise))

    return f'''`timescale 1ns/1ps
// T31b generated ROM: 4 timbres x 1024 points x soft/hard, all embedded.
// IDs: 0=BASS, 1=GUITAR, 2=PIANO, 3=PAD; CC0 AKWF source tables.
// Ten explicit Gowin pROMs avoid inferred-register expansion and preserve
// the one-clock read contract consumed by oscillator_bank's TDM pipeline.
// The ninth ROM (`rom_test_sine_inst`) is a PURE SINE used only by Test Mode:
// the four AKWF timbres are harmonically rich, and Test Mode's M4 acceptance
// counts spectral peaks (exactly 4/8/16/32, tools/peak_count.py), so it must
// never borrow a rich table.
// The tenth ROM (`rom_noise_inst`) is a single-cycle PSEUDO-RANDOM broadband
// table used only by the drum voices: the drum machine separates its four
// instruments by pitch alone, so without a noise source every hit is a pitched
// tick.  It is synthesised from integer harmonics with random phases, which
// makes it exactly periodic (no wrap step) and DC-free by construction.
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
    output wire signed [SAMPLE_W-1:0] sample_test_o,
    output wire signed [SAMPLE_W-1:0] sample_noise_o,
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

    // READ_MODE=1 (Register) gives 1-clock read latency, matching
    // oscillator_bank's "ROM data returns 1 beat after the address" contract.
    // READ_MODE=0 (By-pass) returns data in the SAME beat and shifts every
    // TDM lane by one -> inter-lane data scramble -> transient spikes.
    // timbre_q is the matching
    // one-clock response tag; selecting with the live request timbre would
    // pair every ROM response with the following TDM lane.
    assign sample_soft_o = rom_soft_sel;
    assign sample_hard_o = rom_hard_sel;
    // Timbre-independent PURE sine: Test Mode's measurement source.
    assign sample_test_o = rom_test_sine_inst_do;
    //  ⭐⭐ Timbre-independent PSEUDO-RANDOM table: the **drum voices' noise source**.
    //   ⭐ 谁用它：⭐ `oscillator_bank` 对"保留轴位 voice"（`axis_r[i] >= RESERVED_AXIS`）
    //      **改选本表**（⭐ 见 `oscillator_bank.voice_drum_i`）✅
    //   ⭐ 为什么放这里而⛔ 不放 oscillator_bank：⭐ 与其余 9 张表**同源同拍** ——
    //      共用同一个 `clk_i` / `rd_en_i` / `addr_i` ⇒ ⭐ **1 拍读延迟自动对齐**，
    //      ⛔ 不需要在 `oscillator_bank` 里再加任何时序假设 ✅
    assign sample_noise_o = rom_noise_inst_do;

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


def render_metadata(tables, test_sine, noise):
    lines = ["generator=tools/gen_t31b_wavetable.py",
             "format=gowin_prom_init_parameters",
             f"depth_per_table={DEPTH}",
             "timbre_ids=0:BASS,1:GUITAR,2:PIANO,3:PAD",
             "source=assets/third_party/akwf/SOURCES.md (AKWF-FREE, CC0-1.0)",
             "soft_generation=periodic_5tap_lowpass_3passes_then_normalize",
             "resampling=offline_periodic_linear_256_to_1024",
             "velocity_mapping=soft_hard_linear_interpolation_in_oscillator_bank",
             "test_mode_source=rom_test_sine_inst (dedicated PURE sine, timbre-independent)",
             "drum_source=rom_noise_inst (dedicated single-cycle pseudo-random table, drum voices only)",
             f"noise_seed=0x{NOISE_SEED:08X}",
             "noise_generation=integer_harmonics_1_to_512_equal_amplitude_random_phase_then_normalize",
             f"test_sine.sum={sum(test_sine)}",
             f"test_sine.min={min(test_sine)}", f"test_sine.max={max(test_sine)}",
             f"noise.sum={sum(noise)}",
             f"noise.min={min(noise)}", f"noise.max={max(noise)}"]
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
    test_sine = generate_test_sine()
    noise = generate_noise_table()
    for name, (soft, hard) in zip(TIMBRES, tables):
        validate_table(f"{name}.soft", soft)
        validate_table(f"{name}.hard", hard)
    validate_table("TEST_SINE", test_sine)
    validate_table("NOISE", noise)
    wrap_step, max_step = validate_noise_periodic("NOISE", noise)
    #  ⭐ 统计量打印（⭐ 验收 tb 的门限就从这里取 ⇒ ⛔ 不用手算）
    print(f"NOISE  len={len(noise)} sum={sum(noise)} "
          f"min={min(noise)} max={max(noise)} "
          f"zcr={zero_crossings(noise)} (sine zcr={zero_crossings(test_sine)}) "
          f"wrap_step={wrap_step} max_interior_step={max_step}")
    for path, content in ((RTL_PATH, render_rtl(tables, test_sine, noise)),
                          (METADATA_PATH, render_metadata(tables, test_sine, noise))):
        state = "written" if write_if_changed(path, content) else "unchanged"
        print(f"{state}: {path.relative_to(REPO_ROOT)}")
    print("PASS: generated T31b embedded four-timbre soft/hard wavetable bank")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
