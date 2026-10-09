# ANVIL-07 · 七模块逐行深挖（ADC 采集链 + W3a 控制链）

**审计对象（7 个文件，一行未漏）**

| 文件 | 行数 | 角色 |
|---|---|---|
| `rtl/drivers/adc_farm.sv` | 225 | 多片 MCP3208 并行采集总控 + 影子反串行器 |
| `rtl/drivers/mcp3208_driver.sv` | 208 | 单片 SPI mode-0 24 位事务驱动 |
| `rtl/drivers/mcp3208_scanner.sv` | 162 | CH0..CH7 轮扫 + 帧周期节拍 |
| `rtl/drivers/debounce.sv` | 187 | 4 键 + EC11 去抖/正交解码 |
| `rtl/w3a/fader_gear.v` | 270 | 推子档位状态机 + 档 0 变调接管 |
| `rtl/w3a/right_analog_ctrl.v` | 122 | P4 右手板 CH1/CH2/CH3 采样 + 64 点对数 LUT |
| `rtl/w3a/play_mode_ctrl.v` | 89 | 键盘/指板语义仲裁 → note_on/off/pluck |

**战场事实（判定基准）**：GW5AT-60B · AC1/I0 慢档 · `clk_sys` = 50 MHz · `set_max_delay 18.181 ns`（≈55 MHz）· 交付门槛 0 setup / 0 hold + Fmax ≥ 51.5 MHz · PnR 布局噪声 ±2~3 MHz。

**本报告用到的硬证据（全部来自本工作区实测产物，不是推测）**

| 编号 | 证据 | 用途 |
|---|---|---|
| **E1** | `impl/gwsynthesis/Gowin2026_syn_rsc.xml`（**=0 交付档**综合资源，逐模块） | 证明哪些"死逻辑"被综合器折掉了、哪些没折 |
| **E2** | `sim/evidence/rightboard-vibrato-fix-20261008/rsc-rightadc-a3.xml`（**=1 档**综合资源） | =0/=1 资源差分 ⇒ 第③条归因 |
| **E3** | `build/rightadc-probe/impl/pnr/Gowin2026.timing_paths`（**=1 档** Top-25 setup + Top-25 hold） | 判定一条路径**是不是**时序瓶颈 |
| **E4** | `sim/evidence/gowin_m0_timing.txt`（=0 档：0/0 · Fmax 55.313 MHz · Logic Level 7） | 全局余量 |
| **E5** | `sim/evidence/rightboard-vibrato-fix-20261008/README.md`（1630 违例 = 25/25 同一条链） | 1630 归因 |
| **E6** | 各 tb 源码（`tb_adc_farm` / `tb_debounce` / `tb_mcp3208_driver` / `tb_mcp3208_scanner` / `tb_fader_gear` / `tb_right_analog_ctrl` / `tb_play_mode_ctrl`） | "怎么验证能红"的落点 |

> ⚠️ **两条纪律**（本报告严格自我约束）：
> ① 每条结论必须能归到 **E1/E2/E3** 之一，否则不写；
> ② **凡是我用 E1/E2 证伪的"看起来很浪费"的假设，全部收进 §附录A（已核查·非问题）** —— 那 9 条同样值钱，因为它们能阻止你白干。

---

## 总账

| 优先级 | 条数 | 主题 |
|---|---|---|
| **P0** | **3** | 两条**挂音**（play_mode_ctrl）+ 一条**档 0 串口被推子噪声每帧覆盖**（fader_gear） |
| **P1** | **3** | =0/=1 归因更正（1630 是结构性不是布局运气）· adc_farm 死逻辑陷阱 · `fault` 恒 0 却参与故障聚合 |
| **P2** | **6** | 去抖参数退化/冻结 · Z 输入变 X · EC11 复位态错 · adc_farm 无复位比较器 · 拨弦与按弦同拍丢事件 · 帧周期饱和静默超标 |
| **P3** | **4** | rx_shift 只用到 12 位 · 首个 MOSI 位的隐式来源 · `pluck_up_i` 死端口 · driver default 分支不可达 |
| **附录A** | **9** | 已核查·**非问题**（含 SPI 链不是瓶颈、去抖位宽已被工具窄化、LUT 已是最优 ROM…） |

**一句话总纲**：本摊 7 个模块**没有一条路径进入 =1 档 Top-25**（E3）—— 你原本怀疑的"SPI 位计数链 / 片选扇出 / ADC_N / 去抖比较器 / 档位比较链"**五条全部不是时序瓶颈**（数字见附录A）。真正的 P0 全在**功能语义**上，而且**现有 131 个 tb 结构上抓不到**。

---

## [P0] 阈值跨界 ±1 LSB 抖动 ⇒ 档 0 的串口变调值**每帧被推子覆盖**（P3.2 病灶未闭环）

**位置**：`rtl/w3a/fader_gear.v:171`（判据）· `:217`（接管 mux）· `:235`（历史值刷新）· `:127-139`（阈值表）

**代码**

```verilog
// rtl/w3a/fader_gear.v:169-173
    // ⭐ ① 推子动过 = ⭐ **量化档位**变了（⭐ 与上一拍不同）
    //   ⭐ ±1 LSB 抖动只要没跨过半音档边界 ⇒ `fader_enc` 不变 ⇒ ⛔ 不接管 ✅
    wire fader_moved = (fader_enc != fader_enc_q);
    // ⭐ ② 刚切进档 0（⭐ `gear_q` 是上一拍档位 ⇒ 该条件只成立**一拍**）
    wire gear0_enter = (gear_o == 2'd0) && (gear_q != 2'd0);
```

```verilog
// rtl/w3a/fader_gear.v:213-219
    always @(*) begin
        if      (trans_down_i)   enc_next = down_sat;
        else if (trans_up_i)     enc_next = up_sat;
        else if (trans_abs_i)    enc_next = abs_sat;
        else if (gear_o == 2'd0) enc_next = (fader_moved || gear0_enter) ? fader_enc : enc_r;
        else                     enc_next = enc_r;
    end
```

```verilog
// rtl/w3a/fader_gear.v:235（每拍无条件刷新）
            fader_enc_q <= fader_enc;
```

**机制（带数字，逐拍推）**

`gear_step_of()` 是 12 段**单调阈值**量化器，阈值 = `ceil(4095k/12)`：

```
k=1..12 → t=342 683 1024 1365 1707 2048 2389 2730 3072 3413 3754 4095
```

`ch2_i` 来自 `right_analog_ctrl.vibrato_depth_o`，**每 500 µs 帧更新一次**（`CHANNEL_RATE_HZ=2000`，见 `adc_farm.sv:51`）。而 `calib` 目前**旁路**（`rtl/top.v:1793` 注释 "本版先【旁路】标定"）⇒ **ADC 抖动没有任何滤波**。

于是若推子停在**阈值 ±1 LSB 内**（例如 `ch2_i = 2047 ↔ 2048`，2048 正是 step5/step6 的边界）：

| 拍（帧） | `ch2_i` | `gear_step_of` | `fader_enc` | `fader_enc_q` | `fader_moved` | `enc_next`（档 0） |
|---|---|---|---|---|---|---|
| n | 2047 | 5 | 7 | 7 | **0** | `enc_r` |
| n+1 | 2048 | 6 | **6** | 7 | **1** | **`fader_enc` = 6** ⇒ `enc_r` 被改写 |
| n+2 | 2047 | 5 | 7 | 6 | **1** | **`fader_enc` = 7** ⇒ 再改写 |
| … | 交替 | 交替 | 交替 | | **每帧为真** | **串口值每帧被覆盖** |

⇒ **这正是 P3.2 当初要修的同一个病灶**：P3.1 是"原始 12 位比较 ⇒ 每拍为真"，P3.2 改成"量化档位比较 ⇒ 只有跨边界才为真"。**但噪声本身就能跨边界** ⇒ 触发窗口只是从 **100%** 缩到 **12 个阈值 × ±1 LSB / 4096 ≈ 0.6%**（噪声若 ±2 LSB ⇒ 1.2%）。文件头 `:70-72` 写"相当于天然的迟滞/死区" —— 这个"天然迟滞"**只在档位中间成立，在阈值上不成立**。

**现有 tb 为什么抓不到**（E6，`tb/w3a/tb_fader_gear.sv`）：
- `H4`（`:377-383`）抖的是 `1999/2001` —— 两点**都在 step5 内部**，`fader_enc` 恒 7 ⇒ 结构上不可能红；
- `H11`（`:413-419`）抖的是 `2048/2049` —— 两点**都在 step6 内部**，恒 6 ⇒ 同样不可能红。
- ⇒ **H 组刻意避开了"跨边界"这一种抖动**。这不是疏忽就是当时没想到，总之**判据存在结构性空洞**。

**结构性 / 布局运气**：**结构性**（纯逻辑语义，与布局无关；换任何布局都复现）。

**怎么改**（⭐ 关键：**不改 `gear_step_of`、不改 C12 全 4096 点扫描判据**，只在"接管判据"上加原始域死区）

```verilog
// ── 新增：上次【接管时】的原始推子值 + 死区 ─────────────────────────
//   ⚠️ 必须用 13 位中间量：ch2_taken 最大 4095，+8 会溢出 12 位回绕成 7
localparam [12:0] TAKEOVER_DEADBAND = 13'd8;
reg [11:0] ch2_taken, ch3_taken;

wire raw_moved =
    ( {1'b0, ch2_i} >  ({1'b0, ch2_taken} + TAKEOVER_DEADBAND) ) ||
    ( ({1'b0, ch2_i} + TAKEOVER_DEADBAND) < {1'b0, ch2_taken} ) ||
    ( {1'b0, ch3_i} >  ({1'b0, ch3_taken} + TAKEOVER_DEADBAND) ) ||
    ( ({1'b0, ch3_i} + TAKEOVER_DEADBAND) < {1'b0, ch3_taken} );

// 把 :217 的 fader_moved 换成 raw_moved
        else if (gear_o == 2'd0) enc_next = (raw_moved || gear0_enter) ? fader_enc : enc_r;
```

