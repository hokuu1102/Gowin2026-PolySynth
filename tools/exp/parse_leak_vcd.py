"""解析 tb_nm_leak 的 VCD，找出卡住的 ADSR 的逐拍轨迹。

目的：把「仿真里能复现挂音」升级为「知道它为什么挂」。
只读工具，不改任何 RTL。
"""
import sys
import re

VCD = r"C:\Users\hokuu\Desktop\FPGA\FPGA2026\build\sim\tb_nm_leak\tb_nm_leak.vcd"


def main():
    with open(VCD, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    # ---- 1. 收集 scope 路径 -> 信号短码 ----
    # VCD 结构：$scope module X $end ... $var ... $upscope $end
    scope = []
    signals = {}          # path -> {name: code}
    code_of = {}          # (path, name) -> code
    i = 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s.startswith("$scope"):
            parts = s.split()
            scope.append(parts[2])
        elif s.startswith("$upscope"):
            if scope:
                scope.pop()
        elif s.startswith("$var"):
            parts = s.split()
            # $var wire 16 ! env_level [15:0] $end
            code = parts[3]
            name = parts[4]
            path = ".".join(scope)
            code_of[(path, name)] = code
        elif s.startswith("$enddefinitions"):
            i += 1
            break
        i += 1

    # 找到 u_env 下的 adsr 实例路径
    adsr_paths = sorted({p for (p, n) in code_of if p.endswith("u_adsr")})
    print(f"adsr instances found: {len(adsr_paths)}")
    if not adsr_paths:
        print("!! no adsr scope found")
        return 2

    # 打印第 0 个 adsr 有哪些信号
    p0 = adsr_paths[0]
    names0 = sorted(n for (p, n) in code_of if p == p0)
    print(f"{p0}: {names0}")

    # 我们关心的信号
    want = ["env_level_o", "state", "releasing", "gate_i", "retrig_reset_i"]
    c = {}
    for w in want:
        if (p0, w) in code_of:
            c[code_of[(p0, w)]] = w
    print("tracking codes:", c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
