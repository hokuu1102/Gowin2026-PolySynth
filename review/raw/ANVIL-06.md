# ANVIL-06 · W3a 五模块往死里抠（event_extract / param_extract / axis_map / axis_snapshot / async_pluck_capture）

> 成员编制：本机子代理深度上限 = 1（`subagent` 直接报 `subagent depth 2 exceeds maxDepth 1`），
> 所以「几位猛男分开撸」**没有真的开成** —— 下面这五把武器都是我一只手抡的。
> 名字先起好，方便后面派活：**重锤 SLEDGE**(event_extract) · **扳机 TRIGGER**(param_extract) ·
> **音叉 TONEFORK**(axis_map) · **快门 SHUTTER**(axis_snapshot) · **棘轮 RATCHET**(async_pluck_capture)。

**口径（先说清，免得被"布局噪声"骗）**

| 项 | 值 |
|---|---|
| 器件 / 档位 | GW5AT-LV60PG484 **AC1/I0**（Slow 0.93V 0C C1/I0；Hold Fast 0.975V 85C C1/I0） |
| clk_sys | 50 MHz（20.000 ns）· SDC `set_max_delay` 18.181 ns |
| 实测量（=0 档） | `evidence/h5/base-T5-55p060` ⇒ **Actual Fmax 55.060 MHz**，Logic Level **10** |
| 实测量（=1 档 `RIGHT_ADC_ENABLE=1`） | `build/rightadc-probe/impl/pnr` ⇒ **57.016 MHz**，Logic Level **10**<br>（判定依据：该次综合日志里 `adc_farm` **无参数覆盖** ⇒ 用默认 `N_ADC=3`，且 `right_analog_ctrl`/`vibrato_lfo` **未被 swept** —— 与 =0 档正好相反 ⇒ 就是 =1 档那次） |
| 归档 PnR 报告 | `evidence/` + `build/` 共 **30** 份 `*_tr_content.html`（Fmax 36.1 ~ 57.0 MHz，Logic Level 6 ~ 24） |

**每条结论都带分类标签**：`[结构]` = 与布局无关、改代码/参数就能判定；`[布局]` = 在 2~3 MHz 噪声带内、
只是这次摆得巧/不巧，**别当结论**。

---

## §0 先给最重要的一条：**这五个模块现在根本不是 Fmax 的瓶颈**（有证据，不是感觉）

**证据 1 —— 两份关键 build 的 top-25 setup 路径，一条都不在五模块里**

`base-T5-55p060`（55.060 MHz）top-25 setup：

```
#1  slack 0.019  g_sound.u_tdm_render_mixer/cnt_4_s0/Q -> .../prod_c_0_s/D[8]    data delay 15.978
#2  slack 0.041  同上 -> prod_c_0_s/D[12]                                        15.998
...
#6  slack 0.138  g_sound.u_note_manager/g_t3.rot_cnt_1_s0/Q -> g_t3.phase_tr[17]_26_s0/D  18.003
#25 slack 0.714  g_sound.u_tdm_render_mixer/cnt_4_s0/Q -> prod_c_0_s/D[19]       15.804
```

`build/rightadc-probe`（57.016 MHz，=1 档）top-25 setup：**23 条 `u_tdm_render_mixer/cnt_4_s0 → prod_c_0_s`，
2 条 `u_note_manager/phase_r[*] → g_t3.phase_tr[*]`**。零条 w3a。

**证据 2 —— 全 30 份报告里，五模块只出现过一次，而且是 HOLD 路径**

| 报告 | Fmax | 类型 | rank | slack | data delay | 路径 |
|---|---|---|---|---|---|---|
| `evidence/h5/baseline-53p425-impl-snapshot` | 53.425 | **HOLD** | 1,4,7,10,11,17 | 0.128 ~ 0.239 | 0.261 | `u_event_extract/evt_axis_o_0_s0/Q → u_play_mode_ctrl/selected_axis_0_s0/D` |

该路径的逐级明细（同一份报告）：launch 时钟 0.952(tINS)+1.234(tNET)=**2.186**，
capture 时钟 0.952+**1.415**=**2.367**，tC2Q **0.130**，数据 net **0.131**，tHld −0.048，
required 2.319 / arrival 2.447 / **Clock Skew 0.181**。
⇒ 判定：**`[布局]`** —— 真正的逻辑延迟是 0（FF→FF 一条网），主导项是**时钟树偏斜 0.181 ns**（与 data delay 0.261 同量级），
属于"两个 FF 摆得远、时钟脊抽头不同"。RTL 侧无结构可改（详见 §A-13）。

**⇒ 由此定调（后面所有条目的收益都按这个尺度标）**：
五模块里的任何 RTL 优化，**今天都不会把 55.06 → 更高**；能改的是
① 面积/FF/LUT（真金白银，且给别的模块腾布线资源）② **将来**接回死逻辑时的时序余量 ③ 正确性/防线。
凡是我说"预期 Fmax 不变"的地方，都是这个意思 —— 谁要是拿这五模块去救 Fmax，方向就错了。

---

## A. 重锤 SLEDGE —— `rtl/w3a/event_extract.v`

### [P0] N4 比例守卫在 `TRAVEL_TARE == 0` 时**整条被绕过**，而且 `$fatal` 的消息里除零 —— `rtl/top.v:2717-2724`

**代码（原样）**

```verilog
if (!((EVT_TRIG_TH * 32'd100 >= 32'd5  * TRAVEL_TARE) &&
      (EVT_TRIG_TH * 32'd100 <= 32'd12 * TRAVEL_TARE)))
    $fatal(1, "ERROR [top] 触发点量纲错配(N4): EVT_TRIG_TH(%0d)/TRAVEL_TARE(%0d) = %0d%% 超出 [5%%,12%%] ...",
           EVT_TRIG_TH, TRAVEL_TARE, (EVT_TRIG_TH * 32'd100) / TRAVEL_TARE);
if (!((EVT_REL_TH * 32'd100 >= 32'd2 * TRAVEL_TARE) &&
      (EVT_REL_TH * 32'd100 <= 32'd7 * TRAVEL_TARE)))
    $fatal(1, "ERROR [top] 释放点量纲错配(N4): ...",
           EVT_REL_TH, TRAVEL_TARE, (EVT_REL_TH * 32'd100) / TRAVEL_TARE);
```

**机制（带数字，逐条推）**
`TRAVEL_TARE = 0` 时，两条守卫的**上下界同时塌成 0**：

| 判据 | 表达式 | 0/0 档结果 |
|---|---|---|
| ① `:2668` | `EVT_TRIG_TH > TRAVEL_TARE` | `0 > 0` = 假 ⇒ 不报 |
| ①b `:2680` | `TRAVEL_TARE > 1023` | 假 ⇒ 不报 |
| ①c `:2687` | `TRAVEL_TARE == CALIB_FULL` | `0 == 4095` 假 ⇒ 不报 |
| ② `:2691` | `EVT_REL_TH >= EVT_TRIG_TH` | `0 >= 0` **真** ⇒ 只 `$display`（**不是 fatal**） |
| **N4-TRIG** | `0*100 >= 5*0` ∧ `0*100 <= 12*0` | 真 ∧ 真 ⇒ **`!()` 为假 ⇒ 不 fatal** |
| **N4-REL** | 同上 | **不 fatal** |

⇒ **`TRIG_TH = REL_TH = TRAVEL_TARE = 0` 这套配置会完整穿过全部 6 道守卫**，只有一行 `$display`。
上板后果（正是 `rtl/top.v:3144-3148` 自己写过的那个失效模式）：
`pos >= 0` **恒真** ⇒ `calib_autotare` 一放行（`at_en_ready`）就 16 轴同时"按下" ⇒ 一帧内 16 个 `note_on`；
而 `pos < 0` **恒假** ⇒ **16 个 voice 永久 held、永不释放**（用户报过的"挂音几分钟不停"同族）。
另外 `TRAVEL_TARE = 0` 而 `TRIG_TH = 64` 时守卫会 fatal，但**消息参数 `(64*100)/0` 在 Verilog 里是 x** ⇒
报错文本印成 `x%%`，排障时看不到比值。

**修法（两条一起上，第一条是治本）**

```verilog
// ① 结构性：比例不变量直接写进常量，⛔ 不再允许"阈值"和"行程"各写一个数
//    ⚠️ 四舍五入 +500：744→64 / 4095→352，32 / 176 —— 与现行两档【逐位相同】
localparam [11:0] EVT_TRIG_TH = (TRAVEL_TARE * 32'd86 + 32'd500) / 32'd1000;  // 8.6%
localparam [11:0] EVT_REL_TH  = (TRAVEL_TARE * 32'd43 + 32'd500) / 32'd1000;  // 4.3%

// ② 绝对下界（①之后仍需，因为 TRAVEL_TARE 小到 1 时派生出 0）
if (TRAVEL_TARE == 12'd0)
    $fatal(1, "ERROR [top] TRAVEL_TARE=0 => N4 守卫退化成 0/0（两条都不触发），且 pos>=0 恒真 => 16 轴恒 held");
if (EVT_TRIG_TH == 12'd0)
    $fatal(1, "ERROR [top] EVT_TRIG_TH=0 => pos>=0 恒真 => 一上电 16 轴全部判按下");
if (EVT_REL_TH == 12'd0)
    $fatal(1, "ERROR [top] EVT_REL_TH=0 => pos<0 恒假 => 永不产生 note_off => 永久挂音");
```

**收益 / 代价**
收益：把"量纲错配"从**运行时数值检查**降级为**结构上不可能**（改档只改 `TRAVEL_TARE` 一处）；
顺手补掉 0/0 与除零。代价：`EVT_TRIG_TH`/`EVT_REL_TH` 从手写常量变派生量 ⇒
**必须核对 tb 里有没有写死的 64/32 断言**（`tb/top/tb_top_t15.sv`、`tb/top/tb_top_sound.sv` 优先看）。
数值逐位相同（64/32/352/176），所以理论上是零行为变化。

**验证能红（两条，都必须做）**
1. 临时把 `TRAVEL_TARE` 改成 `12'd0`，跑任一 elaborate `top` 的 tb（`tb/top/tb_top_m0.sv`）⇒
   **现在不会 fatal**（证明盲区真实存在）；改完必须 fatal。
2. 把 `EVT_TRIG_TH` 单独改成 `12'd205`（行程仍 744 ⇒ 27.5%，越界）⇒ 现在必须 fatal。
   ⚠️ **这条守卫从来没有被验证过**：`bringup/mutation_test.ps1:431-444` 里 N4 一个变异体都没有
   （只有 M88~M97，且没有一条打在 top.v 的守卫上）⇒ 按本项目 `C83`（探针假绿）的口径，
   **它现在是"未验证的防线"**。建议补一个变异体：把 `32'd12` 改成 `32'd30`（放宽上界），
   用 `TRAVEL_TARE=744 / TRIG=205` 的档去跑，**必须报红**。

**归类：`[结构]`** —— 纯配置逻辑，与布局、与 Fmax 无关。

---

### [P1] 五模块的 `PARAM_OK` 自检在**综合里全部被忽略**，N4 的 `$fatal` 是否真能拦住综合**无证据** —— `rtl/w3a/event_extract.v:437` 等

**证据（构建日志原文）**

```
WARN  (EX3858) : System task 'display' is ignored for synthesis("...rtl/w3a/axis_snapshot.v":235)
WARN  (EX3858) : System task 'display' is ignored for synthesis("...rtl/w3a/event_extract.v":437)
WARN  (EX3858) : System task 'display' is ignored for synthesis("...rtl/w3a/axis_map.v":572)
WARN  (EX3858) : System task 'display' is ignored for synthesis("...rtl/w3a/param_extract.v":382)
```

来源：`sim/evidence/gowin_build.log` 第 122/131/137/144 行（=0 档）；=1 档日志同样有。

