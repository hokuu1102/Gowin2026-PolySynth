# ANVIL-11 · 灯与显示（RTL 逐行审计）

> **审计对象**：`rtl/w3a/ws2812_driver.v` · `rtl/w3a/led_indicator.v` · `rtl/w3c/led_data.v` ·
> `rtl/w3c/tlc5916_bank.sv` · `rtl/drivers/tlc5916_driver.sv` · `rtl/w3c/guide_lamp.v`
> **战场数字（全篇判据基准）**：GW5AT-60B · 档位 **AC1/I0** · `clk_sys` = **50 MHz**（20 ns）·
> SDC 目标 `set_max_delay` **18.181 ns**（≈55 MHz，`constr/top.sdc:101`）·
> 实测 **=0 档 55.06 MHz / CLS 78%**（`sim/evidence/final-batch-20261008/timing.txt:77`、`pnr-rpt.txt:51`）·
> **=1 档（`RIGHT_ADC_ENABLE=1`）≈57.0 MHz / CLS 81%**（`sim/evidence/rightboard-vibrato-fix-20261008/`）·
> 门槛 **0 setup / 0 hold**、**Fmax ≥ 51.5 MHz**。
> **纪律**：PnR 是**布局噪声主导**（同源重跑差 2~3 MHz，见 `p5-2-osc-20261004/README.md:99-101`）⇒
> 每条结论都标注 **结构性长路径** 还是 **布局运气**。
>
> **本轮实测取证**（不污染交付树，探针放在 `build/anvil11-probe/`，⛔ 不在 `tb/` 下，
> 因此**全量回归仍是 通过 128 / 共 128**，见 `sim/evidence/final-batch-20261008/regression-full.log:6904`）：
> - `build/anvil11-probe/tb_anvil11_bank_probe.sv` → 复现 P0-1，并在 `tlc5916_bank_fixed.sv` 上**验证修法**
> - `build/anvil11-probe/tb_anvil11_ws_probe.sv` → 复现 P1-5（X 传播 13391 拍）
> - `git status --porcelain rtl tb constr Gowin2026.gprj` = **空**（交付树逐字节未动）

---

## §0 五个核心问题 · 裁定

| # | 问题 | 裁定 | 硬证据 |
|---|---|---|---|
| 1 | **WS2812 位定时状态机（1.25 µs/位）对不对** | ✅ **对**。位周期恒 62 拍（1.24 µs）、`'0'` 高 17 拍（0.34 µs）、`'1'` 高 35 拍（0.70 µs），**逐位**测过、无累积漂移。**但**：`mem` 无复位 ⇒ 未写过的 LED 出 X（P1-5）；模块**无参数自检**（P2-6） | `ws2812_driver.v:130` `dout_o = (state==S_SEND) && (bit_t < (cur_bit?T1H:T0H))`；`tb_ws2812_driver.sv:168-169/180-181/211-212` |
| 2 | **灯数据位序 / 颜色映射对不对** | ✅ **对，且是"单点定义"**。RGB888 只在 `ws2812_driver.v:115` 一处重排成 GRB；指示层出的是标准 `24'hRRGGBB`（`led_indicator.v:95-106`）；顶层写口 `case` 切片顺序被 `tb_top_led_strip.sv` 逐颗钉住。⚠️ 但 TLC 那侧的位序**完全没判据**（P0-4） | `ws2812_driver.v:115`；`tb_top_led_strip.sv:167-187/246-253` |
| 3 | **TLC5916 串行移位链对不对** | 🔴 **错**。`tlc5916_bank`→`tlc5916_driver` 握手多打一拍 `start` ⇒ driver 的 `pending` 被误置 ⇒ **片1 的图案被片0 顶替**（实测线上字节 `f0/f0/95`，应为 `f0/3c/95`）。**P0-1** | `build/anvil11-probe/` 实测输出 |
| 4 | **`guide_lamp` 是不是死代码** | 🔴 **是，而且死两次**。① `key_active_i`(v:42) / `blink_i`(v:45) **只出现在端口声明和注释里，逻辑里 0 次引用**；② 它**没登记进 `Gowin2026.gprj`** ⇒ 综合日志 `Compiling module` 列表里没有它 ⇒ **根本没进网表**。**P0-3** | 全文计数：`key_active_i` 2 次 / `blink_i` 2 次（均为声明+注释）；`Gowin2026.gprj` 无 `guide_lamp`；`syn.log:176-181` |
| 5 | **灯是不是跨慢时钟域** | ✅ **不是。全链单时钟域 `clk`=50 MHz，零 CDC**。`led_indicator` / `ws2812_driver` / `led_data` / `tlc5916_bank` / `tlc5916_driver` 的 `clk`/`clk_i` 全部接 `top.v` 的 `clk`；`rst_n` 全部接同步后的 `rst_n_sync`；`led_blink`/`led_beat` 都是 `g_sound.u_beat_gen.beat_o`（同域单周期脉冲）；`led_gear_st`/`led_looper_st` 是同域寄存器。⛔ **不需要任何同步器**；⚠️ 唯一"低频"的东西是**脉冲频率**（拍点 ~2 Hz、快闪 5.96 Hz），**不是时钟** | `top.v:4836/4852/4947/4985`、`top.v:1510`（`bg_beat` 源）、`top.v:3669`、`top.v:1785` |

---

## §1 优先级速查表

| 优先级 | 编号 | 一句话 |
|---|---|---|
| **P0** | P0-1 | `tlc5916_bank`↔`tlc5916_driver` 握手多打一拍 `start` ⇒ **片1 图案被片0 顶替**（已实测复现+已验证修法） |
| **P0** | P0-2 | 交付树里**整条 TLC5916 键灯链永不提交** ⇒ 24 路灯**永久全灭** |
| **P0** | P0-3 | `guide_lamp` 的 `key_active_i`/`blink_i` 是**死输入**（消隐/闪烁都没实现）＋ **未登记 `.gprj`**（未综合） |
| **P0** | P0-4 | `tb_tlc5916_bank` 文件头自述的 ③④ 两条判据**根本没写**；`tb_top_led_strip` **四个 TLC 引脚没连** ⇒ 上面三条 100% 逃过 128 个 tb |
| **P1** | P1-1 | `tlc5916_bank` 的 **OE 引脚绕过 driver 全部 K-01/K-57 防护**（防护作用在死网 `drv_oe` 上） |
| **P1** | P1-2 | `pattern_commit_o` 在 bank 忙时被**静默丢弃**（27.1 µs 盲窗、无 pending、无重试） |
| **P1** | P1-3 | `tb_tlc5916_bank` **没挂任何检查器**（A1 窄脉冲 / A2 LE-移位 / A8 X 传播 全 0 覆盖） |
| **P1** | P1-4 | `tb_led_data` **没挂 A8（chk_xprop）** |
| **P1** | P1-5 | `ws2812_driver` 的 `mem` **无复位** ⇒ 只写 7 颗灯（模块头自己推荐的用法）时 `dout_o` 出 **13391 拍 X**（已实测复现） |
| **P1** | P1-6 | 5 根 LED 输出引脚在 `top.sdc` 里**既无 output_delay 也无 false_path** ⇒ 工具侧**根本不分析** |
| **P2** | P2-1 | 顶层 WS2812 **1.141 kHz 背靠背连发**，WS2812 是自保持器件 ⇒ 54% 的引脚翻转是白烧的 |
| **P2** | P2-2 | `tlc5916_driver` 恢复序列用 **32 位有符号 `integer` + 对 50 取模 `%`** |
| **P2** | P2-3 | `led_indicator` 的 **−1.148 MHz 是布局/拥塞，不是结构性长路径** —— 明确**不建议做**流水 |
| **P2** | P2-4 | `tlc5916_bank` 的 `drv_oe` 是**死网**（0 消费者）＋ `drv_data_r` 是多余一级 |
| **P2** | P2-5 | `ws2812_driver` 的 `mem` **读写竞争** ⇒ 模块头承诺的"飞行中写只影响下一帧"**不成立** |
| **P2** | P2-6 | `ws2812_driver` 是六个灯模块里**唯一没有参数自检**的（`LED_N>32` / `BIT_CYC<60` 静默错） |
| **P2** | P2-7 | `led_data` 的 `if (STATUS_N < 0)` **永远不触发**，而真正会炸的 `STATUS_N=0` 没被拦 |
| **P2** | P2-8 | `tlc5916_bank` 的 FSM **只支持 3 片**，但 `KEY_CHIPS/STATUS_CHIPS` 没被这个上限约束 |
| **P3** | P3-1 | `guide_lamp.v` 无 `` `timescale `` / 无 `` `default_nettype none `` ⇒ 每次回归刷 250+ 行噪声 |
| **P3** | P3-2 | `guide_lamp` 的 `note_axis` 硬编码 4 位，`AXIS_N<16` 时越界写 |
| **P3** | P3-3 | `ws2812_driver.v:45` 注释写预取下界 **61**，实际是 **60** |
| **P3** | P3-4 | `ws2812_driver.v:220` 的 `default` **不可达**（4 个状态全枚举）—— 死逻辑，⛔ 不要删 |
| **P3** | P3-5 | `led_oe_n[2]`/`led_oe_n[3]` 恒高（预留），`.cst` 里没注明 |
| **P3** | P3-6 | `led_indicator` 的 `looper_i=2'd3` 落进 default ⇒ 与"空闲"同色，第 4 态会被静默吞掉 |
| **P3** | P3-7 | `tlc5916_bank` 的 `S_WAIT_BUSY` **无握手超时** ⇒ 一旦卡死无外部症状 |
| **P3** | P3-8 | `top.v` 的 `led_busy` **声明+驱动但从不读**（死信号） |
| **P3** | P3-9 | `led_indicator` 的 `fast_cnt` **无条件自由跑**（没人闪的时候也在烧电） |

**合计 27 条：P0 = 4 · P1 = 6 · P2 = 8 · P3 = 9**

---

## §2 逐条清单

---

### P0-1 · `tlc5916_bank` → `tlc5916_driver` 握手多打一拍 `start`，片1 的图案被片0 顶替

- **位置**：`rtl/w3c/tlc5916_bank.sv:232-239`（`S_START`）＋ `rtl/drivers/tlc5916_driver.sv:277`（`pending` 置位）＋ `rtl/w3c/tlc5916_bank.sv:250-253`（换片处）

- **代码**：

```verilog
// tlc5916_bank.sv:232-239
S_START: begin
    drv_start_r <= 1'b1;   // 拉 start（driver 锁进 pending 或直接接受）
    if (drv_busy) begin
        // driver 已接受本片 ⇒ 撤 start，等 done
        drv_start_r <= 1'b0;
        state       <= S_WAIT_BUSY;
    end
end
```
```verilog
// tlc5916_driver.sv:277
if (start && busy) pending <= 1'b1;
```

- **机制 / 数字**：
  `drv_busy` 是 driver **内部寄存器**，bank 要到**下一拍**才看得见 ⇒ `start` 实际宽度 = **2 拍 = 40 ns**。
  时序：离开 `S_IDLE` 时 `drv_start_r<=0`；`S_START` 第 1 拍拉 1、第 2 拍仍写 1（此时 driver 还没回 `busy`）、第 3 拍看到 `busy=1` 才撤。
  driver 在**第 2 拍**采样 `start=1 && busy=0` ⇒ 接受；在**第 3 拍**采样 `start=1 && busy=1` ⇒ **`pending<=1`（误置）**。
  回到 `STATE_IDLE` 后 `if (start || pending)` 立刻再发一帧，且 `data_latched <= led_data` 采的是**换片前**的值（`chip_sel` 在同一拍才自增）⇒ **重放上一片的图案**。

- **⭐ 实测（`build/anvil11-probe/`，`pattern = 24'hA5_3C_0F` ⇒ 期望 `F0 / 3C / 95`）**：

```
OBSERVED: n_le=3  n_done=3  n_pending_sets=2  start_high_cycles=4
  LE[0]: byte=f0  chip_sel=0   <- 对
  LE[1]: byte=f0  chip_sel=1   <- 🔴 错！应是 3c（片1 的图案永远发不出去）
  LE[2]: byte=95  chip_sel=2   <- 对
VERDICT: BUG REPRODUCED
```

- **⭐ 修法已实测验证**（改 `build/anvil11-probe/tlc5916_bank_fixed.sv`，3 处）：
  把 `start` 做成**恰好 1 拍**的脉冲 —— 在**离开 `S_IDLE` / `S_WAIT_BUSY` 的那一拍**拉高，`S_START` 只负责撤销：

