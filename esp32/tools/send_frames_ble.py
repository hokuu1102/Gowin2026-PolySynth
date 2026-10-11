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

⇒ 本脚本用 bleak 库【直接走 BLE】，绕开虚拟串口和桥工具。

2026-10-01 修正：本文件的位域曾经是【旧的】
============================================
本文件原来自己拼 64 bit 事件字，用的是 2026-09-22 修订【之前】的布局：

    旧： inc<<22(22bit) / axis<<18 / vel 7bit / timbre<<8(1bit)
    新： inc[43:23](21bit) / axis[22:19] / vel[18:11](8bit) / timbre[8:7](2bit)

而 FPGA(rtl/top.v:3594-3616) 与固件(ble/main/pool.c:60-63) 用的都是新布局
=> 本文件发出去的谱面，FPGA 会解出 inc>>1（低一个八度），且 inc 的最低位
   会渗进 axis 字段把轴号污染。

为什么一直没被发现：ESP32 侧固件只读 tick[63:44] 与 kind[10:9]（两个布局
这两个字段恰好相同），而 e2e_accept.py 的判据是 sent/ovf/late/mm 这类
传输层计数，根本不解码 inc/axis/vel/timbre => 错得完全看不出来。

现在位域与帧层常量一律从 score_word 取（唯一真源），本文件不再出现任何
裸的位移常量。

用法
====
    python send_frames_ble.py --events 200              # 合成音阶（通路自测）
    python send_frames_ble.py --hex <events.hex>        # 真谱面（mid2evt.py 的产物）
    python send_frames_ble.py --hex <f> --chunk 180
    python send_frames_ble.py --selftest                # 不需要硬件

真谱面从哪来
============
    FPGA2026/tools/mid2evt.py --in <score.mid> --out-dir <dir>
产出的 `<dir>/events.hex` 就是本脚本 --hex 的输入。
仓库里已有现成的（在 FPGA2026 主仓库的 build/ 下，未入库）：
    FPGA2026/build/score/regen/09_Conjurer/events.hex
    FPGA2026/build/score/regen/6.世界悲(已修订)/events.hex
    FPGA2026/build/score/regen/夜洋风景/events.hex

协议（与 send_frames.py 完全一致，9N 对齐）
=============================================
  载荷 = [复位序列 4 帧][总数帧 1 帧][事件帧 N 帧]   每帧 9 字节
    · 复位标记帧: 9 字节全 0xA5
    · 总数帧:     0x00 + 8 字节大端总事件数
    · 事件帧:     0xA5 + 8 字节事件体（位域见 score_word.py）

UUID（与固件 ble_config.h 一致）
================================
  服务  0xABF0
  写入  0xABF1   ← 本脚本往这里写（ESP32 的 RECV）
  通知  0xABF2   ← 订阅这个才收得到 ESP32 发回的

