## note_manager / adsr / envelope_bank 只读技术梳理（S6 审计输入）

**结论先行（3 条会改变你下一步的）：**
1. 🔴 **`排查计划与疑问清单-20260928.md:38-48` 的"孤儿路径①"不是挂音真因。** 路径①要求 A 已经过 RT_HIGH（gate_r[A]=1、retrig_hold=0）；此时 `gate_mask[A]=1` 且 `axis_r[A]` 完好 ⇒ **任何该轴的 note_off 都能清掉它**（515-516 用的是 gate_mask）。若抢占发生在 **RT_LOW 期间**，真实后果是 gate 停在 **0**（丢音），不是停在 1。⇒ 用户"按所有键也清不掉"只能用**保留轴 14/15 + 只发 note_on**（你的发现 1/2）解释。**S4 的"改成每 voice 一套 retrig"修的是另一个真 bug（交错重触发丢音），修不了挂音。**
2. 🔴 **新发现：ST_COMMIT 的 `retrig_reset_r[best_idx] <= 1`（:570）只有 1 拍，而 adsr 只在 `sample_tick_i` 那一拍采样（adsr.v:61-69）⇒ 抢占路径的包络清零命中率 ≈ 1/1024。** 即"11 倍尖音"的修复**只覆盖同轴重触发（RT_LOW 用电平保持，:481），没覆盖抢占**。class 2 抢占（gate 本来就是 1）连下降沿都没有 ⇒ 新音直接从旧电平续着响，没有 attack。
3. 🔴 **`event_lost_o` / `event_lost_cnt_o` 在 top.v 根本没接**（top.v:2293-2352 只有 `event_lost_clr_i(1'b0)`）⇒ K-106 的"溢出可观测"未交付，`lost_*` 无负载会被综合删掉；且 clr 恒 0 ⇒ 上板只能靠复位清。

另：真正的 Fmax 关键路径是 `retrig_idx` → hold_mask → gate_mask → 32 个 voice 的 CE（与你 `未完成工作总账.md:350-360` 一致）；**改成 `retrig_low[31:0]` 位图会同时去掉 32×5 位比较器 ⇒ 既修 bug 又提 Fmax**。

---

# 1. 模块职责与接口

## 1.1 note_manager.v（633 行）—— 32 voice 分配 / 抢占 / 重触发 / 释放 / 参数更新

| 参数 | 默认 | top.v 实际值 | 说明 |
|---|---|---|---|
| `POLY_TARGET` | 32 | **32**（top.v:63 → :2278） | voice 数 |
| `AXIS_W` | 4 | 4（:2279） | 轴号位宽 ⇒ 最多 16 轴 |
| `PHASE_W` | 32 | 32（:2280） | 相位增量位宽（不是相位累加器） |
| `VEL_W` | 8 | 8（:2281） | 力度 |
| `TIMBRE_W` | 2 | 2（:2282） | 每 voice 音色（K-82） |
| `ENV_W` | 16 | 16（:2283） | 包络电平回读位宽 |
| `AGE_W` | 16 | 16（:2284） | 抢占年龄 |
| `RESERVED_N` | 0 | **5**（:2292） | 从**最高索引**往下留 5 个（voice 27..31） |
| `DEFAULT_VEL` | 200 | 200（未覆盖） | `note_velocity_i==0` 时的起音力度 |
| `RESERVED_AXIS_BASE` | 14 | 14（未覆盖） | 轴 ≥14 视为专用池 |
| `FIFO_DEPTH` | 32 | 32（未覆盖） | 事件队列深度 |
| `EVT_LOST_CNT_W` | 8 | 8（未覆盖） | 丢弃计数（饱和于 255） |
| `IDX_W` | `clog2(POLY_TARGET)`=5 | 5 | 派生 |

派生 localparam：`NORMAL_N = 32-5 = 27`（:162-164）⇒ **普通 voice = 0..26，专用 = 27..31**；`SCAN_LAST=31`（:177）、`SW=5`（:178）、`FW=5`（:179）、`AXIS_MAX=15`（:612）、`FIFO_MIN=18`（:614）。

端口（:91-153）：

| 方向 | 名字 | 位宽 | 语义 |
|---|---|---|---|
| in | `clk_i` | 1 | 50 MHz，**全部逻辑**都在这 |
| in | `rst_n_i` | 1 | 同步低有效复位 |
| in | `sample_tick_i` | 1 | 1 拍脉冲 / 1024 clk = 20.48 µs（clk_gen.v:104） |
| in | `note_valid_i` | 1 | 事件脉冲（来自 `evt_merge`，top.v:2306） |
| in | `note_axis_i` | 4 | 轴号 |
| in | `note_phase_inc_i` | 32 | 相位增量 |
| in | `note_velocity_i` | 8 | 0 ⇒ 用 `DEFAULT_VEL` |
| in | `note_kind_i` | 2 | 0=on 1=off 2=pluck |
| in | `vel_upd_valid_i/axis/value` | 1/4/8 | 力度修正（**top.v:2329 硬接 1'b0，当前失效**） |
| in | `pitch_upd_valid_i/axis/value` | 1/4/32 | 音高修正（top.v:2332-2334 已接 `param_extract`） |
| in | `default_timbre_i` | 2 | 新起音默认音色（top.v:2335 = 2'd0） |
| in | `evt_timbre_valid_i` / `evt_timbre_i` | 1/2 | Looper 每层覆盖（来自 `evt_merge`） |
| in | `env_active_i` | 32 | ← `envelope_bank.env_active_o` |
| in | `env_level_i` | 32×16=512 | ← `envelope_bank.env_level_o` |
| out | `voice_gate_o` | 32 | = `gate_mask` → `envelope_bank.gate_i` |
| out | `voice_active_o` | 32 | = `live_mask` → `oscillator_bank.voice_active_i`（top.v:2394） |
| out | `voice_releasing_o` | 32 | 诊断 = `live_mask & ~gate_mask`（**top.v:2342 悬空**） |
| out | `voice_axis_o` | 32×4 | 诊断 / 抢占（top.v:2343） |
| out | `voice_phase_inc_o` | 32×32 | → `oscillator_bank` |
| out | `voice_velocity_o` | 32×8 | → `envelope_bank.velocity_i` |
| out | `voice_timbre_o` | 32×2 | → wavetable |
| out | `voice_age_o` | 32×16 | 诊断（top.v:2347，**无下游**） |
| out | `voice_retrig_reset_o` | 32 | → `envelope_bank.retrig_reset_i`（top.v:2348，Test Mode 时被屏蔽 :805） |
| out | `alloc_valid_o` / `alloc_voice_o` | 1/5 | 分配脉冲（top.v:2349-2350，**无下游 = 死输出**） |
| out | `event_lost_o` | 1 | sticky 溢出（**top.v 未连接** 🔴） |
| out | `event_lost_cnt_o` | 8 | 饱和丢弃计数（**top.v 未连接** 🔴） |
| in | `event_lost_clr_i` | 1 | top.v:2351 **恒 0** ⇒ 只能靠复位清 |

