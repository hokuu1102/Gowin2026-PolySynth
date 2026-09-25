"""板载串口交互探针 —— 让我（Agent）能自己驱动 FPGA 板卡做实验。

═══════════════════════════════════════════════════════════════════════════════
⭐ 为什么需要它
═══════════════════════════════════════════════════════════════════════════════
排查 `span`（`'S'`）被拒时，最长的一段弯路是"**让用户手打命令、再把字符贴回来**"：
  · 🔴 用户来不及在标定【进行中】发 `'V'`（`'S'` 几秒就跑完 9 轮）
  · 🔴 人工转述会丢时间信息（⭐ 而"每轮多久"正是区分超时 vs 离散度拒绝的关键）
  · 🔴 一次只能问一个问题，来回极慢

本脚本让 Agent **直接驱动板卡**：
  · ⭐ **能定时发**（例如发 `'S'` 后每 50 ms 连发 `'V'`，⭐ 抓标定进行中的状态）
  · ⭐ **能记时间戳**（⭐ 每个字节到达的时刻 ⇒ ⭐ 算出"每轮多少 ms"）
  · ⭐ **能重复跑**（⭐ 同一实验跑 20 次 ⇒ ⭐ 看稳定性）

═══════════════════════════════════════════════════════════════════════════════
⭐ 用法
═══════════════════════════════════════════════════════════════════════════════
  # ① 单发一条命令，打印回包 + 时间
  python tools/board_probe.py COM32 --send S

  # ② 连发多条（⭐ 用逗号分隔；⭐ `@0.05` = 隔 50 ms）
  python tools/board_probe.py COM32 --send "P,P,P"

  # ③ ⭐⭐ 抓"标定进行中"的状态：发 S 后每 50 ms 发一个 V，共 40 次
  python tools/board_probe.py COM32 --send S --follow V --follow-gap 0.05 --follow-count 40

  # ④ ⭐ 重复实验（⭐ 看稳定性）
  python tools/board_probe.py COM32 --send S --follow V --follow-gap 0.05 --follow-count 20 --repeat 5

  # ⑤ 定时长采样（⭐ 不做别的，只听 3 秒）
  python tools/board_probe.py COM32 --listen 3

═══════════════════════════════════════════════════════════════════════════════
⭐ 输出（⭐ 带【相对时间戳】，⭐ 这是人工转述拿不到的信息）
═══════════════════════════════════════════════════════════════════════════════
  [  0.000] >> S
  [  0.021] << 's' 0x73
  [  0.022] << '0' 0x30
  [  0.023] << '!' 0x21
  ...
  ⇒ ⭐ 一看时间就知道"每轮"多久（⭐ 8 ms = 离散度拒绝；⭐ 1000 ms = 超时）
═══════════════════════════════════════════════════════════════════════════════
"""
import sys
import time
import argparse
import io

import serial

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")


def hexdump(bs):
    return " ".join(f"{b:02X}" for b in bs)


def printable(bs):
    return "".join(chr(b) if 32 <= b < 127 else "." for b in bs)


def main():
    ap = argparse.ArgumentParser(description="板载串口交互探针")
    ap.add_argument("port", nargs="?", default="COM32", help="串口号（默认 COM32）")
    ap.add_argument("--baud", type=int, default=500000, help="波特率（默认 500000）")
    ap.add_argument("--send", default=None,
                    help="要发的命令（⭐ 逗号分隔；⭐ '@x' = 先等 x 秒）")
    ap.add_argument("--follow", default=None,
                    help="⭐ send 之后【周期性】发的命令（⭐ 用于抓进行中的状态）")
    ap.add_argument("--follow-gap", type=float, default=0.05, help="follow 的间隔秒（默认 0.05）")
    ap.add_argument("--follow-count", type=int, default=20, help="follow 发几次（默认 20）")
    ap.add_argument("--repeat", type=int, default=1, help="整个流程重复几次（默认 1）")
    ap.add_argument("--listen", type=float, default=0.0, help="⭐ 只监听这么多秒（不发任何命令）")
    ap.add_argument("--quiet-gap", type=float, default=0.30,
                    help="多久没数据算'静默'（默认 0.30s）")
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, bytesize=8, parity="N",
                        stopbits=1, timeout=0.01)
    t0 = time.time()

    def stamp():
        return time.time() - t0

    def emit(tag, data):
        """⭐ 逐字节打印（⭐ 带时间戳）—— ⭐ 时间戳是本脚本的核心价值"""
        if not data:
            return
        ts = stamp()
        shown = data if len(data) <= 8 else data[:8]
        more = f" ...(+{len(data)-8})" if len(data) > 8 else ""
        print(f"[{ts:7.3f}] {tag} {printable(shown)!r}  {hexdump(shown)}{more}")

    def pump(duration):
        """读 duration 秒内到达的所有字节"""
        end = time.time() + duration
        got = bytearray()
        while time.time() < end:
            d = ser.read(256)
            if d:
                got.extend(d)
                emit("<<", d)
        return bytes(got)

    def drain_until_quiet(gap, cap=3.0):
        out = bytearray()
        t_last = time.time()
        t_start = time.time()
        while time.time() - t_start < cap:
            d = ser.read(256)
            if d:
                out.extend(d)
                emit("<<", d)
                t_last = time.time()
            elif time.time() - t_last > gap:
                break
        return bytes(out)

    print(f"# 端口 {args.port} @ {args.baud} 8N1")
    time.sleep(0.3)
    pre = drain_until_quiet(0.2)
    print(f"# 启动排空: {len(pre)} 字节 {'(有残留)' if pre else '(干净)'}")
    print()

    # ── 模式 0：⭐ 纯监听 ────────────────────────────────────────────────
    if args.listen > 0:
        print(f"# 纯监听 {args.listen} 秒 ...")
        got = pump(args.listen)
        print()
        print(f"# 共收到 {len(got)} 字节: {printable(got)!r}")
        ser.close()
        return

    for rep in range(args.repeat):
        if args.repeat > 1:
            print(f"════════ 第 {rep+1}/{args.repeat} 轮 ════════")
        t_rep = time.time()

        # ── 发 --send（⭐ 支持 '@x' 等待）──────────────────────────────
        if args.send:
            for tok in args.send.split(","):
                tok = tok.strip()
                if not tok:
                    continue
                if tok.startswith("@"):
                    time.sleep(float(tok[1:]))
                    continue
                print(f"[{stamp():7.3f}] >> {tok!r}")
                ser.write(tok.encode("latin-1"))
                ser.flush()
                # ⭐ 默认给一点时间让板子回（⭐ 但要短，否则抓不到进行中状态）
                pump(0.05)

        # ── 周期性发 --follow（⭐⭐ 核心：抓标定【进行中】的状态）────────
        if args.follow:
            print(f"# 开始 follow：每 {args.follow_gap}s 发 {args.follow!r}，共 {args.follow_count} 次")
            for k in range(args.follow_count):
                t_before = time.time()
                ser.write(args.follow.encode("latin-1"))
                ser.flush()
                # ⭐ 读这一小段窗口内的回包（⭐ 不等到静默，⭐ 否则会错过节奏）
                pump(args.follow_gap)
                # ⭐ 防止累积漂移：按"应到时刻"补正
                drift = (t_before + args.follow_gap) - time.time()
                if drift > 0:
                    time.sleep(drift)
            print(f"# follow 结束，再排空 {args.quiet_gap}s")
            drain_until_quiet(args.quiet_gap)

        print(f"# 本轮用时 {time.time()-t_rep:.3f}s")
        print()

    ser.close()


if __name__ == "__main__":
    main()
