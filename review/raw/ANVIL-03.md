# ANVIL-03 · 音频核心混音与包络 —— 逐行审查（W3b / W3c）

> 审查人：**ANVIL-03**（肌肉集团）
> 日期：2026-10-09（工作区 HEAD = `026ed21`，`git status` 对这 6 个文件干净）
> 范围：**5 个交付文件 + 1 个 P5-② 基线副本**（见 §0.1）
> 铁律：**每条结论 = 文件:行号 + 代码原文 + 可复现的证据文件**。⛔ 没有证据的不写；
> ⚠️ 我没验证的**单独列在 §0.4**，不和结论混在一起。
> 📌 行号口径：一律按 `[IO.File]::ReadAllLines` 的编号（⚠️ **⛔ 不是 `Get-Content`** —— 见 **P2-4**，这个坑我这次差点踩进去）。

---

## 0. 证据基础（先核对证据，再下结论）

### 0.1 被审文件（全部 `read` 成功）

| 文件 | 字节 | 行数 | 最后提交 |
|---|---|---|---|
| `rtl/w3b/tdm_render_mixer.v` | 63633 | **889** | `026ed21` |
| `rtl/w3b/envelope_bank.v` | 16644 | **349** | `026ed21` |
| `rtl/w3b/adsr.v` | 10569 | **224** | `026ed21` |
| `rtl/w3c/master_mix.v` | 9053 | **143** | `026ed21` |
| `rtl/w3c/i2s_tx.v` | 15448 | **213** | `026ed21` |
| `tb/models/oscillator_bank_ref.v`（P5-② 基线） | 62794 | **809** | `026ed21` |

### 0.2 我引用的外部证据（含时间戳 · ⭐ 交付档与 =0 档是**两套**，别混）

| 证据 | 时间 | 我引用了它的什么 |
|---|---|---|
| ⭐⭐ `sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-a3.html` | 10-09 09:21 | **交付档（`RIGHT_ADC_ENABLE=1`）** PnR：`Actual Fmax = 57.016 MHz`（clk_sys）· top-25 setup 表 · 最差路径的**逐节点到达时间 + 物理坐标** |
| ⭐ `sim/evidence/rightboard-vibrato-fix-20261008/README.md:161-165` | 10-09 09:21 | 交付档最差路径 slack **+0.642 ns**、推算 `≈57.0 MHz` |
| `impl/pnr/Gowin2026_tr_content.html` | 10-09 01:13 | **=0 档** PnR：`Fmax = 55.313 MHz` · top-25 setup 表（**7/25** 是 mixer 同族） |
| `impl/pnr/Gowin2026.timing_paths` | 10-09 01:13 | =0 档逐节点到达时间（`cnt_4_s0 → … → prod_c_0_s`） |
| `impl/gwsynthesis/Gowin2026_syn_resource.html` | 10-09 01:10 | 逐模块 **DSP/LUT/REG**；⭐ `u_adsr` **0 命中**（见 P2-1） |
| `sim/evidence/gowin_m0_timing.txt` | 10-09 09:21 | `0 setup / 0 hold violated`（=0 档） |
| `sim/evidence/tb_velocity_headroom.log` | 10-09 01:42 | ⭐ **实测电平** `max_abs=1147904 (136/1000 FS)`（见 P0-2） |
| `rtl/top.v` · `rtl/w3b/note_manager.v` · `rtl/clk_gen.v` | — | 跨模块参数/接线/节拍（**契约的另一半**都在这里） |
| `tb/w3b/tb_tdm_render_mixer.sv` · `tb/w3b/tb_velocity_headroom.sv` · `tb/w3b/tb_p5_osc_equiv.sv` · `tb/w3b/tb_envelope_bank.sv` · `tb/w3c/tb_i2s_tx_timing.sv` | — | 现有判据的**覆盖范围** |

### 0.3 等级定义（本文件自用，先写清楚免得吵）

| 级 | 含义 |
|---|---|
| **P0** | 现在就在薄冰上 / 会让**上板听感**或**下一次 PnR** 出错 ⇒ 上线前必须处理或必须明确接受 |
| **P1** | 交付档的**证据或标定与实际不符**，或存在**静默失效**的结构契约 ⇒ 会误导下一个改动 |
| **P2** | 潜在结构风险（**当前不失败**）+ 会误导人的**过期证据** |
| **P3** | 卫生（死码 / 注释 / 风格），不影响功能与证据 |

### 0.4 ⚠️ 我**没有**做的（诚实边界，⛔ 别把这些当已验证）

1. **我没跑任何仿真 / 综合 / PnR。** 回归 ~15 min、PnR ~10 min，且按项目纪律「回归/PnR 在跑时 ⛔ 不能改 `rtl/`」⇒ 这类长任务应由**持有任务队列的人**统一跑。本文件所有时序数字都是**引用现成证据**，不是我自己测的。
2. **我唯一的自跑实验**是 §0.5 的独立 iverilog 小例子（不依赖本仓库任何文件）。
3. 我**没有**验证上板听感；"小声"这条因果链我只给到**数字 + 代码**。
4. 我**没有**逐行核 `oscillator_bank_ref.v` 的算术等价性（只做了端口 / 参数 / 结构对比）⇒ **P1-2 的结论限定在「覆盖范围」，不是「等价性对错」**。
5. 交付档的 `Gowin2026-rightadc-a3.fs`（19 MB，10-09 01:55）我**没有**做任何比对（只在 README 里见到名字）。

### 0.5 一个机械实验：`localparam signed` 的比较到底坏不坏？（K-101 同族）

`tdm_render_mixer.v:340-347` 明写「⛔ 不用 `signed` 限定符 + 比较（iverilog 会退化成无符号比较）」，
但**同一个文件的限幅器**（`:746-750`、`:780-790`）就是 `localparam signed` + 比较。
⇒ 我**先做实验再下结论**（⛔ 不猜）：

```verilog
localparam integer ACC_W = 40;
localparam signed [ACC_W-1:0]   MAX_A = (1 <<< 23) - 1;                    // K-101 的历史写法
localparam signed [ACC_W+15:0]  LIM_TH_W = {{(ACC_W-8){1'b0}}, 24'sh700000}; // 现限幅器的写法
wire signed [ACC_W-1:0]   pos9 =  40'sd9000000;  wire signed [ACC_W-1:0]  neg9 = -40'sd9000000;
wire signed [ACC_W+15:0] xneg9 = -56'sd9000000;  wire signed [ACC_W+15:0] xpos9 = 56'sd9000000;
```

实测（`Icarus Verilog version 14.0 (devel)`）：

```
A pos9>MAX_A  = 1 (want 1)     A neg1>MAX_A  = 0 (want 0)
A neg9<MIN_A  = 1 (want 1)     A pos9<MIN_A  = 0 (want 0)
B xneg9>LIM   = 0 (want 0)     B xneg9<-LIM  = 1 (want 1)     B xpos9>LIM = 1 (want 1)
```

