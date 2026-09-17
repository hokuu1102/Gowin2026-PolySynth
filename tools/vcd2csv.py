#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""VCD → CSV：把 `$dumpvars` 波形里的指定信号抽成 CSV（供 `csv_fft`/`peak_count`/Python 分析）。

为什么需要它：
    仿真是本项目**没有系统板期间的主验收手段**，而"验收证据"的形态是 CSV / 频谱 / 统计表
    （见 `files/20-代码/仿真与验证方案.md` 三条铁律）。
    VCD 是二进制波形，人看不了、Python 也读不了 —— 这个脚本是"波形 → 可分析数据"的唯一入口。

三种抽取模式（默认第一种）
    ① 逐变化导出（默认）：把信号每次取值变化导成一行 —— 忠实、不丢信息，适合查时序/位翻转
    ② `--fs HZ`：按固定采样率**重采样**成等间隔样点（音频样点流就用这个）
    ③ `--on SIGNAL --edge rising`：**在另一个信号的边沿上采样**（例如在 `tick_audio`/`valid`
       的上升沿取音频样点）—— 这比"猜采样率"可靠

用法
    # 音频样点流（等间隔）
    python tools/vcd2csv.py sim/evidence/x.vcd --signal "tb.dut.sample" --fs 48828.125 \\
           -o sim/evidence/sample.csv

    # 在 valid 的上升沿取样点（推荐：采样时刻由设计自己给出，不用猜）
    python tools/vcd2csv.py x.vcd --signal sample --on tick_audio --edge rising -o s.csv

    # 只导出变化（查时序）
    python tools/vcd2csv.py x.vcd --signal tlc_sdi -o sdi.csv

    # 自检（不需要任何输入文件，内置一个小 VCD 自证）
    python tools/vcd2csv.py --selftest

输出 CSV 约定（四个脚本统一，见 `tools/_samples.py`）
    `#` 开头的是注释行；数据列默认 `time_s,value`（`--raw` 时只输出 value 一列）。
    X/Z 取值原样写成 `x` / `z`，并在报告里计数（⛔ 不会被静默丢掉）。

