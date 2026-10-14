#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""⭐⭐ 端到端离线验证：⭐ 合成上行字节 → **跑真 CLI** → 转出 `.mid` → **按规范读回**逐项核对。

═══ 为什么必须"读回" ═══
🔴 只检查文件头 `MThd` 是**假绿** —— ⚠️ 文件可以头对、内容全错
   （⭐ 音高错、力度错、时间轴整体偏移 —— ⭐ 头都还是对的）。
⇒ ⭐ 判据 = **按 MIDI 规范把事件读回来**，再逐项比对 音高 / 力度 / 时序。

═══ 与 `evt2midi.py --selftest` 的分工 ═══
   · `--selftest`     ⭐ 单元级（⭐ 每条判据只碰一小块）
   · **本脚本**       ⭐⭐ **整链路**（⭐ 真的起子进程跑 CLI、真的落盘、真的从盘上读回）
⇒ ⭐ 它验的是"**这三件事连起来**还对" —— ⚠️ 单元全绿⛔ 不等于整链路对。

═══ 覆盖的场景（⭐ 全部是实测过的风险点）═══
  ① 正常音符（音高 / 力度 / 时序逐项核对）
  ② ⭐ **32 位 tick 跨回绕**（⭐ 而且跨【第二次】回绕 —— 87 秒处）
  ③ ⭐ **坏帧（校验错 / 未知类型 / 半帧截断）必须被拒收并计数**，⛔ 不许伪装成合理值
  ④ ⭐ **表同步帧（68 B）⛔ 不得被当成 14 B 音符帧切开**
  ⑤ ⭐ **`inc = 0` 的事件跳过并计数**（⛔ 不猜音高）
  ⑥ ⭐ 混合 ASCII 事件 ⛔ 不得干扰帧解析

⚠️ 合成时**必须保证事件按 tick 升序** —— ⭐ 否则测的是"乱序"，⛔ 不是时间轴。

用法：
    python _e2e_check.py            # 用临时目录
    python _e2e_check.py --keep     # 保留产物并打印路径（⭐ 便于人工播放）
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

import evt2midi as E                                 # noqa: E402
from midi_verify import notes_of, read_midi_file     # noqa: E402

CLK = E.CLK_HZ
TWO32 = 1 << 32
BPM = 120.0
T0 = TWO32 - 50_000_000                 # ⭐ 回绕前 1.0 秒（⭐ 基准 tick）
OFF_VEL = 0x40                          # ⭐ 写侧给 note_off 的固定力度


def tick_at(sec):
    """⭐ 把"物理秒"映射成 32 位 FPGA tick（⚠️ 会自然跨过回绕）。"""
    return (T0 + int(round(sec * CLK))) % TWO32


def inc_for(hz):
    return int(round(hz * TWO32 / CLK))


# ⭐⭐ 时间线：⭐ **物理秒**（⛔ 不用 tick 反推 —— ⭐ 否则就是拿被测代码算期望值）
#    ⚠️ 最后两个音在 **87 秒**处 ⇒ ⭐ 已经跨过【第二次】回绕
#       （⭐ 32 位 @50 MHz ⇒ 85.9 秒一圈 ⇒ ⭐ 真实曲子必然遇到）
#    📌 相邻事件最大间隔 81.5 秒（⭐ < 85.9 秒）⇒ ⭐ 取模后**无歧义**
TIMELINE = [
    # (秒, 事件, 频率, 力度)
    (0.0, "on", 440.00, 200),
    (2.0, "off", 440.00, 200),
    (3.0, "on", 523.25, 220),
    (3.5, "off", 523.25, 220),
    (4.0, "on", 659.25, 240),
    (4.5, "off", 659.25, 240),
    (5.0, "on", 440.00, 180),
    (5.5, "off", 440.00, 180),
    (87.0, "on", 880.00, 160),        # ⭐ 第二次回绕之后
    (87.5, "off", 880.00, 160),
]

# ⚠️ 坏帧 / inc=0 / ASCII 的**插入位置**（⭐ 必须按 tick 升序 —— ⚠️ 否则测的是乱序）
BAD_CSUM_SEC = 2.5                      # 🔴 校验错
BAD_HZ = 987.77                         # ⚠️ 这个频率**只给坏帧用** ⇒ ⭐ 它⛔ 绝不许出现在结果里
UNK_TYPE_SEC = 6.0                      # 🔴 未知类型（⭐ 校验是对的）
INC0_ON_SEC = 3.75                      # ⭐ inc = 0
INC0_OFF_SEC = 4.75                     # ⭐ inc = 0
TRUNC_SEC = 88.0                        # 🔴 半帧截断（⭐ 最末尾）


