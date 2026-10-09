# ANVIL-01 · `rtl/w3b/note_manager.v` 扒皮报告（逐行取证版）

> 审计对象：`rtl/w3b/note_manager.v` · 交付档 **GW5AT-60B / AC1-I0 / clk_sys 50 MHz / set_max_delay 18.181 ns**
> 目标模块实测：`impl/pnr` = **55.313 MHz · 0 setup / 0 hold**（=0 档）；右手板 =1 档 **≈57.0 MHz · CLS 81%**
> 纪律：**每条结论 = 文件:行号 + 代码片段 + 机制（带数字）+ 改法 + 收益/代价 + 怎么验证能红**。
> 无证据的推测一律标注 `【推测】`，凡未实测的数字一律标注来源。

---

## 〇、证据基础核对（先钉死"我在审哪一版"）

| # | 事实 | 证据 |
|---|---|---|
| 0.1 | 🔴 **文件不是 1106 行，是 1710 行** | `LF=1710 · CR=0 · 132237 B`（字节级统计）；`read` 尾行 `1710: \`default_nettype wire`；mtime `2026-10-09 09:21:22`。"1106 行"是**过时数字**（T3/T5/A3 三次追加之前）。 |
| 0.2 | ✅ 当前文件 == 最后一次综合/布局的源码 | `sim/evidence/a3-proper-20261008/syn.log:152-162` 报的行号与当前文件**逐行对齐**（`vtgt_val`:457 · `vtgt_vld`:458 · `vtgt_rep`:474 · `fifo_v`:543 · `fifo_inc`:545 · `fifo_timbre`:549 · `fifo_src`:553 · EX3045:1497 · EX3791:1578）。⇒ 资源/时序结论**对当前文件成立**。 |
| 0.3 | ✅ 工作区干净、已提交 | `git status --porcelain rtl/w3b/note_manager.v` 空；HEAD = `026ed21 2026-10-09 09:21:22 deliver(右手板)`。 |
| 0.4 | 🔴 **交付档是 `T3_EN=1`，不是文件里反复暗示的 0** | `syn.log:151`：`Compiling module 'note_manager(T3_EN=1,RESERVED_N=5,DRUM_TOM_MAX=20000000)'`；`rtl/top.v:329` `parameter integer T3_ENABLE = 1`；`rtl/top.v:4015` `.T3_EN (T3_ENABLE)`。⇒ 文件头 `:65-81` 那段"**把 T3 关起来**"的描述**与交付档相反**（详见 P1-4）。 |
| 0.5 | ✅ 模块资源实测（**这是本次审计最重要的一组数**） | `sim/evidence/a3-proper-20261008/rsc.xml`：`g_sound.u_note_manager` = **`T_Lut 9618` · `T_Register 4430` · `T_Alu 918` · `MULT27X36 1` · `Bsram 2`**；全设计 `T_Lut 27140` · `T_Register 17039`。⇒ **note_manager 一个模块吃掉全设计 9618/27140 = 35.4% 的 LUT、4430/17039 = 26.0% 的 FF。** |
| 0.6 | ✅ 全设计最差路径就在本模块 | `impl/pnr/Gowin2026.timing_paths` 第 1 条：`rot_cnt → rot_phase_20_* → rot_base_22_* → prod_w_0_s → phase_tr[28]`，**slack +0.102 ns**（=全设计最紧）；第 2 条是 `tdm_render_mixer`，slack +0.133。 |
| 0.7 | ⚠️ **一处证据口径不自洽，必须记账** | `constr/top.sdc:101` `set_max_delay ... 18.181`；但 `Gowin2026.timing_paths` 第 1 条打印的 required = **22.274 ns**（比 SDC 松 4.09 ns）。而工具自己的 `Actual Fmax 55.313 MHz` = `1/(18.181 − 0.102)`（对得上 README 的算法）。⇒ 该 `.timing_paths` 里的 required 字段含**时钟公共项**，**不能直接当"约束"读**；引用时必须换算，否则会得出"22.17 ns 路径却 0 违例"的假矛盾。 |
| 0.8 | ⚠️ **文件里三套"验收 T_Lut"互相打架** | `note_manager.v:1437` 与 `:1622` 写"`T_Lut` 必须回到 **37026 ± 100**"；`:1571` 又写"关掉 T3 的基线（**31039**）"；实测 **27140**（a3-proper）/ **27271**（final-batch）。⇒ **37026 / 31039 / 27140 三个数并存**，拿它当门槛必然假红（P1-4）。 |
| 0.9 | ✅ `oscillator_bank_ref.v` 历史坑现状 | 树里共 **3 个不同 SHA** 的 `oscillator_bank`：`rtl/w3b/oscillator_bank.v` `7307F32B…`(72951 B) · `tb/models/oscillator_bank_ref.v` `F2005CC9…`(62794 B) · 归档副本 `3675566A…`(61735 B，`build/p5-recon/verify_osc/` 与 `sim/evidence/p5-2-osc-20261004/`)。`tb/w3b/tb_p5_osc_equiv.sv:15-17` 明写"**将来若再改 `oscillator_bank`，必须同步换新参考**，否则本 tb 会**静默恒真**（`C83` 探针假绿同族）"。⇒ **`tb_p5_osc_equiv` 只能证 `oscillator_bank` 自身没变，⛔ 证不了 `note_manager` 的相位语义**（见 P1-1 的验证章节）。 |
| 0.10 | ✅ 所有时序数字均为**单次 PnR**，本项目已知同源重跑差 2~3 MHz | `AGENTS.md` §四 + 本批 README。⇒ 下文凡"结构性/运气"判定，**一律用"跨构建复现性"作判据**（见 §六）。 |

---

## 一、P0 —— 立刻要修（功能错、可达、可听）

### 【P0-1】力度斜坡的 8 位截断 ⇒ `vel_r ≥ 248` 时**回绕到 0~7**（重放满力度音立刻掉 31 dB）

**位置**：`rtl/w3b/note_manager.v:1064-1081`（两处镜像：手弹支 `:1069-1072`、回放支 `:1076-1078`）

```verilog
1069:                            if (vtgt_vld[axis_r[i]]) begin
1070:                                if      (vtgt_val[axis_r[i]] > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;
1071:                                else if (vtgt_val[axis_r[i]] + 8'd8 < vel_r[i]) vel_r[i] <= vel_r[i] - 8'd8;
1072:                                else                                            vel_r[i] <= vtgt_val[axis_r[i]];
1073:                            end
...
1076:                            if      (vtgt_rep[i] > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;
1077:                            else if (vtgt_rep[i] + 8'd8 < vel_r[i]) vel_r[i] <= vel_r[i] - 8'd8;
1078:                            else                                    vel_r[i] <= vtgt_rep[i];
```

**为什么是问题（机制带数字）**
`vel_r` 是 `reg [7:0]`（`:439`），`8'd8` 是 8 位常量 ⇒ 在比较/赋值语境里整个加法表达式**自定宽度 = 8 位**（IEEE 1364-2001 §5.1.1：加法宽度 = 双方宽度最大值，比较**不会**把操作数加宽到 9 位）。于是 `vel_r[i] + 8'd8` 是 **mod 256**：

| `vel_r` | `vel_r + 8'd8` 实际值 | 条件 `tgt > (vel_r+8)` | 结果 |
|---|---|---|---|
| 240 | 248 | `tgt>248` 才走上升支 | ✅ 安全（**这正是现有 tb 的最大值**） |
| 247 | 255 | `tgt>255` 永假 ⇒ 走 else 吸附 | ✅ 安全 |
| **248** | **0** | `tgt > 0` **几乎恒真** | 🔴 `vel_r <= 0` |
| **250** | **2** | `tgt > 2` 恒真 | 🔴 `vel_r <= 2` |
| **255** | **7** | `tgt > 7` 恒真 | 🔴 `vel_r <= 7` |

**可达性（三路，全部实锤）**

1. **回放支（src≠0）无 `vtgt_vld` 门** ⇒ 提交那一刻 `vel_r[i] = vtgt_rep[i] = cmt_vel_r`（`:1365` / `:1385`），两者相等。若事件力度 = 255 ⇒ **第一个 `sample_tick` 就命中**：`255 > 255+8(=7)` 为真 ⇒ `vel_r <= 7`。**不需要任何用户动作，录一段满力度再回放即复现。**
2. 力度上限确实是 255：`rtl/w3a/param_extract.v:96` `parameter [VEL_W-1:0] VEL_MAX = 8'd255`；`:189` `vel_lut[lut_i] = VEL_MAX;`。
3. 掉多少：`adsr.v` 里 `peak = velocity << 8` ⇒ 255→65280、7→1792 ⇒ **−31.2 dB**；随后在 0↔248 之间**锯齿**（32 拍 = **655 µs ≈ 1.53 kHz 颤音**）。

**同时违反文件自己的纪律**：`:1024-1031` 明写"⛔ 不许 `vel_r` 一拍整值跳、每采样拍最多 ±8"（`K-154`），而本 bug 是**一拍跳 248**。

