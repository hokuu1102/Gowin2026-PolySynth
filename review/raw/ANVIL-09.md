# ANVIL-09 · 鼓机与节拍 —— 静态审查 + 复现证据

| 项 | 值 |
|---|---|
| 审查对象 | `rtl/w3c/drum_gen.v` · `rtl/w3c/perc_env_bank.v` · `rtl/w3c/beat_gen.v` · `rtl/w3c/metronome.v` |
| 方法 | 逐行读码 + 机械核对（脚本解码常量表 / 引用计数）+ **2 组可复现仿真实验**（探针复现 1 条缺陷；反事实实验证明 1 条顺序依赖） |
| 结论 | **P0 = 0 · P1 = 1 · P2 = 3 · P3 = 8 · 合计 12** |
| 复现探针 | `build/review_anvil09/tb_posreset_probe.sv`（日志：`probe_dut.log` / `probe_control.log`） |

## 严重度口径（本次自定，便于对齐）

| 级别 | 判据 |
|---|---|
| **P0** | 违反冻结接口 / 合规红线（PCM、软核）/ 交付档整体失效 |
| **P1** | **默认交付档下可听/可见的功能错误**，或已被探针复现 |
| **P2** | 跨模块契约不成立、根因级接口缺口、系统性的可观测性缺失（当前症状可能被掩盖） |
| **P3** | 注释↔代码不一致、死逻辑、纪律自相矛盾 —— **无功能后果** |

---

## 一、条目总表

| # | 级别 | 文件:行 | 一句话 | 后果 |
|---|---|---|---|---|
| ANVIL09-01 | 🔴 **P1** | `drum_gen.v:357-358` | `pos_reset`（= `top.v` 的 `met_start`）让 `tick_cnt_i` **回退**，无符号差值下溢 ⇒ **多发 1 条不在网格上的鼓事件** | 默认档（`SEL_DRUM=1`）每次开鼓机，强拍前 **0.52 ms** 多一下（紧 flam）。**已仿真复现** |
| ANVIL09-02 | 🟠 **P2** | `beat_gen.v:199-204` | `pos_reset_i` 立刻把 `tick_cnt_o` 清 0，但**不发 tick / 不发 bar_start**，也不通知下游"位置复位了" | 01 的**根因**；下游"差值法"无法区分"回绕"与"回退" |
| ANVIL09-03 | 🟠 **P2** | `perc_env_bank.v:76` + `top.v:4124/4346` | `active_o`（模块自述的"**防挂音关键**"）在 `top.v` 里**悬空**；保留池 voice 的释放判据仍来自 ADSR | 保留池 voice **永不释放**（`live_mask` 含 `gate_r` 恒 1）。可听症状被 `env_level_mix` 掩盖 ⇒ 契约不成立 |
| ANVIL09-04 | 🟠 **P2** | 四模块 + `top.v` | 四模块**所有** `K-106` 可观测输出（`cfg_warn` / 计数 / 回绕）在 `top.v` 里**全部悬空** | 上板无任何读数路径；与四个文件头都写着的"K-106 ⛔ 不许静默失效"直接矛盾 |
| ANVIL09-05 | 🟡 P3 | `metronome.v:133-166` vs `top.v:1549-1550` | 头部把 `180/108` 当"当前值"并据此得出"不碰软膝"；**交付档是 `220/132`** | 注释↔交付配置相反；对 220 而言该结论不成立（92.7% FS 已进膝区） |
| ANVIL09-06 | 🟡 P3 | `drum_gen.v:226-228` | 头部"嗵鼓只出现在 **8/14/15/16**"与表实际 **8/11/14/15/16** 矛盾 | 漏 step 11（机械解码证实） |
| ANVIL09-07 | 🟡 P3 | `drum_gen.v:130,399` · `metronome.v:198` · `perc_env_bank.v:149,153` | 四处**对 `integer` 参数做位选**，而各文件头**就写着"⛔ 不对 integer 参数做位选（K-91）"** | 纪律自相矛盾；实测 Gowin 当前接受（PnR 通过）⇒ 无功能后果 |
| ANVIL09-08 | 🟡 P3 | `metronome.v:204` · `:130` | `is_normal` 死线网；注释里的 tb 行号 `:249/:252` 实际是 `:253/:256` | 维护误导 |
| ANVIL09-09 | 🟡 P3 | `beat_gen.v:123,195` · `:125-130` | `run_d` 只写不读（死逻辑），而头部称"下游需要它"—— 它**不是输出端口** | 注释与事实矛盾 |
| ANVIL09-10 | 🟡 P3 | `perc_env_bank.v:77,114` | `busy_o` 与 `active_o` **逐位相同**（同一个 `active_r`），头部却把二者写成不同语义 | 冗余诊断输出 |
| ANVIL09-11 | 🟡 P3 | `drum_gen.v:430,438,449` · `:406` | "装载新步掩码"与"发出即清"同拍时**靠非阻塞赋值顺序**（后者胜）；且"16 步=1 小节"这条契约**无 RTL 自检** | 现通过依赖顺序偶然（反事实实验：改这一处 ⇒ **9 条判据红**）；改 `TICKS_PER_STEP` 会静默截断 |
| ANVIL09-12 | 🟡 P3 | `perc_env_bank.v:130-156` | `trigger_i` 宽于 1 拍时，装载被推迟到 trigger 落下（期间 `level` 冻结在旧值） | 契约依赖（冻结表 §〇 约定 4），但无断言守着 |