```verilog
S_IDLE: begin
    busy_r      <= 1'b0;
    chip_sel    <= 2'd0;
    drv_start_r <= 1'b0;
    if (pattern_commit_i) begin
        busy_r      <= 1'b1;
        chip_sel    <= 2'd0;
        drv_start_r <= 1'b1;   // FIX: 1 拍 start 脉冲
        state       <= S_START;
    end
end
S_START: begin
    drv_start_r <= 1'b0;       // FIX: start 只宽 1 拍
    state       <= S_WAIT_BUSY;
end
// 换片处同样补一行：drv_start_r <= 1'b1;
```
  修后实测：`n_le=3  n_done=3  n_pending_sets=0  start_high_cycles=3`，字节 **`f0 / 3c / 95`** ⇒ `VERDICT: NO BUG`。
  ⚠️ 1 拍 `start` 是 driver 的**既有契约**（`tlc5916_driver.sv:198` 的恢复序列就是按"1 拍 start 会被 `pending` 记住"写的），所以这个修法是**回到契约**，不是新语义。

- **结构性 vs 布局**：⭐ **结构性**。纯握手协议缺陷，与布局/时钟无关，任何 PnR、任何温度角都必错。

- **收益 / 代价**：收益 = 片1（键灯高 8 位 = 右手板 8 个键）恢复正确图案；顺带消掉 2 次多余传输。
  代价 = **0 LUT / 0 FF**（还少一个 `if (drv_busy)` 比较）；`drv_start_r` 路径是 FF→FF 单级，**Fmax 无影响**。

- **怎么验证能红**：新建 `tb/w3c/tb_tlc5916_bank_seq.sv`：`pattern = 24'hA5_3C_0F`，在 `led_le_o` 上升沿抓 8 位串行字节并记 `dut.chip_sel`，断言三个字节依次 `== {chip0_out, chip1_out, chip2_out}`（= `F0/3C/95`）。
  **对未修的 RTL 必须红**（我已实测 `f0/f0/95`）。⛔ 现有 `tb_tlc5916_bank.sv` **抓不到**（见 P0-4）。

---

### P0-2 · 交付树里整条 TLC5916 键灯链是死的：`pattern_commit_o` 永不拉高 ⇒ 24 路灯永久全灭

- **位置**：`rtl/top.v:4838-4840`（三个占位）· `rtl/w3c/led_data.v:73-85`（合并逻辑）· `rtl/w3c/led_data.v:92`（变化检测）· `rtl/w3c/tlc5916_bank.sv:199-205`（OE mux）· `rtl/top.v:4860`

- **代码**：

```verilog
// top.v:4838-4840
.guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
.key_active_i    (16'd0),            // ⭐ 占位：待 event_extract.key_on（甲）
.status_i        (8'd0),             // ⭐ 占位：待 UI 状态总线
```
```verilog
// led_data.v:73-79,85
wire [KEY_N-1:0] blink_keys = guide_key_i & ~key_active_i;
assign key_pattern[ki] = key_active_i[ki] | (blink_keys[ki] & blink_i);
assign pattern_next = {status_i, key_pattern};
```
```verilog
// led_data.v:92,101
wire pattern_changed = (pattern_r !== pattern_next);
commit_r  <= pattern_changed;
```
```verilog
// tlc5916_bank.sv:199-205
oe_n_r = {OE_N{1'b1}};              // 默认全灭
if (state != S_IDLE && !global_blank_i) begin ... end
```

- **机制 / 数字**：
  三个输入恒 0 ⇒ `key_pattern == 16'd0` ⇒ `pattern_next == 24'd0`；
  `pattern_r` 复位也是 0 ⇒ `pattern_changed = (0 !== 0) = 0` **恒假** ⇒ `commit_r` 恒 0。
  `tlc5916_bank` 只在 `S_IDLE && pattern_commit_i` 才启动 ⇒ **一轮都不跑** ⇒ `state` 永为 `S_IDLE` ⇒ `oe_n_r = 5'b11111`。
  `OE` 低有效 ⇒ **24 路 TLC5916 输出（16 键灯 + 8 状态灯）全部永久消隐**。
  实测数字：`0` 次写、`0` 个 `LE` 脉冲、`led_oe_n[4:0]` 恒 `5'b11111`。
  ⚠️ 而**全部 128 个 tb 都会绿**：`led_sdi/led_clk/led_le/led_oe_n` 在 `tb_top_led_strip.sv:90-101` 里**连端口都没写**（悬空），其余 tb 引出来也不做断言。

- **结构性 vs 布局**：⭐ **结构性**（接线缺失，与布局无关）。

- **怎么改**：接真源，顺序不能反 ——
  ① 先修 **P0-3**（`guide_lamp` 的死输入 + `.gprj` 登记），否则接上去也没用；
  ② `play_seq.note_valid_o / note_data_o` → `guide_lamp.note_valid_i / note_data_i`；
  ③ `guide_lamp.guide_key_o` → `led_data.guide_key_i`（替换 `16'd0`）；
  ④ `event_extract` 的 `key_on` 16 位引出 → `led_data.key_active_i`（替换 `16'd0`）；
  ⑤ UI 状态总线 → `led_data.status_i`（替换 `8'd0`）。
  ⑤ 可先不做（`status_i=8'd0` 只是让 8 个状态灯灭），但 ①②③④ 必须一起上。

- **收益 / 代价**：收益 = 功能从"没有"到"有"（16 键灯 + 8 状态灯复活）。
  代价 = `guide_lamp` 一个模块（约 30~50 LUT + 17 FF）＋ 接线；`led_data`/`tlc5916_bank` **本体一行不改**（接口早就留好了）。

- **怎么验证能红**：在 `tb_top_led_strip.sv` 里把 `led_sdi/led_clk/led_le/led_oe_n` **接上**，加两条：
  ① 断言 `led_oe_n` 在图案变化后出现低脉冲（当前恒高 ⇒ 必红）；
  ② 抓一轮串行字节，断言 `== {chip0_out, chip1_out, chip2_out}`（这条同时是 P0-1 的判据）。

---

### P0-3 · `guide_lamp` 的 `key_active_i` / `blink_i` 是死输入（注释说 A、代码做 B）＋ 未登记 `.gprj`

- **位置**：`rtl/w3c/guide_lamp.v:20-21`（承诺）· `:42`（`key_active_i`）· `:45`（`blink_i`）· `:72-95`（全部逻辑）· `Gowin2026.gprj`（无 `guide_lamp`）

- **代码**：

```verilog
// guide_lamp.v:20-21  ← 注释承诺了两件事
//    · key_active_i 已按下的键 → 消隐（已按就不需要再指引）
//    · blink_i（拍点脉冲）→ 使当前指引位跟随拍点闪烁（可观测节拍）
```
```verilog
// guide_lamp.v:41-45  ← 端口确实声明了
input  wire [AXIS_N-1:0]   key_active_i,
input  wire                blink_i,
```
```verilog
// guide_lamp.v:72-95  ← 逻辑里【一次都没用到】上面两个输入
always @(posedge clk_i) begin
    if (!rst_n_i) begin guide_key_o <= {AXIS_N{1'b0}}; guide_commit_o <= 1'b0; end
    else begin
        guide_commit_o <= 1'b0;
        if (note_valid_i) begin
            if (is_note_on)       begin guide_key_o[note_axis] <= 1'b1; guide_commit_o <= 1'b1; end
            else if (is_note_off) begin guide_key_o[note_axis] <= 1'b0; guide_commit_o <= 1'b1; end
        end
    end
end
```

- **机制 / 数字**：
  机械计数（本轮实测）：`key_active_i` 全文出现 **2 次**（`:42` 端口声明 + `:20` 注释）；
  `blink_i` 全文 **2 次**（`:45` 端口声明 + `:21` 注释）；**在 `always` 块里 0 次**。
  ⇒ ① "已按下的键消隐"**没实现**：已按键仍被指引灯点亮 ⇒ 用户分不清"该按的键"和"正在响的键"（正是 `files/10-硬件/LED演奏指引方案.md` §4.3 要区分的那两件事）；
  ② "指引位跟随拍点闪烁"**没实现**：指引是**常亮**，节拍在灯上不可见。
  ③ **双重死亡**：`Gowin2026.gprj` 里**没有** `guide_lamp`（`Select-String -Path Gowin2026.gprj -Pattern "guide"` 只命中一句注释）
  ⇒ `sim/evidence/final-batch-20261008/syn.log:176-181` 的 `Compiling module` 列表里**没有 `guide_lamp`**
  ⇒ **它根本没进网表**。即使甲线把 `top.v` 接好了，Gowin 也只会报 `EX3937 Instantiating unknown module`（或者更糟：静默丢弃）。
  ⚠️ 更阴的是：`tb_guide_lamp.sv` **恒给 `key_active=0`、`blink=0`**（`:34-35` 初始化后 `:101` 起从未改过），所以那 **16 条判据全绿** —— 这是本项目 `C83`（探针假绿）的教科书复现。

- **结构性 vs 布局**：⭐ **结构性**（功能缺失 + 未综合）。

- **怎么改**（三处，一次做完）：
  ① **消隐**（组合，最省）—— 新增一根可见输出，或在 `guide_key_o` 上直接消隐：
  ```verilog
  // 消隐：已按下的键不再指引（与 led_data 的"常亮"语义互补）
  assign guide_vis_o = guide_key_o & ~key_active_i;
  ```
  （若要保持 `guide_key_o` 的端口语义不变，就新增 `guide_vis_o` 端口，`led_data.guide_key_i` 接它。）
  ② **闪烁** —— 把拍点做进输出级（与 `led_data` 的 `blink_i` 语义对齐，⛔ 不要重复实现两个闪烁）：
  ```verilog
  // 指引位跟随拍点：blink_i 高那一拍才亮
  assign guide_vis_o = guide_key_o & ~key_active_i & blink_i;
  ```
  ⚠️ **二选一必须与 `led_data` 商量**：`led_data.v:73-79` 已经做了 `blink_keys & blink_i`。
  若 `guide_lamp` 也做，就是**两次闪烁串联** ⇒ 实际占空比变成 25%。
  ⭐ **推荐**：`guide_lamp` 只做**消隐**（①），闪烁**留给 `led_data`**（那是它已经写好的职责，`led_data.v:73`）。
  这样 `blink_i` 就该**从 `guide_lamp` 的端口列表里删掉**（而不是留着当装饰）。
  ③ **登记 `.gprj`**：在 `Gowin2026.gprj:164` 那一组里加
  `<File path="rtl/w3c/guide_lamp.v" type="file.verilog" enable="1"/>`
  ⛔ **必须是 `type="file.verilog"`**（`.gprj:186-189` 已记过这个坑：写 `file.systemverilog` 会**静默跳过**）。
  ④ 改完在综合日志里**确认**出现 `Compiling module 'guide_lamp'`（`.gprj:189` 的纪律）。

- **收益 / 代价**：
  ① 消隐：**+16 LUT / 0 FF**（一层 AND）。
  ② 删 `blink_i` 端口：**−0**（它本来就没进逻辑，删掉只是让契约诚实）。
  ③ 登记 `.gprj`：**0**（若同时按 ① 加了 `guide_vis_o`，净 +16 LUT + 1 个端口）。
  ⚠️ 代价另一面：登记后 `guide_lamp` 进综合，`AXIS_W` 越界问题（P3-2）就要先修，否则 `AXIS_N<16` 时才炸 —— 当前 `AXIS_N=16` 是安全的。

- **怎么验证能红**：
  `tb_guide_lamp.sv` 现在把 `key_active`/`blink` 恒 0 ⇒ **两条判据都没写**。加：
  ① `key_active_i = 16'h0008` + `note_on axis=3` ⇒ 断言 `guide_vis_o[3] === 1'b0`（当前 `guide_key_o[3]` 会是 1 ⇒ **对未修 RTL 必红**）；
  ② 断言"`key_active_i` 的变化会改变输出"（存在性反证，防止把输入接成常量）。
  ⛔ 别忘 `AGENTS.md` 的**变异证据**纪律：把 `& ~key_active_i` 删掉 ⇒ ① 必须红（这正是 M137~M139 的补集）。

---

### P0-4 · `tb_tlc5916_bank` 自述的两条判据没写；`tb_top_led_strip` 四个 TLC 引脚没连 ⇒ 上面三条 100% 逃过 128 个 tb

- **位置**：`tb/w3c/tb_tlc5916_bank.sv:12-14`（自述）vs `:131-150`（实际）· `tb/top/tb_top_led_strip.sv:90-101`（端口列表）

- **代码**：

