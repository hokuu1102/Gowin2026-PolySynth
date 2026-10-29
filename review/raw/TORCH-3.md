# TORCH-3 · clk_gen / rst_sync / sync_input 与全部跨时钟域衔接面 · 逐跳审计

> **范围**：`rtl/clk_gen.v` · `rtl/rst_sync.v` · `rtl/sync_input.v` · 以及 **UART / SPI / WS2812 / I2S / HDMI / 按键** 六条衔接面的每一跳。
> **战场事实（本报告全部数值以此为准）**：GW5AT-60B · `AC1/I0` · `clk_sys = 50 MHz`（V22）·
> SDC `set_max_delay 18.181 ns`（≈55 MHz）· 实测 **= 0 档 55.06 MHz / CLS 78%** ·
> **= 1 档（`RIGHT_ADC_ENABLE=1`）≈57.0 MHz / CLS 81%** · 门槛 **0 setup / 0 hold、Fmax ≥ 51.5 MHz** ·
> 布局噪声主导（同源重跑差 2~3 MHz）。
> ⚠️ `tb/models/oscillator_bank_ref.v` 是 P5-② 基线副本 —— 本报告**不改任何 RTL**，故不涉及该同步义务。
>
> **本报告的实测证据源**（全部为工作区内的真实产物，非推演）：
> - `impl/pnr/Gowin2026.timing_paths`（PnR 真实路径表，50 个 block：25 SETUP + 25 HOLD）
> - `sim/evidence/final-batch-20261008/timing.txt`（Fmax / clock summary / 违例端点）
> - `sim/evidence/final-batch-20261008/pnr-rpt.txt`（资源：CLS 78%、DSP 22/118）
> - `constr/top.sdc` · `constr/top.cst` · `rtl/**`（逐行 read）
>
> **每条格式**：`文件名:行号` → 确切代码片段 → 机制（带数字）→ 具体改法 → 预期收益/代价 → **怎么验证能红** → 优先级。
> 凡"检查过且干净"的，收进 §附录 B（⛔ 不假装没看）。

---

## 〇、结论速览

| 级别 | 条数 | 一句话 |
|---|---|---|
| **P0** | **4** | 复位释放顺序在 10 个模块上**已失效**；125 MHz 域**零时序验证**；已证明的伪事件注入路径**被默认打开**；`g_silent` 档故障见证线**悬空** |
| **P1** | **10** | HDMI 半周期 hack 靠**综合后网名**挂约束；4 个手写同步器**无 `async_reg`**；SDC 只约束了 **5/25** 个 I/O；最差 25 条路径**全是结构性**且余量 **0.102 ns** |
| **P2** | **8** | `adc_farm.fault_r` **永远为 0**；影子反串行器**差 1 拍**；心跳分频**下溢**；DSP **22 个**而文档写 1 个 |
| **P3** | **5** | 文档/代码不一致、`$display` vs `$fatal` 混用、双份真相常量 |

**最扎心的三条（若只改三处）**：`P0-02`（复位）· `P0-03`（伪事件挂音）· `P1-01`（HDMI 半周期约束）。

---

## 一、逐跳核对表（谁寄存 / 谁组合 / 差几拍 / 同步级数）

### 1.1 `clk_gen` → 全设计（**单域，0 级同步，全部为"节拍使能"**）

| 跳 | 位宽 | 产生方 | 寄存? | 消费方 | 差几拍 | 同步级数 | 结论 |
|---|---|---|---|---|---|---|---|
| `tick_audio` | 1 | `clk_gen.v:104` `cnt==0` | ✅ 寄存 | `note_manager`/`envelope_bank`/`oscillator_bank`/`perc_env_bank`/`master_mix`/`vu_*` | 0 | **不需要** | ✅ 干净 |
| `mclk_en` | 1 | `clk_gen.v:105` `cnt[1:0]==0` | ✅ 寄存 | 仅观测（板载 DAC 不用） | 0 | 不需要 | ✅ 干净 |
| `bclk_en` | 1 | `clk_gen.v:106` `cnt[3:0]==0` | ✅ 寄存 | `i2s_tx` ×2 实例 | 0 | 不需要 | ✅ 干净 |
| `bclk_half_en` | 1 | `clk_gen.v:107` `cnt[2:0]==0` | ✅ 寄存 | `i2s_tx` ×2（翻转 `HP_BCK`） | 0 | 不需要 | ✅ 干净 |
| `lrclk` | 1 | `clk_gen.v:108` `bpos>=32` | ✅ 寄存 | **⛔ 无人使用**（`i2s_tx` 自建 WS） | — | — | ⚠️ 死输出（无害） |
| `frame_start` | 1 | `clk_gen.v:109` | ✅ 寄存 | `i2s_tx` ×2 | 0 | 不需要 | ✅ 干净 |

**数值核对**：`bclk_en` 周期 = 16 clk = **320 ns = 3.125 MHz** ✅；`bclk_half_en` 周期 = 8 clk = 160 ns ⇒ `HP_BCK` 半周期 160 ns ⇒ **3.125 MHz** ✅；
`tick_audio` 周期 = 1024 clk = **20.48 µs = 48.828125 kHz** ✅。三者**同源同拍**，⛔ 不存在跨域。

### 1.2 复位链（**这是本报告最脏的一条链**）

| 跳 | 位宽 | 产生/传递 | 复位风格 | 消费方 | 释放沿是否同源 | 同步级数 |
|---|---|---|---|---|---|---|
| `rst_n`（AA13 按键） | 1 | 板外来 | — | `u_rst_sync` | — | — |
| `sync_chain[1:0]` | 2 | `rst_sync.v:39-45` | **纯同步** | `rst_n_sync` | ✅ 同一 clk_sys 沿 | **2** |
| `rst_n_sync` → 同步复位模块 | 1 | `if(!rst_n_sync)` | ✅ 同步 | `clk_gen`/`i2s_tx`/`note_manager`/… | ✅ **同沿** | 2 |
| `rst_n_sync` → **异步复位模块** | 1 | `posedge clk or negedge rst_n` | 🔴 **异步** | `debounce.sv`(7 块)·`calib.sv`(3)·`adc_farm.sv`(1)·`looper.v`(2) | 🔴 **各 FF 各自释放** | 2→**实际 1** |
| `rst_n_sync` → `hdmi_clk.RESET` | 1 | `hdmi_clk.v:18` `.RESET(!rst_n)` | 🔴 异步（PLL） | PLLA | 🔴 跨到 pixel/serial | 0 |
| `rst_n_sync` → `OSER10.RESET` | 1 | `tmds_serializer.v:38` `.rst(!rst_n)` | 🔴 异步 | OSER10 ×4 | 🔴 **跨 2 个域** | 0 |
| `lock` → `reset_pipe` | 2 | `hdmi_scope.v:19-22` | 🔴 异步（`negedge rst_n`） | `video_reset_n` | 局部 | **2** |

### 1.3 UART 链（**单域，但三消费者共用一条字节流**）

| 跳 | 位宽 | 寄存/组合 | 差几拍 | 同步级数 | 结论 |
|---|---|---|---|---|---|
| `uart_rx`（D14） → `rx_d1/rx_d2` | 1 | ✅ 寄存 | +1/+2 | **2（无 `async_reg`）** | ⚠️ P1-04 |
| `rx_d2` → `S_IDLE` 起始位判定 | 1 | 组合 | **+2 clk** | — | ✅ 2% 位宽偏移，可接受 |
| `rx_data_o/rx_done_o` | 8+1 | ✅ 寄存 | 0 | 同域 | ✅ |
| → `evt_uart_rx` / `calib_cmd` / `uart_ui` | 8+1 | 三路**各自** FSM | 0 | 同域 | ✅ 位不撕裂，⚠️ 见 P0-03 |
| `tx_req/tx_byte` → `uart_tx_fifo.push_i` | 1+8 | 🔴 **组合**（10 深优先编码器） | 0 | 同域 | ⚠️ P2-04 |
| `txf_start/txf_data` → `uart_tx` | 1+8 | ✅ 寄存 | 0 | 同域 | ✅ |
| `uart_tx.tx_o` → D15 | 1 | ✅ 寄存 | 0 | — | ✅ |

### 1.4 SPI / ADC 链

| 跳 | 位宽 | 寄存/组合 | 差几拍 | 同步级数 | 结论 |
|---|---|---|---|---|---|
| `spi_miso[g]`（N3/N5） | 1×N | → `sync_input` | — | **2（✅ 有 `async_reg`）** | ✅ 干净 |
| `miso_sync[0]` → `mcp3208_driver:114` | 1 | ✅ 寄存 | 0 | 2 | ✅ |
| `miso_sync[g≥1]` → `adc_farm:163` `miso_shift` | 1 | ✅ 寄存 | **+1 clk vs 片 0** | 2 | ⚠️ P2-02 |
| `shadow_hold` → `sample_data_packed` | 12 | 🔴 **组合**（`assign`） | 0 | — | ⚠️ P2-02 |
| `af_data` → `axis_polarity()` → `af0/1_pol` | 12 | 🔴 **组合** | 0 | — | ⚠️ P1-09 |
| `af0/1_pol` → `calib.raw` / `calib_span.raw_i` / `pos_probe.pos_i` | 12 | 🔴 组合 mux + 减法 | 0 | — | ⚠️ P1-09 |
| `cal0_vld/cal0_ch` → `axis_snapshot` | 1+3 | ✅ 寄存 | 0 | — | ✅ |
| `cur[]/prev[]` → `pos_o/delta_o` | 192+208 | 🔴 **组合** | 0 | — | ⚠️ **P1-09** |
| `as_pos` → `event_extract` / `param_extract` / `axis_map` / `vu_*` | 192 | 🔴 组合（16:1 mux ×4 处） | 0 | — | ⚠️ **P1-09** |
| `spi_sclk/spi_mosi/spi_cs_n` → 引脚 | 1+1+6 | ✅ 寄存 | 0 | — | ⚠️ **无输出约束** P1-05 |

### 1.5 WS2812 链

| 跳 | 位宽 | 寄存/组合 | 差几拍 | 结论 |
|---|---|---|---|---|
| `led_indicator.col_c/blk_c` | 24+2 ×7 | 🔴 **组合**（`always @*`） | 0 | ✅ 无锁存（默认先赋值） |
| → `led_col_o` | 168 | ✅ 寄存 | +1 | ✅ |
| → `top.v:5003-5014` `case(ws_wr_addr)` | 24 | 🔴 **组合 8:1 mux** | 0 | ⚠️ P1-08 |
| → `ws2812_driver.mem[]` | 24 | ✅ 寄存 | 0 | ✅ |
| `rd_data` → `rd_grb` → `sh/cur_bit` | 24 | 🔴 组合重排 | 0 | ✅ |
| `dout_o` → `ctrl_ws_o`（C22） | 1 | 🔴 **组合直出引脚** | 0 | ⚠️ **P1-08** |
| `busy_o` → 装载器 | 1 | ✅ 寄存 | 0 | ✅ 帧间隔 ≥300 µs 已守住 |

**撕裂核对（用户点名）**：`top.v:5027` 只在 `WLS_WAIT` 判 `!ws_busy` ⇒ 16 颗灯在 **16 拍内写完**（`WLS_WRITE`），此后才 `ws_start`；
传输期间（476 µs）+ 复位期（400 µs）装载器**不动 `mem[]`** ⇒ ✅ **无撕裂**。
（逐拍追踪确认 `mem[15]` 确实在 `addr==15 && wr_en==1` 那一拍写入，⛔ 不是漏写。）

### 1.6 I2S 链（**两路并存，参数不同**）

| 跳 | 位宽 | 寄存/组合 | 差几拍 | 结论 |
|---|---|---|---|---|
| `tdm_render_mixer.dry_sample_o` | 24 | ✅ 寄存 | 0 | ✅ |
| → `master_mix` → `mm_sample/mm_valid` | 24+1 | ✅ 寄存 | 0 | ✅ |
| → `sample_r`（`if(mm_valid)`） | 24 | ✅ 寄存 | +1 | ✅ |
| → `i2s_tx.sample_l/r` | 24 | ✅ 寄存（`frame_start` 装载） | 帧对齐 | ✅ |
| `HP_BCK/HP_WS/HP_DIN` → 引脚 | 1×3 | ✅ 寄存 | 0 | ✅ 有 `set_output_delay -max 2.0` |
| `I2S2_BCK/LRCK/DIN` → 引脚 | 1×3 | ✅ 寄存 | 0 | ⚠️ **无输出约束**（同一模块、同一时序） |

### 1.7 HDMI 链（**唯一的真跨域链**）

| 跳 | 位宽 | 发射域 | 接收域 | 同步级数 | 约束 | 结论 |
|---|---|---|---|---|---|---|
| `wr_gray`（posedge）→ `gray_launch`（**negedge**） | 10 | clk_sys↑ | clk_sys↓ | 0 | `top.sdc:102` 10.000 ns | 🔴 **P1-01** |
| `history_full` → `full_launch`（negedge） | 1 | clk_sys↑ | clk_sys↓ | 0 | 同上 | 🔴 **P1-01** |
| `gray_launch` → `gray_meta/gray_sync` | 10 | clk_sys↓ | pixel_clk↑ | **2（无 `async_reg`）** | 无 | ⚠️ P1-04 |
| `full_launch` → `full_meta/full_sync` | 1 | clk_sys↓ | pixel_clk↑ | 2 | 无 | ⚠️ P2-07 |
| `lock` → `reset_pipe` | 2 | PLL | pixel_clk↑ | 2 | 无 | ✅ 合理 |
| `video_reset_n` → `video_timing`/`tmds_encoder` | 1 | pixel_clk | pixel_clk | 2 | 无 | ⚠️ 异步复位 P0-02 |
| `pixel_clk` → `OSER10.PCLK` → `serial_clk` FCLK | 10×4 | pixel_clk | serial_clk | 硬宏内 | **无** | 🔴 **P0-04** |
| `OSER10.Q` → `TLVDS_OBUF` → `tmds_*` 引脚 | 1×4 | serial_clk | — | — | **无** | 🔴 **P0-04** |

### 1.8 按键 / 板外异步输入链（**9 个入口，只同步了 3 类**）

| 入口 | 引脚 | 同步器 | `async_reg` | 去抖 | 结论 |
|---|---|---|---|---|---|
| `timbre_btn_i` | AB13 | `top.v:575` `sync_input` ×2 | ✅ | ✅ `debounce` 5 ms | ✅ 干净 |
| `pedal_sus_i` | F18 | `top.v:637` `sync_input` ×2 | ✅ | ✅ `debounce` 5 ms | ✅ 干净 |
| `spi_miso[5:0]` | N3/N5/N7/N9/N13/N15 | `adc_farm.sv:90` ×N | ✅ | — | ✅ 干净 |
| `uart_rx` | D14 | `uart_rx.v:111-119` 手写 ×2 | 🔴 **无** | — | ⚠️ P1-04 |
| `pluck_up_i` / `pluck_down_i` | E21/D21 | `async_pluck_capture.v:36-39` 手写 ×2 | 🔴 **无** | — | ⚠️ P1-03/04 |
| `ctrl_col_i[3:0]` | F15/C20/D20/D19 | 🔴 **无** | — | 🔴 无 | ⚠️ **P1-10** |
| `enc_a_i` / `enc_b_i` / `enc_sw_i` | E19/C19/C18 | 🔴 **无** | — | 🔴 无 | ⚠️ **P1-10** |
| `pedal_loop_rec_i` / `pedal_loop_play_i` | E18/B22 | 🔴 **无** | — | 🔴 无 | ⚠️ **P1-10** |
| `esp_uart_rx_i` | G22 | 🔴 **无** | — | 🔴 无 | ⚠️ **P1-10** |

---

## 二、P0 级（4 条）

### P0-01 · `g_silent` 档 `fault_any_w` **悬空** ⇒ M0 安全态构建的"活体见证"失效

**位置**：`rtl/top.v:1121`（声明）· `rtl/top.v:1719`（**唯一的 `assign`，在 `g_sound` 内**）· `rtl/top.v:4789`（消费）

```verilog
// top.v:1121（模块级声明，generate 之外）
wire       fault_any_w;

// top.v:1719（在 `end else begin : g_sound` 之内 —— 见 top.v:1269）
        assign fault_any_w = (|af_fault) | mx_fault;

// top.v:4786-4790（模块级消费，两个分支都看得到）
    reg fault_sticky;
    always @(posedge clk) begin
        if (!rst_n_sync)         fault_sticky <= 1'b0;
        else if (fault_any_w)    fault_sticky <= 1'b1;   // ⭐ sticky
    end
```

**机制（带数字）**：`top.v` 用 `generate if (DEMO_CHORD_ON == 0) ... g_silent ... else ... g_sound`（`top.v:1235` / `top.v:1269`）产生**两个互斥分支**。
`g_silent` 分支**逐个显式驱动**了 10 根跨分支共享线（`pp_push`/`pp_data`/`scope_sample`/`scope_valid`/`sample_mono`/`tx_req`/`tx_byte`/`led_blink`/`led_beat`/`led_gear_st`/`led_looper_st`，见 `top.v:1239-1268`）——
**唯独漏了 `fault_any_w`**。
⇒ 当 `DEMO_CHORD_ON == 0`（**`tb/top/tb_top_m0.sv` 正是这一档**，见 `top.v:56-58` 的说明）：
- **仿真**：`fault_any_w` = `z` ⇒ `if (fault_any_w)` 为 **X** ⇒ `fault_sticky` 变 **X**
  ⇒ `hb_div_eff = fault_sticky ? (HEARTBEAT_DIV>>3) : HEARTBEAT_DIV`（`top.v:4793`）变 **X**
  ⇒ `hb_cnt >= hb_div_eff - 1`（`top.v:4802`）恒为 **X**（判为假）⇒ 🔴 **`hb` 永不翻转 ⇒ 心跳灯死**
  ⇒ 🔴 **M0"活体见证"（本设计唯一的故障可观测手段，`top.v:5-9` 写明是为此存在的）在静默档上完全失效。**
- **硅片**：综合对"无驱动网线"通常**接 0**（并给一条极易被刷屏淹没的 warning）⇒ `fault_sticky` 恒 0
  ⇒ 🔴 **故障指示永远不亮** ⇒ `adc_farm` SPI 挂 / `tdm_render_mixer` 超时**出了也没人知道**。

**具体改法**（`top.v`，`g_silent` 分支内，与 `tx_req` 同段）：
```verilog
        // top.v 约 :1257 之后，与 `assign led_blink = 1'b0;` 同段
        assign fault_any_w = 1'b0;   // ⭐ 静音档：两个故障源都不存在 ⇒ 明确"无故障"
```

**预期收益/代价**：收益 = M0 档心跳灯恢复确定性、故障指示恢复语义；代价 = **1 行、0 资源**。

**怎么验证能红**：
1. 加一条 tb 断言（或在 `tb/top/tb_top_m0.sv` 内）：`DEMO_CHORD_ON=0` 下，复位释放后
   `assert (!$isunknown(dut.fault_sticky))` 且 **在 `4*HEARTBEAT_DIV` 拍内 `led_heartbeat` 必须翻转 ≥2 次**。
   **未修复**：`fault_sticky` = `x` ⇒ 断言立即红；`led_heartbeat` 恒 `x`/0 ⇒ 超时红。
2. 机械旁证（一行、不可绕过）：`select-string -Path rtl/top.v -Pattern 'assign\s+fault_any_w'` 必须**返回 2 行**（两个分支各 1）。当前**只有 1 行**。

---

### P0-02 · `rst_sync` 的"**同步释放**"承诺在 **10 个模块 / 16 个 `always` 块**上被异步复位端口**整段抵消**

**位置（发射端）**：`rtl/rst_sync.v:39-45`

```verilog
    always @(posedge clk) begin
        // ⚠️ 这里**故意不用 `if (!rst_n_sync)`**：本模块自己就是复位的源头，
        //    用输入直接灌链即可（否则就成了自复位）。
        sync_chain <= {sync_chain[STAGES-2:0], rst_n_async};
    end

    assign rst_n_sync = sync_chain[STAGES-1];