```verilog
// 寄存器块内（:232-236 附近）增加：每次真正接管后，把"已接管值"钉住
        if ((enc_next != enc_r)) begin
            ch2_taken <= ch2_i;
            ch3_taken <= ch3_i;
        end
// 复位（:222-231 段）补：ch2_taken <= 12'd0; ch3_taken <= 12'd0;
```

**为什么这个改法零回归**（逐条对 `tb_fader_gear` 的 H 组）：
- `H4`：抖动 ±1 LSB < 死区 8 ⇒ `raw_moved=0` ✅
- `H7/H9/H10`：跨 1707 / 2048 边界 = **341 LSB 级**移动 ≫ 8 ⇒ 仍立刻接管 ✅
- `F8`：`ch3` 0→2048 ≫ 8 ⇒ 接管 ✅
- `C12a/C12b`（全 4096 点 == `floor(c*12/4095)`）：`gear_step_of` 一字未动 ⇒ 逐值不变 ✅
- `G4/G10`：走 `gear0_enter`，与 `raw_moved` 无关 ⇒ 不变 ✅

**收益 / 代价**：+24 FF（2×12）· +约 24 LUT（4 个 13 位比较 + 4 个 13 位加法）· 接管延迟 **0 拍**（死区是组合的，不引入等待）· 风险低（唯一影响是"推子移动 < 8 LSB 时不再接管" —— 而 8 LSB 在半音行程 341 LSB 下 = **2.3% 的半音行程**，用户不可感）。

**怎么验证能红**：在 `tb/w3a/tb_fader_gear.sv` 的 H 组末尾追加（沿用现有 `chk_cnt` 计数式判据）：

```verilog
// ⭐ 新增 H12：抖动【跨过】2048 阈值 —— 现有实现必红
pulse_abs(8'd24);                       // 串口钉 +12
h_bad = 0;
for (c = 0; c < 24; c = c + 1) begin
    ch2 = (c % 2 == 0) ? 12'd2047 : 12'd2048;   // ⭐ 横跨 step5/step6 边界
    @(negedge clk);
    if (semi != 12) h_bad = h_bad + 1;
end
chk_cnt("H12 [P3.3] +-1 LSB dither STRADDLING the 2048 edge => +12 held EVERY cycle", h_bad);
```
**预期：改前 `h_bad = 24`（每拍都丢）⇒ FAIL；改后 `h_bad = 0` ⇒ PASS。** 这就是"能红"的正向证据。

---

## [P0] 键盘 ↔ 指板模式切换期间的按键**释放被吞** ⇒ 挂音（无限延音）

**位置**：`rtl/w3a/play_mode_ctrl.v:51-58`（键盘分支）· `:59`（指板拨弦分支）· `:76`（OFF 判据）

**代码**

```verilog
// rtl/w3a/play_mode_ctrl.v:48-84
        end else begin
            evt_valid_o <= 1'b0;

            if (!fretboard_mode_i) begin
                // Keyboard: threshold crossing and release are directly musical.
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                end
            end else if (pluck_valid_i && selected_valid) begin
                ...
                gate_valid  <= 1'b1;
                gate_axis   <= selected_axis;
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;
                    selected_depth <= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && (axis_i == gate_axis)) begin   // ← 🔴 只有这一条路能发 OFF
                        evt_valid_o <= 1'b1;
                        ...
                        gate_valid  <= 1'b0;
                    end
                end
            end
        end
```

**机制（带因果链）**

1. 键盘模式（`!fretboard_mode_i`）**从不写 `gate_valid` / `gate_axis`**（`:66-67` 只在拨弦分支里写）⇒ 键盘模式下 `gate_valid` 恒 0。
2. 指板模式下的 OFF 事件**唯一出口**是 `:76` 的 `gate_valid && (axis_i == gate_axis)` ⇒ `gate_valid=0` 时**一个 OFF 都发不出去**。
3. `fretboard_mode_i` 接的是 **`play_fretboard_mode = ~ui_mode_piano`**（`rtl/top.v:938`，且 `:3218` 例化传入）—— 这是**运行期信号**（音色循环 BASS→GUITAR→**PIANO**→PAD，`rtl/top.v` 注释与 `.cst` 均确认），**不是编译期常量**。

⇒ 复现序列：**键盘模式下按住一个键（`evt_kind=ON`，voice 起音）→ 切到 PIANO（`fretboard_mode_i=1`）→ 松键**：
- 指板分支走 `else if (axis_valid_i)`（`pluck_valid_i` 为 0）；
- `axis_i == selected_axis` 不成立（键盘模式从没写过 `selected_axis`，保持复位 0，除非恰好是轴 0）；
- `gate_valid(0) && …` 为假 ⇒ **`evt_valid_o` 一拍都不抬** ⇒ 下游**永远收不到 `note_off`** ⇒ **挂音**。

**现有 tb 为什么抓不到**：`tb/w3a/tb_play_mode_ctrl.sv:78` 把 `fretboard_mode=1` 设在**任何键盘事件之前**，此后**再没切回 0**（`:78-92`）⇒ 全流程都在单一模式下，**"模式切换"这个维度根本没被覆盖**。

**结构性 / 布局运气**：**结构性**（纯语义，与布局无关）。

**怎么改**（键盘分支补上"正在响的轴"记账；**零回归**）

```verilog
            if (!fretboard_mode_i) begin
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                    // ⭐ 新增：键盘模式也维护"正在响的轴"
                    //   ⇒ 切到指板模式后，:76 的 gate 判据仍能把这个音放掉
                    if (axis_kind_i == KIND_ON) begin
                        gate_valid <= 1'b1;
                        gate_axis  <= axis_i;
                    end else if (axis_kind_i == KIND_OFF) begin
                        gate_valid <= 1'b0;
                    end
                end
            end
```

**收益 / 代价**：+1 FF（`gate_valid` 在键盘模式下变活）· 0 LUT 增量（`gate_axis` 的写口从 2 个变 3 个，多一级 mux ≈ 4 LUT）· 对既有判据**零影响**（键盘模式的行为完全不变，因为键盘分支在 `if/else if` 链**最前面**，仍然优先转发）。

**怎么验证能红**：在 `tb/w3a/tb_play_mode_ctrl.sv` 追加：

```verilog
        // ⭐ 新增：键盘模式下按下的音，在切到指板模式后必须能被放掉
        fretboard_mode = 1'b0;
        axis_evt(4'd3, 2'd0, 12'd700);            // 键盘 ON ⇒ evt
        fretboard_mode = 1'b1;                    // ⭐ 运行期切模式（PIANO）
        axis_evt(4'd3, 2'd1, 12'd0);              // 松键
        repeat (2) @(posedge clk);
        chk("mode-switch: release still emits note_off", events_kind[event_n-1] == 2'd1);
```
**预期：改前 `event_n` 不变 ⇒ FAIL；改后收到一条 `KIND_OFF` ⇒ PASS。**

---

## [P0] 释放的轴 ≠ `gate_axis` 时 OFF 被吞 ⇒ 滑品/换轴后**挂音**

**位置**：`rtl/w3a/play_mode_ctrl.v:74-82`（尤其 `:76` 与 `:78`）

**代码**

```verilog
// rtl/w3a/play_mode_ctrl.v:73-83
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && (axis_i == gate_axis)) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= axis_i;          // ← 🔴 发的是"被松开的轴"，不是"正在响的轴"
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
```

**机制**

`gate_axis` **只在拨弦那一拍被锁存**（`:67`），此后**只有再次拨弦**才会更新（`:59` 分支）。而 `selected_axis` 会随每一次 `KIND_ON` 更新（`:71`）。

复现序列（指板模式，**滑品不重拨**——吉他上极常见）：
1. `axis_evt(6, ON)` ⇒ `selected_axis=6`，无 evt；
2. `pluck_evt` ⇒ evt `KIND_PLUCK axis=6`，`gate_valid=1`、`gate_axis=6`（voice 起音）；
3. `axis_evt(9, ON)` ⇒ `selected_axis=9`（**`gate_axis` 仍是 6**）；
4. `axis_evt(9, OFF)` ⇒ `axis_i(9) == selected_axis(9)` ⇒ 清 `selected_valid`；但 `gate_valid(1) && (9 == 6)` = **假** ⇒ **不发 OFF** ⇒ **步骤 2 起的音永远不释放** ⇒ 挂音。

**现有 tb 为什么抓不到**：`tb_play_mode_ctrl.sv:89-92` 做了步骤 3（`axis_evt(4'd9, 2'd0, …)` + 拨弦），**但从来没有松开轴 9**，测试就结束了 ⇒ **"换轴后释放"这一格是空的**。`:85-87` 唯一覆盖的释放是 `axis_evt(4'd6, 2'd1, …)` —— 恰好等于 `gate_axis`。

**结构性 / 布局运气**：**结构性**。

**怎么改**（判据放宽到"响着的轴"或"选中的轴"，并且**发的是响着的那个轴**）

```verilog
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && ((axis_i == gate_axis) || (axis_i == selected_axis))) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= gate_axis;    // ⭐ 释放【正在响】的那个轴
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
```
**零回归证明**：既有 `:85-87` 的场景里 `axis_i == gate_axis`（都是 6）⇒ `evt_axis_o` 由 `axis_i` 改成 `gate_axis` 得到**同一个值** ⇒ 判据不变 ✅。

**收益 / 代价**：+0 FF · +约 6 LUT（4 位比较 + 或门 + 4 位 mux 选择）· 风险低。

**怎么验证能红**：追加

```verilog
        fretboard_mode = 1'b1;
        axis_evt(4'd6, 2'd0, 12'd900);  pluck_evt(1'b1);   // 轴 6 起音
        axis_evt(4'd9, 2'd0, 12'd800);                     // 滑到轴 9（不重拨）
        axis_evt(4'd9, 2'd1, 12'd0);                       // 在轴 9 松开
        repeat (2) @(posedge clk);
        chk("slide-then-release must emit note_off for the SOUNDING axis",
            events_kind[event_n-1] == 2'd1 && events_axis[event_n-1] == 4'd6);
```
**预期：改前 `event_n` 不变（无事件）⇒ FAIL；改后收到 `KIND_OFF / axis=6` ⇒ PASS。**