**为什么现有 tb 全绿（这是关键，说明判据是假的）**
`tb/w3b/tb_note_manager_vel_ramp.sv:28` / `:35` 的"黄金模型"**逐字复制了同一个表达式**：

```verilog
28:                if      (tgt_axis > cur + 8'd8) old_next = cur + 8'd8;
35:            if      (tgt_rep > cur + 8'd8) old_next = cur + 8'd8;
```

而它的激励**恰好扫到了失败点**（`tb_note_manager_vel_ramp.sv:70-71`：`tvals = {0,1,7,8,9,127,128,247,248,254,255}` × `cur=0..255`）⇒ 两边**一起错、比出来相等** ⇒ `mism=0` ⇒ `PASS`。**这是 `C83`「探针假绿」的教科书样本：判据复刻了被测实现的 bug。**
另一个 tb 的最大力度是 `tb/w3b/tb_note_manager.sv:591` `vel_upd_value = 8'd240` ⇒ **248~255 全区间零覆盖**。

**具体怎么改**（1 行 × 2 处；**不需要加钳位**，理由见下）
```verilog
// 9 位比较：把两侧零扩展后比较，加法不再截断
if ({1'b0, vtgt_val[axis_r[i]]} > {1'b0, vel_r[i]} + 9'd8) vel_r[i] <= vel_r[i] + 8'd8;
```
*为什么不用钳位*：上升支成立的前提是 `tgt > vel_r+8`（9 位）⇒ `vel_r+8 < tgt ≤ 255` ⇒ 和**必 ≤254**，天然不溢出。下降支同理（`tgt+8 < vel_r` 且 `tgt≤247` 时才可达，不会下溢）。

**预期收益 / 代价**：修一个 −31 dB 的可听功能缺陷；代价 ≈ 每 voice 每分支 +1 LUT × 2 分支 × 32 voice ≈ **+64~128 LUT（<0.5% T_Lut）**，无时序影响（不在关键路径上）。

**怎么验证能红**
1. 把 `tb_note_manager_vel_ramp.sv` 的黄金模型改成**规格式**（不是表达式复刻）：
   `next = (tgt > cur+8) ? min(cur+8,255) : ((tgt+8 < cur) ? max(cur-8,0) : tgt)`（比较用 9 位）⇒ 未修复 RTL 在 `cur ∈ 248..255` 必然 mismatch ⇒ **RED**（现在这条 tb 是 GREEN，改完判据才第一次有牙）。
2. `tb_note_manager.sv` 加一条定向：`note_velocity = 8'd255` → 等 1 个 `sample_tick` → 断言 `vel_of(i) === 8'd255`（当前必 FAIL，值为 7）。
3. 变异测试：把 `8'd8` 改成 `9'd8`（只加宽一侧）⇒ 必须仍然 RED，证明判据抓的是宽度而不是巧合。

---

## 二、P1 —— 结构性长路径 / 结构性资源浪费 / 契约失真

### 【P1-1】`phase_tr` 轮转 ＋ 共享乘法器链 = **全设计第 1 条关键路径（slack +0.102 ns）**，且是**结构性**的

**位置**：`note_manager.v:1532-1544`（读侧）＋ `:1575-1578`（写侧）

```verilog
1532:    wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];
1533:    wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase
1534:                                                        : (rot_phase << base_oct_r);
1540:    wire [4:0]         ratio_idx  = semi_cur + 5'd12;
1541:    wire [16:0]        semi_ratio = semi_ratio_of(ratio_idx);
1544:    wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;
...
1575:            if (rot_ok)
1576:                phase_tr[rot_cnt] <= ((semi_cur == 5'sd0) ||
1577:                                      (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
1578:                                   ? rot_base : (prod_w >>> 15);
```

**证据（`impl/pnr/Gowin2026.timing_paths` 第 1 条，逐节点到达时间）**

| 段 | 节点 | 到达时间 | **本段耗时** | 性质 |
|---|---|---|---|---|
| 起点 | `g_t3.rot_cnt_0_s0` | 0.000 → 1.288 | — | 5 位轮转计数器 FF |
| 布线 | → `rot_phase_20_s83` 入 | 1.288 → 4.142 | **2.85 ns** | 纯布线 |
| **32:1 读 mux** | `rot_phase_20_s83/s71/s65/s62/s61` | 4.142 → 10.398 | **6.26 ns / 5 级 LUT** | `phase_r[rot_cnt]` |
| 布线 | → `rot_base_22_s1` | 10.398 → 11.502 | 1.10 ns | |
| **八度移位** | `rot_base_22_s1/s0` | 11.502 → 12.586 | 1.08 ns / 2 级 | `<< base_oct_r` |
| **共享乘法器** | `prod_w_0_s` | 13.589 → 16.123 | **2.53 ns（DSP）** | `MULT27X36 ×1`（`rsc.xml` 实锤） |
| 选择 mux | `n34284_s0` | 16.296 → 16.765 | 0.47 ns | 旁路选择 |
| **末段布线** | → `phase_tr[28]_24_s0` | 16.765 → **22.172** | **5.41 ns** | 到 1024 个 FF 的写译码 |
| — | **合计** | — | **22.172 ns**（required 22.274） | **slack +0.102 ns** |

⇒ **一整个 18.181 ns 周期里，`rot_cnt` → 32:1 mux → 移位 → DSP → 写译码 是串成一条的组合链**：mux+其前布线 **9.11 ns（50%）**、DSP **2.53 ns**、末段布线 **5.41 ns（24%）**。

**是结构性还是布局运气？—— 跨构建复现性判据**
| 构建 | 全设计最差路径 | 出处 |
|---|---|---|
| 2026-10-02 | `fifo_ax → n1577 → same_idx_0/1 → same_valid_* → scan_cnt`（本模块 FIFO 读 mux ＋ 优先编码） | `sim/evidence/evt_merge-narrow-20261002/pnr-impl/pnr/Gowin2026.timing_paths` |
| 2026-10-03 | `env_active_r_25 → oscillator_bank/lane_active → same_valid_* → scan_cnt` | `sim/evidence/p5-adsr-20261003/Gowin2026.timing_paths` |
| 2026-10-09（当前） | `rot_cnt → rot_phase → rot_base → prod_w → phase_tr` | `impl/pnr/Gowin2026.timing_paths` |

⇒ **4 次归档构建里 3 次最差路径落在 `note_manager`（或穿过它）**，且每次都换一条链——**这排除了"布局运气"**：运气不会连续 3 次都落在同一个模块、并且每次都精确落在"该模块当前最长的那条组合链"上。**结论：结构性问题。**
（"布局噪声 2~3 MHz"的机制也在这里：+0.102 ns 余量 ⇒ 约 0.65 ns 的布线抖动就能翻掉 2 MHz，**它正好是余量最小的那条链**。）

**具体怎么改（二选一，推荐 A）**
- **A（切在 mux 与 DSP 之间）**：加一级流水 —— `rot_phase_r <= phase_r[rot_cnt]; rot_src_r <= src_r[rot_cnt];`（35 FF），下一拍用 `rot_phase_r` 算 `rot_base`/`prod_w`/写 `phase_tr`。为对齐，`rot_cnt` 与旁路判据 `semi_cur==0` 也要各延一拍（`rot_cnt_d1`，5 FF；`semi_bypass_d1`，1 FF）。
  **代价**：+41 FF · T3 刷新周期 32 → **64 拍 = 1.28 µs**（远小于 1 ms 短滑音 ⇒ 语义无损）；`phase_tr` 的"≤32 拍"契约要改成 ≤64 拍（`tb_transpose.sv` 的 `T1_SETTLE` 需同步）。
  **收益**：把 **9.11 ns 的 mux 段**从链上摘掉 ⇒ 该路径降到 ≈13 ns ⇒ 这条链**不再是最差**。
- **B（切在 DSP 输出）**：只寄存 `prod_w`（49 FF）⇒ 摘掉 DSP 的 2.53 ns＋末段布线的一部分，收益小（≈5 ns），且要处理"寄存后写哪个 lane"。

**⚠️ 但必须同时看第 2 名**：`tdm_render_mixer` 第 2 条路径 20.062 ns / slack **+0.133**。⇒ **只修 T3 链，Fmax 只从 55.313 → 55.4 MHz（+0.1 MHz，等于没涨）**。要真涨必须**两条一起切**。这条账必须写进计划，否则会误判"修了没效果"。

**怎么验证能红**
1. `sim/gowin_build.ps1` 重跑 PnR，断言新 `timing_paths` 第 1 条**不再是** `rot_phase/rot_base/prod_w`；同时 `timing.txt` 的 `Actual Fmax` 与 `Numbers of Setup Violated Endpoints` 两项都要看。
2. 功能等价：`tb/w3b/tb_transpose.sv` 的 `T1`（与基线逐位差分）必须在**放宽到 64 拍**后仍 PASS；再补一条"0 档逐位恒等"用例（`transpose_semi_i` 悬空 ⇒ `semi_cur` 恒 0 ⇒ 输出 == `phase_r[g]`）。
3. 🔴 **`tb_p5_osc_equiv` 对此改动【无效】**（见 §0.9）：它只比 `oscillator_bank` vs 它自己的旧副本，相位语义变了它也不知道。别拿它当"没坏"的证据。