```verilog
// tb_tlc5916_bank.sv:12-14  ← 文件头【自述】有这三条
//   ③ ⭐ 三片逐写：commit 后依次写片0、片1、片2，写完回 IDLE、OE 回全高
//   ④ ⭐ OE 分板：写片0 时 oe[0]=0；写片1 时 oe[1]=0；写片2 时 oe[4]=0
//   ⑤ ⭐ busy 只在写期间为高，写完后回落
```
```verilog
// tb_tlc5916_bank.sv:131-150  ← 实际只做了这些
commit = 1'b1; @(negedge clk); commit = 1'b0;
wait (busy === 1'b1);   // 开始
wait (busy === 1'b0);   // 结束
@(negedge clk);
chk("after 3-chip write: OE all high (back to IDLE)", oe_n === {OE_N{1'b1}});
chk("after 3-chip write: busy 0", busy === 1'b0);
```
```verilog
// tb_top_led_strip.sv:90-101  ← 端口列表里【没有】led_sdi/led_clk/led_le/led_oe_n
.clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),
.HP_BCK (), .HP_WS (), .HP_DIN (), .PA_EN_n (), .led_heartbeat (),
...
.ctrl_ws_o (ws_snd),
...
.ws_strip_o (strip_snd)
```

- **机制 / 数字**：
  ① `tb_tlc5916_bank` 的 ③④ **从未实现**：它只在**整轮结束后**看一次 `oe_n === 5'b11111` 和 `busy === 0`，
  **既不抓每片的串行数据、也不看每片的 OE**。判据 ② 之所以有效，是因为它用**层次引用** `dut.chip0_out`（组合表），
  这恰好**绕过了**串行链 —— 也就是说：**CH→OUT 表对、串行链全错，它照样全绿**。
  ② `tb_top_led_strip` 的 `.led_sdi/led_clk/led_le/led_oe_n` **一个都没连** ⇒ 那四根线在 tb 里悬空（`z`）。
  ③ 全仓库计数：`tb/` 下把 `led_sdi`/`led_clk`/`led_le`/`led_oe_n` **引出来**的 tb 只有 3 个（`tb_top_t15`、`tb_pos_probe_axis`、`tb_vibrato_top`），
  **没有任何一个对它们做值断言**。
  ⇒ 结论：**TLC5916 总线的顶层波形，判据覆盖率 = 0**。P0-1 因此能 100% 通过 128/128。

- **结构性 vs 布局**：⭐ **结构性**（判据缺失；这是 P0-1 能活下来的**唯一**原因）。

- **怎么改**（只加 tb，0 RTL 代价）：
  ① `tb_tlc5916_bank.sv` 补 ③④：在 `led_le_o` 上升沿抓 8 位（`{cap[6:0], led_sdi_o}`）并记 `dut.chip_sel`，断言三次 `(byte, chip_sel)` 依次是 `(chip0_out,0) (chip1_out,1) (chip2_out,2)`；同时每次断言 `oe_n[chip] === 1'b0`、其余为 1。
  ② `tb_top_led_strip.sv:90-101` 把四根线接上，并断言"图案变化后 `led_oe_n` 出现低脉冲 + SDI 位流 == 期望"。

- **收益 / 代价**：收益 = P0-1/P0-2 从此**不可能再溜过**；代价 = 0 RTL，tb 运行时间 +≈0（一轮 3 片只有 1353 拍）。
  ⚠️ 注意 `AGENTS.md` 的**发现式**纪律：`tb_all.ps1` 自动发现 `tb/**/tb_*.sv` ⇒ 新增 tb 会让"共 N"从 **128** 变成 **129**，
  ⛔ **判据是"通过数 == 共数"，不是写死 128**。

- **怎么验证能红**：把 `tb/w3c/tb_tlc5916_bank.sv` 的新断言**先对当前 RTL 跑** ⇒ **必须红**（我已实测 `f0/f0/95`）。
  这是"新判据不是恒真"的工具控制实验，⛔ 不能省。

---

### P1-1 · `tlc5916_bank` 的 OE 引脚绕过 driver 的全部 K-01 / K-57 防护

- **位置**：`rtl/w3c/tlc5916_bank.sv:159`（`.outputs_enable(1'b1)`）· `:147`（`wire drv_oe;`）· `:163`（`.tlc_oe_n(drv_oe)`）· `:198-207`（组合 OE mux）· 对照 `rtl/drivers/tlc5916_driver.sv:17-25` / `:159-162` / `:265-267`

- **代码**：

```verilog
// tlc5916_bank.sv:147,159,163
wire        drv_oe;      // driver 的 OE 输出（我们另外做分板 mux）
    .outputs_enable (1'b1),          // ⭐ 让 driver 自己的 OE 常开；分板靠下面 mux
    .tlc_oe_n       (drv_oe),
```
```verilog
// tlc5916_bank.sv:198-207   ← 真正的引脚由【组合】逻辑驱动
reg [OE_N-1:0] oe_n_r;
always @(*) begin
    oe_n_r = {OE_N{1'b1}};
    if (state != S_IDLE && !global_blank_i) begin
        if (chip_sel == 2'd0)      oe_n_r[0] = 1'b0;
        else if (chip_sel == 2'd1) oe_n_r[1] = 1'b0;
        else                        oe_n_r[4] = 1'b0;
    end
end
assign led_oe_n_o = oe_n_r;
```
```verilog
// tlc5916_driver.sv:162,267   ← 这两道防护作用在 drv_oe 上
wire oe_quiet = (state == STATE_IDLE) && (tlc_le == 1'b0) && (tlc_clk == 1'b0);
if (oe_quiet) tlc_oe_n <= ~oe_hold;
```

- **机制 / 数字**：
  `tlc5916_driver` 的**防护①**（`OE_STABLE = 25` 拍 = **500 ns** 稳定窗，满足手册 `tw(OE) ≥ 500 ns`，`K-57`）
  与**防护②**（只在 `state==IDLE && !tlc_le && !tlc_clk` 时改 OE，`K-01` 的成因）
  **全部作用在 `tlc_oe_n` 这个输出上**。而 bank 把它接给 `drv_oe` 之后 **0 个消费者**（全文只有 `:147` 声明 + `:163` 连接），
  真正的 `led_oe_n[4:0]` 由 `oe_n_r` **组合**驱动。
  ⇒ 数字：**500 ns 稳定窗对引脚 0 覆盖**；**"CLK 静止"条件对引脚 0 覆盖**；
  `drv_oe` = **1 位死网**；`outputs_enable` 恒 1 ⇒ `oe_hold`/`oe_cnt` 那套逻辑是**结构上被短路**的死逻辑。
  ⚠️ 具体风险：`oe_n_r` 的输入是 `state[2:0]` 与 `chip_sel[1:0]`（都是 FF），组合译码在 `state` 跳变时可能出毛刺；
  虽然当前"OE 变化总发生在 driver 回 IDLE（CLK 静止）之后"，但那是**时序巧合**，⛔ 不是结构保证。

- **结构性 vs 布局**：⭐ **结构性**（防护被结构绕过）。

- **怎么改**（推荐 (a)，0 额外 FF）：
  (a) **把 `drv_oe` 接成总闸**，分板 mux 与它相与：
  ```verilog
  // drv_oe 低 = 使能；分板选择再与总闸相与
  assign led_oe_n_o = oe_n_r | {OE_N{~drv_oe}};
  ```
  这样 K-01/K-57 的两道防护**重新回到引脚上**，且 `drv_oe` 不再是死网。
  (b) 或把 `oe_n_r` 打一拍成寄存器（消组合毛刺），并**仍然**接 `drv_oe` 作总闸。
  ⚠️ 无论哪条，`tlc5916_bank.sv:159` 的 `1'b1` 要改成真正的"总使能"（若暂时没有，用 `~global_blank_i`）。

- **收益 / 代价**：收益 = 5 根 OE 引脚重新受 `K-01`/`K-57` 防护（`Special Mode` 不可进）。
  代价 = **约 5 个 OR 门 / 0 FF**；副作用 = OE 变化最多晚 `OE_STABLE` = **25 拍 = 0.5 µs**（对"消隐/分板"用途无感，`tlc5916_driver.sv:23-24` 早已算过这笔账）。
  `drv_oe` 路径是 FF→OR→引脚，**Fmax 无影响**。

- **怎么验证能红**：`tb_tlc5916_bank.sv` 挂上 `tb_tlc5916_driver.sv:46-49` 那两个检查器：
  ```verilog
  chk_min_pulse #(.NAME("led_oe_n[0]"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (.clk(clk), .rst_n(rst_n), .sig(oe_n[0]), .err_cnt(a1));
  chk_le_shift  #(.NAME_LE("led_le_o"), .NAME_SCK("led_clk_o"))        u_a2 (.clk(clk), .rst_n(rst_n), .le(le), .sck(clk_o), .err_cnt(a2));
  ```
  再打一个 **1 拍** `global_blank_i` 窄脉冲，断言引脚**完全不动**。
  对未修 RTL：1 拍 `global_blank_i` 会让 `oe_n_r` 组合翻转 1 拍 ⇒ `chk_min_pulse` **必红**。

---

### P1-2 · `pattern_commit_o` 在 bank 忙时被静默丢弃（27.1 µs 盲窗，无 pending、无重试）

- **位置**：`rtl/w3c/led_data.v:100-101`（单周期脉冲）· `rtl/w3c/tlc5916_bank.sv:221-230`（只在 `S_IDLE` 看 commit）

- **代码**：

```verilog
// led_data.v:100-101
// ⭐ commit 只在"图案真的变了"那一拍拉高（单周期），⛔ 每拍都刷
commit_r  <= pattern_changed;
```
```verilog
// tlc5916_bank.sv:221-230   ← 只有 S_IDLE 分支看 commit
S_IDLE: begin
    drv_start_r <= 1'b0;
    busy_r      <= 1'b0;
    chip_sel    <= 2'd0;
    if (pattern_commit_i) begin
        busy_r   <= 1'b1;
        chip_sel <= 2'd0;
        state    <= S_START;
    end
end
```

- **机制 / 数字**：
  一轮 = 3 片 × (8 bit × 2 半周期 × `HALF_DIV`=25 拍 + `LE_WAIT` 1 拍 + `LATCH_HIGH` 25 拍)
  = 3 × (400 + 26) ≈ **1353 拍 = 27.1 µs @50 MHz**。
  这 27.1 µs 里 bank 不在 `S_IDLE` ⇒ **`pattern_commit_i` 被完全忽略**，而且**没有 pending 位**（对照 `tlc5916_driver.sv:277` 的 R-09 是有的）。
  ⚠️ 后果不对称：如果那次变化是"按下并保持"的**一次性**变化，灯会**永远停在旧图案**，直到下一次图案变化。
  用 `blink_i` 抖动时（每拍点都变）看不出来；**单手按一个键不动**时就是永久性错误。

- **结构性 vs 布局**：⭐ **结构性**。

- **怎么改**：给 bank 加 1 位 `pending_commit`（**与 driver 的 R-09 同构**，语义 = "至少写一次"）：
  ```verilog
  // 在非 IDLE 期间记住请求
  if (pattern_commit_i && (state != S_IDLE)) pending_commit <= 1'b1;
  // 回 IDLE 时补发
  S_IDLE: if (pattern_commit_i || pending_commit) begin
              pending_commit <= 1'b0;
              busy_r <= 1'b1; chip_sel <= 2'd0; state <= S_START;
          end
  ```
  （复位分支加 `pending_commit <= 1'b0;`）

- **收益 / 代价**：收益 = 消除"偶尔不刷新/永久不刷新"这类**极难定位**的现象。
  代价 = **+1 FF + ~2 LUT**；`pending_commit` 是 FF→OR→FSM，**Fmax 无影响**。

- **怎么验证能红**：tb 里 `commit` 一次 → `wait (busy === 1'b1)` → **在 busy 期间**改 `pattern_i` 再 `commit` 一次 → 等整轮结束 → 断言 `oe_n`/SDI **又出现一轮**、且最终图案 == 新图案。
  对未修 RTL：**只跑一轮** ⇒ 必红。

---

### P1-3 · `tb_tlc5916_bank` 没挂任何检查器（A1 窄脉冲 / A2 LE-移位 / A8 X 传播 全 0 覆盖）

- **位置**：`tb/w3c/tb_tlc5916_bank.sv`（全文无 `chk_*` 例化）· 对照 `tb/drivers/tb_tlc5916_driver.sv:46-62`（挂了 **8 个**）

- **代码**（对照组的正确写法）：

```verilog
// tb_tlc5916_driver.sv:46-49
chk_min_pulse #(.NAME("tlc_oe_n"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (
    .clk(clk), .rst_n(rst_n), .sig(tlc_oe_n), .err_cnt(a1_err));
chk_le_shift #(.NAME_LE("tlc_le"), .NAME_SCK("tlc_clk")) u_a2 (
    .clk(clk), .rst_n(rst_n), .le(tlc_le), .sck(tlc_clk), .err_cnt(a2_err));
```
```verilog
// tb_tlc5916_bank.sv  ——  全文没有任何 chk_min_pulse / chk_le_shift / chk_xprop
```