⇒ ⭐ **7/7 全部是有符号正确结果** ⇒ **限幅器这两处不是活缺陷**（⛔ 别当 bug 去"修"）。
⇒ 但项目自己的纪律是禁用 ⇒ 归 **P3-7**（建议改逐位判据，理由写成「工具无关性」，⛔ 不是"修 bug"）。

---

## 1. 结论速览

| ID | 级 | 位置 | 一句话 | 分类 |
|---|---|---|---|---|
| **P0-1** | P0 | `tdm_render_mixer.v:137,238,246-249,280` | ⭐ **交付档全设计最差路径**就是它（+0.642 ns，11/25 条同族），切片散布 **0.686 ns > 全部余量** | **结构性**（散布是布局运气） |
| **P0-2** | P0 | `tdm_render_mixer.v:594-633,684-685` + `top.v:4413` | 单音电平：文档说 **88 ⇒ 69%**，交付实为 **64 且再 >>8 = 25%**（实测 13.6% FS）⇒ 差 **8.8 dB** | 标定 / 注释↔代码 |
| **P1-1** | P1 | `tb_tdm_render_mixer.sv:57-61` vs `top.v:4397-4413` | 验收 tb 跑在**非交付参数**上（**6.02 dB**），且**去拉链斜坡（交付默认）全仓库零覆盖** | 证据完整性 |
| **P1-2** | P1 | `tb/models/oscillator_bank_ref.v` vs `oscillator_bank.v:204,246` + `top.v:4214` | P5-② 逐位等价基线**缺 `DRUM_CLS_EXT`/`drum_cls_i`** ⇒ 等价证据**不覆盖交付档（=1）** | 证据完整性 |
| **P1-3** | P1 | `envelope_bank.v:332-335` | "tick 必须单拍且间隔 ≥34 clk"**只写在注释里**；违反 ⇒ 32 路包络**永久冻结**（静默） | 结构契约 |
| **P2-1** | P2 | `adsr.v:110-136` | 那段 PnR 引用的是**已不在网表里**的模块（synth 报告 0 命中）⇒ 过期证据 | 证据卫生 |
| **P2-2** | P2 | `master_mix.v:107-128` + `top.v:4486-4490` | 输出**组合穿通**（限幅→乘法一拍）；当前不在最差 25 条，但它是链上**下一个**会爆的点 | 潜在结构 |
| **P2-3** | P2 | `i2s_tx.v:74` + `clk_gen.v:86,69-74` | `SLOT_BITS` 与 `SLOT_BCK` 两处独立书写、无机械核对（⚠️ 现有 `tb_top_m0:350` 能兜住） | 契约卫生 |
| **P2-4** | P2 | 工具链 | PS **5.1** + 裸 `Get-Content` ⇒ UTF-8 无 BOM 的 RTL/`.md` 被按 **GBK** 解码，**行数都会变**（889→589） | 环境 |
| **P3-1..7** | P3 | 见 §5 | 死线 / 悬空可观测输出 / `integer` 参数位选 / 截断不舍入 / 注释位宽 / 函数重复 / signed 比较风格 | 卫生 |

---

## 2. P0 详述

### P0-1 ⭐⭐ `tdm_render_mixer` 的 TDM 时隙选路 = **交付档全设计最差路径**，且**同族切片的布线散布大于全部余量**

**位置**：`rtl/w3b/tdm_render_mixer.v:137`（夹取）→ `:238`（64 lane 选择）→ `:246-249`（加权/移位加减）→ `:280`（DSP 输入）

```verilog
137:    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];
238:            vs_sum = vs_sum + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
246:            vs_dif = $signed(osc_sample_bus_i[cnt_sel*2*OSC_SAMPLE_W +: OSC_SAMPLE_W])
247:                   - $signed(osc_sample_bus_i[(cnt_sel*2+1)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
248:            vs_w   = $signed({vs_sum, 3'b0}) + vs_dif;   // ⭐ 8·(L0+L1) + (L0−L1) = 9L0+7L1
249:            vs_c   = vs_w >>> LANE_WS;                   // ⭐ ÷16（权重和）
280:    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;
```

**证据（交付档 =1，`RIGHT_ADC_ENABLE=1`）**：`sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-a3.html` 的 Setup Paths Table：

| # | Path Slack | From Node | To Node |
|---|---|---|---|
| **1** | **0.642** | `g_sound.u_tdm_render_mixer/cnt_4_s0/Q` | `g_sound.u_tdm_render_mixer/prod_c_0_s/D[15]` |
| **2** | **0.702** | 同上 | `prod_c_0_s/D[14]` |
| **4** | 0.937 | 同上 | `prod_c_0_s/D[12]` |
| 7 / 8 / 9 / 11 / 14 / 20 / 22 / 23 | 1.087 … 1.328 | 同上 | `D[13] A[17] D[11] D[8] A[16] D[10] D[17] A[5]` |

⇒ ⭐ **交付档 top-25 setup 里 11 条是 `u_tdm_render_mixer`**（14 条是 `u_note_manager`），
   ⭐ **第 1、第 2 名就是它**；`Actual Fmax = 57.016 MHz`（约束 50）。
=0 档（`impl/pnr/Gowin2026_tr_content.html`，01:13）里它是**第 2 名**，top-25 里占 **7/25**，
slack 依次 `0.133 / 0.604 / 0.770 / 0.815 / 0.823 / 0.850 / 0.851`。

**机制（带数字 · 逐节点到达时间，交付档 artifact 原文）**：

```
… R52C139[2][A]  n48_s43/F      14.017   tINS 0.763
   R59C135[3][A]  n48_s36/I3     14.391   tNET 0.373
   R59C135[3][A]  n48_s36/F      14.982   tINS 0.592
   R57C130[1][B]  n48_s33/I2     15.398   tNET 0.415
   R57C130[1][B]  n48_s33/F      16.858   tINS 1.460   ← ⚠️ 单级 1.46 ns
   R64C141[1][A]  vs_dif_8_s/I0  17.358   tNET 0.501
   R64C141[1][A]  vs_dif_8_s/COUT17.358   （进位链 0.045 ns/bit）
```

⇒ ⭐ **减法器本身只花 45 ps/bit**（进位链，便宜），**但它从 17.358 ns 才开始** ——
   **20 ns 周期里 86.8% 已经烧在 `cnt` → 64:1 选择 → 加法树 这一段上了**，之后还要进 DSP（`prod_c`）。
⇒ 这一拍里串了 **4 件事**：`cnt_sel` 夹取 → 64 lane（16 位×2）选择 → 18 位加减（加权） → DSP 乘法输入。

**分类：结构性 ✅（不是布局运气）—— 但"数字本身"是布局运气**