---

### 【P1-2】`vtgt_val[axis_r[i]]` 写在 **32 voice 循环里** ⇒ 32 个读端口 / 32 份 RAM 副本，且压在 **256 个 `vel_r` 的 CE 路径**上

**位置**：`note_manager.v:1064-1081`（循环体内两次查表）

```verilog
1064:            if (sample_tick_i) begin
1065:                for (i = 0; i < POLY_TARGET; i = i + 1)
1066:                    if (gate_mask[i]) begin
1067:                        if (src_r[i] == 3'd0) begin
1069:                            if (vtgt_vld[axis_r[i]]) begin
1070:                                if (vtgt_val[axis_r[i]] > vel_r[i] + 8'd8) ...
```

**为什么是问题（机制带数字）**
`vtgt_val` 是 `reg [7:0] vtgt_val [0:15]`（`:457`，**16 项 × 8 位**），`vtgt_vld` 是 16 位（`:458`）。它们在**每个 voice 的循环体里被按 `axis_r[i]` 索引** ⇒ 综合器面对的是 **32 个独立读地址**：

| 实现方式 | 面积 | 证据/推算 |
|---|---|---|
| 每 voice 一份 16:1 mux（8 位） | 32 × 8 × 5 LUT = **1280 LUT** | LUT4 只能当 2:1 mux（1 sel + 2 data）⇒ 16:1 = 4 级 |
| `vtgt_vld` 同上（1 位） | 32 × 5 = **160 LUT** | |
| 若被识别成分布式 RAM 并**复制 32 份** | 32 × (16×8/16) ≈ **256 LUT** | `syn.log:152-153` 明确 `Extracting RAM for identifier 'vtgt_val'/'vtgt_vld'` ⇒ 至少走了 RAM 路径 |

⇒ **无论哪条路，成本 ≥256 LUT、上限 ~1440 LUT（占本模块 9618 LUT 的 2.7%~15%）**；并且它**串在 `vel_r[i]` 的 CE 上**：CE 条件 = `sample_tick_i & gate_mask[i] & (src/比较)`，其中比较的输入就是这个查表结果 ⇒ **32 voice × 8 位 = 256 个 CE 端点同时被这个宽 mux 驱动**（`impl/pnr/Gowin2026_tr_content.html` 里 4517 端点违例就是"同一条链打到一大批 CE"的同一机制，`note_manager.v:336-341` 有原文引用）。
**文件自己算过这笔账的一半**（`:470-471`：64 项目标表 ⇒ 每 voice 一个 64:1 mux ⇒ +6000 LUT）—— 却**漏掉了已经在树上的这 16:1**。

**具体怎么改**：把"按轴查表"从**每拍 × 每 voice** 降到**每事件一次 + 每次 `vel_upd` 一次**
1. `vel_upd` 到达时（**已有同构代码**：`:1053-1058` 非手弹支）把同轴同源的 voice 直接写 `vtgt_rep[i]`；手弹支也照此办（去掉 `src_r[i]==3'd0` 的分叉，统一写 `vtgt_rep[i]`）。
2. 提交/重触发时初始化 `vtgt_rep[cmt_idx_r] <= vtgt_vld[cmt_axis_r] ? vtgt_val[cmt_axis_r] : cmt_vel_r;`（**全场只剩 1 个 16:1 mux**，40 LUT）—— 这样"更新早于 voice 出现"的自愈性（`:449-451` 的 `K-154` 论证）**仍然保留**。
3. 斜坡段（`:1064-1081`）改成只读 `vtgt_rep[i]`，**不查任何表**。
**预期收益**：−256 ~ −1400 LUT（1%~5% T_Lut，CLS 78% 的机器上就是 1~4 个点）、并把一条宽 mux 从 256 个 CE 的路径上摘掉。**代价**：手弹与回放共用一套 per-voice 目标 ⇒ 需要保留"每轴目标只在按住期间有效"的语义（`:1175-1187` 的清位逻辑要跟着挪），改动面约 30 行；**风险中等**（属"两套目标合并"，必须先补 tb）。

**怎么验证能红**
1. A/B 综合：改前/改后 `syn.log` 的 `T_Lut`（当前 9618）与 `rsc.xml` 的 `note_manager` 行对比；**预期 −256 以上**。
2. 功能：`tb_note_manager.sv` 的力度跟随组（`:606-610`、`:1186` 附近）＋ `tb_note_manager_vel_ramp.sv` 必须全绿；**并且**新增"更新先到、voice 后到"的定向用例（现在这条自愈性只有注释、没有 tb 钉住）。
3. 反向：故意删掉 `vtgt_vld[cmt_axis_r]` 三元判断 ⇒ 必须 RED（证明新结构真的读了每轴表）。

---

### 【P1-3】FIFO 排空时间 **1152 拍 > 一帧 1024 拍**，而文件论证"22.4 µs 仍在一帧内"是**算错的**

**位置**：`note_manager.v:99`（论证）＋ `:1125-1390`（FSM 实际拍数）＋ `:1703`（自检）

```verilog
99:    //       ⭐ 但**听感延迟不受影响** —— `adsr` 的 `gate` 只在 `sample_tick_i`（每 1024 拍）采样，
100:   //          22.4 µs 仍在一帧内（见文件头 `K-103` 的同一论证）。
...
1703:        if ((POLY_TARGET + 4) > 1024)
1704:            $display("ERROR [note_manager] POLY_TARGET+4=%0d > 1024（每帧可用 clk）=> 扫描跑不完一帧",
```

**为什么是问题（机制带数字）** —— 逐状态数拍（每个 `note_on` 事件）：

| 拍 | 状态 | 动作 |
|---|---|---|
| 0 | `fifo_push` | 事件入队（`:945-957`） |
| 1 | `ST_IDLE` | 取头锁存 `cur_*`（`:1126-1137`） |
| 2 | `ST_DECIDE` | 判同轴/开扫（`:1217-1224`） |
| 3~34 | `ST_SCAN` | **32 拍**（`:1272-1287`，`scan_cnt` 0→31） |
| 35 | `ST_COMMIT` | 只锁存 `cmt_*`（`:1306-1328`） |
| 36 | `ST_COMMIT2` | 真正写寄存器（`:1352-1389`） |

⇒ **单事件 = 36 拍**（= `POLY_TARGET + 4`，文件里那个 `+4` 恰好对，但含义是"**一个**事件"）。而 **FIFO 深度 32**（`:102`）⇒ 最坏突发（32 个 `note_on` 背靠背）排空 = **32 × 36 = 1152 拍 = 23.04 µs > 1024 拍 = 20.48 µs**。
⇒ 文件 `:99` 写的 `32×35 = 1120 拍 = 22.4 µs` **两个数都错**：(a) 每事件是 36 不是 35（`ST_COMMIT2` 是后加的，`:390-396`）；(b) **1120 > 1024**，"仍在一帧内"**算术上不成立**。
⇒ 后果（有界但真实）：最坏突发下，最后几个事件的 `gate` 会在**下一个 `sample_tick`** 才被 ADSR 看见 ⇒ **最多 +1 帧 = 20.48 µs** 的额外延迟。而 `:20-28` 整个"代价免费"的论证（K-103）**正是建立在这条之上**。
⇒ 自检漏了这一维：`:1703` 只查单事件（`POLY_TARGET+4 = 36 ≤ 1024` 恒真，**永不触发**），**没有查 `FIFO_DEPTH × (POLY_TARGET+4)`**。

**具体怎么改**：自检加一条（编译期可算，零硬件成本）
```verilog
localparam integer FRAME_CLK = 1024;                      // CLK_PER_SAMPLE（与 clk_gen 同值）
if (FIFO_DEPTH * (POLY_TARGET + 4) > FRAME_CLK)
    $display("WARNING [note_manager] 满队列排空 %0d 拍 > 一帧 %0d 拍 => 尾部事件晚一帧生效",
             FIFO_DEPTH*(POLY_TARGET+4), FRAME_CLK);
```
并把 `:99-101` 的注释改成实测拍数（36），把"仍在一帧内"改成"**最坏溢出 1 帧**"。

**预期收益 / 代价**：**零 RTL 代价**（只加自检 + 改注释）；收益是**把一条假论证从文档里拔掉**——它是"分配延迟 ≤34 拍/免费"整条链的承重墙。若真要不超帧：`FIFO_DEPTH ≤ 28`（28×36 = 1008 ≤ 1024）或把 `ST_SCAN` 的 32 拍改成两拍两个 voice。