**机制**
`sim/gowin_build.ps1` 是**直接综合**（不走仿真）⇒ 这四条自检、以及 `top.v:2664-2738` 那一整块
`initial` 守卫，**在 bitstream 生成路径上一条都不执行**。而"四道门"的第一道是"综合 ERROR=0" ——
它拦不住任何参数错配。项目自己在 `rtl/top.v:2822` 已经承认了这件事
（*"综合工具忽略 `initial` ⇒ 只是仿真侧防线"*），但 N4 那条注释（`:2712-2714`）却写着
*"用 `$fatal`（⛔ 不是 `$display`）… 这是配置错误 ⇒ 必须硬失败"* —— **两处口径互相矛盾**。
日志里**只有** `'display' is ignored` 这一类告警，**没有** `$fatal` 的记录 ⇒
**`$fatal` 在 Gowin 综合里到底是"报错退出"还是"和 display 一样被丢掉"，目前没有任何证据**。

**修法（三选一，按性价比排序）**
1. **结构性消灭**（首选）：把关键不变量改成派生常量（见 A 的 P0 条），让错配**无法表达**。
2. **搬到构建脚本**：在 `sim/gowin_build.ps1` 里加一段参数体检 —— 从 `rtl/top.v` 抓
   `EVT_TRIG_TH/EVT_REL_TH/TRAVEL_TARE` 三个数，算比值，不在 [5%,12%]/[2%,7%] 就 `exit 1`。
   这样第一道门就真的会红（而且**不依赖工具对 `initial` 的态度**）。
3. **实测 `$fatal`**：在 `top.v` 的 `initial` 里临时加 `if (1) $fatal(1,"probe");`，跑一次
   `sim/gowin_build.ps1`，看 exit code。若 exit=0 ⇒ 全项目的 `$fatal` 防线（含 `rtl/w3c/uart_rx.v:196`）
   都只是仿真防线，文档要跟着改。

**收益 / 代价**：收益 = 把"静默错配"变成"构建失败"；代价 = 一次 10 分钟 PnR（第 3 条）+ 可能改脚本。

**验证能红**：见上第 3 条；另外 `Select-String sim\evidence\gowin_build.log EX3858` 本身就是机械证据。

**归类：`[结构]`**。

---

### [P1] ON 分支与 OFF 分支**不对称**：push 失败时 `key_on` 照样置 1 ⇒ 那次 `note_on` 永久丢失 —— `rtl/w3a/event_extract.v:301-318` vs `:332-343`

**代码（原样，注意两边的差别）**

```verilog
// ── ON 分支（:301-318）—— key_on 在 push 【之外】无条件置位
if (!key_on[scan_axis]) begin
    if (pos_i[scan_axis*POS_W +: POS_W] >= TRIG_TH) begin
        if (refr[scan_axis] == 16'd0) begin
            key_on[scan_axis] <= 1'b1;              // 🔴 无条件！push 失败也置
            refr  [scan_axis] <= REFRACT_N[15:0];
            if (q_cnt < FIFO_D[FW:0]) begin
                q_axis [q_wr] <= scan_axis; ... q_push_now = 1'b1;
            end else begin
                overflow_o_r <= 1'b1;
                if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
            end
        end
    end
end
// ── OFF 分支（:332-343）—— 2026-09-28 已修成"推入成功才清"
if (pos_i[scan_axis*POS_W +: POS_W] < REL_TH) begin
    if (q_cnt < FIFO_D[FW:0]) begin
        ... q_push_now = 1'b1;
        key_on[scan_axis] <= 1'b0;                  // ⭐ 与 push 原子
    end else begin overflow ... end
end
```

**机制**
`:321-331` 的注释把 OFF 分支的道理讲得很清楚（*"一旦清 0，后续帧即使 `pos<REL_TH` 也再不会进入本分支
⇒ 该 note_off 永无第二次机会"*）—— 但**ON 分支是完全对称的同款问题，却没修**：
`key_on` 一旦置 1，`if (!key_on[scan_axis])` 就永久挡住本轴 ⇒ **这次按键永远不出声**；
更糟的是松手时会照发一条 `note_off`（`:332` 的条件只看 `pos < REL_TH`）⇒
`note_manager` 收到一条"无主的 off"，如果它按轴匹配 voice，就可能**误关同轴正在响的另一个音**。

**可达性（必须说清）**：今天 `q_cnt ≤ 1 < 4`（证明见下一条）⇒ **不可达**。
但它是**与已修缺陷同构的写法**，只要有人把 `FIFO_D` 改小、或把扫描改成"一拍两个轴"，
它立刻可达。这正是项目最忌讳的"注释说修好了、实际只修了一半"。

**修法（与 OFF 同构，只挪一行）**

```verilog
if (refr[scan_axis] == 16'd0) begin
    if (q_cnt < FIFO_D[FW:0]) begin
        key_on[scan_axis] <= 1'b1;                  // ⭐ 只有推入成功才改状态
        refr  [scan_axis] <= REFRACT_N[15:0];
        q_axis [q_wr] <= scan_axis;
        q_kind [q_wr] <= 2'd0;
        q_depth[q_wr] <= pos_i[scan_axis*POS_W +: POS_W];
        q_wr  <= q_wr + 1'b1;
        q_push_now = 1'b1;
    end else begin
        overflow_o_r <= 1'b1;
        if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
    end
end
```
代价：push 失败时下一帧重试（≤ 500 µs，一帧），与 OFF 分支的语义完全一致。

**验证能红**：把 `FIFO_D` 临时改成 `1`（或加一个 `parameter` 供 tb 覆盖），跑
`tb/w3a/tb_ee_adj.sv`（相邻轴 1/2/3 同帧越阈）⇒ 现在会**丢 note_on**（红），改完必须全绿。
⚠️ `tb/w3a/tb_event_extract.sv:302` 的 PASS 文案声称 *"NEVER loses events when several axes cross in the same frame"* ——
把 `FIFO_D=1` 之后这句就变成假话了，说明**该判据没有覆盖"FIFO 满"这一维**。

**归类：`[结构]`**。

---

### [P1] FIFO 深度 4 **结构上不可达**：`q_cnt ≤ 1` 恒成立 ⇒ 溢出守卫 / 丢失计数 / 深度 4 全是死逻辑 —— `rtl/w3a/event_extract.v:163-170,307,313-316,359-365,390`

**代码（原样）**

```verilog
localparam integer FIFO_D = 4;
localparam integer FW     = 2;
...
q_cnt <= q_cnt + (q_push_now ? 1'b1 : 1'b0)
               - ((q_cnt != 0) ? 1'b1 : 1'b0);       // :390 唯一写点
...
if (q_cnt != 0) begin                                 // :359 只要非空就每拍吐一个
    evt_valid_o <= 1'b1; evt_axis_o <= q_axis[q_rd]; ...
end
```

**机制（归纳证明，不是感觉）**
1. 扫描是**一拍一个轴**（`:298-352`）⇒ 每拍 **push ≤ 1**。
2. drain 只要 `q_cnt != 0` 就每拍 **pop = 1**（`:359`）。
3. 水位公式 `q_cnt' = q_cnt + push − (q_cnt≠0)`。取 `q_cnt ∈ {0,1}`：
   · `q_cnt=0`：`push=1` ⇒ 1；`push=0` ⇒ 0。 · `q_cnt=1`：`push=1` ⇒ 1；`push=0` ⇒ 0。
   ⇒ **`q_cnt ∈ {0,1}` 是归纳不变式**（初始 0，复位清 0）。
4. ⇒ `q_cnt < FIFO_D[FW:0]`（`4 < 4` 才假）**恒真** ⇒ `:313-316` 与 `:339-342` 的
   `overflow_o_r`/`lost_cnt_r` 分支**永不执行**；`q_axis/q_kind/q_depth` 各 4 项里只有 2 项会被写到。

**而且消费者也没有**：`rtl/top.v:3036-3037` 声明 `ee_ovf`/`ee_lost`，
`:3177-3178` 接上端口，**全文再无第三次出现** ⇒ 综合剪掉 ⇒
"`K-106` 溢出必须可见"在 bitstream 里**是空的**（**双重死**：置不了位 + 没人看）。

**修法（二选一，别混）**
- **(a) 诚实化 + 省资源**（推荐）：承认它就是 1 深 skid buffer。
  `localparam FIFO_D = 2; localparam FW = 1;`，`q_cnt` 改成 1 位 `q_full`，
  删掉 `lost_cnt_r`/`overflow_o_r`（或保留 `overflow_o` 但把它接到一个**真实可观测点**）。
  预期省 **54 FF + ~30 LUT**（4 项 × 18 bit = 72 bit 里只留 2 项）。
  ⚠️ 代价：`FIFO_D[FW:0]` 这种 `integer` 位选要一并清理（见 A 的 P3 条）。
- **(b) 保留深度 4 当"将来并行化的余量"**：那就**必须**把 `overflow_o`/`lost_cnt_o` 接到
  LED/串口/scope 任一处，并在注释里写明"当前不可达，是余量"。
  否则下一个人会以为溢出被守着 —— 项目 `K-87` 那一族（"看起来验过了"而"实际没验"）。

**验证能红**：新增判据 —— "连续 5 个轴同帧越阈 ⇒ `lost_cnt_o == 0` 且 5 条事件全部吐出"；
再故意把 `FIFO_D` 设 1，看该判据是否变红（证明它有鉴别力）。

**归类：`[结构]`**（面积与逻辑，与布局无关；**不影响 Fmax**）。

---

### [P1] `refr` 是 **16 位容器装 6 位值**（`REFRACT_N=60` 实测）⇒ 最多 160 FF + ~100 LUT 白烧，扫描锥多 4 级 —— `rtl/w3a/event_extract.v:131,236,303,305`

**证据（综合日志原文，参数是实测的）**

```
Compiling module 'event_extract(DW=13,TRIG_TH=12'b000001000000,REL_TH=12'b000000100000,REFRACT_N=60)'
Extracting RAM for identifier 'refr'("...rtl/w3a/event_extract.v":131)
```
来源 `sim/evidence/gowin_build.log:125-127`（=0 档）；=1 档日志同样。

**代码**

```verilog
reg [15:0]       refr   [0:AXIS_N-1];        // :131  16 位
...
if (refr[ai] != 16'd0) refr[ai] <= refr[ai] - 16'd1;      // :236  16 位 NOR + 16 位减法
...
if (refr[scan_axis] == 16'd0) begin                        // :303  16 位比较（经 16:1 mux）
    ...
    refr  [scan_axis] <= REFRACT_N[15:0];                  // :305
```

**机制 / 数字**
`REFRACT_N = 60 < 64` ⇒ 复位值 60、只做递减 ⇒ **`refr[15:6]` 恒为 0**（10 位/轴 × 16 轴 = **160 bit 恒 0**）。
成本：
- FF：若综合器没剪 ⇒ 256 FF，占 `u_event_extract REG=310` 的 **82.6%**。
  **反推证据**：`sim/evidence/gowin_m0_rsc.xml:43` = `Register="310" Lut="769"`。
  若这 10 位被剪掉，refr 只有 96 FF，全模块其余寄存器（key_on 16 + FIFO 72 + FSM 12 + evt 19 ≈ 119）加起来
  远低于 310 ⇒ **310 这个数强烈提示 Gowin 没有剪高位**（`Extracting RAM` 也没能把它变成 SSRAM：
  `Gowin2026_syn_resource.html` 里**全设计 60 个模块的 SSRAM 列全为 `-`**）。
- LUT：`refr[ai] != 0` 的 16 位 NOR ≈ 5 LUT4/轴，6 位只要 2 ⇒ **省 ~48 LUT**；
  `refr[scan_axis] == 0` 的 16:1 mux 从 16 位（~80 LUT）降到 6 位（~30 LUT）⇒ **再省 ~50 LUT**。
- 锥深：`refr` 支路少 4 级 LUT（mux 2 级 + NOR 2 级）—— 这条支路正是扫描锥里最深的一支（见 A 的 P2 条）。

**修法**

```verilog
// ⭐ 位宽由参数派生（60 ⇒ 6 位），⛔ 不再写死 16
localparam integer RW = (REFRACT_N < 2) ? 1 : $clog2(REFRACT_N + 1);
reg [RW-1:0] refr [0:AXIS_N-1];
...
if (refr[ai] != {RW{1'b0}}) refr[ai] <= refr[ai] - {{(RW-1){1'b0}}, 1'b1};
...
refr[scan_axis] <= REFRACT_N[RW-1:0];
if (refr[scan_axis] == {RW{1'b0}}) begin
```