## 1.2 adsr.v（140 行）—— 单 voice 包络

参数默认（top.v **一个都没覆盖**，envelope_bank.v:31-37 也只透传默认）：`ENV_W=16`、`VEL_W=8`、`ATTACK_STEP=669`、`DECAY_STEP=4`、`SUSTAIN_Q8=64`、`RELEASE_STEP=2`。

端口：`clk_i`、`rst_n_i`、`sample_tick_i`、`gate_i`(1)、`velocity_i`(8)、`retrig_reset_i`(1，**最高优先级**)、`env_level_o`(16, reg)、`active_o`(1)。

## 1.3 envelope_bank.v（51 行）—— 纯 generate 包装

参数 `POLY_TARGET=32`/`VEL_W=8`/`ENV_W=16`（top.v:793-795 显式传，与 note_manager 一致），ADSR 四参数未覆盖。
端口：`gate_i[31:0]`、`velocity_i[255:0]`、`retrig_reset_i[31:0]`、`env_level_o[511:0]`、`env_active_o[31:0]`；扁平总线约定 voice i = `bus[i*W +: W]`（:3, :43-46）。
**本模块自身零逻辑、零参数自检**（对比项目其它模块都有 `initial $display` 自检）。

---

# 2. 状态机

## 2.1 分配扫描 FSM（note_manager，`state` 3 bit，复位 ST_IDLE :367）

| 状态 | 编码 | 进入 | 退出 | 输出 / 动作 |
|---|---|---|---|---|
| `ST_IDLE` | 3'd0 | 复位(:367)、ST_DECIDE 的 off/重触发分支(:521,:532)、ST_COMMIT(:573)、`default`(:576) | `!fifo_empty` ⇒ `state<=ST_DECIDE`（:497-506） | `fifo_pop=1`（:243，组合）；锁存 `cur_*` ← `head_*`（:499-504） |
| `ST_DECIDE` | 3'd1 | ST_IDLE 取出事件 | 三分支 | ①`cur_kind==KIND_OFF`：清**所有**同轴且 `gate_mask` 高的 voice（:514-516），必要时取消重触发（:517-520）⇒ ST_IDLE；②`same_valid`：同轴重触发（:522-532）⇒ ST_IDLE；③否则启动扫描（:535-537）⇒ ST_SCAN |
| `ST_SCAN` | 3'd2 | ST_DECIDE 第三分支 | `scan_cnt==31` ⇒ ST_COMMIT（:550-551） | **每拍考察 1 个 voice**：`cand_ok&&cand_better` ⇒ 更新 `best_*`（:543-549）；`scan_cnt++` |
| `ST_COMMIT` | 3'd3 | ST_SCAN 扫完 | 无条件 ⇒ ST_IDLE（:573） | 写 `gate_r/axis_r/phase_r/vel_r/timbre_r/age_r[best_idx]`（:559-564）；`retrig_reset_r[best_idx]<=1`（:570）；`alloc_valid_r<=1`（:571） |
| `default` | 其它 | — | ⇒ ST_IDLE（:576） | 不可达（3 bit 只用了 0-3） |

## 2.2 重触发 FSM（`retrig_state` 2 bit，复位 RT_NONE :364）

| 状态 | 编码 | 进入 | 退出 | 输出 |
|---|---|---|---|---|
| `RT_NONE` | 2'd0 | 复位(:364)、RT_HIGH+sample_tick(:489)、`ST_DECIDE` 的 off 且轴匹配(:517-520) | `same_valid` ⇒ RT_LOW | 无 |
| `RT_LOW` | 2'd1 | `ST_DECIDE` 的 `same_valid`（:525） | `sample_tick_i` ⇒ RT_HIGH（:484） | **每 clk**：`gate_r[idx]<=0`（:475）、`retrig_reset_r[idx]<=1`（**电平**，:481）；tick 拍：`gate_r[idx]<=1`、`retrig_hold<=0`（:483-485） |
| `RT_HIGH` | 2'd2 | RT_LOW + tick | `sample_tick_i` ⇒ RT_NONE（:489） | **每 clk**：`gate_r[idx]<=1`（:488） |

## 2.3 adsr FSM（`state` 2 bit + `releasing` 标志，复位 ST_IDLE/releasing=0/env=0 :57-60）

| 状态 | 编码 | 进入 | 退出 | 输出 |
|---|---|---|---|---|
| `ST_IDLE` | 2'd0 | 复位；release 到 0（:74-77）；`default`（:131-133） | `gate_i` ⇒ ST_ATTACK（:87-88） | `env_level_o<=0`（:86） |
| `ST_ATTACK` | 2'd1 | gate 上升（:88）；`releasing && gate`（:71-73）；**`retrig_reset_i`**（:62-69，最高优先级） | `env_level>=peak` 或 一步到顶 ⇒ ST_DECAY（:92-97） | `env += 669`/tick（:99） |
| `ST_DECAY` | 2'd2 | attack 到顶 | `<= sustain_level`（含一步到位）⇒ ST_SUSTAIN（:104-109） | `env -= 4`/tick（:111） |
| `ST_SUSTAIN` | 2'd3 | decay 到位 | **无自动退出**（只能被 gate↓ / retrig_reset / 抢占改写） | 朝 `sustain_level` 平滑（:117-127，用 669/4 步长） |
| （隐含）release | `releasing=1` | `!gate_i && state!=ST_IDLE`（:81-82） | gate↑⇒ATTACK（:71-73）；`env<=2` ⇒ IDLE（:74-77） | `env -= 2`/tick（:79） |
| `default` | — | — | ⇒ IDLE（:130-134） | **不可达**（4 个编码已占满） |