---

## 二、P1 详情（已复现）

### ANVIL09-01 · `drum_gen` 在 `pos_reset` 后多发 1 条不在网格上的事件

**链路（逐行）**

1. `rtl/top.v:782` `wire met_start = met_on_r & ~met_on_r_d;` → `rtl/top.v:1505` `.pos_reset_i (met_start)`。
   ⇒ **每次"打开"节拍器/鼓机（按 `S2`/`AB13`，或串口 `'B'`；`met_on_r` 的**上升沿**）都会发一个 1 拍宽的 `pos_reset` 脉冲**（`top.v:551-554` 是 `met_on_r` 的翻转寄存器，`:760` 的注释确认这个上升沿脉冲就是本机制的设计意图）。
2. `rtl/w3c/beat_gen.v:199-204`：`if (pos_reset_i) begin ... tick_cnt_q <= 16'd0; tick_cnt_o_q <= 16'd0; ... end`
   ⇒ **`tick_cnt_o` 在那一拍【立刻】跳回 0**（⛔ 不是等到下一个 tick）。
3. `rtl/w3c/drum_gen.v:357-358`：
   ```verilog
   wire step_advance = transport_i & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
   ```
   `tick_cnt_i` 与 `tick_at_step_q` 都是 `[15:0]` ⇒ `0 - 240 = 65336 ≥ 240` ⇒ 🔴 **假推进**。
   （`drum_gen.v:33-35` 的头部恰好把这条差值法论证成"**天然容忍跨小节跳变**" —— 它容忍的是**向前回绕**，⛔ 不是**向后跳变**。）
4. `drum_gen.v:438` 装载 `mask_next` → `:445-453` 下一拍发出 ⇒ **多一条事件**。
5. 真正的复位要等下一个 tick（`beat_gen` 相位已被清 ⇒ 约 0.52 ms 后）：`tick_cnt_o=0` + `bar_start_o=1` ⇒ `drum_gen.v:425-432` 把 `step_q` 归 0、装载 step 0 ⇒ 强拍正常。

**仿真复现（探针 + 对照，C83 口径：未修复代码必须输出不同）**

```
iverilog -g2012 -o probe.vvp rtl/w3c/beat_gen.v rtl/w3c/drum_gen.v build/review_anvil09/tb_posreset_probe.sv
vvp probe.vvp            # DUT
vvp probe.vvp +NORESET   # 对照
```

