# P5-② `oscillator_bank` 增量算术上提 —— 实施方案（2026-10-04）

> ⭐ **本文是"照做即可"的实施书** —— 起因：⭐ 侦察子代理已把**逐位等价**的变体写出来并实测过
> （⭐ 全设计 **LUT −1069 / ALU −1188**，⭐ 隔离 **−1166 LUT / −2306 ALU = −21.8%**，
> ⭐ **320 帧 0 mismatch**）。⭐ 本次把那份变体**移植进生产文件**。
> **出处**：`files/20-代码/P5-优化候选-20261003.md` 候选 ② · **侦察产物**（⭐ 仍在盘上）：
> `build/p5-recon/verify_osc/oscillator_bank_ref.v`（⭐ 现版副本）·
> `build/p5-recon/verify_osc/oscillator_bank_pv.v`（⭐ 上提版）·
> `build/p5-recon/verify_osc/tb_p5_osc_equiv.v`（⭐ 等价 tb）

---

## 一、⭐ 一句话

**把"每个 lane 各算一遍"的增量/扫频算术，改成"每个 voice 只算一遍"**：
`OSC_PER_VOICE = 2` ⇒ ⭐ 同一 voice 的两个 lane **共用** `base_inc`、失谐偏移、鼓扫频比较器、
扫频计数器与增量加法 ⇒ ⭐ 那部分逻辑**减半**。
⛔ **64 个相位累加器（`phase_q`）必须原样保留**（⭐ 它们是评分主体，⭐ 一个都不能省）。

---

## 二、⭐⭐ 逻辑改动（⭐ 已从 `ref` vs `pv` 的**去注释 diff** 中逐条核对）

### 2.1 ⭐ 新增 `gen_voice`（`POLY_TARGET` = 32 份）

| 项 | 现版（每 lane 一份） | 上提版（每 voice 一份） |
|---|---|---|
| `bv` = 基频增量 | `base_inc = base_phase_inc_i[VOICE*W +: W]` | `bv = base_phase_inc_i[vg*W +: W]` |
| `dv` = 失谐偏移 | `detune_off = (DETUNE_ON && OSC_IDX!=0) ? base_inc>>DETUNE_SH : 0` | `dv = (DETUNE_ON!=0) ? bv>>DETUNE_SH : 0`（⭐ 与 `OSC_IDX` 无关） |
| 鼓判据 | `is_kick_drum = lane_drum[g] && (base_inc < KICK_MAX)` | `drum_v = voice_drum_i[vg]; is_kick = drum_v && (bv < KICK_MAX)`（⭐ `is_tom` 同理） |
| `sweep_load` | 每 lane 一份 | 每 voice 一份（⭐ 算式一字不改） |
| `sweep_q`（16 位） | ⭐ **每 lane 一个**（64 个） | ⭐ **每 voice 一个**（32 个） |
| `lane_active_d`（上升沿） | 每 lane 一个 | ⭐ `act_d` 每 voice 一个 |
| 增量加法 | `lane_inc_s = $signed(..)+$signed(..)+$signed(vib_off)`（33 位）<br>＋ `lane_inc_sweep = lane_inc_s[31:0] + sweep_off` | `inc_main = bv + vib_off[31:0] + so_v`（32 位）<br>＋ `inc_det = inc_main + dv` |

### 2.2 ⭐ 为什么"32 位无符号加法"与现版"33 位有符号加法"**逐位等价**

⭐ 两边都是 **mod 2³² 加法**（⭐ 加法在模意义下结合、交换 ⇒ 分组方式不影响结果）；
现版多出来的第 33 位只是**中间宽度**，⭐ 截到 32 位后与上提版**完全相同** ✅
📌 这正是侦察"320 帧 0 mismatch"能成立的原因（⛔ 不是"看起来一样"）。

### 2.3 ⭐ 每 lane 只剩三行

