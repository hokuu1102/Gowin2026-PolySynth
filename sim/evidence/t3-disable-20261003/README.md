# `P1` · T3 变调参数开关 `T3_EN`（默认 0 = 关）—— 证据归档（2026-10-03）

> **任务**：给 `rtl/w3b/note_manager.v` 加 `parameter T3_EN = 0`，用 `generate if (T3_EN)`
> 把**整个变调核心**包起来 ⇒ `T3_EN=0` 时**不参与综合**、输出回到 **T2 原式** ⇒ 主线恢复可交付。
> **只改两个文件**：`rtl/w3b/note_manager.v`（+91/−20）· `tb/w3b/tb_transpose.sv`（+207/−30）。⛔ 未 commit。

---

## 一、⭐ 三个数字（`T3_EN=0` ⇒ 与无 T3 基线**逐字相同**）

| 项 | **`T3_EN=0`（本任务）** | 无 T3 基线（`no-t3-control-20261003`） | 差 |
|---|---|---|---|
| **`T_Lut`** | ⭐ **37026** | 37026 | **0** ✅ |
| **`T_Register`** | ⭐ **15698** | 15698 | **0** ✅ |
| **`T_MULT27X36`** | ⭐ **5** | 5 | **0** ✅ |
| `g_sound.u_note_manager` | 3281 FF / 10912 LUT | 3281 FF / 10912 LUT | **0** ✅ |

`ERROR=0`（只有既有的 WARN）。归档：`rsc-T3EN0.xml` · `syn-T3EN0.log`

### ⭐⭐ 能红证据（`T3_EN=1`，同一条 RTL 只把默认值改成 1）

| 项 | `T3_EN=1` | T3-HEAD（`t3-only-20261003`） | 差 |
|---|---|---|---|
| **`T_Lut`** | ⭐ **38987** | 38987 | **0** ✅ |
| **`T_Register`** | ⭐ **16749** | 16749 | **0** ✅ |
| **`T_MULT27X36`** | ⭐ **6** | 6 | **0** ✅ |
| `g_sound.u_note_manager` | 4331 FF / 12730 LUT / 1 DSP | — | — |

⇒ ⭐ **开关确实在起作用**：`37026 ↔ 38987`（Δ = **+1961 LUT** / **+1051 FF** / **+1 DSP**）。
归档：`rsc-T3EN1.xml` · `syn-T3EN1.log`

---

## 二、⭐ 聚焦 tb（全 PASS）

