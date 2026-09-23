# 📣 集成层变更通知 · `top.v` 接入 `evt_merge`（**T36 / U-6**）

> **日期**：2026-09-22（周二）
> **依据**：⭐ **冻结表 §〇 约定 5** —— ⚠️ **改集成层（`top.v`）要通知全员**
> **状态**：✅ 代码已改 · ⏳ **回归 + PnR 验证中**
> **⛔ 我还没有 push** —— 等你确认后再压提交

---

## 〇、⭐ 一句话

⭐ **`top.v` 里原来把两路事件"直接或在一起"，同拍相撞会【静默丢一条】。**
🔴 **这是个真缺陷**（不是优化）⇒ ⭐ **现已换成 `evt_merge` 模块仲裁，两路同拍不丢。**

---

## 一、🔴 改了什么（⚠️ 只动了两个源汇合处）

### 1.1 改动前（有缺陷）

```verilog
.note_valid_i      (demo_note_valid | met_evt_valid),
.note_axis_i       (demo_note_valid ? demo_note_axis : met_evt_axis),
.note_phase_inc_i  (demo_note_valid ? demo_note_inc  : met_evt_inc),
.note_velocity_i   (demo_note_valid ? demo_note_vel  : met_evt_vel),
.note_kind_i       (demo_note_valid ? demo_note_kind : met_evt_kind),
```

🔴 **问题**：`note_manager` **只有一个事件口**，而 `note_valid_i` **只响一拍**
⇒ ⚠️ **两路同拍时 `demo` 赢，节拍器那条事件【永久消失】**
（⭐ `top.v` 原有注释自己也承认了："the metronome event is LOST"）。

⚠️ **为什么以前没暴露**：上电阶段两个源**撞不上**
（演示和弦在 2_000_000 clk、拍点在 ~26042 clk），
🔴 **但真实演奏接上后就会撞** —— ⭐ 这正是 `T36` 一直在账上的原因。

### 1.2 改动后

```verilog
// ⭐ 两路先经 evt_merge，再进 note_manager 的唯一事件口
evt_merge #(.AXIS_W(4), .PHASE_W(32), .VEL_W(8), .KIND_W(2), .DEPTH(4))
u_evt_merge (
    .a_valid_i (demo_note_valid), ...   // 源 A：演示和弦（⭐ 将来接 play_seq 曲谱）
    .b_valid_i (met_evt_valid),   ...   // 源 B：节拍器
    .evt_valid_o (mg_evt_valid),  ...   // ⭐ 合流后 → note_manager
);

.note_valid_i (mg_evt_valid),
.note_axis_i  (mg_evt_axis),
...
```

---

## 二、⚠️ 对你们的影响（**请务必看**）

### 2.1 ⭐ **端口没变、模块边界没变** ⇒ ⛔ 你们**不用改任何东西**

| 项 | 状态 |
|---|---|
| `note_manager` 的端口 | ⛔ **一个没动**（⭐ 改的是它**上游怎么接**） |
| 各模块接口 | ⛔ **没动** |
| 引脚约束 `.cst` | ⛔ **没动** |
| ⭐ 对 `rtl/w3b/*`（乙） | ✅ **零影响** |
| ⭐ 对驱动/采集（丙） | ✅ **零影响** |

### 2.2 ⚠️ 但**行为**上有一处变化（⭐ 需要知道）

| 场景 | 改动前 | 改动后 |
|---|---|---|
| 单路来事件 | 直通 | ⭐ **直通（⛔ 无延迟）** |
| ⭐ **两路同拍** | 🔴 **丢一条** | ⭐⭐ **两条都发**，后发那条**晚 1 拍 = 20 ns** |

> ⭐ **20 ns vs 一个音频帧 20.48 µs** ⇒ ⭐ **相差 1000 倍**，
> ⭐ **听感完全不可分辨**；而"丢一条"是**永久损失**（节拍器少一拍 / 音符不响）。

### 2.3 ⭐ 如果你们的 tb 里例化了 `top`

⚠️ **请重新跑一遍** —— 顶层的事件汇合路径变了。
⭐ 我这边**全量回归会重跑**，⛔ 但你们自己的 tb 我不知道有没有依赖那条路径。

---

## 三、⭐ 新增的文件与证据