⚠️ 重要：写入【不需要】订阅 0xABF2；但订阅后才能看到 ESP32 的 notify。
"""

import argparse
import asyncio
import os
import struct
import sys
import time

# --- 控制台 UTF-8（中文 Windows 默认 GBK，会炸）----------------------------
# 实测于 2026-09-30：控制台代码页 936 时，本脚本第一个 print（含非 GBK 字符）
#    就抛 UnicodeEncodeError 直接退出
#    => 与 send_frames.py 同一处理：启动即把 stdout/stderr 重配成 UTF-8。
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ---- 位域与帧层常量：唯一真源在 score_word.py -------------------------------
# 本文件原来自己拼位域（旧布局），2026-10-01 已改为从 score_word 取。
# 这样"两个发送工具位域再次漂移"在结构上不可能发生。
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import score_word as SW          # noqa: E402

FRAME_BYTES   = SW.FRAME_BYTES
HDR_EVENT     = SW.HDR_EVENT
HDR_TOTAL     = SW.HDR_TOTAL
RESET_FRAMES  = SW.RESET_FRAMES

DEV_NAME_HINT = "FPGA2026-Synth"

UUID_SVC  = "0000abf0-0000-1000-8000-00805f9b34fb"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"   # 我们写这里
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"   # 订阅这个
UUID_CMD  = "0000abf3-0000-1000-8000-00805f9b34fb"   # 命令（CMD 0x01 = 清池）


# ============================================================================
# 载荷构造（帧层委托给 score_word，本文件不拼位域）
# ============================================================================
def reset_sequence() -> bytes:
    return SW.reset_sequence(RESET_FRAMES)


def frame_total(n_events: int) -> bytes:
    """总数帧：byte0 = 0x00，byte1..8 = 大端总事件数"""
    return SW.frame_total(n_events)


def fake_song(n_events: int) -> bytes:
    """合成音阶：语义合法、单调递增、无任何 tempo 事件的音符序列。

    为什么假曲谱绝不能含 kind==2 (TEMPO)
    ==================================================================
    2026-09-30 上机实测（ESP32 硬件）确认的缺陷根因：

      旧实现 `kind = i % 4` => 200 个事件里有 50 个 kind==2。
      但冻结契约里 kind 的语义是：
          kind == 0  -> note_on
          kind == 1  -> note_off
          kind == 2  -> TEMPO CHANGE（此时 inc 被重新解释成新的 tick_inc！）
          kind == 3  -> undefined / 未使用

      固件读到 kind==2 时会做两件事：
        1. s_tick_inc = inc       <- 把 inc 当成 tempo 的 tick_inc
        2. 重新锚定时间基准 s_t0_tick = tick; s_t0_us = now

      后果：假曲谱的 inc 只是随便给的一个"相位增量"（~100000），
          被当成 tick_inc 后，每一次 tempo 事件都会把固件的
          【~10 秒 lead ticks 预热】重新计时 => 喂帧节奏被反复打断。
          实测固件日志：
              pool: tempo @tick=1222 -> tick_inc=53900 (time base re-anchored)
          结果：固件只喂出 3 帧就停了，根本发不满 200 帧 =>
              【喂帧节奏 / 时序测试无法通过】。

    => 因此假曲谱必须是【语义合法、单调递增、无任何 tempo 事件的音符序列】。
       请勿"好心"把 kind==2 加回来当"更丰富的测试"——
       它会在硬件上破坏喂帧时序，让 timing 测试永远过不了。

    本实现的取值约定：
      · tick : 1000 + i*37   —— 严格单调递增（测试流程文档依赖首帧 tick==1000）
      · inc  : 常量 164927   —— 音符帧的 inc 是【振荡器相位增量（即音高）】，
                                本来就该是常数；逐事件乱变是没有意义的
      · kind : 偶数 -> note_on(0)，奇数 -> note_off(1)，成对出现
      · axis / vel / timbre 照旧变化（无害，用来锻炼各个位域）
      · 保留位 bit[6:0] 恒为 0（契约要求）
    """
    # 固件 ble_pool / 合成器在 120 BPM 下的默认相位增量。
    NOTE_INC = 164927          # = 固件 BLE_POOL_DEFAULT_TICK_INC @120BPM

    out = bytearray()
    for i in range(n_events):
        word = SW.pack_word(
            tick   = 1000 + i * 37,       # 严格单调递增
            inc    = NOTE_INC,            # 常数（音高），不随 i 变化
            axis   = i % 16,
            vel    = 60 + (i % 60),
            kind   = i % 2,               # 只允许 0/1，绝不产生 2(TEMPO) 或 3
            timbre = i % 2,
        )
        out += SW.frame_from_word(word)
    return bytes(out)


def payload_from_words(words) -> bytes:
    """真谱面整包：复位序列 + 总数帧 + 事件帧。"""
    return SW.build_payload(words)


def build_payload(n_events: int) -> bytes:
    """合成音阶整包（保留给 --events 用）。"""
    return reset_sequence() + frame_total(n_events) + fake_song(n_events)


# ============================================================================
# 自检（不需要硬件）
# ============================================================================
def selftest() -> int:
    print("=" * 66)
    print("send_frames_ble.py 离线自检（不需要硬件）")
    print("=" * 66)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-50s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and bool(cond)

    rs = reset_sequence()
    c1 = len(rs) == FRAME_BYTES * RESET_FRAMES and len(rs) % FRAME_BYTES == 0
    print("① 复位序列 = 36 字节（4 帧），9 的整数倍: %s" % ("OK" if c1 else "RED"))
    ok &= c1

    tf = frame_total(11865)
    val = struct.unpack(">Q", tf[1:])[0]
    c2 = (tf[0] == HDR_TOTAL and val == 11865)
    print("② 总数帧解析回 11865: %s" % ("OK" if c2 else "RED"))
    ok &= c2

    p = build_payload(200)
    c3 = (len(p) == 36 + 9 + 9 * 200) and (len(p) % FRAME_BYTES == 0)
    print("③ 整包 1845 字节，9 的整数倍: %s" % ("OK" if c3 else "RED"))
    ok &= c3

    c4 = len(p) % FRAME_BYTES == 0
    print("④ 9N 对齐（CRC 铁律）: %s" % ("OK" if c4 else "RED"))
    ok &= c4

    # ⑤ 位域往返：本文件产出的帧，必须能被按【FPGA 的切片】解回原值。
    #    这条是本文件 2026-10-01 修正的核心判据。
    song = fake_song(4)
    chk("⑤ 假曲谱 4 帧 = 36 字节", len(song) == 36)
    words = []
    for k in range(4):
        fr = song[k * FRAME_BYTES:(k + 1) * FRAME_BYTES]
        if fr[0] != HDR_EVENT:
            words.append(None)
            continue
        words.append(int.from_bytes(fr[1:], "big"))
    chk("⑤ 每帧帧头都是 0xA5", all(w is not None for w in words))
    if all(w is not None for w in words):
        d0 = SW.unpack_word(words[0])
        chk("⑤ 首帧 tick == 1000（测试流程文档依赖）", d0["tick"] == 1000,
            "  实测 %d" % d0["tick"])
        chk("⑤ 首帧 inc == 164927（相位增量）", d0["inc"] == 164927,
            "  实测 %d" % d0["inc"])
        chk("⑤ 首帧 kind == 0（note_on）", d0["kind"] == SW.KIND_ON,
            "  实测 %d" % d0["kind"])
        chk("⑤ 全部事件保留位为 0", all(SW.reserved_bits(w) == 0 for w in words))
        chk("⑤ 全部事件 kind 只出现 0/1（绝不出现 2=TEMPO）",
            all(SW.unpack_word(w)["kind"] in (SW.KIND_ON, SW.KIND_OFF) for w in words),
            "  实测 kinds=%s" % [SW.unpack_word(w)["kind"] for w in words])
        chk("⑤ tick 严格单调递增",
            all(SW.unpack_word(words[i + 1])["tick"] > SW.unpack_word(words[i])["tick"]
                for i in range(len(words) - 1)))

        # ⑥ 非空洞性：若按【旧布局】打包，FPGA 解出的 inc 必然不是 164927。
        #    这条证明⑤真的能抓住 2026-09-22 那次漂移。
        wrong = (((1000 & SW.MASK_TICK) << SW.OFF_TICK) |
                 ((164927 & SW.OLD_MASK_INC) << SW.OLD_OFF_INC) |
                 ((0 & SW.MASK_AXIS) << SW.OLD_OFF_AXIS) |
                 ((90 & SW.OLD_MASK_VEL) << SW.OFF_VEL) |
                 ((0 & SW.MASK_KIND) << SW.OFF_KIND) |
                 ((0 & SW.OLD_MASK_TIMBRE) << SW.OLD_OFF_TIMBRE))
        chk("⑥ 非空洞：按旧布局打包 => FPGA 解出的 inc != 164927",
            SW.unpack_word(wrong)["inc"] != 164927,
            "  FPGA 会解出 %d" % SW.unpack_word(wrong)["inc"])

    # ⑦ --hex 路径：造一个临时 events.hex，走真加载 -> 真整包
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        hp = os.path.join(td, "t.hex")
        with open(hp, "w", encoding="utf-8") as f:
            f.write("\n".join(["%016X" % SW.pack_word(
                tick=i * 960, inc=164927, axis=i % 16, vel=100,
                kind=i % 2, timbre=0) for i in range(5)]) + "\n")
        hw, hpr = SW.load_events_hex(hp)
        chk("⑦ --hex 路径：读回 5 个字、0 个问题",
            len(hw) == 5 and len(hpr) == 0, "  problems=%s" % hpr)
        hp_payload = payload_from_words(hw)
        chk("⑦ --hex 路径：整包 = 36 + 9 + 5*9 = 90 字节",
            len(hp_payload) == 90, "  实测 %d" % len(hp_payload))
        chk("⑦ --hex 路径：总数帧写的是 5",
            int.from_bytes(hp_payload[36 + 1:36 + 9], "big") == 5)
        chk("⑦ 两种来源的整包【不一样】（证明 --hex 真的换了数据）",
            hp_payload != build_payload(5))

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


# ============================================================================
# BLE 实际发送
# ============================================================================
async def run_ble(payload: bytes, label: str, chunk: int, name: str,
                  scan_to: float, verbose: bool, clear: bool = True) -> int:
    try:
        from bleak import BleakScanner, BleakClient
    except ImportError:
        print("缺 bleak —— 请先 pip install bleak")
        return 2

    n_frames = len(payload) // FRAME_BYTES
    print("曲谱：%s" % label)
    print("总长: %d 字节 = %d 帧" % (len(payload), n_frames))
    print("  复位序列: %d 帧" % RESET_FRAMES)
    print("  总数帧  : 1 帧")
    print("  事件帧  : %d 帧" % (n_frames - RESET_FRAMES - 1))
    print()

    print("扫描 %.1fs 找 \"%s\" ..." % (scan_to, name))
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == name or name in (d.name or ""),
        timeout=scan_to,
    )
    if dev is None:
        print("没找到设备 \"%s\"。" % name)
        print("   常见原因：")
        print("     · 手机/别的中心设备还连着（BLE 一般只允许 1 个连接）")
        print("     · 板子没在广播（查日志有没有 advertising as ...）")
        print("     · 设备名不对（用 --name 指定）")
        return 3

    print("找到: %s  [%s]" % (dev.name, dev.address))

    got_noti = []
    async with BleakClient(dev) as client:
        print("已连接: %s" % client.is_connected)

        # 订阅 0xABF2（收 ESP32 发回的；写入本身不需要它）
        try:
            await client.start_notify(UUID_NOTI,
                                      lambda s, d: got_noti.append(bytes(d)))
            print("已订阅 0xABF2（接收 ESP32 通知）")
        except Exception as e:
            print("订阅 0xABF2 失败（不影响写入）: %s" % e)

        # 连接后稍等，让 MTU 协商与链路稳定
        await asyncio.sleep(1.0)

        # 2026-10-01：灌谱前先清池。
        # 为什么必须显式清：
        #   帧流里的"复位序列"（4 帧全 0xA5）并不清池 —— 固件只拿它把
        #   【本曲事件计数】清零（ble_main.c:925-938），而且它被固件丢弃，
        #   根本到不了 FPGA。实测：不清池连灌两首 => pool 从 200 变 9979
        #   （= 200 + 9779），旧曲残留在池里，起播会把两首混着放。
        #   清池只能走命令特征 0xABF3 的 CMD 0x01（pool_reset + 推屏状态）。
        if clear:
            try:
                await client.write_gatt_char(UUID_CMD, bytes([0x01]),
                                             response=False)
                print("已发 CMD 0x01（清池）")
                await asyncio.sleep(0.8)
            except Exception as e:
                print("CMD 0x01 失败（继续灌，但池里可能残留旧曲）: %s" % e)
        else:
            print("跳过清池（--no-clear）—— 池里会保留已有事件")

        # 分块发送，块大小取 9 的整数倍
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
                print("写入失败（已发 %d/%d）: %s" % (sent, total, e))
                return 4
            sent += n
            if verbose and (sent % (chunk * 10) == 0 or sent == total):
                print("  %6d / %d  (%.1f%%)" % (sent, total, 100.0 * sent / total))
            # 给 ESP32 一点喘息（BLE 吞吐远低于串口）
            await asyncio.sleep(0.005)

        dt = time.time() - t0
        print("发完 %d 字节，用时 %.2f s（%.1f KB/s）"
              % (total, dt, (total / 1024.0) / max(dt, 1e-9)))

        await asyncio.sleep(1.0)
        if got_noti:
            print("收到 ESP32 通知 %d 条，共 %d 字节"
                  % (len(got_noti), sum(len(x) for x in got_noti)))
        try:
            await client.stop_notify(UUID_NOTI)
        except Exception:
            pass

    print()
    print("现在看 ESP32 日志的验收判据：")
    print("   total= 应为 %d" % (n_frames - RESET_FRAMES - 1))
    print("   tf=    应为 1      rst= 应为 4")
    print("   unk= / ovf= / mismatch=  必须恒为 0")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="PC 侧【BLE 直连】给 ESP32 灌曲谱帧（不经串口）")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（不需要硬件）")
    ap.add_argument("--events", type=int, default=200,
                    help="合成音阶的事件数（默认 200）")
    ap.add_argument("--hex", default=None,
                    help="真谱面：读 mid2evt.py 产出的 events.hex（每行 16 位十六进制）")
    ap.add_argument("--chunk", type=int, default=180,
                    help="每次写入字节数（默认 180 = 20 帧，取 9 的整数倍）")
    ap.add_argument("--name", default=DEV_NAME_HINT,
                    help="设备名（默认 %s）" % DEV_NAME_HINT)
    ap.add_argument("--scan-timeout", type=float, default=12.0,
                    help="扫描超时秒数（默认 12）")
    ap.add_argument("--quiet", action="store_true", help="不打印进度")
    ap.add_argument("--clear", dest="clear", action="store_true", default=True,
                    help="灌谱前先发 CMD 0x01 清池（默认开，见 run_ble 里的说明）")
    ap.add_argument("--no-clear", dest="clear", action="store_false",
                    help="不清池（只用于分段追加同一首曲子）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.hex:
        words, problems = SW.load_events_hex(args.hex)
        if not words:
            print("RED: %s 里没读到任何事件字" % args.hex)
            return 5
        if problems:
            print("events.hex 有 %d 个问题：" % len(problems))
            for p in problems[:10]:
                print("   " + p)
            print("   （仍然继续发送，但请先确认这些行是不是真的坏了）")
        sm = SW.summarize(words)
        print("读到 %d 个事件字（tick %s..%s）"
              % (sm["total"], sm["tick_min"], sm["tick_max"]))
        print("   kind 分布: %s" % sm["kinds"])
        label = "%s（真谱面，%d 事件）" % (os.path.basename(args.hex), sm["total"])
        payload = payload_from_words(words)
    else:
        label = "（合成音阶，%d 事件）" % args.events
        payload = build_payload(args.events)

    return asyncio.run(run_ble(payload, label, args.chunk, args.name,
                               args.scan_timeout, not args.quiet, args.clear))


if __name__ == "__main__":
    sys.exit(main())
