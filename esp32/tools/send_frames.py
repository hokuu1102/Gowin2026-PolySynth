#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
send_frames.py -- 把曲谱事件帧灌给 ESP32（PC 侧的"假 FPGA"发送工具）

================================================================================
项目：FPGA2026 · ESP32 通路
用途：在没有 FPGA 的情况下，用 PC 直接把帧流发给 ESP32 验证
      （也可以反过来当"PC 侧发送端"的原型）
================================================================================

协议（本脚本实现的就是这个）
--------------------------------------------------------------------------------
ESP32 期望的 9 字节块有三种，靠【帧头】区分（不是靠位置）：

  1) 帧头 = 0xA5  => 事件帧      => ESP32 转发给 FPGA
  2) 帧头 = 0x00  => 总数帧      => ESP32 自己留下（解析成"总事件数"）
  3) 全 9 字节 = 0xA5 => 复位标记 => ESP32 丢弃（与 FPGA 侧同定义）

为什么总数帧用 0x00：事件帧帧头是 0xA5 => 永不撞车
为什么总数帧也是 9 字节：ESP32 的 9N 对齐逻辑一行都不用改

发送顺序（本脚本的默认行为）
--------------------------------------------------------------------------------
  [36 字节全 0xA5]  复位序列（4 帧）— 只清【固件的本曲事件计数】
  [00 + 8字节总数]  总数帧     — 让屏上的进度条/百分比能工作
  [0xA5 + 8字节]xN  事件帧     — 真正的曲谱数据

2026-10-01 更正：复位序列【不清池】，也【到不了 FPGA】
--------------------------------------------------------------------------------
实测（esp32/ble/main/ble_main.c:925-938）：固件收到全 0xA5 帧时只做两件事 ——
  s_reset_frames_rx++           （计数，屏/STAT 里的 rst）
  s_song_events_rx = 0          （清【本曲】事件计数，防屏上跨曲累加）
然后 `continue`（丢弃，不转发）。
=> 它既不会清 ESP32 的池，也不会到达 FPGA，所以不可能"清 FPGA 侧状态"
   （本文件原先是这么写的，该说法已作废）。

实测证据：不清池连灌两首 => `pool` 从 200 变 9979（= 200 + 9779），旧曲残留在池里。

要清池必须走【命令特征 0xABF3 的 CMD 0x01】：
  · BLE 路：`send_frames_ble.py` 默认就会先发（`--clear`；`--no-clear` 可关，
    只用于分段追加同一首曲子）
  · 串口路：本脚本【做不到】—— 它写的是数据流，没有命令通道

注意：三种块【都要】按 9 的整数倍发（这是本通路最核心的纪律）：
   ESP32 只凑够完整一帧才转发 => 发半帧会让它对不齐。

2026-10-01 修正两处
--------------------------------------------------------------------------------
1) 删掉了 `--song` 这个【死参数】。
   它原来只出现在 `print("曲谱: %s" % (args.song or "(假曲谱)"))` 里，
   而组包那一行永远是 `build_demo_song(args.events)`
   => 名字看起来能选曲，实际上永远发合成音阶。
   现在换成真正生效的 `--hex <events.hex>`。

2) 位域与帧层常量改为从 score_word 取（唯一真源）。
   本文件的 `make_event` 本来就是新布局（inc<<23 / axis<<19 / vel 8bit /
   timbre<<7），但自检里把六个偏移【又硬编码了一遍】=> 下次漂移时
   自检会跟着一起错。现在自检也用 score_word 解包。

用法
================================================================================
  # 1) 离线自检（不需要硬件）—— 生成文件并检查格式
  python send_frames.py --selftest

  # 2) 发给 ESP32（USB-TTL 接 ESP32 的 UART1 RX）
  python send_frames.py --port COM7 --hex build/score/regen/09_Conjurer/events.hex

  # 3) 发合成音阶（通路自测，不需要真谱面）
  python send_frames.py --port COM7 --events 200

  # 4) 只发帧不做限速（模式 B 就是这样：一口气灌完）
  python send_frames.py --port COM7 --hex <f> --full-speed

真谱面从哪来：FPGA2026/tools/mid2evt.py 产出的 events.hex。

注意：波特率默认 500000（500 kbps）—— 必须与 ESP32 的 BLE_BAUD 一致。
      （2026-09-30 起两侧统一 500 k；原写 1000000 已作废）

