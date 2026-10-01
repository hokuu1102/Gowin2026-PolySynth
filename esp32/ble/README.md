# 📡 `esp32/ble/` · ESP32-S3 BLE 版固件（ESP-IDF）

> ⭐ **本目录是 S3 / BLE 版本**，与 `esp32/bridge/`（初代 ESP32 / SPP 版）**并存**。
> 🔴 **两者互不影响** —— 改这边⛔ 不会动到 SPP 版。

---

## 一、⚠️ 为什么会有这一版

| | `esp32/bridge/`（SPP） | ⭐ `esp32/ble/`（本目录） |
|---|---|---|
| 芯片 | 初代 ESP32 | **ESP32-S3** |
| 蓝牙 | 经典 BR/EDR + **SPP** | 🔴 **只有 BLE**（S3 无 BR/EDR） |
| PC 侧 | ⭐ 配对后是 **COM 口** ⇒ `evt2uart.py` 可直接用 | 🔴 **不是 COM 口** ⇒ 要另写客户端 |
| 手机侧 | 通用串口助手 | ⭐ 需 BLE 终端 App（支持自定义 UUID 的） |
| **PSRAM** | ⚠️ **买不到带 PSRAM 的板** | ⭐ **有** ⇒ 水池能放整曲 |

> ⭐ **一句话**：⚠️ 初代 ESP32 + PSRAM 的开发板买不到，而手上那块 **S3 有 PSRAM**
> ⇒ ⭐ **用 S3 换大水池**，代价是 PC 侧生态不如 SPP 方便。

---

## 二、⭐ GATT 属性表（🔴 已拉官方源码核对）

UUID **照抄 ESP-IDF 官方 `ble_spp_server` 示例**（⚠️ 在 esp-iot-solution 外部仓库里，⛔ 不在本仓库）：
⭐ 该示例的入口文件是 `app_main.c`，位于其仓库的 `ble_spp/spp_server` 示例目录下。

```c
#define BLE_SVC_SPP_UUID16      0xABF0     // ← ⭐ 服务（16 位）
#define BLE_SVC_SPP_CHR_UUID16  0xABF1     // ← ⭐ 特征（也是 16 位）
```

⚠️ **我在这里犯过一个认知错误，记下来免得后人再错**：
原以为"服务是 128 位 vendor UUID、0xABF1 挂在它下面"，
🔴 **实际官方的服务和特征都是【16 位】标准 UUID**。⭐ 16 位反而更好填。

本工程按语义拆成四个特征（官方示例只有一个）：

| UUID | 名称 | 权限 | 用途 |
|---|---|---|---|
| **`0xABF0`** | 服务 | — | — |
| **`0xABF1`** | `RECV` | WRITE_NR | ⭐ **对端把事件帧写这里** |
| **`0xABF2`** | `NOTI` | NOTIFY | ⭐ **我们 notify 回对端** |
| **`0xABF3`** | `CMD` | WRITE_NR | ⭐ **控制命令** —— 🔴🔴 **2026-09-30 更正**：⚠️ 原写"控制命令"却**无解析** ⇒ ⭐ **现已实现**：`0x01` = **清池** · `0x02` = **状态上报**（⚠️ **故意不做 start/stop**，⭐ 架构未定） |
| **`0xABF4`** | `STAT` | NOTIFY | ⭐ **状态上报** —— 🔴🔴 **2026-09-30 更正**：⚠️ 原**读回空**（属性用 `ESP_GATT_AUTO_RSP` 且 `length=0`）⇒ ⭐ **已改 `ESP_GATT_RSP_BY_APP`**，⭐ 实测返回 `pool=0/18204 sent=0 ovf=0\|ring=0 u_drop=0/0` |

> 🔴 **客户端必须写 `0xABF2` 的 CCCD = `0x0001`**，否则收不到任何通知。
> ⚠️ 典型症状：**连上了、写数据也成功，但一路收不到东西**。

---

## 三、⭐ 接线

```
PC/手机 ──BLE──> ESP32-S3 ──UART1 500kbps──> FPGA
                     UART2 ──> 串口屏（TJC T1 2.0"）
```

> 🔴🔴 **2026-09-30 更正**：⚠️ 上图原写 **`1Mbps`** ⇒ 🔴 **已作废**。
> ⭐ 现值 = **`500000`**（`esp32/ble/main/ble_config.h` `BLE_BAUD 500000`）；⭐ FPGA 侧 2026-09-24 降档。
> ⭐ **另**：⭐ **反向通路（FPGA→ESP32→BLE→PC）已打通**（⭐ 2000 字节 round-trip 逐字节一致，
> `esp32/evidence/反向通路验收-ESP32侧-20260930.md`）；⭐ 上行有 **`up_ring.c/.h`**（**160 KB PSRAM**，蓄水/放水）。

| 项 | 值 |
|---|---|
| 给 FPGA | **UART1：GPIO17 = TX / GPIO18 = RX**（⚠️ 交叉接 FPGA 的 `G22`/`G21`） |
| 串口屏 | **UART2：GPIO4 = TX / GPIO5 = RX** |
| 日志 | UART0（GPIO43/44） |

⚠️🔴 **引脚选择的两条硬约束（S3 特有）**：
1. **GPIO19/20 是 S3 的原生 USB（D-/D+）** ⇒ ⛔ 不要当普通串口用
2. 模组用**八线 PSRAM** 时 **GPIO35/36/37 被占用**，GPIO26~32 常与 flash/PSRAM 复用
   ⇒ ⭐ 改引脚前必须查**具体模组**的 datasheet

---

## 四、⚠️ 编译

