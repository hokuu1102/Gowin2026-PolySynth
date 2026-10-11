# `P1-53` —— 参数自检在综合里**根本不执行**（2026-10-11 实测定案）

> ⭐ 本轮把 `P1-53` 从一个"**存疑**"变成"**有决定性实测证据的定案**"，
> ⭐ 并**顺带抓出一个 harness 真缺陷**（⭐ 比 `P1-53` 本身更严重 ✅）。
> ⭐ 所有结论**实测**，⛔ 无推测。

---

## 〇、一句话结论

🔴 **Gowin 综合对"综合期断言"一律【只警告】、⭐ 退出码恒为 `0`** ⇒
⭐ **RTL 层面的"参数错配 ⇒ 构建失败"在本工具链上【做不到】** ✅
⇒ ✅ **唯一可行的路 = RTL 写 `generate` 守卫 ＋ 构建脚本把那条警告【提升为错误】** ✅

⭐ **而做这件事的过程中发现**：🔴 **`pnr_run.ps1` 从来不读 `gowin_build.ps1` 的退出码**
⇒ ⭐ **项目全部 6 道机械门（`exit 5`..`exit 10`）在走 `pnr_run.ps1` 时【都只是提示】** ✅
⇒ ✅ **已修**（⭐ 见 §三）—— ⭐ **这一条比 `P1-53` 本身重要得多** ✅

---

## 一、`P1-53` 原文的问题（⭐ 它说"目前没有任何证据"）

> ⭐ `review/时序与逻辑审查-20261009.md` §一 `[P1-53]` 原文：
> *"日志里只有 `'display' is ignored` 这一类告警，没有 `$fatal` 的记录 ⇒
> **`$fatal` 在 Gowin 综合里到底是"报错退出"还是"和 display 一样被丢掉"，
> 目前没有任何证据**"* ✅

⭐ 本轮**把三种候选写法都实测了一遍**（⭐ 探针都放在 `rtl/w3c/evt_buf.v` 的
`initial` / `generate` 里，⭐ 跑 `bringup/synth_only.tcl`）✅

---

## 二、⭐⭐ 实测结果（⭐ 决定性证据）

| # | 探针写法 | ⭐ 工具反应（⭐ 原文） | ⭐ `gw_sh` 退出码 |
|---|---|---|---|
| ① | ⭐ `initial` 里 `if (1) $fatal(1, "...")` | ⭐ `WARN (EX2488) : Elaboration system task 'fatal' is ignored for synthesis` | 🔴 **0** |
| ①b | ⭐ `initial` 里 `$display("ERROR ...")` | ⭐ `WARN (EX3858) : System task 'display' is ignored for synthesis` | 🔴 **0** |
| ② | ⭐ `generate` 里例化**未声明的模块** | ⭐ `WARN (EX3793) : Instantiating unknown empty module '<名字>'` | 🔴 **0** |
| ③ | ⭐ `generate` 里**负重复次数** `{(1-2){1'b0}}` | ⭐ `WARN (EX2195) : Concatenation multiplier constant must be positive` | 🔴 **0** |

⇒ ⭐⭐ **结论（⭐ 这就是 `P1-53` 要的那个"证据"）**：

```
🔴 Gowin 把【一切】"综合期断言"都降级成 WARN，⭐ 而 gw_sh 的退出码【永远是 0】。
⇒ ⭐ "门① 综合 ERROR=0" ⛔ 拦不住任何参数错配。
⇒ ⭐ 全项目所有 initial 里的 $fatal / $display 防线，
   ⭐ 在【位流生成路径】上【一条都不执行】✅
   （⭐ 含 top.v 的 N4 三条下界 · ⭐ uart_rx.v:196 · ⭐ 各模块的 PARAM_OK ✅）
```

📌 ⭐ **但要说清一件事（⭐ 诚实标注）**：⭐ 这些 `$fatal` **⛔ 不是空的** ——
⭐ `sim/tb_all.ps1` 的回归**会**跑到它们（⭐ `iverilog` **执行** `initial` ✅）
⇒ ⭐ 它们**保护得了仿真、⭐ 保护不了构建** ✅
⇒ ⭐ 这正是 `P1-53` 说的"**两处口径互相矛盾**"的实质 ✅

---

## 三、⭐⭐ 顺带抓出的 **harness 真缺陷**（⭐ 比 `P1-53` 本身严重）