- **机制 / 数字**：
  `tlc5916_bank` 是**真正驱动引脚**的那一级：`led_le_o` / `led_clk_o` / `led_oe_n_o[4:0]` / `led_sdi_o` 都由它出。
  ⇒ 这三个引脚的 **A1（窄脉冲）/ A2（LE 在移位期为低）/ A8（X 传播）判据覆盖率 = 0**。
  对照：driver 的 tb 对**同样的物理引脚**（在更下游）挂了 8 个检查器 —— 也就是说防护被挂在了**错误的层级**（见 P1-1，引脚其实由 bank 驱动）。

- **结构性 vs 布局**：⭐ **结构性**（判据缺失）。

- **怎么改**：把 `tb_tlc5916_driver.sv:46-62` 那三组**照抄**到 `tb_tlc5916_bank.sv`：
  ```verilog
  wire [31:0] a1_le, a1_oe, a2_err, a8_sdi, a8_clk, a8_le, a8_oe;
  chk_min_pulse #(.NAME("led_le_o"),   .ACTIVE_LOW(0), .MIN_CYCLES(4)) u_a1l (.clk(clk),.rst_n(rst_n),.sig(le),     .err_cnt(a1_le));
  chk_min_pulse #(.NAME("led_oe_n[0]"),.ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1o (.clk(clk),.rst_n(rst_n),.sig(oe_n[0]),.err_cnt(a1_oe));
  chk_le_shift  #(.NAME_LE("led_le_o"),.NAME_SCK("led_clk_o"))         u_a2  (.clk(clk),.rst_n(rst_n),.le(le),.sck(clk_o),.err_cnt(a2_err));
  chk_xprop #(.W(1),.NAME("led_sdi")) u_a8s (.clk(clk),.rst_n(rst_n),.sig(sdi),  .err_cnt(a8_sdi));
  chk_xprop #(.W(1),.NAME("led_clk")) u_a8c (.clk(clk),.rst_n(rst_n),.sig(clk_o),.err_cnt(a8_clk));
  chk_xprop #(.W(1),.NAME("led_le"))  u_a8l (.clk(clk),.rst_n(rst_n),.sig(le),   .err_cnt(a8_le));
  chk_xprop #(.W(OE_N),.NAME("led_oe_n")) u_a8o (.clk(clk),.rst_n(rst_n),.sig(oe_n),.err_cnt(a8_oe));
  ```
  并在末尾把它们并进 `errors`。

- **收益 / 代价**：收益 = 引脚级防护回到**真正驱动引脚的模块**上。代价 = 只加 tb，**运行时间 +≈0**。

- **怎么验证能红**：把 bank 的 OE mux 改成 `assign oe_n_r = ~{OE_N{outputs_enable}}`（模拟 K-01 回归）⇒ `chk_min_pulse` 必须红。
  （这正是变异体 **M06** 的 bank 版本；M06 现在只打在 driver 上，见 `bringup/mutation_test.ps1:185`。）

---

### P1-4 · `tb_led_data` 没挂 A8（`chk_xprop`）

- **位置**：`tb/w3c/tb_led_data.sv`（全文无 `chk_xprop`）· 对照 `tb/w3a/tb_led_indicator.sv:104-109`、`tb/w3a/tb_ws2812_driver.sv:60-62` 都挂了

- **代码**：

```verilog
// tb_led_data.sv:62-63   ← 只取了两根线做值比对，没有任何 X/Z 监视
wire [KEY_N-1:0]        key_lights  = pattern[KEY_N-1:0];
wire [STATUS_N-1:0]     status_lights = pattern[KEY_N+STATUS_N-1:KEY_N];
```

- **机制 / 数字**：
  `led_data.pattern_o`（24 位）是**唯一**驱动 TLC 总线的源（`top.v:4854`）。
  它若含 X：`pattern_changed = (pattern_r !== pattern_next)` 用 `!==`（X 参与比较）⇒ **恒真**
  ⇒ `commit_r` **每拍拉高** ⇒ bank **每 27.1 µs 重写一轮**（占空 ≈ 100%，因为一轮 27.1 µs < 一拍周期？不，是每拍都来 ⇒ bank 永远在写）
  ⇒ 灯**持续闪烁/乱亮**，而所有 tb 都绿。
  ⚠️ 顺带裁定：`led_data.v:92` 用 `!==`（而非 `!=`）在这里是**正确的** —— `!=` 在 X 下会给出 X 并传播进 `commit_r`。
  ⛔ **不要把它"改成 `!=` 更规范"**，那会引入真 X 传播。

- **结构性 vs 布局**：⭐ **结构性**（判据缺失）。

- **怎么改**：
  ```verilog
  reg [31:0] a8_err;
  chk_xprop #(.W(24), .NAME("led_data.pattern_o")) u_a8 (
      .clk(clk), .rst_n(rst_n), .sig(pattern), .err_cnt(a8_err));
  // 末尾：chk("(8) no X/Z on pattern_o/commit after reset (A8)", a8_err == 32'd0);
  ```
  再加一条**不变量**断言（把 `!==` 的意图钉死）：`status_i` 故意置 `8'hxx` ⇒ 断言 `commit === 1'b1`（不是 `1'bx`）。

- **收益 / 代价**：收益 = 把"X 输入 ⇒ 灯狂闪"这条路堵上；代价 = 只加 tb。

- **怎么验证能红**：① 把 `status_i` 的某一位置 `1'bx` ⇒ `a8_err` 非 0；
  ② 把 `:92` 的 `!==` 改成 `!=`，在同一激励下断言 `commit !== 1'bx` ⇒ **必红**。

---

### P1-5 · `ws2812_driver` 的 `mem` 无复位 ⇒ 只写 7 颗灯（模块头自己推荐的用法）时 `dout_o` 出 13391 拍 X

- **位置**：`rtl/w3c/ws2812_driver.v:99-110`（写口无复位）· `:132-143`（复位块里**没有** `mem`）· `:16`（推荐用法）

- **代码**：

```verilog
// ws2812_driver.v:16  ← 模块头【自己推荐】的用法
//    (default 16; it must be >= 7 because there are 7 indicators)
```
```verilog
// ws2812_driver.v:99-110   ← mem 没有复位
reg [23:0] mem [0:(1<<LW)-1];
reg [23:0] rd_data;
reg [LW-1:0] rd_addr;

always @(posedge clk) begin
    if (wr_en_i && (wr_addr_i < LED_N))
        mem[wr_addr_i[LW-1:0]] <= wr_data_i;
end

always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end
```
```verilog
// ws2812_driver.v:132-143   ← 复位块里逐个清，但【没有 mem】
if (!rst_n) begin
    state <= S_IDLE; busy_o <= 1'b0; ld_cnt <= 2'd0; led_i <= 5'd0;
    bit_i <= 5'd23;  bit_t  <= 6'd0; rst_t  <= 16'd0;
    rd_addr <= {LW{1'b0}}; cur_bit <= 1'b0; sh <= 24'd0;
end
```

- **机制 / 数字**：
  `mem[7..15]` 在仿真里是 `x` ⇒ `rd_data = x` ⇒ `rd_grb = x` ⇒ `sh = x` ⇒ `cur_bit = x`
  ⇒ `dout_o = (state==S_SEND) && (bit_t < (cur_bit ? T1H : T0H))` = `1 && x` = **`x`**。
  预期拍数 = 9 颗未写的灯 × 24 bit × 62 拍 = **13392**。
  **⭐ 实测（`build/anvil11-probe/tb_anvil11_ws_probe.sv`，只写 LED0..LED6）**：
  ```
  X cycles on dout_o = 13391   (must be 0)
  VERDICT: X PROPAGATION REPRODUCED
  ```
  **13391 ≈ 13392**（差 1 是最后一位的边界）⇒ 机制完全对上。
  ⚠️ 为什么现在没炸：`top.v:5019-5043` 的写口 FSM **每帧把 addr 0..15 全写一遍**（LED7..15 写 `24'h000000`，`top.v:5012`），
  `tb_ws2812_driver.sv:150-151/188-189/222-225` 也**全写 16 颗** ⇒ 两条路都把 X 掩掉了。
  但**模块头推荐的"LED_N=7 只写 7 颗"用法会直接踩雷**，而 `tb_ws2812_driver.sv` 的 A8 判据（`:250`）**恒绿**。

- **结构性 vs 布局**：⭐ **结构性**。

- **怎么改**（推荐 (b)，最省）：
  (a) 复位块里清 `mem`：`for (i=0;i<(1<<LW);i=i+1) mem[i] <= 24'd0;`
  → **0 LUT**，但给 384 个 FF 加同步复位端（Gowin 的 FF 复位是专用端，通常不吃 LUT，但会让这 384 FF 无法进 BSRAM）。
  (b) ⭐ **只清读路径**（推荐）：
  ```verilog
  always @(posedge clk) begin
      rd_data <= (rd_addr >= LED_N) ? 24'd0 : mem[rd_addr];
  end
  ```
  → **+1 个 `LW` 位比较器（4 位）+ 24 位 2:1 mux ≈ 6~8 LUT**，**0 额外 FF**，且顺手把"越界读"也堵死。
  (c) 或在端口注释里把契约写成"**必须写满 LED_N 颗**"（0 代价，但**改的是契约而不是缺陷**，不推荐）。

- **收益 / 代价**：收益 = 消除"只写一部分灯 ⇒ 线上 X ⇒ 上板灯乱"的整类问题（也是 A8 判据真正生效的前提）。
  代价 = (b) ≈ **6~8 LUT**；(a) 0 LUT 但 384 FF 带复位。
  ⚠️ 对 Fmax：`rd_addr(4 FF) → 比较器 → mux → rd_data(24 FF)` 是 1~2 级 LUT，**远短于 18.181 ns**，属噪声级。

- **怎么验证能红**：把 `build/anvil11-probe/tb_anvil11_ws_probe.sv` 提升为正式 `tb/w3a/tb_ws2812_partial.sv`（只写 LED0..6 + `chk_xprop`）。
  未修 ⇒ `x_cnt = 13391`（我已实测）；修后 ⇒ `x_cnt = 0`。

---

### P1-6 · 5 根 LED 输出引脚在 `top.sdc` 里既无 `output_delay` 也无 `false_path`

- **位置**：`constr/top.sdc:62-71`（HP_* 有 `-max 2.0`；PA_EN_n / led_heartbeat 有 false_path）· `:101`（`set_max_delay`）· 对照 `constr/top.cst:290-309,470-471,488-493`

- **代码**：

```tcl
# constr/top.sdc:62-71  ← 只覆盖了这些
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]
set_false_path -from [get_ports {rst_n}]
```
```tcl
# constr/top.sdc:101
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
```
```
# 未出现在 sdc 里的 9 个 LED 引脚（全部在 .cst 里有 IO_LOC）：
led_le     A21 · led_sdi B21 · led_clk B18 · led_oe_n[4:0] B17/C17/D17/A19/A18 · ctrl_ws_o C22
```

- **机制 / 数字**：
  `set_max_delay -from [get_clocks X] -to [get_clocks X]` 约束的是**被 `X` 采样的路径**（寄存器↔寄存器）；
  **寄存器 → 输出引脚** 不在 `-to [get_clocks]` 的锥里 ⇒ 这 9 根线**根本不被分析**。
  而 `top.sdc:4-12` 早就写明这个教训（"只看零 error 会漏掉时钟/时序压根没被约束"）。
  实际风险量化：
  · `led_clk` = 1 MHz（半周期 500 ns），TLC5916 的 `tsu(ED2)=8.5 ns / th(ED2)=10 ns` ⇒ SDI 相对 CLK 的偏移必须 < **490 ns** ⇒ 20 ns 的 FPGA 周期**绰绰有余**；
  · `ctrl_ws_o`：WS2812B 的 `T0H/T1H` 容差 **±150 ns** ⇒ 也宽裕。
  ⇒ **物理风险低**，但**工具侧零检查**，违反本仓库 `top.sdc:39-40` 的明文纪律
  （"只有确实不要求时序的路径才配 `false_path`，且必须写清理由"）。

- **结构性 vs 布局**：⭐ **结构性**（约束缺口，与布局无关）。

- **怎么改**（二选一，⛔ 不要留白）：
  (a) 与 HP_* 同口径，给**真有时序含义**的三根加预算：
  ```tcl
  set_output_delay -clock clk_sys -max 2.0 [get_ports {led_clk}]
  set_output_delay -clock clk_sys -max 2.0 [get_ports {led_sdi}]
  set_output_delay -clock clk_sys -max 2.0 [get_ports {led_le}]
  ```
  (b) 给**静态/人眼/宽容差**的加 false_path 并**写明理由**：
  ```tcl
  # led_oe_n[*] = 分板消隐，静态电平选择，无相对时序要求（换片只在 CLK 静止后发生）
  set_false_path -to [get_ports {led_oe_n[*]}]
  # ctrl_ws_o = WS2812B 单线，位容差 ±150 ns >> clk_sys 周期 20 ns
  set_false_path -to [get_ports {ctrl_ws_o}]
  ```

