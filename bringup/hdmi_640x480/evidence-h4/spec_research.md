# GW5AT-LV60PG484AC1/I0 的 H4 输出速率核查

日期：2026-10-01。目标：判断 OSER10 的 768.75 MHz FCLK、LVDS 每 lane 1.5375 Gb/s 是否落在器件速率额定范围。

## 结论

**是，就器件公布的 OSER10 串行输出和 LVDS TX 速率上限而言，两项 H4 数值都在范围内。** Gowin 的 GW5AT 系列数据手册 **DS981-1.1.3E** 对 **GW5AT-60** 给出 OSER10 最高串行输出 **2000 Mb/s**，产品资源表给出 LVDS TX **2.0 Gb/s**。H4 的 1.5375 Gb/s 分别低于这两个上限 0.4625 Gb/s（约 23.1%）。[DS981 官方 PDF，印刷页 87–88、3](https://cdn.gowinsemi.com.cn/DS981E.pdf)。

**OSER10「最高 FCLK」没有找到独立列出的额定 MHz 数值。** 本机 UG304 给出 OSER10 为 10:1、`PCLK = FCLK/5`，据此串行位率为 `10 × PCLK = 2 × FCLK`。因此 2000 Mb/s 串行额定值对应的 **1 GHz FCLK 是计算得到的等效上限，不是手册明列的 FCLK 额定值**；H4 的 768.75 MHz 对应 1.5375 Gb/s，低于该等效上限。不能把 PLL 的 1400 MHz 输出上限当成 OSER10 的 FCLK 上限。[DS981 官方 PDF，印刷页 92–93](https://cdn.gowinsemi.com.cn/DS981E.pdf)；本机 UG304-1.3.5E，印刷页 98（PDF 第 108 页）。

这个“是”有器件手册的使用条件：DS981 的供电注释说，I/O 收发速率超过 600 Mb/s 时 **VCCX 需至少 2.5 V**；表 3-38 还注明 I/O 逻辑最高速率与所用 IP 有关。尚未在本次资料核查中证实 H4 实际管脚所在 bank、板上 VCCX、电气连接、PLL/时钟布线与时序收敛，因此它**不能代替上板可工作证明**。上板前应核对 VCCX 与输出管脚，跑 768.75 MHz FCLK 的 P&R/STA，并用示波器或 HDMI 接收端检验波形与眼图。[DS981 官方 PDF，印刷页 64–65、89](https://cdn.gowinsemi.com.cn/DS981E.pdf)。

Console 官方 HDMI TX 演示工程标称到 1080P30/720P60（74.25 MHz 像素时钟）是**演示设计范围**，不能作为 GW5AT-60 的器件最高速率。此处的“是”仅指器件公布速率；H4 视频链路能否稳定运行仍需实现与板级验证。

## 能由文档直接证明的事实

| 来源与位置 | 原文关键行 | 可证明的事实 |
| --- | --- | --- |
| [DS981-1.1.3E 表 3-38，印刷页 87–88（PDF 第 98–99 页）](https://cdn.gowinsemi.com.cn/DS981E.pdf#page=98) | `FMAXOSER10 10:1 Gearbox maximum serial output rate 2000 Mbps` | GW5AT-60 的 OSER10 **串行输出**上限为 2000 Mb/s。表跨两页，表题在印刷页 87，OSER10 行在印刷页 88。 |
| [DS981-1.1.3E 表 1-1，印刷页 3（PDF 第 14 页）](https://cdn.gowinsemi.com.cn/DS981E.pdf#page=14) | `LVDS (Gbps)`；GW5AT-60 栏 `2.0(TX)` | 60K 的 LVDS TX 标称最高 2.0 Gb/s；RX 与 TX 是不同栏位，不能混用。 |
| [DS981-1.1.3E 表 3-44，印刷页 93（PDF 第 104 页）](https://cdn.gowinsemi.com.cn/DS981E.pdf#page=104) | `FOUTMAX PLL Maximum Output Frequency 1400 1400 MHz` | GW5AT-60 的 C2/I1 与 C1/I0 两速度等级，PLL 输出上限均为 1400 MHz；这只是 PLL 指标。 |
| [DS981-1.1.3E 表 3-38 注释，印刷页 89（PDF 第 100 页）](https://cdn.gowinsemi.com.cn/DS981E.pdf#page=100) | `IO logic maximum, IP-dependent.` | 2000 Mb/s 是 I/O 逻辑的最高速率，具体实现还依赖 IP。 |
| [DS981-1.1.3E §3.1，印刷页 64–65（PDF 第 75–76 页）](https://cdn.gowinsemi.com.cn/DS981E.pdf#page=75) | 文中说明：I/O 收发超过 600 Mb/s 时 VCCX 至少 2.5 V。 | 1.5375 Gb/s 需要满足该供电条件。 |
| 本机 `D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\doc\EN\UG304-1.3.5E_Arora Ⅴ Programmable IO (GPIO) User Guide.pdf`，§4.3.5，印刷页 98（PDF 第 108 页） | “10 to 1 Serializer”；`PCLK` 由 `FCLK` 五分频 | 给出 OSER10 的 10:1 关系与 FCLK/PCLK 关系；**没有**最高 FCLK 或数据率。 |

DS981 的器件表列 GW5AT-60，封装表列 PG484A，表 3-44 列 C1/I0；与本机 `GW5AT-LV60PG484AC1/I0` 的 60K、PG484A、C1/I0 字段相符。[DS981 印刷页 6、92–93、111](https://cdn.gowinsemi.com.cn/DS981E.pdf)。

## 由上述事实计算或仍需验证的内容

- `FCLK = 768.75 MHz` 且 `PCLK = FCLK/5 = 153.75 MHz` 时，OSER10 的 10:1 输出是 `10 × 153.75 = 1537.5 Mb/s = 1.5375 Gb/s`。反向由手册的 2000 Mb/s 算得等效 `FCLK ≤ 1000 MHz`。这是**推算**，不是 DS981 的独立 FCLK 规格。
- `768.75 < 1000 MHz`，`1.5375 < 2.0 Gb/s`，故器件所公布的串行器和 LVDS 速率上限未被 H4 超过。但时钟生成配置、bank 电压、引脚、负载、差分走线和 STA 均需另证。
- DS981 的 SerDes/Transceiver 速率是另一套高速收发器指标，不能用于 GPIO LVDS/OSER10 的判定。

## 本机安装目录核查

对 `D:\Gowin` 递归清点 **7834** 个文件；使用 PyMuPDF 提取并检索全部 **152** 份 PDF 的每一页，并按内容探测后逐行检索 **5951** 个可解码的文本文件（含 Verilog、XML、HTML、CSV、IP 配置与脚本）。另外 1731 个文件因二进制特征或超过 20 MB 而未作为文本读取。关键词包括 `OSER10`、`OSER16`、`serializer`、`SERDES`、`LVDS`、`最大频率`、`数据率`、`Gbps`、`MHz`、`AC 特性`、`GW5AT`、`FCLK`。扫描无读取异常。完整已检查 PDF/文本文件清单与命中记录见 [local_scan.json](local_scan.json)，扫描程序见 [scan_gowin_docs.py](scan_gowin_docs.py)。脚本也记录了若干加密/混淆 IP 源码中的关键词假阳性；不把这些片段作为规格证据。

重点逐页核对的本机文件如下（CN/EN/JP 同类版本亦在完整清单中）：

- `IDE\doc\CN\UG304-1.3.5_Arora V可编程通用管脚(GPIO)用户指南.pdf` 与 `IDE\doc\EN\UG304-1.3.5E_Arora Ⅴ Programmable IO (GPIO) User Guide.pdf`：OSER10/16 结构与时钟关系，无速率极限。
- `IDE\doc\CN\UG306-1.0.7_Arora V时钟资源(Clock)用户指南.pdf` 与 EN 对应版：时钟资源说明，无本型号 OSER10 FCLK 最高额定值。
- `IDE\doc\CN\SUG283-3.6_Gowin原语用户指南.pdf` 与 EN 对应版：原语端口说明，无本型号最高速率。
- `IDE\doc\CN\UG289-2.2.1_Gowin可编程通用管脚(GPIO)用户指南.pdf` 与 EN 对应版：其他系列 GPIO 说明，不能替代 GW5AT 额定值。
- `Programmer\doc\CN\UG718-1.0.4_Arora Ⅴ 60K FPGA产品编程配置手册 .pdf` 与 EN 对应版：编程配置内容，无所求 I/O AC 指标。
- `IDE\data\hardware_core\gw5at\prim_syn.v`、`IDE\bin\prim_syns\gw5a\primitive.xml`、`IDE\ipcore\DVI_TX\dvi_tx.ipspec` 等文本：含原语或 IP 描述，无可引用的本型号 AC 上限。

**本地文档无此数据**：本机安装目录没有 DS981 GW5AT 数据手册；本地 PDF/文本中未找到 GW5AT-60 OSER10 最高串行输出速率、LVDS TX 最高数据率或明列的 OSER10 最高 FCLK。上述 2000 Mb/s / 2.0 Gb/s 均来自在线官方 DS981，不能误写成安装目录原有资料。官方文档库将该手册列为 [DS981 v1.1.3E，2026-07-15](https://www.gowinsemi.com/en/document/main/database/2914/)；其文档库点击需会员登录，但官方 CDN 的 [DS981E.pdf](https://cdn.gowinsemi.com.cn/DS981E.pdf) 可直接读取，封面/页脚版本为 DS981-1.1.3E。
