# ANVIL-02 · 音频核心（振荡器组）深度抠查

> 范围：`rtl/w3b/oscillator_bank.v` · `rtl/w3b/vibrato_lfo.v` · `rtl/w3b/voice.v` ·
> `rtl/w3b/voice_i2s_chain.v` · `rtl/w3b/test_mode_ctrl.v`
> 战场事实：GW5AT-60B · AC1/I0 慢档 · `clk_sys` = 50 MHz · `set_max_delay 18.181 ns`（≈55 MHz）
> 门槛：0 setup / 0 hold，Fmax ≥ 51.5 MHz
> 本报告引用的当前交付 PnR 实测（`impl/pnr/Gowin2026.rpt.txt` / `Gowin2026.timing_paths` / `sim/evidence/gowin_m0_timing.txt`）：
> - Setup 违例 **0** · Hold **0** · `Actual Fmax 55.313 MHz` · `Logic Level 7`
> - 最差 setup 路径 slack **+0.102 ns**（`note_manager/g_t3.rot_cnt_0_s0 → g_t3.phase_tr[28]_24_s0`），即 **余量 0.56%**
> - 资源：`Logic 34507/59904 (58%)`（`LUT 27135` · `ALU 7372`）· `Register 17039/60780 (29%)` · `CLS 23303/29952 (78%)` · `DSP 22/118` · `BSRAM 33/118`
> - `impl/pnr/Gowin2026.timing_paths` 的 25 条 setup 最差路径里 **`oscillator_bank` 出现 0 次、`vibrato_lfo` 出现 0 次**（已 grep 三个 tr html，同为 0 次）
>
> ⚠️ 由此定下本报告的口径：**凡结论涉及"是不是关键路径"，一律标注"当前被布局掩盖（已 grep 证实不在 Top-25）"，并给出可复现的测量判据；不把布局运气当结构。**

---

## 汇总

| 优先级 | 条数 | 条目 |
|---|---|---|
| **P0** | 4 | ① 颤音深度无音域约束 ⇒ 低音相位增量翻负 ② `rate_target_q` 死寄存器 + 未寄存目标落在反馈环 ③ 手写 16 级 ripple-carry 取负喂乘法器 ④ `DRUM_CLS_EXT=1` 只清零分类窗口、**扫频深度窗口仍在** |
| **P1** | 6 | ⑤ test_mode 退出沿 RTL/参考副本分歧（判据盲区）⑥ 扫频自检只守 KICK 不守 TOM ⑦ T10 链 `JUSTIFY=1` 与新板 `JUSTIFY=0` 冲突 ⑧ `LANES ≤ 1024` 自检量错 ⑨ 相位增量通路 3~4 级串联加法器（⛔ 不可流水线）⑩ 同文件内注释自相矛盾（`rom_hard` vs `rom_soft`） |
| **P2** | 10 | ⑪`so_v` 溢出无自检 ⑫奇数 lane test-mode mux 白付 LUT ⑬6 位截断静默全关 ⑭`test_mode_ctrl` 零自检 ⑮`integer` 计数器 ⑯死参数 `CLK_PER_SAMPLE` ⑰名义 24 位实际 16 位 ⑱整数参数位选 ⑲生产档无逐位等价覆盖 ⑳两模块在 gprj 但不在网表 |
| **P3** | 8 | ㉑`integer` 参数位选违反自订纪律 ㉒未读输入 + 未用变量 ㉓`DBG_LANE` 无范围自检 ㉔`test_mode_ctrl` 组合直通 ㉕`mclk_en`/`lrclk` 悬空 ㉖depth 无 slew ㉗`PHASE_QUARTER` 负重复次数 ㉘`sample_bus_r` 变址写入可用移位寄存器省译码器 |

**合计 28 条。**

---

# P0-1 · 颤音深度没有音域约束 ⇒ 低音在 LFO 峰值处**相位增量翻负**，音高跳 +3.27 个八度

### 位置与代码

`rtl/w3b/vibrato_lfo.v:43`（深度定标，**无任何上限**）

```verilog
43:     wire [15:0] depth_target_w = {depth_raw_i, 3'b000}; // 12-bit -> Q1.15
```

`rtl/w3b/vibrato_lfo.v:92-102`（死区门限：`DEPTH_OFF=64` / `DEPTH_ON=96`，即 **2.3% 行程**就打开）

```verilog
 92:                 if (depth_active_r) begin
 93:                     if (depth_raw_i <= DEPTH_OFF) begin
 94:                         depth_active_r <= 1'b0;
 95:                         depth_q        <= 16'd0;
 96:                     end else begin
 97:                         depth_q <= depth_target_w;
 98:                     end
 99:                 end else if (depth_raw_i >= DEPTH_ON) begin
100:                     depth_active_r <= 1'b1;
101:                     depth_q        <= depth_target_w;
102:                 end
```

`rtl/w3b/vibrato_lfo.v:128`（全量程输出）

```verilog
128:     assign mod_o            = depth_active_r ? mod_w : 16'sd0;
```

`rtl/w3b/oscillator_bank.v:299-304` + `:333`（注释已承认这是**绝对偏移**）+ `:469`

```verilog
333:     wire signed [PHASE_W-1:0] vib_off = vib_mul_r >>> 15;
...
469:             assign inc_main_w[vg*PHASE_W +: PHASE_W] = bv + vib_off[PHASE_W-1:0] + so_v;
```

`rtl/w3a/right_analog_ctrl.v:112`（深度**原样**取 ADC 12 位，没有缩放）

```verilog
112:                     vibrato_depth_o <= sample_data_i;
```

`rtl/top.v:1775-1789`：`fader_gear` 在**档 1（上电默认）**把 `ch2_i` 原样透传到 `vibrato_depth_o` ⇒ **推子行程 = `depth_raw_i` 0..4095 全量程可达**。

### 机制（带数字，全程可复算）

| 步 | 量 | 值 |
|---|---|---|
| 1 | `depth_q` 峰值 | `depth_raw × 8` ⇒ 4095 → **32760** |
| 2 | `triangle_q` 峰值 | ±32767（Q1.15） |
| 3 | `mod_w = mod_product[30:15]` 峰值 | `32767 × 32760 / 32768` = **32759** |
| 4 | `vib_mul_r = mod × VIB_REF_INC`（38 700 000） | 峰值 **1.2677e12** |
| 5 | `vib_off = vib_mul_r >>> 15` 峰值 | **38 689 000** |
| 6 | ⇒ 归纳 | **`vib_off_peak = 9448.2 × depth_raw_i`** |
| 7 | A4 的 `bv` | `440 × 2^32 / 48828.125` = **38 702 840** |

**⇒ 满深度（`depth_raw = 4095`）时 `vib_off_peak = 38.69 M ≈ bv(A4)` ⇒ 颤音摆幅 = ±100% 频率。**

`inc_main_w = bv + vib_off`（mod 2³²）在 `vib_off < −bv` 时**翻成负数**。逐音列出的翻负门限：

| 音 | f | `bv = f × 87 961` | 翻负所需 `depth_raw ≥ bv / 9448` | 占满行程 |
|---|---|---|---|---|
| 低 B（5 弦） | 30.87 Hz | 2 715 000 | **287** | **7.0%** |
| E1 | 41.20 Hz | 3 624 000 | **384** | **9.4%** |
| E2 | 82.41 Hz | 7 249 000 | **767** | **18.7%** |
| A2 | 110.0 Hz | 9 676 000 | **1024** | **25.0%** |
| A4 | 440.0 Hz | 38 702 840 | 4096 | 100%（刚好不到） |

**后果的具体数值**（E1 + `depth_raw = 4095`）：
`inc = 3 624 000 − 38 689 000 = −35 065 000` ⇒ 相位累加器**倒着走**，等效 `|f| = 35 065 000 / 87 961 = 398.7 Hz`。
⇒ 41.2 Hz 的音在三角波负半周（**LFO 周期的一半**）变成 **398.7 Hz 倒放** ⇒ **音高跳 +3.27 个八度**，不是"噪声"，是**明确的错音**。

### 这是 bug 还是"已知口径"

`oscillator_bank.v:296-304` 的注释承认"这是**共享的绝对偏移**（⛔ 不是每 lane 按各自基频比例）"，并把它记成 `K-95`。
但 2026-09-28 的那次修复（见 `tb/models/oscillator_bank_ref.v:371-391`）只修掉了**"混合符号求值导致 `vib_off` 符号位被当幅值"**这一个 Verilog 求值规则坑；**"绝对偏移 > 基频增量"这个物理问题从来没有被处理过**。
⇒ 口径缺口：`K-95` 记的是"按不按比例"，**没记"绝对偏移能超过基频"**。

### 具体怎么改

**（A）立即止血（零风险，16 个 LUT，不动任何已验证行为之外的东西）**：在 `vibrato_lfo.v` 里给深度加一个"音乐上合理"的上限。取 **±50 cents @ A4**（50 cents = `2^(50/1200) − 1` = **2.93%** ⇒ `vib_off ≤ 0.0293 × 38.7 M = 1.134 M` ⇒ `depth_q ≤ 960` ⇒ `depth_raw ≤ 120`）：

```verilog
// 在 depth_target_w 之前插入
localparam [11:0] DEPTH_MAX_RAW = 12'd120;   // ±50 cents @ A4（= 2.93%）
wire [11:0] depth_eff = (depth_raw_i > DEPTH_MAX_RAW) ? DEPTH_MAX_RAW : depth_raw_i;
wire [15:0] depth_target_w = {depth_eff, 3'b000};
```

验证上限足够：最低可听音 20 Hz ⇒ `bv = 1 759 220` > 1 134 000 ✅ 永不翻负。

**（B）结构修法（把绝对偏移改成比例偏移，即真正关掉 `K-95`）**：**不需要 32 个乘法器**。
一帧有 **1024** 个 clk，TDM 只吃掉 **LANES+2 = 66** 拍 ⇒ 还剩 **958 拍**。用**一个共享乘法器 + 32 拍轮转**算 `vib_off[voice] = (bv[voice] >>> 15) × vibrato_mod`：

| 项 | 值 |
|---|---|
| 共享乘法器 | **1 个 DSP**（32 位 × 16 位 ⇒ 48 位；当前 `DSP 22/118`，够） |
| 轮转寄存器 | **32 × 32 = 1024 FF**（当前 `Register 17039/60780` ⇒ +6%，利用率 29% → 31%） |
| 轮转拍数 | **32 拍**（占一帧 1024 拍的 **3.1%**，且与现有 66 拍 TDM **完全并行、不冲突**） |
| 代价 | 新增一条 32 拍状态机；`vib_off` 从"1 根共享网"变成"32 根每 voice 网" |
| 收益 | ① 低音不再翻负（任何深度）② 颤音的 cents 深度**与音高无关**（这才是颤音的定义） |

⚠️ **（B）的副作用必须先算清**：`vib_off` 从共享变 per-voice ⇒ `inc_main_w` 的加法器输入从 1 根扇出 32 变成 32 根独立 ⇒ **P1-9 的扇出问题反而缓解**；但 1024 个 FF 会给 `CLS 78%` 的布线压力加码。

### 预期收益 / 代价

| | (A) | (B) |
|---|---|---|
| 收益 | 消灭"错音"级缺陷 | 同上 + 颤音深度与音高解耦 |
| 代价 | 16 LUT（1 个 12 位比较 + 1 个 12 位 2:1 mux） | 1 DSP + 1024 FF + 32 拍状态机 |
| 对 Fmax | 可忽略 | ⚠️ 需实测（当前最差余量只有 **+0.102 ns**） |

### 怎么验证能红

**（1）先把缺陷钉成一条能红的判据（新 tb，例化 `oscillator_bank`，`DRUM_PITCH_ENV_EN=0`）**：

```
激励：voice_active=1，base_inc[0]=32'd3_624_000（E1），voice_drum=0，DETUNE_ON=0
      vibrato_mod_i 手动扫过 −32768 … +32767（每拍一个值，共 32 拍）
断言（每条都必须能红）：
  A1  inc_main_w[31] 恒为 0        ← 现在在 vibrato_mod_i ≤ −3_624_000 时是 1
  A2  phase_q 单调不减（voice_active 期间）
  A3  |phase_q 每拍增量 − 3_624_000| ≤ 1_134_000（即 ±50 cents 上限）
```
反证（**必须做的反向验证**）：把 `depth_eff` 那两行注释掉重跑 ⇒ **A1/A2/A3 三条必须 FAIL**。三条全绿就是**空判据**（`C83` 探针假绿）。

**（2）跑一次现有回归确认没踩契约**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter vibrato
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter p5_osc_equiv
```

⚠️ `tb_vibrato_lfo.sv:63-96` 用的 `depth_raw` 最大是 `12'hFFF`，但 `RATE_MIN_INC/RATE_MAX_INC` 被改成 100/200 且 `fast_dut` 的 `RATE_*` = `32'h4000_0000`；它**只查 `mod` 的符号与过零**，不查幅度 ⇒ **改 `depth_target_w` 不会打红它**。所以 **(1) 的新 tb 是必须的，不能靠现有 tb**。

**（3）改 (B) 时**：`tb_p5_osc_equiv` 必须仍然 PASS（它比全部 64 个 `phase_q` 逐位）——⚠️ 但 (B) 会把 `vib_off` 变成 per-voice 的**轮转值**，与参考副本的"共享即时值"**不再逐位相同** ⇒ **参考副本必须同步改**，否则是**假红**。这一点必须先想清楚再动手（见 P1-5 的同族教训）。

---

# P0-2 · `rate_target_q` 是**死寄存器**；未寄存的 `rate_target_w`（44 位常量乘法云）直接落在 `rate_inc_q` 的反馈环里

### 位置与代码

`rtl/w3b/vibrato_lfo.v:38-42`（44 位乘法）

```verilog
38:     wire [31:0] rate_span = RATE_MAX_INC - RATE_MIN_INC;
39:     wire [43:0] rate_product = {32'd0, rate_raw_i} * {12'd0, rate_span};
40:     wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
41:                               ? RATE_MAX_INC
42:                               : RATE_MIN_INC + rate_product[43:12];
```

`rtl/w3b/vibrato_lfo.v:48`（声明）/ `:83`（复位）/ `:104`（赋值）—— **全文件没有第 4 处引用**（已 grep 全文，仅 48/83/104 三处）

```verilog
 48:     reg [31:0]       rate_target_q;
 83:             rate_target_q  <= RATE_MIN_INC;
