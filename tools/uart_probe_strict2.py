"""严格测试 v2：发送前【把已有数据读干净】（不用 reset_input_buffer，它有竞态）。

关键改动：
  - 发之前先【连续读】直到 200 ms 没有新字节（真正排空）
  - 发之后一直读到【200 ms 静默】为止（而不是固定 1.5 秒）
  - 统计每个包，并检查是否恰好 8 字节
"""
import sys, time, serial, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

port = sys.argv[1] if len(sys.argv) > 1 else "COM32"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 500000

ser = serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1, timeout=0.05)


def drain_until_quiet(gap=0.2, cap=2.0):
    """一直读，直到连续 gap 秒没有新数据。返回读到的字节。"""
    out = bytearray()
    t_last = time.time()
    t0 = time.time()
    while time.time() - t0 < cap:
        d = ser.read(64)
        if d:
            out.extend(d)
            t_last = time.time()
        elif time.time() - t_last > gap:
            break
    return bytes(out)


time.sleep(0.3)
pre = drain_until_quiet()
print(f"端口 {port} @ {baud}")
print(f"启动时排空: {len(pre)} 字节  {'(有残留!)' if pre else '(干净)'}")
print()

print("=== 发 6 次 'P'，每次读到 200ms 静默为止 ===")
ok = 0
for k in range(6):
    pre = drain_until_quiet()
    if pre:
        print(f"  #{k} 发送前有 {len(pre)} 字节残留: "
              f"{''.join(chr(b) if 32<=b<127 else '.' for b in pre)}")

    ser.write(b"P")
    ser.flush()
    got = drain_until_quiet(gap=0.2, cap=2.0)

    asc = "".join(chr(b) if 32 <= b < 127 else "." for b in got)
    hexs = " ".join(f"{b:02X}" for b in got)
    status = "OK " if len(got) == 8 and got[0] == 0x50 and got[-2:] == b"\r\n" else "!! "
    if status == "OK ":
        ok += 1
    print(f"  [{status}] #{k}: {len(got)}B  {hexs}")
    print(f"           |{asc}|")

print()
print(f"=== 结果: {ok}/6 个包是完美的 8 字节 ===")

# 再测一次：连发 2 次不等（压力测试）
print()
print("=== 压力测试: 连发 2 次 'P'（不等），再读 ===")
drain_until_quiet()
ser.write(b"PP")
ser.flush()
got = drain_until_quiet(gap=0.3, cap=3.0)
asc = "".join(chr(b) if 32 <= b < 127 else "." for b in got)
print(f"  收到 {len(got)} 字节: {asc!r}")
print(f"  ⭐ 期望 16 字节（两个包）⇒ {'✅ 对' if len(got)==16 else '⚠️ 不是 16'}")

ser.close()
