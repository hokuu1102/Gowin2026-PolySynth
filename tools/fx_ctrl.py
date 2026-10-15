#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fx_ctrl.py —— 效果器串口控制（⭐ 用【串口屏的帧协议】，⛔ 不需要新字母）

===============================================================================
为什么要这么写
===============================================================================
效果器参数在 FPGA 里是**运行时寄存器**（2026-10-15 起），由 `uart_ui` 解析
**串口屏的返回帧**写入。

帧格式（与 TJC 屏完全一致）：
    <返回码> <变量序号> <值> FF FF FF
      0x71      0x10..0x18

⭐ **好处**：串口屏和串口助手**同一套协议** ⇒ 屏上勾选和这里发帧走同一条
   代码路径，⛔ 不用"编译期二选一"，⛔ 也不占用那唯一剩下的字母 'Z'。

🔴 **一个必须知道的约束**：值 **0xFF 不可用** —— 它是帧尾标记（FF FF FF）。
   实用上无影响：掩码只用 **bit 0/1/2** ⇒ ⭐ **全开 = `0x07`**，永远不需要 0xFF。
   ⚠️ **bit4 是空闲位**（⛔ 不是颤音使能）—— 见下方 `V_MASK` 的注释。

===============================================================================
用法
===============================================================================
    python tools/fx_ctrl.py --port COM31 list
    python tools/fx_ctrl.py --port COM31 on                 # 全开（掩码 0x07）
    python tools/fx_ctrl.py --port COM31 off                # 全关
    python tools/fx_ctrl.py --port COM31 mask 0x05          # 只要失真+延迟
    python tools/fx_ctrl.py --port COM31 gain 64            # 失真 4.0 倍（默认档）
    python tools/fx_ctrl.py --port COM31 gain-raw 16384     # 直接写 Q4.12 原值
    python tools/fx_ctrl.py --port COM31 drive 64           # ⭐ 归一化驱动（gain 64 + trim 32）
    python tools/fx_ctrl.py --port COM31 sweep              # ⭐ 增益扫描（找失真点）
    python tools/fx_ctrl.py --port COM31 raw 10 07          # ⭐ 发任意帧体（⛔ 不带返回码 0x71）

⭐ **`drive` 命令（⭐ 2026-10-15 新增）——「推力↑而音量不变」**
    一次发**两帧**：`gain = 值` ＋ `trim = round(2048 / 值)`。
    换算依据：`gain = 值/16`（Q4.12）、`trim = 补偿值/128`（Q1.15）
      ⇒ 净增益 = `gain × trim` = `值 × 补偿值 / 2048`
      ⇒ 要净增益 ≈ 1 ⇒ `补偿值 = round(2048 / 值)`。
    对照表：`16→128 · 32→64 · 64→32 · 128→16 · 254→8`
    ⚠️ 值范围 **1..254**（255 不可用 —— `0xFF` 是帧尾标记）。
    ⚠️ **`254→8` 那一档的净增益不是正好 1.000，而是 `254×8/2048 = 0.9921875`**（⭐ 差 0.78%，
       听不出来）—— 因为补偿字节要 `round(2048/254) = 8`（⭐ 而 8.06 只能取整）✅