---

## [P1] 【归因更正】`RIGHT_ADC_ENABLE=1` 的 1630 违例是**结构性**的，⛔ **不是布局运气**；且它与 `ADC_N` 几乎无关

**位置**：`rtl/w3a/right_analog_ctrl.v:98`（`!enable_i` 常量门）· `rtl/w3a/fader_gear.v:258-266`（颤音参数 mux）· `rtl/top.v:1676` / `:1746` / `:4155-4156`
**被更正的对象**：`sim/evidence/rightboard-vibrato-fix-20261008/README.md:50` —— 原文写 *"`=0` 档时布局运气好（它不在 Top-12）"*。

**代码（常量门的源头）**

```verilog
// rtl/top.v:1676   ← ADC_N 只在这里变
        localparam integer ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2;
// rtl/top.v:1746
            .enable_i         (RIGHT_ADC_ENABLE != 0),
// rtl/w3a/right_analog_ctrl.v:98
        if (!rst_n_i || !enable_i) begin
            master_gain_o   <= 16'h7FFF;
            vibrato_depth_o <= 12'd0;      // ← =0 档：这两个输出被钉成常量 0
            vibrato_rate_o  <= 12'd0;
```

**机制（用 E1/E2 逐模块差分证明）**

`RIGHT_ADC_ENABLE=0` 时 `enable_i` 是**常量 0** ⇒ `right_analog_ctrl` 的两个输出**恒为常量 0** ⇒ 沿 `top.v:1779-1780 → fader_gear → top.v:4155-4156 → vibrato_lfo → oscillator_bank` 整条**颤音调制数据通路被常量传播折掉**。差分（E1 vs E2，逐模块自用资源）：

| 模块 | **=0 交付档** | **=1 右手板档** | Δ | 说明 |
|---|---|---|---|---|
| `u_adc_farm`（自用） | 13 FF / **1** LUT | 25 FF / 25 LUT | **+12 FF / +24 LUT** | ⭐ 第③条：**`ADC_N` 2→3 的全部代价就这么多** |
| `u_right_analog_ctrl` | **不存在（0）** | 41 FF / 65 LUT | +41 FF / +65 LUT | 整块被折掉 |
| `u_fader_gear` | 7 FF / **0 ALU** / 31 LUT | 12 FF / 10 ALU / 95 LUT | +5 FF / +10 ALU / +64 LUT | 比较链在 =0 档被折掉 |
| `u_vibrato_lfo` | **不存在（0）** | 97 FF / 96 ALU / 286 LUT / **2 DSP** | +97 FF / +96 ALU / +286 LUT / +2 DSP | ⭐ 1630 的源头 |
| `u_oscillator_bank` | Alu 4326 | Alu **5350** | **+1024 ALU** | 颤音加数进入 32 voice 级加法阵列 |
| `u_master_mix` | 10 FF / 43 LUT | 16 FF / 28 ALU / 73 LUT | +6 FF / +28 ALU / +30 LUT | 增益从常量变变量 |
| **TOP 合计** | 17039 FF / 27140 LUT / 7 DSP | 17202 FF / 27589 LUT / 10 DSP | **+163 FF / +449 LUT / +3 DSP** | — |

**⇒ 结论（三条，全部可核对）**

1. **`=0` 档里 `u_vibrato_lfo` 与 `u_right_analog_ctrl` 在综合报告里根本不存在** ⇒ 那条 `vibrato_lfo/phase_q_17 → gen_lane[*]` 路径**不是"运气好没进 Top-12"，而是【不存在】**。⇒ **1630 违例是结构性长路径，⛔ 不是布局噪声**（README:50 的表述必须更正）。
2. **`ADC_N` 2→3 本身只值 +12 FF / +24 LUT**（= 多一片的 12 位影子寄存器 + 一个上升沿检测扇出）。把 1630 违例归到"多一片 ADC"是**错的**：真凶是**整条右手板控制 + 颤音调制通路从"不存在"变成"存在"**。
3. **修法方向已被验证正确**：`oscillator_bank` 颤音链切两级流水（`vibrato_mod_r` / `vib_mul_r`，16+48 FF）把 1630 → 0、46.613 → ≈57.0 MHz（E5）。⚠️ 但 `+1024 ALU` 的加法阵列**仍然在**（32 voice × 32 位），且 =1 档最差余量只剩 **+0.642 ns**（E3）⇒ 任何再往这条路上加逻辑的改动都危险。

**结构性 / 布局运气**：**结构性**（判据：路径在 =0 档**不存在**，在 =1 档**必然存在**；E3 显示 =1 档 Top-25 全是 `tdm_render_mixer` / `note_manager`，颤音链已被流水推到后面）。

**怎么改**：无需改 RTL（流水已落地）。**需要改的是归因文档**：把 `README.md:50` 那句改成"=0 档该通路被常量门折掉 ⇒ 不存在；=1 档新增 ⇒ 结构性"。

**收益 / 代价**：0 资源。收益 = **防止后续把 =1 档时序问题误判成"重跑布局试试"**（那种试法会白烧 ~10 分钟/次的 PnR，而且按 E5 的 25/25 同源聚类，重跑不可能好）。

**怎么验证**：
```powershell
# 用现成脚本做逐模块差分（E1 vs E2）
diff (Select-String -Path impl\gwsynthesis\Gowin2026_syn_rsc.xml -Pattern 'SubModule') `
     (Select-String -Path sim\evidence\rightboard-vibrato-fix-20261008\rsc-rightadc-a3.xml -Pattern 'SubModule')
```
判据：**`u_vibrato_lfo` 与 `u_right_analog_ctrl` 只出现在 =1 侧**；`u_adc_farm` 两侧都出现且 ΔRegister == **+12**。

---

## [P1] `adc_farm` 的 `miso_shift` / `cs_r` / `cs_fall` 是**纯死逻辑**，且文件里 30 行注释仍在描述一个**已不存在的"修前"实现** ⇒ 埋着"改回去"的地雷

**位置**：`rtl/drivers/adc_farm.sv:135`（`miso_shift` 声明）· `:152-165`（唯一写它的 always）· `:129-131`（`cs_r`/`cs_fall`）· `:191`（唯一的读口已改走 `shadow_hold`）

**代码**

```verilog
// rtl/drivers/adc_farm.sv:129-135
    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);

    // ⭐ 2026-09-20：影子移位寄存器改为 [N_ADC-1:1] 的二维数组 ⇒ 任意片数
    //    （片 0 的数据由 scanner 自己给出，不需要影子）
    reg [23:0] miso_shift [1:N_ADC-1];
```

```verilog
// rtl/drivers/adc_farm.sv:153-165 —— 写，但全文件【没有任何一处读】
    always @(posedge clk) begin
        if (!rst_n) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= 24'd0;
        end else if (cs_fall) begin
            // 新事务开始：清零所有影子移位寄存器
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= 24'd0;
        end else if (cs_active && sclk_rise) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= {miso_shift[gi][22:0], miso_sync[gi]};
        end
    end
```

```verilog
// rtl/drivers/adc_farm.sv:189-193 —— 唯一的读口，2026-10-01 已改成 shadow_hold
        for (g = 1; g < N_ADC; g = g + 1) begin : gen_pack
            // ⭐ 2026-10-01：⭐ 由 `miso_shift[g][11:0]`（⭐ ~1 µs 有效）改 `shadow_hold[g][11:0]`（⭐ 保持）✅
            assign sample_data_packed[g*12 +: 12] = shadow_hold[g][11:0];
        end
```

**机制（用 E1 反推综合器干了什么，逐位对得上）**

`grep miso_shift rtl/drivers/adc_farm.sv` ⇒ 命中行 **只有 135 / 156 / 160 / 163（全是写）与注释**，**零读**。
E1（=0 档）：`g_sound.u_adc_farm Register="13" Lut="1"`。逐项对：

| 理论 FF | 数量 | 综合后是否留下 |
|---|---|---|
| `shadow_hold[1][11:0]`（唯一被读的 12 位） | 12 | ✅ 留 |
| `shadow_hold[1][23:12]`（`sample_data_packed` 只取 `[11:0]`） | 12 | ❌ 折掉 |
| `miso_shift[1][23:0]` | 24 | ❌ 折掉（无扇出） |
| `cs_r` | 1 | ❌ 折掉（`cs_fall` 只喂已死的 `miso_shift`） |
| `sclk_r` | 1 | ✅ 留（`sclk_rise` 是 `shadow_hold` 的使能） |
| `fault_r[1:0]` | 2 | ❌ 折掉（恒 0，见下一条） |
| **合计** | **12 + 1 = 13** | ✅ **与 E1 的 `Register="13"` 精确吻合** |

⇒ **综合器已经全部折掉了：资源代价 0、时序代价 0。** 所以这条**不是资源优化项**。
它的真实价值是**排雷**：文件 `:137-149` 那 30 行注释**逐字描述**"原缺陷是取 `miso_shift[g][11:0]`、只在 ~1 µs 内有效"，并明说 **"`shadow_hold` 与 `miso_shift` 逐位相同"** —— 一个后来者读到这句，很自然会把 `:191` 改回 `miso_shift[g][11:0]`（"反正逐位相同、还省 12 个 FF"），于是**静默复活那个 1 拍窗口**。

**⚠️ 我把那个窗口的宽度算准了**（这是判断"改回去会不会真炸"的关键）：
- 第 24 个 SCLK 上升沿：`miso_shift` 收到第 24 位；
- 该上升沿 → 下降沿 `HALF_DIV` = 25 拍；`STATE_FINISH` 再等 `HALF_DIV` = 25 拍 ⇒ `done`/`sample_valid` 在 **第 50 拍**；
- 下一通道的 `cs_fall` 在 **第 51 拍**（driver 回 IDLE 后立刻 `adc_cs_n <= 1'b0`）。
⇒ **`sample_valid` 恰好落在窗口的最后一拍，余量 = 1 拍 = 20 ns**。同拍读的消费者侥幸正确，**晚一拍读就全 0**。这正是 `adc_farm.sv:143-144` 说的"任何不在 `sample_valid` 那一拍读的消费者都会读到 0"—— 该判断**成立**，只是"1 µs / 0.2% 占空比"的措辞容易让人以为是"很宽的窗口"。