`envelope_bank` 无状态机。

---

# 3. 时序

## 3.1 时钟域划分

- **全部寄存器都在 `clk_i` 上**，无派生时钟、无 PLL（符合冻结表 §〇 约定 1）。
- `sample_tick_i` 只是**时钟使能**：
  - note_manager 只用在 **(a) 年龄递增**（:391-395）和 **RT_LOW/RT_HIGH 迁移**（:482-489）。**分配 FSM（ST_IDLE/SCAN/COMMIT）、FIFO、vel/pitch 修正全部与 tick 无关，自由跑**。
  - adsr **除了复位，所有状态更新都被 `sample_tick_i` 门控**（:61）。
- `tick_audio` 由 clk_gen.v:104 `tick_audio <= (cnt==0)` 产生 ⇒ **1 拍宽、在 cnt==1 那一拍为高**，周期 1024 clk = 20.48 µs（fs = 48.828 kHz）。
- ⭐ **相位关系**：note_manager 与 envelope_bank 接**同一个** `tick_audio`（top.v:2296 / :799）。两者在**同一个沿**动作 ⇒ **互相看到的是沿前的旧值**。⇒ **任何 `gate_r` 的变化，ADSR 要等到下一个 tick 沿才看见**（最坏 +20.48 µs）。

## 3.2 关键路径拍数（实测推演，从 `note_valid_i` 那一沿算起）

| 事件 | 拍数 | 说明 |
|---|---|---|
| 入队 | 1 拍 | `fifo_push` 写 `fifo_*`，`fifo_cnt` 在沿后变 1（:399-411） |
| `ST_IDLE` 取出 | +1 拍 | `fifo_empty` 是 `fifo_cnt` 的组合（:231）⇒ **入队当拍不可能 pop**，必须等下一拍（:243, :497） |
| `ST_DECIDE` | +1 拍 | :509-539 |
| `ST_SCAN` | +32 拍 | 每拍 1 个 voice（:541-555） |
| `ST_COMMIT` | +1 拍 | `gate_r[best_idx]<=1` 在这一沿写入（:559） |
| **合计** | **35 拍 = 0.70 µs**（第 36 个 clk 起 `voice_gate_o` 可见） | ⚠️ **头注释写"≤34 拍"（:20,:31），漏算了 pop 那 1 拍** |
| 同轴重触发（same_hit） | 3 拍 | push(1)+pop(1)+DECIDE(1) ⇒ `gate_r[idx]<=0`、`retrig_state<=RT_LOW`（:524-527） |
| `note_off` | 3 拍 | 同上 ⇒ `gate_r[i]<=0`（:516） |
| 重触发 gate 恢复 | **≤ 2 个 tick** | RT_LOW 等 tick（≤1024 clk）→ RT_HIGH 再等 tick → RT_NONE |
| FIFO 排空 | 每事件 +2 拍（off/重触发）或 +35 拍（需扫描） | ⚠️ 头注释 :82-84 说"32×35=1120 拍 = 22.4 µs 仍在一帧内"—— **一帧只有 1024 clk = 20.48 µs，1120 > 1024，这句话自相矛盾** |
| ADSR 看见 gate | 下一个 tick 沿（≤+20.48 µs） | adsr.v:61 |

**FIFO 稳定性（缓解上面那条）**：上游被限到 ≤18 事件/帧（16 轴 + 节拍器 1 + 鼓机 1，:609-610），而排空能力 = 1024/35 ≈ **29 事件/帧** ⇒ 队列不会无界增长；18 条突发 = 630 clk < 1024 ⇒ 实际仍在一帧内。所以"听感延迟不变"的**结论**成立，但**契约数字（≤34 拍）和 1120 拍的算术要改**。

## 3.3 包络时间常数（fs = 48.828 kHz，vel=200 ⇒ peak = 200<<8 = 51200，sustain = peak×64>>8 = 12800）

| 量 | tick | 时间 |
|---|---|---|
| attack 0→peak | 51200/669 ≈ 77 | **1.58 ms** |
| decay peak→sustain | (51200−12800)/4 = 9600 | **196.6 ms** |
| release sustain→0 | 12800/2 = 6400 | **131.1 ms** |
| release peak→0 | 51200/2 = 25600 | **524.3 ms** |
| 每 tick 电平步进 | attack +669 / decay −4 / release −2 | — |

---

# 4. 数据结构

| 寄存器 | 位宽×深度 | 含义 / 生命周期 |
|---|---|---|
| `gate_r[0:31]` | 1×32（:182） | 对外门（经 `gate_mask` 输出）。置位：ST_COMMIT(:559)、RT_LOW+tick(:483)、RT_HIGH(:488)。清 0：复位(:353)、RT_LOW 每拍(:475)、`note_off`(:516)、同轴重触发(:524)。**`note_off` 是唯一"正常释放"路径** |
| `axis_r[0:31]` | 4×32（:183） | 该 voice 当前轴号。**分配时写（:560），释放后永不清零** ⇒ `note_off` 匹配（:515）与 `same_hit`（:292）全靠它 |
| `phase_r[0:31]` | 32×32（:184） | **相位增量**（不是累加器）。写：分配(:561)、重触发(:528)、`pitch_upd`(:468) |
| `vel_r[0:31]` | 8×32（:185） | 力度 → adsr 的 `peak_level = vel<<8`（adsr.v:50）⇒ **线性决定音量** |
| `timbre_r[0:31]` | 2×32（:186） | 每 voice 音色，**起音时刻锁存**（K-82）。写：分配(:563)/重触发(:530) |
| `age_r[0:31]` | 16×32（:187） | 每 tick 在 `live_mask` 时 +1，**饱和于 0xFFFF**（:391-394）；分配/重触发时清 0（:531,:564）。抢占 class 2 取"最大 age" |
| `retrig_hold` / `retrig_idx[4:0]` / `retrig_state[1:0]` | 1/5/2（:190-192） | ⚠️ **单套全局**，却描述"每 voice 一个"的两步重触发 ⇒ 见 §5-C |
| `fifo_v[0:31]` | 1×32（:219） | 🔴 **只写 1、从不写 0（:360 复位、:400 置位），且全文无读点** ⇒ 死逻辑（§5-E） |
| `fifo_ax/inc/vel/knd/timbre_valid/timbre` | 4/32/8/2/1/2 ×32（:220-225） | 事件载荷；读出端 `head_*`（:257-262） |
| `fifo_wr/rd` / `fifo_cnt` | 5/5/6（:226-228） | 环形指针 + **单一计数**（push/pop 同拍正确处理，:411-413 无 else = 故意保持） |
| `scan_cnt[4:0]`、`best_valid/best_idx[4:0]/best_cls[1:0]/best_env[15:0]/best_age[15:0]` | :311-316 | 串行扫描的"当前最优" |
| `cur_axis/inc/vel/kind/timbre_valid/timbre` | :265-270 | 队列头锁存（**池掩码用它而不是活的 `note_axis_i`**，:272） |
| `retrig_reset_r[0:31]` | 32（:347） | 每 clk 先清（:388），(f)/(g) 按需置位 ⇒ **脉冲或电平** |
| `alloc_valid_r` / `alloc_voice_r[4:0]` | 1/5（:344-345） | 1 拍脉冲（:387 清、:571 置） |
| `lost_cnt_r[7:0]` / `lost_sticky_r` | 8/1（:252-253） | 饱和计数 + sticky；clr 优先（:418-425） |

