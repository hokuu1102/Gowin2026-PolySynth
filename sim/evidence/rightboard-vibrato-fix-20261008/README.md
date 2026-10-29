# 右手板时序阻塞 —— 根因定位与修法（2026-10-08）

> 任务来源：第四周计划 **P0**（右手板 `RIGHT_ADC_ENABLE=1` 时序不达标 ⇒ 推子无法验证）
> 输入证据：`evidence/h5/rightboard-adc1-46p613/`（队友归档的 =1 档 PnR 报告 + timing HTML）
> 对照：`impl/pnr/`（当前交付树 =0 档，55.060 MHz / 0-0）

---

## 一、结论（一句话）

⭐ **1630 条 setup 违例、25 条最差路径 100% 是同一条**：
`u_vibrato_lfo/phase_q_17_s0/Q` → `u_oscillator_bank/gen_lane[*].phase_q_*_s0/D`
—— **颤音 LFO 输出经"48 位常量乘法 + 移位 + 32 位加法"后扇出到 64 个 lane 的相位累加器**，
一条纯组合链 **21.4 ns**（约束 18.181 ns）⇒ 在 =1 档被挤爆。

---

## 二、实测数据（两个配置对照）

| 项 | **=0 档**（当前交付） | **=1 档**（右手板联调） |
|---|---|---|
| `clk_sys` Setup TNS | **0.000** | 🔴 **−2718.329 ns** |
| Setup 违例端点 | **0** | 🔴 **1630** |
| Hold | 0 | 0 ✅ |
| `serial_clk` / `pixel_clk` | 0 / 0 ✅ | 0 / 0 ✅ |
| 最差路径 | `u_tdm_render_mixer/cnt_4_s0` → `prod_c_0_s`，**+0.527 ns** | 🔴 **`u_vibrato_lfo/phase_q_17_s0` → `gen_lane[*].phase_q_*`，−3.272 ns** |
| 该路径数据延迟 | —（不在 Top-12 里） | 🔴 **21.4 ns**（约束 18.181） |
| `clk_sys` | 55.060 MHz | 🔴 **46.613 MHz**（低于物理 50） |
| Logic / Register / CLS | — | 36068 / 17085 / **24128（81%）** |

⭐ **25 条最差路径的"源"聚类：`u_vibrato_lfo/phase_q_17_s0` = 25/25**（"宿"遍布 `gen_lane[7..63]`）
⇒ ⭐ **不是"几条长路径"，是一条高扇出链把 1630 个端点一起拖下水** ✅

---

## 三、病因（代码层）

`rtl/w3b/oscillator_bank.v`（修改前）：

```verilog
wire signed [15:0]  vib_s   = vibrato_mod_i;
wire signed [47:0]  vib_mul = vib_s * VIB_REF_INC;   // ⭐ 48 位常量乘法（VIB_REF_INC=38_700_000）
wire signed [PHASE_W-1:0] vib_off = vib_mul >>> 15;  // ⭐ 纯组合
...
assign inc_main_w[vg*PHASE_W +: PHASE_W] = bv + vib_off[PHASE_W-1:0] + so_v;  // 32 位加法
assign inc_det_w [vg*PHASE_W +: PHASE_W] = inc_main_w[...] + dv;
```

⇒ 一整条组合链：**LFO 内部逻辑 → 48 位乘法 → 移位 → 32 位加法 → 扇出 64 lane → 相位累加器**
⭐ `=0` 档时布局运气好（它不在 Top-12），`=1` 档加入第 3 片 ADC 后布局变化 ⇒ 这条链被拉长到 21.4 ns 🔴

---

## 四、修法（已实施）

⭐ **在颤音链上切两级流水**（`rtl/w3b/oscillator_bank.v`）：

```verilog
reg  signed [15:0]  vibrato_mod_r;     // ① 把 LFO 内部逻辑与乘法分开
reg  signed [47:0]  vib_mul_r;         // ② 把乘法与后面的加法链分开
always @(posedge clk_i) begin
    if (!rst_n_i) begin vibrato_mod_r <= 16'sd0; vib_mul_r <= 48'sd0; end
    else begin
        vibrato_mod_r <= vibrato_mod_i;
        vib_mul_r     <= vibrato_mod_r * VIB_REF_INC;
    end
end
wire signed [PHASE_W-1:0] vib_off = vib_mul_r >>> 15;
```

