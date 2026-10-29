# TORCH-1 · 音频数据通路**衔接面**抠缝报告

`note_manager → oscillator_bank → envelope_bank → tdm_render_mixer → master_mix → i2s_tx`

**战场口径**：GW5AT-60B · AC1/I0 慢档 · `clk_sys = 50 MHz` · SDC `set_max_delay 18.181 ns`（≈55 MHz）
**通过判据**：0 setup / 0 hold · Fmax ≥ 51.5 MHz
**本次全部证据来自**：
- `impl/pnr/Gowin2026.timing_paths`（当前交付档 = `RIGHT_ADC_ENABLE=0`，50 条路径：25 SETUP + 25 HOLD）
- `impl/pnr/Gowin2026.rpt.txt`（资源）/ `sim/evidence/gowin_m0_timing.txt`（Fmax 55.313 MHz / Logic Level 7 / 0/0）
- `build/rightadc-probe/impl/pnr/Gowin2026.timing_paths`（`RIGHT_ADC_ENABLE=1` 档，对照用）
- 逐行读源码（不是推测）

---

## 〇、先说结论：这条链的 Fmax 是**一条路径**算出来的，而且是**并列第一的两条**

`Actual Fmax` 的推导关系（实测反推，两次都吻合）：

```
Fmax = 1 / (18.181 − slack)
  · 当前档：  slack = 0.102  ⇒ 1/18.079 ns = 55.31 MHz   ← 报告里就是 55.313 ✅
  · ADC=1 档：slack = 0.740  ⇒ 1/17.441 ns = 57.34 MHz   ← 与"≈57.0 MHz"吻合 ✅
```

⇒ ⭐ **`Fmax` 不是"整体性能"，它就是 `timing_paths` 里那条最差路径的倒数。**

再看这 25 条 SETUP 的**终点分布**（我把 `Gowin2026.timing_paths` 全解析了）：

| 终点结构 | 条数 | 最大 data delay | 最小 slack |
|---|---|---|---|
| `g_sound.u_note_manager/g_t3.phase_tr[...]` | **18 / 25** | **22.172 ns** | **0.102 ns** |
| `g_sound.u_tdm_render_mixer/prod_c_0_s` | **7 / 25** | 20.062 ns | 0.133 ns |

⇒ ⭐⭐ **全设计最差 25 条 setup 路径，100% 出自两个结构，其余一条都没有。**

而这两条的 slack 只差 **0.031 ns**：

```
0.102  ns  →  Fmax 55.313 MHz
0.133  ns  →  Fmax 55.408 MHz
```

⇒ 🔴 **只修其中一条，Fmax 只涨 0.1 MHz（+0.2%）。必须两条一起修。**
⇒ 🔴 而"同源重跑差 2~3 MHz"= 路径延迟摆动 **0.62 ns**（1/55.06 − 1/57.0 = 18.162 − 17.544）
   ⇒ ⭐ **当前余量 0.102 ns 只有摆动的 1/6** —— 也就是说"过不过"目前**靠布局运气**，不是靠设计。

**结构性 vs 布局运气**（这一条我做了 A/B 对照，结论有实证）：

| 结构 | =0 档 | =1 档 | 判定 |
|---|---|---|---|
| `note_manager/g_t3.phase_tr` | 22.172 ns（slack 0.102） | 21.517 ns（slack 0.740） | ⭐ **结构性**：两档都是**全设计第一**，只差 0.65 ns（≈时钟树/布线微差） |
| `tdm_render_mixer/prod_c_0` | 20.062 ns（slack 0.133） | 掉出前 12（第 12 名 20.963 / slack 1.303） | ⭐ **机制结构性、数值布局主导**：同一条链在两档间摆了 **≈2 ns** |

⇒ ⭐ **"=0 档 55.06 / =1 档 57.0"这 2 MHz 的差别，主要是 `prod_c` 那条路径的布线摆动**，不是 `RIGHT_ADC_ENABLE` 带来的逻辑差异（`note_manager` 那条在两档里几乎没动）。

---

## 一、逐跳核对表（谁寄存、谁组合、差几拍、位宽怎么变）

| # | 跳（源 → 宿） | 信号 · 位宽 | 源侧寄存? | 宿侧寄存? | 拍数关系 | 位宽/截断 |
|---|---|---|---|---|---|---|
| 1 | `note_manager.voice_phase_inc_o` → `oscillator_bank.base_phase_inc_i` | `POLY_TARGET*PHASE_W` = **32×32 = 1024 bit** | ✅ `phase_tr[]`（T3_EN=1，交付档）；⛔ 组合 `phase_r[g] << base_oct_r`（T3_EN=0） | ⛔ 组合：`bv + vib_off + so_v` → `phase_q + lane_inc`，只在 `sample_tick_i` 落 `phase_q` | T3 影子数组**每 32 clk 轮刷一遍**（与 tick 异步）；相位**只认 tick**（1024 clk） | 32 位 mod 2³² 截断（P5-② 已论证与旧 33 位有符号加法等价） |
| 2 | `voice_active_o` → `oscillator_bank.voice_active_i` **＋** `tdm_render_mixer.voice_active_i` | 32 bit | ⛔ **组合** `live_mask = gate_r\|retrig_low\|env_active_r\|sus_hold_r`（4 组寄存器 OR） | ⛔ 组合：振荡器 `lane_active`/`act_v`（tick 采 `act_d`）；混音器 popcount（`render_start_i` 采 `n_active_r`） | 两宿**采点不同**：振荡器采 tick，混音器采 `render_start = tick+97` | — |
| 3 | `voice_gate_o` → `envelope_bank.gate_i` | 32 bit | ⛔ 组合 `gate_mask \| sus_hold_r` | ✅ tick 采进 `gate_s_r` | 电平；tick 采样 | — |
| 4 | `voice_velocity_o` → `envelope_bank.velocity_i` / `oscillator_bank.voice_velocity_i` | 256 bit | ⛔ 组合 `vel_r[]` | ✅ `vel_s_r`（envelope）；⚠️ **振荡器侧生产档整条链被常量折叠（死）** | tick | ⚠️ 振荡器端口写死 `POLY_TARGET*8`，⛔ 不是 `VEL_W` |
| 5 | `voice_timbre_o` → `envelope_bank.timbre_i` / `oscillator_bank.voice_timbre_i` | 64 bit | ⛔ 组合 `timbre_r[]` | ✅ `tim_s_r`（envelope）；组合（振荡器 TDM 选表） | tick | — |
| 6 | `voice_retrig_reset_o` → `envelope_bank.retrig_reset_i` / `oscillator_bank.voice_phase_rst_i` | 32 bit | ⛔ 组合 `retrig_reset_r`（**电平，保持到 tick**） | ✅ `rr_s_r`（envelope）；组合 `phase_rst_lane`（振荡器） | ⭐ 一个信号两个消费者，**同源同拍**（K-169）✅ | — |
| 7 | `envelope_bank.env_level_o` / `env_active_o` → `note_manager` / `tdm_render_mixer` | 512 bit / 32 bit | ✅ `env_level_o`（**轮转写，第 v 路在 tick+(v+2) 落盘**） | `note_manager.env_level_r` ✅ 每 clk 无条件寄存；混音器 `env_c` ⛔ 组合 mux | ⭐ **源侧要 33 clk 才写完**；宿侧无握手 | — |
| 8 | `oscillator_bank.osc_sample_bus_o` → `tdm_render_mixer.osc_sample_bus_i` | **64×16 = 1024 bit** | ✅ `sample_bus_r`（`cnt=k+1` 写 lane k） | ⛔ **组合**：32:1 mux → `vs_sum`/`vs_dif` → DSP | `sample_tick` → `osc_valid_o` 在 **tick+65**（1 clk 脉冲） | lane = voice*2+osc ✅ 两侧一致 |
| 9 | `tdm_render_mixer.dry_sample_o` / `dry_valid_o` → `master_mix` | 24 bit / 1 bit | ✅ `samp_r` 真寄存器 | ⛔ `master_mix` 输出**纯组合** | `render_start` → 数据在 +37 clk、`valid` 在 **+39 clk**（POLY+7，差 2 拍） | — |
| 10 | `master_mix.sample_o` / `valid_o` → `top.sample_r` | 24 bit | ⛔ **组合**（DSP + 饱和） | ✅ `top.v:4489` `if (mm_valid) sample_r <= mm_sample;` | 零延迟透传 valid | — |
| 11 | `top.sample_mono` → `i2s_tx.sample_l/r` | 24 bit | ✅ `sample_r` | ✅ `frame_start` 装载（阻塞赋值） | ⭐ `tick_audio` 与 `frame_start` **同拍**（`clk_gen.v:104/109`，都是 `cnt==0` 寄存 ⇒ 都在 `cnt==1` 那拍）⇒ **恰好提前一帧** ✅ | 取高 16 位（`top_bits`）✅ |
| 12 | `i2s_tx` → `HP_BCK/HP_WS/HP_DIN` | 3 脚 | ✅ 全寄存 | — | ⭐ 数据在 **BCK 下降沿**变（`bclk_half_en` 与 `bclk_en` 都在 `cnt%16==1`）⇒ 到上升沿 **8 clk = 160 ns** 建立 ✅ | — |

**⭐ 逐跳核对结论（✅ 清白的部分）**：
- 跳 8 的 lane 映射（`voice*2+osc`）两侧完全一致；`resp_velocity_q`/`resp_drum_q` 与 ROM 的 1 拍延迟**同拍对齐**（`req_active` 同一使能）✅
- 跳 11 的 `tick_audio == frame_start` 同拍、`i2s_tx` 在 `frame_start` 用 `top_bits(sample_l)` 而非 `d16_l`（避开 delta 竞态）✅
- 跳 12 的 BCK 相位（复位值 1 ⇒ 下降沿变数据、上升沿采样）**逐拍核算正确**，160 ns 建立/保持 ✅
- 跳 6 的 K-169"一个事件两个消费者"确实同源同拍；我逐拍推了"新占 voice"和"同轴重触发"两条路，**两条都能在 tick 那拍看见 `retrig_reset`** ✅
- `envelope_bank` 的旋转移位寄存器（`lvl_sr/st_sr/rel_sr`）头指针 = `cnt-1`，`cnt=32` 时 `svc_i=31`、移位 32 次后复位到恒等序 —— **逐拍推过，无错位** ✅

---

## P0-1 · `note_manager` T3 写侧：全设计第一关键路径（slack 0.102 ns，22.172 ns 单周期）

**文件**：`rtl/w3b/note_manager.v:1518-1519` · `:1532-1534` · `:1544` · `:1575-1578` · `:1606-1616`
**实测路径（`impl/pnr/Gowin2026.timing_paths` 第 1 条）**：

```
SETUP  slack 0.102  data 22.172  required 22.274
  clk_ibuf                    0.000 → 1.288
  g_t3.rot_cnt_0_s0           4.142 → 4.473
  g_t3.rot_phase_20_s83       9.737 → 9.948     ← 32:1 读 mux（含 5.26 ns 布线）
  g_t3.rot_phase_20_s71       9.948 → 10.125
  g_t3.rot_phase_20_s65      10.125 → 10.216
  g_t3.rot_phase_20_s62      10.216 → 10.307
  g_t3.rot_phase_20_s61      10.307 → 10.398
  g_t3.rot_base_22_s1        11.502 → 11.975    ← 八度变量移位器
  g_t3.rot_base_22_s0        12.117 → 12.586
  g_t3.prod_w_0_s            13.589 → 16.123    ← 32×17 乘法器 2.53 ns
  g_t3.n34284_s0             16.296 → 16.765    ← 旁路 mux / >>>15
  g_t3.phase_tr[28]_24_s0    22.172             ← 32 路写译码 + 1024 个 D 脚扇出 5.4 ns
```

**代码**：

```verilog
1518:    reg  [4:0]         rot_cnt;
1519:    reg  [PHASE_W-1:0] phase_tr [0:POLY_TARGET-1];
1532:    wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];
1533:    wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase
1534:                                                        : (rot_phase << base_oct_r);
1544:    wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;
1575:            if (rot_ok)
1576:                phase_tr[rot_cnt] <= ((semi_cur == 5'sd0) ||
1577:                                      (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
1578:                                   ? rot_base : (prod_w >>> 15);
```

**为什么是问题（机制 + 数字）**：
一个周期里串了**四件独立的事**，且每一件都是宽结构：
1. `phase_r[rot_cnt]`：**32:1 × 32 bit 读 mux**（`phase_r` 是 32 个分散的寄存器数组）⇒ 实测 **5.26 ns 纯布线 + 0.5 ns LUT**；
2. `<< base_oct_r`：**32 位变量移位器**（2 级桶形）⇒ **2.1 ns**；
3. `rot_base * semi_ratio`：**32×17 乘法器** ⇒ **2.53 ns**；
4. `phase_tr[rot_cnt] <= ...`：**32 路写译码 + 32 位数据扇出到 32×32 = 1024 个 D 脚** ⇒ **5.4 ns**。
合计 22.17 ns，**比 18.181 ns 的挑战档超 3.99 ns**，只是靠 22.274 ns 的 required（时钟树插入差）才勉强正 slack。

⭐⭐ **这不是"运气"，是"上一版修法的代价搬家"**：`:1564-1571` 的注释说 ROT32 把"输出端 32 lane 变量移位 mux"搬到了写侧，LUT 从 31039 降到 29622（**省 1417 LUT 属实**），但**代价是把 `32:1 mux + 移位器 + 乘法器 + 32 路写译码` 全塞进了一个周期**。省下的 LUT 买来了全设计最差路径 —— 而且它是**两档 PnR 里都排第一**的结构性路径。

**具体怎么改（一刀两段，位精确不变）**：把"算值"与"写值"分开，写侧用**寄存后的数据 + 寄存后的索引**：

