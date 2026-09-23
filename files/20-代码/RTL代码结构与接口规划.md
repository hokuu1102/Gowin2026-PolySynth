# Gowin2026 PolySynth RTL 代码结构与接口规划

> 目标：Tang Mega 60K Dock，`clk_sys=50 MHz`，严格 RTL；**音频通路不用 PLL**（⚠️ 准确边界见 `K-41`/`K-114`：⛔ 禁"PLL 做全设计系统时钟"，✅ 外设/相移时钟可用 PLL）、不用硬核 CPU、不用 HLS；工程路径全 ASCII。
> 设计基线：16 轴位，`POLY_TARGET=32`，`OSC_PER_VOICE=2`，至少 2 音色，Test Mode 为正式功能。
> 说明：本文只定义结构、接口、时序契约和验证口径，不给出 RTL 实现。

## 0. 先冻结的结论与对仓库旧资料的异议

| 项 | 本文结论 | 对现有资料的处理 |
|---|---|---|
| 内部时钟 | 全部时序逻辑只使用 `clk_50m_i`；MCLK/BCLK/LRCLK/SPI/TLC 时钟均是输出波形或 clock-enable，不作为内部 `always` 时钟 | 延续仓库“单时钟域”原则 |
| 音频时钟 | 锁死 `MCLK=12.5 MHz`、`BCLK=3.125 MHz`、`LRCLK=48.828125 kHz`；不参数化修改 | 按题面覆盖旧文档中任何其他建议 |
| ADC 拓扑 | 3 片 MCP3208 使用 3 组独立 `CS/SCK/MOSI/MISO`；三组可并行扫描 | 覆盖仓库中“3 片 ADC 可共享 SPI 总线”的建议；最新硬件已给每板独立四线 |
| ADC 周期 | 同一通道固定每 `250_000` 个 50 MHz 周期采一次，即 5.000 ms；每片 ADC 的 8 通道在各自固定窗口内顺序转换 | 仓库旧延迟预算按 2 kHz/通道（0.5 ms）计算，已失效 |
| 低延迟触发 | `UP/DOWN` 比较器是唯一可证明 `<5 ms` 的首次发声触发路径；轴位 ADC 是预先缓存的选音/力度/滑音状态 | 若要求“轴位模拟阈值本身→出声 ≤5 ms”，在“轮询间隔 ≥5 ms”约束下最坏值必然超过 5 ms，二者不可同时保证 |
| 可闻振荡器 | 每个计数振荡器必须有独立 `phase_acc`、`phase_inc`、enable/state；加法器和乘法器可 TDM | 按题面评分口径 |
| 波表计数 | 默认采用“每振荡器 lane 一份物理 ROM bank”；不以共享单片波表宣称 32/64 个振荡器 | 对仓库“全 voice 共享波表”的吞吐量宣称提出异议：按题面只能算 1 个波表振荡器 |
| Test Mode | 直接启用同一合成核心中的前 N 个独立 oscillator lane；N 为 4/8/16/32，第二振荡器关闭，保证 N 就是 N 个不同基频 | 不另做一套无法代表正式核心的演示发生器 |
| TLC5916 `OE` | `OE_n` 由独立安全门控模块驱动；只在复位、首帧锁存后或全局灭灯时改变，并保证宽度远大于一个 TLC CLK；绝不用于 PWM | 现有实验驱动把 `outputs_enable` 每个系统周期直接寄存到 `OE_n`，接口本身不能阻止单周期误脉冲；集成前必须加 guard |
| 相位变调 | 更新 `phase_inc`，绝不清零 `phase_acc` | 防止变调咔哒声 |

### 0.1 评分安全的振荡器组织

默认综合配置共有 `OSC_N = POLY_TARGET × OSC_PER_VOICE = 64` 个 oscillator lane。每 lane 具有独立状态和独立 ROM bank：

- 独立：`phase_acc[31:0]`、`phase_inc[31:0]`、lane enable、音色选择、必要的 FM 状态预留；
- 可共享：包络乘法器、主音量乘法器、饱和器和效果器算术单元；
- 波表：默认每 lane 一块 18 Kbit BSRAM，存 2 种音色 × 512 点 × 16 bit（16,384 bit，能装入一块）；
- Test Mode：启用前 N 个 voice，每个 voice 只打开第 0 个 oscillator lane，并给出不同 `phase_inc`；这样 N 同时代表 N 个独立 voice 和 N 个互不重合基频；
- 必须在综合报告中看到对应数量的独立状态寄存器和 ROM bank，防止工具把相同 ROM 合并。若不能证明未合并，则不按 N 个波表振荡器申报。

这一路线比“64 路共享一片波表”多占 BSRAM，但符合题面最保守的统计口径。若主办方后来书面确认“共享 ROM、独立相位也逐路计数”，再提供资源节省配置；在此之前不依赖该解释。

## 1. 模块层次图与职责

```text
polysynth_top
├─ reset_sync                 外部复位异步置位、同步释放，生成全局 rst_n
├─ audio_timebase             50 MHz 计数器生成固定音频相位与各类 enable
├─ adc_farm                   三组独立 MCP3208 总控，5 ms 固定帧
│  └─ mcp3208_scan ×3         各自驱动一组 CS/SCK/MOSI，定点采 MISO
├─ input/                     [目录，无额外 wrapper]
│  ├─ axis_frontend           16 轴标定、迟滞、双模式映射、力度/滑音状态
│  ├─ right_analog_ctrl       摇杆/音量/两推子处理、对数音量、死区迟滞、速率斜坡
│  └─ async_pluck_capture     UP/DOWN 同步、立即边沿捕获、事件后不应期
├─ panel/                     [目录，无额外 wrapper]
│  ├─ ui_spi_arbiter          74HC165 周期采样优先，OLED 分块传输让行
│  ├─ hc165_reader            PL 锁存后移出 4 个按键状态
│  ├─ ec11_decoder            A/B/SW 同步、去抖和增量解码
│  ├─ ui_control              模式/测试/静音/页面与对象环状态机
│  ├─ oled_status             仅渲染状态数据，不做菜单
│  └─ tjc_uart_status         向 TJC 屏发送状态，接收链与演奏链隔离
├─ led/                       [目录，无额外 wrapper]
│  ├─ led_status_map          16 单色键灯和 4 个双色状态灯的位映射
│  ├─ tlc5916_bank            三片发送器的图案提交与状态汇总
│  ├─ tlc5916_tx ×3           只负责 8 bit 移位与 LE 锁存
│  └─ tlc5916_oe_guard ×3     独占 OE_n，禁止窄脉冲和 PWM
├─ synth/                     [目录，无额外 wrapper；正式演奏与 Test Mode 共用下列核心]
│  ├─ voice_manager           确定性分配/抢占/释放及轴位到 voice 关联
│  ├─ test_mode_ctrl          生成 N=4/8/16/32 个不同频率的 lane 配置
│  ├─ vibrato_lfo             FPGA 内生成 1~12 Hz LFO，相位连续
│  ├─ oscillator_bank         64 份独立相位状态与默认 64 份独立 ROM bank
│  ├─ envelope_bank           32 份独立 ADSR 状态，支持起音后力度修正
│  └─ tdm_render_mixer        在固定 1024-cycle 帧内共享乘法/累加并饱和
├─ audio/                     [目录，无额外 wrapper]
│  ├─ master_gain             64 点对数增益后的数字主音量与静音斜坡
│  ├─ audio_fx               可裁剪的短延迟/合唱/简化混响，固定时延旁路
│  └─ pa_enable_guard         I2S 稳定且无故障后才低有效开启功放
├─ i2s_tx                     24-bit 样本装入 32-bit slot，输出 I2S DIN
└─ status_telemetry           汇总 N/音色/八度/模式/故障供 OLED、TJC、调试口
```

