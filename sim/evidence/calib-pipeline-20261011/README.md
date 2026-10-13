# `calib` 输入流水化：**已证明有效，但本轮回退**（2026-10-11）

> ⭐ 这是本项目第一次**先量到关键路径、再动手、再用判据验收**的时序优化 ✅
> ⭐ **优化本身是成功的** —— ⚠️ 但**收尾没做完** ⇒ ⭐ **按纪律回退**（⛔ 绝不把红的仓库留下）✅

---

## 一、⭐ 预注册的判据（⭐ 动手【之前】就定）

| # | ⭐ 判据 | ⭐ 来源 |
|---|---|---|
| 1 | ⭐ 7 个 `calib*` tb **全绿** | ⭐ 项目纪律 ✅ |
| 2 | ⭐ **PnR 最差 setup slack 改善 ≥ 0.3 ns** | ⭐ 同 `P2-37` 的判据形式 ✅ |

---

## 二、⭐ 改了什么（⭐ 一句话）

⭐ 在 `calib.sv` 的**输入端打一拍**（`raw`/`ch`/`valid` → `raw_d`/`ch_d`/`valid_d`）✅，
⭐ 并让**三个表读**（`zero_rd`/`span_rd`/`gain_rd`）改用 `ch_d` 索引 ✅。

### ⭐ 为什么这样能省（⭐ 根因）

```
report_timing -setup -max_paths 25  ⇒  ⭐ 前 25 条【全部】是
   g_sound.u_adc_farm/u_scan0/sample_channel_*/Q  →  g_sound.u_calib{0,1}/n909_s/A[*]
   ⭐ 最差：slack 0.691 ns · 数据延迟 17.800 ns（⭐ 逻辑 13.855 ns ＋ 走线 ≈3.9 ns）

交付档 RAW_MEDIAN_EN = 0 ⇒ 本模块的组合路 =
   raw → 三个表读（由 ch 组合索引）→ 减 → 两级比较 → 钳位 → 乘法器输入

🔴 根因：raw/ch 来自【物理上很远】的 adc_farm，而 ch 的组合扇出【横跨全芯片】
   ⇒ 那三块表 RAM 被迫放在离 adc_farm 很远的地方
   ⇒ 逻辑延迟里混进了大量【走线代价】
```

---

## 三、⭐⭐ 实测结果：**判据 2 达成** ✅

| ⭐ 项 | ⭐ 流水化前 | ✅ 流水化后 |
|---|---|---|
| ⭐ `Actual Fmax` | ⭐ 56.206 MHz | ⭐ **57.669 MHz**（⭐ **+1.46 MHz** ✅） |
| ⭐ 周期 | ⭐ 17.792 ns | ⭐ **17.340 ns**（⭐ **+0.452 ns** ✅） |
| ⭐ **最差 setup 路径** | 🔴 **`adc_farm/u_scan0/sample_channel_2_s0/Q` → `u_calib0/n909_s/A[*]`**（⭐ slack **0.008 ns** 🔴） | ✅ **换人了** —— ⭐ `u_note_manager/src_r[30]_0_s0/Q` → `scan_cnt_*/CE`（⭐ slack **0.460 ns** ✅） |
| ⭐ 原路径 | ⭐ 前 25 条**全是**它 | ✅ ⭐ **掉出前 6**（⭐ 即 slack > 1.044 ns ✅） |

⇒ ⭐ **`adc_farm → calib` 这条路的 slack 改善 ≥ 0.6 ns** ✅✅
⇒ ⭐ **判据 2（≥0.3 ns）【达成】** ✅
⇒ ⭐ 而且**瓶颈换了地方** —— ⭐ 现在最差的是 **`note_manager`**（⭐ 0.460 ns ✅）

📌 ⭐ **这是本轮最有价值的产出**：⭐ **一个可复现的时序优化配方** ✅

---

## 四、⚠️ 为什么还是回退了（⭐ 判据 1 没达成）