104:                 rate_target_q <= rate_target_w;
```

`rtl/w3b/vibrato_lfo.v:108-123`（**用的是 `rate_target_w`，不是 `rate_target_q`**）

```verilog
108:                 if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
109:                     slew_count_q <= 0;
110:                     if (rate_inc_q < rate_target_w) begin
111:                         if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
112:                             rate_inc_q <= rate_inc_q + RATE_SLEW_STEP;
113:                         else
114:                             rate_inc_q <= rate_target_w;
115:                     end else if (rate_inc_q > rate_target_w) begin
116:                         if ((rate_inc_q - rate_target_w) > RATE_SLEW_STEP)
117:                             rate_inc_q <= rate_inc_q - RATE_SLEW_STEP;
118:                         else
119:                             rate_inc_q <= rate_target_w;
120:                     end
121:                 end else begin
122:                     slew_count_q <= slew_count_q + 1;
123:                 end
```

### 机制

**(a) 死寄存器（确定性事实，不需要实测）**：`rate_target_q` 花掉 **32 个 FF**，**一个负载都没有**。它的存在说明作者**本来打算**把 `rate_target_w` 打一拍再用于 slew —— 那一拍正好能把乘法云从 `rate_inc_q` 的反馈环里切出去。**这一刀没接上。**

**(b) 结构路径（宽度部分需要实测确认，见下）**：
`rate_raw_i`（`vibrato_lfo` 输入端口，来自 `top.v:1788 .vibrato_rate_o(vib_rate_sel)`）→
`{32'd0, rate_raw_i} * 945`（**44 位宽**；945 = `RATE_MAX_INC − RATE_MIN_INC` = 1031 − 86）→
`rate_product[43:12]` →
`RATE_MIN_INC + …`（32 位加）→
**32 位比较 `rate_inc_q < rate_target_w`** →
**32 位加/减 ±16** →
`rate_inc_q` /D

**宽度事实**：`rate_raw_i` 只有 12 个有效位，`rate_span = 945` 只有 10 位，真实积上限 = `4095 × 945 = 3 869 775` = **22 位**（`2^22 = 4 194 304`）。声明的 **44 位**里有 **22 位是纯零填充**。945 = `0b11_1011_0001` ⇒ **6 个非零部分积** ⇒ 每一级加法树的位宽都被声明成 44 位。

**⚠️ 诚实的边界**：Gowin 的常量乘法优化**有可能**把 `{32'd0, rate_raw_i}` 收窄回 12 位（那么 44 位只是名义宽度，无实际代价）。**这一点必须用综合报告确认，不能假设。** 但无论收窄与否，**（a）的死寄存器是确定的**。

### 具体怎么改

**改法一（确定收益，零行为风险）：把宽度收窄到真实需要的 22 位。** 这与现写法**逐位等价**（证明：44 位积 = 22 位积零扩展 ⇒ `rate_product[43:12]` = `product[21:12]` 零扩展）：

```verilog
localparam [21:0] RATE_SPAN22 = 22'd945;                  // = RATE_MAX_INC - RATE_MIN_INC
wire [21:0] rate_product = rate_raw_i * RATE_SPAN22;       // 12×10 -> 22 位，够
wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
                          ? RATE_MAX_INC
                          : RATE_MIN_INC + rate_product[21:12];
```

**改法二（把死寄存器接上，即完成作者本来的意图）：把 `110/111/115/116` 的 `rate_target_w` 换成 `rate_target_q`。**

⚠️ **改法二会改行为，且会打红 `tb_vibrato_lfo`**，必须先算清：
`tb_vibrato_lfo.sv:76-80` 用 `CTRL_SLEW_DIV=1`（⇒ `slew_count_q >= 0` 恒真 ⇒ 每次 commit 都 slew）、`RATE_MIN_INC=100`、`RATE_MAX_INC=200`、`RATE_SLEW_STEP=10`，然后断言：

```verilog
 76:        rate_raw = 12'hFFF;
 78:        commit; chk("rate slew first step is bounded", rate_inc == 32'd110);
 79:        commit; chk("rate slew second step is bounded", rate_inc == 32'd120);
 80:        commit; chk("rate slew converges without a jump", rate_inc == 32'd130);
```

用 `rate_target_q` 后，**第 1 次 commit 时 `rate_target_q` 还是旧目标（100）** ⇒ `rate_inc_q` 不动 ⇒ `rate_inc == 100` ⇒ **78/79/80 三条全红**（随后 110/120/130 依次后移一拍）。
⇒ 要么**同时把 78/79/80 的期望值改成 100/110/120 并把 `commit` 补一次**（**契约变更，必须显式记录**），要么**只做改法一**。

**推荐顺序**：先做**改法一**（零风险）＋ **删掉死寄存器**（省 32 FF），把"要不要接这一拍"当成**独立决策**、带自己的契约变更走。

### 预期收益 / 代价

| 项 | 收益 | 代价 |
|---|---|---|
| 改法一 | 6 级加法树的**位宽从 44 → 22**，每级进位链减半（ALU 估算：`6 × 44/2 = 132` → `6 × 22/2 = 66` ALU，**省 66 ALU**，占 PnR 总 `ALU 7372` 的 0.9%）；深度不变 | **0**（逐位等价） |
| 删死寄存器 | **省 32 FF**（`Register 17039` → 17007，0.19%） | **0** |
| 改法二 | 把整个乘法云 + 第一级加法移出反馈环 | **行为变更 + 打红 3 条既有断言**；颤音速率变化滞后 1 次 commit（**0.5 ms**，听感不可闻） |

### 怎么验证能红

**（1）改法一的等价性判据（必须做）**：临时把 `rate_product[21:12]` 写成 `rate_product[20:11]`（差 1 位）⇒ `tb_vibrato_lfo` 的 **78/79/80 必须变红**。若不变红，说明该 tb 对 rate 的**数值**没有约束（只对**步长**有约束），需要补一条精确值断言。

**（2）44 位是否真有代价 —— 综合报告判据**：

```powershell
# 改前 / 改后各跑一次综合，对比 u_vibrato_lfo 的 DSP/ALU 归属
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT|ALU|DSP|Register'
```
判据：`ALU` 下降 **≈66** ⇒ 44 位宽度确实白付了；`ALU` 不变 ⇒ 工具已自动收窄，改法一只是"防工具不优化"，收益为零（**也要如实记录**）。

**（3）"是不是关键路径"的判据（把布局运气与结构分开）**：在**只读探针副本**里加一条定向约束，把这条路径逼成最差路径：

```tcl
# 探针 SDC（⛔ 不碰 constr/top.sdc）
set_max_delay -from [get_pins {g_sound.u_vibrato_lfo/rate_target_q_*_s0/Q}] \
              -to   [get_pins {g_sound.u_vibrato_lfo/rate_inc_q_*_s0/D}] 5.000
```
然后读 `impl/pnr/Gowin2026_tr_content.html` 的 **Logic Level** 与该路径的 `Data Delay`。
- 若改前 `Data Delay > 8 ns` 或 `Logic Level ≥ 12` ⇒ **结构性长路径**，改法一/二都要做。
- 若 `Data Delay < 5 ns` ⇒ 当前是布局掩盖，**降级为 P2**，只做"删死寄存器"。

---

# P0-3 · 手写 **16 级 ripple-carry** 取负，直接喂 16×16 乘法器（一条 16 级 LUT 链）

### 位置与代码

`rtl/w3b/vibrato_lfo.v:52-76`

```verilog
 52:     // Triangle LFO: 0 -> +1 -> 0 -> -1 -> 0 over one 32-bit phase turn.
 53:     wire [14:0] tri_mag = phase_q[30] ? ~phase_q[29:15] : phase_q[29:15];
 54:     // Build two's-complement negation at exactly 16 bits. Gowin widens both
 55:     // unary '-' and '+' by one bit, so use a ripple carry here instead.
 56:     function [15:0] twos_complement16;
 57:         input [15:0] value;
 58:         integer bit_i;
 59:         reg carry;
 60:         begin
 61:             carry = 1'b1;
 62:             for (bit_i = 0; bit_i < 16; bit_i = bit_i + 1) begin
 63:                 twos_complement16[bit_i] = (~value[bit_i]) ^ carry;
 64:                 carry = (~value[bit_i]) & carry;
 65:             end
 66:         end
 67:     endfunction
 68:     wire [15:0] triangle_bits = phase_q[31]
 69:                                ? twos_complement16({1'b0, tri_mag})
 70:                                :  {1'b0, tri_mag};
 71:     wire signed [15:0] triangle_q = triangle_bits;
 72:     wire signed [31:0] mod_product = triangle_q * $signed(depth_q);
 73:     // Q1.15 product -> Q1.15.  The explicit slice is the low 16 bits of the
 74:     // arithmetic result and avoids Gowin's implicit 17-bit shift truncation.
 75:     wire [15:0] mod_bits = mod_product[30:15];
 76:     wire signed [15:0] mod_w = mod_bits;
```

### 机制

第 64 行 `carry = (~value[bit_i]) & carry;` 是一条**纯 2 输入 AND 串联链**：`carry` 只能经过 `bit_i = 0 → 15` **逐级**传播 ⇒ **16 个 LUT 级联**。

⚠️ 关键点：**这不是加法器**。Gowin 的专用进位链（`ALU` 资源，每单元 2 bit）只在综合器**识别出 `+` / `−` 运算符**时才被推断。这里是一个手写的 `&` 链，综合器**没有义务**把它映射成进位链 —— 而作者写这段代码的**动机**恰恰是"绕开 Gowin 的 `+`/`-` 宽度推断"，所以它**大概率**是 16 级普通 LUT 链。

**这条链在一条 50 MHz 拍内的位置**（全部串在一拍里）：

```
phase_q[31] → tri_mag（15 位 2:1 mux）
            → twos_complement16（16 级 LUT 链）
            → triangle_q
            → mod_product = triangle_q × $signed(depth_q)（16×16 有符号乘法）
            → mod_product[30:15]
            → mod_o → u_oscillator_bank/vibrato_mod_r/D
```

`sim/evidence/rightboard-vibrato-fix-20261008/README.md:12-14` 记录的**修前**实测最差路径正是这一条的**上游**：
`u_vibrato_lfo/phase_q_17_s0/Q → u_oscillator_bank/gen_lane[*].phase_q_*_s0/D`，**21.4 ns**（约束 18.181）、slack **−3.272 ns**、**1630 个端点同时违例**、TNS **−2718.329 ns**。
那次修复在 `oscillator_bank` 侧插了 `vibrato_mod_r` / `vib_mul_r` 两级流水 ⇒ **把这条链的终点从 `gen_lane[*].phase_q` 拉回到 `vibrato_mod_r`**。**但链本身的 16 级 ripple-carry 一级没减**，只是不再是最差路径了（当前 `impl/pnr/Gowin2026.timing_paths` 里 `vibrato_lfo` 出现 **0** 次）。

⇒ **结论：结构性长路径，当前被布局掩盖。**

### 具体怎么改

`~x + 1` 就是 16 位补码取负，**与现有函数逐位等价**，而且**不会触发作者担心的宽度扩张**（两个操作数都是 16 位 ⇒ 结果 16 位）：

```verilog
    // 删掉 twos_complement16 整个 function，替换为：
    wire [15:0] tri_pos = {1'b0, tri_mag};          // 16 位，MSB 恒 0
    wire [15:0] tri_neg = (~tri_pos) + 16'd1;       // 16 位进位链取负，与旧函数逐位相同
    wire [15:0] triangle_bits = phase_q[31] ? tri_neg : tri_pos;
```

- `(~tri_pos)` 是 16 位取反（16 个 LUT，**并行、不在关键路径上**）。
- `+ 16'd1` 是**一条 16 位进位链** = **8 个 ALU**（每 ALU 2 bit）⇒ 延迟约 **0.3~0.5 ns**，而不是 16 级 LUT 的 **8~11 ns**。
- 两个操作数都是 `16'd` 字面量宽度 ⇒ **结果宽度 = max(16,16) = 16** ⇒ 作者的顾虑（Gowin 把 `-`/`+` 加宽 1 位）**在这个写法下不成立**。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益（延迟） | 这条链从 **16 级 LUT** 降到 **1 条进位链**；估算省 **8~10 ns**（按 Gowin LUT4 一级 ~0.5~0.7 ns 含布线） |
| 收益（资源） | 省 16 个 LUT2（`^` 那 16 个 XOR 保留在进位链的 ALU 里）；`ALU +8`，`LUT −16` |
| 代价 | **0**（逐位等价，无 FF，无行为变更） |
| 对 Fmax | 当前不体现（不在 Top-25）；但**这是把 `vibrato_lfo` 整条链的余量从"薄"变"厚"最便宜的一刀** |

### 怎么验证能红

**（1）逐位等价判据（必须做，否则不知道改对了没有）**：新 tb 用**同一个 `phase_q` 序列**驱动新旧两份 `vibrato_lfo`（或直接把旧 function 留成一个 `_ref` 模块），比 `mod_o` 逐位：

```
激励：fast instance（RATE_MIN_INC = RATE_MAX_INC = 32'h4000_0000）跑满 4 个完整三角波周期，
      depth_raw 扫 96 / 4095 两档，共 ≥ 64 拍
断言：dut.mod_o === ref.mod_o（每一拍）
反证：把 `(~tri_pos) + 16'd1` 改成 `(~tri_pos) + 16'd0` ⇒ 必须全红
```
⚠️ 现有 `tb_vibrato_lfo.sv:93-96` 只查 `mod` 的**符号与过零**（`>0` / `==0` / `<0`），**查不出 1 LSB 的取负错误**（`−0` 与 `−1` 都能满足 `<0`）⇒ **必须补逐位比对**。

**（2）"是不是 16 级 LUT 链"的实测判据（把假设变成数字）**：探针 SDC 定向逼路径，再读 Logic Level：

```tcl
# 探针副本 SDC（⛔ 不碰交付树）
set_max_delay -from [get_pins {g_sound.u_vibrato_lfo/phase_q_*_s0/Q}] \
              -to   [get_pins {g_sound.u_vibrato_lfo/mod_product_*_s0/D}] 4.000
```
```powershell
Select-String -Path impl\pnr\Gowin2026_tr_content.html -Pattern 'vibrato_lfo'
```
- 改前：若该路径 **Logic Level ≥ 16** ⇒ **确认是 16 级 LUT 链**（我的判断成立）。
- 改后：**Logic Level 应降到 ≤ 3**（1 级取反 + 1 级进位链 + 1 级 mux）。
- ⚠️ 若改前 `Logic Level ≤ 5` ⇒ 工具**已经**把它映射成了进位链 ⇒ **本条降级为 P3（只是可读性问题）**，并如实记录。

---

# P0-4 · `DRUM_CLS_EXT=1` 只清零了**分类**窗口；**扫频深度**窗口（≤32 拍）仍然在，换鼓种时深度错 3.2~3.3×

### 位置与代码

`rtl/w3b/oscillator_bank.v:407-420`（**深度仍然由 `bv` 算**）

```verilog
407:             //   ⭐ **本档的扫频深度**（⭐ `bv >> (LSB_SH + 本档 SH)` ⇒ ⭐ 纯连线 ✅）
411:             wire [DRUM_SWEEP_W-1:0] sweep_kick =
412:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH);
413:             wire [DRUM_SWEEP_W-1:0] sweep_tom  =
414:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH);
416:             wire [DRUM_SWEEP_W-1:0] sweep_load =
417:                 (DRUM_PITCH_ENV_EN == 0) ? {DRUM_SWEEP_W{1'b0}}
418:               : is_kick                  ? sweep_kick
419:               : is_tom                   ? sweep_tom
420:               :                            {DRUM_SWEEP_W{1'b0}};
```

`rtl/w3b/oscillator_bank.v:367`（`bv` 的来源）

```verilog
367:             wire [PHASE_W-1:0] bv = base_phase_inc_i[vg*PHASE_W +: PHASE_W];
```

`rtl/top.v:4232`（`bv` = `note_manager.voice_phase_inc_o` = 轮转数组）

```verilog
4232:             .base_phase_inc_i   (nm_phase),
```

`rtl/w3b/note_manager.v:1518,1560,1575-1578`（**`rot_cnt` 自由运行，⛔ 不受 `sample_tick_i` 门控**）

```verilog
1518:     reg  [4:0]         rot_cnt;
...
1558:         end else begin
1559:             semi_tgt <= semi_tgt_w;
1560:             rot_cnt  <= rot_cnt + 5'd1;                 // ⭐ 自由运行（⭐ 5 位回绕 ✅）
...
1575:             if (rot_ok)
1576:                 phase_tr[rot_cnt] <= ((semi_cur == 5'sd0) ||
1577:                                       (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
1578:                                    ? rot_base : (prod_w >>> 15);
```

`rtl/w3b/note_manager.v:1615`（输出是**数组元素直连**，不是 mux）

```verilog
1615:         assign voice_phase_inc_o[gp*PHASE_W +: PHASE_W] = phase_tr[gp];
```

### 机制

**`rot_cnt` 是 50 MHz 下的自由运行计数器**（`note_manager.v:1560` 的 `rot_cnt <= rot_cnt + 5'd1;` **无条件**执行，`AGENTS.md` 里也确认 `rot_cnt` 是"自由运行 0..31"）。

⇒ `phase_tr[g]` 每 **32 拍（0.64 µs）** 才被重写一次，而 `sample_tick_i` 的周期是 **1024 拍（20.48 µs）**。两者虽然同源（都从 50 MHz 派生），但 **`rot_cnt` 在哪个拍恰好等于 `g` 是固定的、与 `sample_tick_i` 无关**。

`A3` 的正确修法（`sim/evidence/a3-proper-20261008/README.md`）把**分类**（`is_kick` / `is_tom`）搬到了 `note_manager.ST_COMMIT2` 提交那一刻 ⇒ 分类**零窗口** ✅。

🔴 **但 `sweep_load` 里的 `sweep_kick` / `sweep_tom` 仍然乘 `bv`**（`:411-414`）—— `bv` 就是那个**轮转刷新、最多滞后 32 拍**的值。⇒ **"深度"这一半仍然是旧值。**

**数字（用 `top.v:4205-4206` 的实际参数：`DRUM_TOM_MAX=20_000_000`、`DRUM_TOM_SWEEP_SH=3`、`DRUM_SWEEP_LSB_SH=8`、`DRUM_KICK_SWEEP_SH=0`）**：

| 场景 | 期望深度 | 实际取到的 `bv` | 实际深度 | 误差 |
|---|---|---|---|---|
| 同一 voice 上**底鼓(5 368 709) 紧跟嗵鼓(17 895 697)** | `17 895 697 >> 11` = **8 739** | 滞后的 `bv = 5 368 709`（上一击是底鼓） | `5 368 709 >> 11` = **2 621** | **浅 3.33×** |
| 同一 voice 上**嗵鼓紧跟底鼓** | `5 368 709 >> 8` = **20 971** | 滞后的 `bv = 17 895 697` | `17 895 697 >> 8` = **69 905** ⇒ 超 16 位 ⇒ 截断成 `69 905 − 65 536` = **4 369** | **深 4.8×**（且带截断） |

⇒ 底鼓的起音频率 = 标称 × (1 + 深度/标称) 里那个"深度"直接错 ⇒ **起音扫频要么完全听不出、要么过度到糊**。这正是 `A3` 想消灭的"鼓不像鼓"家族缺陷的**另一半**。

**为什么 `A3` 的记录没发现它**：`sim/evidence/a3-proper-20261008/README.md` 的 6 条判据（`tb_osc_drum_cls.sv` 的 A1/A2/A3/B1/B2/B3）**全部只驱动 `base_phase_inc_i` 的静态值**，没有"同一 voice 上先后两件不同鼓"的时序场景 ⇒ **分类对了、深度错了，判据照样全绿**。

### 具体怎么改

**（A）最小改动（推荐）**：让 `note_manager` 在 `ST_COMMIT2` 提交时**顺便把扫频深度也锁存**（与 `drum_cls_r` **同一个 64 FF 块、同一拍**），新开一根 `voice_drum_depth_o[POLY_TARGET*DRUM_SWEEP_W-1:0]`（32 × 16 = **512 bit**），`oscillator_bank` 在 `DRUM_CLS_EXT != 0` 时直接用它、**不再乘 `bv`**。

| 项 | 值 |
|---|---|
| 新增 FF | **512**（`note_manager` 侧 32 × 16） |
| 新增端口 | 512 bit 一根总线（跨模块） |
| 删掉的逻辑 | `DRUM_CLS_EXT=1` 档下 `sweep_kick` / `sweep_tom` 两个 32 位移位器（**纯连线，省 0 LUT**） |
| 参数门控 | 与 `DRUM_CLS_EXT` **同一个参数** ⇒ `DRUM_CLS_EXT=0`（全部 tb）时新端口**不参与综合**、Z 悬空不传播 ⇒ **老 tb 一个不改** ✅ |
| 代价 | `Register 17039 → 17551`（+3.0%，利用率 29% → 31%）；`CLS 78%` 上加 512 个 FF 的布线压力 |

**（B）零成本替代（若不想加 FF）**：把 `sweep_load` 的装载**延迟到"`phase_tr[g]` 已刷过至少一次"之后再认**——即在 `gen_voice` 里加一个"本 voice 的 `phase_tr` 自上次起音以来已刷新"的标志（32 × 1 = **32 FF**），条件不满足就**不装载**（保持 0 ⇒ 不扫频）。代价是**丢一拍扫频**（起音第一个采样拍不扫），听感影响小于"深度错 3.3×"。

### 怎么验证能红

**新判据（`tb_drum_pitch_env` 的时序扩展，或新建 `tb_drum_sweep_window.sv`）**：

```
单实例 oscillator_bank，DRUM_CLS_EXT=1，DRUM_PITCH_ENV_EN=1
激励（同一 voice 0，两击）：
  第 1 击：drum_cls_i[1]=1（底鼓）、base_inc[0]=32'd5_368_709，跑 8 拍
  第 2 击：drum_cls_i[0]=1（嗵鼓）、base_inc[0]=32'd17_895_697，
          ⚠️ 关键：在"base_inc 改变后的第 1 拍"就发 voice_phase_rst_i[0]=1（即窗口内起音）
断言：
  W1  装载那一拍的 sweep_q == 17_895_697 >> 11 == 16'd8739
      （现在会拿到 5_368_709 >> 11 == 2621 ⇒ FAIL）
  W2  随后 sweep_q 的衰减曲线与 W1 的初值一致（τ = 2^10 拍）
```
**反证（必须做）**：把 `note_manager` 的 `phase_tr` 轮转**人为改成"提交当拍立即刷新该 lane"**（探针副本）⇒ **W1 必须转绿** ⇒ 证明红是"窗口"造成的，不是别的原因。

**顺带跑**（确认没踩 `A3` 的既有契约）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter drum
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter osc
```

⚠️ **参考副本同步纪律**：若走 (A) 并新增端口，`tb/models/oscillator_bank_ref.v` **必须同步加同一条路径**（且只在 `DRUM_CLS_EXT!=0` 时生效），否则 `tb_p5_osc_equiv` 会**假红**（历史坑，见 `rightboard-vibrato-fix-20261008/README.md:77-83`）。

---

# P1-5 · `test_mode` 退出沿：RTL 与参考副本**行为分歧**，而 `tb_p5_osc_equiv` 的 test 档激励**与生产不符**、且**不覆盖退出沿**

### 位置与代码

**RTL（每 voice 一份）** `rtl/w3b/oscillator_bank.v:437-441` + `:453-454`

```verilog
437:             //   ⭐ 本 voice 是否"在响"（⭐ 含 Release 尾巴 ✅）
440:             wire act_v = test_mode_i ? test_lane_active_i[vg*OSC_PER_VOICE]
441:                                      : voice_active_i[vg];
...
453:                 end else if (sample_tick_i) begin
454:                     act_d <= act_v;
```

**参考副本（每 lane 一份）** `tb/models/oscillator_bank_ref.v:320-323` + `:492`

```verilog
320:             //   ⭐ 本 lane 是否"在响"（⭐ 含 Release 尾巴 ✅）
321:             wire lane_active = test_mode_i
322:                              ? test_lane_active_i[g]
323:                              : voice_active_i[VOICE_IDX];
...
492:                     lane_active_d <= lane_active;      // ⭐ 记一拍的"在响"
```

**生产激励的真实形状** `rtl/w3b/test_mode_ctrl.v:78-82`（**奇数 lane 恒为 0**）

```verilog
 78:             for (o = 0; o < OSC_PER_VOICE; o = o + 1) begin : gen_test_lane
 79:                 localparam integer LANE = v*OSC_PER_VOICE + o;
 80:                 assign test_lane_active_o[LANE] = selected && (o == 0);
```

**tb 的激励（`64'hFFFF…`，把差异**掩盖**掉了）** `tb/w3b/tb_p5_osc_equiv.sv:209-217`

```verilog
209:         // ── E · test 档（20 帧）────────────────────────────────────────────
210:         test_mode = 1'b1;
211:         test_lane_active = 64'hFFFF_FFFF_FFFF_FFFF;
212:         for (i = 0; i < 64; i = i + 1)
213:             test_phase_inc[i*32 +: 32] = 32'd2_000_000 + i * 32'd999_983;
214:         for (f = 0; f < 20; f = f + 1) frame;
215:         test_mode = 1'b0;
216: 
217:         $display("--------------------------------------------------");
```

### 机制

RTL 把 `act_d` **上提到 voice 级**（P5-② 的优化），取的是**该 voice 的 osc0 那一位**：`test_lane_active_i[vg*2]`。
参考副本保留 lane 级：lane `2vg+1`（失谐副本）取的是 `test_lane_active_i[2vg+1]`。

**在生产激励下（`test_mode_ctrl.v:80`）奇数 lane 恒为 0**：

| | RTL `act_d_bus[vg]` | 参考副本 lane `2vg+1` 的 `lane_active_d` |
|---|---|---|
| test 档中（voice 被选中） | **1** | **0** |

⇒ 在 **`test_mode_i: 1 → 0` 的第一个 `sample_tick_i`**，若 `voice_active_i[vg] = 1`（含 Release 尾巴，`live_mask = gate_r | retrig_low | env_active_i`）：

- **RTL**：`lane_active && !act_d_bus[VOICE_IDX]` = `1 && !1` = **0**，且 `phase_rst_lane` = 0 ⇒ **不装载** ⇒ 走 else 分支继续累加。
- **参考副本 lane 2vg+1**：`lane_active && !lane_active_d` = `1 && !0` = **1** ⇒ **装载 `phase_seed`（90°）＋ 装载 `sweep_load`**。

⇒ **同拍 `phase_q` 不同** ⇒ `tb_p5_osc_equiv.sv:117-155` 的 `PHCMP(奇数 lane)` 会报 mismatch。

**这是"生产可达"的状态**：`top.v:4219 .voice_active_i(nm_active)`，而保留池（节拍器 / 鼓机）的 `live_mask` **恒为 1**（`top.v:4261-4270` 记录了"节拍器 `EVT_KIND` 是常量 note_on、⛔ 永不发 note_off"）。⇒ 离开 Test Mode 的那一刻，保留池那几个 voice **确实**处在 `voice_active = 1`。

**为什么 tb 抓不到**（两个独立缺口，都要点出来）：
1. `tb_p5_osc_equiv.sv:211` 用 `64'hFFFF_FFFF_FFFF_FFFF` ⇒ 奇数 lane 也被置 1 ⇒ 参考副本 lane `2vg+1` 的 `lane_active_d` 也变成 1 ⇒ **两侧同值，差异被抹平**。
2. `tb_p5_osc_equiv.sv:215-217`：`test_mode = 1'b0;` 之后**紧接着 `$display` 和 `$finish`** ⇒ **退出沿那一拍从来没有被比过**。

### 具体怎么改

**改法一（改判据，零 RTL 风险 —— 推荐先做）**：在 `tb_p5_osc_equiv.sv` 的 E 段末尾补 4 帧，并把激励换成**生产形状**：

```verilog
        // ── E · test 档（20 帧）────────────────────────────────────────────
        test_mode = 1'b1;
        test_lane_active = 64'h5555_5555_5555_5555;   // ⭐ 生产形状：只有偶数 lane
        for (i = 0; i < 64; i = i + 1)
            test_phase_inc[i*32 +: 32] = 32'd2_000_000 + i * 32'd999_983;
        for (f = 0; f < 20; f = f + 1) frame;

        // ⭐⭐ 新增：退出沿 + 退出后 4 帧，voice_active 保持全 1（模拟保留池恒响）
        voice_active = 32'hFFFF_FFFF;
        test_mode = 1'b0;
        for (f = 0; f < 4; f = f + 1) frame;
```

判据：
- **若 mismatch ⇒ 我的分析成立**，RTL 与"已被逐位等价验证的基线"在生产可达状态下**不等价**。
- **若 0 mismatch ⇒ 我的分析错了**（这本身就是有价值的证伪），本条降级为 P3，并把这个"退出沿已覆盖"的事实写回 tb 注释。

**改法二（修 RTL，让两侧真正等价）**：把 `act_d_bus` 的语义改成"**该 voice 的任一 lane 在响**"，即与参考副本在非 test 档下等价、在 test 档下也取同一口径：

```verilog
// gen_voice 内，line 440-441 改为：
wire act_v = test_mode_i ? (test_lane_active_i[vg*OSC_PER_VOICE] |
                            test_lane_active_i[vg*OSC_PER_VOICE + 1])
                         : voice_active_i[vg];
```
⚠️ **这一改会动 `sweep_q` 的装载条件**（`:458`），而 `tb_drum_pitch_env` / `tb_oscillator_bank` 可能依赖现行为 ⇒ **必须先跑 tb 再改**。

### 预期收益 / 代价

| | 改法一 | 改法二 |
|---|---|---|
| 收益 | 把"逐位等价"这句话**变成真的**（生产可达状态下成立） | 同上 + 消除 1 帧（20.5 µs）的"起音相位复位被跳过" |
| 代价 | **0**（只改 tb） | 1 个 OR 门 / voice；**可能打红 `tb_drum_pitch_env`**（需实测） |
| 对 Fmax | 0 | 0 |

### 怎么验证能红

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter p5_osc_equiv
```
- 补完 4 帧后**第一次跑就应该红**（`FAIL frame N: lane 1 PHASE ref=… dut=…`，且全是奇数 lane）。
- 反向验证：把 `tb_p5_osc_equiv.sv:211` 改回 `64'hFFFF_FFFF_FFFF_FFFF` ⇒ **必须转绿** ⇒ 证明红是"激励形状"造成的，不是流水/时序问题。

---

# P1-6 · 扫频深度自检**只守 `DRUM_KICK_MAX`，不守 `DRUM_TOM_MAX`** ⇒ 嗵鼓深度可静默截断 6.2×

### 位置与代码

`rtl/w3b/oscillator_bank.v:911-925`

```verilog
911:         //  ⭐⭐ 2026-09-30 新增（阶段 2b）：⭐ **扫频深度的【截断】自检** ✅
912:         //   🔴 为什么必须有（⭐ `K-106`：⛔ 不许静默失效 ✅）：
917:         //   ⭐ 判据：⭐ 门限上界对应的深度必须**装得进** `DRUM_SWEEP_W` 位 ✅
918:         if ((DRUM_PITCH_ENV_EN != 0)
919:             && (((DRUM_KICK_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH))
920:                 >= (1 << DRUM_SWEEP_W)))
921:             $display("ERROR [oscillator_bank] 扫频深度被截断：DRUM_KICK_MAX=%0d >> (%0d+%0d) 超过 %0d 位",
922:                      DRUM_KICK_MAX, DRUM_SWEEP_LSB_SH, DRUM_KICK_SWEEP_SH, DRUM_SWEEP_W);
```

`rtl/w3b/oscillator_bank.v:411-414`（两个深度**都**是 16 位，**两个都要守**）

```verilog
411:             wire [DRUM_SWEEP_W-1:0] sweep_kick =
412:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH);
413:             wire [DRUM_SWEEP_W-1:0] sweep_tom  =
414:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH);
```

`rtl/top.v:4195-4206`（**顶层把 `DRUM_TOM_MAX` 抬到 20 M** —— 正是最需要守的那一路）

```verilog
4195:             //   ⭐ **① `DRUM_TOM_MAX` 15M → 20M**（⭐ 嗵鼓档上界 167.6 → **223.3 Hz**）
4205:             .DRUM_TOM_MAX     (20_000_000),
4206:             .DRUM_TOM_SWEEP_SH(3),
```

`rtl/top.v:4200-4201`（**顶层注释自己承认了这个缺口**）

```verilog
4200:             //      📌 **自检**：⭐ `oscillator_bank.v` 的 `sweep_q`"扫频深度截断"自检**只守 `DRUM_KICK_MAX`**
4201:             //         ⇒ ⭐ 抬高 `DRUM_TOM_MAX` **不会**触发它 ✅
```

### 机制（数字）

`DRUM_SWEEP_W = 16` ⇒ 可表示的深度上限 **65 535**。

| 配置 | 深度 = `门限 >> (8 + SH)` | 是否 ≥ 65 536 | 实际存进 `sweep_q` | 自检是否报警 |
|---|---|---|---|---|
| 当前交付（`TOM_MAX=20M, TOM_SH=3`） | `20 000 000 >> 11` = **9 765** | 否 ✅ | 9 765 ✅ | — |
| 把 `DRUM_TOM_SWEEP_SH` 改成 **0** | `20 000 000 >> 8` = **78 125** | **是** 🔴 | `78 125 & 0xFFFF` = **12 589** | 🔴 **不报警**（自检只看 KICK） |
| 把 `DRUM_TOM_MAX` 改成 **40 M**（`TOM_SH=3`） | `40 000 000 >> 11` = **19 531** | 否 ✅ | 19 531 ✅ | — |
| 把 `DRUM_TOM_MAX` 改成 **200 M**（`TOM_SH=3`） | `200 000 000 >> 11` = **97 656** | **是** 🔴 | `97 656 & 0xFFFF` = **32 120** | 🔴 **不报警** |

⇒ `TOM_SH=0` 那一行的**净效果**：嗵鼓扫频深度从"设计意图 78 125"变成"实际 12 589" ⇒ **浅 6.2 倍**，而且**零报错、零警告**。这正是 `K-106`（"⛔ 不许静默失效"）要防的事，但防线只铺了一半。

### 具体怎么改

在 `:922` 之后**镜像一份 TOM 的检查**，并补一条 `so_v` 的移位溢出检查（见 P2-11）：

```verilog
        // ⭐ 嗵鼓：与底鼓同款（顶层已经把 TOM_MAX 抬到 20M ⇒ 这一路更需要守）
        if ((DRUM_PITCH_ENV_EN != 0)
            && (((DRUM_TOM_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH))
                >= (1 << DRUM_SWEEP_W)))
            $display("ERROR [oscillator_bank] 嗵鼓扫频深度被截断：DRUM_TOM_MAX=%0d >> (%0d+%0d) 超过 %0d 位",
                     DRUM_TOM_MAX, DRUM_SWEEP_LSB_SH, DRUM_TOM_SWEEP_SH, DRUM_SWEEP_W);
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 把"参数调错 ⇒ 静默变浅"变成"参数调错 ⇒ 仿真启动就报 ERROR" |
| 代价 | **0**（`initial` 块只在仿真跑，综合器忽略；`oscillator_bank.v:899-901` 已经确立了这套路） |
| 对 Fmax | **0**（`initial` 不进网表） |

### 怎么验证能红

**探针副本**（⛔ 不碰交付树）里把 `.DRUM_TOM_SWEEP_SH(3)` 改成 `0`，跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter drum
```
- **改前**：日志里**没有**任何 `ERROR [oscillator_bank] 嗵鼓扫频深度被截断` ⇒ 缺陷确认。
- **改后**：必须打印该行（并且是 **ERROR** 不是 WARNING）。
- 反向验证：改回 `3` ⇒ 必须**不再打印**（否则自检本身写错了）。

---

# P1-7 · T10 链 `voice_i2s_chain` 硬编码 `.JUSTIFY(1)`，与生产 `top.v` 的 `.JUSTIFY(0)` 冲突 ⇒ 在新板上必然静音/错位

### 位置与代码

`rtl/w3b/voice_i2s_chain.v:71-77`

```verilog
 71:     i2s_tx #(
 72:         .SAMPLE_W  (24),
 73:         .DATA_BITS (16),
 74:         .SLOT_BITS (32),
 75:         .JUSTIFY   (1),
 76:         .MSB_DELAY (1),
 77:         .LRCK_POL  (0)
 78:     ) u_i2s_tx (
```

`rtl/top.v:4616-4620`（**生产通路 = 0**）

```verilog
4616:         //    ⭐ 按【标准 I2S / 左对齐】解析 ⇒ `JUSTIFY` 1 → **0**。
4619:         .JUSTIFY   (0),           // ⭐ 0 = 标准 I2S 左对齐（MAX98357A）
4620:         .MSB_DELAY (1),           // 标准 I2S 的 MSB 延迟 = 1 BCK（⛔ 不用改）
```

`rtl/w3c/i2s_tx.v:21-29`（两种格式的语义）+ `:160-165`（位映射）

```verilog
 21: //    · `JUSTIFY=0` 左对齐（Philips 标准 I2S）—— ⭐ **当前默认**（Tang Console / `MAX98357A`）
 22: //    · `JUSTIFY=1` 右对齐（LSBJ / 日本格式）—— ⚠️ 旧板 NEO Dock / `PT8211` 用这个
...
160:             if (JUSTIFY == 0) begin
161:                 i2 = b - MSB_DELAY;                    // 左对齐：数据占 [MSB_DELAY, +DATA_BITS)
162:                 if (i2 >= 0 && i2 < DATA_BITS) calc_bit = d[DATA_BITS-1-i2];
163:             end else begin
164:                 i2 = b - (SLOT_BITS - DATA_BITS);      // 右对齐（LSBJ）：数据占时隙尾部
165:                 if (i2 >= 0 && i2 < DATA_BITS) calc_bit = d[DATA_BITS-1-i2];
```

### 机制（数字）

`SLOT_BITS = 32`、`DATA_BITS = 16` ⇒ `JUSTIFY=1` 把 16 位数据放在时隙的 **BCK 16..31**（尾部）；`JUSTIFY=0` 放在 **BCK 1..16**。
⇒ **同一个 32 位时隙里，两种配置的数据位置相差 15 个 BCK。**
新板（`MAX98357A` / `PCM5102A`）按 **Philips 标准 I2S** 解析 ⇒ 读 **BCK 1..16** ⇒ 在 `JUSTIFY=1` 下读到的是**时隙头部**，而数据在尾部 ⇒ **读到的全是填充位（静音或错位数据）**。

`voice.v:101` 把 16 位样本放到 24 位的高 16 位：

```verilog
101:                 sample_out <= {scaled_16, {(SAMPLE_W-16){1'b0}}};
```
`i2s_tx.top_bits()` 取高 16 位 ⇒ 拿到 `scaled_16` ✅ —— **所以问题纯粹是 `JUSTIFY`**，不是位宽。

**这是"T10 集成缝"（`voice_i2s_chain.v:3` 自称）在新板上的确定性失效**：任何人在新板上例化这个 chain（`bringup/synth_check_top.v:341` 已经这么做了）都会得到静音。

### 具体怎么改

```verilog
        .JUSTIFY   (0),           // ⭐ 与 top.v:4619 一致（新板 MAX98357A / PCM5102A = 标准 I2S）
        .MSB_DELAY (1),
```
并把 `voice_i2s_chain.v:4` 的注释"the production I2S TX"改成明确口径（它是 **T10 历史缝**，不是生产通路）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 新板上这条链**从静音变出声** |
| 代价 | **0**（参数常量） |
| 对 Fmax | **0**（`voice_i2s_chain` 不在 `rtl/top.v` 的网表里，见 P2-20） |

### 怎么验证能红

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter i2s
```
⚠️ 现有 `tb_i2s_tx*` 直接例化 `i2s_tx` 并显式传参 ⇒ **抓不到 chain 里的参数写错**。需要**新判据**：

```
新 tb（例化 voice_i2s_chain，不传 JUSTIFY）：
  断言 J1  chain 内 u_i2s_tx 的 JUSTIFY 参数值 == top.v 生产实例的值（用 defparam 反射不可行 ⇒
           改为：在同一 tb 里并列例化生产参数版 i2s_tx 与 chain，同激励比 HP_DIN 逐位）
  断言 J2  同一个 16 位样本经两条路输出的 HP_DIN 序列逐位相同
反证：把 chain 的 JUSTIFY 改回 1 ⇒ J1/J2 必须红
```

---

# P1-8 · `LANES ≤ 1024` 自检**量错了对象**；`1024` 是跨模块硬编码常量

### 位置与代码

`rtl/w3b/oscillator_bank.v:899-905`

```verilog
899:     // ⚠️ 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）：
900:     //    ⭐ `LANES` 必须 ≤ `CLK_PER_SAMPLE`（1024），否则 **TDM 跑不完一帧**
901:     //       ⇒ ⛔ 帧内截止必然失败（`A6`），而且现象是"随机丢样本"，极难定位。
902:     initial begin
903:         if (LANES > 1024)
904:             $display("ERROR [oscillator_bank] LANES=%0d > 1024（每帧可用 clk 数）=> TDM 跑不完一帧，A6 必然失败",
905:                      LANES);
```

`rtl/w3b/oscillator_bank.v:718-738`（**TDM 实际需要 `LANES+2` 拍，不是 `LANES` 拍**）

```verilog
723:         end else if (sample_tick_i) begin
724:             // 新一帧：从 lane 0 开始重新取
725:             cnt       <= {(LW+1){1'b0}};
...
728:         end else if (rendering) begin
729:             if (cnt == LANES[LW:0])
730:                 rendering <= 1'b0;          // 全部取完
...
734:             valid_r <= (cnt == LANES[LW:0]);
```
`cnt` 走 `0 → LANES`（**LANES+1 个状态**），再加 `valid_r` 那一拍 ⇒ **共 `LANES+2` 拍**。

`rtl/clk_gen.v:26`（真正的一帧长度在这里，**`oscillator_bank` 看不到它**）

```verilog
 26:     parameter integer CLK_PER_SAMPLE = 1024,   // fs 分频：50 MHz / 1024 = 48.828125 kHz
```

### 机制（数字）

`oscillator_bank` **没有 `CLK_PER_SAMPLE` 参数**，自检里的 `1024` 是一个**手抄的魔数**。

| `clk_gen.CLK_PER_SAMPLE` | 一帧可用拍 | TDM 需要 | 自检（`LANES=64 > 1024`?） | 实际结果 |
|---|---|---|---|---|
| 1024（当前） | 1024 | **66** | 否 | ✅ 余量 15.5× |
| 512 | 512 | 66 | 否 | ✅ |
| 256 | 256 | 66 | 否 | ✅ |
| 128 | 128 | 66 | 否 | ✅ |
| **64** | 64 | **66** | 否 🔴 | 🔴 **TDM 跨帧**：`osc_valid_o` 在新一帧的 `sample_tick_i` 之后才拉高 ⇒ `tdm_render_mixer` 读到**半旧半新**的样本总线，**零报错** |

⇒ 自检的**判据写错了**：它守的是 `LANES > 1024`，而真正的不变量是 **`LANES + 2 ≤ CLK_PER_SAMPLE`**。并且 `1024` 这个数**在 `clk_gen.v` 和 `oscillator_bank.v` 两处各写一遍**（跨模块常量重复，`AGENTS.md` 记录的复发缺陷类）。

### 具体怎么改

```verilog
module oscillator_bank #(
    ...
    // ⭐ 与 clk_gen.CLK_PER_SAMPLE 同源；顶层必须显式传同一个值
    parameter integer CLK_PER_SAMPLE = 1024,
    ...
```
```verilog
    initial begin
        // ⭐ 真正的不变量：TDM 必须在【一帧之内】跑完（cnt 走 0..LANES 再加 valid 一拍）
        if ((LANES + 2) > CLK_PER_SAMPLE)
            $display("ERROR [oscillator_bank] TDM 需要 LANES+2=%0d 拍 > 一帧 CLK_PER_SAMPLE=%0d ⇒ 跨帧，A6 失败（现象=随机丢样本）",
                     LANES + 2, CLK_PER_SAMPLE);
```
`top.v:4163-4215` 的例化里补 `.CLK_PER_SAMPLE(CLK_PER_SAMPLE)`（`top.v` 已有同名参数）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 把"改 `CLK_PER_SAMPLE` ⇒ 静默丢样本"变成"启动即 ERROR" |
| 代价 | **1 个参数 + 1 行 initial**；`LANES + 2` 是编译期常量，**0 硬件** |
| 对 Fmax | **0** |

### 怎么验证能红

探针副本：`clk_gen` 的 `CLK_PER_SAMPLE` 改 `64`、`oscillator_bank` 传 `64`：
- **改前**：日志无任何 ERROR；`tb_p5_osc_equiv` 之外看不出问题（因为 tb 直接驱动 `sample_tick_i`，不看 `clk_gen`）。
- **改后**：必须打印 ERROR。
- 更强的判据（新 tb，端到端）：`tb_top_*` 里把 `CLK_PER_SAMPLE` 传 `64`，断言 `osc_valid_o` 在下一个 `sample_tick_i` 之前**必须**已经拉高过一次 ⇒ 现在必红。

---

# P1-9 · 相位增量通路 **3~4 级串联 32 位加法器** + `vib_off` 单根 32 位网扇出 **1024** 个负载；⚠️ **⛔ 不可流水线**

### 位置与代码

`rtl/w3b/oscillator_bank.v:446-447`（扫频偏移）

```verilog
446:             wire [PHASE_W-1:0] so_v =
447:                 {{(PHASE_W-DRUM_SWEEP_W){1'b0}}, sweep_q} << DRUM_SWEEP_LSB_SH;
```

`rtl/w3b/oscillator_bank.v:466-471`（**两级串联加法**，失谐副本再 **+1 级**）

```verilog
466:             //   ⭐⭐ **相位增量**：⭐ 主 lane = 基频 + 颤音 + 本 voice 的扫频偏移
468:             //     📌 32 位无符号加法（⭐ mod 2³²）与原来 33 位有符号加法**截断后等价** ✅
469:             assign inc_main_w[vg*PHASE_W +: PHASE_W] = bv + vib_off[PHASE_W-1:0] + so_v;
470:             assign inc_det_w [vg*PHASE_W +: PHASE_W] =
471:                 inc_main_w[vg*PHASE_W +: PHASE_W] + dv;
```

`rtl/w3b/oscillator_bank.v:531-533` + `:569-571`（lane 选择 mux 在加法**之后**）+ `:682-683`（**第 4 级加法**）

```verilog
531:             wire [PHASE_W-1:0] lane_inc_base =
532:                 (OSC_IDX != 0) ? inc_det_w[VOICE_IDX*PHASE_W +: PHASE_W]
533:                                : inc_main_w[VOICE_IDX*PHASE_W +: PHASE_W];
...
569:             wire [PHASE_W-1:0] lane_inc = test_mode_i
570:                              ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
571:                              : lane_inc_base;
...
682:                         if (lane_active)
683:                             phase_q <= phase_q + lane_inc;
```

### 机制（数字）

**串联深度**（Verilog 左结合 ⇒ `bv + vib_off` 先算，再 `+ so_v`）：

| lane | 级数 | 明细 |
|---|---|---|
| 偶数 lane（`OSC_IDX=0`） | **3** | `(bv + vib_off)` → `+ so_v` → `test_mode_i` mux → `phase_q + lane_inc` |
| **奇数 lane（`OSC_IDX=1`）** | **4** | `(bv + vib_off)` → `+ so_v` → **`+ dv`** → mux → `phase_q + lane_inc` |

⚠️ **这是"深度最优"的**：4 项和用 2 输入加法器最少就是 3 级（`(bv+dv) + (vib_off+so_v)`），再加相位累加那一级 = 4 级。**换任何写法都不会更浅。** 所以这不是"写法不好"，是**结构本身的深度**。

**ALU 占用**（Gowin `ALU` = 每单元 2 bit 进位链；PnR 报告 `ALU 7372`）：

| 加法器 | 个数 | 位宽 | ALU |
|---|---|---|---|
| `bv + vib_off` | 32 | 32 | 512 |
| `+ so_v` | 32 | 32 | 512 |
| `+ dv`（仅奇数 lane 用，但**32 个都综合出来**） | 32 | 32 | 512 |
| `phase_q + lane_inc` | **64** | 32 | **1024** |
| **小计** | | | **2 560** |

⇒ **这四组加法器独占 `ALU 7372` 的 34.7%**（还没算 `sweep_dec` 的 32 × 16 位 = 256）。

**扇出**：`vib_off[31:0]` 是**一根共享网**（`:333` 一个 48 位寄存器的切片），负载 = `32 voice × 32 bit` = **1 024**；`so_v` 同理。

**当前状态（已 grep 证实）**：`impl/pnr/Gowin2026.timing_paths` 的 25 条 setup 最差路径里 `oscillator_bank` 出现 **0 次** ⇒ **当前被布局掩盖**。
**但它曾经是**：`sim/evidence/rightboard-vibrato-fix-20261008/README.md:26` —— 修前最差路径就是 `u_vibrato_lfo/phase_q_17_s0 → gen_lane[*].phase_q_*`，`Data Delay 21.4 ns`、`slack −3.272`、**1630 端点违例**。那次是在**链的起点**（`vibrato_mod_i`）插了两级流水，把 21.4 ns 砍成两段。**链中间这 3~4 级加法器一级没减。**

### 🔴 关键警告：⛔ **不能**在这条路上加流水寄存器

`bv = base_phase_inc_i[vg*32 +: 32]`，而 `base_phase_inc_i` = `note_manager.voice_phase_inc_o` = **`phase_tr[gp]` 数组元素直连**（`note_manager.v:1615`）。
`phase_tr[rot_cnt]` 由 **自由运行的 `rot_cnt`**（`note_manager.v:1560`，**无条件** `rot_cnt <= rot_cnt + 5'd1`）每 **32 拍**刷新一次。

⇒ **`bv` 在哪个拍变化与 `sample_tick_i` 无关**（32 与 1024 同源但相位固定且不重合）。
⇒ 在 `inc_main_w` / `inc_det_w` 上加一拍寄存器，会让 `sample_tick_i` 那一拍采样到**上一个 32 拍窗口**的增量 ⇒ **行为改变**，`tb_p5_osc_equiv`（逐位比 64 个 `phase_q`）**必红**。

**⇒ 结论：这条路径只能"减宽度/减扇出/减负载"，不能"切流水"。** 任何声称"给 inc 加流水"的方案都要先证明 `tb_p5_osc_equiv` 仍逐位等价。

### 具体怎么改（只列**安全**的杠杆）

| # | 改法 | 收益 | 风险 |
|---|---|---|---|
| a | `inc_det_w` 只在 `OSC_PER_VOICE > 1` 时才需要 ⇒ 把 `dv` 与 `inc_det_w` 包进 `generate if (OSC_PER_VOICE > 1)` | 当前无收益（`OSC_PER_VOICE=2`） | 0 |
| b | **降低 `vib_off` 的扇出**：把 `vib_off` 拆成"每 voice 复制一份寄存器"（32 × 32 = **1024 FF**），把 1 根扇出 1024 的网变成 32 根扇出 32 的网 | 布线延迟显著下降（Gowin 自己会复制驱动，但复制点由工具决定，不可控） | **+1024 FF**（`Register 17039 → 18063`，+6%） |
| c | **把 `phase_q + lane_inc` 的加法器从 64 个减到 32 个**：`phase_q` 是每 lane 一份（**评分主体，⛔ 不能合并**），但可以把 `lane_inc` 在 `sample_tick_i` 那一拍**预寄存到每 lane 一份**（64 × 32 = 2048 FF）⇒ 相位累加器前面多一级寄存器、加法器深度从 4 降到 1 | 相位累加器前的深度 4 → **1** | **+2048 FF** 且 ⚠️ **同样受 (b) 的警告约束**：预寄存会让 `sample_tick_i` 采到上一拍的值 ⇒ **行为改变**。**只有在"预寄存的使能严格等于 `sample_tick_i` 且 `bv` 在相邻两拍不变"时才等价** —— 而 `bv` 每 32 拍变一次 ⇒ **有 1/32 的拍不等价** ⇒ 🔴 **不成立** |

**⇒ 诚实结论：这条路径在当前架构下没有"零风险显著降深度"的改法。**
真正能动的只有 **(b) 扇出复制**（加 FF 换布线），以及**把 P0-2 / P0-3 修掉**（把上游链腾出来，让布局器有余量照顾这里）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| (b) 收益 | 把 1 根 1024 负载的网拆成 32 根 32 负载的网；⚠️ 具体省多少 ns **必须实测** |
| (b) 代价 | **+1024 FF**（利用率 29% → 31%），CLS 78% 上加布线压力 |
| 对 Fmax | ⚠️ **可能双向**：`Register` 上升会占布线资源 ⇒ 当前 **+0.102 ns** 的余量有翻红风险 ⇒ **必须完整跑 PnR + 全量回归** |

### 怎么验证能红（以及怎么判断值不值得做）

**（1）把"是不是关键路径"从布局运气里分离出来 —— 定向过约束探针**：

```tcl
# 只读探针副本的 SDC（⛔ 不碰 constr/top.sdc）
set_max_delay -from [get_pins {g_sound.u_oscillator_bank/vib_mul_r_*_s0/Q}] \
              -to   [get_pins {g_sound.u_oscillator_bank/gen_lane[*].phase_q_*_s0/D}] 8.000
```
读 `impl/pnr/Gowin2026_tr_content.html` 该路径的 `Data Delay` 与 `Logic Level`：
- `Data Delay ≥ 12 ns` ⇒ **结构性瓶颈**，(b) 值得做。
- `Data Delay ≤ 8 ns` ⇒ 布局掩盖，**本条降级为 P2**，只做记录。

**（2）(b) 的收益判据（必须成对跑，禁止只看一次 PnR）**：
基线 `Fmax 55.313 MHz`，同源重跑噪声 **2~3 MHz**（`AGENTS.md` 明示）⇒ **单次对照无意义**。做法：
```
同一份 RTL：连跑 3 次 PnR，取 Fmax 的 min/median/max      → 噪声带
加 (b) 后：  连跑 3 次 PnR，取 min/median/max            → 对比
判据：(b) 的 median 比基线的 median 高 ≥ 1.0 MHz 才算有效；
      若两组区间重叠 ⇒ 判为"无结论"（⛔ 不许拿一次 55.9 当收益）
```
每次都要确认 **0 setup / 0 hold**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
Select-String -Path sim\evidence\gowin_m0_timing.txt -Pattern 'Violated|Actual Fmax'
```

---

# P1-10 · 同一文件内注释**自相矛盾**：`rom_hard` vs `rom_soft`；代码真值是 **`rom_soft`**

### 位置与代码

`rtl/w3b/oscillator_bank.v:813-820`（**注释说固定 `rom_hard`**）

```verilog
813:     //  ⭐⭐ 2026-09-29 修 bug②：⭐ **力度→音色 的耦合【默认关闭】**
814:     //   ⭐ `VEL_TIMBRE_BLEND = 0`（默认）⇒ ⭐ **固定 `rom_hard`**（⭐ 音色只由 `timbre` 决定）✅
...
817:     //  ⚠️⚠️ 2026-09-29 上板实测修正：⭐ **固定用 `rom_hard`，⛔ 不是 `rom_soft`**
818:     //   🔴 **为什么**：
819:     //      · ⭐ `rom_hard` 的 4 个块**互不相同**（⭐ 4 个音色可分辨 ✅）＋ ⭐ **满幅 32767** ✅
820:     //        ⇒ 🔴 而 `rom_soft`（⭐ 旧表：⭐ 4 块相同、峰值 16384）**听不出音色切换** ＋ **音量砍半** ✅
```

`rtl/w3b/oscillator_bank.v:831-833`（**同一文件、18 行之后，说固定 `rom_soft`**）

```verilog
831:     //  ⭐⭐ 2026-09-29 合并：⭐ **演奏通路固定走 `blend_sum`**（⭐ 队友版 ✅）
832:     //   ⭐ `FIXED_BLEND_Q = 0` ⇒ ⭐ `blend_sum = rom_soft` ⇒ ⭐ 用 **AKWF 的 soft 表**（⭐ 平滑档 ✅）
833:     //   ⭐ Test Mode 仍走**专用纯正弦** `rom_test`（⭐ 我们的，⛔ 不借 AKWF ✅）
```

`rtl/w3b/oscillator_bank.v:800-812` + `:845-847`（**代码真值**）

```verilog
800:     wire [8:0] velocity_mix_q = (resp_velocity_q == 8'hFF) ? 9'd256
801:                                                            : {1'b0, resp_velocity_q};
802:     localparam [8:0] FIXED_BLEND_Q_W = FIXED_BLEND_Q;
803:     wire [8:0] mix_q = (VELOCITY_BLEND_EN != 0) ? velocity_mix_q
804:                                                 : FIXED_BLEND_Q_W;
805:     wire signed [WT_W:0] blend_delta = {rom_hard[WT_W-1], rom_hard}
806:                                      - {rom_soft[WT_W-1], rom_soft};
807:     wire signed [WT_W+9:0] blend_product = blend_delta * $signed({1'b0, mix_q});
810:     wire signed [WT_W:0] blend_scaled = blend_product[WT_W+8:8];
811:     wire signed [WT_W:0] blend_sum = {rom_soft[WT_W-1], rom_soft}
812:                                   + blend_scaled;
...
845:     wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test
846:                                                   : (resp_drum_q ? rom_noise
847:                                                                  : blend_sum[WT_W-1:0]);
```

`rtl/top.v:4190-4191`（生产实例）

```verilog
4190:             .VELOCITY_BLEND_EN(0),
4191:             .FIXED_BLEND_Q (0),
```

### 机制

`VELOCITY_BLEND_EN = 0` ⇒ `mix_q = FIXED_BLEND_Q_W = 9'd0`
⇒ `blend_product = blend_delta × 0 = 0`
⇒ `blend_scaled = blend_product[24:8] = 0`
⇒ `blend_sum = {rom_soft[15], rom_soft} + 0`
⇒ `rom_dout = blend_sum[15:0]` = **`rom_soft`**（非鼓、非 test 档）

**⇒ 交付音色 = `rom_soft`（AKWF 的 soft 表）。`rom_hard` 在 `:817-820` 的说法与代码相反。**

另外 `:814` 提到的参数名 **`VEL_TIMBRE_BLEND` 在整个文件里不存在**（实际参数是 `VELOCITY_BLEND_EN`，`:86`）⇒ 同一段注释里**参数名也是错的**。

⚠️ **风险等级不是"文档洁癖"**：`AGENTS.md` §五③ 把"注释↔代码不一致"列为**本项目复发缺陷**，而且这里的不一致**指向相反的音色决策**。任何人"按注释修代码"就会把交付音色从 soft 翻成 hard ⇒ **直接改变听感 + 可能打红电平类判据**。

### 具体怎么改

- 删掉 `:817-820` 那四行（`rom_hard` 的"上板实测修正"），或**明确标注为历史**并写清"已被 `:831-833` 的合并版取代"。
- 把 `:814` 的 `VEL_TIMBRE_BLEND` 改成 `VELOCITY_BLEND_EN`。
- 在 `:811` 旁加一行**不变式**：`FIXED_BLEND_Q=0 ⇒ rom_dout == rom_soft（演奏通路）`。
- `tb/models/oscillator_bank_ref.v:696-699` 是**同一段过时注释的副本** ⇒ 一起改（否则下次同步会把它再抄回来）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"按注释改代码 ⇒ 翻音色"的地雷；消除参数名错误 |
| 代价 | **0**（只改注释） |
| 对 Fmax | **0** |

### 怎么验证能红

**这条不是"跑 tb 能红"，是"读代码能红"** —— 判据是机械的：

```powershell
# 判据：同一文件里"固定 rom_hard"与"= rom_soft"不能同时出现
Select-String -Path rtl\w3b\oscillator_bank.v -Pattern '固定.*rom_hard|blend_sum = rom_soft'
```
- 改前：**两处都命中** ⇒ 矛盾确认。
- 改后：只剩一处（或只剩带"历史"标注的一处）。

**行为侧的反向验证**（证明"代码真值是 soft"这件事**能被测出来**）：
把 `FIXED_BLEND_Q` 从 `0` 改成 `256`（⇒ hard）跑 `tb_soft_hard_blend` / `tb_wavetable_timbres`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter wavetable_timbres
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter soft_hard
```
若这些 tb **不变红**，说明交付音色**没有判据保护** ⇒ 补一条"`rom_dout` 必须等于 `wavetable_bank.sample_soft_o`"的断言（这是**比注释更硬的契约**）。

---

# P2-11 · `so_v` 的左移定标**没有溢出检查**；现有自检守的是另一个量

### 位置与代码

`rtl/w3b/oscillator_bank.v:445-447`

```verilog
445:             //   ⭐ **当前额外增量**（⭐ 左移定标 ⇒ ⭐ 纯连线、⛔ 无乘法器 ✅）
446:             wire [PHASE_W-1:0] so_v =
447:                 {{(PHASE_W-DRUM_SWEEP_W){1'b0}}, sweep_q} << DRUM_SWEEP_LSB_SH;
```

现有自检 `rtl/w3b/oscillator_bank.v:918-922`（守的是 `sweep_q` 的**装载值**，不是 `so_v`）

```verilog
918:         if ((DRUM_PITCH_ENV_EN != 0)
919:             && (((DRUM_KICK_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH))
920:                 >= (1 << DRUM_SWEEP_W)))
```

### 机制（数字）

`:447` 是一个 **32 位**表达式左移。`{16'b0, sweep_q}` 占 bit `15:0`，左移 `DRUM_SWEEP_LSB_SH` 后有效位落在 `[15+LSB_SH : LSB_SH]`。
**不丢位的条件：`DRUM_SWEEP_LSB_SH + DRUM_SWEEP_W ≤ PHASE_W`，即 `LSB_SH ≤ 16`。**

| `DRUM_SWEEP_LSB_SH` | `{16'b0,sweep_q} << LSB_SH` | 后果 | 现有自检 |
|---|---|---|---|
| 8（当前） | 有效位 `[23:8]` ✅ | 正常 | — |
| 16 | 有效位 `[31:16]` ✅ | 正常 | — |
| **17** | `sweep_q[15]` 落到 bit 32 ⇒ **丢失** | 偏移上限从 `65535×131072` 掉到 `32767×131072`（**减半**） | 🔴 **不报** |
| **24** | 只保留 `sweep_q[7:0]` | 偏移上限 **÷256** | 🔴 **不报** |

`:918` 的自检算的是 `(DRUM_KICK_MAX-1) >> (LSB_SH + KICK_SH)`（即 `sweep_kick` 的装载值），**与 `so_v` 的移位溢出是两个不同的量**。⇒ 把 `DRUM_SWEEP_LSB_SH` 从 8 调到 17，`:918` 的判据会**变得更宽松**（右移量更大、装载值更小），于是**自检更不会报**，而 `so_v` 正在丢高位。

### 具体怎么改

在 `:922` 之后补一条（与 P1-6 的 TOM 检查并列）：

```verilog
        if ((DRUM_PITCH_ENV_EN != 0)
            && ((DRUM_SWEEP_LSB_SH + DRUM_SWEEP_W) > PHASE_W))
            $display("ERROR [oscillator_bank] so_v 左移溢出：DRUM_SWEEP_LSB_SH=%0d + DRUM_SWEEP_W=%0d > PHASE_W=%0d ⇒ 扫频偏移高位移出被静默截断",
                     DRUM_SWEEP_LSB_SH, DRUM_SWEEP_W, PHASE_W);
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 把"改定标 ⇒ 静默丢高位"变成"启动即 ERROR" |
| 代价 | **0**（`initial`，不进网表） |

### 怎么验证能红

探针副本把 `DRUM_SWEEP_LSB_SH` 改 `17`，跑 `sim\tb_all.ps1 -Filter drum`：
- 改前：**无任何 ERROR**；`tb_drum_pitch_env` 若判据只查"扫频存在"而非"深度精确值"，**照样全绿**。
- 改后：必须打印新 ERROR。
- 反向：改回 `8` ⇒ 必须不打印。

---

# P2-12 · 奇数 lane 的 test-mode 覆盖 mux **白付 ≈1000 个 LUT4**（结构推断 + 可执行实验）

### 位置与代码

`rtl/w3b/oscillator_bank.v:566-571`

```verilog
566:             //   ⭐⭐ 把"本 lane 的相位增量"接上（⭐ 算术已在 `gen_voice` 算好 ✅）
567:             //     ⭐ `test_mode_i` 仍**直接覆盖** ⇒ ⭐ **test-mode 一个 bit 不变** ✅
569:             wire [PHASE_W-1:0] lane_inc = test_mode_i
570:                              ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
571:                              : lane_inc_base;
```

`rtl/w3b/test_mode_ctrl.v:80-82`（**奇数 lane 的 `test_phase_inc_o` 恒为常量 0**）

```verilog
 80:                 assign test_lane_active_o[LANE] = selected && (o == 0);
 81:                 assign test_phase_inc_o[LANE*PHASE_W +: PHASE_W] =
 82:                     (selected && (o == 0)) ? VOICE_INC : {PHASE_W{1'b0}};
```

`rtl/w3b/oscillator_bank.v:490-492`（**奇数 lane 在 test 档下 `lane_active = 0` ⇒ 相位冻结**）

```verilog
490:             wire lane_active = test_mode_i
491:                              ? test_lane_active_i[g]
492:                              : voice_active_i[VOICE_IDX];
```

### 机制

对 **`OSC_IDX == 1`** 的 32 个 lane：

1. `test_phase_inc_i[g*32 +: 32]` 在生产接线（`test_mode_ctrl.v:82`）下是**编译期常量 0**（常量跨模块传播后）。
2. 于是 `:569` 退化成 `lane_inc = test_mode_i ? 32'd0 : lane_inc_base` = **`lane_inc_base & {32{~test_mode_i}}`** ⇒ **32 个 2 输入 AND**。
3. 而 `test_mode_i` 是**运行期寄存器**（`top.v:1358 assign tm_enable_r = tm_enable_q;`）⇒ 综合器**不能折叠**这 32 个 AND。
4. 但 `test_mode_i=1` 时 `lane_active = test_lane_active_i[g] = 0`（`:80`）⇒ **相位冻结** ⇒ 这 32 个 AND 的输出**从不被使用**。

⇒ **32 lane × 32 bit = 1 024 个 AND2，纯白付**（按 Gowin LUT4 一个 LUT 放一个 2 输入函数估，**≈1 024 个 LUT4**，占 `LUT 27135` 的 **3.8%**）。

⚠️ **诚实标注：这是结构性推断，不是实测。** 两个不确定点：① Gowin 是否真的做了跨模块常量传播（若没做，`test_phase_inc_i` 被视为变量 ⇒ mux 是 32 个 2:1 mux，**更大**）；② Gowin 是否把 2 个独立 AND2 打包进 1 个 LUT4（打包则只有 ~512）。**必须用实验判定。**

### 具体怎么改（先测，再决定）

**实验（只读探针副本）**：把奇数 lane 的覆盖去掉：

```verilog
            // 探针：奇数 lane 的 test 覆盖在 test 档下是 don't-care（lane_active=0 ⇒ 相位冻结）
            wire [PHASE_W-1:0] lane_inc = (test_mode_i && (OSC_IDX == 0))
                             ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
                             : lane_inc_base;
```

判据：
- 综合报告 `LUT` 下降 **≥ 500** 且 **所有 tb 全绿** ⇒ 白付确认，**落地**（但必须同步改 `tb/models/oscillator_bank_ref.v`，否则 `tb_p5_osc_equiv` 假红 —— 它在 `:211-213` 给**全部 64 个** lane 都写了非零 `test_phase_inc`，正是靠 `:569` 的覆盖）。
- 综合报告 `LUT` 下降 **< 100** ⇒ 工具已折叠 ⇒ 本条**降级为 P3**，如实记录。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益（若成立） | `LUT −500 ~ −1000`（`LUT 27135` → 约 26200）；当前最差余量只有 **+0.102 ns**，降 LUT 是**唯一对整设计单向有利**的动作 |
| 代价 | **0**（不改行为，只要 tb 的 test 激励同步改成生产形状 —— 与 P1-5 的改法一**同一次改动**） |
| 对 Fmax | 预期**正向**；但受 2~3 MHz 布局噪声限制，需按 P1-9 的 3 次重复法判定 |

### 怎么验证能红

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT,ALU,ROM16'
```
- 判据：`LUT` 的差值（探针 vs 基线）。**必须 ≥500 才落地。**
- 功能侧：`tb_p5_osc_equiv`（改完参考副本后）必须 PASS；`tb_oscillator_bank` / `tb_test_mode_top` / `tb_top_test_mode_pipe` 必须全绿。

---

# P2-13 · `test_mode_ctrl` 的 6 位截断：`POLY_TARGET ≥ 64` 时 clamp 值**回绕成 0**，Test Mode 静默一个 voice 都不选

### 位置与代码

`rtl/w3b/test_mode_ctrl.v:42-47`

```verilog
 42:     wire [5:0] test_n0_c = (TEST_N0 > POLY_TARGET) ? POLY_TARGET : TEST_N0;
 43:     wire [5:0] test_n1_c = (TEST_N1 > POLY_TARGET) ? POLY_TARGET : TEST_N1;
 44:     wire [5:0] test_n2_c = (TEST_N2 > POLY_TARGET) ? POLY_TARGET : TEST_N2;
 45:     wire [5:0] test_n3_c = (TEST_N3 > POLY_TARGET) ? POLY_TARGET : TEST_N3;
 46: 
 47:     reg [5:0] selected_n_r;
```

`rtl/w3b/test_mode_ctrl.v:72`（判据用它）

```verilog
 72:             (* syn_keep = 1 *) wire selected = mode_enabled && (v < selected_n_r);
```

### 机制（数字）

`POLY_TARGET` 是 `parameter integer`（32 位）。`wire [5:0]` 只能表示 **0..63**。

| 配置 | 表达式 | 真值 | 截断到 6 位 | `active_n_o` | `selected` |
|---|---|---|---|---|---|
| 当前（`POLY_TARGET=32, TEST_N3=32`） | `32 > 32` = 假 | 32 | `6'd32` ✅ | 32 | 正常 |
| `POLY_TARGET=64, TEST_N3=64` | `64 > 64` = 假 | **64** | `6'd0` 🔴 | **0** | **全 0** |
| `POLY_TARGET=64, TEST_N3=100` | `100 > 64` = 真 | `POLY_TARGET=64` | `6'd0` 🔴 | **0** | **全 0** |

⇒ 只要 `POLY_TARGET ≥ 64`（本设计 `POLY_TARGET=32`，但**它是参数**，而 `oscillator_bank` 的 `LANES` 上限自检允许到 1024），**Test Mode 会静默什么都不选**，`active_n_o` 报 0，`M4` 判据（谱峰数 4/8/16/32）拿到的是**静音**。
**注释本身承认这个 clamp 的目的是"`active_n_o` 不能与 gate 的种群不一致"**（`:40-41`）—— 而 6 位截断**恰好把那个一致性又破坏了**。

### 具体怎么改

```verilog
    localparam integer NW = $clog2(POLY_TARGET + 1);   // 32 -> 6 ; 64 -> 7
    wire [NW-1:0] test_n0_c = (TEST_N0 > POLY_TARGET) ? POLY_TARGET : TEST_N0;
    ...
    reg [NW-1:0] selected_n_r;
    // active_n_o 的端口宽度也要同步（当前是 [5:0]）
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 参数化正确性；消除"改 `POLY_TARGET` ⇒ 测试模式静默失效" |
| 代价 | `selected_n_r` 从 6 → 7 位（**+1 FF**，组合）；`active_n_o` 端口宽度 +1（**接口变更** ⇒ `top.v:1352` 与 `tb_test_mode_ctrl.sv:22` 的位宽要同步） |
| 对 Fmax | **0** |

### 怎么验证能红

新判据（`tb_test_mode_ctrl.sv` 的**第二个实例**）：

```
双实例差分：
  dut32 : POLY_TARGET=32, TEST_N0..N3 = 4/8/16/32   → 断言 active_n == 4/8/16/32
  dut64 : POLY_TARGET=64, TEST_N0..N3 = 8/16/32/64  → 断言 active_n == 8/16/32/64
判据：dut64 在 n_code=2'b11 时必须 active_n == 64 且 voice_gate 的 popcount == 64
现在：dut64 会给出 active_n == 0、popcount == 0 ⇒ FAIL
```
⚠️ 若暂时不想动接口宽度，**最小替代**：加一条自检（见 P2-14），在 `POLY_TARGET > 63` 时直接 `$display("ERROR ...")` ⇒ 至少不再静默。

---

# P2-14 · `test_mode_ctrl.v` **全文没有任何参数自检**（同族模块全都有）

### 位置与代码

`rtl/w3b/test_mode_ctrl.v:19-22`（参数）

```verilog
 19:     parameter integer TEST_N0       = 4,
 20:     parameter integer TEST_N1       = 8,
 21:     parameter integer TEST_N2       = 16,
 22:     parameter integer TEST_N3       = 32
```

`rtl/w3b/test_mode_ctrl.v:86-87`（**文件末尾，没有任何 `initial`**）

```verilog
 86:     endgenerate
 87: 
 88: endmodule
```

对照（同族模块都有）：
- `oscillator_bank.v:902-926`（`LANES > 1024` / `TIMBRE_OK` / 扫频截断 / `DRUM_CLICK_EN`）
- `vibrato_lfo.v:133-140`（`DEPTH_ON > DEPTH_OFF` / `RATE_MAX ≥ RATE_MIN` / `CTRL_SLEW_DIV ≥ 1`）
- `clk_gen.v:54-75`（`is_pow2` 全套）

### 机制

`TEST_N0..N3` 直接决定 **`M4` 验收判据（谱峰数必须 = 4 / 8 / 16 / 32）** 的目标值。没有任何检查 ⇒ 以下全是**静默**的：

| 误配 | 后果 |
|---|---|
| `TEST_N0=32, TEST_N3=4` | `active_n_o` 对 code 00 报 32、对 code 11 报 4 ⇒ **验收表整个反了**，而 `tb_test_mode_ctrl.sv:142-145` 写死了 `check_mode(2'b00, 4)` ⇒ **它会红**（这一条有保护）；但**只例化 `top` 的端到端 tb** 没有这条断言 ⇒ 端到端**静默** |
| `TEST_N1=6`（非 2 的幂） | 6 个非相干音 ⇒ 谱峰数 6 ⇒ `M4` 期望表（4/8/16/32）对不上 |
| `TEST_N0=0` | Test Mode 打开却**没有任何音** ⇒ 静默静音 |
| `TEST_N2 > TEST_N3` | `active_n_o` 非单调，`'M'` 命令的"关→4→8→16→32→关"循环（`top.v:1369-1374`）语义错乱 |

### 具体怎么改

在 `endmodule` 前加：

```verilog
    initial begin
        if (!((TEST_N0 > 0) && (TEST_N0 <= TEST_N1) && (TEST_N1 <= TEST_N2) && (TEST_N2 <= TEST_N3)))
            $display("ERROR [test_mode_ctrl] TEST_N 必须满足 0 < N0 <= N1 <= N2 <= N3：%0d/%0d/%0d/%0d",
                     TEST_N0, TEST_N1, TEST_N2, TEST_N3);
        if ((TEST_N0 > POLY_TARGET) || (TEST_N3 > POLY_TARGET))
            $display("ERROR [test_mode_ctrl] TEST_N=%0d/%0d/%0d/%0d 超过 POLY_TARGET=%0d（会被 clamp，active_n_o 与设计意图不一致）",
                     TEST_N0, TEST_N1, TEST_N2, TEST_N3, POLY_TARGET);
        if (POLY_TARGET > 63)
            $display("ERROR [test_mode_ctrl] POLY_TARGET=%0d > 63：active_n_o 的 6 位宽会截断（见 K-106）",
                     POLY_TARGET);
        if (OSC_PER_VOICE < 1)
            $display("ERROR [test_mode_ctrl] OSC_PER_VOICE=%0d 非法", OSC_PER_VOICE);
    end
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 把 4 类静默误配变成启动 ERROR（`K-106` 口径） |
| 代价 | **0**（`initial` 不进网表） |
| 对 Fmax | **0** |

### 怎么验证能红

探针副本把 `TEST_N2` 改成 `8`（破坏单调），跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter test_mode
```
- 改前：**无任何 ERROR**（`tb_test_mode_ctrl` 只检查它自己传的 4/8/16/32）。
- 改后：必须打印单调性 ERROR。

---

# P2-15 · `vibrato_lfo` 的 `slew_count_q` 声明为 `integer` ⇒ **32 个 FF + 32 位加法器 + 32 位比较器**，只为数到 9

### 位置与代码

`rtl/w3b/vibrato_lfo.v:50`

```verilog
 50:     integer          slew_count_q;
```

`rtl/w3b/vibrato_lfo.v:85,108-109,122`

```verilog
 85:             slew_count_q   <= 0;
...
108:                 if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
109:                     slew_count_q <= 0;
...
122:                     slew_count_q <= slew_count_q + 1;
```

### 机制（数字）

`integer` = **32 位有符号**。实际取值范围是 `0 .. CTRL_SLEW_DIV-1` = **0..9**（`CTRL_SLEW_DIV=10`，`top.v:4150`）。

| 资源 | 当前 | 应为 | 差 |
|---|---|---|---|
| FF | **32** | **4**（`reg [3:0]`） | **−28 FF** |
| 加法器 | 32 位 ⇒ **16 ALU** | 4 位 ⇒ **2 ALU** | **−14 ALU** |
| 比较器 | 32 位 `>= 9` | 4 位 `>= 9` | LUT 从 ~8 降到 ~1 |

另外 `:122` 的 `slew_count_q <= slew_count_q + 1` 在 `CTRL_SLEW_DIV = 1` 时（`tb_vibrato_lfo.sv:17`）**永远走不到**（`:108` 的 `>= 0` 恒真），但综合器仍会建那个 32 位加法器。

⚠️ **诚实标注**：这是一条 **资源/面积**结论，**不是时序结论**。它不在最差路径上（`:108` 的比较器输出只驱动 `slew_count_q` 与一个 2:1 mux），但 **32 位加法器 + 32 位比较器 ≈ 30 个 LUT + 28 个 FF**，在当前 `CLS 78%`、最差余量 **+0.102 ns** 的环境下，**任何 LUT/FF 都是净负担**。

### 具体怎么改

```verilog
    localparam integer SLEW_W = $clog2(CTRL_SLEW_DIV + 1);   // 10 -> 4
    reg [SLEW_W-1:0]  slew_count_q;
    ...
    if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
        slew_count_q <= {SLEW_W{1'b0}};
    ...
    end else begin
        slew_count_q <= slew_count_q + 1'b1;
    end
```
⚠️ `CTRL_SLEW_DIV = 1` 时 `$clog2(2) = 1` ⇒ `reg [0:0]`，`>= 0` 恒真 ⇒ 行为不变 ✅。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | `FF −28`、`ALU −14`、`LUT −25~30` |
| 代价 | **0**（逐位等价；`CTRL_SLEW_DIV ≤ 16` 时完全等价，`> 16` 时宽度自动跟上） |
| 对 Fmax | 不体现在单条路径上，但降 LUT/FF 对 **+0.102 ns** 的全局余量单向有利 |

### 怎么验证能红

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter vibrato
```
`tb_vibrato_lfo.sv:78-80`（`110/120/130`）与 `:84`（phase 不被清零）**必须保持 PASS**。
反向验证：把 `reg [SLEW_W-1:0]` 改回 `integer` 之外，再故意把比较改成 `>`（而不是 `>=`）⇒ **78/79/80 必须红**（证明这条判据真的锁住了 slew 步长）。

---

# P2-16 · `voice.v` 的 `CLK_PER_SAMPLE` 是**死参数**：`voice_i2s_chain` 传了，`voice` 一次都没用

### 位置与代码

`rtl/w3b/voice.v:7`（声明）

```verilog
  7:     parameter integer CLK_PER_SAMPLE = 1024,
```
全文**再无第二处引用**（已 grep：仅 `:7`）。

`rtl/w3b/voice_i2s_chain.v:36` + `:51`（传了）

```verilog
 36:         .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
...
 51:         .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
```

`rtl/w3b/voice_i2s_chain.v:42`（**`clk_gen` 真的用它**）

```verilog
 42:         .tick_audio   (tick_audio_o),
```

### 机制

`voice` 只通过 `tick_audio`（时钟使能）感知采样率 ⇒ **它不需要 `CLK_PER_SAMPLE`**。但参数被留着并透传 ⇒ 造成"改了它就会生效"的错觉。

**具体后果**：把 `voice_i2s_chain.CLK_PER_SAMPLE` 从 `1024` 改成 `2048`：
- `clk_gen` 的 `tick_audio` 周期从 1024 拍变 2048 拍 ⇒ 采样率 **48.83 kHz → 24.41 kHz**（音高掉一个八度、I2S 时序全错）
- `voice` 内部**什么都不变**
- **零报错、零警告**

### 具体怎么改

**二选一**（⛔ 不要留着不说）：
- **删掉** `voice.v:7` 的 `CLK_PER_SAMPLE`，并从 `voice_i2s_chain.v:36` 的命名参数列表里去掉（`voice_i2s_chain` 自己的那个保留，因为 `clk_gen` 要用）。
- 或**加自检**：在 `voice.v` 里 `initial if (CLK_PER_SAMPLE < 2) $display("ERROR ...")` 并**在注释里写明"本参数当前未被使用"**（`K-106` 口径）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"改参数不生效"的静默陷阱；符合本项目 `K-106`（⛔ 不许静默失效） |
| 代价 | **0** |
| 对 Fmax | **0** |

### 怎么验证能红

机械判据：

```powershell
# 判据：CLK_PER_SAMPLE 在 voice.v 里出现次数必须 == 1（仅声明）或 == 0（已删）
(Select-String -Path rtl\w3b\voice.v -Pattern 'CLK_PER_SAMPLE').Count
```
- 当前：**1**（只有声明）⇒ 死参数确认。
- 改后：**0**（删掉）。

---

# P2-17 · `voice.v` 的 `SAMPLE_W = 24` 是**名义 24 位**，实际只有 **16 位有效**（低 8 位恒 0）

### 位置与代码

`rtl/w3b/voice.v:92` + `:101`

```verilog
 92:     wire signed [15:0] scaled_16 = scaled_wide[15:0];
...
101:                 sample_out <= {scaled_16, {(SAMPLE_W-16){1'b0}}};
```

`rtl/w3c/i2s_tx.v:136-142`（消费端只取高 16 位）

```verilog
136:     function [DATA_BITS-1:0] top_bits;
...
142:                 if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[SAMPLE_W-1-k];
```

`rtl/w3b/voice_i2s_chain.v:72-73`（`DATA_BITS = 16`）

```verilog
 72:         .SAMPLE_W  (24),
 73:         .DATA_BITS (16),
```

### 机制

`sample_out[7:0]` 由 `{(SAMPLE_W-16){1'b0}}` 驱动 ⇒ **恒为 0**（8 个常量零）。
`i2s_tx` 的 `top_bits` 取 `[SAMPLE_W-1 : SAMPLE_W-DATA_BITS]` = **`[23:8]`** ⇒ 正好是 `scaled_16` ✅ 所以**功能正确**。
但：
1. 模块对外宣称 `SAMPLE_W=24`、`sample_dbg_o[23:0]`，而**有效精度是 16 位**。
2. `adsr` 的 `ENV_W=16`、`wavetable` 的 `SAMPLE_W=16` ⇒ **整条链的真实精度是 16 位**，24 位是空壳。
3. 任何"读 `sample_dbg_o` 判断精度"的判据都会被误导（`sample_dbg_o[7:0]` 恒 0 是**可测的**）。

### 具体怎么改

**二选一**：
- 把 `SAMPLE_W` 改成 **16**，`i2s_tx` 的 `SAMPLE_W` 也改成 16（`top_bits` 取 `[15:0]`，行为**逐位不变**），`sample_dbg_o` 变 `[15:0]`。
- 或保留 24 位但在 `:101` 旁加注释写明"**低 8 位恒 0；有效精度 = 16 位（上游 `adsr`/波表都是 16 位）**"。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 口径诚实；若改成 16 位则 `sample_out` 的 8 个常量 FF 被省掉（**−8 FF/lane**） |
| 代价 | **0**（改 16 位是逐位等价：`i2s_tx` 的 `top_bits` 从 `[23:8]` 变 `[15:0]`，取到的都是 `scaled_16`） |
| 对 Fmax | **0**（`voice` 不在生产网表，见 P2-20） |

### 怎么验证能红

新断言（加进 `tb_dds_wavetable_core.sv` 或新 tb）：

```
断言 S1  voice.sample_out[7:0] 恒为 0（连续 ≥ 256 拍，含满幅包络）
断言 S2  若 SAMPLE_W 被改成 16，则 sample_out[15:0] 与旧 sample_out[23:8] 逐位相同
```
- 改前：**S1 必绿**（证明低 8 位是空壳）、**S2 无法评估**。
- 改后：**S2 必绿**（证明 24→16 是等价改写）。
- 反向：把 `:101` 改成 `{scaled_16, {(SAMPLE_W-16){1'b1}}}` ⇒ **S1 必红**（证明判据不是空判据）。

---

# P2-18 · `voice.v:78` 对 **`integer` 参数做位选**（`NOTE_VELOCITY[7:0]`）—— `K-91` 同族，且会**静默截断**

### 位置与代码

`rtl/w3b/voice.v:10` + `:78`

```verilog
 10:     parameter integer NOTE_VELOCITY  = 255,
...
 78:         .velocity_i    (NOTE_VELOCITY[7:0]),
```

对照纪律：`rtl/w3b/oscillator_bank.v:50` 明写

```verilog
 50: //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
```

### 机制（数字）

`NOTE_VELOCITY` 是 `integer`（32 位）。`NOTE_VELOCITY[7:0]` 取低 8 位。

| `NOTE_VELOCITY` | `[7:0]` | 实际力度 | 是否报错 |
|---|---|---|---|
| 255（当前） | `8'hFF` | 255 ✅ | — |
| **300** | `8'h2C` = **44** | **44** | 🔴 **不报** |
| **256** | `8'h00` = **0** | **0**（静音！） | 🔴 **不报** |
| **511** | `8'hFF` = 255 | 255 | 🔴 不报 |

⇒ `NOTE_VELOCITY=256`（一个非常自然的"满量程"写法）会让 `adsr` 的 `peak_level = {velocity_i, 8'b0} = 0` ⇒ **包络峰值恒为 0** ⇒ 整条 T10 链静音，**零报错**。

**当前状态**：`Gowin2026.gprj:76` 把 `voice.v` 列为 `enable="1"` ⇒ 它**会被 Gowin 编译**，而且**编译通过**（否则整个工程报错）。所以这一条不是"现在就坏"，是"**下一个改这个参数的人会静默踩坑**"，且与本文件自己引用的 `K-91` 纪律冲突。

### 具体怎么改

```verilog
    parameter [7:0] NOTE_VELOCITY  = 8'd255,     // ⭐ 直接声明成 8 位，⛔ 不做位选
```
并把 `:78` 改成 `.velocity_i(NOTE_VELOCITY)`。若必须保留 32 位语义，就加定宽常量：

```verilog
    localparam [7:0] NOTE_VELOCITY_W = NOTE_VELOCITY;   // 与 oscillator_bank 的 DRUM_KICK_MAX_C 同款
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"参数 >255 ⇒ 静默截断"；与 `K-91` 纪律一致 |
| 代价 | **0**（`8'd255` 与 `255[7:0]` 在当前值下逐位相同） |
| 对 Fmax | **0** |

### 怎么验证能红

机械判据（**比 tb 更硬**）：

```powershell
# 判据：参数声明为 integer 时，不得对其做位选
Select-String -Path rtl\w3b\voice.v -Pattern 'parameter integer NOTE_VELOCITY|NOTE_VELOCITY\['
```
- 当前：**两处都命中** ⇒ 违规确认。
- 改后：只剩一处（`parameter [7:0]`）。

**行为侧**：把 `NOTE_VELOCITY` 传 `256` 跑 `tb_dds_wavetable_core`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter dds
```
- 改前：`velocity_i = 0` ⇒ `env_level_o` 峰值 0 ⇒ **若 tb 没有"输出非零"的断言，它会绿**（这就是静默）。**先确认这个 tb 有没有这条断言**；没有就补一条 `env_level_o` 峰值 `> 0` 的断言。

---

# P2-19 · `tb/models/oscillator_bank_ref.v` **缺少 `DRUM_CLS_EXT` / `drum_cls_i`** ⇒ 生产档（`DRUM_CLS_EXT=1`）**没有逐位等价覆盖**

### 位置与代码

参考副本的端口列表（`tb/models/oscillator_bank_ref.v:193-240`）**没有 `drum_cls_i`**；参数列表（`:54-192`）**没有 `DRUM_CLS_EXT`**。
参考副本的鼓判据（`:404-406`）**只有 `bv` 比较那一路**：

```verilog
404:             wire is_kick_drum = lane_drum[g] && (base_inc <  DRUM_KICK_MAX_C);
405:             wire is_tom_drum  = lane_drum[g] && (base_inc >= DRUM_KICK_MAX_C)
406:                                              && (base_inc <  DRUM_TOM_MAX_C);
```

生产例化（`rtl/top.v:4214`）

```verilog
4214:             .DRUM_CLS_EXT     (1)
```

### 机制

`tb_p5_osc_equiv.sv:81-90` 例化 DUT 时**不传 `DRUM_CLS_EXT`** ⇒ 走默认 `0` ⇒ 与参考副本口径一致 ⇒ **判据绿**。
⇒ **"逐位等价"这句话的覆盖面是 `DRUM_CLS_EXT=0`，而生产用的是 `1`。**
⇒ `P5-②` 那次"算术上提"的等价性证明，**对生产档不成立**（虽然 `DRUM_CLS_EXT=1` 那一路的改动在 `:400-405` 是纯新增分支，风险低 —— 但**没有判据**）。

另外：`DRUM_CLS_EXT=0` 与 `=1` **本来就不等价**（前者按**变调后**的 `bv` 分类，后者按**提交时刻**的分类）—— `sim/evidence/a3-proper-20261008/README.md:25` 明写"鼓种由按的哪个键决定，⛔ 不被变调带走"。⇒ 这不是 bug，是**故意的语义差异**，但**必须有一条判据把它钉住**，否则将来没人知道两档的差异边界在哪。

### 具体怎么改

**（A）给参考副本加同款参数与端口**（同步纪律，与 `rightboard-vibrato-fix-20261008/README.md:77-83` 同一套路）：

```verilog
// oscillator_bank_ref.v：参数列表加
    parameter integer DRUM_CLS_EXT = 0
// 端口列表加
    input  wire [POLY_TARGET*2-1:0]  drum_cls_i,
// gen_voice 内 is_kick_drum/is_tom_drum 改成与 RTL 逐字相同的三目
```

**（B）`tb_p5_osc_equiv.sv` 加一对双实例差分**（`DRUM_CLS_EXT=1` 的 DUT vs `=1` 的参考），激励用 `tb_osc_drum_cls.sv` 已有的模式（`base` 与 `cls` 故意不一致）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | "逐位等价"这句话**覆盖生产档**；两档的语义差异边界被钉住 |
| 代价 | 参考副本 +~15 行；tb +1 个实例 |
| 对 Fmax | **0**（只在 tb 里） |

### 怎么验证能红

```
反向验证（必须做）：
  1. 在 (B) 的差分 tb 里，把 RTL 的 `(DRUM_CLS_EXT != 0) ? drum_cls_i[...] : (bv < ...)`
     的三目条件改成 `1'b1`（一律听外部）
  2. 断言：`DRUM_CLS_EXT=0` 的实例必须红（因为它不该听外部）
```
⚠️ 这与 `a3-proper-20261008/README.md:68` 记录的既有反向验证**同型**（"去掉参数门控 ⇒ B1/B2/B3 FAIL"），说明这套反向验证套路在本项目**已经跑通**，直接复用即可。

---

# P2-20 · `voice.v` / `voice_i2s_chain.v` 在 `Gowin2026.gprj` 里（`enable="1"`），但**不在 `rtl/top.v` 的网表里**

### 位置与证据

`Gowin2026.gprj:76-77`

```xml
        <File path="rtl/w3b/voice.v" type="file.verilog" enable="1"/>
        <File path="rtl/w3b/voice_i2s_chain.v" type="file.verilog" enable="1"/>
```

`rtl/top.v` **从不例化它们**（全仓 grep：唯一例化点是 `bringup/synth_check_top.v:341`）。
`sim/gowin_build.ps1:38-69` 的守卫**只做单向检查**（"`top.v` 例化的 ⇒ 必须在 gprj 里"），**不检查反向**（"gprj 里的 ⇒ 是否被 `top.v` 例化"）。

### 机制

| 后果 | 说明 |
|---|---|
| ✅ 好处 | 它们**不影响 Fmax**（不在网表）⇒ 本报告里针对 `voice.v` / `voice_i2s_chain.v` 的**所有时序类结论都不影响 51.5 MHz 门槛**（已在每条里标注） |
| 🔴 风险 | 它们**仍被 Gowin 编译** ⇒ 一个语法错误会**打断整个工程**（`K-91` 家族：`N'()` / `logic` / `always_ff` 会让"整个模块被丢弃而仿真全绿"，但那是在 `top.v` 的网表里；这里是"编译不过 ⇒ 工程报错"，**反而更安全**） |
| 🔴 风险 | 它们**没有任何综合/时序证据**，但 `Gowin2026.gprj` 把它们标成 `enable="1"` ⇒ **读者会以为它们在生产路径上**。`tdm_render_mixer.v:378` 与 `:440` 的注释就在拿 `voice_i2s_chain.v` 的接线当**论据**用 |

### 具体怎么改

**三选一，必须显式选一个**：
1. 从 `Gowin2026.gprj` 里删掉这两条（它们属于 `bringup/synth_check.gprj:50-51`，那里已经有一份）。
2. 保留，但在两个文件的头注释里**明写**"⚠️ 本文件不在 `rtl/top.v` 的网表里；只被 `bringup/synth_check_top.v` 例化；其 PnR 证据见 `bringup/`"。
3. 给 `sim/gowin_build.ps1` 加**反向守卫**：gprj 里 `enable="1"` 的文件若**未被任何顶层例化**，打 WARNING（不 FAIL，避免误伤）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"这两个模块在生产路径上"的错觉；`tdm_render_mixer.v` 的两处论证不再悬空 |
| 代价 | **0**（方案 2 只加注释；方案 3 加 ~10 行 PS） |
| 对 Fmax | **0** |

### 怎么验证能红

机械判据：

```powershell
# 判据：gprj 里 enable=1 的每个 rtl/*.v，都必须被 top.v 例化（或显式列入白名单）
$gprj = Select-String -Path Gowin2026.gprj -Pattern 'rtl/w3b/(voice|voice_i2s_chain)\.v.*enable="1"'
$inst = Select-String -Path rtl\top.v -Pattern '\bvoice\b|\bvoice_i2s_chain\b'
```
- 当前：`$gprj` 命中 **2** 条、`$inst` 命中 **0** 条 ⇒ 缺口确认。
- 改后（方案 1）：`$gprj` 命中 **0** 条。

---

# P3-21 · `oscillator_bank` 自己**违反**文件头写下的纪律：对 `integer` 参数做位选（`LANES[LW:0]`）

### 位置与代码

纪律（`rtl/w3b/oscillator_bank.v:50`）

```verilog
 50: //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
```

实际代码（`:259` 声明，`:714 / 729 / 734 / 742 / 876` 使用）

```verilog
259:     localparam integer LANES = POLY_TARGET * OSC_PER_VOICE;
...
714:     reg [LW:0]  cnt;          // 0 .. LANES（需要 LW+1 位才装得下 LANES）
729:             if (cnt == LANES[LW:0])
742:     wire          req_active = rendering && (cnt < LANES[LW:0]);
876:         end else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0])) begin
```

### 机制

`LANES` 是 `integer`（32 位有符号），`LANES[LW:0]` 是它的**位选**。
- **当前无害**：`LANES=64`，`LW=6`，`LANES[6:0] = 7'd64` ✅，`cnt` 也是 `[6:0]` ⇒ 比较正确。Gowin 与 Icarus 都接受（`Gowin2026.gprj` 里的 `oscillator_bank.v` 编译通过、位流已出）。
- **风险**：① 与同文件第 50 行的纪律**直接冲突** ⇒ 下一个维护者不知道该守哪条；② `LANES` 若变成非 2 的幂（如 96），`LW=7`、`LANES[7:0] = 96` ✅ 仍然对 —— 所以这个写法**恰好**是安全的；真正脆弱的是 `LW` 本身（`$clog2`）。

### 具体怎么改

统一口径（与 `:275-276` 的 `DRUM_KICK_MAX_C` 同一套路）：

```verilog
    localparam [LW:0] LANES_C = LANES;      // ⭐ 落定宽常量，⛔ 不对 integer 做位选
    ...
    if (cnt == LANES_C) ...
    wire req_active = rendering && (cnt < LANES_C);
```
并把 `:50` 的纪律注释补一句"本文件的 `LANES_C`/`DRUM_KICK_MAX_C`/`DRUM_TOM_MAX_C` 就是这条纪律的落地形式"。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 纪律与代码一致；`LANES_C` 是编译期常量 ⇒ **0 硬件** |
| 代价 | **0** |
| 对 Fmax | **0** |

### 怎么验证能红

```powershell
# 判据：出现 `LANES[` 即违规（应只剩 LANES_C 的声明处）
Select-String -Path rtl\w3b\oscillator_bank.v -Pattern 'LANES\['
```
- 当前：**命中 4 处**（714/729/742/876 里的 `LANES[LW:0]`，其中 714 是注释）⇒ 违规确认。
- 改后：**0 处**。
- 功能侧：`tb_p5_osc_equiv` 必须仍 PASS（`LANES_C` 与 `LANES[LW:0]` 同值）。

---

# P3-22 · `oscillator_bank` 的 33 位输入**从未被读**；`integer si` 声明未用

### 位置与代码

`rtl/w3b/oscillator_bank.v:251-253`（端口）

```verilog
251:     input  wire                                             fm_cfg_valid_i,
252:     input  wire [15:0]                                      fm_ratio_i,
253:     input  wire [15:0]                                      fm_index_i,
```

全文**没有第二处引用**（已 grep：只有 `:251-253` 的声明与 `:893` 的注释）。
`rtl/w3b/oscillator_bank.v:871`

```verilog
871:     integer si;
```
全文**没有第二处引用**（`tb/models/oscillator_bank_ref.v:750` 是同一份副本里的同一个死变量）。

`rtl/w3b/oscillator_bank.v:893-894`（注释承认了，但只是"说明"，没有自检之外的强制）

```verilog
893:     //  · `fm_cfg_valid_i` / `fm_ratio_i` / `fm_index_i`：`ENABLE_FM=0` ⇒ **忽略**
894:     //    （`A2c`：先留接口、后加，且**不计入吞吐量**）。
```

`rtl/top.v:4250-4252`（顶层接常量 ⇒ 综合器会折掉）

```verilog
4250:             .fm_cfg_valid_i     (1'b0),
4251:             .fm_ratio_i         (16'd0),
4252:             .fm_index_i         (16'd0),
```

### 机制

- 端口：**33 位未读输入**。当前顶层接常量 0 ⇒ 综合器把端口折掉 ⇒ **0 硬件**。但**任何直接例化 `oscillator_bank` 的 tb** 都必须接它们（否则 `default_nettype none` 下会报未连接，或接 `z`）⇒ 这是**接口债务**，`A2c` 已经记录。
- `integer si`：未使用的仿真变量。`iverilog -Wall` 可能报警（`sim/tb_all.ps1:119` 用了 `-Wall`，但**只对 tb 编译**；`rtl/` 也在编译命令行里 ⇒ 理论上会出警告）。**它不产生硬件**，但它是"复制粘贴遗留"的证据。

### 具体怎么改

- `si`：**直接删**（`oscillator_bank.v:871` 与 `oscillator_bank_ref.v:750` 两处）。
- FM 三端口：**保留**（`A2c` 是有意为之），但在 `:893` 的说明里补一句**硬口径**："`ENABLE_FM != 0` 时本模块**不会**做任何 FM ⇒ 该参数当前是**空开关**"（`:908-910` 已有 WARNING，把它升级为与 `K-106` 一致的措辞即可）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 清掉 1 个死变量 ×2 份；把"FM 参数是空开关"变成显式口径 |
| 代价 | **0** |
| 对 Fmax | **0** |

### 怎么验证能红

```powershell
# 判据：`integer si;` 不得出现在两个文件里
Select-String -Path rtl\w3b\oscillator_bank.v,tb\models\oscillator_bank_ref.v -Pattern 'integer si;'
```
- 当前：**命中 2 处** ⇒ 确认。
- 改后：**0 处**。

---

# P3-23 · `DBG_LANE` **没有范围自检**；越界时 `lane_phase[DBG_LANE*PHASE_W +: PHASE_W]` 出 `x` / 综合报错

### 位置与代码

`rtl/w3b/oscillator_bank.v:94`

```verilog
 94:     parameter integer DBG_LANE      = 0,
```

`rtl/w3b/oscillator_bank.v:885`

```verilog
885:     assign phase_acc_dbg_o  = lane_phase[DBG_LANE*PHASE_W +: PHASE_W];
```

`lane_phase` 的宽度（`:289`）

```verilog
289:     wire [LANES*PHASE_W-1:0] lane_phase;     // 供调试观测
```

`rtl/w3b/oscillator_bank.v:902-926` 的 `initial` 自检里**没有 `DBG_LANE`**。

### 机制

`lane_phase` 是 `[LANES*PHASE_W-1:0]` = `[2047:0]`。
`DBG_LANE = 64` ⇒ 索引 `[2048 +: 32]` ⇒ **完全越界**。
- 仿真：`phase_acc_dbg_o` = `32'hxxxxxxxx`（`tb_p5_osc_equiv.sv:143-146` 比 `ref_dbg !== dut_dbg` ⇒ 两侧同为 `x` 时会**恰好相等**，判据**不会红**）。
- 综合：Gowin 对越界位选的行为**未定义**（可能报错、可能给常量 0）。

⇒ 这是 `K-106`（⛔ 不许静默失效）的又一个缺口：**参数越界没有任何提示**。

### 具体怎么改

```verilog
        if ((DBG_LANE < 0) || (DBG_LANE >= LANES))
            $display("ERROR [oscillator_bank] DBG_LANE=%0d 越界（合法 0..%0d）", DBG_LANE, LANES-1);
```

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 把越界从"静默 x"变成"启动 ERROR" |
| 代价 | **0**（`initial`） |
| 对 Fmax | **0** |

### 怎么验证能红

探针副本把 `DBG_LANE` 传 `64`，跑 `sim\tb_all.ps1 -Filter p5_osc_equiv`：
- 改前：**无 ERROR**，且 `ref_dbg !== dut_dbg` 两侧同为 `x` ⇒ **判据绿**（假绿）。
- 改后：必须打印 ERROR。
- 反向：`DBG_LANE=63` ⇒ 必须不打印。

---

# P3-24 · `test_mode_ctrl` 的 `clk_i` / `sample_tick_i` **未被使用**；输出**组合直通跨模块**进入相位增量 mux

### 位置与代码

`rtl/w3b/test_mode_ctrl.v:24-26`（两个输入端口）

```verilog
 24:     input  wire                                         clk_i,
 25:     input  wire                                         rst_n_i,
 26:     input  wire                                         sample_tick_i,
```

全文**没有任何 `always @(posedge clk_i)`**（唯一的时序块是 `:48-55` 的 `always @(*)`）。
`rtl/w3b/test_mode_ctrl.v:57-62`（组合输出）

```verilog
 57:     // Combinational configuration is intentional: disabling Test Mode mutes
 58:     // every test output immediately, and a mode switch settles within one
 59:     // sample period. clk_i/sample_tick_i remain on the frozen interface for
 60:     // integration symmetry with the rendering chain.
 61:     wire mode_enabled = rst_n_i & enable_i;
 62:     assign active_n_o = mode_enabled ? selected_n_r : 6'd0;
```

消费侧（`rtl/w3b/oscillator_bank.v:569-571`，**同一拍**）

```verilog
569:             wire [PHASE_W-1:0] lane_inc = test_mode_i
570:                              ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
571:                              : lane_inc_base;
```

### 机制

**（a）未使用端口**：`clk_i` / `sample_tick_i` 各 1 位未读。`rst_n_i` 被 `:61` 用（组合）。这是 `K-88` 家族（"静默忽略输入"），但注释 `:57-60` **显式说明了理由** ⇒ 口径可接受，**只需补一条自检或注释里的"当前不参与逻辑"字样**（`:57-60` 已经写了）。

**（b）组合直通（跨模块穿透）**：路径 = `top.v` 的 `tm_n_code_r`（寄存器）→ `test_mode_ctrl` 的 `always @(*)` case（6 位 4:1 mux）→ `v < selected_n_r`（6 位比较 × 32）→ `selected` → `test_phase_inc_o`（2048 位）→ **跨模块** → `oscillator_bank` 的 `lane_inc` mux → **相位累加器的加法器**。
⇒ **这条链在同一个 50 MHz 拍内从 `note_manager`/`top` 的寄存器一直穿到相位累加器，中间没有任何寄存级。**
⚠️ **`syn_keep` 只加在 `selected` 上**（`:72`），**没有加在 `selected_n_r`**（6 位，扇出 32 个比较器 + `active_n_o`）⇒ 依赖工具自动复制。
**安全边界**：相位只在 `sample_tick_i` 更新，而 `tm_n_code_r` 由 UART 命令驱动（远慢于采样）⇒ **功能上安全**；风险是**这条链是"看起来短、实际跨模块 + 大扇出"**的典型，一旦 `test_mode_ctrl` 被放在远处就会变长。

### 具体怎么改

- **（a）**：在 `:57-60` 的注释里加一句"⚠️ `clk_i` / `sample_tick_i` **当前不参与任何逻辑**（纯接口对称）"—— 已经是这个意思，补个"当前不参与逻辑"的明确字样即可。
- **（b）低风险改法**：在 `top.v` 里把 `test_mode_ctrl` 的三个输出**各打一拍**再送 `oscillator_bank`（3 × 1 位 + 2048 位 + 256 位 ⇒ **+2304 FF**，太贵）；**更便宜**：只给 `test_phase_inc_o` 打一拍（2048 FF）。
  ⚠️ **代价必须算清**：打一拍后 `test_mode` 与 `test_phase_inc` **不同拍**，会与 `oscillator_bank.v:668` 的 `!test_mode_i` 门控**错位一拍** ⇒ 进/出 Test Mode 的那一拍行为变化 ⇒ **必须先跑 `tb_top_test_mode_pipe` / `tb_test_mode_top`**。
- **（c）零成本改法（推荐）**：只在 `selected_n_r` 上加 `(* syn_keep = 1 *)`（与 `selected` 同款），把"复制多少份"的控制权从工具手里拿回来。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| (c) 收益 | `selected_n_r` 的复制点显式化，避免 33 个负载共用一个远端驱动 |
| (c) 代价 | **0**（一个属性） |
| (b) 收益 | 把跨模块链切成两段 |
| (b) 代价 | **+2048 FF** + **进出 Test Mode 的错位风险** ⇒ 当前**不建议做** |

### 怎么验证能红

```powershell
# 判据：clk_i / sample_tick_i 在 test_mode_ctrl.v 里除声明外无引用
Select-String -Path rtl\w3b\test_mode_ctrl.v -Pattern 'clk_i|sample_tick_i'
```
- 当前：`clk_i` 命中 **1** 次（声明）、`sample_tick_i` 命中 **1** 次（声明）+ `:59` 注释 ⇒ 死端口确认。
- (b) 的判据：`tb_top_test_mode_pipe` 必须保持 PASS；`tb_test_mode_top` / `tb_test_mode_fft` 必须全绿。

---

# P3-25 · `voice_i2s_chain` 把 `clk_gen` 的 `mclk_en` / `lrclk` 引出来**然后悬空**

### 位置与代码

`rtl/w3b/voice_i2s_chain.v:29-32`（声明）

```verilog
 29:     wire mclk_en;
 30:     wire bclk_en;
 31:     wire bclk_half_en;
 32:     wire lrclk;
```

`rtl/w3b/voice_i2s_chain.v:43-47`（`clk_gen` 驱动它们）

```verilog
 43:         .mclk_en      (mclk_en),
 44:         .bclk_en      (bclk_en),
 45:         .bclk_half_en (bclk_half_en),
 46:         .lrclk        (lrclk),
 47:         .frame_start  (frame_start)
```

全文**再没有任何引用** `mclk_en` 或 `lrclk`（`bclk_en`/`bclk_half_en`/`frame_start` 都送进了 `i2s_tx`）。

### 机制

- `lrclk`：`i2s_tx` **自带** WS 生成（它用 `frame_start` + `bclk_half_en`，没有 `lrclk` 输入端口）⇒ `clk_gen.lrclk` 是**冗余输出**。
- `mclk_en`：**12.5 MHz MCLK 使能**被算出来却没人用 ⇒ 这个 chain **不输出 MCLK**。
  - 对 `PT8211` 无害（它从 BCK 派生）。
  - 对**需要 MCLK 的 DAC**（如某些 `PCM5102A` 模块、`AK4490` 类）⇒ **必须外接 MCLK**，而这条 chain **拿不到**。
  ⇒ 这是一个**功能缺口**，不只是"死信号"。

### 具体怎么改

- **二选一**：① 删掉 `mclk_en` / `lrclk` 两个 wire 声明，并把 `clk_gen` 的对应端口留空（`.mclk_en()` / `.lrclk()`）；② 保留并在 `:29-32` 旁写"⚠️ 当前未使用：`mclk_en`（本 chain 不输出 MCLK，PT8211 不需要）/ `lrclk`（`i2s_tx` 自带 WS）"。
- 若将来要驱动需要 MCLK 的 DAC：把 `mclk_en` 引到一个 `HP_MCLK` 输出脚（`clk_gen.v:34` 的注释已经定义了它是 12.5 MHz = 256 × fs ✅）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"这条 chain 有 MCLK"的错觉；明确 DAC 兼容边界 |
| 代价 | **0** |
| 对 Fmax | **0**（不在生产网表） |

### 怎么验证能红

```powershell
# 判据：mclk_en / lrclk 在 voice_i2s_chain.v 里必须出现 == 1 次（仅声明）或 == 0 次（已删）
Select-String -Path rtl\w3b\voice_i2s_chain.v -Pattern 'mclk_en'
Select-String -Path rtl\w3b\voice_i2s_chain.v -Pattern 'lrclk'
```
- 当前：各命中 **2** 次（声明 + 连接）⇒ 悬空确认（**有连接、无消费者**）。
- 改后：各 **0** 次。

---

# P3-26 · `vibrato_lfo`：**rate 有 slew 限幅、depth 没有** ⇒ `depth_q` 一步从 0 跳到 32760（或一步归 0）

### 位置与代码

**rate 有限幅**（`rtl/w3b/vibrato_lfo.v:108-120`）

```verilog
108:                 if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
110:                     if (rate_inc_q < rate_target_w) begin
111:                         if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
112:                             rate_inc_q <= rate_inc_q + RATE_SLEW_STEP;
```

**depth 没有**（`rtl/w3b/vibrato_lfo.v:92-102`）

```verilog
 92:                 if (depth_active_r) begin
 93:                     if (depth_raw_i <= DEPTH_OFF) begin
 94:                         depth_active_r <= 1'b0;
 95:                         depth_q        <= 16'd0;          // ⭐ 一步归 0
 96:                     end else begin
 97:                         depth_q <= depth_target_w;        // ⭐ 一步到目标
 98:                     end
 99:                 end else if (depth_raw_i >= DEPTH_ON) begin
100:                     depth_active_r <= 1'b1;
101:                     depth_q        <= depth_target_w;     // ⭐ 一步到目标
102:                 end
```

### 机制（数字）

- rate：每次 commit 最多动 `RATE_SLEW_STEP = 16`（`RATE_MIN_INC=86` → `RATE_MAX_INC=1031`，跨度 945）⇒ **最少 60 次 commit = 30 ms** 才走完全程（`CTRL_SLEW_DIV=10` × 2 kHz commit ⇒ 每 **5 ms** 一步）。
- depth：`depth_raw` 从 96 到 4095 ⇒ `depth_q` 从 **768** 一步跳到 **32760**（**+42×**），或从 32760 一步归 **0**。

⇒ **非对称设计**。后果不是"咔声"（相位连续，`:88` 的 `phase_q <= phase_q + rate_inc_q` 不受 depth 影响），而是**颤音深度的瞬变**：
- 若用户在推子中间抖动，`depth_q` 会随每个 commit（**0.5 ms**）跳变 ⇒ 颤音幅度**以 2 kHz 更新、无平滑** ⇒ 听感上像"颤音在抖"（尤其在死区边界 96/64 附近来回穿越时，`depth_q` 会在 768 与 0 之间反复跳）。
- 死区（64..95）能防住**端点断续**（`:9-10` 的注释就是这个目的），但**防不住"深度抖动"**。

### 具体怎么改

镜像 rate 的 slew 结构给 depth 加一级限幅（复用同一个 `slew_count_q` 节拍）：

```verilog
    localparam [15:0] DEPTH_SLEW_STEP = 16'd256;   // 每 5 ms 最多动 256（满量程 32760 ⇒ 约 0.64 s 走完）
    ...
                    if (depth_active_r) begin
                        if (depth_raw_i <= DEPTH_OFF) begin
                            depth_active_r <= 1'b0;
                            depth_q        <= 16'd0;
                        end else if (depth_target_w > depth_q + DEPTH_SLEW_STEP) begin
                            depth_q <= depth_q + DEPTH_SLEW_STEP;
                        end else if (depth_q > depth_target_w + DEPTH_SLEW_STEP) begin
                            depth_q <= depth_q - DEPTH_SLEW_STEP;
                        end else begin
                            depth_q <= depth_target_w;
                        end
                    end
```

⚠️ **代价**：`tb_vibrato_lfo.sv:66-73` 的 4 条断言用**单次 commit** 检查 depth 是否立即生效：
```verilog
 66:        depth_raw = 12'd120; commit;
 67:        chk("depth reaches ON threshold and enables vibrato", depth_active);
```
`:67` 只查 `depth_active`（不受限幅影响）✅；但若有限幅，`depth_q` 会从 0 开始爬 ⇒ **`mod` 的幅度会小很多** ⇒ `:93-96` 的三角波符号检查可能受影响（它们用的是 `fast_dut` 且 `depth_raw = 12'hFFF`，`commit` 只做 1 次 ⇒ 限幅下 `depth_q` 只爬到 256/32760 = 0.8% ⇒ **`fast_mod` 会变成 0** ⇒ **`:93` `fast_mod > 0` 直接 FAIL**）。

⇒ **加限幅会打红 `tb_vibrato_lfo` 的 4 条三角波断言** ⇒ 必须同步改 tb（把 `commit` 换成"跑够时间让 depth 爬满"）。**契约变更，必须显式记录。**

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 消除"推子抖动 ⇒ 颤音幅度抖"；depth 与 rate 口径一致 |
| 代价 | **16 位比较 + 16 位加/减**（~32 LUT）；🔴 **打红 `tb_vibrato_lfo.sv:93-96` 四条**，必须同步改 tb |
| 对 Fmax | **0**（不在最差路径上） |

### 怎么验证能红

```
新判据（加进 tb_vibrato_lfo）：
  D1  一次 commit 后 depth_q 的变化量 <= DEPTH_SLEW_STEP
  D2  连续 200 次 commit 后 depth_q 到达 depth_target_w（证明它最终会到）
  D3  depth 在死区边界（96↔64）反复穿越时，depth_q 的相邻差 <= DEPTH_SLEW_STEP
反向验证：把 DEPTH_SLEW_STEP 改成 16'hFFFF（等于没限幅）⇒ D1/D3 必须红
```

---

# P3-27 · `PHASE_QUARTER` 的写法在 `PHASE_W < 2` 时是**非法重复次数**

### 位置与代码

`rtl/w3b/oscillator_bank.v:277-280`

```verilog
277:     //  ⭐⭐ 2026-10-04（P5-②）：⭐ **1/4 周期初相** —— ⭐ 原来写在 lane 里，
278:     //     ⭐ 现在提成**共享常量**（⭐ 只有 `OSC_IDX==1` 那个 lane 用它 ✅）
279:     //   📌 语义见下方 `phase_seed` 的长注释（⭐ "起音时一个是 sin、一个是 cos" ✅）
280:     localparam [PHASE_W-1:0] PHASE_QUARTER = {{(PHASE_W-2){1'b0}}, 2'b01} << (PHASE_W - 2);
```

参考副本里的**等价但更直白**的写法（`tb/models/oscillator_bank_ref.v:477`）

```verilog
477:                 ? ({{(PHASE_W-2){1'b0}}, 2'b01} << (PHASE_W - 2))   // ⭐ 1/4 周期
```

### 机制

- `PHASE_W = 32`（`top.v:4166` 显式传 32）⇒ `{{30{1'b0}}, 2'b01} = 32'h0000_0001`，左移 30 ⇒ **`32'h4000_0000`** ✅ 正确。
- **脆弱点**：`(PHASE_W-2)` 是**重复次数**。`PHASE_W = 1` ⇒ `{(-1){1'b0}}` ⇒ **非法**（IEEE 1364-2001 §4.1.1：重复次数必须是常数表达式且 ≥ 0；负值报错）。
- `PHASE_W = 2` ⇒ `{{0{1'b0}}, 2'b01} << 0` = `2'b01` ⇒ "1/4 周期"实际是 **1/4 周期**（2 位累加器的 1/4 = 0.5 ⇒ 取整 1）⇒ 巧合正确。
- 更直白的等价写法：`localparam [PHASE_W-1:0] PHASE_QUARTER = {2'b01, {(PHASE_W-2){1'b0}}};`（把 `2'b01` 放在**高位**，不依赖移位）—— **`PHASE_W ≥ 2` 时与现写法逐位相同**，且读起来就是"1/4 周期 = 最高两位是 01"。

### 具体怎么改

```verilog
    localparam [PHASE_W-1:0] PHASE_QUARTER = (PHASE_W >= 2)
                                           ? {2'b01, {(PHASE_W-2){1'b0}}}
                                           : {PHASE_W{1'b0}};
```
⚠️ 注意 `(PHASE_W >= 2)` 是**编译期常量** ⇒ 综合器直接折掉没选中的那支；且 `PHASE_W < 2` 时 `{(PHASE_W-2){...}}` 这一支**仍然会被 elaboration 求值**吗？在 Verilog 里三目表达式的**两支都要能 elaborate**，所以 `{(-1){1'b0}}` 仍可能报错。⇒ **更稳的做法是显式断言**：

```verilog
    initial if (PHASE_W < 2)
        $display("ERROR [oscillator_bank] PHASE_W=%0d < 2 ⇒ PHASE_QUARTER 的重复次数非法", PHASE_W);
```
并保留现写法（当前 `PHASE_W=32`，`K-106` 口径下"显式报错"比"改写"更小风险）。

### 预期收益 / 代价

| 项 | 值 |
|---|---|
| 收益 | 参数越界时**启动即报错**，而不是 elaboration 崩 |
| 代价 | **0** |
| 对 Fmax | **0** |

### 怎么验证能红

探针副本把 `PHASE_W` 传 `1`，跑 `sim\tb_all.ps1 -Filter p5_osc_equiv`：
- 改前：**elaboration 阶段报错**（iverilog 的 `{(-1){...}}` 会给出 "Illegal number of repetitions"）或给出 `x` ⇒ 现象不定。
- 改后：必须先打印 `ERROR [oscillator_bank] PHASE_W=1 < 2`。
- 反向：`PHASE_W=32` ⇒ 必须不打印，且 `tb_p5_osc_equiv` PASS。

---

# P3-28 · `sample_bus_r` 的**变址写入**用了 64 个 7 位比较器；改成**移位寄存器**可省掉全部译码器（功能逐位不变）

### 位置与代码

`rtl/w3b/oscillator_bank.v:870-879`

```verilog
870:     reg [LANES*OSC_SAMPLE_W-1:0] sample_bus_r;
871:     integer si;
872: 
873:     always @(posedge clk_i) begin
874:         if (!rst_n_i) begin
875:             sample_bus_r <= {(LANES*OSC_SAMPLE_W){1'b0}};
876:         end else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0])) begin
877:             sample_bus_r[(cnt-1)*OSC_SAMPLE_W +: OSC_SAMPLE_W] <= rom_dout;
878:         end
879:     end
```

### 机制（数字）

`:877` 是**变量下标的部分选择写**：综合出
- **64 个 7 位比较器**（`cnt-1 == k`，k=0..63）⇒ 每个约 2 个 LUT4 ⇒ **≈128 LUT4**
- **64 × 16 = 1024 个 FF，每个带独立使能** ⇒ 1024 个使能网
- `rom_dout`（16 位）**扇出 1024**（每 lane 一份）

**等价改写**：lane `k` 的样本在 `cnt == k+1` 那一拍写入槽 `k`；从 `cnt=1` 到 `cnt=64` 依次写入 `rom_dout`。⇒ 槽 `0` 最先写、槽 `63` 最后写 ⇒ **等价于一条"从高位移入"的移位寄存器**：

```verilog
    always @(posedge clk_i) begin
        if (!rst_n_i)
            sample_bus_r <= {(LANES*OSC_SAMPLE_W){1'b0}};
        else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0]))
            sample_bus_r <= {rom_dout, sample_bus_r[LANES*OSC_SAMPLE_W-1:OSC_SAMPLE_W]};
    end
```
验算：第一次移入（`cnt=1`，`rom_dout` = lane 0）⇒ 槽 63（**最高 16 位**）得到 lane 0 ✅（因为 `{rom_dout, bus[1023:16]}` 把 `rom_dout` 放在 `[1023:1008]` = 槽 63）。
第二次（`cnt=2`，lane 1）⇒ 槽 62 得到 lane 1，槽 63 保持 lane 0 ✅。
…第 64 次（`cnt=64`，lane 63）⇒ 槽 0（最低 16 位）得到 lane 63 ✅。
⇒ **最终 `sample_bus_r[k*16 +: 16]` = lane k 的样本，与现写法逐位相同** ✅

| 项 | 现写法 | 移位寄存器写法 |
|---|---|---|
| FF | 1024 | **1024**（不变） |
| 译码器 | **64 × 7 位比较器 ≈ 128 LUT4** | **0** |
| 写使能网 | 64 组 | **1 组**（全寄存器共用一个使能） |
| `rom_dout` 扇出 | 1024 | **16**（只喂最高 16 位） |

⚠️ **代价（必须算清）**：移位寄存器**每拍都让全部 1024 个 FF 翻转**（使能有效期间），而变址写入**只翻转 16 个**。
- 使能有效的拍数 = `LANES` = **64 拍 / 帧**（一帧 1024 拍 ⇒ **6.25%** 的时间）
- 翻转量：64 拍 × 1024 FF = **65 536 次/帧** vs 现写法 64 × 16 = **1 024 次/帧** ⇒ **动态功耗升约 64 倍**（但只占 6.25% 的时间，绝对量仍小）
- ⚠️ **功耗是 `Gowin2026.power.html` 可查的量** ⇒ 必须实测对比再决定

### 具体怎么改

见上方代码。若功耗不可接受，退而求其次：**保留变址写入，但把 64 个比较器换成 `cnt` 的二进制译码树**（`cnt-1` 的 6→64 译码），代价从 64 个 7 位比较器（~128 LUT4）降到 1 个 6→64 译码器（~64 LUT4）。收益减半但**零功耗代价**。

### 预期收益 / 代价

| 方案 | 收益 | 代价 |
|---|---|---|
| 移位寄存器 | `LUT −128`；`rom_dout` 扇出 1024 → 16（**对布线有利**） | 动态翻转 ×64（占 6.25% 时间）⇒ 必须查 `power.html` |
| 译码树 | `LUT −64` | **0** |

### 怎么验证能红

**功能判据（必须逐位，不能只看波形）**：
```
在 tb_p5_osc_equiv 里，`osc_sample_bus_o` 已经被逐位比对（:131-138）
⇒ 改完只要 `tb_p5_osc_equiv` PASS，就证明"lane k → 槽 k"的映射没变 ✅
```
**反向验证（证明这条判据不是空判据）**：把移位方向写反（`{sample_bus_r[1022:0], rom_dout}`）⇒ `tb_p5_osc_equiv` 的 `osc_sample_bus mismatch` **必须红**（且应报出全部 64 条 lane 的差异）。

**资源判据**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT,ALU,ROM16'
```
- 判据：`LUT` 下降 **≥64**（译码树）或 **≥100**（移位寄存器）。
- 功耗判据：`impl/pnr/Gowin2026.power.html` 的 dynamic power 对比（移位寄存器方案必须查）。

---

# 附录 A · 已核对但**判定为非缺陷**的项（避免后来者重复排查）

| # | 位置 | 核对结论 |
|---|---|---|
| A1 | `oscillator_bank.v:469-471` 的 `bv + vib_off[31:0] + so_v` 与 `tb/models/oscillator_bank_ref.v:389-391,446` 的 33 位有符号写法 | **等价**。加法在 mod 2³² 下结合交换 ⇒ "33 位有符号和截断到 32 位" 与 "32 位无符号和" 逐位相同。`tb_p5_osc_equiv` 320 帧 0 mismatch 是实证 |
| A2 | `oscillator_bank.v:446-447` 的 `{{(PHASE_W-DRUM_SWEEP_W){1'b0}}, sweep_q} << DRUM_SWEEP_LSB_SH` 在 `LSB_SH=8` 时是否丢位 | **不丢**。`sweep_q` 占 `[15:0]`，左移 8 后占 `[23:8]`，32 位内 ✅。**但缺溢出检查**（见 P2-11） |
| A3 | `oscillator_bank.v:787-794` 的 `resp_drum_q` 与 ROM 数据的对齐 | **对齐正确**。`req_active`/`req_drum` 在第 T 拍被采样，`rom_dout`（`READ_MODE=1'b0`，1 拍延迟）在第 T+1 拍给出同一条 lane 的数据 ⇒ 标签与数据同拍 ✅ |
| A4 | `oscillator_bank.v:876-877` 的 `(cnt-1)` 槽位映射与 `:734` 的 `valid_r` 时序 | **正确**。`cnt==64` 那拍写入槽 63，同拍 `valid_r` 置位 ⇒ 下一拍 `valid_r=1` 时槽 63 已是 lane 63 ✅ |
| A5 | `oscillator_bank.v:400-405` 的 `drum_cls_i` **没有** `=== 1'b1` 解码（对比 `:399` / `:443` / `:707` 都用了 `===`） | **不是缺陷**。`(DRUM_CLS_EXT != 0)` 是编译期常量 ⇒ `DRUM_CLS_EXT=0`（所有 tb）时 `drum_cls_i` **不参与综合**、Z 悬空不传播 ✅（`:244-245` 的注释已说明） |
| A6 | `oscillator_bank.v:805-812` 的 `blend_*` 在 `VELOCITY_BLEND_EN=0` 时的行为 | **正确且被折叠**。`mix_q = FIXED_BLEND_Q_W = 0` ⇒ `blend_product = 0` ⇒ `blend_scaled = 0` ⇒ `blend_sum = rom_soft` ⇒ 那个 17×9 乘法器被整块折掉 ✅。**但注释自相矛盾**（见 P1-10） |
| A7 | `vibrato_lfo.v:75` 的 `mod_product[30:15]` 与 `:53` 的三角波幅值 | **正确**。Q1.15 × Q1.15 = Q2.30，取 `[30:15]` = Q1.15 ✅；`tri_mag` 满幅 32767、取负后 −32767，不产生 −32768 的不对称 ✅ |
| A8 | `vibrato_lfo.v:39` 的 `{12'd0, rate_span}` 在 `rate_span` 是常量时是否真的建了 44 位乘法 | **未确定，必须实测**（见 P0-2 的判据）。已按"工具可能自动收窄"标注 |
| A9 | `voice.v:86-92` 的"负数加 65535 再 `>>>16`"是否真的实现"向零取整" | **正确**。`p<0` 时 `(p+65535)>>>16`：`p=−1` ⇒ `65534>>>16 = 0`（向零 ✅）；`p=−65536` ⇒ `−1>>>16 = −1`（精确值 −1 ✅） |
| A10 | `voice.v:101` 的 `{scaled_16, 8'b0}` 与 `i2s_tx.top_bits()` 的取位 | **对齐正确**。`top_bits` 取 `[23:8]` = `scaled_16` ✅（`rtl/w3c/i2s_tx.v:136-142`）。**但名义 24 位是空壳**（见 P2-17） |
| A11 | `test_mode_ctrl.v:37-38` 的 FFT bin 常量 | **精确正确**。`PHASE_INC_BASE = 32'h0280_0000` = `80 × 2^19` ✅；`PHASE_INC_STEP = 32'h03A8_0000` = `117 × 2^19` ✅；最高音 `v=31` ⇒ `1 943 535 616` ⇒ `22 095.0 Hz` < Nyquist `24 414 Hz` ✅（余量 9.5%） |
| A12 | `test_mode_ctrl.v:72` 的 `(* syn_keep = 1 *)` | **有效且必要**（`:69-71` 的注释说明"不要合并成一根扇出数百的控制网"）。⚠️ 但**没有覆盖 `selected_n_r`**（见 P3-24） |
| A13 | `tb/models/oscillator_bank_ref.v` 与 `rtl/w3b/oscillator_bank.v` 的**颤音流水同步** | **已同步**（RTL `:322-333` vs ref `:293-304`，逐字相同）✅ 历史坑当前**没有踩** |
| A14 | `tb/models/oscillator_bank_ref.v` 与 RTL 的 `PHASE_QUARTER` | **语义等价**（RTL 提成 `localparam`，ref 内联；两者 `PHASE_W=32` 时都是 `32'h4000_0000`）✅ |
| A15 | `tb/models/oscillator_bank_ref.v` 的**整体同步状态** | **除 `DRUM_CLS_EXT`/`drum_cls_i` 外逐字同步**（已通读两文件 930 / 809 行）。⇒ 唯一未同步项就是 P2-19，**没有"基线漂移"** ✅ |

---

# 附录 B · 当前交付树的关键数字（后续对照用）

| 项 | 值 | 来源 |
|---|---|---|
| Setup 违例 / Hold 违例 | **0 / 0** | `sim/evidence/gowin_m0_timing.txt:16-19` |
| `Actual Fmax` | **55.313 MHz**（`Logic Level 7`） | `sim/evidence/gowin_m0_timing.txt:74-78` |
| 最差 setup 路径 slack | **+0.102 ns**（`u_note_manager/g_t3.rot_cnt_0_s0 → g_t3.phase_tr[28]_24_s0`） | `impl/pnr/Gowin2026.timing_paths` |
| 第 2 差路径 slack | **+0.133 ns**（`u_tdm_render_mixer/cnt_4_s0 → prod_c_0_s`） | 同上 |
| `oscillator_bank` 在 Top-25 setup 路径里 | **0 次** | 已 grep（3 个 tr html 均为 0） |
| `vibrato_lfo` 在 Top-25 setup 路径里 | **0 次** | 同上 |
| `Logic` | 34507 / 59904（**58%**） | `impl/pnr/Gowin2026.rpt.txt` |
| `LUT` / `ALU` | **27135** / **7372** | 同上 |
| `Register` | 17039 / 60780（**29%**） | 同上 |
| `CLS` | 23303 / 29952（**78%**） | 同上 |
| `DSP` | 22 / 118（其中 `MULTALU27X18` **7**） | 同上 |
| `BSRAM` | 33 / 118（**28%**） | 同上 |
| 参考副本同步状态 | 除 `DRUM_CLS_EXT`/`drum_cls_i` 外**逐字同步** | 通读 `tb/models/oscillator_bank_ref.v` 全文 809 行 |

---

# 附录 C · 建议的执行顺序（按"零风险 → 有风险"排）

| 批次 | 条目 | 为什么排这里 |
|---|---|---|
| **第 1 批（零风险、只改注释/自检/tb）** | P1-10（注释矛盾）、P2-14（`test_mode_ctrl` 自检）、P2-11（`so_v` 溢出检查）、P1-6（TOM 截断检查）、P3-23（`DBG_LANE` 检查）、P3-22（删 `integer si`）、P3-27（`PHASE_W` 检查）、P2-20（gprj 注释）、P3-25（悬空 wire 注释）、P2-16（死参数注释）、P2-17（16/24 位注释）、P3-21（`LANES_C`） | 全部 `initial` / 注释 / 局部常量 ⇒ **不进网表或 0 硬件** ⇒ 可一次性做完再跑一次回归 |
| **第 2 批（零风险、但改逻辑）** | **P0-3**（ripple-carry → `+16'd1`）、**P0-2 改法一**（22 位宽度）+ 删死寄存器、**P0-1 (A)**（depth 上限）、P2-15（`slew_count_q` 位宽）、P2-18（`NOTE_VELOCITY` 定宽） | 都是**逐位等价**或**只影响未验证的极端档**；必须**每条单独跑一次聚焦 tb** |
| **第 3 批（改判据，会先变红）** | **P1-5 改法一**（补 test 退出沿 + 生产形状激励）、**P2-12 探针实验**、P2-19（参考副本加 `DRUM_CLS_EXT`）、P2-13（双实例 64 voice） | **先让它红**，把盲区变成有判据；红完之后再决定要不要改 RTL |
| **第 4 批（改 RTL、要完整四道门）** | **P0-4**（扫频深度窗口）、**P0-1 (B)**（比例颤音）、P1-7（`JUSTIFY`）、P2-20 方案 1（改 gprj） | 改生产行为 ⇒ **综合 + 聚焦 tb + 干净 PnR + 全量回归**四道门 |
| **第 5 批（时序实验，⛔ 禁止与第 4 批并行）** | P1-9 (b)（`vib_off` 扇出复制）、P2-12 落地、P3-28（`sample_bus_r` 改写） | 都要**同源 3 次 PnR** 才能下结论（噪声 2~3 MHz）⇒ 每次 ~10 min × 3 × 3 组 |

**⛔ 铁律提醒**：第 4 / 5 批**动 `rtl/`** ⇒ 与正在跑的**全量回归**、**PnR**、**变异测试**（`bringup/mutation_test.ps1`，会**就地改 `rtl/`**）**互斥**（`AGENTS.md` §二 / `K-119`）。跑之前先 `git status` 确认干净。

---

# 附录 D · 逐条"能红"判据速查表

| # | 优先级 | 一行判据 |
|---|---|---|
| 1 | P0 | 新 tb：`base_inc=E1(3 624 000)`、`vibrato` 扫满量程 ⇒ `inc_main_w[31]` 现在会变 1 ⇒ 断言它恒 0 **必红** |
| 2 | P0 | `grep 'rate_target_q'` 只有 3 处（声明/复位/赋值）⇒ 死寄存器；改 `[21:12]`→`[20:11]` 后 `tb_vibrato_lfo` 的 110/120/130 **必红** |
| 3 | P0 | 探针 SDC 逼路径读 `Logic Level`；`(~tri_pos)+16'd1` 与旧函数逐位比 `mod_o`；反向 `+16'd0` **必红** |
| 4 | P0 | 同 voice 底鼓紧跟嗵鼓、在窗口内起音 ⇒ `sweep_q` 装载值 = 2621（应 8739）⇒ 断言 **必红** |
| 5 | P1 | `tb_p5_osc_equiv` E 段补 4 帧 + `test_lane_active=64'h5555…` ⇒ 奇数 lane `PHASE` mismatch **必红** |
| 6 | P1 | 探针 `DRUM_TOM_SWEEP_SH=0` ⇒ 新检查**必须**打印；现在**不打印** |
| 7 | P1 | chain 的 `JUSTIFY=1` vs `top.v` 的 `0` ⇒ 同激励比 `HP_DIN` 逐位；改回 1 **必红** |
| 8 | P1 | 探针 `CLK_PER_SAMPLE=64` ⇒ 新检查**必须**打印；现在**不打印** |
| 9 | P1 | 探针 SDC 逼 `vib_mul_r → phase_q`；同源 **3 次** PnR 取 median 对比（噪声 2~3 MHz） |
| 10 | P1 | `grep '固定.*rom_hard\|blend_sum = rom_soft'` **两处同时命中** ⇒ 矛盾；把 `FIXED_BLEND_Q` 改 256 跑 `tb_wavetable_timbres` 看有没有保护 |
| 11 | P2 | 探针 `DRUM_SWEEP_LSB_SH=17` ⇒ 新检查**必须**打印；现在**不打印** |
| 12 | P2 | 探针去掉奇数 lane 覆盖 ⇒ `LUT` 降 ≥500 才落地（否则降级 P3） |
| 13 | P2 | 双实例 `POLY_TARGET=64` ⇒ `active_n` 现在给 **0**（应 64）⇒ **必红** |
| 14 | P2 | 探针 `TEST_N2=8`（破坏单调）⇒ 新检查**必须**打印；现在**不打印** |
| 15 | P2 | `grep 'integer.*slew_count_q'` 命中 ⇒ 32 FF 白付；改位宽后 `tb_vibrato_lfo` 必须仍绿 |
| 16 | P2 | `(Select-String voice.v CLK_PER_SAMPLE).Count == 1` ⇒ 死参数；改成 0（删） |
| 17 | P2 | 断言 `sample_out[7:0]` 恒 0（连续 256 拍）⇒ **现在必绿**（证明是空壳） |
| 18 | P2 | `grep 'parameter integer NOTE_VELOCITY\|NOTE_VELOCITY\['` **两处命中** ⇒ 违规；传 256 时 `velocity_i` 变 0 |
| 19 | P2 | `grep 'DRUM_CLS_EXT' tb/models/oscillator_bank_ref.v` 命中 **0** 次 ⇒ 生产档无覆盖 |
| 20 | P2 | `gprj` 命中 2 条、`top.v` 例化命中 **0** 条 ⇒ 缺口 |
| 21 | P3 | `grep 'LANES\[' oscillator_bank.v` 命中 4 处 ⇒ 违反第 50 行纪律 |
| 22 | P3 | `grep 'integer si;'` 在两个文件各命中 1 处 ⇒ 死变量 |
| 23 | P3 | 探针 `DBG_LANE=64` ⇒ 现在**无 ERROR** 且 `tb_p5_osc_equiv` **假绿**（两侧同为 `x`） |
| 24 | P3 | `grep 'clk_i' test_mode_ctrl.v` 命中 1 次（仅声明）⇒ 死端口 |
| 25 | P3 | `grep 'mclk_en\|lrclk' voice_i2s_chain.v` 各命中 2 次（有连接、无消费者）⇒ 悬空 |
| 26 | P3 | 新断言 D1（一次 commit 的 `depth_q` 变化 ≤ `DEPTH_SLEW_STEP`）⇒ **现在必红** |
| 27 | P3 | 探针 `PHASE_W=1` ⇒ 现在 elaboration 报错/给 `x`，改后**必须**先打印 ERROR |
| 28 | P3 | 移位方向写反 ⇒ `tb_p5_osc_equiv` 的 `osc_sample_bus mismatch` **必红**（64 条 lane） |
