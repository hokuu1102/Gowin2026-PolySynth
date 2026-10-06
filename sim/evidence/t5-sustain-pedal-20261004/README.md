# 证据 · T5 延音踏板语义（2026-10-04）

> **任务**：第三周计划 v1 §3.1 任务表 **T5** ——「延音踏板语义：踏板按下期间 `note_off` 只关 gate、不关包络」
> **约束**（用户 2026-10-04）：**不动时序**（本轮不做任何资源/时序优化）· 允许阻塞等待 · 自动化执行
> **方案**：`files/20-代码/延音踏板语义-实施方案-20261004.md`
> **备份**：tag `pre-sus/2026-10-04` ＋ bundle `…\_tmp\FPGA2026-pre-sus-2026-10-04.bundle`（174 refs 已 verify）

---

## 一、四道门（全部通过）

| 门 | 判据 | 结果 |
|---|---|---|
| **① 综合门** | `ERROR=0` ＋ `GowinSynthesis finish` | ✅ **0 行 ERROR** |
| **② 聚焦 tb** | 全 PASS | ✅ **16/16**（含新增 2 个 T5 tb） |
| **③ 干净 PnR** | 出 `.fs` ＋ 无 `PR0004` ＋ `0/0` | ✅ **6.4 min** · `.fs new=True`（18,883 KB）· **0 setup / 0 hold** · **无 `PR0004`** · `Fmax 55.060 MHz` |
| **④ 全量回归** | **通过数 == 共数** | ✅ ⭐ **通过 127 / 共 127**（129 发现 − 2 工具 tb） |

⭐ **位流**：`Gowin2026-t5-pedal.fs`（18,883 KB）· sha256 `D32CA7E4C7EC3362DDB3959BEE30B1C8BB51CC113250482F22DE95F644CAD224`
⭐ **资源**：`T_Lut 27271`（+172）· `T_Register 16975`（+53）· `T_Alu 6871`（+2）· `CLS 78%` · `Logic Level 10`

> ⚠️ **位流 sha 会随重跑变**（⭐ 实测）：同一棵 T5 树重跑 PnR 两次 ⇒ **`Fmax`/资源/违例数逐位相同**
> （都 `55.060 MHz` / `T_Lut 27271` / `0/0`），但 `.fs` 的 **sha256 不同**
> （`D32CA7E4…` vs `815D6C49…`）⇒ ⭐ **判据看 `Fmax`/`0/0`/`T_Lut`，⛔ 不要拿 `.fs` 的 sha 当"版本指纹"** ✅
> 📌 归档件 `Gowin2026-t5-pedal.fs` = 第一次跑（`D32CA7E4…`）；`impl/pnr/Gowin2026.fs` = 重建（`815D6C49…`）

---

## 二、⚠️ 时序代价（⭐ A/B 归因实测，⛔ 不是估计）

| 版本 | `Fmax` | 说明 |
|---|---|---|
| **去掉 T5**（`git stash` 两个 RTL 文件后重跑同一流程） | ⭐ **56.351 MHz** | 与队友交付的 `R_merged_56p351` **逐位相同** ✅ |
| **含 T5** | **55.060 MHz** | ⚠️ **−1.291 MHz** |

⭐ **结论**：这 1.29 MHz **确实由 T5 引入**（同一棵树、同一流程、只差那两个文件 ⇒ 排除了布局噪声）。
⚠️ 仍在门槛内（判据 `Fmax ≥ 51.5`）✅，但**比队友交付的 56.351 低** ⇒ 需用户裁定是否接受。

📌 **可能的廉价回收点**（⛔ 本轮未做 —— 用户说"不动时序"）：
`live_mask` 里的 `| sus_hold_r` **可能是冗余的** —— 被留住的音 `env_active_r` 必然为 1
（包络停在 sustain ⇒ 电平非 0 ⇒ `active_o=1`）⇒ 本来就 `live_mask=1`。
⭐ 若去掉它，新增逻辑只剩"`voice_gate_o` 的一个 OR ＋ 一个 32 位寄存器"。

---

## 三、实现（改了 2 个文件，⛔ 没碰包络/振荡器）

| 文件 | 改动 |
|---|---|
| `rtl/w3b/note_manager.v` | 新增端口 `sus_pedal_i` ＋ 每 voice 一位 `sus_hold_r`；`voice_gate_o = gate_mask \| sus_hold_r`；`live_mask \| sus_hold_r`；`note_off` 时（踏板踩住且 `src==0`）置位；四条清零路径（复位 / 松踏板 / 重触发 / 提交） |
| `rtl/top.v` | 新增参数 `PEDAL_DB_MS=5`；`pedal_sus_i` → Z-safe 归一 → `sync_input` → `debounce` → `sus_pedal_r`（1=踩住）→ `u_note_manager.sus_pedal_i`；⭐ **把 `pedal_sus_i` 从 `reserved_in_xor` 摘掉**（11→10 个输入） |

**⛔ 一行未改**：`envelope_bank.v` · `adsr.v` · `oscillator_bank.v` · `tdm_render_mixer.v` · `axis_map.v`
⭐ 原理：包络只看 gate ⇒ `gate_r=0` 但 `sus_hold_r=1` ⇒ 引擎看到的仍是 1 ⇒ **停在 sustain、不进释放** ✅

### 语义口径（⭐ 我替你定的两条，⛔ 可一行改回）