⭐ **`tb_calib` 修好了**（⭐ 单点修法：⭐ 在它的 `feed` 任务末尾**多等一拍** ⇒
⭐ 所有调用点自动对齐 ✅ ⇒ 14/14 绿 ✅）

🔴 **但另两个 tb 不只是"延迟错位"**：

| ⭐ tb | ⭐ 失败 | ⭐ 根因 |
|---|---|---|
| ⭐ `tb_calib_span_err` | ⭐ 5 条（⭐ 含 `wait_reject_pulse timed out`） | ⚠️ 见下 ✅ |
| ⭐ `tb_calib_still_guard` | ⭐ 4 条（⭐ 全是 `out = raw - zero` 类） | ⚠️ 见下 ✅ |

### 🔴 根因：⭐ **`tare`/`span` 与 `raw` **同拍**驱动 ⇒ 输入寄存器让它捕获到【上一拍】的样本**

⭐ 真硬件里 `raw` 是**连续流**（⭐ 每拍都在更新 ✅）⇒ ⚠️ `tare` 捕获"上一拍"**完全无害** ✅
🔴 而 tb 是"**设 `raw` ⇒ 同拍发 `tare`**"的写法 ⇒ ⭐ 现在会捕获到**旧的 `raw`** ✅
⇒ ⭐ **这是 tb 级的时序写法问题，⛔ 不是 RTL 的功能缺陷** ✅
✅ **修法**：⭐ 在这两个 tb 里**把 `raw` 的驱动提前一拍**（⭐ 相对 `tare`/`span` 脉冲 ✅）

### ⭐ 为什么本轮没做完（⭐ 诚实记录）

⭐ 本轮预算已接近上限 ⇒ ⚠️ 再改两个 tb（⭐ 各需 2~4 处驱动时序调整 ＋ 各跑一次 ✅）
⭐ **有把握做完的风险偏高** ✅
🔴 而项目纪律是 **⛔ 绝不把红的仓库留下** ✅
⇒ ⭐ **处置：⭐ 回退 RTL 与 `tb_calib`，⭐ 把这个配方完整记录** ✅

✅ **回退后验证**：⭐ `通过 7 / 共 7`（⭐ 7 个 `calib*` tb 全绿 ✅）· ⭐ 工作区干净 ✅

---

## 五、✅ 下一轮的配方（⭐ 照做即可）

```text
1. rtl/drivers/calib.sv：
   a) 在【表读之前】声明并实现输入寄存器：
        reg valid_d; reg [CW-1:0] ch_d; reg [DW-1:0] raw_d;
        always @(posedge clk) begin valid_d <= valid; ch_d <= ch; raw_d <= raw; end
      ⚠️ 必须在表读之前 —— 否则 Unable to bind（Verilog 的 reg 不能前向引用）
   b) zero_rd/gain_rd/span_rd 的索引 ch → ch_d
   c) g_raw_plain 的 raw_f = raw → raw_d；g_raw_median 内的 raw/ch → raw_d/ch_d
   d) v_r <= valid_d; ch_r <= ch_d;   if (valid_d) prod_r <= dclamp * gain_rd;

2. tb/drivers/tb_calib.sv：feed 任务末尾多一个 @(negedge clk)；
   并把 P2-24 的判据等待从 2 拍改成 3 拍

3. tb/w3a/tb_calib_span_err.sv + tb/w3a/tb_calib_still_guard.sv：
   把 raw 的驱动【提前一拍】（相对 tare/span 脉冲）
   📌 判据：改完两个 tb 必须全绿

4. 验收：7 个 calib* tb 全绿 ＋ 全量回归 137/137 ＋
   PnR 最差 slack 改善 ≥ 0.3 ns（⭐ 上次实测 ≥0.6 ns ✅）＋ 6 道门全 OK
```

---

## 六、⭐ 第 2 次尝试（⭐ 2026-10-11 同一轮内）：⭐ **配方升级 —— 打拍要打在【两者之前】**

### ⭐ 做到了什么

⭐ 按 §五 的配方重做了一遍 ✅：

