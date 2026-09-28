"""提取 tb_nm_leak VCD 中【卡住的 ADSR】的逐拍轨迹。

目标：从"能复现挂音"升级为"知道它为什么挂"。

方法：
  1. 解析 VCD，拿到每个 adsr 实例的 env_level_o / state / releasing / gate_i 短码
  2. 回放整个仿真，采样每个 adsr 的 (env, state, releasing, gate)
  3. 找"最后 env != 0 且长时间不变"的实例 => 卡住的 voice
  4. 打印它卡住【之前】N 个变化点，看它是怎么走到那一步的

只读分析，不改 RTL。
"""
import sys

VCD = r"C:\Users\hokuu\Desktop\FPGA\FPGA2026\build\sim\tb_nm_leak\tb_nm_leak.vcd"
N_WATCH = 32


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

    adsr_paths = sorted({p for (p, n) in code_of if p.endswith("u_adsr")},
                        key=lambda x: int(x.split("[")[1].split("]")[0]))
    print(f"adsr instances: {len(adsr_paths)}")

    # 每个实例关心的信号短码
    watch = []          # list of dict(code -> field)
    for p in adsr_paths:
        d = {}
        for f in ("env_level_o", "state", "releasing", "gate_i", "retrig_reset_i"):
            if (p, f) in code_of:
                d[code_of[(p, f)]] = f
        watch.append(d)

    # ---- 回放 ----
    cur = [{"env": 0, "state": 0, "rel": 0, "gate": 0, "rr": 0} for _ in range(N_WATCH)]
    t = 0
    # 记录每个实例"最后一次 env 变化"的时刻与值
    last_change_t = [0] * N_WATCH
    last_env = [0] * N_WATCH
    # 只记录最后一个实例的轨迹（先看 0 号，若没卡再换）
    traj = [[] for _ in range(N_WATCH)]

    all_codes = {}
    for idx, d in enumerate(watch):
        for c, f in d.items():
            all_codes[c] = (idx, f)

    for ln in lines[i:]:
        s = ln.strip()
        if not s:
            continue
        if s[0] == "#":
            t = int(s[1:])
            continue
        if s[0] in "01xz":
            # 标量
            code = s[1:]
            if code in all_codes:
                idx, f = all_codes[code]
                v = 0 if s[0] == "0" else 1
                if f == "env_level_o":
                    if v != cur[idx]["env"]:
                        last_change_t[idx] = t
                        traj[idx].append((t, cur[idx].copy()))
                    cur[idx]["env"] = v
                elif f == "state":
                    cur[idx]["state"] = v
                elif f == "releasing":
                    cur[idx]["rel"] = v
                elif f == "gate_i":
                    cur[idx]["gate"] = v
                elif f == "retrig_reset_i":
                    cur[idx]["rr"] = v
        elif s[0] == "b":
            parts = s.split()
            if len(parts) == 2:
                code = parts[1]
                if code in all_codes:
                    idx, f = all_codes[code]
                    try:
                        v = int(parts[0][1:], 2)
                    except ValueError:
                        v = 0
                    if f == "env_level_o":
                        if v != cur[idx]["env"]:
                            last_change_t[idx] = t
                            traj[idx].append((t, cur[idx].copy()))
                        cur[idx]["env"] = v
                    elif f == "state":
                        cur[idx]["state"] = v

    print(f"final sim time = {t}")
    print()
    print("=== per-voice final state ===")
    print(" idx | env | state | rel | gate | rr  | last_env_change_t | frozen_for")
    frozen = []
    for idx in range(N_WATCH):
        c = cur[idx]
        dt = t - last_change_t[idx]
        if c["env"] != 0:
            frozen.append(idx)
        print(f" {idx:3d} | {c['env']:5d} | {c['state']:5d} | {c['rel']:3d} | "
              f"{c['gate']:4d} | {c['rr']:3d} | {last_change_t[idx]:>17d} | {dt}")

    print()
    print(f"voices with env != 0 at end: {frozen}")
    if not frozen:
        print("no stuck voice -- nothing to trace")
        return 0

    # ---- 打印第一个卡住 voice 的最后若干次变化 ----
    v = frozen[0]
    print()
    print(f"=== trajectory of voice {v} (last 12 env changes) ===")
    print("      time | env  | state | rel | gate | rr")
    for (tt, st) in traj[v][-12:]:
        print(f" {tt:9d} | {st['env']:4d} | {st['state']:5d} | {st['rel']:3d} | "
              f"{st['gate']:4d} | {st['rr']:3d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