```verilog
// 新增（g_t3 内）：写侧流水级
reg  [4:0]             rot_cnt_d;
reg                    wr_en_d;
reg  [PHASE_W-1:0]     wr_data_d;
wire [PHASE_W-1:0]     wr_data_v = ((semi_cur == 5'sd0) ||
                                    (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
                                  ? rot_base : (prod_w >>> 15);
always @(posedge clk_i) begin
    if (!rst_n_i) begin
        rot_cnt_d <= 5'd0; wr_en_d <= 1'b0; wr_data_d <= {PHASE_W{1'b0}};
    end else begin
        rot_cnt_d <= rot_cnt;
        wr_en_d   <= rot_ok;
        wr_data_d <= wr_data_v;
    end
end
// 原 if (rot_ok) phase_tr[rot_cnt] <= ...;  改成：
    if (wr_en_d) phase_tr[rot_cnt_d] <= wr_data_d;
```

**预期收益/代价**：
- 路径切成 **A: `rot_cnt` → mux → 移位器 → 乘法器 → FF ≈ 16.8 ns**（含 1.288 clk ⇒ ~18.1，仍紧）+ **B: FF → 写译码 → FF ≈ 5.4 ns**。
  ⇒ ⭐ 原来 22.172 ns 的**那 5.4 ns 尾巴被彻底移出关键路径**，第一名的 data delay 应落到 **≈17 ns**，slack ≈ **+1.2 ns**。
- 代价：**+55 FF**（32 数据 + 5 索引 + 1 使能，≈ Register 29% → 29.1%）· `phase_tr` 刷新延迟 **32 → 33 clk**（0.02 µs，听感无关）。
- ⚠️ **必须同步核对**：`tb/w3b/tb_transpose.sv:821/837` 的 T3 判据是"**34 拍内** 32 个 lane 全更新"⇒ 33 ≤ 34 **仍然绿，但余量从 2 拍掉到 1 拍**；`:503` 的 `repeat (60)` 也够。**这是本改动唯一的契约风险，必须在报告里显式记账。**
- ⛔ **本改动不碰 `oscillator_bank`** ⇒ `tb/models/oscillator_bank_ref.v`（P5-② 基线副本）**不需要同步**。

**怎么验证能红**：
1. **非空洞性**：把新增的 `wr_en_d/wr_data_d/rot_cnt_d` 改成直通（`phase_tr[rot_cnt] <= wr_data_v`），重跑 PnR ⇒ `timing_paths` 第 1 条必须回到 **22.1~22.2 ns / slack ~0.10** 量级；改回则必须掉到 ≤17.5 ns。
2. 四道门：综合 ERROR=0 → `tb_transpose` + `tb_p5_osc_equiv` + `tb_rot32_diff` → 干净 PnR 0/0 无 PR0004 → 全量回归"通过数==共数"。
3. 验收读数：`impl/pnr/Gowin2026.timing_paths` 里 **`g_t3.phase_tr` 必须从前 5 名消失**，且 `Actual Fmax` 应 ≥ 57 MHz（因为下一个绑定项是 prod_c 的 0.133 ns）。

---

## P0-2 · `tdm_render_mixer` 读侧：32:1 mux → 减法 → DSP 全组合（slack 0.133 ns，20.062 ns）

**文件**：`rtl/w3b/tdm_render_mixer.v:137`（`cnt_sel`）· `:235-255`（`vs_sum`/`vs_dif`/`vs_c`）· `:272-280`（`env_c`/`prod_c`）· `:310-333`（流水）
**实测路径（第 2 条，也是 7/25 条的同一结构）**：

```
SETUP  slack 0.133  data 20.062  required 20.194
  clk_ibuf                       0.000 → 1.288
  u_tdm_render_mixer/cnt_4_s0    4.142 → 4.486
  n4361_s3                       5.323 → 5.797
  n41_s88                        6.992 → 7.407
  n101_s44                      11.114 → 11.529   ← +3.7 ns 纯布线
  n101_s37                      13.393 → 13.857   ← +1.9 ns
  n101_s33                      14.289 → 14.754
  vs_dif_4_s                    16.281 → 16.724   ← 16 位借位链起点
  vs_dif_5..17_s                … 每个 +0.045    ← 串行借位链
  prod_c_0_s                    20.062            ← DSP 输入脚
```

**代码**：

```verilog
137:    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];
...
238:            vs_sum = vs_sum + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
246:            vs_dif = $signed(osc_sample_bus_i[cnt_sel*2*OSC_SAMPLE_W +: OSC_SAMPLE_W])
247:                   - $signed(osc_sample_bus_i[(cnt_sel*2+1)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
248:            vs_w   = $signed({vs_sum, 3'b0}) + vs_dif;
249:            vs_c   = vs_w >>> LANE_WS;
272:    wire [ENV_W-1:0] env_c = env_level_i[cnt_sel*ENV_W +: ENV_W];
280:    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;
```

**为什么是问题（机制 + 数字）**：
`cnt`（5 位计数器，寄存器）→ **1024 位扁平总线的 32:1 读 mux**（1024 条 mux 腿散在全片）→ 16 位加减法器 → **DSP 乘法器输入脚**，**一级寄存器都没切**。
- `cnt → mux 输出` = **14.754 − 4.486 = 10.27 ns**，其中**至少 7.4 ns 是纯布线**（n41→n101 三段 3.7 + 1.9 + 0.43）；
- `mux 输出 → DSP 输入` 再 **5.3 ns**（含 1.5 ns 布线 + 借位链 0.47 ns + 2.6 ns 到 DSP 脚）。
⇒ 合计 20.06 ns，**超挑战档 1.88 ns**。

⭐ **与 P0-1 同型**：这条链的两个"怪物"**都是"1024 位扁平总线 + 32:1 mux"**。这是本设计接缝上的头号结构特征，⛔ 不是某一处的偶然。

**具体怎么改（借 P3-1 的"免费预算"，净拍数不变）**：
在 mux 输出与算术之间插一级，并**同时把 `valid_d` 深度 5→4**（因为现在 `valid` 本来就比数据晚 2 拍，见 P3-1）：

```verilog
// ① 新增读侧流水级（busy 时有效）
reg signed [SUM_W-1:0] vs_c_r;
reg        [ENV_W-1:0] env_c_r;
always @(posedge clk_i) begin
    if (!rst_n_i) begin vs_c_r <= {SUM_W{1'b0}}; env_c_r <= {ENV_W{1'b0}}; end
    else if (busy) begin vs_c_r <= vs_c; env_c_r <= env_c; end
end
wire signed [SUM_W-1:0] vs_s = vs_c_r;              // 原为 vs_c
wire signed [ENV_W+0:0] env_s = $signed({1'b0, env_c_r});
// ② 累加窗口整体后移一拍：[1, CNT_LAST] → [2, CNT_LAST+1]
312:                if (cnt >= 1 && cnt <= CNT_LAST)   →  if (cnt >= 2 && (cnt <= CNT_LAST + 1'b1))
// ③ valid 深度 5 → 4（数据路径只多 1 级，valid 原先多 2 级 ⇒ 净拍数不变）
857:    reg [4:0] valid_d;  →  reg [3:0] valid_d;   （及 859/860 的初值/拼接同步）
863:    assign dry_valid_o = valid_d[4];  →  valid_d[3];
// ④ 顺手修 P1-1 的 cnt_sel（否则窗口一动就重复累加 voice 0）
```

**拍数核算（我逐拍推过）**：`cnt=k` 时 `vs_c`=voice k ⇒ 寄存后 `cnt=k+1` 时 `vs_c_r`=voice k ⇒ `prod_r` 在 `cnt=k+2` 时=voice k ⇒ 窗口 `[2, 33]` 恰好累加 voice 0..31，`CNT_TOTAL=34` 不动；`dry_valid` 仍在 **+39 clk = POLY_TARGET+7**。
⇒ ⭐ **`tb/w3b/tb_tdm_render_mixer.sv:246-247` 的判据 `k >= POLY+3 && k <= POLY+8` 原样绿**（不会像"只加级不改 valid_d"那样顶到 POLY+8 边界）。

**预期收益/代价**：
- 20.062 ns 切成 **A: `cnt` → mux → FF ≈ 11.5 ns** + **B: FF → 减法 → DSP → FF ≈ 5 ns** ⇒ 该结构**退出 Fmax 绑定项**。
- 代价：**+18 FF + 18 LUT**（一级 18 位寄存器），`valid_d` 少 1 位（−1 FF）。**零新增 DSP**。
- 与 P0-1 合并后的**总账**：两条绑定路径同时消失 ⇒ Fmax 由"下一条未列出的路径"决定，其 slack **> 0.851 ns** ⇒ **Fmax ≥ 57.7 MHz**；对 51.5 MHz 门槛的余量从 **1.34 ns（7.4%）升到 ≥2.09 ns（12%）**。

**怎么验证能红**：
1. **非空洞性**：把 `vs_c_r/env_c_r` 改回直连 `vs_c/env_c`（窗口不动）⇒ 跑 PnR，`prod_c_0_s` 必须回到 **20.06 ns / slack 0.13**。
2. `tb/w3b/tb_tdm_render_mixer.sv` 全绿（第 2 条 latency 在 `[POLY+3, POLY+8]`、第 3/4 条绝对值判据不变）+ `tb_velocity_headroom` + 全量回归。
3. `timing_paths` 里 `u_tdm_render_mixer/prod_c_0_s` 必须从前 5 名消失。

---

## P1-1 · `cnt_sel` 的"夹取"是**死代码**，`cnt[LW-1:0]` 直接回绕 —— TDM lane 对应关系的地雷

**文件**：`rtl/w3b/tdm_render_mixer.v:136-137`

```verilog
136:    localparam [LW-1:0] LAST_IDX = POLY_TARGET - 1;
137:    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];
```

**为什么是问题（机制 + 数字）**：
- `cnt` 是 `[LW:0]` = **6 位**（0..34），`LAST_IDX = [LW-1:0]` = **5 位** = 31。
- `cnt[LW-1:0]` 是 5 位（0..31），而 `LAST_IDX` 也是 5 位（31 = 5 位最大值）
  ⇒ 🔴 **`cnt[LW-1:0] > LAST_IDX` 恒为假** ⇒ **`cnt_sel` 恒等于 `cnt[4:0]`，那个三目钳位一次都没生效。**
- 于是 `cnt=32 → cnt[4:0]=0`（回绕）、`cnt=33 → 1`、`cnt=34 → 2`：**不是"夹到最后一个 voice"，而是绕回 voice 0/1/2。**
- `:130-135` 的注释写 *"⭐ 正确做法：用**最大索引**（`POLY_TARGET-1`）做夹取"* —— **注释描述的行为不存在**（这正是本项目反复复发的"注释↔代码不一致"）。
- **当前为什么没炸**：`cnt=32/33/34` 算出的 `prod_c` 落进 `prod_r` 的时刻分别是 33/34/35，而累加窗口是 `[1, CNT_LAST=32]` ⇒ 这三个值**都不被累加**。
  ⇒ 🔴 **但这是一颗引信**：**P0-2 的修法必须把窗口后移一拍**（`[2, 33]`）。窗口一动，`cnt=33` 累加的 `prod_r` 来自 `cnt=32` 的 `cnt_sel = 0` ⇒ **voice 0 会被累加两次**，多出来的幅度与信号相关（不是固定 offset）⇒ 混音绝对值判据必红，而且**原因极难定位**（现象是"单音偏大一点点"）。

**具体怎么改**（用**全宽** `cnt` 比较，再截低位）：

```verilog
wire [LW:0] cnt_c = (cnt > {1'b0, LAST_IDX}) ? {1'b0, LAST_IDX} : cnt;
wire [LW-1:0] cnt_sel = cnt_c[LW-1:0];
```

**预期收益/代价**：+1 个 6 位比较器 + 1 个 5 位 mux（≈ 8 LUT）。收益 = **把 P0-2 的修法从"会引入静默幅度错"变成"位精确"**，并让 `:130-135` 的注释第一次成为真话。

**怎么验证能红**：
1. **证明现在是死代码**：把 `:137` 换成 `wire [LW-1:0] cnt_sel = cnt[LW-1:0];` ⇒ 综合/仿真**结果完全不变**（这是"死代码"的直接证据）。
2. **证明它是引信**：在**不改** `cnt_sel` 的前提下，把 `:312` 的窗口改成 `cnt >= 1 && cnt <= CNT_LAST + 1'b1`，跑 `tb_tdm_render_mixer` 第 3/4 条（单 voice / 双 lane 加权绝对值）⇒ **必须红**；改好 `cnt_sel` 后同一实验必须绿。

---

## P1-2 · 归一化增益基准 **44 / 88 / 64 三处互斥** ⇒ 单音实交 24.9% FS，而文档承诺 69%（差 8.8 dB）

**文件**：`rtl/w3b/tdm_render_mixer.v:534` · `:566-585` · `:594-633` · `:684-685` · `rtl/top.v:4413`

```verilog
534:    // ── ② ⭐ `1/√N` 查表（⭐ Q8.7：**基准 44** = 满增益）──────────────────
566:    //   🔴🔴🔴 **2026-09-27 第六次修正：⭐ 基准 44 → 88（⭐ 失谐已生效，模型改了）**
584:    //      | **88** | **69%** | **68%** | **69%** | **68%** | **69%** | ✅
598:                6'd0:  gain_sqrt_lut = 16'd64;    // ⭐ 无 voice（增益无意义，取安全值）
599:                6'd1:  gain_sqrt_lut = 16'd64;    // 64/√1  = 64.0
...
684:            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r}))
685:                         >>> (7 + OUTPUT_HEADROOM_SH);
top.v:4413:            .OUTPUT_HEADROOM_SH  (1)
```

