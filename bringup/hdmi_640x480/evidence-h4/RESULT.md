# hdmi-h4-feas-20261001c 可行性构建结果

结论：H4 首选配置完成综合、布局布线和 bitstream 生成；PLL 配置合法，pixel 域满足当前约束，全设计报告 setup/hold 违例端点各 0。**serial 域无可计算 Fmax 的时序路径，因此本次构建不能证明 OSER10 高速串行输出已满足硬件工作条件，也不能宣称 H4 已上板验证。**

## 配置和复现

```powershell
# 默认配置：640x480，25/125 MHz，负极性同步
.\build_hdmi_640x480.ps1
# H4：1920x1200，153.75/768.75 MHz，正极性同步
.\build_hdmi_640x480.ps1 -Mode H4 -GwSh D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe
```

新增 `hdmi_top.MODE_H4` 参数、`bringup/hdmi_640x480/rtl/hdmi_h4.v` 独立入口、`hdmi_h4.gprj` 和 `constr/hdmi_h4.sdc`。原 `constr/hdmi_640x480.sdc` 未修改。H4 水平参数为 1920/48/32/80（2080），垂直参数为 1200/3/6/26（1235）；顶部把原 timing 模块的负极性同步反相为正极性，再送蓝通道编码器。默认参数保持 640x480。

使用首选 MDIV=15、FRAC=3、ODIV0=1、ODIV1=5；SDC 为 123/8 和 123/40，无放宽约束、无新增 false path。像素频率相对 154 MHz 偏差约 -0.16234%，帧率约 59.85285 Hz。未尝试备选 155 MHz，因为首选已生成 bitstream 且 pixel STA 通过，提高频率不能消除 serial 域没有 STA 路径这一空缺。

## ① PA1019、VCO 和两路频率

最终 H4 构建日志 `h4/build.log` 中 PA1019 次数为 0；ERROR 次数为 0。`subst` 正常执行，没有沙箱拒绝。

综合网表原文：

```text
defparam u_pll.FBDIV_SEL=1;
defparam u_pll.FCLKIN="50";
defparam u_pll.IDIV_SEL=1;
defparam u_pll.MDIV_FRAC_SEL=3;
defparam u_pll.MDIV_SEL=15;
defparam u_pll.ODIV0_SEL=1;
defparam u_pll.ODIV1_SEL=5;
```

由已落入网表的参数计算 VCO = 50 × (15 + 3/8) = **768.75 MHz**，在 700–1400 MHz 内。tr_content.html 没有独立 VCO 实测行；不能把参数计算值或 SDC 的 Frequency 行称为硬件测量。CLKOUT0=768.75 MHz、CLKOUT1=153.75 MHz，比例严格为 5。

`impl/pnr/hdmi_h4_tr_content.html` 表格原始文本（以竖线分隔单元格，下同）：

```text
NO. | Clock Name | Type | Period | Frequency(MHz) | Rise | Fall | Source | Master | Objects
2 | serial_clk | Generated | 1.301 | 768.750 | 0.000 | 0.650 | clk | clk | u_h4/u_clk/u_pll/CLKOUT0
3 | pixel_clk | Generated | 6.504 | 153.750 | 0.000 | 3.252 | clk | clk | u_h4/u_clk/u_pll/CLKOUT1
```

## ② serial 时序与违例数

```text
No timing paths to get frequency of serial_clk!
Clock Name | Analysis Type | Endpoints TNS | Number of Endpoints
serial_clk | Setup | 0.000 | 0
serial_clk | Hold | 0.000 | 0
```

报告的 setup/hold 违例端点各 0、TNS 各 0 ns；但 **serial Actual Fmax 不可得**，0 违例不等于验证通过 768.75 MHz 的串行化器。RTL 使用 OSER10，所需线路速率为 153.75 × 10 = **1537.5 Mb/s/通道**。

## ③ pixel Actual Fmax 和全部 setup/hold 违例

```text
NO. | Clock Name | Constraint | Actual Fmax | Logic Level | Entity
2 | pixel_clk | 153.750(MHz) | 166.880(MHz) | 10 | TOP
Numbers of Paths Analyzed | 387
Numbers of Endpoints Analyzed | 291
Numbers of Setup Violated Endpoints | 0
Numbers of Hold Violated Endpoints | 0
Clock Name | Analysis Type | Endpoints TNS | Number of Endpoints
clk | Setup | 0.000 | 0
clk | Hold | 0.000 | 0
serial_clk | Setup | 0.000 | 0
serial_clk | Hold | 0.000 | 0
pixel_clk | Setup | 0.000 | 0
pixel_clk | Hold | 0.000 | 0
```

