# 下一轮降 CLS —— 任务规格与靶子（2026-10-04）

## 为什么继续降 CLS

本工程已用**实测**证明：**降 CLS 是提升时序余量的唯一有效方向**（codex 评审判断 + 我 6 次实验验证）。
关键经验：**降幅要够大** —— 小改（CLS −110~−683）会被布局抖动吃掉；
阶段 2 的 Logic −4397 / CLS −1161 / Register −552 才压过抖动（Fmax 52.219 → 53.652），
再把余量预算收紧到 18.181 ns 后进一步到 **56.399 MHz**。

## 当前基线（正式版 `TEST_MODE_EN=0`，**已上板验证** ✅）

| 项 | 值 |
|---|---|
| `clk_sys` | **56.399 MHz** / setup 0 / hold 0 |
| 55 MHz 预算 slack | +0.450 ns |
| Logic / Register / **CLS** | 46283 / 15148 / **25725（86%）** |

## 综合层级资源（最大块）

| 模块 | Register | ALU | LUT | 备注 |
|---|---|---|---|---|
| `g_sound.u_note_manager` | 3281 | 885 | **11208** | ⭐ 最大头 |
| `g_sound.u_envelope_bank` | 608 | **4960** | 5401 | 32×ADSR（每声部 ~139 ALU） |
| `g_sound.u_oscillator_bank` | 4778 | 5318 | 5376 | 阶段 2 已共享扫频 |

## 当前最差路径（正式版报告）

1. `u_note_manager/gate_r_24_s0/Q → u_note_manager/scan_cnt_3_s0/CE`（+0.450）
2. `u_note_manager/retrig_low_26_s1/Q → u_note_manager/best_idx_0_s0/CE`（+0.461）
3. （诊断版另有）`u_tdm_render_mixer/cnt_4_s0/Q → prod_c_0_s/D[12]`（+0.065）

⇒ 三个候选靶子：**`note_manager` 的 LUT 与抢声部锥**、**`envelope_bank` 的 ALU**、
**mixer 的 `cnt → prod_c` 操作数路径**（= codex 评审里的"阶段 3"）。

## 已准备的实施任务

`codex-task-spec.json`（本目录）是**完整的实施任务规格**，已按 DSH→Codex 调度规则
（difficulty = hard）写好，内容包括：必读材料、当前状态、三个靶子的具体落点、
硬约束（⛔ 不改 SDC/CST/门槛/声部数、不删断言、不动 TEST_MODE_EN 机制）、
等价性验证要求（差分 + 红检）、综合资源验收要求、交付物清单。

⚠️ **派发受阻**：本机 xats dispatcher 在 2026-10-04 15:20 前后死亡，重启后未接单
（`dispatcher = 0/2` 反复、任务目录未生成）。⇒ 需要先修复 xats 基础设施，
或由 DSH 侧**直接按本规格实施**。

## 建议的实施顺序

1. **`note_manager` 的 LUT 11208**：先做只读分析找出重复的 per-voice 数组/比较/mux 树，
   给出量化目标；⚠️ 同时注意它正是当前最差路径所在模块。
2. **`envelope_bank` 的 ALU 4960**：codex 上轮给过"139 ALU/声部 → ≤80"的目标；
   当时只做了 decay/release 共减法器且**因 CLS 反增而回退**（存档
   `evidence/h5/cand3-adsr-share-50p035/adsr-shared.v`），**必须重新评估**（上次只降 Logic 没降 CLS）。
3. **mixer 操作数流水**（codex 阶段 3）：切断 `cnt → prod_c`；
   ⚠️ 注意 `tb_tdm_render_mixer.sv:246` 的 `[POLY+3, POLY+8]` 延迟契约。

⛔ 每一步都必须：先等价验证（含红检）→ 再综合筛资源 → 才花 PnR 预算。