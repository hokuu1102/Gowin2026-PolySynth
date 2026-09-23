# 🌉 `esp32/bridge/` · 固件工程（ESP-IDF）

> **两套模式，同一份工程**（⭐ 切换见 `main/bridge_config.h` 的 `BRIDGE_MODE`）：
>
> | 模式 | 谁限速 | ESP32 懂事件格式吗 | 断链容忍 | 状态 |
> |---|---|---|---|---|
> | ⭐ **A · 纯透传** | **PC**（`evt2uart.py`，已验证） | ✅ **不用** | ⚠️ = 提前量（≤11.4 s） | ⭐ **先做这个** |
> | ⚠️ **B · 二级水池** | **ESP32 自己** | 🔴 **要读 `tick`/`kind`** | ⭐ **整曲（可达 300 s）** | ⏸ A 跑通后再上 |

---

## 一、⚠️ 开工前第一件事：确认芯片

🔴 **必须是初代 ESP32（经典版）**，⛔ **不是 S3** —— **S3 没有经典蓝牙**，SPP 不可能。

```powershell
# ⭐ 一句话定死芯片型号（需先装好 Python + esptool）
.\build.ps1 -Action chipid -Port COM7
#    ✅ 期望：Chip is ESP32-D0WD-V3
#    🔴 若报 ESP32-S3 / ESP32-S2  ⇒ 芯片错了，⛔ 停下来
```

---

## 二、⭐ 固件的唯一关键设计：**9N 对齐**

> 🔴🔴 **写 UART 的字节数【恒为 9 的整数倍】**（余数留到下次）。

**为什么** —— 已查 RTL 源码确认（`rtl/w3c/evt_uart_rx.v:203`）：

```verilog
end else if (idle_expired && (idx_q != 4'd0))   // 只在【帧中途】触发
```

⇒ ⭐ **帧与帧之间可以任意停顿**（谱子时间，几百 ms 都行）；
🔴 **只有一帧【内部】被打断才会截帧**。

门限 = `GAP_BYTES`(16) 个字节时间：**1 Mbps ⇒ 160 µs**；115200 ⇒ 1.39 ms。

而 **RFCOMM 是字节流，⛔ 不保留 `write()` 边界** ⇒
PC 的一次 `write(9字节)` 到 ESP32 **可能变成两次回调**，中间隔一个任务调度周期（可达 ms）
⇒ 🔴 **远超门限 ⇒ 必然截帧**。

⚠️ **后果特别难查**：内容全对、帧却散架 ⇒ FPGA 侧**默默少几个音**，
而 `resync_cnt`/`hdr_err_cnt` **不一定涨**。

### 实现要点

| # | 要求 | 代码位置 |
|---|---|---|
| **1** | 缓冲容量取 9 的整数倍（**1026 = 9×114**） | `bridge_config.h` · `ALIGN_BUF_CAP` |
| **2** | 只有凑够 9N 才取出（`floor(cnt/9)*9`） | `bridge_main.c` · `bridge_take_aligned()` |
| **3** | 取出后**一次性**写 UART（⛔ 不分 9 次） | `bridge_main.c` · `task_drain_to_uart()` |

✅ **全程不看内容、不改内容** ⇒ ⭐ **仍然算透传**。

---

## 三、⭐ 接线

```
PC ──USB────> ESP32（蓝牙 SPP）      ← 发送端
PC ──USB-TTL─> ESP32 UART2           ← 接收端
```

| 项 | 值 |
|---|---|
| UART2 引脚 | **GPIO17 = TX / GPIO18 = RX**（⚠️ 避开 GPIO43/44 日志口） |
| 波特率 | 默认 **1 Mbps**（⚠️ 见下方"两边必须一致"） |
| 接 FPGA 时 | ⚠️ **交叉接**：ESP32 TX(GPIO17) → FPGA `G22`；ESP32 RX(GPIO18) ← FPGA `G21` |

### 🔴 波特率两边必须一致

| 位置 | 现值 |
|---|---|
| ⭐ **本固件** | `BRIDGE_BAUD` = **1000000** |
| ⚠️ **FPGA 侧** | **115200**（`uart_rx.v:47` = 434；`evt_uart_rx.v:72` = 115200） |

⇒ ⚠️ **一边改了另一边没改 = 完全收不到**。⭐ 回环自测时**两个值都要跑**。

---

## 四、构建

### 4.1 ⚠️ 先激活 ESP-IDF（⭐ 本机实测踩过的坑）

