# `P1-18` —— 开鼓机时多发一条网格外事件（⭐ 2026-10-11 修复归档）

> ⭐ 这是 `review/时序与逻辑审查-20261009.md` §一 `[P1-18]` 的**修复证据**。
> ⭐ 所有数字**实测**，⛔ 无估算。

---

## 〇、一句话结论

⭐ **`P1-18` 已修** —— ⭐ 两条修法**都做了**（⭐ 接口补齐 ＋ 判据加固），
⭐ 并把审查留下的**一次性探针提升成了常驻判据** ✅

| 项 | 值 |
|---|---|
| ⭐ 缺陷 | ⭐ **交付默认档**（`SEL_DRUM=1` = 鼓机）下，⭐ **每次开鼓机**强拍前 **≈0.52 ms** 多一记 ⇒ 🔴 **紧 flam / 双击** ✅ |
| ⭐ 改动 | ⭐ `rtl/w3c/drum_gen.v`（**+56/−2**）· ⭐ `rtl/top.v`（**+8/−0**）✅ |
| ⭐ 新判据 | ⭐ `tb/w3c/tb_drum_gen_posreset.sv`（**5 条**，⭐ **同源双实例** ✅） |
| ⭐ 代价 | ⭐ 见 §五（⭐ `drum_gen` 只多 1 个输入端口 ＋ 1 个比较器 ✅） |

---

## 一、缺陷（⭐ 审查已复现，⭐ 本轮又独立复现一次）

### 链路（⭐ 逐行）

```verilog
// top.v:782   —— "开节拍器/鼓机"的上升沿脉冲
wire met_start = met_on_r & ~met_on_r_d;
// top.v:1505  —— 它喂 beat_gen
.pos_reset_i (met_start)
// beat_gen.v:199-204 —— 收到就【立刻】把 tick_cnt_o 清 0（⛔ 不产生 tick、⛔ 不产生 bar_start）
if (pos_reset_i) begin ... tick_cnt_q <= 16'd0; tick_cnt_o_q <= 16'd0; ... end
// drum_gen.v:357-358 —— 🔴 无符号差值法
wire step_advance = transport_i & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
```

🔴 **`0 - 300 = 65336 ≥ 240`** ⇒ ⭐ **无符号下溢** ⇒ ⭐ **假的 `step_advance`** ✅

📌 ⭐ 而 `drum_gen.v:33-35` 的模块头恰好把这条差值法论证成"**天然容忍跨小节跳变**" ——
⚠️ 它容忍的是**向前回绕**（⭐ `959 → 0`，⭐ 那条由 `bar_start_i` 的
`step_zero_align` **优先**处理 ✅），🔴 **⛔ 不是向后跳变** ✅

### ⭐ 听感（⭐ 为什么值得修）

⭐ 交付默认档 `SEL_DRUM = 1` = **鼓机**（⭐ `top.v:131`，⭐ 2026-09-30 用户裁定 ✅）
⇒ ⭐ **这条路径是可听的** ✅
· ⭐ 多出的那一记比强拍**早 ≈0.52 ms**（⭐ 120 BPM 下一个 16 分音符 = 125 ms ⇒ 约 **0.4%**）
· ⭐ 乐器 = `step_q + 1` 那一件 ⇒ 🔴 听感是**紧 flam**（⭐ 若与强拍同乐器则表现为**加厚/毛刺**）✅
· ⭐ 顺带污染 `evt_cnt_o` / `step_evt_cnt_o` / `hit_cnt_o`（⭐ 各**多计 1** ✅）

---

## 二、⭐ 判据（⭐ 先出"未修复能红"，⭐ 铁律①）

⭐ 审查留下的是**一次性探针**（`build/review_anvil09/tb_posreset_probe.sv`，
⭐ 用 `+NORESET` 切换 DUT/对照 ✅）—— ⚠️ 而 `build/` 是**临时目录**、
⭐ 且它**靠 plusarg 切换**（⭐ 一次运行只能看到一边 ✅）
⇒ ✅ **本轮把它提升成常驻判据**：⭐ `tb/w3c/tb_drum_gen_posreset.sv` ✅
⭐ **改成【同源双实例】**：⭐ 一次运行**同时**给出 DUT 与对照 ⇒ ⭐ **非空洞性内建** ✅