| 运行 | 复位前 | 复位后 1 个 tick 窗口内 | 结果 |
|---|---|---|---|
| **DUT**（发 `pos_reset`，1 拍） | `tick_cnt=300 step_q=1 evt=2` | 🔴 **+1 条**：`t=156770830000`（复位后 **50 ns**）`inst=HiHat` `step_q=2` | **DEFECT REPRODUCED** |
| **对照**（`+NORESET`） | `tick_cnt=300 step_q=1 evt=2` | ✅ **+0 条**，`step_q` 仍 = 1 | PASS |

随后（复位后 520.87 µs）下一个 tick 把 `step_q` 归 0，正常发出强拍 `Kick + HiHat`（日志 `evt #4/#5`）。

**影响面（已核实，⛔ 不是推测）**

- `rtl/top.v:131` `parameter integer SEL_DRUM = 1` ⇒ **交付默认档 = 鼓机**（`top.v:111-116` 记录：2026-09-30 深夜用户裁定）⇒ 这条路径**在默认档是可听的**。
- 幅度：多出的一下比强拍早 **≈0.52 ms**（120 BPM 下一个 16 分音符 = 125 ms ⇒ 约 0.4%），乐器 = `step_q+1` 那一件 ⇒ 听感是**紧 flam / 强拍前的一记双击**（若那一件与强拍同乐器则表现为"加厚/毛刺"）。
- 同一根因还污染 `evt_cnt_o` / `step_evt_cnt_o` / `hit_cnt_o`（多计 1 条、短暂报错步号）。
- `SEL_DRUM=0`（节拍器档）时 `drum_gen` 的事件被 `top.v:3867` 的源 B 二选一挡掉 ⇒ **不可听**，但缺陷仍在（每次 `'B'` 都发生）。

**修法（三选一，按代价排序）**

1. ⭐ `drum_gen` 增加 `pos_reset_i` 端口（与 `beat_gen` 同源），复位时清 `pending_q`/`step_q`/`tick_at_step_q` —— 语义最干净。
2. ⭐ `drum_gen` 改用**有符号/带方向**判据，例如 `(tick_cnt_i >= tick_at_step_q) && (tick_cnt_i - tick_at_step_q >= TPS_C)` —— 一行改动，把"回退"排除掉。
3. ⚠️ `beat_gen` 在 `pos_reset_i` 当拍**额外**发一个 `bar_start_o`（见 ANVIL09-02）—— 会改变"第一个 tick 才是强拍"的既有验收行为，⚠️ 需复核 `tb_beat_gen` / `tb_met_start_top`。

> 📌 建议做 **①+②**（接口补齐 + 判据加固）；只做 ② 能消除症状，但下游仍拿不到"位置复位"这件事。

---

## 三、P2 详情

### ANVIL09-02 · `beat_gen` 的位置复位没有对应事件（01 的根因）

- `beat_gen.v:199-204` 清 `tick_cnt_q` / `tick_cnt_o_q` / `beat_cnt_q` / `bar_cnt_q`，**但不置 `tick_q`、不置 `bar_start_q`**。
- 结果：`tick_cnt_o` 是"位置"信号，却在**位置真正归零之前 0.52 ms** 就报 0；这段窗口里没有任何事件能告诉下游"发生了一次跳变"。
- 头部 `beat_gen.v:43-45` 说"二者的变化都必须在**边沿时刻**被捕获（约定 4）"，但 `pos_reset` 这条**恰恰没有边沿输出**。
- 头部 `:24-27` 自述 `tick_cnt` 是 looper 事件记录的骨架（`tick[15:0]` 时间戳）⇒ ⚠️ **looper 侧需复核**：它同样只能看到 `tick_cnt` 回退（本条超出本次审查的四个文件范围，仅登记）。
- 建议：`pos_reset_i` 当拍输出一个显式脉冲（复用 `bar_start_o`，或新增 `pos_reset_o`），并在文件头把"位置复位是**事件**、不是**电平**"写成契约。