| ⭐ tb | ⭐ 结果 |
|---|---|
| ⭐ `tb_calib` | ✅ **绿**（⭐ 单点修法：⭐ `feed` 末尾多等一拍 ⇒ 14/14 ✅） |
| ⭐ `tb_calib_still_guard` | ✅ **绿**（⭐ 同一个单点修法：⭐ `feed_c` 末尾多等一拍 ⇒ **19/0** ✅） |
| 🔴 `tb_calib_span_err` | 🔴 **5 条红**（⭐ 含 ⚠️ **`wait_reject_pulse timed out`** ✅） |

⇒ ⭐ **单点修法确实有效**（⭐ 两个 tb 各一处就够 ✅）—— ⭐ 配方里那部分是**对的** ✅

### 🔴🔴 但 `tb_calib_span_err` 暴露了**更深的问题**

⚠️ 它不只是"延迟错位" —— ⭐ 有一个 **timeout** ⇒ ⭐ **`reject_o` 根本没出现** 🔴 ✅

🔴 **根因：⭐ `calib_span` 与 `calib` 之间出现了【1 拍错位】** ✅

```
calib_span  ⭐ 决定"⭐ 此刻该 tare"（⭐ 它看的是【当前】raw ✅）
calib       ⭐ 捕获零点（⭐ 现在看的是【上一拍】的 raw_d 🔴）
⇒ ⭐ 两个模块**看的是不同的采样** ✅
⇒ ⭐ 于是"⭐ span 判定的那个样本"与"⭐ calib 记下的零点"**对不上** 🔴
⇒ ⭐ tb 里就表现为 `reject_o` 不出现 / `out` 差一拍 ✅
```

📌 ⭐ **真硬件下这条错位只有 20 ns**（⭐ 相对 20.48 µs 的采样帧可忽略 ✅），
⚠️ **但它确实是一个语义变化** —— ⭐ 两个模块本该看**同一份数据** ✅

### ✅ **正确的设计（⭐ 配方 v2）**

🔴 **打拍要打在【`calib` 与 `calib_span` 两者之前】** ✅
⇒ ⭐ 即在**顶层**（⭐ `adc_farm` 的输出之后、⭐ 分给两个模块之前）打一拍 ✅
⇒ ⭐ 这样：
- ⭐ 两者看**同一份**延迟后的数据 ⇒ ⭐ **对齐保持** ✅
- ⭐ `adc_farm → calib` 的长路**照样被切断** ⇒ ⭐ 时序收益**不变** ✅

```text
现在（配方 v1，⛔ 不要用）：
   adc_farm ──┬──► calib      （⭐ 内部打拍 ⇒ ⭐ 与 span 错位 🔴）
              └──► calib_span

配方 v2（✅ 正确）：
   adc_farm ──► 【顶层打一拍】 ──┬──► calib      （⭐ 两者同源 ⇒ ⭐ 对齐 ✅）
                                 └──► calib_span
```

### ⚠️ ⭐ 为什么本轮没做 v2

⭐ 它要动 `top.v` 的 `adc_farm` 扇出（⭐ 两处实例 ＋ 中间信号 ✅），
⭐ 而且 `calib_span` 的**扫描速率/稳定性判定**与采样时序相关 ⇒ ⚠️ 需要**重新核对**它的 tb ✅
⇒ ⭐ 已超出本轮预算 ⇒ ⭐ **按纪律回退**（⛔ 绝不把红的仓库留下）✅

### ✅ 回退后的验证

⭐ `通过 7 / 共 7`（⭐ 7 个 `calib*` tb 全绿 ✅）· ⭐ 工作区干净 ✅

---

## 七、⭐ 结论（⭐ 两轮合起来）

