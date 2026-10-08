# guide_lamp 接线说明（给甲 · 集成层）

> **作者**：丙线（led_data / tlc5916_bank / guide_lamp）
> **日期**：2026-10-08
> **性质**：⚠️ **只写方案，不改代码**。本文把「曲谱 → LED 指引」这条最后拼图的接线精确到**端口名**，由甲在集成 `top.v` 时照做即可。
> **背景**：`guide_lamp.v` 已写完并推送（丙线 P1），但它消费的 `play_seq` 输出、以及它输出的 `guide_key_o`，目前都还没在 `top.v` 里接通。当前 `led_data` 的 `.guide_key_i(16'd0)` / `.key_active_i(16'd0)` 是占位。

---

## 一、目标（一句话）

让「曲谱播放器 `play_seq` 吐出的音符事件」最终变成「LED 上『下一键该按哪个』的指引位图」。

**数据流**：

```
play_seq                       guide_lamp                        led_data
note_valid_o ──────────────► note_valid_i     guide_key_o[15:0] ─► guide_key_i
note_data_o[63:0] ─────────► note_data_i      (one-hot 指引位图)
event_extract.key_on (未引出) ─► key_active_i
beat_gen/bg_beat ───────────► blink_i
```

---

## 二、需要改动的三处（都在 `top.v`）

### ① 例化 `guide_lamp`（新增，放 `led_data` 例化之前）

```verilog
// ── 丙线 guide_lamp：音符事件 → 指引位图 ─────────────────────────
wire [15:0] guide_key;      // one-hot 指引位图
wire        guide_commit;   // 指引更新（可观测，可悬空）

guide_lamp #(
    .EVT_W  (64),
    .AXIS_N (16)
) u_guide_lamp (
    .clk_i          (clk),
    .rst_n_i        (rst_n_sync),
    .note_valid_i   (play_seq_note_valid),   // ← 见 ②，来自 play_seq
    .note_data_i    (play_seq_note_data),    // ← 见 ②，来自 play_seq
    .key_active_i   (key_on_16bit),          // ← 见 ③，来自 event_extract.key_on
    .blink_i        (led_blink),             // ← 与 led_data 的 blink 同源（bg_beat）
    .guide_key_o    (guide_key),
    .guide_commit_o (guide_commit)
);
```

> **位域契约已核对一致**（两边 `AXIS_SH=19`、`KIND_SH=9`，`note_data` 64 bit），无需改 `guide_lamp` 本体。
> `guide_commit_o` 若无下游消费可直接悬空；若想上板看「指引何时更新」，可引到某个调试脚。

### ② 引出 `play_seq` 的输出（若尚未有顶层 wire）

`play_seq` 已经输出了 `note_valid_o`（reg）与 `note_data_o[63:0]`（reg，锁存输出）。**只需把它们接到 `guide_lamp` 的输入**：

```verilog
wire        play_seq_note_valid;
wire [63:0] play_seq_note_data;
```

> ⚠️ 若 `play_seq` 尚未在 `top.v` 例化，请先例化它（这是甲既有的曲谱通路工作，本文不展开）。
> ⚠️ 若已有同义的顶层 wire（如 `u_play_seq.note_valid_o` 层次引用），直接用现有名字即可，无需新加。

### ③ 引出 `event_extract` 的 `key_on`（唯一需要动 `event_extract.v` 的地方）

**关键**：`event_extract.v` 里的 `key_on` 目前是**内部 `reg` 数组**（`reg key_on [0:AXIS_N-1]`），**没有作为输出端口引出** —— 这正是 `top.v` 注释里说的「尚未引出成 16 bit 端口」。

需要在 `event_extract.v` 加一个打包输出端口（这是**甲自己的文件**，丙不动）：

```verilog
// event_extract.v 端口列表新增：
output wire [AXIS_N-1:0] key_on_o,   // ⭐ 16 bit：各轴当前是否已按下

// 模块体内新增（把 reg 数组打包成向量）：
//   ⚠️ 若 key_on 是 unpacked reg 数组，需逐位赋值或改用 packed：
genvar gi;
generate
    for (gi = 0; gi < AXIS_N; gi = gi + 1) begin : g_keyon
        assign key_on_o[gi] = key_on[gi];
    end
endgenerate
```

然后在 `top.v` 的 `event_extract` 例化处接出：

```verilog
.key_on_o   (key_on_16bit),   // ⭐ 16 bit → 直接喂给 guide_lamp.key_active_i
```

> ⚠️ 这一步是**唯一**需要甲改动非集成层文件（`event_extract.v`）的地方；其余全在 `top.v` 内完成。

### ④ 替换 `led_data` 的两根占位线

```verilog
led_data #(
    .KEY_N    (16),
    .STATUS_N (8)
) u_led_data (
    .clk_i           (clk),
    .rst_n_i         (rst_n_sync),
    .guide_key_i     (guide_key),        // ⭐ 原 16'd0 → 改接 guide_lamp 输出
    .key_active_i    (key_on_16bit),     // ⭐ 原 16'd0 → 改接 event_extract.key_on
    .status_i        (8'd0),             // 状态灯仍是占位（待 UI 状态总线）
    .blink_i         (led_blink),        // 不变
    .pattern_o       (led_pattern),
    .pattern_commit_o(led_pattern_commit)
);
```

---

## 三、语义速查（供集成后核对）

| 事件 | guide_lamp 行为 |
|---|---|
| `note_on`（kind=0） | 点亮 `guide_key_o[axis]` 对应灯位（下一键该按） |
| `note_off`（kind=1） | 熄灭 `guide_key_o[axis]` 对应灯位 |
| `tempo`（kind=2，换速） | **忽略**，不点亮任何灯 |
| `key_active_i[i]=1`（已按下的键） | 由 `led_data` 消隐（已按就不需要再指引） |
| `blink_i` 拍点脉冲 | 指引位跟随拍点闪烁 |

**非空洞性**：任意轴号 0..15 的 `note_on` 都能落到一个真实非空灯位（one-hot 满射），由 `tb/w3c/tb_guide_lamp.sv` 16 断言守护。

---

## 四、验证点（甲接线后自检）

1. 综合门：`ERROR=0`（新例化不引入未连接端口告警）。
2. 跑 `tb/w3c/tb_guide_lamp.sv`（丙已写，16 断言）→ 应 **全绿**。
3. 若有端到端 tb（灌 `events.hex` 曲谱），核对 `led_data.pattern_o` 的低 16 bit 在 `note_on` 后对应 bit 置位。
4. 上板：拨到曲谱播放档，观察 LED 是否随曲谱「下一键」点亮。

---

## 五、边界声明

- 丙线**只负责** `guide_lamp` / `led_data` / `tlc5916_bank` 三个模块本体，本文所述 `top.v` / `event_extract.v` 改动**均属甲线集成层**。
- `status_i`（8 bit 状态灯）的 UI 状态总线目前仍是占位，与本文无关，可后续由 UI 线补。