- **收益 / 代价**：收益 = 补齐工具侧闭环（`top.sdc:97-98` 的验收三步才成立）。
  代价 = **0 硬件**；⚠️ 可能让 PnR **新报 1~2 条 setup 违例** —— 那是"暴露了真问题"，不是回归。
  ⚠️ 加 `set_output_delay` 会像 2026-10-01 那次一样**让结果对布局更敏感**（`top.sdc:45-61` 的教训）⇒ 建议先用 (b) 把 4 根宽容差的钉成 false_path，(a) 只给 `led_clk/led_sdi/led_le`。

- **怎么验证能红**：`top.sdc:97-98` 的验收三步 —— ① Constraints Report 里这 9 个对象**全部 Actived 且非空**；
  ② Timing Exceptions Report 确认覆盖到目标锥；③ 对**同一份 PnR 结果**复算 Fmax 与四类 slack。
  ⛔ 别只看 Fmax 汇总（那正是 `top.sdc:98` 点名的坑）。

---

### P2-1 · 顶层 WS2812 以 1.141 kHz 背靠背连发，而 WS2812 是自保持器件

- **位置**：`rtl/top.v:5019-5045`（`WLS_WAIT` 一见 `!ws_busy` 立刻开下一帧）· `:4932`（`WS_LED_N=16`）· `:4999-5014`（写口 `case`）· `ws2812_driver.v:62`（`RST_CYC=20000`）

- **代码**：

```verilog
// top.v:5026-5031   ← 没有任何"变了才发"的条件
case (ws_ld_state)
    WLS_WAIT: if (!ws_busy) begin
        ws_wr_en    <= 1'b1;
        ws_wr_addr  <= 5'd0;
        ws_ld_state <= WLS_WRITE;
    end
```

- **机制 / 数字**：
  一帧 = 16 颗 × 24 bit × 62 拍 + `RST_CYC` 20000 拍 = 23808 + 20000 = **43808 拍 = 876.2 µs** ⇒ **刷新率 1.141 kHz**。
  其中 **54.3%** 在发数据（23808/43808）、**45.7%** 在复位低电平。
  WS2812B **自保持**（锁存后不需要刷新，没有看门狗）⇒ 这 1.141 kHz **在功能上是零收益**的。
  代价侧：① `ctrl_ws_o`（C22）每秒翻转 ≈ 1.14k × 24 × 7 ≈ **19 万次/秒**（7 颗灯的平均翻转率）；
  ② `mem` 每秒被重写 1.14k × 16 = **18.3 千次/秒**；
  ③ 这是一块**音频板**，C22 与模拟链在同一块控制板上 ⇒ 持续的 800 kHz 码流是**可避免的耦合源**。

- **结构性 vs 布局**：⭐ **结构性**（架构选择）。⚠️ 对 Fmax 的影响是**布局/拥塞级**：168 位比较器 ≈ 42 LUT，
  在 CLS 78%（23228/29952）的树上属 ±0.1 MHz 量级，**落在 2~3 MHz 的布局噪声里，测不出来** —— ⛔ 不要把它当"时序优化"卖。

- **怎么改**：把 `WLS_WAIT` 改成"**图案变了才发**"（与 `led_data` 的 commit 同思想）：
  ```verilog
  reg [NCH_LED*24-1:0] led_col_d;
  always @(posedge clk) if (!rst_n_sync) led_col_d <= {(NCH_LED*24){1'b0}};
                        else             led_col_d <= led_col_flat;
  wire led_dirty = (led_col_flat !== led_col_d);
  // WLS_WAIT: if (!ws_busy && led_dirty) begin ... end
  ```
  ⚠️ 两条纪律：① 比较的是**指示层输出之后**的 `led_col_flat`（不是状态码），否则快闪变化会被漏掉；
  ② `!==` 而非 `!=`（与 `led_data.v:92` 同理由，X 输入下仍然"要发"而不是"不发"）。

- **收益 / 代价**：收益 = 稳态下 C22 活动降到 **≈0**（只在图案变化时爆发 876 µs）、`mem` 写降到 0、省掉整套 FSM 的连续活动。
  代价 = **+168 FF（影子寄存器）＋ 168 位比较器（≈42 LUT）** ⇒ ⚠️ 在 CLS 78% 的树上**净资源是增加的**，
  换的是动态功耗与模拟耦合。若嫌 168 FF 贵，可只比 7×24 = 168 位中的有效位（已经是 168）或改成比"指示层输入状态码"（更省但漏快闪）。
  ⚠️ **风险中等**：比较器写错会让灯**卡住不更新**。

- **怎么验证能红**：`tb_top_led_strip.sv` 的 **(2) 活体判据**（`:269-279`，发裸 `'I'` 切音色 ⇒ 下一帧 LED0 必须变青）**正好就是这条的判据** —— 改完必须仍然绿。
  再加一条：连续两帧之间若图案没变，断言线上**没有**新的帧起点（低电平持续 > 10000 拍不被打断）。

---

### P2-2 · `tlc5916_driver` 恢复序列用 32 位有符号 `integer` + 对 50 取模（`%`）

- **位置**：`rtl/drivers/tlc5916_driver.sv:144-145`（`integer` 声明）· `:224-227`（`%` 与 32 位减法）· `:240-241`（两个 32 位有符号比较）· `:131-138`（常量）

- **代码**：

```verilog
// tlc5916_driver.sv:144-145   ← 32 位【有符号】
integer            rec_phase;               // 稳定期之后过了几拍
integer            rec_in_period;           // 在当前 tlc_clk 周期内的相位
```
```verilog
// tlc5916_driver.sv:224-227
rec_phase     = rec_cnt - REC_SETTLE_CLKS;
rec_in_period = rec_phase % REC_CLK_PERIOD;      // ← 对【50】取模（非 2 的幂）
tlc_clk  <= (rec_in_period < HALF_DIV) ? 1'b1 : 1'b0;
```
```verilog
// tlc5916_driver.sv:240-241
tlc_oe_n <= (rec_phase >= REC_OE_FALL_PH &&
             rec_phase <  REC_OE_FALL_PH + REC_CLK_PERIOD) ? 1'b0 : 1'b1;
```
```verilog
// tlc5916_driver.sv:131-138
localparam integer REC_CLK_PERIOD = 2 * HALF_DIV;        // = 50
localparam integer REC_OE_FALL_PH = HALF_DIV + (HALF_DIV / 2);  // = 37
```

- **机制 / 数字**：
  · `REC_CLK_PERIOD = 50`（**非 2 的幂**）⇒ `%` 综合成"减法-移位/比较"网络，而不是取位。
  · `rec_phase` 的实际取值范围是 **0..299**（`REC_TOTAL_CLKS = 8 + 6×50 = 308`），**只需 9 位**，
    却按 **32 位有符号**参与 1 次减法 + 1 次取模 + **4 个 32 位比较器**。
  · 保守估计多花 **60~100 LUT** 与若干 `T_Alu`（对照 `tlc5916_driver` 整体量级：本模块在顶层 `T_Lut` 里只是零头）。

- **结构性 vs 布局**：⭐ **结构性（宽度/面积），但【不是】关键路径**。
  路径是 `rec_cnt(9 FF) → 32 位减 → %50 → 比较 → tlc_clk/tlc_oe_n FF`，估算 **3~5 级 LUT ≈ 1.5~2.5 ns**，
  离 **18.181 ns** 预算很远；而且它**只在上电后跑一次**（`recovering` 之后永不再置 1，`:201`）
  ⇒ 对**稳态 Fmax 的贡献 = 0**。⛔ 不要把它当"时序问题"报。

- **怎么改**（(a) 最优）：
  (a) 用**自由运行的相位计数器**替掉 `%`：
  ```verilog
  reg [5:0] rec_ph;                     // 0..REC_CLK_PERIOD-1
  // 在恢复分支里：
  rec_ph <= (rec_ph == REC_CLK_PERIOD-1) ? 6'd0 : rec_ph + 6'd1;
  tlc_clk  <= (rec_ph < HALF_DIV) ? 1'b1 : 1'b0;
  // OE 低窗口仍用【绝对相位】判（保住 K-66 的"跨 1 个上升沿"）
  ```
  (b) 把 `rec_phase` / `rec_in_period` 声明成 `reg [REC_W-1:0]` / `reg [5:0]`（**无符号、窄位**）⇒ 4 个比较器从 32 位降到 9/6 位。

- **收益 / 代价**：收益 = 省 ≈ **60~100 LUT**（在 CLS 78% 的树上属**拥塞缓解**，不是 Fmax 修复）。
  代价 = (a) **+6 FF**（相位寄存器）；(b) **0 FF**。
  ⚠️⚠️ **改完必须逐条复跑 `tb_tlc5916_driver.sv:431-481` 的 K-66 五条判据**
  （跨 1 个 CLK 上升沿 / LE 全程低 / OE 低 ≥ 500 ns / ≥5 个 CLK 周期 / 每次复位恰好一次）——
  那五条就是为这段波形写的，⛔ 一条都不能省。

- **怎么验证能红**：把 `%` 改成错的（如 `rec_phase % (REC_CLK_PERIOD - 1)`）⇒
  K-66 的"**每个恢复窗口恰好跨过 1 个 CLK 上升沿**"（`:443-450`）**必红**。

---

### P2-3 · `led_indicator` 的 −1.148 MHz 是布局/拥塞，**不是**结构性长路径 —— 明确不建议做流水

- **位置**：`rtl/w3a/led_indicator.v:128-129`（展开的颜色表）· `:194-205`（168 FF 无条件写）

- **代码**：

```verilog
// led_indicator.v:128-129
reg [23:0] col_c [0:N_CH-1];
reg [1:0]  blk_c [0:N_CH-1];
```
```verilog
// led_indicator.v:194-205
always @(posedge clk) begin
    if (!rst_n) begin
        led_col_o <= {(N_CH*24){1'b0}};
    end else begin
        for (oi = 0; oi < N_CH; oi = oi + 1) begin
            led_col_o[oi*24 +: 24] <=
                ((blk_c[oi] == BL_FAST) &&  fast_off)  ? C_OFF :
                ((blk_c[oi] == BL_BEAT) && !beat_lit)  ? C_OFF :
                                                         col_c[oi];
        end
    end
end
```

- **机制 / 数字**（这是本轮最需要"钉死归属"的一条）：
  · 加指示层的 A/B 实测：**`Fmax` 53.187 → 52.039 MHz = −1.148 MHz**；资源 **`T_Lut` +91 · `T_Register` +203**
    （`sim/evidence/led-indicator-20261003/README.md:40,53-54`；累计口径见 `sim/evidence/p5-2-osc-20261004/README.md:101`）。
  · **判读依据 1（自身深度）**：`led_indicator` 的组合深度 ≈ **2~3 级 LUT**
    （`col_c[oi]` 的 case 译码 1 级 → `blk_c[oi]` 2 位比较 1 级 → 两级 2:1 mux 各 1 级），
    折合 **≈1.5 ns**，**远短于** 18.181 ns。
  · **判读依据 2（全局关键路径没变）**：加它**之前**（`led-indicator-20261003/timing.txt:78`）与
    **之后**的交付树（`final-batch-20261008/timing.txt:78`）`clk_sys` 的 **`Logic Level` 都是 10** ⇒
    **关键路径根本不在 `led_indicator` 里**。
  · **判读依据 3（同批的因果已写明）**：`p5-2-osc-20261004/README.md:97-101` 把随后 **+3.558 MHz** 归因于
    "少了 724 LUT / 544 FF ⇒ **布局拥塞下降** ⇒ `note_manager` 那条路径**布线大幅变短**"
    ⇒ 反过来说明**+91 LUT 的指示层是加了拥塞**，不是加了自己的长路径。
  ⇒ ⭐ **裁定：−1.148 MHz = 布局/拥塞运气，属那 2~3 MHz 的噪声带。**

- **结构性 vs 布局**：⭐⭐ **布局运气**（明确结论）。

- **怎么改**：⭐ **不建议做**（收益 < 测量噪声）。若**一定要动**，唯一有意义的方向是给输出级加**写使能**（降 168 FF 的翻转与扇出）：
  ```verilog
  wire [N_CH*24-1:0] led_next = /* 上面那个三元表达式向量化 */;
  if (led_col_o !== led_next) led_col_o <= led_next;
  ```
  ⚠️ 提醒：Gowin 的 FF 有专用 CE 端，所以 CE 版**通常不吃 LUT**，但会改变 FF 类型（可能影响 CLS 打包）⇒ 净效果**正负难料**。