| 项 | 内容 |
|---|---|
| ⭐ **新模块** | `rtl/w3c/evt_merge.v`（深度 4 环形 FIFO + 轮转仲裁） |
| ⭐ **单测** | `tb/w3c/tb_evt_merge.sv` —— **8 项判据全过** |
| ⭐ **变异体** | `M64`~`M68` ⇒ **5/5 CAUGHT** |
| ⭐ **设计说明** | `files/20-代码/evt_merge设计说明.md` |

⭐ **核心判据（就是它存在的理由）**：
```
BOTH events survived a same-cycle collision (0 -> 2)
collision payloads intact (axis 1 then 2)
round-robin rotates (A first 2, B first 2)
overflow_o raised under sustained overload
```

⭐ **可观测性**（`K-106` 纪律）：`collision_cnt_o` / `merged_cnt_o` /
`drop_cnt_o` / `overflow_o` —— ⚠️ **溢出⛔ 不会静默**。

---

## 四、⭐ 上线时抓到的三个真 bug（⚠️ 值得你们也看一眼）

| # | bug | ⭐ 现象 |
|---|---|---|
| **1** | 🔴 **`wire push_n` 漏写位宽**（1 bit）⇒ `1+1` 截断成 `0` | ⚠️ **只有"两路同拍"坏，单源完全正常**；⭐ 而同模块的相撞计数**照常 +1** ⇒ **看起来像"相撞被吞"** |
| **2** | 🔴 溢出分支忘了更新计数 ⇒ 计数**永不为 0** | ⚠️ 输出**一直挂着**、吐旧数据 ⇒ **像死锁** |
| **3** | 🔴 `DEPTH[15:0]` 对 `integer` 参数位选（`K-91` 禁止） | ⚠️ **索引比较整块静默失效** |

> ⭐⭐ **第 1 条对你们也有用**：⭐ **`wire` 不写位宽就是 1 位** ——
> ⚠️ 凡是**参与算术**的信号，一律**显式写宽度**。
> ⭐ 而且它**只坏一种输入组合** ⇒ ⚠️ **别的判据全绿也照样漏**
> ⇒ ⭐ **"某种组合才坏"的 bug 必须有专打那个组合的判据。**

---

## 五、⚠️ 另外一件**所有人都要知道**的事

### 🔴 `play_seq.v` 建好后 **PnR 静默没编译它**

⭐ 我新加了 `play_seq.v`，**tb 全绿、回归 34/34**，然后跑 PnR：
✅ **exit 0、0 违规、Fmax 58.310 MHz** ——
⚠️ **但与上一版的数据【逐位相同】**（Fmax 到小数点后 3 位、LUT 数都一样）。

🔴 **根因**：工程文件 `Gowin2026.gprj` 的 `<FileList>` 是**静态列表**，
**新文件不放进去，Gowin 不报错、直接不编译它**。

> ⚠️ **这条你们也会踩**：⭐ **新建 `.v` 之后，必须把它加进 `.gprj`**
> （⚠️ `.sv` 也要写 `type="file.verilog"`），
> ⭐ **并且去综合日志里亲眼看到它的 `Compiling module` 行**。

⭐ **我已加了一道脚本断言**（`sim/gowin_build.ps1`）：
凡 **`top.v` 例化、但不在 `.gprj` 里**的文件 ⇒ **直接 `exit 3`**，⛔ 不许静默继续。

---

## 六、⚠️ 需要你们做的

| # | 事项 | 谁 |
|---|---|---|
| **1** | ⭐ **`git pull --rebase`** 拿到本次改动 | 全员 |
| **2** | ⚠️ **如果你的 tb 例化了 `top`** ⇒ **重跑一遍** | 全员 |
| **3** | ⭐ **新建 `.v` 记得加进 `.gprj`**，并**在日志里确认被编译** | 全员 |
| **4** | ⚠️ **`timbre` 端口**（`evt_timbre_i`）本版**仍未接**（⚠️ 等波表 `T31b`） | 乙 |

---

## 附 · 相关文件

| 想看什么 | 去哪 |
|---|---|
| ⭐ **`evt_merge` 设计说明**（含三个 bug 复盘） | `files/20-代码/evt_merge设计说明.md` |
| 事件格式冻结契约 | `files/20-代码/play_seq接口冻结契约.md` |
| 未完成工作总账 | `files/00-总览/未完成工作总账.md` |
| 新模块 | `rtl/w3c/evt_merge.v` · `tb/w3c/tb_evt_merge.sv` |