组合信号推导：

| 信号 | 定义（行号） | 语义 |
|---|---|---|
| `hold_mask[mg]` | `retrig_hold & (retrig_idx==mg)`（:206） | **只对 1 个 voice 有效** |
| `gate_mask[mg]` | `gate_r[mg] & ~hold_mask[mg]`（:207） | 对外门；重触发压低期间为 0 |
| `live_mask[mg]` | `gate_r \| hold_mask \| env_active_i`（:208） | 还能出声（含 release 尾巴 + 重触发保持）→ `voice_active_o` |
| `free_mask[mg]` | `~live_mask`（:209） | 完全空闲；⚠️ **重触发保持不算空闲** |
| `same_hit[sg]` | `gate_mask[sg] && (axis_r[sg]==cur_axis)`（:292） | 同轴重触发检测；`same_valid=\|same_hit`（:295） |
| `same_idx` | `always @(*)` 从 31 递减扫、后写覆盖 ⇒ **最低索引优先**（:300-304） | 32 级 mux 链 |
| `pool_mask[pg]` | `RESERVED_N==0 ? 1 : (cur_axis>=14 ? pg>=27 : pg<27)`（:277-285） | 池隔离 |
| `cand_idx/pool/hold/free/rel/cls/env/age` | :319-326 | `cand_rel=(~gate_mask)&env_active`；`cand_cls = free?0 : rel?1 : 2` |
| `cand_ok` / `cand_better` | `cand_pool & ~cand_hold`（:329）/ :330-335 | 分类 0>1>2；同类 1 取 env 最小、类 2 取 age 最大；并列取最低索引 |
| `new_vel` / `new_timbre` | `cur_vel!=0 ? cur_vel : 200`（:338）/ `cur_timbre_valid ? cur_timbre : default_timbre_i`（:342） | 提交时用 |
| `fifo_full/empty/push/pop/drop` | :230-231, :242-248 | `drop = note_valid_i && fifo_full`（与 push 互斥） |

---

# 5. 🔴 可疑点

> 每条：`位置 | 问题 | 为什么可疑 | 后果 | 验证方法`

## A. 🔴🔴 ST_COMMIT 的包络清零是 1 拍脉冲，而 ADSR 只在 `sample_tick` 采样 ⇒ 抢占路径的清零 ≈ 完全失效

| 项 | 内容 |
|---|---|
| **位置** | note_manager.v:**570**（`retrig_reset_r[best_idx] <= 1'b1;`）+ **388**（每 clk 清零）；adsr.v:**61-69**（`else if (sample_tick_i) begin if (retrig_reset_i)`） |
| **问题** | ST_COMMIT 只持续 1 clk ⇒ `retrig_reset_r[best_idx]` 是 **1 拍脉冲**；ADSR 只在 tick 那一拍看它 ⇒ **命中率 = 1/1024** |
| **为什么可疑** | 注释 :565-569 明确宣称"抢占也要清零包络…否则又是同一个尖音 bug"，而 :481 的同轴重触发路径**特意改成了电平**并写明"若只发一拍脉冲，而 `sample_tick` 恰好错开 ⇒ 清零丢失"。**同一条纪律在 :570 没有执行** ⇒ 自相矛盾 |
| **后果** | ① 抢占 class 1（正在 release、env 有残值）：ADSR 走 `releasing && gate` 分支（adsr.v:71-73）⇒ **从残余电平继续 attack** ⇒ release 尾巴 + 新 attack 叠加 = 文档 :128-136 说的 **~11 倍尖音**，**仍然存在**；② 抢占 class 2（gate 本来就是 1）：`gate_r[best_idx]<=1` 无变化 ⇒ **连下降沿都没有** ⇒ 新音直接继承旧包络电平，**没有 attack 瞬态**，听感是"音高突然换了但音量不重启" |
| **验证方法** | 定向 tb：让 voice i 进入 release（`env_level_i[i] != 0`）→ 发一个必然抢占它的事件（把其余 voice 都占满）→ 下一个 tick 检查 `env_level_o[i]` 是否为 0。**判据：应为 0；预期实测 ≈ 不为 0（99.9%）**。或用 Verilator 探针跑 1000 次抢占统计命中率 ≈ 1/1024 |
| **修法方向（不改，仅建议）** | 与 RT_LOW 同构：给抢占加"保持到下一个 tick 的 `retrig_reset` 电平"（per-voice pending 位），或让 adsr 对 `retrig_reset_i` 做**沿检测 + 保持** |

## B. 🔴 RT_LOW 的**第一拍**若撞上 `sample_tick`，`retrig_reset` 同样漏采 ⇒ 同一尖音以 ~1/1024 概率复现