```

**位置（接收端 —— 全部使用 `rst_n_sync` 作【异步】复位）**：

| 文件:行 | 代码片段 |
|---|---|
| `rtl/drivers/debounce.sv:66` | `always @(posedge clk or negedge rst_n) begin` |
| `rtl/drivers/debounce.sv:88,108,127,140,152,157` | 同上（共 **7** 处） |
| `rtl/drivers/calib.sv:175,257,345` | `always @(posedge clk or negedge rst_n) begin`（**2 个实例** ⇒ ×2） |
| `rtl/drivers/adc_farm.sv:218` | `always @(posedge clk or negedge rst_n) begin` |
| `rtl/w3c/looper.v:293,793` | `always @(posedge clk_i or negedge rst_n_i) begin` |
| `rtl/hdmi/hdmi_scope.v:19` | `always @(posedge pixel_clk or negedge rst_n) begin` |
| `rtl/hdmi/video_timing.v:23` | `always @(posedge clk or negedge rst_n) begin` |
| `rtl/hdmi/tmds_encoder.v:56` | `always @(posedge clk or negedge rst_n) begin`（**3 个实例**） |

顶层接线（证明它们拿到的就是 `rst_n_sync`）：
`top.v:592` `.rst_n(rst_n_sync)`（debounce）· `top.v:654` 同 · `top.v:1693` `.rst_n(rst_n_sync)`（adc_farm）·
`top.v:2481/2501` `.rst_n(rst_n_sync)`（calib ×2）· `top.v:3606` `.rst_n_i(rst_n_sync)`（looper）。

**机制（带数字）**：
`rst_n_sync` 由 `rst_sync` 在 **`posedge clk`** 上更新 ⇒ 它的**释放沿与 `clk_sys` 沿严格对齐（仅差 clk-to-Q）**。
把这个信号接进 `negedge rst_n` 端口后，**释放（de-assert）对每个 FF 的异步复位端而言是【异步】的** ⇒
每个 FF 各自在**自己的 recovery/removal 窗**里判定，**可以落在不同的 clk 沿上**：
- 若 `rst_n_sync` 在 `T` 拍上升，FF-A 在 `T+1` 脱离复位、FF-B 因 removal 不足在 `T+2` 才脱离
  ⇒ 🔴 **同一个复位源，各模块释放相差 1~2 拍（20~40 ns）**，正是 `rst_sync.v:8-12` 明文要消灭的现象。
- 项目自己的报告数字：`constr/top.sdc:90` 记录 **`recovery +1.490 ns` / `removal +0.217 ns`**
  ⇒ ⭐ **removal 余量只有 0.217 ns（= 1.1% 个时钟周期）** —— 任何一点布局噪声都能把它吃掉。
- 本次 PnR 的真实 HOLD 余量（`impl/pnr/Gowin2026.timing_paths`）：
  `HOLD +0.137 ns → g_sound.u_looper/ep_mem_ep_mem_0_5_s`（L=3）、`+0.190 ns`、`+0.194 ns`……
  ⇒ **全设计最薄的 25 条余量里有 6 条落在 `u_looper` / `u_note_manager`**，而 `u_looper` 恰好是异步复位模块。

**具体改法（推荐 = 保守、零行为改动，只改复位端）**：
把上述 **16 个** `always @(posedge clk or negedge rst_n)` 统一改成**同步复位**（与本项目 `W3接口冻结表` §〇 约定 2 一致）：
```verilog
// 例：debounce.sv:66
    always @(posedge clk) begin          // ⛔ 去掉 `or negedge rst_n`
        if (!rst_n) begin ... end else begin ... end