一句话职责已经写在树的右侧。模块边界遵守三条原则：采集不等待 UI、UI 不反压合成、效果器关闭或繁忙都不能阻塞干声。

## 2. 接口定义表

### 2.1 全局接口约定

| 项 | 约定 |
|---|---|
| HDL | 建议 SystemVerilog 仅用于参数和断言；跨模块端口使用扁平 packed vector，避免 Gowin 对 unpacked array 支持差异 |
| 时钟 | 所有内部模块只有 `clk_i`，均连接 `clk_50m_i` |
| 复位 | 除 `reset_sync` 外均为 `rst_n_i`，低有效同步复位；输出在复位态进入硬件安全值 |
| 脉冲 | `*_valid_o`、`*_done_o`、`*_tick_o` 均为一个 50 MHz 周期 |
| 配置快照 | 多字段总线先写 shadow register，再以单周期 `*_commit` 原子生效，禁止字段撕裂 |
| 流接口 | 单样本链使用 `valid`，不得反压；每帧必须在 deadline 前完成，否则拉高 sticky fault |
| 位序 | packed bus 第 `k` 项固定放在 `[k*W +: W]`；ADC 索引 `0=左板0, 1=左板1, 2=右板A` |
| 数值 | 音频为二补码；主音量 `Q1.15`；LFO 调制量为有符号 `Q1.15`；相位为无符号 32 bit 环形量 |

### 2.2 顶层物理端口：`polysynth_top`

除音频 4 根已知 ball 外，其余只冻结逻辑端口名；CST ball 必须在拿到最终 Dock/转接板连线后填写。

| 端口名 | 方向 | 位宽 | 时钟域/采样方式 | 复位安全值 | 谁驱动 → 谁采样 |
|---|---:|---:|---|---|---|
| `clk_50m_i` | in | 1 | 50 MHz 根时钟 | — | Dock 晶振 → 全设计；官方 60K 示例候选 `V22/LVCMOS33`，最终以实板版本 CST 复核 |
| `rst_async_n_i` | in | 1 | 异步输入 | 0 有效 | 复位源（引脚待确认）→ `reset_sync` |
| `i2s_bclk_o` | out | 1 | 50 MHz 寄存输出，3.125 MHz | 0 | `audio_timebase` → Dock DAC，Y17 |
| `i2s_lrck_o` | out | 1 | 50 MHz 寄存输出，48.828125 kHz | 0 | `audio_timebase` → Dock DAC，AB17 |
| `i2s_din_o` | out | 1 | 在 BCLK 安全相位更新 | 0 | `i2s_tx` → Dock DAC，AA16 |
| `pa_en_n_o` | out | 1 | 50 MHz | 1（功放关） | `pa_enable_guard` → Dock 功放，AB16，低有效 |
| `adc_cs_n_o[2:0]` | out | 3 | 三组独立 SPI | 3'b111 | `adc_farm` → 3 片 MCP3208 |
| `adc_sck_o[2:0]` | out | 3 | 三组独立 SPI，注册输出 | 0 | `adc_farm` → 3 片 MCP3208 |
| `adc_mosi_o[2:0]` | out | 3 | 三组独立 SPI | 0 | `adc_farm` → 3 片 MCP3208 DIN |
| `adc_miso_i[2:0]` | in | 3 | 本方 SCK 源同步返回，定相位采样 | — | 3 片 MCP3208 DOUT → `adc_farm` |
| `pluck_up_i` | in | 1 | 异步，2FF + 边沿 | — | LM393 UP → `async_pluck_capture` |
| `pluck_down_i` | in | 1 | 异步，2FF + 边沿 | — | LM393 DOWN → `async_pluck_capture` |
| `enc_a_i`,`enc_b_i`,`enc_sw_n_i` | in | 各1 | 异步，2FF + 去抖 | — | EC11 → `ec11_decoder` |
| `ui_spi_sck_o` | out | 1 | UI 共享 SPI，注册输出 | 0 | `ui_spi_arbiter` → OLED/74HC165 |
| `ui_spi_mosi_o` | out | 1 | UI 共享 SPI | 0 | `ui_spi_arbiter` → OLED SDA/MOSI |
| `oled_cs_n_o` | out | 1 | UI SPI | 1 | `ui_spi_arbiter` → OLED |
| `oled_dc_o` | out | 1 | UI SPI | 0 | `oled_status` → OLED |
| `oled_rst_n_o` | out | 1 | 50 MHz 定时 | 0 | `oled_status` → OLED |
| `hc165_pl_n_o` | out | 1 | 74HC165 捕获脉冲 | 1 | `hc165_reader` → 74HC165 `/PL` |
| `hc165_q_i` | in | 1 | 本方 SCK 源同步返回 | — | 74HC165 QH → `hc165_reader` |
| `tlc_clk_o[2:0]` | out | 3 | 三片独立串行时钟 | 0 | `tlc5916_tx` → 左0/左1/右B TLC |
| `tlc_sdi_o[2:0]` | out | 3 | TLC 串行数据 | 0 | `tlc5916_tx` → 三片 TLC SDI |
| `tlc_le_o[2:0]` | out | 3 | 8 bit 后宽锁存脉冲 | 0 | `tlc5916_tx` → 三片 TLC LE |
| `tlc_oe_n_o[2:0]` | out | 3 | 只由 guard 慢速改变 | 3'b111 | `tlc5916_oe_guard` → 三片 TLC OE |
| `tjc_uart_tx_o` | out | 1 | UART | 1 | `tjc_uart_status` → TJC RX |
| `tjc_uart_rx_i` | in | 1 | 异步 UART，2FF 后过采样 | — | TJC TX → `tjc_uart_status` |
| `evt_flag_o` | out | 1 | 同步后的拨弦事件标志 | 0 | `async_pluck_capture` → 示波器 TP |
| `deadline_fault_o` | out | 1 | sticky 诊断 | 0 | `tdm_render_mixer` → TP/状态显示 |

