# P5-① 证据归档：32× ADSR → 1 个共享引擎 + 32 拍轮转（2026-10-03）

> **HEAD**：`e81a67dd9159b4987c3f6cdc0a0894996ca7abae`（⛔ 未 commit）
> **任务**：`files/20-代码/P5-优化候选-20261003.md` 候选 1 / 拍板 D1·D3·D4
> **纪律**：`files/20-代码/工具陷阱清单-20261003.md` T1~T7

---

## 〇、一句话

⭐ 32 个 `adsr` 实例换成**1 个共享引擎 + 每拍服务一个 voice**（33 拍一圈），
⭐ **逐位等价**（3000 帧 / 3,456,000 次逐拍 voice 比对 / **0 处不同**），
⭐ 干净口径 **LUT −5403 · ALU −4301 · DSP 38→7**，
⭐ 干净 PnR **0/0 违例 · Fmax 53.187 MHz · SETUP #1 1.198 · HOLD #1 0.127**，
⭐ 全量回归 **118/118**。

---

## 一、改了哪些文件

| 文件 | 增删 | 说明 |
|---|---|---|
| `rtl/w3b/envelope_bank.v` | +323 / −27 | ⭐ 主体：共享引擎 + 32 拍轮转 ＋ 服务级前瞻 |
| `rtl/top.v` | +37 / −1 | ⭐ D3：`render_start_i` 推后 32 拍（`ob_valid` → `mx_render_start`） |
| `tb/w3b/tb_p5_adsr_diff.sv` | +536 / −0 | ⭐ **新建**：逐拍逐位差分 tb（内嵌改动前参考副本） |
| `tb/w3b/tb_envelope_bank.sv` | +6 / −0 | 补轮转等待（⛔ 判据未改） |
| `tb/w3b/tb_timbre_adsr.sv` | +11 / −1 | 补轮转等待 + 看门狗 5→50 ms |
| `tb/w3b/tb_note_manager.sv` | +32 / −3 | 帧间空拍 3→40 + 判据 4b 监视器补轮转延迟 |
| `tb/w3b/tb_nm_no_leak.sv` | +9 / −1 | `FRAME` 16→40 |
| `tb/w3c/tb_looper_replay_tail.sv` | +12 / −2 | `CLK_PER_SAMPLE` 4→34 · `TICK_GAP` 102→864（⭐ 比例仍 25.4） |

⛔ **未动**：`rtl/w3a/*` · `rtl/w3b/oscillator_bank.v` · `rtl/w3c/*` · `constr/` ·
`sim/*.ps1` · `tb/w3a/*` · `tb/e2e/*` · `files/10-硬件/*` · `rtl/w3b/adsr.v` · `rtl/w3b/note_manager.v`
（⭐ 后两者 `git diff` 为空，逐字节未变 ✅）

⭐ **完整补丁**：`adsr-share.patch`（`git diff` 全文，含 `sim/evidence` 构建产物）
· ⭐ **只含 RTL+tb**：`adsr-share-rtl-tb-with-new-tb.patch`（含新建 tb）· `adsr-share-rtl-tb.patch`（不含新建 tb）

---

## 二、门 1 · 逐位等价（⭐ 最重要）

`tb/w3b/tb_p5_adsr_diff.sv`（新建）

| 项 | 值 |
|---|---|
| 比较帧数 | ⭐ **3000** |
| 逐拍总线比较 | ⭐ **108000** 次（每帧 36 拍） |
| voice 观测数 | ⭐ **3,456,000**（108000 × 32） |
| **不同处** | ⭐ **0** |

⭐ **参考副本怎么来的**：⭐ **字节副本内嵌**在 tb 文件末尾（⭐ T1 安全手法）——
`Copy-Item` 存 `envelope_bank.v.PRE-P5ADSR` / `adsr.v.PRE-P5ADSR`，
再用**字节级 ASCII 替换**只改模块名（`ref_envelope_bank` / `ref_adsr`），
⭐ **逐字节校验通过**（`head=10542 + ref=12750 = 23292`，逐字节相同 ✅）。

