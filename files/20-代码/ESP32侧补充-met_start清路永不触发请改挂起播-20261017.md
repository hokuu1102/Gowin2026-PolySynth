# ESP32 侧补充：`met_start` 清路**在我们的流程里永不触发** ⇒ 请改挂真正的起播信号

> 收件人：FPGA 线
> 触发：核你们 `ef749735`（LED 清路）时发现 —— **清点选错了信号**，该修复对"网页灌谱"路径是**空操作**
> 结论：请把清点从 `met_start` 换成**真正的起播信号**（`CMD_PLAY` / transport start）；
> ⚠️ 否则示范段（`bit6=0`）**依旧不亮**，而且会**第一次播放后永久不亮**（闩锁只 set 不 clear）

---

## 一、你们的清路：`else if (met_start) evt_guide_seen_r <= 1'b0;`

`rtl/top.v`（origin/main）：

```verilog
reg met_on_r;
if (!rst_n_sync)        met_on_r <= 1'b0;
else if (cmd_met_req)   met_on_r <= ~met_on_r;      // ⭐ 只有 'B' 命令（或硬件键）翻转它
reg met_on_r_d;  ...
wire met_start = met_on_r & ~met_on_r_d;            // ⭐ = met_on_r 的【上升沿】1 拍脉冲
...
else if (met_start)     evt_guide_seen_r <= 1'b0;   // ⭐ 你们的清路
```

⇒ `met_start` 的语义是"**节拍器被打开**那一拍" ✗ —— ⛔ **不是** transport 起播 ✗。

## 二、🔴 在"网页灌谱"路径里，`met_start` **永远不会脉冲**

我方实测（`esp32/tools/score_studio.html`，用户的实际路径）：

| 网页发出的东西 | 命令 | 会不会动 `met_on_r` |
|---|---|---|
| 一键上传（先冲缓冲） | `resetSequence()` = 4× `0xA5` 事件帧 | ⛔ 不会 |
| 上传帧总数 / 事件帧 | `0x00` 头 + `0xA5` 事件帧 | ⛔ 不会 |
| **起播** | `CMD_PLAY` | ⛔ 不会 |
| 停止 / 清池 / 状态 | `CMD_STOP` / `CMD_RESET` / `CMD_STAT` | ⛔ 不会 |
| 节拍器 | **⛔ 网页从不发 `'B'`**（实测 `0x42`/`'B'`/`CMD_MET` 命中 **0**） | — |

⭐ **为什么网页不发 `'B'`**：网页的节拍器是**用鼓机事件生成的**（`buildMetronome()`，`srcTrack = -2`）
—— 它跟着谱面变速走，⛔ 不依赖 FPGA 内部那个节拍器 ✗。

⇒ 🔴 **后果**：`met_on_r` 在整条流程里恒 0 ⇒ `met_start` 恒 0 ⇒ **`evt_guide_seen_r` 永不被清** ⇒
`~evt_guide_seen_r` 在第一次播到重复段（`bit6=1`）之后恒 0 ⇒ **示范段（`bit6=0`）永久不亮** ✗
—— ⚠️ 正是用户实测的那个现象（"示范段不亮、重复段亮；复位后仍不亮"）✓

📌 也解释了你们注释里"重播那个场景仍然被 `met_start` 覆盖"为什么**不成立** ✗：
它要求**每次播放都重新开一次节拍器**，而网页路径**一次都不会开** ✗。

## 三、请改挂真正的起播信号

| 候选清点 | 评价 |
|---|---|
| **`CMD_PLAY` / `seq_arb` 起播 / `play_seq` start** | ⭐ **推荐** —— 语义就是"本次演奏开始" |
| `resetSequence`（连续 `0xA5` 冲缓冲）| ⭐ 也可（"换谱"清）—— ⚠️ 但你们注释说"每个新谱都清 ⇒ 两条 tb 必红" ✗，所以**至少要挂起播** |
| `met_start` | 🔴 **不要** —— 它只在"节拍器被打开"那一拍 ✗（网页路径恒 0）|

⚠️ **注意别把清点挂到 `cmd_met_req` 上**（那是 `'B'` 的翻转请求 ✗，与"起播"无关 ✓）。

## 四、请补一条**能红**的判据

```
场景：同一份流【连续起播两次】，中途 ⛔ 不动节拍器（不发 'B'、不按硬件键）
断言：两次的示范段（bit6=0）都必须能点亮
⇒ 按现在的 `met_start` 语义，这条【必红】✓
```

📌 你们现有的 `tb_top_guide_bit6` / `tb_met_start_top` 覆盖不到它 —— 因为它们的 tb 里
**要么显式给了节拍器脉冲、要么只播一次** ✗（典型"判据绿、上板死"）。

---

## 五、一句话

```
清点 = 起播（CMD_PLAY / transport start）
⛔ 不是 met_start（= met_on_r 上升沿，网页路径恒 0）
```