**为什么是问题（机制 + 数字）**：同一个文件里对"基准"有三种互斥说法，而**代码是 64**：
- `:534` 说 44；`:566/584` 说 88（并据此宣称"单音 69% 满幅、所有 N 恒定"）；`:598-630` 的表是 `round(64/√N)`，**基准 64**。
- 按代码实算（单 voice、力度 255、攻击峰）：
  ```
  vs_c   ≤ 32767                （9:7 加权后 = (9+7)×32767/16 = 32767）
  env_c  = 65280                （peak = 255<<8）
  prod   = 32767 × 65280 = 2.1389e9   （32 位有符号内，勉强）
  sh     = prod >>> 16   = 32636
  sh24   = sh <<< 8      = 8,354,816
  sh_norm= sh24 × 64 >>> (7+1) = 2,088,704
  满幅(24 位) = 8,388,607  ⇒  24.9% FS  =  −12.1 dBFS
  ```
  ⇒ 🔴 **实交 24.9%，文档承诺 69%，差 8.8 dB。** 两个独立因子各贡献一半：
  **① 基准 88 → 64（−2.8 dB）② `OUTPUT_HEADROOM_SH=1`（−6.02 dB，`:4410-4413` 后加的）。**
- ⚠️ 这正是本项目已经栽过一次的坑（`:356-393` 那段"输出量纲少了 16→24 定标 ⇒ 声音极小 + 电流声"）。**同一类量纲/标定不一致又回来了，只是这次没有"完全没声"，所以没人发现。**

**具体怎么改（二选一，必须显式定案，⛔ 不许再留第三种说法）**：
- **A（改代码对齐文档）**：把 `gain_sqrt_lut` 全表按 `round(88/√N)` 重算（`n=1→88, 2→62, 4→44, 8→31, 16→22, 32→16`），并同步改 `:598-630` 的行内注释。
- **B（改文档对齐代码）**：把 `:534/566/584` 的"44/88/69%"全部改成"**基准 64，且 `OUTPUT_HEADROOM_SH=1` ⇒ 单音峰 24.9% FS**"，并在 `:4413` 旁写明这是**有意的 −12 dB 余量**。
- 无论哪条，都要在 `initial` 自检里加一条**可执行的**不变量，例如：
  ```verilog
  if ((OUTPUT_HEADROOM_SH != 0) && (gain_sqrt_lut(6'd1) != 16'd88))
      $display("WARNING [tdm_render_mixer] 单音基准与文档标定不一致（见 :566 的 88 口径）");
  ```

**预期收益/代价**：选 A 则**单音响度 +8.8 dB**（回到文档承诺），代价是**软限幅器介入概率上升**（`:713-719` 记录的"两 lane 周期性 100% 同相 ⇒ 138% 满幅 ⇒ 折点产生谐波 ⇒ 音色不同的音"**可能复发**）⇒ ⭐ **选 A 必须同时重跑 `tb_polyphony_onset_step` + 上板听"尖音"**。选 B 零风险，纯粹把标定讲清楚。

**怎么验证能红**：
- 直接量：跑 `tb/w3b/tb_velocity_headroom.sv`（或 `tb/top/tb_top_sound.sv`）取 `sample_mono` 的峰值，除以 `2^23`，与 `:584` 表格的 69% 对比 ⇒ 现在必得 **≈0.25**。
- 算术自检：把上面 6 行算式写成 tb 里的断言 ⇒ 现在**红**（期望 0.69 / 实得 0.249）。

---

## P1-3 · `master_mix` 输出**纯组合**：全链唯一一个"模块输出不寄存"，DSP + 饱和夹在两个 FF 之间

**文件**：`rtl/w3c/master_mix.v:107-128` · `rtl/top.v:4486-4490`

```verilog
107:    wire signed [PROD_W-1:0] prod = sample_i * $signed({1'b0, gain_r});
108:    wire signed [PROD_W-1:0] scaled = prod >>> (GAIN_W - 1);   // >> 15
113:    wire over_pos = ~scaled[PROD_W-1] && (|scaled[PROD_W-2 : SAMPLE_W-1]);
114:    wire over_neg =  scaled[PROD_W-1] && ~(&scaled[PROD_W-2 : SAMPLE_W-1]);
116:    reg signed [SAMPLE_W-1:0] samp_r;
117:    always @(*) begin                       // ← 组合
118:        if (over_pos)      samp_r = {1'b0, {(SAMPLE_W-1){1'b1}}};
120:        else if (over_neg) samp_r = {1'b1, {(SAMPLE_W-1){1'b0}}};
122:        else               samp_r = scaled[SAMPLE_W-1:0];
124:    end
127:    assign valid_o  = valid_i;              // ← 零延迟透传
128:    assign sample_o = samp_r;
```
```verilog
top.v:4487:        always @(posedge clk) begin
top.v:4488:            if (!rst_n_sync) sample_r <= {SAMPLE_W{1'b0}};
top.v:4489:            else if (mm_valid) sample_r <= mm_sample;   // ← 直接吃组合输出
```

**为什么是问题（机制 + 数字）**：
`u_tdm_render_mixer/samp_r`（FF）→ **24×16 乘法器（DSP `MULTALU27X18`，全设计共 7 个）** → 40 位算术右移 → **40 位逐位溢出归约（两级 AND/OR 树）** → 3 选 1 mux → `top.sample_r` 的 D 脚，**中间零寄存器**。
⇒ 与 `:800-825` 里**已经被修掉的那条**完全同型（那里 `samp_r` 从 `always @(*)` 改成真寄存器，实测"slack = **0.002 ns**、27 级逻辑"）。
- **诚实记账**：这条路径**不在**当前 `timing_paths` 的 25 条 SETUP 里（第 25 名的 data delay 是 19.36 ns）⇒ ⭐ **实测它 < 19.36 ns，当前不是瓶颈**（`master_mix` 只在报告里出现 3 次，全是 HOLD 的 `gain_r_11_s0` 自环，data 2.46 ns）。
- ⇒ 所以本条的收益是 **余量/结构卫生**，⛔ 不是"当前违例"。**但它是这条链上最后一个未寄存的模块输出**，而它下游就是**输出寄存器**（`top.sample_r`），改动成本极低、风险极低。

**具体怎么改**：

```verilog
reg signed [SAMPLE_W-1:0] samp_r;
reg                       valid_r;
always @(posedge clk_i) begin
    if (!rst_n_i) begin
        samp_r <= {SAMPLE_W{1'b0}}; valid_r <= 1'b0;
    end else begin
        valid_r <= valid_i;
        if (over_pos)      samp_r <= {1'b0, {(SAMPLE_W-1){1'b1}}};
        else if (over_neg) samp_r <= {1'b1, {(SAMPLE_W-1){1'b0}}};
        else               samp_r <= scaled[SAMPLE_W-1:0];
    end
end
assign valid_o = valid_r;   // ⭐ 数据加一级，valid 必须同步加一级
```

**预期收益/代价**：把"DSP + 40 位归约 + mux"从"两个 FF 之间的单周期"变成"**一级寄存器输出**"。
- 代价：**+25 FF**、`master_mix` 延迟 **+1 clk（20 ns）**。
- ⚠️ **对 `i2s_tx` 完全无害**：`mm_valid` 从 `tick+136` 变成 `tick+137`，而 `frame_start` 在 `tick+1024` ⇒ **余量 887 拍**。
- ⚠️ **`tb/w3c/tb_master_mix.sv` 的 latency 判据要同步 +1**（这是本项目"加了几级数据寄存器，valid 就要跟着延几级"的既有纪律）。
- ⚠️ 顶层 `top.v:4489` 的 `if (mm_valid) sample_r <= mm_sample;` **一字不改**（它本来就是"吃 valid 存一拍"）。

**怎么验证能红**：
1. 综合前后对比 `timing_paths` 里若出现 `u_master_mix/*_s0` 的 SETUP 路径，比较其 data delay；用 `tb_master_mix` 的 latency 断言确认 +1。
2. **非空洞性**：把 `valid_r` 改成 `assign valid_o = valid_i;` 而数据仍寄存 ⇒ `tb_master_mix` 的"valid 与数据同拍"判据**必须红**（这是流水线改造最经典的错法）。

---

## P1-4 · `tb_transpose` 的 `oct_allow` **假绿**：tb 以为 RTL 有"换档静音门槛"，RTL 里**根本不存在**

**文件**：`tb/w3b/tb_transpose.sv:465` · `:683` vs `rtl/w3b/note_manager.v:428-438`

```verilog
tb:465:    //  ⭐ 等"全部 gate 落 0"（⭐ = RTL 的换档静音门槛 `oct_allow`），⭐ 带超时守卫
tb:683:            //  ⭐⭐ P4-ROT32：⭐ **换档必须在"静音"状态做**（⭐ 与 RTL 的 `oct_allow` 同口径）
```
```verilog
note_manager.v:428:    always @(posedge clk_i) begin
note_manager.v:429:        if (!rst_n_i) base_oct_r <= 2'd0;
note_manager.v:430:        else if (base_commit_i) begin          // ← 只有这一个条件，没有 gate 守卫
note_manager.v:431:            case (base_semi_i)
note_manager.v:432:                7'd0 :   base_oct_r <= 2'd0;
...
```

**为什么是问题（机制 + 数字）**：
- `grep -r oct_allow rtl/` = **0 命中**。`oct_allow` 属于**已回退的 P4-ROT32 设计**（tb `:858-862` 自己写了"ROT32 已按用户裁定【回退】"）。
- ⇒ 🔴 **tb 仍然按"RTL 有静音门槛"的假设去组织测试**（换档前先等 `gate` 全 0），于是**这条路径永远没被验证**；而真实 RTL 在 `base_commit_i` 到来时**无条件立即改 `base_oct_r`**。
- 真实后果（机制）：`base_oct_r` 变 ⇒ `phase_tr` 的影子数组要**≤32 clk**才把 32 个 lane 刷完 ⇒ 这 32 clk 内**部分 lane 用新八度、部分用旧八度**。
  - 大部分情况被"相位只在 `sample_tick` 前进"掩盖（32 < 1024）；
  - 🔴 **但 `base_commit_i` 落在某次 tick 前 ≤32 clk 时**，那一帧（**20.48 µs**）就是**混八度**的 ⇒ 8 度错音的单帧瞬态。
  - 触发条件：UART 发"起始音"命令（`'F'/'G'/'H'` → `ui_base_commit`）**恰好在演奏中**。这是**用户可达**的操作。
- ⇒ 这是本项目 `C83`（探针假绿）的同族：**tb 通过 ≠ 该路径被覆盖**。

**具体怎么改（二选一，必须选一个并写进代码）**：
- **A（补 RTL 守卫，让 tb 的假设成真）**：给 `base_oct_r` 的提交加"全部 voice 的 `gate_r` 为 0"门槛（即真正的 `oct_allow = ~|gate_r`），并把 `base_commit_i` 在非静音时**挂起**（存一个 pending 位，等 `gate_r` 全 0 再提交）。代价：+1 FF + 一个 32 位 OR（≈ 11 LUT）。
- **B（承认没有门槛，改 tb + 改注释）**：删掉 `:465/:683` 的 `oct_allow` 说法，改成"⭐ **RTL 无静音门槛**，本 tb **故意**在静音时换档以避免 32 clk 瞬态；该瞬态的**上界 = 1 帧（20.48 µs）混八度**"，并**新增一条定向用例**：**发声中途**发 `base_commit`，断言"至多一帧内出现 lane 间 `phase_inc` 不一致，且**下一帧必须完全一致**"。

**预期收益/代价**：A = 消除一个可达的单帧错音瞬态；B = 零 RTL 风险，把一个假绿变成真覆盖。**推荐 A**（用户可达、代价 11 LUT），但 A 会改变 `base_commit` 的生效时刻 ⇒ **必须同步 `tb_base_semi.sv`**。

**怎么验证能红**：
- **证明假绿**：在 `tb_transpose` 里**去掉** `oct_switch` 的静音等待（改成"发声中途直接 commit"）⇒ 现在**必红**（因为 RTL 无守卫，会出现混八度帧）。
- **证明 A 生效**：加守卫后，同一用例必须绿，且"下一帧完全一致"。

---

## P2-1 · `envelope_bank` 没有任何 `PARAM_OK`/`CLK_PER_SAMPLE` 自检：tick 间隔不够会把 **32 个 voice 的包络整体置换**

**文件**：`rtl/w3b/envelope_bank.v:323-347`（整个模块**没有 `initial` 块**，`grep initial|PARAM|CLK_PER_SAMPLE` 只命中 `:30` 的注释）

```verilog
332:        end else if (sample_tick_i) begin
333:            cnt     <= {(AW+1){1'b0}};          // ← tick 一来就把 cnt 归零
334:            running <= 1'b1;
335:        end else if (running) begin
336:            if (cnt != {(AW+1){1'b0}}) begin
337:                lvl_sr <= {lvl_n, lvl_sr[POLY_TARGET*ENV_W-1:ENV_W]};   // ← 旋转移位
338:                st_sr  <= {st_n,  st_sr[POLY_TARGET*2-1:2]};
339:                rel_sr <= {rel_n, rel_sr[POLY_TARGET-1:1]};
340:                env_level_o[svc_i*ENV_W +: ENV_W] <= lvl_n;
341:                env_active_o[svc_i]                <= act_n;
```

**为什么是问题（机制 + 数字）**：
- 该模块的**状态（`lvl_sr/st_sr/rel_sr`）是"旋转"的**，它的**头指针身份 = `cnt`**。⇒ 语义要求：**两次 `sample_tick_i` 之间必须 ≥ 34 clk**（32 个 voice + prefetch + 1）。
- 🔴 **如果 tick 间隔 < 34 clk**：`cnt` 被强制归零，但移位寄存器**已经转了 j 位** ⇒ 从此以后 `cnt=1` 服务的不是 voice 0 而是 voice j
  ⇒ ⭐ **全部 32 个 voice 的包络状态被整体置换（cyclic shift）**，而 `env_level_o[v]` 与 voice v 的对应关系**永久错位**。