| 项 | 内容 |
|---|---|
| **位置** | note_manager.v:**474-486**（进入 RT_LOW 的那一拍只写 `retrig_state`，`retrig_reset_r` 从**下一拍**才为 1）；adsr.v:61-69 |
| **问题** | 设 t0 = ST_DECIDE 的 `same_hit` 沿（`retrig_state<=RT_LOW`）。`retrig_reset_r[idx]` 在 **t1** 那一沿才置 1（:481）。若 `sample_tick_i` 恰好在 **t1 那一拍为高**：ADSR 在 t1 沿看到 `retrig_reset_i=0`、`gate_i=0`（旧值）⇒ 走 adsr.v:81-82 置 `releasing=1`；同沿 note_manager 把 `gate_r[idx]<=1`、`retrig_state<=RT_HIGH`、`retrig_hold<=0`。下一个 tick 时 `retrig_reset_r` 早已被 :388 清掉 ⇒ ADSR 走 `releasing && gate` ⇒ **从残余电平 attack** |
| **为什么可疑** | :476-480 的注释声称"用**电平**而不是单拍脉冲，避免跨时钟域式的漏采"——但**电平是从 t1 才开始的，t1 本身就是一个漏采窗口**。且事件到达相位与 tick 完全无关（FSM 自由跑，§3.1） |
| **后果** | 与 A 相同的 11 倍尖音，概率 ≈ 1/1024/次重触发 ⇒ **"偶发刺耳尖音"（用户实测）不会被现有修复消除，只会变稀** |
| **验证方法** | 扫相位：让 `note_valid_i` 相对 tick 偏移 0..1023 拍各发一次同轴重触发，检查重触发后第一个 tick 的 `env_level_o` 是否从 0 开始。**预期：偏移 = 1023（tick 落在 RT_LOW 第一拍）时失败** |

## C. 🔴 `retrig_hold`/`retrig_idx`/`retrig_state` 单套全局被用于"每 voice"操作（已知，但结论要修正）

### C1 · 交错重触发 ⇒ 前一个 voice 的 gate **永久停在 0**（丢音）

| 项 | 内容 |
|---|---|
| **位置** | :190-192（单套全局）、:206（hold_mask 只覆盖 1 个）、:517-532（抢占/覆盖） |
| **时序** | t0：A 轴事件 `same_hit` 命中 voice A ⇒ `retrig_idx<=A, retrig_state<=RT_LOW, gate_r[A]<=0`（:524-527）。t3：另一轴的 `same_hit` 命中 voice B ⇒ `retrig_idx<=B`（:527）。此后 (f) 段**只操作 B**（:474-490）⇒ **A 再也没人抬 gate**，而 A 的 `phase/vel/timbre/age` 已被 t0 改写（:528-531） |
| **为什么可疑** | 这正是"单套全局寄存器被用于每 voice 操作"的教科书案例。⭐ **修正文档 `排查计划与疑问清单-20260928.md:38-48` 的"孤儿路径①"**：那条路径要求 A 已经过 RT_HIGH（gate=1、hold=0），此时 `gate_mask[A]=1`、`axis_r[A]` 完好 ⇒ **该轴的任何 note_off 都能清掉它**（:515-516 判的是 gate_mask）。**若抢占发生在 RT_LOW 期间，真正的后果是 gate 停在 0（丢音），不是停在 1（挂音）** |
| **后果** | ① 丢音：A 那个音**完全不响**（voice 参数被改写、资源被占，直到 env 衰完变 free）；② **不能解释用户"按所有键也清不掉"** ⇒ 挂音真因仍应指向你的 §十一 发现 1/2（保留轴 14/15 + 只发 note_on ⇒ `axis_r[i] ∉ 键盘轴` ⇒ 无任何 note_off 能匹配） |
| **验证方法** | 多轴 tb：tick 前对 axis A 发重触发，3 拍后对 axis B 发重触发，等 2 个 tick，检查 `voice_gate_o[A]`。**判据：应为 1（干净重启）；预期实测 0（丢音）**。⭐ 这与你已发现"单轴 tb 测不到多轴交互"一致 |

### C2 · RT_LOW 期间**同轴再按** ⇒ 分配出第二个同轴 voice（`same_hit` 用 `gate_mask` 被自己挡住）

| 项 | 内容 |
|---|---|
| **位置** | :292（`same_hit = gate_mask[sg] && axis_r[sg]==cur_axis`）+ :206-207（`gate_mask` 在 hold 期间恒 0） |
| **问题** | 重触发压低期间（≤1024 clk = 20.48 µs）该 voice 的 `gate_mask=0` ⇒ `same_hit` **检测不到它** ⇒ 事件走 `else` 分支（:533-538）启动扫描 ⇒ **又给同一个轴分配一个新 voice** |
| **为什么可疑** | 设计意图是"同轴位重触发优先（复用同一 voice，⛔ 不新占，:523）"，但恰恰在压低窗口内该意图失效。且 `free_mask` 又把它算作"不空闲"（:209）⇒ 它既不能被复用、也不能被抢占，只能等 |
| **后果** | ① 同一个键**两个 voice 同时响**（相位不同 ⇒ 拍频/音量加倍/音色脏）；② 复音被双倍消耗：27 个普通 voice 快速同键连按 14 次就打满 ⇒ 触发抢占 ⇒ 又踩 A/B 的尖音路径；③ 随后 note_off 会清"所有"同轴 voice（:514-516）⇒ **不会挂音** |
| **验证方法** | tb：在 RT_LOW 窗口内对同一 axis 连发两次 `note_on`，检查 `voice_axis_o` 是否出现两个 `gate=1` 的同轴 voice。**判据：应只有 1 个；预期实测 2 个** |
| **修法方向** | `same_hit` 改用 `live_mask`（把 hold 中的 voice 也算命中）而不是 `gate_mask` |

### C3 · ⭐ 单套全局寄存器**不影响**池隔离（正面结论）

`pool_mask` 只约束 ST_COMMIT 的 `best_idx`（:543-549 的 `cand_ok` 含 `cand_pool`），因此**普通轴事件永远拿不到 voice 27..31、保留轴事件也拿不到 0..26** ⇒ 你的"发现 1/2 的保留轴挂音"**最多污染 5 个专用 voice**，不会把键盘 voice 变成孤儿。⚠️ 但 `same_hit`（:292）**没有 pool 检查**，隔离只靠"保留 voice 的 `axis_r` 永远是 ≥14"这个不变量——属于缺防御性设计。

## D. 🔴 K-106 的"溢出可观测"没有交付：`event_lost_o`/`event_lost_cnt_o` 在 top.v **未连接**

