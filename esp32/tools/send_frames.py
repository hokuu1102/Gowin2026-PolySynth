#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
send_frames.py -- 把曲谱事件帧灌给 ESP32（⭐ PC 侧的"假 FPGA"发送工具）

================================================================================
项目：FPGA2026 · ESP32 通路
用途：⭐ **在没有 FPGA 的情况下**，用 PC 直接把帧流发给 ESP32 验证
      （⭐ 也可以反过来当"PC 侧发送端"的原型）
================================================================================

⭐⭐ 协议（本脚本实现的就是这个）
--------------------------------------------------------------------------------
ESP32 期望的 9 字节块有三种，靠【帧头】区分（⛔ 不是靠位置）：

  ① 帧头 = 0xA5  ⇒ ⭐ 事件帧      ⇒ ✅ ESP32 转发给 FPGA
  ② 帧头 = 0x00  ⇒ ⭐ 总数帧      ⇒ ⛔ ESP32 自己留下（解析成"总事件数"）
  ③ 全 9 字节 = 0xA5 ⇒ ⭐ 复位标记 ⇒ ⛔ ESP32 丢弃（⚠️ 与 FPGA 侧同定义）

🔴 为什么总数帧用 0x00：⭐ 事件帧帧头是 0xA5 ⇒ ⛔ **永不撞车**
🔴 为什么总数帧也是 9 字节：⭐ **ESP32 的 9N 对齐逻辑一行都不用改**

⭐⭐ 发送顺序（本脚本的默认行为）
--------------------------------------------------------------------------------
  [36 字节全 0xA5]  复位序列（4 帧）— ⚠️ 清 FPGA 侧状态
  [00 + 8字节总数]  ⭐ 总数帧     — ⭐ 让屏上的进度条/百分比能工作
  [0xA5 + 8字节]×N  ⭐ 事件帧     — 真正的曲谱数据

⚠️ 三种块【都要】按 9 的整数倍发（⭐ 这是本通路最核心的纪律）：
   ESP32 只凑够完整一帧才转发 ⇒ ⚠️ 发半帧会让它对不齐。

================================================================================
用法
================================================================================
  # 1) 离线自检（⛔ 不需要硬件）—— 生成文件并检查格式
  python send_frames.py --selftest

  # 2) 发给 ESP32（USB-TTL 接 ESP32 的 UART1 RX）
  python send_frames.py --port COM7 --song 09_Conjurer

  # 3) 只发帧不做限速（⭐ 模式 B 就是这样：一口气灌完）
  python send_frames.py --port COM7 --full-speed

⚠️ 波特率默认 1000000（1 Mbps）—— ⚠️ 必须与 ESP32 的 BLE_BAUD 一致。

🔴 本脚本【不】碰 tools/ 目录（⭐ 那是 FPGA 侧的），它是 ESP32 侧的自备工具。
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
HDR_TOTAL = 0x00

# ⭐ 复位序列 = 9 的整数倍（36 = 4×9）
RESET_FRAMES = 4

# ESP32 侧的默认波特率（⚠️ 必须与 BLE_BAUD / BRIDGE_BAUD 一致）
DEFAULT_BAUD = 1000000


# ============================================================================
# 帧构造
# ============================================================================
def frame_from_event_bytes(payload8: bytes) -> bytes:
    """⭐ 9 字节事件帧 = 0xA5 + 8 字节载荷（大端）"""
    assert len(payload8) == 8, "载荷必须 8 字节"
    return bytes([HDR_EVENT]) + payload8


def frame_total(total: int) -> bytes:
    """⭐⭐ 总数帧 = 0x00 + 8 字节大端总数

    ⚠️ 为什么单独一个帧头：⭐ 让 ESP32 能【一眼区分】"这是总数不是事件"，
       而不必去猜某个位置的语义。
    """
    return bytes([HDR_TOTAL]) + total.to_bytes(8, "big")


def reset_sequence() -> bytes:
    """⭐ 复位序列 = N 个全 0xA5 帧（⚠️ 长度必须是 9 的整数倍）"""
    return bytes([HDR_EVENT]) * (FRAME_BYTES * RESET_FRAMES)


def make_event(tick: int, inc: int, axis: int, vel: int,
               kind: int, timbre: int) -> bytes:
    """⭐ 按冻结契约拼一个事件帧（⭐ 位域布局见 play_seq接口冻结契约.md §1.1）

    tick[63:44] 20b | inc[43:23] 21b | axis[22:19] 4b |
    vel[18:11] 8b   | kind[10:9] 2b  | timbre[8:7] 2b | [6:0] 保留=0
    """
    word = 0
    word |= (tick   & 0xFFFFF) << 44        # 20 bit
    word |= (inc    & 0x1FFFFF) << 23       # 21 bit
    word |= (axis   & 0xF) << 19            # 4 bit
    word |= (vel    & 0xFF) << 11           # 8 bit
    word |= (kind   & 0x3) << 9             # 2 bit
    word |= (timbre & 0x3) << 7             # 2 bit
    # [6:0] 保留，必须为 0
    return frame_from_event_bytes(word.to_bytes(8, "big"))


