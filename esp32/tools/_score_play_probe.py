"""一次性探针：灌真谱面 -> 起播 -> 轮询 STAT，验证喂水是否卡在换速事件上。

为什么写成文件（不用 python -c）：PowerShell 的引号转义会把长命令搞坏
（同族 _hmi_probe.py 的教训）。

它验的是什么
------------
pool.c 的喂水门控是：
    lead_end = s_t0_tick + BLE_POOL_LEAD_TICKS
    if (elapsed_ticks > lead_end) { due_tick = s_t0_tick + elapsed_ticks - LEAD; 允许发 }
    else { 本轮一帧都不发 }

而换速（kind==2）事件会把 s_t0_tick 重锚成【该事件的 tick】（pool.c:706），
同时 s_t0_us = now（elapsed_ticks 从 0 重新起算）
=> 门控变成 "elapsed_ticks > 该事件tick + 20000"，在歌曲剩余时间里不可满足
=> 喂水停住。

09_Conjurer 第 2 条 tempo 在 tick=414720（谱面总长 814080，即 51% 处）
=> 预测：sent 停在「tick <= 414720 的事件数」上，即 7445，停约 226 秒。

用法：
    python _score_play_probe.py --hex <events.hex> --minutes 8
"""
import argparse
import asyncio
import os
import re
import sys
import time

import serial
from bleak import BleakClient, BleakScanner

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import score_word as SW          # noqa: E402
from hmi_states_check import Ask   # noqa: E402


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")

# 读屏上控件值：回包【只出现在 COM29 日志里】，⛔ 不走 BLE
# （Ask 的 docstring 里有实测说明；复用它，避免再写一份 get/解析）

UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"
DEV = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
LOG_PORT = "COM29"


def grab(txt, key):
    m = re.search(r"\b%s=(\d+)" % re.escape(key), txt)
    return int(m.group(1)) if m else None