```powershell
cd esp32\ble
. "C:\Espressif\tools\Microsoft.v5.5.PowerShell_profile.ps1"   # ⭐ 先激活 IDF

idf.py set-target esp32s3      # ⭐ 目标必须是 S3
idf.py build                   # 模式 A（默认）
idf.py -DBLE_MODE=1 build      # 模式 B（水池）
idf.py -DBLE_HMI_ENABLE=0 build # 不接屏
```

⭐ **实测（三种配置体积不同 = 开关真生效）**：

| 配置 | binary size |
|---|---|
| 模式 A + 屏 | `0xc0440` |
| 模式 B + 屏 | `0xc0ea0` |
| 模式 A + 屏关 | `0xbfc20` |

⚠️ **换开关时先删 `build/`** —— CMake 缓存会粘住上一次的 `-D` 值。

---

## 五、🔴🔴 三个"配置没设 ⇒ 报错像别的问题"的坑（⭐ 本目录全部踩过）

> ⭐ **这一节是本目录最有价值的部分** —— 三个坑的**报错信息都指向错误的方向**。

### 坑 A：`fatal error: esp_bt.h: No such file or directory`

🔴 **看起来像**：头文件路径问题 / include 写错
⭐ **实际是**：**`sdkconfig.defaults` 压根不存在** ⇒ `CONFIG_BT_ENABLED` 没开
⇒ **整个蓝牙组件没使能** ⇒ 它的头文件自然不在 include 路径里。

```
CONFIG_SOC_BT_SUPPORTED=y
# CONFIG_BT_ENABLED is not set        ← 🔴 真根因
```

⭐ **纪律**：报"某头文件找不到"时，**先查提供它的组件有没有被 CONFIG 打开**，
⛔ 不要一头扎进 include path。

### 坑 B：`unknown kconfig symbol 'BTDM_CTRL_MODE_BLE_ONLY'`

🔴 **看起来像**：拼写错误
⭐ **实际是**：🔴 **kconfig 符号名【随芯片完全不同】**
- 初代 ESP32：`BTDM_CTRL_MODE_BR_EDR_ONLY` / `BTDM_CTRL_BLE_MAX_CONN`
- ⭐ **ESP32-S3：`BT_CTRL_*` 前缀**

⭐ 因为 **S3 复用 ESP32-C3 的 Kconfig**：
```
components/bt/controller/esp32s3/Kconfig.in 里只有一行：
    source "$IDF_PATH/components/bt/controller/esp32c3/Kconfig.in"
```
⚠️ **写错的后果只是 warning**（不是 error）⇒ 🔴 **"以为设了、其实没设"**。
⭐ 而且 **S3 没有控制器模式 choice**（它只有 BLE，没得选）⇒ ⛔ 别照抄 SPP 版那套。

### 坑 C：`undefined reference to 'esp_ble_gap_start_advertising'`

🔴 **看起来像**：函数名写错 / 库没加
⭐ **实际是**：**`CONFIG_BT_BLE_42_FEATURES_SUPPORTED` 默认是关的**
⇒ 头文件里这些 API 被包在 `#if (BLE_42_FEATURE_SUPPORT == TRUE)` 里
⇒ 🔴 **声明还在（能编过），但实现被条件编译掉了（链接失败）**。

```
# CONFIG_BT_BLE_42_FEATURES_SUPPORTED is not set   ← 🔴 真根因
```

⭐ **纪律**：报 `undefined reference` 时，**先查该符号是不是被某个 CONFIG 挡住**。

---

## 六、⭐ 固件设计（与 SPP 版同构）

| 项 | 说明 |
|---|---|
| **9N 对齐** | 🔴 与 SPP 版【同一套】—— 写 UART 恒为 9 的整数倍 |
| **一帧 9 字节一次写入** | 同上 |
| **模式 A** | BLE 收到就转（对端限速） |
| **模式 B** | 缓存整曲（⭐ **走 PSRAM**）+ 自己按谱子时间放水 |
| **水池分配** | `heap_caps_malloc`：优先 PSRAM，退化内部 DRAM，失败则报错不 abort |
| **串口屏** | 与 SPP 版同一套（⭐ 6 项显示） |

⭐ **为什么 9N 对齐在这版【更关键】**：
BLE 数据是**按 ATT 包投递**的 ⇒ 一个 9 字节帧**可能被切成两个包**，
中间隔一个连接间隔（7.5~30 ms）⇒ 🔴 **远超 FPGA 的 160 µs 归位门限** ⇒ 必然截帧。
⇒ ⭐ 9N 对齐保证"写进 UART 的永远凑成完整帧"。

---

## 七、⚠️ 本目录的边界

| # | 约束 |
|---|---|
| **1** | 🔴 **⛔ 不碰 `esp32/bridge/`**（SPP 版）—— ⭐ 两者独立并存 |
| **2** | 🔴 **⛔ 不碰 `rtl/` `constr/` `tools/`** —— 另有人负责 |
| **3** | 🔴 **⛔ 不含任何可视化/音频的【生成】**（`K-81` 红线）；屏只**显示** |
| **4** | ⚠️ **未验证**：真实硬件上的 BLE 吞吐、MTU 协商结果、PSRAM 是否真被用上 |

---

## 附 · 关联文档

| 想看什么 | 去哪 |
|---|---|
| ⭐⭐ 总体架构（主文档） | `files/20-代码/ESP32通路总体架构-20260922.md` |
| ⭐ ESP32 侧交接 | `files/20-代码/ESP32通路交接文档-20260922.md` |
| ⭐ FPGA 侧对接清单 | `files/20-代码/FPGA侧对接清单-ESP32通路-20260922.md` |
| ⭐ SPP 版固件 | `esp32/bridge/README.md` |
| ⭐ 事件格式（冻结） | `files/20-代码/play_seq接口冻结契约.md` |