### 现象（⭐ 实测现场）

⭐ 我按 §四 加了守卫之后，用**坏参数**（`TRAVEL_TARE = 12'd0`）跑
`sim/pnr_run.ps1` ⇒ ⭐ `gowin_build.ps1` **确实**打印了：

```
OK  NL0002 gate: 3 swept module(s), all whitelisted
ERROR: EX3793 -- a PARAMETER GUARD fired in synthesis (see P1-53):
WARN  (EX3793) : Instantiating unknown empty module 'P1_53_N4_PARAM_ERROR__...'(...top.v":3122)
```

⇒ ⭐ 并且它**确实 `exit 10`** 了（⭐ 日志在它之后就断了，⭐ 后面 4 道门没跑 ✅）

🔴 **而 `pnr_run.ps1` 仍然报**：

```
attempt 1: 7.4 min | .fs new=True | setup=0 hold=0 | Fmax=56.471 MHz | PASS
PnR PASSED on attempt 1 in 7.4 min
=== pnr_run 退出码 = 0 ===        ← 🔴 门红了，构建却报成功
```

### 根因

⭐ `pnr_run.ps1` 在 `Start-Job` 的最后一句**写了** `"EXITCODE=$LASTEXITCODE"`，
⭐ 而且 `Receive-Job` 也拿到了（⭐ `$jobOut`）——
🔴 **但 `$jobOut` 拿到之后【再也没人用】** ✅

```powershell
    $jobOut = Receive-Job $job -ErrorAction SilentlyContinue     # ← 拿到
    ...
    $ok = $fsNew -and ($setup -eq '0') -and ($hold -eq '0') -and ($fmaxVal -ge $MinFmax)
    #                                                          ↑ 🔴 退出码不在判据里
```

⇒ 🔴 **判据只剩"`.fs` 是新的 ＋ 时序 0/0 ＋ Fmax 够"**
⇒ ⭐ 而这三条**在一道门红了的情况下依然成立**（⭐ 因为门是在 PnR/位流**之后**才跑的）✅

### ⚠️ 危害面（⭐ 这才是重点）

🔴 **这不是只有那道新门受影响** —— ⭐ 项目**全部 6 道门**都在同一处境：

| 退出码 | 门 | 走 `pnr_run.ps1` 时 |
|---|---|---|
| `exit 5` | ⭐ `NL0002`（模块被静默扫掉） | 🔴 **只是提示** |
| `exit 6` | ⭐ `P0-25`（HOLD 余量） | 🔴 **只是提示** |
| `exit 7` | ⭐ `P0-23`（异步复位） | 🔴 **只是提示** |
| `exit 8` | ⭐ `P0-26`（时钟域） | 🔴 **只是提示** |
| `exit 9` | ⭐ `P0-29`（观测线） | 🔴 **只是提示** |
| `exit 10` | ⭐ `P1-53`（参数守卫，本轮新增） | 🔴 **只是提示** |

⇒ 🔴 **"门红了但构建报 PASS"** —— ⭐ 正是本项目最忌讳的
"**判据不可靠**"（⭐ `K-94` / `K-161` / `C83` 同族）✅
📌 ⭐ 而"4 道门全 OK"这句话，⭐ 之前**只有在【人眼看过日志】时才成立** ✅

### ✅ 修法

```powershell
    # ⭐ 从 $jobOut 里取出 EXITCODE= ⇒ ⭐ 非 0 即判该次 attempt 失败 ✅
    $buildExit = $null
    foreach ($line in @($jobOut)) {
        if ("$line" -match '^\s*EXITCODE=(-?[0-9]+)\s*$') { $buildExit = [int]$Matches[1] }
    }
    $exitOk = ($null -ne $buildExit) -and ($buildExit -eq 0)
    ...
    $ok = $fsNew -and ($setup -eq '0') -and ($hold -eq '0') -and ($fmaxVal -ge $MinFmax) -and $exitOk
```

📌 ⭐ **取值缺失也判失败** —— ⭐ 与本文件其它判据**同一条纪律**（⭐ 见 `Get-StatValue`
那两段 NOTE 原文：*"Missing value => the verdict still FAILS, i.e. the safe direction
is preserved"* ✅）
📌 ⭐ 判据行现在也**打印 `buildExit=`** ⇒ ⭐ **一眼看出是哪道门** ✅

---

## 四、⭐ `P1-53` 的修法（⭐ 两层）

