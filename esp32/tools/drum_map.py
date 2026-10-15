#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""drum_map.py —— GM 打击乐音高 -> FPGA 鼓机四种鼓 的映射（唯一真相源）。

═══ 为什么需要它 ═══
用户灌了一份 MIDI（含鼓轨），听起来"怪怪的"—— 查证发现：
    鼓轨被当成普通音轨，按 GM 音高（36/38/42/45...）**当乐音发出去**
    => 鼓变成了低音区的音阶。

⭐ 而 FPGA 侧的鼓机有【4 件】，各自是一个固定频率（不是 GM 音高）：
     Kick / Snare / HiHat / Tom
   权威出处：FPGA 线 2026-10-14 答复 §五（对应 `rtl/w3c/drum_gen.v:180-186`）
     · 4 件【共用】AXIS_ID = 15，靠 phase_inc（音高）区分音色
     · 换算：f = inc × 48828.125 / 2^32
     · 件序：bit0=Kick · bit1=Snare · bit2=HiHat · bit3=Tom

⚠️ 所以 PC 侧【必须】做这一步转换：
     GM 音高 -> 上述 4 个 inc 之一
   ⛔ 不能直接把 GM 音高当 phase_inc 发（那就是用户听到的"怪"）。

═══ GM 音高 -> 4 件 的映射依据 ═══
🔴 **FPGA 侧【没有】给我们这个映射**（他们只给了 4 个频率）。
   ⭐ 本表按【General MIDI 打击乐标准】（GM 的 channel 10 音高表）归纳成 4 类。
   📌 出处：MIDI 1.0 规范的 GM 鼓映射（广泛实现的事实标准）。
   ⚠️ 这是【我方归纳】，⛔ 不是 FPGA 侧的规定 —— 已列为待确认项。
      若 FPGA 侧另有口径，只改本文件一处即可。

用法：
    python drum_map.py --selftest          # 离线自检
    python drum_map.py --list              # 打印映射表