| 项 | 内容 |
|---|---|
| **位置** | note_manager.v:**150-152**（端口）、**601-602**（assign）；top.v:**2293-2352**（例化端口清单里**没有** `.event_lost_o` / `.event_lost_cnt_o`；只有 :2351 `.event_lost_clr_i (1'b0)`） |
| **为什么可疑** | 文件头 :34-49 把这三件（深度 16→32、sticky、饱和计数）当作 K-106 的完整修复；但**输出没接出去**，clr 又恒 0 |
| **后果** | `lost_sticky_r`/`lost_cnt_r` 无任何负载 ⇒ 综合**直接优化掉** ⇒ 与"静默丢弃"等价（正是 K-106 要禁的失效模式）；即便保留也无法上板读取、无法清零（只能复位） |
| **验证方法** | ① `grep -n event_lost rtl/top.v` ⇒ 只有 :2351；② 看综合/PnR 报告是否还有 `lost_cnt_r`（或直接读网表） |
| **备注** | 同类死输出：`alloc_valid_o`/`alloc_voice_o`（top.v:692-693 声明、:2349-2350 连接但**无人使用**）、`voice_releasing_o`（:2342 悬空）、`voice_age_o`（:2347 无下游） |

## E. 🟡 `fifo_v[]` 只置位、从不写 0，且**从未被读** ⇒ 死逻辑

| 项 | 内容 |
|---|---|
| **位置** | :219（声明）、:360（复位）、:400（置 1）；**全文无 `fifo_v[` 读点**（`head_*` 直接读 `fifo_ax/inc/vel/knd`，:257-262，靠 `fifo_empty` 保证有效） |
| **为什么可疑** | 这是"没有被释放的逻辑"的典型：32 个位在第一次 push 后**永久为 1** |
| **后果** | 现在无害（无读点 ⇒ 会被优化掉）。⚠️ 危险在于**将来有人把它当 valid 位用** ⇒ 得到"槽位永远有效"的错误结论 |
| **验证方法** | `grep -n "fifo_v" rtl/w3b/note_manager.v` ⇒ 恰好 3 处（219/360/400），无读 |

## F. 🟡 ST_COMMIT 不检查 `best_valid`；`best_idx` 在 ST_DECIDE 不清 ⇒ 潜在 stale 写入

| 项 | 内容 |
|---|---|
| **位置** | :535-537（只清 `best_valid`，**不清 `best_idx`**）、:557-573（直接使用 `best_idx`） |
| **问题** | 若某一轮扫描**一个候选都没有**（`best_valid` 始终 0），ST_COMMIT 会拿**上一次分配遗留的 `best_idx`** 去写 `gate/axis/phase/vel/timbre/age` |
| **何时可达** | `pool_mask` 全 0 —— 即 `RESERVED_N == POLY_TARGET`（`NORMAL_N=0`，:281-283）且来的是普通轴事件。当前 top 用 `RESERVED_N=5` ⇒ **不可达**，但这是一个**没有守卫的隐式假设**（自检 :616-618 只查 `RESERVED_N > POLY_TARGET`，**漏了 `==`**） |
| **后果** | 跨轴污染：错误 voice 被赋成新轴的 `axis_r/phase_r` ⇒ 同轴双音 / 音高错乱 / `age` 被清 |
| **验证方法** | 把 `RESERVED_N` 改成 32（或 tb 里 force `pool_mask=0`）跑一次 tb，看 ST_COMMIT 是否写到 stale `best_idx`。或直接审 PnR 网表确认 `best_idx` 的复位/更新条件 |

## G. 🟡 "≤34 拍"契约与"1120 拍仍在一帧内"的算术错误

| 项 | 内容 |
|---|---|
| **位置** | 头注释 :20 / :31（"≤34 拍"）、:82-84（"32×35=1120 拍 = 22.4 µs …仍在一帧内"）；实际路径 :242-243（pop 需先看到 `fifo_cnt`）、:497-506、:541-573 |
| **问题** | ① 真实分配延迟 = 1(push)+1(pop)+1(DECIDE)+32(SCAN)+1(COMMIT) = **35 拍**，不是 34（漏算 pop 那 1 拍）；② **1120 clk > 1024 clk（一帧）** ⇒ "22.4 µs 仍在一帧内"**自相矛盾**（20.48 µs 才是一帧） |
| **为什么可疑** | 这是**冻结表 §四 的对外契约数字**（:30-32 说已通知全员改 34），数字错会让队友 tb 的等待拍数不足 |
| **后果** | ⚠️ **实际后果有限**：上游被限到 ≤18 事件/帧、排空能力 ≈29 事件/帧 ⇒ 队列稳定，18 条突发 630 clk < 1024 ⇒ 实际仍在一帧内。但契约与注释必须改成 **≤35 拍** |
| **附带** | 自检 :626-628 用 `POLY_TARGET+4` 判"扫不完一帧"，**既没算 FIFO 排空、又硬编码 1024**（note_manager 没有 `CLK_PER_SAMPLE` 参数） |
| **验证方法** | tb 计数 `note_valid_i` 上升沿 → `voice_gate_o` 对应位上升沿的 clk 数 |

## H. 🟡 同一 always 块内**多处写同一个 `gate_r` 位**，正确性靠"书写顺序"而非显式设计

| 项 | 内容 |
|---|---|
| **位置** | (f) 段 :475 / :483 / :488 **vs** (g) 段 :516（note_off 清）/ :524（重触发压低）/ :559（提交抬高） |
| **为什么可疑** | Verilog 语义 = 同块内**后写覆盖先写**。(f) 在 (g) 之前 ⇒ **note_off 赢过 RT_HIGH 的抬高**（:488 写 1，:516 写 0 ⇒ 结果 0 ✅），`retrig_state` 也由 :518 覆盖 :489（结果 RT_NONE ✅）。**这两条正确性完全依赖"case 必须写在 (f) 之后"** |
| **后果** | 一旦有人把 (f) 段下移到 `case` 之后、或把两段拆成两个 `always` 块 ⇒ **note_off 被 RT_HIGH 抬回去 ⇒ 立刻变成"按了也关不掉"的挂音**。这是**结构性脆弱点**，且没有任何注释或断言保护 |
| **验证方法** | 把 (f) 段整体下移到 `case` 之后，跑 `tb_nm_leak` ⇒ 预期立刻出现"清不掉的 gate"（可作为回归哨兵） |

## I. 🟡 真正的 Fmax 关键路径 = `retrig_idx` → `hold_mask` → `gate_mask` → 32 个 voice 的 CE

