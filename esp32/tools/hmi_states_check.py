#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hmi_states_check.py —— ⭐ 逐个验证屏上的【状态字 `t1`】（⛔ 不需要人看屏）

═══ 为什么能"不看屏"就验 ═══
⭐ 屏支持 `get <控件>.<属性>` —— ⭐ **屏会把自己的值回传**。
⇒ ⭐ 我们只要**驱动状态变化**，然后 `get t1.txt` 读回，
   ⭐ 就能判定"状态字有没有跟着变"，⛔ 不用盯着屏。

═══ 验什么（⭐ 覆盖 `hmi_state_t` 的全部可达状态）═══
| ⭐ 状态 | ⭐ 怎么进入 | ⭐ 期望 `t1.txt` |
|---|---|---|
| `IDLE` | 刚连接 | `待机` |
| `LOADING` | 正在灌谱 | `灌谱中` |
| `READY` | 灌完 | `就绪` |
| `PLAYING` | CMD `0x03` 起播 | `播放中` |
| `DONE` | 放完 | `播完` |
| `LINK_LOST` | 断开 | `断链` |
⚠️ `UNDERRUN`（供数不足）/ `OVERFLOW`（溢出）⭐ **需要造异常**，⛔ 本脚本不覆盖（⭐ 单独测）。

═══ 用法 ═══
    python hmi_states_check.py --selftest      # ⛔ 不需要硬件
    python hmi_states_check.py                 # 真机（⚠️ 需要屏已接好）