### ANVIL09-03 · `perc_env_bank.active_o` 悬空 ⇒ "防挂音"契约不成立

- `perc_env_bank.v:33-38` 自述：*"`active_o` **必须**在衰到 0 时**准确落下**：`note_manager` 用 `env_active_i` 判'这个 voice 还在不在响'（`live_mask`）⇒ 若 `active_o` 一直为 1，那个 voice **永远不释放** ⇒ **挂音**"*。
- 实际接线（`grep` 全 `top.v`）：
  - `top.v:4124` `.env_active_i (env_active)` ← **来自 `envelope_bank` 的 ADSR**（`top.v:1458`），⛔ **不是** `perc_active`；
  - `top.v:4346` `.active_o (perc_active)` —— `perc_active` **只出现在声明与端口两处，无任何消费者**。
- 而 `note_manager.v:532` `live_mask = gate_r | hold_mask | env_active_r | sus_hold_r`，其中 `gate_r` 对保留池**恒为 1**（`metronome`/`drum_gen` 只发 `note_on`，`EVT_KIND=2'd0`，**永不发 `note_off`**，见 `metronome.v:169` / `drum_gen.v:96`）⇒ **即使把 `perc_active` 接上，也释放不了那个 voice**。
- ⇒ 结论：**"一击到底 ⇒ 自动释放 voice"这条设计意图并没有实现**。当前"不再挂音"的可听效果，来自 `top.v:4359` 把保留池**电平**换成 `perc_level`（衰到 0 ⇒ 不发声），⛔ 不是来自 voice 释放。
- 影响：保留池 voice 的 `free_mask` 恒 0（专用池，对键盘无抢占影响 ⇒ 目前无功能后果），但**契约、可观测性、以及"这个模块为什么存在"三者都没落地**（`K-144` 家族：建好了但没接上）。

### ANVIL09-04 · 四模块的 `K-106` 可观测输出在 `top.v` 里全部悬空

四个文件头都写了 `K-106` 纪律（"容量有限 / 会静默失效的东西必须可观测"），并都提供了输出端口。机械核对（`grep` 全 `rtl/top.v`，只命中**声明**与**例化端口**）：

| 输出 | 文件:行 | `top.v` 里的引用数 | 备注 |
|---|---|---|---|
| `met_cfg_warn` | `metronome.v:192` | 2（声明+端口） | 常量比较 ⇒ 综合必然消失 |
| `met_beat_cnt` / `met_accent_cnt` | `metronome.v:188-189` | 各 2 | 无消费者 |
| `drm_cfg_warn` | `drum_gen.v:125` | 2 | 同上 |
| `drm_evt_cnt` / `drm_step_cnt` / `drm_hit_cnt` / `drm_step_evt_cnt` | `drum_gen.v:121-124` | 各 2 | 无消费者 |
| `bg_bar_cnt` / `bg_wrap` | `beat_gen.v:84,87` | 各 2 | 无消费者 |
| `perc_active` / `perc_busy` / `perc_retrig_cnt` | `perc_env_bank.v:76-81` | 各 2 | 无消费者 |

⇒ **交付的位流里没有任何一条路径能读出这些值**。项目已有专门的可观测性通路（`rtl/w3c/span_probe.v` / `pos_probe.v` 走串口），这四个模块的对应值**一条都没接**。建议：至少把 `cfg_warn`（4 处）与 `drm_evt_cnt` / `bg_wrap` 挂到一个串口探针字节上 —— ⚠️ 否则"参数配错"这类失效在上板时**完全不可见**（本项目 `K-106`/`K-107` 反复吃亏的那一类）。

---

## 四、P3 详情

### ANVIL09-05 · `metronome` 头部数值 ≠ 交付数值