- **收益 / 代价**：收益 ≈ **±0.1~0.3 MHz 量级**（**测不出来**）；代价 = 约 +24 个比较器位（≈6 LUT）+ 一轮 PnR（10 分钟）+ 必须重跑四道门。
  ⇒ ⭐ **结论：不做。** 这条写出来是为了把"−1.148 MHz"这个数字的**归属钉死**，防止后续有人把它当"结构性长路径"去加流水（那是**纯浪费**）。

- **怎么验证能红**：任何改动都必须让 `tb_led_indicator.sv` 的 7 组判据保持全绿，特别是
  **(7c) 相邻上升沿间隔恒 == 2^FAST_DIV**（`:371-372`）—— 那是"共享快闪计数器"这个省资源手法的**唯一**守卫。

---

### P2-4 · `tlc5916_bank` 的 `drv_oe` 是死网 ＋ `drv_data_r` 是多余的一级

- **位置**：`rtl/w3c/tlc5916_bank.sv:147`（声明）· `:163`（连接）· `:183`/`:194`（`drv_data_r` → `drv_data`）

- **代码**：

```verilog
// tlc5916_bank.sv:147,163
wire        drv_oe;      // driver 的 OE 输出（我们另外做分板 mux）
    .tlc_oe_n       (drv_oe),        // ← 全文【再无第二处】引用
```
```verilog
// tlc5916_bank.sv:183,187-194
reg [CHIP_W-1:0] drv_data_r;
always @(*) begin
    case (chip_sel)
        2'd0: drv_data_r = chip0_out;
        2'd1: drv_data_r = chip1_out;
        default: drv_data_r = chip2_out;
    endcase
end
assign drv_data = drv_data_r;        // ← 只是给 reg 起了个 wire 别名
```

- **机制 / 数字**：`drv_oe` 消费者 **0 个**（机械确认：全文 2 处 = 声明 + 连接）
  ⇒ 综合会优化掉它，且 `K-01`/`K-57` 的防护跟着一起消失（**这正是 P1-1 的根因**）。
  `drv_data_r` 的中间级是纯风格冗余（`drv_data` 与 `drv_data_r` 同宽同值），0 逻辑代价。

- **结构性 vs 布局**：⭐ **结构性**（死网）。

- **怎么改**：
  · `drv_oe` ⛔ **不能删** —— 必须按 **P1-1** 接成 OE 总闸（`assign led_oe_n_o = oe_n_r | {OE_N{~drv_oe}};`）。
  · `drv_data_r` 可改名成 `drv_data` 并去掉别名（纯风格，0 收益，⚠️ 会动到 `M126`/`M127` 变异锚点之外的行，安全）。

- **收益 / 代价**：收益 = 与 P1-1 合并计算（5 个 OR 门恢复 K-01 防护）；本条自身 0。
  代价 = 0。

- **怎么验证能红**：综合日志里**不应**再出现 `drv_oe` 相关的 unused/optimized 警告；
  P1-1 的新增断言（1 拍 `global_blank_i` 引脚不动）同时覆盖它。

---

### P2-5 · `ws2812_driver` 的 `mem` 读写竞争 ⇒ 模块头承诺的"飞行中写只影响下一帧"不成立

- **位置**：`rtl/w3c/ws2812_driver.v:52-53`（承诺）· `:103-110`（读写口）· `:202-205`（预取窗口）

- **代码**：

```verilog
// ws2812_driver.v:52-53  ← 承诺
//    A write that lands while the frame in flight
//    is being read simply takes effect on the next frame.
```
```verilog
// ws2812_driver.v:103-110   ← 读写共用 mem，无互斥
always @(posedge clk) begin
    if (wr_en_i && (wr_addr_i < LED_N))
        mem[wr_addr_i[LW-1:0]] <= wr_data_i;
end
always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end
```
```verilog
// ws2812_driver.v:202-205   ← 预取窗口只有 3 拍
if ((bit_i == 5'd0) && (led_i != LED_N - 1)) begin
    if      (bit_t == 6'd56) rd_addr <= led_nxt[LW-1:0];
    else if (bit_t == 6'd58) sh      <= rd_grb;
end
```

- **机制 / 数字**：
  预取是"**地址在 bit_t=56 设、数据在 57 落地、sh 在 58 装**"⇒ 存在 **3 拍 = 60 ns** 的窗口，
  窗口内 `rd_data` 的值**取决于写口是否恰好在写同一颗灯**。
  若写口在这 3 拍里写 `rd_addr` 指向的**同一颗** LED ⇒ 当前帧的那颗灯会**半新半旧**（撕裂）。
  ⇒ 承诺（"只影响下一帧"）**不成立**；真实语义是"**当且仅当写口与预取不撞同一颗灯时才只影响下一帧**"。
  ⚠️ 今天不炸是因为 `top.v:5027` 的 `WLS_WAIT: if (!ws_busy)` **把写口挡在帧外** —— 那是**调用方**的纪律，⛔ 不是模块的保证。
  ⚠️ 而模块头 `:49-53` 的 USAGE 段落**没有**把这条写成前置条件，反而用"simply"把它说成保证。

- **结构性 vs 布局**：⭐ **结构性**（契约缺陷）。

- **怎么改**：
  (a) ⭐ **推荐（0 代价）**：把承诺降级为**前置条件**，写进端口注释：
  ```verilog
  input wire wr_en_i,   // ⚠️ 只在 busy_o == 0 时给；帧内写同一颗 LED 会撕裂当前帧
  ```
  并把 `:52-53` 那句改成"调用方保证 `wr_en_i` 只在 `busy_o==0` 时有效"。
  (b) 双缓冲（写 shadow，`start_i` 那一拍整体搬运）⇒ **+384 FF**，⛔ **不划算，不做**。

- **收益 / 代价**：收益 = 契约诚实，避免后续调用方（例如把 WS2812 也接到指引链）踩雷。
  代价 = **0 硬件**（纯注释）；若选 (b) 是 +384 FF（拒绝）。

- **怎么验证能红**：tb 在 `busy_o == 1` 期间、且恰在 `bit_t ∈ {56,57,58}` 时写"正在被预取的那颗"LED，
  断言该帧线上字节**仍等于旧值**。**对当前 RTL 必红**（会取到新值）。

---

### P2-6 · `ws2812_driver` 是六个灯模块里唯一没有参数自检的

- **位置**：`rtl/w3c/ws2812_driver.v`（**全文无 `initial` 块**）· 对照 `led_indicator.v:80-87`、`led_data.v:110-115`、`tlc5916_bank.sv:270-277`、`tlc5916_driver.sv:91-98`

- **代码**：

```verilog
// ws2812_driver.v:79-82   ← LW 在 5 位封顶
localparam integer LW = (LED_N <=  2) ? 1 :
                        (LED_N <=  4) ? 2 :
                        (LED_N <=  8) ? 3 :
                        (LED_N <= 16) ? 4 : 5;
```
```verilog
// ws2812_driver.v:45   ← 注释给的下界
//    This requires BIT_CYC >= 61 (the prefetch window lives below BIT_CYC-1).
```
```verilog
// 对照：兄弟模块都有 initial 自检
// led_indicator.v:80-87   initial begin if (FLASH_CYC > ((1<<23)-1)) $display("ERROR ...") ...
// led_data.v:110-115      initial begin if (KEY_N < 1) $display("ERROR ...") ...
// tlc5916_bank.sv:270-277 initial begin if (KEY_CHIPS + STATUS_CHIPS < 1) ...
// tlc5916_driver.sv:91-98 initial begin if (OE_NS < 500) ...
// ws2812_driver.v          —— 没有
```

- **机制 / 数字**：
  · `LED_N > 32`：`LW` 夹在 **5** ⇒ `mem` 深度 32，而 `led_i` 只有 5 位 ⇒ `led_i == LED_N-1` **永不成立**
    ⇒ 最后一颗之后的边界判断错，**图案错位**且**静默**（0 报错、0 警告）。
  · `BIT_CYC < 60`：预取在 `bit_t==58`，且必须落在 `bit_t != BITN-1` 的分支里 ⇒ 需 `58 < BIT_CYC-1` ⇒ **真实下界是 60**，
    而注释写的是 **61**（多算了 1 拍）。若真取 59 或更小，预取窗口与边界判断**撞车** ⇒ 位周期被拉长、图案错位。
  · `T0H_CYC/T1H_CYC` 被塞进 `localparam [5:0]`（`:84-85`）⇒ 传 **>63** 的值**静默截断**。
  · `RST_CYC` 塞进 `localparam [15:0]`（`:87`）⇒ 传 **>65535** 静默截断。

- **结构性 vs 布局**：⭐ 无（这是护栏，不影响时序）。

- **怎么改**（照抄兄弟模块的 `PARAM_OK` 套路，`:89` 的 `TLC_PARAM_OK` 是最佳范例）：
  ```verilog
  localparam WS_PARAM_OK = (LED_N >= 7) && (LED_N <= 32) &&
                           (BIT_CYC >= 60) && (T0H_CYC < T1H_CYC) && (T1H_CYC < BIT_CYC) &&
                           (RST_CYC >= 15000) && (RST_CYC <= 65535) &&
                           (T0H_CYC <= 63) && (T1H_CYC <= 63);
  initial begin
      if (LED_N > 32)    $display("ERROR [ws2812] LED_N=%0d > 32 ⇒ LW 封顶 5 位，led_i 表示不了 (K: 见 ws2812_driver.v:79)", LED_N);
      if (BIT_CYC < 60)  $display("ERROR [ws2812] BIT_CYC=%0d < 60 ⇒ 预取窗口(bit_t=58)与边界判断撞车", BIT_CYC);
      if (T0H_CYC > 63 || T1H_CYC > 63) $display("ERROR [ws2812] T*H_CYC 超过 6 位 ⇒ 静默截断");
      if (RST_CYC > 65535) $display("ERROR [ws2812] RST_CYC 超过 16 位 ⇒ 静默截断");
  end
  ```
  并把 `:45` 的 `61` 改成 **`60`**（见 P3-3）。

- **收益 / 代价**：收益 = 换参数时**看得见**（而不是上板才发现灯乱）。
  代价 = **0 硬件**（综合忽略 `initial`）；⛔ 但**仿真侧只是 `$display`**，按 `K-57` 的教训（`M14` 当年没被抓到）
  建议**在 tb 里把它提成硬断言**（`tb_tlc5916_driver.sv:408-420` 就是那个修法的范例）。

- **怎么验证能红**：仿 `LED_N=40` 实例 ⇒ 必须打印 ERROR；再加 tb 断言 `dut.WS_PARAM_OK === 1'b1` ⇒ 该实例**必红**。

---

### P2-7 · `led_data` 的 `if (STATUS_N < 0)` 永远不触发，而真正会炸的 `STATUS_N=0` 没被拦

- **位置**：`rtl/w3c/led_data.v:62`（端口声明）· `:113-114`（自检）

- **代码**：

```verilog
// led_data.v:62
input  wire [STATUS_N-1:0]      status_i,         // 状态灯（模式/音色/N，已编码）
```
```verilog
// led_data.v:113-114
if (STATUS_N < 0)
    $display("ERROR [led_data] STATUS_N=%0d 必须 >= 0", STATUS_N);
```

- **机制 / 数字**：
  `STATUS_N` 是 `integer` 参数（`:54`）⇒ `STATUS_N < 0` **只在传负数时**成立。
  而真正会炸的是 **`STATUS_N = 0`**：此时 `status_i` 的位选范围是 **`[-1:0]`**（非法范围）。
  ⇒ 自检**对唯一能炸的值不生效**，是**死代码**（category ②）。
  ⚠️ 顺带：`pattern_o` 的宽度 `[KEY_N+STATUS_N-1:0]` 在 `STATUS_N=0` 时是 `[15:0]`，**是合法的** ⇒
  错误只会出现在 `status_i` 的声明上，报错信息离根因很远。

- **结构性 vs 布局**：⭐ 无（护栏）。

- **怎么改**：
  ```verilog
  if (STATUS_N < 1)
      $display("ERROR [led_data] STATUS_N=%0d 必须 >= 1（=0 会让 status_i 的范围变成 [-1:0]）", STATUS_N);
  ```
  或把端口宽度改成 `[((STATUS_N < 1) ? 1 : STATUS_N)-1:0]` 并保留 `STATUS_N>=1` 自检。

- **收益 / 代价**：收益 = 换参数时报出真因；代价 = **0 硬件**。

- **怎么验证能红**：用 `STATUS_N=0` 实例化 ⇒ 当前会**编译期报范围错/综合报错**（而不是打印 ERROR）；
  修后应打印 ERROR 且**编译通过**。