注：题面没有给 `I2S_MCLK` ball。本文仍按 MCLK 比例生成内部 `mclk_phase`，但不凭空增加物理 MCLK 输出；如果板载 DAC 实际需要外部 MCLK，必须补充 ball 后才能加顶层端口。

### 2.3 时基与采集层

| 模块 | 端口名 | 方向/位宽 | 域/复位 | 驱动 → 采样 |
|---|---|---|---|---|
| `reset_sync` | `clk_i` | in/1 | 50 MHz | top → 本模块 |
|  | `arst_n_i` | in/1 | 异步置位 | 外部复位源 → 本模块 |
|  | `rst_n_o` | out/1 | 异步拉低、同步拉高 | 本模块 → 全模块 |
| `audio_timebase` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | top/reset → 本模块 |
|  | `frame_phase_o` | out/10 | 50 MHz | 本模块 → render/i2s |
|  | `sample_tick_o` | out/1 | 每 1024 clk 一拍 | 本模块 → synth/audio |
|  | `mclk_o`,`bclk_o`,`lrck_o` | out/各1 | 注册输出 | 本模块 → 顶层引脚/`i2s_tx` |
|  | `bclk_rise_o`,`bclk_fall_o` | out/各1 | clock-enable | 本模块 → `i2s_tx` |
| `mcp3208_scan` ×3 | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `frame_start_i` | in/1 | 固定每 5 ms 一拍 | `adc_farm` → 本模块 |
|  | `miso_i` | in/1 | 源同步返回，中心采样 | MCP3208 → 本模块 |
|  | `cs_n_o`,`sck_o`,`mosi_o` | out/各1 | 注册 SPI 输出 | 本模块 → 对应 MCP3208 |
|  | `sample_valid_o` | out/1 | 单周期 | 本模块 → `adc_farm` |
|  | `sample_ch_o` | out/3 | 与 valid 同拍 | 本模块 → `adc_farm` |
|  | `sample_data_o` | out/12 | 与 valid 同拍 | 本模块 → `adc_farm` |
|  | `scan_done_o`,`scan_fault_o` | out/各1 | pulse/sticky | 本模块 → `adc_farm/status` |
| `adc_farm` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `adc_miso_i[2:0]` | in/3 | 三组源同步返回 | 顶层 → 本模块 |
|  | `adc_cs_n_o`,`adc_sck_o`,`adc_mosi_o` | out/各3 | 三组独立 SPI | 本模块 → 顶层 |
|  | `adc_raw_o` | out/288 | 3×8×12 packed 快照 | 本模块 → `axis_frontend`/`right_analog_ctrl` |
|  | `adc_commit_o` | out/1 | 每 5 ms 原子提交 | 本模块 → `axis_frontend`/`right_analog_ctrl` |
|  | `adc_fault_o[2:0]` | out/3 | sticky | 本模块 → status |

`frame_start_i` 对三片 ADC 同时发出；因为物理线独立，不存在 MISO 双驱和多 CS 互斥。若为 EMI 将三组错开，偏移必须是编译期固定常数，且每通道重访周期仍严格为 250,000 个系统周期。

### 2.4 控制前端

| 模块 | 端口名 | 方向/位宽 | 域/复位 | 驱动 → 采样 |
|---|---|---|---|---|
| `axis_frontend` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `adc_commit_i` | in/1 | 5 ms 快照脉冲 | `adc_farm` → 本模块 |
|  | `axis_raw_i` | in/192 | 左两 ADC，16×12 | `adc_farm` → 本模块 |
|  | `map_mode_i` | in/1 | 0键盘/1指板 | `ui_control` → 本模块 |
|  | `octave_i` | in/signed 4 | 原子配置 | `ui_control` → 本模块 |
|  | `key_mask_o` | out/16 | 稳态快照 | 本模块 → `voice_manager`/LED |
|  | `phase_inc_bus_o` | out/512 | 16×32 | 本模块 → `voice_manager` |
|  | `velocity_bus_o` | out/128 | 16×8 | 本模块 → `voice_manager` |
|  | `axis_commit_o` | out/1 | 原子快照有效 | 本模块 → `voice_manager` |
|  | `axis_changed_o` | out/16 | 与 commit 同拍 | 本模块 → `voice_manager` |
| `right_analog_ctrl` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `adc_commit_i` | in/1 | 5 ms 快照脉冲 | `adc_farm` → 本模块 |
|  | `right_raw_i` | in/96 | 右 ADC，8×12 | `adc_farm` → 本模块 |
|  | `joy_pos_o` | out/12 | CH0 滤波值 | 本模块 → `voice_manager/status` |
|  | `master_gain_o` | out/16 Q1.15 | CH1 高 6 bit 经 64 点对数 LUT | 本模块 → `master_gain` |
|  | `vib_depth_o` | out/16 Q1.15 | CH2，死区+迟滞 | 本模块 → `vibrato_lfo` |
|  | `vib_rate_inc_o` | out/32 | CH3 映射 1~12 Hz，斜率限制 | 本模块 → `vibrato_lfo` |
|  | `param_commit_o` | out/1 | 原子参数提交 | 本模块 → synth/status |
| `async_pluck_capture` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `up_async_i`,`down_async_i` | in/各1 | 异步，独立 2FF | LM393 → 本模块 |
|  | `pluck_valid_o` | out/1 | 首边沿单周期 | 本模块 → `voice_manager` |
|  | `pluck_dir_o` | out/1 | 0=down,1=up | 本模块 → `voice_manager` |
|  | `evt_flag_o` | out/1 | 与 accepted event 同拍 | 本模块 → TP |
|  | `refractory_o` | out/1 | 诊断 | 本模块 → status |

拨弦不做“先等待稳定再触发”的去抖；第一条同步边沿立即产生事件，随后进入固定不应期屏蔽重复边沿。这样不应期不会增加首次触发延迟。

### 2.5 人机、显示与 LED