**结构性 / 布局运气**：**结构性**（死逻辑与 1 拍窗口都与布局无关）。

**怎么改**（删死代码，保留修法）

```verilog
// ① 删 :129-131（cs_r / cs_fall）
// ② 删 :135 的 miso_shift 声明 与 :152-165 整段 always
// ③ 把 :137-149 的 30 行注释压成 3 行，明确写：
//    "shadow_hold 是【唯一】的片 1..N-1 反串行器；它的 [23:12] 无读者（综合器会折掉），
//     但 ⛔ 不要为了省 12 个 FF 把 :191 改回任何"会被 cs_fall 清零"的副本 ——
//     sample_valid 距下一次 cs_fall 只有 1 拍（20 ns）。"
// ④ 同理把 shadow_hold 的声明收窄到实际需要：reg [11:0] shadow_hold [1:N_ADC-1];
//    并同步把移位改成 {shadow_hold[gh][10:0], miso_sync[gh]}（行为逐位不变）
```

**收益 / 代价**：**+0 LUT / +0 FF（综合器早已折掉）**；收益 = 消除一处**可被误用**的陷阱 + 让 `:167-177` 成为唯一的影子实现。代价 = 0（行为逐位不变，`tb_adc_farm` 应保持 PASS）。

**怎么验证能红**：
1. **行为不变**：`sim/tb_all.ps1` 里 `tb_adc_farm` 必须仍 PASS（它逐通道比对三片 IDVAL，`tb_adc_farm.sv:101-112`）。
2. **死逻辑确认**：改完再看 `impl/gwsynthesis/Gowin2026_syn_rsc.xml`，`u_adc_farm` 的 `Register` 必须**仍是 13**（若从 13 变了，说明我这张对表有误，必须停下来复核）。

---

## [P1] `adc_farm.fault` 恒 0，却被 `top` 汇进 `fault_any_w` 并接上心跳灯 ⇒ **ADC 死片永远不可能被观测**，而聚合逻辑让人以为能

**位置**：`rtl/drivers/adc_farm.sv:216-221` · `rtl/top.v:1719` · `rtl/top.v:4789`

**代码**

```verilog
// rtl/drivers/adc_farm.sv:216-221
    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;
```

```verilog
// rtl/top.v:1719
        assign fault_any_w = (|af_fault) | mx_fault;
// rtl/top.v:4789
        else if (fault_any_w)    fault_sticky <= 1'b1;   // ⭐ sticky
```

**机制**

`fault_r` 的 always 块**只有复位分支、没有 else** ⇒ 它被置 0 后**永不再赋值** ⇒ `fault ≡ 0`（E1 也印证：`fault_r` 的 2 个 FF 被折掉，`u_adc_farm` 自用只剩 13 FF）。
于是 `top.v:1719` 的 `(|af_fault)` 是**常量 0** ⇒ `fault_any_w` 只剩 `mx_fault`（`tdm_render_mixer.deadline_fault_o`）一条活路。
⇒ **后果**：`spi_miso` 被拉死、排线松脱、某片 ADC 未上电 —— **全部不会点亮心跳灯的故障指示**；而代码结构（多位 `fault` 端口 + OR 归并 + sticky 灯）**明确暗示"ADC 故障会被抓到"**。这跟"已知问题清单"里那条"静默卡死"是同一族。

**结构性 / 布局运气**：**结构性**（功能缺失）。

**怎么改**（推荐 (a)：把端口兑现，代价极小）

```verilog
// (a) 在 adc_farm 里实现"死片"sticky：某片连续 N 帧样本贴死在 0x000/0xFFF ⇒ 置 fault
//     ⚠️ 必须用【帧边界】计数（frame_done），不要用 sample_valid（每通道都来）
    localparam integer DEAD_FRAMES = 64;          // 64 帧 = 32 ms @2 kHz
    reg [N_ADC-1:0] dead_cnt_sat;                 // 每片一个"贴死"标志
    reg [5:0]       dead_run [0:N_ADC-1];
    // 逐片：sample_valid && sample_ch==3'd0 时判 sample_data_packed[i*12+:12] 是否 ∈ {0x000,0xFFF}
    //       是 ⇒ dead_run[i]++（饱和）; 否 ⇒ dead_run[i] <= 0
    //       frame_done 时若 dead_run[i] >= DEAD_FRAMES ⇒ fault_r[i] <= 1'b1（sticky，只置不清）
    always @(posedge clk) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
        else if (frame_done) fault_r <= fault_r | dead_flag;
    end
// (b) 或者：删掉 fault 端口 + 删掉 top.v:1719 的 (|af_fault) 项，并在注释里写明"本版无死片检测"
```

**收益 / 代价**：(a) 约 +`N_ADC×6` FF（=1 档 18 FF）+ 约 20 LUT，换来"SPI 挂了能被灯抓到"——这正是 `top.v:2219` 注释里担心的场景（"若 `adc_farm` 停扫（SPI 挂/排线松）⇒ 采样永不来"）。风险：阈值选错会误报（`0x000/0xFFF` 是真实可达的极端位置 ⇒ 建议 DEAD_FRAMES ≥ 64 帧，且只在 **ch0** 判，避免正常贴边被误判）。

**怎么验证能红**：新建/扩展一个 tb（可挂在 `tb_adc_farm` 上）：把 `adc_miso[1]` 恒接 `1'b0`（模拟片 1 排线断）⇒ 跑 ≥ 64 帧 ⇒ 断言 `fault[1] == 1'b1`。
**改前：`fault` 恒 0 ⇒ FAIL**（现在 `tb_adc_farm.sv:168-170` 反而把"`fault==0`"当成通过判据，所以这条判据**方向是反的**，必须新增反向判据）。

---

## [P2] `debounce` 参数退化：`DB_CYC = 0` 时判据变成 `key_cnt >= 32'hFFFFFFFF` ⇒ **去抖器永久冻结**（静默、全死）

**位置**：`rtl/drivers/debounce.sv:55`（`DB_CYC` 定义）· `:76`（按键）· `:116`（编码器）

**代码**

```verilog
// rtl/drivers/debounce.sv:54-55
    // ── 去抖稳定周期数：DB_MS 毫秒换算成系统时钟拍 ─────────────────────────
    localparam integer DB_CYC = (CLK_HZ / 1000) * DB_MS;   // 5 ms @50 MHz = 250_000
```

```verilog
// rtl/drivers/debounce.sv:74-81
                if (key_norm[ki] == key_level[ki]) begin
                    key_cnt[ki] <= 32'd0;
                end else if (key_cnt[ki] >= DB_CYC - 1) begin
                    key_level[ki] <= key_norm[ki];
                    key_cnt[ki]   <= 32'd0;
                end else begin
                    key_cnt[ki] <= key_cnt[ki] + 32'd1;
                end
```

**机制（Verilog 有/无符号规则的精确后果）**

`DB_CYC` 是 `integer`（32 位**有符号**）。当 `DB_MS = 0` 或 `CLK_HZ < 1000`（整数除法 `CLK_HZ/1000 == 0`）时：

```
DB_CYC   = 0
DB_CYC-1 = -1  ⇒  32'hFFFFFFFF   （有符号 → 位模式）
key_cnt  = reg [31:0]            ⇒  【无符号】
```

Verilog 规则：**只要有一个操作数无符号，比较按无符号做** ⇒ `key_cnt[ki] >= 32'hFFFFFFFF` 只在 `key_cnt == 0xFFFFFFFF` 时为真 ⇒ `key_level` **永不更新**、`key_cnt` 停在 0 ⇒ **按键完全死掉，而且没有任何报错/警告**。
（`enc_cnt` 在 `:116` 是同一个写法，同样冻结。）

交付档目前传的是 `TIMBRE_BTN_DB_MS = 5` / `PEDAL_DB_MS = 5`（`rtl/top.v:300` / `:303`）⇒ **当前不触发**；但这是个"参数一改就全静默"的陷阱，且 `CLK_HZ < 1000` 是**任何快速单元 tb** 都可能踩的（例如想用 10 MHz 以下的时钟做短仿真）。

**结构性 / 布局运气**：**结构性**（语义边界）。

**怎么改**

```verilog
// rtl/drivers/debounce.sv:54-55 之后插入
    // ⭐ 把"最后一个有效计数值"显式算出来：DB_CYC==0 ⇒ 立刻生效（0 拍去抖），⛔ 不回绕成 -1
    localparam integer DB_LAST = (DB_CYC > 0) ? (DB_CYC - 1) : 0;
```
然后把 `:76` 与 `:116` 的 `DB_CYC - 1` 都换成 `DB_LAST`。
（`DB_CYC==0` 时 `key_cnt >= 0` 恒真 ⇒ 下一拍就跟随输入 ⇒ 语义是"无去抖直通"，比"永久冻结"合理得多。）

**收益 / 代价**：0 FF · 0 LUT（常量折叠）· 风险 0。

**怎么验证能红**：在 `tb_debounce` 里加一个 `DB_MS=0` 的**第二个实例**（或者临时把 localparam 改 0 跑一次）：
```verilog
debounce #(.NKEY(1), .CLK_HZ(50_000_000), .DB_MS(0), .ACTIVE_LOW(1)) dut_db0 (...);
// 拉低 key_in[0] 后，几个周期内必须出现 key_down
```
**改前：`key_down` 永不出现 ⇒ FAIL；改后：几个周期内出现 ⇒ PASS。**

---

## [P2] `debounce` 对 **Z 输入不自保**：`~key_in` 对 `1'bz` 得 `x`，250 000 拍后 `key_level` 被写成 **X**，`key_down` 变成 X 并污染下游