---

### P2-8 · `tlc5916_bank` 的 FSM 只支持 3 片，但 `KEY_CHIPS/STATUS_CHIPS` 没被这个上限约束

- **位置**：`rtl/w3c/tlc5916_bank.sv:181`（`chip_sel` 2 位）· `:245`（终止条件硬编码 `2'd2`）· `:187-193`（`default` 兜底）· `:270-277`（自检）

- **代码**：

```verilog
// tlc5916_bank.sv:181
reg [1:0]  chip_sel;      // 0/1 = 键灯片，2 = 状态灯片
```
```verilog
// tlc5916_bank.sv:243-254   ← 终止条件写死 2'd2
if (!drv_busy && drv_done) begin
    if (chip_sel == 2'd2) begin
        chip_sel <= 2'd0; busy_r <= 1'b0; state <= S_IDLE;
    end else begin
        chip_sel <= chip_sel + 2'd1;
        state    <= S_START;
    end
end
```
```verilog
// tlc5916_bank.sv:270-277   ← 自检没查"片数 <= 3"
if (KEY_CHIPS + STATUS_CHIPS < 1)          $display("ERROR ... 至少 1 片 TLC5916");
if (CHIP_W != 8)                           $display("ERROR ... CHIP_W=%0d 非法", CHIP_W);
if (OE_N < KEY_CHIPS + STATUS_CHIPS)       $display("ERROR ... OE_N=%0d 少于片数 %0d", ...);
// ⛔ 没有：if (KEY_CHIPS + STATUS_CHIPS > 3) ...
```

- **机制 / 数字**：
  `KEY_CHIPS + STATUS_CHIPS > 3` 时（例如 `KEY_CHIPS=3, STATUS_CHIPS=1` ⇒ 4 片）：
  FSM 在 `chip_sel == 2'd2` 就回 `S_IDLE` ⇒ **第 4 片永远不被写**（0 报错、0 警告、`busy_o` 正常回落）。
  而 `drv_data_r` 的 `default: drv_data_r = chip2_out;`（`:191`）会把 **≥2 的所有片**都当片2
  ⇒ 若将来真扩到 4 片，片3 会拿到片2 的图案。
  当前配置（2+1=3）**正好卡在上限**，所以今天不出错 —— 但**下一个加片的人会静默踩雷**。

- **结构性 vs 布局**：⭐ 无（护栏）。

- **怎么改**（(a) 只加护栏，(b) 真参数化）：
  (a) `if (KEY_CHIPS + STATUS_CHIPS > 3) $display("ERROR [tlc5916_bank] 片数 %0d > 3：FSM 的 chip_sel 与终止条件只支持 3 片", KEY_CHIPS+STATUS_CHIPS);`
  (b) 真参数化：`localparam integer NCHIP = KEY_CHIPS + STATUS_CHIPS;`
      `reg [$clog2(NCHIP)-1:0] chip_sel;` 终止条件改 `chip_sel == NCHIP-1`，
      `drv_data_r` 的 `case` 用 generate 展开（⛔ 注意本仓库 `K-91`：`$clog2` 在 Gowin 里可用，但 `longint'()` 不可用）。

- **收益 / 代价**：(a) **0 硬件**；(b) +0 FF、+1 个常量比较器，但**改动面较大**（`chip_sel` 位宽、OE mux 的 `else` 分支要一起参数化），风险中等。

- **怎么验证能红**：`KEY_CHIPS=3, STATUS_CHIPS=1` 实例化 ⇒ 必须打印 ERROR；
  再加 tb 断言"4 片配置下 4 个 `chip_sel` 都被访问过"⇒ 当前**必红**（只访问 0/1/2）。

---

### P3-1 · `guide_lamp.v` 无 `` `timescale `` / 无 `` `default_nettype none `` ⇒ 每次回归刷 250+ 行噪声

- **位置**：`rtl/w3c/guide_lamp.v:1`（文件头直接是注释）· `:30`（`module`）· 文件末尾（无 `` `default_nettype wire ``）

- **代码**：

```verilog
// guide_lamp.v:1   ← 没有 `timescale
// ═══════════════════════════════════════════════════════════════════════════
//  guide_lamp.v —— 音符事件 → 灯位指引映射层（丙线 · P1 · 2026-10-03）
```
```verilog
// guide_lamp.v:28-30
// ═══════════════════════════════════════════════════════════════════════════

module guide_lamp #(
```
对照（其余五个灯模块全都有）：`ws2812_driver.v:1`、`led_indicator.v:1`、`led_data.v:1`、`tlc5916_bank.sv:1`、`tlc5916_driver.sv:1` 都是 `` `timescale 1ns/1ps ``。

- **机制 / 数字**：
  缺 `` `timescale `` ⇒ iverilog 按**编译顺序**从前一个文件继承，并每次报
  `warning: timescale for guide_lamp inherited from another file.`
  **实测计数**：`sim/evidence/final-batch-20261008/regression-full.log` 里这一句出现 **250+ 次**（每个 tb 编译一次）。
  本轮我自己编译时也复现（`rtl/w3c/guide_lamp.v:30: warning: timescale for guide_lamp inherited from another file`）。
  缺 `` `default_nettype none `` ⇒ 打错信号名会**静默生成 1 位隐式网线**（本仓库 `top.v:741` 明确记过这个坑）。
  ⚠️ `guide_lamp` 内部没有延时，所以**当前无功能影响** —— 但 250 行噪声会**掩盖真警告**，这是真实成本。

- **结构性 vs 布局**：⭐ 无（卫生/可观测性）。

- **怎么改**：
  ```verilog
  `timescale 1ns/1ps
  `default_nettype none
  // ... module ...
  `default_nettype wire
  ```
  并在 `` `default_nettype none `` 打开后**补上所有中间信号的显式声明**（`is_note_on`/`is_note_off`/`note_kind`/`note_axis` 已是 `wire`，OK）。

- **收益 / 代价**：收益 = 回归日志少 250+ 行噪声 + 打错名字会报错；代价 = **0 硬件**。

- **怎么验证能红**：编译时 `warning: timescale for guide_lamp inherited` **必须消失**（`grep` 回归日志计数 == 0）。

---

### P3-2 · `guide_lamp` 的 `note_axis` 硬编码 4 位，`AXIS_N < 16` 时越界写

- **位置**：`rtl/w3c/guide_lamp.v:31-32`（参数）· `:63`（4 位切片）· `:84`/`:89`（索引赋值）

- **代码**：

```verilog
// guide_lamp.v:31-32
parameter integer EVT_W = 64,        // 事件数据位宽（与 play_seq 一致）
parameter integer AXIS_N = 16        // 键位数（轴号 0..15）
```
```verilog
// guide_lamp.v:63
wire [3:0]  note_axis = note_data_i[AXIS_SH +: 4];   // 轴号 0..15
```
```verilog
// guide_lamp.v:84,89
guide_key_o[note_axis] <= 1'b1;
guide_key_o[note_axis] <= 1'b0;
```

- **机制 / 数字**：
  `note_axis` 恒为 **4 位（0..15）**，与 `AXIS_N` **无关**。
  若 `AXIS_N < 16`（例如 8）：`guide_key_o[note_axis]` 对 `note_axis >= AXIS_N` 是**越界写**
  ⇒ 仿真**静默丢位**，综合可能生成错接/锁存。0 报错、0 警告。
  当前 `AXIS_N = 16`（`top.v` 未例化，tb 用 16）⇒ **今天安全**。

- **结构性 vs 布局**：⭐ 无（护栏）。

- **怎么改**：
  ```verilog
  localparam integer AXIS_W = (AXIS_N <= 1) ? 1 : $clog2(AXIS_N);   // AXIS_N=16 ⇒ 4
  wire [AXIS_W-1:0] note_axis = note_data_i[AXIS_SH +: AXIS_W];
  // 并加自检（当前契约就是 16）
  initial if (AXIS_N != 16) $display("ERROR [guide_lamp] AXIS_N=%0d：位域契约固定 4 位（轴 0..15）", AXIS_N);
  ```
  ⚠️ 注意本仓库 `K-91`：`$clog2` 在 Gowin 里可用，但 **`longint` / `longint'()` 不可用**（`tlc5916_driver.sv:71-86` 记过）。

- **收益 / 代价**：收益 = 换 `AXIS_N` 时不会静默错；代价 = **0 硬件**（`AXIS_N=16` 时 `AXIS_W=4`，与现状逐位等价）。

- **怎么验证能红**：`AXIS_N=8` 实例 + 喂 `axis=15` 的 `note_on` ⇒ 当前**静默无输出**（灯不亮且不报错）；
  修后必须打印 ERROR。

---

### P3-3 · `ws2812_driver.v:45` 注释写预取下界 61，实际是 60

- **位置**：`rtl/w3c/ws2812_driver.v:45`（注释）· `:61`（参数注释）

- **代码**：

```verilog
// ws2812_driver.v:44-45
//    therefore no "reload gap" that would stretch one bit.  This requires
//    BIT_CYC >= 61 (the prefetch window lives below BIT_CYC-1).
```
```verilog
// ws2812_driver.v:61
parameter integer BIT_CYC = 62,     // bit period, cycles @50 MHz (>= 61)
```

- **机制 / 数字**：
  预取在 `bit_t == 6'd56`（设地址）与 `bit_t == 6'd58`（装 sh），且这两句在 `else`（即 `bit_t != BITN-1`）分支里。
  要保证 `58` 落在这个 `else` 分支，需 **`58 < BIT_CYC - 1`** ⇒ **`BIT_CYC >= 60`**。
  注释写 **61** 是**多算了 1 拍**（保守，但不准确）。

- **结构性 vs 布局**：⭐ 无（注释准确性）。

- **怎么改**：`:45` 与 `:61` 的 `61` 改成 `60`；若想保留保守值，就写成"实际下界 60，这里取 61 留 1 拍余量"。

- **收益 / 代价**：收益 = 换参数时不会误以为 60 不可用；代价 = 0。

- **怎么验证能红**：用 `BIT_CYC=60` 实例化，跑**参数化**的位周期判据（`== 60` 拍）⇒ 当前 RTL 应该**通过**
  （即证明 60 是可行的，注释的 61 偏保守）。⚠️ 直接用 `tb_ws2812_driver.sv:168-169` 的 `62..63` 判据会红 —— 那是参数变了，不是 bug。

---

### P3-4 · `ws2812_driver.v:220` 的 `default` 不可达（4 个状态全枚举）—— 死逻辑，⛔ 不要删

- **位置**：`rtl/w3c/ws2812_driver.v:89-92`（4 个状态）· `:120`（`reg [1:0] state`）· `:220`（`default`）

- **代码**：

```verilog
// ws2812_driver.v:89-92,120
localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_SEND = 2'd2, S_RST = 2'd3;
reg [1:0]  state;
```
```verilog
// ws2812_driver.v:220
default: state <= S_IDLE;
```

- **机制 / 数字**：`state` 是 **2 位**，四个编码 **0/1/2/3 全部有定义** ⇒ `default` 分支**不可达**，
  综合会删掉它（0 逻辑）。⚠️ **对比 `tlc5916_driver.sv:352-359`**：那里 `state` 是 **3 位**却有 **5 个状态（0..4）**，
  `default` 覆盖 3 个未用编码（5/6/7）⇒ 那里是**必需**的安全网。

- **结构性 vs 布局**：⭐ 无。

- **怎么改**：**不改**（保留作防御）。⚠️ 但若将来把 `state` 扩成 3 位或加状态，这个 `default` 就**变成必需** —— 注释里应写明这一点。

- **收益 / 代价**：收益 = 防止后来者"清理死代码"时误删安全网；代价 = 0。

- **怎么验证能红**：无行为差异 ⇒ 用综合报告的 "unreachable branch" 类警告作为证据（若有）。

---

### P3-5 · `led_oe_n[2]` / `led_oe_n[3]` 恒高（预留），`.cst` 里没注明

- **位置**：`rtl/w3c/tlc5916_bank.sv:65`（`OE_N=5`）· `:199-205`（只写 [0]/[1]/[4]）· `constr/top.cst:304-309`

- **代码**：

```verilog
// tlc5916_bank.sv:199-205
oe_n_r = {OE_N{1'b1}};              // 默认全灭
if (state != S_IDLE && !global_blank_i) begin
    if (chip_sel == 2'd0)      oe_n_r[0] = 1'b0;
    else if (chip_sel == 2'd1) oe_n_r[1] = 1'b0;
    else                        oe_n_r[4] = 1'b0;  // 状态灯 = 右手板 B = oe[4]
end
```
```
// constr/top.cst:304-309  ← 有 IO_LOC 但没写"恒高预留"
IO_LOC  "led_oe_n[2]" D17;   // ⭐ J9 · N22 · SDRAM0_A11
IO_LOC  "led_oe_n[3]" A19;   // ⭐ J9 · N23 · SDRAM0_A7
```