**连带影响（改之前必须知道，否则第三道门会红）**
`bringup/mutation_test.ps1` 里两条变异体的 `find` 串**正是这两行**：
- `M90:437` `find = "if (refr[scan_axis] == 16'd0) begin"`
- `M91:438` `find = "refr  [scan_axis] <= REFRACT_N[15:0];"`
⇒ 改完必须同步改这两条 find（否则 `Contains` 为假 ⇒ SKIP ⇒ 脚本按 `K-87`/`K-125` 判 FAIL）。

**收益 / 代价**：预期 **−160 FF（若未剪）/ −~100 LUT / 锥深 −4 级**；
代价 = 3 行 + 2 条变异体锚点。**对当前 Fmax 无影响**（该路径没进任何 top-25）。

**验证能红（机械可判）**：改完重跑综合，读
`build/<dir>/impl/gwsynthesis/Gowin2026_syn_resource.html` 里 `u_event_extract` 的
`REG NUMBER`（预期 310 → ~150）与 `LUT NUMBER`（预期 769 → ~670）。
**若 REG 不变 ⇒ Gowin 本来就剪了高位**，那本条只剩 LUT/锥深收益 —— 这一步必须做，别猜。

**归类：`[结构]`**。

---

### [P2] 扫描锥"**先 mux 后比较**"⇒ ~12 级；改成"**先比较后 mux**"⇒ ~5 级，LUT 基本不变 —— `rtl/w3a/event_extract.v:301-302,320`

**代码（原样）**

```verilog
if (!key_on[scan_axis]) begin
    if (pos_i[scan_axis*POS_W +: POS_W] >= TRIG_TH) begin      // :302  先 16:1 mux，再比较
...
    if (pos_i[scan_axis*POS_W +: POS_W] < REL_TH) begin        // :320  同一个 mux 再来一次
```

**机制 / 数字（回答"16 轴 × 阈值是不是每轴一套常量比较器"）**
**不是 16 套** —— 因为扫描是串行的，综合出来是 **1 套比较器 + 一个 16:1 输入 mux**（两条比较共用同一 select）。
现值的锥深：

| 段 | 级数 |
|---|---|
| `refr[scan_axis]` 16:1 mux（16 位） | 2 |
| 16 位 NOR（`== 0`） | 2 |
| `key_on[scan_axis]` 16:1 mux（1 位） | 2 |
| `pos_i[...]` 12 位 16:1 mux | 2 |
| 常量比较（`pos>=64` = 6 位 OR / `pos<32` = 5 位 NOR） | 2 |
| FIFO 满判 + AND 汇聚 | 1~2 |
| **合计** | **≈ 11~12 级 LUT4** |

改成**每轴各一套常量比较器**（输入 `pos_i` 本来就是 192 位全并行，不需要 mux）：

```verilog
wire [AXIS_N-1:0] ax_ge_trig, ax_lt_rel;
genvar g;
generate for (g = 0; g < AXIS_N; g = g + 1) begin : gen_cmp
    assign ax_ge_trig[g] = (pos_i[g*POS_W +: POS_W] >= TRIG_TH);   // 常量比较：~2 LUT4/轴
    assign ax_lt_rel [g] = (pos_i[g*POS_W +: POS_W] <  REL_TH);    // ~2 LUT4/轴
end endgenerate
wire cur_ge_trig = ax_ge_trig[scan_axis];   // 1 位 16:1 mux = 5 LUT4
wire cur_lt_rel  = ax_lt_rel [scan_axis];
```
面积账：现值 ≈ 12 位 mux（~60 LUT）+ 比较器（~4 LUT）= **64 LUT**；
新值 ≈ 16×4 = 64 LUT + 2×5 = **74 LUT** ⇒ **+10 LUT 换 −6 级**。
锥深变为：比较 2 级 + 1 位 mux 2 级 + AND 1 级 ≈ **5~6 级**。

**收益 / 代价**：**结构性缩短 event_extract 自己的扫描锥**（对模块内的 setup 余量有利，给将来并行化留空间）；
代价 +10 LUT、+8 行。⚠️ **预期 Fmax 不变** —— 该路径不在任何 top-25 里（§0 证据），
所以这是"给未来留余量"，不是"救现在的 Fmax"。**别把它写成收益。**

**验证能红**：`tb/w3a/tb_event_extract.sv` + `tb/w3a/tb_ee_adj.sv` 必须仍全绿；
再用 PnR 报告看 `u_event_extract` 的 LUT 数与 `clk_sys` 的 Logic Level（**预期 Logic Level 不变**）。

**归类：`[结构]`**（级数与布局无关；但**收益大小**受布局影响，见 §0）。

---

### [P2] `scan_axis` 的自增/清零用了**硬编码 `4'd1`/`4'd0`** ⇒ `AXIS_N > 16` 时静默错 —— `rtl/w3a/event_extract.v:296,349,351`

**代码（原样，对比同项目另一个模块的写法）**

```verilog
// event_extract.v
scan_axis <= 4'd0;                                  // :296
scan_axis <= 4'd0;                                  // :349
scan_axis <= scan_axis + 4'd1;                      // :351   🔴 4 位加法
...
localparam integer SAW = (AXIS_N <= 1) ? 1 : $clog2(AXIS_N);   // :135

// param_extract.v（同一套 FSM，写法正确）
scan_axis <= {SAW{1'b0}};                           // :263
scan_axis <= scan_axis + {{(SAW-1){1'b0}}, 1'b1};   // :293
```

**机制**
`SAW = $clog2(AXIS_N)`。`AXIS_N = 32` ⇒ `SAW = 5`，而 `scan_axis + 4'd1` 的表达式宽度是 **4 位**：
`15 + 1 = 16` 被截成 **0** ⇒ 扫描在 0..15 之间打转，**永远到不了轴 16~31**；
且 `scan_axis == (AXIS_N-1)` = `== 31` **永不成立** ⇒ `scanning` 永不清零 ⇒
每帧扫 16 次"错轴"，另外 16 个轴**永远不被判键**（静默）。
今天 `AXIS_N = 16`（`rtl/top.v:3042`）⇒ 行为正确 —— 但这是**碰巧**。

**修法**：与 `param_extract` 统一。

```verilog
localparam [SAW-1:0] SAW_ONE = {{(SAW-1){1'b0}}, 1'b1};
localparam [SAW-1:0] SAW_ZERO = {SAW{1'b0}};
... scan_axis <= SAW_ZERO; ... scan_axis <= scan_axis + SAW_ONE;
```

**收益 / 代价**：消灭一个"改参数才炸"的静默缺陷；代价 3 行。
**验证能红**：例化 `AXIS_N = 32` 跑 `tb/w3a/tb_event_extract.sv`（今天必红）。

**归类：`[结构]`**。

---

### [P2] 同帧"原子性"依赖一条**从没写下来的隐式不变式**（今天余量 195×，无断言）—— `rtl/w3a/event_extract.v:290-352`

**机制 / 数字**
扫描是 **一拍一个轴、共 16 拍**（`:298-352`）；而输入 `pos_i` 来自 `axis_snapshot` 的**组合输出 `cur[]`**，
`cur[]` 会在**每个 `sample_valid_i`** 被改写（`rtl/w3a/axis_snapshot.v:113-122`）。
实测帧周期 500 µs @50 MHz = **25000 clk**、每帧 8 个通道 ⇒ **样本间隔 ≈ 3125 clk**。
`3125 / 16 ≈ 195×` ⇒ **今天扫描窗口完整落在样本间隙里，安全**。
但这条不变式（"样本间隔 > `AXIS_N` 拍"）在 RTL、在 tb、在文档里**都没有任何断言**：
`adc_farm` 的 SPI 时钟一提速（或扫描改成两拍一轴以外的东西），就会出现"轴 0 用的是 T 时刻、
轴 15 用的是 T+16 拍"的半新半旧快照 —— 与 `:192-193` 的"输入已经是同帧快照"直接冲突。

**修法（择一）**
1. 便宜：在 `axis_snapshot.v` 的帧契约注释里写死这条不变式 + 在 `initial` 里打印
   `AXIS_N` 与"必须 < 样本间隔"的对照（仿真侧防线，成本 0）。
2. 彻底：在 `snap_valid_i` 那一拍把 16 轴 `pos_i` 打进影子寄存器再扫（+192 FF，**不划算**，别做）。

**验证能红**：把 `adc_farm` 的 SPI 分频临时调到 4× 快，跑 `tb/top/tb_top_sound.sv`，
看是否出现"同帧只更新了一半轴"的症状（今天没有判据会报）。

**归类：`[结构]`**（潜在，不是当前缺陷 —— 如实标注）。

---

### [P3] `FIFO_D[FW:0]`（对 `integer` 做位选）与 `axis_map.v:93-99` 明令禁止的写法**冲突** —— `rtl/w3a/event_extract.v:307,332` vs `rtl/w3a/axis_map.v:94-99`

**代码（两边原样对照）**

```verilog
// axis_map.v:94-99 —— 明确记录"⛔ 不允许"
//   ⚠️ **踩过的坑（2026-09-23，本模块第一版）**：原来直接写 `N_KEY[KW-1:0]`
//      ⇒ 🔴 **`N_KEY` 是 `integer`，Verilog-2001 ⛔ 不允许对 `integer` 参数做位选**
//      ⇒ 实测 `N_KEY[3:0]` 求值为 **0**（⛔ 不是 16）⇒ ⭐ **钳位恒成立**

// event_extract.v:307 —— 同一个写法，正在用
if (q_cnt < FIFO_D[FW:0]) begin      // FIFO_D 也是 localparam integer
```

**机制 / 事实**
本设计**能工作**（事件能出、`tb_ee_adj` 全绿）⇒ `FIFO_D[FW:0]` 求值就是 4 ⇒
**"integer 位选一律求值为 0"这条经验至少在 `localparam integer` 上不成立**。
（`axis_map` 当年真正的坑是 `SHIFT = $clog2(N_KEY)` 那个 4 vs 8 的混淆 —— `:79-88` 自己写了。）

**修法**：用一个 3 行的最小实验把它钉死，然后**统一两处**：

```verilog
localparam [FW:0] FIFO_D_V = FIFO_D;   // 先落成定宽常量，再比较 ⇒ 不依赖工具宽容
if (q_cnt < FIFO_D_V) begin
```
最小实验：`$display("N_KEY[3:0]=%0d FIFO_D[2:0]=%0d", N_KEY[3:0], FIFO_D[2:0]);` —— 一次跑完就知道。

**收益**：消灭一条**会误导后人的错误经验规则**（按那条规则去"修"正确的代码，就会引入真缺陷）。
代价 ≈ 0。**验证**：`$display` 的输出直接看。

**归类：`[结构]`**（文档/经验库一致性）。

---

### [P2] `enable_i` 的"悬空 = 使能"**只在仿真成立**；综合后悬空 = 0 ⇒ 事件层永久静音 —— `rtl/w3a/event_extract.v:263-278`

**代码**

```verilog
if (enable_i === 1'b0) begin          // :278  四态比较
    for (ai = 0; ai < AXIS_N; ai = ai + 1) begin
        key_on[ai] <= 1'b0; refr[ai] <= 16'd0;
    end
    scanning <= 1'b0;
end else begin ... 扫描 ...
```
注释（`:271-277`）：*"只有【明确的 0】才代表未使能，而 x/z（悬空）按【使能】处理 ⇒ 不接该端口的老 tb 行为与改动前完全一致"*。

**机制 / 事实**
- 仿真侧 ✅：`tb/w3a/tb_event_extract.sv` **确实没有连 `enable_i`**（全文搜不到该端口）⇒ 悬空 `x` ⇒ `=== 1'b0` 为假 ⇒ 按使能 ⇒ 老用例行为不变。这条设计**成立**。
- 综合侧 ⚠️：硬件里没有 `x`。若将来某个例化**漏接** `enable_i`，Gowin 会把该输入当 0
  ⇒ `enable_i === 1'b0` 恒真 ⇒ **每个时钟沿都清 `key_on`/`refr` 且不扫描** ⇒
  **整条事件通路永久静音**，而且**没有任何告警**（Gowin 的 `CV0016 Input ... is unused` 只在顶层端口报）。
- 对比：`rtl/w3c/note_manager.v` 用的是同一套"悬空 = 使能"口径（`:158`/`:301` 自述），
  ⇒ **风险面不止这一个模块**。

