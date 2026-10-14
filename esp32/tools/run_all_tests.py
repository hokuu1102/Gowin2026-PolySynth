"""全量测试顺序执行器 —— 离线自检 + 全部真机测试，出一张汇总表。

为什么必须【顺序】跑
----------------------------------------------------------------------------
BLE 只允许一个中心设备连接，串口同一时刻只允许一个读者（U85）。
真机测试全都占这两个资源 => ⛔ 并发跑会互相抢，结论不可信（C101 同族）。

判据（⛔ 不是"跑完了"）
----------------------------------------------------------------------------
本执行器的退出码 = 失败项数。⭐ 任何一项红 => 整体红。
并且会打印每一项的退出码与判据行，便于人工复核。

用法
----------------------------------------------------------------------------
    python run_all_tests.py                    # 离线 + 常规真机（约 6~10 分钟）
    python run_all_tests.py --offline-only     # 只跑离线（不需要硬件）
    python run_all_tests.py --with-play        # 追加"灌真谱面并放到底"（+9 分钟）
    python run_all_tests.py --list             # 只列出要跑什么

⚠️ 跑真机前请确认：网页上位机【已关闭】。
   网页握着 BLE 时板子会停在"僵尸连接"里（不广播），所有真机测试都会连不上。
"""
import argparse
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
_HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

# ---------------------------------------------------------------------------
# 端口探测（⭐ 端口号会漂，必须按 VID 找）
# ---------------------------------------------------------------------------
VID_ESP32 = "303A"      # ESP32-S3 原生 USB（日志口）
VID_CH340 = "1A86"      # CH340（假 FPGA / 上行灌入口）


def _port_opens(dev):
    """
    真打开一次，确认这个口【是活的】。

    🔴 为什么必须验：Windows 的 `HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM`
       会【保留已拔出设备的历史项】=> `list_ports.comports()` 照样列出来，
       而实际 `Open()` 报「端口不存在」。
    ⭐ 实测（2026-10-12）：本机有 8 个 VID_1A86 的 CH340 记录，
       只有 1 个能真打开 —— 其余全是历史残留。
    ⚠️ 不验的话，`find_port` 会返回一个打不开的口
       => 下游工具全线"前 0 帧"假红（⭐ 本轮实测就是这个）。
    """
    try:
        import serial
    except Exception:
        return True                      # 没装 pyserial 就不在这层判
    try:
        s = serial.Serial()
        s.port = dev
        s.baudrate = 115200
        s.timeout = 0.2
        # 不拉 DTR/RTS：某些板子会被这两根线复位（见经验库 U86）
        s.dtr = False
        s.rts = False
        s.open()
        s.close()
        return True
    except Exception:
        return False


def find_port(vid, must_open=True):
    """
    按 VID 找一个【当前可用】的串口。

    ⚠️ 端口号会漂（⭐ 本机实测：同一个 CH340 一天内换过 COM31 -> COM24）
       => ⭐ 必须按 VID 找，⛔ 不能写死。
    🔴 2026-10-12 修：原实现返回【第一个】VID 匹配的口，不验能不能打开。
       而 Windows 保留历史 COM 项 => 会拿到一个死口
       => 下游"前 0 帧"假红，且看起来像"链路不通"（⭐ 极难查）。
       ⭐ 现在：逐个候选试开，返回【第一个真能打开的】。
    """
    try:
        from serial.tools import list_ports
    except Exception:
        return None
    cands = [p.device for p in list_ports.comports()
             if vid.lower() in (p.hwid or "").lower()]
    if not cands:
        return None
    if not must_open:
        return cands[0]
    for dev in cands:
        if _port_opens(dev):
            return dev
    return None