> 🔴 **本机实况（2026-09-23 实测）**：ESP-IDF **v5.5** 用官方安装器（EIM）装到了
> **`C:\Espressif`**，工具在 **`C:\Espressif\tools`** ——
> ⚠️ **⛔ 不是默认的 `~\.espressif`**。

🔴 **直接跑 ESP-IDF 自带的 `export.ps1` 会失败**：

<!-- refcheck:off -->
> ⚠️ 下面这段说的是 **ESP-IDF 安装目录里**的 `export.ps1`
> （本机即 `C:\Espressif\v5.5\esp-idf\export.ps1`），
> ⛔ **它是仓库外的本机路径，不是本仓库的文件** ⇒ 故此处豁免交叉引用检查。
<!-- refcheck:on -->

```
ERROR: ESP-IDF Python virtual environment
  "C:\Users\<user>\.espressif\python_env\idf5.5_py3.12_env\Scripts\python.exe" not found.
```

⭐ **原因**：`export.ps1` 假定 `IDF_TOOLS_PATH` 是默认值，而实际装在 `C:\Espressif\tools`。

✅ **正确做法** —— 用 **EIM 自己写的 profile 脚本**（路径记录在 `eim_idf.json` 里）：

```powershell
. "C:\Espressif\tools\Microsoft.v5.5.PowerShell_profile.ps1"
#   ✅ 成功后应看到：IDF_PATH / IDF_TOOLS_PATH / IDF_PYTHON_ENV_PATH
```

> ⚠️ **`idf.py` 是 profile 定义的【自定义命令】，⛔ 不是 PATH 上的可执行文件**
> ⇒ ⭐ **每次 `pwsh` 都是新进程**，必须在**同一条命令里**先激活再调用。
> ⭐ `build.ps1` 已**自动检测并激活**（只需 `IDF_PATH` 为空时它会自己 dot-source 上面那个脚本）。

### 4.2 编译

```powershell
cd esp32\bridge
.\build.ps1 -Action build              # 编译（会自动激活 ESP-IDF）
.\build.ps1 -Action flash -Port COM7   # 烧录
.\build.ps1 -Action monitor -Port COM7 # 看日志
```

⚠️ **首次 `build` 会自动用 `sdkconfig.defaults` 生成 `sdkconfig`**（含 `CONFIG_BT_SPP_ENABLED=y`）。
⚠️ 目标芯片在 `sdkconfig.defaults` 里已写死 `CONFIG_IDF_TARGET="esp32"`（🔴 初代，⛔ 不是 S3）。

### 4.3 ⭐ 切换模式 A / B（⭐ 用 `-D`，⛔ 别改文件）

```powershell
idf.py build                    # 模式 A（纯透传）—— 默认
idf.py -DBRIDGE_MODE=1 build    # 模式 B（二级水池）
```

> 🔴 **两个坑，都是"看起来成功、其实没生效"（⭐ 2026-09-23 实测踩到）**：
>
> **坑 ①：`-D` 到不了 C 编译器**
> `idf.py -DBRIDGE_MODE=1` 只建了个 **CMake 缓存变量**，
> ⛔ **不会自动变成 `-D` 传给编译器** —— 实测 `build/CMakeCache.txt` 里只有
> `BRIDGE_MODE:UNINITIALIZED=1`。
> ⇒ 🔴 结果是**两种模式编出【逐字节相同】的 binary**（都是 `0xa40f0`），
>   模式静默停在 A，⚠️ 而 build **一声不响**。
> ⇒ ⭐ 修法：`main/CMakeLists.txt` 里显式 `target_compile_definitions(...)` 转发；
> ⭐ `bridge_config.h` 把默认值包在 `#ifndef BRIDGE_MODE` 里，好让 `-D` 能覆盖它。
>
> **坑 ②：CMake 缓存会粘住**
> 用 `-DBRIDGE_MODE=1` 编过一次后，**后续不带 `-D` 的 build 仍是模式 B**
> （缓存里的值还在）。⚠️ 这会让人以为"我切回 A 了"，其实没有。
> ⇒ ⭐ 换模式时**先删 `build/`**：
> ```powershell
> Remove-Item build -Recurse -Force
> idf.py build
> ```
>
> ⭐ **怎么确认切换真的生效**：看 build 输出里的
> `-- ESP32 bridge: BRIDGE_MODE=... (from command line|default)`，
> ⭐ 且**两种模式的 binary size 必须不同**（实测 A=`0xa40f0`、B=`0xa4d70`）。
> ⚠️ 若两者体积相同 ⇒ 🔴 **切换没生效**，别再往下走。

