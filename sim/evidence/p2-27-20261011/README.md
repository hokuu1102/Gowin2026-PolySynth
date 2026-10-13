# `P2-27`：第 1 帧的伪 `delta`（`delta = cur − 0`）⇒ 首帧不出快照（2026-10-11 · ✅ 已修）

> ⭐ 这是 `review/时序与逻辑审查-20261009.md` §二 `[P2-27]` 的处置记录 ✅
> ⭐ **为什么现在做**：⭐ 它是**滑音（阶段 2）的前置** ✅ ——
> ⭐ 审查原文：⭐ *"阶段 2 落地时**不会踩到开机伪滑音**"* ✅

---

## 一、⭐ 缺陷

### ⭐ 链路（⭐ 逐行）

```verilog
// rtl/w3a/axis_snapshot.v
if (!rst_n) begin
    ...
    first_ch_of_frame <= 1'b0;      // 🔴 复位为 0 ⇒ 首帧 ch0 不会锁 prev
end

// :151 —— ⭐ 固化上一帧的唯一入口
if (sample_valid_i && (sample_ch_i == 3'd0) && first_ch_of_frame) begin
    for (wi = 0; wi < AXIS_N; wi = wi + 1) prev[wi] <= cur[wi];
end
```

⇒ ⭐ 第 1 帧的 `ch0` **不满足条件** ⇒ ⭐ `prev` 保持**复位值 0** ✅
⇒ 🔴 **第 1 帧的 `delta = cur − 0 = cur`**（⭐ 最大 **+4095** ✅）

### 📌 ⭐ 为什么"现在"才要修（⭐ 原来无害）

⭐ 现在**没有**消费者用 `delta` ✅（⭐ `P1-27`：⭐ 那条通路**根本没进 bitstream** ✅）

🔴 ⭐ 但**阶段 2 接上滑音后** ✅：
- ⭐ 双音/滑音判据是 **"`dA ≥ 0` 且 `dB ≥ 0`"** ✅
- ⭐ 第 1 帧**所有轴**的 `delta` 都是**大正数** ⇒ ⭐ 判据**全部成立**
- ⇒ 🔴 **上电 / 重标定后多发一个音** ✅（⭐ `P3-19` 同源 ✅）

---

## 二、⚠️ 审查的"简写改法"**不够**（⭐ 实测推理）

⭐ 审查摘要写：⭐ *"把 `first_ch_of_frame <= 1'b1;` 放进复位分支（**一行**）"* ✅

🔴 ⭐ **但只改这一行不够** ✅：

```verilog
// ⭐ 即使复位成 1，⭐ 那一拍 `prev[ch0]` 拿到的还是【旧的】cur（⭐ 非阻塞赋值 ✅）
prev[wi] <= cur[wi];      // ⚠️ 读的是【本拍之前】的 cur
```

⭐ 第 1 帧 `ch0` 到来时，`cur[ch0]` **还没写进**（⭐ 同一个 always、⭐ 非阻塞 ✅）
⇒ ⭐ `prev[ch0]` 拿到的仍是 **0** ⇒ 🔴 `delta = cur − 0` **仍然错** ✅

📌 ⭐ **这正是本项目的老毛病**：⭐ **审查的"诊断"准、"改法"要逐条实测** ✅
（⭐ 交接文档 §五 ③：⭐ 本会话已 **7 次**"诊断对、改法错" ✅ —— ⭐ 这是第 8 次 ✅）

---

## 三、✅ 实际改法（⭐ 让第 1 帧**整个不出快照**）

```verilog
reg primed;                        // ⭐ 复位 = 0

if (!rst_n) begin
    ...
    primed <= 1'b0;
end else begin
    ...
    if (sample_valid_i && (sample_ch_i == 3'd0) && first_ch_of_frame) begin
        for (wi = 0; wi < AXIS_N; wi = wi + 1) prev[wi] <= cur[wi];
        primed <= 1'b1;            // ⭐ 预热完成 ⇒ 从【下一帧】起才出快照
    end
    ...
    snap_valid_o <= last_ch_r & primed;    // ⭐ 第 1 帧被抑制
end
```

⭐ **效果**：⭐ 那个错的 `delta = cur − 0` **永远不会被 `snap_valid_o` 暴露** ✅
📌 ⭐ 从**第 2 帧**起：⭐ `prev` = 第 1 帧、⭐ `cur` = 第 2 帧 ⇒ ⭐ **`delta` 语义正确** ✅
📌 ⭐ 且从第 2 帧起 `primed = 1` ⇒ ⭐ **行为与改动前逐位相同** ✅（⭐ 唯一差别 = ⭐ 首帧那一次快照被抑制 ✅）

---

## 四、⭐ 判据（⭐ 先出"未修复能红" ✅）

⭐ 加在 `tb/w3a/tb_axis_snapshot.sv` ✅：

```
⭐ 复位 ⇒ ⭐ 喂【位置完全恒定】的多帧（⭐ 两片都是 0x400 ✅）
⭐ 判据 A（非空洞）：⭐ 至少出现 1 次快照 ✅
⭐ 判据 B（主）：⭐ 每次快照的 `delta` 必须【全 0】✅
```

### 🔴 未修复时（⭐ 实测）

```text
  ok  : P2-27 (non-vacuous) at least one snapshot happened
FAIL: P2-27 with a CONSTANT position every snapshot delta is 0 (the first frame must not emit)
```

### ✅ 修复后（⭐ 实测）

```text
  ok  : P2-27 (non-vacuous) at least one snapshot happened
  ok  : P2-27 with a CONSTANT position every snapshot delta is 0 (the first frame must not emit)
PASS: axis_snapshot maps (adc,ch)->axis, commits all chips in one cycle, ...
```

📌 ⭐ **为什么用"位置恒定 ⇒ `delta` 全 0"当判据** ✅：
⭐ 它**不依赖**具体的位移值 ✅ ⇒ ⭐ 换表/换标定也不会假红 ✅
⭐ 而它**能红**：⭐ 只要首帧的伪 `delta` 还在，⭐ `delta_bad` 必涨 ✅

---

## 五、⚠️ 一条既有判据**必须跟着改**（⭐ 契约变更的连带）

🔴 修复后，`tb_axis_snapshot.sv` 的**既有**判据 ③ 红了 ✅：

```text
FAIL: snapshot pulse occurred (frame_done produced snap_valid)     // ⭐ 期望 snap_total >= 2
```

⭐ **原因**：⭐ 它用的是**全局**计数 `snap_total` ✅ ——
⭐ 而新契约下"**第 1 帧不出快照**" ⇒ ⭐ 前面只跑**单帧**的各段**不再产生快照** ✅
⇒ ⭐ `snap_total` 到那里只有 1 ✅

✅ **改法**：⭐ 断言改成 **`>= 1`** ✅ —— ⭐ 因为该条的**原意**是"快照脉冲确实发生了" ✅，
⭐ 而 `2` 这个数字**依赖前面跑了几帧**（⚠️ 本来就脆 ✅）
📌 ⭐ 新契约的**完整**验证由上面的 `P2-27` 段承担（⭐ 复位 ＋ 恒定位置 ✅）

---

## 六、⭐ 实测（⭐ 见 §七）
