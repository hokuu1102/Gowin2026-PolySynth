#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
trigger_and_capture.py —— 【单进程】发触发字符 + 抓 UART1 放水字节流（分块时间戳）

════════════════════════════════════════════════════════════════════════════════
⭐ 为什么需要这个脚本（🔴 上一版失败的原因）

    ESP32-S3 把谱面灌进 PSRAM 水池后，**不是自己开始放水** ——
    它必须先在 UART1 RX(GPIO18) 上收到一个 ASCII 字符才动：

        S = 开始放水      X = 停止      R = 复位 / 清池

    USB-TTL（CH340，如 COM31）**两条线都接**：

        ESP32 GPIO17 (TX) ──> CH340 RXD     ⭐ 我们【收】放水帧流
        ESP32 GPIO18 (RX) <── CH340 TXD     ⭐ 我们【发】触发字符
        GND ──────────────── GND            ⚠️ 必须共地

    🔴 **失败教训**：上一次把【同一个串口】开在【两个进程】里
       （一个抓、一个发）⇒ `PermissionError(13, 'Access is denied')`。
       Windows 的串口是【独占】的，一个进程开着，另一个就打不开。

    ✅ **本脚本的修法（也是它的全部意义）**：
       **一个进程、一个 `serial.Serial` 句柄，既读又写**。
       pyserial 在同一个句柄上并发读/写是支持的 ⇒ 从根上避开独占冲突。

════════════════════════════════════════════════════════════════════════════════
⭐ 为什么用【单线程非阻塞循环】而不是线程

    ⚠️ 直觉方案是"一个线程读、一个线程写"，但那要处理锁、线程退出、
       以及 GIL 下的时间戳抖动 —— **复杂度换不来任何精度**。

    ⭐ 本脚本的做法：**一个循环里交替做两件事**

        ┌─ 到点了？ ──> ser.write(触发) + flush()，记下【发出的精确时刻】
        └─ ser.read(块)（带小超时）⇒ 收满一块就立刻打【一个】时间戳

    ⇒ ⭐ 触发是在【抓包进行中】发出去的，这正是我们要的：
      固件在 S 之后还有 ~10 s 的 lead tick 才吐第一帧，
      ⇒ ⚠️ 如果先发触发再开串口，前 10 s 的"静默期"就白等了；
      ⇒ ⭐ 必须先开抓、后发触发，且两者在同一个循环里保证顺序。

════════════════════════════════════════════════════════════════════════════════
⭐⭐ 为什么必须【分块读】而不是逐字节 read(1)（🔴 实测的致命缺陷）

    ⚠️ 本脚本的早期版本用 `ser.read(1)` 逐字节读，好让每个字节都有独立时间戳。
       ⭐ 那个设计在本项目的 【500000 baud】 下是【致命的】：

           一个字节的上线间隔 = 10 bit / 500000 baud = 【20 µs】
           一次 Python `ser.read(1)` 的 syscall + 调度开销 ≈ 【10 ~ 50 µs】

       ⇒ 🔴 开销【大于】字节间隔 ⇒ 读取速度【跟不上】到达速度 ⇒
         驱动侧 RX 缓冲被灌满 ⇒ **整条流被丢掉**（不是丢几个字节，是全丢）。

    🔴 实测证据（同一天、同一硬件、同一接线、同一波特率）：
       · 固件日志证明它确实全吐了（sent=600；一次 200 帧的完整轮次 = 1800 字节）
       · 旧版 `read(1)` 脚本：收到 **0 字节** —— 看起来像"接线错 / 没放水"，白查半天
       · 手工 `ser.read(4096)` + `timeout=0`：收到 **1800 字节 = 恰好 200 帧** ✅
       ⇒ ⭐ 结论：问题出在【读策略】，⛔ 不是硬件、不是固件、不是接线。

    ✅ 修法：**分块读** —— `ser.read(ser.in_waiting or 1)`（或 `read(READ_CHUNK)`），
       仍然带小超时（默认 50 ms）⇒ 循环照旧及时返回，触发照样准时发。

    ⚠️ 精度取舍（⭐ 必须明说）：同一块里的字节【共用一个时间戳】⇒
       块内（亚毫秒级）的先后顺序不再被分辨。
       但本脚本判的是【帧间音乐节奏】—— 量级在【毫秒 ~ 秒】，
       块大小 256~4096 字节在 500k 下只对应 5~82 ms ⇒ 相对节奏量级可忽略，
       pace 判据依然准确（见下方 core 判据）。
       ⚠️ 至于【字节级间隔】的测量（FPGA 侧 GAP_BYTES = 16 字节 = 320 µs @500k），
       ⛔ 那不是本脚本的职责 —— 那个由 `uart_timing_check.py` 负责。