| 项 | 值 |
|---|---|
| 代价（FF） | **16 + 48 = 64 个 FF** · ⛔ 几乎不加 LUT |
| 代价（延迟） | 颤音 **2 拍 = 40 ns** ⇒ ⭐ 听感不可闻（颤音是 ~5 Hz 慢调制） |
| 改动文件 | `rtl/w3b/oscillator_bank.v` ＋ ⭐ **同步** `tb/models/oscillator_bank_ref.v` |

### ⚠️ 为什么必须同步改参考副本

`tb/models/oscillator_bank_ref.v` 是 **P5-② 上提之前的基线副本**，
`tb_p5_osc_equiv` 逐位比对"上提后的 RTL vs 该副本"。
⭐ 若只给 RTL 加流水 ⇒ 两侧差 2 拍 ⇒ 🔴 **判据会红（但那是假红）**。
⇒ ⭐ 给副本加**同一条流水**后，判据仍然只验 **P5-② 的等价性**
（⛔ 不验"颤音流水是否存在"）—— ⭐ 这跟"改实现要同步改契约 tb"是同一条纪律 ✅

---

## 五、验证（=0 档，已完成）

| tb | 结果 |
|---|---|
| `tb_p5_osc_equiv`（逐位等价） | ✅ **PASS**（流水同步后仍逐位相同） |
| `tb_oscillator_bank`（验收 T55） | ✅ PASS |
| `tb_drum_pitch_env`（鼓音高包络） | ✅ PASS |
| `tb_transpose`（T3 变调 T1/T2/T3/T4/T6/T7） | ✅ PASS |
| `tb_top_m0` / `tb_top_sound` / `tb_metronome` | ✅ PASS |
| `tb_note_manager`（含 vel_ramp / write_share / T5 踏板） | ✅ **4/4** PASS |

---

## 六、待测（=1 档）

⭐ 用**探针副本**（`build/rightadc-probe/`，只改 `RIGHT_ADC_ENABLE=1`，⛔ 不碰交付树）
跑一次完整 PnR，判据：

| # | 判据 | 期望 |
|---|---|---|
| 1 | `u_vibrato_lfo → gen_lane[*]` 是否还在最差路径里 | ⭐ 应消失或大幅后退 |
| 2 | Setup 违例端点数 | 1630 → 大幅下降 |
| 3 | `clk_sys` | 46.613 → ⭐ 目标 **≥ 51.5**（门槛） |
| 4 | 新的最差路径是谁 | 预计变成 `tdm_render_mixer`（=0 档那条，+0.527 ns）⇒ ⚠️ 若它也撑不住，需要第二处修法 |

⚠️ **若第 3 条不达标**：说明除颤音链外还有别的瓶颈 ⇒ 下一步看新的 Top-N 路径再定（⭐ 先定位再动手）。

---

## 七、⭐ 实测结果（=1 档探针，2026-10-08 23:07）

| 项 | 修前 | ⭐ **修后** |
|---|---|---|
| `clk_sys` Setup **TNS** | 🔴 −2718.329 ns | ✅ **0.000** |
| Setup **违例端点** | 🔴 **1630** | ✅ **0** |
| Hold 违例 | 0 | ✅ 0 |
| 最差路径 | 🔴 `u_vibrato_lfo/phase_q_17 → gen_lane[*].phase_q_*`，**−3.272 ns** | ⭐ `u_note_manager/g_t3.rot_cnt_0_s0 → g_t3.phase_tr[31]_24_s0`，**+0.051 ns** |
| 推算 `clk_sys` | 46.613 MHz | ⭐ **≈ 55.16 MHz**（18.181 − 0.051 = 18.130 ns） |
| 位流 | — | ✅ 出了（18,853 KB） |
| 资源 | Logic 36068 / Register 17085 / CLS 24128（81%） | `T_Lut 27830` · `T_Register 17138` · `T_Alu 8031` · `DSP 10` · `CLS 81%` |

⭐⭐ **结论：颤音链那两级流水把 1630 条违例一次清成 0，右手板档（`RIGHT_ADC_ENABLE=1`）现在过 51.5 门槛** ✅
⇒ ⭐ **右手板的推子/摇杆/音量可以验证了** ✅