| ⭐ 项 | ⭐ 结论 |
|---|---|
| ⭐ **优化有效吗** | ✅ **有效** —— ⭐ 实测 `Fmax +1.46 MHz`、⭐ 原关键路径**掉出前 6**（⭐ 改善 **≥0.6 ns** ✅） |
| ⭐ **配方对吗** | ⚠️ **v1 只对了一半** —— ⭐ "输入打一拍"能省时序 ✅，⭐ 但**位置错了**（⭐ 应打在两个模块**之前** ✅） |
| ⭐ **下一步** | ⭐ 按 **v2** 在顶层打拍 ＋ ⭐ 重核 `calib_span` 的 tb ✅ |
| ⭐ **新瓶颈** | ⭐ `note_manager`（⭐ `src_r[30] → scan_cnt_*/CE`，⭐ 0.460 ns ✅）—— ⭐ 做完 v2 就该看它 ✅ |


## 八、⭐⭐ 第 3 次尝试：**v2 落地成功**（⭐ 2026-10-11 ✅）

### ✅ v2 的做法（⭐ 与 v1 的唯一区别 = **打拍的位置**）

```verilog
// top.v —— ⭐ 在【整簇之前】打一拍（⭐ 紧跟在 af0_pol/af1_pol 之后 ✅）
reg         af_sample_valid_d;
reg  [2:0]  af_sample_ch_d;
reg  [11:0] af0_pol_d;
reg  [11:0] af1_pol_d;
always @(posedge clk) begin
    af_sample_valid_d <= af_sample_valid;
    af_sample_ch_d    <= af_sample_ch;
    af0_pol_d         <= af0_pol;
    af1_pol_d         <= af1_pol;
end
```

⭐ 然后把这 **4 个信号**换成 `_d` 那份，喂给 **calib 簇的 4 个模块** ✅：

| ⭐ 模块 | ⭐ 改的端口 |
|---|---|
| ⭐ `u_autotare` | ⭐ `.sample_valid_i` / `.sample_ch_i` ✅ |
| ⭐ `u_calib_span` | ⭐ `.sample_valid_i` / `.sample_ch_i` ✅（＋ ⭐ `sp_raw_sel` 改用 `af*_pol_d` ✅） |
| ⭐ `u_calib0` | ⭐ `.valid` / `.ch` / `.raw`（⭐ `af0_pol_d` ✅） |
| ⭐ `u_calib1` | ⭐ `.valid` / `.ch` / `.raw`（⭐ `af1_pol_d` ✅） |

⛔ **刻意【不动】的**：⭐ `u_right_analog_ctrl`（⭐ 模拟前端的时序控制 ✅）
＋ ⭐ `u_adc_farm`（⭐ 生产者 ✅）
⇒ ⭐ **只延迟"标定簇"，⛔ 不碰"按键检测/模拟控制"那两路** ✅

### ✅✅ 结果：⭐ **7 个 `calib*` tb 全绿，而且⛔ 一个 tb 都没改**

```text
PASS: calib T13 all 14 checks ok
PASS: calib_autotare ...
PASS: calib_cmd ...
PASS: calib_span ...
PASS: span err handling ...          ← ⭐ v1 下这里是 5 条红 ✅
PASS: still-guard / clk-timeout / 'T'-guard / water-mark / no-direct-read
PASS: a serial 'S' really starts ... ← ⭐ 顶层 tb ✅
通过 7 / 共 7
```

⭐ **这正是 v2 相对 v1 的最大好处**：
- ⭐ v1（模块内部打拍）⇒ 🔴 要改 **3 个 tb**，⭐ 而且**改不干净**（⭐ 模块间错位 ✅）
- ✅ v2（顶层打拍）⇒ ⭐ **零 tb 改动** ✅ —— ⭐ 因为**模块级契约没变**（⭐ `calib.sv` 一行没动 ✅）
  ＋ ⭐ 簇内**同源** ⇒ ⭐ 对齐保持 ✅

### ⭐ 三次尝试的对比（⭐ 值得记）