**怎么验证能红**：`tb_note_manager.sv` 加一条"**32 个 `note_on` 连发**"用例，记录"第 32 个事件的 `gate` 生效时刻 − `note_valid` 时刻"，断言 ≤ 1024 拍（当前会得到 ≈1152 ⇒ RED）；再断言 `event_lost_o` 仍为 0（证明是"排队"不是"丢弃"）。

---

### 【P1-4】契约失真三连：`T3_EN` 默认值与交付档相反 ＋ 验收 `T_Lut` 三套数 ＋ 端口注释与 `top.v` 打架

**位置**：`note_manager.v:65-81`（"把 T3 关起来"）vs `rtl/top.v:329` / `:4014-4015`；`note_manager.v:1437` / `:1571` / `:1622`

```verilog
 65:    //   📌 **为什么要有它**（⭐ 详见 `files/20-代码/T3-后续计划-20261003.md` §三 `P1`）：
 70:    //      ⇒ ⭐ 用户 2026-10-03 拍板"**暂不做大改**" ⇒ ⭐ **把 T3 关起来，让主线恢复可交付** ✅
 81:    parameter integer T3_EN       = 0,
--- rtl/top.v ---
329:    parameter integer T3_ENABLE               = 1
4014:            // ⭐⭐ 2026-10-04：⭐ **T3 变调总闸**（⭐ 交付档 = 1，⭐ 见 `T3_ENABLE` 的说明 ✅）
4015:            .T3_EN       (T3_ENABLE)
```

**为什么是问题（机制带数字）**
1. **交付档 T3 是开的**（`syn.log:151` 实锤 `T3_EN=1`），而模块头 `:70-81` 告诉读者"关着"。任何按文件头推理的人都会得出**相反**的结论（例如"那段 `phase_tr` 不参与综合"——**它参与**，而且它就是全设计第 1 条关键路径）。
2. **验收数三套并存**：`:1437`/`:1622` = `37026 ± 100`；`:1571` = `31039`；实测 **27140**（`a3-proper/rsc.xml`）/ **27271**（`final-batch/README.md:33`）。⇒ 拿 `37026` 当门槛会得到"差 9800 LUT"的**假红**。
3. `:189` 写"悬空 ⇒ 0 档 ⇒ 逐位恒等"，但**交付档 `transpose_semi_i` 是接上的**（`top.v:4059` `.transpose_semi_i (transpose_semi)` ← `u_fader_gear.transpose_semi_o`，`:1786`）⇒ "0 档恒等"在交付档**只在用户没动推子时成立**，不是结构性保证。

**具体怎么改**：把 `:65-81` 整段改成"**交付档 = `top.v` 的 `T3_ENABLE`；本模块默认 0 仅为模块级 tb 兼容**"，并把三个 `T_Lut` 数改成**带日期与出处的唯一一个**（`27140 @ a3-proper-20261008`），其余标"历史值，勿用作门槛"。

**预期收益 / 代价**：零 RTL 代价；收益 = 防止下一轮"照文件头推理 ⇒ 判断错方向"（本项目已因"证据基础没核对"浪费过整轮，见 `AGENTS.md` §五①）。

**怎么验证能红**：在 `sim/` 里加一条 grep 式检查（或 CI 脚本）：`note_manager.v` 中出现的 `T_Lut` 数字必须能在最新 `rsc.xml` 里找到；找不到就报错。手工复核：`Select-String note_manager.v -Pattern "T_Lut"` 当前返回 3 个互斥数字。

---

### 【P1-5】`drum_cls_r`（A3）**没有**被同轴重触发写路径刷新 —— 文件自称的"不可分离"不成立

**位置**：写入方 A `note_manager.v:1363`（提交路径，**有**）；写入方 B `:1236-1268`（重触发路径，**没有**）

```verilog
1360:                        //  ⭐⭐ 2026-10-08（`A3` 正确修法）：⭐ **鼓分类与"占 voice"同拍写**
1361:                        //     ⇒ ⭐ 与 `axis_r`/`src_r`/`phase_r` **同生命周期**（⭐ 不可分离）✅
1363:                        drum_cls_r[cmt_idx_r*2 +: 2] <= {cmt_kick, cmt_tom};
...
1239:                        gate_r[same_idx_r]     <= 1'b0;
1258:                        src_r[same_idx_r]      <= cur_src;
1259:                        phase_r[same_idx_r]    <= cur_inc;     // ← 相位被改写
1260:                        vel_r[same_idx_r]      <= new_vel;
1262:                        age_r[same_idx_r]      <= {AGE_W{1'b0}};
1267:                        vtgt_rep[same_idx_r]   <= new_vel;
                        //  ← drum_cls_r 缺席
```

**为什么是问题（机制带数字）**：`drum_cls` 是 `phase_inc` 的**派生量**（`:835-836` 用 `cmt_inc_oct` 比 `DRUM_KICK_MAX_C`/`DRUM_TOM_MAX_C`）。重触发把 `phase_r` 改成新事件的 `cur_inc`，却把分类留在旧值 ⇒ **同一个 voice 的"相位"和"分类"来自两个不同事件** ⇒ `oscillator_bank` 会按**上一个鼓**的表去扫**这一个鼓**。这正是文件自己在 `:414-415` 为 `src_r` 立的纪律（"必须与 `axis_r` 在同一条写路径上更新，⛔ 否则留下源不明的 voice"）的同构违背。
**可达性（诚实评估：低，但不是零）**：需要"**同轴 + 同源**"（`same_hit` 要求 `axis_r` 与 `src_r` 都相等，`:688-690`）且**两次音高不同**；而分类只在 `src_r==3`（鼓机）时被 `oscillator_bank` 使用（`:1660` `voice_drum_o = (src_r[g]==SRC_AUX)`）⇒ 同一根轴同一来源通常是**同一件鼓**（同音高）⇒ 现实中很难触发。**但**：曲谱/looper 回放（src=1/2/4）在同轴换音高时**会**改写 `phase_r`，此时分类字段虽不被使用却已经**语义漂移**（一旦将来把 `DRUM_CLS_EXT` 扩展到回放路径就会立刻变成真 bug）。

**具体怎么改**：在 `ST_RETRIG` 里补一行（复用同一套比较器，`:832-836` 的表达式换成 `cur_inc`）
```verilog
wire [PHASE_W-1:0] cur_inc_oct = (base_oct_r == 2'd0) ? cur_inc : (cur_inc << base_oct_r);
// ST_RETRIG 内：
drum_cls_r[same_idx_r*2 +: 2] <= {(cur_inc_oct < DRUM_KICK_MAX_C),
                                  (cur_inc_oct >= DRUM_KICK_MAX_C) && (cur_inc_oct < DRUM_TOM_MAX_C)};
```
**预期收益 / 代价**：消除"两处真相"；代价 ≈ **+4~8 LUT**（一个 32 位变移位 ＋ 两个常量比较，**只在重触发拍用**，可被共享），**0 FF**（复用已有 `drum_cls_r`）。时序：新比较器挂在 `same_idx_r` 的写译码上，属短路径。

**怎么验证能红**：`tb/w3b/tb_osc_drum_cls.sv` 现在只测"提交那一刻"（README §三 A1/A2/A3/B1-B3）。补一条：**同轴同源先起"底鼓"（`phase_inc=8M`），在 `env_active` 未落前再起"嗵鼓"（`phase_inc=17M`）** ⇒ 断言 `voice_drum_cls_o[v] == 2'b01`（tom）。当前实现会给出 `2'b10`（kick）⇒ **RED**。

---

## 三、P2 —— 规则违背 / 可观测性缺口 / 参数健壮性

### 【P2-1】`FIFO_DEPTH[FW:0]` 与 `SCAN_LAST[SW-1:0]`：**文件自己禁止**的 `integer` 参数位选，出现在两处 FSM 关键比较上

**位置**：`:558`、`:1281`（vs 文件自己的纪律 `:56`，以及它**正确**的写法 `:404-405`）

```verilog
 56:    //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
404:    localparam [PHASE_W-1:0] DRUM_KICK_MAX_C = DRUM_KICK_MAX;   // ← 正确：显式定宽常量
405:    localparam [PHASE_W-1:0] DRUM_TOM_MAX_C  = DRUM_TOM_MAX;
...
558:    wire fifo_full  = (fifo_cnt == FIFO_DEPTH[FW:0]);            // ← 违规
1281:                    if (scan_cnt == SCAN_LAST[SW-1:0]) begin       // ← 违规
```

**为什么是问题（机制带数字）**：本项目**已有一次实测事故**，`files/20-代码/evt_merge设计说明.md:90-92` 原文：
> 🔴 bug 3：`DEPTH[15:0]` 对 `integer` 参数做位选（`K-91`）… **`K-91` 明确禁止**，而第一版就写了 ⇒ ⚠️ **索引比较全部失效**。