- `metronome.v:167-168`：`VEL_ACCENT = 8'd180` / `VEL_NORMAL = 8'd108`，且 `:133-166` 用**整段推导**论证"抬到 180 仍然安全（最坏 85.0% FS < 软膝 87.5%）"。
- 交付档（`top.v:1549-1550`）：`.VEL_ACCENT (8'd220)` / `.VEL_NORMAL (8'd132)`，而 `top.v:1545` 自己算出 **220 ⇒ 92.7% FS ⇒ 已进软膝**。
- ⇒ 头部结论**对交付值不成立**；下一个调音量的人若只读 `metronome.v`，会以为"当前 180、有 2.5% 余量"。
- 建议：在 `metronome.v` 头部显式写"**交付档由 `top.v` 覆盖为 220/132，本节的 180 推导只对模块默认值成立**"，或把交付值移回模块默认值（⛔ 但后者会改变已上板确认的响度，需用户拍板）。

### ANVIL09-06 · 嗵鼓步号清单漏了 step 11

- `drum_gen.v:226-228`：*"本表里嗵鼓只出现在 **step 8 / 14 / 15 / 16**（1 基）"*。
- 机械解码 `drum_gen.v:237-332` 的 4 张表（脚本按 `4'dN: m = 4'bXXXX;` 逐格解析）：

```
pat0: Kick[1/5/9/13] Snare[5/13] HiHat[1/3/5/7/9/11/13/15] Tom[]              pop=14
pat1: Kick[1/5/9/13] Snare[5/13] HiHat[3/7/11/15]           Tom[8/16]         pop=12
pat2: Kick[1/7/9/15] Snare[5/13] HiHat[1/3/5/7/9/11/13/15]  Tom[14]           pop=15
pat3: Kick[1/5/8/9/13] Snare[5/13] HiHat[1/3/…/15,16]       Tom[8/11/14/15/16] pop=21
ALL TOM STEPS (1-based, unique): 8,11,14,15,16
```

- 四个**分型**注释与表**逐格一致** ✅；只有**文件头那句汇总**错了（漏 `11`）。`pat3` 自己的注释（`:309`）写的是 `8/11/14/15/16` ✅ ⇒ 同文件内两处互相矛盾。
- 注：用户强调的"嗵鼓⛔ 不能落在每一拍上"这条**仍然满足**（8/11/14/15/16 都不是 1/5/9/13）✅ —— 本条只是文档缺陷。

### ANVIL09-07 · K-91 位选：文件头禁止，代码就在旁边做

| 文件:行 | 代码 | 同一文件头的声明 |
|---|---|---|
| `drum_gen.v:130` | `localparam [3:0] STEPS_C = STEPS[3:0];` | `:55` "⛔ 不对 `integer` 参数做位选（`K-91`）⇒ 先落到定宽 `localparam`" |
| `drum_gen.v:399` | `assign evt_axis_o = AXIS_ID[AXIS_W-1:0];` | 同上 |
| `metronome.v:198` | `localparam [AXIS_W-1:0] AXIS_V = AXIS_ID[AXIS_W-1:0];` | `:196-197` "⛔ **不能对 `integer` 参数直接做位选** —— 先经一个显式定宽的 `localparam` 落成向量再用"（⚠️ 但右边仍是位选） |
| `perc_env_bank.v:149,153` | `if (level_r <= DECAY_STEP[ENV_W-1:0])` / `level_r - DECAY_STEP[ENV_W-1:0]` | `:45` "⛔ **不对 `integer` 参数做位选**（`K-91` 顺带发现）" |