| 模块 | 端口名 | 方向/位宽 | 域/复位 | 驱动 → 采样 |
|---|---|---|---|---|
| `hc165_reader` | `clk_i`,`rst_n_i`,`poll_tick_i` | in/各1 | 50 MHz/同步低复位 | arb/timebase → 本模块 |
|  | `qh_i` | in/1 | 本方 SCK 源同步返回 | 74HC165 → 本模块 |
|  | `req_o`,`grant_i` | out/in 1 | 仲裁握手 | 本模块 ↔ `ui_spi_arbiter` |
|  | `sck_o`,`pl_n_o` | out/各1 | 仅 grant 时有效 | 本模块 → arbiter |
|  | `buttons_o` | out/4 | 去抖前原始并行值 | 本模块 → `ui_control` |
|  | `buttons_valid_o` | out/1 | 一轮移位完成 | 本模块 → `ui_control` |
| `ec11_decoder` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `a_async_i`,`b_async_i`,`sw_async_n_i` | in/各1 | 2FF + 去抖 | EC11 → 本模块 |
|  | `step_valid_o`,`step_dir_o`,`press_o` | out/各1 | 单周期 | 本模块 → `ui_control` |
| `ui_control` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `buttons_i` | in/4 | 已去抖 | `hc165_reader` → 本模块 |
|  | `enc_step_valid_i`,`enc_step_dir_i`,`enc_press_i` | in/各1 | 单周期 | `ec11_decoder` → 本模块 |
|  | `map_mode_o`,`test_mode_o`,`mute_o`,`slider_page_o` | out/各1 | 状态寄存器 | 本模块 → 各消费者 |
|  | `timbre_id_o` | out/`TIMBRE_W` | 运行时音色 | 本模块 → synth/status |
|  | `octave_o` | out/signed 4 | 运行时八度 | 本模块 → axis/status |
|  | `test_n_code_o` | out/2 | 00/01/10/11→4/8/16/32 | 本模块 → test/status |
|  | `selected_obj_o` | out/2 | 音色/八度/N | 本模块 → status |
| `oled_status` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `status_bus_i` | in/64 | 原子状态快照 | telemetry → 本模块 |
|  | `req_o`,`grant_i`,`byte_ready_i` | handshake | UI SPI | 本模块 ↔ arbiter |
|  | `byte_valid_o`,`byte_o`,`dc_o`,`cs_n_o`,`last_o` | out/1,8,1,1,1 | OLED 分块字节流 | 本模块 → arbiter |
|  | `rst_n_o` | out/1 | OLED 复位时序 | 本模块 → 顶层 |
| `ui_spi_arbiter` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `hc_*`,`oled_*` | 双向握手组 | 50 MHz | 两 master ↔ 本模块 |
|  | `spi_sck_o`,`spi_mosi_o`,`oled_cs_n_o`,`oled_dc_o`,`hc_pl_n_o` | out/各1 | 注册输出 | 本模块 → 顶层 |
|  | `hc_q_i` | in/1 | 固定采样相位 | 顶层 → 本模块 |
| `tjc_uart_status` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `rx_async_i` | in/1 | 2FF + UART 过采样 | TJC → 本模块 |
|  | `tx_o` | out/1 | UART | 本模块 → TJC |
|  | `status_bus_i`,`status_commit_i` | in/64,1 | 非阻塞快照 | telemetry → 本模块 |
|  | `rx_cmd_valid_o`,`rx_cmd_o` | out/1,16 | 仅 UI 命令 | 本模块 → `ui_control`，不得进音频事件直通 |
| `led_status_map` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `key_mask_i`,`status_bus_i` | in/16,64 | 状态快照 | input/telemetry → 本模块 |
|  | `pattern_o` | out/24 | 3×8 bit | 本模块 → `tlc5916_bank` |
|  | `pattern_commit_o` | out/1 | 低速更新 | 本模块 → `tlc5916_bank` |
| `tlc5916_bank` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `pattern_i`,`pattern_commit_i` | in/24,1 | 原子图案 | map → 本模块 |
|  | `global_blank_i` | in/1 | 慢速状态 | UI/fault → OE guard |
|  | `tlc_clk_o`,`tlc_sdi_o`,`tlc_le_o`,`tlc_oe_n_o` | out/各3 | 三片独立链路 | 本模块 → 顶层 |
|  | `busy_o`,`fault_o` | out/3,3 | 状态/sticky | 本模块 → telemetry |
| `tlc5916_tx` ×3 | `clk_i`,`rst_n_i`,`start_i` | in/各1 | 50 MHz/同步低复位 | bank → 本模块 |
|  | `data_i` | in/8 | start 时锁存 | bank → 本模块 |
|  | `tlc_clk_o`,`tlc_sdi_o`,`tlc_le_o` | out/各1 | LE 在8 bit后才拉高 | 本模块 → 对应 TLC |
|  | `busy_o`,`done_o` | out/各1 | level/pulse | 本模块 → bank/guard |
| `tlc5916_oe_guard` ×3 | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `enable_req_i`,`first_latch_done_i`,`tx_busy_i` | in/各1 | 慢速请求/发送状态 | bank/tx → 本模块 |
|  | `oe_n_o` | out/1 | 复位为1；只在 CLK=0、LE=0、非发送窗口改变 | 本模块 → 对应 TLC OE |
|  | `oe_fault_o` | out/1 sticky | 检出非法快速请求 | 本模块 → telemetry |

UI SPI 仲裁为严格优先级但有界：74HC165 每 1 ms 获得一次固定短时隙；OLED 每发送最多 16 byte 必须让行一次。任何 OLED 刷屏都不能推迟按键采样，也不能占用演奏链资源。

### 2.6 合成核心

