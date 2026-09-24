#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rename_bridge_to_ble.py -- 把从 SPP 版复制来的 pool/hmi 的标识符改成 BLE 版命名

⚠️ 为什么用 Python 而不用 PowerShell：
    今晚我刚因为 `(Get-Content -Raw) | Set-Content -Encoding UTF8` 把
    bridge_config.h 的 28 行中文注释毁成乱码 ——
    🔴 因为 **Get-Content 默认按 GBK 读 UTF-8**，再写回就是"乱码转 UTF-8"。
    ⭐ 而代码是 ASCII，所以编译照样通过 ⇒ 只有注释坏、极难发现。
    ⇒ 本项目纪律：**改含中文的文件，要么用编辑工具，要么用【显式 UTF-8】的 Python**。

⚠️ 本脚本只做【纯文本替换】，⛔ 不改 SPP 版的任何文件。
"""
import io
import os
import sys

# --- 控制台 UTF-8 -------------------------------------------------------------
for _n in ("stdout", "stderr"):
    _s = getattr(sys, _n, None)
    if _s is not None and hasattr(_s, "reconfigure"):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# ⚠️ 本脚本放在 ble/_tools/ 下，而 main/ 在【上一级】
#    （原版按"脚本同级有 main/"算，⇒ 路径错，已修）
TARGET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "main")

# ⚠️ 顺序要求：长标识符先替换，避免前缀误伤
#    例：BRIDGE_POOL_ 必须在 BRIDGE_ 之前（否则 BRIDGE_POOL_X -> BLE_POOL_X 会漏）
REPLACEMENTS = [
    # 头文件名
    ('#include "bridge_config.h"', '#include "ble_config.h"'),
    # 水池相关
    ("BRIDGE_POOL_", "BLE_POOL_"),
    # 屏相关
    ("BRIDGE_PIN_HMI_", "BLE_PIN_HMI_"),
    ("BRIDGE_HMI_", "BLE_HMI_"),
    # UART 引脚
    ("BRIDGE_UART_TX_BUF", "BLE_UART_TX_BUF"),
    ("BRIDGE_UART_RX_BUF", "BLE_UART_RX_BUF"),
    ("BRIDGE_UART_PORT", "BLE_UART_PORT"),
    ("BRIDGE_PIN_UART_TX", "BLE_PIN_UART_TX"),
    ("BRIDGE_PIN_UART_RX", "BLE_PIN_UART_RX"),
    ("BRIDGE_LOG_UART_PORT", "BLE_LOG_UART_PORT"),
    ("BRIDGE_PIN_LOG_TX", "BLE_PIN_LOG_TX"),
    ("BRIDGE_PIN_LOG_RX", "BLE_PIN_LOG_RX"),
    ("BRIDGE_BAUD", "BLE_BAUD"),
    ("BRIDGE_MODE_B_POOL", "BLE_MODE_B_POOL"),
    ("BRIDGE_MODE_A_PASSTHROUGH", "BLE_MODE_A_PASSTHROUGH"),
    ("BRIDGE_MODE", "BLE_MODE"),
    # 任务/日志
    ("BRIDGE_TASK_PRIO_", "BLE_TASK_PRIO_"),
    ("BRIDGE_STATUS_PERIOD_MS", "BLE_STATUS_PERIOD_MS"),
    ("BRIDGE_BT_NAME", "BLE_DEV_NAME"),
    ("BRIDGE_BT_TX_", "BLE_TX_"),
    ("BRIDGE_POOL_BYTES", "BLE_POOL_BYTES"),
]


def main():
    files = [f for f in os.listdir(TARGET_DIR) if f in ("pool.c", "pool.h",
                                                        "hmi.c", "hmi.h")]
    if not files:
        print("没有找到 pool/hmi 文件")
        return 1

    total = 0
    for fn in sorted(files):
        path = os.path.join(TARGET_DIR, fn)
        # ⭐ 显式 UTF-8 读写（⛔ 不用系统默认编码）
        with io.open(path, "r", encoding="utf-8") as f:
            text = f.read()
        orig = text

        count = 0
        for old, new in REPLACEMENTS:
            n = text.count(old)
            if n:
                text = text.replace(old, new)
                count += n

        if text != orig:
            with io.open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            print("  %-10s 替换 %d 处" % (fn, count))
            total += count
        else:
            print("  %-10s 无变化" % fn)

    # 检查是否还有残留
    leftovers = []
    for fn in sorted(files):
        path = os.path.join(TARGET_DIR, fn)
        with io.open(path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                if "BRIDGE_" in line:
                    leftovers.append("%s:%d  %s" % (fn, i, line.strip()[:90]))

    print("总替换 %d 处" % total)
    if leftovers:
        print("🔴 仍有 BRIDGE_ 残留：")
        for s in leftovers:
            print("   " + s)
        return 1
    print("✅ 无 BRIDGE_ 残留")
    return 0


if __name__ == "__main__":
    sys.exit(main())