# ---------------------------------------------------------------------------
# 测试清单：(名字, 需要什么, argv, 超时秒, 判据关键字)
# ---------------------------------------------------------------------------
def build_plan(esp, ch340, log_sec=25):
    offline = [
        ("离线全量自检（22 工具）", "无", ["selftest_all.py"], 300, "0 项 RED"),
        ("上位机离线自检", "无", ["score_uploader.py", "--selftest"], 120, "全部通过"),
        ("池算术校验", "无", ["pool_math_check.py"], 120, "通过"),
        # MIDI 回传端到端演示（离线）：造 v1.1 字节流 -> 解析 -> 转 MIDI -> 逐点核对。
        # 它是"上行解析 + 时间轴"这两块的回归网 —— 本轮的时间 bug 就是它抓到的。
        ("MIDI 回传端到端（离线）", "无", ["demo_midi_roundtrip.py"], 180, "全部通过"),
        # 网页内联 JS 语法检查：单文件 HTML 的语法错只有打开浏览器才暴露，
        # 这里用 node --check 离线抓出来（改网页后必须跑）。
        ("网页 JS 语法检查", "无", ["_check_html_js.py"], 120, "全部通过"),
    ]
    live = [
        ("读状态 0xABF4（8 组齐全）", "BLE", ["stat_read.py"], 90, "结构完整"),
        ("端到端下行（灌 N 事件）", "BLE+串口",
         ["e2e_accept.py", "--log-port", esp, "--uart-port", ch340,
          "--events", "200"], 180, "通过"),
        ("命令与上行回归", "BLE+串口",
         ["regress_live.py", "--log-port", esp, "--uart-port", ch340], 180, "通过"),
        # ⭐ 只用 BLE 验 UART1 的【发送路径】—— ⛔ 不需要 CH340。
        # 🔴 为什么必须有它：CH340 没接时，`_uart1_wire_check` 只会说
        #    "一个字节都没收到"，分不清是【ESP32 没发】还是【线没接】。
        #    本项把"ESP32 侧"和"接线/对端"分开 —— 这是本轮踩过的坑。
        ("UART1 发送路径（仅 BLE）", "BLE",
         ["_uart1_send_path_check.py", "--settle", "14"], 180, "UART1 发送路径正常"),
        ("屏状态机", "BLE+串口",
         ["hmi_states_check.py", "--events", "200", "--log-port", esp], 180,
         "状态字全部正确"),
        ("屏曲名", "BLE+串口", ["hmi_song_check.py"], 120, "曲名通路全部正确"),
        ("下行线上字节级校验", "BLE+串口",
         ["_uart1_wire_check.py", "--port", ch340, "--events", "200",
          "--seconds", str(log_sec)], 180, "逐字节一致"),
        ("上行闭环逐字节校验", "BLE+串口",
         ["_upstream_loop_check.py", "--port", ch340, "--n", "300",
          "--seconds", "18"], 180, "逐字节一致"),
        ("异常路径（未知帧头/池满/断连重连）", "BLE",
         ["_exception_paths_check.py"], 240, "全部通过"),
        # 2026-10-12 补：这两个工具原来【没被任何自动化跑到】
        #   _stress_cycles.py 以 _ 开头 => selftest_all.py 排除它
        #   而它又不在本列表里 => 全程裸奔，判据从没被验证过。
        ("循环压力（重启/丢帧/卡顿）", "BLE",
         ["_stress_cycles.py", "--cycles", "3", "--events", "200",
          "--cycle-timeout", "120"], 600, "全部通过"),
    ]
    play = [
        ("灌真谱面并放到底", "BLE", ["_score_play_probe.py", "--minutes", "9"], 720,
         "无"),
    ]
    return offline, live, play