# ============================================================================
# 造一个假的曲谱（⭐ 没有真谱时用来验证通路）
# ============================================================================
def build_demo_song(n_events: int = 200, start_tick: int = 0,
                    tick_step: int = 960):
    """⭐ 造一段简单旋律：每 tick_step 一个音，音高循环

    ⚠️ 这只是"能验证通路"的假数据，⛔ 不是真曲谱。
    """
    out = bytearray()
    # 五声音阶（⭐ 听着不难听）
    incs = [0x3B000, 0x42800, 0x4B000, 0x54000, 0x5E000]
    tick = start_tick
    for i in range(n_events):
        out += make_event(
            tick=tick % (1 << 20),
            inc=incs[i % len(incs)],
            axis=(i % 8),
            vel=100,
            kind=0 if (i % 2 == 0) else 1,   # ⭐ 0=on 1=off 交替
            timbre=0,
        )
        tick += tick_step
    return bytes(out)


# ============================================================================
# 离线自检
# ============================================================================
def selftest() -> int:
    print("=" * 66)
    print("send_frames.py 离线自检（⛔ 不需要硬件）")
    print("=" * 66)

    ok = True

    # --- ① 复位序列必须是 9 的整数倍 ---------------------------------------
    rs = reset_sequence()
    c1 = (len(rs) % FRAME_BYTES == 0)
    print("\n① 复位序列长度 = %d 字节（%d 帧）  9 的整数倍: %s"
          % (len(rs), len(rs) // FRAME_BYTES, "✅" if c1 else "🔴"))
    ok &= c1

    # --- ② 总数帧格式 -------------------------------------------------------
    tf = frame_total(11865)
    c2 = (len(tf) == FRAME_BYTES and tf[0] == HDR_TOTAL
          and int.from_bytes(tf[1:], "big") == 11865)
    print("② 总数帧 = %s  → 解析回 %d  %s"
          % (tf.hex(" ").upper(), int.from_bytes(tf[1:], "big"),
             "✅" if c2 else "🔴"))
    ok &= c2

    # --- ③ 事件帧帧头必须是 0xA5，⛔ 不能和总数帧撞 -------------------------
    ev = make_event(tick=1234, inc=164927, axis=3, vel=100, kind=0, timbre=1)
    c3 = (len(ev) == FRAME_BYTES and ev[0] == HDR_EVENT)
    print("③ 事件帧 = %s  → 帧头 0x%02X  %s"
          % (ev.hex(" ").upper(), ev[0], "✅" if c3 else "🔴"))
    ok &= c3

    # --- ④ ⭐ 位域往返：拼进去的字段必须能原样取回 --------------------------
    word = int.from_bytes(ev[1:], "big")
    g_tick = (word >> 44) & 0xFFFFF
    g_inc = (word >> 23) & 0x1FFFFF
    g_axis = (word >> 19) & 0xF
    g_vel = (word >> 11) & 0xFF
    g_kind = (word >> 9) & 0x3
    g_timb = (word >> 7) & 0x3
    c4 = (g_tick == 1234 and g_inc == 164927 and g_axis == 3
          and g_vel == 100 and g_kind == 0 and g_timb == 1)
    print("④ 位域往返 tick=%d inc=%d axis=%d vel=%d kind=%d timbre=%d  %s"
          % (g_tick, g_inc, g_axis, g_vel, g_kind, g_timb, "✅" if c4 else "🔴"))
    ok &= c4

    # --- ⑤ ⭐ 保留位必须为 0（⭐ 契约硬要求）--------------------------------
    c5 = ((word & 0x7F) == 0)
    print("⑤ 保留位 [6:0] = 0x%02X（必须 0）  %s"
          % (word & 0x7F, "✅" if c5 else "🔴"))
    ok &= c5

    # --- ⑥ 帧头【不撞车】：事件帧头与总数帧头必须不同 ----------------------
    c6 = (HDR_EVENT != HDR_TOTAL)
    print("⑥ 帧头不撞车：事件 0x%02X vs 总数 0x%02X  %s"
          % (HDR_EVENT, HDR_TOTAL, "✅" if c6 else "🔴"))
    ok &= c6

    # --- ⑦ 假曲谱整体长度 ---------------------------------------------------
    song = build_demo_song(200)
    c7 = (len(song) == 200 * FRAME_BYTES)
    print("⑦ 假曲谱 200 事件 = %d 字节（应为 %d）  %s"
          % (len(song), 200 * FRAME_BYTES, "✅" if c7 else "🔴"))
    ok &= c7

    # --- ⑧ ⭐ 整包长度必须是 9 的整数倍（⭐ 最关键）------------------------
    pkt = rs + tf + song
    c8 = (len(pkt) % FRAME_BYTES == 0)
    print("⑧ 整包 %d 字节，9 的整数倍: %s" % (len(pkt), "✅" if c8 else "🔴"))
    ok &= c8

    print("\n" + "=" * 66)
    print("结论：%s" % ("✅ 全部通过" if ok else "🔴 有失败项"))
    print("=" * 66)
    return 0 if ok else 1


# ============================================================================
# 主流程
# ============================================================================
def send(port: str, baud: int, payload: bytes, full_speed: bool,
         chunk: int = 512) -> int:
    try:
        import serial  # pyserial
    except ImportError:
        print("🔴 缺 pyserial —— 请先 pip install pyserial")
        return 2

    print("打开 %s @ %d ..." % (port, baud))
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except Exception as e:
        print("🔴 打不开串口：%s" % e)
        return 3

    total = len(payload)
    sent = 0
    t0 = time.time()
    try:
        # ⚠️ 分块大小也取 9 的整数倍（⭐ 避免在块边界切出半帧）
        chunk = (chunk // FRAME_BYTES) * FRAME_BYTES or FRAME_BYTES
        while sent < total:
            n = min(chunk, total - sent)
            ser.write(payload[sent:sent + n])
            sent += n
            if not full_speed:
                # ⚠️ 给 ESP32 一点喘息（⭐ 模式 A 的"限速"精神；模式 B 不需要）
                time.sleep(0.001)
            if sent % (FRAME_BYTES * 2000) == 0 or sent == total:
                pct = 100.0 * sent / total
                print("  %6d / %d  (%.1f%%)" % (sent, total, pct))
        ser.flush()
    finally:
        ser.close()

    dt = time.time() - t0
    print("✅ 发完 %d 字节，用时 %.2f s（%.1f KB/s）"
          % (total, dt, (total / 1024.0) / max(dt, 1e-9)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把曲谱事件帧灌给 ESP32（PC 侧发送工具）")
    ap.add_argument("--port", help="串口号，如 COM7")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help="波特率（默认 %d，⚠️ 必须与 ESP32 一致）" % DEFAULT_BAUD)
    ap.add_argument("--song", default=None,
                    help="曲谱名（Python 侧没有真谱，目前只用于打印）")
    ap.add_argument("--events", type=int, default=200,
                    help="假曲谱事件数（默认 200）")
    ap.add_argument("--full-speed", action="store_true",
                    help="⭐ 一口气灌完（⭐ 模式 B 就该这样）")
    ap.add_argument("--no-total", action="store_true",
                    help="不发总数帧（⚠️ 那屏上进度条会一直是 0）")
    ap.add_argument("--no-reset", action="store_true",
                    help="不发复位序列")
    ap.add_argument("--selftest", action="store_true",
                    help="⛔ 不需要硬件的离线自检")
    ap.add_argument("--dump", help="把整包写到文件（⭐ 便于用别的工具发）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    # --- 组包 -------------------------------------------------------------
    song = build_demo_song(args.events)
    n_events = len(song) // FRAME_BYTES

    parts = []
    if not args.no_reset:
        parts.append(reset_sequence())
    if not args.no_total:
        parts.append(frame_total(n_events))
    parts.append(song)
    payload = b"".join(parts)

    print("曲谱: %s" % (args.song or "(假曲谱)"))
    print("事件数: %d" % n_events)
    print("总长: %d 字节 = %d 帧" % (len(payload), len(payload) // FRAME_BYTES))
    print("  复位序列: %s" % ("⛔ 不发" if args.no_reset
                              else "%d 帧" % RESET_FRAMES))
    print("  总数帧  : %s" % ("⛔ 不发（⚠️ 进度条会一直是 0）"
                              if args.no_total else "1 帧（总数 %d）" % n_events))
    print("  事件帧  : %d 帧" % n_events)

    # ⭐ 硬性自检：整包必须是 9 的整数倍
    if len(payload) % FRAME_BYTES != 0:
        print("🔴 整包不是 9 的整数倍 —— 拒绝发送（⭐ 会破坏 ESP32 的对齐）")
        return 4

    if args.dump:
        with open(args.dump, "wb") as f:
            f.write(payload)
        print("✅ 已写到 %s" % args.dump)

    if not args.port:
        print("\n⚠️ 没给 --port ⇒ 只组包不发送。")
        print("   要真发：--port COM7")
        return 0

    return send(args.port, args.baud, payload, args.full_speed)


if __name__ == "__main__":
    sys.exit(main())