| 项 | 内容 |
|---|---|
| **位置** | :206-209（掩码）、:456-469（(d)/(e) 的 for 循环里 `gate_mask[i]`/`live_mask[i]` 就是 `vel_r`/`phase_r` 的 CE）、:514-516（`gate_r` 的 CE） |
| **为什么可疑** | 与你 `files/00-总览/未完成工作总账.md:350-360` 的 PnR 结论一致：**worst path 起点 = `retrig_idx_4_s0/Q`**，扇出到 32 个 voice 的 CE，slack 只剩 **1.306 ns**（Fmax 53.493 MHz）。路径 = 5 位比较器 ×32 → AND → `gate_mask` → CE 网络。⚠️ 这正是 K-103（96 级、8.4 MHz）的**残留形态**：扫描被串行化了，但**掩码扇出没动** |
| **后果** | 任何新增逻辑都可能重新触发 setup 违规；`synth_check` 只跑 `run syn` 看不到（K-104） |
| **⭐ 对 S4 有用** | 改成 **`retrig_low[31:0]` 位图**（每 voice 一位）后，`hold_mask[i] = retrig_low[i]` **直接就是一位** ⇒ **32 个 5 位比较器整体消失** ⇒ 既修 C1/C2，**又把这条关键路径缩短** ⇒ 一举两得 |
| **验证方法** | PnR 报告的 worst path 起点/终点；改前改后对比 slack |

## J. 🟡 `same_idx` 是 32 级串行 mux 链（`always @(*)` 里 for + if）

| 项 | 内容 |
|---|---|
| **位置** | :300-304 |
| **为什么可疑** | :287 的注释说"组合 OR 树，⛔ 无链式依赖 ⇒ 深度 ~5 级"——那只对 `same_valid = \|same_hit`（:295）成立。**`same_idx` 是 32 级优先链**（每级一个 5 位 2:1 mux），且直接喂 ST_DECIDE 的 7 个寄存器 D 端（:524-531）。这正是 T66 要消除的"链式依赖"，只是从 96 级降到 32 级 |
| **后果** | 很可能是仅次于 I 的第二条长路径；50 MHz（20 ns）下 32 级 LUT + 布线有违规风险 |
| **验证方法** | 综合/布局后的 path report 是否出现 `same_idx`；若是 ⇒ 考虑树形优先编码（或复用扫描结构） |

## K. 🟡 `initial` 自检综合时被忽略，且参数校验有 4 个缺口

| 项 | 内容 |
|---|---|
| **位置** | :615-629（以及 clk_gen.v:52-53 已承认"综合工具忽略 initial，上板前必须靠人检查"） |
| **缺口** | ① **没有 `ENV_W >= VEL_W` 检查** —— adsr.v:50 `{velocity_i, {(ENV_W-VEL_W){1'b0}}}` 在 `ENV_W<VEL_W` 时是**负宽度** ⇒ 静默错位/编译错；② :627 **硬编码 1024**（本模块没有 `CLK_PER_SAMPLE` 参数）；③ **漏查 `RESERVED_N == POLY_TARGET`**（会触发 §5-F）；④ 自检只看 `POLY_TARGET+4`，**没算 FIFO 排空**（§5-G） |
| **后果** | 参数配错时**零告警**（K-91/K-107 同族：宽度/参数不够 ⇒ 静默算错） |
| **验证方法** | 改参数跑 elaboration 看 `$display`（仿真有效）；综合报告**看不到任何提示** ⇒ 必须人工审 |

## L. 🟡 `KIND_PLUCK` 在 note_manager 内是死常量 ⇒ pluck 与 note_on 处理完全相同

| 项 | 内容 |
|---|---|
| **位置** | :158（定义 `KIND_PLUCK=2'd2`）；全文只有 :510 比较 `KIND_OFF`；`KIND_ON`(:156) 也**从未被引用** |
| **为什么可疑** | `play_mode_ctrl.v:64` 在指板模式确实发 `KIND_PLUCK`，但 note_manager 的 `ST_DECIDE` 只分"off / 其它" ⇒ **pluck 与 note_on 走同一条 ADSR 路径** |
| **后果** | 拨弦拿到的是**持续音 ADSR**（attack 1.6 ms + sustain 保持到 note_off），⛔ 不是"一次性拨弦包络"。若指望它做拨弦音色，会得到"按住就一直响"的行为（`play_mode_ctrl.v:76-81` 在松手时会补发 `KIND_OFF`，所以**不会挂音**） |
| **验证方法** | tb 发 `kind=2`，观察 gate 是否保持到 note_off（预期：保持） |

## M. 🟡 `vel_upd` 只增不减，且 top.v 已硬接 0 ⇒ (d) 段在交付配置下是死逻辑

| 项 | 内容 |
|---|---|
| **位置** | note_manager.v:**456-461**（`if (vel_upd_value_i > vel_r[i])`，无 else ⇒ 保持）；top.v:**2329** `.vel_upd_valid_i (1'b0)` |
| **后果** | ① **力度响应（评分点）当前完全不生效**；② 恢复时注意 `sustain_level` 也由 velocity 派生（adsr.v:50-52）⇒ 改 vel 会让 sustain 目标**跳变** ⇒ 音量起伏（top.v:2320-2324 已记录该机理） |
| **验证方法** | 读 top.v:2329；上板 A/B 轻按/重按的响度 |

## N. 🟡 `pitch_upd` 会改写**正在 RT_LOW 的 voice** 的 `phase_r`

| 项 | 内容 |
|---|---|
| **位置** | :465-469（判据用 `live_mask`，**含 `hold_mask`**） |
| **后果** | 重触发那一下刚在 :528 写好的 `phase_r` 可能被随后到达的同轴 `pitch_upd` 覆盖（滑音语义上也许正是想要的，但要明确）。同轴 `vel_upd` 用的是 `gate_mask`（:458）⇒ **两条修正通路的判据不一致**（一个含 hold 一个不含） |
| **验证方法** | tb 在 RT_LOW 窗口内发同轴 `pitch_upd`，检查最终 `phase_r` |

## O. 🟡 `age_r` 饱和 ⇒ 长按 1.34 s 后"最老"判据退化

| 项 | 内容 |
|---|---|
| **位置** | :391-394（饱和于 `{AGE_W{1'b1}}`） |
| **后果** | 1.34 s 后多个 voice 的 age 全 = 0xFFFF ⇒ 抢占 class 2 的"最老"失效，退化为"最低索引优先"（:330-335 的并列规则）。⚠️ 不是 bug，但"最老优先"的语义在长按场景不成立 |
| **验证方法** | 长按 >1.34 s 再触发抢占，看被抢 voice 的索引是否恒为最小 |