| ⭐ 次 | ⭐ 打拍位置 | ⭐ tb 结果 | ⭐ 结论 |
|---|---|---|---|
| 1 | ⭐ `calib` 内部（表读前） | 🔴 `tb_calib` 等 4 个红 | ⭐ 判据 2 达成 ✅ 但判据 1 不达成 |
| 2 | ⭐ 同上 ＋ 改 2 个 tb | ⚠️ 5/7（⭐ `span_err` 的 `reject_o` 不出现） | ⭐ 发现**模块间 1 拍错位** 🔴 |
| ✅ **3** | ✅ **顶层、整簇之前** | ✅ **7/7，零 tb 改动** | ✅ **正确** ✅ |

📌 ⭐ **一句话教训**：⭐ **"打拍要打在【共享这份数据的全部消费者】之前"** ——
⭐ 打在某个消费者内部 ⇒ ⭐ **它和别的消费者就错开了** ✅

### 🔴⚠️ ⭐ 第 4 次：**声明顺序**（⭐ 同一个坑，第 2 次踩 ✅）

⭐ v2 的接线写完后，⭐ `-Filter calib` **7/7 全绿** ✅ —— ⚠️ **但那 7 个是【模块级】tb**
（⭐ 它们**不例化 `top`** ⇒ ⭐ **根本没编译 `top.v`** 🔴）

🔴 **而全量回归暴露了**：⭐ **19 个顶层 tb 编译失败** ✅

```text
rtl/top.v:2399: error: Unable to bind wire/reg/memory `af_sample_valid_d'
rtl/top.v:2399: error: Failed to elaborate input port 'sample_valid_i' expression
```

🔴 **根因**：⭐ 我把 4 个 `reg` 都声明在 `:2530`（⭐ `af0_pol` 之后 ✅），
⭐ 而 **`u_autotare` 在 `:2399`**（⭐ **更早** ✅）
⇒ ⭐ **Verilog 的 `reg` 不能前向引用** ✅
📌 ⭐ **这已经是同一个坑的第 2 次**（⭐ 第 1 次在 `calib.sv` 内部 ✅）
⇒ ⭐ **教训固化**：⭐ **`reg` 必须声明在【最早的消费者】之前**；
⭐ 若两个 `reg` 依赖的源信号先后不同 ⇒ ⭐ **拆成两段声明** ✅

✅ **修法**：⭐ 拆成两段 ✅
- ⭐ `af_sample_valid_d`/`af_sample_ch_d` ⇒ ⭐ 紧跟 `af_sample_valid`/`af_sample_ch`（⭐ `:2055` ✅）
- ⭐ `af0_pol_d`/`af1_pol_d` ⇒ ⭐ 紧跟 `af0_pol`/`af1_pol`（⭐ `:2489` ✅）

📌 ⭐ **还有一条更重要的教训**：⭐ **"模块级 tb 全绿" ⛔ 不等于"顶层能编译"** ✅
⇒ ⭐ **改 `top.v` 之后，必须跑一个【顶层】tb（或全量回归）** ✅
（⭐ 本轮幸好跑了全量 ✅）

### 🔴🔴 但 v2 的**判据未达成** ⇒ ⭐ **按预注册判据回退** ✅

⭐ 修好声明顺序后重跑：

| ⭐ 项 | ⭐ 结果 |
|---|---|
| ⭐ 全量回归 | ✅ **通过 137 / 共 137** ✅ |
| ⭐ PnR | ✅ `0 setup / 0 hold` · ⭐ `buildExit=0` ✅ |
| ⭐ `Actual Fmax` | 🔴 **56.205 MHz**（⭐ v2 前是 **56.206** ⇒ ⭐ **一模一样** 🔴） |
| ⭐ **最差 setup 路径** | 🔴 **仍是 `→ u_calib0/n909_s/A[*]`**（⭐ slack **0.008 ns** 🔴）<br>⭐ 只是**源换成了我新加的那个寄存器**：⭐ `g_sound.af_sample_ch_d_2_s0/Q` ✅ |

⇒ ⭐ **判据 ②（≥0.3 ns）【未达成】** ⇒ ⭐ **回退** ✅

### ⭐⭐ 诊断（⭐ 这一条比结论本身有用）

🔴 **v2 的寄存器在【顶层】** ⇒ ⚠️ 它的输出**还要跨芯片走线**到 `calib`
⇒ 🔴 **走线代价原封不动** ✅

⭐ 而 **v1 的寄存器在【`calib` 内部】**（⭐ 紧邻表读 ✅）
⇒ ✅ **v1 实测把这条路径【整个消掉了】**（⭐ 最差变成 `note_manager` 的 0.460 ns ✅）

⇒ ⭐⭐ **结论：⭐ 寄存器必须【紧邻表读】（⭐ 即模块内 ✅），⭐ 否则省的只是逻辑、省的走线又加回来了** ✅

### ✅ 于是配方升级为 **v3**（⭐ 下一步）

```text
v3 = v1 的位置（⭐ 每个模块【内部】打一拍 ⇒ ⭐ 紧邻表读 ✅）
   ＋ v2 的思想（⭐ 簇内【每个】模块都打一拍 ⇒ ⭐ 对齐保持 ✅）