| tb | 结果 | 日志 |
|---|---|---|
| `tb_transpose` | ✅ **PASS**（T1/T2/T3/T4/T6/**T7** 全 ok） | `tb_transpose-T3EN0.log` |
| `tb_note_manager` | ✅ **PASS**（`note_manager acceptance (T54) - all judgements held`） | `tb_note_manager-T3EN0.log` |

### ⭐⭐ `tb_transpose` 的 `T3_EN` 双实例口径（⭐ 探针换了，判据**一条没删**）

| 实例 | `T3_EN` | 变调口 | 角色 |
|---|---|---|---|
| `u_dut` | **0** | 接 `semi` | ⭐ **交付配置** —— `T7` 钉住"全程 == T2 基线" |
| `u_nc` | **0** | **悬空** | ⭐ = `top.v` 现状（`T1` 第三条） |
| `u_t3on` | **1** | 接 `semi` | ⭐ **T2/T3/T4/T6 的探针源**（变调核心打开版） |
| `u_ref` | — | — | `note_manager_ref` = **`d36cb64^`（T2 基线）逐字副本** ⇒ `T1`/`T7` 的差分基准 |

🔴 **为什么⛔ 不用 `ifdef` 把 T2/T3/T4/T6 编译掉**：`T3_EN=0` 时 `semi_cur`/`phase_tr`
**根本不存在** ⇒ 编译掉就是 **`C83`"探针假绿"**（⭐ 通过 ≠ 真的验过）。
⇒ ⭐ 正确做法 = **换实例取探针**（`u_t3on.g_t3.semi_cur` / `u_t3on.g_t3.phase_tr`）。

⭐ **`T7`（本轮新增）的实测数**：全程比较 **1815193 拍** ——
`T3_EN=0` 实例与 T2 基线 **0 处不同**；`T3_EN=1` 实例 **出现过**不同（`semi!=0` 之后）⇒ **非空洞** ✅

---

## 三、⭐ 一次干净 PnR（`-MaxAttempts 1 -SkipRegression -MinFmax 51.5 -TimeoutSec 3600`）

| 项 | 本任务 | 无 T3 基线 | 判据 |
|---|---|---|---|
| 耗时 | **14.3 min** | — | — |
| **`.fs`** | ⭐ **出了**（19 190 855 B） | — | ✅ |
| **`PR0004` / `unrouted`** | ⭐ **0 处** | — | ✅ |
| Setup / Hold 违规 | **0 / 0** | 0 / 0 | ✅ |
| **`Actual Fmax`** | ⭐ **53.425 MHz** | 53.425 | ✅ 逐字相同 |
| **SETUP #1 slack** | ⭐ **1.282 ns** | 1.282 | ✅ 逐字相同 |
| **HOLD #1 slack** | ⭐ **0.128 ns** | 0.128 | ✅ 逐字相同 |
| 位流 sha256 | `7234F11CD595BD8B1F78F59FD3F52465A5D59B7FF566860506685556523E73DB` | — | — |

归档：`Gowin2026-T3EN0.fs` · `gowin_m0_timing-T3EN0.txt` · `Gowin2026-T3EN0_tr_content.html` ·
`gowin_build-T3EN0.log` · `pnr_run_attempt1-T3EN0.log` · `gowin_m0_rsc-T3EN0.xml` · `gowin_m0_pins-T3EN0.txt`

> ⚠️ 唯一 WARN：`PR1014`（`clk_d` 用通用布线资源）—— ⭐ **改动前就有**，与本任务无关。

---

## 四、⚠️ 遗留 / 不在本轮范围

1. 🔴 **`sim/tb_all.ps1` 的每 tb 超时预算需要加 `tb_transpose`** ——
   ⭐ 实测：**HEAD 版 `tb_transpose` 已经是 134.6 s > 默认 120 s**（本任务前就超）；
   本任务加了 `T7` 的两条全程 1024 位差分 ⇒ **159 s**（优化前 178 s）。
   ⇒ ⭐ **修法**：把 `'tb_transpose'` 加进 `sim\tb_all.ps1` 的 **`$heavyTb`**（300 s 档），
   或全量回归用 `-TimeoutSec 300`。
   ⛔ **本轮未改** —— `sim/*` 在本任务的硬边界之外。
2. ⚠️ `T3_EN=0` 时端口 `transpose_semi_i` **无人引用** ⇒ 综合器可能给 unused 警告（⭐ 可接受）。
3. ⚠️ `T3_EN=1` **仍然布不通**（`T_Lut 38987` / `PR0004 659`）—— ⭐ 本任务**不修减重**，
   ⭐ 只是"把 T3 关起来"。⭐ 重新打开的前置条件见 `T3-后续计划-20261003.md` §三 `P4`。

---

## 五、备份（⭐ 改动前原样）

| 文件 | sha256 |
|---|---|
| `note_manager.v.HEAD-4F14BD83.bak` | `4F14BD839FEED50640A57A7E8FF18F7BFBC856276E643932867F6FB6E48C038A` |
| `tb_transpose.sv.HEAD.bak` | `9FD6534D410CB82AAC7C903DCE75A7EF1B669E02CE8FA2B1560A405D1BD6DC89` |

⭐ `note_manager.v.T3EN0` = 交付态的逐字节快照（sha256 `485D4B3A…BC4CA8`）——
⭐ 用于"`T3_EN=1` 能红实验后改回 0"的**逐字节核对**（⭐ 已核对：**相同** ✅）。