- 这**不是**"丢一个采样"，是**持久性数据错乱**；而 `tdm_render_mixer` 的同类契约（`CNT_TOTAL > CLK_PER_SAMPLE`）**有**自检（`:875-881`），**这里没有**。
- ⚠️ 而且 `envelope_bank` **连 `CLK_PER_SAMPLE` 这个参数都没有** ⇒ 顶层 `top.v` 想传也传不进来 ⇒ **这个契约在工程里根本不可见**（只在文件头 `:30` 的一句英文注释里）。
- 当前交付 `CLK_PER_SAMPLE=1024` ⇒ **不可达**；但这是本项目 `K-106`（"任何容量有限的东西都必须可观测"）明确要防的一类。

**具体怎么改**：

```verilog
module envelope_bank #(
    ...
    parameter integer CLK_PER_SAMPLE = 1024,   // ⭐ 新增：与 clk_gen/top 同源
    parameter integer MIN_TICK_GAP   = POLY_TARGET + 2
) ( ... );
    initial begin
        if (CLK_PER_SAMPLE < MIN_TICK_GAP)
            $display("ERROR [envelope_bank] CLK_PER_SAMPLE=%0d < %0d => 两次 tick 之间轮转跑不完，32 个 voice 的包络会被【整体置换】",
                     CLK_PER_SAMPLE, MIN_TICK_GAP);
    end
```
并在 `top.v` 的例化里显式 `.CLK_PER_SAMPLE(1024)`（与 `.CLK_PER_SAMPLE(1024)` 的 mixer 例化并排，让两处口径在源码里可见）。

**预期收益/代价**：**+0 逻辑**（纯 `initial`，综合工具忽略）· 改动风险 ≈ 0。收益 = 把一个"静默置换 32 路包络"的失效模式变成**仿真启动即报错**。

**怎么验证能红**：`tb/w3b/tb_envelope_bank.sv` 里把 tick 间隔改成 **20 clk** ⇒ 新增的 `$display` 必须打印 ERROR（红）；同时可断言 `env_level_o` 与 voice 的对应关系**已经错位**（这是"置换"而非"丢采样"的直接证据）。

---

## P2-2 · `oscillator_bank` 的"帧内截止"自检**写死 1024 且只查 `LANES`**：真正的约束是 `LANES+2 ≤ CLK_PER_SAMPLE`

**文件**：`rtl/w3b/oscillator_bank.v:900-905`

```verilog
900:    //    ⭐ `LANES` 必须 ≤ `CLK_PER_SAMPLE`（1024），否则 **TDM 跑不完一帧**
902:    initial begin
903:        if (LANES > 1024)
904:            $display("ERROR [oscillator_bank] LANES=%0d > 1024（每帧可用 clk 数）=> TDM 跑不完一帧，A6 必然失败", LANES);
```

**为什么是问题（机制 + 数字）**：
- TDM 实际需要 **`LANES + 2`** 拍（`:729` 的 `cnt == LANES` 终止 + `:734` 的 valid 一拍），而且 `ob_valid` 要到 **`tick+65`** 才出现（LANES=64 时）。
- 🔴 **真正的约束是 `LANES + 2 ≤ CLK_PER_SAMPLE`**，而代码只查 `LANES > 1024` ⇒ **`LANES = 1024` 时它判"合法"，但 TDM 需要 1026 拍 ⇒ 一帧内跑不完**。
- 🔴 而且这个 **1024 是硬编码的魔数**，与 `clk_gen.CLK_PER_SAMPLE` / `tdm_render_mixer.CLK_PER_SAMPLE` **没有任何同源保证**（后者是从 `top.v:4403` 显式传进去的参数）。
- 违反时的**现象**（机制）：`sample_tick_i` 在 `rendering=1` 时到来 ⇒ `cnt<=0`、`rendering<=1` ⇒ `cnt` **永远到不了 `LANES`** ⇒ `valid_r` **永不置位** ⇒ `ob_valid` 恒 0 ⇒ `mx_render_start` 恒 0 ⇒ **混音器永不渲染 ⇒ 完全静音**，而 `deadline_fault_o` 也不会报（它只看 `cnt`）。
- ⇒ **"TDM 跑不完一帧"的真实后果是"彻底没声"，⛔ 不是"随机丢样本"**（`:901` 的注释把现象说轻了）。

**具体怎么改**：

```verilog
parameter integer CLK_PER_SAMPLE = 1024,      // ⭐ 新增参数
...
    if ((LANES + 2) > CLK_PER_SAMPLE)
        $display("ERROR [oscillator_bank] LANES+2=%0d > CLK_PER_SAMPLE=%0d => TDM 一帧跑不完，ob_valid 永不出现 ⇒ 全静音",
                 LANES + 2, CLK_PER_SAMPLE);
```
并在 `top.v:4215` 的例化里加 `.CLK_PER_SAMPLE(1024)`（与 `.CLK_PER_SAMPLE(1024)` 的 mixer 例化并排）。

**预期收益/代价**：**+0 逻辑** · ⚠️ **注意**：给 `oscillator_bank` 加参数属于**改队友文件**，且 `tb/models/oscillator_bank_ref.v`（P5-② 基线副本）是它的逐位等价参照 —— ⭐ **新增一个 `parameter` 不影响任何逐位行为**（`initial` 块综合时被忽略，参数不参与运算），所以 `tb_p5_osc_equiv` **不受影响**；但按项目纪律，**改 `oscillator_bank.v` 必须在同一个提交里同步 `tb/models/oscillator_bank_ref.v` 的端口/参数清单**，否则 `tb_p5_osc_equiv` 会以"端口不一致"的形式假红。

**怎么验证能红**：在 `tb/w3b/tb_oscillator_bank.sv` 里把 `LANES` 临时设成 1024（或 `POLY_TARGET=512`）⇒ 新自检必须打印 ERROR；把 `CLK_PER_SAMPLE` 设成 1024 并 `LANES=1022` ⇒ 应打印（1024 > 1024 为假、1024+2 > 1024 为真）。

---

## P2-3 · `oscillator_bank.drum_cls_i` **缺 Z-safe 解码**（同一文件另外 6 处都有）

**文件**：`rtl/w3b/oscillator_bank.v:399-405`

```verilog
399:            wire drum_v  = (voice_drum_i[vg] === 1'b1);        // ← Z-safe ✅
400:            wire is_kick = drum_v && ((DRUM_CLS_EXT != 0)
401:                                      ? drum_cls_i[vg*2 + 1]      // ← ⛔ 裸引用
402:                                      : (bv <  DRUM_KICK_MAX_C));
403:            wire is_tom  = drum_v && ((DRUM_CLS_EXT != 0)
404:                                      ? drum_cls_i[vg*2 + 0]      // ← ⛔ 裸引用
405:                                      : ((bv >= DRUM_KICK_MAX_C) && (bv < DRUM_TOM_MAX_C)));
```

**为什么是问题（机制 + 数字）**：
- 本文件的 Z-safe 纪律是**显式写进注释**的（`:221-223` `voice_phase_rst_i`、`:497-500` `phase_rst_lane`、`:699-707` `lane_drum`），`note_manager` 也有 4 处（`vu_src_w`/`pu_src_w`/`ns_src_w`/`sus_pedal_i`）。**唯独 `drum_cls_i` 漏了。**
- ⇒ 任何"`DRUM_CLS_EXT=1` 但 `drum_cls_i` 悬空"的例化（将来新增顶层/tb/换板最可能踩）：
  `drum_cls_i[..] = z` ⇒ `is_kick/is_tom = x` ⇒ `sweep_load = x` ⇒ `sweep_q = x` ⇒ `so_v = x` ⇒ `inc_main_w = x` ⇒ 🔴 **相位增量全 `x`，两个 lane 一起变噪声，而综合器不报错、仿真里 tb 也未必红**（`x` 在三目/加法里常常"看起来还在跑"）。
- ⚠️ 讽刺的是：`DRUM_CLS_EXT=1` **就是生产档**（`top.v:4214`），而**所有 tb 都用默认 0**（只有 `tb/w3b/tb_osc_drum_cls.sv` 显式用 1，且它接了 `drum_cls_i`）⇒ **生产档的这条输入一旦漏接，没有任何一层会报警**。

**具体怎么改**（与同文件其它 5 处同款）：

```verilog
wire is_kick = drum_v && ((DRUM_CLS_EXT != 0)
                          ? (drum_cls_i[vg*2 + 1] === 1'b1)
                          : (bv <  DRUM_KICK_MAX_C));
wire is_tom  = drum_v && ((DRUM_CLS_EXT != 0)
                          ? (drum_cls_i[vg*2 + 0] === 1'b1)
                          : ((bv >= DRUM_KICK_MAX_C) && (bv < DRUM_TOM_MAX_C)));
```

**预期收益/代价**：每 voice +2 个 1 位比较（≈ 64 LUT，`CLS 78%` 影响 <0.3%）。收益 = 消灭一个"生产档漏接线 ⇒ 全噪声且零报警"的失效模式。
⚠️ **本改动碰 `oscillator_bank`** ⇒ ⭐ **必须同步 `tb/models/oscillator_bank_ref.v`**（P5-② 基线副本）；但注意：**ref 副本里根本没有 `drum_cls` 相关端口/逻辑**（`grep drum_cls tb/models/oscillator_bank_ref.v` = 0 命中）⇒ 说明 ref 副本**已经落后于 A3 改动**，本次同步的正确做法是**把 ref 副本的 `DRUM_CLS_EXT` 分支一起补上**，否则 `tb_p5_osc_equiv` 在 `DRUM_CLS_EXT=1` 下**本来就无法逐位对齐**（它现在只能靠"两边都取 0 档"来绿 —— 这是一个**独立于本条的既有覆盖率缺口**，见 §四 未覆盖项）。

**怎么验证能红**：新建/改 `tb/w3b/tb_osc_drum_cls.sv`：`DRUM_CLS_EXT=1` 且 **`drum_cls_i` 悬空不接** ⇒ 断言 `phase_acc_dbg_o` 在 N 拍内**不得出现 x**（`!== ` 判据）⇒ 现在**必红**；加 `===` 后必绿。

---

## P2-4 · 两个软膝平方器**互斥** ⇒ 可以共享一个，省 ≈700 LUT / CLS ≈2%

**文件**：`rtl/w3b/tdm_render_mixer.v:747-773`

```verilog
747:    wire signed [ACC_W+15:0] exc_pos = (sh_norm_w > LIM_TH_W)
748:                                    ? (sh_norm_w - LIM_TH_W) : {(ACC_W+16){1'b0}};
749:    wire signed [ACC_W+15:0] exc_neg = (sh_norm_w < -LIM_TH_W)
750:                                    ? ((-LIM_TH_W) - sh_norm_w) : {(ACC_W+16){1'b0}};
...
772:            exc_pos_sq_d <= (exc_pos * exc_pos) >>> 21;
773:            exc_neg_sq_d <= (exc_neg * exc_neg) >>> 21;
```

**为什么是问题（机制 + 数字）**：
- `exc_pos` 与 `exc_neg` **永远不可能同时非零**（一个是 `sh>T`，一个是 `sh<−T`，条件互斥）。
  ⇒ 两个 `exc*exc` 平方器里，**任意时刻至多一个在做有效工作**。
- 有效位宽：`|sh_norm|` 的量级 ≤ 2^25（见 P1-2 的算式，单音 2.09e6，满复音 ≤1.15e7）⇒ `exc` ≤ 2^25 ⇒ 平方 ≤ 2^50，`>>>21` 后 ≤ 2^29。
  ⇒ 每个平方器实际是 **~26×26 的乘法**，Gowin 会展开成 LUT（`DSP 22/118` 已被别处占掉，`:751-753` 的注释也确认它们被单独切了一级寄存器，说明它们**是 LUT 实现的长组合**）。
- 粗估：26×26 无符号平方 ≈ 300~350 LUT ⇒ **两个 ≈ 650~700 LUT**，占 `LUT 27135` 的 **2.4~2.6%**，CLS 78% 可望降到 **~76%**。

**具体怎么改（位精确）**：

```verilog
// 互斥 ⇒ 一个平方器服务两侧
wire signed [ACC_W+15:0] exc_sel = (sh_norm_w > LIM_TH_W) ? exc_pos : exc_neg;
wire signed [ACC_W+15:0] exc_sq  = (exc_sel * exc_sel) >>> 21;
always @(posedge clk_i) begin
    ...
    exc_pos_sq_d <= exc_sq;      // 两侧都吃同一个值
    exc_neg_sq_d <= exc_sq;      // 只有对应的那一侧会被 knee_pos/knee_neg 用到
end
```
**位精确论证**：`knee_pos` 只在 `sh_norm_d > LIM_TH_W` 时被 `lim_pos` 取用，`knee_neg` 只在 `sh_norm_d < −LIM_TH_W` 时被 `lim_neg` 取用，**两者互斥**；`exc_sel` 的选择条件与 `exc_pos/exc_neg` 的定义条件**逐字相同** ⇒ 被用到的那一支**拿到的是同一个值** ✅。`|sh| ≤ T` 时两个 `exc` 都是 0、`exc_sq` 也是 0、两个都取不到 ⇒ 无影响 ✅。

**预期收益/代价**：**−300~350 LUT / −≈1.5~2% CLS**；代价 **+1 个 40 位 mux（≈40 LUT）** ⇒ **净省 ≈260~310 LUT**。⛔ 不动任何拍数、⛔ 不动 `valid_d`、⛔ 不动饱和口径。

**怎么验证能红**：
1. 综合报告 `T_Lut`（或 `impl/pnr/Gowin2026.rpt.txt` 的 `LUT,ALU,ROM16`）必须**下降 250~350**；CLS 必须**下降 ≥1%**。
2. `tb/w3b/tb_tdm_render_mixer.sv` 的限幅相关判据（`:135-190` 的 WIDE 实例，专门打限幅）**必须全绿**。
3. **非空洞性**：把 `exc_sel` 改成恒取 `exc_pos` ⇒ WIDE 用例的负半周限幅判据**必须红**。

