#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
read_log.py —— 【限时读串口】抓 ESP32 日志（⛔ 不用 idf.py monitor）

为什么要这个脚本
================
`idf.py monitor` 是【交互式终端】，占住终端不退出（要 Ctrl+]）
=> 脚本/自动化抓不到日志。见 esp32/上机指南.md §八 + 问题分析 §5.1。

本脚本：打开串口 -> 收 N 秒 -> 关闭（⭐ 句柄必定释放）。
可选 --reset 用 DTR/RTS 复位板子，从启动头开始抓。

用法
====
    python read_log.py --port COM29 --seconds 8
    python read_log.py --port COM29 --seconds 8 --reset
    python read_log.py --port COM29 --seconds 20 --save ..\\evidence\\x.log

⚠️ 编码：控制台代码页 936(GBK) 时，本脚本强制 UTF-8 输出，
   否则含 emoji 的打印会 UnicodeEncodeError。
"""

import argparse
import inspect
import io
import os
import sys
import time

# --- 控制台 UTF-8（⚠️ 中文 Windows 默认 GBK，会炸）----------------------------
# ⚠️ 与 send_frames.py / send_frames_ble.py 同一处理：启动即重配成 UTF-8。
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def selftest() -> int:
    """
    ⭐ 离线自检（⛔ 不需要硬件、不需要串口）。

    ⚠️⚠️ 老实说清楚：**本文件没有【纯函数】可测**。
        它整体就是「开串口 → 收 N 秒 → 打印 → 关串口」，
        每一行有效逻辑都要真实 COM 口 + 一块 ESP32 板子。

    ⇒ ⭐ 所以本自检是【结构检查】，🔴 **不是行为检查** ——
        它【不能】证明"抓到的日志是对的"。能证明的只有：
          ① 模块能导入、main 可调用（⭐ 没有语法/导入错误）
          ② ⭐ 参数面（--port/--baud/--seconds/--reset/--save）真的存在
          ③ ⭐ 默认值（115200 / 8.0 s / reset=False / save=""）
          ④ ⭐ 「打开串口【不拉 DTR/RTS】」的意图确实写在源码里
             （⚠️ 这是本项目最贵的血泪教训之一：一开串口就把板子复位掉）

    ⭐ 判据两层：① ⭐ 正例（上面四项）② ⭐⭐ 反例（错参数名/错标记必须判红）
    """
    print("=" * 74)
    print("read_log.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    print("⚠️ 注意：本文件无可测纯函数 ⇒ 下面是【结构检查】，⛔ 不是行为检查。")
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ---- ① 模块 / 入口 ----
    print("\n[1] 结构：模块能导入、main 可调用（⭐ 不是行为检查）")
    chk("   模块已成功导入（⭐ 无语法/导入错误）", True)
    chk("   main 存在且可调用", callable(main))

    # ---- ② ⭐ 参数面：⭐ 从【真的 ArgumentParser】里取，⛔ 不是 grep 源码 ----
    # ⭐ 做法：把 parse_args 临时换成"抓住 parser 然后抛异常"的桩，
    #    这样既拿到了【真的】parser 对象，又⛔ 不会真的去开串口。
    print("\n[2] ⭐ 参数面（⭐ 从真实 parser 取，⛔ 不是 grep 源码）")
    cap = {}

    class _Stop(Exception):
        pass

    _real_parse = argparse.ArgumentParser.parse_args

    def _fake_parse(self, *a, **k):
        cap["parser"] = self
        raise _Stop()

    argparse.ArgumentParser.parse_args = _fake_parse
    _err = ""
    try:
        main()
    except _Stop:
        pass
    except SystemExit:
        pass          # ⚠️ 万一它自己先 SystemExit，⛔ 也不该把自检炸掉
    except Exception as e:                       # ⚠️ 兜住：⭐ 崩溃 ≠ 判红
        _err = "%s: %s" % (type(e).__name__, e)
    finally:
        argparse.ArgumentParser.parse_args = _real_parse

    parser = cap.get("parser")
    chk("   调用 main() 抓 parser 时没抛异常", _err == "", "  %s" % _err)
    chk("   捕获到真实的 ArgumentParser（⭐ main() 里确实建了 parser）",
        parser is not None)

    opts = set()
    port_act = None
    if parser is not None:
        for a in parser._actions:
            opts.update(a.option_strings)
            if "--port" in a.option_strings:
                port_act = a

    for o in ("--port", "--baud", "--seconds", "--reset", "--save", "--selftest"):
        chk("   %s 存在" % o, o in opts)
    # ⭐ --port 必须【不再 required】，否则 --selftest 不带口就跑不起来
    chk("   --port 不再是 required（⭐ 自检才能不带口调用）",
        port_act is not None and port_act.required is False)

    # ---- ③ ⭐ 默认值 ----
    print("\n[3] ⭐ 默认值（⭐ 抓真 parser 的默认，⛔ 不是抄注释）")
    ns = None
    if parser is not None:
        try:
            ns = parser.parse_args(["--port", "__SELFTEST__"])
        except SystemExit:
            ns = None
    chk("   能不带 --baud/--seconds 解析成功", ns is not None)
    # ⚠️ 防崩：⭐ 某个参数被删掉时 ns.<名字> 会抛 AttributeError ⇒
    #    ⚠️ 那【不是判红，是崩溃】⇒ ⭐ 统一用 getattr 兜住，让判据老实报 RED。
    def _ns(name, missing="__MISSING__"):
        return getattr(ns, name, missing) if ns is not None else missing

    chk("   --baud 默认 115200（⭐ 日志口，与烧录口无关）",
        _ns("baud") == 115200, "  实测 %s" % (_ns("baud"),))
    chk("   --seconds 默认 8.0", _ns("seconds") == 8.0,
        "  实测 %s" % (_ns("seconds"),))
    chk("   --reset 默认 False（⭐ 默认【不】复位板子）", _ns("reset") is False)
    chk("   --save 默认 空串（⭐ 默认不写文件）", _ns("save") == "")
    chk("   --selftest 默认 False", _ns("selftest") is False)

    # ---- ④ ⭐⭐ 「打开串口不拉 DTR/RTS」的意图确实写在源码里 ----
    print("\n[4] ⭐⭐ 源码里确实写了「打开串口【不拉 DTR/RTS】」")
    print("     （🔴 血泪教训：ESP32-S3 原生 USB-Serial/JTAG 的 DTR/RTS")
    print("       接在复位/启动电路上 ⇒ 一 open() 就把板子复位、池子清空）")
    # ⚠️⚠️ 只取 main() 自己的源码（⭐ 不是整个文件）——
    #    🔴 否则本自检的【check 名字】里就会带上被判据搜索的字面量，
    #       让 "x not in src" 永远为 False（⭐ 自指陷阱，实测踩过）。
    try:
        msrc = inspect.getsource(main)
    except Exception as e:
        msrc = ""
        print("   ⚠️ 取 main() 源码失败：%s" % e)
    chk("   取到 main() 的源码（⭐ 下面几条的前提）", len(msrc) > 0)

    chk("   有 ser.dtr = False（⭐ open 之前就压住）", "ser.dtr = False" in msrc)
    chk("   有 ser.rts = False", "ser.rts = False" in msrc)
    chk("   有 ser.setDTR(False)（⭐ open 之后再补一刀，防驱动覆盖）",
        "ser.setDTR(False)" in msrc)
    chk("   有 ser.setRTS(False)", "ser.setRTS(False)" in msrc)
    chk("   ⭐ DTR/RTS 被设置了不止一次（⭐ 预置 + open 后兜底）",
        msrc.count("setDTR") >= 2 and msrc.count("setRTS") >= 2,
        "  setDTR×%d setRTS×%d" % (msrc.count("setDTR"), msrc.count("setRTS")))
    chk("   --reset 显式复位分支还在（⭐ 会拉 RTS=True）",
        "ser.setRTS(True)" in msrc)
    chk("   有 ser.close()（⭐ 句柄必定释放，否则下次烧录 PermissionError(13)）",
        "ser.close()" in msrc)
    chk("   有 reset_input_buffer()（⭐ 丢掉打开瞬间的残留）",
        "reset_input_buffer()" in msrc)
    # ⭐⭐ 顺序判据（⭐ 这才是本条意图的【真正内容】，⛔ 不是"有没有写"）：
    #     · 「不拉 DTR」必须在 open() 【之前】压住（⭐ 源码注释：尽可能早）
    #     · open() 之后还必须【再补一刀】（⭐ 防驱动用自己的默认值覆盖）
    _i_open = msrc.find("ser.open()")
    _i_dtr = msrc.find("ser.dtr = False")
    _i_setdtr = msrc.find("ser.setDTR(False)")
    chk("   ⭐ ser.dtr=False 在 open() 之前（⭐ '尽可能早'）",
        0 <= _i_dtr < _i_open, "  dtr@%d open@%d" % (_i_dtr, _i_open))
    chk("   ⭐ setDTR(False) 在 open() 之后（⭐ '补一刀'）",
        _i_open >= 0 and _i_setdtr > _i_open,
        "  setDTR@%d open@%d" % (_i_setdtr, _i_open))
    # ⚠️ 关键判据：⛔ 不许出现"打开时就拉高 DTR"的写法
    chk("   没有 'ser.dtr = True'（⭐ 打开时不拉 DTR 的硬要求）",
        "ser.dtr = True" not in msrc)

    # ---- ⑤ ⭐⭐ 反例（非空洞性）：⭐ 判据必须能失败 ----
    print("\n[5] ⭐⭐ 反例：判据必须能失败（⭐ 否则就是'永远绿'的假判据）")
    chk("   错参数名 --portt 不在 parser 里", "--portt" not in opts)
    chk("   错参数名 --no-such-opt 不在 parser 里", "--no-such-opt" not in opts)
    chk("   错参数名 --reset2 不在 parser 里", "--reset2" not in opts)
    # ⭐ 拿【错的期望值】去核 ⇒ ⭐ 必须不等（⭐ 见经验 C83）
    chk("   错期望默认值 9600 会被判红（⭐ 非空洞）",
        ns is not None and _ns("baud") != 9600)
    chk("   错期望默认秒数 30.0 会被判红（⭐ 非空洞）",
        ns is not None and _ns("seconds") != 30.0)
    # ⭐ 子串类判据也必须能失败：⭐ 一个【不存在】的标记串必须找不到
    #    （⚠️ 它证明 "x in msrc" 这种判据【有能力】返回 False）
    chk("   不存在的源码标记找不到（⭐ 'in msrc' 判据能失败）",
        "ser.setDDD(" not in msrc)

    print()
    print("⚠️ 重申：以上全部是【结构检查】。")
    print("   🔴 它【不能】证明抓日志这件事本身是对的 ——")
    print("      那只能靠实机跑一次：python read_log.py --port COMxx --seconds 8")
    print("   ⭐ 但至少：参数面错了 / 代码写崩了 / DTR-RTS 意图被删了，这里会红。")
    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="限时读 ESP32 串口日志（非交互）")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件/串口）")
    ap.add_argument("--port", help="如 COM29")
    ap.add_argument("--baud", type=int, default=115200,
                    help="日志波特率（默认 115200，⭐ 与烧录波特率无关）")
    ap.add_argument("--seconds", type=float, default=8.0, help="读取秒数")
    ap.add_argument("--reset", action="store_true",
                    help="用 DTR/RTS 复位板子，从启动头开始抓")
    ap.add_argument("--save", default="", help="另存到文件（UTF-8）")
    args = ap.parse_args()

    # ⭐ 自检优先 —— ⚠️ 不需要 --port（⭐ 便于批量自检统一调用）
    if args.selftest:
        return selftest()
    if not args.port:
        print("🔴 需要 --port（⚠️ 或用 --selftest）")
        return 2

    try:
        import serial
    except ImportError:
        print("🔴 缺 pyserial —— pip install pyserial")
        return 2

    buf = bytearray()
    ser = None
    try:
        # 🔴🔴 关键：**打开 COM29 就会复位 ESP32-S3**（⭐ 2026-09-30 实测确认）
        #    · ESP32-S3 的原生 USB-Serial/JTAG 把 DTR/RTS 接到了芯片的
        #      复位/启动电路上 ⇒ **pyserial 在 open() 时会拉这两根线**
        #      ⇒ 🔴 **板子被复位**，⚠️ **池里的数据全部丢失**
        #    · ⭐ 实测：喂完 200 帧后用本脚本读一次日志 ⇒ 板子重启、
        #      `pool=0 total=0` ⇒ 🔴 **把正在做的测试毁掉了**
        #  ⇒ ⭐ 对策：**open() 之前先把 DTR/RTS 置为"不复位"的静息电平**，
        #     并且 ⛔ **绝不在 open 之后再动它们**（除非显式 --reset）。
        #    ⚠️ pyserial 的构造参数里传 dtr/rts 不总是生效
        #      （⭐ 取决于驱动），所以**用 open() 前后的显式设置兜底**。
        ser = serial.Serial()
        ser.port = args.port
        ser.baudrate = args.baud
        ser.timeout = 0.2
        ser.dtr = False          # ⭐ 打开时不要拉 DTR
        ser.rts = False          # ⭐ 打开时不要拉 RTS
        ser.open()
        # ⚠️ 再确认一次（⭐ 部分驱动会在 open 时自作主张拉线）
        if not args.reset:
            ser.setDTR(False)
            ser.setRTS(False)
        if args.reset:
            # ESP32-S3 原生 USB-Serial/JTAG：DTR/RTS 组合复位
            #   ⚠️ 只有显式传 --reset 才这么做（⭐ 会清空池内数据！）
            ser.setDTR(False)
            ser.setRTS(True)
            time.sleep(0.12)
            ser.setRTS(False)
            time.sleep(0.08)
            ser.setDTR(True)
            time.sleep(0.05)
        ser.reset_input_buffer()

        t0 = time.time()
        while time.time() - t0 < args.seconds:
            n = ser.in_waiting
            if n:
                buf += ser.read(n)
            else:
                time.sleep(0.05)
    except Exception as e:
        print("🔴 串口错误: %s" % e)
        return 3
    finally:
        if ser is not None:
            try:
                ser.close()          # ⭐ 必须释放，否则下次烧录 PermissionError(13)
            except Exception:
                pass

    text = buf.decode("utf-8", errors="replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    print("---- 收到 %d 字节 ----" % len(buf))

    if args.save:
        d = os.path.dirname(os.path.abspath(args.save))
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with io.open(args.save, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("已存: %s" % os.path.abspath(args.save))
    return 0


if __name__ == "__main__":
    sys.exit(main())