### ⚠️ 两个必须记住的点

1. **新最差路径只剩 +0.051 ns**（`g_t3.rot_cnt → g_t3.phase_tr[31]`，⭐ T3 影子数组的**写侧**）
   ⇒ ⚠️ **余量极薄**：任何再往这条路上加逻辑的改动都可能把它打红。
   ⭐ 这也正是下面 A3 被回退的原因之一 ✅
2. `T_MULTALU27X18` 从 7 → **10**（=1 档多 3 个 DSP）· `CLS 81%`（=0 档 78%）
   ⇒ ⚠️ =1 档离布线拥挤更近（=0 档 `CLS 78%` 布通、=1 档 81% 也布通 ✅）

### 7.1 ⭐ =0 交付档的四道门（本批改动后，2026-10-08 23:23）

| 门 | 结果 |
|---|---|
| ① 综合 | ✅ `ERROR=0` |
| ② 聚焦 tb | ✅ 全绿（`tb_p5_osc_equiv` 逐位等价 · `tb_oscillator_bank` · `tb_drum_pitch_env` · `tb_transpose` · `tb_top_m0` · `tb_top_sound` · `tb_metronome` · `tb_note_manager` 4/4） |
| ③ 干净 PnR | ✅ **9.2 min** · `.fs` 出了 · **无 `PR0004`** · **0 setup / 0 hold** · ⭐ **`Fmax 55.06 MHz`** |
| ④ 全量回归 | ✅ ⭐ **通过 128 / 共 128**（⭐ 0 FAIL） |

⭐ **关键对照**：改动前 =0 档也是 **55.06 MHz** ⇒ ⭐ **颤音那两级流水【没有吃掉 =0 档的时序】** ✅
（⭐ 它在 =1 档把 1630 条违例清零、在 =0 档分文不取 ✅）
⭐ 位流：`Gowin2026-vibrato-fix.fs` · sha256 `9C07C45D79018641313159BF62C792FECCA9786931C1BF0A549F617F5D48D39E`

### 7.2 ⭐⭐ `=1` 档重测（含 `A3`，2026-10-09 01:55）

> ⭐ 目的：⭐ 本批后来又落了 `A3`（⭐ 动了 `oscillator_bank`）⇒ ⚠️ 必须确认它**没伤到右手板档**

| 项 | 修前 | ＋颤音流水 | ⭐ **＋`A3`（最新）** |
|---|---|---|---|
| `clk_sys` Setup **TNS** | 🔴 −2718.329 | ✅ 0.000 | ✅ **0.000** |
| Setup **违例端点** | 🔴 **1630** | ✅ 0 | ✅ **0** |
| Hold | 0 | 0 | ✅ 0 |
| 最差路径 slack | 🔴 **−3.272**（`vibrato_lfo → gen_lane`） | ⚠️ **+0.051**（`g_t3.rot_cnt → phase_tr[31]`，**很薄**） | ⭐ **+0.642**（换成 `tdm_render_mixer/cnt_4 → prod_c_0`）✅ |
| 推算 `clk_sys` | 46.613 MHz | ≈55.16 MHz | ⭐ **≈57.0 MHz** |
| 资源 | Logic 36068 / CLS 81% | `T_Lut 27830` / CLS 81% | ⭐ **`T_Lut 27589`** · `T_Register 17202` · `T_Alu 7999` · `DSP 10` · CLS **81%** |

⭐⭐ **结论：`A3` 不但没伤 `=1` 档，还把它那条 +0.051 ns 的薄余量抬到 +0.642** ✅
（⭐ 与 `A3` 的资源下降（⭐ −131 LUT）方向一致 ✅）

⭐ **位流（⭐ 上板请用这一版）**：`Gowin2026-rightadc-a3.fs`
· sha256 `2FB981EEF73DE4E02D404A81B508EE3E4D2F45D6060B18368A0FAAF8A0E61D2B`
⚠️ 它比 `…-rightadc-fixed.fs` 新（⭐ 含 `A3`），⭐ 余量也**更宽** ✅
⭐ **探针**：`build/rightadc-probe/`（⭐ 取自 `2686111` 的树 ＋ `RIGHT_ADC_ENABLE=1`）✅


---