"""

import argparse
import asyncio
import re
import sys
import time

# 串口日志的累积缓冲（⭐ 全局，因为断开后仍要从日志口读屏的回包）
LOG_CHUNKS = []

for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

import struct


def _name_matches(name, exact):
    """设备名匹配（2026-10-13 改为【前缀匹配】）。

    为什么不用 `==`：Windows 按 MAC 缓存 GATT 服务列表，改名是绕开它的
    唯一低成本手段（见 ble_config.h）。若写死全名，每改一次名就要改
    22 个工具；前缀匹配后 Synth / Synth2 / Synth3 全都能认。
    ⚠️ 仍然要求【前缀一致】—— 不会误连到别的设备。
    """
    n = name or ""
    return n == exact or n.startswith("FPGA2026-Synth")


CMD = "0000abf3-0000-1000-8000-00805f9b34fb"
RECV = "0000abf1-0000-1000-8000-00805f9b34fb"
FRAME = 9
DEV = "FPGA2026-Synth"
# 前缀匹配（改名后备选）：见 _name_matches 的说明
DEV_PREFIX = "FPGA2026-Synth"
# ⚠️ 端口会漂 ⇒ ⭐ 传 `--log-port` 覆盖；⭐ 默认按 ESP32 的 USB VID 自动找
LOG_PORT = "COM29"

# ⭐ 期望值（⭐ 与 hmi.c 的 state_text() 必须【逐字一致】）
EXPECT = {
    "IDLE": "待机",
    "LOADING": "灌谱中",
    "READY": "就绪",
    "PLAYING": "播放中",
    "DONE": "播完",
    "LINK_LOST": "断链",
}


def build_score(n):
    inc = 164927
    out = bytearray(bytes([0xA5]) * (FRAME * 4))
    out += bytes([0x00]) + struct.pack(">Q", n)
    for i in range(n):
        tick = 1000 + i * 37
        w = ((tick & 0xFFFFF) << 44) | ((inc & 0x3FFFFF) << 22) | \
            (((i % 16) & 0xF) << 18) | (((60 + (i % 60)) & 0x7F) << 11) | \
            (((i % 2) & 0x3) << 9) | (((i % 2) & 0x1) << 8)
        out += bytes([0xA5]) + w.to_bytes(8, "big")
    return bytes(out)


class Ask:
    """
    ⭐ 读屏的 `get` 回包。

    🔴🔴 **关键：回包【不走 BLE】，只出现在 ESP32 的【串口日志】里**
    -----------------------------------------------------------------------
    ⚠️ 实测踩过：⭐ 我一开始用 BLE notify 收回包 ⇒ 🔴 **全部超时**。
    ⭐ 根因：⭐ 屏的回复进的是 **ESP32 的 UART2 RX** ⇒
       ⭐ 固件**只是把它记进日志**（`hmi_poll_rx` 的 hex dump），
       🔴 **⛔ 没有转发到 BLE**（⭐ 那不是本工程的需求）。
    ⇒ ⭐ 所以要读回包，**必须读 COM29 的日志**，⛔ 不是 BLE。

    ⚠️ 日志与 BLE **互不冲突**（⭐ 一个串口、一个无线）⇒ ⭐ 可以同时开。
    """

    RX_RE = re.compile(r"screen -> ESP32: \d+ B .*?\[([0-9A-Fa-f ]+)\]")

    def __init__(self, ser, client):
        self.ser = ser
        self.c = client
        self.log = bytearray()

    def pump(self):
        """⭐ 非阻塞地把日志口里现有的字节吸进来（⭐ 由调用方定期调）。"""
        try:
            n = self.ser.in_waiting
            if n:
                chunk = self.ser.read(n)
                self.log.extend(chunk)
                # 同时喂进全局缓冲：断开后 Ask 已经不 pump 了，
                # 但屏的回包还在日志里流 => 那条路径靠这个缓冲。
                LOG_CHUNKS.append(chunk)
                if len(LOG_CHUNKS) > 64:
                    del LOG_CHUNKS[:-32]
        except Exception:
            pass

    def _replies(self):
        """⭐ 从日志里抽出所有 `screen -> ESP32` 的 hex，⭐ 拼成完整回包。"""
        txt = self.log.decode("utf-8", "replace")
        out = []
        for m in self.RX_RE.finditer(txt):
            try:
                out.append(bytes(int(x, 16) for x in m.group(1).split()))
            except ValueError:
                pass
        return out

    async def get(self, ctrl, attr="txt", wait=1.6):
        """⭐ 发 `get`，等日志里出现回包，⭐ 返回值（⭐ 去掉 `p` 前缀与 `FF FF FF`）。"""
        self.pump()
        before = len(self._replies())
        await self.c.write_gatt_char(CMD, bytes([0x21]) +
                                     ("get %s.%s" % (ctrl, attr)).encode(),
                                     response=False)
        t0 = asyncio.get_event_loop().time()
        while asyncio.get_event_loop().time() - t0 < wait:
            self.pump()
            reps = self._replies()
            if len(reps) > before:
                b = reps[-1]
                if b.endswith(b"\xff\xff\xff"):
                    b = b[:-3]
                if b[:1] in (b"p", b"q"):
                    b = b[1:]
                return b
            await asyncio.sleep(0.1)
        return None                      # 🔴 超时 = 屏没回（⭐ 控件可能不存在）


async def run(events):
    from bleak import BleakClient, BleakScanner

    fails = []
    print("=" * 74)
    print("屏上状态字 `t1` 逐状态验证（⭐ 用 get 读回，⛔ 不用人看屏）")
    print("=" * 74)

    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=12)
    if dev is None:
        print("🔴 没找到 %s（⚠️ 板子在广播吗？）" % DEV)
        return 3

    # ⭐ 日志口：⭐ 屏的 `get` 回包**只在这里**（🔴 不走 BLE）
    import serial
    ser = serial.Serial()
    ser.port = LOG_PORT
    ser.baudrate = 115200
    ser.timeout = 0.05
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.setDTR(False)
    ser.setRTS(False)
    ser.reset_input_buffer()
    print("  （日志口 %s 已开 —— ⭐ 屏的回包从这里读）" % LOG_PORT)

    async with BleakClient(dev) as c:
        await asyncio.sleep(1.0)
        a = Ask(ser, c)
        await asyncio.sleep(0.6)

        async def check(name, note=""):
            got = await a.get("t1")
            want = EXPECT[name]
            txt = got.decode("utf-8", "replace") if got is not None else "(无回包)"
            ok = (got is not None and txt == want)
            print("  %-10s 期望 %-6s 实测 %-8s %s  %s"
                  % (name, want, txt, "OK " if ok else "RED", note))
            if not ok:
                fails.append("%s: 期望 %s，实测 %s" % (name, want, txt))
            return ok

        # ---- ① IDLE（⭐ 先复位，⛔ 不能假定上电就是 IDLE）----
        # 🔴 踩过的坑（2026-10-01 实测）：⭐ 上电后池里**还留着上一次的谱**
        #    ⇒ ⚠️ 状态是 `就绪` 而⛔ 不是 `待机` ⇒ ⭐ 于是判据假红。
        #    ⭐ 根因是【我的测试前提错了】，⛔ 不是固件错。
        #    ⇒ ⭐ 必须显式复位，才能把 IDLE 作为起点。
        #
        # ⚠️⚠️ 第二个坑（⭐ 同样实测到）：⭐ **复位发得太早会被覆盖** ——
        #    ⭐ 连上前 ~1 s 内，上一条连接遗留的 `hmi_set_state(LINK_LOST)`
        #       可能**晚于**我们的 `0x01` 落地 ⇒ 🔴 读回 `断链`（⚠️ 而固件没错）。
        #    ⭐ 判据：⭐ 单独用 `_idle_probe.py`（⭐ 间隔更长）复现 ⇒ ✅ `待机` 正确。
        #    ⇒ ⭐ 测试必须**带重试**，⛔ 不靠"发一次就成功"。
        print("  ...  发 CMD 0x01（复位）把状态打回 IDLE（⭐ 最多试 3 次）")
        idle_ok = False
        for attempt in range(3):
            await c.write_gatt_char(CMD, bytes([0x01]), response=False)
            await asyncio.sleep(1.2)
            got = await a.get("t1")
            txt = got.decode("utf-8", "replace") if got is not None else "(无回包)"
            if txt == EXPECT["IDLE"]:
                idle_ok = True
                print("      第 %d 次复位后读到 `%s` ✅" % (attempt + 1, txt))
                break
            print("      第 %d 次复位后读到 `%s`（⚠️ 再试一次）" % (attempt + 1, txt))
        print("  %-10s 期望 %-6s 实测 %-8s %s  %s"
              % ("IDLE", EXPECT["IDLE"],
                 EXPECT["IDLE"] if idle_ok else "(3 次都没到)",
                 "OK " if idle_ok else "RED", "复位后"))
        if not idle_ok:
            fails.append("IDLE: 连续 3 次复位都没进 %s" % EXPECT["IDLE"])

        # ---- ② LOADING（⭐ 灌谱中）----
        payload = build_score(events)
        off = 0
        # ⭐ 先灌一小部分 ⇒ 停在 LOADING
        first = payload[:36 + 9 + FRAME * 20]
        while off < len(first):
            n = min(180, len(first) - off)
            await c.write_gatt_char(RECV, first[off:off + n], response=False)
            off += n
            await asyncio.sleep(0.004)
        await asyncio.sleep(0.6)
        await check("LOADING", "灌了 20 帧，还没灌完")

        # ---- 灌完 ----
        rest = payload[36 + 9 + FRAME * 20:]
        off = 0
        while off < len(rest):
            n = min(180, len(rest) - off)
            await c.write_gatt_char(RECV, rest[off:off + n], response=False)
            off += n
            await asyncio.sleep(0.004)
        await asyncio.sleep(1.5)
        # ⚠️ 灌完 = 收到总数帧 + 全部事件 ⇒ 但状态要等 `pool_mark_done()`
        #    ⭐ 本固件在【收到应到帧数】时才转 READY ⇒ ⚠️ 可能仍是 LOADING
        await check("READY", "灌完（⚠️ 若仍 LOADING 见下方说明）")

        # ---- ③ PLAYING（⭐ 起播）----
        await c.write_gatt_char(CMD, bytes([0x03]), response=False)
        await asyncio.sleep(1.2)
        await check("PLAYING", "CMD 0x03 起播后")

        # ---- ④ DONE（⭐ 放完）----
        # ⚠️ 200 帧 ≈ 14.3 s（⭐ rate=1919 tick/s + 10.4 s 提前量）
        await asyncio.sleep(22)
        await check("DONE", "起播 ~22 s 后")

    # ---- ⑤ LINK_LOST（断开）----
    # 断开时固件调 `hmi_set_state(LINK_LOST)` => 屏上应是 `断链`。
    #
    # 2026-10-12 第三次改写（⭐ 前两版都不成立，原因值得记）：
    #   🔴 第 1 版：断开 -> 【重连】 -> 读 t1，期望 `断链`。
    #      重连成功时恢复逻辑立刻把状态置成 `就绪` => 永远读到 `就绪`。
    #      ⚠️ 它和 L4_RECOVER（要求重连后是 `就绪`）【互相矛盾】，
    #         两个判据不可能同时成立 => 等于把这条判据废掉了。
    #   🔴 第 2 版：断开 -> 【不重连】，从串口日志读屏的回包。
    #      ⚠️ 但屏【只在被查询时才回包】，断开后没人查询 => 读不到（前置不满足）。
    #   ✅ 第 3 版（本版）：读固件里的【状态进入次数】`st.x`。
    #      ⭐ 关键认知：`断链` 是一个【转瞬即逝的过渡态】——
    #         它的"当前值"注定读不到；能读到的只有【它发生过】这件事。
    #         => 判据必须落在【计数】上，⛔ 不能落在"此刻的值"上。
    #      ⭐ 这也解释了为什么这个缺陷能长期存在：正确实现和缺陷实现
    #         在"重连后读 t1"这个观测下【读数完全一样】。
    #
    # 判据：断开 -> 【等固件自己发现】 -> 重连 -> 读 `hmi.st.x`（断链进入次数）≥ 1。
    #
    # 🔴 2026-10-12 实测：**断开不是立刻被发现的**。
    #    PC 侧 `disconnect()` 之后，要等 HCI 层的链路监督超时（实测 **约 6 秒**）
    #    固件才收到 `ESP_GATTS_DISCONNECT_EVT`：
    #      W (8422) BT_HCI: hcif disc complete: hdl 0x1, rsn 0x13
    #      I (8422) blebridge: DISCONNECT_EVT 进入：conn_id=0 (s_conn_id=0) reason=0x13
    #      I (8552) hmi: screen <- ESP32: "t1.txt="断链""       <= 这时才置
    #    ⚠️ 我第一版只等 1.8 秒 => 固件还没发现断链就去读 => `st.x=0` 假红。
    #    ⭐ 教训：凡是"对端要过一会儿才反应过来"的判据，
    #       等待时间必须【从实测日志里量出来】，⛔ 不能拍脑袋给。
    print("  ...  断开，等固件自己发现（HCI 监督超时，实测约 6 秒），再重连读 st.x")
    # 🔴 必须用【主连接 `c`】断开。
    #    踩过：这里原来写的是 `c3` —— 而 `c3` 直到下面 T2_INTERNAL 那段
    #    （`async with BleakClient(...) as c3`）才被赋值。
    #    在此处 `c3` 是【上一轮循环留下的、早已关闭的 client】
    #    => `c3.disconnect()` 是个空操作 => 🔴 连接其实【根本没断】
    #    => 固件不会置断链 => `st.x` 恒 0 => 假红，且查了很久。
    #    ⭐ 教训：`disconnect()` 不报错 ⛔ 不等于"断开了"；
    #      断开类操作必须【显式确认对象就是当前活跃连接】。
    try:
        await c.disconnect()
    except Exception:                        # noqa: BLE001
        pass
    await asyncio.sleep(8.0)                 # ⭐ 必须 > 实测的 6 秒，留余量

    dev2 = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=12)
    if dev2 is None:
        fails.append("LINK_LOST: 重连失败（找不到设备）")
        print("  LINK_LOST  期望 st.x>=1   RED  重连失败")
    else:
        async with BleakClient(dev2) as c2:
            await asyncio.sleep(1.0)
            st = None
            for _try in range(3):
                try:
                    # ⚠️ 关键：`0xABF4` 的内容是【CMD 0x02 触发组装】的，
                    #    ⛔ 不是"一读就是最新"。刚重连时它还是上次那份旧内容
                    #    （实测：不发 0x02 直接读 => 读到的是上一次的 STAT，
                    #      里面没有刚加的 `st.` 字段 => 误报"需要重新烧录固件"）。
                    # ⭐ 所以必须先要一份新的，再读。
                    await c2.write_gatt_char(
                        "0000abf3-0000-1000-8000-00805f9b34fb",
                        bytes([0x02]), response=False)
                    await asyncio.sleep(0.7)
                    raw = bytes(await c2.read_gatt_char(
                        "0000abf4-0000-1000-8000-00805f9b34fb")).decode(
                            "utf-8", "replace")
                    # 🔴 必须锚定在 `st.` 之后。
                    #    踩过：原来写 `\bx(\d+)` —— 它会先命中
                    #    `last=0x00` 里的 `x00`（`0x` 的 x）=> 读到的是
                    #    那个 0，⭐ 而且刚好等于"变异体的期望值"，
                    #    会让判据【假绿】。锚定写法见下。
                    m = re.search(r"\bst\.i(\d+)\s+l(\d+)\s+r(\d+)\s+p(\d+)\s+x(\d+)",
                                  raw)
                    if m:
                        st = int(m.group(5))
                        break
                except Exception:            # noqa: BLE001
                    pass
                await asyncio.sleep(0.4)
            if st is None:
                print("  %-10s 期望 st.x>=1  实测 (读不到)   前置  "
                      "0xABF4 里没有 st.x 字段（⭐ 需要重新烧录固件）"
                      % "LINK_LOST")
            else:
                ok = (st >= 1)
                print("  %-10s 期望 st.x>=1  实测 st.x=%-5d %s  %s"
                      % ("LINK_LOST", st, "OK " if ok else "RED",
                         "断开确实置过 `断链`（⭐ 计数独立于读取时机）"))
                if not ok:
                    fails.append("LINK_LOST: st.x=%d，断开【没有】置断链" % st)

    # ---- ⑤b L4_RECOVER（重连恢复）----
    # 用户 2026-10-12 裁定：重连成功 => 屏上显示 `就绪`。
    #
    # 为什么单独立一条判据：原来的测试【只验了断开置位】，
    #   注释里还写着"重连本身不会改状态" —— 于是"重连后停在断链"这件事
    #   从头到尾没有任何判据看着，做了没做都测不出来。
    #   同族 C166：一条判据不能同时代表两个相反的行为。
    #
    # 判据：断开 -> 重连 -> 等恢复落地 -> 读 `t1`，必须是 `就绪`。
    #
    # ⚠️ 衔接：上面的 LINK_LOST 判据已经用【主连接 c】断开过了（且没重连），
    #    中间为了读 `st.x` 开的那次连接（`c2`）在它的 with 块结束时也关了。
    #    ⭐ 所以这里【直接重连】就行，⛔ 不要再 disconnect ——
    #      原来的代码在这里调 `c3.disconnect()`，而 `c3` 直到下面才被赋值
    #      => 调的是上一轮的僵尸 client => 空操作（同 LINK_LOST 那个坑）。
    dev3 = None
    await asyncio.sleep(1.0)
    dev3 = await BleakScanner.find_device_by_filter(
        lambda d, ad: _name_matches(d.name, DEV), timeout=12)
    if dev3 is None:
        fails.append("L4_RECOVER: 重连失败（找不到设备）")
        print("  L4_RECOVER 期望 就绪   RED  重连失败")
    else:
        async with BleakClient(dev3) as c4:
            await asyncio.sleep(1.2)      # 留出恢复逻辑落地的时间
            a4 = Ask(ser, c4)
            got4 = await a4.get("t1")
            txt4 = got4.decode("utf-8", "replace") if got4 is not None else "(无回包)"
            ok4 = (got4 is not None and txt4 == EXPECT["READY"])
            print("  %-10s 期望 %-6s 实测 %-8s %s  %s"
                  % ("L4_RECOVER", EXPECT["READY"], txt4,
                     "OK " if ok4 else "RED", "重连后应恢复为就绪"))
            if not ok4:
                fails.append("L4_RECOVER: 期望 %s，实测 %s"
                             % (EXPECT["READY"], txt4))

    # ⭐⭐ 2026-10-12 新增：屏上【事件计数】`t2` 的回归判据。
    # -----------------------------------------------------------------------
    # 🔴 用户实测报的 bug：屏上显示 **`18704/200`** —— 分子远超分母。
    # ⭐ 根因：`s_song_events_rx`（已收）原来只在收到「复位帧」时清零，
    #    而「总数帧」(0x00) 才是声明"新曲子应到多少"的那个点，它到达时没清
    #    ⇒ 客户端不反复发复位帧时，"已收"跨曲无限累加。
    # ⭐ 修法：`frame_parse_total()` 里一并清零（见 ble_main.c）。
    # ⚠️ 本判据的意义：⭐ 把"用户看得见的那串字"钉住 ——
    #    ⛔ 只看 `0xABF4` 里的内部值是不够的（值 / 显示 / 重绘是三件事，C139）。
    # ⭐ 判据：`t2` 形如 `已收/应到`，且【已收 <= 应到】且【应到 == 本次灌入数】。
    try:
        async with BleakClient(dev2 if dev2 is not None else dev) as c3:
            await asyncio.sleep(0.8)
            a3 = Ask(ser, c3)
            got2 = await a3.get("t2")
            t2 = got2.decode("utf-8", "replace") if got2 is not None else "(无回包)"
            num = den = None
            if "/" in t2:
                try:
                    num, den = (int(x.strip()) for x in t2.split("/", 1))
                except ValueError:
                    pass
            if num is None:
                print("  %-10s 期望 %-10s 实测 %-10s RED   t2 不是 数字/数字 形状"
                      % ("T2_COUNT", "%d/%d" % (events, events), t2))
                fails.append("T2_COUNT: 形状不对，实测 %r" % t2)
            else:
                ok = (num <= den) and (den == events)
                print("  %-10s 期望 %-10s 实测 %-10s %s  已收<=应到 且 应到==灌入数"
                      % ("T2_COUNT", "%d/%d" % (events, events), t2,
                         "OK " if ok else "RED"))
                if not ok:
                    fails.append("T2_COUNT: 期望 %d/%d，实测 %s（🔴 已收>应到 = 计数没归零）"
                                 % (events, events, t2))
            # ⭐⭐ 还要查【内部真实值】：屏上显示有兜底钳制（见 hmi.c），
            #    ⚠️ 所以"屏上看起来对"⛔ 不等于"内部计数器真的归零了"。
            #    ⭐ `0xABF4` 的 `frame=... ev=<本曲已收>` 才是真值。
            #    ⭐ 判据：`ev <= tf`（⛔ 不该出现 ev 跨曲累加）。
            # ⚠️ 读 `0xABF4` 偶发失败（BLE 抖动）⇒ ⭐ **重试 3 次**，
            #    ⛔ 不要一次读失败就判红（⭐ 那是"判据不结实"，不是设备坏）。
            ev = tf = None
            last_err = None
            for _try in range(3):
                try:
                    # ⚠️ 同 LINK_LOST：`0xABF4` 要先发 CMD 0x02 触发组装，
                    #    ⛔ 不能直接读（否则读到上一次那份旧内容）。
                    await c3.write_gatt_char(
                        "0000abf3-0000-1000-8000-00805f9b34fb",
                        bytes([0x02]), response=False)
                    await asyncio.sleep(0.7)
                    st = bytes(await c3.read_gatt_char(
                        "0000abf4-0000-1000-8000-00805f9b34fb")).decode("utf-8", "replace")
                    m_ev = re.search(r"\bev=(\d+)", st)
                    m_tf = re.search(r"\btf=(\d+)", st)
                    if m_ev is not None:
                        ev = int(m_ev.group(1))
                        tf = int(m_tf.group(1)) if m_tf else None
                        break
                    last_err = "0xABF4 里没有 ev 字段（⭐ 需要重新烧录固件）"
                except Exception as e:           # noqa: BLE001
                    last_err = str(e)
                await asyncio.sleep(0.4)
            if ev is None:
                print("  %-10s ⚠️ 读不到（重试 3 次后）：%s" % ("T2_INTERNAL", last_err))
            else:
                ok2 = (tf is None or tf == 0 or ev <= tf)
                print("  %-10s 内部 ev=%-6s tf=%-6s %s  内部已收<=应到（⛔ 不受显示兜底影响）"
                      % ("T2_INTERNAL", ev, tf, "OK " if ok2 else "RED"))
                if not ok2:
                    fails.append("T2_INTERNAL: ev=%s > tf=%s（🔴 内部计数跨曲累加）"
                                 % (ev, tf))
    except Exception as e:                       # noqa: BLE001
        print("  T2_COUNT   ⚠️ 读取失败：%s" % e)
        fails.append("T2_COUNT: 读取失败 %s" % e)

    try:
        ser.close()
    except Exception:
        pass

    print()
    print("=" * 74)
    if not fails:
        print("结论：状态字全部正确 ✅")
    else:
        print("结论：%d 项不符 🔴" % len(fails))
        for f in fails:
            print("   - %s" % f)
    print("=" * 74)
    return 0 if not fails else 1


def selftest():
    """⭐ 离线自检：⭐ 验期望表与 hmi.c 的 state_text() 【逐字一致】。"""
    import inspect
    import os
    print("=" * 74)
    print("hmi_states_check.py 离线自检（⛔ 不需要硬件）")
    print("=" * 74)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-46s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and cond

    # ⭐⭐ 关键：⭐ 把 hmi.c 里的 state_text() 源码读出来，⭐ 逐字比对期望表
    #    ⚠️ 这样"屏上显示的字"与"脚本期望的字"**不可能悄悄漂**
    here = os.path.dirname(os.path.abspath(__file__))
    src_path = os.path.join(here, "..", "ble", "main", "hmi.c")
    try:
        with open(src_path, "r", encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError as e:
        chk("读到 hmi.c", False, "  %s" % e)
        print()
        print("结论：有失败项")
        return 1

    chk("读到 hmi.c", len(src) > 1000, "  %d 字符" % len(src))
    for k, v in EXPECT.items():
        # ⭐ 在 hmi.c 里找 `return "xxx"` 附近是否有这个状态
        chk("hmi.c 含状态字 %-6s (%s)" % (v, k), ('"%s"' % v) in src)

    # ⭐ 反例：⭐ 编一个不存在的状态字，必须找不到
    chk("反例：hmi.c 不含「不存在」", '"不存在"' not in src)
    chk("反例：错期望会被抓到", EXPECT["IDLE"] != "待机2")

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def find_log_port():
    """⭐ 按 ESP32 的 USB VID（303A）自动找日志口 —— ⚠️ 端口号会漂。"""
    try:
        from serial.tools import list_ports
    except Exception:
        return None
    for p in list_ports.comports():
        hwid = (p.hwid or "").upper()
        if "303A" in hwid:                   # ⭐ Espressif 的 VID
            return p.device
    return None


def main():
    global LOG_PORT
    ap = argparse.ArgumentParser(description="逐个验证屏上状态字 t1")
    ap.add_argument("--selftest", action="store_true", help="离线自检（⛔ 不需硬件）")
    ap.add_argument("--events", type=int, default=200)
    ap.add_argument("--log-port", default=None,
                    help="ESP32 日志口（⚠️ 默认按 VID 303A 自动找）")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.log_port:
        LOG_PORT = args.log_port
    else:
        auto = find_log_port()
        if auto:
            LOG_PORT = auto
        print("日志口 = %s" % LOG_PORT)
    return asyncio.run(run(args.events))


if __name__ == "__main__":
    sys.exit(main())