- 诚实口径：**实测 Gowin 当前接受**（这四个模块都在交付设计里、PnR 通过）⇒ **无功能后果**；且项目内部对"常量位选是否合法"本身有两种说法（`files/20-代码/审计-note_manager与ADSR-20260928.md:369-370` 判"合法、大概率无害"；`已知问题与风险清单.md` 的 `K-91` 条判"Verilog-2001 同样非法"）。
- 但既然 `K-91` 的失效模式是"**整个模块被静默丢弃**"，最省事的做法是**去掉位选**（`localparam [3:0] STEPS_C = STEPS;` 即可，⛔ 不需要 `[3:0]`）—— 与 `drum_gen.v:129` 的 `TPS_C` 写法一致 ✅。

### ANVIL09-08 · `metronome` 死线网 + 过期行号

- `metronome.v:204` `wire is_normal = beat_i & ~bar_start_i;` —— **全文件仅此 1 次引用**（机械计数）⇒ 死线网（真正的判据用的是 `fire_normal`/`is_accent`）。
- `metronome.v:130` 注释引 `tb/w3c/tb_metronome.sv:249` / `:252`；实测该 tb 里比较 `u_met.VEL_ACCENT`/`VEL_NORMAL` 的两行是 **`:253` / `:256`**（`Select-String` 实测）。

### ANVIL09-09 · `beat_gen.run_d` 是死逻辑，且头部的理由不成立

- `beat_gen.v:123` 声明、`:186` / `:195` 各赋值一次，**从不被读**（机械计数：`run_d` 5 次命中全部是声明/注释/赋值）。
- `:125-130` 头部称它"**必须保留**：① 是'边沿时刻已采样'的硬件证据；② **下游**（节拍器/鼓机的 run 边沿）**需要它**" —— 但它**不是输出端口**，下游物理上拿不到；同一段又承认"Gowin 会因未被使用把它优化掉"⇒ 两句话自相矛盾。
- 建议：要么删掉，要么把它变成真端口（若确有下游需求）。

### ANVIL09-10 · `perc_env_bank.busy_o` 与 `active_o` 逐位相同

- `perc_env_bank.v:113-114`：`assign active_o[pi] = active_r;` / `assign busy_o[pi] = active_r;` ⇒ **同一根线**。
- 而 `:47` 把 `busy_o` 描述成"**还有几个在衰减**"、`:76` 把 `active_o` 描述成"1 = 还在响" —— 二者被写成不同语义，实际是冗余输出（`active_r` 在"装载相位"也是 1，并不严格等于"在衰减"）。
- 建议：让 `busy_o` 只在"已装载且仍在衰减"时为 1（`active_r & ~load_r`），或合并成一个输出。

### ANVIL09-11 · `drum_gen` 的赋值顺序依赖 + 缺一条自检

- `drum_gen.v:430`（`pending_q <= mask_step0`）、`:438`（`pending_q <= mask_next`）与 `:449`（`pending_q <= pending_q & ~drum_sel`）在**同一个 `always` 块**里；Verilog 语义"**后写胜**" ⇒ **`fire` 与步进/小节对齐同拍时，新一步的掩码被丢弃**。
  - 当前**不可达**（`TPS_C=240` ⇒ 每步之间有 240 拍，`pending_q` 早已排空）⇒ 无功能后果；
  - ⚠️ 但 `tb/w3c/tb_drum_gen.sv:243-249` **故意把 `bar_start_i` 拉宽到 2 拍**（`:223` 注释自述"拉了两拍宽"；该 tb 用 `TPS=8`，`:36`）⇒ 该 tb 的通过**恰好依赖"后写胜"这个偶然**。
  - **反事实实验（已做，见 §六）**：把 `:449` 改成"步边界那一拍不清"（= 让装载胜）⇒ `tb_drum_gen` **9 条判据变红**（`exit 1`），其中判据 ② 直接报 **15 条/小节（期望 14）**、判据 ③ 报"step0 的 Kick+HiHat 被吞/重复"、判据 ⑤ 报"粘滞"、4 条位精确表判据也红；基线（现 RTL）**PASS**。
  - ⇒ 结论：**现 RTL 是对的，但"对"建立在赋值顺序这个隐含前提上**（重构时顺序一变，9 条判据全红 —— 好在 tb 抓得住，⛔ 不是静默）。建议把优先级写成显式表达式（例如 `pending_q <= fire ? (pending_q & ~drum_sel) : next_pending;`），把意图写进代码。