```

| ⭐ 模块 | ⭐ v3 要做的 |
|---|---|
| ⭐ `calib.sv` | ⭐ 输入打一拍（⭐ = v1 的改动 ✅，⭐ 已知可行 ✅） |
| ⭐ `calib_span.v` | ⭐ **同样**在输入打一拍（⭐ 新增 ⇒ ⭐ 保持与 `calib` 对齐 ✅） |
| ⭐ `calib_autotare`（⭐ 若它也参与同一判定链） | ⭐ 同样处理 ✅ |
| ⭐ 三个模块级 tb | ⭐ 各自 `feed` 末尾多等一拍（⭐ v1 已证明这是**单点修法** ✅） |

📌 ⭐ **判据（⭐ 预注册）**：⭐ ① 全量回归 **通过数 == 共数** ✅
＋ ⭐ ② PnR 最差 setup slack **改善 ≥ 0.3 ns**（⭐ v1 的**位置**实测改善 ≥0.6 ns ✅）
＋ ⭐ ③ 6 道门全 OK ✅
📌 ⭐ **v1 已经证明了"位置对"能带来 ≥0.6 ns** ⇒ ⭐ v3 只需补上"对齐"那一步 ✅

### ⭐ 四次尝试的完整对比（⭐ 值得留档）

| ⭐ 次 | ⭐ 打拍位置 | ⭐ 回归 | ⭐ PnR 最差路径 | ⭐ 结论 |
|---|---|---|---|---|
| 0 | ⭐ 无 | ⭐ 137/137 | 🔴 `adc_farm/Q → calib/A`（⭐ 0.008 ns） | ⭐ 基线 ✅ |
| 1 | ⭐ `calib` **内部** | 🔴 4 个 tb 红 | ✅ **`note_manager`**（⭐ 0.460 ns ✅ 改善 ≥0.6 ns） | ⭐ **位置对** ✅ 但**簇内错位** 🔴 |
| 2 | ⭐ 同 1 ＋ 改 2 个 tb | ⚠️ 5/7 | — | ⭐ 确认**错位**是根因 ✅ |
| ✅ **3（v2）** | ⭐ **顶层**（⭐ 簇前） | ✅ 137/137 | 🔴 **`af_sample_ch_d/Q → calib/A`**（⭐ 0.008 ns） | ⭐ **对齐对了** ✅ 但**位置错了** 🔴 |
| ⭐ **4（v3）** | ⭐ **每个模块内部** | ⭐ 待做 | ⭐ 期望 ⭐ 两者兼得 ✅ | ⭐ **下一步** ✅ |




## 九、⭐ 附：新的瓶颈是 `note_manager`

⭐ **v1 的实测**（⭐ 唯一一次时序真的改善的配置 ✅）：⭐ 最差路径变成：

```
slack 0.460  g_sound.u_note_manager/src_r[30]_0_s0/Q  →  g_sound.u_note_manager/scan_cnt_1_s0/CE
slack 0.510  g_sound.u_note_manager/src_r[30]_0_s0/Q  →  g_sound.u_note_manager/scan_cnt_0_s3/D
slack 0.641  g_sound.u_note_manager/src_r[30]_0_s0/Q  →  g_sound.u_note_manager/scan_cnt_3_s0/CE
slack 0.787  g_sound.u_note_manager/src_r[30]_0_s0/Q  →  g_sound.u_note_manager/scan_cnt_2_s0/CE
slack 1.043  g_sound.u_tdm_render_mixer/cnt_4_s0/Q   →  g_sound.u_tdm_render_mixer/prod_c_0_s/A[25]
```

---

## 十、⭐⭐ 第 5 次尝试：**v3-lite —— 更差，已回退**（⭐ 2026-10-11 ✅）

### ⭐ v3-lite 是什么

```text
v3-lite = calib.sv【内部】打拍（⭐ = v1 的位置 ⇒ 紧邻表读 ✅）
        + top.v 只给 calib_span/autotare 补 1 拍（⭐ 对齐 ✅）
        ⛔ 而 calib0/calib1 保持【不延迟】（⭐ 它们内部已有一拍 ✅）