### ⭐ 五个判据

| # | ⭐ 判据 | ⭐ 打的是什么 |
|---|---|---|
| `J1` | ⭐ 复位后窗口内 A 组**不许**多出事件 | ⭐ **核心症状**（⭐ 未修复 **+1** ✅） |
| `J2` | ⭐ **同窗口** B 组必须 **0** 条 | ⭐ **非空洞性对照** ✅ |
| `J3` | ⭐ 复位后**前两条**必须是强拍（Kick → HiHat） | ⭐ 守"**开鼓机从强拍开始**"（⭐ 2026-09-28 用户要求 ✅） |
| `J4` | ⭐ 复位后 `step_q` 回到 0 | ⭐ 既有行为 ✅ |
| `J5` | ⭐ 复位后**立刻**（⭐ 10 拍内）`step_q` 就是 0 | ⭐ **修法① 专属**（⭐ 见 §四）✅ |

### ⭐ 实测（⭐ 未修复）

```text
   info: 复位前 A: tick_cnt=300 step_q=1 evt=2 | B: tick_cnt=300 step_q=1 evt=2
   info: pos_reset 脉冲已发（1 拍）
   info: 窗口1 新增 A=1 B=0（A: tick_cnt=0 step_q=2 | B: tick_cnt=301 step_q=1）
FAIL: J1 pos_reset must NOT produce any off-grid event
  ok  : J2 non-vacuity: the control (no pos_reset) has 0 events in the same window
   info: 窗口2 累计新增 A=3 B=0 | A: step_q=0 复位后前两条=171798691,5368709
FAIL: J3 the FIRST post-reset events are the step-0 downbeat (Kick then HiHat)
FAIL: tb_drum_gen_posreset - 2 pass / 2 fail
```

📌 ⭐ **与审查探针的日志逐字一致**（⭐ `+1` 条 · ⭐ `step_q` 由 1 变 2 · ⭐ 乐器 HiHat ✅）

### ⭐ 实测（⭐ 修复后）

```text
   info: 复位后 10 拍（tick 还没来）：A step_q=0 evt=2
  ok  : J5 pos_reset clears step_q IMMEDIATELY (before the next tick)
   info: 窗口1（复位后 20000 拍）新增 A=0 B=0
  ok  : J1 ... / ok : J2 ... / ok : J3 ...
   info: 窗口2 累计新增 A=2 B=0 | A: step_q=0 复位后前两条=5368709,171798691
PASS: tb_drum_gen_posreset - 5/5 judgements held
```

⭐ **注意 `窗口2`**：⭐ 修复前 `A=3`（⭐ **多余 1 条 ＋ 强拍 2 条**），
⭐ 修复后 `A=2`（⭐ **只有强拍**）✅ —— ⭐ **多余那一记真的没了** ✅

---

## 三、⭐ 改了什么（⭐ 两条修法**都做**）

### ⭐ 修法 ①：`drum_gen` 新增 `pos_reset_i`（⭐ 与 `beat_gen` 同源）

```verilog
input  wire pos_reset_i,                        // ⭐ top.v 接 met_start（与 beat_gen 同源）
wire   pos_rst = (pos_reset_i === 1'b1);        // ⭐ Z-safe 解码
...
if (pos_rst) begin                              // ⭐ 优先级最高
    step_q         <= 4'd0;
    tick_at_step_q <= tick_cnt_i;
    pending_q      <= 4'd0;                     // ⭐ 本拍不发任何残余事件
    hit_cnt_o      <= 4'd0;
    step_evt_cnt_o <= 16'd0;
end else if (step_zero_align) begin ... end else if (step_advance) begin ... end
```

⭐ **向后兼容（⭐ 关键）**：⭐ 用 `=== 1'b1` 解码 ⇒ ⭐ **老例化不接本端口（`z`）⇒ 当 0**
⇒ ⭐ **行为与加端口之前完全一致** ✅
📌 ⭐ 实证：⭐ `tb/w3c/tb_drum_gen.sv` **没有接**这个新端口 ⇒ ⭐ 它**照常全绿** ✅
（⭐ 与 `oscillator_bank.voice_phase_rst_i` / `note_manager.vel_upd_src_i` 同一套口径 ✅）

### ⭐ 修法 ②：差值判据加固（⭐ 一行）