- `drum_gen.v:406` 的 `cfg_warn_o` 只查 `RESERVED_N < 1` / `STEPS != 16` / `TICKS_PER_STEP < 1`；而**"16 步 = 1 小节"**（`TICKS_PER_STEP × STEPS == PPQN × BEATS_PER_BAR` = 3840，`beat_gen.v:93`）这条与 `beat_gen` 的**隐式契约没有 RTL 自检**，只在 `tb_drum_gen` 判据 ② 里守着。改 `TICKS_PER_STEP`（`top.v:1612` 硬编码 240）会**静默**截断/提前重启音序。建议加 `TICKS_PER_BAR` 形参并自检。

### ANVIL09-12 · `perc_env_bank` 对"宽触发"没有防护

- `perc_env_bank.v:130-156`：`if (trigger_i[pi]) ... else begin if (load_r) ... end` —— 装载走的是 **`trigger` 的 `else` 分支**。
- ⇒ 若 `trigger_i[pi]` 连续多拍为高：`load_r` 保持 1，`level_r` **一直不被装载**（停在旧值），衰减也被跳过（`level` 冻结）；直到 trigger 落下才装载并开始衰减。
- 契约上 `trigger` 是单拍脉冲（`perc_env_bank.v:70-71` 引冻结表 §〇 约定 4），且 `top.v:4324` 的 `perc_trig = nm_gate & ~nm_gate_d` 确实是单拍 ✅ ⇒ **当前不是缺陷**；但模块内**没有断言**守这条契约。建议在 `initial` 之外补一条 `$display` 级别的自检说明，或把装载改成 `if (load_r || trigger_i[pi])`（等价于让触发拍立刻装载，⛔ 但那会改掉"触发后一拍装载"的时序，⚠️ 需重跑 `tb_perc_env_bank`）。

---

## 五、已核对为"无问题"的点（避免下游重复劳动）

| 检查 | 结论 | 证据 |
|---|---|---|
| 四个节奏型掩码是否与分型注释一致 | ✅ 逐格一致（`pat0 pop=14` / `pat1 12` / `pat2 15` / `pat3 21`） | 机械解码（见 ANVIL09-06） |
| 16 步 × 240 tick = 1 小节（3840） | ✅ 成立 | `drum_gen.v:83` + `beat_gen.v:93` |
| 一步多乐器"逐个发、不吞" | ✅ 结构上成立（`pending_q` one-hot + 逐拍清一位） | `drum_gen.v:443-454`；tb 判据 ③ |
| `evt_*` 与 `evt_valid_o` 同拍锁存（`metronome` 老 bug 的镜像） | ✅ 成立（字段与 `valid` 同一拍赋值） | `drum_gen.v:445-448` · `metronome.v:249-253` |
| 事件字段与脉冲是否同拍 | ✅ `beat_i`/`bar_start_i` 在 `beat_gen` 里同拍产生（`beat_gen.v:219-220`） | — |
| 力度 ↔ 峰值线性映射（`peak = velocity << 8`） | ✅ 与 `perc_env_bank.v:84-86,110` 一致 | — |
| `DECAY_STEP=67` 的时长换算 | ✅ 满力度 975 拍 = 19.97 ms；180 ⇒ 14.09 ms；108 ⇒ 8.46 ms（与 `top.v:4298-4300` 一致） | 逐值复算 |
| `beat_gen` 的 `beat`/`bar_start` 相位（0/960/1920/2880，`bar_start` 在 0） | ✅ 与 `K-107` 的修正一致 | `beat_gen.v:159-171,216-220` |
| 合规红线（无 PCM / 无软核 / 节奏型只是 `{on,vel}` 结构） | ✅ 四模块均无 `.mem`、无 `$readmemh`、无 MCU | `grep` 全仓；`drum_gen.v:201-214` 的论证成立 |
| `drum_gen`/`metronome` 的 `RESERVED_N` 与 `note_manager`（5）一致 | ✅ | `top.v:1537/1613/4013` |