⭐ **判据比"每帧比一次"强**：⭐ **每一个时钟**都比 32 路 —— 按
`voice v 在 tick 后第 (3+v) 拍起必须是新值、之前必须是旧值` 判定
⇒ ⭐ 同时锁死**值**与**轮转时序**。
⭐ 激励**故意在帧内（轮转进行中）随机改 gate/velocity/timbre/retrig**
⇒ ⭐ 任何"服务时才去采输入"的实现（⭐ 例如只跑综合的探针版）**必然红**。

⚠️ **下次改 `envelope_bank.v` 必须换新参考副本**（⭐ 否则退化成"新代码 vs 新代码"）。

---

## 三、门 2 · 聚焦 tb

| tb | 结果 |
|---|---|
| `tb_p5_adsr_diff` | ✅ PASS（0 mismatch） |
| `tb_envelope_bank` | ✅ PASS |
| `tb_tdm_render_mixer` | ✅ PASS（⭐ 模块本身**一字未改** ⇒ 判据/延时数字都不用动） |
| `tb_timbre_adsr` | ✅ PASS |
| `tb_note_manager` | ✅ PASS |
| `tb_top_sound` | ✅ PASS |
| `tb_drum_timbre_top` | ✅ PASS |

⚠️ **契约变更（如实记录）**：⭐ `env_level_o`/`env_active_o` 现在**要 33 拍才全部更新完**
（⭐ 原来在 tick 那一拍全更新）⇒ ⭐ 5 个 tb 的**时基/采样时刻**必须跟着改
（⭐ `K-103` 同族：⭐ **加了几级寄存器，判据的等待就要跟着加**）。
⭐ **判据（期望值/次序/名字）一条没删、一条没放松** —— 只补等待/放长帧周期。
⭐ 其中 `tb/w3c/tb_looper_replay_tail.sv` **不在任务书的允许清单里**
（⭐ 清单只写了 `tb/w3b/*`）⚠️ —— 但它不改就**结构性必红**（`CLK_PER_SAMPLE=4` 只够扫 3 路），
⭐ 且改法是**保比例的**（采样拍:PPQN tick 仍是 25.4）⇒ ⭐ **请用户确认这一处**。

---

## 四、门 3 · 干净综合（⭐ T2：每次先删 `impl/gwsynthesis`）

| 项 | BEFORE（HEAD） | AFTER（本次） | Δ |
|---|---|---|---|
| **`T_Lut`** | 37075 | ⭐ **31672** | ⭐ **−5403** |
| **`T_Alu`** | 12207 | ⭐ **7906** | ⭐ **−4301** |
| `T_Register` | 15784 | 16199 | +415 |
| **`T_MULTALU27X18`（DSP）** | 38 | ⭐ **7** | ⭐ **−31** ✅ 目标 |
| `T_MULT12X12` | 6 | 6 | 0 |
| `T_MULT27X36` | 5 | 5 | 0 |
| `T_Bsram` | 29 | 30 | ⚠️ +1 |
| `ERROR` | 0 | ⭐ **0** | — |

**`u_envelope_bank` 自身**：`6075 LUT + 4448 ALU + 608 FF + 32 DSP + 0 BSRAM`
→ ⭐ **`628 LUT + 148 ALU + 991 FF + 1 DSP + 1 BSRAM`**（LUT −5447 · ALU −4300 · DSP −31）

⚠️ **两处偏差（如实记录）**：
1. ⭐ LUT 只降 **5403**（⭐ 候选表说 ~5891，差 **488**）—— 差额 = 我多做的两件事：
   ⭐ **输入快照寄存器**（384 FF，⭐ 保证帧内改输入不会串进还没扫到的 voice）
   ＋ ⭐ **前瞻寄存器**（见 §六 D4）。