## 八、`A3`（T3 鼓扫频窗口）—— ⭐ **第一版尝试（已回退）· 最终版见 §十一**

> ✅ **最终版已落地**（⭐ 参数门控 `DRUM_CLS_EXT`）：
> 📌 `sim/evidence/a3-proper-20261008/README.md` ✅
> ⭐ 本节保留的是**第一版（`rot_cnt` 跳转）**的失败记录 —— ⭐ 它的教训（⭐ 提交突发会把轮转钉停）仍然有效 ✅

**想法**：⭐ `phase_tr` 是轮转刷新的（32 拍一圈）⇒ 提交时把 `rot_cnt` **跳到** `cmt_idx_r`，
窗口 **≤32 拍 → ≤1 拍**（⭐ 鼓扫频取错概率 3.1% → ~0.1%），代价只有一个 5 位 mux ✅

**实测结果**：🔴 **`tb_transpose` 红 3 条**
- `T3: within 34 clocks of the first non-zero semi_cur, ALL 32 lanes updated` ❌
- `T2: 5 semitone settings × 32 lanes match the ratio table` ❌
- `T6: src=0/1/2 voices DO follow the transposition` ❌

**根因**：⭐ 提交是**突发**的（一个采集帧内最多 18 个事件）⇒ `rot_cnt` 被**连续钉在**提交索引上
⇒ 🔴 **轮转停摆** ⇒ "34 拍内 32 个 lane 全刷新"**不成立** ✅

**已回退**（`note_manager.v` 与 T5 版**逐字节相同**，`tb_transpose` 复绿 ✅）

**正确的修法（待做，⛔ 不是现在）**——二选一：
1. ⭐ **给提交路径加第二个乘法器**（⭐ DSP 余量 81% 够）⇒ 提交那一拍当场算 `phase_tr[cmt_idx]` ⇒ **零窗口** ✅
   ⚠️ 但组合乘法器正是本次长路径的病根 ⇒ 必须**带流水**用，⛔ 不能纯组合 ✅
2. ⭐ **给 `oscillator_bank` 一路"未变调的原始相位"**（`phase_raw_o`）⇒ 鼓的**音高档分类**
   改读它 ⇒ ⭐ 提交当拍就可用（**零窗口、⛔ 不加乘法器**）✅
   ⚠️ 代价：⭐ 变调开启时鼓的分类会与现在不同（⭐ 但那本来就是**更对**的语义：
   鼓种应由**按的哪个键**决定，⛔ 不该被变调带走）⇒ 要改 `tb_drum_pitch_env` 的契约 ✅

---

## 九、⭐ 补的缺口：`=1` 档**功能判据**（`tb/top/tb_right_adc.sv`，2026-10-08 新增）

🔴 **缺口**：⭐ 现有 tb 例化 `top` 时**全部用默认参数**（`RIGHT_ADC_ENABLE=0`）
⇒ ⭐ **第 3 片 ADC 的整条通路（扫描 / 通道映射 / 标定）在仿真里从未验过** ——
`=1` 档在此之前**只有"布不通"这一个事实**，⛔ 没有任何"它是活的"的证据 ✅

⭐ **新判据（双实例差分，⛔ 不是空判据）**：一个 `top` 用 `=1`、另一个用 `=0`，同拍跑同一窗口

| # | 判据 | 实测 |
|---|---|---|
| R1 | `=1` 档：⭐ **片 2 必须被扫描**（`spi_cs_n[2]` 翻） | ✅ `cs2 = 40` |
| R2 | ⭐ **反向对照**：`=0` 档片 2 **必须不翻** | ✅ `cs2 = 0` |
| R3 | 两档的片 0 都照常扫描（左手板不受影响） | ✅ `cs0 = 40 / 40` |
| R4 | SPI 时钟在跑 | ✅ `sclk = 960` |
| R5 | 心跳在翻（设计活着） | ✅ `hb = 600` |
| R6 | 未用片选（`cs_n[5:3]`）恒高（⛔ 不误选不存在的片） | ✅ |

**结果**：⭐ **7/7 PASS**（实测 85 s ⇒ ⭐ 已在 `sim/tb_all.ps1` 里给它 **300 s** 预算，
⛔ 免得机器忙时误报 TIMEOUT —— `K-94`/`K-161` 同族）✅