```verilog
wire [PHASE_W-1:0] phase_seed = ((DETUNE_ON != 0) && (OSC_IDX != 0)) ? PHASE_QUARTER : 0;
wire [PHASE_W-1:0] lane_inc = test_mode_i ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
                          : (OSC_IDX != 0) ? inc_det_w[VOICE*W +: W]
                                           : inc_main_w[VOICE*W +: W];
```
⚠️ **`sweep_q` 的装载/衰减搬进 `gen_voice` 后，条件必须逐项保持**（⭐ 已核对）：
```verilog
if (!test_mode_i && (rst_v || (act_v && !act_d))) sweep_q <= sweep_load;
else if (sweep_q != 0)                            sweep_q <= sweep_dec;
```
- ⭐ `act_v`（非 test 档）= `voice_active_i[vg]` ⇒ ⭐ 与现版 `lane_active` **同一根线**（⭐ 同 voice 两 lane 恒等）
- ⚠️ **test 档下 `sweep_q` 仍要衰减**（⭐ 现版就是这么做的）⇒ ⛔ 别把它关掉
- ⚠️ `phase_rst_lane` 用 `act_d_bus[VOICE_IDX]` 代替 `lane_active_d`（⭐ 等价，⭐ 同上）

### 2.4 ⭐ 新增/保留

- 新增：`localparam [PHASE_W-1:0] PHASE_QUARTER = {{(PHASE_W-2){1'b0}}, 2'b01} << (PHASE_W-2);`
  （⭐ 把原来写在 lane 里的 `phase_seed` 常量提出来共享）
- 保留：`phase_q` / `addr_q`（⭐ **每 lane 一份**，⭐ 64 个相位累加器 ✅）、
  `lane_addr` / `lane_phase` / `lane_timbre` / `lane_velocity` / `lane_drum` 端口与 TDM 轮转逻辑**一行不动**
- ⛔ **不删**任何既有注释：⭐ 把"为什么"搬到 `gen_voice` 头上（⭐ 本项目注释即规格）

---

## 三、⭐ 落地步骤（⛔ 一次只改一个变量）

1. ⭐ **备份**：`Copy-Item rtl\w3b\oscillator_bank.v build\mutation\osc\oscillator_bank.v.bak` ＋ 记 `sha256`
2. ⭐ **改 `rtl/w3b/oscillator_bank.v` 一个文件**（⭐ 只搬 §二 那些项，⭐ 端口/参数/TDM 一律不动）
3. ⭐ **等价 tb**：把侦察的 `oscillator_bank_ref.v` 复制成 `tb/models/oscillator_bank_ref.v`
   ＋ `tb_p5_osc_equiv.v` 复制成 `tb/w3b/tb_p5_osc_equiv.sv`
   ⚠️ **判据必须"能红"**：⭐ 先把 `ref` 与**未改的** `rtl` 对比（⭐ 应 0 mismatch），
   ⭐ 再故意改一处（如 `dv` 的移位量）⇒ ⭐ **必须变红**（⭐ 否则 tb 是恒真探针 = `C83`）
   📌 **本项目的教训**：`tb_p5_adsr_diff` 的参考副本**内嵌在 tb 里** ⇒ ⭐ 本 tb 也照此办，
   ⚠️ 但**将来改 `oscillator_bank` 时必须同步换新参考**（⭐ 否则静默恒真）
4. ⭐ **四道门**：① 综合门（`ERROR=0`，⭐ 看 `GowinSynthesis finish`）
   ② 聚焦 tb：`tb_p5_osc_equiv` ＋ **`tb_oscillator_bank`**（⭐ 它用 `dut.gen_lane[N].phase_q/addr_q`
   ⇒ ⭐ 这两个信号**本方案保留** ⇒ ✅ 不用改 tb）＋ `tb_voice`/`tb_test_mode_top`/`tb_perc_env_top`
   ③ **一次干净 PnR**（`sim\pnr_run.ps1 -MaxAttempts 1 -SkipRegression -MinFmax 51.5 -TimeoutSec 3600`）
   ⇒ 判据 = **出没出 `.fs`** ＋ **有无 `PR0004`** ＋ `0/0`
   ④ 全量回归 ⇒ **通过数 == 共数**
5. ⭐ **归档**：位流 ＋ 时序 ＋ 前后 `rsc.xml` ＋ **原始补丁**（`git diff`）
6. ⭐ **对照点（⭐ 必须一起看）**：

| 项 | 加指示层后（⭐ 本次基线） | 期望（P5-② 后） |
|---|---|---|
| `T_Lut` | **31763** | ⭐ **≈30700**（−1069） |
| `T_Alu` | **7929** | ⭐ **≈6740**（−1188） |
| `Fmax` | **52.039**（0/0） | ⭐ **≥51.5**（⚠️ 布局噪声 ±2~3 MHz ⇒ 必须真跑） |