若 `fifo_full` 恒假 ⇒ **写指针绕过 32 深队列覆盖未读事件** ⇒ 静默丢音（丢 `note_off` 就是挂音，正是 `T38`/`K-106` 要防的失效模式），且 `event_lost_o` **永不置位**。
**诚实评估（概率低，但覆盖为零）**：
- 现有 tb **用 `FIFO_DEPTH=4`**（`tb/w3b/tb_note_manager.sv:125`），溢出判据全绿（`sim/evidence/tb_note_manager.log:73-87`）⇒ **只证明了 `FIFO_DEPTH[2:0]==4` 这一种情况**；**交付档 32 从未在仿真里溢出过一次**。
- `SCAN_LAST[SW-1:0]` 若失效则"永远扫不完" ⇒ 整机无声，**板上显然没发生** ⇒ 该构造在 Gowin 里**是能工作的**。⇒ 本条**不是"正在出错"，而是"规则违背 + 交付档零覆盖"**。

**具体怎么改**（1 行 × 2 处，与 `:404-405` 同款）
```verilog
localparam [FW:0]   FIFO_FULL_C = FIFO_DEPTH[FW:0];     // 或 localparam [FW:0] FIFO_FULL_C = FIFO_DEPTH;
localparam [SW-1:0] SCAN_LAST_C = SCAN_LAST[SW-1:0];
wire fifo_full = (fifo_cnt == FIFO_FULL_C);
if (scan_cnt == SCAN_LAST_C) ...
```
**预期收益 / 代价**：**0 LUT / 0 FF**（纯常量定宽）；收益 = 消除 K-91 家族的最后两处，并把"交付档 32 深溢出"变成可测。

**怎么验证能红**：把 `tb_note_manager.sv` 的**主实例**改成 `FIFO_DEPTH=32`（或在 section 10 加第二个 32 深实例），灌 33+ 个事件，断言 `event_lost_o==1` 且 `lost_cnt` 守恒（`served + lost == sent`）；同时读 `syn.log` 确认该行不再出现 `EX3791`/无新告警。

---

### 【P2-2】`best_valid==0` 的丢弃**不可观测** —— 违反本模块自己刚立的 `K-106` 纪律

**位置**：`:1304-1328`（守卫）＋ `:576-582`（FIFO 侧的对照实现）

```verilog
1304:                    //  ✅ **修法**：加 `if (best_valid)` 守卫 ⇒ ⭐ 无候选时**什么都不做**
1305:                    //     （该事件被丢弃，但⛔ 不会污染无关 voice）。
1306:                    if (best_valid) begin
...
1325:                    end else begin
1327:                        cmt_en_r <= 1'b0;
1328:                    end
```
对照：FIFO 丢事件**有** `lost_sticky_r` / `lost_cnt_r`（`:580-582`、`:967-974`），且 `:270` 明写纪律"**任何容量有限的队列都必须有可观测的溢出指示**"。

**为什么是问题**：这是**第二条静默丢事件路径**（丢的是 `note_on` ⇒ 少一个音，用户会以为"键没响应"），而它**没有任何指示**。文件自己在 `:782` 承认"若真排空 ⇒ `best_valid`=0 ⇒ 事件被丢"，`:1300-1303` 还给出可达条件（`POLY_TARGET=4, RESERVED_N=0` 的小实例只需 4 个 voice 同时 `retrig_low`）。

**具体怎么改**：复用现有计数器（**0 新端口**）
```verilog
// ST_COMMIT 的 else 支：
if (!best_valid && !lost_cnt_sat) lost_cnt_r <= lost_cnt_r + 1'b1;
if (!best_valid)                  lost_sticky_r <= 1'b1;
```
**预期收益 / 代价**：+2 LUT（`lost_cnt_sat` 已在 `:582`）；收益 = 把"第二条静默丢音路径"接进已有的 `event_lost_o`（上层 UART/灯带已经在读它）。

**怎么验证能红**：小实例（`POLY_TARGET=4, RESERVED_N=0`）连发 5 个同轴异源 `note_on` 制造"无候选"，断言 `event_lost_o==1`（当前恒 0 ⇒ RED）。

---

### 【P2-3】`age_r` 饱和判据 = **16 输入 NOR 压在 512 个 CE 上**；且 16 位年龄在 **1.342 s** 就饱和，"最老优先"退化成"最低索引优先"

**位置**：`:936-941`

```verilog
937:            if (sample_tick_i) begin
938:                for (i = 0; i < POLY_TARGET; i = i + 1)
939:                    if (live_mask[i] && (age_r[i] != {AGE_W{1'b1}}))
940:                        age_r[i] <= age_r[i] + 1'b1;
```

**为什么是问题（两个独立机制，都有数字）**
1. **CE 路径**：`age_r[i]` 的使能 = `sample_tick_i & live_mask[i] & (age_r[i] != 16'hFFFF)` ⇒ 最后一项是 **16 输入 NOR = 4 级 LUT4**，它压在 **32 voice × 16 位 = 512 个 CE 端点**上；再叠 `sample_tick_i` 自身的扇出（本模块内 ≈ 98 个负载：年龄 32 ＋ 斜坡 32 ＋ `retrig_reset` 清 1 ＋ 重触发环 32）。⇒ **"CE 大面积违例"的同一机制**，只是这次最差路径被 T3 链盖住了。
2. **仲裁退化**：`sample_tick` 周期 = 1024 clk @50 MHz = **20.48 µs**（`:358-359` 自述）⇒ 16 位饱和时间 = `65535 × 20.48 µs = 1.342 s`。**按住任何音超过 1.34 s，所有 voice 的 `age_r` 全 = `0xFFFF`** ⇒ `cand_better` 的 `(cls==2) && (age > best_age)`（`:801`）**恒假** ⇒ 抢占退化成"**最低索引优先**"，**不是"最老优先"**。文件对此**只字未提**。

**具体怎么改**
- 饱和：改成 **1 位 sticky**（`:939` 换成 `if (live_mask[i] && !age_sat[i])`，进位时置 `age_sat[i]`），**去掉 16 输入 NOR** ⇒ **−32×4 ≈ −128 LUT**，512 个 CE 各短 2 级。
- 仲裁：要么把 `AGE_W` 提到 20（`2^20 × 20.48 µs = 21.5 s`，+128 FF），要么在文档/tb 里**明写"1.342 s 之后按索引抢"**（用户大概率听不出来，但这是**行为契约**，不能只存在于我这份报告里）。

**预期收益 / 代价**：−128 LUT、CE 路径 −2 级；代价 = +32 FF（sticky）。**怎么验证能红**：tb 里让 5 个 voice 保持 > 1.342 s（`sample_tick` 加速或直接 force `age_r`），断言抢占对象 == **最早分配**的那个；当前会抢到**索引最小**的那个 ⇒ RED（这就是"判据能红"）。

---

### 【P2-4】FIFO 是 **8 个并行寄存器阵列 + 组合读**（含一个死数组）⇒ 7 个 32:1 宽 mux；文件用 BSRAM 记账是**机制性记错**

**位置**：`:543-553`（声明）＋ `:585-591`（组合读）＋ `:98`（记账）

```verilog
543:    reg                    fifo_v   [0:FIFO_DEPTH-1];
545:    reg [PHASE_W-1:0]      fifo_inc [0:FIFO_DEPTH-1];
585:    wire [AXIS_W-1:0]  head_axis = fifo_ax [fifo_rd];
586:    wire [PHASE_W-1:0] head_inc  = fifo_inc[fifo_rd];
...
 98:    //    ⚠️ 代价极小：每条事件 64 bit ⇒ 多 16×64 = **1024 bit**（60K 总 BSRAM 2124 kb 的 **0.05%**）。
```

**为什么是问题（机制带数字）**
- **`fifo_v` 是死数组**：只在 `:867` 复位、`:946` 写入，**从不被读**（全仓 grep 只有这三处；`fifo_empty` 走 `fifo_cnt`，`:559`）。而 `syn.log:155` 还专门为它 `Extracting RAM for identifier 'fifo_v'`。
- 读是**组合**的 ⇒ **不能映射 BSRAM**（BSRAM 读需同步）⇒ 变成 7 个 32:1 mux：`head_inc` 一项就 ≈ **352 LUT**（32 位 × 5 级 2:1），全组 ≈ **570 LUT**。
- `rsc.xml` 实测 `note_manager: Bsram=2` ⇒ 深度 16→32 的真实代价**不是** 1024 bit/2124 kb = 0.05%，而是"LUT/FF 阵列（或 LUTRAM）＋ 2 个 BSRAM 的粒度分配"。`:98` 的账**差一个数量级以上**（36 Kb / 2124 Kb = 1.7%）。

**具体怎么改**：把队头**寄存一拍**（`head_*_r <= fifo_*[fifo_rd]`，52 FF），`ST_IDLE` 用 `head_*_r`；读地址变寄存器 ⇒ 允许 LUTRAM/BSRAM 推断，且 570 LUT 的 mux 从"地址→锁存"路径上消失。**代价**：+52 FF、事件延迟 +1 拍（36→37，仍在一帧内，见 P1-3 的账）。
**怎么验证能红**：A/B 综合看 `T_Lut`；`syn.log` 里 `fifo_inc` 是否从 `Extracting RAM` 变成 BSRAM 行；`tb_note_manager.sv` 全绿（这条改动**必须**逐用例回归，因为它动了取事件的时序）。