📌 **它回答什么、不回答什么**：
- ✅ 回答：⭐ "第 3 片的扫描通路是**活的**"（`ADC_N` 2→3 真的生效）✅
- ⛔ 不回答：⭐ "右手板的推子/摇杆/音量的**通道映射对不对**" ——
  那需要**上板**（⭐ 或一个带 3 片夹具的"按键→出声"tb，做法见 `tb_e2e_key_to_sound`）✅

---

## 十一、⭐ `A3` 正确修法（⚠️ **试过两版，2026-10-08 已回退**）

> ⚠️ **结论**：⭐ 窗口能清零、判据能红 ✅，但**两版实现的资源代价都是 +2000 LUT 量级** 🔴
> ⇒ ⭐ 与"保护 `=1` 档（右手板）布线余量"冲突 ⇒ ⭐ **本批回退** ✅
> 📌 **完整记录（含两版的实测数字 ＋ 正确的修法）**：`sim/evidence/a3-drum-raw-20261008/README.md` ✅

**目标**：⭐ 把鼓扫频判据读到的"音高档"从**轮转刷新（≤32 拍）**变成**当拍就绪** ⇒ **零窗口** ✅

### 11.1 关键洞察

鼓的**音高档分类**（`is_kick` / `is_tom`）用的是 `oscillator_bank` 的 `base_phase_inc_i`
= ⭐ `note_manager.voice_phase_inc_o` = **变调后**的值（`phase_tr`，轮转刷新）⚠️

🔴 但 ⭐ **这个分类本来就不该被变调带走** —— 鼓种应该由"**按的哪个键**"决定 ✅
📌 证据：⭐ `T3_EN=0` 时 `voice_phase_inc_o = phase_r[g] << base_oct_r`（**未变调**）⇒
⭐ **两档的分类口径本来就该一致** ✅

### 11.2 修法（⭐ 纯 wire，⛔ 不加 FF、⛔ 不加乘法器）

| 步 | 改动 |
|---|---|
| 1 | `note_manager`：新增输出 ⭐ `voice_phase_raw_o[POLY*PHASE_W]` = **未变调的每 voice 相位**<br>⭐ **实现位置**：⭐ 放进**模块级**的 `gen_pack` 循环（⭐ 与 `voice_axis_o` 并列）——<br>`assign voice_phase_raw_o[g*PHASE_W +: PHASE_W] = (base_oct_r == 2'd0) ? phase_r[g] : (phase_r[g] << base_oct_r);`<br>📌 ⭐ **只依赖 `phase_r`/`base_oct_r`（都在模块级）⇒ 与 `T3_EN` 无关** ⇒ ⛔ **不用在 `g_t3`/`g_t2` 两个分支里各写一遍** ✅（⭐ 那正是 `voice_phase_inc_o` 当初要挪进 generate 的原因）✅ |
| 2 | `oscillator_bank`：新增输入 ⭐ `phase_raw_i`；**只**用它算 `is_kick`/`is_tom`（⭐ 其余照旧） |
| 3 | ⭐ **Z-safe 回退**（⭐ 关键，⛔ 否则老例化会变 X）：<br>`wire [PHASE_W-1:0] raw_g = (phase_raw_i === {PHASE_W{1'bz}}) ? bv : phase_raw_i;`<br>⇒ ⭐ 上层不接（全 Z）⇒ **逐位回退到原行为** ⇒ 老 tb 一个都不用改 ✅ |
| 4 | `top.v`：把 `voice_phase_raw_o` 接到 `oscillator_bank.phase_raw_i` ✅ |

### 11.3 为什么它比第一版好

| 维度 | 第一版（`rot_cnt` 跳转） | ⭐ 本版 |
|---|---|---|
| 窗口 | ≤32 拍 → **≤1 拍** | ⭐ **0 拍**（当拍就绪） |
| 代价 | 一个 5 位 mux | ⭐ 纯 wire（1024 根线，⛔ 0 FF / 0 LUT 逻辑） |
| ⚠️ 对 T3 写侧路径（+0.051 ns，余量极薄） | 🔴 **加 mux ⇒ 直接压上去** | ✅ **不碰写侧**（只是**读** `phase_r`） |
| 契约 | 🔴 打红 `tb_transpose` 3 条 | ✅ `T3_EN=0` 档逐位不变（Z-safe 回退）；`T3_EN=1` 档**鼓分类变得更对** |

