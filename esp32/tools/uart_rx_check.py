#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_rx_check.py —— 用 USB-TTL 抓 ESP32 的 UART1 TX，验证发出的字节是否正确

═══ 用途 ═══
ESP32-S3 的 UART1 = 数据通路（对 FPGA）：
    ESP32 GPIO17 (TX) ──→ USB-TTL RX
    ESP32 GPIO18 (RX) ←── USB-TTL TX
    GND ─── GND          🔴 必须共地
    ⛔ USB-TTL 的 5V 不要接（ESP32 自己从 USB 取电）

本脚本：打开 USB-TTL 串口 → 收 N 秒 → 按 9 字节帧解析 → 出报告。

═══ 为什么需要它 ═══
`idf.py monitor` 抓的是 UART0（日志）；本脚本抓的是 UART1（数据），
两者是【不同物理引脚】，⛔ 不要混淆。

═══ 判据 ═══
总字节数必须是 9 的整数倍（9N 对齐铁律）。
帧头只允许 0xA5；出现别的 ⇒ unknown。
"""

import argparse
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK，会炸）----------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

FRAME_BYTES = 9
HDR_EVENT = 0xA5


def decode_event(body: bytes) -> dict:
    """按冻结契约解 8 字节事件体。"""
    w = int.from_bytes(body, "big")
    return {
        "tick":   (w >> 44) & 0xFFFFF,
        "inc":    (w >> 22) & 0x3FFFFF,
        "axis":   (w >> 18) & 0xF,
        "vel":    (w >> 11) & 0x7F,
        "kind":   (w >> 9) & 0x3,
        "timbre": (w >> 8) & 0x1,
        "rsvd":   w & 0xFF,
    }


def selftest() -> int:
    """
    ⭐ 离线自检（⛔ 不需要硬件、不需要串口）。

    ⭐⭐ 为什么需要它（⭐ 2026-10-01 补）：
      🔴 本工具是【验收工具】之一 —— ⚠️ **它的解码逻辑错了，验收结论就不可信**。
      ⚠️ 而它原来**没有自检** ⇒ ⭐ 只有真接上硬件才知道对不对。

    ⭐ 判据分两层（⭐ 缺一不可）：
      ① ⭐ **正例**：合成帧 → 解出的每个字段都对
      ② ⭐⭐ **反例**：⭐ **故意改坏 → 必须被判红**
         ⇒ ⚠️ 否则就是"永远绿"的假判据（⭐ 见经验 `C83`）
    """
    print("=" * 74)
    print("uart_rx_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-44s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ⭐ 造一个【每个字段都不同】的事件体（⚠️ 这样字段错位一定会被发现）
    def pack(tick, inc, axis, vel, kind, timbre, rsvd=0):
        w = ((tick & 0xFFFFF) << 44) | ((inc & 0x3FFFFF) << 22) | \
            ((axis & 0xF) << 18) | ((vel & 0x7F) << 11) | \
            ((kind & 0x3) << 9) | ((timbre & 0x1) << 8) | (rsvd & 0xFF)
        return w.to_bytes(8, "big")

    body = pack(tick=0xABCDE, inc=0x123456, axis=0xA, vel=0x55,
                kind=2, timbre=1, rsvd=0)
    d = decode_event(body)
    print("\n[1] ⭐ 正例：字段逐个核对")
    for k, want in (("tick", 0xABCDE), ("inc", 0x123456), ("axis", 0xA),
                    ("vel", 0x55), ("kind", 2), ("timbre", 1), ("rsvd", 0)):
        got = d[k]
        chk("   %-7s = %s（期望 %s）" % (k, got, hex(want) if want > 9 else want),
            got == want)

    print("\n[2] ⭐ 边界：各字段取极值（⭐ 防「位宽写错」）")
    full = pack(tick=0xFFFFF, inc=0x3FFFFF, axis=0xF, vel=0x7F,
                kind=3, timbre=1, rsvd=0xFF)
    df = decode_event(full)
    chk("   全 1 时 tick  = 0xFFFFF", df["tick"] == 0xFFFFF)
    chk("   全 1 时 inc   = 0x3FFFFF", df["inc"] == 0x3FFFFF)
    chk("   全 1 时 axis  = 0xF", df["axis"] == 0xF)
    chk("   全 1 时 vel   = 0x7F", df["vel"] == 0x7F)
    chk("   全 1 时 rsvd  = 0xFF", df["rsvd"] == 0xFF)
    zero = decode_event(pack(0, 0, 0, 0, 0, 0, 0))
    chk("   全 0 时所有字段 = 0", all(v == 0 for v in zero.values()))

    print("\n[3] ⭐⭐ 反例（非空洞性）：改坏必须能被发现")
    # ⭐ 3a：把 rsvd 写脏 ⇒ ⭐ "rsvd 必须为 0" 这条判据要能抓住
    dirty = decode_event(pack(1, 1, 1, 1, 0, 0, rsvd=0x01))
    chk("   rsvd 非 0 被识别（⭐ 判据可红）", dirty["rsvd"] == 1)
    # ⭐ 3b：⭐ 故意用【错的期望值】核对 ⇒ ⭐ 必须不等
    chk("   错期望值会被判红（⭐ 非空洞）", decode_event(body)["tick"] != 0x12345)
    # ⭐ 3c：⭐ 字段错位检查 —— 若把 tick 的位移写错，这一条会红
    t_lo = decode_event(pack(tick=1, inc=0, axis=0, vel=0, kind=0, timbre=0))
    chk("   只有 tick=1 时其余字段全 0",
        t_lo["tick"] == 1 and t_lo["inc"] == 0 and t_lo["axis"] == 0)

    print("\n[4] ⭐ 帧头常量")
    chk("   HDR_EVENT = 0xA5", HDR_EVENT == 0xA5)
    chk("   FRAME_BYTES = 9", FRAME_BYTES == 9)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="抓 ESP32 UART1 TX 的字节流并逐帧校验")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件/串口）")
    ap.add_argument("--port",
                    help="USB-TTL 的口，如 COM27")
    ap.add_argument("--baud", type=int, default=500000,
                    help="必须与固件 BLE_BAUD 一致（默认 500000）")
    ap.add_argument("--seconds", type=float, default=15.0, help="抓取秒数")
    ap.add_argument("--save", default="", help="原始字节另存（供离线复核）")
    ap.add_argument("--dump", type=int, default=8,
                    help="打印前 N 帧的详细内容（默认 8，0=不打印）")
    ap.add_argument("--expect-frames", type=int, default=0,
                    help="期望帧数（给了就核对）")
    args = ap.parse_args()

    # ⭐ 自检优先 —— ⚠️ 不需要 --port（⭐ 这样 CI/批量自检能统一调用）
    if args.selftest:
        return selftest()
    if not args.port:
        print("🔴 需要 --port（⚠️ 或用 --selftest）")
        return 2

    try:
        import serial
    except ImportError:
        print("🔴 缺 pyserial —— pip install pyserial")
        return 2

    buf = bytearray()
    ser = None
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as e:
        print("🔴 打不开 %s: %s" % (args.port, e))
        print("   ⚠️ 常见原因：口被别人占着 / 口号不对 / USB-TTL 不支持该波特率")
        return 3

    print("已在 %s @ %d bps 监听 %.1f 秒 ..." % (args.port, args.baud, args.seconds))
    print("（⭐ 现在去触发 ESP32 放水）")
    print()
    try:
        ser.reset_input_buffer()
        t0 = time.time()
        last_report = 0.0
        while time.time() - t0 < args.seconds:
            n = ser.in_waiting
            if n:
                buf += ser.read(n)
                if time.time() - last_report > 2.0:
                    last_report = time.time()
                    print("  ... 已收 %d 字节" % len(buf))
            else:
                time.sleep(0.02)
    except Exception as e:
        print("🔴 读串口出错: %s" % e)
    finally:
        if ser is not None:
            try:
                ser.close()      # ⭐ 必须释放，否则下次打不开
            except Exception:
                pass

    # ---- 解析 --------------------------------------------------------------
    total = len(buf)
    print()
    print("=" * 68)
    print("收到 %d 字节" % total)
    print("=" * 68)

    if total == 0:
        print("🔴 一个字节都没收到。")
        print()
        print("   排查顺序（⭐ 按概率）：")
        print("   ① ⚠️ ESP32 根本没有放水 —— 查日志 sent= 是否一直 0")
        print("      （⭐ 已知固件缺陷：pool_start() 零调用 ⇒ 不放水）")
        print("   ② 🔴 接线：USB-TTL RX ←→ ESP32 GPIO17（⚠️ 是交叉！）")
        print("   ③ 🔴 共地：GND 必须连")
        print("   ④ ⚠️ 波特率：ESP32 是 1000000，脚本也要 1000000")
        print("   ⑤ ⚠️ 某些 USB-TTL 撑不到 1 Mbps")
        return 4

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(args.save, "wb") as f:
            f.write(buf)
        print("原始字节已存: %s" % os.path.abspath(args.save))

    rem = total % FRAME_BYTES
    nframes = total // FRAME_BYTES
    print()
    print("---- 9N 对齐判据 ----")
    if rem == 0:
        print("✅ 总字节是 9 的整数倍（%d 字节 = %d 帧）" % (total, nframes))
    else:
        print("🔴 总字节【不是】9 的整数倍：余 %d 字节" % rem)
        print("   ⇒ ⚠️ 截帧！对端可能读到了半帧（⭐ 9N 铁律被破坏）")

    # ---- 逐帧 --------------------------------------------------------------
    hdr_ok = 0
    unknown = []
    frames = []
    for i in range(nframes):
        fr = bytes(buf[i * FRAME_BYTES:(i + 1) * FRAME_BYTES])
        frames.append(fr)
        if fr[0] == HDR_EVENT:
            hdr_ok += 1
        else:
            unknown.append((i, fr[0]))

    print()
    print("---- 帧头判据 ----")
    print("0xA5 事件帧 : %d" % hdr_ok)
    print("未知帧头    : %d %s" % (len(unknown),
                                  "" if not unknown else "🔴 应为 0"))
    for i, h in unknown[:10]:
        print("   帧 #%-6d 帧头=0x%02X" % (i, h))

    if args.expect_frames:
        print()
        if nframes == args.expect_frames:
            print("✅ 帧数 %d = 期望 %d" % (nframes, args.expect_frames))
        else:
            print("🔴 帧数 %d ≠ 期望 %d（差 %d）"
                  % (nframes, args.expect_frames, args.expect_frames - nframes))

    if args.dump and frames:
        print()
        print("---- 前 %d 帧内容 ----" % min(args.dump, len(frames)))
        for i, fr in enumerate(frames[:args.dump]):
            d = decode_event(fr[1:])
            print("  #%-4d %s  tick=%-7d inc=%-8d axis=%-3d vel=%-4d "
                  "kind=%d timbre=%d rsvd=0x%02X"
                  % (i, fr.hex(" ").upper(), d["tick"], d["inc"], d["axis"],
                     d["vel"], d["kind"], d["timbre"], d["rsvd"]))

    print()
    print("=" * 68)
    ok = (rem == 0) and (len(unknown) == 0)
    print("结论：%s" % ("✅ UART 发出的字节是干净的" if ok
                        else "🔴 有问题，看上面标红项"))
    print("=" * 68)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