⚠️ **⛔ 不要用 PowerShell 的 `Get-Content`/`Set-Content` 改 `bridge_config.h` 来切模式** ——
⚠️ `Get-Content` 按 GBK 读 UTF-8，**会把中文注释毁掉**（本文件因此坏过 **28 行**），
🔴 而**代码是 ASCII，所以编译照样通过** ⇒ **只有注释坏了、极难发现**。

---

## 五、⭐ 自测

```powershell
cd esp32\tools

# ⭐ 先跑离线自检（⛔ 不用任何硬件）—— 证明【判据本身】是对的
python loopback_check.py --selftest

# 真回环
python loopback_check.py --tx-port COM11 --rx-port COM7 --baud 1000000
python loopback_check.py --tx-port COM11 --rx-port COM7 --baud 115200

# 用真实曲谱量级的数据
python loopback_check.py --tx-port COM11 --rx-port COM7 --hex ..\..\build\score\regen\09_Conjurer\events.hex
```

判据详见 `files/20-代码/ESP32通路总体架构-20260922.md` §6.2。

---

## 六、⚠️ 模式 B 专章（二级水池）

### 6.0 🔴 内存：⭐ 动态分配 + 优先 PSRAM + 优雅降级

> 🔴 **实测教训**：第一版水池是 `static uint8_t s_pool[128*1024]` ⇒ 进 `.dram0.bss`
> ⇒ ⚠️ **链接直接失败**：
> ```
> region `dram0_0_seg' overflowed by 51448 bytes
> section `.dram0.bss' will not fit
> ```
> ⚠️ 那是最糟的形态 —— **有无 PSRAM 都编不过**。

**实测内存账**（ESP32 经典版，BR/EDR-only，模式 A 基线）：

| 项 | 数值 |
|---|---|
| DRAM 可用总量 | **124,580 B** |
| 模式 A 已用 | **44,900 B** |
| **剩余** | **79,680 B（77.8 KB）** |
| 整曲需求（`09_Conjurer` 11,865 事件 × 9 B） | **106,785 B（104.3 KB）** |
| 🔴 缺口 | **27,105 B** |

⇒ ⭐ **所以改成 `heap_caps_malloc` 动态分配**（⛔ 不占 `.bss`），并：

| 情形 | 结果 | 断链容忍 |
|---|---|---|
| ⭐ **有 PSRAM**（`CONFIG_SPIRAM=y`） | 整曲水池 104 KB | ⭐ **整曲（~300 s）** |
| ⚠️ **无 PSRAM** | ⭐ **优雅降级**到内部 DRAM 最大块（~64 KB） | ⚠️ **约 60 秒** |
| 🔴 全失败 | 打印明确错误 | ⛔ 模式 B 不可用，**但模式 A 照常工作** |

> ⭐ **关键**：**降级不是失败**。两种情形**都能编、都能跑**，只是"断链能撑多久"不同。
> ⚠️ 而且降级/PSRAM 状态**会打印出来**（K-106 纪律：容量必须看得见）：
> ```
> pool: 131072 B in PSRAM (whole-score capable)
> pool: DEGRADED to internal DRAM: 65520 B (7280 frames, ~63 s of music)
> ```

⚠️ **开 PSRAM 的前提**：`sdkconfig.defaults` 里 `CONFIG_SPIRAM=y` **必须打开**
（默认**注释着**）。🔴 不开的话 `heap_caps_malloc(MALLOC_CAP_SPIRAM)` **一定失败**
⇒ 永远走降级分支，⚠️ **即使模组其实焊了 PSRAM 也用不上**。

⭐ **先确认模组有没有 PSRAM**：
```powershell
.\build.ps1 -Action chipid -Port COM7
#   ⭐ `ESP32-D0W R2 -V3` ⇒ 有 PSRAM ⇒ 可以开 CONFIG_SPIRAM
#   ⚠️ `ESP32-D0WD-V3`     ⇒ 无 PSRAM ⇒ 保持注释
```

### 6.1 它换来什么、付什么

| | 说明 |
|---|---|
| ⭐ **换来** | **蓝牙断了 / 卡很久，音乐还能继续播**（池里还有整曲） |
| 🔴 **付出** | ① 必须读 `tick[63:44]` / `kind[10:9]` ② **溢出风险**（FPGA 无反向通道 ⇒ 是盲发） |

### 6.2 🔴 防溢出：宁可饿着，不可撑着

**溢出算术**（⭐ 离线checker 会算给你看）：