退出码：0 = 正常；1 = 有问题（找不到信号 / 没有数据 / 自检不过）；2 = 环境缺依赖
"""

from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _samples as S  # noqa: E402

RE_VAR = re.compile(
    r"\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+(\S+)\s*(?:\$end)?"
)
RE_SCOPE = re.compile(r"\$scope\s+(\w+)\s+(\S+)\s*(?:\$end)?")
RE_VECTOR = re.compile(r"^[bB]([01xzXZ]+)\s+(\S+)$")
RE_SCALAR = re.compile(r"^([01xzXZ])(\S+)$")


class VcdSignal:
    def __init__(self, ident: str, name: str, width: int):
        self.ident = ident
        self.name = name
        self.width = width
        self.changes: list[tuple[int, str]] = []   # (time, 二进制串/标量)


def parse_header(path: str):
    """扫头部，返回 (信号表, id 反查表, timescale)。

    · 信号表：{完整层次名: VcdSignal}
    · id 反查：{VCD 里的 id: VcdSignal}
    · 层次名由 `$scope`/`$upscope` 栈拼出（例：`tb.dut.sample`），便于按名字精确选取。
    """
    sigs: dict[str, VcdSignal] = {}
    by_id: dict[str, VcdSignal] = {}
    scope: list[str] = []
    ts_unit = "1ns"

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("$timescale"):
                m = re.search(r"\$timescale\s+(\S+)", line)
                if m:
                    ts_unit = m.group(1)
                continue
            if line.startswith("$scope"):
                m = RE_SCOPE.match(line)
                if m:
                    scope.append(m.group(2))
                continue
            if line.startswith("$upscope"):
                if scope:
                    scope.pop()
                continue
            if line.startswith("$var"):
                m = RE_VAR.match(line)
                if m:
                    _, width, ident, ref = m.groups()
                    full = ".".join(scope + [ref.lstrip("\\")])
                    sig = VcdSignal(ident, full, int(width))
                    sigs[full] = sig
                    by_id[ident] = sig
                continue
            if line.startswith("$enddefinitions"):
                break
    return sigs, by_id, ts_unit


def collect(path: str, want: dict[str, VcdSignal]) -> None:
    """第二遍：只收集需要的信号（`want` = {VCD id: VcdSignal}）的取值变化。

    为什么只收需要的：一个音频仿真的 VCD 动辄几十 MB，全量建表既慢又占内存；
    头部已经告诉我们目标信号的 id，第二遍只挑那几条即可。
    """
    cur = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line[0] == "#":
                try:
                    cur = int(line[1:])
                except ValueError:
                    pass
                continue
            if line[0] == "$":
                continue
            m = RE_VECTOR.match(line)
            if m:
                bits, ident = m.groups()
                rec = want.get(ident)
                if rec is not None:
                    rec.changes.append((cur, bits.lower()))
                continue
            m = RE_SCALAR.match(line)
            if m:
                val, ident = m.groups()
                rec = want.get(ident)
                if rec is not None:
                    rec.changes.append((cur, val.lower()))


def to_int(bits: str):
    """二进制串 → int；含 x/z 时返回 None。"""
    if any(c in bits for c in "xz"):
        return None
    return int(bits, 2) if bits else 0


def value_at(changes: list[tuple[int, str]], t: int, idx: list[int]):
    """在已排序的变化表上取 t 时刻的值（idx 是单元素可变游标，摊还 O(1)）。"""
    i = idx[0]
    while i + 1 < len(changes) and changes[i + 1][0] <= t:
        i += 1
    idx[0] = i
    return changes[i][1] if changes else "x"


def fmt(val: str, width: int) -> str:
    v = to_int(val)
    return str(v) if v is not None else val          # x/z 原样保留


def select_signal(sigs: dict[str, VcdSignal], by_id: dict[str, VcdSignal], name: str):
    """按层次名匹配：先精确，再后缀匹配；--signal 也可直接给 VCD 的 id。"""
    if name in sigs:
        return sigs[name]
    if name in by_id:
        return by_id[name]
    hits = [s for k, s in sigs.items() if k == name or k.endswith("." + name)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        print(f"❌ 找不到信号 {name!r}")
        print("   可用信号（前 20 个）：")
        for k in sorted(sigs)[:20]:
            print(f"     {k}   [{sigs[k].width} bit]")
        return None
    print(f"❌ 信号名 {name!r} 匹配到多个，请写全层次名：")
    for s in hits:
        print(f"     {s.name}")
    return None


def write_out(rows: list[str], out_path: str | None, header: str) -> None:
    lines = [f"# {header}"] + rows
    if out_path:
        S.write_csv(out_path, lines)          # ⭐ UTF-8 with BOM，见 _samples.write_csv
        print(f"✅ 已写出 {out_path}（{len(rows)} 行）")
    else:
        sys.stdout.write("\n".join(lines) + "\n")


# ─────────────────────────── 自检 ───────────────────────────
SELFTEST_VCD = """$date today $end
$timescale 1ns $end
$scope module tb $end
$var wire 1 ! tick $end
$var wire 8 " sample $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
b00000000 "
0!
$end
#10
1!
b00000001 "
#20
0!
#30
1!
b00000010 "
#40
0!
#50
1!
b00000011 "
#60
0!
#70
1!
b11111111 "
#80
0!
"""


def selftest(tmpdir: str) -> int:
    S.banner("vcd2csv 自检（内置一个小 VCD，不需要外部输入）")
    v = S.Verdict("vcd2csv 自检")
    path = os.path.join(tmpdir, "selftest.vcd")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(SELFTEST_VCD)

    sigs, by_id, ts = parse_header(path)
    v.info(f"解析到 {len(sigs)} 个信号，timescale={ts}")
    v.check("sample" in " ".join(sigs), "头部解析出 sample")
    v.check(len(sigs) == 2, "信号数量正确（tick + sample）")

    # ① 在 tick 的上升沿采样
    tick = select_signal(sigs, by_id, "tick")
    smp = select_signal(sigs, by_id, "sample")
    collect(path, {tick.ident: tick, smp.ident: smp})
    rising = [(t, val) for (t, val) in tick.changes if val == "1"]
    got = []
    for t, _ in rising:
        idx = [0]
        got.append(to_int(value_at(smp.changes, t, idx)))
    v.check(got == [1, 2, 3, 255], "在 tick 上升沿取到 [1,2,3,255]", f"实际 {got}")

    # ② 按固定采样率重采样（周期 20ns → 1/20ns = 50 MHz）
    #    ⚠️ 循环变量别叫 v —— 上面 v 是 Verdict 对象，覆盖了会在下一行 `.check` 崩
    rows = []
    for k in range(5):
        idx = [0]
        t = k * 20
        val = to_int(value_at(smp.changes, t, idx))
        rows.append(val if val is not None else -1)
    v.check(rows == [0, 1, 2, 3, 255], "按 20ns 等间隔重采样得到 [0,1,2,3,255]", f"实际 {rows}")

    # ③ X/Z 不能被静默丢掉
    v.check(fmt("xxxx", 4) == "xxxx", "X 取值原样保留（不静默丢）")

    return v.finish()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把 VCD 里的指定信号抽成 CSV",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("vcd", nargs="?", help="输入 .vcd")
    ap.add_argument("--signal", "-s", help="信号名（可写层次名 tb.dut.sample，也可写 VCD id）")
    ap.add_argument("--on", help="在另一个信号的边沿上采样（推荐）")
    ap.add_argument("--edge", default="rising", choices=["rising", "falling", "any"],
                    help="配合 --on（默认 rising）")
    ap.add_argument("--fs", type=float, help="等间隔重采样率 Hz")
    ap.add_argument("--t0", type=float, default=None, help="起始时刻（秒）")
    ap.add_argument("--t1", type=float, default=None, help="结束时刻（秒）")
    ap.add_argument("--limit", type=int, default=0, help="最多导出多少个样点（0 = 不限）")
    ap.add_argument("--decimate", type=int, default=1, help="每 N 个样点取 1 个")
    ap.add_argument("--width", type=int, default=0,
                    help="强制位宽（默认用 VCD 里的）；用于把无符号值转成有符号输出")
    ap.add_argument("--signed", action="store_true", help="按位宽做二补码转换（输出有符号）")
    ap.add_argument("-o", "--out", help="输出 CSV（默认写到 stdout）")
    ap.add_argument("--raw", action="store_true", help="只输出 value 一列（不带 time_s）")
    ap.add_argument("--selftest", action="store_true", help="跑内置自检（不需要输入文件）")
    args = ap.parse_args()

    if args.selftest:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return selftest(td)

    if not args.vcd or not args.signal:
        ap.print_help()
        print("\n❌ 需要给 --signal（以及输入 .vcd）")
        return 1
    if not os.path.isfile(args.vcd):
        print(f"❌ 找不到 {args.vcd}")
        return 1

    sigs, by_id, ts = parse_header(args.vcd)
    if not sigs:
        print("❌ 这个文件里没有解析到任何 $var（不是 VCD？或是空文件？）")
        return 1

    # VCD 的时间单位 → 秒
    unit_scale = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}
    m = re.match(r"(\d+)\s*([a-z]+)", ts)
    tick_s = (int(m.group(1)) * unit_scale.get(m.group(2), 1e-9)) if m else 1e-9

    tgt = select_signal(sigs, by_id, args.signal)
    if tgt is None:
        return 1

    want = {tgt.ident: tgt}
    on_sig = None
    if args.on:
        on_sig = select_signal(sigs, by_id, args.on)
        if on_sig is None:
            return 1
        want[on_sig.ident] = on_sig
    collect(args.vcd, want)

    if not tgt.changes:
        print(f"❌ 信号 {tgt.name} 在整个 VCD 里没有任何取值变化")
        return 1

    width = args.width or tgt.width
    t0 = int(round(args.t0 / tick_s)) if args.t0 is not None else tgt.changes[0][0]
    t1 = int(round(args.t1 / tick_s)) if args.t1 is not None else tgt.changes[-1][0]

    rows: list[str] = []
    xs = 0

    def emit(t: int, val: str) -> None:
        nonlocal xs
        v = to_int(val)
        if v is None:
            xs += 1
            out = val
        else:
            if args.signed and v >= (1 << (width - 1)):
                v -= (1 << width)
            out = str(v)
        rows.append(f"{t * tick_s:.12g},{out}" if not args.raw else out)

    if on_sig is not None:
        want_edge = {"rising": "1", "falling": "0"}.get(args.edge)   # any → None
        idx = [0]
        for t, val in on_sig.changes:
            if t < t0 or t > t1:
                continue
            if want_edge is not None and val != want_edge:
                continue
            emit(t, value_at(tgt.changes, t, idx))
        mode = (f"在 {on_sig.name} 的 {args.edge} 边沿采样" if want_edge is not None
                else f"在 {on_sig.name} 的任意变化时采样")
    elif args.fs:
        step = max(1, int(round(1.0 / (args.fs * tick_s))))
        idx = [0]
        t = t0
        while t <= t1:
            emit(t, value_at(tgt.changes, t, idx))
            t += step
        mode = f"按 {args.fs:g} Hz 重采样（每 {step} 个时间单位）"
    else:
        for t, val in tgt.changes:
            if t < t0 or t > t1:
                continue
            emit(t, val)
        mode = "逐取值变化导出"

    if args.decimate > 1:
        rows = rows[::args.decimate]
    if args.limit > 0:
        rows = rows[:args.limit]

    header = (f"vcd2csv {os.path.basename(args.vcd)} signal={tgt.name} "
              f"width={tgt.width} mode={mode}")
    write_out(rows, args.out, header)

    print(f"   信号 {tgt.name} [{tgt.width} bit] · {mode}")
    print(f"   时间窗 {t0 * tick_s:.9g}s ~ {t1 * tick_s:.9g}s（timescale {ts}）")
    print(f"   导出 {len(rows)} 行" + (f" · ⚠️ 含 {xs} 个 X/Z 采样点" if xs else ""))
    if len(rows) < 8:
        print("   ⚠️ 样点太少（<8）—— 后面做 FFT 会没有意义，检查 --signal/--t0/--t1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