### 4.1 ⭐ RTL 层：`generate` 守卫（⭐ RTL 仍是唯一真相源）

⭐ 参数非法时 ⇒ ⭐ `generate` 取**坏分支** ⇒ ⭐ 例化一个**故意不存在**的模块
（⭐ 名字里写着错误内容 ✅）；⭐ 参数合法时 ⇒ ⭐ 该分支**不参与详细阐述** ⇒ ⭐ **零代价** ✅

| 位置 | 守的判据 |
|---|---|
| ⭐ `rtl/top.v`（`g_sound` 内） | ⭐ **N4 的 5 条**：`TRAVEL_TARE`/`EVT_TRIG_TH`/`EVT_REL_TH` 非 0 · 触发阈值 ≤ 行程 · 两条比例带 `[5%,12%]`/`[2%,7%]` ✅ |
| ⭐ `rtl/w3c/evt_buf.v` | ⭐ **DEPTH 是 2 的幂** · ⭐ `DEPTH ≥ 2` ✅ |

⚠️ ⭐ **写法注意（⭐ 本项目约定）**：
· ⭐ `top.v` 的 `g_sound` **已经在 `generate` 区里** ⇒ ⭐ 那里用**裸 `if`**（⛔ 不套 `generate`）✅
· ⭐ `evt_buf.v` 在 `generate` 区**外** ⇒ ⭐ 那里**需要** `generate`/`endgenerate` ✅

### 4.2 ⭐ 构建脚本层：把警告提升为错误

⭐ `sim/gowin_build.ps1` 新增一道门（⭐ 紧接 `NL0002` 门之后）：

```
⭐ 综合日志里出现 `EX3793` ⇒ 🔴 `exit 10`
```

📌 ⭐ **为什么这样比"在脚本里再解析一遍 Verilog 常量"好**（⭐ `P1-53` 的备选方案 2）：
⚠️ 后者要**再实现一遍** RTL 的表达式 ⇒ ⭐ 又多一处"**两处真相**"；
⭐ 本写法**条件只有一份**（⭐ 在 RTL 里），⭐ 脚本只认**工具给的信号** ✅

---

## 五、⭐ 实测验证（⭐ 双向）

| 场景 | ⭐ `gowin_build.ps1` | ⭐ `pnr_run.ps1` |
|---|---|---|
| ⭐ **正常参数** | ⭐ 综合 `OK` · ⭐ 资源**一字不变**（`T_Lut 27655` / `T_Register 17627`）⇒ ⭐ **零代价** ✅ | ⭐ 见 §六 ✅ |
| 🔴 **`TRAVEL_TARE = 12'd0`** | ⭐ `ERROR: EX3793 ...` ⇒ ⭐ **`exit 10`** ✅ | 🔴 **`buildExit=10 \| FAIL`** · ⭐ **退出码 `1`** ✅ |

⭐ **修复前/后对照（⭐ 同一条坏参数）**：

```
修前：attempt 1: 7.4 min | .fs new=True | setup=0 hold=0 | Fmax=56.471 MHz | PASS
      PnR PASSED on attempt 1        ← 🔴 门红了却报成功
      pnr_run 退出码 = 0

修后：FAIL: gowin_build.ps1 exited 10 => a BUILD GATE fired (see the attempt log).
      attempt 1: 11.3 min | .fs new=True | setup=0 hold=0 | Fmax=56.471 MHz | buildExit=10 | FAIL
      PnR FAILED on all attempts.
      pnr_run 退出码 = 1             ← ✅ 门红了就失败
```

---

## 六、⭐ 综合 / PnR / 回归

### ⭐ 综合（⭐ 干净重建的数字口径）

⭐ 加守卫前后 `impl/gwsynthesis/Gowin2026_syn_rsc.xml` **一字不变**：

| 资源 | ⭐ 加守卫前 | ✅ 加守卫后 |
|---|---|---|
| `T_Lut` | 27655 | **27655** ✅ |
| `T_Register` | 17627 | **17627** ✅ |
| `T_Alu` | 8280 | **8280** ✅ |
| `T_Bsram` | 34 | **34** ✅ |

⇒ ⭐ **零代价**（⭐ 因为合法参数下坏分支**不参与详细阐述** ✅）

### ⭐ PnR ＋ 回归（⭐ 正常参数档）

