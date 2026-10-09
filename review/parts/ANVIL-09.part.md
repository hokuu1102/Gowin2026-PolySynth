@@@PRIO=P1|SRC=ANVIL-09|ORIG=ANVIL09-01|MOD=rtl/w3c/drum_gen.v,rtl/w3c/beat_gen.v
### 让 drum_gen 忽略 tick_cnt 的回退，别再在开鼓机时多发一条网格外事件
- **位置**：rtl/w3c/drum_gen.v:357-358、:438、:445-453、:425-432；rtl/w3c/beat_gen.v:199-204；rtl/top.v:782、:1505、:551-554、:760
- **现状**：
```verilog
// rtl/w3c/drum_gen.v:357-358
wire step_advance = transport_i & ((tick_cnt_i - tick_at_step_q) >= TPS_C);
// rtl/w3c/beat_gen.v:199-204
if (pos_reset_i) begin ... tick_cnt_q <= 16'd0; tick_cnt_o_q <= 16'd0; ... end
```
- **为什么是问题**：链路逐行：①rtl/top.v:782 `wire met_start = met_on_r & ~met_on_r_d;` → :1505 `.pos_reset_i (met_start)` ⇒ 每次"打开"节拍器/鼓机（按 S2/AB13，或串口 'B'；`met_on_r` 的上升沿）都会发一个 1 拍宽的 `pos_reset` 脉冲（top.v:551-554 是 met_on_r 的翻转寄存器，:760 的注释确认这个上升沿脉冲就是本机制的设计意图）。②beat_gen.v:199-204 ⇒ `tick_cnt_o` 在那一拍立刻跳回 0（⛔ 不是等到下一个 tick）。③drum_gen.v:357-358：`tick_cnt_i` 与 `tick_at_step_q` 都是 `[15:0]` ⇒ `0 - 240 = 65336 ≥ 240` ⇒ 🔴 **假推进**（drum_gen.v:33-35 的头部恰好把这条差值法论证成"天然容忍跨小节跳变" —— 它容忍的是向前回绕，⛔ 不是向后跳变）。④drum_gen.v:438 装载 `mask_next` → :445-453 下一拍发出 ⇒ 多一条事件。⑤真正的复位要等下一个 tick（beat_gen 相位已被清 ⇒ 约 0.52 ms 后）：`tick_cnt_o=0` + `bar_start_o=1` ⇒ drum_gen.v:425-432 把 `step_q` 归 0、装载 step 0 ⇒ 强拍正常。仿真复现（探针 + 对照，C83 口径：未修复代码必须输出不同，`iverilog -g2012 -o probe.vvp rtl/w3c/beat_gen.v rtl/w3c/drum_gen.v build/review_anvil09/tb_posreset_probe.sv`，`vvp probe.vvp` vs `vvp probe.vvp +NORESET`）：DUT（发 pos_reset，1 拍）复位前 `tick_cnt=300 step_q=1 evt=2`，复位后 1 个 tick 窗口内 🔴 **+1 条**（`t=156770830000`，复位后 **50 ns**，`inst=HiHat`，`step_q=2`）⇒ **DEFECT REPRODUCED**；对照（+NORESET）✅ **+0 条**，`step_q` 仍 = 1 ⇒ PASS。随后（复位后 520.87 µs）下一个 tick 把 `step_q` 归 0，正常发出强拍 Kick + HiHat（日志 evt #4/#5）。影响面（已核实）：rtl/top.v:131 `parameter integer SEL_DRUM = 1` ⇒ 交付默认档 = 鼓机（top.v:111-116 记录：2026-09-30 深夜用户裁定）⇒ 这条路径在默认档是可听的；幅度：多出的一下比强拍早 ≈**0.52 ms**（120 BPM 下一个 16 分音符 = 125 ms ⇒ 约 0.4%），乐器 = `step_q+1` 那一件 ⇒ 听感是紧 flam / 强拍前的一记双击（若那一件与强拍同乐器则表现为加厚/毛刺）；同一根因还污染 `evt_cnt_o`/`step_evt_cnt_o`/`hit_cnt_o`（多计 1 条、短暂报错步号）；`SEL_DRUM=0`（节拍器档）时 drum_gen 的事件被 top.v:3867 的源 B 二选一挡掉 ⇒ 不可听，但缺陷仍在（每次 'B' 都发生）。
- **改法**（三选一，按代价排序）：①⭐ drum_gen 增加 `pos_reset_i` 端口（与 beat_gen 同源），复位时清 `pending_q`/`step_q`/`tick_at_step_q` —— 语义最干净。②⭐ drum_gen 改用有符号/带方向判据，例如 `(tick_cnt_i >= tick_at_step_q) && (tick_cnt_i - tick_at_step_q >= TPS_C)` —— 一行改动，把"回退"排除掉。③⚠️ beat_gen 在 `pos_reset_i` 当拍额外发一个 `bar_start_o`（见 ANVIL09-02）—— 会改变"第一个 tick 才是强拍"的既有验收行为，⚠️ 需复核 tb_beat_gen / tb_met_start_top。📌 建议做 ①+②（接口补齐 + 判据加固）；只做 ② 能消除症状，但下游仍拿不到"位置复位"这件事。
- **预期**：消除默认档（SEL_DRUM=1）每次开鼓机时强拍前 0.52 ms 的一记多余鼓击（紧 flam），并让三个计数器不再虚增 1；代价 = ①新增端口与清位（~3 行）或 ②一行判据加固。
- **怎么验**：`build/review_anvil09/tb_posreset_probe.sv` 探针：修复后 DUT 必须输出 +0 条（与 `+NORESET` 对照一致）；再跑 `-Filter drum`、`-Filter beat` 全绿。
- **来源**：ANVIL-09【ANVIL09-01】
@@@END
@@@PRIO=P2|SRC=ANVIL-09|ORIG=ANVIL09-02|MOD=rtl/w3c/beat_gen.v
### 让 beat_gen 的位置复位输出一个显式事件（它是 01 的根因）
- **位置**：rtl/w3c/beat_gen.v:199-204、:43-45、:24-27；rtl/top.v:1505
- **现状**：
```verilog
// beat_gen.v:199-204 清 tick_cnt_q / tick_cnt_o_q / beat_cnt_q / bar_cnt_q，
// 但不置 tick_q、不置 bar_start_q
// 头部 :43-45 说"二者的变化都必须在【边沿时刻】被捕获（约定 4）"
```
- **为什么是问题**：结果：`tick_cnt_o` 是"位置"信号，却在位置真正归零之前 **0.52 ms** 就报 0；这段窗口里没有任何事件能告诉下游"发生了一次跳变"。头部 :43-45 说"二者的变化都必须在边沿时刻被捕获（约定 4）"，但 `pos_reset` 这条恰恰没有边沿输出。头部 :24-27 自述 `tick_cnt` 是 looper 事件记录的骨架（`tick[15:0]` 时间戳）⇒ ⚠️ looper 侧需复核：它同样只能看到 `tick_cnt` 回退（本条超出本次审查的四个文件范围，仅登记）。
- **改法**：`pos_reset_i` 当拍输出一个显式脉冲（复用 `bar_start_o`，或新增 `pos_reset_o`），并在文件头把"位置复位是事件、不是电平"写成契约。
- **预期**：下游（drum_gen / looper）能区分"回绕"与"回退"；代价 = 一个输出脉冲或复用已有信号。
- **怎么验**：新探针断言 `pos_reset_i` 当拍必须有脉冲输出；`-Filter beat`、`-Filter looper` 全绿。
- **来源**：ANVIL-09【ANVIL09-02】
@@@END
@@@PRIO=P2|SRC=ANVIL-09|ORIG=ANVIL09-03|MOD=rtl/w3c/perc_env_bank.v,rtl/top.v
### 裁定保留池 voice 要不要释放，并把 perc_env_bank 头部改成与接线一致
- **位置**：rtl/w3c/perc_env_bank.v:33-38、:76；rtl/top.v:4124、:4346、:4359、:1458；rtl/w3b/note_manager.v:532；rtl/w3c/metronome.v:169；rtl/w3c/drum_gen.v:96
- **现状**：
```
perc_env_bank.v:33-38 自述："`active_o` **必须**在衰到 0 时**准确落下**：`note_manager` 用 `env_active_i` 判'这个 voice 还在不在响'（`live_mask`）
                        ⇒ 若 `active_o` 一直为 1，那个 voice **永远不释放** ⇒ **挂音**"
top.v:4124  .env_active_i (env_active)   ← 来自 envelope_bank 的 ADSR（top.v:1458），⛔ 不是 perc_active
top.v:4346  .active_o (perc_active)      —— perc_active 只出现在声明与端口两处，无任何消费者
note_manager.v:532  live_mask = gate_r | hold_mask | env_active_r | sus_hold_r
```
- **为什么是问题**：`live_mask` 里 `gate_r` 对保留池**恒为 1**（metronome/drum_gen 只发 `note_on`，`EVT_KIND=2'd0`，永不发 `note_off`，见 metronome.v:169 / drum_gen.v:96）⇒ **即使把 `perc_active` 接上，也释放不了那个 voice** ⇒ 结论：**"一击到底 ⇒ 自动释放 voice"这条设计意图并没有实现**。当前"不再挂音"的可听效果，来自 top.v:4359 把保留池电平换成 `perc_level`（衰到 0 ⇒ 不发声），⛔ 不是来自 voice 释放。影响：保留池 voice 的 `free_mask` 恒 0（专用池，对键盘无抢占影响 ⇒ 目前无功能后果），但契约、可观测性、以及"这个模块为什么存在"三者都没落地（K-144 家族：建好了但没接上）。
- **改法**：决定"保留池 voice 到底要不要释放"。若维持现状，**必须改 perc_env_bank.v:33-38 的头部**（把"防挂音"改成"防可听挂音"，并写明 `active_o` 未接、`gate_r` 恒 1）—— 否则下一个人会照着这条注释去查一个不存在的机制。
- **预期**：契约与接线一致；代价 0（只改注释）或按裁定新增释放路径。
- **怎么验**：`Select-String -Path rtl\top.v -Pattern 'perc_active'` 命中数与注释口径一致；`-Filter perc_env`、`-Filter note_manager` 全绿。
- **来源**：ANVIL-09【ANVIL09-03】
@@@END
@@@PRIO=P2|SRC=ANVIL-09|ORIG=ANVIL09-04|MOD=rtl/w3c/metronome.v,rtl/w3c/drum_gen.v,rtl/w3c/beat_gen.v,rtl/w3c/perc_env_bank.v,rtl/top.v
### 把四个节奏模块的 K-106 可观测输出挂到串口探针
- **位置**：rtl/w3c/metronome.v:188-189、:192；rtl/w3c/drum_gen.v:121-125；rtl/w3c/beat_gen.v:84、:87；rtl/w3c/perc_env_bank.v:76-81；rtl/top.v；对照 rtl/w3c/span_probe.v、rtl/w3c/pos_probe.v
- **现状**：
```
| 输出 | 文件:行 | top.v 里的引用数 | 备注 |
| met_cfg_warn | metronome.v:192 | 2（声明+端口） | 常量比较 ⇒ 综合必然消失 |
| met_beat_cnt / met_accent_cnt | metronome.v:188-189 | 各 2 | 无消费者 |
| drm_cfg_warn | drum_gen.v:125 | 2 | 同上 |
| drm_evt_cnt / drm_step_cnt / drm_hit_cnt / drm_step_evt_cnt | drum_gen.v:121-124 | 各 2 | 无消费者 |
| bg_bar_cnt / bg_wrap | beat_gen.v:84,87 | 各 2 | 无消费者 |
| perc_active / perc_busy / perc_retrig_cnt | perc_env_bank.v:76-81 | 各 2 | 无消费者 |
```
- **为什么是问题**：四个文件头都写了 K-106 纪律（"容量有限/会静默失效的东西必须可观测"）并都提供了输出端口，但机械核对（grep 全 rtl/top.v，只命中声明与例化端口）⇒ **交付的位流里没有任何一条路径能读出这些值**。项目已有专门的可观测性通路（rtl/w3c/span_probe.v / pos_probe.v 走串口），这四个模块的对应值一条都没接。
- **改法**：至少把 `cfg_warn`（4 处）与 `drm_evt_cnt` / `bg_wrap` 挂到一个串口探针字节上。
- **预期**：上板能看见"参数配错"这类失效（本项目 K-106/K-107 反复吃亏的那一类）；代价 = 复用已有探针通路。
- **怎么验**：串口探针输出里能读到这些字段；`-Filter metronome`、`-Filter drum`、`-Filter beat`、`-Filter perc_env` 全绿。
- **来源**：ANVIL-09【ANVIL09-04】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-05|MOD=rtl/w3c/metronome.v
### 在 metronome 头部写明交付档是 220/132（不是 180/108）
- **位置**：rtl/w3c/metronome.v:133-166、:167-168；rtl/top.v:1549-1550、:1545
- **现状**：
```verilog
metronome.v:167-168：VEL_ACCENT = 8'd180 / VEL_NORMAL = 8'd108
metronome.v:133-166 用整段推导论证"抬到 180 仍然安全（最坏 85.0% FS < 软膝 87.5%）"
交付档（top.v:1549-1550）：.VEL_ACCENT (8'd220) / .VEL_NORMAL (8'd132)
top.v:1545 自己算出 220 ⇒ 92.7% FS ⇒ 已进软膝
```
- **为什么是问题**：头部结论对交付值不成立；下一个调音量的人若只读 metronome.v，会以为"当前 180、有 2.5% 余量"。
- **改法**：在 metronome.v 头部显式写"交付档由 top.v 覆盖为 220/132，本节的 180 推导只对模块默认值成立"，或把交付值移回模块默认值（⛔ 但后者会改变已上板确认的响度，需用户拍板）。
- **预期**：消除"照头部推理 ⇒ 判断错方向"；代价 0（改注释）。
- **怎么验**：`Select-String -Path rtl\w3c\metronome.v -Pattern '220|132'` 在头部命中。
- **来源**：ANVIL-09【ANVIL09-05】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-06|MOD=rtl/w3c/drum_gen.v
### 补上 drum_gen 头部嗵鼓清单漏掉的 step 11
- **位置**：rtl/w3c/drum_gen.v:226-228（头部汇总）、:237-332（4 张表）、:309（pat3 自己的注释）
- **现状**：
```
drum_gen.v:226-228：*"本表里嗵鼓只出现在 step 8 / 14 / 15 / 16（1 基）"*
机械解码 :237-332 的 4 张表（脚本按 `4'dN: m = 4'bXXXX;` 逐格解析）：
pat0: Kick[1/5/9/13] Snare[5/13] HiHat[1/3/5/7/9/11/13/15] Tom[]              pop=14
pat1: Kick[1/5/9/13] Snare[5/13] HiHat[3/7/11/15]           Tom[8/16]         pop=12
pat2: Kick[1/7/9/15] Snare[5/13] HiHat[1/3/5/7/9/11/13/15]  Tom[14]           pop=15
pat3: Kick[1/5/8/9/13] Snare[5/13] HiHat[1/3/…/15,16]       Tom[8/11/14/15/16] pop=21
ALL TOM STEPS (1-based, unique): 8,11,14,15,16
```
- **为什么是问题**：四个分型注释与表逐格一致 ✅；只有文件头那句汇总错了（漏 `11`）。pat3 自己的注释（:309）写的是 `8/11/14/15/16` ✅ ⇒ 同文件内两处互相矛盾。注：用户强调的"嗵鼓⛔ 不能落在每一拍上"这条仍然满足（8/11/14/15/16 都不是 1/5/9/13）✅ —— 本条只是文档缺陷。
- **改法**：把 :226-228 的汇总改成 `8/11/14/15/16`。
- **预期**：注释与表一致；代价 0。
- **怎么验**：机械解码脚本重跑，头部清单 == `ALL TOM STEPS`。
- **来源**：ANVIL-09【ANVIL09-06】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-07|MOD=rtl/w3c/drum_gen.v,rtl/w3c/metronome.v,rtl/w3c/perc_env_bank.v
### 去掉四处对 integer 参数的位选（K-91 同族）
- **位置**：rtl/w3c/drum_gen.v:130、:399（文件头 :55 声明纪律）；rtl/w3c/metronome.v:198（文件头 :196-197）；rtl/w3c/perc_env_bank.v:149、:153（文件头 :45）；对照 rtl/w3c/drum_gen.v:129 的 TPS_C 写法
- **现状**：
```
| 文件:行 | 代码 | 同一文件头的声明 |
| drum_gen.v:130 | localparam [3:0] STEPS_C = STEPS[3:0]; | :55 "⛔ 不对 integer 参数做位选（K-91）⇒ 先落到定宽 localparam" |
| drum_gen.v:399 | assign evt_axis_o = AXIS_ID[AXIS_W-1:0]; | 同上 |
| metronome.v:198 | localparam [AXIS_W-1:0] AXIS_V = AXIS_ID[AXIS_W-1:0]; | :196-197 "⛔ 不能对 integer 参数直接做位选 —— 先经一个显式定宽的 localparam 落成向量再用"（⚠️ 但右边仍是位选） |
| perc_env_bank.v:149,153 | if (level_r <= DECAY_STEP[ENV_W-1:0]) / level_r - DECAY_STEP[ENV_W-1:0] | :45 "⛔ 不对 integer 参数做位选（K-91 顺带发现）" |
```
- **为什么是问题**：诚实口径：实测 Gowin 当前接受（这四个模块都在交付设计里、PnR 通过）⇒ **无功能后果**；且项目内部对"常量位选是否合法"本身有两种说法（files/20-代码/审计-note_manager与ADSR-20260928.md:369-370 判"合法、大概率无害"；已知问题与风险清单.md 的 K-91 条判"Verilog-2001 同样非法"）。但既然 K-91 的失效模式是"整个模块被静默丢弃"，最省事的做法是去掉位选（`localparam [3:0] STEPS_C = STEPS;` 即可，⛔ 不需要 `[3:0]`）—— 与 drum_gen.v:129 的 `TPS_C` 写法一致 ✅。
- **改法**：四处改成不带位选的定宽 localparam（`localparam [3:0] STEPS_C = STEPS;` 等）。
- **预期**：纪律与代码一致；代价 0（编译期常量）。
- **怎么验**：`Select-String` 四处位选消失；`-Filter drum`、`-Filter metronome`、`-Filter perc_env` 全绿。
- **来源**：ANVIL-09【ANVIL09-07】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-08|MOD=rtl/w3c/metronome.v
### 删掉 metronome 的死线网 is_normal 并修正过期行号
- **位置**：rtl/w3c/metronome.v:204、:130；tb/w3c/tb_metronome.sv:253、:256
- **现状**：
```verilog
204: wire is_normal = beat_i & ~bar_start_i;   // 全文件仅此 1 次引用（机械计数）⇒ 死线网
130: 注释引 tb/w3c/tb_metronome.sv:249 / :252
实测该 tb 里比较 u_met.VEL_ACCENT/VEL_NORMAL 的两行是 :253 / :256（Select-String 实测）
```
- **为什么是问题**：死线网（真正的判据用的是 `fire_normal`/`is_accent`）；注释里的 tb 行号过期 ⇒ 维护误导。
- **改法**：删掉 `is_normal`（或真用它），把 :130 的行号改成 253/256。
- **预期**：消除死线网与过期行号；代价 0。
- **怎么验**：`Select-String -Path rtl\w3c\metronome.v -Pattern 'is_normal'` 只剩注释或全空。
- **来源**：ANVIL-09【ANVIL09-08】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-09|MOD=rtl/w3c/beat_gen.v
### 处理 beat_gen 的死逻辑 run_d（头部给的理由不成立）
- **位置**：rtl/w3c/beat_gen.v:123（声明）、:186、:195（赋值）、:125-130（头部理由）
- **现状**：
```
beat_gen.v:123 声明、:186 / :195 各赋值一次，从不被读（机械计数：run_d 5 次命中全部是声明/注释/赋值）
:125-130 头部称它"必须保留：① 是'边沿时刻已采样'的硬件证据；② 下游（节拍器/鼓机的 run 边沿）需要它"
```
- **为什么是问题**：它不是输出端口，下游物理上拿不到；同一段又承认"Gowin 会因未被使用把它优化掉" ⇒ 两句话自相矛盾。
- **改法**：要么删掉，要么把它变成真端口（若确有下游需求）。
- **预期**：消除死逻辑与自相矛盾的注释；代价 0。
- **怎么验**：`Select-String -Path rtl\w3c\beat_gen.v -Pattern 'run_d'` 只剩一处（或全空）。
- **来源**：ANVIL-09【ANVIL09-09】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-10|MOD=rtl/w3c/perc_env_bank.v
### 让 busy_o 与 active_o 语义真正分开（或合并成一个输出）
- **位置**：rtl/w3c/perc_env_bank.v:113-114、:47、:76
- **现状**：
```verilog
113-114: assign active_o[pi] = active_r;  /  assign busy_o[pi] = active_r;   ⇒ 同一根线
:47 把 busy_o 描述成"还有几个在衰减"；:76 把 active_o 描述成"1 = 还在响"
```
- **为什么是问题**：二者被写成不同语义，实际是冗余输出（`active_r` 在"装载相位"也是 1，并不严格等于"在衰减"）。
- **改法**：让 `busy_o` 只在"已装载且仍在衰减"时为 1（`active_r & ~load_r`），或合并成一个输出。
- **预期**：诊断输出语义与文档一致；代价 ≈1 个 AND/位。
- **怎么验**：新断言：装载相位 `busy_o == 0` 而 `active_o == 1`；`-Filter perc_env` 全绿。
- **来源**：ANVIL-09【ANVIL09-10】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-11|MOD=rtl/w3c/drum_gen.v
### 把 drum_gen 的赋值顺序依赖写成显式表达式，并给"16 步=1 小节"加自检
- **位置**：rtl/w3c/drum_gen.v:430、:438、:449、:406；rtl/w3c/beat_gen.v:93；rtl/top.v:1612；tb/w3c/tb_drum_gen.sv:223、:243-249、:36
- **现状**：
```verilog
drum_gen.v:430  pending_q <= mask_step0
drum_gen.v:438  pending_q <= mask_next
drum_gen.v:449  pending_q <= pending_q & ~drum_sel
（三者在同一个 always 块里 ⇒ Verilog 语义"后写胜"）
drum_gen.v:406  cfg_warn_o 只查 RESERVED_N < 1 / STEPS != 16 / TICKS_PER_STEP < 1
```
- **为什么是问题**：`fire` 与步进/小节对齐同拍时，新一步的掩码被丢弃。当前不可达（`TPS_C=240` ⇒ 每步之间有 240 拍，`pending_q` 早已排空）⇒ 无功能后果；⚠️ 但 tb/w3c/tb_drum_gen.sv:243-249 故意把 `bar_start_i` 拉宽到 2 拍（:223 注释自述"拉了两拍宽"；该 tb 用 `TPS=8`，:36）⇒ 该 tb 的通过恰好依赖"后写胜"这个偶然。反事实实验（已做）：把 :449 改成"步边界那一拍不清"（= 让装载胜）⇒ tb_drum_gen **9 条判据变红**（exit 1），其中判据②直接报 **15 条/小节（期望 14）**、判据③报"step0 的 Kick+HiHat 被吞/重复"、判据⑤报"粘滞"、4 条位精确表判据也红；基线（现 RTL）PASS ⇒ 结论：现 RTL 是对的，但"对"建立在赋值顺序这个隐含前提上（重构时顺序一变，9 条判据全红 —— 好在 tb 抓得住，⛔ 不是静默）。另外"16 步 = 1 小节"（`TICKS_PER_STEP × STEPS == PPQN × BEATS_PER_BAR` = 3840，beat_gen.v:93）这条与 beat_gen 的隐式契约没有 RTL 自检，只在 tb_drum_gen 判据②里守着；改 `TICKS_PER_STEP`（top.v:1612 硬编码 240）会静默截断/提前重启音序。
- **改法**：把优先级写成显式表达式（例如 `pending_q <= fire ? (pending_q & ~drum_sel) : next_pending;`），把意图写进代码；并加 `TICKS_PER_BAR` 形参并自检。
- **预期**：把"依赖非阻塞赋值顺序"变成显式契约；代价 ≈0（等价改写）+ 一条自检。
- **怎么验**：`-Filter drum` 必须 PASS（现基线）；再跑反事实副本（build/review_anvil09/drum_gen_loadwins.v）必须 9 条红 ⇒ 证明判据活着。
- **来源**：ANVIL-09【ANVIL09-11】
@@@END
@@@PRIO=P3|SRC=ANVIL-09|ORIG=ANVIL09-12|MOD=rtl/w3c/perc_env_bank.v
### 给 perc_env_bank 的"单拍触发"契约补一条断言
- **位置**：rtl/w3c/perc_env_bank.v:130-156、:70-71；rtl/top.v:4324；tb/w3c/tb_perc_env_bank.sv
- **现状**：
```verilog
130-156: if (trigger_i[pi]) ... else begin if (load_r) ... end   —— 装载走的是 trigger 的 else 分支
:70-71 引冻结表 §〇 约定 4（trigger 是单拍脉冲）
top.v:4324  perc_trig = nm_gate & ~nm_gate_d（确实是单拍 ✅）
```
- **为什么是问题**：若 `trigger_i[pi]` 连续多拍为高：`load_r` 保持 1，`level_r` 一直不被装载（停在旧值），衰减也被跳过（level 冻结）；直到 trigger 落下才装载并开始衰减。契约上 trigger 是单拍脉冲，且 top.v:4324 确实是单拍 ✅ ⇒ 当前不是缺陷；但模块内没有断言守这条契约。
- **改法**：补一条 `$display` 级别的自检说明，或把装载改成 `if (load_r || trigger_i[pi])`（等价于让触发拍立刻装载，⛔ 但那会改掉"触发后一拍装载"的时序，⚠️ 需重跑 tb_perc_env_bank）。
- **预期**：把"宽触发 ⇒ level 冻结"从隐性变成显式（或直接免疫）；代价 = 一条断言或一处条件。
- **怎么验**：新用例：`trigger` 连续 2 拍为高，断言装载在触发当拍发生（或断言报出契约违反）；`-Filter perc_env` 全绿。
- **来源**：ANVIL-09【ANVIL09-12】
@@@END
@@@TOTAL SRC=ANVIL-09 COUNT=12 P0=0 P1=1 P2=3 P3=8