════════════════════════════════════════════════════════════════════════════════
⭐ 帧格式（冻结契约，与 pool_pace_check.py 一致）

    | 帧 = 9 字节 | 头 0xA5 + 8 字节大端 body |

    body 是 64 位大端字，位域（⭐ 冻结，⛔ 不要动）：

        tick   [63:44]  20 bit
        inc    [43:22]  22 bit
        axis   [21:18]   4 bit
        vel    [17:11]   7 bit
        kind   [10:9]    2 bit
        timbre [8]       1 bit
        rsvd   [7:0]     8 bit   ⚠️ 必须为 0

    kind：0=note_on  1=note_off  2=tempo 变化

⚠️ 复位帧：头 0xA5 且 8 个 body 字节【全是 0xA5】⇒ 单独计数，⛔ 不参与节奏统计。

════════════════════════════════════════════════════════════════════════════════
⭐⭐ 核心判据 —— 音乐节奏 pace

    一个 tick 的时长 = 60 / (bpm × ppqn) 秒

        tick_span   = 末帧 tick - 首帧 tick
        应有墙钟    = tick_span × 60 / (bpm×ppqn)
        pace        = 实测墙钟 / 应有墙钟

        ✅ pace ≈ 1.0（±10%）⇒ 固件在【按音乐时间】放水
        🔴 pace ≈ 0          ⇒ 固件把整池【一口气倒完】了
                                ⚠️ 这会静默冲爆 FPGA 侧 8 KB 缓冲

    🔴 为什么 pace 是关键：固件"放出来"和"放对节奏"是两回事。
       帧数对、帧头对、9N 对齐 —— ⛔ 全都不能证明节奏对。
       ⭐ 只有 pace 能把"按音乐时间限流"和"能多快就多快"区分开。

════════════════════════════════════════════════════════════════════════════════
⭐ 用法

    python trigger_and_capture.py --port COM31
    python trigger_and_capture.py --port COM31 --seconds 60 --trigger S
    python trigger_and_capture.py --port COM31 --seconds 45 --bpm 168
    python trigger_and_capture.py --port COM31 --save raw.bin --dump 20
    python trigger_and_capture.py --port COM31 --trigger X      # 停止
    python trigger_and_capture.py --port COM31 --trigger R      # 复位