---

### 【P2-5】扫描预译码的**双编码一致性**只靠一个 `syn_preserve` 属性保着（且该属性在日志里无回执）

**位置**：`:711-740`（`scan_cnt` 与 `scan_sel` 两套编码）＋ `:748`（索引取自 `scan_cnt`）

```verilog
714:    (* syn_preserve = 1 *) reg [POLY_TARGET-1:0] scan_sel;
717:    (* syn_keep = 1 *) wire [SCAN_ATTR_W-1:0] scan_group [0:SCAN_GROUPS-1];
726:                    assign leaf[scan_l] = {SCAN_ATTR_W{scan_sel[scan_g*8+scan_l]}} &
727:                        {hold_mask[...], pool_mask[...], free_mask[...], gate_mask[...],
728:                         env_active_r[...], axis_r[...], src_r[...],
729:                         env_level_r[...], age_r[...]};
738:            assign scan_merge[scan_g+1] = scan_merge[scan_g] | scan_group[scan_g];
748:    wire [IDX_W-1:0]   cand_idx   = scan_cnt[IDX_W-1:0];      // ← 索引来自【另一套编码】
```

**为什么是问题（机制带数字）**：候选的**属性值**来自 `scan_sel`（one-hot），而**索引**来自 `scan_cnt`（二进制）——**同一件事的两套编码**。只要 `scan_sel` 不是严格 one-hot（被工具重新编码、被毛刺、被 `syn_preserve` 被忽略），`scan_merge` 的 OR 树会把**两个 voice 的属性按位或**出一个"幽灵候选"，而提交时写的是 `scan_cnt` 那个 voice ⇒ **把 A 的属性写到 B 身上**（例如把 27 号 voice 的 `axis/src/phase` 写进 3 号）。`syn_preserve` 是 **Synopsys 系**属性；`sim/evidence/a3-proper-20261008/syn.log` 对 note_manager 只有 2 条告警（`:163` EX3045、`:164` EX3791），**既没有"属性被忽略"也没有"属性被采纳"的回执** ⇒ **无法从现有证据判定它是否生效**。
（另注：`:738` 是**串行 OR 链**（`scan_merge[g+1]` 依赖 `scan_merge[g]`），而 `:624` 注释写"⛔ 无链式依赖 ⇒ 深度 ~5 级"——注释与代码不符，见 P3-2。）

**具体怎么改（不牺牲已测到的 +6.85%）**：保留结构，**加一致性断言**（仿真期零硬件代价）
```verilog
// synopsys translate_off
always @(posedge clk_i) if (state==ST_SCAN)
    if (scan_sel !== ({{(POLY_TARGET-1){1'b0}},1'b1} << scan_cnt))
        $display("ERROR [note_manager] scan_sel/scan_cnt 失同步：sel=%b cnt=%0d", scan_sel, scan_cnt);
// synopsys translate_on
```
并在 `syn.log` 里显式确认 `syn_preserve`/`syn_keep` 是否被 Gowin 采纳（不采纳就换 `(* keep = 1 *)` 或直接删掉预译码，回到 32:1 mux —— **但 `d449504` 记载预译码带来 clk_sys 50.040→53.425 MHz，所以必须先测再动**）。

**预期收益 / 代价**：0 硬件代价；收益 = 把"一次静默写错 voice"从**板上现象**变成**仿真报错**。**怎么验证能红**：故意把 `scan_sel <= scan_sel << 1` 改成 `<= {scan_sel[30:0], 1'b0}`（丢一位）⇒ 断言必须报错；若断言不报错而功能全绿，说明断言是空的（`C83` 反向验证）。

---

### 【P2-6】`new_timbre` 的兜底读了**活的** `default_timbre_i`，与文件自己给的"不许读活边带"理由冲突

**位置**：`:805-808`

```verilog
805:    // Timbre is stored with the event.  Allocation may start dozens of clocks
806:    // after note_valid_i, so sampling the live sideband here would assign a
807:    // later event's timbre to the wrong voice.
808:    wire [TIMBRE_W-1:0] new_timbre = cur_timbre_valid ? cur_timbre : default_timbre_i;
```

**为什么是问题**：理由（"提交可能晚几十拍，读活边带会张冠李戴"）**完全适用于 `default_timbre_i`**，但兜底支恰恰读的就是它 ⇒ 提交时刻（最长 **36 拍 = 720 ns**，见 P1-3 的表）与事件到达时刻的 `default_timbre_i` 可以不同。窗口 720 ns 对人手不可能，但**串口/自检脚本**可以在同一拍连发 `default_timbre` 切换 ＋ `note_on` ⇒ 得到"事件属于旧音色、却用了新音色"。属**理论窗口**（P3 级严重度），但它是**代码与自己的注释矛盾**，这类"注释对、代码错"在本项目已发生过（`AGENTS.md` §五③）。

**具体怎么改**：把 `default_timbre_i` 也随事件入队（`fifo_dtimbre`，2 位 × 32 = **64 FF**），`:1133` 附近一起锁存。**怎么验证能红**：tb 在 `note_valid` 后第 5 拍改 `default_timbre`，断言该 voice 的 `timbre_of` == 事件当时的默认值（当前会取新值 ⇒ RED）。

---

### 【P2-7】`DRUM_TOM_MAX` 默认值（15 M）≠ 交付值（20 M）⇒ 不显式传参的例化会静默错配

**位置**：`note_manager.v:111` vs `rtl/top.v:3996-3997`

```verilog
111:    parameter integer DRUM_TOM_MAX  = 15_000_000    // ⭐ ≈171 Hz（嗵鼓 / 军鼓 之间）
--- rtl/top.v ---
3996:            .DRUM_KICK_MAX (10_000_000),
3997:            .DRUM_TOM_MAX  (20_000_000),
```
`sim/evidence/a3-proper-20261008/syn.log:151` 实锤编译参数 `DRUM_TOM_MAX=20000000`。`sim/evidence/a3-proper-20261008/README.md:76-81` 已经把这个坑写成"**本修法最容易踩的坑**"，但**代码里没有任何机械保护**：`note_manager` 与 `oscillator_bank` 的默认值不同（15 M vs 20 M），谁少传一处就得到"分类与扫档对不上"的鼓音。

**具体怎么改**：把 `note_manager` 的默认值改成与 `oscillator_bank` **同一个数**，或在 `initial` 自检里断言"两个模块的阈值参数同值"（跨模块做不到就退而求其次：在 `top.v` 里加 `initial if (DRUM_TOM_MAX != 20_000_000) $display("ERROR ...")`）。**收益**：把"文档里的坑"变成"编译/仿真期的错"。**怎么验证能红**：把 `top.v:3997` 改成 `15_000_000`（少传一个值），当前**全绿**；加断言后必须报 ERROR。

---

### 【P2-8】非 2 的幂 `FIFO_DEPTH` / `POLY_TARGET>32` 无保护 ⇒ 指针越界 / 部分 lane 永不刷新

**位置**：`:956`（指针自增）＋ `:543-553`（数组长度）＋ `:1528-1529`（`ROT_LANES`）＋ `:1692-1706`（自检清单）

```verilog
956:                fifo_wr           <= fifo_wr + 1'b1;         // FW = $clog2(FIFO_DEPTH)
407:    localparam integer FW = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
1528:    localparam integer ROT_LANES = (POLY_TARGET > 32) ? 32 : POLY_TARGET;
1575:            if (rot_ok)  phase_tr[rot_cnt] <= ...
```
- **`FIFO_DEPTH=20`**（非 2 的幂）：`FW=5`，指针走 0..31，而数组只有 `[0:19]` ⇒ **写/读到数组外**（仿真得 `x`，综合里高位地址被丢 ⇒ 静默串扰）。自检（`:1700`）只查下界 `FIFO_DEPTH < FIFO_MIN`，**不查"必须是 2 的幂"**。
- **`POLY_TARGET=64`**：`phase_tr` 声明 `[0:63]`（`:1519`），但 `rot_cnt` 只有 5 位（`:1518`）⇒ **lane 32..63 永远不被刷新**（`rot_ok` 只挡"越界写"，挡不住"漏刷"）⇒ 那些 voice 的 `voice_phase_inc_o` 恒 0 ⇒ **永久无声**。自检没有这一条。
**具体怎么改**：自检加两条（编译期常量、零硬件）
```verilog
if ((FIFO_DEPTH & (FIFO_DEPTH-1)) != 0) $display("ERROR [note_manager] FIFO_DEPTH=%0d 必须是 2 的幂（指针按位宽回绕）", FIFO_DEPTH);
if (POLY_TARGET > 32) $display("ERROR [note_manager] POLY_TARGET=%0d > 32 ⇒ phase_tr 只有前 32 lane 被轮转刷新", POLY_TARGET);
```
**怎么验证能红**：用 `-P` 覆盖参数做两次 dry-run 综合/编译，断言两条 ERROR 都出现。