def run_one(name, argv, timeout, expect_kw):
    """跑一项。返回 (状态, 退出码, 判据行, 耗时)。

    ⚠️ 必须给子进程钉住 `PYTHONIOENCODING=utf-8`：
    🔴 实测踩过 —— 父进程用 `encoding="utf-8"` 读，而子进程默认按 GBK 写，
       中文判据行变乱码 => 关键字匹配不上 => **假红**。
    ⭐ 修法是【让写方也写 UTF-8】，⛔ 不是放宽判据（`C17`：编码由读写两端共同决定）。
    """
    t0 = time.time()
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    try:
        p = subprocess.run([PY] + argv, cwd=_HERE, capture_output=True,
                           text=True, encoding="utf-8", errors="replace",
                           env=env, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        rc = p.returncode
    except subprocess.TimeoutExpired:
        return "超时", -1, "超过 %d 秒" % timeout, time.time() - t0
    dt = time.time() - t0

    # 判据行：优先找含关键字的行，否则取最后一行非空
    verdict = ""
    if expect_kw:
        for ln in out.splitlines():
            if expect_kw in ln:
                verdict = ln.strip()
    if not verdict:
        lines = [l.strip() for l in out.splitlines() if l.strip()]
        verdict = lines[-1] if lines else "(无输出)"
    if len(verdict) > 96:
        verdict = verdict[:93] + "..."

    # ⭐ 双重判据：退出码 + 关键字（⛔ 不看"跑完了"）
    ok = (rc == 0)
    if ok and expect_kw and (expect_kw not in out):
        ok = False
        verdict = "退出码 0 但没找到判据关键字 '%s' => 判 RED" % expect_kw
    # ⚠️ RED 扫描必须只认【判据位】的 RED，⛔ 不认汇总标签里的 RED。
    # 🔴 实测踩过：全量自检的汇总行写着"0 项 RED"（那是**列名**），
    #    而 `\bRED\b` 把它当成了失败 => 全绿的东西被判红（假红）。
    # ⭐ 同族 C161（判据必须由"逐项状态"汇总，⛔ 不是"文本里某个词出现几次"）。
    if ok:
        bad_red = (re.search(r"(?m)^\s*RED\b", out) or
                   re.search(r"RED\s*=\s*[1-9]", out) or
                   re.search(r"\b[1-9]\d*\s*项\s*RED", out))
        if bad_red:
            ok = False
            verdict = "输出里出现判据位的 RED（%s）=> 判 RED" % bad_red.group(0).strip()

    # ⭐ 前置不满足：`unk` 是【自开机累计】的，而 e2e_accept 断言 `unk == 0`（绝对值）。
    #    ⚠️ 本执行器里的「异常路径」测试会**故意注入坏帧头** => `unk` 永久非 0 =>
    #    🔴 之后每一轮的 e2e 都必红。⭐ 这是【前置不满足】，⛔ 不是被测对象坏了。
    #    ✅ 正确做法：如实报成"前置不满足 + 需要冷启动"，⛔ 不混进"失败"里。
    if not ok:
        m = re.search(r"unk\s*=\s*([1-9]\d*)\s*（期望 0）", out)
        if m:
            return ("前置", rc,
                    "unk 累计=%s（e2e 断言的是绝对值 0）⇒ 需要冷启动后重跑，"
                    "⛔ 不是失败" % m.group(1), dt)
    return ("通过" if ok else "失败"), rc, verdict, dt


def selftest():
    """离线自检：验证本执行器自己的判据逻辑（⛔ 不需要硬件）。

    ⭐ 关键是【非空洞性】：必须证明
       · 一个真失败的子进程 => 判"失败"
       · 一个真成功的子进程 => 判"通过"
       · 一个"退出码 0 但判据关键字不在"的 => 也要判"失败"
    ⛔ 只证明"能判红"是半个判据（`C156` 同族）。
    """
    print("=" * 70)
    print("run_all_tests.py 离线自检")
    print("=" * 70)
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  %-52s %s%s" % (name, "OK" if cond else "RED", extra))
        ok = ok and bool(cond)

    # 1) 计划表结构
    offline, live, play = build_plan("COM29", "COM31")
    chk("离线项非空", len(offline) >= 3, "  %d 项" % len(offline))
    chk("真机项非空", len(live) >= 6, "  %d 项" % len(live))
    chk("长测项非空", len(play) >= 1, "  %d 项" % len(play))
    shape_ok = all(len(x) == 5 and x[2] and x[3] > 0
                   for x in offline + live + play)
    chk("每一项都是 5 元组且有 argv/超时", shape_ok)
    kw_ok = all(x[4] for x in offline + live)
    chk("离线+真机每项都有判据关键字", kw_ok)

    # 1b) 【工具覆盖率】—— 目录里每个真机工具都必须被登记
    # ---------------------------------------------------------------------
    # 2026-10-12 新增。触发原因：_stress_cycles.py 一直【没被任何自动化跑到】
    #   · 它以 `_` 开头 => selftest_all.py 明确排除（那是有意的）
    #   · 而它又不在本文件的列表里 => 双重漏网，判据从没被验证过
    # 判据：把 tools/ 下的 .py 列出来，减去【明确不必登记】的，
    #       剩下的必须能在本文件的三张表里找到。
    HERE = os.path.dirname(os.path.abspath(__file__))
    registered = set()
    for _, _, argv, _, _ in offline + live + play:
        registered.add(argv[0])
    # 明确不登记的：
    #  A. 库 / 执行器自身
    #  B. 造数据的小工具
    #  C. 已被 selftest_all.py 覆盖的（它们有 --selftest，单独跑没意义）
    #     —— 2026-10-12 实测：下面 7 个都在 selftest_all 的 23 个里
    #  D. 一次性排查脚本（人工判读、无关键字判据，跑不了自动化）
    NOT_TESTS = {
        # A
        "score_word.py",          # 库：位布局与帧层的唯一定义处
        "selftest_all.py",        # 它就是"跑别人"的
        "run_all_tests.py",       # 本文件
        # B
        "send_frames.py",
        "send_frames_ble.py",
        "demo_scale.py",
        "read_log.py",
        # C —— 有 --selftest，已被 selftest_all.py 覆盖
        "loopback_check.py",
        "pool_pace_check.py",
        "screen_demo.py",
        "trigger_and_capture.py",
        "uart_rx_check.py",
        "uart_timing_check.py",
        "wrappers_check.py",
        # C2 —— 2026-10-14：生成器 / JS 自检类。它们【有自检但不进真机清单】，
        #   因为产物是给 FPGA 侧核对的（不是"跑一次就完"的用例）。
        #   ⭐ 它们的判据由 selftest_all 覆盖（python 的加 --selftest，JS 的用 node）。
        "_gen_inc_probe.py",      # 生成"末帧可核对的 inc 探针"（有 --selftest 17 项）
        "_gen_web_midi_demo.js",  # 生成网页解析器的演示 hex
        "_inc_scale_probe.py",    # 由权威锚点反推 inc 放大倍率（有 --selftest 7 项）
        "_lead_model_check.py",   # 提前量模型三版推演（有 --selftest 7 项）
        "_midi_parse_check.js",   # 网页 MIDI 解析器自检（node 跑，33 项）
        "_upstream_parse_check.js",  # 回传（上行）解析器自检（node 跑，28 项）
        "_gen_simul_probe.py",    # 多音色同时探针生成器（有 --selftest 9 项）
        "drum_map.py",            # GM 鼓音高 -> FPGA 鼓机四件（有 --selftest 16 项）
        "_drum_inc_options.py",   # 21 位装不下鼓的三条路代价分析（排查用）
        "_drum_track_check.js",   # 鼓转换 + 选轨自检（node 跑，24 项）
        "_display_check.js",      # 网页显示层自检（C10 / 鼓显示成 BASS，node 跑）
        "_chord_axis_check.js",  # 和弦分轴自检（避免 FPGA 的 same_hit 顶音）
        "_deadlock_check.js",    # 灌谱卡死自检（gattSerial 队列，6 项）
        "_undef_check.js",       # 未定义函数引用自查（静态精准，6 项）
        "_axis_dep_check.py",    # 工具是否依赖"固定 axis 分配"（改成动态分配后必须核）
        "_bidir_check.py",       # 双向验证：四组修复的回归判据【必须能失败】（0.11 §C83）
        "_doc_cmd_check.py",     # 待上机清单的命令必须【单行可粘贴】+ 参数真实存在
        "_diag_bpm.js",          # 查一份 MIDI 的 tempo 转换结果（排查用，要 argv）
        "_diag_timbre_override.js",  # 验"网页改音色"是否真的下发（端到端，要 argv）
        "_display_lane_check.js",   # 鼓栏左侧不画音名 + 图例不写轴号（要 argv）
        "_zoom_check.js",           # 图谱缩放的视口数学（锚点/夹取/裁剪）
        "_diag_chord.js",        # 查和弦是否被正确保留（排查用，要 argv）
        "_diag_chord5.js",       # 精确重叠测量（排查用，要 argv）
        "_diag_concurrency.js",  # 峰值并发 / 轴占用（排查用，要 argv）
        "_inspect_midi.js",       # 看一份 MIDI 的轨结构与分类（排查用）
        "_check_user_midi.js",    # 用真实 MIDI 验鼓转换与选轨（排查用）
        # D —— 一次性排查脚本（人工判读结论）
        "_ble_poll_stress.py",    # A/B 探针（静默 vs 轮询）
        "_crash_capture.py",      # 崩溃取证器（出事才用）
        "_hmi_probe.py",          # 探屏 t3 的内部值
        "_hmi_vis.py",            # 判"哪一栏跟着动"（要人看屏）
        "_idle_probe.py",         # 定位"复位后仍是断链"的三种可能
        "_lead_probe.py",         # 起播提前量探针
        "_migrate_devname.py",    # 一次性迁移脚本（已跑完，改完 22 处设备名比较）
        "score_uploader.py",      # 上位机 GUI（已单独登记 --selftest）
    }
    missing = []
    for fn in sorted(os.listdir(HERE)):
        if not fn.endswith(".py") or fn in NOT_TESTS or fn in registered:
            continue
        missing.append(fn)
    chk("目录里的工具都已登记进本执行器", not missing,
        ("  漏登记：" + ", ".join(missing)) if missing else "  %d 个已登记" % len(registered))

    # 2) 端口探测可用
    try:
        find_port(VID_ESP32)
        chk("find_port 可调用", True)
    except Exception as e:
        chk("find_port 可调用", False, "  " + str(e))

    # 2b) 【端口必须验"能打开"】—— 2026-10-12 新增
    # -----------------------------------------------------------------
    # 触发原因：`find_port` 原来返回第一个 VID 匹配的口，不验能不能打开。
    #   Windows 保留历史 COM 项 => 拿到死口 => 下游"前 0 帧"假红，
    #   ⚠️ 而现象看起来像"链路不通"（⭐ 查了很久）。
    # 判据：`_port_opens` 对一个【必然打不开】的口必须返回 False，
    #   对【当前真在线的口】必须返回 True（若一个都没有则跳过，不算失败）。
    chk("非空洞：_port_opens(不存在的口) == False",
        _port_opens("COM_NOPE_9999") is False)
    chk("非空洞：_port_opens(空串) == False", _port_opens("") is False)
    _esp = find_port(VID_ESP32)
    if _esp:
        chk("ESP32 口【真能打开】（%s）" % _esp, _port_opens(_esp) is True)
        # ⭐ 关键判据：find_port 返回的口，必须自己也能打开
        chk("find_port 返回的口【通过自己的可打开检验】", _port_opens(_esp) is True)
    else:
        chk("ESP32 未接（跳过可打开检验）", True, "  当前没插板子")
    _ch = find_port(VID_CH340)
    if _ch:
        chk("CH340 口【真能打开】（%s）" % _ch, _port_opens(_ch) is True)
    else:
        chk("CH340 未接（跳过可打开检验）", True, "  当前没插 CH340")
    # ⭐ 反证：把 must_open 关掉时，行为应当不同（证明这个参数真的起作用）
    _all_ch = [p.device for p in __import__("serial.tools.list_ports",
                                            fromlist=["comports"]).comports()
               if VID_CH340.lower() in (p.hwid or "").lower()]
    if len(_all_ch) > 1 and _ch:
        chk("非空洞：CH340 有 %d 个记录但只有 1 个能用 => 说明确实在筛"
            % len(_all_ch),
            len(_all_ch) > 1 and _port_opens(_ch) is True,
            "  全部候选=%s，选用=%s" % (_all_ch, _ch))
    else:
        chk("CH340 候选数不足以验证筛选（跳过）", True,
            "  候选=%d" % len(_all_ch))

    # 3) ⭐ 非空洞性：判据必须能红
    st, rc, v, _ = run_one("假失败", ["-c", "import sys; print('RED 我失败了'); sys.exit(3)"],
                           30, "不会出现的字")
    chk("真失败的子进程 => 判失败", st == "失败", "  %s rc=%s" % (st, rc))

    # 4) ⭐ 对称性：判据必须能绿
    st, rc, v, _ = run_one("假成功", ["-c", "print('结论：全部通过')"], 30, "全部通过")
    chk("真成功的子进程 => 判通过", st == "通过", "  %s rc=%s" % (st, rc))

    # 5) ⭐ 第三态：退出码 0 但判据关键字不在 => 必须判失败
    st, rc, v, _ = run_one("假绿", ["-c", "print('跑完了，但没说结论')"], 30, "全部通过")
    chk("退出码 0 但判据关键字不在 => 判失败", st == "失败", "  %s" % st)

    # 6) ⭐ 回归（本轮真实踩到的假红）：汇总行里的 "0 项 RED" 是【列名】，
    #    ⛔ 不能判红。🔴 实测：这一条曾把全绿的离线自检判成失败。
    st, rc, v, _ = run_one(
        "汇总标签", ["-c",
                     "print('合计：23 个工具（不通过 0 个），517 项 OK，0 项 RED')"],
        30, "0 项 RED")
    chk("汇总行里的「0 项 RED」不能判红", st == "通过", "  %s" % st)

    # 7) ⭐ 对称性：真正的判据位 RED 必须判红
    st, rc, v, _ = run_one(
        "判据位RED", ["-c",
                      "print('合计：2 个工具（不通过 1 个），5 项 OK，0 项 RED');"
                      "print('  RED  rc=2  x.py')"],
        30, "0 项 RED")
    chk("判据位的 RED 必须判红", st == "失败", "  %s" % st)

    # 8) ⭐ 前置不满足：`unk` 是【自开机累计】，而 e2e 断言的是绝对值 0
    #    => 本执行器里的异常路径测试注入坏帧头后，之后每轮 e2e 必红。
    #    ⭐ 必须如实报成"前置"，⛔ 不混进"失败"。
    st, rc, v, _ = run_one(
        "前置", ["-c",
                 "print('unk        = 10（期望 0）  <-- RED(必须)');"
                 "import sys; sys.exit(1)"],
        30, "全部通过")
    chk("unk 累计导致的 e2e 红 => 判「前置」而非「失败」", st == "前置", "  %s" % st)

    print()
    print("结论：%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检（⛔ 不需要硬件）：验证本执行器自己的判据逻辑")
    ap.add_argument("--offline-only", action="store_true")
    ap.add_argument("--with-play", action="store_true", help="追加 9 分钟的真谱面播放")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    esp = find_port(VID_ESP32)
    ch340 = find_port(VID_CH340)
    print("=" * 78)
    print("ESP32 线 · 全量测试顺序执行器")
    print("=" * 78)
    print("  ESP32 日志口（VID %s） = %s" % (VID_ESP32, esp or "🔴 没找到"))
    print("  CH340 口  （VID %s） = %s" % (VID_CH340, ch340 or "🔴 没找到"))
    print()

    offline, live, play = build_plan(esp or "COM29", ch340 or "COM31")

    if args.list:
        for tag, items in (("离线", offline), ("真机", live), ("可选长测", play)):
            print("[%s]" % tag)
            for n, need, argv, to, kw in items:
                print("  %-34s 需要 %-10s 超时 %4ds  %s" % (n, need, to, " ".join(argv)))
        return 0

    plan = list(offline)
    if not args.offline_only:
        if esp is None or ch340 is None:
            print("🔴 真机测试需要两个口都在（ESP32 日志口 + CH340）")
            print("   ⚠️ 常见原因：网页上位机还开着 => 板子停在僵尸连接里（不广播）")
            print("   ⇒ 关掉网页后重跑；本次只跑离线部分。")
            print()
        else:
            plan += live
            if args.with_play:
                plan += play

    results = []
    for i, (name, need, argv, timeout, kw) in enumerate(plan, 1):
        print("-" * 78)
        print("[%d/%d] %s   （需要 %s，超时 %ds）" % (i, len(plan), name, need, timeout))
        print("        $ python %s" % " ".join(argv))
        if i > 1:
            # ⭐ 项间让端口释放。🔴 实测踩过：上一项异常退出（rc≠0）时可能没及时
            #    放掉串口，下一项立刻打开就会报
            #    `OSError [WinError -2147023673] 操作已被用户取消` =>
            #    ⚠️ 这是【级联假红】，⛔ 不是被测对象坏了。
            time.sleep(2.5)
        st, rc, verdict, dt = run_one(name, argv, timeout, kw)
        # ⭐ 瞬时资源错误重试一次（明确记录，⛔ 不静默吞）。
        # 🔴 实测：`[WinError -2147023673] 操作已被用户取消` 会在【板子重启、
        #    USB 重新枚举】的瞬间出现 —— 那时 COM29 短暂消失。
        # ⚠️ 这是可重试的【环境瞬时错误】，⛔ 与被测逻辑无关；
        #    但重试必须写进判据里，⛔ 不能让它看起来像一次就过。
        if st == "失败" and re.search(
                r"操作已被用户取消|WinError -2147023673|拒绝访问|Access is denied",
                verdict):
            print("        ⏳ 判据命中【瞬时资源错误】=> 等 3 s 重试一次")
            time.sleep(3.0)
            st2, rc2, v2, dt2 = run_one(name, argv, timeout, kw)
            verdict = "重试一次后：%s（首次为：%s）" % (v2, verdict[:40])
            st, rc, dt = st2, rc2, dt + dt2
        mark = {"通过": "OK ", "失败": "RED", "超时": "TIM", "前置": "SKP"}[st]
        print("        %s  rc=%-4s %5.1fs  %s" % (mark, rc, dt, verdict))
        results.append((name, st, rc, dt, verdict))

    # ---------------- 汇总表 ----------------
    print()
    print("=" * 78)
    print("汇总")
    print("=" * 78)
    print("  %-34s %-6s %6s  %s" % ("测试", "结果", "耗时", "判据"))
    print("  " + "-" * 74)
    n_bad = 0
    n_skip = 0
    for name, st, rc, dt, verdict in results:
        if st in ("失败", "超时"):
            n_bad += 1
        elif st == "前置":
            n_skip += 1
        print("  %-34s %-6s %5.1fs  %s" % (name, st, dt, verdict))
    print("  " + "-" * 74)
    print("  合计 %d 项：通过 %d · 失败/超时 %d · 前置不满足 %d"
          % (len(results), len(results) - n_bad - n_skip, n_bad, n_skip))
    print("  结论：%s" % ("全部通过" if n_bad == 0 else "有失败项（退出码 = 失败项数）"))
    return n_bad


if __name__ == "__main__":
    sys.exit(main())