"""

import sys

# 控制台按 UTF-8 输出（Windows 默认 GBK，遇到 ⛔ 之类会 UnicodeEncodeError）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ---- FPGA 侧权威常量（⛔ 不要改，除非 FPGA 侧通知）------------------------
# 出处：FPGA 线 2026-10-14 答复 §五 / rtl/w3c/drum_gen.v:180-186
# ⚠️ 下面同时给两套值，⛔ 别混：
#   PHASE_INC —— FPGA 侧内部的 32 位 phase_inc（rtl/w3c/drum_gen.v:180-186）
#                ⭐ 只用于"反算频率"与文档，⛔ 不是要发的值
#   DRUM_INC  —— ⭐ **实际要填进下行 `inc` 字段的值** = `phase_inc >> 10`
#                依据：FPGA 侧第 3 版答复（rtl/top.v:4575）
#                  wire [31:0] ps_evt_inc = {1'b0, data[43:23], 10'b0};
#                ⇒ ⭐ 字段语义 = `phase_inc >> 10`（高 21 位），
#                  🔴 ⛔ 不是"低 21 位" ⇒ 该发 `>> 10`，⛔ 不是 `& 0x1FFFFF`
#                📌 我上一轮按 `& 0x1FFFFF` 分析，得出的"21 位装不下"结论
#                   前提错了 —— FPGA 侧指出那张表整张作废。
PHASE_INC = {
    "kick":  5368709,
    "snare": 42949673,
    "hihat": 171798691,
    "tom":   17895697,
}
IN_INC_SHIFT = 10          # ⭐ 下行字段 = phase_inc >> 10
def _to_field(phase_inc):
    """32 位 phase_inc -> 下行 21 位字段值。

    ⭐ 依据 FPGA 侧第 3 版答复（rtl/top.v:4575）：
        ps_evt_inc = {1'b0, data[43:23], 10'b0}  =>  字段值 = phase_inc >> 10

    ⚠️ 用【四舍五入】而不是截断 —— 与我方乐音的口径保持一致：
       乐音 midiToPhaseInc() = round(f * 2^32 / 50e6)，而
       50e6 = 48828.125 × 1024  ⇒ 两种写法数学等价，只差取整。
       ⭐ 若鼓用截断、乐音用 round，同一套坐标系里会差 1 —— 没必要。
    📌 kick 实测：5368709/1024 = 5242.88 ⇒ 截断 5242 / round 5243
       FPGA 侧表格给的是 5243（与 round 一致）。
    """
    return int(round(phase_inc / 1024.0))


DRUM_INC = {k: _to_field(v) for k, v in PHASE_INC.items()}

# 鼓的力度 —— 用【鼓机的固定力度】（2026-10-14，用户："把鼓力度抬到和鼓机一个量级"）。
# 原来发 MIDI 原始力度（0..127），而鼓机是 175..235
#   => 灌谱的鼓只有鼓机的一半响，听着"没劲"。
# 必须是【生效值】= 模块默认 + top.v 的实例化覆盖：
#   rtl/w3c/drum_gen.v:92-95 默认  KICK 230 / SNARE 200 / HIHAT 140 / TOM 190
#   rtl/top.v:2519-2521     覆盖  SNARE 235 / HIHAT 175 / TOM 220
#     （KICK 未被覆盖 => 仍用默认 230）
#   => 生效值 230 / 235 / 175 / 220
# 音量与力度成线性（perc_env_bank.v 的 SHIFT = ENV_W - VEL_W，峰值 = velocity << 8）。
# 若 FPGA 侧改那几个数，这里与 score_studio.html 的 DRUM_VEL 都要同步。
DRUM_VEL = {"kick": 230, "snare": 235, "hihat": 175, "tom": 220}


def drum_vel(name):
    """鼓件 -> 下行 vel 字段值（与鼓机一致）。认不出的件给 200（不给 0，那会静音）。"""
    return DRUM_VEL.get(name, 200)


# 方案 B（2026-10-15）：四件【各占一条轴】12/13/14/15（原为四件共用 15）。
#   ⭐ 判据与 rtl/w3c/seq_arb.v:204 一致：axis >= 12 ⇒ 鼓。
#   ⚠️ 与 score_studio.html / upstream_studio.html 的同名常量必须一致（三处口径）。
DRUM_AXIS_OF = {"kick": 12, "snare": 13, "hihat": 14, "tom": 15}
DRUM_AXIS_BASE = 12
DRUM_ORDER = ("kick", "snare", "hihat", "tom")   # 与 step_mask 位序一致
FS_FPGA = 48828.125                 # f = inc * FS / 2^32


def inc_to_hz(inc):
    return inc * FS_FPGA / 4294967296.0      # 传 32 位 phase_inc 进来


# ---- GM 打击乐音高 -> 我们的 4 件 -----------------------------------------
# ⭐ 按 GM 标准归纳。⚠️ 未列出的音高 => 归到最近的兜底件（见 gm_to_drum）。
GM_DRUM_MAP = {
    # --- Kick 类（底鼓 / 低音鼓）---
    35: "kick", 36: "kick",          # Acoustic / Bass Drum 1
    # --- Snare 类（军鼓 / 拍手 / 边击）---
    37: "snare",                     # Side Stick
    38: "snare",                     # Acoustic Snare
    39: "snare",                     # Hand Clap
    40: "snare",                     # Electric Snare
    # --- Tom 类（嗵鼓 / 中低音鼓）---
    41: "tom", 43: "tom", 45: "tom", 47: "tom",   # Low/Mid/High Floor & Low Tom
    48: "tom", 50: "tom",                          # Hi-Mid / High Tom
    # --- HiHat 类（踩镲 / 镲片 / 铃）---
    42: "hihat", 44: "hihat",        # Closed / Pedal Hi-Hat
    46: "hihat",                     # Open Hi-Hat
    49: "hihat", 51: "hihat", 52: "hihat", 53: "hihat", 55: "hihat", 57: "hihat",
    59: "hihat",                     # Ride 系列 / Crash / China / Splash / Ride Bell
    54: "hihat",                     # Tambourine
    56: "hihat",                     # Cowbell
    58: "hihat",                     # Vibraslap
    # --- Snare 类（拉丁打击，归军鼓最接近）---
    60: "snare", 61: "snare", 62: "snare", 63: "snare", 64: "snare",
    65: "snare", 66: "snare", 67: "snare", 68: "snare", 69: "snare",
    70: "snare", 71: "snare", 72: "snare", 73: "snare", 74: "snare",
    75: "snare", 76: "snare", 77: "snare", 78: "snare", 79: "snare",
    80: "snare", 81: "snare",
}

# ⚠️ 未映射时怎么兜底：按音高分区（低->kick，中->tom，高->hihat）
#    为什么不用"丢弃"：丢鼓会让节奏缺失（那是**听得出**的缺陷）；
#    归到最接近的一件至少保持节奏。
GM_FALLBACK_BANDS = (
    (0,  37, "kick"),
    (38, 48, "snare"),
    (49, 60, "tom"),
    (61, 127, "hihat"),
)


def gm_to_drum(midi):
    """GM 鼓音高 -> 四件之一。返回 (件名, 依据说明)。

    ⭐ 先查表；查不到按音高分区兜底，并【说清是兜底】——
       ⛔ 不许静默归类（用户要能看出哪些音高没被显式映射）。
    """
    m = int(midi)
    if m in GM_DRUM_MAP:
        return GM_DRUM_MAP[m], "表内"
    for lo, hi, name in GM_FALLBACK_BANDS:
        if lo <= m <= hi:
            return name, "⚠️ 兜底（音高 %d 不在映射表内）" % m
    return "snare", "⚠️ 兜底（音高越界）"


def drum_inc(name):
    return DRUM_INC[name]


# ===========================================================================
def selftest():
    """离线自检 —— 重点：映射方向对、四个频率对、兜底会说清。"""
    print("=" * 74)
    print("drum_map.py 离线自检（不需要硬件）")
    print("=" * 74)
    bad = 0

    def chk(name, cond, extra=""):
        nonlocal bad
        print("  %-56s %s%s" % (name, "OK" if cond else "RED",
                                ("   " + extra) if extra else ""))
        if not cond:
            bad += 1

    # ① 四个 phase_inc 与 FPGA 侧给的权威值一致（32 位原值）
    chk("Kick  phase_inc = 5368709", PHASE_INC["kick"] == 5368709)
    chk("Snare phase_inc = 42949673", PHASE_INC["snare"] == 42949673)
    chk("HiHat phase_inc = 171798691", PHASE_INC["hihat"] == 171798691)
    chk("Tom   phase_inc = 17895697", PHASE_INC["tom"] == 17895697)

    # ①b ⭐ 下行字段值 = phase_inc >> 10（FPGA 侧第 3 版答复 rtl/top.v:4575）
    #     ⚠️ 用 round 而不是截断（与乐音口径一致）
    FPGA_TABLE = {"kick": 5243, "snare": 41943, "hihat": 167772, "tom": 17476}
    ok_tbl = all(DRUM_INC[k] == v for k, v in FPGA_TABLE.items())
    chk("⭐ 四个字段值与他们表格给的 >>10 列一致", ok_tbl,
        str({k: DRUM_INC[k] for k in FPGA_TABLE}))
    chk("⭐ 四个字段值全部放得进 21 位（上限 2097151）",
        all(v <= 2097151 for v in DRUM_INC.values()),
        str(sorted(DRUM_INC.values())))

    # ①c ⭐ 鼓力度 = 鼓机的【生效值】（模块默认 + top.v 覆盖）
    #     ⚠️ 生效值：KICK 230（未覆盖）· SNARE 235 · HIHAT 175 · TOM 220
    chk("⭐ 鼓力度与鼓机生效值一致（230/235/175/220）",
        DRUM_VEL == {"kick": 230, "snare": 235, "hihat": 175, "tom": 220},
        str(DRUM_VEL))
    chk("⭐ 力度都在 8 位范围内（1..255）",
        all(1 <= v <= 255 for v in DRUM_VEL.values()),
        str(sorted(DRUM_VEL.values())))
    chk("非空洞：鼓力度明显高于 MIDI 原始力度上限（127）",
        min(DRUM_VEL.values()) > 127,
        "最小 " + str(min(DRUM_VEL.values())) + " vs MIDI 上限 127")
    chk("认不出的件给 200（不给 0 —— 那会静音）", drum_vel("nope") == 200)

    # ② 反算频率（用 32 位 phase_inc）
    chk("Kick  频率 ≈ 61.0 Hz", abs(inc_to_hz(PHASE_INC["kick"]) - 61.0) < 0.5,
        "%.2f Hz" % inc_to_hz(PHASE_INC["kick"]))
    chk("Snare 频率 ≈ 488.3 Hz", abs(inc_to_hz(PHASE_INC["snare"]) - 488.3) < 1.0,
        "%.2f Hz" % inc_to_hz(PHASE_INC["snare"]))
    chk("HiHat 频率 ≈ 1953.1 Hz", abs(inc_to_hz(PHASE_INC["hihat"]) - 1953.1) < 2.0,
        "%.2f Hz" % inc_to_hz(PHASE_INC["hihat"]))
    chk("Tom   频率 ≈ 203.4 Hz", abs(inc_to_hz(PHASE_INC["tom"]) - 203.4) < 1.0,
        "%.2f Hz" % inc_to_hz(PHASE_INC["tom"]))

    # ③ 用户那份 MIDI 里实际出现的鼓音高，逐个看映射
    #    （36,38,42,45,46,47,48,50,51,53,55,57 —— 实测）
    used = [36, 38, 42, 45, 46, 47, 48, 50, 51, 53, 55, 57]
    expected = {36: "kick", 38: "snare", 42: "hihat", 45: "tom", 46: "hihat",
                47: "tom", 48: "tom", 50: "tom", 51: "hihat", 53: "hihat",
                55: "hihat", 57: "hihat"}
    ok_all = True
    for m in used:
        got, why = gm_to_drum(m)
        if got != expected[m]:
            ok_all = False
            print("      RED 音高 %d 映射成 %s，期望 %s" % (m, got, expected[m]))
    chk("用户 MIDI 里用到的 12 个鼓音高全部映射正确", ok_all)
    chk("这 12 个全部来自【表内】（⛔ 没有走兜底）",
        all(gm_to_drum(m)[1] == "表内" for m in used))

    # ④ 非空洞：兜底必须【说清】是兜底
    _, why = gm_to_drum(31)          # 表里没有、落在 kick 区
    chk("非空洞：表外音高 => 依据里写清是兜底", "兜底" in why, why)
    got, why2 = gm_to_drum(31)
    chk("非空洞：表外低音高 => 兜底到 kick", got == "kick", got)

    # ⑤ 方向性：低音高不该判成 hihat
    chk("方向性：音高 36 => kick（⛔ 不是 hihat）", gm_to_drum(36)[0] == "kick")
    chk("方向性：音高 42 => hihat（⛔ 不是 kick）", gm_to_drum(42)[0] == "hihat")

    # ⑥ 方案 B：四件【各占一条轴】12/13/14/15
    chk("四件各占一条轴 12/13/14/15（⭐ FPGA 侧 seq_arb 的口径）",
        DRUM_AXIS_OF == {"kick": 12, "snare": 13, "hihat": 14, "tom": 15},
        str(DRUM_AXIS_OF))
    chk("非空洞：轴号【互不相同】（⛔ 若又变回'四件共用一条'这条立刻红）",
        len(set(DRUM_AXIS_OF.values())) == 4)
    chk("判据边界：axis >= 12 才是鼓（11 是旋律上限）",
        DRUM_AXIS_BASE == 12)
    chk("件序与 step_mask 位序一致（kick,snare,hihat,tom）",
        DRUM_ORDER == ("kick", "snare", "hihat", "tom"))

    print()
    print("结论：%s" % ("全部通过" if bad == 0 else "有 %d 项不符" % bad))
    return 0 if bad == 0 else 1


def main():
    if "--selftest" in sys.argv:
        return selftest()
    print("=" * 74)
    print("GM 打击乐音高 -> FPGA 鼓机四件 的映射")
    print("=" * 74)
    print("  FPGA 侧四件（权威值，出处 drum_gen.v:180-186）：")
    for name in DRUM_ORDER:
        print("    %-6s inc = %-10d  ≈ %7.2f Hz"
              % (name, DRUM_INC[name], inc_to_hz(DRUM_INC[name])))
    print("    ⭐ 四件【各占一条轴】：" +
          " ".join("%s=轴%d" % (n, DRUM_AXIS_OF[n]) for n in DRUM_ORDER) +
          "（判据 axis >= %d）" % DRUM_AXIS_BASE)
    print()
    print("  GM 音高 -> 件：")
    for m in sorted(GM_DRUM_MAP):
        print("    %3d -> %s" % (m, GM_DRUM_MAP[m]))
    print()
    print("  ⚠️ 表外音高按音高分区兜底：")
    for lo, hi, name in GM_FALLBACK_BANDS:
        print("    %3d..%3d -> %s" % (lo, hi, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
