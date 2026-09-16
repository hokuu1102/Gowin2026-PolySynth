# Gowin2026-PolySynth：RTL 规划前仓库事实核验与异议清单

> 核验日期：2026-09-16（Asia/Shanghai）
> 远端仓库：[`hokuu1102/Gowin2026-PolySynth`](https://github.com/hokuu1102/Gowin2026-PolySynth)
> 固定快照：[`6442a098d3bd7df90e18e86a9bb1b908e28e24de`](https://github.com/hokuu1102/Gowin2026-PolySynth/tree/6442a098d3bd7df90e18e86a9bb1b908e28e24de)（远端 `main`，2026-09-16 21:00:43 +08:00）
> 核验目的：只确认现有资料、代码、约束、器件资源及其冲突；不在本文设计完整 RTL 架构。

## 1. 结论摘要

1. 仓库已经不再是“完全没有 RTL”的纯文档仓库：远端 `main` 现有一份 `TLC5916` 驱动、一份 testbench 和一份 Icarus 回归脚本；本次本地复跑通过。但除此之外，顶层、时钟/I2S、ADC/SPI、合成核心、显示/UI、约束和 Gowin 工程仍未实现。
2. 仓库已有较完整的**规划文档**，包括拟建文件树、W3 模块接口草案、延迟估算和资源粗估；这些内容不是已经综合过的实现，也不是可直接照抄的最终接口。
3. 最新硬件 Prompt 与仓库旧规划之间有三组必须先收敛的冲突：
   - 右手模拟 RC：`1 kΩ + 10 nF` 与 `10 kΩ + 100 nF / 每通道间隔 ≥5 ms` 冲突；
   - SPI 拓扑：旧规划把三片 MCP3208 的 `SCLK/MOSI/MISO` 共用，而最新硬件要求左手两板各自四线排线，不能把多个 MISO 直接并到一个 FPGA 输入；
   - 控制量：旧 W3 只传颤音深度且速率固定 5–6 Hz，最新方案是两个推子分别控制深度和 1–12 Hz 速率，另有数字主音量。
4. 正式板音频管脚 `Y17/AB17/AA16/AB16` 在仓库派生文档中有记录，但支撑这些结论的 Dock 原理图被 `.gitignore` 排除，并不在仓库快照中；因此“GitHub 库含全部可复核原始资料”目前不成立。
5. 正式 NEO Dock 的系统时钟不能沿用仓库旧“基石板”的 `F13 @ 50 MHz`。Sipeed 官方 60K 示例把板载 50 MHz `sys_clk` 约束在 `V22/LVCMOS33`；`AB12/LVCMOS15` 是 Rev.31004 上另一条可编程 MS5351 时钟输入。按用户“直接用 50 MHz 晶振”的口径应采用前者，并以正式板 `.cst`/实板版本复核。

## 2. 远端仓库现状

### 2.1 已存在且可执行的代码

| 文件 | 现状 | 核验结果 |
|---|---|---|
| [`rtl/drivers/tlc5916_driver.sv`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/rtl/drivers/tlc5916_driver.sv) | 单颗 TLC5916 正常模式串行发送器；端口为 `clk/rst_n/start/led_data[7:0]/outputs_enable` 与 `tlc_clk/tlc_sdi/tlc_le/tlc_oe_n/busy/done` | 唯一已实现 RTL 模块 |
| [`tb/drivers/tb_tlc5916_driver.sv`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/tb/drivers/tb_tlc5916_driver.sv) | 检查 8 个移位时钟、MSB-first 数据、单次 LE 脉冲、同步复位、最终 OE 电平 | 本地复跑全部 PASS |
| [`sim/run_tlc5916.ps1`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/sim/run_tlc5916.ps1) | 调用 Icarus Verilog 生成 VVP/VCD | 可运行，不是 Gowin 综合脚本 |

本次复跑的最终输出是 `PASS: all TLC5916 tests completed successfully`。这只能证明上述 testbench 覆盖的功能行为，不等同于 Gowin 综合、时序收敛或真芯片 Special Mode 安全验证。

### 2.2 规划存在、实现不存在的内容

仓库的 [`W3接口冻结表.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/W3%E6%8E%A5%E5%8F%A3%E5%86%BB%E7%BB%93%E8%A1%A8.md) 和 [`代码总览图.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/%E4%BB%A3%E7%A0%81%E6%80%BB%E8%A7%88%E5%9B%BE.md) 规划了下列模块，但文档自己也注明“除 TLC5916 驱动外尚未创建”：

- `rtl/top.v`、`clk_gen.v` <!-- refcheck:ignore-line -->
- `adc_spi_master.v`、`chan_scan.v`、`calib.v`、`debounce.v`、`axis_map.v`、`event_extract.v`、`param_extract.v`
- `note_manager.v`、`voice.v`、`osc.v`、`wavetable.v`、`mixer.v`
- `master_mix.v`、`fx_*`、`i2s_tx.v`、`test_mode.v`、`vis_tap.v`、`led_data.v`、`uart_ui.v`
- `constr/top.cst`

远端快照中还没有 `.gprj`、`.cst`、Gowin 综合/P&R 报告或 `.fs` 位流。因此：

- 当前无法验证 50 MHz 时序收敛；
- 当前无法验证管脚、电压标准和 Bank 分配；
- 当前所有 LUT/FF/DSP/BSRAM 数字都只是估算，不是综合结果；
- 当前没有“第一次出声”的可构建路径。

## 3. 平台、资源和音频管脚核验

### 3.1 器件资源

高云官方 Arora V 产品表给出的 GW5AT-60 资源与仓库资源表一致：

| 资源 | GW5AT-60 官方值 |
|---|---:|
| LUT4 | 59,904 |
| REG | 59,904 |
| SSRAM | 468 Kbit |
| BSRAM | 2,124 Kbit，118 块 |
| DSP | 118 |
| PLL | 8 |
| Global Clock | 16 |
| HCLK | 20 |

来源：[GOWIN Arora V 官方产品页](https://www.gowinsemi.com/en/product/arora-v-fpga/)、[GW5AT 数据手册 DS981 官方入口](https://www.gowinsemi.com/en/document/main/database/2914/?order=DESC&page=1&support_search=&type=version)。Sipeed 官方板卡页同样列出 59,904 LUT、2,124 Kbit BSRAM、118 个 18×18 乘法器，并明确 Tang Mega 60K 没有硬核 SoC：[Tang Mega 60K Dock 官方 Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k)。

器件完整料号尚有一处资料漂移：仓库资源文档写 `GW5AT-LV60PG484AC2/I0`，Sipeed 官方板卡页和示例工程使用 `GW5AT-LV60PG484AC1/I0`（示例 `.cst` 标 Device Version B）。资源数量相同，但速度级/工程 Device 选择不能混用；建立 Gowin 工程时必须按实板丝印或官方该批次资料确定。

仓库 [`FPGA平台与资源评估.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/FPGA%E5%B9%B3%E5%8F%B0%E4%B8%8E%E8%B5%84%E6%BA%90%E8%AF%84%E4%BC%B0.md) 判断 BSRAM 是效果器/长延迟线的主要瓶颈，这一方向合理；但其中单 Voice LUT/FF、效果器 LUT、DSP TDM 拍数和总占用都未经过综合，不能当成容量承诺。

### 3.2 正式 Dock 音频连接

仓库 [`开发板与引脚资料.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/10-%E7%A1%AC%E4%BB%B6/%E5%BC%80%E5%8F%91%E6%9D%BF%E4%B8%8E%E5%BC%95%E8%84%9A%E8%B5%84%E6%96%99.md) 记录：

| 信号 | FPGA 管脚 | 备注 |
|---|---|---|
| `I2S_BCLK` | `Y17` | Bank 7 |
| `I2S_LRCK` | `AB17` | Bank 7 |
| `I2S_DIN` | `AA16` | Bank 7 |
| `PA_EN` | `AB16` | 低有效 |

同一文档还明确写了板载 DAC **没有 MCLK 连接**。所以用户指定的 `MCLK=12.5 MHz` 可以作为内部节拍/分频链概念存在，但正式顶层不应凭空增加一个板载 DAC 的 `I2S_MCLK` 输出管脚。物理输出仍是 BCLK、LRCK、DIN 和 PA_EN。

异议：上述管脚的原始依据 `Tang_Mega_NEO_Dock-60K_31004_Schematics.pdf` 被仓库文档明确标为“本地、已 gitignore”，见 [`正式板引脚与连接器.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/10-%E7%A1%AC%E4%BB%B6/%E6%AD%A3%E5%BC%8F%E6%9D%BF%E5%BC%95%E8%84%9A%E4%B8%8E%E8%BF%9E%E6%8E%A5%E5%99%A8.md)。仓库目前只有转录结论，没有可在 GitHub 内独立复核的原图或正式 `.cst`。

### 3.3 系统时钟管脚是未闭合项

- 仓库旧资源文档中的 `sys_clk = F13 @ 50 MHz` 属于手上另一块“基石板”；仓库也明确警告其引脚约束不能移植到正式 Tang Mega NEO Dock。
- Sipeed 官方 60K `pmod_led_neo` 约束把**板载 50 MHz 振荡器**命名为 `sys_clk`，管脚为 `V22`、`LVCMOS33`；同一文件另列可选 `ms5351_clk=AB12/LVCMOS15`（V31005 之前）以及片内 OSC 测试点，说明两者不是同一个时钟源：[官方 `pmod_led.cst`](https://github.com/sipeed/TangMega-60K-example/blob/main/pmod_led_neo/src/pmod_led.cst)、[官方示例说明](https://github.com/sipeed/TangMega-60K-example/tree/main/pmod_led_neo)。
- 因此不能在正式 `top.cst` 中继续使用 `F13`，也不应把 `AB12` 当成“直接 50 MHz 晶振”。按本项目约束，候选基线应是 `V22/LVCMOS33`；仍需用正式板版本和完整官方约束复核后落库。

## 4. SPI、ADC 与采集节拍：现有资料冲突

### 4.1 三片 MCP3208 的物理总线形态

旧 [`代码总览图.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/%E4%BB%A3%E7%A0%81%E6%80%BB%E8%A7%88%E5%9B%BE.md) 把 `adc_spi_master.v` 写成“共用 SCLK/MOSI/MISO，靠 CS1/CS2/CS3 区分”。旧 [`采集链参数复核.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/%E9%87%87%E9%9B%86%E9%93%BE%E5%8F%82%E6%95%B0%E5%A4%8D%E6%A0%B8.md) 也按“24 通道共享一条总线”计算 2 kHz/通道。

最新硬件 Prompt 则明确：左手两板各自一条排线，每板都输出 `CS/SCK/MOSI/MISO` 四线；右手板 A 还有第三组 MCP3208。由此得到的保守接口结论是：

- 三个 ADC 的 `MISO` 必须是三个独立 FPGA 输入，除非板级原理图明确把三态输出接到同一物理网且 CS 互斥；现有资料没有这种并线证据。
- `SCK/MOSI` 可以在 FPGA 内由同一调度器生成相同波形，再扇出到多个独立顶层输出；这不等于把三个物理端口写成一根线。
- “共用一个 CS 会 MISO 双驱”的表述需要精确化：真正必须保证的是任一时刻只选中目标器件；不同板必须有独立 CS。MISO 是否能物理并线取决于板级连接和未选中器件是否可靠高阻，不能只凭逻辑意图推断。
- `74HC165` 的串行输出没有像 SPI ADC 那样的 CS/OE 控制三态语义；TI 引脚表只有 `/PL`、CP、`/CE` 与 QH/QH-bar 等脚。若板 B 所谓“复用 SPI”包含把 Q7/QH 与 ADC MISO 硬并，必须有外部隔离/三态器件。现有资料没有该器件，因此最安全的接口事实是 QH 使用独立 FPGA 输入，只复用 SCK 等主机输出线。来源：[TI SN74HC165 数据手册](https://www.ti.com/lit/ds/symlink/sn74hc165.pdf)。

Microchip 官方资料确认 MCP3208 是 8 通道、12 bit、SPI、最高 100 kSPS 等级器件，并给出了 Start/SGL/D2..D0/Null/B11..B0 的串行帧：[MCP3204/3208 数据手册 DS21298E](https://ww1.microchip.com/downloads/en/devicedoc/21298e.pdf)、[MCP3208 官方产品页](https://www.microchip.com/en-us/product/mcp3208)。具体 SCK 上限随 VDD 条件变化，驱动参数必须按 3.3 V 条件取值，不能仅引用 5 V 下的 100 kSPS。

### 4.2 右手模拟 RC 与轮询周期直接矛盾

同一个远端提交中存在两套互斥口径：

| 来源 | 右手板 A 模拟滤波 | 对调度的含义 |
|---|---|---|
| [`右手板方案.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/10-%E7%A1%AC%E4%BB%B6/%E5%8F%B3%E6%89%8B%E6%9D%BF%E6%96%B9%E6%A1%88.md) | `1 kΩ + 10 nF` | 文档没有要求 5 ms 间隔 |
| [`AI规划代码结构-Prompt.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/AI%E8%A7%84%E5%88%92%E4%BB%A3%E7%A0%81%E7%BB%93%E6%9E%84-Prompt.md) | `10 kΩ + 100 nF` | 明确要求同一通道两次轮询间隔 `≥5 ms` |
| 旧 [`采集链参数复核.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/%E9%87%87%E9%9B%86%E9%93%BE%E5%8F%82%E6%95%B0%E5%A4%8D%E6%A0%B8.md) | 未采用该 5 ms 约束 | 按所有 24 通道 `2 kHz/ch`、间隔 `0.5 ms` 估算 |

所以旧延迟文档中“ADC 最坏等待 500 µs、端到端约 0.59 ms”的数字不能直接用于最新右手模拟通道。好在拨弦首发事件来自 LM393 的 `UP/DOWN` 数字边沿，不依赖右手 ADC；但推子、音量更新周期必须按最终 RC 版本重算并独立调度。

## 5. W3 接口草案与最新功能要求的漂移

### 5.1 颤音和音量接口已过时

[`W3接口冻结表.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/W3%E6%8E%A5%E5%8F%A3%E5%86%BB%E7%BB%93%E8%A1%A8.md) 的 `expr_param_t` 只有：

- `vibrato`：单个 8 bit 深度；
- `timbre`：4 bit；
- 一个文档正文已宣告取消、但结构体里仍保留的 `pitch_fine[11:0]`。

同一文档还写“LFO 速率固定 5–6 Hz”。最新 Prompt 已改为：

- 推子 1 = 颤音深度；
- 推子 2 = 颤音速率，1–12 Hz；
- 独立数字主音量，位置到增益需查表/近似对数映射；
- 速率更新需斜率限制，深度需死区和迟滞。

因此 W3 参数接口目前不能冻结，至少要删除残留 `pitch_fine` 并补齐 `vibrato_depth`、`vibrato_rate`、`master_volume` 或等价接口。这里仅指出缺口，不在本文决定最终模块边界。

### 5.2 测试模式档位口径不一致

- 最新要求是 `N = 4/8/16/32`；
- 旧规划表还列了 `64` 档；
- W3 草案只笼统留 `test_mode_en + test_n[5:0]`，没有冻结编码、非法值行为、切档时机和显示握手。

多一个 64 档本身不是功能冲突，但实现和视频验收必须以 4/8/16/32 四档为必测集合，不能让 64 档扩大正式验收范围或引入资源/混音溢出风险。

### 5.3 复位源缺失

仓库约定所有 RTL 使用 `rst_n`、50 MHz 域内低有效同步复位，现有 TLC5916 驱动也遵守该约定。但最新硬件 Prompt 没有给正式 Dock 的复位输入管脚、上电时序或是否允许仅用内部上电计数器。旧 `D1` 复位管脚属于另一块板，不能迁移。Sipeed 官方示例提供的候选是 `rst_n=Y12/LVCMOS15/PULL_UP`，但是否把该板载按键用作全系统复位仍需项目决定；顶层接口表不能默认为已冻结。

## 6. TLC5916：已有模块的边界与风险

TI 官方数据手册确认：

- `OE(ED2)` 低时输出驱动使能，内部典型 500 kΩ 上拉；
- `LE(ED1)` 负责把移位寄存器锁存到输出锁存器；
- `OE` 上出现一个 CLK 宽的短脉冲会进入 Mode Switching，第四个 CLK 上升沿采样 LE 决定进入 Special/Normal Mode；
- 默认输出电流近似 `Iout=(1.25 V/Rext)×15`，所以 2.4 kΩ 约 7.8 mA。

来源：[TI TLC5916/TLC5917 数据手册 SLVS695D](https://www.ti.com/lit/ds/symlink/tlc5916.pdf)。这与最新硬件约束一致。

现有 `tlc5916_driver.sv` 的优点：复位把 `OE` 置高、LE 置低；移完 8 bit 后才拉高 LE；没有 PWM 调光逻辑。

但必须提出一项接口异议：模块每个 50 MHz 周期都执行 `tlc_oe_n <= ~outputs_enable`，本身**不阻止调用者给出单个系统时钟宽的 `outputs_enable` 毛刺/脉冲**。当前 testbench只检查最终 OE 电平，没有验证 OE 相对 TLC CLK 的脉冲宽度和 Special Mode 序列安全。因此集成时必须有可验证的契约：`outputs_enable` 只能是稳定的整帧状态，或由驱动内部锁存/约束；不能把任意单周期脉冲直接接进来。

另一个资料状态矛盾：[`右手板方案.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/10-%E7%A1%AC%E4%BB%B6/%E5%8F%B3%E6%89%8B%E6%9D%BF%E6%96%B9%E6%A1%88.md) 声称该驱动“写过并上板验证过”，而 [`TLC5916驱动验证.md`](https://github.com/hokuu1102/Gowin2026-PolySynth/blob/6442a098d3bd7df90e18e86a9bb1b908e28e24de/files/20-%E4%BB%A3%E7%A0%81/TLC5916%E9%A9%B1%E5%8A%A8%E9%AA%8C%E8%AF%81.md) 明确写“功能仿真已通过；真芯片时序、引脚约束和尚待上板验证”。在没有示波器截图/上板记录前，应按“尚未上板验证”处理。

## 7. 时钟域与 CDC：仓库能确认到的范围

仓库的总体意图是：

- 全部内部状态机只在 `clk_sys=50 MHz` 工作；
- `tick_audio` 等作为 clock-enable，不把分频信号用作内部派生时钟；
- I2S BCLK/LRCLK 是由 50 MHz 计数器翻转的**外部输出信号**；
- 不使用 PLL。

这与“不用 PLL、结果确定”的硬约束一致。但当前没有 RTL 能证明该策略已落实，也没有异步输入 CDC 清单。以下信号来自 FPGA 外部，不能因为“内部单时钟域”就省略同步/捕获说明：

- LM393 `UP/DOWN`；
- EC11 `A/B/SW`；
- 四个按键；
- UART RX；
- SPI MISO（由本地 SCK 事务采样，需明确采样边沿）；
- 74HC165 Q7；
- OLED 一般只有输出控制线，不构成返回 CDC，除非模块另有未说明的 busy/IRQ。

现有文档没有逐项定义同步器、边沿捕获、去抖或脉冲保持，因此“没有 CDC”不是已核验事实。

## 8. 资源预算能采信到什么程度

| 结论 | 可采信程度 | 原因 |
|---|---|---|
| GW5AT-60 有 59,904 LUT、118 DSP、2,124 Kbit BSRAM | 高 | 官方器件/板卡资料一致 |
| 短延迟效果器比 1 s 真延迟更适合 60K | 中高 | 存储量算术方向正确 |
| 32 Voice × 2 OSC 的 LUT/FF 一定只占约 10% | 低 | 只按手工模块量级估算，未综合 |
| 一个共享 DSP 能在 1024 拍内完成所有振荡器/包络运算 | 中低 | 依赖实际 BRAM 端口、波表读延迟、流水线停顿、音色算法和调度，没有 RTL/时序报告 |
| BSRAM 是唯一瓶颈 | 中 | 对克制的波表+DDS路线大概率成立，但显示、效果器、Voice 状态落 BRAM 后仍需综合证明 |

资源不足时先砍长延迟线/效果器规模而不是复音数，是仓库中有依据的取舍方向；但最终排序仍应由第一版 32×2 骨架的综合报告决定。

## 9. 路径与工具链核验

- 远端仓库根名 `Gowin2026-PolySynth`、拟建 EDA 目录 `rtl/`、`constr/` 都是 ASCII；当前本地镜像路径也全 ASCII。<!-- refcheck:ignore-line -->
- 仓库含中文文档目录和文件名。只要 Gowin 工程、源码、约束、IP 和生成目录完全留在 ASCII 路径，文档目录不加入 Gowin 工程，这一点可控。
- 当前没有 Gowin 工程文件，故还不能证明生成目录、IP 临时目录和最终交付解压路径也满足 ASCII 约束。
- Sipeed 官方 Wiki 要求 Tang Mega 60K 使用足够新的 Gowin IDE（教育版至少 V1.9.11.03，商业版至少 V1.9.10.03）；仓库尚未冻结团队实际版本。版本必须写入构建说明，否则不同机器生成结果不可复现。来源：[Sipeed Tang Mega 60K 官方 Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k)。

## 10. RTL 规划前必须明确的问题

这些是仓库和用户硬约束都没有闭合、不能靠推测补齐的项：

1. 正式 NEO Dock 是否按官方示例采用 `V22/LVCMOS33` 的板载 50 MHz `sys_clk`；实板版本和正式全约束是否与示例一致。不要误用旧板 `F13` 或可编程 MS5351 的 `AB12`。
2. 正式复位源：是否采用官方示例的 `Y12/LVCMOS15/PULL_UP` 按键、极性、上电有效时间；若不用外部复位，是否接受纯 RTL 上电延时复位。
3. 右手板 A 最终 BOM 是 `1 kΩ+10 nF` 还是 `10 kΩ+100 nF`；在确认前不能冻结 ADC 轮询周期。
4. 三片 MCP3208 的 SCK/MOSI/MISO 是物理独立还是部分共线；尤其要给出 P1 转接板逐针连接，不能只给板端信号名。
5. 板 B SPI 的精确共享关系：OLED、74HC165、TLC5916 分别占哪些 SCK/MOSI/MISO/CS/DC/RST/PL/LE/OE 管脚，是否与板 A/左手 ADC 共用时钟线。
6. UART 屏波特率、数据位/校验/停止位、是否需要 RX，以及用户协议帧格式。
7. OLED 控制器虽文档写 SSD1306，但模块的 SPI 模式、CS/DC/RST 极性、上电初始化序列仍需确认。
8. `PA_EN` 上电默认状态和启声顺序：应先连续输出静音帧再开功放，还是可复位后立即拉低；现有资料没冻结。
9. 正式板完整 `.cst`：除四个音频管脚外，所有 SPI/UART/按键/编码器/测试点管脚和 IO 标准仍缺。
10. TLC5916 是否已有真实上板证据；若有，应把逻辑分析仪/示波器截图和测试条件入库，消除文档状态矛盾。

## 11. 可直接作为主架构输入的已确认事实

- 目标器件：Tang Mega 60K，GW5AT-60 资源基线如 §3.1。
- 不用 PLL、不用 CPU、不用 HLS；内部统一 50 MHz 时钟加 clock-enable 的方向与仓库既有约定一致。
- 音频输出物理管脚暂按 `Y17/AB17/AA16/AB16`，其中 `PA_EN` 低有效；正式 `.cst` 仍需把来源补齐。
- 实际采样率按 `50 MHz/1024 = 48.828125 kHz`，每样本正好 1024 个系统时钟；该算术无异议。
- `POLY_TARGET=32`、`OSC_PER_VOICE=2` 已在最新 Prompt 和旧规划中一致。
- 左手 16 轴位、三片 MCP3208、三片 TLC5916、板 B OLED/EC11/4 键/74HC165、UART 屏是最新硬件基线。
- TLC5916 的 OE/LE/Special Mode 约束有 TI 数据手册支撑；现有驱动可作为起点，但 OE 控制契约必须补强和验证。
- 旧 W3 的 `phase_inc[31:0]` 直传、运行中更新而不复位相位累加器，与最新要求一致；W3 其余参数结构需按本报告第 5 节修订。