```
📌 ⭐ 设计意图：⭐ **兼顾"位置对"（v1 ✅）与"对齐对"（v2 ✅）** ✅

### 🔴 实测：**PnR FAILED**

```text
Attempt Minutes FsNew Setup Hold   Fmax BuildExit  Pass
      1    13.2  True 22    0    49.833         6 False
[06:51:53] PnR FAILED on all attempts.
```

🔴 **22 个 setup 违例** · ⭐ Fmax **49.833 MHz**（⭐ 比基线的 56.2 **低 6.4 MHz** 🔴）

### ⭐ tb 侧的进展（⭐ 仍然有价值）

| ⭐ tb | ⭐ 结果 |
|---|---|
| ⭐ `tb_calib` | ✅ **绿**（⭐ 单点修法：⭐ `feed` 末尾多等一拍 ✅） |
| ⭐ `tb_calib_still_guard` | ✅ **绿**（⭐ 同一个单点修法：⭐ `feed_c` ✅） |
| ⭐ `tb_calib_span_err` | ✅ **绿**（⭐ **在 tb 里补顶层那一拍**：⭐ 给 `u_dut`（`calib_span`）的 `sample_valid`/`sample_ch`/`raw_in` 加一级寄存器 ✅ ＋ ⭐ `feed2` 末尾多等一拍 ✅） |
| ⭐ `tb_top_sound` | ✅ **绿**（⭐ 顶层能编译、能跑 ✅） |

⇒ ⭐ **6/7 + 顶层 tb 全绿** ⇒ ⚠️ **但 PnR 判据（≥0.3 ns）【严重未达成】** ⇒ ⭐ **按判据回退** ✅

### 🔴 为什么更差（⭐ 推断，⭐ 诚实标注）

⭐ `top.v` 那一拍**只喂 `calib_span`** ⇒ ⚠️ 它的输出（⭐ `sp_span_val`/`sp_span`/`sp_ch`）
⭐ **又要绕回 `calib`**（⭐ `calib0/1` 的 `.raw` 用 `sp_span_val` ✅）
⇒ 🔴 **多出一段"顶层寄存器 → `calib_span` → 回 `calib`"的长环** ✅
📌 ⭐ 而 `calib_span` 的 FSM 与 `calib` 的 `busy`/`err` 有**握手关系**（⭐ 见 `span_sent_r2` ✅）
⇒ ⭐ 这一拍把**握手也推后了** ⇒ ⚠️ 时序反而崩 ✅

### ⭐⭐ 五次尝试的总账（⭐ 这是本轮最终结论）

| ⭐ 次 | ⭐ 配置 | ⭐ 全量回归 | ⭐ PnR | ⭐ 结论 |
|---|---|---|---|---|
| 0 | ⭐ 无（⭐ 交付基线 ✅） | ✅ 137/137 | ✅ `0/0` · ⭐ Fmax **56.206** · ⭐ 最差 `adc_farm/Q → calib/A`（⭐ 0.008 ns） | ⭐ 基线 ✅ |
| 1 | ⭐ `calib` **内部** | 🔴 4 tb 红 | ✅ `0/0` · ⭐ Fmax **57.669** ✅ · ⭐ 最差 `note_manager`（⭐ 0.460 ns ✅） | ⭐ **时序最好** ✅ 但**簇内错位** 🔴 |
| 2 | ⭐ 同 1 ＋ 改 2 tb | ⚠️ 5/7 | ⭐ — | ⭐ 确认**错位**是根因 ✅ |
| 3（v2） | ⭐ **顶层**（⭐ 簇前） | ✅ 137/137 | ✅ `0/0` · ⭐ Fmax **56.205** · ⭐ 最差 `af_sample_ch_d/Q → calib/A`（⭐ 0.008 ns） | ⭐ **对齐对** ✅ 但**位置错** ⇒ ⭐ **时序中性** ✅ |
| 5（v3-lite） | ⭐ 内部 ＋ 只补 `calib_span` | ⭐ 6/7 | 🔴 **FAILED**（⭐ 22 违例 · ⭐ 49.833 MHz） | 🔴 **更差** ✅ |

### ✅ 最终处置：⭐ **全部回退**

⭐ 回退到**已交付状态**（⭐ `3a1a7c9` ✅）：
- ⭐ `rtl/drivers/calib.sv` ✅ · ⭐ `rtl/top.v` ✅
- ⭐ `tb/drivers/tb_calib.sv` ✅ · ⭐ `tb/w3a/tb_calib_still_guard.sv` ✅ · ⭐ `tb/w3a/tb_calib_span_err.sv` ✅
- ⭐ `sim/evidence/`（⭐ 恢复到已交付的构建证据 ✅）

✅ **回退后验证**：⭐ `通过 7 / 共 7`（⭐ 7 个 `calib*` tb 全绿 ✅）· ⭐ 工作区干净 ✅

### ⭐⭐ 结论（⭐ 值得写下来）

1. ⭐ **"打拍的位置"决定省不省走线** —— ⭐ 必须在**模块内部、紧邻表读** ✅（⭐ v1/v3-lite ✅）
   ⚠️ 打在顶层 ⇒ ⭐ 输出还要跨芯片走线 ⇒ ⭐ **时序中性**（⭐ v2 ✅）
2. 🔴 **但"只给 `calib` 打拍"会破坏 `calib_span` 的握手** ⇒ ⭐ **两个模块必须一起处理** ✅
   ⚠️ 而"在顶层只补 `calib_span`"又**造出一段长环** ⇒ 🔴 **更差** ✅
3. ⇒ ⭐ **正确的做法应当是：⭐ `calib` 与 `calib_span` 都【在各自模块内部】打拍** ✅
   （⭐ 即把 v1 的做法**同样施加到 `calib_span.v`** ✅）——
   ⚠️ 而 `calib_span` 的 FSM 与 `calib` 有**握手**（⭐ `span_sent_r2` / `busy` / `err` ✅）
   ⇒ ⭐ **必须把握手也算进那一拍** ⇒ ⭐ **这是一次【真正的重构】，⛔ 不是"加一级寄存器"** ✅
4. 📌 ⭐ **本轮的价值**：⭐ **把这条路的 5 种配置全试了一遍**，⭐
   并**用实测**排除了 4 种 ⇒ ⭐ **剩下唯一可行的方向（两个模块内部各自打拍 ＋ 握手同步）已经明确** ✅
   ⭐ 而且**每一轮都干净回退了**（⭐ 仓库始终是绿的 ✅）


⭐ 即：⭐ **`note_manager` 的 `src_r[30]` 到 `scan_cnt_*` 的 CE/D 端** ✅
（⭐ 与 `note_manager` 的**扫描 FSM ＋ 32 路比较**有关 ✅ —— ⭐ 那正是它 `same_hit` 的组合 OR 树 ✅）
📌 ⭐ **下一轮做完 `calib` 流水化后，⭐ 就该看 `note_manager` 这一条** ✅