| # | 口径 | 定法 |
|---|---|---|
| 1 | 影响哪些源 | ⭐ **只影响手弹（`src == 0`）** —— 节拍器/鼓机/looper 回放的 `note_off` 照常释放（⭐ 否则破坏节奏与鼓的衰减；⭐ 且与"只有手弹才清力度目标"的既有口径一致） |
| 2 | 松踏板 | ⭐ **所有被留住的音同时释放**（钢琴标准行为）；⭐ 松键之后才踩 ⇒ **不复活** |

---

## 四、判据（⭐ 新增 2 个 tb，共 28 条）

### 4.1 模块级 `tb/w3b/tb_note_manager_sus.sv` —— **19/19**（3 秒）

| 组 | 判据 |
|---|---|
| **S1 不踩踏板**（回归 + 反向对照） | gate=1 按住 / 松键后 gate=0 / **电平回 0** / 包络不活跃 |
| **S2 踩住踏板** | 松键后 gate **仍为 1** / ⭐ **电平仍高（>5000）** / 包络仍活跃 |
| **S3 松踏板** | gate 落 0 / **电平开始下降** / **最终归 0** / 包络不活跃 |
| **S4 同轴再按** | 该轴**只有 1 个 voice**（⛔ 不叠音）/ 正常重触发 |
| **S5 非手弹源** | 踩住踏板时 `src=1` 的松键**照常释放**（⭐ 口径 1） |
| **S6 事后踩踏板** | ⭐ **不复活**（gate 保持 0） |

⭐ **实测曲线**（tb 里的 traj 探针，⭐ 已删）：不踩 ⇒ 松键后 ~50 拍电平归 0；
踩住 ⇒ 松键后 50 拍仍有 **10752**、400 拍仍有 **51032** ✅

### 4.2 顶层接线 `tb/top/tb_sustain_pedal_wire.sv` —— **9/9**

| # | 判据 |
|---|---|
| W1 | 空闲 ⇒ `sus_pedal_r=0`（⛔ 不误判成踩住）＋ `note_manager.sus_pedal_i=0` |
| W2 | 踩下 ⇒ 去抖后 `sus_pedal_r=1`（⭐ **极性正确**） |
| W5 | ⭐ **端口真接上了**：踩住时 `u_note_manager.sus_pedal_i=1`（⭐ 层次引用实测） |
| W3 | **短毛刺（< 去抖窗口）⇒ 状态不变**（⭐ 去抖真的在工作） |
| W4 | 松开 ⇒ `sus_pedal_r=0` ＋ `sus_pedal_i=0` |
| W6 | ⭐ **Z-safe**：悬空（`Z`）⇒ 按"未踩"（⭐ 这条保证 ~13 个老 tb 不用改） |
| W7 | `sus_pedal_r` 全程无 X/Z |

### 4.3 ⭐ 真变异反向验证（⭐ 证明判据不是空判据）

| 变异 | 结果 |
|---|---|
| **M-SUS1**：去掉 `voice_gate_o` 的 OR（= 功能没接上） | ✅ **7 条 FAIL**（S2b/S2c/S2d/S3b/S4a/S4b/S4d）⇒ 判据**真能红** ✅ |
| 还原（用 `*.AFTER` 字节级还原） | ✅ **19/19 复绿**，sha256 与备份**逐字节相同** |

### 4.4 零回归证据（⭐ 老 tb 一个都没改）

`tb_note_manager`（4/4）· `tb_note_manager_vel_ramp` · `tb_note_manager_write_share`（⭐ 队友的）·
`tb_adsr` · `tb_envelope_bank` · `tb_nm_no_leak` · `tb_nm_off_in_hold` · `tb_nm_reuse_tail` ·
`tb_transpose` · `tb_top_m0` · `tb_top_sound` · `tb_top_led_strip` · `tb_oscillator_bank` · `tb_p5_osc_equiv`
⇒ ⭐ **全部 PASS**（老 tb ⛔ 不接 `sus_pedal_i` ⇒ 悬空 `Z` ⇒ 按"未踩" ⇒ 逐位同前 ✅）

---

## 五、⚠️ 与方案的偏差（⭐ 已向用户说明）

方案 §6.2 原计划写"端到端音频 tb（E1~E3：踩踏板 ⇒ 松键后 `HP_DIN` 仍有声）"。
⭐ **实际改为**：模块级**包络电平测量**（`env_level` 就是音的幅度 ⇒ "音不消失"已被直接量化）
＋ **顶层接线 tb**（极性/去抖/Z-safe/端口真接上）。
**理由**：音频级端到端要复制 ~1000 行 ADC 从机夹具（`mcp3208_model` 注入 + 轴映射 + 阈值），
且需改动队友的验收 tb（`tb_e2e_key_to_sound`）—— ⚠️ 那是**已交付行为的契约**，⛔ 不宜动。
⭐ **音质层面的最终确认放到上机**（⭐ 已写进给队友的上机指南 §3.3 变调那节的同类位置）。

---

## 六、复现命令

```powershell
# 模块级语义（19 条）
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_note_manager_sus
# 顶层接线（9 条）
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_sustain_pedal_wire
# 四道门
powershell -NoProfile -ExecutionPolicy Bypass -File sim\pnr_run.ps1 -MaxAttempts 1 -SkipRegression -MinFmax 51.5
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1
```