---

## P2-5 · `master_mix`：对 `integer` 参数做位选（K-91），且 `gain_i < 0x8000` 这条不变量**无人守**

**文件**：`rtl/w3c/master_mix.v:85-88`

```verilog
85:    wire [GAIN_W-1:0] gain_up_v   = (gain_r + RAMP_STEP[GAIN_W-1:0] < gain_i)
86:                                  ? (gain_r + RAMP_STEP[GAIN_W-1:0]) : gain_i;
87:    wire [GAIN_W-1:0] gain_dn_v   = (gain_r - RAMP_STEP[GAIN_W-1:0] > gain_i)
88:                                  ? (gain_r - RAMP_STEP[GAIN_W-1:0]) : gain_i;
```

**为什么是问题（机制 + 数字）**：
1. 🔴 **`RAMP_STEP[GAIN_W-1:0]` 是对 `parameter integer` 做位选** —— 这正是本项目写进硬约束的 `K-91` 禁令（"⛔ 不对 `integer` 参数做位选"）。当前 `RAMP_STEP=128 < 2^16` ⇒ 侥幸正确；**`RAMP_STEP ≥ 65536` 时会被静默截断**（如 70000 → 4464），而 `:135-136` 的自检**只查 `RAMP_STEP < 1`**。
2. 🔴 **`gain_r + RAMP_STEP` 是 16 位无符号加法，会回绕**。`gain_up_v` 的判据是"加上一步还**小于**目标"，但**加法本身先回绕**：
   `gain_r = 0xFF80, RAMP_STEP = 128` ⇒ `gain_r + 128 = 0x10000 → 0x0000` ⇒ `0 < gain_i` 为真 ⇒ **`gain_r <= 0`** ⇒ ⭐ **音量瞬间归零（静默故障）**，而不是"到达目标"。
   可达性：回绕需要 `gain_r ≥ 0xFF80` 且 `ramp_up`（`gain_r < gain_i`）⇒ 需 **`gain_i ≥ 0xFF81`**（即增益 ≥ 1.9961）。当前 `right_analog_ctrl.v:25-92` 的 LUT **最大 29364（idx 62）、default `0x7FFF`** ⇒ **实际不可达**；但 `:58` 只写了"⭐ 最高位须为 0（分数）"，**没有任何 `initial` 断言**，而 `master_mix` 是**通用模块**（`GAIN_W` 可参数化）。

**具体怎么改**：

```verilog
// ① K-91：先落成定宽 localparam
localparam [GAIN_W-1:0] RAMP_STEP_W = RAMP_STEP;
// ② 加宽一位再比较，彻底消除回绕
wire [GAIN_W:0] gain_r_x   = {1'b0, gain_r};
wire [GAIN_W:0] step_x     = {1'b0, RAMP_STEP_W};
wire [GAIN_W:0] tgt_x      = {1'b0, gain_i};
wire [GAIN_W-1:0] gain_up_v = ((gain_r_x + step_x) < tgt_x) ? (gain_r + RAMP_STEP_W) : gain_i;
// ③ 自检补两条
initial begin
    if (RAMP_STEP >= (1 << GAIN_W))
        $display("ERROR [master_mix] RAMP_STEP=%0d >= 2^GAIN_W=%0d => 斜坡步长会被静默截断", RAMP_STEP, (1<<GAIN_W));
end
// ④ `gain_i < 0x8000` 这条不变量只能在上游断言（模块内拿不到 gain_i 的静态上界）：
//    right_analog_ctrl.v 的 LUT 处加
//      if (master_gain_lut(6'd62) >= 16'h8000) $display("ERROR [right_analog_ctrl] 主音量 >= 1.0，会让 master_mix 的斜坡加法回绕");
//    top.v 里加
//      initial if (master_gain[15]) $display("ERROR [top] master_gain MSB=1 => master_mix 斜坡会回绕到 0（静默失声）");
```
（第 ③ 条里对 `gain_i` 的检查只能放 `top.v`：`if (master_gain[15]) $display("ERROR …")`，或直接给 `right_analog_ctrl` 的 LUT 加一条 `initial` 断言"全表 < 0x8000"。）

**预期收益/代价**：+1 位加法器 ×2（≈4 LUT）· **消除两个"静默失效"入口**（截断 + 回绕），符合 `K-106` 纪律。

**怎么验证能红**：
- 截断：把 `RAMP_STEP` 设成 70000 ⇒ 新自检必须打印 ERROR；旧代码下 `gain_up_v` 的行为与 `RAMP_STEP=4464` **完全相同**（这是"静默截断"的直接证据）。
- 回绕：写一个定向 tb，`gain_i = 16'hFF80`、`gain_r` 从 `16'hFF00` 起步 ⇒ 旧代码 `gain_r` **跳到 0**（断言"单调不减"必红），新代码必须单调到 `gain_i`。

---

## P3-1 · `dry_valid_o` 比数据**晚 2 拍**（`valid_d[4]` vs 3 级数据）—— 顺便这是 P0-2 的"免费预算"

**文件**：`rtl/w3b/tdm_render_mixer.v:826-863`

```verilog
826:    reg signed [SAMPLE_W-1:0] samp_r;         // 数据级 ③
857:    reg [4:0] valid_d;
860:        else          valid_d <= {valid_d[3:0], valid_r};
863:    assign dry_valid_o      = valid_d[4];     // ← 第 5 级
```

**逐拍核算（`acc_r` 终值那拍记为 T）**：

| 拍 | 数据到哪一级 | valid 到哪一级 |
|---|---|---|
| T | `acc_r` 终值 | `valid_r` = 1 |
| T+1 | `sh_norm_r`（乘法级） | `valid_d[0]` |
| T+2 | `exc_pos_d`/`sh_norm_d`/`exc_pos_sq_d` | `valid_d[1]` |
| T+3 | **`samp_r`（数据已稳）** | `valid_d[2]` |
| T+4 | — | `valid_d[3]` |
| T+5 | — | **`valid_d[4]` = `dry_valid_o`** |

⇒ ⭐ **数据在 T+3 就稳了，`dry_valid_o` 到 T+5 才来 —— 晚了 2 拍。**

**为什么是问题**：不是功能错（`samp_r` 是寄存器，会保持），但
1. **契约不自洽**：`tb/w3b/tb_tdm_render_mixer.sv:246-247` 把延时钉在 `POLY_TARGET+7`（范围 `[POLY+3, POLY+8]`），而这个数**包含这 2 拍多余延迟** ⇒ 任何人给 `samp_r` 再加一级都会**顶到 `POLY+8` 边界**（当前已经是 `+7`，只剩 1 拍余量）。
2. ⭐ **它正好是 P0-2 需要的那 2 拍预算**：加一级读侧流水后，数据在 T+4 稳，`valid_d[3]` 恰好在 T+4 ⇒ **总延时仍是 `POLY_TARGET+7`，tb 判据一字不改**（见 P0-2 的修法 ③）。

**具体怎么改**：与 P0-2 合并执行 —— `valid_d` 由 `[4:0]` 改 `[3:0]`、`dry_valid_o = valid_d[3]`。若**不**做 P0-2，则本条的独立修法是把 `valid_d` 改成 `[2:0]` + `dry_valid_o = valid_d[2]`（延时变 `POLY_TARGET+5`，仍在 `[POLY+3, POLY+8]` 内），并在 `:838-856` 的注释里把"深度 3 → 4 → 5"的历史账改成"**数据 3 级 / valid 应有 3 级**"。

**预期收益/代价**：−2 FF · 消除"valid 与数据不同拍"的语义债 · 为 P0-2 提供净零拍数的插入空间。

**怎么验证能红**：在 tb 里断言 `dry_valid_o` 那一拍读到的 `dry_sample_o` **与 T+3 拍读到的完全相同**（`samp_r` 已稳）；再断言 `valid_d[2]` 那拍数据**已经正确**（用 `samp_r` 的层次引用或再加一个探针）⇒ 证明"valid 晚 2 拍"。

---

## P3-2 · `PROD_W` 比真实积**少 1 位**（34 vs 35），靠 `SUM_W` 的余量侥幸安全

**文件**：`rtl/w3b/tdm_render_mixer.v:96-98` · `:279-280`

```verilog
 96:    localparam integer SUM_W = OSC_SAMPLE_W + OW + 1;    // 16+1+1 = 18
 98:    localparam integer PROD_W = SUM_W + ENV_W;           // 18+16 = 34
279:    wire signed [ENV_W:0]     env_s  = $signed({1'b0, env_c});   // ← 17 位
280:    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;             // ← 18×17 = 35 位表达式
```

**为什么是问题**：`vs_s` 是 `signed [17:0]`（18 位）、`env_s` 是 `signed [16:0]`（17 位）⇒ **Verilog 的乘法结果宽度 = 18+17 = 35 位**，赋给 34 位的 `prod_c` ⇒ **最高位被截掉**。
- **当前为什么没炸**：`vs_c` 经 9:7 加权后 `|vs_c| ≤ 32768`，`env_c ≤ 65535` ⇒ `|prod| ≤ 32768×65535 = 2,147,450,880 < 2^31` ⇒ **32 位就够了**，34 位绰绰有余。
- 🔴 **但它不是"设计出来的安全"，是"多算了 2 位余量"**：一旦 `ENV_W` 变 17、或 `OSC_PER_VOICE` 改成 3（`:250-253` 的 fallback 分支 `vs_sum >>> 1` 会让 `|vs_c|` 上到 49150）、或加权系数改大，**积就会真的溢出 34 位**，而**没有任何自检**。
- 正确写法（与 `:191-196` 在 `envelope_bank` 里自己强调的"**必须用显式更宽的 wire**"是同一条纪律）：`PROD_W = SUM_W + ENV_W + 1`。

**具体怎么改**：`localparam integer PROD_W = SUM_W + ENV_W + 1;` 并在 `initial` 加：
```verilog
if (PROD_W < (SUM_W + ENV_W + 1))
    $display("ERROR [tdm_render_mixer] PROD_W=%0d 装不下 %0d×%0d 的积", PROD_W, SUM_W, ENV_W+1);
```

**预期收益/代价**：`ACC_W` 随之 40→41（多 1 位加法器 + 若干 FF，≈ +40 FF）⇒ 若不想加宽，**至少要把自检加上**（零代价，把"侥幸"变成"显式"）。

**怎么验证能红**：把 `ENV_W` 设成 17 并在 tb 里把 `env_c` 打满 ⇒ 旧 `PROD_W=34` 下 `prod_c` 的符号位**翻转**（`sh` 变号）⇒ 混音输出符号错误，判据必红。

---

## P3-3 · `SCALE_UP = SAMPLE_W - 16` 里的**魔数 16**：量纲与 `OSC_SAMPLE_W` 参数脱钩

**文件**：`rtl/w3b/tdm_render_mixer.v:395-396`

```verilog
395:    localparam integer SCALE_UP = SAMPLE_W - 16;      // ⭐ 24-16 = 8
396:    wire signed [ACC_W-1:0] sh24 = sh <<< SCALE_UP;
```

**为什么是问题**：这里的 16 语义上是"**原始波表位宽**"= `OSC_SAMPLE_W`（`:53` 的参数）。写成字面量 16 ⇒
- `OSC_SAMPLE_W` 改成 12/20 时，`:349` 的 `acc_r >>> ENV_W` 仍然正确（`ENV_W` 是参数），但**输出量纲会静默错 `OSC_SAMPLE_W−16` 位** ⇒ 音量差 2 的幂（听起来"变大/变小"，**不是无声**）⇒ 典型的难定位故障。
- 同一段代码里 `ENV_W` 用的是参数、只有波表位宽用字面量 ⇒ **不对称**。
- 另外 `i2s_tx` 的 `DATA_BITS=16`、`top_bits()` 的"取高 16 位"、`voice.v` 的 `{scaled_16, 8'b0}` 三处也都隐含 16 —— **这条量纲链一共 4 处硬编码 16，没有任何一处互相校验**。

**具体怎么改**：`localparam integer SCALE_UP = SAMPLE_W - OSC_SAMPLE_W;` 并加自检：
```verilog
if (OSC_SAMPLE_W + SCALE_UP != SAMPLE_W)
    $display("ERROR [tdm_render_mixer] 量纲不自洽：OSC_SAMPLE_W=%0d + SCALE_UP=%0d != SAMPLE_W=%0d",
             OSC_SAMPLE_W, SCALE_UP, SAMPLE_W);
```

**预期收益/代价**：0 逻辑。收益 = 把"改波表位宽 ⇒ 音量差 2 的幂且无报错"变成编译期/仿真期可见。

**怎么验证能红**：把 `OSC_SAMPLE_W` 改成 12（同时改 tb 的 bus 宽度）⇒ 新自检必须打印 ERROR。

---

## P3-4 · 限幅器 `lim_pos`/`lim_neg` **重复判同一个条件**（源码级冗余）

**文件**：`rtl/w3b/tdm_render_mixer.v:788-790`

```verilog
788:    wire signed [ACC_W+15:0] lim_pos = (sh_norm_d >  LIM_TH_W) ?  knee_pos : sh_norm_d;
789:    wire signed [ACC_W+15:0] lim_neg = (sh_norm_d < -LIM_TH_W) ? -knee_neg : sh_norm_d;
790:    wire signed [ACC_W+15:0] lim_w   = (sh_norm_d > LIM_TH_W) ? lim_pos : lim_neg;
```

**为什么是问题**：`lim_w` 已经判过 `sh_norm_d > LIM_TH_W`，而 `lim_pos` **又判了一遍同一个 56 位比较** ⇒ 多出 **1 个 56 位比较器 + 1 个 56 位 mux**，且 `lim_pos` 的 false 分支（`sh_norm_d`）在 `lim_w` 里**永远不会被取用**（因为 `lim_w` 走 false 分支时取的是 `lim_neg`）。综合器**大概率会折掉**，但：
- 这是 `:792-797` 的 `over_pos/over_neg` 与 `samp_r` **同一条组合段**的一部分 ⇒ 源码层面的冗余会污染"这条路径到底多长"的判断；
- 本项目已经有过"注释/结构声称 A、实际 B"的反复（AGENTS 案例③），**源码应尽量不依赖综合器的善意**。

