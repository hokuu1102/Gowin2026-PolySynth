"""追踪卡住 voice 的【完整状态序列】，找出 env 为何减不到 0。

关键疑点：voice 0 的 (env, state, releasing, gate) 长时间是
    (535..513, 1=ATTACK, 1, 0)
而 ATTACK 状态本应【加】env，release 本应【减】env —— 两者同时为真。

本脚本记录该 voice 的 gate / retrig_reset / state / releasing / env
每一次【变化】的时间点，按时间顺序打印，看它到底在做什么循环。
"""
import sys

VCD = r"C:\Users\hokuu\Desktop\FPGA\FPGA2026\build\sim\tb_nm_leak\tb_nm_leak.vcd"


def main():
    with open(VCD, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    scope = []
    code_of = {}
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith("$scope"):
            scope.append(s.split()[2])
        elif s.startswith("$upscope"):
            if scope:
                scope.pop()
        elif s.startswith("$var"):
            p = s.split()
            code_of[(".".join(scope), p[4])] = p[3]
        elif s.startswith("$enddefinitions"):
            i += 1
            break
        i += 1

    TARGET = "tb_nm_leak.u_env.g_voice_envelope[0].u_adsr"
    fields = ("env_level_o", "state", "releasing", "gate_i", "retrig_reset_i")
    codes = {}
    for f in fields:
        if (TARGET, f) in code_of:
            codes[code_of[(TARGET, f)]] = f
    print("TARGET:", TARGET)
    print("codes:", {v: k for k, v in codes.items()})

    cur = {f: 0 for f in fields}
    t = 0
    events = []
    for ln in lines[i:]:
        s = ln.strip()
        if not s:
            continue
        if s[0] == "#":
            t = int(s[1:])
            continue
        if s[0] in "01xz":
            code = s[1:]
            if code in codes:
                f = codes[code]
                v = 0 if s[0] == "0" else 1
                if cur[f] != v:
                    cur[f] = v
                    events.append((t, dict(cur)))
        elif s[0] == "b":
            parts = s.split()
            if len(parts) == 2 and parts[1] in codes:
                f = codes[parts[1]]
                try:
                    v = int(parts[0][1:], 2)
                except ValueError:
                    v = 0
                if cur[f] != v:
                    cur[f] = v
                    events.append((t, dict(cur)))

    print(f"total change events: {len(events)}")
    print()
    print("=== last 60 change events ===")
    print("        time_ps |      t(ms) | env  | state | rel | gate | rr")
    for (tt, st) in events[-60:]:
        print(f" {tt:15d} | {tt/1e9:10.4f} | {st['env_level_o']:4d} | "
              f"{st['state']:5d} | {st['releasing']:3d} | {st['gate_i']:4d} | "
              f"{st['retrig_reset_i']:3d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