**位置**：`rtl/drivers/debounce.sv:64`（按键归一）· `:105`（编码器归一）· 后果在 `:76-78`

**代码**

```verilog
// rtl/drivers/debounce.sv:61-64
    wire [NKEY-1:0] key_norm;
    integer    ki;

    assign key_norm = ACTIVE_LOW ? ~key_in : key_in;
```

**机制（逐拍推，结论是"会真的写出 X"）**

设 `key_in[i] = 1'bz`、`ACTIVE_LOW=1`：

1. `~1'bz = 1'bx` ⇒ `key_norm[i] = x`；
2. `:74` 的 `if (key_norm[ki] == key_level[ki])` ⇒ `x == 0` 求值为 `x` ⇒ **在 if 条件里按"假"处理** ⇒ 走 `else if`；
3. `key_cnt[ki] >= DB_CYC-1` 在 250 000 拍后为真 ⇒ **`:77 key_level[ki] <= key_norm[ki]` = X** ⇒ `key_level` 从"确定 0"变成"X"；
4. `key_down = key_level & ~key_level_d`（`:92`）⇒ **X**；下游（例如 `rtl/top.v:613-614` 的 `timbre_sel_r <= timbre_sel_r + 2'd1`）一旦吃到 X 就**永久 X**。

**当前为什么没炸**：`rtl/top.v:572` / `:634` 在两个例化**外面**做了 Z-safe 归一（`(x === 1'b0) ? 1'b0 : 1'b1`）⇒ 进 `debounce` 的已经是确定电平。
**但这正是问题**：模块**自身**没有防护，而它的文件头（`:9-12`）只声明"顶层负责 `sync_input`"，**从未声明"顶层还要负责 Z-safe"**。任何新调用者（P4 右手板、编码器、辅助按键）只要忘了这一层，就会拿到一个 5 ms 后才变 X 的输入 —— 而 X 在仿真里**不会立刻报错**。

**结构性 / 布局运气**：**结构性**（语义边界，与布局无关）。

**怎么改**（模块内自保，逐位 Z-safe）

```verilog
// rtl/drivers/debounce.sv:61-64 替换
    wire [NKEY-1:0] key_norm;
    wire [NKEY-1:0] key_in_z;                 // ⭐ Z/X 一律当"未按下(1)"，与 top.v:572 同口径
    genvar gk;
    generate
        for (gk = 0; gk < NKEY; gk = gk + 1) begin : gen_key_zsafe
            assign key_in_z[gk] = (key_in[gk] === 1'b0) ? 1'b0 : 1'b1;
        end
    endgenerate
    assign key_norm = ACTIVE_LOW ? ~key_in_z : key_in_z;
```
编码器侧同理（`enc_in` 的每一位用 `===` 归一，`enc_sw` 走 ACTIVE_LOW 反转、A/B 保持物理电平 —— ⛔ 别把 A/B 也反过来，那会把正转变反转，见文件 `:96-98` 的既有纪律）。
**收益 / 代价**：`NKEY` 个 LUT（NKEY=1 时 1 个）· 风险 0（`===` 对确定电平与 `==` 完全等价 ⇒ 既有判据不变）。

**怎么验证能红**：在 `tb_debounce` 里加一段：
```verilog
        key_in = 4'bzzzz;                       // ⭐ 悬空
        repeat (DB_CYC + 100) @(posedge clk);
        chk(a8_key == 0, "Z input must NOT turn key_level into X");
```
（`tb_debounce.sv:101-102` 已经有 `chk_xprop` 监视器 `u_a8_key`，**直接复用即可**。）
**改前：`a8_key != 0` ⇒ FAIL；改后：保持 0 ⇒ PASS。**

---

## [P2] `debounce` 的 `enc_lvl` 复位成 `3'b000`，而真实 EC11 上拉空闲态是 `A=B=1` ⇒ 上电必产生一次**非法 2 位跳变**（`enc_err`），且正交解码的"上一态"起点错误

**位置**：`rtl/drivers/debounce.sv:108-111`（复位值）· `:147-149`（格雷序列定义）· `:166-183`（非法跳变判据）

**代码**

```verilog
// rtl/drivers/debounce.sv:108-111
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enc_lvl <= 3'b000;                        // ← 🔴 与硬件空闲态不符
            for (ei = 0; ei < 3; ei = ei + 1) enc_cnt[ei] <= 32'd0;
```

```verilog
// rtl/drivers/debounce.sv:147-149
    // ── 正交解码：格雷序列 00 → 01 → 11 → 10 → 00 记为正转（CW）────────────
    // 两位同时变化视为非法跳变，只报 enc_err，不产生计数。
    assign enc_state = {enc_b_lvl, enc_a_lvl};
```

```verilog
// rtl/drivers/debounce.sv:177-181（非法跳变：两位同时变）
                4'b00_11: enc_err <= 1'b1;
                4'b11_00: enc_err <= 1'b1;
```

**机制**

硬件事实（`.cst` + 文件头 `:7`）：按键/编码器**全部上拉输入**，EC11 的 A/B 空闲 = `1,1`；而 A/B **不做 ACTIVE_LOW 归一**（`:96-98` 明确纪律：取反会把正转变反转）⇒ `enc_norm[1:0]` 空闲 = `2'b11`。

上电后：`enc_lvl = 3'b000`（复位值）≠ `enc_norm = 3'b011` ⇒ `:114` 不相等 ⇒ `enc_cnt` 开始计数 ⇒ 250 000 拍（5 ms）后 `enc_lvl <= 3'b011` ⇒ `enc_state` 从 `00` **一步跳到 `11`** ⇒ `case ({st_d, enc_state})` 命中 **`4'b00_11`** ⇒ **`enc_err` 拉高一拍**。
更严重的后果：解码器的"上一态"起点是**错的**（真实起点是 11，它以为是从 00 走过来）⇒ **用户上电后的第一个格雷步会被解成 `11→01`/`11→10` 等，方向/步数可能与实际不符**。

**证据（这不是我猜的，tb 自己承认了）**：`tb/drivers/tb_debounce.sv:192-194`

```verilog
        // ⭐ 初始 A/B = 00（物理），让正转测试从合法起点开始，避免起始跳变被记为非法
        enc_a  = 1'b0;
        enc_b  = 1'b0;
```

⇒ **tb 把 A/B 初值设成硬件上不存在的 `00` 来绕开这个问题**。这是"用激励回避 RTL 缺陷"的典型；`tb_debounce.sv:218` 还得再走一次 `enc_a=0; enc_b=0; settle;` 才能开始正转测试。

**当前影响面**：`.cst` 里编码器引脚**尚未分配**（"🔴 仍未分配：编码器 / 辅助按键 / …"），且 `rtl/top.v:597-599` 把 `enc_a/enc_b/enc_sw` 全接 `1'b1` ⇒ **交付档不触发**（E1 也印证：整个 EC11 半边被折掉，`u_timbre_btn_debounce Register=20` 只等于 `key_cnt(18)+key_level+key_level_d`）。⇒ **一旦接上真实编码器就会炸**。

**结构性 / 布局运气**：**结构性**。

**怎么改**（把空闲态参数化；⛔ 必须同步改 tb，否则会红 —— 那是**正确的契约变更**）

```verilog
// 参数表（:24-29）新增
    parameter [1:0] ENC_IDLE = 2'b11           // ⭐ 硬件上拉空闲态：A=B=1（编码器引脚分配后按实物核对）
// :110 改为
            enc_lvl <= {1'b0, ENC_IDLE};       // [2]=SW 归一后空闲(0)，[1:0]=A/B 物理空闲态
```
并把 `tb_debounce.sv:192-195` 的初值改成 `enc_a=ENC_IDLE[0]` / `enc_b=ENC_IDLE[1]`（= 1/1），删掉 `:218` 那次"先走到 00"的额外动作 —— 因为**从真实空闲态出发才是正确的正转起点**。

**收益 / 代价**：0 额外逻辑（只是常量变了）· 代价 = **必须同步改 tb**（`tb_debounce` 的 `enc_err_cnt == 0` 判据会因初值改变而需要重算）。
**怎么验证能红**：把 `ENC_IDLE` 保持 `2'b11` 但**不改 tb**，把 tb 的初值改成 `A=B=1` 后直接跑：
**改前：上电后 `enc_err_cnt >= 1` ⇒ "EC11 CW: enc_err == 0" FAIL；改后：0 ⇒ PASS。**

---

## [P2] `adc_farm` 的 `sclk_r` / `cs_r` **没有复位分支** ⇒ 上电首拍 `sclk_rise` / `cs_fall` 为 X（靠 `rst_n` 宽度兜住）

**位置**：`rtl/drivers/adc_farm.sv:125-127` 与 `:129-131`

**代码**

```verilog
// rtl/drivers/adc_farm.sv:125-131
    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];      // ← ⛔ 无 if(!rst_n)
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);

    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];        // ← ⛔ 无 if(!rst_n)
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);
```

**机制**

同文件里 `shadow_hold` 的 always（`:169-177`）**有**复位分支，而这两个 1 位比较器**没有**。上电时 `sclk_r = X`，且 `adc_sclk[0]` 在第一个时钟沿之前也是 X（它由 `mcp3208_driver` 的**同步**复位寄存器驱动）⇒ 第一拍 `sclk_rise` 可能是 X，从而 `shadow_hold` 的**移位使能**为 X。
**为什么现在没炸**：`:169-177` 的 `if (!rst_n)` 分支**优先级最高**，只要 `rst_n` 在低电平维持 ≥2 拍（`top` 用的是 `rst_n_sync`，`u_rst_sync` 2 级），X 就进不去。**但这是"靠复位宽度兜住"，不是"结构上安全"**：任何把 `rst_n` 在 1 拍内释放的用法（单元 tb、仿真激励）都会让 `shadow_hold` 吃到 X ⇒ **`sample_data_packed` 变 X**。

**结构性 / 布局运气**：**结构性**（复位覆盖不全）。

**怎么改**