| 项 | ⭐ 值 |
|---|---|
| ⭐ 违例 | ⭐ **`0 setup / 0 hold`** ✅ |
| ⭐ `Actual Fmax` | ⭐ **56.492 MHz**（⭐ 真实余量 **`+2.30 ns`**）✅ |
| ⭐ `CLS` / `BSRAM` | ⭐ **24091/29952 = 81%** · ⭐ 37/118 = 32% ✅ |
| ⭐ `buildExit` | ⭐ **`0`** ✅（⭐ 判据行现在会打印它 ✅） |
| ⭐ `sha256` | ⭐ **`93B1238FA38B9086423AEFA49BB6232959661F6D2826D5D5F1B9A2B404844BD6`** |
| ⭐ 全量回归 | ⭐ **通过 135 / 共 135** ✅ |

### ⭐⭐ 6 道门全 OK（⭐ 逐字，⭐ 含本轮新增的那道）

```text
OK  NL0002 gate: 3 swept module(s), all whitelisted
OK  P1-53 gate: 0 parameter-guard violations (EX3793 absent)      ← ⭐ 本轮新增 · ⛔ 无误报 ✅
    HOLD worst slack = 0.142 ns  (review baseline 0.137)   u_looper hits = 0
OK  P0-25 gate: HOLD worst slack 0.142 ns >= 0.05 ns
OK  P0-23 gate: 0 async-reset sensitivity lists
OK  P0-26 gate: all 2 generated clock(s) have an Fmax row: serial_clk, pixel_clk
OK  P0-29 gate: all 6 critical observability wires have a consumer
=== Gowin build finished, exit code 0 ===
```

⭐ 而判据行现在是：

```text
attempt 1: 7.1 min | .fs new=True | setup=0 hold=0 | Fmax=56.492 MHz | buildExit=0 | PASS
PnR PASSED on attempt 1 in 7.1 min
  setup=0  hold=0  Fmax=56.492 MHz  buildExit=0      ← ⭐ 一眼看出"6 道门真的都过了" ✅
```

📌 ⭐ **`sha256` 与上一轮（`264434DF…`）不同是正常的** —— ⭐ `.fs` 里带构建信息，
⭐ 与本项目早已记录的结论一致（⭐ `交接文档` §五②：*"清空后重跑 ⇒ 时序一字不差 ✅
（只有 sha 不同）"*）✅ · ⭐ 而**资源数与 Fmax 逐字相同**（27655 / 17627 / 8280 / 34 · 56.492）✅

---

## 七、⚠️ 诚实标注（⭐ 未覆盖的部分）

1. ⚠️ ⭐ **本门只能覆盖"已经写了 `generate` 守卫"的参数** ✅
   ⇒ ⭐ 今天只有 **`top.v` 的 N4 五条** ＋ ⭐ **`evt_buf.v` 的 DEPTH 两条** ✅
2. 🔴 ⭐ **其余模块仍是仿真侧防线**（⭐ 只有 `initial` + `$display`/`$fatal`）：
   · ⭐ `rtl/w3a/event_extract.v` · ⭐ `rtl/w3a/axis_snapshot.v` · ⭐ `rtl/w3a/axis_map.v`
   · ⭐ `rtl/w3a/param_extract.v` · ⭐ `rtl/w3c/uart_rx.v` ✅
   ⇒ ⭐ **记入 `P1-53` 的后续**（⭐ 照 §4.1 的写法逐个加即可，⭐ 每个约 5 行 ✅）
   📌 ⭐ 优先级判断：⭐ 上面这些的失效模式**都还没有被证明会咬人**
   （⭐ 而 N4 那三条**已被 `P0-11` 证明会**）⇒ ⭐ 所以先做 N4 ＋ 新模块 ✅
3. ⚠️ ⭐ **`EX3793` 是"未声明模块"的通用警告** —— ⭐ 若将来有人**误写**一个模块名，
   ⚠️ 也会撞上这道门 ⇒ ⭐ **误报方向是"安全"的**（⭐ 会 fail，⛔ 不会漏）✅
   📌 ⭐ 而报错行里**带着那串名字** ⇒ ⭐ 一眼能分辨是"守卫"还是"笔误" ✅
4. ⚠️ ⭐ **本轮未做**：⭐ `P1-53` 备选方案 2（⭐ 在脚本里解析 RTL 常量做体检）——
   ⭐ 已按 §4.2 的理由**主动不选**（⭐ 会造成两处真相）✅