## P. 🟡 `ST_SCAN` 期间不重采样 env/age ⇒ 扫描结果可能内部基准不一致

| 项 | 内容 |
|---|---|
| **位置** | :541-549（`best_env`/`best_age` 在各自那一拍采样）；`env_level_i`/`age_r` 只在 tick 变（:391-394 / adsr） |
| **为什么可疑** | 扫描 32 拍，而 tick 每 1024 拍来一次 ⇒ 扫描跨 tick 的概率 ≈ 32/1024 ≈ 3% |
| **后果** | 前半段采的 env/age 与后半段不同基准 ⇒ 选出的"电平最低/年龄最老"可能不是真最优（偏差 1 个 tick 的步进：env ±669 或 age ±1）⇒ 影响极小，属可接受 |
| **验证方法** | 构造 tick 落在扫描中间的场景，对比"选中 voice"与"真实最优" |

## Q. 🟡 纪律自相矛盾：头注释禁"对 integer 参数位选"，代码却做了两处

| 项 | 内容 |
|---|---|
| **位置** | 头注释 :56（`⛔ 不对 integer 参数做位选（K-91）`）vs 代码 **:230** `fifo_cnt == FIFO_DEPTH[FW:0]`、**:550** `scan_cnt == SCAN_LAST[SW-1:0]` |
| **后果** | 常量位选在 Verilog-2001 里合法，实际大概率无害；但**与自定纪律冲突**，且 K-91 的失效模式正是"整个模块被丢弃而仿真全绿" |
| **验证方法** | 综合日志里确认 `note_manager` 存在（未被 drop）；或改成 `localparam [FW:0] FIFO_DEPTH_V = FIFO_DEPTH;` |

## R. 🟡 adsr 的 `default:` 分支不可达 + 缺"强制归零"外部入口

| 项 | 内容 |
|---|---|
| **位置** | adsr.v:**130-134**（2 位 `state` 的 4 个编码已被占满 ⇒ default 永不执行）；:56-69（唯一外部复位入口是 `retrig_reset_i`，且它把状态设成 `ST_ATTACK` 而非 `ST_IDLE`） |
| **后果** | ① default 给人"有兜底"的错觉，仿真里的 X 传播不会因此被清掉；② 没有"立刻静音并回 IDLE"的入口 ⇒ note_manager 只能靠"gate↓ + 等 release"或"retrig_reset + 立刻 gate↓"来静音（后者会先起一个 attack 再从 0 release，见 C1 推演） |
| **验证方法** | 代码审阅即可 |

---

# 6. 已知行为（不是 bug 但要知道）

| # | 行为 | 数值/依据 |
|---|---|---|
| 1 | `sample_tick` 周期 | 1024 clk = **20.48 µs**（fs = 48.828 kHz），clk_gen.v:104 |
| 2 | ⭐ release 时间常数 | sustain→0 = **131.1 ms**；peak→0 = **524.3 ms**（`RELEASE_STEP=2`）⇒ **判"挂死"必须静默 >524 ms**（与 `排查计划…:186` 一致） |
| 3 | attack / decay | **1.58 ms** / **196.6 ms** |
| 4 | ⭐ sustain = peak/4（**−12 dB**） | `SUSTAIN_Q8=64` ⇒ `sustain_level = peak×64>>8`（adsr.v:51-52）⇒ 按住时比 attack 顶点低 12 dB |
| 5 | 分配延迟 | ≤**35 拍 = 0.70 µs**（头注释写 34，见 §5-G） |
| 6 | 重触发窗口 | `RT_LOW + RT_HIGH ≤ 2048 clk = 41 µs`（:474-490） |
| 7 | ⭐ gate 生效时刻 | 任何 `gate_r` 变化，ADSR **最晚下一个 tick 才看见**（≤20.48 µs）⇒ 事件到"听见 attack"最坏 ≈ 35 拍 + 1 帧 ≈ **21.2 µs** |
| 8 | 抢占优先级 | ① 空闲 > ② release 中 env 最低 > ③ age 最老；同类并列取**最低索引**（:324-335, :543-549） |
| 9 | ⭐ 池隔离 | `RESERVED_N=5` ⇒ voice **27..31 只服务 axis ≥14**；普通轴永远拿不到 27..31（:277-285）⇒ 你的"发现 1/2"最多污染 5 个 voice（§5-C3） |
| 10 | 同轴多次按下会产生多个同轴 voice | `same_hit` 只认 `gate_mask=1`（:292）⇒ release 中的旧 voice 不被复用 ⇒ 快速同键连按会**堆叠同轴 voice**（直到 note_off 一次清光 :514-516） |
| 11 | `age_r` 饱和 | 65535 tick = **1.34 s**（:391-394） |
| 12 | FIFO | 深度 32，最坏突发 18 ⇒ 正常不丢；**但丢了也看不见**（§5-D） |
| 13 | 力度修正 | 当前**被 top 关闭**（top.v:2329） |
| 14 | `note_off` 语义 | 清**所有**同轴且 `gate_mask=1` 的 voice（:514-516，防挂音的冗余设计）⇒ 不会漏清 |
| 15 | 复位 | 同步低有效（:350-385）；`note_manager` 硬清所有 `gate/axis/phase/vel/timbre/age` + FIFO + FSM |
| 16 | `voice_axis_o`/`voice_age_o` | 释放后**不清零**（残留最后一次分配值），是诊断口，别当"当前音"用 |

---

## 给 S4 的一句话建议（仅分析，未改任何文件）

优先级：**① 保留轴/no-note_off（你的发现 1/2）→ 挂音** ；**② A/B（retrig_reset 漏采，1 拍脉冲 + RT_LOW 第一拍窗口）→ 尖音** ；**③ C1/C2（`retrig_low[31:0]` 位图）→ 丢音 + 同轴双分配，且顺带提 Fmax** ；**④ D（把 `event_lost_*` 接出去）→ 恢复 K-106 纪律**。
⚠️ 不要指望"每 voice 一套 retrig"能修挂音——挂音的 voice 其 `gate_mask`/`axis_r` 都是完好的（C1 已推演）。

（本次全程只读：未修改任何文件、未运行任何长任务。）