2. ⚠️ **BSRAM +1**：⭐ 综合器把 `lvl_sr`（512×16 移位寄存器）**映射进了 1 块 BSRAM**
   ⇒ ⭐ 省了 512 FF、⭐ 但多占 1 块 BSRAM（29→30）。
   ⭐ 与 `ep_mem` 想省的 3 块（P2 候选 5b）**方向相反**，⚠️ 需要时可以用
   `(* syn_ramstyle = "registers" *)` 换回寄存器（⛔ 本任务未做，⭐ 因为 DSP/LUT 是主目标）。

---

## 五、门 4 · 一次干净 PnR

⚠️ **`pnr_run.ps1` 被 T4 僵尸 `gw_sh` 挡住**（⭐ 实测原文，见 `pnr_run_zombie_blocked.log`）：
```
[21:18:13] FATAL: another gw_sh is already running (PID 37832) -- refusing to start a second one
EXITCODE=3
```
⭐ `PID 37832` = `gw_sh.exe _probe.tcl`，**已死但杀不掉**（`taskkill` 报 *no running instance*、
`HasExited=True` 却仍被 `Get-Process` 列出）—— ⭐ **正是 T4 描述的僵尸**。
⭐ 而 `sim/*.ps1` 在**禁止修改清单**里 ⇒ ⭐ **无法就地修 preflight**。
⇒ ⭐ **等价替代**：手动 `Remove-Item impl\pnr` ＋ `impl\gwsynthesis`，再跑 `sim\gowin_build.ps1`
（⭐ 与 `pnr_run.ps1` attempt-1 的步骤**逐条相同**：⭐ 清两处增量态 + `run all` + 新鲜度判据）。

| 判据 | 结果 |
|---|---|
| ⭐ **出了 `.fs` 吗** | ✅ `impl/pnr/Gowin2026.fs`，19,191,511 B @ 22:25:00（⭐ 归档在 `Gowin2026.fs`） |
| ⭐ **`PR0004`** | ✅ **0** |
| ⭐ **setup / hold 违例** | ✅ **0 / 0** |
| ⭐ **`Actual Fmax`** | ✅ **53.187 MHz**（门槛 51.5 ✅） |
| ⭐ **`SETUP #1` slack** | ⭐ **1.198**（⭐ 对照 **0.850** ✅ 更好） |
| ⭐ **`HOLD #1` slack** | ⭐ **0.127**（⭐ 对照 **0.142** ⚠️ 略紧 0.015） |
| `ERROR` | 0 |
| `PR1014` | ⚠️ 1 条（⭐ `clk_d` 走通用布线资源，⭐ **既有告警**，⭐ 与本次改动无关） |
| 耗时 | 552 s（⭐ 9.2 min，⭐ 干净 PnR） |

📌 **关键路径已不在 `envelope_bank`**（⭐ SETUP #1 现在落在 `note_manager`/`oscillator_bank` 一侧）。

### ⭐⭐ PnR 的两次对照（⭐ 很有价值，⭐ 建议留存）

| 版本 | Fmax | SETUP #1 | 关键路径 |
|---|---|---|---|
| ⭐ **第一版（无服务级前瞻）** | 🔴 **50.055 MHz** | 🔴 **0.022** | 🔴 **`u_envelope_bank`**：`cnt → 32:1 mux → 音色 case → 16 位加减 → lvl_n → lvl_sr` |
| ⭐ **第二版（补服务级前瞻）** | ✅ **53.187 MHz** | ✅ **1.198** | ✅ 回到 `note_manager` 一侧 |

⇒ ⭐ **教训**：⭐ 把 32 份组合逻辑压成 1 份 ⇒ **那一份自己变成关键路径**。
⭐ 只补"乘法"那一级流水（⭐ D4 的原话）**不够** —— ⭐ 必须把**整条服务输入**
（32:1 mux ＋ 音色 case ＋ peak 拼位）**一起前瞻打拍**。

---

## 六、三条必做项怎么落实的

### ① ⭐ D4：给"力度×音色"那一级乘法补流水