---

## 六、复现材料

| 文件 | 说明 |
|---|---|
| `build/review_anvil09/tb_posreset_probe.sv` | 探针 tb（`beat_gen` + `drum_gen` 按 `top.v` 同参数例化；`+NORESET` 为对照） |
| `build/review_anvil09/probe_dut.log` | DUT 日志（**含那条多余事件**） |
| `build/review_anvil09/probe_control.log` | 对照日志（0 条多余事件） |
| `build/review_anvil09/probe.vvp` | 编译产物 |
| `build/review_anvil09/drum_gen_loadwins.v` | **反事实**副本（只改 `:449` 一处：步边界那一拍不清 ⇒ "装载胜"），用于 ANVIL09-11 |
| `build/review_anvil09/tb_drum_baseline.vvp` / `tb_drum_loadwins.vvp` | 基线 / 反事实的 `tb_drum_gen` 编译产物 |

```powershell
# 复现 ANVIL09-01（在仓库根执行）
iverilog -g2012 -o build/review_anvil09/probe.vvp `
    rtl/w3c/beat_gen.v rtl/w3c/drum_gen.v build/review_anvil09/tb_posreset_probe.sv
vvp build/review_anvil09/probe.vvp            # ⇒ DEFECT REPRODUCED
vvp build/review_anvil09/probe.vvp +NORESET   # ⇒ 对照 PASS（0 条）

# 复现 ANVIL09-11 的反事实（现 RTL PASS / 改一处顺序 ⇒ 9 条判据红）
iverilog -g2012 -o build/review_anvil09/tb_drum_baseline.vvp tb/w3c/tb_drum_gen.sv rtl/w3c/drum_gen.v
iverilog -g2012 -o build/review_anvil09/tb_drum_loadwins.vvp tb/w3c/tb_drum_gen.sv build/review_anvil09/drum_gen_loadwins.v
vvp build/review_anvil09/tb_drum_baseline.vvp    # ⇒ PASS（exit 0）
vvp build/review_anvil09/tb_drum_loadwins.vvp    # ⇒ 9 FAIL（exit 1）：② 15/小节（期望 14）…
```

⚠️ 探针放在 `build/review_anvil09/`，**⛔ 没有**放进 `tb/` —— `sim/tb_all.ps1` 会自动发现 `tb/**/tb_*.sv`，放进去会**改变回归基数**（本项目已因"写死基数"错过三次，见项目 `AGENTS.md` §四）。

---

## 七、给下一环的建议顺序

1. 🔴 **ANVIL09-01 / -02**（一起做）：`beat_gen` 补"位置复位是事件"的输出 **或** `drum_gen` 加固差值判据；做完**必须**在默认档（`SEL_DRUM=1`）上板听一次"开鼓机第一声"。
2. 🟠 **ANVIL09-03**：决定"保留池 voice 到底要不要释放"。若维持现状，**必须改 `perc_env_bank.v:33-38` 的头部**（把"防挂音"改成"防可听挂音"，并写明 `active_o` 未接、`gate_r` 恒 1）—— 否则下一个人会照着这条注释去查一个不存在的机制。
3. 🟠 **ANVIL09-04**：把 4 个 `cfg_warn` + `drm_evt_cnt` + `bg_wrap` 挂上串口探针（可观测性零成本，收益是"上板能看见参数配错"）。
4. 🟡 ANVIL09-05/-06/-07/-08/-09/-10/-11/-12：随下一次触碰这些文件时**顺手修**（都是注释/纪律类，零行为风险）。