⭐ 波特率固定 500000 8N1（与 `uart_rx`/`calib_cmd` 一致）。
"""

import argparse
import sys
import time

#  ⭐⭐ 2026-10-15：⭐ **Windows 控制台编码兜底**（🔴 实测踩到）✅
#  ---------------------------------------------------------------------------
#  🔴 **症状**：⭐ 脚本里有 `⇒`（U+21D2）等非 GBK 字符 ⇒ 在中文 Windows 的
#     默认控制台（codepage 936 = GBK）上**直接崩**：
#         UnicodeEncodeError: 'gbk' codec can't encode character '\u21d2'
#     ⚠️ 而且**崩在打印那一行**，⭐ 看起来像"脚本逻辑坏了" ✗
#  ✅ **修法（两层）**：
#     ① 把控制台切到 UTF-8（`chcp 65001`）—— ⚠️ 只对 Windows 有效
#     ② 把 `stdout` 重配成 UTF-8 + `errors="replace"` —— ⭐ 万一切不了也**不崩** ✅
#  📌 **为什么不用"删掉所有非 ASCII"**：⭐ 这些中文说明**是给用户看的**，
#     ⚠️ 删了工具就没法自解释了 ✗ ⇒ ⭐ 该修的是**编码**，⛔ 不是文案 ✅
import os
if sys.platform == "win32":
    try:
        os.system("chcp 65001 >nul 2>&1")
    except Exception:
        pass
for _stream in ("stdout", "stderr"):
    try:
        getattr(sys, _stream).reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

try:
    import serial
except ImportError:
    print("需要 pyserial：pip install pyserial", file=sys.stderr)
    sys.exit(2)

BAUD = 500000

# ── 帧协议常量（与 rtl/w3c/uart_ui.v 对齐）────────────────────────────────
RET_NUM = 0x71          # 数值变量返回
TAIL = 0xFF             # 帧结束符（3 连）

# ── 效果器变量号（与 uart_ui.v 的端口注释表对齐）──────────────────────────
#  ⚠️ bit4 **不是**颤音使能位（⭐ `fx_chain.v:168-173` 明写"bit4 空闲"，
#     颤音级硬接常开、只由 `depth` 控制）⇒ 掩码实际只用 bit0/1/2。
V_MASK = 0x10           # 开关掩码：bit0=失真 bit1=合唱 bit2=延迟（bit3 混响留位·bit4 空闲）
V_GAIN = 0x11           # 失真增益：值 ×256 ⇒ Q4.12（32⇒2.0 64⇒4.0 254⇒15.875）
V_TRIM = 0x12           # 失真补偿：值 ×256 ⇒ Q1.15（32⇒0.25 默认）
V_MIX = 0x13            # 延迟/合唱混合（Q0.8）
V_FB = 0x14             # 延迟反馈（Q0.8）
V_DEPTH = 0x15          # 颤音深度（0 = 数值恒等）
V_RATE = 0x16           # 颤音速率
V_DLYLEN = 0x17         # 延迟长度：值 ×128 采样（64⇒8192⇒168 ms）
V_CHORLEN = 0x18        # 合唱长度：值 ×32 采样（23⇒736⇒15 ms）

#  ⚠️ **掩码只有 bit0/1/2 三个【已实现】的位** ⇒ ⭐ **全开 = `0x07`** ✅
#     🔴 **2026-10-15（清道夫 SWEEPER）修**：⭐ 原来这里还有 `BIT_TREM = 4`，
#        并让 `describe_mask()` 对 bit4 打印"**颤音**" —— ⚠️ 而**同一份代码**的
#        `list` 输出又把 `0x17` 标成"（bit4 空转）" ⇒ 🔴 **自相矛盾**：
#        用户发 `mask 0x17` 会被告知"颤音开了"，⭐ 而**音频上一个颤音都没开** ✗
#     ⭐ 真相：⭐ 颤音级**硬接常开**，只由 `depth` 控制（⭐ `fx_chain.v` 明写"bit4 空闲"）
#        ⇒ ⭐ **bit4 = 空闲**，⛔ 无任何语义 ⇒ ⭐ 本常量**已删除** ✅
BIT_DIST, BIT_CHOR, BIT_DELAY = 0, 1, 2

#  ⭐ 默认值（与 `uart_ui.v` 的 FX_*_DEF 一致）—— `list` 用来说明"出厂值"
DEFAULTS = {
    "mask": 0x00, "gain": 64, "trim": 32, "mix": 128,
    "fb": 96, "depth": 0, "rate": 7, "dlylen": 64, "chorlen": 23,
}

VAR_NAMES = {
    V_MASK: "mask", V_GAIN: "gain", V_TRIM: "trim", V_MIX: "mix",
    V_FB: "fb", V_DEPTH: "depth", V_RATE: "rate",
    V_DLYLEN: "dlylen", V_CHORLEN: "chorlen",
}


def build_frame(var, value):
    """造一个 `0x71 <var> <value> FF FF FF` 帧。

    🔴 值 0xFF 会被 FPGA 当成帧尾标记 ⇒ 这里**主动拒绝**（⛔ 不静默发出去）。
    """
    if not 0 <= var <= 0xFE:
        raise ValueError("变量序号必须在 0x00..0xFE")
    if value == 0xFF:
        raise ValueError(
            "值 0xFF 不可用 —— 它是帧尾标记（FF FF FF），协议固有约束。\n"
            "  实用上无影响：掩码只用 bit 0/1/2 ⇒ 全开 = 0x07。\n"
            "  要「全开」请用 0x07；要「差一位」用 0x06（少失真）/ 0x05（少合唱）/ 0x03（少延迟）。"
        )
    if not 0 <= value <= 0xFE:
        raise ValueError("值必须在 0x00..0xFE")
    return bytes([RET_NUM, var, value, TAIL, TAIL, TAIL])


def send(port, frames, gap_ms=30):
    """把一串帧依次发出去（⭐ 帧间留间隔，避免和屏的回传撞车）。"""
    with serial.Serial(port, BAUD, timeout=0.2) as s:
        time.sleep(0.1)
        for f in frames:
            s.write(f)
            s.flush()
            time.sleep(gap_ms / 1000.0)
    return len(frames)


def describe_mask(m):
    #  ⚠️ **只描述 bit0/1/2** —— ⭐ bit3（混响留位）与 bit4（空闲）**都不打印**
    #     （⭐ 原来 bit4 会打印"颤音" ⇒ 🔴 与 `list` 的"（bit4 空转）"自相矛盾）✅
    on = []
    if m & (1 << BIT_DIST):
        on.append("失真")
    if m & (1 << BIT_CHOR):
        on.append("合唱")
    if m & (1 << BIT_DELAY):
        on.append("延迟")
    if m & ~0x07:
        on.append("（bit3/bit4 等未实现位被置 1 —— ⭐ 无效果）")
    return " + ".join(on) if on else "（全关）"


def cmd_list(_args):
    print("效果器变量表（帧格式：71 <序号> <值> FF FF FF）")
    print("-" * 78)
    rows = [
        (V_MASK, "mask", "0x00..0x07", "直传",
         "bit0=失真 bit1=合唱 bit2=延迟 · ⚠️ bit4 空闲（⛔ 无任何效果）"),
        (V_GAIN, "gain", "0..254", "×256 ⇒ Q4.12",
         "失真增益：32⇒2.0 · 64⇒4.0（默认）· 254⇒15.875（255 因帧尾约束不可发）"),
        (V_TRIM, "trim", "0..254", "×256 ⇒ Q1.15",
         "失真补偿：32⇒0.25（默认）· 128⇒1.0"),
        (V_MIX, "mix", "0..254", "直传 Q0.8", "延迟/合唱混合"),
        (V_FB, "fb", "0..254", "直传 Q0.8", "延迟反馈"),
        (V_DEPTH, "depth", "0..254", "直传", "颤音深度，0 = 数值恒等"),
        (V_RATE, "rate", "0..254", "直传", "颤音速率"),
        (V_DLYLEN, "dlylen", "0..254", "×128 采样",
         "延迟长度：64⇒8192（168 ms）· >127 饱和"),
        (V_CHORLEN, "chorlen", "0..254", "×32 采样",
         "合唱长度：23⇒736（15 ms）· >63 饱和"),
    ]
    for var, name, rng, conv, note in rows:
        d = DEFAULTS.get(name, "?")
        print("  0x%02X  %-8s %-8s %-14s 默认 %-4s  %s" % (var, name, rng, conv, d, note))
    print()
    print("掩码示例（⭐ 只用 bit0/1/2 ⇒ **全开 = 0x07**）：")
    for m, label in [(0x00, "全关"), (0x01, "只失真"), (0x05, "失真+延迟"),
                     (0x07, "失真+合唱+延迟（⭐ 全开）"),
                     (0x06, "全开差一位：少失真"),
                     (0x03, "全开差一位：少延迟")]:
        print("  0x%02X = %-16s %s" % (m, label, describe_mask(m)))
    print()
    print("⚠️ 值 0xFF 不可用（帧尾标记）。掩码有效范围 0x00..0x07 ⇒ 不受影响。")


def cmd_on(args):
    n = send(args.port, [build_frame(V_MASK, 0x07)])
    print("已发 %d 帧：mask = 0x07（%s）" % (n, describe_mask(0x07)))


def cmd_off(args):
    n = send(args.port, [build_frame(V_MASK, 0x00)])
    print("已发 %d 帧：mask = 0x00（全关）" % n)


def cmd_mask(args):
    m = int(args.value, 0)
    #  🔴 **2026-10-15（清道夫 SWEEPER）修**：⭐ 原来允许到 `0xFE` ——
    #     ⚠️ 而**只有 bit0/1/2 有效**（⭐ bit3 混响留位、⭐ bit4 空闲）
    #     ⇒ 🔴 允许 `0x17` 会让用户以为"多开了一个效果"（⭐ 其实什么都没多开）✗
    #  ⭐ 现在**只收 0x00..0x07** ⇒ ⭐ 工具与 RTL 的语义**逐位一致** ✅
    if m > 0x07:
        print("掩码有效范围 0x00..0x07（⭐ 只有 bit0=失真/bit1=合唱/bit2=延迟 有效；"
              "bit3 混响留位、bit4 空闲）", file=sys.stderr)
        sys.exit(2)
    n = send(args.port, [build_frame(V_MASK, m)])
    print("已发 %d 帧：mask = 0x%02X（%s）" % (n, m, describe_mask(m)))


def cmd_set(args):
    table = {
        "mask": V_MASK, "gain": V_GAIN, "trim": V_TRIM, "mix": V_MIX,
        "fb": V_FB, "depth": V_DEPTH, "rate": V_RATE,
        "dlylen": V_DLYLEN, "chorlen": V_CHORLEN,
    }
    var = table[args.name]
    v = int(args.value, 0)
    n = send(args.port, [build_frame(var, v)])
    print("已发 %d 帧：%s(0x%02X) = %d" % (n, args.name, var, v))


def cmd_gain_raw(args):
    """⭐ 直接写 Q4.12 原值（⛔ 不做 ×256 换算）—— 用来精确对照文档里的常数。

    ⚠️ **帧协议的值只有一个字节** ⇒ ⭐ 只能表达 **256 的整数倍**：
       实际发出的字节 = `round(raw / 256)`（⭐ 四舍五入到**最接近**的那一档）。
    """
    raw = int(args.value, 0)
    if not 0 <= raw <= 0xFE00:
        print("Q4.12 原值范围 0..0xFE00（= 254 × 256）—— "
              "⭐ 再大就需要值字节 0xFF，而它是帧尾标记（FF FF FF），不可发",
              file=sys.stderr)
        sys.exit(2)
    #  ⭐ 实际发出的那个字节（⭐ 四舍五入到**最接近**的一档）
    #  🔴 **2026-10-15（清道夫 SWEEPER）修**：⭐ 原来是 `raw // 256`（**向下取整**），
    #     ⚠️ 而提示语写的是"**最接近**" ⇒ 🔴 **自相矛盾**：
    #        · `gain-raw 16383` 提示"最接近的是 16128"（⭐ 真最近是 **16384**）✗
    #        · `gain-raw 200`   提示 0（⭐ 真最近是 **256**）✗
    #     ⇒ ⭐ 现在用 `(raw + 128) // 256` ⇒ ⭐ 与"最接近"的措辞一致 ✅
    byte_val = (raw + 128) // 256
    #  🔴 **2026-10-15 修**：⭐ 原来的 `0xFF` 检查**查错了对象** ——
    #     ⚠️ 它查 `raw` 的 **hi/lo 两个字节**，而**实际只发 `raw // 256` 这一个字节**：
    #        · 🔴 `gain-raw 255`（= 0x00FF）被**误拒**（⭐ 其实只会发字节 **0**）✗
    #        · 🔴 `hi == 0xFF` **恒假**（⭐ 上面 `raw <= 0xFE00` 已保证 `hi <= 0xFE`）✗
    #     ⇒ ⭐ 现在只检查**真正要发的那个字节** ✅
    if byte_val == 0xFF:
        print("该值需要值字节 0xFF ⇒ 不可发（帧尾约束）", file=sys.stderr)
        sys.exit(2)
    if byte_val * 256 != raw:
        print("⚠️ 帧协议的值只有一个字节 ⇒ 只能表达 256 的整数倍。")
        print("   你要的 %d 不是 256 的倍数，最接近的是 %d（= 0x%02X）。"
              % (raw, byte_val * 256, byte_val))
        if args.strict:
            sys.exit(2)
    n = send(args.port, [build_frame(V_GAIN, byte_val)])
    print("已发 %d 帧：gain 值=%d ⇒ Q4.12 = %d（%.3f 倍）"
          % (n, byte_val, byte_val * 256, byte_val * 256 / 4096.0))


def cmd_sweep(args):
    """⭐ 增益扫描 —— 用耳朵找"明显失真"的那个点。

    ⚠️ 这是本工具**最主要的用途**：失真效果"有没有"取决于增益够不够大
       （⭐ 信号必须被推过满量程才会削波）。
       ⭐ 一边放音一边扫，听到"破"就是那一档。
    """
    lo, hi = int(args.lo), int(args.hi)
    step = int(args.step)
    print("增益扫描 %d..%d（步长 %d），每档停 %.1f s" % (lo, hi, step, args.dwell))
    print("📌 值 32 ⇒ 2.0 倍 · 64 ⇒ 4.0 倍（默认）· 254 ⇒ 15.875 倍（⭐ 最大可发）")
    print("⚠️ 请一边放音（按住一个音）一边看这里\n")
    with serial.Serial(args.port, BAUD, timeout=0.2) as s:
        time.sleep(0.1)
        for v in range(lo, hi + 1, step):
            if v == 0xFF:
                continue
            s.write(build_frame(V_GAIN, v))
            s.flush()
            print("  gain = %3d  ⇒  %6.3f 倍" % (v, v * 256 / 4096.0))
            time.sleep(args.dwell)
    print("\n扫完。⭐ 记住「开始明显破」的那一档，用 `gain <值>` 固定它。")


def cmd_drive(args):
    """⭐ 归一化驱动 —— 一次发两帧（`gain = 值` ＋ `trim = round(2048/值)`）。

    ⭐ **目的**：⭐ **推力↑而音量不变** ⇒ ⭐ 能听出"失真音色"，
       ⛔ 不会因为"顺便变响了"而误判。

    ⭐ **换算依据**（⭐ 2026-10-15 字节映射由 ×128 改 ×256）：
        · `gain = 值/16`      （Q4.12：值×256，4096 = 1.0）
        · `trim = 补偿值/128` （Q1.15：值×256，32768 = 1.0）
        ⇒ `净增益 = gain × trim = 值 × 补偿值 / 2048`
        ⇒ 要净增益 ≈ 1 ⇒ `补偿值 = round(2048 / 值)` ✅
    📌 **对照表**：`16→128 · 32→64 · 64→32 · 128→16 · 254→8`
       ⚠️ **`254→8` 那一档的净增益是 `254×8/2048 = 0.9921875`**（⭐ 差 0.78%，听不出来），
          ⛔ **不是正好 1.000** —— ⭐ 因为补偿字节只能取整（`round(2048/254) = 8`）✅
    """
    val = int(args.value, 0)
    if not 1 <= val <= 254:
        print("drive 的值必须在 1..254 —— ⛔ 255 不可用（`0xFF` 是帧尾标记）",
              file=sys.stderr)
        sys.exit(2)
    trim_val = int(round(2048.0 / val))
    if trim_val > 0xFE:
        #  ⚠️ 值太小（≤8）时归一化需要 >254 ⇒ 只能饱和
        print("⚠️ 值 %d 太小 ⇒ 归一化补偿需要 %d（>254），已饱和到 254。"
              % (val, trim_val))
        print("   ⇒ ⭐ 净增益只能到 %.3f 倍（<1.0，⭐ 会变小声，⛔ 不是 1.0）"
              % (val * 254 / 2048.0))
        trim_val = 0xFE
    #  🔴 **2026-10-15（清道夫 SWEEPER）删除**：⭐ 这里原来还有一个
    #     `if trim_val == 0xFF: trim_val = 0xFE` —— ⚠️ **不可达**（死分支）：
    #        · ⭐ 上面 `if trim_val > 0xFE` 已经**含 255** ⇒ ⭐ 走到这里必然 ≤ 254 ✅
    #        · ⭐ 且整数 `val ∈ [1,254]` 时 `round(2048/val)` **永不等于 255**
    #          （⭐ 255 需要 `val = 2048/255 ≈ 8.03`，⛔ 不是整数）✅
    n = send(args.port, [build_frame(V_GAIN, val), build_frame(V_TRIM, trim_val)])
    print("已发 %d 帧：⭐ 归一化驱动" % n)
    print("  gain = %3d ⇒ %.3f 倍（Q4.12 = %d）" % (val, val / 16.0, val * 256))
    print("  trim = %3d ⇒ %.3f（Q1.15 = %d）" % (trim_val, trim_val / 128.0, trim_val * 256))
    print("  ⇒ ⭐ 净增益 ≈ %.3f 倍（⭐ 目标 1.000 —— 推力↑而音量不变）"
          % (val * trim_val / 2048.0))
    #  ⚠️ **诚实提示**：⭐ 补偿字节只能取整 ⇒ ⭐ 有些档位**达不到正好 1.000**
    #     （⭐ 例如 `val = 254`：`round(2048/254) = 8` ⇒ ⭐ 净增益 **0.9921875**，
    #       ⭐ 差 0.78% —— 听不出来，⛔ 但不是"正好 1.000"）✅
    if abs(val * trim_val / 2048.0 - 1.0) > 0.005:
        print("     ⚠️ 本档取整后差 %.2f%%（⭐ 补偿字节只能取整，⛔ 不是正好 1.000）"
              % ((val * trim_val / 2048.0 - 1.0) * 100.0))


def cmd_raw(args):
    body = [int(x, 16) for x in args.bytes]
    for b in body:
        if not 0 <= b <= 0xFF:
            print("字节范围 0x00..0xFF", file=sys.stderr)
            sys.exit(2)
    frame = bytes([RET_NUM] + body + [TAIL, TAIL, TAIL])
    n = send(args.port, [frame])
    print("已发 %d 帧：%s" % (n, " ".join("%02X" % b for b in frame)))


def main():
    ap = argparse.ArgumentParser(
        description="效果器串口控制（用串口屏的帧协议）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--port", required=True, help="串口号，例如 COM31")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="列出所有变量与取值").set_defaults(func=cmd_list)
    sub.add_parser("on", help="全开（掩码 0x07 = 失真+合唱+延迟）").set_defaults(func=cmd_on)
    sub.add_parser("off", help="全关（掩码 0x00）").set_defaults(func=cmd_off)

    p = sub.add_parser("mask", help="设掩码 0x00..0x07（bit0=失真 bit1=合唱 bit2=延迟；全开 0x07）")
    p.add_argument("value")
    p.set_defaults(func=cmd_mask)

    for name in ("gain", "trim", "mix", "fb", "depth", "rate", "dlylen", "chorlen"):
        p = sub.add_parser(name, help="设 %s（值 0..254）" % name)
        p.add_argument("value")
        p.set_defaults(func=cmd_set, name=name)

    p = sub.add_parser("gain-raw", help="按 Q4.12 原值设增益（⭐ 自动提示近似）")
    p.add_argument("value")
    p.add_argument("--strict", action="store_true", help="不是 256 倍数就报错")
    p.set_defaults(func=cmd_gain_raw)

    p = sub.add_parser("drive", help="⭐ 归一化驱动：gain=值 + trim=round(2048/值)（推力↑音量不变；254 档净增益 0.992）")
    p.add_argument("value", help="gain 字节，1..254（16→128 · 32→64 · 64→32 · 128→16 · 254→8=0.992 倍）")
    p.set_defaults(func=cmd_drive)

    p = sub.add_parser("sweep", help="⭐ 增益扫描（找明显失真的点）")
    p.add_argument("--lo", default="32")
    p.add_argument("--hi", default="254")
    p.add_argument("--step", default="16")
    p.add_argument("--dwell", type=float, default=1.5)
    p.set_defaults(func=cmd_sweep)

    p = sub.add_parser("raw", help="发任意帧体（⛔ 不含返回码），例如 raw 10 07")
    p.add_argument("bytes", nargs="+")
    p.set_defaults(func=cmd_raw)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
