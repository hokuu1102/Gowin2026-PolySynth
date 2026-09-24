"""直接收发 FPGA 串口 —— 绕过串口助手，⭐ 把"我发的"和"板子回的"彻底分开。

用法：
    python tools/uart_probe_fpga.py COM31
    python tools/uart_probe_fpga.py COM31 500000
"""
import sys, time, serial, io

# Windows console may default to GBK; force UTF-8 so the Chinese text and the
# star markers do not blow up mid-run.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

port = sys.argv[1] if len(sys.argv) > 1 else "COM31"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 500000

print(f"打开 {port} @ {baud} 8N1 ...")
try:
    ser = serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1, timeout=0.05)
except Exception as e:
    print(f"  FAIL: 打不开 {port}: {e}")
    print("  提示：⭐ 确认串口助手已关闭（⭐ 同一个口不能被两个程序占用）")
    sys.exit(1)

ser.reset_input_buffer()
time.sleep(0.2)
ser.reset_input_buffer()
print("已打开。\n")

CMDS = [
    (b"P", "读 pos（⭐ 8 字节回包 P<ch><pos>CRLF）"),
    (b"P", "再读一次"),
    (b"P", "再读一次"),
    (b"S", "启动 span"),
]

for cmd, desc in CMDS:
    ser.reset_input_buffer()
    print(f"--- 发送 {cmd!r}   ({desc}) ---")
    t0 = time.time()
    ser.write(cmd)
    ser.flush()

    got = bytearray()
    while time.time() - t0 < 1.2:
        d = ser.read(64)
        if d:
            got.extend(d)

    if not got:
        print("    (无回包)")
    else:
        hexs = " ".join(f"{b:02X}" for b in got)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in got)
        print(f"    收到 {len(got)} 字节: {hexs}")
        print(f"    ASCII: {asc}")

        # 尝试解析 P 包
        i = 0
        pkts = []
        while i < len(got) - 7:
            if got[i] == 0x50 and got[i+6] == 0x0D and got[i+7] == 0x0A:
                pkts.append(bytes(got[i:i+8]).decode("ascii", "replace"))
                i += 8
            else:
                i += 1
        if pkts:
            print(f"    ⭐ 解析出的完整 P 包: {pkts}")
    print()

ser.close()
print("完成。")