**具体怎么改**：

```verilog
wire signed [ACC_W+15:0] lim_w = (sh_norm_d > LIM_TH_W) ?  knee_pos
                               : (sh_norm_d < -LIM_TH_W) ? -knee_neg
                                                         :  sh_norm_d;
```

**预期收益/代价**：源码少 2 个宽比较/mux（实测 LUT 收益取决于综合器，**不承诺数字**）· 语义 100% 等价（两条分支条件互斥）。

**怎么验证能红**：把 `lim_w` 的三目改成上式，跑 `tb_tdm_render_mixer` 的限幅 WIDE 用例 ⇒ **必须逐位相同**（若有差异说明我读错了，那本身就是一条 P0）。

---

## P3-5 · `pc_sum` 是 16 项**串行累加**，注释却断言"综合器会做成平衡树"（未验证）

**文件**：`rtl/w3b/tdm_render_mixer.v:483-501`

```verilog
493:    //   级 2：再求和（⭐ 16 → 1，⭐ 组合，但只剩 16 项 ⇒ 路径短得多）
494:    //      📌 综合器会把这 16 项**自动做成平衡树**（⛔ 不是串行长链）
497:    always @(*) begin
498:        pc_sum = {(LW+1){1'b0}};
499:        for (pi = 0; pi < POLY_TARGET/2; pi = pi + 1)
500:            pc_sum = pc_sum + pc_l1[pi];     // ← 源码是 16 深串行链
501:    end
```

**为什么是问题**：`pc_sum` 的**源码语义**是一条 16 深的串行加法链（每次累加都依赖前一次结果）。注释断言综合器会重排成平衡树 —— **这是一个对工具行为的假设，不是代码保证**（本项目在 `:447-450` 正是因为这个假设不成立而吃了 `Fmax 39.488 MHz + 16 setup` 的亏）。
**诚实记账**：`pc_sum → n_active_r` **不在**当前 25 条 SETUP 里 ⇒ **实测它没成为瓶颈**（`:443-450` 记录的那次是"归一化整段全组合"造成的，已经用三级寄存器修掉了）。所以本条是**结构性隐患记录**，不是当前缺陷。
**另外**：这条路径的起点是 `voice_active_i` = `note_manager.live_mask`（**跨模块组合**）⇒ 它的真实深度 = "note_manager 4 组寄存器 OR" + "32 根长线" + "16 项加法" + "FF"。

**具体怎么改**（把假设变成代码，同时去掉对 `always @(*)` 的依赖）：

```verilog
wire [LW:0] pc_g [0:3];                       // 4 组
genvar gj;
generate for (gj = 0; gj < 4; gj = gj + 1) begin : g_pcg
    assign pc_g[gj] = pc_l1[gj*4] + pc_l1[gj*4+1] + pc_l1[gj*4+2] + pc_l1[gj*4+3];
end endgenerate
wire [LW:0] pc_l2 [0:1];
assign pc_l2[0] = pc_g[0] + pc_g[1];
assign pc_l2[1] = pc_g[2] + pc_g[3];
assign pc_sum_w = pc_l2[0] + pc_l2[1];        // 显式平衡树，深度 3
```
（`pc_l1` 已经是 16 项 ⇒ 树深 2+2+1 = 5 级加法，明确可控。）

**预期收益/代价**：把"依赖综合器"换成"结构保证"；LUT 数基本不变（可能 −0~20）。**风险**：`pc_sum` 是 `always @(*)` 里的 reg，改成 wire 要同步改 `n_active_r <= pc_sum`。

**怎么验证能红**：改完后 `timing_paths` 里 `u_tdm_render_mixer` 的 popcount 相关路径（若出现）data delay 必须**不劣化**；同时 `tb` 里 `n_active_o` 的值必须逐位不变（对拍）。

---

## P3-6 · `same_idx` 注释写"**升序扫 + 未命中才赋值**"，代码是"**降序扫 + 无条件覆盖**"

**文件**：`rtl/w3b/note_manager.v:695-702`

```verilog
695:    // 最低索引优先编码（升序扫 + 只在未命中时赋值）
696:    reg [IDX_W-1:0] same_idx;
697:    integer qi;
698:    always @(*) begin
699:        same_idx = {IDX_W{1'b0}};
700:        for (qi = POLY_TARGET - 1; qi >= 0; qi = qi - 1)   // ← 降序
701:            if (same_hit[qi]) same_idx = qi;               // ← 无条件覆盖
702:    end
```

**为什么是问题**：**结果等价**（降序 + 无条件覆盖 = 取最低索引），但**实现与注释描述的相反**。本项目已经把"注释↔代码不一致"列为复发缺陷（AGENTS 案例③，且在 `tdm_render_mixer.v` 同族文件里"三项全错"过）。这一处是**同一缺陷类**：注释描述的写法（升序 + 条件赋值）与代码的**综合结果路径形状不同**（一个会综合成"链式优先 mux"、另一个会综合成"one-hot OR 折叠"），会影响时序判断。
⚠️ 顺带：`same_idx` 来自 **32 路优先编码器**，它的输入 `same_hit[]` 是 `gate_r|retrig_low|env_active_r` + `axis_r==cur_axis` + `src_r==cur_src` ⇒ **32×4 输入 AND + 2 个比较器**，这是 `ST_RETRIG` 写译码的**源头**（`:1192-1203` 已用 `same_idx_r` 切了一刀，所以现在不在 top-25）。

**具体怎么改**：把注释改成实际实现（`降序扫 + 无条件覆盖 ⇒ 取最低索引`），或把代码改成注释描述的写法（两者等价，选一个）。**推荐改注释**（0 风险）。

**预期收益/代价**：0 逻辑。收益 = 消除一处误导。

**怎么验证能红**：写一个定向断言：构造 `same_hit = 32'b...11`（多个命中）⇒ 断言 `same_idx` = **最低**命中索引。这条断言在两种写法下都应绿 —— **所以它不能证明注释错，只能钉住语义**。真正的"红"是**代码审查**（注释与代码字面不符）。

---

## P3-7 · 重触发窗口撞上 `sample_tick` 时：gate 被压低**整整一帧**，且那一帧的力度跟随被跳过

**文件**：`rtl/w3b/note_manager.v:1105-1120` · `:934` · `:1064-1081`

```verilog
1105:            for (i = 0; i < POLY_TARGET; i = i + 1) begin
1106:                if (retrig_low[i]) begin
1107:                    gate_r[i]          <= 1'b0;
1112:                    if (!sample_tick_i) retrig_reset_r[i] <= 1'b1;
1113:                    if (sample_tick_i) begin
1114:                        gate_r[i]     <= 1'b1;
1115:                        retrig_low[i] <= 1'b0;
1118:                    end
1119:                end
1120:            end
```
```verilog
 934:            if (sample_tick_i) retrig_reset_r <= {POLY_TARGET{1'b0}};
1066:                    if (gate_mask[i]) begin        // ← 力度跟随的使能
```

**为什么是问题（机制 + 数字）**：
- `retrig_low[i]` 一旦置位，**只在 `sample_tick_i` 那一拍清除**（`:1113-1118`）。所以：
  - **最优情况**：ST_RETRIG 落在 tick 前 1 拍 ⇒ 压低窗口 ≈ **1 clk（20 ns）**；
  - **最坏情况**：ST_RETRIG 恰好落在 tick **那一拍** ⇒ 该拍 `retrig_low` 还是 0（非阻塞），(f) 段不动它 ⇒ 要等到**下一个 tick** 才清 ⇒ 窗口 = **1024 clk = 20.48 µs**。
- 后果 ①：`gate_mask[i] = gate_r[i] & ~retrig_low[i] = 0` 整整一帧 ⇒ `envelope_bank` 在**那一个 tick 采到 gate=0** ⇒ ADSR 走 `rel_n=1` 分支（`:254-255`）⇒ **电平按 release 步长（1~6）掉一点点**，然后下一个 tick 才拿到 `rr=1`（`retrig_reset` 在窗口内被置 1、保持到 tick）⇒ 归零 + ATTACK。
  ⇒ **净效果 = 起音被推迟一帧（20.48 µs）+ 多一个 release 台阶**。听感上是"这一下重按比别的慢半拍"。
- 后果 ②：`:1066` 的力度跟随 `if (gate_mask[i])` 在那一帧为假 ⇒ **位置式力度更新被跳过**（`:1017-1018` 的注释自己承认"⭐ 影响可忽略（下一拍补上）" —— ⚠️ **但下一拍不是 tick，`vel_r` 的斜坡只在 `sample_tick_i` 更新（`:1064`）⇒ 实际是"下一帧补上"，不是"下一拍"**）。注释低估了代价一帧。
- 概率：**1/1024** 每次重触发。

**具体怎么改（二选一）**：
- **A（消除最坏一帧）**：把 (f) 段的清除条件从"`sample_tick_i` 那一拍"改成"**`sample_tick_i` 已越过至少一个沿**"——即用一个 `retrig_low` 置位时锁存的 `tick_seen` 标志：置位后遇到**第一个** tick 就清（无论置位是否发生在 tick 当拍）。等价做法：ST_RETRIG 在 `sample_tick_i` 当拍**不置 `retrig_low`**（而是直接"当拍压低 + 当拍抬高 + 发 `retrig_reset`"），因为"让 ADSR 看见 gate 0"这件事在 tick 当拍本来就**已经由 `retrig_reset` 完成**（`:1317-1321` 的注释自己说"`retrig_reset_i` 优先级**高于** `gate` 判定"）⇒ **当拍不需要再压低**。
- **B（最小改动，只修注释与记账）**：把 `:1017-1018` 的"下一拍补上"改成"**下一帧补上**"，并把"最坏窗口 = 1 帧（20.48 µs）、概率 1/1024"写进 `:1108-1111` 的注释。

**预期收益/代价**：A 消除一个 1/1024 概率、20.48 µs 的起音延迟；**风险**：A 改的是**重触发时序的核心**，必须重跑 `tb_note_manager` / `tb_retrig_reset_span` / `tb_nm_reuse_tail` / `tb_nm_off_in_hold` 四条 tb。

**怎么验证能红**：
- **证明最坏窗口**：写定向 tb，**精确对齐** ST_RETRIG 与 `sample_tick_i` 同拍（用一个可控的 `sample_tick_i` 相位），量"从 note_on 到 `env_level` 开始上升"的拍数 ⇒ 当前应得 **≈1024+ 拍**，而"错开 1 拍"的对照组应得 **≈34 拍** ⇒ **两者差 30 倍，这就是"整整一帧"的直接证据**。
- **证明力度跳过**：在同一窗口内发 `vel_upd` ⇒ 断言 `vel_r` 在**下一帧**才变（而不是下一拍）。

---

## P3-8 · `note_manager` 对 `envelope_bank` 的 512 位 `env_level` 做**无握手撕裂读**

**文件**：`rtl/w3b/note_manager.v:368-378`（入口寄存）· `rtl/w3b/envelope_bank.v:340`（轮转写）

```verilog
note_manager.v:370:    always @(posedge clk_i) begin
note_manager.v:374:        end else begin
note_manager.v:375:            env_level_r  <= env_level_i;      // ← 每 clk 无条件锁存
note_manager.v:376:            env_active_r <= env_active_i;
```
```verilog
envelope_bank.v:340:                env_level_o[svc_i*ENV_W +: ENV_W] <= lvl_n;   // ← 33 clk 内逐路写
```

**为什么是问题（机制 + 数字）**：
- 生产者在 **33 clk 的窗口内逐路更新**这 512 位；消费者**每 clk 无条件锁存整条** ⇒ `env_level_r` 是一个**撕裂快照**：第 k 拍时可能是"voice 0..j 是新值、j+1..31 是上一帧的旧值"。
- 用到它的地方：`:800-801` 的 `cand_better`（`cand_cls==1` 时"**选电平最低的已 Release voice**"）⇒ **跨帧比较电平** ⇒ 可能选中"其实不是最低"的那个 voice。
- **影响量化**：只影响"抢占时选谁"，**不影响是否发声**；且只在"事件扫描窗口（≤34 拍）与轮转窗口（33 拍）重叠"时发生 ⇒ 最坏 **33/1024 ≈ 3.2%** 的事件受影响，且后果是"被抢的 voice 换一个"（听感几乎不可分辨）。
- ⇒ **低危但真实**，且它暴露一个**架构事实：这条 512 位总线上没有 `valid`/`ready`，也没有"轮转完成"指示**（`envelope_bank` 连一个 `env_valid_o` 都没有）。
- ⚠️ 反方向的 `env_active_r` 撕裂是**保守**的（voice 变空闲会晚 ≤33 clk 被看见 ⇒ 更晚被抢），**这一半无需修**（我在 §一 核对表里已确认）。

**具体怎么改（最小）**：让 `envelope_bank` 输出一个 `round_done_o`（`cnt == CNT_STOP` 那拍置 1，或 `running` 的下降沿），`note_manager` 用它做 `env_level_r` 的锁存使能：
```verilog
// envelope_bank
output wire round_done_o;
assign round_done_o = (cnt == CNT_STOP) && running;
// note_manager
end else if (env_round_done_i) env_level_r <= env_level_i;   // 只在"整条总线都刷新完"那一拍取
```
⚠️ 代价：`env_level_r` 的更新频率从"每 clk"变成"每帧一次"（**语义上本来就该如此** —— `adsr` 的 `env_level_o` 也只在 tick 变）⇒ **无行为损失**；`env_active_r` 建议**保持每 clk 锁存**（保守方向，且 `live_mask` 的实时性有用）。