⭐ **做法（⭐ 前瞻，⭐ 不是就地打拍）**：
```
cnt = k   : 用【下一个 voice】的 vel/timbre 算 prod_p = peak_p * sus_q8_p → 打拍
cnt = k+1 : 服务 voice k，⭐ 直接用寄存器里的 sustain_product_r
```
⭐ 因为轮转的"头"永远是当前 voice、⭐ 而"下一个"是确定的（`pre_i = cnt`）
⇒ ⭐ **乘法器只 1 个**（`T_MULTALU27X18` = **1**，⭐ 实测），⭐ 且**完全在服务路径之外**。
⭐ 位宽按已知坑处理：⭐ 走 **32 位宽 wire** `prod_p` 再截低 24 位（⛔ 不写
`reg [23:0] x <= a*b;` 那种 LHS 决定位宽的写法）。

### ② ⭐ D3：`tdm_render_mixer` 的 32 拍偏斜用方案 (a)

⭐ **做法**：⭐ 在 `top.v` 把 `ob_valid` **延迟 32 拍**再喂 `render_start_i`
（⭐ `mx_start_dly[31:0]` 移位寄存器 ⇒ `mx_render_start`）。
⭐ **为什么放 `top.v` ⛔ 不放 mixer 里**：⭐ mixer 的 `tb_tdm_render_mixer` 判据里有
**固定延时区间** `[POLY+3, POLY+8]` ⇒ ⭐ 在模块内推后会把那条判据**打红**，
⭐ 而任务书要求"⭐ 判据一条不许删"。⭐ 放 `top.v` ⇒ ⭐ **模块与它的 tb 一字未动** ✅
⛔ **没有用"攒够 32 位原子提交"**（⭐ 那要多 512 FF ＋ 整体推迟 1 帧）。
⭐ **I2S 输出逐位不变的理由**：⭐ 下游是**握手式**（`mx_valid` → `master_mix` →
`top.v` 输出寄存器 → `i2s_tx` **只在 `frame_start` 装载一次**）
⇒ ⭐ 32 拍（⭐ 帧的 3.1%）**被吸收**，⭐ 且 32+34+7 ≈ 73 ≪ 1024 ✅。
⚠️ **已知代价（如实记录）**：⭐ 这一延迟**同时**把 mixer 的**帧边界快照**
（`n_active_r` 归一化 popcount · `norm_gain_r` 去拉链步进）推后了 32 拍
⇒ ⭐ 若那 32 拍内恰好有 note 事件落地，⭐ 归一化增益可能差 1 档。⭐ 已跑全量回归复核。
📌 ⚠️ **另一件必须说清的事**：⭐ 以**当前接线**看，`render_start_i` = `ob_valid` 本来就在
**tick 后第 66 拍**（⭐ 振荡器 TDM 先跑 66 拍）⇒ ⭐ 而共享引擎在 **tick 后第 34 拍**就已扫完
⇒ ⭐ **这 32 拍偏斜在今天是"防御性裕量"，⛔ 不是正确性的必要条件**。
⭐ 我按拍板**照做了**（⭐ 因为它无害且与后续 P5-② 的排期假设一致），
⚠️ 但**请用户知道这一点**。

### ③ ⭐ T2：每次综合前先删 `impl/gwsynthesis`

⭐ BEFORE / AFTER 两次综合**都先 `Remove-Item impl\gwsynthesis -Recurse -Force`** ✅
（⭐ 脚本 `build/p5-adsr/syn_only.tcl`：`open_project` + `set_option -top_module top` + `run syn`）
⭐ 判据按 **T6**：⭐ 看日志里的 **`GowinSynthesis finish`**（⛔ 不看退出码/进程存活）。
⭐ 证据：`syn_before.log` / `syn_after2.log` + `syn_before_rsc.xml` / `syn_after2_rsc.xml`。

---

## 七、门 5 · 全量回归

