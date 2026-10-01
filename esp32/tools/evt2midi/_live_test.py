"""⭐ 真机端到端：把合成帧写进 GPIO18，看 rec_upstream.py 能否录到并转成 MIDI。

⚠️ 这条链路是：CH340 → GPIO18 → ESP32 上行环 → BLE notify → PC 录制
   ⭐ 它验证的是【ESP32 上行环 + BLE 回传 + 录制】这一段。
   ⚠️ FPGA 那一段（G21/G22）还没分配，所以用 PC 代发。
"""
import subprocess
import sys
import time

import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, ".")
from evt2midi import CLK_HZ, T_NOTE_OFF, T_NOTE_ON, TWO32, _mk_frame

OUT = "live.bin"
SECONDS = 18


def inc_for(hz):
    return int(round(hz * TWO32 / CLK_HZ))


def main():
    # ⭐ 造一小段旋律：A4 / C5 / E5
    melody = [(440.0, 200), (523.25, 220), (659.25, 240)]
    rec = bytearray()
    seq = 0
    t = 1000
    step = int(0.3 * CLK_HZ)
    for hz, vel in melody:
        inc = inc_for(hz)
        rec += _mk_frame(T_NOTE_ON, seq, t, 0, inc, vel); seq += 1
        rec += _mk_frame(T_NOTE_OFF, seq, t + step // 2, 0, inc, vel); seq += 1
        t += step
    print("准备写 %d 字节（%d 帧）到 GPIO18" % (len(rec), seq))

    # ① 先启动录制（⭐ 它会连接 + 订阅）
    rec_proc = subprocess.Popen(
        [sys.executable, "rec_upstream.py", "--out", OUT,
         "--seconds", str(SECONDS)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace")

    # ② 等它订阅好
    print("等录制端订阅（约 8 秒）...")
    time.sleep(8)

    # ③ 写字节到 GPIO18
    try:
        s = serial.Serial()
        s.port = "COM31"
        s.baudrate = 500000
        s.timeout = 0.2
        s.dtr = False
        s.rts = False
        s.open()
        s.setDTR(False)
        s.setRTS(False)
        time.sleep(0.3)
        # ⚠️ 分块写（⭐ 别一口气塞，避免驱动缓冲溢出 —— 见 C107）
        for i in range(0, len(rec), 126):      # 126 = 14 × 9
            s.write(rec[i:i + 126])
            s.flush()
            time.sleep(0.05)
        s.close()
        print("已写入 GPIO18")
    except Exception as e:
        print("🔴 写串口失败：%s" % e)
        rec_proc.kill()
        return 1

    # ④ 等录制结束
    out, _ = rec_proc.communicate(timeout=SECONDS + 30)
    print()
    print("--- rec_upstream 输出 ---")
    print(out.strip()[-800:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
