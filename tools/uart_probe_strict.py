"""严格测试：发 N 次 'P'，每次等【足够久】（等 FIFO 真的空），看还有没有残留。

用法：python tools/uart_probe_strict.py COM32
"""
import sys, time, serial, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

port = sys.argv[1] if len(sys.argv) > 1 else "COM32"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 500000

ser = serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1, timeout=0.05)
time.sleep(0.3)
ser.reset_input_buffer()

print(f"端口 {port} @ {baud}")
print()

# 关键：每次发之前【先清空并等待】，看有没有"不请自来"的字节
print("=== 阶段 1：不发任何东西，看有没有自发数据（等 1 秒）===")
t0 = time.time()
spont = bytearray()
while time.time() - t0 < 1.0:
    d = ser.read(64)
    if d:
        spont.extend(d)
if spont:
    print(f"  🔴 有 {len(spont)} 字节自发出现: "
          f"{' '.join(f'{b:02X}' for b in spont)}")
    print(f"     ASCII: {''.join(chr(b) if 32<=b<127 else '.' for b in spont)}")
else:
    print("  ✅ 无自发数据")

print()
print("=== 阶段 2：连发 5 次 'P'，每次等 1.5 秒（远超一包时间）===")
for k in range(5):
    ser.reset_input_buffer()
    ser.write(b"P")
    ser.flush()
    t0 = time.time()
    got = bytearray()
    # 等 1.5 秒（8 字节 @500k ≈ 0.16 ms；1.5 秒绝对够）
    while time.time() - t0 < 1.5:
        d = ser.read(64)
        if d:
            got.extend(d)
    hexs = " ".join(f"{b:02X}" for b in got)
    asc = "".join(chr(b) if 32 <= b < 127 else "." for b in got)
    flag = "OK " if len(got) == 8 else f"!! {len(got)}B"
    print(f"  [{flag}] #{k}: {hexs}   |{asc}|")

ser.close()
print()
print("判据：每次应恰好 8 字节，且以 0D 0A 结尾。")
print("     若少于 8 ⇒ FIFO 有残留（包不原子）")
print("     若多于 8 ⇒ 有别的来源在发")