```verilog
wire step_advance = transport_i
                  & (tick_cnt_i >= tick_at_step_q)          // ⭐ 新增：⭐ 先要求"没后退"
                  & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
```

⭐ **为什么不影响正常路径**：⭐ `bar_start_i` 那条 `step_zero_align` **优先级更高** ⇒
⭐ 小节回绕（⭐ `959 → 0`）永远走它，⛔ 走不到这里 ✅

---

## 四、⭐⭐ 为什么【两条都必要】（⭐ 变异体实测，⭐ 如实记录）

| 组合 | `J1` | `J3` | `J5` | ⭐ 总判 |
|---|---|---|---|---|
| ⭐ **都不修**（原始缺陷） | 🔴 **红** | 🔴 **红** | 🔴 **红** | 🔴 **FAIL** ✅ |
| ⭐ **只修 ①**（MUT-A） | ✅ 绿 | ✅ 绿 | 🔴 **红** | 🔴 **FAIL** ✅ |
| ⭐ **只修 ②**（MUT-B） | ✅ 绿 | ✅ 绿 | 🔴 **红** | 🔴 **FAIL** ✅ |
| ✅ **两条都修** | ✅ 绿 | ✅ 绿 | ✅ 绿 | ✅ **PASS** ✅ |

### 🔴 只修 ① 为什么不够（⭐ 一般情形）

⭐ `pos_rst` **当拍**，`tick_at_step_q` 拿到的还是**旧值**（⭐ `tick_cnt_i` 尚未更新）
⇒ ⚠️ **下一拍** `step_advance` 仍会**下溢为真** ⇒ ⭐ `step_q` 从 0 跳到 **1**、
⭐ 并装载 **step 1 的掩码** ✅
📌 ⭐ **`pattern 0` 恰好 step 1 是空掩码** ⇒ ⚠️ 所以 `J1` 在 MUT-A 下**侥幸绿** ✅
⇒ 🔴 **若换一个 step 1 非空的节奏型 ⇒ 多余事件照样出来** ✅
⇒ ⭐ **这正是 `J5` 存在的意义：⭐ 它查【状态】而不是【症状】** ✅

### ⚠️ 只修 ② 为什么也不够

⭐ 症状没了，⭐ 但 `drum_gen` **仍然不知道位置被复位了**
⇒ ⭐ `step_q` 会一直停在旧值，⭐ 直到下一个 tick 的 `bar_start` 才归零 ✅
📌 ⭐ 审查原文也这么写：*"只做 ② 能消除症状，但下游仍拿不到'位置复位'这件事"* ✅

---

## 五、⭐ 综合 / 回归（⭐ 实测）

### ⭐ 资源（⭐ 干净重建口径，⭐ 与上一轮 `P1-53` 对比）

| 资源 | ⭐ `P1-18` 之前 | ✅ `P1-18` 之后 | ⭐ 差值 |
|---|---|---|---|
| `T_Lut` | 27655 | **27615** | ⭐ **−40** ✅ |
| `T_Register` | 17627 | **17627** | ⭐ **0** ✅ |
| `T_Alu` | 8280 | **8297** | ⭐ **+17** |
| `T_Bsram` | 34 | **34** | ⭐ **0** ✅ |

📌 ⭐ **怎么读这个表**：⭐ 修法 ② 加的那个 16 位"没后退"比较器走**进位链** ⇒ ⭐ `T_Alu +17` ✅；
⭐ 而 `if (pos_rst)` 那层分支让综合器**共享了原有逻辑** ⇒ ⭐ `T_Lut` **反而少 40** ✅
⇒ ⭐ **净效果 ≈ 免费**（⭐ 甚至略小 ✅）
📌 ⭐ **零 FF** —— ⭐ 因为清位用的都是**已有寄存器** ✅

### ⭐ 回归

| 项 | ⭐ 值 |
|---|---|
| ⭐ `drum` 相关 | ⭐ **7/7 全绿**（⭐ 含 `tb_drum_gen`（⭐ **不接新端口** ⇒ 覆盖 `z`-safe 兼容 ✅）· ⭐ `tb_drum_pitch_env` · ⭐ `tb_drum_sweep_window` · ⭐ `tb_osc_drum_cls` · ⭐ `tb_drum_timbre_top` · ⭐ `tb_key_drum` ✅） |
| ⭐ **全量回归** | ⭐ **通过 136 / 共 136** ✅ |