| 模块 | 端口名 | 方向/位宽 | 域/复位 | 驱动 → 采样 |
|---|---|---|---|---|
| `voice_manager` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `axis_commit_i`,`key_mask_i`,`axis_changed_i` | in/1,16,16 | 5 ms 原子快照 | axis → 本模块 |
|  | `phase_inc_bus_i`,`velocity_bus_i` | in/512,128 | 与 commit 对齐 | axis → 本模块 |
|  | `pluck_valid_i`,`pluck_dir_i`,`joy_pos_i` | in/1,1,12 | 低延迟事件+缓存参数 | pluck/analog → 本模块 |
|  | `test_mode_i` | in/1 | 模式 | UI → 本模块 |
|  | `voice_active_o`,`voice_gate_o` | out/各`POLY_TARGET` | 独立状态 | 本模块 → env/osc |
|  | `voice_axis_o` | out/`POLY_TARGET*4` | 每 voice 源轴 | 本模块 → osc/status |
|  | `voice_phase_inc_o` | out/`POLY_TARGET*32` | 每 voice 基频 | 本模块 → osc |
|  | `voice_velocity_o` | out/`POLY_TARGET*8` | 每 voice 力度 | 本模块 → envelope |
|  | `voice_age_o` | out/`POLY_TARGET*16` | 抢占年龄 | 本模块内部/诊断 |
| `test_mode_ctrl` | `clk_i`,`rst_n_i`,`sample_tick_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `enable_i`,`n_code_i` | in/1,2 | UI 状态 | UI → 本模块 |
|  | `test_voice_gate_o` | out/`POLY_TARGET` | 前 N voice gate=1 | 本模块 → envelope 输入 mux |
|  | `test_velocity_o` | out/`POLY_TARGET*8` | 前 N voice 固定可听力度 | 本模块 → envelope 输入 mux |
|  | `test_lane_active_o` | out/`OSC_N` | 前 N voice 的 lane0=1，其余 lane=0 | 本模块 → osc mux |
|  | `test_phase_inc_o` | out/`OSC_N*32` | N 个 lane0 使用不同基频 | 本模块 → osc mux |
|  | `active_n_o` | out/6 | 4/8/16/32 | 本模块 → OLED/TJC |
| `vibrato_lfo` | `clk_i`,`rst_n_i`,`sample_tick_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `rate_inc_i` | in/32 | 斜率限制后速率 | analog → 本模块 |
|  | `depth_i` | in/16 Q1.15 | 死区迟滞后深度 | analog → 本模块 |
|  | `mod_o` | out/signed 16 Q1.15 | 每样本更新 | 本模块 → oscillator bank |
| `oscillator_bank` | `clk_i`,`rst_n_i`,`sample_tick_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `voice_active_i` | in/`POLY_TARGET` | 正式 voice 状态 | manager → 本模块 |
|  | `base_phase_inc_i` | in/`POLY_TARGET*32` | 基频 | manager → 本模块 |
|  | `timbre_id_i` | in/`TIMBRE_W` | 运行时音色 | UI → 本模块 |
|  | `vibrato_mod_i` | in/signed 16 | 相位连续调制 | LFO → 本模块 |
|  | `test_mode_i`,`test_lane_active_i`,`test_phase_inc_i` | in/1,`OSC_N`,`OSC_N*32` | Test 覆盖 | test → 本模块 |
|  | `fm_cfg_valid_i`,`fm_ratio_i`,`fm_index_i` | in/1,16,16 | 预留，`ENABLE_FM=0` 时忽略 | config → 本模块 |
|  | `osc_sample_bus_o` | out/`OSC_N*OSC_SAMPLE_W` | 每 lane 原始波形 | 本模块 → mixer |
|  | `osc_valid_o` | out/1 | 固定延迟 | 本模块 → mixer |
|  | `phase_acc_dbg_o` | out/32 | 选定 lane 调试 | 本模块 → telemetry |
| `envelope_bank` | `clk_i`,`rst_n_i`,`sample_tick_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `gate_i` | in/`POLY_TARGET` | 每 voice gate | manager → 本模块 |
|  | `velocity_i` | in/`POLY_TARGET*8` | 可在起音后修正 | manager → 本模块 |
|  | `env_level_o` | out/`POLY_TARGET*16` | 每 voice Q1.15 | 本模块 → mixer |
|  | `env_active_o` | out/`POLY_TARGET` | 尾音状态 | 本模块 → manager/status |
| `tdm_render_mixer` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `render_start_i` | in/1 | 每样本固定相位 | timebase → 本模块 |
|  | `osc_sample_bus_i` | in/`OSC_N*OSC_SAMPLE_W` | 稳定至本帧结束 | osc → 本模块 |
|  | `env_level_i` | in/`POLY_TARGET*16` | 稳定至本帧结束 | env → 本模块 |
|  | `dry_valid_o` | out/1 | 固定周期产生 | 本模块 → audio post |
|  | `dry_sample_o` | out/signed 24 | 饱和后单声道 | 本模块 → audio post |
|  | `deadline_fault_o` | out/1 sticky | 未在 cycle 927 前完成 | 本模块 → 顶层/status |

`voice_manager` 的确定性抢占顺序固定为：空闲 voice → 已进入 Release 且电平最低 → 年龄最老；并列时取最低索引。禁止用可变长搜索；候选比较树固定拍数。

### 2.7 后处理与 I2S