| 判据 | 事实 |
|---|---|
| 结构性 | 同一 from→to **在交付档占 top-25 的 11 条**（=0 档 7 条）⇒ **不是单点坏运气**；且它跨 `D[8..17]`/`A[5..17]` 复制 ⇒ 逻辑结构决定 |
| 布局运气 | **同族切片之间的 slack 散布 = 1.328 − 0.642 = 0.686 ns**（=0 档 0.851 − 0.133 = **0.718 ns**）<br>🔴 **这个散布【大于】第 1 名的全部余量 0.642 ns** ⇒ **"今天过了"对下一次 PnR 没有任何信息量** |

**改法（按性价比排序）**：

1. ⭐⭐ **把 64:1 选择换成"旋转移位寄存器"**（`envelope_bank` 已经在用同一招 —— `envelope_bank.v:151-153,337-339`）：
   帧起点把 `osc_sample_bus_i` 装进 1024 位移位寄存器，**每拍头切片就是当前 voice 的两条 lane**，
   于是 `cnt → mux` 这条选路整段消失，一拍里只剩「加法 + DSP 输入」。
   · 📌 **数字出处（⛔ 别混档）**：选路 ≈ **6.1 ns**（=0 档 dump：`cnt_4_s0` 1.288 → `n101_s44` 7.407）、
     加权算术 ≈ **2.5 ns**（同 dump：`n101_s33` 14.754 → `vs_dif_17_s` 17.219）、
     DSP 输入 ≈ **2.6 ns**（同 dump：17.438 → `prod_c_0_s` 20.062）。
     ⭐ **交付档的 dump 也给出同一形状**：`n48_s43/F` 14.017 → `vs_dif_8_s/I0` 17.358（3.34 ns）。
   · 代价：**+1024 FF**，`cnt` 不再参与选路（改为移位计数）；⛔ **不动 `env_level_i` 的选择也可以**（512 位同理可选做，或保留）。
   · 收益：**削掉 86.8% 里最大的那一块**，预期把这条路径从"最差"挪出 top-25。
2. 次选：**拆两级流水**（选择 1 拍 → 算术 1 拍 → 乘法）：`valid_d` 深度 5 → 7（`tdm_render_mixer.v:857-863`），
   `acc_r` 要跟着"同一 voice"的乘积 ⇒ 需要 1 个 look-ahead 指针（照抄 `envelope_bank.v:165-166` 的 `svc_i/pre_i`）。
   · 代价：+2 拍延迟（一帧 1024 拍，占 0.2%，⛔ 听感不可闻），tb 的 `POLY+3..POLY+8` 断言窗口要跟着改（`:854-855` 已经留过口子）。
3. ⛔ **不要**只把 `cnt_sel` 打一拍（那只挪掉 1.288 ns，见到达时间表第一跳）—— 不够，别浪费一轮 PnR。

**怎么验证能红**：
```powershell
# ① 改之前先记基线（⛔ 别只看"跑完了"）
#    交付档：sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-a3.html
#    grep 关键字：u_tdm_render_mixer/cnt_4_s0  与  prod_c_0_s
# ② 改完重跑 PnR（~10 min）
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
# ③ 判据（机械）：新的 top-25 setup 表里【不应再出现】From=cnt_4_s0 → To=prod_c_0_s；
#    且最差 slack 必须【大于】0.642 ns（否则说明改动没生效或换了个点爆）
# ④ 功能不许动：
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_tdm_render_mixer
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_e2e_key_to_sound
```
⚠️ **注意**：这是**时序**判据 ⇒ 唯一判据是 **PnR 产物**，⛔ 仿真永远测不出来。

---

### P0-2 ⭐⭐ 单音电平：文档三处口径互斥，交付实际是 **64 再 >>8 = 25% FS**（实测 13.6% FS）⇒ 与"88 ⇒ 69%"的意图差 **8.8 dB**

**位置**：`rtl/w3b/tdm_render_mixer.v:594-633`（LUT）· `:684-685`（移位）· `rtl/top.v:4413`（交付参数）

```verilog
 66:    parameter integer NORM_GAIN_STEP      = 1,
 71:    parameter integer OUTPUT_HEADROOM_SH  = 0      // ⚠️ 模块默认 0
598:                 6'd0:  gain_sqrt_lut = 16'd64;
599:                 6'd1:  gain_sqrt_lut = 16'd64;    // 64/√1  = 64.0   ← ⭐ 交付 N=1 走这条
600:                 6'd2:  gain_sqrt_lut = 16'd45;    // 64/√2  = 45.3
684:            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r})) >>> (7 + OUTPUT_HEADROOM_SH);
```
```verilog
// rtl/top.v:4397-4413
        tdm_render_mixer #(
            ...
            .OUTPUT_HEADROOM_SH  (1)          // ⭐ 交付档 = 1 ⇒ 实际 >>>8
```

**同一文件里的四套互斥口径（全部原文）**：

| 行 | 原文 | 隐含基准 |
|---|---|---|
| `:425` | `gain(N) = 128 / √N` | **128 = 1.0** |
| `:534` | `基准 44 = 满增益` | **44 = 1.0** |
| `:581-585` | 表格：`44 → 34%`、**`88 → 69%`** ✅ | **88 = 1.0** |
| `:598-601` | `6'd1: 16'd64` / `6'd2: 16'd45` / `6'd3: 16'd37` | **64 = 1.0** ← ⭐ **代码实况** |

**机制（数字全部可复算）**：

- 单 voice 满幅：两 lane 同相 `L0=L1=32767` ⇒ `vs_c = (9+7)/16 × 32767 = 32767`
  ⇒ `prod = 32767 × 65535 = 2 147 385 345` ⇒ `sh = acc >>> 16 = ⌊2 147 385 345/65536⌋ = 32766`
  ⇒ `sh24 = 32766 << 8 = 8 388 096` = **99.994% ≈ 2²³ = 100.0% FS**（`:395` 的 `SCALE_UP = SAMPLE_W-16 = 8`）
  ⇒ 交付档 `×64 >>> 8` = **2 097 024 = 25.0% FS = −12.04 dBFS**
  （📌 这里刻意保留 `⌊⌋`：`>>>` 对正数是**向下取整**，`2 147 385 345/65 536 = 32 766.9999…` ⇒ 32766 而⛔ 不是 32767）
  ⇒ 若 `OUTPUT_HEADROOM_SH=0` 才是 50%（−6.02 dB）；文档说的 69% = −3.2 dB ⇒ **差 8.8 dB**。
- ⭐ **实测（交付档路径参数，`sim/evidence/tb_velocity_headroom.log`）**：
  ```
  INFO: timbre=0 velocity=200 samples=700 osc=32767 env=51200 max_abs=1147904 (136/1000 FS) knee=0 rail=0
  ```
  ⇒ 正常演奏力度（vel=200，env=51200=78.1% FS）下 **13.6% FS = −17.3 dBFS**；
  ⇒ 该力度下的**理论上限** = `(25599<<8)×64>>>8 = 1 638 336` = 19.5% FS（实测低是因为取到的那一帧加权和不在波峰）。