**预期收益/代价**：`+1` 根线 + `note_manager` 侧 `env_level_r` 的使能逻辑（≈0 LUT，因为使能本来就有）· 消除一类撕裂读。

**怎么验证能红**：定向 tb —— 构造"一个 voice 刚 release 到低电平、另一个也在 release 到较高电平"，把事件**精确落在轮转窗口中间**（让 `env_level_r` 拿到"一个旧值 + 一个新值"）⇒ 断言被抢占的 voice 索引**与"用完整帧快照算出来的答案"不同** ⇒ 现在**必红**；加 `round_done` 使能后必绿。

---

## P3-9 · `deadline_fault_o` **没有清除口**（与 `note_manager.event_lost_clr_i` 不对称）

**文件**：`rtl/w3b/tdm_render_mixer.v:291` · `:331-332` · `:865`

```verilog
291:    reg fault_r;
331:                if (cnt >= DEADLINE_C)
332:                    fault_r <= 1'b1;        // ← sticky，且全模块无任何清零输入
865:    assign deadline_fault_o = fault_r;
```

**为什么是问题**：`note_manager` 对同类"sticky 故障指示"给了 `event_lost_clr_i`（`:277`），而这里**只有置位、没有清除**：
- 上板后**一次**瞬时超时（例如调试时手动拉 `render_start` 或时钟抖动）⇒ `deadline_fault_o` **永久为 1**，之后再也无法用这个信号判断"当前是否正常"（只能复位整片）。
- 违反本项目 `K-106` 的口径："**可观测**"不只是"能置位"，还要"**能区分历史与当下**"（`note_manager` 的 sticky + 饱和计数 + clr 三件套就是这个口径的模板）。

**具体怎么改**：加 `input wire fault_clr_i`（或 `deadline_fault_clr_i`），`if (fault_clr_i) fault_r <= 1'b0;` 放在 `:331` 的置位**之前**（后写覆盖先写 ⇒ 置位赢，与 `note_manager` 的 `event_lost_clr_i` 同款语义）。⚠️ **加端口 = 接口变更**，按冻结表 §〇 约定 5 须通知全员；老例化不接该端口 ⇒ `z` ⇒ 用 `(fault_clr_i === 1'b1)` 解码为"不清"（Z-safe）。

**预期收益/代价**：+1 FF + 1 根线。收益 = 让这个信号**在整机寿命内可用**。

**怎么验证能红**：定向 tb —— 制造一次超时（`RENDER_DEADLINE_CYC=1`）⇒ 断言 `deadline_fault_o=1`；再拉 `fault_clr_i` ⇒ 断言变 0；**老代码下第二次断言必红**（无法清零）。

---

## P3-10 · `i2s_tx` 输出脚只有 **0.247 ns** 保持余量（`set_output_delay -max 2.0` 的人为紧约束）

**文件**：`constr/top.sdc:62-64` + 实测 `impl/pnr/Gowin2026.timing_paths`

```
HOLD  slack 0.247  data 2.456  required 2.209
  clk_ibuf 0.000 → 0.952
  u_i2s_tx/bit_cnt_1_s0 2.186 → 2.313
  u_i2s_tx/n57_s2       2.318 → 2.456
  u_i2s_tx/bit_cnt_1_s0 2.456          ← 自环
（同族：ch_s0 0.247 / master_mix gain_r_11 0.247 / ws2812 bit_i_4 0.247）
```

**为什么是问题**：
- 这批 **HOLD 0.247 ns** 是**全设计最薄的保持余量**（其余 HOLD 在 0.19~0.25 ns，见 §四），而它们**全部**是"寄存器自环 + 极短布线"（data 2.4~2.6 ns，其中时钟插入 0.952 ns）⇒ **余量 ≈ 纯时钟树偏斜 + hold 时间 − 布线延迟**。
- ⚠️ 这类路径的余量与**布局**强相关（布线越短、余量越小）⇒ ⭐ **"重跑布局变好"反而可能把它变红**（与 setup 的方向相反）。
- `:62-64` 的 `-max 2.0` 是**故意过约束**（`:45-61` 记录了上一版 `-max 10` 造成 `slack −1.827 / Fmax 45.815` 的事故）⇒ 这个约束**本身没问题**，但它把 `HP_*` 的输出路径钉在 18 ns 预算上，而实测 data 只有 2.5 ns ⇒ **余量不是来自设计，是来自约束的宽裕**。

**具体怎么改**：**不改 RTL**（这三根脚的真实要求是 BCK→DIN 的 160 ns，已由 `tb_i2s_tx_timing` 逐位量过）。建议：
1. 在 `constr/top.sdc` 里给这批路径加一条**保持余量下限**：`set_clock_uncertainty -hold 0.3 [get_clocks clk_sys]`（让工具**主动**为 hold 留 0.3 ns，而不是"能过就行"）；
2. 把"0 hold 的判据"从"违规数 = 0"升级为"**最小 hold slack ≥ 0.2 ns**"（写进 `sim/gowin_build.ps1` 的解析里），因为**0.001 ns 的 hold 也是"0 hold"** —— ⭐ 这是本项目"通过判据"里的一个真实盲点。

**预期收益/代价**：`set_clock_uncertainty` 会让 setup 预算再紧 0.3 ns（当前 setup 最差 0.102 ns ⇒ **可能直接打破**）⇒ ⚠️ **必须与 P0-1/P0-2 一起做，或者只加 `-hold`**（Gowin 支持 `-hold` 单独设）。

**怎么验证能红**：把 `set_clock_uncertainty -hold 0.5` 加上 ⇒ 重跑 PnR，若报告里出现 hold 违例 ⇒ 说明当前"0 hold"**确实只是勉强**（这是判据盲点的直接证明）；随后按 P0-1/P0-2 修好 setup 再回来加这条。

---

## P3-11 · `oscillator_bank.voice_velocity_i`：位宽写死 8 **且生产档整条链被常量折叠（声明了没人读）**

**文件**：`rtl/w3b/oscillator_bank.v:227` · `:291` · `:697` · `:770-777` · `:800-812` · `rtl/top.v:4190-4191`

```verilog
227:    input  wire [POLY_TARGET*8-1:0]                         voice_velocity_i,   // ⛔ 写死 8
291:    wire [LANES*8-1:0]       lane_velocity;                                      // ⛔ 写死 8
697:            assign lane_velocity[g*8 +: 8] = voice_velocity_i[VOICE_IDX*8 +: 8]; // ⛔ 写死 8
800:    wire [8:0] velocity_mix_q = (resp_velocity_q == 8'hFF) ? 9'd256 : {1'b0, resp_velocity_q};
803:    wire [8:0] mix_q = (VELOCITY_BLEND_EN != 0) ? velocity_mix_q : FIXED_BLEND_Q_W;
805:    wire signed [WT_W:0] blend_delta = {rom_hard[WT_W-1], rom_hard} - {rom_soft[WT_W-1], rom_soft};
807:    wire signed [WT_W+9:0] blend_product = blend_delta * $signed({1'b0, mix_q});
811:    wire signed [WT_W:0] blend_sum = {rom_soft[WT_W-1], rom_soft} + blend_scaled;
```
```verilog
top.v:4190:            .VELOCITY_BLEND_EN(0),
top.v:4191:            .FIXED_BLEND_Q (0),
```

**为什么是问题（两条，同一处）**：
1. **位宽**：`voice_velocity_i` / `lane_velocity` / 索引全部写死 `8`，而 `note_manager` 侧是 `POLY_TARGET*VEL_W`（`VEL_W` 是参数）。⇒ 若 `VEL_W` 改成 10，**两侧位宽不等**，Verilog 会**静默零扩展/截断**（不是编译错误）⇒ 力度→音色的映射静默错位。
2. **死逻辑**：交付档 `VELOCITY_BLEND_EN=0` ⇒ `mix_q = FIXED_BLEND_Q_W = 0`（编译期常量）⇒ `blend_product ≡ 0` ⇒ `blend_sum ≡ rom_soft`，**整条"力度→soft/hard 插值"链被折叠掉**，`voice_velocity_i` 这 **256 位输入在生产档完全没有读者**。
   - `:815-816` 的注释承认他们**故意保留引用**"免得 `iverilog -Wall` 报未使用" ⇒ 也就是说：**为了让 lint 闭嘴，保留了一条不参与综合的死链**。
   - ⇒ 后果：`tb_velocity_*` / `tb_soft_hard_blend` / `tb_velocity_lane_isolation` / `tb_velocity_tone_decoupling` **验证的是一个交付档不使用的模式**；而**真正生效的** `FIXED_BLEND_Q` 路径（= 固定取 `rom_soft`）**只在少数 tb 里被覆盖**。
   - ⚠️ 更值得记的是：`:817-825` 的注释说"⭐ 2026-09-29 上板实测修正：**固定用 `rom_hard`，⛔ 不是 `rom_soft`**"，而 `top.v:4191` 传的 `FIXED_BLEND_Q(0)` ⇒ **0 = soft**。**两处说法相反**（这是本报告第 3 处"注释↔代码不一致"，且它决定音色）。需要裁定：到底是 hard 还是 soft？

**具体怎么改**：
1. 位宽：`input wire [POLY_TARGET*VEL_W-1:0] voice_velocity_i`、`wire [LANES*VEL_W-1:0] lane_velocity`、`assign lane_velocity[g*VEL_W +: VEL_W] = voice_velocity_i[VOICE_IDX*VEL_W +: VEL_W];`（⚠️ 改端口声明 ⇒ **必须同步 `tb/models/oscillator_bank_ref.v`**）。
2. 死链：**要么删掉**（`VELOCITY_BLEND_EN` 恒 0 时用 `generate if` 门控整段，像 `note_manager.T3_EN` 那样），**要么**在注释里明确"这是给非交付档留的回退路径，交付档不参与综合"。**推荐 `generate` 门控**（与 T3_EN 同一手法，结构上不可能被综合出来）。
3. `rom_hard` vs `rom_soft`：**以代码为准**（`FIXED_BLEND_Q=0` ⇒ `blend_sum = rom_soft`），把 `:817-825` 的"固定用 `rom_hard`"改成与代码一致，或把 `top.v` 的 `FIXED_BLEND_Q` 改成 256（= hard）—— ⭐ **必须由用户/音色负责人裁定，⛔ 我不能替你定音色**。

**预期收益/代价**：位宽改动 = 0 逻辑（纯声明）· 死链 `generate` 门控 = 综合器本来已折叠，收益是**可读性与覆盖率诚实性**（以及 `-Wall` 干净）。

**怎么验证能红**：
- 位宽：把 `VEL_W` 改成 10（两侧 tb 同步）⇒ 现在**静默错位**（`lane_velocity` 拿到的是错位的 8 位片段），力度→音色判据必红。
- 死链：把 `VELOCITY_BLEND_EN` 设 1 跑 `tb_soft_hard_blend` ⇒ 必须绿；设 0 ⇒ 该 tb 的 soft/hard 判据必须**红**（证明它测的是非交付档）。当前**没有任何 tb 做这个"非空洞性"对照**。

---

## 二、跨模块**组合穿透**清单（长路径的头号来源）

| # | 穿透路径 | 起点（FF） | 终点（FF） | 中间组合 | 实测证据 | 等级 |
|---|---|---|---|---|---|---|
| ① | `note_manager` → `oscillator_bank`/`envelope_bank` 的 **6 条扁平总线** | `timbre_r[1]` / `vel_r[]` / `gate_r[]` / `retrig_reset_r[]` / `phase_tr[]` | `envelope_bank.tim_s_r` / `vel_s_r` / `gate_s_r` / `rr_s_r`；`oscillator_bank.phase_q` | ⛔ **无**（纯线 + 少量 OR） | HOLD **0.207 / 0.208 / 0.244 ns**（`tim_s_r_3` / `tim_s_r_17` / `vel_s_r_87`），data 2.59 ns 里 **2.19 ns 是布线** | ⭐ **P2**：全设计最薄的保持余量，且**纯布线 ⇒ 与布局强相关** |
| ② | `oscillator_bank` → `tdm_render_mixer` 的 **1024 位样本总线** | `sample_bus_r` | `prod_r`（DSP 后） | 32:1 mux → 16 位加减 → DSP | SETUP **0.133 ns / 20.062 ns**（**P0-2**） | ⭐ **P0** |
| ③ | `tdm_render_mixer` → `master_mix` → `top.sample_r` | `samp_r` | `top.sample_r` | 24×16 DSP → 40 位归约 → mux | **不在 top-25**（<19.36 ns），结构同 `:800-825` 已修那条 | ⭐ **P1-3** |
| ④ | `perc_env_bank` → `tdm_render_mixer` 的 DSP 输入 | `perc_env_bank.level_o` | `prod_r`（DSP 后） | `top.v:4359` 的**纯拼接** → `env_c` 32:1 mux → DSP | 与 ② 同一条 `prod_c` 路径（并行支路） | **P3**：保留池那 5 路的包络**也没有寄存器**（与键盘那 27 路不同源） |
| ⑤ | `looper` → `note_manager.phase_r` | `play_upd_inc_o_9_s0` | `phase_r[31]_9_s1` | ⛔ 无 | HOLD **0.194 ns**（全设计最薄） | **P3**：`pitch_upd_value_i` 直连 D 脚 |
| ⑥ | `note_manager` → `tdm_render_mixer` 的 `voice_active_i` | `gate_r`、`env_active_r` 等信号 | `n_active_r` | 4 组 OR → 32 根长线 → 16 项加法 | 不在 top-25（`pc_sum` 见 P3-5） | **P3** |

⭐ **结论**：这条链上**只有 1 处是"寄存器到寄存器"的干净边界**（`phase_tr[]` → `oscillator_bank`，因为 T3 影子数组是寄存器）。其余 **6 处全部是"模块输出不寄存、直接喂下游的组合/时序块"** ⇒ **这就是长路径与薄 hold 的结构性来源**，也是"布局噪声主导"的根因（组合穿透路径的延迟 ≈ 布线延迟，而布线延迟随布局摆动 ±2 ns）。