- **机制 / 数字**：`KEY_CHIPS=2 + STATUS_CHIPS=1 = 3` 片 ⇒ 只用到 `[0]`/`[1]`/`[4]`；
  `oe_n_r[2]` 与 `oe_n_r[3]` **永远是 1**（消隐），对应左手板第 3/4 块板（预留）。
  这是**正确**的预留行为，但 `.cst` 里没有说明 ⇒ 将来接线的人可能以为它们会动。

- **结构性 vs 布局**：⭐ 无。

- **怎么改**：在 `constr/top.cst:304-309` 旁加一行注释
  `// ⭐ 恒高预留：tlc5916_bank 只用 oe[0]/oe[1]/oe[4]（KEY_CHIPS=2,STATUS_CHIPS=1）`
  ＋ 在 `tb_tlc5916_bank.sv` 加断言 `oe_n[3:2] === 2'b11` 钉死。

- **收益 / 代价**：收益 = 防误接；代价 = 0。

- **怎么验证能红**：tb 断言 `oe_n[3:2] === 2'b11`（当前恒真；若有人把 `else` 分支改错会红）。

---

### P3-6 · `led_indicator` 的 `looper_i=2'd3` 落进 default ⇒ 与"空闲"同色，第 4 态会被静默吞掉

- **位置**：`rtl/w3a/led_indicator.v:169-176`

- **代码**：

```verilog
// led_indicator.v:169-176
case (looper_i)
    2'd1: begin col_c[4] = C_RED;   blk_c[4] = BL_FAST; end   // 录音：红快闪
    2'd2: begin col_c[4] = C_GREEN; blk_c[4] = BL_STEADY; end // 回放：绿常亮
    default: begin
        col_c[4] = C_DIMBLUE;                                     // 空闲：暗蓝常亮
        blk_c[4] = BL_STEADY;
    end
endcase
```

- **机制 / 数字**：`looper_i` 是 2 位（4 个编码），只有 `0/1/2` 有语义；`2'd3` **与 `2'd0` 同色**。
  今天 `top.v:3669-3670` 只产生 `0/1/2` ⇒ 安全。但 looper 若加第 4 态（例如"叠录"），
  `2'd3` 会被**静默显示成"空闲暗蓝"** —— 灯在**说谎**（正是 `top.v:1261-1263` 记过的 `led_gear_st` 同类坑）。

- **结构性 vs 布局**：⭐ 无。

- **怎么改**：把 `2'd0:` 显式列出，`2'd3:` 给一个**显眼的非法色**（例如洋红 `C_MAGENTA`），
  或在 `initial` 里加 `if (looper_i > 2) $display("ERROR ...")`（那需要 `looper_i` 上电值，做不到）⇒
  ⭐ 推荐**改成显式 4 分支**（`2'd0`/`2'd1`/`2'd2`/`2'd3`），`2'd3` 用洋红，一眼看出"没人定义这个态"。

- **收益 / 代价**：收益 = 新态不会被静默吞掉；代价 = **0 LUT**（case 展开不变）+ 1 个颜色常量。

- **怎么验证能红**：tb 加 `drive(..., looper=2'd3, ...)` ⇒ 断言 `col != X_DIMBLUE`。**当前必红**（就是暗蓝）。

---

### P3-7 · `tlc5916_bank` 的 `S_WAIT_BUSY` 无握手超时 ⇒ 一旦卡死无外部症状

- **位置**：`rtl/w3c/tlc5916_bank.sv:241-255` · `:267`（`busy_o`）· `top.v:4829`/`:4861`（`led_busy`）

- **代码**：

```verilog
// tlc5916_bank.sv:241-255   ← 无超时，只有 done 才能出去
S_WAIT_BUSY: begin
    drv_start_r <= 1'b0;
    if (!drv_busy && drv_done) begin
        if (chip_sel == 2'd2) begin chip_sel <= 2'd0; busy_r <= 1'b0; state <= S_IDLE; end
        else begin chip_sel <= chip_sel + 2'd1; state <= S_START; end
    end
end
```
```verilog
// top.v:4829,4861   ← busy_o 有驱动，但【没有任何消费者】
wire        led_busy;
        .busy_o          (led_busy)
```

- **机制 / 数字**：`drv_done` 由 driver 保证（正常路径），但**一旦 driver 被改坏**（或将来加了别的 `start` 源），
  bank 会**永久卡在 `S_WAIT_BUSY`** 且 `busy_o` 恒 1；
  而 `busy_o` 接到 `top.v` 的 `led_busy` 之后**没有任何读取**（见 P3-8）⇒ **外部零症状**，只能靠 tb 超时（200 ms 后一条泛泛的 FAIL）。
  正常一轮 ≈ 1353 拍；给个 **4096 拍**（≈82 µs）看门狗绰绰有余。

- **结构性 vs 布局**：⭐ 无（可观测性）。

- **怎么改**：加 12 位看门狗 + 一个粘滞错误位：
  ```verilog
  reg [11:0] wd;  reg err_sticky;
  // S_WAIT_BUSY 里：if (wd == 12'd4095) begin err_sticky <= 1'b1; state <= S_IDLE; busy_r <= 1'b0; end
  //                 else wd <= wd + 1'b1;
  ```
  并把 `err_sticky` 引出成端口（或并进某个已有状态总线）供上板观测。

- **收益 / 代价**：收益 = "卡死"变成"一条清楚的信号"（对照 `tb_tlc5916_driver.sv:164-171` 的"tb 里任何等待都要有上限"纪律）；
  代价 = **+12 FF + ~15 LUT**。

- **怎么验证能红**：临时把 driver 的 `done <= 1'b1;` 去掉 ⇒ 看门狗必须置位、`busy_o` 必须回落
  （当前 tb 只会 200 ms 后报一条泛泛的 timeout）。

---

### P3-8 · `top.v` 的 `led_busy` 声明+驱动但从不读（死信号）

- **位置**：`rtl/top.v:4829`（声明）· `:4861`（连接）

- **代码**：

```verilog
// top.v:4829
wire        led_busy;
```
```verilog
// top.v:4861
.busy_o          (led_busy)
```
（机械确认：`led_busy` 全文 **2 处** = 声明 + 连接，**0 个消费者**。）

- **机制 / 数字**：综合会把它优化掉（0 逻辑），但它掩盖了 P3-7 —— 若把 `led_busy` 接到一个状态寄存器
  （像 `reserved_in_r` 那样 `syn_keep`），上板就能观测"TLC 是否在写"。

- **结构性 vs 布局**：⭐ 无。

- **怎么改**：二选一 —— ① 接进一个可观测寄存器（推荐，顺带给 P3-7 的看门狗一个出口）：
  ```verilog
  (* syn_keep = 1 *) reg led_busy_r;
  always @(posedge clk) if (!rst_n_sync) led_busy_r <= 1'b0; else led_busy_r <= led_busy;
  ```
  ② 或删掉 `led_busy` 与 `.busy_o()` 的连接（省一行，但失去观测点）。⛔ 推荐 ①。

- **收益 / 代价**：收益 = 多一个上板观测点；代价 = **+1 FF**。

- **怎么验证能红**：综合日志里不应再有 `led_busy` unused 警告；P3-7 的看门狗 tb 会用到它。

---

### P3-9 · `led_indicator` 的 `fast_cnt` 无条件自由跑（没人闪的时候也在烧电）

- **位置**：`rtl/w3a/led_indicator.v:108-115`

- **代码**：

```verilog
// led_indicator.v:108-115
reg [FAST_DIV-1:0] fast_cnt;
always @(posedge clk) begin
    if (!rst_n) fast_cnt <= {FAST_DIV{1'b0}};
    else        fast_cnt <= fast_cnt + 1'b1;
end
wire fast_off = fast_cnt[FAST_DIV-1];
```

- **机制 / 数字**：`FAST_DIV=23` ⇒ **23 个 FF 每拍翻转**（50 MHz 下最低位 25 MHz 翻转）。
  只有 `blk_c[4] == BL_FAST`（= looper 录音）时才需要它；其余 99% 的时间里它在**白烧动态功耗**。
  量级很小（23 FF @50 MHz），但这是**纯浪费**，且它在**每个时钟周期**都在动。

- **结构性 vs 布局**：⭐ 无（功耗）。

- **怎么改**：
  ```verilog
  wire fast_en = (blk_c[4] == BL_FAST);      // N_CH=7 时只有第 4 路用快闪
  always @(posedge clk) begin
      if (!rst_n)         fast_cnt <= {FAST_DIV{1'b0}};
      else if (fast_en)   fast_cnt <= fast_cnt + 1'b1;
  end
  ```
  ⚠️ 副作用：计数器在非录音期间**冻结**，录音一开始从冻结值继续 ⇒ 第一次闪的相位不确定。
  ⭐ 这**不影响** `tb_led_indicator.sv` 的 (7c)（它量的是"相邻上升沿间隔恒 == 2^FAST_DIV"，冻结恢复后周期仍精确）。

- **收益 / 代价**：收益 = 省 23 FF 的持续翻转；代价 = **+1 LUT（`fast_en` 已经是现成的比较）+ 1 个 CE 门**，
  且**改变了闪烁的绝对相位**（视觉上无差别）。⚠️ 若将来有第 2 路用 `BL_FAST`，`fast_en` 要改成"任意一路是 BL_FAST"。

- **怎么验证能红**：`tb_led_indicator.sv` 的 (7c)(7d)(7f) 必须仍然全绿；
  再加一条反证：断言"非录音时 `fast_cnt` 不变"（当前**必红**，因为它在跑）。

---

## §3 四道门 · 改动落地纪律（⛔ 一条都不能省）

按 `AGENTS.md`，改这六个文件里**任何一行**都必须过：

| 门 | 命令 | 判据 |
|---|---|---|
| ① 综合 | `sim/gowin_build.ps1` | **ERROR = 0**；⭐ 并在日志里 `grep "Compiling module '<你改的模块>'"` **确认它真的被分析了**（`.gprj:186-189` 的坑） |
| ② 聚焦 tb | `sim/tb_all.ps1 -Filter <tb>` | 全 PASS；⛔ **新增判据必须先对旧 RTL 跑出红**（工具控制实验，`C83` 纪律） |
| ③ 干净 PnR | `sim/gowin_build.ps1`（全流程） | 出 `.fs` ＋ **无 `PR0004`** ＋ **0 setup / 0 hold** ＋ `Fmax ≥ 51.5 MHz` |
| ④ 全量回归 | `sim/tb_all.ps1` | **通过数 == 共数**（⛔ 不写死 128；`tb_all.ps1` 自动发现 `tb/**/tb_*.sv`） |

⚠️ **本次审计的 P0-1 修法已实测验证**，但仍**必须**走完四道门才能落地 ——
`build/anvil11-probe/` 里的验证只证明了**功能**，⛔ 没有证明**综合/PnR**。

⚠️ **等价参考副本纪律**：`tb/models/` 下有 `oscillator_bank_ref.v` 与 `evt_merge_ref.v` 两个"逐位等价基线"，
**本次六个灯模块没有对应的 `*_ref` 副本** ⇒ 改灯模块**不需要同步任何 ref**。
⛔ 但若将来有人为 `led_data` / `tlc5916_bank` 建了 ref（例如为了做"逐位等价"回归），**必须**按 `p5-2-osc-20261004/README.md:122` 的纪律同步更新，否则两边同源 ⇒ **tb 静默恒真**。

---

## §4 一句话总结

**这份交付的 WS2812 那半条链（`led_indicator` + `ws2812_driver` + 顶层写口）是扎实的**：
位定时逐位对、GRB 单点定义、顶层集成有 `tb_top_led_strip` 钉住，单时钟域零 CDC，改动代价 0。
**TLC5916 那半条链（`led_data` + `tlc5916_bank` + `tlc5916_driver`）是坏的**：
① 握手多一拍 `start` ⇒ **片1 图案被片0 顶替**（已实测 `f0/f0/95`，3 行可修，修法已验证）；
② 交付树里**整条链永不提交** ⇒ 24 路灯永久全灭；
③ `guide_lamp` **死输入 + 未登记 `.gprj`** ⇒ 消隐/闪烁都没实现、且根本没综合；
④ 而**唯一**该抓这三条的 tb，**文件头自述的判据根本没写**、顶层 tb **连引脚都没接**。
⇒ **改这摊的顺序必须是：先补判据（P0-4 / P1-3 / P1-4），再修 P0-1，再接线（P0-3 → P0-2），最后才是 P1/P2 的性能与鲁棒性。**