pixel 域 Actual Fmax **166.880 MHz > 153.750 MHz**。以上违例总数来自完整 STA 汇总，并非仅统计报告默认列出的前 25 条路径。

## ④ 其它 WARN / ERROR 原文

最终 H4 构建共以下 5 行 WARN，无 ERROR，stderr 为空：

```text
WARN  (EX3791) : Expression size 32 truncated to fit in target size 6("X:\rtl\tmds_encoder.v":45)
WARN  (EX3791) : Expression size 32 truncated to fit in target size 6("X:\rtl\tmds_encoder.v":46)
WARN  (EX3791) : Expression size 32 truncated to fit in target size 6("X:\rtl\tmds_encoder.v":50)
WARN  (EX3791) : Expression size 32 truncated to fit in target size 6("X:\rtl\tmds_encoder.v":53)
WARN  (PR1014) : Generic routing resource will be used to clock signal 'clk_d' by the specified constraint. And then it may lead to the excessive delay or skew
```

默认 640x480 回归也出现相同 5 行警告。

早期一次构建启动曾因尝试了不支持的 Tcl 宏选项而退出，尚未综合。原文如下，已改为参数化顶层入口解决，原始日志保存在 「initial_cli_failure/」（历史引用，当前未收录）：

```text
unknown option: -verilog_define

    while executing
"set_option -verilog_define {HDMI_H4}"
    (file "build/build.tcl" line 3)
```

## 默认模式回归及产物

改动前和改动后均通过指定脚本构建默认 640x480。改动后仍为 pixel=25 MHz、serial=125 MHz，pixel Actual Fmax=167.005 MHz，全设计 setup/hold 违例端点各 0。构建完成原文：

```text
PASS bitstream X:\impl\pnr\hdmi_h4.fs
PASS bitstream X:\impl\pnr\hdmi_640x480.fs
```

H4 bitstream：`impl/pnr/hdmi_h4.fs`，SHA256 `CCC5A2DDF6BCAA8FD924533A495344BD8CCA08E5F8122A57781502CBAC442910`。

默认 bitstream：`impl/pnr/hdmi_640x480.fs`，SHA256 `E2117F3F54301728E3984FAFAB0D41F46CAEC252EEA9D8A82B3ABC659091446E`。

原始 H4 报告仍在 `impl/pnr/hdmi_h4_tr_content.html`，同时归档到本目录 「h4/」（历史引用，当前未收录）。修改前/后默认配置日志分别在 「baseline_before/」（历史引用，当前未收录）、「baseline_after/」（历史引用，当前未收录），避免共享 `build/build.log` 被后续构建覆盖后混淆。`evidence.txt` 是两种配置报告的原始单元格文本及警告、PLL 网表参数摘录；提取程序为 `extract_evidence.py`。

新增 `bringup/hdmi_640x480/tb/tb_hdmi_modes.sv` 对两种模式逐像素检查完整一帧的坐标、DE、同步极性/区间、有效像素数和帧回绕，均通过：

```text
PASS H4=0 active=640x480 total=800x525 pixels=307200 sync_positive=0
PASS H4=1 active=1920x1200 total=2080x1235 pixels=2304000 sync_positive=1
```

此仿真替代了 PLL 和物理串行器，只验证数字视频时序，不是 PLL 频率、物理 OSER10 速率或上板验证。H4 仿真日志为 `mode_h4.log`。原有 `tb_hdmi_640x480` 回归日志保存为 `regression.log`。

原有 640x480 编解码回归也通过，输出原文：

```text
PASS frame=420000 pixels=307200 lines=480 sweep=256
```

## 是否必须更换串行化方案

**目前无法判定“必须更换”，也不能判定“现方案已满足 H4”。** PLL 和 pixel STA 没有给出必须替换 OSER10 的证据；serial STA 缺失使高速输出能力仍未闭环。下一步需核实本器件/速度等级的 OSER10、FCLK、LVDS 输出允许速率是否覆盖 768.75 MHz / 1.5375 Gb/s，并进行上板链路验证。若原语或 I/O 的额定能力不足，则需要更换串行化/输出方案；不能用放宽 SDC 的方式解决。本任务未编程硬件。