⚠️ **风险**：⭐ 动的是**音频核心**。⭐ 唯一的安全网 = **逐位等价 tb**（⭐ 320 帧不够就加到 2000 帧，
⭐ 且**必须包含鼓 lane**：`is_kick`/`is_tom`/扫频衰减是这次搬动的重点）。

---

## 四、⚠️ 为什么值得做（⭐ 与 T3 的关系）

⭐ P5-② 是**纯代数重排**（⭐ 不改语义、不改接口、不新增状态机）⇒
⭐ 它换来的 **~1070 LUT** 正好是 T3 变调（⭐ 约 +1961 LUT 的组合逻辑）**装得下的关键余量**。
📌 顺序不变：⭐ **先 ① 指示层（已落地）→ 再 ② 本项 → 最后 ③ `T3_EN=1`**（⭐ 用户已裁定 A：
⭐ 不动判据、不动架构，先试现有数组版）。

---

## 五、⭐⭐ 落地结果（2026-10-04 · ⭐ 已实施并通过四道门）

> ⭐ **状态**：✅ **已落地**（`rtl/w3b/oscillator_bank.v` 一个文件）
> ⭐ **逐位等价**：`tb/w3b/tb_p5_osc_equiv.sv` ＋ `tb/models/oscillator_bank_ref.v`
> ⇒ ⭐ **320 帧 0 mismatch**（⭐ 比了**全部 64 个相位累加器** ＋ 整条样点总线 ＋ valid ＋ dbg）
> 📌 证据：`sim/evidence/p5-2-osc-20261004/README.md`

### 5.1 ⭐ 数字（⭐ 顶层 `T_*` 差值口径）

| 项 | 改前（`60a7481`） | **改后** | 增量 |
|---|---|---|---|
| `T_Lut` | 31763 | ⭐ **31039** | ⭐ **−724** |
| `T_Alu` | 7929 | ⭐ **6746** | ⭐ **−1183** |
| `T_Register`（FF） | 16402 | **15858** | **−544** |
| `DSP` / `BSRAM` | 7 / 30 | 7 / 30 | **0 / 0** |
| ⭐ **`Fmax`** | 52.039 | ⭐ **55.597 MHz** | ⭐ **+3.558 MHz** |
| ⭐ **`Logic Level`** | 10 | ⭐ **3** | 关键路径**大幅变短** |

⭐⭐ **比"省 LUT"更重要的发现**：⭐ 上提让最差路径（`note_manager` 分配扫描）的
**布局拥塞下降** ⇒ ⭐ `Fmax` **+6.8%** ⇒ ⭐ **把 ① 指示层吃掉的 −1.148 MHz 全部补回还有余** ✅
📌 累计：**53.187（ADSR 后）→ 52.039（＋指示层）→ 55.597（＋P5-②）**

### 5.2 ⚠️ 与 §三 预估的差异（⭐ 如实记录）

| 项 | §三 预估（⭐ 侦察在**旧基线**探针上测） | 本次实测 | 判读 |
|---|---|---|---|
| `T_Alu` | −1188 | ⭐ **−1183** | ✅ 几乎完全吻合 |
| `T_Lut` | −1069 | ⚠️ **−724** | ⚠️ 少省 ~345 ⇒ ⭐ 基线不同（ADSR 后 `note_manager` 已变）＋ ⭐ Gowin 跨模块全局优化（⭐ `T7` 同族）⇒ ⭐ **以顶层实测为准** ✅ |

### 5.3 ⭐ 四道门

① 综合门 `ERROR=0` ✅ · ② 聚焦 tb **8 次 `-Filter` 全绿** ✅
③ 一次干净 PnR **11 min 出 `.fs`（无 `PR0004`，`0/0`，`Fmax 55.597`）** ✅
④ 全量回归 **通过 121 / 共 121** ✅

### 5.4 ⚠️ 一条流程教训（⭐ 写进记录）

🔴 **变异实验前必须备份【改动后】的版本** —— 本次把"改动前"的备份拷回去，
⚠️ **P5-② 的改动被整段抹掉**（当时还没提交）⇒ ⭐ 8 处编辑重做。
✅ **正确做法**：⭐ 改完先存 `*.AFTER`，⭐ 变异后用 `*.AFTER` 还原 ＋ ⭐ **tb 复跑 0 mismatch** 反证 ✅