本脚本【不】碰 tools/ 目录（那是 FPGA 侧的），它是 ESP32 侧的自备工具。
"""

import argparse
import os
import sys
import time

# --- 控制台 UTF-8（中文 Windows 默认 GBK，会炸）----------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ---- 位域与帧层常量：唯一真源在 score_word.py -------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import score_word as SW          # noqa: E402

FRAME_BYTES = SW.FRAME_BYTES
HDR_EVENT = SW.HDR_EVENT
HDR_TOTAL = SW.HDR_TOTAL

# 复位序列 = 9 的整数倍（36 = 4x9）
RESET_FRAMES = SW.RESET_FRAMES

# ESP32 侧的默认波特率（必须与 BLE_BAUD / BRIDGE_BAUD / FPGA 侧一致）
# 500000（500 kbps）—— 2026-09-30 起两侧统一档位
#    依据：FPGA 侧 top.v:702/945 已是 .BAUD_DIV(100) = 500 k（2026-09-24 改），
#    且用户实测 1 Mbps 经常出问题、500 k 比较稳定。
DEFAULT_BAUD = 500000


# ============================================================================
# 帧构造
# ============================================================================
def frame_from_event_bytes(payload8: bytes) -> bytes:
    """9 字节事件帧 = 0xA5 + 8 字节载荷（大端）"""
    assert len(payload8) == 8, "载荷必须 8 字节"
    return bytes([HDR_EVENT]) + payload8


def frame_total(total: int) -> bytes:
    """总数帧 = 0x00 + 8 字节大端总数

    为什么单独一个帧头：让 ESP32 能一眼区分"这是总数不是事件"，
    而不必去猜某个位置的语义。
    """
    return SW.frame_total(total)


def reset_sequence() -> bytes:
    """复位序列 = N 个全 0xA5 帧（长度必须是 9 的整数倍）"""
    return SW.reset_sequence(RESET_FRAMES)


def make_event(tick: int, inc: int, axis: int, vel: int,
               kind: int, timbre: int) -> bytes:
    """按冻结契约拼一个事件帧。

    位域布局的唯一真源是 score_word.py（与 FPGA2026/rtl/top.v:3594-3616 逐位一致）：
        tick[63:44] 20b | inc[43:23] 21b | axis[22:19] 4b |
        vel[18:11] 8b   | kind[10:9] 2b  | timbre[8:7] 2b | [6:0] 保留=0
    """
    return SW.frame_from_word(
        SW.pack_word(tick=tick, inc=inc, axis=axis, vel=vel,
                     kind=kind, timbre=timbre))


# ============================================================================
# 造一个假的曲谱（没有真谱时用来验证通路）
# ============================================================================
def build_demo_song(n_events: int = 200, start_tick: int = 0,
                    tick_step: int = 960):
    """造一段简单旋律：每 tick_step 一个音，音高循环

    这只是"能验证通路"的假数据，不是真曲谱。
    """
    out = bytearray()
    # 五声音阶（听着不难听）
    incs = [0x3B000, 0x42800, 0x4B000, 0x54000, 0x5E000]
    tick = start_tick
    for i in range(n_events):
        out += make_event(
            tick=tick % (1 << 20),
            inc=incs[i % len(incs)],
            axis=(i % 8),
            vel=100,
            kind=0 if (i % 2 == 0) else 1,   # 0=on 1=off 交替
            timbre=0,
        )
        tick += tick_step
    return bytes(out)


# ============================================================================
# 离线自检
# ============================================================================
def selftest() -> int:
    print("=" * 66)
    print("send_frames.py 离线自检（不需要硬件）")
    print("=" * 66)

    ok = True

    # --- ① 复位序列必须是 9 的整数倍 ---------------------------------------
    rs = reset_sequence()
    c1 = (len(rs) % FRAME_BYTES == 0)
    print("\n① 复位序列长度 = %d 字节（%d 帧）  9 的整数倍: %s"
          % (len(rs), len(rs) // FRAME_BYTES, "OK" if c1 else "RED"))
    ok &= c1

    # --- ② 总数帧格式 -------------------------------------------------------
    tf = frame_total(11865)
    c2 = (len(tf) == FRAME_BYTES and tf[0] == HDR_TOTAL
          and int.from_bytes(tf[1:], "big") == 11865)
    print("② 总数帧 = %s  -> 解析回 %d  %s"
          % (tf.hex(" ").upper(), int.from_bytes(tf[1:], "big"),
             "OK" if c2 else "RED"))
    ok &= c2

    # --- ③ 事件帧帧头必须是 0xA5，不能和总数帧撞 ---------------------------
    ev = make_event(tick=1234, inc=164927, axis=3, vel=100, kind=0, timbre=1)
    c3 = (len(ev) == FRAME_BYTES and ev[0] == HDR_EVENT)
    print("③ 事件帧 = %s  -> 帧头 0x%02X  %s"
          % (ev.hex(" ").upper(), ev[0], "OK" if c3 else "RED"))
    ok &= c3

    # --- ④ 位域往返：拼进去的字段必须能按【FPGA 的切片】原样取回 ------------
    #     2026-10-01：原来这里把六个偏移硬编码了一遍 => 位域漂移时自检会
    #     跟着一起错。现在统一用 score_word.unpack_word 解。
    word = int.from_bytes(ev[1:], "big")
    d = SW.unpack_word(word)
    c4 = (d["tick"] == 1234 and d["inc"] == 164927 and d["axis"] == 3
          and d["vel"] == 100 and d["kind"] == 0 and d["timbre"] == 1)
    print("④ 位域往返 tick=%d inc=%d axis=%d vel=%d kind=%d timbre=%d  %s"
          % (d["tick"], d["inc"], d["axis"], d["vel"], d["kind"], d["timbre"],
             "OK" if c4 else "RED"))
    ok &= c4

    # --- ⑤ 保留位必须为 0（契约硬要求）-------------------------------------
    c5 = (SW.reserved_bits(word) == 0)
    print("⑤ 保留位 [6:0] = 0x%02X（必须 0）  %s"
          % (SW.reserved_bits(word), "OK" if c5 else "RED"))
    ok &= c5

    # --- ⑥ 帧头【不撞车】：事件帧头与总数帧头必须不同 ----------------------
    c6 = (HDR_EVENT != HDR_TOTAL)
    print("⑥ 帧头不撞车：事件 0x%02X vs 总数 0x%02X  %s"
          % (HDR_EVENT, HDR_TOTAL, "OK" if c6 else "RED"))
    ok &= c6

    # --- ⑦ 假曲谱整体长度 ---------------------------------------------------
    song = build_demo_song(200)
    c7 = (len(song) == 200 * FRAME_BYTES)
    print("⑦ 假曲谱 200 事件 = %d 字节（应为 %d）  %s"
          % (len(song), 200 * FRAME_BYTES, "OK" if c7 else "RED"))
    ok &= c7

    # --- ⑧ 整包长度必须是 9 的整数倍（最关键）------------------------------
    pkt = rs + tf + song
    c8 = (len(pkt) % FRAME_BYTES == 0)
    print("⑧ 整包 %d 字节，9 的整数倍: %s" % (len(pkt), "OK" if c8 else "RED"))
    ok &= c8

    # --- ⑨ 非空洞性：旧布局必须能被抓出来 ---------------------------------
    #     2026-10-01 加的。这一条是"位域唯一真源"这个改动存在的理由：
    #     若按 2026-09-22 修订【之前】的布局打包，FPGA 读到的 inc 会差一倍。
    wrong = (((1234 & SW.MASK_TICK) << SW.OFF_TICK) |
             ((164927 & SW.OLD_MASK_INC) << SW.OLD_OFF_INC) |
             ((3 & SW.MASK_AXIS) << SW.OLD_OFF_AXIS) |
             ((100 & SW.OLD_MASK_VEL) << SW.OFF_VEL) |
             ((0 & SW.MASK_KIND) << SW.OFF_KIND) |
             ((1 & SW.OLD_MASK_TIMBRE) << SW.OLD_OFF_TIMBRE))
    dw = SW.unpack_word(wrong)
    c9 = (dw["inc"] != 164927)
    print("⑨ 非空洞：按旧布局打包 => FPGA 解出的 inc != 164927  %s"
          % ("OK" if c9 else "RED"), "  FPGA 会解出 %d" % dw["inc"])
    ok &= c9

    # --- ⑩ --hex 路径：造临时 events.hex，走真加载 -> 真整包 ---------------
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        hp = os.path.join(td, "t.hex")
        with open(hp, "w", encoding="utf-8") as f:
            f.write("\n".join(["%016X" % SW.pack_word(
                tick=i * 960, inc=164927, axis=i % 16, vel=100,
                kind=i % 2, timbre=0) for i in range(5)]) + "\n")
        hw, hpr = SW.load_events_hex(hp)
        c10a = (len(hw) == 5 and len(hpr) == 0)
        print("⑩ --hex 路径：读回 5 个字、0 个问题  %s"
              % ("OK" if c10a else "RED"), "  problems=%s" % hpr)
        ok &= c10a
        hpayload = reset_sequence() + frame_total(len(hw)) + b"".join(
            SW.frame_from_word(w) for w in hw)
        c10b = (len(hpayload) == 36 + 9 + 5 * 9)
        print("⑩ --hex 路径：整包 = 36 + 9 + 5*9 = 90 字节  %s"
              % ("OK" if c10b else "RED"), "  实测 %d" % len(hpayload))
        ok &= c10b
        # 非空洞：--hex 的整包必须与合成音阶的整包【不同】
        c10c = (hpayload != build_demo_song(5))
        print("⑩ 两种来源的整包【不一样】（证明 --hex 真的换了数据）  %s"
              % ("OK" if c10c else "RED"))
        ok &= c10c

    print("\n" + "=" * 66)
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
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
        print("缺 pyserial —— 请先 pip install pyserial")
        return 2

    print("打开 %s @ %d ..." % (port, baud))
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except Exception as e:
        print("打不开串口：%s" % e)
        return 3

    total = len(payload)
    sent = 0
    t0 = time.time()
    try:
        # 分块大小也取 9 的整数倍（避免在块边界切出半帧）
        chunk = (chunk // FRAME_BYTES) * FRAME_BYTES or FRAME_BYTES
        while sent < total:
            n = min(chunk, total - sent)
            ser.write(payload[sent:sent + n])
            sent += n
            if not full_speed:
                # 给 ESP32 一点喘息（模式 A 的"限速"精神；模式 B 不需要）
                time.sleep(0.001)
            if sent % (FRAME_BYTES * 2000) == 0 or sent == total:
                pct = 100.0 * sent / total
                print("  %6d / %d  (%.1f%%)" % (sent, total, pct))
        ser.flush()
    finally:
        ser.close()

    dt = time.time() - t0
    print("发完 %d 字节，用时 %.2f s（%.1f KB/s）"
          % (total, dt, (total / 1024.0) / max(dt, 1e-9)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把曲谱事件帧灌给 ESP32（PC 侧发送工具）")
    ap.add_argument("--port", help="串口号，如 COM7")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help="波特率（默认 %d，必须与 ESP32 一致）" % DEFAULT_BAUD)
    ap.add_argument("--hex", default=None,
                    help="真谱面：读 mid2evt.py 产出的 events.hex（每行 16 位十六进制）")
    ap.add_argument("--events", type=int, default=200,
                    help="合成音阶的事件数（默认 200，仅在没有 --hex 时用）")
    ap.add_argument("--full-speed", action="store_true",
                    help="一口气灌完（模式 B 就该这样）")
    ap.add_argument("--no-total", action="store_true",
                    help="不发总数帧（那屏上进度条会一直是 0）")
    ap.add_argument("--no-reset", action="store_true",
                    help="不发复位序列")
    ap.add_argument("--selftest", action="store_true",
                    help="不需要硬件的离线自检")
    ap.add_argument("--dump", help="把整包写到文件（便于用别的工具发）")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    # --- 取事件字 ---------------------------------------------------------
    if args.hex:
        words, problems = SW.load_events_hex(args.hex)
        if not words:
            print("RED: %s 里没读到任何事件字" % args.hex)
            return 5
        if problems:
            print("events.hex 有 %d 个问题：" % len(problems))
            for p in problems[:10]:
                print("   " + p)
        sm = SW.summarize(words)
        label = "%s（真谱面，%d 事件）" % (os.path.basename(args.hex), sm["total"])
        print("读到 %d 个事件字（tick %s..%s）"
              % (sm["total"], sm["tick_min"], sm["tick_max"]))
        print("   kind 分布: %s" % sm["kinds"])
        song = b"".join(SW.frame_from_word(w) for w in words)
        n_events = len(words)
    else:
        label = "（合成音阶，%d 事件）" % args.events
        song = build_demo_song(args.events)
        n_events = len(song) // FRAME_BYTES

    # --- 组包 -------------------------------------------------------------
    parts = []
    if not args.no_reset:
        parts.append(reset_sequence())
    if not args.no_total:
        parts.append(frame_total(n_events))
    parts.append(song)
    payload = b"".join(parts)

    print("曲谱: %s" % label)
    print("事件数: %d" % n_events)
    print("总长: %d 字节 = %d 帧" % (len(payload), len(payload) // FRAME_BYTES))
    print("  复位序列: %s" % ("不发" if args.no_reset
                              else "%d 帧" % RESET_FRAMES))
    print("  总数帧  : %s" % ("不发（进度条会一直是 0）"
                              if args.no_total else "1 帧（总数 %d）" % n_events))
    print("  事件帧  : %d 帧" % n_events)

    # 硬性自检：整包必须是 9 的整数倍
    if len(payload) % FRAME_BYTES != 0:
        print("RED: 整包不是 9 的整数倍 —— 拒绝发送（会破坏 ESP32 的对齐）")
        return 4

    if args.dump:
        with open(args.dump, "wb") as f:
            f.write(payload)
        print("已写到 %s" % args.dump)

    if not args.port:
        print("\n没给 --port => 只组包不发送。")
        print("   要真发：--port COM7")
        return 0

    return send(args.port, args.baud, payload, args.full_speed)


if __name__ == "__main__":
    sys.exit(main())