---

## 六、⭐ PnR（⭐ 含 `P1-53` 之后新增的 `buildExit` 判据）

| 项 | ⭐ 值 |
|---|---|
| ⭐ 违例 | ⭐ **`0 setup / 0 hold`** ✅ |
| ⭐ `Actual Fmax` | ⭐ **58.518 MHz** ⇒ ⭐ **真实余量 `+2.91 ns`** ✅ |
| ⭐ 对照（`P1-53` 之后） | ⭐ 56.492 MHz ⇒ `+2.30 ns` |
| ⭐ `CLS` / `BSRAM` | ⭐ 24107/29952 = **81%** · ⭐ 37/118 = 32% ✅ |
| ⭐ `buildExit` | ⭐ **`0`** ✅ |
| ⭐ `sha256` | ⭐ **`7B82B0EDF3D4C26A2D5BC7587C820FECCD6856BABCC30D87728E0E6516ED7DFA`** |
| ⭐ 大小 | ⭐ 18883 KB |

### ⭐⭐ 6 道门全 OK（⭐ 逐字）

```text
OK  NL0002 gate: 3 swept module(s), all whitelisted
OK  P1-53 gate: 0 parameter-guard violations (EX3793 absent)
    HOLD worst slack = 0.183 ns  (review baseline 0.137)   u_looper hits = 0
OK  P0-25 gate: HOLD worst slack 0.183 ns >= 0.05 ns
OK  P0-23 gate: 0 async-reset sensitivity lists
OK  P0-26 gate: all 2 generated clock(s) have an Fmax row: serial_clk, pixel_clk
OK  P0-29 gate: all 6 critical observability wires have a consumer
=== Gowin build finished, exit code 0 ===
```

⚠️ ⭐ **`Fmax 56.492 → 58.518 MHz` 不是"本改动带来的性能提升"** ——
⭐ 本改动只加了 1 个比较器 ⇒ ⭐ **这是【布局变化】的结果** ✅
（⭐ 与本项目 `交接文档` §五② 记录的"PnR 是布局噪声主导"一致 ✅）
⇒ ⭐ **⛔ 不要把它归因给 `P1-18`** ✅

---

## 七、⚠️ 诚实标注

1. ⭐ **还没上板** —— ⭐ 本轮是**仿真 ＋ 综合 ＋ PnR** 验证 ✅
   ⇒ ⭐ 上板要听：⭐ **开鼓机的那一下不再有紧 flam** ✅
2. ⭐ `J5` 查的是**内部状态**（`step_q`）—— ⚠️ 它**不是**用户可听的东西 ✅
   📌 ⭐ 但它是**必要的**：⭐ 因为 `pattern 0` 的 step 1 是空掩码，
   ⚠️ 只靠 `J1`/`J3`（症状层）**抓不到"只修 ①"** ✅
3. ⚠️ ⭐ **未加**的判据：⭐ "**换一个 step 1 非空的节奏型**（⭐ 如 `pattern 1/2/3`），
   在只修 ① 的情况下也必须红" —— ⚠️ 那会让 `J1` **直接**抓住"只修 ①" ✅
   📌 ⭐ 本轮**没做**（⭐ 因为 `J5` 已经在状态层抓住了，⭐ 边际收益小）；
   ⭐ 若将来要更强，⭐ 加一对 `pattern_id_i = 1` 的实例即可 ✅
4. ⭐ 顺带记录一条**踩坑**（⭐ 已写进 tb）：⭐ **`J1` 的窗口必须【严格小于】一个 tick** ——
   ⚠️ 我原来用 `TICK_CLK`（26042）⇒ ⭐ 加上 `J5` 那 10 拍之后，
   ⭐ 窗口右端正好跨过**第一个 tick** ⇒ 🔴 **把强拍也数进去 ⇒ 假红** ✅
   ✅ **修法**：⭐ `WIN1_CLK = 20000`（⭐ ≈ 一个 tick 的 77%）⇒
   ⭐ 缺陷那条在 **+2.5 拍**（⭐ 稳稳在内）、⭐ 强拍在 **+26042 拍**（⭐ 稳稳在外）✅