```
线速 11,111 事件/s  ÷  FPGA 消费 69.5 事件/s = 160 倍
1024 事件缓冲 ÷ 11,111 = 92 ms     ← 全速灌，92 毫秒就满
```

⇒ 因此 `pool.c` 的 `pool_pump()` 有一条**硬规则**：

> 🔴 **一旦发现落后（`due_tick` 超过本帧 tick），只把当前帧发掉，⛔ 不补发、⛔ 不追赶。**

⭐ **理由**：慢 ⇒ FPGA `evt_underrun`（**可见**）；快 ⇒ FPGA 缓冲溢出（🔴 **静默丢**）。
⭐ 与 §4.4「不做反向通道」是配套的 —— 开环下**只能靠可观测 + 可归因**。

### 6.3 ⭐ 提前量的取值依据

`BRIDGE_POOL_LEAD_TICKS = 20000`（在 `bridge_config.h`）：

| 曲子 | 换算 | 占 FPGA 缓冲（1024 事件） |
|---|---|---|
| `夜洋风景`（最密，99.3 事件/小节） | 5.21 小节 ≈ **517 事件** | **51%** ✅ |
| `09_Conjurer`（55.9 事件/小节） | 5.21 小节 ≈ **291 事件** | **28%** ✅ |

⇒ ⭐ **留了近一半余量**给突发和弦（单拍最多 24 条）与时钟漂移。

### 6.4 ⭐ 控制通道（⚠️ 只在模式 B）

整曲灌完后总得有人喊"开始"。而**冻结接口里没有这个命令**
（🔴 协议缺口，见 `FPGA侧对接清单-ESP32通路-20260922.md` §五 问题 1）。

⇒ 本固件用**带外控制**（⛔ 控制字节不进水池）：

| 命令 | 含义 |
|---|---|
| `0x1B 'S'` | **start** —— 开始放水 |
| `0x1B 'D'` | **done** —— 声明整曲灌完 |
| `0x1B 'R'` | **reset** —— 清空水池 |
| `0x1B '?'` | **stats** —— 回一段状态文本 |

⚠️ **前提**：数据流里**不能出现 `0x1B`**（否则会被误判为控制前缀）。
⭐ 若做不到，就改用"发完即断开 SPP"（断连 = 开始）的方案。

### 6.5 🔴 两个已修的算术 bug（⭐ 都是离线 checker 抓的）

| # | 写法 | 后果 |
|---|---|---|
| **①** | `us = dticks * 2^32 * 1e6 / (inc * F)` 算**绝对时刻** | ⚠️ 整曲需 **72 bit** ⇒ 64 位回绕 ⇒ 算出 **0.9 s**，真值 **303 s**（最大误差 **3.02 亿 µs**） |
| **②** | 改成 `per1k = 每 1000 tick 多少 us` 再乘 | ⚠️ `per1k` 只有 7 位有效数字 ⇒ 整曲累积 **154 µs** |

⇒ ⭐ **最终方案：增量式** —— 不算绝对时刻，只把"已过微秒"换算成"谱面 tick 进度"：
`dticks = us × inc × F / (2^32 × 1e6)`，中间量只随**一次 pump 的间隔**增长（≤500 ms ⇒ 63 bit）✅

⭐ **复算命令**（⛔ 不用硬件）：
```powershell
cd esp32\tools
python pool_math_check.py
```

---

## 七、⚠️ 边界

| # | 约束 |
|---|---|
| **1** | 🔴 **⛔ 不要动 `rtl/` `constr/` `tools/`** —— ⚠️ **另有其人负责**，⭐ 且那边**正在改 `rtl/`** |
| **2** | ⚠️ **电平 3.3 V**，⛔ 别接 5 V |
| **3** | ⭐ **ESP32 ⛔ 绝不碰音频/视觉的【生成】**（🔴 合规红线） |
| **4** | ⭐ **模式 A ⛔ 不解析事件格式**；⚠️ 模式 B 只读 `tick`/`kind`（用于限速） |

---

## 附 · 关联文档

| 想看什么 | 去哪 |
|---|---|
| ⭐⭐ 总体架构（主文档） | `files/20-代码/ESP32通路总体架构-20260922.md` |
| ⭐ 交接文档（含 8 处更正） | `files/20-代码/ESP32通路交接文档-20260922.md` |
| ⭐ FPGA 侧对接清单 | `files/20-代码/FPGA侧对接清单-ESP32通路-20260922.md` |
| ⭐ 事件格式（冻结） | `files/20-代码/play_seq接口冻结契约.md` |