```verilog
    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_r <= 1'b0;
            cs_r   <= 1'b1;              // CS 空闲为高（低有效）
        end else begin
            sclk_r <= adc_sclk[0];
            cs_r   <= adc_cs_n[0];
        end
    end
```
**收益 / 代价**：+0 LUT（FF 已有，只是补了复位端）· 风险 0。

**怎么验证能红**：写一个最小 tb：`rst_n` 只低 1 拍（`#20` 后释放），随后断言 `sample_data_packed` **不含 X**（复用仓库已有的 `chk_xprop`）。
**改前：`sclk_r`/`cs_r` 的 X 有机会把 `shadow_hold` 打成 X ⇒ FAIL；改后：PASS。**

---

## [P2] `play_mode_ctrl`：**拨弦与按弦同拍**到达时，按弦事件被 `else if` 链整条丢弃，拨弦用到**上一次的 `selected_axis`**

**位置**：`rtl/w3a/play_mode_ctrl.v:59`（拨弦分支优先）· `:68`（按弦分支）

**代码**

```verilog
// rtl/w3a/play_mode_ctrl.v:59-72
            end else if (pluck_valid_i && selected_valid) begin
                // Fretboard: a pluck is the musical trigger. ...
                evt_axis_o  <= selected_axis;      // ← 用的是【旧】的选择
                ...
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;      // ← 同拍到达时，这一句根本执行不到
                    selected_depth <= axis_depth_i;
                end
```

**机制**

`pluck_valid_i` 来自**板外异步比较器**（`async_pluck_capture`，`rtl/top.v:3199-3210`，任意相位），`axis_valid_i`（`ee_valid`）来自 **500 µs 帧节拍**（`adc_farm` → `event_extract`）。
两者落在**同一 `clk` 拍**的概率 ≈ `1 / 25000` 每次事件（帧周期 25000 拍）。按每秒 5 次轴事件估算 ⇒ 约 **1 次 / 83 分钟**连续演奏。
撞上时：`:59` 分支优先 ⇒ **按弦的 `selected_*` 不更新** ⇒ 拨弦发出的是**上一个音符的轴/力度** ⇒ 听感是"按了 A 键、响的是 B 音"。

**结构性 / 布局运气**：**结构性**（仲裁优先级，与布局无关）。

**怎么改**（把同拍按弦"提前算出来"给拨弦用；⛔ 不要简单地把两个分支换序 —— 那会让"拨弦优先"的既有契约反过来）

```verilog
// 在 always 之前算"本拍若发生 ON，选中值会变成什么"
    wire              on_now    = axis_valid_i && (axis_kind_i == KIND_ON);
    wire [AXIS_W-1:0] sel_ax_n  = on_now ? axis_i       : selected_axis;
    wire [DEPTH_W-1:0] sel_dp_n = on_now ? axis_depth_i : selected_depth;
    wire              sel_vd_n  = on_now ? 1'b1         : selected_valid;
// :59 分支改用（注意用 sel_vd_n 而不是 selected_valid）
            end else if (pluck_valid_i && sel_vd_n) begin
                evt_axis_o  <= sel_ax_n;
                evt_depth_o <= sel_dp_n;
                gate_axis   <= sel_ax_n;
```
**收益 / 代价**：+约 12 LUT（4+12 位 mux 各一级）· 风险低（既有判据不变：`:59` 在 `on_now=0` 时 `sel_*_n` 与 `selected_*` 逐位相同）。

**怎么验证能红**：追加同拍激励

```verilog
        fretboard_mode = 1'b1;
        axis_evt(4'd4, 2'd0, 12'd500); repeat (2) @(posedge clk);   // 先选中 4
        // ⭐ 同拍：新轴 ON + 拨弦
        @(negedge clk); axis=4'd11; axis_kind=2'd0; axis_depth=12'd800; axis_valid=1'b1;
                        pluck_up=1'b1; pluck_valid=1'b1;
        @(negedge clk); axis_valid=1'b0; pluck_valid=1'b0;
        repeat (2) @(posedge clk);
        chk("same-cycle press+pluck must play the NEW axis",
            events_axis[event_n-1] == 4'd11);
```
**改前：播的是轴 4 ⇒ FAIL；改后：轴 11 ⇒ PASS。**

---

## [P2] `mcp3208_scanner` 帧周期**饱和分支**：转换一旦慢过帧周期，采样率会**静默超过** `CHANNEL_RATE_HZ`（下游 VOTE_N / STABLE_NEED 的时基随之失效）

**位置**：`rtl/mcp3208_scanner.sv:115-121`（饱和）· `:139-140`（判据）

**代码**

```verilog
// rtl/mcp3208_scanner.sv:115-121
                    STATE_WAIT_DRIVER: begin
                        // Measure the frame period from the CH0 start event.
                        // Saturation makes an overrun start the next frame as
                        // soon as the current frame finishes.
                        if (frame_counter < FRAME_PERIOD - 1) begin
                            frame_counter <= frame_counter + 1'b1;
                        end
```

```verilog
// rtl/mcp3208_scanner.sv:139-149
                    STATE_WAIT_PERIOD: begin
                        if (frame_counter >= FRAME_PERIOD - 1) begin
                            frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
                            driver_channel <= 3'd0;
                            driver_start   <= 1'b1;
                            state          <= STATE_WAIT_DRIVER;
```

**机制**

`FRAME_PERIOD = 50_000_000 / 2000 = 25000` 拍 = 500 µs。8 笔转换 = 8 × 24.5 µs = **196 µs = 9800 拍**（`SCLK_HZ=1 MHz` ⇒ `HALF_DIV=25`，见 `mcp3208_driver.sv:25-29`）⇒ 正常路径下 `frame_counter` 在 `WAIT_DRIVER` 段只走到 ~9800，**不饱和**；余下 ~15200 拍在 `WAIT_PERIOD` 空等 ⇒ 帧周期精确 25000 拍（`tb_mcp3208_scanner.sv:269-277` 与 `tb_adc_farm.sv:156-159` 都断言 500000 ns，且 PASS）。

**但**：若将来把 `SCLK_HZ` 调低（或加片导致单帧转换时间变长）使 8 笔 > 500 µs，则 `frame_counter` 在 `WAIT_DRIVER` 段**饱和在 24999**，`WAIT_PERIOD` 立刻满足条件 ⇒ **下一帧马上开始** ⇒ **实际通道速率 = 1/转换时间 > 2000 Hz**，而 `CHANNEL_RATE_HZ` 这个参数**名义上仍写着 2000**。
下游 `rtl/top.v:3135` 注释明确说"改采样率会连带影响 `VOTE_N`/`STABLE_NEED`/`debounce` 等" ⇒ 一旦静默超标，**这些时间窗全部按错误时基工作**，且**没有任何信号能告诉你发生了饱和**。

**结构性 / 布局运气**：**结构性**（时序契约）。

**怎么改**（加一个 sticky overrun 观测位，成本 1 FF；不改既有节拍）

```verilog
// 端口（:17-18 附近）新增
    output reg        period_overrun,          // ⭐ sticky：本帧发生过饱和（采样率已被迫提高）
// :119-121 改为
                        if (frame_counter < FRAME_PERIOD - 1) begin
                            frame_counter <= frame_counter + 1'b1;
                        end else begin
                            period_overrun <= 1'b1;   // ⭐ 饱和 ⇒ 记一笔（只置不清，复位清）
                        end
// 复位段补：period_overrun <= 1'b0;
```
（`top.v` 可把它并进已有的 `fault_any_w`，这样"SPI 慢到改变采样率"就会亮心跳灯。）

**收益 / 代价**：+1 FF / +1 LUT；收益 = 把"静默的时基漂移"变成"可观测的 sticky 故障"。风险：`top.v` 需加一根接线（`adc_farm` 要把它透传出来）。

**怎么验证能红**：把 `tb_mcp3208_scanner` 的 `SCLK_HZ` 改成 `200_000`（8 笔 = 8 × 122.5 µs = 980 µs > 500 µs）⇒ 断言 `period_overrun == 1'b1`。
**改前：无此信号（或恒 0）⇒ FAIL；改后：1 ⇒ PASS。**

---

## [P3] `mcp3208_driver` 的 `rx_shift` 是 24 位，但**只有 `[11:0]` 被读** ⇒ `[23:12]` 是 12 个"只喂自己"的触发器

**位置**：`rtl/drivers/mcp3208_driver.sv:38`（声明）· `:114`（移位）· `:156`（唯一读口）

**代码**

```verilog
// rtl/drivers/mcp3208_driver.sv:38
    reg [23:0] rx_shift;
// :114
                        rx_shift <= {rx_shift[22:0], adc_miso};
// :155-156
                    //24位接收帧的最低12位就是ADC的采样结果
                    adc_data <= rx_shift[11:0];
```

**机制（用 E1 反推，逐项精确吻合）**

E1：`u_scan0 → driver_inst Register="50" Lut="54"`。逐项对：

```
div_counter(5) + bit_counter(5) + rx_shift(24) + state(2) + adc_data(12) + busy(1) + done(1) = 50  ✅ 精确
```
⇒ **`tx_shift`(24) 与 `channel_latched`(3) 已经被综合器折掉了**（`tx_shift` 由常量装载、只做确定性移位 ⇒ 被替换成 `adc_mosi = f(bit_counter, channel)` 的译码），**而 `rx_shift` 仍是 24 位**。
因为 `rx_shift[23:12]` 的扇出只是它自己的 `[22:0]`（`:114`），**不是死逻辑**，所以工具不会删它；但它们在**语义上无用** —— 12 次移位就足以把最后 12 位推进 `[11:0]`。

**结构性 / 布局运气**：**结构性**（位宽冗余），但**收益很小**（12 FF / 17202 = 0.07%）。

**怎么改**

```verilog
    reg [11:0] rx_shift;                                  // :38
    rx_shift <= {rx_shift[10:0], adc_miso};               // :114
    adc_data <= rx_shift[11:0];                           // :156（不变）
```
**收益 / 代价**：**−12 FF**（若工具不折则 −12 LUT 的移位逻辑）· 风险 0（**逐位等价**：第 13..24 个上升沿把 B11..B0 推进 12 位移位器，第 24 拍时 `[11:0] == 原 24 位版的 [11:0]`）。