- ⭐ **gain 到底是 64 还是 45？用 timbre=1 的实测把答案钉死**（⛔ 不是读注释猜的）：
  ```
  INFO: timbre=1 velocity=200 … env=51200 max_abs=1540672 (183/1000 FS)
  ```
  若 `gain=45` ⇒ 需要 `sh24 = 1540672×256/45 = 8 764 712 > 6 553 344 = (32767×51200>>>16)<<8` = **物理上不可能**（`vs_c ≤ 32767`）
  ⇒ ⭐ **`gain=64` 是唯一解**（`8.8e6 > 6.55e6` 而 `64` 给 `6.16e6 ≤ 6.55e6` ✅）
  ⇒ ⭐ **LUT 是地面真相，`:581-585` 那张"88 ⇒ 69%"的表是【作废的意图记录】。**

**改法（⛔ 二选一，不许两个一起默默改）**：

- **(a) 承认 64 + −6 dB 裕量**：把 `:425`、`:534`、`:566-591`、`:581-585` 四段散文**全部改写成 64 口径**，
  并把 `tb_tdm_render_mixer.sv:361-364` 的 `128/91/74` 注释一起改（它的**断言标签**已经写的是 `gain=64`，`:300`/`:356`）。
  · 代价：0（只改注释）· 收益：⛔ 消灭"下次又有人按 88 去调"的循环（**这个循环已经发生 5 轮**，见 `:542-550`）。
- **(b) 真的把单音抬上去**（若用户仍觉得小）：`top.v:4413` 的 `OUTPUT_HEADROOM_SH` 1 → 0（**+6.02 dB**，一行），
  或把 LUT 换成 88 基准（**+2.76 dB**）。
  · 代价：软膝阈值 `LIM_TH_W = 7/8 FS`（`:746`）会更频繁介入（单音从 25% → 50% FS，双音/和弦更容易进膝）
  ⇒ **必须**重跑 `tb_velocity_headroom`（它会在 `vel ≤ 200` 进限幅时 **FAIL**：`:133-136`）并重听。
  · ⚠️ 这一条**是用户决策**（响度 vs 动态余量），⛔ 不是我能替他定的。