def build_recording():
    """⭐ 合成一份"录制文件"，⭐ 返回 (字节, 期望 MIDI 事件表, 期望记账, 坏帧音高)。"""
    rec = bytearray()
    seq = [0]

    def nf(kind, sec, hz, vel):
        ft = E.T_NOTE_ON if kind == "on" else E.T_NOTE_OFF
        rec.extend(E._mk_frame(ft, seq[0], tick_at(sec), 0, inc_for(hz), vel))
        seq[0] = (seq[0] + 1) & 0xFF

    # ① ⭐ 表同步帧（68 B）放在最前 —— ⚠️ 若按 14 B 切，整条流从此错位
    rec += E._mk_frame(E.T_TABLESYNC, table=E.TABLESYNC_TABLE_KB,
                       items=[inc_for(440.0)] * E.TABLESYNC_ITEMS)

    # ② ⭐ 严格按 tick 升序铺时间线，⭐ 并把各种"坏东西"插在真实位置上
    nf("on", 0.0, 440.00, 200)
    nf("off", 2.0, 440.00, 200)

    # 🔴 坏帧（校验错）：⭐ 一位翻转 —— ⚠️ 它解出来的值"看起来正常"
    bad = bytearray(E._mk_frame(E.T_NOTE_ON, seq[0], tick_at(BAD_CSUM_SEC),
                                0, inc_for(BAD_HZ), 250))
    bad[12] ^= 0x01                     # ⚠️ 翻 vel 一位 ⇒ 校验必不过
    rec += bytes(bad)
    seq[0] = (seq[0] + 1) & 0xFF
    bad_value = inc_for(BAD_HZ)         # ⭐ 这个音⛔ 绝不许出现在结果里

    nf("on", 3.0, 523.25, 220)
    nf("off", 3.5, 523.25, 220)
    rec += E._mk_frame(E.T_NOTE_ON, seq[0], tick_at(INC0_ON_SEC), 3, 0, 200)
    seq[0] = (seq[0] + 1) & 0xFF
    nf("on", 4.0, 659.25, 240)
    nf("off", 4.5, 659.25, 240)
    rec += E._mk_frame(E.T_NOTE_OFF, seq[0], tick_at(INC0_OFF_SEC), 3, 0, 200)
    seq[0] = (seq[0] + 1) & 0xFF
    nf("on", 5.0, 440.00, 180)
    rec += b"s"                         # ⭐ ASCII 事件（⭐ 与帧交错）
    nf("off", 5.5, 440.00, 180)

    # 🔴 未知类型帧（⭐ 校验【是】对的 ⇒ ⭐ 只能靠类型白名单识别）
    unk = bytearray(bytes([E.FRAME_HDR, 0x7F]) + bytes(12))
    unk[13] = E.frame_checksum(bytes(unk))
    rec += bytes(unk)

    nf("on", 87.0, 880.00, 160)         # ⭐ 第二次回绕之后
    nf("off", 87.5, 880.00, 160)

    # 🔴 半帧截断（⭐ 末尾砍掉 5 字节 ⇒ ⭐ 必须被拒收，⛔ 不许硬猜）
    rec += E._mk_frame(E.T_NOTE_ON, seq[0], tick_at(TRUNC_SEC), 0,
                       inc_for(440.0), 200)[:-5]

    # ---- ⭐ 期望值：⭐ 由【物理秒】独立算出（⛔ 不用 tick 反推）----
    tps = E.PPQN * BPM / 60.0
    expect = []
    for sec, kind, hz, vel in TIMELINE:
        # ⚠️ note_off 的力度是写侧固定的 0x40（⭐ 规范做法），⛔ 不是 (vel+1)//2
        v = OFF_VEL if kind == "off" else (vel + 1) // 2
        expect.append([kind, int(round(sec * tps)), E.hz_to_note(hz), v])

    stats_expect = {
        "frames_ok": len(TIMELINE) + 2 + 1,   # ⭐ 10 音符帧 + 2 个 inc=0 帧 + 1 表帧
        "bad_csum": 1,
        "bad_type": 1,
        "truncated": 1,
        "table_frames": 1,
        "ascii": 1,
    }
    return bytes(rec), expect, stats_expect, bad_value