返回码：0 = 节奏合格；1 = 判据不合格；2 = 缺 pyserial；3 = 串口错误；4 = 0 字节
════════════════════════════════════════════════════════════════════════════════
"""

import argparse
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK / 代码页 936，会炸）---------------
# ⭐ 本脚本要打印 emoji 和中文 ⇒ 这一步是【必须】的，⛔ 不是可选项。
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HDR_EVENT = 0xA5

# ⭐ 分块读的块上限（⛔ 见文件头"为什么必须分块读"：read(1) 在 500k 下会丢整条流）
#    ⚠️ 只是 in_waiting 拿到 0 时的兜底读取量，正常路径由 in_waiting 决定。
READ_CHUNK = 4096

# ---- 冻结契约的位域（⚠️ 改了这里就等于改了协议）------------------------------
B_TICK_MSB = 64
B_TICK_LSB = 44
B_INC_MSB = 43
B_INC_LSB = 22
B_AXIS_MSB = 21
B_AXIS_LSB = 18
B_VEL_MSB = 17
B_VEL_LSB = 11
B_KIND_MSB = 10
B_KIND_LSB = 9
B_TIMBRE_BIT = 8
B_RSVD_MSB = 7
B_RSVD_LSB = 0

KIND_NAME = {0: "note_on", 1: "note_off", 2: "tempo", 3: "kind3"}

# ---- 判据门限 ----------------------------------------------------------------
PACE_LO = 0.90          # ⭐ pace 允许带：±10%
PACE_HI = 1.10
TRIGGER_CHARS = ("S", "X", "R")     # ⭐ 固件认的三个字符


# ══════════════════════════════════════════════════════════════════════════════
# 小工具
# ══════════════════════════════════════════════════════════════════════════════
def stats(vals):
    """返回 (min, p50, p90, p99, max)，空表返回 None。"""
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)

    def pct(p):
        i = int(round((n - 1) * p))
        return s[max(0, min(n - 1, i))]

    return s[0], pct(0.50), pct(0.90), pct(0.99), s[-1]


def fmt5(st, unit, nd=2):
    """把 stats() 的 5 元组格式化。"""
    if st is None:
        return "  (无数据)"
    return ("min=%.*f  p50=%.*f  p90=%.*f  p99=%.*f  max=%.*f %s"
            % (nd, st[0], nd, st[1], nd, st[2], nd, st[3], nd, st[4], unit))


def bits(word, msb, lsb):
    """取 [msb:lsb]（闭区间，含两端，和 verilog 的 [msb:lsb] 同义）。"""
    return (word >> lsb) & ((1 << (msb - lsb + 1)) - 1)


def open_no_reset(port, baud, timeout=0.05):
    """
    ⭐ 打开串口，且【绝不拉 DTR/RTS】—— 这是本项目血泪教训，⛔ 不是洁癖。

    🔴 为什么关键：
        ESP32-S3 的**原生 USB-Serial/JTAG** 端口，DTR/RTS 直接接到芯片的
        EN / BOOT（复位 / 下载模式）⇒ pyserial 默认在 open() 时把 DTR/RTS
        拉低（True 的语义在不同平台相反），**一开串口就把芯片复位掉**。
        CH340 虽然通常没有这条硬连线，但它的 DTR/RTS 同样会驱动到
        ESP32 的 EN/GPIO0 上（很多板子就是这么接的）⇒ 同样的坑。

        ⇒ ⚠️ 一旦复位：水池被清空 / 固件重新启动 ⇒
          ⭐ 我们【刚要抓的那一轮放水就没了】，而且现象上表现为"0 字节"，
          🔴 极易被误判成"接线错 / 固件没放水"，白查半天。

    ⭐ 做法：
        ① 先构造 Serial() 对象【不 open】，把 dtr/rts 置 False（打开前就设好）；
        ② open() 之后再 setDTR(False)/setRTS(False) 各来一次 ——
           ⚠️ 某些驱动在 open() 内部会用自己的默认值覆盖掉我们预置的，
           ⇒ ⭐ 必须【补一刀】，否则预置等于没设。
    """
    import serial

    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.timeout = timeout          # ⭐ 小超时 ⇒ 分块 read() 变成"非阻塞式"轮询
    ser.dtr = False                # ⭐ open 之前就压住，尽可能早
    ser.rts = False
    ser.open()
    ser.setDTR(False)              # ⭐ open 之后再压一次（驱动可能覆盖）
    ser.setRTS(False)
    return ser


# ══════════════════════════════════════════════════════════════════════════════
# ① 采集 + 触发（⭐ 单进程 / 单句柄 / 单线程，本脚本的核心）
# ══════════════════════════════════════════════════════════════════════════════
def capture_with_trigger(port, baud, seconds, trigger, trigger_delay):
    """
    ⭐ 一个循环里【边抓边发】—— 触发在抓包进行中发出去。

    返回 (data, chunks, t_trig, t_start, t_end)：
        data    : bytes
        chunks  : [(end_offset, timestamp), ...] —— ⭐ 每块一个时间戳，
                  end_offset 是该块最后一个字节的【下标 + 1】，列表按
                  end_offset 严格递增 ⇒ 可用二分查任意字节属于哪一块。
        t_trig  : 触发字符【发出时刻】，没发成则 None

    ⭐⭐ 为什么【分块读】而不是逐字节 read(1)（🔴 实测的致命缺陷，详见文件头）：
        500000 baud ⇒ 一个字节每 20 µs 就到；
        而一次 read(1) 的 syscall 开销约 10~50 µs ⇒ 🔴 读得比到得慢 ⇒
        驱动 RX 缓冲溢出 ⇒ **整条流全丢**（现象是"0 字节"，酷似接线错，极易误判）。
        🔴 实测：read(1) 收到 0 字节；read(4096) 收到 1800 字节 = 恰好 200 帧。

    ⚠️ 精度取舍：同一块里的字节【共用一个时间戳】⇒ 块内（亚毫秒级）先后不可分辨。
        但本脚本判的是【帧间音乐节奏】，量级在毫秒~秒 ⇒ 判据依然准确。
        ⚠️ 字节级间隔（FPGA 侧 GAP_BYTES = 16 字节 = 320 µs @500k）
           ⛔ 不是本脚本的职责，那个交给 uart_timing_check.py。
    """
    data = bytearray()
    chunks = []                      # ⭐ [(end_offset, t)，...]，按 end_offset 递增
    t_trig = None
    t_start = time.perf_counter()
    t_end = t_start + seconds
    sent = False

    ser = open_no_reset(port, baud)      # ⚠️ 可能抛异常，由调用方兜
    try:
        try:
            ser.reset_input_buffer()
        except Exception:
            pass                          # ⚠️ 个别驱动/CSP 不支持，⛔ 不该因此失败

        while True:
            now = time.perf_counter()
            if now >= t_end:
                break

            # ---- 发触发（⭐ 只在抓包【进行中】发一次）--------------------
            elapsed = now - t_start
            if (not sent) and elapsed >= trigger_delay:
                payload = trigger.encode("ascii", "replace")
                ser.write(payload)
                ser.flush()                       # ⭐ 确保立刻上线，不做缓冲
                t_trig = time.perf_counter()
                sent = True
                print("  ⭐ [%.3f s] 已发出触发字符 %r (0x%02X) —— 现在开始等放水 ..."
                      % (elapsed, trigger, payload[0] if payload else 0))

            # ---- 分块收（⭐ 小超时 ⇒ 非阻塞式，不会把循环卡住）-----------
            # ⭐ 优先一次把驱动缓冲里【已有的全部】收走 ⇒ 单次 syscall 搬一大块，
            #    读取速率远高于到达速率 ⇒ Rx 缓冲不再溢出（这就是本缺陷的修法）。
            # ⚠️ 缓冲为空时退回 READ_CHUNK：此时 read() 会等满小超时后返回 b""
            #    （与原来的 read(1) 同等的"非阻塞式轮询"语义）⇒ 循环节奏不变。
            try:
                n = ser.in_waiting
            except Exception:
                n = 0
            try:
                b = ser.read(n if n > 0 else READ_CHUNK)
            except Exception:
                b = b""
            if b:
                data += b
                chunks.append((len(data), time.perf_counter()))  # ⭐ 整块共用一个戳
    finally:
        ser.close()          # ⭐ 必须释放，否则下次烧录报 PermissionError(13)
    return bytes(data), chunks, t_trig, t_start, time.perf_counter()


# ══════════════════════════════════════════════════════════════════════════════
# ② 帧解码
# ══════════════════════════════════════════════════════════════════════════════
def decode_frame(buf):
    """9 字节 -> 字段 dict（⛔ 不判合法，判别放在调用方）。"""
    body = int.from_bytes(buf[1:9], "big")
    return {
        "tick": bits(body, B_TICK_MSB, B_TICK_LSB),
        "inc": bits(body, B_INC_MSB, B_INC_LSB),
        "axis": bits(body, B_AXIS_MSB, B_AXIS_LSB),
        "vel": bits(body, B_VEL_MSB, B_VEL_LSB),
        "kind": bits(body, B_KIND_MSB, B_KIND_LSB),
        "timbre": bits(body, B_TIMBRE_BIT, B_TIMBRE_BIT),
        "rsvd": bits(body, B_RSVD_MSB, B_RSVD_LSB),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="⭐ 单进程：向 ESP32 发触发字符(S/X/R) 并同时抓放水帧流，验音乐节奏")
    ap.add_argument("--port", required=True, help="USB-TTL 口，如 COM31")
    ap.add_argument("--baud", type=int, default=500000,
                    help="必须与固件 / FPGA 侧一致（默认 500000）")
    ap.add_argument("--seconds", type=float, default=45.0,
                    help="总抓包窗口秒数（默认 45；⚠️ 固件 S 后有 ~10s 预热）")
    ap.add_argument("--trigger", default="S",
                    help="触发字符：S=开始放水  X=停止  R=复位清池（默认 S）")
    ap.add_argument("--trigger-delay", type=float, default=2.0,
                    help="开串口后等多久再发触发（⭐ 让抓包先稳定，默认 2.0 s）")
    ap.add_argument("--bpm", type=float, default=120.0,
                    help="曲目 BPM（⭐ 判据要用它算 tick 时长，默认 120）")
    ap.add_argument("--ppqn", type=int, default=960,
                    help="每四分音符 tick 数（默认 960）")
    ap.add_argument("--save", default="", help="原始字节另存到该路径")
    ap.add_argument("--dump", type=int, default=8, help="详细打印前 N 帧（默认 8）")
    args = ap.parse_args(argv)

    # 懒加载 pyserial ------------------------------------------------------
    try:
        import serial  # noqa: F401
    except ImportError:
        print("🔴 缺 pyserial —— 请先安装：")
        print("     pip install pyserial")
        return 2

    # ---- 参数自检 ---------------------------------------------------------
    if args.bpm <= 0 or args.ppqn <= 0:
        print("🔴 --bpm / --ppqn 必须为正数")
        return 3
    if args.seconds <= 0:
        print("🔴 --seconds 必须为正数")
        return 3
    if args.trigger_delay < 0:
        print("🔴 --trigger-delay 不能为负数")
        return 3
    trig = args.trigger
    if len(trig) != 1:
        print("⚠️ --trigger 是 %d 个字符，固件只认【单字符】S/X/R ⇒ 只取第一个 %r"
              % (len(trig), trig[:1]))
        trig = trig[:1]
    if trig not in TRIGGER_CHARS:
        print("⚠️ --trigger=%r 不在固件约定的 S/X/R 里 —— 固件可能不认，"
              "但本脚本照发（便于实测其它字符）。" % trig)

    # ---- 音乐时间换算 -----------------------------------------------------
    sec_per_tick = 60.0 / (args.bpm * args.ppqn)       # 120 BPM × 960 => 520.833 µs
    us_per_tick = sec_per_tick * 1e6

    print("=" * 78)
    print("ESP32 放水触发 + 抓包（trigger_and_capture）·  ⭐ 单进程单句柄")
    print("=" * 78)
    print("口 = %-10s 波特率 = %d" % (args.port, args.baud))
    print("触发字符 = %r" % trig)
    print("触发时刻 = 开串口后 %.2f s（⭐ 先开抓，后发触发）" % args.trigger_delay)
    print("曲目 = %.4g BPM × PPQN %d   ⇒  ⭐ 1 tick = %.4f µs"
          % (args.bpm, args.ppqn, us_per_tick))
    print("抓包窗口 = %.1f s" % args.seconds)
    print()
    print("⚠️ 打开串口【不拉 DTR/RTS】—— 避免把 ESP32-S3 复位掉（见 open_no_reset）")
    print()

    # ---- 采集（⭐ 单进程边发边收）-----------------------------------------
    t0 = time.perf_counter()
    try:
        data, chunks, t_trig, t_start, t_stop = capture_with_trigger(
            args.port, args.baud, args.seconds, trig, args.trigger_delay)
    except Exception as exc:
        print("🔴 串口打不开/读失败：%s" % exc)
        print("   排查：① 口对不对（设备管理器）")
        print("        ② 🔴 有没有【别的进程】占着这个口 —— 这正是上一版失败的原因：")
        print("           之前是【两个进程】一个抓、一个发 ⇒ PermissionError(13)。")
        print("           ⭐ 本脚本单进程单句柄，关掉其它串口助手再试。")
        print("        ③ 上一次没 close ⇒ 拔插一次 USB-TTL")
        return 3
    wall_total = time.perf_counter() - t0

    print("-" * 78)
    print("实际抓包 %.3f s，收到 %d 字节" % (wall_total, len(data)))
    if t_trig is not None:
        print("⭐ 触发确认：已发出 %r（t = %.6f，开抓后 %.3f s）"
              % (trig, t_trig, t_trig - t_start))
    else:
        print("🔴 触发【没发出去】！—— 抓包窗口比 --trigger-delay(%.2f s) 还短？"
              % args.trigger_delay)

    # ---- ⭐ 0 字节诊断（有序清单）-----------------------------------------
    if not data:
        print()
        print("=" * 78)
        print("🔴 0 字节 —— 按顺序排查（⭐ 从上往下，先排除最可能的）")
        print("=" * 78)
        if t_trig is None:
            print("  ① 🔴 触发字符【根本没发出去】—— 看上面那句 '触发确认'：")
            print("     ⚠️ --seconds(%.1f) 必须 > --trigger-delay(%.1f)，"
                  % (args.seconds, args.trigger_delay))
            print("        否则循环在发触发之前就结束了。")
        else:
            print("  ① ✅ 触发字符【确实发出去了】（t = %.6f）⇒ 不是触发的问题，往下看："
                  % t_trig)
        print("  ② 🔴 接线【交叉】对不对：")
        print("       ESP32 GPIO17 (TX) ──> USB-TTL **RXD**   ⭐ 我们收")
        print("       ESP32 GPIO18 (RX) <── USB-TTL **TXD**   ⭐ 我们发")
        print("     ⚠️ TX-TX / RX-RX 接反 = 两边都收不到，也是 0 字节。")
        print("  ③ 🔴 【共地】：ESP32 GND ── USB-TTL GND")
        print("     ⚠️ 不共地时经常【能发出、收不到】，或收到满屏乱码。")
        print("  ④ 🔴 波特率【两端必须一致】= %d（--baud）" % args.baud)
        print("     ⚠️ 对不上时通常不是 0 字节而是乱码；0 字节更可能是接线/触发。")
        print("  ⑤ ⭐ 固件在 S 之后有 ~10 s 的 lead tick 【预热】才吐第一帧 ⇒")
        print("     ⚠️ 抓包窗口太短（如 --seconds 5）【合法地】可能一帧都看不到。")
        print("     ⇒ ⭐ 建议 --seconds >= 30 再判。")
        print()
        print("  ⭐ 另外：口选对了吗？USB-TTL 是不是插在电脑上（设备管理器有 COM%d）？"
              % 0)
        print("=" * 78)
        return 4

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(args.save, "wb") as f:
            f.write(data)
        print("原始字节已存: %s" % os.path.abspath(args.save))

    # ---- 9N 对齐 + 帧头 ---------------------------------------------------
    print()
    print("---- 9N 对齐 + 帧头 ----")
    rem = len(data) % FRAME_BYTES
    nf = len(data) // FRAME_BYTES
    aligned = (rem == 0)
    print("  总字节 = %d" % len(data))
    print("  9N 对齐: %s（%d 字节 = %d 帧，余 %d）"
          % ("✅" if aligned else "🔴", len(data), nf, rem))
    if not aligned:
        print("     🔴 余数非 0 ⇒ ①抓包从半帧开始的常见原因：触发/复位时机不对；")
        print("        ②真丢字节。⚠️ 下面按 9 字节硬切，结果仅供参考。")

    bad_hdr = [(i, data[i * FRAME_BYTES]) for i in range(nf)
               if data[i * FRAME_BYTES] != HDR_EVENT]
    print("  帧头 0xA5: %d/%d %s" % (nf - len(bad_hdr), nf,
                                    "✅" if not bad_hdr else "🔴"))
    for i, h in bad_hdr[:8]:
        print("     帧 #%-6d 帧头=0x%02X" % (i, h))
    if len(bad_hdr) > 8:
        print("     ... 还有 %d 个" % (len(bad_hdr) - 8))

    # ---- 逐帧解码 ---------------------------------------------------------
    # ⭐⭐ 时间戳查询：从【分块】时间戳表里取某个字节偏移所属块的戳。
    #      chunks = [(end_offset, t), ...]，end_offset 严格递增且是"末字节下标+1"
    #      ⇒ 偏移 k 所属的第一块满足 end_offset > k ⇒ 二分查第一个 end_offset > k。
    #      ⚠️ 块内字节共用该块的时间戳（⭐ 这是分块读的固有取舍，见文件头）。
    def _stamp_at(k):
        if not chunks:
            return 0.0
        if k < 0:
            return chunks[0][1]
        lo, hi = 0, len(chunks)
        while lo < hi:                      # ⭐ 手写二分，⛔ 不依赖 bisect 版本差异
            mid = (lo + hi) // 2
            if chunks[mid][0] > k:
                hi = mid
            else:
                lo = mid + 1
        if lo >= len(chunks):               # ⚠️ 偏移越过已收数据 ⇒ 退到最后一个戳
            return chunks[-1][1]
        return chunks[lo][1]

    events = []          # ⭐ 参与节奏统计的 event 帧
    resets = []          # 复位帧（全 0xA5）
    rsvd_bad = []
    for i in range(nf):
        fr = data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
        if fr[0] != HDR_EVENT:
            continue
        payload = fr[1:9]
        if payload == b"\xA5" * 8:
            resets.append((i, _stamp_at(i * FRAME_BYTES)))   # ⭐ 排除出节奏统计
            continue
        d = decode_frame(fr)
        d["idx"] = i
        d["t"] = _stamp_at(i * FRAME_BYTES)
        events.append(d)
        if d["rsvd"] != 0:
            rsvd_bad.append(d)

    print()
    print("---- 帧分类 ----")
    print("  总帧数 = %d" % nf)
    print("  event 帧 = %d" % len(events))
    print("  复位帧(全0xA5) = %d %s（⭐ 已排除出节奏统计）"
          % (len(resets), "" if not resets else "⚠️"))
    for idx, t in resets[:6]:
        print("     帧 #%-6d t=%s" % (idx, ("%.6f" % t) if t else "?"))
    kc = {0: 0, 1: 0, 2: 0, 3: 0}
    for e in events:
        kc[e["kind"]] = kc.get(e["kind"], 0) + 1
    print("  kind 分布: note_on(0)=%d  note_off(1)=%d  tempo(2)=%d  其它(3)=%d"
          % (kc.get(0, 0), kc.get(1, 0), kc.get(2, 0), kc.get(3, 0)))
    print("  rsvd 非 0: %d %s" % (len(rsvd_bad), "✅" if not rsvd_bad else "🔴"))
    for e in rsvd_bad[:5]:
        print("     帧 #%-6d rsvd=%d" % (e["idx"], e["rsvd"]))

    # ---- 详细打印 ---------------------------------------------------------
    if args.dump and events:
        print()
        print("---- 前 %d 帧明细 ----" % min(args.dump, len(events)))
        print("  %-7s %-10s %-10s %-5s %-4s %-9s %-3s %-5s %s"
              % ("#", "tick", "inc", "axis", "vel", "kind", "tr", "rsvd", "t-rel(s)"))
        t_base = events[0]["t"]
        for e in events[:args.dump]:
            print("  %-7d %-10d %-10d %-5d %-4d %-9s %-3d %-5d %.6f"
                  % (e["idx"], e["tick"], e["inc"], e["axis"], e["vel"],
                     KIND_NAME.get(e["kind"], "?"), e["timbre"], e["rsvd"],
                     e["t"] - t_base))

    if len(events) < 2:
        print()
        print("🔴 event 帧不足 2 个，⛔ 没法算节奏。")
        print("   ⭐ 收到了字节却凑不出 event 帧 ⇒ 多半是帧头/对齐问题，"
              "先看上面的 9N 与帧头两项。")
        print("=" * 78)
        return 1

    # ══════════════════════════════════════════════════════════════════════
    # ⭐⭐ 核心判据：音乐节奏（pace）
    # ══════════════════════════════════════════════════════════════════════
    first, last = events[0], events[-1]
    tick_span = last["tick"] - first["tick"]
    wall_span = last["t"] - first["t"]
    expect_wall = tick_span * sec_per_tick                 # 应有墙钟秒数

    print()
    print("=" * 78)
    print("⭐⭐ 核心判据 · 放水节奏（pace）")
    print("=" * 78)
    print("  首帧: tick=%d  t=%.6f" % (first["tick"], first["t"]))
    print("  末帧: tick=%d  t=%.6f" % (last["tick"], last["t"]))
    print()
    print("  tick_span（音乐时长）   = %d tick" % tick_span)
    print("                          = %.3f 拍 = %.3f 小节(4/4)"
          % (tick_span / float(args.ppqn), tick_span / float(args.ppqn * 4)))
    print("  wall_span（实测墙钟）   = %.6f s" % wall_span)
    print("  expect_wall（应有墙钟） = tick_span × %.6f µs = %.6f s"
          % (us_per_tick, expect_wall))

    pace = (wall_span / expect_wall) if expect_wall > 0 else float("inf")
    ok_pace = (PACE_LO <= pace <= PACE_HI)

    print()
    print("  ⭐⭐ pace = 实测 / 应有 = %.6f   （判据：%.2f ~ %.2f）"
          % (pace, PACE_LO, PACE_HI))
    if ok_pace:
        print("      ✅ 放水节奏【正确】—— 固件在按音乐时间限流")
    elif pace < PACE_LO:
        print("      🔴 放水【过快】—— 比音乐时间快 %.1f 倍 ⇒ 限流没生效"
              % (1.0 / pace if pace > 0 else float("inf")))
        print("         ⚠️ 这就是【一口气倒完】的指纹 ⇒ 会静默冲爆 FPGA 侧 8 KB 缓冲")
    else:
        print("      🔴 放水【过慢】—— 只有应有速度的 %.1f%% ⇒ 卡住了/被饿死"
              % (pace * 100.0))

    if wall_span > 0 and tick_span > 0:
        eff_bpm = tick_span / (wall_span * args.ppqn) * 60.0
        print("      ⭐ 若以实测墙钟为准，等效 BPM = %.4f（名义 %.4g）"
              % (eff_bpm, args.bpm))

    # ---- 相邻 event 帧的墙钟间隔分布 --------------------------------------
    wall_gaps = [events[i + 1]["t"] - events[i]["t"] for i in range(len(events) - 1)]
    print()
    print("---- 相邻 event 帧的墙钟间隔分布 ----")
    print("  墙钟间隔(s): n=%d  %s" % (len(wall_gaps), fmt5(stats(wall_gaps), "s", 6)))
    print("  墙钟间隔(ms): n=%d  %s"
          % (len(wall_gaps), fmt5(stats([g * 1e3 for g in wall_gaps]), "ms", 3)))
    st_g = stats(wall_gaps)
    if st_g:
        print("  ⭐ 该 tick 间隔应有的墙钟 = %.6f ms"
              % (us_per_tick * max(1e-9, tick_span / float(max(1, len(events) - 1))) / 1e3))

    # ══════════════════════════════════════════════════════════════════════
    # ⭐ 最终结论
    # ══════════════════════════════════════════════════════════════════════
    print()
    print("=" * 78)
    print("最终结论")
    print("=" * 78)

    reasons = []
    verdict = True

    if t_trig is not None:
        reasons.append("✅ 触发字符 %r 已发出" % trig)
    else:
        reasons.append("🔴 触发字符 %r 未发出（窗口短于 --trigger-delay）" % trig)
        verdict = False

    if aligned:
        reasons.append("✅ 9N 对齐")
    else:
        reasons.append("🔴 9N 不对齐（余 %d 字节）" % rem)
        verdict = False

    if not bad_hdr:
        reasons.append("✅ 全部帧头 0xA5")
    else:
        reasons.append("🔴 %d 个帧头不是 0xA5" % len(bad_hdr))
        verdict = False

    if not rsvd_bad:
        reasons.append("✅ rsvd 全为 0")
    else:
        reasons.append("🔴 %d 帧 rsvd 非 0（位域串了）" % len(rsvd_bad))
        verdict = False

    if ok_pace:
        reasons.append("✅ 放水节奏 pace=%.4f ∈ [%.2f, %.2f]"
                       % (pace, PACE_LO, PACE_HI))
    else:
        reasons.append("🔴 放水节奏 pace=%.4f 超出 [%.2f, %.2f]"
                       % (pace, PACE_LO, PACE_HI))
        verdict = False

    for r in reasons:
        print("  " + r)

    print()
    if verdict:
        print("  ✅ 放水节奏【合格】：固件按音乐时间（%.4g BPM × PPQN %d）放水，"
              % (args.bpm, args.ppqn))
        print("     pace=%.4f ≈ 1.0，触发→放水整条链路通了。" % pace)
    else:
        print("  🔴 放水节奏【不合格】—— 见上面标红项。")
        if pace < PACE_LO:
            print("     ⭐ 最可能：放水循环【没有按 tick 限流】（能多快就多快），")
            print("        查 pool_pump() 里的 due_tick 计算 / 有没有真正的等待。")
        elif pace > PACE_HI:
            print("     ⭐ 最可能：放水被【饿死/卡住】—— UART 阻塞、或 tick 源太快。")
        if not aligned or bad_hdr:
            print("     ⚠️ 先修对齐/帧头问题，否则节奏结论不可信。")

    # ══════════════════════════════════════════════════════════════════════
    # ⭐⭐ 验收结论（CRITICAL —— ⭐ 判读整轮放水是否成功的唯一口径）
    # ══════════════════════════════════════════════════════════════════════
    print()
    print("=" * 78)
    print("⭐⭐ 验收结论（CRITICAL）")
    print("=" * 78)
    print("  ⭐ 前提：如果固件确实【灌了 200 帧】并真的启动了水池，")
    print("     那么一次【正确的】运行应当把 **200 个 event 帧全部吐出来**。")
    print("     ⇒ 帧数不足 200 本身就说明【中途断了 / 池子没灌满 / 触发没生效】。")
    print()
    print("  ⭐⭐ **通过判据只有一个：pace ≈ 1.0**（±10%%，即 %.2f ~ %.2f）。"
          % (PACE_LO, PACE_HI))
    print("     ✅ pace ≈ 1.0  ⇒ 固件按音乐时间放水，整条链路正确。")
    print("     🔴 pace << 1    ⇒ ⚠️ 固件把整池【一口气倒完】了。")
    print("        🔴 后果：FPGA 侧只有 8 KB 缓冲，帧瞬间灌满 ⇒")
    print("           **静默溢出**：超出部分被丢掉，现象是【少音 / 弹错音】，")
    print("           ⚠️ 而且【不会报任何错】—— 这就是为什么必须用 pace 判它。")
    print()
    print("  ⚠️ 注意：帧数对、帧头对、9N 对齐，⛔ **都不能证明节奏对**；")
    print("     只有 pace 能区分【按音乐时间限流】和【能多快就多快】。")
    print()
    print("  本轮实测：event 帧 = %d 个，pace = %.6f ⇒ %s"
          % (len(events), pace, "✅ 通过" if ok_pace else "🔴 不通过"))
    print("=" * 78)
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