**怎么验证能红**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_velocity_headroom   # 打印实测 %FS
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_tdm_render_mixer    # 算术/电平判据
# 判据：改 (b) 之后 tb_velocity_headroom 的 INFO 行 %FS 必须【变大】；
#       且 knee=0 rail=0 对 vel≤200 仍然成立（否则就是"修了音量、破了验收"）
```

---

## 3. P1 详述

### P1-1 ⭐ 验收 tb 跑在**非交付参数**上（6.02 dB），且**去拉链斜坡（交付默认）零覆盖**

**位置**：`tb/w3b/tb_tdm_render_mixer.sv:57-61` vs `rtl/top.v:4397-4413`

```verilog
// tb_tdm_render_mixer.sv:57-61   ⚠️ 没传 OUTPUT_HEADROOM_SH ⇒ 用 RTL 默认 0
    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(OSW),
        .ENV_W(ENVW), .SAMPLE_W(SW), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927), .NORM_GAIN_STEP(0)      // ⚠️ 0 = 立即模式
    ) dut (
```
```verilog
// rtl/top.v:4409-4413        ⭐ 交付档
            .RESERVED_N          (5),
            .OUTPUT_HEADROOM_SH  (1)
        ) u_tdm_render_mixer (      // ⚠️ 没传 NORM_GAIN_STEP ⇒ 用 RTL 默认 1（去拉链）
```

**机制（两条，都要说清）**：

1. **6.02 dB 差**：tb 的 `>>>7`，交付是 `>>>8`。于是 tb 里这些**绝对电平判据全部不适用于交付档**：
   - `:300` `chk("full env => 183808 (weighted lane sum, gain=64)", latched === 24'sd183808);`
   - `:356` `chk("negative magnitude 184064 …", s1 >= -184240 && s1 <= -183888);`
   - `:419-420` `chk("max input clamps to soft-knee ceiling 0x780000 (not wrap)", sSat === 24'sd7864320);`
     🔴 交付档同样的激励只会给 **3 932 160**，**根本没到 T = 0x700000** ⇒
     **"限幅器会介入并封顶"这个结论在交付档是假的**（交付档那一档输入压根不碰限幅器）。
2. **去拉链零覆盖**：`rtl/w3b/tdm_render_mixer.v:641-658` 的斜坡（`:520-525` 自述是 2026-09-29 为消"偶发尖音/控制量阶跃"加的）**只有 `NORM_GAIN_STEP ≠ 0` 才会走到**。
   ```powershell
   # 机械核查（我跑过）：全仓库 tb 里 NORM_GAIN_STEP 只出现 4 次，【全部 = 0】
   Select-String -Path tb\*\*.sv -Pattern 'NORM_GAIN_STEP'
   #   tb_tdm_render_mixer.sv:60   .NORM_GAIN_STEP(0)
   #   tb_tdm_render_mixer.sv:77   .NORM_GAIN_STEP(0)
   #   tb_tdm_render_mixer.sv:155  .NORM_GAIN_STEP(0)
   #   tb_velocity_headroom.sv:67  .RESERVED_N(0), .NORM_GAIN_STEP(0)
   #   ⇒ 交付默认的 1 【一次都没被实例化过】
   ```
   ⇒ ⭐ **交付默认的那条斜坡，没有任何一条 tb 走过** ⇒ 改坏它（步长、方向判断、饱和）**回归不会红**。

**改法**：
1. 给 `tb_tdm_render_mixer.sv` 加**第 4 个实例**（照抄 `dut_wide` 的写法），参数 = **交付档**：`OUTPUT_HEADROOM_SH(1)` + `NORM_GAIN_STEP(1)` + `RESERVED_N(5)`。
2. 该实例的判据**一律写成相对量**（⛔ 不写死绝对数）：反相/同相比 ≈ 1/8（`:339-340` 的写法已经是这个路子 ✅）、单调、不回绕、天花板 = `T + W/2` 按**该实例自己的**移位口径算。
3. 斜坡要有 **settle 等待**：64→45 需要 `(64-45)/1 = 19` 帧（`:650-657`），一帧 1 个 `render_start` ⇒ **至少等 19 帧再判**。

**收益**：验收 tb 第一次真正跑在**交付参数**上；去拉链从"零覆盖"变成"有守护"。
**代价**：tb +1 实例 + ~20 行；⛔ **不动 RTL**。
**怎么验证能红**（先证明它非空洞 —— 按 `C83` 探针假绿的教训）：
```powershell
# ① 先把 NORM_GAIN_STEP(1) 写进【现有】tb 的实例（即"未修复代码"）：
#    ⇒ 现有那批绝对电平判据应当【立刻 FAIL】（它们编的是 shift=7 的账）⇒ 证明覆盖缺口是真的
# ② 再把 rtl 的斜坡步长改成 0（变异）：
#    ⇒ 新实例的判据必须 FAIL；旧实例必须仍然 PASS（否则说明新判据没打到斜坡）
```

---

### P1-2 ⭐ P5-② 逐位等价基线**缺 `DRUM_CLS_EXT` / `drum_cls_i`** ⇒ 等价证据**不覆盖交付档（=1）**

**位置**：`rtl/w3b/oscillator_bank.v:204,246`（新参数/新端口）vs `tb/models/oscillator_bank_ref.v`（**都没有**）

```verilog
// rtl/w3b/oscillator_bank.v
204:    parameter integer DRUM_CLS_EXT      = 0
246:    input  wire [POLY_TARGET*2-1:0]                         drum_cls_i,
400:            wire is_kick = drum_v && ((DRUM_CLS_EXT != 0)
401:                ? drum_cls_i[vg*2 + 1]
403:            wire is_tom  = drum_v && ((DRUM_CLS_EXT != 0)
404:                ? drum_cls_i[vg*2 + 0]
```
```verilog
// rtl/top.v:4214      ⭐ 交付档 = 1
            .DRUM_CLS_EXT     (1)
// rtl/w3b/note_manager.v:832-836 / :1363 / :1667    ⭐ 分类在【提交那一拍】算
832:    wire [PHASE_W-1:0] cmt_inc_oct = (base_oct_r == 2'd0) ? cmt_inc_r
835:    wire cmt_kick = (cmt_inc_oct <  DRUM_KICK_MAX_C);
1363:                        drum_cls_r[cmt_idx_r*2 +: 2] <= {cmt_kick, cmt_tom};
1667:    assign voice_drum_cls_o = drum_cls_r;
```

**机械对比（我跑过）**：
```
RTL 端口表比 ref 多【且只多】一行：input wire [POLY_TARGET*2-1:0] drum_cls_i,
RTL 参数表比 ref 多【且只多】一行：parameter integer DRUM_CLS_EXT = 0
```

**证据覆盖范围（关键）**：
```verilog
// tb/w3b/tb_p5_osc_equiv.sv:81-91   ⚠️ DUT 也没传 DRUM_CLS_EXT ⇒ 默认 0
    oscillator_bank #(
        .POLY_TARGET(32), … .DETUNE_ON(1), .DETUNE_SH(9),
        .DRUM_PITCH_ENV_EN(1), … .DRUM_CLICK_EN(0)
    ) dut (
```
⇒ ⭐ `tb_p5_osc_equiv.sv` 的 **320 帧 0 mismatch**（引用于 `files/00-总览/交接-逻辑优化-20261003.md:47`）
   **只证明了 `DRUM_CLS_EXT=0` 那一档**；而**交付档是 1**。
   两档在"鼓音高扫频装载值"上**可以不同**（`is_kick/is_tom` 的来源不同：`bv` 实时比较 vs 提交时锁存），
   触发差异的现实路径是**抢占 / 重触发 / 起音后再变调**（`sweep_load` 在 `rst_v` 或 `act_v` 上升沿重装，`:458`）。
⇒ ⚠️ **ref 连这个端口都没有 ⇒ 想验也编译不过** —— 所以这不是"我怀疑它错"，而是**覆盖不到**。

**附带的文档漂移（同一条证据链）**：`sim/evidence/rightboard-vibrato-fix-20261008/README.md:253-256` 描述的方案是
「给 `oscillator_bank` 加输入 **`phase_raw_i`** + Z-safe 回退 + `top.v` 接 `voice_phase_raw_o`」，
但 `phase_raw` 在**全仓库 RTL 里 0 命中**（我 grep 过 `rtl/**/*.v`）——
落地的其实是 `drum_cls_i` 方案（`note_manager` 提交时锁存，`:822-836`）。
⇒ ⚠️ README 的计划段落**没有标记为"已被取代"** ⇒ 下一个人会去找一个不存在的端口。

**改法**：
1. `tb/models/oscillator_bank_ref.v` 补 `DRUM_CLS_EXT` 参数 + `drum_cls_i` 端口（它就是 RTL generate 块的副本，两处几行）。
2. `tb_p5_osc_equiv.sv` 再加**一对**（ref/DUT 各一）实例，`.DRUM_CLS_EXT(1)`，`drum_cls` 同时驱动两边。
3. ⭐ **判别性激励**（这是关键，⛔ 不能只跑"分类与 `base_inc` 一致"的激励）：
   让 `drum_cls_i` 说"底鼓"而 `base_inc` 落在"嗵鼓"档（或反之），**再打一次 `voice_phase_rst`** ⇒
   两档的 `sweep_load` 必须不同 ⇒ 这才验到交付档独有的那条路。
4. README 的 `phase_raw_i` 段落加一行「⛔ 已被 `drum_cls_i` 方案取代（2026-10-08）」。

**收益**：交付档的鼓扫频第一次有逐位守护；顺手把一条会误导人的过期方案标注掉。
**代价**：ref +2 行、tb +~20 行；⛔ 不动 RTL。
**怎么验证能红**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_p5_osc_equiv
# ① 未修复代码：新实例【编译不过】（ref 无 drum_cls_i 端口）⇒ 这就是缺口的存在性证明
# ② 修好后：把 rtl 的 `? drum_cls_i[vg*2+1] :` 改成 `? bv < DRUM_KICK_MAX_C :`（变异）
#    ⇒ 新实例必须 FAIL；旧实例（=0 档）必须仍然 PASS
```

---

### P1-3 ⭐ `envelope_bank` 的"tick 必须单拍、间隔 ≥34 clk"**只写在注释里**；违反 ⇒ **32 路包络永久冻结**（静默）

**位置**：`rtl/w3b/envelope_bank.v:332-346`

```verilog
332:        end else if (sample_tick_i) begin
333:            cnt     <= {(AW+1){1'b0}};
334:            running <= 1'b1;
335:        end else if (running) begin
336:            if (cnt != {(AW+1){1'b0}}) begin
...
343:            if (cnt == CNT_STOP)
344:                running <= 1'b0;
```
文件头 `:28-30` 自述：*"A testbench must also leave at least 34 clocks between two sample_tick_i pulses"*。

**机制**：`sample_tick_i` 只要是**电平**（连续 2 拍以上为高），每个高拍都会把 `cnt` 清 0 ⇒
`cnt` **永远到不了 `CNT_STOP = POLY_TARGET = 32`**（`:59`）⇒ 服务分支 `else if (running)`（`:335`）**永远轮不到**
⇒ ⭐ **32 路 `env_level_o` 停在复位值 0**，`tdm_render_mixer` 输出恒 0 ⇒ **无声**，而且**没有任何 tb 会红**
（旧设计 32 个并行 `adsr` 是"每个高拍走一步"，**多拍 tick 只是包络变快**，不会冻结 ⇒ ⚠️ **这是本次重构【新引入】的失效模式**）。

**现状核对（我查过，硬件上是安全的）**：
```verilog
// rtl/clk_gen.v:104   ⭐ 单拍脉冲 ✅
104:            tick_audio   <= (cnt == {CW{1'b0}});
```
⇒ 硬件 `CLK_PER_SAMPLE = 1024`，`tick_audio` 1 拍宽 ⇒ **当前不失败**；`tb_envelope_bank.sv:45-54` 的 `tick()` 也是 1 拍 + 等 8 拍 ✅。
⚠️ 但**契约没有机械守护**：谁把 `tick_audio` 过一级寄存器/换成门控使能（或把 `envelope_bank` 复用到别的节拍上），就会静默冻结。

**改法（推荐 (a)）**：
- **(a) 让它对多拍 tick 免疫**（1 行）：`end else if (sample_tick_i && !running) begin` ⇒
  轮转进行中忽略新的 tick（语义：一个音频帧只服务一轮，**与 32 个并行实例的语义一致**）；
  ⚠️ 代价：若 tick 来得太快（<34 clk），该帧的包络**不推进**（旧设计是推进 1 步）——
  但那种配置本来就已经违反 `CLK_PER_SAMPLE=1024` 的契约，**冻结比"推进 2 步"更接近设计意图**。
- **(b) 只加守护**：`initial` 里加 `PARAM_OK` 风格检查（本项目已有 4 处同样套路：`clk_gen`/`i2s_tx`/`master_mix`/`tdm_render_mixer`）+ 在 `tb_envelope_bank.sv` 里加一条"tick 拉高 2 拍"的用例。

**收益**：消掉一个"无声且全绿"的失效模式（本项目最贵的那一类）。
**代价**：(a) 1 行 RTL + 必须重跑 `tb_p5_adsr_diff` / `tb_envelope_bank` / `tb_velocity_headroom`（⛔ 因为它改了共享引擎）；
(b) 0 行 RTL、只加测试。
**怎么验证能红**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tb_envelope_bank
# 用例：sample_tick 连续 2 拍为高，然后等 40 拍，断言 env0 === 16_384（期望推进 1 步）
# 未修复代码 ⇒ 实测 0（冻结）⇒ 红 ✅；修复后 ⇒ 16_384 ✅
```

---

## 4. P2 详述

### P2-1 `adsr.v` 的 PnR 引用是**已不在网表里**的模块（过期证据，会把人引到不存在的路径上）

**位置**：`rtl/w3b/adsr.v:110-136`（大段 PnR 引用：*"最差 25 条 setup 路径里 **24 条**都是 `…/u_adsr/sustain_product_0_s → …/env_level_o_*_s0/D`"*）

**机械核查（我跑过）**：
```powershell
$t = [IO.File]::ReadAllText('impl/gwsynthesis/Gowin2026_syn_resource.html')
# 命中数：u_adsr = 0 · u_voice = 0 · voice_i2s = 0
```
⇒ `adsr` 只被 `rtl/w3b/voice.v:66` 例化 ← `rtl/w3b/voice_i2s_chain.v:50` ← **只有 tb 用**
（`tb_voice_accept.sv:63`、`tb_voice_i2s_chain.sv:29`、`tb_pitch_shift_accept.sv:28`）；
交付档走的是 `rtl/top.v:1440` 的 `envelope_bank`（32 路并行实例已被共享引擎取代，见 `envelope_bank.v:1-30`）。

**改法**：把那一段前面加一行**历史标注**：*"⛔ 本段描述的是 32 路并行实例时代的路径；该结构已不在交付网表里
（`impl/gwsynthesis/Gowin2026_syn_resource.html` 中 `u_adsr` 0 命中）。当前全设计最差路径见 P0-1。"*
并保留 `adsr.v` —— ⭐ 它仍是 `tb_p5_adsr_diff.sv` 的**参考模型**，⛔ 不要删。
**收益**：下一个人不会去优化一条不在网表里的路径（本项目 §五① 的头号成本）。
**代价**：只改注释。
**怎么验证**：`Select-String -Path impl/gwsynthesis/Gowin2026_syn_resource.html -Pattern u_adsr` ⇒ **0 命中**（机械，不用仿真）。

---

### P2-2 `master_mix` 输出是**组合穿通**（限幅/饱和 → 主音量乘法 → `i2s_tx` 输入寄存器 一拍串完）

**位置**：`rtl/w3c/master_mix.v:107-128` + `rtl/top.v:4486-4490`

```verilog
107:    wire signed [PROD_W-1:0] prod = sample_i * $signed({1'b0, gain_r});
108:    wire signed [PROD_W-1:0] scaled = prod >>> (GAIN_W - 1);   // >> 15
113:    wire over_pos = ~scaled[PROD_W-1] && (|scaled[PROD_W-2 : SAMPLE_W-1]);
116:    reg signed [SAMPLE_W-1:0] samp_r;
117:    always @(*) begin                       // ⚠️ 组合
128:    assign sample_o = samp_r;
```
```verilog
// rtl/top.v:4486-4490      ⭐ 下游是寄存器
        always @(posedge clk) begin
            if (!rst_n_sync) sample_r <= {SAMPLE_W{1'b0}};
            else if (mm_valid) sample_r <= mm_sample;
```

**现状（我查了最差路径表，⛔ 不是猜的）**：
- 交付档 top-25 setup 里**没有 `master_mix`**（全是 `u_tdm_render_mixer` / `u_note_manager`）；
- =0 档的 25 条 setup 里也没有；`master_mix` 只出现在 **HOLD** 段（`gain_r_11_s0 → n169_s0`，2.317 ns，与输出乘法无关）。
⇒ **当前余量 ≥ 0.85 ns（=0 档第 25 名的 slack）**，**现在不失败** ✅。

**为什么仍然要盯它**：`tdm_render_mixer.v:799-825` 记着**同一个模式的实测代价** ——
`samp_r` 组合时"归一化乘法 → 限幅 → 饱和 → **主音量乘法**"串在一拍里，实测 `slack = 0.002 ns`、**27 级逻辑**。
现在 `tdm_render_mixer` 那一头已经寄存了（`:826-836`），**这条链的下一段就是 `master_mix`** ⇒
⭐ **P0-2 里任何"把音量抬上去"的改动，最先吃掉的余量就在这里**。

**改法**：把 `samp_r` 变成真寄存器 + `valid_o` 跟着延 1 拍（1 位移位链）。
**代价**：⚠️ 破坏 `:33-34` 自述的"**零延迟透传 valid**"契约 ⇒ `tb/w3c/tb_master_mix.sv` 必须跟着改；
真实链上无害（`i2s_tx` 只在 `frame_start` 装载一次，见 `i2s_tx.v:184`）。
**怎么验证能红**：PnR 重跑后确认 `master_mix` 仍不在 top-25（这是**接受改动**的判据）；
功能 `sim\tb_all.ps1 -Filter tb_master_mix` + `-Filter tb_e2e_key_to_sound`。

---

### P2-3 `i2s_tx.SLOT_BITS` 与 `clk_gen.SLOT_BCK` 两处独立书写、无机械核对（⚠️ 但现有 `tb_top_m0` 能兜住 ⇒ 才放 P2）

**位置**：`rtl/clk_gen.v:69-74,86` + `rtl/top.v:4614,4656` + `rtl/w3c/i2s_tx.v:74`

```verilog
// clk_gen.v:69-74   ⭐ 自己承认"本模块查不了，交给调用方"
        //    真实约束：`CLK_PER_SAMPLE == BCLK_DIV × SLOT_BITS × 2`
        if ((CLK_PER_SAMPLE % (BCLK_DIV * 2)) != 0)
            $display("ERROR [clk_gen] … 左右时隙不等长", …);
// clk_gen.v:86
    localparam integer SLOT_BCK = (CLK_PER_SAMPLE / BCLK_DIV) / 2;  // 每声道 BCK 数 = 32
// top.v:4614 / :4656
        .SLOT_BITS (32),          // ⚠️ 硬编码，与 clk_gen 的 BCLK_DIV 无任何交叉检查
```
**机制**：把 `BCLK_DIV` 改成 8（帧内 128 个 BCK）而 `SLOT_BITS` 留 32 ⇒ `i2s_tx` 每帧只数 64 个 BCK ⇒
`HP_WS`/`HP_DIN` **每帧漂半个帧**（左右声道互换 + 数据落到错误时隙），而 `i2s_tx` 的 `PARAM_OK`（`:111-113`）
只检查"时隙装得下数据"，**查不出这个**。
**⚠️ 为什么只算 P2**：`tb/top/tb_top_m0.sv:350` 直接量 `HP_WS` 周期并断言 `== CLK_PER_SAMPLE`
⇒ 上表这个改动**会被现有 tb 抓住**（我核过它的判据）。所以这是**契约卫生**，不是"没覆盖的洞"。
**改法**：把 `BCLK_DIV`/`CLK_PER_SAMPLE` 传进 `i2s_tx`，在它已有的 `initial` 自检里加
`CLK_PER_SAMPLE == BCLK_DIV*SLOT_BITS*2`（照抄 `:111-126` 的套路，2 行）；或在 `tb_top_m0` 里显式断言这条恒等式。
**怎么验证能红**：临时 `BCLK_DIV=8` 重跑 `-Filter tb_top_m0` ⇒ WS 周期判据红（证明检测器在）；加上新检查后 ⇒ 在 `i2s_tx` 边界就红（更早、更准）。

---

### P2-4 ⚠️ 工具链：本机是 **PowerShell 5.1**，裸 `Get-Content` 把 UTF-8 无 BOM 的 RTL/`.md` 按 **GBK** 解码 ⇒ **行数都会变**

**这不是我猜的，是我这次实际撞上的**（第一次数行数得到 589，真值是 889）：

```
$PSVersionTable.PSVersion = 5.1.26100.9444        ← ⭐ 不是 PowerShell 7
rtl/w3b/tdm_render_mixer.v        ReadAllLines= 889   GetContent= 589   ← 少 300 行（34%）
tb/models/oscillator_bank_ref.v   ReadAllLines= 809   GetContent= 549   ← 少 260 行
rtl/w3c/i2s_tx.v                  ReadAllLines= 213   GetContent= 131   ← 少  82 行
rtl/w3c/master_mix.v              ReadAllLines= 143   GetContent= 113   ← 少  30 行
```
合并的实例（`master_mix.v`，无 BOM）：
```
Get-Content[55] = "    assign ramp_done  = (gain_r == gain_i);"
真实第 55 行   = ""（空行）  真实第 56 行 = "// ── 主音量（Q1.15 线性增益，[0, 1)）───────"
```
⇒ ⭐ **非 ASCII 序列把后面的换行吃掉了** —— 与项目已归档的 `C72` **同一根因**，
  但 `C72` 的记录范围是 **`.ps1`**，而这里证明**同样的坑覆盖 `rtl/` 与 `files/**/*.md`**：
  README 直接 `Get-Content` 出来就是 `# 璇佹嵁 路 `A3` 姝ｇ‘淇硪…`（mojibake，我现场看到的）。

**现状核查（好消息：两个长任务脚本是安全的）**：
```powershell
sim/tb_all.ps1:96        $src = Get-Content -LiteralPath $tb.FullName -Raw -Encoding UTF8   # ✅ 显式 UTF8
bringup/mutation_test.ps1:152  $cur = [System.IO.File]::ReadAllBytes($src)                    # ✅ 字节级
```
⇒ ✅ `tb_all.ps1` / `mutation_test.ps1` **不会**踩到；⚠️ **但任何"临时一行命令"、任何新写的脚本、
以及【本审查报告的行号】都会踩** —— 我这次差点据此写出错误的 `文件:行号`。

**改法（三选一，推荐 ①+③）**：
1. ⭐ 所有脚本一律 `-Raw -Encoding UTF8` 或 `[IO.File]::ReadAllText`；**行号一律用 `ReadAllLines`**。
2. 把 `tools/check_ps1_encoding.ps1` 的规则**扩到 RTL/`.md`**（判据同款：非 ASCII 字节 > 0 且无 BOM ⇒ 报警），
   或者干脆给 `rtl/**/*.v`、`files/**/*.md` 也加 BOM（⚠️ 但那会动 `git diff`，要先确认行尾规则，见项目 §二）。
3. 在审查/排查清单里加一行机械检查：`(Get-Content f).Count -ne [IO.File]::ReadAllLines(f).Count` ⇒ **两个数不等就是踩了**。
**怎么验证**：上面那 4 行计数命令本身就是判据（⛔ 不需要仿真）。

---

## 5. P3（卫生，不影响功能与证据）

| ID | 位置 | 事实 | 建议 |
|---|---|---|---|
| **P3-1** | `master_mix.v:72,78` | `wire [GAIN_W-1:0] gain_diff; assign gain_diff = gain_i - gain_r;` —— **⛔ 全文无人读**（方向其实由 `:79-81` 的比较决定，`:77` 的注释"用差判方向"与代码不符） | 删掉，或真的用它做方向判断；顺带改 `:77` 注释 |
| **P3-2** | `top.v:4481` | `.ramp_busy_o  ()` —— 模块自己在 `:63-64` 声明"K-106 可观测性"的输出，**在顶层被丢弃** | 接到已有的调试/LED 通道，或删掉端口（⛔ 别留"声明了但看不见"） |
| **P3-3** | `i2s_tx.v:179,190,203` | `LRCK_POL[0]` —— **对 `integer` 参数做位选**，正是本项目 `K-91`/`K-99` 明令禁止的构造（`tdm_render_mixer.v:105-113,130-136` 为它专门写过踩坑记录）。{0,1} 下无害 | 改 `(LRCK_POL != 0)` |
| **P3-4** | `i2s_tx.v:136-144` | `top_bits` 取高 16 位 = **截断**低 8 位（不四舍五入）⇒ −0.5 LSB 直流偏置（`tb_tdm_render_mixer.sv:349-352` 已记录同族现象） | 要么加 `+ 0x80` 再截（⚠️ 必须同时确认饱和路径），要么在注释里写明"故意截断" |
| **P3-5** | `envelope_bank.v:191-196` | 注释说 *"this wire is 32 bits wide"*，实际 `wire [ENV_W+15:0] prod_p` = **31 位**（ENV_W=16）。乘积上界 `65280×230 = 15 014 400 < 2²⁴` ⇒ 无害 | 改注释（注释↔代码不一致是本项目复发缺陷） |
| **P3-6** | `adsr.v:45-95` vs `envelope_bank.v:69-119` | 4 个 `*_for_timbre` 函数**逐字重复**两份（A/D/S/R 的 4 组常数）⇒ 改一处忘一处就静默分叉 | 已有 `tb/w3b/tb_p5_adsr_diff.sv` 兜底 ⇒ 保持现状可接受；若要根治，让 `envelope_bank` 例化 `adsr` 的 function 不可行（Verilog-2001）⇒ 建议只加一条"两份必须一致"的注释 + 依赖该 tb |
| **P3-7** | `tdm_render_mixer.v:746,780,782,788-790` | `localparam signed` + 有符号比较 —— 与 `:340-347` 的纪律冲突。⭐ **我实测 iverilog 14.0 行为正确（§0.5，7/7）** ⇒ **不是活缺陷** | 若要工具无关，改成逐位判据（`sign = sh_norm_w[MSB]` + 幅值无符号比较）。⚠️ **改了必须重跑验收 tb**（⛔ 别当"修 bug"轻率动它） |

---

## 6. 我**核过并确认 OK** 的（⛔ 不要再去改，也别当问题报）

| # | 结论 | 依据 |
|---|---|---|
| 1 | ⭐ `envelope_bank` 的轮转对齐**没有 off-by-one**：voice `v` 在 tick 后第 `(2+v)` 拍落盘（我逐拍推了 `cnt=0` 预取 → `cnt=k` 服务 `k-1`，与文件头 `:25-30` 一致）；每个 voice 每帧**恰好一步** | `envelope_bank.v:158-166,203-221,323-346` + `tb_p5_adsr_diff.sv` |
| 2 | ⭐ `sustain_product` 的位宽链在 `adsr` 与 `envelope_bank` 两侧**逐位等价**：乘积上界 `65280×230 = 15 014 400 < 2²⁴`，两侧都取低 24 位再 `[23:8]` | `adsr.v:134-136` · `envelope_bank.v:196-223` |
| 3 | 饱和判据的位选边界**正确**：`+2²³−1` 与 `−2²³` 都不误判（因为 `SAMPLE_W-1` 位就是结果的符号位，必须与高位相同） | `tdm_render_mixer.v:796-797` · `master_mix.v:113-114` |
| 4 | ⭐ 软膝**确实是 C1 连续**：`e=0` 斜率 `1−e/W = 1`、`e=W` 斜率 `0`、天花板 `T+W/2 = 0x780000 = 15/16 FS`，且 **< 硬饱和点** ⇒ 硬折点不会被用到 | `tdm_render_mixer.v:721-790`（我复算了 `T=0x700000`、`W=0x100000`、`>>>21`） |
| 5 | ⭐ DSP 预算：合成报告实测 `u_tdm_render_mixer` = **8 DSP / 1662 LUT / 181 REG** ⇒ 与文件头 `:22` 的"实测 8 个 DSP"**一致** ✅（`u_oscillator_bank` 0 DSP · `u_envelope_bank` 1 · `u_master_mix` 1） | `impl/gwsynthesis/Gowin2026_syn_resource.html` |
| 6 | ⭐ `i2s_tx` 的 BCK/DIN 相位**与文件头一致**：数据在 `bclk_half_en` 拍变化、BCK 在 8 拍后上升采样 ⇒ 建立/保持各 8 clk = 160 ns | `i2s_tx.v:178-209` + `clk_gen.v:88-110` + `tb_i2s_tx_timing.sv` |
| 7 | `mx_fault` **不是死信号**（我一开始怀疑，查完撤销）：`top.v:1719 assign fault_any_w = (\|af_fault) \| mx_fault;` ⇒ 有人消费 | `top.v:1719,4457` |
| 8 | ⭐ 交付档 PnR **0 setup / 0 hold violated**，`Fmax = 57.016 MHz`（约束 50）⇒ **"能上板"这个结论本身成立**；P0-1 讲的是**余量薄**，不是"已经违约" | `timing-rightadc-a3.html` · `sim/evidence/gowin_m0_timing.txt` |

---

## 7. 给下一个人的最短行动序列（按依赖排序）

1. **先决定 P0-2 的口径**（用户拍板：接受 25% FS，还是抬上去）—— ⛔ **这一步不定，下面全是白干**
   （它决定 `OUTPUT_HEADROOM_SH`，而那个参数同时决定 P1-1 的判据窗口和 P2-2 的余量消耗）。
2. **P1-1**（改 tb 参数 → 交付档第一次有守护）：纯 tb，⛔ 不碰 RTL ⇒ 可立刻做，**风险 0**。
3. **P1-3 (b) / P2-1 / P2-4 / P3-\***：纯注释/测试/脚本，随时做。
4. **P0-1**（削逻辑级）：**必须独占一次 PnR**（~10 min，且期间 ⛔ 不改 `rtl/`）；
   建议先做"旋转移位寄存器"方案（一次到位），⛔ 不要先试"只给 `cnt_sel` 打拍"。
5. **P1-2**（补 ref 的 `DRUM_CLS_EXT` + 判别性激励）：等 4 落地后一起跑回归，省一轮。
6. **收尾**：`sim/tb_all.ps1` 全量（判据 = **通过数 == 运行时打印的"共 N"**，⛔ 不要写死数字）+ PnR 0/0 + `tb_velocity_headroom` 的 %FS 记录。

> ⚠️ 纪律提醒（本项目血泪）：跑**回归**期间 ⛔ 改 `rtl/`/`tb/`；跑**变异测试**期间 ⛔ 碰 `rtl/`、
> ⛔ `git add`、⛔ 与另一个 worktree 的 git 写操作并行。本报告只读，没有产生任何变异。
