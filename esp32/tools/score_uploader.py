#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FPGA2026 · 曲谱上位机（单文件 GUI）

双击即可打开。不需要装任何第三方库（GUI 用标准库 tkinter），
BLE 需要 bleak（本项目已装：pip install bleak）。

功能
================================================================================
  1. 打开谱面：events.hex（mid2evt.py 的产物）或 .mid（自动找 mid2evt.py 转换）
  2. 钢琴卷帘可视化：按轴着色、tempo 变速画竖线、悬停读数
  3. 一键上传：清池 -> 发复位序列 + 总数帧 + 全部事件帧（带进度与速率）
  4. 起播 / 停止 / 清池
  5. 实时状态：pool / sent / ovf / late / mm / run / 屏上 t1 t2
  6. 线上字节校验（可选）：USB-TTL 收 UART1 出口，与谱面逐帧比对
  7. 日志面板

命令行
================================================================================
  python score_uploader.py                  # 打开 GUI
  python score_uploader.py --selftest       # 离线自检（不需要硬件）
  python score_uploader.py --autotest <hex> # 无人值守全流程跑一遍（真机）

位域与帧格式的唯一真源是同目录的 score_word.py —— 本文件不自己拼位域。
"""

import argparse
import asyncio
import math
import os
import queue
import re
import struct
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
try:
    import score_word as SW
except Exception as _e:                                    # pragma: no cover
    print("找不到 score_word.py（必须与本文件同目录）：%s" % _e)
    sys.exit(2)

# ============================================================================
# 常量
# ============================================================================
DEV_NAME = "FPGA2026-Synth"
UUID_RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
UUID_NOTI = "0000abf2-0000-1000-8000-00805f9b34fb"
UUID_CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
UUID_STAT = "0000abf4-0000-1000-8000-00805f9b34fb"

CMD_RESET, CMD_STAT, CMD_PLAY, CMD_STOP, CMD_RAW = 0x01, 0x02, 0x03, 0x04, 0x21

F_CLK = 50_000_000.0
TICKS_PER_SEC_120 = 1920.003          # PPQN 960 @ 120 BPM

# 候选的 mid2evt.py 位置（用于 .mid -> events.hex）
MID2EVT_CANDIDATES = [
    os.path.join(_HERE, "mid2evt.py"),
    os.path.join(_HERE, "..", "..", "..", "FPGA2026", "tools", "mid2evt.py"),
    r"C:\Users\hokuu\Desktop\FPGA\FPGA2026\tools\mid2evt.py",
]

# 深色配色
C_BG = "#0f1218"
C_PANEL = "#171c26"
C_PANEL2 = "#1e2533"
C_LINE = "#2a3446"
C_FG = "#e6edf7"
C_DIM = "#8b98ad"
C_ACC = "#4ea1ff"
C_OK = "#3ddc84"
C_WARN = "#ffb020"
C_ERR = "#ff5c5c"
AXIS_COLORS = ["#4ea1ff", "#3ddc84", "#ffb020", "#ff7ab2", "#a78bfa",
               "#22d3ee", "#fb923c", "#f472b6", "#34d399", "#facc15",
               "#60a5fa", "#c084fc", "#2dd4bf", "#f87171", "#a3e635", "#fcd34d"]


def inc_to_hz(inc):
    return inc * F_CLK / (1 << 32)


def hz_to_note(hz):
    """频率 -> 音名（十二平均律，A4=440）。"""
    if hz <= 0:
        return "-"
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    n = int(round(69 + 12 * math.log2(hz / 440.0)))
    return "%s%d" % (names[n % 12], n // 12 - 1)


def hz_to_midi_float(hz):
    if hz <= 0:
        return 0.0
    return 69 + 12 * math.log2(hz / 440.0)


# ============================================================================
# 谱面加载
# ============================================================================
class Score:
    def __init__(self, path, words, note):
        self.path = path
        self.words = words
        self.note = note
        self.notes = []          # (tick, axis, midi_float, vel, kind, timbre)
        self.tempos = []         # (tick, inc, hz)
        self.kinds = {}
        for w in words:
            d = SW.unpack_word(w)
            self.kinds[d["kind"]] = self.kinds.get(d["kind"], 0) + 1
            if d["kind"] == SW.KIND_TEMPO:
                self.tempos.append((d["tick"], d["inc"], inc_to_hz(d["inc"])))
            elif d["kind"] in (SW.KIND_ON, SW.KIND_OFF):
                hz = inc_to_hz(d["inc"])
                self.notes.append((d["tick"], d["axis"], hz_to_midi_float(hz),
                                   d["vel"], d["kind"], d["timbre"]))
        self.tick_max = max((SW.unpack_word(w)["tick"] for w in words), default=0)
        self.tick_min = min((SW.unpack_word(w)["tick"] for w in words), default=0)

    @property
    def n(self):
        return len(self.words)

    def duration_s(self):
        """按首个 tempo 的速率估算时长。"""
        hz = self.tempos[0][2] if self.tempos else TICKS_PER_SEC_120
        return (self.tick_max - self.tick_min) / hz if hz > 0 else 0.0

    def payload(self):
        return SW.build_payload(self.words)


def load_score(path):
    """读 events.hex；若是 .mid 则先找 mid2evt.py 转换。"""
    ext = os.path.splitext(path)[1].lower()
    if ext in (".mid", ".midi"):
        conv = None
        for c in MID2EVT_CANDIDATES:
            if os.path.isfile(c):
                conv = c
                break
        if conv is None:
            raise RuntimeError(
                "这是 MIDI 文件，需要 mid2evt.py 先转成 events.hex。\n"
                "没找到 mid2evt.py。请先运行：\n"
                "  python <FPGA2026>/tools/mid2evt.py --in \"%s\" --out-dir <目录>\n"
                "然后把生成的 events.hex 用本工具打开。" % path)
        outdir = os.path.join(os.path.dirname(path), "_evt")
        os.makedirs(outdir, exist_ok=True)
        import subprocess
        r = subprocess.run([sys.executable, conv, "--in", path, "--out-dir", outdir],
                           capture_output=True, text=True)
        hexp = os.path.join(outdir, "events.hex")
        if r.returncode != 0 or not os.path.isfile(hexp):
            raise RuntimeError("mid2evt.py 转换失败：\n%s\n%s"
                               % (r.stdout[-800:], r.stderr[-800:]))
        words, probs = SW.load_events_hex(hexp)
        return Score(hexp, words, "由 %s 转换（%d 个问题）"
                     % (os.path.basename(path), len(probs)))
    words, probs = SW.load_events_hex(path)
    if not words:
        raise RuntimeError("这个文件里没读到任何事件字：%s" % path)
    note = "直接读取" if not probs else ("%d 处格式问题（仍已载入）" % len(probs))
    return Score(path, words, note)


# ============================================================================
# BLE 工作线程
# ============================================================================
class BleWorker(threading.Thread):
    """独占一个 asyncio 事件循环跑 bleak。UI 通过 cmd_q 下命令、stat_q 收状态。"""

    def __init__(self, cmd_q, evt_q):
        super().__init__(daemon=True)
        self.cmd_q = cmd_q
        self.evt_q = evt_q
        self.loop = None
        self.client = None
        self.stop_flag = threading.Event()

    # ---- 给 UI 用的上报 ----
    def emit(self, kind, **kw):
        kw["kind"] = kind
        self.evt_q.put(kw)

    def log(self, msg):
        self.emit("log", msg=msg)

    # ---- 线程主体 ----
    def run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._main())

    async def _main(self):
        while not self.stop_flag.is_set():
            try:
                cmd = self.cmd_q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.05)
                continue
            try:
                await self._handle(cmd)
            except Exception as e:
                self.log("命令 %s 出错：%s" % (cmd.get("op"), e))
                self.emit("op_done", op=cmd.get("op"), ok=False, err=str(e))

    async def _handle(self, cmd):
        op = cmd.get("op")
        if op == "connect":
            await self._connect(cmd.get("name", DEV_NAME))
        elif op == "disconnect":
            await self._disconnect()
        elif op == "upload":
            await self._upload(cmd["payload"], cmd["n_events"], cmd.get("clear", True))
        elif op == "cmd":
            await self._send_cmd(cmd["code"])
        elif op == "poll":
            await self._poll()
        elif op == "raw":
            await self._raw(cmd["text"])
        elif op == "quit":
            await self._disconnect()
            self.stop_flag.set()

    async def _connect(self, name):
        from bleak import BleakClient, BleakScanner
        self.log("扫描 %s ..." % name)
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: (d.name or "") == name or name in (d.name or ""),
            timeout=12.0)
        if dev is None:
            raise RuntimeError("没找到设备 %s（板子在广播吗？别的中心设备还连着？）" % name)
        self.client = BleakClient(dev)
        await self.client.connect()
        await asyncio.sleep(0.8)
        self.log("已连接 %s [%s]" % (dev.name, dev.address))
        self.emit("connected", name=dev.name, addr=dev.address)

    async def _disconnect(self):
        if self.client is not None:
            try:
                await self.client.disconnect()
            except Exception:
                pass
            self.client = None
        self.emit("disconnected")

    async def _send_cmd(self, code):
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("还没连上蓝牙")
        await self.client.write_gatt_char(UUID_CMD, bytes([code]), response=False)
        self.log("已发 CMD 0x%02X" % code)

    async def _raw(self, text):
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("还没连上蓝牙")
        await self.client.write_gatt_char(UUID_CMD,
                                          bytes([CMD_RAW]) + text.encode(),
                                          response=False)
        self.log("已发 HMI 原样命令：%s" % text)

    async def _upload(self, payload, n_events, clear):
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("还没连上蓝牙")
        if clear:
            await self.client.write_gatt_char(UUID_CMD, bytes([CMD_RESET]),
                                              response=False)
            self.log("已发 CMD 0x01（清池）")
            await asyncio.sleep(0.8)
        total = len(payload)
        chunk = 180
        sent = 0
        t0 = time.time()
        self.emit("progress", sent=0, total=total, rate=0.0)
        while sent < total:
            n = min(chunk, total - sent)
            await self.client.write_gatt_char(UUID_RECV, payload[sent:sent + n],
                                              response=False)
            sent += n
            dt = time.time() - t0
            self.emit("progress", sent=sent, total=total,
                      rate=(sent / 1024.0) / max(dt, 1e-9))
            await asyncio.sleep(0.004)
        self.log("上传完成：%d 字节 / %d 事件，用时 %.1f s"
                 % (total, n_events, time.time() - t0))
        self.emit("op_done", op="upload", ok=True)

    async def _poll(self):
        if self.client is None or not self.client.is_connected:
            self.emit("stat", ok=False)
            return
        try:
            await self.client.write_gatt_char(UUID_CMD, bytes([CMD_STAT]),
                                              response=False)
            await asyncio.sleep(0.5)
            raw = await self.client.read_gatt_char(UUID_STAT)
            txt = bytes(raw).decode("utf-8", "replace")
        except Exception as e:
            self.emit("stat", ok=False, err=str(e))
            return
        d = {}
        for k in ("pool", "sent", "ovf", "late", "exp", "mm", "clamp", "run",
                  "tf", "total", "rst", "unk", "in", "out"):
            m = re.search(r"\b%s=(\d+)" % k, txt)
            if m:
                d[k] = int(m.group(1))
        m = re.search(r"pool=(\d+)/(\d+)", txt)
        if m:
            d["pool"], d["pool_cap"] = int(m.group(1)), int(m.group(2))
        self.emit("stat", ok=True, data=d, raw=txt)


# ============================================================================
# 钢琴卷帘画布
# ============================================================================
class PianoRoll(tk.Canvas):
    def __init__(self, master, **kw):
        kw.setdefault("bg", C_PANEL)
        kw.setdefault("highlightthickness", 0)
        super().__init__(master, **kw)
        self.score = None
        self.cursor = None            # 播放位置（0..1）
        self.bind("<Configure>", lambda e: self.redraw())
        self.bind("<Motion>", self._hover)
        self._tip = None

    def set_score(self, score):
        self.score = score
        self.redraw()

    def set_cursor(self, frac):
        self.cursor = frac
        self.redraw()

    def _hover(self, ev):
        if not self.score or not self.score.notes:
            return
        w, h = self.winfo_width(), self.winfo_height()
        pad_l, pad_r, pad_t, pad_b = 46, 12, 10, 22
        pw = max(1, w - pad_l - pad_r)
        tm = max(1, self.score.tick_max)
        t = (ev.x - pad_l) / pw * tm
        # 找最近的音符
        best, bd = None, 1e18
        for nt in self.score.notes:
            dd = abs(nt[0] - t)
            if dd < bd:
                bd, best = dd, nt
        if best and bd < tm * 0.02:
            f = 440.0 * (2 ** ((best[2] - 69) / 12.0))
            txt = "tick %d · 轴 %d · %s (%.1f Hz) · 力度 %d · %s" % (
                best[0], best[1], hz_to_note(f), f, best[3],
                "on" if best[4] == SW.KIND_ON else "off")
            self._tip = (txt, ev.x, ev.y)
        else:
            self._tip = None
        self.redraw()

    def redraw(self):
        self.delete("all")
        w, h = self.winfo_width(), self.winfo_height()
        if w < 10 or h < 10:
            return
        pad_l, pad_r, pad_t, pad_b = 46, 12, 10, 22
        pw, ph = w - pad_l - pad_r, h - pad_t - pad_b
        self.create_rectangle(pad_l, pad_t, pad_l + pw, pad_t + ph,
                              fill=C_PANEL2, outline=C_LINE)
        if not self.score or not self.score.notes:
            self.create_text(w / 2, h / 2, text="还没有打开谱面",
                             fill=C_DIM, font=("Microsoft YaHei UI", 12))
            return
        sc = self.score
        tm = max(1, sc.tick_max)
        mids = [n[2] for n in sc.notes if n[2] > 0]
        lo = min(mids) - 1 if mids else 0
        hi = max(mids) + 1 if mids else 1
        if hi - lo < 6:
            lo, hi = lo - 3, hi + 3

        def X(t):
            return pad_l + (t / tm) * pw

        def Y(m):
            return pad_t + ph - (m - lo) / (hi - lo) * ph

        # 八度参考线（C 音）
        import math
        for m in range(int(math.floor(lo)), int(math.ceil(hi)) + 1):
            if m % 12 == 0:
                y = Y(m)
                self.create_line(pad_l, y, pad_l + pw, y, fill="#243044")
                self.create_text(pad_l - 6, y, text=hz_to_note(
                    440.0 * 2 ** ((m - 69) / 12.0)), fill=C_DIM,
                    anchor="e", font=("Consolas", 8))

        # tempo 竖线
        for (tk_, inc, hz) in sc.tempos:
            x = X(tk_)
            self.create_line(x, pad_t, x, pad_t + ph, fill=C_WARN, dash=(3, 3))
            self.create_text(x + 3, pad_t + 8, text="%.0f BPM"
                             % (hz / TICKS_PER_SEC_120 * 120.0),
                             fill=C_WARN, anchor="w", font=("Consolas", 8))

        # 音符
        n_total = len(sc.notes)
        step = 1 if n_total <= 20000 else max(1, n_total // 20000)
        for i in range(0, n_total, step):
            tick, axis, m, vel, kind, timbre = sc.notes[i]
            x = X(tick)
            y = Y(m)
            c = AXIS_COLORS[axis % len(AXIS_COLORS)]
            r = 2 if kind == SW.KIND_ON else 1
            self.create_oval(x - r, y - r, x + r, y + r,
                             fill=c, outline="")

        # 播放游标
        if self.cursor is not None:
            x = pad_l + self.cursor * pw
            self.create_line(x, pad_t, x, pad_t + ph, fill=C_OK, width=2)

        # 轴图例
        axes = sorted(set(n[1] for n in sc.notes))
        lx = pad_l + 4
        for a in axes[:12]:
            self.create_rectangle(lx, pad_t + ph + 8, lx + 8, pad_t + ph + 16,
                                  fill=AXIS_COLORS[a % len(AXIS_COLORS)],
                                  outline="")
            self.create_text(lx + 12, pad_t + ph + 12, text="轴%d" % a,
                             fill=C_DIM, anchor="w", font=("Consolas", 8))
            lx += 46

        if self._tip:
            txt, tx, ty = self._tip
            tid = self.create_text(tx + 12, ty - 12, text=txt, fill=C_FG,
                                   anchor="w", font=("Microsoft YaHei UI", 9))
            bx = self.bbox(tid)
            if bx:
                self.create_rectangle(bx[0] - 6, bx[1] - 3, bx[2] + 6, bx[3] + 3,
                                      fill=C_BG, outline=C_LINE)
                self.tag_raise(tid)


# ============================================================================
# 主界面
# ============================================================================
class App:
    def __init__(self, root):
        self.root = root
        self.score = None
        self.cmd_q = queue.Queue()
        self.evt_q = queue.Queue()
        self.worker = BleWorker(self.cmd_q, self.evt_q)
        self.worker.start()
        self.connected = False
        self.uploading = False
        self.polling = False
        self._build()
        self.root.after(60, self._drain)

    # ---------- 布局 ----------
    def _build(self):
        r = self.root
        r.title("FPGA2026 · 曲谱上位机")
        r.configure(bg=C_BG)
        r.geometry("1180x760")
        r.minsize(980, 640)

        style = ttk.Style()
        try:
            style.theme_use("clam")
        except Exception:
            pass
        style.configure("TButton", background=C_PANEL2, foreground=C_FG,
                        borderwidth=0, focusthickness=0, padding=(14, 7),
                        font=("Microsoft YaHei UI", 10))
        style.map("TButton",
                  background=[("active", C_ACC), ("disabled", C_PANEL)],
                  foreground=[("disabled", C_DIM)])
        style.configure("Accent.TButton", background=C_ACC, foreground="#06121f",
                        font=("Microsoft YaHei UI", 10, "bold"))
        style.map("Accent.TButton", background=[("active", "#79bcff")])
        style.configure("TProgressbar", background=C_ACC, troughcolor=C_PANEL2,
                        borderwidth=0, thickness=14)

        # 顶栏
        top = tk.Frame(r, bg=C_PANEL, height=54)
        top.pack(fill="x", side="top")
        top.pack_propagate(False)
        tk.Label(top, text="FPGA2026 · 曲谱上位机", bg=C_PANEL, fg=C_FG,
                 font=("Microsoft YaHei UI", 14, "bold")).pack(side="left", padx=16)
        self.lbl_conn = tk.Label(top, text="● 未连接", bg=C_PANEL, fg=C_ERR,
                                 font=("Microsoft YaHei UI", 11))
        self.lbl_conn.pack(side="right", padx=16)
        self.btn_conn = ttk.Button(top, text="连接蓝牙", command=self.on_connect)
        self.btn_conn.pack(side="right", padx=6)

        # 中部：左栏 + 卷帘
        mid = tk.Frame(r, bg=C_BG)
        mid.pack(fill="both", expand=True, padx=12, pady=(10, 6))

        left = tk.Frame(mid, bg=C_PANEL, width=268)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)
        self._build_left(left)

        right = tk.Frame(mid, bg=C_BG)
        right.pack(side="left", fill="both", expand=True, padx=(10, 0))
        tk.Label(right, text="钢琴卷帘（按轴着色 · 虚线=变速点 · 悬停读数）",
                 bg=C_BG, fg=C_DIM,
                 font=("Microsoft YaHei UI", 9)).pack(anchor="w", pady=(0, 4))
        self.roll = PianoRoll(right)
        self.roll.pack(fill="both", expand=True)

        # 底部：控制 + 状态 + 日志
        self._build_bottom(r)

    def _build_left(self, p):
        tk.Label(p, text="谱面", bg=C_PANEL, fg=C_ACC,
                 font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w",
                                                               padx=14, pady=(14, 6))
        ttk.Button(p, text="打开谱面…", command=self.on_open).pack(fill="x", padx=14)
        self.lbl_file = tk.Label(p, text="（未打开）", bg=C_PANEL, fg=C_DIM,
                                 wraplength=240, justify="left",
                                 font=("Microsoft YaHei UI", 9))
        self.lbl_file.pack(anchor="w", padx=14, pady=(6, 12))

        tk.Frame(p, bg=C_LINE, height=1).pack(fill="x", padx=14)
        tk.Label(p, text="统计", bg=C_PANEL, fg=C_ACC,
                 font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w",
                                                               padx=14, pady=(12, 6))
        self.stat_vars = {}
        for key, label in [("n", "事件数"), ("dur", "时长"),
                           ("ticks", "tick 范围"), ("tempo", "变速点"),
                           ("kinds", "类型分布"), ("bytes", "整包字节")]:
            row = tk.Frame(p, bg=C_PANEL)
            row.pack(fill="x", padx=14, pady=1)
            tk.Label(row, text=label, bg=C_PANEL, fg=C_DIM, width=9, anchor="w",
                     font=("Microsoft YaHei UI", 9)).pack(side="left")
            v = tk.StringVar(value="-")
            tk.Label(row, textvariable=v, bg=C_PANEL, fg=C_FG, anchor="w",
                     justify="left", wraplength=150,
                     font=("Consolas", 9)).pack(side="left", fill="x", expand=True)
            self.stat_vars[key] = v

        tk.Frame(p, bg=C_LINE, height=1).pack(fill="x", padx=14, pady=12)
        tk.Label(p, text="线上字节校验（可选）", bg=C_PANEL, fg=C_ACC,
                 font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w", padx=14)
        self.var_wire = tk.BooleanVar(value=False)
        tk.Checkbutton(p, text="抓 UART1 出口并逐帧比对", variable=self.var_wire,
                       bg=C_PANEL, fg=C_FG, selectcolor=C_PANEL2,
                       activebackground=C_PANEL, activeforeground=C_FG,
                       font=("Microsoft YaHei UI", 9)).pack(anchor="w", padx=14)
        rowp = tk.Frame(p, bg=C_PANEL)
        rowp.pack(fill="x", padx=14, pady=(4, 0))
        tk.Label(rowp, text="口", bg=C_PANEL, fg=C_DIM,
                 font=("Microsoft YaHei UI", 9)).pack(side="left")
        self.var_port = tk.StringVar(value="COM31")
        tk.Entry(rowp, textvariable=self.var_port, width=8, bg=C_PANEL2,
                 fg=C_FG, insertbackground=C_FG, relief="flat",
                 font=("Consolas", 9)).pack(side="left", padx=4)
        self.lbl_wire = tk.Label(p, text="-", bg=C_PANEL, fg=C_DIM,
                                 wraplength=240, justify="left",
                                 font=("Consolas", 8))
        self.lbl_wire.pack(anchor="w", padx=14, pady=(4, 14))

    def _build_bottom(self, r):
        bar = tk.Frame(r, bg=C_PANEL)
        bar.pack(fill="x", padx=12)
        inner = tk.Frame(bar, bg=C_PANEL)
        inner.pack(fill="x", padx=12, pady=10)

        self.btn_up = ttk.Button(inner, text="一键上传", style="Accent.TButton",
                                 command=self.on_upload)
        self.btn_up.pack(side="left")
        self.btn_play = ttk.Button(inner, text="起播", command=lambda: self.on_cmd(CMD_PLAY, "起播"))
        self.btn_play.pack(side="left", padx=6)
        self.btn_stop = ttk.Button(inner, text="停止", command=lambda: self.on_cmd(CMD_STOP, "停止"))
        self.btn_stop.pack(side="left", padx=6)
        self.btn_clr = ttk.Button(inner, text="清池", command=lambda: self.on_cmd(CMD_RESET, "清池"))
        self.btn_clr.pack(side="left", padx=6)
        self.var_poll = tk.BooleanVar(value=True)
        tk.Checkbutton(inner, text="实时状态", variable=self.var_poll,
                       bg=C_PANEL, fg=C_FG, selectcolor=C_PANEL2,
                       activebackground=C_PANEL, activeforeground=C_FG,
                       font=("Microsoft YaHei UI", 9)).pack(side="left", padx=10)

        self.pb = ttk.Progressbar(inner, mode="determinate", maximum=1000)
        self.pb.pack(side="left", fill="x", expand=True, padx=10)
        self.lbl_pb = tk.Label(inner, text="就绪", bg=C_PANEL, fg=C_DIM, width=22,
                               anchor="e", font=("Consolas", 9))
        self.lbl_pb.pack(side="left")

        # 状态条
        st = tk.Frame(r, bg=C_PANEL2)
        st.pack(fill="x", padx=12, pady=(6, 0))
        self.lbl_stat = tk.Label(st, text="pool -   sent -   ovf -   late -   mm -   run -",
                                 bg=C_PANEL2, fg=C_FG, anchor="w",
                                 font=("Consolas", 10))
        self.lbl_stat.pack(side="left", padx=12, pady=8)
        self.lbl_screen = tk.Label(st, text="屏上 t1=-  t2=-", bg=C_PANEL2,
                                   fg=C_DIM, anchor="e", font=("Consolas", 10))
        self.lbl_screen.pack(side="right", padx=12)

        # 日志
        lg = tk.Frame(r, bg=C_BG)
        lg.pack(fill="both", padx=12, pady=(6, 12))
        self.txt = tk.Text(lg, height=7, bg=C_PANEL, fg=C_DIM, relief="flat",
                           insertbackground=C_FG, font=("Consolas", 9),
                           wrap="word")
        self.txt.pack(side="left", fill="both", expand=True)
        sb = tk.Scrollbar(lg, command=self.txt.yview)
        sb.pack(side="right", fill="y")
        self.txt.configure(yscrollcommand=sb.set, state="disabled")

    # ---------- 日志 ----------
    def log(self, msg):
        self.txt.configure(state="normal")
        self.txt.insert("end", "%s  %s\n" % (time.strftime("%H:%M:%S"), msg))
        self.txt.see("end")
        self.txt.configure(state="disabled")

    # ---------- 事件 ----------
    def on_open(self):
        p = filedialog.askopenfilename(
            title="打开谱面",
            filetypes=[("事件流", "*.hex"), ("MIDI", "*.mid *.midi"),
                       ("所有文件", "*.*")])
        if not p:
            return
        try:
            self.score = load_score(p)
        except Exception as e:
            messagebox.showerror("打开失败", str(e))
            return
        sc = self.score
        self.lbl_file.configure(text=os.path.basename(sc.path), fg=C_FG)
        self.stat_vars["n"].set("%d" % sc.n)
        self.stat_vars["dur"].set("%.1f s" % sc.duration_s())
        self.stat_vars["ticks"].set("%d .. %d" % (sc.tick_min, sc.tick_max))
        self.stat_vars["tempo"].set("%d 个" % len(sc.tempos))
        self.stat_vars["kinds"].set(" ".join(
            "%s:%d" % (SW.KIND_NAMES.get(k, k), v)
            for k, v in sorted(sc.kinds.items())))
        self.stat_vars["bytes"].set("%d B / %d 帧"
                                    % (len(sc.payload()),
                                       len(sc.payload()) // SW.FRAME_BYTES))
        self.roll.set_score(sc)
        self.log("已打开 %s：%d 事件，%.1f s，%d 个变速点"
                 % (os.path.basename(sc.path), sc.n, sc.duration_s(),
                    len(sc.tempos)))

    def on_connect(self):
        if self.connected:
            self.cmd_q.put({"op": "disconnect"})
            return
        self.btn_conn.configure(state="disabled")
        self.cmd_q.put({"op": "connect", "name": DEV_NAME})

    def on_cmd(self, code, label):
        self.cmd_q.put({"op": "cmd", "code": code})
        self.log("下发：%s" % label)

    def on_upload(self):
        if self.score is None:
            messagebox.showinfo("先打开谱面", "还没有打开谱面。")
            return
        if not self.connected:
            messagebox.showinfo("先连接蓝牙", "还没连上 ESP32。")
            return
        if self.uploading:
            return
        self.uploading = True
        self.btn_up.configure(state="disabled")
        self.pb["value"] = 0
        self.cmd_q.put({"op": "upload", "payload": self.score.payload(),
                        "n_events": self.score.n, "clear": True})

    # ---------- 轮询 ----------
    def _drain(self):
        # 收工作线程的消息
        while True:
            try:
                e = self.evt_q.get_nowait()
            except queue.Empty:
                break
            k = e.get("kind")
            if k == "log":
                self.log(e["msg"])
            elif k == "connected":
                self.connected = True
                self.lbl_conn.configure(text="● 已连接 %s" % e["name"], fg=C_OK)
                self.btn_conn.configure(text="断开", state="normal")
            elif k == "disconnected":
                self.connected = False
                self.lbl_conn.configure(text="● 未连接", fg=C_ERR)
                self.btn_conn.configure(text="连接蓝牙", state="normal")
            elif k == "progress":
                tot = max(1, e["total"])
                self.pb["value"] = int(1000.0 * e["sent"] / tot)
                self.lbl_pb.configure(
                    text="%d/%d KB  %.1f KB/s"
                         % (e["sent"] // 1024, tot // 1024, e["rate"]))
            elif k == "op_done":
                if e.get("op") == "upload":
                    self.uploading = False
                    self.btn_up.configure(state="normal")
                    self.pb["value"] = 1000 if e.get("ok") else 0
                    self.lbl_pb.configure(text="上传完成" if e.get("ok") else "上传失败")
            elif k == "stat":
                self._on_stat(e)

        # 定时轮询
        if self.polling:
            self.polling = False
            self.cmd_q.put({"op": "poll"})
        if self.connected and self.var_poll.get():
            self.polling = True
        self.root.after(1200, self._drain)

    def _on_stat(self, e):
        if not e.get("ok"):
            return
        d = e["data"]
        self.lbl_stat.configure(text=(
            "pool %s/%s   sent %s   ovf %s   late %s   mm %s   run %s   tf %s"
            % (d.get("pool", "-"), d.get("pool_cap", "-"), d.get("sent", "-"),
               d.get("ovf", "-"), d.get("late", "-"), d.get("mm", "-"),
               d.get("run", "-"), d.get("tf", "-"))))
        cap = d.get("pool_cap") or 1
        pct = 100.0 * d.get("pool", 0) / cap
        self.roll.set_cursor(min(1.0, d.get("sent", 0) / max(1, d.get("tf", 1) or 1)))
        if self.score:
            self.lbl_screen.configure(
                text="池占用 %.0f%%   屏上 t1/t2 见日志" % pct)

    # ---------- 关闭 ----------
    def on_close(self):
        try:
            self.cmd_q.put({"op": "quit"})
            time.sleep(0.2)
        except Exception:
            pass
        self.root.destroy()


# ============================================================================
# 离线自检
# ============================================================================
def selftest():
    print("=" * 70)
    print("score_uploader.py 离线自检（不需要硬件）")
    print("=" * 70)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-54s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and bool(cond)

    # 1) 位域来自 score_word（唯一定义处）
    chk("位域来自 score_word（唯一真源）", SW.OFF_INC == 23 and SW.OFF_AXIS == 19)
    chk("帧层常量来自 score_word",
        SW.FRAME_BYTES == 9 and SW.HDR_EVENT == 0xA5)

    # 2) 频率换算
    hz = inc_to_hz(37796)
    chk("inc=37796 => 440 Hz（50 MHz 口径）", abs(hz - 440.0) < 1.0,
        "  %.2f Hz" % hz)
    chk("音名换算 A4", hz_to_note(440.0) == "A4", "  " + hz_to_note(440.0))
    chk("音名换算 C4", hz_to_note(261.63) == "C4", "  " + hz_to_note(261.63))

    # 3) 用真实 events.hex 造一个 Score（若仓库里那份在）
    real = r"C:\Users\hokuu\Desktop\FPGA\FPGA2026\build\score\regen\09_Conjurer\events.hex"
    if os.path.isfile(real):
        sc = load_score(real)
        chk("真实谱面载入：11865 事件", sc.n == 11865, "  %d" % sc.n)
        chk("真实谱面有 7 个变速点", len(sc.tempos) == 7, "  %d" % len(sc.tempos))
        chk("tick 范围 0..814080",
            sc.tick_min == 0 and sc.tick_max == 814080,
            "  %d..%d" % (sc.tick_min, sc.tick_max))
        pl = sc.payload()
        chk("整包 = 36 + 9 + 11865*9 = 106830", len(pl) == 106830, "  %d" % len(pl))
        chk("整包是 9 的整数倍", len(pl) % 9 == 0)
        chk("首帧 tick == 0（真谱面）",
            SW.unpack_word(sc.words[0])["tick"] == 0)
    else:
        chk("真实谱面存在（跳过则说明那份 events.hex 不在这台机器上）", True,
            "  跳过")

    # 4) 合成谱面：往返 + 非空洞
    words = [SW.pack_word(tick=i * 960, inc=164927, axis=i % 16, vel=100,
                          kind=i % 2, timbre=0) for i in range(64)]
    sc2 = Score("<mem>", words, "合成")
    chk("合成谱面 64 事件 / 64 帧", sc2.n == 64)
    chk("合成谱面 0 个变速点", len(sc2.tempos) == 0)
    chk("时长 ≈ 31.5 s（64*960/1920）", abs(sc2.duration_s() - 31.5) < 0.2,
        "  %.2f s" % sc2.duration_s())

    # 5) 非空洞：若按旧位域解，inc 会差一倍
    w = SW.pack_word(tick=1000, inc=164927, axis=3, vel=100,
                     kind=SW.KIND_ON, timbre=1)
    wrong = (((1000 & SW.MASK_TICK) << SW.OFF_TICK) |
             ((164927 & SW.OLD_MASK_INC) << SW.OLD_OFF_INC) |
             ((3 & SW.MASK_AXIS) << SW.OLD_OFF_AXIS) |
             ((100 & SW.OLD_MASK_VEL) << SW.OFF_VEL) |
             ((0 & SW.MASK_KIND) << SW.OFF_KIND) |
             ((1 & SW.OLD_MASK_TIMBRE) << SW.OLD_OFF_TIMBRE))
    chk("非空洞：旧位域 => 解出的 inc 不是 164927",
        SW.unpack_word(wrong)["inc"] != 164927,
        "  解出 %d" % SW.unpack_word(wrong)["inc"])
    chk("正确位域 => 解回 164927", SW.unpack_word(w)["inc"] == 164927)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


# ============================================================================
# 无人值守全流程（真机）
# ============================================================================
def autotest(hexpath, seconds):
    """清池 -> 上传 -> 起播 -> 轮询，全机器可验，不需要人看屏。"""
    from bleak import BleakClient, BleakScanner

    sc = load_score(hexpath)
    print("谱面 %s：%d 事件，%.1f s，%d 个变速点"
          % (os.path.basename(hexpath), sc.n, sc.duration_s(), len(sc.tempos)))

    async def run():
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: (d.name or "") == DEV_NAME, timeout=15)
        if dev is None:
            print("RED: 没找到 %s" % DEV_NAME)
            return 1
        async with BleakClient(dev) as c:
            await asyncio.sleep(1.0)
            print(">>> 清池")
            await c.write_gatt_char(UUID_CMD, bytes([CMD_RESET]), response=False)
            await asyncio.sleep(0.8)
            pl = sc.payload()
            print(">>> 上传 %d 字节" % len(pl))
            sent = 0
            t0 = time.time()
            while sent < len(pl):
                n = min(180, len(pl) - sent)
                await c.write_gatt_char(UUID_RECV, pl[sent:sent + n],
                                        response=False)
                sent += n
                await asyncio.sleep(0.004)
            print("    %.1f s" % (time.time() - t0))
            await asyncio.sleep(1.0)

            async def stat():
                await c.write_gatt_char(UUID_CMD, bytes([CMD_STAT]),
                                        response=False)
                await asyncio.sleep(0.5)
                t = bytes(await c.read_gatt_char(UUID_STAT)).decode("utf-8", "replace")
                d = {}
                for k in ("pool", "sent", "ovf", "late", "mm", "run", "tf", "unk"):
                    m = re.search(r"\b%s=(\d+)" % k, t)
                    if m:
                        d[k] = int(m.group(1))
                return d

            d = await stat()
            print("灌后：pool=%s tf=%s unk=%s" % (d.get("pool"), d.get("tf"),
                                                d.get("unk")))
            print(">>> 起播")
            await c.write_gatt_char(UUID_CMD, bytes([CMD_PLAY]), response=False)
            t0 = time.time()
            prev = None
            plateau = 0.0
            while time.time() - t0 < seconds:
                d = await stat()
                s = d.get("sent", 0)
                if s == prev:
                    plateau += 1
                else:
                    plateau = 0
                print("  t=%4.0fs sent=%-6s run=%s late=%s ovf=%s mm=%s"
                      % (time.time() - t0, s, d.get("run"), d.get("late"),
                         d.get("ovf"), d.get("mm")))
                if d.get("run") == 0 and s:
                    print(">>> 自然放完")
                    break
                prev = s
                await asyncio.sleep(15)
            final = (await stat()).get("sent", 0)
            print()
            if final == sc.n:
                print("OK   => 全部 %d 个事件都喂出去了" % sc.n)
                return 0
            print("RED  => 只喂出 %d / %d" % (final, sc.n))
            return 3

    return asyncio.run(run())


# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="FPGA2026 曲谱上位机")
    ap.add_argument("--selftest", action="store_true", help="离线自检（不需要硬件）")
    ap.add_argument("--autotest", default=None, help="无人值守全流程（真机），传 events.hex")
    ap.add_argument("--seconds", type=float, default=480.0, help="autotest 观察秒数")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if args.autotest:
        return autotest(args.autotest, args.seconds)

    root = tk.Tk()
    app = App(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