**修法（低成本加固）**
```verilog
// ⭐ 只在【明确的 0】时锁死；悬空（z/x）按使能 —— 但综合里没有 x，
//    所以再加一条"结构性"保险：把 enable 改成【低有效锁存 + 显式默认】：
//    在 top.v 例化处强制写 .enable_i(at_en_ready)，⛔ 不允许省略（用 lint/脚本来守）
```
更实际的做法：**在 `sim/gowin_build.ps1` 里 grep 所有 `event_extract`/`note_manager` 的例化，
确认 `enable_i` 被显式连接**（构建期检查，不依赖仿真）。

**验证能红**：临时删掉 `top.v:3162` 那一行 `.enable_i(...)`，跑综合 ⇒ **不报错、不告警**，
上板/后仿才是静音 —— 证明"仿真侧防线"在综合侧不存在。

**归类：`[结构]`**。

---

## B. 扳机 TRIGGER —— `rtl/w3a/param_extract.v`

### [P1] `param_extract` **整模块被综合扫掉**（NL0002），`top.v:4092` 的注释是**错的** —— `rtl/top.v:3335` / `:4092`

**证据（两份构建日志都有，=0 档与 =1 档各一次）**

```
WARN  (NL0002) : The module "param_extract" instantiated to "g_sound.u_param_extract" is swept in optimizing("...rtl/top.v":3335)
```
来源 `sim/evidence/gowin_build.log:210` 与 `build/rightadc-probe/impl/gwsynthesis/Gowin2026.log`。
`sim/evidence/gowin_m0_rsc.xml` 里**根本没有** `u_param_extract` 这一行（连 0 都不占）。

**机制（两条输出全死，逐条）**
1. **力度通路**：`top.v:4096-4098` 用的是 `vu_valid_r`/`vu_axis_r`/`vu_val_r`（位置式力度流）
   ⇒ `pe_vel_v`/`pe_vel_ax`/`pe_vel`（`:3288-3290` 声明、`:3329-3331` 连接）**无消费者**。
2. **音高通路**：`param_extract.v:239` `pitch_valid_o <= 1'b0;` 是**唯一**赋值（全文再没有置 1 的地方），
   `:344 assign pitch_value_o = {PHASE_W{1'b0}};` ⇒ `pe_pitch_v` **恒 0**、`pe_pitch` **恒 0**。
   ⇒ `top.v:4117 .pitch_upd_valid_i (pe_pitch_v | lp_upd_valid)` 化简成 `lp_upd_valid`（**只有 looper 回放**）。

**矛盾点（注释 vs 代码，项目 ③ 类）**
`top.v:4091-4092` 写着：*"⛔ 不删实例、⛔ 不动 `param_extract.v` —— 它的**音高**通路
（`pe_pitch_v`/`pe_pitch_ax`/`pe_pitch` ⇒ 下方 `pitch_upd_*`）**仍在用** ✅"* ——
**代码上不成立**（`pitch_valid_o` 恒 0）。⇒ 这句注释会让人以为"手弹的 pitch_upd 通路是通的"。

**修法**
1. 把 `top.v:4091-4092` 改成事实：*"本模块当前【整体被综合剪掉】（NL0002，见构建日志）；
   `pitch_valid_o` 恒 0（`param_extract.v:239`），力度输出未接（`:4096`）。保留实例只为阶段 2 的接口。"*
2. `top.v:4117-4120` 那两行加注释：`pe_pitch_v ≡ 0`，`pitch_upd_*` 实际来源只有 looper。
3. **真正的风险提示**：谁要是"修好" `pitch_valid_o`（阶段 2 的本意），
   **会突然激活一条从未被任何 PnR / 回归覆盖过的通路**（与 §C 的 `axis_snapshot.delta` 同族）。

**验证能红**：`Select-String -Path sim\evidence\gowin_build.log -Pattern NL0002`（现成证据）；
或写一条资源判据："`u_param_extract` 的 REG/LUT 必须为 0"。

**归类：`[结构]`**。

---

### [P1] `VEL_T1_EFF` 是**装饰品**：浅阈从未参与测速 ⇒ 文档的"双阈值测速法"只实现了后半截 —— `rtl/w3a/param_extract.v:110-111,251-255,269,361,367`

**证据（全文引用次数）**
`VEL_T1_EFF` 只出现 **3** 次：定义 `:110-111`、`PARAM_OK` `:361`、`$display` `:367`。
**逻辑里一次都没用。** 真正"记 t1 时刻"的是：

```verilog
if (evt_valid_i && (evt_kind_i != 2'd1)) begin        // :251
    t1_stamp[evt_axis_i] <= frame_cnt;                // :253  ← 由 event_extract 的越阈驱动
    t1_seen [evt_axis_i] <= 1'b1;
end
...
if (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T2_EFF) begin   // :269  ← 只有深阈在这里
```

**机制 / 数字**
- 设计意图（`:15-17`）：从 `VEL_T1_EFF` 记到 `VEL_T2_EFF`。
  `POS_FULL = 744`（综合日志实测 `param_extract(POS_FULL=12'b001011101000)`），
  `VEL_T1_PCT=50`、`VEL_T2_PCT=80` ⇒ **`VEL_T1_EFF = 372`、`VEL_T2_EFF = 595`**，跨度 **223 码**。
- 实际：t1 由 `event_extract` 的 `TRIG_TH = 64`（**8.6%**）驱动 ⇒ 跨度 = `595 − 64 = ` **531 码**，
  是设计意图的 **2.38 倍**。
- 后果：`DT_MAX = 64` 帧 = 32 ms 是**按 223 码跨度**标定的（`:81-86`）。按实测跨度 531 码重算：
  744 码/30 ms 的手速 ⇒ 531 码 ≈ **21 ms ≈ 43 帧**（勉强在表内）；
  744 码/50 ms 的慢手 ⇒ 531 码 ≈ **36 ms ≈ 71 帧 > 64** ⇒ **直接撞 `VEL_MIN` 地板**。
  ⇒ **慢按全部同音量**（力度响应只剩快按侧）——正是 `:70-79` 当年想修的那个症状，只是偏了方向。
- 附带：`VEL_T1_EFF` 只被 PARAM_OK 拿去和 `VEL_T2_EFF` 比大小 ⇒ 它**可以填任意 < 595 的值**而无人察觉。

**修法（二选一，别和稀泥）**
- **(a) 让浅阈真的参与**（推荐，符合文档意图）：在扫描里加一个"浅阈越阈"的置位分支：
  ```verilog
  // 在扫描循环里，pos 首次 >= VEL_T1_EFF 的那一帧记 t1（与 evt 的 t1_stamp 取【更早】者）
  if (!t1_seen[scan_axis] && (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T1_EFF))
      begin t1_stamp[scan_axis] <= frame_cnt; t1_seen[scan_axis] <= 1'b1; end
  ```
  ⚠️ 与 `:251-255` 的 evt 分支**会撞同一拍写**（同款两处写问题）⇒ 必须按"取更早的时刻"合并成一个写点。
- **(b) 把文档改对**：删掉 `VEL_T1_EFF`/`VEL_T1_PCT`，把 `:15-17` 改成
  *"浅阈 = `event_extract.TRIG_TH`"*，并按 **8.6% → 80%** 的实际跨度把 `DT_MAX` 重标（64 → **~100 帧 = 50 ms**）。

**验证能红**：`tb/w3a/tb_param_extract.sv` 里加一条判据 ——
"同一手速下，改变 `VEL_T1_PCT` 必须改变 `vel`"（**今天恒不通过** ⇒ 直接证明它是死的）。

**归类：`[结构]`**。

---

### [P2] `Δt` 下溢钳位与物理语义**相反**：帧计数回绕时把"最慢按"变成"最响按" —— `rtl/w3a/param_extract.v:275-278`（+ tb 判据 ⑤b + 变异体 M96）

**代码（原样）**

```verilog
if (frame_cnt >= t1_stamp[scan_axis])
    dt_hold[scan_axis] <= frame_cnt - t1_stamp[scan_axis];
else
    dt_hold[scan_axis] <= 16'd0;    // ⭐ 钳位，⛔ 不回绕
```

**机制 / 数字**
`frame_cnt`/`t1_stamp` 都是 **16 位**，帧周期 **500 µs** ⇒ **回绕周期 = 65536 × 500 µs = 32.8 s**。
设 note_on 落在回绕前（`t1_stamp = 65000`），t2 越阈落在回绕后（`frame_cnt = 100`）：
- **真实 Δt = (65536 − 65000) + 100 = 636 帧 = 318 ms** ⇒ 这是**很慢的按法** ⇒ 应给 `VEL_MIN = 64`。
- 现在：`frame_cnt (100) >= t1_stamp (65000)` 为假 ⇒ **钳 0** ⇒ `vel_of(0)` ⇒ **`VEL_MAX = 255`（最响）**。
发生概率 ≈ 按键窗口 / 回绕周期 ≈ **100 / 65536 = 0.15% 每次按键**（约每 660 次一次异常重音）。

**修法（删掉钳位，用模运算 —— 模减在回绕时给出的正是 636）**

```verilog
dt_hold[scan_axis] <= frame_cnt - t1_stamp[scan_axis];   // 模 2^16，跨回绕正确
```
安全性：若 `t1_stamp` 是垃圾值（"未来"时刻），模差会是一个巨大数 ⇒ 被 `vel_of` 的
`dt >= DT_MAX ⇒ idx = DT_MAX+1 ⇒ VEL_MIN` 兜住 ✓（**最弱**，安全侧）。

**连带影响（一起改，否则第三道门红）**
1. `tb/w3a/tb_param_extract.sv:298-335`（判据 ⑤b）现在断言的是**错的行为**：
   `chk("an underflowing dt is CLAMPED ...", (k_wrap >= 1) && (v_wrap === 8'd255));`
   ⇒ 改后期望值必须变成 **`64`（`VEL_MIN`）**，并把 `:300` 的时基笔误一起修（见 B 的 P3 条）。
2. 变异体 `M96`（`bringup/mutation_test.ps1:443`）的 `find = "dt_hold[scan_axis] <= 16'd0;"`
   **会失效** ⇒ 要么删 M96，要么换成等价变异（例如 `dt_hold <= t1_stamp - frame_cnt;`）。

**验证能红（必须先证明判据有鉴别力）**：先用**未改**的代码跑 ⑤b 的场景，
确认它给 255（= 证明这条判据确实在测这个行为）；改后应为 64。

**归类：`[结构]`**。

---

### [P2] 力度映射表的 `LUT_N = DT_MAX + 2 = 66` 不是 2 的幂 ⇒ 索引多一级钳位、译码变宽 mux —— `rtl/w3a/param_extract.v:177,202-211`

**代码**

```verilog
localparam integer LUT_N = DT_MAX + 2;          // 66
reg [VEL_W-1:0] vel_lut [0:LUT_N-1];
function [VEL_W-1:0] vel_of;
    input [15:0] dt; integer idx;
    begin
        if (dt >= DT_MAX) idx = DT_MAX + 1;     // 两级钳位比较
        else if (dt <= DT_MIN) idx = 0;
        else idx = dt;
        vel_of = vel_lut[idx];
    end
endfunction
```

**机制**：66 项的常量表要落成 66:1 选择逻辑（或补到 128）；索引还带两级比较器。
把表**补到 128 项**（`localparam LUT_N = 128;`，`dt >= DT_MAX` 的位置全部填 `VEL_MIN`），
则 `vel_of` 可以直接 `vel_lut[dt[6:0]]` —— **少一个比较器 + 一个干净的 7 位地址译码**；
常量多 62×8 = 496 bit（LUT INIT 折叠，面积几乎不涨）。

**收益 / 代价**：~少 20~30 LUT + 少一级锥；代价 = 表尺寸常量 +1 行、`vel_of` 简化。
⚠️ **前提**：该模块当前被扫掉（见 B 的 P1 条），**必须先把它接回消费者才谈得上收益**。

**验证**：接回 `pe_vel_*` 后跑综合，比对 `u_param_extract` 的 LUT NUMBER。

**归类：`[结构]`**。

---

### [P3] `dt_valid` 在**同一个 always 块里被两处写**（扫描置位 / 出队清零）—— 项目已经因为同款写法栽过两次 —— `rtl/w3a/param_extract.v:280,324`