---

## 四、P3 —— 死逻辑 / 注释失真 / 边角

### 【P3-1】死声明与死数组（全仓 grep 实证）

| 位置 | 代码 | 证据 | 说明 |
|---|---|---|---|
| `:285` | `localparam [AXIS_W-1:0] RESERVED_AXIS = RESERVED_AXIS_BASE;` | 全仓只有 `:285` 定义 ＋ `:219`/`oscillator_bank.v:230`/`metronome.v:21` 的**注释**提到 | 2026-10-01"修B"把按轴判池改成按源判池后**遗留** |
| `:283` | `localparam [1:0] KIND_PLUCK = 2'd2;` | `note_manager` 内零引用（`play_mode_ctrl.v:29` 是另一个模块的同名常量） | `cur_kind` 只与 `KIND_OFF` 比（`:1141`）⇒ `pluck` 走 `note_on` 语义，**无人写下这条语义** |
| `:381-383` | `RT_NONE / RT_LOW / RT_HIGH` | 只在 `:489`/`:497`/`:505` 的注释里出现 | 2026-09-28 改成"每 voice 位图"（`:500-507`）后的遗留 |
| `:543` / `:867` / `:946` | `reg fifo_v [0:FIFO_DEPTH-1];` | **无任何读**（读侧走 `fifo_cnt`，`:559`）；`syn.log:155` 还为它抽了 RAM | 32 FF ＋ 写译码；**综合器会裁掉**，但源码上它是"看起来有 valid 位"的假象 |

**怎么改**：删（或把 `fifo_v` 改成"真的有读"的用途）。**收益**：源码可信度（本项目的核心资产是"注释即契约"）。**怎么验证能红**：`grep -n "RESERVED_AXIS\|KIND_PLUCK\|RT_LOW" rtl/w3b/note_manager.v` 应只剩定义处（或全空）。

### 【P3-2】注释 vs 代码（4 处，逐条给出代码）

| 位置 | 注释说 | 代码是 | 影响 |
|---|---|---|---|
| `:695` | "最低索引优先编码（**升序扫** + 只在未命中时赋值）" | `for (qi = POLY_TARGET-1; qi >= 0; qi = qi-1) if (same_hit[qi]) same_idx = qi;`（`:700-701`，**降序 + 无条件覆盖**） | 结果**正确**（最后写入者=最低索引），但**推理链是反的**；下一个人照注释改就会改错 |
| `:624` | "同轴位重触发检测（**组合 OR 树**，⛔ 无链式依赖 ⇒ 深度 ~5 级）" | `:738` `scan_merge[scan_g+1] = scan_merge[scan_g] \| scan_group[scan_g];` = **4 级串行 ripple** | 深度被低估；且"无链式依赖"是**错的** |
| `:99` | "32×35 = 1120 拍 = 22.4 µs **仍在一帧内**" | 每事件 **36** 拍；1120 **>** 1024 | 见 P1-3 |
| `:20` / `:31` | 分配延迟"≤ **34 拍**" | 36 拍（`ST_COMMIT2`/`ST_RETRIG` 两次加级后未更新） | 契约数字失真（对外冻结表写的就是 34） |

**怎么改**：四处按代码改写；并把"延迟契约"改成 **36 拍**（或实测值）。**怎么验证能红**：写一条 tb 计时用例，实测 `note_valid` → `alloc_valid_o` 的拍数（当前 36），断言 ≤ 36；注释里的数字由脚本核对。

### 【P3-3】恒真/恒假的守卫与分支（不可达代码）

| 位置 | 代码 | 为什么恒真/恒假 |
|---|---|---|
| `:1237` | `if (same_en_r) begin` | `ST_RETRIG` **只能**从 `:1216` 进入，而那里无条件 `same_en_r <= 1'b1` ⇒ 读到它时**必为 1**；`:1222` 的 `same_en_r <= 1'b0` 只在开扫支（另一条路）⇒ **`if` 的 else 支不可达**（`same_en_r` 这个 FF 事实上是死状态） |
| `:1529` | `wire rot_ok = (rot_cnt < ROT_LANES);` | `ROT_LANES` 是 `integer 32`，`rot_cnt` 5 位零扩展后**恒 < 32** ⇒ 交付档（`POLY_TARGET=32`）**恒为 1**（工具会折叠）；只在 `POLY_TARGET<32` 时才有意义 |
| `:609` | `if (RESERVED_N == 0) assign pool_mask[pg] = 1'b1;` | 交付档 `RESERVED_N=5` ⇒ 走 else；该分支只在 tb 用 |
| `:874` / `:1220` | `{{(POLY_TARGET-1){1'b0}}, 1'b1}` | `POLY_TARGET=1` ⇒ **零宽复制**（非法/无意义）；`POLY_TARGET=1` 的实例没有 tb |

**怎么改**：`same_en_r` 直接删（把 `ST_RETRIG` 的写从 `if` 里拿出来）；`rot_ok` 加注释"仅小实例有效"；零宽复制改成 `{{POLY_TARGET{1'b0}}} \| 1'b1` 形式。**收益**：−1 FF、少一层嵌套；**怎么验证能红**：删 `if (same_en_r)` 后 `tb_note_manager` 必须逐条不变（若变了说明 `same_en_r` 不是恒真，我的判断就被证伪）。

### 【P3-4】"诊断输出"在顶层**无人读**（3 路，共 672 bit）

| 输出 | 顶层连接 | 证据 |
|---|---|---|
| `voice_releasing_o`（32 bit，`:1672`） | `rtl/top.v:4128` `.voice_releasing_o (),` **空连接** | 直接删掉 |
| `voice_axis_o`（32×4=128 bit，`:1638`） | `rtl/top.v:4129` → `nm_axis`；而 `nm_axis` 在 `top.v` 里只有 `:1295` 声明 ＋ `:4129` 这一处（**零消费者**） | grep 计数 = 2 |
| `voice_age_o`（32×16=512 bit，`:1661`） | `rtl/top.v:4137` → `nm_age`；同样只有 `:1313` 声明 ＋ `:4137`（**零消费者**） | grep 计数 = 2 |

⇒ 工具会把它们整段裁掉（**所以不是资源问题**），但**出事时手里没有任何诊断信号**：抢占对象、年龄、释放态这三个"最难查的现场"全都接不出来。**怎么改**：接进 `waveform_scope`/UART 遥测，或显式删除并在注释里写"本设计不提供该诊断"。**怎么验证能红**：`top.v` 里 `nm_axis`/`nm_age` 若被任何逻辑读走，grep 计数必须 > 2。

### 【P3-5】复位/初始化核查（结论：**基本完整**，缺口无害，逐条列出）

- ✅ 已复位：全部 per-voice（`gate_r/axis_r/src_r/phase_r/vel_r/timbre_r/age_r/vtgt_rep`，`:849-859`）、`vtgt_val/vtgt_vld`（`:863-866`）、`fifo_v`（`:867`）、`fifo_wr/rd/cnt`（`:868-870`）、`retrig_low`、`state`、`scan_cnt/scan_sel`、`best_*`、`cur_*`、`cmt_*`、`same_*`、`retrig_reset_r`、`sus_hold_r`、`drum_cls_r`、`lost_*`（`:871-905`）、`env_level_r/env_active_r`（`:371-373`）、`base_oct_r`（`:429`）、T3 的 `semi_cur/semi_tgt/port_cnt/rot_cnt/phase_tr`（`:1551-1557`）。
- ⚠️ **未复位**：`fifo_ax/inc/vel/knd/timbre_valid/timbre/src`（`:544-553`）。**无害**，因为读侧只在 `!fifo_empty` 时锁存（`:1127`），而 `fifo_empty` 由已复位的 `fifo_cnt` 导出（`:559`）⇒ **X 不会传播**。建议在注释里写清这条推理（现在只有 `fifo_v` 被复位，反而误导读者以为"数据数组都复位了"）。
- ✅ **无推断 latch**：全文件唯一 `always @(*)`（`:698-702`）有默认赋值 `same_idx = 0`；`sim.log` 对 note_manager **没有任何 latch 告警**（`:163-164` 只有 EX3045/EX3791）。这是**已验证的阴性结论**，可以直接写进交付说明。
- ✅ **无 CDC**：全部输入同属 `clk_sys`；`sus_pedal_i`/`timbre` 由顶层 `u_pedal_sus_sync`/`u_timbre_btn_sync` 同步（`rsc.xml` 可见），`transpose_semi_i` 来自同域寄存器 `u_fader_gear.transpose_semi_o`（`top.v:1786` → `:4059`）。
- ⚠️ **Z 悬空的语义**：`:308-327`（`vu_src_w/pu_src_w/ns_src_w`）、`:913`、`:1166`、`:1497` 用 `===`/`!==` 做 Z-safe 解码。**综合日志给出了它们的真实命运**：`syn.log:163` `WARN (EX3045) : Case inequality operator always evaluates to true due to comparison with 'x' or 'z'`（`:1497`）⇒ **`trans_known` 在硬件里恒 1**（合成里没有 `x`）。⇒ 这些"Z-safe"是**纯仿真兼容层**，对硬件语义零影响（这是对的，但必须写清楚，否则会被误当成鲁棒性机制）。

