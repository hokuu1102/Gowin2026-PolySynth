#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
send_frames_ble.py —— PC 侧【直接走 BLE】给 ESP32 灌曲谱帧

为什么要这个脚本
================
原来的 `send_frames.py` 走【USB-TTL 串口】或【BLE 桥的虚拟串口 COM11】，
而 2026-09-24 上机实测发现：

  · 手机 App      → BLE → ESP32   ✅ 通（ble_rx=9）
  · 桥界面发送框  → BLE → ESP32   ✅ 通（ble_rx=9）
  · 脚本 → COM11  → 桥 → ESP32    🔴 不通（ble_rx=0）

⚠️ 根因：桥工具的 COM11 是"懒连接"的虚拟串口对，
   且不在 pyserial 的端口枚举里（能 open() 但数据不过去）。

⇒ ⭐ 本脚本用 bleak 库【直接走 BLE】，⛔ 绕开虚拟串口和桥工具。

用法
====
    python send_frames_ble.py --events 200
    python send_frames_ble.py --events 200 --chunk 180
    python send_frames_ble.py --selftest          # 不需要硬件

协议（与 send_frames.py 完全一致，⭐ 9N 对齐）
=============================================
  载荷 = [复位序列 4 帧][总数帧 1 帧][事件帧 N 帧]   每帧 9 字节
    · 复位标记帧: 9 字节全 0xA5
    · 总数帧:     0x00 + 8 字节大端总事件数
    · 事件帧:     0xA5 + 8 字节事件体

UUID（与固件 ble_config.h 一致）
================================
  服务  0xABF0
  写入  0xABF1   ← 本脚本往这里写（ESP32 的 RECV）
  通知  0xABF2   ← 订阅这个才收得到 ESP32 发回的