**代码**

```verilog
dt_valid[scan_axis] <= 1'b1;        // :280  扫描里置位
...
dt_valid[emit_axis] <= 1'b0;        // :324  出队里清零（在本块中【更靠后】）
```

**机制**：同拍同索引时**后写胜** ⇒ 该轴的 `vel_update` 静默丢失；
更糟的是 `t1_seen[scan_axis]` 已在 `:281` 被清 ⇒ **这次按键再无第二次机会**。
可达性：`emit_axis` 恒比 `scan_axis` 落后 ≥2 拍、`emitting` 只维持 1 拍 ⇒ **今天不可达**。
但 `event_extract` 的 `q_cnt` 就是被**同款写法**咬过的（`:367-391` 那一大段注释），
项目自己在 `:157` 也写了"`for` 循环里改指针会互相覆盖"的教训。

**修法（与 `q_cnt` 同款"单一写点"）**

```verilog
reg dt_set, dt_clr; reg [SAW-1:0] dt_set_ax, dt_clr_ax;
// 扫描/出队只置标志，块末统一：dt_valid[i] <= (dt_set&i==ax) ? 1 : ((dt_clr&i==ax) ? 0 : dt_valid[i]);
```
（16 项循环展开即可，成本 ~20 LUT，换来"结构上不可能失步"。）

**验证能红**：写一个定向 tb，层次赋值把 `dut.scan_axis`/`dut.emit_axis` 造到同一索引同一拍，
看现在是否丢包。

**归类：`[结构]`**。

---

### [P3] `tb/w3a/tb_param_extract.sv:300` 的时基**仍然是错的**（196 µs）—— K-128 只修了 RTL，没修 tb

**代码（tb 原样）**

```
//      ⭐ `frame_cnt` 是 **16 位**，⭐ 一帧 ≈ 196 µs
```
`rtl/w3a/param_extract.v:64-66` 已更正为 *"一帧 = **500 µs**（⛔ 不是原来注释写的 196 µs）… 见 `K-128`"*，
`rtl/top.v:3128-3130` 也改过。⇒ **同一笔误在本项目已修过至少 3 处，tb 里还剩这一处。**

**修法**：`一帧 ≈ 196 µs` → `一帧 = 500 µs（K-128）`，并把 `:302` 的"回绕前 65000"注释
按 32.8 s 复核（数值本身不用改，只改叙述）。
**验证**：`Select-String -Path tb\w3a\*.sv -Pattern "196"` 应为空。
**归类：`[结构]`**（文档一致性）。

---

### [P3] `t1_stamp` 的复位值与"帧 0 合法"**同值**，代码里没有"未初始化"标记 —— `rtl/w3a/param_extract.v:220-221`

**机制**：`t1_stamp <= 16'd0` 与 `frame_cnt` 的合法值 0 无法区分。
今天靠 `t1_seen` 兜住（`t1_stamp` 只在 `t1_seen=1` 时可信）⇒ 不是活缺陷。
**修法**：在 `:148` 加一行注释写死这个不变式 —— *"`t1_stamp` 只在 `t1_seen[i]=1` 时可信；
`t1_seen` 是唯一的权威标志"*。**验证**：无（纯文档）。**归类：`[结构]`**。

---

## C. 音叉 TONEFORK —— `rtl/w3a/axis_map.v`

### [P1] 表项填 0 时 `phase_safe` 会把它变成"几乎静止的 DC 音"，而**没有任何检查表项的守卫** —— `rtl/w3a/axis_map.v:539-544,560-561,563-573`

**代码（原样）**

```verilog
wire [PHASE_W-1:0] phase_safe = (phase_calc == {PHASE_W{1'b0}}) ? {{(PHASE_W-1){1'b0}}, 1'b1}
                                                                : phase_calc;      // :543
localparam PARAM_OK = (N_KEY >= 2) && NKEY_IS_POW2 && (BASE_INC != 0);              // :561
```

**机制 / 数字**
`phase_inc = 1` ⇒ `f = 1 × 48828.125 / 2^32 = ` **1.14e-5 Hz** ⇒ 相位累加器要走完一圈需要 **85899 s**（≈24 小时）
⇒ 输出近似**恒定 DC**（听不见，但**占着一个 voice**、包络照跑）。
而 `PARAM_OK` 只查 `BASE_INC != 0` —— **看不到 `kb_inc[0..15]` / `fb_inc[0..15]` 这 32 项**（它们由 `initial` 逐项赋值）。
⇒ **手填表时把某一项写成 `32'd0`（或漏写），那个键不响、还占 voice，且没有任何报错。**
这两张表恰恰是本项目改得最勤的地方（`:300-304` 改名、`:354-391` 换键盘表、`:398-457` 重排指板表）。

**修法（`ti` 已在 `:352` 声明，直接加进 `:563` 的 `initial` 块）**

```verilog
for (ti = 0; ti < N_KEY; ti = ti + 1) begin
    if (kb_inc[ti] == {PHASE_W{1'b0}})
        $display("ERROR [axis_map] kb_inc[%0d] == 0 => that key plays a DC 'note' (f=1.1e-5 Hz) and HOLDS a voice. PARAM_OK=0.", ti);
    if (fb_inc[ti] == {PHASE_W{1'b0}})
        $display("ERROR [axis_map] fb_inc[%0d] == 0 => same. PARAM_OK=0.", ti);
end
// 顺手把表值打出来，日志里能直接核对
$display("NOTE [axis_map] kb_inc[0]=%h kb_inc[15]=%h fb_inc[0]=%h fb_inc[15]=%h",
         kb_inc[0], kb_inc[15], fb_inc[0], fb_inc[15]);
```

**收益 / 代价**：32 行表里任何一项填错立刻可见；代价 ≈ 0（只在仿真 elaborate 跑）。
⚠️ 诚实说明：`$display` 在综合里被忽略（见 A 的 P1 条）⇒ 这仍是**仿真侧防线**，
但"表填错"正是"仿真能看见、上板才发现"的典型，值得有。

**验证能红**：临时把 `kb_inc[7]` 改成 `32'd0`，跑 `tb/w3a/tb_axis_map.sv`
⇒ **今天不报**；改后必报。（也可作为新变异体：**"某一项表置 0 ⇒ 必须有判据红"**。）

**归类：`[结构]`**。

---

### [P1] `pos_i` / `key_idx` / `key_sel` / `sel_key` / `frac` / `inc_hi` / `hi_sel` / `interp*` **全是死逻辑** ⇒ "两层表"实际只有**一层** —— `rtl/w3a/axis_map.v:113,183,189,519,522,526-527,531-534`

**证据（代码 + 综合资源，两条独立）**
1. 代码：`:522 wire [PHASE_W-1:0] inc_lo = mode_i ? fb_inc[fb_sel] : kb_inc[fb_sel];`
   而 `fb_sel = axis_id_i[KW-1:0]`（`:148`）—— **与 `pos_i` 无关**。
   `key_idx`（`:113`）→ `key_sel`（`:183`）→ `sel_key`（`:189`）**链条在 `sel_key` 处断掉**（`sel_key` 无人引用）；
   `frac = {FRAC_W{1'b0}}`（`:519`）恒 0 ⇒ `interp_raw = inc_delta * frac`（`:532`）恒 0 ⇒
   `interp = 0`（`:533`）⇒ `phase_calc = inc_lo`（`:537`）；`hi_sel`/`inc_hi`（`:526-527`）无人引用。
2. 综合：`sim/evidence/gowin_m0_rsc.xml:46` = **`u_axis_map Lut="60"`，无 Register 字段（= 0 FF）**。
   若插值链活着，至少要一个 32 位乘法器 + 32 位加法器 + 32 位 mux ⇒ 绝不可能是 60 LUT。

**机制 / 后果**
- `:14-15` 文件头的"第 1 层 `pos_i` → `key_idx`"**在 bitstream 里不存在**；
- `pos_valid_i` 只被透传成 `phase_valid_o`（`:548`）⇒ **`pos_i` 这个输入端口完全没用**，
  连带 `rtl/top.v:3258` 的 `as_pos[pm_axis*12 +: 12]`（12 位 16:1 mux）也被剪；
- `:513-515` 的注释只说"`key_idx`/`key_sel`/插值链没有消费者"，**漏了 `pos_i` 本身**
  ⇒ 下一个人会以为"滑弦已经通了、只是插值关着"。

**修法**
1. `:192` 的标题"第 2 层表：`key_sel` → `phase_inc`" 与 `:14-15` 的表要改成事实：
   *"当前**只有一层**：`axis_id_i` → `phase_inc`（两张常量表由 `mode_i` 二选一）；
   `pos_i`/插值链为滑弦预留，**当前无消费者、已被综合剪掉**。"*