```
若因"必须异步置位"而不能改（**只有 `hdmi_scope.v:19` 的 `reset_pipe` 有正当理由**，因为它要同步 `lock`），
则必须走标准写法：**异步置位 + 同步释放的两级同步器**，并且该同步器本身用 `(* async_reg *)` 标注：
```verilog
    (* async_reg = "true" *) reg [1:0] rst_sync_pix;
    always @(posedge pixel_clk or negedge rst_n)     // 断言异步
        if (!rst_n) rst_sync_pix <= 2'b00;
        else        rst_sync_pix <= {rst_sync_pix[0], 1'b1};   // 释放同步
    wire video_reset_n = rst_sync_pix[1];
```
（⛔ **不要**用 `set_false_path` 把 recovery/removal 藏起来 —— `top.sdc:88-90` 已经明文禁止这条路，理由正确。）

**预期收益/代价**：
- 收益：**全设计复位释放沿严格同沿**（`rst_sync` 的设计意图真正落地）；`removal` 从 **+0.217 ns** 变成**普通 setup 路径**（有 18 ns 预算）；
  消除"某次上电某个模块慢一拍"这类**偶发、不可复现**的怪病（用户主诉的那一类）。
- 代价：同步复位**生效晚 1 拍**（20 ns）；`debounce`/`calib` 的复位语义**完全不变**（它们本来就是同步逻辑）；需要重跑全量回归 + 一次 PnR。
- ⚠️ 风险点：`tlc5916_driver` 的 K-66 恢复序列**依赖复位后的固定相位**，`debounce`/`calib` 不涉及，故**无连带**。

**怎么验证能红**：
新增 「tb/cdc/tb_reset_release_order.sv」（历史计划路径，当前未提供）（或加进 `tb/top/tb_top_m0.sv`）：
1. 用 `rand` 让 `rst_n` 的释放沿**相对 `clk_sys` 随机偏移 0..19 ns**（跑 200 个种子）；
2. 释放后第 3 拍，断言**下列模块的所有状态 FF 全部处于复位初值**（用 `$isunknown` + 初值比对）：
   `u_timbre_btn_debounce.key_level` · `u_pedal_sus_debounce.key_level` · `g_sound.u_calib0.zero_r` ·
   `g_sound.u_calib1.zero_r` · `g_sound.u_looper.state` · `g_sound.u_adc_farm.fault_r`；
3. **未修复**：在某个种子下这些 FF 的"脱离复位拍号"**不相等** ⇒ 断言红。
   **已修复**：200 个种子下全部相等 ⇒ 绿。
> 📌 这条判据**必须跑多相位**，单相位跑一次是抓不到的（这正是本缺陷能活到今天的原因）。

---

### P0-03 · `SCORE_UART_ENABLE` 默认 **1** 把一条**已被仿真证明**的伪事件注入路径打开 ⇒ 永久挂音

**位置**：`rtl/top.v:3495`（默认值）· `rtl/top.v:3472-3494`（自述风险）· `rtl/top.v:3725`（接线）· `rtl/w3c/evt_uart_rx.v:175-187`（帧头判定）

```verilog
// top.v:3495
        localparam integer SCORE_UART_ENABLE = 1;

// top.v:3725-3729
            .score_valid_i    (SCORE_UART_ENABLE ? eu_evt_valid : 1'b0),
            .score_axis_i     (SCORE_UART_ENABLE ? score_evt_axis : 4'd0),
            .score_phase_inc_i(SCORE_UART_ENABLE ? score_evt_inc  : 32'd0),
            .score_velocity_i (SCORE_UART_ENABLE ? score_evt_vel  : 8'd0),
            .score_kind_i     (SCORE_UART_ENABLE ? score_evt_kind : 2'd0),
```
```verilog
// evt_uart_rx.v:175-187 —— 只在 idx==0 位置看帧头（本模块自己的安全设计）
                if (idx_q == 4'd0) begin
                    // ---- ⭐ 只在【第 0 字节位置】看帧头（⛔ 不扫描）----------
                    if (byte_is_a5) begin
                        idx_q    <= 4'd1;
                        all_a5_q <= 1'b1;      // ⭐ 帧头是 0xA5 ⇒ 起始为真
```

**机制（带数字）**：
`top.v:829-837` 与 `top.v:3693-3694` 都写明：**同一个 `uart_rx` 的 `ur_done`/`ur_data` 被三路共用**
（`uart_ui` 串口屏 · `calib_cmd` 命令 · `evt_uart_rx` 曲谱事件），**三路各自维护帧边界**。
`evt_uart_rx` 的帧头是 `0xA5`，帧长 **9 字节**；只要**任意**另一路的合法载荷里出现 `0xA5`，且它恰好落在 `evt_uart_rx` 的 `idx_q == 0`，
就会被当成帧头 ⇒ **注入一条 64 bit 伪事件**。
`top.v:3699-3701` 记录了**实测**：喂 **8 个**串口屏数值帧（数据含 `0xA5`）⇒ **产生 8 条伪事件**，
其中 `axis = 15` · `inc = 0x1FFFFF` · `kind = 0`（note_on）。
致命之处在 `top.v:3703-3707`：伪事件带 **`score` 源**，而 `note_manager` 的 `note_off` 按 **`(axis, src)` 双条件**匹配
⇒ **手弹（`live`）的 `note_off` 永远清不掉这条 `score` voice** ⇒ 🔴 **`gate_r` 永久为 1**。
用户实测症状（`top.v:3710-3711` 原文）：**「按同键不能清」「按所有键也不能清」「持续几分钟」「断电才清」「~50% 概率」「按一阵后累积」**。
🔴 **关键退化**：`top.v:3480-3489` 记载，2026-09-28 曾把本参数**默认置 0 作为缓解**，
2026-09-30 为了"曲谱与 looper 同时可用"**又把默认改回 1** ⇒ **那道缓解被撤掉了**，而注入通路**未被修**（`top.v:3490-3494` 自认"遗留风险…理论通路仍然存在"）。

**具体改法（按性价比排序）**：
1. ⭐ **零成本、立即止血**：把 `top.v:3495` 改回 `localparam integer SCORE_UART_ENABLE = 0;`
   （`top.v:3486-3489` 已证明 `= 0` **只关曲谱 UART，looper 照常可用** ⇒ 不牺牲任何已交付功能）。
2. ⭐ **结构性修法（真正闭环）**：给曲谱一条**独立 UART 引脚**。引脚申请单已留了 `esp_uart_rx_i`（G22），
   但 `top.v:499` 注释说它"← ESP32 的 TX"⇒ 应把曲谱改走 **`esp_uart_rx_i` + 它自己的 `uart_rx` 实例**，
   与 `uart_ui`/`calib_cmd` **物理分线** ⇒ 注入在原理上不可能。
3. ⭐ **协议加固（若必须共用一条线）**：`evt_uart_rx` 增加**帧尾校验**（如第 9 字节 = 前 8 字节的 XOR），
   校验不过 ⇒ `hdr_err_cnt_o++` 且**不产生事件**。伪事件概率从"载荷含 0xA5"降到 2⁻⁸。

**预期收益/代价**：
- 方案 1：收益 = 消除用户主诉的头号"偶发怪病"；代价 = **曲谱 UART 关闭**（looper/手弹/鼓机/节拍器全不受影响），**1 行**。
- 方案 2：收益 = 曲谱与串口屏**真并存**且零注入；代价 = 1 个 `uart_rx` 实例（~120 FF）+ `.cst` 1 行 + ESP32 侧分线。
- 方案 3：收益 = 保留共用线；代价 = 上位机 `tools/evt2uart.py` 必须同步加校验字节（⚠️ 协议变更）。

**怎么验证能红**：
`tb/w3c/tb_evt_uart_rx_screen.sv` **已存在**且已能复现（`top.v:3494` 指向它）。把它的判据改成硬断言：
```systemverilog
// 注入 8 个含 0xA5 的屏幕数值帧后：
assert (u_evt_uart_rx.frame_cnt_o == 0)   // 未修复 ⇒ == 8 ⇒ 红
assert (u_evt_uart_rx.hdr_err_cnt_o >= 8) // 未修复 ⇒ == 0 ⇒ 红（说明 0xA5 被当成了帧头）
```
再加一条端到端判据（`tb/e2e/tb_e2e_key_to_sound.sv` 家族）：
注入伪事件后发同轴的 `live` `note_off`，断言 `u_note_manager.gate_r` 对应位**归 0**。
**未修复**：恒 1 ⇒ 红（这就是"挂音"的机器判据）。

---

### P0-04 · **125 MHz `serial_clk` 域零时序验证** —— "0 违例"对 TMDS 串行化是**空真**

**位置**：`constr/top.sdc:74-76`（生成时钟）· `sim/evidence/final-batch-20261008/timing.txt:64-79`（Fmax 汇总）· `rtl/hdmi/tmds_serializer.v:21-33`

```tcl
# top.sdc:74-76
# H5: same PLL divisors as verified 640x480 bringup; CDC remains timed.
create_generated_clock -name serial_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 8 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 40 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT1}]
```
```verilog
// tmds_serializer.v:21-28
    generate for (j=0; j<4; j=j+1) begin : lanes
        OSER10 u_oser (
            .Q(serial[j]), .D0(lane[j][0]), ... .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst)
        );
```

**机制（带数字）**：`timing.txt` 的 **Max Frequency Summary 只有 1 行**：

| NO. | Clock | Constraint | Actual Fmax | Logic Level | Entity |
|---|---|---|---|---|---|
| 1 | `clk_sys` | 50.000 MHz | **55.060 MHz** | **10** | TOP |

⇒ 🔴 **`serial_clk`（8.000 ns / 125 MHz）与 `pixel_clk`（40.000 ns / 25 MHz）在 Clock Summary 里存在（`timing.txt:44-63`），
但 Fmax 汇总里【一条都没有】** ⇒ **没有任何数据路径的时序是被"以 125 MHz 为目标"验证过的**。
原因：`OSER10` 是**硬宏**，`PCLK → FCLK` 的 10:1 搬运发生在宏内部，STA 看不见（`top.sdc:89` 的注释也承认这一点）。
⇒ 本项目自己的证据文件 `bringup/hdmi_640x480/evidence-h4/RESULT.md:53` 原文：
> *"报告的 setup/hold 违例端点各 0、TNS 各 0 ns；但 **serial Actual Fmax 不可得**，0 违例不等于验证通过 768.75 MHz 的串行化器。"*
而当前配置 `ODIV0_SEL=8`（`hdmi_clk.v:33`）⇒ `50×20/8 = 125 MHz` FCLK，每 lane **10×25 = 250 Mb/s**。
⚠️ 同时 `top.sdc:88-90` **刻意不用** `set_clock_groups -asynchronous`（理由正确：会删掉 OSER10 RESET 的真实 recovery/removal）
⇒ 于是这个域既**没有 Fmax**、**也没有被显式豁免**，处于"**约束真空**"。

**具体改法**：
1. ⭐ **把不可测变成可测（首选）**：在 `tmds_serializer` 的 OSER10 **前后各插一级可测寄存器**做"影子通路"，
   仅用于 STA（用 `(* syn_keep *)` + `dont_touch`，不接输出）：
   ```verilog
   (* syn_keep = "true", dont_touch = "true" *) reg [9:0] lane_shadow [0:3];
   always @(posedge pixel_clk) lane_shadow[0] <= blue;   // PCLK 侧影子
   ```
   ⇒ 让工具至少能报 `pixel_clk` 的 Fmax，并把 `serial_clk` 的存在显式化。
2. ⭐ **显式记录"serial 域不可 STA"这件事**：在 `top.sdc` 里加**带理由的注释 + 一条 `set_false_path`**（写明"OSER10 内部，宏外不可分析"），
   ⛔ 不要留成"没写"（没写 = 没人知道是漏了还是故意的）。
3. ⭐ **上板闭环**（唯一真判据）：用示波器/眼图量 `tmds_clk_p` 的 125 MHz 与 `tmds_d_p_0` 的 250 Mb/s 眼宽，
   记录到 `evidence/h5/`。**这是本项唯一能"红"的方式。**

**预期收益/代价**：收益 = 把"H5 显示通路"从"看起来全绿"变成"有明确验证边界"；代价 = 方案 1 多 ~40 FF、方案 2 零成本、方案 3 需要仪器。

**怎么验证能红**：
```powershell
# 机械判据：Fmax 汇总必须覆盖所有 create_generated_clock 的时钟
$fmax = (Get-Content sim/evidence/*/timing.txt | Select-String 'Actual Fmax').Count
$gen  = (Get-Content constr/top.sdc | Select-String 'create_generated_clock').Count
# 当前：$fmax = 1, $gen = 2  ⇒ 红
```
⇒ 该脚本必须在 `sim/gowin_build.ps1` 的验收里**硬失败**（⛔ 现在是"人看报告"，没有机械门）。

---

## 三、P1 级（10 条）

### P1-01 · `waveform_scope` 的**负沿半周期 hack**：10 ns 预算挂在**综合后网名**上，网名一变约束**静默失配**

**位置**：`rtl/hdmi/waveform_scope.v:34-43`（负沿发射）· `constr/top.sdc:101-102`（约束）

```verilog
// waveform_scope.v:34-43
    // The PLL pixel rising edge coincides with a source rising edge. Launch
    // the CDC bundle on the source falling edge to provide a real 10 ns
    // setup/hold separation instead of relying on a false-path exception.
    reg [9:0] gray_launch;
    reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
```
```tcl
# top.sdc:101-102
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```

**机制（带数字）**：
- `sample_clk = clk_sys = 50 MHz` ⇒ 一个周期 **20 ns**，正沿到负沿 **10 ns**。
  `gray_launch`/`full_launch` 在**负沿**发射，接收侧 `gray_meta/full_meta` 在 `pixel_clk`（25 MHz，40 ns）正沿采样
  ⇒ 作者用它把"同沿发射"改成"错开半个周期"，得到 **10 ns** 的发射侧预算。
- 🔴 **风险 1（致命）**：`top.sdc:102` 的目标用的是 **`gray_launch_*_s0` / `full_launch_s0`**
  —— 这是 **Gowin 综合后加的 `_s0` 后缀网名**，**不是 RTL 名**。
  综合若把它们改成 `_s1`、合并进 `_s83`、或把 10 位打散重命名（本设计里 `_s0/_s1/_s83` 三种后缀都真实出现过，
  见 `Gowin2026.timing_paths` 的 `rot_phase_20_s83` / `phase_r[31]_9_s1`），
  ⇒ `get_regs {...}` **匹配到空集** ⇒ `set_max_delay 10.000` **不生效**
  ⇒ 该路径回落到 `top.sdc:101` 的 **18.181 ns**（**更松**）⇒ 🔴 **唯一的跨域时序检查被静默删除**。
  ⚠️ 而 SDC 自己的验收要求（`top.sdc:97`）"Constraints Report 全部 Actived 且对象非空"是**人工**步骤，**没有任何 CI 门**。
- 🔴 **风险 2**：`always @(negedge sample_clk)` 是**全设计唯一的负沿寄存器**（`grep -r "always @(negedge" rtl/` ⇒ **1 处**）。
  在 Gowin 的 CLS 里，FF 的时钟极性需要**在时钟网上插反相器**（或走专用资源）⇒ 引入 **额外的时钟插入延迟/偏斜**，
  而 **10 ns 的预算假设偏斜为 0**。若偏斜 1.5 ns ⇒ 真实预算只剩 **8.5 ns**。
- 🔴 **风险 3**：`top.sdc` 里**没有** `create_generated_clock` 或 `set_clock_groups` 描述这个负沿域，
  `set_max_delay -from clk_sys -to clk_sys` 是否把"负沿发射"算成半周期，**取决于工具**；作者靠"显式钉 10 ns"绕过，
  但这等于**放弃了工具自己的边沿推导**。

**具体改法（推荐 = 彻底去掉负沿）**：
```verilog
// waveform_scope.v —— 改回正沿，用"两级 + 灰码 + 独立约束"换取确定性
    (* async_reg = "true" *) reg [9:0] gray_launch;
    (* async_reg = "true" *) reg       full_launch;
    always @(posedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 10'd0; full_launch <= 1'b0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
```
并把约束改成**按 RTL 名 + 交叉时钟对**（⛔ 不用综合后网名）：
```tcl
# 正沿发射 ⇒ 用 create_clock 的边沿关系，不用手工 10 ns
set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {pixel_clk}] 20.000
set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {serial_clk}] 8.000
set_false_path -hold -from [get_clocks {clk_sys}] -to [get_clocks {pixel_clk}]
```
（`-datapath_only` 让工具只约束数据路径，避免把时钟偏斜算进去；灰码保证单比特变化 ⇒ 不需要 hold 约束。）

**预期收益/代价**：
- 收益：**跨域约束不再依赖综合后网名**（不会静默失配）；去掉负沿寄存器 ⇒ 少一个时钟反相资源、少一份偏斜；
  约束从"手工 10 ns"变成"工具可推导的时钟对关系"。
- 代价：回到正沿后发射侧预算从 10 ns 变回 20 ns 的**同沿**关系 ⇒ 需要 `-datapath_only` + 灰码配合；
  **必须重跑一次 PnR 确认 `pixel_clk` 侧没有新的 setup 违例**（预计无，因为该路径逻辑极浅：`wr_gray` 是寄存器，到 `gray_launch` 只有布线）。

**怎么验证能红**：
```powershell
# ① 约束对象非空（机械、可进 CI）
Select-String -Path impl/pnr/Gowin2026_tr_content.html -Pattern 'gray_launch_|full_launch_' -SimpleMatch
# 未修复：若综合改名，这里【一个都搜不到】⇒ 红
# ② 负沿寄存器数量必须为 0（修复后）
(Select-String -Path rtl/hdmi/waveform_scope.v -Pattern 'always\s*@\s*\(\s*negedge').Count   # 期望 0
```
③ 时序：`tb/hdmi` 家族里加一条**跨域一致性**断言 —— 在 `pixel_clk` 侧解码 `gray_sync` 得到的二进制指针，
**永远不得跳过**（单调、步长 ≤1）；把 `sample_clk` 相位随机化 200 次，**未修复**时会在某个相位抓到"跳 2"⇒ 红。

---

### P1-02 · HDMI 域复位：**异步复位由 `clk_sys` 同步信号驱动**，且 `OSER10.RESET` **跨两个域**

**位置**：`rtl/hdmi/hdmi_scope.v:9-22` · `rtl/hdmi/hdmi_scope.v:37-38` · `rtl/hdmi/hdmi_clk.v:18`

```verilog
// hdmi_scope.v:9-22
    wire pixel_clk, serial_clk, lock;
    reg [1:0] reset_pipe;
    wire video_reset_n = reset_pipe[1];
    ...
    hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[0], lock};
    end
```
```verilog
// hdmi_scope.v:37-38
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!rst_n), .blue(blue), .green(green), .red(red),
```
```verilog
// hdmi_clk.v:17-18
    PLLA u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
```

**机制（带数字）**：
顶层把 **`rst_n_sync`**（`clk_sys` 域的寄存器输出）接到 `u_hdmi.rst_n`（`top.v:1228` `.rst_n(rst_n_sync)`）。
于是：
1. `hdmi_scope.v:19` 用它作 **`pixel_clk` 域的异步复位** ⇒ 释放沿与 `pixel_clk` **无固定关系**
   ⇒ `reset_pipe[0]`/`reset_pipe[1]` 可能**不在同一拍释放** ⇒ `video_reset_n` 出现 **1 拍的中间态**
   ⇒ `video_timing` / 3 个 `tmds_encoder` 可能**差一拍脱离复位**（与 P0-02 同族，但在跨域场景下更危险）。
2. `hdmi_scope.v:38` 把 **`!rst_n`（= `!rst_n_sync`）** 直接送 `OSER10.RESET`
   ⇒ 该复位被 **`PCLK`(25 MHz) 与 `FCLK`(125 MHz) 两个时钟同时采样** ⇒ **跨 2 个域的异步复位**。
   项目自己量过：**recovery +1.490 ns / removal +0.217 ns**（`top.sdc:90`、`files/20-代码/H5显示修复与时序拉锯-记录与方向-20261002.md:695`）
   ⇒ 🔴 **removal 只有 0.217 ns（0.217/8 = 2.7% 个 125 MHz 周期）**。
3. `hdmi_clk.v:18` 用 `!rst_n` 复位 **PLL**。`rst_n_sync` 一旦被按下（按键）⇒ **PLL 停机 ⇒ `pixel_clk`/`serial_clk` 直接消失**
   ⇒ 此时 `OSER10` 的 `RESET` 也被断言，**顺序不可控**（PLL 停止与 OSER10 复位谁先谁后取决于布线）
   ⇒ 上电/复位窗口里 TMDS 输出**未定义序列**（`ANVIL-12` 的 P1-01 已指出同一问题）。

**具体改法**：
```verilog
// hdmi_scope.v —— ① pixel 域复位改成"异步断言 + 同步释放"，且由 lock 门控
    (* async_reg = "true" *) reg [2:0] reset_pipe;
    always @(posedge pixel_clk or negedge rst_n)
        if (!rst_n)        reset_pipe <= 3'b000;
        else               reset_pipe <= {reset_pipe[1:0], lock};   // 3 级：lock 也是异步源
    wire video_reset_n = reset_pipe[2];
    wire serial_reset_n = reset_pipe[2];        // ⭐ serial 域用同一个"已同步到 pixel 域"的释放沿
```
```verilog
// hdmi_scope.v:37-38 —— ② OSER10 的 RESET 改由已同步的复位驱动（⛔ 不再用裸 rst_n）
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!video_reset_n), .blue(blue), .green(green), .red(red),
```
```verilog
// hdmi_clk.v:18 —— ③ PLL 复位保持由 clk_sys 域驱动（正确），但必须在 .cst 里给 CLKIN 的 PLL 加 lock 上拉/时序
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
```
⚠️ **不要**为了消警告加 `set_clock_groups -asynchronous` —— `top.sdc:88-90` 已论证那会把真实检查一起删掉。

**预期收益/代价**：收益 = `removal` 从 **+0.217 ns** 变成**同域同步路径**（40 ns 预算）；消除 PLL 未锁期间 OSER10 输出未定义序列；
代价 = 复位释放**晚 3 个 `pixel_clk`（120 ns）**，对视频完全无影响；**必须重跑全量回归**（`tb/models/hdmi_primitives_model.sv:36` 的 OSER10 模型认 RESET 极性）。

**怎么验证能红**：
`tb/hdmi` 里加：随机化 `rst_n` 释放相位（0..19 ns，200 种子），断言
`u_hdmi.reset_pipe` 的 3 位**在同一拍**变为全 1，且 `u_serializer.lanes[0].u_oser.RESET` 的释放沿
**落在 `video_reset_n` 释放之后 ≥1 个 `pixel_clk`**。
**未修复**：会在某个相位抓到"`reset_pipe[0]` 先脱离、`[1]` 后脱离"⇒ 红。

---

### P1-03 · `async_pluck_capture` 的"**同时跳变时确定 UP**"是**假的** —— 实际是"谁先解除亚稳态谁赢"

**位置**：`rtl/w3a/async_pluck_capture.v:1-4`（声明）· `:17`（寄存器）· `:36-49`（逻辑）

```verilog
// async_pluck_capture.v:1-4
// T15: LM393 UP/DOWN asynchronous outputs -> one synchronous pluck event.
// The first synchronized edge is accepted immediately; the refractory period
// only rejects later edges.  A simultaneous UP/DOWN edge is deterministically UP.
```
```verilog
// async_pluck_capture.v:17-22, 36-49
    reg up_ff1, up_ff2, down_ff1, down_ff2;
    reg up_prev, down_prev;
    reg [31:0] refractory_q;

    wire up_rise   = up_ff2   && !up_prev;
    wire down_rise = down_ff2 && !down_prev;
    ...
            up_ff1    <= pluck_up_async_i;
            up_ff2    <= up_ff1;
            down_ff1  <= pluck_down_async_i;
            down_ff2  <= down_ff1;
            up_prev   <= up_ff2;
            down_prev <= down_ff2;

            pluck_valid_o <= 1'b0;
            if (refractory_q != 32'd0) begin
                refractory_q <= refractory_q - 32'd1;
            end else if (up_rise || down_rise) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= up_rise; // UP wins if both edges are present.
                refractory_q  <= REFRACT_CYC;
            end
```

**机制（带数字）**：
`up_ff1/up_ff2` 与 `down_ff1/down_ff2` 是**两条完全独立的 2 级同步链**（`async_pluck_capture.v:36-39`）。
当 UP 与 DOWN 在**同一个 `clk_sys` 沿附近**跳变（LM393 比较器开漏上拉，两路可以同时翻转），
两级 FF 的**亚稳态解除时间服从指数分布**，两路**互不相关** ⇒
- 若 `up_ff2` 先变 1（第 N 拍）：`up_rise=1` ⇒ `pluck_up_o <= 1`，且 `refractory_q <= 1_500_000`。
- 若 `down_ff2` 晚 1 拍变 1（第 N+1 拍）：`refractory_q != 0` ⇒ **`else if (up_rise || down_rise)` 分支根本不执行**
  ⇒ 🔴 **DOWN 事件被【静默丢弃】**。
⇒ 结果**不是**"确定 UP"，而是"**先解除亚稳态的那一路赢，另一路被吃**"。
🔴 **实际后果**：用户同时拨动/摇杆回弹瞬间两路都动时，**拨弦方向随机**（这一次 UP、下一次 DOWN）。
`REFRACT_CYC = 1_500_000`（`top.v:3202`）= **30 ms**，意味着一旦判错，**30 ms 内不再接受任何修正**。

**具体改法**（保持"UP 优先"语义，但让它**确定**）：
```verilog
// async_pluck_capture.v —— 先合并成"任一路有上升沿"，再用【同拍可见】的组合优先
    (* async_reg = "true" *) reg [1:0] up_sync, down_sync;   // 见 P1-04
    reg [1:0] up_prev2, down_prev2;
    wire up_rise_c   = up_sync[1]   && !up_prev2[1];
    wire down_rise_c = down_sync[1] && !down_prev2[1];
    // ⭐ UP 优先：同拍时 up 赢；不同拍时【已接受的上升沿】记一个"待定方向"，
    //    在下一拍再定，避免"晚一拍的那路被 refractory 吃掉"
    reg pending_dir_q, pending_en_q;
    always @(posedge clk_i) begin
        ...
        if (!pending_en_q) begin
            if (up_rise_c) begin
                // 等 1 拍看 down 是否同拍/邻拍到达 ⇒ 只有真的"同时"才需要等
                pending_en_q <= 1'b1; pending_dir_q <= 1'b1;
            end else if (down_rise_c) begin
                pending_en_q <= 1'b1; pending_dir_q <= 1'b0;
            end
        end else begin
            pending_en_q <= 1'b0;
            if (refractory_q == 32'd0) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= pending_dir_q | down_rise_c;   // ⭐ UP 永远优先
                refractory_q  <= REFRACT_CYC;
            end
        end
    end
```
（核心：**把"方向判定"与"不应期开闸"解耦** —— 先记录两路是否都来了，再统一决定方向。⛔ 不要在 `refractory` 分支里吞事件。）

**预期收益/代价**：收益 = 拨弦方向**确定**（UP 恒优先）；代价 = 首次拨弦**晚 1 拍（20 ns）** —— 对 30 ms 不应期完全无感；
多 2 个 FF。⚠️ 必须同步更新 `top.v:3200-3202` 的注释（它现在写着"此处只兜住摇杆回弹，不延迟首次拨弦"）。

**怎么验证能红**：
`tb/w3a/tb_async_pluck_capture.sv`（若无则新建）：对 `up`/`down` 施加**相对偏移 0/1/2 拍**的成对上升沿，
每个偏移跑 100 个随机相位种子，断言 **`pluck_up_o === 1'b1` 恒成立**。
**未修复**：偏移 1 拍时，约 50% 的种子 `pluck_up_o == 0`（DOWN 先解除）⇒ **红**。
另加一条：断言 `pluck_valid_o` 的脉冲数 == 注入的成对事件数（**未修复时 DOWN 被吞 ⇒ 少脉冲**）。

---

### P1-04 · **4 个手写同步器缺 `(* async_reg = "true" *)`** —— 项目纪律只覆盖了 2 个模块

**位置（有标注的，仅 2 处）**：`rtl/rst_sync.v:37` · `rtl/sync_input.v:42`
```verilog
// rst_sync.v:37
    (* async_reg = "true" *) reg [STAGES-1:0] sync_chain;
// sync_input.v:42
    (* async_reg = "true" *) reg [W-1:0] chain [0:STAGES-1];
```

**位置（缺标注的，4 处 / 20 个 FF）**：
```verilog
// rtl/w3c/uart_rx.v:107  —— 2 FF
    reg         rx_d1, rx_d2;       // ⭐ 两级同步打拍

// rtl/w3a/async_pluck_capture.v:17  —— 4 FF
    reg up_ff1, up_ff2, down_ff1, down_ff2;

// rtl/hdmi/waveform_scope.v:47-48  —— 22 FF
    reg [9:0] gray_meta, gray_sync;
    reg full_meta, full_sync;

// rtl/hdmi/hdmi_scope.v:10  —— 2 FF
    reg [1:0] reset_pipe;
```
**机械判据（一行）**：
```powershell
(Select-String -Path rtl/**/*.v,rtl/**/*.sv -Pattern 'async_reg').Count   # 当前 = 2
(Select-String -Path rtl -Recurse -Pattern '<= *\w*(_async|_i|_d1)' ...)  # 手写同步器 ≥ 4 处
```

**机制（带数字）**：
`(* async_reg = "true" *)` 在 Gowin/Synplify 里的作用是**禁止对这两级做重定时（retiming）、合并、以及把两级塞进同一 CLB 共享时钟**。
没有它：
- 综合器可以把 `rx_d1`/`rx_d2` 重定时合并（因为逻辑上 `rx_d2` 只是 `rx_i` 的两拍延迟）
  ⇒ 🔴 **2 级同步器退化成 1 级** ⇒ 亚稳态 MTBF 从 `e^(t_r/τ)` 的**平方级**掉回**线性级**。
  τ 与 `t_r` 依工艺而定，**保守估计 MTBF 掉 3~6 个数量级**（从"万年一遇"掉到"几天一遇"）。
- `waveform_scope.v:47-48` 的 `gray_meta`/`gray_sync` 是 **10 位总线**：两级若被塞进同一 CLB，
  10 位的**位间偏斜**在同一个时钟沿上不可控 ⇒ 灰码"单比特变化"的前提被破坏。
⚠️ 而本项目**自己**的纪律（`rtl/drivers/debounce.sv:9-12`）明文写着 K-62 要求所有板外异步输入走 `sync_input`：
> *"本模块在端口层面不例化 `sync_input`…由顶层负责同步（与 K-62「**仍待做：把 SPI/按键输入实际接上 `sync_input`**」一致）"*
⇒ 🔴 **K-62 至今是"待做"，而不是"已做"** —— 这条纪律在文档里存在、在代码里只落实了 3 处。

**具体改法（4 处各 1 行）**：
```verilog
// uart_rx.v:107
    (* async_reg = "true" *) reg rx_d1, rx_d2;
// async_pluck_capture.v:17
    (* async_reg = "true" *) reg up_ff1, up_ff2, down_ff1, down_ff2;
// waveform_scope.v:47-48
    (* async_reg = "true" *) reg [9:0] gray_meta, gray_sync;
    (* async_reg = "true" *) reg full_meta, full_sync;
// hdmi_scope.v:10
    (* async_reg = "true" *) reg [1:0] reset_pipe;
```
⭐ **更彻底的做法**：把 `uart_rx.v:111-119`、`async_pluck_capture.v:36-39`、`waveform_scope.v:55-62`、`hdmi_scope.v:19-22`
**全部改成例化 `sync_input`**（它已有 `async_reg` + 参数化级数 + `RESET_VAL`），
⇒ 一处标注、全设计受益，且**下次新增同步器不会漏**。

**预期收益/代价**：收益 = 同步器**结构上不可能被优化掉**；MTBF 回到设计意图；灰码总线位间偏斜可控。
代价 = **4 行属性（或 4 处例化替换）**、0 资源变化；⚠️ 替换成 `sync_input` 时要**逐位**（`W=1`）以免引入 P1-10 的多比特问题。

**怎么验证能红**：
1. **静态（进 CI）**：脚本扫描 `rtl/`，凡出现"两级同名前缀 FF 且第二级由第一级驱动、第一级由 `_i`/`_async` 驱动"的模式，
   必须**同时**在同一行或紧邻上一行出现 `async_reg`。当前会报 **4 处违规**。
2. **动态**：跑 Gowin 综合，检查综合后网表里同步器是否仍是 **2 个独立 FF**（用 `impl/gwsynthesis/Gowin2026_syn.rpt.html` 的寄存器列表）。
   **未修复**：可能在某个综合设置（`-retiming`）下变成 1 个 FF ⇒ 红。

---

### P1-05 · SDC 只约束了 **5 / 25** 个 I/O 端口 —— **11 个异步输入没有输入延时、7 类输出没有输出延时**

**位置**：`constr/top.sdc:62-71`（全部 I/O 约束，共 5 条）

```tcl
# top.sdc:62-71 —— 这就是全部 I/O 约束
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]
set_false_path -from [get_ports {rst_n}]
```

**未约束的输出端口（`top.v:349-501` 的真实端口列表）**：

| 端口 | 引脚 | 位时序要求 | 当前约束 |
|---|---|---|---|
| `ctrl_ws_o` | C22 | **WS2812 800 kHz**：T0H 350 ns ±150 · T1H 700 ns ±150 · T 1250 ns ±600 | 🔴 **无** |
| `spi_sclk` / `spi_mosi` / `spi_cs_n[5:0]` | E14/E13/N4… | **1 MHz**（500 ns 半周期），MCP3208 tSU/tHD ~10 ns | 🔴 **无** |
| `led_sdi` / `led_clk` / `led_le` / `led_oe_n[4:0]` | B21/B18/A21/… | **1 MHz**（TLC5916 tSU 8.5 ns / tHD 10 ns） | 🔴 **无** |
| `I2S2_BCK` / `I2S2_LRCK` / `I2S2_DIN` | F20/E22/D22 | 与 `HP_*` **完全相同**（同一 `i2s_tx` 参数） | 🔴 **无**（只有板载那路有） |
| `uart_tx` / `esp_uart_tx_o` | D15/G21 | 500 kbps / 2 µs 位宽 | 🔴 **无** |
| `tmds_d_p_0[2:0]` / `tmds_clk_p_0` | J14… | **250 Mb/s/lane** | 🔴 **无** |
| `ctrl_row_o` / `ws_strip_o` | D16… | 直流（常量） | ✅ 不需要 |

**未约束的输入端口（全部是板外异步）**：

| 端口 | 引脚 | 同步器 | `set_input_delay` |
|---|---|---|---|
| `uart_rx` | D14 | `uart_rx.v:111` 手写 2FF | 🔴 无 |
| `spi_miso[5:0]` | N3/N5/N7/N9/N13/N15 | `adc_farm.sv:90` `sync_input` ×2 | 🔴 无 |
| `timbre_btn_i` | AB13 | `top.v:575` `sync_input` ×2 | 🔴 无 |
| `pedal_sus_i` | F18 | `top.v:637` `sync_input` ×2 | 🔴 无 |
| `pluck_up_i` / `pluck_down_i` | E21/D21 | `async_pluck_capture.v:36` 手写 2FF | 🔴 无 |
| `ctrl_col_i[3:0]` / `enc_a_i` / `enc_b_i` / `enc_sw_i` / `pedal_loop_rec_i` / `pedal_loop_play_i` / `esp_uart_rx_i` | F15…G22 | 🔴 **无** | 🔴 无 |

**机制（带数字）**：
`top.sdc:23-28` 自己写明：
> *"它只约束**寄存器→寄存器**的路径。**进出引脚的路径**…在没有 `set_output_delay`/`set_input_delay` 时**不被分析**"*
⇒ 对**同步器**而言，"不被分析"意味着 **`port → chain[0]` 的建立时间没有预算**。
亚稳态 MTBF ∝ `e^(t_r/τ)`，其中 `t_r = T_clk − t_su − t_route`。
**没有约束 ⇒ 工具不会去缩短 `t_route`** ⇒ 若综合/布局把 `chain[0]` 放得离引脚很远（AC1/I0 慢档，20 ns 周期下 route 可达 5~8 ns），
`t_r` 被吃掉 25~40% ⇒ **MTBF 掉好几个数量级**。
对**输出**而言：`ctrl_ws_o` 的 T0H=**17 clk = 340 ns** / T1H=**35 clk = 700 ns**（`ws2812_driver.v:59-61`）
是**寄存输出**，但 `dout_o` 是 **`assign`（组合）**（见 P1-08）⇒ 其边沿位置 = FF clk-to-Q + **未约束的布线延迟**。
WS2812 的容限是 **±150 ns**，看起来很宽，但 `led_sdi/led_clk` 的 TLC5916 **tSU 只有 8.5 ns**（`tlc5916_driver.sv:117` 注释）
⇒ 一个未约束的 10 ns 布线差就能**吃掉全部建立余量**。

**具体改法**（`constr/top.sdc` 追加；数值取"外部器件要求"，⛔ 不要用 `false_path` 图省事）：
```tcl
# ── WS2812（800 kHz，容限 ±150 ns；给 50 ns 预算足够，⛔ 不设 false_path）
set_output_delay -clock clk_sys -max 50.0 [get_ports {ctrl_ws_o}]
set_output_delay -clock clk_sys -min -50.0 [get_ports {ctrl_ws_o}]
# ── SPI（1 MHz，MCP3208 tSU/tHD ≈ 10 ns；给 40 ns）
set_output_delay -clock clk_sys -max 40.0 [get_ports {spi_sclk spi_mosi}]
set_output_delay -clock clk_sys -max 40.0 [get_ports {spi_cs_n[*]}]
# ── TLC5916（1 MHz，tSU 8.5 ns / tHD 10 ns）
set_output_delay -clock clk_sys -max 40.0 [get_ports {led_sdi led_clk led_le}]
# ── 外置 I2S：与板载 HP_* 同参数 ⇒ 必须同约束（⛔ 现在漏了）
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_BCK I2S2_LRCK I2S2_DIN}]
# ── UART
set_output_delay -clock clk_sys -max 100.0 [get_ports {uart_tx esp_uart_tx_o}]
# ── 异步输入：给"外部器件的最坏 tCO + 走线"预算（⛔ 不要 false_path —— 那会连同步器的建立检查一起删）
set_input_delay -clock clk_sys -max 10.0 [get_ports {uart_rx spi_miso[*] timbre_btn_i pedal_sus_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {pluck_up_i pluck_down_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {ctrl_col_i[*] enc_a_i enc_b_i enc_sw_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i}]
```

**预期收益/代价**：
- 收益：**11 个异步输入的同步器首次获得真实建立预算** ⇒ MTBF 可量化、可优化；
  WS2812/SPI/TLC5916 的位边沿首次被工具守住；外置 I2S 与板载 I2S **同约束**（消除"板载对、外置错"的隐患）。
- 代价：⚠️ **会新增一批 setup 报告条目**，可能暴露真实违例（这正是目的）；`set_output_delay -max 2.0` 对 `I2S2_*`
  会把内部预算压到 18 ns（与板载一致）—— 已验证板载那路可过（`top.sdc:60` 实测 11.827 ns 路径）。

**怎么验证能红**：
```powershell
# 机械判据：SDC 里出现的 I/O 端口名必须覆盖 top.v 的全部非直流端口
$sdc = Select-String -Path constr/top.sdc -Pattern 'get_ports' | ForEach-Object { $_.Line }
$missing = @('ctrl_ws_o','spi_sclk','spi_miso','spi_cs_n','led_sdi','I2S2_BCK','uart_tx','esp_uart_tx_o','enc_a_i','esp_uart_rx_i') |
           Where-Object { -not ($sdc -match $_) }
if ($missing.Count -gt 0) { "RED: 未约束端口 $($missing -join ', ')"; exit 1 }
```
当前会报 **10 个未约束端口** ⇒ 红。修复后必须绿，并**同时**要求 PnR 的 setup/hold 违例仍为 0/0。

---

### P1-06 · 最差 **25 条 setup 路径全是结构性的**，余量 **0.102 ns**；且报告 `required` = **22.274 ns** ≠ SDC 的 **18.181 ns**（约束覆盖存疑）

**证据源**：`impl/pnr/Gowin2026.timing_paths`（25 SETUP + 25 HOLD，全部真实路径）

**前 6 条（按 slack 升序，全部由脚本从 `timing_paths` 机械解析）**：

| # | slack | data | required | 逻辑级 | 终点 | 结构? |
|---|---|---|---|---|---|---|
| 1 | **+0.102** | 22.172 | 22.274 | **12** | `g_sound.u_note_manager/g_t3.phase_tr[28]_24_s0` | ⭐ **结构性** |
| 2 | **+0.133** | 20.062 | 20.194 | **21** | `g_sound.u_tdm_render_mixer/prod_c_0_s` | ⭐ **结构性（21 级！）** |
| 3 | +0.154 | 22.120 | 22.274 | 12 | `g_sound.u_note_manager/g_t3.phase_tr[24]_24_s0` | ⭐ 结构性 |
| 4 | +0.191 | 22.066 | 22.257 | 12 | `g_sound.u_note_manager/g_t3.phase_tr[26]_30_s0` | ⭐ 结构性 |
| 5 | +0.208 | 22.066 | 22.274 | 12 | `g_sound.u_note_manager/g_t3.phase_tr[10]_30_s0` | ⭐ 结构性 |
| 6 | +0.604 | 19.611 | 20.215 | **21** | `g_sound.u_tdm_render_mixer/prod_c_0_s` | ⭐ 结构性 |

**完整路径 #1（逐跳，来自 `timing_paths` 原文）**：
```
g_sound.u_note_manager/g_t3.rot_cnt_0_s0
  → g_t3.rot_phase_20_s83 → rot_phase_20_s71 → rot_phase_20_s65
  → rot_phase_20_s62 → rot_phase_20_s61 → rot_base_22_s1 → rot_base_22_s0
  → g_t3.prod_w_0_s → n34284_s0 → g_t3.phase_tr[28]_24_s0
```
**完整路径 #2**：
```
g_sound.u_tdm_render_mixer/cnt_4_s0 → n4361_s3 → n41_s88 → n101_s44 → n101_s37 → n101_s33
  → vs_dif_4_s → vs_dif_5_s → … → vs_dif_17_s → prod_c_0_s
```
⭐ **`vs_dif_4..17` 连续 14 跳、每跳约 0.045 ns** —— 这是 **Gowin ALU 进位链的单级延迟**
⇒ 🔴 **这是 14 级串行进位链**，**不是布局运气，是结构决定的**（`Logic Level = 21`）。

**全 25 条统计（机械解析，⛔ 非抽样）**：

| 归属 | 条数 | 逻辑级 | slack 范围 | data 范围 |
|---|---|---|---|---|
| `g_sound.u_note_manager`（T3 变调旋转器 `g_t3.*`） | **19 / 25** | 全部 **12** | **+0.102 ~ +0.823 ns** | 21.447 ~ 22.172 ns |
| `g_sound.u_tdm_render_mixer`（`prod_c`） | **6 / 25** | **20 ~ 21** | +0.133 ~ +0.851 ns | 19.360 ~ 20.062 ns |
| 其他模块 | **0 / 25** | — | — | — |

**逐条（25/25，按 slack 升序）**：

```
 +0.102  22.172  L=12  u_note_manager      +0.632  21.634  L=12  u_note_manager
 +0.133  20.062  L=21  u_tdm_render_mixer  +0.766  21.499  L=12  u_note_manager
 +0.154  22.120  L=12  u_note_manager      +0.766  21.492  L=12  u_note_manager
 +0.191  22.066  L=12  u_note_manager      +0.770  19.611  L=21  u_tdm_render_mixer
 +0.208  22.066  L=12  u_note_manager      +0.810  21.447  L=12  u_note_manager
 +0.291  21.966  L=12  u_note_manager      +0.815  19.487  L=21  u_tdm_render_mixer
 +0.343  21.931  L=12  u_note_manager      +0.821  21.453  L=12  u_note_manager
 +0.354  21.926  L=12  u_note_manager      +0.823  19.611  L=21  u_tdm_render_mixer
 +0.404  21.870  L=12  u_note_manager      +0.850  19.514  L=21  u_tdm_render_mixer
 +0.418  21.853  L=12  u_note_manager      +0.851  19.360  L=20  u_tdm_render_mixer
 +0.425  21.832  L=12  u_note_manager
 +0.458  21.807  L=12  u_note_manager
 +0.502  21.755  L=12  u_note_manager
 +0.598  21.659  L=12  u_note_manager
 +0.604  19.611  L=21  u_tdm_render_mixer
```

⇒ ⭐ **全部 25 条都是【模块内】路径** —— 用户担心的"跨模块组合穿透导致长路径"**在本版 PnR 里不是最差路径的主因**；
真正的头号瓶颈是 **T3 变调（`T3_ENABLE=1`，`top.v:329`）的旋转/乘法链** 与 **TDM 混音的饱和累加链**。
⚠️ 但余量只有 **+0.102 ns（= 0.56% 个周期）** ⇒ 用户实测的"**同源重跑差 2~3 MHz**"（≈0.7~1.1 ns 的周期变化）
**足以把 #1~#8 全部打成负 slack** ⇒ 🔴 **这就是"偶发红/偶发绿"的机械来源**。

**🔴 附带发现（约束覆盖存疑）**：报告里 `required` 是 **22.274 / 22.257 / 20.194 / 20.215 ns**，
而 `top.sdc:101` 写的是 **18.181 ns**。
- 若这 25 条**被 18.181 覆盖** ⇒ `required` 应为 ≈18.18，slack 应为 **−4 ns 级**（与"0 违例"矛盾）；
- 若**未被覆盖** ⇒ 🔴 **`set_max_delay -from clk_sys -to clk_sys 18.181` 对这 25 条最差路径【不生效】**。
两种解释**都指向一个必须查清的事实**：`Actual Fmax = 55.060 MHz`（= 1/18.162 ns）**与路径表的 `required` 不自洽**
⇒ 该 Fmax 是 `top.sdc:81-83` 自己承认的"**外推值**"，**不能当作 18.181 ns 目标的达标证据**。

**具体改法**：
1. ⭐ **立刻（零风险）**：把 `top.sdc:101` 的 `set_max_delay` **换成显式、可核验的写法**，并加 `-datapath_only`：
   ```tcl
   set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
   ```
   然后**重新生成 Constraints Report**，确认这 25 条路径的 `required` 真的变成 18.181。
   ⛔ 在那之前，"0 setup 违例"**不能作为 18.181 ns 达标的证据**。
2. ⭐ **治本（T3 链）**：`note_manager` 的 `g_t3` 旋转器插一级流水（把 `rot_base`/`prod_w` 拆成两级），
   代价 = 变调生效晚 1 拍（20 ns），**听感无影响**。预期把 #1/#3~#14 的 slack 从 0.1~0.6 ns 抬到 **2~3 ns**。
3. ⭐ **治本（`prod_c` 链）**：`tdm_render_mixer` 的 `vs_dif` 进位链拆成 **两拍累加**（先算 16 路、再算后 16 路），
   代价 = 混音晚 1 拍（在 1024 拍帧预算里**完全装得下**，当前只用 100/1024）。
4. ⭐ **保底（若不能改 RTL）**：把 `T3_ENABLE` 置 0（`top.v:329`）出正式码流 ——
   `top.v:324-327` 已记录"影子数组版 `T_Lut 29622`，比 T3 关的基线**还低 1417**" ⇒ 关掉 T3 是**净收益**。

**预期收益/代价**：
- 改法 1：收益 = 约束可信；代价 = **0**。
- 改法 2/3：收益 = 最差 slack 从 **+0.102 ns** 抬到 **>2 ns**（抗住 ±2~3 MHz 布局噪声）；代价 = 各 1 拍延迟 + 需重跑全量回归 + 一次 PnR。
- 改法 4：收益 = 直接去掉 **19/25** 条最差路径（`note_manager` 那 19 条全部消失）；代价 = **失去 T3 实时变调**（用户已裁定"最终效果没问题就行"，需确认）。

**怎么验证能红**：
```powershell
# 机械判据（可进 CI）：最差 setup slack 必须 >= 1.0 ns（抗布局噪声）
$paths = Get-Content impl/pnr/Gowin2026.timing_paths
# 解析 SETUP 块的第一个数 = slack；取最小
# 当前 min = 0.102 ⇒ 红（< 1.0）
# 另：required 必须 == 18.181（±0.01）⇒ 当前 = 22.274 ⇒ 红（约束未覆盖）
```
② 行为判据：「tb/w3b/tb_note_manager_t3.sv」（历史引用，当前未收录） 家族必须证明"插流水后变调值**逐位不变**，只是晚 1 拍"。

---

### P1-07 · `DSP = 22/118`（19%）而 `top.v` 断言"**全设计只有 1 个 DSP**"

**位置**：`rtl/top.v:4258`（声明）· `rtl/drivers/calib.sv:373`（真实的 12×12 乘法，**例化 2 次**）

```verilog
// top.v:4258
        // ⭐ TDM 混音 + 饱和（T56）—— ⭐ 全设计**只有 1 个 DSP**
```
```verilog
// calib.sv:373
            prod_r <= dclamp * gain_rd;
```
（`u_calib0` @ `top.v:2479`、`u_calib1` @ `top.v:2499` ⇒ **2 个 12×12 乘法器**）

**实测资源（`sim/evidence/final-batch-20261008/pnr-rpt.txt`）**：
```
DSP                         | 22/118                              |  19%
--MULT12X12                 | 6
--MULT27X36                 | 6
--MULTALU27X18              | 7
CLS                         | 23228/29952                         |  78%
Register                    | 16975/60780                         |  28%
```

**机制（带数字）**：
文档断言 **1** 个，实测 **22** 个 ⇒ **差 22 倍**。这直接影响三件事：
1. **资源预算失真**：DSP 已用 **19%**（22/118）。若后续按"还有 117 个 DSP 可用"做设计决策，会踩空。
2. **时序理解失真**：DSP 有**固定的流水/组合延迟**（`MULT12X12` 组合路径约 4~6 ns @AC1/I0）。
   最差路径 #2（`u_tdm_render_mixer/prod_c`，**Logic Level 21**）里 `prod_c` 很可能就是一个乘法器输出寄存器
   ⇒ 把乘法器当"LUT 拼的浅逻辑"来估时序，**必然低估**。
3. **`calib` 的 2 个乘法器在 `pos` 通路的关键位置上**（`prod_r` 直接决定 `pos` ⇒ 决定按键触发）
   ⇒ 它们是 `axis_snapshot → event_extract` 链路的一环，⛔ 不是"无关紧要的角落"。

**具体改法**：
1. ⭐ **立即改正文档**：`top.v:4258` 改为
   ```
   // ⭐ TDM 混音 + 饱和（T56）—— 实测 PnR：DSP 22/118（19%）；
   //    --MULT12X12 6 · --MULT27X36 6 · --MULTALU27X18 7（见 sim/evidence/final-batch-20261008/pnr-rpt.txt）
   //    ⚠️ 原注释"全设计只有 1 个 DSP"与实测不符（差 22 倍）⇒ 已作废
   ```
2. ⭐ **把资源数字做成机械判据**（进 `sim/gowin_build.ps1` 验收）：解析 `pnr-rpt.txt` 的 `DSP` 行，
   与 RTL 里 `*` 的出现次数（`grep -c` 乘号）做**量级核对**；偏差 > 2× 则 **FAIL**。
3. ⭐ **（可选）把 `calib` 的乘法器换成移位相加**：`gain_rd` 是 `(4095<<8)/(span-zero)` 的商，
   **不是常数** ⇒ 不能强度缩减 ⇒ 保留 DSP 是**正确的**；但应在注释里写明"这 2 个 DSP 是必须的"。

**预期收益/代价**：收益 = 资源/时序模型回到地面真相；代价 = **1 段注释 + 1 条 CI 检查**，0 资源。

**怎么验证能红**：
```powershell
$dsp = (Select-String -Path sim/evidence/final-batch-20261008/pnr-rpt.txt -Pattern '^DSP\s+\|').Line
$claim = (Select-String -Path rtl/top.v -Pattern '只有\s*\*?\*?1\s*个\s*DSP').Count
if ($claim -gt 0 -and $dsp -notmatch '22/118') { "RED: 文档 DSP 声明与实测不符"; exit 1 }
```
当前 ⇒ 红。

---

### P1-08 · WS2812 数据脚是**组合直出**且**无输出约束**；`ws_wr_data` 是跨模块 8:1 组合 mux

**位置**：`rtl/w3a/ws2812_driver.v:130`（组合引脚）· `rtl/top.v:5003-5014`（跨模块组合 mux）· `rtl/top.v:4957`

```verilog
// ws2812_driver.v:129-130
    // High for T0H or T1H cycles, then low for the rest of the cell.
    assign dout_o = (state == S_SEND) && (bit_t < (cur_bit ? T1H : T0H));
```
```verilog
// top.v:4957
    assign ctrl_ws_o  = ws_dout;          // ⭐ 控制板灯带（C22）
```
```verilog
// top.v:5003-5014 —— led_indicator 的 168 位寄存输出 → 组合 8:1 mux → ws2812 写口
    always @* begin
        case (ws_wr_addr)
            5'd0: ws_wr_data = led_col_flat[  0 +: 24];
            ...
            5'd6: ws_wr_data = led_col_flat[144 +: 24];
            default: ws_wr_data = 24'h000000;
        endcase
    end
```

**机制（带数字）**：
1. **组合直出引脚**：`dout_o` 由 `state`（FF）· `bit_t`（FF）· `cur_bit`（FF）经 **1 个比较器 + 1 个 mux** 产生
   ⇒ 引脚边沿 = FF clk-to-Q + **组合延迟** + **未约束的输出布线延迟**。
   WS2812 要求（`ws2812_driver.v:21-29`）：T0H = **17 clk = 340 ns**（spec 350 ±150）、T1H = **35 clk = 700 ns**（spec 700 ±150）、
   BIT_CYC = **62 clk = 1240 ns**（spec 1250 ±600）。⇒ 位周期容限很宽，但：
   - **`bit_t < (cur_bit ? T1H : T0H)` 存在同沿竞争**：`bit_t`、`cur_bit`、`state` **同一个时钟沿更新**
     ⇒ mux + 比较器在沿后可能产生**短毛刺**。对 800 kHz 无影响（毛刺 ns 级），
     ⚠️ 但**对 `led_sdi/led_clk` 那类 tSU=8.5 ns 的器件（TLC5916）就不一定**（见 P1-05）。
   - `ctrl_ws_o` **不在 SDC 里**（P1-05）⇒ 布线延迟**完全未表征**。
2. **跨模块组合穿透**：`led_indicator.led_col_o`（**168 FF**）→ `top.v:5003` 的 **8:1 × 24 位 mux** → `ws2812_driver.mem[]` 写口。
   ⛔ 中间**没有寄存器**。24 位 × 8 选 1 = 约 **48~72 LUT**，2 级逻辑；虽浅，但它是**A 的输出不经过任何寄存器就进 B 的输入**的教科书例子。
3. **扇出**：`led_col_flat`（168 位）同时扇出到 8 个 case 分支 ⇒ **每一位扇出 8**（`top.v:5005-5011`）⇒ 布线压力。

**具体改法**：
```verilog
// ① ws2812_driver.v —— 输出加一级寄存（引脚时序可预测）
    reg dout_r;
    always @(posedge clk) begin
        if (!rst_n) dout_r <= 1'b0;
        else        dout_r <= (state == S_SEND) && (bit_t < (cur_bit ? T1H : T0H));
    end
    assign dout_o = dout_r;
```
```verilog
// ② top.v:5003-5014 —— 把 mux 的结果打一拍（切断跨模块组合链）
    reg [23:0] ws_wr_data_r;
    always @(posedge clk) ws_wr_data_r <= ws_wr_data_mux;   // ws_wr_data_mux = 原 case 结果
    // ⚠️ 但 ws_wr_data 必须与 ws_wr_addr 同拍 ⇒ 地址也要一起打拍（或把整个 case 挪进寄存器）
```
⭐ **更干净的做法**：把 `led_col_flat → mem[]` 的搬运整体移进 `ws2812_driver` 的一个**帧缓冲写端口**，
用 `led_col_flat` 直接做 `mem` 的初始值（`wr_en` 由 top 的装载器给），
⇒ 消掉 top.v 里的 8:1 mux（省 ~72 LUT），且写口与地址天然同拍。
```tcl
# ③ constr/top.sdc —— 补输出约束（见 P1-05）
set_output_delay -clock clk_sys -max 50.0 -min -50.0 [get_ports {ctrl_ws_o}]
```

**预期收益/代价**：
- ①：收益 = 引脚边沿只含 clk-to-Q + 布线，**时序可分析**；代价 = 数据**晚 1 clk（20 ns）**，
  ⇒ 必须把 `T0H/T1H` 各 +1 或把 `BIT_CYC` 检查重算（⚠️ **否则 T0H 变 360 ns、T1H 变 720 ns —— 仍在 spec 内，但注释必须同步**）。
- ②/③：收益 = 切断跨模块组合链、省 LUT、边沿被约束；代价 = 1 拍延迟（写口）+ 需重跑 `tb_ws2812_driver`。

**怎么验证能红**：
1. **时序**：`tb/w3a/tb_ws2812_driver.sv` 里逐位量 `dout_o` 的高电平拍数，断言
   `高拍数 ∈ {17±1, 35±1}` 且 `低拍数 = 62 − 高拍数`。加输出寄存后**未同步改 `T0H/T1H`** ⇒ 变 `{18,36}` ⇒ **红**。
2. **组合穿透（静态）**：脚本检查 `assign ctrl_ws_o` 的驱动源是否经过寄存器 ——
   当前 `dout_o` 是 `assign`（组合）⇒ **红**；修复后必须指向一个 `reg`。
3. **约束覆盖**：见 P1-05 的机械脚本（`ctrl_ws_o` 当前不在 `get_ports` 列表 ⇒ 红）。

---

### P1-09 · `axis_snapshot` 的 `pos_o` / `delta_o` 是**组合输出**，经 **4 处 16:1 mux + 22 位加法** 进入下游

**位置**：`rtl/w3a/axis_snapshot.v:202-214`（组合输出）· 消费点 `rtl/top.v:2785-2787` / `:3258` / `:2888` / `:2936`

```verilog
// axis_snapshot.v:202-214
    generate
        for (gi = 0; gi < AXIS_N; gi = gi + 1) begin : gen_out
            // ⭐ 本帧行程（⭐ 快照那一拍 `cur` 就是本帧值）
            assign pos_o[gi*POS_W +: POS_W] = cur[gi];

            // ⭐⭐ 带符号增量：`delta = cur − prev`
            assign delta_o[gi*DW +: DW] =
                {1'b0, cur[gi]} - {1'b0, prev[gi]};
        end
    endgenerate
```
```verilog
// top.v:2785-2787 —— 消费点 ①：16:1 mux → 22 位三项加减 → 寄存器
        wire [11:0] vu_pos = as_pos[vu_ax_r*12 +: 12];
        //   ⭐⭐ 与**起音力度**用同一个函数 ⇒ ⛔ 公式只有一份（见 `pos_to_vel`）
        wire [7:0]  vu_vel = pos_to_vel(vu_pos);
```
```verilog
// top.v:1202 —— `pos_to_vel` 内部：22 位 (p<<8) + (p<<3) − p
            prod       = (p22 << 8) + (p22 << 3) - p22;    // ⭐ ×263（⛔ 无乘法器）
```
```verilog
// top.v:3258 —— 消费点 ②：16:1 mux → 寄存器
                    am_pos_in  <= as_pos[pm_axis*12 +: 12];
// top.v:2888 —— 消费点 ③：16:1 mux → pos_probe
            .pos_i      (as_pos[np_axis_r*12 +: 12]),   // ⭐ 轮转轴的标定后行程
// top.v:2936 —— 消费点 ④（仅 DPOS_DIAG=1）：16 组并联减法 + 16 路最大值比较
                    if ({1'b0, dpos_abs_f(as_pos[dpi*12 +: 12], as_pos_d[dpi])}
                        > {1'b0, dpos_pk_r}) begin
```

**机制（带数字）**：
- `pos_o` 是 **192 位**（16×12）、`delta_o` 是 **208 位**（16×13）的**组合总线**，源头是 32 个 `reg` 数组（`cur[]`/`prev[]`，共 **384 FF**）。
- ⇒ **`cur[]` 的每一位扇出到 4 个不同模块的 16:1 mux**（`event_extract` · `param_extract` · `pos_probe` · `vu_*`）
  ＋ `delta_o` 的 **16 个 13 位减法器**（`axis_snapshot.v:211`）→ `event_extract`。
- ⇒ 消费点 ① 的完整组合链：`axis_snapshot.cur[]`（FF）→ **16:1 mux（12 位，2 级 LUT）** → `pos_to_vel` 的
  **22 位 3 项加减（`<<8` + `<<3` − 1，约 2~3 级 LUT4/ALU）** → `vu_val_r`（FF）。合计 **约 5 级逻辑**。
- 这是**教科书式的"A 的输出不经过任何寄存器就进 B 的组合逻辑"**，且 **`as_pos` 是 192 位宽的高扇出总线**。
- ⚠️ **本次 PnR 里它没有进前 25 名**（见 P1-06）⇒ 说明**当前布局把它排得不错**，
  但它是**结构性**的（逻辑深度 5 级 + 192 位扇出），属于"**布局运气在帮忙**"的那一类：
  一旦 `axis_snapshot` 与 `event_extract`/`vu_*` 被摆远，**2~3 MHz 的布局噪声就可能把它推进红区**。

**具体改法（按代价排序）**：
1. ⭐ **零风险、先做**：在 `axis_snapshot` 出口**加一级寄存**（`pos_o`/`delta_o` 各打一拍），
   同时把 `snap_valid_o` **一起打第二拍**（⛔ 必须同拍，否则犯 `K-109`"valid 与 data 不同拍"的老毛病）：
   ```verilog
   reg [AXIS_N*POS_W-1:0] pos_r;  reg [AXIS_N*DW-1:0] delta_r;  reg snap_r;
   always @(posedge clk) begin
       if (!rst_n) begin pos_r <= 0; delta_r <= 0; snap_r <= 0; end
       else begin
           for (gi=0; gi<AXIS_N; gi=gi+1) begin
               pos_r[gi*POS_W +: POS_W] <= cur[gi];
               delta_r[gi*DW +: DW]     <= {1'b0, cur[gi]} - {1'b0, prev[gi]};
           end
           snap_r <= snap_valid_o;
       end
   end
   assign pos_o = pos_r; assign delta_o = delta_r;
   ```
   ⚠️ **代价**：`snap_valid_o` 整体晚 1 拍 ⇒ 必须同步检查 `event_extract` 的 `REFRACT_N(60)`（`top.v:3137`）
   与 `calib_span` 的 `STABLE_NEED/VOTE_N` 是否按"帧"计（**是**，按帧 ⇒ **不受影响**）。
   ⇒ 收益：192+208 位的高扇出总线变成**寄存器到寄存器的干净起点**，消费点①的链缩短 2 级。
2. ⭐ **治本**：把"16:1 选轴"挪进 `axis_snapshot` 内部，对 **16 个轴各算一份 `vel`** 并寄存
   （`pos_to_vel` 复用同一函数 ⇒ 公式仍只有一份），下游直接按轴取。
   ⚠️ 代价 = **16 × 22 位加法器**（约 350 LUT）—— 与 `top.v:2753-2757` 记录的"Fmax 余量只有 +0.18%"相冲，**需实测**。

**预期收益/代价**：改法 1 = 收益（结构链 -2 级、扇出被寄存器隔断）/ 代价（1 拍延迟 + 需回归）；
改法 2 = 收益（彻底消除选轴 mux）/ 代价（+350 LUT，可能挤掉时序余量）。

**怎么验证能红**：
1. **静态**：脚本断言 `axis_snapshot.pos_o` / `delta_o` 的驱动必须经过寄存器。
   当前是 `assign ... = cur[gi]`（组合）⇒ **红**。
2. **动态（K-109 同拍性）**：`tb/w3a/tb_axis_snapshot.sv` 断言
   `snap_valid_o` 拉高的那一拍，`pos_o` **必须等于本帧写入的最后一个通道值**。
   加寄存器但**忘了把 `snap_valid_o` 一起打拍** ⇒ 该断言在"帧边界"抓错值 ⇒ **红**。
3. **时序**：加寄存器后重跑 PnR，断言最差 slack **不下降**（当前 +0.102 ns 是全局最差，不受此影响，但要看 `vu_*` 相关路径的余量）。

---

### P1-10 · **7 个板外异步输入完全没有同步器**（K-62 至今"仍待做"）

**位置**：`rtl/top.v:4898-4900`（唯一的"处理"= 异或归并）· `rtl/top.v:498-501`（端口声明）

```verilog
// top.v:4898-4900
    (* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_i, enc_a_i, enc_b_i, enc_sw_i,
                                                pedal_loop_rec_i,
                                                pedal_loop_play_i, esp_uart_rx_i};
```
```verilog
// top.v:498-501
    output wire esp_uart_tx_o,      // G21 · PMOD0 针 9 · IO2（出 · → ESP32 的 RX）
    input  wire esp_uart_rx_i,      // G22 · PMOD0 针 10 · IO3（入 · ← ESP32 的 TX · 上拉）
    // ── ⑥ 拓展板 WS2812 三路 · `PMOD1` 针 11/12/9 ─────────────────────────
    output wire [2:0] ws_strip_o    // W19/W20/F19 · PMOD1 针 11/12/9 · IO0/IO1/IO2（出）
```
```verilog
// top.v:4902-4906 —— 异或结果【直接】进一个 FF，无任何同步
    (* syn_keep = 1 *) reg  reserved_in_r;
    always @(posedge clk) begin
        if (!rst_n_sync) reserved_in_r <= 1'b0;
        else             reserved_in_r <= reserved_in_xor;
    end
```

**机制（带数字）**：
`grep -r "sync_input" rtl/` 的全部例化只有 **3 处**：
`top.v:575`（`timbre_btn_i`）· `top.v:637`（`pedal_sus_i`）· `adc_farm.sv:90`（`spi_miso` ×N_ADC）。
⇒ 下列 **7 个**（按位算 **10 位**）板外异步输入**没有任何同步器**：

| 信号 | 位 | 引脚 | 计划用途（`top.v` 注释） | 现状 |
|---|---|---|---|---|
| `ctrl_col_i[3:0]` | 4 | F15/C20/D20/D19 | 4×4 矩阵**列入**（上拉） | 🔴 无同步 |
| `enc_a_i` | 1 | E19 | EC11 A 相 | 🔴 无同步 |
| `enc_b_i` | 1 | C19 | EC11 B 相 | 🔴 无同步 |
| `enc_sw_i` | 1 | C18 | EC11 按压 | 🔴 无同步 |
| `pedal_loop_rec_i` | 1 | E18 | looper 录/停 | 🔴 无同步 |
| `pedal_loop_play_i` | 1 | B22 | looper 播 | 🔴 无同步 |
| `esp_uart_rx_i` | 1 | G22 | **ESP32 UART 接收** | 🔴 无同步 |

**两条风险**：
1. **`reserved_in_r` 是"10 位异步信号的异或"直接进 FF**（`top.v:4905`）⇒ 该 FF 会**亚稳态**。
   今天它**没有消费者** ⇒ 无功能后果；⚠️ **但它是"下一个接入者"的陷阱**：
   一旦有人读 `reserved_in_r`（或读 `reserved_in_xor`）做任何判断，就拿到一个**未同步的 10 位异步组合值**。
2. **`esp_uart_rx_i` 是已声明的功能端口**（`top.v:499` 注释"← ESP32 的 TX"）⇒
   ESP32 线一接上，它就是**第二个 UART 入口**，而它**没有 `sync_input`、没有 `uart_rx` 实例**。
   ⚠️ 这正是 `P0-03` 推荐的结构性修法（"曲谱走独立 UART"）所依赖的那根线 ⇒ **两条缺陷在同一根线上会师**。

**具体改法**：
```verilog
// top.v —— 每个异步输入在【进入任何逻辑之前】先过 sync_input（与 timbre/pedal 完全同款）
    // ── ① 4×4 矩阵列入（上拉 ⇒ 空闲 1、按下 0）—— 逐位同步
    wire [3:0] ctrl_col_s;
    genvar gc;
    generate for (gc=0; gc<4; gc=gc+1) begin : g_col_sync
        sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_col_sync (
            .clk(clk), .rst_n(rst_n_sync), .async_in(ctrl_col_i[gc]), .sync_out(ctrl_col_s[gc]));
    end endgenerate

    // ── ② EC11 A/B/SW —— 逐位同步（⚠️ A/B 必须【逐位】且【同一拍】，否则正交解码会误判方向）
    wire enc_a_s, enc_b_s, enc_sw_s;
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_a  (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_a_i),  .sync_out(enc_a_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_b  (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_b_i),  .sync_out(enc_b_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_sw (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_sw_i), .sync_out(enc_sw_s));

    // ── ③ 踏板 looper 两键
    wire pl_rec_s, pl_play_s;
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_pl_rec  (.clk(clk), .rst_n(rst_n_sync), .async_in(pedal_loop_rec_i),  .sync_out(pl_rec_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_pl_play (.clk(clk), .rst_n(rst_n_sync), .async_in(pedal_loop_play_i), .sync_out(pl_play_s));

    // ── ④ ESP32 UART —— 必须走【自己的】uart_rx 实例（顺带修 P0-03 的结构性方案）
    wire [7:0] esp_ur_data; wire esp_ur_done;
    uart_rx #(.BAUD_DIV(100)) u_uart_rx_esp (
        .clk_i(clk), .rst_n_i(rst_n_sync), .rx_i(esp_uart_rx_i),
        .rx_data_o(esp_ur_data), .rx_done_o(esp_ur_done));

    // ── ⑤ 异或归并改用【同步后】的值（或把已同步的从归并里摘掉）
    (* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_s, enc_a_s, enc_b_s, enc_sw_s,
                                                pl_rec_s, pl_play_s};
```
⚠️ **纪律**（`top.v:4885-4887` 自己写的）：**接入功能逻辑时，必须把该端口从 `reserved_in_xor` 里摘掉** ——
上面已按此把 7 个全部摘出并各自同步。

**预期收益/代价**：
- 收益：**K-62 从"仍待做"变成"已做"**；消除 10 位异步值进 FF 的亚稳态；EC11 A/B **逐位同拍**同步 ⇒ 正交解码方向不会因位偏斜而误判；
  `esp_uart_rx_i` 有了真正的 `uart_rx` ⇒ 顺带打通 P0-03 的结构性修法。
- 代价：**7 个 `sync_input`（每个 2 FF）= 14 FF** + 1 个 `uart_rx`（约 120 FF）≈ **134 FF**（占 60780 的 **0.2%**）；
  输入响应**晚 2 拍（40 ns）** —— 对机械按键/踏板**完全无感**。

**怎么验证能红**：
1. **静态（进 CI）**：脚本列出 `top.v` 全部 `input wire` 端口，断言每一个要么
   (a) 被 `sync_input` 例化的 `.async_in` 消费，要么 (b) 被 `uart_rx` 的 `.rx_i` 消费，要么 (c) 在**显式白名单**里（如 `clk`/`rst_n`）。
   当前会报 **7 个违规** ⇒ 红。
2. **动态**：`tb/top` 家族里对 `enc_a_i`/`enc_b_i` 注入**相对偏斜 0/1 拍的成对跳变**，
   断言 `debounce.enc_cw/enc_ccw` **不产生 `enc_err`**（`debounce.sv:178-181` 的非法跳变分支）。
   **未修复**：位偏斜会让 A/B 看起来"同时变化" ⇒ `enc_err` 置位 ⇒ **红**。

---

## 四、P2 级（8 条）

### P2-01 · `adc_farm.fault_r` **永远为 0** —— "ADC 故障"这一半的可观测性是空的

**位置**：`rtl/drivers/adc_farm.sv:216-221`

```verilog
    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;
```

**机制**：`always` 块**只有复位分支、没有 else** ⇒ `fault_r` 是"只被复位"的寄存器 ⇒ **恒 0**。
而 `top.v:1719` 把它当故障源用：`assign fault_any_w = (|af_fault) | mx_fault;`
⇒ 🔴 **`|af_fault` 恒 0** ⇒ 心跳灯的"快闪"**只能由 `mx_fault`（`tdm_render_mixer.deadline_fault_o`）触发**。
`top.v:4766-4777` 声称"两者都接上了、都能看见"—— **只对了一半**。
⚠️ 叠加 `P0-01`（`g_silent` 档悬空）⇒ **故障见证在两个方向上都漏**。

**具体改法**（把"预留"变成"真实现"，或至少把谎话删掉）：
```verilog
// 方案 A（推荐，实现最小可用的死片检测）：
//   MCP3208 在 CS 有效期间 DOUT 恒为 0/1（断线、无供电）⇒ 该片 raw 恒 0 或 4095。
//   用一个 16 帧窗口统计：若某片 16 帧的样本【全相同】⇒ 判定死片。
    reg [3:0]  stuck_cnt [0:N_ADC-1];
    reg [11:0] last_sample [0:N_ADC-1];
    integer    fi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (fi=0; fi<N_ADC; fi=fi+1) begin
                stuck_cnt[fi] <= 4'd0; last_sample[fi] <= 12'd0; fault_r[fi] <= 1'b0;
            end
        end else if (sample_valid) begin
            for (fi=0; fi<N_ADC; fi=fi+1) begin
                if (sample_data_packed[fi*12 +: 12] == last_sample[fi]) begin
                    if (stuck_cnt[fi] == 4'd15) fault_r[fi] <= 1'b1;   // ⭐ sticky
                    else stuck_cnt[fi] <= stuck_cnt[fi] + 4'd1;
                end else begin
                    stuck_cnt[fi] <= 4'd0; fault_r[fi] <= 1'b0;
                end
                last_sample[fi] <= sample_data_packed[fi*12 +: 12];
            end
        end
    end
// 方案 B（若暂不实现）：把 top.v:1719 改成 `assign fault_any_w = mx_fault;` 并删掉 `af_fault` 的引用，
//   同时在 adc_farm 的注释里写明"fault 端口当前恒 0，⛔ 不可作为故障判据"。
```

**预期收益/代价**：收益 = 排线松/ADC 掉电**首次可观测**（心跳灯 8 Hz 快闪）；代价 = 方案 A 约 **N_ADC×16 FF + 若干比较器**（N_ADC=2 ⇒ 32 FF），
⚠️ 需注意"**用户按住键不动时 raw 帧间变化可达 ~23 码**"（`top.v:1986-1988`）⇒ 阈值要留够，⛔ 不能用"完全相同"，
应用"**16 帧内 |Δ| ≤ 2 码**"作为卡死判据。

**怎么验证能红**：`tb/drivers/tb_adc_farm.sv` 里把某一片的 `adc_miso` 恒接 0（模拟断线），
断言 **16 帧内 `fault[该片] === 1'b1`** 且 `top.fault_sticky === 1'b1`，且 `led_heartbeat` 半周期变成 `HEARTBEAT_DIV>>3`。
**未修复**：`fault` 恒 0 ⇒ 红。

---

### P2-02 · 影子反串行器比片 0 的 driver **晚 1 个 clk** 采样 MISO ⇒ 片间存在 1 bit 的隐性偏斜

**位置**：`rtl/drivers/adc_farm.sv:125-127, 161-163` vs `rtl/drivers/mcp3208_driver.sv:111-114`

```verilog
// adc_farm.sv:125-127 —— 用"打一拍再比"检测 SCLK 上升沿 ⇒ 比 driver 晚 1 clk
    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);
```
```verilog
// adc_farm.sv:161-163 —— 在 sclk_rise 那一拍（= driver 置高后的【下一拍】）移位
        end else if (cs_active && sclk_rise) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= {miso_shift[gi][22:0], miso_sync[gi]};
        end
```
```verilog
// mcp3208_driver.sv:110-114 —— 片 0 在【置高那一拍】就采样
                        //产生spi时钟的上升沿
                        adc_sclk <= 1'b1;
                        //mode 0 :在上升沿读取MISO数据
                        rx_shift <= {rx_shift[22:0], adc_miso};
```

**机制（带数字）**：
- 片 0 的 `rx_shift` 在第 **T** 拍采 `miso_sync[0]`；
- 片 1..N−1 的 `miso_shift` 在第 **T+1** 拍采 `miso_sync[g]`。
⇒ 两者相差 **1 个 `clk_sys` = 20 ns**。`SCLK = 1 MHz` ⇒ 半周期 **500 ns**，MISO 由从机在 **SCLK 下降沿**更新
⇒ 在上升沿附近 MISO 稳定 ⇒ **今天不会出错**。
⚠️ 但这是**结构性的 1 拍错位**：一旦 `SCLK_HZ` 提到 **25 MHz 以上**（半周期 < 20 ns），
或 `sync_input` 的级数从 2 改成 3，**片 0 与片 1..N 就会采到相邻两个 bit** ⇒ 🔴 **静默的 1-bit 移位错误**
（现象：读数整体除以 2 或加倍，看起来像"增益标定错了"）。

**具体改法**：让两侧**同拍**。最干净的是把 `sclk_rise` 改成**与 driver 同拍**：
```verilog
// adc_farm.sv:125-127 —— 改成"当拍检测"（与 mcp3208_driver 同拍）
    reg sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];
    wire sclk_rise = (sclk_r == 1'b0) && (adc_sclk[0] == 1'b1);
    // ⚠️ 但 adc_sclk[0] 是 driver 的【寄存器输出】⇒ 它置高的那一拍 sclk_r 还是 0
    //    ⇒ 这个表达式本来就是"当拍"的！真正的问题是 miso_shift 用了 sclk_rise 的【寄存版】
```
⭐ **正解**：把 `miso_shift` 的移位条件从 `sclk_rise` 改为**与 driver 同源的组合条件**，
或在 `adc_farm` 里也做一级 `adc_sclk` 的边沿寄存**并把片 0 的采样也推后一拍**（统一到 T+1）：
```verilog
// 统一方案：给 scanner 也传"延迟一拍的 SCLK 上升沿"是不可能的（它在 driver 内部）
// ⇒ 改为在 adc_farm 里【只用 shadow_hold】，并把片 0 的数据也走同一级 shadow
//   （即在 adc_farm 里为片 0 也建一份 shadow_hold[0]，与片 1..N 完全同式）
```
**预期收益/代价**：收益 = 片间**零偏斜**，`SCLK_HZ` 提升不再触发静默错位；代价 = **+24 FF**（片 0 的影子）+ 需重跑 `tb_adc_farm`。

**怎么验证能红**：`tb/drivers/tb_adc_farm.sv` 里把 `SCLK_HZ` 参数化到 **25 MHz**（半周期 20 ns = 1 clk），
断言两片的 `sample_data_packed` **逐位相等**（同一从机模型喂同样的 MISO）。
**未修复**：片 1 会采到下一个 bit ⇒ 相差 2 倍 ⇒ **红**。

---

### P2-03 · 心跳分频 `HEARTBEAT_DIV>>3` 在**小参数 + 有故障**时**下溢** ⇒ 心跳灯停摆 85 秒

**位置**：`rtl/top.v:50` · `rtl/top.v:4793` · `rtl/top.v:4802`

```verilog
// top.v:50
    parameter integer HEARTBEAT_DIV     = 25_000_000,
```
```verilog
// top.v:4793
    wire [31:0] hb_div_eff = fault_sticky ? (HEARTBEAT_DIV >> 3) : HEARTBEAT_DIV;
```
```verilog
// top.v:4798-4808
    always @(posedge clk) begin
        if (!rst_n_sync) begin
            hb_cnt <= 32'd0;
            hb     <= 1'b0;
        end else if (hb_cnt >= hb_div_eff - 1) begin
            hb_cnt <= 32'd0;
            hb     <= ~hb;
```

**机制（带数字）**：
`HEARTBEAT_DIV` 是 `integer`（**有符号 32 位**）；`HEARTBEAT_DIV >> 3` 在 **< 8** 时得到 **0**。
`hb_div_eff` 是 `wire [31:0]`（**无符号**）⇒ `0 - 1` = **32'hFFFFFFFF** = 4 294 967 295
⇒ `hb_cnt` 必须数到 **4 294 967 294 拍 = 85.9 秒** 才翻转一次。
🔴 **触发条件**：`HEARTBEAT_DIV < 8` **且** `fault_sticky == 1`。
⚠️ 而 `top.v:49` 明文写着"**tb 会传小值以便快速验证**" ⇒ **所有传小值的 tb，一旦锁存故障，心跳灯就停摆**，
⇒ 任何"用心跳灯判活"的 tb 判据会**超时假红**（或假绿 —— 若它只等固定拍数）。

**具体改法**：
```verilog
// top.v:4793
    wire [31:0] hb_div_eff = fault_sticky ? ((HEARTBEAT_DIV >> 3) < 2 ? 32'd2 : (HEARTBEAT_DIV >> 3))
                                          : ((HEARTBEAT_DIV     < 2 ? 32'd2 : HEARTBEAT_DIV));
```
或加一条参数自检（与 `clk_gen` 的 `PARAM_OK` 同套路）：
```verilog
    initial if (HEARTBEAT_DIV < 8)
        $display("WARNING [top] HEARTBEAT_DIV=%0d < 8 => fault fast-blink (>>3) underflows to 0 and the heartbeat wedges for ~86 s", HEARTBEAT_DIV);
```

**预期收益/代价**：收益 = 小参数 tb 的心跳判据恢复可靠；代价 = **1 行**。

**怎么验证能红**：`tb/top/tb_top_m0.sv`（或任意 `HEARTBEAT_DIV=4` 的 tb）里断言
`fault_sticky=1` 之后 **`HEARTBEAT_DIV>>3 * 4` 拍内 `led_heartbeat` 必须翻转 ≥2 次**。
**未修复**：恒不翻转 ⇒ **红**。

---

### P2-04 · `rep_req`/`rep_byte`（**10 深优先编码器**）与 `tx_byte`（**5 深 mux**）是跨模块组合穿透，直连 FIFO 推入口

**位置**：`rtl/top.v:2433-2447` · `rtl/top.v:2470-2476`

```verilog
// top.v:2433-2447
        wire       rep_req  = ev_need   | ev_reject | ev_axis_ok | ev_done
                            | cmd_tare_req | cmd_span_req | cmd_abort_req | cmd_test_mode_req
                            | sp_start_rejected | (at_done & ~at_done_r)
                            | cmd_keydrum_req;   // ⭐ 'K' 键盘打鼓切换（⭐ 2026-10-01）
        wire [7:0] rep_byte = ev_need          ? axis_char        // ⭐ ① 轴号（⭐ 最要紧）
                            : ev_reject        ? rej_why_byte     // 🔴 被拒（⭐ 带原因码，见上）
                            : ev_axis_ok       ? 8'h2E            // '.' ⭐ 本轴通过
                            : ev_done          ? 8'h44            // 'D' ⭐ 全部完成
                            : sp_start_rejected? 8'h21            // '!' 🔴 'S' 被拒（正忙）
                            : (at_done & ~at_done_r) ? 8'h54      // 'T' ⭐ autotare 完成
                            : cmd_tare_req     ? 8'h74            // 't' ⭐ 受理 tare
                            : cmd_span_req     ? 8'h73            // 's' ⭐ 受理 span
                            : cmd_test_mode_req? tm_reply_byte    // M: 4/8/A/B/0
                            : cmd_keydrum_req  ? 8'h6B            // 'k' ⭐ 受理键盘打鼓切换
                            :                    8'h78;           // 'x' ⭐ 受理取消
```
```verilog
// top.v:2470-2476
        assign tx_req  = rep_req | pp_push | vp_push | np_push
                       | ((DPOS_DIAG != 0) ? dp_push : 1'b0);
        assign tx_byte = np_push ? np_data
                       : (((DPOS_DIAG != 0) && dp_push) ? dp_data
                       : (vp_push ? vp_data : (pp_push ? pp_data : rep_byte)));
```

**机制（带数字）**：`rep_byte` 是 **10 级优先 mux**，其中两级（`axis_char` @ `top.v:2326-2328`、`rej_why_byte` @ `top.v:2422-2431`）
**本身就是 4~6 级优先 mux**（`rej_why_byte` 是 6 级）⇒ 叠加后 **`tx_byte` 的总组合深度约 12~16 级 LUT**。
`tx_byte`/`tx_req` 直连 `uart_tx_fifo.push_i`/`data_i`（`top.v:1126-1127`），**中间无寄存器**。
⇒ 这是一条 **`calib_span` / `calib_autotare` / `calib_cmd` / `uart_ui` / `pos_probe` 的 FF → 12~16 级组合 → FIFO FF** 的路径。
⚠️ 它**没有进本次 PnR 的前 25 名**（说明布局给了它好位置），但它是**结构性**的，且**扇入极宽**
（跨 5 个模块的输出）⇒ 属于"布局运气在帮忙"的一类。

**具体改法**：把优先编码器**打一拍**（回包晚 20 ns，人眼完全无感）：
```verilog
    reg        rep_req_r;  reg [7:0] rep_byte_r;
    always @(posedge clk) begin
        if (!rst_n_sync) begin rep_req_r <= 1'b0; rep_byte_r <= 8'h00; end
        else             begin rep_req_r <= rep_req; rep_byte_r <= rep_byte; end
    end
    assign tx_req  = rep_req_r | pp_push | vp_push | np_push | ...;
    assign tx_byte = np_push ? np_data : (... : rep_byte_r);
```
⚠️ **注意**：`rep_req` 里有 `cmd_tare_req` 等**单拍脉冲** ⇒ 打一拍会**把脉冲延迟 1 拍**，
必须确认 `calib_cmd` 的脉冲宽度 ≥ 1 拍（**是**，见 `top.v:742-746` 的注释"单周期脉冲"）⇒ **安全**。

**预期收益/代价**：收益 = 切断一条 12~16 级、跨 5 模块的组合链，**时序余量更稳**；代价 = 回包晚 **20 ns**，+9 FF。

**怎么验证能红**：
1. **静态**：断言 `uart_tx_fifo.push_i` 的驱动源必须是寄存器（当前是 `rep_req | ...` 组合 ⇒ **红**）。
2. **动态**：`tb/w3a/tb_span_axis_over_uart.sv` / `tb/w3a/tb_uart_calib_chain.sv`（均**已存在**）
   断言回包字符序列**逐字节不变**（打一拍不改序列，只改时间）⇒ 未修复与已修复**都应绿**，
   故**这条的判据是"序列不变 + 静态检查"**，⛔ 不能靠行为 tb 抓。

---

### P2-05 · `cal_ch_mux` 仍是**跨模块组合仲裁**（历史组合环已修，但结构性风险残留）

**位置**：`rtl/top.v:2373`（现状）· `rtl/top.v:2355-2371`（历史缺陷记录）

```verilog
// top.v:2373
        wire [2:0] cal_ch_mux = sp_busy_r ? sp_ch : at_ch;
```
```verilog
// top.v:2355-2360（历史记录，证明这里真的出过组合环）
        //   🔴🔴 **为什么必须用 `sp_busy_r`（⭐ 打过一拍）而不是 `sp_busy`**：
        //      ⚠️ `sp_busy` 是 `calib_span.busy_o`（⭐ **组合输出**）
        //      ⇒ ⭐ `cal_ch_mux` 随它**立即变化** ⇒ ⭐ 而 `cal_ch_mux` 又喂给 `calib`
        //      ⇒ 🔴 **`cal_ch_mux` → `calib` → 采集通路 → `calib_span` → `sp_busy`
        //         → `cal_ch_mux` 形成【跨模块组合环】**
```

**机制**：现状用 `sp_busy_r`（寄存器）打断了环 ✅。但 `cal_ch_mux` 仍是
**`calib_span.sp_ch`（FF）与 `calib_autotare.at_ch`（FF）的 2:1 组合 mux**，直连 `calib.cal_ch`（两个实例，`top.v:2491`/`:2509`）。
⇒ 结构上仍是"A 的 FF → 组合 mux → B 的组合输入"，**深度 1 级**，风险很低，**但**：
⚠️ 若将来有人把 `sp_busy_r` 换回 `sp_busy`（看起来"少一拍更实时"），组合环**立刻复活**（仿真在时间 0 挂死，已实测）。
⇒ 这是一条**必须留下"为什么不能改回去"的机械护栏**的位置。

**具体改法**：加一条编译期/仿真期护栏（比注释硬）：
```verilog
// top.v:2373 附近
    // ⛔ 护栏：cal_ch_mux 的选择信号必须是寄存器（防止组合环复活）
    initial begin
        if (!$isunknown(sp_busy_r) && (sp_busy_r !== 1'b0) && (sp_busy_r !== 1'b1))
            $fatal(1, "ERROR [top] cal_ch_mux selector is not a clean register => the cross-module combinational loop (cal_ch_mux->calib->calib_span->sp_busy->cal_ch_mux) is back");
    end
```
⭐ 更实用的是**加一条 tb 超时护栏**：`tb/top/*` 统一加 `initial #1ms $fatal("simulation wedged at time 0 => combinational loop")`
—— `top.v:2361` 记录了当时的真实现象正是"**零输出超时**"。

**预期收益/代价**：收益 = 组合环不可能再静默复活；代价 = **1 条 initial**（仅仿真）。

**怎么验证能红**：把 `top.v:2373` 临时改成 `sp_busy ? sp_ch : at_ch`，跑 `tb/top/tb_top_sound.sv`
⇒ **未加护栏**：iverilog 在时间 0 反复求值、**零输出超时**（无明确报错）；
**加了护栏**：立即 `$fatal` 并指名组合环 ⇒ **红得清楚**。

---

### P2-06 · `pos_probe` 每实例 **3 个 12 位常数乘法** × 3 实例；历史上这里出过 **23.519 ns** 的最差路径

**位置**：`rtl/w3c/pos_probe.v:179` · `:257` · `:270` · `:55-63`（历史记录）

```verilog
// pos_probe.v:179
    wire [11:0] cur_x100 = {8'd0, cur_digit} * 12'd100;
// pos_probe.v:257
                            rem  <= rem - ({8'd0, cur_thou} * 12'd1000);
// pos_probe.v:270
                            rem  <= rem - ({8'd0, cur_ten} * 12'd10);
```
```verilog
// pos_probe.v:55-63（作者自己的实测记录）
//  ③ 🔴🔴 **BCD 转换必须【流水化】**（⭐ 2026-09-24 PnR 实测后重写）：
//     ⚠️ 第一版把"比较 → 减 → 比较 → 减 → 比较 → 减"写成**一整条组合链**
//     ⇒ 🔴 **最差时序路径 23.519 ns**（⭐ 目标 20 ns）
//        ⇒ ⭐ **Actual Fmax 从 54.6 MHz 掉到 50.011 MHz**（⭐ 余量只剩 0.02%）
```

**机制**：`cur_digit`/`cur_thou`/`cur_ten` 各是 **10 级优先比较器**（`pos_probe.v:135-173`），
其输入 `rem` 是寄存器，其输出经 **12 位常数乘法 + 12 位减法**回到 `rem`
⇒ 单级链 = `rem(FF)` → 10 级优先比较器 → 常数乘法（LUT 拼） → 12 位减法 → `rem(FF)`。
作者已把它拆成 **4 拍流水**（`bcd_stage`）⇒ 今天单级只有 1 个比较器 + 1 个乘法 + 1 个减法。
⚠️ 但本模块被例化 **3 次**（`top.v:2125` `u_pos_probe` · `top.v:2882` `u_pos_probe_cal` · `top.v:2995` `u_pos_probe_dpos`）
⇒ **9 个常数乘法器**的等价逻辑。⚠️ `u_pos_probe_dpos` 在 `DPOS_DIAG=0` 时被优化掉（`top.v:2991-2993`）⇒ 实际 6 个。

**具体改法**：把 3 个乘法器换成**移位相加**（常数 100 = 64+32+4、1000 = 1024−16−8、10 = 8+2）：
```verilog
// pos_probe.v:179
    wire [11:0] cur_x100 = (cur_digit << 6) + (cur_digit << 5) + (cur_digit << 2);   // ×100
// pos_probe.v:257
    rem <= rem - ((cur_thou << 10) - (cur_thou << 4) - (cur_thou << 3));            // ×1000
// pos_probe.v:270
    rem <= rem - ((cur_ten << 3) + (cur_ten << 1));                                  // ×10
```
（⛔ 注意左操作数位宽：`cur_digit` 是 4 位 ⇒ 必须先零扩展到 12 位再移位，否则**先截断再移位**，静默算错 —— 见 `top.v:1167-1171` 的同类教训。）

**预期收益/代价**：收益 = 3 个常数乘法器变成 2~3 个加法器，**省 LUT 且链更短**；代价 = 需重跑 `tb_pos_probe*`（**已存在**：`sim/evidence/tb_pos_probe.log` / `tb_pos_probe_axis.log`）。

**怎么验证能红**：`tb/w3c/tb_pos_probe.sv` 对 `pos_i` 扫 **0..4095 全量**，断言回包 4 位十进制**逐个正确**。
**未修复位宽**（写成 `(cur_digit << 6)` 而不先扩展）⇒ `cur_digit=9` 时 `9<<6` 在 4 位里截断 ⇒ 输出错 ⇒ **红**。

---

### P2-07 · `gray_launch` 与 `full_launch` 是**同一沿发射的两个独立 CDC bundle** ⇒ 接收侧可能取到不同"代"

**位置**：`rtl/hdmi/waveform_scope.v:38-42`（发射）· `:47-48,55-62`（接收）· `:89-90`（使用）

```verilog
// waveform_scope.v:38-42
    reg [9:0] gray_launch;
    reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
```
```verilog
// waveform_scope.v:55-62 —— 两个 bundle 各自 2 级同步，互不相关
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            gray_meta <= 0; gray_sync <= 0;
            full_meta <= 0; full_sync <= 0;
        end else begin
            gray_meta <= gray_launch; gray_sync <= gray_meta;
            full_meta <= full_launch; full_sync <= full_meta;
        end
    end
```
```verilog
// waveform_scope.v:89-90 —— 用 full_sync 门控 gray 派生的地址
            if (x_i == 0 && y_i == 480 && full_sync) begin
                copy_base <= wr_seen - 10'd640;
```

**机制（带数字）**：`gray_launch`（10 位）与 `full_launch`（1 位）在**同一个负沿**更新，
但在接收侧**各自独立同步 2 级**（10 条 + 1 条路径，位间/信号间偏斜不可控）
⇒ 可能出现 **`full_sync=1` 而 `gray_sync` 还是上一代**（或反之），
使 `copy_base = wr_seen − 640` 的 `wr_seen` 与 `full_sync` 的语义**差 1 个采样**。
⚠️ 实际后果**很小**（`copy_base` 只影响显示窗口起点，偏差 1 个采样 = 20.48 µs 的显示位移），
但它**破坏了"同一快照"的语义**，且 `full_launch` 是**电平**（不是脉冲）⇒ 在 `history_full` 从 0→1 的那一次跳变上必然出现这个窗口。

**具体改法**：把两个 bundle 合成**一个**灰码化的向量，一次同步：
```verilog
// 发射侧：{full, gray} 作为一个 11 位灰码字（full 是 sticky ⇒ 只需在它变化时确保 gray 同步更新）
    reg [10:0] cdc_launch;
    always @(negedge sample_clk)
        if (!sample_rst_n) cdc_launch <= 11'd0;
        else               cdc_launch <= {history_full, wr_gray};
// 接收侧：一次 2 级同步
    (* async_reg = "true" *) reg [10:0] cdc_meta, cdc_sync;
    always @(posedge pixel_clk)
        if (!pixel_rst_n) begin cdc_meta <= 0; cdc_sync <= 0; end
        else              begin cdc_meta <= cdc_launch; cdc_sync <= cdc_meta; end
    wire [9:0] gray_sync = cdc_sync[9:0];
    wire       full_sync = cdc_sync[10];
```
⚠️ 严格来说 `{full, gray}` 整体**不是**灰码（两个字段同时变），
但 `full` 是 **sticky 单比特**、`gray` 是**单比特变化** ⇒ 最坏情况是"多取或少取 1 个采样"，**与现状等价**，
而**单次同步**消除了"两 bundle 代际不一致"这个额外自由度 ⇒ **净改善**。

**预期收益/代价**：收益 = CDC bundle 从 2 个减到 1 个，代际一致；代价 = **11 FF 变 11 FF（0 增量）**。

**怎么验证能红**：`tb/hdmi` 里在 `pixel_clk` 侧断言
**`full_sync` 首次变 1 的那一拍，`wr_seen` 必须 ≥ 640**（否则 `copy_base` 会下溢成 10 位回绕值）。
把 `sample_clk`/`pixel_clk` 的相对相位随机化 200 次 ⇒ **未修复**时会在某个相位抓到 `wr_seen < 640` ⇒ **红**。

---

### P2-08 · HDMI PLL **无条件例化**，与"单时钟域、无 PLL"的设计信条**正面冲突**

**位置**：`rtl/clk_gen.v:2` · `constr/top.sdc:2` · `rtl/hdmi/hdmi_clk.v:17-28` · `rtl/top.v:1228-1232`

```verilog
// clk_gen.v:2
// clk_gen.v · L1 时基（⛔ 不用 PLL、无门控时钟、全设计单时钟域）
```
```tcl
# top.sdc:2
# top.sdc · **时序约束**（`files/20-代码/W3接口冻结表.md` §〇：单时钟域、无 PLL）
```
```verilog
// hdmi_clk.v:17-28
    PLLA u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
        ...
        .LOCK(pll_lock), .CLKOUT0(serial_clk), .CLKOUT1(pixel_clk),
```
```verilog
// top.v:1228-1232 —— 无条件例化（没有 generate 门控）
    hdmi_scope u_hdmi (.clk(clk), .rst_n(rst_n_sync),
        .sample_i(scope_sample), .valid_i(scope_valid),
```

**机制（带数字）**：
- `clk_gen.v:2` 与 `top.sdc:2` 都断言"**单时钟域、无 PLL**"，而实际有 **3 个时钟域**
  （`clk_sys` 50 MHz · `pixel_clk` 25 MHz · `serial_clk` 125 MHz，见 `timing.txt:34-63`）。
- `top.v:5-9` 记载了本项目**最惨痛的历史教训**：`K-41`"**上一个项目把全设计换成 PLL 时钟后板子全死、连 UART 都没输出**"。
  ⇒ 🔴 **当前设计在顶层无条件例化了一个 PLLA + 4 对 LVDS**，而文档仍在说"无 PLL" ⇒
  **新加入者读文档会做出错误假设**（例如认为"任何信号都能当同步信号用"）。
- 资源代价：PLL ×1（`PLLA`）+ `OSER10` ×4 + `TLVDS_OBUF` ×4 + **4 对差分引脚**
  —— **全部无条件占用**，即使 `hpd_en=1'b1`（`hdmi_scope.v:16`）根本没有消费者。

**具体改法**：
1. ⭐ **改文档（必须，1 行）**：
   - `clk_gen.v:2` 改为 `// clk_gen.v · L1 时基（⛔ 本模块不用 PLL；⚠️ 全设计【不是】单时钟域 —— HDMI 另有 pixel_clk/serial_clk，见 hdmi_clk.v）`
   - `top.sdc:2` 同样更正。
2. ⭐ **给 HDMI 加编译期总闸**（与 `TEST_MODE_EN`/`DPOS_DIAG` 同一手法）：
   ```verilog
   parameter integer HDMI_SCOPE_EN = 0,   // ⭐ 默认关：不需要示波器显示时不占 PLL/4 对差分脚
   ...
   generate if (HDMI_SCOPE_EN != 0) begin : g_hdmi
       hdmi_scope u_hdmi (...);
   end else begin : g_no_hdmi
       assign scope_sample = 24'sd0; assign scope_valid = 1'b0;
       assign tmds_d_p_0 = 3'b000; assign tmds_d_n_0 = 3'b111;
       assign tmds_clk_p_0 = 1'b0; assign tmds_clk_n_0 = 1'b1;
       assign hpd_en = 1'b0;
   end endgenerate
   ```
   ⚠️ 注意 `scope_sample`/`scope_valid` 在 `g_sound`/`g_silent` 里**已被 assign**（`top.v:1247-1248`、`:4492-4493`）
   ⇒ 必须把这两个 assign 一起挪进 generate（否则**多驱动**）。
3. ⭐ **（可选）把 `hpd_en` 接到真实用途或删掉** —— 现在是 `assign hpd_en = 1'b1;`（`hdmi_scope.v:16`），**无人消费**。

**预期收益/代价**：收益 = 文档与地面真相一致（⛔ 不再误导）；可选地**释放 1 个 PLL + 4 对差分脚**；
代价 = 文档改动 2 行；加总闸需要动 `top.v` 的 generate 结构（**中等风险，需重跑全量回归**）。

**怎么验证能红**：
```powershell
# 机械判据：文档声称"无 PLL/单时钟域"时，RTL 里不得出现 PLL 原语
$pll = Select-String -Path rtl -Recurse -Pattern 'PLLA|rPLL|PLLVR'
$claim = Select-String -Path rtl/clk_gen.v,constr/top.sdc -Pattern '无 PLL|单时钟域'
if ($pll.Count -gt 0 -and $claim.Count -gt 0) { "RED: 文档声称无 PLL 但 RTL 里有 $($pll.Count) 处 PLL 原语"; exit 1 }
```
当前 ⇒ 红。

---

## 五、P3 级（5 条）

### P3-01 · `top.sdc` 注释说 **19.417 ns**，代码写 **18.181 ns** —— 复发性"注释↔代码不一致"

**位置**：`constr/top.sdc:91-101`

```tcl
# top.sdc:91-96
#   ③ `gray_launch`/`full_launch` 走的是 `negedge sample_clk` 半周期预算（10 ns，
#      见 `rtl/hdmi/waveform_scope.v:38-43`）⇒ 必须**显式钉住 10 ns**，
#      否则会被下面那条 19.417 意外放宽。
#
# 📌 取值：19.417 ns ≈ 51.5 MHz（精确值 19.4174757 ⇒ 这里**略紧**）。
#    挑战档 = 18.181 ns（≈55 MHz，精确 18.1818182 ⇒ **略松**，确保严格达标）。
```
```tcl
# top.sdc:101-102（实际生效的值）
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```

**机制**：注释里"下面那条 19.417"指的是**已经被改成 18.181 的那条** ⇒ 注释**过期**。
本项目 `AGENTS.md` §五③ 明文记录"注释↔代码不一致"是**复发缺陷**（`tdm_render_mixer.v` 三项全错）。
⇒ 一个读注释的人会以为当前跑的是"**51.5 MHz 门槛档（19.417）**"，而实际跑的是"**挑战档（18.181 ≈ 55 MHz）**"
⇒ 会**误判余量的含义**（把 55 MHz 的成绩当成 51.5 MHz 的成绩）。

**具体改法**：
```tcl
# top.sdc:91-96 —— 改为与代码一致
#   ③ `gray_launch`/`full_launch` 走的是 `negedge sample_clk` 半周期预算（10 ns，
#      见 `rtl/hdmi/waveform_scope.v:38-43`）⇒ 必须**显式钉住 10 ns**，
#      否则会被下面那条 **18.181** 意外放宽。
#
# 📌 当前生效值 = **18.181 ns（≈55 MHz，挑战档）** —— 见下方 :101。
#    门槛档 19.417 ns（≈51.5 MHz）**未启用**；切换时改 :101 一处即可。
```

**预期收益/代价**：收益 = 读者不再误判余量口径；代价 = **6 行注释**。

**怎么验证能红**：脚本比对 `top.sdc` 里出现的所有 `\d+\.\d+` 数值与该文件里 `set_max_delay` 的实际参数，
**注释中提到的"下面那条 N"必须等于紧邻的下一条 `set_max_delay` 的数值**。当前 19.417 ≠ 18.181 ⇒ 红。

---

### P3-02 · `$display` 与 `$fatal` **混用**：同类参数自检，有的硬失败、有的只打印

**位置（用 `$fatal`，正确）**：`rtl/w3c/uart_rx.v:196` · `rtl/top.v:2719` · `rtl/top.v:2723`
**位置（用 `$display`，可被刷屏淹没）**：`rtl/clk_gen.v:67,73` · `rtl/top.v:2669,2681,2688,2692,2826,2832,2835` · `rtl/drivers/adc_farm.sv` 无自检

```verilog
// uart_rx.v:196 —— 正确：硬失败
            $fatal(1, "ERROR [uart_rx] BAUD_DIV=%0d < 4 => bit-midpoint sampling is unusable ...");
```
```verilog
// top.v:2826 —— 同族缺陷，但只打印
                $display("ERROR [top] VEL_AXIS_N=%0d != SYS_AXIS_N=%0d => %0d axis/axes get ATTACK velocity but NO follow ...",
                         VEL_AXIS_N, SYS_AXIS_N, ...);
```
```verilog
// top.v:2681 —— 同上
            if (TRAVEL_TARE > 12'd1023)
                $display("ERROR [top] TRAVEL_TARE(%0d) > calib.MAX_TRAVEL(1023) => ... (K-124)",
                         TRAVEL_TARE);
```

**机制**：`$display` 在仿真里**不阻止运行**、在综合里**被完全忽略** ⇒
`VEL_AXIS_N != SYS_AXIS_N`（`top.v:2825`）这类**会导致部分轴"有起音力度但完全没有跟随"**的缺陷
（`top.v:2817-2818` 自认"同族 K-56：全绿不证明任何事"）**只留一行可能被刷屏淹没的日志**，
而**综合照常进行、缺陷原样进板**。
`uart_rx.v:185-197` 已经把这条教训写成"**必须硬失败**"，但 `top.v`/`clk_gen.v` 的同类检查**没有跟上**。

**具体改法**：把 `top.v:2669/2681/2688/2692/2826/2832/2835` 与 `clk_gen.v:67/73` 的 `$display` 改成 `$fatal(1, ...)`。
⚠️ **例外**：`clk_gen.v:72-74` 的"`CLK_PER_SAMPLE` 不能被 `2×BCLK_DIV` 整除"**可以**保持 `$display`
（它是"配置建议"而非"必然缺陷"），但要在注释里写明理由（照 `uart_rx.v:198-204` 的先例）。

**预期收益/代价**：收益 = 量纲/轴数错配**不可能静默进板**；代价 = ⚠️ **可能打断现有 tb**（若有 tb 故意传错参数来验"自检能报"）
⇒ 需先 `grep` 全部 tb 确认（`tb/**` 里搜 `VEL_AXIS_N` / `TRAVEL_TARE` / `PARAM_OK`）。

**怎么验证能红**：
```powershell
# 机械判据：凡消息里含 "ERROR [top]" 或 "ERROR [clk_gen]" 的行，必须使用 $fatal
Select-String -Path rtl/top.v,rtl/clk_gen.v -Pattern 'ERROR \[(top|clk_gen)\]' -Context 1,0 |
  Where-Object { $_.Line -notmatch '\$fatal' }   # 当前有 9 处 ⇒ 红
```

---

### P3-03 · `led_drum_on` 与 `src_b_valid` 是**两份真相**，靠注释维持一致

**位置**：`rtl/top.v:4982`（指示层）· `rtl/top.v:3867-3869`（真实门控）· `rtl/top.v:4979-4980`（自述）

```verilog
// top.v:4982 —— 指示层用的表达式
    wire led_drum_on = (SEL_DRUM == 1) && (METRONOME_ON != 0) && met_on_r;
```
```verilog
// top.v:3867-3869 —— 真实进 evt_merge 的门控
        wire        src_b_valid = (sel_drum ? drm_evt_valid : met_evt_valid)
                                  & (METRONOME_ON != 0)
                                  & met_on_r;
```
```verilog
// top.v:4979-4980 —— 作者自己承认这是双份真相
    //      🔴 **与 `g_sound` 里 `src_b_valid` 的算式逐项一致** ⇒ ⭐ 改一处必须改两处
    //         （⭐ 否则指示灯会说"鼓机在响"而实际不响 —— ⚠️ 比不亮更坏）
```

**机制**：`led_drum_on` 用 `(SEL_DRUM == 1)` **字面量**，而真实门控用 `sel_drum`（`top.v:3848` 定义的 wire）。
今天两者等价，但：
- 若有人把 `SEL_DRUM` 参数改成"运行时信号"（`top.v:110` 的注释**明确说将来要这么做**："只需把 `sel_drum` 换成寄存器即可"），
  `led_drum_on` 会**继续读编译期常量** ⇒ 🔴 **指示灯说谎**（用户最讨厌的一类）。
- `led_drum_on` **没有**包含 `drm_evt_valid`/`met_evt_valid` ⇒ 它表示的是"**源 B 已使能**"而不是"**正在发声**"，
  而注释把它当"正在发声"用（"只有三者都成立时，鼓机才**真的在出声**"）。

**具体改法**：
```verilog
// top.v:4982 —— 单一来源：引用同一个 `sel_drum`
    wire led_drum_on = sel_drum && (METRONOME_ON != 0) && met_on_r;
```
⚠️ `sel_drum` 声明在 `g_sound` 内（`top.v:3848`），而 `led_drum_on` 在 `g_sound` **之外**（`top.v:4982`）
⇒ 必须把 `sel_drum` 提到模块层（照 `tx_req`/`led_blink` 的先例，由两个 generate 分支各自驱动）。

**预期收益/代价**：收益 = 指示灯不再能说谎；代价 = 需把 `sel_drum` 提到模块层（**小改，但涉及 generate 边界，需回归**）。

**怎么验证能红**：`tb/top/tb_top_led_strip.sv`（**已存在**，见 `top.v:1263`）里加：
把 `SEL_DRUM` 参数改成一个运行时寄存器后，断言 **`led_drum_on` 与 `src_b_valid` 在同拍等价**。
**未修复**：`led_drum_on` 恒等于 `SEL_DRUM==1` ⇒ 断言红。

---

### P3-04 · `clk_gen` 的 `initial` 自检用 `$display`，与 `uart_rx`/`top` 的 `$fatal` 先例不一致

**位置**：`rtl/clk_gen.v:65-75`

```verilog
    initial begin
        if (!PARAM_OK)
            $display("ERROR [clk_gen] 参数必须全为 2 的幂且 BCLK_DIV/MCLK_DIV >= 2、CLK_PER_SAMPLE >= BCLK_DIV：...",
                     CLK_PER_SAMPLE, BCLK_DIV, MCLK_DIV);
        // ⭐ R-05：跨模块一致性 —— `i2s_tx` 的每声道时隙数必须与这里算出来的一致。
        if ((CLK_PER_SAMPLE % (BCLK_DIV * 2)) != 0)
            $display("ERROR [clk_gen] CLK_PER_SAMPLE(%0d) 不能被 2×BCLK_DIV(%0d) 整除 ⇒ 左右时隙不等长",
                     CLK_PER_SAMPLE, BCLK_DIV * 2);
    end
```

**机制**：`clk_gen.v:46-53` 的注释自己写明"**非 2 的幂会【静默给错频率】**"
（例如 `BCLK_DIV=12` ⇒ 实际仍按 ÷16 走 ⇒ BCLK 比预期低 33%）。
这种"**频率错了但一切看起来正常**"的缺陷，与 `uart_rx.v:189-194` 描述的
"`BAUD_DIV<4` ⇒ 毛刺保护静默失效"**属于同一族**（`K-87`），而 `uart_rx` 已经升级成 `$fatal`。
⇒ `clk_gen` 的自检**只留一行日志**，综合时**完全被忽略** ⇒ 缺陷原样进板。

**具体改法**：`clk_gen.v:66` 与 `:72` 的 `$display` → `$fatal(1, ...)`（保留消息原文）。
⚠️ 先 `grep tb/` 确认没有 tb 故意传非法参数来验自检。

**预期收益/代价**：收益 = 频率错配不可能静默进板；代价 = **2 处关键字**。

**怎么验证能红**：加一条 tb（或临时改参数）：`clk_gen #(.BCLK_DIV(12))` ⇒
**未修复**：仿真跑完、只打印 ERROR ⇒ 若判据是"仿真必须终止"则**红**；
**已修复**：`$fatal` 立即终止 ⇒ 绿。

---

### P3-05 · `clk_gen.lrclk` 是**死输出**；`mclk_en` 也无人消费 —— 顶层挂了 2 根不用的线

**位置**：`rtl/clk_gen.v:37,105,108` · `rtl/top.v:785-800`

```verilog
// clk_gen.v:37-38
    output reg  lrclk,        // 帧时钟电平：低 = 左声道（标准 I2S）
    output reg  frame_start   // 本周期是"帧内第 0 个 BCLK"（给 i2s_tx 对齐用）
```
```verilog
// top.v:785-800 —— `lrclk`/`mclk_en` 被声明但无人使用
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;

    clk_gen #(
        .CLK_PER_SAMPLE (1024),   // fs = 50 MHz ÷ 1024 = 48.828125 kHz
        .BCLK_DIV       (16),     // BCLK = 3.125 MHz（= 64 × fs）
        .MCLK_DIV       (4)       // MCLK = 12.5 MHz（板载 DAC 不用，留作观测）
    ) u_clk_gen (
        ...
        .mclk_en      (mclk_en),
        ...
        .lrclk        (lrclk),
```
**`i2s_tx.v:39-40` 的注释明确说明为什么不用它**：
> *"`HP_WS` **由本模块自己的计数器决定**…⛔ 不要直通 `clk_gen` 的 `lrclk` 寄存器 —— 它比位边界晚一拍，会让 WS 与数据错开半个 BCK。"*

**机制**：`lrclk` 与 `mclk_en` 被 `clk_gen` 寄存产生（**各 1 FF + 各自的比较器**），
顶层连线后**没有任何消费者** ⇒ 综合会剪掉**下游**，但 `clk_gen` 内部的寄存器因为**是模块输出**，
在**模块级综合**时不会被剪（顶层综合可能剪，取决于工具）。
⇒ 最小后果：**浪费 2 FF + 2 个比较器**（可忽略）；
⚠️ 真后果：**下一个人看到 `lrclk` 被接出来，会以为它是"权威的 WS"**，
而 `i2s_tx.v:39-40` 的警告在另一个文件里 ⇒ **重蹈"WS 与数据错开半个 BCK"的覆辙**（`i2s_tx.v:34-41` 记录这是**踩过两次**才定下来的）。

**具体改法**（二选一）：
```verilog
// 方案 A（推荐）：顶层删掉这两根线，并在 clk_gen 的端口注释里标注"仅供观测/未使用"
//   top.v:785 → wire tick_audio, bclk_en, bclk_half_en, frame_start;   // ⛔ 不再引 mclk_en/lrclk
//   top.v:795/798 → 删除 .mclk_en(...) / .lrclk(...)
// 方案 B：保留，但在 clk_gen.v:37-38 的端口注释加一行
//   // ⚠️ `lrclk` **⛔ 不要直通 `i2s_tx` 的 WS**（见 i2s_tx.v:39-40：它比位边界晚一拍）
```

**预期收益/代价**：收益 = 消除"误用权威 WS"的陷阱；代价 = **方案 A 删 4 行**（需确认无 tb 引用 `dut.lrclk`）。

**怎么验证能红**：脚本断言 `top.v` 里 `clk_gen` 例化的**每个输出端口都在模块层被消费至少一次**。
当前 `mclk_en`/`lrclk` 违规 ⇒ 红。

---

## 附录 A · 逐条"怎么验证能红"索引（可复制进 CI）

| 编号 | 机械判据（一行/一段） | 行为判据（tb） |
|---|---|---|
| P0-01 | `(Select-String rtl/top.v -Pattern 'assign\s+fault_any_w').Count == 2` | `tb_top_m0`：`fault_sticky` 非 X + 心跳翻转 ≥2 |
| P0-02 | `grep -c 'or negedge rst_n' rtl/**` → 目标 0（HDMI 除外） | `tb_reset_release_order`：200 相位下各模块脱离复位拍号相等 |
| P0-03 | `SCORE_UART_ENABLE == 0` 或曲谱走独立 `uart_rx` | `tb_evt_uart_rx_screen`：`frame_cnt_o == 0`；`gate_r` 能被 `live` 清 |
| P0-04 | Fmax 汇总行数 == `create_generated_clock` 数 | 示波器量 125 MHz / 250 Mb/s 眼宽 |
| P1-01 | `negedge` 出现次数 == 0；`get_regs` 对象非空 | `tb/hdmi`：灰码指针步长 ≤1（200 相位） |
| P1-02 | `tmds_serializer` 的 `.rst` 必须接已同步复位 | `reset_pipe` 3 位同拍释放 |
| P1-03 | — | `tb_async_pluck_capture`：偏移 1 拍时 `pluck_up_o` 恒 1 |
| P1-04 | `async_reg` 出现次数 ≥ 6（当前 2） | 综合后同步器仍是 2 个独立 FF |
| P1-05 | SDC `get_ports` 覆盖全部非直流端口 | PnR 新增约束后仍 0 setup/0 hold |
| P1-06 | 最差 slack ≥ 1.0 ns；`required == 18.181` | 插流水后变调值逐位不变 |
| P1-07 | `DSP` 行与 RTL 乘号量级一致 | — |
| P1-08 | `ctrl_ws_o` 驱动源必须经过寄存器；SDC 覆盖 | `tb_ws2812_driver` 高拍数 ∈ {17,35} |
| P1-09 | `pos_o/delta_o` 驱动必须经过寄存器 | `tb_axis_snapshot`：valid 与 data 同拍（K-109） |
| P1-10 | 每个 `input wire` 都被 `sync_input`/`uart_rx` 消费 | A/B 偏斜注入下 `enc_err` 不置位 |
| P2-01 | `adc_farm` 的 `fault` 不得恒 0 | `tb_adc_farm`：MISO 恒 0 ⇒ 16 帧内 fault=1 |
| P2-02 | — | `tb_adc_farm`：`SCLK_HZ=25M` 下两片数据逐位相等 |
| P2-03 | `HEARTBEAT_DIV ≥ 8` 或加下溢保护 | 小 `HEARTBEAT_DIV` + 故障 ⇒ 心跳仍翻转 |
| P2-04 | `uart_tx_fifo.push_i` 驱动源必须是寄存器 | 回包字符序列逐字节不变 |
| P2-05 | 组合环护栏 initial 存在 | 换回 `sp_busy` ⇒ 立即 `$fatal` |
| P2-06 | — | `tb_pos_probe`：0..4095 全量十进制正确 |
| P2-07 | — | `full_sync` 首次为 1 时 `wr_seen ≥ 640` |
| P2-08 | 文档称"无 PLL"时 RTL 不得有 PLL 原语 | — |
| P3-01 | 注释里的"N ns"必须等于下一条 `set_max_delay` 的值 | — |
| P3-02 | `ERROR [top]`/`ERROR [clk_gen]` 必须用 `$fatal` | 传非法参数 ⇒ 仿真立即终止 |
| P3-03 | — | `led_drum_on` 与 `src_b_valid` 同拍等价 |
| P3-04 | `clk_gen` 自检必须 `$fatal` | `BCLK_DIV=12` ⇒ 仿真终止 |
| P3-05 | `clk_gen` 每个输出端口在模块层被消费 | — |

---

## 附录 B · **检查过且干净**的（⛔ 不假装没看，也⛔ 不虚报缺陷）

| 项 | 位置 | 核对了什么（带数字） | 结论 |
|---|---|---|---|
| `clk_gen` 节拍频率 | `clk_gen.v:104-109` | `bclk_en` = 16 clk = **320 ns = 3.125 MHz**；`bclk_half_en` = 8 clk = 160 ns；`tick_audio` = 1024 clk = **20.48 µs = 48.828125 kHz**；`bclk_half_en` 是 `bclk_en` 的 2 倍频 ⇒ 二者同沿 | ✅ 数值全部正确 |
| `clk_gen` 参数位选 | `clk_gen.v:88-92` | `$clog2(16)=4` ⇒ `cnt[3:0]`；`$clog2(8)=3` ⇒ `cnt[2:0]`；`bpos = cnt>>4` 得 6 位（`BW=6`）；`SLOT_BCK=32` | ✅ 位宽自洽 |
| `rst_sync` 的 2 级链 | `rst_sync.v:37-45` | `sync_chain <= {sync_chain[0], rst_n_async}` ⇒ 严格 2 级；有 `async_reg`；有 `initial` 防上电 X | ✅ 模块本身正确 |
| `sync_input` 的多比特纪律 | `sync_input.v:32,42` | 模块**允许** `W>1`（整总线同步 = 错），但**全部例化都是 `W(1)`**：`top.v:576` · `top.v:638` · `adc_farm.sv:90`（在 `generate` 里**逐片**） | ✅ **无实际多比特误用** |
| `uart_rx` 的 2 级同步 + 中点采样 | `uart_rx.v:111-119,143-158` | 2 FF 同步（复位值 1 = 空闲）；起始位中点复检（`START_MID = 49`）；数据位在 `MID_CNT = 50` 采样 | ✅ 逻辑正确（⚠️ 缺 `async_reg` 见 P1-04） |
| `uart_rx` 的同步器延迟补偿 | `uart_rx.v:135,156` | `rx_d2` 比 `rx_i` 晚 **2 clk**；位宽 **100 clk** ⇒ 采样点偏移 **2%**，远在 ±50% 容限内 | ✅ 不需要补偿 |
| `i2s_tx` 的 WS/数据边沿 | `i2s_tx.v:178-182` | `HP_BCK` 复位值 = **1** ⇒ 数据在下降沿变、DAC 在上升沿采 ⇒ **建立 8 clk = 160 ns / 保持 8 clk = 160 ns**；位周期 16 clk = 320 ns | ✅ 理想值 |
| `i2s_tx` 的 `d16_l` 陷阱 | `i2s_tx.v:191-198` | 帧边界**直接用 `sample_l`**（⛔ 不用 `d16_l`）⇒ 避免"连续赋值晚一个 delta"的仿真/综合不一致 | ✅ 已修且注释完备 |
| WS2812 帧装载无撕裂 | `top.v:5019-5045` | 逐拍追踪：`WLS_WAIT` 判 `!ws_busy` → 16 拍写完 `mem[0..15]`（**含 `mem[15]`**）→ `WLS_START` 发 1 拍 `ws_start`；传输 476 µs + 复位 400 µs 期间**不写 `mem`** | ✅ **无撕裂** |
| WS2812 位时序 | `ws2812_driver.v:59-62,130` | T0H = 17 clk = **340 ns**（spec 350±150）；T1H = 35 clk = **700 ns**（spec 700±150）；BIT_CYC = 62 clk = **1240 ns**（spec 1250±600）；RST = 20000 clk = **400 µs**（spec ≥300） | ✅ 全部在 spec 内（⚠️ 引脚组合见 P1-08） |
| `waveform_scope` 的 RAM 覆写余量 | `waveform_scope.v:3-4,15,21-31` | 源速率 = 1 样本/1024 clk = **48.828 kHz**；拷贝 640 个 `pixel_clk` = **25.6 µs** ⇒ 期间只写入 **≈1.25 个样本**；1024 深度 ⇒ 余量 **≈800 个样本（16 ms）** | ✅ 注释的"384-sample margin"**结论正确**（⛔ 我按 50 MHz 误算过一次，已纠正） |
| `waveform_scope` 的读管线对齐 | `waveform_scope.v:83-105` | `history_q` 在 N+1 落盘、`frame_y` 用 N 拍的值 + `copy_index_q`(N)=`copy_index`(N−1) ⇒ **地址与数据同代** | ✅ 管线正确 |
| `waveform_scope` 的未初始化 RAM | `waveform_scope.v:19-20,89` | `history[]` 不复位 ⇒ 首帧读到 X，但 `copy` 由 `full_sync` 门控、显示由 `frame_ready` 门控 | ✅ 不会外泄 X |
| `adc_farm` 的 MISO 同步 | `adc_farm.sv:85-95` | **每片独立** `sync_input #(.W(1), .STAGES(2))`，有 `async_reg` | ✅ 正确（符合 K-06/K-62） |
| `adc_farm` 的 SCLK 边沿检测 | `adc_farm.sv:123-131` | `sclk_rise`/`cs_fall` 都用"打一拍再比"⇒ **无毛刺**（不是纯组合边沿检测） | ✅ 结构正确（⚠️ 与 driver 差 1 拍见 P2-02） |
| `mcp3208_driver` 的 SCLK | `mcp3208_driver.sv:106-147` | `adc_sclk` 是**寄存输出**（⛔ 不是门控时钟）；`HALF_DIV=25` ⇒ 1 MHz；24 bit/通道 ⇒ **24.5 µs**；8 通道 = 196 µs | ✅ 无毛刺、频率正确 |
| `adc_farm` 的 `sample_data` 别名越界 | `adc_farm.sv:203-214` | `N_ADC=2` 时 `sample_data2` 走 `generate` 的 `else` 分支给 `12'd0` | ✅ K-89 已修 |
| `axis_snapshot` 的快照时机 | `axis_snapshot.v:132-151` | 在"新帧第一个 `sample_valid` 且 `sample_ch==0`"时 `prev <= cur` ⇒ 前两版"`delta` 恒 0"的缺陷已修 | ✅ 逻辑正确 |
| `axis_snapshot` 的 `delta` 位宽 | `axis_snapshot.v:49-51,211-212` | `DW = POS_W+1 = 13`；两侧先零扩展到 13 位再减 ⇒ 可表示 **[-4095,+4095]** | ✅ 无溢出 |
| `debounce` 的"先同步再去抖" | `debounce.sv:9-12` + `top.v:575,637` | 两个实例（`timbre_btn`/`pedal_sus`）**都**先过 `sync_input` | ✅ 顺序正确 |
| `debounce` 的 Z-safe | `top.v:572,634` | `(x === 1'b0) ? 1'b0 : 1'b1` ⇒ 未连接（`Z`）按"未按下/未踩" | ✅ 现有 tb 无需改 |
| `async_pluck_capture` 的不应期语义 | `async_pluck_capture.v:44-49` + `top.v:3200-3202` | 不应期**只在接受第一个沿之后**才开始 ⇒ **不延迟首次拨弦** | ✅ 语义正确（⚠️ 方向判定见 P1-03） |
| `uart_tx_fifo` 的 `cnt` 单点赋值 | `uart_tx_fifo.v:196-201` | `case({take_now,push_ok})` ⇒ 同拍"取+推"净 0（修掉了"每个回包多 1 字节"） | ✅ 已修 |
| `uart_tx_fifo` 的 `can_launch` | `uart_tx_fifo.v:111` | 同时看 `~empty & ~sending & ~busy_i` ⇒ 不会在 `uart_tx` 忙时取字节 | ✅ 已修 |
| `uart_tx` 的位序 | `uart_tx.v:193-216` | `BIT_START`→`D0`；`4'd1..7`→`D1..D7`；`4'd8`→**停止位**；`BIT_STOP`→收工 ⇒ **每帧恰好 10 位** | ✅ 已修（D7 重发已删） |
| `uart_tx_fifo` 的 `idle_o` 语义 | `uart_tx_fifo.v:129` | `empty & ~sending & ~busy_i` ⇒ 上游据此"一包一包发" | ✅ 语义正确 |
| `pos_probe` 的收尾拍 | `pos_probe.v:119,298-305` | 独立的 `S_DONE` 拍 ⇒ 不会多发 1 字节（修掉 `P52900\r\nP`） | ✅ 已修 |
| `pos_probe` 的 `idle_i` 门控 | `pos_probe.v:227-237` | 开新包**必须** `probe_req_i && idle_i` ⇒ 包与包干净分开 | ✅ 已修 |
| `evt_uart_rx` 的"不扫描"原则 | `evt_uart_rx.v:20-28,175-187` | 只在 `idx_q==0` 看 `0xA5`；失步靠空闲归位 + PC 重发 | ✅ 模块本身正确（⚠️ 共用线的注入见 P0-03） |
| `evt_uart_rx` 的空闲归位 | `evt_uart_rx.v:211-220` | `idle_expired && idx_q!=0` ⇒ 归位并 `resync_cnt_o++` | ✅ 幂等 |
| `calib_cmd` 的命令字母查重 | `calib_cmd.v:526-547` | `initial` 里逐个比对 `cmd_tab[ci] == HEADER` ⇒ 帧头不会被当命令 | ✅ 自检完备（⚠️ 用 `$display` 见 P3-02） |
| `evt_merge` 的深度依据 | `evt_merge.v:37-44` + `top.v:3910-3917` | 3 源各 ≤1 条/拍 ⇒ `DEPTH≥3`，取 **6**；溢出 sticky + `drop_cnt_o` | ✅ 深度正确且有可观测 |
| `seq_arb` 的深度 | `top.v:3677` | `.DEPTH(6)`，3 源各 ≤1 条/拍 | ✅ |
| `looper` 的 `live_busy` 避让 | `top.v:4113-4115` | looper 内部主动避让手弹流 ⇒ `vu_valid_r ? ... : ...` 的 mux 只是兜底 | ✅ 结构正确 |
| `tlc5916_driver` 的 OE 防护 | `tlc5916_driver.sv:17-25,162,267` | 双防护：`OE_STABLE=25` 拍稳定窗（= **500 ns** ≥ 手册 `tw(OE)`）+ **只在 `state==IDLE && le==0 && clk==0` 时更新 OE** | ✅ 结构上不可能进 Special Mode |
| `tlc5916_driver` 的恢复序列 | `tlc5916_driver.sv:100-131,240-241` | 复位后**一次性**发 1 个 CLK 宽的 OE 低脉冲（**1000 ns** ≥ 500 ns）且全程 `LE` 低 ⇒ 切回 Normal Mode | ✅ 符合手册 Figure 16 |
| `tlc5916_bank` 的 OE 安全态 | `tlc5916_bank.sv:198-207` | `oe_n_r = {OE_N{1'b1}}`（默认全灭）⇒ `if (X==0)` 判假 ⇒ 保留默认 ⇒ **上电全灭** | ✅ 安全 |
| `led_data` 的变化检测 | `led_data.v:92,101` | `pattern_r !== pattern_next` ⇒ 只在真变化时提交 | ✅ |
| `led_indicator` 的无锁存 | `led_indicator.v:132-137` | `always @*` 里**先**给全部元素赋默认值，再 case 覆盖 | ✅ 无锁存 |
| `led_indicator` 的共享闪烁计数器 | `led_indicator.v:109-115` | `FAST_DIV=23` ⇒ 半周期 2²² = **4.19 M 拍 = 83.9 ms** ⇒ **≈6 Hz** | ✅ 与注释一致 |
| `top` 的 `set_false_path -from rst_n` 范围 | `top.sdc:71` + `top.v:511-515` | `rst_n` 在顶层**只**接 `u_rst_sync.rst_n_async`（`hdmi_scope` 拿的是 `rst_n_sync`） | ✅ false_path 范围正确 |
| `top` 的 `PA_EN_n` 安全态 | `top.v:4738-4745` | `g_pa_on` 档**恒高**（复位期也是高）⇒ `SD_MODE` = Left ⇒ 出声；`.cst` 的 `PULL_MODE=UP` 覆盖配置期 | ✅ 符合 U-25b |
| `top` 的 `pos_to_vel` 位宽 | `top.v:1181-1207` | `p22` 显式零扩展到 **22 位**；`4095×263 = 1 076 985 < 2²¹` ⇒ 不溢出；`v13` 取 13 位（⛔ 不是 9 位）⇒ 两种标定档都能正确饱和 | ✅ 位宽纪律正确 |
| `top` 的 `at_en_ready` 延迟 | `top.v:1920-1927` | 16 拍延迟（320 ns）⇒ 修掉"`zero` 生效前用脏 `pos` 判键 ⇒ 8 个 note_on 恒响" | ✅ 已修且证据完备 |
| `top` 的 `cal_ch_mux` 组合环 | `top.v:2373` | 已用 `sp_busy_r`（寄存器）打断 | ✅ 已修（⚠️ 残留见 P2-05） |
| `oscillator_bank` 的 CDC 出口 | `oscillator_bank.v:329,881` | `vibrato_mod_r <= vibrato_mod_i`（**寄存**）；`assign osc_sample_bus_o = sample_bus_r`（**寄存**） | ✅ **不是**组合穿透（历史最差路径已消除） |
| `vibrato_lfo` → `oscillator_bank` 的边界 | `vibrato_lfo.v:128` + `oscillator_bank.v:329` | `mod_o` 是组合输出，但**立即被 `vibrato_mod_r` 寄存** ⇒ 跨模块链只有 1 级 mux | ✅ 边界干净（扇出 = 1×16 位） |
| `tdm_render_mixer` 的输入总线 | `oscillator_bank.v:881` | `osc_sample_bus_o` 是寄存器输出 | ✅ 不是组合穿透 |
| 全部 `assign` 到引脚的路径 | `top.v:4723-4725,4911,4957-4958` | `spi_sclk`/`spi_mosi`/`spi_cs_n` 来自 `adc_farm` 的**寄存**输出；`led_sdi/led_clk/led_le` 来自 `tlc5916_driver` 的**寄存**输出 | ✅ 除 `ctrl_ws_o`（P1-08）与 `led_oe_n`（直流）外，引脚均为寄存输出 |
| 门控时钟 | `grep -r "always @(posedge" rtl/` 全部使用 `clk`/`clk_i`/`pixel_clk`/`serial_clk` | **没有任何派生/门控时钟**（`adc_sclk`/`tlc_clk` 只是外部协议信号，⛔ 不当内部时钟） | ✅ 符合冻结表约定 1 |

---

## 附录 C · 本次审计**没有覆盖**的面（诚实声明）

| 未覆盖项 | 原因 | 建议 |
|---|---|---|
| `note_manager` T3 旋转器的**功能**正确性 | 本报告只做 CDC/时序/复位；功能正确性属 `A3`/`N4` 家族 | 已有 `tb_note_manager*` |
| `tdm_render_mixer` 的**限幅器数学** | 同上 | 已有 `tb_tdm_render_mixer` |
| `looper` 的**事件压缩/插值算法** | 同上 | 已有 `tb_looper*` |
| `drum_gen`/`metronome` 的**节奏型表** | 同上 | 已有 `tb_key_drum`/`tb_met_start_top` |
| `wavetable_bank` 的 ROM 内容 | 与 CDC 无关 | — |
| `.cst` 的引脚/电平合法性 | 属硬件核对，非 CDC | `sim/evidence/*/pnr-rpt.txt` 的 Port Name 表 |
| 变异测试覆盖 | 需 ~5 小时（`bringup/mutation_test.ps1`） | ⚠️ 本报告未跑 |

---

**报告结束。** 共 **27 条**：**P0 × 4** · **P1 × 10** · **P2 × 8** · **P3 × 5**；
附录 B 记录 **50 项已核对且干净**；附录 C 声明 7 项未覆盖面。