**怎么验证能红**：
1. **等价**：`tb_mcp3208_driver` 必须仍全 PASS（`:136-144` 逐通道比对 `adc_data == test_value`，8 个通道全查）—— 这条 tb **足够强**，是本条的安全网。
2. **资源**：改完看 E1，`driver_inst` 的 `Register` 必须从 **50 → 38**。

---

## [P3] `mcp3208_driver` 的**第 1 个 MOSI 位不是从 `tx_shift` 出来的**，而是 IDLE 分支的常量 `1'b0`（靠"5 个前导零"恰好兜住）

**位置**：`rtl/drivers/mcp3208_driver.sv:79`（IDLE 置 0）· `:88-95`（装载）· `:138`（后续位）

**代码**

```verilog
// rtl/drivers/mcp3208_driver.sv:76-101
                STATE_IDLE: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;                 // ← 第 1 位就是它
                    ...
                    if(start) begin
                        ...
                        tx_shift <= {
                            5'b00000,             // ← tx_shift[23:19]
                            1'b1,                 // ← tx_shift[18]  START
                            1'b1,                 // ← tx_shift[17]  SGL/DIFF
                            channel[2],           // ← tx_shift[16]
                            channel[1:0],         // ← tx_shift[15:14]
                            14'd0                 // ← tx_shift[13:0]（含 MSBF/NULL）
                        };
```
```verilog
// rtl/drivers/mcp3208_driver.sv:138-139
                            adc_mosi <= tx_shift[22];
                            tx_shift <= {tx_shift[22:0], 1'b0};
```

**机制（逐沿推演，这是全文件最容易看错的一处）**

`adc_mosi` **只在 `STATE_SCLK_HIGH`（下降沿）更新**为 `tx_shift[22]`。而**第 1 个 SCLK 上升沿**发生在 `STATE_SCLK_LOW` 首次计满之后 —— 此时 `adc_mosi` 还是 IDLE 里写的 `1'b0`。推演：

| SCLK 上升沿 #k | 从机采到的 `adc_mosi` | 来自 |
|---|---|---|
| 1 | `1'b0` | **IDLE 常量（不是 `tx_shift[23]`）** |
| 2 | `tx_shift(0)[22]` | 第 1 个下降沿 |
| 3 | `tx_shift(0)[21]` | 第 2 个下降沿 |
| … | … | … |
| 24 | `tx_shift(0)[0]` | 第 23 个下降沿 |

⇒ 帧的第 1 位**恰好**等于 `tx_shift[23]`，**因为 `tx_shift[23]` 被硬写成 0**。**换任何一个非零前导（例如给别的 SPI 器件改成 `5'b00001`）都会静默错 1 位。**
**唯一的安全网**是 `tb_mcp3208_driver.sv:126-134` 的整帧比对（`captured_mosi !== 24'h06xxxx`）—— **它确实能抓到**（因为 `captured_mosi` 会把第 1 位也收进去）。⇒ 所以这是**可读性/隐式耦合**问题，**不是隐藏 bug**。

**结构性 / 布局运气**：**结构性**（但当前行为正确）。

**怎么改**（让第 1 位显式来自 `tx_shift`，或至少写死注释）

```verilog
// 方案 A（最小、零回归）：在 :99 处把 IDLE 的常量写成"与 tx_shift[23] 同源"
                    adc_mosi <= 1'b0;   // ⭐ == tx_shift[23]（前导 5 位恒 0）—— ⛔ 改前导域必须同步改这里
// 方案 B（结构正确）：让 IDLE 也用 tx_shift 的 MSB
                    adc_mosi <= tx_shift[23];   // 复位时 tx_shift=0 ⇒ 上电仍为 0
```
**收益 / 代价**：0 FF / 0 LUT · 风险 0（方案 B 需确认复位时 `tx_shift=0`，`:56` 已复位为 0 ✅）。

**怎么验证能红**：把 `tx_shift` 的 `5'b00000` 改成 `5'b00001`（一个假想的改动），**期望** `tb_mcp3208_driver` 报 `FAIL CH0: MOSI=860000, expected=060000`。
- **若 tb 报 FAIL** ⇒ 说明安全网有效（当前情况，符合我上面的推演）；
- **若 tb 不报** ⇒ 说明有我没算到的路径，必须回头复核。
（这条"能红"判据的价值在于：**它同时验证了 tb 的 MOSI 整帧比对是真判据**。）

---

## [P3] `play_mode_ctrl.pluck_up_i` 是**声明了从不读**的死端口

**位置**：`rtl/w3a/play_mode_ctrl.v:20`（声明）；全文件无第二处出现

**代码**

```verilog
// rtl/w3a/play_mode_ctrl.v:19-20
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // direction retained at capture seam
```

**机制**：`grep pluck_up_i rtl/w3a/play_mode_ctrl.v` ⇒ **只命中第 20 行（端口声明）**。拨弦分支（`:59-67`）对两个方向一视同仁（`:61-62` 注释也承认："Direction has already been resolved by async_pluck_capture (UP priority)"）⇒ **方向信息在这一层被有意丢弃**，但端口留着，`rtl/top.v:3224` 还认真地把 `pluck_up` 接了进来。
⇒ 一个后来者读到这里会以为"方向会影响事件"，从而在错误的前提下改代码。

**结构性 / 布局运气**：**结构性**（接口冗余）。综合代价 **0**（未使用的输入不产生逻辑）。

**怎么改**（二选一）
- **(a) 删端口**：删 `:20`，并删 `rtl/top.v:3224` 的 `.pluck_up_i (pluck_up)`；`pluck_up` 在 `top` 里若还有其他消费者则保留。
- **(b) 兑现语义**：把方向带进事件（例如 `evt_depth_o` 的高位或 `evt_kind_o` 扩 1 位），但这会**改变下游契约**（`evt_merge` / `note_manager`），**不建议在本摊做**。

**收益 / 代价**：0 资源；收益 = 消除一处"看起来有语义、实际没有"的接口。风险 0。

**怎么验证能红**：本条**无法用 tb 变红**（删掉未使用端口不改变任何可观测行为）—— ⚠️ **我明确标注它不可红**，验证方式只有一条：`grep` 证明零读 + 综合后 `u_play_mode_ctrl` 的 `Register`/`Lut` **不变**（E1 的 17 FF / 17 LUT 必须保持）。

---

## [P3] `mcp3208_driver` 的 `default` 分支**不可达**（4 个状态码已全部枚举），且它**没有清 `div_counter`/`bit_counter`**

**位置**：`rtl/drivers/mcp3208_driver.sv:42-47`（状态编码）· `:171-178`（default）

**代码**

```verilog
// rtl/drivers/mcp3208_driver.sv:42-47
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_SCLK_LOW = 2'd1;
    localparam [1:0] STATE_SCLK_HIGH = 2'd2;
    localparam [1:0] STATE_FINISH = 2'd3;
    reg [1:0] state;
```
```verilog
// rtl/drivers/mcp3208_driver.sv:171-178
                default: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;
                    busy     <= 1'b0;
                    state    <= STATE_IDLE;
                end
```

**机制**：`state` 是 2 位，`2'd0..2'd3` **四个值全部被 `case` 显式列出** ⇒ `default` 在 RTL 语义上**不可达**（工具应能证明并折掉；E1 的 `driver_inst Lut=54` 与之相容，但无法单独归因）。
⇒ 这是**防御性写法**，本身不是缺陷。**唯一实质问题**：`default` 里**没有** `div_counter <= 0; bit_counter <= 5'd0;`，而其它分支进 IDLE 时都会清（`:82-83`）⇒ 若将来把状态编码扩到 3 位并新增状态，从 `default` 回 IDLE 会带着**陈旧的 `div_counter`/`bit_counter`** 重新开始（表现为"第一次转换的 SCLK 周期偏短/位偏移"）。

**结构性 / 布局运气**：**结构性**（防御性代码的完备性）。

**怎么改**

```verilog
                default: begin
                    adc_cs_n     <= 1'b1;
                    adc_sclk     <= 1'b0;
                    adc_mosi     <= 1'b0;
                    busy         <= 1'b0;
                    div_counter  <= {DIV_WIDTH{1'b0}};   // ⭐ 补
                    bit_counter  <= 5'd0;                // ⭐ 补
                    state        <= STATE_IDLE;
                end
```
**收益 / 代价**：0（不可达分支；补上后若工具仍能证明不可达则仍折掉）· 风险 0。

**怎么验证能红**：**当前不可红**（不可达分支）。验证方式：改完确认 E1 的 `driver_inst` 资源**不变**（若变了说明工具其实没折掉，那这条就从 P3 升级为 P2 —— **这本身就是一次有价值的核查**）。

---

# 附录A · 已核查 · **非问题**（9 条，全部有数字，用来阻止白干）

> ⚠️ 这 9 条同样是"证据结论"。**凡是我在初稿里怀疑过、最后用 E1/E2/E3 证伪的，一条都不删** —— 否则下一个人会把同样的怀疑再跑一遍。

### A1. SPI 采集链（`adc_farm` + `scanner` + `driver`）**不是** Fmax 瓶颈
- **E1/E2**：`u_adc_farm` 自用 = **1 LUT**（=0 档）/ **25 LUT**（=1 档）· `u_scan0` = 49 LUT（内含 `driver_inst` 54 LUT）⇒ 三者合计 **128 LUT = 全设计 27589 LUT 的 0.46%**。
- **E3**：=1 档 **Top-25 setup 路径里没有一条**来自这三个模块（25 条全是 `u_tdm_render_mixer` 的 `cnt_4_s0 → prod_c_0_s`、`u_note_manager` 的 `phase_r[*] → g_t3.phase_tr[*]`、`u_tdm_render_mixer/mult_*`）。第 25 条的 slack 已是 **+1.364 ns** ⇒ 这三个模块**全部余量 > 1.36 ns**。
- ⇒ **"SPI 位计数/移位链是长组合链"这个假设不成立**：`div_counter == HALF_DIV-1`（5 位 vs 常量 24）、`bit_counter == 5'd23` 都是 5 位常量比较；`div_counter+1` 走 Gowin 的进位链。**不要在这里做时序优化。**