2. 端口注释 `:54-56` 加 *"⚠️ 当前未使用（滑弦预留）"*。
3. 若短期不做滑弦：把 `key_idx`/`key_sel`/`sel_key`/`frac`/`hi_sel`/`inc_hi`/`interp` 整段
   挪进 `` `ifdef AXIS_MAP_SLIDE `` 或直接删 —— 省 0 资源，但**省掉 40 行会误导人的代码**。
4. **风险提示**：滑弦一旦启用，插值链（32 位乘法 + 加法 + 比较）会**复活**，
   而这条路径从未被任何 PnR 分析过（`u_axis_map` 现在 0 FF / 60 LUT）。

**验证能红**：在 tb 里**只改 `pos_i`**（保持 `axis_id_i`/`mode_i` 不变），断言 `phase_inc_o` **不变**
⇒ 今天就通过 ⇒ 直接证明 `pos_i` 是死的。反向判据（"文档说的 key_idx 影响音高"）会红。

**归类：`[结构]`**。

---

### [P2] 常量表的落地方式：综合器先尝试 `Extracting RAM`，**最终落回 LUT-INIT 常量表**（SSRAM=0）—— 回答"有没有意外推断出分布式 RAM" —— `rtl/w3a/axis_map.v:226-227,353-458`

**证据**

```
Extracting RAM for identifier 'kb_inc'("...rtl/w3a/axis_map.v":226)
Extracting RAM for identifier 'fb_inc'("...rtl/w3a/axis_map.v":227)
```
（`sim/evidence/gowin_build.log:135-136`）
但最终资源表里：**全设计 60 个模块的 `SSRAM NUMBER` 列全为 `-`**（`Gowin2026_syn_resource.html`，
我用脚本过滤 `SSRAM != '-'` 得到 **0 行**），`u_axis_map` 只有 `LUT=60`、`REG=0`、`BSRAM=-`。
⇒ **不是分布式 RAM**：16 项 × 1 bit 的常量表正好能塞进一个 LUT4 的 INIT（16 bit），
两张表 × 32 bit ≈ 60 LUT4 ⇒ 这解释了 60 这个数。

**风险（真实且具体）**
这个映射依赖"综合器把 `initial` 对 `reg` 数组的赋值当作上电初值"。
Gowin 这里做到了（上板音高正确是佐证）；但**没有任何自检能发现"表没被初始化"**：
若表全 0，`phase_safe` 会把**每个键**都变成 `inc = 1` ⇒ **32 个键全是同一个 DC 音**（静默）。

**修法**：与上一条的"表项非 0 检查"合并即可覆盖；
再加一条"表不能全同"的检查（`if (kb_inc[0]==kb_inc[1] && kb_inc[1]==kb_inc[2] ...)` 取首/中/末三项比较即可）。
**验证**：把整个 `initial` 填表段临时注释掉，跑仿真看是否报"表项为 0"。
**归类：`[结构]`**。

---

### [P3] `phase_valid_o = pos_valid_i` 的**命名**与"`pos_i` 已废弃"不一致 —— `rtl/w3a/axis_map.v:548,54`

`:548 assign phase_valid_o = pos_valid_i;` —— 逻辑**正确**（valid 与 `phase_inc_o` 同拍，判据 4 成立），
但端口名叫 `pos_valid_i` 会让人以为"valid 与 `pos_i` 相关"，而 `pos_i` 恰恰是死的（见 C 的 P1 条）。
**修法**：改名 `upd_valid_i`（top.v 例化处 `:3279` 同步改）。**收益**：可读性 / 防误判。**代价**：2 处。**归类：`[结构]`**。

---

## D. 快门 SHUTTER —— `rtl/w3a/axis_snapshot.v`

### [P1] `delta` 通路在 bitstream 里**不存在**（`Register=193` 恰好 = `cur` 192 + `snap_valid` 1）—— `rtl/w3a/axis_snapshot.v:76-77,148-151,211-212`

**证据链（三重独立，硬）**
1. **代码**：`rtl/top.v:3165 .delta_i (as_delta)` ⇒ 而 `rtl/w3a/event_extract.v:103` 的 `delta_i` **在模块体内从未被读**
   （全文只有端口声明那一处）。`rtl/top.v:2523/2548` 的 `as_delta` 也只有"声明 + 连接"两处。
2. **综合资源**：`sim/evidence/gowin_m0_rsc.xml:41` = `u_axis_snapshot Register="193" Lut="8"`。
   **193 = 16 × 12 + 1**，正好是 `cur[]`（192）+ `snap_valid_o`（1）
   ⇒ **`prev[]` 的 192 FF、`seen[]` 的 16 FF、`first_ch_of_frame` 的 1 FF 全被剪掉**。
   （`Gowin2026_syn_resource.html` 里同一个数 193/8，两份报告一致。）
3. **对比**：`tb/w3a/tb_axis_snapshot.sv:202-214` 在**仿真里**逐条查 delta 的正负号
   ⇒ **仿真全绿、硬件里这个信号不存在**（`K-56` 族："全绿不证明任何事"）。

**机制 / 后果**
`:5-21` 文件头把"算 Δ"列为模块存在的**两个理由之一**；实际上
**"16 轴原子快照 + 带符号 Δ" 只交付了"快照"，Δ 是纸面的**。
真实风险：阶段 2 一接上滑音/双音，**192 FF + 16×13 减法阵列会突然复活**，
而它**从未被任何一次 PnR 分析过**（§0 证据：30 份报告里 w3a 只出现过一次，且是 hold）。
⇒ **阶段 2 落地时必须重跑 PnR，⛔ 不能沿用现在的 55.06/57.02 结论。**

**修法（今天就做，防"幽灵复活"）**
1. `axis_snapshot.v` 文件头 + `:65` 端口注释加一句：
   *"⚠️ 当前 `delta_o`/`axis_seen_o` 无消费者，已被综合剪掉（`Register=193` 即证）；启用前必须重跑 PnR。"*
2. `rtl/top.v:3165` 那一行加同样的注释。
3. （可选，最强）把 `as_delta` 接到一个真实观测点（例如已有的 `u_scope`），
   让"这条通路活着"变成综合可见的事实 —— 代价：**Fmax 会动，必须重跑 PnR**。

**验证能红**：接上消费者后重跑 PnR，预期 `u_axis_snapshot` **REG +192、LUT +~200**，
并检查 `clk_sys` 的 Actual Fmax / Logic Level 是否变化。

**归类：`[结构]`**（"存在与否"与布局无关）。

---

### [P1] `axis_seen_o` **从不清零** ⇒ 端口文档说的"本帧"是错的（诊断信号永久饱和）—— `rtl/w3a/axis_snapshot.v:66,109,119,216`

**代码（原样）**

```verilog
output wire [AXIS_N-1:0] axis_seen_o      // ⭐ 本帧收到过哪些轴（诊断）      // :66
...
seen <= {AXIS_N{1'b0}};                                                     // :109 只在复位清
...
cur[di*8 + sample_ch_i]  <= sample_data_i[di*POS_W +: POS_W];
seen[di*8 + sample_ch_i] <= 1'b1;                                           // :119 只置位
...
assign axis_seen_o = seen;                                                  // :216
```

**机制**：**全模块没有任何 `seen <= 0` 的帧边界清零** ⇒ 某轴一旦收到过一个样本，
该位**永久为 1** ⇒ 这个诊断永远无法回答它唯一想回答的问题（"本帧哪个轴没来"）。
⇒ 与 `:66` 的注释**直接矛盾**。

**修法（注意：清零必须与置位合并成单一写点 —— 本块已有"两处写同一数组"的隐患）**

```verilog
wire new_frame = sample_valid_i && (sample_ch_i == 3'd0) && first_ch_of_frame;
always @(posedge clk) begin
  ...
  if (sample_valid_i) begin
      // ⭐ 单一写点：新帧先清零，再按片置位（用掩码合并，⛔ 不写两次 seen）
      for (di = 0; di < N_ADC; di = di + 1) begin
          if ((di*8 + sample_ch_i) < AXIS_N) begin
              cur [di*8 + sample_ch_i] <= sample_data_i[di*POS_W +: POS_W];
              // seen 的更新挪到块末统一做（见下）
          end
      end
  end
  ...
  // ⭐ seen 的唯一写点
  if (sample_valid_i) begin
      seen <= (new_frame ? {AXIS_N{1'b0}} : seen) | seen_mask;
  end
end
// seen_mask：本拍命中的轴置位（generate 展开）
```
（也可简单点：把 `:113-122` 的置位循环改成"先算 `mask`，再一次性写 `seen`"。）

**验证能红**：`tb/w3a/tb_axis_snapshot.sv:167` 只查了"复位后 seen=0"；
**新增**判据 —— "第 2 帧只送 `ch3` ⇒ `axis_seen_o` 必须只反映轴 3/11"（**今天必红**）。

**归类：`[结构]`**。

---

### [P2] 帧 1 的 `delta_o` 是"`cur − 0`"（语义无效），且**没有任何判据覆盖** —— `rtl/w3a/axis_snapshot.v:110,148-151`

**机制 / 数字**
`prev` 只在"新帧 ch0 **且** `first_ch_of_frame`"那一拍固化（`:148-151`），
而 `first_ch_of_frame` **复位为 0**（`:110`）⇒ **第 1 帧不固化** ⇒ `prev` 保持复位值 0
⇒ **第 1 帧 `delta = cur`（最大 +4095）**。
tb 的 delta 判据从**第 2 帧**才开始（`tb_axis_snapshot.sv:193-203`）⇒ 第 1 帧无人检查。
阶段 2 接上滑音后，"全部轴 delta 都为正且很大"会让**双音判据（`dA≥0` 且 `dB≥0`）**在第 1 帧对所有轴成立
⇒ 上电/重标定后那一帧里只要有轴越阈，就可能**多发一个音**。

**修法（最小、语义最干净）**

```verilog
reg primed;
...
if (sample_valid_i && (sample_ch_i == 3'd0) && first_ch_of_frame) begin
    for (wi = 0; wi < AXIS_N; wi = wi + 1) prev[wi] <= cur[wi];
    primed <= 1'b1;                                  // ⭐ 第 1 帧只做固化，⛔ 不出快照
end
...
always @(posedge clk) begin
    if (!rst_n) snap_valid_o <= 1'b0;
    else        snap_valid_o <= frame_done_i & primed;
end
```
代价：上电/重标定后**多 500 µs 静默**（完全可接受）。

**验证能红**：新增判据 —— "第 1 帧不得产生 `snap_valid`"（`snap_total` 在 `:198` 已有计数器，直接可用）。
**归类：`[结构]`**。

---

### [P2] 握手有一处**真实**的隐含假设：`frame_done` 必须与"最后一个样本"同拍或更晚 —— `rtl/w3a/axis_snapshot.v:188-193`

**代码 + 注释（原样）**

```verilog
//   ⚠️ 延迟一拍：⭐ 让 `frame_done` 那一拍写入的 `cur` 先落定，
//      下一拍再发快照 ⇒ ⭐ 保证快照里**一定包含本帧最后一个通道**
always @(posedge clk) begin
    if (!rst_n) snap_valid_o <= 1'b0;
    else        snap_valid_o <= frame_done_i;
end
```

**机制**：这段推理**隐含假设 `frame_done_i` 与最后一个 `sample_valid_i` 同拍**。
若哪天 `adc_farm` 把 `frame_done` 提前一拍（或改成"下一帧第一拍才给"），
快照就会**少一个通道**或**多等一帧**，而模块里**没有任何检查**。
现有 tb 只送部分通道（`tb_axis_snapshot.sv:172-180` 送 ch0/ch3），
**从不检查"16 个轴都非零"** ⇒ 这个假设今天是裸奔的。

**修法（便宜且有效）**：在 `snap_valid_o` 那一拍加一条仿真侧诊断：

```verilog
always @(posedge clk)
    if (rst_n && snap_valid_o && (seen != {AXIS_N{1'b1}}))
        $display("WARN [axis_snapshot] snap_valid fired but seen=%h (some axes have no data this frame) -- check that frame_done is coincident with the LAST sample_valid", seen);
```
（依赖 D 的 P1 条先修好 `seen` 的清零，否则它恒不触发。）
或至少把"`frame_done` 必须与最后样本同拍或更晚"写进 `adc_farm` 的接口契约注释。

**验证能红**：把 `frame_done` 提前一拍驱动，看是否出现"某轴恒 0"（今天**不会报警** ⇒ 证明无保护）。
**归类：`[结构]`**。

---

### [P3] `N_ADC * 8 > AXIS_N` 时多出来的片**被静默丢弃**，自检只查 `>=` —— `rtl/w3a/axis_snapshot.v:117,225`

**代码**

```verilog
if ((di * 8 + sample_ch_i) < AXIS_N) begin      // :117  越界的片静默丢
...
localparam PARAM_OK = (AXIS_N > 0) && ((N_ADC * 8) >= AXIS_N) && (DW >= (POS_W + 1));   // :225 只查 ≥
```

**机制 / 现状**：`N_ADC=3, AXIS_N=16` ⇒ 片 2 的样本**全部被丢**，无任何告警。
**今天不构成缺陷**（`rtl/top.v:2536` 硬编码 `.N_ADC(2)`，
=1 档的第三片 ADC 走的是颤音控制通路，见 `top.v:1681`），
但模块级参数化允许这种"静默无效"的组合 ⇒ 将来接右手板推子时容易踩。
**修法**：自检加 `(N_ADC * 8 == AXIS_N)` 的 ERROR，或显式打印"片 `N` 的样本被丢弃（按设计）"。
**验证**：例化 `N_ADC=3/AXIS_N=16` 跑 tb，看是否报错。**归类：`[结构]`**。

---

## E. 棘轮 RATCHET —— `rtl/w3a/async_pluck_capture.v`

### [P1] `pluck_up_o` **没有消费者** ⇒ 方向逻辑在 bitstream 里不存在（`Register=39` 恰好证明）—— `rtl/w3a/async_pluck_capture.v:15,48` + `rtl/w3a/play_mode_ctrl.v:20`

**证据链（三重）**
1. **消费者侧**：`rtl/w3a/play_mode_ctrl.v:20` 声明 `input wire pluck_up_i, // direction retained at capture seam`，
   **全文 89 行再无第二次引用**（我通读了整文件）⇒ 方向被丢弃。
2. **生产者侧资源**：`sim/evidence/gowin_m0_rsc.xml:44` = `u_async_pluck_capture Register="39" Lut="56"`。
   逐项账：`up_ff1/up_ff2/down_ff1/down_ff2/up_prev/down_prev` = **6**，
   `refractory_q` = **32**，`pluck_valid_o` = **1** ⇒ **6+32+1 = 39** —— **正好不含 `pluck_up_o`** ⇒ 它被剪掉。
3. **注释侧**：`play_mode_ctrl.v:59-61` 写着 *"Direction has already been resolved by async_pluck_capture (UP priority)"* ——
   与事实相反（方向在硬件里根本不存在）。

**后果**：上拨/下拨在 bitstream 里产生**完全相同**的事件；
而 `tb/w3a/tb_async_pluck_capture.sv:49 event_dir[event_n] = pluck_up;` 在仿真里**逐次检查方向**
⇒ **仿真绿、硬件无此信号**（`K-56` 族）。

**修法（取决于产品意图，二选一，别两头都不做）**
- (a) **方向不该有音乐意义** ⇒ 删掉 `pluck_up_o`（`:15`）、`pluck_up_i`（`play_mode_ctrl.v:20`）
  和 `tb_async_pluck_capture` 里对方向的判据；注释改成"方向被有意忽略（T15 决议）"。
- (b) **方向该有**（例如上拨=正常起音、下拨=mute/滑音）⇒ 在 `play_mode_ctrl` 里真正用它
  （最小实现：`evt_kind_o` 区分，或加一个 `dir_o` 端口给 `note_manager`）。

**验证能红**：在 `tb/top/tb_top_t15.sv` 里分别上拨/下拨，断言产生的事件**不同**（今天必红）。
**归类：`[结构]`**。

---

### [P2] 不应期是**全局单计数器**，且模块默认值与 top 覆盖值**不一致（两个真相）**；顺带给出拨弦速率上限 —— `rtl/w3a/async_pluck_capture.v:8` vs `rtl/top.v:3202`

**代码**

```verilog
// async_pluck_capture.v:8
parameter integer REFRACT_CYC = 2_500_000        // 默认 = 50 ms @50 MHz
// top.v:3199-3202
async_pluck_capture #(
    // 50 MHz 下 1_500_000 周期 = 30 ms；...
    .REFRACT_CYC(1_500_000)                      // 实际 = 30 ms
```

**机制 / 数字**
- **两个真相**：模块默认 50 ms，top 实际 30 ms ⇒ 任何**直接例化该模块的 tb** 测的是 50 ms，
  上板是 30 ms。项目最忌讳这个（`K-124` 族"两个数各自独立"）。
- **速率上限**：指板模式下 `note_on` **只由 pluck 产生**（`play_mode_ctrl.v:59`）⇒
  最短连拨间隔 = 30 ms ⇒ **最高约 33 次/秒**。若将来做震音/轮指（>33 Hz）会被吞。
  另外 `event_extract` 还有 60 帧 = 30 ms 的不应期（`top.v:3137`），
  但它作用在**键位通路**上（与 pluck 是不同触发源），两者不是简单相加。
- 代码里**没有一处**写出这个速率上限。

**修法**：① 把模块默认改成与 top 一致，或删掉默认值强制显式传参（消灭两个真相）；
② 在 `:3-4` 的注释里写明 *"指板模式的最大拨弦速率 = 1 / REFRACT_CYC"*。
**验证**：写一个 tb 以 40 Hz 连拨，数事件数（今天应得 ~33/s，与注释对照）。
**归类：`[结构]`**。

---

### [P3] `pluck_up_o` 在**非 valid 拍保持旧值** ⇒ 接口契约只写在注释里 —— `rtl/w3a/async_pluck_capture.v:43-49`

**机制**：`pluck_valid_o` 每拍默认清 0（`:43`），而 `pluck_up_o` **只在事件那一拍更新**（`:48`）⇒
它保持到下次事件。下游必须"只在 valid=1 时读 up"（`play_mode_ctrl.v:20` 的注释说了这件事，但**没有机械保证**）。
**修法**：`pluck_up_o` 改名 `pluck_dir_o` 并在 `valid=0` 时清 0（更安全），或把契约写进端口注释。
**验证**：加判据"`pluck_valid_o==0` 时 `pluck_up_o` 必须为 0"（采纳清零方案后会红一次，然后常绿）。
**归类：`[结构]`**。

---

## F. 跨模块（不进五模块，但同链路，必须一起看）

### [P1] `play_mode_ctrl` 在指板模式下只维护**一个** gate ⇒ 双指按下后松开第一个键会**永久挂音** —— `rtl/w3a/play_mode_ctrl.v:59-82`

**代码（原样）**

```verilog
end else if (pluck_valid_i && selected_valid) begin
    evt_valid_o <= 1'b1;
    evt_axis_o  <= selected_axis;
    evt_kind_o  <= KIND_PLUCK;
    evt_depth_o <= selected_depth;
    gate_valid  <= 1'b1;
    gate_axis   <= selected_axis;              // 🔴 只有一个 gate
end else if (axis_valid_i) begin
    if (axis_kind_i == KIND_ON) begin
        selected_valid <= 1'b1; selected_axis <= axis_i; selected_depth <= axis_depth_i;
    end else if (axis_kind_i == KIND_OFF) begin
        if (axis_i == selected_axis) selected_valid <= 1'b0;
        if (gate_valid && (axis_i == gate_axis)) begin   // 🔴 只有 gate 轴才发 off
            evt_valid_o <= 1'b1; evt_axis_o <= axis_i; evt_kind_o <= KIND_OFF;
            evt_depth_o <= {DEPTH_W{1'b0}};
            gate_valid  <= 1'b0;
        end
    end
end
```

**机制（逐步）**：按 A（`selected=A`）→ 拨弦（`gate=A`）→ 按 B（`selected=B`）→ 拨弦（`gate=B`）
→ **松开 A**：`axis_i=A ≠ gate_axis=B` ⇒ **不发 `note_off`**，且 `A ≠ selected(B)` ⇒ 也不清 `selected`
⇒ **A 的 voice 永久 held**（= 用户报过的"挂音，几分钟不停"同族）。

**修法**：把 gate 改成**每轴 1 位的掩码**：

```verilog
reg [AXIS_N-1:0] gate_mask;                 // 参数化 AXIS_N（默认 16）
// pluck：gate_mask[selected_axis] <= 1'b1;
// off ：if (gate_mask[axis_i]) begin evt_valid_o<=1; evt_kind_o<=KIND_OFF; gate_mask[axis_i]<=1'b0; end
```
**验证能红**：`tb/w3a/tb_play_mode_ctrl.sv` 加判据 ——
"双键按下 → 拨弦 → 松开第一个键 ⇒ 必须产生该轴的 `note_off`"（**今天必红**）。

**说明**：该模块**不在用户点名的五个里**，但它是 `event_extract` 的**直接消费者**，
且症状与"挂音"同族 ⇒ 单列，别让它溜掉。

**归类：`[结构]`**。

---

## V. 验证侧（变异体 / 判据的盲区）—— 五模块的防线到底守住了什么

### [P1] 变异体 **M88 必然存活**：它打在 `frac ≡ 0` 的**死代码**上，而自称 *"Must be caught"* —— `bringup/mutation_test.ps1:435` + `rtl/w3a/axis_map.v:519,532`

**代码（两边原样对照）**

```powershell
# bringup/mutation_test.ps1:435
@{ id = "M88"; file = "rtl\w3a\axis_map.v"; find = "wire [PHASE_W-1:0] inc_delta = inc_hi - inc_lo;"; repl = "wire [PHASE_W-1:0] inc_delta = {PHASE_W{1'b0}};"; why = "W3a axis_map: the interpolation slope is forced to zero -> dual-press interpolation degrades to 'only the lower key' (glissando silently dies). Must be caught." },
```
```verilog
// rtl/w3a/axis_map.v:519 / :532
wire [FRAC_W-1:0] frac = {FRAC_W{1'b0}};                       // :519  ⭐ 恒 0
wire [PHASE_W+FRAC_W-1:0] interp_raw = inc_delta * frac;       // :532
```

**机制（为什么它必然存活）**
M88 把 `inc_delta` 强制成 0。而 `interp_raw = inc_delta * frac`，`frac` 是**常量 0 线**：
- 原式：`inc_delta × 0 = 0`
- 变异后：`0 × 0 = 0`
⇒ **两者逐位恒等** ⇒ `interp = interp_raw[..] = 0` ⇒ `phase_calc = inc_lo` 两边一样 ⇒
**任何 tb 都不可能区分**。这不是"测试漏保护"，而是**等价变异体**（equivalent mutant）。

**为什么必须处理（不是洁癖）**
① 它自称 *"Must be caught"* ⇒ 变异报告里它要么显示"存活"（= 假防线），要么被脚本算成 FAIL 而**掩盖真问题**；
② 更糟的是它给人"插值被覆盖了"的错觉 —— 与 `axis_map.v:153-181` 里那段
*"删掉钳位不改变行为 ⇒ 那是死代码"* 的教训**同族**（项目已经栽过一次）。

**修法（二选一，按项目自己的口径选后者）**
- (a) 删掉 M88，并在 `mutation_test.ps1` 的注释里记档：
  *"插值当前被有意关闭（`frac ≡ 0`，见 `axis_map.v:519`）⇒ 本变异体无被测对象。"*
- (b) **恢复被测对象**（真修）：给插值一个可测入口，例如
  ```verilog
  parameter integer FRAC_EN = 0;                       // 0 = 关闭（当前交付档）
  wire [FRAC_W-1:0] frac = FRAC_EN ? pos_i[SHIFT-1:0] : {FRAC_W{1'b0}};
  ```
  tb 里用 `#(.FRAC_EN(1))` 例化，测"相邻双压 ⇒ 输出在两端点之间" ⇒ M88 立刻变成**可抓**的变异体。
  依据：`rtl/top.v:3358-3359` 的既定口径 —— *"不能为了接新功能而废掉验收手段"*（T57 的先例）。

**收益 / 代价**：收益 = 让 `axis_map` 的插值重新有判据（阶段 2 滑弦直接受益）；
代价 = (b) 多一个 parameter + 一个 tb 分支，且**必须确认 `FRAC_EN=0` 时综合结果与今天逐位相同**（跑一次 PnR 比对资源表）。

**验证能红**：`bringup/mutation_test.ps1 -Filter M88`（单变异体，几分钟）——
**观察它现在是不是"存活"**；若存活即证明本条。

**归类：`[结构]`**（验证基建，与布局无关）。

---

### [P2] 变异覆盖的不对称：`axis_snapshot` 与 `async_pluck_capture` **一个变异体都没有**；N4 守卫也没有 —— `bringup/mutation_test.ps1:431-444`

**证据**：`Select-String` 全表（705 行）里，`rtl\w3a\` 下的变异体只有
`axis_map`（M88/M89）· `event_extract`（M90-M93）· `param_extract`（M94-M97）——
**`axis_snapshot.v`、`async_pluck_capture.v`、`play_mode_ctrl.v` 零条**；
`top.v` 的 N4 守卫（`:2717-2724`）也**零条**。

**机制 / 后果**：这三个模块恰好是本次查出"bitstream 里不存在 / 方向被丢 / 挂音"的地方 ⇒
**"回归全绿 + 变异测试全绿"对它们没有任何鉴别力**（`K-56`："全绿不证明任何事"）。

**修法（补 4 条最小变异体，每条都要能红）**
1. `axis_snapshot.v:193` `snap_valid_o <= frame_done_i;` → `<= 1'b0;`（快照消失 ⇒ 事件层全停）。
2. `axis_snapshot.v:119` `seen[di*8 + sample_ch_i] <= 1'b1;` → `<= 1'b0;`（诊断失效；**需先有"帧内清零"的判据才抓得住**，见 D 的 P1 条）。
3. `async_pluck_capture.v:48` `pluck_up_o <= up_rise;` → `<= 1'b0;`（方向恒定 ⇒ **只有 (b) 修法之后才抓得住**）。
4. `top.v:2718` `32'd12 * TRAVEL_TARE` → `32'd30 * TRAVEL_TARE`（放宽上界）+ 一组越界参数
   ⇒ 守 N4（**注意**：要先解决 A 的 P1 条"$fatal 是否真能拦综合"）。
**收益**：把"看不见的失效模式"变成有判据的失效模式。**代价**：每次变异测试 +~10 分钟（4 条）。
**验证**：每条都先跑**未修**代码确认它**不红**（证明是盲区），修完再确认它红（证明有鉴别力）。

**归类：`[结构]`**。

---

## G. 已检查、**无发现**的项（如实记录，避免"泛泛而谈"）

| 检查项 | 结论（带证据） |
|---|---|
| 16 轴 × 阈值是不是"每轴一套常量比较器" | **不是**。串行扫描 ⇒ **1 套比较器 + 16:1 输入 mux**；阈值是编译期常量 ⇒ `pos>=64` 折成 6 位 OR ≈ 2 LUT4。唯一可议是"mux 在前"（见 A 的 P2 条）。 |
| 高扇出（尤其跨 32 voice） | **五模块内没有任何信号扇出到 32 voice**（那是 `note_manager`/`oscillator_bank` 的地盘）。最宽的是 `as_valid`：→ `event_extract`（16 `refr` + 16 `key_on` + FSM）＋ `param_extract`（5×16 数组 + FSM）≈ **115 个使能负载**（`[布局]` 敏感，但不构成缺陷）。 |
| 宽 mux 层级 | 唯一的宽 mux 是 **16:1**（2 级 LUT4）；没有 32:1/64:1；`axis_map` 的 32 位表 mux 落在 LUT-INIT 里（见 C 的 P2 条）。 |
| 有符号 / 无符号、扩位截断 | `delta` 的扩位写法**正确**：`{1'b0,cur[gi]} - {1'b0,prev[gi]}`（`axis_snapshot.v:211-212`）；`VEL_T1_EFF` 的乘除**不截断**（`VEL_T1_PCT` 是 `integer` ⇒ 32 位运算，`744*50/100=372` 精确）；`refr - 16'd1` 无符号减法**正确**。 |
| 比较器边界 `<=` vs `<` | `>= TRIG_TH` / `< REL_TH`（迟滞方向正确）；`dt >= DT_MAX` / `dt <= DT_MIN` 与 `vel_lut` 内部的 `>= / <=` **一致**（冗余但不错）；`q_cnt < FIFO_D` 的"满"语义正确。 |
| FSM 未覆盖状态 / default | `event_extract`/`param_extract` 都是"计数器 + 2 个状态位"，`scan_axis` 只有 `0..AXIS_N-1` 的合法值（`scanning` 门控）⇒ **无未覆盖状态**。`play_mode_ctrl` 用 `if/else if` 链而非 `case`，无 `default` 需求。 |
| generate 分支覆盖 | `axis_snapshot` 的 `gen_out` 逐轴展开、`event_extract` 无 generate ⇒ 无"某参数下永不生效"的分支。 |
| 复位 | 五模块**全是同步复位、低有效**，复位覆盖**每一个寄存器**（含 `refr` 高位、`seen`）；**没有异步复位** ⇒ 不存在"复位域不同步"。唯一缺的是 `seen` 的**帧内**清零（D 的 P1 条）。 |
| 上电 X 传播 | `axis_map`/`param_extract` 的常量表用 `initial` 赋初值（落 LUT-INIT，见 C 的 P2 条）；其余寄存器都有复位 ⇒ **未发现 X 传播路径**。`param_extract` 的 `frame_cnt` 复位 0 与合法值同值（B 的 P3 条，非缺陷）。 |
| 推断出 latch | **没有**。所有组合输出都是连续赋值或完整 `if/else`；`event_extract` 的 `q_push_now` 是 `reg` 但在 always 首行清 0（阻塞）⇒ 综合成线网，**不产生 FF/latch**。 |
| DSP / 乘法器 | 五模块**没有 DSP**：`axis_map` 的 `inc_delta * frac` 因 `frac ≡ 0` 被剪；`param_extract` 的 `span*...` 只在 `initial`。资源表里 `u_axis_map`/`u_event_extract` 的 DSP 列都是 `-`。 |
| 分布式 RAM / BSRAM | **没有**。`Extracting RAM` 提示存在（`refr`/`kb_inc`/`fb_inc`/`t1_*`/`vel_lut`），但**全设计 SSRAM/ROM16 列全为 `-`** ⇒ 最终落回 FF/LUT-INIT。 |
| 悬空端口 Z | 五个文件**都**声明了 `` `default_nettype none ``（`event_extract.v:41` / `param_extract.v:31` / `axis_map.v:30` / `axis_snapshot.v:39` / `async_pluck_capture.v:5`）并在文件末恢复 `` `default_nettype wire `` ⇒ **不会出现隐式线网**。 |
| 跨时钟域 | 五模块**只有一个时钟** `clk_sys`。唯一异步输入是 `async_pluck_capture` 的两路 LM393：**2 级同步器 + 1 级边沿延迟**（`:36-41`），事件延迟 = 3 拍 = 60 ns 确定；**未发现亚稳态/窄脉冲缺陷**（LM393 是慢速比较器，µs 级边沿，不会窄于 20 ns）。 |
| 毛刺敏感路径 | `axis_map.phase_inc_o`（组合，LUT-INIT 查表 + mux）与 `axis_snapshot.pos_o/delta_o`（组合）都由 **FF 输出**驱动地址/数据，下游 `am_inc_out`/`event_extract` 在时钟沿/`snap_valid` 后 16 拍采样 ⇒ 建立时间窗口内稳定。**未发现真实的毛刺敏感缺陷**。 |
| 重复逻辑 / 可共享 | 五模块内没有可再共享的加法器/比较器（`event_extract` 的两条比较已共用同一个 16:1 mux）；`refr` 的 16 个减法器**不可共享**（要同拍递减 16 轴）。 |

---

## H. 优先级总览（按"能不能立刻动手"排）

| 优先 | 编号 | 一句话 | 位置 | 分类 |
|---|---|---|---|---|
| **P0** | A-1 | N4 守卫 `TRAVEL_TARE==0` 整条被绕过（0/0 放行）+ 消息除零 ⇒ 16 音齐响永不释放 | `top.v:2717-2724` | 结构 |
| P1 | A-2 | 模块自检 / N4 `$fatal` 在综合里被忽略（EX3858）⇒ 第一道门拦不住参数错 | `event_extract.v:437` 等 | 结构 |
| P1 | A-3 | ON 分支 push 失败仍置 `key_on` ⇒ `note_on` 永久丢失（OFF 已修、ON 没修） | `event_extract.v:304` | 结构 |
| P1 | A-4 | FIFO 深度 4 不可达（`q_cnt ≤ 1`）⇒ 溢出守卫/丢失计数全死 + 无消费者 | `event_extract.v:163,307,313` | 结构 |
| P1 | A-5 | `refr` 16 位装 6 位值 ⇒ 最多 −160 FF / −100 LUT / 锥深 −4 级 | `event_extract.v:131` | 结构 |
| P1 | B-1 | `param_extract` **整模块被扫掉**；`top.v:4092` 注释与代码相反 | `top.v:3335/4092` | 结构 |
| P1 | B-2 | `VEL_T1_EFF` 是装饰品 ⇒ 测速跨度是设计意图的 **2.38×** ⇒ 慢按全撞地板 | `param_extract.v:110,251` | 结构 |
| P1 | C-1 | 表项填 0 无守卫 + `phase_safe` 把它变成"占 voice 的 DC 音" | `axis_map.v:543,561` | 结构 |
| P1 | C-2 | `pos_i`/插值链全死 ⇒ "两层表"只有一层，`pos_i` 完全没用 | `axis_map.v:113,183,519` | 结构 |
| P1 | D-1 | `axis_snapshot` 的 delta 通路在 bitstream **不存在**（REG=193 即证） | `axis_snapshot.v:76,211` | 结构 |
| P1 | D-2 | `axis_seen_o` 从不清零 ⇒ 诊断信号永久饱和（端口注释错） | `axis_snapshot.v:119,216` | 结构 |
| P1 | E-1 | `pluck_up_o` 无消费者（REG=39 即证）⇒ 方向逻辑在硬件里不存在 | `async_pluck_capture.v:15` | 结构 |
| P1 | F-1 | `play_mode_ctrl` 单 gate ⇒ 双指后松第一个键**永久挂音** | `play_mode_ctrl.v:59-82` | 结构 |
| P1 | V-1 | 变异体 **M88 必然存活**（打在 `frac≡0` 的死代码上）⇒ 假防线 | `mutation_test.ps1:435` | 结构 |
| P2 | V-2 | `axis_snapshot`/`async_pluck_capture`/N4 守卫 **零变异体** ⇒ 无鉴别力 | `mutation_test.ps1:431-444` | 结构 |
| P2 | A-6 | 扫描锥"先 mux 后比较" ~12 级 ⇒ 改"先比较后 mux" ~5 级（+10 LUT） | `event_extract.v:302,320` | 结构 |
| P2 | A-7 | `scan_axis` 硬编码 `4'd1` ⇒ `AXIS_N>16` 静默错 | `event_extract.v:351` | 结构 |
| P2 | A-8 | 同帧原子性靠"样本间隔 > 16 拍"这条没写下的不变式（今天 195× 余量） | `event_extract.v:290` | 结构 |
| P2 | A-9 | `enable_i` 的"悬空=使能"只在仿真成立；综合里悬空=0 ⇒ 永久静音 | `event_extract.v:278` | 结构 |
| P2 | B-3 | `Δt` 下溢钳位与物理相反：回绕把"最慢按"变"最响按"（0.15%/次） | `param_extract.v:275` | 结构 |
| P2 | B-4 | `LUT_N=66` 非 2 的幂 ⇒ 索引多一级钳位 | `param_extract.v:177` | 结构 |
| P2 | C-4 | 常量表落地方式：`Extracting RAM` 提示但 SSRAM=0（**不是**分布式 RAM） | `axis_map.v:226` | 结构 |
| P2 | D-3 | 帧 1 的 delta = `cur − 0`（语义无效）且无判据 | `axis_snapshot.v:110,148` | 结构 |
| P2 | D-4 | 握手隐含假设"`frame_done` 与最后样本同拍"，无检查 | `axis_snapshot.v:188` | 结构 |
| P2 | E-2 | `REFRACT_CYC` 默认 50 ms vs top 30 ms（两个真相）+ 拨弦速率上限 33/s 没写 | `async_pluck_capture.v:8` | 结构 |
| P3 | A-10 | `FIFO_D[FW:0]`（integer 位选）与 `axis_map.v:94-99` 的禁令冲突 | `event_extract.v:307` | 结构 |
| P3 | B-5 | `dt_valid` 同一 always 两处写（同款模式，今天不可达） | `param_extract.v:280,324` | 结构 |
| P3 | B-6 | tb 里时基仍写 196 µs（K-128 只修了 RTL） | `tb_param_extract.sv:300` | 结构 |
| P3 | B-7 | `t1_stamp` 复位值与合法值同值（无"未初始化"标记） | `param_extract.v:220` | 结构 |
| P3 | C-5 | `phase_valid_o = pos_valid_i` 命名误导（建议 `upd_valid_i`） | `axis_map.v:548` | 结构 |
| P3 | D-5 | `N_ADC*8 > AXIS_N` 时多出的片静默丢，自检只查 `≥` | `axis_snapshot.v:117,225` | 结构 |
| P3 | E-3 | `pluck_up_o` 非 valid 拍保持旧值（契约只在注释里） | `async_pluck_capture.v:43` | 结构 |

V-1 排在 P1 是**验证侧**的账：M88 打在 `frac ≡ 0` 的死代码上（`axis_map.v:519`），
`repl` 让 `inc_delta = 0`，而 `interp_raw = inc_delta * frac = 0 * 0` 与原式**恒等**
⇒ **任何 tb 都无法区分** ⇒ 该变异体**必然存活**，但它自称 *"Must be caught"*。
按项目自己的口径（`top.v:3358-3359`"不能为了接新功能而废掉验收手段"），
要么删掉 M88 并记档"插值当前被有意关闭、无被测对象"，要么**给 `frac` 一个可测入口**
（例如 `parameter FRAC_EN`，tb 里打开再测插值）—— 后者才是真修（恢复被测对象）。

---

## I. 落地纪律（改这个仓库必须过的四道门 + 两条连带）

1. **改 RTL 必过四道门**：综合 ERROR=0 → 聚焦 tb → 干净 PnR **0/0 且无 PR0004** → 全量回归
   （判据 = `sim/tb_all.ps1` 打印的"通过 N / 共 N"，**N 必须相等**，⛔ 不要写死数字）。
2. **改 `refr` 位宽 ⇒ 必须同步改 `bringup/mutation_test.ps1:437-438` 的 M90/M91 find 串**，
   否则 SKIP ⇒ 脚本判 FAIL（`K-87`/`K-125`）。
3. **删 `Δt` 钳位 ⇒ 必须同步改** `tb/w3a/tb_param_extract.sv:298-335`（判据 ⑤b 的期望值反过来）
   **和** `mutation_test.ps1:443` 的 M96 锚点。
4. 本次**没有改任何 RTL**（纯审查）；若采纳 A-5/A-3，建议**一次只改一条**并单独跑四道门，
   别把"省 FF"和"修逻辑"混在一次 PnR 里 —— 否则 Fmax 那 ±2~3 MHz 的布局噪声会盖掉归因。
5. 历史坑提醒（用户点名的）：`tb/models/oscillator_bank_ref.v` 是 P5-② 的基线副本，
   **本次五模块与 `oscillator_bank` 无关**，所以**不需要**动它；但若后续顺手改了 `oscillator_bank`，
   必须同步那个副本，否则 `tb_p5_osc_equiv` 逐位等价会假红。