⚠️ 重要：写入【不需要】订阅 0xABF2；但订阅后才能看到 ESP32 的 notify。
"""

import argparse
import asyncio
import struct
import sys
import time

# ---- 与夹具/固件一致的常量 --------------------------------------------------
FRAME_BYTES   = 9
HDR_EVENT     = 0xA5
HDR_TOTAL     = 0x00
RESET_FRAMES  = 4

DEV_NAME_HINT = "FPGA2026-Synth"

UUID_SVC  = "0000abf0-0000-1000-8000-00805f9b34fb"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"   # 我们写这里
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"   # 订阅这个


# ============================================================================
# 载荷构造（⭐ 与 send_frames.py 的算法保持一致）
# ============================================================================
def reset_sequence() -> bytes:
    return bytes([HDR_EVENT]) * (FRAME_BYTES * RESET_FRAMES)


def frame_total(n_events: int) -> bytes:
    """总数帧：byte0 = 0x00，byte1..8 = 大端总事件数"""
    return bytes([HDR_TOTAL]) + struct.pack(">Q", n_events)


def fake_song(n_events: int) -> bytes:
    """
    ⚠️ 假曲谱（与 send_frames.py 同款）。
    事件体 8 字节，⭐ 帧头 0xA5 由调用方拼。
    位域（冻结契约）：
        tick   [63:44]  20 bit
        inc    [43:22]  22 bit
        axis   [21:18]   4 bit
        vel    [17:11]   7 bit
        kind   [10:9]    2 bit
        timbre [8]       1 bit
        rsvd   [7:0]     8 bit（必须 0）
    """
    out = bytearray()
    for i in range(n_events):
        tick = 1000 + i * 37
        inc  = 100000 + (i % 50) * 1300
        axis = i % 16
        vel  = 60 + (i % 60)
        kind = i % 4
        timb = i % 2
        word = ((tick & 0xFFFFF) << 44) | \
               ((inc & 0x3FFFFF) << 22) | \
               ((axis & 0xF) << 18) | \
               ((vel & 0x7F) << 11) | \
               ((kind & 0x3) << 9) | \
               ((timb & 0x1) << 8)
        body = word.to_bytes(8, "big")
        out += bytes([HDR_EVENT]) + body
    return bytes(out)


def build_payload(n_events: int) -> bytes:
    parts = [reset_sequence(), frame_total(n_events), fake_song(n_events)]
    return b"".join(parts)


# ============================================================================
# 自检（⛔ 不需要硬件）
# ============================================================================
def selftest() -> int:
    print("=" * 66)
    print("send_frames_ble.py 离线自检（⛔ 不需要硬件）")
    print("=" * 66)
    ok = True

    rs = reset_sequence()
    c1 = len(rs) == FRAME_BYTES * RESET_FRAMES and len(rs) % FRAME_BYTES == 0
    print("① 复位序列 = 36 字节（4 帧），9 的整数倍: %s" % ("✅" if c1 else "🔴"))
    ok &= c1

    tf = frame_total(11865)
    val = struct.unpack(">Q", tf[1:])[0]
    c2 = (tf[0] == HDR_TOTAL and val == 11865)
    print("② 总数帧解析回 11865: %s" % ("✅" if c2 else "🔴"))
    ok &= c2

    p = build_payload(200)
    c3 = (len(p) == 36 + 9 + 9 * 200) and (len(p) % FRAME_BYTES == 0)
    print("③ 整包 1845 字节，9 的整数倍: %s" % ("✅" if c3 else "🔴"))
    ok &= c3

    c4 = len(p) % FRAME_BYTES == 0
    print("④ 9N 对齐（CRC 铁律）: %s" % ("✅" if c4 else "🔴"))
    ok &= c4

    print()
    print("结论：%s" % ("✅ 全部通过" if ok else "🔴 有失败项"))
    return 0 if ok else 1


# ============================================================================
# BLE 实际发送
# ============================================================================
async def run_ble(n_events: int, chunk: int, name: str, scan_to: float,
                  verbose: bool) -> int:
    try:
        from bleak import BleakScanner, BleakClient
    except ImportError:
        print("🔴 缺 bleak —— 请先 pip install bleak")
        return 2

    payload = build_payload(n_events)
    print("曲谱：(假曲谱, BLE 直发)")
    print("事件数: %d" % n_events)
    print("总长: %d 字节 = %d 帧" % (len(payload), len(payload) // FRAME_BYTES))
    print("  复位序列: %d 帧" % RESET_FRAMES)
    print("  总数帧  : 1 帧（总数 %d）" % n_events)
    print("  事件帧  : %d 帧" % n_events)
    print()

    print("扫描 %.1fs 找 \"%s\" ..." % (scan_to, name))
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == name or name in (d.name or ""),
        timeout=scan_to,
    )
    if dev is None:
        print("🔴 没找到设备 \"%s\"。" % name)
        print("   ⚠️ 常见原因：")
        print("     · 手机/别的中心设备还连着（BLE 一般只允许 1 个连接）")
        print("     · 板子没在广播（⭐ 查日志有没有 advertising as ...）")
        print("     · 设备名不对（用 -Name 指定）")
        return 3

    print("找到: %s  [%s]" % (dev.name, dev.address))

    got_noti = []
    async with BleakClient(dev) as client:
        print("已连接: %s" % client.is_connected)

        # ⭐ 订阅 0xABF2（收 ESP32 发回的；⛔ 写入本身不需要它）
        try:
            await client.start_notify(UUID_NOTI,
                                      lambda s, d: got_noti.append(bytes(d)))
            print("已订阅 0xABF2（接收 ESP32 通知）")
        except Exception as e:
            print("⚠️ 订阅 0xABF2 失败（不影响写入）: %s" % e)

        # ⚠️ 连接后稍等，让 MTU 协商与链路稳定
        await asyncio.sleep(1.0)

        # ⭐ 分块发送，块大小取 9 的整数倍
        chunk = max(FRAME_BYTES, (chunk // FRAME_BYTES) * FRAME_BYTES)
        total = len(payload)
        sent = 0
        t0 = time.time()
        while sent < total:
            n = min(chunk, total - sent)
            piece = payload[sent:sent + n]
            try:
                await client.write_gatt_char(UUID_RECV, piece, response=False)
            except Exception as e:
                print("🔴 写入失败（已发 %d/%d）: %s" % (sent, total, e))
                return 4
            sent += n
            if verbose and (sent % (chunk * 10) == 0 or sent == total):
                print("  %6d / %d  (%.1f%%)" % (sent, total, 100.0 * sent / total))
            # ⭐ 给 ESP32 一点喘息（⚠️ BLE 吞吐远低于串口）
            await asyncio.sleep(0.005)

        dt = time.time() - t0
        print("✅ 发完 %d 字节，用时 %.2f s（%.1f KB/s）"
              % (total, dt, (total / 1024.0) / max(dt, 1e-9)))

        await asyncio.sleep(1.0)
        if got_noti:
            print("⭐ 收到 ESP32 通知 %d 条，共 %d 字节"
                  % (len(got_noti), sum(len(x) for x in got_noti)))
        try:
            await client.stop_notify(UUID_NOTI)
        except Exception:
            pass

    print()
    print("⭐ 现在看 ESP32 日志的验收判据：")
    print("   total= 应为 %d" % n_events)
    print("   tf=    应为 1      rst= 应为 4")
    print("   unk= / ovf= / mismatch=  必须恒为 0")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="PC 侧【BLE 直连】给 ESP32 灌曲谱帧（⛔ 不经串口）")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件）")
    ap.add_argument("--events", type=int, default=200,
                    help="事件数（默认 200）")
    ap.add_argument("--chunk", type=int, default=180,
                    help="每次写入字节数（默认 180 = 20 帧，⭐ 取 9 的整数倍）")
    ap.add_argument("--name", default=DEV_NAME_HINT,
                    help="设备名（默认 %s）" % DEV_NAME_HINT)
    ap.add_argument("--scan-timeout", type=float, default=12.0,
                    help="扫描超时秒数（默认 12）")
    ap.add_argument("--quiet", action="store_true", help="不打印进度")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    return asyncio.run(run_ble(args.events, args.chunk, args.name,
                               args.scan_timeout, not args.quiet))


if __name__ == "__main__":
    sys.exit(main())