### A2. 多片并行片选/扇出**不是**问题
`gen_fanout`（`adc_farm.sv:114-120`）把 `adc_cs_n[0]`/`adc_sclk[0]`/`adc_mosi[0]` 扇出到 `N_ADC` 个 **IO 焊盘**：`N_ADC=2` ⇒ 扇出 2；`N_ADC=3` ⇒ 扇出 3；即使拉到 6 片也只 **6**。对照本设计真正的扇出大户（`oscillator_bank` 的 64 lane），这个量级**连一级缓冲都不需要**。E2 实测：`N_ADC` 2→3 的全部代价 = **+12 FF / +24 LUT**。

### A3. 去抖计数器"32 位浪费"**已经被综合器自动窄化** ⇒ 不要改
`debounce.sv:60` 声明 `reg [31:0] key_cnt [0:NKEY-1]`，实际只需 `$clog2(250000) = 18` 位。**E1 实测**：
- `u_timbre_btn_debounce Register="20"` = **18**（`key_cnt`）+ 1（`key_level`）+ 1（`key_level_d`，因为 `key_down` 被用）✅
- `u_pedal_sus_debounce Register="19"` = **18** + 1（`key_level`；`key_down`/`key_up` 空连接 ⇒ `key_level_d` 被折掉）✅
⇒ **两个实例都精确吻合"18 位"**。⇒ "把 32 位改 18 位"的收益 **= 0**，且会改动一段本来正确的代码。**别动。**

### A4. `debounce` 的 EC11 半边在交付配置里**已被整体折掉**
`rtl/top.v:597-599` / `:659-661` 把两个实例的 `enc_a`/`enc_b`/`enc_sw` 全接 `1'b1`（常量）⇒ `enc_norm = 3'b011` 为常量 ⇒ E1 显示 `u_timbre_btn_debounce` 总共只有 **36 LUT / 20 FF**，**不含** 3×18 位的 `enc_cnt` 与 3 个比较器。⇒ "EC11 半边白烧 200 个 FF"这个怀疑**不成立**。（真正的坑是它的**复位态**，见 §P2 那条。）

### A5. `right_analog_ctrl` 的 64 点对数 LUT **已经是最优实现**（无宽 mux / 无 DSP / 无 BSRAM）
- **E2（=1 档）**：`u_right_analog_ctrl Register="41" Lut="65"`。
- FF 逐项对：`master_gain_o(16) + vibrato_depth_o(12) + vibrato_rate_o(12) + pending_q(1) = 41` ✅ **精确**。
- LUT 逐项对：64×16 = **1024 bit** 的表 = 1024/16 = **64 个 LUT4**（每个 LUT4 当 16 bit ROM）+ 1 个地址逻辑 = **65** ✅ **精确**。
- ⇒ 综合器把它实现成**分布式 ROM**（正如 `:24` 注释所期望），**没有 64:1 宽 mux、没有额外 DSP**（`T_Bsram` 在 =0/=1 两侧都是 30，未变）。⇒ **不要"优化"这个 LUT。**

### A6. `fader_gear` 的 `gear_step_of` 12 级比较链**代价极小**，**且不在 =1 档 Top-25**
- **E2**：`u_fader_gear = 12 FF / 10 ALU / 95 LUT`；**E1**（=0 档）：`7 FF / 0 ALU / 31 LUT` ⇒ 增量 = **+64 LUT / +10 ALU**。
- `+10 ALU` ≈ `fader_enc6` 的 6 位加/减；`+64 LUT` ≈ 两条 `gear_step_of`（**≈32 LUT/条**）⇒ **不是 12 级串联 mux**（那会是 12 级 × 4 位 × 2 条 ≫ 64 LUT）。Gowin 把**单调阈值链**实现成了纯 LUT 译码。
- **E3**：=1 档 Top-25 里**没有一条**经过 `u_fader_gear`。⇒ **"档位选择是长组合链"这个假设不成立。**
- ⚠️ 我在草稿里也验证过"跨模块组合穿透"：`right_analog_ctrl.vibrato_depth_o(reg) → fader_gear.vibrato_depth_o(组合 mux, :258-266) → top → vibrato_lfo` 确实是一条**无中间寄存器的组合穿透**，但 E3 显示它的 slack **> 1.364 ns**（不在 Top-25），且 1630 那条最差路径的**起点在 `vibrato_lfo` 内部**（`phase_q_17_s0`），**不在这个 mux 上**。⇒ **不要为它加流水。**

### A7. `fader_gear` 的"(左档位,右档位) 非单射"角**不是缺陷**（`:76-79` 的自述正确）
文件 `:76-79` 说：`fader_enc` 对 (左,右) 非单射（如 (0,0) 与 (1,1) 都得 12）⇒ 若同拍两推子各走恰好抵消的档数则不接管，但"此时变调值本来就没变"。
**逐位核对**：`fader_enc = 12 + right_step − left_step`（`:149-150`）⇒ 不接管时 `enc_r` 不变，而 `transpose_semi_o = enc_r − 12`（`:249`）也不变；若接管，新值 `fader_enc` 与原值相等 ⇒ **输出同样不变**。⇒ **功能上无差异，自述正确。**（本条列入附录是为了防止后人把它当 bug"修"掉。）

### A8. SPI mode-0 的采样裕量充足（MISO 建立 ≈300 ns · MOSI 建立 ≈500 ns）
- `HALF_DIV = 25` 拍 = **500 ns** 半周期（`mcp3208_driver.sv:25-29`）。
- 从机在 SCLK **下降沿**更新 DOUT；FPGA 在**内部时钟沿**采 MISO（该沿比引脚上升沿早约 Tco ≈ 5 ns）⇒ 采样点距 DOUT 更新 **≈495 ns**；再经 `adc_farm` 的 2 级同步（**40 ns**，`sync_input.v:45-52`）⇒ 最坏仍有 **≈455 ns** 裕量（MCP3208 的 `tDO` 手册量级 ~200 ns）✅。
- MOSI：`adc_mosi` 在下降沿更新，到下一个上升沿有整 **500 ns** 建立时间 ✅。
- ⇒ **采样点无需调整**（`mcp3208_driver.sv:113-114` 的注释"mode 0：在上升沿读取 MISO"与实现一致）。

### A9. `adc_farm` 的兼容别名端口在交付 `top` 里**全空连接** ⇒ 代价 0；`adc_miso` 未用位有硬件上拉
- `rtl/top.v:1702-1704`：`.sample_data0 ()`, `.sample_data1 ()`, `.sample_data2 ()` ⇒ `sample_data_alias`（`adc_farm.sv:201-214`）整条被折掉 ✅（K-89 的 generate 保护仍然是对的：它防的是**别的**例化者索引越界）。
- `rtl/top.v:1684` `af_miso = spi_miso[ADC_N-1:0]`，其余位未用；`constr/top.cst` 对 `spi_miso[3..5]` 全部 `PULL_MODE=UP` ⇒ **不会悬空乱跳** ✅（`rtl/top.v:1682-1683` 的注释正确）。

---

# 附录B · 复现与落门（改任何一条之前先看这段）

**本条目的任何 RTL 改动都必须过四道门**（顺序不可省）：

| 门 | 命令 | 判据 |
|---|---|---|
| ① 综合 | `sim/gowin_build.ps1` 的编译段（或 IDE 综合） | `ERROR=0`（⭐ 特别注意 `EX3872` 这类**作用域**错误：tb 抓不到，只有综合门能拦，见 `rtl/top.v:1710-1714` 的实证） |
| ② 聚焦 tb | 与本摊相关的：`tb_adc_farm` · `tb_mcp3208_driver` · `tb_mcp3208_scanner` · `tb_debounce` · `tb_fader_gear` · `tb_right_analog_ctrl` · `tb_play_mode_ctrl` · `tb_right_adc` · `tb_span_with_real_adc_farm` | 全绿 |
| ③ 干净 PnR | `sim/gowin_build.ps1` | **0 setup / 0 hold** · 无 `PR0004` · `Actual Fmax ≥ 51.5 MHz`（读 `sim/evidence/gowin_m0_timing.txt`） |
| ④ 全量回归 | `sim/tb_all.ps1`（~15 min） | **通过数 == 共数**（⛔ 不要写死数字；`tb_all.ps1` 自动发现 `tb/**/tb_*.sv`，当前 131 个文件） |

**⚠️ 本摊改动的门③风险提示**：=1 档（`RIGHT_ADC_ENABLE=1`）最差余量只有 **+0.642 ns**（E3）⇒ **任何动 `right_analog_ctrl` / `fader_gear` / 颤音链的改动，都必须用 `build/rightadc-probe/` 探针副本单独跑一次 =1 档 PnR**，不能只看 =0 档的 55.06 MHz。E1/E2 显示 =1 档比 =0 档多 **+163 FF / +449 LUT / +3 DSP**，CLS 从 78% → 81% ⇒ 布线更挤。

**⚠️ 不要踩的坑（本摊相关）**：`tb/models/oscillator_bank_ref.v` 是 **P5-② 基线副本**，`tb_p5_osc_equiv` 拿它做**逐位等价**比对。本报告**没有**建议改 `oscillator_bank`，所以**不需要**同步它；但如果谁要顺着附录 A6/§P1 那条线去动颤音链，**必须同步改该副本**，否则 `tb_p5_osc_equiv` 会**假红**（差 2 拍流水）。

**判定口径提醒**：本报告所有"结构性 / 布局运气"的分类都基于 **E1/E2 的资源差分 + E3 的 Top-25 名单**，而不是"跑得快慢"。⚠️ 按 E5 的实测，`=1` 档 25/25 条最差路径**同源**，所以**重跑 PnR 不会改善它** —— 遇到这类结论，⛔ 不要靠"再跑一次布局"去验证。