---

## 五、四条重点任务的逐条结算

| # | 任务 | 结算 | 证据 |
|---|---|---|---|
| ① | **提交/重触发两条写路径的 32 路写译码扇出（历史 4500 端点）** | ✅ **已真正治好，且是结构性的**。`ST_COMMIT2`（`:1352`）与 `ST_RETRIG`（`:1236`）把"选谁(组合)"与"写谁(寄存)"分开 ⇒ 2026-10-02 那条 `fifo_ax → same_idx → same_valid → scan_cnt` 的写译码链**已从最差路径表消失**（对比 §P1-1 的表）。⚠️ **残留风险**：`cmt_idx_r`/`same_idx_r` 各 5 位要驱动 `8 个数组 × 32 = 256` 个译码 LUT（每 bit 扇出 ≈256），以及 `cur_axis`/`cur_src` 7 根线扇出 ≈130（`pool_mask`/`same_hit`/`note_off` 三处各 32 个比较器）。**可共享**：`axis_r[i]==cur_axis && src_r[i]==cur_src` 在 `:689-690` 与 `:1155-1156` 各算一遍 ⇒ 合成一个 `cur_match[i]` 可省 ≈64 LUT（P3 级）。 |
| ② | **`phase_tr` 轮转的共享乘法器链** | 🔴 **全设计第 1 关键路径（+0.102 ns）**，结构性的（见 P1-1）。 |
| ③ | **FSM 各状态的未覆盖组合** | 8 个编码用 6 个，`:1392` 有 `default` ⇒ **非法状态不会卡死**（但会静默丢一个在途事件）。**真正未覆盖的"组合"**是：(a) `ST_COMMIT` + `best_valid==0`（丢弃不可观测，P2-2）；(b) `ST_RETRIG` + `same_en_r==0`（**不可达**，P3-3）；(c) `ST_SCAN` + `scan_sel` 非 one-hot（无断言，P2-5）；(d) `ST_COMMIT2` + `cmt_en_r==0`（= (a) 的镜像）。 |
| ④ | **`best_idx` 32 路优先编码器的组合深度** | ✅ **T66 之后 `best_idx` 不是优先编码器**：它是**每拍只比 1 个 voice** 的寄存器（`:1274-1280`），深度 = 预译码（1 级 AND + 2 级 8:1 OR + 3 级 ripple OR ≈6 级）＋ 16 位比较 ≈4 级 ⇒ **≈10 级**，且**终点是 `best_*` 寄存器**（不是写译码器）⇒ 不跨周期。**真正剩下的 32 路优先编码器只有 `same_idx`**（`:698-702`），它现在也**先落寄存器**（`:1213`）再驱动写译码（`:1239-1267`）。⇒ 两条"编码器→写译码"的长链**都已被流水级切断**。 |

---

## 六、结构性 vs 布局运气 —— 判定规则与逐条结论

**判据（本报告统一使用）**：一条路径/一处违例若**换构建后仍复现**（同一模块、同一"当前最长链"）⇒ **结构性**；若只在单次构建出现且与资源/结构变化无关 ⇒ **布局运气**。

| 结论 | 判定 | 依据 |
|---|---|---|
| T3 轮转-共享乘法器链 | **结构性** | 4 次构建里 3 次最差路径在本模块；本次的链是"32:1 mux（5 级）＋移位＋DSP（2.53 ns）＋末段布线（5.41 ns）"串成一条，与布局无关 |
| 4500 端点写译码违例 | **结构性，已修** | `ST_COMMIT2`/`ST_RETRIG` 是 RTL 级改动，与布局无关；且违例链已从最差路径表消失 |
| `vtgt_val[axis_r[i]]` 的 32 读端口 | **结构性** | 由"循环体内查表"这一写法决定，与布局无关（成本随 voice 数线性放大） |
| `vel_r` 回绕 | **结构性（功能）** | 由 8 位截断决定，与工艺/布局无关 |
| `note_manager` 占 35.4% LUT | **结构性** | `rsc.xml` 实测，跨两次构建一致（9618 / 27271 总量下的同量级） |
| 55.06 → 57.0 MHz 的档间差 | **布局＋DSP 数变化** | `=1` 档多 3 个 DSP（`T_MULTALU27X18 7→10`，right-board README:136）、CLS 78%→81%；**同源重跑差 2~3 MHz** ⇒ 引用任何单次 Fmax 必须带"同源重跑区间" |

---

## 七、修复优先级建议（按"收益/风险/代价"排序）

| 序 | 项 | 严重度 | 代价 | 风险 |
|---|---|---|---|---|
| 1 | P0-1 力度回绕（9 位比较） | 🔴 可听功能缺陷 | +64~128 LUT | **极低**（2 行） |
| 2 | P1-3 FIFO 排空自检 ＋ 注释纠错 | 🟠 契约失真 | 0 | **极低** |
| 3 | P1-4 `T3_EN`/`T_Lut` 契约纠正 | 🟠 决策依据 | 0 | **极低** |
| 4 | P2-1 `*_C` 定宽常量 ×2 | 🟠 规则违背 | 0 | **极低** |
| 5 | P2-2 丢弃可观测化 | 🟠 可观测性 | +2 LUT | **极低** |
| 6 | P1-5 重触发刷新 `drum_cls_r` | 🟠 不变量 | +4~8 LUT | 低 |
| 7 | P2-3 年龄 sticky ＋ 文档化 1.342 s | 🟡 资源/契约 | −128 LUT +32 FF | 低 |
| 8 | P1-2 每轴表移到提交/更新路径 | 🟠 资源（−256~−1400 LUT） | 改 ~30 行 | **中**（需新 tb 钉自愈性） |
| 9 | P1-1 T3 链流水（**必须与 `tdm_render_mixer` 同批**） | 🔴 时序 | +41 FF，刷新 32→64 拍 | **中**（`tb_transpose` 的 `T1_SETTLE`） |
| 10 | P2-4 FIFO 同步读 / P2-5 一致性断言 | 🟡 资源/可验证性 | +52 FF / 0 | 中 / 极低 |

---

## 八、证据索引（本报告引用的全部外部事实）

| 文件 | 用途 |
|---|---|
| `impl/pnr/Gowin2026.timing_paths`（10-09 01:13） | 全设计最差路径逐节点到达时间（P1-1、§六） |
| `sim/evidence/a3-proper-20261008/{syn.log,rsc.xml,pnr-rpt.txt,README.md}` | note_manager 编译参数、逐模块资源、四道门、Fmax 55.313 |
| `sim/evidence/final-batch-20261008/{README.md,syn.log}` | 对照批次资源 27271、CLS 78% |
| `sim/evidence/rightboard-vibrato-fix-20261008/README.md` | `=1` 档 1630 违例 → 0、CLS 81%、DSP 7→10、Fmax 公式 |
| `constr/top.sdc:18,101` | `create_clock 20 ns` 与 `set_max_delay 18.181` |
| `sim/evidence/{p4-rot32,p5-adsr,evt_merge-narrow}-2026*/…timing_paths` | 跨构建最差路径复现性（结构性判据） |
| `tb/w3b/tb_note_manager_vel_ramp.sv:28,35,70-71` | 黄金模型复刻 bug（假绿证据） |
| `tb/w3b/tb_note_manager.sv:125,591` | 覆盖缺口（`FIFO_DEPTH=4`、力度最大 240） |
| `rtl/w3a/param_extract.v:96,189` | 力度上限 255（可达性） |
| `rtl/top.v:329,3996-3997,4015,4059,4128-4129,4137` | 交付档参数、空连接、零消费者 |
| `tb/models/oscillator_bank_ref.v` / `tb/w3b/tb_p5_osc_equiv.sv:15-17` | 基线副本坑（§0.9） |
| `files/20-代码/evt_merge设计说明.md:90-92` | `K-91` `integer` 位选的实测事故 |
| `AGENTS.md` §四/§五 | 通过判据、布局噪声、"证据基础没核对" |

---

> **一句话总结**：本模块**结构上是干净的**（无 latch、无 CDC、写译码长链已被两级流水切断、`K-106` 溢出可观测性真的落地了），但它**吃掉全设计 35.4% 的 LUT**，并且**全设计最紧的一条路径（+0.102 ns）就在它的 T3 轮转-共享乘法器链上**；同时它藏着**一个可达、可听、且被自己的 tb 复刻成假绿的功能缺陷（力度 8 位回绕）**。先修 P0-1 与三处零代价契约（P1-3/P1-4/P2-1），再动 P1-2/P1-1 这两处结构性大头。