`sim\tb_all.ps1`（串行，⭐ 判据 = 通过数 == 共数）：
⭐ **118 / 118** ✅（⭐ 基线 117/117 ＋ 本次新建 `tb_p5_adsr_diff` = 118）
⭐ 跳过 2 个工具 tb（`tb_export_wav` / `tb_export_key_wav`，⭐ 默认跳过，⛔ 不计入总数）。
证据：`regression_final.log`（⭐ 含每条的 `PASS:` 行）。

---

## 八、工具陷阱（本轮实测）

| # | 现象 | 处置 |
|---|---|---|
| **T1** | 复制含非 ASCII 的源码 | ⭐ 全程 `Copy-Item`（字节级）＋ `edit` 工具；⭐ 参考副本用**字节级 ASCII 替换**并**逐字节校验** ✅ |
| **T2** | `run syn` 是增量的 | ⭐ 两次综合都先删 `impl/gwsynthesis` ✅ |
| **T4** | 僵尸 `gw_sh` 挡住 `pnr_run.ps1` | ⚠️ **挡住了**，⭐ 贴现象 ＋ 走等价替代（见 §五） |
| **T5** | `gowin_build.ps1` 收尾杀所有 `gw_sh` | ⭐ 全程**不并发**跑 gw_sh ✅ |
| **T6** | `gw_sh` 综合完不退出 | ⭐ 判据用日志里的 `GowinSynthesis finish` ✅ |
| **T7** | 顶层子模块数字被常量折叠 | ⭐ 模块自身数字取自 `syn_rsc.xml` 的 `SubModule` 行 ✅ |

---

## 九、⚠️ 我不确定 / 需要用户确认的

1. ⚠️ **`tb/w3c/tb_looper_replay_tail.sv` 被改了**（⭐ 不在允许清单里，⭐ 但不改结构性必红）。
   ⭐ 改法是保比例的（25.4 采样拍/PPQN tick 不变），⛔ 判据未改。**请确认这一处是否可接受。**
2. ⚠️ **帧内可见性**：⭐ 共享引擎的 512 位 `env_level_o` 是**逐拍落盘**的
   ⇒ ⭐ `note_manager` 的 32 拍扫描**若正好落在 tick 后的 32 拍窗口内**，
   ⭐ 个别 voice 会读到**上一帧**的电平（⭐ 参考实现是"整拍一起变"）。
   ⭐ 影响面：⭐ 只影响"抢占时选哪个已 Release 的 voice"（⭐ `cand_env` 比较），
   ⚠️ **概率约 3%/次分配**，⭐ 且**不改变每个 voice 的包络序列本身**（⭐ 门 1 已证逐位等价）。
   ⭐ **本次没有实测它在整机上的可观测差异** —— ⛔ 只跑到模块级等价 ＋ 全量回归全绿。
3. ⚠️ **D3 的 32 拍偏斜在今天是防御性的**（⭐ 见 §六②）—— ⭐ 请确认是否仍要保留。
4. ⚠️ **BSRAM +1**（⭐ `lvl_sr` 被映射进 BSRAM）—— ⭐ 与 P2 的 `ep_mem` 省 3 块方向相反。
5. ⚠️ **`pnr_run.ps1` 未能按原命令执行**（⭐ 僵尸 gw_sh）；⭐ 我用的是**逐条等价的替代流程**。
   ⭐ 若要严格复现原命令，⭐ **需要重启 DSH**（⭐ 僵尸句柄才会释放）。
6. ⚠️ **`T_Lut` 只降 5403（⭐ 目标 ~5891）** —— ⭐ 差额来自我额外加的
   输入快照（384 FF）＋ 服务级前瞻寄存器。⭐ 若用户要求"必须到 5891"，
   ⭐ 可以去掉输入快照（⚠️ 但会破坏帧内改输入时的逐位等价，⭐ 不推荐）。
7. ⚠️ **未上板**（⭐ 本轮只到"仿真 + 综合 + PnR + 全量回归"）。