---

## 三、协议漏洞核查（valid/ready、同拍多事件、丢/重事件、优先级反转）

| 检查项 | 位置 | 结论 |
|---|---|---|
| **同拍多事件**（`note_valid_i` 与 FIFO push 同拍） | `note_manager.v:570-576`、`960-962` | ✅ 正确：`fifo_push && fifo_pop` 时 `fifo_cnt` 不加不减；`fifo_empty` 时不可能 pop ⇒ **不会读到同拍正在写的槽** |
| **丢事件** | `note_manager.v:576`、`964-974` | ✅ 有 sticky + 饱和计数 + clr（`K-106` 三件套齐全） |
| **`note_off` 顺序** | `note_manager.v:561-566`、`1141-1188` | ✅ 统一排队 ⇒ 不会"清空"（`T38` 防挂音） |
| **`best_valid==0` 守卫** | `note_manager.v:1306` | ✅ 无候选时不提交（不污染无关 voice） |
| **valid 与数据同拍** | `tdm_render_mixer.v:857-863` | ⚠️ **不同拍：valid 晚 2 拍**（P3-1，功能无害但契约债） |
| **valid 与数据同拍** | `master_mix.v:127` | ⚠️ 零延迟透传，**输出组合**（P1-3） |
| **`render_start_i` 重入** | `tdm_render_mixer.v:304-309` | ⚠️ `render_start_i` **无条件打断**正在跑的帧（`cnt<=0, acc_r<=0`）⇒ 被丢弃的那帧 `valid_r` 不置位 ⇒ 下游保持**上一帧样本**（= 重复一个采样）。当前调度下不可达，但**没有任何观测/守卫**（P3 级，未单列） |
| **`i2s_tx` 装载** | `i2s_tx.v:184-198` | ✅ `frame_start` 一次装载；用 `top_bits(sample_l)` 避开 delta 竞态 |
| **`envelope_bank` tick 间隔** | `envelope_bank.v:332-335` | 🔴 **无契约、无自检**（P2-1） |
| **`oscillator_bank` 帧内截止** | `oscillator_bank.v:900-905` | 🔴 自检写死 1024 且只查 `LANES`（P2-2） |
| **优先级反转** | `note_manager.v:1105-1120` vs `1125-1393` | ✅ (f) 段在 `case` 之前 + `note_off` 清 `retrig_low` ⇒ **`note_off` 无条件优先**（防挂音） |
| **同轴异源抢占** | `note_manager.v:789-791` | ✅ `cand_foreign` 排除"异源且按住"的 voice（A3' 修法） |
| **`deadline_fault_o` 可观测性** | `tdm_render_mixer.v:331` | ⚠️ sticky 但**无 clr**（P3-9） |

---

## 四、宽度 / 符号 / 复位 / 鲁棒性 逐项核查（含"已验证清白"的部分）

### 4.1 宽度与符号（✅ 清白，除已列项）
- `vs_sum`/`vs_dif`/`vs_w`/`vs_c`：逐级位宽推导**我手算过**，9:7 加权最大 524272 需 20 位，`LSUM_W=22` ⇒ **不溢出**；`vs_c = vs_w >>> 4` 最大 36863，装进 18 位有符号 ⇒ ✅
- `$signed()` 包住所有拼接后再参与有符号运算（`vs_w`、`env_s`、`blend_*`、`master_mix.prod`）⇒ ✅ **没有发现"拼接把符号丢掉"的实例**
- `master_mix` 的 `over_pos/over_neg` 逐位判据：`scaled[38:23]` 对 24 位输出**判据正确**（bit23 是符号位，属溢出区）⇒ ✅
- `tdm_render_mixer` 的 `over_pos/over_neg`：`sh_final_w[ACC_W+14 : 23]` ✅
- `i2s_tx.top_bits()`：`k < SAMPLE_W` 才取，其余补 0 ⇒ 避开 `DATA_BITS > SAMPLE_W` 的越界（R-07）✅
- `envelope_bank` 的 `sustain_product_r`：`peak(≤65280) × sus(≤230) = 1.5e7` 需 24 位，`prod_p` 32 位、截 `[23:0]` ⇒ ✅ **正是"显式更宽 wire"的正确示范**
- ⚠️ 已列：`PROD_W` 少 1 位（P3-2）、`SCALE_UP` 魔数 16（P3-3）、`voice_velocity_i` 写死 8（P3-11）

### 4.2 复位与初始化（✅ 全部覆盖，未发现 X 传播口）
逐个核对了 `note_manager`（含 `drum_cls_r`/`sus_hold_r`/`vtgt_*`/`lost_*`）、`oscillator_bank`（含 `sweep_q`/`act_d`/`resp_*_q`/`sample_bus_r`）、`envelope_bank`（含 `lvl_sr/st_sr/rel_sr` 与全部 look-ahead 寄存器）、`tdm_render_mixer`（含 `n_active_r`/`norm_gain_r`/`sh_norm_r`/`exc_*_d`/`valid_d`/`samp_r`/`fault_r`）、`master_mix`（`gain_r <= 0` = **安全静音态** ✅）、`i2s_tx`（同步复位、`HP_BCK <= 1` 有意为之 ✅）
⇒ **结论：未发现"复位覆盖不全"或"上电 X 传播"**（这一点我逐块看了，⛔ 不写没有的发现）。
⚠️ 唯一的 X 入口是 **`drum_cls_i` 的裸引用**（P2-3）。

### 4.3 鲁棒性（悬空 Z）
- ✅ 已有 Z-safe 解码 7 处：`note_manager` 的 `ns_src_w`/`vu_src_w`/`pu_src_w`/`sus_pedal_i`、`oscillator_bank` 的 `voice_phase_rst_i`/`lane_drum`、`note_manager` 的 `transpose_semi_i`（`^transpose_semi_i !== 1'bx`）
- 🔴 **缺口 1 处**：`oscillator_bank.drum_cls_i`（P2-3）
- ⚠️ **新端口若加**（P3-9 的 `fault_clr_i`）必须同样 Z-safe

### 4.4 资源（可共享 / 可折叠）
- ✅ **已做对**：`tdm_render_mixer` 的 9:7 加权用 `8(L0+L1)+(L0−L1)` 的**代数恒等式避开 DSP**（`:216-234`，实测 `MULTALU27X18` 只 +0）；鼓分类上提到 `note_manager` 提交路径**省掉 64 个常量比较器**（`:400-405` + `:822-836`）
- 🔴 **可共享未共享**：两个软膝平方器互斥 ⇒ 共享一个（P2-4，≈260~310 LUT）
- ⚠️ **可折叠未显式折叠**：`VELOCITY_BLEND_EN=0` 的死链（P3-11）
- ⚠️ **`lim_pos`/`lim_neg` 冗余**（P3-4）
- 当前资源账（`impl/pnr/Gowin2026.rpt.txt`）：`Logic 34507/59904 (58%)` · `LUT 27135 + ALU 7372` · `Register 17039/60780 (29%)` · **`CLS 23303/29952 (78%)`** · `BSRAM 33/118` · **`DSP 22/118（MULTALU27X18 = 7）`** ⇒ ⭐ **真正的天花板是 CLS 78%**，不是 LUT/Register/DSP。

### 4.5 已核对但**未发现问题**的接缝（⛔ 不硬凑）
1. **lane ↔ voice 映射**（`lane = voice*2 + osc`）在 `oscillator_bank`（`VOICE_IDX = g/2`、`OSC_IDX = g%2`）与 `tdm_render_mixer`（`cnt_sel*2 + oi`）**两侧一致** ✅
2. **ROM 1 拍延迟与响应标签**（`resp_velocity_q`/`resp_drum_q` 用同一个 `req_active` 使能、同一个时钟沿）✅
3. **`osc_valid_o` 的 1 拍脉冲**与 `sample_bus_r[63]` 的写入**同拍**（`cnt == LANES`）✅
4. **`tick_audio` 与 `frame_start` 同拍**（`clk_gen.v:104/109` 都是 `cnt==0` 寄存 ⇒ 都在 `cnt==1`）⇒ "提前一帧"契约成立 ✅
5. **BCK/DIN 相位**：`bclk_half_en` 与 `bclk_en` 同在 `cnt%16==1` ⇒ 数据在**下降沿**变、上升沿采样、**建立/保持各 8 clk = 160 ns** ✅（我逐拍核算过，与文件头声称的一致）
6. **K-169（一个事件两个消费者）**：`retrig_reset_r` 电平保持到 tick ⇒ `envelope_bank` 与 `oscillator_bank` **同源同拍**看见 ✅（我推了"新占 voice"与"同轴重触发"两条路）
7. **`envelope_bank` 旋转移位寄存器的头指针**：`cnt=32 ⇒ svc_i=31`、32 次移位后回恒等序 ✅
8. **`acc_r` 累加窗口与 `prod_r` 的对应**：voice 0..31 各加一次、`cnt=32` 的那次不计入 ✅（但见 P1-1 的引信）
9. **`i2s_tx` 的 `calc_bit` 用函数而非组合 reg**（避免阻塞赋值后用旧值）✅
10. **`note_manager` 的 Z-safe `note_src_i`**（`ns_src_w`）✅ —— 若无它，悬空 `note_src_i` 会让 `pool_mask` 全 `x` ⇒ **6/6 事件全丢**（章程记录），现在不会。

---

## 五、建议的执行顺序（⛔ 不许打乱，因为 ③ 与 ① 强耦合）

| 步 | 动作 | 为什么这个顺序 |
|---|---|---|
| 1 | **P1-1**（修 `cnt_sel` 全宽夹取） | 它是 P0-2 的**前置**：不修就动窗口 ⇒ voice 0 被累加两次（静默幅度错） |
| 2 | **P0-2 + P3-1**（读侧流水 + `valid_d` 5→4 + 窗口 `[2,33]`） | 一次改动同时解决"第二关键路径"与"valid 晚 2 拍"，且**净拍数不变**（tb 判据一字不改） |
| 3 | **P0-1**（T3 写侧流水） | 独立，但与 P0-2 是**并列第一**（只修一个只涨 0.1 MHz）⇒ 必须同批 |
| 4 | 四道门 | 综合 ERROR=0 → `tb_transpose`（注意 34 拍窗口）/`tb_tdm_render_mixer`/`tb_note_manager` → 干净 PnR 0/0 无 PR0004 → 全量回归"通过数==共数" |
| 5 | **P2-4**（共享平方器） | 用 PnR 腾出的 CLS 余量换面积；纯等价改动，低风险 |
| 6 | **P1-2 定案**（增益基准） | 需要用户/音色负责人拍板（是"提 8.8 dB"还是"改文档"）；**若选提增益，必须与步 5 之后一起上板听"尖音"** |
| 7 | **P1-3 / P2-1 / P2-2 / P2-3 / P2-5 / P3-2..P3-11** | 按各自风险单独提交，每条都带"能红"的判据 |

**⛔ 全局提醒**：
- 任何改动**碰 `oscillator_bank`**（P2-2 加参数、P2-3 加 `===`、P3-11 改端口）⇒ **必须同步 `tb/models/oscillator_bank_ref.v`**，否则 `tb_p5_osc_equiv` 逐位等价假红。
- ⚠️ **`tb/models/oscillator_bank_ref.v` 已经落后于 A3**（它**没有** `drum_cls_i`/`DRUM_CLS_EXT`）⇒ **`DRUM_CLS_EXT=1`（生产档）下的逐位等价【从未被验证】**（现在只能靠"两边都取 0 档"来绿）—— 这是一条**独立的覆盖率缺口**，建议补 `tb_osc_drum_cls` 的逐位对拍版本。
- ⚠️ **改 RTL 期间⛔ 不许跑变异测试**（它会就地改 `rtl/`）；全量回归期间⛔ 不许改 `rtl/`/`tb/`（项目 AGENTS 硬约束）。

---

## 六、汇总

| 优先级 | 条数 | 编号 |
|---|---|---|
| **P0** | 2 | P0-1（T3 写侧，0.102 ns）· P0-2（读侧 mux+DSP，0.133 ns） |
| **P1** | 4 | P1-1（`cnt_sel` 死夹取，P0-2 的前置）· P1-2（增益基准 44/88/64 互斥 ⇒ 单音 24.9% FS）· P1-3（`master_mix` 输出组合）· P1-4（`oct_allow` 假绿） |
| **P2** | 5 | P2-1（`envelope_bank` 无 tick 间隔契约）· P2-2（`oscillator_bank` 帧内截止自检不覆盖 `LANES+2`）· P2-3（`drum_cls_i` 缺 Z-safe）· P2-4（平方器可共享 ≈300 LUT）· P2-5（`RAMP_STEP` 位选 K-91 + 回绕） |
| **P3** | 11 | P3-1（valid 晚 2 拍）· P3-2（`PROD_W` 少 1 位）· P3-3（魔数 16）· P3-4（限幅冗余判据）· P3-5（`pc_sum` 串行假设）· P3-6（`same_idx` 注释反）· P3-7（重触发最坏窗口 1 帧）· P3-8（512 位撕裂读）· P3-9（`deadline_fault` 无 clr）· P3-10（HOLD 0.247 ns 判据盲点）· P3-11（`voice_velocity_i` 写死 8 + 死链 + soft/hard 注释反） |
| **合计** | **22** | |

**一句话总结**：这条链的 Fmax 由**两个同型结构**（1024 位扁平总线 + 32:1 mux）**并列决定**，两者 slack 只差 0.031 ns；而链上 **6/7 个模块边界是"输出不寄存的组合穿透"**，这是"布局噪声主导 ±2 MHz"的结构性根因。**修 P0-1 + P0-2（+前置 P1-1）应把对 51.5 MHz 门槛的余量从 1.34 ns 提到 ≥2.09 ns**，其余 19 条按优先级各自独立、每条都带"能红"的判据。