def run_cli(rec_path, mid_path):
    """⭐ **真的起子进程**跑 CLI（⭐ 这样连 `main()` / argparse 一起验了）。"""
    cmd = [sys.executable, os.path.join(HERE, "evt2midi.py"),
           "--in", rec_path, "--out", mid_path, "--bpm", "120", "--verify"]
    r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=120)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    ap = argparse.ArgumentParser(description="端到端：合成 → CLI → .mid → 读回核对")
    ap.add_argument("--keep", action="store_true", help="保留产物并打印路径")
    args = ap.parse_args()

    print("=" * 74)
    print("端到端：⭐ 合成上行字节 → 跑真 CLI → 转出 .mid → **按规范读回**逐项核对")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-52s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    rec, expect, stats_expect, bad_value = build_recording()
    print("合成录制：%d 字节" % len(rec))

    out_dir = tempfile.mkdtemp(prefix="evt2midi_e2e_")
    rec_path = os.path.join(out_dir, "rec.bin")
    mid_path = os.path.join(out_dir, "song.mid")
    with open(rec_path, "wb") as f:
        f.write(rec)

    print("产物目录：%s" % out_dir)
    print()
    rc, out = run_cli(rec_path, mid_path)
    print("---- CLI 原始输出 ----")
    print(out.rstrip())
    print("----------------------")
    print()

    chk("CLI 退出码 = 0", rc == 0, "  实测 %d" % rc)
    chk("产物 .mid 已落盘", os.path.isfile(mid_path),
        "  %d 字节" % (os.path.getsize(mid_path) if os.path.isfile(mid_path) else -1))

    # ---- ① 记账：⭐ 坏帧必须被计数（⭐ 从 CLI 输出里读）----
    print()
    print("[1] ⭐⭐ 坏帧记账（⭐ 从 CLI 输出核对）")
    chk("  二进制帧 ok = %d（⭐ 含 2 个 inc=0 帧）" % stats_expect["frames_ok"],
        ("二进制帧 ok        = %d" % stats_expect["frames_ok"]) in out)
    chk("  坏校验帧 = %d" % stats_expect["bad_csum"],
        ("🔴 坏校验帧     = %d" % stats_expect["bad_csum"]) in out)
    chk("  未知类型 = %d（⭐ 且⛔ 不计入 ok）" % stats_expect["bad_type"],
        ("🔴 未知类型     = %d" % stats_expect["bad_type"]) in out)
    chk("  半帧/长度不足 = %d" % stats_expect["truncated"],
        ("🔴 半帧/长度不足 = %d" % stats_expect["truncated"]) in out)
    chk("  ⭐ 被拒收合计 = 3（⭐ 判据：⛔ 不是 0）",
        ("🔴 被拒收合计      = %d" % 3) in out)
    chk("  表同步帧 = 1（⭐ ⛔ 没被切成 14 B 假帧）",
        ("⭐ 表同步帧        = %d" % stats_expect["table_frames"]) in out)
    chk("  ASCII 事件 = 1",
        ("ASCII 事件         = %d" % stats_expect["ascii"]) in out)
    chk("  ⛔ 没有未知高位字节（⭐ 说明没错位）",
        "⚠️ 未知高位字节    = 0" in out)
    chk("  ⭐ inc=0 被跳过并计数（2 个）", "其中 inc=0 = 2" in out)
    chk("  ⭐ 表内容被解出（440 Hz）", "inc=37796 (440.0 Hz)" in out)
    # 🔴 这条抓的是"**报告顺序**"这类 bug：⭐ `big_tick_steps` 是在 `build_midi` 里算的
    #    ⇒ ⚠️ 若在 `build_midi` 之前打印，⭐ 它**永远是 0**（🔴 而没人会发现）。
    #    ⭐ 本录制的 5.5 秒 → 87.0 秒之间有 81.5 秒的空档 ⇒ ⭐ 必须被记成 1。
    chk("  ⭐ 单步 Δ>43 秒 = 1（⭐ 抓【报告顺序】bug）",
        "⚠️ 单步 Δ>43 秒    = 1" in out)

    # ---- ② 按 MIDI 规范读回 ----
    print()
    print("[2] ⭐⭐ 按 MIDI 规范读回（⛔ 不是只看 MThd 文件头）")
    res = read_midi_file(mid_path)
    ns = notes_of(res)
    got = [[e["kind"], e["t"], e["note"], e["vel"]] for e in ns]
    chk("  division = %d（PPQN）" % E.PPQN, res["division"] == E.PPQN)
    chk("  tempo 自描述 = 500000 µs（120 BPM）", res["tempo_us"] == 500000,
        "  实测 %s" % res["tempo_us"])
    chk("  ⭐ 音符事件数 = %d（⭐ 坏帧/inc=0 ⛔ 一个都不许进来）" % len(expect),
        len(ns) == len(expect), "  实测 %d" % len(ns))
    chk("  ⭐ 事件序列逐项对（类型/时间/音高/力度）", got == expect)
    if got != expect:
        print("      实为 %s" % got)
        print("      期望 %s" % expect)

    # ---- ③ 逐项明细 ----
    print()
    print("[3] ⭐ 逐项明细")
    chk("  ⭐ 音高 = %s" % [e[2] for e in expect],
        [e["note"] for e in ns] == [e[2] for e in expect],
        "  实为 %s" % [e["note"] for e in ns])
    chk("  ⭐ 力度 = %s" % [e[3] for e in expect],
        [e["vel"] for e in ns] == [e[3] for e in expect],
        "  实为 %s" % [e["vel"] for e in ns])
    chk("  ⭐ 绝对时刻 = %s" % [e[1] for e in expect],
        [e["t"] for e in ns] == [e[1] for e in expect],
        "  实为 %s" % [e["t"] for e in ns])
    # ⭐⭐ 非空洞：⭐ 把"期望"整体挪一位 ⇒ 必须判红（⭐ 证明比对真的在比）
    chk("  ⭐ 非空洞：期望挪一位后比对会失败",
        got != expect[1:] + [expect[0]])

    # ---- ④ 回绕 ----
    print()
    print("[4] ⭐⭐ 32 位 tick 跨回绕（⭐ 回绕点在 1.0 秒与 86.9 秒处）")
    chk("  ⭐ 跨第一次回绕：0 秒 → 2 秒 = %d tick"
        % int(round(2.0 * E.PPQN * BPM / 60.0)),
        len(ns) >= 2 and ns[1]["t"] - ns[0]["t"] == 3840,
        "  实测 %s" % [e["t"] for e in ns[:2]])
    chk("  ⭐ 时间轴单调递增（⛔ 没有因回绕倒退）",
        all(ns[k + 1]["t"] >= ns[k]["t"] for k in range(len(ns) - 1)),
        "  %s" % [e["t"] for e in ns])
    chk("  ⭐ 非空洞：朴素相减在该处为负（⭐ 说明这条判据有区分力）",
        (tick_at(2.0) - tick_at(0.0)) < 0,
        "  朴素 = %d" % (tick_at(2.0) - tick_at(0.0)))
    want87 = int(round(87.0 * E.PPQN * BPM / 60.0))
    chk("  ⭐⭐ 跨【第二次】回绕：87 秒处 ⇒ %d tick（⛔ 不是 ~1 秒）" % want87,
        len(ns) >= 9 and ns[8]["t"] == want87,
        "  实测 t[8]=%s" % (ns[8]["t"] if len(ns) > 8 else None))
    fixed87 = ((tick_at(87.0) - tick_at(0.0)) % TWO32) / CLK
    chk("  ⭐ 非空洞：固定基准取模只得到 %.2f 秒（⭐ 差 %.0f 秒）"
        % (fixed87, 87.0 - fixed87), fixed87 < 2.0)

    # ---- ⑤ 坏帧不许伪装成合理值 ----
    print()
    print("[5] ⭐⭐ 坏帧⛔ 不许伪装成合理值")
    bad_note = E.hz_to_note(E.inc_to_hz(bad_value))
    chk("  坏帧对应的音（note=%s）⛔ 不在结果里" % bad_note,
        bad_note not in [e["note"] for e in ns], "  结果音高 %s" % [e["note"] for e in ns])
    chk("  ⭐ 坏帧的 tick（%.2f 秒）⛔ 不产生任何事件" % BAD_CSUM_SEC,
        int(round(BAD_CSUM_SEC * E.PPQN * BPM / 60.0)) not in [e["t"] for e in ns])
    chk("  ⭐ 未知类型帧⛔ 不产生任何事件",
        int(round(UNK_TYPE_SEC * E.PPQN * BPM / 60.0)) not in [e["t"] for e in ns])
    chk("  ⭐ 半帧⛔ 不产生任何事件",
        int(round(TRUNC_SEC * E.PPQN * BPM / 60.0)) not in [e["t"] for e in ns])

    if not args.keep:
        shutil.rmtree(out_dir, ignore_errors=True)
    else:
        print()
        print("产物保留在：%s" % out_dir)

    print()
    print("结论：%s" % ("端到端通过 ✅" if ok else "有失败项 🔴"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