async def read_stat(c):
    """发 CMD 0x02 拉快照，再读 0xABF4。"""
    try:
        await c.write_gatt_char(UUID_CMD, bytes([0x02]), response=False)
    except Exception as e:
        return None, "write 0x02 fail: %s" % e
    await asyncio.sleep(0.6)
    try:
        raw = await c.read_gatt_char(UUID_STAT)
    except Exception as e:
        return None, "read 0xABF4 fail: %s" % e
    return bytes(raw).decode("utf-8", "replace"), None


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex", required=True)
    ap.add_argument("--minutes", type=float, default=8.0)
    ap.add_argument("--interval", type=float, default=20.0)
    ap.add_argument("--no-send", action="store_true",
                    help="不重灌，只起播并轮询（板子里已经有谱面时用）")
    args = ap.parse_args()

    # 先把谱面读进来算预测值
    words, problems = SW.load_events_hex(args.hex)
    ticks = [SW.unpack_word(w)["tick"] for w in words]
    tempos = [(SW.unpack_word(w)["tick"], SW.unpack_word(w)["inc"])
              for w in words if SW.unpack_word(w)["kind"] == SW.KIND_TEMPO]
    print("谱面 %s：%d 事件，tick 0..%d（%.1f s）"
          % (os.path.basename(args.hex), len(words), max(ticks),
             max(ticks) / 1920.003))
    print("tempo 事件：%s" % tempos)
    if problems:
        print("!! events.hex 有 %d 个问题" % len(problems))
    # 第一条【非 0 tick】的 tempo 就是预测的卡点
    stall_tick = next((t for t, _ in tempos if t > 0), None)
    if stall_tick is not None:
        pred = sum(1 for t in ticks if t <= stall_tick)
        print("预测：sent 会停在 %d（tick<=%d 的事件数），"
              "停约 %.0f 秒"
              % (pred, stall_tick, (stall_tick + 20000) / 1920.003))
    else:
        pred = None
        print("本谱面没有非 0 tick 的 tempo => 预测【不会】卡")
    print()

    # 串口只用来抓日志（不读也行，但便于事后核对）
    lg = serial.Serial()
    lg.port = LOG_PORT
    lg.baudrate = 115200
    lg.timeout = 0.1
    lg.dtr = False
    lg.rts = False
    lg.open()
    lg.setDTR(False)
    lg.setRTS(False)
    lg.reset_input_buffer()
    log = bytearray()

    # 注意：这里【不】再起一个自己的读串口任务。
    # U85：同一个串口只能有一个读者 —— 我原来一边跑自己的 pump()、一边让
    # Ask.get() 也去读同一个 COM29，结果 Ask 什么也读不到
    # （实测：屏上 t1/t2 全部显示 "(无回包)"，而屏幕本身是好的）。
    # 现在串口只由 Ask 读，并把它的缓冲区指向 log（见下面 ask.log = log）。

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=15)
    if dev is None:
        print("RED: 没找到 %s" % DEV)
        return 1

    rc = 0
    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        ask = Ask(lg, c)          # 读屏上控件值（回包只出现在 COM29 日志里）
        ask.log = log             # 共用缓冲区 => 串口【单读者】（U85）

        if not args.no_send:
            print(">>> CMD 0x01 清池")
            await c.write_gatt_char(UUID_CMD, bytes([0x01]), response=False)
            await asyncio.sleep(1.0)

            print(">>> 灌谱面（%d 字节）" % len(SW.build_payload(words)))
            payload = SW.build_payload(words)
            chunk = 180
            sent = 0
            t0 = time.time()
            while sent < len(payload):
                n = min(chunk, len(payload) - sent)
                await c.write_gatt_char(UUID_RECV, payload[sent:sent + n],
                                        response=False)
                sent += n
                await asyncio.sleep(0.005)
            print("    发完 %d 字节，%.1f s" % (sent, time.time() - t0))
            await asyncio.sleep(1.5)

        txt, err = await read_stat(c)
        print("灌后 STAT: %s" % (err or " ".join(
            l for l in txt.splitlines() if l.startswith("pool="))))
        if err:
            rc = 2

        print(">>> CMD 0x03 起播")
        await c.write_gatt_char(UUID_CMD, bytes([0x03]), response=False)
        await asyncio.sleep(0.5)

        t_start = time.time()
        hist = []
        print()
        print("%8s %8s %8s %8s %8s %8s %8s   %s" %
              ("t(s)", "sent", "pool", "late", "clamp", "run", "delta",
               "屏上 t1 / t2"))
        prev = None
        stall_since = None
        while time.time() - t_start < args.minutes * 60:
            txt, err = await read_stat(c)
            if err:
                print("  (读 STAT 失败: %s)" % err)
                await asyncio.sleep(args.interval)
                continue
            s = grab(txt, "sent")
            pool = grab(txt, "pool")
            late = grab(txt, "late")
            clamp = grab(txt, "clamp")
            run = grab(txt, "run")
            el = time.time() - t_start
            delta = "-" if prev is None else str(s - prev)
            # 屏上控件值（机器可验，不需要人看屏）。
            # 注意：回包【只出现在 COM29 日志里】，不走 BLE => 用 Ask.get()
            t1 = await ask.get("t1", "txt")
            t2 = await ask.get("t2", "txt")
            s_t1 = t1.decode("utf-8", "replace") if t1 else "(无回包)"
            s_t2 = t2.decode("utf-8", "replace") if t2 else "(无回包)"
            print("%8.0f %8s %8s %8s %8s %8s %8s   t1=%-10s t2=%s"
                  % (el, s, pool, late, clamp, run, delta, s_t1, s_t2))
            hist.append((el, s))
            # 卡住检测：连续 3 次 delta==0
            if prev is not None and s == prev:
                if stall_since is None:
                    stall_since = el
            else:
                stall_since = None
            prev = s
            if run == 0 and len(hist) > 3:
                print(">>> run=0 => 已停（放完或被停）")
                break
            await asyncio.sleep(args.interval)

    lg.close()

    # ---- 结论 ----
    # 判据要盯【冻结】这个现象，不是盯"最终值"。
    # 2026-10-01 实测教训：第一版只比 final 与 pred，结果 final=7478 > pred=7445
    # 就报了 "OK 没有卡住"，而数据里明明有一段 167 秒的 7445 平台。
    # 那正是 C83（探针假绿）的形态：判据没锚在真正的症状上。
    print()
    print("=" * 62)
    print("结论")
    print("=" * 62)
    if hist:
        print("sent 轨迹：%s" % [(int(a), b) for a, b in hist])
        final = hist[-1][1]
        total = len(words)
        # 找最长平台（连续相同的 sent）
        # 注意：若全程【没有】任何平台，内层 while 每轮只圈到 1 个样本，
        # dur 恒为 0.0 => 永不进 if => best_val/best_at 会留在 None
        # => 下面那句 "%.0f" 会 TypeError。
        # 2026-10-01 实测踩到：它恰好只在【结果好】的时候崩（C35 同族：
        # "没有结论"不能被当成异常，必须能正常给出"无平台"这个结论）。
        best_len, best_val, best_at = 0.0, None, 0.0
        i = 0
        while i < len(hist):
            j = i
            while j + 1 < len(hist) and hist[j + 1][1] == hist[i][1]:
                j += 1
            dur = hist[j][0] - hist[i][0]
            if dur > best_len:
                best_len, best_val, best_at = dur, hist[i][1], hist[i][0]
            i = j + 1
        if best_val is None:
            print("最长平台：无（每一轮 sent 都在增长）")
        else:
            print("最长平台：sent 停在 %s，持续 %.0f 秒（从 t=%.0f s 起）"
                  % (best_val, best_len, best_at))
        print("最终 sent = %d / %d（%.1f%%）" % (final, total, 100.0 * final / total))
        if best_len >= 60.0:
            print("RED  => 出现 %.0f 秒的平台 => 换速门控缺陷【已复现】" % best_len)
            if pred is not None and best_val == pred:
                print("        且平台正好落在预测值 %d 上（预测成立）" % pred)
            rc = 3
        elif final >= total:
            print("OK   => 全部 %d 个事件都喂出去了，且无长平台 => 没有卡住" % total)
        elif pred is not None and final > pred:
            print("OK   => sent 越过预测卡点 %d 且无长平台 => 没有卡住" % pred)
        else:
            print("??   => sent=%d，预测卡点 %s（可能还没跑到，或窗口太短）"
                  % (final, pred))
    txt = log.decode("utf-8", "replace")
    tempo_lines = [l.strip() for l in txt.splitlines() if "tempo" in l]
    print("固件日志里的 tempo 行（最多 10 条）：")
    for l in tempo_lines[:10]:
        print("   " + l[:100])
    return rc


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