| 模块 | 端口名 | 方向/位宽 | 域/复位 | 驱动 → 采样 |
|---|---|---|---|---|
| `master_gain` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `sample_valid_i`,`sample_i` | in/1,signed24 | 单样本流 | mixer/fx → 本模块 |
|  | `gain_i` | in/16 Q1.15 | 64 点对数映射结果 | analog → 本模块 |
|  | `mute_i` | in/1 | 运行时静音 | UI/fault → 本模块 |
|  | `sample_valid_o`,`sample_o` | out/1,signed24 | 固定流水线 | 本模块 → fx/i2s |
| `audio_fx` | `clk_i`,`rst_n_i`,`sample_tick_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `sample_valid_i`,`dry_i` | in/1,signed24 | 单样本流 | master gain → 本模块 |
|  | `fx_enable_i`,`fx_mix_i` | in/1,8 | 配置 | UI/config → 本模块 |
|  | `sample_valid_o`,`wetmix_o` | out/1,signed24 | 固定 1 sample 延迟，旁路同延迟 | 本模块 → i2s |
|  | `fx_fault_o` | out/1 sticky | 诊断 | 本模块 → status |
| `i2s_tx` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `frame_phase_i`,`bclk_rise_i`,`bclk_fall_i` | in/10,1,1 | enable，不是新时钟域 | timebase → 本模块 |
|  | `sample_valid_i`,`left_i`,`right_i` | in/1,signed24,signed24 | 帧边界装载 | audio fx → 本模块 |
|  | `din_o` | out/1 | 标准 I2S，32-bit slot | 本模块 → 顶层 DAC |
|  | `underrun_o` | out/1 sticky | 缺样本诊断 | 本模块 → status |
|  | `stream_locked_o` | out/1 | 连续有效零/音频帧达到固定门限 | 本模块 → `pa_enable_guard` |
| `pa_enable_guard` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `stream_locked_i`,`mute_i`,`fatal_fault_i` | in/各1 | 安全条件 | i2s/UI/status → 本模块 |
|  | `pa_en_n_o` | out/1 | 复位/静音/故障为1；延时后才为0 | 本模块 → 顶层 AB16 |
| `status_telemetry` | `clk_i`,`rst_n_i` | in/各1 | 50 MHz/同步低复位 | 全局 → 本模块 |
|  | `mode_i`,`test_mode_i`,`mute_i` | in/各1 | UI 状态 | UI → 本模块 |
|  | `timbre_i`,`octave_i`,`active_n_i`,`selected_obj_i` | in/参数宽度 | 状态字段 | UI/test → 本模块 |
|  | `fault_bus_i` | in/16 | ADC/TLC/render/I2S/FX sticky faults | 各模块 → 本模块 |
|  | `status_bus_o`,`status_commit_o` | out/64,1 | 原子低速快照 | 本模块 → OLED/TJC/LED |

I2S 每声道 32-bit slot，24-bit 有效数据 MSB first，其余补 0；左右声道当前复制同一个单声道样本。LRCK 极性与标准 I2S 的一位延迟仍需用板载 DAC 资料或上板波形确认。

## 3. 时钟域与 CDC

### 3.1 域清单

| 名称 | 频率 | 是否内部时钟域 | 用途 |
|---|---:|---:|---|
| `clk_sys` | 50 MHz | 是，唯一域 | 全部寄存器、状态机、RAM/DSP 控制 |
| `mclk_o` | 12.5 MHz | 否 | 由 10-bit 相位计数器组合/寄存输出；不驱动内部触发器 |
| `bclk_o` | 3.125 MHz | 否 | I2S 输出引脚；内部只用 `bclk_rise/fall` clock-enable |
| `lrck_o` | 48.828125 kHz | 否 | I2S 输出引脚；内部只用 `sample_tick` |
| 3× ADC SCK | 参数化，建议 1~2 MHz | 否 | 注册引脚波形；MISO 用 50 MHz 固定相位采样 |
| UI SPI SCK | 参数化 | 否 | OLED/74HC165 引脚波形 |
| 3× TLC CLK | 参数化，建议 1 MHz | 否 | TLC 引脚波形 |
| UART baud | 待确认 | 否 | 50 MHz 过采样 enable |

### 3.2 跨域/异步信号逐项处理

| 信号 | 来源 → 目的 | 方法 | 为什么不是其他方法 |
|---|---|---|---|
| `rst_async_n_i` | 板级复位 → 50 MHz | 异步拉低、2~3 级同步释放 | 防止释放沿破坏 recovery/removal |
| `pluck_up_i/down_i` | LM393 → 50 MHz | 每路独立 2FF，同步后边沿检测；首边沿立即接收，后置固定不应期 | 不做等待式去抖，避免增加首次触发延迟 |
| EC11 A/B/SW | 机械输入 → 50 MHz | 每路 2FF；A/B 用状态转移表+稳定计数；SW 固定时间去抖 | UI 不在演奏延迟链，可容忍毫秒去抖 |
| TJC UART RX | 异步串口 → 50 MHz | 输入 2FF 后 8×/16×过采样，多数表决可选 | 标准 UART CDC |
| MCP3208 MISO ×3 | 本方 SCK 驱动的外部从机 → 50 MHz | 不过 2FF；在远离数据改变沿的固定 50 MHz 相位采样，并写输入/输出时序约束 | 2FF 会改变 bit 对齐；这是源同步时序，不是自由运行异步数据 |
| 74HC165 QH | 本方 UI SCK 驱动的外部从机 → 50 MHz | 同上，在中心相位采样 | 同上 |
| 按键并行输入 | 按键 → 74HC165 → 50 MHz | `/PL` 先锁存，串行移入后在 50 MHz 域去抖 | 74HC165 是采样边界 |
| 所有内部参数快照 | 同一 50 MHz 域模块间 | shadow + commit；不使用 CDC FIFO | 同域，只需保证原子性 |

CDC 验收必须包含：异步输入亚稳结构检查、所有源同步输入的 `set_input_delay`/板级余量、以及断言“内部没有 `posedge bclk/lrck/spi_sck/tlc_clk`”。

## 4. 资源预算

以下按仓库记录的 60K 资源基线粗估：约 59,904 LUT/FF、118 块 18 Kbit BSRAM、118 个 DSP。最终只能以 Gowin 综合/P&R 报告为准。

| 模块 | LUT/FF 粗估 | DSP | BSRAM 块 | 说明 |
|---|---:|---:|---:|---|
| 64 独立 phase/phase_inc + 控制 | 4k~7k FF，3k~6k LUT | 0 | 0 | 独立状态是评分证据 |
| 64 份双音色波表 bank | 输出 mux/控制约 3k~8k LUT | 0 | **64** | 2×512×16 bit/lane；最大固定项 |
| 32 ADSR + voice manager | 3k~5k FF/LUT | 0~1 | 0 | 状态独立，比较树固定延迟 |
| TDM 包络/混音/饱和 | 2k~4k LUT | **2~4** | 0 | 每帧 64 lane，固定调度 |
| 主音量 + LFO | <1k LUT | 1~2 | 0~1 | 音量 LUT 可用分布 ROM |
| ADC/输入/UI/UART/TLC/I2S | 4k~8k LUT | 0 | 0~2 | 三路 ADC 物理独立 |
| 短 delay/chorus/reverb | 2k~6k LUT | 2~8 | **12~30** | 按 16-bit 延迟线、短时长估计 |
| OLED 文本缓存/状态 | <2k LUT | 0 | 0~2 | 不做整帧 framebuffer |
| 合计（默认） | 约 25k~40k LUT，12k~20k FF | 5~15 | **76~98** | 留 20% 以上 LUT 和约 20 块 BRAM 余量为目标 |

### 4.1 瓶颈

1. 第一瓶颈是 BSRAM block 数，而非原始 bit 数：64 个独立波表即占 64/118 块。
2. 第二瓶颈是 64 路 ROM 输出选择和 TDM 数据选择造成的宽 mux；综合后要看 LUT 与时序，不可只看 RAM bit。
3. 第三瓶颈是固定 1024-cycle 内的调度截止时间；资源够但排程失约仍会 I2S underrun。
4. DSP 不是默认主瓶颈；只有开启 FM、复杂滤波或豪华混响后才会上升。

### 4.2 资源不够时的裁剪顺序

| 顺序 | 先砍什么 | 保留什么 |
|---:|---|---|
| 1 | FFT、帧缓冲、花哨可视化；OLED 只保留文字状态 | N 必须仍可读 |
| 2 | 缩短 reverb/delay，延迟线 24→16 bit，只留一种效果 | 干声与确定性延迟 |
| 3 | 波表深度 512→256，波表宽度 16→12 | 每 lane 独立 bank、至少 2 音色 |
| 4 | `OSC_PER_VOICE` 2→1 | `POLY_TARGET=32`、32 个独立振荡器、Test N=32 |
| 5 | FM 保持关闭，去掉逐 voice 滤波 | 两种基础音色 |
| 6 | 仍不够才重新评估独立 ROM 的实现形式或器件/评分书面口径 | 不先砍 Test Mode、相位独立性、低延迟、数字音量 |

不建议通过减少 `POLY_TARGET` 解决 BSRAM，因为 voice 状态主要吃 FF/LUT；若 BSRAM 真正被 64 个 ROM bank卡住，先把 2 osc/voice 降到 1，仍有 32 复音与 32 个可闻振荡器。

## 5. 参数化开关

### 5.1 可改 parameter

| 参数 | 默认 | 合法范围/约束 | 影响 |
|---|---:|---|---|
| `POLY_TARGET` | 32 | 4/8/16/32；交付版不低于 32 | voice/ADSR 状态和混音轮数 |
| `OSC_PER_VOICE` | 2 | 1或2 | oscillator lane 和独立 ROM 数 |
| `TIMBRE_N` | 2 | ≥2；受每 lane ROM 容量限制 | 波表容量、`TIMBRE_W` |
| `WT_DEPTH` | 512 | 256或512，2 的幂 | ROM 地址位和音质 |
| `WT_W` | 16 | 12或16 | ROM 容量和底噪 |
| `PHASE_W` | 32 | 固定建议32 | 频率精度 |
| `SAMPLE_W` | 24 | 固定建议24 | 内部动态范围 |
| `ADC_SCK_HZ` | 1_000_000 | 由 MCP3208 电压/时序核实 | 单次扫描占用窗口 |
| `ADC_REVISIT_CYC` | 250_000 | **不得小于**250,000 | 每通道轮询间隔 |
| `TLC_CLK_HZ` | 1_000_000 | 依数据手册 | LED 更新时间 |
| `ENABLE_FX` | 0 | 0/1 | BRAM/DSP，首版关闭 |
| `ENABLE_FM` | 0 | 0/1 | 预留接口；不计吞吐量 |
| `FM_OPS` | 0 | 0~4 | 仅 `ENABLE_FM=1` 有效 |
| `TEST_N0..3` | 4/8/16/32 | 编译期常量；运行时用 2 bit 选择 | Test Mode 档位 |

### 5.2 锁死的 localparam/接口常量

`SYS_CLK_HZ=50_000_000`、`AUDIO_FRAME_CYC=1024`、`MCLK_DIV=4`、`BCLK_DIV=16`、`LRCLK_DIV=1024`、`I2S_SLOT_W=32`、`AXIS_N=16`。这些不是用户旋钮，修改等于改变硬件/赛题基线。

优先使用 parameter 而不是全局宏；只有编译工具无法跨文件传参时，才在单一 `rtl/include/project_cfg.vh` 中保留宏。参数组合应有 elaboration-time 约束，例如 `POLY_TARGET*OSC_PER_VOICE<=64` 和每 lane 波表能装入既定 RAM block。

## 6. 实现与验证顺序

| 里程碑 | 最小范围 | 可观测验收标准 |
|---|---|---|
| M0 时基与安全上电 | reset、audio timebase、I2S 空帧、PA/TLC 安全态 | 示波器：BCLK=3.125 MHz、LRCLK=48.828125 kHz；PA_EN_n=1；三路 OE_n=1；无窄脉冲 |
| **M1 第一次能出声** | 单个独立 oscillator + 固定增益 + I2S；不接 ADC/UI/FX | DAC/耳机可听到稳定单音；逻辑分析仪看到标准 I2S；频率误差符合 32-bit phase_inc；无 PLL |
| M2 低延迟拨弦 | UP/DOWN 同步、一个预置音、event flag、固定 sample commit | 示波器 CH1=`evt_flag_o`、CH2=DAC 输出；50 次均 <5 ms，极差目标 <0.1 ms；数字端应 <2 个音频帧 |
| M3 三 ADC 与控制 | 三总线并行、16轴快照、音量/推子处理 | 逻辑分析仪：同一通道间隔严格 5.000 ms；三 CS 只控制各自器件；CH1 音量曲线单调且近似对数；深度死区无抖动 |
| M4 32 独立振荡器/voice | `POLY=32`，Test N=4/8/16/32；每个测试 voice 只启用 lane0 | OLED/TJC 清楚显示 N；频谱看到 N 个预定基频；32 份 voice/包络状态、32 份相位/频率状态和32 ROM bank均可追溯；`deadline_fault=0` |
| M5 默认 32×2 与两音色 | 64 lane、2 音色、ADSR、颤音 | 综合/P&R 过 50 MHz；音色切换可辨；推子速率变化无音高跳变；持续变调时相位无复位、示波器无不连续尖峰 |
| M6 正式 UI/LED | OLED、EC11、4键、3 TLC、TJC | 编码器对象环正确；四键功能正确；右侧 4 双色灯映射正确；抓取 OE_n 证明从无一个 TLC CLK 宽的脉冲 |
| M7 效果器与资源收口 | 按余量启用短 FX | 开/关 FX 总延迟固定；旁路不丢样；BSRAM/LUT/DSP/时序报告留足裕量 |
| M8 决赛验收 | 全系统、Test Mode、故障注入 | 反复 50 次延迟统计；N 视频可读；拔掉/不启动 CPU 仍演奏；ADC/UART/OLED 压力下无音频 underrun |

M1 是第一次能出声的最小路径：`50 MHz → audio_timebase → 1 个 phase_acc/ROM → 固定幅度 → i2s_tx → 板载 DAC`。不要在 M1 前加入 ADC、ADSR、显示或效果器。

## 7. 风险清单与缓解

| 风险 | 后果 | 结构性对策 | 验证 |
|---|---|---|---|
| 5 ms ADC 轮询与 ≤5 ms 模拟触发冲突 | 轴位动作最坏 >5 ms 才被看到 | 把 LM393 UP/DOWN 定为评分低延迟触发；轴位先缓存 | 分开测“拨弦→出声”和“轴位→参数生效”；不得混写结论 |
| 共享波表只算 1 oscillator | 吞吐量申报被否 | 每 lane 独立 ROM bank；或获得主办方书面确认后再共享 | RTL+综合网表+资源报告三证合一 |
| 工具合并相同 ROM | 名义64、物理少于64 | 保层次/禁止合并属性并核对综合网表；必要时每 bank 加独立初始化标识 | 检查 BSRAM instance 数 |
| TDM 超过 1024-cycle deadline | I2S 重复旧样本/爆音 | 固定静态时隙；默认计划 cycle 0~767 render，768~895 mix/fx，896~927 commit，928~1023 guard | `deadline_fault` sticky + 断言 |
| 同周期事件冲突 | 丢 pluck/轴更新/UI命令 | 演奏事件与 5 ms 快照分平面；pluck 最高优先且不经 UI FIFO；voice 分配固定最多16拍 | 同拍注入所有事件的仿真 |
| ADC 多 CS/MISO 双驱 | 总线争用、采样错误 | 当前三组完全独立四线，无共享 MISO；每 master 只有一个 CS | 电气连通检查+逻辑分析仪 |
| UI SPI OLED 独占 | 按键采样变慢 | 165 固定 1 ms 高优先时隙，OLED 每16 byte让行 | OLED全刷时测按键周期 |
| TLC OE 误脉冲进 Special Mode | 灯异常、现场不稳定 | OE guard 独占；不用 OE PWM；LE 移位期恒低 | 示波器长记录+形式断言 |
| 变调重置相位 | 咔哒声 | 只写 phase_inc，phase_acc 只在 reset/新 lane 分配初始化 | 连续扫频观察波形连续性 |
| 音量线性映射 | 小角度爆音、后半程无变化 | 64 点对数 gain LUT + mute ramp | ADC扫全量程记录 dB 曲线 |
| 推子端点噪声/速率跳变 | 颤音启停抖动、音高跳变 | 深度双阈值死区迟滞；rate_inc 每5 ms 最大步进限制 | 端点抖动与快速推拉测试 |
| 累加溢出 | 32音时削顶/回绕 | 宽累加器（至少样本位宽+`ceil(log2(OSC_N))`+保护位）后饱和 | 全 lane 同相最大幅仿真 |
| DAC/I2S 格式不明 | 无声或声道错位 | 先 M0/M1 核对标准 I2S、LR 极性和有效位 | 逻辑分析仪+单比特测试字 |
| DAC/功放群延迟未知 | 数字预算正确但模拟实测超标 | 不在文档中编造 5 µs；以板载链路实测为准 | event flag 与模拟输出双通道测量 |
| PA 使能爆音 | 上电/静音有冲击 | PA 默认关；先输出零帧与增益斜坡，再低有效开启 | 上电/复位/静音循环测试 |
| UART 屏阻塞 | 演奏抖动 | status shadow copy；UART 自己慢慢发，不提供 backpressure | 屏断线/满负荷仍无 underrun |
| 无明确复位源 | 上电状态不可证明 | 顶层保留 `rst_async_n_i`；冻结 CST 前确认来源 | 冷启动100次 |
| 路径含中文 | Gowin SORT-1002 | RTL/Gowin工程放在全 ASCII 目录，如 `C:/fpga/Gowin2026-PolySynth` | 构建脚本启动前检查绝对路径 ASCII |

### 7.1 低延迟的可证明上界

对 `UP/DOWN → I2S 首个非零样本`：

| 段 | 最坏预算 |
|---|---:|
| 异步同步与边沿捕获 | <60 ns，外加最多 20 ns 相位量化 |
| voice 分配/最多16轴展开 | ≤16 clk = 0.32 µs |
| 等待下一音频帧边界 | <20.48 µs |
| 固定 render + 后处理 | ≤1~2 帧 = 20.48~40.96 µs |
| I2S 串行至 DAC 接收到有效高位 | <1 帧 = 20.48 µs |
| 数字侧合计 | 设计目标 <82 µs，抖动上界 <1 个样本周期 |
| DAC+模拟功放 | **未知，必须实测** |

这里的“确定性”定义为：没有排队、重试或可变长路径；事件至样本的延迟只存在一个音频样本以内的相位量化，且有明确上界。最终评分证据必须是 50 次以上示波器统计，不能只用 RTL 推算。

对“轴位模拟阈值→参数生效”，采集等待本身最坏接近 5 ms，再加数字和音频路径后会略大于 5 ms，因此只能承诺基础 `≤10 ms`，除非硬件 RC/轮询约束改变。

## 8. 仍缺的信息（不编造）

| # | 缺失问题 | 影响 |
|---:|---|---|
| 1 | 最终 Dock/核心板准确型号、速度等级（资料存在 C1/C2 漂移）、原理图版本，以及所有非音频信号的 ball 映射；50 MHz 当前官方候选为 `V22/LVCMOS33`，不能沿用旧板 `F13` | CST、IO standard、P&R 能否通过 |
| 2 | 外部复位源及有效极性；官方示例候选为 `Y12/LVCMOS15/PULL_UP`，但项目尚未确认；若不用它，允许采用哪种 Gowin GSR/POR 方案 | 上电确定性 |
| 3 | 板载 DAC 的具体型号、标准 I2S/左对齐格式、LRCK 极性、有效位数、是否需要物理 MCLK | `i2s_tx` 最终帧格式；当前题面没有 MCLK ball |
| 4 | OLED 控制器型号（SSD1306/SH1106等）、SPI mode、是否有独立 CS/DC/RST | OLED 初始化与总线端口冻结 |
| 5 | 74HC165 的 `/CE` 是硬件固定低还是需要 FPGA 控制；按键到 D0~D3 的位序 | 右手板 B 顶层端口与映射 |
| 6 | TJC X2 串口电平和固定 baud | 是否需要电平转换、UART 参数 |
| 7 | 右手 4 个双色 LED 的公共极性、TLC OUT0~7 到颜色/灯号的映射 | `led_status_map` 真值表 |
| 8 | 三片 MCP3208 的 VREF、电源电压和允许 SCK；通道物理顺序是否与 CH 编号一致 | ADC 时序与量化换算 |
| 9 | 演奏语义：轴位过浅阈就自动 Note On，还是必须先选轴再由 UP/DOWN 拨弦触发 | 决定哪个动作作为官方延迟起点；在当前5ms轮询约束下非常关键 |
| 10 | `UP` 与 `DOWN` 同时有效时的电气可能性和优先规则 | pluck 冲突处理 |
| 11 | 左手 16 灯和右手 8 输出是否三组完全独立 CLK/DATA/LE/OE；若部分线共用需给出原理图 | TLC 顶层端口是否可收缩 |

在上述问题未答复前，可以完成 M0~M4 的大部分 RTL 和仿真，但不能宣称 CST、OLED、UART、I2S 模式或全系统端到端延迟已经最终冻结。

## 9. 仓库资料引用基线

- 当前仓库已有的接口草案：[`files/20-代码/W3接口冻结表.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/W3%E6%8E%A5%E5%8F%A3%E5%86%BB%E7%BB%93%E8%A1%A8.md)
- ~~旧延迟预算~~ ⛔ **已作废**：原「延迟预算逐段分解」按"3 片 ADC 共享一条 SPI 总线 + 模拟 RC `10 kΩ+100 nF`（每通道 ≥5 ms）"估算，**两个前提都已推翻** ⇒ 该文件已归档到 `files/历史/`，**引用其数字前必须以现行口径重算**（见 `files/20-代码/已知问题与风险清单.md` 的 `K-07` / `K-31`）
- 资源评估：[`files/20-代码/FPGA平台与资源评估.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/FPGA%E5%B9%B3%E5%8F%B0%E4%B8%8E%E8%B5%84%E6%BA%90%E8%AF%84%E4%BC%B0.md)
- Dock 音频引脚：[`files/10-硬件/开发板与引脚资料.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/10-%E7%A1%AC%E4%BB%B6/%E5%BC%80%E5%8F%91%E6%9D%BF%E4%B8%8E%E5%BC%95%E8%84%9A%E8%B5%84%E6%96%99.md)
- TLC5916 实验驱动现已在远端 `main`；其功能仿真覆盖移位/LE，但 `OE` 仍需本文所述 guard 才满足最新安全约束。