### 11.4 实施后要跑

1. ⭐ `tb_drum_pitch_env` / `tb_oscillator_bank`（⭐ 鼓分类的既有契约）
2. ⭐ `tb_p5_osc_equiv`（⭐ 逐位等价 —— 若它没接新端口 ⇒ **Z-safe 回退**必须让它逐位不变 ✅）
3. ⭐ `tb_transpose`（⭐ T3 的 T1/T2/T3/T6/T7）
4. ⭐ **四道门**（综合 / 聚焦 / PnR / 全量回归）
5. ⚠️ **特别看 =1 档的 T3 写侧那条 +0.051 ns 有没有被带坏**（⭐ 本修法不碰写侧 ⇒ 应当无影响 ✅）

### 11.5 ⭐ 实施结果（2026-10-08）

| 项 | 结果 |
|---|---|
| 改动文件 | `rtl/w3b/oscillator_bank.v`（新输入 `phase_raw_i` + Z-safe + 鼓分类）· `rtl/w3b/note_manager.v`（新输出 `voice_phase_raw_o` + 模块级 `gen_pack` 打包）· `rtl/top.v`（接线 `nm_phase_raw`）· `tb/models/oscillator_bank_ref.v`（⭐ 同步，⛔ 否则逐位等价假红） |
| ⭐ 新判据 | 「tb/w3b/tb_osc_drum_raw.sv」（历史引用，当前未收录） —— **4/4 PASS**：<br>· `A1`：`base=嗵鼓档(12M)`、`raw=底鼓档(8M)` ⇒ ⭐ **`is_kick=1`**（⭐ 按原始相位判 ✅）<br>· `A2`：`raw=Z`（悬空）⇒ ⭐ **回退 `base`** ⇒ `is_kick=0`/`is_tom=1`（⭐ Z-safe 向后兼容 ✅） |
| ⭐ 反向验证 | 去掉修法（`bv_drum = bv`）⇒ **A1/A1b 两条 FAIL**（2 pass / 2 fail）✅<br>还原后**逐字节一致** ⇒ **4/4 复绿** ✅ |
| 零回归 | ⭐ 老 tb **一个都没改**：`tb_p5_osc_equiv`（逐位等价）· `tb_oscillator_bank` · `tb_drum_pitch_env` · `tb_transpose` · `tb_note_manager`(4/4) · `tb_sustain_pedal_wire` · `tb_right_adc` · `tb_top_m0` ⇒ **全绿** ✅ |

📌 **Z-safe 的代价是零**：⭐ 综合时上层接了 ⇒ `!== 1'bz` 是常量真 ⇒ ⭐ 工具直接折掉（⭐ 只看 1 位，
⛔ 不是 1024 位归约 —— 那才会是 ~1024 LUT 的浪费 ✅）



---

## 十、本批改动的文件清单

| 文件 | 改动 |
|---|---|
| `rtl/w3b/oscillator_bank.v` | ⭐ 颤音链两级流水（`vibrato_mod_r` / `vib_mul_r`） |
| `tb/models/oscillator_bank_ref.v` | ⭐ 同步加同一条流水（⭐ 保住逐位等价判据） |
| `rtl/top.v` | ⭐ `N4` 比例守卫（`EVT_TRIG_TH`/`EVT_REL_TH` 相对行程的百分比 + `$fatal`） |
| `tb/top/tb_right_adc.sv`（新） | ⭐ `=1` 档功能判据（双实例差分，7 条） |
| `sim/tb_all.ps1` | ⭐ 给 `tb_right_adc` 300 s 预算 |
| 15 个 `.ps1` | ⭐ 补 UTF-8 BOM（⭐ 项目硬规矩；`tools/check_ps1_encoding.ps1` 现在 **32/32 全过**）✅ |
| `files/00-总览/第四周/第四周计划-20261008.md` | ⭐ §4.5 结果 ＋ 剩余项（含"=1 档无功能判据"这条缺口） |
| `files/00-总览/第三周/第三周计划-v2-实测修正版.md` | ⭐ `N4` 行收口（⭐ 原描述已过时） |


